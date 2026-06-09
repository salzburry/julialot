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

## Honest scope (what this *does not* do)

- **Other-malig / pregnancy / no-baseline-MM-therapy** exclusions are inherited from the parent pipeline's 183-day-pre-MM-dx window (`baseline_days = 183` in `config_prompts.R`). Recomputing them against the 12-mo-pre-LOT1 window belongs in a pipeline edit, not in this helper.
- **Death-aware** semantics for the 3-mo FU. Would need death-dt access that the persisted output doesn't surface.
- **Steroid inclusion** in LOT regimens. That's a codelist + pipeline change in `julia_pipeline/`; this script can't fake it.

## What was retired

This restart **replaces** five helper scripts that grew unwieldy through review iteration:

- `lot_ie_cohort.R`
- `lot_baseline_recalc.R`
- `lot_ce_sens_length.R`
- `lot_fu_qs.R`
- `julia_jun08_qs.R`

The parent pipeline (`apr_30_2026/`) and the variant pipeline (`apr_30_2026/julia_pipeline/`) are untouched.
