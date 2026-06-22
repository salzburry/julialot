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
# max_lot validated to the config contract [2,9]: < 2 fails fast (R's 2:1 is
# DESCENDING, not empty); max_lot=2 caps the loop at LOT2 for this 3-line cohort.
ok(inherits(try(build_lot_long(l1, le, map, NULL, mem, max_lot = 1L), silent = TRUE), "try-error"),
   "max_lot < 2 fails fast (no silent 2:1 descending loop)")
cap2 <- build_lot_long(l1, le, map, NULL, mem, max_lot = 2L)
ok(max(cap2$lot_num) == 2 && nrow(cap2) == 2L, "max_lot=2 caps the loop at LOT2")
ok(inherits(try(build_lot_long(l1, le, map, NULL, mem, max_lot = 2.9), silent = TRUE), "try-error"),
   "max_lot=2.9 is REJECTED (validated before coercion), not silently truncated to 2")
ok(inherits(try(build_lot_long(l1, le, map, NULL, mem, max_lot = "5.8"), silent = TRUE), "try-error"),
   "max_lot=\"5.8\" is rejected (non-whole-number)")

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
ok(setequal(names(llx), LOT_LONG_COLS), "LOT_LONG output == LOT_LONG_COLS (23 columns)")

# CE-sensitive end: a LOT ending after enddate_ce (with disenrollment) is capped to
# enddate_ce with reason DISENROLLMENT (the primary end is unchanged).
memce <- data.frame(patient_id = "9000000061", index_date = "2020-06-01", obs_end_dt = "2021-12-31",
  enddate_ce = "2021-03-01", enddate = "2021-12-31", stringsAsFactors = FALSE)
llce <- build_lot_long(lb, le, mp, NULL, memce)
c1 <- llce[llce$lot_num == 1, ]
ok(as.character(c1$lot_base_end_dt) == "2021-03-14" &&
   as.character(c1$lot_base_end_dt_ce_sens) == "2021-03-01" && c1$lot_base_end_reason_ce_sens == "DISENROLLMENT",
   "CE-sensitive end caps at enddate_ce with DISENROLLMENT (primary end unchanged)")

# CART-started LOT with NO consolidation agent ends on its start date (SCT_CART,
# single-day) - lot2_5_base.R:814-815/850-851. LOT1 LENA runs out, then a lone CART.
lbc <- data.frame(patient_id = "9000000081", lot1_start_dt = "2021-01-01", lot1_med_cnt = 1L,
  lot1_base_meds = "LENA", lot1_base_discon_dt = "2021-03-01",
  lot1_base_1st_add_med_dt = NA, lot1_base_1st_add_med = NA, stringsAsFactors = FALSE)
lec <- data.frame(patient_id = "9000000081", lot1_base_end_dt = "2021-03-01",
  lot1_base_end_reason = "DISCONTINUATION", lot1_base_length = 60L, stringsAsFactors = FALSE)
mpc <- data.frame(patient_id = "9000000081", med_abbr = "LENA", med_class = "IMID",
  map_cnt = 1L, map_start_dt = "2021-01-01", map_end_dt = "2021-03-01", stringsAsFactors = FALSE)
sctcart <- data.frame(patient_id = "9000000081", dt = "2021-05-01", sct_type = "CART", stringsAsFactors = FALSE)
memc <- data.frame(patient_id = "9000000081", index_date = "2020-06-01", obs_end_dt = "2021-12-31", stringsAsFactors = FALSE)
llc <- build_lot_long(lbc, lec, mpc, sctcart, memc)
cc2 <- llc[llc$lot_num == 2, ]
ok(nrow(llc) == 2 && cc2$lot_start_type == "CART" && cc2$lot_base_meds == "" && cc2$lot_med_cnt == 0 &&
   cc2$lot_base_end_reason == "SCT_CART" && as.character(cc2$lot_base_end_dt) == "2021-05-01" &&
   cc2$lot_base_length == 1 && cc2$lot_cart_lot_flg == 1,
   "CART-started LOT with no consolidation agent ends on its start date (SCT_CART, single-day)")

# CART death guard THROUGH build_lot_long (call-site wiring of the 45-day applicable
# window): LOT1 LENA runs out, a CART starts LOT2 with a CARF consolidation that runs
# out 2021-04-29, an AUTO lands 2021-05-06 (35d after the CART start, INSIDE the 45-day
# window), death 2021-05-19. The in-window AUTO is NOT a next-line trigger, so LOT2
# ends DEATH - a fixed 30-day window would (wrongly) end at the 04-29 runout.
lbg <- data.frame(patient_id = "9000000095", lot1_start_dt = "2021-01-01", lot1_med_cnt = 1L,
  lot1_base_meds = "LENA", lot1_base_discon_dt = "2021-03-01",
  lot1_base_1st_add_med_dt = NA, lot1_base_1st_add_med = NA, stringsAsFactors = FALSE)
