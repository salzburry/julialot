# ============================================================
# db_utils.R — Connection, retry, naming, materialization
# ============================================================
# No module-level mutable state. All runtime state (connection,
# materialized table mappings) is created in main() and passed
# through function arguments.

# ---- Separators (pre-computed constants) ----
SEP_59  <- strrep("=", 59)
SEP_60  <- strrep("=", 60)
SEP_70  <- strrep("=", 70)
DASH_60 <- strrep("-", 60)
DASH_70 <- strrep("-", 70)

# ---- Logging ----
log_msg <- function(...) {
  cat(sprintf("[%s] ", format(Sys.time(), "%Y-%m-%d %H:%M:%S")), ..., "\n")
  flush.console()
}

# ============================================================
# NAMING HELPERS — closure factory
# ============================================================
# Returns a list of naming functions that close over cfg and
# mat_tables. Callers unpack into locals so that the ~114 glue
# interpolations ({cdm(...)}, {work_tbl(...)}, etc.) in
# pipeline_steps.R require zero changes.
#
# mat_tables is an R environment (reference semantics) so that
# materialize_to_personal_schema() writes are visible to work_tbl().
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
materialize_to_personal_schema <- function(con, view_name, cfg, mat_tables, replace = TRUE) {
  if (!nzchar(cfg$personal_schema)) {
    log_msg("WARN: personal_schema not set, skipping materialization of ", view_name)
    return(FALSE)
  }
  remote_table <- tolower(view_name)
  # Use same catalog-aware naming as full_name() / persistence step
  full_table_name <- if (nzchar(cfg$catalog)) {
    paste0(cfg$catalog, ".", cfg$personal_schema, ".", remote_table)
  } else {
    paste0(cfg$personal_schema, ".", remote_table)
  }
  log_msg("  >> Materializing ", view_name, " to ", full_table_name, "...")

  tryCatch({
    pointer <- tbl(con, view_name)
    # NOTE: createInPersonalSchema (GSK helper) requires a global `con` variable.
    # This is the one unavoidable global write in the module.
    assign("con", con, envir = .GlobalEnv)
    createInPersonalSchema(pointer, remote_table, replace = replace)

    alias_sql <- glue("CREATE OR REPLACE TEMPORARY VIEW {view_name} AS SELECT * FROM {full_table_name}")
    DBI::dbExecute(con, alias_sql)

    assign(view_name, full_table_name, envir = mat_tables)
    log_msg("  >> Materialized successfully (view alias created)")
    TRUE
  }, error = function(e) {
    log_msg("  >> WARN: Materialization failed: ", conditionMessage(e))
    FALSE
  })
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

    if (!is.null(qc_sql)) {
      qc <- DBI::dbGetQuery(conn$con, qc_sql)
      qc_metric <- colnames(qc)[1]
      qc_value  <- as.character(qc[[1]][1])
      numeric_val <- suppressWarnings(as.numeric(qc_value))
      formatted   <- if (!is.na(numeric_val)) format(numeric_val, big.mark = ",") else qc_value
      log_msg("  >> Result: ", qc_metric, " = ", formatted)
      flush.console()
    }

    ended_at <- Sys.time()
    log_msg("  >> Completed in ", round(as.numeric(difftime(ended_at, started_at, units = "secs")), 1), "s")
    flush.console()

  }, error = function(e) {
    log_msg("STEP FAILED: ", step_name, " - ", conditionMessage(e))
    stop(e)
  })
}
