# GSK study 223926 — belantamab mafodotin, NDMM/RRMM

Against **Optum Clinformatics Data Mart V9.0**, on Databricks over the
project's ODBC DSN, deployed on Domino.

Five folders, side by side. They must stay siblings: every path between them is
relative and nothing uses an absolute path.

**Five stages of one study, not five studies.** Each reads what the stage above
it wrote. The order below is the order to run them in.

| # | folder | what it is | writes |
|---|---|---|---|
| 1 | `ndmm/` | the cohort and its attrition | `NDMM_COHORT`, `NDMM_ATTRITION` |
| 2 | `lot/` | the lines of therapy | `LOT_LONG_FINAL`, `MAP_STACKED`, … |
| 3 | `variables/` | every other variable the protocol asks for — demographics, comorbidity, SOC, safety, HCRU, secondary malignancy, time-to-event, treatment patterns | the `S_*` tables |
| 4 | `TFLS/` | the requested table shells, filled from stage 3 and suppressed | `TFLS/out/` |
| 5 | `dashboard/` | the Domino app over a finished run, and the snapshot job that feeds it | the job: a study run and a snapshot per scenario; the app writes nothing |

Dependencies run one way. `lot/` names no cohort and resolves nothing outside
itself; the stages after it read the tables a run wrote. Each stage's own doc
is where to start on it: `ndmm/README.md`, `lot/CONTENTS.md`,
`variables/CONTENTS.md`, `TFLS/README.md` and `dashboard/DASHBOARD.md`. The
last section below says which doc answers what.

---

## Before the first run

**Code lists are not in here.** They are CSV files on production, read from
`CODELIST_DIR`. In the cohort and LOT builds a missing file, an unknown
filename, a missing column or an empty file stops the run and says which. The
study package falls back to `variables/codelists/`, which ships the shapes with
no codes, so give it `CODELIST_DIR` as well; there a module whose list is
unusable is left out by name under `MODULES=all` (the default), and stops the
run if `MODULES` names it. `variables/CODELISTS.md` lists every file, what it
must carry and which are still to be authored.

**Warehouse settings** come from the environment, which beats `config.csv` in
each folder. `DATABRICKS_PWD` is read from the environment only — every stage
ignores it in a `config.csv`, and no file here holds one.

**Cohort settings.** Every setting of stage 1 is written once, in
`ndmm/config.csv` or the environment, and reaches both the contract check and
the SQL; `ndmm/README.md` "Settings" lists them. The ones in the build's
`CONTRACT` — the study period and the 1L index floor among them — are what the
cohort *is*, so the build refuses a value that differs unless
`NDMM_CONTRACT_OVERRIDE=TRUE` says the difference is meant. The deviation is
then recorded on the run, and the study package holds its own window to the
one the cohort recorded (`SETTINGS_OVERRIDE=TRUE` lets it go on, recording the
disagreement as a deviation).

**1L index exclusions.** Protocol s7.2.1.1 bars panobinostat and elotuzumab
from setting the 1L index, and only the cohort build can apply that: set
`NDMM_INDEX_EXCLUDED_ABBRS` in `ndmm/config.csv` to the code list's
abbreviations for both, with `|` between entries (`ndmm/README.md` has the
details). The study package reads what the cohort build recorded and stops on
a cohort that barred less (`COHORT_INDEX_EXCLUSIONS` in `variables/config.csv`).

**Open questions.** `variables/OPEN_QUESTIONS.md` lists every protocol
question still with the study team and the reading this build takes meanwhile.
Each reading is recorded on the run itself, in `S_RUN_METADATA`, so a number
can always be traced to the assumption behind it.

