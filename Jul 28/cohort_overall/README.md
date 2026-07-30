# cohort_overall — the Overall cohort's IE criteria, implemented on their own

The **Overall** cohort: MM patients who clear the index-anchored IE funnel and
have an MM-agent claim in follow-up. This folder builds it **from the Optum
CDM** — it does not read `ELIG_COH_ALLFLAGS`, so `01_cohort.R` does not have to
have run first.

> **Not "1L-treated."** Step 6 requires an MM-agent claim of *any* class, not a
> LOT1 regimen, so steroid-only follow-up qualifies. This cohort is a **superset**
> of the 1L-regimen population. The earlier label said "1L-treated", which invited
> exactly the wrong reading of the denominator.

```sh
Rscript "Jul 28/cohort_overall/build_overall.R" --funnel    # the funnel
Rscript "Jul 28/cohort_overall/build_overall.R" --dry-run   # all 27 statements
Rscript "Jul 28/cohort_overall/tests/test_cohort_overall.R" # 154 assertions

DATABRICKS_PWD=... Rscript "Jul 28/cohort_overall/build_overall.R"
```

Those are the only modes. `--views`, `--no-persist` and `--attrition-only` were
removed: each could report success having done nothing (see `ie_runner.R`).

> ⚠️ **Not validated against the legacy cohort.** Every statement is compared
> against `pipeline_steps.R` and every criterion against `criteria_attrition.R` —
> a strong *static* argument, not an empirical one. The gate is
> **`tests/verify_cohort_overall.R`**, and it has not been run.

## Everything is a real table. No temporary views.

A Databricks SQL warehouse re-executes a view's definition on **every**
reference, so a chain of views re-scans the claims tables once per downstream
reader. Each of the 27 steps writes a table in your own schema instead, prefixed
`ovr_` (`IE_OBJ_PREFIX`).

That also removed a whole class of bug rather than patching one. An earlier
revision created prefixed *views* and then materialized the checkpoint under the
**unprefixed** name — so a clean run died at the first checkpoint, and a dirty
schema would have silently materialized a stale object of that name. The fix is
structural: a step declares only its `name` and its `SELECT` body. `work()` is the
only place an object name is formed and `ie_stmt()` the only place a `CREATE` is
formed, both from that `name`, and a step whose `select` contains a `CREATE` is
rejected outright. There is no second place for a name to come from.

There is no separate persist step either: the cohort **is**
`ovr_ELIG_COH_FINAL`, written by step 27. The legacy `ELIG_COH_FINAL` is never
touched.

If your site creates tables through a helper — e.g. Domino's
`personalSchemaFunctions.R` — set `IE_CREATE_TABLE_FN` to a function
`f(con, table_name, select_sql)` already defined in the session. That helper is
not in this repository, so its signature is not assumed anywhere; wire it up with
a one-line adapter.

## Layout

```
ie_config.R      configuration, naming, the {expr} formatter, the follow-up cap
ie_criteria.R    loads the steps, orders the funnel, validates it
ie_attrition.R   the attrition table + the reconciliation that checks it
ie_runner.R      connect / build / report — no IE logic
build_overall.R  entry point
steps/           ONE FILE PER TABLE, in build order
tests/           test_cohort_overall.R (offline) + verify_cohort_overall.R (warehouse)
```

Nothing outside `Jul 28` is read at run time. The plumbing is `../lib` (a verbatim
copy of `apr_30_2026/R/`, byte-identity asserted while that folder is present) and
the configuration is `../pipeline_inputs.csv`. `apr_30_2026` appears only in the
dev-time drift test, which skips when it is absent.

---

## Step by step: how each IE criterion is implemented

### The two orderings

| | order | driven by | where |
|---|---|---|---|
| **Build** | `00 → 09` | dependencies (what needs what) | file numbers |
| **Funnel** | `1 → 10` | the study's attrition table | the `step` field |

They genuinely differ — continuous enrolment (Steps 3–4) is *built* before age
(Step 2), because `death_dt` needs `mm_qualifying` and the therapy flags need
`ce_flags`. The attrition table still reports age second.

### Step 0 — the starting pool (not a gate)

`>= 1 MM diagnosis, any position`, counted off `ovr_mm_dx_events_id`. It is never
applied; it gives the attrition table a denominator. It has to come from that
table rather than the flags table, which only contains patients who already have a
qualifying index date — counted there, Step 0 would equal Step 1 and the largest
drop in the study would vanish.

