# =============================================================================
# lot_views.R  --  per-LOT (1L/2L/3L) outcome slicing + regimen-frequency
#                  tables + 1L->2L SOC transition (Sankey-style) views.
#                  Backed by the LOT-long table (synth_lot_long / warehouse
#                  LOT_LONG projection). Pure base R (+ base graphics).
# =============================================================================

# Slice LOT-long to the selected patients and a given line, for per-LOT KM.
lot_slice <- function(lot_long, patient_ids, lot_num) {
  lot_long[lot_long$patient_id %in% patient_ids & lot_long$lot_num == lot_num, ,
           drop = FALSE]
}

# Regimen-frequency table (n & %) by SOC category for a given line.
regimen_frequency <- function(lot_long, patient_ids, lot_num) {
  s <- lot_slice(lot_long, patient_ids, lot_num)
  if (!nrow(s)) return(NULL)
  tb <- sort(table(s$lot_soc), decreasing = TRUE)
  data.frame(`SOC category` = names(tb), N = as.integer(tb),
             `%` = round(100 * as.integer(tb) / sum(tb), 2),
             check.names = FALSE, row.names = NULL)
}

# SOC transition counts from line `from_lot` -> next line.
# Protocol: the Sankey is COMMERCIAL-insured only (excludes Medicare).
lot_transition_table <- function(lot_long, patient_ids, from_lot = 1L,
                                 commercial_only = TRUE) {
  s <- lot_slice(lot_long, patient_ids, from_lot)
  if (commercial_only) s <- s[s$payer_type == "Commercial", , drop = FALSE]
  if (!nrow(s)) return(NULL)
  s$next_soc[is.na(s$next_soc)] <- "No next LOT"
  tb <- as.data.frame(table(From = s$lot_soc, To = s$next_soc),
                      stringsAsFactors = FALSE)
  tb <- tb[tb$Freq > 0, , drop = FALSE]
  tb <- tb[order(-tb$Freq), ]
  tb$`%` <- round(100 * tb$Freq / sum(tb$Freq), 2)
  rownames(tb) <- NULL
  tb
}

SANKEY_COLS <- c("#E8480C","#1F8A8A","#6A4C93","#3A6EA5","#B5179E","#666666",
                 "#2E8B57","#D62828","#8A6D3B","#00798C")

# Lightweight single-transition flow plot (base graphics, no extra deps).
# from_label / to_label default to 1L/2L but are parameterised so a 2L->3L or
# 3L->4L view shows the correct axis labels.
sankey_plot <- function(trans, title = "SOC transitions (commercial only)",
                        from_label = "from", to_label = "to") {
  if (is.null(trans) || !nrow(trans)) {
    plot.new(); text(0.5, 0.5, "No transitions for the current cohort."); return(invisible())
  }
  froms <- unique(trans$From); tos <- unique(trans$To)
  fy <- setNames(seq_along(froms) / (length(froms) + 1), froms)
  ty <- setNames(seq_along(tos)   / (length(tos) + 1),   tos)
  cols <- grDevices::adjustcolor(SANKEY_COLS, alpha.f = 0.55)
  fcol <- setNames(cols[(seq_along(froms) - 1) %% length(cols) + 1], froms)
  op <- par(mar = c(1, 1, 2.5, 1)); on.exit(par(op))
  plot(NA, xlim = c(0, 1), ylim = c(0, 1), axes = FALSE, xlab = "", ylab = "",
       main = title)
  wmax <- max(trans$Freq)
  for (i in seq_len(nrow(trans)))
    segments(0.18, fy[trans$From[i]], 0.82, ty[trans$To[i]],
             lwd = 1 + 9 * trans$Freq[i] / wmax, col = fcol[trans$From[i]])
  text(0.16, fy, labels = froms, pos = 2, cex = 0.8, xpd = NA)
  text(0.84, ty, labels = tos,   pos = 4, cex = 0.8, xpd = NA)
  points(rep(0.18, length(fy)), fy, pch = 15, cex = 1.4, col = fcol[froms])
  points(rep(0.82, length(ty)), ty, pch = 15, cex = 1.4, col = "#333333")
  mtext(from_label, side = 3, at = 0.18, line = -0.5, cex = 0.9)
  mtext(to_label,   side = 3, at = 0.82, line = -0.5, cex = 0.9)
  invisible()
}

