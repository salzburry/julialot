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

# Lightweight Sankey/flow plot (base graphics, no extra deps): left nodes =
# From SOC, right nodes = To SOC, ribbon width ~ transition count.
sankey_plot <- function(trans, title = "1L -> 2L SOC transitions (commercial only)") {
  if (is.null(trans) || !nrow(trans)) {
    plot.new(); text(0.5, 0.5, "No transitions for the current cohort."); return(invisible())
  }
  froms <- unique(trans$From); tos <- unique(trans$To)
  fy <- setNames(seq_along(froms) / (length(froms) + 1), froms)
  ty <- setNames(seq_along(tos)   / (length(tos) + 1),   tos)
  cols <- grDevices::adjustcolor(
    c("#E8480C","#1F8A8A","#6A4C93","#3A6EA5","#B5179E","#666666","#2E8B57","#D62828"),
    alpha.f = 0.55)
  fcol <- setNames(cols[(seq_along(froms) - 1) %% length(cols) + 1], froms)
  op <- par(mar = c(1, 1, 2.5, 1)); on.exit(par(op))
  plot(NA, xlim = c(0, 1), ylim = c(0, 1), axes = FALSE, xlab = "", ylab = "",
       main = title)
  wmax <- max(trans$Freq)
  for (i in seq_len(nrow(trans))) {
    segments(0.18, fy[trans$From[i]], 0.82, ty[trans$To[i]],
             lwd = 1 + 9 * trans$Freq[i] / wmax, col = fcol[trans$From[i]])
  }
  text(0.16, fy, labels = froms, pos = 2, cex = 0.8, xpd = NA)
  text(0.84, ty, labels = tos,   pos = 4, cex = 0.8, xpd = NA)
  points(rep(0.18, length(fy)), fy, pch = 15, cex = 1.4, col = fcol[froms])
  points(rep(0.82, length(ty)), ty, pch = 15, cex = 1.4, col = "#333333")
  mtext("1L", side = 3, at = 0.18, line = -0.5, cex = 0.9)
  mtext("2L", side = 3, at = 0.82, line = -0.5, cex = 0.9)
  invisible()
}
