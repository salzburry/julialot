# Stakeholder validation helpers on top of LOT_LONG / LOT_LONG_AUG and
# the NDMM flag view. Read-only - no derivation lives here.

# ---- Sankey title with N denominator -------------------------------
# `unit` lets the caller say what N counts: pairwise LOT Sankeys use
# "patient" (distinct PATIDs); 04's multi-LOT flow Sankeys use
# "transition" because the same patient can sit on many edges.
sankey_title_with_n <- function(title, n_patients, unit = "patient") {
  if (is.null(n_patients) || !is.finite(n_patients) || n_patients <= 0)
    return(title)
  paste0(title,
         "<br><span style='font-size:11px;color:#6B7280'>N = ",
         format(round(n_patients), big.mark = ","), " ", unit,
         if (n_patients == 1) "" else "s",
         " on this view</span>")
}

# Adds pct_of_sankey so reviewers can check the visual proportions.
augment_transition_table <- function(df, n_col = "n_patients") {
  if (is.null(df) || nrow(df) == 0) return(df)
  tot <- sum(df[[n_col]], na.rm = TRUE)
  df$pct_of_sankey <- if (tot > 0)
    round(100 * df[[n_col]] / tot, 1) else NA_real_
  df
}

# ---- Patient journey gallery ---------------------------------------
# For each category we pick 3 patients (deepest LOT, then ascending
# PATID, so reruns return the same set) and render one combined Plotly
# timeline + a DT detail table.

.mask_pid <- function(p) {
  p <- as.character(p)
  s <- nchar(p) - 5L; s[s < 1L] <- 1L
  paste0("...", tolower(substring(p, s)))
}

GALLERY_CATEGORIES <- list(
  list(label = "Typical LOT1 -> LOT2 progressor (MED-started)",
       pred  = "max_lot >= 2 AND lot1_start_type = 'MED'"),
  list(label = "LOT1-only non-progressor (DISCONTINUATION)",
       pred  = "max_lot = 1 AND lot1_end_reason = 'DISCONTINUATION'"),
  list(label = "CART_INIT case",
       pred  = "any_cart_init = 1"),
  list(label = "SCT_AUTO case",
       pred  = "any_sct_auto = 1"),
  list(label = "SCT_ALLO single-day case",
       pred  = "any_sct_allo = 1"),
  list(label = "Death on LOT1",
       pred  = "lot1_end_reason = 'DEATH'"),
  list(label = "Study-end on LOT1",
       pred  = "lot1_end_reason = 'STUDY_END'")
)

