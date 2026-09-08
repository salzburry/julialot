# Cohort membership and the attrition funnel.
#
# The 1L cohort's criteria were applied by the cohort build and the LOT build
# between them - I1 to X3 in ndmm/, X4 in lot/engine/R/line_criteria.R - so
# this module does not re-apply them. What it does is:
#
#   * index each selected cohort on the right line's start date,
#   * apply the criteria that are this package's own (N1, N2, I5, and the
#     index-date floors the new protocol adds),
#   * write one funnel per cohort in the order ../IE_CRITERIA.md section 8 sets.
#
# A criterion whose evidence is not in the cohort or LOT tables is named in
# CRITERIA_UNAVAILABLE and stops the run rather than being quietly skipped.

# criterion -> where its verdict comes from. `here` is applied below; `cohort`
# and `lot` were applied upstream and are read off the cohort table's flags.
CRITERION_SOURCE <- c(
  I1_mm_dx          = "cohort", I2_age            = "cohort",
  I3_eligible_1l_tx = "cohort", I4_ce_pre         = "cohort",
  X1_prior_mm_tx    = "cohort", X2_other_cancer   = "cohort",
  X3_pregnancy      = "cohort", X4_belantamab     = "lot",
  I5_followup       = "here",   N1_received_line  = "here",
  N2_ce_pre         = "here"
)

# criterion -> the predicate on S_COHORT that tests it here. A criterion can be
# in both maps: I4/N2 is continuous enrolment before index, which the cohort
# build applied on ITS index date and this package re-applies on the line's
# index date with the protocol's own 30-day gap allowance. Naming it here is
# what makes the 1L and SEC2L funnels show that step's loss instead of
# carrying the count through untouched.
HERE_PRED <- list(
  N1_received_line = "1 = 1",
  I4_ce_pre        = "MET_N2 = 1",
  N2_ce_pre        = "MET_N2 = 1",
  I5_followup      = "MET_I5 = 1"
)

