# Which LOT run these numbers rest on, and whether it can be vouched for.
#
# Everything here derives from a finished LOT run, so the run is identified
# before anything is read. A run that failed part-way, was built over a
# different cohort, or deviated from the LOT contract is refused.
#
# The LOT rules have changed more than once, and numbers built before the last
# change are superseded, so a run older than that is refused by date as well as
# by status. The date is `lot_rules_epoch` (config_223926.R), a setting rather
# than a constant here: it moves whenever the engine's rules do.
#
# The date says WHEN a run executed, not WHAT executed. LOT_CODE_MD5 is the
# exact answer and is opt-in; this one is the floor everyone gets.
#
# The column names are the WRITER'S: BUILD_STATUS_COLS declares
# INPUT_COHORT_TABLE and no STUDY_START, so asking for COHORT_TABLE or
# STUDY_START raises unresolved columns before the check can run. STUDY_START
# is read from the cohort build's own contract instead, by
# read_upstream_settings() below.
# A setting or a status column as a plain trimmed string: blank where it is
# absent, NULL, NA, or the literal "NA" a warehouse NULL reads back as over
# ODBC. Every identity below compares two of these, so an absent value on
# either side is one value - "" - rather than three that are not identical()
# to each other.
as_str <- function(x) {
  v <- trimws(as.character(x %||% "")[1])
  if (is.na(v) || identical(tolower(v), "na")) "" else v
}

# The cohort build's own status, by the convention the LOT engine uses: the
# table is prefixed by hand, with COHORT_PREFIX where set and this run's
# OBJECT_PREFIX otherwise, and named one of two things depending on which build
# wrote it. cohort_tbl() already resolves that prefix.
COHORT_STATUS_TABLES <- c("NDMM_BUILD_STATUS", "build_status")

# Which cohort attempt sits under that name RIGHT NOW. NULL where no status
# table was found - the caller decides what an absence means, because "no
# status here" and "the attempt moved" are different answers.
cohort_build_now <- function(con, cfg) {
  cands <- COHORT_STATUS_TABLES
  named <- as_str(cfg$cohort_status_table %||% "")
  if (nzchar(named)) cands <- named
  for (nm in cands) {
    tbl <- cohort_tbl(nm)
    d <- tryCatch(db_q(con, sprintf(
           "SELECT * FROM %s ORDER BY UPDATED_AT DESC LIMIT 1", tbl)),
         error = function(e) e)
    # Absent is one of the two names not being used, which is ordinary. Any
    # other failure is a status that exists and was not seen, and reading
    # that as absent would let a cohort rebuilt under the same name through
    # on the strength of an outage.
    if (inherits(d, "error")) {
      # A table NAMED by the setting that is not there is a mistake in the
      # setting, not an absence - the engine treats its own
      # COHORT_STATUS_TABLE the same way. Carrying on would end in "no
      # status found", which is true and points away from the cause.
      # Its own class, so the waiver below cannot cover it: a wrong setting
      # is not an unproven lineage, it is a run that was told to read the
      # wrong table.
      if (missing_object_error(d) && nzchar(named))
        stop(errorCondition(paste0(
          "SETTING ERROR: COHORT_STATUS_TABLE names ", tbl, ", which is not ",
          "there. Give the table name bare, without the schema and without ",
          "the cohort prefix - COHORT_PREFIX is added for you, and defaults ",
          "to this run's own OBJECT_PREFIX."), class = "setting_error"))
      if (missing_object_error(d)) next
      stop("LINEAGE ERROR: the cohort build-status table ", tbl,
           " could not be read - ", conditionMessage(d), "\nThat is not the ",
           "same as its being absent: a table that is not there is a build ",
           "that recorded nothing, and one that cannot be read is a question ",
           "with no answer. Fix the read, name the table with ",
           "COHORT_STATUS_TABLE or its prefix with COHORT_PREFIX if the ",
           "cohort build wrote its status elsewhere, or set ",
           "LOT_ALLOW_UNPROVEN_LINEAGE=TRUE to proceed over a binding nothing ",
           "checked.", call. = FALSE)
    }
    if (!nrow(d)) next
    # Column case differs between the builds. Spark does not care; R does.
    pick <- function(w) {
      i <- match(tolower(w), tolower(names(d)))
      if (is.na(i)) NA_character_ else as.character(d[[i]][1])
    }
    return(list(table = tbl, run_id = as_str(pick("run_id")),
                stamp = as_str(pick("updated_at"))))
  }
  NULL
}

