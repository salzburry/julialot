# Which LOT run these numbers rest on, and whether it can be vouched for.
#
# This package derives everything from a finished LOT run. A number read off a
# run that failed part-way, that was built over a different cohort, or that
# deviated from the LOT contract is not this study's number, and nothing
# downstream can tell. So the run is identified before anything is read.
#
# LOT_RULES.md carries a banner: three rules changed on 2026-08-30 and "LOT
# numbers produced before that date are superseded". A run older than that is
# refused by date as well as by status.
LOT_RULES_EPOCH <- as.Date("2026-08-30")

check_lot_lineage <- function(con, cfg) {
  st <- lot_tbl("LOT_BUILD_STATUS")
  rows <- tryCatch(
    db_q(con, sprintf(
      "SELECT RUN_ID, STATE, UPDATED_AT, COHORT_TABLE, STUDY_START, STUDY_END,
              CONTRACT_DEVIATIONS
       FROM %s ORDER BY UPDATED_AT DESC LIMIT 5", st)),
    error = function(e)
      stop("LINEAGE ERROR: could not read ", st, " - ", conditionMessage(e),
           "\nThis package will not read LOT tables it cannot attribute to a ",
           "run. If the LOT build wrote its status somewhere else, set ",
           "LOT_PREFIX.", call. = FALSE))

  if (!nrow(rows))
    stop("LINEAGE ERROR: ", st, " has no rows, so no LOT run owns the tables ",
         "this package would read.", call. = FALSE)

  r <- rows[1, ]
  problems <- character(0)

  if (!identical(tolower(trimws(as.character(r$STATE))), "complete"))
    problems <- c(problems, sprintf(
      "the newest run (%s) is '%s', not 'complete'", r$RUN_ID, r$STATE))

  if (nzchar(trimws(as.character(r$COHORT_TABLE %||% ""))) &&
      !identical(trimws(as.character(r$COHORT_TABLE)),
                 trimws(cfg$input_cohort_table)))
    problems <- c(problems, sprintf(
      "it was built over '%s', not the cohort this run was given ('%s')",
      r$COHORT_TABLE, cfg$input_cohort_table))

  dev <- trimws(as.character(r$CONTRACT_DEVIATIONS %||% ""))
  if (nzchar(dev) && !identical(tolower(dev), "na"))
    problems <- c(problems, sprintf("it deviated from the LOT contract: %s", dev))

  if (!identical(trimws(as.character(r$STUDY_END)), cfg$study_end))
    problems <- c(problems, sprintf(
      "its STUDY_END is %s and this package is set to %s, so the two read ",
      r$STUDY_END, cfg$study_end))

  upd <- suppressWarnings(as.Date(substr(as.character(r$UPDATED_AT), 1, 10)))
  if (!is.na(upd) && upd < LOT_RULES_EPOCH)
    problems <- c(problems, sprintf(
      "it finished %s, before the 2026-08-30 rule change; LOT_RULES.md says ",
      "LOT numbers produced before that date are superseded", upd))

  if (length(problems)) {
    msg <- paste0("LINEAGE ERROR: this package will not read LOT run ",
                  r$RUN_ID, " because:\n  - ",
                  paste(problems, collapse = "\n  - "),
                  "\nSet LOT_ALLOW_UNPROVEN_LINEAGE=TRUE to accept a lineage ",
                  "that could not be CHECKED. A lineage shown to be wrong is ",
                  "not accepted by that flag and still stops.")
    checkable <- !grepl("could not", msg)
    if (checkable) stop(msg, call. = FALSE)
  }

  log_msg("LOT run ", r$RUN_ID, " accepted: ", r$STATE, ", cohort ",
          r$COHORT_TABLE, ", ", r$STUDY_START, " to ", r$STUDY_END)
  as.list(r)
}

`%||%` <- function(a, b) if (is.null(a) || (length(a) == 1L && is.na(a))) b else a
