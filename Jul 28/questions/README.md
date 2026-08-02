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

These read what a LOT run wrote, so the schema and prefix have to be that run's.
Nothing here writes to the warehouse.

## They use the `lot` package's modules, not their own

`_setup.R` sources `load_inputs.R`, `config_lot.R`, `codelists_lot.R` and
`db_utils_lot.R` from `../lot/R`, so `wrk()`, `cdm_src()` and the code-list
loaders have one definition rather than a second copy that can drift.

One thing needed bridging. `config_lot.R` defines `cfg_defaults` and leaves the
build to pin a config, so sourcing it alone leaves no `cfg` and the first
`wrk()` call stops with "No LOT config". `qs_setup()` does what the build does —
resolves the work schema, checks it is a schema name, pins the prefix — and
`set_lot_config()` puts `cfg` where these scripts read it from.

## Not verified against these modules

**These scripts have not been run since they were pointed at `lot/R`.** They
parse, and the four modules they ask for are all there, but the modules are not
identical to the ones they were written against. Known differences that could
bite:

- the study window is a run argument now, not a fixed value in `CONTRACT`
- `lot_out()` exists and carries the object prefix; `wrk()` does not prefix
- the code-list loaders drop codes that normalise to blank, de-duplicate, and
  require digits on both sides of an NDC join

None of that is expected to change an answer, but none of it has been tested.
Treat the first run of each script as a run to check, not a run to quote.

## The files in `asked/`

They are PDFs, spreadsheets and one message thread — the record of what was
asked and when. They are reference material, not inputs: no script reads them,
and nothing in the build does either.
