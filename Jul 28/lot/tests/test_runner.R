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
COHORTS  <- get("COHORTS",  envir = env)

SETTINGS <- c("USE_QUARTERLY_TABLES", "CENSOR_AT_DISENROLLMENT", "PERSIST_TO_SCHEMA",
              "INDUCTION_WINDOW_DAYS", "INDUCTION_WINDOW_DAYS_LOT_N",
              "MAP_DISCON_GAP_DAYS", "MEDICAL_DAY_SUPPLY", "SCT_AUTO_WINDOW_DAYS",
              "SCT_AUTO_GAP_DAYS", "SCT_TANDEM_DAYS", "CART_CONSOLIDATION_DAYS",
              "PROJECT_WORK_SCHEMA", "DOMINO_USER_NAME", "DOMINO_STARTING_USERNAME",
              "STUDY_END", "INPUT_COHORT_TABLE", "OBJECT_PREFIX")
clear <- function() for (v in SETTINGS) Sys.unsetenv(v)

cat("\n-- the cohort switch --\n")
clear()
base <- modifyList(list(persist_to_schema = TRUE), CONTRACT)
for (nm in names(COHORTS)) {
  cfg <- pin_cohort(base, nm)
  ok(identical(cfg$input_cohort_table, COHORTS[[nm]]$input_cohort_table) &&
       identical(cfg$object_prefix, COHORTS[[nm]]$object_prefix),
     paste0(nm, ": reads ", COHORTS[[nm]]$input_cohort_table,
            ", writes ", COHORTS[[nm]]$object_prefix, "*"))
  runs(check_lot_contract(cfg), paste0(nm, ": passes the contract"))
}
stops(pin_cohort(base, "ndmm"), "an undeclared cohort is rejected, not invented")
stops(pin_cohort(base, ""), "no cohort argument is rejected")

cat("\n-- two cohorts cannot collide --\n")
# This is the whole point of the module: same rules, different output names.
# Without a distinct prefix the second cohort would overwrite the first.
prefixes <- vapply(COHORTS, `[[`, character(1), "object_prefix")
inputs   <- vapply(COHORTS, `[[`, character(1), "input_cohort_table")
ok(!anyDuplicated(prefixes), "every cohort has its own output prefix")
ok(!anyDuplicated(inputs), "every cohort reads its own table")
ok(all(nzchar(prefixes)), "no cohort writes unprefixed")
stops(check_lot_contract(modifyList(pin_cohort(base, "overall"),
                                    list(object_prefix = ""))),
      "a blank prefix is rejected, so outputs cannot collide")
stops(check_lot_contract(modifyList(pin_cohort(base, "overall"),
                                    list(input_cohort_table = ""))),
      "a blank cohort table is rejected")

cat("\n-- lot_out() prefixes LOT's outputs, wrk() leaves the cohort alone --\n")
# The cohort table is named by the cohort build; prefixing it here would look
# for overall_OVERALL_COH_FINAL.
cfg <- pin_cohort(modifyList(base, list(work_schema = "osk02156")), "overall")
assign("cfg", cfg, envir = globalenv())
sys.source(file.path(ROOT, "R", "db_utils_lot.R"), envir = globalenv())
ok(identical(lot_out("LOT1_BASE"), "hive_metastore.osk02156.overall_LOT1_BASE"),
   "lot_out() carries the cohort prefix")
ok(identical(wrk(cfg$input_cohort_table), "hive_metastore.osk02156.OVERALL_COH_FINAL"),
   "wrk() reads the cohort table as the cohort named it")

# With one cohort registered, "prefixes are unique" cannot fail. Run a second
# one through the same code to show the outputs really do separate - this is
# what the module exists for, so it is tested on the mechanism, not the list.
OUTPUTS <- c("MAP_STACKED", "LOT1_BASE", "LOT1_SCT", "LOT1_BASE_END",
             "LOT_RUN_METADATA", "LOT_QC_SUMMARY")
names_for <- function(prefix) {
  assign("cfg", modifyList(cfg, list(object_prefix = prefix)), envir = globalenv())
  vapply(OUTPUTS, lot_out, character(1))
}
a <- names_for("overall_"); b <- names_for("ndmm_")
ok(!any(a %in% b), "a second cohort writes none of the first cohort's tables")
ok(all(grepl("\\.ndmm_", b)), "every output of the second cohort is prefixed")
assign("cfg", cfg, envir = globalenv())

cat("\n-- the contract rejects every value that changes a LOT --\n")
clear()
for (k in names(CONTRACT)) {
  v <- CONTRACT[[k]]
  other <- if (is.logical(v)) !v else if (is.numeric(v)) v + 1 else paste0(v, "x")
  stops(check_lot_contract(modifyList(pin_cohort(base, "overall"),
                                      setNames(list(other), k))),
        paste0("rejects ", k, " = ", format(other)))
}
stops(check_lot_contract(modifyList(pin_cohort(base, "overall"),
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
            SCT_TANDEM_DAYS = "180", CART_CONSOLIDATION_DAYS = "45")
for (k in names(EXPECT))
  ok(identical(shipped[[k]], EXPECT[[k]]), paste0("config.csv ", k, " = ", EXPECT[[k]]))
# config.csv must not name a cohort: COHORTS is the only place that decides.
ok(!any(c("INPUT_COHORT_TABLE", "OBJECT_PREFIX") %in% names(shipped)),
   "config.csv does not set a cohort - COHORTS does")

report()
