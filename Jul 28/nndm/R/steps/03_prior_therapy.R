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
# [LOT1_START - NDMM_PRE_LOT1_DAYS, LOT1_START - 1]. Mirrors the parent's
# pipeline_steps.R:646-696 therapy_events four-source pattern
# (medical PROC_CD, medical BILL_PROC_CD, medical NDC, rx NDC) with
# NDC11 normalisation, but with a per-PATID date window driven off
# LOT1_START_DT instead of [study_start, study_end].
#
# This raw-claim scan is necessary because the parent's persisted
# MMA_MED_PROCESSED is built with `FST_DT >= INDEX_DATE` (MM-dx anchor)
# on every source branch (02_lot1.R:316,336,359,386). It therefore
# cannot see any claims before the MM diagnosis, and would miss MM
# therapy occurring in the [LOT1_START - 365, INDEX_DATE - 1] portion
# of the 12-month 1L baseline.
build_ndmm_therapy_pre_lot1 <- function(con, medical_tbl, rx_tbl) {
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
       AND lpad(regexp_replace(coalesce(cast(m.NDC as string),''), '[^0-9]', ''), 11, '0')
         = lpad(regexp_replace(c.code, '[^0-9]', ''), 11, '0')
       AND regexp_replace(coalesce(cast(m.NDC as string),''), '[^0-9]', '') <> ''
      WHERE cast(m.FST_DT as date)
              BETWEEN date_sub(l1.LOT1_START_DT, {NDMM_PRE_LOT1_DAYS})
                  AND date_sub(l1.LOT1_START_DT, 1)
    ),
    rx_ndc AS (
      SELECT /*+ BROADCAST(c) */ cast(r.PATID as string) AS PATID
      FROM {rx_tbl} r
      INNER JOIN {NDMM_LOT1_STARTS} l1 ON cast(r.PATID as string) = l1.PATID
      INNER JOIN {NDMM_MMA_CODELIST} c
        ON c.code_type = 'NDC'
       AND lpad(regexp_replace(coalesce(cast(r.NDC as string),''), '[^0-9]', ''), 11, '0')
         = lpad(regexp_replace(c.code, '[^0-9]', ''), 11, '0')
       AND regexp_replace(coalesce(cast(r.NDC as string),''), '[^0-9]', '') <> ''
      WHERE cast(r.FILL_DT as date)
              BETWEEN date_sub(l1.LOT1_START_DT, {NDMM_PRE_LOT1_DAYS})
                  AND date_sub(l1.LOT1_START_DT, 1)
    )
    SELECT DISTINCT PATID FROM med_proc
    UNION SELECT DISTINCT PATID FROM med_bill
    UNION SELECT DISTINCT PATID FROM med_ndc
    UNION SELECT DISTINCT PATID FROM rx_ndc
  "))
}

# Other-malignancy codelist loaded from cl_other_malignancies CSV
# (default file: other_malig.csv, per config_prompts.R:76). Same loader
# and column normalisation as parent pipeline_steps.R step 06 (which
# materialises work('other_malig_codes')). Built here so the NDMM IP/OP
# scan does not depend on the parent leaving its temp view alive.
#
# Tags each row with is_mm_adjacent_override (1 for the
# NDMM_MM_ADJACENT_OVERRIDE tumor groups, else 0). The actual exclusion
# scan (build_ndmm_other_malig_pre_lot1) reads only
# is_mm_adjacent_override = 0 rows; the QC card reads all rows so the
# overridden groups stay visible. Logs how many of the expected override
# labels matched the codelist - a partial match means the stored labels
# differ from NDMM_MM_ADJACENT_OVERRIDE and the override is a silent no-op
# for the unmatched groups (run-review blocker). Takes con (was a pure
# SQL-string builder) so it can run the post-create match-count probe.
