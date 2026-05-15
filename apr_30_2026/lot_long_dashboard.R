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

  # ---- Patient journey examples (per-patient LOT timeline Gantt) ----
  # Mirrors the LOT1 dashboard's JOURNEY section, but each row of the
  # Gantt is a LOT (1..max) rather than a medication MAP. One bar per
  # LOT spans LOT_START_DT -> LOT_BASE_END_DT, colored by start type.
  if (has_plotly) {
    lot_start_palette <- c(
      "MED"      = "#2E86AB",
      "SCT_AUTO" = "#A23B72",
      "SCT_ALLO" = "#F18F01",
      "CART"     = "#C73E1D"
    )
    # One row per patient: furthest LOT + that final LOT's end reason.
    pat_pick <- db_q(con, glue("
      WITH pm AS (SELECT PATID, max(LOT_NUM) AS max_lot
                  FROM {lot_long} GROUP BY PATID)
      SELECT pm.PATID, pm.max_lot, ll.LOT_BASE_END_REASON AS terminal_reason
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
        SELECT PATID, LOT_NUM, LOT_START_TYPE,
               cast(LOT_START_DT   as date) AS LOT_START_DT,
               cast(LOT_BASE_END_DT as date) AS LOT_BASE_END_DT,
               LOT_BASE_END_REASON, LOT_BASE_LENGTH, LOT_BASE_MEDS
        FROM {lot_long}
        WHERE PATID IN ({id_list})
        ORDER BY PATID, LOT_NUM
      "))
      jdf$LOT_NUM        <- as.numeric(jdf$LOT_NUM)
      jdf$LOT_START_DT   <- as.Date(as.character(jdf$LOT_START_DT))
      jdf$LOT_BASE_END_DT<- as.Date(as.character(jdf$LOT_BASE_END_DT))

      k <- 0
      for (pid in pick_ids) {
        pr <- jdf[jdf$PATID == pid, , drop = FALSE]
        pr <- pr[order(pr$LOT_NUM), , drop = FALSE]
        if (nrow(pr) == 0) next
        if (all(is.na(pr$LOT_START_DT)) || all(is.na(pr$LOT_BASE_END_DT))) next
        k <- k + 1

        added <- tryCatch({
          shapes <- list()
          for (j in seq_len(nrow(pr))) {
            row   <- pr[j, ]
            st    <- as.character(row$LOT_START_TYPE)
            color <- if (!is.na(st) && st %in% names(lot_start_palette))
              lot_start_palette[[st]] else "#636e72"
            x0 <- if (is.na(row$LOT_START_DT)) NA else as.character(row$LOT_START_DT)
            x1 <- if (is.na(row$LOT_BASE_END_DT)) x0 else
              as.character(row$LOT_BASE_END_DT)
            if (is.na(x0)) next
            shapes[[length(shapes) + 1]] <- list(
              type = "rect", x0 = x0, x1 = x1,
              y0 = row$LOT_NUM - 0.32, y1 = row$LOT_NUM + 0.32,
              fillcolor = color, opacity = 0.85,
              line = list(color = color, width = 1), layer = "below"
            )
          }
          mid_x <- pr$LOT_START_DT +
            as.integer((pr$LOT_BASE_END_DT - pr$LOT_START_DT) / 2)
          hover_df <- data.frame(
            x = mid_x, y = pr$LOT_NUM,
            text = paste0(
              "LOT ", pr$LOT_NUM,
              "\nStart type: ", pr$LOT_START_TYPE,
              "\nStart: ", pr$LOT_START_DT,
              "\nEnd: ",   pr$LOT_BASE_END_DT,
              "\nEnd reason: ", pr$LOT_BASE_END_REASON,
              "\nLength (d): ", pr$LOT_BASE_LENGTH,
              "\nRegimen: ", pr$LOT_BASE_MEDS),
            stringsAsFactors = FALSE
          )
          term <- pr$LOT_BASE_END_REASON[nrow(pr)]
          pat_label <- paste0("Patient ", k)
          pp <- plotly::plot_ly(hover_df, x = ~x, y = ~y, text = ~text,
                                 type = "scatter", mode = "markers",
                                 marker = list(size = 1, opacity = 0),
                                 hoverinfo = "text") |>
            plotly::layout(
              title = list(text = paste0(pat_label, " — LOT Journey"),
                           font = list(size = 14)),
              xaxis = list(title = "", type = "date", gridcolor = "#eee"),
              yaxis = list(title = "LOT_NUM", tickmode = "array",
                           tickvals = sort(unique(pr$LOT_NUM)),
                           ticktext = paste0("LOT", sort(unique(pr$LOT_NUM))),
                           range = c(0.4, max(pr$LOT_NUM) + 0.7),
                           gridcolor = "#eee"),
              shapes = shapes, showlegend = FALSE,
              margin = list(l = 80, t = 50, b = 40, r = 30),
              plot_bgcolor = "#fafafa", paper_bgcolor = "white"
            ) |>
            plotly::config(displayModeBar = TRUE, displaylogo = FALSE)
          add_to_dashboard(pp, section = "JOURNEY",
                           title = paste0(pat_label, " (", nrow(pr),
                                          " LOTs, ends ", term, ")"))
          TRUE
        }, error = function(e) {
          log_msg("  INFO: skipping journey for a patient (",
                  conditionMessage(e), ")")
          FALSE
        })
        if (!isTRUE(added)) k <- k - 1
      }
      log_msg("  Patient journey examples added: ", k)
    }
  } else {
    log_msg("  plotly not available - skipping JOURNEY section.")
  }

  build_dashboard(
    out_name     = "lot_long_dashboard.html",
    header_title = "LOT 1-5 &mdash; Long-Format Dashboard",
    header_sub   = "Funnel &bull; Start Type &bull; End Reason &bull; Length &bull; Regimens &bull; Progression &bull; Gaps &bull; Transitions &bull; Patient Journeys"
  )
  log_msg("LOT1-5 dashboard written to ",
          file.path(cfg$output_dir, "lot_long_dashboard.html"))
}

main()
