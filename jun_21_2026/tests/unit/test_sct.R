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
