# Logging, DB helpers, naming, and the step runner for the LOT pipeline.

SEP   <- strrep("=", 70)
DASH  <- strrep("-", 70)

# --- the run log -------------------------------------------------------------
#
# One file per run, and everything the run says goes in it: its log lines, the
# QC and diagnostic tables it print()s, and its warnings, messages and the
# error that stops it. Each of the last three used to reach the console only,
# so the log of a failed run ended mid-step with no reason, and a QC heading
# had nothing under it.
#
# Where it goes, the first of these that can be written to:
#   1. PIPELINE_LOG_FILE - an exact path, so several stages can share one file.
#      Its folder is created. If it cannot be written, there is no run log, and
#      the console says so once: a path somebody named is not quietly swapped.
#   2. OUTPUT_DIR/pipeline_run_<time>_<pid>.log
#   3. /mnt/artifacts/results/pipeline_run_<time>_<pid>.log, the default when
#      OUTPUT_DIR is unset - the folder Domino keeps as a run's results.
#   4. R's temporary folder - said LOUDLY, because R deletes it when the
#      process exits, and a log that is gone by the time anyone looks is a log
#      nobody was told they did not have.
# The process id is in the name because two runs starting in the same second
# used to append to one file. Times are the container's local clock, and the
# announcement names its zone.

.run_log <- new.env(parent = emptyenv())

# Whether a file can be appended to, found by doing it rather than by asking
# whether its folder exists - a folder can exist and refuse the write.
.log_writable <- function(lf) {
  tryCatch({
    dir.create(dirname(lf), showWarnings = FALSE, recursive = TRUE)
    con <- file(lf, open = "a")
    close(con)
    TRUE
  }, error = function(e) FALSE, warning = function(w) FALSE)
}

.log_stamp <- function() format(Sys.time(), "%Y-%m-%d %H:%M:%S")

.resolve_log_file <- function() {
  if (exists("file", envir = .run_log, inherits = FALSE)) return(.run_log$file)
  named <- Sys.getenv("PIPELINE_LOG_FILE", unset = "")
  lf <- if (nzchar(named)) named else {
    d <- Sys.getenv("OUTPUT_DIR", unset = "")
    if (!nzchar(d)) d <- "/mnt/artifacts/results"
    file.path(d, sprintf("pipeline_run_%s_%d.log",
                         format(Sys.time(), "%Y%m%d_%H%M%S"), Sys.getpid()))
  }
  if (!.log_writable(lf)) {
    alt <- if (nzchar(named)) NA_character_ else file.path(tempdir(), basename(lf))
    if (!is.na(alt) && .log_writable(alt)) {
      cat(sprintf(paste0("[%s] [log] WARNING: %s cannot be written. The run log ",
                         "is %s instead, which R DELETES when this process ",
                         "exits - copy it out before then.\n"),
                  .log_stamp(), lf, alt))
      lf <- alt
    } else {
      cat(sprintf(paste0("[%s] [log] WARNING: no run log - %s cannot be ",
                         "written. This run is logged to the console only.\n"),
                  .log_stamp(), lf))
      lf <- NA_character_
    }
  }
  assign("file", lf, envir = .run_log)
  if (!is.na(lf))
    cat(sprintf("[%s] [log] run log -> %s (times are %s)\n", .log_stamp(), lf,
                format(Sys.time(), "%Z")))
  lf
}

# One value as text. cat() does not dispatch S3 methods, so a bit64::integer64
# from the driver printed its bit pattern - a count of 1780 came out of a real
# run as 8.794368e-321 - and a Date printed as a day number, a factor as its
# code. And cat() keeps 7 significant digits, so 100000 printed as 1e+05 and a
# count of 12,000,003 as 1.2e+07: rounded, in a log that is read as the count.
.log_fmt <- function(x) {
  if (is.null(x)) return("NULL")
  if (inherits(x, "integer64")) x <- as.numeric(x)
  v <- if (inherits(x, c("Date", "POSIXt"))) format(x)
       else if (is.factor(x)) as.character(x)
       else if (is.numeric(x)) format(x, scientific = FALSE, trim = TRUE)
       else as.character(x)
  paste(v, collapse = " ")
}

# The pieces of a line, joined the way cat() joined them - one space between -
# except where a piece already brings its own whitespace. Every call site was
# written for cat()'s space and supplies its own too ("LOT code ", x, " is"),
# so the old lines carried two; this keeps one and never joins two words that
# were apart before.
.log_join <- function(parts) {
  if (!length(parts)) return("")
  out <- parts[1]
  for (p in parts[-1]) {
    gap <- grepl("[[:space:]]$", out) || grepl("^[[:space:]]", p) ||
           !nzchar(p) || !nzchar(out)
    out <- paste0(out, if (gap) "" else " ", p)
  }
  out
}