# ---- true multi-stage 1L -> ...L patient-journey pathway --------------------
# Build the full per-patient SOC sequence across lines 1..max_line (patients who
# stop earlier flow into an "End (no next LOT)" terminal node), and the adjacent
# transition counts for every stage. Commercial-only per protocol.
lot_pathway_data <- function(lot_long, patient_ids, max_line = 4L,
                             commercial_only = TRUE) {
  s <- lot_long[lot_long$patient_id %in% patient_ids, , drop = FALSE]
  if (commercial_only) s <- s[s$payer_type == "Commercial", , drop = FALSE]
  if (!nrow(s)) return(NULL)
  s <- s[order(s$patient_id, s$lot_num), ]
  seqs <- tapply(seq_len(nrow(s)), s$patient_id, function(ix) {
    v <- rep("End", max_line); ln <- s$lot_num[ix]
    keep <- ln <= max_line; v[ln[keep]] <- s$lot_soc[ix][keep]; v
  })
  mat <- do.call(rbind, seqs)
  stages <- lapply(seq_len(max_line - 1L), function(l) {
    tb <- as.data.frame(table(From = mat[, l], To = mat[, l + 1L]),
                        stringsAsFactors = FALSE)
    tb <- tb[tb$Freq > 0 & tb$From != "End", , drop = FALSE]  # once ended, stays
    if (nrow(tb)) tb$stage <- l
    tb
  })
  list(trans = do.call(rbind, stages), max_line = max_line, n = nrow(mat))
}

# Multi-column alluvial: one node column per line, ribbons between adjacent
# lines with width ~ patient count; colour by the source SOC.
lot_pathway_sankey <- function(pd,
    title = "1L -> 4L treatment pathway (commercial only)") {
  if (is.null(pd) || is.null(pd$trans) || !nrow(pd$trans)) {
    plot.new(); text(0.5, 0.5, "No pathway data for the current cohort."); return(invisible()) }
  L <- pd$max_line; tr <- pd$trans
  xs <- seq(0.12, 0.88, length.out = L)
  # node y-position per (line, category)
  node_y <- function(line) {
    cats <- if (line == 1L) sort(unique(tr$From[tr$stage == 1L]))
            else sort(unique(tr$To[tr$stage == line - 1L]))
    setNames(seq_along(cats) / (length(cats) + 1), cats)
  }
  ys <- lapply(seq_len(L), node_y)
  all_cats <- sort(unique(c(tr$From, tr$To)))
  ccol <- setNames(grDevices::adjustcolor(
    SANKEY_COLS[(seq_along(all_cats) - 1) %% length(SANKEY_COLS) + 1], 0.5), all_cats)
  op <- par(mar = c(1, 1, 2.5, 1)); on.exit(par(op))
  plot(NA, xlim = c(0, 1), ylim = c(0, 1), axes = FALSE, xlab = "", ylab = "", main = title)
  wmax <- max(tr$Freq)
  for (i in seq_len(nrow(tr))) {
    l <- tr$stage[i]
    y1 <- ys[[l]][tr$From[i]]; y2 <- ys[[l + 1L]][tr$To[i]]
    if (is.na(y1) || is.na(y2)) next
    segments(xs[l], y1, xs[l + 1L], y2, lwd = 1 + 9 * tr$Freq[i] / wmax,
             col = ccol[tr$From[i]])
  }
  for (l in seq_len(L)) {
    y <- ys[[l]]; if (!length(y)) next
    points(rep(xs[l], length(y)), y, pch = 15, cex = 1.3, col = ccol[names(y)])
    text(xs[l], y, labels = names(y), pos = if (l == L) 2 else 4, cex = 0.7, xpd = NA)
    mtext(paste0(l, "L"), side = 3, at = xs[l], line = -0.5, cex = 0.85)
  }
  invisible()
}