mod_cohorts <- function(con, cfg, cohort) {
  unknown <- setdiff(cohort$criteria, names(CRITERION_SOURCE))
  if (length(unknown))
    stop("COHORT ERROR: ", cohort$key, " names criteria this package cannot ",
         "source: ", paste(unknown, collapse = ", "), ".", call. = FALSE)

  floor_sql <- if (!is.na(cohort$index_from))
    sprintf("AND s.LOT_START_DT >= date('%s')", cfg[[cohort$index_from]]) else ""

  # I5. Three readings, and they are not the same criterion.
  #   claim_from_index  - the protocol's words. The index claim itself is a
  #                       claim on the index date, so this excludes nobody.
  #   claim_after_index - a claim strictly after the index, which is what the
  #                       wording is probably reaching for.
  #   enrolled_on_index - the June 2026 rule the current build implements.
  # ../OPEN_QUESTIONS.md Q5.
  fu_pred <- switch(cfg$fu_evidence_rule,
    claim_from_index  = "1 = 1",
    claim_after_index = "fu.N_CLAIMS_AFTER_INDEX > 0 OR c.DEATH_DT IS NOT NULL",
    enrolled_on_index = "c.ENDDATE_CE >= s.LOT_START_DT")

  # N2. Continuous enrolment before this cohort's own index date, rebuilt from
  # the raw spans because the CDM rollup bridges gaps of LESS than 30 days
  # while the protocol allows 30 or fewer - a day's difference at the boundary,
  # in the stricter direction.
  ce_pre <- sprintf("ce.COV_START <= date_sub(s.LOT_START_DT, %d)
                     AND ce.COV_END >= date_sub(s.LOT_START_DT, 1)",
                    as.integer(cfg$ce_pre_days))

  # The parent must be IN the parent cohort, not merely indexed in it. Without
  # IN_COHORT = 1 a patient who failed the 1L continuous-enrolment test still
  # reaches the 2L cohort, and 2L stops being a subset of 1L.
  parent <- if (!is.na(cohort$nested_in))
    sprintf("INNER JOIN %s par ON par.PATID = s.PATID AND par.COHORT = '%s'
             AND par.IN_COHORT = 1", wrk("S_COHORT"), cohort$nested_in) else ""

  # A re-run replaces this cohort's rows rather than appending a second copy.
  # The parent join reads S_COHORT while this statement writes to it, so the
  # parent's rows are staged into a view first: Spark does not define the
  # result of reading a table an INSERT is writing.
  prepare_table(con, wrk("S_COHORT"),
    "PATID string, COHORT string, LOT_NUM int, INDEX_DATE date,
     MET_N1 int, MET_N2 int, MET_I5 int, IN_COHORT int", cohort$key)
  if (!is.na(cohort$nested_in)) {
    db_exec(con, sprintf(
      "CREATE OR REPLACE TEMPORARY VIEW s_parent_cohort AS
       SELECT PATID FROM %s WHERE COHORT = '%s' AND IN_COHORT = 1",
      wrk("S_COHORT"), cohort$nested_in))
    parent <- "INNER JOIN s_parent_cohort par ON par.PATID = s.PATID"
  }

  run_step(con, paste0("cohort_", cohort$key), sprintf("
    INSERT INTO %1$s
    SELECT s.PATID, '%2$s' AS COHORT, s.LOT_NUM, s.LOT_START_DT AS INDEX_DATE,
           1 AS MET_N1,
           CASE WHEN %3$s THEN 1 ELSE 0 END AS MET_N2,
           CASE WHEN %4$s THEN 1 ELSE 0 END AS MET_I5,
           CASE WHEN (%3$s) AND (%4$s) THEN 1 ELSE 0 END AS IN_COHORT
    FROM %5$s s
    INNER JOIN %6$s c ON c.PATID = s.PATID
    LEFT JOIN %7$s ce
           ON ce.PATID = s.PATID
          AND ce.COV_START <= s.LOT_START_DT AND ce.COV_END >= s.LOT_START_DT
    LEFT JOIN %8$s fu ON fu.PATID = s.PATID AND fu.LOT_NUM = s.LOT_NUM
    %9$s
    WHERE s.LOT_NUM = %10$d %11$s",
    wrk("S_COHORT"), cohort$key, ce_pre, fu_pred, wrk("S_SPINE"),
    cfg$input_cohort_table, wrk("S_ENROLL_SPANS"), wrk("S_FU_CLAIMS"),
    parent, cohort$lot_num, floor_sql),
    qc = sprintf("SELECT count(*) AS n_indexed, sum(IN_COHORT) AS n_in_cohort
                  FROM %s WHERE COHORT = '%s'", wrk("S_COHORT"), cohort$key))
}

# The funnel. One row per criterion, in the order ../IE_CRITERIA.md section 8
# sets, each row applying every criterion above it plus its own - so it reads
# top to bottom and each step's loss is the difference from the row before.
#
# Criteria applied upstream (I1 to X4) are reported as counts carried in rather
# than as losses, because this package cannot re-derive them and a funnel that
# showed them as zero-loss steps would claim they cost nothing.
mod_attrition <- function(con, cfg, cohort) {
  prepare_table(con, wrk("S_ATTRITION"),
    "COHORT string, STEP int, CRITERION string, APPLIED_BY string,
     N_REMAINING int, N_LOST int", cohort$key)

  # The count carried into each step is the population that has passed every
  # criterion at or above it that this package can test. A step whose verdict
  # came from upstream adds no predicate of its own, so it reports the same
  # count as the step before rather than resetting to the unfiltered total -
  # a funnel whose N_REMAINING goes back up is not a funnel.
  #
  # Counted in SQL, in one statement, rather than a db_q() per criterion per
  # cohort. Two reasons, and the second is the one that matters: it is 36
  # warehouse round-trips otherwise, and a count that comes back into R and is
  # written out as a literal is a number no test can reach without a
  # warehouse. In SQL the funnel is checkable against the cohort table it
  # describes.
  cum <- character(0)
  arms <- character(0)
  for (i in seq_along(cohort$criteria)) {
    k <- cohort$criteria[i]
    here <- k %in% names(HERE_PRED)
    src <- CRITERION_SOURCE[[k]]
    applied_by <- if (here && src != "here") paste0(src, "+here") else src
    if (here) cum <- c(cum, HERE_PRED[[k]])
    where <- sprintf("COHORT = '%s'%s", cohort$key,
                     if (length(cum))
                       paste0(" AND ", paste(cum, collapse = " AND ")) else "")
    arms <- c(arms, sprintf(
      "SELECT '%s' AS COHORT, %d AS STEP, '%s' AS CRITERION,
              '%s' AS APPLIED_BY,
              (SELECT count(*) FROM %s WHERE %s) AS N_REMAINING",
      cohort$key, i, k, applied_by, wrk("S_COHORT"), where))
  }

  run_step(con, paste0("attrition_", cohort$key), sprintf("
    INSERT INTO %s
    WITH steps AS (
      %s
    )
    -- N_LOST as the difference from the row above, in the same pass. It was a
    -- MERGE, which needs a Delta table and is the only statement in the
    -- package that did.
    SELECT COHORT, STEP, CRITERION, APPLIED_BY, N_REMAINING,
           cast(lag(N_REMAINING) OVER (PARTITION BY COHORT ORDER BY STEP)
                - N_REMAINING as int) AS N_LOST
    FROM steps",
    wrk("S_ATTRITION"), paste(arms, collapse = "\n      UNION ALL\n      ")),
    qc = sprintf("SELECT count(*) AS n_steps, max(N_REMAINING) AS n_in
                  FROM %s WHERE COHORT = '%s'", wrk("S_ATTRITION"),
                 cohort$key))
  log_msg("  attrition written for ", cohort$key, ": ",
          length(cohort$criteria), " step(s)")
}

# The enrolment spans, built once from the raw table with the protocol's own
# gap allowance. Not the CDM rollup - see above.
build_enroll_spans <- function(con, cfg) {
  run_step(con, "enroll_spans", sprintf("
    CREATE OR REPLACE TABLE %s AS
    WITH base AS (
      SELECT cast(PATID as string) AS PATID,
             cast(ELIGEFF as date) AS elig_eff, cast(ELIGEND as date) AS elig_end
      FROM %s WHERE ELIGEFF IS NOT NULL AND ELIGEND IS NOT NULL
    ),
    ordered AS (
      SELECT *, max(elig_end) OVER (PARTITION BY PATID ORDER BY elig_eff, elig_end
                ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS max_end
      FROM base
    ),
    flagged AS (
      SELECT *, CASE WHEN max_end IS NULL THEN 1
                     WHEN elig_eff <= date_add(max_end, %d + 1) THEN 0
                     ELSE 1 END AS new_grp
      FROM ordered
    ),
    grouped AS (
      SELECT *, sum(new_grp) OVER (PARTITION BY PATID ORDER BY elig_eff, elig_end
                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS grp
      FROM flagged
    )
    SELECT PATID, grp AS SPAN_ID, min(elig_eff) AS COV_START,
           max(elig_end) AS COV_END
    FROM grouped GROUP BY PATID, grp",
    wrk("S_ENROLL_SPANS"), cdm_src("member_enrollment"), as.integer(cfg$gap_days)),
    qc = sprintf("SELECT count(*) AS n_spans, count(DISTINCT PATID) AS n_pat
                  FROM %s", wrk("S_ENROLL_SPANS")))
}

# Claims on and after EACH LINE'S index, for the I5 readings that need one.
#
# Per line, not per patient. It was one row per patient counted against the
# input cohort's INDEX_DATE - the 1L index - and every cohort read that same
# row. Under FU_EVIDENCE_RULE=claim_after_index a single claim falling between
# a patient's 1L and 2L therefore satisfied the after-2L test, and the after-3L
# test, and SEC2L's: one claim admitted a patient to cohorts whose index it
# preceded. The grain has to be the grain the criterion is asked at.
#
# Bounded above by STUDY_END as well: a claim after the study period is not
# evidence of follow-up within it.
build_fu_claims <- function(con, cfg) {
  run_step(con, "fu_claims", sprintf("
    CREATE OR REPLACE TABLE %1$s AS
    SELECT l.PATID, l.LOT_NUM,
           sum(CASE WHEN d.svc_dt >  l.LOT_START_DT THEN 1 ELSE 0 END) AS N_CLAIMS_AFTER_INDEX,
           sum(CASE WHEN d.svc_dt >= l.LOT_START_DT THEN 1 ELSE 0 END) AS N_CLAIMS_FROM_INDEX
    FROM (SELECT cast(PATID as string) AS PATID, cast(LOT_NUM as int) AS LOT_NUM,
                 LOT_START_DT
          FROM %2$s WHERE LOT_NUM <= %5$d) l
    LEFT JOIN (
      SELECT cast(PATID as string) AS PATID, cast(FST_DT as date) AS svc_dt
      FROM %3$s WHERE FST_DT IS NOT NULL
      UNION ALL
      SELECT cast(PATID as string) AS PATID, cast(FILL_DT as date) AS svc_dt
      FROM %4$s WHERE FILL_DT IS NOT NULL
    ) d ON d.PATID = l.PATID AND d.svc_dt <= date('%6$s')
    GROUP BY l.PATID, l.LOT_NUM",
    wrk("S_FU_CLAIMS"), lot_tbl("LOT_LONG_FINAL"),
    cdm_src("medical"), cdm_src("rx"), as.integer(cfg$max_lot),
    cfg$study_end),
    qc = sprintf("SELECT count(*) AS n_rows FROM %s", wrk("S_FU_CLAIMS")))
}