log_msg <- function(...) {
  body <- .log_join(vapply(list(...), .log_fmt, character(1)))
  line <- paste0("[", .log_stamp(), "]", if (nzchar(body)) " ", body)
  cat(line, "\n", sep = "")
  flush.console()
  # Teed, the console IS the file as well, and writing it here too would say
  # everything twice. Otherwise the line is appended, as it always was.
  if (isTRUE(.run_log$teed)) {
    try(flush(.run_log$con), silent = TRUE)
  } else {
    lf <- .resolve_log_file()
    if (!is.na(lf)) try(cat(line, "\n", sep = "", file = lf, append = TRUE),
                        silent = TRUE)
  }
  invisible(line)
}

# Straight into the file, not onto the console - for what the console has
# already shown in its own way (a warning, a message) and the file had not.
.log_to_file_only <- function(...) {
  if (!isTRUE(.run_log$teed)) return(invisible(NULL))
  try({
    cat("[", .log_stamp(), "] ", .log_join(vapply(list(...), .log_fmt,
                                                  character(1))),
        "\n", sep = "", file = .run_log$con)
    flush(.run_log$con)
  }, silent = TRUE)
  invisible(NULL)
}

# Tee the console into the run log for the rest of the process: every print()
# lands in the file as well as on screen. Started once, from an entry point.
start_run_log <- function() {
  if (isTRUE(.run_log$teed)) return(invisible(.run_log$file))
  lf <- .resolve_log_file()
  if (is.na(lf)) return(invisible(NA_character_))
  con <- tryCatch(file(lf, open = "at"), error = function(e) NULL,
                  warning = function(w) NULL)
  if (is.null(con)) return(invisible(NA_character_))
  sink(con, split = TRUE)
  assign("con", con, envir = .run_log)
  assign("teed", TRUE, envir = .run_log)
  invisible(lf)
}

