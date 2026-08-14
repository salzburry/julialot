# LOT - the files

What each file in this delivery does. The rules themselves are in
`RULES.md`.
`lot/engine/` builds the lines and is the only part that decides a clinical rule.
Everything beside it reads a finished run: `lot/qc/` checks it, `lot/validation/`
measures it, `lot/dashboard/` renders it, `lot/outcomes/` derives Table 4 from it,
`lot/questions/` answers specific asks off it. Each is entered through its own
`build.R` or `run_*.R`.

### engine - builds the lines

| path | what it does |
|---|---|
| `lot/engine/build.R` | Entry point. Takes a cohort table and an output prefix, and builds every line for it. |
| `lot/engine/config.csv` | Every setting as `name,value,description`. The cohort table and prefix are not here; the caller passes them. |
| `lot/engine/R/build_lot.R` | The runner, and `CONTRACT` - the pinned settings a run is checked against before it starts. Deviating needs an explicit override and is recorded in the run's status row. |
| `lot/engine/R/config_lot.R` | Reads the settings. The environment wins over `config.csv`. |
| `lot/engine/R/load_inputs.R` | Applies `config.csv` as defaults, never over a value already set, and never reads the password from it. |
| `lot/engine/R/codelists_lot.R` | Loads the four code lists from CSV. No embedded fallback - a missing file stops the run. |
| `lot/engine/R/db_utils_lot.R` | Connection, logging, table naming and the step runner. |
| `lot/engine/R/line_criteria.R` | Extra criteria on finished lines. Every one is computed into an all-flags table; only the enabled ones are applied to the final one. |
| `lot/engine/R/cart_rule.R` | The CAR-T induction rule: an infusion inside line 1's window belongs to line 1 and neither ends nor starts a line. |
| `lot/engine/R/melp_rule.R` | The melphalan rule. Off unless a mode is named, and off emits the same SQL as not having the file. It lives here because it needs each line's own induction window. |
| `lot/engine/R/steps/01_codelists.R` | Code lists into views, then the consistency checks between them. |
| `lot/engine/R/steps/02_patient_input.R` | The cohort as the build reads it. Sets the observation end date every later gap and window is measured against. |
| `lot/engine/R/steps/03_mma_map.R` | Claims into medication available periods. A new period opens only for a claim beyond every runout; one arriving while cover is live pushes the runout out instead. |
| `lot/engine/R/steps/04_lot1_base.R` | Line 1's start, its induction medications and its base regimen. |
| `lot/engine/R/steps/05_sct.R` | Transplant and CAR-T events: autologous, allogeneic, CAR-T. |
| `lot/engine/R/steps/05b_lot1_sct.R` | Line 1's own transplant summary, which needs line 1's base and so is not part of what a later-lines-only run rebuilds. |
| `lot/engine/R/steps/06_lot1_end.R` | Line 1's end date and end reason. |
| `lot/engine/R/steps/07_qc.R` | Counts on what was just built, recorded with the run. |
| `lot/engine/R/steps/08_persist.R` | Writes the outputs, every one through the prefix helper so a run cannot overwrite another cohort's. |
| `lot/engine/R/steps/10_lot2_5_base.R` | Lines 2 to 5: their start candidates, regimens, run-outs and ends. The largest file here, and the one that decides where later lines begin. |

### reading a finished run