### Step 1 — a qualifying MM diagnosis → `steps/01_index.R`

**1 inpatient** MM dx (STRICT `203.0x` / `C90.0x`) **or 2 outpatient** (BROAD
`203.x` / `C90.x`) on separate days within the configured window.

- **It does not pick an index date.** Every qualifying candidate is kept, built at
  the **widest** window (90d) whatever `OUTPATIENT_WINDOW` is. The configured
  window is applied later, as a predicate.
- **That changes who is in the cohort.** With filter-then-rank (below), a patient
  whose earliest candidate fails a later gate can still enter on a subsequent one.
- **`outpt2_30 / 60 / 90` are all carried forward**, which is what lets the
  attrition table report three windows from one pass.

**Inpatient and outpatient are mutually exclusive but NOT exhaustive.** Under SQL
three-valued logic, a claim with `POS` *and* `TOS_CD` both NULL and no validated
confinement makes the condition NULL, so `CASE WHEN NULL` and
`CASE WHEN NOT NULL` both fall to `ELSE 0`:

```
inpatient_flg  = 0
outpatient_flg = 0     -- neither
```

Such a claim can never produce an index date by either path. Step 1 is **ON**, so
this is live. It is copied faithfully from `pipeline_steps.R` — so the legacy
comparison can never surface it, both sides do the same thing — and it is **not
fixed here**, because changing it would change the cohort, which is a study-team
decision. `mm_dx_events_all` carries a `qc_extra` diagnostic counting the affected
claims (and the STRICT subset of them) so the question has a number attached.
Step 8 resolves the same ambiguity **differently** — see below.

This is the one criterion with **no toggle**: without a qualifying diagnosis there
is no index date for the other nine to anchor to.

### Step 2 — age at index → `steps/03_demographics.R`

`AGE_INDEX_YR >= MIN_AGE` (18). The only criterion with **no flag table of its
own**: `member_demo` supplies `YRDOB` and the assembly derives
`year(INDEX_DATE) - YRDOB`, so the column it reads is an integer and its predicate
is a comparison, not `= 1`.

Whole years from the birth **year** — Optum has no birth date, and the label says
so ("at index year"). Not an approximation introduced here.

### Steps 3 & 4 — continuous enrolment → `steps/02_enrollment_ce.R`

| | rule |
|---|---|
| Step 3 | `CE_b = 1` — one span covers **all** of `index-183 .. index-1` |
| Step 4 | `CE_f = 1` — enrolled **on** the index date (≥1 day of follow-up) |

Baseline *excludes* the index date, follow-up *starts* on it, so the windows abut
and never overlap.

Two span builds, and there have to be two: `enrollment_spans` absorbs gaps up to
`GAP_DAYS` (30); `enrollment_spans_strict` absorbs none. Both from raw
`member_enrollment`, not the CDM's `member_cont_enrollment` — that table has
already absorbed sub-30-day gaps and cannot reveal a true one.

Coverage is `max()` over spans, not a sum: **one** span must cover the window. Two
spans that jointly cover the baseline but are separated by a gap longer than 30
days do not qualify.

`CE_3mosf` is derived in the assembly and is **not** a gate — it is carried for
downstream LOT work.

### Steps 5 & 6 — treatment-naive, then treated → `steps/04_therapy.R`

| | rule |
|---|---|
| Step 5 | `MM_bl_agents = 0` — no MM agent in baseline (new-user design) |
| Step 6 | `MM_FU_agents = 1` — ≥1 MM agent in follow-up |

**Step 6 is not "has a LOT1 regimen"** — see the note at the top of this file. Any
MM agent, any class; steroid-only follow-up passes; the LOT build excludes
steroid-only starts when it defines LOT1.

Four scans, the same four the LOT pipeline uses (S04), so IE and LOT agree on what
an MM agent is: medical `PROC_CD`, medical `BILL_PROC_CD`, medical `NDC`, Rx `NDC`.
NDCs match 11-digit zero-padded on **both** sides.

Follow-up is capped at `least(study_end, death)`, plus disenrollment under
`CENSOR_AT_DISENROLLMENT`. That cap is why the step joins `death_dt`: a post-death
claim is a data artefact and must not qualify somebody as treated.

