#!/usr/bin/env Rscript
# Standalone LOT1-5 dashboard.
# Reads work_schema.LOT_LONG (one row per PATID x LOT_NUM) and writes a
# SEPARATE interactive HTML (lot_long_dashboard.html) that breaks every
# view down by LOT_NUM 1..max. This does NOT touch the LOT1 dashboard
# produced by lot_program.R (lot_dashboard.html); it is an independent
# entry script you can run any time LOT_LONG has been (re)built.
#
#   Rscript lot_long_dashboard.R
#
# Prerequisite: work_schema.LOT_LONG must exist and contain LOT2-5 rows
# (i.e. lot2_5_program.R / the LOT2-5 stage completed, not just the
# LOT1 init). If LOT_LONG only has LOT_NUM = 1, every view will show
# only LOT1 - rebuild LOT_LONG first.

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
# Apply CSV input overrides BEFORE config_lot.R reads Sys.getenv().
if (file.exists(file.path(source_dir, "load_inputs.R"))) {
  source(file.path(source_dir, "load_inputs.R"))
  load_pipeline_inputs(c(.script_dir, dirname(.script_dir)))
}
source(file.path(source_dir, "config_lot.R"))
source(file.path(source_dir, "db_utils_lot.R"))
source(file.path(source_dir, "dashboard_lot.R"))

