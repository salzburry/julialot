# =============================================================================
# 01_codelists.R -- Phase 1 -- normalise the code lists. No criteria here.
# -----------------------------------------------------------------------------
# Lifted from apr_30_2026/R/pipeline_steps.R. Every SQL line below is
# byte-identical to the source; only this function's first line changed,
# because the helpers it used to close over are now passed in.
# =============================================================================

phase_codelists <- function(cfg, h, ctx) {
  full_name <- h$full_name; cdm <- h$cdm; ref <- h$ref
  work <- h$work; work_tbl <- h$work_tbl; cdm_src <- h$cdm_src
  criteria_sql <- ctx$criteria_sql
  fu_cap_expr <- ctx$fu_cap_expr
  ce_join_for_fu_cap <- ctx$ce_join_for_fu_cap
  mm_dx_source <- ctx$mm_dx_source
  mm_therapy_source <- ctx$mm_therapy_source
  preg_source <- ctx$preg_source
  clintrial_source <- ctx$clintrial_source
  other_malig_source <- ctx$other_malig_source

  list(
    # ---- Phase 1: normalize the code lists (small, run once) ----
    # Source: CSV temp views, or server-side ref tables (see above).
    list(
      name = "01_mm_dx_codes",
      description = "Loading MM diagnosis codes (ICD-9/ICD-10)",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('mm_dx_codes')} AS
        SELECT
          CASE WHEN upper(icd_family) IN ('9','ICD9','ICD-9','ICD9DIAG') THEN 'ICD9' ELSE 'ICD10' END AS icd_family,
          upper(regexp_replace(trim(dx), '[^A-Za-z0-9]', '')) AS dx
        FROM {mm_dx_source}
        WHERE dx IS NOT NULL
      "),
      qc = glue("SELECT count(*) AS n_codes FROM {work('mm_dx_codes')}")
    ),

    list(
      name = "03_mm_therapy_codes",
      description = "Loading MM therapy codes (HCPCS/NDC) — sourced from cl_mma_codelist.csv (single source of truth with LOT S04)",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('mm_therapy_codes')} AS
        -- cl_mma_codelist.csv has columns CL_CODE_TYPE, CL_CODE (+ CL_MEDICATION_FULL, CL_MED_CLASS, CL_MED_ABBR)
        -- Aliased here to code_type/code to match downstream therapy join logic
        SELECT upper(trim(CL_CODE_TYPE)) AS code_type,
               upper(regexp_replace(trim(CL_CODE), '[^A-Za-z0-9]', '')) AS code
        FROM {mm_therapy_source}
        WHERE CL_CODE IS NOT NULL AND trim(CL_CODE) <> ''
          AND CL_CODE_TYPE IS NOT NULL AND trim(CL_CODE_TYPE) <> ''
      "),
      qc = glue("SELECT count(*) AS n_codes, count(DISTINCT code_type) AS n_code_types FROM {work('mm_therapy_codes')}")
    ),

    list(
      name = "04_preg_codes",
      description = "Loading pregnancy exclusion codes",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('preg_codes')} AS
        SELECT upper(trim(code_type)) AS code_type,
               upper(regexp_replace(trim(code), '[^A-Za-z0-9]', '')) AS code
        FROM {preg_source}
        WHERE code IS NOT NULL
      "),
      qc = glue("SELECT count(*) AS n_codes FROM {work('preg_codes')}")
    ),

    list(
      name = "05_clintrial_codes",
      description = "Loading clinical trial exclusion codes",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('clintrial_codes')} AS
        SELECT upper(trim(code_type)) AS code_type,
               upper(regexp_replace(trim(code), '[^A-Za-z0-9]', '')) AS code
        FROM {clintrial_source}
        WHERE code IS NOT NULL
      "),
      qc = glue("SELECT count(*) AS n_codes FROM {work('clintrial_codes')}")
    ),

    list(
      name = "06_other_malig_codes",
      description = "Loading other malignancy exclusion codes",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('other_malig_codes')} AS
        SELECT
          upper(tumor_group) AS tumor_group,
          CASE WHEN upper(icd_family) IN ('9','ICD9','ICD-9','ICD9DIAG') THEN 'ICD9' ELSE 'ICD10' END AS icd_family,
          upper(regexp_replace(trim(dx), '[^A-Za-z0-9]', '')) AS dx
        FROM {other_malig_source}
        WHERE dx IS NOT NULL AND tumor_group IS NOT NULL
      "),
      qc = glue("SELECT count(*) AS n_codes FROM {work('other_malig_codes')}")
    ),

    # SCHEMA PROBE: Validate RVNU_CD column exists on medical table
    # The revenue code field is RVNU_CD (facility claims only).
    # This check fails early with a clear message if the column is missing,
    # rather than erroring deep in the pregnancy/clinical trial steps.
    list(
      name = "06c_validate_rvnu_cd",
      description = "Validating RVNU_CD column exists on medical table",
      source_tables = c("medical"),
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('rvnu_cd_check')} AS
        SELECT RVNU_CD FROM {cdm_src(cfg$tbl_medical)} LIMIT 1
      "),
      qc = glue("SELECT 'RVNU_CD column validated on medical table' AS status")
    )
  )
}
