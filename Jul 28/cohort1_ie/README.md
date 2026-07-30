# cohort1_ie — the Overall cohort's IE criteria, implemented on their own

Cohort 1 is the **Overall** cohort: every 1L-treated MM patient that clears the
index-anchored IE funnel. This folder builds it **from the Optum CDM**. It does
not read `ELIG_COH_ALLFLAGS`, so `01_cohort.R` does not have to have run first.

```sh
Rscript "Jul 28/cohort1_ie/build_cohort1.R" --funnel     # the funnel, one line per gate
Rscript "Jul 28/cohort1_ie/build_cohort1.R" --dry-run    # all 28 statements, nothing run
Rscript "Jul 28/cohort1_ie/tests/test_cohort1_ie.R"      # 121 assertions

DATABRICKS_PWD=... Rscript "Jul 28/cohort1_ie/build_cohort1.R"
```

> ⚠️ **Not validated against the warehouse.** Every statement here is asserted
> token-for-token against `pipeline_steps.R`, and every criterion against
> `criteria_attrition.R`, by evaluating the production functions — so this is a
> strong *static* argument. It is not an empirical one. The check that compares
> **patients** is `../tests/verify_against_legacy.R` (`EXCEPT` in both
> directions) and it has never been run. See `../REVIEW_FINDINGS.md`.

## Layout

```
ie_config.R      configuration, naming, the {expr} formatter, fu-cap
ie_criteria.R    loads the steps, orders the funnel, validates it
ie_attrition.R   the attrition table
ie_runner.R      connect / execute / report — no IE logic
build_cohort1.R  entry point
steps/           ONE FILE PER FLAG VIEW, in build order
tests/           the drift checks
```

Study parameters are **not** in this folder. `ie_cfg()` loads
`pipeline_inputs.csv` and then reads `config_prompts.R`'s own `cfg_defaults`, so
the study window, baseline length, `MIN_AGE`, `OUTPATIENT_WINDOW` and all nine
`APPLY_*` toggles are the project's values. Change `pipeline_inputs.csv` and this
build changes with it.

---

## Step by step: how each IE criterion is implemented

### The two orderings

Read these as two different sequences, because they are:

| | order | driven by | where |
|---|---|---|---|
| **Build** | `00 → 09` | dependencies (what needs what) | file numbers |
| **Funnel** | `1 → 10` | the study's attrition table | the `step` field |

They genuinely differ — continuous enrolment (Steps 3–4) is *built* before age
(Step 2), because `death_dt` needs `mm_qualifying` and the therapy flags need
`ce_flags`. The attrition table still reports age second. Nothing depends on the
two agreeing.

### Step 0 — the starting pool (not a gate)

`>= 1 MM diagnosis, any position`, counted straight off `mm_dx_events_id`. It is
never applied to anything; it exists so the attrition table has a denominator.

It has to come from that table and not from the flag table: the flag table only
ever contains patients who already have a qualifying index date, so Step 0
counted there would equal Step 1 and the largest drop in the study would vanish.

### Step 1 — a qualifying MM diagnosis → `steps/01_index.R`

**1 inpatient** MM dx (STRICT `203.0x` / `C90.0x`) **or 2 outpatient** (BROAD
`203.x` / `C90.x`) on separate days within the configured window.

Four views: inpatient candidates → outpatient date pairs → outpatient candidates
→ `mm_qualifying`, one row per `(PATID, candidate index date)`.

Three things to know:

- **It does not pick an index date.** Every qualifying candidate is kept, and
  they are built at the **widest** window (90d) whatever `OUTPATIENT_WINDOW` is
  set to. The configured window is applied later, as a predicate.
- **That changes who is in the cohort**, not just how fast it runs. If the
  earliest candidate fails a later gate, a *subsequent* candidate can still carry
  the patient in.
- **`outpt2_30 / 60 / 90` are all carried forward**, which is what lets the
  attrition table report three windows from one pass.

Inpatient/outpatient classification is Approach 1 (`POS` 21/51/61, or four
`TOS_CD` values) **or** Approach 2 (a `CONF_ID` validated against the confinement
table). Outpatient is the strict negation, so the two paths are exhaustive and
mutually exclusive — no claim counts toward both.

