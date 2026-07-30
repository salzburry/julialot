# =============================================================================
# 00_inputs.R -- inputs. No criteria.
# -----------------------------------------------------------------------------
# Nothing here includes or excludes anybody. It normalises the code lists and
# turns raw claims into MM diagnosis events. The funnel starts in 01_index.R.
#
# Two grains of MM events, and the difference matters:
#   mm_dx_events_all  full study period  -> baseline lookback (step 7)
#   mm_dx_events_id   ID period only     -> index qualification (step 1)
#
# Two MM code sets, likewise:
#   broad   203.x / C90.x    -> step 0 count, outpatient qualification
#   strict  203.0x / C90.0x  -> inpatient qualification, baseline MM evidence
# =============================================================================

ie_step_inputs <- function(cfg, h) {
  work <- h$work; cdm_src <- h$cdm_src; ref <- h$ref

  # Code lists come from temp views that load_csv_codelists() has already pushed
  # from each cl_*.csv (USE_CSV_CODELISTS=TRUE, the default), or from reference
  # tables. They stay views because they are tiny.
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
      select = fmt("
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
      select = fmt("
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
      select = fmt("
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
      select = fmt("
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
      select = fmt("
        SELECT
          upper(tumor_group) AS tumor_group,
          CASE WHEN upper(icd_family) IN ('9','ICD9','ICD-9','ICD9DIAG') THEN 'ICD9' ELSE 'ICD10' END AS icd_family,
          upper(regexp_replace(trim(dx), '[^A-Za-z0-9]', '')) AS dx
        FROM {other_malig_source}
        WHERE dx IS NOT NULL AND tumor_group IS NOT NULL
      "),
      qc = fmt("SELECT count(*) AS n_codes FROM {work('other_malig_codes')}")
    ),

    # Fails early if RVNU_CD is missing, instead of erroring deep inside the
    # pregnancy / clinical-trial scans that need it.
    ie_view(
      name = "rvnu_cd_check",
      legacy = "06c_validate_rvnu_cd",
      description = "Validating RVNU_CD column exists on medical table",
      source_tables = c("medical"),
      select = fmt("
        SELECT RVNU_CD FROM {cdm_src(cfg$tbl_medical)} LIMIT 1
      "),
      qc = "SELECT 'RVNU_CD column validated on medical table' AS status"
    ),

    ie_view(
      name = "med_claim_header",
      legacy = "07a_med_claim_header",
      description = "Extracting medical claim headers from CDM (study period)",
      source_tables = c("medical"),
      select = fmt("
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

    # Inpatient via CONF_ID needs a real confinement, so both an admission and a
    # discharge date.
    ie_view(
      name = "confinement",
      legacy = "07b_confinement",
      description = "Extracting confinement records",
      source_tables = c("confinement"),
      select = fmt("
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

    # Inpatient = approach 1 (POS/TOS) or approach 2 (validated CONF_ID).
    # Outpatient is the negation, so the two never overlap.
    #
    # But they do not cover everything. If POS and TOS_CD are both NULL and there
    # is no confinement, the condition is NULL, and NOT NULL is still NULL, so
    # both CASEs fall to ELSE 0:
    #
    #     inpatient_flg = 0
    #     outpatient_flg = 0     <- neither
    #
    # That claim cannot qualify a patient at step 1 by either path. Step 1 is on,
    # so this is live.
    #
    # Copied as-is from pipeline_steps.R, so the legacy comparison cannot show it
    # -- both sides behave the same. Not changed here: that would change the
    # cohort, which is the study team's call. qc_extra below counts the affected
    # claims. 06_other_malig.R handles the same case differently.
    ie_view(
      name = "mm_dx_events_all",
      legacy = "08a_mm_dx_events_all",
      description = "Identifying MM diagnosis events (full study period, Approach 1+2 inpatient)",
      source_tables = c("med_diagnosis", "confinement"),
      select = fmt("
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
      qc = fmt("SELECT count(DISTINCT PATID) AS n_patients, sum(inpatient_flg) AS n_inpatient_events, sum(conf_validated) AS n_via_conf, sum(pos_tos_inpatient) AS n_via_pos_tos FROM {work('mm_dx_events_all')}"),
      # Not compared to the legacy QC. Sizes the unknown-setting gap above, and
      # the strict-code subset -- those are the claims that could otherwise have
      # produced an inpatient index date.
      qc_extra = fmt("
        SELECT
          count(*) AS n_events,
          sum(CASE WHEN inpatient_flg = 0 AND outpatient_flg = 0 THEN 1 ELSE 0 END) AS n_setting_unknown,
          count(DISTINCT CASE WHEN inpatient_flg = 0 AND outpatient_flg = 0 THEN PATID END) AS n_patients_affected,
          sum(CASE WHEN inpatient_flg = 0 AND outpatient_flg = 0 AND mm_dx_strict_flg = 1 THEN 1 ELSE 0 END) AS n_unknown_strict
        FROM {work('mm_dx_events_all')}")
    ),

    ie_view(
      name = "mm_dx_events_id",
      legacy = "08b_mm_dx_events_id",
      description = "Filtering MM events to identification period",
      select = fmt("
        SELECT * FROM {work('mm_dx_events_all')}
        WHERE svc_dt BETWEEN date('{cfg$id_start}') AND date('{cfg$id_end}')
      "),
      qc = fmt("SELECT count(DISTINCT PATID) AS n_patients FROM {work('mm_dx_events_id')}")
    )
  )

  list(views = views, criteria = list())
}
