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
#
# `pct` says what the percentage beside each bar is a percentage OF, and the
# section has to declare it - see BAR_PCT in sections.R. This used to be the
# first row always, which is right for a funnel and wrong for everything else:
# on a chart of overlapping scenarios it read "CAR-T 5%" where 5% was of the
# largest scenario, not of the cohort, and nothing on the page said so.
render_bar <- function(df, pct = "none") {
  if (is.null(df) || !nrow(df))
    return('<p class="empty">No rows.</p>')
  if (!all(c("label", "n") %in% names(df)))
    return(render_table(df))
  n <- suppressWarnings(as.numeric(df$n)); n[is.na(n)] <- 0
  top <- max(n, 0)
  w <- if (top > 0) 100 * n / top else rep(0, length(n))
  base <- switch(pct, first = if (length(n)) n[1] else 0, total = sum(n), 0)
  rows <- vapply(seq_len(nrow(df)), function(i)
    paste0('<div class="brow"><div class="blab">', .h(df$label[i]),
           '</div><div class="btrack"><div class="bfill" style="width:',
           sprintf("%.1f", w[i]), '%"></div></div><div class="bval">',
           .h(.fmt(n[i])),
           if (base > 0) paste0(' <span class="bpct">',
                                sprintf("%.1f%%", 100 * n[i] / base), "</span>") else "",
           "</div></div>"), character(1))
  paste0('<div class="bars">', paste(rows, collapse = ""), "</div>")
}

# A Sankey, as inline SVG. Needs `source`, `target` and `n`.
#
# apr_30_2026 drew these through plotly, which means a JavaScript bundle and a
# package that may not be installed - and when it is not, its dashboard writes
# no file at all. An SVG is a handful of bezier paths and needs neither. It
# also prints, which a canvas-based chart does not.
#
# Two columns: sources left, targets right, each node as tall as its share of
# the patients and each ribbon as thick as the patients moving along it.
# Ordered by size so the eye starts at the biggest flow.
render_sankey <- function(df, width = 940, node_w = 16, gap = 7,
                          height = NULL, pad = 6) {
  if (is.null(df) || !nrow(df)) return('<p class="empty">No rows.</p>')
  if (!all(c("source", "target", "n") %in% names(df))) return(render_table(df))
  src <- as.character(df$source); tgt <- as.character(df$target)
  n   <- suppressWarnings(as.numeric(df$n)); n[is.na(n)] <- 0
  keep <- n > 0
  if (!any(keep)) return('<p class="empty">No flows.</p>')
  src <- src[keep]; tgt <- tgt[keep]; n <- n[keep]

  ord <- function(k, v) { t <- tapply(v, k, sum); names(sort(t, decreasing = TRUE)) }
  L <- ord(src, n); R <- ord(tgt, n)
  Ltot <- tapply(n, src, sum); Rtot <- tapply(n, tgt, sum)
  # "Other" is a bucket, not a regimen, so it sits at the bottom whatever its
  # size - otherwise the largest flow on the page is the one that means least.
  if ("Other" %in% R) R <- c(setdiff(R, "Other"), "Other")

  if (is.null(height)) height <- max(220, 26 * max(length(L), length(R)))
  span <- function(k, tot) {
    total <- sum(tot[k]); gaps <- gap * max(length(k) - 1L, 0L)
    avail <- height - gaps
    h <- if (total > 0) avail * as.numeric(tot[k]) / total else rep(0, length(k))
    # Nothing thinner than a hairline: a flow of one patient still has to be
    # visible, or the chart quietly says it does not exist.
    h <- pmax(h, 2)
    y <- cumsum(c(0, head(h, -1) + gap))
    list(h = setNames(h, k), y = setNames(y, k))
  }
  Ls <- span(L, Ltot); Rs <- span(R, Rtot)
  x1 <- 0; x2 <- width - node_w
  off_l <- setNames(rep(0, length(L)), L); off_r <- setNames(rep(0, length(R)), R)

  # Widest flow first, so a thin ribbon is drawn over a thick one and stays
  # findable where they overlap.
  o <- order(n, decreasing = TRUE)
  ribbons <- vapply(o, function(i) {
    a <- src[i]; b <- tgt[i]
    ha <- Ls$h[[a]] * n[i] / Ltot[[a]]; hb <- Rs$h[[b]] * n[i] / Rtot[[b]]
    ya <- Ls$y[[a]] + off_l[[a]];       yb <- Rs$y[[b]] + off_r[[b]]
    off_l[[a]] <<- off_l[[a]] + ha;     off_r[[b]] <<- off_r[[b]] + hb
    xm <- (x1 + node_w + x2) / 2
    d <- sprintf("M%.1f,%.2f C%.1f,%.2f %.1f,%.2f %.1f,%.2f L%.1f,%.2f C%.1f,%.2f %.1f,%.2f %.1f,%.2f Z",
                 x1 + node_w, ya, xm, ya, xm, yb, x2, yb,
                 x2, yb + hb, xm, yb + hb, xm, ya + ha, x1 + node_w, ya + ha)
    paste0('<path d="', d, '" class="sk-f"><title>', .h(a), ' \u2192 ', .h(b),
           ': ', .h(.fmt(n[i])), ' patients</title></path>')
  }, character(1))

  node <- function(k, sp, x, anchor, dx) paste0(vapply(k, function(v) paste0(
    '<rect x="', x, '" y="', sprintf("%.2f", sp$y[[v]]), '" width="', node_w,
    '" height="', sprintf("%.2f", sp$h[[v]]), '" class="sk-n"><title>', .h(v),
    ': ', .h(.fmt(sp$h[[v]] * 0 + (if (anchor == "end") Ltot[[v]] else Rtot[[v]]))),
    ' patients</title></rect>',
    '<text x="', x + dx, '" y="', sprintf("%.2f", sp$y[[v]] + sp$h[[v]] / 2 + 4),
    '" text-anchor="', anchor, '" class="sk-t">', .h(v), '</text>'),
    character(1)), collapse = "")

  # viewBox with room for the labels either side, and preserveAspectRatio left
  # at its default so the whole thing scales into whatever width it is given.
  vb <- paste(-300, -pad, width + 600, height + 2 * pad)
  paste0('<div class="scroll"><svg class="sk" viewBox="', vb,
         '" width="100%" height="', height + 2 * pad, '" role="img">',
         paste(ribbons, collapse = ""),
         node(L, Ls, x1, "end", -8), node(R, Rs, x2, "start", node_w + 8),
         '</svg></div>')
}

