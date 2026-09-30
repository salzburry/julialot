# Settings for the NDMM cohort build on MDV. Values come from config.csv; the
# environment wins over it. build_ndmm.R checks them against CONTRACT before
# anything runs. The cohort prefix is not here - the caller passes it.
#
# The MDV table and column names are not here either: they are in
# R/mdv_source.R, which both this package and the LOT engine read.

cfg_defaults <- list(
  dsn = Sys.getenv("DATABRICKS_DSN", unset = "RWDE"),
  pwd = Sys.getenv("DATABRICKS_PWD", unset = ""),

  catalog    = Sys.getenv("DATABRICKS_CATALOG", unset = "hive_metastore"),
  # Called cdm_schema so R/mdv_source.R reads one name in both packages.
  cdm_schema = Sys.getenv("MDV_SCHEMA", unset = "clnprw_mdv_all_use"),
  # pin_output_schema() sets this before the build reads it. Blank here so a
  # build that skipped that step stops instead of writing somewhere shared.
  work_schema   = "",
  object_prefix = Sys.getenv("OBJECT_PREFIX", unset = ""),

  # Two outpatient MM diagnosis months at most this many months apart confirm a
  # diagnosis, and the minimum age at that diagnosis.
  outpatient_window_months  = as.integer(Sys.getenv("OUTPATIENT_WINDOW_MONTHS", unset = "3")),
  other_malig_window_months = as.integer(Sys.getenv("OTHER_MALIG_WINDOW_MONTHS", unset = "1")),
  min_age                   = as.integer(Sys.getenv("MIN_AGE", unset = "18")),
  # How belantamab is spelled in cl_mma_codelist.csv; see
  # standalone_constants.R. Pinned because a criterion turns on it.
  belantamab_abbr   = Sys.getenv("NDMM_BELANTAMAB_ABBR", unset = "BELA"),
  # Agents barred from setting the 1L index beyond belantamab. Empty unless the
  # study team names one; see standalone_constants.R and NDMM_INDEX_AGENTS.
  index_excluded_abbrs = Sys.getenv("NDMM_INDEX_EXCLUDED_ABBRS", unset = ""),
  # The same, by receipt code or name pattern rather than by abbreviation.
  index_excluded_codes = Sys.getenv("NDMM_INDEX_EXCLUDED_CODES", unset = ""),
  # Whether a plasma-cell disorder in remission still excludes as another
  # cancer; see standalone_constants.R and NDMM_MM_ADJACENT_GROUPS.
  mm_adjacent_states = Sys.getenv("NDMM_MM_ADJACENT_STATES", unset = "override"),
  # What makes an MDV diagnosis record an inpatient one, for criterion 1. See
  # standalone_constants.R.
  mdv_ip_rule        = Sys.getenv("NDMM_MDV_IP_RULE", unset = "none"),
  # Whether the MM and other-cancer diagnoses must carry MDV's cancer flag.
  mdv_require_cancerflg = as.logical(Sys.getenv("NDMM_MDV_REQUIRE_CANCERFLG",
                                                unset = "TRUE")),

  use_quarterly_tables = as.logical(Sys.getenv("USE_QUARTERLY_TABLES", unset = "TRUE")),
  mdv_vintage          = Sys.getenv("MDV_VINTAGE", unset = "2026q2"),
  study_end            = Sys.getenv("STUDY_END", unset = "2026-03-31"),

  # Earliest date an eligible 1L treatment can count.
  lot1_from     = Sys.getenv("LOT1_FROM", unset = "2019-01-01"),
  # 12 months of lookback and of baseline before the 1L index date.
  pre_lot1_days = as.integer(Sys.getenv("PRE_LOT1_DAYS", unset = "365")),
  # Days after index the patient must still be observed. Zero means the index
  # date itself - one day - as the study team confirmed for the Optum cohort.
  fu_ce_days    = as.integer(Sys.getenv("FU_CE_DAYS", unset = "0")),
  # The steps read NDMM_STUDY_START, not this. It is here so check_constants()
  # has something to compare the constant against.
  study_start   = Sys.getenv("STUDY_START", unset = "2018-01-01"),

  codelist_dir = Sys.getenv("CODELIST_DIR", unset = "/mnt/code/codelist_mdv"),
  output_dir   = Sys.getenv("OUTPUT_DIR", unset = "/mnt/artifacts/results"),

  max_retries = 4,
  base_sleep  = 5
)

run_id <- Sys.getenv("DOMINO_RUN_ID", unset = format(Sys.time(), "%Y%m%d%H%M%S"))
