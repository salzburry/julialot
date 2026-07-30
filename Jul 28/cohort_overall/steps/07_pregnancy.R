# =============================================================================
# 07_pregnancy.R -- step 9: no pregnancy
# -----------------------------------------------------------------------------
#   step 9  PREGNANT_FLAG = 0
#
# One window, not two: index-183 .. fu_cap, covering baseline and follow-up as a
# single flag. BETWEEN includes the index date, so there is no gap between the
# halves and no column pair to AND. Step 10 splits its two periods; this does not.
# That asymmetry is in the original.
#
# Four code surfaces, because a pregnancy shows up in whichever one the biller
# used: ICD diagnosis, HCPCS procedure, ICD procedure, revenue code (RVNU_CD,
# facility claims only). code_type is matched as well as code, so a numeric
# revenue code cannot match a procedure code that happens to be spelled the same.
#
# RVNU_CD is what 00_inputs.R's rvnu_cd_check probe protects -- without the column
# this step would fail deep in a full-table scan instead of in the first seconds.
#
# Ships off (APPLY_PREGNANCY_EXCL=FALSE). NDMM re-applies it over the study
# period.
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
      select = fmt("
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
      note = "One window over baseline and follow-up. Ships off."
    )
  )

  list(views = views, criteria = criteria)
}
