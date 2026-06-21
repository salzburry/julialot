# engine: SCT detection (AUTO 14-day window + 60-day gap + 180-day tandem,
# ALLO/CART censoring + LOT-end reason). Inline synthetic cases, hand-derived.
source("engine/sct.R")
mk <- function(pid, dt, type) data.frame(patient_id = pid, dt = as.Date(dt), sct_type = type, stringsAsFactors = FALSE)
claims <- do.call(rbind, list(
  mk("9000000011", "2021-03-01", "AUTO"),                                   # single AUTO
  mk("9000000012", "2021-03-01", "AUTO"), mk("9000000012", "2021-03-10", "AUTO"),  # 9d -> one window
  mk("9000000013", "2021-03-01", "AUTO"), mk("9000000013", "2021-08-01", "AUTO"),  # 153d -> tandem
  mk("9000000014", "2021-03-01", "AUTO"), mk("9000000014", "2021-10-01", "AUTO"),  # 214d -> excess
  mk("9000000015", "2021-04-01", "ALLO"),
  mk("9000000016", "2021-05-01", "CART"),
  mk("9000000017", "2021-03-01", "AUTO"), mk("9000000017", "2021-06-01", "ALLO"),  # ALLO censors AUTO
  mk("9000000018", "2021-03-01", "AUTO"), mk("9000000018", "2021-04-10", "AUTO"))) # 40d -> 60d merge
pids <- sprintf("90000000%02d", 11:18)
lot1 <- data.frame(patient_id = pids, lot1_start_dt = "2021-02-01", stringsAsFactors = FALSE)
obs  <- data.frame(patient_id = pids, obs_end_dt = "2021-12-31", stringsAsFactors = FALSE)
s <- build_sct_summary(claims, lot1, obs)
g <- function(pid) s[s$patient_id == pid, ]

ok(as.character(g("9000000011")$auto_dt_1) == "2021-03-01" && g("9000000011")$sing_flg == 1 &&
   is.na(g("9000000011")$lot1_tx_enddate_reason), "single AUTO: allowed, no LOT end")
eq(as.character(g("9000000012")$auto_dt_1), "2021-03-10", "two AUTO within 14d -> one window, MAX date")
ok(g("9000000013")$tand_flg == 1 && as.character(g("9000000013")$auto_dt_2) == "2021-08-01" &&
   is.na(g("9000000013")$lot1_tx_enddate_reason), "tandem AUTO (<=180d): allowed, no end")
ok(g("9000000014")$tand_flg == 0 && as.character(g("9000000014")$lot1_tx_enddate) == "2021-09-30" &&
   g("9000000014")$lot1_tx_enddate_reason == 1, "2nd non-tandem AUTO (>180d) ends LOT1 (reason AUTO)")
ok(as.character(g("9000000015")$lot1_tx_enddate) == "2021-03-31" && g("9000000015")$lot1_tx_enddate_reason == 2,
   "ALLO ends LOT1 (reason ALLO)")
ok(as.character(g("9000000016")$lot1_tx_enddate) == "2021-04-30" && g("9000000016")$lot1_tx_enddate_reason == 3,
   "CART ends LOT1 (reason CART)")
ok(as.character(g("9000000017")$auto_dt_1) == "2021-03-01" &&
   as.character(g("9000000017")$lot1_tx_enddate) == "2021-05-31" && g("9000000017")$lot1_tx_enddate_reason == 2,
   "ALLO censors later AUTO; ALLO ends LOT1")
ok(as.character(g("9000000018")$auto_dt_1) == "2021-03-01" && is.na(g("9000000018")$auto_dt_2),
   "two AUTO <60d apart merge to one TX")

# finalize_auto_dates direct
eq(length(finalize_auto_dates(as.Date(c("2021-03-01", "2021-03-10")))), 1L, "14-day window: 2 claims -> 1 TX")
eq(length(finalize_auto_dates(as.Date(c("2021-03-01", "2021-08-01")))), 2L, "153d apart -> 2 TX")
eq(length(finalize_auto_dates(as.Date(c("2021-03-01", "2021-04-10")))), 1L, "40d apart -> 60d merge -> 1 TX")
# AUTO window default is 13 (datediff <= 13), matching production config_lot.R:53.
# 03-15 is 14 days from 03-01 -> a NEW window (not 13), so the window-1 TX is 03-14.
eq(as.character(finalize_auto_dates(as.Date(c("2021-03-01", "2021-03-14", "2021-03-15")))), "2021-03-14",
   "AUTO window is 13 days (03-15 datediff 14 > 13 -> new window)")
