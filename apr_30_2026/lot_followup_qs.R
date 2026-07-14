#!/usr/bin/env Rscript
# Standalone LOT follow-up study-team questions -> ONE Excel workbook.
#
#   Rscript lot_followup_qs.R
#
# Sibling of lot1_studyteam_qs.R, poma_studyteam_qs.R and validation_qs.R.
# Answers the LOT-algorithm follow-ups (steroids / regimen composition / CAR-T)
# against the newly-diagnosed MM study cohort (Databricks / Optum CDM) and writes
# a single .xlsx (one tab per question + a Read Me). It reuses the shared
# operational definitions in R/validation_qs.R (vqs_* helpers), so the CAR-T and
# token logic can never drift from the dashboard.
#
# Cohort. Runs on the NDMM newly-diagnosed 1L STUDY cohort by DEFAULT
# (NDMM_LOT_LONG_FILT, LOT_LONG restricted to the NDMM cohort and persisted by
# 06_ndmm_dashboard.R) - the study team asked to see NDMM first. Set
# LOT_COHORT=FULL to re-run on the full LOT_LONG cohort (all LOT1 patients). Every
# LOT/regimen/CAR-T query flows from this one table, so the switch scopes the whole
# workbook. MAP_STACKED and LOT1_SCT are patient-level and shared (NDMM is a subset,
# joined by PATID).
#
# Questions:
#   Q1  Steroids: confirm the LOT already excludes steroids from every rule
#       (start / induction / regimen membership / discontinuation / add-med), with
#       a live audit that NO steroid token appears in any LOT_BASE_MEDS regimen
#       string, plus where the only residual steroid code lives (descriptive-only).
#   Q2  Among 1L DARA+BORT dual-therapy patients (no other agents), summarise the
#       difference in the two agents' start dates (same-day vs staggered, which
#       comes first, and the gap distribution).
#   Q3  Percentage of patients on LENA+DARA dual therapy in 1L and in 2L (exact
#       dual, plus a "contains both, any combination" context column).
#   Q4  Melphalan in 2L: the calendar timing (LOT2 start year) of MELP-containing
#       2L regimens, to see whether MELP was phased out after 2017.
#   Q5  CAR-T clarifications: recompute the CAR-T-relative-to-LOT1 metric table
#       (vqs_q6_cart) on this cohort and answer, empirically, each of the study
#       team's five CAR-T questions (subset relationships, the 124 count, CAR-T on
#       the LOT1 start date, and whether a CAR-T becomes the 2L start date).
#
# Builds nothing persistent (only session TEMP views); safe to run any time.

