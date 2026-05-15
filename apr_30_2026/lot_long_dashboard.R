#!/usr/bin/env Rscript
# ============================================================
# lot_long_dashboard.R - Standalone LOT1-5 dashboard
# ============================================================
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
# ============================================================

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
source(file.path(source_dir, "config_lot.R"))
source(file.path(source_dir, "db_utils_lot.R"))
source(file.path(source_dir, "dashboard_lot.R"))

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

  # Reset the shared collector (dashboard_lot.R defines it at load).
  dashboard_items <<- list()

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
             'present in LOT_LONG. Rebuild LOT_LONG (drop it, rerun the ',
             'LOT2-5 stage) to populate LOT2-5.</p>') else "",
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

  build_dashboard(
    out_name     = "lot_long_dashboard.html",
    header_title = "LOT 1-5 &mdash; Long-Format Dashboard",
    header_sub   = "Funnel &bull; Start Type &bull; End Reason &bull; Length &bull; Regimens (by LOT_NUM)"
  )
  log_msg("LOT1-5 dashboard written to ",
          file.path(cfg$output_dir, "lot_long_dashboard.html"))
}

main()
