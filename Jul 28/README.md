# Multiple myeloma cohort and lines of therapy

Seven packages. Each runs on its own, from its own folder, against Databricks
through Domino.

## Run them in this order

| | | writes |
|---|---|---|
| 1 | `overall/` — the broad MM cohort | `OVERALL_COH_FINAL` |
| 2 | `nndm/` — the 1L newly-diagnosed cohort, built from a cohort table | `<prefix>NDMM_COHORT` |
| 3 | `lot/` — lines of therapy, one row per patient per line | `<prefix>LOT_LONG_FINAL` |
| 4 | `dashboard/` — one self-contained HTML of descriptives | a file, no tables |
| 4 | `questions/` — the study team's questions, answered as CSVs | files, no tables |

`tools/` and `lot_validation/` are not part of a run. `tools/` edits a
production code list once, on request. `lot_validation/` checks the LOT rules
and needs a finished LOT run.

Steps 1 and 2 both build a cohort. Step 2 can read the output of step 1, or any
other cohort table you name.

```
DATABRICKS_PWD=... Rscript overall/build.R
DATABRICKS_PWD=... Rscript nndm/build.R      ndmm_
DATABRICKS_PWD=... Rscript lot/build.R       ndmm_NDMM_COHORT ndmm_
DATABRICKS_PWD=... Rscript dashboard/build.R ndmm_NDMM_COHORT ndmm_
```

Each package has a README with its own settings, outputs and checks. Read that
one before running it.

## One prefix is one study

Every table a run writes carries a prefix, and the cohort table it reads does
not. Two studies on one schema differ only by prefix, so a wrong prefix is a
wrong study — the builds check it rather than trusting it.

Each build records what it did in a status table (`<prefix>LOT_BUILD_STATUS`,
`<prefix>NDMM_BUILD_STATUS`): which run, which cohort, whether it finished.
Everything that reads a run afterwards — the dashboard, the questions, the
validation package — reads that row first and refuses a run that did not
finish. The latest row wins, finished or not, because a build replaces its
tables before it validates them.

## Nothing here has been run yet

No package in this folder has executed against a warehouse. The tests check the
code, not the numbers. Treat the first run of anything as a run to check, not a
run to quote.

## Settings

`config.csv` in each package holds the defaults. The environment wins over it.
Settings that change what a build means are pinned as a contract and refused if
changed — a different threshold is a different algorithm, not a setting.

Code lists live outside the folder, on a mounted path. They are hashed before
and after each read, so a run records which version it used.

## Tests

```
Rscript <package>/tests/test_runner.R
```

No connection needed. They check the SQL, the settings and the guards.
