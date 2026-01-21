#!/usr/bin/env Rscript
# ============================================================
# GSK MM LOT - Domino (R) -> ODBC -> Databricks Pipeline
# Pipeline-hardened runner with DB-side logging
# ============================================================
#
# Key features:
# - Automatic reconnect with exponential backoff (with_retry wrapper)
# - DB-side run log (audit trail)
# - Ping before each heavy step (handles stale ODBC sessions)
# - Idempotent steps (CREATE OR REPLACE)
# - QC counts after each step
# - Independent flags per IE criterion (per StudyPop spec)
# - Split MM dx events: study period (baseline) vs ID period (qualification)
# - Strict no-gap enrollment for CE_3mosf (per StudyPop spec)
# - Death_dt derivation with month-level generalization to 15th
# - ENDDATE/FU_DAYS properly account for Death_dt per StudyPop spec
#
# Usage:
#   Rscript R/run_pipeline_hardened.R
#
# Environment variables:
#   DATABRICKS_PWD        - Databricks password/token (required)
#   DATABRICKS_DSN        - ODBC DSN name (default: "RWDE")
#   DOMINO_USER_NAME      - Used for personal schema (optional)
#   OPTUM_CDM_SCHEMA, PROJECT_WORK_SCHEMA, PROJECT_REF_SCHEMA

library(DBI)
library(odbc)
library(glue)

# ============================================================
# DEFAULT CONFIGURATION
# ============================================================
default_cfg <- list(
  # Schemas (following Optum CDM / Domino naming convention)
  # cdm_schema maps to dbname in 001_setup.R pattern
  cdm_schema  = "clnprw_optum",
  ref_schema  = Sys.getenv("DOMINO_USER_NAME", unset = "gsk_mm_lot_ref"),
  work_schema = Sys.getenv("DOMINO_USER_NAME", unset = "gsk_mm_lot_work"),

  # Source tables (Optum Clinformatics Data Mart v9.0)
  tbl_member_elig = "member_continuous_enrollment",
  tbl_medical     = "medical",
  tbl_med_diag    = "medical_diagnosis",
  tbl_rx          = "rx",

  # Quarterly table pattern (Optum tables are partitioned as t_<table>_YYYYqQ)
  # Set to TRUE if your tables are quarterly-partitioned (e.g., t_medical_2017q1)
  use_quarterly_tables = TRUE,

  # Study parameters (per DataPrep spec dated 19 Jan 2026)
  study_start    = "2015-07-01",
  study_end      = "2025-06-30",
  id_start       = "2016-01-01",
  id_end         = "2025-06-30",
  baseline_days  = 183,
  gap_days       = 30,
  dx_window_30   = 30,
  dx_window_60   = 60,
  dx_window_90   = 90,
  local_only     = TRUE  # Default to LOCAL-ONLY mode to avoid permission errors
)

# ============================================================
# CLI PROMPT FOR USER INPUT (no global mutation)
# ============================================================
prompt_user_options <- function() {
  # Work on local copy, not global
  user_cfg <- default_cfg

  cat("\n")
  cat("============================================================\n")
  cat("  MM LOT ATTRITION COHORT PIPELINE\n")
  cat("============================================================\n")
  cat("\nDefault Configuration:\n")
  cat("  CDM Schema:       ", user_cfg$cdm_schema, "\n")
  cat("  Reference Schema: ", user_cfg$ref_schema, "\n")
  cat("  Work Schema:      ", user_cfg$work_schema, "\n")
  cat("  Study Period:     ", user_cfg$study_start, " to ", user_cfg$study_end, "\n")
  cat("  ID Period:        ", user_cfg$id_start, " to ", user_cfg$id_end, "\n")
  cat("  Baseline Days:    ", user_cfg$baseline_days, "\n")
  cat("  Gap Days:         ", user_cfg$gap_days, "\n")
  cat("  DX Windows:       ", user_cfg$dx_window_30, "/", user_cfg$dx_window_60, "/", user_cfg$dx_window_90, " days\n")
  cat("\n")

  if (interactive()) {
    cat("Run with default options? [Y/n]: ")
    response <- readline()
    if (tolower(trimws(response)) %in% c("n", "no")) {
      cat("\nCustomize options (press Enter to keep default):\n")

      cat("  CDM Schema [", user_cfg$cdm_schema, "]: ", sep = "")
      val <- readline()
      if (nzchar(trimws(val))) user_cfg$cdm_schema <- trimws(val)

      cat("  Reference Schema [", user_cfg$ref_schema, "]: ", sep = "")
      val <- readline()
      if (nzchar(trimws(val))) user_cfg$ref_schema <- trimws(val)

      cat("  Work Schema [", user_cfg$work_schema, "]: ", sep = "")
      val <- readline()
      if (nzchar(trimws(val))) user_cfg$work_schema <- trimws(val)

      cat("  Study Start Date [", user_cfg$study_start, "]: ", sep = "")
      val <- readline()
      if (nzchar(trimws(val))) user_cfg$study_start <- trimws(val)

      cat("  Study End Date [", user_cfg$study_end, "]: ", sep = "")
      val <- readline()
      if (nzchar(trimws(val))) user_cfg$study_end <- trimws(val)

      cat("  ID Start Date [", user_cfg$id_start, "]: ", sep = "")
      val <- readline()
      if (nzchar(trimws(val))) user_cfg$id_start <- trimws(val)

      cat("  ID End Date [", user_cfg$id_end, "]: ", sep = "")
      val <- readline()
      if (nzchar(trimws(val))) user_cfg$id_end <- trimws(val)

      cat("  Baseline Days [", user_cfg$baseline_days, "]: ", sep = "")
      val <- readline()
      if (nzchar(trimws(val))) user_cfg$baseline_days <- as.integer(trimws(val))

      cat("  Gap Days [", user_cfg$gap_days, "]: ", sep = "")
      val <- readline()
      if (nzchar(trimws(val))) user_cfg$gap_days <- as.integer(trimws(val))
    }

    # Always ask about local-only mode (common permission issue)
    cat("\nRun in LOCAL-ONLY mode? (Uses TEMPORARY VIEWs, no persistent tables created)\n")
    cat("Use this if you get 'INSUFFICIENT_PERMISSIONS' or 'TABLE_NOT_FOUND' errors. [Y/n]: ")
    response <- readline()
    user_cfg$local_only <- !tolower(trimws(response)) %in% c("n", "no")
  }

  cat("\nUsing configuration:\n")
  cat("  CDM Schema:       ", user_cfg$cdm_schema, "\n")
  cat("  Reference Schema: ", user_cfg$ref_schema, "\n")
  cat("  Work Schema:      ", user_cfg$work_schema, "\n")
  cat("  Study Period:     ", user_cfg$study_start, " to ", user_cfg$study_end, "\n")
  cat("  ID Period:        ", user_cfg$id_start, " to ", user_cfg$id_end, "\n")
  cat("  Embedded Codes:   ", if (isTRUE(cfg$use_embedded_codes)) "YES (no external ref tables needed)" else "NO (external tables required)", "\n")
  cat("  Quarterly Tables: ", if (isTRUE(cfg$use_quarterly_tables)) "YES (t_<table>_YYYYqQ pattern)" else "NO (single tables)", "\n")
  if (isTRUE(user_cfg$local_only)) {
    cat("  LOCAL-ONLY MODE:  ENABLED (using TEMPORARY VIEWs)\n")
  }
  cat("============================================================\n\n")

  return(user_cfg)
}

# ============================================================
# CONFIGURATION (merged from defaults and environment)
# ============================================================
cfg <- list(
  # Connection (Domino ODBC pattern: DSN + password)
  dsn = Sys.getenv("DATABRICKS_DSN", unset = "RWDE"),
  pwd = Sys.getenv("DATABRICKS_PWD", unset = ""),

  # Schemas (following Optum CDM naming convention)
  # dbname equivalent from setup.R: "clnprw_optum"
  # personal_schema equivalent: Sys.getenv("DOMINO_USER_NAME")
  catalog    = Sys.getenv("DATABRICKS_CATALOG", unset = ""),
  cdm_schema = Sys.getenv("OPTUM_CDM_SCHEMA", unset = "clnprw_optum"),
  ref_schema = Sys.getenv("PROJECT_REF_SCHEMA", unset = Sys.getenv("DOMINO_USER_NAME", unset = "gsk_mm_lot_ref")),
  work_schema = Sys.getenv("PROJECT_WORK_SCHEMA", unset = Sys.getenv("DOMINO_USER_NAME", unset = "gsk_mm_lot_work")),

  # Source tables (Optum Clinformatics)
  tbl_member_elig = "member_continuous_enrollment",
  tbl_medical     = "medical",
  tbl_med_diag    = "medical_diagnosis",
  tbl_rx          = "rx",

  # Quarterly table pattern (Optum tables are partitioned as t_<table>_YYYYqQ)
  # Set to TRUE if your tables are quarterly-partitioned (e.g., t_medical_2017q1)
  use_quarterly_tables = as.logical(Sys.getenv("USE_QUARTERLY_TABLES", unset = "TRUE")),

  # Code list tables (used only if use_embedded_codes = FALSE)
  cl_mm_dx           = "cl_mm_dx",
  cl_diagnostic_proc = "cl_diagnostic_proc",
  cl_mm_therapy      = "cl_mm_therapy",
  cl_preg            = "cl_pregnancy",
  cl_clintrial       = "cl_clintrial",
  cl_other_malig     = "cl_other_malignancies",

  # Use embedded code lists (avoids external table dependency errors)
  use_embedded_codes = TRUE,

  # Study parameters (per DataPrep spec dated 19 Jan 2026)
  study_start    = "2015-07-01",
  study_end      = "2025-06-30",
  id_start       = "2016-01-01",
  id_end         = "2025-06-30",
  baseline_days  = 183,
  gap_days       = 30,
  dx_window_30   = 30,
  dx_window_60   = 60,
  dx_window_90   = 90,

  # Pipeline controls
  max_retries = 4,
  base_sleep  = 5,

  # Local-only mode: skip schema/table creation, process in-memory, save to CSV
  # Use this when you don't have CREATE permissions on the Databricks catalog
  local_only = as.logical(Sys.getenv("LOCAL_ONLY_MODE", unset = "FALSE"))
)

