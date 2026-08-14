# Steps 5-7: MM agents in baseline and follow-up, MM diagnosis in baseline.

phase_clinical_flags <- function(cfg, h, ctx) {
  work <- h$work; cdm_src <- h$cdm_src
  fu_cap_expr <- ctx$fu_cap_expr; ce_join_for_fu_cap <- ctx$ce_join_for_fu_cap

  list(
    # ---- Phase 7: baseline MM evidence (Step 7 gate) ----
    # Step 7 needs >=1 strict MM dx (203.0x / C90.0x) in baseline. Follows the
    # attrition table, which does not also require a non-diagnostic claim.
    list(
      name = "17_mm_baseline_evidence_flag",
      description = "Checking for any STRICT MM dx (203.0x/C90.0x) claim in baseline period",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('mm_baseline_evidence_flag')} AS
        SELECT
          q.PATID,
          q.index_date,
          -- Per attrition table Step 7: >=1 MM claim (203.0x/C90.0x) in baseline
          -- Baseline excludes index_date (baseline = before index)
          -- mm_dx_strict_flg ensures only STRICT codes are counted
          max(CASE WHEN e.svc_dt BETWEEN date_sub(q.index_date, {cfg$baseline_days})
                                     AND date_sub(q.index_date, 1)
                    AND e.mm_dx_strict_flg = 1
               THEN 1 ELSE 0 END) AS MM_BASELINE_EVIDENCE
        FROM {work('mm_qualifying')} q
        LEFT JOIN {work('mm_dx_events_all')} e ON q.PATID = e.PATID
        GROUP BY q.PATID, q.index_date
      "),
      qc = glue("SELECT sum(MM_BASELINE_EVIDENCE) AS n_with_baseline_mm FROM {work('mm_baseline_evidence_flag')}")
    ),

    # ---- Phase 8: MM therapy events + flags (Steps 5-6) ----
    # Five sources:
    #   (1) medical PROC_CD (HCPCS/CPT)   -> MEDICAL_PROC_CD
    #   (2) medical BILL_PROC_CD (HCPCS)  -> MEDICAL_BILL_PROC_CD
    #   (3) medical NDC                   -> MEDICAL_NDC
    #   (4) Rx NDC                        -> RX
    #   (5) med_procedure PROC (HCPCS/CPT) -> MED_PROCEDURE_PROC
    # (5) finds a drug given as a procedure under a HCPCS or CPT code.
    # No ICD_FLAG condition: a J-code carrying an unexpected flag
    # would otherwise be dropped, and the join is self-limiting anyway because
    # ICD-10-PCS is seven characters and ICD-9 procedures three or four.
    list(
      name = "18_therapy_events",
      description = "Identifying MM therapy events (medical PROC_CD + BILL_PROC_CD + NDC, Rx NDC)",
      source_tables = c("medical", "rx", "med_procedure"),
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('therapy_events')} AS
        -- 1) Medical therapy via PROC_CD (HCPCS/CPT)
        SELECT /*+ BROADCAST(c) */
          m.PATID, cast(m.FST_DT as date) AS event_dt, 'MEDICAL_PROC_CD' AS source
        FROM {cdm_src(cfg$tbl_medical)} m
        INNER JOIN {work('mm_therapy_codes')} c
          ON c.code_type IN ('HCPCS','CPT')
          AND upper(regexp_replace(coalesce(cast(m.PROC_CD as string),''), '[^A-Za-z0-9]', '')) = c.code
        WHERE m.FST_DT BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
        UNION ALL
        -- 2) Medical therapy via BILL_PROC_CD (HCPCS)
        SELECT /*+ BROADCAST(c) */
          m.PATID, cast(m.FST_DT as date) AS event_dt, 'MEDICAL_BILL_PROC_CD' AS source
        FROM {cdm_src(cfg$tbl_medical)} m
        INNER JOIN {work('mm_therapy_codes')} c
          ON c.code_type = 'HCPCS'
          AND upper(regexp_replace(coalesce(cast(m.BILL_PROC_CD as string),''), '[^A-Za-z0-9]', '')) = c.code
        WHERE m.FST_DT BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
        UNION ALL
        -- 3) Medical therapy via NDC
        SELECT /*+ BROADCAST(c) */
          m.PATID, cast(m.FST_DT as date) AS event_dt, 'MEDICAL_NDC' AS source
        FROM {cdm_src(cfg$tbl_medical)} m
        INNER JOIN {work('mm_therapy_codes')} c
          -- Both sides lpad to 11. A code with no digits and a NULL NDC both
          -- become 00000000000, so require digits on the code list side.
          ON c.code_type = 'NDC'
          AND regexp_replace(c.code, '[^0-9]', '') <> ''
          AND CASE WHEN regexp_replace(coalesce(cast(m.NDC as string),''), '[^0-9]', '') RLIKE '^0+$' THEN NULL WHEN length(regexp_replace(coalesce(cast(m.NDC as string),''), '[^0-9]', '')) = 11 THEN regexp_replace(coalesce(cast(m.NDC as string),''), '[^0-9]', '') WHEN length(regexp_replace(coalesce(cast(m.NDC as string),''), '[^0-9]', '')) = 10 THEN concat('0', regexp_replace(coalesce(cast(m.NDC as string),''), '[^0-9]', '')) END
            = lpad(regexp_replace(c.code, '[^0-9]', ''), 11, '0')
        WHERE m.FST_DT BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
        UNION ALL
        -- 4) Rx therapy via NDC
        SELECT /*+ BROADCAST(c) */
          r.PATID, cast(r.FILL_DT as date) AS event_dt, 'RX' AS source
        FROM {cdm_src(cfg$tbl_rx)} r
        INNER JOIN {work('mm_therapy_codes')} c
          -- Same guard as the medical NDC join above.
          ON c.code_type = 'NDC'
          AND regexp_replace(c.code, '[^0-9]', '') <> ''
          AND CASE WHEN regexp_replace(coalesce(cast(r.NDC as string),''), '[^0-9]', '') RLIKE '^0+$' THEN NULL WHEN length(regexp_replace(coalesce(cast(r.NDC as string),''), '[^0-9]', '')) = 11 THEN regexp_replace(coalesce(cast(r.NDC as string),''), '[^0-9]', '') WHEN length(regexp_replace(coalesce(cast(r.NDC as string),''), '[^0-9]', '')) = 10 THEN concat('0', regexp_replace(coalesce(cast(r.NDC as string),''), '[^0-9]', '')) END
            = lpad(regexp_replace(c.code, '[^0-9]', ''), 11, '0')
        WHERE r.FILL_DT BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
        UNION ALL
        -- 5) Therapy given as a procedure, from med_procedure
        SELECT /*+ BROADCAST(c) */
          p.PATID, cast(p.FST_DT as date) AS event_dt, 'MED_PROCEDURE_PROC' AS source
        FROM {cdm_src(cfg$tbl_med_proc)} p
        INNER JOIN {work('mm_therapy_codes')} c
          ON c.code_type IN ('HCPCS','CPT')
          AND upper(regexp_replace(coalesce(cast(p.PROC as string),''), '[^A-Za-z0-9]', '')) = c.code
          AND regexp_replace(coalesce(cast(p.PROC as string),''), '[^A-Za-z0-9]', '') <> ''
        WHERE p.FST_DT BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
      "),
      qc = glue("
        SELECT
          count(*) AS n_therapy_events,
          sum(CASE WHEN source = 'MEDICAL_PROC_CD'      THEN 1 ELSE 0 END) AS n_med_proc_cd,
          sum(CASE WHEN source = 'MEDICAL_BILL_PROC_CD' THEN 1 ELSE 0 END) AS n_med_bill_proc_cd,
          sum(CASE WHEN source = 'MEDICAL_NDC'          THEN 1 ELSE 0 END) AS n_med_ndc,
          sum(CASE WHEN source = 'RX'                   THEN 1 ELSE 0 END) AS n_rx_ndc,
          sum(CASE WHEN source = 'MED_PROCEDURE_PROC'   THEN 1 ELSE 0 END) AS n_med_procedure
        FROM {work('therapy_events')}")
    ),

    # Join death_dt to therapy_flags so follow-up therapy is bounded by death date
    # This prevents counting therapy after death (data quality issue) and ensures
    # that patients who die are not incorrectly included due to post-death claims
    list(
      name = "19_therapy_flags",
      description = "CRITERION: MM therapy in baseline/follow-up (death-aware)",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('therapy_flags')} AS
        SELECT
          q.PATID,
          q.index_date,
          -- Baseline excludes index_date (baseline = before index)
          max(CASE WHEN t.event_dt BETWEEN date_sub(q.index_date, {cfg$baseline_days})
                                       AND date_sub(q.index_date, 1)
               THEN 1 ELSE 0 END) AS MM_THERAPY_BASELINE,
          -- Followup starts on index_date (>= index_date)
          -- Bounded by fu_cap_expr (death + optionally ENDDATE_CE under sensitivity flag)
          max(CASE WHEN t.event_dt >= q.index_date
                    AND t.event_dt <= {fu_cap_expr}
               THEN 1 ELSE 0 END) AS MM_THERAPY_FOLLOWUP
        FROM {work('mm_qualifying')} q
        LEFT JOIN {work('death_dt')} d ON q.PATID = d.PATID AND q.index_date = d.index_date
        {ce_join_for_fu_cap}
        LEFT JOIN {work('therapy_events')} t ON q.PATID = t.PATID
        GROUP BY q.PATID, q.index_date
      "),
      qc = glue("SELECT sum(MM_THERAPY_FOLLOWUP) AS n_with_fu_therapy FROM {work('therapy_flags')}")
    )
  )
}
