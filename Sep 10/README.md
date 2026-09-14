# GSK study 223926 — belantamab mafodotin, NDMM/RRMM

Against **Optum Clinformatics Data Mart V9.0**, on Databricks over the
project's ODBC DSN, deployed on Domino.

Four folders, side by side. They must stay siblings: every path between them is
relative and nothing uses an absolute path.

| folder | what it is | start at |
|---|---|---|
| `lot/` | the claims lines-of-therapy engine — produces the lines everything else reads | `lot/CONTENTS.md` |
| `ndmm_study_updated/` | the study package — the cohorts, the variables, the released tables | `ndmm_study_updated/CONTENTS.md` |
| `dashboard/` | the R Shiny app over a finished run, and the snapshot job that feeds it | `dashboard/DASHBOARD.md` |
| `TFLS/` | the requested table shells, filled from a finished run | `TFLS/README.md` |

Dependencies run one way. `lot/` names no cohort and resolves nothing outside
itself; the other three read the tables a run wrote.

---

## Before the first run

**Code lists are not in here.** They are CSV files on production, read from
`CODELIST_DIR`, and nothing loads without them: a missing file, an unknown
filename, a missing column or an empty file stops the run and says which.
`ndmm_study_updated/CODELISTS.md` lists every file, its required columns and
the code types it may carry, and marks the ones still to be authored.

**Warehouse settings** come from the environment, which beats `config.csv` in
each folder. `DATABRICKS_PWD` is read from the environment only — never from a
file, and no file here holds one.

**Open questions.** `ndmm_study_updated/OPEN_QUESTIONS.md` lists every protocol
question still with the study team and the reading this build takes meanwhile.
Each reading is recorded on the run itself, in `S_RUN_METADATA`, so a number
can always be traced to the assumption behind it.

---

## Running it

In order. Each step reads what the one before it wrote.

```bash
# 1. lines of therapy
CODELIST_DIR=... DATABRICKS_PWD=... Rscript lot/engine/build.R

# 2. the study's cohorts, variables and released tables
DATABRICKS_PWD=... Rscript ndmm_study_updated/study223926/build.R
DRY_RUN=TRUE   Rscript ndmm_study_updated/study223926/build.R   # print the plan only

# 3. the requested table shells
TFLS_SOURCE=warehouse TFLS_PREFIX=s223926_ PROJECT_WORK_SCHEMA=... \
  DATABRICKS_PWD=... Rscript TFLS/run_tfls.R

# 4. the dashboard — snapshot for a shared deployment, then the App
DATABRICKS_PWD=... Rscript dashboard/jobs/build_scenarios.R
bash dashboard/app.sh
```

`dashboard/DEPLOY_DOMINO.md` has the Domino Job and App setup, the environment
variables each needs, and the deployment controls that are **not** in the code.

---

## Checking it before you point it at the warehouse

Every suite runs offline — no warehouse, no driver, no Shiny — and exits
non-zero on any failure.

```bash
Rscript ndmm_study_updated/study223926/tests/run_tests.R   # 447
Rscript dashboard/tests/run_tests.R                        # 574
Rscript TFLS/tests/test_tfls.R                             # 300
(cd lot/engine     && Rscript tests/test_line_criteria.R)  #  57
(cd lot/engine     && Rscript tests/test_runner.R)         # 527
(cd lot/qc         && Rscript tests/test_lot_qc.R)         # 295
(cd lot/qc         && Rscript tests/test_foldin_trace.R)   # 149
(cd lot/melphalan  && Rscript tests/test_melp_simple.R)    # 161
(cd lot/validation && Rscript tests/test_vignettes.R)      #  36
```

2546 checks. Base R throughout — no suite above loads a package. The app needs
`shiny`; a warehouse run needs `DBI`, `odbc` and `glue`. Four of the suites
(the study package, LOT QC's two, and melphalan) additionally **execute** the
SQL they emit against fixtures where `python3` with `duckdb` and `sqlglot` is
present; where it is not they print `SKIP` and the rest of the suite still
runs, so a green run on a machine without them is a smaller check than a green
run with them. The dashboard suite does the same with `survival`, which it uses
only to cross-check its own Kaplan-Meier against a second implementation.

Each suite prints `SKIP` for anything it could not run, and the line says what
was missing — so read the skips, not just the total.

---

## Disclosure

Counts are suppressed below a floor of **25** patients, the protocol's, and the
floor may only rise — never fall. A withheld cell must not be recoverable by
subtraction, so the release module closes the sums and reports in
`S_RUN_METADATA` anything it could not close. The snapshot job refuses to
export such a run, the dashboard refuses to show those tables, and the shell
runner refuses to fill from them; each has one named override that says on the
run that it was set.

Read `dashboard/DEPLOY_DOMINO.md` under **Deployment controls** before sharing
anything this produces. A snapshot holds patient-level tables and is as
sensitive as the warehouse; the shell output in `TFLS/out/` is the artefact
meant to be shared, after disclosure review.
