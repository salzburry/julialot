# LOT

Lines of therapy, built once and run per cohort.

## Status: ported, not yet run

`R/steps/` holds the whole build - LOT1 (MMA claims, MAP, base regimen, SCT,
end date) and LOT2 onwards up to `LOT_LONG`, one row per patient per line.
All of it ported line for line from the validated source.

`tests/test_same_as_source.R` proves that: every phase is compared against
`apr_30_2026/02_lot1.R`, `lot2_5_inputs.R` and `lot2_5_base.R`, and must match
exactly apart from the one change the port is allowed to make - LOT's outputs
carry the cohort prefix.

It has never been run against Databricks. Nothing here is validated output
until it has been, and compared with the source build patient for patient.

The folder is self-contained - the only outside dependencies are the R
packages `DBI`, `odbc` and `glue`, and no file resolves a path outside it.
`tests/test_selfcontained.R` checks that, so it cannot quietly stop being true.

## Run it

```
DATABRICKS_PWD=... Rscript build.R <COHORT_TABLE> <prefix_>
DATABRICKS_PWD=... Rscript build.R MY_COH_FINAL mystudy_
```

Or set `INPUT_COHORT_TABLE` and `OBJECT_PREFIX` instead of passing them.

## Running it for another cohort

Point it at a different table with a different prefix. Nothing in the folder
changes - it names no cohort of its own, and `tests/test_selfcontained.R`
keeps it that way.

```
Rscript build.R STUDY_A_FINAL study_a_
Rscript build.R STUDY_B_FINAL study_b_
```

The prefix is what keeps the two apart: LOT's own outputs go through
`lot_out()`, which prepends it, so `study_a_LOT1_BASE` and `study_b_LOT1_BASE`
sit side by side in one schema. The cohort table itself goes through `wrk()`
unprefixed, because the cohort build already named it. A run with no prefix is
rejected rather than allowed to overwrite another one.

### What a cohort table has to provide

`PATID`, `INDEX_DATE`, `ENDDATE`, `ENDDATE_CE`, `DEATH_DT`, `GDR_CD`, `YRDOB`,
`AGE_INDEX_YR`, `FU_DAYS`, `FU_DAYS_CE`.

The build checks the real table before it starts: the columns, and also one row
per patient, no null `PATID`/`INDEX_DATE`/`ENDDATE`, and `ENDDATE` on or after
`INDEX_DATE`. The rules read this table row for row, so a repeated patient
would multiply their claims and their lines. `ENDDATE_CE` may be null.

## Extra criteria on a line

LOT is defined by the rules in `R/steps`. If a study needs to require something
more of a line - any line, not only L1 - add it to `LINE_CRITERIA` in
`R/line_criteria.R` instead of editing those rules:

```r
list(
  name    = "l2_started_on_med",
  label   = "L2 started on a drug, not a transplant",
  lines   = 2L,                        # 1L, c(2L, 3L), or "*" for every line
  flag    = "L2_START_IS_MED",
  sql     = "LOT_START_TYPE = 'MED'",  # any expression over lot_long
  on_fail = "flag"
)
```

Then turn it on with `APPLY_L2_STARTED_ON_MED,TRUE` in `config.csv`. Any value
other than `TRUE` or `FALSE` stops the build rather than quietly leaving the
criterion off.

Two tables come out:

- `<prefix>LOT_LONG_ALLFLAGS` - every criterion as a 0/1 column, computed
  whether or not it is enabled. Check what a criterion would cost before
  turning it on.
- `<prefix>LOT_LONG_FINAL` - the enabled ones applied.

`on_fail` decides what a failing line does:

| value | effect |
|---|---|
| `flag` | column only, nothing removed - a true no-op |
| `truncate` | that line and every later line for the patient go |

`flag` is the default and may be left out, so a new criterion cannot change a
result until someone deliberately chooses otherwise. `truncate` is the only
removal mode offered, because LOT N is defined against LOT N-1: dropping a
middle line would leave L1 next to L3. Anything more is left until a real
criterion needs it.

Two rules worth knowing:

- A line the criterion is not asked of **passes**. It is not applicable, not a
  failure - otherwise a criterion aimed at L2 would fail every L1.
- A predicate that evaluates to NULL **fails**. Unknown is not evidence the
  line qualifies.

## Tests

```
Rscript tests/test_runner.R          # cohort input, contract, settings
Rscript tests/test_line_criteria.R   # the per-line criteria layer
Rscript tests/test_selfcontained.R   # no outside paths, everything resolves
Rscript tests/test_same_as_source.R  # the steps match apr_30_2026 exactly
```

No warehouse needed. They run offline; `glue` is stubbed if absent. The last
one skips when `apr_30_2026` is not beside this folder, so a copied-out package
still runs green.

## Layout

```
build.R              entry point, takes a cohort table and prefix
config.csv           pinned settings, no cohort named here
R/build_lot.R        CONTRACT, cohort input, guards
R/config_lot.R       settings
R/db_utils_lot.R     logging, retry, naming (wrk / lot_out)
R/codelists_lot.R    code list loading
R/line_criteria.R    per-line criteria
R/load_inputs.R      config.csv reader
R/steps/             the rules, in order:
  01_codelists.R       code lists, and the rollup consistency checks
  02_patient_input.R   the cohort, and OBS_END_DT
  03_mma_map.R         MM/steroid claims, then Medication Available Period
  04_lot1_base.R       LOT1 start, induction meds, base regimen
  05_sct.R             transplant: AUTO, ALLO, CAR-T
  06_lot1_end.R        LOT1 end date and reason
  07_qc.R              QC counts
  08_persist.R         write the LOT1 outputs, all prefixed
  09_lot2_5_inputs.R   rebuild the views LOT2-5 reads
  10_lot2_5_base.R     LOT2 onwards, and LOT_LONG
```
