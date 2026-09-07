-- =========================================================================
--  RUN_ONCE_2.sql — round two. Everything a query can still settle.
-- =========================================================================
--
--  NO PLACEHOLDERS. Block 0 builds a proxy MM population as a temporary view
--  and everything else reuses it, so the whole file runs as-is.
--
--  IF YOU HAVE THE COHORT TABLE, say so by replacing block 0's body with
--      SELECT DISTINCT cast(PATID as string) AS PATID FROM <your cohort table>
--  Four answers get sharper; nothing else changes. Round one skipped every
--  cohort-dependent query, which is why Q11, Q13, Q16 and Q25 are still open.
--
--  Round one already closed Q8, Q10, Q22, Q24 and Q26. This file targets:
--      Q1, Q2, Q5, Q9, Q11, Q13, Q14, Q16, Q19, Q25, Q27, Q28
--  What NO query can answer, now or ever:
--      Q7, Q12, Q15, Q20 — the protocol author or the missing annexes
--      Q21             — arithmetic; the two readings differ by a day count
--      Q3, Q6, Q23     — need Annex 2/3 code lists, i.e. Q15 again
--
--  The 2026q1 vintage is confirmed to exist. Roughly 10 minutes.


-- =========================================================================
-- BLOCK 0 — the population everything else is scoped to.        ~1 minute
-- =========================================================================
-- Anyone with a myeloma diagnosis in the study window. NOT the study cohort -
-- no age, enrolment or exclusion criteria - but it bounds every scan below to
-- the right order of magnitude and needs nothing from outside the CDM.

CREATE OR REPLACE TEMPORARY VIEW mm_pts AS
SELECT DISTINCT cast(PATID as string) AS PATID
FROM   hive_metastore.clnprw_optum.t_med_diagnosis_2026q1
WHERE  cast(FST_DT as date) >= date('2016-01-01')
  AND  upper(regexp_replace(DIAG, '[^A-Za-z0-9]', '')) LIKE 'C90%';

SELECT count(*) AS mm_patients FROM mm_pts;


-- =========================================================================
-- BLOCK 1 — Q28. What is DOD.MBR_MATCH_TYPE?                   ~5 seconds
-- =========================================================================
-- The fifth DOD column, in no Optum document we hold. If it grades how each
-- member was linked to the death record, some fraction of those 11.5M deaths
-- are lower-confidence links and nothing filters on them. Overall survival is
-- a secondary objective.

SELECT MBR_MATCH_TYPE, count(*) AS n,
       round(100.0 * count(*) / sum(count(*)) OVER (), 2) AS pct
FROM   hive_metastore.clnprw_optum.t_dod_2026q1
GROUP BY MBR_MATCH_TYPE ORDER BY n DESC;


-- =========================================================================
-- BLOCK 2 — Q9. Does a member's STATE change?                   ~1 minute
-- =========================================================================
-- REGION is absent from this extract, so region comes from a STATE crosswalk.
-- The open half of Q9 is what to do when STATE changes between enrolment rows.
-- If almost nobody moves, "take the row covering the index date" is a
-- formality. If many do, it is a real choice.

SELECT n_states, count(*) AS n_members
FROM ( SELECT PATID, count(DISTINCT STATE) AS n_states
       FROM   hive_metastore.clnprw_optum.t_member_enrollment_2026q1
       WHERE  STATE IS NOT NULL
       GROUP BY PATID )
GROUP BY n_states ORDER BY n_states;


-- =========================================================================
-- BLOCK 3 — Q16. Do enrolment rows overlap, and do they disagree? ~2 minutes
-- =========================================================================
-- MEMBER_ENROLLMENT gets a new row whenever anything changes, and a member on
-- two concurrent plans has two rows covering the same day. Ranked on ELIGEFF
-- alone the winner was arbitrary, so race, ethnicity, region and insurance
-- could differ between two runs of identical code. The package now breaks the
-- tie on (ELIGEFF, ELIGEND, PAT_PLANID); this says how much was at stake.

