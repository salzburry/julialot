# engine: the LOCAL pure-R re-implementation must reproduce the hand-derived
# expected MAP_STACKED and LOT1_BASE on the synthetic cohort (verifies the refactor
# logic end to end, MAP -> LOT1, including edge cases).
source("engine/map.R"); source("engine/lot1.R"); source("engine/sct.R"); source("engine/lot_end.R")
source("engine/run_engine.R")
.rd <- function(f) read.csv(file.path("engine/fixtures", f), stringsAsFactors = FALSE, colClasses = "character")
ph <- .rd("pharmacy.csv"); md <- .rd("medical.csv"); rollup <- .rd("rollup.csv"); mem <- .rd("members.csv")

map <- build_map_stacked(ph, md, rollup, mem)
lot1 <- build_lot1_base(map, mem)

.write <- function(df) { f <- tempfile(fileext = ".csv"); write.csv(df, f, row.names = FALSE, na = ""); f }
map_contract <- c("patient_id", "med_abbr", "med_class", "map_cnt", "map_start_dt", "map_rx_runout_dt",
                  "map_med_runout_dt", "map_end_dt", "map_med_type", "map_med_class", "map_discon_flg")
lot1_contract <- c("patient_id", "lot1_start_dt", "lot1_med_cnt", "lot1_base_meds",
                   "lot1_base_discon_dt", "lot1_base_1st_add_med_dt", "lot1_base_1st_add_med")
cm <- compare_local_table(.write(map), "engine/fixtures/expected/MAP_STACKED.csv",
                          c("patient_id", "med_abbr", "map_cnt"), required = map_contract)
ok(isTRUE(cm$match), "engine MAP_STACKED reproduces hand-derived expected (synthetic)")
cl <- compare_local_table(.write(lot1), "engine/fixtures/expected/LOT1_BASE.csv",
                          c("patient_id"), required = lot1_contract)
ok(isTRUE(cl$match), "engine LOT1_BASE reproduces hand-derived expected (synthetic)")
# end-to-end driver MAP -> LOT1 -> SCT -> LOT1 end reproduces hand-derived LOT1_END
e2e <- run_engine("engine/fixtures")
ce <- compare_local_table(.write(e2e$LOT1_END), "engine/fixtures/expected/LOT1_END.csv",
        c("patient_id"), required = c("patient_id", "lot1_base_end_dt", "lot1_base_end_reason", "lot1_base_length"))
ok(isTRUE(ce$match), "driver LOT1_END reproduces hand-derived expected (end-to-end, incl. SCT_ALLO)")

# --- targeted rule spot-checks ------------------------------------------------
eq(nrow(map), 8L, "8 MAP periods across the cohort")
p1 <- map[map$patient_id == "9000000001", ]
eq(as.character(p1$map_rx_runout_dt[p1$map_cnt == 1]), "2021-03-01", "pharmacy PUSHOUT rx_runout")
eq(as.integer(p1$map_discon_flg[p1$map_cnt == 1]), 1L, "MAP1 discon=1 (92d gap to MAP2)")
eq(as.integer(p1$map_discon_flg[p1$map_cnt == 2]), 0L, "MAP2 discon=0 (<90d to OBS_END)")
p2 <- map[map$patient_id == "9000000002", ]
ok(as.character(p2$map_med_runout_dt) == "2021-03-04" && as.character(p2$map_rx_runout_dt) == "2021-03-01",
   "medical no-pushout + pharmacy RESET")
# steroid is in MAP but excluded from LOT1
ok("DEX" %in% map$med_abbr[map$patient_id == "9000000003"], "steroid appears in MAP_STACKED")
p3 <- lot1[lot1$patient_id == "9000000003", ]
eq(p3$lot1_base_meds, "BORT LENA", "steroid + out-of-window DARA excluded from induction meds")
eq(as.character(p3$lot1_base_1st_add_med), "DARA", "DARA is the first-add med")
eq(as.character(p3$lot1_base_1st_add_med_dt), "2021-05-14", "first-add date = MAP_START - 1")
ok(!"9000000004" %in% lot1$patient_id, "steroid-only patient gets NO LOT1 row")

# --- direct edge cases (inline, independent of the cohort) --------------------
rl <- data.frame(code_type = "NDC", code = "X", med_abbr = "AAA", med_class = "IMID", stringsAsFactors = FALSE)
oe <- data.frame(patient_id = "9000000001", obs_end_dt = "2022-12-31", stringsAsFactors = FALSE)
# single claim -> single MAP
single <- data.frame(patient_id = "9000000001", service_date = "2021-01-10", normalized_code = "X",
                     code_system = "NDC", days_supply = "30", stringsAsFactors = FALSE)
m1 <- build_map_stacked(single, data.frame(), rl, oe)
ok(nrow(m1) == 1 && as.character(m1$map_end_dt) == "2021-02-08", "single pharmacy claim -> one MAP")
# same-day pharmacy + medical: pharmacy sorted first; both update the one MAP
rl2 <- rbind(rl, data.frame(code_type = "HCPCS", code = "J1", med_abbr = "AAA", med_class = "IMID", stringsAsFactors = FALSE))
sd_ph <- data.frame(patient_id = "9000000001", service_date = "2021-01-10", normalized_code = "X",
                    code_system = "NDC", days_supply = "10", stringsAsFactors = FALSE)
sd_md <- data.frame(patient_id = "9000000001", service_date = "2021-01-10", normalized_code = "J1",
                    code_system = "HCPCS", day_supply = "28", stringsAsFactors = FALSE)
m2 <- build_map_stacked(sd_ph, sd_md, rl2, oe)
ok(nrow(m2) == 1 && as.character(m2$map_end_dt) == "2021-02-06",
   "same-day pharmacy+medical collapse to one MAP (end = medical runout)")
# pharmacy day-supply imputation: missing/<1 -> 28 (production parity, 02_lot1.R:426-435)
imp <- data.frame(patient_id = "9000000001", service_date = "2021-01-10", normalized_code = "X",
                  code_system = "NDC", days_supply = "", stringsAsFactors = FALSE)
mi <- build_map_stacked(imp, data.frame(), rl, oe)
ok(nrow(mi) == 1 && as.character(mi$map_end_dt) == "2021-02-06",
   "missing pharmacy day-supply imputed to 28 (end = dt + 27)")
# same-day duplicate pharmacy claims -> deduped to MAX day-supply (no artificial pushout)
dup <- data.frame(patient_id = "9000000001", service_date = "2021-01-10", normalized_code = "X",
                  code_system = "NDC", days_supply = c("10", "30"), stringsAsFactors = FALSE)
md <- build_map_stacked(dup, data.frame(), rl, oe)
ok(nrow(md) == 1 && as.character(md$map_end_dt) == "2021-02-08",
   "same-day dup pharmacy -> one MAP, MAX day-supply 30 (end dt+29), no pushout")
# claim-window scoping: claims outside [index_date, obs_end] are dropped before MAP
memw <- data.frame(patient_id = "9000000001", index_date = "2021-01-05", obs_end_dt = "2021-06-30", stringsAsFactors = FALSE)
phw <- data.frame(patient_id = "9000000001", service_date = c("2021-01-01", "2021-02-01", "2021-08-01"),
                  normalized_code = "X", code_system = "NDC", days_supply = "30", stringsAsFactors = FALSE)
mw <- build_map_stacked(phw, data.frame(), rl, memw)
ok(nrow(mw) == 1 && as.character(mw$map_start_dt) == "2021-02-01",
   "claims before index_date / after obs_end dropped before MAP")
