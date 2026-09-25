# Logging, DB helpers, naming, and the step runner for the NDMM cohort build.
# wrk() differs from lot's: it adds the cohort prefix.

SEP   <- strrep("=", 70)

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
# This makes that explicit and says so when it is missing, instead of failing
# with "object 'cfg' not found" deep inside a step.
set_lot_config <- function(x) {
  assign("cfg", x, envir = globalenv())
  invisible(x)
}

ndmm_config <- function() {
  if (!exists("cfg", envir = globalenv()))
    stop("No NDMM config. build_ndmm() calls set_lot_config() before any step.",
         call. = FALSE)
  get("cfg", envir = globalenv())
}

# The claim side of an NDC join.
#
# The key is built from the value's DIGITS - separators and letters are
# stripped first, because that is what claim systems do to an NDC - and only
# ten or eleven of them get a key: eleven as they stand, ten padded under the
# 4-4-2 assumption. Any other count gets no key and simply does not join, which
# is what a join is for. So a value carrying exactly ten or eleven digits keys
# on them even if letters ride along; a value with any other digit count never
# keys, whatever else it contains. Optum writes NONE or UNK where a medical
# claim has no NDC - 1.2bn rows of them - and left-padding those to eleven
# zeros and hoping nothing collided is what made a shape check feel necessary.
ndc_key <- function(col) {
  d <- paste0("regexp_replace(coalesce(cast(", col, " as string),''), '[^0-9]', '')")
  paste0("CASE WHEN ", d, " RLIKE '^0+$' THEN NULL",
         " WHEN length(", d, ") = 11 THEN ", d,
         " WHEN length(", d, ") = 10 THEN concat('0', ", d, ") END")
}

full_name <- function(schema, object) {
  cfg <- ndmm_config()
  paste0(cfg$catalog, ".", schema, ".", object)
}

cdm <- function(tbl) full_name(ndmm_config()$cdm_schema, tbl)
# Every table this build touches carries the cohort prefix - what it reads as
# well as what it writes, since they all belong to one cohort. Steps call wrk()
# and pick up the prefix without knowing it is there.
wrk <- function(tbl) {
  cfg <- ndmm_config()
  prefix <- if (is.null(cfg$object_prefix)) "" else cfg$object_prefix
  full_name(cfg$work_schema, paste0(prefix, tbl))
}

get_quarter_suffix <- function(end_date) {
  v  <- trimws(as.character(end_date))
  # ISO first. tryCatch because as.Date errors, rather than returning NA, on a
  # string matching none of its standard formats - which would skip the
  # recovery below.
  dt <- tryCatch(suppressWarnings(as.Date(v)), error = function(e) NA)
  yr <- if (!is.na(dt)) as.integer(format(dt, "%Y")) else NA_integer_
  # as.Date("30-06-2025") does not return NA - it yields year 0030.
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
  cfg <- ndmm_config()
  if (isTRUE(cfg$use_quarterly_tables)) {
    qsuffix <- get_quarter_suffix(cfg$study_end)
    cdm(paste0("t_", base_tbl, "_", qsuffix))
  } else {
    cdm(base_tbl)
  }
}

with_retry <- function(fn, max_retries = ndmm_config()$max_retries,
                       base_sleep = ndmm_config()$base_sleep) {
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

# Is this error "the table is not there", as opposed to "it could not be read"?
#
# Checks that fall back to a first-run default need the first only; the second
# fires that fallback against a table full of rows. Narrower than the permanent
# list above, which includes syntax and column errors - a wrong query, not an
# absent table. Not airtight: a warehouse may answer TABLE_OR_VIEW_NOT_FOUND
# for an object the caller cannot see.
missing_object_error <- function(err) {
  msg <- if (inherits(err, "condition")) conditionMessage(err) else as.character(err)
  length(msg) == 1L && !is.na(msg) &&
    grepl("TABLE_OR_VIEW_NOT_FOUND|Table or view not found|no such table|does not exist", msg, ignore.case = TRUE)
}

# The retry wraps the whole call, so what it retries must be safe to run twice.
# One CREATE OR REPLACE or DELETE is; an INSERT on its own is not.
db_exec_once <- function(con, sql) DBI::dbExecute(con, sql)

db_exec <- function(con, sql) {
  with_retry(function() db_exec_once(con, sql))
}

# A count as plain digits. as.character(1e5) is "1e+05", and glue and paste0
# both take that route - in LOT_LONG_BY_LINE that is recorded verbatim and
# wrong. See the README for the numeric-column case.
sql_count <- function(x) {
  if (length(x) != 1L || is.na(x)) return("NULL")
  format(x, scientific = FALSE, trim = TRUE)
}

# A string as a SQL literal: quoted, quotes doubled, and NULL rather than 'NA'
# when there is nothing to write. sql_count's counterpart for text columns.
sql_text <- function(x) {
  if (length(x) != 1L || is.na(x)) return("NULL")
  paste0("'", gsub("'", "''", as.character(x), fixed = TRUE), "'")
}

# Retry a DELETE and its INSERT together, so the write stays idempotent.
# Retried apart, an INSERT whose answer was lost is sent twice and the DELETE
# that would have cleared the first has already run.
db_replace <- function(con, ...) {
  sqls <- c(...)
  with_retry(function() for (s in sqls) db_exec_once(con, s))
  invisible(TRUE)
}

# A BIGINT comes back from the driver as bit64::integer64, which stores a
# 64-bit integer inside a double's bit pattern. paste0() and log_msg() then
# render the bits, so a count of 1780 prints as 8.794368e-321 - and any
# arithmetic on it without bit64 attached is silently wrong.
#
# Converted once, here, rather than at each of the forty-odd call sites that
# read a count. Every count this build takes is far below 2^53, so nothing is
# lost; a value above that would lose precision, and there is none.
.unint64 <- function(d) {
  if (!is.data.frame(d) || !ncol(d)) return(d)
  for (j in seq_along(d))
    if (inherits(d[[j]], "integer64")) d[[j]] <- as.numeric(d[[j]])
  d
}

db_q <- function(con, sql) {
  .unint64(with_retry(function() DBI::dbGetQuery(con, sql)))
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
    # A count is printed as the count: print() would show 100000 as 1e+05 and
    # round a large one to 7 digits. Set here only, for this print, so no
    # format() elsewhere - one building SQL, say - sees a different option.
    op <- options(scipen = 100)
    print(out)
    options(op)
  }
  invisible(TRUE)
}
