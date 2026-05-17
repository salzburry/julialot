# Connection, retry, naming, and materialization helpers. No
# module-level mutable state - runtime state is created in main() and
# passed by argument.

# ---- Separators (pre-computed constants) ----
SEP_59  <- strrep("=", 59)
SEP_60  <- strrep("=", 60)
SEP_70  <- strrep("=", 70)
DASH_60 <- strrep("-", 60)
DASH_70 <- strrep("-", 70)

# ---- Logging ----
# Resolve a single run log file (memoized). Honour PIPELINE_LOG_FILE if
# set (the orchestrator points all stages at one file); else write a
# timestamped file under OUTPUT_DIR (falls back to tempdir()).
.resolve_log_file <- function() {
  lf <- getOption("pipeline_log_file", default = NULL)
  if (!is.null(lf)) return(lf)
  envf <- Sys.getenv("PIPELINE_LOG_FILE", unset = "")
  if (nzchar(envf)) {
    lf <- envf
  } else {
    base_dir <- Sys.getenv("OUTPUT_DIR", unset = "")
    if (!nzchar(base_dir)) base_dir <- "/mnt/artifacts/results"
    ok <- tryCatch({ dir.create(base_dir, showWarnings = FALSE, recursive = TRUE); dir.exists(base_dir) },
                   error = function(e) FALSE)
    if (!isTRUE(ok)) base_dir <- tempdir()
    lf <- file.path(base_dir, paste0("pipeline_run_",
            format(Sys.time(), "%Y%m%d_%H%M%S"), ".log"))
  }
  options(pipeline_log_file = lf)
  cat(sprintf("[%s] [log] run log -> %s\n",
              format(Sys.time(), "%Y-%m-%d %H:%M:%S"), lf))
  lf
}

log_msg <- function(...) {
  prefix <- sprintf("[%s] ", format(Sys.time(), "%Y-%m-%d %H:%M:%S"))
  cat(prefix, ..., "\n")
  flush.console()
  try({
    lf <- .resolve_log_file()
    cat(prefix, ..., "\n", file = lf, append = TRUE)
  }, silent = TRUE)
}

# ---- Naming helpers (closure factory) ----
# Returns naming functions that close over cfg and mat_tables. Callers
# unpack them into locals so the ~114 glue interpolations in
# pipeline_steps.R need no changes. mat_tables is an environment
# (reference semantics) so materialize_to_personal_schema() writes are
# visible to work_tbl().
make_naming_helpers <- function(cfg, mat_tables = new.env()) {
  full_name <- function(schema, object) {
    if (nzchar(cfg$catalog)) paste0(cfg$catalog, ".", schema, ".", object)
    else paste0(schema, ".", object)
  }
  cdm  <- function(tbl) full_name(cfg$cdm_schema, tbl)
  ref  <- function(tbl) full_name(cfg$ref_schema, tbl)
  work <- function(tbl) tbl

  work_tbl <- function(name) {
    if (exists(name, envir = mat_tables)) return(get(name, envir = mat_tables))
    name
  }

  # Quarterly table resolution (from codelists.R logic)
  cdm_quarterly <- function(base_table) {
    cdm(get_quarterly_table(base_table, cfg$study_end))
  }
  cdm_src <- function(base_table) {
    if (isTRUE(cfg$use_quarterly_tables)) cdm_quarterly(base_table)
    else cdm(base_table)
  }

  list(full_name = full_name, cdm = cdm, ref = ref, work = work,
       work_tbl = work_tbl, cdm_src = cdm_src, cdm_quarterly = cdm_quarterly)
}

# ---- Load code-list CSVs into Spark temp views ----
# Code-list files live on the server filesystem (/mnt/code/codelist/) as CSVs.
# R can read these directly, but Spark executors cannot access the driver's
# local filesystem. So we read each CSV in R and push it to Spark as a temp
# view via a SQL VALUES clause.
load_csv_codelists <- function(conn, cfg) {
  if (!isTRUE(cfg$use_csv_codelists)) return(invisible(NULL))

  csv_map <- cfg$codelist_csv_map
  # The 5 cohort-critical codelists - pipeline cannot proceed without these
  required <- c(cfg$cl_mm_dx, cfg$cl_mm_therapy, cfg$cl_preg,
                cfg$cl_clintrial, cfg$cl_other_malig)

  log_msg("Loading code lists from CSV: ", cfg$codelist_dir)

  for (tbl_name in names(csv_map)) {
    csv_file <- csv_map[[tbl_name]]
    csv_path <- file.path(cfg$codelist_dir, csv_file)
    tryCatch({
      # Read CSV in R (driver-local filesystem access)
      df <- read.csv(csv_path, stringsAsFactors = FALSE, colClasses = "character")
      df[] <- lapply(df, trimws)
      n <- nrow(df)
      cols <- names(df)
      col_list <- paste(cols, collapse = ", ")

      if (n == 0) {
        sel <- paste(paste0("CAST(NULL AS STRING) AS ", cols), collapse = ", ")
        sql <- glue("CREATE OR REPLACE TEMPORARY VIEW {tbl_name} AS SELECT {sel} WHERE 1=0")
      } else {
        # Build VALUES rows from R data frame
        value_rows <- vapply(seq_len(n), function(i) {
          vals <- vapply(cols, function(c) {
            v <- df[[c]][i]
            if (is.na(v) || v == "") "NULL"
            else paste0("'", gsub("'", "''", v), "'")
          }, character(1))
          paste0("(", paste(vals, collapse = ","), ")")
        }, character(1))
        values_sql <- paste(value_rows, collapse = ",\n        ")
        sql <- glue("CREATE OR REPLACE TEMPORARY VIEW {tbl_name} AS
          SELECT {col_list} FROM VALUES
          {values_sql}
          AS t({col_list})")
      }

      DBI::dbExecute(conn$con, sql)
      log_msg("  >> ", tbl_name, " <- ", csv_file, " (", format(n, big.mark = ","), " rows)")
    }, error = function(e) {
      if (tbl_name %in% required) {
        log_msg("  ERROR: Required codelist ", csv_file, " failed: ", conditionMessage(e))
        stop("Cannot proceed without required codelist: ", tbl_name, call. = FALSE)
      }
      log_msg("  WARN: Could not load ", csv_file, ": ", conditionMessage(e))
    })
  }
  log_msg("Code lists loaded")
}

# ---- Databricks connection ----
connect_databricks <- function(cfg) {
  if (!nzchar(cfg$pwd)) {
    stop("DATABRICKS_PWD environment variable is not set.")
  }
  DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 120)
}

