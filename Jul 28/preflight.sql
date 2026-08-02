-- Pre-flight for the production run. READ ONLY: every statement here is a
-- SELECT, SHOW or DESCRIBE. Nothing is created, written or dropped.
--
-- Run this in the Databricks SQL editor BEFORE `Rscript build.R`, and read the
-- answers. The build is not reversible once it has written, and three of the
-- things below are assumptions no test in this repo can check - they are facts
-- about the warehouse, not about the code.
--
-- The window this run is configured for is 2016-01-01 .. 2026-03-31, which
-- resolves to the 2026q1 tables. That vintage has never been read by this code:
-- every run so far has been on 2025q2. Sections 1-3 are about that.
--
-- Codelists are NOT checked here. They are CSVs under /mnt/code/codelist, read
-- by R and pushed to Spark as temp views, so they do not exist as warehouse
-- tables and no SQL console can see them. The build checks them itself and
-- stops - check_codelists(), check_belantamab_abbr() - so that half is covered.
--
-- Sections 2 and 3 scan medical and rx, which are large. Expect minutes, not
-- seconds. Run them one at a time rather than as a batch.


-- ===========================================================================
-- 1. Does the vintage exist at all?
-- ---------------------------------------------------------------------------
-- Expect eight rows: medical, rx, med_procedure, med_diagnosis, confinement,
-- member_enrollment, member_cont_enrollment, dod - each suffixed _2026q1.
-- A missing one means STUDY_END is pointing at a vintage that was never
-- delivered, and the build would fail on its first read of that table.
-- ===========================================================================
SHOW TABLES IN hive_metastore.clnprw_optum LIKE '*_2026q1';


-- ===========================================================================
-- 2. Does the data actually reach 2026-03-31?
-- ---------------------------------------------------------------------------
-- The name says 2026q1; that is a delivery label, not a guarantee of coverage.
-- If claims stop at, say, 2025-09-30, then the configured study end is nine
-- months past the data and every patient's follow-up is quietly short.
--
-- Nothing catches this for you. lot's check_cohort_window() compares the COHORT
-- against the window; it cannot compare the DATA against it.
--
-- Expect max_dt at or near 2026-03-31 for medical, rx, med_procedure,
-- med_diagnosis. A max_dt well before it is a reason to move STUDY_END back to
-- the quarter the data really ends in - in BOTH nndm/config.csv and
-- lot/config.csv, which must agree.
-- ===========================================================================
SELECT 'medical'       AS tbl, count(*) AS n_rows,
       min(cast(FST_DT  AS date)) AS min_dt, max(cast(FST_DT  AS date)) AS max_dt
FROM hive_metastore.clnprw_optum.t_medical_2026q1
UNION ALL
SELECT 'rx',            count(*),
       min(cast(FILL_DT AS date)), max(cast(FILL_DT AS date))
FROM hive_metastore.clnprw_optum.t_rx_2026q1
UNION ALL
SELECT 'med_procedure', count(*),
       min(cast(FST_DT  AS date)), max(cast(FST_DT  AS date))
FROM hive_metastore.clnprw_optum.t_med_procedure_2026q1
UNION ALL
SELECT 'med_diagnosis', count(*),
       min(cast(FST_DT  AS date)), max(cast(FST_DT  AS date))
FROM hive_metastore.clnprw_optum.t_med_diagnosis_2026q1;


-- ===========================================================================
-- 3. Was history restated between 2025q2 and 2026q1?
-- ---------------------------------------------------------------------------
-- These are cumulative deliveries, so 2026q1 should CONTAIN 2025q2 for every
-- period they share. Should. A claim can be added late, corrected or reversed
-- between deliveries, and if that happened before 2025-06-30 then the parent MM
-- cohort - built and frozen on 2025q2 - rests on rows this run will not see the
-- same way.
--
-- Expect n_2026q1 >= n_2025q2 in every year, and equal in most. A year where
-- 2026q1 has FEWER rows is a reversal and is worth understanding before the run;
-- a small excess in 2024-2025 is ordinary claims lag.
--
-- Change the table name and date column to repeat for rx (FILL_DT) if medical
-- shows anything odd.
-- ===========================================================================
SELECT coalesce(a.yr, b.yr)                        AS yr,
       coalesce(b.n, 0)                            AS n_2025q2,
       coalesce(a.n, 0)                            AS n_2026q1,
       coalesce(a.n, 0) - coalesce(b.n, 0)         AS delta
FROM (SELECT year(cast(FST_DT AS date)) AS yr, count(*) AS n
      FROM hive_metastore.clnprw_optum.t_medical_2026q1
      WHERE cast(FST_DT AS date) <= date('2025-06-30')
      GROUP BY 1) a
