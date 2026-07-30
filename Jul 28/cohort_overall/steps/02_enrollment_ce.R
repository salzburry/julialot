# =============================================================================
# 02_enrollment_ce.R -- steps 3 and 4: continuous enrolment
# -----------------------------------------------------------------------------
#   step 3  CE_b = 1   enrolled across the whole baseline (index-183 .. index-1)
#   step 4  CE_f = 1   enrolled on the index date (>=1 day of follow-up)
#
# Baseline excludes the index date, follow-up starts on it, so the two windows
# abut and never overlap.
#
# Two span builds, and both are needed:
#   enrollment_spans         gaps up to GAP_DAYS (30) absorbed  -> CE_b, CE_f
#   enrollment_spans_strict  no gap absorbed                    -> CE_3mosf
# Both from raw member_enrollment, not the CDM's member_cont_enrollment -- that
# table has already absorbed sub-30-day gaps, so it cannot reveal a real one and
# the strict flag would just copy the lenient one.
#
# Coverage is max() over spans, not a sum: one span must cover the window. Two
# spans that together cover the baseline but sit either side of a longer gap do
# not qualify. That is why spans are built first.
#
# CE_3mosf (90-day, strict, death-aware) is derived in 09_assemble.R and is not a
# gate -- it is carried for the LOT build.
# =============================================================================

ie_step_enrollment_ce <- function(cfg, h) {
  work <- h$work; cdm_src <- h$cdm_src

  views <- list(
    ie_view(
      name = "enrollment_spans",
      legacy = "13_enrollment_spans",
      description = "Building enrollment spans with 30-day gap logic from member_enrollment",
      source_tables = c("member_enrollment"),
      select = fmt("
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
      qc = fmt("SELECT count(DISTINCT PATID) AS n_patients FROM {work('enrollment_spans')}")
    ),

    # Same logic without the gap allowance. max(elig_end) over the window rather
    # than lag(), so a short segment nested in a long one is not read as a gap.
    ie_view(
      name = "enrollment_spans_strict",
      legacy = "13b_enrollment_spans_strict",
      description = "Building strict enrollment spans (no gaps, handles overlaps)",
      source_tables = c("member_enrollment"),
      select = fmt("
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
      qc = fmt("SELECT count(DISTINCT PATID) AS n_patients FROM {work('enrollment_spans_strict')}")
    ),

    # Per candidate index date. ENDDATE_CE is the last covered day of the span
    # containing index; 09_assemble.R uses it, and so does the follow-up cap
    # under the sensitivity flag.
    ie_view(
      name = "ce_flags",
      legacy = "14_ce_flags",
      description = "CRITERION: Continuous enrollment (baseline before index, follow-up from index)",
      select = fmt("
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
      qc = fmt("SELECT sum(CE_b) AS n_with_baseline_ce FROM {work('ce_flags')}")
    )
  )

  criteria <- list(
    ie_criterion(
      step = 3L,
      id = "ce_baseline",
      attrition_id = "03_step3_ce_baseline",
      label = "Step 3: 6-mo baseline enrollment",
      flag_col = "CE_b",
      predicate = "CE_b = 1",
      cfg_key = "apply_ce_b_incl",
      polarity = "include",
      note = paste0("One span covering index-", cfg$baseline_days,
                    " .. index-1; gaps up to ", cfg$gap_days, "d absorbed.")
    ),
    ie_criterion(
      step = 4L,
      id = "ce_followup",
      attrition_id = "04_step4_ce_followup",
      label = "Step 4: 1+ day FU enrollment",
      flag_col = "CE_f",
      predicate = "CE_f = 1",
      cfg_key = "apply_ce_f_incl",
      polarity = "include",
      note = "Enrolled on the index date itself."
    )
  )

  list(views = views, criteria = criteria)
}
