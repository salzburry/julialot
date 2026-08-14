# Overall cohort - the files

What each file in this build does. The criteria themselves are in `RULES.md`.
`build.R` is the entry point, `config.csv` holds every setting, `R/` is the
build and `R/steps/` the criteria - one file per phase, in the order they apply.

| path | what it does |
|---|---|
| `build.R` | Entry point. Takes the connection details, calls the runner, writes `OVERALL_COH_FINAL`. |
| `config.csv` | Every setting as `name,value,description`, applied as defaults before the config files are read, so a shell export always wins. |
| `R/build_cohort.R` | The runner. Executes the steps in order and stops at the first whose input is missing rather than skipping the filter that needed it. |
| `R/pipeline_steps.R` | The ordered list of view-building steps, one per phase file, so the criteria can be read a step at a time. |
| `R/criteria_attrition.R` | The criteria in the order they apply, which is also the attrition table's row order - the report ANDs them on cumulatively, so reordering changes both. |
| `R/config_prompts.R` | Configuration defaults, picked up after `config.csv` has been applied to the environment. |
| `R/load_inputs.R` | Reads `config.csv` into the environment as defaults. Never overrides a value already set, and never reads the password from the file. |
| `R/db_utils.R` | Connection, logging and step-running helpers. Also normalises the raw claim `ICD_FLAG`, naming both families explicitly rather than assuming anything unrecognised is ICD-10. |
| `R/steps/01_codelists.R` | Loads the five code lists into views the later phases join against. |
| `R/steps/02_dx_events.R` | Builds the myeloma diagnosis events: claim headers, then confinements, then the event tables. |
| `R/steps/03_index_date.R` | Every candidate index date - one inpatient or two outpatient diagnoses in the window. All are kept; the earliest surviving one is chosen at assembly. |
| `R/steps/04_enrollment.R` | Continuous enrolment through baseline, and enrolment on the index date itself. |
| `R/steps/05_demographics.R` | Age at index, and the death date that caps follow-up. |
| `R/steps/06_clinical_flags.R` | Myeloma agents in baseline and in follow-up, and a myeloma diagnosis in baseline. |
| `R/steps/07_exclusions.R` | The exclusions: another cancer, pregnancy, clinical trial. |
| `R/steps/08_assembly.R` | Joins every flag, applies the criteria, keeps each patient's earliest surviving index date. |
