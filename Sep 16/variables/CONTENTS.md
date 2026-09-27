# What is in this folder

GSK study **223926** (belantamab mafodotin, NDMM/RRMM), against Optum
Clinformatics Data Mart V9.0. This folder is stage 3: it reads the cohort
table and a finished lines-of-therapy run and writes the study's cohorts, its
variables and the released `S_*` tables. It builds no line and no MM cohort of
its own, so it can be re-run against a finished LOT run as often as needed.
`README.md` has the protocol and the cohorts at a glance.

The delivery's folders have to stay siblings. The dashboard finds this package
at `../variables`, the engine at `../lot/engine` and the shells at `../TFLS`;
the shell runner finds this package by `TFLS_PACKAGE_DIR`. Nothing uses an
absolute path.

---

## Start here

| read this | for |
|---|---|
| `README.md` | the protocol, the cohorts, what the protocol does not yet specify |
| `IE_CRITERIA_APPLIED.md` | which eligibility rules are applied, by whom, and how to change them |
| `MODULES.md` | how the package works: the modules, what makes it selectable, what it refuses, the output prefix |
| `OPEN_QUESTIONS.md` | every question still open with the study team, the reading this build takes meanwhile, and each setting |
| `CONFORMANCE.md` | the code checked requirement by requirement against the protocol, the Optum CDM V9.0 dictionary and the Optum business rules |

The reference documents:

| file | what it settles |
|---|---|
| `IE_CRITERIA.md` | every eligibility rule and follow-up concept the protocol states, quoted, with its section |
| `VARIABLES.md` | every variable the protocol asks for, the counting rules, and where each comes from |
| `DATA_MAPPING.md` | the Optum CDM tables and columns each rule and variable reads |
| `CODELISTS.md` | every code list read, its columns and code types, and which are still to be authored |

`ie_criteria.csv`, `variables.csv` and `optum_cdm_fields.csv` are the same
content as tables, for anyone who would rather filter than read.

`RUN_ONCE.sql`, `RUN_ONCE_2.sql` and `RUN_ONCE_3.sql` are profiling queries
against the warehouse: which columns exist, how they are coded, how complete
they are. They are not part of a build and nothing runs them. The measured
numbers in `DATA_MAPPING.md` and `OPEN_QUESTIONS.md` come from them.

---

## The package

Self-contained: nothing in it reads a file outside this folder, and a test
asserts that no path function in any R file reaches out. It carries its own
code-list shapes, settings and tests. The two things it needs that are not
files are the warehouse and the production code-list directory.

| path | what it is |
|---|---|
| `build.R` | the entry point. `Rscript build.R` |
| `config.csv` | every setting as `name,value,description` (all but `MM_HOSP_POSITION`, which is environment-only). The environment beats the file |
| `R/registry.R` | what may be selected — the cohorts, the modules, their dependencies and outputs — and the selection logic |
| `R/config_223926.R` | settings resolution and validation, `CONTRACT`, and the readings a run records |
| `R/contract.R` | what the package writes, as data: one row per table, the copy TFLS ships |
| `R/db_utils_223926.R` | the connection (ODBC through DBI, or a sparklyr session), statement splitting, retries, table naming, schema guards, the run log |
| `R/windows.R` | every period the protocol defines, as SQL: baseline, follow-up, treatment period, the time-to-event analysis set |
| `R/person_time.R` | the counting rules: same-day collapse, chronic-once, the acute washout chain |
| `R/codelists.R` | reading and checking the code lists, the preflight, and the manifest a run records |
| `R/lineage.R` | which LOT run - and which build and cohort attempt behind it - these numbers rest on, and whether it can be vouched for; checked when the run starts and again before it is recorded complete |
| `R/load_inputs.R` | settings from `config.csv` and the environment |
| `R/run_223926.R` | the runner: resolve the plan, refuse what it cannot vouch for, walk the modules, write `S_RUN_METADATA` |
| `R/modules/` | one file per module, in the order they run. Nothing else defines a clinical rule |
| `codelists/` | the code-list shapes this package ships, with no codes (`codelists/README.md`) |
| `tests/` | the suite. `Rscript tests/run_tests.R` |

