# MM oncology therapy in the 12 months before LOT1.
#

build_ndmm_mma_codelist <- function() {
  codelist_src <- load_codelist_csv(
    "cl_mma_codelist.csv",
    c("CL_CODE_TYPE", "CL_CODE", "CL_MEDICATION_FULL", "CL_MED_CLASS", "CL_MED_ABBR"))
  ster_in <- paste0("'", NDMM_STEROID_ABBRS, "'", collapse = ",")
  glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_MMA_CODELIST} AS
    SELECT upper(trim(CL_CODE_TYPE)) AS code_type,
           upper(regexp_replace(trim(CL_CODE), '[^A-Za-z0-9]', '')) AS code,
           upper(trim(CL_MED_ABBR))  AS med_abbr
    FROM {codelist_src}
    WHERE CL_CODE      IS NOT NULL AND trim(CL_CODE)      <> ''
      AND CL_CODE_TYPE IS NOT NULL AND trim(CL_CODE_TYPE) <> ''
      -- The two blank checks above read the raw value. A CL_CODE of '---'
      -- passes them and normalises to '', which is what a claim with a NULL
      -- PROC_CD also normalises to - so every such claim would read as prior
      -- MM therapy and the patient would be excluded. The NDC branches are
      -- worse: both sides pad to 00000000000. Check the normalised value too.
      AND regexp_replace(trim(CL_CODE), '[^A-Za-z0-9]', '') <> ''
      AND (upper(trim(CL_CODE_TYPE)) <> 'NDC'
           OR regexp_replace(CL_CODE, '[^0-9]', '') <> '')
      AND upper(coalesce(CL_MED_ABBR, '')) NOT IN ({ster_in})
  ")
}

# Distinct PATIDs with any MM oncology therapy claim in
# Window is [LOT1_START - NDMM_PRE_LOT1_DAYS, LOT1_START - 1], per patient.
# Five sources: medical PROC_CD, medical BILL_PROC_CD, medical NDC, rx NDC and
# med_procedure PROC, with NDC11 normalisation.
#
# Read from raw claims rather than a prepared table. Those are anchored at the
# MM diagnosis, so they cannot see claims before it - and part of the baseline
# window falls there.
build_ndmm_therapy_pre_lot1 <- function(con, medical_tbl, rx_tbl, med_proc_tbl) {
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_THERAPY_PRE_LOT1} AS
    WITH med_proc AS (
      SELECT /*+ BROADCAST(c) */ cast(m.PATID as string) AS PATID
      FROM {medical_tbl} m
      INNER JOIN {NDMM_LOT1_STARTS} l1 ON cast(m.PATID as string) = l1.PATID
      INNER JOIN {NDMM_MMA_CODELIST} c
        ON c.code_type IN ('HCPCS','CPT')
       AND upper(regexp_replace(coalesce(cast(m.PROC_CD as string),''), '[^A-Za-z0-9]', '')) = c.code
       AND regexp_replace(coalesce(cast(m.PROC_CD as string),''), '[^A-Za-z0-9]', '') <> ''
      WHERE cast(m.FST_DT as date)
              BETWEEN date_sub(l1.LOT1_START_DT, {NDMM_PRE_LOT1_DAYS})
                  AND date_sub(l1.LOT1_START_DT, 1)
    ),
    med_bill AS (
      SELECT /*+ BROADCAST(c) */ cast(m.PATID as string) AS PATID
      FROM {medical_tbl} m
      INNER JOIN {NDMM_LOT1_STARTS} l1 ON cast(m.PATID as string) = l1.PATID
      INNER JOIN {NDMM_MMA_CODELIST} c
        ON c.code_type = 'HCPCS'
       AND upper(regexp_replace(coalesce(cast(m.BILL_PROC_CD as string),''), '[^A-Za-z0-9]', '')) = c.code
       AND regexp_replace(coalesce(cast(m.BILL_PROC_CD as string),''), '[^A-Za-z0-9]', '') <> ''
      WHERE cast(m.FST_DT as date)
              BETWEEN date_sub(l1.LOT1_START_DT, {NDMM_PRE_LOT1_DAYS})
                  AND date_sub(l1.LOT1_START_DT, 1)
    ),
    med_ndc AS (
      SELECT /*+ BROADCAST(c) */ cast(m.PATID as string) AS PATID
      FROM {medical_tbl} m
      INNER JOIN {NDMM_LOT1_STARTS} l1 ON cast(m.PATID as string) = l1.PATID
      INNER JOIN {NDMM_MMA_CODELIST} c
        ON c.code_type = 'NDC'
       AND {ndc_key('m.NDC')}
         = lpad(regexp_replace(c.code, '[^0-9]', ''), 11, '0')
      WHERE cast(m.FST_DT as date)
              BETWEEN date_sub(l1.LOT1_START_DT, {NDMM_PRE_LOT1_DAYS})
                  AND date_sub(l1.LOT1_START_DT, 1)
    ),
    -- med_procedure.PROC: a drug given as a procedure under a HCPCS or CPT
    -- code. No ICD_FLAG condition, matching how 05_sct.R reads the same
    -- column for HCPCS.
    mproc AS (
      SELECT /*+ BROADCAST(c) */ cast(mp.PATID as string) AS PATID
      FROM {med_proc_tbl} mp
      INNER JOIN {NDMM_LOT1_STARTS} l1 ON cast(mp.PATID as string) = l1.PATID
      INNER JOIN {NDMM_MMA_CODELIST} c ON c.code_type IN ('HCPCS','CPT')
       AND upper(regexp_replace(coalesce(cast(mp.PROC as string),''), '[^A-Za-z0-9]', '')) = c.code
       AND regexp_replace(coalesce(cast(mp.PROC as string),''), '[^A-Za-z0-9]', '') <> ''
      WHERE cast(mp.FST_DT as date) >= date_sub(l1.LOT1_START_DT, {NDMM_PRE_LOT1_DAYS})
        AND cast(mp.FST_DT as date) <= date_sub(l1.LOT1_START_DT, 1)
    ),  -- end mproc
    rx_ndc AS (
      SELECT /*+ BROADCAST(c) */ cast(r.PATID as string) AS PATID
      FROM {rx_tbl} r
      INNER JOIN {NDMM_LOT1_STARTS} l1 ON cast(r.PATID as string) = l1.PATID
      INNER JOIN {NDMM_MMA_CODELIST} c
        ON c.code_type = 'NDC'
       AND {ndc_key('r.NDC')}
         = lpad(regexp_replace(c.code, '[^0-9]', ''), 11, '0')
      WHERE cast(r.FILL_DT as date)
              BETWEEN date_sub(l1.LOT1_START_DT, {NDMM_PRE_LOT1_DAYS})
                  AND date_sub(l1.LOT1_START_DT, 1)
    )
    SELECT DISTINCT PATID FROM med_proc
    UNION SELECT DISTINCT PATID FROM med_bill
    UNION SELECT DISTINCT PATID FROM med_ndc
    UNION SELECT DISTINCT PATID FROM rx_ndc
    UNION SELECT DISTINCT PATID FROM mproc
  "))
}

# Other-malignancy code list, read from other_malig.csv. Built here so the
# inpatient/outpatient scan does not depend on any other build.
#
# Tags each row with is_mm_adjacent_override - 1 for the tumour groups that
# must not exclude, else 0. The exclusion scan reads only the 0 rows; the QC
# card reads all of them, so the overridden groups stay visible. Logs how many
# override labels matched: a partial match means the stored wording differs and
# the override quietly does nothing, which blocks the run review.
