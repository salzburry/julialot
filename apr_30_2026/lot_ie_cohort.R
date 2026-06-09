#!/usr/bin/env Rscript
# Apply Julia's June 5 IE criteria to the delivered cohort WITHOUT
# editing any existing pipeline program.
#
#   Rscript lot_ie_cohort.R
#
# Materialises a thin work-schema VIEW (IE_COHORT_PATIDS by default;
# overridable via IE_COHORT_VIEW) holding the PATIDs that pass:
#
#   1. 1L treatment start (LOT_LONG.LOT_START_DT at LOT_NUM=1)
#      >= 2017-01-01.
#   2. No belantamab exposure anywhere - excluded if the token
#      appears in LOT_BASE_MEDS at any LOT_NUM OR in
#      MAP_STACKED.MAP_MED_TYPE (true any-exposure).
#   3. Continuous enrolment >= 12 months before 1L start, allowing
#      gaps of <= 30 days (matches pipeline_steps.R:386-419 logic).
#   4. Continuous enrolment >= 6 months before MM diagnosis date
#      (ELIG_COH_FINAL.INDEX_DATE = MM-dx qualifying date per
#      pipeline_steps.R:356), allowing the same 30-day gap.
#
# All thresholds are env-overridable: CE_PRE_LOT1_DAYS (365),
# CE_PRE_MM_DX_DAYS (183), CE_GAP_DAYS (30), ELIGIBLE_1L_FROM
# (2017-01-01), BELANTAMAB_MED_ABBR (BELA).
#
# The IE cohort view is self-contained (a single CREATE OR REPLACE
# VIEW with the gap-allowing enrollment-span CTE inlined), so other
# scripts can join to it across sessions without setting anything up.
#
# Q2 steroid placeholder: Julia said she is updating the LOT rules
# to include steroids ("J8540 / J7512 / J1100 / J1101 plus quite a
# few NDC codes"). Actually adding steroids to LOT_BASE_MEDS needs
# a pipeline change, which is out of scope here. This script keeps
# a clearly-marked NDC placeholder block; when she ships the full
# list, drop the codes into STEROID_NDC_INLINE below (or a CSV
# pointed to by STEROID_NDC_CSV) and rerun. The script then
# reports steroid exposure counts for the IE cohort (informational
# only - LOT regimens are unchanged until the pipeline rebuild).

.script_dir <- local({
  args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", args, value = TRUE)
  if (length(file_arg) > 0) {
    return(dirname(normalizePath(sub("^--file=", "", file_arg[1]))))
  }
  for (i in seq_len(sys.nframe())) {
    ofile <- tryCatch(sys.frame(i)$ofile, error = function(e) NULL)
    if (!is.null(ofile)) return(dirname(normalizePath(ofile)))
  }
  getwd()
})

source_dir <- file.path(.script_dir, "R")
if (file.exists(file.path(source_dir, "load_inputs.R"))) {
  source(file.path(source_dir, "load_inputs.R"))
  load_pipeline_inputs(c(.script_dir, dirname(.script_dir)))
}
source(file.path(source_dir, "config_lot.R"))
source(file.path(source_dir, "db_utils_lot.R"))

VIEW_BASE        <- Sys.getenv("IE_COHORT_VIEW",      unset = "IE_COHORT_PATIDS")
ELIG_1L_FROM     <- Sys.getenv("ELIGIBLE_1L_FROM",    unset = "2017-01-01")
BELA_TOKEN       <- Sys.getenv("BELANTAMAB_MED_ABBR", unset = "BELA")
PRE_LOT_DAYS     <- as.integer(Sys.getenv("CE_PRE_LOT1_DAYS",  unset = "365"))
PRE_MM_DAYS      <- as.integer(Sys.getenv("CE_PRE_MM_DX_DAYS", unset = "183"))
GAP_DAYS         <- as.integer(Sys.getenv("CE_GAP_DAYS",       unset = "30"))
ENR_TBL_NAME     <- Sys.getenv("MEMBER_ENROLLMENT_TBL",
                                unset = "member_enrollment")
