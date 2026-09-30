#!/usr/bin/env Rscript
# The MDV half of the LOT engine, run - not read.
#
# The chain as production runs it, against synthetic MDV in a local DuckDB
# (../../tests/duck_bridge.py): the MDV cohort build writes NDMM_COHORT, then
# the LOT engine runs its preflight, its code lists, and the two phases that
# read MDV - phase_mma_extract(), which writes MMA_MED_PROCESSED, and
# phase_sct_extract(), which writes SCT_CLAIMS_RAW. The rows are checked
# against what the planted patients (../../tests/fixture_mdv.R) must give.
#
# It stops there. The MAP state machine and everything after it are the Optum
# engine's, unchanged, and use Spark higher-order functions DuckDB cannot run,
# so no suite here executes them. See ../../MDV_RULES.md, "What was tested".
#
#   Rscript "lot/engine/tests/test_mdv_extract.R"

ROOT <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                                 fixed = TRUE))) else getwd()
  dirname(d)
})
MDV   <- dirname(dirname(ROOT))
NDMM  <- file.path(MDV, "ndmm")
SHARED <- file.path(MDV, "tests")
source(file.path(ROOT, "tests", "testutil.R"))
source(file.path(SHARED, "fixture_mdv.R"))
source(file.path(SHARED, "duck_bridge.R"))

have_duck <- identical(0L, suppressWarnings(system2(
  "python3", c("-c", shQuote("import duckdb, sqlglot")), stdout = FALSE, stderr = FALSE)))
if (!have_duck) {
  skip_note("the MDV extraction suite: python3 cannot import duckdb and sqlglot")
  report()
}

work <- file.path(tempdir(), "mdv_lot")
fx <- write_mdv_fixture(work)
# 2026q4: the act table's care-setting column carries 9, which neither code reads.
write_mdv_fixture(work, vintage = "2026q4")
local({
  f <- file.path(work, "clnprw_mdv_all_use.t_actdata_2026q4.csv")
  a <- utils::read.csv(f, stringsAsFactors = FALSE, colClasses = "character")
  a$nyugaikbn <- "9"
  utils::write.csv(a, f, row.names = FALSE, na = "")
})
# Steroids are kept out of the production code list (lot/CONTENTS.md, "the
# code-list checks"); the shared fixture carries dexamethasone to test the
# cohort build's own steroid drop, so it is taken out here.
local({
  f <- file.path(fx$codelists, "cl_mma_codelist.csv")
  cl <- read.csv(f, colClasses = "character")
  write.csv(cl[cl$CL_MED_CLASS != "STEROID", ], f, row.names = FALSE, na = "")
})
Sys.setenv(CODELIST_DIR = fx$codelists, PROJECT_WORK_SCHEMA = "wk",
           OUTPUT_DIR = work, PIPELINE_LOG_FILE = file.path(work, "run.log"),
           DOMINO_RUN_ID = "mdvlot1",
           MDV_COL_FF1_OUTCOME = "taiintenki", MDV_COL_ICD10 = "icd10code",
           MDV_COL_ACT_DAYS = "kaisu",
           NDMM_CONTRACT_OVERRIDE = "TRUE", LOT_CONTRACT_OVERRIDE = "TRUE",
           # The cohort was built under its own prefix, as the study does it.
           COHORT_PREFIX = "ndmm_",
           # POM's pattern finds nothing in the fixture's drug master, as an
           # agent not sold in Japan would; accepted here by name.
           CODELIST_WAIVERS = "unresolved_names")

cat("\n-- the MDV cohort build writes the cohort LOT reads --\n")
source(file.path(NDMM, "R", "build_ndmm.R"))
load_ndmm_modules(NDMM)
use_duck()
duck_start(fx$tables, file.path(SHARED, "duck_bridge.py"))
duck_exec("CREATE SCHEMA IF NOT EXISTS wk")
r0 <- tryCatch(suppressMessages(capture.output(build_ndmm(NDMM, "ndmm_", con = "duck"))),
               error = function(e) e)
if (inherits(r0, "error")) cat("  stopped: ", conditionMessage(r0), "\n")
ok(!inherits(r0, "error"), "build_ndmm() writes wk.ndmm_NDMM_COHORT")

cat("\n-- the LOT engine's MDV half, in build_lot()'s own order --\n")
# The LOT modules replace the cohort build's helpers of the same names, as a
# separate process would start with only its own.
source(file.path(ROOT, "R", "build_lot.R"))
load_lot_modules(ROOT)
use_duck()