This is the one criterion with **no toggle**. Without a qualifying diagnosis
there is no index date, so there is nothing for the other nine to anchor to.

### Step 2 — age at index → `steps/03_demographics.R`

`AGE_INDEX_YR >= MIN_AGE` (18).

The only criterion with **no flag view of its own**. `member_demo` supplies
`YRDOB`; the assembly step derives `year(INDEX_DATE) - YRDOB`. So the column it
reads is an integer, and its predicate is a comparison rather than `= 1`.

Whole years from the birth **year** — Optum has no birth date. A patient turning
18 later in their index year already counts as 18. The label says so ("at index
year"); it is the study definition, not an approximation introduced here.

### Steps 3 & 4 — continuous enrolment → `steps/02_enrollment_ce.R`

| | rule |
|---|---|
| Step 3 | `CE_b = 1` — one span covers **all** of `index-183 .. index-1` |
| Step 4 | `CE_f = 1` — enrolled **on** the index date (≥1 day of follow-up) |

Baseline *excludes* the index date, follow-up *starts* on it, so the two windows
abut and never overlap.

Two span builds, and there have to be two: `enrollment_spans` absorbs gaps up to
`GAP_DAYS` (30); `enrollment_spans_strict` absorbs none. Both are built from raw
`member_enrollment`, not the CDM's prebuilt `member_cont_enrollment` — that table
has *already* absorbed sub-30-day gaps and therefore cannot reveal a true one.

Coverage is `max()` over spans, not a sum: the window must be covered by **one**
span. Two spans that jointly cover the baseline but are separated by a gap longer
than 30 days do not qualify. That is why spans are built first instead of testing
raw segments.

`CE_3mosf` (90-day, strict, death-aware) is derived in the assembly step and is
**not** a gate here — it is carried for downstream LOT work.

### Steps 5 & 6 — treatment-naive, then treated → `steps/04_therapy.R`

| | rule |
|---|---|
| Step 5 | `MM_bl_agents = 0` — no MM agent in baseline (new-user design) |
| Step 6 | `MM_FU_agents = 1` — ≥1 MM agent in follow-up |

Together these are what make cohort 1 *1L-treated*, and what makes the index date
the start of the treated course.

**Step 6 is not "has a LOT1 regimen."** It is one claim for **any** MM agent, any
drug class. A patient whose only follow-up MM agent is a steroid **passes** Step 6
and belongs to cohort 1 — while the LOT build excludes steroid-only starts when
it defines LOT1. So cohort 1 is a **superset** of the 1L-regimen population, and
the difference is real patients. Reading Step 6 as "LOT1 exists" is the single
most common misreading of this funnel.

Four scans, the same four the LOT pipeline uses (S04), so IE and LOT agree on
what an MM agent is: medical `PROC_CD`, medical `BILL_PROC_CD`, medical `NDC`, Rx
`NDC`. NDCs are matched 11-digit zero-padded on **both** sides.

Follow-up is capped at `least(study_end, death)` — and additionally at
disenrollment under `CENSOR_AT_DISENROLLMENT`. That cap is why the view joins
`death_dt`: a post-death claim is a data artefact and must not qualify somebody as
treated.

### Step 7 — no MM diagnosis already in baseline → `steps/05_baseline_mm.R`

`MM_baseline_diag = 0`: ≥1 **STRICT** MM dx in `index-183 .. index-1` excludes.

Step 5 said the patient was not already being *treated*; this says they were not
already *diagnosed*. Both are needed for "newly diagnosed" — a patient can carry
an MM diagnosis for months before their first MM-agent claim.

Note the asymmetry: Step 1 **admits** on 2 BROAD outpatient claims, but only a
**STRICT** claim in baseline **excludes**. A broad-code history disqualifies
nobody. Deliberate — broad codes cover MM-adjacent conditions that are not a
prior MM diagnosis.

Reads `mm_dx_events_all`, not `mm_dx_events_id`: the point is to look *before*
the identification period, and the ID-period view has already been cut to it.

**Ships OFF** (`APPLY_BASELINE_MM_EXCL=FALSE`).

### Step 8 — no other active cancer → `steps/06_other_malig.R`

`OTHER_MALIGN_FLAG = 0`. Per tumour group, in baseline: **≥1 inpatient** claim,
**or ≥2 outpatient** claims within 30 days, the first of which is in baseline.

Same 1-IP-or-2-OP shape as Step 1, with three differences that all matter:

1. **Per tumour group.** The pair must be the *same* group — the window partitions
   by `(PATID, tumor_group)`. Two outpatient claims for two different cancers
   confirm neither.
2. **A hardcoded 30-day window, not `OUTPATIENT_WINDOW`.** Setting the outpatient
   window to 60 or 90 changes Step 1 and leaves Step 8 at 30.
3. **The confirming claim may fall after index.** Only `first_dt` must be in
   baseline. So a patient can be excluded on the strength of a claim that
   post-dates their index date — intended (the pair confirms a cancer already
   present in baseline), but it means Step 8 is not purely a baseline-window
   criterion, unlike Steps 5 and 7.

Patients are excluded **by diagnosis code** (`dx.dx = o.dx` plus matching ICD
family). `tumor_group` is a *label* carried on the matched rows and used to
partition the pair logic.

**Ships OFF, and this one is not a preference.** NDMM re-applies
other-malignancy at the LOT1 anchor with an **MM-adjacent override** that keeps
five tumour groups (MGUS, secondary bone, solitary and extramedullary
plasmacytoma, plasma-cell leukaemia). Turning it on here drops those patients
*upstream*, before NDMM can put them back, and breaks the NDMM cohort. The
consequence for cohort 1 is stated plainly in `pipeline_inputs.csv`: with FALSE,
Overall has **no** other-malignancy exclusion.

### Step 9 — no pregnancy → `steps/07_pregnancy.R`

`PREGNANT_FLAG = 0`. **One window, not two:** `index-183 .. fu_cap`, spanning
baseline *and* follow-up as a single flag. `BETWEEN` includes the index date, so
there is no gap between the halves and no pair of columns to AND together.

Four code surfaces, because a pregnancy shows up in whichever one the biller
used: ICD diagnosis, HCPCS procedure, ICD procedure, **revenue code**
(`RVNU_CD`, facility claims only). `code_type` is matched as well as `code`, so a
numeric revenue code cannot accidentally match a procedure code.

That revenue-code surface is what the `rvnu_cd_check` probe in `00_inputs.R`
protects: without the column, this step would fail deep in a scan of the whole
medical table instead of in the first seconds of the run.

**Ships OFF** (`APPLY_PREGNANCY_EXCL=FALSE`); NDMM re-applies it over the study
period.

### Step 10 — no clinical trial → `steps/08_clintrial.R`

`CLINTRIAL_BASELINE = 0 AND CLINTRIAL_FOLLOWUP = 0`.

The **only criterion with two columns in one predicate** — baseline
(`index-183 .. index-1`) and follow-up (`index .. fu_cap`) are separate flags.
Because they are separate, it is also the only gate whose relaxation can be
partial. Step 9 collapses its two periods into one flag and cannot be split that
way.

**Ships OFF**, and nothing downstream re-applies it: clinical trial is not in the
NDMM IE spec (S6.2.1). Read `pipeline_inputs.csv`'s note before turning it on.

### Assembly → `steps/09_assemble.R`

Two objects, and the order between them is the design:

| object | grain | |
|---|---|---|
| `c1_ELIG_COH_ALLFLAGS` | `(PATID, candidate index date)` | every criterion as a column. **Nobody is dropped.** |
| `c1_ELIG_COH_FINAL` | one row per `PATID` | apply the active criteria, **then** take the earliest surviving index |

**Filter first, rank second.** Reversing those two lines changes the cohort:

- *rank-then-filter* — take the earliest candidate; drop the patient if it fails
- *filter-then-rank* — drop the failing candidates; keep the earliest survivor

So the index date a patient ends up with is a function of which gates are
switched on. **Turn a gate off and some patients move to an earlier index date**,
not just in or out of the cohort. Any comparison of two configurations has to
account for that; the counts alone will not show it.

Keeping every flag as a column is what makes a sensitivity analysis a `WHERE`
clause instead of a rebuild — and what lets the four criteria that ship OFF be
computed anyway and re-applied downstream at a different anchor.

Derived columns that are **not** criteria: `AGE_INDEX_YR` (Step 2 reads it),
`ENDDATE`, `ENDDATE_CE`, `FU_DAYS`, `FU_DAYS_CE`, `CE_3mosf`. `FU_DAYS` counts
from the day *after* index then adds 1 back, so a patient who dies on their index
date has `FU_DAYS = 0`.

### The attrition table → `ie_attrition.R`

**Cumulative**, so the drop attributable to a gate is the difference between its
row and the one above. Counts are `count(DISTINCT PATID)` — a patient with three
surviving candidate indexes is one patient on every row.

Three window columns come from one pass per row (30 / 60 / 90 differ only in
which `outpt2_*` Step 1 reads, and all three are materialized). The 90-day column
is the configured build; the other two are free sensitivity numbers, not separate
runs. Row ids and labels match `criteria_attrition.R`, so this table and the
legacy one line up row for row.

---

## Configuration

| Var | Default | |
|---|---|---|
| `IE_VIEW_PREFIX` | `c1_` | on every temp view; must not be empty |
| `IE_FINAL_TABLE` | `C1_ELIG_COH_FINAL` | the persisted cohort |
| `IE_ATTRITION_TABLE` | `C1_ATTRITION_REPORT` | |
| `IE_FLAGS_VIEW` | `ELIG_COH_ALLFLAGS` | base name; the prefix is added |
| `IE_CONNECT_FN` | — | a function already in the session |
| `APR30_DIR` | auto-detected | where the config and plumbing are read from |

Everything else — `OUTPATIENT_WINDOW`, `MIN_AGE`, `STUDY_*`, the nine `APPLY_*`
toggles — comes from `pipeline_inputs.csv` / the environment, unchanged.

Setting `IE_FINAL_TABLE` to `FINAL_TABLE_NAME` is **refused**: writing the legacy
pipeline's cohort table from here would replace what the LOT build reads.
`IE_ALLOW_OVERWRITE_LEGACY=TRUE` if that is genuinely what you mean.

## What fails closed

Each of these has a matching way to fail *silently*, which is why it is checked:

| check | what it would otherwise do |
|---|---|
| `cfg_key` is a real configuration key | `isTRUE(NULL)` is `FALSE` — the criterion would never apply and the cohort would quietly be larger |
| `flag_col` is produced by the assembly | the predicate would reference a missing column — an error, but only at run time, after the expensive scans |
| steps 1..10 present, none duplicated | a gap means a criterion was lost in a refactor |
| every `CREATE` is prefixed | an unprefixed temp view collides with the legacy pipeline's view of that name, and whichever ran second wins |
| `IE_FINAL_TABLE` ≠ `FINAL_TABLE_NAME` | silently replacing the LOT build's input |

## The cost of a second copy, stated plainly

The criteria SQL in `steps/` is a **copy** of `pipeline_steps.R`'s. There are now
two definitions of each index-anchored criterion, and nothing *prevents* them
diverging — an edit to one will not touch the other.

That is the same failure mode that let NDMM's CE and prior-therapy definitions
drift from Overall's. What is different here is that the copy is **compared
mechanically on every test run**: `tests/test_cohort1_ie.R` renders both sides
from the same `cfg` and asserts the SQL is identical token for token, and asserts
every criterion against `build_criteria_catalog()` by *evaluating* it. A
divergence is a red suite, not a quiet change in who is in the cohort.

What is duplicated, and what is not:

- **Duplicated:** the criteria SQL. Drift-tested.
- **Not duplicated:** study parameters, IE toggles, quarterly-table resolution,
  connection / retry / logging / checkpointing / the CSV code-list loader. All
  read from `apr_30_2026`, which this folder never writes to.
