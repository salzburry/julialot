# The MM-diagnosed adult population this cohort is drawn from.
#
# Ported from Jul 28/overall - the SQL is copied from steps 01_codelists.R,
# 02_dx_events.R, 03_index_date.R, 05_demographics.R and 08_assembly.R of that
# build. tests/test_same_as_overall.R compares each statement against it.
#
# Only two criteria are applied here, because only two are what S6.2.1.1
# inherits: a qualifying MM diagnosis, and age >= 18 at that diagnosis. The
# parent build has switches for six more - baseline CE, enrolment on the index,
# no MM agent in baseline, at least one MM agent in follow-up. None of them is
# an NDMM criterion, and NDMM re-applies CE and baseline therapy at the 1L
# start instead. Applying them here would drop patients the NDMM funnel never
# gets to account for.

# Diagnosis codes. DISTINCT because a repeated CSV row would duplicate every
# claim it matches.
build_ndmm_mm_dx_codes <- function(con) {
  src <- load_codelist_csv("mm_dx.csv", c("dx", "icd_family"))
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_MM_DX_CODES} AS
    SELECT DISTINCT
      CASE WHEN upper(icd_family) IN ('9','ICD9','ICD-9','ICD9DIAG') THEN 'ICD9' ELSE 'ICD10' END AS icd_family,
      upper(regexp_replace(trim(dx), '[^A-Za-z0-9]', '')) AS dx
    FROM {src}
    WHERE dx IS NOT NULL AND regexp_replace(dx, '[^A-Za-z0-9]', '') <> ''
  "))
}

# Claim headers and confinements over the whole study period. 04_other_malig.R
# builds the same two views over a narrower window for its own scan; these are
# separate rather than widened so each stays a faithful copy of the build it
# came from.
build_ndmm_mm_claim_header <- function(con, medical_tbl, confinement_tbl) {
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_MM_CLAIM_HEADER} AS
    -- Keep the five-column claim grain.
    -- Flag each line before max(POS) can hide an inpatient code.
    SELECT PATID, PAT_PLANID, CLMID, FST_DT, LOC_CD,
           max(CONF_ID) AS CONF_ID,
           max(POS)     AS POS,
           max(TOS_CD)  AS TOS_CD,
           max(CASE WHEN POS IN ('21', '51', '61')
                      OR TOS_CD IN ('FAC_IP.ACUTE', 'FAC_IP.REHSNF', 'PROF.INPVIS', 'FAC_IP.SNF')
                    THEN 1 ELSE 0 END) AS line_inpatient
    FROM {medical_tbl}
    WHERE FST_DT BETWEEN date('{NDMM_STUDY_START}') AND date('{cfg$study_end}')
    GROUP BY PATID, PAT_PLANID, CLMID, FST_DT, LOC_CD
  "))
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_MM_CONFINEMENT} AS
    SELECT DISTINCT PATID, CONF_ID,
           cast(ADMIT_DATE as date) AS ADMIT_DATE,
           cast(DISCH_DATE as date) AS DISCH_DATE
    FROM {confinement_tbl}
    WHERE CONF_ID IS NOT NULL
      AND ADMIT_DATE IS NOT NULL
      AND DISCH_DATE IS NOT NULL
  "))
}

