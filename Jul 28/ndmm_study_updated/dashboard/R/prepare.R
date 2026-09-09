# What a panel is allowed to show, decided once.
#
# Every renderer used to answer four questions for itself: which rows are the
# analysis set, how many PATIENTS that is, whether that number clears the
# floor, and what to draw when it does not. Six closures answered them six
# ways, and five of them got at least one wrong - a survival curve over the
# whole cohort instead of the eligible subset, a KPI and a comparison with no
# floor at all, a caption calling lines patients.
#
# So the questions are asked here, and a renderer receives the answers.
#
# Nothing in this file loosens anything. The package suppressed into its
# S_*_RELEASE tables at its own threshold before any of this ran, and
# apply_floor() still holds every released cell to the viewer's floor as well.
# This is the population test that has to happen AFTER aggregation, on the
# thing being drawn, and it can only ever withhold more.

# ---- grain ------------------------------------------------------------------
# How many rows a table has per patient. A count of rows is a count of
# patients only where the two are the same thing.
#
#   patient  one row per patient within the keys
#   line     one row per patient AND line - LOT_LONG_FINAL is this
#   stratum  one row per stratum, with its own count column
#
# Declared for the tables where rows are not patients. Everything else is read
# off the shape, so a new table gets the safe reading without an edit here.
TABLE_GRAIN <- list(
  LOT_LONG_FINAL = "line",
  LOT_LONG       = "line",
  S_SAFETY_EVENTS = "event",   # one row per patient and condition
  S_HCRU_EVENTS   = "event",   # one row per patient and encounter
  S_MALIGNANCY    = "event")   # one row per patient and malignancy

table_grain <- function(spec) {
  g <- TABLE_GRAIN[[spec$name %||% ""]]
  if (!is.null(g)) return(g)
  if (identical(spec$shape, "subject")) "patient" else "stratum"
}

# What one row of this table is, for a caption. Plural, lower case.
grain_noun <- function(grain)
  switch(grain, patient = "patients", line = "lines", event = "records",
         "rows")

# ---- population -------------------------------------------------------------
# The number of PATIENTS a rendered result rests on, which is the number the
# suppression rule is about.
#
# Counted off the identifier where the table carries one, because that is the
# only reading that is right at every grain. nrow() is right only at patient
# grain, and using it at line grain called ten patients with three lines each
# "30 patients" and published a category summary the floor should have
# withheld.
#
# NA where it cannot be established. A caller must treat NA as "withhold":
# a population that cannot be counted has not been shown to clear the floor.
population_n <- function(d, spec) {
  if (is.null(d) || !nrow(d)) return(0L)
  id <- spec$id %||% "PATID"
  hit <- names(d)[match(toupper(id), toupper(names(d)))]
  if (length(hit) && !is.na(hit[1])) {
    v <- as.character(d[[hit[1]]])
    return(length(unique(v[!is.na(v) & nzchar(trimws(v))])))
  }
  # A stratum table carries its own count instead.
  n_col <- infer_n_col(spec, names(d))
  if (!is.null(n_col)) {
    n <- suppressWarnings(as.numeric(d[[n_col]]))
    if (any(!is.na(n))) return(as.integer(max(n, na.rm = TRUE)))
  }
  NA_integer_
}

# ---- the analysis set -------------------------------------------------------
# Which rows a purpose may use. The producer keeps the whole cohort in S_TTE
# and marks the restricted analysis with TTE_ELIGIBLE - see
# study223926/R/modules/09_tte.R - so a survival estimate has to apply it and
# a descriptive summary of the same table must not.
#
# Fails closed: a purpose that needs a flag the table does not carry gets no
# rows, rather than the whole table under an eligible-looking label.
ANALYSIS_FLAG <- list(tte = "TTE_ELIGIBLE")

analysis_rows <- function(d, spec, purpose = "descriptive") {
  if (is.null(d) || !nrow(d)) return(d)
  flag <- ANALYSIS_FLAG[[purpose]]
  if (is.null(flag)) return(d)
  if (!flag %in% names(d)) return(d[0, , drop = FALSE])
  keep <- suppressWarnings(as.integer(d[[flag]])) %in% 1L
  d[keep, , drop = FALSE]
}

