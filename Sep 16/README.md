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
| 4 | `TFLS/` | the requested table shells, filled from stage 3 | `TFLS/out/` |
| 5 | `dashboard/` | the Domino app over a finished run, and the snapshot job that feeds it | — |

Start at `ndmm/README.md`, `lot/CONTENTS.md`, `variables/CONTENTS.md`,
`TFLS/README.md` and `dashboard/DASHBOARD.md` respectively.

**Stage 1 changes are contract edits, not environment overrides.**
`variables/BUILD_DELTA.md` section 0 lists every cohort setting the protocol
moves and says, for each, whether it is an environment variable or an edit to
`CONTRACT` in `ndmm/R/build_ndmm.R`. Two of them are edits — the cohort build
refuses a config that does not match its contract, deliberately, and there is
no override for that.

Dependencies run one way. `lot/` names no cohort and resolves nothing outside
itself; the stages after it read the tables a run wrote.

---

## Before the first run

**Code lists are not in here.** They are CSV files on production, read from
`CODELIST_DIR`, and nothing loads without them: a missing file, an unknown
filename, a missing column or an empty file stops the run and says which.
`variables/CODELISTS.md` lists every file, its required columns and
the code types it may carry, and marks the ones still to be authored.

**Warehouse settings** come from the environment, which beats `config.csv` in
each folder. `DATABRICKS_PWD` is read from the environment only — never from a
file, and no file here holds one.

**Open questions.** `variables/OPEN_QUESTIONS.md` lists every protocol
question still with the study team and the reading this build takes meanwhile.
Each reading is recorded on the run itself, in `S_RUN_METADATA`, so a number
can always be traced to the assumption behind it.

**The lines have changed, so an earlier LOT run is stale.** A defect in the
returning-drug rule (`lot/LOT_RULES.md` 4.8) is fixed in this build: where a
drug that folded into an earlier line returned again inside a line a transplant
or CAR-T opened, that line used to claim the return instead of ending on it.
Patients with that shape lose a line, so the attrition's progression rows and
every per-line variable downstream of them move. That is the correct answer,
not a regression - but it is a difference to expect rather than to discover in
the rebuilt QC summary.

So **step 2 has to be re-run before steps 3 to 5**, on the same cohort. Tables
built from the earlier run describe lines this code no longer produces.

`LOT_RUN_METADATA.CODE_MD5` is what tells an old run from a new one. It
fingerprints the engine's R, so a run built before this fix carries a different
one - no value is quoted here, because the fingerprint moves whenever the
engine does and a number in a document would go quietly stale. Read it off the
rebuilt run and compare.

It is recorded on every LOT run, and on every study run that reads one
(`S_RUN_METADATA.LOT_CODE_MD5`), so a table can always be traced back to the
code behind it. But it is only CHECKED where `LOT_CODE_MD5` is set: unset, it
checks nothing and a stale LOT run flows through in silence.

Step 3 refuses one by date as well, and that check is on by default. It stops
any LOT run that finished **on or before** `LOT_RULES_EPOCH`, which ships as
the date the rules last changed — so a run built before this fix is refused
whether or not anyone pinned a fingerprint. On or before, because the
comparison is by calendar date and a rule change lands at a time of day: a run
finished on that date cannot be placed either side of it, and the check refuses
what it cannot place. The cost is one day's runs; the alternative is reading a
superseded number in silence. Set it only to name a different floor:

```bash
LOT_RULES_EPOCH=2026-09-19    # shipped; a run finished on or before this stops
```

Whichever floor applied is recorded on the run, in
`S_RUN_METADATA.LOT_RULES_EPOCH`.

The shipped date is held to the engine beside it. The study suite fingerprints
`lot/engine` — its R and the settings it ships — and compares both to the
fingerprints the shipped epoch was set for, all three pinned as one value, so a
change to the rules fails that check until the date is moved to the date of the
change and the fingerprints re-pinned with it. The floor went stale twice before
that tie existed: each time, the engine changed and the date did not, and every
run built in between passed a check written to stop exactly those runs.

What the tie cannot see is the code lists. They live under `CODELIST_DIR` on the
platform rather than in this folder, so a rollup that moves a drug to another
agent moves lines without moving either fingerprint. Each run records the code
lists it read, in `LOT_CODELIST`; that is where such a change is caught, and it
is the same limit `LOT_CODE_MD5` has always had.

The two checks answer different questions. The epoch says WHEN a run executed
and everybody gets it; `LOT_CODE_MD5` says WHAT executed, exactly, and is
opt-in. A run built after the epoch by code you have not approved passes the
first and is caught only by the second. So after the
rebuild, read the new run's `CODE_MD5` and pin it - that is what makes step 3
stop on the wrong run instead of building on it.

