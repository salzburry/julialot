# Julia June 5 follow-up — clean restart

One folder. One entry point. Nothing else needed.

```
apr_30_2026/julia_june5/
├── run.R                     # the only entry point
├── mm_treatment_table.csv    # Julia's categories, from the June 5 PDF
└── README.md                 # this file
```

## What it does

Reads parent pipeline outputs (`apr_30_2026/` — *not* edited, *not* touched) and produces:

- `{work_schema}.julia_june5_cohort` — Ashley planned-study cohort (persistent table).
- `julia_june5_dashboard.html` — single HTML with cohort card, focused LOT-pair Sankeys, category Sankeys, sequential SCT/CART events.

## Run

```sh
export DATABRICKS_PWD=...
Rscript apr_30_2026/julia_june5/run.R
```

That's it. No env-var sprawl. Defaults are inlined.

## Ashley cohort criteria (all applied, inline)

| Criterion | How |
|---|---|
| 1L treatment ≥ 2017-01-01 | `LOT_LONG.LOT_START_DT` at `LOT_NUM=1` |
| No belantamab anywhere | excludes BELA in `LOT_BASE_MEDS` (any LOT) OR `MAP_STACKED.MAP_MED_TYPE` |
| CE ≥ 12 mo pre-LOT1 | gap-allowing spans (≤ 30-day gap) from `member_enrollment` |
| CE ≥ 6 mo pre-MM-dx | same |
| CE ≥ 3 mo post-LOT1 FU | **strict** (no-gap) spans |

## Files

| File | What |
|---|---|
| `run.R` | The only entry point. |
| `mm_treatment_table.csv` | Regimen → category mapping from Julia's June 5 PDF. |
| `steroid_codes.csv` | **Placeholder** for steroid HCPCS + NDC codes. Drop additions here when Julia ships her list. |
| `README.md` | This file. |

## Ashley cohort criteria (all applied inline in `run.R`)

| Criterion | How |
|---|---|
| 1L treatment ≥ 2017-01-01 | `LOT_LONG.LOT_START_DT` at `LOT_NUM = 1` |
| No belantamab anywhere | `LOT_BASE_MEDS` at any LOT_NUM **or** `MAP_STACKED.MAP_MED_TYPE` = `BELA` |
| CE ≥ 12 mo pre-LOT1 | gap-allowing spans (≤ 30 d) from `member_enrollment` |
| CE ≥ 6 mo pre-MM-dx | same |
| 3-mo post-LOT1 FU | **Flag, not an exclusion** — recorded as `FU_STATUS` ∈ {`full_3mo`, `censored_death`, `limited_fu`}. Per spec, patients without full 3-mo FU are *retained with limited follow-up that ends at the censored date of death*. `DEATH_DT` is read from persisted `LOT1_BASE` (`lot_program.R:815`). Downstream queries can split on `FU_STATUS` for sensitivity analyses. |
| No other-malignancy in `[LOT1-365, LOT1-1]` | ≥ 1 inpatient OR ≥ 2 outpatient within 30 d, same tumor group; codelist from `$CODELIST_DIR/other_malig.csv` |
| No pregnancy event in same window | DX / HCPCS / ICD-PROC / REV match against `$CODELIST_DIR/pregnancy.csv` |
| No prior MM oncology therapy in same window | rx NDC + medical HCPCS against `$CODELIST_DIR/cl_mma_codelist.csv` |

## Honest scope (what this *does not* do)

- **Steroid inclusion in `LOT_BASE_MEDS`**. That's a pipeline-level change owned by `julia_pipeline/` (the variant copy that already has the structural-vs-membership steroid filters set correctly). This script reads whatever `LOT_LONG` the parent pipeline produced. `steroid_codes.csv` is a *placeholder* for collecting the HCPCS + NDC list while waiting for Julia's full set; the cohort card reports how many codes are loaded but does not filter on steroid exposure (that's not an IE criterion — it's a regimen-membership change).

## What was retired

This restart **replaces** five helper scripts that grew unwieldy through review iteration:

- `lot_ie_cohort.R`
- `lot_baseline_recalc.R`
- `lot_ce_sens_length.R`
- `lot_fu_qs.R`
- `julia_jun08_qs.R`

The parent pipeline (`apr_30_2026/`) and the variant pipeline (`apr_30_2026/julia_pipeline/`) are untouched.