# Whether the purpose narrowed the table, for a caption that has to say so.
analysis_note <- function(purpose) {
  flag <- ANALYSIS_FLAG[[purpose]]
  if (is.null(flag)) return("")
  sprintf(" %s = 1 only, which is the population the producer marks for this analysis.",
          flag)
}

# ---- the release decision ---------------------------------------------------
# One test, and it is the only one any renderer should make.
released <- function(n, floor_n)
  !is.na(n) && !is.na(floor_n) && n >= floor_n

# The viewer's floor and the package's, whichever is higher. A viewer may
# raise it; lowering it below what the package applied reveals nothing,
# because those cells arrived NULL.
effective_floor <- function(viewer_floor, package_min_n = 25L) {
  v <- suppressWarnings(as.integer(viewer_floor))
  p <- suppressWarnings(as.integer(package_min_n))
  if (is.na(p)) p <- 25L
  if (is.na(v)) p else max(v, p)
}

# Everything a renderer needs, from the rows it was given.
#
#   rows      the analysis set for this purpose
#   n         patients in it, or NA where that cannot be counted
#   grain     what one row is
#   floor_n   the floor actually applied
#   released  whether the result may be drawn
#   note      the caption, whichever way it went
prepare_panel <- function(d, spec, floor_n, purpose = "descriptive",
                          package_min_n = 25L) {
  fl   <- effective_floor(floor_n, package_min_n)
  rows <- analysis_rows(d, spec, purpose)
  n    <- population_n(rows, spec)
  gr   <- table_grain(spec)
  rel  <- released(n, fl)
  note <- if (rel)
    sprintf("%s patients in this selection%s%s", fmt_num(n, 0),
            if (identical(gr, "patient")) "" else
              sprintf(" (%s %s)", fmt_num(nrow(rows), 0), grain_noun(gr)),
            analysis_note(purpose))
  else if (is.na(n))
    sprintf("Withheld: the number of patients behind this could not be established, so it cannot be shown to reach the floor of %s.",
            fmt_num(fl, 0))
  else
    sprintf("Withheld: %s patients, below the floor of %s.",
            fmt_num(n, 0), fmt_num(fl, 0))
  list(rows = rows, n = n, grain = gr, floor_n = fl, released = rel,
       note = note, purpose = purpose)
}

# ---- bars -------------------------------------------------------------------
# A bar chart of a FINISHED rate, with the strata preserved.
#
# The previous version grouped by the facet alone and took mean() of the rate.
# Selecting every period therefore drew one unlabelled bar averaging distinct
# strata: 10 events in 10 person-years and 10 in 1,000 are rates of 1,000 and
# 10 per 1,000 PY, and the bar said 505 - a number that is neither, and not
# the pooled rate either. Baseline and follow-up person-time cannot be pooled
# by averaging, and the populations behind two strata overlap.
#
# So the label carries every column that varies in the selection, and each bar
# is one row of the table. Where that still leaves two rows on one label the
# table has a duplicated stratum - a real failure the package has its own
# grain check for - and it is reported rather than averaged away.
stratum_label <- function(d, spec, lab) {
  cols <- unique(c(lab, intersect(c(spec$keys, spec$groups), names(d))))
  cols <- Filter(function(k)
    identical(k, lab) || length(unique(as.character(d[[k]]))) > 1L, cols)
  do.call(paste, c(lapply(cols, function(k)
    if (identical(k, lab)) as.character(d[[k]])
    else paste0(k, "=", as.character(d[[k]]))), sep = " · "))
}

# What the bars ARE, separately from drawing them.
#
# The decision lived inside the plot call, and a plot returns nothing a test
# can read - so the two rules that matter here, that strata are never averaged
# and that a bar resting on too few patients is not drawn, were reachable only
# through Shiny. Same reason panel_table_html() and kpi_row_html() left the
# server.
#
# Returns labels and values to draw, or ok = FALSE and the reason not to.
stratum_bar_data <- function(d, spec, lab, val) {
  L <- stratum_label(d, spec, lab)
  v <- suppressWarnings(as.numeric(d[[val]]))
  keep <- !is.na(v)
  L <- L[keep]; v <- v[keep]
  if (!length(v))
    return(list(ok = FALSE, why = "Every value in this selection is withheld."))
  if (anyDuplicated(L))
    return(list(ok = FALSE, why = paste0(
      "This selection holds more than one row per stratum, so a bar would ",
      "have to combine them. The table beside this panel shows them separately.")))
  o <- order(-v)
  list(ok = TRUE, labels = L[o], values = v[o], xlab = val)
}