# tandem-boundary: TX1=01-01 (boundary 06-29); window {06-28, 07-05} would take max
# 07-05 (185d > 180 -> NOT tandem), but the boundary-closest 06-28 is selected
# (178d <= 180 -> tandem). Verifies the refinement flips the outcome.
tb <- finalize_auto_dates(as.Date(c("2021-01-01", "2021-06-28", "2021-07-05")))
eq(as.character(tb[2]), "2021-06-28", "tandem-boundary picks boundary-closest date, not window max")
tbc <- do.call(rbind, list(mk("9000000019", "2021-01-01", "AUTO"),
  mk("9000000019", "2021-06-28", "AUTO"), mk("9000000019", "2021-07-05", "AUTO")))
sb <- build_sct_summary(tbc, data.frame(patient_id = "9000000019", lot1_start_dt = "2020-12-01"),
                        data.frame(patient_id = "9000000019", obs_end_dt = "2021-12-31"))
eq(sb$tand_flg, 1L, "tandem-boundary selection yields a valid tandem (178d <= 180d)")
# extract from canonical procedure rows via the SCT codelist
proc <- data.frame(patient_id = "9000000011", event_date = "2021-03-01",
                   normalized_code = "38241", code_system = "HCPCS", stringsAsFactors = FALSE)
cl <- data.frame(code_type = "HCPCS", code = "38241", sct_type = "Autologous", stringsAsFactors = FALSE)
ex <- extract_sct_claims(proc, cl)
ok(nrow(ex) == 1 && ex$sct_type == "AUTO", "SCT claim extracted + type normalized (Autologous->AUTO)")

# --- additional SCT coverage (per review) -------------------------------------
# a 3rd AUTO ends a valid tandem course (ENDING_AUTO = AUTO_DT_3)
t3 <- do.call(rbind, list(mk("9000000041", "2021-03-01", "AUTO"),
  mk("9000000041", "2021-06-01", "AUTO"), mk("9000000041", "2021-11-01", "AUTO")))
s3 <- build_sct_summary(t3, data.frame(patient_id = "9000000041", lot1_start_dt = "2021-01-01"),
  data.frame(patient_id = "9000000041", obs_end_dt = "2021-12-31"))
ok(s3$tand_flg == 1 && as.character(s3$lot1_tx_enddate) == "2021-10-31" && s3$lot1_tx_enddate_reason == 1,
   "tandem then 3rd AUTO -> 3rd AUTO ends LOT1 (reason AUTO)")
# an AUTO AFTER an ALLO is censored (not AUTO_DT_2)
t4 <- do.call(rbind, list(mk("9000000042", "2021-03-01", "AUTO"),
  mk("9000000042", "2021-06-01", "ALLO"), mk("9000000042", "2021-08-01", "AUTO")))
s4 <- build_sct_summary(t4, data.frame(patient_id = "9000000042", lot1_start_dt = "2021-01-01"),
  data.frame(patient_id = "9000000042", obs_end_dt = "2021-12-31"))
ok(as.character(s4$auto_dt_1) == "2021-03-01" && is.na(s4$auto_dt_2) && s4$lot1_tx_enddate_reason == 2,
   "AUTO after ALLO is censored; ALLO ends LOT1")
# OBS_END scoping: a post-observation claim in the same window must not replace the
# valid in-window window-max and then be excluded (the event must survive)
t5 <- do.call(rbind, list(mk("9000000043", "2021-06-28", "AUTO"), mk("9000000043", "2021-07-05", "AUTO")))
s5 <- build_sct_summary(t5, data.frame(patient_id = "9000000043", lot1_start_dt = "2021-01-01"),
  data.frame(patient_id = "9000000043", index_date = "2020-01-01", obs_end_dt = "2021-06-30"))
