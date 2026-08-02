# One self-contained HTML file, built from base R only.
#
# apr_30_2026's dashboard machinery renders through ggplot2, plotly, DT,
# htmlwidgets, jsonlite and base64enc, and no-ops when any of them is missing:
# build_dashboard() logs "skipping" and writes nothing. That is the wrong
# failure for a deliverable - a run that reports complete and produces no
# dashboard looks the same as a run nobody asked for one from. None of those
# packages is guaranteed on the Domino image, and a dashboard is worth less than
# the tables it describes, so it is not worth making the run depend on them.
#
# So: tables, KPI tiles and bars drawn as styled divs. No script tag, no CDN, no
# plotting package. The output opens from a file:// path with nothing installed,
# which is also what makes it easy to attach to an email.

.h <- function(x) {
  x <- as.character(x)
  x[is.na(x)] <- ""
  x <- gsub("&", "&amp;", x, fixed = TRUE)
  x <- gsub("<", "&lt;",  x, fixed = TRUE)
  x <- gsub(">", "&gt;",  x, fixed = TRUE)
  gsub('"', "&quot;", x, fixed = TRUE)
}

# Thousands separators on whole numbers, and the value itself on anything else.
# A count is easier to read grouped and a median of 1.5 is not.
.fmt <- function(v) {
  if (is.numeric(v))
    return(ifelse(is.na(v), "",
                  ifelse(v == round(v) & abs(v) >= 1000,
                         format(v, big.mark = ",", scientific = FALSE, trim = TRUE),
                         format(v, scientific = FALSE, trim = TRUE))))
  as.character(v)
}

render_table <- function(df) {
  if (is.null(df) || !nrow(df))
    return('<p class="empty">No rows.</p>')
  head <- paste0("<th>", .h(names(df)), "</th>", collapse = "")
  body <- vapply(seq_len(nrow(df)), function(i) {
    cells <- vapply(seq_along(df), function(j) {
      v <- df[[j]][i]
      cls <- if (is.numeric(df[[j]])) ' class="num"' else ""
      paste0("<td", cls, ">", .h(.fmt(v)), "</td>")
    }, character(1))
    paste0("<tr>", paste(cells, collapse = ""), "</tr>")
  }, character(1))
  paste0('<div class="scroll"><table><thead><tr>', head, "</tr></thead><tbody>",
         paste(body, collapse = ""), "</tbody></table></div>")
}

# One row of big numbers. The section's SQL returns a single row and every
# column becomes a tile, so the SQL decides what is on the strip.
render_kpi <- function(df) {
  if (is.null(df) || !nrow(df))
    return('<p class="empty">No rows.</p>')
  tiles <- vapply(seq_along(df), function(j)
    paste0('<div class="kpi"><div class="kpi-n">', .h(.fmt(df[[j]][1])),
           '</div><div class="kpi-l">', .h(names(df)[j]), "</div></div>"),
    character(1))
  paste0('<div class="kpis">', paste(tiles, collapse = ""), "</div>")
}

# A bar per row, width proportional to the largest. Needs `label` and `n`.
render_bar <- function(df) {
  if (is.null(df) || !nrow(df))
    return('<p class="empty">No rows.</p>')
  if (!all(c("label", "n") %in% names(df)))
    return(render_table(df))
  n <- suppressWarnings(as.numeric(df$n)); n[is.na(n)] <- 0
  top <- max(n, 0)
  pct <- if (top > 0) 100 * n / top else rep(0, length(n))
  # Of the first bar, not of the cohort: the first row of an attrition is the
  # denominator anyone reading it has in mind.
  base <- if (length(n)) n[1] else 0
  rows <- vapply(seq_len(nrow(df)), function(i)
    paste0('<div class="brow"><div class="blab">', .h(df$label[i]),
           '</div><div class="btrack"><div class="bfill" style="width:',
           sprintf("%.1f", pct[i]), '%"></div></div><div class="bval">',
           .h(.fmt(n[i])),
           if (base > 0) paste0(' <span class="bpct">',
                                sprintf("%.1f%%", 100 * n[i] / base), "</span>") else "",
           "</div></div>"), character(1))
  paste0('<div class="bars">', paste(rows, collapse = ""), "</div>")
}

render_panel <- function(kind, df) {
  switch(kind, table = render_table(df), kpi = render_kpi(df),
         bar = render_bar(df), render_table(df))
}

# GSK colours, in one place. Swapping the palette is editing this block - every
# rule below refers to a variable, none carries a literal.
#
# GSK orange (#F36633) is the primary and is the one value taken from the brand
# mark itself. The plum used for the header bar and the supporting neutrals are
# chosen to sit with it; confirm them against the current brand guide before
# this goes to anyone outside the team, and change them here if they differ.
PALETTE <- c(
  orange      = "#F36633",   # GSK primary - bars, accents, active nav
  orange_dark = "#D14E1F",   # hover and the darker end of the bar fill
  plum        = "#3D2352",   # header band
  plum_light  = "#5B3A73",   # nav band
  ink         = "#1B1B1B",   # body text
  slate       = "#5A5A64",   # muted text
  line        = "#E4E0E6",   # borders
  wash        = "#FAF8F7",   # panel tint and page background
  paper       = "#FFFFFF",
  on_plum     = "#EFE7F3",   # nav text on the plum band
  on_plum_dim = "#D9CFE2",   # the header's sub-line
  alert_ink   = "#7A4A1C",   # a panel that could not be shown
  alert_bg    = "#FDF1E9",
  alert_line  = "#F6D8C4"
)

