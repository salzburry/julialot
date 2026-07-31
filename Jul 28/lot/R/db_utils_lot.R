# Logging, DB helpers, naming, and the step runner for the LOT pipeline.

SEP   <- strrep("=", 70)
DASH  <- strrep("-", 70)

# Resolve a single run log file (memoized). Honour PIPELINE_LOG_FILE if
# set (orchestrator shares one file across stages); else timestamped
# file under OUTPUT_DIR (falls back to tempdir()).
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

stop_if_blank <- function(x, msg) {
  if (!nzchar(x)) stop(msg)
}

# The ported rules call wrk() and cdm_src() with no cfg argument, so the config
# is shared state. set_lot_config() makes that explicit and says so when it is
# missing, instead of failing with "object 'cfg' not found" deep in a step.
set_lot_config <- function(x) {
  assign("cfg", x, envir = globalenv())
  invisible(x)
}

lot_config <- function() {
  if (!exists("cfg", envir = globalenv()))
    stop("No LOT config. build_lot() calls set_lot_config() before any step.",
         call. = FALSE)
  get("cfg", envir = globalenv())
}

full_name <- function(schema, object) {
  cfg <- lot_config()
  paste0(cfg$catalog, ".", schema, ".", object)
}

cdm <- function(tbl) full_name(lot_config()$cdm_schema, tbl)
wrk <- function(tbl) full_name(lot_config()$work_schema, tbl)

# LOT's own outputs carry the cohort's prefix, so two cohorts can be built into
# one schema without the second overwriting the first. The cohort table itself
# goes through wrk(): it is named by the cohort build, not by us.
lot_out <- function(tbl) {
  cfg <- lot_config()
  prefix <- if (is.null(cfg$object_prefix)) "" else cfg$object_prefix
  full_name(cfg$work_schema, paste0(prefix, tbl))
}

get_quarter_suffix <- function(end_date) {
  v  <- trimws(as.character(end_date))
  # tryCatch, not just suppressWarnings: as.Date ERRORS on a string matching
  # none of its standard formats rather than returning NA, so "06/30/2025"
  # stopped here and never reached the recovery below - which meant two of the
  # five layouts it lists, the US month-first ones, could not be recovered, and
  # the message at the bottom naming STUDY_END could not be reached either.
  dt <- tryCatch(suppressWarnings(as.Date(v)), error = function(e) NA)  # ISO first
  yr <- if (!is.na(dt)) as.integer(format(dt, "%Y")) else NA_integer_
  # as.Date("30-06-2025") does NOT return NA - it yields year 0030.
  # Treat an implausible year as a parse failure and retry the common
  # non-ISO (Excel) layouts so a reformatted STUDY_END still works.
  if (is.na(dt) || is.na(yr) || yr < 1900) {
    cand <- Filter(Negate(is.na), lapply(
      c("%d-%m-%Y", "%d/%m/%Y", "%m/%d/%Y", "%Y/%m/%d", "%m-%d-%Y"),
      function(fmt) {
        d2 <- tryCatch(as.Date(v, format = fmt), error = function(e) NA)
        if (!is.na(d2) && as.integer(format(d2, "%Y")) >= 1900) d2 else NA
      }))
    # 03/04/2025 is 3 April day-first and 4 March month-first, and nothing in
    # the string says which was meant. Taking the first format that parses
    # picks one silently, and the two fall in different quarters - a different
    # set of CDM tables for the whole study. Refuse instead.
    if (length(unique(vapply(cand, format, character(1)))) > 1L)
      stop("get_quarter_suffix: STUDY_END=\"", end_date, "\" is ambiguous - it ",
           "reads as ", paste(unique(vapply(cand, format, character(1))),
                              collapse = " or "),
           ". Write it as YYYY-MM-DD.", call. = FALSE)
    if (length(cand)) dt <- cand[[1]]
    yr <- if (!is.na(dt)) as.integer(format(dt, "%Y")) else NA_integer_
  }
  if (is.na(dt) || is.na(yr) || yr < 1900) {
    stop("get_quarter_suffix: cannot parse STUDY_END=\"", end_date,
         "\". Use YYYY-MM-DD - Excel may have reformatted it in config.csv.")
  }
  qtr <- ceiling(as.integer(format(dt, "%m")) / 3)
  sprintf("%dq%d", yr, qtr)
}

cdm_src <- function(base_tbl) {
  cfg <- lot_config()
  if (isTRUE(cfg$use_quarterly_tables)) {
    qsuffix <- get_quarter_suffix(cfg$study_end)
    cdm(paste0("t_", base_tbl, "_", qsuffix))
  } else {
    cdm(base_tbl)
  }
}

with_retry <- function(fn, max_retries = lot_config()$max_retries,
                       base_sleep = lot_config()$base_sleep) {
  # Errors worth no retry. Both the Spark class name and the ODBC wording
  # appear, depending on how the driver surfaces it, so list both.
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

# The retry is around the whole call, so what it retries has to be safe to run
# twice. One CREATE OR REPLACE or one DELETE is; an INSERT on its own is not.
db_exec_once <- function(con, sql) DBI::dbExecute(con, sql)

db_exec <- function(con, sql) {
  with_retry(function() db_exec_once(con, sql))
}

# A count, as SQL rather than as R prints it. as.character(1e5) is "1e+05" -
# R uses scientific notation whenever it is shorter, which for a whole number
# means any exact power of ten from 100000 up, and glue and paste0 both take
# that route.
#
# In a string column that is simply recorded wrong: LOT_LONG_BY_LINE would
# carry "1:1e+05" and nothing would object. That is the certain case, and the
# reason this exists. In a numeric column it reaches an INSERT as a floating
# point literal; whether that is stored, refused or truncated is a question
# about the warehouse's store-assignment policy, which has not been tested
# here, so no claim is made about it. Sending digits removes the question.
sql_count <- function(x) {
  if (length(x) != 1L || is.na(x)) return("NULL")
  format(x, scientific = FALSE, trim = TRUE)
}

# Statements that only make sense together, retried together. Written as two
# db_exec calls, a DELETE and an INSERT are retried separately: if the INSERT
# reaches the warehouse but the answer is lost, the retry inserts a second copy
# and the DELETE that would have cleared it has already run. Retrying the pair
# re-runs the DELETE first, so a second attempt lands the same rows once.
db_replace <- function(con, ...) {
  sqls <- c(...)
  with_retry(function() for (s in sqls) db_exec_once(con, s))
  invisible(TRUE)
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
