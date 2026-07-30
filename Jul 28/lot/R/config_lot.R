# Configuration for the LOT Part 2 pipeline. All parameters read from
# Sys.getenv() with defaults.

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
  # Same schema the cohort build writes to (see R/build_cohort.R,
  # pin_output_schema): <catalog>.<schema>, e.g. hive_metastore.osk02156.
  # No "gsk_mm_lot_work" fallback - that used to send LOT somewhere the cohort
  # build never wrote, and the missing-table error came many steps later.
  work_schema = local({
    s <- Sys.getenv("PROJECT_WORK_SCHEMA",
           unset = Sys.getenv("DOMINO_USER_NAME",
             unset = Sys.getenv("DOMINO_STARTING_USERNAME", unset = "")))
    if (!nzchar(s))
      stop("No work schema. Set DOMINO_USER_NAME to your personal schema ",
           "(e.g. osk02156), or PROJECT_WORK_SCHEMA to override.", call. = FALSE)
    s
  }),

  # Clinformatics CDM base tables
  tbl_medical  = "medical",
  tbl_med_proc = "med_procedure",
  tbl_med_diag = "med_diagnosis",
  tbl_rx       = "rx",

  # Use cumulative quarterly tables (t_<table>_YYYYqQ) like Part 1
  use_quarterly_tables = as.logical(Sys.getenv("USE_QUARTERLY_TABLES", unset = "TRUE")),
  study_end            = Sys.getenv("STUDY_END", unset = "2025-06-30"),

  # Cohort input (the cohort build's output). One LOT run per cohort:
  #   INPUT_COHORT_TABLE=OVERALL_COH_FINAL  ATTRITION_TABLE=overall_attrition_report
  #   INPUT_COHORT_TABLE=NDMM_COH_FINAL     ATTRITION_TABLE=ndmm_attrition_report
  input_cohort_table = Sys.getenv("INPUT_COHORT_TABLE", unset = "OVERALL_COH_FINAL"),

  # The cohort build prefixes this per cohort; the dashboards read it back.
  attrition_table = Sys.getenv("ATTRITION_TABLE", unset = "overall_attrition_report"),

  # Part 2 parameters
  # NOTE: There is only ONE 90-day discontinuation rule - the per-drug MAP-level one
  # below. No additional LOT-level wait exists (confirmed 13-May).
  induction_window_days       = as.integer(Sys.getenv("INDUCTION_WINDOW_DAYS", unset = "60")),
  lot_n_induction_window_days = as.integer(Sys.getenv("INDUCTION_WINDOW_DAYS_LOT_N", unset = "30")),
  map_discon_gap_days         = as.integer(Sys.getenv("MAP_DISCON_GAP_DAYS", unset = "90")),
  medical_day_supply          = as.integer(Sys.getenv("MEDICAL_DAY_SUPPLY", unset = "28")),

  # Outpatient-confirmation window for the attrition report rendering
  # (descriptives_lot.R ATTRITION tab picks the primary n_{30/60/90} column
  # by this value). Must match Part 1's OUTPATIENT_WINDOW to show Part 2's
  # built cohort. Read from the same env var so one override covers both.
  outpatient_window = as.integer(Sys.getenv("OUTPATIENT_WINDOW", unset = "90")),

  # Code list sourcing - CSV-only (no embedded fallbacks)
  codelist_dir = Sys.getenv("CODELIST_DIR", unset = "/mnt/code/codelist"),

  # SCT parameters
  sct_auto_window_days = as.integer(Sys.getenv("SCT_AUTO_WINDOW_DAYS", unset = "13")),
  sct_auto_gap_days    = as.integer(Sys.getenv("SCT_AUTO_GAP_DAYS", unset = "60")),
  sct_tandem_days      = as.integer(Sys.getenv("SCT_TANDEM_DAYS", unset = "180")),

  # CAR-T consolidation: new agents within this window of CART are consolidation, not MED_ADD
  cart_consolidation_days = as.integer(Sys.getenv("CART_CONSOLIDATION_DAYS", unset = "45")),

  # Disenrollment censoring (sensitivity flag).
  # FALSE (default, primary analysis): OBS_END_DT = ENDDATE = min(death, study_end).
  #                                    Disenrolled patients keep contributing follow-up.
  # TRUE  (sensitivity):               OBS_END_DT = coalesce(ENDDATE_CE, ENDDATE),
  #                                    so disenrollment also caps observation.
  # ENDDATE_CE is preserved as a column on lot_patient_input either way, so flipping
  # this flag is the only change needed to run the sensitivity branch.
  censor_at_disenrollment = as.logical(Sys.getenv("CENSOR_AT_DISENROLLMENT", unset = "FALSE")),

  # Persist outputs
  persist_to_schema = as.logical(Sys.getenv("PERSIST_TO_SCHEMA", unset = "TRUE")),

  # Output directory for figures
  output_dir = Sys.getenv("OUTPUT_DIR", unset = "/mnt/artifacts/results"),

  # Retry controls
  max_retries = 4,
  base_sleep  = 5,

  # Optional reporting flags (new: gate descriptives/dashboard/CYCLO)
  generate_descriptives = as.logical(Sys.getenv("GENERATE_DESCRIPTIVES", unset = "TRUE")),
  build_dashboard       = as.logical(Sys.getenv("BUILD_DASHBOARD", unset = "TRUE")),
  run_cyclo_deepdive    = as.logical(Sys.getenv("RUN_CYCLO_DEEPDIVE", unset = "TRUE"))
)

run_id <- Sys.getenv("DOMINO_RUN_ID", unset = format(Sys.time(), "%Y%m%d%H%M%S"))
