# NDMM study 223926 - the study package

Stage 3 of the study pipeline. It reads the cohort table (`ndmm/`) and a
finished lines-of-therapy run (`lot/`) and writes the study's cohorts, its
variables and the released `S_*` tables. It builds no line and no MM cohort of
its own, so it can be re-run against a finished LOT run as often as needed.

```
                cohort build          lot/engine/build.R        build.R
raw Optum CDM ──────────────► NDMM_COHORT ──────────► LOT_LONG_FINAL ──────────► S_*
```

## The study at a glance

| | |
|---|---|
| GSK study | **223926** · asset GSK2857916, Belantamab Mafodotin (Blenrep) |
| title | *Unmet Needs and Rates of Key Background Safety Events of Interest Relating to Treatment Use among Newly Treated and Relapsed/Refractory Patients with Multiple Myeloma* |
| accountable | Epidemiology, Oncology |
| classification | Non-PASS · Tier 2 · secondary data collection · no safety objective |
| data source | Optum Clinformatics Data Mart (CDM) V9.0 |
| classification marking | Critical and Sensitive Information (CSI) |
| study period | 01 Jan 2018 → 31 Mar 2026 (`OPEN_QUESTIONS.md` Q1) |

| cohort | who | index | eligibility |
|---|---|---|---|
| 1L (NDMM) | all patients initiating 1L therapy | 1L start, ≥ 01 Jan 2019 | I1-I5, X1-X4 |
| 2L (RRMM) | nested subset of 1L initiating 2L | 2L start | + received 2L, 12-month CE before it |
| 3L (RRMM) | nested subset of 2L initiating 3L | 3L start | + received 3L, 12-month CE before it |
| Secondary 2L (RRMM) | **not nested** - all 2L initiators | 2L start, ≥ 01 Jan 2020 | as 1L except the index; prior malignancy permitted |

There is no 4L cohort - only a 4L start date and 4L regimen. The protocol's
feasibility count expects **10,514** 1L, **5,179** 2L and **3,127** 3L patients
before study criteria. The criteria, who applies each and how to change them
are `IE_CRITERIA.md`. The secondary 2L cohort cannot be built from the bundled
cohort table (`MODULES.md` "The secondary 2L cohort's wide input"). Cohort
settings are changed on the cohort side, `../ndmm/README.md` "Settings".

**What the protocol does not yet specify.** Annexes 2 to 7 are stand-alone
documents and none has been issued: the SOC regimen categorisation (Annex 2),
the outcome code lists (Annex 3), the table and figure shells (Annexes 4 and 5),
the LOT algorithm (Annex 6) and the claims-based frailty algorithm (Annex 7).
Annexes 2 and 3 are code lists - the SOC, safety, HCRU and malignancy outcomes
cannot be computed without them. `OPEN_QUESTIONS.md` Q15 is the ask. Annex
numbers follow the body text, which agrees with Annex 1 (Q20).