# Inpatient means a POS/TOS line flag or a valid confinement.
build_ndmm_mm_dx_events <- function(con, med_diag_tbl) {
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_MM_DX_EVENTS} AS
    SELECT /*+ BROADCAST(c) */
      d.PATID,
      cast(d.FST_DT as date) AS svc_dt,
      -- POS/TOS line flag or valid confinement.
      CASE WHEN h.line_inpatient = 1 OR cf.CONF_ID IS NOT NULL
           THEN 1 ELSE 0 END AS inpatient_flg,
      -- line_inpatient is 0/1, so missing POS/TOS stays null-safe.
      CASE WHEN NOT (h.line_inpatient = 1 OR cf.CONF_ID IS NOT NULL)
           THEN 1 ELSE 0 END AS outpatient_flg,
      -- The code list decides which codes are in scope at all. This flag
      -- marks the 203.0x / C90.0x subset, which inpatient qualifying
      -- additionally requires.
      CASE WHEN (CASE WHEN upper(d.ICD_FLAG) IN ('9','ICD9','ICD-9') THEN 'ICD9' ELSE 'ICD10' END) = 'ICD9'
                  AND upper(regexp_replace(d.DIAG, '[^A-Za-z0-9]', '')) LIKE '2030%'
             OR (CASE WHEN upper(d.ICD_FLAG) IN ('9','ICD9','ICD-9') THEN 'ICD9' ELSE 'ICD10' END) = 'ICD10'
                  AND upper(regexp_replace(d.DIAG, '[^A-Za-z0-9]', '')) LIKE 'C900%'
           THEN 1 ELSE 0 END AS mm_dx_strict_flg
    FROM {med_diag_tbl} d
    INNER JOIN {NDMM_MM_CLAIM_HEADER} h
      -- PAT_PLANID and LOC_CD may be NULL; use null-safe equality.
      ON d.PATID      =   h.PATID
     AND d.CLMID      =   h.CLMID
     AND d.FST_DT     =   h.FST_DT
     AND d.PAT_PLANID <=> h.PAT_PLANID
     AND d.LOC_CD     <=> h.LOC_CD
    INNER JOIN {NDMM_MM_DX_CODES} c
      ON upper(regexp_replace(d.DIAG, '[^A-Za-z0-9]', '')) = c.dx
      AND (CASE WHEN upper(d.ICD_FLAG) IN ('9','ICD9','ICD-9') THEN 'ICD9' ELSE 'ICD10' END) = c.icd_family
    LEFT JOIN {NDMM_MM_CONFINEMENT} cf
      ON h.PATID = cf.PATID AND h.CONF_ID = cf.CONF_ID
    WHERE cast(d.FST_DT as date) BETWEEN date('{NDMM_STUDY_START}') AND date('{cfg$study_end}')
  "))
}

# Every candidate diagnosis date: one inpatient claim carrying a strict code,
# or two outpatient claims on separate days within the window. Every candidate
# is kept, not just the earliest - a patient who is 17 at their first
# qualifying date and 18 at the next is in the cohort, and picking the earliest
# before applying age would lose them.
build_ndmm_mm_qualifying <- function(con) {
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_MM_QUALIFYING} AS
    WITH inpatient_potential AS (
      SELECT DISTINCT PATID, svc_dt AS potential_index
      FROM {NDMM_MM_DX_EVENTS}
      WHERE inpatient_flg = 1
        AND mm_dx_strict_flg = 1
    ),
    distinct_dates AS (
      SELECT DISTINCT PATID, svc_dt
      FROM {NDMM_MM_DX_EVENTS}
      WHERE outpatient_flg = 1
    ),
    with_next AS (
      SELECT PATID, svc_dt,
             lead(svc_dt) OVER (PARTITION BY PATID ORDER BY svc_dt) AS next_dt
      FROM distinct_dates
    ),
    outpatient_potential AS (
      SELECT DISTINCT PATID, svc_dt AS potential_index
      FROM with_next
      WHERE next_dt IS NOT NULL
        AND datediff(next_dt, svc_dt) <= {NDMM_OUTPATIENT_WINDOW}
    ),
    all_potential AS (
      SELECT PATID, potential_index, 1 AS inpt_qual, 0 AS outpt_qual
      FROM inpatient_potential
      UNION ALL
      SELECT PATID, potential_index, 0 AS inpt_qual, 1 AS outpt_qual
      FROM outpatient_potential
    )
    SELECT PATID,
           potential_index AS MM_DX_DT,
           max(inpt_qual) AS inpt_qual,
           max(outpt_qual) AS outpt_qual,
           CASE WHEN max(inpt_qual) = 1 THEN 'INPATIENT'
                ELSE 'OUTPATIENT_2IN{NDMM_OUTPATIENT_WINDOW}' END AS index_source
    FROM all_potential
    GROUP BY PATID, potential_index
  "))
}

