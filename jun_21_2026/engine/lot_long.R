#!/usr/bin/env Rscript
# engine/lot_long.R - LOT2-5 multi-line loop (LOT_LONG), faithful to
# apr_30_2026/R/lot2_5_base.R. Triggers each line from the PRIOR line's end event,
# re-derives the regimen, and repeats to MAX_LOT (5). LOCAL verification engine.
#
#   N.1 candidates (after PREV_END_DT, <= OBS_END):
#       d_MED  = earliest non-steroid agent, excl. permissible subs of prior drugs
#       d_ALLO = earliest ALLO ; d_CART = earliest CART
#       d_AUTO = earliest AUTO outside the prior LOT's window + not a planned tandem
#   N.2 LOT_N_START = least(candidates); TYPE by min (SCT_ALLO>CART>SCT_AUTO>MED).
#   N.3 regimen: induction in [start, start+win] (win: CART 44, else 29; ALLO=0),
#       base = induction + subs, discon = max base MAP_END <= OBS_END, first-add
#       AFTER the window; LOT_N end via the LOT1 cascade (build_lot1_end).
#
# Focus: MED-started lines (the common sequential-therapy path) with the full
# candidate selection for start/type. DOCUMENTED REFINEMENT (not yet
# synthetic-verified): ALLO/CART-singleton regimen specifics and the LOT-scoped SCT
# end fields (CE-sensitive end, in-LOT AUTO flags). The cohort is MED-started.

.lot_regimen <- function(ms_p, lot_start, start_type, obs, subs,
                         induction_window_days, cart_consolidation_days) {
  if (start_type == "SCT_ALLO")             # ALLO singleton: no MM regimen rows
    return(list(base_meds = "", med_cnt = 0L, discon = as.Date(NA),
                add_dt = as.Date(NA), add_med = NA_character_))
  win <- if (start_type == "CART") cart_consolidation_days - 1L else induction_window_days - 1L
  ind <- ms_p[ms_p$med_class != "STEROID" & ms_p$map_start_dt >= lot_start &
              ms_p$map_start_dt <= lot_start + win, , drop = FALSE]
  induction <- sort(unique(ind$med_abbr))
  base <- induction; if (!is.null(subs)) base <- sort(unique(c(base, unlist(subs[induction]))))
  dms <- ms_p[ms_p$med_abbr %in% base & ms_p$map_start_dt >= lot_start, , drop = FALSE]
  raw <- if (nrow(dms)) max(dms$map_end_dt) else as.Date(NA)
  discon <- if (!is.na(raw) && raw <= obs) raw else as.Date(NA)
  upper  <- if (!is.na(discon)) discon else obs
  cand <- ms_p[!(ms_p$med_abbr %in% base) & ms_p$med_class != "STEROID" &
               ms_p$map_start_dt > (lot_start + win) & ms_p$map_start_dt <= upper, , drop = FALSE]
  if (nrow(cand)) { cand <- cand[order(cand$map_start_dt, cand$med_abbr), , drop = FALSE]
    add_dt <- cand$map_start_dt[1] - 1L; add_med <- cand$med_abbr[1]
  } else { add_dt <- as.Date(NA); add_med <- NA_character_ }
  list(base_meds = paste(induction, collapse = " "), med_cnt = length(induction),
       discon = discon, add_dt = add_dt, add_med = add_med)
}

.lot_candidates <- function(ms_p, allo, cart, autos, prev_end, prev_meds, prev_start, prev_type,
                            obs, subs, induction_window_days, cart_consolidation_days, sct_tandem_days) {
  excl <- if (!is.null(subs)) unlist(subs[strsplit(prev_meds, " ")[[1]]]) else character(0)
  mc <- ms_p[ms_p$med_class != "STEROID" & ms_p$map_start_dt > prev_end & ms_p$map_start_dt <= obs &
             !(ms_p$med_abbr %in% excl), , drop = FALSE]
  d_MED  <- if (nrow(mc)) min(mc$map_start_dt) else as.Date(NA)
  d_ALLO <- { a <- allo[allo > prev_end & allo <= obs]; if (length(a)) min(a) else as.Date(NA) }
  d_CART <- { c <- cart[cart > prev_end & cart <= obs]; if (length(c)) min(c) else as.Date(NA) }
  prev_win <- switch(prev_type, "SCT_ALLO" = 0L, "CART" = cart_consolidation_days - 1L, induction_window_days - 1L)
  au <- sort(autos); pau <- if (length(au)) c(as.Date(NA), au[-length(au)]) else au
  qual <- au > prev_end & au <= obs & au > (prev_start + prev_win) &
          !(!is.na(pau) & as.integer(au - pau) <= sct_tandem_days)
  d_AUTO <- if (any(qual)) min(au[qual]) else as.Date(NA)
  cands <- c(d_MED, d_ALLO, d_CART, d_AUTO)
  if (all(is.na(cands))) return(NULL)
  m <- min(cands, na.rm = TRUE)
  type <- if (!is.na(d_ALLO) && d_ALLO == m) "SCT_ALLO"
          else if (!is.na(d_CART) && d_CART == m) "CART"
          else if (!is.na(d_AUTO) && d_AUTO == m) "SCT_AUTO" else "MED"
  list(start = m, type = type)
}

