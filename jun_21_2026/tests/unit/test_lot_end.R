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

# --- CART_INIT + post-runout death guard (ported branches) --------------------
lb2 <- data.frame(patient_id = sprintf("90000000%02d", 31:34), lot1_start_dt = "2021-01-01",
  lot1_base_meds = "LENA",
  lot1_base_1st_add_med_dt = c("2021-04-01", NA, NA, NA),
  lot1_base_discon_dt = c("2021-06-30", "2021-06-30", "2021-03-01", "2021-03-01"), stringsAsFactors = FALSE)
sct2 <- data.frame(patient_id = c("9000000031", "9000000032"),
  lot1_tx_enddate = "2021-04-19", lot1_tx_enddate_reason = 3L,
  first_cart_dt = "2021-04-20", first_allo_dt = NA, stringsAsFactors = FALSE)
obs2 <- data.frame(patient_id = sprintf("90000000%02d", 31:34), obs_end_dt = "2021-12-31", stringsAsFactors = FALSE)
death2 <- data.frame(patient_id = c("9000000033", "9000000034"), death_dt = "2021-05-01", stringsAsFactors = FALSE)
# P34 has a non-base DARA MAP AFTER the runout (a LOT2 trigger); P33 does not
ms2 <- data.frame(patient_id = c("9000000033", "9000000034", "9000000034"),
  med_abbr = c("LENA", "LENA", "DARA"), med_class = c("IMID", "IMID", "MAB"),
  map_start_dt = c("2021-01-01", "2021-01-01", "2021-04-01"), stringsAsFactors = FALSE)
r2 <- build_lot1_end(lb2, sct2, obs2, death2, map_stacked = ms2)
h <- function(p) r2[r2$patient_id == p, ]
ok(h("9000000031")$lot1_base_end_reason == "CART_INIT" && as.character(h("9000000031")$lot1_base_end_dt) == "2021-04-19",
   "MED_ADD then CART within 45d -> CART_INIT (end FIRST_CART-1)")
ok(h("9000000032")$lot1_base_end_reason == "SCT_CART" && as.character(h("9000000032")$lot1_base_end_dt) == "2021-04-19",
   "CART with no prior add -> SCT_CART (not CART_INIT)")
ok(h("9000000033")$lot1_base_end_reason == "DEATH" && as.character(h("9000000033")$lot1_base_end_dt) == "2021-05-01",
   "death, no post-runout trigger -> DEATH")
ok(h("9000000034")$lot1_base_end_reason == "DISCONTINUATION" && as.character(h("9000000034")$lot1_base_end_dt) == "2021-03-01",
   "death BUT a post-runout LOT2 trigger -> runout wins (DISCONTINUATION)")

# CART-started post-runout death guard uses the CART 45-day applicable window, NOT a
# fixed 30 days (lot2_5_base.R:721-727). CARC runs out day 20, an AUTO lands day 35
# (inside the CART window), death day 50. In-window AUTO is NOT a next-line trigger,
# so DEATH wins; the (wrong) 30-day window would flag it and end at runout instead.
lbC <- data.frame(patient_id = "9000000071", lot1_start_dt = "2021-01-01", lot1_base_meds = "CARC",
  lot1_base_1st_add_med_dt = NA, lot1_base_discon_dt = "2021-01-21", stringsAsFactors = FALSE)
oeC <- data.frame(patient_id = "9000000071", obs_end_dt = "2021-12-31", stringsAsFactors = FALSE)
dthC <- data.frame(patient_id = "9000000071", death_dt = "2021-02-20", stringsAsFactors = FALSE)   # day 50
mpC <- data.frame(patient_id = "9000000071", med_abbr = "CARC", med_class = "PI", map_cnt = 1L,
  map_start_dt = "2021-01-01", map_end_dt = "2021-01-21", stringsAsFactors = FALSE)
auC <- data.frame(patient_id = "9000000071", tx_dt = "2021-02-05", stringsAsFactors = FALSE)        # day 35
eC <- build_lot1_end(lbC, NULL, oeC, dthC, map_stacked = mpC, auto_dates = auC, lot_applicable_window_days = 45L)
ok(eC$lot1_base_end_reason == "DEATH" && as.character(eC$lot1_base_end_dt) == "2021-02-20",
   "CART line: post-runout AUTO inside the 45-day window does NOT suppress DEATH")
eM <- build_lot1_end(lbC, NULL, oeC, dthC, map_stacked = mpC, auto_dates = auC, lot_applicable_window_days = 30L)
ok(eM$lot1_base_end_reason == "DISCONTINUATION" && as.character(eM$lot1_base_end_dt) == "2021-01-21",
   "30-day window would (wrongly) flag the same AUTO as a trigger and end at runout")
