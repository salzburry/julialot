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
#   N.4 LOT-scoped SCT: in-LOT AUTO iff within the applicable window (1/45/30);
#       first AUTO outside = ENDING_AUTO; ALLO/CART scoped `> start` (build_sct_summary).
#   N.6 special starts: ALLO single-day (or extend_to_next) + CART-no-med -> SCT_CART.
#   N.7 final projection: the in-LOT AUTO fields are CLAMPED to <= LOT_BASE_END_DT
#       and SING/TAND/MAX recomputed (the row() builder below).

.lot_regimen <- function(ms_p, lot_start, start_type, obs, subs,
                         induction_window_days, cart_consolidation_days, allo_extend = FALSE) {
  if (start_type == "SCT_ALLO") {           # ALLO: induction rows suppressed (lot2_5_base.R:352)
    if (!allo_extend)                        # single_day: ends on the ALLO date, add-med is moot
      return(list(base_meds = "", med_cnt = 0L, discon = as.Date(NA), add_dt = as.Date(NA), add_med = NA_character_))
    # extend_to_next: no induction window - the next MM agent strictly after the
    # ALLO date is the first-add that ends the LOT (lot2_5_base.R:410-419).
    cand <- ms_p[ms_p$med_class != "STEROID" & ms_p$map_start_dt > lot_start & ms_p$map_start_dt <= obs, , drop = FALSE]
    if (nrow(cand)) { cand <- cand[order(cand$map_start_dt, cand$med_abbr), , drop = FALSE]
      add_dt <- cand$map_start_dt[1] - 1L; add_med <- cand$med_abbr[1]
    } else { add_dt <- as.Date(NA); add_med <- NA_character_ }
    return(list(base_meds = "", med_cnt = 0L, discon = as.Date(NA), add_dt = add_dt, add_med = add_med))
  }
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
  "lot_base_end_dt", "lot_base_end_reason", "lot_base_length", "lot_allo_lot_flg",
  "lot_cart_lot_flg", "contains_mtx_reg", "lot_base_end_dt_ce_sens", "lot_base_end_reason_ce_sens",
  "lot_tx_auto_flg", "lot_tx_auto_tand_flg", "lot_tx_auto_sing_flg", "lot_tx_auto_dt_1",
  "lot_tx_auto_dt_2", "lot_tx_auto_max_dt")

# Line-scoped SCT summary for one line: SCT events within [start, OBS_END]. For a
# CART-started line the start CART is the trigger (not an end event) and is dropped.
# lot_window_days = the LOT applicable window (Step N.4): the first AUTO is in-line
# only within that many days of the start, else it is the ENDING_AUTO that closes
# the line (NA = LOT1 = no window). allo_cart_strict = TRUE (LOT_N) scopes ALLO/CART
# with `> start` so the line's own start SCT is not treated as its end.
.line_sct <- function(sct_claims, pid, lot_start, lot_type, obs_end, tandem, window, gap,
                      lot_window_days = NA_integer_, allo_cart_strict = FALSE, tie_priority = "lot1") {
  if (is.null(sct_claims) || !nrow(sct_claims)) return(NULL)
  sc <- sct_claims[sct_claims$patient_id == pid, , drop = FALSE]
  if (lot_type == "CART") sc <- sc[!(as.Date(as.character(sc$dt)) == lot_start & sc$sct_type == "CART"), , drop = FALSE]
  if (!nrow(sc)) return(NULL)
  build_sct_summary(sc, data.frame(patient_id = pid, lot1_start_dt = lot_start, stringsAsFactors = FALSE),
                    obs_end, tandem, window, gap, lot_window_days, allo_cart_strict, tie_priority)
}

# The LOT applicable window for a LOT_N start type (Step N.4 / lb CTE,
# lot2_5_base.R:477-481): 1 (SCT_ALLO) / cart_consolidation (CART) / induction (else).
.lot_window_days <- function(start_type, induction_window_days, cart_consolidation_days) {
  switch(start_type, "SCT_ALLO" = 1L, "CART" = cart_consolidation_days, induction_window_days)
}

