# Settings for the NDMM cohort build. Values come from config.csv; the
# environment wins over it. build_nndm.R checks them against CONTRACT before
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

  use_quarterly_tables = as.logical(Sys.getenv("USE_QUARTERLY_TABLES", unset = "TRUE")),
  study_end            = Sys.getenv("STUDY_END", unset = "2025-06-30"),

  # The 1L eligible-treatment period opens here (protocol S6.2.1.1).
  lot1_from     = Sys.getenv("LOT1_FROM", unset = "2017-01-01"),
  # 12 months of CE and of baseline before the 1L index date.
  pre_lot1_days = as.integer(Sys.getenv("PRE_LOT1_DAYS", unset = "365")),
  # Days after index a no-gap span must cover. Zero is the index date itself -
  # one day - confirmed by the study team for 1L, overriding the protocol's
  # three months. The 2L/3L cohorts keep three months; see README.
  fu_ce_days    = as.integer(Sys.getenv("FU_CE_DAYS", unset = "0")),
  # Gaps of this many days or fewer still count as continuous enrollment.
  gap_days      = as.integer(Sys.getenv("GAP_DAYS", unset = "30")),

  codelist_dir = Sys.getenv("CODELIST_DIR", unset = "/mnt/code/codelist"),
  output_dir   = Sys.getenv("OUTPUT_DIR", unset = "/mnt/artifacts/results"),

  max_retries = 4,
  base_sleep  = 5
)

run_id <- Sys.getenv("DOMINO_RUN_ID", unset = format(Sys.time(), "%Y%m%d%H%M%S"))
