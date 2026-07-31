# Enrollment spans, with the gap semantics the parent's CE_b/CE_f use.
#
# Ported from apr_30_2026/06_ndmm_dashboard.R lines 143-198.
# tests/test_same_as_source.R compares this against that range.

                                       unset = "member_enrollment")
NDMM_GAP_DAYS              <- as.integer(Sys.getenv("GAP_DAYS",
                                                  unset = "30"))
NDMM_FINAL_TABLE_NAME      <- Sys.getenv("FINAL_TABLE_NAME",
                                       unset = "ELIG_COH_FINAL")

# Build enrollment_spans (with NDMM_GAP_DAYS allowance) directly from
# member_enrollment - the parent's temp view isn't persisted, so we
# rebuild it inside this script. SQL mirrors pipeline_steps.R:382-421
# verbatim so the gap semantics stay identical to CE_b/CE_f.
build_enrollment_spans_ndmm <- function(con, view = NDMM_ENROLL_SPANS,
                                        gap_days = NDMM_GAP_DAYS) {
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {view} AS
    WITH base AS (
      SELECT PATID,
             cast(ELIGEFF as date) AS elig_eff,
             cast(ELIGEND as date) AS elig_end
      FROM {cdm_src(NDMM_TBL_MEMBER_ENROLLMENT)}
      WHERE ELIGEFF IS NOT NULL AND ELIGEND IS NOT NULL
    ),
    ordered AS (
      SELECT *,
        max(elig_end) OVER (
          PARTITION BY PATID
          ORDER BY elig_eff, elig_end
          ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ) AS max_end_so_far
      FROM base
    ),
    flagged AS (
      SELECT *,
        CASE WHEN max_end_so_far IS NULL THEN 1
             WHEN elig_eff <= date_add(max_end_so_far, {gap_days} + 1) THEN 0
             ELSE 1 END AS new_grp
      FROM ordered
    ),
    grouped AS (
      SELECT *,
        sum(new_grp) OVER (PARTITION BY PATID ORDER BY elig_eff, elig_end
                           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS grp_id
      FROM flagged
    )
    SELECT PATID, grp_id,
           min(elig_eff) AS cov_start,
           max(elig_end) AS cov_end
    FROM grouped
    GROUP BY PATID, grp_id
  "))
}

# LOT1_START_DT per patient (the '1L cohort index date'), with the
# NDMM_LOT1_FROM cutoff enforced. Patients whose LOT1 starts before the
# cutoff are dropped from this view, which then propagates to every
# downstream NDMM step (CE / belantamab / MM-Tx / other-cancer all join
# from here).
