-- =========================================================================
--  RUN_ONCE.sql — everything worth asking the warehouse, in one sitting
-- =========================================================================
--
--  Ordered so that a failure late costs the least. Blocks A and B are
--  instant, cannot fail on a column name, and answer several questions on
--  their own. The expensive scans are last on purpose.
--
--  TWO EDITS BEFORE RUNNING
--    1. <COHORT>   -> the cohort table, e.g. myschema.ndmm_NDMM_COHORT
--    2. _2026q1    -> whatever block A says actually exists. The config
--                     resolves to 2026q1; the only describe-table screenshot
--                     in docs/ is 2025q4. Block A tells you; if you can only
--                     run once, do a find-replace to the vintage you believe
--                     is right and let block A confirm it.
--
--  IF A STATEMENT ERRORS and the editor stops: everything above it is still
--  valid output — send that. Each block is independent.
--
--  Roughly 10-15 minutes end to end, almost all of it in blocks G and H.


-- =========================================================================
-- BLOCK A — what exists.                                    ~5 seconds, safe
-- =========================================================================
-- Answers on its own: which vintage the study can actually read, and whether
-- a DOD table exists at all.

SHOW TABLES IN hive_metastore.clnprw_optum;


-- =========================================================================
-- BLOCK B — the shape of every table this study reads.     ~10 seconds, safe
-- =========================================================================
-- This is the highest value-per-risk in the file. It cannot fail on a column
-- name because it asks for the column names. It settles, with no further work:
--
--   * whether ADMIT_DATE / DISCH_DATE / FST_DT are DATE or the documented
--     YYYYMMDD — both builds cast them to date, and casting an integer yields
--     NULL, which would silently drop every hospitalisation;
--   * whether CONFINEMENT.ICD_FLAG is present in this vintage (Q27 rests on it);
--   * whether MEDICAL.PAID_STATUS exists (Q25) and BILL_PROC_CD landed;
--   * what DOD's columns are actually called — the V9 dictionary has a sheet
--     for all fifteen CDM tables and none for DOD, so this is the only source.

DESCRIBE TABLE hive_metastore.clnprw_optum.t_member_enrollment_2026q1;
DESCRIBE TABLE hive_metastore.clnprw_optum.t_confinement_2026q1;
DESCRIBE TABLE hive_metastore.clnprw_optum.t_medical_2026q1;
DESCRIBE TABLE hive_metastore.clnprw_optum.t_diagnosis_2026q1;
DESCRIBE TABLE hive_metastore.clnprw_optum.t_procedure_2026q1;
DESCRIBE TABLE hive_metastore.clnprw_optum.t_rx_2026q1;
DESCRIBE TABLE hive_metastore.clnprw_optum.t_dod_2026q1;
DESCRIBE TABLE <COHORT>;


-- =========================================================================
-- BLOCK C — can DOD be joined at all?      Q26 / Q8.    ~1 minute, low risk
-- =========================================================================
-- THE ONE THAT MATTERS MOST. The Optum business-rules document says DOD
-- "cannot be joined since both tables are encrypted differently"; its own join
-- diagram draws a PATID edge to DOD; and the existing build joins on PATID.
-- DEATH_DT sets follow-up end, censors overall survival, and gates the
-- time-to-event analysis set.
--
--   match_pct near 0  -> the keys are in different encryption domains. Every
--                        death date in both builds is spurious or absent and
--                        OS is unreportable as built.
--   match_pct high    -> the note is stale; nothing to do.

SELECT count(DISTINCT d.PATID)                                  AS dod_patients,
       count(DISTINCT m.PATID)                                  AS matched_in_enrollment,
       round(100.0 * count(DISTINCT m.PATID)
                   / nullif(count(DISTINCT d.PATID), 0), 1)     AS match_pct
FROM       hive_metastore.clnprw_optum.t_dod_2026q1 d
LEFT JOIN (SELECT DISTINCT PATID
           FROM hive_metastore.clnprw_optum.t_member_enrollment_2026q1) m
       ON  m.PATID = d.PATID;

-- Q22: how precise is a death date? Length 6 is year+month; length 4 is year
-- only, which makes the build's constructed day six months wide.
SELECT length(trim(YMDOD)) AS ymdod_length, count(*) AS n,
       min(YMDOD) AS example_lo, max(YMDOD) AS example_hi
