# =============================================================================
# 07_pregnancy.R -- IE Step 9: no pregnancy
# -----------------------------------------------------------------------------
#   Step 9  PREGNANT_FLAG = 0
#
# ONE WINDOW, NOT TWO. Unlike the clinical-trial flag next door -- which splits
# baseline and follow-up into separate columns -- pregnancy is a SINGLE flag over
# one continuous span:
#
#       index-183  ..  fu_cap        (baseline AND follow-up, no split)
#
# Note the boundary: `BETWEEN date_sub(index_date, 183) AND fu_cap` includes the
# index date, so there is no gap between the two halves and no separate
# CLINTRIAL_BASELINE/FOLLOWUP-style pair to AND together. That asymmetry with
# Step 10 is in the original and is preserved here; it is not a simplification.
#
# FOUR CODE SURFACES, because a pregnancy shows up in whichever one the biller
# used:
#   ICD diagnosis   (ICD9DIAG / ICD10DIAG)
#   HCPCS procedure (medical.PROC_CD)
#   ICD procedure   (ICD9PROC / ICD10PROC, from med_procedure)
#   REVENUE code    (medical.RVNU_CD -- facility claims only)
# `code_type` is matched as well as `code`, so a numeric revenue code cannot
# accidentally match an identically-spelled procedure code.
#
# The RVNU_CD surface is exactly what 00_inputs.R's rvnu_cd_check probe protects:
# without the column this step would fail deep in a scan of the full medical
# table instead of in the first seconds of the run.
#
# CONFIGURED OFF (APPLY_PREGNANCY_EXCL=FALSE). NDMM re-applies pregnancy over the
# study period from its own scan.
# =============================================================================

ie_step_pregnancy <- function(cfg, h) {
  work <- h$work; cdm_src <- h$cdm_src
  cap <- ie_fu_cap(cfg, h)
  fu_cap_expr <- cap$fu_cap_expr
  ce_join_for_fu_cap <- cap$ce_join_for_fu_cap

  views <- list(
    ie_view(
      name = "pregnancy_flag",
      legacy = "20_pregnancy_flag",
      description = "EXCLUSION: Pregnancy flag (DX + PROC + RVNU_CD, baseline + follow-up)",
      source_tables = c("med_diagnosis", "medical", "med_procedure"),
      sql = fmt("
        CREATE OR REPLACE TEMPORARY VIEW {work('pregnancy_flag')} AS
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
          SELECT /*+ BROADCAST(p) */ e.PATID, e.event_dt
          FROM events e
          INNER JOIN {work('preg_codes')} p ON e.code_type = p.code_type AND e.code = p.code
        )
        SELECT
          q.PATID,
          q.index_date,
          -- Per attrition table: pregnancy during baseline or follow-up period
          -- Follow-up upper bound follows fu_cap_expr (sensitivity flag aware)
          max(CASE WHEN m.event_dt BETWEEN date_sub(q.index_date, {cfg$baseline_days})
                                       AND {fu_cap_expr}
               THEN 1 ELSE 0 END) AS PREGNANT_FLAG
        FROM {work('mm_qualifying')} q
        LEFT JOIN {work('death_dt')} d ON q.PATID = d.PATID AND q.index_date = d.index_date
        {ce_join_for_fu_cap}
        LEFT JOIN matched m ON q.PATID = m.PATID
        GROUP BY q.PATID, q.index_date
      "),
      qc = fmt("SELECT sum(PREGNANT_FLAG) AS n_pregnant FROM {work('pregnancy_flag')}")
    )
  )

  criteria <- list(
    ie_criterion(
      step = 9L,
      id = "no_pregnancy",
      attrition_id = "09_step9_pregnancy",
      label = "Step 9: Pregnancy (excl)",
      flag_col = "PREGNANT_FLAG",
      predicate = "PREGNANT_FLAG = 0",
      cfg_key = "apply_pregnancy_excl",
      polarity = "exclude",
      note = paste("One window spanning baseline AND follow-up (unlike Step 10).",
                   "Ships OFF: APPLY_PREGNANCY_EXCL=FALSE.")
    )
  )

  list(views = views, criteria = criteria)
}
