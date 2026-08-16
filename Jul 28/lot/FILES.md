# What is in this folder

The lines-of-therapy engine, and everything that depends on it. This file says
what is here and what each file does. `LOT_RULES.md` is the other half: the
rules the line build applies, one at a time, each with a scenario showing what
it does to a patient's claims.

One package here writes a study run's LOT tables, and only that one: everything
else reads that run, derives from it, or rebuilds it under a changed rule into
a prefix of its own. So the lines themselves have a single author.
`lot/outcomes/` does add tables under the study's prefix, but they are its own
`OUT_*`, derived from a finished run rather than a second account of it.

| | |
|---|---|
| `lot/engine/` | builds the lines. `build.R <COHORT_TABLE> <prefix_>`. The only package here that writes a study run. |
| `lot/dashboard/` | one self-contained HTML off a finished run. `build.R <COHORT_TABLE> <lot_prefix_>`. |
| `lot/outcomes/` | TTNT, TTD, OS and attrition off a finished run. `build.R <COHORT_TABLE> <lot_prefix_>`. |
| `lot/questions/` | the study team's questions, one script each. Not a build. |
| `lot/qc/` | the slower checks on a finished run, asked after the fact. `run_lot_qc.R`. |
| `lot/validation/` | whether the rules are the right rules — vignettes, benchmarks, definitions, a sensitivity sweep. |
| `lot/melphalan/` | an exploration: a proposed line-advancing rule, built as three complete runs and differenced. Opt-in, and not in the study's numbers. |

Paths are written from the study folder, so `lot/engine/` is what you type
standing at its root. Inside each package's own file table below they are
relative to that package, which is why they read `R/build_lot.R` and the
commands read `Rscript build.R` — those are run from the package's folder.

## What a study run uses

`lot/engine/`, then `lot/dashboard/`, `lot/outcomes/` and `lot/questions/` over
what it wrote. `lot/qc/` signs a finished run off.

The other two are not part of a run: `lot/validation/` is the case for the
rules, and `lot/melphalan/` an experiment on one of them. Both build — the
sensitivity sweep and the melphalan cells — into throwaway prefixes of their
own, and both are opt-in, so neither can land on a study's tables by being run
at the wrong moment.

## Why the engine is its own folder

It is copied into other projects as-is, so it may not reach outside itself: no
sibling here is on its path, its only outside dependencies are the R packages
`DBI`, `odbc` and `glue`, and nothing in it names a cohort. A check outside the
study folder holds every file in it to that.

The direction is one-way, and it is the whole reason the split reads the way it
does. `lot/qc/`, `lot/questions/`, `lot/validation/` and `lot/melphalan/` resolve
`../engine` and read its modules, so the config, the code lists and the naming
helpers have one definition rather than a copy per reader. `lot/engine/`
resolves nothing back.

`lot/dashboard/` and `lot/outcomes/` are the two that do not: they read a
finished run's tables and nothing else, so they carry their own
`load_inputs.R`, config and helpers. That is a real duplication, and the reason
it is tolerated is that neither reads a code list or a line rule — only columns
the engine has already written — so there is no rule for their copy to drift
away from.

## The cohorts are not here

`overall/` and `ndmm/` build the cohorts. A cohort is what the engine is pointed
at — `build.R` takes the table name — so it comes before LOT rather than under
it, and neither cohort build reads anything in this folder at run time.

Two things do cross. `ndmm/build_subsequent_cohorts.R` runs *after* a LOT run,
because the 2L and 3L index dates are line starts; it is still a cohort build, so
it lives with the cohorts. And `ndmm/tests/` reads `lot/engine/R/build_lot.R` as a
source file — not to run it, but to pin the interface between them: the columns
the engine requires of a cohort, and the columns its status table really has.

## Settings

Each package has a `config.csv` where it has settings at all, and the environment
wins over the file. The cohort table and the prefix are never in a config file —
the caller passes them, because one prefix is one study and a wrong prefix is a
wrong study.

