# Julia June-5 variant pipeline

Parallel copy of the MM LOT pipeline (`apr_30_2026/` parent) with the
edits Julia spelled out in her June 5 follow-up email applied directly
to the build, instead of layering helper scripts on top. The parent
pipeline is **not touched** by anything in this folder.

Files in this directory are byte-identical to their parent siblings
EXCEPT for the changes documented below.

## Changes vs the parent pipeline

### Q2 — steroids included in LOT regimens (membership only, not boundaries)

Only the **two regimen-membership** steroid filters are removed, so
steroids appear inside `LOT_BASE_MEDS` / induction-med counts WITHOUT
changing LOT start dates, LOT counts, or end reasons. The four
**structural** steroid filters are deliberately kept (a steroid must
never start a line, trigger an add-med, or trigger a post-runout/
post-discon line) so the LOT boundaries are identical to the parent.

| File | Site | Stage | Steroid filter |
|---|---|---|---|
| `lot_program.R` | `lot1_start` | LOT1 start trigger | **KEPT** (structural) |
| `lot_program.R` | `lot1_induction_meds` | LOT1 regimen membership | **REMOVED** |
| `lot_program.R` | add-med | LOT1 add-med trigger | **KEPT** (structural) |
| `lot_program.R` | post-runout | LOT1 post-runout | **KEPT** (structural) |
| `R/lot2_5_base.R` | `med_cand` | LOT2-5 start trigger | **KEPT** (structural) |
| `R/lot2_5_base.R` | `induction_meds` | LOT2-5 regimen membership | **REMOVED** |
| `R/lot2_5_base.R` | `first_add_candidates` | LOT2-5 add-med | **KEPT** (structural) |
| `R/lot2_5_base.R` | post-discon | LOT2-5 post-discon | **KEPT** (structural) |

So the behavioural diff vs parent is exactly the **2 membership sites**.

**OPEN QUESTION for Julia**: this is the conservative reading of
*"include steroids in the LoT"* — steroids show in the regimen but do
not move line boundaries. If she actually wants steroids to also be
able to *start / break* a line (the broad reading), the four
structural filters can be removed too — a 5-minute change. Flagged
because it materially changes LOT start dates and counts.

**Important**: even the membership change only has effect once the
codelist (`$CODELIST_DIR/cl_mma_codelist.csv`) has steroid entries
with `CL_MED_CLASS = 'STEROID'`. Julia is preparing the steroid
HCPCS + NDC list; until that lands, no steroid rows surface from
`map_stacked` and the LOT regimens are identical to the parent. The
pipeline change is ready the moment the codelist is updated.

### Spec — `LOT_BASE_LENGTH_CE_SENS` emitted natively

`R/lot2_5_base.R` now emits the spec column `LOTN_BASE_LENGTH_CE_SENS`
(`scripts/build_lot2_5_spec.py:504`) directly in both the LOT1
projection and the LOT2-5 INSERT, so the variant's `LOT_LONG` carries
it without the wrapper view. The standalone `lot_ce_sens_length.R`
remains for adding the column to the **parent** pipeline's `LOT_LONG`.

### Belantamab — handled by the IE cohort, NOT the LOT builder

The LOT builder copy does **not** filter belantamab (it is identical
to the parent on that point). Julia's IE criterion *"eligible 1L
treatment for MM (other than belantamab)"* plus *"received an ADC
(belantamab) in any LOT → exclude"* is **cohort selection**, applied
downstream by `apr_30_2026/lot_ie_cohort.R` (which excludes belantamab
exposure anywhere, in `LOT_BASE_MEDS` or `MAP_STACKED`). Keeping all
belantamab logic in one place avoids the earlier inconsistency where
the pipeline only excluded it from the LOT1 start trigger.

### What is NOT baked into this copy (served by helpers)

- **CE windows** (≥12 mo before 1L start, ≥6 mo before MM-dx). Applied
  by `apr_30_2026/lot_ie_cohort.R` as a post-filter view on top of
  either pipeline; also enforced inline by `julia_jun08_qs.R` when
  `member_enrollment` is readable. Moving the parent's baseline-window
  anchor itself would be a deeper `pipeline_steps.R` refactor.

## How to run

```sh
# Use a different work schema so the variant outputs don't collide
# with the parent pipeline's LOT_LONG etc.
export PROJECT_WORK_SCHEMA=gsk_mm_lot_julia          # or any other name
export DATABRICKS_PWD=<your password>

# Optional: extend the codelist with the steroid additions before
# running (CODELIST_DIR points to the updated cl_mma_codelist.csv).

Rscript apr_30_2026/julia_pipeline/run_all.R
# or, individually:
#   Rscript apr_30_2026/julia_pipeline/run_pipeline.R
#   Rscript apr_30_2026/julia_pipeline/lot_long_dashboard.R
```

The variant emits the same set of work-schema tables as the parent
(`LOT_LONG`, `MAP_STACKED`, `ELIG_COH_FINAL`, …) but in whichever
`PROJECT_WORK_SCHEMA` you point it at.

## Sync discipline

Files here drift the moment the parent pipeline is updated. If a
parent file changes that isn't on the "Changes" list above, re-copy
it from `apr_30_2026/<file>` to `apr_30_2026/julia_pipeline/<same
relative path>`. The diff against parent is the change set.