| path | what it does |
|---|---|
| `lot/qc/run_lot_qc.R` | Runs the checks against a finished run and refuses one whose own build did not complete. |
| `lot/qc/R/checks.R` | The checks as data - one entry per check, each carrying the query that finds violations, so the catalogue can be read without running it. |
| `lot/outcomes/build.R` | Entry point for treatment patterns and treatment-related outcomes, protocol Table 4. |
| `lot/outcomes/R/build_outcomes.R` | Computes those outcomes off one finished run. Builds no line and no cohort of its own. |
| `lot/outcomes/R/run_outcomes.R` | Resolves which run owns the tables, refuses anything it cannot vouch for, then writes the five output tables. |
| `lot/outcomes/R/config_out.R` | Settings, all about which run to read. Nothing here defines a clinical rule. |
| `lot/outcomes/R/db_utils_out.R`, `lot/outcomes/R/load_inputs.R` | Connection, logging and settings helpers for that package. |
| `lot/dashboard/build.R` | Entry point. Renders one cohort's dashboard after the cohort and line builds. |
| `lot/dashboard/R/sections.R` | What the dashboard shows. Every panel is one entry - a name, a tab, its query and how to draw the answer. |
| `lot/dashboard/R/render.R` | Writes one self-contained HTML file using base R only, so a missing plotting package cannot silently produce nothing. |
| `lot/dashboard/R/db_utils_dash.R` | Reading only. This package creates, replaces and drops nothing, which is what makes it safe to re-run against a finished study. |
| `lot/dashboard/R/build_dashboard.R`, `R/config_dash.R`, `R/load_inputs.R` | The runner and its settings. |

### validation - measuring the algorithm

| path | what it does |
|---|---|
| `lot/validation/R/run_binding.R` | Works out which run actually wrote the tables about to be measured, since the tables themselves do not say. |
| `lot/validation/R/benchmarks.R` | This algorithm's distributions - lines per patient, regimen frequencies, durations - beside published figures. |
| `lot/validation/R/definitions.R` | How this algorithm operationalises "line of therapy", each answer cited to file and line so a reader can check it. |
| `lot/validation/R/sensitivity.R` | Moves one threshold at a time, with the direction predicted before the run, so a metric moving the other way is a finding. |
| `lot/validation/R/stockpiling.R` | Sizes coverage-based regimen membership: what leftover cover would add or remove if it counted. |
| `lot/validation/R/rechallenge.R` | Sizes re-challenge events - an agent returning - and the gap that decides each one. |
| `lot/validation/R/melphalan.R` | Measures the melphalan rule against a finished run without applying it. |
| `lot/validation/R/vignettes.R` | The edge cases the algorithm is hardest on, each with the assignment the rules give. A specification, not observed data. |
| `lot/validation/run_benchmarks.R` | One runner per module above - benchmarks, definitions, sensitivity, stockpiling, rechallenge, melphalan, vignettes. Each prints what it would measure and needs no connection until asked to run. |

### the rest

| path | what it does |
|---|---|
| `lot/melphalan/run_aug1_melp.R` | Builds the melphalan comparison as three complete runs rather than estimating it, because moving one boundary changes every later line. |
| `lot/melphalan/R/cells.R` | Which three builds, what is read off them, and the checks that they saw the same cohort and code lists. |
| `lot/melphalan/R/scenarios.R` | The study team's worked patients, run through the shipped rule rather than a copy of it. |
| `lot/melphalan/run_melp_scenarios.R` | Runs those scenarios and exits non-zero if any of them moves. |
| `lot/melphalan/read_melp_metrics.R` | Reads the comparison off cells that are already built. |
| `lot/questions/lot1_studyteam_qs.R` | One script per study-team ask - line 1, POMA, the July-20 set, the follow-ups, the broad-cohort ones - each writing its own CSVs or workbook. |
| `lot/questions/_setup.R` | Shared setup, using the engine's own modules rather than a second copy so the two cannot drift. |
| `lot/questions/validation_helpers.R` | The analysis behind those questions, shared with the dashboard's exploratory tables. |
| `lot/safety/run_safety_codelists.R` | Reports what the protocol's safety and utilisation code lists still need. |
| `lot/safety/R/codelists_safety.R` | Loads them. The codes themselves are not in this repository. |
| `lot/tools/remove_steroids_from_rollup.R` | Removes steroid rows from the production medication rollup. Reports by default; changes nothing unless told to. |
