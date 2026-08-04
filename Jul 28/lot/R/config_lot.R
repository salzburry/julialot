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
  # The study window this run covers, and the default for it. build_lot() takes
  # it as an argument, so these are what a run uses when none is passed.
  #
  # LOT bounds every claim scan by the cohort's own INDEX_DATE and OBS_END_DT
  # rather than by these dates, so they do not filter anything directly - what
  # they do is say which data this build is entitled to see, and study_end also
  # picks the quarterly CDM tables. A cohort built to a wider window than these
  # would have its follow-up silently truncated at the vintage;
  # check_cohort_window() stops instead.
  #
  # These dates are the study period of the cohort this build is usually run
  # for. Another cohort passes its own window - nothing here has to change.
  study_start          = Sys.getenv("STUDY_START", unset = "2016-01-01"),
  study_end            = Sys.getenv("STUDY_END", unset = "2026-03-31"),

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
  # How belantamab is spelled in MED_ABBR, for the line criterion in
  # line_criteria.R. Same abbreviation the cohort build uses on
  # cl_mma_codelist.csv.
  belantamab_med_abbr = toupper(trimws(Sys.getenv("BELANTAMAB_MED_ABBR", unset = "BELA"))),

  # What the cohort build calls its run-status table, before the prefix. Empty
  # means try the names the cohort builds in this folder use. The check refuses
  # a cohort whose own build did not finish - and refuses the run outright if
  # this names a table that cannot be read.
  cohort_status_table = trimws(Sys.getenv("COHORT_STATUS_TABLE", unset = "")),
  # Stop the build when a face-validity check falls outside its band. Off by
  # default: those bands are plausibility judgements, and an unusual cohort can
  # fail one legitimately. The values are recorded either way.
  face_validity_fatal = as.logical(Sys.getenv("FACE_VALIDITY_FATAL", unset = "FALSE")),
  # The cohort build's prefix, for that table. Defaults to this run's own -
  # one study, one prefix - so it is only set when the two differ.
  cohort_prefix       = trimws(Sys.getenv("COHORT_PREFIX", unset = "")),

  # ---- Observation end ----
  # FALSE (primary): OBS_END_DT = ENDDATE = min(death, study_end), so a
  # disenrolled patient keeps contributing follow-up.
  # TRUE (sensitivity): disenrollment caps observation too. ENDDATE_CE is kept
  # on lot_patient_input either way, so this flag is the only change needed.
  censor_at_disenrollment = as.logical(Sys.getenv("CENSOR_AT_DISENROLLMENT", unset = "FALSE")),

  # ---- The melphalan line-advancing rule (aug1_melp) ----
  # Blank is the contract build and the SQL is the same as without the rule.
  # A mode is a different algorithm, so it is pinned in CONTRACT and needs
  # LOT_CONTRACT_OVERRIDE - see R/melp_rule.R.
  apply_melp_rule    = Sys.getenv("APPLY_MELP_RULE",    unset = ""),
  melp_med_abbr      = Sys.getenv("MELP_MED_ABBR",      unset = "MELP"),
  melp_exposure_days = as.integer(Sys.getenv("MELP_EXPOSURE_DAYS", unset = "30")),
  melp_restart_days  = as.integer(Sys.getenv("MELP_RESTART_DAYS",  unset = "60")),
  melp_advance_days  = as.integer(Sys.getenv("MELP_ADVANCE_DAYS",  unset = "180")),
  melp_sct_days      = as.integer(Sys.getenv("MELP_SCT_DAYS",      unset = "14")),

  # ---- Code lists ----
  codelist_dir = Sys.getenv("CODELIST_DIR", unset = "/mnt/code/codelist"),

  persist_to_schema = as.logical(Sys.getenv("PERSIST_TO_SCHEMA", unset = "TRUE")),
  output_dir        = Sys.getenv("OUTPUT_DIR", unset = "/mnt/artifacts/results"),

  # ---- Retry ----
  max_retries = 4,
  base_sleep  = 5
)

run_id <- Sys.getenv("DOMINO_RUN_ID", unset = format(Sys.time(), "%Y%m%d%H%M%S"))
