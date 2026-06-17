# Visualization helpers and the combined-HTML dashboard builder:
# package checks, palette, theme, save helpers, the dashboard
# collector, and build_dashboard().

has_ggplot2 <- requireNamespace("ggplot2", quietly = TRUE)
has_plotly  <- requireNamespace("plotly", quietly = TRUE) &&
               requireNamespace("htmlwidgets", quietly = TRUE)
has_dt      <- requireNamespace("DT", quietly = TRUE)
has_jsonlite  <- requireNamespace("jsonlite", quietly = TRUE)
has_base64enc <- requireNamespace("base64enc", quietly = TRUE)
if (has_ggplot2) {
  suppressPackageStartupMessages(library(ggplot2))
}

# Defined here because every dashboard sources dashboard_lot.R.
`%||%` <- function(a, b) if (is.null(a) || !nzchar(as.character(a))) b else a

# ---- Dashboard collector: accumulates widgets for the combined HTML ----
dashboard_items <- list()

add_to_dashboard <- function(widget, section, title, type = "figure") {
  dashboard_items[[length(dashboard_items) + 1]] <<- list(
    widget = widget, section = section, title = title, type = type
  )
}

# ---- Shared visual theme and palettes ----
# One source of truth for both dashboards. Same category -> same colour
# everywhere; tune here to retune every chart in both. Chosen to read
# on a white background (no near-black fills) and to keep the SCT family
# consistent between "start type" and "end reason".
lot_class_palette <- c(
  "IMMUNOMOD"  = "#2E86AB",
  "PROTINHIB"  = "#A23B72",
  "MUSTARD"    = "#F18F01",
  "ACD38"      = "#C73E1D",
  "STEROID"    = "#44BBA4",
  "ABCMA"      = "#8D5A97",
  "ASLAMF7"    = "#3F88C5",
  "MELP"       = "#B5651D",
  "TOPOINHIB"  = "#E94F37",
  "HIST"       = "#5FAD56",
  "NUCLEAR"    = "#F49D37",
  "BLC21"      = "#D72638",
  "ATCELL"     = "#F2D0A4",
  "UNV"        = "#7B6D8D",
  "PLAT"       = "#6E8898"
)

# LOT start type (used by LOT1-5 charts + the journey Gantt).
lot_start_palette <- c(
  "MED"       = "#2E86AB",
  "SCT_AUTO"  = "#A23B72",
  "SCT_ALLO"  = "#8D5A97",
  "SCT_CART"  = "#3F88C5",
  "CART"      = "#3F88C5",
  "CART_INIT" = "#44AF69"
)

# LOT end reason (SCT_* / CART_INIT colours match lot_start_palette).
lot_reason_palette <- c(
  "MED_ADD"         = "#F18F01",
  "DISCONTINUATION" = "#C73E1D",
  "DEATH"           = "#5C6670",
  "STUDY_END"       = "#9AA0A6",
  "DISENROLLMENT"   = "#B0879F",
  "SCT_AUTO"        = "#A23B72",
  "SCT_ALLO"        = "#8D5A97",
  "SCT_CART"        = "#3F88C5",
  "SCT"             = "#8D5A97",
  "CART_INIT"       = "#44AF69"
)

theme_lot <- function(base_size = 13) {
  theme_minimal(base_size = base_size) %+replace%
    theme(
      plot.title       = element_text(face = "bold", size = base_size + 2, margin = margin(b = 10)),
      plot.subtitle    = element_text(color = "grey40", size = base_size, margin = margin(b = 12)),
      plot.caption     = element_text(color = "grey50", size = base_size - 3, hjust = 0),
      panel.grid.major = element_line(color = "grey90", linewidth = 0.3),
      panel.grid.minor = element_blank(),
      axis.title       = element_text(face = "bold", size = base_size - 1),
      axis.text        = element_text(size = base_size - 2),
      legend.position  = "top",
      legend.title     = element_text(face = "bold", size = base_size - 1),
      legend.text      = element_text(size = base_size - 2),
      plot.margin      = margin(15, 15, 15, 15)
    )
}

save_plot <- function(p, filename, width = 10, height = 6, section = "", title = "") {
  if (!has_ggplot2) return(invisible(NULL))
  dir.create(cfg$output_dir, showWarnings = FALSE, recursive = TRUE)
  # cfg$plot_filename_prefix lets a caller that runs the same builders
  # twice (e.g. the combined Overall+NDMM dashboard) keep both runs'
  # static PNGs in cfg$output_dir without clobbering each other. The
  # in-memory plotly object added below is unaffected - that's what
  # the HTML dashboard actually renders, so this is purely about the
  # standalone PNG artifact files.
  prefix <- if (is.null(cfg$plot_filename_prefix)) "" else cfg$plot_filename_prefix
  out_path <- file.path(cfg$output_dir, paste0(prefix, filename))
  tryCatch({
    ggsave(out_path, plot = p, width = width, height = height, dpi = 150, bg = "white")
    log_msg("  Figure saved: ", out_path)
  }, error = function(e) {
    log_msg("  WARNING: Could not save figure ", filename, ": ", e$message)
  })
  # Collect interactive version for dashboard (skip if dashboard disabled)
  if (isTRUE(cfg$build_dashboard) && has_plotly) {
    tryCatch({
      pp <- plotly::ggplotly(p, tooltip = "text") |>
        plotly::layout(
          hoverlabel = list(bgcolor = "white", font = list(size = 12)),
          margin = list(t = 60, b = 60)
        ) |>
        plotly::config(displayModeBar = TRUE, displaylogo = FALSE,
                       modeBarButtonsToRemove = list("lasso2d", "select2d"))
      add_to_dashboard(pp, section, title, type = "figure")
    }, error = function(e) {
      log_msg("  WARNING: Could not create interactive figure for dashboard: ", e$message)
    })
  }
}