# build_lot() up to and including the two MDV phases, call for call. It is not
# called whole because phase_map() would follow, and DuckDB cannot run it.
run_mdv_half <- function(prefix) {
  check_settings()
  cfg <- pin_output_schema(cfg_defaults)
  cfg <- pin_cohort(cfg, "ndmm_NDMM_COHORT", prefix)
  cfg <- pin_study_window(cfg, NULL, NULL)
  cfg$code_md5 <- code_fingerprint(ROOT)
  check_lot_contract(cfg)
  set_lot_config(cfg)
  con <- "duck"
  cohort <- check_cohort_input(con, wrk(cfg$input_cohort_table))
  check_cohort_window(con, wrk(cfg$input_cohort_table), cfg)
  st <- check_cohort_build(con, cfg)
  check_mdv_source(con, cfg)
  options(lot_waivers_applied = character(0), lot_codelist_md5 = list())
  ctx <- phase_codelists(con)
  phase_patient_input(con)
  materialize_cohort_input(con, cohort)
  phase_mma_extract(con, ctx)
  phase_sct_extract(con, ctx)
  invisible(list(cfg = cfg, status = st))
}

r1 <- tryCatch(suppressMessages(capture.output(run1 <- run_mdv_half("lotmdv_"))),
               error = function(e) e)
if (inherits(r1, "error")) {
  cat("  stopped: ", conditionMessage(r1), "\n")
  cat("  last statement:\n", utils::tail(duck_log$sql, 1), "\n")
}
ok(!inherits(r1, "error"), "the preflight, the code lists and both MDV extractions complete")

