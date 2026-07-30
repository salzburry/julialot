# =============================================================================
# 00_inputs.R -- the inputs every criterion is built from
# -----------------------------------------------------------------------------
# NO CRITERIA IN THIS FILE. Nothing here includes or excludes anybody; it
# normalizes the code lists and turns raw claims into MM diagnosis events. The
# funnel starts in 01_index.R.
#
# File numbers are BUILD order (what depends on what). IE Step numbers are
# FUNNEL order (what drops whom). They are not the same sequence and it matters:
# every flag is computed for every candidate index date first, and only then are
# the gates applied. That is why a patient whose earliest index fails a gate can
# still enter on a later one -- see 09_assemble.R.
#
# Two grains of MM events, and the difference is load-bearing:
#   mm_dx_events_all  full study period  -> baseline lookback (Step 7)
#   mm_dx_events_id   ID period only     -> index qualification (Step 1)
#
# Two MM code sets, likewise:
#   BROAD   203.x / C90.x    -> Step 0 base count, outpatient qualification
#   STRICT  203.0x / C90.0x  -> inpatient qualification, baseline MM evidence
# =============================================================================

ie_step_inputs <- function(cfg, h) {
  work <- h$work; cdm_src <- h$cdm_src; ref <- h$ref

  # Code lists come from CSV temp views (USE_CSV_CODELISTS=TRUE, the default:
  # load_csv_codelists() has already pushed each cl_*.csv into a temp view of
  # that name) or from server-side reference tables.
  if (isTRUE(cfg$use_csv_codelists)) {
    mm_dx_source       <- cfg$cl_mm_dx
    mm_therapy_source  <- cfg$cl_mm_therapy
    preg_source        <- cfg$cl_preg
    clintrial_source   <- cfg$cl_clintrial
    other_malig_source <- cfg$cl_other_malig
  } else {
    mm_dx_source       <- ref(cfg$cl_mm_dx)
    mm_therapy_source  <- ref(cfg$cl_mm_therapy)
    preg_source        <- ref(cfg$cl_preg)
    clintrial_source   <- ref(cfg$cl_clintrial)
    other_malig_source <- ref(cfg$cl_other_malig)
  }

  views <- list(
    ie_view(
      name = "mm_dx_codes",
      legacy = "01_mm_dx_codes",
      description = "Loading MM diagnosis codes (ICD-9/ICD-10)",
      sql = fmt("
        CREATE OR REPLACE TEMPORARY VIEW {work('mm_dx_codes')} AS
        SELECT
          CASE WHEN upper(icd_family) IN ('9','ICD9','ICD-9','ICD9DIAG') THEN 'ICD9' ELSE 'ICD10' END AS icd_family,
          upper(regexp_replace(trim(dx), '[^A-Za-z0-9]', '')) AS dx
        FROM {mm_dx_source}
        WHERE dx IS NOT NULL
      "),
      qc = fmt("SELECT count(*) AS n_codes FROM {work('mm_dx_codes')}")
    ),

    ie_view(
      name = "mm_therapy_codes",
      legacy = "03_mm_therapy_codes",
      description = "Loading MM therapy codes (HCPCS/NDC) - sourced from cl_mma_codelist.csv (single source of truth with LOT S04)",
      sql = fmt("
        CREATE OR REPLACE TEMPORARY VIEW {work('mm_therapy_codes')} AS
        -- cl_mma_codelist.csv has columns CL_CODE_TYPE, CL_CODE (+ CL_MEDICATION_FULL, CL_MED_CLASS, CL_MED_ABBR)
        -- Aliased here to code_type/code to match downstream therapy join logic
        SELECT upper(trim(CL_CODE_TYPE)) AS code_type,
               upper(regexp_replace(trim(CL_CODE), '[^A-Za-z0-9]', '')) AS code
        FROM {mm_therapy_source}
        WHERE CL_CODE IS NOT NULL AND trim(CL_CODE) <> ''
          AND CL_CODE_TYPE IS NOT NULL AND trim(CL_CODE_TYPE) <> ''
      "),
      qc = fmt("SELECT count(*) AS n_codes, count(DISTINCT code_type) AS n_code_types FROM {work('mm_therapy_codes')}")
    ),

    ie_view(
      name = "preg_codes",
      legacy = "04_preg_codes",
      description = "Loading pregnancy exclusion codes",
      sql = fmt("
        CREATE OR REPLACE TEMPORARY VIEW {work('preg_codes')} AS
        SELECT upper(trim(code_type)) AS code_type,
               upper(regexp_replace(trim(code), '[^A-Za-z0-9]', '')) AS code
        FROM {preg_source}
        WHERE code IS NOT NULL
      "),
      qc = fmt("SELECT count(*) AS n_codes FROM {work('preg_codes')}")
    ),

    ie_view(
      name = "clintrial_codes",
      legacy = "05_clintrial_codes",
      description = "Loading clinical trial exclusion codes",
      sql = fmt("
        CREATE OR REPLACE TEMPORARY VIEW {work('clintrial_codes')} AS
        SELECT upper(trim(code_type)) AS code_type,
               upper(regexp_replace(trim(code), '[^A-Za-z0-9]', '')) AS code
        FROM {clintrial_source}
        WHERE code IS NOT NULL
      "),
      qc = fmt("SELECT count(*) AS n_codes FROM {work('clintrial_codes')}")
    ),

    ie_view(
      name = "other_malig_codes",
      legacy = "06_other_malig_codes",
      description = "Loading other malignancy exclusion codes",
      sql = fmt("
        CREATE OR REPLACE TEMPORARY VIEW {work('other_malig_codes')} AS
        SELECT
          upper(tumor_group) AS tumor_group,
          CASE WHEN upper(icd_family) IN ('9','ICD9','ICD-9','ICD9DIAG') THEN 'ICD9' ELSE 'ICD10' END AS icd_family,
          upper(regexp_replace(trim(dx), '[^A-Za-z0-9]', '')) AS dx
        FROM {other_malig_source}
        WHERE dx IS NOT NULL AND tumor_group IS NOT NULL
      "),
      qc = fmt("SELECT count(*) AS n_codes FROM {work('other_malig_codes')}")
    ),

    # Fail early and legibly if the revenue-code column is absent, instead of
    # erroring deep inside the pregnancy / clinical-trial scans that need it.
    ie_view(
      name = "rvnu_cd_check",
      legacy = "06c_validate_rvnu_cd",
      description = "Validating RVNU_CD column exists on medical table",
      source_tables = c("medical"),
      sql = fmt("
        CREATE OR REPLACE TEMPORARY VIEW {work('rvnu_cd_check')} AS
        SELECT RVNU_CD FROM {cdm_src(cfg$tbl_medical)} LIMIT 1
      "),
      qc = "SELECT 'RVNU_CD column validated on medical table' AS status"
    ),

    ie_view(
      name = "med_claim_header",
      legacy = "07a_med_claim_header",
      description = "Extracting medical claim headers from CDM (study period)",
      source_tables = c("medical"),
      sql = fmt("
        CREATE OR REPLACE TEMPORARY VIEW {work('med_claim_header')} AS
        -- Claim grain is (PATID, PAT_PLANID, CLMID, FST_DT, LOC_CD). CLMID alone is
        -- not unique: it is a plan-assigned sequence number, so the same value can
        -- legitimately repeat across plan changes, service dates, or service-line
        -- locations. Grouping on only (PATID, CLMID) silently merges genuinely
        -- distinct claims and corrupts the inpatient_flg (which is then driven by
        -- max(POS) / max(TOS_CD) / max(CONF_ID) across the merged rows). This
        -- 5-column key matches the GSK house convention used elsewhere (e.g.
        -- vax_300081 R/02_codes/005_outcomes.Rmd).
        SELECT PATID, PAT_PLANID, CLMID, FST_DT, LOC_CD,
               max(CONF_ID) AS CONF_ID,
               max(POS)     AS POS,
               max(TOS_CD)  AS TOS_CD
        FROM {cdm_src(cfg$tbl_medical)}
        WHERE FST_DT BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
        GROUP BY PATID, PAT_PLANID, CLMID, FST_DT, LOC_CD
      "),
      qc = fmt("
        SELECT count(*) AS n_claims,
               sum(CASE WHEN PAT_PLANID IS NULL THEN 1 ELSE 0 END) AS n_null_pat_planid,
               sum(CASE WHEN LOC_CD     IS NULL THEN 1 ELSE 0 END) AS n_null_loc_cd,
               sum(CASE WHEN FST_DT     IS NULL THEN 1 ELSE 0 END) AS n_null_fst_dt
        FROM {work('med_claim_header')}")
    ),

    # Inpatient via CONF_ID requires an actual confinement, which requires both
    # an admission and a discharge date.
    ie_view(
      name = "confinement",
      legacy = "07b_confinement",
      description = "Extracting confinement records",
      source_tables = c("confinement"),
      sql = fmt("
        CREATE OR REPLACE TEMPORARY VIEW {work('confinement')} AS
        SELECT DISTINCT PATID, CONF_ID,
               cast(ADMIT_DATE as date) AS ADMIT_DATE,
               cast(DISCH_DATE as date) AS DISCH_DATE
        FROM {cdm_src(cfg$tbl_confinement)}
        WHERE CONF_ID IS NOT NULL
          AND ADMIT_DATE IS NOT NULL
          AND DISCH_DATE IS NOT NULL
      "),
      qc = fmt("SELECT count(*) AS n_confinements FROM {work('confinement')}")
    ),

    # Inpatient = Approach 1 (POS/TOS) OR Approach 2 (validated CONF_ID).
    # Outpatient is the strict negation of that, so the two are exhaustive and
    # mutually exclusive -- a claim cannot count toward both paths of Step 1.
    ie_view(
      name = "mm_dx_events_all",
      legacy = "08a_mm_dx_events_all",
      description = "Identifying MM diagnosis events (full study period, Approach 1+2 inpatient)",
      source_tables = c("med_diagnosis", "confinement"),
      sql = fmt("
        CREATE OR REPLACE TEMPORARY VIEW {work('mm_dx_events_all')} AS
        SELECT /*+ BROADCAST(c) */
          d.PATID,
          d.PAT_PLANID,
          d.CLMID,
          d.LOC_CD,
          cast(d.FST_DT as date) AS svc_dt,
          upper(regexp_replace(d.DIAG, '[^A-Za-z0-9]', '')) AS diag,
          CASE WHEN upper(d.ICD_FLAG) IN ('9','ICD9','ICD-9') THEN 'ICD9' ELSE 'ICD10' END AS icd_family,
          h.CONF_ID,
          h.POS,
          h.TOS_CD,
          -- Inpatient = Approach 1 (POS/TOS) OR Approach 2 (CONF_ID validated)
          -- Approach 1: POS 21/51/61; TOS_CD IN (FAC_IP.ACUTE, FAC_IP.REHSNF, PROF.INPVIS, FAC_IP.SNF)
          -- Approach 2: CONF_ID exists in T_CONFINEMENT with valid dates
          CASE WHEN h.POS IN ('21', '51', '61')
                 OR h.TOS_CD IN ('FAC_IP.ACUTE', 'FAC_IP.REHSNF', 'PROF.INPVIS', 'FAC_IP.SNF')
                 OR cf.CONF_ID IS NOT NULL
               THEN 1 ELSE 0 END AS inpatient_flg,
          -- Outpatient: NOT identified as inpatient by either approach
          CASE WHEN NOT (h.POS IN ('21', '51', '61')
                      OR h.TOS_CD IN ('FAC_IP.ACUTE', 'FAC_IP.REHSNF', 'PROF.INPVIS', 'FAC_IP.SNF')
                      OR cf.CONF_ID IS NOT NULL)
               THEN 1 ELSE 0 END AS outpatient_flg,
          -- STRICT MM dx flag: 203.0x / C90.0x only (for inpatient qualifying + baseline evidence)
          -- BROAD codes (203.x / C90.x) are used for Step 0 base and outpatient qualifying
          CASE WHEN (CASE WHEN upper(d.ICD_FLAG) IN ('9','ICD9','ICD-9') THEN 'ICD9' ELSE 'ICD10' END) = 'ICD9'
                      AND upper(regexp_replace(d.DIAG, '[^A-Za-z0-9]', '')) LIKE '2030%'
                 OR (CASE WHEN upper(d.ICD_FLAG) IN ('9','ICD9','ICD-9') THEN 'ICD9' ELSE 'ICD10' END) = 'ICD10'
                      AND upper(regexp_replace(d.DIAG, '[^A-Za-z0-9]', '')) LIKE 'C900%'
               THEN 1 ELSE 0 END AS mm_dx_strict_flg,
          -- QC flags for each approach
          CASE WHEN cf.CONF_ID IS NOT NULL THEN 1 ELSE 0 END AS conf_validated,
          CASE WHEN h.POS IN ('21', '51', '61') OR h.TOS_CD IN ('FAC_IP.ACUTE', 'FAC_IP.REHSNF', 'PROF.INPVIS', 'FAC_IP.SNF') THEN 1 ELSE 0 END AS pos_tos_inpatient
        FROM {cdm_src(cfg$tbl_med_diag)} d
        INNER JOIN {work('med_claim_header')} h
          -- PAT_PLANID and LOC_CD can be NULL on some Optum claim lines; use
          -- null-safe equality (Spark `<=>`) so a NULL on both sides matches
          -- instead of silently dropping the diagnosis row. PATID / CLMID /
          -- FST_DT should never be NULL on a valid claim, so plain `=` there.
          ON d.PATID      =   h.PATID
         AND d.CLMID      =   h.CLMID
         AND d.FST_DT     =   h.FST_DT
         AND d.PAT_PLANID <=> h.PAT_PLANID
         AND d.LOC_CD     <=> h.LOC_CD
        INNER JOIN {work('mm_dx_codes')} c
          ON upper(regexp_replace(d.DIAG, '[^A-Za-z0-9]', '')) = c.dx
          AND (CASE WHEN upper(d.ICD_FLAG) IN ('9','ICD9','ICD-9') THEN 'ICD9' ELSE 'ICD10' END) = c.icd_family
        LEFT JOIN {work('confinement')} cf
          ON h.PATID = cf.PATID AND h.CONF_ID = cf.CONF_ID
        WHERE cast(d.FST_DT as date) BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
      "),
      qc = fmt("SELECT count(DISTINCT PATID) AS n_patients, sum(inpatient_flg) AS n_inpatient_events, sum(conf_validated) AS n_via_conf, sum(pos_tos_inpatient) AS n_via_pos_tos FROM {work('mm_dx_events_all')}")
    ),

    ie_view(
      name = "mm_dx_events_id",
      legacy = "08b_mm_dx_events_id",
      description = "Filtering MM events to identification period",
      sql = fmt("
        CREATE OR REPLACE TEMPORARY VIEW {work('mm_dx_events_id')} AS
        SELECT * FROM {work('mm_dx_events_all')}
        WHERE svc_dt BETWEEN date('{cfg$id_start}') AND date('{cfg$id_end}')
      "),
      qc = fmt("SELECT count(DISTINCT PATID) AS n_patients FROM {work('mm_dx_events_id')}")
    )
  )

  list(views = views, criteria = list())
}