**Which LOT run step 3 will read.** It refuses a LOT run that finished on or
before `LOT_RULES_EPOCH` (shipped `2026-09-22`, the date the line rules last
changed; compared by calendar date, so a run finished on that day is refused
too), so a LOT run built before then has to be rebuilt. `LOT_CODE_MD5` is
blank and checks nothing; set it to the `LOT_RUN_METADATA.CODE_MD5` of the LOT
run the study team approved and step 3 refuses a run built by any other code.
`S_RUN_METADATA` records the floor applied (`LOT_RULES_EPOCH`) and the
fingerprint of the LOT run read (`LOT_CODE_MD5`). Neither check covers the code
lists: each LOT run records the lists it read, with their digests, in
`<prefix>LOT_CODELIST_METADATA`, so a changed list shows when two runs are
compared but is not refused.

**A prefix reused across package versions.** Inserts are positional, so an
`S_*` table already under the prefix with different columns from the ones this
package declares stops the run rather than taking values into the wrong
columns:

```
Error: SCHEMA ERROR: <catalog>.<schema>.s223926_S_COHORT exists with a
different shape.
```

Either drop what the old version left:

```sql
SHOW TABLES IN <catalog>.<schema> LIKE 's223926_*';   -- then DROP each
```

or give this run a prefix of its own, `OBJECT_PREFIX=s223926b_`, and carry the
same value into step 4 as `TFLS_PREFIX` and into the dashboard. Nothing is
lost either way — every `S_*` table is rebuilt from steps 1 and 2.

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
# 1. the cohort and its attrition.  Writes $COHORT and ndmm_NDMM_ATTRITION.
#    The prefix is POSITIONAL (or OBJECT_PREFIX) and must end in '_'.
CODELIST_DIR=$CL DATABRICKS_PWD="$DATABRICKS_PWD" PROJECT_WORK_SCHEMA=$SCHEMA \
  Rscript ndmm/build.R ndmm_

# 2. lines of therapy.  Cohort table and prefix are POSITIONAL
#    (or INPUT_COHORT_TABLE and OBJECT_PREFIX).
CODELIST_DIR=$CL DATABRICKS_PWD="$DATABRICKS_PWD" PROJECT_WORK_SCHEMA=$SCHEMA \
  Rscript lot/engine/build.R $COHORT ndmm_

# 3. the study's cohorts, variables and released tables.
#    INPUT_COHORT_TABLE and OBJECT_PREFIX are REQUIRED - the run stops
#    naming whichever is missing before it opens a connection.
DATABRICKS_PWD="$DATABRICKS_PWD" PROJECT_WORK_SCHEMA=$SCHEMA CODELIST_DIR=$CL \
  INPUT_COHORT_TABLE=$COHORT OBJECT_PREFIX=s223926_ \
  LOT_PREFIX=ndmm_ COHORT_PREFIX=ndmm_ \
  Rscript variables/build.R

# ...or print the plan and stop. No driver, no warehouse, nothing read.
DRY_RUN=TRUE INPUT_COHORT_TABLE=$COHORT OBJECT_PREFIX=s223926_ \
  Rscript variables/build.R
```

**Step 3 needs three prefixes.** `OBJECT_PREFIX` is where the study run
WRITES; `LOT_PREFIX` and `COHORT_PREFIX` are where it READS what steps 2 and 1
wrote. Each read prefix defaults to `OBJECT_PREFIX`, which is right only when
one prefix built everything — the commands above do not, so both are named.
Leave `COHORT_PREFIX` out and the run looks for the cohort build's status and
metadata under the study prefix: the lineage check stops on "no cohort build
status could be found", and the upstream-settings and index-exclusion checks
are logged as unverified rather than made:

```
upstream settings unverified: could not read <catalog>.<schema>.s223926_NDMM_RUN_METADATA
WARNING: whether the cohort build barred panobinostat and elotuzumab from
         setting the 1L index is unverified
```

Set the prefix rather than `LOT_ALLOW_UNPROVEN_LINEAGE=TRUE`: that waiver
exists for a lineage that could not be proven, and it would carry the run past
exactly this message.

```bash
# 4. the requested table shells - from the folder holding TFLS/ and variables/
TFLS_SOURCE=warehouse TFLS_PREFIX=s223926_ PROJECT_WORK_SCHEMA=$SCHEMA \
  TFLS_PACKAGE_DIR=variables \
  DATABRICKS_PWD="$DATABRICKS_PWD" Rscript TFLS/run_tfls.R

