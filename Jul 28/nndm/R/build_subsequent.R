# The 2L and 3L cohorts, per protocol 6.2.1.1 "Additional eligibility for 2L
# and 3L RRMM Cohorts".
#
# Runs AFTER the LOT build, because the 2L and 3L index dates are line starts
# and only lot knows them. Separate cohorts rather than flags on the lines:
# 6.2.1.1 says the additional criteria "will be applied to the 1L cohort to
# create the subset cohorts", which is membership.
#
# "To be eligible for each 2L or 3L cohorts, patients must meet the following
# criteria" - three, and no others:
#
#   1. "Received a subsequent LOT required to qualify for a specific cohort
#       (i.e., received a 2L treatment for 2L, 3L for 3L cohort)"
#   2. "Continuous enrollment (CE) for each cohort: CE of at least 12-months
#       with medical and pharmacy benefits before the cohort index date (2L or
#       3L). Patients with gaps in enrolment of <= 30 days are considered to be
#       continuously enrolled"
#   3. "CE during follow-up for each cohort: CE of at least 3-months during
#       follow-up or death with no gaps in enrollment" - counted as 90 days,
#       see SUBSEQ_FU_CE_DAYS below
#
# Death is the stated alternative to the follow-up window, and the only one.
# The study end is not: a living patient whose window runs past the data has
# not shown the enrolment, so the window is truncated at death and at nothing
# else.
#
# Each cohort is drawn from the one before it: 2L from the 1L cohort, 3L from
# the 2L cohort. The study design note says "each subsequent line is a subset
# of the prior line", and the study team reads that as a cohort rule - the
# progression is 1L -> 2L -> 3L, so a patient who is not in the 2L cohort is
# not in the 3L cohort.
#
# Receiving the lines in order is guaranteed anyway: lines are numbered
# sequentially, so a LOT 3 row implies a LOT 2 row. What chaining adds is that
# the 2L cohort's ENROLMENT windows must also have been met. Those are not the
# same test - a patient can have a gap that fails the follow-up window after
# 2L and still be fully enrolled for the 365 days before 3L and 90 after it.
# N_EXCLUDED_BY_PRIOR counts them: patients who meet 3L's own three criteria
# and are dropped only for not being in the 2L cohort.
#
# Nothing here changes the 1L cohort or the LOT tables. It reads the spans the
# 1L build already checkpointed, so no enrollment rule is written twice.

SUBSEQ_LINES <- c(2L, 3L)

# The two windows, as settings of their own rather than the 1L cohort's.
#
# SUBSEQ_PRE_DAYS is days of CE before the cohort index date - 365 for the
# protocol's 12 months. It is NOT PRE_LOT1_DAYS: that one is pinned by
# CONTRACT to the value the 1L cohort was built with, so it cannot be moved
# without redefining that cohort. These are a separate question.
#
# SUBSEQ_FU_CE_DAYS is days of follow-up CE - 90 for the protocol's 3 months,
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