**The five readings most likely to change a count** (`OPEN_QUESTIONS.md` "What
each decision is worth" ranks them all):

1. **Disenrollment censors follow-up** (`CENSOR_AT_DISENROLLMENT=TRUE`, the
   protocol's wording); the LOT engine's primary reading does not censor (Q13).
2. **Which route makes a hospitalisation MM-related** - the two differ by a
   factor of two (Q27).
3. **The outpatient MM diagnosis code set** - strict or broad (Q2).
4. **How an emergency visit is identified** - the three claims constructions
   differ by 37% (Q11).
5. **Bone metastasis excludes** - `C79.51` is a metastatic cancer to the rule
   and myeloma bone disease to a haematologist; the cohort build excludes on it
   (`IE_CRITERIA.md` "X2. Another cancer in the 1L baseline").

## What is in the folder

The five study folders stay siblings: the dashboard finds this package at
`../variables`, the engine at `../lot/engine` and the shells at `../TFLS`; the
shell runner finds this package by `TFLS_PACKAGE_DIR`. Nothing in this package
reads a file outside it (a test asserts that no path function in any R file
reaches out). The two things it needs that are not files are the warehouse and
the production code-list directory.

| path | what it is |
|---|---|
| `build.R` | the entry point |
| `config.csv` | every setting as `name,value,description`, except `MM_HOSP_POSITION`, which is read from the environment only (default `confinement`, Q27) |
| `R/registry.R` | what may be selected - cohorts, modules, their dependencies and outputs, the suppression spec - and the selection logic |
| `R/config_223926.R` | settings resolution and validation, `CONTRACT`, and the readings a run records |
| `R/contract.R` | what the package writes, as data: one row per table, the copy TFLS holds |
| `R/db_utils_223926.R` | the connection, statement splitting, retries, table naming, schema guards, the run log |
| `R/windows.R` | every period the protocol defines, as SQL |
| `R/person_time.R` | the counting rules: chronic-once, prior history, the acute washout chain |
| `R/codelists.R` | loading and checking the code lists, the preflight, the manifest a run records |
| `R/lineage.R` | which LOT run - and which cohort attempt behind it - the numbers rest on, checked at the start and again before the run is recorded complete |
| `R/load_inputs.R` | settings from `config.csv` and the environment |
| `R/run_223926.R` | the runner: resolve the plan, refuse what it cannot vouch for, walk the modules, write `S_RUN_METADATA` |
| `R/modules/` | one file per module, in run order. Nothing else defines a clinical rule |
| `codelists/` | the shapes of the eleven code lists, with no codes |
| `tests/` | the test suite and its synthetic fixtures |

| document | what it settles |
|---|---|
| `README.md` | this page: the study, the folder, how to run it |
| `MODULES.md` | how the package works: modules, selection, the input cohort table, what it refuses, the output prefix, suppression and release, what a run records |
| `IE_CRITERIA.md` | every eligibility rule the protocol states, who applies it, the funnel, and how to change a date, a window or a criterion |
| `VARIABLES.md` | every variable, the counting rules, the time-to-event conventions and the strata |
| `DATA_MAPPING.md` | the Optum CDM tables and columns each rule and variable reads, and every code list |
| `OPEN_QUESTIONS.md` | the questions open with the study team, the reading taken meanwhile, the answered ones, and the known deviations and gaps |

## Running it

```bash
# print the plan and stop - no warehouse, no database driver needed
DRY_RUN=TRUE INPUT_COHORT_TABLE=ndmm_NDMM_COHORT OBJECT_PREFIX=s223926_ \
  Rscript build.R

# a real build, over the Databricks ODBC DSN the cohort and LOT builds use
DATABRICKS_PWD=... INPUT_COHORT_TABLE=ndmm_NDMM_COHORT OBJECT_PREFIX=s223926_ \
  Rscript build.R

# one module; 2L is nested in 1L, so 1L comes too
MODULES=safety COHORTS=1L,2L Rscript build.R
```

**Settings.** The environment beats `config.csv`: a row of the file is applied
only where that variable is unset. `INPUT_COHORT_TABLE` (the cohort the LOT run
was built over) and `OBJECT_PREFIX` are required. `COHORT_PREFIX` and
`LOT_PREFIX` name the cohort and LOT builds' prefixes where they differ from
this run's. A value that becomes a name in SQL must be letters, digits and
underscore. `DRY_RUN=TRUE` resolves every setting, prints the cohorts, the
modules (and any left out, with the reason), the tables it would write, the
code lists and each open question's reading, then stops before opening a
connection.

**The connection.** `SPARK_METHOD` picks it. `odbc`, the default, is the
Databricks ODBC driver through DBI on the DSN in `DATABRICKS_DSN` (default
`RWDE`) with the password in `DATABRICKS_PWD` - the environment the cohort and
LOT builds connect with. `DATABRICKS_PWD` is read from the environment only (a
value in `config.csv` is ignored); keep `DATABRICKS_TOKEN` there too. The other
modes are sparklyr sessions: `databricks` attaches to the session of the
cluster the script runs on, with no DSN or password; `databricks_connect`
drives a named cluster from outside and is the only mode that needs
`DATABRICKS_HOST`, `DATABRICKS_TOKEN` and `SPARK_CLUSTER_ID`; `local` is a smoke
test. Every statement is SQL text, so the modes differ only in the connection
layer; over ODBC a code list is staged as one VALUES statement behind a
temporary view.

**The schema** a run writes into, and reads the cohort and LOT tables from,
resolves as the cohort and LOT builds resolve theirs: `WORK_SCHEMA`, then
`PROJECT_WORK_SCHEMA`, then `DOMINO_USER_NAME`, then
`DOMINO_STARTING_USERNAME`, else the session's current schema. Give the schema
alone - `usr00000`, not `hive_metastore.usr00000` - though the second form is
accepted when the catalog is `DATABRICKS_CATALOG` (default `hive_metastore`).

**Code lists.** `CODELIST_DIR` blank means this folder's own `codelists/`,
which carries no codes: there the modules that need a list are left out by name
and the rest run. On production set it to the real directory,
`CODELIST_DIR=/mnt/code/codelist` (`DATA_MAPPING.md` "11. Code lists").

**The run log.** A run started from `build.R` writes its log to `OUTPUT_DIR`
(`/mnt/artifacts/results` by default, the folder Domino keeps as a run's
results) as `pipeline_run_<time>_<pid>.log`; `PIPELINE_LOG_FILE` names an exact
file instead. With neither writable it falls back to R's temporary folder and
says so, because that folder is deleted when the process exits. A dry run
writes no log.

**A reused prefix** written by a different version of this package stops the
run before anything is cleared; drop its `S_*` tables or use a fresh
`OBJECT_PREFIX` (`MODULES.md` "The output prefix").

## The tests

```bash
Rscript tests/run_tests.R      # no warehouse
```

The suite runs every module for every cohort without a warehouse, parses every
statement they emit in the Spark dialect, executes them against the synthetic
fixtures in `tests/fixtures/`, and checks the numbers that come back against
`tests/expectations.py` (each derived by hand in `tests/fixtures/EXPECTED.md`),
then runs the whole script again and checks nothing doubled. It also starts
`build.R` in a fresh process. The fixtures carry filled miniatures of every
code list - dummy codes for the tests, not codes to run a study on; nothing
outside `tests/` reads them.

Parsing and executing the SQL needs the Python packages sqlglot and duckdb.
Without them those checks report `SKIP` and the rest run unchanged.

What the suite cannot check is a number from the CDM itself: the list-driven
modules have not run against the warehouse, because their code lists do not
exist yet, and a fixture that agrees with the code is not the warehouse
agreeing with it.
