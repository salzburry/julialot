#!/usr/bin/env Rscript
# ============================================================
# GSK MM LOT - Domino (R) -> ODBC -> Databricks Pipeline
# Pipeline-hardened runner with DB-side logging
# ============================================================
#
# Validated against:
# - Optum CDM Data Dictionary v9.0 (18-08-2025)
# - Optum Business Rules document (30_08_2022)
#
# Key features:
# - Automatic reconnect with exponential backoff (with_retry wrapper)
# - DB-side run log (audit trail)
# - Ping before each heavy step (handles stale ODBC sessions)
# - Idempotent steps (CREATE OR REPLACE)
# - QC counts after each step
# - Independent flags per IE criterion (per StudyPop spec)
# - Split MM dx events: study period (baseline) vs ID period (qualification)
# - Strict no-gap enrollment for CE_3mosf (per StudyPop spec)
# - Death_dt derivation with month-level generalization to 15th
# - ENDDATE/FU_DAYS properly account for Death_dt per StudyPop spec
#
# Optum Business Rules compliance:
# - Inpatient: Approach 1 (POS/TOS) OR Approach 2 (CONF_ID in T_CONFINEMENT)
# - Confinement: Requires BOTH ADMIT_DATE and DISCH_DATE
# - Enrollment: Uses prebuilt member_cont_enrollment for standard spans (<30 day gaps)
# - Strict CE: Uses member_enrollment (raw) for CE_3mosf (no-gap sensitivity)
# - Non-diagnostic claims: Claim-level logic (has diagnostic line = diagnostic)
# - DOD: Uses YMDOD field, includes joinability QC validation
# - Exclusion flags: Configurable application (pregnancy, clinical trial, etc.)
#
# Usage:
#   Rscript R/run_pipeline_hardened.R
#
# Environment variables:
#   DATABRICKS_PWD        - Databricks password/token (required)
#   DATABRICKS_DSN        - ODBC DSN name (default: "RWDE")
#   DOMINO_USER_NAME      - Used for personal schema (optional)
#   OPTUM_CDM_SCHEMA, PROJECT_WORK_SCHEMA, PROJECT_REF_SCHEMA
 
library(DBI)
library(odbc)
library(glue)
library(dplyr)   # Required for tbl() function
library(dbplyr)  # Required for sql_render() used by GSK helpers
 
# Source GSK helper functions for personal schema operations
source("/mnt/code/R/helperScripts/databases/personalSchemaFunctions.R")
 
# ============================================================
# DEFAULT CONFIGURATION
# ============================================================
default_cfg <- list(
  # Schemas (following Optum CDM / Domino naming convention)
  # cdm_schema maps to dbname in 001_setup.R pattern
  cdm_schema  = "clnprw_optum",
  ref_schema  = Sys.getenv("DOMINO_USER_NAME", unset = "gsk_mm_lot_ref"),
  work_schema = Sys.getenv("DOMINO_USER_NAME", unset = "gsk_mm_lot_work"),
 
  # Source tables (Optum Clinformatics Data Mart v9.0)
  tbl_member_elig       = "member_cont_enrollment",
  tbl_member_enrollment = "member_enrollment",      # Raw enrollment (not pre-rolled)
  tbl_medical           = "medical",
  tbl_med_diag          = "med_diagnosis",
  tbl_rx                = "rx",
  tbl_dod               = "dod",
  tbl_confinement       = "confinement",            # Per Optum business rules Approach 2
 
  # Quarterly table pattern (Optum tables are partitioned as t_<table>_YYYYqQ)
  # Set to TRUE if your tables are quarterly-partitioned (e.g., t_medical_2017q1)
  use_quarterly_tables = TRUE,
 
  # Study parameters (per DataPrep spec dated 19 Jan 2026)
  study_start    = "2015-07-01",
  study_end      = "2025-06-30",
  id_start       = "2016-01-01",
  id_end         = "2025-06-30",
  baseline_days  = 183,
  gap_days       = 30,
  dx_window_30   = 30,
  dx_window_60   = 60,
  dx_window_90   = 90
)
 
# ============================================================
# CLI PROMPT FOR USER INPUT (no global mutation)
# ============================================================
prompt_user_options <- function() {
  # Work on local copy, not global
  user_cfg <- default_cfg
 
  # Resolve schemas from environment (no prompting for schemas)
  user_cfg$cdm_schema  <- Sys.getenv("OPTUM_CDM_SCHEMA", unset = user_cfg$cdm_schema)
  user_cfg$ref_schema  <- Sys.getenv("PROJECT_REF_SCHEMA", unset = user_cfg$ref_schema)
  user_cfg$work_schema <- Sys.getenv("PROJECT_WORK_SCHEMA", unset = user_cfg$work_schema)
 
  cat("\n")
  cat("============================================================\n")
  cat("  MM LOT ATTRITION COHORT PIPELINE\n")
  cat("============================================================\n")
  cat("\nDefault Configuration:\n")
  cat("  CDM Schema:       ", user_cfg$cdm_schema, "\n")
  cat("  Reference Schema: ", user_cfg$ref_schema, "\n")
  cat("  Work Schema:      ", user_cfg$work_schema, "\n")
  cat("  Study Period:     ", user_cfg$study_start, " to ", user_cfg$study_end, "\n")
  cat("  ID Period:        ", user_cfg$id_start, " to ", user_cfg$id_end, "\n")
  cat("  Baseline Days:    ", user_cfg$baseline_days, "\n")
  cat("  Gap Days:         ", user_cfg$gap_days, "\n")
  cat("  DX Windows:       ", user_cfg$dx_window_30, "/", user_cfg$dx_window_60, "/", user_cfg$dx_window_90, " days\n")
  cat("\n")
 
  if (should_prompt()) {
    cat("Run with default options? [Y/n]: ")
    response <- readline()
    if (tolower(trimws(response)) %in% c("n", "no")) {
      cat("\nCustomize options (press Enter to keep default):\n")
     
      cat("  Study Start Date [", user_cfg$study_start, "]: ", sep = "")
      val <- readline()
      if (nzchar(trimws(val))) user_cfg$study_start <- trimws(val)
     
      cat("  Study End Date [", user_cfg$study_end, "]: ", sep = "")
      val <- readline()
      if (nzchar(trimws(val))) user_cfg$study_end <- trimws(val)
     
      cat("  ID Start Date [", user_cfg$id_start, "]: ", sep = "")
      val <- readline()
      if (nzchar(trimws(val))) user_cfg$id_start <- trimws(val)
     
      cat("  ID End Date [", user_cfg$id_end, "]: ", sep = "")
      val <- readline()
      if (nzchar(trimws(val))) user_cfg$id_end <- trimws(val)
     
      cat("  Baseline Days [", user_cfg$baseline_days, "]: ", sep = "")
      val <- readline()
      if (nzchar(trimws(val))) user_cfg$baseline_days <- as.integer(trimws(val))
     
      cat("  Gap Days [", user_cfg$gap_days, "]: ", sep = "")
      val <- readline()
      if (nzchar(trimws(val))) user_cfg$gap_days <- as.integer(trimws(val))
    }
  }
 
  cat("\nUsing configuration:\n")
  cat("  CDM Schema:       ", user_cfg$cdm_schema, "\n")
  cat("  Reference Schema: ", user_cfg$ref_schema, "\n")
  cat("  Work Schema:      ", user_cfg$work_schema, "\n")
  cat("  Study Period:     ", user_cfg$study_start, " to ", user_cfg$study_end, "\n")
  cat("  ID Period:        ", user_cfg$id_start, " to ", user_cfg$id_end, "\n")
  cat("  Embedded Codes:   ", if (isTRUE(as.logical(Sys.getenv("USE_EMBEDDED_CODES", unset = "TRUE")))) "YES (no external ref tables needed)" else "NO (external tables required)", "\n")
  cat("  Quarterly Tables: ", if (isTRUE(user_cfg$use_quarterly_tables)) "YES (t_<table>_YYYYqQ pattern)" else "NO (single tables)", "\n")
  cat("============================================================\n\n")
 
  return(user_cfg)
}
 
# ============================================================
# INTERACTIVE IE CRITERIA SELECTION
# ============================================================
# Prompts user for each inclusion/exclusion criterion before running
# Returns a list of criteria settings to apply in Step 24
 
prompt_ie_criteria <- function() {
  criteria <- list(
    # Inclusion criteria (defaults)
    apply_age = TRUE,
    min_age = 18,
    apply_ce_baseline = TRUE,
    apply_ce_followup = TRUE,
    apply_no_baseline_therapy = TRUE,
    apply_followup_therapy = TRUE,
    outpatient_window = 90,  # 30, 60, or 90 days
   
    # Exclusion criteria (defaults)
    apply_pregnancy_excl = TRUE,
    apply_clintrial_excl = TRUE,
    apply_other_malig_excl = TRUE,
    apply_baseline_nondx_excl = FALSE
  )
 
  if (!should_prompt()) {
    cat("Non-interactive mode: using IE criteria from environment variables / config\n")
    cat("  (Set PROMPT_USER=TRUE to enable interactive prompts under Rscript)\n")
    # FIXED: Return cfg values (from env vars) instead of hard-coded defaults
    return(list(
      # Inclusion criteria - use cfg values (from env vars)
      apply_age = cfg$apply_age_incl,
      min_age = cfg$min_age,
      apply_ce_baseline = cfg$apply_ce_b_incl,
      apply_ce_followup = cfg$apply_ce_f_incl,
      apply_no_baseline_therapy = cfg$apply_no_bl_agents_incl,
      apply_followup_therapy = cfg$apply_fu_agents_incl,
      outpatient_window = cfg$outpatient_window,
      # Exclusion criteria - use cfg values (from env vars)
      apply_pregnancy_excl = cfg$apply_pregnancy_excl,
      apply_clintrial_excl = cfg$apply_clintrial_excl,
      apply_other_malig_excl = cfg$apply_other_malig_excl,
      apply_baseline_nondx_excl = cfg$apply_baseline_nondx_excl
    ))
  }
 
  cat("\n")
  cat("============================================================\n")
  cat("  INCLUSION / EXCLUSION CRITERIA SELECTION\n")
  cat("============================================================\n")
  cat("\nFor each criterion, enter Y (apply), N (skip), or a new value.\n")
  cat("Press Enter to keep the default shown in brackets.\n\n")
 
  # Helper function for Y/N prompts
  ask_yn <- function(prompt, default) {
    default_str <- if (default) "Y" else "N"
    cat(prompt, " [", default_str, "]: ", sep = "")
    response <- tolower(trimws(readline()))
    if (response == "") return(default)
    return(response %in% c("y", "yes", "1", "true"))
  }
 
  # Helper function for numeric prompts
  ask_num <- function(prompt, default) {
    cat(prompt, " [", default, "]: ", sep = "")
    response <- trimws(readline())
    if (response == "") return(default)
    return(as.integer(response))
  }
 
  # Helper function for choice prompts
  ask_choice <- function(prompt, choices, default) {
    cat(prompt, " [", default, "]: ", sep = "")
    response <- trimws(readline())
    if (response == "") return(default)
    val <- as.integer(response)
    if (val %in% choices) return(val)
    cat("  Invalid choice, using default: ", default, "\n")
    return(default)
  }
 
  cat("--- INCLUSION CRITERIA ---\n\n")
 
  # 1. Age criterion
  criteria$apply_age <- ask_yn("Apply Age >= 18 criterion?", criteria$apply_age)
  if (criteria$apply_age) {
    criteria$min_age <- ask_num("  Minimum age", criteria$min_age)
  }
 
  # 2. Outpatient confirmation window (30/60/90 days)
  cat("\nOutpatient MM Diagnosis Confirmation Window:\n")
  cat("  Requires 2 outpatient claims within X days for non-inpatient patients\n")
  cat("  Options: 30, 60, or 90 days\n")
  criteria$outpatient_window <- ask_choice("Select window (30/60/90)", c(30, 60, 90), criteria$outpatient_window)
 
  # 3. Continuous enrollment - baseline
  cat("\n")
  criteria$apply_ce_baseline <- ask_yn("Apply 6-month baseline enrollment (CE_b=1)?", criteria$apply_ce_baseline)
 
  # 4. Continuous enrollment - follow-up
  criteria$apply_ce_followup <- ask_yn("Apply 1+ day follow-up enrollment (CE_f=1)?", criteria$apply_ce_followup)
 
  # 5. No baseline therapy
  criteria$apply_no_baseline_therapy <- ask_yn("Apply no MM therapy in baseline (MM_bl_agents=0)?", criteria$apply_no_baseline_therapy)
 
  # 6. Follow-up therapy required
  criteria$apply_followup_therapy <- ask_yn("Apply MM therapy in follow-up required (MM_FU_agents=1)?", criteria$apply_followup_therapy)
 
  cat("\n--- EXCLUSION CRITERIA ---\n\n")
 
  # 7. Pregnancy exclusion
  criteria$apply_pregnancy_excl <- ask_yn("Exclude patients with pregnancy claims?", criteria$apply_pregnancy_excl)
 
  # 8. Clinical trial exclusion
  criteria$apply_clintrial_excl <- ask_yn("Exclude patients in clinical trials?", criteria$apply_clintrial_excl)
 
  # 9. Other malignancy exclusion
  criteria$apply_other_malig_excl <- ask_yn("Exclude patients with other malignancies?", criteria$apply_other_malig_excl)
 
  # NOTE: Baseline non-diagnostic claim exclusion is hardcoded to FALSE
  # (diagnostic code list is incomplete, causes 81% false exclusion rate)
  criteria$apply_baseline_nondx_excl <- FALSE
 
  # Show summary and confirm
  cat("\n")
  cat("============================================================\n")
  cat("  CRITERIA SUMMARY\n")
  cat("============================================================\n")
  cat("\nINCLUSION CRITERIA:\n")
  cat("  [", if(criteria$apply_age) "X" else " ", "] Age >= ", criteria$min_age, "\n", sep = "")
  cat("  [", if(criteria$apply_ce_baseline) "X" else " ", "] 6-month baseline enrollment (CE_b=1)\n", sep = "")
  cat("  [", if(criteria$apply_ce_followup) "X" else " ", "] 1+ day follow-up enrollment (CE_f=1)\n", sep = "")
  cat("  [", if(criteria$apply_no_baseline_therapy) "X" else " ", "] No MM therapy in baseline\n", sep = "")
  cat("  [", if(criteria$apply_followup_therapy) "X" else " ", "] MM therapy in follow-up required\n", sep = "")
  cat("  [X] Outpatient confirmation window: ", criteria$outpatient_window, " days\n", sep = "")
 
  cat("\nEXCLUSION CRITERIA:\n")
  cat("  [", if(criteria$apply_pregnancy_excl) "X" else " ", "] Pregnancy\n", sep = "")
  cat("  [", if(criteria$apply_clintrial_excl) "X" else " ", "] Clinical trial participation\n", sep = "")
  cat("  [", if(criteria$apply_other_malig_excl) "X" else " ", "] Other malignancies\n", sep = "")
 
  cat("\n============================================================\n")
  cat("Proceed with these criteria? [Y/n]: ")
  response <- tolower(trimws(readline()))
  if (response %in% c("n", "no")) {
    cat("\nRestarting criteria selection...\n")
    return(prompt_ie_criteria())  # Recursive call to restart
  }
 
  cat("\nCriteria confirmed. Proceeding with pipeline...\n\n")
  return(criteria)
}
 