```bash
# after step 2, from LOT_RUN_METADATA for the run you just built
LOT_CODE_MD5=<the 32 characters that run recorded>
```

`qc/run_lot_qc.R` on the rebuilt run is the confirmation: check `C5` reads zero.

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
#    The prefix is POSITIONAL and must end in '_'.
CODELIST_DIR=$CL DATABRICKS_PWD="$DATABRICKS_PWD" PROJECT_WORK_SCHEMA=$SCHEMA \
  Rscript ndmm/build.R ndmm_

# 2. lines of therapy.  Cohort table and prefix are POSITIONAL.
CODELIST_DIR=$CL DATABRICKS_PWD="$DATABRICKS_PWD" PROJECT_WORK_SCHEMA=$SCHEMA \
  Rscript lot/engine/build.R $COHORT ndmm_

# 3. the study's cohorts, variables and released tables.
#    INPUT_COHORT_TABLE and OBJECT_PREFIX are REQUIRED - the run stops
#    naming whichever is missing before it opens a connection.
DATABRICKS_PWD="$DATABRICKS_PWD" PROJECT_WORK_SCHEMA=$SCHEMA CODELIST_DIR=$CL \
  INPUT_COHORT_TABLE=$COHORT OBJECT_PREFIX=s223926_ LOT_PREFIX=ndmm_ \
  Rscript variables/build.R

# ...or print the plan and stop. No driver, no warehouse, nothing read.
DRY_RUN=TRUE INPUT_COHORT_TABLE=$COHORT OBJECT_PREFIX=s223926_ \
  Rscript variables/build.R

# 4. the requested table shells
TFLS_SOURCE=warehouse TFLS_PREFIX=s223926_ PROJECT_WORK_SCHEMA=$SCHEMA \
  TFLS_PACKAGE_DIR=variables \
  DATABRICKS_PWD="$DATABRICKS_PWD" Rscript TFLS/run_tfls.R

# 5. the dashboard — snapshot for a shared deployment, then the App
DATABRICKS_PWD="$DATABRICKS_PWD" PROJECT_WORK_SCHEMA=$SCHEMA \
  Rscript dashboard/jobs/build_scenarios.R
DASH_SOURCE=snapshot DASH_SNAPSHOT_DIR=/mnt/data/NDMM bash dashboard/app.sh
```

**One connection.** All five open the warehouse through one line of code -
the LOT engine's `DBI::dbConnect(odbc::odbc(), dsn = DATABRICKS_DSN, pwd =
DATABRICKS_PWD, timeout = 120)`, which the study package carries character for
character, and which TFLS and the dashboard reach by calling the study
package's `connect_db()` rather than having one of their own. And all five
read the same three facts under the LOT engine's names: `PROJECT_WORK_SCHEMA`
(or the Domino user's own schema where it is unset), `DATABRICKS_CATALOG` and
`INPUT_COHORT_TABLE`. So an environment that carried the cohort build carries
the LOT build, the study run, the fill and the dashboard's warehouse mode too; `TFLS_*` and
`DASH_*` names exist only for a fill or a page that has to look elsewhere.

The study run takes one name the other two do not: `WORK_SCHEMA`, ahead of
`PROJECT_WORK_SCHEMA`. It moves the whole of that run — the schema its `S_*`
tables are written into, and the schema it reads the cohort and LOT tables
from — so setting it points the run at one schema entirely. The fill and the
dashboard read those `S_*` tables, so they resolve the schema in the study
run's order rather than the LOT build's; set only `PROJECT_WORK_SCHEMA`, as
the commands above do, and the two orders are the same answer. All three
accept `catalog.schema` and read it as the study run does, the catalog
stripped when it matches. The
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

Each prints how many assertions it made. That number is not quoted in this
document, or in any other here: nothing reads a number in a document, so it
goes stale the next time a suite grows and then quietly misdescribes the thing
it was written to describe. Run them and read it off the run.

Installing `survival::` adds one assertion: the dashboard suite's Kaplan-Meier
cross-check, which is skipped without it — and a skipped block makes that suite
exit non-zero, because a run missing its executed blocks is not a clean run.
Base R except for **`glue`**, which four of the twelve need — the two LOT
engine suites through `tests/testutil.R`, melphalan, and the cohort's own
runner. The other eight load nothing. The app needs `shiny`; a warehouse run
needs `DBI`, `odbc` and `glue`.

Four of the suites (the variables package, LOT QC's two, and melphalan) additionally **execute** the
SQL they emit against fixtures where `python3` with `duckdb` and `sqlglot` is
present. The dashboard suite does the same with `survival`, which it uses
only to cross-check its own Kaplan-Meier against a second implementation.

The dashboard suite also needs **`survival`** for a complete run — without it
the Kaplan-Meier cross-check is skipped, the suite reports one skip and exits
non-zero, and its count is one lower.

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
