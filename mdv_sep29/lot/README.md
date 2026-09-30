# The LOT engine on MDV

Stage 2 of the MDV port: the Optum build's lines-of-therapy engine with its
**extraction half** rebuilt for MDV, split where `PORTING.md` puts the seam.
The **line rules** are the Optum engine's, unchanged, and `LOT_RULES.md` is
their reference: the induction windows, the MAP state machine, the run-out
chain, the SCT clustering, CAR-T, the melphalan and fold-in rules, and the line
criteria. `../MDV_RULES.md`, section 4, gives the Optum-to-MDV table.

```
CODELIST_DIR=/mnt/code/codelist_mdv DATABRICKS_PWD=... \
  Rscript lot/engine/build.R mdv_NDMM_COHORT mdv_
```

The cohort table is the MDV cohort build's (`../ndmm/`). The arguments, the
prefix rules, the study window, the lineage check against `NDMM_BUILD_STATUS`,
`LOT_CONTRACT_OVERRIDE` and the outputs are in `CONTENTS.md`, with every file
and what it does.

## What changed from the Optum engine

| file | change |
|---|---|
| `engine/R/mdv_source.R` | new; the same file as `../ndmm/R/mdv_source.R`. Every MDV table, column and value code, and the staged selects |
| `engine/R/config_lot.R`, `engine/config.csv` | `MDV_SCHEMA`, `MDV_VINTAGE`, the `MDV_*` names; `ORAL_DAYS_DEFAULT`; `CENSOR_AT_DISENROLLMENT` TRUE; `CODELIST_DIR` the MDV lists |
| `engine/R/build_lot.R` | the MDV `CONTRACT`; `check_mdv_source()` (every column read exists) in place of the NDC profile, run in the preflight before anything is written; the MDV code-list checks among the waivable and fatal ones; `MDV_SOURCE` on `LOT_RUN_METADATA`; a `con` argument the test suite uses |
| `engine/R/steps/01_codelists.R` | the drug list's `RECEIPTCODE` and `NAME_ENG` rows, resolved to receipt codes (`MMA_RECEIPTS`); `CL_ROUTE`; the checks `unresolved_names`, `receipt_shape` (waivable), `route`, `multi_route` (fatal), and `code_to_med` on resolved codes, each independent of the others. The NDC checks are gone |
| `engine/R/steps/02_patient_input.R` | the observation-end log line and comment read for MDV, where censoring at the last record is the contract; the SQL is unchanged |
| `engine/R/steps/03_mma_map.R` | split: `phase_mma_extract()` reads `actdata` (the MDV half), and stops on an oral act with no days supplied whose care setting neither code reads; `phase_map()` is the Optum MAP, unchanged |
| `engine/R/steps/05_sct.R` | split: `phase_sct_extract()` reads acts and confirmed diagnoses (the MDV half), and stops on a `NAME_ENG` pattern matching nothing (`sct_unresolved_names`, waivable); `phase_sct_cluster()` is the Optum AUTO clustering and ALLO/CAR-T ordering, unchanged but for its comment on the tandem mark (`LOT_RULES.md` §6.1) |
| `engine/R/db_utils_lot.R`, `engine/R/steps/07_qc.R`, `engine/R/steps/06_lot1_end.R` | the Optum NDC helper and its comments removed |
| `engine/R/melp_rule.R` | comments only: they pointed at the Optum build's melphalan package, which is not in this folder |

Every other file under `engine/R/` is the Optum engine's, unchanged.

## Day supply, the one assumption everything follows from

An act is a drug on a day. How long it covers decides every line boundary
downstream (`PORTING.md`).

- `CL_ROUTE = INJ`: the act covers `MEDICAL_DAY_SUPPLY` days (28), exactly as
  an Optum medical administration does, and does not accumulate.
- `CL_ROUTE = ORAL`: the act covers its own days supplied where the delivery
  has the column (`MDV_COL_ACT_DAYS`, **confirm**). Where it does not, an
  inpatient act covers 1 day, since DPC records an inpatient drug day by day,
  and an outpatient prescription covers `ORAL_DAYS_DEFAULT` (28), Optum's
  figure for a fill with no supply. Oral supply accumulates the way Optum
  pharmacy fills do.

`PORTING.md` asks for the whole build at two or three values before one is
chosen. Run them as separate prefixes with `LOT_CONTRACT_OVERRIDE=TRUE`
(`CONTENTS.md`, "Running it").

## Observation

`OBS_END_DT` is the cohort's `ENDDATE_CE`, the last MDV record
(`CENSOR_AT_DISENROLLMENT=TRUE`, pinned; `LOT_RULES.md` §7.6). MDV cannot tell
a patient who stopped attending from one who stopped treatment. Observed to the
study end, every loss to follow-up would be recorded as a discontinuation, and
the gap before the next line as time off treatment.

## Tests

```
Rscript lot/engine/tests/test_runner.R          # the runner, the contract, the checks, the declared outputs
Rscript lot/engine/tests/test_line_criteria.R   # the per-line criteria layer
Rscript lot/engine/tests/test_mdv_extract.R     # the MDV cohort, then this engine's MDV half, on synthetic MDV
Rscript lot/validation/tests/test_vignettes.R   # the rules and the vignette catalogue agree with the engine
```

`test_mdv_extract.R` runs the chain as production does: the cohort build, then
this engine's preflight, code lists, `phase_mma_extract()` and
`phase_sct_extract()`, all against synthetic MDV in duckdb, checking the rows
that come out. It stops before `phase_map()`.

**Not executed by any suite here:** `phase_map()`, `phase_sct_cluster()` and
the line assembly after them. The MAP and SCT clustering use Spark `aggregate`
with a finish lambda, which DuckDB cannot run through sqlglot. That code is the
Optum engine's, unchanged; in this folder the suites check its settings, its
declared outputs and the rules it cites, not the rows it returns. Its first
execution on MDV output is the first warehouse run.
