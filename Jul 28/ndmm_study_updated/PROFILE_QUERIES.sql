-- Profiling queries for the study team
-- =====================================
--
-- Each block answers a specific open question from OPEN_QUESTIONS.md. They are
-- ordered by how much turns on the answer. Every one is a count or a group-by;
-- none writes anything.
--
-- Two placeholders to set before running:
--   <WORK>     the schema the cohort build wrote to      e.g. hive_metastore.myschema
--   <PREFIX>   OBJECT_PREFIX from Jul 28/ndmm/config.csv e.g. ndmm_
--
-- The CDM quarter below is written as 2026q1, which is what STUDY_END=2026-03-31
-- resolves to. Block 0 checks that vintage exists - the describe-table
-- screenshot in docs/ is 2025q4, so they may not be the same.


-- ---------------------------------------------------------------------------
-- 0.  Does the vintage the config points at exist?           (2 seconds)
-- ---------------------------------------------------------------------------
-- If these come back empty, every table name in this file needs its suffix
-- changed, and so does STUDY_END or USE_QUARTERLY_TABLES.

SHOW TABLES IN hive_metastore.clnprw_optum LIKE 't_*_2026q1';
SHOW TABLES IN hive_metastore.clnprw_optum LIKE 't_dod*';


-- ---------------------------------------------------------------------------
-- 1.  Can DOD be joined at all?             OPEN_QUESTIONS Q26   (~1 minute)
-- ---------------------------------------------------------------------------
-- THE IMPORTANT ONE. The Optum business-rules document says DOD "cannot be
-- joined" to the claims tables because it is encrypted with a different key;
-- its own join diagram draws a PATID edge to DOD; and the existing build joins
-- on PATID. DEATH_DT sets follow-up end, censors overall survival, and gates
-- the time-to-event analysis set.
--
-- 1a is the decisive test, and it needs no cohort: how many DOD patients exist
-- in the enrolment table at all?
--
--   match_pct near 0    -> the keys are in different encryption domains. The
--                          note is right, every death date is spurious or
--                          absent, and OS is unreportable as built.
--   match_pct high      -> the keys are compatible and the note is stale.
--   match_pct in between-> ask Optum; a partial match is its own problem.

SELECT count(DISTINCT d.PATID)                                   AS dod_patients,
       count(DISTINCT m.PATID)                                   AS matched_in_enrollment,
       round(100.0 * count(DISTINCT m.PATID)
                   / nullif(count(DISTINCT d.PATID), 0), 1)      AS match_pct
FROM        hive_metastore.clnprw_optum.t_dod_2026q1 d
LEFT JOIN  (SELECT DISTINCT PATID
            FROM hive_metastore.clnprw_optum.t_member_enrollment_2026q1) m
       ON  m.PATID = d.PATID;

-- 1b. The same question asked of the cohort actually built. A 1L NDMM cohort
--     followed from 2019 should be tens of percent dead - not ~0%, not ~100%.

SELECT count(*)                                                  AS n_cohort,
       count(DEATH_DT)                                           AS n_with_death,
       round(100.0 * count(DEATH_DT) / count(*), 1)              AS pct_dead,
       min(DEATH_DT)                                             AS earliest,
       max(DEATH_DT)                                             AS latest
FROM <WORK>.<PREFIX>NDMM_COHORT;


-- ---------------------------------------------------------------------------
-- 2.  RACE and ETHNICITY code values          OPEN_QUESTIONS Q10  (~30 seconds)
-- ---------------------------------------------------------------------------
-- Both are varchar(1) and neither value list is published. The dictionary gives
-- RACE's labels only - "African American, Asian, Caucasian, Other/Unknown" -
-- and marks ETHNICITY's list "Intentionally Blank" because the column is a V9
-- addition.
--
-- The package currently guesses A->Asian, B->Black, W/C->White. If the real
-- coding differs, that guess silently mislabels a whole demographic row.
-- Table 4 wants Asian / Black / White / Unknown.

SELECT RACE, ETHNICITY, RACE_SOURCE, count(*) AS n
FROM   hive_metastore.clnprw_optum.t_member_enrollment_2026q1
GROUP BY RACE, ETHNICITY, RACE_SOURCE
ORDER BY n DESC;

-- 2b. Insurance type and the columns the demographics table reads. The package
--     maps BUS 'MCR'->Medicare and 'COM'->Commercial; anything else becomes
--     Unknown, so a different coding empties the column silently.

SELECT BUS, PRODUCT, CDHP, count(*) AS n
FROM   hive_metastore.clnprw_optum.t_member_enrollment_2026q1
GROUP BY BUS, PRODUCT, CDHP
ORDER BY n DESC
LIMIT 50;


-- ---------------------------------------------------------------------------
-- 3.  The deployed shape of the other five tables               (10 seconds)
-- ---------------------------------------------------------------------------
-- There is a describe-table screenshot for member_enrollment and nothing else.
-- Everything this study assumes about the other five is inferred from the
-- dictionary plus that one example. These settle:
--   * whether ADMIT_DATE / DISCH_DATE / FST_DT are DATE or the documented
--     YYYYMMDD - the package casts them to date, which silently yields NULL
--     for an integer and would drop every hospitalisation;
--   * whether CONFINEMENT.ICD_FLAG is actually present in this vintage;
--   * whether BILL_PROC_CD (a V9 addition) landed on MEDICAL.