build_lot_long <- function(lot1_base, lot1_end, map_stacked, sct_claims = NULL,
                           obs_end, death = NULL, permissible_subs = NULL,
                           induction_window_days = 30L, cart_consolidation_days = 45L,
                           sct_tandem_days = 180L, sct_auto_window_days = 13L,
                           sct_auto_gap_days = 60L, allo_lot_span = c("single_day", "extend_to_next"),
                           max_lot = 5L) {
  allo_lot_span <- match.arg(allo_lot_span)   # production default single_day (lot2_5_base.R:665)
  D <- function(x) as.Date(as.character(x))
  oe <- setNames(D(obs_end$obs_end_dt), as.character(obs_end$patient_id))
  ece <- if ("enddate_ce" %in% names(obs_end)) setNames(D(obs_end$enddate_ce), as.character(obs_end$patient_id)) else NULL
  ed  <- if ("enddate"    %in% names(obs_end)) setNames(D(obs_end$enddate),    as.character(obs_end$patient_id)) else NULL
  subs <- if (!is.null(permissible_subs) && nrow(permissible_subs))
    split(as.character(permissible_subs$substitute_med), as.character(permissible_subs$original_med)) else NULL
  ms <- map_stacked; ms$map_start_dt <- D(ms$map_start_dt); ms$map_end_dt <- D(ms$map_end_dt)
  ms$med_class <- toupper(as.character(ms$med_class)); ms$patient_id <- as.character(ms$patient_id)
  auto_all <- if (!is.null(sct_claims) && nrow(sct_claims))     # SCOPED before finalization
    finalize_auto_per_patient(sct_claims, obs_end, sct_auto_window_days, sct_auto_gap_days, sct_tandem_days)
    else data.frame(patient_id = character(0), tx_dt = as.Date(character(0)))
  sc_allo <- if (!is.null(sct_claims) && nrow(sct_claims)) sct_claims[sct_claims$sct_type == "ALLO", ] else NULL
  sc_cart <- if (!is.null(sct_claims) && nrow(sct_claims)) sct_claims[sct_claims$sct_type == "CART", ] else NULL

  # 23-column LOT_LONG contract. CE-sensitive end caps at enddate_ce (reason
  # DISENROLLMENT) when the line outlasts continuous enrollment. contains_mtx_reg
  # = 0 (EXCLUDED: needs maintenance metadata).
  row <- function(pid, ln, start, type, reg, end, lsct = NULL, ce = NULL) {
    ed_dt <- D(end$lot1_base_end_dt)
    # FINAL LOT_LONG AUTO clamp (Step N.7 / init, lot2_5_base.R:104-145, 923-960):
    # the line-scoped SCT view (lsct) collects through OBS_END and Step N.4 keeps
    # only window-eligible AUTOs, but the final projection ADDITIONALLY clamps each
    # in-LOT AUTO date to <= LOT_BASE_END_DT and RECOMPUTES SING/TAND/MAX from the
    # clamped dates. So an AUTO after the line actually ended (MED_ADD / CART_INIT /
    # DEATH / runout) is dropped; a within-LOT DT_1 whose DT_2 falls outside the LOT
    # collapses TAND->SING; MAX is the in-LOT tandem DT_2 else the in-LOT DT_1.
    has <- !is.null(lsct) && nrow(lsct)
    raw <- function(f) if (has) D(lsct[[f]][1]) else as.Date(NA)
    d1 <- raw("auto_dt_1"); d2 <- raw("auto_dt_2")
    in1 <- !is.na(d1) && !is.na(ed_dt) && d1 <= ed_dt
    in2 <- !is.na(d2) && !is.na(ed_dt) && d2 <= ed_dt
    cl_tand <- in2 && has && isTRUE(lsct$tand_flg[1] == 1)
    a_dt1 <- if (in1) d1 else as.Date(NA); a_dt2 <- if (in2) d2 else as.Date(NA)
    a_flg <- as.integer(in1); a_tand <- as.integer(cl_tand); a_sing <- as.integer(in1 && !cl_tand)
    a_max <- if (cl_tand) d2 else if (in1) d1 else as.Date(NA)
    ce_end <- ed_dt; ce_rs <- end$lot1_base_end_reason  # CE-sensitive end
    if (!is.null(ce) && !is.na(ce$enddate_ce) && !is.na(ed_dt) && ed_dt > ce$enddate_ce) {
      ce_end <- ce$enddate_ce
      if (!is.na(ce$enddate) && ce$enddate_ce < ce$enddate) ce_rs <- "DISENROLLMENT"
    }
    data.frame(patient_id = pid, lot_num = ln,
    lot_start_dt = start, lot_start_type = type, lot_base_meds = reg$base_meds, lot_med_cnt = reg$med_cnt,
    lot_base_discon_dt = reg$discon, lot_base_1st_add_med_dt = reg$add_dt, lot_base_1st_add_med = reg$add_med,
    lot_base_end_dt = ed_dt, lot_base_end_reason = end$lot1_base_end_reason,
    lot_base_length = end$lot1_base_length,
    lot_allo_lot_flg = as.integer(type == "SCT_ALLO"), lot_cart_lot_flg = as.integer(type == "CART"),
    contains_mtx_reg = 0L,                                # NOT computed: needs maintenance metadata
    lot_base_end_dt_ce_sens = ce_end, lot_base_end_reason_ce_sens = ce_rs,
    lot_tx_auto_flg = a_flg, lot_tx_auto_tand_flg = a_tand,
    lot_tx_auto_sing_flg = a_sing, lot_tx_auto_dt_1 = a_dt1,
    lot_tx_auto_dt_2 = a_dt2, lot_tx_auto_max_dt = a_max, stringsAsFactors = FALSE)
  }

  out <- lapply(as.character(lot1_base$patient_id), function(pid) {
    obs <- oe[[pid]]; msp <- ms[ms$patient_id == pid, , drop = FALSE]
    cep <- list(enddate_ce = if (!is.null(ece)) ece[[pid]] else as.Date(NA),
                enddate    = if (!is.null(ed))  ed[[pid]]  else as.Date(NA))
    autos <- sort(D(auto_all$tx_dt[as.character(auto_all$patient_id) == pid]))
    allo  <- if (!is.null(sc_allo)) sort(unique(D(sc_allo$dt[as.character(sc_allo$patient_id) == pid]))) else as.Date(character(0))
    cart  <- if (!is.null(sc_cart)) sort(unique(D(sc_cart$dt[as.character(sc_cart$patient_id) == pid]))) else as.Date(character(0))
    lb <- lot1_base[as.character(lot1_base$patient_id) == pid, ]; le <- lot1_end[as.character(lot1_end$patient_id) == pid, ]
    reg1 <- list(base_meds = lb$lot1_base_meds, med_cnt = as.integer(lb$lot1_med_cnt),
      discon = D(lb$lot1_base_discon_dt), add_dt = D(lb$lot1_base_1st_add_med_dt), add_med = as.character(lb$lot1_base_1st_add_med))
    lsct1 <- .line_sct(sct_claims, pid, D(lb$lot1_start_dt), "MED", obs_end, sct_tandem_days, sct_auto_window_days, sct_auto_gap_days)
    rows <- list(row(pid, 1L, D(lb$lot1_start_dt), "MED", reg1,
      list(lot1_base_end_dt = le$lot1_base_end_dt, lot1_base_end_reason = le$lot1_base_end_reason, lot1_base_length = le$lot1_base_length), lsct1, cep))
    prev_end <- D(le$lot1_base_end_dt); prev_meds <- lb$lot1_base_meds; prev_start <- D(lb$lot1_start_dt); prev_type <- "MED"
    for (ln in 2:max_lot) {
      if (is.na(prev_end)) break
      cd <- .lot_candidates(msp, allo, cart, autos, prev_end, prev_meds, prev_start, prev_type, obs, subs,
                            induction_window_days, cart_consolidation_days, sct_tandem_days)
      if (is.null(cd)) break
      if (cd$type == "SCT_ALLO" && allo_lot_span == "single_day") {   # ALLO single-day: ends on its start
        reg <- list(base_meds = "", med_cnt = 0L, discon = as.Date(NA), add_dt = as.Date(NA), add_med = NA_character_)
        en <- list(lot1_base_end_dt = cd$start, lot1_base_end_reason = "SCT_ALLO", lot1_base_length = 1L)
        lsct <- NULL
      } else {                                              # MED/CART/AUTO line (or extend_to_next ALLO)
        reg <- .lot_regimen(msp, cd$start, cd$type, obs, subs, induction_window_days, cart_consolidation_days,
                            allo_extend = (allo_lot_span == "extend_to_next"))
        win <- .lot_window_days(cd$type, induction_window_days, cart_consolidation_days)
        lsct <- .line_sct(sct_claims, pid, cd$start, cd$type, obs_end, sct_tandem_days,
                          sct_auto_window_days, sct_auto_gap_days, lot_window_days = win,
                          allo_cart_strict = TRUE, tie_priority = "lotn")
        if (cd$type == "CART" && reg$med_cnt == 0L) {          # CART, no consolidation agent: single-day line
          en <- list(lot1_base_end_dt = cd$start, lot1_base_end_reason = "SCT_CART", lot1_base_length = 1L)
        } else {
          lbn <- data.frame(patient_id = pid, lot1_start_dt = cd$start, lot1_base_meds = reg$base_meds,
            lot1_base_1st_add_med_dt = reg$add_dt, lot1_base_discon_dt = reg$discon, stringsAsFactors = FALSE)
          en <- build_lot1_end(lbn, lsct, obs_end, death, map_stacked = map_stacked,
                               auto_dates = auto_all, permissible_subs = permissible_subs,
                               cart_consolidation_days = cart_consolidation_days,
                               lot_n_induction_window_days = induction_window_days, sct_tandem_days = sct_tandem_days)
        }
      }
      rows[[length(rows) + 1L]] <- row(pid, ln, cd$start, cd$type, reg, en, lsct, cep)
      prev_end <- D(en$lot1_base_end_dt); prev_meds <- reg$base_meds; prev_start <- cd$start; prev_type <- cd$type
    }
    do.call(rbind, rows)
  })
  do.call(rbind, out)
}
