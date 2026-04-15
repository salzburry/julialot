# ============================================================
# descriptives_lot.R — Descriptive summary and reporting
# ============================================================
# Extracted from lot_program.R during modularization.
# Contains: print_descriptives() — generates summary tables,
#   ggplot2 figures, HTML cards, patient journey timelines,
#   Sankey flow chart, and zoomed distributions.
# CYCLO deep-dive extracted to cyclo_appendix_lot.R.
# Dashboard build extracted to dashboard_lot.R.
# Requires: cfg, run_id, log_msg, db_q, SEP, DASH,
#   lot_palette, lot_class_palette, theme_lot, save_plot,
#   save_table, add_html_card, add_to_dashboard, has_ggplot2,
#   has_plotly, has_dt (from other modules)
# ============================================================

print_descriptives <- function(con) {
  cat("\n")
  cat(SEP, "\n")
  cat("        PART 2 DESCRIPTIVE SUMMARY                    \n")
  cat(SEP, "\n")

  # --------------------------------------------------------
  # 0a. Overview tab — run metadata + dynamic counts (FIRST tab)
  # --------------------------------------------------------
  tryCatch({
    # Dynamic run counts
    cohort_n   <- tryCatch(as.numeric(db_q(con, "SELECT count(DISTINCT PATID) AS n FROM lot_patient_input")$n), error = function(e) NA)
    mma_n      <- tryCatch(as.numeric(db_q(con, "SELECT count(*) AS n FROM mma_med_processed")$n), error = function(e) NA)
    mma_pat_n  <- tryCatch(as.numeric(db_q(con, "SELECT count(DISTINCT PATID) AS n FROM mma_med_processed")$n), error = function(e) NA)
    map_n      <- tryCatch(as.numeric(db_q(con, "SELECT count(*) AS n FROM map_stacked")$n), error = function(e) NA)
    map_pat_n  <- tryCatch(as.numeric(db_q(con, "SELECT count(DISTINCT PATID) AS n FROM map_stacked")$n), error = function(e) NA)
    lot1_n     <- tryCatch(as.numeric(db_q(con, "SELECT count(*) AS n FROM lot1_base")$n), error = function(e) NA)
    sct_n      <- tryCatch(as.numeric(db_q(con, "SELECT sum(CASE WHEN LOT1_TX_ENDDATE IS NOT NULL THEN 1 ELSE 0 END) AS n FROM lot1_sct")$n), error = function(e) NA)
    censored_n <- tryCatch({
      r <- db_q(con, "
        SELECT sum(case when ENDDATE_CE < ENDDATE then 1 else 0 end) AS n_cens,
               count(*) AS n_total
        FROM lot_patient_input
      ")
      list(n = as.numeric(r$n_cens), pct = round(100 * as.numeric(r$n_cens) / max(as.numeric(r$n_total), 1), 1))
    }, error = function(e) list(n = NA, pct = NA))

    fmt <- function(x) if (is.na(x)) "N/A" else format(x, big.mark = ",")

    overview_html <- paste0('<!DOCTYPE html><html><head>
<meta charset="UTF-8">
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
         background: #fff; padding: 24px; color: #2d3436; }
  h2 { font-size: 20px; color: #1a5276; margin-bottom: 16px; }
  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 14px; margin-bottom: 24px; }
  .card { background: #f5f6fa; border-radius: 8px; padding: 16px; border: 1px solid #dfe6e9; }
  .card h3 { font-size: 11px; color: #636e72; text-transform: uppercase;
             letter-spacing: 0.5px; margin-bottom: 6px; }
  .card .val { font-size: 24px; font-weight: 700; color: #2d3436; }
  .card .sub { font-size: 12px; color: #636e72; margin-top: 4px; }
  table { border-collapse: collapse; width: 100%; margin-top: 12px; }
  th, td { text-align: left; padding: 8px 12px; border-bottom: 1px solid #eee; font-size: 13px; }
  th { background: #f5f6fa; font-weight: 600; color: #636e72; text-transform: uppercase;
       letter-spacing: 0.5px; font-size: 11px; }
</style></head><body>
<h2>Run Overview</h2>
<div class="grid">
  <div class="card"><h3>Run ID</h3><div class="val" style="font-size:16px;word-break:break-all;">', run_id, '</div>
    <div class="sub">Generated: ', format(Sys.time(), "%Y-%m-%d %H:%M:%S"), '</div></div>
  <div class="card"><h3>Cohort Patients</h3><div class="val">', fmt(cohort_n), '</div></div>
  <div class="card"><h3>MMA Claims</h3><div class="val">', fmt(mma_n), '</div>
    <div class="sub">', fmt(mma_pat_n), ' patients</div></div>
  <div class="card"><h3>MAPs</h3><div class="val">', fmt(map_n), '</div>
    <div class="sub">', fmt(map_pat_n), ' patients</div></div>
  <div class="card"><h3>LOT1 Patients</h3><div class="val">', fmt(lot1_n), '</div></div>
  <div class="card"><h3>LOT-Ending SCT</h3><div class="val">', fmt(sct_n), '</div>
    <div class="sub">Patients with SCT ending LOT1</div></div>
  <div class="card"><h3>Censored (OBS_END)</h3><div class="val">',
    if (!is.na(censored_n$pct)) paste0(censored_n$pct, "%") else "N/A", '</div>
    <div class="sub">', fmt(censored_n$n), ' patients</div></div>
</div>
<h2>Configuration</h2>
<table>
<tr><th>Parameter</th><th>Value</th></tr>
<tr><td>CDM Schema</td><td>', cfg$cdm_schema, '</td></tr>
<tr><td>Work Schema</td><td>', cfg$work_schema, '</td></tr>
<tr><td>Input Cohort Table</td><td>', cfg$input_cohort_table, '</td></tr>
<tr><td>Induction Window</td><td>', cfg$induction_window_days, ' days</td></tr>
<tr><td>MAP Discontinuation Gap</td><td>', cfg$map_discon_gap_days, ' days</td></tr>
<tr><td>Medical Day Supply</td><td>', cfg$medical_day_supply, ' days</td></tr>
<tr><td>LOT Discontinuation Gap</td><td>', cfg$lot_discon_gap_days, ' days</td></tr>
</table>
</body></html>')
    add_html_card(overview_html, section = "OVERVIEW", title = "Run Overview")
  }, error = function(e) {
    log_msg("  WARNING: Overview tab generation failed: ", conditionMessage(e))
  })

  # --------------------------------------------------------
  # 0b. QC Summary tab — pass/fail validation checks (SECOND tab)
  # --------------------------------------------------------
  tryCatch({
    qc_rows <- list()
    add_qc <- function(check, value, status) {
      qc_rows[[length(qc_rows) + 1]] <<- sprintf(
        '<tr><td>%s</td><td>%s</td><td class="%s">%s</td></tr>',
        check, value,
        if (status == "PASS") "pass" else if (status == "WARN") "warn" else "fail",
        status
      )
    }

    orphan_n <- tryCatch({
      as.numeric(db_q(con, "
        SELECT count(DISTINCT c.CL_MED_ABBR) AS n
        FROM mma_codelist c LEFT JOIN mma_rollup r ON c.CL_MED_ABBR = r.CL_MED_ABBR
        WHERE r.CL_MED_ABBR IS NULL
      ")$n)
    }, error = function(e) NA)
    if (!is.na(orphan_n)) add_qc("Codelist meds not in rollup", orphan_n,
                                  if (orphan_n == 0) "PASS" else "WARN")

    uncoded_n <- tryCatch({
      as.numeric(db_q(con, "
        SELECT count(DISTINCT r.CL_MED_ABBR) AS n
        FROM mma_rollup r LEFT JOIN mma_codelist c ON r.CL_MED_ABBR = c.CL_MED_ABBR
        WHERE c.CL_MED_ABBR IS NULL
      ")$n)
    }, error = function(e) NA)
    if (!is.na(uncoded_n)) add_qc("Rollup meds with zero codes", uncoded_n,
                                   if (uncoded_n == 0) "PASS" else "WARN")

    multi_n <- tryCatch({
      as.numeric(db_q(con, "
        SELECT count(*) AS n FROM (
          SELECT CL_MED_ABBR FROM mma_codelist
          GROUP BY CL_MED_ABBR HAVING count(DISTINCT CL_MED_CLASS) > 1
        )
      ")$n)
    }, error = function(e) NA)
    if (!is.na(multi_n)) add_qc("MED_ABBR mapped to multiple classes", multi_n,
                                 if (multi_n == 0) "PASS" else "WARN")

    bad_maps <- tryCatch({
      as.numeric(db_q(con, "SELECT count(*) AS n FROM map_stacked WHERE MAP_END_DT < MAP_START_DT")$n)
    }, error = function(e) NA)
    if (!is.na(bad_maps)) add_qc("MAPs with END_DT < START_DT", bad_maps,
                                  if (bad_maps == 0) "PASS" else "FAIL")

    runout_mm <- tryCatch({
      as.numeric(db_q(con, "
        SELECT count(*) AS n FROM map_stacked
        WHERE MAP_END_DT <> greatest(
          coalesce(MAP_RX_RUNOUT_DT, cast('1900-01-01' as date)),
          coalesce(MAP_MED_RUNOUT_DT, cast('1900-01-01' as date)))
        AND MAP_END_DT IS NOT NULL
      ")$n)
    }, error = function(e) NA)
    if (!is.na(runout_mm)) add_qc("MAPs where END != max(runouts)", runout_mm,
                                   if (runout_mm == 0) "PASS" else "WARN")

    lot1_past <- tryCatch({
      as.numeric(db_q(con, "
        SELECT sum(case when lb.LOT1_BASE_END_DT > p.OBS_END_DT then 1 else 0 end) AS n
        FROM lot1_base_end lb INNER JOIN lot_patient_input p ON lb.PATID = p.PATID
      ")$n)
    }, error = function(e) NA)
    if (!is.na(lot1_past)) add_qc("LOT1 END_DT past OBS_END_DT", lot1_past,
                                   if (lot1_past == 0) "PASS" else "WARN")

    sct_both <- tryCatch({
      as.numeric(db_q(con, "
        SELECT sum(CASE WHEN LOT1_SCT_AUTO_TAND_FLG = 1 AND LOT1_SCT_AUTO_SING_FLG = 1 THEN 1 ELSE 0 END) AS n
        FROM lot1_sct
      ")$n)
    }, error = function(e) NA)
    if (!is.na(sct_both)) add_qc("SCT: both tandem AND single flag", sct_both,
                                  if (sct_both == 0) "PASS" else "FAIL")

    sct_past <- tryCatch({
      as.numeric(db_q(con, "
        SELECT sum(CASE WHEN sct.LOT1_TX_ENDDATE IS NOT NULL
                    AND sct.LOT1_TX_ENDDATE > lb.OBS_END_DT THEN 1 ELSE 0 END) AS n
        FROM lot1_sct sct INNER JOIN lot1_base lb ON sct.PATID = lb.PATID
      ")$n)
    }, error = function(e) NA)
    if (!is.na(sct_past)) add_qc("SCT end date past OBS_END_DT", sct_past,
                                  if (sct_past == 0) "PASS" else "WARN")

    n_pass <- sum(sapply(qc_rows, function(r) grepl('class="pass"', r)))
    n_total <- length(qc_rows)

    qc_html <- paste0('<!DOCTYPE html><html><head>
<meta charset="UTF-8">
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
         background: #fff; padding: 24px; color: #2d3436; }
  h2 { font-size: 20px; color: #1a5276; margin-bottom: 8px; }
  .summary { font-size: 14px; color: #636e72; margin-bottom: 16px; }
  table { border-collapse: collapse; width: 100%; }
  th, td { text-align: left; padding: 10px 14px; border-bottom: 1px solid #eee; font-size: 13px; }
  th { background: #f5f6fa; font-weight: 600; color: #636e72; text-transform: uppercase;
       letter-spacing: 0.5px; font-size: 11px; }
  .pass { color: #00b894; font-weight: 700; }
  .warn { color: #fdcb6e; font-weight: 700; }
  .fail { color: #d63031; font-weight: 700; }
</style></head><body>
<h2>QC Validation Summary</h2>
<p class="summary">', n_pass, ' / ', n_total, ' checks passed</p>
<table>
<tr><th>Check</th><th>Value</th><th>Status</th></tr>
', paste(qc_rows, collapse = "\n"), '
</table>
</body></html>')
    add_html_card(qc_html, section = "QC", title = "QC Summary")
  }, error = function(e) {
    log_msg("  WARNING: QC summary tab generation failed: ", conditionMessage(e))
  })

  # --------------------------------------------------------
  # 1. MMA_MED Summary
  # --------------------------------------------------------
  tryCatch({
    cat("\n", DASH, "\n")
    cat("  5A. MMA_MED (Medication Claims) Summary\n")
    cat(DASH, "\n")

    mma_stats <- db_q(con, "
      SELECT
        count(*)                                     AS n_rows,
        count(DISTINCT PATID)                        AS n_patients,
        count(DISTINCT MED_ABBR)                     AS n_meds,
        sum(case when CLAIM_TYPE='pharmacy' then 1 else 0 end) AS n_pharmacy,
        sum(case when CLAIM_TYPE='medical'  then 1 else 0 end) AS n_medical,
        min(DATE_SERVICE) AS min_date,
        max(DATE_SERVICE) AS max_date,
        avg(DAY_SUPPLY)   AS avg_day_supply,
        percentile_approx(DAY_SUPPLY, 0.5) AS median_day_supply
      FROM mma_med_processed
    ")
    cat(sprintf("  Total claims (de-duped):     %s\n", format(mma_stats$n_rows, big.mark = ",")))
    cat(sprintf("  Distinct patients:           %s\n", format(mma_stats$n_patients, big.mark = ",")))
    cat(sprintf("  Distinct medications:        %s\n", format(mma_stats$n_meds, big.mark = ",")))
    cat(sprintf("  Pharmacy claims:             %s\n", format(mma_stats$n_pharmacy, big.mark = ",")))
    cat(sprintf("  Medical claims:              %s\n", format(mma_stats$n_medical, big.mark = ",")))
    cat(sprintf("  Date range:                  %s to %s\n", mma_stats$min_date, mma_stats$max_date))
    cat(sprintf("  Avg day supply:              %.1f (median: %.0f)\n",
                mma_stats$avg_day_supply, mma_stats$median_day_supply))

    # Claims by medication
    med_dist <- db_q(con, "
      SELECT MED_ABBR, MED_CLASS,
             count(*) AS n_claims,
             count(DISTINCT PATID) AS n_patients,
             sum(case when CLAIM_TYPE='pharmacy' then 1 else 0 end) AS n_rx,
             sum(case when CLAIM_TYPE='medical' then 1 else 0 end) AS n_med
      FROM mma_med_processed
      GROUP BY MED_ABBR, MED_CLASS
      ORDER BY count(DISTINCT PATID) DESC
    ")
    cat("\n")
    cat(sprintf("  %-8s %-12s %10s %10s %8s %8s\n", "Med", "Class", "Claims", "Patients", "RX", "Medical"))
    cat(strrep("-", 62), "\n")
    for (i in seq_len(nrow(med_dist))) {
      r <- med_dist[i, ]
      cat(sprintf("  %-8s %-12s %10s %10s %8s %8s\n",
                  r$MED_ABBR, r$MED_CLASS,
                  format(r$n_claims, big.mark = ","),
                  format(r$n_patients, big.mark = ","),
                  format(r$n_rx, big.mark = ","),
                  format(r$n_med, big.mark = ",")))
    }

    # Figure 1: Patients by medication (bar chart)
    if (has_ggplot2 && nrow(med_dist) > 0) {
      med_dist$n_patients <- as.numeric(med_dist$n_patients)
      med_dist$n_claims   <- as.numeric(med_dist$n_claims)
      med_dist$n_rx       <- as.numeric(med_dist$n_rx)
      med_dist$n_med      <- as.numeric(med_dist$n_med)
      p1 <- ggplot(med_dist,
                    aes(x = reorder(MED_ABBR, -n_patients), y = n_patients,
                        fill = MED_CLASS, text = paste0(
                          "Med: ", MED_ABBR, "\nClass: ", MED_CLASS,
                          "\nPatients: ", format(n_patients, big.mark = ","),
                          "\nClaims: ", format(n_claims, big.mark = ",")))) +
        geom_bar(stat = "identity", width = 0.75) +
        geom_text(aes(label = format(n_patients, big.mark = ",")),
                  vjust = -0.4, size = 3, color = "grey30") +
        scale_fill_manual(values = lot_class_palette, na.value = "grey50") +
        scale_y_continuous(labels = scales::comma_format(), expand = expansion(mult = c(0, 0.12))) +
        labs(title = "MMA_MED: Patients by Medication",
             subtitle = paste0("N = ", format(sum(med_dist$n_patients), big.mark = ","),
                               " patient-medication combinations across ",
                               nrow(med_dist), " medications"),
             x = NULL, y = "Distinct Patients", fill = "Drug Class") +
        theme_lot() +
        theme(axis.text.x = element_text(angle = 45, hjust = 1, size = 10))
      save_plot(p1, "fig01_mma_patients_by_med.png",
               section = "MMA_MED", title = "Fig 1: Patients by Medication")
      save_table(med_dist, section = "MMA_MED",
                 title = "Table: MMA Claims by Medication")
    }

    # Figure 2: Pharmacy vs Medical claims stacked bar
    if (has_ggplot2 && nrow(med_dist) > 0) {
      claim_long <- rbind(
        data.frame(MED_ABBR = med_dist$MED_ABBR, MED_CLASS = med_dist$MED_CLASS,
                   CLAIM_TYPE = "Pharmacy", N = as.numeric(med_dist$n_rx)),
        data.frame(MED_ABBR = med_dist$MED_ABBR, MED_CLASS = med_dist$MED_CLASS,
                   CLAIM_TYPE = "Medical",  N = as.numeric(med_dist$n_med))
      )
      # Compute total claims per med for correct ordering
      total_by_med <- tapply(claim_long$N, claim_long$MED_ABBR, sum)
      claim_long$MED_ABBR <- factor(claim_long$MED_ABBR,
                                     levels = names(sort(total_by_med, decreasing = TRUE)))
      p2 <- ggplot(claim_long,
                    aes(x = MED_ABBR, y = N, fill = CLAIM_TYPE,
                        text = paste0("Med: ", MED_ABBR, "\nType: ", CLAIM_TYPE,
                                      "\nClaims: ", format(N, big.mark = ",")))) +
        geom_bar(stat = "identity", position = "stack", width = 0.75) +
        scale_fill_manual(values = c("Pharmacy" = "#2E86AB", "Medical" = "#C73E1D")) +
        scale_y_continuous(labels = scales::comma_format(), expand = expansion(mult = c(0, 0.08))) +
        labs(title = "MMA_MED: Claims by Type and Medication",
             subtitle = "Pharmacy (NDC-based) vs Medical (procedure/NDC) claim sources",
             x = NULL, y = "Claim Count", fill = "Claim Type") +
        theme_lot() +
        theme(axis.text.x = element_text(angle = 45, hjust = 1, size = 10))
      save_plot(p2, "fig02_mma_claims_by_type.png",
               section = "MMA_MED", title = "Fig 2: Claims by Type")
    }

    # Day supply distribution
    ds_dist <- db_q(con, "
      SELECT CLAIM_TYPE,
             min(DAY_SUPPLY) AS min_ds,
             percentile_approx(DAY_SUPPLY, 0.25) AS p25_ds,
             percentile_approx(DAY_SUPPLY, 0.5)  AS median_ds,
             percentile_approx(DAY_SUPPLY, 0.75) AS p75_ds,
             max(DAY_SUPPLY) AS max_ds,
             avg(DAY_SUPPLY) AS mean_ds
      FROM mma_med_processed
      GROUP BY CLAIM_TYPE
    ")
    cat("\n  Day Supply Distribution:\n")
    cat(sprintf("  %-10s %6s %6s %6s %6s %6s %8s\n", "Type", "Min", "P25", "Med", "P75", "Max", "Mean"))
    cat(strrep("-", 55), "\n")
    for (i in seq_len(nrow(ds_dist))) {
      r <- ds_dist[i, ]
      cat(sprintf("  %-10s %6.0f %6.0f %6.0f %6.0f %6.0f %8.1f\n",
                  r$CLAIM_TYPE, r$min_ds, r$p25_ds, r$median_ds, r$p75_ds, r$max_ds, r$mean_ds))
    }

  }, error = function(e) {
    log_msg("WARN: MMA_MED descriptives failed: ", conditionMessage(e))
  })

  # --------------------------------------------------------
  # 2. MAP Summary
  # --------------------------------------------------------
  cat("\n", DASH, "\n")
  cat("  5B. MAP_MED (Medication Available Periods) Summary\n")
  cat(DASH, "\n")

  # Use a subquery for MAP length to avoid percentile_approx on expression
  map_stats <- tryCatch(db_q(con, "
    SELECT
      count(*)               AS n_maps,
      count(DISTINCT PATID)  AS n_patients,
      count(DISTINCT MAP_MED_TYPE) AS n_meds,
      avg(map_length)        AS avg_map_length,
      percentile_approx(map_length, 0.5) AS median_map_length,
      min(map_length)        AS min_map_length,
      max(map_length)        AS max_map_length,
      sum(CAST(MAP_DISCON_FLG AS INT)) AS n_discon
    FROM (
      SELECT *, datediff(MAP_END_DT, MAP_START_DT) + 1 AS map_length
      FROM map_stacked
    )
  "), error = function(e) {
    log_msg("WARN: MAP stats query failed: ", conditionMessage(e))
    data.frame()
  })
  if (nrow(map_stats) > 0) {
    cat(sprintf("  Total MAPs:                  %s\n", format(map_stats$n_maps, big.mark = ",")))
    cat(sprintf("  Distinct patients:           %s\n", format(map_stats$n_patients, big.mark = ",")))
    cat(sprintf("  Distinct medications:        %s\n", format(map_stats$n_meds, big.mark = ",")))
    cat(sprintf("  MAP length (days):           mean=%.1f, median=%.0f, range=[%s, %s]\n",
                map_stats$avg_map_length, map_stats$median_map_length,
                format(map_stats$min_map_length, big.mark = ","),
                format(map_stats$max_map_length, big.mark = ",")))
    cat(sprintf("  MAPs with discontinuation:   %s (%.1f%%)\n",
                format(map_stats$n_discon, big.mark = ","),
                100 * map_stats$n_discon / max(map_stats$n_maps, 1)))
  }

  # MAPs per patient distribution
  maps_per_pt <- tryCatch(db_q(con, "
    SELECT n_maps, count(*) AS n_patients
    FROM (SELECT PATID, count(*) AS n_maps FROM map_stacked GROUP BY PATID)
    GROUP BY n_maps
    ORDER BY n_maps
  "), error = function(e) {
    log_msg("WARN: MAPs per patient query failed: ", conditionMessage(e))
    data.frame()
  })
  if (nrow(maps_per_pt) > 0) {
    cat("\n  MAPs per patient distribution:\n")
    cat(sprintf("  %-8s %10s\n", "# MAPs", "Patients"))
    cat(strrep("-", 22), "\n")
    for (i in seq_len(min(nrow(maps_per_pt), 15))) {
      r <- maps_per_pt[i, ]
      cat(sprintf("  %-8s %10s\n", format(as.integer(r$n_maps)), format(r$n_patients, big.mark = ",")))
    }
    if (nrow(maps_per_pt) > 15) cat("  ... (truncated)\n")
  }

  # MAP by medication
  map_by_med <- tryCatch(db_q(con, "
    SELECT
      MAP_MED_TYPE AS med,
      MAP_MED_CLASS AS class,
      count(*) AS n_maps,
      count(DISTINCT PATID) AS n_patients,
      avg(datediff(MAP_END_DT, MAP_START_DT) + 1) AS avg_map_days,
      sum(CAST(MAP_DISCON_FLG AS INT)) AS n_discon,
      sum(CASE WHEN MAP_RX_RUNOUT_DT IS NOT NULL AND MAP_MED_RUNOUT_DT IS NOT NULL THEN 1 ELSE 0 END) AS n_both_types
    FROM map_stacked
    GROUP BY MAP_MED_TYPE, MAP_MED_CLASS
    ORDER BY count(DISTINCT PATID) DESC
  "), error = function(e) {
    log_msg("WARN: MAP by med query failed: ", conditionMessage(e))
    data.frame()
  })
  if (nrow(map_by_med) > 0) {
    cat("\n")
    cat(sprintf("  %-8s %-12s %6s %8s %10s %7s %9s\n",
                "Med", "Class", "MAPs", "Patients", "Avg Days", "Discon", "Both Src"))
    cat(strrep("-", 66), "\n")
    for (i in seq_len(nrow(map_by_med))) {
      r <- map_by_med[i, ]
      cat(sprintf("  %-8s %-12s %6s %8s %9.1f %7s %9s\n",
                  r$med, r$class,
                  format(r$n_maps, big.mark = ","),
                  format(r$n_patients, big.mark = ","),
                  r$avg_map_days,
                  format(r$n_discon, big.mark = ","),
                  format(r$n_both_types, big.mark = ",")))
    }
  }

  # Figure 3: MAP length distribution (histogram via SQL-binned counts)
  tryCatch({
    if (has_ggplot2) {
      map_bins <- db_q(con, "
        SELECT bin_start, count(*) AS n
        FROM (
          SELECT floor((datediff(MAP_END_DT, MAP_START_DT) + 1) / 30) * 30 AS bin_start
          FROM map_stacked
        )
        GROUP BY bin_start
        ORDER BY bin_start
      ")
      if (nrow(map_bins) > 0) {
        map_bins$bin_start <- as.numeric(map_bins$bin_start)
        map_bins$n         <- as.numeric(map_bins$n)
        median_map <- if (nrow(map_stats) > 0) as.numeric(map_stats$median_map_length) else NA
        p3 <- ggplot(map_bins, aes(x = bin_start, y = n,
                                    text = paste0("Days: ", bin_start, "-", bin_start + 29,
                                                  "\nMAPs: ", format(n, big.mark = ",")))) +
          geom_bar(stat = "identity", width = 28, fill = "#2E86AB", alpha = 0.85) +
          { if (!is.na(median_map)) geom_vline(xintercept = median_map,
                     linetype = "dashed", color = "#C73E1D", linewidth = 0.8) } +
          { if (!is.na(median_map)) annotate("text", x = median_map + 25, y = Inf, vjust = 2, hjust = 0,
                   label = paste0("Median: ", round(median_map), " days"),
                   color = "#C73E1D", fontface = "bold", size = 3.8) } +
          scale_x_continuous(breaks = seq(0, max(map_bins$bin_start, na.rm = TRUE), by = 90)) +
          scale_y_continuous(labels = scales::comma_format(), expand = expansion(mult = c(0, 0.1))) +
          labs(title = "MAP Length Distribution",
               subtitle = paste0(format(sum(map_bins$n), big.mark = ","), " medication-available periods, 30-day bins"),
               x = "MAP Length (days)", y = "Number of MAPs") +
          theme_lot()
        save_plot(p3, "fig03_map_length_distribution.png",
                 section = "MAP", title = "Fig 3: MAP Length Distribution")
      }
    }
  }, error = function(e) {
    log_msg("WARN: fig03 MAP length distribution failed: ", conditionMessage(e))
  })

  # Figure 4: MAP count by medication (bar)
  tryCatch({
    if (has_ggplot2 && nrow(map_by_med) > 0) {
      map_by_med$n_patients <- as.numeric(map_by_med$n_patients)
      map_by_med$n_maps     <- as.numeric(map_by_med$n_maps)
      map_by_med$n_discon   <- as.numeric(map_by_med$n_discon)
      p4 <- ggplot(map_by_med,
                    aes(x = reorder(med, -n_patients), y = n_patients, fill = class,
                        text = paste0("Med: ", med, "\nClass: ", class,
                                      "\nPatients: ", format(n_patients, big.mark = ","),
                                      "\nMAPs: ", format(n_maps, big.mark = ","),
                                      "\nAvg Days: ", round(avg_map_days, 1)))) +
        geom_bar(stat = "identity", width = 0.75) +
        geom_text(aes(label = format(n_patients, big.mark = ",")),
                  vjust = -0.4, size = 3, color = "grey30") +
        scale_fill_manual(values = lot_class_palette, na.value = "grey50") +
        scale_y_continuous(labels = scales::comma_format(), expand = expansion(mult = c(0, 0.12))) +
        labs(title = "MAP: Patients by Medication",
             subtitle = "Medication-available periods across all drug classes",
             x = NULL, y = "Distinct Patients", fill = "Drug Class") +
        theme_lot() +
        theme(axis.text.x = element_text(angle = 45, hjust = 1, size = 10))
      save_plot(p4, "fig04_map_patients_by_med.png",
               section = "MAP", title = "Fig 4: MAP Patients by Medication")
      map_by_med$avg_map_days <- round(as.numeric(map_by_med$avg_map_days), 1)
      save_table(map_by_med, section = "MAP",
                 title = "Table: MAP Summary by Medication")
    }
  }, error = function(e) {
    log_msg("WARN: fig04 MAP patients by med failed: ", conditionMessage(e))
  })

  # --------------------------------------------------------
  # 3. LOT1 Summary
  # --------------------------------------------------------
  tryCatch({
    cat("\n", DASH, "\n")
    cat("  6. LOT1_BASE Summary\n")
    cat(DASH, "\n")

    lot1_stats <- db_q(con, "
      SELECT
        count(*) AS n_patients,
        avg(datediff(LOT1_START_DT, INDEX_DATE)) AS avg_days_to_lot1,
        avg(LOT1_MED_CNT) AS avg_induction_meds,
        avg(LOT1_BASE_LENGTH) AS avg_lot1_length,
        percentile_approx(LOT1_BASE_LENGTH, 0.5) AS median_lot1_length,
        min(LOT1_BASE_LENGTH) AS min_lot1_length,
        max(LOT1_BASE_LENGTH) AS max_lot1_length,
        sum(case when LOT1_BASE_DISCON_DT is not null then 1 else 0 end) AS n_discon,
        sum(case when LOT1_BASE_1ST_ADD_MED_DT is not null then 1 else 0 end) AS n_add_med
      FROM lot1_base_end
    ")
    cat(sprintf("  Total LOT1 patients:         %s\n", format(lot1_stats$n_patients, big.mark = ",")))
    cat(sprintf("  Avg days index->LOT1:        %.1f\n", lot1_stats$avg_days_to_lot1))
    cat(sprintf("  Avg induction meds:          %.1f\n", lot1_stats$avg_induction_meds))
    cat(sprintf("  LOT1 length (days):          mean=%.1f, median=%.0f, range=[%s, %s]\n",
                lot1_stats$avg_lot1_length, lot1_stats$median_lot1_length,
                format(lot1_stats$min_lot1_length, big.mark = ","),
                format(lot1_stats$max_lot1_length, big.mark = ",")))
    cat(sprintf("  With discontinuation date:   %s (%.1f%%)\n",
                format(lot1_stats$n_discon, big.mark = ","),
                100 * lot1_stats$n_discon / max(lot1_stats$n_patients, 1)))
    cat(sprintf("  With medication add:         %s (%.1f%%)\n",
                format(lot1_stats$n_add_med, big.mark = ","),
                100 * lot1_stats$n_add_med / max(lot1_stats$n_patients, 1)))

    # LOT1 end reasons
    end_reasons <- db_q(con, "
      SELECT LOT1_BASE_END_REASON, count(*) AS n,
             avg(datediff(LOT1_BASE_END_DT, LOT1_START_DT) + 1) AS avg_length
      FROM lot1_base_end
      GROUP BY LOT1_BASE_END_REASON
      ORDER BY count(*) DESC
    ")
    total_lot1 <- lot1_stats$n_patients
    cat("\n  LOT1 BASE End Reasons:\n")
    cat(sprintf("  %-20s %10s %8s %10s\n", "Reason", "N", "%", "Avg Days"))
    cat(strrep("-", 52), "\n")
    for (i in seq_len(nrow(end_reasons))) {
      r <- end_reasons[i, ]
      cat(sprintf("  %-20s %10s %7.1f%% %10.1f\n",
                  r$LOT1_BASE_END_REASON,
                  format(r$n, big.mark = ","),
                  100 * r$n / max(total_lot1, 1),
                  r$avg_length))
    }

    # Induction regimen distribution (Top 25)
    regimens <- db_q(con, "
      SELECT
        LOT1_BASE_MEDS AS regimen,
        count(*) AS n_patients,
        avg(LOT1_BASE_LENGTH) AS avg_length,
        avg(LOT1_MED_CNT) AS avg_meds
      FROM lot1_base_end
      GROUP BY LOT1_BASE_MEDS
      ORDER BY count(*) DESC
      LIMIT 25
    ")
    cat("\n  Top 25 LOT1 Induction Regimens:\n")
    cat(sprintf("  %-40s %8s %7s %9s\n", "Regimen", "N", "%", "Avg Days"))
    cat(strrep("-", 68), "\n")
    for (i in seq_len(nrow(regimens))) {
      r <- regimens[i, ]
      cat(sprintf("  %-40s %8s %6.1f%% %8.1f\n",
                  substr(r$regimen, 1, 40),
                  format(r$n_patients, big.mark = ","),
                  100 * r$n_patients / max(total_lot1, 1),
                  r$avg_length))
    }

    # Figure 5: LOT1 induction regimen frequency (top 15 horizontal bar)
    if (has_ggplot2 && nrow(regimens) > 0) {
      regimens$n_patients <- as.numeric(regimens$n_patients)
      top15 <- head(regimens, 15)
      top15$pct <- 100 * top15$n_patients / as.numeric(max(total_lot1, 1))
      top15$regimen <- factor(top15$regimen, levels = rev(top15$regimen))
      p5 <- ggplot(top15, aes(x = regimen, y = n_patients,
                               text = paste0("Regimen: ", regimen,
                                             "\nPatients: ", format(n_patients, big.mark = ","),
                                             "\n% of LOT1: ", round(pct, 1), "%",
                                             "\nAvg Length: ", round(avg_length, 0), " days"))) +
        geom_bar(stat = "identity", fill = "#44BBA4", width = 0.7) +
        geom_text(aes(label = paste0(format(n_patients, big.mark = ","),
                                     " (", round(pct, 1), "%)")),
                  hjust = -0.05, size = 3.2, color = "grey30") +
        coord_flip() +
        scale_y_continuous(labels = scales::comma_format(), expand = expansion(mult = c(0, 0.2))) +
        labs(title = "LOT1: Top 15 Induction Regimens",
             subtitle = paste0("Out of ", format(as.numeric(total_lot1), big.mark = ","), " LOT1 patients"),
             x = NULL, y = "Number of Patients") +
        theme_lot() +
        theme(legend.position = "none")
      save_plot(p5, "fig05_lot1_top_regimens.png", width = 12, height = 7,
               section = "LOT1", title = "Fig 5: Top 15 Induction Regimens")
      regimens$avg_length <- round(as.numeric(regimens$avg_length), 1)
      regimens$avg_meds   <- round(as.numeric(regimens$avg_meds), 1)
      save_table(regimens, section = "LOT1",
                 title = "Table: Top 25 Induction Regimens")
    }

    # Figure 6: LOT1 base length distribution (SQL-binned to avoid OOM)
    if (has_ggplot2) {
      lot1_bins <- db_q(con, "
        SELECT floor(LOT1_BASE_LENGTH / 30) * 30 AS bin_start,
               count(*) AS n
        FROM lot1_base_end
        WHERE LOT1_BASE_LENGTH IS NOT NULL
        GROUP BY floor(LOT1_BASE_LENGTH / 30) * 30
        ORDER BY bin_start
      ")
      lot1_median <- db_q(con, "
        SELECT percentile_approx(LOT1_BASE_LENGTH, 0.5) AS median_len
        FROM lot1_base_end
        WHERE LOT1_BASE_LENGTH IS NOT NULL
      ")
      if (nrow(lot1_bins) > 0) {
        lot1_bins$bin_start  <- as.numeric(lot1_bins$bin_start)
        lot1_bins$n          <- as.numeric(lot1_bins$n)
        median_len <- if (nrow(lot1_median) > 0) as.numeric(lot1_median$median_len) else NA
        p6 <- ggplot(lot1_bins, aes(x = bin_start, y = n,
                                     text = paste0("Days: ", bin_start, "-", bin_start + 29,
                                                   "\nPatients: ", format(n, big.mark = ",")))) +
          geom_bar(stat = "identity", width = 28, fill = "#44BBA4", alpha = 0.85) +
          { if (!is.na(median_len)) geom_vline(xintercept = median_len,
                     linetype = "dashed", color = "#C73E1D", linewidth = 0.8) } +
          { if (!is.na(median_len)) annotate("text", x = median_len + 25, y = Inf, vjust = 2, hjust = 0,
                   label = paste0("Median: ", round(median_len), " days"),
                   color = "#C73E1D", fontface = "bold", size = 3.8) } +
          scale_x_continuous(breaks = seq(0, max(lot1_bins$bin_start, na.rm = TRUE), by = 180)) +
          scale_y_continuous(labels = scales::comma_format(), expand = expansion(mult = c(0, 0.1))) +
          labs(title = "LOT1 BASE Length Distribution",
               subtitle = paste0(format(sum(lot1_bins$n), big.mark = ","),
                                 " patients, 30-day bins"),
               x = "LOT1 BASE Length (days)", y = "Number of Patients") +
          theme_lot()
        save_plot(p6, "fig06_lot1_base_length.png",
                 section = "LOT1", title = "Fig 6: LOT1 Length Distribution")
      }
    }

    # Figure 7: LOT1 end reason bar chart
    if (has_ggplot2 && nrow(end_reasons) > 0) {
      end_reasons$n <- as.numeric(end_reasons$n)
      end_reasons$pct <- 100 * end_reasons$n / sum(end_reasons$n)
      end_reason_colors <- c(
        "DISCONTINUATION" = "#C73E1D", "MED_ADD" = "#F18F01",
        "DEATH" = "#2E86AB", "DISENROLLMENT" = "#5DA9C8",
        "STUDY_END" = "#8DC4DB", "SCT_AUTO" = "#A23B72",
        "SCT_ALLO" = "#8D5A97", "SCT_CART" = "#3F88C5", "SCT" = "#393E41",
        "SCT_NO_MAINT" = "#B47EB3", "MAINTENANCE_END" = "#44AF69"
      )
      p7 <- ggplot(end_reasons,
                    aes(x = reorder(LOT1_BASE_END_REASON, -n), y = n,
                        fill = LOT1_BASE_END_REASON,
                        text = paste0("Reason: ", LOT1_BASE_END_REASON,
                                      "\nPatients: ", format(n, big.mark = ","),
                                      "\n%: ", round(pct, 1), "%",
                                      "\nAvg LOT1 Length: ", round(avg_length, 0), " days"))) +
        geom_bar(stat = "identity", width = 0.7) +
        geom_text(aes(label = paste0(format(n, big.mark = ","), "\n(", round(pct, 1), "%)")),
                  vjust = -0.3, size = 3.5, color = "grey20") +
        scale_fill_manual(values = end_reason_colors) +
        scale_y_continuous(labels = scales::comma_format(), expand = expansion(mult = c(0, 0.15))) +
        labs(title = "LOT1 BASE End Reasons",
             subtitle = paste0("How LOT1 ended for ", format(sum(end_reasons$n), big.mark = ","), " patients"),
             x = NULL, y = "Number of Patients") +
        theme_lot() +
        theme(legend.position = "none")
      save_plot(p7, "fig07_lot1_end_reasons.png", width = 8, height = 6,
               section = "LOT1", title = "Fig 7: LOT1 End Reasons")
      end_reasons$avg_length <- round(as.numeric(end_reasons$avg_length), 1)
      end_reasons$pct        <- round(end_reasons$pct, 1)
      save_table(end_reasons, section = "LOT1",
                 title = "Table: LOT1 End Reasons")
    }

    # Figure 8: Induction med count distribution
    if (has_ggplot2) {
      med_cnt <- db_q(con, "
        SELECT LOT1_MED_CNT, count(*) AS n
        FROM lot1_base
        GROUP BY LOT1_MED_CNT
        ORDER BY LOT1_MED_CNT
      ")
      if (nrow(med_cnt) > 0) {
        med_cnt$n   <- as.numeric(med_cnt$n)
        med_cnt$LOT1_MED_CNT <- as.numeric(med_cnt$LOT1_MED_CNT)
        med_cnt$pct <- 100 * med_cnt$n / sum(med_cnt$n)
        p8 <- ggplot(med_cnt, aes(x = factor(LOT1_MED_CNT), y = n,
                                   text = paste0("Meds: ", LOT1_MED_CNT,
                                                 "\nPatients: ", format(n, big.mark = ","),
                                                 "\n%: ", round(pct, 1), "%"))) +
          geom_bar(stat = "identity", fill = "#2E86AB", width = 0.65) +
          geom_text(aes(label = paste0(format(n, big.mark = ","), "\n(", round(pct, 1), "%)")),
                    vjust = -0.3, size = 3.5, color = "grey20") +
          scale_y_continuous(labels = scales::comma_format(), expand = expansion(mult = c(0, 0.15))) +
          labs(title = "LOT1: Number of Induction Medications per Patient",
               subtitle = "How many distinct medications each patient received in induction",
               x = "Number of Induction Meds", y = "Patients") +
          theme_lot()
        save_plot(p8, "fig08_lot1_med_count.png", width = 8, height = 6,
                 section = "LOT1", title = "Fig 8: Induction Med Count")
      }
    }

    # Drug class distribution
    cat("\n  LOT1 Drug Class Distribution (from induction meds):\n")
    class_dist <- db_q(con, "
      SELECT MED_CLASS, count(DISTINCT PATID) AS n_patients
      FROM lot1_induction_meds
      GROUP BY MED_CLASS
      ORDER BY count(DISTINCT PATID) DESC
    ")
    cat(sprintf("  %-20s %10s %8s\n", "Class", "Patients", "%"))
    cat(strrep("-", 42), "\n")
    for (i in seq_len(nrow(class_dist))) {
      r <- class_dist[i, ]
      cat(sprintf("  %-20s %10s %7.1f%%\n",
                  r$MED_CLASS, format(r$n_patients, big.mark = ","),
                  100 * r$n_patients / max(total_lot1, 1)))
    }

  }, error = function(e) {
    log_msg("WARN: LOT1 descriptives failed: ", conditionMessage(e))
  })

  # --------------------------------------------------------
  # 4. SCT Summary
  # --------------------------------------------------------
  tryCatch({
    cat("\n", DASH, "\n")
    cat("  7. SCT (Stem Cell Transplant) Summary\n")
    cat(DASH, "\n")

    sct_raw_stats <- tryCatch(db_q(con, "
      SELECT SCT_TYPE, count(*) AS n_claims, count(DISTINCT PATID) AS n_patients
      FROM sct_claims_raw
      GROUP BY SCT_TYPE
      ORDER BY SCT_TYPE
    "), error = function(e) data.frame())
    if (nrow(sct_raw_stats) > 0) {
      cat("  Raw SCT claims by type:\n")
      cat(sprintf("  %-8s %10s %10s\n", "Type", "Claims", "Patients"))
      cat(strrep("-", 32), "\n")
      for (i in seq_len(nrow(sct_raw_stats))) {
        r <- sct_raw_stats[i, ]
        cat(sprintf("  %-8s %10s %10s\n",
                    r$SCT_TYPE, format(r$n_claims, big.mark = ","),
                    format(r$n_patients, big.mark = ",")))
      }
    } else {
      cat("  No SCT claims found.\n")
    }

    sct_lot1_stats <- tryCatch(db_q(con, "
      SELECT
        count(*) AS n_patients,
        sum(CASE WHEN LOT1_TX_AUTO_DT_1 IS NOT NULL THEN 1 ELSE 0 END) AS n_with_auto,
        sum(CASE WHEN FIRST_ALLO_DT IS NOT NULL THEN 1 ELSE 0 END) AS n_with_allo,
        sum(CASE WHEN FIRST_CART_DT IS NOT NULL THEN 1 ELSE 0 END) AS n_with_cart,
        sum(LOT1_SCT_AUTO_TAND_FLG) AS n_tandem,
        sum(LOT1_SCT_AUTO_SING_FLG) AS n_single_auto,
        sum(CASE WHEN LOT1_TX_ENDDATE IS NOT NULL THEN 1 ELSE 0 END) AS n_sct_end
      FROM lot1_sct
    "), error = function(e) data.frame())
    if (nrow(sct_lot1_stats) > 0) {
      cat(sprintf("\n  LOT1 SCT Summary (of %s LOT1 patients):\n",
                  format(sct_lot1_stats$n_patients, big.mark = ",")))
      cat(sprintf("    With AUTO SCT:      %s (%.1f%%)\n",
                  format(sct_lot1_stats$n_with_auto, big.mark = ","),
                  100 * sct_lot1_stats$n_with_auto / max(sct_lot1_stats$n_patients, 1)))
      cat(sprintf("      Tandem AUTO:      %s\n", format(sct_lot1_stats$n_tandem, big.mark = ",")))
      cat(sprintf("      Single AUTO:      %s\n", format(sct_lot1_stats$n_single_auto, big.mark = ",")))
      cat(sprintf("    With ALLO SCT:      %s (%.1f%%)\n",
                  format(sct_lot1_stats$n_with_allo, big.mark = ","),
                  100 * sct_lot1_stats$n_with_allo / max(sct_lot1_stats$n_patients, 1)))
      cat(sprintf("    With CAR-T:         %s (%.1f%%)\n",
                  format(sct_lot1_stats$n_with_cart, big.mark = ","),
                  100 * sct_lot1_stats$n_with_cart / max(sct_lot1_stats$n_patients, 1)))
      cat(sprintf("    SCT ending LOT1:    %s (%.1f%%)\n",
                  format(sct_lot1_stats$n_sct_end, big.mark = ","),
                  100 * sct_lot1_stats$n_sct_end / max(sct_lot1_stats$n_patients, 1)))
    }

    # SCT end reason breakdown
    sct_end_reasons <- tryCatch(db_q(con, "
      SELECT
        CASE LOT1_TX_ENDDATE_REASON
          WHEN 1 THEN 'AUTO' WHEN 2 THEN 'ALLO' WHEN 3 THEN 'CART' ELSE 'NONE'
        END AS SCT_END_TYPE,
        count(*) AS n
      FROM lot1_sct
      WHERE LOT1_TX_ENDDATE IS NOT NULL
      GROUP BY LOT1_TX_ENDDATE_REASON
      ORDER BY LOT1_TX_ENDDATE_REASON
    "), error = function(e) data.frame())
    if (nrow(sct_end_reasons) > 0) {
      cat("\n  SCT End Reason (within patients whose LOT1 ends due to SCT):\n")
      cat(sprintf("  %-8s %10s\n", "Type", "N"))
      cat(strrep("-", 20), "\n")
      for (i in seq_len(nrow(sct_end_reasons))) {
        r <- sct_end_reasons[i, ]
        cat(sprintf("  %-8s %10s\n", r$SCT_END_TYPE, format(r$n, big.mark = ",")))
      }
    }

    cat("\n", SEP, "\n")
    cat("  END OF DESCRIPTIVE SUMMARY\n")
    cat(SEP, "\n")

  }, error = function(e) {
    log_msg("WARN: SCT descriptives failed: ", conditionMessage(e))
  })

  # --------------------------------------------------------
  # 5. Patient journey timelines — sample of interesting patients
  # --------------------------------------------------------
  tryCatch({
    if (has_plotly) {
      # Find interesting patients: those with med restarts (MAP_CNT >= 2),
      # add-meds, or SCT events. Sample up to 20.
      journey_pats <- db_q(con, "
        WITH interesting AS (
          -- Patients with same-med restarts
          SELECT DISTINCT PATID, 'restart' AS reason
          FROM map_stacked WHERE MAP_CNT >= 2
          UNION
          -- Patients with add-med
          SELECT DISTINCT PATID, 'add_med'
          FROM lot1_base WHERE LOT1_BASE_1ST_ADD_MED_DT IS NOT NULL
          UNION
          -- Patients with SCT
          SELECT DISTINCT PATID, 'sct'
          FROM lot1_sct WHERE LOT1_TX_ENDDATE IS NOT NULL
        )
        SELECT PATID, concat_ws(',', collect_set(reason)) AS reasons
        FROM interesting
        GROUP BY PATID
        ORDER BY length(concat_ws(',', collect_set(reason))) DESC
        LIMIT 20
      ")

      if (nrow(journey_pats) > 0) {
        pat_ids_sql <- paste0("('", paste(journey_pats$PATID, collapse = "','"), "')")

        # Get MAP segments for these patients
        journey_maps <- db_q(con, glue("
          SELECT m.PATID, m.MAP_MED_TYPE AS MED, m.MAP_MED_CLASS AS CLASS,
                 m.MAP_START_DT, m.MAP_END_DT, m.MAP_CNT,
                 m.MAP_DISCON_FLG,
                 datediff(m.MAP_END_DT, m.MAP_START_DT) + 1 AS MAP_DAYS
          FROM map_stacked m
          WHERE m.PATID IN {pat_ids_sql}
          ORDER BY m.PATID, m.MAP_MED_TYPE, m.MAP_START_DT
        "))

        # Get LOT1 milestones
        journey_milestones <- db_q(con, glue("
          SELECT lb.PATID,
                 lb.LOT1_START_DT,
                 lb.LOT1_BASE_1ST_ADD_MED_DT,
                 lbe.LOT1_BASE_END_DT,
                 lbe.LOT1_BASE_END_REASON,
                 sct.LOT1_1ST_SCT_DT AS SCT_DT
          FROM lot1_base lb
          LEFT JOIN lot1_base_end lbe ON lb.PATID = lbe.PATID
          LEFT JOIN lot1_sct sct ON lb.PATID = sct.PATID
          WHERE lb.PATID IN {pat_ids_sql}
        "))

        if (nrow(journey_maps) > 0) {
          # Convert types
          journey_maps$MAP_START_DT <- as.Date(journey_maps$MAP_START_DT)
          journey_maps$MAP_END_DT   <- as.Date(journey_maps$MAP_END_DT)
          journey_maps$MAP_CNT      <- as.numeric(journey_maps$MAP_CNT)
          journey_maps$MAP_DAYS     <- as.numeric(journey_maps$MAP_DAYS)

          # Render one plotly timeline per patient, collect them
          # Use first 10 patients max for dashboard size
          show_pats <- unique(journey_maps$PATID)[1:min(10, length(unique(journey_maps$PATID)))]

          for (pid in show_pats) {
            pat_maps <- journey_maps[journey_maps$PATID == pid, ]
            if (nrow(pat_maps) == 0) next
            pat_ms   <- journey_milestones[journey_milestones$PATID == pid, ]
            reasons  <- if (pid %in% journey_pats$PATID) {
              journey_pats$reasons[journey_pats$PATID == pid]
            } else ""

            # Build plotly shapes for Gantt bars
            # Y-axis: medication names, X-axis: dates
            meds <- sort(unique(pat_maps$MED))
            med_y <- setNames(seq_along(meds), meds)

            shapes <- list()
            annotations <- list()
            hover_texts <- list()

            for (j in seq_len(nrow(pat_maps))) {
              row <- pat_maps[j, ]
              y_pos <- med_y[row$MED]
              color <- if (row$CLASS %in% names(lot_class_palette)) lot_class_palette[row$CLASS] else "#636e72"
              # Make restart segments slightly different shade
              alpha_val <- if (row$MAP_CNT > 1) 0.6 else 0.85

              shapes[[length(shapes) + 1]] <- list(
                type = "rect",
                x0 = as.character(row$MAP_START_DT),
                x1 = as.character(row$MAP_END_DT),
                y0 = y_pos - 0.35,
                y1 = y_pos + 0.35,
                fillcolor = color,
                opacity = alpha_val,
                line = list(color = color, width = 1),
                layer = "below"
              )
            }

            # Milestone vertical lines
            vlines <- list()
            if (nrow(pat_ms) > 0) {
              ms <- pat_ms[1, ]
              add_vline <- function(dt, label, color) {
                if (!is.na(dt) && !is.null(dt)) {
                  vlines[[length(vlines) + 1]] <<- list(
                    type = "line", x0 = as.character(dt), x1 = as.character(dt),
                    y0 = 0.3, y1 = length(meds) + 0.7,
                    line = list(color = color, width = 2, dash = "dash"),
                    layer = "above"
                  )
                  annotations[[length(annotations) + 1]] <<- list(
                    x = as.character(dt), y = length(meds) + 0.6,
                    text = label, showarrow = FALSE,
                    font = list(size = 10, color = color),
                    xanchor = "left", textangle = -30
                  )
                }
              }
              add_vline(as.Date(ms$LOT1_START_DT), "LOT1 Start", "#2E86AB")
              add_vline(as.Date(ms$LOT1_BASE_1ST_ADD_MED_DT), "Add Med", "#F18F01")
              add_vline(as.Date(ms$LOT1_BASE_END_DT), paste0("LOT1 End (", ms$LOT1_BASE_END_REASON, ")"), "#C73E1D")
              add_vline(as.Date(ms$SCT_DT), "SCT", "#8D5A97")
            }

            all_shapes <- c(shapes, vlines)

            # Create invisible scatter for hover
            hover_df <- data.frame(
              x = pat_maps$MAP_START_DT + as.integer((pat_maps$MAP_END_DT - pat_maps$MAP_START_DT) / 2),
              y = med_y[pat_maps$MED],
              text = paste0(
                "Med: ", pat_maps$MED,
                "\nClass: ", pat_maps$CLASS,
                "\nStart: ", pat_maps$MAP_START_DT,
                "\nEnd: ", pat_maps$MAP_END_DT,
                "\nDays: ", pat_maps$MAP_DAYS,
                "\nMAP #", pat_maps$MAP_CNT,
                {
                  discon_flg <- pat_maps$MAP_DISCON_FLG
                  if (is.null(discon_flg)) discon_flg <- rep(0L, nrow(pat_maps))
                  ifelse(discon_flg == 1, "\nDiscon: Yes", "")
                }
              ),
              stringsAsFactors = FALSE
            )

            # Anonymized patient label
            pat_label <- paste0("Patient ", which(show_pats == pid))
            pp <- plotly::plot_ly(hover_df, x = ~x, y = ~y, text = ~text,
                                  type = "scatter", mode = "markers",
                                  marker = list(size = 1, opacity = 0),
                                  hoverinfo = "text") |>
              plotly::layout(
                title = list(text = paste0(pat_label, " — Medication Journey"),
                             font = list(size = 14)),
                xaxis = list(title = "", type = "date",
                             gridcolor = "#eee"),
                yaxis = list(title = "", tickmode = "array",
                             tickvals = seq_along(meds),
                             ticktext = meds,
                             range = c(0.3, length(meds) + 0.8),
                             gridcolor = "#eee"),
                shapes = all_shapes,
                annotations = annotations,
                showlegend = FALSE,
                margin = list(l = 100, t = 50, b = 40, r = 30),
                plot_bgcolor = "#fafafa",
                paper_bgcolor = "white"
              ) |>
              plotly::config(displayModeBar = TRUE, displaylogo = FALSE,
                             modeBarButtonsToRemove = list("lasso2d", "select2d"))

            add_to_dashboard(pp, section = "JOURNEY",
                             title = paste0(pat_label, " (", reasons, ")"))
          }
          log_msg("  Patient journey timelines added: ", length(show_pats), " patients")
        }
      } else {
        log_msg("  No interesting patients found for journey timelines.")
      }
    }
  }, error = function(e) {
    log_msg("WARN: Patient journey timelines failed: ", conditionMessage(e))
  })

  # --------------------------------------------------------
  # 6. Restart / Gap Summary Table
  # --------------------------------------------------------
  tryCatch({
    restart_summary <- db_q(con, "
      WITH gaps AS (
        SELECT
          a.PATID, a.MAP_MED_TYPE AS MED, a.MAP_MED_CLASS AS CLASS,
          a.MAP_CNT,
          datediff(a.MAP_START_DT, b.MAP_END_DT) - 1 AS gap_days
        FROM map_stacked a
        INNER JOIN map_stacked b
          ON a.PATID = b.PATID
          AND a.MAP_MED_TYPE = b.MAP_MED_TYPE
          AND a.MAP_CNT = b.MAP_CNT + 1
      )
      SELECT
        MED, CLASS,
        count(DISTINCT PATID) AS n_patients_with_restart,
        count(*) AS n_restarts,
        round(avg(gap_days), 1) AS avg_gap_days,
        percentile_approx(gap_days, 0.25) AS p25_gap,
        percentile_approx(gap_days, 0.5) AS median_gap,
        percentile_approx(gap_days, 0.75) AS p75_gap,
        max(gap_days) AS max_gap
      FROM gaps
      GROUP BY MED, CLASS
      ORDER BY count(DISTINCT PATID) DESC
    ")
    if (nrow(restart_summary) > 0) {
      for (col in c("avg_gap_days", "p25_gap", "median_gap", "p75_gap", "max_gap")) {
        restart_summary[[col]] <- as.numeric(restart_summary[[col]])
      }
      restart_summary$n_patients_with_restart <- as.numeric(restart_summary$n_patients_with_restart)
      restart_summary$n_restarts <- as.numeric(restart_summary$n_restarts)
      save_table(restart_summary, section = "JOURNEY",
                 title = "Table: Restart/Gap Summary by Medication")
      log_msg("  Restart/gap summary table added.")
    }
  }, error = function(e) {
    log_msg("WARN: Restart/gap summary failed: ", conditionMessage(e))
  })

  # --------------------------------------------------------
  # 7. True regimen-state timeline (contiguous regimen segments)
  #    Derives change-point intervals where the active med set is constant.
  #    Y-axis: regimen labels (e.g., "BORT+LENA"), X-axis: date range.
  #    Gaps between segments are visible as whitespace.
  # --------------------------------------------------------
  tryCatch({
    if (has_plotly) {
      # Select patients with interesting regimen transitions:
      # add-med events, restarts, or multiple distinct regimens
      regimen_pats <- db_q(con, "
        WITH change_patients AS (
          SELECT PATID FROM lot1_base WHERE LOT1_BASE_1ST_ADD_MED_DT IS NOT NULL
          UNION
          SELECT PATID FROM map_stacked WHERE MAP_CNT >= 2
          UNION
          SELECT PATID FROM (
            SELECT PATID, count(DISTINCT MAP_MED_TYPE) AS n_meds
            FROM map_stacked GROUP BY PATID HAVING count(DISTINCT MAP_MED_TYPE) >= 2
          )
        )
        SELECT DISTINCT PATID FROM change_patients LIMIT 8
      ")

      if (nrow(regimen_pats) > 0) {
        rp_ids_sql <- paste0("('", paste(regimen_pats$PATID, collapse = "','"), "')")

        # Get all MAPs for these patients
        reg_maps <- db_q(con, glue("
          SELECT PATID, MAP_MED_TYPE AS MED, MAP_MED_CLASS AS CLASS,
                 MAP_START_DT, MAP_END_DT, MAP_CNT
          FROM map_stacked
          WHERE PATID IN {rp_ids_sql}
          ORDER BY PATID, MAP_START_DT, MAP_MED_TYPE
        "))

        # Get milestones
        reg_ms <- db_q(con, glue("
          SELECT lb.PATID, lb.LOT1_START_DT,
                 lb.LOT1_BASE_1ST_ADD_MED_DT, lb.LOT1_BASE_MEDS,
                 lbe.LOT1_BASE_END_DT, lbe.LOT1_BASE_END_REASON
          FROM lot1_base lb
          LEFT JOIN lot1_base_end lbe ON lb.PATID = lbe.PATID
          WHERE lb.PATID IN {rp_ids_sql}
        "))

        if (nrow(reg_maps) > 0) {
          reg_maps$MAP_START_DT <- as.Date(reg_maps$MAP_START_DT)
          reg_maps$MAP_END_DT   <- as.Date(reg_maps$MAP_END_DT)

          show_reg_pats <- unique(reg_maps$PATID)[1:min(6, length(unique(reg_maps$PATID)))]

          for (pid in show_reg_pats) {
            pat_m <- reg_maps[reg_maps$PATID == pid, ]
            pat_info <- reg_ms[reg_ms$PATID == pid, ]

            # --- Derive regimen segments from MAP change points ---
            # Collect all boundary dates (MAP starts and MAP ends + 1 day)
            boundary_dates <- sort(unique(c(pat_m$MAP_START_DT, pat_m$MAP_END_DT + 1)))

            segments <- list()
            for (k in seq_len(length(boundary_dates) - 1)) {
              seg_start <- boundary_dates[k]
              seg_end   <- boundary_dates[k + 1] - 1  # inclusive end

              # Which MAPs are active during this segment?
              active <- pat_m[pat_m$MAP_START_DT <= seg_start & pat_m$MAP_END_DT >= seg_end, ]
              if (nrow(active) > 0) {
                active_meds <- paste(sort(unique(active$MED)), collapse = "+")
                segments[[length(segments) + 1]] <- data.frame(
                  start = seg_start, end = seg_end,
                  regimen = active_meds,
                  n_meds = length(unique(active$MED)),
                  stringsAsFactors = FALSE
                )
              }
              # If no MAPs active, this is a gap — no segment added, shows as whitespace
            }

            if (length(segments) == 0) next
            seg_df <- do.call(rbind, segments)

            # Merge consecutive segments with the same regimen
            merged <- list(seg_df[1, ])
            for (k in seq_len(nrow(seg_df))[-1]) {
              prev <- merged[[length(merged)]]
              curr <- seg_df[k, ]
              if (curr$regimen == prev$regimen && curr$start <= prev$end + 1) {
                # Extend previous segment
                merged[[length(merged)]]$end <- max(prev$end, curr$end)
              } else {
                merged[[length(merged) + 1]] <- curr
              }
            }
            seg_df <- do.call(rbind, merged)
            seg_df$days <- as.numeric(seg_df$end - seg_df$start) + 1

            # Assign y-positions: unique regimens
            reg_labels <- unique(seg_df$regimen)
            reg_y <- setNames(seq_along(reg_labels), reg_labels)

            # Color palette for regimens (cycle through a set)
            reg_colors <- c("#2E86AB", "#44BBA4", "#F18F01", "#C73E1D", "#A23B72",
                           "#3F88C5", "#8D5A97", "#636e72", "#E8A87C", "#41B3A3")

            shapes <- list()
            for (j in seq_len(nrow(seg_df))) {
              row <- seg_df[j, ]
              y_pos <- reg_y[row$regimen]
              color <- reg_colors[((y_pos - 1) %% length(reg_colors)) + 1]

              shapes[[length(shapes) + 1]] <- list(
                type = "rect",
                x0 = as.character(row$start), x1 = as.character(row$end),
                y0 = y_pos - 0.35, y1 = y_pos + 0.35,
                fillcolor = color, opacity = 0.85,
                line = list(color = color, width = 1),
                layer = "below"
              )
            }

            # Milestone vertical lines
            vlines <- list()
            annotations <- list()
            if (nrow(pat_info) > 0) {
              ms <- pat_info[1, ]
              add_vline3 <- function(dt, label, color) {
                if (!is.na(dt) && !is.null(dt)) {
                  vlines[[length(vlines) + 1]] <<- list(
                    type = "line", x0 = as.character(dt), x1 = as.character(dt),
                    y0 = 0.3, y1 = length(reg_labels) + 0.7,
                    line = list(color = color, width = 2, dash = "dash"), layer = "above"
                  )
                  annotations[[length(annotations) + 1]] <<- list(
                    x = as.character(dt), y = length(reg_labels) + 0.6,
                    text = label, showarrow = FALSE,
                    font = list(size = 10, color = color),
                    xanchor = "left", textangle = -30
                  )
                }
              }
              add_vline3(as.Date(ms$LOT1_START_DT), "LOT1 Start", "#2E86AB")
              add_vline3(as.Date(ms$LOT1_BASE_1ST_ADD_MED_DT), "Add Med", "#F18F01")
              add_vline3(as.Date(ms$LOT1_BASE_END_DT),
                         paste0("LOT1 End (", ms$LOT1_BASE_END_REASON, ")"), "#C73E1D")
            }

            # Hover trace
            hover_df3 <- data.frame(
              x = seg_df$start + as.integer((seg_df$end - seg_df$start) / 2),
              y = reg_y[seg_df$regimen],
              text = paste0("Regimen: ", seg_df$regimen,
                           "\nStart: ", seg_df$start, "\nEnd: ", seg_df$end,
                           "\nDays: ", seg_df$days,
                           "\nMeds: ", seg_df$n_meds),
              stringsAsFactors = FALSE
            )

            pat_idx <- which(show_reg_pats == pid)
            regimen_label <- if (nrow(pat_info) > 0) pat_info$LOT1_BASE_MEDS[1] else "?"
            pp2 <- plotly::plot_ly(hover_df3, x = ~x, y = ~y, text = ~text,
                                    type = "scatter", mode = "markers",
                                    marker = list(size = 1, opacity = 0),
                                    hoverinfo = "text") |>
              plotly::layout(
                title = list(
                  text = paste0("Regimen State ", pat_idx, " [", regimen_label, "]"),
                  font = list(size = 14)),
                xaxis = list(title = "", type = "date", gridcolor = "#eee"),
                yaxis = list(title = "", tickmode = "array",
                             tickvals = seq_along(reg_labels), ticktext = reg_labels,
                             range = c(0.3, length(reg_labels) + 0.8), gridcolor = "#eee"),
                shapes = c(shapes, vlines),
                annotations = annotations,
                showlegend = FALSE,
                margin = list(l = 140, t = 50, b = 40, r = 30),
                plot_bgcolor = "#fafafa", paper_bgcolor = "white"
              ) |>
              plotly::config(displayModeBar = TRUE, displaylogo = FALSE,
                             modeBarButtonsToRemove = list("lasso2d", "select2d"))

            add_to_dashboard(pp2, section = "JOURNEY",
                             title = paste0("Regimen State ", pat_idx, ": ", regimen_label))
          }
          log_msg("  Regimen-state timelines added: ", length(show_reg_pats), " patients")
        }
      }
    }
  }, error = function(e) {
    log_msg("WARN: Regimen-state timelines failed: ", conditionMessage(e))
  })

  # --------------------------------------------------------
  # 8. Improved distribution views — zoomed to p95
  # --------------------------------------------------------
  tryCatch({
    if (has_ggplot2) {
      # MAP length zoomed
      map_p95 <- tryCatch(
        as.numeric(db_q(con, "SELECT percentile_approx(datediff(MAP_END_DT, MAP_START_DT) + 1, 0.95) AS p95 FROM map_stacked")$p95),
        error = function(e) NA)
      if (!is.na(map_p95)) {
        map_bins_z <- db_q(con, glue("
          SELECT floor((datediff(MAP_END_DT, MAP_START_DT) + 1) / 30) * 30 AS bin_start,
                 count(*) AS n
          FROM map_stacked
          WHERE datediff(MAP_END_DT, MAP_START_DT) + 1 <= {round(map_p95 * 1.1)}
          GROUP BY floor((datediff(MAP_END_DT, MAP_START_DT) + 1) / 30) * 30
          ORDER BY bin_start
        "))
        if (nrow(map_bins_z) > 0) {
          map_bins_z$bin_start <- as.numeric(map_bins_z$bin_start)
          map_bins_z$n <- as.numeric(map_bins_z$n)
          map_median_z <- tryCatch(
            as.numeric(db_q(con, "SELECT percentile_approx(datediff(MAP_END_DT, MAP_START_DT) + 1, 0.5) AS m FROM map_stacked")$m),
            error = function(e) NA)
          pz1 <- ggplot(map_bins_z, aes(x = bin_start, y = n,
                        text = paste0("Days: ", bin_start, "-", bin_start + 29,
                                      "\nMAPs: ", format(n, big.mark = ",")))) +
            geom_bar(stat = "identity", width = 28, fill = "#2E86AB", alpha = 0.85) +
            { if (!is.na(map_median_z)) geom_vline(xintercept = map_median_z,
                       linetype = "dashed", color = "#C73E1D", linewidth = 0.8) } +
            { if (!is.na(map_median_z)) annotate("text", x = map_median_z + 15, y = Inf, vjust = 2, hjust = 0,
                     label = paste0("Median: ", round(map_median_z), "d"),
                     color = "#C73E1D", fontface = "bold", size = 3.8) } +
            scale_x_continuous(breaks = seq(0, max(map_bins_z$bin_start, na.rm = TRUE), by = 90)) +
            scale_y_continuous(labels = scales::comma_format(), expand = expansion(mult = c(0, 0.1))) +
            labs(title = "MAP Length Distribution (Zoomed to P95)",
                 subtitle = paste0("Clipped at ", round(map_p95), " days (95th percentile); ",
                                   format(sum(map_bins_z$n), big.mark = ","), " MAPs shown"),
                 x = "MAP Length (days)", y = "Number of MAPs") +
            theme_lot()
          save_plot(pz1, "fig03b_map_length_zoomed.png",
                   section = "MAP", title = "Fig 3b: MAP Length (Zoomed)")
        }
      }

      # LOT1 length zoomed
      lot1_p95 <- tryCatch(
        as.numeric(db_q(con, "SELECT percentile_approx(LOT1_BASE_LENGTH, 0.95) AS p95 FROM lot1_base_end WHERE LOT1_BASE_LENGTH IS NOT NULL")$p95),
        error = function(e) NA)
      if (!is.na(lot1_p95)) {
        lot1_bins_z <- db_q(con, glue("
          SELECT floor(LOT1_BASE_LENGTH / 30) * 30 AS bin_start,
                 count(*) AS n
          FROM lot1_base_end
          WHERE LOT1_BASE_LENGTH IS NOT NULL AND LOT1_BASE_LENGTH <= {round(lot1_p95 * 1.1)}
          GROUP BY floor(LOT1_BASE_LENGTH / 30) * 30
          ORDER BY bin_start
        "))
        if (nrow(lot1_bins_z) > 0) {
          lot1_bins_z$bin_start <- as.numeric(lot1_bins_z$bin_start)
          lot1_bins_z$n <- as.numeric(lot1_bins_z$n)
          lot1_median_z <- tryCatch(
            as.numeric(db_q(con, "SELECT percentile_approx(LOT1_BASE_LENGTH, 0.5) AS m FROM lot1_base_end WHERE LOT1_BASE_LENGTH IS NOT NULL")$m),
            error = function(e) NA)
          pz2 <- ggplot(lot1_bins_z, aes(x = bin_start, y = n,
                        text = paste0("Days: ", bin_start, "-", bin_start + 29,
                                      "\nPatients: ", format(n, big.mark = ",")))) +
            geom_bar(stat = "identity", width = 28, fill = "#44BBA4", alpha = 0.85) +
            { if (!is.na(lot1_median_z)) geom_vline(xintercept = lot1_median_z,
                       linetype = "dashed", color = "#C73E1D", linewidth = 0.8) } +
            { if (!is.na(lot1_median_z)) annotate("text", x = lot1_median_z + 15, y = Inf, vjust = 2, hjust = 0,
                     label = paste0("Median: ", round(lot1_median_z), "d"),
                     color = "#C73E1D", fontface = "bold", size = 3.8) } +
            scale_x_continuous(breaks = seq(0, max(lot1_bins_z$bin_start, na.rm = TRUE), by = 90)) +
            scale_y_continuous(labels = scales::comma_format(), expand = expansion(mult = c(0, 0.1))) +
            labs(title = "LOT1 Length Distribution (Zoomed to P95)",
                 subtitle = paste0("Clipped at ", round(lot1_p95), " days (95th percentile); ",
                                   format(sum(lot1_bins_z$n), big.mark = ","), " patients shown"),
                 x = "LOT1 Length (days)", y = "Number of Patients") +
            theme_lot()
          save_plot(pz2, "fig06b_lot1_length_zoomed.png",
                   section = "LOT1", title = "Fig 6b: LOT1 Length (Zoomed)")
        }
      }
    }
  }, error = function(e) {
    log_msg("WARN: Zoomed distribution views failed: ", conditionMessage(e))
  })

  # --------------------------------------------------------
  # 9. SCT zero-state card (when no SCT events detected)
  # --------------------------------------------------------
  tryCatch({
    sct_event_n <- tryCatch(
      as.numeric(db_q(con, "SELECT sum(CASE WHEN LOT1_TX_ENDDATE IS NOT NULL THEN 1 ELSE 0 END) AS n FROM lot1_sct")$n),
      error = function(e) 0)
    sct_codes_n <- tryCatch(
      as.numeric(db_q(con, "SELECT count(*) AS n FROM sct_codelist")$n),
      error = function(e) NA)
    sct_raw_n <- tryCatch(
      as.numeric(db_q(con, "SELECT count(*) AS n FROM sct_claims_raw")$n),
      error = function(e) 0)

    if (sct_event_n == 0) {
      sct_html <- paste0('<!DOCTYPE html><html><head><meta charset="UTF-8">
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
         background: #fff; padding: 32px; color: #2d3436; }
  .zero-state { text-align: center; padding: 60px 24px; }
  .zero-state h2 { font-size: 22px; color: #636e72; margin-bottom: 12px; }
  .zero-state p  { font-size: 14px; color: #b2bec3; margin-bottom: 8px; }
  .info-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(200px, 1fr));
               gap: 12px; max-width: 600px; margin: 24px auto 0; }
  .info-card { background: #f5f6fa; border-radius: 8px; padding: 14px;
               border: 1px solid #dfe6e9; text-align: left; }
  .info-card h4 { font-size: 11px; color: #636e72; text-transform: uppercase;
                  letter-spacing: 0.5px; margin-bottom: 4px; }
  .info-card .val { font-size: 18px; font-weight: 700; color: #2d3436; }
</style></head><body>
<div class="zero-state">
  <h2>No LOT-Ending SCT Events</h2>
  <p>No stem cell transplant events ended LOT1 in this run.</p>
  <p>Raw SCT claims may still exist but did not meet LOT-ending criteria. This may be expected if the cohort does not include transplant-eligible patients.</p>
  <div class="info-grid">
    <div class="info-card"><h4>SCT Codes Loaded</h4><div class="val">',
        if (!is.na(sct_codes_n)) format(sct_codes_n, big.mark = ",") else "N/A",
        '</div></div>
    <div class="info-card"><h4>Raw SCT Claims Found</h4><div class="val">',
        format(sct_raw_n, big.mark = ","),
        '</div></div>
    <div class="info-card"><h4>SCT Ending LOT1</h4><div class="val">0</div></div>
  </div>
</div></body></html>')
      add_html_card(sct_html, section = "SCT", title = "SCT Summary")
      log_msg("  SCT zero-state card added.")
    } else {
      # ------- SCT data exists — build populated SCT tab -------
      log_msg("  Building SCT dashboard section (", sct_event_n, " LOT-ending events)...")

      # Query SCT summary stats
      sct_stats <- tryCatch(db_q(con, "
        SELECT
          count(*) AS n_patients,
          sum(CASE WHEN LOT1_TX_AUTO_DT_1 IS NOT NULL THEN 1 ELSE 0 END) AS n_with_auto,
          sum(CASE WHEN FIRST_ALLO_DT IS NOT NULL THEN 1 ELSE 0 END) AS n_with_allo,
          sum(CASE WHEN FIRST_CART_DT IS NOT NULL THEN 1 ELSE 0 END) AS n_with_cart,
          sum(LOT1_SCT_AUTO_TAND_FLG) AS n_tandem,
          sum(LOT1_SCT_AUTO_SING_FLG) AS n_single_auto,
          sum(CASE WHEN LOT1_TX_ENDDATE IS NOT NULL THEN 1 ELSE 0 END) AS n_sct_end
        FROM lot1_sct
      "), error = function(e) data.frame())

      # Query raw claims by type
      sct_raw_by_type <- tryCatch(db_q(con, "
        SELECT SCT_TYPE, count(*) AS n_claims, count(DISTINCT PATID) AS n_patients
        FROM sct_claims_raw
        GROUP BY SCT_TYPE
        ORDER BY SCT_TYPE
      "), error = function(e) data.frame())

      # Query end reasons
      sct_end_reasons <- tryCatch(db_q(con, "
        SELECT
          CASE LOT1_TX_ENDDATE_REASON
            WHEN 1 THEN 'AUTO' WHEN 2 THEN 'ALLO' WHEN 3 THEN 'CART' ELSE 'OTHER'
          END AS SCT_END_TYPE,
          count(*) AS n
        FROM lot1_sct
        WHERE LOT1_TX_ENDDATE IS NOT NULL
        GROUP BY LOT1_TX_ENDDATE_REASON
        ORDER BY LOT1_TX_ENDDATE_REASON
      "), error = function(e) data.frame())

      # Build SCT summary HTML card
      sfmt <- function(x) if (is.null(x) || is.na(x)) "0" else format(as.numeric(x), big.mark = ",")
      spct <- function(x, total) if (is.null(x) || is.na(x) || is.null(total) || is.na(total) || total == 0) "0.0" else sprintf("%.1f", 100 * as.numeric(x) / as.numeric(total))

      n_pat <- if (nrow(sct_stats) > 0) as.numeric(sct_stats$n_patients) else 0

      # Build raw claims rows for the table
      raw_rows <- ""
      if (nrow(sct_raw_by_type) > 0) {
        for (i in seq_len(nrow(sct_raw_by_type))) {
          r <- sct_raw_by_type[i, ]
          raw_rows <- paste0(raw_rows, '<tr><td>', r$SCT_TYPE, '</td><td>',
                             format(as.numeric(r$n_claims), big.mark = ","), '</td><td>',
                             format(as.numeric(r$n_patients), big.mark = ","), '</td></tr>')
        }
      }

      # Build end reason rows
      end_rows <- ""
      if (nrow(sct_end_reasons) > 0) {
        for (i in seq_len(nrow(sct_end_reasons))) {
          r <- sct_end_reasons[i, ]
          end_rows <- paste0(end_rows, '<tr><td>', r$SCT_END_TYPE, '</td><td>',
                             format(as.numeric(r$n), big.mark = ","), '</td></tr>')
        }
      }

      sct_summary_html <- paste0('<!DOCTYPE html><html><head><meta charset="UTF-8">
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
         background: #fff; padding: 24px; color: #2d3436; }
  h2 { font-size: 20px; color: #1a5276; margin-bottom: 16px; }
  h3.section { font-size: 16px; color: #2d3436; margin: 24px 0 12px; border-bottom: 2px solid #dfe6e9; padding-bottom: 6px; }
  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(200px, 1fr)); gap: 14px; margin-bottom: 24px; }
  .card { background: #f5f6fa; border-radius: 8px; padding: 16px; border: 1px solid #dfe6e9; }
  .card h4 { font-size: 11px; color: #636e72; text-transform: uppercase;
             letter-spacing: 0.5px; margin-bottom: 6px; }
  .card .val { font-size: 24px; font-weight: 700; color: #2d3436; }
  .card .sub { font-size: 12px; color: #636e72; margin-top: 4px; }
  .card.highlight { background: #A23B72; border-color: #A23B72; }
  .card.highlight h4, .card.highlight .val, .card.highlight .sub { color: #fff; }
  table { border-collapse: collapse; width: 100%; margin-top: 8px; margin-bottom: 16px; }
  th, td { text-align: left; padding: 8px 12px; border-bottom: 1px solid #eee; font-size: 13px; }
  th { background: #f5f6fa; font-weight: 600; color: #636e72; text-transform: uppercase;
       letter-spacing: 0.5px; font-size: 11px; }
</style></head><body>
<h2>Stem Cell Transplant (SCT) Summary</h2>
<div class="grid">
  <div class="card highlight"><h4>LOT-Ending SCT</h4><div class="val">', sfmt(sct_event_n), '</div>
    <div class="sub">Patients with SCT ending LOT1</div></div>
  <div class="card"><h4>LOT1 Patients</h4><div class="val">', sfmt(n_pat), '</div></div>
  <div class="card"><h4>With AUTO SCT</h4><div class="val">',
        if (nrow(sct_stats) > 0) sfmt(sct_stats$n_with_auto) else "0", '</div>
    <div class="sub">', if (nrow(sct_stats) > 0) spct(sct_stats$n_with_auto, n_pat) else "0.0", '% of LOT1</div></div>
  <div class="card"><h4>Tandem AUTO</h4><div class="val">',
        if (nrow(sct_stats) > 0) sfmt(sct_stats$n_tandem) else "0", '</div></div>
  <div class="card"><h4>Single AUTO</h4><div class="val">',
        if (nrow(sct_stats) > 0) sfmt(sct_stats$n_single_auto) else "0", '</div></div>
  <div class="card"><h4>With ALLO SCT</h4><div class="val">',
        if (nrow(sct_stats) > 0) sfmt(sct_stats$n_with_allo) else "0", '</div>
    <div class="sub">', if (nrow(sct_stats) > 0) spct(sct_stats$n_with_allo, n_pat) else "0.0", '% of LOT1</div></div>
  <div class="card"><h4>With CAR-T</h4><div class="val">',
        if (nrow(sct_stats) > 0) sfmt(sct_stats$n_with_cart) else "0", '</div>
    <div class="sub">', if (nrow(sct_stats) > 0) spct(sct_stats$n_with_cart, n_pat) else "0.0", '% of LOT1</div></div>
  <div class="card"><h4>Raw SCT Claims</h4><div class="val">', sfmt(sct_raw_n), '</div></div>
  <div class="card"><h4>SCT Codes Loaded</h4><div class="val">',
        if (!is.na(sct_codes_n)) format(sct_codes_n, big.mark = ",") else "N/A", '</div></div>
</div>

<h3 class="section">SCT End Reason Breakdown</h3>
<p style="font-size:13px;color:#636e72;">Which SCT type ended LOT1 for each patient (priority: earliest event)</p>
<table>
<tr><th>SCT Type</th><th>Patients</th></tr>
', end_rows, '
</table>

<h3 class="section">Raw SCT Claims by Type</h3>
<p style="font-size:13px;color:#636e72;">All SCT procedure claims found in the cohort (before LOT-ending logic)</p>
<table>
<tr><th>SCT Type</th><th>Claims</th><th>Patients</th></tr>
', raw_rows, '
</table>
</body></html>')
      add_html_card(sct_summary_html, section = "SCT", title = "SCT Summary")

      # SCT end reason bar chart (if ggplot2 available and data exists)
      if (has_ggplot2 && nrow(sct_end_reasons) > 0) {
        sct_end_reasons$n <- as.numeric(sct_end_reasons$n)
        sct_end_reasons$pct <- 100 * sct_end_reasons$n / sum(sct_end_reasons$n)
        sct_type_colors <- c("AUTO" = "#A23B72", "ALLO" = "#8D5A97",
                             "CART" = "#3F88C5", "OTHER" = "#636e72")
        p_sct <- ggplot(sct_end_reasons,
                         aes(x = reorder(SCT_END_TYPE, -n), y = n,
                             fill = SCT_END_TYPE,
                             text = paste0("Type: ", SCT_END_TYPE,
                                           "\nPatients: ", format(n, big.mark = ","),
                                           "\n%: ", round(pct, 1), "%"))) +
          geom_bar(stat = "identity", width = 0.65) +
          geom_text(aes(label = paste0(format(n, big.mark = ","), "\n(", round(pct, 1), "%)")),
                    vjust = -0.3, size = 3.8, color = "grey20") +
          scale_fill_manual(values = sct_type_colors) +
          scale_y_continuous(labels = scales::comma_format(), expand = expansion(mult = c(0, 0.2))) +
          labs(title = "LOT1 SCT End Reasons by Type",
               subtitle = paste0(format(sum(sct_end_reasons$n), big.mark = ","),
                                 " patients with SCT ending LOT1"),
               x = NULL, y = "Number of Patients") +
          theme_lot() +
          theme(legend.position = "none")
        save_plot(p_sct, "fig_sct_end_reasons.png", width = 7, height = 5,
                 section = "SCT", title = "Fig: SCT End Reasons")
      }

      # SCT details table: patient-level SCT data
      sct_detail <- tryCatch(db_q(con, "
        SELECT
          CASE LOT1_TX_ENDDATE_REASON
            WHEN 1 THEN 'AUTO' WHEN 2 THEN 'ALLO' WHEN 3 THEN 'CART' ELSE 'NONE'
          END AS END_REASON,
          LOT1_SCT_AUTO_TAND_FLG AS TANDEM,
          LOT1_SCT_AUTO_SING_FLG AS SINGLE_AUTO,
          LOT1_TX_AUTO_DT_1 AS AUTO_DT_1,
          LOT1_TX_AUTO_DT_2 AS AUTO_DT_2,
          FIRST_ALLO_DT,
          FIRST_CART_DT,
          LOT1_TX_ENDDATE AS SCT_END_DT,
          LOT1_1ST_SCT_DT AS FIRST_SCT_DT
        FROM lot1_sct
        WHERE LOT1_TX_ENDDATE IS NOT NULL
           OR LOT1_TX_AUTO_DT_1 IS NOT NULL
           OR FIRST_ALLO_DT IS NOT NULL
           OR FIRST_CART_DT IS NOT NULL
        ORDER BY LOT1_TX_ENDDATE_REASON, LOT1_TX_ENDDATE
      "), error = function(e) data.frame())
      if (nrow(sct_detail) > 0) {
        save_table(sct_detail, section = "SCT",
                   title = "Table: SCT Patient Details")
      }

      log_msg("  SCT dashboard section built with ", sct_event_n, " LOT-ending events.")
    }
  }, error = function(e) {
    log_msg("WARN: SCT zero-state card failed: ", conditionMessage(e))
  })

  # --------------------------------------------------------
  # 10. Sankey / alluvial flow: Regimen -> Med Count -> End Reason
  # --------------------------------------------------------
  tryCatch({
    if (has_plotly) {
      flow_data <- db_q(con, "
        SELECT
          CASE
            WHEN lb.LOT1_BASE_MEDS IN ('BORT LENA', 'BORT', 'LENA', 'BORT DARA LENA',
                                     'BORT CYCL', 'DARA LENA', 'BORT DARA',
                                     'CARF LENA', 'BORT CYCL DARA LENA', 'DARA')
            THEN lb.LOT1_BASE_MEDS
            ELSE 'OTHER'
          END AS regimen,
          CAST(lb.LOT1_MED_CNT AS STRING) AS med_count,
          lbe.LOT1_BASE_END_REASON AS end_reason,
          count(*) AS n
        FROM lot1_base lb
        INNER JOIN lot1_base_end lbe ON lb.PATID = lbe.PATID
        GROUP BY 1, 2, 3
        ORDER BY n DESC
      ")

      if (nrow(flow_data) > 0) {
        flow_data$n <- as.numeric(flow_data$n)

        # Build Sankey node/link structure
        regimens_u <- sort(unique(flow_data$regimen))
        medcnts_u  <- sort(unique(flow_data$med_count))
        reasons_u  <- sort(unique(flow_data$end_reason))

        # Node labels: regimen nodes, then med_count nodes, then end_reason nodes
        node_labels <- c(regimens_u,
                        paste0(medcnts_u, " med(s)"),
                        reasons_u)

        n_reg <- length(regimens_u)
        n_mc  <- length(medcnts_u)

        reg_idx <- setNames(seq_along(regimens_u) - 1, regimens_u)
        mc_idx  <- setNames(seq_along(medcnts_u) - 1 + n_reg, medcnts_u)
        er_idx  <- setNames(seq_along(reasons_u) - 1 + n_reg + n_mc, reasons_u)

        # Links: regimen -> med_count
        link1 <- aggregate(n ~ regimen + med_count, data = flow_data, FUN = sum)
        # Links: med_count -> end_reason
        link2 <- aggregate(n ~ med_count + end_reason, data = flow_data, FUN = sum)

        sources <- c(reg_idx[link1$regimen], mc_idx[link2$med_count])
        targets <- c(mc_idx[link1$med_count], er_idx[link2$end_reason])
        values  <- c(link1$n, link2$n)

        # Color nodes by type
        reg_colors <- rep("#2E86AB", n_reg)
        mc_colors  <- rep("#44BBA4", n_mc)
        er_colors  <- sapply(reasons_u, function(r) {
          switch(r, DISCONTINUATION = "#C73E1D", MED_ADD = "#F18F01",
                 DEATH = "#2E86AB", DISENROLLMENT = "#5DA9C8",
                 STUDY_END = "#8DC4DB", SCT_AUTO = "#A23B72",
                 SCT_ALLO = "#8D5A97", SCT_CART = "#3F88C5",
                 SCT_NO_MAINT = "#B47EB3", MAINTENANCE_END = "#44AF69", "#636e72")
        })
        node_colors <- c(reg_colors, mc_colors, er_colors)

        # Link colors — semi-transparent version of source node
        hex_to_rgba <- function(hex, alpha = 0.3) {
          r <- strtoi(substr(hex, 2, 3), 16)
          g <- strtoi(substr(hex, 4, 5), 16)
          b <- strtoi(substr(hex, 6, 7), 16)
          sprintf("rgba(%d,%d,%d,%.1f)", r, g, b, alpha)
        }
        link_colors <- sapply(sources + 1, function(i) hex_to_rgba(node_colors[i]))

        ps <- plotly::plot_ly(
          type = "sankey",
          orientation = "h",
          node = list(
            pad = 15, thickness = 20,
            line = list(color = "black", width = 0.5),
            label = node_labels,
            color = node_colors
          ),
          link = list(
            source = as.integer(sources),
            target = as.integer(targets),
            value = as.numeric(values),
            color = link_colors
          )
        ) |>
          plotly::layout(
            title = list(text = "Patient Flow: Regimen → Med Count → End Reason",
                         font = list(size = 16)),
            font = list(size = 11),
            margin = list(l = 20, r = 20, t = 50, b = 30)
          ) |>
          plotly::config(displayModeBar = TRUE, displaylogo = FALSE)

        add_to_dashboard(ps, section = "LOT1", title = "Fig 9: Patient Flow (Sankey)")
        log_msg("  Sankey flow chart added.")
      }
    }
  }, error = function(e) {
    log_msg("WARN: Sankey flow chart failed: ", conditionMessage(e))
  })

  # CYCLO deep-dive (gated by config)
  if (isTRUE(cfg$run_cyclo_deepdive)) {
    run_cyclo_deepdive(con)
  }

  # Build combined interactive dashboard (gated by config)
  if (isTRUE(cfg$build_dashboard)) {
    build_dashboard()
  }
}
