# Reading only. This package writes no warehouse table: it renders what the
# cohort and LOT builds already produced. Nothing here creates, replaces or
# drops anything, which is what makes it safe to re-run against a finished
# study whenever somebody wants the numbers again.

with_retry <- function(fn, max_retries = dash_config()$max_retries,
                       base_sleep = dash_config()$base_sleep) {
  permanent <- c("TABLE_OR_VIEW_NOT_FOUND", "AnalysisException",
                 "PARSE_SYNTAX_ERROR", "UNRESOLVED_COLUMN",
                 "does not exist", "cannot be found")
  attempt <- 1L
  repeat {
    out <- tryCatch(fn(), error = function(e) e)
    if (!inherits(out, "error")) return(out)
    msg <- conditionMessage(out)
    if (attempt >= max_retries || any(vapply(permanent, grepl, logical(1),
                                             x = msg, fixed = TRUE)))
      stop(msg, call. = FALSE)
    Sys.sleep(base_sleep * 2^(attempt - 1L))
    attempt <- attempt + 1L
  }
}

# A BIGINT arrives as bit64::integer64 - a 64-bit int inside a double's bit
# pattern - so paste0() renders the bits: a count of 1780 prints as
# 8.794368e-321. Converted once here rather than at each call site. Every
# count here is far below 2^53, so nothing is lost.
.unint64 <- function(d) {
  if (!is.data.frame(d) || !ncol(d)) return(d)
  for (j in seq_along(d))
    if (inherits(d[[j]], "integer64")) d[[j]] <- as.numeric(d[[j]])
  d
}

db_q <- function(con, sql) .unint64(with_retry(function() DBI::dbGetQuery(con, sql)))

# <catalog>.<schema>.<table>, or <schema>.<table> when no catalog is set. The
# schema is the work schema the cohort and LOT builds wrote into.
full_name <- function(schema, object) {
  cfg <- dash_config()
  if (nzchar(cfg$catalog)) paste0(cfg$catalog, ".", schema, ".", object)
  else paste0(schema, ".", object)
}

wrk <- function(tbl) full_name(dash_config()$work_schema, tbl)

# The tables a section may name. Every one is resolved once, up front, so a
# section cannot invent a name and a missing table is reported against the
# input rather than against whichever panel happened to read it first.
dashboard_inputs <- function(cfg) {
  lp <- cfg$lot_prefix
  cp <- if (nzchar(cfg$cohort_prefix)) cfg$cohort_prefix else lp
  list(
    cohort    = wrk(cfg$input_cohort_table),
    patients  = wrk(paste0(lp, "LOT_PATIENT_INPUT")),
    lot_long  = wrk(paste0(lp, "LOT_LONG")),
    lot_final = wrk(paste0(lp, "LOT_LONG_FINAL")),
    run_meta  = wrk(paste0(lp, "LOT_RUN_METADATA")),
    # One row per LOT run, STATE written "complete" last of all. This is what
    # says which run the tables beside it came from.
    build_st  = wrk(paste0(lp, "LOT_BUILD_STATUS")),
    # The attrition table is the COHORT build's, so its name belongs to that
    # build and not to this one. ndmm calls it NDMM_ATTRITION; another cohort
    # will call it something else, or have none. Configurable, so this folder
    # still names no study of its own - ATTRITION_TABLE in config.csv.
    attrition = wrk(paste0(cp, cfg$attrition_table)),
    # The LOT build's own funnel, which is a different thing from the cohort
    # build's above: it starts where that one ends. Its name is this package's
    # to know, not configurable, because the LOT build writes it.
    lot_attrition = wrk(paste0(lp, "LOT_ATTRITION")),
    # The cohort build's follow-up-CE sensitivity, so configurable for the same
    # reason the attrition table is: ndmm writes it, another cohort build may
    # not. Absent is a panel to skip, not a run to fail.
    fu_ce_counts  = wrk(paste0(cp, cfg$fu_ce_counts_table)),
    # The outcomes build's per-line table. Written under the LOT prefix - the
    # outcomes build is pointed at the same one - so this package can name it.
    # Absent whenever outcomes has not been run, which is most of the time.
    out_tte       = wrk(paste0(lp, "OUT_TTE"))
  )
}

# Which of them are actually there. A study that ran the LOT build but not the
# cohort build has no attrition table, and that is a section to skip with a
# note rather than a run to fail: the rest of the dashboard is still true.
probe_inputs <- function(con, inputs) {
  vapply(inputs, function(tbl)
    isTRUE(tryCatch({ db_q(con, paste0("SELECT 1 FROM ", tbl, " LIMIT 1")); TRUE },
                    error = function(e) FALSE)),
    logical(1))
}

# The column names of a table, upper-cased, or character(0) if it cannot be
# asked. Empty means "no answer", never "no columns" - acting on the second
# reading of an empty result is how the other packages' schema-evolution code
# nearly added every column to tables that already had them.
table_cols <- function(con, tbl) {
  tryCatch({
    d  <- db_q(con, paste0("DESCRIBE ", tbl))
    cn <- intersect(c("col_name", "COL_NAME", "name", "NAME"), names(d))
    if (!length(cn)) return(character(0))
    v <- toupper(trimws(as.character(d[[cn[1]]])))
    # DESCRIBE appends a blank line and a partition block on some tables.
    v[nzchar(v) & !startsWith(v, "#")]
  }, error = function(e) character(0))
}

