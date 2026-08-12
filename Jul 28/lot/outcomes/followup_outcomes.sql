-- ---------------------------------------------------------------------------
-- Follow-up as the outcomes build sees it.
--
-- Paste into a SQL editor and run. Needs lot/outcomes/build.R to have finished.
--
-- This is NOT the cohort follow-up in ndmm/followup_days.sql, and the two do
-- not reconcile. That one is a row per PATIENT, measured from the index date.
-- This is a row per patient-LINE, measured from each line's own start - the
-- window TTNT, TTD and OS were actually observed over. A patient with three
-- lines is three rows here and one there.
--
-- FU_END_DT is the earlier of death, the study end and the end of continuous
-- enrolment. It is the same boundary as FU_DAYS_CE on the cohort table.
-- ---------------------------------------------------------------------------


-- 1. The one place to edit. Point these at the run you want.
CREATE OR REPLACE TEMPORARY VIEW tte  AS
SELECT * FROM hive_metastore.osk02156.ndmm_OUT_TTE;

CREATE OR REPLACE TEMPORARY VIEW attr AS
SELECT * FROM hive_metastore.osk02156.ndmm_OUT_ATTRITION;


-- 1b. RUN THIS FIRST. The two tables are separate writes, so a run that died
--     between them leaves one from this attempt and one from the last. Both
--     stay readable, and nothing further down would notice.
--
--     One row, and `Same run` must be `yes`. LOT_RUN_ID says which LOT run
--     outcomes read: if it does not match the LOT build you think you are
--     describing, these numbers are about a different set of lines.
SELECT (SELECT count(DISTINCT OUT_RUN_ID) FROM tte)             AS `Runs in OUT_TTE`,
       (SELECT count(DISTINCT OUT_RUN_ID) FROM attr)            AS `Runs in OUT_ATTRITION`,
       (SELECT max(OUT_RUN_ID) FROM tte)                        AS `Outcomes run`,
       (SELECT max(LOT_RUN_ID) FROM tte)                        AS `LOT run it read`,
       CASE WHEN (SELECT count(DISTINCT OUT_RUN_ID) FROM tte)  = 1
             AND (SELECT count(DISTINCT OUT_RUN_ID) FROM attr) = 1
             AND (SELECT max(OUT_RUN_ID) FROM tte)
                 = (SELECT max(OUT_RUN_ID) FROM attr)
            THEN 'yes' ELSE 'NO - the two tables are from different runs'
       END                                                      AS `Same run`;


-- 2. Observed follow-up per line, and how many events each endpoint got.
--    The event counts are the point: a median TTNT is only readable if enough
--    lines reached the event. A line that is almost all censored has a median
--    the data cannot support, and the median alone does not say so.
--
--    `Line-eligible` is NULL, not 0, where no line-specific cohort exists.
--    outcomes means the difference: not eligible and not asked are different
--    answers, and a 0 there would read as "nobody qualified" for a line where
--    nobody was assessed.
SELECT LOT_NUM                                                     AS `Line`,
       count(*)                                                    AS `Lines`,
       sum(CASE WHEN LINE_ELIGIBLE = 1 THEN 1
                WHEN LINE_ELIGIBLE = 0 THEN 0 END)                 AS `Line-eligible`,
       percentile_approx(datediff(FU_END_DT, LOT_START_DT), 0.25)  AS `P25 days`,
       percentile_approx(datediff(FU_END_DT, LOT_START_DT), 0.5)   AS `Median days`,
       percentile_approx(datediff(FU_END_DT, LOT_START_DT), 0.75)  AS `P75 days`,
       max(datediff(FU_END_DT, LOT_START_DT))                      AS `Max days`,
       sum(TTNT_EVENT)                                             AS `TTNT events`,
       sum(TTD_EVENT)                                              AS `TTD events`,
       sum(OS_EVENT)                                               AS `Deaths`
FROM tte
GROUP BY LOT_NUM ORDER BY LOT_NUM;


