#' SQL Builder for Databricks/Spark
#'
#' Generates optimized SQL for building attrition cohort tables
#' with Spark-specific optimizations:
#' - CACHE TABLE for frequently accessed data
#' - OPTIMIZE and ZORDER for Delta tables
#' - Broadcast hints for small tables
#' - Partitioning strategies

library(glue)

#' Build fully qualified table name
#'
#' @param config Configuration with catalog/schema info
#' @param table Table name
#' @param schema Override schema (optional)
#' @return Fully qualified table name
#' @export
fq_table <- function(config, table, schema = NULL) {
  s <- schema %||% config$db$work_schema
  if (!is.null(config$db$catalog) && config$db$catalog != "") {
    paste0(config$db$catalog, ".", s, ".", table)
  } else {
    paste0(s, ".", table)
  }
}

#' Reference table in CDM schema
#' @export
cdm_table <- function(config, table) {
  fq_table(config, table, config$db$cdm_schema)
}

#' Reference table in reference/codelist schema
#' @export
ref_table <- function(config, table) {
  fq_table(config, table, config$db$ref_schema)
}

#' Work table reference
#' @export
work_table <- function(config, table) {
  fq_table(config, table, config$db$work_schema)
}

# ============================================================================
# SQL GENERATION FUNCTIONS
# ============================================================================

#' Generate SQL to create working schema
#' @export
sql_create_schema <- function(config) {
  schema_path <- if (!is.null(config$db$catalog) && config$db$catalog != "") {
    paste0(config$db$catalog, ".", config$db$work_schema)
  } else {
    config$db$work_schema
  }
  glue("CREATE SCHEMA IF NOT EXISTS {schema_path}")
}

