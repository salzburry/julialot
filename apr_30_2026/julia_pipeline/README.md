# Julia June-5 variant pipeline

Parallel copy of the MM LOT pipeline (`apr_30_2026/` parent) with the
edits Julia spelled out in her June 5 follow-up email applied directly
to the build, instead of layering helper scripts on top. The parent
pipeline is **not touched** by anything in this folder.

Files in this directory are byte-identical to their parent siblings
EXCEPT for the changes documented below.

## Changes vs the parent pipeline

### Q2 — steroids included in LOT regimens

Six `AND MAP_MED_CLASS <> 'STEROID'` filters have been neutralised
(commented + replaced with `1 = 1`) so steroid agents can now contribute
to `LOT_BASE_MEDS`, induction-medication counts, add-med detection,
and post-runout add-med logic:

| File | Original line | Stage |
|---|---|---|
| `lot_program.R` | 688 | LOT1 start trigger |
| `lot_program.R` | 704 | LOT1 induction-meds window |
| `lot_program.R` | 797 | LOT1 add-med (post-induction) |
| `lot_program.R` | 1492 | LOT1 post-runout autos |
| `R/lot2_5_base.R` | 218, 408, 708 | LOT2-5 induction / add-med / post-discon |
| `R/lot2_5_base.R` | 351 | LOT2-5 base-meds window |

**Important**: removing the filter only takes effect if the codelist
(`$CODELIST_DIR/cl_mma_codelist.csv`) has steroid entries with
`CL_MED_CLASS = 'STEROID'`. Julia is preparing the steroid HCPCS +
NDC list; until that lands in the codelist file, no steroid rows will
surface from `map_stacked` and the LOT regimens stay identical to the
parent pipeline output. The pipeline change is ready the moment the
codelist is updated.

### IE — belantamab excluded from being the LOT1 start trigger

`lot_program.R:688` (`lot1_start` view) now filters
`upper(MAP_MED_TYPE) <> 'BELA'` so a patient whose earliest non-steroid
medication is belantamab is **not** assigned belantamab as their 1L
treatment, matching Julia's IE criterion *"eligible 1L treatment for
MM (other than belantamab)"*.

### What is NOT yet baked into this copy

- **CE window change to 12 months before 1L start**. The parent
  pipeline anchors its 183-day baseline window to MM-dx `INDEX_DATE`.
  Moving the anchor to `LOT1_START_DT` and lengthening to 365 days is
  a deeper refactor (touches `pipeline_steps.R` Phase 4 logic at
  ~line 376-440). The standalone helper
  `apr_30_2026/lot_ie_cohort.R` still applies this as a post-filter
  view on top of either pipeline.
- **`LOT_BASE_LENGTH_CE_SENS` spec column**. The helper
  `apr_30_2026/lot_ce_sens_length.R` adds it as a view on top of
  `LOT_LONG`.

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