if (anyNA(c(PRE_LOT_DAYS, PRE_MM_DAYS, GAP_DAYS)))
  stop("CE_PRE_LOT1_DAYS / CE_PRE_MM_DX_DAYS / CE_GAP_DAYS must be integers.")

# -------- Steroid Q2 placeholder ------------------------------------
# Julia June 5 PDF, item 2: HCPCS codes she listed (OCR-confirmed).
# Inline-edit STEROID_NDC_INLINE below to add NDC codes (or supply
# them via STEROID_NDC_CSV). Until the NDCs land the script just
# documents the placeholder; once populated it reports IE-cohort
# steroid-exposure counts from MMA_MED_PROCESSED (informational).
STEROID_HCPCS <- c("J8540", "J7512", "J1100", "J1101")

# ------- DROP NDC CODES HERE WHEN JULIA SHIPS THEM -------
# Replace character(0) with a character vector of NDC strings, e.g.:
#   STEROID_NDC_INLINE <- c("00054818025", "00054423025", "00781511595")
STEROID_NDC_INLINE <- character(0)
# ---------------------------------------------------------

STEROID_NDC_CSV <- Sys.getenv("STEROID_NDC_CSV", unset = "")

read_steroid_ndcs <- function() {
  ndcs <- STEROID_NDC_INLINE
  if (nzchar(STEROID_NDC_CSV) && file.exists(STEROID_NDC_CSV)) {
    df <- tryCatch(read.csv(STEROID_NDC_CSV, stringsAsFactors = FALSE,
                            check.names = FALSE),
                   error = function(e) NULL)
    if (!is.null(df) && nrow(df) > 0) {
      col <- which(tolower(names(df)) %in%
                    c("ndc", "ndc_code", "code", "value"))[1]
      if (!is.na(col)) {
        ndcs <- unique(c(ndcs, trimws(as.character(df[[col]]))))
        log_msg("Loaded ", length(ndcs), " steroid NDCs (HCPCS + CSV)")
      } else {
        log_msg("STEROID_NDC_CSV has no recognised NDC/code column; ",
                "ignoring (found cols: ", paste(names(df), collapse = ", "),
                ")")
      }
    }
  }
  ndcs <- unique(ndcs[nzchar(ndcs)])
  ndcs
}

