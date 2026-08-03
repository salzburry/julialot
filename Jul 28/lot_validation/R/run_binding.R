# Which LOT run wrote the tables about to be measured.
#
# Both harnesses in this package read a prefix's LOT tables and report numbers
# off them. The tables themselves carry nothing that says which run built them,
# and the build replaces LOT_LONG_FINAL early in the line-criteria phase and
# validates it afterwards - so a rerun that replaced it and then failed leaves
# lines that read perfectly well and were never checked. LOT_BUILD_STATUS is
# the only thing that can tell those numbers from good ones.
#
# The LATEST row, whatever state it reached - not the latest COMPLETE one.
# "complete" is written last of all, so the newest row is the run that last
# touched that prefix's tables. Filtering to complete rows attributes a failed
# rerun's tables to the previous good run, which is the exact case this exists
# to catch. The questions package and the dashboard resolve ownership the same
# way, for the same reason.
#
# SELECT * rather than a column list: STUDY_END was added to this table later,
# and naming it would make a run that predates it unreadable - which reads as
# no run recorded at all, the softest of the failure modes here.

# Case-insensitively, because the two builds do not agree on it: LOT writes
# LOT_BUILD_STATUS with uppercase columns and overall writes build_status with
# lowercase ones.
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
  list(tbl       = tbl,
       run       = one("RUN_ID"),
       state     = state,
       complete  = identical(state, "complete"),
       cohort    = one("INPUT_COHORT_TABLE"),
       study_end = one("STUDY_END"))
}

# A prefix that names one run, and a run that finished.
#
# A blank prefix is refused rather than defaulted. lot_out() resolves it to the
# UNPREFIXED table names, and if some older run's unprefixed tables are sitting
# in the schema they read perfectly - so the measurement would come out of a
# different study with nothing in the output to say so.
#
# An unfinished run stops rather than warns. Everything this package produces
# is a number somebody will quote, and there is nothing about "median 2.1
# lines" that carries which run it came from.
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
  got
}
