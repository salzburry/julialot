#!/usr/bin/env Rscript
# The whole MDV cohort build, run - not read.
#
# build_ndmm() runs unchanged against synthetic MDV tables in a local DuckDB
# (../tests/duck_bridge.py): every statement it would send to the warehouse,
# in order, with each check reading a real answer. The planted patients in
# ../tests/fixture_mdv.R each exercise one rule, and the numbers below are
# worked out from them by hand.
#
#   Rscript "ndmm/tests/test_mdv_build.R"
#
# Needs python3 with duckdb and sqlglot. Without them it says so, counts the
# skip, and exits non-zero unless ALLOW_SKIPPED_TESTS=TRUE.

ROOT <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                                 fixed = TRUE))) else getwd()
  dirname(d)
})
SHARED <- file.path(dirname(ROOT), "tests")
source(file.path(ROOT, "tests", "testutil.R"))
source(file.path(SHARED, "fixture_mdv.R"))
source(file.path(SHARED, "duck_bridge.R"))

have_duck <- identical(0L, suppressWarnings(system2(
  "python3", c("-c", shQuote("import duckdb, sqlglot")), stdout = FALSE, stderr = FALSE)))
if (!have_duck) {
  cat("  SKIP  the MDV build suite: python3 cannot import duckdb and sqlglot\n")
  cat("\n0 passed, 0 failed, 1 skipped\n")
  quit(status = if (identical(toupper(Sys.getenv("ALLOW_SKIPPED_TESTS")), "TRUE")) 0L else 1L)
}

work <- file.path(tempdir(), "mdv_ndmm")
fx <- write_mdv_fixture(work)
Sys.setenv(CODELIST_DIR = fx$codelists, PROJECT_WORK_SCHEMA = "wk",
           OUTPUT_DIR = work, PIPELINE_LOG_FILE = file.path(work, "run.log"),
           DOMINO_RUN_ID = "mdvtest1",
           # The fixture's names for the columns the OC rules do not name.
           MDV_COL_FF1_OUTCOME = "taiintenki", MDV_COL_ICD10 = "icd10code",
           MDV_COL_ACT_DAYS = "kaisu",
           # CODELIST_DIR is pinned to production's; the fixture's is not it.
           NDMM_CONTRACT_OVERRIDE = "TRUE")

source(file.path(ROOT, "R", "build_ndmm.R"))
load_ndmm_modules(ROOT)
use_duck()
duck_start(fx$tables, file.path(SHARED, "duck_bridge.py"))
duck_exec("CREATE SCHEMA IF NOT EXISTS wk")

q <- function(sql) duck_query(sql)
W <- function(t) paste0("wk.ndmm_", t)

cat("\n-- the build runs to the end on MDV-shaped tables --\n")
res <- tryCatch(suppressMessages(capture.output(counts <- build_ndmm(ROOT, "ndmm_", con = "duck"))),
                error = function(e) e)
if (inherits(res, "error")) {
  cat("  build_ndmm() stopped: ", conditionMessage(res), "\n")
  cat("  last statement sent:\n", utils::tail(duck_log$sql, 1), "\n")
}
ok(!inherits(res, "error"), "build_ndmm() completes")

