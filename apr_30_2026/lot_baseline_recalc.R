#!/usr/bin/env Rscript
# Baseline-window recalc helper - apply Julia's 12-mo-pre-LOT1 window to
# the three pipeline baseline-exclusion flags WITHOUT editing the
# pipeline. Materialises a thin work-schema view BASELINE_FLAGS_LOT1
# with per-patient recomputed flags:
#
#   PATID
#   OTHER_MALIGN_FLAG_LOT1    1 if >=1 IP or >=2 OP-within-30d cancer
#                              dx (other than MM) in [LOT1-bsl, LOT1-1]
#                              for ANY tumor group in cl_other_malig.
#   PREGNANT_FLAG_LOT1        1 if >=1 pregnancy event (DX / HCPCS /
#                              ICD-PROC / RVNU_CD) in same window.
#   MM_BL_THERAPY_FLAG_LOT1   1 if >=1 MM ONCOLOGY THERAPY event
#                              (rx NDC OR medical-claim HCPCS) matches
#                              the MMA codelist in same window. Note:
#                              MM diagnosis events (203.0x / C90.0x)
#                              are NOT used - Julia's IE row is about
#                              prior treatment exposure, not prior
#                              diagnosis. Matches pipeline_steps.R
#                              MM_THERAPY_BASELINE step (line 703).
#   ANY_BASELINE_EXCL_LOT1    OR of the three flags.
#
# The pipeline currently computes these against the 183-day window
# anchored to MM-dx INDEX_DATE (pipeline_steps.R: 17_mm_baseline_evidence_flag,
# 20_pregnancy_flag, 22_other_malig_flag). Julia's June 5 IE criteria
# want them against the 12-month window pre-LOT1 start, so a patient
# is excluded only if they had the offending event in the year before
# their first MM treatment - not in the half-year before their MM dx.
#
# Run AFTER the parent pipeline so MM_DX_EVENTS_ALL is persisted:
#   Rscript apr_30_2026/lot_baseline_recalc.R
#
# Defaults: BSL_DAYS=365, GAP/IP-OP rules identical to pipeline. Knobs:
#   BSL_DAYS_LOT1, CODELIST_DIR (parent of cl_other_malig / cl_preg /
#   cl_mma_codelist CSVs), MEDICAL_TBL / MED_DIAG_TBL / MED_PROC_TBL /
#   RX_TBL (override if your CDM uses non-default names).
#
# IMPORTANT scope notes:
#   - Setting classification (IP vs OP) is derived inline from
#     medical.POS / TOS_CD only. The pipeline's other_malig step also
#     consults a `confinement` temp view; that view is not persisted
#     and we do not rebuild it here. The effect is a SMALL
#     under-detection of IP claims (claims with confinement records
#     but no POS / TOS hit). Document and accept; if material, run
#     the helper inside a pipeline session where `confinement` exists.
#   - MM-baseline-therapy is rebuilt INLINE here (mm_dx_events_all is
#     a temp view per pipeline_steps.R:208, NOT persisted, so reading
#     it across sessions would fail). The inline CTE replicates the
#     STRICT MM-dx detection from pipeline_steps.R:204-258 (any
#     med_diagnosis row whose normalised code starts with 2030
#     [ICD-9] or C900 [ICD-10]).
#   - Cancer dx must NOT be an MM code (203.0x / C90.0x). The
#     cl_other_malig codelist already encodes this exclusion in the
#     pipeline. We rely on the same codelist here.
#   - The IP/OP setting derivation pre-aggregates the `medical` table
#     to claim grain (matches pipeline step 07a's
#     `max(POS), max(TOS_CD)` GROUP BY on the 5-column claim key).
#     Without this pre-aggregation a multi-line claim Cartesian-
#     explodes the dx-event rows and the outpatient-pair logic
#     fabricates false 30-day pairs from duplicates of the same
#     physical claim.

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

VIEW_BASE     <- Sys.getenv("BASELINE_FLAGS_VIEW", unset = "BASELINE_FLAGS_LOT1")
BSL_DAYS      <- as.integer(Sys.getenv("BSL_DAYS_LOT1", unset = "365"))
OP_PAIR_DAYS  <- as.integer(Sys.getenv("OP_PAIR_DAYS",  unset = "30"))
CL_DIR        <- Sys.getenv("CODELIST_DIR",
                             unset = if (!is.null(cfg$codelist_dir))
                               cfg$codelist_dir else "/mnt/code/codelist")
CL_OTHER      <- Sys.getenv("CL_OTHER_MALIG_CSV",
                             unset = file.path(CL_DIR, "other_malig.csv"))
