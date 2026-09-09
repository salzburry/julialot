# Which LOT run these numbers rest on, and whether it can be vouched for.
#
# Everything here derives from a finished LOT run, so the run is identified
# before anything is read. A run that failed part-way, was built over a
# different cohort, or deviated from the LOT contract is refused.
#
# LOT rules changed on 2026-08-30 and earlier numbers are superseded, so a run
# older than that is refused by date as well as by status.
#
# The column names are the WRITER'S. BUILD_STATUS_COLS declares
# INPUT_COHORT_TABLE and no STUDY_START; asking for COHORT_TABLE and
# STUDY_START raised unresolved columns before the check could run.
#
# STUDY_START is therefore not checked HERE - the LOT status row does not carry
# it. The cohort build records its own contract, so read_upstream_settings()
# below reads it there instead. Q1 stays open either way: what that answers is
# which date the data was built on, not which date is right.
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

# What the cohort build actually applied.
#
# Eight of this package's settings are the cohort build's rules, recorded so a
# number can be traced to the definition behind it. Recording the setting alone
# asserted a reading nothing had checked - and the two defaults disagree today:
# this package reads s7.1's body ("study start 01 Jan 2018") and the cohort
# build reads Figures 1 and 2 ("Study start 01 Jan 2016"), which is Q1.
#
# NDMM_RUN_METADATA.CONTRACT_SETTINGS is that build's whole CONTRACT as
# `k=v|k=v`, written by the run that made the cohort. Read here so the study's
# metadata records what shaped the data rather than what this run was told.
#
# Not fatal. A disagreement is an open question, not a broken run, and the
# cohort is what it is either way - so it is named, recorded, and left to the
# study team.
read_upstream_settings <- function(con, cfg) {
  tbl <- cohort_tbl("NDMM_RUN_METADATA")
  rows <- tryCatch(
    db_q(con, sprintf("SELECT CONTRACT_SETTINGS FROM %s
                       ORDER BY RECORDED_AT DESC LIMIT 1", tbl)),
    error = function(e) {
      log_msg("  upstream settings unverified: could not read ", tbl, " - ",
              conditionMessage(e))
      NULL
    })
  if (is.null(rows) || !nrow(rows)) return(NULL)
  s <- trimws(as.character(rows$CONTRACT_SETTINGS[1]))
  if (!nzchar(s) || identical(tolower(s), "na")) return(NULL)
  kv <- strsplit(strsplit(s, "|", fixed = TRUE)[[1]], "=", fixed = TRUE)
  kv <- Filter(function(x) length(x) >= 2L, kv)
  if (!length(kv)) return(NULL)
  out <- setNames(vapply(kv, function(x) paste(x[-1], collapse = "="),
                         character(1)),
                  vapply(kv, `[`, character(1), 1L))
  disagree <- Filter(Negate(is.null), lapply(names(UPSTREAM_SETTING_MAP), function(k) {
    up <- UPSTREAM_SETTING_MAP[[k]]
    got <- if (up %in% names(out)) out[[up]] else NULL
    mine <- paste(as.character(cfg[[k]]), collapse = "|")
    if (is.null(got) || identical(trimws(got), trimws(mine))) NULL
    else sprintf("%s: the cohort was built with %s, this run is set to %s",
                 k, got, mine)
  }))
  if (length(disagree))
    log_msg("WARNING: this run's upstream readings disagree with the cohort ",
            "build that made its input:\n  - ",
            paste(disagree, collapse = "\n  - "),
            "\n  The cohort is what the cohort build made it, so the numbers ",
            "follow ITS values. Both are recorded in S_RUN_METADATA.")
  else
    log_msg("  upstream settings verified against ", tbl)
  out
}
