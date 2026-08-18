# The 2L and 3L cohorts, with their own extra eligibility rules.
#
# Runs after the LOT build, because the 2L and 3L index dates are line starts
# and only lot knows them. They are separate cohorts rather than flags on the
# lines: 6.2.1.1 applies the extra criteria to the 1L cohort to create subset
# cohorts, which is membership.
#
# Three criteria, and no others:
#
#   1. Received the line that qualifies for the cohort - 2L for 2L, 3L for 3L.
#   2. Continuous enrollment with medical and pharmacy benefits for at least 12
#      months before that line's index date. Gaps of 30 days or less are still
#      continuous.
#   3. Continuous enrollment for at least 3 months of follow-up, or death, with
#      no gaps. Counted as 90 days - see SUBSEQ_FU_CE_DAYS below.
#
# Death is the stated alternative to the follow-up window and the only one. The
# study end is not: a living patient whose window runs past the data has not
# shown the enrolment, so the window is truncated at death and nothing else.
#
# Each cohort is drawn from the one before it, 2L from the 1L cohort and 3L from
# the 2L cohort, because the study team reads "each subsequent line is a subset
# of the prior line" as a cohort rule. Receiving the lines in order is
# guaranteed anyway - lines are numbered sequentially, so a LOT 3 row implies a
# LOT 2 row. What chaining adds is that the earlier cohort's enrolment windows
# must also have been met, and that is not the same test: a patient can fail the
# follow-up window after 2L and still be fully enrolled for the 365 days before
# 3L and the 90 after it. N_EXCLUDED_BY_PRIOR counts them.
#
# Nothing here changes the 1L cohort or the LOT tables. It reads the spans the
# 1L build already checkpointed, so no enrollment rule is written twice.

SUBSEQ_LINES <- c(2L, 3L)

# What separates two runs of this build from each other.
#
# run_id is not enough. It comes from DOMINO_RUN_ID, so a second attempt inside
# one Domino execution shares it - build_ndmm.R says so where it resets the
# findings option. The three outputs are replaced one at a time with no
# transaction, so an attempt that rewrote 2L and then died left a NEW 2L beside
# a STALE 3L carrying the same run id, the same source LOT run and stamp, the
# same cohort attempt and the same windows. Every column outcomes compares
# matched, and LINE_ELIGIBLE meant one thing on 2L and another on 3L.
#
# Minted fresh per call, so two attempts differ whatever the run id says.
# Timestamp to the millisecond for readability, process id because two Rscript
# invocations in the same millisecond are still two processes.
subseq_attempt_id <- function() {
  paste0(format(Sys.time(), "%Y%m%d%H%M%OS3"), "-", Sys.getpid())
}

SUBSEQ_STATUS_COLS <- c(
  RUN_ID = "STRING", ATTEMPT = "STRING", STATE = "STRING",
  OBJECT_PREFIX = "STRING", CE_PRE_DAYS = "INT", CE_FU_DAYS = "INT",
  SOURCE_LOT_RUN_ID = "STRING", SOURCE_LOT_STAMP = "STRING",
  UPDATED_AT = "TIMESTAMP")

