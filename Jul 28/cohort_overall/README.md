# cohort_overall — the Overall cohort's IE criteria, on their own

MM patients who pass the index-anchored IE funnel and have an MM-agent claim in
follow-up. Built from the Optum CDM, so it does not need `01_cohort.R` to have
run first.

```sh
Rscript "Jul 28/cohort_overall/build_overall.R" --funnel    # the funnel
Rscript "Jul 28/cohort_overall/build_overall.R" --dry-run   # the SQL
Rscript "Jul 28/cohort_overall/tests/test_cohort_overall.R" # 154 checks

DATABRICKS_PWD=... Rscript "Jul 28/cohort_overall/build_overall.R"
```

Those are the only modes.

> **Not "1L-treated."** Step 6 wants an MM-agent claim of any class, not a LOT1
> regimen, so steroid-only follow-up passes. This cohort is a **superset** of the
> 1L-regimen population.

> ⚠️ **Not yet compared to the legacy cohort.** The SQL and every criterion are
> compared against `pipeline_steps.R` and `criteria_attrition.R`, which is a
> statement about text. `tests/verify_cohort_overall.R` is the one that compares
> patients, and it needs a warehouse.

## Output

27 tables in your **personal schema** (`DOMINO_USER_NAME`, falling back to
`PROJECT_WORK_SCHEMA`), all prefixed `ovr_`:

| table | |
|---|---|
| `ovr_ELIG_COH_ALLFLAGS` | one row per (PATID, candidate index date), every criterion as a column |
| `ovr_ELIG_COH_FINAL` | **the cohort** — one row per PATID |
| `ovr_ATTRITION_REPORT` | the attrition table |
| the other 24 | code lists, claim events, enrolment spans, per-criterion flags |

Real tables, not views: a Databricks SQL warehouse re-runs a view's definition on
every read, so a chain of views re-scans the claims tables once per reader.

The legacy `ELIG_COH_FINAL` is never written. The prefix is what guarantees that.

## Layout

```
ie_config.R      config, naming, {expr} formatter, follow-up cap
ie_criteria.R    load steps, order the funnel, validate it
ie_attrition.R   attrition table + reconciliation
ie_runner.R      connect, build, report
build_overall.R  entry point
steps/           one file per table, in build order
tests/           test_cohort_overall.R (offline), verify_cohort_overall.R (warehouse)
```

Nothing outside `Jul 28` is read at run time — plumbing is `../lib`, config is
`../pipeline_inputs.csv`.

---

## The criteria, step by step

Two orderings, and they differ. **Build order** is the file numbers (`00`–`09`),
driven by dependencies. **Funnel order** is the `step` field (`1`–`10`), driven by
the attrition table. CE is built before age because `death_dt` needs
`mm_qualifying`; the attrition table still reports age second.

| Step | Rule | File | State |
|---|---|---|---|
| 0 | ≥1 MM dx, any position — the starting pool, not a gate | counted off `ovr_mm_dx_events_id` | count |
| 1 | 1 inpatient MM dx (strict) **or** 2 outpatient (broad) in window | `01_index.R` | always |
| 2 | `AGE_INDEX_YR >= 18` | `03_demographics.R` | ON |
| 3 | `CE_b = 1` — enrolled across the whole baseline | `02_enrollment_ce.R` | ON |
| 4 | `CE_f = 1` — enrolled on the index date | `02_enrollment_ce.R` | ON |
| 5 | `MM_bl_agents = 0` — no MM agent in baseline | `04_therapy.R` | ON |
| 6 | `MM_FU_agents = 1` — ≥1 MM agent in follow-up | `04_therapy.R` | ON |
| 7 | `MM_baseline_diag = 0` | `05_baseline_mm.R` | **off** |
| 8 | `OTHER_MALIGN_FLAG = 0` | `06_other_malig.R` | **off** |
| 9 | `PREGNANT_FLAG = 0` | `07_pregnancy.R` | **off** |
| 10 | `CLINTRIAL_* = 0` | `08_clintrial.R` | **off** |

The four that ship off are set `FALSE` in `pipeline_inputs.csv`. Their flags are
still computed, as columns on the flags table, so NDMM can re-apply them at the
LOT1 anchor. For other-malignancy that is not optional: NDMM keeps five
MM-adjacent tumour groups (MGUS, secondary bone, solitary and extramedullary
plasmacytoma, plasma-cell leukaemia), and turning step 8 on here would drop those
patients before NDMM can put them back. The cost, per `pipeline_inputs.csv`:
Overall has no other-malignancy exclusion.

Each step file explains its own rule. The points worth knowing up front:

**Step 1 does not pick an index date.** Every qualifying candidate is kept, built
at the widest window (90d) whatever `OUTPATIENT_WINDOW` says. Combined with
filter-then-rank below, a patient whose earliest candidate fails a later gate can
still enter on a subsequent one.

**Inpatient and outpatient do not cover everything.** If `POS` and `TOS_CD` are
both NULL and there is no confinement, the condition is NULL, `NOT NULL` is still
NULL, and both flags come out 0 — the claim is neither, so it cannot produce an
index date. Step 1 is on, so this is live. Step 8 handles the same case
differently: it treats non-inpatient as outpatient. Both are inherited from
`pipeline_steps.R`, so the legacy comparison cannot show them, and neither is
changed here — that would change the cohort. `mm_dx_events_all` carries a
diagnostic that counts the affected claims.

