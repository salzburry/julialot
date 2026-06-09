# Julia June 5 Q4 - Ashley planned study cohort

`julia_q4.R` builds the **Q1 / Q2 / Q3 dashboards on Julia's planned
study cohort** (Ashley's IE-filtered population) rather than on the
whole `LOT_LONG` cohort.

> Source: `June 08 2026/julia questions june 5.pdf`, page 1 yellow
> highlight ("Can we also have a look at all of these new IE criteria
> being implemented, please show bullets 1-3 above amongst the whole
> cohort and the planned study cohort.")

The whole-cohort view is produced by `../julia_q1_q3.R`. This script
reuses every helper from that file verbatim - no logic is forked.

## Cohort definition

Ashley's planned cohort is layered on top of the parent pipeline:

```
LOT_LONG                                # whole cohort
  + in ELIG_COH_FINAL                   # parent IE flags (CE_b, age,
                                        #   pregnancy, clintrial, other
                                        #   malig at MM_dx anchor, ...)
  + has LOT1_START_DT in LOT_LONG       # 1L treatment exists
  + 12-mo CE before LOT1_START_DT       # Q4 filter (Julia June 5)
  + no belantamab in any LOT            # Q4 filter (Julia June 5)
  + no MM oncology Tx in [LOT1-365, LOT1-1]   # Q4 filter (Julia June 5)
  = ASHLEY_PATIDS
```

Counts at each step are printed as the OVERVIEW attrition table in the
output dashboard and to stdout when the script runs.

### Why the three Q4 filters live here and not in the parent

Each of these is a wording change in the June 5 PDF that does **not**
match what the May 12 program spec (the parent's source of truth)
implements. We add them only for this Ashley view so the parent
pipeline and its persisted tables stay untouched.

| Q4 filter                       | June 5 PDF wording                                                                                                                                | Parent (May 12 spec) equivalent                                  | What's different                                                                                          |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| 12-mo CE before LOT1            | "CE of at least 12-months ... before the 1L cohort index date and at least 6 months before the MM diagnosis"                                      | `CE_b` = 6-mo CE before `INDEX_DATE` (MM dx)                     | Spec adds a second window with a different anchor (1L treatment start). Parent already enforces 6-mo MM-dx anchor. |
| No belantamab in any LOT        | "Eligible 1L treatment: Received an eligible treatment for MM (other than belantamab)" + "Received belantamab (i.e., an ADC) in any LOT"          | Not present                                                      | Net-new exclusion.                                                                                        |
| No MM oncology Tx in 12-mo pre-LOT1 | "Evidence of treatment with another MM oncology therapy during the 12-month 1L baseline period"                                                | `MM_BASELINE_EVIDENCE` from `therapy_flags` = 6-mo before MM dx  | Same intent, different window and anchor: 12-mo before LOT1 vs. 6-mo before MM dx.                        |

## How the Q4 filters are implemented

All three filters are computed as flags in a single per-PATID temp
view (`_jjq4_flags_all`) so the attrition card can count each step
independently. Final Ashley membership requires all three flags set.

### 12-mo CE before LOT1
Built from `member_enrollment` raw eligibility records with
**identical** span SQL as the parent's `enrollment_spans` view
(`R/pipeline_steps.R:382-421`). Gap absorption is configurable via
`GAP_DAYS` env var (default 30, matches `config_prompts.R:90`). A
patient passes if at least one merged span covers
`[LOT1_START_DT - 365, LOT1_START_DT - 1]`.

### No belantamab in any LOT
Data-driven detection on the parent's persisted `MAP_STACKED`:
```sql
upper(MAP_MED_CLASS) LIKE '%BCMA%'
   OR upper(MAP_MED_TYPE)  LIKE 'BEL%'
```
Same pattern as `lot1_studyteam_qs.R:395-407` so a future codelist
change to the belantamab abbreviation or class label is picked up
automatically. The exclusion drops PATIDs with **any** matching
`MAP_STACKED` segment regardless of LOT number (matches "in any LOT").

At study lockup belantamab was the only ADC in use for MM; the
detection above also matches future BCMA agents if they are labelled
similarly. If a non-belantamab ADC is added later, extend the
predicate (or move to a CSV-backed code list).

### No MM oncology therapy in 12-mo pre-LOT1
Scans the parent's persisted `MMA_MED_PROCESSED` for any
`DATE_SERVICE` in `[LOT1_START - 365, LOT1_START - 1]`, excluding
steroid `MED_ABBR` values (DEX / DEXA / DEXAMETHASONE / PRED /
PREDNISONE - same tokens as `julia_q1_q3.R::STEROID_TOKENS`).
Steroids are supportive care; the spec wording targets MM oncology
therapy specifically, mirroring the parent's LOT-derivation steroid
exclusion.

## Running it

```sh
Rscript apr_30_2026/julia_q4_ashley/julia_q4.R
```

Same connection environment as the parent pipeline. Required env vars:

| Env var               | Default            | Used by                                            |
| --------------------- | ------------------ | -------------------------------------------------- |
| `DATABRICKS_DSN`      | `RWDE`             | ODBC connect                                       |
| `DATABRICKS_PWD`      | (required)         | ODBC connect                                       |
| `OUTPUT_DIR`          | `/mnt/artifacts/results` | Dashboard output                              |
| `TBL_MEMBER_ENROLLMENT` | `member_enrollment` | Q4 enrollment-span build                        |
| `GAP_DAYS`            | `30`               | Q4 CE gap allowance (matches parent `cfg$gap_days`) |
| `FINAL_TABLE_NAME`    | `ELIG_COH_FINAL`   | Parent IE-flagged cohort table name                |

All three Q4-specific env-var names match the cohort pipeline's own
`config_prompts.R` so a run that already exports them picks them up
identically here.

### Required parent work tables

The script reads (does not write) these persisted parent tables:

- `LOT_LONG`             - LOT derivation per patient
- `ELIG_COH_FINAL`       - parent IE-filtered cohort
- `MAP_STACKED`          - per-medication exposure (belantamab filter)
- `MMA_MED_PROCESSED`    - per-claim MM agent table (MM-Tx-pre-LOT1 filter)

Plus the raw `member_enrollment` table for the CE span rebuild.

If `MAP_STACKED` or `MMA_MED_PROCESSED` is unreadable, the
corresponding Q4 filter is **skipped** and a warning is surfaced both
in stdout and as a note in the OVERVIEW card. The script still
produces a dashboard with the filters that did apply.

## Output

`julia_q4_ashley_dashboard.html` written to `OUTPUT_DIR`. Structure
matches `julia_q1_q3_dashboard.html` (same OVERVIEW, steroid
prevalence card, Q1 category-pair Sankeys, Q3 focused-regimen
Sankeys, Q1 category coverage QC) but every section is computed on
the Ashley cohort.

## Reuse policy

`julia_q4.R` calls `source("../julia_q1_q3.R")` with two `options()`
that the parent script honours:

- `julia_q1_q3.no_autorun = TRUE` - skip its `main()` so sourcing
  does not trigger the whole-cohort dashboard.
- `julia_q1_q3.script_dir = .parent_dir` - tell its `.script_dir`
  resolver to look in `apr_30_2026/` for the parent `R/` helpers and
  CSV inputs (otherwise `commandArgs("--file=")` makes it look in
  `apr_30_2026/julia_q4_ashley/` and the source fails).

Both options are NULL by default so the standalone
`Rscript apr_30_2026/julia_q1_q3.R` invocation is unchanged.

No parent pipeline files are written or modified.

## Known gaps vs the June 5 PDF

These June 5 criteria are **not** added as Q4 post-filters and are
inherited from `ELIG_COH_FINAL` as-built by the parent at the MM-dx
anchor:

- **Other active cancer** in the 1L baseline. Parent excludes "other
  cancer in 6-mo before MM dx" via `OTHER_MALIGN_FLAG`
  (`pipeline_steps.R:858-947`). The June 5 wording implies the 12-mo
  pre-LOT1 baseline window; re-deriving it requires copying the
  parent's `other_malig_codes` codelist + IP/OP classification SQL
  (which depends on `med_claim_header` and `confinement`). Tractable
  but a heavier lift than the three filters implemented here. If
  Julia confirms this is required, add a fourth Q4 filter following
  the same pattern.
- **MM dx in baseline** (`MM_baseline_diag` in the May 12 spec). The
  June 5 PDF does not separately call this out; NDMM identification
  rests on the "first MM treatment claim" inclusion criterion.

These are visible only as auditability caveats, not silent failures:
the OVERVIEW card states exactly which filters Q4 applies and the
attrition table reports the cohort size at each step.
