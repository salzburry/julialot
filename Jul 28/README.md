# Multiple myeloma cohort and lines of therapy

Two cohort builds, one lines-of-therapy build that runs over either, and the
things that read a finished run.

## Three folders

| | |
|---|---|
| `overall/` | cohort build. The broad MM cohort. |
| `ndmm/` | cohort build. The 1L newly-diagnosed MM study cohort. |
| `lot/` | lines of therapy, and everything that reads a LOT run. |

A cohort is what LOT is pointed at; it is not part of LOT and does not read it.
That is the split: two cohort folders that go to the raw CDM on their own, and
one folder holding the engine and everything downstream of it.

## Two cohorts, not one pipeline

`ndmm/` and `overall/` are independent. Neither reads the other. Each goes
to the raw CDM and the production code lists and builds its own cohort.

| | | writes |
|---|---|---|
| `ndmm/` | the 1L newly-diagnosed MM study cohort | `<prefix>NDMM_COHORT`, `<prefix>NDMM_ATTRITION` |
| `overall/` | the broad MM cohort | `OVERALL_COH_FINAL` |

`lot/engine/` is pointed at a cohort table by name, so it runs over either one.
That gives two paths:

```
ndmm     ->  lot over <prefix>NDMM_COHORT  ->  lot/dashboard, lot/questions/*_qs.R
overall  ->  lot over OVERALL_COH_FINAL    ->  lot/questions/broad_studyteam_qs.R
```

The study is the first path. The second exists because two of the study team's
questions cannot be answered on the NDMM cohort at all - it excluded the
patients they are about - so they need a LOT run over the broad cohort.

```
DATABRICKS_PWD=... Rscript ndmm/build.R              ndmm_
DATABRICKS_PWD=... Rscript lot/engine/build.R        ndmm_NDMM_COHORT ndmm_
DATABRICKS_PWD=... Rscript lot/dashboard/build.R     ndmm_NDMM_COHORT ndmm_
```

The 2L and 3L cohorts are a fourth step on the NDMM path, after the LOT run:
their index dates are line starts, so lot has to have found the lines first.

```
DATABRICKS_PWD=... Rscript ndmm/build_subsequent_cohorts.R ndmm_
```

The outcomes read a finished LOT run and add nothing to it:

```
DATABRICKS_PWD=... Rscript lot/outcomes/build.R      ndmm_NDMM_COHORT ndmm_
```

Each package documents its own settings, outputs and checks - in a README where
it has one, in the entry script's header where it does not (`overall/` and
`lot/tools/`). Read that before running it. `lot/README.md` says which package
in that folder is which.

## What each package is

| | |
|---|---|
| `overall/` | cohort build. `build.R`, takes no arguments. |
| `ndmm/` | cohort build. `build.R <prefix_>`. Also `build_subsequent_cohorts.R <prefix_>` for the 2L and 3L cohorts, which runs after the LOT build. |
| `lot/engine/` | lines of therapy. `build.R <COHORT_TABLE> <prefix_>`. The only package in `lot/` that writes the LOT tables. |
| `lot/dashboard/` | one self-contained HTML. `build.R <COHORT_TABLE> <lot_prefix_>`. Reads only. |
| `lot/questions/` | scripts, not a build. Each reads one finished LOT run and writes CSVs or a workbook. They reuse `lot/engine/`'s modules rather than a second copy. |
| `lot/outcomes/` | treatment patterns and treatment-related outcomes - TTNT, TTD, OS, attrition. `build.R <COHORT_TABLE> <lot_prefix_>`. Reads only. |
| `lot/qc/` | the slower checks on a finished LOT run, asked after the fact. Reads only, writes a report to `out/`. |
| `lot/validation/` | checks the LOT rules. Needs a finished LOT run for some of it; the sensitivity sweep builds its own throwaway runs. Not part of a study run. |
| `lot/melphalan/` | builds the proposed melphalan line-advancing rule as three complete LOT runs and reports the difference. Opt-in, writes to its own throwaway prefixes. Not part of a study run. |
| `lot/safety/` | code lists for the protocol's key safety events and healthcare utilisation events. The roster is complete; the codes are outstanding. |
| `lot/tools/` | a utility that edits a production code list on request. Not a study stage. |

## Which names carry a prefix