# ---- Clinical-order display for regimen strings --------------------
# The pipeline stores regimens alphabetically (sort_array) - that canonical
# key is what counting and regimen_categories.csv matching rely on, so it
# stays untouched. For DISPLAY, re-order the SAME tokens by drug class so a
# regimen reads anti-CD38 -> other mAb/bispecific/ADC -> PI -> IMiD ->
# alkylator -> other targeted -> steroid (last), the novel-agent-first
# convention regimen_categories.csv uses (e.g. ELOT POMA). The remap is 1:1 (same
# token set, different order), so it never merges or splits groups.
REGIMEN_CLASS_RANK <- c(
  DARA = 1L, ISAT = 1L,                                  # anti-CD38 mAb
  ELOT = 2L, BELA = 2L, TECL = 2L, ELRA = 2L, TALQ = 2L, # other mAb/bispecific/ADC
  BORT = 3L, CARF = 3L, IXAZ = 3L,                       # proteasome inhibitor
  THAL = 4L, LENA = 4L, POMA = 4L,                       # IMiD
  CYCL = 5L, MELP = 5L,                                  # alkylator
  SELI = 6L,                                             # other targeted
  DEX = 9L, DEXA = 9L, DEXAMETHASONE = 9L,
  PRED = 9L, PREDNISONE = 9L)                            # steroid - last
clin_regimen <- function(x) {
  vapply(x, function(s) {
    if (is.na(s) || !nzchar(trimws(s))) return(s)
    toks <- strsplit(trimws(s), "[[:space:]]+")[[1]]
    toks <- toks[nzchar(toks)]
    if (length(toks) <= 1L) return(paste(toks, collapse = " "))
    rk <- REGIMEN_CLASS_RANK[toupper(toks)]
    rk[is.na(rk)] <- 7L              # unknown agents: between other & steroid
    paste(toks[order(rk, toupper(toks))], collapse = " ")
  }, character(1), USE.NAMES = FALSE)
}

# Set by build_modal_map() during dashboard setup; maps a canonical
# (alphabetical) backbone regimen -> its most-common real-world agent order.
REGIMEN_MODAL_MAP <- character(0)

# Display a regimen in the most-common real-world order: backbone agents in
# the modal start-order (REGIMEN_MODAL_MAP), steroid tokens appended last.
# Falls back to clinical order (clin_regimen) for any regimen with no modal
# entry. Display only - counting + category matching still use the canonical
# alphabetical key, so nothing double-counts.
disp_regimen <- function(x) {
  mm <- REGIMEN_MODAL_MAP
  vapply(x, function(s) {
    if (is.na(s) || !nzchar(trimws(s))) return(s)
    toks <- strsplit(trimws(s), "[[:space:]]+")[[1]]
    toks <- toks[nzchar(toks)]
    if (length(toks) <= 1L) return(paste(toks, collapse = " "))
    is_ster <- toupper(toks) %in% c("DEX","DEXA","DEXAMETHASONE","PRED","PREDNISONE")
    back <- toks[!is_ster]; ster <- toks[is_ster]
    if (length(back) == 0L) return(paste(toks, collapse = " "))
    canon <- paste(sort(toupper(back)), collapse = " ")
    disp_back <- if (length(mm) > 0L && canon %in% names(mm)) unname(mm[[canon]])
                 else clin_regimen(paste(back, collapse = " "))
    paste(c(disp_back, ster), collapse = " ")
  }, character(1), USE.NAMES = FALSE)
}

# Collect a data table for the dashboard (DT does NOT require plotly)
save_table <- function(df, section, title) {
  if (!isTRUE(cfg$build_dashboard)) return(invisible(NULL))
  if (!has_dt || !requireNamespace("htmlwidgets", quietly = TRUE)) return(invisible(NULL))
  tryCatch({
    # Convert integer64 columns for display
    for (col in names(df)) {
      if (inherits(df[[col]], "integer64")) df[[col]] <- as.numeric(df[[col]])
    }
    # Buttons gives Copy + CSV export when the DT Buttons extension is
    # installed (DT bundles it). If unavailable, fall back to the plain
    # dom = "ftip" layout so the table still renders.
    dt <- tryCatch(
      DT::datatable(df, rownames = FALSE,
                    extensions = "Buttons",
                    options = list(pageLength = 15, scrollX = TRUE,
                                   dom = "Bfrtip",
                                   buttons = list("copy", list(extend = "csv",
                                                                title = NULL))),
                    class = "display compact stripe hover"),
      error = function(e)
        DT::datatable(df, rownames = FALSE,
                      options = list(pageLength = 15, scrollX = TRUE,
                                     dom = "ftip"),
                      class = "display compact stripe hover"))
    # Percentage/rate columns (by name) render to 2 dp even when a value is
    # whole (98 -> 98.00); other numeric columns get 2 dp only if they hold a
    # fractional value, so integer counts/years stay clean.
    frac_cols <- Filter(function(cn) {
      v <- df[[cn]]
      if (!is.numeric(v)) return(FALSE)
      grepl("pct|percent|rate|prop|share|ratio", cn, ignore.case = TRUE) ||
        any(is.finite(v) & v != round(v))
    }, names(df))
    if (length(frac_cols) > 0)
      dt <- DT::formatRound(dt, columns = frac_cols, digits = 2)
    add_to_dashboard(dt, section, title, type = "table")
  }, error = function(e) {
    log_msg("  WARNING: Could not create table for dashboard: ", e$message)
  })
}