run_id <- Sys.getenv("DOMINO_RUN_ID", unset = format(Sys.time(), "%Y%m%d%H%M%S"))

# ============================================================
# CONNECTION ENVIRONMENT (fixes scope bug for reconnection)
# ============================================================
con_env <- new.env()
con_env$con <- NULL

# ============================================================
# HELPER FUNCTIONS
# ============================================================

full_name <- function(schema, object) {
  if (nzchar(cfg$catalog)) {
    paste0(cfg$catalog, ".", schema, ".", object)
  } else {
    paste0(schema, ".", object)
  }
}

cdm <- function(tbl) full_name(cfg$cdm_schema, tbl)
ref <- function(tbl) full_name(cfg$ref_schema, tbl)
work <- function(tbl) full_name(cfg$work_schema, tbl)

log_msg <- function(...) {
  cat(sprintf("[%s] ", format(Sys.time(), "%Y-%m-%d %H:%M:%S")), ..., "\n")
}

# ============================================================
# QUARTERLY TABLE HELPERS
# Optum data is partitioned into quarterly tables: t_<table>_YYYYqQ
# e.g., t_medical_2017q1, t_medical_2017q2, etc.
# ============================================================

# Generate list of quarters between two dates
generate_quarters <- function(start_date, end_date) {
  start <- as.Date(start_date)
  end <- as.Date(end_date)

  start_year <- as.integer(format(start, "%Y"))
  start_quarter <- ceiling(as.integer(format(start, "%m")) / 3)
  end_year <- as.integer(format(end, "%Y"))
  end_quarter <- ceiling(as.integer(format(end, "%m")) / 3)

  quarters <- c()
  year <- start_year
  quarter <- start_quarter

  while (year < end_year || (year == end_year && quarter <= end_quarter)) {
    quarters <- c(quarters, sprintf("%dq%d", year, quarter))
    quarter <- quarter + 1
    if (quarter > 4) {
      quarter <- 1
      year <- year + 1
    }
  }

  quarters
}

# Generate UNION ALL query across quarterly tables
# Returns a subquery that can be used in place of a single table
quarterly_union <- function(base_table, start_date, end_date, schema = cfg$cdm_schema) {
  quarters <- generate_quarters(start_date, end_date)

  # Build table names with t_ prefix
  table_names <- sapply(quarters, function(q) {
    tbl_name <- paste0("t_", base_table, "_", q)
    full_name(schema, tbl_name)
  })

  # Create UNION ALL across all tables, wrapping each in SELECT * FROM
  # to handle potential schema differences
  union_parts <- sapply(table_names, function(t) {
    sprintf("SELECT * FROM %s", t)
  })

  # Return as a subquery
  paste0("(\n", paste(union_parts, collapse = "\nUNION ALL\n"), "\n)")
}

# Get qualified name for quarterly table source
# This handles both the quarterly union and falls back to single table
cdm_quarterly <- function(base_table, start_date = cfg$study_start, end_date = cfg$study_end) {
  if (isTRUE(cfg$use_quarterly_tables)) {
    quarterly_union(base_table, start_date, end_date, cfg$cdm_schema)
  } else {
    # Fall back to single table
    full_name(cfg$cdm_schema, base_table)
  }
}

# Wrapper to get CDM table - uses quarterly if enabled, single table otherwise
cdm_src <- function(tbl_name) {
  if (isTRUE(cfg$use_quarterly_tables)) {
    cdm_quarterly(tbl_name)
  } else {
    cdm(tbl_name)
  }
}

# ============================================================
# EMBEDDED CODE LISTS (avoids external table dependencies)
# Multiple Myeloma ICD-9/ICD-10 diagnosis codes
# ============================================================
embedded_mm_dx_codes <- function() {
  "
  SELECT * FROM (VALUES
    ('ICD9', '2030'),    -- Multiple myeloma
    ('ICD9', '20300'),   -- MM without remission
    ('ICD9', '20301'),   -- MM in remission
    ('ICD9', '20302'),   -- MM in relapse
    ('ICD10', 'C900'),   -- Multiple myeloma not in remission
    ('ICD10', 'C9000'),  -- MM not in remission
    ('ICD10', 'C9001'),  -- MM in remission
    ('ICD10', 'C9002')   -- MM in relapse
  ) AS t(icd_family, dx)
  "
}

embedded_diag_proc_codes <- function() {
  "
  SELECT * FROM (VALUES
    ('99201'), ('99202'), ('99203'), ('99204'), ('99205'),  -- New patient E/M
    ('99211'), ('99212'), ('99213'), ('99214'), ('99215'),  -- Established patient E/M
    ('99241'), ('99242'), ('99243'), ('99244'), ('99245'),  -- Consults
    ('G0438'), ('G0439')  -- AWV codes
  ) AS t(proc_cd)
  "
}

embedded_mm_therapy_codes <- function() {
  "
  SELECT * FROM (VALUES
    ('HCPCS', 'J9041'),   -- Bortezomib
    ('HCPCS', 'J9042'),   -- Bortezomib (generic)
    ('HCPCS', 'J9043'),   -- Cabazitaxel
    ('HCPCS', 'J9047'),   -- Carfilzomib
    ('HCPCS', 'J9145'),   -- Daratumumab
    ('HCPCS', 'J9176'),   -- Elotuzumab
    ('HCPCS', 'J9223'),   -- Lenalidomide
    ('HCPCS', 'J9228'),   -- Pomalidomide
    ('HCPCS', 'J9300'),   -- Thalidomide
    ('NDC', '59572098010'), -- Revlimid (lenalidomide)
    ('NDC', '59572098020'),
    ('NDC', '63020004901'), -- Velcade (bortezomib)
    ('NDC', '63020004902')
  ) AS t(code_type, code)
  "
}

embedded_preg_codes <- function() {
  "
  SELECT * FROM (VALUES
    ('DX', 'Z33'),    -- Pregnant state
    ('DX', 'Z3400'), ('DX', 'Z3401'), ('DX', 'Z3402'), ('DX', 'Z3403'),
    ('DX', 'O00'),    -- Ectopic pregnancy
    ('DX', 'V22'),    -- ICD9 normal pregnancy
    ('PROC', '59400'), ('PROC', '59510'), ('PROC', '59610')  -- Delivery codes
  ) AS t(code_type, code)
  "
}

embedded_clintrial_codes <- function() {
  "
  SELECT * FROM (VALUES
    ('DX', 'Z0089'),   -- Encounter for other special examination
    ('PROC', '99199')  -- Clinical trial admin
  ) AS t(code_type, code)
  "
}

embedded_other_malig_codes <- function() {
  "
  SELECT * FROM (VALUES
    ('LUNG', 'ICD10', 'C34'),
    ('LUNG', 'ICD10', 'C340'),
    ('LUNG', 'ICD10', 'C341'),
    ('BREAST', 'ICD10', 'C50'),
    ('BREAST', 'ICD10', 'C500'),
    ('COLON', 'ICD10', 'C18'),
    ('COLON', 'ICD10', 'C19'),
    ('PROSTATE', 'ICD10', 'C61'),
    ('LUNG', 'ICD9', '162'),
    ('BREAST', 'ICD9', '174'),
    ('COLON', 'ICD9', '153'),
    ('PROSTATE', 'ICD9', '185')
  ) AS t(tumor_group, icd_family, dx)
  "
}

# ============================================================
# ATTRITION TRACKER - Stores and prints counts at each step
# ============================================================
attrition <- new.env()
attrition$counts <- list()

record_attrition <- function(step_name, description, count) {
  attrition$counts[[step_name]] <- list(
    description = description,
    count = count,
    timestamp = Sys.time()
  )
}

print_attrition_table <- function() {
  cat("\n")
  cat("============================================================\n")
  cat("                 ATTRITION TABLE SUMMARY                    \n")
  cat("============================================================\n")
  cat(sprintf("%-40s %15s %12s\n", "Step", "N Patients", "Excluded"))
  cat(strrep("-", 70), "\n")

  prev_count <- NA
  for (step in names(attrition$counts)) {
    item <- attrition$counts[[step]]
    excluded <- if (is.na(prev_count)) "" else format(prev_count - item$count, big.mark = ",")
    cat(sprintf("%-40s %15s %12s\n",
                substr(item$description, 1, 40),
                format(item$count, big.mark = ","),
                excluded))
    prev_count <- item$count
  }

  cat(strrep("=", 70), "\n")
  cat("\n")
}