Not everything, and the exception matters when you point one package at
another's output.

* A cohort build names its own final table. `ndmm` prefixes it, so it is
  `ndmm_NDMM_COHORT`. `overall` does not - its final table is
  `OVERALL_COH_FINAL`, from `FINAL_TABLE_NAME` in its config, with no prefix.
* Everything else a build writes is prefixed - checkpoints, attrition,
  run metadata, status tables, and all of LOT's outputs.
* LOT reads the cohort table by its whole name and prefixes only what it
  writes. So `INPUT_COHORT_TABLE` is given complete, prefix included, and is
  never prefixed again.

One prefix is one study. Two studies on one schema differ only by prefix, so a
wrong prefix is a wrong study, and the builds check it rather than trusting it.

## How a run is identified

Each build records what it did in a status table - `<prefix>LOT_BUILD_STATUS`,
`<prefix>NDMM_BUILD_STATUS`, `<prefix>build_status` for overall: which run,
which cohort, whether it finished.

Everything that reads a run afterwards reads that row first and refuses a run
that did not finish. The latest row wins, finished or not, because a build
replaces its tables before it validates them - so a rerun that replaced them
and then failed owns them, and the previous good row does not.

## Where the decisions are written down

A decision is anywhere this build had to choose something the protocol does not
settle, or chose to differ from it. There is no single register, and that is
worth knowing before looking for one: `ndmm/DECISIONS.md` is a real register and
it covers the NDMM cohort only. Everything else records its decisions in its own
README, next to the thing decided.

| | where |
|---|---|
| NDMM cohort | `ndmm/DECISIONS.md` - numbered, with the reasoning and what was measured |
| maintenance | `ndmm/DECISIONS.md` #10 - **not implemented**; the protocol defines a period, the build carries a flag |
| pregnancy window | `ndmm/DECISIONS.md` #9 - the protocol and the validated program spec disagree; which wins is recorded there |
| lines of therapy | `lot/engine/README.md`. The rules the protocol summarises come from prior internal work not in this repository, so `SCT_TANDEM_DAYS` and `CART_CONSOLIDATION_DAYS` cannot be checked against the protocol text - only against that document. |
| outcomes | `lot/outcomes/README.md` - the `STUDY_END` censoring rule for TTD, the fifth attrition category, both denominators |
| safety and utilisation | `lot/safety/README.md` - the acute/chronic counting rules, event attribution, and the protocol's own `>30` / `>=30` ambiguity |
| the melphalan proposal | `lot/melphalan/README.md`, and the open questions printed by `run_melp_scenarios.R` |

Where a package's README and this table disagree, the README is the record and
this table is the index.

## Settings

`config.csv` in each package holds the defaults. The environment wins over it.

Settings that change what a build means are pinned as a contract and refused if
changed - a different threshold is a different algorithm, not a setting. The
one way past that is `LOT_CONTRACT_OVERRIDE`, which exists for the sensitivity
sweep; a run that uses it is marked as a non-contract build in its status row,
and everything downstream refuses it.

Code lists live outside this folder, on a mounted path. They are hashed before
and after each read, so a run records which version it used.

## Tests

No connection needed. They check the SQL, the settings and the guards. The
merge gate runs every one of them with a single exit status, so the counts
below are recorded against a commit rather than reported by whoever ran them.

```
Rscript overall/tests/test_runner.R
Rscript ndmm/tests/test_runner.R                 # and test_same_as_overall.R,
                                                 # test_subsequent.R
Rscript lot/engine/tests/test_runner.R           # and test_line_criteria.R
Rscript lot/dashboard/tests/test_runner.R
Rscript lot/questions/tests/test_setup.R
Rscript lot/outcomes/tests/test_runner.R
Rscript lot/qc/tests/test_lot_qc.R
Rscript lot/tools/tests/test_remove_steroids.R
Rscript lot/validation/tests/test_vignettes.R    # and test_sensitivity.R,
                                                 # test_benchmarks.R,
                                                 # test_definitions.R,
                                                 # test_melphalan.R
Rscript lot/melphalan/tests/test_aug1_melp.R
Rscript lot/safety/tests/test_safety_codelists.R
```

The study team's worked melphalan scenarios run without a connection too, and
exit non-zero if any of them moves:

```
Rscript lot/melphalan/run_melp_scenarios.R
```
