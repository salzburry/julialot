#!/usr/bin/env Rscript
# Julia June-5 PDF Qs 1-3, on the current pipeline (whole cohort).
#
#   Rscript apr_30_2026/julia_q1_q3.R
#
# Inputs (all live next to this script):
#   julia_q1_q3_categories.csv     regimen -> category from Julia's PDF
#   julia_q1_q3_steroid_codes.csv  HCPCS + NDC codes -> token (DEXA / PRED)
#
# Output: julia_q1_q3_dashboard.html in cfg$output_dir.
#
# Q1: Category Sankeys per LOT pair.
# Q2: Steroid tokens (DEXA / PRED) appended to LOT_BASE_MEDS when the
#     patient had a matching rx.NDC, medical.PROC_CD, medical.BILL_PROC_CD
#     or medical.NDC claim inside the parent induction window (LOT1
#     cfg$induction_window_days, CART-started LOT2-5 cfg$cart_consolidation_days,
#     else cfg$lot_n_induction_window_days; SCT_ALLO suppressed), capped at
#     LOT_BASE_END_DT (same 4-source pattern as the parent in
#     pipeline_steps.R). Membership only; LOT boundaries unchanged.
# Q3: Non-progressors dropped (INNER JOIN LOTn -> LOTn+1).
#
# Reuses parent pipeline helpers - R/dashboard_lot.R (build_dashboard,
# add_to_dashboard, save_table, add_html_card, palettes), R/config_lot.R
# (cfg, wrk, cdm_src), R/db_utils_lot.R (db_q, db_exec, glue, log_msg).
# Parent pipeline files are NOT edited.

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

source_dir <- file.path(.script_dir, "R")
if (file.exists(file.path(source_dir, "load_inputs.R"))) {
  source(file.path(source_dir, "load_inputs.R"))
  load_pipeline_inputs(c(.script_dir, dirname(.script_dir)))
}
source(file.path(source_dir, "config_lot.R"))
source(file.path(source_dir, "db_utils_lot.R"))
source(file.path(source_dir, "dashboard_lot.R"))

TOP_N            <- 10L
LOT_LONG_AUG     <- "_jjq_lot_long_aug"
STEROID_VIEW     <- "_jjq_steroid"
CAT_CSV_PATH     <- file.path(.script_dir, "julia_q1_q3_categories.csv")
STER_CSV_PATH    <- file.path(.script_dir, "julia_q1_q3_steroid_codes.csv")
STEROID_TOKENS   <- c("DEX","DEXA","DEXAMETHASONE","PRED","PREDNISONE")

esc_html <- function(s) {
  s <- gsub("&","&amp;",as.character(s),fixed=TRUE)
  s <- gsub("<","&lt;", s,fixed=TRUE)
  gsub(">","&gt;", s,fixed=TRUE)
}

# Normalise a regimen for category matching. Strips steroid tokens
# so a steroid-augmented LOT_BASE_MEDS still matches a CSV row that
# does not list the steroid (the CSV uses canonical non-steroid
# drug-token form).
norm_key_no_steroid <- function(s) {
  if (is.na(s) || !nzchar(trimws(as.character(s)))) return("")
  t <- toupper(strsplit(as.character(s), "[[:space:]/+,\\-]+",
                         perl = TRUE)[[1]])
  t <- t[nzchar(t) & !t %in% STEROID_TOKENS]
  paste(sort(unique(t)), collapse = " ")
}

# Sankey wrapper - lifted verbatim from lot_long_dashboard.R:289 with
# the section parameterised. Same palette / layout / config conventions.
make_sankey <- function(src_lab, tgt_lab, value, section, title) {
  if (!has_plotly || length(value) == 0) return(invisible())
  nodes <- unique(c(src_lab, tgt_lab))
  idx   <- setNames(seq_along(nodes) - 1L, nodes)
  sk <- tryCatch(
    plotly::plot_ly(
      type = "sankey", orientation = "h", arrangement = "snap",
      node = list(label = nodes, pad = 14, thickness = 16,
                  color = "#2E86AB",
                  line  = list(color = "white", width = 0.5)),
      link = list(source = unname(idx[src_lab]),
                  target = unname(idx[tgt_lab]),
                  value  = as.numeric(value),
                  color  = "rgba(46,134,171,0.30)")
    ) |>
      plotly::layout(title = list(text = title, font = list(size = 15)),
                     font  = list(size = 11),
                     margin = list(l = 10, r = 10, t = 50, b = 10),
                     paper_bgcolor = "white") |>
      plotly::config(displayModeBar = TRUE, displaylogo = FALSE),
    error = function(e) {
      log_msg("  INFO: sankey '", title, "' skipped (",
              conditionMessage(e), ")"); NULL
    })
  if (!is.null(sk)) add_to_dashboard(sk, section = section, title = title)
}

