# GSK study 223926 — belantamab mafodotin, NDMM/RRMM

The study folder: the code that builds study 223926 from **Optum Clinformatics
Data Mart V9.0**, on Databricks over the project's ODBC DSN, deployed on
Domino. It is five folders side by side, and they must stay siblings: every
path between them is relative.

## The five stages

Five stages of one study, run in this order. Each reads the tables the stages
above it wrote; `lot/` names no cohort and resolves nothing outside itself.

| # | folder | what it is | writes |
|---|---|---|---|
| 1 | `ndmm/` | the cohort and its attrition | `<prefix>NDMM_COHORT`, `<prefix>NDMM_ATTRITION` and the build's status and metadata |
| 2 | `lot/` | the lines of therapy | `<prefix>LOT_LONG_FINAL` (the lines the study reads), `LOT_ATTRITION`, `LOT_BUILD_STATUS`, `LOT_RUN_METADATA` and working tables |
| 3 | `variables/` | the study's cohorts and every other protocol variable: demographics, comorbidity, SOC, safety, HCRU, secondary malignancy, time-to-event, treatment patterns | the `S_*` tables, and a suppressed `S_*_RELEASE` copy of seven of them |
| 4 | `TFLS/` | the study's table shells, filled from stage 3 and suppressed | `TFLS/out/` |
| 5 | `dashboard/` | the Domino App over finished runs, and the snapshot Job that feeds it | the Job: one stage-3 run and one snapshot per scenario; the App writes nothing |

---

## Before the first run

**Code lists are not in here.** They are CSV files on production, read from
`CODELIST_DIR`; give it to stages 1, 2 and 3. Unset, the study package falls
back to `variables/codelists/`, which ships the shapes with no codes: under
`MODULES=all` (the default) a module whose list is unusable is left out by
name, and a module that `MODULES` names stops the run instead. Every file and
what it must carry: `variables/DATA_MAPPING.md` "Code lists".

**Warehouse settings** come from the environment, which beats `config.csv` in
each folder. `DATABRICKS_PWD` is read from the environment only; every stage
ignores it in a `config.csv`.

**The cohort's defining settings** - the study period and the 1L index floor
among them - are pinned in stage 1's contract, and the study package holds its
own window to the one the cohort recorded (`ndmm/README.md`). Protocol
s7.2.1.1 bars panobinostat and elotuzumab from setting the 1L index, and only
the cohort build can apply that: set `NDMM_INDEX_EXCLUDED_ABBRS` in
`ndmm/config.csv`, or stage 3 refuses the cohort.

**Which LOT run stage 3 will read.** It refuses a LOT run that finished on or
before the date in `LOT_RULES_EPOCH` (`variables/config.csv`), so such a run
has to be rebuilt. Set `LOT_CODE_MD5` to the
`LOT_RUN_METADATA.CODE_MD5` of the approved LOT run and stage 3 refuses a run
built by any other code; blank, it checks nothing.

**Open questions.** `variables/OPEN_QUESTIONS.md` lists every protocol question
still with the study team and the reading this build takes meanwhile. Each
reading is recorded on the run in `S_RUN_METADATA`, so a number can always be
traced to the assumption behind it.

**A prefix that already holds `S_*` tables of another shape.** Inserts are
positional, so the run stops rather than take values into the wrong columns:

```
Error: SCHEMA ERROR: <catalog>.<schema>.s223926_S_COHORT exists with a
different shape.
```

Drop what is there (`SHOW TABLES IN <catalog>.<schema> LIKE 's223926_*';`,
then `DROP` each), or give the run a prefix of its own, `OBJECT_PREFIX=s223926b_`,
and carry it into stage 4 as `TFLS_PREFIX` and into the dashboard. Nothing is
lost either way: every `S_*` table is rebuilt from stages 1 and 2.

---

## Running it

Set these once; the rest is copy-paste.

```bash
COHORT=ndmm_NDMM_COHORT        # your cohort table
SCHEMA=$DOMINO_USER_NAME       # or your work schema
CL=/mnt/code/codelist          # where the authored code lists live
```