eq(as.character(s5$auto_dt_1), "2021-06-28", "post-OBS_END claim scoped out BEFORE windowing (in-window event survives)")
# diagnosis-coded SCT evidence + code-type normalization (ICD10DX alias)
diag <- data.frame(patient_id = "9000000099", event_date = "2021-03-01",
                   normalized_code = "Z9484", code_system = "ICD10DIAG", stringsAsFactors = FALSE)
cld <- data.frame(code_type = "ICD10DX", code = "Z94.84", sct_type = "Allogenic", stringsAsFactors = FALSE)
exd <- extract_sct_claims(procedure = NULL, sct_codelist = cld, diagnosis = diag)
ok(nrow(exd) == 1 && exd$sct_type == "ALLO", "diagnosis-coded SCT detected (ICD10DX alias -> ICD10DIAG)")
# CPT code_system normalized to HCPCS
procc <- data.frame(patient_id = "9000000099", event_date = "2021-03-01",
                    normalized_code = "38241", code_system = "CPT", stringsAsFactors = FALSE)
exc <- extract_sct_claims(procedure = procc, sct_codelist = data.frame(code_type = "HCPCS", code = "38241", sct_type = "Autologous"))
ok(nrow(exc) == 1 && exc$sct_type == "AUTO", "CPT code_system normalized to HCPCS matches codelist")

# --- LOT_N applicable window (Step N.4: lot_window_days + allo_cart_strict) --------
# The same AUTO is an in-line transplant when WITHIN the LOT window, but becomes the
# ENDING_AUTO (closes the line) when OUTSIDE it. lot2_5_base.R:555-610.
wlot <- data.frame(patient_id = "9000000044", lot1_start_dt = "2021-01-01", stringsAsFactors = FALSE)
wobs <- data.frame(patient_id = "9000000044", obs_end_dt = "2021-12-31", stringsAsFactors = FALSE)
auto_in  <- mk("9000000044", "2021-01-20", "AUTO")   # 19d after start (< 30 window)
auto_out <- mk("9000000044", "2021-03-01", "AUTO")   # 59d after start (>= 30 window)
wi <- build_sct_summary(auto_in, wlot, wobs, lot_window_days = 30L, allo_cart_strict = TRUE)
ok(as.character(wi$auto_dt_1) == "2021-01-20" && wi$sing_flg == 1 && wi$tand_flg == 0 &&
   is.na(wi$lot1_tx_enddate_reason),
   "LOT_N: AUTO within the applicable window is an in-line transplant (no line end)")
wo <- build_sct_summary(auto_out, wlot, wobs, lot_window_days = 30L, allo_cart_strict = TRUE)
ok(is.na(wo$auto_dt_1) && wo$sing_flg == 0 && wo$tand_flg == 0 &&
   as.character(wo$ending_auto_dt) == "2021-03-01" &&
   as.character(wo$lot1_tx_enddate) == "2021-02-28" && wo$lot1_tx_enddate_reason == 1,
   "LOT_N: first AUTO outside the window is NOT in-line -> it is the ENDING_AUTO (ends the line)")
wl1 <- build_sct_summary(auto_out, wlot, wobs)       # lot_window_days = NA (LOT1)
ok(as.character(wl1$auto_dt_1) == "2021-03-01" && wl1$sing_flg == 1 && is.na(wl1$lot1_tx_enddate_reason),
   "LOT1: the first AUTO is the induction transplant regardless of distance from start")
# allo_cart_strict: an ALLO on the line's own start date is its START (not its end)
sallo <- mk("9000000045", "2021-01-01", "ALLO")
slot <- data.frame(patient_id = "9000000045", lot1_start_dt = "2021-01-01", stringsAsFactors = FALSE)
sobs <- data.frame(patient_id = "9000000045", obs_end_dt = "2021-12-31", stringsAsFactors = FALSE)
ss <- build_sct_summary(sallo, slot, sobs, allo_cart_strict = TRUE)
ok(is.na(ss$first_allo_dt) && is.na(ss$lot1_tx_enddate_reason),
   "LOT_N: an ALLO on the start date is the line's start, not its end (strict > start)")
