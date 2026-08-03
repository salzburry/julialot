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

## Known to be wrong, not yet fixed

These scripts were written against an earlier arrangement and three of their
assumptions no longer hold. The wiring is fixed; the question logic is not.

**They read `LOT_LONG`, not `LOT_LONG_FINAL`.** For this cohort
`APPLY_NO_BELANTAMAB` is on and truncates patients, so `LOT_LONG` still contains
people the study removed. Every denominator and percentage these scripts report
is therefore over the pre-criteria population. That is a per-script change to
each query, not a setting.

**Three of them expect `<prefix>NDMM_LOT_LONG_FILT`.** The cohort build no
longer produces it — the flow is now cohort → LOT directly, and the LOT run's
own `LOT_LONG` under the cohort's prefix *is* the NDMM population. Those
sections will stop, and `validation_qs.R` additionally labels that run "Overall"
when it is not.

**`poma_studyteam_qs.R` treats secondary neoplasm of bone as MM-adjacent** and
removes it from its de-confounded analysis. The cohort build decided the
opposite — `C79.51`, `C79.52` and `198.5` are metastatic cancer and exclude
(`DECISIONS.md` section 4). The two answer the same clinical question
differently.

Its other-malignancy section also calls `load_codelist_csv("other_malig.csv")`,
which the `lot` loader refuses: it allows only the four code lists the LOT build
reads.

Until those are reworked, treat the affected sections as unavailable rather than
as answers.

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