CL_PREG       <- Sys.getenv("CL_PREG_CSV",
                             unset = file.path(CL_DIR, "pregnancy.csv"))
CL_MM_THERAPY <- Sys.getenv("CL_MM_THERAPY_CSV",
                             unset = file.path(CL_DIR, "cl_mma_codelist.csv"))
if (anyNA(c(BSL_DAYS, OP_PAIR_DAYS)))
  stop("BSL_DAYS_LOT1 and OP_PAIR_DAYS must be integers.")

# ---- helpers ------------------------------------------------------------
read_csv_robust <- function(path) {
  if (!file.exists(path)) return(NULL)
  tryCatch(read.csv(path, stringsAsFactors = FALSE, check.names = FALSE,
                    na.strings = c("", "NA")),
           error = function(e) {
             log_msg("Could not read ", path, ": ", conditionMessage(e))
             NULL })
}

# Materialise a codelist CSV as a temp view named `vw`. The CSV must
# have at minimum a `code` column; `code_type` is preserved when present.
csv_to_view <- function(con, path, vw, normalise_code = TRUE) {
  df <- read_csv_robust(path)
  if (is.null(df) || nrow(df) == 0) {
    log_msg("  ", vw, ": codelist ", path, " missing or empty - flag will read NA.")
    db_exec(con, glue(
      "CREATE OR REPLACE TEMPORARY VIEW {vw} AS ",
      "SELECT cast('' as string) AS code_type, ",
      "       cast('' as string) AS code,      ",
      "       cast('' as string) AS dx,        ",
      "       cast('' as string) AS icd_family,",
      "       cast('' as string) AS tumor_group WHERE 1 = 0"))
    return(0L)
  }
  nm <- tolower(names(df))
  pick <- function(...) {
    cands <- c(...); i <- which(nm %in% cands)[1]; if (is.na(i)) NA_character_ else names(df)[i]
  }
  code_col <- pick("code", "dx", "diag", "icd", "ndc", "hcpcs", "proc")
  type_col <- pick("code_type", "codetype", "type")
  tg_col   <- pick("tumor_group", "tumorgroup", "group")
  fam_col  <- pick("icd_family", "icdfamily", "family")
  dx_col   <- pick("dx")
  if (is.na(code_col)) {
    log_msg("  ", vw, ": ", path, " has no recognisable code column.")
    return(0L)
  }
  # Local DataFrame -> temp view via createOrReplaceTempView; use a
  # CREATE OR REPLACE VIEW from a VALUES clause for portability.
  rows <- vapply(seq_len(nrow(df)), function(i) {
    code <- trimws(as.character(df[[code_col]][i]))
    if (normalise_code) code <- toupper(gsub("[^A-Za-z0-9]", "", code))
    if (!nzchar(code)) return(NA_character_)
    ty <- if (!is.na(type_col)) trimws(as.character(df[[type_col]][i])) else ""
    tg <- if (!is.na(tg_col))   trimws(as.character(df[[tg_col]][i]))   else ""
    fa <- if (!is.na(fam_col))  trimws(as.character(df[[fam_col]][i]))  else ""
    dx <- if (!is.na(dx_col))   trimws(as.character(df[[dx_col]][i]))   else code
    # Single-quote escape
    sq <- function(x) gsub("'", "''", x, fixed = TRUE)
    sprintf("('%s','%s','%s','%s','%s')",
            sq(ty), sq(code), sq(sq(dx)), sq(fa), sq(tg))
  }, character(1))
  rows <- rows[!is.na(rows)]
  if (length(rows) == 0) {
    log_msg("  ", vw, ": ", path, " parsed but produced no rows.")
    return(0L)
  }
  # Spark's VALUES has a row-count limit; chunk if needed (~50k safe).
  CHUNK <- 50000L
  parts <- split(rows, ceiling(seq_along(rows) / CHUNK))
  union_sql <- paste(vapply(parts, function(pr) {
    paste0("SELECT * FROM VALUES ", paste(pr, collapse = ","),
           " AS t(code_type, code, dx, icd_family, tumor_group)")
  }, character(1)), collapse = " UNION ALL ")
  db_exec(con, glue("CREATE OR REPLACE TEMPORARY VIEW {vw} AS {union_sql}"))
  length(rows)
}

