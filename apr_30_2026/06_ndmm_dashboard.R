#!/usr/bin/env Rscript
# NDMM dashboard entry point: keep parent reusable, then apply the
# project-specific NDMM overlay on top of the existing dashboard logic.

.wrapper_script_dir <- local({
  override <- getOption('ndmm_dashboard.script_dir', NULL)
  if (!is.null(override)) return(override)
  args <- commandArgs(trailingOnly = FALSE)
  fa <- grep('^--file=', args, value = TRUE)
  if (length(fa) > 0) return(dirname(normalizePath(sub('^--file=', '', fa[1]))))
  for (i in seq_len(sys.nframe())) {
    o <- tryCatch(sys.frame(i)$ofile, error = function(e) NULL)
    if (!is.null(o)) return(dirname(normalizePath(o)))
  }
  getwd()
})

.ndmm_wrapper_no_autorun <- isTRUE(getOption('ndmm_dashboard.no_autorun', NULL))
.ndmm_prev_no_autorun <- getOption('ndmm_dashboard.no_autorun', NULL)
.ndmm_prev_script_dir <- getOption('ndmm_dashboard.script_dir', NULL)
options(ndmm_dashboard.no_autorun = TRUE)
if (is.null(.ndmm_prev_script_dir)) options(ndmm_dashboard.script_dir = .wrapper_script_dir)
source(file.path(.wrapper_script_dir, '06_ndmm_dashboard_base.R'))
if (is.null(.ndmm_prev_no_autorun)) options(ndmm_dashboard.no_autorun = NULL) else options(ndmm_dashboard.no_autorun = .ndmm_prev_no_autorun)
if (is.null(.ndmm_prev_script_dir)) options(ndmm_dashboard.script_dir = NULL) else options(ndmm_dashboard.script_dir = .ndmm_prev_script_dir)

NDMM_STUDY_START      <- Sys.getenv('STUDY_START', unset = '2015-07-01')
NDMM_PREG_CODES       <- '_ndmm_preg_codes'
NDMM_PREGNANCY_PATIDS <- '_ndmm_pregnancy_patids'

.ndmm_table_ok <- function(con, tbl) isTRUE(tryCatch(
  nrow(db_q(con, glue('SELECT 1 FROM {tbl} LIMIT 1'))) >= 0,
  error = function(e) FALSE))

.base_build_lot1_starts_ndmm <- build_lot1_starts_ndmm

build_ndmm_preg_codes <- function(con) {
  src <- load_codelist_csv('pregnancy.csv', c('code_type', 'code'))
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_PREG_CODES} AS
    SELECT upper(trim(code_type)) AS code_type,
           upper(regexp_replace(trim(code), '[^A-Za-z0-9]', '')) AS code
    FROM {src}
    WHERE code IS NOT NULL AND trim(code) <> ''
      AND code_type IS NOT NULL AND trim(code_type) <> ''
  "))
}