# Another attempt of this build already going on this prefix.
#
# Reads its own status table rather than the 1L build's: those are different
# builds writing different tables, and a 1L run in progress is not a reason to
# refuse this one. An unreadable table is this check not running, which is not
# this check passing - the same line every other status reader here draws.
subseq_check_no_active_run <- function(con, cfg) {
  tbl <- wrk("NDMM_SUBSEQ_BUILD_STATUS")
  d <- tryCatch(db_q(con, glue("
    SELECT ATTEMPT, UPDATED_AT FROM {tbl}
    WHERE OBJECT_PREFIX = {sql_text(cfg$object_prefix)}
      AND STATE = 'started'")), error = function(e) e)
  ignoring <- identical(toupper(trimws(Sys.getenv("NDMM_SUBSEQ_IGNORE_ACTIVE_RUN",
                                                  unset = ""))), "TRUE")
  if (inherits(d, "condition")) {
    if (missing_object_error(d)) return(invisible(TRUE))
    if (ignoring) {
      log_msg("WARNING: ", tbl, " could not be read (", conditionMessage(d),
              ") and NDMM_SUBSEQ_IGNORE_ACTIVE_RUN is set, so nothing checked ",
              "whether another subsequent build is running on this prefix.")
      return(invisible(TRUE))
    }
    stop("Could not read ", tbl, " (", conditionMessage(d), "), so whether ",
         "another subsequent build is already running on prefix '",
         cfg$object_prefix, "' is unknown. Two of them interleave 2L, 3L and ",
         "the attrition and both reach complete. ",
         "NDMM_SUBSEQ_IGNORE_ACTIVE_RUN=TRUE proceeds anyway.", call. = FALSE)
  }
  if (nrow(d)) {
    msg <- paste0("Another subsequent build is marked started on prefix '",
                  cfg$object_prefix, "' (attempt ", d[[1]][1], ", ", d[[2]][1],
                  "). They write the same three tables under the same names, ",
                  "so running both leaves a pair that is partly each. Wait for ",
                  "it, or NDMM_SUBSEQ_IGNORE_ACTIVE_RUN=TRUE if it died.")
    if (ignoring) log_msg("WARNING: ", msg) else stop(msg, call. = FALSE)
  }
  invisible(TRUE)
}

# One row per attempt, not per run id: a retry has to be visible beside the
# attempt it is replacing, or "it died part-way" is not recorded anywhere.
# started before the first table is replaced, complete after the last one,
# failed from an on.exit if neither is reached.
write_subseq_status <- function(con, cfg, attempt, state, pre_days, fu_days,
                                src = NULL) {
  tbl  <- wrk("NDMM_SUBSEQ_BUILD_STATUS")
  cols <- names(SUBSEQ_STATUS_COLS)
  db_exec(con, glue("CREATE TABLE IF NOT EXISTS {tbl} (",
                    paste(cols, SUBSEQ_STATUS_COLS, collapse = ", "), ")"))
  ensure_cols(con, tbl, SUBSEQ_STATUS_COLS)
  db_replace(con,
    glue("DELETE FROM {tbl} WHERE ATTEMPT = {sql_text(attempt)}"),
    glue("INSERT INTO {tbl} ({paste(cols, collapse = ', ')}) VALUES (",
         "{sql_text(run_id)}, {sql_text(attempt)}, {sql_text(state)}, ",
         "{sql_text(cfg$object_prefix)}, {sql_count(pre_days)}, ",
         "{sql_count(fu_days)}, ",
         "{sql_text(if (is.null(src)) NA_character_ else src$lot_run)}, ",
         "{sql_text(if (is.null(src)) NA_character_ else src$lot_stamp)}, ",
         "current_timestamp())"))
  log_msg("Subsequent-build status: ", state, " (attempt ", attempt, ")")
  invisible(TRUE)
}

# The two windows, as settings of their own rather than the 1L cohort's.
#
# SUBSEQ_PRE_DAYS is days of CE before the cohort index date - 365 for the
# 12 months of baseline. It is not PRE_LOT1_DAYS: that one is pinned by
# CONTRACT to the value the 1L cohort was built with, so it cannot be moved
# without redefining that cohort. These are a separate question.
#
# SUBSEQ_FU_CE_DAYS is days of follow-up CE - 90 for the 3 months,
# counted the same way NDMM_FU_CE_DAYS counts the 1L window. Days rather than
# calendar months: 90 days is not add_months(index, 3), because month lengths
# differ, and the 1L build's own sensitivity table put the two seven patients
# apart. 90 days is the shorter of the pair, so it is the more permissive
# reading of "at least 3-months".
#
# Whatever they are set to is written into all three outputs, so a cohort
# always says which windows made it.
subseq_days <- function(v, default) {
  x <- trimws(Sys.getenv(v, unset = ""))
  if (!nzchar(x)) return(as.integer(default))
  # The text, not what coercion makes of it: as.integer("60.5") is 60.
  if (!grepl("^[0-9]+$", x))
    stop(v, "='", x, "' (want a whole number)", call. = FALSE)
  as.integer(x)
}

# The windows the cohorts are DEFINED by, pinned the way the 1L build pins its
# own contract. Settable was not the same as free: any other pair builds a
# different cohort that still lands in NDMM_COHORT_2L and NDMM_COHORT_3L, the
# names everything downstream reads as the study's. So a non-contract pair
# stops unless asked for by name - and an overridden run is still readable as
# one, because the values go onto every output as CE_PRE_DAYS and CE_FU_DAYS.
SUBSEQ_CONTRACT_PRE_DAYS <- 365L
SUBSEQ_CONTRACT_FU_DAYS  <- 90L
subseq_check_windows <- function(pre_days, fu_days) {
  off <- c(
    if (pre_days != SUBSEQ_CONTRACT_PRE_DAYS)
      paste0("SUBSEQ_PRE_DAYS=", pre_days,
             " (contract ", SUBSEQ_CONTRACT_PRE_DAYS, ")"),
    if (fu_days != SUBSEQ_CONTRACT_FU_DAYS)
      paste0("SUBSEQ_FU_CE_DAYS=", fu_days,
             " (contract ", SUBSEQ_CONTRACT_FU_DAYS, ")"))
  if (!length(off)) return(invisible(FALSE))
  if (!identical(toupper(trimws(Sys.getenv("NDMM_SUBSEQ_OVERRIDE", unset = ""))),
                 "TRUE"))
    stop("The 2L/3L windows are not the study's: ",
         paste(off, collapse = ", "), ". Cohorts built under other windows are ",
         "different cohorts wearing the study's table names. ",
         "NDMM_SUBSEQ_OVERRIDE=TRUE builds them anyway, as a named ",
         "sensitivity; the values are written into every output either way.",
         call. = FALSE)
  log_msg("NON-CONTRACT 2L/3L WINDOWS: ", paste(off, collapse = ", "),
          ". These cohorts are a sensitivity, not the study's.")
  invisible(TRUE)
}

# Mismatched lineage always stops. These are the cases where the proof is
# MISSING rather than failed - a status table that is not there, a metadata row
# recording no cohort attempt, a status row from a build too old to carry the
# column. Logging and carrying on lets a damaged or older-vintage warehouse
# build cohorts nothing can tie to their lines, so the operator accepts an
# unproven lineage by name or does not get the cohorts.
subseq_unproven <- function(what) {
  if (identical(toupper(trimws(Sys.getenv("NDMM_SUBSEQ_ALLOW_UNPROVEN",
                                          unset = ""))), "TRUE")) {
    log_msg("UNPROVEN LINEAGE ACCEPTED: ", what)
    return(invisible(TRUE))
  }
  stop(what, " The lines' lineage cannot be proven, and a subset cohort built ",
       "over mixed vintages looks exactly like a right one. ",
       "NDMM_SUBSEQ_ALLOW_UNPROVEN=TRUE accepts that, on the record.",
       call. = FALSE)
}

# The lines come from a LOT run, so that run has to have finished, to have been
# built over this cohort, and to have been built over the cohort attempt that
# is on disk now. The latest status row, whatever state it reached: "complete"
# is written last, so the newest row is the run that last wrote the tables - a
# rerun that replaced them and then failed owns them.
subseq_check_lot_run <- function(con, prefix) {
  tbl <- wrk("LOT_BUILD_STATUS")
  d <- tryCatch(db_q(con, glue(
    "SELECT * FROM {tbl} ORDER BY UPDATED_AT DESC LIMIT 1")), error = function(e) NULL)
  if (is.null(d) || !nrow(d))
    stop("No LOT run is recorded in ", tbl, ". The 2L and 3L index dates are ",
         "line starts, so the LOT build has to run first.", call. = FALSE)
  pick <- function(nm) {
    i <- match(toupper(nm), toupper(names(d)))
    if (is.na(i)) NA_character_ else as.character(d[[i]][1])
  }
  st <- tolower(trimws(pick("STATE")))
  if (!identical(st, "complete"))
    stop("The last LOT run on prefix '", prefix, "' (", pick("RUN_ID"),
         ") is marked '", st, "'. It replaces LOT_LONG_FINAL before it ",
         "validates it, so those lines may be an unfinished run's.",
         call. = FALSE)
  want <- toupper(trimws(paste0(prefix, "NDMM_COHORT")))
  got  <- sub("^.*\\.", "", toupper(trimws(pick("INPUT_COHORT_TABLE"))))
  if (is.na(got) || !nzchar(got))
    subseq_unproven(paste0(tbl, " records no INPUT_COHORT_TABLE for run ",
                           pick("RUN_ID"), ", so there is no proof the lines ",
                           "are about ", prefix, "NDMM_COHORT."))
  else if (!identical(got, want))
    stop("That LOT run was built from '", pick("INPUT_COHORT_TABLE"),
         "', not from ", prefix, "NDMM_COHORT. These cohorts would be a subset ",
         "of a population the lines are not about.", call. = FALSE)
  dev <- pick("CONTRACT_DEVIATIONS")
  if (is.na(dev))
    subseq_unproven(paste0(tbl, " has no CONTRACT_DEVIATIONS column, so ",
                           "whether run ", pick("RUN_ID"), " was the contract ",
                           "algorithm is not recorded."))
  else if (nzchar(trimws(dev)))
    stop("That LOT run was built with LOT_CONTRACT_OVERRIDE (", dev,
         "), so its lines are an alternative algorithm's.", call. = FALSE)
  log_msg("LOT run ", pick("RUN_ID"), " completed over ", pick("INPUT_COHORT_TABLE"))
  # Which cohort attempt it read is not in the status table - it is in
  # LOT_RUN_METADATA, on the row for this run.
  att <- subseq_check_cohort_attempt(con, pick("RUN_ID"))
  # The run id alone does not identify the build. A re-run under the same
  # RUN_ID replaces LOT_LONG_FINAL in place, so cohorts built from attempt A
  # keep naming a run id that now means attempt B and read as current. The
  # status row's UPDATED_AT is what separates them, so it travels with the id.
  invisible(list(lot_run = pick("RUN_ID"), lot_stamp = pick("UPDATED_AT"),
                 cohort_run = att$cohort_run, cohort_stamp = att$cohort_stamp))
}

# The name of the cohort table is not enough. A re-run under the same prefix
# replaces NDMM_COHORT and both span tables in place, so lines from attempt A
# and enrollment from attempt B carry the same names.
#
# LOT records which attempt it read as COHORT_RUN_ID and COHORT_STAMP - in
# LOT_RUN_METADATA, not in LOT_BUILD_STATUS. They are two different tables and
# reading the wrong one costs nothing visible: the columns are simply absent,
# every value is NA, and the comparison quietly decides it has nothing to
# compare. Hence subseq_row(), and a caller that stops when the row is absent.
subseq_row <- function(con, tbl, where, order = "") {
  ord <- if (nzchar(order)) paste0(" ORDER BY ", order) else ""
  d <- tryCatch(db_q(con, glue("SELECT * FROM {tbl} WHERE {where}{ord} LIMIT 1")),
                error = function(e) NULL)
  if (is.null(d) || !nrow(d)) return(NULL)
  d
}

subseq_check_cohort_attempt <- function(con, lot_run_id) {
  meta <- wrk("LOT_RUN_METADATA")
  m <- subseq_row(con, meta, glue("RUN_ID = {sql_text(lot_run_id)}"))
  # A LOT run that reached "complete" always wrote this row, so its absence is
  # not an old-run allowance - something is wrong with what is on disk.
  if (is.null(m))
    stop("LOT run ", lot_run_id, " is marked complete but has no row in ", meta,
         ", so there is no record of which cohort attempt its lines were built ",
         "over.", call. = FALSE)
  mpick <- function(nm) {
    i <- match(toupper(nm), toupper(names(m)))
    if (is.na(i)) NA_character_ else as.character(m[[i]][1])
  }
  lot_cohort_id <- mpick("COHORT_RUN_ID"); lot_stamp <- mpick("COHORT_STAMP")

  tbl <- wrk("NDMM_BUILD_STATUS")
  d <- subseq_row(con, tbl, "1 = 1", "UPDATED_AT DESC")
  if (is.null(d)) {
    subseq_unproven(paste0(tbl, " has no row, so the cohort attempt the lines ",
                           "were built over cannot be compared to what is on ",
                           "disk now."))
    return(invisible(list(cohort_run = NA_character_, cohort_stamp = NA_character_)))
  }
  pick <- function(nm) {
    i <- match(toupper(nm), toupper(names(d)))
    if (is.na(i)) NA_character_ else as.character(d[[i]][1])
  }
  now_id <- pick("RUN_ID"); now_stamp <- pick("UPDATED_AT")
  # LOT writes NULL here when it could not find a cohort status table at all.
  # Nothing recorded is nothing to compare - and a comparison that cannot be
  # made is not a comparison that passed.
  if (is.na(lot_cohort_id) || !nzchar(trimws(lot_cohort_id))) {
    subseq_unproven(paste0(meta, " records no cohort attempt for run ",
                           lot_run_id, ", so it cannot be compared to NDMM ",
                           "run ", now_id, "."))
    return(invisible(list(cohort_run = NA_character_, cohort_stamp = NA_character_)))
  }
  cohort_run_id <- lot_cohort_id
  eq <- function(a, b) {
    a <- trimws(as.character(a)); b <- trimws(as.character(b))
    !is.na(a) && !is.na(b) && identical(a, b)
  }
  # The stamp exists because two attempts can reuse a run id, so a blank one
  # does not prove the attempt. "Could not check" is not "checked".
  if (eq(cohort_run_id, now_id) && (is.na(lot_stamp) || !nzchar(trimws(lot_stamp)))) {
    subseq_unproven(paste0(meta, " records cohort run ", cohort_run_id,
                           " with no stamp, so a second attempt under the same ",
                           "run id cannot be told from the one the lines were ",
                           "built over."))
    return(invisible(list(cohort_run = cohort_run_id, cohort_stamp = NA_character_)))
  }
  same <- eq(cohort_run_id, now_id) && eq(lot_stamp, now_stamp)
  if (!same)
    stop("The LOT lines were built over NDMM run ", cohort_run_id, " (", lot_stamp,
         "), but ", tbl, " now holds run ", now_id, " (", now_stamp,
         "). The cohort and the enrollment spans on disk are a later attempt ",
         "than the lines, so eligibility would be worked out from enrollment ",
         "data that did not produce the population the lines are about. ",
         "Re-run the LOT build.", call. = FALSE)
  log_msg("  Cohort attempt ", now_id, " matches the one the LOT run read.")
  # Returned, not just checked: these go onto the cohort tables so a later
  # reader can tell whether they still belong beside the LOT tables on disk.
  invisible(list(cohort_run = cohort_run_id, cohort_stamp = lot_stamp))
}

# Criterion 2: 12 months of CE before that cohort's own index date, over the
# gap-merged spans, because gaps of 30 days or fewer count as continuous. The window is [index - 365, index - 1], the one 06_flags.R uses
# at 1L.
subseq_pre_expr <- function(ix, pre_days) {
  glue("max(CASE WHEN s.cov_start <= date_sub({ix}, {as.integer(pre_days)})",
       " AND s.cov_end >= date_sub({ix}, 1) THEN 1 ELSE 0 END)")
}

# Criterion 3: the follow-up CE window from that index, "with no gaps", so
# over the STRICT spans - a different table from the one above, and the
# difference is the rule. "or death": the window is cut short at the death
# date, and at nothing else. The study end does not truncate it, so a patient
# whose window runs past the data does not qualify on the data's account.
# Floored at the index date, for the same reason as the 1L flag: a death date
# carried from the cohort can precede a later line's start - it was imputed
# against the MM diagnosis - and without the floor the window collapses behind
# the index and enrolment that stops before the line begins passes.
subseq_fu_expr <- function(ix, fu_days, death = "g.DEATH_DT") {
  end <- glue("date_add({ix}, {as.integer(fu_days)})")
  glue("max(CASE WHEN s.cov_start <= {ix}",
       " AND s.cov_end >= greatest({ix}, least({end}, coalesce({death}, {end})))",
       " THEN 1 ELSE 0 END)")
}

# Patients in the 1L cohort who reached LOT `lot_num`, indexed on that line's
# start, with both CE flags.
subseq_cohort_sql <- function(lot_num, from_tbl, out_tbl, pre_days, fu_days,
                              lines_tbl, spans_tbl, spans_strict_tbl, run_id,
                              lot_run = NA_character_, coh_run = NA_character_,
                              coh_stamp = NA_character_,
                              lot_stamp = NA_character_,
                              attempt = NA_character_) {
  pre_days <- as.integer(pre_days); fu_days <- as.integer(fu_days)
  glue("
    CREATE OR REPLACE TABLE {out_tbl} AS
    WITH base AS (
      SELECT cast(c.PATID as string) AS PATID, cast(c.DEATH_DT as date) AS DEATH_DT
      FROM {from_tbl} c
    ),
    idx AS (
      SELECT cast(l.PATID as string) AS PATID,
             min(cast(l.LOT_START_DT as date)) AS COHORT_INDEX_DATE
      FROM {lines_tbl} l
      WHERE l.LOT_NUM = {as.integer(lot_num)}
      GROUP BY cast(l.PATID as string)
    ),
    got AS (
      SELECT b.PATID, b.DEATH_DT, i.COHORT_INDEX_DATE
      FROM base b INNER JOIN idx i ON i.PATID = b.PATID
    ),
    pre AS (
      SELECT g.PATID,
             {subseq_pre_expr('g.COHORT_INDEX_DATE', pre_days)} AS CE_PRE
      FROM got g LEFT JOIN {spans_tbl} s ON s.PATID = g.PATID
      GROUP BY g.PATID
    ),
    fu AS (
      SELECT g.PATID,
             {subseq_fu_expr('g.COHORT_INDEX_DATE', fu_days)} AS CE_FU
      FROM got g LEFT JOIN {spans_strict_tbl} s ON s.PATID = g.PATID
      GROUP BY g.PATID
    )
    SELECT g.PATID, g.COHORT_INDEX_DATE, g.DEATH_DT,
           {as.integer(lot_num)}        AS LOT_NUM,
           coalesce(pre.CE_PRE, 0)      AS CE_PRE,
           coalesce(fu.CE_FU, 0)        AS CE_FU,
           {pre_days}                   AS CE_PRE_DAYS,
           {fu_days}                    AS CE_FU_DAYS,
           {sql_text(run_id)}           AS SUBSEQ_RUN_ID,
           -- Which ATTEMPT of that run id, because the run id does not say.
           -- Two attempts in one Domino execution share it, and the three
           -- outputs are replaced one at a time - so this is the only column
           -- that differs between a table this attempt wrote and one left by
           -- the attempt before it.
           {sql_text(attempt)}          AS SUBSEQ_ATTEMPT,
           -- Which run's lines these were drawn from, and which cohort attempt
           -- those lines were built over. Without them a reader of this table
           -- cannot tell whether it still belongs beside the LOT tables on
           -- disk, and a rebuilt LOT leaves it looking perfectly readable.
           {sql_text(lot_run)}          AS SOURCE_LOT_RUN_ID,
           {sql_text(lot_stamp)}        AS SOURCE_LOT_STAMP,
           {sql_text(coh_run)}          AS SOURCE_COHORT_RUN_ID,
           {sql_text(coh_stamp)}        AS SOURCE_COHORT_STAMP,
           current_timestamp()          AS BUILT_AT
    FROM got g
    LEFT JOIN pre ON pre.PATID = g.PATID
    LEFT JOIN fu  ON fu.PATID  = g.PATID
    WHERE coalesce(pre.CE_PRE, 0) = 1 AND coalesce(fu.CE_FU, 0) = 1")
}

# What each criterion cost, counted off the same expressions the cohort uses.
# Written rather than logged only: a cohort whose funnel nobody can read is a
# number somebody has to take on trust.
#
# Counted over whatever population is passed as from_tbl, so the same query
# answers "how many from the 2L cohort" and "how many there would have been
# from the 1L cohort" - the difference is what chaining costs.
subseq_funnel_sql <- function(lot_num, from_tbl, pre_days, fu_days, lines_tbl,
                              spans_tbl, spans_strict_tbl) {
  glue("
    WITH base AS (
      SELECT cast(PATID as string) AS PATID, cast(DEATH_DT as date) AS DEATH_DT
      FROM {from_tbl}
    ),
    idx AS (
      SELECT cast(PATID as string) AS PATID, min(cast(LOT_START_DT as date)) AS ix
      FROM {lines_tbl} WHERE LOT_NUM = {as.integer(lot_num)}
      GROUP BY cast(PATID as string)
    ),
    got AS (
      SELECT b.PATID, b.DEATH_DT, i.ix
      FROM base b INNER JOIN idx i ON i.PATID = b.PATID
    ),
    pre AS (
      SELECT g.PATID, {subseq_pre_expr('g.ix', pre_days)} AS p
      FROM got g LEFT JOIN {spans_tbl} s ON s.PATID = g.PATID
      GROUP BY g.PATID
    ),
    fu AS (
      SELECT g.PATID, {subseq_fu_expr('g.ix', fu_days)} AS f
      FROM got g LEFT JOIN {spans_strict_tbl} s ON s.PATID = g.PATID
      GROUP BY g.PATID
    ),
    kept AS (
      SELECT g.PATID FROM got g
      JOIN pre ON pre.PATID = g.PATID JOIN fu ON fu.PATID = g.PATID
      WHERE pre.p = 1 AND fu.f = 1
    )
    SELECT (SELECT count(*) FROM base) AS n_from,
           (SELECT count(*) FROM got)  AS n_reached,
           (SELECT count(*) FROM got g JOIN pre ON pre.PATID = g.PATID
             WHERE pre.p = 1)          AS n_ce_pre,
           (SELECT count(*) FROM kept) AS n_final")
}

build_subsequent <- function(here, prefix,
                             pre_days = subseq_days("SUBSEQ_PRE_DAYS", 365L),
                             fu_days  = subseq_days("SUBSEQ_FU_CE_DAYS", 90L)) {
  # Before anything else: a non-contract window pair is a different cohort
  # under the study's table names, so it is refused here rather than after a
  # connection has been spent on it.
  subseq_check_windows(pre_days, fu_days)
  # The same gates the 1L build runs. These cohorts are a subset of that one,
  # so they have to be built under the settings that defined it - a different
  # gap allowance or baseline window here would be a different study.
  check_settings()
  cfg <- pin_output_schema(cfg_defaults)
  cfg <- pin_prefix(cfg, prefix)
  check_contract(cfg)
  check_choices(cfg)
  check_constants(cfg)
  set_lot_config(cfg)
  prefix <- cfg$object_prefix

  stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")
  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  log_msg(SEP)
  log_msg("Subsequent-line cohorts (2L and 3L), prefix ", prefix)
  log_msg("  received that line")
  log_msg("  ", pre_days, " days of CE before its start, gaps <= ",
          cfg$gap_days, " days")
  log_msg("  ", fu_days, " days of CE after it, or death, no gaps")
  # The gap allowance is not settable here. It is baked into the span tables
  # the 1L build wrote, so changing GAP_DAYS moves nothing until that build is
  # re-run - and CONTRACT stops it being changed anyway.
  if (pre_days != as.integer(cfg$pre_lot1_days))
    log_msg("  (the 1L cohort used ", cfg$pre_lot1_days, " days)")
  log_msg("  run ", run_id)
  log_msg(SEP)
  src <- subseq_check_lot_run(con, prefix)

  # Minted here, once, and written into all three outputs below. Everything
  # after this point can leave the warehouse half-written, so from here the
  # attempt is recorded before anything is replaced and the handler that marks
  # it failed is armed before the first replace - the same order build_lot.R
  # and build_ndmm.R use, and for the same reason: a run that dies with a
  # 'started' row and no handler leaves nothing saying it ended.
  attempt <- subseq_attempt_id()
  # Same check the 1L build runs, over this build's own status table. The three
  # outputs carry no run id in their names, so two of these running at once on
  # one prefix interleave and both reach complete having published a pair that
  # is partly the other's. A check, not a lock: two starting at the same instant
  # both pass it. It catches the case worth catching - starting a second while
  # one is going - and NDMM_SUBSEQ_IGNORE_ACTIVE_RUN=TRUE is the way past.
  subseq_check_no_active_run(con, cfg)
  options(subseq_complete = FALSE)
  write_subseq_status(con, cfg, attempt, "started", pre_days, fu_days, src)
  on.exit(if (!isTRUE(getOption("subseq_complete", FALSE)))
            try(write_subseq_status(con, cfg, attempt, "failed",
                                    pre_days, fu_days, src), silent = TRUE),
          add = TRUE, after = FALSE)
  log_msg("  attempt ", attempt)

  cohort <- wrk("NDMM_COHORT")
  lines  <- wrk("LOT_LONG_FINAL")
  spans  <- wrk("NDMM_ENROLL_SPANS")
  strict <- wrk("NDMM_ENROLL_SPANS_STRICT")
  rows <- list(); from <- cohort
  for (n in SUBSEQ_LINES) {
    out <- wrk(paste0("NDMM_COHORT_", n, "L"))
    fun <- function(src) db_q(con, subseq_funnel_sql(
      n, src, pre_days, fu_days, lines, spans, strict))
    f <- fun(from)
    db_exec(con, subseq_cohort_sql(n, from, out, pre_days, fu_days,
                                   lines, spans, strict, run_id,
                                   lot_run = src$lot_run, coh_run = src$cohort_run,
                                   coh_stamp = src$cohort_stamp,
                                   lot_stamp = src$lot_stamp,
                                   attempt = attempt))
    log_msg(n, "L: ", f$n_from, " in the ", if (n == 2L) "1L" else paste0(n - 1L, "L"),
            " cohort -> ", f$n_reached, " reached ", n, "L -> ", f$n_ce_pre,
            " with ", pre_days, " days of CE before it -> ", f$n_final,
            " with ", fu_days, " days after it")
    # What the chain costs: patients who meet this cohort's own criteria off
    # the 1L cohort but are not in the cohort before it. Same query, wider
    # population, so the two numbers are counted the same way.
    excl <- if (identical(from, cohort)) 0 else fun(cohort)$n_final - f$n_final
    if (excl != 0)
      log_msg("  ", excl, " more would qualify on ", n, "L's own criteria but ",
              "are not in the ", n - 1L, "L cohort")
    log_msg("  -> ", out)
    rows[[length(rows) + 1L]] <- data.frame(
      COHORT = paste0(n, "L"), N_FROM = f$n_from, N_REACHED_LOT = f$n_reached,
      N_CE_PRE = f$n_ce_pre, N_FINAL = f$n_final,
      N_EXCLUDED_BY_PRIOR = excl, stringsAsFactors = FALSE)
    # 1L -> 2L -> 3L: each cohort is drawn from the one before it.
    from <- out
  }

  att  <- do.call(rbind, rows)
  num  <- function(x) vapply(x, sql_count, "")
  vals <- paste(sprintf("(%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, current_timestamp())",
                        vapply(att$COHORT, sql_text, ""), num(att$N_FROM),
                        num(att$N_REACHED_LOT), num(att$N_CE_PRE),
                        num(att$N_FINAL), num(att$N_EXCLUDED_BY_PRIOR),
                        sql_count(pre_days), sql_count(fu_days),
                        sql_text(run_id), sql_text(attempt)),
                collapse = ", ")
  db_exec(con, glue("
    CREATE OR REPLACE TABLE {wrk('NDMM_SUBSEQUENT_ATTRITION')} AS
    SELECT * FROM (VALUES {vals})
      AS t(COHORT, N_FROM, N_REACHED_LOT, N_CE_PRE, N_FINAL, N_EXCLUDED_BY_PRIOR,
           CE_PRE_DAYS, CE_FU_DAYS, SUBSEQ_RUN_ID, SUBSEQ_ATTEMPT, BUILT_AT)"))
  log_msg("Wrote ", wrk("NDMM_SUBSEQUENT_ATTRITION"))
  # All three outputs carry this attempt. The run id alone did not distinguish
  # them - a retry inside one Domino execution reuses it - so a run that died
  # between the tables left a mismatch in nothing a reader compared. The
  # attempt is minted per call, so now it does.
  write_subseq_status(con, cfg, attempt, "complete", pre_days, fu_days, src)
  options(subseq_complete = TRUE)
  log_msg("All three tables are stamped SUBSEQ_ATTEMPT = ", attempt,
          " (run ", run_id, "), CE_PRE_DAYS = ", pre_days,
          ", CE_FU_DAYS = ", fu_days)
  log_msg(SEP)
  invisible(TRUE)
}
