# =============================================================================
# patient_explorer.R  --  per-patient treatment-journey "swimlanes".
# -----------------------------------------------------------------------------
# Lets a user look INTO the cohort: pick a 1L regimen (or All), and see a sample
# of individual patients drawn as horizontal timelines -- one lane per patient,
# each line-of-therapy a coloured segment (months since 1L start), with markers
# for death (x) and censoring (>). Pure base R + base graphics (self-contained),
# backed by the same LOT-long table + patient-level anchors the rest of the app
# uses. Sampling is DETERMINISTIC (first-n after an ordered sort) so a given
# cohort + filter always shows the same illustrative patients.
# =============================================================================

# Build per-patient, per-line timeline segments (months from the patient's 1L
# start) for up to `n` patients, with PATHWAY + EVENT filters so a reviewer can
# pull specific journeys for QC (e.g. "1L Monotherapy -> later CAR-T", or every
# patient who discontinued after 1L). All filters are indication-agnostic --
# regimen sets come from the data / the active pack, not hard-coded MM terms.
#   soc_filter       restrict 1L regimen (NULL / "All" = any)
#   then_soc         require >=1 LATER line (lot_num>=2) whose regimen is in this set
#   reached_regimen  require ANY line (any position) whose regimen is in this set
#                    (this is how pack "milestones" like CAR-T / SCT / surgery map)
#   event            structural outcome: "any" | "died" (OS event) |
#                    "disc1l" (stopped after 1L, no 2L) | "ge3lines" (>=3 lines)
#   sort_by          "soc" groups by 1L regimen; "os" longest-followed; "lines"
#                    most heavily treated first.
patient_timeline_data <- function(lot_long, cohort, n = 16L, soc_filter = NULL,
                                  then_soc = NULL, reached_regimen = NULL,
                                  event = c("any", "died", "disc1l", "ge3lines"),
                                  sort_by = c("soc", "os", "lines")) {
  sort_by <- match.arg(sort_by); event <- match.arg(event)
  anc <- cohort[, c("patient_id", "lot1_start_dt", "soc_category", "n_lines",
                    "os_time", "os_event"), drop = FALSE]
  if (!is.null(soc_filter) && length(soc_filter) && !("All" %in% soc_filter))
    anc <- anc[anc$soc_category %in% soc_filter, , drop = FALSE]
  if (!nrow(anc)) return(NULL)

  # pathway / event filters that need the per-line table (restricted to remaining
  # patients). Membership sets are computed once; anc is then intersected.
  llc <- lot_long[lot_long$patient_id %in% anc$patient_id, , drop = FALSE]
  if (!is.null(then_soc) && length(then_soc) && !("Any" %in% then_soc)) {
    hit <- unique(llc$patient_id[llc$lot_num >= 2L & llc$lot_soc %in% then_soc])
    anc <- anc[anc$patient_id %in% hit, , drop = FALSE]
  }
  if (!is.null(reached_regimen) && length(reached_regimen)) {
    hitr <- unique(llc$patient_id[llc$lot_soc %in% reached_regimen])
    anc <- anc[anc$patient_id %in% hitr, , drop = FALSE]
  }
  if (event != "any") {
    keep <- switch(event,
      died     = anc$patient_id[anc$os_event == 1L],
      disc1l   = anc$patient_id[anc$n_lines == 1L],
      ge3lines = anc$patient_id[anc$n_lines >= 3L])
    anc <- anc[anc$patient_id %in% keep, , drop = FALSE]
  }
  if (!nrow(anc)) return(NULL)

  ord <- switch(sort_by,
    soc   = order(anc$soc_category, -anc$n_lines, anc$patient_id),
    os    = order(-anc$os_time, anc$patient_id),
    lines = order(-anc$n_lines, -anc$os_time, anc$patient_id))
  anc <- anc[ord, , drop = FALSE]
  ids <- utils::head(anc$patient_id, n)

  ll <- lot_long[lot_long$patient_id %in% ids, , drop = FALSE]
  ll <- ll[order(match(ll$patient_id, ids), ll$lot_num), ]
  segs <- list(); marks <- list()
  for (k in seq_along(ids)) {
    pid <- ids[k]
    p <- ll[ll$patient_id == pid, , drop = FALSE]
    a <- anc[anc$patient_id == pid, , drop = FALSE][1, ]
    if (!nrow(p)) next
    l1 <- as.Date(a$lot1_start_dt)
    startm <- as.numeric(as.Date(p$lot_start_dt) - l1) / 30.44
    startm[is.na(startm) | startm < 0] <- 0
    ns <- nrow(p); endm <- numeric(ns)
    if (ns > 1) endm[seq_len(ns - 1)] <- startm[-1]
    endm[ns] <- startm[ns] + max(p$os_time[ns], 0.5)       # last line -> death/censor
    endm <- pmax(endm, startm + 0.4)                        # visible minimum width
    for (j in seq_len(ns))
      segs[[length(segs) + 1L]] <- data.frame(lane = k, x0 = startm[j], x1 = endm[j],
        soc = p$lot_soc[j], lot = p$lot_num[j], stringsAsFactors = FALSE)
    died <- isTRUE(p$os_event[ns] == 1L)
    marks[[length(marks) + 1L]] <- data.frame(lane = k, x = endm[ns],
      type = if (died) "death" else "censor", pid = pid,
      soc1 = a$soc_category, stringsAsFactors = FALSE)
  }
  if (!length(segs)) return(NULL)
  list(segs = do.call(rbind, segs), marks = do.call(rbind, marks),
       ids = ids, n = length(ids), sort_by = sort_by)
}