# Load steroid codes from CSV into a session temp view (Q2).
load_steroid_codes <- function(con) {
  if (!file.exists(STER_CSV_PATH)) {
    log_msg("  no steroid CSV at ", STER_CSV_PATH, " - Q2 augmentation skipped.")
    db_exec(con, glue(
      "CREATE OR REPLACE TEMPORARY VIEW {STEROID_VIEW} AS ",
      "SELECT cast('' as string) AS code, ",
      " cast('' as string) AS code_type, ",
      " cast('' as string) AS mapped_to WHERE 1=0"))
    return(0L)
  }
  df <- tryCatch(read.csv(STER_CSV_PATH, stringsAsFactors = FALSE,
                          check.names = FALSE, comment.char = "#"),
                 error = function(e) NULL)
  if (is.null(df) || nrow(df) == 0) {
    log_msg("  steroid CSV unreadable or empty.")
    db_exec(con, glue(
      "CREATE OR REPLACE TEMPORARY VIEW {STEROID_VIEW} AS ",
      "SELECT cast('' as string) AS code, ",
      " cast('' as string) AS code_type, ",
      " cast('' as string) AS mapped_to WHERE 1=0"))
    return(0L)
  }
  sq <- function(x) gsub("'","''",x,fixed=TRUE)
  rows <- vapply(seq_len(nrow(df)), function(i) {
    cd <- toupper(gsub("[^A-Za-z0-9]", "",
                        trimws(as.character(df$code[i]))))
    ty <- toupper(trimws(as.character(df$code_type[i])))
    mt <- toupper(trimws(as.character(df$mapped_to[i])))
    if (!nzchar(cd) || !nzchar(mt)) return(NA_character_)
    sprintf("('%s','%s','%s')", sq(cd), sq(ty), sq(mt))
  }, character(1))
  rows <- rows[!is.na(rows)]
  if (length(rows) == 0) {
    log_msg("  steroid CSV parsed but produced 0 valid rows.")
    return(0L)
  }
  db_exec(con, glue(
    "CREATE OR REPLACE TEMPORARY VIEW {STEROID_VIEW} AS ",
    "SELECT * FROM VALUES {paste(rows, collapse=',')} ",
    "AS t(code, code_type, mapped_to)"))
  length(rows)
}

