#!/usr/bin/env Rscript
# engine/lot_end.R - LOT1 end date + reason, faithful to apr_30_2026/02_lot1.R S16.
# LOCAL verification engine (see map.R/lot1.R/sct.R).
#
# End-reason cascade (highest priority wins, each gated so it only fires when its
# event is at/before the regimen runout DISCON):
#   SCT (AUTO/ALLO/CART) - LOT1_TX_ENDDATE, when <= first-add (or first_cart-1 under
#                          CART_INIT) and <= discon; skipped when the SCT IS the CART
#                          and CART_INIT handles it.
#   CART_INIT            - MED_ADD followed by a CART within cart_consolidation_days
#                          (45) of the add start; ends the LOT at FIRST_CART_DT - 1.
#   MED_ADD              - first non-base add (no CART_INIT), when <= discon.
#   DEATH                - death within observation, UNLESS a post-runout LOT2
#                          trigger sits after the runout (then runout is the true end).
#   DISCONTINUATION      - regimen runout (DISCON_DT).
#   STUDY_END            - else (OBS_END_DT).
#
# CART_INIT and the post-runout-trigger guard need extra inputs (the SCT summary's
# first_cart/allo, map_stacked, finalized AUTO dates, permissible subs). When those
# are absent the function degrades to the core SCT/MED_ADD/DEATH/DISCON/STUDY_END
# cascade.

build_lot1_end <- function(lot1_base, sct_summary = NULL, obs_end, death = NULL,
                           map_stacked = NULL, auto_dates = NULL, permissible_subs = NULL,
                           cart_consolidation_days = 45L, lot_n_induction_window_days = 30L,
                           sct_tandem_days = 180L) {
  if (is.null(lot1_base) || !nrow(lot1_base)) return(data.frame(
    patient_id = character(0), lot1_base_end_dt = as.Date(character(0)),
    lot1_base_end_reason = character(0), lot1_base_length = integer(0), stringsAsFactors = FALSE))
  D <- function(x) as.Date(as.character(x))
  oe  <- setNames(D(obs_end$obs_end_dt), as.character(obs_end$patient_id))
  dd  <- if (!is.null(death) && nrow(death)) setNames(D(death$death_dt), as.character(death$patient_id)) else character(0)
  sct <- if (!is.null(sct_summary) && nrow(sct_summary)) sct_summary else NULL
  subs <- if (!is.null(permissible_subs) && nrow(permissible_subs))
    split(as.character(permissible_subs$substitute_med), as.character(permissible_subs$original_med)) else NULL
  ms <- if (!is.null(map_stacked) && nrow(map_stacked)) map_stacked else NULL
  if (!is.null(ms)) { ms$map_start_dt <- D(ms$map_start_dt); ms$med_class <- toupper(as.character(ms$med_class)) }
  adt <- if (!is.null(auto_dates) && nrow(auto_dates)) auto_dates else NULL
  SCT_REASON <- c("1" = "SCT_AUTO", "2" = "SCT_ALLO", "3" = "SCT_CART")

  rows <- lapply(seq_len(nrow(lot1_base)), function(i) {
    pid  <- as.character(lot1_base$patient_id[i])
    ls   <- D(lot1_base$lot1_start_dt[i]); add <- D(lot1_base$lot1_base_1st_add_med_dt[i])
    disc <- D(lot1_base$lot1_base_discon_dt[i])
    obs  <- oe[[pid]]; dth <- if (pid %in% names(dd)) dd[[pid]] else as.Date(NA)
    srow <- if (!is.null(sct)) sct[sct$patient_id == pid, , drop = FALSE] else NULL
    scol <- function(nm) if (!is.null(srow) && nrow(srow) && nm %in% names(srow)) srow[[nm]][1] else NA
    sct_end    <- D(scol("lot1_tx_enddate"))
    sct_rs     <- scol("lot1_tx_enddate_reason")
    first_cart <- D(scol("first_cart_dt"))
    first_allo <- D(scol("first_allo_dt"))

    cart_init <- !is.na(first_cart) && !is.na(add) &&
      { g <- as.integer(first_cart - (add + 1L)); g >= 0 && g <= cart_consolidation_days }

    prt <- 0L                                                    # post-runout LOT2 trigger
    if (!is.na(disc)) {
      prm <- FALSE
      if (!is.null(ms)) {
        induction <- strsplit(as.character(lot1_base$lot1_base_meds[i]), " ")[[1]]
        excluded  <- if (!is.null(subs)) unlist(subs[induction]) else character(0)
        prm <- any(as.character(ms$patient_id) == pid & ms$med_class != "STEROID" &
                   ms$map_start_dt > disc & ms$map_start_dt <= obs & !(ms$med_abbr %in% excluded))
      }
      pra <- FALSE
      if (!is.null(adt)) {
        ad <- sort(D(adt$tx_dt[as.character(adt$patient_id) == pid]))
        if (length(ad)) { prev <- c(as.Date(NA), ad[-length(ad)])
          pra <- any(ad > disc & ad <= obs & ad > (ls + (lot_n_induction_window_days - 1L)) &
                     !(!is.na(prev) & as.integer(ad - prev) <= sct_tandem_days)) }
      }
      prt <- as.integer(prm || (!is.na(first_allo) && first_allo > disc) ||
                        (!is.na(first_cart) && first_cart > disc) || pra)
    }

    le_disc <- function(d) is.na(disc) || d <= disc
    sct_is_cart3 <- cart_init && !is.na(sct_rs) && sct_rs == 3
    sct_fires <- !is.na(sct_end) && !sct_is_cart3 &&
      (is.na(add) || (cart_init && sct_end <= (first_cart - 1L)) || (!cart_init && sct_end <= add)) &&
      le_disc(sct_end)
    if (sct_fires) { reason <- unname(SCT_REASON[as.character(sct_rs)]); end <- sct_end }
    else if (cart_init && (is.na(disc) || (first_cart - 1L) <= disc)) { reason <- "CART_INIT"; end <- first_cart - 1L }
    else if (!is.na(add) && !cart_init && le_disc(add)) { reason <- "MED_ADD"; end <- add }
    else if (!is.na(dth) && !is.na(obs) && dth <= obs && prt == 0L) { reason <- "DEATH"; end <- dth }
    else if (!is.na(disc)) { reason <- "DISCONTINUATION"; end <- disc }
    else { reason <- "STUDY_END"; end <- obs }
    data.frame(patient_id = pid, lot1_base_end_dt = end, lot1_base_end_reason = reason,
               lot1_base_length = as.integer(end - ls) + 1L, stringsAsFactors = FALSE)
  })
  do.call(rbind, rows)
}
