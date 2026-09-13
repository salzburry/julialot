# What is in this folder

GSK study **223926** (belantamab mafodotin, NDMM/RRMM), against Optum
Clinformatics Data Mart V9.0. This folder turns a finished lines-of-therapy run
into the study's analytical cohort and its variables.

Three folders sit side by side:

| folder | what it does |
|---|---|
| `ndmm_study_updated/` | **this folder** - the cohorts, the variables, the released tables |
| `lot/` | the lines-of-therapy engine that produces the lines this reads |
| `dashboard/` | the R Shiny app that shows what both produced |

They have to stay siblings. The dashboard finds this package at
`../ndmm_study_updated/study223926` and the engine at `../lot/engine`; nothing
uses an absolute path.

---

## Start here

| read this | for |
|---|---|
| `README.md` | the protocol, the cohorts, and what the protocol does not yet specify |
| `IE_CRITERIA_APPLIED.md` | which eligibility rules are applied, by whom, and how to change them |
| `study223926/MODULES.md` | what each module computes |
| `OPEN_QUESTIONS.md` | every question still open with the study team, and the reading this build takes meanwhile |

---

## The package — `study223926/`

The code. Self-contained: it reads the cohort table and the LOT tables, and
writes only its own `S_*` tables.

| path | what it is |
|---|---|
| `build.R` | the entry point. `Rscript build.R` |
| `config.csv` | every setting, with what each one does. The environment beats the file |
| `R/registry.R` | what may be selected — the cohorts, the modules, their dependencies and outputs |
| `R/config_223926.R` | settings resolution, the contract check, and the readings the run records |
| `R/db_utils_223926.R` | the Spark session, statement splitting, retries, schema guards |
| `R/windows.R` | every period the protocol defines, as SQL. Baseline, follow-up, treatment period, the time-to-event analysis set |
| `R/person_time.R` | person-time and the acute-event washout chain |
| `R/codelists.R` | reading and checking the code lists, and the manifest a run records |
| `R/lineage.R` | which LOT run - and which build of it - these numbers rest on, and whether it can be vouched for. Checked when the run starts and again before it is recorded complete, so a LOT rebuild landing in between fails the run rather than being attested |
| `R/load_inputs.R` | settings from `config.csv` and the environment |
| `R/run_223926.R` | the runner: resolve the plan, refuse what it cannot vouch for, walk the modules |
| `R/modules/` | one file per module, in the order they run |
| `codelists/` | the code lists this package ships. Production overrides the directory |
| `tests/` | 417 checks. `Rscript tests/run_tests.R` |

### The modules

| module | writes |
|---|---|
| `spine` | `S_SPINE` — one row per patient and line |
| `cohorts` | `S_COHORT` — membership, criterion by criterion |
| `attrition` | `S_ATTRITION` — the funnel, one step per criterion |
| `periods` | `S_PERIODS`, `S_LOT_PERIODS` |
| `demographics` | `S_DEMOGRAPHICS` |
| `comorbidity` | `S_COMORBIDITY`, `S_COMORB_SUBGROUP`, `S_FRAILTY` |
| `soc` | `S_SOC` |
| `safety` | `S_SAFETY_EVENTS`, `S_SAFETY_COUNTED`, `S_SAFETY_RATES` |
| `hcru` | `S_HCRU_EVENTS`, `S_HCRU_RATES` |
| `malignancy` | `S_MALIGNANCY`, `S_MALIGNANCY_DATES`, `S_MALIGNANCY_RATES` |
| `tte` | `S_TTE` |
| `patterns` | `S_PATTERNS`, `S_SWITCH`, `S_TX_ATTRITION` |
| `release` | `S_*_RELEASE` — the same tables with cells under 25 patients suppressed |

**The `_RELEASE` tables are the released aggregates** — the ones with every
cell under 25 patients suppressed. The raw ones keep their counts so QC can
still read what produced a rate.

Two things read the raw tables outside the warehouse, and both are controlled
outputs rather than releases: the QC report, and the dashboard's snapshot job,
which exports every `S_*` table and the LOT tables to a directory the app
reads. The app itself shows the `_RELEASE` form where one exists and applies
its own floor on top; the snapshot directory is patient-level data and is
handled as such.

---

## The reference documents

| file | what it settles |
|---|---|
| `IE_CRITERIA.md` | every eligibility rule the protocol states, quoted, with its section |
| `IE_CRITERIA_APPLIED.md` | which of them this build applies, where, and how to change one |
| `DATA_MAPPING.md` | each rule and variable turned into Optum tables and columns |
| `VARIABLES.md` | every variable the protocol asks for and where it comes from |
| `CODELISTS.md` | which code lists are needed, which are present, and which are still outstanding |
| `OPEN_QUESTIONS.md` | the questions still with the study team, each with the reading this build takes |
| `VERSION_DIFF.md` | what changed between the earlier protocol and the August 2026 one |
| `BUILD_DELTA.md` | what the cohort build has to change to match this protocol |

`ie_criteria.csv`, `variables.csv` and `optum_cdm_fields.csv` are the same
content as tables, for anyone who would rather filter than read.

---

## The working files

`RUN_ONCE.sql`, `RUN_ONCE_2.sql` and `RUN_ONCE_3.sql` are three rounds of
profiling queries against the warehouse: which columns exist, how they are
coded, how complete they are. They are not part of a build and nothing runs
them automatically. They are kept because the answers in `DATA_MAPPING.md` and
`OPEN_QUESTIONS.md` came from them.

---

## Running it

```bash
# print the plan and stop - no warehouse needed
DRY_RUN=TRUE INPUT_COHORT_TABLE=ndmm_NDMM_COHORT OBJECT_PREFIX=s223926_ \
  Rscript build.R

# a real build, over the Databricks ODBC DSN the cohort and LOT builds use
DATABRICKS_PWD=... INPUT_COHORT_TABLE=ndmm_NDMM_COHORT OBJECT_PREFIX=s223926_ Rscript build.R
```

`DRY_RUN=TRUE` resolves every setting, prints the cohorts, the modules and each
open question's reading, and stops before opening a connection. It is the
fastest way to see what a run *would* do.

```bash
Rscript tests/run_tests.R      # 417 checks, no warehouse
```

The suite runs the modules without a warehouse, executes the SQL they emit
against fixtures, and checks the numbers that come back. It also starts
`build.R` in a fresh process, because a package that only works in an
already-loaded session is a package that does not work.