FULL OUTER JOIN
     (SELECT year(cast(FST_DT AS date)) AS yr, count(*) AS n
      FROM hive_metastore.clnprw_optum.t_medical_2025q2
      WHERE cast(FST_DT AS date) <= date('2025-06-30')
      GROUP BY 1) b
  ON a.yr = b.yr
ORDER BY yr;


-- ===========================================================================
-- 4. ICD_FLAG really is '9' or '10', and nothing else
-- ---------------------------------------------------------------------------
-- The build reads both spellings and maps anything else to NULL, which matches
-- no code list - deliberately, so an unexpected flag drops the claim rather
-- than being guessed as ICD-10. That is the safe direction, but if this vintage
-- carries a third value in quantity, those claims are silently invisible.
--
-- Expect two rows, '9' and '10'. A third value with a large count is a reason
-- to look before running; a handful of nulls is normal.
-- ===========================================================================
SELECT ICD_FLAG, count(*) AS n
FROM hive_metastore.clnprw_optum.t_med_diagnosis_2026q1
GROUP BY ICD_FLAG
ORDER BY n DESC;


-- ===========================================================================
-- 5. Every column the build reads is present
-- ---------------------------------------------------------------------------
-- A renamed or dropped column fails deep into a run rather than at the start.
-- Run each DESCRIBE and check the named columns are in the output.
--
-- medical                 PATID FST_DT PROC_CD BILL_PROC_CD NDC RVNU_CD
--                         POS TOS_CD CONF_ID CLMID PAT_PLANID LOC_CD
-- rx                      PATID FILL_DT NDC DAYS_SUP
-- med_procedure           PATID FST_DT PROC ICD_FLAG
-- med_diagnosis           PATID FST_DT DIAG ICD_FLAG DIAG_POSITION
-- confinement             PATID CONF_ID ADMIT_DATE DISCH_DATE
-- member_enrollment       PATID ELIGEFF ELIGEND
-- member_cont_enrollment  PATID GDR_CD YRDOB ELIGEND
-- dod                     PATID YMDOD
-- ===========================================================================
DESCRIBE TABLE hive_metastore.clnprw_optum.t_medical_2026q1;
DESCRIBE TABLE hive_metastore.clnprw_optum.t_rx_2026q1;
DESCRIBE TABLE hive_metastore.clnprw_optum.t_med_procedure_2026q1;
DESCRIBE TABLE hive_metastore.clnprw_optum.t_med_diagnosis_2026q1;
DESCRIBE TABLE hive_metastore.clnprw_optum.t_confinement_2026q1;
DESCRIBE TABLE hive_metastore.clnprw_optum.t_member_enrollment_2026q1;
DESCRIBE TABLE hive_metastore.clnprw_optum.t_member_cont_enrollment_2026q1;
DESCRIBE TABLE hive_metastore.clnprw_optum.t_dod_2026q1;


-- ===========================================================================
-- 6. Is the output schema clear of a previous attempt?
-- ---------------------------------------------------------------------------
-- Outputs are <work_schema>.<prefix><TABLE>, with no run id in the name, so a
-- second run on the same prefix replaces the first's tables. Substitute your
-- schema and the prefix you intend to use.
--
-- Expect no rows on a first run. Anything here will be overwritten.
-- ===========================================================================
-- SHOW TABLES IN hive_metastore.<your_schema> LIKE '<your_prefix>*';


-- ===========================================================================
-- 7. After the run: what the outputs say about themselves
-- ---------------------------------------------------------------------------
-- Not pre-flight. Run these once the build reports complete, before anyone
-- reads a count off LOT_LONG_FINAL. Substitute schema and prefix.
--
-- STATE must be 'complete'. LINE_CRITERIA_APPLIED names each line criterion,
-- whether it was applied and how many patients it catches - for this study
-- expect no_belantamab=on:truncate:<n>. STUDY_START/STUDY_END must be the
-- window you intended, and LOT_LONG_BY_LINE shows how many patients reach each
-- line.
-- ===========================================================================
-- SELECT STATE, CODELIST_WAIVERS_APPLIED, UPDATED_AT
-- FROM hive_metastore.<your_schema>.<your_prefix>LOT_BUILD_STATUS
-- ORDER BY UPDATED_AT DESC;
--
-- SELECT STUDY_START, STUDY_END, LINE_CRITERIA_APPLIED, LOT_LONG_BY_LINE,
--        N_LOT_LONG_ROWS, N_LOT_LONG_PATIENTS,
--        N_LOT_FINAL_ROWS, N_LOT_FINAL_PATIENTS, CODE_MD5
-- FROM hive_metastore.<your_schema>.<your_prefix>LOT_RUN_METADATA;
--
-- The NDMM side: every cohort member carrying a belantamab claim, with dates.
-- This is the handover list for the exclusion lot applies.
-- SELECT * FROM hive_metastore.<your_schema>.<your_prefix>NDMM_BELANTAMAB_RECONCILE;
