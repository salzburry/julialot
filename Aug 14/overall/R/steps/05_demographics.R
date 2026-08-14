# Step 2: age at index, and the death date that caps follow-up.

phase_demographics <- function(cfg, h, ctx) {
  work <- h$work; cdm_src <- h$cdm_src

  list(
    # ---- Phase 6: demographics (age -> Step 2) + death date ----
    list(
      name = "15_member_demo",
      description = "Extracting patient demographics (age/gender)",
      source_tables = c("member_cont_enrollment"),
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('member_demo')} AS
        WITH ranked AS (
          SELECT PATID, GDR_CD, cast(YRDOB as int) AS YRDOB,
                 row_number() OVER (PARTITION BY PATID
                   -- A usable birth year first, ahead of a known sex. Age decides
                   -- membership and sex does not, so ranking sex above it lost
                   -- patients: an 'M' row with no YRDOB outranked a 'U' row carrying
                   -- 1980, the patient came out with no birth year, and the age
                   -- filter then dropped someone eligible. Whatever the row's date,
                   -- and now whatever its sex.
                   ORDER BY CASE WHEN cast(YRDOB as int) IS NOT NULL THEN 0 ELSE 1 END,
                            CASE WHEN upper(GDR_CD) NOT IN ('U','') THEN 0 ELSE 1 END,
                            cast(ELIGEND as date) DESC,
                            -- Ties broken by the values themselves, so the same input
                            -- always gives the same patient. Two rows sharing one
                            -- ELIGEND with YRDOB 1980 and 2010 could otherwise make
                            -- the same person 40 and eligible on one run, 10 and
                            -- excluded on the next.
                            cast(YRDOB as int), GDR_CD) AS rn
          FROM {cdm_src(cfg$tbl_member_elig)}
        )
        SELECT PATID, GDR_CD, YRDOB FROM ranked WHERE rn = 1
      "),
      qc = glue("SELECT count(*) AS n_patients FROM {work('member_demo')}")
    ),

    # ---- Phase 6b: death date ----
    # Coarsen partial death dates: month-only -> the 15th, year-only ->
    # Jul 15. If that lands before the index date in the same period,
    # bump to the period end (month-end / Dec 31) so DEATH_DT is never
    # earlier than INDEX_DATE, which would make FU_DAYS negative.
    list(
      name = "15b_death_dt",
      description = "Deriving death dates (month->15th, year-only uses July15/Dec31 rule)",
      source_tables = c("dod"),
      sql = glue("
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
      qc = glue("SELECT count(*) AS n_with_death_dt FROM {work('death_dt')} WHERE DEATH_DT IS NOT NULL")
    )
  )
}