-- 3. The same, restricted to lines whose patient is in that line's own cohort.
--    Both denominators are reported by the build and neither is the study's
--    answer on its own - see lot/outcomes/README.md. Run 2 and 3 together or
--    neither. Quoting one is picking a denominator silently.
--
--    Conditional aggregation rather than WHERE LINE_ELIGIBLE = 1, so a line
--    with no eligibility cohort still gets a row, with NULLs. Filtered, it
--    would return no row at all, and a missing row reads as a line that does
--    not exist rather than one nobody asked the question of.
SELECT LOT_NUM                                                     AS `Line`,
       sum(CASE WHEN LINE_ELIGIBLE = 1 THEN 1
                WHEN LINE_ELIGIBLE = 0 THEN 0 END)                 AS `Line-eligible`,
       percentile_approx(CASE WHEN LINE_ELIGIBLE = 1
                              THEN datediff(FU_END_DT, LOT_START_DT) END, 0.5)
                                                                   AS `Median days`,
       sum(CASE WHEN LINE_ELIGIBLE = 1 THEN TTNT_EVENT END)        AS `TTNT events`,
       sum(CASE WHEN LINE_ELIGIBLE = 1 THEN OS_EVENT END)          AS `Deaths`
FROM tte
GROUP BY LOT_NUM ORDER BY LOT_NUM;


-- 4. Censored versus observed, per endpoint. What is left after an endpoint
--    fires is the follow-up that endpoint never got to use.
SELECT LOT_NUM                                                     AS `Line`,
       count(*)                                                    AS `Lines`,
       round(100.0 * sum(TTNT_EVENT) / nullif(count(*), 0), 1)     AS `% TTNT observed`,
       round(100.0 * sum(TTD_EVENT)  / nullif(count(*), 0), 1)     AS `% TTD observed`,
       round(100.0 * sum(OS_EVENT)   / nullif(count(*), 0), 1)     AS `% died`,
       percentile_approx(CASE WHEN TTNT_EVENT = 0 THEN TTNT_DAYS END, 0.5)
                                                                   AS `Median censored TTNT days`
FROM tte
GROUP BY LOT_NUM ORDER BY LOT_NUM;


-- 5. The attrition categories, read straight off the build.
--
--    N_LOST_TO_FU and N_ONGOING are NOT the cohort-level died/disenrolled/
--    study-end split. They are what is left after N_NEXT_LOT, N_DIED and
--    N_DISCON_NO_NEXT have been taken out - patients still on treatment when
--    observation stopped - divided by WHY it stopped. Do not try to reconcile
--    them with the dashboard's Cohort tab. The reconciliation that does hold
--    is statement 6.
SELECT DENOM                       AS `Denominator`,
       LOT_NUM                     AS `Line`,
       N_ON_LINE                   AS `On line`,
       N_NEXT_LOT                  AS `Next LOT`,
       N_DIED                      AS `Died`,
       N_DISCON_NO_NEXT            AS `Discontinued, no next`,
       N_LOST_TO_FU                AS `Lost to follow-up`,
       N_ONGOING                   AS `Still on treatment at study end`
FROM attr
ORDER BY DENOM, LOT_NUM;


-- 6. The reconciliation that holds: the five categories partition the line.
--    Any row where `Difference` is not 0 is a build problem, not a rounding
--    one - they are counts, not percentages.
SELECT DENOM                                                       AS `Denominator`,
       LOT_NUM                                                     AS `Line`,
       N_ON_LINE                                                   AS `On line`,
       N_NEXT_LOT + N_DIED + N_DISCON_NO_NEXT
         + N_LOST_TO_FU + N_ONGOING                                AS `Sum of the five`,
       N_ON_LINE - (N_NEXT_LOT + N_DIED + N_DISCON_NO_NEXT
         + N_LOST_TO_FU + N_ONGOING)                               AS `Difference`
FROM attr
ORDER BY DENOM, LOT_NUM;