WITH pairs AS (
  SELECT a.PATID,
         CASE WHEN a.RACE  IS DISTINCT FROM b.RACE  THEN 1 ELSE 0 END AS d_race,
         CASE WHEN a.BUS   IS DISTINCT FROM b.BUS   THEN 1 ELSE 0 END AS d_bus,
         CASE WHEN a.STATE IS DISTINCT FROM b.STATE THEN 1 ELSE 0 END AS d_state
  FROM       hive_metastore.clnprw_optum.t_member_enrollment_2026q1 a
  INNER JOIN hive_metastore.clnprw_optum.t_member_enrollment_2026q1 b
          ON b.PATID = a.PATID
         AND b.PAT_PLANID <> a.PAT_PLANID
         AND a.ELIGEFF <= b.ELIGEND AND b.ELIGEFF <= a.ELIGEND   -- overlapping
  INNER JOIN mm_pts m ON m.PATID = cast(a.PATID as string)
)
SELECT count(DISTINCT PATID)                                        AS members_with_overlap,
       count(DISTINCT CASE WHEN d_race  = 1 THEN PATID END)         AS disagree_on_race,
       count(DISTINCT CASE WHEN d_bus   = 1 THEN PATID END)         AS disagree_on_bus,
       count(DISTINCT CASE WHEN d_state = 1 THEN PATID END)         AS disagree_on_state
FROM pairs;


-- =========================================================================
-- BLOCK 4 — Q19 and Q13. Enrolment gaps, and what censoring costs. ~2 minutes
-- =========================================================================
-- Q19: the protocol bridges gaps of 30 days or fewer. Those bridged days are
-- covered on paper and unobserved in fact. This says how many days the study
-- would be counting as person-time that nobody was enrolled for.
-- Q13: the same rows price censoring — a member with no gaps is unaffected
-- either way.

WITH spans AS (
  SELECT cast(e.PATID as string) AS PATID,
         cast(e.ELIGEFF as date) AS s,
         cast(e.ELIGEND as date) AS e_end,
         lag(cast(e.ELIGEND as date)) OVER (PARTITION BY e.PATID
                                            ORDER BY e.ELIGEFF) AS prev_end
  FROM       hive_metastore.clnprw_optum.t_member_enrollment_2026q1 e
  INNER JOIN mm_pts m ON m.PATID = cast(e.PATID as string)
),
gaps AS (
  SELECT PATID, datediff(s, prev_end) - 1 AS gap_days
  FROM   spans WHERE prev_end IS NOT NULL AND s > prev_end
)
SELECT count(*)                                                    AS n_gaps,
       count(DISTINCT PATID)                                       AS members_with_a_gap,
       sum(CASE WHEN gap_days <= 30 THEN 1 ELSE 0 END)             AS gaps_bridged_le_30,
       sum(CASE WHEN gap_days <= 30 THEN gap_days ELSE 0 END)      AS bridged_days_total,
       sum(CASE WHEN gap_days = 30 THEN 1 ELSE 0 END)              AS gaps_exactly_30,
       sum(CASE WHEN gap_days = 29 THEN 1 ELSE 0 END)              AS gaps_exactly_29,
       round(avg(gap_days), 1)                                     AS mean_gap_days
FROM gaps;


-- =========================================================================
-- BLOCK 5 — Q2 and Q1. Which MM codes, and which start year.     ~2 minutes
-- =========================================================================
-- Q2: the outpatient arm of I1 may use a broader code set than the inpatient
-- arm. This is every myeloma-adjacent stem actually present, with patient
-- counts, so the study team can see exactly what "broad" would add.
--   C90.0 multiple myeloma   C90.1 plasma cell leukaemia
--   C90.2 plasmacytoma       C88.x malignant immunoproliferative
--   203.0x is the ICD-9 equivalent.

SELECT upper(regexp_replace(DIAG, '[^A-Za-z0-9]', '')) AS code,
       ICD_FLAG,
       count(DISTINCT cast(PATID as string))           AS patients,
       count(*)                                        AS claim_lines
FROM   hive_metastore.clnprw_optum.t_med_diagnosis_2026q1
WHERE  cast(FST_DT as date) >= date('2016-01-01')
  AND (upper(regexp_replace(DIAG, '[^A-Za-z0-9]', '')) LIKE 'C90%'
    OR upper(regexp_replace(DIAG, '[^A-Za-z0-9]', '')) LIKE 'C88%'
    OR upper(regexp_replace(DIAG, '[^A-Za-z0-9]', '')) LIKE '2030%'
    OR upper(regexp_replace(DIAG, '[^A-Za-z0-9]', '')) LIKE '2731%')
GROUP BY 1, 2 ORDER BY patients DESC LIMIT 40;

-- Q1: the study period starts 2016 or 2018, and the figure and the body text
-- disagree. This is what the two years differ by, in patients: the year of
-- each member's FIRST myeloma diagnosis.
SELECT year(first_dx) AS first_dx_year, count(*) AS patients
FROM ( SELECT cast(PATID as string) AS PATID,
              min(cast(FST_DT as date)) AS first_dx
       FROM   hive_metastore.clnprw_optum.t_med_diagnosis_2026q1
       WHERE  upper(regexp_replace(DIAG, '[^A-Za-z0-9]', '')) LIKE 'C90%'
       GROUP BY cast(PATID as string) )
