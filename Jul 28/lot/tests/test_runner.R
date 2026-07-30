#!/usr/bin/env Rscript
# Checks on the LOT runner: the cohort switch, the contract, and the setting
# validators. No warehouse needed.
#
#   Rscript "Jul 28/lot/tests/test_runner.R"

ROOT <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                                 fixed = TRUE))) else getwd()
  dirname(d)
})

source(file.path(ROOT, "tests", "testutil.R"))

env <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "build_lot.R"), envir = env)
for (f in ls(env)) assign(f, get(f, envir = env), envir = globalenv())
CONTRACT <- get("CONTRACT", envir = env)

SETTINGS <- c("USE_QUARTERLY_TABLES", "CENSOR_AT_DISENROLLMENT", "PERSIST_TO_SCHEMA",
              "INDUCTION_WINDOW_DAYS", "INDUCTION_WINDOW_DAYS_LOT_N",
              "MAP_DISCON_GAP_DAYS", "MEDICAL_DAY_SUPPLY", "SCT_AUTO_WINDOW_DAYS",
              "SCT_AUTO_GAP_DAYS", "SCT_TANDEM_DAYS", "CART_CONSOLIDATION_DAYS",
              "PROJECT_WORK_SCHEMA", "DOMINO_USER_NAME", "DOMINO_STARTING_USERNAME",
              "STUDY_END", "INPUT_COHORT_TABLE", "OBJECT_PREFIX",
              "ALLO_LOT_SPAN", "MAX_LOT")
clear <- function() for (v in SETTINGS) Sys.unsetenv(v)

# Stand-in names. The package knows no real cohort, so the tests must not
# smuggle one in either.
TBL_A <- "COH_A_FINAL"; PFX_A <- "coh_a_"
TBL_B <- "COH_B_FINAL"; PFX_B <- "coh_b_"

cat("\n-- the caller supplies the cohort, the package holds none --\n")
clear()
base <- modifyList(list(persist_to_schema = TRUE), CONTRACT)
cfg <- pin_cohort(base, TBL_A, PFX_A)
ok(identical(cfg$input_cohort_table, TBL_A) && identical(cfg$object_prefix, PFX_A),
   "a cohort table and prefix are taken as given")
runs(check_lot_contract(cfg), "and pass the contract")
ok(!exists("COHORTS", envir = env),
   "there is no built-in cohort list to fall out of date")

cat("\n-- a cohort has to be named properly --\n")
stops(pin_cohort(base, "", PFX_A), "no cohort table")
stops(pin_cohort(base, TBL_A, ""), "no prefix")
stops(pin_cohort(base, NULL, NULL), "neither")
stops(pin_cohort(base, "sch.COH_A_FINAL", PFX_A),
      "a qualified name - schema comes from the settings")
stops(pin_cohort(base, "COH_A; DROP TABLE x", PFX_A), "anything not a table name")
stops(pin_cohort(base, TBL_A, "coh a "), "a prefix that is not a name")
stops(pin_cohort(base, TBL_A, "coh_a"), "a prefix with no trailing underscore")
runs(pin_cohort(base, TBL_A, "s3_"), "digits are fine inside a prefix")

cat("\n-- two cohorts cannot collide --\n")
# The point of the module: same rules, different output names.
stops(check_lot_contract(modifyList(cfg, list(object_prefix = ""))),
      "a blank prefix is rejected, so outputs cannot collide")
stops(check_lot_contract(modifyList(cfg, list(input_cohort_table = ""))),
      "a blank cohort table is rejected")

cat("\n-- lot_out() prefixes LOT's outputs, wrk() leaves the cohort alone --\n")
# The cohort table is named by the cohort build; prefixing it here would look
# for coh_a_COH_A_FINAL.
cfg <- pin_cohort(modifyList(base, list(work_schema = "osk02156")), TBL_A, PFX_A)
assign("cfg", cfg, envir = globalenv())
sys.source(file.path(ROOT, "R", "db_utils_lot.R"), envir = globalenv())
ok(identical(lot_out("LOT1_BASE"), paste0("hive_metastore.osk02156.", PFX_A, "LOT1_BASE")),
   "lot_out() carries the prefix")
ok(identical(wrk(cfg$input_cohort_table), paste0("hive_metastore.osk02156.", TBL_A)),
   "wrk() reads the cohort table as the cohort named it")

# Read the real output names out of the ported steps rather than listing them
# by hand - a hand list goes stale the moment a step adds a table, which is
# exactly when a collision would slip through.
step_src <- unlist(lapply(list.files(file.path(ROOT, "R", "steps"), "\\.R$",
                                     full.names = TRUE), readLines, warn = FALSE))
step_src <- step_src[!grepl("^\\s*(#|--)", step_src)]
lits <- unlist(regmatches(step_src, gregexpr("lot_out\\((\'|\")[A-Z_0-9]+(\'|\")\\)",
                                             step_src, perl = TRUE)))