# The lines come from a LOT run, so that run has to have finished, to have been
# built over THIS cohort, and to have been built over the cohort attempt that
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
  if (!is.na(got) && nzchar(got) && !identical(got, want))
    stop("That LOT run was built from '", pick("INPUT_COHORT_TABLE"),
         "', not from ", prefix, "NDMM_COHORT. These cohorts would be a subset ",
         "of a population the lines are not about.", call. = FALSE)
  dev <- pick("CONTRACT_DEVIATIONS")
  if (!is.na(dev) && nzchar(trimws(dev)))
    stop("That LOT run was built with LOT_CONTRACT_OVERRIDE (", dev,
         "), so its lines are an alternative algorithm's.", call. = FALSE)
  log_msg("LOT run ", pick("RUN_ID"), " completed over ", pick("INPUT_COHORT_TABLE"))
  # Which cohort attempt it read is NOT in the status table - it is in
  # LOT_RUN_METADATA, on the row for this run.
  subseq_check_cohort_attempt(con, pick("RUN_ID"))
  invisible(TRUE)
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
    log_msg("  ", tbl, " has no row - the cohort attempt cannot be compared.")
    return(invisible(FALSE))
  }
  pick <- function(nm) {
    i <- match(toupper(nm), toupper(names(d)))
    if (is.na(i)) NA_character_ else as.character(d[[i]][1])
  }
  now_id <- pick("RUN_ID"); now_stamp <- pick("UPDATED_AT")
  # LOT writes NULL here when it could not find a cohort status table at all.
  # Nothing recorded is nothing to compare, and saying so is honest; inventing
  # a match would not be.
  if (is.na(lot_cohort_id) || !nzchar(trimws(lot_cohort_id))) {
    log_msg("  ", meta, " records no cohort attempt for run ", lot_run_id,
            ", so it cannot be compared to NNDM run ", now_id, ".")
    return(invisible(FALSE))
  }
  lot_run_id <- lot_cohort_id
  eq <- function(a, b) {
    a <- trimws(as.character(a)); b <- trimws(as.character(b))
    length(a) == 1L && length(b) == 1L && !is.na(a) && !is.na(b) && identical(a, b)
  }
  same <- eq(lot_run_id, now_id) &&
    (is.na(lot_stamp) || !nzchar(trimws(lot_stamp)) || eq(lot_stamp, now_stamp))
  if (!same)
    stop("The LOT lines were built over NNDM run ", lot_run_id, " (", lot_stamp,
         "), but ", tbl, " now holds run ", now_id, " (", now_stamp,
         "). The cohort and the enrollment spans on disk are a later attempt ",
         "than the lines, so eligibility would be worked out from enrollment ",
         "data that did not produce the population the lines are about. ",
         "Re-run the LOT build.", call. = FALSE)
  log_msg("  Cohort attempt ", now_id, " matches the one the LOT run read.")
  invisible(TRUE)
}

# Criterion 2: 12 months of CE before that cohort's own index date, over the
# gap-merged spans, because the protocol counts gaps of 30 days or fewer as
# continuous. The window is [index - 365, index - 1], the one 06_flags.R uses
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
subseq_fu_expr <- function(ix, fu_days, death = "g.DEATH_DT") {
  end <- glue("date_add({ix}, {as.integer(fu_days)})")
  glue("max(CASE WHEN s.cov_start <= {ix}",
       " AND s.cov_end >= least({end}, coalesce({death}, {end}))",
       " THEN 1 ELSE 0 END)")
}

# Patients in the 1L cohort who reached LOT `lot_num`, indexed on that line's
# start, with both CE flags.
subseq_cohort_sql <- function(lot_num, from_tbl, out_tbl, pre_days, fu_days,
                              lines_tbl, spans_tbl, spans_strict_tbl, run_id) {
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
  log_msg("Subsequent-line cohorts (protocol 6.2.1.1), prefix ", prefix)
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
  subseq_check_lot_run(con, prefix)

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
                                   lines, spans, strict, run_id))
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
  vals <- paste(sprintf("(%s, %s, %s, %s, %s, %s, %s, %s, %s, current_timestamp())",
                        vapply(att$COHORT, sql_text, ""), num(att$N_FROM),
                        num(att$N_REACHED_LOT), num(att$N_CE_PRE),
                        num(att$N_FINAL), num(att$N_EXCLUDED_BY_PRIOR),
                        sql_count(pre_days), sql_count(fu_days),
                        sql_text(run_id)),
                collapse = ", ")
  db_exec(con, glue("
    CREATE OR REPLACE TABLE {wrk('NDMM_SUBSEQUENT_ATTRITION')} AS
    SELECT * FROM (VALUES {vals})
      AS t(COHORT, N_FROM, N_REACHED_LOT, N_CE_PRE, N_FINAL, N_EXCLUDED_BY_PRIOR,
           CE_PRE_DAYS, CE_FU_DAYS, SUBSEQ_RUN_ID, BUILT_AT)"))
  log_msg("Wrote ", wrk("NDMM_SUBSEQUENT_ATTRITION"))
  # All three outputs carry this run id. A run that died between them leaves
  # one table stamped with an older one, and the mismatch is the evidence.
  log_msg("All three tables are stamped SUBSEQ_RUN_ID = ", run_id,
          ", CE_PRE_DAYS = ", pre_days, ", CE_FU_DAYS = ", fu_days)
  log_msg(SEP)
  invisible(TRUE)
}