if (!inherits(res, "error")) {
  cat("\n-- the attrition, step by step --\n")
  att <- q(paste("SELECT STEP_NUM, CRITERION, N_PATIENTS FROM", W("NDMM_ATTRITION"),
                 "WHERE RUN_ID = 'mdvtest1' ORDER BY STEP_NUM"))
  ok(nrow(att) == 9L, "nine attrition steps")
  for (i in seq_len(min(nrow(att), 9L)))
    ok(att$N_PATIENTS[i] == EXPECTED$attrition[i],
       sprintf("step %d (%s): %s, expected %s", i, att$CRITERION[i],
               att$N_PATIENTS[i], EXPECTED$attrition[i]))

  cat("\n-- who is in the cohort, and when they start --\n")
  coh <- q(paste("SELECT PATID, cast(INDEX_DATE as string) AS INDEX_DATE,",
                 "cast(MM_DX_DT as string) AS MM_DX_DT, cast(ENDDATE as string) AS ENDDATE,",
                 "cast(ENDDATE_CE as string) AS ENDDATE_CE, cast(DEATH_DT as string) AS DEATH_DT,",
                 "GDR_CD, YRDOB, FU_DAYS FROM", W("NDMM_COHORT"), "ORDER BY PATID"))
  ok(identical(sort(coh$PATID), sort(EXPECTED$cohort)),
     paste0("the cohort is ", paste(EXPECTED$cohort, collapse = " "),
            if (!identical(sort(coh$PATID), sort(EXPECTED$cohort)))
              paste0(" - got ", paste(coh$PATID, collapse = " ")) else ""))
  idx <- setNames(coh$INDEX_DATE, coh$PATID)
  for (p in names(EXPECTED$index))
    ok(identical(unname(idx[p]), EXPECTED$index[[p]]),
       paste0(p, " is indexed ", EXPECTED$index[[p]], " (got ", idx[p], ")"))
  dxd <- setNames(coh$MM_DX_DT, coh$PATID)
  for (p in names(EXPECTED$mm_dx))
    ok(identical(unname(dxd[p]), EXPECTED$mm_dx[[p]]),
       paste0(p, "'s diagnosis is dated to the first of its month, ",
              EXPECTED$mm_dx[[p]], " (got ", dxd[p], ")"))
  row <- function(p) coh[coh$PATID == p, , drop = FALSE]
  ok(identical(row("P17")$DEATH_DT, "2021-03-01") && identical(row("P17")$ENDDATE, "2021-03-01"),
     "P17 dies at the FF1 discharge whose outcome is a death code, and ENDDATE is that day")
  ok(all(is.na(coh$DEATH_DT[coh$PATID != "P17"])), "nobody else dies")
  ok(identical(row("P20")$ENDDATE_CE, "2021-01-20"),
     "P20 was last seen at discharge, so ENDDATE_CE is 2021-01-20")
  ok(identical(row("P20")$ENDDATE, "2026-03-31"),
     "while ENDDATE is the study end - MDV does not see a patient leave")
  ok(identical(row("P01")$GDR_CD, "M") && identical(row("P02")$GDR_CD, "F"),
     "sex is read through MDV_SEX_MALE / MDV_SEX_FEMALE into M and F")
  ok(identical(as.integer(row("P01")$YRDOB), 1954L),
     "the birth year is the first four digits of a yyyyMM birth column")

  cat("\n-- criterion 1 at each reading --\n")
  rules <- q(paste("SELECT RULE, N_PATIENTS, IS_THIS_RUN FROM", W("NDMM_MM_DX_RULES")))
  got <- setNames(rules$N_PATIENTS, rules$RULE)
  for (r in names(EXPECTED$dx_rules))
    ok(isTRUE(got[[r]] == EXPECTED$dx_rules[[r]]),
       sprintf("%s: %s patients, expected %s", r, got[r], EXPECTED$dx_rules[[r]]))
  ok(isTRUE(got[["outpatient months within 30 days of MM therapy (the OC rule)"]] <=
            got[["as configured"]]),
     "the OC outpatient treatment link can only narrow criterion 1")
  ok(sum(rules$IS_THIS_RUN) == 1L && rules$RULE[rules$IS_THIS_RUN == 1L] == "as configured",
     "exactly one row is the applied reading")

  cat("\n-- the MM therapy code list, resolved --\n")
  rc <- q(paste("SELECT med_abbr, code_type, RECEIPTCODE, NAME_ENG FROM", W("NDMM_MMA_RECEIPTS")))
  ok(any(rc$med_abbr == "CARF" & rc$code_type == "NAME_ENG" & rc$RECEIPTCODE == "620000004"),
     "'%carfilzomib%' finds the master's KYPROLIS (Carfilzomib) receipt code, case-insensitively")
  ok(!any(rc$med_abbr == "DEX"), "steroids are not MM therapy")
  ok(!any(rc$med_abbr == "POM"), "a pattern matching no drug in the master resolves to nothing")
  ag <- q(paste("SELECT MED_ABBR, ELIGIBLE, N_PATIENTS FROM", W("NDMM_INDEX_AGENTS")))
  ok(identical(ag$ELIGIBLE[ag$MED_ABBR == "BELA"], 0L), "belantamab may not set the index")
  ok(isTRUE(ag$N_PATIENTS[ag$MED_ABBR == "CARF"] >= 1L), "carfilzomib set P18's index")

  cat("\n-- belantamab after the index goes to lot --\n")
  br <- q(paste("SELECT PATID, cast(BEL_DT as string) AS BEL_DT FROM", W("NDMM_BELANTAMAB_RECONCILE")))
  ok(identical(br$PATID, "P18") && identical(br$BEL_DT, "2020-09-01"),
     "P18's 2020-09-01 belantamab is the one act on the list passed to lot")

  cat("\n-- the descriptive clinical-trial flag --\n")
  ct <- q(paste("SELECT PATID, CLINTRIAL_PRE_DX FROM wk.ndmm_NDMM_CLINTRIAL_FLAGS WHERE PATID = 'P23'"))
  ok(identical(ct$CLINTRIAL_PRE_DX, 1L), "P23's trial diagnosis falls before the MM diagnosis")

  cat("\n-- the MDV value profile --\n")
  prof <- q(paste("SELECT SOURCE, FIELD, VALUE, READ_AS, N_RECORDS FROM", W("NDMM_MDV_SOURCE_PROFILE")))
  ok(any(prof$FIELD == "nyugaikbn" & prof$READ_AS == "inpatient"),
     "the profile reads nyugaikbn 2 as inpatient")
  ok(any(prof$FIELD == "utagaiflg" & prof$VALUE == "1" & prof$READ_AS == "neither"),
     "and shows the suspected records it does not count")

  cat("\n-- the run records what it read --\n")
  md <- q(paste("SELECT MDV_VINTAGE, MDV_IP_RULE, MDV_REQUIRE_CANCERFLG, MDV_SOURCE, FINDINGS, N_NDMM",
                "FROM", W("NDMM_RUN_METADATA"), "WHERE RUN_ID = 'mdvtest1'"))
  ok(nrow(md) == 1L && md$N_NDMM == length(EXPECTED$cohort), "one metadata row, with the cohort's size")
  ok(nrow(md) == 1L && md$MDV_VINTAGE == "2026q2" && md$MDV_IP_RULE == "none",
     "it names the MDV vintage and the inpatient reading")
  ok(nrow(md) == 1L && grepl("col.ff1_outcome=taiintenki", md$MDV_SOURCE, fixed = TRUE),
     "and every column name it read")
  ok(nrow(md) == 1L && grepl("contract deviation: codelist_dir", md$FINDINGS, fixed = TRUE),
     "a fixture code list is recorded as the contract deviation it is")
  st <- q(paste("SELECT STATE FROM", W("NDMM_BUILD_STATUS"), "WHERE RUN_ID = 'mdvtest1'"))
  ok(identical(st$STATE, "complete"), "the build status is complete")
}

