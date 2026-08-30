# Multiple myeloma cohort and lines of therapy

Two cohort builds, one lines-of-therapy build that runs over either, and the
things that read a finished run.

A cohort is what LOT is pointed at. It is not part of LOT and does not read it.

> **The line-counting algorithm changed on 2026-08-30.** Two rules the study
> team asked for were adopted, and both change what starts and ends a line:
> a short melphalan course outside induction no longer starts one
> (`lot/LOT_RULES.md` 4.7), and a drug from an earlier line coming back joins
> the line it returns in when exactly one agent advanced the line while it was
> away (4.8). **Every LOT number produced before that date is superseded** —
> line counts, line dates, end reasons and the cohorts built from them. Rebuild
> before quoting anything. `STUDY_TEAM_ASKS.md` is the trail of what was asked,
> what was decided, and what is still owed.

## The packages

| | |
|---|---|
| `overall/` | cohort build, the broad MM cohort. `build.R`, no arguments. Writes `OVERALL_COH_FINAL`. |
| `ndmm/` | cohort build, the 1L newly-diagnosed study cohort. `build.R <prefix_>`. Also `build_subsequent_cohorts.R <prefix_>` for the 2L and 3L cohorts, which runs *after* the LOT build. |
| `lot/engine/` | lines of therapy. `build.R <COHORT_TABLE> <prefix_>`. The only package anywhere here that writes LOT tables. |
| `lot/qc/` | thirty-five checks on a finished run. Reads only, writes to `out/`. |
| `lot/validation/` | the rule scenarios, machine-checked. No warehouse. |
| `reporting/dashboard/` | one self-contained HTML. Reads only. |
| `analysis/outcomes/` | TTNT, TTD, OS, attrition. Reads only. |
| `analysis/questions/` | the study team's questions, one script each. Not a build. |
| `exploration/melphalan/` | the melphalan rules, built as complete runs and differenced — the study adopted one of them. Opt-in. |
| `exploration/lot/run_foldin_cells.R` | the MAP fold-in the study adopted, measured against a build without it. Opt-in. |
| `exploration/lot/` | benchmarks, the definition comparison, the sensitivity sweep, stockpiling, re-challenge, audit counts. Not part of a study run. |

`lot/` is the algorithm and only the algorithm: the engine that builds the
lines, the checks that sign a run off, the scenarios that say what the rules
are. Everything derived from a finished run is in `reporting/` and `analysis/`;
everything asked *about* the rules rather than applied by them is in
`exploration/`.

Each area carries a `FILES.md` — what is in it and what each file does — and
each cohort build a `RULES.md`, with `ndmm/DECISIONS.md` as the long form for
the cohort. `lot/LOT_RULES.md` is the rules the line build applies, each naming
the machine-checked vignette that tests it. Open questions live on the Open
questions sheet of the scenario workbook
(`exploration/lot/run_lot_scenarios.R`).

`ndmm/` and `overall/` are independent - neither reads the other, and each goes
to the raw CDM and the production code lists on its own. `lot/engine/` takes a
cohort table by name, so it runs over either:

```
ndmm     ->  lot over <prefix>NDMM_COHORT  ->  reporting/dashboard, analysis/questions/*_qs.R
overall  ->  lot over OVERALL_COH_FINAL    ->  analysis/questions/broad_studyteam_qs.R
```

The study is the first path. The second exists because two of the study team's
questions are about patients the NDMM cohort excluded.

```
DATABRICKS_PWD=... Rscript ndmm/build.R                    ndmm_
DATABRICKS_PWD=... Rscript lot/engine/build.R              ndmm_NDMM_COHORT ndmm_
DATABRICKS_PWD=... Rscript reporting/dashboard/build.R     ndmm_NDMM_COHORT ndmm_
DATABRICKS_PWD=... Rscript ndmm/build_subsequent_cohorts.R ndmm_
DATABRICKS_PWD=... Rscript analysis/outcomes/build.R       ndmm_NDMM_COHORT ndmm_
```

