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
# extract from canonical procedure rows via the SCT codelist
proc <- data.frame(patient_id = "9000000011", event_date = "2021-03-01",
                   normalized_code = "38241", code_system = "HCPCS", stringsAsFactors = FALSE)
cl <- data.frame(code_type = "HCPCS", code = "38241", sct_type = "Autologous", stringsAsFactors = FALSE)
ex <- extract_sct_claims(proc, cl)
ok(nrow(ex) == 1 && ex$sct_type == "AUTO", "SCT claim extracted + type normalized (Autologous->AUTO)")
