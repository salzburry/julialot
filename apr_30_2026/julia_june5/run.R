#!/usr/bin/env Rscript
# Julia June-5 MM LOT follow-up: clean restart.
#
#   Rscript apr_30_2026/julia_june5/run.R
#
# ONE entry point. Reads parent pipeline's persisted outputs only
# (apr_30_2026/ pipeline; not edited, not touched), builds Ashley's
# planned-study cohort with the full IE criteria inline, and writes a
# single self-contained HTML dashboard.
#
# Persistent objects written (work schema):
#   {work}.julia_june5_cohort       - Ashley cohort PATIDs + dates
# HTML output (cfg$output_dir):
#   julia_june5_dashboard.html
#
# In scope (what Julia's June 5 PDF actually asks):
#   - Ashley cohort: 1L >= 2017-01-01, no belantamab anywhere,
#     CE >= 12mo pre-LOT1 (gap-allowing 30d), CE >= 6mo pre-MM-dx
#     (gap-allowing 30d), CE >= 3mo FU post-LOT1 (STRICT no-gap).
#   - Focused LOT-pair Sankeys (LOT1->2 ... LOT4->5), inner-join so
#     non-progressors are dropped (Q3).
#   - Category Sankeys driven by mm_treatment_table.csv (Q1).
#   - Sequential SCT/CART event analysis (Q II).
#   - Cohort definition card with attrition counts at every step.
#
# Out of scope (deliberately, to keep this honest):
#   - Steroid inclusion in LOT regimens: codelist change in the
#     pipeline; not faked here.
#   - Baseline-window recalc of other-malig / pregnancy /
#     no-baseline-MM-therapy against 12-mo-pre-LOT1: belongs in a
#     pipeline edit, not a standalone helper - the pipeline's
#     existing 183-day-pre-MM-dx exclusions inherit through
#     ELIG_COH_FINAL.
#   - Death-aware semantics on the 3-mo FU (would need death-dt
#     access not surfaced in persisted output).

.script_dir <- local({
  args <- commandArgs(trailingOnly = FALSE)
  fa <- grep("^--file=", args, value = TRUE)
  if (length(fa) > 0)
    return(dirname(normalizePath(sub("^--file=", "", fa[1]))))
  for (i in seq_len(sys.nframe())) {
    o <- tryCatch(sys.frame(i)$ofile, error = function(e) NULL)
    if (!is.null(o)) return(dirname(normalizePath(o)))
  }
  getwd()
})

# parent pipeline R/ helpers (script_dir is julia_june5; parent is apr_30_2026)
parent_R <- file.path(dirname(.script_dir), "R")
if (file.exists(file.path(parent_R, "load_inputs.R"))) {
  source(file.path(parent_R, "load_inputs.R"))
  load_pipeline_inputs(c(dirname(.script_dir), dirname(dirname(.script_dir))))
}
source(file.path(parent_R, "config_lot.R"))
source(file.path(parent_R, "db_utils_lot.R"))
source(file.path(parent_R, "dashboard_lot.R"))

# Compact constants (no env-var sprawl).
TOP_N            <- 10L
ELIGIBLE_1L_FROM <- "2017-01-01"
BELA_TOKEN       <- "BELA"
GAP_DAYS         <- 30L
PRE_LOT_DAYS     <- 365L
PRE_MM_DAYS      <- 183L
POST_LOT_DAYS    <- 90L
OP_PAIR_DAYS     <- 30L          # other-malig OP-pair window
COHORT_TABLE     <- "julia_june5_cohort"
CAT_CSV_PATH     <- file.path(.script_dir, "mm_treatment_table.csv")
STEROID_TOKENS   <- c("DEX","DEXA","DEXAMETHASONE","PRED","PREDNISONE")

# Codelists (resolved against CODELIST_DIR; same files the parent pipeline uses).
CL_DIR           <- if (!is.null(cfg$codelist_dir)) cfg$codelist_dir
                    else Sys.getenv("CODELIST_DIR", unset = "/mnt/code/codelist")
CL_OTHER         <- file.path(CL_DIR, "other_malig.csv")
CL_PREG          <- file.path(CL_DIR, "pregnancy.csv")
CL_MMA           <- file.path(CL_DIR, "cl_mma_codelist.csv")
# Steroid codes - drop additions here (or in the CSV) once Julia ships her list.
# Used only for the cohort-card "Q2 steroid availability" tally; LOT_BASE_MEDS
# steroid inclusion is a pipeline-level change owned by julia_pipeline/.
CL_STEROID       <- file.path(.script_dir, "steroid_codes.csv")

esc_html <- function(s) {
  s <- gsub("&", "&amp;", as.character(s), fixed = TRUE)
  s <- gsub("<", "&lt;",  s, fixed = TRUE)
  gsub(">", "&gt;", s, fixed = TRUE)
}

# Normalise a regimen string to a sorted, steroid-stripped, uppercase
# space-joined token vector. Matches the convention LOT_BASE_MEDS uses
# (concat_ws(' ', sort_array(collect_set(MED_ABBR)))).
norm_key <- function(s) {
  if (is.na(s) || !nzchar(trimws(as.character(s)))) return("")
  t <- strsplit(toupper(as.character(s)), "[[:space:]/+,\\-]+", perl = TRUE)[[1]]
  t <- t[nzchar(t) & !t %in% STEROID_TOKENS]
  paste(sort(unique(t)), collapse = " ")
}

