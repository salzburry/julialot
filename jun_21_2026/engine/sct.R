#!/usr/bin/env Rscript
# engine/sct.R - Stem-cell-transplant detection, faithful to the production 02_lot1.R
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
# The tandem-boundary date-selection refinement is implemented in
# finalize_auto_dates (a window straddling the 180-day mark picks the
# boundary-closest date, for accurate tandem determination).

# Normalize SCT_TYPE the way production does: ALLO* -> ALLO, AUTO* -> AUTO,
# CAR-T/CART -> CART (anything else kept upper-cased).
.norm_sct_type <- function(x) {
  u <- toupper(trimws(as.character(x)))
  ifelse(startsWith(u, "ALLO"), "ALLO",
  ifelse(startsWith(u, "AUTO"), "AUTO",
  ifelse(u %in% c("CAR-T", "CART", "CAR_T"), "CART", u)))
}
# Normalize a code-system / code_type label to the canonical bucket (production
# S11): ICD10PCS->ICD10PROC, CPT->HCPCS, ICD diagnosis aliases -> ICD{9,10}DIAG.
.norm_code_type <- function(x) {
  u <- toupper(trimws(as.character(x)))
  ifelse(u %in% c("ICD10PROC", "ICD10PCS"), "ICD10PROC",
  ifelse(u == "ICD9PROC", "ICD9PROC",
  ifelse(u %in% c("ICD10DIAG", "ICD10DX", "DIAG10") | grepl("^ICD.*10.*DIAG", u), "ICD10DIAG",
  ifelse(u %in% c("ICD9DIAG", "ICD9DX", "ICD9", "DIAG9") | grepl("^ICD.*9.*DIAG", u), "ICD9DIAG",
  ifelse(grepl("PROC", u) | u == "ICD", "ICD10PROC",          # generic procedure aliases
  ifelse(u %in% c("DIAG", "DX", "DIAGNOSIS"), "ICD10DIAG",    # generic diagnosis aliases
  ifelse(u %in% c("CPT", "CPT4"), "HCPCS", u)))))))
}
# Detect SCT evidence across the canonical entities that carry codes: procedure
# (ICD9/10 PROC + HCPCS), diagnosis (ICD9/10 DIAG), medical (HCPCS/CPT). Matches on
# (normalized code_system, code) against the SCT codelist; type normalized to
# ALLO/AUTO/CART. Mirrors the four production evidence routes.
extract_sct_claims <- function(procedure = NULL, sct_codelist, diagnosis = NULL, medical = NULL) {
  empty <- data.frame(patient_id = character(0), dt = as.Date(character(0)), sct_type = character(0))
  nc <- function(code) toupper(gsub("[^A-Za-z0-9]", "", as.character(code)))
  ck <- paste(.norm_code_type(sct_codelist$code_type), nc(sct_codelist$code))
  ty <- setNames(.norm_sct_type(sct_codelist$sct_type), ck)
  pull <- function(df, date_col) {
    if (is.null(df) || !nrow(df)) return(NULL)
    k <- paste(.norm_code_type(df$code_system), nc(df$normalized_code)); keep <- k %in% ck
    if (!any(keep)) return(NULL)
    data.frame(patient_id = as.character(df$patient_id)[keep],
               dt = as.Date(as.character(df[[date_col]]))[keep],
               sct_type = unname(ty[k[keep]]), stringsAsFactors = FALSE)
  }
  res <- rbind(pull(procedure, "event_date"), pull(diagnosis, "event_date"), pull(medical, "service_date"))
  if (is.null(res)) return(empty)
  unique(res)
}

