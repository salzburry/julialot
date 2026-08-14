# NDMM cohort - the files

What each file in this build does. The criteria themselves are in `RULES.md`.
`build.R` builds the 1L cohort. `build_subsequent_cohorts.R` builds 2L and 3L
after the LOT run, because those index dates are line starts and only the LOT
build knows them. `R/steps/` is the criteria in the order they apply.

| path | what it does |
|---|---|
| `build.R` | Entry point for the 1L cohort, one cohort prefix per run. |
| `build_subsequent_cohorts.R` | Entry point for the 2L and 3L cohorts. Runs after the LOT build, since those index dates are line starts. |
| `other_malig_overlap.R` | Reports what the other-cancer list actually says about myeloma. Reads the CSVs only - no warehouse, no connection. |
| `config.csv` | Every setting as `name,value,description`. The cohort prefix is not here; the caller passes it. |
| `R/build_ndmm.R` | The runner. Stops when an input is missing rather than skipping the filter that needed it, because a count nobody can reproduce is worse than no count. |
| `R/build_subsequent.R` | The 2L and 3L cohorts, built as separate cohorts rather than flags on the lines, which is how the protocol scopes the extra criteria. |
| `R/config.R` | Settings, checked against `CONTRACT` before anything runs. |
| `R/load_inputs.R` | Reads `config.csv` into the environment as defaults. The environment always wins, and the password is never read from the file. |
| `R/codelists.R` | Loads the four code lists from CSV. There is no embedded fallback: a missing file stops the run. |
| `R/db_utils.R` | Connection, logging, naming and the step runner. Its table-naming helper adds the cohort prefix. |
| `R/ndmm_constants.R` | Names, windows and code-list overrides for this cohort. |
| `R/standalone_constants.R` | Names and settings for the diagnosis, demographics and 1L-index steps, kept separate so the constants file above stays at a fixed length. |
| `R/steps/00_mm_cohort.R` | The diagnosed adult population this cohort is drawn from - a qualifying diagnosis and age 18 or over, and nothing else. |
| `R/steps/00b_lot1_index.R` | The 1L index date: the first eligible myeloma treatment on or after the diagnosis. |
| `R/steps/01_enrollment.R` | Enrolment spans built from the raw table rather than the rollup, because the rollup bridges a gap of under 30 days while the study counts 30 or fewer as continuous. |
| `R/steps/02_lot1_starts.R` | The medication code list as a query fragment. Steroid rows are dropped here once, so every later query inherits the exclusion. |
| `R/steps/03_prior_therapy.R` | Myeloma therapy in the 12 months before the index date. |
| `R/steps/04_other_malig.R` | Another active cancer in the 12 months before the index date. |
| `R/steps/05_pregnancy.R` | Pregnancy or childbirth anywhere in the study period. |
| `R/steps/05b_preg_window.R` | Sizes what the narrower reading of the pregnancy window would cost, since the protocol and the program spec disagree on it. |
| `R/steps/06_flags.R` | One row per patient carrying every filter's verdict. |
| `R/steps/07_cohort.R` | The attrition counts. Each row applies all previous filters plus the new one, so it reads top to bottom as a funnel. |
| `R/steps/08_clintrial.R` | Clinical-trial evidence as a descriptive flag. Not a criterion - it filters nobody. |