```bash
# 1. the cohort and its attrition.  Writes $COHORT and ndmm_NDMM_ATTRITION.
#    The prefix is POSITIONAL (or OBJECT_PREFIX) and must end in '_'.
CODELIST_DIR=$CL DATABRICKS_PWD="$DATABRICKS_PWD" PROJECT_WORK_SCHEMA=$SCHEMA \
  Rscript ndmm/build.R ndmm_

# 2. lines of therapy.  Cohort table and prefix are POSITIONAL
#    (or INPUT_COHORT_TABLE and OBJECT_PREFIX).
CODELIST_DIR=$CL DATABRICKS_PWD="$DATABRICKS_PWD" PROJECT_WORK_SCHEMA=$SCHEMA \
  Rscript lot/engine/build.R $COHORT ndmm_

# 3. the study's cohorts, variables and released tables.
#    INPUT_COHORT_TABLE and OBJECT_PREFIX are REQUIRED.
DATABRICKS_PWD="$DATABRICKS_PWD" PROJECT_WORK_SCHEMA=$SCHEMA CODELIST_DIR=$CL \
  INPUT_COHORT_TABLE=$COHORT OBJECT_PREFIX=s223926_ \
  LOT_PREFIX=ndmm_ COHORT_PREFIX=ndmm_ \
  Rscript variables/build.R

# ...or print the plan and stop. No driver, no warehouse, nothing read.
DRY_RUN=TRUE INPUT_COHORT_TABLE=$COHORT OBJECT_PREFIX=s223926_ \
  Rscript variables/build.R

# 4. the table shells - from the folder holding TFLS/ and variables/
TFLS_SOURCE=warehouse TFLS_PREFIX=s223926_ PROJECT_WORK_SCHEMA=$SCHEMA \
  TFLS_PACKAGE_DIR=variables \
  DATABRICKS_PWD="$DATABRICKS_PWD" Rscript TFLS/run_tfls.R

# 5. the dashboard: the snapshot Job, then the App.
DATABRICKS_PWD="$DATABRICKS_PWD" PROJECT_WORK_SCHEMA=$SCHEMA CODELIST_DIR=$CL \
  INPUT_COHORT_TABLE=$COHORT LOT_PREFIX=ndmm_ COHORT_PREFIX=ndmm_ \
  Rscript dashboard/jobs/build_scenarios.R
DASH_SOURCE=snapshot DASH_SNAPSHOT_DIR=/mnt/data/NDMM bash dashboard/app.sh
```

**Stage 3 needs three prefixes.** `OBJECT_PREFIX` is where it WRITES;
`LOT_PREFIX` and `COHORT_PREFIX` are where it READS what stages 2 and 1 wrote.
Each read prefix defaults to `OBJECT_PREFIX`, which is right only when one
prefix built everything. Leave `COHORT_PREFIX` out and the run looks for the
cohort build's status under the study prefix: the lineage check stops on "no
cohort build status could be found", and the upstream-settings and
index-exclusion checks are logged as unverified. Set the prefix rather than
`LOT_ALLOW_UNPROVEN_LINEAGE=TRUE`, which would carry the run past exactly this.

**Stage 5 runs stage 3 again, once per row of `dashboard/scenarios.csv`,** so
it is given what stage 3 was given, and the grid adds only `OBJECT_PREFIX` and
the question each row changes. The Domino Job and App setup is in
`dashboard/DASHBOARD.md` "Deploying on Domino".

**Connection and schema.** Every stage connects over the ODBC DSN in
`DATABRICKS_DSN` (default `RWDE`) with `DATABRICKS_PWD`; the fill and the
dashboard use the study package's own `connect_db()`. All of them read the
same names: `PROJECT_WORK_SCHEMA` (or the Domino user's own schema where it is
unset), `DATABRICKS_CATALOG` (default `hive_metastore`) and
`INPUT_COHORT_TABLE`; `TFLS_*` and `DASH_*` names exist only for a fill or a
page that has to look elsewhere. Stage 3 also takes `WORK_SCHEMA`, ahead of
`PROJECT_WORK_SCHEMA`, for both the schema it writes and the one it reads the
cohort and LOT tables from; the fill and the dashboard resolve the schema in
that order too. Set only `PROJECT_WORK_SCHEMA`, as above, and every stage
reads the same schema.

**Keep the variables inline per command**, as above. `MAX_LOT` and
`CENSOR_AT_DISENROLLMENT` are read by stages 2 and 3 under the same name with
deliberately different defaults (`5` and `4`; `FALSE` and `TRUE`), so an
`export` silently moves one of them off its intended value.

---

## The run log

Stages 1, 2 and 3, started from their `build.R`, each write one: every log
line, the QC and diagnostic tables the run prints, its warnings, and - as an
`ERROR:` line - the reason it stopped. The file is the one to send.