if (!inherits(r1, "error")) {
  ok("unresolved_names" %in% getOption("lot_waivers_applied"),
     "POM's pattern finding no drug is the waivable unresolved_names, and the waiver is recorded as applied")
  ok(identical(as.character(run1$status$run_id), "mdvlot1"),
     "check_cohort_build() finds the cohort build's own status row, so the lineage is proven")

  pi <- duck_query("SELECT PATID, cast(OBS_END_DT as string) AS OBS_END_DT FROM lot_patient_input ORDER BY PATID")
  ob <- setNames(pi$OBS_END_DT, pi$PATID)
  ok(identical(unname(ob["P20"]), "2021-01-20"),
     "OBS_END_DT is ENDDATE_CE - P20's last record, 2021-01-20 - under the MDV contract")

  cat("\n-- the drug acts, as the MAP will read them --\n")
  mp <- duck_query("SELECT PATID, MED_ABBR, cast(DATE_SERVICE as string) AS DT, CLAIM_TYPE, DAY_SUPPLY
                    FROM mma_med_processed ORDER BY PATID, DT, MED_ABBR")
  got <- function(p, med, dt) mp[mp$PATID == p & mp$MED_ABBR == med & mp$DT == dt, , drop = FALSE]
  g <- got("P01", "BORT", "2019-04-10")
  ok(nrow(g) == 1L && g$CLAIM_TYPE == "medical" && g$DAY_SUPPLY == 28L,
     "an injected drug (CL_ROUTE=INJ) is a medical act covering MEDICAL_DAY_SUPPLY, 28 days")
  g <- got("P01", "LEN", "2019-04-12")
  ok(nrow(g) == 1L && g$CLAIM_TYPE == "pharmacy" && g$DAY_SUPPLY == 21L,
     "an oral drug (CL_ROUTE=ORAL) is a pharmacy act covering its own days supplied, 21")
  ok(!any(mp$MED_ABBR == "DEX"),
     "a steroid act is not extracted when the code list carries no steroid")
  g <- got("P02", "LEN", "2020-06-16")
  ok(nrow(g) == 1L && g$CLAIM_TYPE == "pharmacy" && g$DAY_SUPPLY == 1L,
     "an inpatient daily oral act covers its one day")
  ok(nrow(got("P01", "MELP", "2019-09-08")) == 1L,
     "melphalan found by its English name '%melphalan%' is extracted")
  ok(!any(mp$PATID == "P01" & mp$DT < "2019-04-10"),
     "nothing before the index is read")
  ok(!any(mp$PATID == "P20" & mp$DT > "2021-01-20"),
     "nothing after the last record is read")
  ok(nrow(got("P18", "BELA", "2020-09-01")) == 1L,
     "P18's belantamab after the index is extracted, so the no_belantamab criterion can see it")

  cat("\n-- the transplants and CAR-T --\n")
  sc <- duck_query("SELECT PATID, SCT_TYPE, cast(DATE_SERVICE as string) AS DT FROM sct_claims_raw ORDER BY PATID, DT")
  ok(identical(sc$DT[sc$PATID == "P01" & sc$SCT_TYPE == "AUTO"], c("2019-09-01", "2019-09-10")),
     "P01's two autologous transplant acts are both raw AUTO events, for the clustering to take the last")
  ok(identical(sc$SCT_TYPE[sc$PATID == "P13"], "ALLO"),
     "P13's allogeneic transplant is an ALLO event - and her blank-coded act is no CAR-T")
  ok(!any(mp$PATID == "P13" & mp$MED_ABBR == "MELP"),
     "nor a melphalan act: a master code of '--' named melphalan joins nothing")
  ok(identical(sc$SCT_TYPE[sc$PATID == "P16"], "CART"),
     "P16's CAR-T, a drug found by its English name, is a CART event")
  rc <- duck_query("SELECT count(*) AS n FROM wk.lotmdv_MMA_RECEIPTS")
  ok(isTRUE(rc$n > 0), "MMA_RECEIPTS is written for the reader")
}

cat("\n-- the same extraction when the delivery carries no days supplied --\n")
Sys.setenv(MDV_COL_ACT_DAYS = "NONE", DOMINO_RUN_ID = "mdvlot2")
load_lot_modules(ROOT); use_duck()
r2 <- tryCatch(suppressMessages(capture.output(run_mdv_half("lotmdv2_"))),
               error = function(e) e)
if (inherits(r2, "error")) cat("  stopped: ", conditionMessage(r2), "\n")
ok(!inherits(r2, "error"), "the extraction completes with MDV_COL_ACT_DAYS=NONE")
if (!inherits(r2, "error")) {
  mp2 <- duck_query("SELECT PATID, MED_ABBR, cast(DATE_SERVICE as string) AS DT, DAY_SUPPLY
                     FROM mma_med_processed WHERE MED_ABBR = 'LEN' ORDER BY PATID, DT")
  d <- function(p, dt) mp2$DAY_SUPPLY[mp2$PATID == p & mp2$DT == dt]
  ok(identical(d("P01", "2019-04-12"), 28L),
     "an outpatient oral act with no days supplied covers ORAL_DAYS_DEFAULT, 28")
  ok(identical(d("P02", "2020-06-16"), 1L),
     "an inpatient one covers its day")
}

cat("\n-- a route the extraction does not know stops the build --\n")
cl <- read.csv(file.path(fx$codelists, "cl_mma_codelist.csv"), colClasses = "character")
cl$CL_ROUTE[cl$CL_MED_ABBR == "BORT"] <- "IV"
bad_dir <- file.path(work, "codelists_badroute"); dir.create(bad_dir, showWarnings = FALSE)
for (f in list.files(fx$codelists, full.names = TRUE)) file.copy(f, bad_dir, overwrite = TRUE)
write.csv(cl, file.path(bad_dir, "cl_mma_codelist.csv"), row.names = FALSE, na = "")
Sys.setenv(CODELIST_DIR = bad_dir, DOMINO_RUN_ID = "mdvlot3")
load_lot_modules(ROOT); use_duck()
r3 <- tryCatch(suppressMessages(capture.output(run_mdv_half("lotmdv3_"))),
               error = function(e) conditionMessage(e))
ok(is.character(r3) && length(r3) == 1L && grepl("route", r3, fixed = TRUE),
   "CL_ROUTE=IV is the fatal route check, not a silent medical act")

# A copy of the fixture's code lists with one file changed, for the checks
# below.
lists_with <- function(name, file, edit) {
  d <- file.path(work, paste0("codelists_", name))
  dir.create(d, showWarnings = FALSE)
  for (f in list.files(fx$codelists, full.names = TRUE)) file.copy(f, d, overwrite = TRUE)
  x <- read.csv(file.path(d, file), colClasses = "character")
  write.csv(edit(x), file.path(d, file), row.names = FALSE, na = "")
  d
}
run_with <- function(dir, waivers, id, prefix) {
  Sys.setenv(CODELIST_DIR = dir, CODELIST_WAIVERS = waivers, DOMINO_RUN_ID = id)
  load_lot_modules(ROOT); use_duck()
  tryCatch({ suppressMessages(capture.output(run_mdv_half(prefix))); "" },
           error = function(e) conditionMessage(e))
}

cat("\n-- one waived check does not switch another off --\n")
# A rollup agent no code-list row names is uncoded_meds; POM's pattern finding
# nothing is unresolved_names. Waiving the first must leave the second standing.
dir6 <- lists_with("uncoded", "cl_mma_rollup.csv", function(r) {
  z <- r[1, ]; z$CL_MED_ABBR <- "ZZZ"; z$CL_MEDICATION_FULL <- "zzz"; rbind(r, z) })
r6 <- run_with(dir6, "uncoded_meds", "mdvlot6", "lotmdv6_")
ok(grepl("unresolved_names", r6, fixed = TRUE),
   "with only uncoded_meds waived, POM's unmatched pattern still stops the build")
r6b <- run_with(dir6, "uncoded_meds,unresolved_names", "mdvlot6b", "lotmdv6b_")
ok(identical(r6b, "") &&
     all(c("uncoded_meds", "unresolved_names") %in% getOption("lot_waivers_applied")),
   "waived by name, both are recorded as applied")

cat("\n-- an SCT name pattern that finds nothing stops the build --\n")
dir7 <- lists_with("scttypo", "cl_sct_codelist.csv", function(x) {
  x$CL_CODE[x$CL_CODE == "%vicleucel%"] <- "%vicleucell%"; x })
r7 <- run_with(dir7, "unresolved_names", "mdvlot7", "lotmdv7_")
ok(grepl("sct_unresolved_names", r7, fixed = TRUE) && grepl("%vicleucell%", r7, fixed = TRUE),
   "'%vicleucell%' is refused by name, rather than losing P16's CAR-T")
r7b <- run_with(dir7, "unresolved_names,sct_unresolved_names", "mdvlot7b", "lotmdv7b_")
ok(identical(r7b, "") && "sct_unresolved_names" %in% getOption("lot_waivers_applied"),
   "waived by name, it runs and records the waiver")
if (identical(r7b, "")) {
  sc7 <- duck_query("SELECT PATID, SCT_TYPE FROM sct_claims_raw WHERE PATID = 'P16'")
  ok(!"CART" %in% sc7$SCT_TYPE, "...and the waiver's cost is visible: P16 has no CAR-T event")
}

cat("\n-- oral supply the care setting cannot size --\n")
# With no days supplied, an oral act is sized by its setting. A value neither
# code reads must not fall to ORAL_DAYS_DEFAULT as if outpatient.
Sys.setenv(MDV_VINTAGE = "2026q4", MDV_COL_ACT_DAYS = "NONE", COHORT_PREFIX = "ndmm_")
r9 <- run_with(fx$codelists, "unresolved_names", "mdvlot9", "lotmdv9_")
ok(grepl("neither MDV_INPATIENT", r9, fixed = TRUE) && grepl("9 (", r9, fixed = TRUE),
   "a care-setting value of 9 stops the run, naming the value")
Sys.setenv(MDV_COL_ACT_NYUGAIKBN = "NONE")
r9b <- run_with(fx$codelists, "unresolved_names", "mdvlot9b", "lotmdv9b_")
ok(identical(r9b, ""), "declared NONE, the documented no-setting fallback runs")
if (identical(r9b, "")) {
  d9 <- duck_query("SELECT DAY_SUPPLY FROM mma_med_processed
                    WHERE PATID = 'P02' AND MED_ABBR = 'LEN' AND cast(DATE_SERVICE as string) = '2020-06-16'")
  ok(identical(as.integer(d9$DAY_SUPPLY), 28L),
     "...and sizes the inpatient act at ORAL_DAYS_DEFAULT, because it was asked to")
}
Sys.unsetenv(c("MDV_VINTAGE", "MDV_COL_ACT_NYUGAIKBN"))
Sys.setenv(MDV_COL_ACT_DAYS = "kaisu")

cat("\n-- a sensitivity build under its own prefix names the cohort's --\n")
# The documented sensitivity command writes under mdvds21_ over a cohort built
# under another prefix. Without COHORT_PREFIX the lineage check looks for the
# cohort's status under the new prefix.
Sys.unsetenv("COHORT_PREFIX")
r8 <- run_with(fx$codelists, "unresolved_names", "mdvlot8", "lotds21_")
ok(grepl("No cohort build-status table found", r8, fixed = TRUE) &&
     grepl("lotds21_", r8, fixed = TRUE),
   "without COHORT_PREFIX the lineage check looks under the new prefix and stops")
Sys.setenv(COHORT_PREFIX = "ndmm_")
r8b <- run_with(fx$codelists, "unresolved_names", "mdvlot8b", "lotds21b_")
ok(identical(r8b, ""), "with COHORT_PREFIX naming the cohort's prefix it runs")

duck_stop()
report()