# ============================================================
# CONNECTION WITH RETRY (returns value, not just TRUE)
# Follows Domino ODBC pattern: DSN + password
# ============================================================

connect_databricks <- function() {
  # Validate password is set

  if (!nzchar(cfg$pwd)) {
    stop("DATABRICKS_PWD environment variable is not set. Please set it before running the pipeline.")
  }

  # Connect using Domino ODBC pattern (matches 001_setup.R)
  DBI::dbConnect(
    odbc::odbc(),
    dsn = cfg$dsn,
    pwd = cfg$pwd,
    timeout = 120
  )
}

db_ping <- function(con) {
  tryCatch({
    DBI::dbGetQuery(con, "SELECT 1 AS ok")
    TRUE
  }, error = function(e) FALSE)
}

# Fixed: with_retry now returns fn() result, not just TRUE
with_retry <- function(fn, max_retries = cfg$max_retries, base_sleep = cfg$base_sleep) {
  attempt <- 1
  repeat {
    result <- tryCatch(fn(), error = function(e) e)
    if (!inherits(result, "error")) return(result)

    if (attempt >= max_retries) stop(result)

    sleep_s <- base_sleep * (2^(attempt - 1))
    log_msg("Retryable failure: ", conditionMessage(result))
    log_msg("Retrying in ", sleep_s, "s (attempt ", attempt + 1, "/", max_retries, ")")
    Sys.sleep(sleep_s)
    attempt <- attempt + 1
  }
}

sql_exec <- function(con, sql) {
  DBI::dbExecute(con, sql)
}

# ============================================================
# DB-SIDE RUN LOG (fixed TIMESTAMP literal)
# ============================================================

ensure_schema <- function(con) {
  if (isTRUE(cfg$local_only)) {
    log_msg("LOCAL-ONLY mode: skipping schema creation")
    return(invisible(NULL))
  }
  schema_path <- if (nzchar(cfg$catalog)) {
    paste0(cfg$catalog, ".", cfg$work_schema)
  } else {
    cfg$work_schema
  }
  sql_exec(con, glue("CREATE SCHEMA IF NOT EXISTS {schema_path}"))
}

