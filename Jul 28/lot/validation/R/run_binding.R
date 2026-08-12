# Which LOT run wrote the tables about to be measured.
#
# The tables carry nothing saying which run built them, and the build replaces
# LOT_LONG_FINAL early and validates it afterwards - so a rerun that replaced
# it and then failed leaves lines that read perfectly well and were never
# checked. LOT_BUILD_STATUS is the only thing that can tell them apart.
#
# The latest row, whatever state it reached, not the latest complete one.
# "complete" is written last, so the newest row is the run that last touched
# the tables. Filtering to complete rows would credit a failed rerun's tables
# to the previous good run. The questions and the dashboard do the same.
#
# SELECT * rather than a column list: STUDY_END was added later, and naming it
# would make an older run's table unreadable - which reads as no run at all.

# Case-insensitively: LOT writes uppercase columns, overall writes lowercase.
.bind_col <- function(d, name) {
  if (is.null(d) || !is.data.frame(d)) return(NULL)
  i <- match(toupper(name), toupper(names(d)))
  if (is.na(i)) NULL else d[[i]]
}

lot_run_row <- function(con, prefix) {
  tbl <- wrk(paste0(prefix, "LOT_BUILD_STATUS"))
  d <- tryCatch(db_q(con, paste0(
    "SELECT * FROM ", tbl, " ORDER BY UPDATED_AT DESC LIMIT 1")),
    error = function(e) NULL)
  if (is.null(d) || nrow(d) == 0) return(NULL)
  one <- function(nm) {
    v <- .bind_col(d, nm)
    if (is.null(v)) NA_character_ else as.character(v[1])
  }
  state <- tolower(trimws(one("STATE")))
  dev <- one("CONTRACT_DEVIATIONS")
  list(tbl        = tbl,
       run        = one("RUN_ID"),
       state      = state,
       complete   = identical(state, "complete"),
       cohort     = one("INPUT_COHORT_TABLE"),
       study_end  = one("STUDY_END"),
       # NA on a table predating the column - a run built before the override
       # existed, so it cannot have deviated.
       deviations = if (is.na(dev) || !nzchar(trimws(dev))) character(0)
                    else strsplit(trimws(dev), "|", fixed = TRUE)[[1]])
}

# The run's own metadata row: what it was built with, and which cohort it read.
#
# RUN_TIMESTAMP is this table's clock - there is no RECORDED_AT. Ordering by a
# column that is not there fails inside the tryCatch, returns NULL, and reads
# as "an older run" - which is how a guard elsewhere passed without running.
lot_run_meta <- function(con, prefix) {
  tbl <- wrk(paste0(prefix, "LOT_RUN_METADATA"))
  d <- tryCatch(db_q(con, paste0(
    "SELECT * FROM ", tbl, " ORDER BY RUN_TIMESTAMP DESC LIMIT 1")),
    error = function(e) e)
  # NULL means "no run recorded", and callers take that as a build too old to
  # have written one. A table that could not be READ is this check not running,
  # and returning NULL for it lets a comparison artefact out with its cohort
  # attempt unestablished.
  if (inherits(d, "condition")) {
    if (!grepl("TABLE_OR_VIEW_NOT_FOUND|Table or view not found|no such table|does not exist",
               conditionMessage(d), ignore.case = TRUE))
      stop("Could not read ", tbl, ": ", conditionMessage(d),
           "\nThat table is what ties these outputs to the cohort attempt they ",
           "were built over. A build old enough to have written none says so ",
           "specifically; this did not.", call. = FALSE)
    return(NULL)
  }
  if (nrow(d) == 0) return(NULL)
  one <- function(nm) {
    v <- .bind_col(d, nm)
    if (is.null(v)) NA_character_ else as.character(v[1])
  }
  list(tbl        = tbl,
       run        = one("RUN_ID"),
       settings   = one("CONTRACT_SETTINGS"),
       # The pair, not the id alone: a cohort re-run keeps its id and
       # rewrites its rows, and UPDATED_AT is what moves.
       cohort_run = one("COHORT_RUN_ID"),
       cohort_at  = one("COHORT_STAMP"))
}

# What the measured run was built with, not what this package is set to.
#
# max_lot decides how many lines the benchmarks ask for. Taking it from cfg
# would ask for lines the run never built, or leave out lines it did.
# CONTRACT_SETTINGS records the run's own values; the dashboard reads it the
# same way. NULL when there is nothing to read, so the caller can say so.
lot_run_contract <- function(con, prefix, key) {
  m <- lot_run_meta(con, prefix)
  if (is.null(m) || is.na(m$settings)) return(NULL)
  hit <- regmatches(m$settings,
                    regexpr(paste0("(^|\\|)", key, "=[^|]*"), m$settings))
  if (!length(hit)) return(NULL)
  sub(paste0("^\\|?", key, "="), "", hit)
}

# A prefix that names one run, and a run that finished.
#
# A blank prefix is refused, not defaulted: lot_out() resolves it to the
# UNPREFIXED names, and an older run's unprefixed tables read perfectly.
#
# An unfinished run stops rather than warns. Everything here is a number
# somebody will quote, and "median 2.1 lines" carries no run with it.
require_lot_run <- function(con, prefix, ignore_env = "") {
  if (!nzchar(prefix))
    stop("OBJECT_PREFIX is not set. It resolves to the unprefixed table names, ",
         "which are either absent or some other run's - and either way the ",
         "numbers would not be this study's. Set it to the prefix of the LOT ",
         "run to measure.", call. = FALSE)
  if (!grepl("^[A-Za-z][A-Za-z0-9_]*_$", prefix))
    stop("OBJECT_PREFIX '", prefix, "' should be a name ending in '_'.",
         call. = FALSE)
  got <- lot_run_row(con, prefix)
  if (is.null(got))
    stop("No LOT run is recorded in ", wrk(paste0(prefix, "LOT_BUILD_STATUS")),
         ", so nothing says which run wrote the tables under prefix '", prefix,
         "' or whether it finished. Run the LOT build first.", call. = FALSE)
  if (!isTRUE(got$complete)) {
    if (!identical(toupper(trimws(Sys.getenv(ignore_env, unset = ""))), "TRUE"))
      stop("The last LOT run on prefix '", prefix, "' (", got$run,
           ") is marked '", got$state, "' in ", got$tbl, ", so it is the run ",
           "that last wrote these tables and it did not finish. It replaces ",
           "LOT_LONG_FINAL before it validates it, so the lines on disk may be ",
           "that run's - built, unvalidated, left behind. Re-run the build, or ",
           "set ", ignore_env, "=TRUE if you know it failed before it wrote ",
           "anything.", call. = FALSE)
    log_msg("WARNING: the last LOT run (", got$run, ") is marked '", got$state,
            "' and ", ignore_env, " is set. If it got as far as replacing ",
            "LOT_LONG_FINAL, these measurements are that run's.")
  }
  # A run built with LOT_CONTRACT_OVERRIDE is a sensitivity cell - a different
  # algorithm. Its distributions are not this study's. The sweep reads those
  # through lot_run_row(), where they belong.
  if (length(got$deviations))
    stop("The LOT run on prefix '", prefix, "' (", got$run, ") was built with ",
         "LOT_CONTRACT_OVERRIDE, so it is not the contract algorithm:\n  ",
         paste(got$deviations, collapse = "\n  "),
         "\nIts distributions are an alternative build's. Comparing them to a ",
         "published figure would attribute the difference to this cohort ",
         "rather than to the setting that was changed. Point this at the ",
         "study's own prefix.", call. = FALSE)
  got
}
