# cohort_overall — the Overall cohort's IE criteria, on their own

MM patients who pass the index-anchored IE funnel and have an MM-agent claim in
follow-up. Built from the Optum CDM, so it does not need `01_cohort.R` to have
run first.

```sh
# shape the cohort: edit cohort_config.csv (the nine IE switches)
DATABRICKS_PWD=... Rscript "Jul 28/cohort_overall/build_overall.R"   # build
Rscript "Jul 28/cohort_overall/tests/test_cohort_overall.R"          # offline checks
```

The builder takes no options — it builds. It prints the funnel it is about to
run, so you can see which criteria are on before it starts.

> **Not "1L-treated."** Step 6 wants an MM-agent claim of any class, not a LOT1
> regimen, so steroid-only follow-up passes. This cohort is a **superset** of the
> 1L-regimen population.

> ⚠️ **Not compared to the legacy cohort on patients.** The SQL and every
> criterion are compared against `pipeline_steps.R` and `criteria_attrition.R`,
> which is a statement about text, not about which patients come out. Confirm the
> numbers against the legacy `ELIG_COH_FINAL` on the warehouse before using them.

## Turning criteria on and off

`cohort_config.csv` is the operator surface — the nine `APPLY_*` switches plus the
window, min age and output settings. `TRUE` applies a criterion, `FALSE` drops it;
step 1 has no switch. It wins over `../pipeline_inputs.csv`, and an exported env
var wins over both. The funnel the build prints reflects your edits.

## Output

Writes to your **personal schema** (`DOMINO_USER_NAME`), everything prefixed
`ovr_`. The build **refuses to run** if the output resolves to the shared work
schema (i.e. `DOMINO_USER_NAME` unset) unless you name it explicitly with
`IE_OUT_SCHEMA` or set `IE_ALLOW_WORK_SCHEMA=TRUE`. `IE_REQUIRE_SCHEMA=osk` makes
it write only to `osk` and stop otherwise.

Kept after a successful build:

| table | |
|---|---|
| `ovr_ELIG_COH_FINAL` | **the cohort** — one row per PATID |
| `ovr_ELIG_COH_ALLFLAGS` | one row per (PATID, candidate index date), every criterion as a column |
| `ovr_ATTRITION_REPORT` | the attrition table |
| `ovr_RUN_STATUS` | one row: run id, config, start, completion state, final count |

The ~23 intermediate tables (code lists, claim events, spans, per-criterion flags)
are **dropped** after a clean build (`IE_KEEP_INTERMEDIATE=TRUE` keeps them). Real
tables, not views — a Databricks SQL warehouse re-runs a view's definition on
every read.

Because this build has been run against the same schema many times, it also:

- **stages** the final cohort as `ovr_ELIG_COH_FINAL__stg` and publishes it to
  the real name **only after reconciliation passes** — so a failed run leaves the
  previous cohort intact rather than a half-built one looking current;
- writes **`ovr_RUN_STATUS`** at start and finish, so you can tell which run the
  current tables belong to and whether it completed.

The legacy `ELIG_COH_FINAL` is never written.

### Handing off to the LOT build

The LOT programs read `INPUT_COHORT_TABLE`, which defaults to the legacy
`ELIG_COH_FINAL`. Building this cohort does **not** repoint them. After the
warehouse comparison passes, set `INPUT_COHORT_TABLE=ovr_ELIG_COH_FINAL`
explicitly.

## Layout

```
cohort_config.csv  the IE switches (operator edits this)
ie_config.R        config, naming, {expr} formatter, follow-up cap
ie_criteria.R      load steps, order the funnel, validate it
ie_codelists.R     load the five cohort code lists (no glue dependency)
ie_attrition.R     attrition table, reconciliation, run status, staging, cleanup
ie_runner.R        connect, build, report
build_overall.R    entry point
steps/             one file per table, in build order
tests/             test_cohort_overall.R (offline)
```

Nothing outside `Jul 28` is read at run time — plumbing is `../lib`, config is
`cohort_config.csv` + `../pipeline_inputs.csv`.

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
| **same patients as `ELIG_COH_FINAL`** | on the warehouse | **not done** — see below |

Nothing in this repo compares this build to the legacy cohort on patients.
`../tests/verify_against_legacy.R` covers the selection layer and never reads
`ovr_ELIG_COH_FINAL`. To confirm the numbers, build the legacy `ELIG_COH_FINAL`
on the same source vintage and configuration, then `EXCEPT`-compare it against
`ovr_ELIG_COH_FINAL` both directions — on PATID **and** on `(PATID, INDEX_DATE)`,
since filter-then-rank can move a surviving patient to a different index date.

The offline suite compares **normalised text** — whitespace collapsed, `CREATE`
dropped, this folder's object qualifier removed — not tokens or bytes. It also
runs nothing, so it cannot catch a runtime fault; instead it asserts the structure
that makes one impossible (every name from `work()`, every `CREATE` from
`ie_stmt()`, both from a step's `name`).

## Configuration

The IE switches and cohort parameters are in **`cohort_config.csv`** (above).
Everything else — connection, schemas, CDM source, code-list dir — is in
`../pipeline_inputs.csv`.

One wrinkle: `cfg_defaults` hardcodes the study window (`study_start`,
`study_end`, `id_start`, `id_end`, `baseline_days`, `gap_days`) as literals, so
`STUDY_END` and friends do nothing. To change them use `IE_STUDY_START`,
`IE_STUDY_END`, `IE_ID_START`, `IE_ID_END` (ISO dates, window must be in order).
Setting a dead name to something that disagrees is an error that names the
working one. This matters for a new data vintage, since quarterly source tables
resolve off `study_end`.

| Var | |
|---|---|
| `IE_OUT_SCHEMA` | output schema; defaults to `DOMINO_USER_NAME`; may not be the CDM schema |
| `IE_REQUIRE_SCHEMA` | if set, the build writes only to this schema and stops otherwise |
| `IE_ALLOW_WORK_SCHEMA` | `TRUE` to allow the shared work-schema fallback when `DOMINO_USER_NAME` is unset |
| `IE_KEEP_INTERMEDIATE` | `TRUE` to keep the intermediate tables after a build |
| `IE_OBJ_PREFIX` | `ovr_`; letters, digits, underscore |
| `IE_CONNECT_FN` | a connect function already in the session |
| `IE_ROOT_DIR` | the `Jul 28` folder, if auto-detection is wrong |

## What fails closed

Each of these has a matching way to fail *quietly*:

| check | what it would otherwise do |
|---|---|
| output resolves to a personal schema | scatter the outputs into the shared work schema |
| `IE_REQUIRE_SCHEMA` matches | write to the wrong schema on a scheduled run |
| `PERSIST_TO_SCHEMA` is TRUE | look like an off switch that does nothing |
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
| reconciliation before publish | a stale or half-built cohort under the real name |

## The second copy

The SQL in `steps/` is a copy of `pipeline_steps.R`'s, so there are two
definitions of each criterion and nothing stops them diverging. What keeps it
honest: while `apr_30_2026` is present, the test suite renders both sides from the
same `cfg` and requires the SQL to match, and checks every criterion against
`build_criteria_catalog()` by calling it. In production that folder is gone, those
checks skip, and this folder is simply the definition.

Study parameters and IE toggles are **not** copied — they come from
`../lib/config_prompts.R`'s `cfg_defaults`.
