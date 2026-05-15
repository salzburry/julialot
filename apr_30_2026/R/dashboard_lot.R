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
          '<div id="%s" class="tab-content"><iframe src="data:text/html;base64,%s" style="width:100%%;height:%spx;border:none;" sandbox="allow-scripts allow-same-origin" onload="resizeIframe(this)"></iframe></div>',
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
  /* GSK-style palette. These approximate the GSK brand; drop exact
     brand hexes into :root to retune everything centrally. */
  :root{
    --gsk-orange:#F36633; --gsk-orange-d:#D24E1F; --gsk-orange-l:#FFE6DC;
    --gsk-sidebar:#20232E; --gsk-sidebar-2:#2B3040; --gsk-sidebar-h:#39405440;
    --bg:#F4F5F7; --card:#FFFFFF; --text:#2A2A33; --muted:#6B7280;
    --border:#E5E7EB; --accent:#0E7C7B;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  html,body { height: 100%; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    background: var(--bg); color: var(--text); display: flex;
  }
  /* ---- Sidebar ---- */
  .sidebar {
    width: 280px; min-width: 280px; height: 100vh; overflow-y: auto;
    background: var(--gsk-sidebar); color: #E8EAF0;
    position: sticky; top: 0; display: flex; flex-direction: column;
  }
  .sb-brand {
    padding: 20px 18px 16px; border-bottom: 1px solid #ffffff14;
    background: linear-gradient(135deg, var(--gsk-orange) 0%, var(--gsk-orange-d) 100%);
    color: #fff;
  }
  .sb-brand h1 { font-size: 17px; font-weight: 800; line-height: 1.25; }
  .sb-brand p  { font-size: 11px; opacity: 0.92; margin-top: 5px; }
  .sb-search { padding: 12px 14px; }
  .sb-search input {
    width: 100%; padding: 9px 12px; border: 0; border-radius: 7px;
    background: var(--gsk-sidebar-2); color: #fff; font-size: 13px;
  }
  .sb-search input::placeholder { color: #9aa1b3; }
  .sb-search input:focus { outline: 2px solid var(--gsk-orange); }
  .sb-nav { flex: 1; padding: 4px 8px 24px; }
  .grp-h {
    display: flex; align-items: center; gap: 8px; cursor: pointer;
    padding: 9px 10px; margin-top: 4px; border-radius: 6px;
    font-size: 11px; font-weight: 800; letter-spacing: 0.7px;
    text-transform: uppercase; color: #aab0c2; user-select: none;
  }
  .grp-h:hover { background: var(--gsk-sidebar-h); color: #fff; }
  .grp-h .caret { transition: transform 0.15s; font-size: 10px; }
  .grp.collapsed .caret { transform: rotate(-90deg); }
  .grp.collapsed .grp-items { display: none; }
  .grp-count {
    margin-left: auto; font-size: 10px; background: #ffffff1f;
    padding: 1px 7px; border-radius: 10px; font-weight: 700;
  }
  .grp-items { padding: 2px 0 6px; }
  .nav-item {
    display: block; padding: 7px 12px 7px 28px; font-size: 12.5px;
    color: #c7cbd8; cursor: pointer; border-radius: 6px;
    border-left: 3px solid transparent; transition: all 0.12s;
  }
  .nav-item:hover { background: var(--gsk-sidebar-h); color: #fff; }
  .nav-item.active {
    background: #ffffff10; color: #fff; font-weight: 700;
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
  .sb-foot { padding: 14px; font-size: 10.5px; color: #7a8095; }
  @media (max-width: 820px) {
    body { flex-direction: column; }
    .sidebar { width: 100%; min-width: 0; height: auto; position: static; }
    .main { height: auto; }
  }
</style>
</head>
<body>
<aside class="sidebar">
  <div class="sb-brand">
    <h1>', header_title, '</h1>
    <p>', header_sub, '</p>
  </div>
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
    var any = false;
    grp.querySelectorAll(".nav-item").forEach(function(a){
      var hit = !q || a.getAttribute("data-t").indexOf(q) !== -1;
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
  return out.length ? out : FLAT.map(function(f){ return f.id; });
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
document.addEventListener("DOMContentLoaded", function(){
  buildFlat();
  buildNav();
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
  if (start) openView(start, false);
});
// Category-grouped nav model
', nav_json, '
// Plotly figure specs — all figures share one copy of plotly.js
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