The 2L and 3L cohorts sit between the lines and the outcomes, and both sides
matter. After LOT, because their index dates are line starts. Before outcomes,
because outcomes reads them for LINE_ELIGIBLE: run outcomes first on a clean
prefix and it quietly reports ALL_LINES alone; run it first on a re-run and it
reads the previous attempt's cohorts.

Read the area's `FILES.md` before running a package — `lot/`, `reporting/`,
`analysis/` and `exploration/` each carry one, with every package's commands,
settings and outputs. `overall/` documents itself in its entry script's
header.

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
that did not finish. The latest row wins, finished or not — a build replaces its
tables before it validates them, so a rerun that replaced them and then failed
owns them.

## Where the decisions are written down

A decision is anywhere this build had to choose between two readings of a rule.
Two registers: `ndmm/DECISIONS.md` for the cohort, `lot/LOT_RULES.md` for the
lines.

| | where |
|---|---|
| NDMM cohort | `ndmm/DECISIONS.md`, numbered, with reasoning and what was measured |
| maintenance | `ndmm/DECISIONS.md` #10 - **not built**; the build carries a flag, not a period |
| pregnancy window | `ndmm/DECISIONS.md` #9 - two windows are possible; the one the code applies is recorded there |
| lines of therapy | `lot/LOT_RULES.md`, and the scenario workbook's Open questions sheet |
| outcomes | `analysis/FILES.md` - the `STUDY_END` censoring rule for TTD, the fifth attrition category, both denominators |
| the melphalan rule the build applies | `lot/LOT_RULES.md` 4.7. How it was chosen, and the five-branch rule that was not adopted, are in `exploration/FILES.md` |
| a drug from an earlier line coming back | `lot/LOT_RULES.md` 4.8 - it joins the line it returns in when one agent advanced the line in between |
| what the study team asked for, and what is still owed | `STUDY_TEAM_ASKS.md` |

Where one of those documents and this table disagree, the document is the record.

The scenario workbook's **Open questions** sheet is the other side: the rules
that still need a decision from the study team. Each names the scenario that
shows it and the count that sizes it, and each is recorded in `lot/LOT_RULES.md`
beside the rule it affects. None is being changed while it is open.

## Settings

`config.csv` in each package holds the defaults; the environment wins over it.

Settings that change what a build means are pinned as a contract and refused if
changed: a different threshold is a different algorithm. `LOT_CONTRACT_OVERRIDE`
exists for the sensitivity sweep. A run that uses it is marked a non-contract
build in its status row, and everything downstream refuses it.

Code lists live outside this folder, on a mounted path, hashed either side of
each read so a run records which version it used.

## Tests

No connection needed. They check the SQL, the settings and the guards. The
merge gate runs every one with a single exit status, so the counts are recorded
against a commit rather than reported by whoever ran them.

```
Rscript overall/tests/test_runner.R
Rscript ndmm/tests/test_runner.R                 # and test_same_as_overall.R,
                                                 # test_subsequent.R
Rscript lot/engine/tests/test_runner.R              # and test_line_criteria.R
Rscript lot/qc/tests/test_lot_qc.R
Rscript lot/validation/tests/test_vignettes.R
Rscript reporting/dashboard/tests/test_runner.R
Rscript analysis/outcomes/tests/test_runner.R
Rscript analysis/questions/tests/test_setup.R
Rscript exploration/melphalan/tests/test_aug1_melp.R
Rscript exploration/lot/tests/test_benchmarks.R     # and test_definitions.R,
                                                    # test_melphalan.R,
                                                    # test_sensitivity.R,
                                                    # test_stockpiling.R
```

The study team's worked melphalan scenarios run without a connection too, and
exit non-zero if any of them moves:

```
Rscript exploration/melphalan/run_melp_scenarios.R
```
