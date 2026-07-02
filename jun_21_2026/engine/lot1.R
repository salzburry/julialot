#!/usr/bin/env Rscript
# engine/lot1.R - LOT1 induction builder from MAP_STACKED, faithful to
# the production 02_lot1.R steps S08-S10. LOCAL verification engine (see map.R).
#
#   LOT1_START_DT   = min(MAP_START_DT) over NON-STEROID classes (steroid-only
#                     patients get no LOT1).
#   induction meds  = non-steroid drugs whose MAP_START is within
#                     [LOT1_START, LOT1_START + induction_window_days - 1].
#   base_meds       = induction meds + permissible substitutes (steroids excluded).
#   LOT1_BASE_MEDS / _MED_CNT come from the INDUCTION meds (not the subs).
#   DISCON_DT       = max(MAP_END_DT) over base-med MAPs at/after LOT1_START,
#                     kept only when <= OBS_END_DT (else null).
#   first-add       = earliest non-base, non-steroid drug within
#                     [LOT1_START, coalesce(DISCON, OBS_END)]; date = MAP_START - 1.
#                     NOTE: production breaks a same-date tie with rand(42) (the
#                     med token is the excluded nondeterministic field). Here the
#                     tie-break is deterministic (min med); fixtures avoid ties so
#                     the result is identical either way.

build_lot1_base <- function(map_stacked, obs_end, permissible_subs = NULL,
                            induction_window_days = 60L) {
  empty <- data.frame(patient_id = character(0), lot1_start_dt = as.Date(character(0)),
    lot1_med_cnt = integer(0), lot1_base_meds = character(0),
    lot1_base_discon_dt = as.Date(character(0)), lot1_base_1st_add_med_dt = as.Date(character(0)),
    lot1_base_1st_add_med = character(0), stringsAsFactors = FALSE)
  ms <- map_stacked
  if (is.null(ms) || !nrow(ms)) return(empty)
  ms$map_start_dt <- as.Date(as.character(ms$map_start_dt))
  ms$map_end_dt   <- as.Date(as.character(ms$map_end_dt))
  ms$med_class    <- toupper(as.character(ms$med_class))
  oe   <- setNames(as.Date(as.character(obs_end$obs_end_dt)), as.character(obs_end$patient_id))
  subs <- NULL
  if (!is.null(permissible_subs) && nrow(permissible_subs))
    subs <- split(as.character(permissible_subs$substitute_med),
                  as.character(permissible_subs$original_med))

  nonster <- ms[ms$med_class != "STEROID", , drop = FALSE]
  rows <- lapply(split(seq_len(nrow(nonster)), nonster$patient_id), function(ix) {
    pm  <- nonster[ix, , drop = FALSE]; pid <- pm$patient_id[1]
    lot1_start <- min(pm$map_start_dt)
    win_end    <- lot1_start + (induction_window_days - 1L)
    ind        <- pm[pm$map_start_dt >= lot1_start & pm$map_start_dt <= win_end, , drop = FALSE]
    induction_meds <- sort(unique(ind$med_abbr))
    if (!length(induction_meds)) return(NULL)
    base_meds <- induction_meds
    if (!is.null(subs)) base_meds <- sort(unique(c(base_meds, unlist(subs[induction_meds]))))
    pm_all <- ms[ms$patient_id == pid & ms$med_abbr %in% base_meds & ms$map_start_dt >= lot1_start, , drop = FALSE]
    raw_discon <- if (nrow(pm_all)) max(pm_all$map_end_dt) else as.Date(NA)
    obs <- oe[[pid]]
    discon <- if (!is.na(raw_discon) && !is.na(obs) && raw_discon <= obs) raw_discon else as.Date(NA)
    upper <- if (!is.na(discon)) discon else obs
    cand <- pm[!(pm$med_abbr %in% base_meds) & pm$map_start_dt >= lot1_start &
               !is.na(upper) & pm$map_start_dt <= upper, , drop = FALSE]
    if (nrow(cand)) {
      cand <- cand[order(cand$map_start_dt, cand$med_abbr), , drop = FALSE]
      fa_dt <- cand$map_start_dt[1] - 1L; fa_med <- cand$med_abbr[1]
    } else { fa_dt <- as.Date(NA); fa_med <- NA_character_ }
    data.frame(patient_id = pid, lot1_start_dt = lot1_start, lot1_med_cnt = length(induction_meds),
      lot1_base_meds = paste(induction_meds, collapse = " "), lot1_base_discon_dt = discon,
      lot1_base_1st_add_med_dt = fa_dt, lot1_base_1st_add_med = fa_med, stringsAsFactors = FALSE)
  })
  out <- do.call(rbind, c(list(empty), rows))
  out[order(out$patient_id), , drop = FALSE]
}