.script_dir <- local({
  args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", args, value = TRUE)
  if (length(file_arg) > 0)
    return(dirname(normalizePath(sub("^--file=", "", file_arg[1]))))
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
source(file.path(source_dir, "codelists_lot.R"))        # load_codelist_csv
source(file.path(source_dir, "validation_qs.R"))        # vqs_* helpers (shared)

`%||%` <- function(a, b) if (is.null(a)) b else a

# ===========================================================================
# Ensure the Excel engine is present. Try to load openxlsx; if missing, try to
# install it once; report whether it is now usable. The deliverable is an .xlsx,
# so main() fails closed when this returns FALSE (unless ALLOW_CSV_FALLBACK).
# ===========================================================================
wbx_ensure_openxlsx <- function() {
  if (requireNamespace("openxlsx", quietly = TRUE)) return(TRUE)
  log_msg("openxlsx not installed - attempting install.packages('openxlsx')...")
  tryCatch(utils::install.packages("openxlsx", repos = getOption("repos"), quiet = TRUE),
           error = function(e) log_msg("  openxlsx install failed: ", conditionMessage(e)))
  requireNamespace("openxlsx", quietly = TRUE)
}

# ===========================================================================
# Excel writer. Writes ONE .xlsx via openxlsx. If openxlsx is unavailable it
# fails closed (stop) unless allow_csv=TRUE, in which case it emits one CSV per
# table as an explicit, opt-in degraded mode.
# A "sheet" is list(name, title, subtitle=NULL, narrative=character(), tables=
# named list of data.frames or list(caption, df)).
# ===========================================================================
wbx_write_workbook <- function(sheets, xlsx_path, csv_dir, stamp, allow_csv = FALSE) {
  san <- function(x) gsub("[^A-Za-z0-9]+", "_", x)
  if (!requireNamespace("openxlsx", quietly = TRUE)) {
    if (!isTRUE(allow_csv))
      stop("openxlsx is required to build the Excel workbook, but it is not ",
           "installed and could not be installed. Install it (install.packages",
           "('openxlsx')) and re-run, or set ALLOW_CSV_FALLBACK=TRUE to emit one CSV ",
           "per table instead of the .xlsx.")
    log_msg("WARNING: openxlsx unavailable and ALLOW_CSV_FALLBACK set - emitting one ",
            "CSV per table INSTEAD of the single .xlsx deliverable. Install openxlsx ",
            "for the single-file workbook.")
    for (s in sheets) for (nm in names(s$tables)) {
      entry <- s$tables[[nm]]; df <- entry
      if (is.list(entry) && !is.data.frame(entry)) df <- entry$df
      if (is.data.frame(df) && nrow(df) > 0) {
        f <- file.path(csv_dir, sprintf("lot_followup_qs_%s__%s_%s.csv",
                                        san(s$name), san(nm), stamp))
        utils::write.csv(df, f, row.names = FALSE)
        log_msg("  wrote ", f, " (", nrow(df), " rows)")
      }
    }
    return(invisible(FALSE))
  }
  ox <- function(f) getExportedValue("openxlsx", f)
  wb <- ox("createWorkbook")()
  st_title <- ox("createStyle")(fontSize = 14, textDecoration = "bold",
                                fontColour = "#FFFFFF", fgFill = "#1F3864")
  st_sub   <- ox("createStyle")(fontColour = "#FFFFFF", fgFill = "#2E5496",
                                textDecoration = "italic")
  st_narr  <- ox("createStyle")(wrapText = TRUE, valign = "top")
  st_cap   <- ox("createStyle")(textDecoration = "bold", fgFill = "#D6E0F0")
  st_hdr   <- ox("createStyle")(textDecoration = "bold", fontColour = "#FFFFFF",
                                fgFill = "#2E5496", border = "TopBottomLeftRight",
                                halign = "left")
  for (s in sheets) {
    sn <- substr(gsub("[\\/?*:\\[\\]]", "", s$name), 1, 31)
    ox("addWorksheet")(wb, sn)
    r <- 1L
    ox("writeData")(wb, sn, s$title, startRow = r, startCol = 1)
    ox("addStyle")(wb, sn, st_title, rows = r, cols = 1:10, gridExpand = TRUE)
    r <- r + 1L
    if (!is.null(s$subtitle)) {
      ox("writeData")(wb, sn, s$subtitle, startRow = r, startCol = 1)
      ox("addStyle")(wb, sn, st_sub, rows = r, cols = 1:10, gridExpand = TRUE)
      r <- r + 1L
    }
    r <- r + 1L
    for (line in s$narrative %||% character()) {
      ox("writeData")(wb, sn, line, startRow = r, startCol = 1)
      ox("addStyle")(wb, sn, st_narr, rows = r, cols = 1, gridExpand = TRUE)
      r <- r + 1L
    }
    r <- r + 1L
    for (nm in names(s$tables %||% list())) {
      entry <- s$tables[[nm]]
      cap <- nm; df <- entry
      if (is.list(entry) && !is.data.frame(entry)) { cap <- entry$caption %||% nm; df <- entry$df }
      ox("writeData")(wb, sn, cap, startRow = r, startCol = 1)
      ox("addStyle")(wb, sn, st_cap, rows = r, cols = 1:10, gridExpand = TRUE)
      r <- r + 1L
      if (is.data.frame(df) && nrow(df) > 0) {
        ox("writeData")(wb, sn, df, startRow = r, startCol = 1,
                        headerStyle = st_hdr, withFilter = FALSE)
        r <- r + nrow(df) + 2L
      } else {
        ox("writeData")(wb, sn, "(no rows / not available)", startRow = r, startCol = 1)
        r <- r + 2L
      }
    }
    ox("setColWidths")(wb, sn, cols = 1:14, widths = "auto")
  }
  ox("saveWorkbook")(wb, xlsx_path, overwrite = TRUE)
  log_msg("wrote workbook -> ", xlsx_path, " (", length(sheets), " sheets)")
  invisible(TRUE)
}

# Best-effort optional table: return the data on success, else a one-row table
# NAMING the failure. Assigning NULL into a list element would DELETE it (R
# semantics), so an unavailable optional pull would vanish with no trace; this
# keeps a visible "unavailable" row in the workbook (and logs the reason).
best_effort <- function(expr, label) {
  r <- tryCatch(expr, error = function(e) {
    log_msg("  NOTE: '", label, "' unavailable - ", conditionMessage(e))
    data.frame(status = sprintf("'%s' unavailable: %s", label, conditionMessage(e)),
               stringsAsFactors = FALSE)
  })
  if (is.null(r))
    data.frame(status = sprintf("'%s' returned no data (optional pull unavailable this run)", label),
               stringsAsFactors = FALSE)
  else r
}

num <- function(x) suppressWarnings(as.numeric(x))
pct1 <- function(x, d) if (isTRUE(num(d) > 0)) round(100 * num(x) / num(d), 1) else NA_real_

# ---------------------------------------------------------------------------
# Resolve the agent abbreviations from cl_mma_codelist.csv by medication-full
# name, so a codelist abbreviation change does not silently zero out an answer.
# Mirrors vqs_resolve_agent_tokens (which resolves POMA/ELOT/PANO). Falls back
# to the study-standard tokens.
# ---------------------------------------------------------------------------
resolve_lot_tokens <- function(con) {
  out <- list(dara = "DARA", bort = "BORT", lena = "LENA", melp = "MELP", notes = character(0))
  ok <- tryCatch({ vqs_build_mma_codelist(con); TRUE }, error = function(e) FALSE)
  if (!ok) {
    out$notes <- "mma_codelist unavailable; using default tokens (DARA/BORT/LENA/MELP)."
    return(out)
  }
  pick <- function(like, dflt) {
    df <- tryCatch(db_q(con, glue("
      SELECT CL_MED_ABBR, count(*) AS n
      FROM mma_codelist
      WHERE lower(CL_MEDICATION_FULL) LIKE '%{like}%'
      GROUP BY CL_MED_ABBR ORDER BY n DESC")), error = function(e) NULL)
    if (is.null(df) || nrow(df) == 0) return(dflt)
    toupper(trimws(df$CL_MED_ABBR[1]))
  }
  out$dara <- pick("daratumumab", "DARA")
  out$bort <- pick("bortezomib",  "BORT")
  out$lena <- pick("lenalidomid", "LENA")
  out$melp <- pick("melphalan",   "MELP")
  out$notes <- sprintf("Resolved tokens from cl_mma_codelist.csv: DARA=%s, BORT=%s, LENA=%s, MELP=%s.",
                       out$dara, out$bort, out$lena, out$melp)
  out
}

# non-empty agent tokens of a LOT_BASE_MEDS regimen string (steroids are already
# excluded from LOT_BASE_MEDS by the engine, so this is the MM-agent set).
MEDS_ARR <- "filter(split(LOT_BASE_MEDS, ' '), x -> length(x) > 0)"

# Known steroid abbreviations across the repo's codelists: the dashboard
# STEROID_TOKENS (DEX/DEXA/DEXAMETHASONE/PRED/PREDNISONE, 05_regimen_dashboard.R),
# steroid_codes.csv (mapped_to DEXA/PRED) and the engine rollup (DEX). Used as the
# FIXED reference set for the LOT_BASE_MEDS audit so the check is a real test that
# cannot pass vacuously (it does NOT depend on MAP_MED_CLASS='STEROID' being
# populated, which R/validation_qs.R warns may be empty for cl_mma_codelist.csv).
STEROID_TOKENS <- c("DEX", "DEXA", "DEXAMETHASONE", "DEXAMETH",
                    "PRED", "PREDNISONE", "PREDNISOLONE",
                    "METHYLPRED", "METHYLPREDNISOLONE", "MPRED")

# ===========================================================================
# Q1 - Steroids are already excluded from every LOT rule. Evidence, robustly:
#   (a) AUDIT: no known steroid token appears in any LOT_BASE_MEDS regimen
#       (checked against the FIXED STEROID_TOKENS set -> a real, non-vacuous test).
#   (b) VOCABULARY: the full set of agent tokens that DO appear in LOT_BASE_MEDS,
#       so the reader can see directly there are no steroid tokens.
#   (c) MAP CLASS INVENTORY: the actual MAP_MED_CLASS counts on THIS cohort
#       (cohort-scoped), so whether steroids reach the mapped-claims layer at all
#       is reported factually rather than assumed - and never enters a LOT.
# ===========================================================================
q1_steroid_audit <- function(con, lot_long, map_tbl) {
  ster_arr <- paste(sprintf("'%s'", STEROID_TOKENS), collapse = ", ")

  audit <- best_effort(db_q(con, glue("
    WITH ll AS (
      SELECT {MEDS_ARR} AS meds
      FROM {lot_long}
      WHERE LOT_BASE_MEDS IS NOT NULL AND trim(LOT_BASE_MEDS) <> ''
    )
    SELECT count(*)                                                              AS n_lot_regimen_rows,
           sum(CASE WHEN size(array_intersect(meds, array({ster_arr}))) > 0
                    THEN 1 ELSE 0 END)                                           AS n_rows_with_steroid_token
    FROM ll")), "steroid-in-regimen audit (must be 0)")

  vocab <- best_effort(db_q(con, glue("
    WITH base AS (
      SELECT cast(PATID as string) AS PATID, {MEDS_ARR} AS meds
      FROM {lot_long}
      WHERE LOT_BASE_MEDS IS NOT NULL AND trim(LOT_BASE_MEDS) <> ''
    )
    SELECT upper(tok)             AS agent_token,
           count(*)              AS n_regimen_rows,
           count(DISTINCT PATID) AS n_patients,
           CASE WHEN array_contains(array({ster_arr}), upper(tok))
                THEN 'STEROID - should NOT appear' ELSE '' END AS note
    FROM base LATERAL VIEW explode(meds) t AS tok
    GROUP BY upper(tok) ORDER BY n_patients DESC")), "LOT_BASE_MEDS token vocabulary")

  # Cohort-scoped MAP class inventory: restrict to the selected cohort's patients
  # so the counts match the sheet's cohort label (MAP_STACKED is patient-level and
  # shared across cohorts).
  map_classes <- best_effort(db_q(con, glue("
    WITH coh AS (SELECT DISTINCT cast(PATID as string) AS PATID FROM {lot_long})
    SELECT upper(coalesce(m.MAP_MED_CLASS, '(null)')) AS map_med_class,
           count(*)                                   AS n_map_rows,
           count(DISTINCT m.PATID)                    AS n_patients
    FROM {map_tbl} m JOIN coh ON cast(m.PATID as string) = coh.PATID
    GROUP BY upper(coalesce(m.MAP_MED_CLASS, '(null)')) ORDER BY n_map_rows DESC")),
    "MAP class inventory (cohort-scoped)")

  list(audit = audit, vocab = vocab, map_classes = map_classes)
}

# ===========================================================================
# Q2 - 1L DARA+BORT dual therapy: difference in the two agents' start dates.
# Denominator = LOT1 patients whose regimen is EXACTLY {DARA, BORT} (2 agents,
# no other MM agent). Each agent's start = the first MAP_STACKED segment of that
# agent inside the LOT1 induction window [LOT1_START, LOT1_START + W1 - 1] (the
# window that defines regimen membership). gap = BORT_start - DARA_start (days):
# >0 => DARA first, <0 => BORT first, 0 => same day.
# ===========================================================================
q2_dara_bort_gap <- function(con, lot_long, map_tbl, dara, bort, w1) {
  base_cte <- glue("
    WITH l1 AS (
      SELECT cast(PATID as string) AS PATID, cast(LOT_START_DT as date) AS L1,
             {MEDS_ARR} AS meds
      FROM {lot_long}
      WHERE LOT_NUM = 1 AND LOT_BASE_MEDS IS NOT NULL AND trim(LOT_BASE_MEDS) <> ''
    ),
    dual AS (
      SELECT PATID, L1 FROM l1
      WHERE size(meds) = 2 AND array_contains(meds, '{dara}') AND array_contains(meds, '{bort}')
    ),
    dara_dt AS (
      SELECT cast(m.PATID as string) AS PATID, min(cast(m.MAP_START_DT as date)) AS d_dara
      FROM {map_tbl} m JOIN dual d ON cast(m.PATID as string) = d.PATID
      WHERE upper(trim(m.MAP_MED_TYPE)) = '{dara}'
        AND cast(m.MAP_START_DT as date) BETWEEN d.L1 AND date_add(d.L1, {w1} - 1)
      GROUP BY cast(m.PATID as string)
    ),
    bort_dt AS (
      SELECT cast(m.PATID as string) AS PATID, min(cast(m.MAP_START_DT as date)) AS d_bort
      FROM {map_tbl} m JOIN dual d ON cast(m.PATID as string) = d.PATID
      WHERE upper(trim(m.MAP_MED_TYPE)) = '{bort}'
        AND cast(m.MAP_START_DT as date) BETWEEN d.L1 AND date_add(d.L1, {w1} - 1)
      GROUP BY cast(m.PATID as string)
    ),
    g AS (
      SELECT d.PATID,
             datediff(bd.d_bort, dd.d_dara)      AS gap_bort_minus_dara,
             abs(datediff(bd.d_bort, dd.d_dara)) AS abs_gap
      FROM dual d JOIN dara_dt dd USING (PATID) JOIN bort_dt bd USING (PATID)
    )")

  # Denominator (exactly DARA+BORT) kept separate from the gap aggregates so no
  # single SELECT mixes a scalar subquery with aggregates (portable across Spark).
  n_dual <- num(db_q(con, glue("{base_cte} SELECT count(*) AS n FROM dual"))$n[1])

  summ <- db_q(con, glue("{base_cte}
    SELECT
      count(*)                                                     AS n_with_both_start_dates,
      sum(CASE WHEN abs_gap = 0 THEN 1 ELSE 0 END)                 AS n_same_day,
      sum(CASE WHEN gap_bort_minus_dara > 0 THEN 1 ELSE 0 END)     AS n_dara_first,
      sum(CASE WHEN gap_bort_minus_dara < 0 THEN 1 ELSE 0 END)     AS n_bort_first,
      round(avg(abs_gap), 1)                                       AS mean_abs_gap_days,
      percentile_approx(abs_gap, 0.5)                              AS median_abs_gap_days,
      percentile_approx(abs_gap, 0.25)                             AS p25_abs_gap_days,
      percentile_approx(abs_gap, 0.75)                             AS p75_abs_gap_days,
      percentile_approx(abs_gap, 0.9)                              AS p90_abs_gap_days,
      max(abs_gap)                                                 AS max_abs_gap_days
    FROM g"))

  buckets <- db_q(con, glue("{base_cte}
    SELECT
      sum(CASE WHEN abs_gap = 0            THEN 1 ELSE 0 END) AS d_same_day,
      sum(CASE WHEN abs_gap BETWEEN 1 AND 7   THEN 1 ELSE 0 END) AS d_1_7,
      sum(CASE WHEN abs_gap BETWEEN 8 AND 30  THEN 1 ELSE 0 END) AS d_8_30,
      sum(CASE WHEN abs_gap BETWEEN 31 AND 59 THEN 1 ELSE 0 END) AS d_31_59
    FROM g"))

  n_both <- num(summ$n_with_both_start_dates[1])

  overview <- data.frame(
    metric = c(
      "1L DARA+BORT dual-therapy patients (denominator)",
      "  ... with a start date for BOTH agents in the induction window",
      "Started on the SAME day",
      "DARA started first (BORT added later)",
      "BORT started first (DARA added later)",
      "Mean absolute gap (days)",
      "Median absolute gap (days)",
      "25th percentile absolute gap (days)",
      "75th percentile absolute gap (days)",
      "90th percentile absolute gap (days)",
      "Max absolute gap (days)"),
    value = c(
      as.integer(n_dual), as.integer(n_both),
      as.integer(num(summ$n_same_day[1])),
      as.integer(num(summ$n_dara_first[1])),
      as.integer(num(summ$n_bort_first[1])),
      num(summ$mean_abs_gap_days[1]),
      num(summ$median_abs_gap_days[1]),
      num(summ$p25_abs_gap_days[1]),
      num(summ$p75_abs_gap_days[1]),
      num(summ$p90_abs_gap_days[1]),
      num(summ$max_abs_gap_days[1])),
    pct_of_dual = c(
      NA_real_, pct1(n_both, n_dual),
      pct1(summ$n_same_day[1],  n_dual), pct1(summ$n_dara_first[1], n_dual),
      pct1(summ$n_bort_first[1], n_dual),
      NA_real_, NA_real_, NA_real_, NA_real_, NA_real_, NA_real_),
    stringsAsFactors = FALSE)

  dist <- data.frame(
    start_date_gap = c("Same day (0)", "1-7 days", "8-30 days", "31-59 days"),
    n_patients = as.integer(c(num(buckets$d_same_day[1]), num(buckets$d_1_7[1]),
                              num(buckets$d_8_30[1]), num(buckets$d_31_59[1]))),
    stringsAsFactors = FALSE)
  dist$pct_of_pairs <- vapply(dist$n_patients, function(x) pct1(x, n_both), numeric(1))

  list(overview = overview, distribution = dist, n_dual = n_dual, n_both = n_both)
}

# ===========================================================================
# Q3 - LENA+DARA dual-therapy share in 1L and 2L. "exact dual" = regimen is
# EXACTLY {DARA, LENA}; "contains both (any combo)" = both present, possibly with
# other agents (context, since Peter expected a meaningful share).
# ===========================================================================
q3_lena_dara <- function(con, lot_long, dara, lena) {
  # Denominator = ALL distinct patients reaching each line (LOT_NUM), including
  # ALLO/CART singleton lines that carry an empty/NULL LOT_BASE_MEDS, so
  # n_lot_patients matches the Read Me's per-line counts. A NULL/empty regimen
  # never matches a DARA/LENA numerator (size()/array_contains yield NULL -> the
  # CASE is not counted), but the patient still counts in the denominator.
  r <- db_q(con, glue("
    WITH l AS (
      SELECT LOT_NUM, cast(PATID as string) AS PATID, {MEDS_ARR} AS meds
      FROM {lot_long}
      WHERE LOT_NUM IN (1, 2)
    )
    SELECT LOT_NUM,
           count(DISTINCT PATID) AS n_lot_patients,
           count(DISTINCT CASE WHEN size(meds) = 2 AND array_contains(meds, '{dara}')
                                AND array_contains(meds, '{lena}') THEN PATID END) AS n_dara_lena_dual,
           count(DISTINCT CASE WHEN array_contains(meds, '{dara}')
                                AND array_contains(meds, '{lena}') THEN PATID END) AS n_contains_both_any
    FROM l GROUP BY LOT_NUM ORDER BY LOT_NUM"))
  if (nrow(r) == 0) return(data.frame(status = "No LOT1/LOT2 regimen rows found.", stringsAsFactors = FALSE))
  data.frame(
    line = paste0("LOT", r$LOT_NUM),
    n_line_patients          = as.integer(num(r$n_lot_patients)),
    n_dara_lena_dual         = as.integer(num(r$n_dara_lena_dual)),
    pct_dara_lena_dual       = mapply(pct1, r$n_dara_lena_dual, r$n_lot_patients),
    n_contains_dara_and_lena = as.integer(num(r$n_contains_both_any)),
    pct_contains_both_any    = mapply(pct1, r$n_contains_both_any, r$n_lot_patients),
    stringsAsFactors = FALSE)
}

# ===========================================================================
# Q4 - Melphalan in 2L: calendar timing. LOT2 start year x MELP-containing share,
# a before/after-2017 summary, and the top MELP-containing 2L regimen strings.
# ===========================================================================
q4_melp_2l <- function(con, lot_long, melp) {
  by_year <- db_q(con, glue("
    WITH l2 AS (
      SELECT year(cast(LOT_START_DT as date)) AS yr, {MEDS_ARR} AS meds
      FROM {lot_long}
      WHERE LOT_NUM = 2 AND LOT_START_DT IS NOT NULL
        AND LOT_BASE_MEDS IS NOT NULL AND trim(LOT_BASE_MEDS) <> ''
    )
    SELECT yr AS lot2_start_year,
           count(*)                                                    AS n_lot2_total,
           sum(CASE WHEN array_contains(meds, '{melp}') THEN 1 ELSE 0 END) AS n_lot2_with_melp,
           round(100.0 * sum(CASE WHEN array_contains(meds, '{melp}') THEN 1 ELSE 0 END)
                 / count(*), 1)                                        AS pct_melp
    FROM l2 GROUP BY yr ORDER BY yr"))

  era <- db_q(con, glue("
    WITH l2 AS (
      SELECT year(cast(LOT_START_DT as date)) AS yr, {MEDS_ARR} AS meds
      FROM {lot_long}
      WHERE LOT_NUM = 2 AND LOT_START_DT IS NOT NULL
        AND LOT_BASE_MEDS IS NOT NULL AND trim(LOT_BASE_MEDS) <> ''
    ),
    melp AS (SELECT yr FROM l2 WHERE array_contains(meds, '{melp}'))
    SELECT
      (SELECT count(*) FROM melp)                                    AS n_lot2_with_melp_total,
      (SELECT count(*) FROM melp WHERE yr <= 2017)                   AS n_melp_2017_and_earlier,
      (SELECT count(*) FROM melp WHERE yr >= 2018)                   AS n_melp_2018_and_later,
      (SELECT percentile_approx(yr, 0.5) FROM melp)                  AS median_melp_lot2_year,
      (SELECT count(*) FROM l2)                                      AS n_lot2_total"))
  n_melp <- num(era$n_lot2_with_melp_total[1])
  era_df <- data.frame(
    metric = c(
      "MELP-containing 2L regimens (all years)",
      "  ... with LOT2 starting in 2017 or earlier",
      "  ... with LOT2 starting in 2018 or later",
      "Median LOT2 start year among MELP-containing 2L regimens",
      "All 2L regimens (any agent), all years"),
    value = c(as.integer(n_melp),
              as.integer(num(era$n_melp_2017_and_earlier[1])),
              as.integer(num(era$n_melp_2018_and_later[1])),
              as.integer(num(era$median_melp_lot2_year[1])),
              as.integer(num(era$n_lot2_total[1]))),
    pct_of_melp = c(NA_real_,
                    pct1(era$n_melp_2017_and_earlier[1], n_melp),
                    pct1(era$n_melp_2018_and_later[1], n_melp),
                    NA_real_, NA_real_),
    stringsAsFactors = FALSE)

  top_reg <- db_q(con, glue("
    WITH l2 AS (
      SELECT LOT_BASE_MEDS, {MEDS_ARR} AS meds
      FROM {lot_long}
      WHERE LOT_NUM = 2 AND LOT_BASE_MEDS IS NOT NULL AND trim(LOT_BASE_MEDS) <> ''
    )
    SELECT LOT_BASE_MEDS AS lot2_regimen, count(*) AS n_patients
    FROM l2 WHERE array_contains(meds, '{melp}')
    GROUP BY LOT_BASE_MEDS ORDER BY n_patients DESC LIMIT 10"))

  list(by_year = by_year, era = era_df, top_regimens = top_reg)
}

# ===========================================================================
# Q5 - CAR-T clarifications. Empirical answers to the five sub-questions, using
# LOT1_SCT.FIRST_CART_DT (>= LOT1_START by construction) and the same
# during/closing window vqs_q6_cart uses (upper bound = LOT1_BASE_END_DT, +1d
# ONLY when the end reason is SCT_CART/CART_INIT). w1 = LOT1 induction window.
# ===========================================================================
q5_cart_clarifications <- function(con, lot_long, sct_tbl, w1) {
  during_ub <- "CASE WHEN END_REASON IN ('SCT_CART','CART_INIT') THEN date_add(L1_END, 1) ELSE L1_END END"

  # (a)+(c)+(d): relationships among the CAR-T windows, on one pass.
  rel <- db_q(con, glue("
    WITH l1 AS (
      SELECT cast(PATID as string) AS PATID, cast(LOT_START_DT as date) AS L1,
             cast(LOT_BASE_END_DT as date) AS L1_END, LOT_BASE_END_REASON AS END_REASON
      FROM {lot_long} WHERE LOT_NUM = 1
    ),
    sct AS (
      SELECT cast(PATID as string) AS PATID, min(cast(FIRST_CART_DT as date)) AS CART_DT
      FROM {sct_tbl} WHERE FIRST_CART_DT IS NOT NULL GROUP BY cast(PATID as string)
    ),
    j AS (
      SELECT l.PATID, l.L1, l.L1_END, l.END_REASON, s.CART_DT,
             CASE WHEN s.CART_DT IS NOT NULL AND s.CART_DT BETWEEN l.L1 AND date_add(l.L1, {w1} - 1)
                  THEN 1 ELSE 0 END AS in60,
             CASE WHEN s.CART_DT IS NOT NULL AND s.CART_DT BETWEEN l.L1 AND ({during_ub})
                  THEN 1 ELSE 0 END AS during
      FROM l1 l LEFT JOIN sct s ON s.PATID = l.PATID
    )
    SELECT
      sum(in60)                                                       AS n_within_60d_after,
      sum(during)                                                     AS n_during_or_closing,
      sum(CASE WHEN in60 = 1 AND during = 1 THEN 1 ELSE 0 END)        AS n_in_both,
      sum(CASE WHEN in60 = 1 AND during = 0 THEN 1 ELSE 0 END)        AS n_60d_not_during,
      sum(CASE WHEN in60 = 0 AND during = 1 THEN 1 ELSE 0 END)        AS n_during_not_60d,
      sum(CASE WHEN CART_DT IS NOT NULL THEN 1 ELSE 0 END)            AS n_any_cart_on_after_lot1,
      sum(CASE WHEN CART_DT IS NOT NULL AND during = 0 THEN 1 ELSE 0 END) AS n_cart_strictly_later,
      sum(CASE WHEN CART_DT = L1 THEN 1 ELSE 0 END)                   AS n_cart_on_lot1_start
    FROM j"))

  # (e): does the closing CAR-T become the 2L start date? Compare LOT1-ended-by-
  # CAR-T patients' LOT1 end vs FIRST_CART_DT-1 and LOT2 start vs FIRST_CART_DT.
  seq <- db_q(con, glue("
    WITH l1 AS (
      SELECT cast(PATID as string) AS PATID, cast(LOT_BASE_END_DT as date) AS L1_END,
             LOT_BASE_END_REASON AS END_REASON
      FROM {lot_long} WHERE LOT_NUM = 1
    ),
    l2 AS (
      SELECT cast(PATID as string) AS PATID, cast(LOT_START_DT as date) AS L2,
             LOT_START_TYPE AS L2_TYPE
      FROM {lot_long} WHERE LOT_NUM = 2
    ),
    sct AS (
      SELECT cast(PATID as string) AS PATID, min(cast(FIRST_CART_DT as date)) AS CART_DT
      FROM {sct_tbl} WHERE FIRST_CART_DT IS NOT NULL GROUP BY cast(PATID as string)
    ),
    e AS (
      SELECT l1.PATID, l1.L1_END, s.CART_DT, l2.L2, l2.L2_TYPE
      FROM l1 JOIN sct s ON s.PATID = l1.PATID
              LEFT JOIN l2 ON l2.PATID = l1.PATID
      WHERE l1.END_REASON IN ('SCT_CART','CART_INIT')
    )
    SELECT
      count(*)                                                             AS n_lot1_ended_by_cart,
      sum(CASE WHEN L1_END = date_sub(CART_DT, 1) THEN 1 ELSE 0 END)       AS n_lot1_ends_day_before_cart,
      sum(CASE WHEN L2 IS NOT NULL THEN 1 ELSE 0 END)                      AS n_with_a_lot2,
      sum(CASE WHEN L2 = CART_DT THEN 1 ELSE 0 END)                        AS n_lot2_starts_on_cart_date,
      sum(CASE WHEN L2_TYPE = 'CART' THEN 1 ELSE 0 END)                    AS n_lot2_start_type_cart
    FROM e"))

  na_i <- function(x) { v <- num(x); if (length(v) == 0 || is.na(v)) NA_integer_ else as.integer(v) }
  data.frame(
    check = c(
      "(a) CAR-T within 60d after LOT1 start",
      "(a) CAR-T during or closing LOT1",
      "(a)   ... in BOTH windows",
      "(a)   ... within-60d but NOT during/closing (subset test: 0 => 60d is a subset)",
      "(a)   ... during/closing but NOT within-60d (later closing CAR-T)",
      "(c) Any CAR-T on/after LOT1 start (distinct patients; incl. later lines)",
      "(c)   ... occurring strictly after LOT1 ends (i.e. on 2L+, not during LOT1)",
      "(d) CAR-T dated exactly ON the LOT1 start date",
      "(e) LOT1 ended by CAR-T (SCT_CART / CART_INIT)",
      "(e)   ... LOT1 ends the day BEFORE the CAR-T (FIRST_CART_DT - 1)",
      "(e)   ... has a LOT2 record",
      "(e)   ... whose LOT2 START DATE equals the CAR-T date",
      "(e)   ... whose LOT2 start TYPE is 'CART'"),
    n_patients = c(
      na_i(rel$n_within_60d_after[1]), na_i(rel$n_during_or_closing[1]),
      na_i(rel$n_in_both[1]), na_i(rel$n_60d_not_during[1]), na_i(rel$n_during_not_60d[1]),
      na_i(rel$n_any_cart_on_after_lot1[1]), na_i(rel$n_cart_strictly_later[1]),
      na_i(rel$n_cart_on_lot1_start[1]),
      na_i(seq$n_lot1_ended_by_cart[1]), na_i(seq$n_lot1_ends_day_before_cart[1]),
      na_i(seq$n_with_a_lot2[1]), na_i(seq$n_lot2_starts_on_cart_date[1]),
      na_i(seq$n_lot2_start_type_cart[1])),
    stringsAsFactors = FALSE)
}

# ===========================================================================
main <- function() {
  stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")

  # Fail closed on the Excel engine BEFORE running any query, so a missing
  # openxlsx does not waste warehouse time and cannot masquerade as success.
  allow_csv <- tolower(Sys.getenv("ALLOW_CSV_FALLBACK", unset = "")) %in% c("1", "true", "yes")
  have_xlsx <- wbx_ensure_openxlsx()
  if (!have_xlsx && !allow_csv)
    stop("openxlsx is required to build the Excel workbook, and it is not ",
         "installed / could not be installed here. Run install.packages('openxlsx') ",
         "and re-run, or set ALLOW_CSV_FALLBACK=TRUE to emit one CSV per table instead.")
  if (!have_xlsx)
    log_msg("WARNING: openxlsx unavailable; ALLOW_CSV_FALLBACK is set -> CSV-per-table ",
            "degraded mode (NOT the .xlsx deliverable).")

  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  out_dir <- cfg$output_dir
  if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  stamp <- format(Sys.time(), "%Y%m%d_%H%M%S")

  # ---- Cohort selection --------------------------------------------------
  # Default = NDMM study cohort (the study team asked to see NDMM first). Set
  # LOT_COHORT=FULL for the full LOT_LONG cohort (all LOT1 patients).
  cohort_mode <- toupper(Sys.getenv("LOT_COHORT", unset = "NDMM"))
  if (cohort_mode == "FULL") {
    lot_long <- wrk("LOT_LONG")
    cohort_label <- "full LOT cohort (all LOT1 patients)"
  } else {
    cohort_mode <- "NDMM"
    lot_long <- wrk("NDMM_LOT_LONG_FILT")
    cohort_label <- "NDMM newly-diagnosed 1L study cohort"
  }
  map_tbl <- wrk("MAP_STACKED")
  sct_tbl <- wrk("LOT1_SCT")

  log_msg(SEP); log_msg("LOT follow-up study-team questions [", cohort_label, "] -> single Excel workbook"); log_msg(SEP)
  if (!vqs_readable(con, lot_long)) {
    if (cohort_mode == "NDMM")
      stop("Cannot read ", lot_long, ". Run 06_ndmm_dashboard.R first to persist ",
           "NDMM_LOT_LONG_FILT (LOT_LONG restricted to the NDMM study cohort), or set ",
           "LOT_COHORT=FULL to run on LOT_LONG.")
    stop("Cannot read ", lot_long, ". Build the LOT pipeline (02_lot1.R / 03_lot2_5.R) first.")
  }
  have_map <- vqs_readable(con, map_tbl)
  have_sct <- vqs_readable(con, sct_tbl)
  if (!have_map) log_msg("WARNING: ", map_tbl, " not readable - Q1 residual / Q2 start-date gap will note the gap.")
  if (!have_sct) log_msg("WARNING: ", sct_tbl, " not readable - Q5 CAR-T tables will note the gap.")

  tok <- resolve_lot_tokens(con)
  log_msg(paste(tok$notes, collapse = " "))
  bounds   <- vqs_obs_bounds_src(con)
  cart_raw <- if (have_sct) tryCatch(vqs_build_raw_cart_dates(con, lot_long, bounds$sql),
                                     error = function(e) NULL) else NULL

  n_lot1 <- num(db_q(con, glue(
    "SELECT count(DISTINCT PATID) n FROM {lot_long} WHERE LOT_NUM = 1"))$n)
  n_lot2 <- num(db_q(con, glue(
    "SELECT count(DISTINCT PATID) n FROM {lot_long} WHERE LOT_NUM = 2"))$n)
  log_msg(sprintf("Cohort denominators: LOT1 = %s patients, LOT2 = %s patients.",
                  format(n_lot1, big.mark = ","), format(n_lot2, big.mark = ",")))

  sheets <- list()
  add_sheet <- function(...) sheets[[length(sheets) + 1L]] <<- list(...)

  # ---- Read Me -----------------------------------------------------------
  add_sheet(name = "Read Me", title = paste0("LOT follow-up study-team questions - ", cohort_label),
    subtitle = paste0("Generated ", stamp, " by lot_followup_qs.R against ", cfg$work_schema),
    narrative = c(
      sprintf("Cohort: %s. LOT1 = %s patients; LOT2 = %s patients. Switch with LOT_COHORT=FULL / NDMM.",
              cohort_label, format(n_lot1, big.mark = ","), format(n_lot2, big.mark = ",")),
      tok$notes,
      "Q1 = steroids are ALREADY excluded from every LOT rule (start / induction / regimen / discontinuation / add-med). The audit proves NO steroid token appears in any LOT_BASE_MEDS regimen; the only residual steroid surfaces are descriptive (the steroid_codes.csv-based dashboard Steroids panel and the steroid-timing analyses).",
      "Q2 = among 1L DARA+BORT dual-therapy patients (exactly two agents), the difference between the DARA and BORT start dates (same-day vs staggered; which comes first; gap distribution).",
      "Q3 = LENA+DARA dual-therapy share in 1L and 2L (exact dual + a 'contains both, any combination' context column).",
      "Q4 = Melphalan in 2L by LOT2 start year, with a pre-/post-2017 summary and the top MELP-containing 2L regimens.",
      "Q5 = CAR-T clarifications: the CAR-T-relative-to-LOT1 metric table recomputed on THIS cohort, then empirical answers to the five CAR-T questions.",
      "Regimen strings (LOT_BASE_MEDS) are space-separated, alphabetically-sorted MM-agent tokens; steroids are excluded by construction, so 'DARA+BORT dual therapy, no other agents' means no other MM agent (a backbone steroid does not change the pairing).",
      "Operational definitions (CAR-T windows, tokens, induction window) are shared with R/validation_qs.R (single source of truth)."),
    tables = list())

  # ---- Q1: steroids ------------------------------------------------------
  q1_tables <- list(); q1_notes <- character()
  if (have_map) {
    q1 <- q1_steroid_audit(con, lot_long, map_tbl)
    q1_tables[["Audit - any known steroid token in a LOT_BASE_MEDS regimen (n_rows_with_steroid_token MUST be 0)"]] <- q1$audit
    q1_tables[["Full agent-token vocabulary appearing in LOT_BASE_MEDS (confirm: no steroid token)"]] <- q1$vocab
    q1_tables[["MAP layer class inventory (cohort-scoped; shows whether steroids reach the mapped-claims layer at all)"]] <- q1$map_classes
  } else {
    q1_notes <- c(q1_notes, paste0(map_tbl, " not readable - the MAP class inventory is skipped; the LOT_BASE_MEDS audit still runs off ", lot_long, "."))
    q1 <- q1_steroid_audit(con, lot_long, map_tbl)  # audit/vocab only need lot_long; map_classes will note the gap
    q1_tables[["Audit - any known steroid token in a LOT_BASE_MEDS regimen (n_rows_with_steroid_token MUST be 0)"]] <- q1$audit
    q1_tables[["Full agent-token vocabulary appearing in LOT_BASE_MEDS (confirm: no steroid token)"]] <- q1$vocab
  }
  q1_notes <- c(q1_notes,
    "Bottom line: steroids are ALREADY turned off in the LOT algorithm. In 02_lot1.R the LOT1 start, induction meds, base regimen, discontinuation and add-med steps all filter MAP_MED_CLASS <> 'STEROID' (the 'H1 fix'); lot2_5_base.R does the same for the LOT2-5 start/regimen candidates. So a steroid never sets a LOT start, never joins a regimen, and never triggers a new line.",
    paste0("AUDIT (first table): every LOT_BASE_MEDS regimen string (all lines) is checked against the known steroid abbreviations (",
           paste(STEROID_TOKENS, collapse = "/"), "). n_rows_with_steroid_token MUST be 0; a non-zero value would mean a steroid leaked into a regimen and should be investigated. The full token vocabulary (second table) lets you confirm directly that the regimens contain only oncology agents."),
    "MAP layer (third table): the MAP_MED_CLASS inventory, scoped to this cohort, shows which classes reach the mapped-claims layer. Whether a STEROID class appears there depends on the medication codelist (cl_mma_codelist.csv); either way it never enters a LOT regimen - the audit is the proof.",
    "The residual steroid surfaces are DESCRIPTIVE only and never touch a LOT: (1) the dashboard 'Steroids panel' appends DEXA/PRED to a display-only LOT_BASE_MEDS_AUG using steroid_codes.csv (05_regimen_dashboard.R), and (2) the steroid-timing analyses (validation_qs.R Q3/Q4/Q5). To fully remove steroids end-to-end, empty steroid_codes.csv (which turns the dashboard augmentation into a passthrough) and skip the steroid-timing tabs; no re-run of the LOT assignment is required.")
  add_sheet(name = "Q1 Steroids off", title = "Q1 - Steroids are already excluded from the LOT",
    subtitle = paste0("Audit (regimen strings) + token vocabulary + MAP class inventory. Cohort: ", cohort_label, "."),
    narrative = q1_notes, tables = q1_tables)

  # ---- Q2: DARA+BORT start-date difference -------------------------------
  q2_tables <- list(); q2_notes <- character()
  if (have_map) {
    q2 <- best_effort(q2_dara_bort_gap(con, lot_long, map_tbl, tok$dara, tok$bort, VQS_W1),
                      "DARA+BORT start-date gap")
    if (is.data.frame(q2)) {
      q2_tables[["DARA+BORT dual therapy - start-date difference (overview)"]] <- q2
      q2_notes <- c(q2_notes, "q2 returned a status row (see table); the gap distribution is omitted.")
    } else {
      q2_tables[["DARA+BORT dual therapy - start-date difference (overview)"]] <- q2$overview
      q2_tables[["Absolute start-date gap distribution"]] <- q2$distribution
      q2_notes <- c(q2_notes,
        sprintf("Denominator: %s 1L patients whose regimen is EXACTLY DARA + BORT (no other MM agent).",
                format(as.integer(q2$n_dual), big.mark = ",")),
        sprintf("Each agent's start = the first MAP_STACKED segment of that agent inside the %d-day LOT1 induction window (the window that defines regimen membership). gap = BORT start - DARA start (days).", VQS_W1),
        "A large same-day count would support 'prescribed together'; a spread toward staggered starts (DARA first or BORT first) supports Peter's 'one and then the other, inside the induction window'.")
    }
  } else {
    q2_notes <- paste0(map_tbl, " not readable - per-agent start dates need MAP_STACKED; Q2 skipped.")
  }
  add_sheet(name = "Q2 DARA+BORT dates", title = "Q2 - 1L DARA+BORT: difference in agent start dates",
    subtitle = paste0("Among patients whose 1L regimen is exactly DARA + BORT (dual therapy, no other agents). Cohort: ",
                      cohort_label, "."),
    narrative = q2_notes, tables = q2_tables)

  # ---- Q3: LENA+DARA dual therapy ---------------------------------------
  q3_df <- best_effort(q3_lena_dara(con, lot_long, tok$dara, tok$lena), "LENA+DARA dual share")
  add_sheet(name = "Q3 LENA+DARA", title = "Q3 - LENA+DARA dual therapy share in 1L and 2L",
    subtitle = paste0("Exact dual = regimen is exactly DARA + LENA; 'contains both' allows other agents. Cohort: ",
                      cohort_label, "."),
    narrative = c(
      "pct_dara_lena_dual = share of that line's patients whose regimen is EXACTLY DARA + LENA (dual therapy).",
      "pct_contains_both_any = share whose regimen contains BOTH DARA and LENA in any combination (e.g. DARA+LENA+other) - the broader read of 'receiving this combo'.",
      "Denominators are distinct patients reaching each line (LOT1 / LOT2)."),
    tables = list("LENA+DARA share by line" = q3_df))

  # ---- Q4: Melphalan in 2L timing ---------------------------------------
  q4 <- best_effort(q4_melp_2l(con, lot_long, tok$melp), "Melphalan-in-2L timing")
  if (is.data.frame(q4)) {
    q4_tables <- list("Melphalan in 2L" = q4)
  } else {
    q4_tables <- list(
      "MELP-containing 2L regimens by LOT2 start year" = q4$by_year,
      "Pre-/post-2017 summary"                         = q4$era,
      "Top MELP-containing 2L regimen strings"         = q4$top_regimens)
  }
  add_sheet(name = "Q4 MELP in 2L", title = "Q4 - Melphalan in 2L: calendar timing",
    subtitle = paste0("Is MELP-in-2L concentrated before 2018? Cohort: ", cohort_label, "."),
    narrative = c(
      "n_lot2_with_melp / pct_melp = 2L regimens (that year) whose regimen contains MELP. The study team expects MELP to fade as a common 2L option after 2017.",
      "The summary table splits MELP-containing 2L regimens into LOT2-start <=2017 vs >=2018 and gives the median LOT2 start year.",
      "The regimen table lists the most common MELP-containing 2L regimen strings for context (e.g. transplant-conditioning vs oral combinations)."),
    tables = q4_tables)

  # ---- Q5: CAR-T clarifications -----------------------------------------
  q5_tables <- list(); q5_notes <- character()
  if (have_sct) {
    q5_tables[["CAR-T relative to LOT1 (recomputed on this cohort; vqs_q6_cart)"]] <-
      best_effort(vqs_q6_cart(con, lot_long, sct_tbl, w1 = VQS_W1, cart_raw_tbl = cart_raw),
                  "CAR-T-relative-to-LOT1 metric table")
    q5_tables[["Empirical answers to the five CAR-T questions"]] <-
      best_effort(q5_cart_clarifications(con, lot_long, sct_tbl, VQS_W1), "CAR-T clarifications")
    q5_notes <- c(
      sprintf("The first table restates the CAR-T-relative-to-LOT1 metrics on THIS cohort (%s, LOT1 = %s patients) so the numbers are live. The earlier table Julia referenced (denominator 11,148; 'Any CAR-T on/after LOT1' = 124) was the FULL Overall LOT cohort - run this script with LOT_COHORT=FULL to reproduce those exact figures. The structural answers below hold for either cohort.",
              cohort_label, format(n_lot1, big.mark = ",")),
      if (is.null(cart_raw))
        "NOTE: the raw CAR-T-before-LOT1 scan was unavailable this run, so 'CAR-T BEFORE LOT1' / 'prior-to-or-during' rows in the first table are NA. During/closing timing is still valid."
      else
        "The raw CAR-T scan is available, so 'CAR-T BEFORE LOT1' is populated (from raw claim dates).",
      "Answers to the study team's questions (see the second table for the counts):",
      "(a) The 'within 60d after LOT1 start' window is start-relative and NOT capped at LOT1 end; 'during or closing LOT1' is capped at LOT1_BASE_END_DT (+1 day only when CAR-T CLOSED LOT1). They are NOT nested by definition: a within-60d CAR-T after LOT1 already ended would sit outside during/closing, and a CAR-T that closes LOT1 past day 60 sits outside within-60d. The subset-test rows show the actual overlap in this cohort.",
      "(b) Because 'CAR-T BEFORE LOT1 start' = 0 and CAR-T dates are >= LOT1 start by construction, 'prior-to-OR-during LOT1' collapses to 'during LOT1' - so yes, all of those patients had the CAR-T during (not before) LOT1.",
      "(c) 'Any CAR-T on/after LOT1 start' is a count of DISTINCT PATIENTS (one per patient, from LOT1_SCT.FIRST_CART_DT), NOT a count of CAR-T instances, and it DOES include later lines (2L+). The 'strictly after LOT1 ends' row shows how many of them are later-line rather than during-LOT1 CAR-T.",
      "(d) A CAR-T dated exactly ON the LOT1 start date is possible in principle (FIRST_CART_DT >= LOT1_START); the count row shows how often it actually happens here.",
      "(e) When a CAR-T closes LOT1 (end reason SCT_CART/CART_INIT), the engine sets LOT1_BASE_END_DT = FIRST_CART_DT - 1 (LOT1 ends the day BEFORE the infusion), and that same CAR-T is the LOT2 start candidate - so the CAR-T date becomes the 2L start (LOT2_START_TYPE = 'CART') unless an even earlier LOT2 trigger exists. The last rows confirm this on the data.",
      if (!have_sct) paste0(sct_tbl, " not readable - CAR-T tables omitted.") else NULL)
  } else {
    q5_notes <- paste0(sct_tbl, " not readable - CAR-T analysis needs LOT1_SCT (FIRST_CART_DT). Q5 skipped.")
  }
  add_sheet(name = "Q5 CAR-T", title = "Q5 - CAR-T relative to LOT1: metrics + clarifications",
    subtitle = paste0("Metric table recomputed on this cohort + empirical answers to the five CAR-T questions. Cohort: ",
                      cohort_label, "."),
    narrative = q5_notes, tables = q5_tables)

  # ---- write --------------------------------------------------------------
  xlsx <- file.path(out_dir, paste0("lot_followup_qs_", tolower(cohort_mode), "_", stamp, ".xlsx"))
  wrote_xlsx <- wbx_write_workbook(sheets, xlsx, out_dir, stamp, allow_csv = allow_csv)
  log_msg(SEP)
  if (isTRUE(wrote_xlsx))
    log_msg("LOT follow-up study-team questions complete. Excel workbook -> ", xlsx)
  else
    log_msg("LOT follow-up study-team questions complete in DEGRADED mode: one CSV per table in ",
            out_dir, " (openxlsx unavailable). Install openxlsx to get the single .xlsx.")
  log_msg(SEP)
}

if (!interactive()) main()