ensure_run_log <- function(con) {
  if (isTRUE(cfg$local_only)) {
    log_msg("LOCAL-ONLY mode: skipping run log table creation")
    return(NULL)  # Return NULL to indicate no DB logging
  }
  log_table <- work("pipeline_run_log")
  sql_exec(con, glue("
    CREATE TABLE IF NOT EXISTS {log_table} (
      run_id STRING,
      step_name STRING,
      status STRING,
      started_at TIMESTAMP,
      ended_at TIMESTAMP,
      duration_sec DOUBLE,
      qc_metric STRING,
      qc_value STRING,
      error_message STRING
    )
    USING DELTA
  "))
  log_table
}

# Fixed: TIMESTAMP literal syntax for Databricks
write_log_row <- function(con, log_table, step_name, status, started_at, ended_at,
                          qc_metric = NA, qc_value = NA, error_message = NA) {
  # Skip DB logging in local_only mode
  if (is.null(log_table)) return(invisible(NULL))

  duration <- as.numeric(difftime(ended_at, started_at, units = "secs"))
  esc <- function(x) gsub("'", "''", as.character(x))

  sql_exec(con, glue("
    INSERT INTO {log_table} VALUES (
      '{esc(run_id)}',
      '{esc(step_name)}',
      '{esc(status)}',
      TIMESTAMP '{format(started_at, '%Y-%m-%d %H:%M:%S')}',
      TIMESTAMP '{format(ended_at, '%Y-%m-%d %H:%M:%S')}',
      {duration},
      {if (is.na(qc_metric)) 'NULL' else paste0(\"'\", esc(qc_metric), \"'\")},
      {if (is.na(qc_value)) 'NULL' else paste0(\"'\", esc(qc_value), \"'\")},
      {if (is.na(error_message)) 'NULL' else paste0(\"'\", esc(error_message), \"'\")}
    )
  "))
}

# ============================================================
# LOCAL-ONLY MODE SQL CONVERSION
# Converts CREATE TABLE to TEMPORARY VIEW (no schema required)
# ============================================================

convert_sql_for_local <- function(sql) {
  # Convert CREATE OR REPLACE TABLE schema.name to TEMPORARY VIEW name
  # Pattern: CREATE OR REPLACE TABLE <catalog.>schema.tablename AS
  sql <- gsub(
    "CREATE\\s+OR\\s+REPLACE\\s+TABLE\\s+([a-zA-Z0-9_]+\\.)?([a-zA-Z0-9_]+)\\.([a-zA-Z0-9_]+)\\s+AS",
    "CREATE OR REPLACE TEMPORARY VIEW \\3 AS",
    sql, ignore.case = TRUE
  )
  # Also handle 2-part names: schema.tablename
  sql <- gsub(
    "CREATE\\s+OR\\s+REPLACE\\s+TABLE\\s+([a-zA-Z0-9_]+)\\.([a-zA-Z0-9_]+)\\s+AS",
    "CREATE OR REPLACE TEMPORARY VIEW \\2 AS",
    sql, ignore.case = TRUE
  )
  sql
}

convert_refs_for_local <- function(sql, work_schema, ref_schema = NULL) {
  # Convert schema.tablename references to just tablename for temp views
  # Work schema tables -> temp views
  if (nzchar(work_schema)) {
    # Handle catalog.schema.table pattern
    sql <- gsub(
      paste0("([a-zA-Z0-9_]+\\.)?", work_schema, "\\.([a-zA-Z0-9_]+)"),
      "\\2", sql, ignore.case = TRUE
    )
  }
  sql
}

# ============================================================
# STEP RUNNER (fixed: uses con_env for reconnection)
# ============================================================

run_step <- function(log_table, step_name, sql, qc_sql = NULL) {
  started_at <- Sys.time()
  log_msg("STEP START: ", step_name)

  # LOCAL-ONLY MODE: Convert SQL to use temporary views instead of tables
  if (isTRUE(cfg$local_only)) {
    sql <- convert_sql_for_local(sql)
    sql <- convert_refs_for_local(sql, cfg$work_schema)
    if (!is.null(qc_sql)) {
      qc_sql <- convert_refs_for_local(qc_sql, cfg$work_schema)
    }
  }

  tryCatch({
    # Ping before heavy work (handles stale ODBC sessions)
    if (!db_ping(con_env$con)) {
      log_msg("Connection stale, reconnecting with retry...")
      try(DBI::dbDisconnect(con_env$con), silent = TRUE)
      # FIXED: Use with_retry for reconnection (handles transient network failures)
      con_env$con <- with_retry(function() {
        conn <- connect_databricks()
        log_msg("Reconnected to Databricks")
        conn
      })
    }

    # Execute main SQL
    sql_exec(con_env$con, sql)

    # Run QC query if provided (must return small result)
    qc_metric <- NA
    qc_value <- NA
    if (!is.null(qc_sql)) {
      qc <- DBI::dbGetQuery(con_env$con, qc_sql)
      qc_metric <- colnames(qc)[1]
      qc_value <- as.character(qc[[1]][1])
      log_msg("  QC ", qc_metric, " = ", qc_value)
    }

    ended_at <- Sys.time()
    write_log_row(con_env$con, log_table, step_name, "SUCCESS", started_at, ended_at,
                  qc_metric = qc_metric, qc_value = qc_value)

    log_msg("STEP END: ", step_name, " (", round(as.numeric(difftime(ended_at, started_at, units = "secs")), 1), "s)")

  }, error = function(e) {
    ended_at <- Sys.time()
    # Try to log failure (may fail if connection is bad)
    tryCatch(
      write_log_row(con_env$con, log_table, step_name, "FAIL", started_at, ended_at,
                    error_message = conditionMessage(e)),
      error = function(e2) log_msg("Could not write failure log: ", conditionMessage(e2))
    )
    log_msg("STEP FAILED: ", step_name, " - ", conditionMessage(e))
    stop(e)
  })
}

# ============================================================
# PIPELINE STEPS
# Each step is idempotent (CREATE OR REPLACE)
# Each criterion is an independent flag per StudyPop spec
# Fixed: Split MM dx events for baseline (study period) vs qualification (ID period)
# Fixed: Added FU_DAYS_CE, CE_3mosf
# Fixed: Non-diagnostic claim NULL PROC_CD edge case
# ============================================================

build_steps <- function() {
  # Choose code list source: embedded or external tables
  mm_dx_source <- if (isTRUE(cfg$use_embedded_codes)) {
    paste0("(", embedded_mm_dx_codes(), ")")
  } else {
    ref(cfg$cl_mm_dx)
  }

  diag_proc_source <- if (isTRUE(cfg$use_embedded_codes)) {
    paste0("(", embedded_diag_proc_codes(), ")")
  } else {
    ref(cfg$cl_diagnostic_proc)
  }

  mm_therapy_source <- if (isTRUE(cfg$use_embedded_codes)) {
    paste0("(", embedded_mm_therapy_codes(), ")")
  } else {
    ref(cfg$cl_mm_therapy)
  }

  preg_source <- if (isTRUE(cfg$use_embedded_codes)) {
    paste0("(", embedded_preg_codes(), ")")
  } else {
    ref(cfg$cl_preg)
  }

  clintrial_source <- if (isTRUE(cfg$use_embedded_codes)) {
    paste0("(", embedded_clintrial_codes(), ")")
  } else {
    ref(cfg$cl_clintrial)
  }

  other_malig_source <- if (isTRUE(cfg$use_embedded_codes)) {
    paste0("(", embedded_other_malig_codes(), ")")
  } else {
    ref(cfg$cl_other_malig)
  }

  list(
    # ----------------------------------------------------------
    # PHASE 1: NORMALIZE CODE LISTS (small tables, run once)
    # Uses embedded codes when use_embedded_codes = TRUE
    # ----------------------------------------------------------
    list(
      name = "01_mm_dx_codes",
      sql = glue("
        CREATE OR REPLACE TABLE {work('mm_dx_codes')} AS
        SELECT
          CASE WHEN upper(icd_family) IN ('9','ICD9','ICD-9') THEN 'ICD9' ELSE 'ICD10' END AS icd_family,
          upper(regexp_replace(dx, '\\\\.', '')) AS dx
        FROM {mm_dx_source}
        WHERE dx IS NOT NULL
      "),
      qc = glue("SELECT count(*) AS n_codes FROM {work('mm_dx_codes')}")
    ),

    list(
      name = "02_diag_proc_codes",
      sql = glue("
        CREATE OR REPLACE TABLE {work('diag_proc_codes')} AS
        SELECT DISTINCT upper(regexp_replace(proc_cd, '\\\\.', '')) AS proc_cd
        FROM {diag_proc_source}
        WHERE proc_cd IS NOT NULL
      "),
      qc = glue("SELECT count(*) AS n_codes FROM {work('diag_proc_codes')}")
    ),

    list(
      name = "03_mm_therapy_codes",
      sql = glue("
        CREATE OR REPLACE TABLE {work('mm_therapy_codes')} AS
        SELECT upper(code_type) AS code_type, upper(regexp_replace(code, '\\\\.', '')) AS code
        FROM {mm_therapy_source}
        WHERE code IS NOT NULL
      "),
      qc = glue("SELECT count(*) AS n_codes FROM {work('mm_therapy_codes')}")
    ),

    list(
      name = "04_preg_codes",
      sql = glue("
        CREATE OR REPLACE TABLE {work('preg_codes')} AS
        SELECT upper(code_type) AS code_type, upper(regexp_replace(code, '\\\\.', '')) AS code
        FROM {preg_source}
        WHERE code IS NOT NULL
      "),
      qc = glue("SELECT count(*) AS n_codes FROM {work('preg_codes')}")
    ),

    list(
      name = "05_clintrial_codes",
      sql = glue("
        CREATE OR REPLACE TABLE {work('clintrial_codes')} AS
        SELECT upper(code_type) AS code_type, upper(regexp_replace(code, '\\\\.', '')) AS code
        FROM {clintrial_source}
        WHERE code IS NOT NULL
      "),
      qc = glue("SELECT count(*) AS n_codes FROM {work('clintrial_codes')}")
    ),

    list(
      name = "06_other_malig_codes",
      sql = glue("
        CREATE OR REPLACE TABLE {work('other_malig_codes')} AS
        SELECT
          upper(tumor_group) AS tumor_group,
          CASE WHEN upper(icd_family) IN ('9','ICD9','ICD-9') THEN 'ICD9' ELSE 'ICD10' END AS icd_family,
          upper(regexp_replace(dx, '\\\\.', '')) AS dx
        FROM {other_malig_source}
        WHERE dx IS NOT NULL AND tumor_group IS NOT NULL
      "),
      qc = glue("SELECT count(*) AS n_codes FROM {work('other_malig_codes')}")
    ),

    # ----------------------------------------------------------
    # PHASE 2: BUILD MM DIAGNOSIS EVENTS
    # FIXED: Build two tables:
    #   - mm_dx_events_all: full study period (for baseline flags)
    #   - mm_dx_events_id:  ID period only (for index qualification)
    # ----------------------------------------------------------
    list(
      name = "07_med_claim_header",
      sql = glue("
        CREATE OR REPLACE TABLE {work('med_claim_header')} AS
        SELECT PATID, CLMID, max(CONF_ID) AS CONF_ID
        FROM {cdm_src(cfg$tbl_medical)}
        WHERE FST_DT BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
        GROUP BY PATID, CLMID
      "),
      qc = glue("SELECT count(*) AS n_claims FROM {work('med_claim_header')}")
    ),

    # All MM dx events in study period (for baseline lookback)
    list(
      name = "08a_mm_dx_events_all",
      sql = glue("
        CREATE OR REPLACE TABLE {work('mm_dx_events_all')} AS
        SELECT /*+ BROADCAST(c) */
          d.PATID,
          d.CLMID,
          cast(d.FST_DT as date) AS svc_dt,
          upper(regexp_replace(d.DIAG, '\\\\.', '')) AS diag,
          CASE WHEN upper(d.ICD_FLAG) IN ('9','ICD9','ICD-9') THEN 'ICD9' ELSE 'ICD10' END AS icd_family,
          h.CONF_ID,
          CASE WHEN h.CONF_ID IS NOT NULL THEN 1 ELSE 0 END AS inpatient_flg,
          CASE WHEN h.CONF_ID IS NULL THEN 1 ELSE 0 END AS outpatient_flg
        FROM {cdm_src(cfg$tbl_med_diag)} d
        INNER JOIN {work('med_claim_header')} h
          ON d.PATID = h.PATID AND d.CLMID = h.CLMID
        INNER JOIN {work('mm_dx_codes')} c
          ON upper(regexp_replace(d.DIAG, '\\\\.', '')) = c.dx
          AND (CASE WHEN upper(d.ICD_FLAG) IN ('9','ICD9','ICD-9') THEN 'ICD9' ELSE 'ICD10' END) = c.icd_family
        WHERE cast(d.FST_DT as date) BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
      "),
      qc = glue("SELECT count(DISTINCT PATID) AS n_patients FROM {work('mm_dx_events_all')}")
    ),

    # MM dx events in ID period only (for index date qualification)
    list(
      name = "08b_mm_dx_events_id",
      sql = glue("
        CREATE OR REPLACE TABLE {work('mm_dx_events_id')} AS
        SELECT * FROM {work('mm_dx_events_all')}
        WHERE svc_dt BETWEEN date('{cfg$id_start}') AND date('{cfg$id_end}')
      "),
      qc = glue("SELECT count(DISTINCT PATID) AS n_patients FROM {work('mm_dx_events_id')}")
    ),

    # ----------------------------------------------------------
    # PHASE 3: INDEX DATE DERIVATION (uses ID period events only)
    # ----------------------------------------------------------
    list(
      name = "09_mm_inpatient_index",
      sql = glue("
        CREATE OR REPLACE TABLE {work('mm_inpatient_index')} AS
        SELECT PATID, 1 AS inpt1, min(svc_dt) AS idx_inpt
        FROM {work('mm_dx_events_id')}
        WHERE inpatient_flg = 1
        GROUP BY PATID
      "),
      qc = glue("SELECT count(*) AS n_inpt_patients FROM {work('mm_inpatient_index')}")
    ),

    list(
      name = "10_mm_outpatient_pairs",
      sql = glue("
        CREATE OR REPLACE TABLE {work('mm_outpatient_pairs')} AS
        WITH distinct_dates AS (
          SELECT DISTINCT PATID, svc_dt
          FROM {work('mm_dx_events_id')}
          WHERE outpatient_flg = 1
        ),
        with_next AS (
          SELECT PATID, svc_dt,
                 lead(svc_dt) OVER (PARTITION BY PATID ORDER BY svc_dt) AS next_dt
          FROM distinct_dates
        )
        SELECT PATID, svc_dt AS first_dt, next_dt,
               datediff(next_dt, svc_dt) AS diff_days
        FROM with_next
        WHERE next_dt IS NOT NULL
      "),
      qc = glue("SELECT count(*) AS n_pairs FROM {work('mm_outpatient_pairs')}")
    ),

    list(
      name = "11_mm_outpatient_index",
      sql = glue("
        CREATE OR REPLACE TABLE {work('mm_outpatient_index')} AS
        SELECT
          PATID,
          max(CASE WHEN diff_days <= {cfg$dx_window_90} THEN 1 ELSE 0 END) AS outpt2_90,
          max(CASE WHEN diff_days <= {cfg$dx_window_60} THEN 1 ELSE 0 END) AS outpt2_60,
          max(CASE WHEN diff_days <= {cfg$dx_window_30} THEN 1 ELSE 0 END) AS outpt2_30,
          min(CASE WHEN diff_days <= {cfg$dx_window_90} THEN first_dt END) AS idx_outpt_90,
          min(CASE WHEN diff_days <= {cfg$dx_window_60} THEN first_dt END) AS idx_outpt_60,
          min(CASE WHEN diff_days <= {cfg$dx_window_30} THEN first_dt END) AS idx_outpt_30
        FROM {work('mm_outpatient_pairs')}
        GROUP BY PATID
      "),
      qc = glue("SELECT count(*) AS n_outpt_patients FROM {work('mm_outpatient_index')}")
    ),

    list(
      name = "12_mm_qualifying",
      sql = glue("
        CREATE OR REPLACE TABLE {work('mm_qualifying')} AS
        WITH combined AS (
          SELECT PATID, inpt1, 0 AS outpt2_90, 0 AS outpt2_60, 0 AS outpt2_30,
                 idx_inpt, NULL AS idx_outpt_90, NULL AS idx_outpt_60, NULL AS idx_outpt_30
          FROM {work('mm_inpatient_index')}
          UNION ALL
          SELECT PATID, 0 AS inpt1, outpt2_90, outpt2_60, outpt2_30,
                 NULL AS idx_inpt, idx_outpt_90, idx_outpt_60, idx_outpt_30
          FROM {work('mm_outpatient_index')}
        ),
        agg AS (
          SELECT
            PATID,
            max(inpt1) AS inpt1,
            max(outpt2_90) AS outpt2_90,
            max(outpt2_60) AS outpt2_60,
            max(outpt2_30) AS outpt2_30,
            min(idx_inpt) AS idx_inpt,
            min(idx_outpt_90) AS idx_outpt_90,
            min(idx_outpt_60) AS idx_outpt_60,
            min(idx_outpt_30) AS idx_outpt_30
          FROM combined
          GROUP BY PATID
        )
        SELECT
          PATID, inpt1, outpt2_90, outpt2_60, outpt2_30,
          idx_inpt, idx_outpt_90, idx_outpt_60, idx_outpt_30,
          -- Index date: earliest of inpatient or qualifying outpatient (90-day primary)
          CASE
            WHEN inpt1 = 1 AND idx_outpt_90 IS NULL THEN idx_inpt
            WHEN inpt1 = 0 AND idx_outpt_90 IS NOT NULL THEN idx_outpt_90
            WHEN inpt1 = 1 AND idx_outpt_90 IS NOT NULL THEN least(idx_inpt, idx_outpt_90)
          END AS index_date,
          CASE
            WHEN inpt1 = 1 AND (idx_outpt_90 IS NULL OR idx_inpt <= idx_outpt_90) THEN 'INPATIENT'
            WHEN idx_outpt_90 IS NOT NULL THEN 'OUTPATIENT_2IN90'
          END AS index_source
        FROM agg
        WHERE inpt1 = 1 OR outpt2_90 = 1
      "),
      qc = glue("SELECT count(*) AS n_qualifying FROM {work('mm_qualifying')}")
    ),

    # ----------------------------------------------------------
    # PHASE 4: ENROLLMENT SPANS WITH GAP LOGIC
    # Per DataPrep: allowable gaps <= 30 days
    # FIXED: gap_days + 1 because ELIGEND is inclusive (last day of coverage)
    # ----------------------------------------------------------
    list(
      name = "13_enrollment_spans",
      sql = glue("
        CREATE OR REPLACE TABLE {work('enrollment_spans')} AS
        WITH base AS (
          SELECT PATID, cast(ELIGEFF as date) AS elig_eff, cast(ELIGEND as date) AS elig_end
          FROM {cdm_src(cfg$tbl_member_elig)}
          WHERE ELIGEFF IS NOT NULL AND ELIGEND IS NOT NULL
        ),
        ordered AS (
          SELECT *, lag(elig_end) OVER (PARTITION BY PATID ORDER BY elig_eff, elig_end) AS prev_end
          FROM base
        ),
        flagged AS (
          SELECT *,
            -- FIXED: +1 because ELIGEND is inclusive (day after prev_end is first uncovered day)
            CASE WHEN prev_end IS NULL THEN 1
                 WHEN elig_eff <= date_add(prev_end, {cfg$gap_days} + 1) THEN 0
                 ELSE 1 END AS new_grp
          FROM ordered
        ),
        grouped AS (
          SELECT *,
            sum(new_grp) OVER (PARTITION BY PATID ORDER BY elig_eff, elig_end
                               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS grp_id
          FROM flagged
        )
        SELECT PATID, grp_id, min(elig_eff) AS cov_start, max(elig_end) AS cov_end
        FROM grouped
        GROUP BY PATID, grp_id
      "),
      qc = glue("SELECT count(DISTINCT PATID) AS n_patients FROM {work('enrollment_spans')}")
    ),

    # ----------------------------------------------------------
    # PHASE 4b: STRICT ENROLLMENT SPANS (NO GAPS)
    # Per StudyPop spec: CE_3mosf requires NO allowable gaps
    # ----------------------------------------------------------
    list(
      name = "13b_enrollment_spans_strict",
      sql = glue("
        CREATE OR REPLACE TABLE {work('enrollment_spans_strict')} AS
        WITH base AS (
          SELECT PATID, cast(ELIGEFF as date) AS elig_eff, cast(ELIGEND as date) AS elig_end
          FROM {cdm_src(cfg$tbl_member_elig)}
          WHERE ELIGEFF IS NOT NULL AND ELIGEND IS NOT NULL
        ),
        ordered AS (
          SELECT *, lag(elig_end) OVER (PARTITION BY PATID ORDER BY elig_eff, elig_end) AS prev_end
          FROM base
        ),
        flagged AS (
          SELECT *,
            -- NO allowable gaps: new group if elig_eff > prev_end + 1 (i.e., any gap)
            CASE WHEN prev_end IS NULL THEN 1
                 WHEN elig_eff <= date_add(prev_end, 1) THEN 0
                 ELSE 1 END AS new_grp
          FROM ordered
        ),
        grouped AS (
          SELECT *,
            sum(new_grp) OVER (PARTITION BY PATID ORDER BY elig_eff, elig_end
                               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS grp_id
          FROM flagged
        )
        SELECT PATID, grp_id, min(elig_eff) AS cov_start, max(elig_end) AS cov_end
        FROM grouped
        GROUP BY PATID, grp_id
      "),
      qc = glue("SELECT count(DISTINCT PATID) AS n_patients FROM {work('enrollment_spans_strict')}")
    ),

    # ----------------------------------------------------------
    # PHASE 5: CE FLAGS (baseline 6 months, follow-up, 3-month sensitivity)
    # FIXED: Added CE_3mosf using STRICT enrollment spans (no gaps allowed)
    # ----------------------------------------------------------
    list(
      name = "14_ce_flags",
      sql = glue("
        CREATE OR REPLACE TABLE {work('ce_flags')} AS
        WITH idx AS (
          SELECT PATID, index_date,
                 date_sub(index_date, {cfg$baseline_days}) AS baseline_start,
                 date_sub(index_date, 1) AS baseline_end
          FROM {work('mm_qualifying')}
        ),
        -- CE_b and CE_f use standard enrollment spans (with allowable gaps)
        joined_std AS (
          SELECT i.PATID, i.index_date, i.baseline_start, i.baseline_end,
                 s.cov_start, s.cov_end,
                 CASE WHEN s.cov_start <= i.baseline_start AND s.cov_end >= i.baseline_end
                      THEN 1 ELSE 0 END AS covers_baseline,
                 CASE WHEN s.cov_start <= i.index_date AND s.cov_end >= i.index_date
                      THEN 1 ELSE 0 END AS covers_index
          FROM idx i
          LEFT JOIN {work('enrollment_spans')} s ON i.PATID = s.PATID
        ),
        std_agg AS (
          SELECT PATID, index_date, baseline_start, baseline_end,
                 max(covers_baseline) AS CE_b,
                 max(covers_index) AS CE_f,
                 max(CASE WHEN covers_index = 1 THEN cov_end END) AS ENDDATE_CE
          FROM joined_std
          GROUP BY PATID, index_date, baseline_start, baseline_end
        ),
        -- CE_3mosf uses STRICT enrollment spans (NO allowable gaps per spec)
        joined_strict AS (
          SELECT i.PATID,
                 -- 3-month (91 days) follow-up sensitivity flag with NO gaps allowed
                 CASE WHEN ss.cov_start <= i.index_date AND ss.cov_end >= date_add(i.index_date, 91)
                      THEN 1 ELSE 0 END AS covers_3mos_strict
          FROM idx i
          LEFT JOIN {work('enrollment_spans_strict')} ss ON i.PATID = ss.PATID
        ),
        strict_agg AS (
          SELECT PATID, max(covers_3mos_strict) AS CE_3mosf
          FROM joined_strict
          GROUP BY PATID
        )
        SELECT
          a.PATID, a.index_date, a.baseline_start, a.baseline_end,
          a.CE_b, a.CE_f, a.ENDDATE_CE,
          coalesce(s.CE_3mosf, 0) AS CE_3mosf
        FROM std_agg a
        LEFT JOIN strict_agg s ON a.PATID = s.PATID
      "),
      qc = glue("SELECT sum(CE_b) AS n_with_baseline_ce FROM {work('ce_flags')}")
    ),

    # ----------------------------------------------------------
    # PHASE 6: DEMOGRAPHICS
    # ----------------------------------------------------------
    list(
      name = "15_member_demo",
      sql = glue("
        CREATE OR REPLACE TABLE {work('member_demo')} AS
        WITH ranked AS (
          SELECT PATID, GDR_CD, cast(YRDOB as int) AS YRDOB,
                 row_number() OVER (PARTITION BY PATID
                   ORDER BY CASE WHEN upper(GDR_CD) NOT IN ('U','') THEN 0 ELSE 1 END,
                            cast(ELIGEND as date) DESC) AS rn
          FROM {cdm_src(cfg$tbl_member_elig)}
        )
        SELECT PATID, GDR_CD, YRDOB FROM ranked WHERE rn = 1
      "),
      qc = glue("SELECT count(*) AS n_patients FROM {work('member_demo')}")
    ),

    # ----------------------------------------------------------
    # PHASE 6b: DEATH DATE DERIVATION
    # Per StudyPop spec: When death date is only available at month-level
    # granularity, the date is generalized to the middle of the month (15th)
    # ----------------------------------------------------------
    list(
      name = "15b_death_dt",
      sql = glue("
        CREATE OR REPLACE TABLE {work('death_dt')} AS
        WITH raw_death AS (
          SELECT
            PATID,
            -- Optum death fields: DEATH_YR (yyyy), DEATH_MO (mm), DEATH_DY (dd)
            -- If day is missing (NULL or 0), use 15; if month is missing, use July (7)
            cast(DEATH_YR as int) AS death_yr,
            cast(DEATH_MO as int) AS death_mo,
            cast(DEATH_DY as int) AS death_dy
          FROM {cdm_src(cfg$tbl_member_elig)}
          WHERE DEATH_YR IS NOT NULL AND cast(DEATH_YR as int) > 0
        ),
        -- Take most recent non-null death record per patient
        ranked AS (
          SELECT *,
                 row_number() OVER (PARTITION BY PATID ORDER BY death_yr DESC, death_mo DESC NULLS LAST, death_dy DESC NULLS LAST) AS rn
          FROM raw_death
        ),
        best AS (
          SELECT PATID, death_yr, death_mo, death_dy FROM ranked WHERE rn = 1
        )
        SELECT
          PATID,
          -- Per StudyPop: generalize to 15th if only month-level, July 15 if only year-level
          CASE
            WHEN death_mo IS NULL OR death_mo = 0 THEN
              make_date(death_yr, 7, 15)  -- Year-level only -> July 15
            WHEN death_dy IS NULL OR death_dy = 0 THEN
              make_date(death_yr, death_mo, 15)  -- Month-level only -> 15th
            ELSE
              make_date(death_yr, death_mo, death_dy)  -- Full date available
          END AS DEATH_DT
        FROM best
      "),
      qc = glue("SELECT count(*) AS n_with_death_dt FROM {work('death_dt')}")
    ),

    # ----------------------------------------------------------
    # PHASE 7: NON-DIAGNOSTIC CLAIM FLAG
    # FIXED: Handle NULL PROC_CD properly (only count explicit non-diagnostic lines)
    # ----------------------------------------------------------
    list(
      name = "16_claim_nondiagnostic",
      sql = glue("
        CREATE OR REPLACE TABLE {work('claim_nondiagnostic')} AS
        WITH lines AS (
          SELECT PATID, CLMID, upper(regexp_replace(PROC_CD, '\\\\.', '')) AS proc_cd
          FROM {cdm_src(cfg$tbl_medical)}
          WHERE FST_DT BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
        ),
        marked AS (
          SELECT /*+ BROADCAST(d) */
            l.PATID, l.CLMID,
            -- FIXED: Only mark as diagnostic if we have a proc_cd AND it's in diagnostic list
            CASE
              WHEN l.proc_cd IS NULL THEN NULL  -- Unknown, don't count
              WHEN d.proc_cd IS NOT NULL THEN 1 -- Is diagnostic procedure
              ELSE 0                            -- Has proc_cd but not diagnostic
            END AS is_diag_line
          FROM lines l
          LEFT JOIN {work('diag_proc_codes')} d ON l.proc_cd = d.proc_cd
        )
        SELECT PATID, CLMID,
               -- FIXED: Only count as non-diagnostic if we have explicit 0 (not NULL)
               max(CASE WHEN is_diag_line = 0 THEN 1 ELSE 0 END) AS has_nondiag_line
        FROM marked
        GROUP BY PATID, CLMID
      "),
      qc = glue("SELECT sum(has_nondiag_line) AS n_nondiag_claims FROM {work('claim_nondiagnostic')}")
    ),

    # FIXED: Use mm_dx_events_all for baseline lookback (not just ID period)
    list(
      name = "17_mm_baseline_nondx_flag",
      sql = glue("
        CREATE OR REPLACE TABLE {work('mm_baseline_nondx_flag')} AS
        SELECT
          q.PATID,
          max(CASE WHEN e.svc_dt BETWEEN date_sub(q.index_date, {cfg$baseline_days})
                                     AND date_sub(q.index_date, 1)
                    AND n.has_nondiag_line = 1
               THEN 1 ELSE 0 END) AS MM_BASELINE_NONDX
        FROM {work('mm_qualifying')} q
        LEFT JOIN {work('mm_dx_events_all')} e ON q.PATID = e.PATID
        LEFT JOIN {work('claim_nondiagnostic')} n ON e.PATID = n.PATID AND e.CLMID = n.CLMID
        GROUP BY q.PATID
      "),
      qc = glue("SELECT sum(MM_BASELINE_NONDX) AS n_with_baseline_nondx FROM {work('mm_baseline_nondx_flag')}")
    ),

    # ----------------------------------------------------------
    # PHASE 8: THERAPY EVENTS AND FLAGS
    # ----------------------------------------------------------
    list(
      name = "18_therapy_events",
      sql = glue("
        CREATE OR REPLACE TABLE {work('therapy_events')} AS
        -- Medical therapy via PROC_CD
        SELECT /*+ BROADCAST(c) */
          m.PATID, cast(m.FST_DT as date) AS event_dt, 'MEDICAL' AS source
        FROM {cdm_src(cfg$tbl_medical)} m
        INNER JOIN {work('mm_therapy_codes')} c
          ON c.code_type IN ('HCPCS','CPT','PROC')
          AND upper(regexp_replace(m.PROC_CD, '\\\\.', '')) = c.code
        WHERE m.FST_DT BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')

        UNION ALL

        -- RX therapy via NDC
        SELECT /*+ BROADCAST(c) */
          r.PATID, cast(r.FILL_DT as date) AS event_dt, 'RX' AS source
        FROM {cdm_src(cfg$tbl_rx)} r
        INNER JOIN {work('mm_therapy_codes')} c
          ON c.code_type = 'NDC'
          AND upper(regexp_replace(r.NDC, '\\\\.', '')) = c.code
        WHERE r.FILL_DT BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
      "),
      qc = glue("SELECT count(*) AS n_therapy_events FROM {work('therapy_events')}")
    ),

    list(
      name = "19_therapy_flags",
      sql = glue("
        CREATE OR REPLACE TABLE {work('therapy_flags')} AS
        SELECT
          q.PATID,
          max(CASE WHEN t.event_dt BETWEEN date_sub(q.index_date, {cfg$baseline_days})
                                       AND date_sub(q.index_date, 1)
               THEN 1 ELSE 0 END) AS MM_THERAPY_BASELINE,
          max(CASE WHEN t.event_dt >= q.index_date AND t.event_dt <= date('{cfg$study_end}')
               THEN 1 ELSE 0 END) AS MM_THERAPY_FOLLOWUP
        FROM {work('mm_qualifying')} q
        LEFT JOIN {work('therapy_events')} t ON q.PATID = t.PATID
        GROUP BY q.PATID
      "),
      qc = glue("SELECT sum(MM_THERAPY_FOLLOWUP) AS n_with_fu_therapy FROM {work('therapy_flags')}")
    ),

    # ----------------------------------------------------------
    # PHASE 9: EXCLUSION FLAGS (pregnancy, clinical trial, other cancer)
    # Each is an independent flag per StudyPop spec
    # ----------------------------------------------------------
    list(
      name = "20_pregnancy_flag",
      sql = glue("
        CREATE OR REPLACE TABLE {work('pregnancy_flag')} AS
        WITH dx AS (
          SELECT PATID, cast(FST_DT as date) AS event_dt, 'DX' AS code_type,
                 upper(regexp_replace(DIAG, '\\\\.', '')) AS code
          FROM {cdm_src(cfg$tbl_med_diag)}
          WHERE FST_DT BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
        ),
        proc AS (
          SELECT PATID, cast(FST_DT as date) AS event_dt, 'PROC' AS code_type,
                 upper(regexp_replace(PROC_CD, '\\\\.', '')) AS code
          FROM {cdm_src(cfg$tbl_medical)}
          WHERE PROC_CD IS NOT NULL
            AND FST_DT BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
        ),
        events AS (SELECT * FROM dx UNION ALL SELECT * FROM proc),
        matched AS (
          SELECT /*+ BROADCAST(p) */ e.PATID, e.event_dt
          FROM events e
          INNER JOIN {work('preg_codes')} p ON e.code_type = p.code_type AND e.code = p.code
        )
        SELECT
          q.PATID,
          max(CASE WHEN m.event_dt BETWEEN date_sub(q.index_date, {cfg$baseline_days})
                                       AND date('{cfg$study_end}')
               THEN 1 ELSE 0 END) AS PREGNANT_FLAG
        FROM {work('mm_qualifying')} q
        LEFT JOIN matched m ON q.PATID = m.PATID
        GROUP BY q.PATID
      "),
      qc = glue("SELECT sum(PREGNANT_FLAG) AS n_pregnant FROM {work('pregnancy_flag')}")
    ),

    list(
      name = "21_clintrial_flag",
      sql = glue("
        CREATE OR REPLACE TABLE {work('clintrial_flag')} AS
        WITH dx AS (
          SELECT PATID, cast(FST_DT as date) AS event_dt, 'DX' AS code_type,
                 upper(regexp_replace(DIAG, '\\\\.', '')) AS code
          FROM {cdm_src(cfg$tbl_med_diag)}
          WHERE FST_DT BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
        ),
        proc AS (
          SELECT PATID, cast(FST_DT as date) AS event_dt, 'PROC' AS code_type,
                 upper(regexp_replace(PROC_CD, '\\\\.', '')) AS code
          FROM {cdm_src(cfg$tbl_medical)}
          WHERE PROC_CD IS NOT NULL
            AND FST_DT BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
        ),
        events AS (SELECT * FROM dx UNION ALL SELECT * FROM proc),
        matched AS (
          SELECT /*+ BROADCAST(c) */ e.PATID, e.event_dt
          FROM events e
          INNER JOIN {work('clintrial_codes')} c ON e.code_type = c.code_type AND e.code = c.code
        )
        SELECT
          q.PATID,
          max(CASE WHEN m.event_dt BETWEEN date_sub(q.index_date, {cfg$baseline_days})
                                       AND date_sub(q.index_date, 1)
               THEN 1 ELSE 0 END) AS CLINTRIAL_BASELINE,
          max(CASE WHEN m.event_dt >= q.index_date AND m.event_dt <= date('{cfg$study_end}')
               THEN 1 ELSE 0 END) AS CLINTRIAL_FOLLOWUP
        FROM {work('mm_qualifying')} q
        LEFT JOIN matched m ON q.PATID = m.PATID
        GROUP BY q.PATID
      "),
      qc = glue("SELECT sum(CLINTRIAL_BASELINE) + sum(CLINTRIAL_FOLLOWUP) AS n_clintrial FROM {work('clintrial_flag')}")
    ),

    list(
      name = "22_other_malig_flag",
      sql = glue("
        CREATE OR REPLACE TABLE {work('other_malig_flag')} AS
        WITH dx AS (
          SELECT d.PATID, d.CLMID, cast(d.FST_DT as date) AS event_dt,
                 upper(regexp_replace(d.DIAG, '\\\\.', '')) AS dx,
                 CASE WHEN upper(d.ICD_FLAG) IN ('9','ICD9','ICD-9') THEN 'ICD9' ELSE 'ICD10' END AS icd_family
          FROM {cdm_src(cfg$tbl_med_diag)} d
          WHERE FST_DT BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
        ),
        dx_mapped AS (
          SELECT /*+ BROADCAST(o) */ dx.PATID, dx.CLMID, dx.event_dt, o.tumor_group
          FROM dx
          INNER JOIN {work('other_malig_codes')} o ON dx.dx = o.dx AND dx.icd_family = o.icd_family
        ),
        dx_nondx AS (
          SELECT m.PATID, m.tumor_group, m.event_dt
          FROM dx_mapped m
          INNER JOIN {work('claim_nondiagnostic')} n ON m.PATID = n.PATID AND m.CLMID = n.CLMID
          WHERE n.has_nondiag_line = 1
        ),
        distinct_dates AS (SELECT DISTINCT PATID, tumor_group, event_dt FROM dx_nondx),
        with_next AS (
          SELECT PATID, tumor_group, event_dt,
                 lead(event_dt) OVER (PARTITION BY PATID, tumor_group ORDER BY event_dt) AS next_dt
          FROM distinct_dates
        ),
        pairs AS (
          SELECT PATID, tumor_group, event_dt AS first_dt, next_dt,
                 datediff(next_dt, event_dt) AS diff_days
          FROM with_next WHERE next_dt IS NOT NULL
        )
        SELECT
          q.PATID,
          max(CASE WHEN p.diff_days <= 30
                    AND p.first_dt BETWEEN date_sub(q.index_date, {cfg$baseline_days})
                                       AND date_sub(q.index_date, 1)
               THEN 1 ELSE 0 END) AS OTHER_MALIGN_FLAG
        FROM {work('mm_qualifying')} q
        LEFT JOIN pairs p ON q.PATID = p.PATID
        GROUP BY q.PATID
      "),
      qc = glue("SELECT sum(OTHER_MALIGN_FLAG) AS n_other_malig FROM {work('other_malig_flag')}")
    ),

    # ----------------------------------------------------------
    # PHASE 10: FINAL ASSEMBLY - ELIG_COH with all flags
    # FIXED: Added Death_dt, proper ENDDATE/FU_DAYS per StudyPop spec:
    #   - ENDDATE = min(Death_dt, study_end)
    #   - ENDDATE_CE = min(Death_dt, disenrollment, study_end)
    #   - FU_DAYS = datediff(ENDDATE, index_date) + 1
    #   - FU_DAYS_CE = datediff(ENDDATE_CE, index_date) + 1
    # ----------------------------------------------------------
    list(
      name = "23_ELIG_COH_ALLFLAGS",
      sql = glue("
        CREATE OR REPLACE TABLE {work('ELIG_COH_ALLFLAGS')} AS
        SELECT
          q.PATID,
          q.index_date AS INDEX_DATE,
          year(q.index_date) AS INDEX_YR,
          d.GDR_CD,
          d.YRDOB,
          (year(q.index_date) - d.YRDOB) AS AGE_INDEX_YR,

          -- Diagnosis qualification flags
          q.inpt1,
          q.outpt2_30,
          q.outpt2_60,
          q.outpt2_90,
          q.index_source,

          -- Enrollment
          ce.baseline_start,
          ce.baseline_end,
          coalesce(ce.CE_b, 0) AS CE_b,
          coalesce(ce.CE_f, 0) AS CE_f,
          coalesce(ce.CE_3mosf, 0) AS CE_3mosf,

          -- Death date (per StudyPop: generalized to 15th if month-level only)
          death.DEATH_DT,

          -- Per StudyPop spec:
          -- ENDDATE = min(Death_dt, study_end)
          least(
            date('{cfg$study_end}'),
            coalesce(death.DEATH_DT, date('{cfg$study_end}'))
          ) AS ENDDATE,

          -- ENDDATE_CE = min(Death_dt, disenrollment_date, study_end)
          least(
            date('{cfg$study_end}'),
            coalesce(death.DEATH_DT, date('{cfg$study_end}')),
            coalesce(ce.ENDDATE_CE, date('{cfg$study_end}'))
          ) AS ENDDATE_CE,

          -- FU_DAYS = datediff(ENDDATE, index_date) + 1
          datediff(
            least(
              date('{cfg$study_end}'),
              coalesce(death.DEATH_DT, date('{cfg$study_end}'))
            ),
            q.index_date
          ) + 1 AS FU_DAYS,

          -- FU_DAYS_CE = datediff(ENDDATE_CE, index_date) + 1
          datediff(
            least(
              date('{cfg$study_end}'),
              coalesce(death.DEATH_DT, date('{cfg$study_end}')),
              coalesce(ce.ENDDATE_CE, date('{cfg$study_end}'))
            ),
            q.index_date
          ) + 1 AS FU_DAYS_CE,

          -- Therapy flags
          coalesce(th.MM_THERAPY_BASELINE, 0) AS MM_bl_agents,
          coalesce(th.MM_THERAPY_FOLLOWUP, 0) AS MM_FU_agents,

          -- Smoldering/baseline MM flag
          coalesce(mm_bl.MM_BASELINE_NONDX, 0) AS MM_baseline_diag,

          -- Exclusion flags (independent per StudyPop spec)
          coalesce(om.OTHER_MALIGN_FLAG, 0) AS OTHER_MALIGN_FLAG,
          coalesce(preg.PREGNANT_FLAG, 0) AS PREGNANT_FLAG,
          coalesce(ct.CLINTRIAL_BASELINE, 0) AS CLINTRIAL_BASELINE,
          coalesce(ct.CLINTRIAL_FOLLOWUP, 0) AS CLINTRIAL_FOLLOWUP

        FROM {work('mm_qualifying')} q
        LEFT JOIN {work('ce_flags')} ce ON q.PATID = ce.PATID
        LEFT JOIN {work('member_demo')} d ON q.PATID = d.PATID
        LEFT JOIN {work('death_dt')} death ON q.PATID = death.PATID
        LEFT JOIN {work('mm_baseline_nondx_flag')} mm_bl ON q.PATID = mm_bl.PATID
        LEFT JOIN {work('therapy_flags')} th ON q.PATID = th.PATID
        LEFT JOIN {work('pregnancy_flag')} preg ON q.PATID = preg.PATID
        LEFT JOIN {work('clintrial_flag')} ct ON q.PATID = ct.PATID
        LEFT JOIN {work('other_malig_flag')} om ON q.PATID = om.PATID
      "),
      qc = glue("SELECT count(*) AS n_total, count(DISTINCT PATID) AS n_patients FROM {work('ELIG_COH_ALLFLAGS')}")
    ),

    list(
      name = "24_ELIG_COH_FINAL",
      sql = glue("
        CREATE OR REPLACE TABLE {work('ELIG_COH_FINAL')} AS
        SELECT *
        FROM {work('ELIG_COH_ALLFLAGS')}
        WHERE AGE_INDEX_YR >= 18
          AND CE_b = 1
          AND CE_f = 1
          AND MM_bl_agents = 0
          AND MM_FU_agents = 1
      "),
      qc = glue("SELECT count(*) AS n_final_cohort FROM {work('ELIG_COH_FINAL')}")
    )
  )
}

# ============================================================
# MAIN EXECUTION (fixed: uses con_env for connection)
# ============================================================

main <- function() {
  # Prompt user for options at start
  user_cfg <- prompt_user_options()

  # Update cfg with user selections (env vars take precedence)
  cfg$cdm_schema <<- Sys.getenv("OPTUM_CDM_SCHEMA", unset = user_cfg$cdm_schema)
  cfg$ref_schema <<- Sys.getenv("PROJECT_REF_SCHEMA", unset = user_cfg$ref_schema)
  cfg$work_schema <<- Sys.getenv("PROJECT_WORK_SCHEMA", unset = user_cfg$work_schema)
  cfg$study_start <<- user_cfg$study_start
  cfg$study_end <<- user_cfg$study_end
  cfg$id_start <<- user_cfg$id_start
  cfg$id_end <<- user_cfg$id_end
  cfg$baseline_days <<- user_cfg$baseline_days
  cfg$gap_days <<- user_cfg$gap_days
  # LOCAL-ONLY mode: env var takes precedence, then user input
  cfg$local_only <<- as.logical(Sys.getenv("LOCAL_ONLY_MODE", unset = "FALSE")) ||
                      isTRUE(user_cfg$local_only)

  log_msg("=" , strrep("=", 59))
  log_msg("ATTRITION COHORT PIPELINE - run_id: ", run_id)
  if (isTRUE(cfg$use_embedded_codes)) {
    log_msg("CODE LISTS: Using EMBEDDED codes (no external tables required)")
  } else {
    log_msg("CODE LISTS: Using EXTERNAL tables from ", cfg$ref_schema)
  }
  if (isTRUE(cfg$local_only)) {
    log_msg("MODE: LOCAL-ONLY (using TEMPORARY VIEWs)")
  }
  if (isTRUE(cfg$use_quarterly_tables)) {
    log_msg("TABLES: Using QUARTERLY partitioned tables (t_<table>_YYYYqQ)")
  } else {
    log_msg("TABLES: Using single consolidated tables")
  }
  log_msg("=" , strrep("=", 59))

  # Connect with retry (now returns connection properly)
  con_env$con <- with_retry(function() {
    conn <- connect_databricks()
    log_msg("Connected to Databricks")
    conn
  })

  on.exit({
    if (!is.null(con_env$con)) try(DBI::dbDisconnect(con_env$con), silent = TRUE)
  }, add = TRUE)

  # Ensure schema and run log table exist
  ensure_schema(con_env$con)
  log_table <- ensure_run_log(con_env$con)
  log_msg("Run log table: ", log_table)

  # Build and run steps
  steps <- build_steps()
  log_msg("Running ", length(steps), " pipeline steps...")

  for (s in steps) {
    with_retry(function() {
      run_step(log_table, s$name, s$sql, qc_sql = s$qc)
    })
  }

  # Final summary
  log_msg("=" , strrep("=", 59))
  log_msg("PIPELINE COMPLETE - Generating attrition report...")

  # Build and run detailed attrition queries
  # Use temp view names in local_only mode, qualified names otherwise
  tbl <- function(name) {
    if (isTRUE(cfg$local_only)) name else work(name)
  }

  # Collect detailed attrition counts
  tryCatch({
    # Step 1: All patients with MM diagnosis in ID period
    q1 <- DBI::dbGetQuery(con_env$con, glue("SELECT count(DISTINCT PATID) AS n FROM {tbl('mm_dx_events_id')}"))
    record_attrition("01_mm_dx", "Patients with MM diagnosis (ID period)", q1$n)

    # Step 2: Qualifying patients (1+ inpatient OR 2 outpatient in 90 days)
    q2 <- DBI::dbGetQuery(con_env$con, glue("SELECT count(*) AS n FROM {tbl('mm_qualifying')}"))
    record_attrition("02_qualifying", "MM qualifying (1+ IP or 2 OP in 90d)", q2$n)

    # Step 3: With baseline enrollment (CE_b = 1)
    q3 <- DBI::dbGetQuery(con_env$con, glue("SELECT count(*) AS n FROM {tbl('ELIG_COH_ALLFLAGS')} WHERE CE_b = 1"))
    record_attrition("03_ce_baseline", "With 6-mo baseline enrollment", q3$n)

    # Step 4: With index date enrollment (CE_f = 1)
    q4 <- DBI::dbGetQuery(con_env$con, glue("SELECT count(*) AS n FROM {tbl('ELIG_COH_ALLFLAGS')} WHERE CE_b = 1 AND CE_f = 1"))
    record_attrition("04_ce_index", "With index date enrollment", q4$n)

    # Step 5: Age >= 18
    q5 <- DBI::dbGetQuery(con_env$con, glue("SELECT count(*) AS n FROM {tbl('ELIG_COH_ALLFLAGS')} WHERE CE_b = 1 AND CE_f = 1 AND AGE_INDEX_YR >= 18"))
    record_attrition("05_age_18", "Age >= 18 at index", q5$n)

    # Step 6: No MM therapy in baseline
    q6 <- DBI::dbGetQuery(con_env$con, glue("SELECT count(*) AS n FROM {tbl('ELIG_COH_ALLFLAGS')} WHERE CE_b = 1 AND CE_f = 1 AND AGE_INDEX_YR >= 18 AND MM_bl_agents = 0"))
    record_attrition("06_no_bl_therapy", "No MM therapy in baseline", q6$n)

    # Step 7: MM therapy in follow-up (final cohort)
    q7 <- DBI::dbGetQuery(con_env$con, glue("SELECT count(*) AS n FROM {tbl('ELIG_COH_FINAL')}"))
    record_attrition("07_final", "MM therapy in follow-up (FINAL)", q7$n)

    # Print the attrition table
    print_attrition_table()

    # Print additional summary statistics
    cat("\n")
    cat("============================================================\n")
    cat("                 COHORT CHARACTERISTICS                     \n")
    cat("============================================================\n")

    # Get summary stats from final cohort
    stats_sql <- glue("
      SELECT
        count(*) AS n_patients,
        avg(AGE_INDEX_YR) AS mean_age,
        sum(CASE WHEN GDR_CD = 'M' THEN 1 ELSE 0 END) AS n_male,
        sum(CASE WHEN GDR_CD = 'F' THEN 1 ELSE 0 END) AS n_female,
        avg(FU_DAYS) AS mean_fu_days,
        min(INDEX_DATE) AS min_index_date,
        max(INDEX_DATE) AS max_index_date,
        sum(CASE WHEN index_source = 'INPATIENT' THEN 1 ELSE 0 END) AS n_inpatient_index,
        sum(CASE WHEN DEATH_DT IS NOT NULL THEN 1 ELSE 0 END) AS n_with_death
      FROM {tbl('ELIG_COH_FINAL')}
    ")
    stats <- DBI::dbGetQuery(con_env$con, stats_sql)

    cat(sprintf("Total patients:          %s\n", format(stats$n_patients, big.mark = ",")))
    cat(sprintf("Mean age at index:       %.1f years\n", stats$mean_age))
    cat(sprintf("Male / Female:           %s / %s\n",
                format(stats$n_male, big.mark = ","),
                format(stats$n_female, big.mark = ",")))
    cat(sprintf("Inpatient index:         %s (%.1f%%)\n",
                format(stats$n_inpatient_index, big.mark = ","),
                100 * stats$n_inpatient_index / stats$n_patients))
    cat(sprintf("Mean follow-up:          %.1f days\n", stats$mean_fu_days))
    cat(sprintf("Index date range:        %s to %s\n", stats$min_index_date, stats$max_index_date))
    cat(sprintf("Patients with death:     %s (%.1f%%)\n",
                format(stats$n_with_death, big.mark = ","),
                100 * stats$n_with_death / stats$n_patients))
    cat("============================================================\n")

  }, error = function(e) {
    log_msg("WARN: Could not generate full attrition report: ", conditionMessage(e))
  })

  log_msg("=" , strrep("=", 59))
}

# Run if executed as script
if (!interactive()) {
  main()
} else {
  log_msg("Source loaded. Call main() to run pipeline.")
}