build_ndmm_pregnancy_patids <- function(con, med_diag_tbl, medical_tbl, med_proc_tbl) {
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_PREGNANCY_PATIDS} AS
    WITH dx AS (
      SELECT cast(PATID as string) AS PATID,
             CASE WHEN upper(ICD_FLAG) IN ('9','ICD9','ICD-9') THEN 'ICD9DIAG' ELSE 'ICD10DIAG' END AS code_type,
             upper(regexp_replace(DIAG, '[^A-Za-z0-9]', '')) AS code
      FROM {med_diag_tbl}
      WHERE DIAG IS NOT NULL
        AND cast(FST_DT as date) BETWEEN date('{NDMM_STUDY_START}') AND date('{cfg$study_end}')
    ),
    hcpcs_proc AS (
      SELECT cast(PATID as string) AS PATID,
             'HCPCS' AS code_type,
             upper(regexp_replace(PROC_CD, '[^A-Za-z0-9]', '')) AS code
      FROM {medical_tbl}
      WHERE PROC_CD IS NOT NULL
        AND cast(FST_DT as date) BETWEEN date('{NDMM_STUDY_START}') AND date('{cfg$study_end}')
    ),
    icd_proc AS (
      SELECT cast(PATID as string) AS PATID,
             CASE WHEN upper(ICD_FLAG) IN ('9','ICD9','ICD-9') THEN 'ICD9PROC' ELSE 'ICD10PROC' END AS code_type,
             upper(regexp_replace(PROC, '[^A-Za-z0-9]', '')) AS code
      FROM {med_proc_tbl}
      WHERE PROC IS NOT NULL
        AND cast(FST_DT as date) BETWEEN date('{NDMM_STUDY_START}') AND date('{cfg$study_end}')
    ),
    rev AS (
      SELECT cast(PATID as string) AS PATID,
             'REV' AS code_type,
             upper(trim(RVNU_CD)) AS code
      FROM {medical_tbl}
      WHERE RVNU_CD IS NOT NULL AND trim(RVNU_CD) <> ''
        AND cast(FST_DT as date) BETWEEN date('{NDMM_STUDY_START}') AND date('{cfg$study_end}')
    ),
    events AS (
      SELECT * FROM dx UNION ALL SELECT * FROM hcpcs_proc
      UNION ALL SELECT * FROM icd_proc UNION ALL SELECT * FROM rev
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

build_lot1_starts_ndmm <- function(con, lot_long) {
  .base_build_lot1_starts_ndmm(con, lot_long)
  med_diag_tbl <- cdm_src(cfg$tbl_med_diag)
  medical_tbl  <- cdm_src(cfg$tbl_medical)
  med_proc_tbl <- cdm_src(cfg$tbl_med_proc)
  if (.ndmm_table_ok(con, med_diag_tbl) && .ndmm_table_ok(con, medical_tbl) && .ndmm_table_ok(con, med_proc_tbl)) {
    log_msg('Loading pregnancy codelist -> ', NDMM_PREG_CODES)
    build_ndmm_preg_codes(con)
    log_msg('Scanning pregnancy claims in [', NDMM_STUDY_START, ', ', cfg$study_end, '] -> ', NDMM_PREGNANCY_PATIDS)
    build_ndmm_pregnancy_patids(con, med_diag_tbl, medical_tbl, med_proc_tbl)
  } else {
    log_msg('  WARN: pregnancy exclusion skipped; med_diagnosis, medical, or med_procedure unreadable.')
  }
}

build_ndmm_flags <- function(con, elig_coh_final, map_stacked,
                             q2_ok_belantamab, q2_ok_priortx,
                             q2_ok_othercancer, q2_ok_pregnancy = NULL) {
  if (is.null(q2_ok_pregnancy)) q2_ok_pregnancy <- .ndmm_table_ok(con, NDMM_PREGNANCY_PATIDS)
  bela_expr <- if (q2_ok_belantamab) glue("SELECT DISTINCT cast(PATID as string) AS PATID FROM {map_stacked} WHERE upper(MAP_MED_TYPE) LIKE 'BEL%'") else 'SELECT cast(NULL as string) AS PATID WHERE 1 = 0'
  prior_tx_expr <- if (q2_ok_priortx) glue("SELECT DISTINCT PATID FROM {NDMM_THERAPY_PRE_LOT1}") else 'SELECT cast(NULL as string) AS PATID WHERE 1 = 0'
  other_cancer_expr <- if (q2_ok_othercancer) glue("SELECT DISTINCT cast(PATID as string) AS PATID FROM {NDMM_OTHER_MALIG_PATIDS}") else 'SELECT cast(NULL as string) AS PATID WHERE 1 = 0'
  pregnancy_expr <- if (q2_ok_pregnancy) glue("SELECT DISTINCT cast(PATID as string) AS PATID FROM {NDMM_PREGNANCY_PATIDS}") else 'SELECT cast(NULL as string) AS PATID WHERE 1 = 0'

  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_FLAGS_ALL} AS
    WITH ec_l1 AS (
      SELECT cast(ec.PATID as string) AS PATID, l1.LOT1_START_DT,
             date_sub(l1.LOT1_START_DT, {NDMM_PRE_LOT1_DAYS}) AS pre_lot1_start,
             date_sub(l1.LOT1_START_DT, 1) AS pre_lot1_end,
             cast(ec.DEATH_DT as date) AS DEATH_DT
      FROM {elig_coh_final} ec
      INNER JOIN {NDMM_LOT1_STARTS} l1 ON cast(ec.PATID as string) = l1.PATID
    ),
    ce AS (
      SELECT ec_l1.PATID,
             max(CASE WHEN s.cov_start <= ec_l1.pre_lot1_start AND s.cov_end >= ec_l1.pre_lot1_end THEN 1 ELSE 0 END) AS CE_pre_lot1_12mo
      FROM ec_l1 LEFT JOIN {NDMM_ENROLL_SPANS} s ON s.PATID = ec_l1.PATID
      GROUP BY ec_l1.PATID
    ),
    fuce AS (
      SELECT ec_l1.PATID,
             max(CASE WHEN s.cov_start <= ec_l1.LOT1_START_DT
                       AND s.cov_end >= least(date_add(ec_l1.LOT1_START_DT, 90), date('{cfg$study_end}'), coalesce(ec_l1.DEATH_DT, date('{cfg$study_end}')))
                      THEN 1 ELSE 0 END) AS CE_lot1_3mo
      FROM ec_l1 LEFT JOIN {NDMM_ENROLL_SPANS_STRICT} s ON s.PATID = ec_l1.PATID
      GROUP BY ec_l1.PATID
    ),
    bela AS ({bela_expr}), prior_tx AS ({prior_tx_expr}),
    other_cancer AS ({other_cancer_expr}), pregnancy AS ({pregnancy_expr})
    SELECT ec_l1.PATID,
           ce.CE_pre_lot1_12mo,
           coalesce(fuce.CE_lot1_3mo, 0) AS CE_lot1_3mo_fu,
           CASE WHEN bela.PATID IS NULL THEN 1 ELSE 0 END AS NO_BELANTAMAB,
           CASE WHEN prior_tx.PATID IS NULL THEN 1 ELSE 0 END AS NO_PRIOR_MM_TX,
           CASE WHEN other_cancer.PATID IS NULL THEN 1 ELSE 0 END AS NO_OTHER_CANCER_PRE_LOT1,
           CASE WHEN pregnancy.PATID IS NULL THEN 1 ELSE 0 END AS NO_PREGNANCY
    FROM ec_l1
    LEFT JOIN ce ON ec_l1.PATID = ce.PATID
    LEFT JOIN fuce ON ec_l1.PATID = fuce.PATID
    LEFT JOIN bela ON ec_l1.PATID = bela.PATID
    LEFT JOIN prior_tx ON ec_l1.PATID = prior_tx.PATID
    LEFT JOIN other_cancer ON ec_l1.PATID = other_cancer.PATID
    LEFT JOIN pregnancy ON ec_l1.PATID = pregnancy.PATID
  "))

  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_PATIDS} AS
    SELECT PATID FROM {NDMM_FLAGS_ALL}
    WHERE CE_pre_lot1_12mo = 1 AND NO_BELANTAMAB = 1
      AND NO_PRIOR_MM_TX = 1 AND NO_OTHER_CANCER_PRE_LOT1 = 1
      AND CE_lot1_3mo_fu = 1 AND NO_PREGNANCY = 1
  "))
}