### Step 7 — no MM diagnosis already in baseline → `steps/05_baseline_mm.R`

`MM_baseline_diag = 0`: ≥1 **STRICT** MM dx in `index-183 .. index-1` excludes.

Step 5 said the patient was not already *treated*; this says they were not already
*diagnosed*. Both are needed for "newly diagnosed".

Note the asymmetry: Step 1 **admits** on 2 BROAD outpatient claims, but only a
**STRICT** claim in baseline **excludes**. Broad-code history disqualifies nobody
— broad codes cover MM-adjacent conditions that are not a prior MM diagnosis.

Reads `mm_dx_events_all`, not `mm_dx_events_id`: the point is to look *before* the
identification period. **Ships OFF** (`APPLY_BASELINE_MM_EXCL=FALSE`).

### Step 8 — no other active cancer → `steps/06_other_malig.R`

`OTHER_MALIGN_FLAG = 0`. Per tumour group, in baseline: **≥1 inpatient** claim, or
**≥2 outpatient** claims within 30 days, the first in baseline.

Same 1-IP-or-2-OP shape as Step 1, with four differences that matter:

1. **Per tumour group.** The pair must be the *same* group — the window partitions
   by `(PATID, tumor_group)`.
2. **A hardcoded 30-day window, not `OUTPATIENT_WINDOW`.** Moving the outpatient
   window to 60 or 90 changes Step 1 and leaves Step 8 at 30.
3. **The confirming claim may fall after index.** Only `first_dt` must be in
   baseline, so a patient can be excluded on a claim that post-dates their index
   date. Intended — but it means Step 8 is not purely a baseline-window criterion.
4. **Unknown care setting is treated as OUTPATIENT here**, because this step writes
   `inpatient_flg = CASE WHEN <ip> THEN 1 ELSE 0 END` and then treats everything
   with `0` as outpatient. Step 1 writes the negation explicitly and gets
   *neither*. The same claim is therefore classified differently by the two
   criteria. Step 8 ships OFF, so it does not affect the current count; the
   inconsistency is inherited and needs a study-team answer.

Patients are excluded **by diagnosis code** (`dx.dx = o.dx` plus ICD family);
`tumor_group` is a *label* used to partition the pair logic.

**Ships OFF by design.** NDMM re-applies other-malignancy at the LOT1 anchor with
an **MM-adjacent override** keeping five tumour groups (MGUS, secondary bone,
solitary and extramedullary plasmacytoma, plasma-cell leukaemia). Turning it on
here drops those patients *upstream*, before NDMM can restore them, and breaks the
NDMM cohort. Consequence for Overall, per `pipeline_inputs.csv`: **no**
other-malignancy exclusion.

### Step 9 — no pregnancy → `steps/07_pregnancy.R`

`PREGNANT_FLAG = 0`. **One window, not two:** `index-183 .. fu_cap`, spanning
baseline *and* follow-up as a single flag; `BETWEEN` includes the index date, so
there is no gap and no column pair to AND.

Four code surfaces: ICD diagnosis, HCPCS procedure, ICD procedure, **revenue
code** (`RVNU_CD`, facility claims only). `code_type` is matched as well as `code`,
so a numeric revenue code cannot match a procedure code. The `rvnu_cd_check` probe
in `00_inputs.R` exists so a missing `RVNU_CD` fails in the first seconds rather
than deep in a full-table scan.

**Ships OFF**; NDMM re-applies it over the study period.

### Step 10 — no clinical trial → `steps/08_clintrial.R`

`CLINTRIAL_BASELINE = 0 AND CLINTRIAL_FOLLOWUP = 0`. The **only criterion with two
columns in one predicate**, so also the only gate whose relaxation can be partial.
Step 9 collapses its two periods into one flag and cannot be split.

**Ships OFF**, and nothing downstream re-applies it — clinical trial is not in the
NDMM IE spec (S6.2.1).

### Assembly → `steps/09_assemble.R`

| table | grain | |
|---|---|---|
| `ovr_ELIG_COH_ALLFLAGS` | `(PATID, candidate index date)` | every criterion as a column. **Nobody is dropped.** |
| `ovr_ELIG_COH_FINAL` | one row per `PATID` | apply the active criteria, **then** take the earliest surviving index |