db_ping <- function(con) {
  tryCatch({ DBI::dbGetQuery(con, "SELECT 1 AS ok"); TRUE },
           error = function(e) FALSE)
}

with_retry <- function(fn, max_retries = 3L, base_sleep = 5) {
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

# ---- Materialization to personal schema (GSK helper) ----
# Transient Delta/Spark errors worth retrying. CREATE OR REPLACE TABLE
# on a large source can take many minutes; if the target Delta table is
# touched concurrently (auto-optimize, another session, an overlapping
# run) the commit throws MetadataChangedException / a CONCURRENT_*
# error. These are transient - a fresh attempt usually succeeds.
.mat_transient_patterns <- c(
  "DELTA_METADATA_CHANGED", "MetadataChangedException",
  "ConcurrentModificationException", "ConcurrentAppend",
  "ConcurrentDeleteRead", "ConcurrentDeleteDelete",
  "ConcurrentTransaction", "CONCURRENT_", "concurrent update",
  "DELTA_CONCURRENT", "could not be committed"
)

materialize_to_personal_schema <- function(con, view_name, cfg, mat_tables, replace = TRUE) {
  if (!nzchar(cfg$personal_schema)) {
    log_msg("WARN: personal_schema not set, skipping materialization of ", view_name)
    return(FALSE)
  }
  remote_table <- tolower(view_name)
  full_table_name <- if (nzchar(cfg$catalog)) {
    paste0(cfg$catalog, ".", cfg$personal_schema, ".", remote_table)
  } else {
    paste0(cfg$personal_schema, ".", remote_table)
  }

  max_attempts <- as.integer(Sys.getenv("MATERIALIZE_RETRIES", unset = "3"))
  if (is.na(max_attempts) || max_attempts < 1) max_attempts <- 3L

  # replace = FALSE keeps the simple "create if absent" semantics
  # (unchanged behaviour; this is not the failing path).
  if (!isTRUE(replace)) {
    return(tryCatch({
      DBI::dbExecute(con, glue(
        "CREATE TABLE IF NOT EXISTS {full_table_name} AS SELECT * FROM `{view_name}`"))
      DBI::dbExecute(con, glue(
        "CREATE OR REPLACE TEMPORARY VIEW {view_name} AS SELECT * FROM {full_table_name}"))
      assign(view_name, full_table_name, envir = mat_tables)
      log_msg("  >> Materialized ", view_name, " (create-if-absent)")
      TRUE
    }, error = function(e) {
      log_msg("  >> WARN: Materialization of ", view_name,
              " failed (create-if-absent): ", conditionMessage(e))
      FALSE
    }))
  }

  # Staging / atomic-publish (structural fix for DELTA_METADATA_CHANGED):
  # the heavy SELECT lands in a BRAND-NEW staging table (no existing
  # table metadata -> minimal Delta OCC surface for the long write),
  # then a fast CREATE OR REPLACE from that already-materialized
  # staging table swaps it into the final name in seconds (tiny OCC
  # window). This is the same pattern used for LOT_LONG. The 5-column
  # claim grain / null-safe joins are deliberately left unchanged.
  for (attempt in seq_len(max_attempts)) {
    t0 <- Sys.time()
    stg <- paste0(full_table_name, "__stg_",
                  format(t0, "%Y%m%d%H%M%S"), "_", Sys.getpid(),
                  "_a", attempt)
    log_msg("  >> Materializing ", view_name, " -> ", full_table_name,
            " via staging (attempt ", attempt, "/", max_attempts,
            ", started ", format(t0, "%H:%M:%S"), ") ...")
    res <- tryCatch({
      try(DBI::dbExecute(con, glue("DROP TABLE IF EXISTS {stg}")), silent = TRUE)
      # Heavy write to a NEW table (no replace-in-place => not exposed
      # to the concurrent-metadata failure during the long scan).
      DBI::dbExecute(con, glue(
        "CREATE TABLE {stg} AS SELECT * FROM `{view_name}`"))
      el_stg <- round(as.numeric(difftime(Sys.time(), t0, units = "secs")), 1)
      log_msg("  >> Staged ", view_name, " in ", el_stg,
              " s; publishing to ", full_table_name, " ...")
      # Fast swap: source is a materialized table, seconds not minutes.
      DBI::dbExecute(con, glue(
        "CREATE OR REPLACE TABLE {full_table_name} AS SELECT * FROM {stg}"))
      DBI::dbExecute(con, glue(
        "CREATE OR REPLACE TEMPORARY VIEW {view_name} AS SELECT * FROM {full_table_name}"))
      try(DBI::dbExecute(con, glue("DROP TABLE IF EXISTS {stg}")), silent = TRUE)
      assign(view_name, full_table_name, envir = mat_tables)
      el <- round(as.numeric(difftime(Sys.time(), t0, units = "secs")), 1)
      log_msg("  >> Materialized ", view_name, " OK in ", el,
              " s (staged + published, view alias re-pointed)")
      TRUE
    }, error = function(e) e)

    if (isTRUE(res)) return(TRUE)

    # Best-effort: never leak the staging table.
    try(DBI::dbExecute(con, glue("DROP TABLE IF EXISTS {stg}")), silent = TRUE)

    msg <- conditionMessage(res)
    el  <- round(as.numeric(difftime(Sys.time(), t0, units = "secs")), 1)
    transient <- any(vapply(.mat_transient_patterns,
                            function(p) grepl(p, msg, ignore.case = TRUE),
                            logical(1)))
    if (!transient) {
      log_msg("  >> WARN: Materialization of ", view_name,
              " failed after ", el, " s (permanent, not retrying): ", msg)
      return(FALSE)
    }
    if (attempt >= max_attempts) {
      log_msg("  >> WARN: Materialization of ", view_name,
              " still failing after ", attempt, " attempt(s) (", el,
              " s): transient Delta concurrency error. Last: ", msg)
      return(FALSE)
    }
    wait_s <- 15 * (2 ^ (attempt - 1))   # 15s, 30s, 60s ...
    log_msg("  >> Transient Delta concurrency error after ", el,
            " s (attempt ", attempt, "/", max_attempts,
            "). Retrying in ", wait_s, " s. Detail: ", msg)
    Sys.sleep(wait_s)
  }
  FALSE
}

# Run a step's QC query and log the headline metric. Separate from
# run_step() so checkpoint steps can defer QC until AFTER the view is
# materialized: the QC then scans the cheap persisted table instead of
# recomputing the heavy view a second time. Same SQL, same result.
run_qc <- function(con, qc_sql) {
  if (is.null(qc_sql)) return(invisible(NULL))
  qc <- DBI::dbGetQuery(con, qc_sql)
  qc_metric <- colnames(qc)[1]
  qc_value  <- as.character(qc[[1]][1])
  numeric_val <- suppressWarnings(as.numeric(qc_value))
  formatted   <- if (!is.na(numeric_val)) format(numeric_val, big.mark = ",") else qc_value
  log_msg("  >> Result: ", qc_metric, " = ", formatted)
  flush.console()
}

# ---- Step runner ----
# conn is a mutable environment with conn$con (reference semantics for reconnect)
run_step <- function(step_name, sql, conn, cfg, qc_sql = NULL, description = NULL,
                     step_num = NULL, total_steps = NULL, source_tables = NULL) {
  started_at <- Sys.time()

  progress_prefix <- if (!is.null(step_num) && !is.null(total_steps)) {
    sprintf("[Step %d/%d] ", step_num, total_steps)
  } else ""

  step_desc <- if (!is.null(description)) description else step_name
  cat("\n", DASH_60, "\n", sep = "")
  log_msg(progress_prefix, step_desc)

  if (!is.null(source_tables) && length(source_tables) > 0) {
    log_msg("  >> Reading from: ", paste(source_tables, collapse = ", "))
  }
  cat(DASH_60, "\n")
  flush.console()

  tryCatch({
    # Reconnect if stale
    if (!db_ping(conn$con)) {
      log_msg("Connection stale, reconnecting with retry...")
      try(DBI::dbDisconnect(conn$con), silent = TRUE)
      conn$con <- with_retry(function() {
        c <- connect_databricks(cfg)
        log_msg("Reconnected to Databricks")
        c
      }, max_retries = cfg$max_retries, base_sleep = cfg$base_sleep)
    }

    DBI::dbExecute(conn$con, sql)

    run_qc(conn$con, qc_sql)

    ended_at <- Sys.time()
    log_msg("  >> Completed in ", round(as.numeric(difftime(ended_at, started_at, units = "secs")), 1), "s")
    flush.console()

  }, error = function(e) {
    log_msg("STEP FAILED: ", step_name, " - ", conditionMessage(e))
    stop(e)
  })
}