It goes to `PIPELINE_LOG_FILE` if that is set, otherwise to
`pipeline_run_<time>_<pid>.log` under `OUTPUT_DIR` (default
`/mnt/artifacts/results`, the folder Domino keeps as a run's results). The run
prints the path when it starts. If that folder cannot be written it says so and
falls back to R's temporary folder, which R deletes when the process ends; if a
named `PIPELINE_LOG_FILE` cannot be written it says so once and logs to the
console only. To keep one file across all three stages, set
`PIPELINE_LOG_FILE` - the one variable it is safe to `export`, since it names a
file rather than a rule:

```bash
export PIPELINE_LOG_FILE=/mnt/artifacts/results/run_$(date +%Y%m%d_%H%M%S).log
```

The log opens once a stage has loaded its code and `config.csv`, so a stage
that fails while loading has its reason on the console only. A `DRY_RUN`
writes none, and stages 4 and 5 write none of their own; each scenario the
snapshot Job builds is a stage-3 run and writes one.

## Checking it before it touches the warehouse

No suite needs a warehouse, a driver or Shiny; each exits non-zero on any
failure.

```bash
(cd ndmm           && Rscript tests/test_runner.R)
(cd ndmm           && Rscript tests/test_subsequent.R)
Rscript variables/tests/run_tests.R
Rscript dashboard/tests/run_tests.R
Rscript TFLS/tests/test_tfls.R
(cd lot/engine     && Rscript tests/test_line_criteria.R)
(cd lot/engine     && Rscript tests/test_runner.R)
(cd lot/qc         && Rscript tests/test_lot_qc.R)
(cd lot/qc         && Rscript tests/test_foldin_trace.R)
(cd lot/qc         && Rscript tests/test_trace_returns.R)
(cd lot/melphalan  && Rscript tests/test_melp_simple.R)
(cd lot/validation && Rscript tests/test_vignettes.R)
```

They need base R, plus:

- **`glue`** for the melphalan suite (the cohort and LOT engine suites use it
  where installed and a stand-in otherwise);
- **`python3` with `duckdb` and `sqlglot`** for the suites that execute the SQL
  they emit against fixtures - the variables package, the three LOT QC suites
  and melphalan;
- **`survival`** for the dashboard suite's Kaplan-Meier cross-check.

**A suite that could not run part of itself does not exit clean.** It names
each skipped block and what was missing, ends with `N passed, N failed, N
skipped`, and exits non-zero. To accept an incomplete run deliberately (a
machine without `duckdb`, say), set `ALLOW_SKIPPED_TESTS=TRUE`; the skips are
still printed.

A warehouse run needs `DBI` and `odbc`, and `glue` for stages 1 and 2; the App
needs `shiny`.

---

## Disclosure

Counts are suppressed below a floor of **25** patients, the protocol's, and the
floor may only rise. The study package's release module writes an
`S_*_RELEASE` copy of each of seven aggregated tables (`SUPPRESSION_SPEC` in
`variables/R/registry.R`) with every cell under the floor withheld, and records
in `S_RUN_METADATA` (`RELEASE_RECOVERABLE`, and the tables it is about in
`RELEASE_RECOVERABLE_TABLES`) any group where one withheld cell is still the
group's total less the published rest. It does not regroup; that is the
analyst's call. The snapshot Job refuses to export such a run, and the
dashboard and the shell fill refuse those tables; each has one named override
that says on the run that it was set. The shell fill also closes every sum its
own tables draw (`TFLS/README.md` "Disclosure").

A snapshot holds patient-level tables and is as sensitive as the warehouse;
the shell output in `TFLS/out/` is what is meant to be shared. Read
`dashboard/DASHBOARD.md` "Deployment controls" before sharing anything this
produces.

---

## Which doc answers what

| question | doc |
|---|---|
| how the cohort is built, its criteria, settings, outputs and files | `ndmm/README.md` |
| why each cohort rule reads the way it does, and what is pending sign-off | `ndmm/DECISIONS.md` |
| the LOT packages, their files, how to run them and their checks | `lot/CONTENTS.md` |
| every LOT rule, with worked patient timelines | `lot/LOT_RULES.md` |
| moving the LOT engine to another data source | `lot/PORTING.md` |
| the study, its cohorts, and the study package's files and how to run it | `variables/README.md` |
| what each module computes, what a run records and what it refuses | `variables/MODULES.md` |
| the eligibility criteria, and where and how this build applies each | `variables/IE_CRITERIA.md` |
| every variable the protocol defines | `variables/VARIABLES.md` |
| where each rule and variable comes from in Optum, and every code list | `variables/DATA_MAPPING.md` |
| the questions still with the study team, and the reading taken meanwhile | `variables/OPEN_QUESTIONS.md` |
| the table shells: filling them, editing them, their disclosure rules | `TFLS/README.md` |
| the dashboard, and deploying its Job and App on Domino | `dashboard/DASHBOARD.md` |
