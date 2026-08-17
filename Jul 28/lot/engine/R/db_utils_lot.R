# Logging, DB helpers, naming, and the step runner for the LOT pipeline.

SEP   <- strrep("=", 70)
DASH  <- strrep("-", 70)

# One run log file, worked out once and remembered. PIPELINE_LOG_FILE wins if
# it is set - that is how the orchestrator shares one file across stages.
# Otherwise a timestamped file under OUTPUT_DIR, or tempdir() if that fails.
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
  # cat() does not dispatch S3 methods. So a bit64::integer64 from the driver
  # is written as its raw bit pattern: a count of 1780 came out of a real run
  # as 8.794368e-321. format() does dispatch, so coerce first. db_q() converts
  # on the way out too. This catches anything reaching a message another way.
  a <- lapply(list(...), function(x)
    if (inherits(x, "integer64")) format(as.numeric(x), scientific = FALSE) else x)
  prefix <- sprintf("[%s] ", format(Sys.time(), "%Y-%m-%d %H:%M:%S"))
  do.call(cat, c(list(prefix), a, "\n"))
  flush.console()
  try({
    lf <- .resolve_log_file()
    do.call(cat, c(list(prefix), a, "\n", file = lf, append = TRUE))
  }, silent = TRUE)
}

stop_if_blank <- function(x, msg) {
  if (!nzchar(x)) stop(msg)
}

# wrk() and cdm_src() take no cfg argument, so the config is shared state.
# This makes that plain, and says so when it is missing. Otherwise a run fails
# with "object 'cfg' not found" deep inside a step.
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

# The claim side of an NDC join.
#
# A key comes only from a value that could BE an NDC: eleven digits, or ten
# under the 4-4-2 assumption. Anything else gets no key and does not join,
# which is what a join is for. Optum writes NONE or UNK where a medical claim
# has no NDC - 1.2bn rows of them. Left-padding those to eleven zeros and
# hoping nothing collided is what made a shape check feel necessary.
ndc_key <- function(col) {
  d <- paste0("regexp_replace(coalesce(cast(", col, " as string),''), '[^0-9]', '')")
  paste0("CASE WHEN ", d, " RLIKE '^0+$' THEN NULL",
         " WHEN length(", d, ") = 11 THEN ", d,
         " WHEN length(", d, ") = 10 THEN concat('0', ", d, ") END")
}

full_name <- function(schema, object) {
  cfg <- lot_config()
  paste0(cfg$catalog, ".", schema, ".", object)
}

cdm <- function(tbl) full_name(lot_config()$cdm_schema, tbl)
wrk <- function(tbl) full_name(lot_config()$work_schema, tbl)

# LOT's own outputs carry the cohort's prefix, so two cohorts can be built into
# one schema without the second overwriting the first. The cohort table itself
# goes through wrk(). It is named by the cohort build, not by this one.
lot_out <- function(tbl) {
  cfg <- lot_config()
  prefix <- if (is.null(cfg$object_prefix)) "" else cfg$object_prefix
  full_name(cfg$work_schema, paste0(prefix, tbl))
}

