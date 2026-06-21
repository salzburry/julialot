# engine: the LOCAL pure-R MAP re-implementation must reproduce the hand-derived
# expected output on the synthetic cohort (verification of the refactor logic).
source("engine/map.R")
.rd <- function(f) read.csv(file.path("engine/fixtures", f), stringsAsFactors = FALSE, colClasses = "character")
got <- build_map_stacked(.rd("pharmacy.csv"), .rd("medical.csv"), .rd("rollup.csv"), .rd("members.csv"))

tf <- tempfile(fileext = ".csv"); write.csv(got, tf, row.names = FALSE, na = "")
contract <- c("patient_id", "med_abbr", "med_class", "map_cnt", "map_start_dt", "map_rx_runout_dt",
              "map_med_runout_dt", "map_end_dt", "map_med_type", "map_med_class", "map_discon_flg")
cmp <- compare_local_table(tf, "engine/fixtures/expected/MAP_STACKED.csv",
                           c("patient_id", "med_abbr", "map_cnt"), required = contract)
ok(isTRUE(cmp$match), "engine MAP_STACKED reproduces the hand-derived expected (synthetic)")

# rule spot-checks (independent of the CSV compare)
eq(nrow(got), 3L, "engine produces 3 MAP periods")
p1m1 <- got[got$patient_id == "9000000001" & got$map_cnt == 1L, ]
eq(as.character(p1m1$map_rx_runout_dt), "2021-03-01", "pharmacy PUSHOUT: rx_runout = 2021-03-01")
eq(as.integer(p1m1$map_discon_flg), 1L, "discontinuation flagged on a >=90d gap")
p2 <- got[got$patient_id == "9000000002", ]
ok(as.character(p2$map_med_runout_dt) == "2021-03-04" && as.character(p2$map_rx_runout_dt) == "2021-03-01",
   "medical no-pushout (2021-03-04) + pharmacy RESET (2021-03-01)")
eq(nrow(got[got$patient_id == "9000000001", ]), 2L, "gap opens a second MAP for patient 1")
