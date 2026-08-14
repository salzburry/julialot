# Steps 8-10: other cancer, pregnancy, clinical trial.

phase_exclusions <- function(cfg, h, ctx) {
  work <- h$work; cdm_src <- h$cdm_src
  fu_cap_expr <- ctx$fu_cap_expr; ce_join_for_fu_cap <- ctx$ce_join_for_fu_cap
  icd_family_sql <- ctx$icd_fam

  list(
    # ---- Phase 9: exclusion flags (Steps 8-10) ----
    # Three independent flags: pregnancy, clinical trial, other cancer.
    # Each scans DX + procedure + revenue codes (RVNU_CD) over baseline
    # and/or follow-up, per the attrition table.
    list(
      name = "20_pregnancy_flag",
      description = "EXCLUSION: Pregnancy flag (DX + PROC + RVNU_CD, baseline + follow-up)",
      source_tables = c("med_diagnosis", "medical", "med_procedure"),
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('pregnancy_flag')} AS
        WITH dx AS (
          SELECT PATID, cast(FST_DT as date) AS event_dt,
                 {icd_family_sql('ICD_FLAG', 'ICD9DIAG', 'ICD10DIAG')} AS code_type,
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
        -- Facility-claim procedure code. The therapy scan reads it as an HCPCS
        -- source; this scan did not, so a code populated only here was missed.
        bill_proc AS (
          SELECT PATID, cast(FST_DT as date) AS event_dt, 'HCPCS' AS code_type,
                 upper(regexp_replace(BILL_PROC_CD, '[^A-Za-z0-9]', '')) AS code
          FROM {cdm_src(cfg$tbl_medical)}
          WHERE BILL_PROC_CD IS NOT NULL
            AND FST_DT BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
        ),
        icd_proc AS (
          SELECT PATID, cast(FST_DT as date) AS event_dt,
                 {icd_family_sql('ICD_FLAG', 'ICD9PROC', 'ICD10PROC')} AS code_type,
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
        events AS (SELECT * FROM dx UNION ALL SELECT * FROM hcpcs_proc UNION ALL SELECT * FROM bill_proc UNION ALL SELECT * FROM icd_proc UNION ALL SELECT * FROM rev),
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
      qc = glue("SELECT sum(PREGNANT_FLAG) AS n_pregnant FROM {work('pregnancy_flag')}")
    ),

    # Flags evidence of clinical trial participation during each of the
    # baseline and follow-up periods.
    # Revenue code (RVNU_CD) support is included for clinical trial detection.
    list(
      name = "21_clintrial_flag",
      description = "EXCLUSION: Clinical trial flag (DX + PROC + RVNU_CD, baseline + follow-up)",
      source_tables = c("med_diagnosis", "medical", "med_procedure"),
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('clintrial_flag')} AS
        WITH dx AS (
          SELECT PATID, cast(FST_DT as date) AS event_dt,
                 {icd_family_sql('ICD_FLAG', 'ICD9DIAG', 'ICD10DIAG')} AS code_type,
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
        -- Facility-claim procedure code. The therapy scan reads it as an HCPCS
        -- source; this scan did not, so a code populated only here was missed.
        bill_proc AS (
          SELECT PATID, cast(FST_DT as date) AS event_dt, 'HCPCS' AS code_type,
                 upper(regexp_replace(BILL_PROC_CD, '[^A-Za-z0-9]', '')) AS code
          FROM {cdm_src(cfg$tbl_medical)}
          WHERE BILL_PROC_CD IS NOT NULL
            AND FST_DT BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
        ),
        icd_proc AS (
          SELECT PATID, cast(FST_DT as date) AS event_dt,
                 {icd_family_sql('ICD_FLAG', 'ICD9PROC', 'ICD10PROC')} AS code_type,
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
        events AS (SELECT * FROM dx UNION ALL SELECT * FROM hcpcs_proc UNION ALL SELECT * FROM bill_proc UNION ALL SELECT * FROM icd_proc UNION ALL SELECT * FROM rev),
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
      qc = glue("SELECT sum(CLINTRIAL_BASELINE) + sum(CLINTRIAL_FOLLOWUP) AS n_clintrial FROM {work('clintrial_flag')}")
    ),

    list(
      name = "22_other_malig_flag",
      description = "EXCLUSION: Other malignancy flag (>=1 IP or >=2 OP within 30d)",
      source_tables = c("med_diagnosis", "medical", "confinement"),
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('other_malig_flag')} AS
        WITH dx AS (
          -- Carry the full 5-column claim key so dx_with_setting can join
          -- med_claim_header on the same grain (see step 07a comment).
          SELECT d.PATID, d.PAT_PLANID, d.CLMID, d.FST_DT, d.LOC_CD,
                 cast(d.FST_DT as date) AS event_dt,
                 upper(regexp_replace(d.DIAG, '[^A-Za-z0-9]', '')) AS dx,
                 {icd_family_sql('d.ICD_FLAG')} AS icd_family
          FROM {cdm_src(cfg$tbl_med_diag)} d
          WHERE FST_DT BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
        ),
        dx_mapped AS (
          SELECT /*+ BROADCAST(o) */
                 dx.PATID, dx.PAT_PLANID, dx.CLMID, dx.FST_DT, dx.LOC_CD,
                 dx.event_dt, o.tumor_group
          FROM dx
          INNER JOIN {work('other_malig_codes')} o ON dx.dx = o.dx AND dx.icd_family = o.icd_family
        ),
        -- Use the same inpatient rule as MM qualifying.
        dx_with_setting AS (
          SELECT dm.PATID, dm.CLMID, dm.event_dt, dm.tumor_group,
                 CASE WHEN h.line_inpatient = 1 OR cf.CONF_ID IS NOT NULL
                      THEN 1 ELSE 0 END AS inpatient_flg
          FROM dx_mapped dm
          INNER JOIN {work('med_claim_header')} h
            -- Null-safe on PAT_PLANID / LOC_CD; see comment in step 08a.
            ON dm.PATID      =   h.PATID
           AND dm.CLMID      =   h.CLMID
           AND dm.FST_DT     =   h.FST_DT
           AND dm.PAT_PLANID <=> h.PAT_PLANID
           AND dm.LOC_CD     <=> h.LOC_CD
          LEFT JOIN {work('confinement')} cf
            ON h.PATID = cf.PATID AND h.CONF_ID = cf.CONF_ID
        ),
        -- Path A: >=1 inpatient claim for a tumor group in baseline
        inpatient_flag AS (
          SELECT DISTINCT PATID, tumor_group, event_dt
          FROM dx_with_setting
          WHERE inpatient_flg = 1
        ),
        -- Path B: >=2 outpatient claims on separate days within 30 days
        outpatient_dates AS (
          SELECT DISTINCT PATID, tumor_group, event_dt
          FROM dx_with_setting
          WHERE inpatient_flg = 0
        ),
        with_next AS (
          SELECT PATID, tumor_group, event_dt,
                 lead(event_dt) OVER (PARTITION BY PATID, tumor_group ORDER BY event_dt) AS next_dt
          FROM outpatient_dates
        ),
        outpatient_pairs AS (
          SELECT PATID, tumor_group, event_dt AS first_dt, next_dt,
                 datediff(next_dt, event_dt) AS diff_days
          FROM with_next WHERE next_dt IS NOT NULL
        )
        SELECT
          q.PATID,
          q.index_date,
          -- >=1 inpatient OR >=2 outpatient within 30d, same tumor group, in baseline
          max(CASE
            -- Path A: single inpatient claim in baseline
            WHEN ip.event_dt BETWEEN date_sub(q.index_date, {cfg$baseline_days})
                                 AND date_sub(q.index_date, 1)
            THEN 1
            -- Path B: 2 outpatient claims within 30d, first in baseline
            -- Only the first of the 2 codes
            -- is required to occur inside the baseline period. The confirming
            -- second claim may fall after index, as long as the pair is
            -- within 30 days of each other.
            WHEN op.diff_days <= 30
              AND op.first_dt BETWEEN date_sub(q.index_date, {cfg$baseline_days})
                                  AND date_sub(q.index_date, 1)
            THEN 1
            ELSE 0
          END) AS OTHER_MALIGN_FLAG
        FROM {work('mm_qualifying')} q
        LEFT JOIN inpatient_flag ip ON q.PATID = ip.PATID
        LEFT JOIN outpatient_pairs op ON q.PATID = op.PATID
        GROUP BY q.PATID, q.index_date
      "),
      qc = glue("SELECT sum(OTHER_MALIGN_FLAG) AS n_other_malig FROM {work('other_malig_flag')}")
    )
  )
}
