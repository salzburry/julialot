# Drawing, in base R only.
#
# A missing plotting package must not silently produce nothing, so nothing here
# needs one. Shiny renders the HTML these build; the plots are base graphics.

# GSK colours, written out here rather than read from a sibling folder: this
# folder has to stand on its own, and reaching across for eleven strings would
# end that.
PALETTE <- c(
  orange      = "#F36633",
  orange_dark = "#D14E1F",
  orange_pale = "#FDEDE6",
  paper       = "#FFFFFF",
  ink         = "#1B1B1B",
  slate       = "#5A5A64",
  line        = "#E6E6E6",
  wash        = "#FBF9F8",
  alert_ink   = "#7A4A1C",
  alert_bg    = "#FDF1E9",
  alert_line  = "#F6D8C4"
)

# A categorical ramp for series that are not the primary. Derived from the
# palette rather than written out, so a swap carries.
series_colours <- function(n) {
  base <- c(PALETTE[["orange"]], PALETTE[["slate"]], PALETTE[["orange_dark"]],
            "#8C6D9C", "#3F7F7A", "#B58A3C", "#6B7FA8")
  if (n <= length(base)) return(base[seq_len(n)])
  grDevices::colorRampPalette(base)(n)
}

html_escape <- function(x) {
  x <- as.character(x)
  x[is.na(x)] <- ""
  x <- gsub("&", "&amp;", x, fixed = TRUE)
  x <- gsub("<", "&lt;", x, fixed = TRUE)
  x <- gsub(">", "&gt;", x, fixed = TRUE)
  x <- gsub('"', "&quot;", x, fixed = TRUE)
  gsub("'", "&#39;", x, fixed = TRUE)
}

# A number a reader can scan. Counts get thousands separators, rates and
# percentages a fixed number of places, and a suppressed cell reads as the
# reason it is empty rather than as a blank that could be a zero.
fmt_num <- function(x, digits = 2) {
  if (is.null(x)) return(character(0))
  n <- suppressWarnings(as.numeric(x))
  out <- ifelse(is.na(n), "—",
                ifelse(n == round(n) & abs(n) >= 1000,
                       formatC(n, format = "d", big.mark = ","),
                       formatC(n, format = "f", digits = digits, big.mark = ",")))
  out[is.na(x)] <- "—"
  out
}

# A data frame as an HTML table. Suppressed rows are marked, not dropped: a
# dropped row and a stratum that did not occur look the same, and only one of
# them means "we could not say".
html_table <- function(d, caption = NULL, digits = 2, max_rows = 5000L) {
  if (is.null(d) || !nrow(d))
    return(sprintf('<p class="empty">%s</p>',
                   html_escape(caption %||% "Nothing to show for this selection.")))
  truncated <- nrow(d) > max_rows
  if (truncated) d <- d[seq_len(max_rows), , drop = FALSE]
  supp <- if ("SUPPRESSED" %in% names(d)) d$SUPPRESSED %in% 1L else rep(FALSE, nrow(d))
  show <- setdiff(names(d), "SUPPRESSED")
  cells <- lapply(show, function(cl) {
    v <- d[[cl]]
    if (is.numeric(v)) fmt_num(v, digits) else html_escape(v)
  })
  head_html <- paste0("<th>", html_escape(gsub("_", " ", show)), "</th>", collapse = "")
  rows <- vapply(seq_len(nrow(d)), function(i) {
    tds <- paste0("<td>", vapply(cells, `[`, character(1), i), "</td>", collapse = "")
    sprintf('<tr class="%s">%s</tr>', if (supp[i]) "supp" else "", tds)
  }, character(1))
  paste0(
    if (!is.null(caption)) sprintf("<p class=\"cap\">%s</p>", html_escape(caption)) else "",
    '<table class="grid"><thead><tr>', head_html, "</tr></thead><tbody>",
    paste(rows, collapse = ""), "</tbody></table>",
    if (any(supp)) sprintf('<p class="note">%d row(s) shaded: fewer than the floor this view applies, so the cells are withheld.</p>', sum(supp)) else "",
    if (truncated) sprintf('<p class="note">Showing the first %s rows.</p>',
                           format(max_rows, big.mark = ",")) else "")
}

# KPI strip.
html_kpis <- function(pairs) {
  if (!length(pairs)) return("")
  items <- vapply(names(pairs), function(k)
    sprintf('<div class="kpi"><div class="kpi-v">%s</div><div class="kpi-k">%s</div></div>',
            html_escape(pairs[[k]]), html_escape(k)), character(1))
  paste0('<div class="kpis">', paste(items, collapse = ""), "</div>")
}

# --- base-R plots -----------------------------------------------------------