leg <- data.frame(patient_id = "9000000095", lot1_base_end_dt = "2021-03-01",
  lot1_base_end_reason = "DISCONTINUATION", lot1_base_length = 60L, stringsAsFactors = FALSE)
mpg <- data.frame(patient_id = "9000000095", med_abbr = c("LENA", "CARF"), med_class = c("IMID", "PI"),
  map_cnt = 1L, map_start_dt = c("2021-01-01", "2021-04-10"), map_end_dt = c("2021-03-01", "2021-04-29"),
  stringsAsFactors = FALSE)
sctg <- data.frame(patient_id = "9000000095", dt = c("2021-04-01", "2021-05-06"),
  sct_type = c("CART", "AUTO"), stringsAsFactors = FALSE)
dthg <- data.frame(patient_id = "9000000095", death_dt = "2021-05-19", stringsAsFactors = FALSE)
memg <- data.frame(patient_id = "9000000095", index_date = "2020-06-01", obs_end_dt = "2021-12-31", stringsAsFactors = FALSE)
g2 <- build_lot_long(lbg, leg, mpg, sctg, memg, death = dthg)
g2 <- g2[g2$lot_num == 2, ]
ok(g2$lot_start_type == "CART" && g2$lot_base_end_reason == "DEATH" &&
   as.character(g2$lot_base_end_dt) == "2021-05-19",
   "CART LOT2 + in-45d-window AUTO + death -> DEATH (build_lot_long wires the CART window)")

# LOT_N AUTO window (integration): a MED LOT2 (DARA) whose coverage spans an AUTO.
# Outside the 30-day window -> the AUTO ENDS LOT2 (SCT_AUTO); inside -> in-line TX.
lba <- data.frame(patient_id = "9000000091", lot1_start_dt = "2021-01-01", lot1_med_cnt = 1L,
  lot1_base_meds = "LENA", lot1_base_discon_dt = "2021-04-30",
  lot1_base_1st_add_med_dt = "2021-03-14", lot1_base_1st_add_med = "DARA", stringsAsFactors = FALSE)
lea <- data.frame(patient_id = "9000000091", lot1_base_end_dt = "2021-03-14",
  lot1_base_end_reason = "MED_ADD", lot1_base_length = 73L, stringsAsFactors = FALSE)
mpa <- data.frame(patient_id = "9000000091", med_abbr = c("LENA", "DARA"), med_class = c("IMID", "MAB"),
  map_cnt = 1L, map_start_dt = c("2021-01-01", "2021-03-15"), map_end_dt = c("2021-04-30", "2021-07-12"),
  stringsAsFactors = FALSE)
mema <- data.frame(patient_id = "9000000091", index_date = "2020-06-01", obs_end_dt = "2021-12-31", stringsAsFactors = FALSE)
llao <- build_lot_long(lba, lea, mpa,
  data.frame(patient_id = "9000000091", dt = "2021-05-20", sct_type = "AUTO", stringsAsFactors = FALSE), mema)  # 66d after start
ao2 <- llao[llao$lot_num == 2, ]
ok(ao2$lot_start_type == "MED" && ao2$lot_base_meds == "DARA" && ao2$lot_base_end_reason == "SCT_AUTO" &&
   as.character(ao2$lot_base_end_dt) == "2021-05-19" && ao2$lot_tx_auto_flg == 0,
   "LOT_N: AUTO outside the 30-day window ends the MED line (SCT_AUTO), not an in-line transplant")
llai <- build_lot_long(lba, lea, mpa,
  data.frame(patient_id = "9000000091", dt = "2021-04-01", sct_type = "AUTO", stringsAsFactors = FALSE), mema)  # 17d after start
ai2 <- llai[llai$lot_num == 2, ]
ok(ai2$lot_base_end_reason == "DISCONTINUATION" && as.character(ai2$lot_base_end_dt) == "2021-07-12" &&
   ai2$lot_tx_auto_flg == 1 && as.character(ai2$lot_tx_auto_dt_1) == "2021-04-01",
   "LOT_N: AUTO inside the 30-day window is an in-line transplant (LOT2 still ends at runout)")