# ============================================================
# CONFIGURATION (merged from defaults and environment)
# ============================================================
cfg <- list(
  # Connection (Domino ODBC pattern: DSN + password)
  dsn = Sys.getenv("DATABRICKS_DSN", unset = "RWDE"),
  pwd = Sys.getenv("DATABRICKS_PWD", unset = ""),
 
  # Schemas (following Optum CDM naming convention)
  # dbname equivalent from setup.R: "clnprw_optum"
  # personal_schema equivalent: Sys.getenv("DOMINO_USER_NAME")
  catalog    = Sys.getenv("DATABRICKS_CATALOG", unset = "hive_metastore"),
  cdm_schema = Sys.getenv("OPTUM_CDM_SCHEMA", unset = "clnprw_optum"),
  ref_schema = Sys.getenv("PROJECT_REF_SCHEMA", unset = Sys.getenv("DOMINO_USER_NAME", unset = "gsk_mm_lot_ref")),
  work_schema = Sys.getenv("PROJECT_WORK_SCHEMA", unset = Sys.getenv("DOMINO_USER_NAME", unset = "gsk_mm_lot_work")),
 
  # Source tables (Optum Clinformatics)
  tbl_member_elig       = "member_cont_enrollment",
  tbl_member_enrollment = "member_enrollment",      # Raw enrollment (not pre-rolled)
  tbl_medical           = "medical",
  tbl_med_diag          = "med_diagnosis",
  tbl_rx                = "rx",
  tbl_dod               = "dod",
  tbl_confinement       = "confinement",            # Per Optum business rules Approach 2
 
  # Quarterly table pattern (Optum tables are partitioned as t_<table>_YYYYqQ)
  # Set to TRUE if your tables are quarterly-partitioned (e.g., t_medical_2017q1)
  use_quarterly_tables = as.logical(Sys.getenv("USE_QUARTERLY_TABLES", unset = "TRUE")),
 
  # Code list tables (used only if use_embedded_codes = FALSE and no CSV files)
  cl_mm_dx           = "cl_mm_dx",
  cl_diagnostic_proc = "cl_diagnostic_proc",
  cl_mm_therapy      = "cl_mm_therapy",
  cl_preg            = "cl_pregnancy",
  cl_clintrial       = "cl_clintrial",
  cl_other_malig     = "cl_other_malignancies",
 
  # ============================================================
  # CODE LIST SOURCE PRIORITY (checked in order):
  # 1. CSV files from codelist_dir (if directory exists and file found)
  # 2. Embedded codes (if use_embedded_codes = TRUE)
  # 3. External tables from ref_schema (fallback)
  # ============================================================
  # Directory containing CSV code list files
  # Expected files: mm_dx.csv, diagnostic_proc.csv, mm_therapy.csv,
  #                 pregnancy.csv, clintrial.csv, other_malig.csv
  codelist_dir = Sys.getenv("CODELIST_DIR", unset = "/mnt/code/codelist"),
 
  # Use embedded codes as fallback if CSV not found (set FALSE to require CSV/external tables)
  use_embedded_codes = as.logical(Sys.getenv("USE_EMBEDDED_CODES", unset = "FALSE")),
 
  # Study parameters (per DataPrep spec dated 19 Jan 2026)
  study_start    = "2015-07-01",
  study_end      = "2025-06-30",
  id_start       = "2016-01-01",
  id_end         = "2025-06-30",
  baseline_days  = 183,
  gap_days       = 30,
  dx_window_30   = 30,
  dx_window_60   = 60,
  dx_window_90   = 90,
 
  # Pipeline controls
  max_retries = 4,
  base_sleep  = 5,
 
  # ============================================================
  # RUN MODE CONTROL
  # ============================================================
  # FULL        = Run all steps (default)
  # BASE_ONLY   = Build flags only (Steps 1-23), skip final filter
  # FILTER_ONLY = Skip base build, apply criteria from ELIG_COH_ALLFLAGS only (Step 24+)
  run_mode = toupper(Sys.getenv("RUN_MODE", unset = "FULL")),
 
  # Output table naming (allows multiple cohort versions)
  final_table_name = Sys.getenv("FINAL_TABLE_NAME", unset = "ELIG_COH_FINAL"),
 
  # ============================================================
  # INCLUSION/EXCLUSION CRITERIA (defaults - overridden by interactive prompt)
  # ============================================================
  # These are default values; when running interactively, prompt_ie_criteria()
  # will ask the user for each criterion and update cfg accordingly.
 
  # Outpatient confirmation window: 30, 60, or 90 days
  # Affects which flag is used: outpt2_30, outpt2_60, or outpt2_90
  outpatient_window = as.integer(Sys.getenv("OUTPATIENT_WINDOW", unset = "90")),
 
  # Inclusion criteria toggles
  apply_age_incl          = as.logical(Sys.getenv("APPLY_AGE_INCL", unset = "TRUE")),
  min_age                 = as.integer(Sys.getenv("MIN_AGE", unset = "18")),
 
  apply_ce_b_incl         = as.logical(Sys.getenv("APPLY_CE_B_INCL", unset = "TRUE")),
  apply_ce_f_incl         = as.logical(Sys.getenv("APPLY_CE_F_INCL", unset = "TRUE")),
 
  apply_no_bl_agents_incl = as.logical(Sys.getenv("APPLY_NO_BL_AGENTS_INCL", unset = "TRUE")),
  apply_fu_agents_incl    = as.logical(Sys.getenv("APPLY_FU_AGENTS_INCL", unset = "TRUE")),
 
  # ============================================================
  # EXCLUSION CRITERIA TOGGLES (set TRUE to apply in final filter)
  # ============================================================
  # These are computed as independent flags; set to TRUE to apply as exclusions
  apply_pregnancy_excl     = as.logical(Sys.getenv("APPLY_PREGNANCY_EXCL", unset = "FALSE")),
  apply_clintrial_excl     = as.logical(Sys.getenv("APPLY_CLINTRIAL_EXCL", unset = "FALSE")),
  apply_other_malig_excl   = as.logical(Sys.getenv("APPLY_OTHER_MALIG_EXCL", unset = "FALSE")),
  apply_baseline_nondx_excl = as.logical(Sys.getenv("APPLY_BASELINE_NONDX_EXCL", unset = "FALSE")),  # Smoldering flag
 
  # Create config-driven VIEW for interactive toggling (Option 2)
  create_criteria_view = as.logical(Sys.getenv("CREATE_CRITERIA_VIEW", unset = "FALSE")),
 
  # ============================================================
  # DYNAMIC IE CRITERIA ORDERING (interactive only)
  # ============================================================
  # When TRUE, after building all flags (Steps 1-23), the pipeline enters
  # an interactive loop where the user selects IE criteria one at a time
  # in any order, sees patient counts after each criterion, and can stop
  # at any point to finalize the cohort.
  # Requires interactive mode (PROMPT_USER=TRUE or interactive()).
  dynamic_ie_order = as.logical(Sys.getenv("DYNAMIC_IE_ORDER", unset = "TRUE")),
 
  # Persist final cohort to personal schema (uses lazy table approach)
  persist_to_schema = as.logical(Sys.getenv("PERSIST_TO_SCHEMA", unset = "TRUE")),
  personal_schema = Sys.getenv("DOMINO_USER_NAME", unset = Sys.getenv("DOMINO_STARTING_USERNAME", unset = "")),
 
  # ============================================================
  # PERFORMANCE: MATERIALIZE CHECKPOINTS
  # ============================================================
  # Set TRUE to materialize key intermediate tables to personal schema
  # This breaks Spark lazy evaluation and dramatically speeds up the pipeline
  # Checkpoint tables: mm_dx_events_all, mm_qualifying, claim_nondiagnostic, ELIG_COH_ALLFLAGS
  # HARDCODED: Always materialize checkpoints to personal schema for performance
  # This breaks Spark lazy evaluation and dramatically speeds up the pipeline
  materialize_checkpoints = TRUE
)
 
# Steps to materialize to personal schema (breaks lazy eval chain)
CHECKPOINT_STEPS <- c("mm_dx_events_all", "mm_qualifying", "claim_nondiagnostic", "ELIG_COH_ALLFLAGS")
 
run_id <- Sys.getenv("DOMINO_RUN_ID", unset = format(Sys.time(), "%Y%m%d%H%M%S"))
 
# ============================================================
# CONNECTION ENVIRONMENT (fixes scope bug for reconnection)
# ============================================================
con_env <- new.env()
con_env$con <- NULL
 
# ============================================================
# HELPER FUNCTIONS
# ============================================================
 
# Pre-computed separator strings (avoid repeated strrep() calls)
SEP_59 <- strrep("=", 59)
SEP_60 <- strrep("=", 60)
SEP_70 <- strrep("=", 70)
DASH_60 <- strrep("-", 60)
DASH_70 <- strrep("-", 70)
 
# ============================================================
# PROMPTING CONTROL
# ============================================================
# By default, Rscript runs with interactive() == FALSE, so prompts won't show.
# Use PROMPT_USER=TRUE env var to force prompting even under Rscript.
 
should_prompt <- function() {
  isTRUE(as.logical(Sys.getenv("PROMPT_USER", unset = "TRUE"))) || interactive()
}
 
# ============================================================
# VALIDATION HELPERS
# ============================================================
 
# Force outpatient window to valid values (30/60/90) per IE spec
validate_outpatient_window <- function(x, default = 90L) {
  x <- suppressWarnings(as.integer(x))
  if (is.na(x) || !(x %in% c(30L, 60L, 90L))) return(default)
  x
}
# Convert R logical to SQL boolean literal
bool_sql <- function(x) if (isTRUE(x)) "true" else "false"
 
full_name <- function(schema, object) {
  if (nzchar(cfg$catalog)) {
    paste0(cfg$catalog, ".", schema, ".", object)
  } else {
    paste0(schema, ".", object)
  }
}
 
cdm <- function(tbl) full_name(cfg$cdm_schema, tbl)
ref <- function(tbl) full_name(cfg$ref_schema, tbl)
# Use temp views for work tables - no schema needed
work <- function(tbl) tbl
 
# Alias for work() - checks if table has been materialized to personal schema
# Used in reporting/QC queries that run AFTER potential materialization
work_tbl <- function(name) {
  if (exists(name, envir = materialized_tables)) {
    return(get(name, envir = materialized_tables))
  }
  return(name)
}
 
# ============================================================
# MATERIALIZATION HELPERS (for checkpoint tables)
# Uses GSK createInPersonalSchema helper from personalSchemaFunctions.R
# ============================================================
# Track which tables have been materialized to personal schema
materialized_tables <- new.env()
 
# Materialize a temp view to personal schema using GSK helper
# This breaks Spark lazy evaluation chain for better performance
materialize_to_personal_schema <- function(con, view_name, replace = TRUE) {
  if (!nzchar(cfg$personal_schema)) {
    log_msg("WARN: personal_schema not set, skipping materialization of ", view_name)
    return(FALSE)
  }
 
  remote_table <- tolower(view_name)
  full_table_name <- paste0(cfg$personal_schema, ".", remote_table)
 
  log_msg("  >> Materializing ", view_name, " to ", full_table_name, "...")
 
  tryCatch({
    # Create pointer to the temp view
    pointer <- tbl(con, view_name)
   
    # GSK helper expects 'con' in global environment
    assign("con", con, envir = .GlobalEnv)
   
    # Use GSK helper to create table in personal schema
    createInPersonalSchema(pointer, remote_table, replace = replace)
   
    # Create a view alias so subsequent steps using the temp view name
    # will read from the materialized table (avoids recomputation)
    alias_sql <- glue("CREATE OR REPLACE TEMPORARY VIEW {view_name} AS SELECT * FROM {full_table_name}")
    DBI::dbExecute(con, alias_sql)
   
    # Track that this table is now materialized
    assign(view_name, full_table_name, envir = materialized_tables)
    log_msg("  >> Materialized successfully (view alias created)")
    TRUE
  }, error = function(e) {
    log_msg("  >> WARN: Materialization failed: ", conditionMessage(e))
    FALSE
  })
}
 
log_msg <- function(...) {
  cat(sprintf("[%s] ", format(Sys.time(), "%Y-%m-%d %H:%M:%S")), ..., "\n")
  flush.console()  # Ensure output is shown immediately
}
 
# ============================================================
# CODE LIST LOADING (CSV -> Embedded -> External tables)
# ============================================================
 
# Load a code list from CSV file and convert to SQL VALUES clause
# Returns NULL if file doesn't exist
load_codelist_csv <- function(csv_name, col_spec) {
  csv_path <- file.path(cfg$codelist_dir, csv_name)
  if (!file.exists(csv_path)) {
    return(NULL)
  }
 
  tryCatch({
    df <- read.csv(csv_path, stringsAsFactors = FALSE, colClasses = "character")
    if (nrow(df) == 0) {
      log_msg("WARNING: Empty CSV file: ", csv_path)
      return(NULL)
    }
   
    # Build VALUES clause from dataframe
    # col_spec is a vector of column names in the CSV that map to the VALUES columns
    rows <- apply(df[, col_spec, drop = FALSE], 1, function(row) {
      vals <- sapply(row, function(v) {
        if (is.na(v) || v == "") "NULL" else paste0("'", gsub("'", "''", v), "'")
      })
      paste0("(", paste(vals, collapse = ", "), ")")
    })
   
    col_names <- paste(col_spec, collapse = ", ")
    sql <- paste0("SELECT * FROM (VALUES\n    ", paste(rows, collapse = ",\n    "), "\n  ) AS t(", col_names, ")")
    log_msg("Loaded codelist from CSV: ", csv_path, " (", nrow(df), " rows)")
    return(sql)
  }, error = function(e) {
    log_msg("WARNING: Failed to load CSV ", csv_path, ": ", e$message)
    return(NULL)
  })
}
 
# Get code source with priority: CSV > Embedded > External table
# csv_name: filename in codelist_dir (e.g., "mm_dx.csv")
# col_spec: column names expected in CSV
# embedded_fn: function returning embedded SQL
# external_ref: table name in ref_schema
get_code_source <- function(embedded_fn, external_ref, csv_name = NULL, col_spec = NULL) {
  # Priority 1: Try CSV file if csv_name provided
  if (!is.null(csv_name) && !is.null(col_spec) && dir.exists(cfg$codelist_dir)) {
    csv_sql <- load_codelist_csv(csv_name, col_spec)
    if (!is.null(csv_sql)) {
      return(paste0("(", csv_sql, ") src"))
    }
  }
 
  # Priority 2: Use embedded codes if enabled
  if (isTRUE(cfg$use_embedded_codes)) {
    return(paste0("(", embedded_fn(), ") src"))
  }
 
  # Priority 3: Fall back to external table
  ref(external_ref)
}
 
# ============================================================
# QUARTERLY TABLE HELPERS
# Optum data is stored in cumulative quarterly tables: t_<table>_YYYYqQ
# Each table contains ALL data up to that quarter (not just that quarter)
# e.g., t_medical_2025q2 contains all medical data through June 2025
# ============================================================
 
# Get the quarter suffix for a given date (returns "YYYYqQ" format)
get_quarter_suffix <- function(end_date) {
  dt <- as.Date(end_date)
  year <- as.integer(format(dt, "%Y"))
  quarter <- ceiling(as.integer(format(dt, "%m")) / 3)
  sprintf("%dq%d", year, quarter)
}
 
# Get the quarterly table name for a base table
# e.g., "medical" with end_date "2025-06-30" -> "t_medical_2025q2"
get_quarterly_table <- function(base_table, end_date = cfg$study_end) {
  quarter_suffix <- get_quarter_suffix(end_date)
  paste0("t_", base_table, "_", quarter_suffix)
}
 
# Get qualified name for quarterly table source
# Uses the cumulative quarterly table that covers the study end date
cdm_quarterly <- function(base_table, end_date = cfg$study_end) {
  tbl_name <- get_quarterly_table(base_table, end_date)
  full_name(cfg$cdm_schema, tbl_name)
}
 
# Wrapper to get CDM table - uses quarterly if enabled, single table otherwise
cdm_src <- function(tbl_name) {
  if (isTRUE(cfg$use_quarterly_tables)) {
    cdm_quarterly(tbl_name)
  } else {
    cdm(tbl_name)
  }
}
 
# ============================================================
# EMBEDDED CODE LISTS (avoids external table dependencies)
# Multiple Myeloma ICD-9/ICD-10 diagnosis codes
# ============================================================
embedded_mm_dx_codes <- function() {
  # BROAD codes (203.x / C90.x) for Step 0 and outpatient Step 1
  # STRICT codes (203.0x / C90.0x) for inpatient Step 1 and Step 7 baseline evidence
  # Per attrition table: inpatient requires 203.0x/C90.0x, outpatient allows 203.x/C90.x
  "
  SELECT * FROM (VALUES
    -- STRICT: 203.0x Multiple myeloma
    ('ICD9', '2030'),    -- Multiple myeloma (unspecified)
    ('ICD9', '20300'),   -- MM without remission
    ('ICD9', '20301'),   -- MM in remission
    ('ICD9', '20302'),   -- MM in relapse
    -- BROAD: 203.1x Plasma cell leukemia
    ('ICD9', '2031'),    -- Plasma cell leukemia (unspecified)
    ('ICD9', '20310'),   -- Plasma cell leukemia without remission
    ('ICD9', '20311'),   -- Plasma cell leukemia in remission
    ('ICD9', '20312'),   -- Plasma cell leukemia in relapse
    -- BROAD: 203.8x Other immunoproliferative neoplasms
    ('ICD9', '2038'),    -- Other immunoproliferative neoplasms (unspecified)
    ('ICD9', '20380'),   -- Other immunoproliferative neoplasms without remission
    ('ICD9', '20381'),   -- Other immunoproliferative neoplasms in remission
    ('ICD9', '20382'),   -- Other immunoproliferative neoplasms in relapse
    -- STRICT: C90.0x Multiple myeloma
    ('ICD10', 'C900'),   -- Multiple myeloma (unspecified)
    ('ICD10', 'C9000'),  -- MM not having achieved remission
    ('ICD10', 'C9001'),  -- MM in remission
    ('ICD10', 'C9002'),  -- MM in relapse
    -- BROAD: C90.1x Plasma cell leukemia
    ('ICD10', 'C901'),   -- Plasma cell leukemia (unspecified)
    ('ICD10', 'C9010'),  -- Plasma cell leukemia not having achieved remission
    ('ICD10', 'C9011'),  -- Plasma cell leukemia in remission
    ('ICD10', 'C9012'),  -- Plasma cell leukemia in relapse
    -- BROAD: C90.2x Extramedullary plasmacytoma
    ('ICD10', 'C902'),   -- Extramedullary plasmacytoma (unspecified)
    ('ICD10', 'C9020'),  -- Extramedullary plasmacytoma not having achieved remission
    ('ICD10', 'C9021'),  -- Extramedullary plasmacytoma in remission
    ('ICD10', 'C9022'),  -- Extramedullary plasmacytoma in relapse
    -- BROAD: C90.3x Solitary plasmacytoma
    ('ICD10', 'C903'),   -- Solitary plasmacytoma (unspecified)
    ('ICD10', 'C9030'),  -- Solitary plasmacytoma not having achieved remission
    ('ICD10', 'C9031'),  -- Solitary plasmacytoma in remission
    ('ICD10', 'C9032')   -- Solitary plasmacytoma in relapse
  ) AS t(icd_family, dx)
  "
}
 
embedded_diag_proc_codes <- function() {
  "
  SELECT * FROM (VALUES
    ('99201'), ('99202'), ('99203'), ('99204'), ('99205'),  -- New patient E/M
    ('99211'), ('99212'), ('99213'), ('99214'), ('99215'),  -- Established patient E/M
    ('99241'), ('99242'), ('99243'), ('99244'), ('99245'),  -- Consults
    ('G0438'), ('G0439')  -- AWV codes
  ) AS t(proc_cd)
  "
}
 
embedded_mm_therapy_codes <- function() {
  "
  SELECT * FROM (VALUES
    ('HCPCS', 'J9041'),   -- Bortezomib
    ('HCPCS', 'J9042'),   -- Bortezomib (generic)
    ('HCPCS', 'J9043'),   -- Cabazitaxel
    ('HCPCS', 'J9047'),   -- Carfilzomib
    ('HCPCS', 'J9145'),   -- Daratumumab
    ('HCPCS', 'J9176'),   -- Elotuzumab
    ('HCPCS', 'J9223'),   -- Lenalidomide
    ('HCPCS', 'J9228'),   -- Pomalidomide
    ('HCPCS', 'J9300'),   -- Thalidomide
    ('NDC', '59572098010'), -- Revlimid (lenalidomide)
    ('NDC', '59572098020'),
    ('NDC', '63020004901'), -- Velcade (bortezomib)
    ('NDC', '63020004902')
  ) AS t(code_type, code)
  "
}
 
embedded_preg_codes <- function() {
  # Per IE spec: "diagnosis, procedure, or revenue code indicating pregnancy or childbirth"
  # EXPANDED: Added broader O-chapter codes, ICD-9 pregnancy range, and delivery revenue codes
  "
  SELECT * FROM (VALUES
    -- ICD-10 Pregnancy DX codes (O-chapter)
    ('DX', 'Z33'),     -- Pregnant state incidental
    ('DX', 'Z3400'), ('DX', 'Z3401'), ('DX', 'Z3402'), ('DX', 'Z3403'),  -- Supervision of pregnancy
    ('DX', 'Z3A'),     -- Weeks of gestation
    ('DX', 'O00'),     -- Ectopic pregnancy
    ('DX', 'O03'),     -- Spontaneous abortion
    ('DX', 'O04'),     -- Complications following abortion
    ('DX', 'O09'),     -- Supervision of high-risk pregnancy
    ('DX', 'O10'),     -- Pre-existing hypertension complicating pregnancy
    ('DX', 'O24'),     -- Diabetes mellitus in pregnancy
    ('DX', 'O26'),     -- Maternal care for other conditions
    ('DX', 'O30'),     -- Multiple gestation
    ('DX', 'O60'),     -- Preterm labor
    ('DX', 'O68'),     -- Labor complicated by fetal stress
    ('DX', 'O70'),     -- Perineal laceration during delivery
    ('DX', 'O80'),     -- Encounter for full-term uncomplicated delivery
    ('DX', 'O82'),     -- Encounter for cesarean delivery
    -- ICD-9 Pregnancy DX codes
    ('DX', 'V22'),     -- Normal pregnancy supervision
    ('DX', 'V23'),     -- High-risk pregnancy supervision
    ('DX', 'V27'),     -- Outcome of delivery
    ('DX', '630'),     -- Hydatidiform mole
    ('DX', '631'),     -- Other abnormal product of conception
    ('DX', '632'),     -- Missed abortion
    ('DX', '640'),     -- Hemorrhage in early pregnancy
    ('DX', '650'),     -- Normal delivery
    ('DX', '660'),     -- Obstructed labor
    ('DX', '669'),     -- Other complications of labor
    -- Delivery procedure codes
    ('PROC', '59400'), ('PROC', '59510'), ('PROC', '59610'),  -- Vaginal/cesarean delivery
    ('PROC', '59409'), ('PROC', '59514'), ('PROC', '59612'),  -- Additional delivery codes
    -- Revenue codes indicating obstetric/delivery services
    ('REV', '0720'),   -- Labor room/delivery
    ('REV', '0721'),   -- Labor room
    ('REV', '0722'),   -- Delivery room
    ('REV', '0723'),   -- Circumcision
    ('REV', '0724'),   -- Birthing center
    ('REV', '0729')    -- Other labor room/delivery
  ) AS t(code_type, code)
  "
}
 