**Filter first, rank second.** Reversing those two lines changes the cohort:

- *rank-then-filter* — take the earliest candidate; drop the patient if it fails
- *filter-then-rank* — drop the failing candidates; keep the earliest survivor

So the index date a patient ends up with is a function of which gates are on.
**Turn a gate off and some patients move to an earlier index date**, not just in or
out. Counts alone will not show that — which is why `verify_cohort_overall.R`
compares `(PATID, INDEX_DATE)` and not just `PATID`.

Keeping every flag as a column makes a sensitivity analysis a `WHERE` clause
instead of a rebuild, and lets the four criteria that ship OFF be computed anyway
and re-applied downstream at a different anchor.

Derived, not criteria: `AGE_INDEX_YR` (Step 2 reads it), `ENDDATE`, `ENDDATE_CE`,
`FU_DAYS`, `FU_DAYS_CE`, `CE_3mosf`. `FU_DAYS` counts from the day *after* index
then adds 1 back, so a patient who dies on their index date has `FU_DAYS = 0`.

### The attrition table, and what checks it → `ie_attrition.R`

**Cumulative**, so a gate's drop is the difference between its row and the one
above. Counts are `count(DISTINCT PATID)`. Three window columns come from one pass
per row; the configured one is the build, the other two are free sensitivity
numbers. Row ids and labels match `criteria_attrition.R`.

**The funnel does not validate itself.** Every row, including the terminal one, is
computed by re-running the predicates over the *flags* table — it never reads the
cohort table, so it cannot see a wrong object written, a wrong index date selected,
duplicate PATIDs, or a failed write. An earlier revision claimed the terminal row
provided that check; it did not.

`ie_reconcile()` does, after every build, and the build **exits non-zero** if it
fails:

| check | catches |
|---|---|
| grain: one row per PATID | a broken ranking, a duplicated join |
| count == funnel end | a partial or failed write |
| membership, **both directions** | a wrong object read or written |
| `INDEX_DATE` == earliest **surviving** candidate | filter-then-rank applied in the wrong order |
| no NULL PATID / INDEX_DATE | an upstream join gone wrong |

That is internal consistency. Agreement with the legacy cohort is a different
question — next section.

---

## Validation status, precisely

| what | script | state |
|---|---|---|
| criteria + SQL match the legacy definition | `tests/test_cohort_overall.R` | **passing**, 154 assertions, offline |
| the cohort table matches its own funnel | `ie_reconcile()` | runs on every build, fails the run |
| **the same patients as `ELIG_COH_FINAL`** | **`tests/verify_cohort_overall.R`** | **never run** — needs a warehouse |

`../tests/verify_against_legacy.R` does **not** validate this folder. It compares
the *selection* layer (`coh_overall_cohort`, `coh_index_union`, `coh_ndmm_cohort`)
and never reads `ovr_ELIG_COH_FINAL`. An earlier revision of this README pointed at
it as the gate here; that was wrong.

`verify_cohort_overall.R` compares, both directions:

- the **PATID** set
- **`(PATID, INDEX_DATE)`** — because filter-then-rank means the same patient can
  legitimately survive on a *different* index date, and every LOT number
  downstream is computed from that date. PATID alone would report agreement while
  the exposure dates had moved.
- **15 key fields** over shared `(PATID, INDEX_DATE)` pairs, null-safe
- grain on both sides, and the funnel reconciliation

### What "matches" means in the offline suite

**Normalized-text** equality — not token-for-token, not byte-for-byte. Both sides
are whitespace-collapsed, the `CREATE` clause is dropped, and this folder's object
qualifier (`catalog.schema.ovr_`) is removed. Both transformations are asserted
safe first: the legacy side must contain no occurrence of the qualifier, and the
output schema must differ from the CDM schema. An earlier revision said "token for
token", which overstated it.

