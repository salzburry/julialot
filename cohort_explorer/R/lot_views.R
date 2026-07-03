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

SANKEY_COLS <- c("#E8480C","#0E7C7B","#5B4B8A","#2F6DB5","#B5179E",
                 "#3F8F4F","#C9A227","#8A6D3B","#4C5866","#D1495B")

# ---- alluvial drawing primitives (base graphics, no deps) --------------------
# smootherstep-interpolated S-curve band between a source edge (x1, y1t..y1b) and
# a target edge (x2, y2t..y2b), filled + faintly outlined. This is what gives the
# pathway its curved-ribbon look instead of straight segments.
.ribbon <- function(x1, y1t, y1b, x2, y2t, y2b, col, npt = 34L) {
  t <- seq(0, 1, length.out = npt)
  s <- t * t * t * (t * (t * 6 - 15) + 10)         # smootherstep
  x <- x1 + (x2 - x1) * t
  yt <- y1t + (y2t - y1t) * s
  yb <- y1b + (y2b - y1b) * s
  polygon(c(x, rev(x)), c(yt, rev(yb)), col = col,
          border = grDevices::adjustcolor(col, alpha.f = 1), lwd = 0.4)
}

# solid vertical node block with a soft edge.
.node_block <- function(x, top, bot, w, col) {
  rect(x - w, bot, x + w, top, col = col, border = "#FFFFFF", lwd = 1.1)
}

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

# Multi-column alluvial with STACKED nodes (height ~ patient count) and CURVED
# gradient ribbons. One node column per line; a single global scale means one
# patient is the same thickness everywhere, so attrition shows as shorter columns.
lot_pathway_sankey <- function(pd,
    title = "1L -> 4L treatment pathway (commercial only)") {
  if (is.null(pd) || is.null(pd$trans) || !nrow(pd$trans)) {
    plot.new(); text(0.5, 0.5, "No pathway data for the current cohort.",
                     col = "#5B6472"); return(invisible()) }
  L <- pd$max_line; tr <- pd$trans[pd$trans$Freq > 0, , drop = FALSE]
  xs <- seq(0.11, 0.89, length.out = L)
  colw <- min(0.018, 0.34 / L); gap <- 0.018; topm <- 0.10; botm <- 0.04

  # per-column category sizes: outflow at col 1, inflow at cols 2..L
  colcats <- vector("list", L)
  for (l in seq_len(L)) {
    ix <- if (l == 1L) tr$stage == 1L else tr$stage == l - 1L
    key <- if (l == 1L) tr$From[ix] else tr$To[ix]
    agg <- tapply(tr$Freq[ix], key, sum)
    agg <- agg[order(-agg)]
    colcats[[l]] <- agg
  }
  maxtot <- max(vapply(colcats, function(a) sum(a), numeric(1)), 1)
  avail  <- 1 - topm - botm
  scale  <- (avail - (max(lengths(colcats)) - 1) * gap) / maxtot
  if (!is.finite(scale) || scale <= 0) scale <- avail / maxtot

  # node vertical extents per column (centred), + running out/in offsets
  nodes <- lapply(seq_len(L), function(l) {
    a <- colcats[[l]]; k <- length(a); if (!k) return(NULL)
    h <- as.numeric(a) * scale
    blk <- sum(h) + (k - 1) * gap
    top <- numeric(k)
    y <- botm + (avail + blk) / 2                    # top of the first (largest) node, column centred
    for (i in seq_len(k)) { top[i] <- y; y <- y - h[i] - gap }
    data.frame(cat = names(a), top = top, bot = top - h,
               out = top, `in` = top, check.names = FALSE, stringsAsFactors = FALSE)
  })
  all_cats <- unique(unlist(lapply(nodes, function(n) if (!is.null(n)) n$cat)))
  ccol <- setNames(SANKEY_COLS[(seq_along(all_cats) - 1) %% length(SANKEY_COLS) + 1], all_cats)

  op <- par(mar = c(4.2, 1, 3, 1)); on.exit(par(op))
  plot(NA, xlim = c(0, 1), ylim = c(0, 1), axes = FALSE, xlab = "", ylab = "")
  title(main = title, col.main = "#1A1F2B", font.main = 1, cex.main = 1.05, line = 1)

  # ribbons: for each stage, order source outflows by the target's vertical pos so
  # bands stack cleanly; consume source `out` and target `in` offsets by Freq.
  for (l in seq_len(L - 1L)) {
    src <- nodes[[l]]; tgt <- nodes[[l + 1L]]; if (is.null(src) || is.null(tgt)) next
    st <- tr[tr$stage == l, , drop = FALSE]
    st$ty <- tgt$top[match(st$To, tgt$cat)]
    st <- st[order(match(st$From, src$cat), -st$ty), ]
    for (i in seq_len(nrow(st))) {
      si <- match(st$From[i], src$cat); ti <- match(st$To[i], tgt$cat)
      if (is.na(si) || is.na(ti)) next
      hh <- st$Freq[i] * scale
      s_top <- src$out[si]; src$out[si] <- s_top - hh
      t_top <- tgt$`in`[ti]; tgt$`in`[ti] <- t_top - hh
      .ribbon(xs[l] + colw, s_top, s_top - hh, xs[l + 1L] - colw, t_top, t_top - hh,
              grDevices::adjustcolor(ccol[st$From[i]], alpha.f = 0.42))
    }
    nodes[[l]] <- src; nodes[[l + 1L]] <- tgt
  }

  # node blocks + line headers on top of the ribbons. Interior category names are
  # carried by the colour legend (below) to avoid overlap; the terminal "End"
  # node is labelled in-place since it dominates later columns.
  for (l in seq_len(L)) {
    n <- nodes[[l]]; if (is.null(n)) next
    for (i in seq_len(nrow(n))) {
      .node_block(xs[l], n$top[i], n$bot[i], colw, ccol[n$cat[i]])
      if (identical(n$cat[i], "End") && (n$top[i] - n$bot[i]) > 0.04)
        text(xs[l], (n$top[i] + n$bot[i]) / 2, "End", col = "#FFFFFF",
             cex = 0.6, font = 2, srt = 90, xpd = NA)
    }
    mtext(paste0(l, "L"), side = 3, at = xs[l], line = 0.1, cex = 0.95,
          col = "#1A1F2B", font = 2)
  }
  # colour legend (category identity) in the bottom margin
  leg <- all_cats[all_cats != "End"]
  legend(x = 0.5, y = -0.02, xjust = 0.5, yjust = 1, legend = leg,
         fill = ccol[leg], border = "#FFFFFF", bty = "n", cex = 0.62,
         ncol = min(3L, length(leg)), xpd = NA, text.col = "#3A414E")
  invisible()
}
