# Multiple myeloma cohort and lines of therapy

Two cohort builds, one lines-of-therapy build that runs over either, and the
things that read a finished run.

## Two cohorts, not one pipeline

`nndm/` and `overall/` are **independent**. Neither reads the other. Each goes
to the raw CDM and the production code lists and builds its own cohort.

| | | writes |
|---|---|---|
| `nndm/` | the 1L newly-diagnosed MM study cohort | `<prefix>NDMM_COHORT`, `<prefix>NDMM_ATTRITION` |
| `overall/` | the broad MM cohort | `OVERALL_COH_FINAL` |

`lot/` is pointed at a cohort table by name, so it runs over either one. That
gives two paths:

```
nndm     ->  lot over <prefix>NDMM_COHORT  ->  dashboard, questions/*_qs.R
overall  ->  lot over OVERALL_COH_FINAL    ->  questions/broad_studyteam_qs.R
```

The study is the first path. The second exists because two of the study team's
questions cannot be answered on the NDMM cohort at all — it excluded the
patients they are about — so they need a LOT run over the broad cohort.

```
DATABRICKS_PWD=... Rscript nndm/build.R      ndmm_
DATABRICKS_PWD=... Rscript lot/build.R       ndmm_NDMM_COHORT ndmm_
DATABRICKS_PWD=... Rscript dashboard/build.R ndmm_NDMM_COHORT ndmm_
```

The 2L and 3L cohorts are a fourth step on the NDMM path, after the LOT run:
their index dates are line starts, so lot has to have found the lines first.

```
DATABRICKS_PWD=... Rscript nndm/build_subsequent_cohorts.R ndmm_
```

Each package has a README with its own settings, outputs and checks. Read that
one before running it.

## What each package is

| | |
|---|---|
| `overall/` | cohort build. `build.R`, takes no arguments. |
| `nndm/` | cohort build. `build.R <prefix_>`. Also `build_subsequent_cohorts.R <prefix_>` for the 2L and 3L cohorts, which runs after the LOT build. |
| `lot/` | lines of therapy. `build.R <COHORT_TABLE> <prefix_>`. |
| `dashboard/` | one self-contained HTML. `build.R <COHORT_TABLE> <lot_prefix_>`. Reads only. |
| `questions/` | scripts, not a build. Each reads one finished LOT run and writes CSVs or a workbook. They reuse `lot/`'s modules rather than a second copy. |
| `lot_validation/` | checks the LOT rules. Needs a finished LOT run for some of it; the sensitivity sweep builds its own throwaway runs. Not part of a study run. |
| `tools/` | a utility that edits a production code list on request. Not a study stage. |

## Which names carry a prefix

Not everything, and the exception matters when you point one package at
another's output.

* **A cohort build names its own final table.** `nndm` prefixes it, so it is
  `ndmm_NDMM_COHORT`. `overall` does **not** — its final table is
  `OVERALL_COH_FINAL`, from `FINAL_TABLE_NAME` in its config, with no prefix.
* **Everything else a build writes is prefixed** — checkpoints, attrition,
  run metadata, status tables, and all of LOT's outputs.
* **LOT reads the cohort table by its whole name** and prefixes only what it
  writes. So `INPUT_COHORT_TABLE` is given complete, prefix included, and is
  never prefixed again.

One prefix is one study. Two studies on one schema differ only by prefix, so a
wrong prefix is a wrong study, and the builds check it rather than trusting it.

## How a run is identified

Each build records what it did in a status table — `<prefix>LOT_BUILD_STATUS`,
`<prefix>NDMM_BUILD_STATUS`, `<prefix>build_status` for overall: which run,
which cohort, whether it finished.

Everything that reads a run afterwards reads that row first and refuses a run
that did not finish. The **latest** row wins, finished or not, because a build
replaces its tables before it validates them — so a rerun that replaced them
and then failed owns them, and the previous good row does not.

## Settings

`config.csv` in each package holds the defaults. The environment wins over it.

Settings that change what a build means are pinned as a contract and refused if
changed — a different threshold is a different algorithm, not a setting. The
one way past that is `LOT_CONTRACT_OVERRIDE`, which exists for the sensitivity
sweep; a run that uses it is marked as a non-contract build in its status row,
and everything downstream refuses it.

Code lists live outside this folder, on a mounted path. They are hashed before
and after each read, so a run records which version it used.

## Tests

No connection needed. They check the SQL, the settings and the guards.

```
Rscript overall/tests/test_runner.R
Rscript nndm/tests/test_runner.R          # and test_same_as_overall.R,
                                          # test_subsequent.R
Rscript lot/tests/test_runner.R           # and test_line_criteria.R
Rscript dashboard/tests/test_runner.R
Rscript questions/tests/test_setup.R
Rscript tools/tests/test_remove_steroids.R
Rscript lot_validation/tests/test_vignettes.R      # and test_sensitivity.R,
                                                   # test_benchmarks.R,
                                                   # test_definitions.R
```