.gallery_pick <- function(con, lot_long_tbl, predicate, n_each) {
  sql <- glue("
    WITH pat AS (
      SELECT cast(PATID as string) AS PATID,
             max(LOT_NUM)                                            AS max_lot,
             max(CASE WHEN LOT_NUM = 1 THEN LOT_START_TYPE END)      AS lot1_start_type,
             max(CASE WHEN LOT_NUM = 1 THEN LOT_BASE_END_REASON END) AS lot1_end_reason,
             max(CASE WHEN LOT_BASE_END_REASON = 'CART_INIT' THEN 1 ELSE 0 END) AS any_cart_init,
             max(CASE WHEN LOT_START_TYPE = 'SCT_AUTO' THEN 1 ELSE 0 END) AS any_sct_auto,
             max(CASE WHEN LOT_START_TYPE = 'SCT_ALLO' THEN 1 ELSE 0 END) AS any_sct_allo
      FROM {lot_long_tbl}
      GROUP BY PATID
    )
    SELECT PATID FROM pat
    WHERE {predicate}
    ORDER BY max_lot DESC, PATID ASC
    LIMIT {as.integer(n_each)}")
  rows <- tryCatch(db_q(con, sql), error = function(e) NULL)
  if (is.null(rows) || nrow(rows) == 0) return(character(0))
  as.character(rows$PATID)
}

.gallery_fetch_lots <- function(con, lot_long_tbl, patids) {
  if (length(patids) == 0) return(NULL)
  ids <- paste0("'", gsub("'", "''", patids), "'", collapse = ",")
  df <- tryCatch(db_q(con, glue("
    SELECT cast(PATID as string) AS PATID, LOT_NUM,
           LOT_START_TYPE, LOT_START_DT, LOT_BASE_END_DT,
           LOT_BASE_END_REASON, LOT_BASE_LENGTH, LOT_BASE_MEDS
    FROM {lot_long_tbl}
    WHERE cast(PATID as string) IN ({ids})
    ORDER BY PATID, LOT_NUM
  ")), error = function(e) NULL)
  if (is.null(df) || nrow(df) == 0) return(NULL)
  df$LOT_START_DT    <- as.Date(df$LOT_START_DT)
  df$LOT_BASE_END_DT <- as.Date(df$LOT_BASE_END_DT)
  df
}

# Plotly date axes interpret numeric values as milliseconds since
# 1970-01-01, not R's day-since-epoch. ISO anchor + ms width fixes it.
.gallery_timeline_plot <- function(df, label) {
  if (is.null(df) || nrow(df) == 0 || !has_plotly) return(NULL)
  df$row_label <- paste0(.mask_pid(df$PATID), "  L", df$LOT_NUM)
  df$row_label <- factor(df$row_label, levels = rev(unique(df$row_label)))
  df$bar_color <- ifelse(df$LOT_START_TYPE %in% names(lot_start_palette),
                         lot_start_palette[df$LOT_START_TYPE], "#9AA0A6")
  df$tooltip <- paste0(
    "PATID ",   .mask_pid(df$PATID),
    "\nLOT ",   df$LOT_NUM, " (", df$LOT_START_TYPE, ")",
    "\n",       format(df$LOT_START_DT), " - ", format(df$LOT_BASE_END_DT),
    "\n",       df$LOT_BASE_LENGTH, " days",
    "\nEnd: ",  df$LOT_BASE_END_REASON,
    "\nMeds: ", df$LOT_BASE_MEDS)
  df$base_iso <- format(df$LOT_START_DT, "%Y-%m-%d")
  df$width_ms <- (as.numeric(df$LOT_BASE_END_DT - df$LOT_START_DT) + 1) * 86400000
  tryCatch(
    plotly::plot_ly(df, type = "bar", orientation = "h",
                    y = ~row_label, base = ~base_iso, x = ~width_ms,
                    marker = list(color = df$bar_color,
                                  line = list(color = "white", width = 1)),
                    text = ~tooltip, hoverinfo = "text") |>
      plotly::layout(
        title  = list(text = paste0("Patient journeys - ", label),
                      font = list(size = 14), x = 0.02),
        xaxis  = list(type = "date", title = "Date", gridcolor = "#EAECEE"),
        yaxis  = list(title = "", automargin = TRUE),
        margin = list(l = 10, r = 10, t = 60, b = 40),
        showlegend = FALSE,
        paper_bgcolor = "white", plot_bgcolor = "white") |>
      plotly::config(displayModeBar = TRUE, displaylogo = FALSE),
    error = function(e) {
      log_msg("  INFO: gallery timeline '", label, "' skipped (",
              conditionMessage(e), ")")
      NULL
    })
}

build_patient_gallery <- function(con, lot_long_tbl,
                                  section = "Patient examples",
                                  title_prefix = "Examples: ") {
  empty <- character(0)
  for (cat in GALLERY_CATEGORIES) {
    patids <- .gallery_pick(con, lot_long_tbl, cat$pred, 3L)
    df <- if (length(patids)) .gallery_fetch_lots(con, lot_long_tbl, patids) else NULL
    if (is.null(df)) { empty <- c(empty, cat$label); next }
    sk <- .gallery_timeline_plot(df, cat$label)
    if (!is.null(sk))
      add_to_dashboard(sk, section = section,
                       title = paste0(title_prefix, cat$label, " - timeline"))
    df$PATID <- .mask_pid(df$PATID)
    save_table(df, section = section,
               title = paste0(title_prefix, cat$label, " - LOT detail"))
  }
  # Note the scenarios we checked but found no patients for, so a missing
  # category reads as "none in this cohort" rather than "forgot to check".
  if (length(empty))
    add_html_card(paste0(
      '<div style="font-family:system-ui;padding:14px;max-width:900px">',
      '<h3>Categories with no examples in this cohort</h3>',
      '<p style="color:#555;font-size:13px">Checked, matched no patients: ',
      paste(empty, collapse = "; "), '.</p></div>'),
      section = section,
      title = paste0(title_prefix, "Categories with no matches"))
}

# ---- LOT cascade counters ------------------------------------------
# Per-cohort counts of the cases the LOT cascade is supposed to
# produce. If everything is 0, either the cohort is tiny or a rule
# isn't firing - either way it's worth a look.
build_lot_qc_counters <- function(con, lot_long_tbl,
                                  section = "Validation",
                                  title_prefix = "Validation: ") {
  df <- tryCatch(db_q(con, glue("
    WITH per_pat AS (
      SELECT cast(PATID as string) AS PATID,
             sum(CASE WHEN LOT_START_TYPE = 'SCT_AUTO' THEN 1 ELSE 0 END) AS n_auto,
             sum(CASE WHEN LOT_START_TYPE = 'SCT_ALLO' THEN 1 ELSE 0 END) AS n_allo,
             sum(CASE WHEN LOT_START_TYPE IN ('CART','SCT_CART','CART_INIT')
                      THEN 1 ELSE 0 END)                                  AS n_cart,
             sum(CASE WHEN LOT_BASE_END_REASON = 'CART_INIT'       THEN 1 ELSE 0 END) AS n_cart_init,
             sum(CASE WHEN LOT_BASE_END_REASON = 'MED_ADD'         THEN 1 ELSE 0 END) AS n_med_add,
             sum(CASE WHEN LOT_BASE_END_REASON = 'DEATH'           THEN 1 ELSE 0 END) AS n_death,
             sum(CASE WHEN LOT_BASE_END_REASON = 'DISCONTINUATION' THEN 1 ELSE 0 END) AS n_discon,
             sum(CASE WHEN LOT_BASE_END_REASON = 'STUDY_END'       THEN 1 ELSE 0 END) AS n_studyend
      FROM {lot_long_tbl}
      GROUP BY PATID
    )
    SELECT
      (SELECT count(*) FROM per_pat)                       AS total_patients,
      (SELECT count(*) FROM per_pat WHERE n_cart      >= 1) AS pts_any_cart,
      (SELECT count(*) FROM per_pat WHERE n_auto      >= 1) AS pts_any_auto,
      (SELECT count(*) FROM per_pat WHERE n_auto      >= 2) AS pts_auto_tandem_or_excess,
      (SELECT count(*) FROM per_pat WHERE n_allo      >= 1) AS pts_any_allo,
      (SELECT count(*) FROM per_pat WHERE n_cart_init >= 1) AS pts_any_cart_init,
      (SELECT count(*) FROM per_pat WHERE n_med_add   >= 1) AS pts_any_med_add,
      (SELECT count(*) FROM per_pat WHERE n_death     >= 1) AS pts_any_death,
      (SELECT count(*) FROM per_pat WHERE n_discon    >= 1) AS pts_any_discon,
      (SELECT count(*) FROM per_pat WHERE n_studyend  >= 1) AS pts_any_study_end
  ")), error = function(e) NULL)
  if (is.null(df) || nrow(df) == 0) return(invisible())
  total <- as.numeric(df$total_patients)
  metric_names <- c("Total patients", "Any CAR-T LOT",
                    "Any SCT_AUTO LOT", "SCT_AUTO 2+ times (tandem or excess)",
                    "Any SCT_ALLO LOT", "Any CART_INIT end reason",
                    "Any MED_ADD end reason", "Any DEATH end reason",
                    "Any DISCONTINUATION end reason", "Any STUDY_END end reason")
  vals <- as.numeric(unlist(df[1, ], use.names = FALSE))
  out <- data.frame(metric = metric_names, n_patients = vals,
                    stringsAsFactors = FALSE)
  out$pct_of_cohort <- if (total > 0)
    round(100 * out$n_patients / total, 1) else NA_real_
  save_table(out, section = section,
             title = paste0(title_prefix, "LOT cascade counters"))
}

# ---- LOT1 start-year trend -----------------------------------------
build_lot1_start_year_trend <- function(con, lot_long_tbl,
                                        section = "Validation",
                                        title_prefix = "Validation: ") {
  df <- tryCatch(db_q(con, glue("
    SELECT year(LOT_START_DT)                                AS start_year,
           count(DISTINCT PATID)                             AS n_patients,
           sum(CASE WHEN LOT_START_TYPE = 'MED'      THEN 1 ELSE 0 END) AS n_med,
           sum(CASE WHEN LOT_START_TYPE = 'SCT_AUTO' THEN 1 ELSE 0 END) AS n_sct_auto,
           sum(CASE WHEN LOT_START_TYPE = 'SCT_ALLO' THEN 1 ELSE 0 END) AS n_sct_allo,
           sum(CASE WHEN LOT_START_TYPE IN ('CART','SCT_CART','CART_INIT')
                    THEN 1 ELSE 0 END)                                  AS n_cart
    FROM {lot_long_tbl}
    WHERE LOT_NUM = 1 AND LOT_START_DT IS NOT NULL
    GROUP BY year(LOT_START_DT)
    ORDER BY start_year
  ")), error = function(e) NULL)
  if (is.null(df) || nrow(df) == 0) return(invisible())
  for (col in setdiff(names(df), "start_year"))
    df[[col]] <- as.numeric(df[[col]])
  save_table(df, section = section,
             title = paste0(title_prefix, "LOT1 starts by year (by start type)"))
  if (!has_ggplot2) return(invisible())
  p <- ggplot(df, aes(x = factor(start_year), y = n_patients,
                      text = paste0("Year: ", start_year,
                                    "\nLOT1 patients: ",
                                    format(n_patients, big.mark = ",")))) +
    geom_col(fill = "#2E86AB", width = 0.7) +
    geom_text(aes(label = format(n_patients, big.mark = ",")),
              vjust = -0.3, size = 3.3, color = "grey20") +
    labs(title = "LOT1 starts by calendar year",
         x = NULL, y = "Distinct LOT1 patients") +
    scale_y_continuous(labels = scales::comma_format(),
                       expand = expansion(mult = c(0, 0.15))) +
    theme_lot()
  save_plot(p, "lot1_start_year_trend.png", width = 10, height = 5,
            section = section,
            title = paste0(title_prefix, "LOT1 starts by year"))
}

# ---- Data-quality / outlier checks ---------------------------------
# Non-zero rows don't always mean a bug, but anything flipping from OK
# to investigate between runs is worth looking at. SCT_ALLO is dropped
# from the blank-meds count because those LOTs have no meds.
build_outlier_checks <- function(con, lot_long_tbl,
                                 section = "Validation",
                                 title_prefix = "Validation: ") {
  df <- tryCatch(db_q(con, glue("
    WITH lot AS (SELECT * FROM {lot_long_tbl}),
    per_pat AS (
      SELECT cast(PATID as string) AS PATID,
             min(LOT_NUM)            AS min_lot,
             max(LOT_NUM)            AS max_lot,
             count(DISTINCT LOT_NUM) AS n_distinct_lot
      FROM lot GROUP BY PATID
    ),
    overlaps AS (
      SELECT DISTINCT a.PATID
      FROM lot a JOIN lot b
        ON a.PATID = b.PATID AND a.LOT_NUM < b.LOT_NUM
       AND a.LOT_BASE_END_DT IS NOT NULL AND b.LOT_START_DT IS NOT NULL
       AND a.LOT_BASE_END_DT >= b.LOT_START_DT
    )
    SELECT
      (SELECT count(*) FROM lot
       WHERE LOT_BASE_LENGTH IS NULL OR LOT_BASE_LENGTH <= 0)             AS n_zero_or_neg_length,
      (SELECT count(*) FROM lot
       WHERE LOT_BASE_END_DT IS NOT NULL AND LOT_START_DT IS NOT NULL
         AND LOT_BASE_END_DT < LOT_START_DT)                              AS n_end_before_start,
      (SELECT count(*) FROM lot
       WHERE (LOT_BASE_MEDS IS NULL OR trim(LOT_BASE_MEDS) = '')
         AND coalesce(LOT_START_TYPE, '') <> 'SCT_ALLO')                  AS n_missing_meds,
      (SELECT count(*) FROM lot WHERE LOT_BASE_END_REASON IS NULL)        AS n_missing_end_reason,
      (SELECT count(*) FROM per_pat WHERE min_lot > 1)                    AS pts_lot2plus_no_lot1,
      (SELECT count(*) FROM per_pat WHERE max_lot <> n_distinct_lot)      AS pts_lot_num_gap,
      (SELECT count(*) FROM (SELECT PATID, LOT_NUM, count(*) AS c FROM lot
                             GROUP BY PATID, LOT_NUM HAVING count(*) > 1)) AS pts_dup_rows,
      (SELECT count(*) FROM overlaps)                                     AS pts_overlapping,
      (SELECT count(*) FROM lot WHERE LOT_BASE_LENGTH > 3650)             AS n_over_10_years
  ")), error = function(e) NULL)
  if (is.null(df) || nrow(df) == 0) return(invisible())
  out <- data.frame(
    check = c("LOT_BASE_LENGTH zero or negative",
              "LOT_BASE_END_DT < LOT_START_DT",
              "LOT_BASE_MEDS missing or blank (excludes SCT_ALLO)",
              "LOT_BASE_END_REASON missing",
              "Patient has LOT2+ but no LOT1",
              "Patient has a LOT_NUM gap (e.g. 1, 3, no 2)",
              "Duplicate (PATID, LOT_NUM) rows",
              "Patient has overlapping LOT intervals",
              "LOT length over 10 years (impossible)"),
    n_cases = as.numeric(unlist(df[1, ], use.names = FALSE)),
    stringsAsFactors = FALSE)
  out$status <- ifelse(out$n_cases == 0, "OK",
                       ifelse(out$n_cases < 5, "review", "investigate"))
  save_table(out, section = section,
             title = paste0(title_prefix, "Data-quality / outlier checks"))
}

# ---- NDMM evidence drilldown ---------------------------------------
# 3 deterministic NDMM-included + 3 excluded patients with their flag
# pass/fail values. The flag view (NDMM_FLAGS_ALL) is built by 06.
.ndmm_pick <- function(con, flags_tbl, include, n_each) {
  all_pass <- "CE_pre_lot1_12mo = 1 AND CE_lot1_3mo_fu = 1 AND NO_BELANTAMAB = 1 AND NO_PRIOR_MM_TX = 1 AND NO_OTHER_CANCER_PRE_LOT1 = 1 AND NO_PREGNANCY = 1"
  pred <- if (isTRUE(include)) all_pass else paste0("NOT (", all_pass, ")")
  rows <- tryCatch(db_q(con, glue("
    SELECT PATID FROM {flags_tbl}
    WHERE {pred}
    ORDER BY PATID ASC
    LIMIT {as.integer(n_each)}")), error = function(e) NULL)
  if (is.null(rows) || nrow(rows) == 0) return(character(0))
  as.character(rows$PATID)
}

.ndmm_flags_for <- function(con, flags_tbl, patids) {
  if (length(patids) == 0) return(NULL)
  ids <- paste0("'", gsub("'", "''", patids), "'", collapse = ",")
  df <- tryCatch(db_q(con, glue("
    SELECT cast(PATID as string) AS PATID,
           CE_pre_lot1_12mo, CE_lot1_3mo_fu, NO_BELANTAMAB,
           NO_PRIOR_MM_TX, NO_OTHER_CANCER_PRE_LOT1, NO_PREGNANCY
    FROM {flags_tbl}
    WHERE cast(PATID as string) IN ({ids})
    ORDER BY PATID
  ")), error = function(e) NULL)
  if (is.null(df) || nrow(df) == 0) return(NULL)
  for (col in c("CE_pre_lot1_12mo","CE_lot1_3mo_fu","NO_BELANTAMAB",
                "NO_PRIOR_MM_TX","NO_OTHER_CANCER_PRE_LOT1","NO_PREGNANCY"))
    df[[col]] <- ifelse(as.numeric(df[[col]]) == 1, "PASS", "FAIL")
  df$PATID <- .mask_pid(df$PATID)
  df
}

build_ndmm_evidence_drilldown <- function(con, flags_tbl, lot_long_tbl,
                                          section = "Validation",
                                          title_prefix = "Validation: ",
                                          n_each = 3L) {
  inc_pids <- .ndmm_pick(con, flags_tbl, TRUE,  n_each)
  exc_pids <- .ndmm_pick(con, flags_tbl, FALSE, n_each)
  if (length(inc_pids) == 0 && length(exc_pids) == 0) return(invisible())

  add_html_card(paste0(
    '<div style="font-family:system-ui;padding:14px;max-width:900px">',
    '<h3>NDMM IE evidence drilldown</h3>',
    '<p style="color:#555;font-size:13px">Flag-by-flag pass/fail for a ',
    'few deterministic patients. <code>CE_pre_lot1_12mo</code>: enrolled ',
    'for the 12 months before LOT1. <code>NO_BELANTAMAB</code>: no ',
    'belantamab in any LOT. <code>NO_PRIOR_MM_TX</code>: no MM oncology ',
    'therapy in the pre-LOT1 baseline. <code>NO_OTHER_CANCER_PRE_LOT1</code>: ',
    'no other active cancer (1 IP or 2 OP within 30d), with the MM-adjacent ',
    'override applied. <code>CE_lot1_3mo_fu</code>: strict no-gap enrollment ',
    'for 3 months of follow-up from LOT1 (death-aware). ',
    '<code>NO_PREGNANCY</code>: no pregnancy claim (re-scanned from ',
    'pregnancy.csv over the study period).</p></div>'),
    section = section,
    title = paste0(title_prefix, "NDMM evidence - about"))

  inc_df <- .ndmm_flags_for(con, flags_tbl, inc_pids)
  exc_df <- .ndmm_flags_for(con, flags_tbl, exc_pids)
  if (!is.null(inc_df))
    save_table(inc_df, section = section,
               title = paste0(title_prefix, "NDMM included - flag pass/fail"))
  if (!is.null(exc_df))
    save_table(exc_df, section = section,
               title = paste0(title_prefix, "NDMM excluded - flag pass/fail"))

  # LOT detail only for INCLUDED - excluded patients aren't in the
  # filtered NDMM_LOT_LONG_FILT view by construction.
  if (length(inc_pids) > 0) {
    lot_df <- .gallery_fetch_lots(con, lot_long_tbl, inc_pids)
    if (!is.null(lot_df)) {
      lot_df$PATID <- .mask_pid(lot_df$PATID)
      save_table(lot_df, section = section,
                 title = paste0(title_prefix, "NDMM included - LOT detail"))
    }
  }
}

build_validation_views <- function(con, lot_long_tbl,
                                   section = "Validation",
                                   title_prefix = "Validation: ",
                                   ndmm_flags_tbl = NULL) {
  build_lot_qc_counters(con, lot_long_tbl, section, title_prefix)
  build_lot1_start_year_trend(con, lot_long_tbl, section, title_prefix)
  build_outlier_checks(con, lot_long_tbl, section, title_prefix)
  if (!is.null(ndmm_flags_tbl) && nzchar(ndmm_flags_tbl))
    build_ndmm_evidence_drilldown(con, ndmm_flags_tbl, lot_long_tbl,
                                  section, title_prefix)
}

# ---- Run-to-run comparison -----------------------------------------
# Small dashboard-owned summary table so reviewers can spot count
# changes between runs. CREATE OR REPLACE on every write (same idiom as
# attrition_report), capped at the last 20 runs per cohort.
RUN_SUMMARY_TBL <- "lot_dashboard_run_summary"
RUN_SUMMARY_CAP <- 20L

.run_summary_full_name <- function() {
  if (!nzchar(cfg$work_schema)) return(NULL)
  if (nzchar(cfg$catalog))
    paste0(cfg$catalog, ".", cfg$work_schema, ".", RUN_SUMMARY_TBL)
  else
    paste0(cfg$work_schema, ".", RUN_SUMMARY_TBL)
}

.compute_run_metrics <- function(con, lot_long_tbl) {
  row <- tryCatch(db_q(con, glue("
    WITH per_pat AS (
      SELECT PATID,
             max(LOT_NUM)                                                AS max_lot,
             max(CASE WHEN LOT_NUM = 1 THEN LOT_START_DT END)            AS lot1_dt,
             max(CASE WHEN LOT_NUM = 1 AND LOT_START_TYPE = 'MED'
                      THEN 1 ELSE 0 END)                                 AS lot1_med,
             max(CASE WHEN LOT_START_TYPE IN ('CART','SCT_CART','CART_INIT')
                      THEN 1 ELSE 0 END)                                 AS cart_any,
             max(CASE WHEN LOT_START_TYPE = 'SCT_ALLO' THEN 1 ELSE 0 END) AS allo_any,
             max(CASE WHEN LOT_START_TYPE = 'SCT_AUTO' THEN 1 ELSE 0 END) AS auto_any,
             max(CASE WHEN LOT_BASE_END_REASON = 'CART_INIT' THEN 1 ELSE 0 END) AS cart_init_any,
             max(CASE WHEN LOT_BASE_END_REASON = 'DEATH'     THEN 1 ELSE 0 END) AS death_any
      FROM {lot_long_tbl}
      GROUP BY PATID
    )
    SELECT
      cast((SELECT count(*) FROM per_pat)                          as double) AS n_patients,
      cast((SELECT count(*) FROM per_pat WHERE max_lot >= 1)       as double) AS n_lot1,
      cast((SELECT count(*) FROM per_pat WHERE max_lot >= 2)       as double) AS n_lot2,
      cast((SELECT count(*) FROM per_pat WHERE max_lot >= 3)       as double) AS n_lot3,
      cast((SELECT count(*) FROM per_pat WHERE cart_any = 1)       as double) AS n_cart_any,
      cast((SELECT count(*) FROM per_pat WHERE allo_any = 1)       as double) AS n_allo_any,
      cast((SELECT count(*) FROM per_pat WHERE auto_any = 1)       as double) AS n_auto_any,
      cast((SELECT count(*) FROM per_pat WHERE cart_init_any = 1)  as double) AS n_cart_init,
      cast((SELECT count(*) FROM per_pat WHERE death_any = 1)      as double) AS n_death_end,
      cast((SELECT count(*) FROM per_pat WHERE lot1_med = 1)       as double) AS n_lot1_med_started,
      cast((SELECT year(min(lot1_dt)) FROM per_pat)                as double) AS lot1_min_year,
      cast((SELECT year(max(lot1_dt)) FROM per_pat)                as double) AS lot1_max_year
  ")), error = function(e) NULL)
  if (is.null(row) || nrow(row) == 0) return(list())
  for (col in names(row)) if (inherits(row[[col]], "integer64"))
    row[[col]] <- as.numeric(row[[col]])
  as.list(row[1, , drop = FALSE])
}

.read_run_summary <- function(con, tbl_name) {
  tryCatch(db_q(con, glue("
    SELECT run_ts, cohort_label, metric, cast(value as double) AS value
    FROM {tbl_name}
  ")), error = function(e) NULL)
}

.write_run_summary <- function(con, tbl_name, df) {
  if (is.null(df) || nrow(df) == 0) return(invisible())
  sq <- function(x) paste0("'", gsub("'", "''", as.character(x)), "'")
  rows <- vapply(seq_len(nrow(df)), function(i) {
    val_sql <- if (is.na(df$value[i])) "cast(NULL as double)"
               else format(df$value[i], scientific = FALSE)
    paste0("(", sq(df$run_ts[i]), ", ", sq(df$cohort_label[i]), ", ",
           sq(df$metric[i]), ", ", val_sql, ")")
  }, character(1))
  tryCatch(db_exec(con, glue("
    CREATE OR REPLACE TABLE {tbl_name} AS
    SELECT * FROM VALUES
      {paste(rows, collapse = ',\n      ')}
    AS t(run_ts, cohort_label, metric, value)
  ")), error = function(e)
    log_msg("  WARN: could not persist run summary to ", tbl_name,
            ": ", conditionMessage(e)))
}

build_run_comparison <- function(con, cohort_label, lot_long_tbl,
                                 section = "Validation",
                                 title_prefix = "Validation: ",
                                 run_ts = format(Sys.time(), "%Y-%m-%d %H:%M:%S")) {
  tbl_name <- .run_summary_full_name()
  if (is.null(tbl_name)) {
    log_msg("  WARN: cfg$work_schema not set; skipping run comparison.")
    return(invisible())
  }
  metrics <- .compute_run_metrics(con, lot_long_tbl)
  if (length(metrics) == 0) return(invisible())
  new_rows <- data.frame(
    run_ts       = run_ts,
    cohort_label = cohort_label,
    metric       = names(metrics),
    value        = as.numeric(unlist(metrics)),
    stringsAsFactors = FALSE)

  prior <- .read_run_summary(con, tbl_name)
  combined <- if (is.null(prior) || nrow(prior) == 0) new_rows
              else unique(rbind(prior, new_rows))
  ts_keep <- tail(sort(unique(combined$run_ts[combined$cohort_label == cohort_label])),
                  RUN_SUMMARY_CAP)
  combined <- combined[combined$cohort_label != cohort_label |
                         combined$run_ts %in% ts_keep, ]
  .write_run_summary(con, tbl_name, combined)

  this_cohort <- combined[combined$cohort_label == cohort_label, ]
  if (nrow(this_cohort) == 0) return(invisible())
  recent_ts <- tail(sort(unique(this_cohort$run_ts)), 4L)
  cmp <- data.frame(metric = unique(this_cohort$metric),
                    stringsAsFactors = FALSE)
  for (ts in recent_ts) {
    sub <- this_cohort[this_cohort$run_ts == ts, c("metric","value")]
    cmp[[ts]] <- sub$value[match(cmp$metric, sub$metric)]
  }
  if (length(recent_ts) >= 2) {
    cur  <- cmp[[recent_ts[length(recent_ts)]]]
    prev <- cmp[[recent_ts[length(recent_ts) - 1L]]]
    cmp$delta_vs_prev     <- cur - prev
    cmp$pct_delta_vs_prev <- ifelse(is.finite(prev) & prev != 0,
                                    round(100 * (cur - prev) / prev, 1),
                                    NA_real_)
  }
  save_table(cmp, section = section,
             title = paste0(title_prefix, "Run-over-run comparison (last ",
                            length(recent_ts), " runs)"))
}
