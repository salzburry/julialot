# =============================================================================
# 03_demographics.R -- IE Step 2: age at index (plus the death date)
# -----------------------------------------------------------------------------
#   Step 2  AGE_INDEX_YR >= MIN_AGE
#
# THE ONE CRITERION WITH NO FLAG VIEW OF ITS OWN
# Age is not computed as a 0/1 flag anywhere. member_demo supplies YRDOB, and
# 09_assemble.R derives
#       AGE_INDEX_YR = year(INDEX_DATE) - YRDOB
# on the assembled row. So the "flag" this criterion reads is an integer, and its
# predicate is a comparison rather than `= 1`.
#
# Note what that means: age is in WHOLE YEARS from the birth YEAR, not from a
# birth date -- Optum supplies YRDOB only. A patient turning 18 later in their
# index year already counts as 18. That is the study definition, and the label
# says so ("at index year"). It is not an approximation introduced here.
#
# member_demo picks ONE row per patient: prefer a usable gender code, then the
# latest ELIGEND. So a patient whose gender was 'U' on their most recent segment
# keeps the coded value from an earlier one, rather than losing it.
#
# ---------------------------------------------------------------------------
# THE DEATH DATE IS HERE BECAUSE THE FOLLOW-UP WINDOW DEPENDS ON IT
# ---------------------------------------------------------------------------
# Not a criterion. But Steps 5/6, 9 and 10 all cap follow-up at
# least(study_end, death), so death_dt has to exist before any of them.
#
# Optum DOD is partial: YYYYMM or YYYY. Coarsening it naively can place death
# BEFORE the index date and make FU_DAYS negative, so:
#   month known  -> the 15th, or month-end if index is later in that same month
#   year only    -> Jul 15,   or Dec 31   if index is later in that same year
# and then a final clamp, DEATH_DT >= index_date, for anything the rules miss.
# The output is keyed by (PATID, index_date) precisely because the coarsening
# depends on which candidate index you are asking about.
# =============================================================================

ie_step_demographics <- function(cfg, h) {
  work <- h$work; cdm_src <- h$cdm_src

  views <- list(
    ie_view(
      name = "member_demo",
      legacy = "15_member_demo",
      description = "Extracting patient demographics (age/gender)",
      source_tables = c("member_cont_enrollment"),
      sql = fmt("
        CREATE OR REPLACE TEMPORARY VIEW {work('member_demo')} AS
        WITH ranked AS (
          SELECT PATID, GDR_CD, cast(YRDOB as int) AS YRDOB,
                 row_number() OVER (PARTITION BY PATID
                   ORDER BY CASE WHEN upper(GDR_CD) NOT IN ('U','') THEN 0 ELSE 1 END,
                            cast(ELIGEND as date) DESC) AS rn
          FROM {cdm_src(cfg$tbl_member_elig)}
        )
        SELECT PATID, GDR_CD, YRDOB FROM ranked WHERE rn = 1
      "),
      qc = fmt("SELECT count(*) AS n_patients FROM {work('member_demo')}")
    ),

    ie_view(
      name = "death_dt",
      legacy = "15b_death_dt",
      description = "Deriving death dates (month->15th, year-only uses July15/Dec31 rule)",
      source_tables = c("dod"),
      sql = fmt("
        CREATE OR REPLACE TEMPORARY VIEW {work('death_dt')} AS
        WITH raw_death AS (
          SELECT
            PATID,
            cast(SUBSTR(YMDOD, 1, 4) as int) AS death_yr,
            CASE
              WHEN LENGTH(TRIM(YMDOD)) >= 6 THEN cast(SUBSTR(YMDOD, 5, 2) as int)
              ELSE NULL
            END AS death_mo
          FROM {cdm_src(cfg$tbl_dod)}
          WHERE YMDOD IS NOT NULL AND LENGTH(TRIM(YMDOD)) >= 4
        ),
        ranked AS (
          SELECT *,
                 row_number() OVER (PARTITION BY PATID ORDER BY death_yr DESC, death_mo DESC NULLS LAST) AS rn
          FROM raw_death
        ),
        best AS (
          SELECT PATID, death_yr, NULLIF(death_mo, 0) AS death_mo
          FROM ranked
          WHERE rn = 1
        ),
        calc AS (
          SELECT
            q.PATID,
            q.index_date,
            CASE
              WHEN b.death_yr IS NULL THEN NULL
              WHEN b.death_mo IS NOT NULL THEN
                -- Month-level: use 15th unless index_date > 15th in same month, then use month-end
                CASE
                  WHEN year(q.index_date) = b.death_yr
                   AND month(q.index_date) = b.death_mo
                   AND q.index_date > make_date(b.death_yr, b.death_mo, 15)
                  THEN last_day(make_date(b.death_yr, b.death_mo, 1))
                  ELSE make_date(b.death_yr, b.death_mo, 15)
                END
              ELSE
                -- Year-only: use July 15 unless index_date > July 15 in same year, then Dec 31
                CASE
                  WHEN year(q.index_date) = b.death_yr
                   AND q.index_date > make_date(b.death_yr, 7, 15)
                  THEN make_date(b.death_yr, 12, 31)
                  ELSE make_date(b.death_yr, 7, 15)
                END
            END AS death_raw
          FROM {work('mm_qualifying')} q
          LEFT JOIN best b ON q.PATID = b.PATID
        )
        -- Final clamp: ensure DEATH_DT >= index_date (prevents negative FU_DAYS from data issues)
        -- NOTE: Output includes index_date since death can be relative to each potential index
        SELECT
          PATID,
          index_date,
          CASE
            WHEN death_raw IS NOT NULL AND death_raw < index_date THEN index_date
            ELSE death_raw
          END AS DEATH_DT
        FROM calc
      "),
      qc = fmt("SELECT count(*) AS n_with_death_dt FROM {work('death_dt')} WHERE DEATH_DT IS NOT NULL")
    )
  )

  criteria <- list(
    ie_criterion(
      step = 2L,
      id = "age_at_index",
      attrition_id = "02_step2_age",
      label = fmt("Step 2: Age >= {cfg$min_age} at index year"),
      flag_col = "AGE_INDEX_YR",
      predicate = fmt("AGE_INDEX_YR >= {cfg$min_age}"),
      cfg_key = "apply_age_incl",
      polarity = "include",
      note = paste("year(INDEX_DATE) - YRDOB, derived in the assembly step.",
                   "Whole years from the birth YEAR; Optum has no birth date.")
    )
  )

  list(views = views, criteria = criteria)
}
