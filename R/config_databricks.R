#' Databricks/Domino Configuration for Attrition Cohort Pipeline
#'
#' Configuration management for running the attrition cohort build
#' on Databricks via ODBC in Domino environment.

#' Create configuration for Databricks/Domino environment
#'
#' @param env Environment name: "dev", "test", "prod", or custom
#' @return Configuration list
#' @export
create_databricks_config <- function(env = "dev") {
  # Base configuration
  config <- list(
    env = env,

    # ========================================================================
    # DATABASE CONNECTION (ODBC -> Databricks)
    # ========================================================================
    db = list(
      # Option 1: DSN-based (recommended for Domino)
      # Set DSN in Domino environment or odbc.ini
      dsn = Sys.getenv("DATABRICKS_DSN", ""),

      # Option 2: DSN-less connection parameters
      driver = "Databricks",
      host = Sys.getenv("DATABRICKS_HOST", ""),
      port = 443,
      http_path = Sys.getenv("DATABRICKS_HTTP_PATH", ""),
      uid = "token",
      pwd = Sys.getenv("DATABRICKS_TOKEN", ""),
      auth_mech = 3,
      timeout = 120,

      # Schema configuration
      catalog = Sys.getenv("DATABRICKS_CATALOG", ""),
      cdm_schema = "optum_cdm_2025q2",
      work_schema = "gsk_mm_lot_work",
      ref_schema = "gsk_mm_lot_ref"
    ),

    # ========================================================================
    # OPTUM CLINFORMATICS TABLE MAPPINGS
    # ========================================================================
    tables = list(
      # Source CDM tables (Optum Clinformatics)
      tbl_member_elig = "member_continuous_enrollment",
      tbl_medical = "medical",
      tbl_med_diag = "medical_diagnosis",
      tbl_rx = "rx",

      # Reference/code list tables (load from spec tabs)
      cl_mm_dx = "cl_mm_dx",
      cl_diagnostic_proc = "cl_diagnostic_proc",
      cl_mm_therapy = "cl_mm_therapy",
      cl_preg = "cl_pregnancy",
      cl_clintrial = "cl_clintrial",
      cl_other_malig = "cl_other_malignancies"
    ),

    # ========================================================================
    # STUDY PARAMETERS (from DataPrep/StudyPop spec dated 19 Jan 2026)
    # ========================================================================
    study = list(
      # Study periods
      study_start = "2015-07-01",
      study_end = "2025-06-30",
      id_start = "2016-01-01",
      id_end = "2025-06-30",

      # Enrollment parameters
      baseline_days = 183,        # 6 months
      gap_days = 30,              # Allowable enrollment gap

      # Diagnosis windows for outpatient claims
      dx_window_30 = 30,
      dx_window_60 = 60,
      dx_window_90 = 90,
      primary_window = 90,

      # Therapy assumptions
      med_days_supply_assumption = 28
    ),

    # ========================================================================
    # INCLUSION/EXCLUSION CRITERIA TOGGLES
    # ========================================================================
    criteria = list(
      # Base requirement (always on)
      c0_mm_diagnosis = list(enabled = TRUE, modifiable = FALSE),

      # Criterion 1: Inpatient OR 2 outpatient within window
      c1_mm_dx_strict = list(
        enabled = TRUE,
        outpatient_count = 2,
        window_days = 90
      ),

      # Criterion 2: Age >= 18
      c2_age = list(enabled = TRUE, min_age = 18),

      # Criterion 3: MM therapy in follow-up (inclusion)
      c3_therapy_fu = list(enabled = TRUE),

      # Criterion 4: No MM therapy in baseline (exclusion)
      c4_therapy_bl = list(enabled = TRUE),

      # Criterion 5: Baseline CE >= 6 months
      c5_ce_baseline = list(enabled = TRUE, months = 6),

      # Criterion 6: Follow-up CE >= 1 day
      c6_ce_followup = list(enabled = TRUE, days = 1),

      # Criterion 7: Other cancer (exclusion) - DISABLED by default
      c7_other_cancer = list(enabled = FALSE),

      # Criterion 8: Pregnancy (exclusion) - DISABLED by default
      c8_pregnancy = list(enabled = FALSE),

      # Criterion 9: Clinical trial (exclusion) - DISABLED by default
      c9_clinical_trial = list(enabled = FALSE)
    ),

    # ========================================================================
    # PIPELINE SETTINGS
    # ========================================================================
    pipeline = list(
      checkpoint_dir = Sys.getenv("CHECKPOINT_DIR", "/mnt/artifacts/checkpoints"),
      optimize_tables = TRUE,
      max_retries = 4,
      base_retry_delay = 2,
      log_level = "INFO"
    ),

    # ========================================================================
    # OUTPUT SETTINGS
    # ========================================================================
    output = list(
      results_dir = Sys.getenv("RESULTS_DIR", "/mnt/results"),
      export_format = "csv",
      generate_attrition_table = TRUE
    )
  )

  # Environment-specific overrides
  if (env == "prod") {
    config$db$work_schema <- "gsk_mm_lot_prod"
    config$pipeline$log_level <- "INFO"
  } else if (env == "test") {
    config$db$work_schema <- "gsk_mm_lot_test"
    config$pipeline$log_level <- "DEBUG"
  }

  # Validate configuration
  validate_databricks_config(config)

  config
}

