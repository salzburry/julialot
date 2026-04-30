# ============================================================
# db_utils_lot.R — Logging, DB helpers, naming, step runner
# ============================================================
# Extracted from lot_program.R during modularization.
# Requires: cfg (from config_lot.R)
# ============================================================

SEP   <- strrep("=", 70)
DASH  <- strrep("-", 70)

log_msg <- function(...) {
  cat(sprintf("[%s] ", format(Sys.time(), "%Y-%m-%d %H:%M:%S")), ..., "\n")
  flush.console()
}

stop_if_blank <- function(x, msg) {
  if (!nzchar(x)) stop(msg)
}

full_name <- function(schema, object) {
  paste0(cfg$catalog, ".", schema, ".", object)
}

cdm <- function(tbl) full_name(cfg$cdm_schema, tbl)
wrk <- function(tbl) full_name(cfg$work_schema, tbl)

get_quarter_suffix <- function(end_date) {
  dt <- as.Date(end_date)
  year <- as.integer(format(dt, "%Y"))
  qtr  <- ceiling(as.integer(format(dt, "%m")) / 3)
  sprintf("%dq%d", year, qtr)
}

cdm_src <- function(base_tbl) {
  if (isTRUE(cfg$use_quarterly_tables)) {
    qsuffix <- get_quarter_suffix(cfg$study_end)
    cdm(paste0("t_", base_tbl, "_", qsuffix))
  } else {
    cdm(base_tbl)
  }
}

with_retry <- function(fn, max_retries = cfg$max_retries, base_sleep = cfg$base_sleep) {
  # Permanent (non-retryable) error patterns. Mix of Databricks/Spark
  # internal class names (e.g. AnalysisException, TABLE_OR_VIEW_NOT_FOUND)
  # and user-visible ODBC messages (e.g. "Table or view not found") —
  # both forms appear depending on how the driver surfaces the error.
  # The space-separated forms were added after observing the ATTRITION
  # tab's missing-table probe eat 35s of retry backoff because only the
  # underscore form was listed.
  permanent_error_patterns <- c(
    "AnalysisException", "AMBIGUOUS_REFERENCE", "AMBIGUOUS REFERENCE",
    "ParseException", "Syntax error",
    "TABLE_OR_VIEW_NOT_FOUND", "Table or view not found",
    "UNRESOLVED_COLUMN", "Unresolved column", "cannot resolve",
    "not supported", "UNSUPPORTED_FEATURE", "not allowed"
  )
  attempt <- 1
  repeat {
    out <- tryCatch(fn(), error = function(e) e)
    if (!inherits(out, "error")) return(out)
    msg <- conditionMessage(out)
    is_permanent <- any(vapply(permanent_error_patterns, function(p) grepl(p, msg, ignore.case = TRUE), logical(1)))
    if (is_permanent || attempt >= max_retries) {
      if (is_permanent && attempt < max_retries) {
        log_msg("Permanent error (not retrying): ", msg)
      }
      stop(out)
    }
    sleep_s <- base_sleep * (2^(attempt - 1))
    log_msg("Retryable failure: ", msg)
    log_msg("Retrying in ", sleep_s, "s (attempt ", attempt + 1, "/", max_retries, ")")
    Sys.sleep(sleep_s)
    attempt <- attempt + 1
  }
}

db_exec <- function(con, sql) {
  with_retry(function() DBI::dbExecute(con, sql))
}

db_q <- function(con, sql) {
  with_retry(function() DBI::dbGetQuery(con, sql))
}

run_step <- function(con, name, sql, qc = NULL) {
  log_msg(SEP)
  log_msg("STEP ", name)
  log_msg(SEP)
  t0 <- proc.time()
  db_exec(con, sql)
  elapsed <- (proc.time() - t0)[["elapsed"]]
  log_msg("  Completed in ", round(elapsed, 1), "s")
  if (!is.null(qc) && nzchar(qc)) {
    t1 <- proc.time()
    out <- db_q(con, qc)
    qc_elapsed <- (proc.time() - t1)[["elapsed"]]
    log_msg("  QC completed in ", round(qc_elapsed, 1), "s")
    print(out)
  }
  invisible(TRUE)
}
