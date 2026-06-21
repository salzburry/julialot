# engine: LOT2-5 loop (LOT_LONG). A 3-line patient (LENA -> DARA -> CARF), each line
# triggering the next from the prior line's end event, run through the FULL chain
# MAP -> LOT1 -> LOT1 end -> LOT_LONG. Hand-derived expected.
source("engine/map.R"); source("engine/lot1.R"); source("engine/sct.R")
source("engine/lot_end.R"); source("engine/lot_long.R")

ph <- data.frame(patient_id = "9000000051",
  service_date = c("2021-01-01", "2021-01-25", "2021-02-18", "2021-03-14",   # LENA (extends past 60d)
                   "2021-03-15", "2021-04-08", "2021-05-02", "2021-05-26",   # DARA (the LOT1 add -> LOT2)
                   "2021-06-01"),                                            # CARF (the LOT2 add -> LOT3)
  normalized_code = c(rep("L", 4), rep("D", 4), "C"), code_system = "NDC",
  days_supply = "30", stringsAsFactors = FALSE)
rollup <- data.frame(code_type = "NDC", code = c("L", "D", "C"),
  med_abbr = c("LENA", "DARA", "CARF"), med_class = c("IMID", "MAB", "PI"), stringsAsFactors = FALSE)
mem <- data.frame(patient_id = "9000000051", index_date = "2020-06-01", obs_end_dt = "2021-12-31", stringsAsFactors = FALSE)

map <- build_map_stacked(ph, data.frame(), rollup, mem)
l1  <- build_lot1_base(map, mem)
le  <- build_lot1_end(l1, NULL, mem, NULL, map_stacked = map,
         auto_dates = data.frame(patient_id = character(0), tx_dt = as.Date(character(0))))
ll  <- build_lot_long(l1, le, map, NULL, mem)

eq(nrow(ll), 3L, "three lines of therapy derived, then the loop stops (no 4th trigger)")
r1 <- ll[ll$lot_num == 1, ]; r2 <- ll[ll$lot_num == 2, ]; r3 <- ll[ll$lot_num == 3, ]
ok(r1$lot_base_meds == "LENA" && r1$lot_base_end_reason == "MED_ADD" &&
   as.character(r1$lot_base_end_dt) == "2021-03-14", "LOT1 LENA ends MED_ADD (DARA added)")
ok(r2$lot_start_type == "MED" && r2$lot_base_meds == "DARA" &&
   as.character(r2$lot_start_dt) == "2021-03-15" && r2$lot_base_end_reason == "MED_ADD" &&
   as.character(r2$lot_base_end_dt) == "2021-05-31",
   "LOT2 = DARA (triggered by the LOT1 add), ends MED_ADD (CARF)")
ok(r3$lot_base_meds == "CARF" && as.character(r3$lot_start_dt) == "2021-06-01" &&
   r3$lot_base_end_reason == "DISCONTINUATION" && as.character(r3$lot_base_end_dt) == "2021-06-30",
   "LOT3 = CARF, ends DISCONTINUATION (runout)")
eq(as.integer(r2$lot_base_length), 78L, "LOT2 length = end - start + 1")
ok(all(ll$lot_num == c(1, 2, 3)), "lines are numbered 1..3 in order")

# candidate type tie-break: ALLO on the same day as a MED -> SCT_ALLO wins
ct <- .lot_candidates(
  data.frame(med_abbr = "X", med_class = "IMID", map_start_dt = as.Date("2021-05-01")),
  allo = as.Date("2021-05-01"), cart = as.Date(character(0)), autos = as.Date(character(0)),
  prev_end = as.Date("2021-04-01"), prev_meds = "LENA", prev_start = as.Date("2021-01-01"),
  prev_type = "MED", obs = as.Date("2021-12-31"), subs = NULL,
  induction_window_days = 30L, cart_consolidation_days = 45L, sct_tandem_days = 180L)
ok(ct$type == "SCT_ALLO" && as.character(ct$start) == "2021-05-01",
   "same-day candidate tie-break: SCT_ALLO > MED")

# line-scoped SCT: a MED-started LOT2 with a later ALLO ends SCT_ALLO (not at runout);
# the ALLO then starts a single-day LOT3
lb <- data.frame(patient_id = "9000000061", lot1_start_dt = "2021-01-01", lot1_med_cnt = 1L,
  lot1_base_meds = "LENA", lot1_base_discon_dt = "2021-04-30",
  lot1_base_1st_add_med_dt = "2021-03-14", lot1_base_1st_add_med = "DARA", stringsAsFactors = FALSE)
le <- data.frame(patient_id = "9000000061", lot1_base_end_dt = "2021-03-14",
  lot1_base_end_reason = "MED_ADD", lot1_base_length = 73L, stringsAsFactors = FALSE)
mp <- data.frame(patient_id = "9000000061", med_abbr = c("LENA", "DARA"), med_class = c("IMID", "MAB"),
  map_cnt = 1L, map_start_dt = c("2021-01-01", "2021-03-15"), map_end_dt = c("2021-04-30", "2021-07-12"),
  stringsAsFactors = FALSE)
sctc <- data.frame(patient_id = "9000000061", dt = "2021-05-01", sct_type = "ALLO", stringsAsFactors = FALSE)
memx <- data.frame(patient_id = "9000000061", index_date = "2020-06-01", obs_end_dt = "2021-12-31", stringsAsFactors = FALSE)
llx <- build_lot_long(lb, le, mp, sctc, memx)
x2 <- llx[llx$lot_num == 2, ]; x3 <- llx[llx$lot_num == 3, ]
ok(x2$lot_start_type == "MED" && x2$lot_base_meds == "DARA" && x2$lot_base_end_reason == "SCT_ALLO" &&
   as.character(x2$lot_base_end_dt) == "2021-04-30",
   "MED-started LOT2 with a later ALLO ends SCT_ALLO (line-scoped SCT)")
ok(x3$lot_start_type == "SCT_ALLO" && x3$lot_base_end_reason == "SCT_ALLO" &&
   as.character(x3$lot_base_end_dt) == "2021-05-01" && x3$lot_base_length == 1 && x3$lot_allo_lot_flg == 1,
   "ALLO starts a single-day LOT (ends on the ALLO date)")
ok(all(c("lot_allo_lot_flg", "contains_mtx_reg", "lot_base_end_dt_ce_sens", "lot_tx_auto_flg",
         "lot_tx_auto_dt_1") %in% names(llx)), "LOT_LONG carries the full contract columns (incl. SCT flags + CE-sens)")