#' Load configuration from YAML file
#'
#' @param config_file Path to YAML config file
#' @return Configuration list
#' @export
load_config_from_yaml <- function(config_file) {
  if (!requireNamespace("yaml", quietly = TRUE)) {
    stop("Package 'yaml' required. Install with: install.packages('yaml')")
  }

  if (!file.exists(config_file)) {
    stop(sprintf("Config file not found: %s", config_file))
  }

  config <- yaml::read_yaml(config_file)

  # Merge with defaults
  defaults <- create_databricks_config("custom")

  # Deep merge
  config <- merge_configs(defaults, config)

  validate_databricks_config(config)

  config
}

#' Deep merge two configuration lists
#' @keywords internal
merge_configs <- function(base, override) {
  for (name in names(override)) {
    if (is.list(override[[name]]) && is.list(base[[name]])) {
      base[[name]] <- merge_configs(base[[name]], override[[name]])
    } else {
      base[[name]] <- override[[name]]
    }
  }
  base
}

#' Validate Databricks configuration
#'
#' @param config Configuration list
#' @return TRUE if valid, throws error otherwise
#' @export
validate_databricks_config <- function(config) {
  errors <- character()

  # Check database connection
  has_dsn <- !is.null(config$db$dsn) && config$db$dsn != ""
  has_host <- !is.null(config$db$host) && config$db$host != ""

  if (!has_dsn && !has_host) {
    errors <- c(errors, "Database connection required: set DATABRICKS_DSN or DATABRICKS_HOST")
  }

  # Check required schemas
  if (is.null(config$db$cdm_schema) || config$db$cdm_schema == "") {
    errors <- c(errors, "CDM schema (db.cdm_schema) is required")
  }

  if (is.null(config$db$work_schema) || config$db$work_schema == "") {
    errors <- c(errors, "Work schema (db.work_schema) is required")
  }

  # Check study dates
  if (is.na(as.Date(config$study$study_start, optional = TRUE))) {
    errors <- c(errors, "Invalid study_start date format")
  }

  if (is.na(as.Date(config$study$study_end, optional = TRUE))) {
    errors <- c(errors, "Invalid study_end date format")
  }

  if (length(errors) > 0) {
    stop(paste("Configuration validation failed:\n",
               paste("-", errors, collapse = "\n")))
  }

  TRUE
}

#' Print configuration summary
#' @export
print_databricks_config <- function(config) {
  cat("\n")
  cat("=" %rep% 60, "\n")
  cat("ATTRITION COHORT PIPELINE CONFIGURATION\n")
  cat("=" %rep% 60, "\n\n")

  cat("ENVIRONMENT:", config$env, "\n\n")

  cat("DATABASE CONNECTION:\n")
  if (config$db$dsn != "") {
    cat("  DSN:", config$db$dsn, "\n")
  } else {
    cat("  Host:", config$db$host, "\n")
    cat("  HTTP Path:", config$db$http_path, "\n")
  }
  cat("  Catalog:", config$db$catalog %||% "(default)", "\n")
  cat("  CDM Schema:", config$db$cdm_schema, "\n")
  cat("  Work Schema:", config$db$work_schema, "\n")
  cat("  Ref Schema:", config$db$ref_schema, "\n\n")

  cat("STUDY PARAMETERS:\n")
  cat("  Study Period:", config$study$study_start, "to", config$study$study_end, "\n")
  cat("  ID Period:", config$study$id_start, "to", config$study$id_end, "\n")
  cat("  Baseline Days:", config$study$baseline_days, "\n")
  cat("  Gap Days:", config$study$gap_days, "\n")
  cat("  Primary DX Window:", config$study$primary_window, "days\n\n")

  cat("CRITERIA (Enabled):\n")
  for (name in names(config$criteria)) {
    crit <- config$criteria[[name]]
    if (crit$enabled) {
      cat("  [x]", name, "\n")
    } else {
      cat("  [ ]", name, "\n")
    }
  }

  cat("\nPIPELINE SETTINGS:\n")
  cat("  Checkpoint Dir:", config$pipeline$checkpoint_dir, "\n")
  cat("  Optimize Tables:", config$pipeline$optimize_tables, "\n")
  cat("  Max Retries:", config$pipeline$max_retries, "\n")

  cat("\n", "=" %rep% 60, "\n")
}

#' Helper: repeat string
#' @keywords internal
`%rep%` <- function(x, n) paste(rep(x, n), collapse = "")

#' Null coalescing
#' @keywords internal
`%||%` <- function(x, y) if (is.null(x) || is.na(x) || x == "") y else x

#' Update specific configuration values
#'
#' @param config Configuration list
#' @param ... Named arguments to update (use dot notation: "db.work_schema")
#' @return Updated configuration
#' @export
update_config <- function(config, ...) {
  updates <- list(...)

  for (path in names(updates)) {
    parts <- strsplit(path, "\\.")[[1]]
    value <- updates[[path]]

    # Navigate to the correct nested level
    if (length(parts) == 1) {
      config[[parts[1]]] <- value
    } else if (length(parts) == 2) {
      config[[parts[1]]][[parts[2]]] <- value
    } else if (length(parts) == 3) {
      config[[parts[1]]][[parts[2]]][[parts[3]]] <- value
    }
  }

  config
}