# Sex and birth year, one row per patient: a known sex wins over 'U', then the
# most recent eligibility record.
build_ndmm_demographics <- function(con, member_elig_tbl, dod_tbl) {
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_MEMBER_DEMO} AS
    WITH ranked AS (
      SELECT PATID, GDR_CD, cast(YRDOB as int) AS YRDOB,
             row_number() OVER (PARTITION BY PATID
               ORDER BY CASE WHEN upper(GDR_CD) NOT IN ('U','') THEN 0 ELSE 1 END,
                        cast(ELIGEND as date) DESC) AS rn
      FROM {member_elig_tbl}
    )
    SELECT PATID, GDR_CD, YRDOB FROM ranked WHERE rn = 1
  "))
  # Coarsen partial death dates: month-only -> the 15th, year-only -> Jul 15.
  # If that lands before the diagnosis date in the same period, bump to the
  # period end so DEATH_DT is never earlier than the date follow-up runs from,
  # which would make FU_DAYS negative.
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_DEATH_DT} AS
    WITH raw_death AS (
      SELECT PATID,
             cast(SUBSTR(YMDOD, 1, 4) as int) AS death_yr,
             CASE WHEN LENGTH(TRIM(YMDOD)) >= 6 THEN cast(SUBSTR(YMDOD, 5, 2) as int)
                  ELSE NULL END AS death_mo
      FROM {dod_tbl}
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
      SELECT q.PATID,
             q.MM_DX_DT,
             CASE
               WHEN b.death_yr IS NULL THEN NULL
               WHEN b.death_mo IS NOT NULL THEN
                 CASE
                   WHEN year(q.MM_DX_DT) = b.death_yr
                    AND month(q.MM_DX_DT) = b.death_mo
                    AND q.MM_DX_DT > make_date(b.death_yr, b.death_mo, 15)
                   THEN last_day(make_date(b.death_yr, b.death_mo, 1))
                   ELSE make_date(b.death_yr, b.death_mo, 15)
                 END
               ELSE
                 CASE
                   WHEN year(q.MM_DX_DT) = b.death_yr
                    AND q.MM_DX_DT > make_date(b.death_yr, 7, 15)
                   THEN make_date(b.death_yr, 12, 31)
                   ELSE make_date(b.death_yr, 7, 15)
                 END
             END AS death_raw
      FROM {NDMM_MM_QUALIFYING} q
      LEFT JOIN best b ON q.PATID = b.PATID
    )
    SELECT PATID, MM_DX_DT,
           CASE WHEN death_raw IS NOT NULL AND death_raw < MM_DX_DT THEN MM_DX_DT
                ELSE death_raw END AS DEATH_DT
    FROM calc
  "))
}

# The base population: each patient's EARLIEST qualifying diagnosis, and then
# age >= 18 in that date's calendar year.
#
# That order is the whole point, and it used to be the other way round - age
# filtered first, earliest date chosen from what survived. A patient qualifying
# at 17 and again at 18 was then kept, with MM_DX_DT moved to the later date.
# Two things are wrong with that. It is not what Jul 28/overall does: there age
# is `AND AGE_INDEX_YR >= min_age` applied to a chosen index date, which drops
# the patient and never moves the date, and a standalone package that disagrees
# with the parent on who is in the cohort is worse than one that is merely
# stricter. And MM_DX_DT is not a demographic here - it gates the 1L index, via
# "first MM therapy claim on or after MM_DX_DT". Advancing it to the second
# qualifying date lets a later therapy claim be recorded as first line for a
# patient whose real first line was at 17. "Newly diagnosed" is the earliest
# diagnosis; the second qualifying date is more claims for the same disease,
# not a new one.
#
# So the ranking cannot see age at all: it runs on NDMM_MM_QUALIFYING alone.
# The demographics join and the age test come after, on the one surviving row,
# where they can only drop a patient.
build_ndmm_base_cohort <- function(con) {
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_BASE_COHORT} AS
    WITH ranked AS (
      SELECT q.PATID, q.MM_DX_DT, q.index_source,
             row_number() OVER (PARTITION BY q.PATID ORDER BY q.MM_DX_DT) AS rn
      FROM {NDMM_MM_QUALIFYING} q
      WHERE q.inpt_qual = 1 OR q.outpt_qual = 1
    ),
    first_dx AS (
      SELECT PATID, MM_DX_DT, index_source FROM ranked WHERE rn = 1
    )
    SELECT cast(f.PATID as string) AS PATID, f.MM_DX_DT, f.index_source,
           m.GDR_CD, m.YRDOB,
           (year(f.MM_DX_DT) - m.YRDOB) AS AGE_DX_YR,
           dd.DEATH_DT
    FROM first_dx f
    INNER JOIN {NDMM_MEMBER_DEMO} m ON m.PATID = f.PATID
    LEFT JOIN {NDMM_DEATH_DT} dd
           ON dd.PATID = f.PATID AND dd.MM_DX_DT = f.MM_DX_DT
    WHERE m.YRDOB IS NOT NULL
      AND (year(f.MM_DX_DT) - m.YRDOB) >= {NDMM_MIN_AGE}
  "))
}