# Draw the swimlane. Reuses SANKEY_COLS (lot_views.R) so a regimen has the SAME
# colour here and in the pathway Sankey.
patient_swimlane_plot <- function(td, title = "Patient treatment journeys (sample)") {
  if (is.null(td) || is.null(td$segs) || !nrow(td$segs)) {
    plot.new(); text(0.5, 0.5, "No patients match the current selection.",
                     col = "#5B6472"); return(invisible()) }
  segs <- td$segs; marks <- td$marks
  nlane <- max(segs$lane); xmax <- max(segs$x1, na.rm = TRUE) * 1.03
  cats <- sort(unique(segs$soc))
  ccol <- setNames(SANKEY_COLS[(seq_along(cats) - 1) %% length(SANKEY_COLS) + 1], cats)

  op <- par(mar = c(6, 6.6, 3, 1)); on.exit(par(op))
  plot(NA, xlim = c(0, xmax), ylim = c(0.4, nlane + 0.6), axes = FALSE,
       xlab = "", ylab = "", yaxs = "i")
  title(main = title, col.main = "#1A1F2B", font.main = 1, cex.main = 1.05, line = 1)
  ax <- pretty(c(0, xmax), n = 8)
  abline(v = ax, col = "#EDEFF3", lwd = 1)
  axis(1, at = ax, col = "#DADEE6", col.axis = "#5B6472", cex.axis = 0.78, lwd = 0.8)
  mtext("Months since 1L start", side = 1, line = 2.4, cex = 0.85, col = "#5B6472")

  # subtle lane banding
  for (y in seq_len(nlane)) if (y %% 2L == 0L)
    rect(0, y - 0.42, xmax, y + 0.42, col = "#FAFBFC", border = NA)

  for (i in seq_len(nrow(segs))) {
    y <- segs$lane[i]
    rect(segs$x0[i], y - 0.30, segs$x1[i], y + 0.30, col = ccol[segs$soc[i]],
         border = "#FFFFFF", lwd = 0.7)
    if (segs$x1[i] - segs$x0[i] > xmax * 0.035)
      text((segs$x0[i] + segs$x1[i]) / 2, y, paste0(segs$lot[i], "L"),
           cex = 0.5, col = "#FFFFFF", font = 2)
  }
  for (i in seq_len(nrow(marks))) {
    y <- marks$lane[i]; x <- marks$x[i]
    if (identical(marks$type[i], "death"))
      points(x, y, pch = 4, col = "#C0392B", lwd = 2.2, cex = 1)     # x = death
    else
      text(x + xmax * 0.006, y, ">", col = "#8A93A2", cex = 0.9, font = 2)  # censored
  }
  # left lane labels (ordered sample index)
  axis(2, at = seq_len(nlane), labels = sprintf("Pt %02d", seq_len(nlane)),
       las = 1, tick = FALSE, col.axis = "#3A414E", cex.axis = 0.72, line = -0.5)

  # legend: SOC colours + the death/censor glyphs, anchored at the device bottom
  leg <- c(cats, "Death (x)", "Censored (>)")
  cols <- c(ccol[cats], "#C0392B", "#8A93A2")
  pchs <- c(rep(15, length(cats)), 4, NA)
  yb <- grconvertY(0.015, "ndc", "user")
  legend(x = grconvertX(0.5, "ndc", "user"), y = yb, xjust = 0.5, yjust = 0,
         legend = leg, col = cols, pch = pchs, pt.cex = 1.1, bty = "n",
         ncol = min(4L, length(leg)), cex = 0.62, text.col = "#3A414E", xpd = NA)
  invisible()
}