plot_stratum_bars <- function(d, spec, lab, val, main) {
  b <- stratum_bar_data(d, spec, lab, val)
  if (!b$ok) return(plot_empty(b$why))
  plot_bar(b$labels, b$values, main = main, xlab = b$xlab)
}

# A count of rows, broken down. The bar counts what the table's rows ARE -
# lines, where the table is one row per patient and line - and that is a
# legitimate figure. The FLOOR is still about patients, so the patients behind
# each bar are counted and a bar below the floor is dropped rather than drawn.
count_bar_data <- function(d, spec, lab, floor_n, package_min_n = 25L) {
  fl  <- effective_floor(floor_n, package_min_n)
  gr  <- table_grain(spec)
  lv  <- as.character(d[[lab]])
  lv[is.na(lv) | !nzchar(trimws(lv))] <- "(Missing)"
  parts <- split(seq_len(nrow(d)), lv)
  n_pat <- vapply(parts, function(i) population_n(d[i, , drop = FALSE], spec),
                  integer(1))
  n_row <- vapply(parts, length, integer(1))
  ok_bar <- vapply(n_pat, released, logical(1), fl)
  if (!any(ok_bar))
    return(list(ok = FALSE, why = sprintf(
      "Every %s here rests on fewer than %s patients, so none is shown.",
      sub("s$", "", grain_noun(gr)), fmt_num(fl, 0))))
  o <- order(-n_row[ok_bar])
  list(ok = TRUE, labels = names(parts)[ok_bar][o], values = n_row[ok_bar][o],
       patients = unname(n_pat[ok_bar][o]), xlab = grain_noun(gr))
}

plot_count_bars <- function(d, spec, lab, main, floor_n,
                            package_min_n = 25L) {
  b <- count_bar_data(d, spec, lab, floor_n, package_min_n)
  if (!b$ok) return(plot_empty(b$why))
  plot_bar(b$labels, b$values, main = main, xlab = b$xlab)
}

# ---- comparisons ------------------------------------------------------------
# The floor, applied to a two-scenario comparison.
#
# compare_tables() joins two readings on the spec's keys and reports A, B and
# the difference. Both sides had already been through apply_floor(), but the
# comparison was built from the rows rather than from the suppressed values,
# so a stratum both normal panels withheld came back here in full - with its
# delta, which is a second disclosure the panels never made.
#
# A stratum is shown only where BOTH sides clear the floor. One side alone is
# still a fact worth seeing - a scenario that moves a stratum under the floor
# is exactly what someone is looking for - so the row stays and says so.
suppress_comparison <- function(cm, a, b, spec, floor_n, package_min_n = 25L) {
  if (is.null(cm) || !nrow(cm)) return(cm)
  fl <- effective_floor(floor_n, package_min_n)
  n_col <- infer_n_col(spec, unique(c(names(a), names(b))))
  keys <- intersect(names(cm), names(a))
  if (is.null(n_col) || !length(keys)) {
    # Nothing to test the population with: withhold rather than publish a
    # difference that has not been shown to clear the floor.
    cm$A <- NA; cm$B <- NA; cm$DELTA <- NA; cm$PCT_CHANGE <- NA
    cm$RELEASED <- 0L
    return(cm)
  }
  side_n <- function(d) {
    if (is.null(d) || !nrow(d) || !n_col %in% names(d)) return(NULL)
    k <- do.call(paste, c(lapply(keys, function(x) as.character(d[[x]])),
                          sep = "\r"))
    stats::setNames(suppressWarnings(as.numeric(d[[n_col]])), k)
  }
  na <- side_n(a); nb <- side_n(b)
  ck <- do.call(paste, c(lapply(keys, function(x) as.character(cm[[x]])),
                         sep = "\r"))
  get <- function(v) if (is.null(v)) rep(NA_real_, length(ck)) else
    unname(v[match(ck, names(v))])
  ok_row <- vapply(get(na), released, logical(1), fl) &
            vapply(get(nb), released, logical(1), fl)
  cm$A[!ok_row] <- NA
  cm$B[!ok_row] <- NA
  cm$DELTA[!ok_row] <- NA
  cm$PCT_CHANGE[!ok_row] <- NA
  cm$RELEASED <- as.integer(ok_row)
  cm
}
