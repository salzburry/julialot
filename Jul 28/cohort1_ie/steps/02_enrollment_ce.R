# =============================================================================
# 02_enrollment_ce.R -- IE Steps 3 and 4: continuous enrollment
# -----------------------------------------------------------------------------
#   Step 3  CE_b = 1   enrolled across the WHOLE baseline (index-183d .. index-1)
#   Step 4  CE_f = 1   enrolled ON the index date (>=1 day of follow-up)
#
# Baseline EXCLUDES the index date; follow-up STARTS on it. So the two windows
# abut and never overlap, and a patient enrolled from exactly index-183 through
# exactly index passes both.
#
# TWO SPAN BUILDS, AND WHY THERE HAVE TO BE TWO
#   enrollment_spans         gaps of <= GAP_DAYS (30) absorbed   -> CE_b, CE_f
#   enrollment_spans_strict  no gap absorbed at all              -> CE_3mosf
# Both are built from RAW member_enrollment rather than the CDM's prebuilt
# member_cont_enrollment, which has already absorbed sub-30-day gaps and
# therefore cannot reveal a true one. Reading the prebuilt table would make the
# strict flag a copy of the lenient one.
#
# CE_3mosf (90-day, death-aware, no gaps) is derived in 09_assemble.R and is NOT
# an IE gate here -- it is carried for downstream LOT work. Kept where the study
# put it rather than promoted to a criterion, because promoting it would change
# the cohort.
#
# The window is a max() over spans, not a sum: enrollment must be covered by ONE
# span. Two adjacent spans that jointly cover the baseline but are separated by a
# gap longer than GAP_DAYS do not qualify -- which is the whole point of building
# spans first instead of testing each raw segment.
# =============================================================================

ie_step_enrollment_ce <- function(cfg, h) {
  work <- h$work; cdm_src <- h$cdm_src

  views <- list(
    ie_view(
      name = "enrollment_spans",
      legacy = "13_enrollment_spans",
      description = "Building enrollment spans with 30-day gap logic from member_enrollment",
      source_tables = c("member_enrollment"),
      sql = fmt("
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
      qc = fmt("SELECT count(DISTINCT PATID) AS n_patients FROM {work('enrollment_spans')}")
    ),

    # Identical logic with the gap allowance removed. max(elig_end) over the
    # window rather than lag() so a short segment nested inside a long one does
    # not read as a gap.
    ie_view(
      name = "enrollment_spans_strict",
      legacy = "13b_enrollment_spans_strict",
      description = "Building strict enrollment spans (no gaps, handles overlaps)",
      source_tables = c("member_enrollment"),
      sql = fmt("
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
      qc = fmt("SELECT count(DISTINCT PATID) AS n_patients FROM {work('enrollment_spans_strict')}")
    ),

    # Per candidate index date. ENDDATE_CE (last covered day of the span that
    # contains index) is emitted here and used by 09_assemble.R and, under the
    # sensitivity flag, by the follow-up cap.
    ie_view(
      name = "ce_flags",
      legacy = "14_ce_flags",
      description = "CRITERION: Continuous enrollment (baseline before index, follow-up from index)",
      sql = fmt("
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
      note = paste0("One span must cover all of index-", cfg$baseline_days,
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
      note = "Enrolled on the index date itself -- follow-up starts on index."
    )
  )

  list(views = views, criteria = criteria)
}