Settings that change what a build *means* are pinned in `CONTRACT`
(`lot/engine/R/build_lot.R`) and refused if changed, since a different
threshold is a different algorithm. `LOT_CONTRACT_OVERRIDE=TRUE` exists for the
sensitivity sweep and the melphalan cells; a run that uses it records what it
deviated on in `CONTRACT_DEVIATIONS`, and every reader here refuses such a run
as the study's numbers.

Code lists live outside version control on a mounted path (`CODELIST_DIR`) and
are hashed either side of each read, so a run records which version it used.

---

# Every file

## `lot/engine/` — builds the lines

Entry point `build.R <COHORT_TABLE> <prefix_> [<study_start> <study_end>]`, or
the same four as `INPUT_COHORT_TABLE`, `OBJECT_PREFIX`, `STUDY_START`,
`STUDY_END`. One run per prefix at a time. There is one way to run it — start to
finish; LOT2-5 cannot be continued in a session of its own, because a rebuild
would re-read the code lists and the cohort and could build LOT1 from one version
and `LOT_LONG` from another.

A cohort table has to provide `PATID`, `INDEX_DATE`, `ENDDATE`, `ENDDATE_CE`,
`DEATH_DT`, `GDR_CD`, `YRDOB`, `AGE_INDEX_YR`, `FU_DAYS`, `FU_DAYS_CE`, one row
per patient, and has to fit the study window the run was given.

| path | what it does |
|---|---|
| `build.R` | Entry point. Takes a cohort table and an output prefix, and builds every line for it. |
| `config.csv` | Every setting as `name,value,description`. The cohort table and prefix are not here; the caller passes them. |
| `R/build_lot.R` | The runner, and `CONTRACT` — the pinned settings a run is checked against before it starts. Deviating needs an explicit override and is recorded in the run's status row. Also the cohort-input checks, the run metadata and the face-validity checks. |
| `R/config_lot.R` | Reads the settings. The environment wins over `config.csv`. |
| `R/load_inputs.R` | Applies `config.csv` as defaults, never over a value already set, and never reads the password from it. |
| `R/codelists_lot.R` | Loads the four code lists from CSV — `cl_mma_rollup.csv`, `cl_mma_codelist.csv`, `permissible_subs.csv`, `cl_sct_codelist.csv`. No embedded fallback: a missing file stops the run, and each is hashed before and after being read. |
| `R/db_utils_lot.R` | Connection, logging, retry, table naming (`wrk` / `lot_out`), `materialize()` and the step runner. |
| `R/line_criteria.R` | Extra criteria on finished lines, declared as data. Every one is computed into `LOT_LONG_ALLFLAGS`; only the enabled ones are applied to `LOT_LONG_FINAL`. |
| `R/cart_rule.R` | The CAR-T induction rule: an infusion inside line 1's window belongs to line 1 and neither ends nor starts a line. |
| `R/melp_rule.R` | The melphalan exploration's rule. Pinned off, and off emits the same SQL as not having the file, so it decides nothing in a study run. It lives here because it needs each line's own induction window — `lot/melphalan/` below. |
| `R/prior_regimen.R` | The prior-regimen rule and each line's run-out. A drug in the previous regimen cannot start the next line; the line it belongs to extends over its later episodes instead, stopping at any other agent arriving in between. |
| `R/steps/01_codelists.R` | Code lists into views, then the consistency checks between them — which are fatal, which are waivable through `CODELIST_WAIVERS`, and why. |
| `R/steps/02_patient_input.R` | The cohort as the build reads it, snapshotted into `LOT_PATIENT_INPUT`. Sets the observation end date every later gap and window is measured against. |
| `R/steps/03_mma_map.R` | Claims into medication available periods. A new period opens only for a claim beyond every runout; one arriving while cover is live pushes the runout out instead. |
| `R/steps/04_lot1_base.R` | Line 1's start, its induction medications and its base regimen. |
| `R/steps/05_sct.R` | Transplant and CAR-T events: autologous, allogeneic, CAR-T. |
| `R/steps/05b_lot1_sct.R` | Line 1's own transplant summary, which needs line 1's base. |
| `R/steps/06_lot1_end.R` | Line 1's end date and end reason, including the discontinuation confirmation buffer. |
| `R/steps/07_qc.R` | Counts on what was just built, recorded with the run. |
| `R/steps/08_persist.R` | Writes the outputs, every one through the prefix helper so a run cannot overwrite another cohort's. |
| `R/steps/10_lot2_5_base.R` | Lines 2 to 5: their start candidates, regimens, run-outs and ends, and `LOT_LONG`. The largest file here, and the one that decides where later lines begin. |
| `tests/test_runner.R` | The cohort switch, the contract, the setting validators, the declared outputs against what the steps write. |
| `tests/test_line_criteria.R` | The per-line criteria layer. |
| `tests/testutil.R` | Shared assertion helpers. Not a suite. |