sl1 <- build_sct_summary(sallo, slot, sobs)          # LOT1 non-strict (>=)
ok(as.character(sl1$first_allo_dt) == "2021-01-01" && sl1$lot1_tx_enddate_reason == 2,
   "LOT1: an ALLO on the start date ends LOT1 (non-strict >=)")

# auto_dt_2 is reported only for a valid IN-LINE tandem under LOT_N (Step N.4); a
# non-tandem 2nd AUTO (the excess that ends the line) is NOT an in-line 2nd transplant.
nt <- do.call(rbind, list(mk("9000000048", "2021-01-10", "AUTO"), mk("9000000048", "2021-10-01", "AUTO")))  # 264d -> non-tandem
ntlot <- data.frame(patient_id = "9000000048", lot1_start_dt = "2021-01-01", stringsAsFactors = FALSE)
ntobs <- data.frame(patient_id = "9000000048", obs_end_dt = "2022-12-31", stringsAsFactors = FALSE)
ntn <- build_sct_summary(nt, ntlot, ntobs, lot_window_days = 30L, allo_cart_strict = TRUE, tie_priority = "lotn")
ok(as.character(ntn$auto_dt_1) == "2021-01-10" && is.na(ntn$auto_dt_2) && ntn$sing_flg == 1 && ntn$tand_flg == 0,
   "LOT_N: a non-tandem 2nd AUTO is NOT reported as auto_dt_2 (single, not tandem)")
nt1 <- build_sct_summary(nt, ntlot, ntobs)           # LOT1 reports the raw 2nd AUTO (S15)
ok(as.character(nt1$auto_dt_2) == "2021-10-01" && nt1$sing_flg == 1,
   "LOT1: the raw 2nd AUTO is reported as auto_dt_2 (unconditional S15)")

# Production uses a line-specific same-day tie order (LOT1 AUTO>ALLO>CART; LOT_N
# ALLO>CART>AUTO). But an AUTO end can never TIE an ALLO/CART end: ALLO/CART CENSOR
# any same-day-or-later AUTO (ending_auto is strictly before first ALLO/CART in both
# the engine and 02_lot1.R:1219 / lot2_5_base.R:510). So both orderings agree on
# every reachable input; the LOT_N order is mirrored for faithfulness. Here a
# same-day AUTO+ALLO: the AUTO is censored, the ALLO ends -> reason 2 either way.
tied <- do.call(rbind, list(mk("9000000049", "2021-01-11", "AUTO"),
  mk("9000000049", "2021-07-20", "AUTO"), mk("9000000049", "2021-07-20", "ALLO")))
tlot <- data.frame(patient_id = "9000000049", lot1_start_dt = "2021-01-01", stringsAsFactors = FALSE)
tobs <- data.frame(patient_id = "9000000049", obs_end_dt = "2021-12-31", stringsAsFactors = FALSE)
t1 <- build_sct_summary(tied, tlot, tobs)            # LOT1 ordering
tn <- build_sct_summary(tied, tlot, tobs, lot_window_days = 30L, allo_cart_strict = TRUE, tie_priority = "lotn")
ok(t1$lot1_tx_enddate_reason == 2 && tn$lot1_tx_enddate_reason == 2 &&
   as.character(t1$lot1_tx_enddate) == "2021-07-19" && as.character(tn$lot1_tx_enddate) == "2021-07-19" &&
   is.na(t1$auto_dt_2) && is.na(tn$auto_dt_2),
   "same-day AUTO is censored by the ALLO -> ALLO ends under BOTH orderings (AUTO tie unreachable)")
# LOT_N reason path is wired: an ALLO end yields 2, a CART end yields 3.
cn <- build_sct_summary(mk("9000000050", "2021-06-01", "CART"),
  data.frame(patient_id = "9000000050", lot1_start_dt = "2021-01-01", stringsAsFactors = FALSE),
  data.frame(patient_id = "9000000050", obs_end_dt = "2021-12-31", stringsAsFactors = FALSE),
  lot_window_days = 30L, allo_cart_strict = TRUE, tie_priority = "lotn")
ok(cn$lot1_tx_enddate_reason == 3 && as.character(cn$lot1_tx_enddate) == "2021-05-31",
   "LOT_N reason path: a CART end yields reason 3 (lotn ordering wired)")
