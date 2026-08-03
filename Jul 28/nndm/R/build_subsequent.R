# The 2L and 3L cohorts, per protocol 6.2.1.1 "Additional eligibility for 2L
# and 3L RRMM Cohorts".
#
# Runs AFTER the LOT build, because the 2L and 3L index dates are line starts
# and only lot knows them. Separate cohorts rather than flags on the lines:
# the protocol says "the subset of patients with evidence of each subsequent
# LOT will be included in the 2L or 3L cohort", which is membership.
#
# Three criteria, and all three are the protocol's:
#
#   1. Received that LOT            - a LOT n row in LOT_LONG_FINAL
#   2. CE >= 12 months before the   - a span covering [index - 365, index - 1],
#      cohort index date              gaps of <= 30 days still continuous
#   3. CE >= 3 months of follow-up  - a NO-GAP span covering [index, index+3mo],
#      from that index, or death      or death inside it
#
# Each cohort is a subset of the one before it, so 3L is taken from 2L rather
# than from the 1L cohort - "each subsequent line is a subset of the prior
# line". A patient who fails at 2L cannot appear at 3L.
#
# Nothing here changes the 1L cohort or the LOT tables. It reads the spans the
# 1L build already checkpointed, so no enrollment rule is written twice.

# Months of follow-up CE these cohorts need. Named here, not written into the
# SQL, for the same reason NDMM_FU_CE_DAYS is named: the 1L cohort's window is
# one day by the study team's answer, and this one is the protocol's three
# months. Two different numbers, so neither should be a literal.
SUBSEQ_FU_CE_MONTHS <- as.integer(Sys.getenv("SUBSEQ_FU_CE_MONTHS", unset = "3"))

# The line dates come from a LOT run, so that run has to have finished and to
# have been built over THIS cohort. The latest status row, whatever state it
# reached: "complete" is written last, so the newest row is the run that last
# wrote the tables - a rerun that replaced them and then failed owns them.
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
  got  <- toupper(trimws(pick("INPUT_COHORT_TABLE")))
  # Schema-qualified either side, so compare the name at the end of it.
  got  <- sub("^.*\\.", "", got)
  if (!is.na(got) && nzchar(got) && !identical(got, want))
    stop("That LOT run was built from '", pick("INPUT_COHORT_TABLE"),
         "', not from ", prefix, "NDMM_COHORT. These cohorts would be a subset ",
         "of a population the lines are not about.", call. = FALSE)
  dev <- pick("CONTRACT_DEVIATIONS")
  if (!is.na(dev) && nzchar(trimws(dev)))
    stop("That LOT run was built with LOT_CONTRACT_OVERRIDE (", dev,
         "), so its lines are an alternative algorithm's.", call. = FALSE)
  log_msg("LOT run ", pick("RUN_ID"), " completed over ", pick("INPUT_COHORT_TABLE"))
  invisible(TRUE)
}

# The two criteria as SQL, shared by the cohort and its funnel so neither can
# drift from the other.
#
# PRE uses the gap-merged spans: the protocol allows gaps of <= 30 days before
# the index. FU uses the STRICT no-gap spans, because it says "with no gaps in
# enrollment". Those are two different tables and the difference is the rule.
#
# Death satisfies the follow-up requirement rather than failing it - the window
# is truncated at the death date, the same way the 1L follow-up CE treats it.
subseq_pre_expr <- function(ix, pre_days) {
  glue("max(CASE WHEN s.cov_start <= date_sub({ix}, {as.integer(pre_days)})",
       " AND s.cov_end >= date_sub({ix}, 1) THEN 1 ELSE 0 END)")
}
subseq_fu_expr <- function(ix, months, study_end, death = "g.DEATH_DT") {
  glue("max(CASE WHEN s.cov_start <= {ix}",
       " AND s.cov_end >= least(add_months({ix}, {as.integer(months)}),",
       " date('{study_end}'), coalesce({death}, date('{study_end}')))",
       " THEN 1 ELSE 0 END)")
}

# Patients in `from_tbl` who reached LOT `lot_num`, with their index date and
# the two CE flags. `from_tbl` is the population the cohort is drawn from -
# 1L for 2L, 2L for 3L, because each line is a subset of the one before it.
subseq_cohort_sql <- function(lot_num, from_tbl, out_tbl, pre_days, months,
                              study_end, lines_tbl, spans_tbl, spans_strict_tbl) {
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
             {subseq_pre_expr('g.COHORT_INDEX_DATE', pre_days)} AS CE_PRE_12MO
      FROM got g LEFT JOIN {spans_tbl} s ON s.PATID = g.PATID
      GROUP BY g.PATID
    ),
    fu AS (
      SELECT g.PATID,
             {subseq_fu_expr('g.COHORT_INDEX_DATE', months, study_end)} AS CE_FU
      FROM got g LEFT JOIN {spans_strict_tbl} s ON s.PATID = g.PATID
      GROUP BY g.PATID
    )
    SELECT g.PATID, g.COHORT_INDEX_DATE, g.DEATH_DT,
           {as.integer(lot_num)}        AS LOT_NUM,
           coalesce(pre.CE_PRE_12MO, 0) AS CE_PRE_12MO,
           coalesce(fu.CE_FU, 0)        AS CE_FU
    FROM got g
    LEFT JOIN pre ON pre.PATID = g.PATID
    LEFT JOIN fu  ON fu.PATID  = g.PATID
    WHERE coalesce(pre.CE_PRE_12MO, 0) = 1 AND coalesce(fu.CE_FU, 0) = 1")
}

