# ============================================================
# dashboard_lot.R — Visualization helpers + dashboard builder
# ============================================================
# Extracted from lot_program.R during modularization.
# Contains: package checks, palettes, theme, save helpers,
#           dashboard collector, and build_dashboard() HTML generator.
# Requires: cfg (from config_lot.R), log_msg (from db_utils_lot.R)
# ============================================================

has_ggplot2 <- requireNamespace("ggplot2", quietly = TRUE)
has_plotly  <- requireNamespace("plotly", quietly = TRUE) &&
               requireNamespace("htmlwidgets", quietly = TRUE)
has_dt      <- requireNamespace("DT", quietly = TRUE)
has_jsonlite  <- requireNamespace("jsonlite", quietly = TRUE)
has_base64enc <- requireNamespace("base64enc", quietly = TRUE)
if (has_ggplot2) {
  suppressPackageStartupMessages(library(ggplot2))
}

# ---- Dashboard collector: accumulates widgets for the combined HTML ----
dashboard_items <- list()

add_to_dashboard <- function(widget, section, title, type = "figure") {
  dashboard_items[[length(dashboard_items) + 1]] <<- list(
    widget = widget, section = section, title = title, type = type
  )
}

# ---- Shared visual theme and palette ----
lot_class_palette <- c(
  "IMMUNOMOD"  = "#2E86AB",
  "PROTINHIB"  = "#A23B72",
  "MUSTARD"    = "#F18F01",
  "ACD38"      = "#C73E1D",
  "STEROID"    = "#44BBA4",
  "ABCMA"      = "#8D5A97",
  "ASLAMF7"    = "#3F88C5",
  "MELP"       = "#3B1F2B",
  "TOPOINHIB"  = "#E94F37",
  "HIST"       = "#5FAD56",
  "NUCLEAR"    = "#F49D37",
  "BLC21"      = "#D72638",
  "ATCELL"     = "#F2D0A4",
  "UNV"        = "#140F2D",
  "PLAT"       = "#393E41"
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
  out_path <- file.path(cfg$output_dir, filename)
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

# Collect a data table for the dashboard (DT does NOT require plotly)
save_table <- function(df, section, title) {
  if (!isTRUE(cfg$build_dashboard)) return(invisible(NULL))
  if (!has_dt || !requireNamespace("htmlwidgets", quietly = TRUE)) return(invisible(NULL))
  tryCatch({
    # Convert integer64 columns for display
    for (col in names(df)) {
      if (inherits(df[[col]], "integer64")) df[[col]] <- as.numeric(df[[col]])
    }
    dt <- DT::datatable(df, rownames = FALSE,
                         options = list(pageLength = 15, scrollX = TRUE,
                                        dom = "ftip"),
                         class = "display compact stripe hover")
    add_to_dashboard(dt, section, title, type = "table")
  }, error = function(e) {
    log_msg("  WARNING: Could not create table for dashboard: ", e$message)
  })
}

# Add a raw HTML card to the dashboard (for overview/QC — no htmlwidget needed)
add_html_card <- function(html_content, section, title) {
  if (!isTRUE(cfg$build_dashboard)) return(invisible(NULL))
  dashboard_items[[length(dashboard_items) + 1]] <<- list(
    html = html_content, section = section, title = title, type = "html_card"
  )
}

# Build and save the single combined HTML dashboard
# out_name / header_title / header_sub default to the LOT1 (lot_program.R)
# dashboard so existing callers are unaffected. The LOT1-5 dashboard
# (lot_long_dashboard.R) passes its own values to write a separate file.
build_dashboard <- function(out_name     = "lot_dashboard.html",
                            header_title = "LOT Part 2 &mdash; Interactive Dashboard",
                            header_sub   = "MMA_MED &bull; MAP &bull; LOT1_BASE &bull; SCT &bull; Patient Journey") {
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
            '<div id="%s" class="tab-content" style="display:%s"><div id="%s" style="width:100%%;min-height:500px;"></div></div>',
            tab_id, if (idx == 1) "block" else "none", div_id
          )
        } else {
          # Fallback: empty panel with error message
          tab_panels[[idx]] <- sprintf(
            '<div id="%s" class="tab-content" style="display:%s"><p style="color:#C73E1D;padding:20px;">Figure could not be rendered.</p></div>',
            tab_id, if (idx == 1) "block" else "none"
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
          '<div id="%s" class="tab-content" style="display:%s"><iframe src="data:text/html;base64,%s" style="width:100%%;height:%spx;border:none;" sandbox="allow-scripts allow-same-origin" onload="resizeIframe(this)"></iframe></div>',
          tab_id, if (idx == 1) "block" else "none", encoded, iframe_height
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
<title>LOT Part 2 - Interactive Dashboard</title>
', plotly_script_tag, '
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    background: #f5f6fa; color: #2d3436;
  }
  .header {
    background: linear-gradient(135deg, #2E86AB 0%, #1a5276 100%);
    color: white; padding: 28px 32px;
    box-shadow: 0 2px 8px rgba(0,0,0,0.15);
  }
  .header h1 { font-size: 26px; font-weight: 700; margin-bottom: 6px; }
  .header p  { font-size: 14px; opacity: 0.85; }
  .nav-bar {
    position: sticky; top: 0; z-index: 100;
    background: white; box-shadow: 0 1px 3px rgba(0,0,0,0.06);
    display: flex; flex-wrap: wrap; align-items: center; gap: 10px 24px;
    padding: 14px 32px; border-bottom: 1px solid #dfe6e9;
  }
  .nav-group { display: flex; align-items: center; gap: 8px; }
  .nav-group label {
    font-size: 11px; font-weight: 700; text-transform: uppercase;
    letter-spacing: 0.6px; color: #636e72;
  }
  .nav-bar select {
    padding: 8px 30px 8px 12px; border: 1px solid #cdd6db;
    border-radius: 6px; background: #f5f6fa; color: #2d3436;
    font-size: 13px; font-weight: 600; cursor: pointer;
    min-width: 200px; appearance: none;
    background-image: url("data:image/svg+xml;charset=US-ASCII,%3Csvg%20xmlns%3D%27http%3A%2F%2Fwww.w3.org%2F2000%2Fsvg%27%20width%3D%2710%27%20height%3D%276%27%3E%3Cpath%20d%3D%27M0%200l5%206%205-6z%27%20fill%3D%27%23636e72%27%2F%3E%3C%2Fsvg%3E");
    background-repeat: no-repeat; background-position: right 12px center;
  }
  .nav-bar select:hover { border-color: #2E86AB; }
  .nav-bar select:focus { outline: 2px solid #2E86AB33; border-color: #2E86AB; }
  #catSelect { font-weight: 700; }
  .tab-content { padding: 16px 32px; }
  .tab-content iframe { border: none; width: 100%; min-height: 500px; }
</style>
</head>
<body>
<div class="header">
  <h1>', header_title, '</h1>
  <p>', header_sub, ' &nbsp;|&nbsp; Generated ', format(Sys.time(), "%Y-%m-%d %H:%M"), '</p>
</div>
<div class="nav-bar">
  <div class="nav-group">
    <label for="catSelect">Category</label>
    <select id="catSelect" onchange="onCatChange()"></select>
  </div>
  <div class="nav-group">
    <label for="itemSelect">View</label>
    <select id="itemSelect" onchange="onItemChange()"></select>
  </div>
</div>
', paste(tab_panels, collapse = "\n"), '
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
// Track which plotly divs have been rendered
var renderedPlots = {};
function renderPlotlyIfVisible(divId) {
  if (renderedPlots[divId]) {
    Plotly.Plots.resize(divId);
    return;
  }
  var el = document.getElementById(divId);
  if (!el || el.offsetParent === null) return;
  var spec = PLOTLY_SPECS[divId];
  if (spec) {
    Plotly.newPlot(divId, spec.data || [], spec.layout || {}, spec.config || {displayModeBar:true,displaylogo:false});
    renderedPlots[divId] = true;
  }
}
function showItem(tabId) {
  document.querySelectorAll(".tab-content").forEach(function(el) { el.style.display = "none"; });
  var t = document.getElementById(tabId);
  if (!t) return;
  t.style.display = "block";
  var plotDiv = t.querySelector("[id^=plotly_]");
  if (plotDiv) { setTimeout(function() { renderPlotlyIfVisible(plotDiv.id); }, 100); }
  var iframe = t.querySelector("iframe");
  if (iframe) { setTimeout(function() { resizeIframe(iframe); }, 300); }
}
function onItemChange() {
  var sel = document.getElementById("itemSelect");
  if (sel && sel.value) showItem(sel.value);
}
function onCatChange() {
  var cat = +document.getElementById("catSelect").value;
  var is  = document.getElementById("itemSelect");
  is.innerHTML = "";
  (NAV[cat] ? NAV[cat].items : []).forEach(function(it) {
    var o = document.createElement("option");
    o.value = it.id; o.text = it.title;
    is.add(o);
  });
  onItemChange();
}
function buildNav() {
  var cs = document.getElementById("catSelect");
  NAV.forEach(function(g, i) {
    var o = document.createElement("option");
    o.value = i;
    o.text = g.section + "  (" + g.items.length + ")";
    cs.add(o);
  });
  onCatChange();
}
// Category-grouped nav model
', nav_json, '
// Plotly figure specs — all figures share one copy of plotly.js
', plotly_specs_json, '
document.addEventListener("DOMContentLoaded", function() { buildNav(); });
</script>
</body>
</html>')

    writeLines(html_doc, dash_path)
    log_msg("  Dashboard saved: ", dash_path)

  }, error = function(e) {
    log_msg("  WARNING: Could not build dashboard: ", conditionMessage(e))
  })
}