plot_bar <- function(labels, values, main = "", xlab = "", horizontal = TRUE) {
  if (!length(values) || all(is.na(values))) { plot_empty(); return(invisible()) }
  op <- graphics::par(mar = if (horizontal) c(4, 14, 3, 2) else c(8, 4, 3, 2),
                      bg = PALETTE[["paper"]], col.axis = PALETTE[["slate"]],
                      col.lab = PALETTE[["slate"]], col.main = PALETTE[["ink"]])
  on.exit(graphics::par(op), add = TRUE)
  graphics::barplot(values, names.arg = labels, horiz = horizontal, las = 1,
                    col = PALETTE[["orange"]], border = NA, main = main,
                    xlab = xlab, cex.names = 0.8)
  graphics::grid(nx = if (horizontal) NULL else NA, ny = if (horizontal) NA else NULL,
                 col = PALETTE[["line"]], lty = 1)
}

# One or more KM curves, with the step function and its band.
#
# A curve with no step in it is still a curve: thirty patients none of whom had
# the event is a result, not absent data. So any curve that was observed at all
# is kept, and km_steps() supplies the points either way.
plot_km <- function(curves, main = "", xlab = "Months", ylab = "Survival") {
  curves <- Filter(function(k)
    !is.null(k) && (nrow(k) > 0 || !is.na(attr(k, "follow_up") %||% NA_real_)),
    curves)
  if (!length(curves)) { plot_empty(); return(invisible()) }
  op <- graphics::par(mar = c(4.5, 4.5, 3, 2), bg = PALETTE[["paper"]],
                      col.axis = PALETTE[["slate"]], col.lab = PALETTE[["slate"]],
                      col.main = PALETTE[["ink"]])
  on.exit(graphics::par(op), add = TRUE)
  steps <- lapply(curves, km_steps)
  xmax <- max(vapply(steps, function(k)
    if (nrow(k)) max(k$TIME) else 0, numeric(1)), na.rm = TRUE)
  if (!is.finite(xmax) || xmax <= 0) xmax <- 1
  cols <- series_colours(length(curves))
  plot(NA, xlim = c(0, xmax), ylim = c(0, 1), main = main, xlab = xlab,
       ylab = ylab, las = 1, bty = "n")
  graphics::grid(col = PALETTE[["line"]], lty = 1)
  for (i in seq_along(curves)) {
    k <- curves[[i]]; st <- steps[[i]]
    if (nrow(k) && !all(is.na(k$LOWER))) {
      x <- c(0, k$TIME)
      graphics::polygon(c(x, rev(x)),
                        c(c(1, k$UPPER), rev(c(1, k$LOWER))),
                        col = grDevices::adjustcolor(cols[i], alpha.f = 0.12),
                        border = NA)
    }
    if (nrow(st)) graphics::lines(st$TIME, st$SURV, type = "s", col = cols[i],
                                  lwd = 2)
  }
  if (length(curves) > 1)
    graphics::legend("topright", legend = names(curves), col = cols, lwd = 2,
                     bty = "n", cex = 0.85, text.col = PALETTE[["slate"]])
}

plot_empty <- function(msg = "Nothing to show for this selection.") {
  op <- graphics::par(mar = c(0, 0, 0, 0), bg = PALETTE[["paper"]])
  on.exit(graphics::par(op), add = TRUE)
  plot(NA, xlim = 0:1, ylim = 0:1, axes = FALSE, xlab = "", ylab = "")
  graphics::text(0.5, 0.5, msg, col = PALETTE[["slate"]], cex = 1)
}

# The headline counts, and the floor applied to them.
#
# Pure rather than part of the server, so the floor these go through is decided
# where a test can drive it.
kpi_row_html <- function(d, floor_n = 25L, package_min_n = 25L,
                         col = "N_REMAINING", by = "COHORT") {
  if (is.null(d) || !nrow(d) || !all(c(col, by) %in% names(d)))
    return(html_table(NULL))
  fl <- effective_floor(floor_n, package_min_n)
  n  <- suppressWarnings(as.numeric(d[[col]]))
  rel <- vapply(n, released, logical(1), fl)
  paste0(
    html_kpis(stats::setNames(as.list(ifelse(rel, fmt_num(n, 0), "withheld")),
                              paste0(as.character(d[[by]]), " cohort"))),
    if (all(rel)) "" else sprintf(
      '<p class="note">A cohort below the floor of %s is withheld.</p>',
      fmt_num(fl, 0)))
}

# What a table panel renders. A `subject` table is one row per patient, so it
# is summarised rather than drawn as a grid: a grid of it is a line listing
# with the identifier attached.
#
# The population, the floor and the caption all come from prepare_panel(), so
# this cannot disagree with the KPI, the curve or the comparison about how many
# patients a selection holds.
panel_table_html <- function(d, spec, floor_n = 25L, max_rows = 5000L,
                             purpose = "descriptive") {
  if (is.null(d) || !nrow(d)) return(html_table(NULL))
  if (identical(spec$shape, "subject")) {
    pp <- prepare_panel(d, spec, floor_n, purpose = purpose)
    out <- summarise_subject(pp$rows, spec, min_n = pp$floor_n,
                             n_population = pp$n)
    return(paste0(
      sprintf('<p class="note">%s%s</p>', html_escape(pp$note),
              if (pp$released) " Per-patient rows are never shown." else ""),
      html_table(out, max_rows = max_rows)))
  }
  html_table(drop_identifiers(d), max_rows = max_rows)
}
