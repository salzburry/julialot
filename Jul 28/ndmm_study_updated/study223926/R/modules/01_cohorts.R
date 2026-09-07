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

  parent <- if (!is.na(cohort$nested_in))
    sprintf("INNER JOIN %s par ON par.PATID = s.PATID AND par.COHORT = '%s'",
            wrk("S_COHORT"), cohort$nested_in) else ""

  run_step(con, paste0("cohort_", cohort$key), sprintf("
    CREATE TABLE IF NOT EXISTS %1$s (
      PATID string, COHORT string, LOT_NUM int, INDEX_DATE date,
      MET_N1 int, MET_N2 int, MET_I5 int, IN_COHORT int);
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
    LEFT JOIN %8$s fu ON fu.PATID = s.PATID
    %9$s
    WHERE s.LOT_NUM = %10$d %11$s",
    wrk("S_COHORT"), cohort$key, ce_pre, fu_pred, wrk("S_SPINE"),
    cfg$input_cohort_table, wrk("S_ENROLL_SPANS"), wrk("S_FU_CLAIMS"),
    parent, cohort$lot_num, floor_sql),
    qc = sprintf("SELECT count(*) AS n_indexed, sum(IN_COHORT) AS n_in_cohort
                  FROM %s WHERE COHORT = '%s'", wrk("S_COHORT"), cohort$key))
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

# Claims on and after each patient's 1L index, for the I5 readings that need
# one. Cheap because it counts rather than collecting.
build_fu_claims <- function(con, cfg) {
  run_step(con, "fu_claims", sprintf("
    CREATE OR REPLACE TABLE %s AS
    SELECT c.PATID,
           sum(CASE WHEN d.svc_dt >  c.INDEX_DATE THEN 1 ELSE 0 END) AS N_CLAIMS_AFTER_INDEX,
           sum(CASE WHEN d.svc_dt >= c.INDEX_DATE THEN 1 ELSE 0 END) AS N_CLAIMS_FROM_INDEX
    FROM %s c
    LEFT JOIN (
      SELECT cast(PATID as string) AS PATID, cast(FST_DT as date) AS svc_dt
      FROM %s WHERE FST_DT IS NOT NULL
      UNION ALL
      SELECT cast(PATID as string) AS PATID, cast(FILL_DT as date) AS svc_dt
      FROM %s WHERE FILL_DT IS NOT NULL
    ) d ON d.PATID = cast(c.PATID as string)
    GROUP BY c.PATID",
    wrk("S_FU_CLAIMS"), cfg$input_cohort_table,
    cdm_src("medical"), cdm_src("rx")),
    qc = sprintf("SELECT count(*) AS n_pat FROM %s", wrk("S_FU_CLAIMS")))
}