# A run, with what it says on the way out kept. Calling handlers, so they see a
# condition as it is raised and change nothing about what happens to it: a
# warning is still printed by R, and an error still stops the run and runs its
# on.exit status write. Each goes into the file only - R prints its own on the
# console, to stderr, which is exactly the stream the tee does not carry. What an inner tryCatch() or suppressWarnings() handles
# never reaches these, so an expected retry is not logged as an error.
run_logged <- function(expr) {
  withCallingHandlers(expr,
    error = function(e) .log_to_file_only("ERROR: ", conditionMessage(e)),
    warning = function(w) .log_to_file_only("WARNING: ", conditionMessage(w)),
    message = function(m) .log_to_file_only(sub("\n$", "", conditionMessage(m))))
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
# A key comes only from a value that could be an NDC: eleven digits, or ten
# under the 4-4-2 assumption. Anything else gets no key and does not join.
# Optum writes NONE or UNK where a medical claim has no NDC, and left-padding
# those to eleven zeros would let them collide with a real code.
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
  # The window was normalized to YYYY-MM-DD before it got here
  # (pin_study_window / load_inputs), so anything else is a real fault.
  dt <- tryCatch(suppressWarnings(as.Date(v)), error = function(e) NA)
  yr <- if (!is.na(dt)) as.integer(format(dt, "%Y")) else NA_integer_
  if (is.na(dt) || is.na(yr) || yr < 1900) {
    stop("get_quarter_suffix: cannot parse STUDY_END=\"", end_date,
         "\". Use YYYY-MM-DD.")
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

# Whether this error means "the table is not there" rather than "it could not
# be read".
#
# Checks that fall back to a first-run default want the first only; the second
# would fire that fallback against a table full of rows. Narrower than the
# permanent list below, which also covers syntax and column errors. Not
# airtight: a warehouse may answer TABLE_OR_VIEW_NOT_FOUND for an object the
# caller cannot see.
missing_object_error <- function(err) {
  msg <- if (inherits(err, "condition")) conditionMessage(err) else as.character(err)
  length(msg) == 1L && !is.na(msg) &&
    grepl("TABLE_OR_VIEW_NOT_FOUND|Table or view not found|no such table|does not exist", msg, ignore.case = TRUE)
}

# Second question, for the callers that turn "not found" into a first-run
# default: whether the namespace that name sits in can be read at all.
#
# Under Unity Catalog a caller with no grant on an object is told
# TABLE_OR_VIEW_NOT_FOUND, the same words the absent case gives, so a missing
# grant would read as a clean first run. Asking the catalogue for the namespace
# separates them: an absent table in a schema this caller can read lists
# cleanly, while a missing USE CATALOG or USE SCHEMA fails the listing too.
#
# It still cannot see a caller holding USE SCHEMA but no grant on this one
# table; that one needs the grant check in the runbook. NA means the name
# carried no namespace to ask about, so the caller keeps whatever it did
# before.
namespace_readable <- function(con, tbl) {
  ns <- sub("\\.[^.]+$", "", tbl)
  if (identical(ns, tbl) || !nzchar(ns)) return(NA)
  !inherits(tryCatch(db_q(con, paste0("SHOW TABLES IN ", ns)),
                     error = function(e) e), "condition")
}

with_retry <- function(fn, max_retries = lot_config()$max_retries,
                       base_sleep = lot_config()$base_sleep) {
  # Errors not worth a retry. Both the Spark class name and the ODBC wording
  # turn up, depending on how the driver surfaces it, so both are listed. A
  # missing grant is permanent too: no amount of waiting grants a privilege.
  permanent_error_patterns <- c(
    "AnalysisException", "AMBIGUOUS_REFERENCE", "AMBIGUOUS REFERENCE",
    "ParseException", "Syntax error",
    "TABLE_OR_VIEW_NOT_FOUND", "Table or view not found",
    "UNRESOLVED_COLUMN", "Unresolved column", "cannot resolve",
    "not supported", "UNSUPPORTED_FEATURE", "not allowed",
    "INSUFFICIENT_PERMISSIONS", "PERMISSION_DENIED",
    "UnauthorizedAccessException", "does not have permission"
  )
  # A message that says outright it can be retried. The patterns above are
  # substrings, and two of them - "not supported" and "not allowed" - are
  # ordinary English that turns up inside genuinely transient messages. Taking
  # those as permanent kills a recoverable run; taking them as retryable costs
  # at worst five backoffs, so an explicit hint from the server wins.
  retryable_markers <- c("RETRIABLE", "RETRYABLE", "please retry", "try again",
                         "temporarily", "transient", "Connection reset",
                         "timed out", "timeout")
  attempt <- 1
  repeat {
    out <- tryCatch(fn(), error = function(e) e)
    if (!inherits(out, "error")) return(out)
    msg <- conditionMessage(out)
    said_retry <- any(vapply(retryable_markers, function(p)
      grepl(p, msg, ignore.case = TRUE), logical(1)))
    is_permanent <- !said_retry &&
      any(vapply(permanent_error_patterns, function(p) grepl(p, msg, ignore.case = TRUE), logical(1)))
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
# both go that way: in LOT_LONG_BY_LINE that is recorded word for word, and in
# a numeric column it arrives as a floating point literal whose handling
# depends on the warehouse's store-assignment policy.
sql_count <- function(x) {
  if (length(x) != 1L || is.na(x)) return("NULL")
  # A count, so it has to be one. Inf reaches a BIGINT column as the word
  # "Inf", which the warehouse rejects, and 1.5 as "1.5", which it truncates
  # without saying so.
  n <- suppressWarnings(as.numeric(x))
  if (!is.finite(n)) return("NULL")
  # A fraction is not a count. NULL rather than a truncation, so a column that
  # should hold a count never holds a rounded-off one.
  if (n != round(n)) return("NULL")
  format(round(n), scientific = FALSE, trim = TRUE)
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
# integer inside a double's bit pattern, so paste0() and log_msg() print the
# bits and arithmetic without bit64 attached is quietly wrong.
#
# Converted once here rather than at every call site that reads a count. Every
# count this build takes is far below 2^53, so nothing is lost.
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
# the QC below reads it, since the QC names the view.
#
# Each statement is retried on its own, which is right only where each one is
# safe to run twice. A step whose statements are safe only as a sequence - a
# DELETE clearing what the INSERT after it writes - passes retry_as_unit = TRUE
# and is retried as a whole through db_replace().
run_step <- function(con, name, sql, qc = NULL, retry_as_unit = FALSE) {
  log_msg(SEP)
  log_msg("STEP ", name)
  log_msg(SEP)
  t0 <- proc.time()
  if (retry_as_unit) db_replace(con, sql) else for (s in sql) db_exec(con, s)
  elapsed <- (proc.time() - t0)[["elapsed"]]
  log_msg("  Completed in ", round(elapsed, 1), "s")
  if (!is.null(qc) && nzchar(qc)) {
    t1 <- proc.time()
    out <- db_q(con, qc)
    qc_elapsed <- (proc.time() - t1)[["elapsed"]]
    log_msg("  QC completed in ", round(qc_elapsed, 1), "s")
    # A count is printed as the count: print() would show 100000 as 1e+05 and
    # round a large one to 7 digits. Set here only, for this print, so no
    # format() elsewhere - one building SQL, say - sees a different option.
    op <- options(scipen = 100)
    print(out)
    options(op)
  }
  invisible(TRUE)
}

# Write a query's rows to a work-schema table, then point the session view at
# the table. The name does not change, and every later read is a scan rather
# than the query run again.
#
# A Spark temporary view is a query, not a result, and these views sit on top
# of each other, so leaving one lazy costs multiples rather than sums: a view
# read four times by a view read four times is planned sixteen times. At the
# bottom of the LOT chain sits a four-arm scan of `medical` and `rx`.
#
# The table is written straight from the query; creating the view, counting it
# in QC and then copying it would run the query twice. No fallback: carrying on
# with the view gives the same numbers hours later and leaves a declared output
# missing.
materialize <- function(con, step, view, name, body, qc = NULL) {
  tbl <- lot_out(name)
  run_step(con, step,
           c(paste0("CREATE OR REPLACE TABLE ", tbl, " AS\n", body),
             paste0("CREATE OR REPLACE TEMPORARY VIEW ", view,
                    " AS SELECT * FROM ", tbl)),
           qc = qc)
  invisible(tbl)
}
