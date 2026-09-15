# NDMM study 223926

This folder turns the NDMM protocol into something a build can be written from:
the eligibility criteria, the variables, the Optum CDM mapping for each of them,
and the list of things still to be decided.

**Scope: this folder only.** The cohort build and the LOT engine are not edited
by this work. Where the protocol needs either of them to behave differently,
that is delivered as an environment override on a re-run, never as a change to
the build - `BUILD_DELTA.md` section 0 lists every one and shows it is already
read from the environment.

## The protocol

| | |
|---|---|
| GSK study | **223926** · asset GSK2857916, Belantamab Mafodotin (Blenrep) |
| title | *Unmet Needs and Rates of Key Background Safety Events of Interest Relating to Treatment Use among Newly Treated and Relapsed/Refractory Patients with Multiple Myeloma* |
| accountable | Epidemiology, Oncology |
| effective | 26 August 2026 |
| classification | Non-PASS · Tier 2 · secondary data collection · no safety objective |
| data source | Optum Clinformatics Data Mart (CDM) |
| classification marking | Critical and Sensitive Information (CSI) |

## Files

`CONTENTS.md` lists every file in this folder and what each is for. Read
`IE_CRITERIA.md` first; `IE_CRITERIA_APPLIED.md` says which of its rules this
build applies and how to change one. `OPEN_QUESTIONS.md` is what to send the
study team.

## The cohorts, in one table

| cohort | who | index | eligibility |
|---|---|---|---|
| 1L (NDMM) | all patients initiating 1L therapy | 1L start, ≥ 01 Jan 2019 | I1-I5, X1-X4 |
| 2L (RRMM) | nested subset initiating 2L | 2L start | + received 2L, 12-month CE before it |
| 3L (RRMM) | nested subset initiating 3L | 3L start | + received 3L, 12-month CE before it |
| Secondary 2L (RRMM) | **not nested** - all 2L initiators | 2L start, ≥ 01 Jan 2020 | same as 1L except the index, and prior malignancy is permitted |

There is no 4L cohort - only a 4L start date and 4L regimen. Expected sizes from the
protocol's own feasibility count (August 2026): **10,514** 1L, **5,179** 2L,
**3,127** 3L, before study criteria are applied.

## What the protocol does not yet specify

Annexes 2 to 7 are stand-alone documents and none has been issued: the SOC
regimen categorisation (Annex 2), the outcome code lists (Annex 3), the table
and figure shells (Annexes 4 and 5), the LOT algorithm (Annex 6) and the
claims-based frailty algorithm (Annex 7). **Annexes 2 and 3 are code lists -
nothing can be built without them.** `CODELISTS.md` §5 has the exact ask.

The Table 4 rows for Primary Objectives 1 and 2 are also incomplete.
`OPEN_QUESTIONS.md` Q15 lists what is outstanding.

> The protocol's contents list and its own Annex 1 **disagree about the annex
> numbers.** The contents list reads 3 TABLES, 4 FIGURES, 5 CODELISTS; Annex 1
> reads 3 Codelists, 4 Table shells, 5 Figures. The body text agrees with
> Annex 1 - §7.3.2 and §7.8.5 both cite **Annex 3** for code lists, and §7.8
> cites *"Annex 4 and Annex 5"* for the shells. **This folder uses the body's
> numbering.** `OPEN_QUESTIONS.md` Q20.

## Mapping to Optum

`DATA_MAPPING.md` turns each rule and variable into Optum CDM tables and
columns, and records where the deployed extract differs from the published
dictionary. The difference that matters most is `MEMBER_ENROLLMENT`: it carries
`STATE` and no `REGION`, so region is derived through a state crosswalk
(`OPEN_QUESTIONS.md` Q9).

## The five things most likely to change a count

1. **Study period start** - the text says 01 Jan 2018, both figures say 01 Jan 2016
   (`OPEN_QUESTIONS.md` Q1).
2. **1L index from 01 Jan 2019** - the cohort build uses 2017 today, and now has to
   bar panobinostat and elotuzumab as well as belantamab.
3. **Bone metastasis still excludes** - `C79.51` is a metastatic cancer to the rule and
   myeloma bone disease to a haematologist. The build knows and excludes anyway
   (`IE_CRITERIA.md` §6). The 30-day pairing window the protocol states is already what
   the build does.
4. **Follow-up is three different tests** - an eligibility test, an observation
   window, and a ≥ 3-month analysis-set restriction - where the build has one
   (`BUILD_DELTA.md` §2).
5. **Disenrollment censors follow-up** on the protocol's wording; the LOT engine says
   it does not (`OPEN_QUESTIONS.md` Q13).

## The code

`study223926/` is a package that runs **after** the LOT engine: it reads
`LOT_LONG_FINAL` and the NDMM cohort table and writes its own `S_*` tables. It builds
no line and no MM cohort of its own, so it can be re-run against a finished LOT run as
often as needed.

```
DATABRICKS_PWD=... Rscript study223926/build.R                # over the Databricks ODBC DSN
DRY_RUN=TRUE Rscript study223926/build.R                      # print the plan only
MODULES=safety COHORTS=1L,2L Rscript study223926/build.R      # one module; 2L is nested in 1L, so 1L comes too
Rscript study223926/tests/run_tests.R                         # 508 checks, no warehouse
```

Fourteen modules, four cohorts, and every open reading is a setting with the
protocol's answer as its default. Seven of the fourteen modules run today - the
cohorts, their attrition, windows, demographics and outcomes need no code list;
the other seven are blocked on Annexes 2 and 3, and a default run leaves them
out by name rather than stopping. `study223926/MODULES.md` has the rest.

## Standalone

Nothing in this folder reads a file outside it. The package carries its own code
lists (`study223926/codelists/` - the shapes, not the codes, which do not exist
anywhere yet), its own settings and its own tests, and a test asserts that no
path function in any R file reaches out. The two things it needs that are not
files are the warehouse and, optionally, the production code-list directory.

Part of the test suite parses and executes the SQL the modules emit, which needs
the Python packages sqlglot and duckdb. Without them those checks report `SKIP`
and the rest run unchanged.

## What this folder does not do

It does not change the cohort build. `study223926/` runs after it and after
the LOT engine, and reads what they wrote. `BUILD_DELTA.md` says what would
have to change in the cohort build to match this protocol; making those
changes is separate work, and several of them are blocked on
`OPEN_QUESTIONS.md`.