embedded_clintrial_codes <- function() {
  # FIXED: Z0089 is not clinical-trial-specific (it's a general exam code - false positives)
  # Replaced with Z00.6 (Z006) which is the correct ICD-10 for clinical trial encounters
  # Added ICD-9 V70.7 (V707) for clinical investigation participation
  # Added revenue code 0762 (investigational services) for completeness
  "
  SELECT * FROM (VALUES
    ('DX', 'Z006'),    -- Encounter for examination for normal comparison/control in clinical research
    ('DX', 'V707'),    -- ICD-9 Examination of participant in clinical trial
    ('PROC', '99199'), -- Unlisted special service/procedure (clinical trial admin)
    ('REV', '0762')    -- Investigational services revenue code
  ) AS t(code_type, code)
  "
}
 
embedded_other_malig_codes <- function() {
  "
  SELECT * FROM (VALUES
    ('LUNG', 'ICD10', 'C34'),
    ('LUNG', 'ICD10', 'C340'),
    ('LUNG', 'ICD10', 'C341'),
    ('BREAST', 'ICD10', 'C50'),
    ('BREAST', 'ICD10', 'C500'),
    ('COLON', 'ICD10', 'C18'),
    ('COLON', 'ICD10', 'C19'),
    ('PROSTATE', 'ICD10', 'C61'),
    ('LUNG', 'ICD9', '162'),
    ('BREAST', 'ICD9', '174'),
    ('COLON', 'ICD9', '153'),
    ('PROSTATE', 'ICD9', '185')
  ) AS t(tumor_group, icd_family, dx)
  "
}
 
# ============================================================
# ATTRITION TRACKER - Stores and prints counts at each step
# ============================================================
attrition <- new.env()
attrition$counts <- list()
 
record_attrition <- function(step_name, description, n_30, n_60, n_90) {
  attrition$counts[[step_name]] <- list(
    description = description,
    n_30 = n_30,
    n_60 = n_60,
    n_90 = n_90,
    timestamp = Sys.time()
  )
}
 
print_attrition_table <- function() {
  cat("\n")
  cat(strrep("=", 110), "\n")
  cat("                              ATTRITION TABLE SUMMARY (30d / 60d / 90d)\n")
  cat(strrep("=", 110), "\n")
  cat(sprintf("%-40s %12s %12s %12s %12s %12s %12s\n",
              "Step", "N (30d)", "Excl (30d)", "N (60d)", "Excl (60d)", "N (90d)", "Excl (90d)"))
  cat(strrep("-", 110), "\n")
 
  prev_30 <- NA
  prev_60 <- NA
  prev_90 <- NA
  for (step in names(attrition$counts)) {
    item <- attrition$counts[[step]]
    excl_30 <- if (is.na(prev_30)) "" else format(prev_30 - item$n_30, big.mark = ",")
    excl_60 <- if (is.na(prev_60)) "" else format(prev_60 - item$n_60, big.mark = ",")
    excl_90 <- if (is.na(prev_90)) "" else format(prev_90 - item$n_90, big.mark = ",")
    cat(sprintf("%-40s %12s %12s %12s %12s %12s %12s\n",
                substr(item$description, 1, 40),
                format(item$n_30, big.mark = ","), excl_30,
                format(item$n_60, big.mark = ","), excl_60,
                format(item$n_90, big.mark = ","), excl_90))
    prev_30 <- item$n_30
    prev_60 <- item$n_60
    prev_90 <- item$n_90
  }
 
  cat(strrep("=", 110), "\n")
  cat("\n")
}
 
# ============================================================
# DYNAMIC IE CRITERIA FILTER
# Interactive loop: user picks criteria in any order, can stop early
# Requires ELIG_COH_ALLFLAGS to be built (Steps 1-23)
# ============================================================
 
