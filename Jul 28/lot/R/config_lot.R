# Settings for the LOT build. Values come from config.csv; the environment
# wins over it. build_lot.R checks them against CONTRACT before anything runs.
# The cohort table and prefix are not here - the caller passes those.

cfg_defaults <- list(
  # ---- Connection ----
  dsn = Sys.getenv("DATABRICKS_DSN", unset = "RWDE"),
  pwd = Sys.getenv("DATABRICKS_PWD", unset = ""),

  # ---- Catalog and schemas ----
  catalog    = Sys.getenv("DATABRICKS_CATALOG", unset = "hive_metastore"),
  cdm_schema = Sys.getenv("OPTUM_CDM_SCHEMA", unset = "clnprw_optum"),
  # pin_output_schema() sets this from the environment before the build reads
  # it. Blank here so a build that skipped that step stops instead of writing
  # somewhere shared.
  work_schema = "",

  # ---- Which cohort this run is for ----
  # The cohort table is named by the cohort build, so it is read as-is.
  # object_prefix goes on LOT's own outputs, which is what keeps two cohorts
  # from overwriting each other in one schema.
  input_cohort_table = Sys.getenv("INPUT_COHORT_TABLE", unset = ""),
  object_prefix      = Sys.getenv("OBJECT_PREFIX", unset = ""),

  # ---- CDM source tables ----
  tbl_medical  = "medical",
  tbl_med_proc = "med_procedure",
  tbl_med_diag = "med_diagnosis",
  tbl_rx       = "rx",

  use_quarterly_tables = as.logical(Sys.getenv("USE_QUARTERLY_TABLES", unset = "TRUE")),
  study_end            = Sys.getenv("STUDY_END", unset = "2025-06-30"),

  # ---- LOT parameters ----
  # One 90-day discontinuation rule only, at MAP level per drug. There is no
  # second LOT-level wait.
  induction_window_days       = as.integer(Sys.getenv("INDUCTION_WINDOW_DAYS", unset = "60")),
  lot_n_induction_window_days = as.integer(Sys.getenv("INDUCTION_WINDOW_DAYS_LOT_N", unset = "30")),
  map_discon_gap_days         = as.integer(Sys.getenv("MAP_DISCON_GAP_DAYS", unset = "90")),
  medical_day_supply          = as.integer(Sys.getenv("MEDICAL_DAY_SUPPLY", unset = "28")),

  # ---- SCT parameters ----
  sct_auto_window_days = as.integer(Sys.getenv("SCT_AUTO_WINDOW_DAYS", unset = "13")),
  sct_auto_gap_days    = as.integer(Sys.getenv("SCT_AUTO_GAP_DAYS", unset = "60")),
  sct_tandem_days      = as.integer(Sys.getenv("SCT_TANDEM_DAYS", unset = "180")),

  # New agents within this window of a CAR-T are consolidation, not a med add.
  cart_consolidation_days = as.integer(Sys.getenv("CART_CONSOLIDATION_DAYS", unset = "45")),

  # ---- LOT2 and later ----
  # single_day: an ALLO line spans only the transplant date.
  allo_lot_span = Sys.getenv("ALLO_LOT_SPAN", unset = "single_day"),
  max_lot       = as.integer(Sys.getenv("MAX_LOT", unset = "5")),

  # ---- Observation end ----
  # FALSE (primary): OBS_END_DT = ENDDATE = min(death, study_end), so a
  # disenrolled patient keeps contributing follow-up.
  # TRUE (sensitivity): disenrollment caps observation too. ENDDATE_CE is kept
  # on lot_patient_input either way, so this flag is the only change needed.
  censor_at_disenrollment = as.logical(Sys.getenv("CENSOR_AT_DISENROLLMENT", unset = "FALSE")),

  # ---- Code lists ----
  codelist_dir = Sys.getenv("CODELIST_DIR", unset = "/mnt/code/codelist"),

  persist_to_schema = as.logical(Sys.getenv("PERSIST_TO_SCHEMA", unset = "TRUE")),
  output_dir        = Sys.getenv("OUTPUT_DIR", unset = "/mnt/artifacts/results"),

  # ---- Retry ----
  max_retries = 4,
  base_sleep  = 5
)

run_id <- Sys.getenv("DOMINO_RUN_ID", unset = format(Sys.time(), "%Y%m%d%H%M%S"))