**What a run leaves behind.** `LOT_LONG` and `LOT_LONG_FINAL` (the study
population), `LOT_LONG_ALLFLAGS`, `LOT_PATIENT_INPUT`, `MAP_STACKED`, the LOT1
stage tables, the per-line `LOT<n>_<STAGE>` tables, `LOT_ATTRITION`,
`LOT_RUN_METADATA`, `LOT_CODELIST_METADATA`, `LOT_QC_SUMMARY` and
`LOT_BUILD_STATUS` — all prefixed. Read `LOT_BUILD_STATUS` before trusting any of
them: `started` once preflight passes, then `complete`, or `failed`.

The per-line stage tables stay behind deliberately — they are the working of each
line, so why a patient's LOT3 ended where it did is a read rather than a re-run.

### Adding a criterion to a line

LOT is defined by the rules in `R/steps`. If a study needs to require something
more of a line — any line, not only L1 — add it to `LINE_CRITERIA` in
`R/line_criteria.R` rather than editing those rules:

```r
list(
  name    = "l2_started_on_med",
  label   = "L2 started on a drug, not a transplant",
  lines   = 2L,                        # 1L, c(2L, 3L), or "*" for every line
  flag    = "L2_START_IS_MED",
  sql     = "LOT_START_TYPE = 'MED'",  # any expression over lot_long
  on_fail = "flag"                     # or "truncate"
)
```

Then turn it on with `APPLY_L2_STARTED_ON_MED,TRUE` in `config.csv`. Any value
other than `TRUE` or `FALSE` stops the build rather than quietly leaving the
criterion off. A criterion needing patient-level facts `lot_long` does not carry
declares `patients` as well — SQL building one row per `PATID`, created before
the flags view and `LEFT JOIN`ed into it, with both names derived from the
criterion's so a rename cannot leave the predicate reading nothing.

Every run says what it applied: the log names each criterion, whether it was
applied and how many patients fail it — the disabled ones too — and the same goes
into `LINE_CRITERIA_APPLIED` in `LOT_RUN_METADATA` as
`no_belantamab=on:truncate:37`. `LOT_RULES.md` is what a criterion means for
the lines, under "Belantamab removes the patient, not the line".

### The funnel

`<prefix>LOT_ATTRITION`, one row per step, with patients and lines on each, and
`PCT_OF_START` / `PCT_OF_PREV`. Not every row is attrition, and `KIND` says which
is which:

| `KIND` | what it is |
|---|---|
| `input` | cohort patients handed to LOT |
| `reconciliation` | with a mapped MM therapy episode, then with LOT1 built. On a treatment-indexed cohort such as NDMM these re-derive a fact the cohort build already established, so a drop is the two scans disagreeing rather than patients the study lost — reported as a discrepancy, not as loss |
| `criterion` | one row per enabled `truncate` criterion, cumulative |
| `final` | the study population, `LOT_LONG_FINAL` |
| `progression` | reached LOT1, LOT2, ... to `MAX_LOT`. Nobody was removed here — a patient with no LOT3 did not progress, or their follow-up ended |

Two rows are the same number reached two ways, deliberately: `final` must equal
the last `criterion` row, and `Reached LOT1` must equal `final`. Either mismatch
stops the build, as does a step larger than the one above it.

### The code-list checks

Three consistency checks are reviewable and stop the build unless named in
`CODELIST_WAIVERS`, because each has a reading a study team can accept: a
code-list med with no rollup row (`orphan_meds`), a rollup med with no
extractable NDC/HCPCS code (`uncoded_meds`), a code type other than NDC or HCPCS
(`code_types`). The full waivable set is:

```
orphan_meds  uncoded_meds  code_types  subs_substitute  subs_original
ndc_short  claim_ndc_short  claim_ndc_shape
```

These are not waivable, because each means a claim counted twice, a code matching
every claim with no NDC, a medication with no class, or an output column that is
always zero:

```
code_to_med  bad_ndc  rollup_defs  blank_keys  ndc_shape
multi_class  class_agreement
```

Naming one of the second group is refused before the build starts. `multi_class`
is fatal because `min(MED_CLASS)` picks lexically, not clinically, and the choice
reaches the class flags and the steroid exclusion. The SCT checks in `05_sct.R`
are on neither list and always stop the build. Run with none of them set first: a
check that fires is evidence about the production code lists.

**NDC shape** is the one worth reading twice. The join pads whatever digits it
finds to eleven — `lpad(regexp_replace(CL_CODE, '[^0-9]', ''), 11, '0')`.
`ndc_shape` is for codes that cannot be an NDC in any form: letters, more than
eleven digits, fewer than ten. `ndc_short` is for ten-digit codes, which are a
real FDA form but one of three layouts — 4-4-2, 5-3-2 or 5-4-1 — and the
eleven-digit form is made by inserting the zero into the short segment, not at
the far left. `50242-040-62` is 5-3-2, so it becomes `50242004062`; the blanket
left-pad produces `05024204062`, a different key. The conversion has to happen in
the file. Waive `ndc_short` only once the study team has confirmed the ten-digit
entries are 4-4-2, the one layout the pad gets right. `check_claim_ndc` asks the
same question of both claim tables before LOT1 starts, under
`claim_ndc_short` / `claim_ndc_shape`.

**Steroids** are maintained separately, so their codes are not in
`cl_mma_codelist.csv`, and both places that build `mma_rollup` drop them by class
as well. The rollup file itself should not list them either — QC check `D3`
reports whether the production copy still does. That edit is made on the server
by hand now; the script that used to make it was removed with `lot/tools/` and
is in git history if it is wanted again.

### Face validity

The structural invariants ask whether the output is internally consistent.
`LOT_FACE_VALIDITY` asks whether it looks like myeloma — a run can pass every
structural check with transplants in late lines, CAR-T in first line, or a median
line lasting three days.

| check | expects |
|---|---|
| autologous transplant lines that are LOT1-2 | >= 50% |
| CAR-T lines at LOT3 or later | >= 50% |
| patients with any allogeneic line | <= 5% |
| LOT1 lines started by a medication | >= 80% |
| median LOT1 length in days | 30-1500 |
| LOT1 patients covered by the ten commonest regimens | >= 25% |

The number is the point, not the verdict: every check records what it found
whether or not it passed, and the bands are wide deliberately — they catch gross
failure, and none is a published benchmark. Reported, not fatal;
`FACE_VALIDITY_FATAL=TRUE` makes them stop.

## `lot/dashboard/` — one HTML off a finished run

`build.R <COHORT_TABLE> <lot_prefix_> [<cohort_prefix_>]`. Reading only: it
creates, replaces and drops nothing, so it can be re-run against a finished study
as often as anyone wants.

| path | what it does |
|---|---|
| `build.R` | Entry point. Renders one cohort's dashboard after the cohort and line builds. |
| `config.csv` | Settings: which tables to read, the attrition table's name and window, and one `SHOW_*` switch per panel. A switch that is neither `TRUE` nor `FALSE` stops the build. |
| `R/build_dashboard.R` | The runner. Resolves which LOT run owns the tables from `LOT_BUILD_STATUS`, refuses one that did not finish or that carries contract deviations, then draws. |
| `R/sections.R` | What the dashboard shows. Every panel is one entry — a name, a tab, its query, what it needs and how to draw the answer. Also the attrition layouts, the transition Sankeys and the patient-journey scenarios. |
| `R/render.R` | Writes one self-contained HTML file using base R only, so a missing plotting package cannot silently produce nothing. Holds `PALETTE`, the whole colour scheme. |
| `R/db_utils_dash.R` | Reading only. This package creates, replaces and drops nothing, which is what makes it safe to re-run against a finished study. |
| `R/config_dash.R`, `R/load_inputs.R` | Settings, and the `config.csv` reader. |
| `tests/test_runner.R` | The registry, the guards, the placeholder filling, that the package cannot write, and that the HTML escapes values and needs no network. |

