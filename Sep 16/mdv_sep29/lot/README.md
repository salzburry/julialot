# The LOT engine on MDV

Stage 2 of the MDV port: the Sep 16 lines-of-therapy engine
(`../../lot/engine/`) with its **extraction half** rebuilt for MDV, split where
`../../lot/PORTING.md` puts the seam. The **line rules** are the Sep 16
engine's, unchanged, and `../../lot/LOT_RULES.md` is their reference. So are
the induction windows, the MAP state machine, the run-out chain, the SCT
clustering, CAR-T, the melphalan and fold-in rules, and the line criteria.
`../MDV_RULES.md`, section 4, gives the Optum-to-MDV table.

```
CODELIST_DIR=/mnt/code/codelist_mdv DATABRICKS_PWD=... \
  Rscript lot/engine/build.R mdv_NDMM_COHORT mdv_
```

The cohort table is the MDV cohort build's (`../ndmm/`). The arguments, the
prefix rules, the study window, the lineage check against `NDMM_BUILD_STATUS`,
`LOT_CONTRACT_OVERRIDE` and the outputs are as in Sep 16 (`../../lot/CONTENTS.md`),
with one new output, `MMA_RECEIPTS`.

## What changed

| file | change |
|---|---|
| `R/mdv_source.R` | new; the same file as `../ndmm/R/mdv_source.R`. Every MDV table, column and value code, and the staged selects |
| `R/config_lot.R`, `config.csv` | `MDV_SCHEMA`, `MDV_VINTAGE`, the `MDV_*` names; `ORAL_DAYS_DEFAULT`; `CENSOR_AT_DISENROLLMENT` TRUE; `CODELIST_DIR` the MDV lists |
| `R/build_lot.R` | the MDV `CONTRACT`; `check_mdv_source()` (every column read exists) in place of `check_claim_ndc()`; the MDV code-list checks among the waivable and fatal ones; a `con` argument the test suite uses |
| `R/steps/01_codelists.R` | the drug list's `RECEIPTCODE` and `NAME_ENG` rows, resolved to receipt codes (`MMA_RECEIPTS`); `CL_ROUTE`; the checks `unresolved_names`, `receipt_shape` (waivable), `route`, `multi_route` (fatal), and `code_to_med` on resolved codes. The NDC checks are gone |
| `R/steps/03_mma_map.R` | split: `phase_mma_extract()` reads `actdata` (the MDV half); `phase_map()` is the Optum MAP, unchanged |
| `R/steps/05_sct.R` | split: `phase_sct_extract()` reads acts and confirmed diagnoses (the MDV half); `phase_sct_cluster()` is the Optum AUTO clustering and ALLO/CAR-T ordering, unchanged |
| `R/db_utils_lot.R`, `R/steps/07_qc.R`, `R/steps/06_lot1_end.R` | the Optum NDC helper and its comments removed |

Nothing else in `R/` differs from Sep 16:

```
diff -r "../../lot/engine/R" "R"    # from this folder
```

## Day supply, the one assumption everything follows from

An act is a drug on a day. How long it covers decides every line boundary
downstream (PORTING.md).

- `CL_ROUTE = INJ`: the act covers `MEDICAL_DAY_SUPPLY` days (28), exactly as
  an Optum medical administration does, and does not accumulate.
- `CL_ROUTE = ORAL`: the act covers its own days supplied where the delivery
  has the column (`MDV_COL_ACT_DAYS`, **confirm**). Where it does not, an
  inpatient act covers 1 day, since DPC records an inpatient drug day by day,
  and an outpatient prescription covers `ORAL_DAYS_DEFAULT` (28), Optum's
  figure for a fill with no supply. Oral supply accumulates the way Optum
  pharmacy fills do.

PORTING.md asks for the whole build at two or three values before one is
chosen. Run them as separate prefixes with `LOT_CONTRACT_OVERRIDE=TRUE`.

## Observation

`OBS_END_DT` is the cohort's `ENDDATE_CE`, the last MDV record
(`CENSOR_AT_DISENROLLMENT=TRUE`, pinned). MDV cannot tell a patient who stopped
attending from one who stopped treatment. Observed to the study end, every
loss to follow-up would be recorded as a discontinuation, and the gap before
the next line as time off treatment.

## Tests

```
Rscript lot/engine/tests/test_runner.R        # the runner and checks (Sep 16's, adapted)
Rscript lot/engine/tests/test_line_criteria.R # unchanged
Rscript lot/engine/tests/test_mdv_extract.R   # the MDV cohort, then this engine's MDV half, on synthetic MDV
```

`test_mdv_extract.R` runs the chain as production does: the cohort build, then
this engine's preflight, code lists, `phase_mma_extract()` and
`phase_sct_extract()`, all against synthetic MDV in duckdb, checking the rows
that come out. It stops before `phase_map()`. The MAP and SCT clustering use
Spark `aggregate` with a finish lambda, which DuckDB cannot run through
sqlglot. That code is unchanged, and the Sep 16 suites cover it.
