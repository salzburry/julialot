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