WHERE year(first_dx) BETWEEN 2015 AND 2026
GROUP BY 1 ORDER BY 1;


-- =========================================================================
-- BLOCK 6 — Q25. How much of the medical table is DENIED?        ~3 minutes
-- =========================================================================
-- Skipped in round one because it was scoped to a cohort table that was not
-- supplied. MEDICAL.PAID_STATUS separates PAID from DENIED and nothing in
-- either build filters on it, so every count built on medical claims includes
-- denied lines. A percent or two is a footnote; ten inflates every rate.

SELECT m.PAID_STATUS, count(*) AS n_lines,
       round(100.0 * count(*) / sum(count(*)) OVER (), 2) AS pct
FROM       hive_metastore.clnprw_optum.t_medical_2026q1 m
INNER JOIN mm_pts p ON p.PATID = cast(m.PATID as string)
GROUP BY m.PAID_STATUS ORDER BY n_lines DESC;


-- =========================================================================
-- BLOCK 7 — Q11. The three ED constructions, side by side.       ~3 minutes
-- =========================================================================
-- Also skipped in round one. The CDM has no ED flag and the vendor says the
-- classification is "as per the study requirements". The three constructions
-- select structurally different claim types - RVNU_CD is facility-only, CPT
-- 9928x is professional - so they disagree by construction, not just in
-- number. `then_admitted` is the sub-question: an ED claim carrying a CONF_ID
-- became an admission (business rule 14), and is at risk of being counted
-- twice.

WITH ed AS (
  SELECT cast(m.PATID as string) AS PATID,
         cast(m.FST_DT as date)  AS dt,
         CASE WHEN upper(regexp_replace(trim(m.RVNU_CD),'[^A-Za-z0-9]',''))
                   RLIKE '^(045[0-9]|0981)$'                 THEN 1 ELSE 0 END AS by_rev,
         CASE WHEN trim(m.POS) = '23'                        THEN 1 ELSE 0 END AS by_pos,
         CASE WHEN trim(m.PROC_CD) BETWEEN '99281' AND '99285' THEN 1 ELSE 0 END AS by_cpt,
         CASE WHEN m.CONF_ID IS NOT NULL AND trim(m.CONF_ID) <> ''
                                                             THEN 1 ELSE 0 END AS inpat
  FROM       hive_metastore.clnprw_optum.t_medical_2026q1 m
  INNER JOIN mm_pts p ON p.PATID = cast(m.PATID as string)
  WHERE  cast(m.FST_DT as date) >= date('2018-01-01')
)
SELECT count(DISTINCT CASE WHEN by_rev=1 THEN concat(PATID,'|',cast(dt as string)) END) AS by_revenue_045x,
       count(DISTINCT CASE WHEN by_pos=1 THEN concat(PATID,'|',cast(dt as string)) END) AS by_pos_23,
       count(DISTINCT CASE WHEN by_cpt=1 THEN concat(PATID,'|',cast(dt as string)) END) AS by_cpt_9928x,
       count(DISTINCT CASE WHEN by_rev+by_pos+by_cpt>0
                           THEN concat(PATID,'|',cast(dt as string)) END)                AS any_of_three,
       count(DISTINCT CASE WHEN by_rev=1 AND by_cpt=1
                           THEN concat(PATID,'|',cast(dt as string)) END)                AS revenue_and_cpt_same_day,
       count(DISTINCT CASE WHEN by_rev+by_pos+by_cpt>0 AND inpat=1
                           THEN concat(PATID,'|',cast(dt as string)) END)                AS then_admitted
FROM ed;


-- =========================================================================
-- BLOCK 8 — Q27. The two routes to "MM in first or second position". ~4 min
-- =========================================================================
-- Route A - CONFINEMENT.DIAG1/DIAG2, the stay's own first two diagnoses. This
--           is what the package implements: five positions, stay level.
-- Route B - MED_DIAGNOSIS.DIAG_POSITION 1 or 2 on a claim carrying that
--           CONF_ID, which is the route business rule 13 documents:
--           twenty-five positions, claim line level.
-- If the counts come back close, the choice does not matter. If they differ
-- materially, somebody has to say which one s7.8.1 means.

