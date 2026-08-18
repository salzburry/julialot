# Load the five code lists into views the later phases join against.

phase_codelists <- function(cfg, h, ctx) {
  cdm_src <- h$cdm_src
  mm_dx_source       <- ctx$mm_dx_source
  mm_therapy_source  <- ctx$mm_therapy_source
  preg_source        <- ctx$preg_source
  clintrial_source   <- ctx$clintrial_source
  other_malig_source <- ctx$other_malig_source

  list(
    # ---- Phase 1: normalize the production CSV code lists (run once) ----
    list(
      name = "01_mm_dx_codes",
      description = "Loading MM diagnosis codes (ICD-9/ICD-10)",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW mm_dx_codes AS
        -- DISTINCT: a repeated row in the CSV would duplicate every claim
        -- it matches.
        SELECT DISTINCT
          CASE WHEN upper(icd_family) IN ('9','ICD9','ICD-9','ICD9DIAG') THEN 'ICD9' ELSE 'ICD10' END AS icd_family,
          upper(regexp_replace(trim(dx), '[^A-Za-z0-9]', '')) AS dx
        FROM {mm_dx_source}
        WHERE dx IS NOT NULL AND regexp_replace(dx, '[^A-Za-z0-9]', '') <> ''
      "),
      qc = glue("SELECT count(*) AS n_codes FROM mm_dx_codes")
    ),

    list(
      name = "03_mm_therapy_codes",
      description = "Loading MM therapy codes (HCPCS/NDC)",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW mm_therapy_codes AS
        -- Keep the fields used for claim matching.
        SELECT DISTINCT upper(trim(CL_CODE_TYPE)) AS code_type,
               upper(regexp_replace(trim(CL_CODE), '[^A-Za-z0-9]', '')) AS code
        FROM {mm_therapy_source}
        WHERE CL_CODE IS NOT NULL AND trim(CL_CODE) <> ''
          AND CL_CODE_TYPE IS NOT NULL AND trim(CL_CODE_TYPE) <> ''
          AND regexp_replace(CL_CODE, '[^A-Za-z0-9]', '') <> ''
      "),
      qc = glue("SELECT count(*) AS n_codes, count(DISTINCT code_type) AS n_code_types FROM mm_therapy_codes")
    ),

    list(
      name = "04_preg_codes",
      description = "Loading pregnancy exclusion codes",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW preg_codes AS
        SELECT DISTINCT upper(trim(code_type)) AS code_type,
               upper(regexp_replace(trim(code), '[^A-Za-z0-9]', '')) AS code
        FROM {preg_source}
        WHERE code IS NOT NULL AND regexp_replace(code, '[^A-Za-z0-9]', '') <> ''
      "),
      qc = glue("SELECT count(*) AS n_codes FROM preg_codes")
    ),

    list(
      name = "05_clintrial_codes",
      description = "Loading clinical trial exclusion codes",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW clintrial_codes AS
        SELECT DISTINCT upper(trim(code_type)) AS code_type,
               upper(regexp_replace(trim(code), '[^A-Za-z0-9]', '')) AS code
        FROM {clintrial_source}
        WHERE code IS NOT NULL AND regexp_replace(code, '[^A-Za-z0-9]', '') <> ''
      "),
      qc = glue("SELECT count(*) AS n_codes FROM clintrial_codes")
    ),

    list(
      name = "06_other_malig_codes",
      description = "Loading other malignancy exclusion codes",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW other_malig_codes AS
        SELECT DISTINCT
          upper(tumor_group) AS tumor_group,
          CASE WHEN upper(icd_family) IN ('9','ICD9','ICD-9','ICD9DIAG') THEN 'ICD9' ELSE 'ICD10' END AS icd_family,
          upper(regexp_replace(trim(dx), '[^A-Za-z0-9]', '')) AS dx
        FROM {other_malig_source}
        WHERE dx IS NOT NULL AND tumor_group IS NOT NULL
          AND regexp_replace(dx, '[^A-Za-z0-9]', '') <> ''
      "),
      qc = glue("SELECT count(*) AS n_codes FROM other_malig_codes")
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
        CREATE OR REPLACE TEMPORARY VIEW rvnu_cd_check AS
        SELECT RVNU_CD FROM {cdm_src(cfg$tbl_medical)} LIMIT 1
      "),
      qc = glue("SELECT 'RVNU_CD column validated on medical table' AS status")
    )
  )
}
