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

Set these once; the rest is copy-paste.

```bash
COHORT=ndmm_NDMM_COHORT        # your cohort table
SCHEMA=$DOMINO_USER_NAME       # or your work schema
CL=/mnt/code/codelist          # where the authored code lists live
```

```bash
# 1. lines of therapy.  Cohort table and prefix are POSITIONAL.
CODELIST_DIR=$CL DATABRICKS_PWD="$DATABRICKS_PWD" PROJECT_WORK_SCHEMA=$SCHEMA \
  Rscript lot/engine/build.R $COHORT ndmm_

# 2. the study's cohorts, variables and released tables.
#    INPUT_COHORT_TABLE and OBJECT_PREFIX are REQUIRED - the run stops
#    naming whichever is missing before it opens a connection.
DATABRICKS_PWD="$DATABRICKS_PWD" PROJECT_WORK_SCHEMA=$SCHEMA CODELIST_DIR=$CL \
  INPUT_COHORT_TABLE=$COHORT OBJECT_PREFIX=s223926_ LOT_PREFIX=ndmm_ \
  Rscript ndmm_study_updated/study223926/build.R

# ...or print the plan and stop. No driver, no warehouse, nothing read.
DRY_RUN=TRUE INPUT_COHORT_TABLE=$COHORT OBJECT_PREFIX=s223926_ \
  Rscript ndmm_study_updated/study223926/build.R

# 3. the requested table shells
TFLS_SOURCE=warehouse TFLS_PREFIX=s223926_ PROJECT_WORK_SCHEMA=$SCHEMA \
  TFLS_PACKAGE_DIR=ndmm_study_updated/study223926 \
  DATABRICKS_PWD="$DATABRICKS_PWD" Rscript TFLS/run_tfls.R

# 4. the dashboard — snapshot for a shared deployment, then the App
DATABRICKS_PWD="$DATABRICKS_PWD" PROJECT_WORK_SCHEMA=$SCHEMA \
  Rscript dashboard/jobs/build_scenarios.R
DASH_SOURCE=snapshot DASH_SNAPSHOT_DIR=/mnt/data/NDMM bash dashboard/app.sh
```

**One connection.** All four open the warehouse through one line of code -
the LOT engine's `DBI::dbConnect(odbc::odbc(), dsn = DATABRICKS_DSN, pwd =
DATABRICKS_PWD, timeout = 120)`, which the study package carries character for
character, and which TFLS and the dashboard reach by calling the study
package's `connect_db()` rather than having one of their own. And all four
read the same three facts under the LOT engine's names: `PROJECT_WORK_SCHEMA`
(or the Domino user's own schema where it is unset), `DATABRICKS_CATALOG` and
`INPUT_COHORT_TABLE`. So an environment that carried the LOT build carries
the study run, the fill and the dashboard's warehouse mode too; `TFLS_*` and
`DASH_*` names exist only for a fill or a page that has to look elsewhere. The
study suite checks the line and the variable against the engine's source
whenever the folders sit together. The password is read from the environment
alone, by every one of them.

Keep the variables **inline per command**, as above. `STUDY_START`, `MAX_LOT`
and `CENSOR_AT_DISENROLLMENT` are read by both step 1 and step 2 from the same
environment variable name with deliberately different defaults, so an `export`
silently moves one of them off its intended value.

`dashboard/DEPLOY_DOMINO.md` has the Domino Job and App setup, the environment
variables each needs, and the deployment controls that are **not** in the code.

---

## Checking it before you point it at the warehouse

Every suite runs offline — no warehouse, no driver, no Shiny — and exits
non-zero on any failure.

```bash
Rscript ndmm_study_updated/study223926/tests/run_tests.R   # 584
Rscript dashboard/tests/run_tests.R                        # 598
Rscript TFLS/tests/test_tfls.R                             # 361
(cd lot/engine     && Rscript tests/test_line_criteria.R)  #  57
(cd lot/engine     && Rscript tests/test_runner.R)         # 527
(cd lot/qc         && Rscript tests/test_lot_qc.R)         # 295
(cd lot/qc         && Rscript tests/test_foldin_trace.R)   # 149
(cd lot/qc         && Rscript tests/test_trace_returns.R)  # 148
(cd lot/melphalan  && Rscript tests/test_melp_simple.R)    # 161
(cd lot/validation && Rscript tests/test_vignettes.R)      #  36
```

2916 checks. Base R except for **`glue`**, which three of them need — the two
LOT engine suites, through `tests/testutil.R`, and melphalan. The other six load
nothing. The app needs `shiny`; a warehouse run needs `DBI`, `odbc` and `glue`.

Four of the suites (the study package, LOT QC's two, and melphalan) additionally **execute** the
SQL they emit against fixtures where `python3` with `duckdb` and `sqlglot` is
present. The dashboard suite does the same with `survival`, which it uses
only to cross-check its own Kaplan-Meier against a second implementation.

**A suite that could not run part of itself does not exit clean.** Every suite
ends with `N passed, N failed, N skipped`, names each skipped block and what
was missing, and **exits non-zero when anything was skipped** — because a run
missing its executed blocks has tested a fraction of what it claims, and
`0 failed` reads as a clean run. To accept an incomplete run deliberately (a
machine without `duckdb`, say), set `ALLOW_SKIPPED_TESTS=TRUE`; the skips are
still printed. The counts above are for a complete run.

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
