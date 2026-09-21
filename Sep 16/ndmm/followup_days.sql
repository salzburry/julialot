-- ---------------------------------------------------------------------------
-- Follow-up days, NDMM cohort.
--
-- Paste into a SQL editor and run. It reads the cohort build's own output, so
-- it works as soon as ndmm/build.R has finished - the LOT build is not needed
-- for anything but the last statement.
--
-- The cohort carries two follow-up lengths and they answer different questions:
--
--   FU_DAYS      the day after the index date to death or the study end.
--                Ignores disenrolment. The LOT run's primary analysis.
--   FU_DAYS_CE   the same, also capped where continuous enrolment stops. The
--                protocol's follow-up period (6.1), and what outcomes censors
--                on. Where the two differ, the difference is disenrolment.
--
-- Index is the 1L start, so this is follow-up from 1L and not from diagnosis.
--
-- These are the whole cohort. The dashboard and the POMA workbook restrict to
-- LOT_LONG_FINAL, so their numbers are over fewer patients once the line
-- criteria have run - statement 5 is that comparison. The definitions here are
-- the same ones those two use, so the figures reconcile.
-- ---------------------------------------------------------------------------


-- 1. The one place to edit. Point this at the cohort table you built.
CREATE OR REPLACE TEMPORARY VIEW fu AS
SELECT PATID, INDEX_DATE, ENDDATE, ENDDATE_CE, DEATH_DT, FU_DAYS, FU_DAYS_CE
FROM hive_metastore.usr00000.ndmm_NDMM_COHORT;


-- 2. The distribution, on both definitions. One row each - the two are not a
--    range, and read across a row they look like one.
SELECT `Follow-up ends at`, `Patients`, `Mean`, `Min`, `P25`, `Median`, `P75`, `Max`
FROM (
  SELECT 1 AS ord,
         'Death or study end'                   AS `Follow-up ends at`,
         count(*)                               AS `Patients`,
         round(avg(FU_DAYS), 1)                 AS `Mean`,
         min(FU_DAYS)                           AS `Min`,
         percentile_approx(FU_DAYS, 0.25)       AS `P25`,
         percentile_approx(FU_DAYS, 0.5)        AS `Median`,
         percentile_approx(FU_DAYS, 0.75)       AS `P75`,
         max(FU_DAYS)                           AS `Max`
  FROM fu
  UNION ALL
  SELECT 2,
         '...or disenrolment, whichever is first',
         count(*),
         round(avg(FU_DAYS_CE), 1),
         min(FU_DAYS_CE),
         percentile_approx(FU_DAYS_CE, 0.25),
         percentile_approx(FU_DAYS_CE, 0.5),
         percentile_approx(FU_DAYS_CE, 0.75),
         max(FU_DAYS_CE)
  FROM fu
) f ORDER BY ord;


-- 3. What ended it. A short median because people died and a short median
--    because they left the data are the same number and different findings.
--
--    Partitioned on what ended the CE-bounded follow-up, in this order: a
--    patient who disenrolled and died afterwards counts as disenrolled,
--    because that death is outside the window this cohort observes. The three
--    are mutually exclusive and cover everyone, so the percentages sum to 100.
SELECT CASE
         WHEN DEATH_DT IS NOT NULL AND DEATH_DT <= ENDDATE_CE THEN 'Died'
         WHEN ENDDATE_CE < ENDDATE                            THEN 'Disenrolled'
         ELSE 'Followed to study end'
       END                                                    AS `Follow-up ended by`,
       count(*)                                               AS `Patients`,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1)     AS `% of cohort`,
       percentile_approx(FU_DAYS_CE, 0.5)                     AS `Median FU days (CE)`
FROM fu
GROUP BY 1 ORDER BY 2 DESC;


-- 4. By index year. The study end is fixed, so a later index has less room -
--    any follow-up figure over the whole cohort is an average across this.
SELECT cast(year(INDEX_DATE) as string)                       AS `Index year`,
       count(*)                                               AS `Patients`,
       percentile_approx(FU_DAYS, 0.5)                        AS `Median`,
       percentile_approx(FU_DAYS_CE, 0.5)                     AS `Median (CE)`,
       percentile_approx(FU_DAYS_CE, 0.25)                    AS `P25 (CE)`,
       percentile_approx(FU_DAYS_CE, 0.75)                    AS `P75 (CE)`,
       sum(CASE WHEN DEATH_DT IS NOT NULL AND DEATH_DT <= ENDDATE_CE
                THEN 1 ELSE 0 END)                            AS `Died in FU`
FROM fu
GROUP BY 1 ORDER BY 1;


-- 5. Needs the LOT build. Two things at once: what the line criteria cost in
--    patients, and follow-up by the highest line reached - reaching a later
--    line takes time, so the patients who got there are the ones who had it.
--
--    Edit the LOT table name to match your prefix. Skip this statement until
--    lot/engine/build.R has run.
SELECT concat('LOT', cast(m.max_lot as string))               AS `Highest line`,
       count(*)                                               AS `Patients`,
       percentile_approx(f.FU_DAYS, 0.5)                      AS `Median`,
       percentile_approx(f.FU_DAYS_CE, 0.5)                   AS `Median (CE)`,
       percentile_approx(f.FU_DAYS_CE, 0.25)                  AS `P25 (CE)`,
       percentile_approx(f.FU_DAYS_CE, 0.75)                  AS `P75 (CE)`,
       sum(CASE WHEN f.DEATH_DT IS NOT NULL AND f.DEATH_DT <= f.ENDDATE_CE
                THEN 1 ELSE 0 END)                            AS `Died in FU`
FROM fu f
INNER JOIN (SELECT PATID, max(LOT_NUM) AS max_lot
            FROM hive_metastore.usr00000.ndmm_LOT_LONG_FINAL
            GROUP BY PATID) m
        ON m.PATID = f.PATID
GROUP BY 1 ORDER BY 1;