OUTPUTS <- unique(gsub("lot_out\\(|\'|\"|\\)", "", lits))
ok(length(OUTPUTS) >= 6,
   paste0("found ", length(OUTPUTS), " named outputs in the steps: ",
          paste(sort(OUTPUTS), collapse = ", ")))
ok(all(c("LOT_LONG", "LOT_RUN_METADATA") %in% OUTPUTS),
   "including LOT_LONG, the table LOT2-5 exists to build")
names_for <- function(prefix) {
  assign("cfg", modifyList(cfg, list(object_prefix = prefix)), envir = globalenv())
  vapply(OUTPUTS, lot_out, character(1))
}
a <- names_for(PFX_A); b <- names_for(PFX_B)
ok(!any(a %in% b), "a second cohort writes none of the first cohort's tables")
ok(all(grepl(paste0("\\.", PFX_B), b)), "every output of the second cohort is prefixed")
assign("cfg", cfg, envir = globalenv())

cat("\n-- the cohort table is checked before any work --\n")
# A missing column would otherwise surface deep into the build.
fake_con <- structure(list(), class = "fakecon")
GOOD <- list(n_rows = 10, n_patients = 10, n_null_patid = 0, n_null_index = 0,
             n_null_end = 0, n_end_before_index = 0)
# DESCRIBE answers with columns; the shape query answers with counts.
stub <- function(cols = REQUIRED_COHORT_COLS, shape = list()) {
  sh <- modifyList(GOOD, shape)
  assign("db_q", function(con, sql) {
    if (grepl("DESCRIBE", sql)) data.frame(col_name = cols, stringsAsFactors = FALSE)
    else as.data.frame(sh)
  }, envir = globalenv())
}
assign("log_msg", function(...) invisible(NULL), envir = globalenv())

stub()
runs(check_cohort_input(fake_con, cfg), "a sound cohort table is accepted")
stub(cols = tolower(REQUIRED_COHORT_COLS))
runs(check_cohort_input(fake_con, cfg), "column case does not matter")
stub(cols = setdiff(REQUIRED_COHORT_COLS, "ENDDATE_CE"))
stops(check_cohort_input(fake_con, cfg), "a missing column is named, not ignored")

cat("\n-- and for shape, not just column names --\n")
# The rules read this table row for row: no DISTINCT, no ranking. A repeated
# patient would multiply their claims and their lines.
stub(shape = list(n_rows = 12, n_patients = 10))
stops(check_cohort_input(fake_con, cfg), "more rows than patients is rejected")
stub(shape = list(n_rows = 0, n_patients = 0))
stops(check_cohort_input(fake_con, cfg), "an empty table cannot drive LOT")
stub(shape = list(n_null_patid = 1))
stops(check_cohort_input(fake_con, cfg), "a null PATID is rejected")
stub(shape = list(n_null_index = 3))
stops(check_cohort_input(fake_con, cfg), "a null INDEX_DATE is rejected")
stub(shape = list(n_null_end = 2))
stops(check_cohort_input(fake_con, cfg), "a null ENDDATE is rejected")
stub(shape = list(n_end_before_index = 1))
stops(check_cohort_input(fake_con, cfg), "an ENDDATE before INDEX_DATE is rejected")
rm("db_q", "log_msg", envir = globalenv())

cat("\n-- build_lot() actually runs the phases, in order --\n")
# Every step file passing its own test proved nothing about whether build_lot()
# calls it. The line-criteria layer shipped complete, tested, and never invoked.
bl <- paste(readLines(file.path(ROOT, "R", "build_lot.R"), warn = FALSE),
            collapse = "\n")
body <- sub(".*build_lot <- function\\([^)]*\\) \\{", "", bl)
ORDER <- c("check_settings", "pin_output_schema", "pin_cohort",
           "check_lot_contract", "set_lot_config", "check_cohort_input",
           "phase_codelists", "phase_patient_input", "phase_mma_map",
           "phase_lot1_base", "phase_sct", "phase_lot1_end", "phase_qc",
           "phase_persist", "build_lot2_5", "phase_line_criteria",
           "check_lot_long")
at <- vapply(ORDER, function(f) {
  m <- regexpr(paste0("(?<![A-Za-z0-9_.])", f, "\\("), body, perl = TRUE)
  if (m == -1) NA_integer_ else as.integer(m)
}, integer(1))
for (f in ORDER) ok(!is.na(at[[f]]), paste0("build_lot() calls ", f, "()"))
ok(!any(is.na(at)) && !is.unsorted(at[!is.na(at)]),
   "and calls them in that order")