WITH stays AS (
  SELECT cast(cf.PATID as string) AS PATID, cf.CONF_ID,
         CASE WHEN upper(regexp_replace(coalesce(cf.DIAG1,''),'[^A-Za-z0-9]','')) LIKE 'C90%'
                OR upper(regexp_replace(coalesce(cf.DIAG2,''),'[^A-Za-z0-9]','')) LIKE 'C90%'
              THEN 1 ELSE 0 END AS route_a,
         CASE WHEN upper(regexp_replace(coalesce(cf.DIAG3,''),'[^A-Za-z0-9]','')) LIKE 'C90%'
                OR upper(regexp_replace(coalesce(cf.DIAG4,''),'[^A-Za-z0-9]','')) LIKE 'C90%'
                OR upper(regexp_replace(coalesce(cf.DIAG5,''),'[^A-Za-z0-9]','')) LIKE 'C90%'
              THEN 1 ELSE 0 END AS mm_in_pos_3_to_5
  FROM       hive_metastore.clnprw_optum.t_confinement_2026q1 cf
  INNER JOIN mm_pts p ON p.PATID = cast(cf.PATID as string)
  WHERE  cast(cf.ADMIT_DATE as date) >= date('2018-01-01')
),
route_b AS (
  SELECT DISTINCT cast(m.PATID as string) AS PATID, m.CONF_ID
  FROM       hive_metastore.clnprw_optum.t_medical_2026q1 m
  INNER JOIN hive_metastore.clnprw_optum.t_med_diagnosis_2026q1 d
          ON cast(d.PATID as string) = cast(m.PATID as string)
         AND d.CLMID = m.CLMID
  INNER JOIN mm_pts p ON p.PATID = cast(m.PATID as string)
  WHERE  m.CONF_ID IS NOT NULL AND trim(m.CONF_ID) <> ''
    AND  try_cast(d.DIAG_POSITION as int) IN (1, 2)
    AND  upper(regexp_replace(d.DIAG,'[^A-Za-z0-9]','')) LIKE 'C90%'
)
SELECT count(*)                                                     AS n_stays,
       sum(s.route_a)                                               AS route_a_conf_diag1_2,
       count(b.CONF_ID)                                             AS route_b_claim_pos_1_2,
       sum(CASE WHEN s.route_a=1 AND b.CONF_ID IS NULL THEN 1 ELSE 0 END) AS route_a_only,
       sum(CASE WHEN s.route_a=0 AND b.CONF_ID IS NOT NULL THEN 1 ELSE 0 END) AS route_b_only,
       sum(s.mm_in_pos_3_to_5)                                      AS mm_only_in_conf_pos_3_5
FROM      stays s
LEFT JOIN route_b b ON b.PATID = s.PATID AND b.CONF_ID = s.CONF_ID;


-- =========================================================================
-- BLOCK 9 — Q5 and Q14. Two boundary readings, priced.           ~3 minutes
-- =========================================================================
-- Q5: "evidence of follow-up" is at least one claim from the index date. Read
-- literally the index claim itself satisfies it and it excludes nobody. These
-- three counts are the three readings, against each member's first myeloma
-- diagnosis as a stand-in index.
-- Q14: how many members have a claim exactly ON that date - the population
-- that moves when the baseline window includes or excludes the index day.

WITH idx AS (
  SELECT cast(PATID as string) AS PATID, min(cast(FST_DT as date)) AS ix
  FROM   hive_metastore.clnprw_optum.t_med_diagnosis_2026q1
  WHERE  upper(regexp_replace(DIAG,'[^A-Za-z0-9]','')) LIKE 'C90%'
    AND  cast(FST_DT as date) >= date('2018-01-01')
  GROUP BY cast(PATID as string)
),
clm AS (
  SELECT i.PATID, i.ix,
         max(CASE WHEN cast(m.FST_DT as date) >= i.ix THEN 1 ELSE 0 END) AS from_index,
         max(CASE WHEN cast(m.FST_DT as date) >  i.ix THEN 1 ELSE 0 END) AS after_index,
         max(CASE WHEN cast(m.FST_DT as date)  = i.ix THEN 1 ELSE 0 END) AS on_index
  FROM       idx i
  INNER JOIN hive_metastore.clnprw_optum.t_medical_2026q1 m
          ON cast(m.PATID as string) = i.PATID
  GROUP BY i.PATID, i.ix
)
SELECT count(*)              AS n_members,
       sum(from_index)       AS have_a_claim_from_index,
       sum(after_index)      AS have_a_claim_after_index,
       sum(on_index)         AS have_a_claim_on_index,
       count(*) - sum(after_index) AS excluded_by_the_stricter_reading
FROM clm;