# Default args reproduce the standalone dashboard's behaviour byte-for-
# byte. The combined orchestrator passes a cohort-filtered LOT_LONG and
# disables the schema-wide DEBUG/QC + DRILLDOWN sections (they audit
# work-schema tables and search ANY PATID, neither of which is
# cohort-scoped). Connection / readability check / dashboard_items reset
# / build_dashboard happen in main(), not here, so the function stays a
# pure view collector that callers can chain.
#
# Adding a new LOT1-5 view? Drop it inside this function (or call a
# helper from inside it) using the same save_table / save_plot /
# add_html_card / add_to_dashboard sinks already in use. It will then
# appear in BOTH the standalone dashboard AND the combined dashboard
# (under each cohort) with no other changes needed.
collect_lot_long_views <- function(con, lot_long = wrk("LOT_LONG"),
                                   include_debug = TRUE) {

  # ---- Per-LOT patient/row counts ----
  by_lot <- db_q(con, glue("
    SELECT LOT_NUM,
           count(*)               AS n_rows,
           count(DISTINCT PATID)  AS n_patients
    FROM {lot_long}
    GROUP BY LOT_NUM
    ORDER BY LOT_NUM
  "))
  by_lot$n_rows     <- as.numeric(by_lot$n_rows)
  by_lot$n_patients <- as.numeric(by_lot$n_patients)

  max_lot_present <- if (nrow(by_lot) > 0) max(by_lot$LOT_NUM) else 0
  lot1_n <- if (any(by_lot$LOT_NUM == 1)) by_lot$n_patients[by_lot$LOT_NUM == 1] else NA_real_

  retn <- by_lot
  retn$pct_of_lot1 <- if (is.na(lot1_n) || lot1_n == 0) NA_real_ else
    round(100 * retn$n_patients / lot1_n, 1)
  retn$pct_of_prev <- NA_real_
  if (nrow(retn) > 1) {
    for (i in 2:nrow(retn)) {
      prev_n <- retn$n_patients[i - 1]
      retn$pct_of_prev[i] <- if (prev_n > 0)
        round(100 * retn$n_patients[i] / prev_n, 1) else NA_real_
    }
  }

  overview_html <- paste0(
    '<div style="font-family:system-ui;padding:8px 4px">',
    '<h3 style="margin:0 0 8px">LOT_LONG &mdash; ', lot_long, '</h3>',
    '<p style="color:#555;margin:0 0 12px">Max LOT present: <b>', max_lot_present,
    '</b> &nbsp;|&nbsp; LOT1 patients: <b>',
    ifelse(is.na(lot1_n), "n/a", format(lot1_n, big.mark = ",")),
    '</b></p>',
    if (max_lot_present <= 1)
      paste0('<p style="color:#b00;font-weight:600">Only LOT_NUM = 1 is ',
             'present in LOT_LONG. Rebuild with: ',
             '<code>SKIP_COHORT=TRUE SKIP_LOT1=TRUE FORCE_RERUN=TRUE ',
             'Rscript run_pipeline.R</code> (atomic publish keeps the ',
             'old LOT_LONG until the full rebuild succeeds, so no ',
             'manual DROP is needed).</p>') else "",
    '</div>'
  )
  add_html_card(overview_html, section = "OVERVIEW", title = "LOT_LONG Overview")
  save_table(retn, section = "OVERVIEW", title = "Patients per LOT (retention)")

  # ---- Funnel: patients reaching each LOT ----
  if (has_ggplot2 && nrow(by_lot) > 0) {
    p_funnel <- ggplot(by_lot, aes(x = factor(LOT_NUM), y = n_patients)) +
      geom_col(fill = "#2E86AB", width = 0.65) +
      geom_text(aes(label = format(n_patients, big.mark = ",")),
                vjust = -0.4, size = 4) +
      labs(title = "Patients reaching each LOT",
           x = "LOT_NUM", y = "Distinct patients") +
      theme_lot()
    save_plot(p_funnel, "lotlong_funnel.png", width = 9, height = 5,
              section = "FUNNEL", title = "Patient Funnel by LOT")
  }

  # ---- Start type by LOT ----
  st <- db_q(con, glue("
    SELECT LOT_NUM, LOT_START_TYPE, count(*) AS n
    FROM {lot_long}
    GROUP BY LOT_NUM, LOT_START_TYPE
    ORDER BY LOT_NUM, LOT_START_TYPE
  "))
  st$n <- as.numeric(st$n)
  if (has_ggplot2 && nrow(st) > 0) {
    p_st <- ggplot(st, aes(x = factor(LOT_NUM), y = n, fill = LOT_START_TYPE)) +
      geom_col(position = "fill", width = 0.7) +
      scale_fill_manual(values = lot_start_palette, na.value = "grey60") +
      scale_y_continuous(labels = function(x) paste0(x * 100, "%")) +
      labs(title = "LOT start type composition by LOT_NUM",
           x = "LOT_NUM", y = "Share of LOTs", fill = "Start type") +
      theme_lot()
    save_plot(p_st, "lotlong_starttype.png", width = 9, height = 5,
              section = "START_TYPE", title = "Start Type by LOT")
  }
  save_table(st, section = "START_TYPE", title = "Start Type counts by LOT")

  # ---- End reason by LOT ----
  er <- db_q(con, glue("
    SELECT LOT_NUM, LOT_BASE_END_REASON, count(*) AS n
    FROM {lot_long}
    GROUP BY LOT_NUM, LOT_BASE_END_REASON
    ORDER BY LOT_NUM, LOT_BASE_END_REASON
  "))
  er$n <- as.numeric(er$n)
  if (has_ggplot2 && nrow(er) > 0) {
    p_er <- ggplot(er, aes(x = factor(LOT_NUM), y = n, fill = LOT_BASE_END_REASON)) +
      geom_col(position = "fill", width = 0.7) +
      scale_fill_manual(values = lot_reason_palette, na.value = "grey60") +
      scale_y_continuous(labels = function(x) paste0(x * 100, "%")) +
      labs(title = "LOT end reason composition by LOT_NUM",
           x = "LOT_NUM", y = "Share of LOTs", fill = "End reason") +
      theme_lot()
    save_plot(p_er, "lotlong_endreason.png", width = 10, height = 5,
              section = "END_REASON", title = "End Reason by LOT")
  }
  save_table(er, section = "END_REASON", title = "End Reason counts by LOT")

  # ---- LOT length distribution by LOT ----
  len_stats <- db_q(con, glue("
    SELECT LOT_NUM,
           count(*)                                       AS n,
           round(avg(LOT_BASE_LENGTH), 1)                 AS mean_days,
           percentile_approx(LOT_BASE_LENGTH, 0.5)        AS median_days,
           percentile_approx(LOT_BASE_LENGTH, 0.25)       AS p25_days,
           percentile_approx(LOT_BASE_LENGTH, 0.75)       AS p75_days
    FROM {lot_long}
    WHERE LOT_BASE_LENGTH IS NOT NULL
    GROUP BY LOT_NUM
    ORDER BY LOT_NUM
  "))
  for (col in c("n", "mean_days", "median_days", "p25_days", "p75_days")) {
    if (col %in% names(len_stats)) len_stats[[col]] <- as.numeric(len_stats[[col]])
  }
  save_table(len_stats, section = "LENGTH",
             title = "LOT length summary (days) by LOT")
  if (has_ggplot2 && nrow(len_stats) > 0) {
    p_len <- ggplot(len_stats, aes(x = factor(LOT_NUM), y = median_days)) +
      geom_col(fill = "#A23B72", width = 0.6) +
      geom_errorbar(aes(ymin = p25_days, ymax = p75_days), width = 0.2,
                    color = "grey30") +
      geom_text(aes(label = round(median_days)), vjust = -0.5, size = 4) +
      labs(title = "Median LOT length by LOT_NUM (IQR whiskers)",
           x = "LOT_NUM", y = "LOT_BASE_LENGTH (days)") +
      theme_lot()
    save_plot(p_len, "lotlong_length.png", width = 9, height = 5,
              section = "LENGTH", title = "LOT Length by LOT")
  }

  # ---- Top regimens per LOT ----
  reg <- db_q(con, glue("
    SELECT LOT_NUM, LOT_BASE_MEDS, count(*) AS n
    FROM {lot_long}
    WHERE LOT_BASE_MEDS IS NOT NULL AND trim(LOT_BASE_MEDS) <> ''
    GROUP BY LOT_NUM, LOT_BASE_MEDS
  "))
  reg$n <- as.numeric(reg$n)
  if (nrow(reg) > 0) {
    reg <- reg[order(reg$LOT_NUM, -reg$n), ]
    top_reg <- do.call(rbind, lapply(split(reg, reg$LOT_NUM), function(d)
      head(d, 10)))
    rownames(top_reg) <- NULL
    save_table(top_reg, section = "REGIMENS",
               title = "Top 10 regimens per LOT")
  }

  # ---- Progression: how far each patient gets ----
  prog <- db_q(con, glue("
    SELECT max_lot, count(*) AS n_patients
    FROM (SELECT PATID, max(LOT_NUM) AS max_lot FROM {lot_long} GROUP BY PATID)
    GROUP BY max_lot
    ORDER BY max_lot
  "))
  prog$max_lot     <- as.numeric(prog$max_lot)
  prog$n_patients  <- as.numeric(prog$n_patients)
  save_table(prog, section = "PROGRESSION",
             title = "Patients by furthest LOT reached")
  if (has_ggplot2 && nrow(prog) > 0) {
    p_prog <- ggplot(prog, aes(x = factor(max_lot), y = n_patients)) +
      geom_col(fill = "#3F88C5", width = 0.65) +
      geom_text(aes(label = format(n_patients, big.mark = ",")),
                vjust = -0.4, size = 4) +
      labs(title = "How far patients progress (furthest LOT reached)",
           x = "Highest LOT_NUM reached", y = "Patients") +
      theme_lot()
    save_plot(p_prog, "lotlong_progression.png", width = 9, height = 5,
              section = "PROGRESSION", title = "Progression depth")
  }

  # ---- Gap between consecutive LOTs (LOT N end -> LOT N+1 start) ----
  gaps <- db_q(con, glue("
    SELECT a.LOT_NUM AS from_lot,
           count(*)                                                       AS n,
           round(avg(datediff(b.LOT_START_DT, a.LOT_BASE_END_DT)), 1)      AS mean_gap_days,
           percentile_approx(datediff(b.LOT_START_DT, a.LOT_BASE_END_DT), 0.5)  AS median_gap_days,
           percentile_approx(datediff(b.LOT_START_DT, a.LOT_BASE_END_DT), 0.25) AS p25_gap_days,
           percentile_approx(datediff(b.LOT_START_DT, a.LOT_BASE_END_DT), 0.75) AS p75_gap_days
    FROM {lot_long} a
    JOIN {lot_long} b ON a.PATID = b.PATID AND b.LOT_NUM = a.LOT_NUM + 1
    GROUP BY a.LOT_NUM
    ORDER BY a.LOT_NUM
  "))
  for (col in names(gaps)) gaps[[col]] <- as.numeric(gaps[[col]])
  if (nrow(gaps) > 0) {
    gaps$transition <- paste0("LOT", gaps$from_lot, " -> LOT", gaps$from_lot + 1)
    save_table(gaps[, c("transition", "n", "mean_gap_days",
                        "median_gap_days", "p25_gap_days", "p75_gap_days")],
               section = "GAPS", title = "Gap (days) between consecutive LOTs")
    if (has_ggplot2) {
      p_gap <- ggplot(gaps, aes(x = transition, y = median_gap_days)) +
        geom_col(fill = "#F18F01", width = 0.6) +
        geom_errorbar(aes(ymin = p25_gap_days, ymax = p75_gap_days),
                      width = 0.2, color = "grey30") +
        geom_text(aes(label = round(median_gap_days)), vjust = -0.5, size = 4) +
        labs(title = "Median days between consecutive LOTs (IQR whiskers)",
             x = "", y = "Days (LOT N end -> LOT N+1 start)") +
        theme_lot()
      save_plot(p_gap, "lotlong_gaps.png", width = 9, height = 5,
                section = "GAPS", title = "Inter-LOT gap")
    }
  }

  # ---- Start-type transitions (LOT N start type -> LOT N+1 start type) ----
  trans <- db_q(con, glue("
    SELECT a.LOT_NUM AS from_lot,
           a.LOT_START_TYPE AS from_type,
           b.LOT_START_TYPE AS to_type,
           count(*) AS n
    FROM {lot_long} a
    JOIN {lot_long} b ON a.PATID = b.PATID AND b.LOT_NUM = a.LOT_NUM + 1
    GROUP BY a.LOT_NUM, a.LOT_START_TYPE, b.LOT_START_TYPE
    ORDER BY a.LOT_NUM, a.LOT_START_TYPE, b.LOT_START_TYPE
  "))
  trans$from_lot <- as.numeric(trans$from_lot)
  trans$n        <- as.numeric(trans$n)
  if (nrow(trans) > 0) {
    trans$transition <- paste0("LOT", trans$from_lot, " -> LOT", trans$from_lot + 1)
    save_table(trans[, c("transition", "from_type", "to_type", "n")],
               section = "TRANSITIONS",
               title = "Start-type transitions across LOTs")
  }

  # ---- Sankey flow diagrams ----
  # Helper: build a plotly Sankey from parallel src/tgt label vectors.
  make_sankey <- function(src_lab, tgt_lab, value, title, pal = NULL) {
    if (!has_plotly || length(value) == 0) return(invisible(NULL))
    nodes <- unique(c(src_lab, tgt_lab))
    idx   <- setNames(seq_along(nodes) - 1L, nodes)
    ncol  <- function(lbl) {
      if (is.null(pal)) return("#2E86AB")
      key <- sub("^.*?:\\s*", "", lbl)        # strip "L2: " style prefix
      vapply(key, function(k)
        if (k %in% names(pal)) pal[[k]] else "#9aa5ab",
        character(1))
    }
    sk <- tryCatch(
      plotly::plot_ly(
        type = "sankey", orientation = "h",
        arrangement = "snap",
        node = list(
          label = nodes, pad = 14, thickness = 16,
          color = unname(ncol(nodes)),
          line  = list(color = "white", width = 0.5)
        ),
        link = list(
          source = unname(idx[src_lab]),
          target = unname(idx[tgt_lab]),
          value  = as.numeric(value),
          color  = "rgba(46,134,171,0.30)"
        )
      ) |>
        plotly::layout(
          title = list(text = title, font = list(size = 15)),
          font  = list(size = 11),
          margin = list(l = 10, r = 10, t = 50, b = 10),
          paper_bgcolor = "white"
        ) |>
        plotly::config(displayModeBar = TRUE, displaylogo = FALSE),
      error = function(e) {
        log_msg("  INFO: sankey '", title, "' skipped (",
                conditionMessage(e), ")")
        NULL
      }
    )
    if (!is.null(sk)) add_to_dashboard(sk, section = "SANKEY", title = title)
  }

  # Shared palette from dashboard_lot.R so SCT_ALLO / CART_* colours
  # stay consistent across charts (Sankey, drilldown, MED journey).
  type_pal <- lot_start_palette

  # Sankey 1: start-type flow across LOTs (reuses `trans`).
  if (nrow(trans) > 0) {
    s1 <- trans[!is.na(trans$from_type) & !is.na(trans$to_type), ]
    if (nrow(s1) > 0) {
      make_sankey(
        src_lab = paste0("L", s1$from_lot, ": ", s1$from_type),
        tgt_lab = paste0("L", s1$from_lot + 1, ": ", s1$to_type),
        value   = s1$n,
        title   = "Start-type flow across LOTs",
        pal     = type_pal)
    }
  }

  # Sankey 2: LOT N end reason -> LOT N+1 start type (or terminal).
  er_next <- db_q(con, glue("
    SELECT a.LOT_NUM AS from_lot,
           a.LOT_BASE_END_REASON AS end_reason,
           b.LOT_START_TYPE AS next_type,
           count(*) AS n
    FROM {lot_long} a
    LEFT JOIN {lot_long} b ON a.PATID = b.PATID AND b.LOT_NUM = a.LOT_NUM + 1
    GROUP BY a.LOT_NUM, a.LOT_BASE_END_REASON, b.LOT_START_TYPE
  "))
  if (nrow(er_next) > 0) {
    er_next$from_lot <- as.numeric(er_next$from_lot)
    er_next$n        <- as.numeric(er_next$n)
    src <- paste0("L", er_next$from_lot, " end: ", er_next$end_reason)
    tgt <- ifelse(is.na(er_next$next_type),
                  paste0("L", er_next$from_lot, " (no next LOT)"),
                  paste0("L", er_next$from_lot + 1, " start: ", er_next$next_type))
    make_sankey(src, tgt, er_next$n,
                "LOT end reason → next LOT start type")
  }

  # Sankey 3: drop-off funnel (continue vs stop after each LOT).
  cont <- db_q(con, glue("
    SELECT a.LOT_NUM                    AS lot,
           count(DISTINCT a.PATID)      AS n_here,
           count(DISTINCT b.PATID)      AS n_continue
    FROM {lot_long} a
    LEFT JOIN {lot_long} b ON a.PATID = b.PATID AND b.LOT_NUM = a.LOT_NUM + 1
    GROUP BY a.LOT_NUM
    ORDER BY a.LOT_NUM
  "))
  if (nrow(cont) > 0) {
    cont$lot        <- as.numeric(cont$lot)
    cont$n_here     <- as.numeric(cont$n_here)
    cont$n_continue <- as.numeric(cont$n_continue)
    cont$n_stop     <- cont$n_here - cont$n_continue
    src <- character(0); tgt <- character(0); val <- numeric(0)
    for (i in seq_len(nrow(cont))) {
      L <- cont$lot[i]
      if (cont$n_continue[i] > 0) {
        src <- c(src, paste0("LOT", L)); tgt <- c(tgt, paste0("LOT", L + 1))
        val <- c(val, cont$n_continue[i])
      }
      if (cont$n_stop[i] > 0) {
        src <- c(src, paste0("LOT", L))
        tgt <- c(tgt, paste0("Stopped after LOT", L))
        val <- c(val, cont$n_stop[i])
      }
    }
    make_sankey(src, tgt, val, "Drop-off funnel (continue vs stop per LOT)")
  }

  # ---- MED count per LOT ----
  mc <- db_q(con, glue("
    SELECT LOT_NUM,
           round(avg(LOT_MED_CNT), 2)              AS mean_med_cnt,
           percentile_approx(LOT_MED_CNT, 0.5)     AS median_med_cnt,
           max(LOT_MED_CNT)                        AS max_med_cnt
    FROM {lot_long}
    WHERE LOT_MED_CNT IS NOT NULL
    GROUP BY LOT_NUM ORDER BY LOT_NUM
  "))
  for (col in names(mc)) mc[[col]] <- as.numeric(mc[[col]])
  if (nrow(mc) > 0) {
    save_table(mc, section = "MEDCOUNT", title = "Induction med count by LOT")
    if (has_ggplot2) {
      p_mc <- ggplot(mc, aes(x = factor(LOT_NUM), y = mean_med_cnt)) +
        geom_col(fill = "#5FAD56", width = 0.6) +
        geom_text(aes(label = round(mean_med_cnt, 2)), vjust = -0.4, size = 4) +
        labs(title = "Mean induction-window med count by LOT",
             x = "LOT_NUM", y = "Mean LOT_MED_CNT") +
        theme_lot()
      save_plot(p_mc, "lotlong_medcount.png", width = 9, height = 5,
                section = "MEDCOUNT", title = "Med count by LOT")
    }
  }

  # ---- contains_mtx_reg rate by LOT ----
  mtx <- db_q(con, glue("
    SELECT LOT_NUM,
           count(*)                                            AS n,
           sum(CASE WHEN contains_mtx_reg = 1 THEN 1 ELSE 0 END) AS n_mtx
    FROM {lot_long}
    GROUP BY LOT_NUM ORDER BY LOT_NUM
  "))
  if (nrow(mtx) > 0) {
    mtx$n     <- as.numeric(mtx$n)
    mtx$n_mtx <- as.numeric(mtx$n_mtx)
    mtx$pct_mtx <- round(100 * mtx$n_mtx / pmax(mtx$n, 1), 1)
    save_table(mtx, section = "MTX",
               title = "contains_mtx_reg rate by LOT")
    if (has_ggplot2) {
      p_mtx <- ggplot(mtx, aes(x = factor(LOT_NUM), y = pct_mtx)) +
        geom_col(fill = "#8D5A97", width = 0.6) +
        geom_text(aes(label = paste0(pct_mtx, "%")), vjust = -0.4, size = 4) +
        labs(title = "Maintenance-regimen (contains_mtx_reg) rate by LOT",
             x = "LOT_NUM", y = "% of LOTs") +
        theme_lot()
      save_plot(p_mtx, "lotlong_mtx.png", width = 9, height = 5,
                section = "MTX", title = "MTX regimen rate by LOT")
    }
  }

  # ---- LOT starts over calendar time ----
  trend <- db_q(con, glue("
    SELECT year(LOT_START_DT) AS yr,
           quarter(LOT_START_DT) AS qtr,
           LOT_NUM,
           count(*) AS n
    FROM {lot_long}
    WHERE LOT_START_DT IS NOT NULL
    GROUP BY year(LOT_START_DT), quarter(LOT_START_DT), LOT_NUM
    ORDER BY yr, qtr, LOT_NUM
  "))
  if (nrow(trend) > 0 && has_ggplot2) {
    trend$yr  <- as.numeric(trend$yr)
    trend$qtr <- as.numeric(trend$qtr)
    trend$n   <- as.numeric(trend$n)
    trend$period <- trend$yr + (trend$qtr - 1) / 4
    p_tr <- ggplot(trend, aes(x = period, y = n,
                              color = factor(LOT_NUM))) +
      geom_line(linewidth = 1) + geom_point(size = 1.6) +
      labs(title = "LOT starts over calendar time (by quarter)",
           x = "Year", y = "LOT starts", color = "LOT_NUM") +
      theme_lot()
    save_plot(p_tr, "lotlong_trend.png", width = 11, height = 5,
              section = "TREND", title = "LOT starts over time")
  }

  # ---- Patient medication journey examples ---------------------------
  # Per-patient chart with one row per medication (MAP_MED_TYPE); bars
  # are the MAP segments coloured by class, vertical dashed lines mark
  # each LOT_NUM start and the final LOT end. Same selection logic the
  # LOT1 dashboard uses for its journey section, generalised to LOT1-5.
  if (has_plotly) {
    # lot_start_palette / lot_reason_palette come from dashboard_lot.R
    # (shared so the same category is the same colour in both dashboards).
    # One row per patient: furthest LOT + that final LOT's end reason.
    # PATID is CAST AS STRING at the warehouse: some ODBC drivers return
    # the BIGINT PATID to R as a numeric/scientific double, which then
    # never matches back in the `WHERE PATID IN (...)` list below (the
    # join inside SQL still uses the raw column, so it is unaffected).
    # HAVING max(LOT_NUM) >= 2: Med Journey examples are about the
    # patient journey THROUGH lines, so LOT1-only patients (no
    # progression to show) are excluded even from the
    # spread-of-terminal-reasons fill below.
    pat_pick <- db_q(con, glue("
      WITH pm AS (SELECT PATID, max(LOT_NUM) AS max_lot
                  FROM {lot_long} GROUP BY PATID
                  HAVING max(LOT_NUM) >= 2)
      SELECT cast(pm.PATID as string) AS PATID, pm.max_lot,
             ll.LOT_BASE_END_REASON AS terminal_reason
      FROM pm
      JOIN {lot_long} ll ON ll.PATID = pm.PATID AND ll.LOT_NUM = pm.max_lot
    "))
    pat_pick$max_lot <- as.numeric(pat_pick$max_lot)

    pick_ids <- character(0)
    if (nrow(pat_pick) > 0) {
      # Deepest progressors first, then ensure a spread of terminal reasons.
      ord <- pat_pick[order(-pat_pick$max_lot), , drop = FALSE]
      pick_ids <- head(ord$PATID, 6)
      for (rs in unique(pat_pick$terminal_reason)) {
        cand <- ord$PATID[ord$terminal_reason == rs]
        cand <- setdiff(cand, pick_ids)
        if (length(cand) > 0) pick_ids <- c(pick_ids, cand[1])
      }
      pick_ids <- unique(head(pick_ids, 12))
    }

    if (length(pick_ids) > 0) {
      id_list <- paste(sprintf("'%s'", gsub("'", "''", pick_ids)),
                       collapse = ", ")
      jdf <- db_q(con, glue("
        SELECT cast(PATID as string) AS PATID, LOT_NUM, LOT_START_TYPE,
               cast(cast(LOT_START_DT    as date) as string) AS LOT_START_DT,
               cast(cast(LOT_BASE_END_DT as date) as string) AS LOT_BASE_END_DT,
               LOT_BASE_END_REASON, LOT_BASE_LENGTH, LOT_BASE_MEDS
        FROM {lot_long}
        WHERE cast(PATID as string) IN ({id_list})
        ORDER BY PATID, LOT_NUM
      "))
      # PATID and dates are stringified at the warehouse so the IN-list
      # matches and as.Date() parses. Without the PATID cast, a BIGINT
      # PATID surfaced in R as a numeric never matched here and every
      # patient was skipped -> "no usable LOT start dates" / 0 journeys.
      jdf$LOT_NUM         <- as.numeric(jdf$LOT_NUM)
      jdf$LOT_START_DT    <- as.Date(jdf$LOT_START_DT)
      jdf$LOT_BASE_END_DT <- as.Date(jdf$LOT_BASE_END_DT)
      # End date can legitimately be NULL (ongoing / some reasons);
      # fall back to the start date so the LOT still draws as a thin bar.
      eend <- jdf$LOT_BASE_END_DT
      eend[is.na(eend)] <- jdf$LOT_START_DT[is.na(eend)]
      jdf$LOT_BASE_END_DT <- eend

      # ---- MED JOURNEY: per-medication patient journey (LOT1-5) ---------
      # Mirrors the LOT1 dashboard's medication-level journey chart. The
      # milestone vlines extend across every LOT_NUM boundary (start of
      # each line + final end), so a 5-line patient sees LOT1..LOT5
      # markers. Reads the persisted MAP_STACKED work-schema table that
      # lot_program.R materializes.
      map_tbl <- wrk("MAP_STACKED")
      mdf <- tryCatch(db_q(con, glue("
        SELECT cast(PATID as string) AS PATID,
               MAP_MED_TYPE          AS MED,
               MAP_MED_CLASS         AS CLASS,
               cast(cast(MAP_START_DT as date) as string) AS MAP_START_DT,
               cast(cast(MAP_END_DT   as date) as string) AS MAP_END_DT,
               coalesce(MAP_CNT, 1)        AS MAP_CNT,
               coalesce(MAP_DISCON_FLG, 0) AS MAP_DISCON_FLG
        FROM {map_tbl}
        WHERE cast(PATID as string) IN ({id_list})
        ORDER BY PATID, MAP_MED_TYPE, MAP_START_DT
      ")), error = function(e) {
        log_msg("  MED JOURNEY: cannot read ", map_tbl, " (",
                conditionMessage(e), ")"); NULL
      })

      km <- 0
      if (!is.null(mdf) && nrow(mdf) > 0) {
        mdf$MAP_START_DT <- as.Date(mdf$MAP_START_DT)
        mdf$MAP_END_DT   <- as.Date(mdf$MAP_END_DT)
        bad_end <- is.na(mdf$MAP_END_DT) | mdf$MAP_END_DT < mdf$MAP_START_DT
        mdf$MAP_END_DT[bad_end] <- mdf$MAP_START_DT[bad_end]

        for (pid in pick_ids) {
          pm <- mdf[mdf$PATID == pid, , drop = FALSE]
          pl <- jdf[jdf$PATID == pid, , drop = FALSE]
          pl <- pl[order(pl$LOT_NUM), , drop = FALSE]
          if (nrow(pm) == 0 || all(is.na(pm$MAP_START_DT))) next
          km <- km + 1

          added_m <- tryCatch({
            meds  <- sort(unique(pm$MED))
            med_y <- setNames(seq_along(meds), meds)
            ymax  <- length(meds)

            shapes <- list(); annotations <- list()
            for (j in seq_len(nrow(pm))) {
              row <- pm[j, ]
              y   <- med_y[[row$MED]]
              cls <- as.character(row$CLASS)
              color <- if (!is.na(cls) && cls %in% names(lot_class_palette))
                lot_class_palette[[cls]] else "#636e72"
              opa <- if (isTRUE(row$MAP_CNT > 1)) 0.6 else 0.85
              shapes[[length(shapes) + 1]] <- list(
                type = "rect",
                x0 = as.character(row$MAP_START_DT),
                x1 = as.character(row$MAP_END_DT),
                y0 = y - 0.35, y1 = y + 0.35,
                fillcolor = color, opacity = opa,
                line = list(color = color, width = 1), layer = "below"
              )
            }
            add_vline <- function(dt, label, color) {
              if (is.na(dt)) return(invisible())
              x <- as.character(dt)
              shapes[[length(shapes) + 1]] <<- list(
                type = "line", x0 = x, x1 = x,
                y0 = 0.3, y1 = ymax + 0.7,
                line = list(color = color, width = 2, dash = "dash"),
                layer = "above"
              )
              annotations[[length(annotations) + 1]] <<- list(
                x = x, y = ymax + 0.6, text = label, showarrow = FALSE,
                font = list(size = 10, color = color),
                xanchor = "left", textangle = -30
              )
            }
            for (i in seq_len(nrow(pl))) {
              st  <- as.character(pl$LOT_START_TYPE[i])
              col <- if (!is.na(st) && st %in% names(lot_start_palette))
                lot_start_palette[[st]] else "#2E86AB"
              add_vline(pl$LOT_START_DT[i],
                        paste0("LOT", pl$LOT_NUM[i], " start"), col)
            }
            last_row <- pl[nrow(pl), ]
            if (!is.na(last_row$LOT_BASE_END_DT)) {
              rsn  <- as.character(last_row$LOT_BASE_END_REASON)
              rcol <- if (!is.na(rsn) && rsn %in% names(lot_reason_palette))
                lot_reason_palette[[rsn]] else "#C73E1D"
              add_vline(last_row$LOT_BASE_END_DT,
                        paste0("End (", rsn, ")"), rcol)
            }

            mid_x <- pm$MAP_START_DT +
              as.integer((pm$MAP_END_DT - pm$MAP_START_DT) / 2)
            hover_df <- data.frame(
              x = mid_x, y = med_y[pm$MED],
              text = paste0(
                "Med: ", pm$MED,
                "\nClass: ", pm$CLASS,
                "\nStart: ", pm$MAP_START_DT,
                "\nEnd: ",   pm$MAP_END_DT,
                "\nMAP #",   pm$MAP_CNT,
                ifelse(pm$MAP_DISCON_FLG == 1, "\nDiscon: Yes", "")),
              stringsAsFactors = FALSE
            )
            pat_label <- paste0("Patient ", which(pick_ids == pid))
            pp_m <- plotly::plot_ly(hover_df, x = ~x, y = ~y, text = ~text,
                                     type = "scatter", mode = "markers",
                                     marker = list(size = 1, opacity = 0),
                                     hoverinfo = "text") |>
              plotly::layout(
                title = list(text = paste0(pat_label, " - Medication Journey"),
                             font = list(size = 14)),
                xaxis = list(title = "", type = "date", gridcolor = "#eee"),
                yaxis = list(title = "Medication", tickmode = "array",
                             tickvals = seq_along(meds), ticktext = meds,
                             range = c(0.4, length(meds) + 0.9),
                             gridcolor = "#eee"),
                shapes = shapes, annotations = annotations,
                showlegend = FALSE,
                margin = list(l = 110, t = 50, b = 40, r = 30),
                plot_bgcolor = "#fafafa", paper_bgcolor = "white"
              ) |>
              plotly::config(displayModeBar = TRUE, displaylogo = FALSE)
            term_m <- as.character(last_row$LOT_BASE_END_REASON)
            add_to_dashboard(pp_m, section = "MED JOURNEY",
                             title = paste0(pat_label, " (",
                                            length(meds), " meds, ",
                                            nrow(pl), " LOTs, ends ",
                                            term_m, ")"))
            TRUE
          }, error = function(e) {
            log_msg("  INFO: skipping med journey for a patient (",
                    conditionMessage(e), ")")
            FALSE
          })
          if (!isTRUE(added_m)) km <- km - 1
        }
        log_msg("  Med journey examples added: ", km)
      }
      if (km == 0) {
        add_html_card(paste0(
          '<div style="font-family:system-ui;padding:14px">',
          '<h3>No medication journey examples</h3>',
          '<p style="color:#555">MAP_STACKED has no rows for the ',
          'selected example patients. Rebuild via ',
          '<code>lot_program.R</code> / <code>run_pipeline.R</code> ',
          'so the medication-level table exists in the work schema.',
          '</p></div>'),
          section = "MED JOURNEY", title = "Med Journeys (none)")
      }
    } else {
      add_html_card(paste0(
        '<div style="font-family:system-ui;padding:14px">',
        '<h3>No patients to show</h3>',
        '<p style="color:#555">LOT_LONG returned no patients. If it was ',
        'just rebuilt, confirm rows exist (Debug/QC &rarr; Table ',
        'inventory).</p></div>'),
        section = "MED JOURNEY", title = "Med Journeys (none)")
    }
  } else {
    log_msg("  plotly not available - skipping MED JOURNEY.")
    add_html_card(paste0(
      '<div style="font-family:system-ui;padding:14px">',
      '<h3>Med Journeys unavailable</h3>',
      '<p style="color:#555">The <code>plotly</code> R package is not ',
      'installed, so the journey chart was skipped. The <b>Drilldown</b> ',
      'category still works (renders client-side without plotly).</p></div>'),
      section = "MED JOURNEY", title = "Med Journeys (unavailable)")
  }

  # DEBUG/QC + DRILLDOWN are schema-wide audit/exploration tools
  # (they inventory persisted work tables and let users look up ANY
  # PATID). When the combined dashboard re-runs this collector for the
  # NDMM cohort, repeating both would be misleading - they don't change
  # between cohorts - so the orchestrator turns them off there.
  if (include_debug) {

  # ---- DEBUG / QC: persisted work-schema tables ----
  # Reads the tables lot_program.R / LOT2-5 persist (NOT temp views), so
  # this stays a single robust script with no dependency on the LOT1
  # pipeline session. Every probe is defensive: a missing table is
  # reported, never fatal.
  esc_html <- function(x) {
    x <- as.character(x)
    x <- gsub("&", "&amp;", x, fixed = TRUE)
    x <- gsub("<", "&lt;",  x, fixed = TRUE)
    gsub(">", "&gt;", x, fixed = TRUE)
  }
  # Cohort input is configurable (INPUT_COHORT_TABLE); probe the table
  # the pipeline actually uses, not a hardcoded default, else a
  # non-default run shows it falsely "missing".
  debug_tables <- list(
    list(tb = cfg$input_cohort_table,
         label = paste0(cfg$input_cohort_table, " (cohort input)")),
    list(tb = "MMA_MED_PROCESSED", label = "MMA_MED_PROCESSED"),
    list(tb = "MAP_STACKED",       label = "MAP_STACKED"),
    list(tb = "LOT1_BASE",         label = "LOT1_BASE"),
    list(tb = "LOT1_SCT",          label = "LOT1_SCT"),
    list(tb = "LOT1_BASE_END",     label = "LOT1_BASE_END"),
    list(tb = "LOT_LONG",          label = "LOT_LONG"),
    list(tb = "LOT_RUN_METADATA",  label = "LOT_RUN_METADATA"),
    list(tb = "LOT_QC_SUMMARY",    label = "LOT_QC_SUMMARY")
  )
  inv_rows <- lapply(debug_tables, function(ent) {
    res <- tryCatch(
      db_q(con, glue("SELECT count(*) AS n FROM {wrk(ent$tb)}")),
      error = function(e) NULL)
    if (is.null(res)) {
      sprintf('<tr><td>%s</td><td style="color:#b00">missing / unreadable</td></tr>',
              esc_html(ent$label))
    } else {
      sprintf('<tr><td>%s</td><td>%s rows</td></tr>',
              esc_html(ent$label), format(as.numeric(res$n[1]), big.mark = ","))
    }
  })
  inv_html <- paste0(
    '<div style="font-family:system-ui;padding:8px 4px">',
    '<h3 style="margin:0 0 8px">Persisted work-schema tables (',
    esc_html(cfg$work_schema), ')</h3>',
    '<table style="border-collapse:collapse;font-size:13px" border="1" ',
    'cellpadding="6"><tr style="background:#f0f3f5"><th>Table</th>',
    '<th>Status</th></tr>', paste(unlist(inv_rows), collapse = ""),
    '</table></div>'
  )
  add_html_card(inv_html, section = "DEBUG", title = "Table inventory")

  # LOT_RUN_METADATA / LOT_QC_SUMMARY as tables (if present).
  for (qt in list(
        list(tb = "LOT_RUN_METADATA", title = "Run metadata"),
        list(tb = "LOT_QC_SUMMARY",   title = "QC summary"))) {
    df <- tryCatch(db_q(con, glue("SELECT * FROM {wrk(qt$tb)}")),
                   error = function(e) NULL)
    if (!is.null(df) && is.data.frame(df) && nrow(df) > 0) {
      for (col in names(df)) {
        if (inherits(df[[col]], "integer64")) df[[col]] <- as.numeric(df[[col]])
      }
      save_table(df, section = "DEBUG", title = qt$title)
    } else {
      add_html_card(
        paste0('<p style="font-family:system-ui;color:#b00">',
               wrk(qt$tb), ' not available.</p>'),
        section = "DEBUG", title = qt$title)
    }
  }

  # Cross-check: LOT1_BASE_END end-reason distribution vs LOT_LONG LOT1.
  lbe_chk <- tryCatch(db_q(con, glue("
    SELECT LOT1_BASE_END_REASON AS end_reason, count(*) AS n_lot1_base_end
    FROM {wrk('LOT1_BASE_END')}
    GROUP BY LOT1_BASE_END_REASON ORDER BY LOT1_BASE_END_REASON
  ")), error = function(e) NULL)
  if (!is.null(lbe_chk) && nrow(lbe_chk) > 0) {
    lbe_chk$n_lot1_base_end <- as.numeric(lbe_chk$n_lot1_base_end)
    ll1 <- tryCatch(db_q(con, glue("
      SELECT LOT_BASE_END_REASON AS end_reason, count(*) AS n_lot_long_lot1
      FROM {lot_long} WHERE LOT_NUM = 1
      GROUP BY LOT_BASE_END_REASON
    ")), error = function(e) NULL)
    if (!is.null(ll1) && nrow(ll1) > 0) {
      ll1$n_lot_long_lot1 <- as.numeric(ll1$n_lot_long_lot1)
      cmp <- merge(lbe_chk, ll1, by = "end_reason", all = TRUE)
      cmp[is.na(cmp)] <- 0
      cmp$delta <- cmp$n_lot_long_lot1 - cmp$n_lot1_base_end
      save_table(cmp, section = "DEBUG",
                 title = "LOT1 cross-check: LOT1_BASE_END vs LOT_LONG LOT1")
    } else {
      save_table(lbe_chk, section = "DEBUG",
                 title = "LOT1_BASE_END end-reason distribution")
    }
  }

  # ---- PATID drilldown (search ANY patient's LOT journey) ----
  # Self-contained html_card: embeds compact per-patient LOT data +
  # native PATID autocomplete + a pure-DOM Gantt rendered client-side.
  # No plotly inside the sandboxed iframe (it would need its own 3 MB
  # copy); a lightweight CSS/JS timeline is plenty for debugging.
  max_pat <- suppressWarnings(as.integer(
    Sys.getenv("DRILLDOWN_MAX_PATIENTS", unset = "8000")))
  if (is.na(max_pat) || max_pat < 1) max_pat <- 8000L
  dd <- tryCatch(db_q(con, glue("
    SELECT cast(PATID as string) AS PATID,
           LOT_NUM, LOT_START_TYPE,
           cast(cast(LOT_START_DT    as date) as string) AS sd,
           cast(cast(LOT_BASE_END_DT as date) as string) AS ed,
           LOT_BASE_END_REASON AS rsn,
           LOT_BASE_LENGTH     AS len,
           LOT_BASE_MEDS       AS meds
    FROM {lot_long}
    ORDER BY PATID, LOT_NUM
  ")), error = function(e) NULL)

  if (!is.null(dd) && is.data.frame(dd) && nrow(dd) > 0) {
    dd$LOT_NUM <- as.integer(dd$LOT_NUM)
    dd$len     <- suppressWarnings(as.numeric(dd$len))
    all_ids    <- unique(dd$PATID)
    truncated  <- length(all_ids) > max_pat
    keep_ids   <- head(all_ids, max_pat)
    dd <- dd[dd$PATID %in% keep_ids, , drop = FALSE]

    by_pat <- split(dd, dd$PATID)
    pj <- lapply(by_pat, function(d) {
      d <- d[order(d$LOT_NUM), , drop = FALSE]
      lapply(seq_len(nrow(d)), function(i) list(
        lot  = d$LOT_NUM[i],
        st   = ifelse(is.na(d$LOT_START_TYPE[i]), "", d$LOT_START_TYPE[i]),
        sd   = ifelse(is.na(d$sd[i]), "", d$sd[i]),
        ed   = ifelse(is.na(d$ed[i]), "", d$ed[i]),
        rsn  = ifelse(is.na(d$rsn[i]), "", d$rsn[i]),
        len  = ifelse(is.na(d$len[i]), 0, d$len[i]),
        meds = ifelse(is.na(d$meds[i]), "", d$meds[i])
      ))
    })
    pj_json <- jsonlite::toJSON(pj, auto_unbox = TRUE, force = TRUE)
    # Prevent any "</script>" inside data from closing the script tag.
    pj_json <- gsub("</", "<\\/", as.character(pj_json), fixed = TRUE)
    # Embed the shared start-type palette so the drilldown bar colours
    # match Sankey / MED journey (single source of truth in dashboard_lot.R).
    pal_json <- as.character(jsonlite::toJSON(
      as.list(lot_start_palette), auto_unbox = TRUE))

    # HTML-attribute-escape PATIDs before inlining (cheap hardening even
    # though clinical IDs are usually clean).
    esc_attr <- function(x) {
      x <- gsub("&", "&amp;",  as.character(x), fixed = TRUE)
      x <- gsub("<", "&lt;",   x, fixed = TRUE)
      x <- gsub(">", "&gt;",   x, fixed = TRUE)
      gsub('"', "&quot;", x, fixed = TRUE)
    }
    opts <- paste(sprintf('<option value="%s">', esc_attr(keep_ids)),
                  collapse = "")
    note <- if (truncated) paste0(
      '<p style="color:#b06000;font-size:12px">Showing first ',
      format(max_pat, big.mark = ","), ' of ',
      format(length(all_ids), big.mark = ","),
      ' patients (set DRILLDOWN_MAX_PATIENTS to raise).</p>') else ""

    drill_html <- paste0('
<div style="font-family:system-ui;padding:10px 6px">
  <h3 style="margin:0 0 6px">Patient drilldown</h3>
  <p style="color:#555;font-size:13px;margin:0 0 10px">Type or paste a
     PATID, then Enter / Show. Each bar is one LOT.</p>
  ', note, '
  <div style="display:flex;gap:8px;align-items:center;margin-bottom:12px">
    <input id="pjIn" list="pjList" placeholder="PATID"
           style="padding:8px 12px;border:1px solid #cdd6db;border-radius:6px;
                  font-size:13px;min-width:240px">
    <datalist id="pjList">', opts, '</datalist>
    <button id="pjBtn" style="padding:8px 16px;border:0;border-radius:6px;
            background:#2E86AB;color:#fff;font-weight:600;cursor:pointer">
      Show</button>
  </div>
  <div id="pjMeta" style="font-size:13px;margin-bottom:8px;color:#2d3436"></div>
  <div id="pjChart" style="position:relative"></div>
  <div id="pjLegend" style="margin-top:14px;font-size:12px;color:#555"></div>
</div>
<script>
var PJ = ', pj_json, ';
var PAL = ', pal_json, ';
function pjEsc(s){return String(s).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;");}
function pjDraw(pid){
  var meta=document.getElementById("pjMeta");
  var chart=document.getElementById("pjChart");
  var leg=document.getElementById("pjLegend");
  chart.innerHTML="";leg.innerHTML="";
  var rows=PJ[pid];
  if(!rows){meta.innerHTML="<span style=\\"color:#b00\\">PATID "+pjEsc(pid)+" not found.</span>";return;}
  var t0=null,t1=null;
  rows.forEach(function(r){
    if(r.sd){var a=Date.parse(r.sd);if(!isNaN(a)&&(t0===null||a<t0))t0=a;}
    var e=r.ed?Date.parse(r.ed):(r.sd?Date.parse(r.sd):NaN);
    if(!isNaN(e)&&(t1===null||e>t1))t1=e;
  });
  if(t0===null){meta.innerHTML="No usable dates for PATID "+pjEsc(pid)+".";return;}
  if(t1===null||t1<=t0)t1=t0+86400000;
  var span=t1-t0, maxlot=0;
  rows.forEach(function(r){if(r.lot>maxlot)maxlot=r.lot;});
  var term=rows.length?rows[rows.length-1].rsn:"";
  meta.innerHTML="<b>"+pjEsc(pid)+"</b> &nbsp; LOTs: "+rows.length+
    " &nbsp; max LOT_NUM: "+maxlot+" &nbsp; ends: <b>"+pjEsc(term)+"</b>";
  var rowH=34, H=maxlot*rowH+10;
  chart.style.height=H+"px";
  chart.style.borderLeft="1px solid #ccc";
  chart.style.background="#fafafa";
  rows.forEach(function(r){
    if(!r.sd)return;
    var a=Date.parse(r.sd), b=r.ed?Date.parse(r.ed):a;
    if(isNaN(a))return; if(isNaN(b)||b<a)b=a;
    var x=((a-t0)/span)*100, w=Math.max(((b-a)/span)*100,0.6);
    var y=(r.lot-1)*rowH+4;
    var c=PAL[r.st]||"#636e72";
    var bar=document.createElement("div");
    bar.style.cssText="position:absolute;left:"+x+"%;top:"+y+
      "px;width:"+w+"%;height:"+(rowH-10)+"px;background:"+c+
      ";border-radius:3px;opacity:.88;cursor:default";
    bar.title="LOT "+r.lot+"  ["+r.st+"]\\nStart: "+r.sd+"\\nEnd: "+r.ed+
      "\\nReason: "+r.rsn+"\\nLength(d): "+r.len+"\\nRegimen: "+r.meds;
    var lab=document.createElement("div");
    lab.style.cssText="position:absolute;left:4px;top:"+(y+2)+
      "px;font-size:11px;font-weight:600;color:#333";
    lab.textContent="LOT"+r.lot;
    chart.appendChild(bar);chart.appendChild(lab);
  });
  var lg="";Object.keys(PAL).forEach(function(k){
    lg+="<span style=\\"display:inline-block;margin-right:14px\\">"+
        "<span style=\\"display:inline-block;width:12px;height:12px;"+
        "background:"+PAL[k]+";border-radius:2px;vertical-align:middle;"+
        "margin-right:4px\\"></span>"+k+"</span>";});
  leg.innerHTML=lg+"<br><span style=\\"color:#888\\">Timeline: "+
    new Date(t0).toISOString().slice(0,10)+" \\u2192 "+
    new Date(t1).toISOString().slice(0,10)+"</span>";
}
function pjGo(){var v=document.getElementById("pjIn").value.trim();if(v)pjDraw(v);}
document.getElementById("pjBtn").addEventListener("click",pjGo);
document.getElementById("pjIn").addEventListener("change",pjGo);
document.getElementById("pjIn").addEventListener("keydown",function(e){if(e.key==="Enter")pjGo();});
var first=Object.keys(PJ)[0]; if(first){document.getElementById("pjIn").value=first;pjDraw(first);}
</script>')
    add_html_card(drill_html, section = "DRILLDOWN",
                  title = if (truncated) "Patient drilldown (embedded sample)"
                          else "Patient drilldown (any PATID)")
    log_msg("  Drilldown card: ", length(keep_ids), " patients embedded",
            if (truncated) paste0(" (capped from ", length(all_ids), ")") else "")
  } else {
    log_msg("  Drilldown: no LOT_LONG rows - section skipped.")
  }

  }  # end if (include_debug) - DEBUG + DRILLDOWN block
}

main <- function() {
  stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")
  # build_dashboard()/save_*() are gated on cfg$build_dashboard; force it
  # on for this standalone tool regardless of the env default.
  cfg$build_dashboard <<- TRUE

  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  lot_long <- wrk("LOT_LONG")
  log_msg("LOT1-5 dashboard - reading ", lot_long)

  if (!isTRUE(tryCatch(
        nrow(db_q(con, glue("SELECT 1 FROM {lot_long} LIMIT 1"))) >= 0,
        error = function(e) FALSE))) {
    stop("Cannot read ", lot_long,
         ". Build LOT_LONG (lot2_5_program.R / LOT2-5 stage) first.")
  }

  dashboard_items <<- list()
  collect_lot_long_views(con, lot_long)
  build_dashboard(
    out_name     = "lot_long_dashboard.html",
    header_title = "LOT 1-5 &mdash; Long-Format Dashboard",
    header_sub   = "Funnel &bull; Start/End &bull; Length &bull; Regimens &bull; Progression &bull; Gaps &bull; Transitions &bull; Sankey flows &bull; Med count &bull; MTX &bull; Trend &bull; Med Journeys &bull; Debug/QC &nbsp;&mdash;&nbsp; pick a Category above"
  )
  log_msg("LOT1-5 dashboard written to ",
          file.path(cfg$output_dir, "lot_long_dashboard.html"))
}

if (!interactive() && !isTRUE(getOption("lot_long_dashboard.no_autorun"))) main()