Two things worth knowing before reading a number off it. Every clinical panel
is drawn on `LOT_LONG_FINAL`; only the Validation tab reads `LOT_LONG`, where
the before/after comparison is the point. And `followup_end_reason` is one row
per **patient** over the whole study population, while `outcomes`'
`N_LOST_TO_FU` and `N_ONGOING` are one row per patient-**line** and only over
what is left after the next line, death and discontinuation have been taken
out. The two do not reconcile, and `outcomes_followup` is the panel to read
beside `OUT_ATTRITION`.

## `lot/outcomes/` — protocol Table 4

`build.R <COHORT_TABLE> <lot_prefix_>`. Reads only; writes five `OUT_*` tables.

| path | what it does |
|---|---|
| `build.R` | Entry point for treatment patterns and treatment-related outcomes. |
| `R/build_outcomes.R` | Computes those outcomes off one finished run. Builds no line and no cohort of its own. |
| `R/run_outcomes.R` | Resolves which run owns the tables, refuses anything it cannot vouch for, then writes the five output tables. |
| `R/config_out.R` | Settings, all about which run to read. Nothing here defines a clinical rule. |
| `R/db_utils_out.R`, `R/load_inputs.R` | Connection, logging and settings helpers for that package. |
| `config.csv` | Three settings: the run to read, the cohort prefix, and `STUDY_END`, which is checked against the LOT run rather than trusted. |
| `followup_outcomes.sql` | Paste-and-run: reads observed follow-up, event counts and the attrition split back off a finished run, and checks the five categories sum to `N_ON_LINE`. |
| `tests/test_runner.R` | The SQL as a string, and the censoring arithmetic evaluated in R over hand-made cases. |

| table | one row per |
|---|---|
| `<prefix>OUT_TTE` | patient per line — TTNT, TTD and OS as a date and a 0/1 each |
| `<prefix>OUT_ATTRITION` | denominator and line — the attrition categories, which partition it |
| `<prefix>OUT_LINE_GAP` | denominator and line pair — months from one line's start to the next |
| `<prefix>OUT_REGIMEN` | denominator, line and regimen — N and % receiving each |
| `<prefix>OUT_DX_TO_LOT1` | one row — months from MM diagnosis to the 1L index. The only optional output. |

It refuses a run it cannot identify and a lineage it cannot prove — the newest
`LOT_BUILD_STATUS` row has to be `complete`, built from the cohort named on the
command line, carry no `CONTRACT_DEVIATIONS`, and name the same `STUDY_END` this
package is set to. `OUT_ALLOW_UNPROVEN_LINEAGE=TRUE` accepts what could not be
checked; a lineage shown to be wrong still stops.

Both readings of "of the patients who reached 2L" are reported side by side —
`ALL_LINES` and `LINE_ELIGIBLE` — because nothing in the protocol picks one.
Regimens are raw, not the Annex 2 SOC categories.

## `lot/qc/` — the slower checks on a finished run

| path | what it does |
|---|---|
| `run_lot_qc.R` | Runs thirty-two checks against a finished run and refuses one whose own build did not complete. Reads only; writes a report to `out/`. Exit status is 0 when nothing failed and 1 when something did, so it can gate a handover. |
| `R/checks.R` | The checks as data — one entry per check, each carrying the query that finds violations, so the catalogue can be read without running it. |
| `run_lot_audit_counts.R` | Real-data frequencies for the LOT assignment findings — the audit's questions put to the real run. |
| `tests/test_lot_qc.R` | That each check answers the same shape, reads only the tables it declares, masks every patient id, and turns a count into the right verdict. |

Nothing here duplicates a check the build already makes. Three severities: `fail`
is something the algorithm's own definition says cannot happen, `warn` is worth a
look, `info` is counted and never scored. A check that could not run is reported
as an error, not a pass. It judges a run by that run's own recorded
`CONTRACT_SETTINGS`, not by `config.csv`.

