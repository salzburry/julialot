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
# full 23-column LOT_LONG vs the hand-derived golden (LOT1 rows anchored to the golden
# LOT1_BASE/LOT1_END; LOT2-5 to the documented sequential rules). ALL 23 columns match
# exactly - incl. contains_mtx_reg, now COMPUTED (the fixture marks LENA MONOMAINTENANCE,
# so 9000000003 LOT1 "BORT LENA" = 1). A FULL match, not partial.
cll <- compare_local_table(.write(e2e$LOT_LONG), "engine/fixtures/expected/LOT_LONG.csv",
        c("patient_id", "lot_num"), required = LOT_LONG_COLS)
ok(isTRUE(cll$match) && cll$verdict == "match" && cll$value_mismatch == 0 &&
   cll$only_in_a == 0 && cll$only_in_b == 0 && isTRUE(cll$schema_ok),
   "driver LOT_LONG reproduces the hand-derived golden on ALL 23 columns (contains_mtx_reg computed; full match)")

# typed param validation: run_engine fails CLOSED on bad/unknown overrides (before run),
# reusing the SHARED CONFIG_SPEC (no second contract) - so its bounds apply here too.
ok(inherits(try(.validate_params(list(max_lott = 5)), silent = TRUE), "try-error"), "unknown param key (typo max_lott) rejected")
ok(inherits(try(.validate_params(list(sct_tandem_days = "bad")), silent = TRUE), "try-error"), "non-numeric param rejected")
ok(inherits(try(.validate_params(list(induction_window_days = -10)), silent = TRUE), "try-error"), "negative param rejected")
ok(inherits(try(.validate_params(list(map_discon_gap_days = 1.5)), silent = TRUE), "try-error"), "fractional param rejected")
ok(inherits(try(.validate_params(list(allo_lot_span = "nope")), silent = TRUE), "try-error"), "bad enum value rejected")
ok(inherits(try(.validate_params(list(map_discon_gap_days = 0)), silent = TRUE), "try-error"),
   "CONFIG_SPEC bound applied: map_discon_gap_days=0 (< min 1) rejected (the old .PARAM_SPEC allowed it)")
ok(inherits(try(.validate_params(list(sct_auto_window_days = 100L)), silent = TRUE), "try-error"),
   "CONFIG_SPEC upper bound applied: sct_auto_window_days=100 (> max 60) rejected")
ok(identical(DEFAULT_PARAMS, lapply(CONFIG_SPEC[names(DEFAULT_PARAMS)], `[[`, "default")),
   "DEFAULT_PARAMS VALUES are derived from CONFIG_SPEC (single source of defaults, no drift)")
ok(isTRUE(.validate_params(list(sct_tandem_days = 200L, allo_lot_span = "extend_to_next"))), "valid overrides accepted")
ok(isTRUE(.validate_params(list())), "empty overrides accepted (defaults used)")

# P2: run_engine PROPAGATES cart_consolidation_days into the LOT1 end (build_lot1_end).
# A CART 36d after the first-add is CART_INIT under the default 45-day window (ends
# FIRST_CART-1) but falls through to MED_ADD under a 30-day override - proving the
# param reaches LOT1, not build_lot1_end's hardcoded default.
ci_dir <- file.path(tempdir(), "ci_prop"); dir.create(ci_dir, showWarnings = FALSE)
write.csv(data.frame(patient_id = "9000000200", index_date = "2020-06-01", obs_end_dt = "2021-12-31"),
          file.path(ci_dir, "members.csv"), row.names = FALSE)
write.csv(data.frame(patient_id = "9000000200",
  service_date = c("2021-01-01", "2021-01-31", "2021-03-02", "2021-04-01", "2021-05-01", "2021-03-15"),
  normalized_code = c(rep("00000000001", 5), "00000000002"), code_system = "NDC", days_supply = "30"),  # 11-digit NDC
          file.path(ci_dir, "pharmacy.csv"), row.names = FALSE)
