# Stakeholder validation helpers: patient journey gallery, top-transition
# tables, Sankey title enrichment, and (in Phase C) cohort-funnel / LOT
# QC / mapped-unmapped / NDMM evidence / codelist / outlier views.
#
# Read-only against LOT_LONG / LOT_LONG_AUG / ELIG_COH_FINAL / raw claims.
# No new derivation - only aggregates and example pickers over already-
# derived data. Examples are picked deterministically (ORDER BY PATID) so
# reruns return the same set, which is what makes the gallery usable as
# a validation tool.

# ---- HTML escaping (mirrors 05_regimen_dashboard.R) ----------------
.esc_html <- function(s) {
  s <- gsub("&","&amp;",as.character(s),fixed=TRUE)
  s <- gsub("<","&lt;", s,fixed=TRUE)
  gsub(">","&gt;", s,fixed=TRUE)
}

# ---- Sankey title with N denominator -------------------------------
# Plotly title supports inline HTML, so we fold the N into a second
# subtitle line that reads at a glance. Used by 04 + 05's local Sankey
# builders via an optional n_patients arg.
sankey_title_with_n <- function(title, n_patients) {
  if (is.null(n_patients) || !is.finite(n_patients) || n_patients <= 0)
    return(title)
  paste0(title,
         "<br><span style='font-size:11px;color:#6B7280'>N = ",
         format(round(n_patients), big.mark = ","),
         " patient", if (n_patients == 1) "" else "s",
         " on this view</span>")
}

# ---- Top transition table helpers ----------------------------------
# Adds a pct_of_sankey column so reviewers can verify the visual
# proportions against numbers. Takes the same edge frame the Sankey was
# drawn from and returns a sorted, percent-augmented data.frame.
augment_transition_table <- function(df, n_col = "n_patients") {
  if (is.null(df) || nrow(df) == 0) return(df)
  tot <- sum(df[[n_col]], na.rm = TRUE)
  df$pct_of_sankey <- if (tot > 0)
    round(100 * df[[n_col]] / tot, 1) else NA_real_
  df
}

# ---- Patient journey gallery ---------------------------------------
# Categories: each is a predicate over LOT_LONG that defines a distinct
# validation scenario. For each, we pick N_EX deterministic example
# patients (smallest PATID with the deepest progression) and render
# one combined plotly horizontal-bar timeline showing all their LOTs,
# plus a DT table with the raw LOT detail rows for audit.
#
# Why deterministic: stakeholders can come back tomorrow and see the
# same examples, and the same examples can be checked against source
# claims. Random sampling would fail that workflow.

.PATIENT_EXAMPLES_N <- 3L

# Categories are simple: a name, a one-line description, and a SQL
# predicate over a per-patient summary CTE. The predicate is applied
# inside .gallery_pick(), so it can reference the aggregated columns
# (max_lot, any_cart, any_allo, etc.) by name.
.gallery_categories <- function() list(
  list(key = "lot1_to_lot2",
       label = "Typical LOT1 -> LOT2 progressor (MED-started)",
       desc  = "Patients who progressed from a MED-started LOT1 to LOT2. Validates the normal MED_ADD/DISCONTINUATION -> next-line trigger logic.",
       pred  = "max_lot >= 2 AND lot1_start_type = 'MED'"),
  list(key = "lot1_only_discon",
       label = "LOT1-only non-progressor (DISCONTINUATION)",
       desc  = "Patients whose LOT1 ended at DISCONTINUATION and who never started LOT2. Confirms why they are absent from the LOT1->LOT2 Sankeys.",
       pred  = "max_lot = 1 AND lot1_end_reason = 'DISCONTINUATION'"),
  list(key = "cart_init",
       label = "CART_INIT case",
       desc  = "Patient with any LOT ending at CART_INIT (MED_ADD followed by CAR-T within 45 days). Validates the CAR-T consolidation rule.",
       pred  = "any_cart_init = 1"),
  list(key = "sct_auto",
       label = "SCT_AUTO case",
       desc  = "Patient with any LOT starting at SCT_AUTO. Validates the autologous-SCT start-type assignment.",
       pred  = "any_sct_auto = 1"),
  list(key = "sct_allo",
       label = "SCT_ALLO single-day case",
       desc  = "Patient with any LOT starting at SCT_ALLO. The ALLO LOT spans a single day per spec; this view shows that visually.",
       pred  = "any_sct_allo = 1"),
  list(key = "death_on_lot1",
       label = "Death on LOT1",
       desc  = "Patient whose LOT1 ended at DEATH (no qualifying LOT2 trigger between runout and death).",
       pred  = "lot1_end_reason = 'DEATH'"),
  list(key = "study_end_on_lot1",
       label = "Study-end / observable-end on LOT1",
       desc  = "Patient whose LOT1 was censored at study end (no death, no progression). Validates the STUDY_END branch.",
       pred  = "lot1_end_reason = 'STUDY_END'")
)

