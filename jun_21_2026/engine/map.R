#!/usr/bin/env Rscript
# engine/map.R - LOCAL, pure-R re-implementation of the MAP (medication-available
# period) builder, faithful to apr_30_2026/02_lot1.R (the Spark `aggregate`
# runout state machine), STEP-for-STEP.
#
# PURPOSE: verification only. It runs on synthetic fixtures locally so we can see
# the refactor reproduce the documented behaviour without a warehouse. It is NOT
# the production engine (production is Databricks SQL over hive_metastore) and it
# never ships (engine/ is outside the prod allowlist; fixtures are synthetic).
#
# It is deliberately MODULAR + CONFIG-DRIVEN: codelist (code -> MED_ABBR) and the
# params are DATA, so "fix it for new NDC/HCPCS codes" is a fixture edit, not code.

.MIN_DATE <- as.Date("1900-01-01")               # Spark `min_date` sentinel
.dadd  <- function(d, n) d + as.integer(n)       # date_add(d, n)
.ddiff <- function(a, b) as.integer(a - b)       # datediff(a, b) = a - b (days)
.gmax  <- function(...) { v <- c(...); v <- v[!is.na(v)]; if (!length(v)) .MIN_DATE else max(v) }

# Map canonical pharmacy + medical claims to (MED_ABBR, MED_CLASS) via the rollup
# codelist keyed on (code_system, normalized_code). Unmapped codes are dropped
# (not MM agents). days_supply: pharmacy as-is; medical imputed to the default
# where null/<1. Returns one row per claim: patient_id, med_abbr, med_class, dt,
# type, ds.
map_claims <- function(pharmacy, medical, rollup, medical_day_supply = 28L) {
  key <- function(cs, code) paste(toupper(trimws(as.character(cs))), toupper(trimws(as.character(code))))
  rk <- key(rollup$code_type, rollup$code)
  ab <- setNames(as.character(rollup$med_abbr), rk); cl <- setNames(as.character(rollup$med_class), rk)
  mk <- function(df, type, ds) {
    if (is.null(df) || !nrow(df)) return(NULL)
    k <- key(df$code_system, df$normalized_code); keep <- k %in% rk
    if (!any(keep)) return(NULL)
    data.frame(patient_id = as.character(df$patient_id)[keep], med_abbr = unname(ab[k[keep]]),
               med_class = unname(cl[k[keep]]), dt = as.Date(as.character(df$service_date))[keep],
               type = type, ds = ds[keep], stringsAsFactors = FALSE)
  }
  ph_ds <- suppressWarnings(as.integer(pharmacy$days_supply))
  md_ds <- suppressWarnings(as.integer(medical$day_supply)); md_ds[is.na(md_ds) | md_ds < 1L] <- medical_day_supply
  rbind(mk(pharmacy, "pharmacy", ph_ds), mk(medical, "medical", md_ds))
}