write.csv(data.frame(code_type = "NDC", code = c("00000000001", "00000000002"), med_abbr = c("BORT", "DARA"), med_class = c("PI", "MAB"),
          MONOMAINTENANCE = "0", DUALMAINTENANCEWITH = ""),   # required maintenance metadata
          file.path(ci_dir, "rollup.csv"), row.names = FALSE)
write.csv(data.frame(code_type = "HCPCS", code = "38241", sct_type = "CART"),
          file.path(ci_dir, "sct_codelist.csv"), row.names = FALSE)
write.csv(data.frame(patient_id = "9000000200", event_date = "2021-04-20", normalized_code = "38241", code_system = "HCPCS"),
          file.path(ci_dir, "procedure.csv"), row.names = FALSE)
le_def <- run_engine(ci_dir)$LOT1_END                                  # default cart_consolidation_days = 45
le_30  <- run_engine(ci_dir, list(cart_consolidation_days = 30L))$LOT1_END
ok(le_def$lot1_base_end_reason == "CART_INIT" && as.character(le_def$lot1_base_end_dt) == "2021-04-19",
   "LOT1 CART_INIT fires under the default 45-day window")
ok(le_30$lot1_base_end_reason == "MED_ADD" && as.character(le_30$lot1_base_end_dt) == "2021-03-14",
   "cart_consolidation_days=30 override REACHES LOT1 (CART now outside window -> MED_ADD)")

# maintenance metadata is a REQUIRED rollup input (contains_mtx_reg must be EVALUATED,
# never silently 0 from a missing input): run_engine fails closed without the columns.
nomaint <- file.path(tempdir(), "nomaint"); dir.create(nomaint, showWarnings = FALSE)
file.copy(list.files("engine/fixtures", full.names = TRUE, pattern = "\\.csv$"), nomaint, overwrite = TRUE)
.rollup_csv <- function(df) { write.csv(df, file.path(nomaint, "rollup.csv"), row.names = FALSE)
  inherits(try(run_engine(nomaint), silent = TRUE), "try-error") }
ok(.rollup_csv(data.frame(code_type = "NDC", code = "11111111111", med_abbr = "LENA", med_class = "IMID")),
   "run_engine fails closed when the rollup lacks MONOMAINTENANCE/DUALMAINTENANCEWITH (no silent zero)")
ok(.rollup_csv(data.frame(code_type = character(0), code = character(0), med_abbr = character(0),
   med_class = character(0), MONOMAINTENANCE = character(0), DUALMAINTENANCEWITH = character(0))),
   "run_engine fails closed on a header-only (0-row) rollup")
ok(.rollup_csv(data.frame(code = "L", med_abbr = "LENA", med_class = "IMID",
   MONOMAINTENANCE = "0", DUALMAINTENANCEWITH = "")),
   "run_engine fails closed when the rollup lacks code_type (MAP-construction column)")
# the end-to-end golden now exercises a POSITIVE maintenance row (BORT LENA = mono LENA + anchor BORT)
gold <- read.csv("engine/fixtures/expected/LOT_LONG.csv", colClasses = "character")
ok("1" %in% gold$contains_mtx_reg && sum(gold$contains_mtx_reg == "1") == 1L,
   "the LOT_LONG golden includes a contains_mtx_reg=1 row (BORT LENA induction)")
# rollup HEADERS are canonicalized (case-insensitive): an UPPERCASE-header rollup is
# accepted AND consumed correctly (the prior bug: validation passed case-insensitively
# but map.R/.maint_maps read exact-lowercase, breaking downstream).
upcase <- file.path(tempdir(), "upcase"); dir.create(upcase, showWarnings = FALSE)
file.copy(list.files("engine/fixtures", full.names = TRUE, pattern = "\\.csv$"), upcase, overwrite = TRUE)
ru <- read.csv("engine/fixtures/rollup.csv", colClasses = "character", check.names = FALSE)
names(ru) <- toupper(names(ru))   # CODE_TYPE, MED_ABBR, MONOMAINTENANCE, ...
write.csv(ru, file.path(upcase, "rollup.csv"), row.names = FALSE)
up_ll <- run_engine(upcase)$LOT_LONG
ok(nrow(up_ll) == 5L && sum(up_ll$contains_mtx_reg == 1) == 1L,
   "UPPERCASE-header rollup is accepted and yields the same contains_mtx_reg (headers canonicalized)")
