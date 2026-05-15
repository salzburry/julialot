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
    tab_buttons   <- list()
    tab_panels    <- list()
    plotly_specs  <- list()   # JSON specs for plotly figures
    sections      <- unique(sapply(dashboard_items, `[[`, "section"))

    for (idx in seq_along(dashboard_items)) {
      item   <- dashboard_items[[idx]]
      tab_id <- paste0("tab", idx)

      active_class <- if (idx == 1) "active" else ""
      section_tag  <- paste0('<span class="section-tag">', item$section, '</span> ')
      tab_buttons[[idx]] <- sprintf(
        '<button class="tab-btn %s" onclick="showTab(\'%s\', this)" data-section="%s">%s%s</button>',
        active_class, tab_id, item$section, section_tag, item$title
      )

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

    # Build section filter buttons
    section_filters <- paste0(
      '<button class="filter-btn active" onclick="filterSection(\'ALL\', this)">All</button>\n',
      paste(sprintf(
        '<button class="filter-btn" onclick="filterSection(\'%s\', this)">%s</button>',
        sections, sections
      ), collapse = "\n")
    )

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
  }
  .filter-bar {
    display: flex; flex-wrap: wrap; gap: 4px; padding: 10px 32px;
    border-bottom: 1px solid #eee; background: #fafafa;
  }
  .filter-btn {
    padding: 5px 14px; border: 1px solid #dfe6e9; border-radius: 20px;
    background: white; color: #636e72; cursor: pointer;
    font-size: 12px; font-weight: 600; text-transform: uppercase;
    letter-spacing: 0.5px; transition: all 0.15s;
  }
  .filter-btn:hover { background: #dfe6e9; }
  .filter-btn.active { background: #1a5276; color: white; border-color: #1a5276; }
  .tab-bar {
    display: flex; flex-wrap: wrap; gap: 6px;
    padding: 10px 32px;
    border-bottom: 1px solid #dfe6e9;
  }
  .tab-btn {
    padding: 8px 14px; border: 1px solid #dfe6e9; border-radius: 6px;
    background: #f5f6fa; color: #636e72; cursor: pointer;
    font-size: 12.5px; font-weight: 500; transition: all 0.15s;
    display: inline-flex; align-items: center; gap: 4px;
  }
  .tab-btn:hover { background: #dfe6e9; color: #2d3436; }
  .tab-btn.active { background: #2E86AB; color: white; border-color: #2E86AB; }
  .tab-btn.active .section-tag { background: rgba(255,255,255,0.25); color: white; }
  .tab-btn.hidden { display: none; }
  .section-tag {
    font-size: 10px; font-weight: 700; text-transform: uppercase;
    background: #dfe6e9; color: #636e72; padding: 2px 6px;
    border-radius: 3px; letter-spacing: 0.5px;
  }
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
<div class="filter-bar">
', section_filters, '
</div>
<div class="tab-bar">
', paste(tab_buttons, collapse = "\n"), '
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
function showTab(tabId, btn) {
  document.querySelectorAll(".tab-content").forEach(function(el) { el.style.display = "none"; });
  document.querySelectorAll(".tab-btn").forEach(function(el) { el.classList.remove("active"); });
  document.getElementById(tabId).style.display = "block";
  btn.classList.add("active");
  // Render/resize plotly if this tab has one
  var plotDiv = document.querySelector("#" + tabId + " [id^=plotly_]");
  if (plotDiv) {
    setTimeout(function() { renderPlotlyIfVisible(plotDiv.id); }, 100);
  }
  // Resize iframes
  var iframe = document.querySelector("#" + tabId + " iframe");
  if (iframe) { setTimeout(function() { resizeIframe(iframe); }, 300); }
}
function filterSection(section, btn) {
  document.querySelectorAll(".filter-btn").forEach(function(el) { el.classList.remove("active"); });
  btn.classList.add("active");
  document.querySelectorAll(".tab-btn").forEach(function(el) {
    if (section === "ALL" || el.getAttribute("data-section") === section) {
      el.classList.remove("hidden");
    } else {
      el.classList.add("hidden");
    }
  });
  var activeTab = document.querySelector(".tab-btn.active");
  if (activeTab && activeTab.classList.contains("hidden")) {
    var firstVisible = document.querySelector(".tab-btn:not(.hidden)");
    if (firstVisible) firstVisible.click();
  }
}
// Plotly figure specs — all figures share one copy of plotly.js
', plotly_specs_json, '
// Render the first visible plotly chart on load
document.addEventListener("DOMContentLoaded", function() {
  var firstPlot = document.querySelector(".tab-content[style*=block] [id^=plotly_]");
  if (firstPlot) { setTimeout(function() { renderPlotlyIfVisible(firstPlot.id); }, 200); }
});
</script>
</body>
</html>')

    writeLines(html_doc, dash_path)
    log_msg("  Dashboard saved: ", dash_path)

  }, error = function(e) {
    log_msg("  WARNING: Could not build dashboard: ", conditionMessage(e))
  })
}