# 5. the dashboard — snapshot for a shared deployment, then the App.
#    Each scenario IS a step-3 run, so it needs what step 3 was given; the
#    grid adds only OBJECT_PREFIX and the question it changes.
DATABRICKS_PWD="$DATABRICKS_PWD" PROJECT_WORK_SCHEMA=$SCHEMA CODELIST_DIR=$CL \
  INPUT_COHORT_TABLE=$COHORT LOT_PREFIX=ndmm_ COHORT_PREFIX=ndmm_ \
  Rscript dashboard/jobs/build_scenarios.R
DASH_SOURCE=snapshot DASH_SNAPSHOT_DIR=/mnt/data/NDMM bash dashboard/app.sh
```

**Step 5 runs step 3 again, once per row of `dashboard/scenarios.csv`,** so
the settings on step 3's line are given again. Without the cohort table or
either read prefix the Job stops before building anything and names what is
missing. Without `CODELIST_DIR` every module whose list is still the shipped
blank template is left out of every scenario. Anything else step 3 was given —
`LOT_CODE_MD5`, `MODULES`, `SKIP_MODULES` — goes on this line too.
`dashboard/DEPLOY_DOMINO.md` has the Domino Job and App setup and the
deployment controls that are **not** in the code.

**Connection and schema.** Every stage connects over the ODBC DSN in
`DATABRICKS_DSN` (default `RWDE`) with `DATABRICKS_PWD`; TFLS and the
dashboard use the study package's own `connect_db()` rather than one of their
own. All of them read the same names: `PROJECT_WORK_SCHEMA` (or the Domino
user's own schema where it is unset), `DATABRICKS_CATALOG` (default
`hive_metastore`) and `INPUT_COHORT_TABLE`. `TFLS_*` and `DASH_*` names exist
only for a fill or a page that has to look elsewhere. The study run also takes
`WORK_SCHEMA`, ahead of `PROJECT_WORK_SCHEMA`: it moves both the schema its
`S_*` tables are written into and the one it reads the cohort and LOT tables
from. The fill and the dashboard resolve the schema in the study run's order
and accept `catalog.schema` as it does; set only `PROJECT_WORK_SCHEMA`, as the
commands above do, and every stage reads the same schema.

**Keep the variables inline per command**, as above. `MAX_LOT` and
`CENSOR_AT_DISENROLLMENT` are read by steps 2 and 3 under the same name with
deliberately different defaults (`5` and `4`; `FALSE` and `TRUE`), so an
`export` silently moves one of them off its intended value.

---

## The run log

Steps 1, 2 and 3 each write one when started from their `build.R`, and it
holds everything the run says: its log lines, the QC and diagnostic tables it
prints, its warnings and messages, and - as an `ERROR:` line - the reason it
stopped, if it did. The console shows the same run; the file is the one to
send.

It goes to `PIPELINE_LOG_FILE` if that is set, and otherwise to
`pipeline_run_<time>_<pid>.log` under `OUTPUT_DIR`, which defaults to
`/mnt/artifacts/results` - the folder Domino keeps as a run's results. The run
prints the path when it starts. If that folder cannot be written it says so
and falls back to R's temporary folder, which R deletes when the process ends,
so copy the file out before then; if a named `PIPELINE_LOG_FILE` cannot be
written it says so once and logs to the console only. To keep one file across
all three steps, set `PIPELINE_LOG_FILE` - the one variable it is safe to
`export`, since it names a file rather than a rule:

```bash
export PIPELINE_LOG_FILE=/mnt/artifacts/results/run_$(date +%Y%m%d_%H%M%S).log
```

Step 4 and the dashboard write no run log of their own; step 3's `DRY_RUN`
writes none either.

The log opens once a step has loaded its code and `config.csv`, since those
define the logger and can say where the log goes. A step that fails *while
loading* - a file it cannot source, a `config.csv` it cannot read - stops before
there is a log, so that reason is on the console only.

## Checking it before you point it at the warehouse

Every suite runs offline — no warehouse, no driver, no Shiny — and exits
non-zero on any failure.

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

What they need:

- **Base R**, plus **`glue`** for the cohort's own runner, the two LOT engine
  suites and melphalan.
- **`python3` with `duckdb` and `sqlglot`** for the suites that execute the
  SQL they emit against fixtures — the variables package, LOT QC's two and
  melphalan.
- **`survival`** for the dashboard suite's Kaplan-Meier cross-check against a
  second implementation.

**A suite that could not run part of itself does not exit clean.** Every suite
ends with `N passed, N failed, N skipped`, names each skipped block and what
was missing, and exits non-zero when anything was skipped. To accept an
incomplete run deliberately (a machine without `duckdb`, say), set
`ALLOW_SKIPPED_TESTS=TRUE`; the skips are still printed.

The app needs `shiny`; a warehouse run needs `DBI`, `odbc` and `glue`.

---

## Disclosure

Counts are suppressed below a floor of **25** patients, the protocol's, and the
floor may only rise — never fall. The study package's release module writes an
`S_*_RELEASE` copy of each of seven aggregated tables (`SUPPRESSION_SPEC` in
`variables/R/registry.R`) with every cell under the floor withheld, and records in `S_RUN_METADATA` (`RELEASE_RECOVERABLE`, and the
tables it is about in `RELEASE_RECOVERABLE_TABLES`) any group where one
withheld cell is still the group's total less the published rest. It does not
regroup; that is the analyst's call. The snapshot job refuses to export such a
run, the dashboard refuses to show those tables, and the shell runner refuses
to fill from them; each has one named override that says on the run that it
was set. The shell runner also closes every sum its own tables draw
(`TFLS/README.md` "Disclosure").

Read `dashboard/DEPLOY_DOMINO.md` under **Deployment controls** before sharing
anything this produces. A snapshot holds patient-level tables and is as
sensitive as the warehouse; the shell output in `TFLS/out/` is the artefact
meant to be shared, after disclosure review.

---

## Which doc answers what

| question | doc |
|---|---|
| how the cohort is built, what it writes, every setting | `ndmm/README.md` |
| the cohort's inclusion and exclusion rules | `ndmm/RULES.md` |
| why each cohort rule reads the way it does, and what is pending sign-off | `ndmm/DECISIONS.md` |
| what each file of the cohort build does | `ndmm/FILES.md` |
| the LOT packages, how to run them and their checks | `lot/CONTENTS.md` |
| every LOT rule, as a reference | `lot/LOT_RULES.md` |
| every LOT rule, with a worked patient timeline | `lot/LOT_RULES_EXPLAINED.md` |
| what each file of `lot/` does | `lot/FILES.md` |
| moving the LOT engine to another data source | `lot/PORTING.md` |
| the protocol, the cohorts, what the protocol does not yet specify | `variables/README.md` |
| the study package's files, modules and how to run it | `variables/CONTENTS.md` |
| what each module computes | `variables/MODULES.md` |
| the eligibility rules as the protocol states them | `variables/IE_CRITERIA.md` |
| which of them this build applies, where, and how to change one | `variables/IE_CRITERIA_APPLIED.md` |
| every variable the protocol asks for | `variables/VARIABLES.md` |
| where each rule and variable comes from in Optum | `variables/DATA_MAPPING.md` |
| the code check against the protocol, requirement by requirement | `variables/CONFORMANCE.md` |
| the questions still with the study team, and the reading taken meanwhile | `variables/OPEN_QUESTIONS.md` |
| which code lists are needed, present and outstanding | `variables/CODELISTS.md` |
| the shape of each shipped code list | `variables/CODELISTS.md` §4 |
| the table shells: filling them, editing them, their disclosure rules | `TFLS/README.md` |
| the app: its tabs, controls and where its numbers come from | `dashboard/DASHBOARD.md` |
| deploying the Job and the App on Domino, and the deployment controls | `dashboard/DEPLOY_DOMINO.md` |
