# ============================================================
# config_lot.R — Configuration for LOT Part 2 pipeline
# ============================================================
# Study/methodology parameters now live in configs/study.yaml.
# This file owns infrastructure / deployment defaults only and exposes
# build_cfg_lot() which merges YAML-resolved study values on top.
# ============================================================

suppressPackageStartupMessages({
  library(DBI)
  library(odbc)
  library(glue)
  library(dplyr)
})

# Source the YAML loader (sibling file in same R/ folder)
.config_lot_dir <- tryCatch(dirname(sys.frame(1)$ofile), error = function(e) NULL)
if (is.null(.config_lot_dir) || !nzchar(.config_lot_dir)) {
  .config_lot_dir <- getwd()
}
source(file.path(.config_lot_dir, "load_study_config.R"))

# ---- Infrastructure defaults (env-var driven) ----
.cfg_lot_infrastructure <- list(
  # Connection
  dsn = Sys.getenv("DATABRICKS_DSN", unset = "RWDE"),
  pwd = Sys.getenv("DATABRICKS_PWD", unset = ""),

  # Databricks catalog + schemas
  catalog     = Sys.getenv("DATABRICKS_CATALOG", unset = "hive_metastore"),
  cdm_schema  = Sys.getenv("OPTUM_CDM_SCHEMA", unset = "clnprw_optum"),
  work_schema = Sys.getenv("PROJECT_WORK_SCHEMA",
                           unset = Sys.getenv("DOMINO_USER_NAME", unset = "gsk_mm_lot_work")),

  # Clinformatics CDM base tables
  tbl_medical  = "medical",
  tbl_med_proc = "med_procedure",
  tbl_med_diag = "med_diagnosis",
  tbl_rx       = "rx",

  use_quarterly_tables = as.logical(Sys.getenv("USE_QUARTERLY_TABLES", unset = "TRUE")),

  # Cohort input (Part 1 output)
  input_cohort_table = Sys.getenv("INPUT_COHORT_TABLE", unset = "ELIG_COH_FINAL"),

  # Persist outputs
  persist_to_schema = as.logical(Sys.getenv("PERSIST_TO_SCHEMA", unset = "TRUE")),

  # Output directory for figures + resolved config
  output_dir = Sys.getenv("OUTPUT_DIR", unset = "/mnt/artifacts/results"),

  # Retry controls
  max_retries = 4,
  base_sleep  = 5,

  # Optional reporting flags
  generate_descriptives = as.logical(Sys.getenv("GENERATE_DESCRIPTIVES", unset = "TRUE")),
  build_dashboard       = as.logical(Sys.getenv("BUILD_DASHBOARD", unset = "TRUE")),
  run_cyclo_deepdive    = as.logical(Sys.getenv("RUN_CYCLO_DEEPDIVE", unset = "TRUE"))
)

# Build the full Part 2 cfg by merging infrastructure with the YAML-resolved
# study/LOT/codelist values. Always writes the resolved-config dump if
# output_dir is set (the dump filename embeds run_id).
build_cfg_lot <- function(yaml_path = "configs/study.yaml",
                          run_id     = format(Sys.time(), "%Y%m%d%H%M%S"),
                          output_dir = .cfg_lot_infrastructure$output_dir,
                          require_yaml = TRUE,
                          validate_codelist_files = TRUE) {
  res <- resolve_study_config(
    yaml_path  = yaml_path,
    run_id     = run_id,
    output_dir = output_dir,
    require_yaml = require_yaml,
    validate_codelist_files = validate_codelist_files
  )
  yaml_cfg <- res$cfg
  legacy <- list(
    study_end             = yaml_cfg$end,
    induction_window_days = as.integer(yaml_cfg$induction_window_days),
    map_discon_gap_days   = as.integer(yaml_cfg$map_discon_gap_days),
    lot_discon_gap_days   = as.integer(yaml_cfg$lot_discon_gap_days),
    medical_day_supply    = as.integer(yaml_cfg$medical_day_supply),
    cart_consolidation_days = as.integer(yaml_cfg$cart_consolidation_days),
    sct_auto_window_days  = as.integer(yaml_cfg$sct_auto_window_days),
    sct_auto_gap_days     = as.integer(yaml_cfg$sct_auto_gap_days),
    sct_tandem_days       = as.integer(yaml_cfg$sct_tandem_days),

    censor_at_disenrollment = as.logical(yaml_cfg$censor_at_disenrollment),

    outpatient_window = as.integer(yaml_cfg$outpatient_window),
    codelist_dir      = yaml_cfg$codelist_dir
  )
  cfg <- utils::modifyList(.cfg_lot_infrastructure, legacy, keep.null = FALSE)
  list(cfg = cfg, resolution = res)
}

# Module-level cfg seeded with infrastructure only. lot_program.R:main()
# calls build_cfg_lot() and reassigns the parent-env `cfg` to the merged
# config so the rest of the pipeline (which uses `cfg` as a global) sees
# the full study + infrastructure picture.
cfg <- .cfg_lot_infrastructure
run_id <- Sys.getenv("DOMINO_RUN_ID", unset = format(Sys.time(), "%Y%m%d%H%M%S"))
