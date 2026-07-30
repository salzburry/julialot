# =============================================================================
# 02_dx_events.R -- Phase 2 -- MM diagnosis events, inpatient vs outpatient.
# -----------------------------------------------------------------------------
# Lifted from apr_30_2026/R/pipeline_steps.R. Every SQL line below is
# byte-identical to the source; only this function's first line changed,
# because the helpers it used to close over are now passed in.
# =============================================================================

phase_dx_events <- function(cfg, h, ctx) {
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
    # ---- Phase 2: MM diagnosis events ----
    # Two tables: mm_dx_events_all (full study period, for baseline
    # flags) and mm_dx_events_id (ID period only, for index qualifying).
    list(
      name = "07a_med_claim_header",
      description = "Extracting medical claim headers from CDM (study period)",
      source_tables = c("medical"),
      sql = glue("
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
      qc = glue("
        SELECT count(*) AS n_claims,
               sum(CASE WHEN PAT_PLANID IS NULL THEN 1 ELSE 0 END) AS n_null_pat_planid,
               sum(CASE WHEN LOC_CD     IS NULL THEN 1 ELSE 0 END) AS n_null_loc_cd,
               sum(CASE WHEN FST_DT     IS NULL THEN 1 ELSE 0 END) AS n_null_fst_dt
        FROM {work('med_claim_header')}")
    ),

    # CONFINEMENT TABLE EXTRACT
    # Inpatient is restricted to cases where CONF_ID is not NULL from the
    # confinement table, so CONF_ID corresponds to an actual confinement; a
    # confinement must also have associated admission AND discharge dates.
    list(
      name = "07b_confinement",
      description = "Extracting confinement records",
      source_tables = c("confinement"),
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('confinement')} AS
        SELECT DISTINCT PATID, CONF_ID,
               cast(ADMIT_DATE as date) AS ADMIT_DATE,
               cast(DISCH_DATE as date) AS DISCH_DATE
        FROM {cdm_src(cfg$tbl_confinement)}
        WHERE CONF_ID IS NOT NULL
          AND ADMIT_DATE IS NOT NULL
          AND DISCH_DATE IS NOT NULL
      "),
      qc = glue("SELECT count(*) AS n_confinements FROM {work('confinement')}")
    ),

    # All MM dx events in study period (for baseline lookback)
    # Inpatient identification using EITHER Approach 1 OR Approach 2
    # - Approach 1: POS IN (21, 51, 61) OR TOS_CD IN (FAC_IP.ACUTE, FAC_IP.REHSNF, PROF.INPVIS, FAC_IP.SNF)
    # - Approach 2: CONF_ID is validated in T_CONFINEMENT
    # Patient qualifies as inpatient if EITHER approach identifies them as inpatient
    # Join key matches the 5-column claim grain used by med_claim_header:
    # (PATID, PAT_PLANID, CLMID, FST_DT, LOC_CD).
    list(
      name = "08a_mm_dx_events_all",
      description = "Identifying MM diagnosis events (full study period, Approach 1+2 inpatient)",
      source_tables = c("med_diagnosis", "confinement"),
      sql = glue("
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
      qc = glue("SELECT count(DISTINCT PATID) AS n_patients, sum(inpatient_flg) AS n_inpatient_events, sum(conf_validated) AS n_via_conf, sum(pos_tos_inpatient) AS n_via_pos_tos FROM {work('mm_dx_events_all')}")
    ),

    # MM dx events in ID period only (for index date qualification)
    list(
      name = "08b_mm_dx_events_id",
      description = "Filtering MM events to identification period",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('mm_dx_events_id')} AS
        SELECT * FROM {work('mm_dx_events_all')}
        WHERE svc_dt BETWEEN date('{cfg$id_start}') AND date('{cfg$id_end}')
      "),
      qc = glue("SELECT count(DISTINCT PATID) AS n_patients FROM {work('mm_dx_events_id')}")
    )
  )
}
