# ============================================================
# config_lot.R — Configuration for LOT Part 2 pipeline
# ============================================================
# Extracted from lot_program.R during modularization.
# All parameters use Sys.getenv() with sensible defaults.
# ============================================================

suppressPackageStartupMessages({
  library(DBI)
  library(odbc)
  library(glue)
  library(dplyr)
})

cfg <- list(
  # Connection
  dsn = Sys.getenv("DATABRICKS_DSN", unset = "RWDE"),
  pwd = Sys.getenv("DATABRICKS_PWD", unset = ""),

  # Databricks catalog + schemas
  catalog     = Sys.getenv("DATABRICKS_CATALOG", unset = "hive_metastore"),
  cdm_schema  = Sys.getenv("OPTUM_CDM_SCHEMA", unset = "clnprw_optum"),
  work_schema = Sys.getenv("PROJECT_WORK_SCHEMA",
                           unset = Sys.getenv("DOMINO_USER_NAME", unset = "gsk_mm_lot_work")),

  # Clinformatics CDM base tables (validated against optum data dict.pdf)
  tbl_medical  = "medical",
  tbl_med_proc = "med_procedure",
  tbl_med_diag = "med_diagnosis",
  tbl_rx       = "rx",

  # Use cumulative quarterly tables (t_<table>_YYYYqQ) like Part 1
  use_quarterly_tables = as.logical(Sys.getenv("USE_QUARTERLY_TABLES", unset = "TRUE")),
  study_end            = Sys.getenv("STUDY_END", unset = "2025-06-30"),

  # Cohort input (Part 1 output)
  input_cohort_table = Sys.getenv("INPUT_COHORT_TABLE", unset = "ELIG_COH_FINAL"),

  # Part 2 parameters
  induction_window_days = as.integer(Sys.getenv("INDUCTION_WINDOW_DAYS", unset = "60")),
  map_discon_gap_days   = as.integer(Sys.getenv("MAP_DISCON_GAP_DAYS", unset = "90")),
  lot_discon_gap_days   = as.integer(Sys.getenv("LOT_DISCON_GAP_DAYS", unset = "90")),
  medical_day_supply    = as.integer(Sys.getenv("MEDICAL_DAY_SUPPLY", unset = "28")),

  # Maintenance parameters (per protocol Section 5.1.1)
  maint_min_days         = as.integer(Sys.getenv("MAINT_MIN_DAYS", unset = "120")),
  maint_post_sct_min_days = as.integer(Sys.getenv("MAINT_POST_SCT_MIN_DAYS", unset = "30")),
  maint_sct_window_days  = as.integer(Sys.getenv("MAINT_SCT_WINDOW_DAYS", unset = "180")),

  # Code list sourcing — CSV-only (no embedded fallbacks)
  codelist_dir = Sys.getenv("CODELIST_DIR", unset = "/mnt/code/codelist"),

  # SCT parameters (per sct.pdf spec section 7)
  sct_auto_window_days = as.integer(Sys.getenv("SCT_AUTO_WINDOW_DAYS", unset = "13")),
  sct_auto_gap_days    = as.integer(Sys.getenv("SCT_AUTO_GAP_DAYS", unset = "60")),
  sct_tandem_days      = as.integer(Sys.getenv("SCT_TANDEM_DAYS", unset = "180")),

  # Persist outputs
  persist_to_schema = as.logical(Sys.getenv("PERSIST_TO_SCHEMA", unset = "TRUE")),

  # Output directory for figures
  output_dir = Sys.getenv("OUTPUT_DIR", unset = "/mnt/results"),

  # Retry controls
  max_retries = 4,
  base_sleep  = 5,

  # Optional reporting flags (new: gate descriptives/dashboard/CYCLO)
  generate_descriptives = as.logical(Sys.getenv("GENERATE_DESCRIPTIVES", unset = "TRUE")),
  build_dashboard       = as.logical(Sys.getenv("BUILD_DASHBOARD", unset = "TRUE")),
  run_cyclo_deepdive    = as.logical(Sys.getenv("RUN_CYCLO_DEEPDIVE", unset = "TRUE"))
)

run_id <- Sys.getenv("DOMINO_RUN_ID", unset = format(Sys.time(), "%Y%m%d%H%M%S"))
