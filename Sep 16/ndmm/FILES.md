# NDMM cohort - the files

What each file does. How to run and configure the build is `README.md`; the
criteria are `RULES.md` and `DECISIONS.md`.

| path | what it does |
|---|---|
| `build.R` | Entry point for the 1L cohort, one cohort prefix per run. |
| `build_subsequent_cohorts.R` | Entry point for the 2L and 3L cohorts, run after the LOT build. |
| `config.csv` | Every default setting as `name,value,description`. The environment wins over it; the prefix and the password are not here. |
| `followup_days.sql` | Follow-up distribution over a built `NDMM_COHORT`, paste-and-run in a SQL editor. |
| `other_malig_overlap.R` | What `other_malig.csv` says about myeloma: codes it shares with `mm_dx.csv`, its plasma-cell labels, and which configured labels match. Reads the CSVs only - no warehouse. |
| `R/build_ndmm.R` | The runner: `CONTRACT`, `CHOICES`, `CHECKPOINTS`, `OUTPUTS`, the preflight checks, `NDMM_CRITERIA` and the attrition, the NDC and `ICD_FLAG` checks, the cohort table and the metadata and status writers. |
| `R/build_subsequent.R` | The 2L and 3L cohorts, their window check, lineage checks and attrition. |
| `R/load_inputs.R` | Reads `config.csv` into the environment as defaults; never reads `DATABRICKS_PWD`. |
| `R/config.R` | The settings, read from the environment. |
| `R/codelists.R` | Loads the five code lists from CSV, checks their columns and `icd_family`, and records each file's md5. A missing file stops the run. |
| `R/db_utils.R` | The run log, naming (the prefix is added here), the quarterly CDM table names, NDC keys, retries and the step runner. |
| `R/ndmm_constants.R` | View names, the windows the SQL reads, the MM-adjacent override labels and the steroid list. |
| `R/standalone_constants.R` | View names for the diagnosis, 1L-index and trial steps; `OUTPATIENT_WINDOW`, `MIN_AGE`, the belantamab abbreviation, the 1L index exclusions, the `NDMM_MM_ADJACENT_STATES` modes and the metastatic prefixes. |
| `R/steps/00_mm_cohort.R` | Criteria 1 and 2: the MM diagnosis, demographics, constructed death dates. |
| `R/steps/00b_lot1_index.R` | Criterion 3, the 1L index, and the belantamab claims for criterion 9. Also writes `NDMM_INDEX_AGENTS`, `NDMM_OTHER_MALIG_GROUPS`, `NDMM_OTHER_MALIG_GRAIN`, `NDMM_FU_CE_COUNTS`, `NDMM_BELANTAMAB_RECONCILE`, `NDMM_MM_ADJACENT_GROUPS` and `NDMM_MM_ADJACENT_CODES`. |
| `R/steps/01_enrollment.R` | Enrolment spans from `member_enrollment`, gap-bridged and no-gap. |
| `R/steps/02_lot1_starts.R` | A comment only; no code. |
| `R/steps/03_prior_therapy.R` | The MM therapy code list (steroids dropped) and its checks, and criterion 6. |
| `R/steps/04_other_malig.R` | Criterion 7: the other-cancer code list with its override flag and pairing groups, and the claim scan. |
| `R/steps/05_pregnancy.R` | Criterion 8. |
| `R/steps/05b_preg_window.R` | `NDMM_PREG_WINDOW_COUNTS` and its consistency checks. |
| `R/steps/06_flags.R` | `NDMM_FLAGS_ALL`, one row per candidate with every criterion's flag, and the cohort defined over it. |
| `R/steps/07_cohort.R` | The attrition counts. |
| `R/steps/08_clintrial.R` | `NDMM_CLINTRIAL_FLAGS`, the descriptive trial flag. |
| `tests/test_runner.R` | Tests of the 1L build. No warehouse needed. |
| `tests/test_subsequent.R` | Tests of the 2L and 3L build. No warehouse needed. |
| `tests/testutil.R` | Shared test helpers. |