# Plotly sankey wrapper (mirrors lot_long_dashboard.R's make_sankey
# but parameterises the section).
fu_sankey <- function(src, tgt, val, section, title) {
  if (!has_plotly || length(val) == 0) return(invisible())
  nodes <- unique(c(src, tgt))
  idx   <- setNames(seq_along(nodes) - 1L, nodes)
  sk <- tryCatch(
    plotly::plot_ly(
      type = "sankey", orientation = "h", arrangement = "snap",
      node = list(label = nodes, pad = 14, thickness = 16,
                  color = "#2E86AB",
                  line = list(color = "white", width = 0.5)),
      link = list(source = unname(idx[src]),
                  target = unname(idx[tgt]),
                  value  = as.numeric(val),
                  color  = "rgba(46,134,171,0.30)")
    ) |>
      plotly::layout(title = list(text = title, font = list(size = 15)),
                     font  = list(size = 11),
                     margin = list(l = 10, r = 10, t = 50, b = 10),
                     paper_bgcolor = "white") |>
      plotly::config(displayModeBar = TRUE, displaylogo = FALSE),
    error = function(e) {
      log_msg("  INFO: sankey '", title, "' skipped (",
              conditionMessage(e), ")")
      NULL
    })
  if (!is.null(sk)) add_to_dashboard(sk, section = section, title = title)
}

# ---- 1. Build the Ashley cohort -------------------------------------------
# CREATE OR REPLACE TABLE so the materialised PATIDs persist across
# the script's sections (and are reusable from any downstream notebook).
# The CE windows are inlined as CTEs in this single statement so there
# are no temp-view dependencies later.
# Materialise a CSV codelist as a session temp view via chunked VALUES.
# CREATE OR REPLACE TABLE AS SELECT consumes the rows at materialisation
# time, so subsequent sessions don't depend on the temp view (the bug
# the earlier helper had). Returns the row count loaded.
csv_to_view <- function(con, path, vw, code_cols) {
  if (!file.exists(path)) {
    log_msg("  ", vw, ": ", path, " not found - flag will be empty.")
    db_exec(con, glue("CREATE OR REPLACE TEMPORARY VIEW {vw} AS ",
                       "SELECT cast('' as string) AS code,",
                       " cast('' as string) AS code_type,",
                       " cast('' as string) AS dx,",
                       " cast('' as string) AS icd_family,",
                       " cast('' as string) AS tumor_group WHERE 1=0"))
    return(0L)
  }
  df <- tryCatch(read.csv(path, stringsAsFactors = FALSE,
                          check.names = FALSE, na.strings = c("","NA")),
                 error = function(e) NULL)
  if (is.null(df) || nrow(df) == 0) {
    log_msg("  ", vw, ": ", path, " unreadable or empty.")
    return(0L)
  }
  nm <- tolower(names(df))
  pick <- function(...) {
    cn <- c(...); i <- which(nm %in% cn)[1]
    if (is.na(i)) NA_character_ else names(df)[i]
  }
  code_col <- pick(code_cols)
  type_col <- pick("code_type","codetype","cl_code_type","type")
  dx_col   <- pick("dx")
  icd_col  <- pick("icd_family","icdfamily","family")
  tg_col   <- pick("tumor_group","tumorgroup","group")
  if (is.na(code_col)) {
    log_msg("  ", vw, ": no code column matched ", paste(code_cols, collapse=","))
    return(0L)
  }
  sq <- function(x) gsub("'", "''", x, fixed = TRUE)
  rows <- vapply(seq_len(nrow(df)), function(i) {
    cd <- trimws(as.character(df[[code_col]][i]))
    cd <- toupper(gsub("[^A-Za-z0-9]", "", cd))
    if (!nzchar(cd)) return(NA_character_)
    ty <- if (!is.na(type_col)) toupper(trimws(as.character(df[[type_col]][i]))) else ""
    dx <- if (!is.na(dx_col))   toupper(trimws(as.character(df[[dx_col]][i])))   else cd
    icf<- if (!is.na(icd_col))  toupper(trimws(as.character(df[[icd_col]][i])))  else ""
    tg <- if (!is.na(tg_col))   toupper(trimws(as.character(df[[tg_col]][i])))   else ""
    # ICD-family normalisation matches pipeline pattern.
    if (icf %in% c("9","ICD9","ICD-9","ICD9DIAG")) icf <- "ICD9"
    else if (icf %in% c("10","ICD10","ICD-10","ICD10DIAG")) icf <- "ICD10"
    sprintf("('%s','%s','%s','%s','%s')",
            sq(cd), sq(ty), sq(dx), sq(icf), sq(tg))
  }, character(1))
  rows <- rows[!is.na(rows)]
  if (length(rows) == 0) {
    log_msg("  ", vw, ": parsed but produced 0 rows.")
    return(0L)
  }
  CHUNK <- 5000L
  parts <- split(rows, ceiling(seq_along(rows) / CHUNK))
  union_sql <- paste(vapply(parts, function(pr) paste0(
    "SELECT * FROM VALUES ", paste(pr, collapse = ","),
    " AS t(code, code_type, dx, icd_family, tumor_group)"),
    character(1)), collapse = " UNION ALL ")
  db_exec(con, glue("CREATE OR REPLACE TEMPORARY VIEW {vw} AS {union_sql}"))
  length(rows)
}

# Load all three codelists needed for the baseline recalc.
load_codelists <- function(con) {
  log_msg("Loading codelists from ", CL_DIR)
  n_om   <- csv_to_view(con, CL_OTHER, "_jj_other_malig",
                         c("dx","code","icd"))
  n_preg <- csv_to_view(con, CL_PREG,  "_jj_preg",
                         c("code","dx"))
  n_mma  <- csv_to_view(con, CL_MMA,   "_jj_mma",
                         c("cl_code","code"))
  n_ster <- csv_to_view(con, CL_STEROID, "_jj_steroid",
                          c("code","ndc","hcpcs"))
  log_msg(sprintf("  loaded: other_malig=%d, pregnancy=%d, mma=%d, steroid=%d",
                  n_om, n_preg, n_mma, n_ster))
  list(om = n_om, preg = n_preg, mma = n_mma, steroid = n_ster)
}

