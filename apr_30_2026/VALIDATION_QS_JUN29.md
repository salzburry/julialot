# MM LOT Validation next steps — study-team Q&A (Jun 2026)

Answers the six follow-up questions in
`Questions/June 29 2026/lot questions jul 24.pdf` (Julia Moore, GSK RWB,
24-Jun-2026). Two deliverables, one shared logic module so they can never
drift apart:

| File | What it is |
|------|------------|
| `R/validation_qs_jun29.R` | Shared logic (SQL → data.frame). Single source of truth for every definition. |
| `validation_qs_jun29.R` | **Standalone program.** Runs all six analyses, writes one CSV per result + a run log. |
| `07_combined_dashboard.R` | Renders the same six answers as labelled tables under a new **Exploratory analysis** cohort pill. |

## Run

```bash
# Standalone (CSVs in $OUTPUT_DIR):
Rscript apr_30_2026/validation_qs_jun29.R

# In the combined dashboard (Exploratory pill):
Rscript apr_30_2026/07_combined_dashboard.R   # or the usual run_all.R
```

Requires `DATABRICKS_PWD`. Reads only the persisted work-schema tables
(`LOT_LONG`, `MAP_STACKED`, `LOT1_SCT`) and — for the raw-claim patient
examples — the raw CDM via `cdm_src()`. Builds nothing persistent.

## The questions

1. **Q1** — LOT1 regimens including pomalidomide / elotuzumab / panobinostat,
   split into mono- vs combination-therapy (and an "any of the three" total).
2. **Q2** — raw-claim patient examples (before MAPs were derived) for patients
   with pomalidomide in their LOT1 regimen, beside the MAP-derived journey.
3. **Q3** — among LOT1 patients with **no** steroid at LOT1, how many received
   a steroid within 7/14/30 days **before** LOT1 start and within 7/14/30 days
   **after** the 60-day induction window.
4. **Q4** — same as Q3 for LOT2 (30-day induction window).
5. **Q5** — patients with no steroid at LOT2 but a steroid in the 30 days
   before LOT2 start: did they have a steroid at LOT1? (attribution check, to
   confirm the pre-LOT2 steroid is not really the LOT1 regimen's).
6. **Q6** — patients with CAR-T prior to or during LOT1 (the LOT rules do not
   allow CAR-T during LOT1), with raw-claim journey examples.

## Operational definitions (stated on every output)

- **Steroid signal**: a `STEROID`-class segment in `MAP_STACKED` — the same
  codelist class the LOT engine (`02_lot1.R`) excludes from regimens.
- **"Steroid at LOT*n*"**: a steroid MAP whose `MAP_START_DT` falls inside the
  induction window `[LOT_START_DT, LOT_START_DT + W − 1]`, `W` = 60 (LOT1) /
  30 (LOT2) — mirrors the engine's induction-membership rule.
- **Before / after windows** (7/14/30 d) are cumulative (≤ N days) and measured
  from a steroid MAP start date.
- **CAR-T date**: `LOT1_SCT.FIRST_CART_DT`; "prior to or during LOT1" =
  `FIRST_CART_DT < LOT1_START` or within `[LOT1_START, LOT1_BASE_END_DT]`.
- **Agent tokens**: POMA / ELOT / PANO, best-effort resolved from
  `cl_mma_codelist.csv` by medication-full-name (override via
  `POMA_MED_ABBR` / `ELOT_MED_ABBR` / `PANO_MED_ABBR`). A zero count
  (e.g. panobinostat absent from the cohort) is itself a valid answer.

The raw-claim example pulls (Q2, Q6) are **guarded**: if the CDM / codelist
CSVs are unreachable they degrade to a note and the reliable MAP-derived
journey is shown instead. Raw per-patient tables are tagged "(sample)" so the
dashboard keeps them in the full-only Patient-explorer view.
