# Questions

What the study team asked, and the scripts that answered it.

## Layout

| | |
|---|---|
| `asked/` | the questions as they were sent, and the specs and comments that came with them |
| `*_qs.R` | the scripts that answered them, against a finished LOT run |
| `_setup.R` | shared setup — points the scripts at the `lot` package's modules |

Every answer here was produced on the NDMM cohort.

## Running one

```
DATABRICKS_PWD=... DOMINO_USER_NAME=usr00000 OBJECT_PREFIX=ndmm_ \
  Rscript questions/lot1_studyteam_qs.R
```

`OBJECT_PREFIX` is **required** and names the run being asked about. Blank would
ask for unprefixed tables — usually nothing, but if an older unprefixed table is
sitting in the schema these scripts would read it and answer confidently about a
different study. A run that genuinely had no prefix says so with
`QS_ALLOW_NO_PREFIX=TRUE`.

Nothing here writes to the warehouse.

## They use the `lot` package's modules, not their own

`_setup.R` sources `load_inputs.R`, `config_lot.R`, `codelists_lot.R` and
`db_utils_lot.R` from `../lot/R`, so `cdm_src()`, the naming helpers and the
code-list loaders have one definition rather than a second copy that can drift.

Two things needed bridging.

`config_lot.R` builds `cfg_defaults` out of environment variables **at the
moment it is sourced**, so `config.csv` has to be loaded first or every setting
falls back to its hardcoded default and these scripts describe a run configured
differently from the one they are reading. `qs_setup()` loads them in the order
the build does.

`config_lot.R` then leaves the build to pin a config, so sourcing it alone
leaves no `cfg` and the first table lookup stops with "No LOT config".
`qs_setup()` does what the build does — resolves the work schema, checks it is a
schema name, requires the prefix — and `set_lot_config()` puts `cfg` where these
scripts read it from.

## Table names carry the prefix

Every table these scripts read is a build's own output: `LOT_LONG` and
`MAP_STACKED` from `lot`, `NDMM_FLAGS_ALL` and `ELIG_COH_ALLFLAGS` from the
cohort build. All of them carry the prefix.

`wrk()` does **not** add it — in this package the cohort table is named by
whoever built it, so the caller passes the whole name and `wrk()` only prepends
catalog and schema. `qs_tbl()` is what these scripts use, and it prefixes.

`tests/test_setup.R` fails if any script calls `wrk()` again.

## Not verified against the warehouse

`tests/test_setup.R` runs the setup — sourcing it, the load order, the guards,
the resolved names — so the wiring is checked. What is **not** checked is
whether the question SQL still returns the same answers against the current
`lot` modules. Known differences:

- the study window is a run argument now, not a fixed value in `CONTRACT`
- the code-list loaders drop codes that normalise to blank, de-duplicate, and
  require digits on both sides of an NDC join

Neither is expected to change an answer, and neither has been tested against
data. Treat the first run of each script as a run to check, not a run to quote.

## The files in `asked/`

They are PDFs, spreadsheets and one message thread — the record of what was
asked and when. They are reference material, not inputs: no script reads them,
and nothing in the build does either.