render_panel <- function(kind, df, pct = "none") {
  switch(kind, table = render_table(df), kpi = render_kpi(df),
         bar = render_bar(df, pct), sankey = render_sankey(df), render_table(df))
}

# GSK colours, in one place. Swapping the palette is editing this block - every
# rule below refers to a variable, none carries a literal.
#
# GSK orange (#F36633) is the primary and is the one value taken from the brand
# mark itself. The plum used for the header bar and the supporting neutrals are
# chosen to sit with it; confirm them against the current brand guide before
# this goes to anyone outside the team, and change them here if they differ.
PALETTE <- c(
  orange      = "#F36633",   # GSK primary - the header band, bars, accents
  orange_dark = "#D14E1F",   # hover, and the darker end of a gradient
  orange_pale = "#FDEDE6",   # the faintest wash of it, for table headers
  paper       = "#FFFFFF",   # GSK's other colour: the page is white
  ink         = "#1B1B1B",
  slate       = "#5A5A64",   # muted text
  line        = "#E6E6E6",   # borders
  wash        = "#FBF9F8",   # a barely-there warm grey behind the panels
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
:root{--o:', p[["orange"]], ';--od:', p[["orange_dark"]], ';--ink:', p[["ink"]], ';--sl:', p[["slate"]],
';--ln:', p[["line"]], ';--wa:', p[["wash"]], ';--pa:', p[["paper"]],
';--opl:', p[["orange_pale"]], ';--ai:', p[["alert_ink"]],
';--ab:', p[["alert_bg"]], ';--al:', p[["alert_line"]], ';--oh:', .rgba(p[["orange"]], ".12"), '}
*{box-sizing:border-box} body{margin:0;font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;color:var(--ink);background:var(--wa)}
header{background:var(--o);color:var(--pa);padding:22px 28px}
header h1{margin:0;font-size:20px;font-weight:600;letter-spacing:-.01em}
header p{margin:5px 0 0;font-size:13px;color:var(--pa);opacity:.9}
nav{display:flex;flex-wrap:wrap;gap:2px;background:var(--pa);padding:0 28px;border-bottom:1px solid var(--ln)}
nav a{color:var(--ink);text-decoration:none;padding:11px 16px;font-size:13px;border-bottom:3px solid transparent}
nav a:hover{background:var(--oh);border-bottom-color:var(--o)}
main{padding:24px 28px 64px;max-width:1500px}
section{margin-bottom:34px}
section h2{font-size:14px;text-transform:uppercase;letter-spacing:.08em;color:var(--od);margin:0 0 14px;padding-bottom:6px;border-bottom:2px solid var(--o)}
.panel{background:var(--pa);border:1px solid var(--ln);border-radius:6px;padding:16px 18px;margin-bottom:16px}
.panel h3{margin:0 0 12px;font-size:14px;font-weight:600;color:var(--ink)}
.scroll{overflow-x:auto}
table{border-collapse:collapse;width:100%;font-size:13px}
th{text-align:left;background:var(--opl);color:var(--od);font-weight:600;padding:7px 10px;border-bottom:2px solid var(--o);white-space:nowrap}
td{padding:6px 10px;border-bottom:1px solid var(--ln)}
td.num{text-align:right;font-variant-numeric:tabular-nums}
tr:last-child td{border-bottom:none}
tbody tr:hover{background:var(--wa)}
.kpis{display:flex;flex-wrap:wrap;gap:12px}
.kpi{flex:1 1 150px;background:var(--wa);border:1px solid var(--ln);border-left:4px solid var(--o);border-radius:5px;padding:14px 16px}
.kpi-n{font-size:24px;font-weight:600;color:var(--od);font-variant-numeric:tabular-nums}
.kpi-l{font-size:12px;color:var(--sl);margin-top:2px}
.bars{display:flex;flex-direction:column;gap:6px}
.brow{display:flex;align-items:center;gap:10px}
.blab{flex:0 0 clamp(140px,26%,340px);font-size:13px;color:var(--ink)}
.btrack{flex:1 1 auto;background:var(--ln);border-radius:3px;height:18px;overflow:hidden}
.bfill{height:100%;background:linear-gradient(90deg,var(--o),var(--od));border-radius:3px}
.bval{flex:0 0 130px;text-align:right;font-size:13px;font-variant-numeric:tabular-nums}
.bpct{color:var(--sl);font-size:12px}
.empty{color:var(--sl);font-style:italic;margin:0}
.sk{display:block;min-width:900px}
.sk-f{fill:var(--o);fill-opacity:.28}
.sk-f:hover{fill-opacity:.62}
.sk-n{fill:var(--od)}
.sk-t{font:12px -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;fill:var(--ink)}
.skip{color:var(--ai);background:var(--ab);border:1px solid var(--al);border-left:4px solid var(--o);border-radius:4px;padding:8px 10px;font-size:13px;margin:0}
footer{padding:18px 28px;color:var(--sl);font-size:12px;border-top:3px solid var(--o);background:var(--pa)}
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