# Final LOT_LONG clamp (Step N.7): an AUTO INSIDE the window but AFTER the line's
# actual end (here an early runout) is dropped from the in-LOT AUTO fields, even
# though Step N.4 would window-accept it. DARA runs out at 2021-03-24; the AUTO is
# 2021-04-04 (20d after start < 30 window, but > the line end).
lbk <- data.frame(patient_id = "9000000092", lot1_start_dt = "2021-01-01", lot1_med_cnt = 1L,
  lot1_base_meds = "LENA", lot1_base_discon_dt = "2021-04-30",
  lot1_base_1st_add_med_dt = "2021-03-14", lot1_base_1st_add_med = "DARA", stringsAsFactors = FALSE)
lek <- data.frame(patient_id = "9000000092", lot1_base_end_dt = "2021-03-14",
  lot1_base_end_reason = "MED_ADD", lot1_base_length = 73L, stringsAsFactors = FALSE)
mpk <- data.frame(patient_id = "9000000092", med_abbr = c("LENA", "DARA"), med_class = c("IMID", "MAB"),
  map_cnt = 1L, map_start_dt = c("2021-01-01", "2021-03-15"), map_end_dt = c("2021-04-30", "2021-03-24"),
  stringsAsFactors = FALSE)
memk <- data.frame(patient_id = "9000000092", index_date = "2020-06-01", obs_end_dt = "2021-12-31", stringsAsFactors = FALSE)
llk <- build_lot_long(lbk, lek, mpk,
  data.frame(patient_id = "9000000092", dt = "2021-04-04", sct_type = "AUTO", stringsAsFactors = FALSE), memk)
k2 <- llk[llk$lot_num == 2, ]
ok(k2$lot_base_end_reason == "DISCONTINUATION" && as.character(k2$lot_base_end_dt) == "2021-03-24" &&
   k2$lot_tx_auto_flg == 0 && is.na(k2$lot_tx_auto_dt_1) && k2$lot_tx_auto_sing_flg == 0,
   "final clamp: an in-window AUTO after the line end (early runout) is dropped (FLG/DT_1/SING cleared)")

# allo_lot_span: an ALLO-started LOT is single-day by DEFAULT, but extend_to_next
# lets it run to the next event (here a later CART -> SCT_CART). lot2_5_base.R:662-665.
lbs <- data.frame(patient_id = "9000000101", lot1_start_dt = "2021-01-01", lot1_med_cnt = 1L,
  lot1_base_meds = "LENA", lot1_base_discon_dt = "2021-03-01",
  lot1_base_1st_add_med_dt = NA, lot1_base_1st_add_med = NA, stringsAsFactors = FALSE)
les <- data.frame(patient_id = "9000000101", lot1_base_end_dt = "2021-03-01",
  lot1_base_end_reason = "DISCONTINUATION", lot1_base_length = 60L, stringsAsFactors = FALSE)
mps <- data.frame(patient_id = "9000000101", med_abbr = "LENA", med_class = "IMID",
  map_cnt = 1L, map_start_dt = "2021-01-01", map_end_dt = "2021-03-01", stringsAsFactors = FALSE)
scts <- data.frame(patient_id = "9000000101", dt = c("2021-05-01", "2021-08-09"),
  sct_type = c("ALLO", "CART"), stringsAsFactors = FALSE)
mems <- data.frame(patient_id = "9000000101", index_date = "2020-06-01", obs_end_dt = "2021-12-31", stringsAsFactors = FALSE)
sd2 <- build_lot_long(lbs, les, mps, scts, mems)                       # default = single_day
g2 <- sd2[sd2$lot_num == 2, ]
ok(g2$lot_start_type == "SCT_ALLO" && g2$lot_base_end_reason == "SCT_ALLO" &&
   as.character(g2$lot_base_end_dt) == "2021-05-01" && g2$lot_base_length == 1,
   "allo_lot_span=single_day (default): ALLO LOT spans only its start date")
ex <- build_lot_long(lbs, les, mps, scts, mems, allo_lot_span = "extend_to_next")
e2 <- ex[ex$lot_num == 2, ]
ok(e2$lot_start_type == "SCT_ALLO" && e2$lot_base_end_reason == "SCT_CART" &&
   as.character(e2$lot_base_end_dt) == "2021-08-08" && e2$lot_base_length == 100 && e2$lot_allo_lot_flg == 1,
   "allo_lot_span=extend_to_next: ALLO LOT runs to the next event (later CART -> SCT_CART)")
# extend_to_next: a later MM agent (no induction window for ALLO) ends the ALLO LOT
# via MED_ADD and starts the next LOT - NOT absorbed to STUDY_END. lot2_5_base.R:410-419.
mpm <- data.frame(patient_id = "9000000101", med_abbr = c("LENA", "DARA"), med_class = c("IMID", "MAB"),
  map_cnt = 1L, map_start_dt = c("2021-01-01", "2021-06-01"), map_end_dt = c("2021-03-01", "2021-08-30"),
  stringsAsFactors = FALSE)
