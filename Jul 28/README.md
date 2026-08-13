# Multiple myeloma cohort and lines of therapy

Two cohort builds, one lines-of-therapy build that runs over either, and the
things that read a finished run.

A cohort is what LOT is pointed at. It is not part of LOT and does not read it.

## The packages

| | |
|---|---|
| `overall/` | cohort build, the broad MM cohort. `build.R`, no arguments. Writes `OVERALL_COH_FINAL`. |
| `ndmm/` | cohort build, the 1L newly-diagnosed study cohort. `build.R <prefix_>`. Also `build_subsequent_cohorts.R <prefix_>` for the 2L and 3L cohorts, which runs *after* the LOT build. |
| `lot/engine/` | lines of therapy. `build.R <COHORT_TABLE> <prefix_>`. The only package in `lot/` that writes LOT tables. |
| `lot/dashboard/` | one self-contained HTML. Reads only. |
| `lot/outcomes/` | TTNT, TTD, OS, attrition. Reads only. |
| `lot/questions/` | the study team's questions, one script each. Not a build. |
| `lot/qc/` | the slower checks on a finished run. Reads only, writes to `out/`. |
| `lot/validation/` | whether the rules are the right rules. Not part of a study run. |
| `lot/melphalan/` | a proposed line-advancing rule, built as three runs and differenced. Opt-in. |
| `lot/safety/` | code lists for the protocol's safety and utilisation events. Roster only. |
| `lot/tools/` | edits a production code list on request. Not a study stage. |

Each of the three has a **`RULES.md`** — the rules that build applies and the
assumptions behind them, on one page. `lot/LOT_RULES.md` is the long form for
lines; `ndmm/DECISIONS.md` is the long form for the cohort.

`ndmm/` and `overall/` are independent - neither reads the other, and each goes
to the raw CDM and the production code lists on its own. `lot/engine/` takes a
cohort table by name, so it runs over either:

```
ndmm     ->  lot over <prefix>NDMM_COHORT  ->  lot/dashboard, lot/questions/*_qs.R
overall  ->  lot over OVERALL_COH_FINAL    ->  lot/questions/broad_studyteam_qs.R
```

The study is the first path. The second exists because two of the study team's
questions are about patients the NDMM cohort excluded.

```
DATABRICKS_PWD=... Rscript ndmm/build.R                    ndmm_
DATABRICKS_PWD=... Rscript lot/engine/build.R              ndmm_NDMM_COHORT ndmm_
DATABRICKS_PWD=... Rscript lot/dashboard/build.R           ndmm_NDMM_COHORT ndmm_
DATABRICKS_PWD=... Rscript ndmm/build_subsequent_cohorts.R ndmm_
DATABRICKS_PWD=... Rscript lot/outcomes/build.R            ndmm_NDMM_COHORT ndmm_
```

The 2L and 3L cohorts sit between the lines and the outcomes, and both sides of
that matter. They come after LOT because their index dates are line starts, so
the lines have to exist first. They come before outcomes because outcomes reads
them for LINE_ELIGIBLE: run it first on a clean prefix and it quietly reports
ALL_LINES alone, and run it first on a re-run and it reads the previous
attempt's cohorts.

Read a package's own README before running it - or the entry script's header
where it has none (`overall/`, `lot/tools/`).

## Which names carry a prefix

* A cohort build names its own final table. `ndmm` prefixes it, so it is
  `ndmm_NDMM_COHORT`. `overall` does not - its final table is
  `OVERALL_COH_FINAL`, from `FINAL_TABLE_NAME`.
* Everything else a build writes is prefixed: checkpoints, attrition, run
  metadata, status tables, all of LOT's outputs.
* LOT reads the cohort table by its whole name and prefixes only what it writes,
  so `INPUT_COHORT_TABLE` is given complete and never prefixed again.

One prefix is one study, so a wrong prefix is a wrong study. The builds check it
rather than trusting it.

## How a run is identified

Each build records what it did in a status table - `<prefix>LOT_BUILD_STATUS`,
`<prefix>NDMM_BUILD_STATUS`, `<prefix>build_status` for overall.

Everything that reads a run afterwards reads that row first and refuses a run
that did not finish. The latest row wins, finished or not: a build replaces its
tables before it validates them, so a rerun that replaced them and then failed
owns them.

## Where the decisions are written down

A decision is anywhere this build chose something the protocol does not settle,
or chose to differ from it. There is no single register: `ndmm/DECISIONS.md` is
one and covers the NDMM cohort; everything else records decisions in its own
README, next to the thing decided.

| | where |
|---|---|
| NDMM cohort | `ndmm/DECISIONS.md`, numbered, with reasoning and what was measured |
| maintenance | `ndmm/DECISIONS.md` #10 - **not implemented**; the protocol defines a period, the build carries a flag |
| pregnancy window | `ndmm/DECISIONS.md` #9 - protocol and program spec disagree; which wins is recorded there |
| lines of therapy | `lot/engine/README.md`. `SCT_TANDEM_DAYS` and `CART_CONSOLIDATION_DAYS` come from prior internal work not in this repository, so they cannot be checked against the protocol text |
| outcomes | `lot/outcomes/README.md` - the `STUDY_END` censoring rule for TTD, the fifth attrition category, both denominators |
| safety and utilisation | `lot/safety/README.md` - acute/chronic counting, event attribution, the protocol's own `>30`/`>=30` ambiguity |
| the melphalan proposal | `lot/melphalan/README.md`, and the open questions `run_melp_scenarios.R` prints |

Where a README and this table disagree, the README is the record.

## Settings

`config.csv` in each package holds the defaults; the environment wins over it.

Settings that change what a build means are pinned as a contract and refused if
changed - a different threshold is a different algorithm. `LOT_CONTRACT_OVERRIDE`
exists for the sensitivity sweep; a run that uses it is marked as a non-contract
build in its status row and everything downstream refuses it.

Code lists live outside this folder, on a mounted path, hashed either side of
each read so a run records which version it used.

## Tests

No connection needed. They check the SQL, the settings and the guards. The merge
gate runs every one with a single exit status, so the counts are recorded against
a commit rather than reported by whoever ran them.

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
