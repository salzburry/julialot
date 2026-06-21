#!/usr/bin/env Rscript
# engine/lot_end.R - LOT1 end date + reason, faithful to apr_30_2026/02_lot1.R S16.
# LOCAL verification engine (see map.R/lot1.R/sct.R).
#
# End-reason cascade (highest priority wins, each gated so it only fires when its
# event is at/before the regimen runout DISCON):
#   SCT (AUTO/ALLO/CART)  - LOT1_TX_ENDDATE, when <= first-add and <= discon
#   MED_ADD               - first non-base add, when <= discon
#   DEATH                 - death within observation
#   DISCONTINUATION       - regimen runout (DISCON_DT)
#   STUDY_END             - else (OBS_END_DT; disenrollment is not censoring)
#
# DOCUMENTED LIMITATIONS (not yet ported / synthetic-verified): the CART_INIT
# special case (MED_ADD followed by a CART within cart_consolidation_days, ending
# the LOT at FIRST_CART_DT-1) and the post-runout-trigger guard (DEATH does not
# outrank DISCONTINUATION when a LOT2-qualifying trigger sits between runout and
# death). The fixtures below avoid those corners.

build_lot1_end <- function(lot1_base, sct_summary = NULL, obs_end, death = NULL) {
  if (is.null(lot1_base) || !nrow(lot1_base)) return(data.frame(
    patient_id = character(0), lot1_base_end_dt = as.Date(character(0)),
    lot1_base_end_reason = character(0), lot1_base_length = integer(0), stringsAsFactors = FALSE))
  D <- function(x) as.Date(as.character(x))
  oe  <- setNames(D(obs_end$obs_end_dt), as.character(obs_end$patient_id))
  dd  <- if (!is.null(death) && nrow(death)) setNames(D(death$death_dt), as.character(death$patient_id)) else character(0)
  sct <- if (!is.null(sct_summary) && nrow(sct_summary)) sct_summary else NULL
  SCT_REASON <- c("1" = "SCT_AUTO", "2" = "SCT_ALLO", "3" = "SCT_CART")

  rows <- lapply(seq_len(nrow(lot1_base)), function(i) {
    pid  <- as.character(lot1_base$patient_id[i])
    ls   <- D(lot1_base$lot1_start_dt[i])
    add  <- D(lot1_base$lot1_base_1st_add_med_dt[i])
    disc <- D(lot1_base$lot1_base_discon_dt[i])
    obs  <- oe[[pid]]; dth <- if (pid %in% names(dd)) dd[[pid]] else as.Date(NA)
    srow <- if (!is.null(sct)) sct[sct$patient_id == pid, , drop = FALSE] else NULL
    sct_end <- if (!is.null(srow) && nrow(srow)) D(srow$lot1_tx_enddate) else as.Date(NA)
    sct_rs  <- if (!is.null(srow) && nrow(srow)) srow$lot1_tx_enddate_reason else NA

    le_disc <- function(d) is.na(disc) || d <= disc
    if (!is.na(sct_end) && (is.na(add) || sct_end <= add) && le_disc(sct_end)) {
      reason <- unname(SCT_REASON[as.character(sct_rs)]); end <- sct_end
    } else if (!is.na(add) && le_disc(add)) {
      reason <- "MED_ADD"; end <- add
    } else if (!is.na(dth) && !is.na(obs) && dth <= obs) {
      reason <- "DEATH"; end <- dth
    } else if (!is.na(disc)) {
      reason <- "DISCONTINUATION"; end <- disc
    } else { reason <- "STUDY_END"; end <- obs }
    data.frame(patient_id = pid, lot1_base_end_dt = end, lot1_base_end_reason = reason,
               lot1_base_length = as.integer(end - ls) + 1L, stringsAsFactors = FALSE)
  })
  do.call(rbind, rows)
}