LOT_LONG_COLS <- c("patient_id", "lot_num", "lot_start_dt", "lot_start_type", "lot_base_meds",
  "lot_med_cnt", "lot_base_discon_dt", "lot_base_1st_add_med_dt", "lot_base_1st_add_med",
  "lot_base_end_dt", "lot_base_end_reason", "lot_base_length")

build_lot_long <- function(lot1_base, lot1_end, map_stacked, sct_claims = NULL,
                           obs_end, death = NULL, permissible_subs = NULL,
                           induction_window_days = 30L, cart_consolidation_days = 45L,
                           sct_tandem_days = 180L, sct_auto_window_days = 13L,
                           sct_auto_gap_days = 60L, max_lot = 5L) {
  D <- function(x) as.Date(as.character(x))
  oe <- setNames(D(obs_end$obs_end_dt), as.character(obs_end$patient_id))
  subs <- if (!is.null(permissible_subs) && nrow(permissible_subs))
    split(as.character(permissible_subs$substitute_med), as.character(permissible_subs$original_med)) else NULL
  ms <- map_stacked; ms$map_start_dt <- D(ms$map_start_dt); ms$map_end_dt <- D(ms$map_end_dt)
  ms$med_class <- toupper(as.character(ms$med_class)); ms$patient_id <- as.character(ms$patient_id)
  auto_all <- if (!is.null(sct_claims) && nrow(sct_claims))
    finalize_auto_per_patient(sct_claims, sct_auto_window_days, sct_auto_gap_days, sct_tandem_days)
    else data.frame(patient_id = character(0), tx_dt = as.Date(character(0)))
  sc_allo <- if (!is.null(sct_claims) && nrow(sct_claims)) sct_claims[sct_claims$sct_type == "ALLO", ] else NULL
  sc_cart <- if (!is.null(sct_claims) && nrow(sct_claims)) sct_claims[sct_claims$sct_type == "CART", ] else NULL

  row <- function(pid, ln, start, type, reg, end) data.frame(patient_id = pid, lot_num = ln,
    lot_start_dt = start, lot_start_type = type, lot_base_meds = reg$base_meds, lot_med_cnt = reg$med_cnt,
    lot_base_discon_dt = reg$discon, lot_base_1st_add_med_dt = reg$add_dt, lot_base_1st_add_med = reg$add_med,
    lot_base_end_dt = D(end$lot1_base_end_dt), lot_base_end_reason = end$lot1_base_end_reason,
    lot_base_length = end$lot1_base_length, stringsAsFactors = FALSE)

  out <- lapply(as.character(lot1_base$patient_id), function(pid) {
    obs <- oe[[pid]]; msp <- ms[ms$patient_id == pid, , drop = FALSE]
    autos <- sort(D(auto_all$tx_dt[as.character(auto_all$patient_id) == pid]))
    allo  <- if (!is.null(sc_allo)) sort(unique(D(sc_allo$dt[as.character(sc_allo$patient_id) == pid]))) else as.Date(character(0))
    cart  <- if (!is.null(sc_cart)) sort(unique(D(sc_cart$dt[as.character(sc_cart$patient_id) == pid]))) else as.Date(character(0))
    lb <- lot1_base[as.character(lot1_base$patient_id) == pid, ]; le <- lot1_end[as.character(lot1_end$patient_id) == pid, ]
    reg1 <- list(base_meds = lb$lot1_base_meds, med_cnt = as.integer(lb$lot1_med_cnt),
      discon = D(lb$lot1_base_discon_dt), add_dt = D(lb$lot1_base_1st_add_med_dt), add_med = as.character(lb$lot1_base_1st_add_med))
    rows <- list(row(pid, 1L, D(lb$lot1_start_dt), "MED", reg1,
      list(lot1_base_end_dt = le$lot1_base_end_dt, lot1_base_end_reason = le$lot1_base_end_reason, lot1_base_length = le$lot1_base_length)))
    prev_end <- D(le$lot1_base_end_dt); prev_meds <- lb$lot1_base_meds; prev_start <- D(lb$lot1_start_dt); prev_type <- "MED"
    for (ln in 2:max_lot) {
      if (is.na(prev_end)) break
      cd <- .lot_candidates(msp, allo, cart, autos, prev_end, prev_meds, prev_start, prev_type, obs, subs,
                            induction_window_days, cart_consolidation_days, sct_tandem_days)
      if (is.null(cd)) break
      reg <- .lot_regimen(msp, cd$start, cd$type, obs, subs, induction_window_days, cart_consolidation_days)
      lbn <- data.frame(patient_id = pid, lot1_start_dt = cd$start, lot1_base_meds = reg$base_meds,
        lot1_base_1st_add_med_dt = reg$add_dt, lot1_base_discon_dt = reg$discon, stringsAsFactors = FALSE)
      en <- build_lot1_end(lbn, NULL, obs_end, death, map_stacked = map_stacked,
                           auto_dates = auto_all, permissible_subs = permissible_subs,
                           cart_consolidation_days = cart_consolidation_days,
                           lot_n_induction_window_days = induction_window_days, sct_tandem_days = sct_tandem_days)
      rows[[length(rows) + 1L]] <- row(pid, ln, cd$start, cd$type, reg, en)
      prev_end <- D(en$lot1_base_end_dt); prev_meds <- reg$base_meds; prev_start <- cd$start; prev_type <- cd$type
    }
    do.call(rbind, rows)
  })
  do.call(rbind, out)
}