## `lot/questions/` — the study team's asks

One script per ask, each writing its own CSVs or workbook. All read a finished
run and write nothing to the warehouse. `OBJECT_PREFIX` and `INPUT_COHORT_TABLE`
are required, and each script checks the cohort it was given against what the LOT
build recorded.

| path | what it does |
|---|---|
| `_setup.R` | Shared setup, using the engine's own modules rather than a second copy so the two cannot drift. Loads `config.csv` first, then pins a config the way the build does. |
| `lot1_studyteam_qs.R` | The standalone LOT1 asks. |
| `poma_studyteam_qs.R` | The POMA-in-1L asks — one workbook, one tab per question. |
| `jul20_studyteam_qs.R` | The July-20 set, including `q3_cart_screen()`, which counts the patients the CAR-T induction rule touches. |
| `lot_followup_qs.R` | The follow-ups on steroids, regimen mix and CAR-T. |
| `broad_studyteam_qs.R` | The two asks NDMM cannot answer, over the broad cohort — the other-cancer association, and the diagnosis-anchored trial flags. |
| `validation_qs.R` | The "MM LOT validation next steps" asks. |
| `validation_helpers.R` | The analysis behind those questions, shared with the dashboard's exploratory tables. |
| `tests/test_setup.R` | Executes the setup and holds the population, the table names and the bone-metastasis list to what the build does. |

`LOT_POPULATION=PRECRITERIA` is the one axis: the same run before the line
criteria, worth asking for when the question is what a criterion cost. It is not
a cohort, and a denominator taken from it counts patients the study removed.

## `lot/validation/` — whether the rules are the right rules

Five asks, each taken as far as this folder can take it. None of it has executed
against a warehouse, so nothing here is an observed output. Every runner prints
what it would measure and needs no connection until told to execute.

| path | what it does |
|---|---|
| `R/run_binding.R` | Works out which run actually wrote the tables about to be measured, since the tables themselves do not say. |
| `R/vignettes.R` | The edge cases the algorithm is hardest on, each with the assignment the rules give. A specification, not observed data. Every offset is derived from the parameter that decides it, so the cases move when a setting moves. |
| `run_vignettes.R` | Renders the catalogue. No connection; writes a CSV and a markdown table to `out/`. |
| `R/benchmarks.R` | This algorithm's distributions — lines per patient, regimen frequencies, durations, TTNT — beside published figures. |
| `benchmarks.csv` | The reference grid, shipping with `published_value` blank: the published figures are not this folder's to write, and an unfilled row reports itself rather than passing. A value with no `source` is refused on load. |
| `run_benchmarks.R` | Measures a finished run and compares. `OBJECT_PREFIX` required; `BENCH_EXECUTE=TRUE` to run. |
| `R/definitions.R` | How this algorithm operationalises "line of therapy" across twelve dimensions, each answer cited to file and line so a reader can check it. |
| `definitions_sources.csv` | The grid somebody with the documents fills in — 12 dimensions × 6 source slots. A summary or a recollection is rejected by name; the default falls to "not yet sourced", never to "agrees". |
| `run_definitions.R` | Renders the comparison. No warehouse — the rules are in the code, not the data. |
| `R/sensitivity.R` | Moves one threshold at a time, with the direction predicted before the run, so a metric moving the other way is a finding. Fourteen cells, each a complete LOT build under `LOT_CONTRACT_OVERRIDE` into a throwaway prefix. |
| `run_sensitivity.R` | Prints the grid, the predicted directions and the cell count by default; `SENS_EXECUTE=TRUE` builds them. |
| `R/stockpiling.R` | Sizes coverage-based regimen membership: what leftover cover would add or remove if it counted. Writes `STOCKPILE_AGENTS`, `STOCKPILE_IMPACT`, `STOCKPILE_BY_LOT`, `STOCKPILE_BY_MED`. |
| `run_stockpiling_rule.R` | Prints the rule; `STOCK_EXECUTE=TRUE` measures it. |
| `R/rechallenge.R` | Sizes re-challenge events — an agent returning — and the gap that decides each one. |
| `sql/rechallenge_evidence.sql` | The query behind it. |
| `run_rechallenge_evidence.R` | Prints what would be measured; opt-in to run. |
| `R/melphalan.R` | Measures the melphalan rule against a finished run without applying it. Writes `MELP_RULE_EXPOSURES`, `MELP_RULE_BRANCHES`, `MELP_RULE_IMPACT`. |
| `run_melphalan_rule.R` | Prints the rule and its settings; `MELP_EXECUTE=TRUE` measures it. |
| `tests/test_vignettes.R` | The catalogue cannot drift: the parameters have to exist, the boundary pairs have to straddle them and expect different things, the timelines have to run forwards, the cited files have to be there. |
| `tests/test_benchmarks.R` | The loader, the verdicts and the Kaplan-Meier arithmetic against a worked example. |
| `tests/test_definitions.R` | Our column against the code it cites, and the source grid against the one thing it exists to enforce. |
| `tests/test_sensitivity.R` | The grid, the guards and the comparison logic, driven with fabricated results. |
| `tests/test_stockpiling.R`, `tests/test_melphalan.R` | Each measurement's SQL, read as a string. |
| `out/` | Generated. `run_vignettes.R` and `run_definitions.R` write their CSVs and the vignette markdown table here; nothing reads them back. |