main <- function() {
  stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")
  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn,
                        pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  lot_long  <- wrk("LOT_LONG")
  med_diag  <- cdm_src(cfg$tbl_med_diag)           # raw CDM
  medical   <- cdm_src(cfg$tbl_medical)
  med_proc  <- cdm_src(cfg$tbl_med_proc)
  view_name <- wrk(VIEW_BASE)

  ok <- function(tbl) isTRUE(tryCatch(
    nrow(db_q(con, glue("SELECT 1 FROM {tbl} LIMIT 1"))) >= 0,
    error = function(e) FALSE))
  if (!ok(lot_long)) stop("Cannot read ", lot_long, ". Run the pipeline first.")

  # ---- Load codelists into temp views ---------------------------------
  log_msg("Loading codelists from ", CL_DIR)
  n_other <- csv_to_view(con, CL_OTHER, "_bl_other_malig_codes")
  n_preg  <- csv_to_view(con, CL_PREG,  "_bl_preg_codes")
  n_mm    <- csv_to_view(con, CL_MM_THERAPY, "_bl_mm_therapy_codes")
  log_msg(sprintf("  codes loaded: other-malig=%d, pregnancy=%d, mm-therapy=%d",
                  n_other, n_preg, n_mm))

  log_msg("Building ", view_name,
          " (window = [LOT1 - ", BSL_DAYS, ", LOT1 - 1])")
  # CREATE OR REPLACE TABLE (not VIEW): the codelists below are
  # SESSION temp views, and a persistent VIEW that references temp
  # views is unusable across sessions (Spark / Databricks errors with
  # CANNOT_READ_FROM_LOCAL_TEMP_VIEW). Materialising as a TABLE
  # captures the row data at build time so lot_ie_cohort.R can read
  # it in a separate Rscript session.
  sql <- glue("
    CREATE OR REPLACE TABLE {view_name} AS
    WITH lot1 AS (
      SELECT cast(PATID as string) AS PATID,
             cast(LOT_START_DT as date) AS LOT1_DT,
             cast(date_sub(LOT_START_DT, {BSL_DAYS}) as date) AS w_start,
             cast(date_sub(LOT_START_DT, 1)          as date) AS w_end
      FROM {lot_long}
      WHERE LOT_NUM = 1 AND LOT_START_DT IS NOT NULL
    ),
    -- Pre-filter raw CDM to the union of all patients' baseline windows
    -- so the joins below don't scan claims outside any window.
    dx AS (
      SELECT cast(d.PATID as string) AS PATID,
             cast(d.FST_DT as date) AS event_dt,
             d.CLMID, d.PAT_PLANID, d.LOC_CD, d.FST_DT,
             CASE WHEN upper(d.ICD_FLAG) IN ('9','ICD9','ICD-9')
                  THEN 'ICD9' ELSE 'ICD10' END AS icd_family,
             upper(regexp_replace(d.DIAG, '[^A-Za-z0-9]', '')) AS code
      FROM {med_diag} d
      WHERE d.FST_DT IS NOT NULL AND d.DIAG IS NOT NULL
    ),
    hcpcs AS (
      SELECT cast(m.PATID as string) AS PATID,
             cast(m.FST_DT as date) AS event_dt,
             upper(regexp_replace(m.PROC_CD, '[^A-Za-z0-9]', '')) AS code
      FROM {medical} m
      WHERE m.PROC_CD IS NOT NULL AND m.FST_DT IS NOT NULL
    ),
    icd_proc AS (
      SELECT cast(p.PATID as string) AS PATID,
             cast(p.FST_DT as date) AS event_dt,
             CASE WHEN upper(p.ICD_FLAG) IN ('9','ICD9','ICD-9')
                  THEN 'ICD9PROC' ELSE 'ICD10PROC' END AS code_type,
             upper(regexp_replace(p.PROC, '[^A-Za-z0-9]', '')) AS code
      FROM {med_proc} p
      WHERE p.PROC IS NOT NULL AND p.FST_DT IS NOT NULL
    ),
    rev AS (
      SELECT cast(m.PATID as string) AS PATID,
             cast(m.FST_DT as date) AS event_dt,
             upper(TRIM(m.RVNU_CD)) AS code
      FROM {medical} m
      WHERE m.RVNU_CD IS NOT NULL AND TRIM(m.RVNU_CD) <> ''
        AND m.FST_DT IS NOT NULL
    ),
    -- Pre-aggregate medical to CLAIM grain (matches pipeline step 07a:
    -- pipeline_steps.R:145-167) so multi-line claims do not Cartesian-
    -- explode the dx join below.
    mch AS (
      SELECT cast(PATID as string) AS PATID,
             PAT_PLANID, CLMID, FST_DT, LOC_CD,
             max(POS)    AS POS,
             max(TOS_CD) AS TOS_CD
      FROM {medical}
      WHERE FST_DT IS NOT NULL
      GROUP BY PATID, PAT_PLANID, CLMID, FST_DT, LOC_CD
    ),
    -- IP/OP setting derived inline from POS + TOS_CD only (the
    -- pipeline also uses a `confinement` temp view; not rebuilt here -
    -- caveat documented in the header).
    dx_settings AS (
      SELECT d.*,
             CASE WHEN m.POS IN ('21','51','61')
                    OR m.TOS_CD IN ('FAC_IP.ACUTE','FAC_IP.REHSNF',
                                    'PROF.INPVIS','FAC_IP.SNF')
                  THEN 1 ELSE 0 END AS inpatient_flg
      FROM dx d
      LEFT JOIN mch m
        ON d.PATID       =   m.PATID
       AND d.CLMID       =   m.CLMID
       AND d.FST_DT      =   m.FST_DT
       AND d.PAT_PLANID <=> m.PAT_PLANID
       AND d.LOC_CD     <=> m.LOC_CD
    ),
    -- Other-malig: cancer dx joined to cl_other_malig codelist.
    -- inpatient dx in window OR 2+ outpatient dx within 30d (first in
    -- window). MM codes are excluded by the codelist by construction.
    om_dx AS (
      SELECT dxs.PATID, dxs.event_dt, dxs.inpatient_flg, oc.tumor_group
      FROM dx_settings dxs
      INNER JOIN _bl_other_malig_codes oc
        ON dxs.code = oc.dx AND dxs.icd_family = oc.icd_family
    ),
    om_ip AS (
      SELECT l1.PATID, max(CASE WHEN om.inpatient_flg = 1
                                  AND om.event_dt BETWEEN l1.w_start AND l1.w_end
                                THEN 1 ELSE 0 END) AS ip_hit
      FROM lot1 l1
      LEFT JOIN om_dx om ON om.PATID = l1.PATID
      GROUP BY l1.PATID
    ),
    om_op_pairs AS (
      SELECT l1.PATID, om1.event_dt AS first_dt
      FROM lot1 l1
      JOIN om_dx om1 ON om1.PATID = l1.PATID AND om1.inpatient_flg = 0
                   AND om1.event_dt BETWEEN l1.w_start AND l1.w_end
      JOIN om_dx om2 ON om2.PATID = l1.PATID AND om2.inpatient_flg = 0
                   AND om2.tumor_group = om1.tumor_group
                   AND om2.event_dt > om1.event_dt
                   AND datediff(om2.event_dt, om1.event_dt) <= {OP_PAIR_DAYS}
    ),
    om_op AS (
      SELECT PATID, 1 AS op_hit FROM (SELECT DISTINCT PATID FROM om_op_pairs)
    ),
    -- Pregnancy: any DX / HCPCS / ICD-PROC / REV match in window.
    preg_evts AS (
      SELECT PATID, event_dt FROM dx
      WHERE EXISTS (SELECT 1 FROM _bl_preg_codes p
                    WHERE (p.code_type IN ('ICD9DIAG','ICD10DIAG')
                           OR p.code_type = '')
                      AND p.code = dx.code)
      UNION ALL
      SELECT PATID, event_dt FROM hcpcs
      WHERE EXISTS (SELECT 1 FROM _bl_preg_codes p
                    WHERE p.code_type = 'HCPCS' AND p.code = hcpcs.code)
      UNION ALL
      SELECT PATID, event_dt FROM icd_proc
      WHERE EXISTS (SELECT 1 FROM _bl_preg_codes p
                    WHERE p.code_type = icd_proc.code_type
                      AND p.code = icd_proc.code)
      UNION ALL
      SELECT PATID, event_dt FROM rev
      WHERE EXISTS (SELECT 1 FROM _bl_preg_codes p
                    WHERE p.code_type = 'REV' AND p.code = rev.code)
    ),
    preg_hit AS (
      SELECT l1.PATID, max(CASE
        WHEN p.event_dt BETWEEN l1.w_start AND l1.w_end THEN 1 ELSE 0 END) AS f
      FROM lot1 l1
      LEFT JOIN preg_evts p ON p.PATID = l1.PATID
      GROUP BY l1.PATID
    ),
    -- MM-baseline-therapy: any MM ONCOLOGY THERAPY event in window
    -- (rx NDC OR medical-claim HCPCS that maps to the MMA codelist).
    -- This is Julia's IE criterion ("Evidence of an MM oncology
    -- therapy during the 12-month 1L baseline period"), NOT a prior
    -- MM diagnosis check - those are different IE rows. Mirrors
    -- pipeline_steps.R's MM_THERAPY_BASELINE step (line 703) which
    -- scans MMA therapy events against the codelist, then
    -- criteria_attrition.R filters MM_bl_agents = 0.
    mm_therapy_evts AS (
      SELECT cast(r.PATID as string) AS PATID,
             cast(r.FILL_DT as date) AS event_dt
      FROM {cdm_src(cfg$tbl_rx)} r
      WHERE r.NDC IS NOT NULL AND r.FILL_DT IS NOT NULL
        AND EXISTS (SELECT 1 FROM _bl_mm_therapy_codes c
                    WHERE upper(c.code_type) IN ('NDC','')
                      AND c.code = upper(regexp_replace(r.NDC, '[^A-Za-z0-9]', '')))
      UNION ALL
      SELECT cast(m.PATID as string) AS PATID,
             cast(m.FST_DT as date) AS event_dt
      FROM {medical} m
      WHERE m.PROC_CD IS NOT NULL AND m.FST_DT IS NOT NULL
        AND EXISTS (SELECT 1 FROM _bl_mm_therapy_codes c
                    WHERE upper(c.code_type) IN ('HCPCS','')
                      AND c.code = upper(regexp_replace(m.PROC_CD, '[^A-Za-z0-9]', '')))
    ),
    mm_hit AS (
      SELECT l1.PATID,
             max(CASE WHEN m.event_dt BETWEEN l1.w_start AND l1.w_end
                       THEN 1 ELSE 0 END) AS f
      FROM lot1 l1
      LEFT JOIN mm_therapy_evts m ON m.PATID = l1.PATID
      GROUP BY l1.PATID
    )
    SELECT l1.PATID,
           coalesce(greatest(coalesce(om_ip.ip_hit, 0),
                              coalesce(om_op.op_hit, 0)), 0)
             AS OTHER_MALIGN_FLAG_LOT1,
           coalesce(preg_hit.f, 0) AS PREGNANT_FLAG_LOT1,
           coalesce(mm_hit.f, 0)   AS MM_BL_THERAPY_FLAG_LOT1,
           CASE WHEN coalesce(om_ip.ip_hit,0)   = 1
                  OR coalesce(om_op.op_hit,0)   = 1
                  OR coalesce(preg_hit.f,0)     = 1
                  OR coalesce(mm_hit.f,0)       = 1
                THEN 1 ELSE 0 END AS ANY_BASELINE_EXCL_LOT1
    FROM lot1 l1
    LEFT JOIN om_ip    ON om_ip.PATID    = l1.PATID
    LEFT JOIN om_op    ON om_op.PATID    = l1.PATID
    LEFT JOIN preg_hit ON preg_hit.PATID = l1.PATID
    LEFT JOIN mm_hit   ON mm_hit.PATID   = l1.PATID
  ")
  db_exec(con, sql)

  # ---- Summary ------------------------------------------------------
  s <- db_q(con, glue("
    SELECT count(*) AS n_lot1,
           sum(OTHER_MALIGN_FLAG_LOT1)  AS n_other_malig,
           sum(PREGNANT_FLAG_LOT1)      AS n_pregnant,
           sum(MM_BL_THERAPY_FLAG_LOT1) AS n_mm_bl_therapy,
           sum(ANY_BASELINE_EXCL_LOT1)  AS n_any
    FROM {view_name}"))
  num <- function(x) suppressWarnings(as.numeric(x))
  log_msg("Baseline recalc against [LOT1-", BSL_DAYS,
          ", LOT1-1] - patients with each flag (LOT1 N=",
          format(num(s$n_lot1[1]), big.mark = ","), "):")
  log_msg(sprintf("  other malignancy : %s", format(num(s$n_other_malig[1]),  big.mark = ",")))
  log_msg(sprintf("  pregnancy        : %s", format(num(s$n_pregnant[1]),     big.mark = ",")))
  log_msg(sprintf("  MM baseline tx   : %s", format(num(s$n_mm_bl_therapy[1]),big.mark = ",")))
  log_msg(sprintf("  ANY of the above : %s  (would be excluded under Ashley's 12-mo-pre-LOT1 rules)",
                  format(num(s$n_any[1]), big.mark = ",")))
  log_msg("Join to IE_COHORT_PATIDS via PATID and AND ANY_BASELINE_EXCL_LOT1 = 0",
          " to get the fully-spec'd Ashley cohort.")
}

if (!interactive()) main()