run_dynamic_ie_filter <- function() {
  con <- con_env$con
 
  # Define all IE criteria (Steps 1-10) with their SQL conditions
  # Step 1 has window-specific SQL; all others are window-independent
  all_criteria <- list(
    list(step_id = 1,
         label = "Qualifying dx (IP strict OR 2 OP in 30/60/90d window)",
         type = "Inclusion",
         sql_30 = "(inpt_qual = 1 OR outpt2_30 = 1)",
         sql_60 = "(inpt_qual = 1 OR outpt2_60 = 1)",
         sql_90 = "(inpt_qual = 1 OR outpt2_90 = 1)"),
    list(step_id = 2,
         label = "Age >= 18 at index year",
         type = "Inclusion",
         sql = "AGE_INDEX_YR >= 18"),
    list(step_id = 3,
         label = "FU therapy required (MM_FU_agents = 1)",
         type = "Inclusion",
         sql = "MM_FU_agents = 1"),
    list(step_id = 4,
         label = "No baseline therapy (MM_bl_agents = 0)",
         type = "Exclusion",
         sql = "MM_bl_agents = 0"),
    list(step_id = 5,
         label = "6-month baseline enrollment (CE_b = 1)",
         type = "Inclusion",
         sql = "CE_b = 1"),
    list(step_id = 6,
         label = "1+ day follow-up enrollment (CE_f = 1)",
         type = "Inclusion",
         sql = "CE_f = 1"),
    list(step_id = 7,
         label = "No baseline MM dx evidence (MM_baseline_diag = 0)",
         type = "Exclusion",
         sql = "MM_baseline_diag = 0"),
    list(step_id = 8,
         label = "No other cancer in baseline (OTHER_MALIGN_FLAG = 0)",
         type = "Exclusion",
         sql = "OTHER_MALIGN_FLAG = 0"),
    list(step_id = 9,
         label = "No pregnancy (PREGNANT_FLAG = 0)",
         type = "Exclusion",
         sql = "PREGNANT_FLAG = 0"),
    list(step_id = 10,
         label = "No clinical trial (CLINTRIAL = 0)",
         type = "Exclusion",
         sql = "CLINTRIAL_BASELINE = 0 AND CLINTRIAL_FOLLOWUP = 0")
  )
 
  tbl_name <- work_tbl('ELIG_COH_ALLFLAGS')
 
  # Cumulative SQL clauses per window (diverge only when Step 1 is applied)
  clauses_30 <- c()
  clauses_60 <- c()
  clauses_90 <- c()
 
  # Track applied criteria in user-chosen order
  applied_criteria <- list()
  remaining_criteria <- all_criteria
 
  # Helper: build WHERE clause from a vector of conditions
  build_where <- function(clauses) {
    if (length(clauses) == 0) return("1=1")
    paste(clauses, collapse = " AND ")
  }
 
  # Helper: count distinct patients for all 3 windows
  get_counts <- function(c30, c60, c90) {
    n30 <- DBI::dbGetQuery(con, glue("SELECT count(DISTINCT PATID) AS n FROM {tbl_name} WHERE {build_where(c30)}"))$n
    n60 <- DBI::dbGetQuery(con, glue("SELECT count(DISTINCT PATID) AS n FROM {tbl_name} WHERE {build_where(c60)}"))$n
    n90 <- DBI::dbGetQuery(con, glue("SELECT count(DISTINCT PATID) AS n FROM {tbl_name} WHERE {build_where(c90)}"))$n
    list(n_30 = n30, n_60 = n60, n_90 = n90)
  }
 
  # Step 0: Base cohort (all patients in ELIG_COH_ALLFLAGS, no filters)
  current <- get_counts(clauses_30, clauses_60, clauses_90)
 
  cat("\n")
  cat(strrep("=", 90), "\n")
  cat("  DYNAMIC IE CRITERIA SELECTION\n")
  cat("  Select criteria in any order. Enter 0 to finalize cohort at current state.\n")
  cat(strrep("=", 90), "\n")
  cat(sprintf("\nStep 0 (Base Cohort): %s patients with >= 1 MM dx\n",
              format(current$n_30, big.mark = ",")))
  cat(sprintf("  30-day: %-12s | 60-day: %-12s | 90-day: %-12s\n\n",
              format(current$n_30, big.mark = ","),
              format(current$n_60, big.mark = ","),
              format(current$n_90, big.mark = ",")))
 
  # Record Step 0 in attrition tracker
  record_attrition("dyn_00_base", "Step 0: Base cohort (>= 1 MM dx)",
                   current$n_30, current$n_60, current$n_90)
 
  apply_counter <- 0
 
  # ---- Interactive loop ----
  repeat {
    if (length(remaining_criteria) == 0) {
      cat("\nAll criteria have been applied.\n")
      break
    }
   
    # Display current counts
    cat(strrep("-", 90), "\n")
    cat(sprintf("Current patients:  30-day: %-12s | 60-day: %-12s | 90-day: %-12s\n",
                format(current$n_30, big.mark = ","),
                format(current$n_60, big.mark = ","),
                format(current$n_90, big.mark = ",")))
    cat(strrep("-", 90), "\n")
   
    # Display remaining criteria
    cat("\nAVAILABLE CRITERIA:\n\n")
    for (crit in remaining_criteria) {
      cat(sprintf("  [%2d] %-55s (%s)\n", crit$step_id, crit$label, crit$type))
    }
    cat(sprintf("\n  [ 0] FINALIZE COHORT (stop here, use current counts as final)\n"))
    cat(strrep("-", 90), "\n")
   
    # Get user choice
    cat("\nEnter criterion number to apply next (0 to finalize): ")
    response <- trimws(readline())
    choice <- suppressWarnings(as.integer(response))
   
    if (is.na(choice)) {
      cat("Invalid input. Please enter a number from the list above.\n")
      next
    }
   
    if (choice == 0) {
      cat("\nFinalizing cohort with current criteria...\n")
      break
    }
   
    # Find chosen criterion in remaining list
    match_idx <- which(sapply(remaining_criteria, function(c) c$step_id) == choice)
    if (length(match_idx) == 0) {
      cat(sprintf("Criterion %d is not available. Please choose from the list above.\n", choice))
      next
    }
   
    chosen <- remaining_criteria[[match_idx]]
    apply_counter <- apply_counter + 1

    # Add SQL clauses (Step 1 has window-specific SQL)
    if (chosen$step_id == 1) {
      clauses_30 <- c(clauses_30, chosen$sql_30)
      clauses_60 <- c(clauses_60, chosen$sql_60)
      clauses_90 <- c(clauses_90, chosen$sql_90)
    } else {
      clauses_30 <- c(clauses_30, chosen$sql)
      clauses_60 <- c(clauses_60, chosen$sql)
      clauses_90 <- c(clauses_90, chosen$sql)
    }

    # Count patients with new cumulative criteria
    prev <- current
    current <- get_counts(clauses_30, clauses_60, clauses_90)

    # Display results
    cat(sprintf("\n>> Applied Step %d: %s\n", chosen$step_id, chosen$label))
    cat(sprintf("   30-day: %s -> %s  (excluded: %s)\n",
                format(prev$n_30, big.mark = ","),
                format(current$n_30, big.mark = ","),
                format(prev$n_30 - current$n_30, big.mark = ",")))
    cat(sprintf("   60-day: %s -> %s  (excluded: %s)\n",
                format(prev$n_60, big.mark = ","),
                format(current$n_60, big.mark = ","),
                format(prev$n_60 - current$n_60, big.mark = ",")))
    cat(sprintf("   90-day: %s -> %s  (excluded: %s)\n\n",
                format(prev$n_90, big.mark = ","),
                format(current$n_90, big.mark = ","),
                format(prev$n_90 - current$n_90, big.mark = ",")))

    # Record in attrition tracker
    record_attrition(
      sprintf("dyn_%02d_step%d", apply_counter, chosen$step_id),
      sprintf("Applied %d: Step %d - %s", apply_counter, chosen$step_id, chosen$label),
      current$n_30, current$n_60, current$n_90
    )
   
    # Move from remaining to applied
    applied_criteria <- c(applied_criteria, list(chosen))
    remaining_criteria <- remaining_criteria[-match_idx]
  }
 
  # ---- Create final cohort view ----
  cat("\n")
  cat(strrep("=", 90), "\n")
  cat("  CREATING FINAL COHORT\n")
  cat(strrep("=", 90), "\n")
 
  # Build final WHERE for configured outpatient window
  final_where <- switch(as.character(cfg$outpatient_window),
                        "30" = build_where(clauses_30),
                        "60" = build_where(clauses_60),
                        build_where(clauses_90)  # default to 90
  )
 
  # Create final cohort view (earliest qualifying index per patient)
  final_sql <- glue("
    CREATE OR REPLACE TEMPORARY VIEW {work(cfg$final_table_name)} AS
    WITH filtered AS (
      SELECT * FROM {tbl_name}
      WHERE {final_where}
    ),
    ranked AS (
      SELECT *, row_number() OVER (PARTITION BY PATID ORDER BY INDEX_DATE) AS rn
      FROM filtered
    )
    SELECT * FROM ranked WHERE rn = 1
  ")
 
  DBI::dbExecute(con, final_sql)
 
  final_count <- DBI::dbGetQuery(con, glue(
    "SELECT count(*) AS n FROM {work(cfg$final_table_name)}"
  ))$n
  record_attrition("dyn_99_final",
                   glue("FINAL ({cfg$final_table_name}, earliest index, {cfg$outpatient_window}d)"),
                   final_count, final_count, final_count)
 
  cat(sprintf("\nFinal cohort (%s): %s patients (earliest index per patient, %dd window)\n",
              cfg$final_table_name,
              format(final_count, big.mark = ","),
              cfg$outpatient_window))
 
  # ---- Print attrition summary ----
  print_attrition_table()
 
  # ---- Show criteria application order summary ----
  cat("\nCriteria applied in order:\n")
  for (i in seq_along(applied_criteria)) {
    crit <- applied_criteria[[i]]
    cat(sprintf("  %d. Step %d: %s (%s)\n", i, crit$step_id, crit$label, crit$type))
  }
  if (length(remaining_criteria) > 0) {
    cat("\nCriteria NOT applied (user finalized early):\n")
    for (crit in remaining_criteria) {
      cat(sprintf("  - Step %d: %s (%s)\n", crit$step_id, crit$label, crit$type))
    }
  }
  cat("\n")
 
  # ---- Persist to personal schema if configured ----
  if (isTRUE(cfg$persist_to_schema) && nzchar(cfg$personal_schema)) {
    log_msg("Persisting final cohort to personal schema...")
    tryCatch({
      persist_sql <- glue("
        CREATE OR REPLACE TABLE {cfg$catalog}.{cfg$personal_schema}.{cfg$final_table_name} AS
        SELECT * FROM {work(cfg$final_table_name)}
      ")
      DBI::dbExecute(con, persist_sql)
      n_persisted <- DBI::dbGetQuery(con, glue(
        "SELECT count(*) AS n FROM {cfg$catalog}.{cfg$personal_schema}.{cfg$final_table_name}"
      ))$n
      log_msg("Persisted final cohort to ", cfg$catalog, ".", cfg$personal_schema, ".",
              cfg$final_table_name, " (", format(n_persisted, big.mark = ","), " rows)")
    }, error = function(e) {
      log_msg("WARN: Failed to persist final cohort: ", conditionMessage(e))
    })
  }
}
 
# ============================================================
# CONNECTION WITH RETRY (returns value, not just TRUE)
# Follows Domino ODBC pattern: DSN + password
# ============================================================
 
connect_databricks <- function() {
  # Validate password is set
 
  if (!nzchar(cfg$pwd)) {
    stop("DATABRICKS_PWD environment variable is not set. Please set it before running the pipeline.")
  }
 
  # Connect using Domino ODBC pattern (matches 001_setup.R)
  DBI::dbConnect(
    odbc::odbc(),
    dsn = cfg$dsn,
    pwd = cfg$pwd,
    timeout = 120
  )
}
 
db_ping <- function(con) {
  tryCatch({
    DBI::dbGetQuery(con, "SELECT 1 AS ok")
    TRUE
  }, error = function(e) FALSE)
}
 
# Fixed: with_retry now returns fn() result, not just TRUE
with_retry <- function(fn, max_retries = cfg$max_retries, base_sleep = cfg$base_sleep) {
  attempt <- 1
  repeat {
    result <- tryCatch(fn(), error = function(e) e)
    if (!inherits(result, "error")) return(result)
   
    if (attempt >= max_retries) stop(result)
   
    sleep_s <- base_sleep * (2^(attempt - 1))
    log_msg("Retryable failure: ", conditionMessage(result))
    log_msg("Retrying in ", sleep_s, "s (attempt ", attempt + 1, "/", max_retries, ")")
    Sys.sleep(sleep_s)
    attempt <- attempt + 1
  }
}
 
sql_exec <- function(con, sql) {
  DBI::dbExecute(con, sql)
}
 
# ============================================================
# DB-SIDE RUN LOG (fixed TIMESTAMP literal)
# ============================================================
 
ensure_run_log <- function(con) {
  # Skip DB logging - return NULL so write_log_row() no-ops
  NULL
}
 
# Fixed: TIMESTAMP literal syntax for Databricks
write_log_row <- function(con, log_table, step_name, status, started_at, ended_at,
                          qc_metric = NA, qc_value = NA, error_message = NA) {
  # Skip DB logging if log_table is NULL
  if (is.null(log_table)) return(invisible(NULL))
 
  duration <- as.numeric(difftime(ended_at, started_at, units = "secs"))
  esc <- function(x) gsub("'", "''", as.character(x))
 
  sql_exec(con, glue("
    INSERT INTO {log_table} VALUES (
      '{esc(run_id)}',
      '{esc(step_name)}',
      '{esc(status)}',
      TIMESTAMP '{format(started_at, '%Y-%m-%d %H:%M:%S')}',
      TIMESTAMP '{format(ended_at, '%Y-%m-%d %H:%M:%S')}',
      {duration},
      {if (is.na(qc_metric)) 'NULL' else paste0(\"'\", esc(qc_metric), \"'\")},
      {if (is.na(qc_value)) 'NULL' else paste0(\"'\", esc(qc_value), \"'\")},
      {if (is.na(error_message)) 'NULL' else paste0(\"'\", esc(error_message), \"'\")}
    )
  "))
}
 
# ============================================================
# STEP RUNNER (fixed: uses con_env for reconnection)
# ============================================================
 
print_phase_header <- function(phase_name) {
  cat("\n")
  cat(SEP_60, "\n")
  cat("  PHASE: ", phase_name, "\n")
  cat(SEP_60, "\n")
  flush.console()
}
 
run_step <- function(log_table, step_name, sql, qc_sql = NULL, description = NULL, step_num = NULL, total_steps = NULL, source_tables = NULL) {
  started_at <- Sys.time()
 
  # Show progress header with step number
  progress_prefix <- if (!is.null(step_num) && !is.null(total_steps)) {
    sprintf("[Step %d/%d] ", step_num, total_steps)
  } else {
    ""
  }
 
  step_desc <- if (!is.null(description)) description else step_name
  cat("\n")
  cat(DASH_60, "\n")
  log_msg(progress_prefix, step_desc)
 
  # Show which source tables will be accessed (helps user know what's happening)
  if (!is.null(source_tables) && length(source_tables) > 0) {
    log_msg("  >> Reading from: ", paste(source_tables, collapse = ", "))
  }
 
  cat(DASH_60, "\n")
  flush.console()
 
  tryCatch({
    # Ping before heavy work (handles stale ODBC sessions)
    if (!db_ping(con_env$con)) {
      log_msg("Connection stale, reconnecting with retry...")
      try(DBI::dbDisconnect(con_env$con), silent = TRUE)
      # FIXED: Use with_retry for reconnection (handles transient network failures)
      con_env$con <- with_retry(function() {
        conn <- connect_databricks()
        log_msg("Reconnected to Databricks")
        conn
      })
    }
   
    # Execute main SQL
    sql_exec(con_env$con, sql)
   
    # Run QC query if provided (must return small result)
    qc_metric <- NA
    qc_value <- NA
    if (!is.null(qc_sql)) {
      qc <- DBI::dbGetQuery(con_env$con, qc_sql)
      qc_metric <- colnames(qc)[1]
      qc_value <- as.character(qc[[1]][1])
      # Format count with commas for readability (only if numeric)
      numeric_val <- suppressWarnings(as.numeric(qc_value))
      formatted_value <- if (!is.na(numeric_val)) {
        format(numeric_val, big.mark = ",")
      } else {
        qc_value
      }
      log_msg("  >> Result: ", qc_metric, " = ", formatted_value)
      flush.console()
    }
   
    ended_at <- Sys.time()
    duration_secs <- round(as.numeric(difftime(ended_at, started_at, units = "secs")), 1)
    write_log_row(con_env$con, log_table, step_name, "SUCCESS", started_at, ended_at,
                  qc_metric = qc_metric, qc_value = qc_value)
   
    log_msg("  >> Completed in ", duration_secs, "s")
    flush.console()
   
  }, error = function(e) {
    ended_at <- Sys.time()
    # Try to log failure (may fail if connection is bad)
    tryCatch(
      write_log_row(con_env$con, log_table, step_name, "FAIL", started_at, ended_at,
                    error_message = conditionMessage(e)),
      error = function(e2) log_msg("Could not write failure log: ", conditionMessage(e2))
    )
    log_msg("STEP FAILED: ", step_name, " - ", conditionMessage(e))
    stop(e)
  })
}
 
# ============================================================
# PIPELINE STEPS
# Each step is idempotent (CREATE OR REPLACE)
# Each criterion is an independent flag per StudyPop spec
# Fixed: Split MM dx events for baseline (study period) vs qualification (ID period)
# Fixed: Added FU_DAYS_CE, CE_3mosf
# Fixed: Non-diagnostic claim NULL PROC_CD edge case
# ============================================================
 
build_steps <- function() {
  # ============================================================
  # CODE LIST SOURCES (Priority: CSV files > Embedded > External tables)
  # CSV files expected in: cfg$codelist_dir (default: /mnt/artifacts/codelist)
  # ============================================================
  # CSV format requirements:
  #   mm_dx.csv:         icd_family, dx
  #   diagnostic_proc.csv: proc_cd
  #   mm_therapy.csv:    code_type, code
  #   pregnancy.csv:     code_type, code
  #   clintrial.csv:     code_type, code
  #   other_malig.csv:   tumor_group, icd_family, dx
 
  mm_dx_source <- get_code_source(
    embedded_mm_dx_codes, cfg$cl_mm_dx,
    csv_name = "mm_dx.csv", col_spec = c("icd_family", "dx")
  )
  diag_proc_source <- get_code_source(
    embedded_diag_proc_codes, cfg$cl_diagnostic_proc,
    csv_name = "diagnostic_proc.csv", col_spec = c("proc_cd")
  )
  mm_therapy_source <- get_code_source(
    embedded_mm_therapy_codes, cfg$cl_mm_therapy,
    csv_name = "mm_therapy.csv", col_spec = c("code_type", "code")
  )
  preg_source <- get_code_source(
    embedded_preg_codes, cfg$cl_preg,
    csv_name = "pregnancy.csv", col_spec = c("code_type", "code")
  )
  clintrial_source <- get_code_source(
    embedded_clintrial_codes, cfg$cl_clintrial,
    csv_name = "clintrial.csv", col_spec = c("code_type", "code")
  )
  other_malig_source <- get_code_source(
    embedded_other_malig_codes, cfg$cl_other_malig,
    csv_name = "other_malig.csv", col_spec = c("tumor_group", "icd_family", "dx")
  )
 
  # ============================================================
  # BUILD COMBINED CRITERIA SQL (inclusions + exclusions)
  # ============================================================
  # This implements the "build flags once, apply criteria later" pattern
  # per the IE specification: each criterion is an independent flag,
 
  # merged forward, and can be toggled without rebuilding Steps 1-23.
  criteria_clauses <- c()
 
  # --- INCLUSION TOGGLES ---
  if (isTRUE(cfg$apply_age_incl) && !is.na(cfg$min_age)) {
    criteria_clauses <- c(criteria_clauses, glue("AND AGE_INDEX_YR >= {cfg$min_age}"))
  }
  if (isTRUE(cfg$apply_ce_b_incl)) {
    criteria_clauses <- c(criteria_clauses, "AND CE_b = 1")
  }
  if (isTRUE(cfg$apply_ce_f_incl)) {
    criteria_clauses <- c(criteria_clauses, "AND CE_f = 1")
  }
  if (isTRUE(cfg$apply_no_bl_agents_incl)) {
    criteria_clauses <- c(criteria_clauses, "AND MM_bl_agents = 0")
  }
  if (isTRUE(cfg$apply_fu_agents_incl)) {
    criteria_clauses <- c(criteria_clauses, "AND MM_FU_agents = 1")
  }
 
  # --- EXCLUSION TOGGLES ---
  if (isTRUE(cfg$apply_pregnancy_excl)) {
    criteria_clauses <- c(criteria_clauses, "AND PREGNANT_FLAG = 0")
  }
  if (isTRUE(cfg$apply_clintrial_excl)) {
    criteria_clauses <- c(criteria_clauses, "AND CLINTRIAL_BASELINE = 0 AND CLINTRIAL_FOLLOWUP = 0")
  }
  if (isTRUE(cfg$apply_other_malig_excl)) {
    criteria_clauses <- c(criteria_clauses, "AND OTHER_MALIGN_FLAG = 0")
  }
  if (isTRUE(cfg$apply_baseline_nondx_excl)) {
    criteria_clauses <- c(criteria_clauses, "AND MM_baseline_diag = 0")
  }
 
  criteria_sql <- paste(criteria_clauses, collapse = "\n          ")
 
  list(
    # ----------------------------------------------------------
    # PHASE 1: NORMALIZE CODE LISTS (small tables, run once)
    # Default: Uses prebuilt reference tables (use_embedded_codes = FALSE)
    # Set use_embedded_codes = TRUE to use embedded codes if ref tables unavailable
    # ----------------------------------------------------------
    list(
      name = "01_mm_dx_codes",
      description = "Loading MM diagnosis codes (ICD-9/ICD-10)",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('mm_dx_codes')} AS
        SELECT
          CASE WHEN upper(icd_family) IN ('9','ICD9','ICD-9') THEN 'ICD9' ELSE 'ICD10' END AS icd_family,
          upper(regexp_replace(dx, '\\\\.', '')) AS dx
        FROM {mm_dx_source}
        WHERE dx IS NOT NULL
      "),
      qc = glue("SELECT count(*) AS n_codes FROM {work('mm_dx_codes')}")
    ),
   
    list(
      name = "02_diag_proc_codes",
      description = "Loading diagnostic procedure codes",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('diag_proc_codes')} AS
        SELECT DISTINCT upper(regexp_replace(proc_cd, '\\\\.', '')) AS proc_cd
        FROM {diag_proc_source}
        WHERE proc_cd IS NOT NULL
      "),
      qc = glue("SELECT count(*) AS n_codes FROM {work('diag_proc_codes')}")
    ),
   
    list(
      name = "03_mm_therapy_codes",
      description = "Loading MM therapy codes (HCPCS/NDC)",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('mm_therapy_codes')} AS
        SELECT upper(code_type) AS code_type, upper(regexp_replace(code, '\\\\.', '')) AS code
        FROM {mm_therapy_source}
        WHERE code IS NOT NULL
      "),
      qc = glue("SELECT count(*) AS n_codes FROM {work('mm_therapy_codes')}")
    ),
   
    list(
      name = "04_preg_codes",
      description = "Loading pregnancy exclusion codes",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('preg_codes')} AS
        SELECT upper(code_type) AS code_type, upper(regexp_replace(code, '\\\\.', '')) AS code
        FROM {preg_source}
        WHERE code IS NOT NULL
      "),
      qc = glue("SELECT count(*) AS n_codes FROM {work('preg_codes')}")
    ),
   
    list(
      name = "05_clintrial_codes",
      description = "Loading clinical trial exclusion codes",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('clintrial_codes')} AS
        SELECT upper(code_type) AS code_type, upper(regexp_replace(code, '\\\\.', '')) AS code
        FROM {clintrial_source}
        WHERE code IS NOT NULL
      "),
      qc = glue("SELECT count(*) AS n_codes FROM {work('clintrial_codes')}")
    ),
   
    list(
      name = "06_other_malig_codes",
      description = "Loading other malignancy exclusion codes",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('other_malig_codes')} AS
        SELECT
          upper(tumor_group) AS tumor_group,
          CASE WHEN upper(icd_family) IN ('9','ICD9','ICD-9') THEN 'ICD9' ELSE 'ICD10' END AS icd_family,
          upper(regexp_replace(dx, '\\\\.', '')) AS dx
        FROM {other_malig_source}
        WHERE dx IS NOT NULL AND tumor_group IS NOT NULL
      "),
      qc = glue("SELECT count(*) AS n_codes FROM {work('other_malig_codes')}")
    ),
   
    # ----------------------------------------------------------
    # SCHEMA PROBE: Validate RVNU_CD column exists on medical table
    # Per Optum CDM v9.0, the revenue code field is RVNU_CD (facility claims only).
    # This check fails early with a clear message if the column is missing,
    # rather than erroring deep in the pregnancy/clinical trial steps.
    # ----------------------------------------------------------
    list(
      name = "06c_validate_rvnu_cd",
      description = "Validating RVNU_CD column exists on medical table",
      source_tables = c("medical"),
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('rvnu_cd_check')} AS
        SELECT RVNU_CD FROM {cdm_src(cfg$tbl_medical)} LIMIT 1
      "),
      qc = glue("SELECT 'RVNU_CD column validated on medical table' AS status")
    ),
   
    # ----------------------------------------------------------
    # PHASE 2: BUILD MM DIAGNOSIS EVENTS
    # FIXED: Build two tables:
    #   - mm_dx_events_all: full study period (for baseline flags)
    #   - mm_dx_events_id:  ID period only (for index qualification)
    # ----------------------------------------------------------
    list(
      name = "07a_med_claim_header",
      description = "Extracting medical claim headers from CDM (study period)",
      source_tables = c("medical"),
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('med_claim_header')} AS
        SELECT PATID, CLMID,
               max(CONF_ID) AS CONF_ID,
               max(POS) AS POS,
               max(TOS_CD) AS TOS_CD
        FROM {cdm_src(cfg$tbl_medical)}
        WHERE FST_DT BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
        GROUP BY PATID, CLMID
      "),
      qc = glue("SELECT count(*) AS n_claims FROM {work('med_claim_header')}")
    ),
   
    # ----------------------------------------------------------
    # CONFINEMENT TABLE EXTRACT (per Optum Business Rules Approach 2)
    # Business rules: "inpatient should be restricted to cases where
    # CONF_ID is not NULL from the T_CONFINEMENT table"
    # This validates that CONF_ID corresponds to an actual confinement
    # Per Approach 2: confinement should have associated admission AND discharge dates
    # ----------------------------------------------------------
    list(
      name = "07b_confinement",
      description = "Extracting confinement records (Optum Approach 2)",
      source_tables = c("confinement"),
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('confinement')} AS
        SELECT DISTINCT PATID, CONF_ID,
               cast(ADMIT_DATE as date) AS ADMIT_DATE,
               cast(DISCH_DATE as date) AS DISCH_DATE
        FROM {cdm_src(cfg$tbl_confinement)}
        WHERE CONF_ID IS NOT NULL
          AND ADMIT_DATE IS NOT NULL
          AND DISCH_DATE IS NOT NULL
      "),
      qc = glue("SELECT count(*) AS n_confinements FROM {work('confinement')}")
    ),
   
    # All MM dx events in study period (for baseline lookback)
    # Inpatient identification using EITHER Approach 1 OR Approach 2
    # - Approach 1: POS IN (21, 51, 61) OR TOS_CD IN (FAC_IP.ACUTE, FAC_IP.REHSNF, PROF.INPVIS, FAC_IP.SNF)
    # - Approach 2: CONF_ID is validated in T_CONFINEMENT
    # Patient qualifies as inpatient if EITHER approach identifies them as inpatient
    list(
      name = "08a_mm_dx_events_all",
      description = "Identifying MM diagnosis events (full study period, Approach 1+2 inpatient)",
      source_tables = c("med_diagnosis", "confinement"),
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('mm_dx_events_all')} AS
        SELECT /*+ BROADCAST(c) */
          d.PATID,
          d.CLMID,
          cast(d.FST_DT as date) AS svc_dt,
          upper(regexp_replace(d.DIAG, '\\\\.', '')) AS diag,
          CASE WHEN upper(d.ICD_FLAG) IN ('9','ICD9','ICD-9') THEN 'ICD9' ELSE 'ICD10' END AS icd_family,
          h.CONF_ID,
          h.POS,
          h.TOS_CD,
          -- FIXED: Inpatient = Approach 1 (POS/TOS) OR Approach 2 (CONF_ID validated)
          -- Approach 1: POS 21/51/61; TOS_CD IN (FAC_IP.ACUTE, FAC_IP.REHSNF, PROF.INPVIS, FAC_IP.SNF)
          -- Approach 2: CONF_ID exists in T_CONFINEMENT with valid dates
          CASE WHEN h.POS IN ('21', '51', '61')
                 OR h.TOS_CD IN ('FAC_IP.ACUTE', 'FAC_IP.REHSNF', 'PROF.INPVIS', 'FAC_IP.SNF')
                 OR cf.CONF_ID IS NOT NULL
               THEN 1 ELSE 0 END AS inpatient_flg,
          -- Outpatient: NOT identified as inpatient by either approach
          CASE WHEN NOT (h.POS IN ('21', '51', '61')
                      OR h.TOS_CD IN ('FAC_IP.ACUTE', 'FAC_IP.REHSNF', 'PROF.INPVIS', 'FAC_IP.SNF')
                      OR cf.CONF_ID IS NOT NULL)
               THEN 1 ELSE 0 END AS outpatient_flg,
          -- STRICT MM dx flag: 203.0x / C90.0x only (for inpatient qualifying + baseline evidence)
          -- BROAD codes (203.x / C90.x) are used for Step 0 base and outpatient qualifying
          CASE WHEN (CASE WHEN upper(d.ICD_FLAG) IN ('9','ICD9','ICD-9') THEN 'ICD9' ELSE 'ICD10' END) = 'ICD9'
                      AND upper(regexp_replace(d.DIAG, '\\\\.', '')) LIKE '2030%'
                 OR (CASE WHEN upper(d.ICD_FLAG) IN ('9','ICD9','ICD-9') THEN 'ICD9' ELSE 'ICD10' END) = 'ICD10'
                      AND upper(regexp_replace(d.DIAG, '\\\\.', '')) LIKE 'C900%'
               THEN 1 ELSE 0 END AS mm_dx_strict_flg,
          -- QC flags for each approach
          CASE WHEN cf.CONF_ID IS NOT NULL THEN 1 ELSE 0 END AS conf_validated,
          CASE WHEN h.POS IN ('21', '51', '61') OR h.TOS_CD IN ('FAC_IP.ACUTE', 'FAC_IP.REHSNF', 'PROF.INPVIS', 'FAC_IP.SNF') THEN 1 ELSE 0 END AS pos_tos_inpatient
        FROM {cdm_src(cfg$tbl_med_diag)} d
        INNER JOIN {work('med_claim_header')} h
          ON d.PATID = h.PATID AND d.CLMID = h.CLMID
        INNER JOIN {work('mm_dx_codes')} c
          ON upper(regexp_replace(d.DIAG, '\\\\.', '')) = c.dx
          AND (CASE WHEN upper(d.ICD_FLAG) IN ('9','ICD9','ICD-9') THEN 'ICD9' ELSE 'ICD10' END) = c.icd_family
        LEFT JOIN {work('confinement')} cf
          ON h.PATID = cf.PATID AND h.CONF_ID = cf.CONF_ID
        WHERE cast(d.FST_DT as date) BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
      "),
      qc = glue("SELECT count(DISTINCT PATID) AS n_patients, sum(inpatient_flg) AS n_inpatient_events, sum(conf_validated) AS n_via_conf, sum(pos_tos_inpatient) AS n_via_pos_tos FROM {work('mm_dx_events_all')}")
    ),
   
    # MM dx events in ID period only (for index date qualification)
    list(
      name = "08b_mm_dx_events_id",
      description = "Filtering MM events to identification period",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('mm_dx_events_id')} AS
        SELECT * FROM {work('mm_dx_events_all')}
        WHERE svc_dt BETWEEN date('{cfg$id_start}') AND date('{cfg$id_end}')
      "),
      qc = glue("SELECT count(DISTINCT PATID) AS n_patients FROM {work('mm_dx_events_id')}")
    ),
   
    # ----------------------------------------------------------
    # PHASE 3: INDEX DATE DERIVATION (uses ID period events only)
    # ----------------------------------------------------------
    list(
      name = "09_mm_inpatient_potential",
      description = "Finding ALL potential inpatient MM index dates (STRICT 203.0x/C90.0x only per spec)",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('mm_inpatient_potential')} AS
        SELECT DISTINCT PATID, svc_dt AS potential_index, 'INPATIENT' AS index_source
        FROM {work('mm_dx_events_id')}
        WHERE inpatient_flg = 1
          AND mm_dx_strict_flg = 1
      "),
      qc = glue("SELECT count(*) AS n_potential_inpt FROM {work('mm_inpatient_potential')}")
    ),
   
    list(
      name = "10_mm_outpatient_pairs",
      description = "Building outpatient diagnosis date pairs",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('mm_outpatient_pairs')} AS
        WITH distinct_dates AS (
          SELECT DISTINCT PATID, svc_dt
          FROM {work('mm_dx_events_id')}
          WHERE outpatient_flg = 1
        ),
        with_next AS (
          SELECT PATID, svc_dt,
                 lead(svc_dt) OVER (PARTITION BY PATID ORDER BY svc_dt) AS next_dt
          FROM distinct_dates
        )
        SELECT PATID, svc_dt AS first_dt, next_dt,
               datediff(next_dt, svc_dt) AS diff_days
        FROM with_next
        WHERE next_dt IS NOT NULL
      "),
      qc = glue("SELECT count(*) AS n_pairs FROM {work('mm_outpatient_pairs')}")
    ),
   
    list(
      name = "11_mm_outpatient_potential",
      description = "Finding ALL potential outpatient MM index dates (2+ OP in window, not just earliest)",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('mm_outpatient_potential')} AS
        -- Each qualifying pair's first_dt is a potential index date
        -- Keep track of which windows (30/60/90) each date qualifies for
        SELECT DISTINCT
          PATID,
          first_dt AS potential_index,
          'OUTPATIENT' AS index_source,
          CASE WHEN diff_days <= {cfg$dx_window_90} THEN 1 ELSE 0 END AS qualifies_90,
          CASE WHEN diff_days <= {cfg$dx_window_60} THEN 1 ELSE 0 END AS qualifies_60,
          CASE WHEN diff_days <= {cfg$dx_window_30} THEN 1 ELSE 0 END AS qualifies_30
        FROM {work('mm_outpatient_pairs')}
        WHERE diff_days <= {cfg$dx_window_90}
      "),
      qc = glue("SELECT count(*) AS n_potential_outpt FROM {work('mm_outpatient_potential')}")
    ),
   
    list(
      name = "12_mm_qualifying",
      description = "Combining ALL potential index dates (IP or OP within 90d max window) - keeps all, not just earliest",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('mm_qualifying')} AS
        -- Option B: Always build with MAX window (90 days) so all candidates are preserved.
        -- The configured outpatient window ({cfg$outpatient_window}d) is applied later in Step 24
        -- via the outpt_qual flag, NOT here. This ensures that if a patient's earliest
        -- 90d-qualified date fails IE criteria, a later date can still be selected.
        -- Flags outpt2_30, outpt2_60, outpt2_90 are carried forward for attrition reporting.
        WITH all_potential AS (
          -- Inpatient potential index dates (always qualify regardless of window)
          SELECT PATID, potential_index, 1 AS inpt_qual, 0 AS outpt2_30, 0 AS outpt2_60, 0 AS outpt2_90
          FROM {work('mm_inpatient_potential')}
          UNION ALL
          -- Outpatient potential index dates (include ALL that qualify within 90d)
          SELECT PATID, potential_index, 0 AS inpt_qual,
                 qualifies_30 AS outpt2_30, qualifies_60 AS outpt2_60, qualifies_90 AS outpt2_90
          FROM {work('mm_outpatient_potential')}
        )
        -- Aggregate per PATID + potential_index to handle dates that qualify via both paths
        SELECT
          PATID,
          potential_index AS index_date,
          max(inpt_qual) AS inpt_qual,
          -- outpt_qual reflects the CONFIGURED window (used in Step 24 criteria filter)
          max(CASE WHEN inpt_qual = 1 THEN 0
                   ELSE outpt2_{cfg$outpatient_window} END) AS outpt_qual,
          max(outpt2_30) AS outpt2_30,
          max(outpt2_60) AS outpt2_60,
          max(outpt2_90) AS outpt2_90,
          CASE
            WHEN max(inpt_qual) = 1 THEN 'INPATIENT'
            WHEN max(outpt2_{cfg$outpatient_window}) = 1 THEN 'OUTPATIENT_2IN{cfg$outpatient_window}'
            ELSE 'OUTPATIENT_2IN90'
          END AS index_source
        FROM all_potential
        GROUP BY PATID, potential_index
      "),
      qc = glue("SELECT count(*) AS n_potential_index, count(DISTINCT PATID) AS n_patients FROM {work('mm_qualifying')}")
    ),
   
    # ----------------------------------------------------------
    # PHASE 4: ENROLLMENT SPANS (using member_enrollment with 30-day gap logic)
    # Per IE spec: Build continuous enrollment spans from raw member_enrollment
    # allowing gaps <= 30 days to be absorbed into continuous spans.
    # This replaces using prebuilt member_cont_enrollment to ensure consistent
    # gap handling logic across baseline and followup periods.
    # ----------------------------------------------------------
    list(
      name = "13_enrollment_spans",
      description = "Building enrollment spans with 30-day gap logic from member_enrollment",
      source_tables = c("member_enrollment"),
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('enrollment_spans')} AS
        WITH base AS (
          -- Use member_enrollment (raw) with 30-day gap allowance
          SELECT PATID, cast(ELIGEFF as date) AS elig_eff, cast(ELIGEND as date) AS elig_end
          FROM {cdm_src(cfg$tbl_member_enrollment)}
          WHERE ELIGEFF IS NOT NULL AND ELIGEND IS NOT NULL
        ),
        ordered AS (
          SELECT *,
            -- Use max(elig_end) seen so far to handle overlapping/nested segments
            max(elig_end) OVER (
              PARTITION BY PATID
              ORDER BY elig_eff, elig_end
              ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
            ) AS max_end_so_far
          FROM base
        ),
        flagged AS (
          SELECT *,
            -- Allow gaps <= {cfg$gap_days} days: new group if elig_eff > max_end_so_far + gap_days + 1
            CASE WHEN max_end_so_far IS NULL THEN 1
                 WHEN elig_eff <= date_add(max_end_so_far, {cfg$gap_days} + 1) THEN 0
                 ELSE 1 END AS new_grp
          FROM ordered
        ),
        grouped AS (
          SELECT *,
            sum(new_grp) OVER (PARTITION BY PATID ORDER BY elig_eff, elig_end
                               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS grp_id
          FROM flagged
        )
        SELECT PATID, grp_id, min(elig_eff) AS cov_start, max(elig_end) AS cov_end
        FROM grouped
        GROUP BY PATID, grp_id
      "),
      qc = glue("SELECT count(DISTINCT PATID) AS n_patients FROM {work('enrollment_spans')}")
    ),
   
    # ----------------------------------------------------------
    # PHASE 4b: STRICT ENROLLMENT SPANS (NO GAPS) - for CE_3mosf sensitivity
    # Per StudyPop spec: CE_3mosf requires NO allowable gaps
    # This step uses member_enrollment (raw eligibility records) since
    # the prebuilt member_cont_enrollment already absorbs <30 day gaps
    # and cannot be used to detect true enrollment gaps.
    # FIXED: Handle overlapping/nested segments by using max(elig_end) over window
    # instead of lag() which fails when a short segment follows a long one.
    # ----------------------------------------------------------
    list(
      name = "13b_enrollment_spans_strict",
      description = "Building strict enrollment spans (no gaps, handles overlaps)",
      source_tables = c("member_enrollment"),
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('enrollment_spans_strict')} AS
        WITH base AS (
          -- Use member_enrollment (raw) to detect ALL gaps
          SELECT PATID, cast(ELIGEFF as date) AS elig_eff, cast(ELIGEND as date) AS elig_end
          FROM {cdm_src(cfg$tbl_member_enrollment)}
          WHERE ELIGEFF IS NOT NULL AND ELIGEND IS NOT NULL
        ),
        ordered AS (
          SELECT *,
            -- FIXED: Use max(elig_end) seen so far, not just previous row
            -- This handles overlapping/nested segments correctly
            max(elig_end) OVER (
              PARTITION BY PATID
              ORDER BY elig_eff, elig_end
              ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
            ) AS max_end_so_far
          FROM base
        ),
        flagged AS (
          SELECT *,
            -- NO allowable gaps: new group if elig_eff > max_end_so_far + 1
            CASE WHEN max_end_so_far IS NULL THEN 1
                 WHEN elig_eff <= date_add(max_end_so_far, 1) THEN 0
                 ELSE 1 END AS new_grp
          FROM ordered
        ),
        grouped AS (
          SELECT *,
            sum(new_grp) OVER (PARTITION BY PATID ORDER BY elig_eff, elig_end
                               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS grp_id
          FROM flagged
        )
        SELECT PATID, grp_id, min(elig_eff) AS cov_start, max(elig_end) AS cov_end
        FROM grouped
        GROUP BY PATID, grp_id
      "),
      qc = glue("SELECT count(DISTINCT PATID) AS n_patients FROM {work('enrollment_spans_strict')}")
    ),
   
    # ----------------------------------------------------------
    # PHASE 5: CE FLAGS (baseline 6 months, follow-up)
    # NOTE: CE_3mosf is computed in Step 23 with death-awareness per IE spec
    # (requires enrollment through min(index+91, death_dt, study_end), no gaps)
    # Per IE spec: Baseline ends at index_date - 1; CE_f checks enrollment on index_date
    # CE_f = 1 when cov_start <= index_date AND cov_end >= index_date (follow-up starts on index)
    # ----------------------------------------------------------
    list(
      name = "14_ce_flags",
      description = "CRITERION: Continuous enrollment (baseline before index, follow-up from index)",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('ce_flags')} AS
        WITH idx AS (
          SELECT PATID, index_date,
                 date_sub(index_date, {cfg$baseline_days}) AS baseline_start,
                 date_sub(index_date, 1) AS baseline_end
          FROM {work('mm_qualifying')}
        ),
        -- CE_b and CE_f use standard enrollment spans (with 30-day allowable gaps)
        -- Baseline excludes index_date; CE_f requires enrollment on index_date (follow-up starts on index)
        joined_std AS (
          SELECT i.PATID, i.index_date, i.baseline_start, i.baseline_end,
                 s.cov_start, s.cov_end,
                 CASE WHEN s.cov_start <= i.baseline_start AND s.cov_end >= i.baseline_end
                      THEN 1 ELSE 0 END AS covers_baseline,
                 -- CE_f: requires enrollment covering index_date (follow-up starts on index)
                 CASE WHEN s.cov_start <= i.index_date AND s.cov_end >= i.index_date
                      THEN 1 ELSE 0 END AS has_1day_followup
          FROM idx i
          LEFT JOIN {work('enrollment_spans')} s ON i.PATID = s.PATID
        )
        SELECT PATID, index_date, baseline_start, baseline_end,
               max(covers_baseline) AS CE_b,
               max(has_1day_followup) AS CE_f,
               max(CASE WHEN has_1day_followup = 1 THEN cov_end END) AS ENDDATE_CE
        FROM joined_std
        GROUP BY PATID, index_date, baseline_start, baseline_end
      "),
      qc = glue("SELECT sum(CE_b) AS n_with_baseline_ce FROM {work('ce_flags')}")
    ),
   
    # ----------------------------------------------------------
    # PHASE 6: DEMOGRAPHICS
    # ----------------------------------------------------------
    list(
      name = "15_member_demo",
      description = "Extracting patient demographics (age/gender)",
      source_tables = c("member_cont_enrollment"),
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('member_demo')} AS
        WITH ranked AS (
          SELECT PATID, GDR_CD, cast(YRDOB as int) AS YRDOB,
                 row_number() OVER (PARTITION BY PATID
                   ORDER BY CASE WHEN upper(GDR_CD) NOT IN ('U','') THEN 0 ELSE 1 END,
                            cast(ELIGEND as date) DESC) AS rn
          FROM {cdm_src(cfg$tbl_member_elig)}
        )
        SELECT PATID, GDR_CD, YRDOB FROM ranked WHERE rn = 1
      "),
      qc = glue("SELECT count(*) AS n_patients FROM {work('member_demo')}")
    ),
   
    # ----------------------------------------------------------
    # PHASE 6b: DEATH DATE DERIVATION
    # Per StudyPop spec: When death date is only available at month-level
    # granularity, the date is generalized to the middle of the month (15th)
    # ----------------------------------------------------------
    # FIXED: Compute DEATH_DT directly with Dec 31 rule by joining to mm_qualifying
    # Per IE spec: Year-only death uses July 15 UNLESS index_date > July 15, then Dec 31
    # This prevents DEATH_DT < INDEX_DATE which would cause negative FU_DAYS
    list(
      name = "15b_death_dt",
      description = "Deriving death dates (month->15th, year-only uses July15/Dec31 rule)",
      source_tables = c("dod"),
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('death_dt')} AS
        WITH raw_death AS (
          SELECT
            PATID,
            cast(SUBSTR(YMDOD, 1, 4) as int) AS death_yr,
            CASE
              WHEN LENGTH(TRIM(YMDOD)) >= 6 THEN cast(SUBSTR(YMDOD, 5, 2) as int)
              ELSE NULL
            END AS death_mo
          FROM {cdm_src(cfg$tbl_dod)}
          WHERE YMDOD IS NOT NULL AND LENGTH(TRIM(YMDOD)) >= 4
        ),
        ranked AS (
          SELECT *,
                 row_number() OVER (PARTITION BY PATID ORDER BY death_yr DESC, death_mo DESC NULLS LAST) AS rn
          FROM raw_death
        ),
        best AS (
          SELECT PATID, death_yr, NULLIF(death_mo, 0) AS death_mo
          FROM ranked
          WHERE rn = 1
        ),
        calc AS (
          SELECT
            q.PATID,
            q.index_date,
            CASE
              WHEN b.death_yr IS NULL THEN NULL
              WHEN b.death_mo IS NOT NULL THEN
                -- Month-level: use 15th unless index_date > 15th in same month, then use month-end
                CASE
                  WHEN year(q.index_date) = b.death_yr
                   AND month(q.index_date) = b.death_mo
                   AND q.index_date > make_date(b.death_yr, b.death_mo, 15)
                  THEN last_day(make_date(b.death_yr, b.death_mo, 1))
                  ELSE make_date(b.death_yr, b.death_mo, 15)
                END
              ELSE
                -- Year-only: use July 15 unless index_date > July 15 in same year, then Dec 31
                CASE
                  WHEN year(q.index_date) = b.death_yr
                   AND q.index_date > make_date(b.death_yr, 7, 15)
                  THEN make_date(b.death_yr, 12, 31)
                  ELSE make_date(b.death_yr, 7, 15)
                END
            END AS death_raw
          FROM {work('mm_qualifying')} q
          LEFT JOIN best b ON q.PATID = b.PATID
        )
        -- Final clamp: ensure DEATH_DT >= index_date (prevents negative FU_DAYS from data issues)
        -- NOTE: Output includes index_date since death can be relative to each potential index
        SELECT
          PATID,
          index_date,
          CASE
            WHEN death_raw IS NOT NULL AND death_raw < index_date THEN index_date
            ELSE death_raw
          END AS DEATH_DT
        FROM calc
      "),
      qc = glue("SELECT count(*) AS n_with_death_dt FROM {work('death_dt')} WHERE DEATH_DT IS NOT NULL")
    ),
   
    # ----------------------------------------------------------
    # PHASE 7: NON-DIAGNOSTIC CLAIM FLAG
    # FIXED per IE spec: A "non-diagnostic MM claim" is a claim where:
    #   - MM diagnosis is present AND
    #   - There is at least one service line that is NOT a diagnostic code
    # Example: claim with diagnostic testing + medication/care mgmt → non-diagnostic
    # This indicates active MM treatment, not just diagnostic workup
    # ----------------------------------------------------------
    list(
      name = "16_claim_nondiagnostic",
      description = "Identifying non-diagnostic claims per IE spec (has ANY non-diag line)",
      source_tables = c("medical"),
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('claim_nondiagnostic')} AS
        WITH lines AS (
          SELECT PATID, CLMID, upper(regexp_replace(PROC_CD, '\\\\.', '')) AS proc_cd
          FROM {cdm_src(cfg$tbl_medical)}
          WHERE FST_DT BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
        ),
        marked AS (
          SELECT /*+ BROADCAST(d) */
            l.PATID, l.CLMID,
            CASE
              WHEN l.proc_cd IS NULL THEN NULL  -- Unknown, don't count either way
              WHEN d.proc_cd IS NOT NULL THEN 1 -- Is diagnostic procedure
              ELSE 0                            -- Has proc_cd but not in diagnostic list
            END AS is_diag_line
          FROM lines l
          LEFT JOIN {work('diag_proc_codes')} d ON l.proc_cd = d.proc_cd
        ),
        claim_agg AS (
          SELECT PATID, CLMID,
                 -- Claim-level classification
                 max(CASE WHEN is_diag_line = 1 THEN 1 ELSE 0 END) AS has_diag_line,
                 max(CASE WHEN is_diag_line = 0 THEN 1 ELSE 0 END) AS has_nondiag_line,
                 -- All lines NULL (unknown)
                 CASE WHEN max(is_diag_line) IS NULL THEN 1 ELSE 0 END AS all_null_lines
          FROM marked
          GROUP BY PATID, CLMID
        )
        SELECT PATID, CLMID,
               has_diag_line,
               has_nondiag_line,
               all_null_lines,
               -- FIXED per IE spec: Non-diagnostic = has ANY non-diagnostic line
               -- (even if it also has diagnostic lines - e.g., testing + treatment)
               CASE
                 WHEN has_nondiag_line = 1 THEN 1  -- Has non-diag line -> NON-DIAGNOSTIC
                 ELSE 0                            -- Only diag lines or all NULL -> not non-diag
               END AS is_nondiagnostic_claim
        FROM claim_agg
      "),
      qc = glue("SELECT sum(is_nondiagnostic_claim) AS n_nondiag_claims FROM {work('claim_nondiagnostic')}")
    ),
   
    # Per ATTRITION TABLE Step 7: >=1 medical claim for MM (203.0x/C90.0x) in baseline
    # NOTE: Attrition table does NOT require non-diagnostic; IE criteria PDF row 14 does.
    # Following attrition table as the authoritative source.
    list(
      name = "17_mm_baseline_nondx_flag",
      description = "Checking for any STRICT MM dx (203.0x/C90.0x) claim in baseline period",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('mm_baseline_nondx_flag')} AS
        SELECT
          q.PATID,
          q.index_date,
          -- Per attrition table Step 7: >=1 MM claim (203.0x/C90.0x) in baseline
          -- Baseline excludes index_date (baseline = before index)
          -- mm_dx_strict_flg ensures only STRICT codes are counted
          max(CASE WHEN e.svc_dt BETWEEN date_sub(q.index_date, {cfg$baseline_days})
                                     AND date_sub(q.index_date, 1)
                    AND e.mm_dx_strict_flg = 1
               THEN 1 ELSE 0 END) AS MM_BASELINE_NONDX
        FROM {work('mm_qualifying')} q
        LEFT JOIN {work('mm_dx_events_all')} e ON q.PATID = e.PATID
        GROUP BY q.PATID, q.index_date
      "),
      qc = glue("SELECT sum(MM_BASELINE_NONDX) AS n_with_baseline_mm FROM {work('mm_baseline_nondx_flag')}")
    ),
   
    # ----------------------------------------------------------
    # PHASE 8: THERAPY EVENTS AND FLAGS
    # ----------------------------------------------------------
    list(
      name = "18_therapy_events",
      description = "Identifying MM therapy events (medical + Rx)",
      source_tables = c("medical", "rx"),
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('therapy_events')} AS
        -- Medical therapy via PROC_CD
        SELECT /*+ BROADCAST(c) */
          m.PATID, cast(m.FST_DT as date) AS event_dt, 'MEDICAL' AS source
        FROM {cdm_src(cfg$tbl_medical)} m
        INNER JOIN {work('mm_therapy_codes')} c
          ON c.code_type IN ('HCPCS','CPT','PROC')
          AND upper(regexp_replace(m.PROC_CD, '\\\\.', '')) = c.code
        WHERE m.FST_DT BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
        UNION ALL
        -- RX therapy via NDC
        SELECT /*+ BROADCAST(c) */
          r.PATID, cast(r.FILL_DT as date) AS event_dt, 'RX' AS source
        FROM {cdm_src(cfg$tbl_rx)} r
        INNER JOIN {work('mm_therapy_codes')} c
          ON c.code_type = 'NDC'
          AND upper(regexp_replace(r.NDC, '\\\\.', '')) = c.code
        WHERE r.FILL_DT BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
      "),
      qc = glue("SELECT count(*) AS n_therapy_events FROM {work('therapy_events')}")
    ),
   
    # ----------------------------------------------------------
    # FIXED: Join death_dt to therapy_flags so follow-up therapy is bounded by death date
    # This prevents counting therapy after death (data quality issue) and ensures
    # that patients who die are not incorrectly included due to post-death claims
    # ----------------------------------------------------------
    list(
      name = "19_therapy_flags",
      description = "CRITERION: MM therapy in baseline/follow-up (death-aware)",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('therapy_flags')} AS
        SELECT
          q.PATID,
          q.index_date,
          -- Baseline excludes index_date per IE spec (baseline = before index)
          max(CASE WHEN t.event_dt BETWEEN date_sub(q.index_date, {cfg$baseline_days})
                                       AND date_sub(q.index_date, 1)
               THEN 1 ELSE 0 END) AS MM_THERAPY_BASELINE,
          -- Followup starts on index_date per IE spec (>= index_date)
          -- Bounded by death_dt to prevent counting therapy after death
          max(CASE WHEN t.event_dt >= q.index_date
                    AND t.event_dt <= least(date('{cfg$study_end}'), coalesce(d.DEATH_DT, date('{cfg$study_end}')))
               THEN 1 ELSE 0 END) AS MM_THERAPY_FOLLOWUP
        FROM {work('mm_qualifying')} q
        LEFT JOIN {work('death_dt')} d ON q.PATID = d.PATID AND q.index_date = d.index_date
        LEFT JOIN {work('therapy_events')} t ON q.PATID = t.PATID
        GROUP BY q.PATID, q.index_date
      "),
      qc = glue("SELECT sum(MM_THERAPY_FOLLOWUP) AS n_with_fu_therapy FROM {work('therapy_flags')}")
    ),
   
    # ----------------------------------------------------------
    # PHASE 9: EXCLUSION FLAGS (pregnancy, clinical trial, other cancer)
    # Each is an independent flag per StudyPop spec
    # ----------------------------------------------------------
    # Per IE spec: "1 of medical claim with a diagnosis, procedure, or revenue code
    # indicating pregnancy or childbirth during the baseline or follow-up period"
    # FIXED: Added revenue code (RVNU_CD) support per spec requirement
    # NOTE: Pregnancy check spans baseline + follow-up per attrition table Step 9
    list(
      name = "20_pregnancy_flag",
      description = "EXCLUSION: Pregnancy flag (DX + PROC + RVNU_CD, baseline + follow-up)",
      source_tables = c("med_diagnosis", "medical"),
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('pregnancy_flag')} AS
        WITH dx AS (
          SELECT PATID, cast(FST_DT as date) AS event_dt, 'DX' AS code_type,
                 upper(regexp_replace(DIAG, '\\\\.', '')) AS code
          FROM {cdm_src(cfg$tbl_med_diag)}
          WHERE FST_DT BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
        ),
        proc AS (
          SELECT PATID, cast(FST_DT as date) AS event_dt, 'PROC' AS code_type,
                 upper(regexp_replace(PROC_CD, '\\\\.', '')) AS code
          FROM {cdm_src(cfg$tbl_medical)}
          WHERE PROC_CD IS NOT NULL
            AND FST_DT BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
        ),
        -- ADDED: Revenue code stream per IE spec (pregnancy requires DX, PROC, or RVNU_CD)
        rev AS (
          SELECT PATID, cast(FST_DT as date) AS event_dt, 'REV' AS code_type,
                 upper(TRIM(RVNU_CD)) AS code
          FROM {cdm_src(cfg$tbl_medical)}
          WHERE RVNU_CD IS NOT NULL AND TRIM(RVNU_CD) != ''
            AND FST_DT BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
        ),
        events AS (SELECT * FROM dx UNION ALL SELECT * FROM proc UNION ALL SELECT * FROM rev),
        matched AS (
          SELECT /*+ BROADCAST(p) */ e.PATID, e.event_dt
          FROM events e
          INNER JOIN {work('preg_codes')} p ON e.code_type = p.code_type AND e.code = p.code
        )
        SELECT
          q.PATID,
          q.index_date,
          -- Per attrition table: pregnancy during baseline or follow-up period
          -- FIXED: Follow-up ends at min(death_dt, study_end) per ENDDATE definition
          max(CASE WHEN m.event_dt BETWEEN date_sub(q.index_date, {cfg$baseline_days})
                                       AND least(date('{cfg$study_end}'), coalesce(d.DEATH_DT, date('{cfg$study_end}')))
               THEN 1 ELSE 0 END) AS PREGNANT_FLAG
        FROM {work('mm_qualifying')} q
        LEFT JOIN {work('death_dt')} d ON q.PATID = d.PATID AND q.index_date = d.index_date
        LEFT JOIN matched m ON q.PATID = m.PATID
        GROUP BY q.PATID, q.index_date
      "),
      qc = glue("SELECT sum(PREGNANT_FLAG) AS n_pregnant FROM {work('pregnancy_flag')}")
    ),
   
    # Per IE spec: "Evidence of clinical trial participation during each of the
    # baseline and follow-up periods. See tab CL CLNTRIAL."
    # FIXED: Added revenue code (RVNU_CD) support for consistency with CL CLNTRIAL tab
    list(
      name = "21_clintrial_flag",
      description = "EXCLUSION: Clinical trial flag (DX + PROC + RVNU_CD, baseline + follow-up)",
      source_tables = c("med_diagnosis", "medical"),
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('clintrial_flag')} AS
        WITH dx AS (
          SELECT PATID, cast(FST_DT as date) AS event_dt, 'DX' AS code_type,
                 upper(regexp_replace(DIAG, '\\\\.', '')) AS code
          FROM {cdm_src(cfg$tbl_med_diag)}
          WHERE FST_DT BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
        ),
        proc AS (
          SELECT PATID, cast(FST_DT as date) AS event_dt, 'PROC' AS code_type,
                 upper(regexp_replace(PROC_CD, '\\\\.', '')) AS code
          FROM {cdm_src(cfg$tbl_medical)}
          WHERE PROC_CD IS NOT NULL
            AND FST_DT BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
        ),
        -- ADDED: Revenue code stream for consistency with CL CLNTRIAL tab
        rev AS (
          SELECT PATID, cast(FST_DT as date) AS event_dt, 'REV' AS code_type,
                 upper(TRIM(RVNU_CD)) AS code
          FROM {cdm_src(cfg$tbl_medical)}
          WHERE RVNU_CD IS NOT NULL AND TRIM(RVNU_CD) != ''
            AND FST_DT BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
        ),
        events AS (SELECT * FROM dx UNION ALL SELECT * FROM proc UNION ALL SELECT * FROM rev),
        matched AS (
          SELECT /*+ BROADCAST(c) */ e.PATID, e.event_dt
          FROM events e
          INNER JOIN {work('clintrial_codes')} c ON e.code_type = c.code_type AND e.code = c.code
        )
        SELECT
          q.PATID,
          q.index_date,
          -- Baseline excludes index_date per IE spec (baseline = before index)
          max(CASE WHEN m.event_dt BETWEEN date_sub(q.index_date, {cfg$baseline_days})
                                       AND date_sub(q.index_date, 1)
               THEN 1 ELSE 0 END) AS CLINTRIAL_BASELINE,
          -- Followup starts on index_date per IE spec
          -- FIXED: Follow-up ends at min(death_dt, study_end) per ENDDATE definition
          max(CASE WHEN m.event_dt >= q.index_date
                    AND m.event_dt <= least(date('{cfg$study_end}'), coalesce(d.DEATH_DT, date('{cfg$study_end}')))
               THEN 1 ELSE 0 END) AS CLINTRIAL_FOLLOWUP
        FROM {work('mm_qualifying')} q
        LEFT JOIN {work('death_dt')} d ON q.PATID = d.PATID AND q.index_date = d.index_date
        LEFT JOIN matched m ON q.PATID = m.PATID
        GROUP BY q.PATID, q.index_date
      "),
      qc = glue("SELECT sum(CLINTRIAL_BASELINE) + sum(CLINTRIAL_FOLLOWUP) AS n_clintrial FROM {work('clintrial_flag')}")
    ),
   
    list(
      name = "22_other_malig_flag",
      description = "EXCLUSION: Other malignancy flag",
      source_tables = c("med_diagnosis"),
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('other_malig_flag')} AS
        WITH dx AS (
          SELECT d.PATID, d.CLMID, cast(d.FST_DT as date) AS event_dt,
                 upper(regexp_replace(d.DIAG, '\\\\.', '')) AS dx,
                 CASE WHEN upper(d.ICD_FLAG) IN ('9','ICD9','ICD-9') THEN 'ICD9' ELSE 'ICD10' END AS icd_family
          FROM {cdm_src(cfg$tbl_med_diag)} d
          WHERE FST_DT BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
        ),
        dx_mapped AS (
          SELECT /*+ BROADCAST(o) */ dx.PATID, dx.CLMID, dx.event_dt, o.tumor_group
          FROM dx
          INNER JOIN {work('other_malig_codes')} o ON dx.dx = o.dx AND dx.icd_family = o.icd_family
        ),
        -- Per attrition table Step 8: Evidence of another cancer in the baseline period
        -- Attrition table does NOT require non-diagnostic claims for other cancer
        distinct_dates AS (SELECT DISTINCT PATID, tumor_group, event_dt FROM dx_mapped),
        with_next AS (
          SELECT PATID, tumor_group, event_dt,
                 lead(event_dt) OVER (PARTITION BY PATID, tumor_group ORDER BY event_dt) AS next_dt
          FROM distinct_dates
        ),
        pairs AS (
          SELECT PATID, tumor_group, event_dt AS first_dt, next_dt,
                 datediff(next_dt, event_dt) AS diff_days
          FROM with_next WHERE next_dt IS NOT NULL
        )
        SELECT
          q.PATID,
          q.index_date,
          -- Per spec: only the FIRST of the 2 codes is required to occur inside the baseline period
          max(CASE WHEN p.diff_days <= 30
                    AND p.first_dt BETWEEN date_sub(q.index_date, {cfg$baseline_days})
                                       AND date_sub(q.index_date, 1)
               THEN 1 ELSE 0 END) AS OTHER_MALIGN_FLAG
        FROM {work('mm_qualifying')} q
        LEFT JOIN pairs p ON q.PATID = p.PATID
        GROUP BY q.PATID, q.index_date
      "),
      qc = glue("SELECT sum(OTHER_MALIGN_FLAG) AS n_other_malig FROM {work('other_malig_flag')}")
    ),
   
    # ----------------------------------------------------------
    # PHASE 10: FINAL ASSEMBLY - ELIG_COH with all flags
    # FIXED: Added Death_dt, proper ENDDATE/FU_DAYS per StudyPop spec:
    #   - ENDDATE = min(Death_dt, study_end)
    #   - ENDDATE_CE = min(Death_dt, disenrollment, study_end)
    #   - FU_DAYS = datediff(ENDDATE, index_date + 1) + 1  (follow-up starts day after index)
    #   - FU_DAYS_CE = datediff(ENDDATE_CE, index_date + 1) + 1
    # ----------------------------------------------------------
    list(
      name = "23_ELIG_COH_ALLFLAGS",
      description = "Assembling cohort with all flags",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('ELIG_COH_ALLFLAGS')} AS
        WITH base AS (
          SELECT
            q.PATID,
            q.index_date,
            d.GDR_CD,
            d.YRDOB,
            death.DEATH_DT,
            ce.baseline_start,
            ce.baseline_end,
            ce.CE_b,
            ce.CE_f,
            ce.ENDDATE_CE,
            th.MM_THERAPY_BASELINE,
            th.MM_THERAPY_FOLLOWUP,
            mm_bl.MM_BASELINE_NONDX,
            om.OTHER_MALIGN_FLAG,
            preg.PREGNANT_FLAG,
            ct.CLINTRIAL_BASELINE,
            ct.CLINTRIAL_FOLLOWUP,
            q.inpt_qual, q.outpt_qual, q.outpt2_30, q.outpt2_60, q.outpt2_90, q.index_source
          FROM {work('mm_qualifying')} q
          LEFT JOIN {work('ce_flags')} ce ON q.PATID = ce.PATID AND q.index_date = ce.index_date
          LEFT JOIN {work('member_demo')} d ON q.PATID = d.PATID
          LEFT JOIN {work('death_dt')} death ON q.PATID = death.PATID AND q.index_date = death.index_date
          LEFT JOIN {work('mm_baseline_nondx_flag')} mm_bl ON q.PATID = mm_bl.PATID AND q.index_date = mm_bl.index_date
          LEFT JOIN {work('therapy_flags')} th ON q.PATID = th.PATID AND q.index_date = th.index_date
          LEFT JOIN {work('pregnancy_flag')} preg ON q.PATID = preg.PATID AND q.index_date = preg.index_date
          LEFT JOIN {work('clintrial_flag')} ct ON q.PATID = ct.PATID AND q.index_date = ct.index_date
          LEFT JOIN {work('other_malig_flag')} om ON q.PATID = om.PATID AND q.index_date = om.index_date
        ),
        -- CE_3mosf with death-aware logic (no gaps, ends at min of 90 days/death/study_end)
        ce3mos_calc AS (
          SELECT
            b.PATID,
            b.index_date,
            least(
              date_add(b.index_date, 90),
              date('{cfg$study_end}'),
              coalesce(b.DEATH_DT, date('{cfg$study_end}'))
            ) AS required_3mos_end,
            ss.cov_start,
            ss.cov_end
          FROM base b
          LEFT JOIN {work('enrollment_spans_strict')} ss ON b.PATID = ss.PATID
        ),
        ce3mos_flag AS (
          SELECT PATID, index_date,
            max(CASE WHEN cov_start <= index_date AND cov_end >= required_3mos_end THEN 1 ELSE 0 END) AS CE_3mosf
          FROM ce3mos_calc
          GROUP BY PATID, index_date
        )
        SELECT
          b.PATID,
          b.index_date AS INDEX_DATE,
          year(b.index_date) AS INDEX_YR,
          b.GDR_CD,
          b.YRDOB,
          (year(b.index_date) - b.YRDOB) AS AGE_INDEX_YR,
          b.inpt_qual, b.outpt_qual, b.outpt2_30, b.outpt2_60, b.outpt2_90, b.index_source,
          b.baseline_start, b.baseline_end,
          coalesce(b.CE_b, 0) AS CE_b,
          coalesce(b.CE_f, 0) AS CE_f,
          coalesce(c3.CE_3mosf, 0) AS CE_3mosf,
          b.DEATH_DT,
          least(date('{cfg$study_end}'), coalesce(b.DEATH_DT, date('{cfg$study_end}'))) AS ENDDATE,
          least(date('{cfg$study_end}'), coalesce(b.DEATH_DT, date('{cfg$study_end}')), coalesce(b.ENDDATE_CE, date('{cfg$study_end}'))) AS ENDDATE_CE,
          datediff(least(date('{cfg$study_end}'), coalesce(b.DEATH_DT, date('{cfg$study_end}'))), date_add(b.index_date, 1)) + 1 AS FU_DAYS,
          datediff(least(date('{cfg$study_end}'), coalesce(b.DEATH_DT, date('{cfg$study_end}')), coalesce(b.ENDDATE_CE, date('{cfg$study_end}'))), date_add(b.index_date, 1)) + 1 AS FU_DAYS_CE,
          coalesce(b.MM_THERAPY_BASELINE, 0) AS MM_bl_agents,
          coalesce(b.MM_THERAPY_FOLLOWUP, 0) AS MM_FU_agents,
          coalesce(b.MM_BASELINE_NONDX, 0) AS MM_baseline_diag,
          coalesce(b.OTHER_MALIGN_FLAG, 0) AS OTHER_MALIGN_FLAG,
          coalesce(b.PREGNANT_FLAG, 0) AS PREGNANT_FLAG,
          coalesce(b.CLINTRIAL_BASELINE, 0) AS CLINTRIAL_BASELINE,
          coalesce(b.CLINTRIAL_FOLLOWUP, 0) AS CLINTRIAL_FOLLOWUP
        FROM base b
        LEFT JOIN ce3mos_flag c3 ON b.PATID = c3.PATID AND b.index_date = c3.index_date
      "),
      qc = glue("SELECT count(*) AS n_total, count(DISTINCT PATID) AS n_patients FROM {work('ELIG_COH_ALLFLAGS')}")
    ),
   
    list(
      name = "24_ELIG_COH_FINAL",
      description = glue("FINAL COHORT ({cfg$final_table_name}): Apply IE criteria then select EARLIEST qualifying index_date per patient"),
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work(cfg$final_table_name)} AS
        -- First apply IE criteria, then select the EARLIEST qualifying index_date per patient
        -- This ensures that if a patient's earliest potential index_date fails IE criteria,
        -- a later index_date that passes can still be selected
        WITH filtered AS (
          SELECT *
          FROM {work('ELIG_COH_ALLFLAGS')}
          WHERE 1=1
            -- Step 1: Index date must qualify via IP (strict) or OP in configured window
            AND (inpt_qual = 1 OR outpt2_{cfg$outpatient_window} = 1)
            {criteria_sql}
        ),
        ranked AS (
          SELECT *,
                 row_number() OVER (PARTITION BY PATID ORDER BY INDEX_DATE) AS rn
          FROM filtered
        )
        SELECT * FROM ranked WHERE rn = 1
      "),
      qc = glue("SELECT count(*) AS n_final_cohort FROM {work(cfg$final_table_name)}")
    ),
   
    # ----------------------------------------------------------
    # STEP 24b: PERSIST FINAL COHORT TO PERSONAL SCHEMA
    # ----------------------------------------------------------
    # Uses lazy table approach to save final cohort as permanent table
    # in user's personal schema. Set PERSIST_TO_SCHEMA=FALSE to skip.
   
    if (isTRUE(cfg$persist_to_schema) && nzchar(cfg$personal_schema)) list(
      name = "24b_persist_final_cohort",
      description = glue("Persist final cohort to {cfg$catalog}.{cfg$personal_schema}.{cfg$final_table_name}"),
      sql = glue("
        CREATE OR REPLACE TABLE {cfg$catalog}.{cfg$personal_schema}.{cfg$final_table_name} AS
        SELECT * FROM {work(cfg$final_table_name)}
      "),
      qc = glue("SELECT count(*) AS n_persisted FROM {cfg$catalog}.{cfg$personal_schema}.{cfg$final_table_name}")
    ) else NULL,
   
    # ----------------------------------------------------------
    # STEP 25a-c: CONFIG-DRIVEN VIEW (Option 2 - toggle without rerun)
    # ----------------------------------------------------------
    # FIXED: Split into 3 separate steps to avoid multi-statement execution issues
    # Creates a config table + VIEW so criteria can be toggled via SQL UPDATE
    # without re-running the pipeline at all. Set CREATE_CRITERIA_VIEW=FALSE to skip.
   
    if (isTRUE(cfg$create_criteria_view)) list(
      name = "25a_ie_criteria_config_table",
      description = "Create IE criteria config table",
      sql = glue("
        CREATE TABLE IF NOT EXISTS {work('ie_criteria_config')} (
          config_name STRING,
          apply_age BOOLEAN,
          min_age INT,
          apply_ce_b BOOLEAN,
          apply_ce_f BOOLEAN,
          apply_no_bl_agents BOOLEAN,
          apply_fu_agents BOOLEAN,
          apply_pregnancy_excl BOOLEAN,
          apply_clintrial_excl BOOLEAN,
          apply_other_malig_excl BOOLEAN,
          apply_baseline_nondx_excl BOOLEAN,
          updated_at TIMESTAMP
        ) USING DELTA
      "),
      qc = glue("SELECT 'ie_criteria_config table created' AS status")
    ) else NULL,
   
    if (isTRUE(cfg$create_criteria_view)) list(
      name = "25b_ie_criteria_config_upsert",
      description = "Upsert current IE criteria configuration",
      sql = glue("
        MERGE INTO {work('ie_criteria_config')} t
        USING (SELECT
          'ACTIVE' AS config_name,
          {bool_sql(cfg$apply_age_incl)} AS apply_age,
          {cfg$min_age} AS min_age,
          {bool_sql(cfg$apply_ce_b_incl)} AS apply_ce_b,
          {bool_sql(cfg$apply_ce_f_incl)} AS apply_ce_f,
          {bool_sql(cfg$apply_no_bl_agents_incl)} AS apply_no_bl_agents,
          {bool_sql(cfg$apply_fu_agents_incl)} AS apply_fu_agents,
          {bool_sql(cfg$apply_pregnancy_excl)} AS apply_pregnancy_excl,
          {bool_sql(cfg$apply_clintrial_excl)} AS apply_clintrial_excl,
          {bool_sql(cfg$apply_other_malig_excl)} AS apply_other_malig_excl,
          {bool_sql(cfg$apply_baseline_nondx_excl)} AS apply_baseline_nondx_excl,
          current_timestamp() AS updated_at
        ) s
        ON t.config_name = s.config_name
        WHEN MATCHED THEN UPDATE SET *
        WHEN NOT MATCHED THEN INSERT *
      "),
      qc = glue("SELECT * FROM {work('ie_criteria_config')} WHERE config_name = 'ACTIVE'")
    ) else NULL,
   
    if (isTRUE(cfg$create_criteria_view)) list(
      name = "25c_elig_coh_dynamic_view",
      description = "Create dynamic VIEW for interactive criteria toggling",
      sql = glue("
        CREATE OR REPLACE VIEW {work('ELIG_COH_DYNAMIC')} AS
        WITH c AS (SELECT * FROM {work('ie_criteria_config')} WHERE config_name = 'ACTIVE')
        SELECT a.*
        FROM {work('ELIG_COH_ALLFLAGS')} a
        CROSS JOIN c
        WHERE (a.inpt_qual = 1 OR a.outpt2_{cfg$outpatient_window} = 1)
          AND (c.apply_age = false OR a.AGE_INDEX_YR >= c.min_age)
          AND (c.apply_ce_b = false OR a.CE_b = 1)
          AND (c.apply_ce_f = false OR a.CE_f = 1)
          AND (c.apply_no_bl_agents = false OR a.MM_bl_agents = 0)
          AND (c.apply_fu_agents = false OR a.MM_FU_agents = 1)
          AND (c.apply_pregnancy_excl = false OR a.PREGNANT_FLAG = 0)
          AND (c.apply_clintrial_excl = false OR (a.CLINTRIAL_BASELINE = 0 AND a.CLINTRIAL_FOLLOWUP = 0))
          AND (c.apply_other_malig_excl = false OR a.OTHER_MALIGN_FLAG = 0)
          AND (c.apply_baseline_nondx_excl = false OR a.MM_baseline_diag = 0)
      "),
      qc = glue("SELECT count(*) AS n_dynamic_cohort FROM {work('ELIG_COH_DYNAMIC')}")
    ) else NULL
  )
}
 
# ============================================================
# MAIN EXECUTION (fixed: uses con_env for connection)
# ============================================================
 
main <- function() {
  # Prompt user for options at start
  user_cfg <- prompt_user_options()
 
  # Update cfg with user selections (env vars take precedence)
  cfg$cdm_schema <<- Sys.getenv("OPTUM_CDM_SCHEMA", unset = user_cfg$cdm_schema)
  cfg$ref_schema <<- Sys.getenv("PROJECT_REF_SCHEMA", unset = user_cfg$ref_schema)
  cfg$work_schema <<- Sys.getenv("PROJECT_WORK_SCHEMA", unset = user_cfg$work_schema)
  cfg$study_start <<- user_cfg$study_start
  cfg$study_end <<- user_cfg$study_end
  cfg$id_start <<- user_cfg$id_start
  cfg$id_end <<- user_cfg$id_end
  cfg$baseline_days <<- user_cfg$baseline_days
  cfg$gap_days <<- user_cfg$gap_days
 
  # ============================================================
  # PROMPT FOR INCLUSION/EXCLUSION CRITERIA
  # ============================================================
  if (isTRUE(cfg$dynamic_ie_order) && should_prompt()) {
    log_msg("DYNAMIC IE MODE: Criteria will be selected interactively after base steps")
    log_msg("Skipping upfront IE criteria prompt (all criteria available in dynamic loop)")
    ie_criteria <- NULL
  } else {
    ie_criteria <- prompt_ie_criteria()
  }
 
  # Update cfg with user-selected criteria (validate outpatient window)
  # Skip when dynamic mode is on (criteria selected interactively later)
  if (!is.null(ie_criteria)) {
    cfg$outpatient_window <<- validate_outpatient_window(ie_criteria$outpatient_window)
    cfg$apply_age_incl <<- ie_criteria$apply_age
    cfg$min_age <<- ie_criteria$min_age
    cfg$apply_ce_b_incl <<- ie_criteria$apply_ce_baseline
    cfg$apply_ce_f_incl <<- ie_criteria$apply_ce_followup
    cfg$apply_no_bl_agents_incl <<- ie_criteria$apply_no_baseline_therapy
    cfg$apply_fu_agents_incl <<- ie_criteria$apply_followup_therapy
    cfg$apply_pregnancy_excl <<- ie_criteria$apply_pregnancy_excl
    cfg$apply_clintrial_excl <<- ie_criteria$apply_clintrial_excl
    cfg$apply_other_malig_excl <<- ie_criteria$apply_other_malig_excl
    cfg$apply_baseline_nondx_excl <<- ie_criteria$apply_baseline_nondx_excl
  }
 
  log_msg("=", SEP_59)
  log_msg("ATTRITION COHORT PIPELINE - run_id: ", run_id)
  if (isTRUE(cfg$use_embedded_codes)) {
    log_msg("CODE LISTS: Using EMBEDDED codes (no external tables required)")
  } else {
    log_msg("CODE LISTS: Using EXTERNAL tables from ", cfg$ref_schema)
  }
  if (isTRUE(cfg$use_quarterly_tables)) {
    log_msg("TABLES: Using quarterly tables (t_<table>_", get_quarter_suffix(cfg$study_end), ")")
  } else {
    log_msg("TABLES: Using single consolidated tables")
  }
 
  # Log criteria settings (already shown in prompt, but log for audit trail)
  log_msg("OUTPATIENT WINDOW: ", cfg$outpatient_window, " days")
  log_msg("OUTPUT TABLE: ", cfg$final_table_name)
  log_msg("=", SEP_59)
 
  # Connect with retry (now returns connection properly)
  con_env$con <- with_retry(function() {
    conn <- connect_databricks()
    log_msg("Connected to Databricks")
    conn
  })
 
  on.exit({
    if (!is.null(con_env$con)) try(DBI::dbDisconnect(con_env$con), silent = TRUE)
  }, add = TRUE)
 
  # Ensure run log table exists (schema created lazily by SQL statements)
  log_table <- ensure_run_log(con_env$con)
  log_msg("Run log table: ", log_table)
 
  # Build and run steps
  steps <- build_steps()
 
  # Remove NULL steps (e.g., Step 25 if create_criteria_view = FALSE)
  steps <- Filter(Negate(is.null), steps)
 
  # ============================================================
  # RUN MODE: Filter steps based on cfg$run_mode
  # ============================================================
  # FULL        = Run all steps (default)
  # BASE_ONLY   = Build flags only (Steps 1-23), skip final filter
  # FILTER_ONLY = Skip base build, apply criteria from ELIG_COH_ALLFLAGS only (Step 24+)
  original_step_count <- length(steps)
 
  if (cfg$run_mode == "FILTER_ONLY") {
    log_msg("RUN_MODE=FILTER_ONLY: Skipping base build; applying criteria only.")
    # Find steps that start with "24" or "25" (the filter/view steps)
    filter_step_indices <- grep("^2[45]", sapply(steps, function(s) s$name))
    if (length(filter_step_indices) == 0) {
      stop("FILTER_ONLY mode requested but no filter steps (24_*, 25*) found!")
    }
    steps <- steps[filter_step_indices]
    log_msg("  Running ", length(steps), " filter step(s) from ", original_step_count, " total")
   
  } else if (cfg$run_mode == "BASE_ONLY") {
    log_msg("RUN_MODE=BASE_ONLY: Building flags only; skipping final filter.")
    # Exclude steps that start with "24" or "25"
    base_step_indices <- grep("^2[45]", sapply(steps, function(s) s$name), invert = TRUE)
    steps <- steps[base_step_indices]
    log_msg("  Running ", length(steps), " base step(s), skipping filter steps")
   
  } else if (cfg$run_mode != "FULL") {
    log_msg("WARNING: Unknown RUN_MODE '", cfg$run_mode, "', defaulting to FULL")
  }
 
  
  # DYNAMIC IE MODE: Exclude final filter steps (criteria applied interactively after base build)
  if (isTRUE(cfg$dynamic_ie_order) && should_prompt()) {
    if (cfg$run_mode == "FILTER_ONLY") {
      log_msg("WARN: DYNAMIC_IE_ORDER is not compatible with FILTER_ONLY mode. Ignoring dynamic mode.")
      cfg$dynamic_ie_order <<- FALSE
    } else {
      filter_indices <- grep("^2[45]", sapply(steps, function(s) s$name))
      if (length(filter_indices) > 0) {
        steps <- steps[-filter_indices]
      }
      log_msg("DYNAMIC IE MODE: Will apply criteria interactively after base steps complete")
    }
  }
  total_steps <- length(steps)
 
  cat("\n")
  cat(SEP_60, "\n")
  cat("  STARTING PIPELINE: ", total_steps, " steps to process")
  if (cfg$run_mode != "FULL") {
    cat(" (", cfg$run_mode, " mode)")
  }
  cat("\n")
  cat(SEP_60, "\n")
 
  for (i in seq_along(steps)) {
    s <- steps[[i]]
    with_retry(function() {
      run_step(log_table, s$name, s$sql, qc_sql = s$qc,
               description = s$description, step_num = i, total_steps = total_steps,
               source_tables = s$source_tables)
    })
   
    # Materialize checkpoint tables to personal schema (breaks lazy eval chain)
    if (isTRUE(cfg$materialize_checkpoints) && nzchar(cfg$personal_schema)) {
      # Extract table name from step name (e.g., "08a_mm_dx_events_all" -> "mm_dx_events_all")
      table_name <- sub("^[0-9]+[a-z]?_", "", s$name)
      if (table_name %in% CHECKPOINT_STEPS) {
        materialize_to_personal_schema(con_env$con, table_name, replace = TRUE)
      }
    }
  }
 
  # ============================================================
  # DYNAMIC IE MODE: Interactive criterion-by-criterion filtering
  # ============================================================
  if (isTRUE(cfg$dynamic_ie_order) && should_prompt()) {
    log_msg("=", SEP_59)
    log_msg("BASE STEPS COMPLETE - Entering dynamic IE criteria selection...")
    run_dynamic_ie_filter()
    log_msg("=", SEP_59)
    log_msg("DYNAMIC IE PIPELINE COMPLETE")
    log_msg("=", SEP_59)
    return(invisible(NULL))
  }
 
  # Final summary
  log_msg("=", SEP_59)
  log_msg("PIPELINE COMPLETE - Generating attrition report...")
 
  # Collect detailed attrition counts (uses work_tbl helper for local/remote mode)
  # FIXED: Reordered to match attrition table Steps 0-10
  # Added 30/60/90-day cohort columns per attrition table spec
  tryCatch({
    # ----------------------------------------------------------
    # ATTRITION TABLE: Steps 0-10 with 30/60/90-day cohort breakdown
    # Order matches attritiom.pdf exactly:
    #   Step 0: Base (>=1 MM dx)
    #   Step 1: Qualifying (IP strict OR 2 OP broad in 30/60/90d)
    #   Step 2: Age >= 18
    #   Step 3: FU therapy required
    #   Step 4: No baseline therapy (exclusion)
    #   Step 5: CE_b (6-mo baseline enrollment)
    #   Step 6: CE_f (1+ day follow-up enrollment)
    #   Step 7: Baseline MM evidence (exclusion)
    #   Step 8: Other cancer (exclusion)
    #   Step 9: Pregnancy (exclusion)
    #   Step 10: Clinical trial (exclusion)
    # ----------------------------------------------------------
   
    # Step 0: Base cohort - all patients with >=1 MM dx in ID period (BROAD codes)
    # Same count for all 3 windows (pre-qualifying)
    q0 <- DBI::dbGetQuery(con_env$con, glue("SELECT count(DISTINCT PATID) AS n FROM {work_tbl('mm_dx_events_id')}"))
    record_attrition("00_step0_base", "Step 0: >=1 MM dx (ID period)", q0$n, q0$n, q0$n)
   
    # Step 1: Qualifying - 30/60/90 day cohorts
    # Per spec: 1+ IP (strict) OR 2 OP (broad) within window
    q1_30 <- DBI::dbGetQuery(con_env$con, glue("SELECT count(DISTINCT PATID) AS n FROM {work_tbl('ELIG_COH_ALLFLAGS')} WHERE inpt_qual = 1 OR outpt2_30 = 1"))
    q1_60 <- DBI::dbGetQuery(con_env$con, glue("SELECT count(DISTINCT PATID) AS n FROM {work_tbl('ELIG_COH_ALLFLAGS')} WHERE inpt_qual = 1 OR outpt2_60 = 1"))
    q1_90 <- DBI::dbGetQuery(con_env$con, glue("SELECT count(DISTINCT PATID) AS n FROM {work_tbl('ELIG_COH_ALLFLAGS')} WHERE inpt_qual = 1 OR outpt2_90 = 1"))
    record_attrition("01_step1_qualifying", "Step 1: Qualifying dx", q1_30$n, q1_60$n, q1_90$n)
   
    # Qualifying filters for each window
    qual_30 <- "(inpt_qual = 1 OR outpt2_30 = 1)"
    qual_60 <- "(inpt_qual = 1 OR outpt2_60 = 1)"
    qual_90 <- "(inpt_qual = 1 OR outpt2_90 = 1)"
   
    # Helper: run a count query for all 3 windows
    count_3w <- function(where_30, where_60, where_90) {
      tbl <- work_tbl('ELIG_COH_ALLFLAGS')
      n30 <- DBI::dbGetQuery(con_env$con, glue("SELECT count(DISTINCT PATID) AS n FROM {tbl} WHERE {where_30}"))$n
      n60 <- DBI::dbGetQuery(con_env$con, glue("SELECT count(DISTINCT PATID) AS n FROM {tbl} WHERE {where_60}"))$n
      n90 <- DBI::dbGetQuery(con_env$con, glue("SELECT count(DISTINCT PATID) AS n FROM {tbl} WHERE {where_90}"))$n
      list(n_30 = n30, n_60 = n60, n_90 = n90)
    }
   
    # Step 2: Age >= 18 at index year
    s2 <- count_3w(
      glue("{qual_30} AND AGE_INDEX_YR >= 18"),
      glue("{qual_60} AND AGE_INDEX_YR >= 18"),
      glue("{qual_90} AND AGE_INDEX_YR >= 18"))
    record_attrition("02_step2_age", "Step 2: Age >= 18 at index year", s2$n_30, s2$n_60, s2$n_90)
   
    # Step 3: Evidence of FU therapy (MM_FU_agents = 1)
    s3 <- count_3w(
      glue("{qual_30} AND AGE_INDEX_YR >= 18 AND MM_FU_agents = 1"),
      glue("{qual_60} AND AGE_INDEX_YR >= 18 AND MM_FU_agents = 1"),
      glue("{qual_90} AND AGE_INDEX_YR >= 18 AND MM_FU_agents = 1"))
    record_attrition("03_step3_fu_therapy", "Step 3: FU therapy required", s3$n_30, s3$n_60, s3$n_90)
   
    # Step 4: No baseline therapy (MM_bl_agents = 0) - EXCLUSION
    s4 <- count_3w(
      glue("{qual_30} AND AGE_INDEX_YR >= 18 AND MM_FU_agents = 1 AND MM_bl_agents = 0"),
      glue("{qual_60} AND AGE_INDEX_YR >= 18 AND MM_FU_agents = 1 AND MM_bl_agents = 0"),
      glue("{qual_90} AND AGE_INDEX_YR >= 18 AND MM_FU_agents = 1 AND MM_bl_agents = 0"))
    record_attrition("04_step4_no_bl_therapy", "Step 4: No baseline therapy (excl)", s4$n_30, s4$n_60, s4$n_90)
   
    # Step 5: CE_b - 6-month baseline enrollment
    s5 <- count_3w(
      glue("{qual_30} AND AGE_INDEX_YR >= 18 AND MM_FU_agents = 1 AND MM_bl_agents = 0 AND CE_b = 1"),
      glue("{qual_60} AND AGE_INDEX_YR >= 18 AND MM_FU_agents = 1 AND MM_bl_agents = 0 AND CE_b = 1"),
      glue("{qual_90} AND AGE_INDEX_YR >= 18 AND MM_FU_agents = 1 AND MM_bl_agents = 0 AND CE_b = 1"))
    record_attrition("05_step5_ce_baseline", "Step 5: 6-mo baseline enrollment", s5$n_30, s5$n_60, s5$n_90)
   
    # Step 6: CE_f - 1+ day follow-up enrollment
    s6 <- count_3w(
      glue("{qual_30} AND AGE_INDEX_YR >= 18 AND MM_FU_agents = 1 AND MM_bl_agents = 0 AND CE_b = 1 AND CE_f = 1"),
      glue("{qual_60} AND AGE_INDEX_YR >= 18 AND MM_FU_agents = 1 AND MM_bl_agents = 0 AND CE_b = 1 AND CE_f = 1"),
      glue("{qual_90} AND AGE_INDEX_YR >= 18 AND MM_FU_agents = 1 AND MM_bl_agents = 0 AND CE_b = 1 AND CE_f = 1"))
    record_attrition("06_step6_ce_followup", "Step 6: 1+ day FU enrollment", s6$n_30, s6$n_60, s6$n_90)
   
    # Step 7: Baseline MM evidence (exclusion) - always report even if not applied
    base7 <- "AGE_INDEX_YR >= 18 AND MM_FU_agents = 1 AND MM_bl_agents = 0 AND CE_b = 1 AND CE_f = 1 AND MM_baseline_diag = 0"
    s7 <- count_3w(
      glue("{qual_30} AND {base7}"),
      glue("{qual_60} AND {base7}"),
      glue("{qual_90} AND {base7}"))
    excl_suffix <- if (isTRUE(cfg$apply_baseline_nondx_excl)) "" else " [not applied]"
    record_attrition("07_step7_bl_mm_evidence", paste0("Step 7: BL MM evidence (excl)", excl_suffix), s7$n_30, s7$n_60, s7$n_90)
   
    # Cumulative base for steps 8-10: always includes Step 7 (MM_baseline_diag)
    # so that the attrition table is truly sequential per protocol order.
    # The apply_baseline_nondx_excl toggle only affects the final cohort filter
    # (Step 24), not the attrition table counts.
    base_cond <- "AGE_INDEX_YR >= 18 AND MM_FU_agents = 1 AND MM_bl_agents = 0 AND CE_b = 1 AND CE_f = 1 AND MM_baseline_diag = 0"
   
    # Step 8: Other cancer (exclusion) - always report
    s8 <- count_3w(
      glue("{qual_30} AND {base_cond} AND OTHER_MALIGN_FLAG = 0"),
      glue("{qual_60} AND {base_cond} AND OTHER_MALIGN_FLAG = 0"),
      glue("{qual_90} AND {base_cond} AND OTHER_MALIGN_FLAG = 0"))
    excl_suffix8 <- if (isTRUE(cfg$apply_other_malig_excl)) "" else " [not applied]"
    record_attrition("08_step8_other_cancer", paste0("Step 8: Other cancer (excl)", excl_suffix8), s8$n_30, s8$n_60, s8$n_90)
   
    # Step 9: Pregnancy (exclusion) - always report
    preg_cond <- base_cond
    if (isTRUE(cfg$apply_other_malig_excl)) {
      preg_cond <- paste0(preg_cond, " AND OTHER_MALIGN_FLAG = 0")
    }
    s9 <- count_3w(
      glue("{qual_30} AND {preg_cond} AND PREGNANT_FLAG = 0"),
      glue("{qual_60} AND {preg_cond} AND PREGNANT_FLAG = 0"),
      glue("{qual_90} AND {preg_cond} AND PREGNANT_FLAG = 0"))
    excl_suffix9 <- if (isTRUE(cfg$apply_pregnancy_excl)) "" else " [not applied]"
    record_attrition("09_step9_pregnancy", paste0("Step 9: Pregnancy (excl)", excl_suffix9), s9$n_30, s9$n_60, s9$n_90)
   
    # Step 10: Clinical trial (exclusion) - always report
    ct_cond <- preg_cond
    if (isTRUE(cfg$apply_pregnancy_excl)) {
      ct_cond <- paste0(ct_cond, " AND PREGNANT_FLAG = 0")
    }
    s10 <- count_3w(
      glue("{qual_30} AND {ct_cond} AND CLINTRIAL_BASELINE = 0 AND CLINTRIAL_FOLLOWUP = 0"),
      glue("{qual_60} AND {ct_cond} AND CLINTRIAL_BASELINE = 0 AND CLINTRIAL_FOLLOWUP = 0"),
      glue("{qual_90} AND {ct_cond} AND CLINTRIAL_BASELINE = 0 AND CLINTRIAL_FOLLOWUP = 0"))
    excl_suffix10 <- if (isTRUE(cfg$apply_clintrial_excl)) "" else " [not applied]"
    record_attrition("10_step10_clintrial", paste0("Step 10: Clinical trial (excl)", excl_suffix10), s10$n_30, s10$n_60, s10$n_90)
   
    # Final cohort (after applied criteria + earliest index per patient)
    q_final <- DBI::dbGetQuery(con_env$con, glue("SELECT count(*) AS n FROM {work_tbl(cfg$final_table_name)}"))
    record_attrition("99_final", glue("FINAL COHORT ({cfg$final_table_name})"), q_final$n, q_final$n, q_final$n)
   
    # Print the attrition table
    print_attrition_table()
   
    # Print additional summary statistics
    cat("\n")
    cat(SEP_60, "\n")
    cat("                 COHORT CHARACTERISTICS                     \n")
    cat(SEP_60, "\n")
   
    # Get summary stats from final cohort (uses configurable final_table_name)
    stats_sql <- glue("
      SELECT
        count(*) AS n_patients,
        avg(AGE_INDEX_YR) AS mean_age,
        sum(CASE WHEN GDR_CD = 'M' THEN 1 ELSE 0 END) AS n_male,
        sum(CASE WHEN GDR_CD = 'F' THEN 1 ELSE 0 END) AS n_female,
        avg(FU_DAYS) AS mean_fu_days,
        min(INDEX_DATE) AS min_index_date,
        max(INDEX_DATE) AS max_index_date,
        sum(CASE WHEN index_source = 'INPATIENT' THEN 1 ELSE 0 END) AS n_inpatient_index,
        sum(CASE WHEN DEATH_DT IS NOT NULL THEN 1 ELSE 0 END) AS n_with_death
      FROM {work_tbl(cfg$final_table_name)}
    ")
    stats <- DBI::dbGetQuery(con_env$con, stats_sql)
   
    cat(sprintf("Total patients:          %s\n", format(stats$n_patients, big.mark = ",")))
    cat(sprintf("Mean age at index:       %.1f years\n", stats$mean_age))
    cat(sprintf("Male / Female:           %s / %s\n",
                format(stats$n_male, big.mark = ","),
                format(stats$n_female, big.mark = ",")))
    cat(sprintf("Inpatient index:         %s (%.1f%%)\n",
                format(stats$n_inpatient_index, big.mark = ","),
                100 * stats$n_inpatient_index / stats$n_patients))
    cat(sprintf("Mean follow-up:          %.1f days\n", stats$mean_fu_days))
    cat(sprintf("Index date range:        %s to %s\n", stats$min_index_date, stats$max_index_date))
    cat(sprintf("Patients with death:     %s (%.1f%%)\n",
                format(stats$n_with_death, big.mark = ","),
                100 * stats$n_with_death / stats$n_patients))
    cat(SEP_60, "\n")
   
    # ----------------------------------------------------------
    # DOD JOINABILITY VALIDATION (per Optum Business Rules warning)
    # Optum warns that DOD/SES may be encrypted differently
    # This QC validates that PATID keys match
    # ----------------------------------------------------------
    cat("\n")
    cat(DASH_60, "\n")
    cat("  DOD JOINABILITY VALIDATION\n")
    cat(DASH_60, "\n")
   
    dod_qc_sql <- glue("
      WITH dod_ids AS (
        SELECT DISTINCT PATID
        FROM {cdm_src(cfg$tbl_dod)}
        WHERE YMDOD IS NOT NULL AND LENGTH(TRIM(YMDOD)) >= 4
      )
      SELECT
        count(DISTINCT q.PATID) AS n_qualifying,
        count(DISTINCT d.PATID) AS n_dod_matched,
        ROUND(100.0 * count(DISTINCT d.PATID) / NULLIF(count(DISTINCT q.PATID), 0), 2) AS pct_matched
      FROM {work_tbl('mm_qualifying')} q
      LEFT JOIN dod_ids d ON q.PATID = d.PATID
    ")
    dod_qc <- DBI::dbGetQuery(con_env$con, dod_qc_sql)
   
    cat(sprintf("Qualifying patients:     %s\n", format(dod_qc$n_qualifying, big.mark = ",")))
    cat(sprintf("DOD matches:             %s (%.2f%%)\n",
                format(dod_qc$n_dod_matched, big.mark = ","),
                dod_qc$pct_matched))
   
    if (dod_qc$pct_matched < 1) {
      cat("WARNING: DOD join rate is < 1%. This may indicate:\n")
      cat("  - PATID encryption mismatch between tables\n")
      cat("  - DOD table may require different linkage key\n")
      cat("  - Verify DOD table structure in your environment\n")
    } else if (dod_qc$pct_matched < 10) {
      cat("NOTE: Low DOD join rate may be expected for MM cohort.\n")
    } else {
      cat("DOD join rate looks reasonable for validation.\n")
    }
    cat(DASH_60, "\n")
   
    # ----------------------------------------------------------
    # INPATIENT VALIDATION (Approach 1 + Approach 2)
    # ----------------------------------------------------------
    cat("\n")
    cat(DASH_60, "\n")
    cat("  INPATIENT CLASSIFICATION VALIDATION (Approach 1 + 2)\n")
    cat(DASH_60, "\n")
   
    conf_qc_sql <- glue("
      SELECT
        count(*) AS n_mm_dx_events,
        sum(inpatient_flg) AS n_inpatient_total,
        sum(pos_tos_inpatient) AS n_via_pos_tos,
        sum(conf_validated) AS n_via_conf,
        sum(CASE WHEN pos_tos_inpatient = 1 AND conf_validated = 1 THEN 1 ELSE 0 END) AS n_both_approaches,
        sum(CASE WHEN pos_tos_inpatient = 1 AND conf_validated = 0 THEN 1 ELSE 0 END) AS n_pos_tos_only,
        sum(CASE WHEN pos_tos_inpatient = 0 AND conf_validated = 1 THEN 1 ELSE 0 END) AS n_conf_only
      FROM {work_tbl('mm_dx_events_all')}
    ")
    conf_qc <- DBI::dbGetQuery(con_env$con, conf_qc_sql)
   
    cat(sprintf("MM dx events (total):    %s\n", format(conf_qc$n_mm_dx_events, big.mark = ",")))
    cat(sprintf("Inpatient (combined):    %s (%.1f%%)\n",
                format(conf_qc$n_inpatient_total, big.mark = ","),
                100 * conf_qc$n_inpatient_total / conf_qc$n_mm_dx_events))
    cat(sprintf("  Via POS/TOS (Appr 1):  %s\n", format(conf_qc$n_via_pos_tos, big.mark = ",")))
    cat(sprintf("  Via CONF_ID (Appr 2):  %s\n", format(conf_qc$n_via_conf, big.mark = ",")))
    cat(sprintf("  Both approaches:       %s\n", format(conf_qc$n_both_approaches, big.mark = ",")))
    cat(sprintf("  POS/TOS only:          %s\n", format(conf_qc$n_pos_tos_only, big.mark = ",")))
    cat(sprintf("  CONF_ID only:          %s\n", format(conf_qc$n_conf_only, big.mark = ",")))
    cat(DASH_60, "\n")
   
    # ----------------------------------------------------------
    # INPATIENT VALIDATION (scoped to qualifying cohort only)
    # ----------------------------------------------------------
    cat("\n")
    cat(DASH_60, "\n")
    cat("  INPATIENT CLASSIFICATION (Qualifying Cohort, 90d)\n")
    cat(DASH_60, "\n")
   
    cohort_conf_sql <- glue("
      SELECT
        count(*) AS n_mm_dx_events,
        sum(inpatient_flg) AS n_inpatient_total,
        sum(pos_tos_inpatient) AS n_via_pos_tos,
        sum(conf_validated) AS n_via_conf,
        sum(CASE WHEN pos_tos_inpatient = 1 AND conf_validated = 1 THEN 1 ELSE 0 END) AS n_both_approaches,
        sum(CASE WHEN pos_tos_inpatient = 1 AND conf_validated = 0 THEN 1 ELSE 0 END) AS n_pos_tos_only,
        sum(CASE WHEN pos_tos_inpatient = 0 AND conf_validated = 1 THEN 1 ELSE 0 END) AS n_conf_only
      FROM {work_tbl('mm_dx_events_all')} e
      WHERE e.PATID IN (
        SELECT DISTINCT PATID FROM {work_tbl('ELIG_COH_ALLFLAGS')}
        WHERE inpt_qual = 1 OR outpt2_90 = 1
      )
    ")
    cohort_conf <- DBI::dbGetQuery(con_env$con, cohort_conf_sql)
   
    cat(sprintf("MM dx events (cohort):   %s\n", format(cohort_conf$n_mm_dx_events, big.mark = ",")))
    cat(sprintf("Inpatient (combined):    %s (%.1f%%)\n",
                format(cohort_conf$n_inpatient_total, big.mark = ","),
                100 * cohort_conf$n_inpatient_total / cohort_conf$n_mm_dx_events))
    cat(sprintf("  Via POS/TOS (Appr 1):  %s\n", format(cohort_conf$n_via_pos_tos, big.mark = ",")))
    cat(sprintf("  Via CONF_ID (Appr 2):  %s\n", format(cohort_conf$n_via_conf, big.mark = ",")))
    cat(sprintf("  Both approaches:       %s\n", format(cohort_conf$n_both_approaches, big.mark = ",")))
    cat(sprintf("  POS/TOS only:          %s\n", format(cohort_conf$n_pos_tos_only, big.mark = ",")))
    cat(sprintf("  CONF_ID only:          %s\n", format(cohort_conf$n_conf_only, big.mark = ",")))
    cat(DASH_60, "\n")
   
    # ----------------------------------------------------------
    # PATIENT-LEVEL INPATIENT APPROACH OVERLAP (Step 0 base)
    # Shows how many PATIENTS have inpatient events via each approach
    # ----------------------------------------------------------
    cat("\n")
    cat(DASH_60, "\n")
    cat("  PATIENT-LEVEL INPATIENT APPROACH OVERLAP (Step 0 base)\n")
    cat(DASH_60, "\n")
   
    pat_overlap_sql <- glue("
      WITH patient_flags AS (
        SELECT
          PATID,
          max(pos_tos_inpatient) AS has_pos_tos,
          max(conf_validated) AS has_conf,
          max(inpatient_flg) AS has_any_inpatient
        FROM {work_tbl('mm_dx_events_all')}
        GROUP BY PATID
      )
      SELECT
        count(*) AS n_total_patients,
        sum(has_any_inpatient) AS n_inpatient_any,
        sum(has_pos_tos) AS n_via_pos_tos,
        sum(has_conf) AS n_via_conf,
        sum(CASE WHEN has_pos_tos = 1 AND has_conf = 1 THEN 1 ELSE 0 END) AS n_both,
        sum(CASE WHEN has_pos_tos = 1 AND has_conf = 0 THEN 1 ELSE 0 END) AS n_pos_tos_only,
        sum(CASE WHEN has_pos_tos = 0 AND has_conf = 1 THEN 1 ELSE 0 END) AS n_conf_only,
        sum(CASE WHEN has_any_inpatient = 0 THEN 1 ELSE 0 END) AS n_outpatient_only
      FROM patient_flags
    ")
    pat_overlap <- DBI::dbGetQuery(con_env$con, pat_overlap_sql)
   
    cat(sprintf("Total patients (Step 0): %s\n", format(pat_overlap$n_total_patients, big.mark = ",")))
    cat(sprintf("Any inpatient event:     %s (%.1f%%)\n",
                format(pat_overlap$n_inpatient_any, big.mark = ","),
                100 * pat_overlap$n_inpatient_any / pat_overlap$n_total_patients))
    cat(sprintf("  Via POS/TOS (Appr 1):  %s (%.1f%%)\n",
                format(pat_overlap$n_via_pos_tos, big.mark = ","),
                100 * pat_overlap$n_via_pos_tos / pat_overlap$n_total_patients))
    cat(sprintf("  Via CONF_ID (Appr 2):  %s (%.1f%%)\n",
                format(pat_overlap$n_via_conf, big.mark = ","),
                100 * pat_overlap$n_via_conf / pat_overlap$n_total_patients))
    cat(sprintf("  Both approaches:       %s (%.1f%%)\n",
                format(pat_overlap$n_both, big.mark = ","),
                100 * pat_overlap$n_both / pat_overlap$n_total_patients))
    cat(sprintf("  POS/TOS only:          %s (%.1f%%)\n",
                format(pat_overlap$n_pos_tos_only, big.mark = ","),
                100 * pat_overlap$n_pos_tos_only / pat_overlap$n_total_patients))
    cat(sprintf("  CONF_ID only:          %s (%.1f%%)\n",
                format(pat_overlap$n_conf_only, big.mark = ","),
                100 * pat_overlap$n_conf_only / pat_overlap$n_total_patients))
    cat(sprintf("Outpatient only:         %s (%.1f%%)\n",
                format(pat_overlap$n_outpatient_only, big.mark = ","),
                100 * pat_overlap$n_outpatient_only / pat_overlap$n_total_patients))
    cat(DASH_60, "\n")
   
  }, error = function(e) {
    log_msg("WARN: Could not generate full attrition report: ", conditionMessage(e))
  })
 
  log_msg("=", SEP_59)
}
 
# Run if executed as script
if (!interactive()) {
  main()
} else {
  log_msg("Source loaded. Call main() to run pipeline.")
}
