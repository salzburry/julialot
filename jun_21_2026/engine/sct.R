#!/usr/bin/env Rscript
# engine/sct.R - Stem-cell-transplant detection, faithful to apr_30_2026/02_lot1.R
# steps S12-S15. LOCAL verification engine (see map.R/lot1.R).
#
#   AUTO: group claims by `window_days` (13; datediff(x, window_start) <= 13), take
#         the MAX date per window, then merge windows < `gap_days` (60) from the
#         last finalized TX.
#         A 2nd AUTO within `tandem_days` (180) of the 1st (no ALLO between) is a
#         planned TANDEM. Excess AUTO ends LOT1 (single -> 2nd; tandem -> 3rd).
#   ALLO / CART: distinct sequential dates; the earliest CENSORS later AUTO and
#         immediately ends LOT1.
#   LOT1_TX_ENDDATE = earliest LOT-ending SCT event - 1; reason 1=AUTO 2=ALLO 3=CART.
#
# DOCUMENTED LIMITATION (not yet ported / synthetic-verified): the rare
# tandem-boundary date-selection refinement (when a 14-day window straddles the
# 180-day mark, production picks the boundary-closest date instead of the window
# max). The fixtures below avoid that corner; selection here is the window max.

# Normalize SCT_TYPE the way production does: ALLO* -> ALLO, AUTO* -> AUTO,
# CAR-T/CART -> CART (anything else kept upper-cased).
.norm_sct_type <- function(x) {
  u <- toupper(trimws(as.character(x)))
  ifelse(startsWith(u, "ALLO"), "ALLO",
  ifelse(startsWith(u, "AUTO"), "AUTO",
  ifelse(u %in% c("CAR-T", "CART", "CAR_T"), "CART", u)))
}
extract_sct_claims <- function(procedure, sct_codelist) {
  if (is.null(procedure) || !nrow(procedure)) return(data.frame(
    patient_id = character(0), dt = as.Date(character(0)), sct_type = character(0)))
  key <- function(cs, code) paste(toupper(trimws(as.character(cs))),
                                   toupper(gsub("[^A-Za-z0-9]", "", as.character(code))))
  ck <- key(sct_codelist$code_type, sct_codelist$code)
  ty <- setNames(.norm_sct_type(sct_codelist$sct_type), ck)
  k <- key(procedure$code_system, procedure$normalized_code); keep <- k %in% ck
  if (!any(keep)) return(data.frame(patient_id = character(0), dt = as.Date(character(0)), sct_type = character(0)))
  d <- data.frame(patient_id = as.character(procedure$patient_id)[keep],
                  dt = as.Date(as.character(procedure$event_date))[keep],
                  sct_type = unname(ty[k[keep]]), stringsAsFactors = FALSE)
  unique(d)
}

# AUTO window (datediff <= window_days, default 13) max-date + 60-day gap merge.
finalize_auto_dates <- function(dates, window_days = 13L, gap_days = 60L) {
  dates <- sort(unique(dates)); if (!length(dates)) return(as.Date(character(0)))
  tx <- as.Date(character(0)); cur_start <- NULL; cur_max <- NULL; last_tx <- NULL
  finalize <- function() {
    if (is.null(last_tx) || as.integer(cur_max - last_tx) >= gap_days) {
      tx <<- c(tx, cur_max); last_tx <<- cur_max }      # else < gap: merge (discard)
  }
  for (i in seq_along(dates)) {
    x <- dates[i]
    if (is.null(cur_start)) { cur_start <- x; cur_max <- x }
    else if (as.integer(x - cur_start) <= window_days) { cur_max <- x }   # within window
    else { finalize(); cur_start <- x; cur_max <- x }                     # new window
  }
  if (!is.null(cur_start)) finalize()
  tx
}

# Per-patient SCT summary within LOT1 (the S15 derivations).
build_sct_summary <- function(sct_claims, lot1_start, obs_end,
                              tandem_days = 180L, window_days = 13L, gap_days = 60L) {
  ls <- setNames(as.Date(as.character(lot1_start$lot1_start_dt)), as.character(lot1_start$patient_id))
  oe <- setNames(as.Date(as.character(obs_end$obs_end_dt)), as.character(obs_end$patient_id))
  rows <- lapply(names(ls), function(pid) {
    L <- ls[[pid]]; O <- oe[[pid]]
    sc <- sct_claims[sct_claims$patient_id == pid, , drop = FALSE]
    auto_tx <- finalize_auto_dates(sc$dt[sc$sct_type == "AUTO"], window_days, gap_days)
    allo <- sort(unique(sc$dt[sc$sct_type == "ALLO"])); cart <- sort(unique(sc$dt[sc$sct_type == "CART"]))
    inw <- function(d) d[!is.na(d) & d >= L & d <= O]
    first_allo <- if (length(inw(allo))) min(inw(allo)) else as.Date(NA)
    first_cart <- if (length(inw(cart))) min(inw(cart)) else as.Date(NA)
    ena <- suppressWarnings(min(c(first_allo, first_cart), na.rm = TRUE))
    if (is.infinite(ena)) ena <- as.Date(NA)
    auto_in <- sort(auto_tx[auto_tx >= L & auto_tx <= O & (is.na(ena) | auto_tx < ena)])
    d1 <- if (length(auto_in) >= 1) auto_in[1] else as.Date(NA)
    d2 <- if (length(auto_in) >= 2) auto_in[2] else as.Date(NA)
    d3 <- if (length(auto_in) >= 3) auto_in[3] else as.Date(NA)
    n_allo_between <- if (!is.na(d2)) sum(allo >= d1 & allo <= d2) else 0L
    tandem <- !is.na(d2) && as.integer(d2 - d1) <= tandem_days && n_allo_between == 0L
    sing <- !is.na(d1) && !tandem
    ending_auto <- if (tandem) d3 else if (!is.na(d1)) d2 else as.Date(NA)
    cands <- c(AUTO = ending_auto, ALLO = first_allo, CART = first_cart)
    if (all(is.na(cands))) { end_dt <- as.Date(NA); reason <- NA_integer_ } else {
      SENT <- as.Date("9999-12-31"); a <- cands["AUTO"]; al <- cands["ALLO"]; ca <- cands["CART"]
      a[is.na(a)] <- SENT; al[is.na(al)] <- SENT; ca[is.na(ca)] <- SENT
      end_dt <- min(a, al, ca) - 1L
      reason <- if (a <= al && a <= ca) 1L else if (al <= ca) 2L else 3L
    }
    data.frame(patient_id = pid, auto_dt_1 = d1, auto_dt_2 = d2,
               tand_flg = as.integer(tandem), sing_flg = as.integer(sing),
               ending_auto_dt = ending_auto, first_allo_dt = first_allo, first_cart_dt = first_cart,
               lot1_tx_enddate = end_dt, lot1_tx_enddate_reason = reason, stringsAsFactors = FALSE)
  })
  do.call(rbind, rows)
}