cat("\n-- the same build under the OC inpatient rule --\n")
Sys.setenv(NDMM_MDV_IP_RULE = "ff1_chemo", DOMINO_RUN_ID = "mdvtest2")
# The constants read the environment when sourced, so the modules are loaded
# again, the way a new run would load them.
load_ndmm_modules(ROOT); use_duck()
res2 <- tryCatch(suppressMessages(capture.output(build_ndmm(ROOT, "ndmoc_", con = "duck"))),
                 error = function(e) e)
if (inherits(res2, "error")) cat("  stopped: ", conditionMessage(res2), "\n")
ok(!inherits(res2, "error"), "build_ndmm() completes under NDMM_MDV_IP_RULE=ff1_chemo")
if (!inherits(res2, "error")) {
  coh2 <- q("SELECT PATID FROM wk.ndmoc_NDMM_COHORT ORDER BY PATID")$PATID
  ok(identical(coh2, setdiff(EXPECTED$cohort, c("P03", "P20", "P22"))),
     paste0("P03 (fromdate outside FF1), P20 (no chemotherapy) and P22 (no FF1) ",
            "leave; got ", paste(coh2, collapse = " ")))
}
Sys.unsetenv("NDMM_MDV_IP_RULE")

cat("\n-- a value code that is not this delivery's stops the run --\n")
Sys.setenv(MDV_INPATIENT = "9", DOMINO_RUN_ID = "mdvtest3")
load_ndmm_modules(ROOT); use_duck()
res3 <- tryCatch(suppressMessages(capture.output(build_ndmm(ROOT, "ndmbad_", con = "duck"))),
                 error = function(e) conditionMessage(e))
ok(is.character(res3) && length(res3) == 1L && grepl("MDV_INPATIENT", res3, fixed = TRUE),
     "MDV_INPATIENT=9 matches no record, and check_mdv_values() says so by name")
Sys.unsetenv("MDV_INPATIENT")

cat("\n-- a column name that is not this delivery's stops the run before any work --\n")
Sys.setenv(MDV_COL_BIRTH = "birth_ym", DOMINO_RUN_ID = "mdvtest4")
load_ndmm_modules(ROOT); use_duck()
res4 <- tryCatch(suppressMessages(capture.output(build_ndmm(ROOT, "ndmcol_", con = "duck"))),
                 error = function(e) conditionMessage(e))
ok(is.character(res4) && length(res4) == 1L && grepl("no column birth_ym", res4, fixed = TRUE),
   "MDV_COL_BIRTH=birth_ym is refused at the preflight, naming the table and column")
Sys.unsetenv("MDV_COL_BIRTH")

duck_stop()
report()
