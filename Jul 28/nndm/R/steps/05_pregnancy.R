# Pregnancy or childbirth anywhere in the study period.
#

build_ndmm_preg_codes <- function(con) {
  src <- load_codelist_csv("pregnancy.csv", c("code_type", "code"))
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_PREG_CODES} AS
    SELECT upper(trim(code_type)) AS code_type,
           upper(regexp_replace(trim(code), '[^A-Za-z0-9]', '')) AS code
    FROM {src}
    WHERE code IS NOT NULL AND trim(code) <> ''
      AND code_type IS NOT NULL AND trim(code_type) <> ''
      -- Blank after normalising too, or a punctuation-only row matches every
      -- claim whose code is missing. See 03_prior_therapy.R.
      AND regexp_replace(trim(code), '[^A-Za-z0-9]', '') <> ''
  "))
}

# Distinct NDMM-candidate PATIDs with a pregnancy/childbirth claim (dx,
# HCPCS / ICD procedure, or revenue code) anywhere in the study period.
# Restricted to NDMM LOT1 candidates up front in each source (and again by
# the trailing INNER JOIN) so the UNION / de-dupe / codelist-join work runs
# on cohort claims only. This is logical row pruning - Spark may still
# physically scan source partitions before the join, depending on layout/
# stats - not a guaranteed I/O reduction.
build_ndmm_pregnancy_patids <- function(con, med_diag_tbl, medical_tbl, med_proc_tbl) {
  # Two scheduling-only optimisations (the matched PATID set is identical):
  #   1) Restrict every source to NDMM LOT1 candidates UP FRONT (INNER JOIN
  #      NDMM_LOT1_STARTS) instead of only at the very end. The output is
  #      DISTINCT PATID intersected with NDMM_LOT1_STARTS either way, so the
  #      early join only prunes claims that the trailing join would drop
  #      anyway. The trailing join is kept as a belt-and-braces no-op so the
  #      result stays cohort-restricted even if a future source arm forgets
  #      the push-down.
  #   2) Scan the large `medical` table ONCE: stack() emits its HCPCS
  #      (PROC_CD) and REV (RVNU_CD) rows in a single pass instead of two
  #      separate scans. The per-arm CASE reproduces the original inclusion
  #      rules exactly - HCPCS keeps a blank-after-clean code (only PROC_CD
  #      IS NOT NULL was required), REV drops blanks (trim(RVNU_CD) <> '') -
  #      and a blank code never matches a real pregnancy code, so the matched
  #      PATIDs are unchanged.
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_PREGNANCY_PATIDS} AS
    WITH dx AS (
      SELECT cast(d.PATID as string) AS PATID,
             CASE WHEN upper(d.ICD_FLAG) IN ('9','ICD9','ICD-9') THEN 'ICD9DIAG' ELSE 'ICD10DIAG' END AS code_type,
             upper(regexp_replace(d.DIAG, '[^A-Za-z0-9]', '')) AS code
      FROM {med_diag_tbl} d
      INNER JOIN {NDMM_LOT1_STARTS} l1 ON cast(d.PATID as string) = l1.PATID
      WHERE d.DIAG IS NOT NULL
        AND cast(d.FST_DT as date) BETWEEN date('{NDMM_STUDY_START}') AND date('{cfg$study_end}')
    ),
    med AS (
      SELECT s.PATID, t.code_type, t.code
      FROM (
        SELECT cast(m.PATID as string) AS PATID, m.PROC_CD, m.RVNU_CD
        FROM {medical_tbl} m
        INNER JOIN {NDMM_LOT1_STARTS} l1 ON cast(m.PATID as string) = l1.PATID
        WHERE cast(m.FST_DT as date) BETWEEN date('{NDMM_STUDY_START}') AND date('{cfg$study_end}')
      ) s
      LATERAL VIEW stack(2,
        'HCPCS', CASE WHEN s.PROC_CD IS NOT NULL
                      THEN upper(regexp_replace(s.PROC_CD, '[^A-Za-z0-9]', '')) END,
        'REV',   CASE WHEN s.RVNU_CD IS NOT NULL AND trim(s.RVNU_CD) <> ''
                      THEN upper(trim(s.RVNU_CD)) END
      ) t AS code_type, code
      WHERE t.code IS NOT NULL
    ),
    icd_proc AS (
      SELECT cast(p.PATID as string) AS PATID,
             CASE WHEN upper(p.ICD_FLAG) IN ('9','ICD9','ICD-9') THEN 'ICD9PROC' ELSE 'ICD10PROC' END AS code_type,
             upper(regexp_replace(p.PROC, '[^A-Za-z0-9]', '')) AS code
      FROM {med_proc_tbl} p
      INNER JOIN {NDMM_LOT1_STARTS} l1 ON cast(p.PATID as string) = l1.PATID
      WHERE p.PROC IS NOT NULL
        AND cast(p.FST_DT as date) BETWEEN date('{NDMM_STUDY_START}') AND date('{cfg$study_end}')
    ),
    events AS (
      SELECT * FROM dx
      UNION ALL SELECT * FROM med
      UNION ALL SELECT * FROM icd_proc
    ),
    matched AS (
      SELECT DISTINCT e.PATID
      FROM events e
      INNER JOIN {NDMM_PREG_CODES} p
              ON e.code_type = p.code_type AND e.code = p.code
    )
    SELECT DISTINCT m.PATID
    FROM matched m
    INNER JOIN {NDMM_LOT1_STARTS} l1 ON m.PATID = l1.PATID
  "))
}
