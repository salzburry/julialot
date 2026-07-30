# LOT

Lines of therapy, built once and run per cohort.

The folder is self-contained: copy it into another project and it works. The
only outside dependencies are the R packages `DBI`, `odbc` and `glue`.
`tests/test_selfcontained.R` checks this, so it cannot quietly stop being true.

## Run it

```
DATABRICKS_PWD=... Rscript build.R overall
```

## Adding a cohort

A cohort is two facts: which table to read, and what to call the outputs. Both
live in `COHORTS` in `R/build_lot.R`:

```r
COHORTS <- list(
  overall = list(input_cohort_table = "OVERALL_COH_FINAL", object_prefix = "overall_"),
  ndmm    = list(input_cohort_table = "NDMM_COH_FINAL",    object_prefix = "ndmm_")
)
```

That is the only change. The rules are the same for every cohort.

The prefix is what keeps cohorts apart: LOT's own outputs go through
`lot_out()`, which prepends it, so `overall_LOT1_BASE` and `ndmm_LOT1_BASE` sit
side by side in one schema. The cohort table itself goes through `wrk()`
unprefixed, because the cohort build already named it. A cohort with no prefix
is rejected rather than allowed to overwrite another one.

An unknown cohort name stops with the list of known ones. It is a typo, not a
new cohort.

### What a cohort table has to provide

`PATID`, `INDEX_DATE`, `ENDDATE`, `ENDDATE_CE`, `DEATH_DT`, `GDR_CD`, `YRDOB`,
`AGE_INDEX_YR`, `FU_DAYS`, `FU_DAYS_CE`.

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

Then turn it on with `APPLY_L2_STARTED_ON_MED,TRUE` in `config.csv`.

Two tables come out:

- `<prefix>LOT_LONG_ALLFLAGS` - every criterion as a 0/1 column, computed
  whether or not it is enabled. Check what a criterion would cost before
  turning it on.
- `<prefix>LOT_LONG_FINAL` - the enabled ones applied.

`on_fail` decides what a failing line does:

| value | effect |
|---|---|
| `flag` | column only, nothing removed |
| `drop_line` | that line goes |
| `truncate` | that line and every later line for the patient go |
| `drop_patient` | the patient goes entirely |

`flag` is the default, so a new criterion cannot change a result until someone
deliberately chooses otherwise. `truncate` exists because LOT N is defined
against LOT N-1: dropping a middle line would leave L1 and L3 with nothing
between them.

Two rules worth knowing:

- A line the criterion is not asked of **passes**. It is not applicable, not a
  failure - otherwise a criterion aimed at L2 would fail every L1.
- A predicate that evaluates to NULL **fails**. Unknown is not evidence the
  line qualifies.

## Tests

```
Rscript tests/test_runner.R          # cohort switch, contract, settings
Rscript tests/test_line_criteria.R   # the per-line criteria layer
Rscript tests/test_selfcontained.R   # nothing reaches outside this folder
```

No warehouse needed. They run offline; `glue` is stubbed if absent.

## Layout

```
build.R              entry point, takes a cohort name
config.csv           pinned settings, no cohort named here
R/build_lot.R        CONTRACT, COHORTS, guards
R/config_lot.R       settings
R/db_utils_lot.R     logging, retry, naming (wrk / lot_out)
R/codelists_lot.R    code list loading
R/line_criteria.R    per-line criteria
R/load_inputs.R      config.csv reader
R/steps/             the rules
```