The modules and the tables each writes are listed in `MODULES.md` "Modules".
**The `_RELEASE` tables are the released aggregates** — every cell under 25
patients suppressed; the raw `S_*` tables keep their counts for QC
(`MODULES.md` "Suppression is applied in one place").

---

## Running it

```bash
# print the plan and stop - no warehouse needed
DRY_RUN=TRUE INPUT_COHORT_TABLE=ndmm_NDMM_COHORT OBJECT_PREFIX=s223926_ \
  Rscript build.R

# a real build, over the Databricks ODBC DSN the cohort and LOT builds use
DATABRICKS_PWD=... INPUT_COHORT_TABLE=ndmm_NDMM_COHORT OBJECT_PREFIX=s223926_ \
  Rscript build.R

# one module; 2L is nested in 1L, so 1L comes too
MODULES=safety COHORTS=1L,2L Rscript build.R
```

`INPUT_COHORT_TABLE` (the cohort the LOT run was built over) and
`OBJECT_PREFIX` are required. `COHORT_PREFIX` and `LOT_PREFIX` name the cohort
and LOT builds' prefixes where they differ from this run's.

`DRY_RUN=TRUE` resolves every setting, prints the cohorts, the modules and each
open question's reading, and stops before opening a connection. It needs no
database driver installed, and it is the fastest way to see what a run
*would* do.

A run started from `build.R` writes its log to `OUTPUT_DIR`
(`/mnt/artifacts/results` by default, the folder Domino keeps as a run's
results) as `pipeline_run_<time>_<pid>.log`; `PIPELINE_LOG_FILE` names an exact
file instead. A dry run writes none.

**The connection.** `SPARK_METHOD` picks it, and `odbc` is the default: the
Databricks ODBC driver through DBI, on the DSN in `DATABRICKS_DSN` (default
`RWDE`) with the password in `DATABRICKS_PWD` - the same environment the cohort
and LOT builds connect with. `DATABRICKS_PWD` is read from the environment
only (a value in `config.csv` is ignored), and `DATABRICKS_TOKEN` belongs there
too. The other three modes are sparklyr sessions:
`databricks` attaches to the session of the cluster the script runs on, with
no DSN and no password; `databricks_connect` drives a named cluster from
outside and is the only mode that needs `DATABRICKS_HOST`, `DATABRICKS_TOKEN`
and `SPARK_CLUSTER_ID`; `local` is a smoke test. Every statement is SQL text,
so the modes differ only in the connection layer; over ODBC a code list is
staged as one VALUES statement behind a temporary view.

**The schema** a run writes into, and reads the cohort and LOT tables from,
resolves as the cohort and LOT builds resolve theirs: `WORK_SCHEMA`, then
`PROJECT_WORK_SCHEMA`, then `DOMINO_USER_NAME`, else the session's current
schema. Give the schema alone - `usr00000`, not `hive_metastore.usr00000` -
though the second form is accepted when the catalog is `DATABRICKS_CATALOG`.

**Code lists.** `CODELIST_DIR` blank means this folder's own `codelists/`,
which carries no codes: there, the modules that need a list are left out by
name and the rest run. On production set it to the real directory
(`CODELISTS.md`).

**A reused prefix** written by a different version of this package stops the
run before anything is cleared; drop its `S_*` tables or use a fresh
`OBJECT_PREFIX` (`MODULES.md` "The output prefix").

### The tests

```bash
Rscript tests/run_tests.R      # no warehouse
```

The suite runs every module for every cohort without a warehouse, parses every
statement they emit in the Spark dialect, executes them against the synthetic
fixtures in `tests/fixtures/`, and checks the numbers that come back against
`tests/expectations.py` (each derived by hand in `tests/fixtures/EXPECTED.md`),
then runs the whole script again and checks nothing doubled. It also starts
`build.R` in a fresh process. The fixtures carry filled miniatures of every
code list - dummy codes for the tests, not codes to run a study on.

Parsing and executing the SQL needs the Python packages sqlglot and duckdb.
Without them those checks report `SKIP` and the rest run unchanged.
