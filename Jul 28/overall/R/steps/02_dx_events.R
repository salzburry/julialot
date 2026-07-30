# MM diagnosis events: claim headers, confinements, then the dx event tables.

phase_dx_events <- function(cfg, h, ctx) {
  work <- h$work; cdm_src <- h$cdm_src

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
        -- Keep the five-column claim grain.
        -- Flag each line before max(POS) can hide an inpatient code.
        SELECT PATID, PAT_PLANID, CLMID, FST_DT, LOC_CD,
               max(CONF_ID) AS CONF_ID,
               max(POS)     AS POS,
               max(TOS_CD)  AS TOS_CD,
               max(CASE WHEN POS IN ('21', '51', '61')
                          OR TOS_CD IN ('FAC_IP.ACUTE', 'FAC_IP.REHSNF', 'PROF.INPVIS', 'FAC_IP.SNF')
                        THEN 1 ELSE 0 END) AS line_inpatient
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

    # Keep confinements with valid admission and discharge dates.
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

    # Inpatient means a POS/TOS line flag or a valid confinement.
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
          -- POS/TOS line flag or valid confinement.
          CASE WHEN h.line_inpatient = 1 OR cf.CONF_ID IS NOT NULL
               THEN 1 ELSE 0 END AS inpatient_flg,
          -- line_inpatient is 0/1, so missing POS/TOS stays null-safe.
          CASE WHEN NOT (h.line_inpatient = 1 OR cf.CONF_ID IS NOT NULL)
               THEN 1 ELSE 0 END AS outpatient_flg,
          -- The code list decides which codes are in scope at all. This flag
          -- marks the 203.0x / C90.0x subset, which inpatient qualifying and
          -- the baseline rule additionally require.
          CASE WHEN (CASE WHEN upper(d.ICD_FLAG) IN ('9','ICD9','ICD-9') THEN 'ICD9' ELSE 'ICD10' END) = 'ICD9'
                      AND upper(regexp_replace(d.DIAG, '[^A-Za-z0-9]', '')) LIKE '2030%'
                 OR (CASE WHEN upper(d.ICD_FLAG) IN ('9','ICD9','ICD-9') THEN 'ICD9' ELSE 'ICD10' END) = 'ICD10'
                      AND upper(regexp_replace(d.DIAG, '[^A-Za-z0-9]', '')) LIKE 'C900%'
               THEN 1 ELSE 0 END AS mm_dx_strict_flg,
          -- QC flags for each approach
          CASE WHEN cf.CONF_ID IS NOT NULL THEN 1 ELSE 0 END AS conf_validated,
          h.line_inpatient AS pos_tos_inpatient
        FROM {cdm_src(cfg$tbl_med_diag)} d
        INNER JOIN {work('med_claim_header')} h
          -- PAT_PLANID and LOC_CD may be NULL; use null-safe equality.
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
