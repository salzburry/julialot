# engine: LOT1 end cascade (SCT > MED_ADD > DEATH > DISCONTINUATION > STUDY_END,
# each gated against the regimen runout). Inline synthetic cases, hand-derived.
source("engine/lot_end.R")
pid <- sprintf("90000000%02d", 21:28)
lb <- data.frame(patient_id = pid, lot1_start_dt = "2021-01-01",
  lot1_base_1st_add_med_dt = c(NA, NA, "2021-04-01", "2021-05-01", "2021-05-01", NA, NA, NA),
  lot1_base_discon_dt = c("2021-06-30", "2021-06-30", "2021-06-30", "2021-06-30", "2021-03-01", NA, NA, "2021-03-01"),
  stringsAsFactors = FALSE)
sct <- data.frame(patient_id = c("9000000022", "9000000024", "9000000028"),
  lot1_tx_enddate = c("2021-03-31", "2021-03-31", "2021-05-31"),
  lot1_tx_enddate_reason = c(2L, 1L, 1L), stringsAsFactors = FALSE)
obs <- data.frame(patient_id = pid, obs_end_dt = "2021-12-31", stringsAsFactors = FALSE)
death <- data.frame(patient_id = "9000000027", death_dt = "2021-05-01", stringsAsFactors = FALSE)
r <- build_lot1_end(lb, sct, obs, death)
g <- function(p) r[r$patient_id == p, ]
chk <- function(p, reason, end, msg) ok(g(p)$lot1_base_end_reason == reason &&
  as.character(g(p)$lot1_base_end_dt) == end, msg)

chk("9000000021", "DISCONTINUATION", "2021-06-30", "discon only -> DISCONTINUATION")
chk("9000000022", "SCT_ALLO", "2021-03-31", "SCT (ALLO) before discon -> SCT_ALLO")
chk("9000000023", "MED_ADD", "2021-04-01", "first-add before discon -> MED_ADD")
chk("9000000024", "SCT_AUTO", "2021-03-31", "SCT before the add -> SCT wins over MED_ADD")
chk("9000000025", "DISCONTINUATION", "2021-03-01", "add AFTER discon -> falls back to DISCONTINUATION")
chk("9000000026", "STUDY_END", "2021-12-31", "no discon/SCT/add -> STUDY_END (OBS_END)")
chk("9000000027", "DEATH", "2021-05-01", "death within observation -> DEATH")
chk("9000000028", "DISCONTINUATION", "2021-03-01", "SCT AFTER discon does not fire -> DISCONTINUATION")
eq(as.integer(g("9000000021")$lot1_base_length), 181L, "length = end - start + 1 (DISCON)")
eq(as.integer(g("9000000026")$lot1_base_length), 365L, "length spans the full year (STUDY_END)")