get_quarter_suffix <- function(end_date) {
  v  <- trimws(as.character(end_date))
  # ISO first. tryCatch because as.Date errors rather than returning NA on a
  # string matching none of its standard formats, which would skip the
  # recovery below.
  dt <- tryCatch(suppressWarnings(as.Date(v)), error = function(e) NA)
  yr <- if (!is.na(dt)) as.integer(format(dt, "%Y")) else NA_integer_
  # as.Date("30-06-2025") does not return NA. It gives year 0030. So treat an
  # implausible year as a parse failure, and retry the common non-ISO (Excel)
  # layouts. A STUDY_END that Excel reformatted still works.
  if (is.na(dt) || is.na(yr) || yr < 1900) {
    cand <- Filter(Negate(is.na), lapply(
      c("%d-%m-%Y", "%d/%m/%Y", "%m/%d/%Y", "%Y/%m/%d", "%m-%d-%Y"),
      function(fmt) {
        d2 <- tryCatch(as.Date(v, format = fmt), error = function(e) NA)
        if (!is.na(d2) && as.integer(format(d2, "%Y")) >= 1900) d2 else NA
      }))
    # 03/04/2025 is 3 April day-first and 4 March month-first. Nothing in the
    # string says which was meant. Taking the first format that parses picks
    # one quietly, and the two fall in different quarters - a different set of
    # CDM tables for the whole study. Refuse instead.
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

# Is this error "the table is not there", rather than "it could not be read"?
#
# Checks that fall back to a first-run default want the first only. The second
# would fire that fallback against a table full of rows. Narrower than the
# permanent list below, which also covers syntax and column errors - a wrong
# query, not an absent table. Not airtight: a warehouse may answer
# TABLE_OR_VIEW_NOT_FOUND for an object the caller cannot see.
missing_object_error <- function(err) {
  msg <- if (inherits(err, "condition")) conditionMessage(err) else as.character(err)
  length(msg) == 1L && !is.na(msg) &&
    grepl("TABLE_OR_VIEW_NOT_FOUND|Table or view not found|no such table|does not exist", msg, ignore.case = TRUE)
}

with_retry <- function(fn, max_retries = lot_config()$max_retries,
                       base_sleep = lot_config()$base_sleep) {
  # Errors not worth a retry. Both the Spark class name and the ODBC wording
  # turn up, depending on how the driver surfaces it, so both are listed.
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

# The retry wraps the whole call, so what it retries must be safe to run twice.
# One CREATE OR REPLACE or DELETE is. An INSERT on its own is not.
db_exec_once <- function(con, sql) DBI::dbExecute(con, sql)

db_exec <- function(con, sql) {
  with_retry(function() db_exec_once(con, sql))
}

# A count as plain digits. as.character(1e5) is "1e+05", and glue and paste0
# both go that way. In LOT_LONG_BY_LINE that is recorded word for word, and
# wrong. In a numeric column it arrives as a floating point literal, and what
# the warehouse makes of that depends on its store-assignment policy, which is
# untested here. Sending digits removes the question either way.
sql_count <- function(x) {
  if (length(x) != 1L || is.na(x)) return("NULL")
  format(x, scientific = FALSE, trim = TRUE)
}

# A string as a SQL literal: quoted, inner quotes doubled, and NULL rather than
# 'NA' when there is nothing to write. sql_count, for text columns.
sql_text <- function(x) {
  if (length(x) != 1L || is.na(x)) return("NULL")
  paste0("'", gsub("'", "''", as.character(x), fixed = TRUE), "'")
}

# Retry a DELETE and its INSERT together, so the write can be run twice safely.
# Retried apart, an INSERT whose answer was lost is sent twice, and the DELETE
# that would have cleared the first has already run.
db_replace <- function(con, ...) {
  sqls <- c(...)
  with_retry(function() for (s in sqls) db_exec_once(con, s))
  invisible(TRUE)
}

# A BIGINT comes back from the driver as bit64::integer64, which holds a 64-bit
# integer inside a double's bit pattern. paste0() and log_msg() then print the
# bits, so a count of 1780 shows as 8.794368e-321. Arithmetic on it without
# bit64 attached is quietly wrong.
#
# Converted once, here, rather than at each of the forty-odd call sites that
# read a count. Every count this build takes is far below 2^53, so nothing is
# lost. A value above that would lose precision, and there is none.
.unint64 <- function(d) {
  if (!is.data.frame(d) || !ncol(d)) return(d)
  for (j in seq_along(d))
    if (inherits(d[[j]], "integer64")) d[[j]] <- as.numeric(d[[j]])
  d
}

db_q <- function(con, sql) {
  .unint64(with_retry(function() DBI::dbGetQuery(con, sql)))
}

# sql may be more than one statement. They run in order and are timed as one
# step. materialize() uses that to write a table and repoint its view before
# the QC below reads it. The QC names the view, so repointing afterwards would
# have it read the query the table was just written to replace.
run_step <- function(con, name, sql, qc = NULL) {
  log_msg(SEP)
  log_msg("STEP ", name)
  log_msg(SEP)
  t0 <- proc.time()
  for (s in sql) db_exec(con, s)
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

# Write a query's rows to a work-schema table, then point the session view at
# the table. Nothing that reads it has to know. The name does not change, and
# every later read is a scan rather than the query run again.
#
# A Spark temporary view is a query, not a result. These views sit on top of
# each other, so leaving one lazy costs multiples rather than sums: a view read
# four times by a view read four times is planned sixteen times. At the bottom
# of the LOT chain sits a four-arm scan of `medical` and `rx`.
#
# The table is written straight from the query. The other way - create the
# view, count it in QC, then copy it to a table - runs the query once for the
# count and again for the copy.
#
# No fallback. Carrying on with the view would give the same numbers, turn
# minutes into hours without saying so, and leave a table the run declares as
# an output missing.
materialize <- function(con, step, view, name, body, qc = NULL) {
  tbl <- lot_out(name)
  run_step(con, step,
           c(paste0("CREATE OR REPLACE TABLE ", tbl, " AS\n", body),
             paste0("CREATE OR REPLACE TEMPORARY VIEW ", view,
                    " AS SELECT * FROM ", tbl)),
           qc = qc)
  invisible(tbl)
}