# Which run wrote the tables this dashboard is about to read.
#
# LOT_BUILD_STATUS is one row per run and its "complete" is written after every
# other write in the build, so the latest row on the prefix is the run that
# last touched these tables - whatever state it reached. That is ownership, and
# it is what the provenance panel needs. A completed metadata row is not:
# LOT_LONG_FINAL is replaced early in the line-criteria phase and validated
# afterwards, so a rerun that replaced it and then failed leaves its own table
# on disk with a metadata row no completeness test will accept, and the
# previous run's complete row still looks like the newest good one.
#
# Returns list(run_id, ts, exact). exact = FALSE means the status table was
# not there to ask and the answer is the newest completed metadata row - the
# old behaviour, kept so a study built by an older LOT still renders, and
# reported as the weaker claim it is.
resolve_owner_run <- function(con, inputs, have, cfg) {
  # FALSE feeds a stop that says the tables were "edited or partly restored" -
  # right for a missing run row, wrong for a metadata table too old to have
  # N_LOT_FINAL_ROWS, which errors and sends the operator hunting tampering.
  # NA says which it was.
  meta_complete <- function(rid)
    tryCatch(nrow(db_q(con, paste0(
      "SELECT 1 FROM ", inputs$run_meta, " WHERE RUN_ID = '", rid,
      "' AND N_LOT_FINAL_ROWS IS NOT NULL"))) > 0,
      error = function(e) NA)

  # Which cohort run LOT read. Recorded by lot at the moment it checked the
  # cohort build, so it is a fact about this LOT run rather than a guess from
  # timestamps. NA on an older lot that did not record it.
  # The stamp comes with it: a cohort re-run keeps its run id and rewrites its
  # rows under it, so the id alone cannot tell one attempt from the next.
  cohort_of <- function(rid) tryCatch({
    d <- db_q(con, paste0("SELECT COHORT_RUN_ID, COHORT_STAMP FROM ",
                          inputs$run_meta, " WHERE RUN_ID = '", rid, "'"))
    if (!nrow(d)) list(id = NA_character_, stamp = NA_character_)
    else list(id = as.character(d[[1]][1]), stamp = as.character(d[[2]][1]))
  }, error = function(e) list(id = NA_character_, stamp = NA_character_))

  # Was this run built as the contract algorithm at all?
  #
  # Its own query rather than a column in the SELECT below: CONTRACT_DEVIATIONS
  # was added later, and naming it there would make an older run's status table
  # unreadable - which reads as no status table, and falls back to the weaker
  # metadata answer. Empty on every contract build.
  #
  # No override on this one. It is not an inference from timestamps that could
  # be wrong; it is what the build wrote about itself. A dashboard drawn from a
  # sensitivity cell would render every panel exactly as it renders the study.
  # By name, not by position. A frame that came back without the column is a
  # table that does not have it, and reading column one instead would turn a
  # run id into a deviation.
  # "" means no deviation and the page renders on it, so "" has to mean the
  # question was ASKED and answered no. A missing table or column does answer
  # no - a run built before the override existed cannot have used it. A refused
  # read answers nothing, and returning "" for it draws a sensitivity cell as
  # the study.
  #
  # Class name and driver wordings both, as with_retry lists them: which comes
  # back depends on how the ODBC layer surfaces it.
  #
  # Two predicates, because the two reads below ask different questions. A
  # column error is legacy for CONTRACT_DEVIATIONS, which was added later - but
  # not for the ownership read, whose RUN_ID, STATE and UPDATED_AT have been
  # there from the start. A status table missing one of those is malformed, and
  # falling back to the newest completed metadata row would put run A's
  # provenance over run B's tables. Only an absent table is legacy there.
  missing_table <- function(msg)
    grepl("TABLE_OR_VIEW_NOT_FOUND|Table or view not found|does not exist",
          msg, ignore.case = TRUE)
  legacy_gap <- function(msg)
    missing_table(msg) ||
    grepl("UNRESOLVED_COLUMN|Unresolved column|cannot resolve|no such column",
          msg, ignore.case = TRUE)
  deviations_of <- function(rid) tryCatch({
    d <- db_q(con, paste0("SELECT CONTRACT_DEVIATIONS FROM ", inputs$build_st,
                          " WHERE RUN_ID = '", rid, "'"))
    i <- match("CONTRACT_DEVIATIONS", toupper(names(d)))
    if (!nrow(d) || is.na(i)) return("")
    v <- as.character(d[[i]][1])
    if (is.na(v)) "" else trimws(v)
  }, error = function(e) {
    if (legacy_gap(conditionMessage(e))) return("")
    stop("Could not read CONTRACT_DEVIATIONS from ", inputs$build_st,
         " for run ", rid, ": ", conditionMessage(e),
         "\nThat column is what says whether this run was built with ",
         "LOT_CONTRACT_OVERRIDE - a sensitivity cell, which every panel here ",
         "would draw exactly as it draws the study. A status table written ",
         "before the column existed says so specifically; this did not. Fix ",
         "the read and re-run.", call. = FALSE)
  })
  refuse_if_deviating <- function(rid) {
    dev <- deviations_of(rid)
    if (nzchar(dev))
      stop("Run ", rid, " was built with LOT_CONTRACT_OVERRIDE, so it is not ",
           "the contract algorithm:\n  ",
           paste(strsplit(dev, "|", fixed = TRUE)[[1]], collapse = "\n  "),
           "\nIt is a sensitivity cell. Every panel here would draw it exactly ",
           "as it draws the study. Point LOT_PREFIX at the study's own run.",
           call. = FALSE)
    invisible(TRUE)
  }

  # Read and classify rather than trust probe_inputs(), which answers FALSE for
  # a table that is absent and for one it could not read alike. Only the first
  # justifies the fallback below; the second takes it and hands run A's
  # provenance to run B's unvalidated tables.
  st <- tryCatch(db_q(con, paste0(
    "SELECT RUN_ID, STATE, UPDATED_AT FROM ", inputs$build_st,
    " ORDER BY UPDATED_AT DESC LIMIT 1")), error = function(e) e)
  if (inherits(st, "condition") && !missing_table(conditionMessage(st)))
    stop("Could not read ", inputs$build_st, ": ", conditionMessage(st),
         "\nThat table is what says which run wrote the tables on this page. ",
         "A study built by an older lot has no such table and says so ",
         "specifically; this did not, so falling back to the newest completed ",
         "metadata row would risk drawing one run's numbers under another ",
         "run's provenance. Fix the read and re-run.", call. = FALSE)
  {
    d <- if (inherits(st, "condition")) NULL else st
    if (!is.null(d) && nrow(d) == 1L) {
      rid   <- as.character(d$RUN_ID[1])
      state <- tolower(trimws(as.character(d$STATE[1])))
      refuse_if_deviating(rid)
      if (identical(state, "complete")) {
        # Marked complete but with no completed metadata row is a contradiction
        # in the warehouse, not something to paper over with a fallback: the
        # two are written seconds apart at the end of the same build.
        mc <- meta_complete(rid)
        if (is.na(mc))
          stop("Run ", rid, " is marked complete in ", inputs$build_st,
               ", but ", inputs$run_meta, " could not be asked whether it has ",
               "that run's completed row. Either the table is older than the ",
               "N_LOT_FINAL_ROWS column, or it could not be read at all. ",
               "Nothing here can say what produced these tables.", call. = FALSE)
        if (!isTRUE(mc))
          stop("Run ", rid, " is marked complete in ", inputs$build_st,
               " but has no completed row in ", inputs$run_meta,
               ". Those two are written seconds apart at the end of the same ",
               "build, so one of them has been edited or partly restored. ",
               "Nothing here can say what produced these tables.", call. = FALSE)
        co <- cohort_of(rid)
        return(list(run_id = rid, ts = d$UPDATED_AT[1], exact = TRUE,
                    cohort_run = co$id, cohort_stamp = co$stamp))
      }
      # Not complete. The tables on disk may be this run's, and nothing here
      # can tell. Stop, unless the operator says they know it failed early.
      if (!identical(toupper(Sys.getenv("DASH_IGNORE_BUILD_STATE", unset = "")),
                     "TRUE"))
        stop("The last LOT run on prefix ", cfg$lot_prefix, " (", rid,
             ") is marked '", state, "', so it is the run that last wrote ",
             "these tables and it did not finish. LOT replaces LOT_LONG_FINAL ",
             "early in the line-criteria phase and validates it afterwards, so ",
             "the table on disk may be that run's - built, unvalidated, and ",
             "left behind. A dashboard cannot tell those numbers from good ",
             "ones. Re-run the LOT build. If you know that run failed before ",
             "it wrote anything, set DASH_IGNORE_BUILD_STATE=TRUE and this ",
             "falls back to the newest completed run.", call. = FALSE)
      log_msg("WARNING: the last LOT run (", rid, ") is marked '", state,
              "' and DASH_IGNORE_BUILD_STATE is set. If it got as far as ",
              "replacing LOT_LONG_FINAL, the numbers on this page are that ",
              "run's and the provenance below them is not.")
    }
  }

  d <- tryCatch(db_q(con, paste0(
    "SELECT RUN_ID, RUN_TIMESTAMP FROM ", inputs$run_meta,
    " WHERE N_LOT_FINAL_ROWS IS NOT NULL ORDER BY RUN_TIMESTAMP DESC LIMIT 1")),
    error = function(e) NULL)
  if (is.null(d) || !nrow(d))
    return(list(run_id = NA_character_, ts = NA, exact = FALSE,
                cohort_run = NA_character_, cohort_stamp = NA_character_))
  rid <- as.character(d$RUN_ID[1])
  co  <- cohort_of(rid)
  list(run_id = rid, ts = d$RUN_TIMESTAMP[1], exact = FALSE,
       cohort_run = co$id, cohort_stamp = co$stamp)
}