DESCRIBE TABLE hive_metastore.clnprw_optum.t_confinement_2026q1;
DESCRIBE TABLE hive_metastore.clnprw_optum.t_medical_2026q1;
DESCRIBE TABLE hive_metastore.clnprw_optum.t_diagnosis_2026q1;
DESCRIBE TABLE hive_metastore.clnprw_optum.t_procedure_2026q1;
DESCRIBE TABLE hive_metastore.clnprw_optum.t_rx_2026q1;
DESCRIBE TABLE hive_metastore.clnprw_optum.t_dod_2026q1;


-- ---------------------------------------------------------------------------
-- 4.  Is YRDOB capped, and at what?                             (~30 seconds)
-- ---------------------------------------------------------------------------
-- The V9 dictionary says "capped at 89 years", changed in April 2025 from a cap
-- at 90. A cap shows up as a pile-up at the lowest birth year. The age BANDS
-- are unaffected either way; a mean or median age is right-censored.

SELECT YRDOB, count(*) AS n
FROM   hive_metastore.clnprw_optum.t_member_enrollment_2026q1
GROUP BY YRDOB
ORDER BY YRDOB
LIMIT 12;


-- ---------------------------------------------------------------------------
-- 5.  How much do denied claims matter?       OPEN_QUESTIONS Q25  (~2 minutes)
-- ---------------------------------------------------------------------------
-- MEDICAL.PAID_STATUS separates PAID from DENIED, and nothing in either build
-- has ever filtered on it. Restricted to the cohort's own patients to keep the
-- scan bounded.
--
-- If DENIED is a percent or two, this is a footnote. If it is ten, every rate
-- built on medical claims is inflated by roughly that much.

SELECT m.PAID_STATUS, count(*) AS n_lines,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
FROM       hive_metastore.clnprw_optum.t_medical_2026q1 m
INNER JOIN (SELECT DISTINCT cast(PATID as string) AS PATID
            FROM <WORK>.<PREFIX>NDMM_COHORT) c
        ON cast(m.PATID as string) = c.PATID
GROUP BY m.PAID_STATUS
ORDER BY n_lines DESC;


-- ---------------------------------------------------------------------------
-- 6.  The three ED constructions, side by side  OPEN_QUESTIONS Q11 (~3 minutes)
-- ---------------------------------------------------------------------------
-- The CDM has no ED flag and the vendor says so outright: "Non-inpatient
-- records can be classified into various categories as per the study
-- requirements". The three usual constructions select structurally different
-- claim types - RVNU_CD is "Facility Claims only", CPT 9928x is professional -
-- so they disagree by construction, not just by number.
--
-- `became_inpatient` is the sub-question: an ED claim carrying a CONF_ID is one
-- that turned into an admission (business rule 14). That is what ED_ADMITTED
-- switches on.

WITH coh AS (
  SELECT DISTINCT cast(PATID as string) AS PATID
  FROM <WORK>.<PREFIX>NDMM_COHORT
),
ed AS (
  SELECT cast(m.PATID as string) AS PATID,
         cast(m.FST_DT as date)  AS dt,
         CASE WHEN upper(regexp_replace(trim(m.RVNU_CD),'[^A-Za-z0-9]',''))
                   RLIKE '^(045[0-9]|0981)$'            THEN 1 ELSE 0 END AS by_revenue,
         CASE WHEN trim(m.POS) = '23'                   THEN 1 ELSE 0 END AS by_pos,
         CASE WHEN trim(m.PROC_CD) BETWEEN '99281' AND '99285'
                                                        THEN 1 ELSE 0 END AS by_cpt,
         CASE WHEN m.CONF_ID IS NOT NULL
               AND trim(m.CONF_ID) <> ''                THEN 1 ELSE 0 END AS became_inpatient
  FROM       hive_metastore.clnprw_optum.t_medical_2026q1 m
  INNER JOIN coh ON coh.PATID = cast(m.PATID as string)
)
SELECT count(DISTINCT CASE WHEN by_revenue = 1 THEN concat(PATID, dt) END) AS visits_revenue,
       count(DISTINCT CASE WHEN by_pos     = 1 THEN concat(PATID, dt) END) AS visits_pos,
       count(DISTINCT CASE WHEN by_cpt     = 1 THEN concat(PATID, dt) END) AS visits_cpt,
       count(DISTINCT CASE WHEN by_revenue + by_pos + by_cpt > 0
                           THEN concat(PATID, dt) END)                     AS visits_any,
       count(DISTINCT CASE WHEN by_revenue + by_pos + by_cpt > 0
                            AND became_inpatient = 1
                           THEN concat(PATID, dt) END)                     AS visits_then_admitted
FROM ed;


-- ---------------------------------------------------------------------------
-- 7.  Which inpatient definition agrees with CONFINEMENT?        (~2 minutes)
-- ---------------------------------------------------------------------------
-- Business rule 14 gives two approaches. The package uses CONFINEMENT directly
-- (approach 2). This checks the other one agrees, and shows the TOS_CD values
-- actually present - the rule names four and there may be more.

SELECT m.POS, m.TOS_CD,
       count(*)                                              AS n_lines,
       sum(CASE WHEN m.CONF_ID IS NOT NULL
                 AND trim(m.CONF_ID) <> '' THEN 1 ELSE 0 END) AS n_with_conf_id
FROM       hive_metastore.clnprw_optum.t_medical_2026q1 m
INNER JOIN (SELECT DISTINCT cast(PATID as string) AS PATID
            FROM <WORK>.<PREFIX>NDMM_COHORT) c
        ON cast(m.PATID as string) = c.PATID
WHERE  m.POS IN ('21','51','61','23')
    OR m.TOS_CD LIKE 'FAC.IP%' OR m.TOS_CD LIKE 'PROF.INP%'
GROUP BY m.POS, m.TOS_CD
ORDER BY n_lines DESC
LIMIT 40;