# AUTO window (datediff <= window_days, default 13) + 60-day gap merge -> finalized
# TX dates. Within a window the MAX date is taken, EXCEPT when the window straddles
# the 180-day tandem mark from the last finalized TX (boundary = last_tx + 179):
# then the date CLOSEST to that boundary is selected, for accurate tandem
# determination (02_lot1.R:1041-1128).
finalize_auto_dates <- function(dates, window_days = 13L, gap_days = 60L, tandem_days = 180L) {
  dates <- sort(unique(dates)); if (!length(dates)) return(as.Date(character(0)))
  tx <- as.Date(character(0)); cur_start <- NULL; cur_max <- NULL
  cur_bd <- as.Date(NA); cur_bdist <- NA_integer_; last_tx <- as.Date(NA)
  bdist <- function(x) abs(as.integer(x - (last_tx + (tandem_days - 1L))))   # |x - (last_tx+179)|
  open <- function(x) {                       # open a window; init boundary vs last_tx
    cur_start <<- x; cur_max <<- x
    if (!is.na(last_tx) && bdist(x) <= window_days) { cur_bd <<- x; cur_bdist <<- bdist(x) }
    else { cur_bd <<- as.Date(NA); cur_bdist <<- NA_integer_ }
  }
  finalize <- function() {
    sel <- if (!is.na(cur_bd)) cur_bd else cur_max          # boundary-closest, else max
    if (is.na(last_tx) || as.integer(sel - last_tx) >= gap_days) { tx <<- c(tx, sel); last_tx <<- sel }
  }
  for (i in seq_along(dates)) {
    x <- dates[i]
    if (is.null(cur_start)) { cur_start <- x; cur_max <- x; cur_bd <- as.Date(NA); cur_bdist <- NA_integer_ }
    else if (as.integer(x - cur_start) <= window_days) {    # within window
      cur_max <- x
      if (!is.na(last_tx) && bdist(x) <= window_days && (is.na(cur_bdist) || bdist(x) < cur_bdist)) {
        cur_bd <- x; cur_bdist <- bdist(x) }
    } else { finalize(); open(x) }                          # new window (boundary vs new last_tx)
  }
  if (!is.null(cur_start)) finalize()
  tx
}

# Finalized AUTO TX dates per patient (tx_auto_dates) - input the post-runout death
# guard + LOT2+ triggers need. Production's source arms are already restricted to
# the observation window, so AUTO dates are SCOPED to [index_date, OBS_END] BEFORE
# windowing (a post-OBS claim must not skew the window-max/tandem selection).
finalize_auto_per_patient <- function(sct_claims, members = NULL, window_days = 13L, gap_days = 60L, tandem_days = 180L) {
  a <- sct_claims[sct_claims$sct_type == "AUTO", , drop = FALSE]
  if (!is.null(members) && nrow(a)) a <- scope_to_window(a, members)
  if (!nrow(a)) return(data.frame(patient_id = character(0), tx_dt = as.Date(character(0))))
  do.call(rbind, lapply(unique(a$patient_id), function(p) {
    d <- finalize_auto_dates(a$dt[a$patient_id == p], window_days, gap_days, tandem_days)
    if (length(d)) data.frame(patient_id = p, tx_dt = d, stringsAsFactors = FALSE) else NULL
  }))
}