build_ndmm_overview_card <- function(counts, n_ster_codes, n_cat_rules,
                                     notes = list(), section = 'OVERVIEW',
                                     title = 'What this dashboard shows') {
  pct <- function(num, den) if (den > 0) sprintf('%.1f%%', 100 * num / den) else '-'
  row <- function(label, n, bold = FALSE, bg = '') {
    open <- if (bold) '<b>' else ''; close <- if (bold) '</b>' else ''
    bgsty <- if (nzchar(bg)) paste0(' style="background:', bg, '"') else ''
    paste0('<tr', bgsty, '><td style="padding:6px 12px">', open, label, close, '</td>',
           '<td style="text-align:right;padding:6px 12px">', open, format(n, big.mark = ','), close, '</td>',
           '<td style="text-align:right;padding:6px 12px">', open, pct(n, counts$whole), close, '</td></tr>')
  }
  notes_html <- if (length(notes)) paste0('<p style="color:#a06000;font-size:12px;margin-top:8px"><b>Notes:</b> ', paste(notes, collapse = ' '), '</p>') else ''
  add_html_card(paste0(
    ndc_missing_banner(),
    '<div style="font-family:system-ui;padding:14px;max-width:900px">',
    '<h3>NDMM (1L newly-diagnosed) planned cohort</h3>',
    '<p style="color:#555;font-size:13px">Parent/Overall remains this project&apos;s Step-6 denominator via <code>pipeline_inputs.csv</code>. NDMM then applies the spec filters at the correct anchors: LOT1 for CE / prior therapy / other cancer, any LOT for belantamab, and the study period for pregnancy.</p>',
    '<table style="font-size:13px;border-collapse:collapse;margin-top:8px">',
    '<tr style="background:#eef"><th style="text-align:left;padding:6px 12px">Filter step</th><th style="text-align:right;padding:6px 12px">n patients</th><th style="text-align:right;padding:6px 12px">% of whole</th></tr>',
    row('Whole LOT_LONG cohort', counts$whole),
    row('+ in ELIG_COH_FINAL (project Step-6 parent/Overall)', counts$elig),
    row(paste0('+ has LOT1 start &ge; ', NDMM_LOT1_FROM, ' in LOT_LONG'), counts$elig_lot1),
    row('+ 12-mo CE pre-LOT1', counts$ce12),
    row('+ no belantamab in any LOT', counts$ce12_nobela),
    row('+ no MM oncology Tx in 12-mo pre-LOT1', counts$ce12_nobela_nopriortx),
    row('+ no other active cancer in 12-mo pre-LOT1', counts$noother),
    row('+ 3-mo follow-up CE (from LOT1)', counts$noother_fuce),
    row('+ no pregnancy during study period (NDMM final)', counts$ndmm_final, bold = TRUE, bg = '#efe'),
    '</table>', notes_html,
    '<ul style="font-size:13px;color:#1a7a3a;margin-top:10px"><li><b>Category transitions</b>: regimen-category Sankeys per LOT pair (', n_cat_rules, ' regimen rules loaded).</li><li><b>Steroid prevalence</b>: steroid tokens appended to <code>LOT_BASE_MEDS</code> inside the parent induction window (', n_ster_codes, ' codes loaded; <code>SCT_ALLO</code>-started LOTs suppressed).</li><li><b>Progressor flows</b>: non-progressors dropped (inner-join LOTn &rarr; LOTn+1).</li></ul></div>'),
    section = section, title = title)
}

if (!interactive() && !.ndmm_wrapper_no_autorun) main_ndmm()