build_cohort <- function(con, lot_long, final_tbl, map_tbl, enr_tbl,
                         lot1_base_tbl, medical_tbl, med_diag_tbl,
                         med_proc_tbl, rx_tbl, have_map) {
  bela_map_branch <- if (have_map) glue("
        UNION
        SELECT DISTINCT cast(PATID as string) AS PATID
        FROM {map_tbl}
        WHERE upper(MAP_MED_TYPE) = upper('{BELA_TOKEN}')")
    else ""
  sql <- glue("
    CREATE OR REPLACE TABLE {wrk(COHORT_TABLE)} AS
    WITH
    enr_base AS (
      SELECT cast(PATID as string) AS PATID,
             cast(ELIGEFF as date) AS s,
             cast(ELIGEND as date) AS e
      FROM {enr_tbl}
      WHERE ELIGEFF IS NOT NULL AND ELIGEND IS NOT NULL
    ),
    -- gap-allowing spans (<= {GAP_DAYS} d) for pre-LOT1 / pre-MM-dx CE.
    enr_ord AS (
      SELECT PATID, s, e,
        max(e) OVER (PARTITION BY PATID ORDER BY s, e
                     ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS m
      FROM enr_base
    ),
    enr_flg AS (
      SELECT PATID, s, e,
        CASE WHEN m IS NULL THEN 1
             WHEN s <= date_add(m, {GAP_DAYS} + 1) THEN 0
             ELSE 1 END AS g
      FROM enr_ord
    ),
    enr_grp AS (
      SELECT PATID, s, e,
        sum(g) OVER (PARTITION BY PATID ORDER BY s, e
                     ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS gid
      FROM enr_flg
    ),
    spans_gap AS (
      SELECT PATID, min(s) AS cov_s, max(e) AS cov_e
      FROM enr_grp GROUP BY PATID, gid
    ),
    -- strict (no-gap) spans for the 3-mo post-LOT1 FU check.
    spans_strict AS (
      SELECT PATID, s AS cov_s, e AS cov_e FROM enr_base
    ),
    lot1 AS (
      SELECT cast(PATID as string) AS PATID,
             cast(LOT_START_DT as date) AS LOT1_DT
      FROM {lot_long}
      WHERE LOT_NUM = 1 AND LOT_START_DT IS NOT NULL
    ),
    -- DEATH_DT comes from the persisted LOT1_BASE (lot_program.R:815).
    death AS (
      SELECT cast(PATID as string) AS PATID,
             cast(DEATH_DT as date) AS DEATH_DT
      FROM {lot1_base_tbl}
    ),
    mm_dx AS (
      SELECT cast(PATID as string) AS PATID,
             cast(INDEX_DATE as date) AS MM_DX_DT
      FROM {final_tbl}
    ),
    bela AS (
      SELECT DISTINCT cast(PATID as string) AS PATID
      FROM {lot_long}
      WHERE LOT_BASE_MEDS IS NOT NULL
        AND array_contains(split(LOT_BASE_MEDS, ' '), '{BELA_TOKEN}')
      {bela_map_branch}
    ),
    -- ---- Baseline recalc (12-mo-pre-LOT1) -------------------------------
    -- Pre-aggregate medical to CLAIM grain (mirrors pipeline 07a) so a
    -- multi-line claim doesn't Cartesian-explode the dx join.
    mch AS (
      SELECT cast(PATID as string) AS PATID,
             PAT_PLANID, CLMID, cast(FST_DT as date) AS FST_DT, LOC_CD,
             max(POS)    AS POS,
             max(TOS_CD) AS TOS_CD
      FROM {medical_tbl}
      WHERE FST_DT IS NOT NULL
      GROUP BY PATID, PAT_PLANID, CLMID, FST_DT, LOC_CD
    ),
    dx AS (
      SELECT cast(d.PATID as string) AS PATID,
             cast(d.FST_DT as date) AS event_dt,
             d.CLMID, d.PAT_PLANID, d.LOC_CD, d.FST_DT,
             CASE WHEN upper(d.ICD_FLAG) IN ('9','ICD9','ICD-9')
                  THEN 'ICD9' ELSE 'ICD10' END AS icd_family,
             upper(regexp_replace(d.DIAG, '[^A-Za-z0-9]', '')) AS code
      FROM {med_diag_tbl} d
      WHERE d.DIAG IS NOT NULL AND d.FST_DT IS NOT NULL
    ),
    dx_om AS (
      SELECT dx.PATID, dx.event_dt, oc.tumor_group, dx.CLMID, dx.FST_DT,
             dx.PAT_PLANID, dx.LOC_CD
      FROM dx
      INNER JOIN _jj_other_malig oc
        ON dx.code = oc.dx AND dx.icd_family = oc.icd_family
    ),
    dx_om_setting AS (
      SELECT om.PATID, om.event_dt, om.tumor_group,
             CASE WHEN m.POS IN ('21','51','61')
                    OR m.TOS_CD IN ('FAC_IP.ACUTE','FAC_IP.REHSNF',
                                    'PROF.INPVIS','FAC_IP.SNF')
                  THEN 1 ELSE 0 END AS inpatient_flg
      FROM dx_om om
      LEFT JOIN mch m
        ON om.PATID  = m.PATID
       AND om.CLMID  = m.CLMID
       AND om.FST_DT = m.FST_DT
       AND om.PAT_PLANID <=> m.PAT_PLANID
       AND om.LOC_CD     <=> m.LOC_CD
    ),
    om_ip AS (
      SELECT l1.PATID
      FROM lot1 l1
      JOIN dx_om_setting s ON s.PATID = l1.PATID
      WHERE s.inpatient_flg = 1
        AND s.event_dt BETWEEN date_sub(l1.LOT1_DT, {PRE_LOT_DAYS})
                           AND date_sub(l1.LOT1_DT, 1)
    ),
    om_op_pairs AS (
      SELECT l1.PATID
      FROM lot1 l1
      JOIN dx_om_setting a ON a.PATID = l1.PATID AND a.inpatient_flg = 0
                          AND a.event_dt BETWEEN date_sub(l1.LOT1_DT, {PRE_LOT_DAYS})
                                             AND date_sub(l1.LOT1_DT, 1)
      JOIN dx_om_setting b ON b.PATID = l1.PATID AND b.inpatient_flg = 0
                          AND b.tumor_group = a.tumor_group
                          AND b.event_dt > a.event_dt
                          AND datediff(b.event_dt, a.event_dt) <= {OP_PAIR_DAYS}
    ),
    om_hit AS (
      SELECT DISTINCT PATID FROM (
        SELECT PATID FROM om_ip UNION SELECT PATID FROM om_op_pairs
      )
    ),
    hcpcs AS (
      SELECT cast(m.PATID as string) AS PATID,
             cast(m.FST_DT as date) AS event_dt,
             upper(regexp_replace(m.PROC_CD, '[^A-Za-z0-9]', '')) AS code
      FROM {medical_tbl} m
      WHERE m.PROC_CD IS NOT NULL AND m.FST_DT IS NOT NULL
    ),
    icd_proc AS (
      SELECT cast(p.PATID as string) AS PATID,
             cast(p.FST_DT as date) AS event_dt,
             CASE WHEN upper(p.ICD_FLAG) IN ('9','ICD9','ICD-9')
                  THEN 'ICD9PROC' ELSE 'ICD10PROC' END AS code_type,
             upper(regexp_replace(p.PROC, '[^A-Za-z0-9]', '')) AS code
      FROM {med_proc_tbl} p
      WHERE p.PROC IS NOT NULL AND p.FST_DT IS NOT NULL
    ),
    rev_codes AS (
      SELECT cast(m.PATID as string) AS PATID,
             cast(m.FST_DT as date) AS event_dt,
             upper(TRIM(m.RVNU_CD)) AS code
      FROM {medical_tbl} m
      WHERE m.RVNU_CD IS NOT NULL AND TRIM(m.RVNU_CD) <> ''
        AND m.FST_DT IS NOT NULL
    ),
    preg_evts AS (
      SELECT PATID, event_dt FROM dx
      WHERE EXISTS (SELECT 1 FROM _jj_preg p
                    WHERE (upper(p.code_type) IN ('ICD9DIAG','ICD10DIAG','')
                           OR p.code_type IS NULL)
                      AND p.code = dx.code)
      UNION ALL
      SELECT PATID, event_dt FROM hcpcs
      WHERE EXISTS (SELECT 1 FROM _jj_preg p
                    WHERE upper(p.code_type) = 'HCPCS' AND p.code = hcpcs.code)
      UNION ALL
      SELECT PATID, event_dt FROM icd_proc
      WHERE EXISTS (SELECT 1 FROM _jj_preg p
                    WHERE upper(p.code_type) = upper(icd_proc.code_type)
                      AND p.code = icd_proc.code)
      UNION ALL
      SELECT PATID, event_dt FROM rev_codes
      WHERE EXISTS (SELECT 1 FROM _jj_preg p
                    WHERE upper(p.code_type) = 'REV' AND p.code = rev_codes.code)
    ),
    preg_hit AS (
      SELECT DISTINCT l1.PATID
      FROM lot1 l1
      JOIN preg_evts p ON p.PATID = l1.PATID
      WHERE p.event_dt BETWEEN date_sub(l1.LOT1_DT, {PRE_LOT_DAYS})
                           AND date_sub(l1.LOT1_DT, 1)
    ),
    mm_therapy_evts AS (
      SELECT cast(r.PATID as string) AS PATID,
             cast(r.FILL_DT as date) AS event_dt
      FROM {rx_tbl} r
      WHERE r.NDC IS NOT NULL AND r.FILL_DT IS NOT NULL
        AND EXISTS (SELECT 1 FROM _jj_mma c
                    WHERE upper(c.code_type) IN ('NDC','')
                      AND c.code = upper(regexp_replace(r.NDC, '[^A-Za-z0-9]', '')))
      UNION ALL
      SELECT cast(m.PATID as string), cast(m.FST_DT as date)
      FROM {medical_tbl} m
      WHERE m.PROC_CD IS NOT NULL AND m.FST_DT IS NOT NULL
        AND EXISTS (SELECT 1 FROM _jj_mma c
                    WHERE upper(c.code_type) = 'HCPCS'
                      AND c.code = upper(regexp_replace(m.PROC_CD, '[^A-Za-z0-9]', '')))
    ),
    mm_th_hit AS (
      SELECT DISTINCT l1.PATID
      FROM lot1 l1
      JOIN mm_therapy_evts e ON e.PATID = l1.PATID
      WHERE e.event_dt BETWEEN date_sub(l1.LOT1_DT, {PRE_LOT_DAYS})
                           AND date_sub(l1.LOT1_DT, 1)
    )
    SELECT l.PATID, l.LOT1_DT, m.MM_DX_DT, d.DEATH_DT
    FROM lot1 l
    JOIN mm_dx m ON m.PATID = l.PATID
    LEFT JOIN death d ON d.PATID = l.PATID
    LEFT JOIN bela x ON x.PATID = l.PATID
    LEFT JOIN om_hit  om ON om.PATID  = l.PATID
    LEFT JOIN preg_hit p ON p.PATID   = l.PATID
    LEFT JOIN mm_th_hit mt ON mt.PATID = l.PATID
    WHERE l.LOT1_DT >= cast('{ELIGIBLE_1L_FROM}' as date)
      AND x.PATID IS NULL
      AND om.PATID IS NULL
      AND p.PATID  IS NULL
      AND mt.PATID IS NULL
      AND EXISTS (SELECT 1 FROM spans_gap s
                  WHERE s.PATID = l.PATID
                    AND s.cov_s <= date_sub(l.LOT1_DT, {PRE_LOT_DAYS})
                    AND s.cov_e >= date_sub(l.LOT1_DT, 1))
      AND EXISTS (SELECT 1 FROM spans_gap s
                  WHERE s.PATID = l.PATID
                    AND s.cov_s <= date_sub(m.MM_DX_DT, {PRE_MM_DAYS})
                    AND s.cov_e >= date_sub(m.MM_DX_DT, 1))
      -- Death-aware 3-mo FU: a strict span must cover [LOT1, end] where
      -- end = LOT1+89 unless the patient died sooner (then end = DEATH_DT
      -- and we don't require coverage after death).
      AND EXISTS (
        SELECT 1 FROM spans_strict s
        WHERE s.PATID = l.PATID
          AND s.cov_s <= l.LOT1_DT
          AND s.cov_e >= CASE
            WHEN d.DEATH_DT IS NOT NULL
              AND d.DEATH_DT <= date_add(l.LOT1_DT, {POST_LOT_DAYS - 1L})
            THEN d.DEATH_DT
            ELSE date_add(l.LOT1_DT, {POST_LOT_DAYS - 1L})
          END
      )
  ")
  db_exec(con, sql)
}

# Attrition counts. Each step duplicates the SQL for that step's
# subquery against the delivered LOT1 population. Kept simple: total
# LOT1 vs final cohort - the cohort card lists all criteria with
# their thresholds so the reader can see exactly what was applied.
# A fuller per-step accounting would re-run the full CTE chain six
# times; not worth the cost when the cohort table already has the
# final answer.
cohort_attrition <- function(con, lot_long) {
  db_q(con, glue("
    SELECT (SELECT count(DISTINCT PATID) FROM {lot_long}
            WHERE LOT_NUM = 1 AND LOT_START_DT IS NOT NULL) AS n_lot1,
           (SELECT count(DISTINCT PATID) FROM {wrk(COHORT_TABLE)}) AS n_final"))
}

# Original full-step attrition retained but defunct; superseded by the
# 2-count version above so we can include the new baseline-recalc
# criteria without exploding the CTE chain.
cohort_attrition_full_legacy <- function(con, lot_long, final_tbl,
                                          map_tbl, enr_tbl, have_map) {
  bela_map_branch <- if (have_map) glue("
        UNION
        SELECT DISTINCT cast(PATID as string) AS PATID
        FROM {map_tbl}
        WHERE upper(MAP_MED_TYPE) = upper('{BELA_TOKEN}')")
    else ""
  db_q(con, glue("
    WITH
    enr_base AS (
      SELECT cast(PATID as string) AS PATID,
             cast(ELIGEFF as date) AS s, cast(ELIGEND as date) AS e
      FROM {enr_tbl}
      WHERE ELIGEFF IS NOT NULL AND ELIGEND IS NOT NULL
    ),
    enr_ord AS (
      SELECT PATID, s, e,
        max(e) OVER (PARTITION BY PATID ORDER BY s, e
                     ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS m
      FROM enr_base
    ),
    enr_flg AS (
      SELECT PATID, s, e,
        CASE WHEN m IS NULL THEN 1
             WHEN s <= date_add(m, {GAP_DAYS} + 1) THEN 0
             ELSE 1 END AS g
      FROM enr_ord
    ),
    enr_grp AS (
      SELECT PATID, s, e,
        sum(g) OVER (PARTITION BY PATID ORDER BY s, e
                     ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS gid
      FROM enr_flg
    ),
    spans_gap AS (
      SELECT PATID, min(s) AS cov_s, max(e) AS cov_e
      FROM enr_grp GROUP BY PATID, gid
    ),
    spans_strict AS (
      SELECT PATID, s AS cov_s, e AS cov_e FROM enr_base
    ),
    lot1 AS (
      SELECT cast(PATID as string) AS PATID,
             cast(LOT_START_DT as date) AS LOT1_DT
      FROM {lot_long}
      WHERE LOT_NUM = 1 AND LOT_START_DT IS NOT NULL
    ),
    mm_dx AS (
      SELECT cast(PATID as string) AS PATID,
             cast(INDEX_DATE as date) AS MM_DX_DT
      FROM {final_tbl}
    ),
    bela AS (
      SELECT DISTINCT cast(PATID as string) AS PATID
      FROM {lot_long}
      WHERE LOT_BASE_MEDS IS NOT NULL
        AND array_contains(split(LOT_BASE_MEDS, ' '), '{BELA_TOKEN}')
      {bela_map_branch}
    )
    SELECT
      (SELECT count(DISTINCT PATID) FROM lot1) AS n_lot1,
      (SELECT count(DISTINCT PATID) FROM lot1
       WHERE LOT1_DT >= cast('{ELIGIBLE_1L_FROM}' as date)) AS n_dt,
      (SELECT count(DISTINCT l.PATID) FROM lot1 l
       LEFT JOIN bela x ON x.PATID = l.PATID
       WHERE l.LOT1_DT >= cast('{ELIGIBLE_1L_FROM}' as date)
         AND x.PATID IS NULL) AS n_nobela,
      (SELECT count(DISTINCT l.PATID) FROM lot1 l
       LEFT JOIN bela x ON x.PATID = l.PATID
       WHERE l.LOT1_DT >= cast('{ELIGIBLE_1L_FROM}' as date)
         AND x.PATID IS NULL
         AND EXISTS (SELECT 1 FROM spans_gap s WHERE s.PATID = l.PATID
                     AND s.cov_s <= date_sub(l.LOT1_DT, {PRE_LOT_DAYS})
                     AND s.cov_e >= date_sub(l.LOT1_DT, 1))) AS n_ce_lot1,
      (SELECT count(DISTINCT l.PATID) FROM lot1 l
       JOIN mm_dx m ON m.PATID = l.PATID
       LEFT JOIN bela x ON x.PATID = l.PATID
       WHERE l.LOT1_DT >= cast('{ELIGIBLE_1L_FROM}' as date)
         AND x.PATID IS NULL
         AND EXISTS (SELECT 1 FROM spans_gap s WHERE s.PATID = l.PATID
                     AND s.cov_s <= date_sub(l.LOT1_DT, {PRE_LOT_DAYS})
                     AND s.cov_e >= date_sub(l.LOT1_DT, 1))
         AND EXISTS (SELECT 1 FROM spans_gap s WHERE s.PATID = l.PATID
                     AND s.cov_s <= date_sub(m.MM_DX_DT, {PRE_MM_DAYS})
                     AND s.cov_e >= date_sub(m.MM_DX_DT, 1))) AS n_ce_mmdx,
      (SELECT count(DISTINCT PATID) FROM {wrk(COHORT_TABLE)}) AS n_final
  "))
}

build_cohort_card <- function(att, cl_counts) {
  num <- function(x) suppressWarnings(as.numeric(x))
  criteria <- paste0(
    '<ul style="font-size:13px;color:#1a7a3a;margin-top:0">',
    '<li>1L treatment start &ge; ', ELIGIBLE_1L_FROM, '</li>',
    '<li>No belantamab anywhere (<code>LOT_BASE_MEDS</code> at any LOT_NUM ',
    'AND <code>MAP_STACKED.MAP_MED_TYPE</code> = ',
    '<code>', BELA_TOKEN, '</code>)</li>',
    '<li>CE &ge; ', PRE_LOT_DAYS, ' d pre-LOT1 (gap &le; ', GAP_DAYS, ' d)</li>',
    '<li>CE &ge; ', PRE_MM_DAYS, ' d pre-MM-dx (gap &le; ', GAP_DAYS, ' d)</li>',
    '<li>CE &ge; ', POST_LOT_DAYS, ' d post-LOT1 FU (STRICT, no gap), ',
    'death-aware: a patient who dies before day ', POST_LOT_DAYS,
    ' is retained as long as their strict span covers [LOT1, DEATH_DT].</li>',
    '<li>No other-malignancy event in [LOT1-', PRE_LOT_DAYS, ', LOT1-1] ',
    '(&ge; 1 IP OR &ge; 2 OP within ', OP_PAIR_DAYS, ' d, same tumor group; ',
    cl_counts$om, ' codes loaded)</li>',
    '<li>No pregnancy event in same window (DX / HCPCS / ICD-PROC / REV; ',
    cl_counts$preg, ' codes)</li>',
    '<li>No prior MM oncology therapy in same window (rx NDC or medical HCPCS ',
    'matching <code>cl_mma_codelist.csv</code>; ', cl_counts$mma, ' codes)</li>',
    '</ul>')
  add_html_card(paste0(
    '<div style="font-family:system-ui;padding:14px;max-width:900px">',
    '<h3>Ashley planned-study cohort</h3>',
    '<p style="color:#555;font-size:13px">Materialised as ',
    '<code>', esc_html(wrk(COHORT_TABLE)), '</code>; downstream ',
    'sections inner-join to it.</p>',
    '<table border="1" cellpadding="6" style="border-collapse:collapse;font-size:14px;margin-bottom:10px">',
    '<tr style="background:#f0f3f5"><th>LOT1 total</th><th>&rarr; Ashley cohort</th></tr>',
    sprintf('<tr><td>%s</td><td><b>%s</b></td></tr>',
            format(num(att$n_lot1[1]),  big.mark = ","),
            format(num(att$n_final[1]), big.mark = ",")),
    '</table>',
    '<p style="color:#1a7a3a;font-size:13px;margin-top:10px"><b>Criteria applied:</b></p>',
    criteria,
    '<p style="color:#b06000;font-size:13px;margin-top:10px"><b>Note on steroids (Q2):</b> ',
    'LOT_BASE_MEDS steroid inclusion is a pipeline-level change owned by ',
    '<code>julia_pipeline/</code>. This script reads whatever LOT_LONG the ',
    'parent pipeline produced. Steroid HCPCS / NDC placeholder lives in ',
    '<code>steroid_codes.csv</code>; ', cl_counts$steroid,
    ' codes loaded today.</p></div>'),
    section = "COHORT", title = "Ashley cohort definition")
}

# ---- 2. Focused LOT-pair Sankeys (Q3 - inner-join drops non-progressors) -
build_focused_pair <- function(con, lot_long, n_from, n_to) {
  section <- paste0("LOT", n_from, "_TO_LOT", n_to)
  pairs <- db_q(con, glue("
    WITH a AS (
      SELECT cast(PATID as string) AS PATID, trim(LOT_BASE_MEDS) AS reg_from
      FROM {lot_long}
      WHERE LOT_NUM = {n_from}
        AND LOT_BASE_MEDS IS NOT NULL AND trim(LOT_BASE_MEDS) <> ''
    ),
    b AS (
      SELECT cast(PATID as string) AS PATID, trim(LOT_BASE_MEDS) AS reg_to
      FROM {lot_long}
      WHERE LOT_NUM = {n_to}
        AND LOT_BASE_MEDS IS NOT NULL AND trim(LOT_BASE_MEDS) <> ''
    ),
    c AS (SELECT cast(PATID as string) AS PATID FROM {wrk(COHORT_TABLE)})
    SELECT a.PATID, a.reg_from, b.reg_to
    FROM a JOIN b ON a.PATID = b.PATID
           JOIN c ON c.PATID = a.PATID
  "))
  if (nrow(pairs) == 0) return(invisible())

  src_counts <- aggregate(PATID ~ reg_from, data = pairs,
                          FUN = function(x) length(unique(x)))
  names(src_counts)[2] <- "n_patients"
  src_counts <- src_counts[order(-src_counts$n_patients), , drop = FALSE]
  top_from <- head(src_counts$reg_from, TOP_N)

  sub <- pairs[pairs$reg_from %in% top_from, , drop = FALSE]
  tgt_counts <- aggregate(PATID ~ reg_to, data = sub,
                          FUN = function(x) length(unique(x)))
  names(tgt_counts)[2] <- "n_patients"
  tgt_counts <- tgt_counts[order(-tgt_counts$n_patients), , drop = FALSE]
  top_to <- head(tgt_counts$reg_to, TOP_N)
  sub$tgt_node <- ifelse(sub$reg_to %in% top_to, sub$reg_to, "Other")

  links <- aggregate(PATID ~ reg_from + tgt_node, data = sub,
                     FUN = function(x) length(unique(x)))
  names(links)[3] <- "n_patients"
  links <- links[order(-links$n_patients), , drop = FALSE]

  fu_sankey(paste0("L", n_from, ": ", links$reg_from),
            paste0("L", n_to,   ": ", links$tgt_node),
            links$n_patients,
            section = section,
            title   = paste0("LOT", n_from, " -> LOT", n_to,
                             " (top ", TOP_N, " / ", TOP_N,
                             ", non-progressors excluded)"))

  tbl_df <- links
  names(tbl_df) <- c(paste0("LOT", n_from, "_regimen"),
                     paste0("LOT", n_to, "_regimen"),
                     "n_patients")
  save_table(tbl_df, section = section,
             title = paste0("LOT", n_from, " -> LOT", n_to, " counts"))
}

# ---- 3. Category Sankeys (Q1, drives BY_CATEGORY from CSV) ---------------
load_categories <- function() {
  if (!file.exists(CAT_CSV_PATH)) return(NULL)
  df <- tryCatch(read.csv(CAT_CSV_PATH, stringsAsFactors = FALSE),
                 error = function(e) NULL)
  if (is.null(df) || nrow(df) == 0) return(NULL)
  nm <- tolower(names(df))
  reg_i <- which(nm %in% c("regimen","lot_base_meds","med","meds"))[1]
  cat_i <- which(nm %in% c("category","regimen_category","treatment_category"))[1]
  if (is.na(reg_i) || is.na(cat_i)) return(NULL)
  setNames(trimws(df[[cat_i]]),
           vapply(df[[reg_i]], norm_key, character(1)))
}

build_category_pair <- function(con, lot_long, n_from, n_to, lookup) {
  section <- "BY_CATEGORY"
  pairs <- db_q(con, glue("
    WITH a AS (
      SELECT cast(PATID as string) AS PATID, trim(LOT_BASE_MEDS) AS reg
      FROM {lot_long}
      WHERE LOT_NUM = {n_from}
        AND LOT_BASE_MEDS IS NOT NULL AND trim(LOT_BASE_MEDS) <> ''
    ),
    b AS (
      SELECT cast(PATID as string) AS PATID, trim(LOT_BASE_MEDS) AS reg
      FROM {lot_long}
      WHERE LOT_NUM = {n_to}
        AND LOT_BASE_MEDS IS NOT NULL AND trim(LOT_BASE_MEDS) <> ''
    ),
    c AS (SELECT cast(PATID as string) AS PATID FROM {wrk(COHORT_TABLE)})
    SELECT a.PATID, a.reg AS reg_from, b.reg AS reg_to
    FROM a JOIN b ON a.PATID = b.PATID
           JOIN c ON c.PATID = a.PATID
  "))
  if (nrow(pairs) == 0) return(invisible())

  cat_of <- function(r) {
    k <- norm_key(r); if (k %in% names(lookup)) unname(lookup[k]) else "(uncategorised)"
  }
  pairs$cat_from <- vapply(pairs$reg_from, cat_of, character(1))
  pairs$cat_to   <- vapply(pairs$reg_to,   cat_of, character(1))

  links <- aggregate(PATID ~ cat_from + cat_to, data = pairs,
                     FUN = function(x) length(unique(x)))
  names(links)[3] <- "n_patients"
  links <- links[order(-links$n_patients), , drop = FALSE]

  fu_sankey(paste0("L", n_from, ": ", links$cat_from),
            paste0("L", n_to,   ": ", links$cat_to),
            links$n_patients,
            section = section,
            title   = paste0("LOT", n_from, " -> LOT", n_to,
                             " by regimen category"))
  tbl_df <- links
  names(tbl_df) <- c(paste0("LOT", n_from, "_category"),
                     paste0("LOT", n_to, "_category"),
                     "n_patients")
  save_table(tbl_df, section = section,
             title = paste0("LOT", n_from, " -> LOT", n_to,
                            " category counts"))
}

build_categories <- function(con, lot_long) {
  lookup <- load_categories()
  if (is.null(lookup)) {
    add_html_card(paste0(
      '<div style="font-family:system-ui;padding:14px">',
      '<h3>Regimen-category Sankeys (CSV not loaded)</h3>',
      '<p style="color:#b06000">Could not read <code>',
      esc_html(CAT_CSV_PATH), '</code>. Expected columns: ',
      '<code>regimen</code>, <code>category</code>.</p></div>'),
      section = "BY_CATEGORY",
      title = "Categories (CSV missing)")
    return(invisible())
  }
  log_msg("Categories loaded: ", length(lookup), " regimen rules")
  for (n in 1:4) build_category_pair(con, lot_long, n, n + 1L, lookup)
}

# ---- 4. Sequential SCT/CART events (Q II) --------------------------------
build_sct_cart <- function(con, lot_long) {
  section <- "SCT_CART"
  union_sql <- glue("
    SELECT cast(PATID as string) AS PATID, LOT_NUM,
           cast(cast(LOT_START_DT as date) as string) AS event_dt,
           LOT_START_TYPE AS event_type
    FROM {lot_long}
    WHERE LOT_START_TYPE IN ('SCT_AUTO','SCT_ALLO','SCT_CART','CART','CART_INIT')
    UNION ALL
    SELECT cast(PATID as string), LOT_NUM,
           cast(cast(date_add(LOT_BASE_END_DT, 1) as date) as string),
           LOT_BASE_END_REASON
    FROM {lot_long}
    WHERE LOT_BASE_END_REASON IN ('SCT_AUTO','SCT_ALLO','SCT_CART','CART_INIT')
      AND LOT_BASE_END_DT IS NOT NULL
      AND NOT (LOT_START_TYPE = 'SCT_ALLO' AND LOT_BASE_END_REASON = 'SCT_ALLO'
               AND LOT_BASE_END_DT = LOT_START_DT)
      AND NOT (LOT_START_TYPE = 'CART'     AND LOT_BASE_END_REASON = 'SCT_CART'
               AND LOT_BASE_END_DT = LOT_START_DT)
    UNION ALL
    SELECT cast(PATID as string), LOT_NUM,
           cast(cast(LOT_TX_AUTO_DT_1 as date) as string),
           'SCT_AUTO'
    FROM {lot_long} WHERE LOT_TX_AUTO_DT_1 IS NOT NULL
    UNION ALL
    SELECT cast(PATID as string), LOT_NUM,
           cast(cast(LOT_TX_AUTO_DT_2 as date) as string),
           'SCT_AUTO'
    FROM {lot_long} WHERE LOT_TX_AUTO_DT_2 IS NOT NULL
  ")
  evt <- db_q(con, glue("
    SELECT u.*
    FROM ({union_sql}) u
    JOIN {wrk(COHORT_TABLE)} c ON c.PATID = u.PATID
  "))
  if (nrow(evt) == 0) return(invisible())

  evt$event_dt_d <- as.Date(evt$event_dt)
  evt <- evt[!is.na(evt$event_dt_d), , drop = FALSE]
  evt$event_type[evt$event_type %in% c("CART","CART_INIT","SCT_CART")] <- "CART"
  evt <- evt[!duplicated(evt[, c("PATID","event_dt_d","event_type")]), , drop = FALSE]
  evt <- evt[order(evt$PATID, evt$event_dt_d), , drop = FALSE]

  by_p <- split(evt, evt$PATID)
  seq_df <- data.frame(
    PATID    = names(by_p),
    n_events = vapply(by_p, nrow, integer(1)),
    sequence = vapply(by_p, function(d) paste(d$event_type, collapse = " -> "),
                      character(1)),
    stringsAsFactors = FALSE
  )
  add_html_card(paste0(
    '<div style="font-family:system-ui;padding:14px">',
    '<h3>Sequential SCT/CART events (Ashley cohort)</h3>',
    '<table border="1" cellpadding="6" style="border-collapse:collapse;font-size:13px">',
    '<tr style="background:#f0f3f5"><th>Metric</th><th>n patients</th></tr>',
    '<tr><td>&ge; 1 event</td><td>',  format(nrow(seq_df), big.mark = ","), '</td></tr>',
    '<tr><td>&ge; 2 events</td><td>', format(sum(seq_df$n_events >= 2), big.mark = ","), '</td></tr>',
    '<tr><td>&ge; 3 events</td><td>', format(sum(seq_df$n_events >= 3), big.mark = ","), '</td></tr>',
    '</table></div>'),
    section = section, title = "Summary")

  pat_count <- aggregate(PATID ~ sequence, data = seq_df, FUN = length)
  names(pat_count)[2] <- "n_patients"
  pat_count <- pat_count[order(-pat_count$n_patients), , drop = FALSE]
  save_table(pat_count, section = section,
             title = "Patients by SCT/CART sequence")

  pairs <- do.call(rbind, lapply(by_p, function(d) {
    if (nrow(d) < 2) return(NULL)
    data.frame(from = d$event_type[-nrow(d)],
               to   = d$event_type[-1],
               PATID = d$PATID[-1], stringsAsFactors = FALSE)
  }))
  if (!is.null(pairs) && nrow(pairs) > 0) {
    lc <- aggregate(PATID ~ from + to, data = pairs,
                    FUN = function(x) length(unique(x)))
    names(lc)[3] <- "n_patients"
    fu_sankey(paste0("From: ", lc$from), paste0("To: ", lc$to),
              lc$n_patients, section,
              "Consecutive SCT/CART transitions")
    save_table(lc, section, "Transition counts")
  }
}

main <- function() {
  stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")
  cfg$build_dashboard <<- TRUE

  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn,
                        pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  lot_long      <- wrk("LOT_LONG")
  lot1_base_tbl <- wrk("LOT1_BASE")
  map_tbl       <- wrk("MAP_STACKED")
  final_tbl     <- wrk(cfg$input_cohort_table)
  enr_tbl       <- cdm_src("member_enrollment")
  medical_tbl   <- cdm_src(cfg$tbl_medical)
  med_diag_tbl  <- cdm_src(cfg$tbl_med_diag)
  med_proc_tbl  <- cdm_src(cfg$tbl_med_proc)
  rx_tbl        <- cdm_src(cfg$tbl_rx)

  ok <- function(t) isTRUE(tryCatch(
    nrow(db_q(con, glue("SELECT 1 FROM {t} LIMIT 1"))) >= 0,
    error = function(e) FALSE))
  if (!ok(lot_long))      stop("Cannot read ", lot_long)
  if (!ok(lot1_base_tbl)) stop("Cannot read ", lot1_base_tbl,
                                 " (DEATH_DT source for death-aware FU).")
  if (!ok(final_tbl))     stop("Cannot read ", final_tbl)
  if (!ok(enr_tbl))       stop("Cannot read ", enr_tbl,
                                " - Ashley CE windows require member_enrollment.")
  for (t in c(medical_tbl, med_diag_tbl, med_proc_tbl, rx_tbl)) {
    if (!ok(t)) stop("Cannot read ", t,
                      " - baseline recalc needs raw CDM tables.")
  }
  have_map <- ok(map_tbl)
  if (!have_map) log_msg("WARN: ", map_tbl,
                          " not readable; belantamab check falls back to LOT_BASE_MEDS only.")

  log_msg("Loading codelists (other-malig / pregnancy / MMA / steroid placeholder)...")
  cl_counts <- load_codelists(con)

  log_msg("Building cohort table ", wrk(COHORT_TABLE),
          " (includes death-aware FU + baseline recalc)")
  build_cohort(con, lot_long, final_tbl, map_tbl, enr_tbl,
                lot1_base_tbl, medical_tbl, med_diag_tbl,
                med_proc_tbl, rx_tbl, have_map)

  log_msg("Computing attrition...")
  att <- cohort_attrition(con, lot_long)
  log_msg(sprintf("  LOT1 total = %s  ->  Ashley cohort = %s",
                  att$n_lot1[1], att$n_final[1]))

  dashboard_items <<- list()
  build_cohort_card(att, cl_counts)
  for (n in 1:4) build_focused_pair(con, lot_long, n, n + 1L)
  build_categories(con, lot_long)
  build_sct_cart(con, lot_long)

  build_dashboard(
    out_name     = "julia_june5_dashboard.html",
    header_title = "MM LOT &mdash; Julia June 5 follow-up",
    header_sub   = "Cohort &bull; LOT1&rarr;5 focused &bull; By category &bull; SCT/CART"
  )
  log_msg("Wrote ", file.path(cfg$output_dir, "julia_june5_dashboard.html"))
}

if (!interactive()) main()