# What the accepted LOT run recorded about ITS inputs.
#
# LOT_BUILD_STATUS carries none of this - BUILD_STATUS_COLS declares nine
# columns and COHORT_RUN_ID is not among them, so asking it for one raises
# unresolved columns before the check can run. The engine records the cohort
# attempt and its own code fingerprint on LOT_RUN_METADATA instead, keyed by
# RUN_ID, so that is where this reads them from.
#
# Two ways the read can come back empty, and they are not the same answer.
# A table or a column that IS NOT THERE is an older LOT run that predates
# these columns: it recorded nothing, and NULL says so. A table that COULD NOT
# BE READ - a permission refused, a session dropped, a statement the engine
# would not parse - has recorded whatever it recorded, and this run has not
# seen it. Turning that into NULL made every outage read as "an older run",
# which is the answer that accepts; so it stops, and only the flag that
# already waives an unreadable LOT_BUILD_STATUS waives this too.
lot_run_inputs <- function(con, cfg, run_id) {
  if (!nzchar(as_str(run_id))) return(NULL)
  tbl <- lot_tbl("LOT_RUN_METADATA")
  d <- tryCatch(db_q(con, sprintf(
         "SELECT COHORT_RUN_ID, COHORT_STAMP, CODE_MD5 FROM %s
           WHERE RUN_ID = '%s'", tbl, run_id)),
       error = function(e) e)
  if (inherits(d, "error")) {
    if (missing_object_error(d) || missing_column_error(d)) {
      log_msg("  ", tbl, " records no cohort attempt for LOT run ", run_id,
              " (", if (missing_object_error(d)) "the table is not there"
                    else "the columns are not there",
              "), so that run predates them")
      return(NULL)
    }
    if (isTRUE(cfg$lot_allow_unproven_lineage)) {
      log_msg("WARNING: could not read ", tbl, " for LOT run ", run_id, " - ",
              conditionMessage(d), ". That is not the same as the run having ",
              "recorded nothing. LOT_ALLOW_UNPROVEN_LINEAGE=TRUE, so the run ",
              "continues over a cohort attempt and a code fingerprint nothing ",
              "checked.")
      return(NULL)
    }
    stop("LINEAGE ERROR: could not read ", tbl, " for LOT run ", run_id,
         " - ", conditionMessage(d), "\nThat is not the same as the table ",
         "being absent: an older LOT run that predates the cohort-attempt ",
         "columns records nothing and is accepted as such, but a table that ",
         "cannot be read has recorded whatever it recorded and this run has ",
         "not seen it. Fix the read, set LOT_PREFIX if the LOT build wrote ",
         "its metadata elsewhere, or set LOT_ALLOW_UNPROVEN_LINEAGE=TRUE to ",
         "proceed over a binding nothing checked.", call. = FALSE)
  }
  if (!nrow(d)) return(NULL)
  list(table = tbl,
       cohort_run_id = as_str(d$COHORT_RUN_ID),
       cohort_stamp  = as_str(d$COHORT_STAMP),
       code_md5      = as_str(d$CODE_MD5))
}

# Is the cohort under this name still the ATTEMPT the LOT run was built from?
#
# Everything check_lot_lineage() compares above is a NAME, and a cohort table
# can be rebuilt in place under the same name. So a LOT run built from attempt
# A still passes every name check while the table now holds attempt B - and
# this package would then read A's lines against B's eligibility flags,
# demographics and index dates, with no column anywhere disagreeing.
#
# The LOT engine already solved this for itself: check_cohort_build() records
# the cohort build's run id AND its UPDATED_AT, because a re-run keeps its id.
# This carries that same binding forward rather than inventing a second one.
#
# Not fatal where the LOT run recorded no attempt - it has nothing to compare -
# but that is said out loud rather than passed over, because it is the one case
# this cannot check.
check_cohort_attempt <- function(con, cfg, inputs) {
  if (is.null(inputs) ||
      (!nzchar(inputs$cohort_run_id) && !nzchar(inputs$cohort_stamp))) {
    log_msg("WARNING: the LOT run records no cohort build attempt, so this ",
            "run cannot tell whether ", cfg$input_cohort_table, " still holds ",
            "the cohort those lines were built from. A rebuild of it under ",
            "the same name would not be detected.")
    return(invisible(NULL))
  }
  was_id <- inputs$cohort_run_id
  was_stamp <- inputs$cohort_stamp
  now <- tryCatch(cohort_build_now(con, cfg), error = function(e) e)
  if (inherits(now, "error")) {
    # The waiver is for a lineage that could not be PROVED. A setting that
    # names a table which is not there is not that; nothing is unproven, the
    # run was pointed at the wrong place.
    if (inherits(now, "setting_error") ||
        !isTRUE(cfg$lot_allow_unproven_lineage)) stop(now)
    log_msg("WARNING: ", conditionMessage(now),
            "\nLOT_ALLOW_UNPROVEN_LINEAGE=TRUE, so the run continues.")
    return(invisible(NULL))
  }
  if (is.null(now)) {
    if (isTRUE(cfg$lot_allow_unproven_lineage)) {
      log_msg("WARNING: no cohort build status found, so the cohort attempt ",
              "behind ", cfg$input_cohort_table, " is unproven. ",
              "LOT_ALLOW_UNPROVEN_LINEAGE=TRUE, so the run continues.")
      return(invisible(NULL))
    }
    stop("LINEAGE ERROR: the LOT run was built from cohort attempt ", was_id,
         " (", was_stamp, "), and no cohort build status could be found under ",
         "this schema to say whether ", cfg$input_cohort_table,
         " still holds it.\nA cohort can be rebuilt in place under the same ",
         "name, so the name alone does not establish that these lines and ",
         "this eligibility came from one cohort. Set COHORT_PREFIX if the ",
         "cohort build wrote its status elsewhere, or set ",
         "LOT_ALLOW_UNPROVEN_LINEAGE=TRUE to proceed over a binding nothing ",
         "checked.", call. = FALSE)
  }
  same <- (!nzchar(was_id) || identical(was_id, now$run_id)) &&
          (!nzchar(was_stamp) || identical(was_stamp, now$stamp))
  if (!same)
    stop("LINEAGE ERROR: ", cfg$input_cohort_table, " has been rebuilt since ",
         "the LOT run was built from it.\n  LOT used cohort attempt: ", was_id,
         " (", was_stamp, ")\n  ", now$table, " now holds:      ",
         now$run_id, " (", now$stamp, ")\n",
         "The lines under the LOT prefix are the earlier attempt's, and this ",
         "package would read them against the current attempt's eligibility ",
         "flags, demographics and index dates. Re-run the LOT build over the ",
         "current cohort, or point INPUT_COHORT_TABLE at the cohort those ",
         "lines were built from.", call. = FALSE)
  log_msg("  cohort attempt ", was_id, " (", was_stamp,
          ") still holds under ", cfg$input_cohort_table)
  invisible(NULL)
}

# WHICH LOT code produced these lines.
#
# LOT_RULES_EPOCH below refuses a run that finished before the rule change, and
# a date is a proxy: it says when the build ran, not what it ran. Two builds on
# the same afternoon can be different code, and a re-run of the old code
# tomorrow carries tomorrow's date. The engine records a fingerprint of the R
# that actually executed - not a revision, because the code is copied into
# Domino to run - and LOT_CODE_MD5 is where a study team pins the one it
# approved.
#
# Blank is the shipped default and checks nothing, so this adds no refusal to
# a run that does not ask for one; it only lets a run that wants the stronger
# statement make it.
check_lot_code <- function(cfg, md5, run_id) {
  want <- as_str(cfg$lot_code_md5 %||% "")
  if (!nzchar(want)) return(invisible(NULL))
  if (!nzchar(md5))
    stop("LINEAGE ERROR: LOT_CODE_MD5 is set to ", want, ", and LOT run ",
         run_id, " records no code fingerprint to compare it to. ",
         lot_tbl("LOT_RUN_METADATA"), ".CODE_MD5 is written by the LOT ",
         "build when it records its final counts, so a run missing it did ",
         "not reach that point or predates the column. Re-run the LOT build, ",
         "or clear LOT_CODE_MD5 to accept a run whose code this cannot name.",
         call. = FALSE)
  if (!identical(want, md5))
    stop("LINEAGE ERROR: LOT run ", run_id, " was built by code ", md5,
         ", and this run is set to accept only ", want, ".\nLOT_CODE_MD5 ",
         "names the LOT build a study team approved, so a run built by any ",
         "other code is refused here rather than silently reported under the ",
         "approved one's name. Point LOT_PREFIX at the approved build, re-run ",
         "LOT with the approved code, or change LOT_CODE_MD5 if the new code ",
         "is what was approved.", call. = FALSE)
  log_msg("  LOT code ", substr(md5, 1, 8), " is the approved build")
  invisible(NULL)
}

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

  # A LOT run that did not finish. Its status row carries no reason - the LOT
  # build's own log does - so the message says where to look.
  if (!identical(tolower(trimws(as.character(r$STATE))), "complete"))
    problems <- c(problems, sprintf(
      paste0("the newest run (%s) is '%s', not 'complete'. The status row ",
             "does not say why; the LOT build's own log does, under the ",
             "OUTPUT_DIR that build ran with. Fix what it reports there and ",
             "re-run the LOT build"),
      r$RUN_ID, r$STATE))

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
  epoch <- as.Date(cfg$lot_rules_epoch)
  if (!is.na(upd) && upd < epoch)
    problems <- c(problems, sprintf(
      paste0("it finished %s, and the LOT rules last changed %s ",
             "(LOT_RULES_EPOCH): what starts and ends a line moved, so ",
             "numbers built before that date are superseded"),
      format(upd), format(epoch)))

  # Every problem above was CHECKED and found wrong, so every one stops.
  # LOT_ALLOW_UNPROVEN_LINEAGE covers only the case where the status table
  # could not be read at all, which is handled above.
  if (length(problems))
    stop("LINEAGE ERROR: this package will not read LOT run ", r$RUN_ID,
         " because:\n  - ", paste(problems, collapse = "\n  - "),
         "\nEach of these was checked against ", st,
         " and found wrong, so none of them is waived by a flag. Point the run ",
         "at the LOT build that produced this study's lines, or re-run it.",
         call. = FALSE)

  # The cohort ATTEMPT, not its name.
  #
  # A cohort table can be rebuilt in place under the same name, and everything
  # above compares names. So a LOT run built from attempt A still passes while
  # the table now holds attempt B - and this package would then read A's lines
  # against B's eligibility flags, demographics and index dates. The LOT engine
  # already solved this for itself: it records the cohort build's run id and
  # stamp on LOT_BUILD_STATUS precisely because the id alone is not enough.
  # This carries that binding forward rather than inventing a second one.
  inputs <- lot_run_inputs(con, cfg, as_str(r$RUN_ID))
  check_cohort_attempt(con, cfg, inputs)

  md5 <- if (is.null(inputs)) "" else inputs$code_md5
  check_lot_code(cfg, md5, r$RUN_ID)
  log_msg("LOT run ", r$RUN_ID, " accepted: ", r$STATE, ", cohort ",
          r$INPUT_COHORT_TABLE, ", study end ", r$STUDY_END,
          ", build ", run_version_stamp(r$UPDATED_AT),
          if (nzchar(md5)) paste0(", LOT code ", substr(md5, 1, 8)) else "")
  # UPDATED_AT stays in what is returned: it is the version of this build of
  # the run, and S_RUN_METADATA records it beside the id (LOT_RUN_VERSION).
  # The cohort attempt rides along under names of this package's own, so the
  # completion recheck asks the warehouse once rather than twice and
  # S_RUN_METADATA records what was actually bound.
  c(as.list(r),
    list(COHORT_ATTEMPT_ID = if (is.null(inputs)) "" else inputs$cohort_run_id,
         COHORT_ATTEMPT_STAMP = if (is.null(inputs)) "" else inputs$cohort_stamp,
         LOT_CODE_MD5 = md5))
}

# The same build, still? Asked once every module has run and before the run is
# recorded complete.
#
# check_lot_lineage() accepts a build before any table is read, and the modules
# then read the LOT tables for minutes while the engine can replace them in
# place under the same prefix. A row that is no longer the accepted build -
# another run, a build in progress, or the same run built again - stops the run
# here, and the failure handler records it `failed` rather than `complete`.
check_lot_lineage_unchanged <- function(con, accepted) {
  id <- trimws(as.character(accepted$RUN_ID %||% ""))
  if (!nzchar(id) || identical(id, "unproven")) return(invisible(TRUE))
  st <- lot_tbl("LOT_BUILD_STATUS")
  now <- tryCatch(
    db_q(con, sprintf("SELECT RUN_ID, STATE, UPDATED_AT FROM %s
                       ORDER BY UPDATED_AT DESC LIMIT 1", st)),
    error = function(e) e)
  # Kept, not dropped: the failure record has to tell a revoked grant from a
  # dropped session from a dropped table, and only the driver's words do.
  if (inherits(now, "error") || !nrow(now))
    stop("LINEAGE ERROR: ", st, " could not be re-read after the modules ran",
         if (inherits(now, "error")) paste0(" - ", conditionMessage(now))
         else " - it has no rows now",
         ", so it cannot be shown that LOT run ", id, " was still the build ",
         "under the prefix while this run read it. The run is recorded as ",
         "failed.", call. = FALSE)
  was_v <- lot_run_version(accepted)
  now_v <- run_version_stamp(now$UPDATED_AT[1])
  if (!lot_build_owns(now, id, was_v))
    stop("LINEAGE ERROR: the LOT prefix was rebuilt while this run was reading ",
         "it. Accepted LOT run ", id, " build ", was_v, "; the prefix now holds ",
         "run ", now$RUN_ID[1], " (", now$STATE[1], ") build ", now_v, ". The ",
         "lines this run read are not one build's, so it is recorded as failed ",
         "rather than complete. Re-run it once the LOT build has finished.",
         call. = FALSE)
  # ...and the cohort under it, for the same reason. The modules read the
  # cohort's eligibility flags, demographics and index dates for minutes after
  # the accept, and the cohort build can rewrite them in place under the same
  # name in that window. check_cohort_attempt() asks the same question against
  # the attempt this run accepted, so a rebuild during the read stops here and
  # the failure handler records the run `failed` rather than `complete`.
  att <- list(cohort_run_id = as_str(accepted$COHORT_ATTEMPT_ID %||% ""),
              cohort_stamp = as_str(accepted$COHORT_ATTEMPT_STAMP %||% ""))
  # Silent where there is nothing to compare: the accept already said so, and
  # saying it twice per run reads as a second, different gap.
  if (nzchar(att$cohort_run_id) || nzchar(att$cohort_stamp))
    check_cohort_attempt(con, study_config(), att)
  log_msg("LOT run ", id, " build ", was_v, " still owns the prefix; lineage holds")
  invisible(TRUE)
}

# Which BUILD of the LOT run a study run rests on - see run_version_stamp().
# LOT_RUN_ID alone names a run the engine may have built more than once; the
# version is the stamp of the `complete` status row this run vouched for, and
# every downstream reader refuses LOT tables under that id whose newest status
# row carries any other stamp.
lot_run_version <- function(lot_run)
  run_version_stamp(lot_run$UPDATED_AT %||% "")

# Which agents the cohort build barred from setting the 1L index.
#
# s7.2.1.1 I3 names two agents that may not set it - "Exclusions include:
# panobinostat and elotuzumab" - and only the cohort build can apply that,
# because it is the build that chooses the index claim. It records what it
# barred on NDMM_RUN_METADATA.INDEX_EXCLUDED, as the LIKE patterns it was
# given against the code list's CL_MED_ABBR. This resolves the protocol's
# names to abbreviations through cl_mma_rollup.csv and requires every
# abbreviation to be matched by a recorded pattern.
#
# An agent not on the rollup cannot set an index at all - the code list is the
# eligible-1L set - so there is nothing to bar and nothing to check. A build
# that recorded nothing (an older writer, or no metadata table) is unverified
# and said so; a metadata table that could not be READ is unproven and follows
# LOT_ALLOW_UNPROVEN_LINEAGE. A build that checkably barred less is wrong, and
# that stops: it made a different cohort. COHORT_INDEX_EXCLUSIONS=none checks
# nothing, since an empty environment value reads as the default.
check_cohort_index_exclusions <- function(con, cfg, cohort_run_id = "") {
  want <- trimws(strsplit(as.character(cfg$cohort_index_exclusions %||% ""),
                          "[,|]")[[1]])
  want <- want[nzchar(want) & tolower(want) != "none"]
  if (!length(want)) {
    log_msg("COHORT_INDEX_EXCLUSIONS is empty, so which agents the cohort ",
            "build barred from setting the 1L index is not checked.")
    return(invisible(NULL))
  }
  tbl <- cohort_tbl("NDMM_RUN_METADATA")
  cohort_run_id <- as_str(cohort_run_id)
  sql <- if (nzchar(cohort_run_id))
    sprintf("SELECT RUN_ID, INDEX_EXCLUDED FROM %s WHERE RUN_ID = '%s'
             ORDER BY RECORDED_AT DESC LIMIT 1",
            tbl, gsub("'", "''", cohort_run_id, fixed = TRUE))
  else sprintf("SELECT RUN_ID, INDEX_EXCLUDED FROM %s
                ORDER BY RECORDED_AT DESC LIMIT 1", tbl)
  rows <- tryCatch(db_q(con, sql), error = function(e) e)
  unverified <- function(why) {
    log_msg("WARNING: whether the cohort build barred ",
            paste(want, collapse = " and "), " from setting the 1L index is ",
            "unverified - ", why, ". s7.2.1.1 names them, and only the cohort ",
            "build can apply it.")
    invisible(NULL)
  }
  if (inherits(rows, "error")) {
    if (missing_object_error(rows))
      return(unverified(paste0(tbl, " is not there, so that build recorded nothing")))
    if (missing_column_error(rows))
      return(unverified(paste0(tbl, " predates the INDEX_EXCLUDED column")))
    if (!isTRUE(cfg$lot_allow_unproven_lineage))
      stop("LINEAGE ERROR: could not read ", tbl, " - ", conditionMessage(rows),
           "\nIt records which agents the cohort build barred from setting ",
           "the 1L index (s7.2.1.1: ", paste(want, collapse = ", "),
           "), and a build that barred neither made a different cohort. Fix ",
           "the read, set COHORT_PREFIX if the build wrote its metadata ",
           "elsewhere, or set LOT_ALLOW_UNPROVEN_LINEAGE=TRUE to proceed ",
           "over a binding nothing checked.", call. = FALSE)
    return(unverified(paste0(tbl, " could not be read (",
                             conditionMessage(rows),
                             ") and LOT_ALLOW_UNPROVEN_LINEAGE=TRUE")))
  }
  if (is.null(rows) || !nrow(rows))
    return(unverified(if (nzchar(cohort_run_id))
      paste0(tbl, " has no row for cohort attempt ", cohort_run_id)
      else paste0(tbl, " has no rows")))
  recorded <- trimws(strsplit(as_str(rows$INDEX_EXCLUDED[1]), "[,|]")[[1]])
  recorded <- recorded[nzchar(recorded) & tolower(recorded) != "na"]

  # The protocol's names, as the code list's abbreviations.
  rl <- tryCatch(load_codelist("cl_mma_rollup.csv", cfg), error = function(e) e)
  if (inherits(rl, "error"))
    return(unverified(paste0("cl_mma_rollup.csv, which maps the names to the ",
                             "code list's abbreviations, is not usable here: ",
                             sub("^CODELIST ERROR: ", "", conditionMessage(rl)))))
  # Whole columns, not as_str(), which reads one value.
  full <- tolower(trimws(ifelse(is.na(rl$CL_MEDICATION_FULL), "",
                                as.character(rl$CL_MEDICATION_FULL))))
  abbr <- toupper(trimws(ifelse(is.na(rl$CL_MED_ABBR), "",
                                as.character(rl$CL_MED_ABBR))))
  missing <- character(0)
  barred <- character(0)
  for (agent in want) {
    hits <- unique(abbr[grepl(tolower(agent), full, fixed = TRUE) & nzchar(abbr)])
    if (!length(hits)) {
      log_msg("  ", agent, " is not on cl_mma_rollup.csv, so it cannot set a ",
              "1L index and there is nothing to bar")
      next
    }
    for (a in hits) {
      if (any(vapply(recorded, function(p) like_matches(p, a), logical(1))))
        barred <- c(barred, sprintf("%s (%s)", agent, a))
      else missing <- c(missing, sprintf("%s (%s)", agent, a))
    }
  }
  if (length(missing))
    stop("LINEAGE ERROR: the cohort build", if (nzchar(cohort_run_id))
           paste0(" (attempt ", cohort_run_id, ")") else "",
         " did not bar ", paste(missing, collapse = ", "),
         " from setting the 1L index. s7.2.1.1 names them among the agents ",
         "restricted to later lines, and a cohort indexed on one of them is a ",
         "different cohort. It recorded NDMM_INDEX_EXCLUDED_ABBRS as '",
         paste(recorded, collapse = ","), "'.\nRe-run the cohort build with ",
         "NDMM_INDEX_EXCLUDED_ABBRS naming them, or set COHORT_INDEX_EXCLUSIONS ",
         "to what the study team agreed.", call. = FALSE)
  log_msg("  cohort build barred from the 1L index: ",
          if (length(barred)) paste(barred, collapse = ", ")
          else "nothing the code list could set one with")
  invisible(barred)
}

# SQL LIKE, as the cohort build applies NDMM_INDEX_EXCLUDED_ABBRS: `%` any run
# of characters, `_` any one, case-insensitive on both sides.
like_matches <- function(pattern, x) {
  # LIKE's wildcards as glob ones, and glob2rx() does the escaping: a dot in a
  # pattern is a dot, not any character.
  g <- chartr("%_", "*?", toupper(trimws(pattern)))
  grepl(utils::glob2rx(g, trim.tail = FALSE), toupper(trimws(x)))
}

# What the cohort build actually applied.
#
# Eight of this package's settings are the cohort build's rules, and the two
# defaults disagree today: this package reads s7.1's body (01 Jan 2018) and the
# cohort build reads Figures 1 and 2 (01 Jan 2016), which is Q1.
# NDMM_RUN_METADATA.CONTRACT_SETTINGS is that build's whole CONTRACT as
# `k=v|k=v`, so the study's metadata records what shaped the data rather than
# what this run was told.
#
# A disagreement on a setting that only SHAPES a criterion's reading is named,
# recorded and left to the study team. One on a setting that defines the
# cohort - BINDING_UPSTREAM_SETTINGS - stops the run, unless
# SETTINGS_OVERRIDE says to go on, and then it is a recorded deviation like a
# contract change: returned on the result's "deviations" attribute for the
# metadata row.
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
  binding <- Filter(function(d) any(startsWith(d, paste0(BINDING_UPSTREAM_SETTINGS, ":"))),
                    disagree)
  if (length(binding) && !isTRUE(cfg$settings_override))
    stop("UPSTREAM ERROR: the cohort this run reads was built under a ",
         "different study period or index floor than this run is set to:\n  - ",
         paste(binding, collapse = "\n  - "),
         "\nThe study period and the 1L index floor define the cohort, so ",
         "the two must agree: set STUDY_START / LOT1_INDEX_FROM to what the ",
         "cohort build applied, or rebuild the cohort. SETTINGS_OVERRIDE=TRUE ",
         "proceeds and records the disagreement as a deviation on the status ",
         "row, which no reader downstream accepts as the study's numbers.",
         call. = FALSE)
  if (length(disagree))
    log_msg("WARNING: this run's upstream readings disagree with the cohort ",
            "build that made its input:\n  - ",
            paste(disagree, collapse = "\n  - "),
            "\n  The cohort is what the cohort build made it, so the numbers ",
            "follow ITS values. Both are recorded in S_RUN_METADATA.")
  else
    log_msg("  upstream settings verified against ", tbl)
  attr(out, "deviations") <- if (length(binding))
    paste0("upstream ", sub(":", " -", binding, fixed = TRUE)) else character(0)
  out
}