It counts **boundaries**, not lines. Subtracting boundaries added from boundaries
removed does not give a line count: moving a boundary changes which line an
exposure falls in, whether an agent is inside an induction window, regimen
membership, discontinuation dates and every later line number.

## `lot/melphalan/` — an exploration, not a rule

**Nothing here is in the study's numbers.** `apply_melp_rule` is pinned blank in
`CONTRACT`, blank generates the SQL the engine generated before this existed,
and every cell that names a mode records a contract deviation that the
questions, the dashboard and the benchmark harness all refuse. This is why the
proposal is described here, in the folder inventory, and not in `LOT_RULES.md`:
`LOT_RULES.md` is the confirmed rules, and this is not one of them.

What it is: a study-team proposal that a melphalan (`MELP`) administration
should advance the line on windows of its own, built as three complete LOT runs
— `reference`, `as_asked`, `yield_to_sct` — and differenced. Three builds rather
than arithmetic on a finished run, because the engine is sequential: a line's
end date sets the next line's start, which sets that line's induction window,
which decides which drugs join its regimen, which sets its discontinuation date,
which decides whether the line after it starts at all.

All three or none: a run where one mode failed reads like a finished experiment
and is not one. Cells write to `melp_reference_`, `melp_as_asked_` and
`melp_yield_to_sct_`, and a plan that would write to the study's own prefix is
refused.

| path | what it does |
|---|---|
| `run_aug1_melp.R` | Builds the comparison as three complete runs rather than estimating it. Prints the plan by default; `AUG1_EXECUTE=TRUE` builds. |
| `R/cells.R` | Which three builds, what is read off them, and the checks that they saw the same cohort, the same code lists, the same code and the same window. |
| `R/scenarios.R` | The study team's four worked patients, held as data. |
| `run_melp_scenarios.R` | Runs those scenarios through the shipped rule — the decision lifted out of the generated SQL rather than restated — and exits non-zero if any of them moves. No connection. |
| `read_melp_metrics.R` | Reads the comparison off cells that are already built. |
| `tests/test_aug1_melp.R` | That off is the absence of the rule, and the branch decision checked against the proposal. |

The rule itself is not in this folder — it is `lot/engine/R/melp_rule.R`,
because the engine builds the lines and the rule needs each line's own induction
window, which exists only while that line is being built. It is off by default
and off emits nothing.

### The proposal

An exposure is one administration; doses less than `melp_exposure_days` (30)
apart are the same exposure. Consecutive exposures are judged as a pair, on the
gap between them and on whether the first sits inside the line's induction
window:

