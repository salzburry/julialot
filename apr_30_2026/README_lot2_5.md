# LOT 2-5 — How to run

This directory ships an additional, **standalone** module that builds LOT2
through LOT5 on top of the existing LOT1 outputs. It does not modify
`lot_program.R` or any LOT1 code.

## Files

- `R/lot2_5_inputs.R` — `prepare_lot_inputs(con, ...)`: rebuilds the
  session-scoped views the builder needs (`lot_patient_input`, `mma_rollup`,
  `permissible_subs`, `sct_codelist`, `sct_claims_raw`, `tx_auto_dates`,
  `tx_allo_cart_dates`) from CSVs + persisted CDM/cohort tables.
- `R/lot2_5_base.R` — module: `build_lot2_5(con, ...)` and helpers.
- `lot2_5_program.R` — entry script.
- Spec: `../Apr 18 2026/Program Spec and Scenarios/lot2to5_spec_DRAFT_apr30.xlsx`.

## Order of operations

There are two ways to run the full pipeline.

### Option A — top-level orchestrator (recommended)

`run_pipeline.R` runs all three stages (cohort attrition → LOT1 → LOT2-5)
in sequence, skipping any stage whose output table already exists in
the work schema:

```
Rscript run_pipeline.R
```

Skip flags:
- `FORCE_RERUN=TRUE Rscript run_pipeline.R` — re-run every stage even
  if outputs already exist.
- `SKIP_COHORT=TRUE SKIP_LOT1=TRUE Rscript run_pipeline.R` — LOT2-5 only.
- `SKIP_LOT2_5=TRUE Rscript run_pipeline.R` — cohort attrition + LOT1
  only.

After every stage the orchestrator verifies its primary output table
(`ELIG_COH_FINAL`, `LOT1_BASE_END`, `LOT_LONG`) actually landed in the
work schema. If a stage exits 0 but its output is missing — usually
because `materialize_to_personal_schema()` warned but did not write —
the orchestrator logs a `WARN:` and the next stage can still see it
before the cryptic `TABLE_OR_VIEW_NOT_FOUND` error appears two steps
later.

### Option B — run each stage manually

1. Run `lot_program.R` first. The work-schema tables it persists
   (`MAP_STACKED`, `LOT1_BASE`, `LOT1_SCT`, `LOT1_BASE_END`,
   `MMA_MED_PROCESSED`, plus `cfg$input_cohort_table`) are the only
   inputs the runner depends on.
2. Run `lot2_5_program.R`. It loads codelists from CSV, rebuilds the
   session-scoped temp views, and produces `LOT_LONG` with one row per
   `(PATID, LOT_NUM)` for `LOT_NUM = 1..max_lot`.

```
Rscript lot_program.R
Rscript lot2_5_program.R
```

## Output: LOT_LONG

Long-format table; one row per patient per LOT.

| Column                          | Notes                                          |
|---------------------------------|------------------------------------------------|
| `PATID`, `LOT_NUM`              | 1..max_lot                                     |
| `LOT_START_DT`, `LOT_START_TYPE`| `MED` / `SCT_AUTO` / `SCT_ALLO` / `CART`       |
| `LOT_BASE_MEDS`, `LOT_MED_CNT`  | 30d induction window (LOT1 was 60d)            |
| `LOT_BASE_DISCON_DT`            | run-out date if regimen ran out                |
| `LOT_BASE_1ST_ADD_MED_DT/_MED`  | first non-induction agent during LOT           |
| `LOT_BASE_END_DT/_REASON/_LENGTH`| primary analysis (disenrollment ignored)      |
| `LOT_ALLO_LOT_FLG`, `LOT_CART_LOT_FLG` | start-type indicators                   |
| `contains_mtx_reg`              | descriptive maintenance flag (LOT1 logic)      |
| `LOT_BASE_END_DT_CE_SENS`       | sensitivity end date (capped at ENDDATE_CE)    |
| `LOT_BASE_END_REASON_CE_SENS`   | `DISENROLLMENT` only when ELIGEND binds        |

## Configuration overrides

Environment variables (in addition to the LOT1 set):

| Env var                       | Default         | Spec ref       |
|-------------------------------|-----------------|----------------|
| `INDUCTION_WINDOW_DAYS_LOT_N` | `30`            | study-team decision |
| `CART_CONSOLIDATION_DAYS`     | `45`            | study-team decision |
| `SCT_TANDEM_DAYS`             | `180`           | inherited LOT1 |
| `ALLO_LOT_SPAN`               | `single_day`    | Q2 (resolved)  |
| `MAX_LOT`                     | `5`             | Q6 (open)      |

Note: there is only ONE 90-day discontinuation rule in the pipeline — the per-drug
MAP-level `MAP_DISCON_GAP_DAYS` parameter. No additional LOT-level wait exists
(Q1 06-May, confirmed Julia 13-May).

`ALLO_LOT_SPAN=extend_to_next` switches the ALLO-singleton LOT to span
through the day before the next qualifying agent.

## Open questions still pending sign-off

Resolved as of 13-May: Q1 (90-day LOT-level buffer — removed; the only
90-day rule is the per-drug MAP-level `MAP_DISCON_GAP_DAYS`), Q2 (ALLO
LOT spans a single day), Q9 (tandem AUTO uses `<= sct_tandem_days`
upper bound only; `tx_auto_dates` already groups < 60 d events upstream),
Q11 (CAR-T 45 d consolidation), Q12 (disenrollment in sensitivity only),
Q14 (same-day START priority `SCT_ALLO > CART > SCT_AUTO > MED` using
the LOT_START_TYPE labels), Q15
(CAR-T LOT runout = `DISCONTINUATION`), Q16 (AUTO trigger broadening
LOT2-5 only).

Still open and shipping with the draft defaults above: Q3, Q4, Q5, Q6,
Q10, Q13 (mostly draft confirmations; none behaviorally significant
under common histories), Q7, Q8 (Onkar — pipeline-output verifications).
