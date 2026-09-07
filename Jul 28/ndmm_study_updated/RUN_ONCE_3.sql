-- =========================================================================
--  RUN_ONCE_3.sql — the two loose ends round two left.        ~3 minutes
-- =========================================================================
--
--  Round two (SQL Result 2.pdf) priced sixteen questions. Two things it did
--  not settle, both because of how the query was written rather than what the
--  data holds:
--
--    Q13  the gap query counted a contiguous re-enrolment as a gap, so the
--         160,945 "bridged" figure is mostly zeros and the number of MEMBERS
--         with a genuine break is still unknown. The 109,679 bridged-days
--         figure is unaffected - zeros contribute nothing - so Q19 stands.
--
--    STATE  53 distinct values came back, ordered by descending count, and
--         the tail was not captured. CENSUS_REGION carries 51. Two values are
--         falling to region Unknown and nobody knows which.
--
--  NO PLACEHOLDERS. Block 0 rebuilds the same proxy population round two used,
--  so the numbers are directly comparable to it.


-- =========================================================================
-- BLOCK 0 — the same proxy population as round two.            ~1 minute
-- =========================================================================

CREATE OR REPLACE TEMPORARY VIEW mm_pts AS
SELECT DISTINCT cast(PATID as string) AS PATID
FROM   hive_metastore.clnprw_optum.t_med_diagnosis_2026q1
WHERE  cast(FST_DT as date) >= date('2016-01-01')
  AND  upper(regexp_replace(DIAG, '[^A-Za-z0-9]', '')) LIKE 'C90%';


-- =========================================================================
-- BLOCK 1 — Q13. Members with a real break in enrolment.       ~2 minutes
-- =========================================================================
-- A boundary is only a gap if the next span starts more than one day after
-- the last one ended. Round two's `gap_days <= 30` bucket counted the
-- contiguous case (gap_days = 0) as bridged, which is why 160,945 of 202,108
-- boundaries landed in it. This splits the boundaries properly and counts
-- MEMBERS, which is the unit censoring applies to.
--
-- `members_with_a_break_over_30` is the population Q13 moves: censor at
-- disenrollment and they lose their follow-up from that point; bridge and
-- they keep it.

WITH spans AS (
  SELECT cast(e.PATID as string) AS PATID,
         cast(e.ELIGEFF as date) AS s,
         lag(cast(e.ELIGEND as date)) OVER (PARTITION BY e.PATID
                                            ORDER BY e.ELIGEFF) AS prev_end
  FROM       hive_metastore.clnprw_optum.t_member_enrollment_2026q1 e
  INNER JOIN mm_pts m ON m.PATID = cast(e.PATID as string)
),
gaps AS (
  SELECT PATID, datediff(s, prev_end) - 1 AS gap_days
  FROM   spans WHERE prev_end IS NOT NULL AND s > prev_end
)
SELECT n.mm_members,
       count(DISTINCT CASE WHEN g.gap_days = 0 THEN g.PATID END)          AS members_contiguous_only,
       count(DISTINCT CASE WHEN g.gap_days BETWEEN 1 AND 30
                           THEN g.PATID END)                             AS members_with_a_bridged_gap,
       count(DISTINCT CASE WHEN g.gap_days > 30 THEN g.PATID END)        AS members_with_a_break_over_30,
       sum(CASE WHEN g.gap_days BETWEEN 1 AND 30 THEN 1 ELSE 0 END)      AS n_bridged_gaps,
       sum(CASE WHEN g.gap_days > 30 THEN 1 ELSE 0 END)                  AS n_breaks_over_30,
       round(avg(CASE WHEN g.gap_days > 30 THEN g.gap_days END), 1)      AS mean_break_days
FROM      (SELECT count(*) AS mm_members FROM mm_pts) n
LEFT JOIN gaps g ON true
GROUP BY n.mm_members;


-- =========================================================================
-- BLOCK 2 — the two STATE values the census crosswalk does not map. ~1 min
-- =========================================================================
-- Asked the other way round from round two: not the top 70 by count, but
-- everything that is NOT one of the 51 the crosswalk carries. Whatever comes
-- back is silently becoming region Unknown today.

SELECT coalesce(STATE, '(null)')      AS unmapped_state,
       count(*)                       AS enrolment_rows,
       count(DISTINCT PATID)          AS members
FROM   hive_metastore.clnprw_optum.t_member_enrollment_2026q1
WHERE  STATE IS NULL
   OR  upper(trim(STATE)) NOT IN (
         'CT','ME','MA','NH','RI','VT','NJ','NY','PA',
         'IL','IN','MI','OH','WI','IA','KS','MN','MO','NE','ND','SD',
         'DE','DC','FL','GA','MD','NC','SC','VA','WV','AL','KY','MS',
         'TN','AR','LA','OK','TX',
         'AZ','CO','ID','MT','NV','NM','UT','WY','AK','CA','HI','OR','WA')
GROUP BY 1 ORDER BY enrolment_rows DESC;