# The runout state machine for ONE (patient, med) claim stream. Mirrors the Spark
# aggregate: sort by (dt, pharmacy-before-medical); CASE1 open the first MAP; CASE2
# a claim beyond both runouts closes the MAP and opens a new one; CASE3 updates
# runouts (rx pushout / reset, medical never pushed out); finalize flushes the last.
.map_periods <- function(cl) {
  cl <- cl[order(cl$dt, ifelse(cl$type == "pharmacy", 0L, 1L)), , drop = FALSE]
  maps <- list(); cnt <- 0L; start <- NULL; rx <- as.Date(NA); med <- as.Date(NA)
  flush <- function() {
    end <- .gmax(rx, med)
    maps[[length(maps) + 1L]] <<- data.frame(MAP_CNT = cnt, MAP_START_DT = start,
      MAP_RX_RUNOUT_DT = rx, MAP_MED_RUNOUT_DT = med,
      MAP_END_DT = if (end == .MIN_DATE) as.Date(NA) else end, stringsAsFactors = FALSE)
  }
  open <- function(dt, type, ds) {
    start <<- dt
    rx  <<- if (type == "pharmacy") .dadd(dt, ds - 1L) else as.Date(NA)
    med <<- if (type == "medical")  .dadd(dt, ds - 1L) else as.Date(NA)
  }
  for (i in seq_len(nrow(cl))) {
    dt <- cl$dt[i]; type <- cl$type[i]; ds <- cl$ds[i]
    if (is.null(start)) { cnt <- 1L; open(dt, type, ds)                 # CASE 1
    } else if (dt > .gmax(rx, med)) { flush(); cnt <- cnt + 1L; open(dt, type, ds)  # CASE 2
    } else {                                                            # CASE 3
      if (type == "pharmacy") {
        rx <- if (is.na(rx)) .dadd(dt, ds - 1L)
              else if (dt <= rx) .dadd(rx, ds)        # pharmacy within coverage -> PUSHOUT
              else .dadd(dt, ds - 1L)                 # after rx_runout, still in MAP -> RESET
      } else {
        med <- if (is.na(med)) .dadd(dt, ds - 1L) else .gmax(med, .dadd(dt, ds - 1L))  # no pushout
      }
    }
  }
  if (!is.null(start)) flush()
  do.call(rbind, maps)
}

# Build MAP_STACKED for every (patient, med), then the discontinuation flag: a gap
# to the next MAP (or to OBS_END_DT for the last MAP) >= map_discon_gap_days.
# Returns the canonical MAP_STACKED columns (see contracts/outputs.md).
build_map_stacked <- function(pharmacy, medical, rollup, obs_end,
                              map_discon_gap_days = 90L, medical_day_supply = 28L) {
  empty <- data.frame(patient_id = character(0), med_abbr = character(0), med_class = character(0),
    map_cnt = integer(0), map_start_dt = as.Date(character(0)), map_rx_runout_dt = as.Date(character(0)),
    map_med_runout_dt = as.Date(character(0)), map_end_dt = as.Date(character(0)),
    map_med_type = character(0), map_med_class = character(0), map_discon_flg = integer(0),
    stringsAsFactors = FALSE)
  claims <- map_claims(pharmacy, medical, rollup, medical_day_supply)
  if (is.null(claims) || !nrow(claims)) return(empty)
  oe <- setNames(as.Date(as.character(obs_end$obs_end_dt)), as.character(obs_end$patient_id))
  parts <- split(claims, list(claims$patient_id, claims$med_abbr), drop = TRUE)
  rows <- lapply(parts, function(cl) {
    per <- .map_periods(cl); per <- per[!is.na(per$MAP_END_DT), , drop = FALSE]
    if (!nrow(per)) return(NULL)
    per <- per[order(per$MAP_CNT), , drop = FALSE]
    nxt <- c(per$MAP_START_DT[-1], as.Date(NA)); obs <- oe[[cl$patient_id[1]]]
    discon <- ifelse(!is.na(nxt), .ddiff(nxt, per$MAP_END_DT) >= map_discon_gap_days,
                     !is.na(obs) & .ddiff(obs, per$MAP_END_DT) >= map_discon_gap_days)
    data.frame(patient_id = cl$patient_id[1], med_abbr = cl$med_abbr[1], med_class = cl$med_class[1],
      map_cnt = per$MAP_CNT, map_start_dt = per$MAP_START_DT, map_rx_runout_dt = per$MAP_RX_RUNOUT_DT,
      map_med_runout_dt = per$MAP_MED_RUNOUT_DT, map_end_dt = per$MAP_END_DT,
      map_med_type = cl$med_abbr[1], map_med_class = cl$med_class[1],
      map_discon_flg = as.integer(discon), stringsAsFactors = FALSE)
  })
  out <- do.call(rbind, c(list(empty), rows))
  out[order(out$patient_id, out$med_abbr, out$map_cnt), , drop = FALSE]
}