# ---- Acronym tooltips, baked into the card HTML at build time ------
# Card HTML renders inside sandboxed iframes, so parent-page JS can't
# annotate it. We rewrite known <code>TOKEN</code> tokens with a
# native title= and an inline dotted underline instead.
DASH_TOOLTIPS <- c(
  "CE_b" = "Continuous enrollment, baseline window",
  "CE_f" = "Continuous enrollment, follow-up window",
  "CE_3mosf" = "Continuous enrollment through 90d follow-up (no gaps)",
  "ELIG_COH_FINAL" = "Final eligibility cohort table",
  "LOT_LONG" = "One row per (PATID, LOT_NUM)",
  "LOT_LONG_AUG" = "LOT_LONG with steroid tokens appended for display",
  "MAP_STACKED" = "Per-patient medication-administration-period rollup",
  "MMA" = "Multiple-myeloma agent",
  "MMA_MED_PROCESSED" = "Parent MMA medication events, ID-period forward",
  "MED_ADD" = "LOT ended because a new non-base drug was added",
  "MED_ABBR" = "Standardized medication abbreviation token",
  "CART_INIT" = "LOT ended because CAR-T followed a MED_ADD within 45 days",
  "SCT_AUTO" = "Autologous stem-cell transplant",
  "SCT_ALLO" = "Allogeneic stem-cell transplant",
  "SCT_CART" = "CAR-T therapy (categorized as SCT)",
  "CART" = "CAR-T cell therapy (start type label)",
  "DISCONTINUATION" = "LOT ended at runout of all base agents",
  "DISENROLLMENT" = "LOT ended at enrollment gap (sensitivity only)",
  "STUDY_END" = "LOT ended at study end or end of observable period",
  "DEATH" = "LOT ended at death date",
  "NDMM" = "Newly diagnosed multiple myeloma",
  "OBS_END_DT" = "Observable-period end (min of study end, death, etc.)",
  "ENDDATE" = "min(study_end, death)",
  "ENDDATE_CE" = "min(study_end, death, disenrollment)",
  "FU_DAYS" = "Follow-up days from index",
  "INDEX_DATE" = "Patient index date (qualifying MM diagnosis)",
  "LOT1_START_DT" = "Date the 1L line of therapy started",
  "LOT_BASE_END_DT" = "Date the LOT ended (after the cascade)",
  "LOT_BASE_END_REASON" = "Why the LOT ended (one of the cascade values)",
  "LOT_START_TYPE" = "How the LOT started (MED, SCT_AUTO, CART, etc.)",
  "LOT_BASE_MEDS" = "Distinct base agents on the LOT (induction window)",
  "LOT_BASE_MEDS_AUG" = "LOT_BASE_MEDS plus steroid tokens (display only)",
  "LOT_BASE_LENGTH" = "LOT_BASE_END_DT - LOT_START_DT + 1 (days)",
  "PROC_CD" = "HCPCS / CPT procedure code on a medical claim",
  "BILL_PROC_CD" = "Billing HCPCS code on a medical claim",
  "RVNU_CD" = "Revenue code (facility claims only)",
  "NDC" = "National Drug Code (11-digit, zero-padded)",
  "CONF_ID" = "Confinement identifier on the inpatient confinement table",
  "DEXA" = "Dexamethasone (steroid token)",
  "PRED" = "Prednisone (steroid token)",
  "PATID" = "Patient identifier"
)

.esc_attr <- function(s) {
  s <- gsub("&", "&amp;",  as.character(s), fixed = TRUE)
  s <- gsub("<", "&lt;",   s, fixed = TRUE)
  s <- gsub(">", "&gt;",   s, fixed = TRUE)
  gsub('"',     "&quot;",  s, fixed = TRUE)
}

inject_tooltips <- function(html) {
  if (length(html) != 1 || !nzchar(html)) return(html)
  for (term in names(DASH_TOOLTIPS)) {
    plain <- paste0("<code>", term, "</code>")
    if (!grepl(plain, html, fixed = TRUE)) next
    tipped <- paste0(
      '<code title="', .esc_attr(DASH_TOOLTIPS[[term]]),
      '" style="border-bottom:1px dotted #0E7C7B;cursor:help">',
      .esc_attr(term), "</code>")
    html <- gsub(plain, tipped, html, fixed = TRUE)
  }
  html
}

# Add a raw HTML card to the dashboard (for overview/QC - no htmlwidget needed)
add_html_card <- function(html_content, section, title) {
  if (!isTRUE(cfg$build_dashboard)) return(invisible(NULL))
  dashboard_items[[length(dashboard_items) + 1]] <<- list(
    html = inject_tooltips(html_content), section = section,
    title = title, type = "html_card"
  )
}

# ---- KPI tile strip ------------------------------------------------
# Styles are inline because HTML cards render inside sandboxed iframes.
# Tile spec: list(label, value, sub, accent in c("orange","teal","muted")).
fmt_n <- function(x) {
  if (length(x) == 0 || any(is.na(x))) return("-")
  format(round(as.numeric(x)), big.mark = ",", scientific = FALSE)
}
fmt_pct <- function(num, den, digits = 1) {
  if (length(num) == 0 || length(den) == 0 ||
      !is.finite(num) || !is.finite(den) || den == 0) return("-")
  sprintf(paste0("%.", digits, "f%%"), 100 * num / den)
}
fmt_date_range <- function(min_d, max_d) {
  if (is.na(min_d) || is.na(max_d)) return("-")
  paste0(as.character(min_d), " to ", as.character(max_d))
}

kpi_strip_html <- function(tiles) {
  if (length(tiles) == 0) return("")
  accent_hex <- c(orange = "#F36633", teal = "#0E7C7B", muted = "#6B7280")
  tile_html <- vapply(tiles, function(t) {
    accent <- if (is.null(t$accent)) "orange" else t$accent
    bar <- unname(accent_hex[[if (accent %in% names(accent_hex)) accent else "orange"]])
    sub <- if (is.null(t$sub) || !nzchar(t$sub)) "" else
      paste0('<div style="font-size:11.5px;color:#6B7280;margin-top:3px">',
             t$sub, '</div>')
    sprintf(paste0(
      '<div style="flex:1 1 150px;min-width:140px;background:#fff;',
      'border:1px solid #E5E7EB;border-left:4px solid %s;border-radius:10px;',
      'padding:12px 14px;box-shadow:0 1px 2px rgba(0,0,0,0.04)">',
      '<div style="font-size:10.5px;font-weight:800;letter-spacing:0.5px;',
      'text-transform:uppercase;color:#6B7280;margin-bottom:4px">%s</div>',
      '<div style="font-size:22px;font-weight:800;color:#2A2A33;line-height:1.1">%s</div>',
      '%s</div>'),
      bar, t$label, t$value, sub)
  }, character(1))
  paste0('<div style="display:flex;flex-wrap:wrap;gap:10px;margin:0 0 14px;',
         "font-family:system-ui,-apple-system,'Segoe UI',Roboto,sans-serif\">",
         paste(tile_html, collapse = ""), '</div>')
}

