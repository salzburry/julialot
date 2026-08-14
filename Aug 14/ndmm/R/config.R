# Settings for the NDMM cohort build. Values come from config.csv; the
# environment wins over it. build_ndmm.R checks them against CONTRACT before
# anything runs. The cohort prefix is not here - the caller passes it.

cfg_defaults <- list(
  dsn = Sys.getenv("DATABRICKS_DSN", unset = "RWDE"),
  pwd = Sys.getenv("DATABRICKS_PWD", unset = ""),

  catalog    = Sys.getenv("DATABRICKS_CATALOG", unset = "hive_metastore"),
  cdm_schema = Sys.getenv("OPTUM_CDM_SCHEMA", unset = "clnprw_optum"),
  # pin_output_schema() sets this before the build reads it. Blank here so a
  # build that skipped that step stops instead of writing somewhere shared.
  work_schema   = "",
  object_prefix = Sys.getenv("OBJECT_PREFIX", unset = ""),

  tbl_medical     = "medical",
  tbl_med_proc    = "med_procedure",
  tbl_med_diag    = "med_diagnosis",
  tbl_rx          = "rx",
  tbl_confinement = Sys.getenv("TBL_CONFINEMENT", unset = "confinement"),
  # Read by both enrollment-span builds, so it is the first raw table the run
  # touches. Same environment variable ndmm_constants.R uses for it.
  tbl_member_enroll = Sys.getenv("TBL_MEMBER_ENROLLMENT", unset = "member_enrollment"),

  # Read by the demographics step: sex and birth year, and date of death.
  tbl_member_elig = Sys.getenv("TBL_MEMBER_ELIG", unset = "member_cont_enrollment"),
  tbl_dod         = Sys.getenv("TBL_DOD", unset = "dod"),

  # Two outpatient MM claims within this many days confirm a diagnosis, and the
  # minimum age at that diagnosis.
  outpatient_window = as.integer(Sys.getenv("OUTPATIENT_WINDOW", unset = "90")),
  min_age           = as.integer(Sys.getenv("MIN_AGE", unset = "18")),
  # How belantamab is spelled in cl_mma_codelist.csv; see
  # standalone_constants.R. Pinned because a criterion turns on it.
  belantamab_abbr   = Sys.getenv("NDMM_BELANTAMAB_ABBR", unset = "BELA"),
  # Agents barred from setting the 1L index beyond belantamab. Empty unless the
  # study team names one; see standalone_constants.R and NDMM_INDEX_AGENTS.
  index_excluded_abbrs = Sys.getenv("NDMM_INDEX_EXCLUDED_ABBRS", unset = ""),
  # The same, by HCPCS or NDC rather than by the code list's own abbreviation.
  index_excluded_codes = Sys.getenv("NDMM_INDEX_EXCLUDED_CODES", unset = ""),
  # Whether a plasma-cell disorder in remission still excludes as another
  # cancer; see standalone_constants.R and NDMM_MM_ADJACENT_GROUPS.
  mm_adjacent_states = Sys.getenv("NDMM_MM_ADJACENT_STATES", unset = "override"),

  use_quarterly_tables = as.logical(Sys.getenv("USE_QUARTERLY_TABLES", unset = "TRUE")),
  study_end            = Sys.getenv("STUDY_END", unset = "2026-03-31"),

  # Earliest date an eligible 1L treatment can count.
  lot1_from     = Sys.getenv("LOT1_FROM", unset = "2017-01-01"),
  # 12 months of CE and of baseline before the 1L index date.
  pre_lot1_days = as.integer(Sys.getenv("PRE_LOT1_DAYS", unset = "365")),
  # Days after index a no-gap span must cover. Zero means the index date
  # itself - one day - confirmed by the study team. Other cohorts use three
  # months; see README.
  fu_ce_days    = as.integer(Sys.getenv("FU_CE_DAYS", unset = "0")),
  # Gaps of this many days or fewer still count as continuous enrollment.
  gap_days      = as.integer(Sys.getenv("GAP_DAYS", unset = "30")),
  # The steps read NDMM_STUDY_START, not this. It is here so check_constants()
  # has something to compare the constant against - same variable, same
  # default, so a config.csv that goes missing stops the build rather than
  # silently widening the pregnancy and MM-diagnosis scans.
  study_start   = Sys.getenv("STUDY_START", unset = "2016-01-01"),

  codelist_dir = Sys.getenv("CODELIST_DIR", unset = "/mnt/code/codelist"),
  output_dir   = Sys.getenv("OUTPUT_DIR", unset = "/mnt/artifacts/results"),

  max_retries = 4,
  base_sleep  = 5
)

run_id <- Sys.getenv("DOMINO_RUN_ID", unset = format(Sys.time(), "%Y%m%d%H%M%S"))
