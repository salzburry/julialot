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
  INPUT_COHORT_TABLE=ndmm_NDMM_COHORT \
  Rscript questions/lot1_studyteam_qs.R
```

`INPUT_COHORT_TABLE` is the **whole** physical name, prefix included — that is
how LOT takes it, since the cohort is named by whoever built it. Several
questions read it for observation windows, index dates and the raw-claim
bounds, so it is required rather than defaulted; blank used to resolve to a
name that was only the schema, and those sections warned and ran unbounded.

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

## One population, chosen once

`qs_population()` decides what every question runs over. Default
**`LOT_LONG_FINAL`** — the study population, after the line criteria.

```
LOT_POPULATION=PRECRITERIA   # the same run BEFORE the line criteria
```

That is the only axis left. The scripts used to switch between two *cohorts* —
a full LOT run and an NDMM-filtered copy persisted beside it — and that
arrangement is gone: the LOT run is over the cohort already, so its output under
this prefix **is** the study population, and a different cohort is a different
prefix and a separate invocation. `LOT_COHORT` stops the run and says so rather
than being quietly reinterpreted.

Pre-criteria is worth asking for when the question is what a criterion cost. It
is not a cohort, and a denominator taken from it counts patients the study
removed.

## Q3's broad-cohort question needs a broad-cohort run

`poma_studyteam_qs.R` Q3 has two halves. The NDMM audit runs on this cohort and
must come back zero. The **association** — whether POMA use tracks with another
cancer — is a broad-population question, and one prefix is one cohort: this
cohort has already excluded patients with a qualifying other cancer, so
answering it from this run would be near-zero by construction and mean nothing.

Set `BROAD_PREFIX` to the prefix of a LOT run over the broad cohort. Without it
that half is skipped and says so; the audit still runs.

## Bone metastasis

`poma_studyteam_qs.R` removes MM-adjacent conditions from its de-confounded
broad-cohort analysis, and it takes that decision from
`<prefix>NDMM_OTHER_MALIG_CODES` — the code list as the cohort build resolved
it, with `is_mm_adjacent_override` already applied.

So there is no second list here to keep in step. Secondary neoplasm of bone is
excluded because the build excluded it (`C79.51`, `C79.52` and `198.5` are
metastatic cancer — `nndm/DECISIONS.md` section 4), not because this script
agrees. Rebuilding the list from `other_malig.csv` would mean re-deciding the
rule, which is exactly how the two came to disagree.

## Not verified against the warehouse

`tests/test_setup.R` runs the setup and holds the population, the table names
and the bone-metastasis list to what the build does. What it cannot check is
whether the question SQL returns the same answers as before — nothing here has
been executed against a warehouse.

Treat the first run of each script as a run to check, not a run to quote.

## The files in `asked/`

They are PDFs, spreadsheets and one message thread — the record of what was
asked and when. They are reference material, not inputs: no script reads them,
and nothing in the build does either.