# SEMANTIC rollup validation via the shared validate_reference_data layer (not one-off
# checks): a rows-but-unusable rollup BLOCKS instead of silently emptying MAP/LOT.
ok(.rollup_csv(data.frame(code_type = "NDC", code = c("11111111111", "11111111111"),
   med_abbr = c("LENA", "BORT"), med_class = c("IMID", "PI"), MONOMAINTENANCE = "0", DUALMAINTENANCEWITH = "")),
   "run_engine fails closed on a rollup collision (one NDC code -> two medications)")
ok(.rollup_csv(data.frame(code_type = "NDC", code = "11111111111", med_abbr = "",
   med_class = "IMID", MONOMAINTENANCE = "0", DUALMAINTENANCEWITH = "")),
   "run_engine fails closed on a blank med_abbr (no silent empty mapping)")
ok(.rollup_csv(data.frame(code_type = "NDC", code = "123", med_abbr = "LENA",
   med_class = "IMID", MONOMAINTENANCE = "0", DUALMAINTENANCEWITH = "")),
   "run_engine fails closed on a non-11-digit NDC code")
# headers folding to the same name after case-normalization (code_type + CODE_TYPE) are
# ambiguous -> rejected
writeLines(c("code_type,CODE_TYPE,code,med_abbr,med_class,MONOMAINTENANCE,DUALMAINTENANCEWITH",
             "NDC,NDC,11111111111,LENA,IMID,0,"), file.path(nomaint, "rollup.csv"))
ok(inherits(try(run_engine(nomaint), silent = TRUE), "try-error"),
   "run_engine rejects a rollup whose headers collide after case-normalization")

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
oe <- data.frame(patient_id = "9000000001", index_date = "2020-01-01", obs_end_dt = "2022-12-31", stringsAsFactors = FALSE)
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
# strict scoping: a claim for a patient ABSENT from members is dropped (no false patient)
phu <- data.frame(patient_id = c("9000000001", "9999999999"), service_date = "2021-02-01",
                  normalized_code = "X", code_system = "NDC", days_supply = "30", stringsAsFactors = FALSE)
mu <- build_map_stacked(phu, data.frame(), rl, memw)
ok(nrow(mu) == 1 && mu$patient_id == "9000000001", "claim for unknown (non-member) patient dropped")
# pharmacy invalid day-supply is hardcoded to 28, independent of medical_day_supply
imp2 <- data.frame(patient_id = "9000000001", service_date = "2021-01-10", normalized_code = "X",
                   code_system = "NDC", days_supply = "", stringsAsFactors = FALSE)
m28 <- build_map_stacked(imp2, data.frame(), rl, oe, 90L, 60L)   # medical_day_supply = 60
ok(as.character(m28$map_end_dt) == "2021-02-06", "pharmacy imputation stays 28 even when medical_day_supply=60")
# medical day-supply is HARDCODED to medical_day_supply (ignores the claim's value)
rlh <- data.frame(code_type = "HCPCS", code = "J1", med_abbr = "AAA", med_class = "IMID", stringsAsFactors = FALSE)
medh <- data.frame(patient_id = "9000000001", service_date = "2021-01-10", normalized_code = "J1",
                   code_system = "HCPCS", day_supply = "10", stringsAsFactors = FALSE)
mh <- build_map_stacked(data.frame(), medh, rlh, oe)            # medical_day_supply default 28
ok(as.character(mh$map_med_runout_dt) == "2021-02-06",
   "medical day-supply hardcoded to 28 (ignores the claim's 10) -> runout dt+27")
