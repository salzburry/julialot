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
#
# THE COLUMN NAMES ARE THE WRITER'S, NOT THIS PACKAGE'S. BUILD_STATUS_COLS in
# the LOT engine declares RUN_ID, INPUT_COHORT_TABLE, OBJECT_PREFIX, STATE,
# STUDY_END, CODELIST_WAIVERS_REQUESTED, CODELIST_WAIVERS_APPLIED,
# CONTRACT_DEVIATIONS and UPDATED_AT. There is no COHORT_TABLE and no
# STUDY_START. This SELECT asked for both, so it raised unresolved columns on
# the first real run and never reached the check it was guarding - and the test
# covering it built its fixture from the column names expected here rather than
# from the writer, so it agreed with the mistake instead of catching it.
#
# STUDY_START is therefore NOT checked: the status row does not carry it, and a
# check that cannot be sourced is worse than an absent one. cfg$study_start is
# marked "upstream" in OPEN_QUESTION_SOURCE, so it is recorded on every run as
# the reading the numbers were produced under, and Q1 remains open.
LOT_RULES_EPOCH <- as.Date("2026-08-30")

check_lot_lineage <- function(con, cfg) {
  st <- lot_tbl("LOT_BUILD_STATUS")
  rows <- tryCatch(
    db_q(con, sprintf(
      "SELECT RUN_ID, STATE, UPDATED_AT, INPUT_COHORT_TABLE, STUDY_END,
              CONTRACT_DEVIATIONS
       FROM %s ORDER BY UPDATED_AT DESC LIMIT 5", st)),
    error = function(e) {
      # The one case a flag can waive: the status table could not be READ, so
      # nothing has been shown to be wrong - only unproven.
      if (isTRUE(cfg$lot_allow_unproven_lineage)) {
        log_msg("WARNING: could not read ", st, " - ", conditionMessage(e),
                ". LOT_ALLOW_UNPROVEN_LINEAGE=TRUE, so the run continues over ",
                "a lineage nothing checked.")
        return(NULL)
      }
      stop("LINEAGE ERROR: could not read ", st, " - ", conditionMessage(e),
           "\nThis package will not read LOT tables it cannot attribute to a ",
           "run. If the LOT build wrote its status somewhere else, set ",
           "LOT_PREFIX; to proceed over an unproven lineage set ",
           "LOT_ALLOW_UNPROVEN_LINEAGE=TRUE.", call. = FALSE)
    })
  if (is.null(rows)) return(list(RUN_ID = "unproven"))

  if (!nrow(rows))
    stop("LINEAGE ERROR: ", st, " has no rows, so no LOT run owns the tables ",
         "this package would read.", call. = FALSE)

  r <- rows[1, ]
  problems <- character(0)

  if (!identical(tolower(trimws(as.character(r$STATE))), "complete"))
    problems <- c(problems, sprintf(
      "the newest run (%s) is '%s', not 'complete'", r$RUN_ID, r$STATE))

  if (nzchar(trimws(as.character(r$INPUT_COHORT_TABLE %||% ""))) &&
      !identical(trimws(as.character(r$INPUT_COHORT_TABLE)),
                 trimws(cfg$input_cohort_table)))
    problems <- c(problems, sprintf(
      "it was built over '%s', not the cohort this run was given ('%s')",
      r$INPUT_COHORT_TABLE, cfg$input_cohort_table))

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
      paste0("it finished %s, before the 2026-08-30 rule change, and ",
             "LOT_RULES.md says LOT numbers produced before that date are ",
             "superseded"), format(upd)))

  # Every problem above was CHECKED and found wrong, so every one stops. There
  # is no flag for these: LOT_ALLOW_UNPROVEN_LINEAGE exists for the case where
  # the status table could not be read at all, which is handled above by
  # honouring the setting there and nowhere else.
  if (length(problems))
    stop("LINEAGE ERROR: this package will not read LOT run ", r$RUN_ID,
         " because:\n  - ", paste(problems, collapse = "\n  - "),
         "\nEach of these was checked against ", st,
         " and found wrong, so none of them is waived by a flag. Point the run ",
         "at the LOT build that produced this study's lines, or re-run it.",
         call. = FALSE)

  log_msg("LOT run ", r$RUN_ID, " accepted: ", r$STATE, ", cohort ",
          r$INPUT_COHORT_TABLE, ", study end ", r$STUDY_END)
  as.list(r)
}

`%||%` <- function(a, b) if (is.null(a) || (length(a) == 1L && is.na(a))) b else a