# Headline counts pulled from a cohort's LOT_LONG view.
query_cohort_kpis <- function(con, lot_long_tbl) {
  row <- tryCatch(db_q(con, glue("
    WITH per_pat AS (
      SELECT PATID,
             min(CASE WHEN LOT_NUM = 1 THEN LOT_START_DT END) AS lot1_dt,
             max(LOT_NUM)                                     AS max_lot,
             max(CASE WHEN LOT_NUM = 1
                       AND LOT_START_TYPE IN ('CART','SCT_CART','CART_INIT')
                      THEN 1 ELSE 0 END)                      AS cart_1l,
             max(CASE WHEN LOT_START_TYPE IN ('CART','SCT_CART','CART_INIT')
                      THEN 1 ELSE 0 END)                      AS cart_any,
             max(CASE WHEN LOT_START_TYPE = 'SCT_ALLO' THEN 1 ELSE 0 END) AS allo_any,
             max(CASE WHEN LOT_START_TYPE = 'SCT_AUTO' THEN 1 ELSE 0 END) AS auto_any
      FROM {lot_long_tbl}
      GROUP BY PATID
    ),
    lot1_len AS (
      SELECT percentile_approx(LOT_BASE_LENGTH, 0.5) AS median_len
      FROM {lot_long_tbl}
      WHERE LOT_NUM = 1 AND LOT_BASE_LENGTH IS NOT NULL
    )
    SELECT
      (SELECT count(*) FROM per_pat)                                      AS n_patients,
      (SELECT count(*) FROM per_pat WHERE max_lot >= 1)                   AS n_lot1,
      (SELECT count(*) FROM per_pat WHERE max_lot >= 2)                   AS n_lot2,
      (SELECT count(*) FROM per_pat WHERE max_lot >= 3)                   AS n_lot3,
      (SELECT count(*) FROM per_pat WHERE cart_any = 1)                   AS n_cart_any,
      (SELECT count(*) FROM per_pat WHERE allo_any = 1)                   AS n_allo_any,
      (SELECT count(*) FROM per_pat WHERE auto_any = 1)                   AS n_auto_any,
      (SELECT min(lot1_dt) FROM per_pat)                                  AS lot1_min,
      (SELECT max(lot1_dt) FROM per_pat)                                  AS lot1_max,
      (SELECT median_len FROM lot1_len)                                   AS lot1_median_len
  ")), error = function(e) NULL)
  if (is.null(row) || nrow(row) == 0) return(list())
  for (col in names(row)) if (inherits(row[[col]], "integer64"))
    row[[col]] <- as.numeric(row[[col]])
  as.list(row[1, , drop = FALSE])
}

build_cohort_kpis <- function(con, lot_long_tbl,
                              section, title = "KPI snapshot") {
  k <- query_cohort_kpis(con, lot_long_tbl)
  if (length(k) == 0 || is.null(k$n_patients) || k$n_patients == 0) {
    add_html_card(paste0(
      '<div style="font-family:system-ui;padding:14px;max-width:900px;',
      'color:#a06000">KPI snapshot unavailable - <code>', lot_long_tbl,
      '</code> returned no rows.</div>'),
      section = section, title = title)
    return(invisible())
  }
  n_pat <- as.numeric(k$n_patients)
  tiles <- list(
    list(label = "Patients (any LOT)", value = fmt_n(n_pat),
         sub = "distinct PATID", accent = "orange"),
    list(label = "Reached LOT1", value = fmt_n(k$n_lot1),
         sub = paste0(fmt_pct(k$n_lot1, n_pat), " of cohort"), accent = "orange"),
    list(label = "Reached LOT2+", value = fmt_n(k$n_lot2),
         sub = paste0(fmt_pct(k$n_lot2, n_pat), " of cohort"), accent = "teal"),
    list(label = "Reached LOT3+", value = fmt_n(k$n_lot3),
         sub = paste0(fmt_pct(k$n_lot3, n_pat), " of cohort"), accent = "teal"),
    list(label = "Median LOT1 length", value = paste0(fmt_n(k$lot1_median_len), " d"),
         sub = "LOT_BASE_LENGTH", accent = "muted"),
    list(label = "Any CAR-T",
         value = paste0(fmt_n(k$n_cart_any), " (", fmt_pct(k$n_cart_any, n_pat), ")"),
         sub = "any LOT_START_TYPE in CART family", accent = "muted"),
    list(label = "Any SCT_AUTO",
         value = paste0(fmt_n(k$n_auto_any), " (", fmt_pct(k$n_auto_any, n_pat), ")"),
         sub = "autologous SCT in any LOT", accent = "muted"),
    list(label = "LOT1 start range",
         value = fmt_date_range(k$lot1_min, k$lot1_max),
         sub = "earliest -> latest", accent = "muted")
  )
  add_html_card(kpi_strip_html(tiles), section = section, title = title)
}

# Build and save the single combined HTML dashboard
# out_name / header_title / header_sub default to the LOT1 (02_lot1.R)
# dashboard so existing callers are unaffected. The LOT1-5 dashboard
# (04_lot_detail_dashboard.R) passes its own values to write a separate file.
# cohort_sections: when set (combined dashboard only), the sidebar shows a
# cohort-pill row built from exactly these section names. Left empty for
# the standalone dashboards, whose sections are functional, not cohorts.
build_dashboard <- function(out_name     = "lot_dashboard.html",
                            header_title = "LOT Part 2 &mdash; Interactive Dashboard",
                            header_sub   = "MMA_MED &bull; MAP &bull; LOT1_BASE &bull; SCT &bull; Patient Journey",
                            cohort_sections = character(0)) {
  if (length(dashboard_items) == 0) {
    log_msg("  Skipping dashboard (no items collected).")
    return(invisible(NULL))
  }
  if (!has_jsonlite || !has_base64enc) {
    log_msg("  Skipping dashboard (jsonlite or base64enc not available).")
    return(invisible(NULL))
  }

  dir.create(cfg$output_dir, showWarnings = FALSE, recursive = TRUE)
  dash_path <- file.path(cfg$output_dir, out_name)

  tryCatch({
    tab_panels    <- list()
    plotly_specs  <- list()   # JSON specs for plotly figures
    sections      <- unique(sapply(dashboard_items, `[[`, "section"))

    for (idx in seq_along(dashboard_items)) {
      item   <- dashboard_items[[idx]]
      tab_id <- paste0("tab", idx)

      if (item$type == "figure") {
        # Plotly figures: extract JSON spec, render client-side with shared plotly.js
        # This avoids pandoc dependency, data URI size limits, and saves ~3MB per figure
        plotly_json <- tryCatch({
          # plotly_build() resolves lazy attrs/visdat into $x$data and merges
          # layoutAttrs into $x$layout.  Without this, raw plot_ly() objects
          # (e.g. Sankey) have no $x$data, and ggplotly layout tweaks added
          # via plotly::layout() sit in $x$layoutAttrs instead of $x$layout,
          # producing blank figures in the dashboard.
          built <- plotly::plotly_build(item$widget)
          jsonlite::toJSON(built$x, auto_unbox = TRUE, force = TRUE, null = "null")
        }, error = function(e) NULL)

        if (!is.null(plotly_json)) {
          div_id <- paste0("plotly_", idx)
          plotly_specs[[div_id]] <- as.character(plotly_json)
          tab_panels[[idx]] <- sprintf(
            '<div id="%s" class="tab-content"><div id="%s" style="width:100%%;min-height:500px;"></div></div>',
            tab_id, div_id
          )
        } else {
          # Fallback: empty panel with error message
          tab_panels[[idx]] <- sprintf(
            '<div id="%s" class="tab-content"><p style="color:#C73E1D;padding:20px;">Figure could not be rendered.</p></div>',
            tab_id
          )
        }
      } else {
        # Tables and HTML cards: base64 data URI iframes (these work fine)
        if (item$type == "html_card") {
          widget_html <- item$html
        } else {
          tmp_file <- tempfile(fileext = ".html")
          htmlwidgets::saveWidget(item$widget, tmp_file, selfcontained = TRUE)
          widget_html <- paste(readLines(tmp_file, warn = FALSE), collapse = "\n")
          unlink(tmp_file)
        }
        encoded <- base64enc::base64encode(charToRaw(widget_html))
        iframe_height <- if (item$type == "table") "600" else "500"
        tab_panels[[idx]] <- sprintf(
          '<div id="%s" class="tab-content"><iframe src="data:text/html;base64,%s" style="width:100%%;height:%spx;border:none;" sandbox="allow-scripts allow-same-origin allow-downloads" onload="resizeIframe(this)"></iframe></div>',
          tab_id, encoded, iframe_height
        )
      }
    }

    # Category-grouped navigation model: [{section, items:[{id,title}]}].
    # Rendered as two dropdowns (Category -> View) instead of a flat tab
    # list, which scales when a dashboard has many figures.
    nav_list <- lapply(sections, function(s) {
      idxs <- which(vapply(dashboard_items,
                           function(it) identical(it$section, s), logical(1)))
      list(
        section = s,
        items = lapply(idxs, function(i)
          list(id = paste0("tab", i), title = dashboard_items[[i]]$title))
      )
    })
    nav_json <- paste0("var NAV = ",
      jsonlite::toJSON(nav_list, auto_unbox = TRUE, force = TRUE), ";")

    # Explicit cohort-pill list (combined dashboard only). Restricted to
    # sections that actually exist so a typo can't produce an empty pill.
    cohort_present <- intersect(cohort_sections, sections)
    cohort_json <- paste0("var COHORT_SECTIONS = ",
      jsonlite::toJSON(as.character(cohort_present), force = TRUE), ";")

    # Build plotly specs as a single JSON object keyed by div id
    plotly_specs_json <- paste0("var PLOTLY_SPECS = {\n",
      paste(sapply(names(plotly_specs), function(div_id) {
        sprintf('  "%s": %s', div_id, plotly_specs[[div_id]])
      }), collapse = ",\n"),
    "\n};")

    # Bundle plotly.js from the installed R package (no CDN / no internet needed)
    plotly_js_code <- ""
    if (length(plotly_specs) > 0) {
      plotly_js_files <- list.files(
        system.file("htmlwidgets/lib", package = "plotly"),
        pattern = "plotly[^/]*\\.min\\.js$",
        recursive = TRUE, full.names = TRUE
      )
      if (length(plotly_js_files) == 0) {
        # Fallback: try non-minified
        plotly_js_files <- list.files(
          system.file("htmlwidgets/lib", package = "plotly"),
          pattern = "plotly[^/]*\\.js$",
          recursive = TRUE, full.names = TRUE
        )
      }
      if (length(plotly_js_files) > 0) {
        plotly_js_code <- paste(readLines(plotly_js_files[1], warn = FALSE), collapse = "\n")
        log_msg("  Bundled plotly.js from: ", plotly_js_files[1],
                " (", round(file.size(plotly_js_files[1]) / 1e6, 1), " MB)")
      } else {
        log_msg("  WARNING: Could not find plotly.js in installed package. Figures may not render.")
      }
    }
    plotly_script_tag <- if (nchar(plotly_js_code) > 0) {
      paste0("<script>", plotly_js_code, "</script>")
    } else ""

    html_doc <- paste0('<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>', header_title, '</title>
', plotly_script_tag, '
<style>
  /* GSK-style palette: orange + white (not orange + dark). Drop exact
     brand hexes into :root to retune everything centrally. */
  :root{
    --gsk-orange:#F36633; --gsk-orange-d:#D24E1F; --gsk-orange-l:#FFE6DC;
    --gsk-sidebar:#FFFFFF; --gsk-sidebar-2:#FFF3EE; --gsk-sidebar-h:#F366331A;
    --gsk-sidebar-tx:#33343D; --gsk-sidebar-mut:#7A7F8C; --gsk-sidebar-bd:#EADFD9;
    --bg:#F4F5F7; --card:#FFFFFF; --text:#2A2A33; --muted:#6B7280;
    --border:#E5E7EB; --accent:#0E7C7B;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  html,body { height: 100%; }
  body {
    font-family: "Inter", -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    background: var(--bg); color: var(--text); display: flex;
    -webkit-font-smoothing: antialiased; -moz-osx-font-smoothing: grayscale;
    text-rendering: optimizeLegibility;
  }
  /* DT tables default to a cramped, mismatched stack; force the app font. */
  table.dataTable, .dataTables_wrapper, .dataTables_wrapper input,
  .dataTables_wrapper select, .dataTables_filter, .dataTables_info,
  .dt-buttons .dt-button { font-family: inherit !important; }
  table.dataTable { font-size: 13px; }
  table.dataTable thead th { font-weight: 600; letter-spacing: .01em; }
  table.dataTable td, table.dataTable th { padding: 6px 10px; }
  /* ---- Sidebar (GSK orange + white) ---- */
  .sidebar {
    width: 280px; min-width: 280px; height: 100vh; overflow-y: auto;
    background: var(--gsk-sidebar); color: var(--gsk-sidebar-tx);
    border-right: 1px solid var(--gsk-sidebar-bd);
    position: sticky; top: 0; display: flex; flex-direction: column;
  }
  .sb-brand {
    padding: 20px 18px 16px;
    background: linear-gradient(135deg, var(--gsk-orange) 0%, var(--gsk-orange-d) 100%);
    color: #fff;
  }
  .sb-brand h1 { font-size: 17px; font-weight: 800; line-height: 1.25; }
  .sb-brand p  { font-size: 11px; opacity: 0.95; margin-top: 5px; }
  .sb-search { padding: 12px 14px; }
  .sb-search input {
    width: 100%; padding: 9px 12px; border: 1px solid var(--gsk-sidebar-bd);
    border-radius: 7px; background: var(--gsk-sidebar-2);
    color: var(--gsk-sidebar-tx); font-size: 13px;
  }
  .sb-search input::placeholder { color: var(--gsk-sidebar-mut); }
  .sb-search input:focus { outline: 2px solid var(--gsk-orange); }
  .sb-nav { flex: 1; padding: 4px 8px 24px; }
  .grp-h {
    display: flex; align-items: center; gap: 8px; cursor: pointer;
    padding: 9px 10px; margin-top: 4px; border-radius: 6px;
    font-size: 11px; font-weight: 800; letter-spacing: 0.7px;
    text-transform: uppercase; color: var(--gsk-sidebar-mut); user-select: none;
  }
  .grp-h:hover { background: var(--gsk-sidebar-h); color: var(--gsk-orange-d); }
  .grp-h .caret { transition: transform 0.15s; font-size: 10px; }
  .grp.collapsed .caret { transform: rotate(-90deg); }
  .grp.collapsed .grp-items { display: none; }
  .grp-count {
    margin-left: auto; font-size: 10px;
    background: var(--gsk-orange-l); color: var(--gsk-orange-d);
    padding: 1px 7px; border-radius: 10px; font-weight: 700;
  }
  .grp-items { padding: 2px 0 6px; }
  .nav-item {
    display: block; padding: 7px 12px 7px 28px; font-size: 12.5px;
    color: var(--gsk-sidebar-tx); cursor: pointer; border-radius: 6px;
    border-left: 3px solid transparent; transition: all 0.12s;
  }
  .nav-item:hover { background: var(--gsk-sidebar-h); color: var(--gsk-orange-d); }
  .nav-item.active {
    background: var(--gsk-orange-l); color: var(--gsk-orange-d); font-weight: 700;
    border-left-color: var(--gsk-orange);
  }
  .nav-item.hidden, .grp.hidden { display: none; }
  /* ---- Main ---- */
  .main { flex: 1; min-width: 0; height: 100vh; overflow-y: auto; }
  .topbar {
    position: sticky; top: 0; z-index: 50; background: var(--card);
    border-bottom: 1px solid var(--border);
    display: flex; align-items: center; gap: 12px; padding: 14px 26px;
    box-shadow: 0 1px 3px rgba(0,0,0,0.04);
  }
  .crumb { font-size: 13px; color: var(--muted); }
  .crumb b { color: var(--text); }
  .topbar .spacer { flex: 1; }
  .icon-btn {
    border: 1px solid var(--border); background: var(--card);
    color: var(--muted); border-radius: 7px; padding: 7px 12px;
    font-size: 12px; font-weight: 700; cursor: pointer;
  }
  .icon-btn:hover { border-color: var(--gsk-orange); color: var(--gsk-orange-d); }
  .content { padding: 22px 26px 60px; }
  .card {
    background: var(--card); border: 1px solid var(--border);
    border-radius: 12px; box-shadow: 0 1px 3px rgba(0,0,0,0.05);
    overflow: hidden;
  }
  .tab-content { display: none; animation: fade 0.18s ease; }
  .tab-content.show { display: block; }
  @keyframes fade { from { opacity: 0; transform: translateY(4px); } to { opacity: 1; } }
  .tab-content iframe { border: none; width: 100%; min-height: 500px; display: block; }
  [id^=plotly_] { padding: 10px; }
  .main.fs .topbar { position: fixed; left: 0; right: 0; }
  .main.fs { position: fixed; inset: 0; z-index: 9999; background: var(--bg); }
  .main.fs .content { padding-top: 70px; }
  .sb-foot { padding: 14px; font-size: 10.5px; color: var(--gsk-sidebar-mut); }
  @media (max-width: 820px) {
    body { flex-direction: column; }
    .sidebar { width: 100%; min-width: 0; height: auto; position: static; }
    .main { height: auto; }
  }
  /* ---- Cohort tabs (top of sidebar) ---- */
  .sb-cohorts {
    display: flex; flex-wrap: wrap; gap: 6px;
    padding: 10px 14px 4px; border-bottom: 1px solid var(--gsk-sidebar-bd);
  }
  .sb-cohorts.hidden { display: none; }
  .ct-btn {
    flex: 1 1 30%; padding: 7px 10px; font-size: 12px; font-weight: 700;
    border: 1px solid var(--gsk-sidebar-bd); border-radius: 6px;
    background: var(--gsk-sidebar-2); color: var(--gsk-sidebar-tx);
    cursor: pointer; text-align: center; transition: all 0.12s;
  }
  .ct-btn:hover { border-color: var(--gsk-orange); color: var(--gsk-orange-d); }
  .ct-btn.active {
    background: var(--gsk-orange); color: #fff;
    border-color: var(--gsk-orange-d);
  }
  /* KPI tiles and code tooltips are styled inline (they live inside
     sandboxed iframes, so parent CSS would not reach them). */
</style>
</head>
<body>
<aside class="sidebar">
  <div class="sb-brand">
    <h1>', header_title, '</h1>
    <p>', header_sub, '</p>
  </div>
  <div class="sb-cohorts hidden" id="sbCohorts"></div>
  <div class="sb-search">
    <input id="navSearch" type="text" placeholder="Search views    ( / )" autocomplete="off">
  </div>
  <nav class="sb-nav" id="sbNav"></nav>
  <div class="sb-foot">Generated ', format(Sys.time(), "%Y-%m-%d %H:%M"), '</div>
</aside>
<div class="main" id="main">
  <div class="topbar">
    <div class="crumb"><b id="cbCat">--</b> &nbsp;/&nbsp; <span id="cbView">--</span></div>
    <div class="spacer"></div>
    <button class="icon-btn" id="prevBtn" title="Previous (Left arrow)">&#8592; Prev</button>
    <button class="icon-btn" id="nextBtn" title="Next (Right arrow)">Next &#8594;</button>
    <button class="icon-btn" id="fsBtn" title="Toggle fullscreen (F)">&#9974; Fullscreen</button>
  </div>
  <div class="content">
    <div class="card">
', paste(tab_panels, collapse = "\n"), '
    </div>
  </div>
</div>
<script>
function resizeIframe(iframe) {
  try { iframe.style.height = iframe.contentWindow.document.body.scrollHeight + 40 + "px"; } catch(e) {}
  setTimeout(function() {
    try { iframe.style.height = iframe.contentWindow.document.body.scrollHeight + 40 + "px"; } catch(e) {}
  }, 800);
  setTimeout(function() {
    try { iframe.style.height = iframe.contentWindow.document.body.scrollHeight + 40 + "px"; } catch(e) {}
  }, 2000);
}
var renderedPlots = {};
function renderPlotlyIfVisible(divId) {
  // Fail gracefully if plotly.js was not bundled (R side already logs
  // "figures may not render"); never throw a ReferenceError.
  if (typeof Plotly === "undefined") return;
  if (renderedPlots[divId]) { Plotly.Plots.resize(divId); return; }
  var el = document.getElementById(divId);
  if (!el || el.offsetParent === null) return;
  var spec = PLOTLY_SPECS[divId];
  if (spec) {
    Plotly.newPlot(divId, spec.data || [], spec.layout || {}, spec.config || {displayModeBar:true,displaylogo:false});
    renderedPlots[divId] = true;
  }
}
// Flat ordered list of all views for prev/next + search + hash.
// Populated in buildFlat() AFTER `var NAV` is assigned (NAV is defined
// near the end of this script, so it must not be read at parse time).
var FLAT = [];
function buildFlat() {
  FLAT = [];
  NAV.forEach(function(g){ g.items.forEach(function(it){
    FLAT.push({ id: it.id, title: it.title, section: g.section });
  }); });
}
var curId = null;
function openView(id, push) {
  var rec = FLAT.filter(function(f){ return f.id === id; })[0];
  if (!rec) return;
  curId = id;
  document.querySelectorAll(".tab-content").forEach(function(el){ el.classList.remove("show"); });
  var t = document.getElementById(id);
  if (t) t.classList.add("show");
  document.querySelectorAll(".nav-item").forEach(function(el){
    el.classList.toggle("active", el.getAttribute("data-id") === id);
  });
  document.getElementById("cbCat").textContent  = rec.section;
  document.getElementById("cbView").textContent = rec.title;
  var plotDiv = t ? t.querySelector("[id^=plotly_]") : null;
  if (plotDiv) setTimeout(function(){ renderPlotlyIfVisible(plotDiv.id); }, 80);
  var iframe = t ? t.querySelector("iframe") : null;
  if (iframe) setTimeout(function(){ resizeIframe(iframe); }, 250);
  var act = document.querySelector(".nav-item.active");
  if (act) { var grp = act.closest(".grp"); if (grp) grp.classList.remove("collapsed"); }
  if (push !== false) { try { history.replaceState(null,"","#"+id); } catch(e){} }
}
function buildNav() {
  var nav = document.getElementById("sbNav");
  NAV.forEach(function(g, gi){
    var grp = document.createElement("div");
    grp.className = "grp" + (gi === 0 ? "" : " collapsed");
    var h = document.createElement("div");
    h.className = "grp-h";
    h.innerHTML = "<span class=\\"caret\\">&#9660;</span><span>" + g.section +
      "</span><span class=\\"grp-count\\">" + g.items.length + "</span>";
    h.addEventListener("click", function(){ grp.classList.toggle("collapsed"); });
    grp.appendChild(h);
    var box = document.createElement("div");
    box.className = "grp-items";
    g.items.forEach(function(it){
      var a = document.createElement("div");
      a.className = "nav-item"; a.setAttribute("data-id", it.id);
      a.setAttribute("data-t", (g.section + " " + it.title).toLowerCase());
      a.textContent = it.title;
      a.addEventListener("click", function(){ openView(it.id); });
      box.appendChild(a);
    });
    grp.appendChild(box);
    nav.appendChild(grp);
  });
}
function applySearch(q) {
  q = (q || "").trim().toLowerCase();
  document.querySelectorAll(".grp").forEach(function(grp){
    // Respect the active cohort pill (combined dashboard): groups outside
    // the selected cohort stay hidden even when the search matches an item.
    var ch = grp.querySelector(".grp-h span:nth-child(2)");
    var inCohort = !curCohort || !ch || ch.textContent === curCohort;
    var any = false;
    grp.querySelectorAll(".nav-item").forEach(function(a){
      var hit = inCohort && (!q || a.getAttribute("data-t").indexOf(q) !== -1);
      a.classList.toggle("hidden", !hit);
      if (hit) any = true;
    });
    grp.classList.toggle("hidden", !any);
    if (q && any) grp.classList.remove("collapsed");
  });
}
// Currently navigable views in DOM order: when a search filter is
// active, only the visible (non-hidden) items; otherwise all of them.
// Collapsed-but-not-hidden groups are still included (openView expands
// the target group), so collapse is purely cosmetic for prev/next.
function visibleIds() {
  var out = [];
  document.querySelectorAll(".grp:not(.hidden) .nav-item:not(.hidden)")
    .forEach(function(a){ out.push(a.getAttribute("data-id")); });
  // When a cohort is selected, never fall back to the full FLAT list - that
  // would let arrow nav jump into other cohorts on a no-results search.
  return out.length ? out : (curCohort ? out : FLAT.map(function(f){ return f.id; }));
}
function step(delta) {
  var ids = visibleIds();
  if (!ids.length) return;
  var i = ids.indexOf(curId);
  if (i === -1) i = (delta > 0 ? -1 : 0);  // current filtered out -> jump to an edge
  i = (i + delta + ids.length) % ids.length;
  openView(ids[i]);
  var el = document.querySelector(".nav-item.active");
  if (el) el.scrollIntoView({block:"nearest"});
}
function toggleFs() {
  var m = document.getElementById("main");
  m.classList.toggle("fs");
  if (curId) {
    var t = document.getElementById(curId);
    var p = t ? t.querySelector("[id^=plotly_]") : null;
    if (p && window.Plotly) setTimeout(function(){ Plotly.Plots.resize(p.id); }, 120);
    var f = t ? t.querySelector("iframe") : null;
    if (f) setTimeout(function(){ resizeIframe(f); }, 200);
  }
}
// ---- Cohort tabs ---------------------------------------------------
// COHORTS comes from COHORT_SECTIONS, an explicit list emitted by R
// (build_dashboard(cohort_sections=...)). Only the combined dashboard
// passes it, so standalone 04/05/06 show no cohort pills - their NAV
// sections are functional (FUNNEL, START_TYPE, ...), not cohorts.
// Read inside buildCohortTabs(): COHORT_SECTIONS is assigned near the
// end of this script (like NAV), so it must not be read at parse time.
var COHORTS = [];
var curCohort = null;
function buildCohortTabs() {
  COHORTS = (typeof COHORT_SECTIONS !== "undefined" && COHORT_SECTIONS) ?
            COHORT_SECTIONS : [];
  if (COHORTS.length < 2) return;
  var bar = document.getElementById("sbCohorts");
  bar.classList.remove("hidden");
  COHORTS.forEach(function(name){
    var b = document.createElement("button");
    b.className = "ct-btn"; b.type = "button";
    b.setAttribute("data-cohort", name);
    b.textContent = name;
    b.addEventListener("click", function(){ setCohort(name, true); });
    bar.appendChild(b);
  });
}
function setCohort(name, jump) {
  curCohort = name;
  document.querySelectorAll(".ct-btn").forEach(function(b){
    b.classList.toggle("active", b.getAttribute("data-cohort") === name);
  });
  document.querySelectorAll(".grp").forEach(function(g){
    var h = g.querySelector(".grp-h span:nth-child(2)");
    var s = h ? h.textContent : "";
    g.classList.toggle("hidden", s !== name);
    if (s === name) g.classList.remove("collapsed");
  });
  // Re-apply any active search against the newly-selected cohort so nav
  // items keep a correct shown/hidden state instead of one from the prior cohort.
  var sbx = document.getElementById("navSearch");
  if (sbx) applySearch(sbx.value);
  if (jump) {
    var first = document.querySelector(".grp:not(.hidden) .nav-item:not(.hidden)");
    if (first) {
      openView(first.getAttribute("data-id"));
    } else {
      // No views match in this cohort (e.g. active search with zero hits):
      // clear the stale view so the main panel does not keep prior content.
      document.querySelectorAll(".tab-content").forEach(function(el){ el.classList.remove("show"); });
      document.querySelectorAll(".nav-item.active").forEach(function(el){ el.classList.remove("active"); });
      curId = null;
      var cbc = document.getElementById("cbCat"), cbv = document.getElementById("cbView");
      if (cbc) cbc.textContent = name;
      if (cbv) cbv.textContent = "no matching views - clear the search";
    }
  }
}
// Acronym tooltips are applied R-side at card-build time (inject_tooltips
// in dashboard_lot.R) so they work inside the sandboxed card iframes;
// no client-side dictionary is needed here.
document.addEventListener("DOMContentLoaded", function(){
  buildFlat();
  buildNav();
  buildCohortTabs();
  document.getElementById("prevBtn").addEventListener("click", function(){ step(-1); });
  document.getElementById("nextBtn").addEventListener("click", function(){ step(1); });
  document.getElementById("fsBtn").addEventListener("click", toggleFs);
  var sb = document.getElementById("navSearch");
  sb.addEventListener("input", function(){ applySearch(sb.value); });
  document.addEventListener("keydown", function(e){
    var typing = /^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement.tagName);
    if (e.key === "/" && !typing) { e.preventDefault(); sb.focus(); return; }
    if (typing) { if (e.key === "Escape") { sb.value=""; applySearch(""); sb.blur(); } return; }
    if (e.key === "ArrowRight") step(1);
    else if (e.key === "ArrowLeft") step(-1);
    else if (e.key === "f" || e.key === "F") toggleFs();
    else if (e.key === "Escape" && document.getElementById("main").classList.contains("fs")) toggleFs();
  });
  window.addEventListener("hashchange", function(){
    var h = location.hash.replace("#","");
    if (h && h !== curId) openView(h, false);
  });
  var h0 = location.hash.replace("#","");
  var start = (h0 && FLAT.filter(function(f){return f.id===h0;}).length) ? h0
              : (FLAT[0] ? FLAT[0].id : null);
  if (start) {
    openView(start, false);
    var rec = FLAT.filter(function(f){return f.id===start;})[0];
    if (rec && COHORTS.indexOf(rec.section) !== -1) setCohort(rec.section, false);
  }
});
// Category-grouped nav model
', nav_json, '
// Cohort-pill list (combined dashboard only; empty for standalone)
', cohort_json, '
// Plotly figure specs - all figures share one copy of plotly.js
', plotly_specs_json, '
</script>
</body>
</html>')

    writeLines(html_doc, dash_path)
    log_msg("  Dashboard saved: ", dash_path)

  }, error = function(e) {
    log_msg("  WARNING: Could not build dashboard: ", conditionMessage(e))
  })
}
