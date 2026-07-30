# =============================================================================
# 04_enrollment.R -- Phase 4-5 -- Steps 3 and 4: continuous enrollment.
# -----------------------------------------------------------------------------
# Lifted from apr_30_2026/R/pipeline_steps.R. Every SQL line below is
# byte-identical to the source; only this function's first line changed,
# because the helpers it used to close over are now passed in.
# =============================================================================

phase_enrollment <- function(cfg, h, ctx) {
  full_name <- h$full_name; cdm <- h$cdm; ref <- h$ref
  work <- h$work; work_tbl <- h$work_tbl; cdm_src <- h$cdm_src
  criteria_sql <- ctx$criteria_sql
  fu_cap_expr <- ctx$fu_cap_expr
  ce_join_for_fu_cap <- ctx$ce_join_for_fu_cap
  mm_dx_source <- ctx$mm_dx_source
  mm_therapy_source <- ctx$mm_therapy_source
  preg_source <- ctx$preg_source
  clintrial_source <- ctx$clintrial_source
  other_malig_source <- ctx$other_malig_source

  list(
    # ---- Phase 4: enrollment spans (feed CE gates, Steps 3-4) ----
    # Build continuous spans from raw member_enrollment, absorbing gaps
    # of <= gap_days. We don't use prebuilt member_cont_enrollment so the
    # gap logic stays identical across baseline and follow-up.
    list(
      name = "13_enrollment_spans",
      description = "Building enrollment spans with 30-day gap logic from member_enrollment",
      source_tables = c("member_enrollment"),
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('enrollment_spans')} AS
        WITH base AS (
          -- Use member_enrollment (raw) with 30-day gap allowance
          SELECT PATID, cast(ELIGEFF as date) AS elig_eff, cast(ELIGEND as date) AS elig_end
          FROM {cdm_src(cfg$tbl_member_enrollment)}
          WHERE ELIGEFF IS NOT NULL AND ELIGEND IS NOT NULL
        ),
        ordered AS (
          SELECT *,
            -- Use max(elig_end) seen so far to handle overlapping/nested segments
            max(elig_end) OVER (
              PARTITION BY PATID
              ORDER BY elig_eff, elig_end
              ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
            ) AS max_end_so_far
          FROM base
        ),
        flagged AS (
          SELECT *,
            -- Allow gaps <= {cfg$gap_days} days: new group if elig_eff > max_end_so_far + gap_days + 1
            CASE WHEN max_end_so_far IS NULL THEN 1
                 WHEN elig_eff <= date_add(max_end_so_far, {cfg$gap_days} + 1) THEN 0
                 ELSE 1 END AS new_grp
          FROM ordered
        ),
        grouped AS (
          SELECT *,
            sum(new_grp) OVER (PARTITION BY PATID ORDER BY elig_eff, elig_end
                               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS grp_id
          FROM flagged
        )
        SELECT PATID, grp_id, min(elig_eff) AS cov_start, max(elig_end) AS cov_end
        FROM grouped
        GROUP BY PATID, grp_id
      "),
      qc = glue("SELECT count(DISTINCT PATID) AS n_patients FROM {work('enrollment_spans')}")
    ),

    # ---- Phase 4b: strict enrollment spans (no gaps) ----
    # CE_3mosf allows no gaps, so build from raw member_enrollment - the
    # prebuilt member_cont_enrollment already absorbs <30-day gaps and
    # can't reveal true ones. Use max(elig_end) over the window (not
    # lag()) so a short segment after a long one is handled correctly.
    list(
      name = "13b_enrollment_spans_strict",
      description = "Building strict enrollment spans (no gaps, handles overlaps)",
      source_tables = c("member_enrollment"),
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('enrollment_spans_strict')} AS
        WITH base AS (
          -- Use member_enrollment (raw) to detect ALL gaps
          SELECT PATID, cast(ELIGEFF as date) AS elig_eff, cast(ELIGEND as date) AS elig_end
          FROM {cdm_src(cfg$tbl_member_enrollment)}
          WHERE ELIGEFF IS NOT NULL AND ELIGEND IS NOT NULL
        ),
        ordered AS (
          SELECT *,
            -- Use max(elig_end) so far (not just the previous row) so
            -- overlapping/nested segments are handled correctly
            max(elig_end) OVER (
              PARTITION BY PATID
              ORDER BY elig_eff, elig_end
              ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
            ) AS max_end_so_far
          FROM base
        ),
        flagged AS (
          SELECT *,
            -- NO allowable gaps: new group if elig_eff > max_end_so_far + 1
            CASE WHEN max_end_so_far IS NULL THEN 1
                 WHEN elig_eff <= date_add(max_end_so_far, 1) THEN 0
                 ELSE 1 END AS new_grp
          FROM ordered
        ),
        grouped AS (
          SELECT *,
            sum(new_grp) OVER (PARTITION BY PATID ORDER BY elig_eff, elig_end
                               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS grp_id
          FROM flagged
        )
        SELECT PATID, grp_id, min(elig_eff) AS cov_start, max(elig_end) AS cov_end
        FROM grouped
        GROUP BY PATID, grp_id
      "),
      qc = glue("SELECT count(DISTINCT PATID) AS n_patients FROM {work('enrollment_spans_strict')}")
    ),

    # ---- Phase 5: CE flags - CE_b (Step 3) and CE_f (Step 4) ----
    # Baseline runs index-baseline_days .. index-1; CE_b needs a span
    # covering all of it. CE_f needs a span covering the index date
    # itself (follow-up starts on index). CE_3mosf comes later, in
    # Step 23 (death-aware, no gaps).
    list(
      name = "14_ce_flags",
      description = "CRITERION: Continuous enrollment (baseline before index, follow-up from index)",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('ce_flags')} AS
        WITH idx AS (
          SELECT PATID, index_date,
                 date_sub(index_date, {cfg$baseline_days}) AS baseline_start,
                 date_sub(index_date, 1) AS baseline_end
          FROM {work('mm_qualifying')}
        ),
        -- CE_b and CE_f use standard enrollment spans (with 30-day allowable gaps)
        -- Baseline excludes index_date; CE_f requires enrollment on index_date (follow-up starts on index)
        joined_std AS (
          SELECT i.PATID, i.index_date, i.baseline_start, i.baseline_end,
                 s.cov_start, s.cov_end,
                 CASE WHEN s.cov_start <= i.baseline_start AND s.cov_end >= i.baseline_end
                      THEN 1 ELSE 0 END AS covers_baseline,
                 -- CE_f: requires enrollment covering index_date (follow-up starts on index)
                 CASE WHEN s.cov_start <= i.index_date AND s.cov_end >= i.index_date
                      THEN 1 ELSE 0 END AS has_1day_followup
          FROM idx i
          LEFT JOIN {work('enrollment_spans')} s ON i.PATID = s.PATID
        )
        SELECT PATID, index_date, baseline_start, baseline_end,
               max(covers_baseline) AS CE_b,
               max(has_1day_followup) AS CE_f,
               max(CASE WHEN has_1day_followup = 1 THEN cov_end END) AS ENDDATE_CE
        FROM joined_std
        GROUP BY PATID, index_date, baseline_start, baseline_end
      "),
      qc = glue("SELECT sum(CE_b) AS n_with_baseline_ce FROM {work('ce_flags')}")
    )
  )
}