cat("\n-- the criteria layer reaches the warehouse --\n")
# The README promises these two tables. Nothing was producing them.
ok(grepl("line_criteria_flags_sql", bl, fixed = TRUE) &&
     grepl("line_criteria_final_sql", bl, fixed = TRUE),
   "both criteria builders are called")
for (t in c("LOT_LONG_ALLFLAGS", "LOT_LONG_FINAL"))
  ok(grepl(paste0('"', t, '"'), bl, fixed = TRUE),
     paste0(t, " is persisted, not just built as a view"))

cat("\n-- a run says whether its outputs belong together --\n")
# LOT1 tables are replaced before LOT2-5 runs; a failure between them would
# otherwise leave new LOT1 output beside an old LOT_LONG, looking complete.
for (st in c("started", "complete", "failed"))
  ok(grepl(paste0('"', st, '"'), bl, fixed = TRUE),
     paste0("build status records '", st, "'"))
ok(grepl("LOT_BUILD_STATUS", bl, fixed = TRUE), "into its own prefixed table")

cat("\n-- the contract rejects every value that changes a LOT --\n")
clear()
for (k in names(CONTRACT)) {
  v <- CONTRACT[[k]]
  other <- if (is.logical(v)) !v else if (is.numeric(v)) v + 1 else paste0(v, "x")
  stops(check_lot_contract(modifyList(pin_cohort(base, TBL_A, PFX_A),
                                      setNames(list(other), k))),
        paste0("rejects ", k, " = ", format(other)))
}
stops(check_lot_contract(modifyList(pin_cohort(base, TBL_A, PFX_A),
                                    list(persist_to_schema = FALSE))),
      "rejects PERSIST_TO_SCHEMA=FALSE")

cat("\n-- settings that used to fail open --\n")
clear()
runs(check_settings(), "unset is fine")
Sys.setenv(CENSOR_AT_DISENROLLMENT = "Y")
stops(check_settings(), "as.logical('Y') is NA, not FALSE")
clear()
Sys.setenv(MAP_DISCON_GAP_DAYS = "ninety")
stops(check_settings(), "a window that will not parse")
clear()
Sys.setenv(STUDY_END = "30-06-2025")
stops(check_settings(), "an Excel-reformatted STUDY_END")
clear()
Sys.setenv(PROJECT_WORK_SCHEMA = "hive_metastore.osk02156")
stops(check_settings(), "catalog.schema where a schema name belongs")
clear()
Sys.setenv(ALLO_LOT_SPAN = "whole_lot")
stops(check_settings(), "an ALLO span that is not one of the two")
clear()
Sys.setenv(MAX_LOT = "five")
stops(check_settings(), "a MAX_LOT that will not parse")
clear()

cat("\n-- pin_output_schema --\n")
Sys.setenv(DOMINO_USER_NAME = "osk02156")
ok(identical(pin_output_schema(list(catalog = "hive_metastore"))$work_schema, "osk02156"),
   "schema pinned from the environment")
clear()
stops(pin_output_schema(list(catalog = "hive_metastore")),
      "stops when no schema resolves")
cp <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "config_lot.R"), envir = cp)
ok(identical(get("cfg_defaults", envir = cp)$work_schema, ""),
   "schema default is blank, not a shared fallback")

cat("\n-- the shipped config.csv, not a sample --\n")
rows <- read.csv(file.path(ROOT, "config.csv"), stringsAsFactors = FALSE,
                 comment.char = "#")
shipped <- setNames(trimws(as.character(rows$value)), trimws(rows$name))
EXPECT <- c(DATABRICKS_DSN = "RWDE", DATABRICKS_CATALOG = "hive_metastore",
            OPTUM_CDM_SCHEMA = "clnprw_optum", USE_QUARTERLY_TABLES = "TRUE",
            STUDY_END = "2025-06-30", CODELIST_DIR = "/mnt/code/codelist",
            PERSIST_TO_SCHEMA = "TRUE", CENSOR_AT_DISENROLLMENT = "FALSE",
            INDUCTION_WINDOW_DAYS = "60", INDUCTION_WINDOW_DAYS_LOT_N = "30",
            MAP_DISCON_GAP_DAYS = "90", MEDICAL_DAY_SUPPLY = "28",
            SCT_AUTO_WINDOW_DAYS = "13", SCT_AUTO_GAP_DAYS = "60",
            SCT_TANDEM_DAYS = "180", CART_CONSOLIDATION_DAYS = "45",
            ALLO_LOT_SPAN = "single_day", MAX_LOT = "5")
for (k in names(EXPECT))
  ok(identical(shipped[[k]], EXPECT[[k]]), paste0("config.csv ", k, " = ", EXPECT[[k]]))
# The caller passes the cohort, so config.csv must not pin one.
ok(!any(c("INPUT_COHORT_TABLE", "OBJECT_PREFIX") %in% names(shipped)),
   "config.csv does not name a cohort")

report()