FROM   hive_metastore.clnprw_optum.t_dod_2026q1
GROUP BY length(trim(YMDOD)) ORDER BY ymdod_length;


-- =========================================================================
-- BLOCK D — the enrolment columns the demographics table reads.   ~1 minute
-- =========================================================================
-- Q10. RACE and ETHNICITY are varchar(1) and NEITHER value list is published:
-- the dictionary gives RACE's labels only ("African American, Asian,
-- Caucasian, Other/Unknown") and marks ETHNICITY's list "Intentionally Blank".
-- The package currently guesses A->Asian, B->Black, W/C->White. If the coding
-- differs, a whole Table 4 row is mislabelled and nothing would show it.

SELECT RACE, ETHNICITY, RACE_SOURCE, count(*) AS n
FROM   hive_metastore.clnprw_optum.t_member_enrollment_2026q1
GROUP BY RACE, ETHNICITY, RACE_SOURCE ORDER BY n DESC;

-- The package maps BUS 'MCR'->Medicare and 'COM'->Commercial; anything else
-- silently becomes Unknown.
SELECT BUS, PRODUCT, CDHP, count(*) AS n
FROM   hive_metastore.clnprw_optum.t_member_enrollment_2026q1
GROUP BY BUS, PRODUCT, CDHP ORDER BY n DESC LIMIT 40;

-- Is YRDOB capped, and at what? The dictionary says 89 years, changed from 90
-- in April 2025. A cap shows up as a pile-up at the lowest birth year. The age
-- BANDS are unaffected; a mean or median age is right-censored.
SELECT YRDOB, count(*) AS n
FROM   hive_metastore.clnprw_optum.t_member_enrollment_2026q1
GROUP BY YRDOB ORDER BY YRDOB LIMIT 12;


-- =========================================================================
-- BLOCK E — Q24. Does ICD_FLAG ever name neither family?          ~2 minutes
-- =========================================================================
-- Business rule 1 says '9' or '10'. Every code-list join in both builds treats
-- anything else as matching NEITHER family, so such a row silently stops
-- qualifying or excluding anyone. The existing build reports these rather than
-- gating on them; whether that is enough depends on how many there are.

SELECT ICD_FLAG, count(*) AS n
FROM   hive_metastore.clnprw_optum.t_diagnosis_2026q1
GROUP BY ICD_FLAG ORDER BY n DESC;


-- =========================================================================
-- BLOCK F — the cohort as built.        Q26b, Q13, Q16.    ~2 minutes
-- =========================================================================
-- Needs <COHORT>. Death rate is the practical read on block C: a 1L NDMM
-- cohort followed from 2019 should be tens of percent dead — not ~0%, which
-- means the DOD join matches nothing, and not ~100%, which means it matches
-- the wrong people.

SELECT count(*)                                                     AS n_cohort,
       count(DEATH_DT)                                              AS n_with_death,
       round(100.0 * count(DEATH_DT) / count(*), 1)                 AS pct_dead,
       min(DEATH_DT) AS earliest_death, max(DEATH_DT) AS latest_death,
       -- Q13: how often censoring at disenrolment actually bites.
       sum(CASE WHEN ENDDATE_CE < ENDDATE THEN 1 ELSE 0 END)        AS n_censored_early,
       round(avg(datediff(ENDDATE_CE, INDEX_DATE) + 1) / 365.25, 2) AS mean_yrs_censored,
       round(avg(datediff(ENDDATE,    INDEX_DATE) + 1) / 365.25, 2) AS mean_yrs_uncensored
FROM <COHORT>;

