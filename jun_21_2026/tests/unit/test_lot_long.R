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
mem <- data.frame(patient_id = "9000000051", obs_end_dt = "2021-12-31", stringsAsFactors = FALSE)

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