| Branch | Condition | Effect | Against the shipped engine |
|---|---|---|---|
| A.1 | inside induction, gap < 180 | no boundary | agrees |
| A.2 | inside induction, gap ≥ 180 | the later dose advances the line | differs — today the repeat dose extends the line's run-out instead |
| B.1 | outside induction, gap < 60 | this dose starts a line | agrees, incidentally |
| B.2 | outside induction, 60 ≤ gap < 180 | no boundary | differs — today the first dose advances the line |
| B.3 | outside induction, gap ≥ 180 | the later dose advances the line | differs — today the first dose does |

It moves in both directions, so the net effect on line counts is not derivable:
A.2 makes more lines, B.2 and B.3 make fewer, and which wins depends on how many
patients sit in each branch. `run_melphalan_rule.R` in `lot/validation/` reports
the branch counts off a finished run without rebuilding anything.

**Two readings of a coded transplant**, which is why three cells are built
rather than two. High-dose melphalan is transplant conditioning, so a melphalan
claim and an AUTO code are often the same clinical event and the transplant rule
already fires on it. `as_asked` judges every exposure regardless; `yield_to_sct`
leaves an exposure with an AUTO within `melp_sct_days` (14) to the transplant
rule, so the melphalan rule fills only the gap where a transplant left no
procedure code. Every output row records which mode produced it.

**What B.2 does and does not do.** Suppressing B.2's boundaries stops melphalan
ending the line at either dose. It does not hold the line open to the second
dose. A line's discontinuation date is its base agents' last cover, and a
melphalan first seen outside the induction window is not a base agent, so it
does not extend that date — a line whose regimen runs out between the two doses
still ends there, and the second dose falls in whatever line follows.

### What has to be settled before it could be built for real

The measurement program had to pick an answer to some of these to run at all.
Where it did, the assumption is named. An assumption is not a decision.

1. Does the rule apply to melphalan alone, or to any agent used as transplant
   conditioning? As written it is drug-specific, which is a first for this
   algorithm — every other rule is about classes, windows and gaps. *The program
   assumes melphalan alone, through `melp_med_abbr`.* **Open.**

2. What happens when the transplant procedure code is also present? The AUTO
   rule and this rule would both fire on one clinical event. *The program runs
   both readings and writes the mode onto every row.* **Open.**

3. Is 30 days the exposure threshold, or 28? The build's medical day supply is
   28, so episodes already merge on that boundary. *The program uses 30.*
   **Confirmed by the worked examples.**

4. Third and later exposures. The proposal is written for a first and a next
   dose. *The program judges consecutive pairs.* **Confirmed by examples 3 and
   4.**

5. Does it apply at every line, or only at 1L? The induction window is 60 days
   at 1L and 30 later, so the branches land differently. *The program applies it
   at every line, against that line's own window.* **Confirmed by examples 3 and
   4.**

6. In B.2, does "both doses stay in the current line" mean the line has to be
   held open to the second dose? Half of this is settled — the worked examples
   say the second dose starts no line, and the boundary is removed at both
   doses. What is left open is whether the line has to be held open to reach it,
   which would need melphalan to join a regimen whose induction window it never
   entered: a change to what a regimen means rather than a setting, and a
   clinical decision. **Open**, and `n_b2_line_starts` is the number that
   settles it — MED-started lines whose start is a B.2 second dose, with
   `n_b2_melp_only` the subset no other agent could have started.

Neither mode is the proposal implemented to the letter: the mode names describe
the transplant reading, and on B.2 both take the narrow one above.

---

# Tests

None of them needs a connection. The study folder's `README.md` lists every
suite in one block, and the merge gate runs every one of them with a single exit
status — so "all suites pass" is recorded against a commit rather than reported
by whoever ran them.

```
Rscript lot/engine/tests/test_runner.R           # and test_line_criteria.R
Rscript lot/dashboard/tests/test_runner.R
Rscript lot/outcomes/tests/test_runner.R
Rscript lot/qc/tests/test_lot_qc.R
Rscript lot/questions/tests/test_setup.R
Rscript lot/validation/tests/test_vignettes.R    # and test_sensitivity.R,
                                                 # test_benchmarks.R,
                                                 # test_definitions.R,
                                                 # test_melphalan.R,
                                                 # test_stockpiling.R
Rscript lot/melphalan/tests/test_aug1_melp.R     # and run_melp_scenarios.R
```