**Step 6 is not "has a LOT1 regimen."** Any MM agent, any class. Steroid-only
follow-up passes here and is excluded by the LOT build's LOT1 definition.

**Step 7's asymmetry.** Step 1 admits on broad codes; only strict codes in
baseline exclude.

**Step 8's window is a hardcoded 30 days**, not `OUTPATIENT_WINDOW`, and the
confirming outpatient claim may fall after index.

**Step 9 is one window** over baseline and follow-up; step 10 is two columns.

**Filter first, rank second.** `ovr_ELIG_COH_ALLFLAGS` drops nobody;
`ovr_ELIG_COH_FINAL` applies the active criteria and then takes each patient's
earliest surviving index date. Reversing that changes the cohort — and turning a
gate off moves some patients to an *earlier* index date, not just in or out.
Counts alone will not show it, which is why the verification compares
`(PATID, INDEX_DATE)`.

## Checks

**Every build reconciles** the cohort table against the funnel and exits non-zero
if a check fails: one row per PATID, count equals the funnel end, membership both
ways, no NULL keys, and `INDEX_DATE` is the earliest *surviving* candidate. That
last one is the filter-then-rank property, checked on real rows.

The attrition table does **not** check itself — every row re-runs the predicates
over the flags table and never reads the cohort table.

| what | script | state |
|---|---|---|
| criteria + SQL match the legacy definition | `tests/test_cohort_overall.R` | passing, 154 checks, offline |
| cohort table matches its own funnel | `ie_reconcile()` | every build |
| **same patients as `ELIG_COH_FINAL`** | **`tests/verify_cohort_overall.R`** | **not run** — needs a warehouse |

`../tests/verify_against_legacy.R` does not cover this folder. It compares the
selection layer and never reads `ovr_ELIG_COH_FINAL`.

`verify_cohort_overall.R` compares both directions on PATID and on
`(PATID, INDEX_DATE)`, plus 15 key fields over shared pairs, grain on both sides,
and the funnel reconciliation.

The offline suite compares **normalised text** — whitespace collapsed, `CREATE`
dropped, this folder's object qualifier removed — not tokens or bytes. It also
runs nothing, so it cannot catch a runtime fault; instead it asserts the structure
that makes one impossible (every name from `work()`, every `CREATE` from
`ie_stmt()`, both from a step's `name`).

## Configuration

`../pipeline_inputs.csv` and the environment. Which parameters actually reach the
build matters, because `cfg_defaults` hardcodes some:

- **Reachable:** `OUTPATIENT_WINDOW`, `MIN_AGE`, the nine `APPLY_*`,
  `CENSOR_AT_DISENROLLMENT`, schemas, catalog, DSN, `USE_QUARTERLY_TABLES`,
  `CODELIST_DIR`
- **Hardcoded as literals:** `study_start`, `study_end`, `id_start`, `id_end`,
  `baseline_days`, `gap_days`, `dx_window_30/60/90`

`pipeline_inputs.csv`'s `STUDY_START` row says so itself: it feeds the NDMM
pregnancy scan, not the study window. Setting `STUDY_END` there logs "applied" and
reaches nothing — and since quarterly source tables resolve off `study_end`, a new
data vintage would keep reading the old tables.

So the working names here are `IE_STUDY_START`, `IE_STUDY_END`, `IE_ID_START`,
`IE_ID_END` (ISO dates, and the window must be in order). Setting a dead name to
something that disagrees is an error that names the working one.

| Var | |
|---|---|
| `IE_OBJ_PREFIX` | `ovr_`; letters, digits, underscore |
| `IE_OUT_SCHEMA` | defaults to `DOMINO_USER_NAME`, then `PROJECT_WORK_SCHEMA`; may not be the CDM schema |
| `IE_FLAGS_TABLE` | `ELIG_COH_ALLFLAGS` base name; the prefix is added |
| `IE_CONNECT_FN` | a connect function already in the session |
| `IE_ROOT_DIR` | the `Jul 28` folder, if auto-detection is wrong |

## What fails closed

Each of these has a matching way to fail *quietly*:

| check | what it would otherwise do |
|---|---|
| `OUTPATIENT_WINDOW` is 30/60/90 | silently becomes 90 |
| `APPLY_*` is `TRUE`/`FALSE` | `as.logical("Y")` is NA, read as FALSE, so a gate never applies and the cohort is larger |
| `MIN_AGE` parses | an NA comparison drops everyone |
| dead date vars don't conflict | the run looks configured and reads the old vintage |
| study window in order | an empty cohort |
| `cfg_key` is a real key | `isTRUE(NULL)` is FALSE — same silent enlargement |
| `flag_col` exists on the flags table | errors only at run time, after the expensive scans |
| steps 1–10, none duplicated | a criterion lost in a refactor |
| every object prefixed and qualified | collides with the legacy pipeline's object |
| no step writes its own `CREATE` | the create/reference mismatch that broke the earlier checkpoint |
| unknown CLI option | a typo that builds nothing |
| reconciliation | a cohort table that does not match its funnel |

## The second copy

The SQL in `steps/` is a copy of `pipeline_steps.R`'s, so there are two
definitions of each criterion and nothing stops them diverging. What keeps it
honest: while `apr_30_2026` is present, the test suite renders both sides from the
same `cfg` and requires the SQL to match, and checks every criterion against
`build_criteria_catalog()` by calling it. In production that folder is gone, those
checks skip, and this folder is simply the definition.

Study parameters and IE toggles are **not** copied — they come from
`../lib/config_prompts.R`'s `cfg_defaults`.