emm <- build_lot_long(lbs, les, mpm, data.frame(patient_id = "9000000101", dt = "2021-05-01",
  sct_type = "ALLO", stringsAsFactors = FALSE), mems, allo_lot_span = "extend_to_next")
m2 <- emm[emm$lot_num == 2, ]; m3 <- emm[emm$lot_num == 3, ]
ok(m2$lot_start_type == "SCT_ALLO" && m2$lot_base_end_reason == "MED_ADD" &&
   as.character(m2$lot_base_end_dt) == "2021-05-31" && m2$lot_allo_lot_flg == 1,
   "allo_lot_span=extend_to_next: a later MM agent ends the ALLO LOT via MED_ADD")
ok(nrow(emm) == 3 && m3$lot_start_type == "MED" && m3$lot_base_meds == "DARA" &&
   as.character(m3$lot_start_dt) == "2021-06-01",
   "extend_to_next: the agent that ended the ALLO LOT starts the next LOT (DARA)")

# contains_mtx_reg (S16b / Step N.5): the induction contains a valid maintenance subset
# (a MONO drug, or a DUAL pair both present + listed) PLUS an anchor drug outside it.
rmaint <- data.frame(code_type = "NDC", code = c("L", "D", "B", "X"),
  med_abbr = c("LENA", "DARA", "BORT", "DEX"), med_class = c("IMID", "MAB", "PI", "STEROID"),
  MONOMAINTENANCE = c("YES", "0", "0", "0"),
  DUALMAINTENANCEWITH = c("", "BORT", "", ""), stringsAsFactors = FALSE)
mm <- .maint_maps(rmaint)
ok("LENA" %in% mm$mono && identical(mm$dual$DARA, "BORT"), ".maint_maps parses MONOMAINTENANCE + DUALMAINTENANCEWITH")
ok(.contains_mtx_reg(c("LENA", "DARA"), mm) == 1L, "mono (LENA) + anchor (DARA) -> contains_mtx_reg=1")
ok(.contains_mtx_reg("LENA", mm) == 0L, "mono with NO anchor -> 0")
ok(.contains_mtx_reg(c("DARA", "BORT"), mm) == 0L, "dual PAIR alone (DARA+BORT), no anchor -> 0")
ok(.contains_mtx_reg(c("DARA", "BORT", "LENA"), mm) == 1L, "dual (DARA+BORT) + anchor (LENA) -> 1")
ok(.contains_mtx_reg(c("BORT", "DEX"), mm) == 0L, "no maintenance drug in induction -> 0")
ok(.contains_mtx_reg(c("LENA", "DARA"), .maint_maps(rmaint[, 1:4])) == 0L, "no maintenance metadata -> 0")

# wiring: build_lot_long computes contains_mtx_reg from the rollup (LOT1 induction = DARA LENA)
lbm2 <- data.frame(patient_id = "9000000110", lot1_start_dt = "2021-01-01", lot1_med_cnt = 2L,
  lot1_base_meds = "DARA LENA", lot1_base_discon_dt = "2021-06-30",
  lot1_base_1st_add_med_dt = NA, lot1_base_1st_add_med = NA, stringsAsFactors = FALSE)
lem2 <- data.frame(patient_id = "9000000110", lot1_base_end_dt = "2021-06-30",
  lot1_base_end_reason = "DISCONTINUATION", lot1_base_length = 181L, stringsAsFactors = FALSE)
mpm2 <- data.frame(patient_id = "9000000110", med_abbr = c("LENA", "DARA"), med_class = c("IMID", "MAB"),
  map_cnt = 1L, map_start_dt = "2021-01-01", map_end_dt = "2021-06-30", stringsAsFactors = FALSE)
memm2 <- data.frame(patient_id = "9000000110", index_date = "2020-06-01", obs_end_dt = "2021-12-31", stringsAsFactors = FALSE)
ok(build_lot_long(lbm2, lem2, mpm2, NULL, memm2, rollup = rmaint)$contains_mtx_reg[1] == 1L,
   "build_lot_long wires the rollup -> contains_mtx_reg=1 (mono LENA + anchor DARA)")
ok(is.na(build_lot_long(lbm2, lem2, mpm2, NULL, memm2)$contains_mtx_reg[1]),
   "no maintenance evidence at the function boundary -> contains_mtx_reg=NA (not a silent clinical 0)")
ok(is.na(build_lot_long(lbm2, lem2, mpm2, NULL, memm2, rollup = rmaint[, 1:4])$contains_mtx_reg[1]),
   "a rollup WITHOUT maintenance columns is also 'unavailable' -> NA, not 0")