# Per-patient summary CTE used by every category predicate. Centralised
# so categories share one consistent definition of "any CART" etc.
.gallery_summary_cte <- function(lot_long_tbl) {
  glue("
    WITH pat AS (
      SELECT cast(PATID as string) AS PATID,
             max(LOT_NUM)                                        AS max_lot,
             max(CASE WHEN LOT_NUM = 1 THEN LOT_START_TYPE END)  AS lot1_start_type,
             max(CASE WHEN LOT_NUM = 1 THEN LOT_BASE_END_REASON END) AS lot1_end_reason,
             max(CASE WHEN LOT_BASE_END_REASON = 'CART_INIT'
                      THEN 1 ELSE 0 END)                         AS any_cart_init,
             max(CASE WHEN LOT_START_TYPE IN ('CART','SCT_CART','CART_INIT')
                      THEN 1 ELSE 0 END)                         AS any_cart,
             max(CASE WHEN LOT_START_TYPE = 'SCT_AUTO' THEN 1 ELSE 0 END) AS any_sct_auto,
             max(CASE WHEN LOT_START_TYPE = 'SCT_ALLO' THEN 1 ELSE 0 END) AS any_sct_allo
      FROM {lot_long_tbl}
      GROUP BY PATID
    )")
}

# Deterministic picker: ORDER BY max_lot DESC (prefer deeper journeys),
# then PATID ASC (stable across runs).
.gallery_pick <- function(con, lot_long_tbl, predicate, n_each) {
  sql <- paste0(
    .gallery_summary_cte(lot_long_tbl), "
    SELECT PATID FROM pat
    WHERE ", predicate, "
    ORDER BY max_lot DESC, PATID ASC
    LIMIT ", as.integer(n_each))
  rows <- tryCatch(db_q(con, sql), error = function(e) NULL)
  if (is.null(rows) || nrow(rows) == 0) return(character(0))
  as.character(rows$PATID)
}

# Pull the full LOT detail for a set of PATIDs.
.gallery_fetch_lots <- function(con, lot_long_tbl, patids) {
  if (length(patids) == 0) return(NULL)
  ids <- paste0("'", gsub("'", "''", patids), "'", collapse = ",")
  df <- tryCatch(db_q(con, glue("
    SELECT cast(PATID as string) AS PATID, LOT_NUM,
           LOT_START_TYPE, LOT_START_DT, LOT_BASE_END_DT,
           LOT_BASE_END_REASON, LOT_BASE_LENGTH,
           LOT_BASE_MEDS
    FROM {lot_long_tbl}
    WHERE cast(PATID as string) IN ({ids})
    ORDER BY PATID, LOT_NUM
  ")), error = function(e) NULL)
  if (is.null(df) || nrow(df) == 0) return(NULL)
  df$LOT_START_DT    <- as.Date(df$LOT_START_DT)
  df$LOT_BASE_END_DT <- as.Date(df$LOT_BASE_END_DT)
  df
}

# Anonymise a PATID for display (last 6 chars, lower-cased), kept stable
# so the same masked id appears across views for the same patient.
.mask_pid <- function(p) {
  p <- as.character(p)
  s <- nchar(p) - 5L; s[s < 1L] <- 1L
  paste0("...", tolower(substring(p, s)))
}

# One combined timeline (plotly horizontal bars) for up to N example
# patients sharing a category. Each LOT is a coloured bar from
# LOT_START_DT to LOT_BASE_END_DT, colored by LOT_START_TYPE. Tooltip
# carries the LOT number, regimen, length, and end reason.
.gallery_timeline_plot <- function(df, category_label) {
  if (is.null(df) || nrow(df) == 0 || !has_plotly) return(NULL)
  df$row_label <- paste0(.mask_pid(df$PATID), "  L", df$LOT_NUM)
  df$row_label <- factor(df$row_label, levels = rev(unique(df$row_label)))
  df$start_type_color <- ifelse(
    df$LOT_START_TYPE %in% names(lot_start_palette),
    lot_start_palette[df$LOT_START_TYPE], "#9AA0A6")
  df$tooltip <- paste0(
    "PATID ", .mask_pid(df$PATID),
    "\nLOT ", df$LOT_NUM, " (", df$LOT_START_TYPE, ")",
    "\n", format(df$LOT_START_DT), " - ", format(df$LOT_BASE_END_DT),
    "\n", df$LOT_BASE_LENGTH, " days",
    "\nEnd: ", df$LOT_BASE_END_REASON,
    "\nMeds: ", df$LOT_BASE_MEDS)
  tryCatch({
    plotly::plot_ly(df, type = "bar", orientation = "h",
                    y = ~row_label,
                    base = ~as.numeric(LOT_START_DT),
                    x = ~as.numeric(LOT_BASE_END_DT - LOT_START_DT) + 1,
                    marker = list(color = df$start_type_color,
                                  line = list(color = "white", width = 1)),
                    text = ~tooltip, hoverinfo = "text") |>
      plotly::layout(
        title = list(
          text = paste0("Patient journeys - ", category_label,
                        "<br><span style='font-size:11px;color:#6B7280'>",
                        "deterministic examples; one row per LOT</span>"),
          font = list(size = 14), x = 0.02),
        xaxis = list(type = "date", title = "Date",
                     gridcolor = "#EAECEE"),
        yaxis = list(title = "", automargin = TRUE),
        margin = list(l = 10, r = 10, t = 70, b = 40),
        showlegend = FALSE, paper_bgcolor = "white",
        plot_bgcolor  = "white") |>
      plotly::config(displayModeBar = TRUE, displaylogo = FALSE)
  }, error = function(e) {
    log_msg("  INFO: gallery timeline '", category_label,
            "' skipped (", conditionMessage(e), ")")
    NULL
  })
}

# One gallery category: timeline plot + audit table + brief HTML card
# describing what this view validates.
.gallery_one <- function(con, lot_long_tbl, cat, section, title_prefix) {
  patids <- .gallery_pick(con, lot_long_tbl, cat$pred, .PATIENT_EXAMPLES_N)
  if (length(patids) == 0) {
    add_html_card(paste0(
      '<div style="font-family:system-ui;padding:14px;max-width:900px;color:#a06000">',
      '<h3>', cat$label, '</h3>',
      '<p>No example patients matched this predicate against <code>',
      lot_long_tbl, '</code> in this cohort.</p></div>'),
      section = section,
      title = paste0(title_prefix, cat$label))
    return(invisible())
  }
  df <- .gallery_fetch_lots(con, lot_long_tbl, patids)
  if (is.null(df) || nrow(df) == 0) return(invisible())

  add_html_card(paste0(
    '<div style="font-family:system-ui;padding:14px;max-width:900px">',
    '<h3>', cat$label, '</h3>',
    '<p style="color:#555;font-size:13px">', cat$desc, '</p>',
    '<p style="color:#555;font-size:12px">Showing <b>',
    length(patids), '</b> deterministic example',
    if (length(patids) == 1) "" else "s",
    ' (ordered by deepest LOT reached, then ascending PATID; same examples ',
    'on every rerun so they can be audited against source claims).</p>',
    '</div>'),
    section = section,
    title = paste0(title_prefix, cat$label, " - about"))

  sk <- .gallery_timeline_plot(df, cat$label)
  if (!is.null(sk))
    add_to_dashboard(sk, section = section,
                     title = paste0(title_prefix, cat$label, " - timeline"))

  display <- df
  display$PATID <- .mask_pid(display$PATID)
  save_table(display, section = section,
             title = paste0(title_prefix, cat$label, " - LOT detail"))
}

# Top-level entry: emit the patient gallery for a cohort.
build_patient_gallery <- function(con, lot_long_tbl,
                                  section = "Patient examples",
                                  title_prefix = "Examples: ") {
  cats <- .gallery_categories()
  for (cat in cats) .gallery_one(con, lot_long_tbl, cat, section, title_prefix)
}

# ---- LOT logic QC counters -----------------------------------------
# Counts of the cases the LOT cascade is supposed to produce, so a
# reviewer can confirm the rule actually fires on real patients in this
# cohort. Pure aggregation on LOT_LONG - no new flags.
build_lot_qc_counters <- function(con, lot_long_tbl,
                                  section = "Validation",
                                  title_prefix = "Validation: ") {
  df <- tryCatch(db_q(con, glue("
    WITH per_pat AS (
      SELECT cast(PATID as string) AS PATID,
             max(LOT_NUM)                                                  AS max_lot,
             sum(CASE WHEN LOT_START_TYPE = 'SCT_AUTO' THEN 1 ELSE 0 END)  AS n_auto,
             sum(CASE WHEN LOT_START_TYPE = 'SCT_ALLO' THEN 1 ELSE 0 END)  AS n_allo,
             sum(CASE WHEN LOT_START_TYPE IN ('CART','SCT_CART','CART_INIT')
                      THEN 1 ELSE 0 END)                                   AS n_cart,
             sum(CASE WHEN LOT_BASE_END_REASON = 'CART_INIT' THEN 1 ELSE 0 END) AS n_cart_init,
             sum(CASE WHEN LOT_BASE_END_REASON = 'MED_ADD'   THEN 1 ELSE 0 END) AS n_med_add,
             sum(CASE WHEN LOT_BASE_END_REASON = 'DEATH'     THEN 1 ELSE 0 END) AS n_death,
             sum(CASE WHEN LOT_BASE_END_REASON = 'DISCONTINUATION' THEN 1 ELSE 0 END) AS n_discon,
             sum(CASE WHEN LOT_BASE_END_REASON = 'STUDY_END' THEN 1 ELSE 0 END) AS n_studyend
      FROM {lot_long_tbl}
      GROUP BY PATID
    )
    SELECT
      cast((SELECT count(*) FROM per_pat)                       as int) AS total_patients,
      cast((SELECT count(*) FROM per_pat WHERE n_cart      >= 1) as int) AS pts_with_any_cart,
      cast((SELECT count(*) FROM per_pat WHERE n_auto      >= 1) as int) AS pts_with_any_sct_auto,
      cast((SELECT count(*) FROM per_pat WHERE n_auto      >= 2) as int) AS pts_with_sct_auto_tandem_or_excess,
      cast((SELECT count(*) FROM per_pat WHERE n_allo      >= 1) as int) AS pts_with_any_sct_allo,
      cast((SELECT count(*) FROM per_pat WHERE n_cart_init >= 1) as int) AS pts_with_any_cart_init_end,
      cast((SELECT count(*) FROM per_pat WHERE n_med_add   >= 1) as int) AS pts_with_any_med_add_end,
      cast((SELECT count(*) FROM per_pat WHERE n_death     >= 1) as int) AS pts_with_any_death_end,
      cast((SELECT count(*) FROM per_pat WHERE n_discon    >= 1) as int) AS pts_with_any_discon_end,
      cast((SELECT count(*) FROM per_pat WHERE n_studyend  >= 1) as int) AS pts_with_any_study_end
  ")), error = function(e) NULL)
  if (is.null(df) || nrow(df) == 0) return(invisible())
  total <- as.numeric(df$total_patients)
  out <- data.frame(
    metric = c("Total patients", "Any CAR-T LOT",
               "Any SCT_AUTO LOT", "SCT_AUTO appears 2+ times (tandem or excess)",
               "Any SCT_ALLO LOT", "Any CART_INIT end reason",
               "Any MED_ADD end reason", "Any DEATH end reason",
               "Any DISCONTINUATION end reason", "Any STUDY_END end reason"),
    n_patients = as.numeric(c(df$total_patients,
                              df$pts_with_any_cart,
                              df$pts_with_any_sct_auto,
                              df$pts_with_sct_auto_tandem_or_excess,
                              df$pts_with_any_sct_allo,
                              df$pts_with_any_cart_init_end,
                              df$pts_with_any_med_add_end,
                              df$pts_with_any_death_end,
                              df$pts_with_any_discon_end,
                              df$pts_with_any_study_end)),
    stringsAsFactors = FALSE)
  out$pct_of_cohort <- if (total > 0)
    round(100 * out$n_patients / total, 1) else NA_real_
  save_table(out, section = section,
             title = paste0(title_prefix, "LOT cascade counters"))
}

# ---- LOT1 start-year trend ----------------------------------------
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
  if (has_ggplot2) {
    p <- ggplot(df, aes(x = factor(start_year), y = n_patients,
                        text = paste0("Year: ", start_year,
                                      "\nLOT1 patients: ", format(n_patients, big.mark=",")))) +
      geom_col(fill = "#2E86AB", width = 0.7) +
      geom_text(aes(label = format(n_patients, big.mark = ",")),
                vjust = -0.3, size = 3.3, color = "grey20") +
      labs(title = "LOT1 starts by calendar year",
           subtitle = paste0("Cohort = ", lot_long_tbl,
                             ". Cross-check that the trend tracks expected enrolment."),
           x = NULL, y = "Distinct LOT1 patients") +
      scale_y_continuous(labels = scales::comma_format(),
                         expand = expansion(mult = c(0, 0.15))) +
      theme_lot()
    save_plot(p, "lot1_start_year_trend.png", width = 10, height = 5,
              section = section,
              title = paste0(title_prefix, "LOT1 starts by year"))
  }
}

# ---- Data-quality / outlier checks ---------------------------------
# Counts of suspicious cases. Each row should be 0 in a clean cohort;
# a non-zero count is not necessarily a bug, but it tells reviewers
# which edge case to inspect.
build_outlier_checks <- function(con, lot_long_tbl,
                                 section = "Validation",
                                 title_prefix = "Validation: ") {
  df <- tryCatch(db_q(con, glue("
    WITH lot AS (SELECT * FROM {lot_long_tbl}),
    per_pat AS (
      SELECT cast(PATID as string) AS PATID,
             count(*)               AS n_rows,
             min(LOT_NUM)           AS min_lot,
             max(LOT_NUM)           AS max_lot,
             count(DISTINCT LOT_NUM) AS n_distinct_lot
      FROM lot
      GROUP BY PATID
    ),
    overlaps AS (
      SELECT DISTINCT a.PATID
      FROM lot a JOIN lot b
        ON a.PATID = b.PATID AND a.LOT_NUM < b.LOT_NUM
       AND a.LOT_BASE_END_DT IS NOT NULL AND b.LOT_START_DT IS NOT NULL
       AND a.LOT_BASE_END_DT >= b.LOT_START_DT
    )
    SELECT
      cast((SELECT count(*) FROM lot WHERE LOT_BASE_LENGTH IS NULL OR LOT_BASE_LENGTH <= 0) as int) AS n_zero_or_neg_length,
      cast((SELECT count(*) FROM lot
            WHERE LOT_BASE_END_DT IS NOT NULL
              AND LOT_START_DT    IS NOT NULL
              AND LOT_BASE_END_DT < LOT_START_DT) as int) AS n_end_before_start,
      cast((SELECT count(*) FROM lot WHERE LOT_BASE_MEDS IS NULL OR trim(LOT_BASE_MEDS) = '') as int) AS n_missing_meds,
      cast((SELECT count(*) FROM lot WHERE LOT_BASE_END_REASON IS NULL) as int) AS n_missing_end_reason,
      cast((SELECT count(*) FROM per_pat WHERE min_lot > 1) as int) AS pts_with_lot2plus_but_no_lot1,
      cast((SELECT count(*) FROM per_pat WHERE max_lot <> n_distinct_lot) as int) AS pts_with_lot_num_gap,
      cast((SELECT count(*) FROM (SELECT PATID, LOT_NUM, count(*) AS c FROM lot
                                  GROUP BY PATID, LOT_NUM
                                  HAVING count(*) > 1)) as int) AS pts_with_duplicate_lot_rows,
      cast((SELECT count(*) FROM overlaps) as int) AS pts_with_overlapping_lots,
      cast((SELECT count(*) FROM lot WHERE LOT_BASE_LENGTH > 3650) as int) AS n_lots_over_10_years
  ")), error = function(e) NULL)
  if (is.null(df) || nrow(df) == 0) return(invisible())
  out <- data.frame(
    check = c("LOT_BASE_LENGTH zero or negative",
              "LOT_BASE_END_DT < LOT_START_DT",
              "LOT_BASE_MEDS missing or blank",
              "LOT_BASE_END_REASON missing",
              "Patient has LOT2+ but no LOT1",
              "Patient has a LOT_NUM gap (e.g. 1, 3, no 2)",
              "Duplicate (PATID, LOT_NUM) rows",
              "Patient has overlapping LOT intervals",
              "LOT length over 10 years (impossible)"),
    n_cases = as.numeric(c(df$n_zero_or_neg_length,
                           df$n_end_before_start,
                           df$n_missing_meds,
                           df$n_missing_end_reason,
                           df$pts_with_lot2plus_but_no_lot1,
                           df$pts_with_lot_num_gap,
                           df$pts_with_duplicate_lot_rows,
                           df$pts_with_overlapping_lots,
                           df$n_lots_over_10_years)),
    stringsAsFactors = FALSE)
  out$status <- ifelse(out$n_cases == 0, "OK",
                       ifelse(out$n_cases < 5, "review", "investigate"))
  save_table(out, section = section,
             title = paste0(title_prefix, "Data-quality / outlier checks"))
  add_html_card(paste0(
    '<div style="font-family:system-ui;padding:14px;max-width:900px">',
    '<h3>Data-quality checks</h3>',
    '<p style="color:#555;font-size:13px">Each row is a sanity check ',
    'against <code>', lot_long_tbl, '</code>. A non-zero count is not ',
    'necessarily a bug - some of these (e.g. very long LOTs, ',
    'overlapping intervals) can be expected for data-edge patients. ',
    'But anything that flips from <b>OK</b> to <b>investigate</b> ',
    'between runs should be looked at.</p></div>'),
    section = section,
    title = paste0(title_prefix, "Data-quality checks - about"))
}

# ---- NDMM evidence drilldown ---------------------------------------
# For 3 deterministically picked included and 3 excluded NDMM
# patients, show their per-flag pass/fail values plus their LOT
# detail. Lets a stakeholder verify the IE filters one patient at a
# time. Requires NDMM_FLAGS_ALL (built by 06_ndmm_dashboard.R's
# build_ndmm_flags()).
.ndmm_pick_examples <- function(con, flags_tbl, include, n_each) {
  pred <- if (isTRUE(include))
    "CE_pre_lot1_12mo = 1 AND NO_BELANTAMAB = 1 AND NO_PRIOR_MM_TX = 1 AND NO_OTHER_CANCER_PRE_LOT1 = 1"
  else
    "NOT (CE_pre_lot1_12mo = 1 AND NO_BELANTAMAB = 1 AND NO_PRIOR_MM_TX = 1 AND NO_OTHER_CANCER_PRE_LOT1 = 1)"
  sql <- glue("
    SELECT PATID FROM {flags_tbl}
    WHERE {pred}
    ORDER BY PATID ASC
    LIMIT {as.integer(n_each)}")
  rows <- tryCatch(db_q(con, sql), error = function(e) NULL)
  if (is.null(rows) || nrow(rows) == 0) return(character(0))
  as.character(rows$PATID)
}

.ndmm_flags_for <- function(con, flags_tbl, patids) {
  if (length(patids) == 0) return(NULL)
  ids <- paste0("'", gsub("'", "''", patids), "'", collapse = ",")
  df <- tryCatch(db_q(con, glue("
    SELECT cast(PATID as string) AS PATID,
           CE_pre_lot1_12mo, NO_BELANTAMAB,
           NO_PRIOR_MM_TX, NO_OTHER_CANCER_PRE_LOT1
    FROM {flags_tbl}
    WHERE cast(PATID as string) IN ({ids})
    ORDER BY PATID
  ")), error = function(e) NULL)
  if (is.null(df) || nrow(df) == 0) return(NULL)
  for (col in c("CE_pre_lot1_12mo","NO_BELANTAMAB","NO_PRIOR_MM_TX",
                "NO_OTHER_CANCER_PRE_LOT1"))
    df[[col]] <- ifelse(as.numeric(df[[col]]) == 1, "PASS", "FAIL")
  df$PATID <- .mask_pid(df$PATID)
  df
}

build_ndmm_evidence_drilldown <- function(con, flags_tbl, lot_long_tbl,
                                          section = "Validation",
                                          title_prefix = "Validation: ",
                                          n_each = 3L) {
  inc_pids <- .ndmm_pick_examples(con, flags_tbl, TRUE,  n_each)
  exc_pids <- .ndmm_pick_examples(con, flags_tbl, FALSE, n_each)
  if (length(inc_pids) == 0 && length(exc_pids) == 0) return(invisible())

  add_html_card(paste0(
    '<div style="font-family:system-ui;padding:14px;max-width:900px">',
    '<h3>NDMM IE evidence drilldown</h3>',
    '<p style="color:#555;font-size:13px">Pass/fail of each NDMM ',
    'inclusion/exclusion flag for a handful of deterministically picked ',
    'patients - <b>', length(inc_pids), '</b> included plus <b>',
    length(exc_pids), '</b> excluded. Pick the same patient ID in the ',
    'LOT detail table to see which line of therapy each flag was tied ',
    'to. <code>CE_pre_lot1_12mo</code> = continuous enrollment in the ',
    '12 months before LOT1. <code>NO_BELANTAMAB</code> = no belantamab ',
    'in any LOT. <code>NO_PRIOR_MM_TX</code> = no MM oncology therapy in ',
    'the 12 months before LOT1. <code>NO_OTHER_CANCER_PRE_LOT1</code> ',
    '= no other active cancer (1 IP or 2 OP within 30d) in the 12 ',
    'months before LOT1, with the MM-adjacent override applied.</p>',
    '</div>'),
    section = section,
    title = paste0(title_prefix, "NDMM evidence drilldown - about"))

  inc_df <- .ndmm_flags_for(con, flags_tbl, inc_pids)
  exc_df <- .ndmm_flags_for(con, flags_tbl, exc_pids)
  if (!is.null(inc_df))
    save_table(inc_df, section = section,
               title = paste0(title_prefix, "NDMM included - flag pass/fail"))
  if (!is.null(exc_df))
    save_table(exc_df, section = section,
               title = paste0(title_prefix, "NDMM excluded - flag pass/fail"))

  # LOT detail for the same picked patients (only for INCLUDED, since
  # excluded patients are not in NDMM_LOT_LONG_FILT by construction).
  if (length(inc_pids) > 0) {
    lot_df <- .gallery_fetch_lots(con, lot_long_tbl, inc_pids)
    if (!is.null(lot_df)) {
      lot_df$PATID <- .mask_pid(lot_df$PATID)
      save_table(lot_df, section = section,
                 title = paste0(title_prefix, "NDMM included - LOT detail"))
    }
  }
}

# ---- Phase-C entry: emit all validation views for a cohort ---------
# ndmm_flags_tbl is optional and only meaningful for the NDMM cohort
# (the Overall cohort does not have NDMM-specific flags).
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

# ---- Phase D: run-to-run comparison --------------------------------
# Persists a small dashboard-owned table of per-cohort run summaries,
# then surfaces the last few runs side by side so reviewers can spot
# unexpected count changes after code or codelist updates.
#
# Schema (all STRING / DOUBLE so it round-trips cleanly through Spark):
#   run_ts         STRING  e.g. "2026-06-14 11:00:00"
#   cohort_label   STRING  e.g. "Overall", "NDMM"
#   metric         STRING  e.g. "n_lot1", "n_cart_any"
#   value          DOUBLE
#
# Caps history at the last 20 runs per cohort. Uses the same CREATE OR
# REPLACE TABLE idiom as persist_attrition_table().
.RUN_SUMMARY_TBL <- "lot_dashboard_run_summary"
.RUN_SUMMARY_CAP <- 20L

.run_summary_full_name <- function() {
  if (!nzchar(cfg$work_schema)) return(NULL)
  if (nzchar(cfg$catalog))
    paste0(cfg$catalog, ".", cfg$work_schema, ".", .RUN_SUMMARY_TBL)
  else
    paste0(cfg$work_schema, ".", .RUN_SUMMARY_TBL)
}

.compute_run_metrics <- function(con, lot_long_tbl) {
  row <- tryCatch(db_q(con, glue("
    WITH per_pat AS (
      SELECT PATID,
             max(LOT_NUM)                                                   AS max_lot,
             max(CASE WHEN LOT_NUM = 1 THEN LOT_START_DT END)              AS lot1_dt,
             max(CASE WHEN LOT_NUM = 1 AND LOT_START_TYPE = 'MED'
                      THEN 1 ELSE 0 END)                                    AS lot1_med,
             max(CASE WHEN LOT_START_TYPE IN ('CART','SCT_CART','CART_INIT')
                      THEN 1 ELSE 0 END)                                    AS cart_any,
             max(CASE WHEN LOT_START_TYPE = 'SCT_ALLO' THEN 1 ELSE 0 END)   AS allo_any,
             max(CASE WHEN LOT_START_TYPE = 'SCT_AUTO' THEN 1 ELSE 0 END)   AS auto_any,
             max(CASE WHEN LOT_BASE_END_REASON = 'CART_INIT' THEN 1 ELSE 0 END) AS cart_init_any,
             max(CASE WHEN LOT_BASE_END_REASON = 'DEATH'     THEN 1 ELSE 0 END) AS death_any
      FROM {lot_long_tbl}
      GROUP BY PATID
    )
    SELECT
      cast((SELECT count(*)             FROM per_pat)                       as double) AS n_patients,
      cast((SELECT count(*)             FROM per_pat WHERE max_lot >= 1)    as double) AS n_lot1,
      cast((SELECT count(*)             FROM per_pat WHERE max_lot >= 2)    as double) AS n_lot2,
      cast((SELECT count(*)             FROM per_pat WHERE max_lot >= 3)    as double) AS n_lot3,
      cast((SELECT count(*)             FROM per_pat WHERE cart_any = 1)    as double) AS n_cart_any,
      cast((SELECT count(*)             FROM per_pat WHERE allo_any = 1)    as double) AS n_allo_any,
      cast((SELECT count(*)             FROM per_pat WHERE auto_any = 1)    as double) AS n_auto_any,
      cast((SELECT count(*)             FROM per_pat WHERE cart_init_any = 1) as double) AS n_cart_init,
      cast((SELECT count(*)             FROM per_pat WHERE death_any = 1)   as double) AS n_death_end,
      cast((SELECT count(*)             FROM per_pat WHERE lot1_med = 1)    as double) AS n_lot1_med_started,
      cast((SELECT year(min(lot1_dt))   FROM per_pat)                       as double) AS lot1_min_year,
      cast((SELECT year(max(lot1_dt))   FROM per_pat)                       as double) AS lot1_max_year
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
    paste0("(", sq(df$run_ts[i]), ", ", sq(df$cohort_label[i]), ", ",
           sq(df$metric[i]), ", ",
           if (is.na(df$value[i])) "cast(NULL as double)"
           else format(df$value[i], scientific = FALSE), ")")
  }, character(1))
  sql <- glue("
    CREATE OR REPLACE TABLE {tbl_name} AS
    SELECT * FROM VALUES
      {paste(rows, collapse = ',\n      ')}
    AS t(run_ts, cohort_label, metric, value)
  ")
  tryCatch(db_exec(con, sql), error = function(e)
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

  # New run's metrics
  metrics <- .compute_run_metrics(con, lot_long_tbl)
  if (length(metrics) == 0) return(invisible())
  new_rows <- data.frame(
    run_ts       = run_ts,
    cohort_label = cohort_label,
    metric       = names(metrics),
    value        = as.numeric(unlist(metrics)),
    stringsAsFactors = FALSE)

  # Combine with prior rows (if any), cap history per cohort.
  prior <- .read_run_summary(con, tbl_name)
  combined <- if (is.null(prior) || nrow(prior) == 0) new_rows
              else rbind(prior, new_rows)
  combined <- unique(combined)
  ts_keep <- unique(combined$run_ts[combined$cohort_label == cohort_label])
  ts_keep <- tail(sort(ts_keep), .RUN_SUMMARY_CAP)
  combined <- combined[!(combined$cohort_label == cohort_label) |
                         combined$run_ts %in% ts_keep, ]
  .write_run_summary(con, tbl_name, combined)

  # Build the side-by-side comparison for this cohort: last 4 runs.
  this_cohort <- combined[combined$cohort_label == cohort_label, ]
  if (nrow(this_cohort) == 0) return(invisible())
  recent_ts <- tail(sort(unique(this_cohort$run_ts)), 4L)
  wide_rows <- unique(this_cohort$metric)
  cmp <- data.frame(metric = wide_rows, stringsAsFactors = FALSE)
  for (ts in recent_ts) {
    sub <- this_cohort[this_cohort$run_ts == ts, c("metric","value")]
    cmp[[ts]] <- sub$value[match(cmp$metric, sub$metric)]
  }
  if (length(recent_ts) >= 2) {
    cur  <- cmp[[recent_ts[length(recent_ts)]]]
    prev <- cmp[[recent_ts[length(recent_ts) - 1L]]]
    cmp$delta_vs_prev      <- cur - prev
    cmp$pct_delta_vs_prev  <- ifelse(is.finite(prev) & prev != 0,
                                     round(100 * (cur - prev) / prev, 1),
                                     NA_real_)
  }
  save_table(cmp, section = section,
             title = paste0(title_prefix, "Run-over-run comparison (last ",
                            length(recent_ts), " runs)"))
  add_html_card(paste0(
    '<div style="font-family:system-ui;padding:14px;max-width:900px">',
    '<h3>Run-over-run comparison</h3>',
    '<p style="color:#555;font-size:13px">Cohort: <b>', cohort_label,
    '</b>. The table reads <code>', tbl_name, '</code>, a small ',
    'dashboard-owned summary table (current run is row <code>',
    run_ts, '</code>). Last <b>', length(recent_ts),
    '</b> runs are shown side by side; the <code>delta_vs_prev</code> ',
    'and <code>pct_delta_vs_prev</code> columns are current minus the ',
    'penultimate run. History is capped at ', .RUN_SUMMARY_CAP,
    ' runs per cohort. Persistence is dashboard-side only - no parent ',
    'pipeline table is touched.</p></div>'),
    section = section,
    title = paste0(title_prefix, "Run comparison - about"))
}