# Per-patient SCT summary within a line (S15 for LOT1; Step N.4 for LOT_N).
# lot_window_days = the LOT applicable window (NA for LOT1 = no window, the first
# AUTO is induction; LOT_N = 30/45/1): an AUTO_DT_1 at/after that many days from the
# start is NOT in-line - its TX fields clear and it becomes the ENDING_AUTO that
# closes the line. allo_cart_strict = TRUE (LOT_N) uses `> start` for ALLO/CART so
# the line's own start SCT is not treated as its end. tie_priority selects the
# SAME-DAY end-reason order: "lot1" = AUTO>ALLO>CART (02_lot1.R:1327-1338); "lotn" =
# ALLO>CART>AUTO (lot2_5_base.R:776-791). auto_dt_2 is reported only when it is a
# valid in-line tandem for LOT_N (Step N.4); LOT1 reports the raw 2nd AUTO (S15).
build_sct_summary <- function(sct_claims, lot1_start, obs_end,
                              tandem_days = 180L, window_days = 13L, gap_days = 60L,
                              lot_window_days = NA_integer_, allo_cart_strict = FALSE,
                              tie_priority = c("lot1", "lotn")) {
  tie_priority <- match.arg(tie_priority)
  ls <- setNames(as.Date(as.character(lot1_start$lot1_start_dt)), as.character(lot1_start$patient_id))
  oe <- setNames(as.Date(as.character(obs_end$obs_end_dt)), as.character(obs_end$patient_id))
  idx <- if ("index_date" %in% names(obs_end))
    setNames(as.Date(as.character(obs_end$index_date)), as.character(obs_end$patient_id)) else NULL
  rows <- lapply(names(ls), function(pid) {
    L <- ls[[pid]]; O <- if (pid %in% names(oe)) oe[[pid]] else as.Date(NA)
    if (length(O) == 0 || is.na(L) || is.na(O)) return(NULL)   # fail-closed: drop NA/unbounded patients (like MAP)
    sc <- sct_claims[sct_claims$patient_id == pid, , drop = FALSE]
    # SCT claims are scoped to [index_date, OBS_END] BEFORE windowing (production
    # S12), so a post-observation claim cannot become a window max and skew a TX.
    lo <- if (!is.null(idx)) idx[[pid]] else as.Date(NA)
    sc <- sc[(is.na(lo) | sc$dt >= lo) & (is.na(O) | sc$dt <= O), , drop = FALSE]
    auto_tx <- finalize_auto_dates(sc$dt[sc$sct_type == "AUTO"], window_days, gap_days, tandem_days)
    allo <- sort(unique(sc$dt[sc$sct_type == "ALLO"])); cart <- sort(unique(sc$dt[sc$sct_type == "CART"]))
    inw <- function(d) d[!is.na(d) & (if (allo_cart_strict) d > L else d >= L) & d <= O]
    first_allo <- if (length(inw(allo))) min(inw(allo)) else as.Date(NA)
    first_cart <- if (length(inw(cart))) min(inw(cart)) else as.Date(NA)
    ena <- suppressWarnings(min(c(first_allo, first_cart), na.rm = TRUE))
    if (is.infinite(ena)) ena <- as.Date(NA)
    auto_in <- sort(auto_tx[auto_tx >= L & auto_tx <= O & (is.na(ena) | auto_tx < ena)])
    d1 <- if (length(auto_in) >= 1) auto_in[1] else as.Date(NA)
    d2 <- if (length(auto_in) >= 2) auto_in[2] else as.Date(NA)
    d3 <- if (length(auto_in) >= 3) auto_in[3] else as.Date(NA)
    n_allo_between <- if (!is.na(d2)) sum(allo >= d1 & allo <= d2) else 0L
    tandem0 <- !is.na(d2) && as.integer(d2 - d1) <= tandem_days && n_allo_between == 0L
    # LOT applicable window (Step N.4, lot2_5_base.R:555-610): for LOT_N the first
    # AUTO is in-line only if `datediff(AUTO_DT_1, start) < lot_window_days`; the
    # first AUTO outside that window is NOT in-line (TX fields clear, flags 0) and
    # instead becomes the ENDING_AUTO that closes the line. LOT1 = NA window = the
    # first AUTO is always the induction transplant (in-line), never an end trigger.
    in_win <- is.na(lot_window_days) || (!is.na(d1) && as.integer(d1 - L) < lot_window_days)
    tandem <- in_win && tandem0
    sing <- in_win && !is.na(d1) && !tandem0
    rep_d1 <- if (in_win) d1 else as.Date(NA)
    # auto_dt_2 is an in-line 2nd transplant ONLY for a valid tandem under LOT_N
    # (Step N.4); LOT1 (NA window) reports the raw 2nd AUTO (S15, 02_lot1.R:1268).
    rep_d2 <- if (in_win && (is.na(lot_window_days) || tandem0)) d2 else as.Date(NA)
    ending_auto <- if (is.na(d1)) as.Date(NA) else if (!in_win) d1 else if (tandem0) d3 else d2
    cands <- c(AUTO = ending_auto, ALLO = first_allo, CART = first_cart)
    if (all(is.na(cands))) { end_dt <- as.Date(NA); reason <- NA_integer_ } else {
      SENT <- as.Date("9999-12-31"); a <- cands["AUTO"]; al <- cands["ALLO"]; ca <- cands["CART"]
      a[is.na(a)] <- SENT; al[is.na(al)] <- SENT; ca[is.na(ca)] <- SENT
      end_dt <- min(a, al, ca) - 1L
      # Same-day tie order is line-specific in production: LOT1 AUTO>ALLO>CART; LOT_N
      # ALLO>CART>AUTO. NOTE the AUTO branch only matters on an AUTO==ALLO/CART tie,
      # which is UNREACHABLE: ALLO/CART censor any same-day-or-later AUTO (above), so
      # ending_auto is strictly before first ALLO/CART. We still mirror production's
      # distinct LOT_N order for faithfulness (the ALLO-vs-CART tie -> ALLO in both).
      reason <- if (tie_priority == "lotn") {
        if (al <= ca && al <= a) 2L else if (ca <= a) 3L else 1L
      } else if (a <= al && a <= ca) 1L else if (al <= ca) 2L else 3L
    }
    data.frame(patient_id = pid, auto_dt_1 = rep_d1, auto_dt_2 = rep_d2,
               tand_flg = as.integer(tandem), sing_flg = as.integer(sing),
               ending_auto_dt = ending_auto, first_allo_dt = first_allo, first_cart_dt = first_cart,
               lot1_tx_enddate = end_dt, lot1_tx_enddate_reason = reason, stringsAsFactors = FALSE)
  })
  do.call(rbind, rows)
}
