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
| `INDUCTION_WINDOW_DAYS_LOT_N` | `30`            | Apr 22 meeting |
| `CART_CONSOLIDATION_DAYS`     | `45`            | Apr 22 (Q11)   |
| `SCT_TANDEM_DAYS`             | `180`           | inherited LOT1 |
| `ALLO_LOT_SPAN`               | `single_day`    | Q2 (resolved)  |
| `MAX_LOT`                     | `5`             | Q6 (open)      |

Note: there is only ONE 90-day discontinuation rule in the pipeline — the per-drug
MAP-level `MAP_DISCON_GAP_DAYS` parameter. No additional LOT-level wait exists
(Q1 06-May, confirmed Julia 13-May).

`ALLO_LOT_SPAN=extend_to_next` switches the ALLO-singleton LOT to span
through the day before the next qualifying agent.

## Open questions still pending sign-off

The spec workbook lists open Q1..Q15 (Q11 and Q12 resolved). The defaults
above reflect the **draft** answers in the spec; flipping `ALLO_LOT_SPAN`
is the only one behaviorally significant under common patient histories.
Q15 specifically tracks the CAR-T LOT end reason (`SCT_CART` vs the
current default `DISCONTINUATION`).