The offline suite also **executes nothing** — it opens no connection, so it cannot
catch a runtime fault. What it does instead is assert the structural properties
that make one impossible (section 2: every object name from `work()`, every
`CREATE` from `ie_stmt()`, both from a step's `name`). That is what the checkpoint
bug taught: a text comparison passed while the runner was unrunnable.

## Configuration

Read from `../pipeline_inputs.csv` and the environment. **Which parameters are
actually reachable matters**, because `cfg_defaults` hardcodes some of them:

| | |
|---|---|
| **Configurable** (`cfg_defaults` reads `Sys.getenv`) | `OUTPATIENT_WINDOW`, `MIN_AGE`, the nine `APPLY_*`, `CENSOR_AT_DISENROLLMENT`, schemas, catalog, DSN, `USE_QUARTERLY_TABLES`, `CODELIST_DIR` |
| **Hardcoded as literals** — no env var reaches them | `study_start`, `study_end`, `id_start`, `id_end`, `baseline_days`, `gap_days`, `dx_window_30/60/90` |

`pipeline_inputs.csv`'s own `STUDY_START` row says as much: it feeds the NDMM
dashboard's pregnancy scan, **not** the parent study window. Setting `STUDY_END`
there logs `applied` and reaches nothing — and since quarterly source tables
resolve off `cfg$study_end`, a new data vintage would silently keep reading the old
tables.

So this folder adds working overrides under **distinct names**, validated, and
layered on top rather than patched into `../lib`:

| Var | |
|---|---|
| `IE_STUDY_START` / `IE_STUDY_END` / `IE_ID_START` / `IE_ID_END` | ISO dates; must satisfy `study_start <= id_start <= id_end <= study_end` |
| `IE_BASELINE_DAYS` / `IE_GAP_DAYS` | integers |
| `IE_OBJ_PREFIX` | `ovr_`; must be a plain identifier fragment |
| `IE_OUT_SCHEMA` | defaults to `DOMINO_USER_NAME`, else `PROJECT_WORK_SCHEMA`; may not be the CDM schema |
| `IE_FLAGS_TABLE` | `ELIG_COH_ALLFLAGS` base name; the prefix is added |
| `IE_CREATE_TABLE_FN` | site helper `f(con, table, select_sql)` |
| `IE_CONNECT_FN` | a connect function already in the session |
| `IE_ROOT_DIR` | the `Jul 28` folder, if auto-detection is wrong |

Setting an **inert** name (`STUDY_END`, `ID_START`, …) to something that disagrees
with `cfg_defaults` is an **error** naming the working variable — never a silent
no-op.

## What fails closed

Each has a matching way to fail *silently*, which is why it is checked:

| check | what it would otherwise do |
|---|---|
| `OUTPATIENT_WINDOW` is 30/60/90 | `validate_outpatient_window()` silently substitutes **90**, so an invalid value looks configured |
| `APPLY_*` is exactly `TRUE`/`FALSE` | `as.logical("Y")` is `NA`, `isTRUE(NA)` is `FALSE` — the criterion never applies and the cohort is quietly larger |
| `MIN_AGE` parses | an `NA` age comparison drops everyone |
| inert date vars don't conflict | the run looks configured and uses the old window, including the old quarterly tables |
| study window ordered | an empty or nonsensical cohort |
| `cfg_key` is a real key | `isTRUE(NULL)` is `FALSE` — the same silent enlargement |
| `flag_col` is produced by the assembly | a missing column errors only at run time, after the expensive scans |
| steps 1..10 present, none duplicated | a criterion lost in a refactor |
| every object is prefixed + schema-qualified | collision with the legacy pipeline's object of that name |
| no step writes its own `CREATE` | the create/reference mismatch that was the checkpoint bug |
| unknown CLI option | a typo that silently builds nothing |
| reconciliation | a cohort table that does not match its funnel |

## The cost of a second copy, stated plainly

The criteria SQL in `steps/` is a **copy** of `pipeline_steps.R`'s. There are two
definitions of each index-anchored criterion, and nothing *prevents* them
diverging — an edit to one will not touch the other. That is the same failure mode
that let NDMM's CE and prior-therapy definitions drift from Overall's.

What is different is that the copy is **compared mechanically on every test run**,
while `apr_30_2026` is present: both sides are rendered from the same `cfg` and the
SQL must match after normalization, and every criterion is checked against
`build_criteria_catalog()` by *evaluating* it. In production `apr_30_2026` is gone,
those checks skip, and this folder is simply the definition.

- **Duplicated, drift-tested:** the criteria SQL; `../lib` (byte-identical);
  `../pipeline_inputs.csv` (byte-identical).
- **Not duplicated:** study parameters and IE toggles — read from
  `../lib/config_prompts.R`'s `cfg_defaults`, one source of truth.