# Augment LOT_LONG with steroid tokens appended to LOT_BASE_MEDS (Q2).
# Materialised as a session temp view so the downstream Sankey queries
# can JOIN to it without re-scanning rx + medical each time.
augment_lot_long <- function(con, lot_long, rx_tbl, medical_tbl, n_codes) {
  # Pull induction-window sizes from cfg so this dashboard tracks the
  # parent pipeline when those env vars are overridden from defaults.
  iw_lot1 <- as.integer(cfg$induction_window_days)         # default 60
  iw_lotn <- as.integer(cfg$lot_n_induction_window_days)   # default 30
  iw_cart <- as.integer(cfg$cart_consolidation_days)       # default 45
  if (n_codes == 0) {
    # No codes -> view = LOT_LONG passthrough with the same column name.
    db_exec(con, glue("
      CREATE OR REPLACE TEMPORARY VIEW {LOT_LONG_AUG} AS
      SELECT cast(PATID as string) AS PATID, LOT_NUM, LOT_START_DT,
             LOT_BASE_END_DT, LOT_BASE_MEDS AS LOT_BASE_MEDS_AUG
      FROM {lot_long}
    "))
    return(invisible())
  }
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {LOT_LONG_AUG} AS
    WITH lot AS (
      -- Mirror parent induction windows so steroid attribution matches
      -- non-steroid LOT_BASE_MEDS membership. Window sizes come from
      -- cfg so any override on the parent run carries through:
      --   LOT1                 -> {iw_lot1} d (cfg$induction_window_days)
      --   LOT2-5 CART-started  -> {iw_cart} d (cfg$cart_consolidation_days)
      --   LOT2-5 SCT_ALLO      -> NULL    (parent suppresses regimen rows
      --                                    for ALLO singletons; lot2_5_base.R:353)
      --   LOT2-5 otherwise     -> {iw_lotn} d (cfg$lot_n_induction_window_days)
      -- Capped at LOT_BASE_END_DT so we never extend past the parent.
      SELECT cast(PATID as string) AS PATID, LOT_NUM, LOT_START_TYPE,
             LOT_START_DT, LOT_BASE_END_DT, LOT_BASE_MEDS,
             CASE
               WHEN LOT_START_TYPE = 'SCT_ALLO' THEN cast(NULL as date)
               WHEN LOT_BASE_END_DT IS NULL
                 THEN date_add(LOT_START_DT,
                        CASE WHEN LOT_NUM = 1             THEN {iw_lot1} - 1
                             WHEN LOT_START_TYPE = 'CART' THEN {iw_cart} - 1
                             ELSE                              {iw_lotn} - 1 END)
               ELSE least(LOT_BASE_END_DT,
                          date_add(LOT_START_DT,
                            CASE WHEN LOT_NUM = 1             THEN {iw_lot1} - 1
                                 WHEN LOT_START_TYPE = 'CART' THEN {iw_cart} - 1
                                 ELSE                              {iw_lotn} - 1 END))
             END AS LOT_INDUCTION_END_DT
      FROM {lot_long}
    ),
    lot_pats AS (SELECT DISTINCT PATID FROM lot),
    -- Source 1: medical.PROC_CD (HCPCS / CPT) - mirrors pipeline_steps.R:651
    ster_med_proc AS (
      SELECT cast(m.PATID as string) AS PATID,
             cast(m.FST_DT as date) AS dt,
             sc.mapped_to AS token
      FROM {medical_tbl} m
      JOIN {STEROID_VIEW} sc
        ON sc.code_type IN ('HCPCS','CPT')
       AND sc.code = upper(regexp_replace(coalesce(cast(m.PROC_CD as string),''), '[^A-Za-z0-9]', ''))
      WHERE m.PROC_CD IS NOT NULL AND m.FST_DT IS NOT NULL
        AND EXISTS (SELECT 1 FROM lot_pats lp
                    WHERE lp.PATID = cast(m.PATID as string))
    ),
    -- Source 2: medical.BILL_PROC_CD (HCPCS only)
    ster_med_bill AS (
      SELECT cast(m.PATID as string) AS PATID,
             cast(m.FST_DT as date) AS dt,
             sc.mapped_to AS token
      FROM {medical_tbl} m
      JOIN {STEROID_VIEW} sc
        ON sc.code_type = 'HCPCS'
       AND sc.code = upper(regexp_replace(coalesce(cast(m.BILL_PROC_CD as string),''), '[^A-Za-z0-9]', ''))
      WHERE m.BILL_PROC_CD IS NOT NULL AND m.FST_DT IS NOT NULL
        AND EXISTS (SELECT 1 FROM lot_pats lp
                    WHERE lp.PATID = cast(m.PATID as string))
    ),
    -- Source 3: medical.NDC (11-digit zero-padded compare, same as parent)
    ster_med_ndc AS (
      SELECT cast(m.PATID as string) AS PATID,
             cast(m.FST_DT as date) AS dt,
             sc.mapped_to AS token
      FROM {medical_tbl} m
      JOIN {STEROID_VIEW} sc
        ON sc.code_type = 'NDC'
       AND lpad(regexp_replace(coalesce(cast(m.NDC as string),''), '[^0-9]', ''), 11, '0')
         = lpad(regexp_replace(sc.code, '[^0-9]', ''), 11, '0')
      WHERE m.NDC IS NOT NULL AND m.FST_DT IS NOT NULL
        AND EXISTS (SELECT 1 FROM lot_pats lp
                    WHERE lp.PATID = cast(m.PATID as string))
    ),
    -- Source 4: rx.NDC (same NDC normalisation)
    ster_rx AS (
      SELECT cast(r.PATID as string) AS PATID,
             cast(r.FILL_DT as date) AS dt,
             sc.mapped_to AS token
      FROM {rx_tbl} r
      JOIN {STEROID_VIEW} sc
        ON sc.code_type = 'NDC'
       AND lpad(regexp_replace(coalesce(cast(r.NDC as string),''), '[^0-9]', ''), 11, '0')
         = lpad(regexp_replace(sc.code, '[^0-9]', ''), 11, '0')
      WHERE r.NDC IS NOT NULL AND r.FILL_DT IS NOT NULL
        AND EXISTS (SELECT 1 FROM lot_pats lp
                    WHERE lp.PATID = cast(r.PATID as string))
    ),
    ster_all AS (
      SELECT * FROM ster_med_proc
      UNION ALL SELECT * FROM ster_med_bill
      UNION ALL SELECT * FROM ster_med_ndc
      UNION ALL SELECT * FROM ster_rx
    ),
    lot_tokens AS (
      SELECT l.PATID, l.LOT_NUM,
             sort_array(collect_set(s.token)) AS toks
      FROM lot l
      JOIN ster_all s ON s.PATID = l.PATID
                     AND s.dt BETWEEN l.LOT_START_DT
                                  AND l.LOT_INDUCTION_END_DT
      GROUP BY l.PATID, l.LOT_NUM
    )
    SELECT l.PATID, l.LOT_NUM, l.LOT_START_DT, l.LOT_BASE_END_DT,
           CASE WHEN lt.toks IS NOT NULL
                THEN concat_ws(' ', array_sort(array_distinct(filter(
                       array_union(split(coalesce(l.LOT_BASE_MEDS,''),' '),
                                   lt.toks),
                       x -> x is not null and length(x) > 0))))
                ELSE l.LOT_BASE_MEDS END AS LOT_BASE_MEDS_AUG
    FROM lot l
    LEFT JOIN lot_tokens lt ON lt.PATID = l.PATID
                           AND lt.LOT_NUM = l.LOT_NUM
  "))
}

# Steroid prevalence: how many patients have at least one steroid
# token in their LOT_BASE_MEDS_AUG, per LOT_NUM. Sanity check.
build_steroid_prevalence <- function(con) {
  df <- db_q(con, glue("
    WITH per AS (
      SELECT LOT_NUM,
             count(DISTINCT PATID) AS n_lot,
             count(DISTINCT CASE WHEN array_contains(split(LOT_BASE_MEDS_AUG,' '),'DEXA')
                                  OR array_contains(split(LOT_BASE_MEDS_AUG,' '),'PRED')
                                  THEN PATID END) AS n_with_steroid
      FROM {LOT_LONG_AUG}
      GROUP BY LOT_NUM
    )
    SELECT LOT_NUM,
           cast(n_lot as int)          AS n_patients,
           cast(n_with_steroid as int) AS n_with_steroid,
           CASE WHEN n_lot > 0
                THEN round(100.0 * n_with_steroid / n_lot, 1)
                ELSE 0 END AS pct_with_steroid
    FROM per ORDER BY LOT_NUM
  "))
  if (nrow(df) == 0) return(invisible())
  save_table(df, section = "STEROIDS",
             title = "Steroid prevalence per LOT_NUM (Q2)")
  add_html_card(paste0(
    '<div style="font-family:system-ui;padding:14px;max-width:700px">',
    '<h3>Steroid token attached to LOT_BASE_MEDS (Q2)</h3>',
    '<p style="color:#555;font-size:13px">Tokens (<code>DEXA</code>, ',
    '<code>PRED</code>) are appended to <code>LOT_BASE_MEDS</code> ',
    'when the patient had a matching <code>rx.NDC</code>, ',
    '<code>medical.PROC_CD</code>, <code>medical.BILL_PROC_CD</code> ',
    'or <code>medical.NDC</code> claim inside the parent ',
    '<b>induction window</b> (LOT1: ', cfg$induction_window_days,
    'd, LOT2-5: ', cfg$lot_n_induction_window_days,
    'd, CART-started LOT2-5: ', cfg$cart_consolidation_days,
    'd), capped at <code>LOT_BASE_END_DT</code>. ',
    '<code>SCT_ALLO</code>-started LOTs are suppressed (parent ',
    'puts no induction meds on ALLO singletons). This mirrors ',
    'how the parent picks non-steroid <code>LOT_BASE_MEDS</code> ',
    'so the steroid token plays by the same rules. Membership only - ',
    'LOT boundaries (start dates, ',
    'counts, end reasons) are unchanged from <code>LOT_LONG</code>. ',
    'Steroid codes are loaded from ',
    '<code>julia_q1_q3_steroid_codes.csv</code>.</p></div>'),
    section = "STEROIDS", title = "What this section shows")
}

# Q1+Q2+Q3: focused LOT-pair Sankey by REGIMEN (steroid-augmented).
# INNER JOIN drops non-progressors.
build_focused_pair <- function(con, n_from, n_to) {
  section <- paste0("LOT", n_from, "_TO_LOT", n_to, "_REGIMEN")
  pairs <- db_q(con, glue("
    WITH a AS (
      SELECT cast(PATID as string) AS PATID, LOT_BASE_MEDS_AUG AS reg_from
      FROM {LOT_LONG_AUG}
      WHERE LOT_NUM = {n_from}
        AND LOT_BASE_MEDS_AUG IS NOT NULL
        AND trim(LOT_BASE_MEDS_AUG) <> ''
    ),
    b AS (
      SELECT cast(PATID as string) AS PATID, LOT_BASE_MEDS_AUG AS reg_to
      FROM {LOT_LONG_AUG}
      WHERE LOT_NUM = {n_to}
        AND LOT_BASE_MEDS_AUG IS NOT NULL
        AND trim(LOT_BASE_MEDS_AUG) <> ''
    )
    SELECT a.PATID, a.reg_from, b.reg_to
    FROM a JOIN b ON a.PATID = b.PATID
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

  make_sankey(paste0("L", n_from, ": ", links$reg_from),
              paste0("L", n_to,   ": ", links$tgt_node),
              links$n_patients,
              section = section,
              title   = paste0("LOT", n_from, " -> LOT", n_to,
                               " by regimen (top ", TOP_N, ", non-progressors excluded)"))
  tbl <- links
  names(tbl) <- c(paste0("LOT", n_from, "_regimen"),
                  paste0("LOT", n_to,   "_regimen"),
                  "n_patients")
  save_table(tbl, section = section,
             title = paste0("LOT", n_from, " -> LOT", n_to, " regimen counts"))
}

# Q1+Q3: focused LOT-pair Sankey by CATEGORY (Julia's mapping).
# Line-aware: LOT_NUM=1 uses the 1L NDMM lookup, LOT_NUM>=2 uses the
# 2L+ R/RMM lookup. Same regimen string can resolve to different
# categories depending on which line it is being read at.
build_category_pair <- function(con, n_from, n_to, lookups) {
  section <- "BY_CATEGORY"
  lk_from <- if (n_from == 1L) lookups$lookup_1L else lookups$lookup_2L
  lk_to   <- if (n_to   == 1L) lookups$lookup_1L else lookups$lookup_2L
  pairs <- db_q(con, glue("
    WITH a AS (
      SELECT cast(PATID as string) AS PATID, LOT_BASE_MEDS_AUG AS reg
      FROM {LOT_LONG_AUG}
      WHERE LOT_NUM = {n_from}
        AND LOT_BASE_MEDS_AUG IS NOT NULL
        AND trim(LOT_BASE_MEDS_AUG) <> ''
    ),
    b AS (
      SELECT cast(PATID as string) AS PATID, LOT_BASE_MEDS_AUG AS reg
      FROM {LOT_LONG_AUG}
      WHERE LOT_NUM = {n_to}
        AND LOT_BASE_MEDS_AUG IS NOT NULL
        AND trim(LOT_BASE_MEDS_AUG) <> ''
    )
    SELECT a.PATID, a.reg AS reg_from, b.reg AS reg_to
    FROM a JOIN b ON a.PATID = b.PATID
  "))
  if (nrow(pairs) == 0) return(invisible())

  cat_of <- function(r, lk) {
    k <- norm_key_no_steroid(r)
    if (k %in% names(lk)) unname(lk[k]) else "(uncategorised)"
  }
  pairs$cat_from <- vapply(pairs$reg_from, cat_of, character(1), lk = lk_from)
  pairs$cat_to   <- vapply(pairs$reg_to,   cat_of, character(1), lk = lk_to)

  links <- aggregate(PATID ~ cat_from + cat_to, data = pairs,
                     FUN = function(x) length(unique(x)))
  names(links)[3] <- "n_patients"
  links <- links[order(-links$n_patients), , drop = FALSE]

  make_sankey(paste0("L", n_from, ": ", links$cat_from),
              paste0("L", n_to,   ": ", links$cat_to),
              links$n_patients,
              section = section,
              title   = paste0("LOT", n_from, " -> LOT", n_to,
                               " by regimen category (non-progressors excluded)"))
  tbl <- links
  names(tbl) <- c(paste0("LOT", n_from, "_category"),
                  paste0("LOT", n_to,   "_category"),
                  "n_patients")
  save_table(tbl, section = section,
             title = paste0("LOT", n_from, " -> LOT", n_to, " category counts"))
}

# QC: how many LOT regimens fell into '(uncategorised)' per LOT_NUM.
# Pulls distinct PATID + LOT_NUM rows, applies the same line-aware
# lookup logic, and reports match rate. Surfaces mapping gaps that
# would otherwise be invisible in the Sankeys.
build_category_coverage <- function(con, lookups) {
  rows <- db_q(con, glue("
    SELECT cast(PATID as string) AS PATID, LOT_NUM,
           LOT_BASE_MEDS_AUG AS reg
    FROM {LOT_LONG_AUG}
    WHERE LOT_BASE_MEDS_AUG IS NOT NULL
      AND trim(LOT_BASE_MEDS_AUG) <> ''
      AND LOT_NUM BETWEEN 1 AND 5
  "))
  if (nrow(rows) == 0) return(invisible())
  cat_of <- function(r, lk) {
    k <- norm_key_no_steroid(r)
    if (k %in% names(lk)) unname(lk[k]) else "(uncategorised)"
  }
  rows$cat <- vapply(seq_len(nrow(rows)), function(i) {
    lk <- if (rows$LOT_NUM[i] == 1L) lookups$lookup_1L else lookups$lookup_2L
    cat_of(rows$reg[i], lk)
  }, character(1))
  agg <- aggregate(PATID ~ LOT_NUM, data = rows,
                   FUN = function(x) length(unique(x)))
  names(agg)[2] <- "n_patients"

  un_rows <- rows[rows$cat == "(uncategorised)", , drop = FALSE]
  if (nrow(un_rows) > 0) {
    unc <- aggregate(PATID ~ LOT_NUM, data = un_rows,
                     FUN = function(x) length(unique(x)))
    names(unc)[2] <- "n_uncategorised"
    out <- merge(agg, unc, by = "LOT_NUM", all.x = TRUE)
    out$n_uncategorised[is.na(out$n_uncategorised)] <- 0L
  } else {
    out <- agg
    out$n_uncategorised <- 0L
  }
  out$pct_uncategorised <- ifelse(out$n_patients > 0,
                                   round(100 * out$n_uncategorised /
                                         out$n_patients, 1), 0)
  save_table(out, section = "BY_CATEGORY",
             title = "Category mapping coverage per LOT_NUM")

  # Top 10 unmapped regimen strings so Julia can extend the CSV.
  if (nrow(un_rows) > 0) {
    top <- aggregate(PATID ~ reg + LOT_NUM,
                     data = un_rows[, c("PATID","LOT_NUM","reg")],
                     FUN = function(x) length(unique(x)))
    names(top)[3] <- "n_patients"
    top <- top[order(-top$n_patients), , drop = FALSE]
    save_table(head(top, 10), section = "BY_CATEGORY",
               title = "Top 10 unmapped regimens (extend the CSV)")
  }
}

# Line-aware: regimens like 'CARF CYCL' map to different categories
# depending on whether they are 1L NDMM or 2L+ R/RMM. The CSV tags the
# category with '(1L NDMM)' or '(2L+ R/RMM)' so we split into two
# lookups keyed by normalised regimen string.
load_categories <- function() {
  if (!file.exists(CAT_CSV_PATH))
    return(list(lookup_1L = character(0), lookup_2L = character(0)))
  df <- tryCatch(read.csv(CAT_CSV_PATH, stringsAsFactors = FALSE),
                 error = function(e) NULL)
  if (is.null(df) || nrow(df) == 0)
    return(list(lookup_1L = character(0), lookup_2L = character(0)))
  nm <- tolower(names(df))
  reg_i <- which(nm %in% c("regimen","lot_base_meds","med","meds"))[1]
  cat_i <- which(nm %in% c("category","regimen_category","treatment_category"))[1]
  if (is.na(reg_i) || is.na(cat_i))
    return(list(lookup_1L = character(0), lookup_2L = character(0)))
  cats <- trimws(df[[cat_i]])
  keys <- vapply(df[[reg_i]], norm_key_no_steroid, character(1))
  is_1L <- grepl("1L",  cats, ignore.case = TRUE)
  is_2L <- grepl("2L\\+|2L|R/RMM|RRMM", cats, ignore.case = TRUE)
  # If neither tag, fall back to 1L so unmarked rows still match.
  no_tag <- !is_1L & !is_2L
  is_1L <- is_1L | no_tag
  list(
    lookup_1L = setNames(cats[is_1L], keys[is_1L]),
    lookup_2L = setNames(cats[is_2L], keys[is_2L])
  )
}

build_overview_card <- function(n_ster_codes, n_cat_rules) {
  add_html_card(paste0(
    '<div style="font-family:system-ui;padding:14px;max-width:900px">',
    '<h3>Julia June 5 - Q1 / Q2 / Q3 on the current pipeline</h3>',
    '<p style="color:#555;font-size:13px">Reads parent pipeline ',
    '<code>LOT_LONG</code>; no Ashley-cohort filter applied (that is ',
    'Q4, separate).</p>',
    '<ul style="font-size:13px;color:#1a7a3a;margin-top:0">',
    '<li><b>Q1</b>: regimen-category Sankeys per LOT pair (',
    n_cat_rules, ' regimen rules loaded).</li>',
    '<li><b>Q2</b>: steroid tokens appended to <code>LOT_BASE_MEDS</code> ',
    'inside the parent induction window, capped at ',
    '<code>LOT_BASE_END_DT</code>; <code>SCT_ALLO</code>-started LOTs ',
    'suppressed to mirror the parent (',
    n_ster_codes, ' codes loaded; LOT boundaries unchanged).</li>',
    '<li><b>Q3</b>: non-progressors dropped (inner-join LOTn &rarr; LOTn+1).</li>',
    '</ul></div>'),
    section = "OVERVIEW", title = "What this dashboard shows")
}

main <- function() {
  stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")
  cfg$build_dashboard <<- TRUE

  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn,
                        pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  lot_long    <- wrk("LOT_LONG")
  rx_tbl      <- cdm_src(cfg$tbl_rx)
  medical_tbl <- cdm_src(cfg$tbl_medical)

  ok <- function(t) isTRUE(tryCatch(
    nrow(db_q(con, glue("SELECT 1 FROM {t} LIMIT 1"))) >= 0,
    error = function(e) FALSE))
  if (!ok(lot_long)) stop("Cannot read ", lot_long)
  q2_ok <- ok(rx_tbl) && ok(medical_tbl)
  if (!q2_ok) {
    log_msg("  WARN: rx or medical unreadable; Q2 steroid augmentation ",
            "skipped. Q1+Q3 will run on un-augmented LOT_LONG.")
  }

  if (q2_ok) {
    log_msg("Loading steroid codes from ", STER_CSV_PATH)
    n_ster <- load_steroid_codes(con)
    log_msg("  ", n_ster, " codes loaded")
  } else {
    n_ster <- 0L
  }

  log_msg("Augmenting LOT_LONG with steroid tokens -> ", wrk(LOT_LONG_AUG))
  augment_lot_long(con, lot_long, rx_tbl, medical_tbl, n_ster)

  log_msg("Loading categories from ", CAT_CSV_PATH)
  lookups <- load_categories()
  n_rules <- length(lookups$lookup_1L) + length(lookups$lookup_2L)
  if (n_rules == 0) {
    log_msg("  WARN: no category mapping loaded; Q1 section will say uncategorised.")
  } else {
    log_msg("  ", length(lookups$lookup_1L), " 1L rules, ",
            length(lookups$lookup_2L), " 2L+ rules loaded")
  }

  dashboard_items <<- list()
  build_overview_card(n_ster, n_rules)
  build_steroid_prevalence(con)
  for (n in 1:4) build_focused_pair(con, n, n + 1L)
  for (n in 1:4) build_category_pair(con, n, n + 1L, lookups)
  build_category_coverage(con, lookups)

  build_dashboard(
    out_name     = "julia_q1_q3_dashboard.html",
    header_title = "MM LOT &mdash; Julia June 5 (Q1/Q2/Q3 on current pipeline)",
    header_sub   = "Steroids &bull; LOT-pair regimen Sankeys &bull; By category &nbsp;&mdash; pick a Category above"
  )
  log_msg("Wrote ", file.path(cfg$output_dir, "julia_q1_q3_dashboard.html"))
}

if (!interactive()) main()
