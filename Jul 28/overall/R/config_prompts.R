# Configuration defaults. config.csv is applied to the environment before
# this file is sourced, so these pick it up.

# ---- Validation helpers ----
validate_outpatient_window <- function(x, default = 90L) {
  x <- suppressWarnings(as.integer(x))
  if (is.na(x) || !(x %in% c(30L, 60L, 90L))) return(default)
  x
}

# ---- Configuration defaults ----
# Defaults; build.R pins the ones that move the cohort as a local.
cfg_defaults <- list(
  # ---- Databricks / ODBC ----
  dsn         = Sys.getenv("DATABRICKS_DSN", unset = "RWDE"),
  pwd         = Sys.getenv("DATABRICKS_PWD", unset = ""),
  # Set an empty string to fall back to the session's default catalog.
  catalog     = Sys.getenv("DATABRICKS_CATALOG", unset = "hive_metastore"),
  max_retries = as.integer(Sys.getenv("MAX_RETRIES", unset = "3")),
  base_sleep  = as.numeric(Sys.getenv("BASE_SLEEP_SECS", unset = "5")),

  # ---- Schemas (Optum CDM / Domino pattern) ----
  cdm_schema  = Sys.getenv("OPTUM_CDM_SCHEMA", unset = "clnprw_optum"),
  # pin_output_schema() sets this from the environment before the build reads
  # it. Blank here so a build that skipped that step stops instead of writing
  # somewhere shared.
  work_schema = "",

  # ---- Source tables ----
  tbl_member_elig       = "member_cont_enrollment",
  tbl_member_enrollment = "member_enrollment",
  tbl_medical           = "medical",
  tbl_med_diag          = "med_diagnosis",
  tbl_med_proc          = "med_procedure",
  tbl_rx                = "rx",
  tbl_dod               = "dod",
  tbl_confinement       = "confinement",
  use_quarterly_tables  = as.logical(Sys.getenv("USE_QUARTERLY_TABLES", unset = "TRUE")),

  # ---- Code-list table names ----
  # Used by cohort attrition pipeline
  cl_mm_dx           = "cl_mm_dx",
  cl_mm_therapy      = "cl_mm_therapy",
  cl_preg            = "cl_pregnancy",
  cl_clintrial       = "cl_clintrial",
  cl_other_malig     = "cl_other_malignancies",

  # ---- Code-list CSVs (on server filesystem at /mnt/code/codelist/) ----
  # When use_csv_codelists = TRUE, the cohort CSVs are loaded into temp views.
  use_csv_codelists = as.logical(Sys.getenv("USE_CSV_CODELISTS", unset = "TRUE")),
  codelist_dir      = Sys.getenv("CODELIST_DIR", unset = "/mnt/code/codelist"),
  # The five lists this build loads, and the file each comes from.
  codelist_csv_map  = list(
    cl_mm_dx              = "mm_dx.csv",
    cl_mm_therapy         = "cl_mma_codelist.csv",
    cl_pregnancy          = "pregnancy.csv",
    cl_clintrial          = "clintrial.csv",
    cl_other_malignancies = "other_malig.csv"
  ),

  # ---- Study parameters ----
  study_start   = "2015-07-01",
  study_end     = "2025-06-30",
  id_start      = "2016-01-01",
  id_end        = "2025-06-30",
  baseline_days = 183L,
  gap_days      = 30L,

  # ---- Diagnosis window thresholds (fixed) ----
  dx_window_30 = 30,
  dx_window_60 = 60,
  dx_window_90 = 90,

  # ---- Output ----
  final_table_name = Sys.getenv("FINAL_TABLE_NAME", unset = "ELIG_COH_FINAL"),
  outpatient_window = as.integer(Sys.getenv("OUTPATIENT_WINDOW", unset = "90")),

  # ---- Inclusion criteria (defaults for static/batch mode) ----
  # Read from config.csv, then checked against CONTRACT. This build only runs
  # with the values below; change both together, deliberately.
  apply_age_incl          = as.logical(Sys.getenv("APPLY_AGE_INCL",          unset = "TRUE")),
  min_age                 = as.integer(Sys.getenv("MIN_AGE",                 unset = "18")),
  apply_ce_b_incl         = as.logical(Sys.getenv("APPLY_CE_B_INCL",         unset = "TRUE")),
  apply_ce_f_incl         = as.logical(Sys.getenv("APPLY_CE_F_INCL",         unset = "TRUE")),
  apply_no_bl_agents_incl = as.logical(Sys.getenv("APPLY_NO_BL_AGENTS_INCL", unset = "TRUE")),
  apply_fu_agents_incl    = as.logical(Sys.getenv("APPLY_FU_AGENTS_INCL",    unset = "TRUE")),

  # ---- Exclusion criteria ----
  # config.csv turns all four off for Overall; the flags are still computed in
  # ELIG_COH_ALLFLAGS.
  apply_pregnancy_excl   = as.logical(Sys.getenv("APPLY_PREGNANCY_EXCL",   unset = "TRUE")),
  apply_clintrial_excl   = as.logical(Sys.getenv("APPLY_CLINTRIAL_EXCL",   unset = "TRUE")),
  apply_other_malig_excl = as.logical(Sys.getenv("APPLY_OTHER_MALIG_EXCL", unset = "TRUE")),
  apply_baseline_mm_excl = as.logical(Sys.getenv("APPLY_BASELINE_MM_EXCL", unset = "TRUE")),

  # ---- Disenrollment censoring (sensitivity flag) ----
  # FALSE (primary): IE follow-up window is min(study_end, death). Disenrolled
  #                  patients keep contributing follow-up.
  # TRUE  (sensitivity): IE follow-up window also caps at last continuous-enrollment
  #                  end (ENDDATE_CE).
  # Sensitivity flag; the contract pins it FALSE.
  censor_at_disenrollment = as.logical(Sys.getenv("CENSOR_AT_DISENROLLMENT", unset = "FALSE")),

  # ---- Performance ----
  persist_to_schema       = as.logical(Sys.getenv("PERSIST_TO_SCHEMA", unset = "TRUE")),
  personal_schema         = "",   # set by pin_output_schema(), same as work_schema
  materialize_checkpoints = TRUE
)

CHECKPOINT_STEPS <- c("mm_dx_events_all", "mm_qualifying", "ELIG_COH_ALLFLAGS")
run_id <- Sys.getenv("DOMINO_RUN_ID", unset = format(Sys.time(), "%Y%m%d%H%M%S"))
