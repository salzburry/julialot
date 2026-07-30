# =============================================================================
# 08_clintrial.R -- IE Step 10: no clinical-trial participation
# -----------------------------------------------------------------------------
#   Step 10  CLINTRIAL_BASELINE = 0 AND CLINTRIAL_FOLLOWUP = 0
#
# THE ONLY CRITERION WITH TWO COLUMNS IN ONE PREDICATE. Baseline and follow-up
# are separate flags, ANDed in the filter:
#
#     baseline    index-183 .. index-1     (excludes index)
#     follow-up   index     .. fu_cap      (includes index)
#
# Because they are separate, this is also the only gate whose relaxation is
# partial: dropping the follow-up half while keeping the baseline half is a
# one-column edit. Step 9 (pregnancy) collapses its two periods into a single
# flag and cannot be split that way.
#
# Same four code surfaces as pregnancy (ICD dx, HCPCS proc, ICD proc, revenue
# code), same code_type + code matching, different code list (clintrial_codes).
#
# CONFIGURED OFF (APPLY_CLINTRIAL_EXCL=FALSE). Read pipeline_inputs.csv's note
# before turning it on: clinical trial is NOT in the NDMM IE spec (S6.2.1), so
# nothing downstream re-applies it, and the study team has to confirm it belongs
# in cohort 1 at all.
# =============================================================================

ie_step_clintrial <- function(cfg, h) {
  work <- h$work; cdm_src <- h$cdm_src
  cap <- ie_fu_cap(cfg, h)
  fu_cap_expr <- cap$fu_cap_expr
  ce_join_for_fu_cap <- cap$ce_join_for_fu_cap

  views <- list(
    ie_view(
      name = "clintrial_flag",
      legacy = "21_clintrial_flag",
      description = "EXCLUSION: Clinical trial flag (DX + PROC + RVNU_CD, baseline + follow-up)",
      source_tables = c("med_diagnosis", "medical", "med_procedure"),
      sql = fmt("
        CREATE OR REPLACE TEMPORARY VIEW {work('clintrial_flag')} AS
        WITH dx AS (
          SELECT PATID, cast(FST_DT as date) AS event_dt,
                 CASE WHEN upper(ICD_FLAG) IN ('9','ICD9','ICD-9') THEN 'ICD9DIAG' ELSE 'ICD10DIAG' END AS code_type,
                 upper(regexp_replace(DIAG, '[^A-Za-z0-9]', '')) AS code
          FROM {cdm_src(cfg$tbl_med_diag)}
          WHERE FST_DT BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
        ),
        hcpcs_proc AS (
          SELECT PATID, cast(FST_DT as date) AS event_dt, 'HCPCS' AS code_type,
                 upper(regexp_replace(PROC_CD, '[^A-Za-z0-9]', '')) AS code
          FROM {cdm_src(cfg$tbl_medical)}
          WHERE PROC_CD IS NOT NULL
            AND FST_DT BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
        ),
        icd_proc AS (
          SELECT PATID, cast(FST_DT as date) AS event_dt,
                 CASE WHEN upper(ICD_FLAG) IN ('9','ICD9','ICD-9') THEN 'ICD9PROC' ELSE 'ICD10PROC' END AS code_type,
                 upper(regexp_replace(PROC, '[^A-Za-z0-9]', '')) AS code
          FROM {cdm_src(cfg$tbl_med_proc)}
          WHERE PROC IS NOT NULL
            AND FST_DT BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
        ),
        rev AS (
          SELECT PATID, cast(FST_DT as date) AS event_dt, 'REV' AS code_type,
                 upper(TRIM(RVNU_CD)) AS code
          FROM {cdm_src(cfg$tbl_medical)}
          WHERE RVNU_CD IS NOT NULL AND TRIM(RVNU_CD) != ''
            AND FST_DT BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
        ),
        events AS (SELECT * FROM dx UNION ALL SELECT * FROM hcpcs_proc UNION ALL SELECT * FROM icd_proc UNION ALL SELECT * FROM rev),
        matched AS (
          SELECT /*+ BROADCAST(c) */ e.PATID, e.event_dt
          FROM events e
          INNER JOIN {work('clintrial_codes')} c ON e.code_type = c.code_type AND e.code = c.code
        )
        SELECT
          q.PATID,
          q.index_date,
          -- Baseline excludes index_date (baseline = before index)
          max(CASE WHEN m.event_dt BETWEEN date_sub(q.index_date, {cfg$baseline_days})
                                       AND date_sub(q.index_date, 1)
               THEN 1 ELSE 0 END) AS CLINTRIAL_BASELINE,
          -- Followup starts on index_date
          -- Follow-up upper bound follows fu_cap_expr (sensitivity flag aware)
          max(CASE WHEN m.event_dt >= q.index_date
                    AND m.event_dt <= {fu_cap_expr}
               THEN 1 ELSE 0 END) AS CLINTRIAL_FOLLOWUP
        FROM {work('mm_qualifying')} q
        LEFT JOIN {work('death_dt')} d ON q.PATID = d.PATID AND q.index_date = d.index_date
        {ce_join_for_fu_cap}
        LEFT JOIN matched m ON q.PATID = m.PATID
        GROUP BY q.PATID, q.index_date
      "),
      qc = fmt("SELECT sum(CLINTRIAL_BASELINE) + sum(CLINTRIAL_FOLLOWUP) AS n_clintrial FROM {work('clintrial_flag')}")
    )
  )

  criteria <- list(
    ie_criterion(
      step = 10L,
      id = "no_clintrial",
      attrition_id = "10_step10_clintrial",
      label = "Step 10: Clinical trial (excl)",
      flag_col = c("CLINTRIAL_BASELINE", "CLINTRIAL_FOLLOWUP"),
      predicate = "CLINTRIAL_BASELINE = 0 AND CLINTRIAL_FOLLOWUP = 0",
      cfg_key = "apply_clintrial_excl",
      polarity = "exclude",
      note = paste("Two columns, one gate. Ships OFF, and nothing downstream",
                   "re-applies it -- not in the NDMM IE spec (S6.2.1).")
    )
  )

  list(views = views, criteria = criteria)
}