main <- function() {
  stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")
  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn,
                        pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  lot_long  <- wrk("LOT_LONG")
  final_tbl <- wrk(cfg$input_cohort_table)
  map_tbl   <- wrk("MAP_STACKED")
  proc_tbl  <- wrk("MMA_MED_PROCESSED")
  enr_tbl   <- cdm_src(ENR_TBL_NAME)
  view_name <- wrk(VIEW_BASE)

  ok <- function(tbl) isTRUE(tryCatch(
    nrow(db_q(con, glue("SELECT 1 FROM {tbl} LIMIT 1"))) >= 0,
    error = function(e) FALSE))
  for (t in c(lot_long, final_tbl, enr_tbl)) {
    if (!ok(t)) stop("Cannot read ", t,
                     " (run the pipeline first or check env vars).")
  }
  have_map <- ok(map_tbl)

  # ---- IE cohort view (single self-contained CTE chain) -------------
  bela_map_branch <- if (have_map) glue("
        UNION ALL
        SELECT DISTINCT cast(PATID as string) AS PATID
        FROM {map_tbl}
        WHERE upper(MAP_MED_TYPE) = upper('{BELA_TOKEN}')") else ""

  ie_sql <- glue("
    CREATE OR REPLACE VIEW {view_name} AS
    WITH
    enr_base AS (
      SELECT cast(PATID as string) AS PATID,
             cast(ELIGEFF as date) AS elig_eff,
             cast(ELIGEND as date) AS elig_end
      FROM {enr_tbl}
      WHERE ELIGEFF IS NOT NULL AND ELIGEND IS NOT NULL
    ),
    enr_ordered AS (
      SELECT PATID, elig_eff, elig_end,
        max(elig_end) OVER (PARTITION BY PATID
                            ORDER BY elig_eff, elig_end
                            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)
        AS max_end_so_far
      FROM enr_base
    ),
    enr_flagged AS (
      SELECT PATID, elig_eff, elig_end,
        CASE WHEN max_end_so_far IS NULL THEN 1
             WHEN elig_eff <= date_add(max_end_so_far, {GAP_DAYS} + 1) THEN 0
             ELSE 1 END AS new_grp
      FROM enr_ordered
    ),
    enr_grouped AS (
      SELECT PATID, elig_eff, elig_end,
        sum(new_grp) OVER (PARTITION BY PATID ORDER BY elig_eff, elig_end
                           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
        AS grp_id
      FROM enr_flagged
    ),
    enr_spans AS (
      SELECT PATID, min(elig_eff) AS cov_start, max(elig_end) AS cov_end
      FROM enr_grouped GROUP BY PATID, grp_id
    ),
    lot1 AS (
      SELECT cast(PATID as string) AS PATID, LOT_START_DT AS LOT1_DT
      FROM {lot_long}
      WHERE LOT_NUM = 1 AND LOT_START_DT IS NOT NULL
    ),
    mm_dx AS (
      SELECT cast(PATID as string) AS PATID,
             cast(INDEX_DATE as date) AS MM_DX_DT
      FROM {final_tbl}
    ),
    bela AS (
      SELECT DISTINCT PATID FROM (
        SELECT cast(PATID as string) AS PATID
        FROM {lot_long}
        WHERE LOT_BASE_MEDS IS NOT NULL
          AND array_contains(split(LOT_BASE_MEDS, ' '), '{BELA_TOKEN}')
        {bela_map_branch}
      )
    ),
    candidates AS (
      SELECT l.PATID, l.LOT1_DT, m.MM_DX_DT,
             date_sub(l.LOT1_DT, {PRE_LOT_DAYS}) AS w1_start,
             date_sub(l.LOT1_DT, 1)              AS w1_end,
             date_sub(m.MM_DX_DT, {PRE_MM_DAYS}) AS w2_start,
             date_sub(m.MM_DX_DT, 1)             AS w2_end
      FROM lot1 l
      JOIN mm_dx m ON l.PATID = m.PATID
      LEFT JOIN bela x ON x.PATID = l.PATID
      WHERE l.LOT1_DT >= cast('{ELIG_1L_FROM}' as date)
        AND x.PATID IS NULL
    ),
    ce_pre_lot1 AS (
      SELECT DISTINCT c.PATID
      FROM candidates c
      JOIN enr_spans s ON s.PATID = c.PATID
      WHERE s.cov_start <= c.w1_start AND s.cov_end >= c.w1_end
    ),
    ce_pre_mm_dx AS (
      SELECT DISTINCT c.PATID
      FROM candidates c
      JOIN enr_spans s ON s.PATID = c.PATID
      WHERE s.cov_start <= c.w2_start AND s.cov_end >= c.w2_end
    )
    SELECT c.PATID
    FROM candidates c
    JOIN ce_pre_lot1  pl ON pl.PATID = c.PATID
    JOIN ce_pre_mm_dx pm ON pm.PATID = c.PATID
  ")
  log_msg("Building IE cohort view ", view_name)
  db_exec(con, ie_sql)

  # ---- Attrition log ------------------------------------------------
  # Re-run the CTE counts so the user can see how each criterion
  # whittles the cohort down. Cheap (single SQL).
  log_msg("IE cohort criteria summary:")
  attr_df <- db_q(con, glue("
    WITH enr_base AS (
      SELECT cast(PATID as string) AS PATID,
             cast(ELIGEFF as date) AS elig_eff,
             cast(ELIGEND as date) AS elig_end
      FROM {enr_tbl}
      WHERE ELIGEFF IS NOT NULL AND ELIGEND IS NOT NULL
    ),
    enr_ordered AS (
      SELECT PATID, elig_eff, elig_end,
        max(elig_end) OVER (PARTITION BY PATID
                            ORDER BY elig_eff, elig_end
                            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)
        AS max_end_so_far
      FROM enr_base
    ),
    enr_flagged AS (
      SELECT PATID, elig_eff, elig_end,
        CASE WHEN max_end_so_far IS NULL THEN 1
             WHEN elig_eff <= date_add(max_end_so_far, {GAP_DAYS} + 1) THEN 0
             ELSE 1 END AS new_grp
      FROM enr_ordered
    ),
    enr_grouped AS (
      SELECT PATID, elig_eff, elig_end,
        sum(new_grp) OVER (PARTITION BY PATID ORDER BY elig_eff, elig_end
                           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
        AS grp_id
      FROM enr_flagged
    ),
    enr_spans AS (
      SELECT PATID, min(elig_eff) AS cov_start, max(elig_end) AS cov_end
      FROM enr_grouped GROUP BY PATID, grp_id
    ),
    lot1 AS (
      SELECT cast(PATID as string) AS PATID, LOT_START_DT AS LOT1_DT
      FROM {lot_long}
      WHERE LOT_NUM = 1 AND LOT_START_DT IS NOT NULL
    ),
    mm_dx AS (
      SELECT cast(PATID as string) AS PATID,
             cast(INDEX_DATE as date) AS MM_DX_DT
      FROM {final_tbl}
    ),
    bela AS (
      SELECT DISTINCT PATID FROM (
        SELECT cast(PATID as string) AS PATID
        FROM {lot_long}
        WHERE LOT_BASE_MEDS IS NOT NULL
          AND array_contains(split(LOT_BASE_MEDS, ' '), '{BELA_TOKEN}')
        {bela_map_branch}
      )
    ),
    n_total      AS (SELECT count(DISTINCT PATID) AS n FROM lot1),
    n_dt_pass    AS (SELECT count(DISTINCT PATID) AS n FROM lot1
                     WHERE LOT1_DT >= cast('{ELIG_1L_FROM}' as date)),
    n_no_bela    AS (SELECT count(DISTINCT l.PATID) AS n
                     FROM lot1 l
                     LEFT JOIN bela x ON x.PATID = l.PATID
                     WHERE l.LOT1_DT >= cast('{ELIG_1L_FROM}' as date)
                       AND x.PATID IS NULL),
    n_with_ce_lot1 AS (
      SELECT count(DISTINCT l.PATID) AS n
      FROM lot1 l
      LEFT JOIN bela x ON x.PATID = l.PATID
      JOIN enr_spans s ON s.PATID = l.PATID
      WHERE l.LOT1_DT >= cast('{ELIG_1L_FROM}' as date)
        AND x.PATID IS NULL
        AND s.cov_start <= date_sub(l.LOT1_DT, {PRE_LOT_DAYS})
        AND s.cov_end   >= date_sub(l.LOT1_DT, 1)
    ),
    n_final AS (SELECT count(DISTINCT PATID) AS n FROM {view_name})
    SELECT (SELECT n FROM n_total)        AS n_lot1_total,
           (SELECT n FROM n_dt_pass)      AS n_1l_from_2017,
           (SELECT n FROM n_no_bela)      AS n_no_belantamab,
           (SELECT n FROM n_with_ce_lot1) AS n_with_ce_pre_lot1,
           (SELECT n FROM n_final)        AS n_ie_cohort
  "))
  num <- function(x) suppressWarnings(as.numeric(x))
  log_msg(sprintf("  LOT1 total (delivered)            : %s",
                  format(num(attr_df$n_lot1_total[1]),       big.mark = ",")))
  log_msg(sprintf("  + 1L start >= %s             : %s",
                  ELIG_1L_FROM,
                  format(num(attr_df$n_1l_from_2017[1]),     big.mark = ",")))
  log_msg(sprintf("  + no belantamab exposure          : %s",
                  format(num(attr_df$n_no_belantamab[1]),    big.mark = ",")))
  log_msg(sprintf("  + CE >= %s d pre-LOT1 (gap<=%s d)  : %s",
                  PRE_LOT_DAYS, GAP_DAYS,
                  format(num(attr_df$n_with_ce_pre_lot1[1]), big.mark = ",")))
  log_msg(sprintf("  + CE >= %s d pre-MM-dx (gap<=%s d) : %s  <- IE cohort",
                  PRE_MM_DAYS, GAP_DAYS,
                  format(num(attr_df$n_ie_cohort[1]),        big.mark = ",")))

  # ---- Q2 steroid Q2 placeholder / report ---------------------------
  ndcs <- read_steroid_ndcs()
  if (length(ndcs) == 0 && length(STEROID_NDC_INLINE) == 0
      && !nzchar(STEROID_NDC_CSV)) {
    log_msg(
      "Q2 steroid placeholder: HCPCS codes from Julia's June 5 PDF ",
      "documented (", paste(STEROID_HCPCS, collapse = ", "),
      "). NDC codes not yet provided - drop them into ",
      "STEROID_NDC_INLINE in this script or set STEROID_NDC_CSV. ",
      "Adding steroids to LOT_BASE_MEDS itself is a pipeline change ",
      "and stays out of scope here.")
    return(invisible())
  }
  if (!ok(proc_tbl)) {
    log_msg("Q2 steroid count skipped - ", proc_tbl, " not readable.")
    return(invisible())
  }
  hcpcs_in <- paste(sprintf("'%s'", STEROID_HCPCS), collapse = ", ")
  ndc_in   <- if (length(ndcs) > 0)
    paste(sprintf("'%s'", gsub("'", "''", ndcs)), collapse = ", ") else "''"
  steroid_q <- glue("
    SELECT count(DISTINCT p.PATID) AS n_ie_patients,
           count(DISTINCT CASE WHEN p.CODE_TYPE = 'HCPCS'
                                AND p.CODE IN ({hcpcs_in})
                               THEN p.PATID END) AS n_with_steroid_hcpcs,
           count(DISTINCT CASE WHEN p.CODE_TYPE = 'NDC'
                                AND p.CODE IN ({ndc_in})
                               THEN p.PATID END) AS n_with_steroid_ndc,
           count(DISTINCT CASE WHEN (p.CODE_TYPE = 'HCPCS'
                                     AND p.CODE IN ({hcpcs_in}))
                                 OR (p.CODE_TYPE = 'NDC'
                                     AND p.CODE IN ({ndc_in}))
                               THEN p.PATID END) AS n_with_steroid_any
    FROM {proc_tbl} p
    JOIN {view_name} i ON cast(p.PATID as string) = i.PATID
  ")
  st <- tryCatch(db_q(con, steroid_q), error = function(e) NULL)
  if (is.null(st)) {
    log_msg("Q2 steroid count failed - MMA_MED_PROCESSED may not ",
            "carry CODE/CODE_TYPE in this build; check the schema.")
  } else {
    log_msg(sprintf(
      "Q2 steroid exposure in IE cohort | HCPCS=%s | NDC=%s | any=%s of %s",
      format(num(st$n_with_steroid_hcpcs[1]), big.mark = ","),
      format(num(st$n_with_steroid_ndc[1]),   big.mark = ","),
      format(num(st$n_with_steroid_any[1]),   big.mark = ","),
      format(num(st$n_ie_patients[1]),        big.mark = ",")))
    log_msg("NOTE: informational only - LOT_BASE_MEDS is unchanged ",
            "until the pipeline rebuild that folds steroids in.")
  }
}

if (!interactive()) main()