# What each criterion cost, counted off the same expressions the cohort uses.
# Written rather than logged only: a cohort whose funnel nobody can read is a
# number somebody has to take on trust.
subseq_funnel_sql <- function(lot_num, from_tbl, pre_days, months, study_end,
                              lines_tbl, spans_tbl, spans_strict_tbl) {
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
      SELECT g.PATID, {subseq_fu_expr('g.ix', months, study_end)} AS f
      FROM got g LEFT JOIN {spans_strict_tbl} s ON s.PATID = g.PATID
      GROUP BY g.PATID
    )
    SELECT (SELECT count(*) FROM base)                              AS n_from,
           (SELECT count(*) FROM got)                               AS n_reached,
           (SELECT count(*) FROM got g JOIN pre ON pre.PATID = g.PATID
             WHERE pre.p = 1)                                       AS n_ce_pre,
           (SELECT count(*) FROM got g JOIN pre ON pre.PATID = g.PATID
             JOIN fu ON fu.PATID = g.PATID
             WHERE pre.p = 1 AND fu.f = 1)                          AS n_final")
}

build_subsequent <- function(here, prefix, months = SUBSEQ_FU_CE_MONTHS) {
  if (length(months) != 1L || is.na(months) || months < 0L)
    stop("SUBSEQ_FU_CE_MONTHS must be a whole number of months.", call. = FALSE)
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
  log_msg("  ", cfg$pre_lot1_days, "-day CE before each index, gaps <= ",
          cfg$gap_days, " days")
  log_msg("  ", months, "-month CE during follow-up, or death, no gaps")
  log_msg(SEP)
  subseq_check_lot_run(con, prefix)

  lines  <- wrk("LOT_LONG_FINAL")
  spans  <- wrk("NDMM_ENROLL_SPANS")
  strict <- wrk("NDMM_ENROLL_SPANS_STRICT")
  rows <- list()
  from <- wrk("NDMM_COHORT")
  for (n in c(2L, 3L)) {
    out <- wrk(paste0("NDMM_COHORT_", n, "L"))
    f <- db_q(con, subseq_funnel_sql(n, from, cfg$pre_lot1_days, months,
                                     cfg$study_end, lines, spans, strict))
    db_exec(con, subseq_cohort_sql(n, from, out, cfg$pre_lot1_days, months,
                                   cfg$study_end, lines, spans, strict))
    log_msg(n, "L: ", f$n_from, " in the ", if (n == 2L) "1L" else "2L",
            " cohort -> ", f$n_reached, " reached ", n, "L -> ", f$n_ce_pre,
            " with 12-month CE -> ", f$n_final, " with ", months,
            "-month follow-up CE")
    log_msg("  -> ", out)
    rows[[length(rows) + 1L]] <- data.frame(
      COHORT = paste0(n, "L"), N_FROM = f$n_from, N_REACHED_LOT = f$n_reached,
      N_CE_PRE_12MO = f$n_ce_pre, N_FINAL = f$n_final, stringsAsFactors = FALSE)
    # 3L is drawn from the 2L cohort, not from 1L: each line is a subset of
    # the line before it.
    from <- out
  }

  att  <- do.call(rbind, rows)
  vals <- paste(mapply(function(...) sprintf(
                  "(%s, %s, %s, %s, %s, current_timestamp())", ...),
                  sql_text(att$COHORT), vapply(att$N_FROM, sql_count, ""),
                  vapply(att$N_REACHED_LOT, sql_count, ""),
                  vapply(att$N_CE_PRE_12MO, sql_count, ""),
                  vapply(att$N_FINAL, sql_count, "")),
                collapse = ", ")
  db_exec(con, glue("
    CREATE OR REPLACE TABLE {wrk('NDMM_SUBSEQUENT_ATTRITION')} AS
    SELECT * FROM (VALUES {vals})
      AS t(COHORT, N_FROM, N_REACHED_LOT, N_CE_PRE_12MO, N_FINAL, RECORDED_AT)"))
  log_msg("Wrote ", wrk("NDMM_SUBSEQUENT_ATTRITION"))
  log_msg(SEP)
  invisible(TRUE)
}
