# =============================================================================
# 04_therapy.R -- steps 5 and 6: naive at index, treated after it
# -----------------------------------------------------------------------------
#   step 5  MM_bl_agents = 0   no MM agent in baseline (new-user design)
#   step 6  MM_FU_agents = 1   >=1 MM agent in follow-up
#
# One idea in two gates: treatment must start at or after index, not already be
# running.
#
# Step 6 is NOT "has a LOT1 regimen". It is one claim for any MM agent, any drug
# class, from the same code list the LOT build uses. Steroid-only follow-up can
# pass step 6 if those steroid codes are in the configured MM-agent codelist,
# while the LOT build excludes steroid-only starts when it defines LOT1.
# So this cohort is a superset of the 1L-regimen population, and the difference is
# real patients. Reading step 6 as "LOT1 exists" is the usual mistake.
#
# Four scans, the same four the LOT pipeline uses (S04), so IE and LOT agree on
# what an MM agent is: medical PROC_CD, medical BILL_PROC_CD, medical NDC, Rx NDC.
# NDCs are matched 11-digit zero-padded on both sides, because Optum and the code
# list disagree about leading zeros.
#
# Windows:
#   baseline   index-183 .. index-1   (excludes index)
#   follow-up  index .. fu_cap        (includes index)
# The cap is why this joins death_dt -- a post-death claim is a data artefact and
# must not make someone count as treated.
# =============================================================================

ie_step_therapy <- function(cfg, h) {
  work <- h$work; cdm_src <- h$cdm_src
  cap <- ie_fu_cap(cfg, h)
  fu_cap_expr <- cap$fu_cap_expr
  ce_join_for_fu_cap <- cap$ce_join_for_fu_cap

  views <- list(
    ie_view(
      name = "therapy_events",
      legacy = "18_therapy_events",
      description = "Identifying MM therapy events (medical PROC_CD + BILL_PROC_CD + NDC, Rx NDC)",
      source_tables = c("medical", "rx"),
      select = fmt("
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
          ON c.code_type = 'NDC'
          AND lpad(regexp_replace(coalesce(cast(m.NDC as string),''), '[^0-9]', ''), 11, '0')
            = lpad(regexp_replace(c.code, '[^0-9]', ''), 11, '0')
        WHERE m.FST_DT BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
        UNION ALL
        -- 4) Rx therapy via NDC
        SELECT /*+ BROADCAST(c) */
          r.PATID, cast(r.FILL_DT as date) AS event_dt, 'RX' AS source
        FROM {cdm_src(cfg$tbl_rx)} r
        INNER JOIN {work('mm_therapy_codes')} c
          ON c.code_type = 'NDC'
          AND lpad(regexp_replace(coalesce(cast(r.NDC as string),''), '[^0-9]', ''), 11, '0')
            = lpad(regexp_replace(c.code, '[^0-9]', ''), 11, '0')
        WHERE r.FILL_DT BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
      "),
      qc = fmt("
        SELECT
          count(*) AS n_therapy_events,
          sum(CASE WHEN source = 'MEDICAL_PROC_CD'      THEN 1 ELSE 0 END) AS n_med_proc_cd,
          sum(CASE WHEN source = 'MEDICAL_BILL_PROC_CD' THEN 1 ELSE 0 END) AS n_med_bill_proc_cd,
          sum(CASE WHEN source = 'MEDICAL_NDC'          THEN 1 ELSE 0 END) AS n_med_ndc,
          sum(CASE WHEN source = 'RX'                   THEN 1 ELSE 0 END) AS n_rx_ndc
        FROM {work('therapy_events')}")
    ),

    ie_view(
      name = "therapy_flags",
      legacy = "19_therapy_flags",
      description = "CRITERION: MM therapy in baseline/follow-up (death-aware)",
      select = fmt("
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
      qc = fmt("SELECT sum(MM_THERAPY_FOLLOWUP) AS n_with_fu_therapy FROM {work('therapy_flags')}")
    )
  )

  criteria <- list(
    ie_criterion(
      step = 5L,
      id = "no_baseline_mm_agents",
      attrition_id = "05_step5_no_bl_therapy",
      label = "Step 5: No baseline therapy (excl)",
      flag_col = "MM_bl_agents",
      predicate = "MM_bl_agents = 0",
      cfg_key = "apply_no_bl_agents_incl",
      polarity = "exclude",
      note = "No MM agent in the 183 days before index."
    ),
    ie_criterion(
      step = 6L,
      id = "fu_mm_agents",
      attrition_id = "06_step6_fu_therapy",
      label = "Step 6: FU therapy required",
      flag_col = "MM_FU_agents",
      predicate = "MM_FU_agents = 1",
      cfg_key = "apply_fu_agents_incl",
      polarity = "include",
      note = "Any MM agent, any class. Not a LOT1 regimen start."
    )
  )

  list(views = views, criteria = criteria)
}