# The orange at an alpha, for the nav hover. Derived rather than written out:
# a second copy of the colour would survive a palette swap and then look like a
# bug in the swap.
.rgba <- function(hex, alpha) {
  v <- strtoi(substring(gsub("#", "", hex, fixed = TRUE), c(1, 3, 5), c(2, 4, 6)), 16L)
  sprintf("rgba(%d,%d,%d,%s)", v[1], v[2], v[3], alpha)
}

.CSS <- local({
  p <- PALETTE
  paste0('
:root{--o:', p[["orange"]], ';--od:', p[["orange_dark"]], ';--pl:', p[["plum"]],
';--pll:', p[["plum_light"]], ';--ink:', p[["ink"]], ';--sl:', p[["slate"]],
';--ln:', p[["line"]], ';--wa:', p[["wash"]], ';--pa:', p[["paper"]],
';--op:', p[["on_plum"]], ';--opd:', p[["on_plum_dim"]], ';--ai:', p[["alert_ink"]],
';--ab:', p[["alert_bg"]], ';--al:', p[["alert_line"]], ';--oh:', .rgba(p[["orange"]], ".22"), '}
*{box-sizing:border-box} body{margin:0;font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;color:var(--ink);background:var(--wa)}
header{background:var(--pl);color:var(--pa);padding:22px 28px;border-bottom:4px solid var(--o)}
header h1{margin:0;font-size:20px;font-weight:600;letter-spacing:-.01em}
header p{margin:5px 0 0;font-size:13px;color:var(--opd)}
nav{display:flex;flex-wrap:wrap;gap:2px;background:var(--pll);padding:0 28px}
nav a{color:var(--op);text-decoration:none;padding:11px 16px;font-size:13px;border-bottom:3px solid transparent}
nav a:hover{background:var(--oh);color:var(--pa);border-bottom-color:var(--o)}
main{padding:24px 28px 64px;max-width:1500px}
section{margin-bottom:34px}
section h2{font-size:14px;text-transform:uppercase;letter-spacing:.08em;color:var(--pl);margin:0 0 14px;padding-bottom:6px;border-bottom:2px solid var(--o)}
.panel{background:var(--pa);border:1px solid var(--ln);border-radius:6px;padding:16px 18px;margin-bottom:16px}
.panel h3{margin:0 0 12px;font-size:14px;font-weight:600;color:var(--pl)}
.scroll{overflow-x:auto}
table{border-collapse:collapse;width:100%;font-size:13px}
th{text-align:left;background:var(--wa);color:var(--pl);font-weight:600;padding:7px 10px;border-bottom:2px solid var(--o);white-space:nowrap}
td{padding:6px 10px;border-bottom:1px solid var(--ln)}
td.num{text-align:right;font-variant-numeric:tabular-nums}
tr:last-child td{border-bottom:none}
tbody tr:hover{background:var(--wa)}
.kpis{display:flex;flex-wrap:wrap;gap:12px}
.kpi{flex:1 1 150px;background:var(--wa);border:1px solid var(--ln);border-left:4px solid var(--o);border-radius:5px;padding:14px 16px}
.kpi-n{font-size:24px;font-weight:600;color:var(--pl);font-variant-numeric:tabular-nums}
.kpi-l{font-size:12px;color:var(--sl);margin-top:2px}
.bars{display:flex;flex-direction:column;gap:6px}
.brow{display:flex;align-items:center;gap:10px}
.blab{flex:0 0 clamp(140px,26%,340px);font-size:13px;color:var(--ink)}
.btrack{flex:1 1 auto;background:var(--ln);border-radius:3px;height:18px;overflow:hidden}
.bfill{height:100%;background:linear-gradient(90deg,var(--o),var(--od));border-radius:3px}
.bval{flex:0 0 130px;text-align:right;font-size:13px;font-variant-numeric:tabular-nums}
.bpct{color:var(--sl);font-size:12px}
.empty{color:var(--sl);font-style:italic;margin:0}
.skip{color:var(--ai);background:var(--ab);border:1px solid var(--al);border-left:4px solid var(--o);border-radius:4px;padding:8px 10px;font-size:13px;margin:0}
footer{padding:18px 28px;color:var(--sl);font-size:12px;border-top:2px solid var(--o);background:var(--pa)}
@media print{nav{display:none} .panel{break-inside:avoid}}
')
})

# panels: list(tab, label, html). Order is the registry's order, so the file
# reads the way sections.R reads.
render_document <- function(panels, title, subtitle) {
  tabs <- unique(vapply(panels, `[[`, character(1), "tab"))
  anchor <- function(t) paste0("s-", tolower(gsub("[^A-Za-z0-9]+", "-", t)))
  nav <- paste0(vapply(tabs, function(t)
    paste0('<a href="#', anchor(t), '">', .h(t), "</a>"), character(1)),
    collapse = "")
  body <- paste0(vapply(tabs, function(t) {
    inner <- paste0(vapply(Filter(function(p) identical(p$tab, t), panels),
      function(p) paste0('<div class="panel"><h3>', .h(p$label), "</h3>",
                         p$html, "</div>"), character(1)), collapse = "")
    paste0('<section id="', anchor(t), '"><h2>', .h(t), "</h2>", inner, "</section>")
  }, character(1)), collapse = "")
  paste0("<!DOCTYPE html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">",
         '<meta name="viewport" content="width=device-width,initial-scale=1">',
         "<title>", .h(title), "</title><style>", .CSS, "</style></head><body>",
         "<header><h1>", .h(title), "</h1><p>", .h(subtitle), "</p></header>",
         "<nav>", nav, "</nav><main>", body, "</main>",
         "<footer>", .h(subtitle), "</footer></body></html>")
}