-- Q16. MEMBER_ENROLLMENT gets a new row whenever anything changes, and a
-- member with two concurrent plans has two rows covering the same index date.
-- Ranked on ELIGEFF alone those tie and the winner was arbitrary, so race,
-- ethnicity, region and insurance could differ between two runs of identical
-- code. `n_where_rows_disagree` is the size of that exposure.
WITH idx AS (
  SELECT cast(c.PATID as string) AS PATID,
         count(*)                AS n_rows,
         count(DISTINCT e.RACE)  AS n_race,
         count(DISTINCT e.BUS)   AS n_bus,
         count(DISTINCT e.STATE) AS n_state
  FROM       <COHORT> c
  INNER JOIN hive_metastore.clnprw_optum.t_member_enrollment_2026q1 e
          ON cast(e.PATID as string) = cast(c.PATID as string)
         AND e.ELIGEFF <= c.INDEX_DATE AND e.ELIGEND >= c.INDEX_DATE
  GROUP BY cast(c.PATID as string)
)
SELECT count(*)                                                    AS n_matched,
       sum(CASE WHEN n_rows > 1 THEN 1 ELSE 0 END)                 AS n_multi_row_at_index,
       sum(CASE WHEN n_race > 1 OR n_bus > 1 OR n_state > 1
                THEN 1 ELSE 0 END)                                 AS n_where_rows_disagree
FROM idx;


-- =========================================================================
-- BLOCK G — Q25. How much of the medical table is DENIED?      ~3-5 minutes
-- =========================================================================
-- MEDICAL.PAID_STATUS separates PAID from DENIED, and the CDM fills it in
-- where the source left it null. Nothing in either build filters on it, so
-- every count built on medical claims includes denied lines. Restricted to the
-- cohort's own patients to bound the scan.
--
-- A percent or two is a footnote. Ten percent inflates every claims-based rate
-- by roughly that much.

SELECT m.PAID_STATUS, count(*) AS n_lines,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
FROM       hive_metastore.clnprw_optum.t_medical_2026q1 m
INNER JOIN (SELECT DISTINCT cast(PATID as string) AS PATID FROM <COHORT>) c
        ON cast(m.PATID as string) = c.PATID
GROUP BY m.PAID_STATUS ORDER BY n_lines DESC;


-- =========================================================================
-- BLOCK H — Q11. The three ED constructions, side by side.     ~3-5 minutes
-- =========================================================================
-- The CDM has no ED flag and the vendor says so outright: non-inpatient
-- records are classified "as per the study requirements". The three usual
-- constructions select structurally different claim types — RVNU_CD is
-- "Facility Claims only", CPT 9928x is professional — so they disagree by
-- construction, not merely in number.
--
-- `then_admitted` is the sub-question nobody has answered: an ED claim
-- carrying a CONF_ID is one that became an admission (business rule 14). Those
-- are the visits at risk of being counted twice, as an ED visit and again as a
-- hospitalisation.

WITH ed AS (
  SELECT cast(m.PATID as string) AS PATID,
         cast(m.FST_DT as date)  AS dt,
         CASE WHEN upper(regexp_replace(trim(m.RVNU_CD),'[^A-Za-z0-9]',''))
                   RLIKE '^(045[0-9]|0981)$'                THEN 1 ELSE 0 END AS by_rev,
         CASE WHEN trim(m.POS) = '23'                       THEN 1 ELSE 0 END AS by_pos,
         CASE WHEN trim(m.PROC_CD) BETWEEN '99281' AND '99285'
                                                            THEN 1 ELSE 0 END AS by_cpt,
         CASE WHEN m.CONF_ID IS NOT NULL AND trim(m.CONF_ID) <> ''
                                                            THEN 1 ELSE 0 END AS inpat
  FROM       hive_metastore.clnprw_optum.t_medical_2026q1 m
  INNER JOIN (SELECT DISTINCT cast(PATID as string) AS PATID FROM <COHORT>) c
          ON cast(m.PATID as string) = c.PATID
)
SELECT count(DISTINCT CASE WHEN by_rev=1 THEN concat(PATID,'|',cast(dt as string)) END) AS by_revenue,
       count(DISTINCT CASE WHEN by_pos=1 THEN concat(PATID,'|',cast(dt as string)) END) AS by_pos_23,
       count(DISTINCT CASE WHEN by_cpt=1 THEN concat(PATID,'|',cast(dt as string)) END) AS by_cpt_9928x,
       count(DISTINCT CASE WHEN by_rev+by_pos+by_cpt>0
                           THEN concat(PATID,'|',cast(dt as string)) END)                AS any_of_three,
       count(DISTINCT CASE WHEN by_rev+by_pos+by_cpt>0 AND inpat=1
                           THEN concat(PATID,'|',cast(dt as string)) END)                AS then_admitted
FROM ed;