#' Generate SQL for normalized MM diagnosis codes
#' @export
sql_mm_dx_codes <- function(config) {
  glue("
CREATE OR REPLACE TABLE {work_table(config, 'mm_dx_codes')} AS
SELECT
  CASE
    WHEN upper(icd_family) IN ('9','ICD9','ICD-9') THEN 'ICD9'
    WHEN upper(icd_family) IN ('10','ICD10','ICD-10') THEN 'ICD10'
    ELSE upper(icd_family)
  END AS icd_family,
  upper(regexp_replace(dx, '\\\\.', '')) AS dx
FROM {ref_table(config, config$tables$cl_mm_dx)}
WHERE dx IS NOT NULL
")
}

#' Generate SQL for diagnostic procedure codes
#' @export
sql_diagnostic_proc_codes <- function(config) {
  glue("
CREATE OR REPLACE TABLE {work_table(config, 'diag_proc_codes')} AS
SELECT DISTINCT
  upper(regexp_replace(proc_cd, '\\\\.', '')) AS proc_cd
FROM {ref_table(config, config$tables$cl_diagnostic_proc)}
WHERE proc_cd IS NOT NULL
")
}

#' Generate SQL for therapy codes (NDC + HCPCS/CPT)
#' @export
sql_therapy_codes <- function(config) {
  glue("
CREATE OR REPLACE TABLE {work_table(config, 'mm_therapy_codes')} AS
SELECT
  upper(code_type) AS code_type,
  upper(regexp_replace(code, '\\\\.', '')) AS code
FROM {ref_table(config, config$tables$cl_mm_therapy)}
WHERE code IS NOT NULL
")
}

#' Generate SQL for pregnancy codes
#' @export
sql_pregnancy_codes <- function(config) {
  glue("
CREATE OR REPLACE TABLE {work_table(config, 'preg_codes')} AS
SELECT
  upper(code_type) AS code_type,
  upper(regexp_replace(code, '\\\\.', '')) AS code
FROM {ref_table(config, config$tables$cl_preg)}
WHERE code IS NOT NULL
")
}

#' Generate SQL for clinical trial codes
#' @export
sql_clintrial_codes <- function(config) {
  glue("
CREATE OR REPLACE TABLE {work_table(config, 'clintrial_codes')} AS
SELECT
  upper(code_type) AS code_type,
  upper(regexp_replace(code, '\\\\.', '')) AS code
FROM {ref_table(config, config$tables$cl_clintrial)}
WHERE code IS NOT NULL
")
}

#' Generate SQL for other malignancy codes
#' @export
sql_other_malig_codes <- function(config) {
  glue("
CREATE OR REPLACE TABLE {work_table(config, 'other_malig_dx_codes')} AS
SELECT
  upper(tumor_group) AS tumor_group,
  CASE
    WHEN upper(icd_family) IN ('9','ICD9','ICD-9') THEN 'ICD9'
    WHEN upper(icd_family) IN ('10','ICD10','ICD-10') THEN 'ICD10'
    ELSE upper(icd_family)
  END AS icd_family,
  upper(regexp_replace(dx, '\\\\.', '')) AS dx
FROM {ref_table(config, config$tables$cl_other_malig)}
WHERE dx IS NOT NULL AND tumor_group IS NOT NULL
")
}

#' Generate SQL for medical claim header (for inpatient identification)
#' @export
sql_med_claim_header <- function(config) {
  glue("
CREATE OR REPLACE TABLE {work_table(config, 'med_claim_header')} AS
SELECT
  PATID,
  CLMID,
  max(CONF_ID) AS CONF_ID
FROM {cdm_table(config, config$tables$tbl_medical)}
GROUP BY PATID, CLMID
")
}

#' Generate SQL for MM diagnosis events
#' @export
sql_mm_dx_events <- function(config) {
  glue("
CREATE OR REPLACE TABLE {work_table(config, 'mm_dx_events')} AS
SELECT /*+ BROADCAST(c) */
  d.PATID,
  d.CLMID,
  cast(d.FST_DT as date) AS svc_dt,
  upper(regexp_replace(d.DIAG, '\\\\.', '')) AS diag,
  CASE
    WHEN upper(d.ICD_FLAG) IN ('9','ICD9','ICD-9') THEN 'ICD9'
    ELSE 'ICD10'
  END AS icd_family,
  d.DIAG_POSITION,
  h.CONF_ID,
  CASE WHEN h.CONF_ID IS NOT NULL THEN 1 ELSE 0 END AS inpatient_flg,
  CASE WHEN h.CONF_ID IS NULL THEN 1 ELSE 0 END AS outpatient_flg
FROM {cdm_table(config, config$tables$tbl_med_diag)} d
JOIN {work_table(config, 'med_claim_header')} h
  ON d.PATID = h.PATID AND d.CLMID = h.CLMID
JOIN {work_table(config, 'mm_dx_codes')} c
  ON upper(regexp_replace(d.DIAG, '\\\\.', '')) = c.dx
 AND (CASE WHEN upper(d.ICD_FLAG) IN ('9','ICD9','ICD-9') THEN 'ICD9' ELSE 'ICD10' END) = c.icd_family
WHERE cast(d.FST_DT as date) BETWEEN date('{config$study$id_start}') AND date('{config$study$id_end}')
")
}

#' Generate SQL for outpatient date pairs
#' @export
sql_mm_outpt_pairs <- function(config) {
  # First get distinct outpatient dates
  sql1 <- glue("
CREATE OR REPLACE TABLE {work_table(config, 'mm_outpt_dates')} AS
SELECT DISTINCT PATID, svc_dt
FROM {work_table(config, 'mm_dx_events')}
WHERE outpatient_flg = 1
")

  # Then compute pairs with window function
  sql2 <- glue("
CREATE OR REPLACE TABLE {work_table(config, 'mm_outpt_pairs')} AS
WITH ordered AS (
  SELECT
    PATID,
    svc_dt,
    lead(svc_dt) OVER (PARTITION BY PATID ORDER BY svc_dt) AS next_dt
  FROM {work_table(config, 'mm_outpt_dates')}
)
SELECT
  PATID,
  svc_dt AS first_dt,
  next_dt,
  datediff(next_dt, svc_dt) AS diff_days
FROM ordered
WHERE next_dt IS NOT NULL
")

  list(sql1, sql2)
}

#' Generate SQL for qualifying index date (core logic)
#' @export
sql_mm_qualifying <- function(config) {
  w30 <- config$study$dx_window_30
  w60 <- config$study$dx_window_60
  w90 <- config$study$dx_window_90

  glue("
CREATE OR REPLACE TABLE {work_table(config, 'mm_qualifying')} AS
WITH outpt AS (
  SELECT
    PATID,
    max(CASE WHEN diff_days <= {w90} THEN 1 ELSE 0 END) AS outpt2_90,
    max(CASE WHEN diff_days <= {w60} THEN 1 ELSE 0 END) AS outpt2_60,
    max(CASE WHEN diff_days <= {w30} THEN 1 ELSE 0 END) AS outpt2_30,
    min(CASE WHEN diff_days <= {w90} THEN first_dt END) AS idx_outpt_90,
    min(CASE WHEN diff_days <= {w60} THEN first_dt END) AS idx_outpt_60,
    min(CASE WHEN diff_days <= {w30} THEN first_dt END) AS idx_outpt_30
  FROM {work_table(config, 'mm_outpt_pairs')}
  GROUP BY PATID
),
inpt AS (
  SELECT
    PATID,
    1 AS inpt1,
    min(svc_dt) AS idx_inpt
  FROM {work_table(config, 'mm_dx_events')}
  WHERE inpatient_flg = 1
  GROUP BY PATID
)
SELECT
  coalesce(i.PATID, o.PATID) AS PATID,
  coalesce(i.inpt1, 0) AS inpt1,
  coalesce(o.outpt2_90, 0) AS outpt2_90,
  coalesce(o.outpt2_60, 0) AS outpt2_60,
  coalesce(o.outpt2_30, 0) AS outpt2_30,
  i.idx_inpt,
  o.idx_outpt_90,
  o.idx_outpt_60,
  o.idx_outpt_30,
  -- Index date: earliest of inpatient or qualifying outpatient (90-day window primary)
  CASE
    WHEN coalesce(i.inpt1,0)=1 AND o.idx_outpt_90 IS NULL THEN i.idx_inpt
    WHEN coalesce(i.inpt1,0)=0 AND o.idx_outpt_90 IS NOT NULL THEN o.idx_outpt_90
    WHEN coalesce(i.inpt1,0)=1 AND o.idx_outpt_90 IS NOT NULL THEN least(i.idx_inpt, o.idx_outpt_90)
    ELSE NULL
  END AS index_date,
  CASE
    WHEN coalesce(i.inpt1,0)=1 AND (o.idx_outpt_90 IS NULL OR i.idx_inpt <= o.idx_outpt_90) THEN 'INPATIENT'
    WHEN o.idx_outpt_90 IS NOT NULL THEN 'OUTPATIENT_2IN90'
    ELSE NULL
  END AS index_source
FROM inpt i
FULL OUTER JOIN outpt o
  ON i.PATID = o.PATID
WHERE (coalesce(i.inpt1,0)=1 OR coalesce(o.outpt2_90,0)=1)
")
}

#' Generate SQL for enrollment spans with gap logic
#' @export
sql_enrollment_spans <- function(config) {
  gap_days <- config$study$gap_days

  glue("
CREATE OR REPLACE TABLE {work_table(config, 'enroll_spans_gap30')} AS
WITH base AS (
  SELECT
    PATID,
    cast(ELIGEFF as date) AS elig_eff,
    cast(ELIGEND as date) AS elig_end
  FROM {cdm_table(config, config$tables$tbl_member_elig)}
  WHERE ELIGEFF IS NOT NULL AND ELIGEND IS NOT NULL
),
ordered AS (
  SELECT
    *,
    lag(elig_end) OVER (PARTITION BY PATID ORDER BY elig_eff, elig_end) AS prev_end
  FROM base
),
flag AS (
  SELECT
    *,
    CASE
      WHEN prev_end IS NULL THEN 1
      WHEN elig_eff <= date_add(prev_end, {gap_days}) THEN 0
      ELSE 1
    END AS new_grp
  FROM ordered
),
grp AS (
  SELECT
    *,
    sum(new_grp) OVER (
      PARTITION BY PATID
      ORDER BY elig_eff, elig_end
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS grp_id
  FROM flag
)
SELECT
  PATID,
  grp_id,
  min(elig_eff) AS cov_start,
  max(elig_end) AS cov_end
FROM grp
GROUP BY PATID, grp_id
")
}

#' Generate SQL for CE flags (baseline and follow-up)
#' @export
sql_ce_flags <- function(config) {
  baseline_days <- config$study$baseline_days

  glue("
CREATE OR REPLACE TABLE {work_table(config, 'ce_flags')} AS
WITH idx AS (
  SELECT PATID, index_date
  FROM {work_table(config, 'mm_qualifying')}
),
spans AS (
  SELECT PATID, cov_start, cov_end
  FROM {work_table(config, 'enroll_spans_gap30')}
),
joined AS (
  SELECT
    i.PATID,
    i.index_date,
    date_sub(i.index_date, {baseline_days}) AS baseline_start,
    date_sub(i.index_date, 1) AS baseline_end,
    s.cov_start,
    s.cov_end,
    CASE WHEN s.cov_start <= date_sub(i.index_date, {baseline_days})
           AND s.cov_end >= date_sub(i.index_date, 1)
         THEN 1 ELSE 0 END AS covers_baseline_6m,
    CASE WHEN s.cov_start <= i.index_date AND s.cov_end >= i.index_date
         THEN 1 ELSE 0 END AS covers_index_day
  FROM idx i
  LEFT JOIN spans s
    ON i.PATID = s.PATID
)
SELECT
  PATID,
  index_date,
  max(covers_baseline_6m) AS CE_6MOS_GAP30,
  max(covers_index_day) AS CE_1D_POST_INDEX_GAP30,
  min(baseline_start) AS baseline_start,
  min(baseline_end) AS baseline_end,
  max(CASE WHEN cov_start <= index_date AND cov_end >= index_date THEN cov_end END) AS ENDDATE_CE
FROM joined
GROUP BY PATID, index_date
")
}

#' Generate SQL for member demographics
#' @export
sql_member_demo <- function(config) {
  glue("
CREATE OR REPLACE TABLE {work_table(config, 'member_demo')} AS
WITH ranked AS (
  SELECT
    PATID,
    GDR_CD,
    cast(YRDOB as int) AS YRDOB,
    cast(ELIGEND as date) AS elig_end,
    row_number() OVER (
      PARTITION BY PATID
      ORDER BY (CASE WHEN upper(GDR_CD) IS NOT NULL AND upper(GDR_CD) <> 'U' THEN 1 ELSE 0 END) DESC,
               cast(ELIGEND as date) DESC
    ) AS rn
  FROM {cdm_table(config, config$tables$tbl_member_elig)}
)
SELECT PATID, GDR_CD, YRDOB
FROM ranked
WHERE rn = 1
")
}

#' Generate SQL for non-diagnostic claim indicator
#' @export
sql_claim_nondiagnostic <- function(config) {
  glue("
CREATE OR REPLACE TABLE {work_table(config, 'claim_nondiagnostic')} AS
WITH lines AS (
  SELECT
    PATID,
    CLMID,
    upper(regexp_replace(PROC_CD, '\\\\.', '')) AS proc_cd
  FROM {cdm_table(config, config$tables$tbl_medical)}
),
marked AS (
  SELECT /*+ BROADCAST(d) */
    l.PATID,
    l.CLMID,
    CASE WHEN d.proc_cd IS NOT NULL THEN 1 ELSE 0 END AS is_diagnostic_line
  FROM lines l
  LEFT JOIN {work_table(config, 'diag_proc_codes')} d
    ON l.proc_cd = d.proc_cd
)
SELECT
  PATID,
  CLMID,
  max(CASE WHEN is_diagnostic_line = 0 THEN 1 ELSE 0 END) AS has_nondiagnostic_line
FROM marked
GROUP BY PATID, CLMID
")
}

#' Generate SQL for MM baseline non-diagnostic flag (smoldering indicator)
#' @export
sql_mm_baseline_nondx <- function(config) {
  baseline_days <- config$study$baseline_days

  glue("
CREATE OR REPLACE TABLE {work_table(config, 'mm_baseline_nondx_flag')} AS
WITH idx AS (
  SELECT PATID, index_date
  FROM {work_table(config, 'mm_qualifying')}
),
base AS (
  SELECT PATID, CLMID, svc_dt
  FROM {work_table(config, 'mm_dx_events')}
),
j AS (
  SELECT
    i.PATID,
    max(CASE
          WHEN b.svc_dt BETWEEN date_sub(i.index_date, {baseline_days}) AND date_sub(i.index_date, 1)
           AND n.has_nondiagnostic_line = 1
          THEN 1 ELSE 0
        END) AS MM_BASELINE_NONDX
  FROM idx i
  LEFT JOIN base b ON i.PATID = b.PATID
  LEFT JOIN {work_table(config, 'claim_nondiagnostic')} n
    ON b.PATID = n.PATID AND b.CLMID = n.CLMID
  GROUP BY i.PATID
)
SELECT * FROM j
")
}

#' Generate SQL for therapy events
#' @export
sql_therapy_events <- function(config) {
  med_days_supply <- config$study$med_days_supply_assumption %||% 28

  glue("
CREATE OR REPLACE TABLE {work_table(config, 'therapy_events')} AS
-- MEDICAL therapy via PROC_CD
SELECT /*+ BROADCAST(c) */
  m.PATID,
  cast(m.FST_DT as date) AS event_dt,
  'MEDICAL' AS source,
  'PROC' AS code_type,
  upper(regexp_replace(m.PROC_CD, '\\\\.', '')) AS code,
  cast(NULL as int) AS days_sup,
  {med_days_supply} AS days_sup_assumed
FROM {cdm_table(config, config$tables$tbl_medical)} m
JOIN {work_table(config, 'mm_therapy_codes')} c
  ON c.code_type IN ('HCPCS','CPT','PROC')
 AND upper(regexp_replace(m.PROC_CD, '\\\\.', '')) = c.code
WHERE m.FST_DT IS NOT NULL

UNION ALL

-- MEDICAL therapy via NDC on medical lines
SELECT /*+ BROADCAST(c) */
  m.PATID,
  cast(m.FST_DT as date) AS event_dt,
  'MEDICAL' AS source,
  'NDC' AS code_type,
  upper(regexp_replace(m.NDC, '\\\\.', '')) AS code,
  cast(NULL as int) AS days_sup,
  {med_days_supply} AS days_sup_assumed
FROM {cdm_table(config, config$tables$tbl_medical)} m
JOIN {work_table(config, 'mm_therapy_codes')} c
  ON c.code_type = 'NDC'
 AND upper(regexp_replace(m.NDC, '\\\\.', '')) = c.code
WHERE m.FST_DT IS NOT NULL AND m.NDC IS NOT NULL

UNION ALL

-- RX therapy via NDC
SELECT /*+ BROADCAST(c) */
  r.PATID,
  cast(r.FILL_DT as date) AS event_dt,
  'RX' AS source,
  'NDC' AS code_type,
  upper(regexp_replace(r.NDC, '\\\\.', '')) AS code,
  cast(r.DAYS_SUP as int) AS days_sup,
  cast(NULL as int) AS days_sup_assumed
FROM {cdm_table(config, config$tables$tbl_rx)} r
JOIN {work_table(config, 'mm_therapy_codes')} c
  ON c.code_type = 'NDC'
 AND upper(regexp_replace(r.NDC, '\\\\.', '')) = c.code
WHERE r.FILL_DT IS NOT NULL
")
}

#' Generate SQL for therapy flags (baseline and follow-up)
#' @export
sql_therapy_flags <- function(config) {
  baseline_days <- config$study$baseline_days
  study_end <- config$study$study_end

  glue("
CREATE OR REPLACE TABLE {work_table(config, 'therapy_flags')} AS
WITH idx AS (
  SELECT PATID, index_date
  FROM {work_table(config, 'mm_qualifying')}
),
te AS (
  SELECT PATID, event_dt
  FROM {work_table(config, 'therapy_events')}
)
SELECT
  i.PATID,
  max(CASE WHEN te.event_dt BETWEEN date_sub(i.index_date, {baseline_days}) AND date_sub(i.index_date, 1)
           THEN 1 ELSE 0 END) AS MM_THERAPY_BASELINE,
  max(CASE WHEN te.event_dt >= i.index_date AND te.event_dt <= date('{study_end}')
           THEN 1 ELSE 0 END) AS MM_THERAPY_FOLLOWUP
FROM idx i
LEFT JOIN te ON i.PATID = te.PATID
GROUP BY i.PATID
")
}

#' Generate SQL for pregnancy flag
#' @export
sql_pregnancy_flag <- function(config) {
  baseline_days <- config$study$baseline_days
  study_end <- config$study$study_end

  glue("
CREATE OR REPLACE TABLE {work_table(config, 'pregnancy_flag')} AS
WITH idx AS (
  SELECT PATID, index_date
  FROM {work_table(config, 'mm_qualifying')}
),
dx AS (
  SELECT PATID, cast(FST_DT as date) AS event_dt, 'DX' AS code_type,
         upper(regexp_replace(DIAG, '\\\\.', '')) AS code
  FROM {cdm_table(config, config$tables$tbl_med_diag)}
),
proc AS (
  SELECT PATID, cast(FST_DT as date) AS event_dt, 'PROC' AS code_type,
         upper(regexp_replace(PROC_CD, '\\\\.', '')) AS code
  FROM {cdm_table(config, config$tables$tbl_medical)}
  WHERE PROC_CD IS NOT NULL
),
events AS (
  SELECT * FROM dx UNION ALL SELECT * FROM proc
),
matched AS (
  SELECT /*+ BROADCAST(p) */ e.PATID, e.event_dt
  FROM events e
  JOIN {work_table(config, 'preg_codes')} p
    ON e.code_type = p.code_type AND e.code = p.code
)
SELECT
  i.PATID,
  max(CASE WHEN m.event_dt BETWEEN date_sub(i.index_date, {baseline_days}) AND date('{study_end}')
           THEN 1 ELSE 0 END) AS PREGNANT_FLAG
FROM idx i
LEFT JOIN matched m ON i.PATID = m.PATID
GROUP BY i.PATID
")
}

#' Generate SQL for clinical trial flag
#' @export
sql_clintrial_flag <- function(config) {
  baseline_days <- config$study$baseline_days
  study_end <- config$study$study_end

  glue("
CREATE OR REPLACE TABLE {work_table(config, 'clintrial_flag')} AS
WITH idx AS (
  SELECT PATID, index_date
  FROM {work_table(config, 'mm_qualifying')}
),
dx AS (
  SELECT PATID, cast(FST_DT as date) AS event_dt, 'DX' AS code_type,
         upper(regexp_replace(DIAG, '\\\\.', '')) AS code
  FROM {cdm_table(config, config$tables$tbl_med_diag)}
),
proc AS (
  SELECT PATID, cast(FST_DT as date) AS event_dt, 'PROC' AS code_type,
         upper(regexp_replace(PROC_CD, '\\\\.', '')) AS code
  FROM {cdm_table(config, config$tables$tbl_medical)}
  WHERE PROC_CD IS NOT NULL
),
events AS (
  SELECT * FROM dx UNION ALL SELECT * FROM proc
),
matched AS (
  SELECT /*+ BROADCAST(c) */ e.PATID, e.event_dt
  FROM events e
  JOIN {work_table(config, 'clintrial_codes')} c
    ON e.code_type = c.code_type AND e.code = c.code
)
SELECT
  i.PATID,
  max(CASE WHEN m.event_dt BETWEEN date_sub(i.index_date, {baseline_days}) AND date_sub(i.index_date, 1)
           THEN 1 ELSE 0 END) AS CLINTRIAL_BASELINE,
  max(CASE WHEN m.event_dt >= i.index_date AND m.event_dt <= date('{study_end}')
           THEN 1 ELSE 0 END) AS CLINTRIAL_FOLLOWUP
FROM idx i
LEFT JOIN matched m ON i.PATID = m.PATID
GROUP BY i.PATID
")
}

#' Generate SQL for other malignancy flag
#' @export
sql_other_malig_flag <- function(config) {
  baseline_days <- config$study$baseline_days

  glue("
CREATE OR REPLACE TABLE {work_table(config, 'other_malig_flag')} AS
WITH idx AS (
  SELECT PATID, index_date
  FROM {work_table(config, 'mm_qualifying')}
),
dx AS (
  SELECT
    d.PATID, d.CLMID, cast(d.FST_DT as date) AS event_dt,
    upper(regexp_replace(d.DIAG, '\\\\.', '')) AS dx,
    CASE WHEN upper(d.ICD_FLAG) IN ('9','ICD9','ICD-9') THEN 'ICD9' ELSE 'ICD10' END AS icd_family
  FROM {cdm_table(config, config$tables$tbl_med_diag)} d
),
dx_mapped AS (
  SELECT /*+ BROADCAST(o) */
    dx.PATID, dx.CLMID, dx.event_dt, o.tumor_group
  FROM dx
  JOIN {work_table(config, 'other_malig_dx_codes')} o
    ON dx.dx = o.dx AND dx.icd_family = o.icd_family
),
dx_nondx AS (
  SELECT m.PATID, m.tumor_group, m.event_dt
  FROM dx_mapped m
  JOIN {work_table(config, 'claim_nondiagnostic')} n
    ON m.PATID = n.PATID AND m.CLMID = n.CLMID
  WHERE n.has_nondiagnostic_line = 1
),
ordered AS (
  SELECT PATID, tumor_group, event_dt,
         lead(event_dt) OVER (PARTITION BY PATID, tumor_group ORDER BY event_dt) AS next_dt
  FROM (SELECT DISTINCT PATID, tumor_group, event_dt FROM dx_nondx)
),
pairs AS (
  SELECT PATID, tumor_group, event_dt AS first_dt, next_dt,
         datediff(next_dt, event_dt) AS diff_days
  FROM ordered WHERE next_dt IS NOT NULL
),
flagged AS (
  SELECT
    i.PATID,
    max(CASE
          WHEN p.diff_days <= 30
           AND p.first_dt BETWEEN date_sub(i.index_date, {baseline_days}) AND date_sub(i.index_date, 1)
          THEN 1 ELSE 0
        END) AS OTHER_MALIGN_FLAG
  FROM idx i
  LEFT JOIN pairs p ON i.PATID = p.PATID
  GROUP BY i.PATID
)
SELECT * FROM flagged
")
}

#' Generate SQL for final ELIG_COH with all flags
#' @export
sql_elig_coh_allflags <- function(config) {
  study_end <- config$study$study_end

  glue("
CREATE OR REPLACE TABLE {work_table(config, 'ELIG_COH_ALLFLAGS')} AS
SELECT
  q.PATID,
  q.index_date AS INDEX_DATE,
  year(q.index_date) AS INDEX_YR,
  d.GDR_CD,
  d.YRDOB,
  (year(q.index_date) - d.YRDOB) AS AGE_INDEX_YR,

  -- Diagnosis qualification flags
  q.inpt1,
  q.outpt2_30,
  q.outpt2_60,
  q.outpt2_90,
  q.index_source,

  -- Enrollment periods
  ce.baseline_start,
  ce.baseline_end,
  ce.CE_6MOS_GAP30 AS CE_b,
  ce.CE_1D_POST_INDEX_GAP30 AS CE_f,
  ce.ENDDATE_CE,

  -- Follow-up end date and days
  date('{study_end}') AS ENDDATE,
  datediff(date('{study_end}'), q.index_date) + 1 AS FU_DAYS,
  datediff(least(date('{study_end}'), coalesce(ce.ENDDATE_CE, date('{study_end}'))), q.index_date) + 1 AS FU_DAYS_CE,

  -- Therapy flags
  coalesce(th.MM_THERAPY_BASELINE, 0) AS MM_bl_agents,
  coalesce(th.MM_THERAPY_FOLLOWUP, 0) AS MM_FU_agents,

  -- Smoldering/baseline MM flag
  coalesce(mm_bl.MM_BASELINE_NONDX, 0) AS MM_baseline_diag,

  -- Exclusion flags
  coalesce(om.OTHER_MALIGN_FLAG, 0) AS OTHER_MALIGN_FLAG,
  coalesce(preg.PREGNANT_FLAG, 0) AS PREGNANT_FLAG,
  coalesce(ct.CLINTRIAL_BASELINE, 0) AS CLINTRIAL_BASELINE,
  coalesce(ct.CLINTRIAL_FOLLOWUP, 0) AS CLINTRIAL_FOLLOWUP

FROM {work_table(config, 'mm_qualifying')} q
LEFT JOIN {work_table(config, 'ce_flags')} ce ON q.PATID = ce.PATID
LEFT JOIN {work_table(config, 'member_demo')} d ON q.PATID = d.PATID
LEFT JOIN {work_table(config, 'mm_baseline_nondx_flag')} mm_bl ON q.PATID = mm_bl.PATID
LEFT JOIN {work_table(config, 'therapy_flags')} th ON q.PATID = th.PATID
LEFT JOIN {work_table(config, 'pregnancy_flag')} preg ON q.PATID = preg.PATID
LEFT JOIN {work_table(config, 'clintrial_flag')} ct ON q.PATID = ct.PATID
LEFT JOIN {work_table(config, 'other_malig_flag')} om ON q.PATID = om.PATID
")
}

#' Generate SQL for final filtered cohort
#' @export
sql_elig_coh_final <- function(config) {
  glue("
CREATE OR REPLACE TABLE {work_table(config, 'ELIG_COH_FINAL')} AS
SELECT *
FROM {work_table(config, 'ELIG_COH_ALLFLAGS')}
WHERE
  AGE_INDEX_YR >= 18
  AND CE_b = 1
  AND CE_f = 1
  AND MM_bl_agents = 0
  AND MM_FU_agents = 1
")
}

#' Optimize Delta table (optional for large tables)
#' @export
sql_optimize_table <- function(config, table_name, zorder_cols = NULL) {
  sql <- glue("OPTIMIZE {work_table(config, table_name)}")
  if (!is.null(zorder_cols) && length(zorder_cols) > 0) {
    sql <- paste0(sql, " ZORDER BY (", paste(zorder_cols, collapse = ", "), ")")
  }
  sql
}
