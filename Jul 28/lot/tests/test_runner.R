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
              "ALLO_LOT_SPAN", "MAX_LOT", "CODELIST_WAIVERS")
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
# build_lot.R too: the SCT materialization names live there now that the
# fresh-session path no longer carries its own copy.
step_src <- unlist(lapply(c(list.files(file.path(ROOT, "R", "steps"), "\\.R$",
                                       full.names = TRUE),
                            file.path(ROOT, "R", "build_lot.R")),
                          readLines, warn = FALSE))
step_src <- step_src[!grepl("^\\s*(#|--)", step_src)]
# Two forms: lot_out("NAME") directly, and name = "NAME" in a list whose
# entries are passed to lot_out(). Scanning only the first missed three.
lits <- unlist(regmatches(step_src, gregexpr("lot_out\\((\'|\")[A-Z_0-9]+(\'|\")\\)",
                                             step_src, perl = TRUE)))
# Only entries that also name a source view are tables; the bare name = "..."
# form is also used for QC check labels, which are not outputs.
vlines <- grep("view = ", step_src, fixed = TRUE, value = TRUE)
named <- unlist(regmatches(vlines, gregexpr("(?<=name = \")[A-Z_0-9]{4,}(?=\")",
                                            vlines, perl = TRUE)))
OUTPUTS <- unique(c(gsub("lot_out\\(|\'|\"|\\)", "", lits), named))
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
           "phase_codelists", "record_codelist_hashes",
           "phase_patient_input", "materialize_cohort_input",
           "check_claim_ndc",
           "phase_mma_map",
           "phase_lot1_base", "phase_sct", "phase_lot1_sct",
           "phase_lot1_end", "phase_qc",
           "check_lot1_invariants", "phase_persist", "materialize_sct_views",
           "build_lot2_5",
           "check_lot_long", "record_final_counts", "phase_line_criteria",
           "check_run_recorded")
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
ok(all(c("CODELIST_WAIVERS_REQUESTED", "CODELIST_WAIVERS_APPLIED") %in%
         names(BUILD_STATUS_COLS)),
   "the status row separates the waivers asked for from the ones that fired")
# 08_persist writes metadata inside a tryCatch, so confirm the row arrived.
ok(grepl("check_run_recorded", bl, fixed = TRUE),
   "a run with no metadata row is not called complete")

cat("\n-- an older status table is upgraded, not written into blind --\n")
# CREATE TABLE IF NOT EXISTS does nothing to a table an earlier version of this
# package left behind, so a run after a column was added would INSERT a column
# that is not there. LOT_RUN_METADATA already had a DESCRIBE/ALTER path; this
# table had only a comment claiming that naming the columns was enough, which
# prevents a positional mis-fill but cannot supply a missing column.
se <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "build_lot.R"), envir = se)
assign("log_msg", function(...) invisible(NULL), envir = se)
assign("lot_out", function(x) paste0("wk.p_", x), envir = se)
assign("codelist_waivers", function() "code_types", envir = se)
assign("run_id", "TESTRUN", envir = se)
BSC <- get("BUILD_STATUS_COLS", envir = se)
# `present` is what DESCRIBE answers; NULL means it could not answer at all.
sql_for <- function(present) {
  out <- character(0)
  assign("db_exec", function(con, s) { out <<- c(out, s); invisible(TRUE) }, envir = se)
  assign("db_q", if (is.null(present)) function(con, s) stop("no such table")
         else function(con, s) data.frame(col_name = present, stringsAsFactors = FALSE),
         envir = se)
  se$write_build_status(NULL, list(input_cohort_table = "COH",
                                   object_prefix = "p_"), "started")
  out
}
old <- sql_for(setdiff(names(BSC), "CODELIST_WAIVERS_APPLIED"))
ok(any(grepl(paste0("ALTER TABLE wk.p_LOT_BUILD_STATUS ADD COLUMNS ",
                    "(CODELIST_WAIVERS_APPLIED STRING)"), old, fixed = TRUE)),
   "a table left by an earlier version gets the column it is missing")
ok(which(grepl("ALTER", old))[1] < which(grepl("INSERT", old))[1],
   "added before the insert that needs it, not after")
cur <- sql_for(names(BSC))
ok(!any(grepl("ALTER", cur)), "a current table is left alone")
ok(any(grepl(paste0("(", paste(names(BSC), collapse = ", "), ")"), cur, fixed = TRUE)),
   "the insert still names every column, so nothing is filled positionally")
ok(any(grepl(paste(paste(names(BSC), BSC), collapse = ", "), cur, fixed = TRUE)),
   "and one declaration drives the CREATE, the upgrade and the INSERT alike")
# An empty answer means DESCRIBE failed, not that the table has no columns.
# Adding all six to a table that has them would error on the first.
ok(!any(grepl("ALTER", sql_for(NULL))),
   "a DESCRIBE that cannot answer adds nothing")

# Requested is what the run was given; applied is what phase_codelists actually
# waived. A run can ask for a waiver on a condition that never occurs, and
# recording that as "waived" would say something false about the code lists.
assign("codelist_waivers", function() c("uncoded_meds", "code_types"), envir = se)
options(lot_waivers_applied = "code_types")
ins <- grep("INSERT", sql_for(names(BSC)), value = TRUE)[1]
ok(grepl("'uncoded_meds|code_types'", ins, fixed = TRUE),
   "the row records both waivers the run asked for")
ok(grepl("'code_types', current_timestamp()", ins, fixed = TRUE),
   "...and only the one that actually fired as applied")
options(lot_waivers_applied = NULL)
ins <- grep("INSERT", sql_for(names(BSC)), value = TRUE)[1]
ok(grepl("'uncoded_meds|code_types', '', current", ins, fixed = TRUE),
   "nothing fired yet reads as empty, not as the requested list")
# Cleared at the start of a run, or a second build in one session inherits it.
ok(grepl("options(lot_waivers_applied = character(0), lot_codelist_md5 = list())",
         bl, fixed = TRUE),
   "and it is cleared before the run writes 'started'")

cat("\n-- the code lists are recorded and checked --\n")
# They live outside git, so the run log is the only record of which version
# built a cohort.
cl <- paste(readLines(file.path(ROOT, "R", "codelists_lot.R"), warn = FALSE),
            collapse = "\n")
cls <- readLines(file.path(ROOT, "R", "codelists_lot.R"), warn = FALSE)
hashes <- grep("tools::md5sum(csv_path)", cls, fixed = TRUE)
read_at <- grep("read.csv(csv_path", cls, fixed = TRUE)
ok(length(hashes) == 2 && length(read_at) == 1 &&
     hashes[1] < read_at[1] && hashes[2] > read_at[1],
   "each code list is hashed before and after the read")
ok(grepl("md5 ", cl, fixed = TRUE), "and the hash goes in the run log")
ok(grepl("CODELIST_FILES", cl, fixed = TRUE),
   "only the four declared file names can be loaded")

# The guard has to actually behave, not just be present.
cle <- new.env(parent = globalenv())
assign("log_msg", function(...) invisible(NULL), envir = cle)
assign("glue", function(..., .envir = parent.frame()) paste0(..., collapse = ""), envir = cle)
assign("lot_config", function() list(codelist_dir = tempdir()), envir = cle)
sys.source(file.path(ROOT, "R", "codelists_lot.R"), envir = cle)
f <- file.path(tempdir(), "cl_mma_rollup.csv")
writeLines(c("CL_MED_ABBR", "LEN"), f)
ok(!inherits(tryCatch(cle$load_codelist_csv("cl_mma_rollup.csv", "CL_MED_ABBR"),
                      error = function(e) e), "error"),
   "a normal read succeeds")
ok(inherits(tryCatch(cle$load_codelist_csv("not_a_codelist.csv", "X"),
                     error = function(e) e), "error"),
   "an undeclared file name is refused")
# The read is what captures the hash for LOT_CODELIST_METADATA; a test that set
# that record itself would never notice the capture going away.
options(lot_codelist_md5 = list())
invisible(cle$load_codelist_csv("cl_mma_rollup.csv", "CL_MED_ABBR"))
seen1 <- getOption("lot_codelist_md5")
ok(identical(names(seen1), "cl_mma_rollup.csv") &&
     identical(seen1[["cl_mma_rollup.csv"]]$md5, unname(tools::md5sum(f))) &&
     identical(seen1[["cl_mma_rollup.csv"]]$n_rows, 1L),
   "reading a code list records its md5 and row count for the metadata table")
options(lot_codelist_md5 = NULL)
# Leading zeros must survive, or an NDC silently becomes a different drug.
writeLines(c("CL_CODE", "00093075601"), f)
sqltxt <- cle$load_codelist_csv("cl_mma_rollup.csv", "CL_CODE")
ok(grepl("00093075601", sqltxt, fixed = TRUE),
   "leading zeros survive the read")
unlink(f)

cat("\n-- a bad code list stops the build, it does not warn and continue --\n")
# All four checks used to print a warning inside a tryCatch that also
# swallowed query errors, so a code list that changed who counts as treated
# went through silently.
cd <- paste(readLines(file.path(ROOT, "R", "steps", "01_codelists.R"), warn = FALSE),
            collapse = "\n")
ok(!grepl("WARNING: Codelist consistency QC failed", cd, fixed = TRUE),
   "the tryCatch that swallowed QC errors is gone")
ok(grepl("stop(\"The production code lists would change", cd, fixed = TRUE),
   "the checks stop the build")
ok(grepl("codelist_waivers()", cd, fixed = TRUE),
   "and a waiver names the individual check, not all of them")
for (w in c("orphan_meds", "uncoded_meds", "unexpected_types", "multi_class",
            "code_to_med", "bad_ndc", "subs_sub", "subs_orig", "ndc_shape",
            "class_agreement"))
  ok(grepl(paste0(w, " <-"), cd, fixed = TRUE), paste0(w, " is checked"))
# bad_ndc catches the all-zero key. The rest is silent because the join pads
# whatever digits it finds, so each of these becomes a real-looking but
# different eleven-digit key. The contract is canonical eleven digits.
ok(grepl("WHERE CL_CODE_TYPE = 'NDC' AND (has_alpha OR n_digits <> 11)", cd, fixed = TRUE),
   "the code list has to carry eleven-digit NDCs, not merely plausible ones")
# bad_ndc runs first. Casting the stripped code to a number raises a bare
# conversion error on 'ABC' (strips to '') or on an overlong value, before
# ndc_shape can say what is wrong with the row.
ok(grepl("RLIKE '^0+$'", cd, fixed = TRUE) &&
     !grepl("AS bigint) = 0", cd, fixed = TRUE),
   "the all-zero test is string logic, so a malformed code reaches ndc_shape")
for (shape in c("WHEN has_alpha      THEN 'non-digits'",
                "WHEN n_digits > 11  THEN 'over eleven digits'",
                "WHEN n_digits = 10  THEN 'ten digits'"))
  ok(grepl(shape, cd, fixed = TRUE), paste0("and reports which: ", trimws(shape)))
# Ten digits is its own name: it is a real FDA form whose layout the strip at
# S01 destroys, so waiving it is a judgement the study team can make. Waiving
# it must not also accept 'ABC123'.
ok(grepl('check = "ndc_short"', cd, fixed = TRUE) &&
     grepl('check = "ndc_shape"', cd, fixed = TRUE),
   "ten-digit codes are waivable separately from malformed ones")
# The two files are compared to each other, not each to itself: MED_CLASS on a
# claim comes from the code list while the LOT1_CLASS_<x> columns are named
# from the rollup's classes, so a disagreement is an always-zero column.
ok(grepl("INNER JOIN mma_rollup r ON c.CL_MED_ABBR = r.CL_MED_ABBR", cd, fixed = TRUE),
   "class agreement joins the code list to the rollup")
# Compared as sets, so a med one file classes two ways is compared rather than
# skipped. Requiring each file to be unambiguous first - which is what this did
# - left such a med checked by neither whenever multi_class was waived.
ok(grepl("concat_ws(',', sort_array(collect_set(c.CL_MED_CLASS)))", cd, fixed = TRUE) &&
     !grepl("count(DISTINCT c.CL_MED_CLASS) = 1", cd, fixed = TRUE),
   "class agreement compares the whole set, skipping no medication")
ok("multi_class" %in% FATAL_CHECKS,
   "...and multi_class is fatal, so min() never picks a class silently")
mmx <- paste(readLines(file.path(ROOT, "R", "steps", "03_mma_map.R"), warn = FALSE),
             collapse = "\n")
ok(grepl("c.CL_MED_CLASS AS MED_CLASS", mmx, fixed = TRUE) &&
     grepl("FROM mma_rollup ORDER BY CL_MED_CLASS", cd, fixed = TRUE),
   "...which is the pairing that matters: claims classed from one, columns from the other")
# NOT IN against a column that may be NULL returns no rows at all, so the
# check would pass by being unanswerable. Both sides use NOT EXISTS.
ok(length(gregexpr("NOT EXISTS (", cd, fixed = TRUE)[[1]]) == 2 &&
     !grepl("NOT IN (SELECT", cd, fixed = TRUE),
   "the substitution checks cannot pass by being unanswerable")
# Extraction only joins NDC and HCPCS; the source also accepted ICD, which
# matches nothing.
ok(grepl('EXTRACTED_CODE_TYPES <- c("NDC", "HCPCS")', cd, fixed = TRUE),
   "the accepted code types are the ones extraction actually reads")

cat("\n-- ...and the stop actually fires, not just appears in the source --\n")
# Static greps cannot tell a stop() that runs from one that never does. Drive
# phase_codelists() with stubbed answers and see what it does.
mk_db_q <- function(problem) function(con, sql) {
  if (grepl("r.CL_MED_ABBR IS NULL", sql)) return(if (problem == "orphan")
    data.frame(CL_MED_ABBR = "XYZ", n_codes = 3) else
    data.frame(CL_MED_ABBR = character(0), n_codes = integer(0)))
  if (grepl("c.CL_MED_ABBR IS NULL", sql)) return(if (problem == "uncoded")
    data.frame(CL_MED_ABBR = "ABC", CL_MED_CLASS = "IMID") else
    data.frame(CL_MED_ABBR = character(0), CL_MED_CLASS = character(0)))
  if (grepl("count\\(DISTINCT CL_MED_ABBR\\) AS n_meds", sql))
    return(if (problem == "code_to_med")
      data.frame(CL_CODE_TYPE = "NDC", CL_CODE = "00011122233", n_meds = 2,
                 meds = "A, B") else
      data.frame(CL_CODE_TYPE = character(0), CL_CODE = character(0),
                 n_meds = integer(0), meds = character(0)))
  if (grepl("GROUP BY CL_CODE_TYPE", sql))
    return(data.frame(CL_CODE_TYPE = if (problem == "type") c("NDC", "ICD")
                                     else c("NDC", "HCPCS"), n_codes = c(10, 10)))
  if (grepl("HAVING count\\(DISTINCT CL_MED_CLASS\\) > 1", sql))
    return(if (problem == "class")
      data.frame(CL_MED_ABBR = "DUP", n_classes = 2, classes = "A, B") else
      data.frame(CL_MED_ABBR = character(0), n_classes = integer(0),
                 classes = character(0)))
  if (grepl("AS n_defs", sql))
    return(if (problem == "rollup_defs") data.frame(CL_MED_ABBR = "LEN", n_defs = 2)
           else data.frame(CL_MED_ABBR = character(0), n_defs = integer(0)))
  if (grepl("AS n_rollup", sql))
    return(data.frame(n_rollup = if (problem == "blank_keys") 2 else 0,
                      n_codelist = 0))
  if (grepl("RLIKE '^0+$'", sql, fixed = TRUE))
    return(if (problem == "bad_ndc") data.frame(CL_CODE = "00000000000", CL_MED_ABBR = "X")
           else data.frame(CL_CODE = character(0), CL_MED_ABBR = character(0)))
  if (grepl("AS why", sql, fixed = TRUE))
    return(switch(problem,
      ndc_shape = data.frame(CL_CODE = "ABC123", CL_MED_ABBR = "LEN",
                             n_digits = 3L, why = "non-digits"),
      ndc_short = data.frame(CL_CODE = "5024204062", CL_MED_ABBR = "LEN",
                             n_digits = 10L, why = "ten digits"),
      data.frame(CL_CODE = character(0), CL_MED_ABBR = character(0),
                 n_digits = integer(0), why = character(0))))
  if (grepl("AS rollup_class", sql, fixed = TRUE))
    return(if (problem == "class_agreement")
      data.frame(CL_MED_ABBR = "LEN", codelist_class = "IMID", rollup_class = "PI")
      else data.frame(CL_MED_ABBR = character(0), codelist_class = character(0),
                      rollup_class = character(0)))
  if (grepl("c.CL_MED_ABBR = p.substitute_med", sql, fixed = TRUE))
    return(if (problem == "subs_substitute") data.frame(med = "LENN")
           else data.frame(med = character(0)))
  if (grepl("c.CL_MED_ABBR = p.original_med", sql, fixed = TRUE))
    return(if (problem == "subs_original") data.frame(med = "BORT")
           else data.frame(med = character(0)))
  if (grepl("count\\(DISTINCT CL_MED_ABBR\\) AS n FROM mma_rollup", sql)) return(data.frame(n = 28))
  if (grepl("count\\(\\*\\) AS n FROM mma_codelist", sql)) return(data.frame(n = 500))
  if (grepl("SELECT DISTINCT CL_MED_ABBR FROM mma_rollup", sql, fixed = TRUE))
    return(data.frame(CL_MED_ABBR = switch(problem,
      collide = c("CAR-T", "CAR T"), quoted = c("LEN", "O'BRIEN"),
      cnt = c("LEN", "CNT"),
      c("LEN", "BOR"))))
  if (grepl("SELECT DISTINCT CL_MED_CLASS FROM mma_rollup", sql, fixed = TRUE))
    return(data.frame(CL_MED_CLASS = switch(problem,
      collide_class = c("ANTI-CD38", "ANTI CD38"), c("IMID", "PI"))))
  data.frame()
}
ce <- new.env(parent = globalenv())
for (nm in c("log_msg", "print")) assign(nm, function(...) invisible(NULL), envir = ce)
assign("run_step", function(...) invisible(TRUE), envir = ce)
assign("glue", function(..., .envir = parent.frame()) paste0(..., collapse = ""), envir = ce)
assign("load_codelist_csv", function(...) "(SELECT 1) src", envir = ce)
# codelist_waivers() lives in build_lot.R, which this env does not source. It
# filters to WAIVABLE_CHECKS, and the stub has to as well - a stub that waived
# anything named would make the fatal-check assertions below pass on their own.
assign("codelist_waivers", function()
  { v <- trimws(strsplit(Sys.getenv("CODELIST_WAIVERS", unset = ""), "[,|]")[[1]])
    intersect(v[nzchar(v)], WAIVABLE_CHECKS) },
  envir = ce)
sys.source(file.path(ROOT, "R", "steps", "01_codelists.R"), envir = ce)
Sys.unsetenv("CODELIST_WAIVERS")
assign("db_q", mk_db_q("none"), envir = ce)
ok(!inherits(tryCatch(ce$phase_codelists(NULL), error = function(e) e), "error"),
   "a consistent pair of code lists runs")
for (prob in c("orphan", "uncoded", "type", "class", "code_to_med", "bad_ndc",
               "rollup_defs", "blank_keys", "subs_substitute", "subs_original",
               "ndc_shape", "ndc_short", "class_agreement")) {
  assign("db_q", mk_db_q(prob), envir = ce)
  ok(inherits(tryCatch(ce$phase_codelists(NULL), error = function(e) e), "error"),
     paste0("'", prob, "' stops the build"))
}
# A waiver names one check. A medication deliberately left without extractable
# codes is an expected condition a study may accept; waiving it must NOT also
# waive a code naming two different drugs.
Sys.setenv(CODELIST_WAIVERS = "uncoded_meds")
assign("db_q", mk_db_q("uncoded"), envir = ce)
ok(!inherits(tryCatch(ce$phase_codelists(NULL), error = function(e) e), "error"),
   "waiving uncoded_meds lets a deliberately uncoded medication through")
assign("db_q", mk_db_q("code_to_med"), envir = ce)
ok(inherits(tryCatch(ce$phase_codelists(NULL), error = function(e) e), "error"),
   "and still stops on a code naming two medications")
Sys.unsetenv("CODELIST_WAIVERS")

cat("\n-- the checks ask about rows extraction can reach --\n")
# Every join in 03_mma_map is ON c.CL_CODE_TYPE = 'NDC' or 'HCPCS'. A check
# counting a row of any other type answers about a row the build never reads:
# a medication coded only as ICD looked coded while producing nothing, and an
# unused ICD code naming two drugs failed the build over a row nothing joins.
ok(grepl("SELECT * FROM mma_codelist WHERE CL_CODE_TYPE IN ('NDC', 'HCPCS')",
         cd, fixed = TRUE),
   "there is one view of the rows extraction reaches")
ok(identical(sort(unique(gsub(".*= '|'.*", "",
     regmatches(mmx, gregexpr("c\\.CL_CODE_TYPE = '[A-Z]+'", mmx))[[1]]))),
     c("HCPCS", "NDC")),
   "...and those are the types 03_mma_map actually joins on")
# Every query keyed on a medication abbreviation must read that view. Scanning
# each query separately, because the file still names the full list on purpose
# for code_types, and for the two NDC checks that filter the type themselves.
qs <- strsplit(cd, "db_q(con, \"", fixed = TRUE)[[1]][-1]
qs <- vapply(qs, function(q) sub("\").*", "", q), character(1), USE.NAMES = FALSE)
# A query is scoped if it reads the view, or filters CL_CODE_TYPE itself as the
# two NDC checks do. The load-sanity count names neither and is not a
# per-medication check, so it is not caught by this and does not need to be.
unscoped <- Filter(function(q)
  grepl("CL_MED_ABBR", q) && !grepl("CL_CODE_TYPE", q) &&
    grepl("mma_codelist", gsub("mma_extractable_codelist", "", q)), qs)
ok(length(unscoped) == 0,
   if (length(unscoped)) paste0("a check keyed on the abbreviation reads the ",
                                "full list: ", substr(trimws(unscoped[1]), 1, 60))
   else paste0("all ", sum(grepl("CL_MED_ABBR", qs) & !grepl("CL_CODE_TYPE", qs)),
               " abbreviation-keyed checks read the extractable view"))
ok(any(grepl("GROUP BY CL_CODE_TYPE", qs, fixed = TRUE) &
         !grepl("extractable", qs, fixed = TRUE)),
   "code_types still reports over the whole list - that is its job")

cat("\n-- the generated column names have to be usable --\n")
# sanitize_col maps punctuation and spaces to '_', and the value itself goes
# into a SQL string literal unescaped. Neither was checked, here or in LOT2-5,
# which discovers its meds and classes from the same rollup.
for (p in list(list(k = "collide", what = "two medications making one column"),
               list(k = "collide_class", what = "two classes making one column"),
               list(k = "quoted", what = "a name that would close the literal"))) {
  assign("db_q", mk_db_q(p$k), envir = ce)
  err <- tryCatch({ ce$phase_codelists(NULL); "" }, error = conditionMessage)
  ok(nzchar(err), paste0(p$what, " stops the build"))
}
assign("db_q", mk_db_q("collide"), envir = ce)
err <- tryCatch({ ce$phase_codelists(NULL); "" }, error = conditionMessage)
ok(grepl("CAR_T", err, fixed = TRUE) && grepl("CAR-T", err, fixed = TRUE) &&
     grepl("CAR T", err, fixed = TRUE),
   "...naming the column and both values that produce it")
# LOT1_MED_CNT is a fixed column - the induction medication count - so a
# medication abbreviated CNT generates a second column of that name.
assign("db_q", mk_db_q("cnt"), envir = ce)
cerr <- tryCatch({ ce$phase_codelists(NULL); "" }, error = conditionMessage)
ok(grepl("LOT1_MED_CNT", cerr, fixed = TRUE),
   "an abbreviation of CNT collides with the fixed count column and stops it")
ok(any(grepl("count(DISTINCT im.MED_ABBR) AS LOT1_MED_CNT",
             readLines(file.path(ROOT, "R", "steps", "04_lot1_base.R"), warn = FALSE),
             fixed = TRUE)),
   "...and that column really is fixed, not merely assumed to be")
# The check calls sanitize_col rather than repeating its expression, so it
# cannot drift from the generator it is guarding.
ok(grepl("san <- sanitize_col(nm$v)", cd, fixed = TRUE),
   "and it asks sanitize_col itself, not a copy of what sanitize_col does")
lb <- paste(readLines(file.path(ROOT, "R", "steps", "10_lot2_5_base.R"), warn = FALSE),
            collapse = "\n")
ok(grepl("FROM mma_rollup", lb, fixed = TRUE),
   "LOT2-5 draws its meds and classes from the same rollup, so this covers it")

# phase_qc reports the SCT end date past observation as INVESTIGATE inside a
# tryCatch, so a run could finish with it. The invariant is the fail-loud copy;
# without it the comment in 07_qc.R claiming these are re-checked was wrong.
inv <- get("LOT1_INVARIANTS", envir = env)
inv_sql <- paste(vapply(inv, function(i) i$sql, character(1)), collapse = " ")
ok(any(vapply(inv, function(i) identical(i$name, "SCT end date past observation"),
              logical(1))),
   "LOT1_TX_ENDDATE past observation is a fail-loud invariant, not only QC")
ok(grepl("sct.LOT1_TX_ENDDATE > p.OBS_END_DT", inv_sql, fixed = TRUE),
   "...on the column phase_qc reports, not a neighbouring one")
qc7 <- paste(readLines(file.path(ROOT, "R", "steps", "07_qc.R"), warn = FALSE),
             collapse = "\n")
ok(grepl("LOT1_TX_ENDDATE > lb.OBS_END_DT", qc7, fixed = TRUE),
   "and that is the condition 07_qc.R still reports")

cat("\n-- the run says what it produced, not only what LOT1 saw --\n")
# phase_persist writes LOT_RUN_METADATA before LOT2-5 exists, so its counts
# stop at LOT1 and a row on its own says nothing about LOT_LONG.
fe <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "build_lot.R"), envir = fe)
assign("log_msg", function(...) invisible(NULL), envir = fe)
assign("lot_out", function(x) paste0("wk.p_", x), envir = fe)
assign("run_id", "R1", envir = fe)
FSQL <- character(0); FQRY <- character(0)
assign("db_exec", function(con, s) { FSQL <<- c(FSQL, s); TRUE }, envir = fe)
drive_fm <- function(have) {
  FSQL <<- character(0); FQRY <<- character(0)
  assign("db_q", function(con, s) {
    FQRY <<- c(FQRY, s)
    if (grepl("DESCRIBE", s)) return(if (is.null(have)) stop("no")
                                     else data.frame(col_name = have))
    data.frame(LOT_NUM = 1:3, n = c(900, 400, 120))
  }, envir = fe)
  tryCatch({ fe$record_final_counts(NULL, list(),
                                    list(n_rows = 1420, n_patients = 900)); NULL },
           error = conditionMessage)
}
base_cols <- c("RUN_ID", "N_COHORT_PATIENTS", "N_LOT1_PATIENTS")
ok(is.null(drive_fm(base_cols)), "a metadata table without the columns gets them")
ok(sum(grepl("ALTER", FSQL)) == 1 &&
     all(vapply(names(get("FINAL_METADATA_COLS", envir = fe)),
                function(m) any(grepl(m, FSQL, fixed = TRUE)), logical(1))),
   "...in one ALTER, since phase_persist creates the table without any of them")
# The totals come from check_lot_long, which has just counted them, so the only
# scan here is the one it does not do. FQRY is every db_q, not just the writes -
# an earlier version watched db_exec and so proved nothing.
reads <- Filter(function(q) !grepl("DESCRIBE", q), FQRY)
ok(length(reads) == 1 && grepl("GROUP BY LOT_NUM", reads[1]),
   paste0("and it scans once, for the line distribution only (", length(reads), ")"))
ok(any(grepl("LOT_LONG_BY_LINE = '1:900|2:400|3:120'", FSQL, fixed = TRUE)),
   "the line distribution is recorded, not just a total")
ok(any(grepl("WHERE RUN_ID = 'R1'", FSQL, fixed = TRUE)),
   "against this run's row, not every row in the table")
ok(is.null(drive_fm(c(base_cols, names(get("FINAL_METADATA_COLS", envir = fe))))) &&
     !any(grepl("ALTER", FSQL)),
   "a later run finds them and alters nothing")
ok(!is.null(drive_fm(NULL)),
   "a DESCRIBE that cannot answer stops rather than adding columns blind")
# Recorded after check_lot_long, so the numbers describe a table already found
# usable - and check_run_recorded now asks for them, not merely for a row.
ok(regexpr("check_lot_long(", body, fixed = TRUE) <
     regexpr("record_final_counts(", body, fixed = TRUE),
   "the counts are taken after LOT_LONG has passed its checks")
ok(grepl("N_LOT_LONG_ROWS IS NOT NULL", bl, fixed = TRUE),
   "and a run with a LOT1-only metadata row is not called complete")

cat("\n-- the outputs say which code lists built them --\n")
# The hashes are logged as the files are read, but a log is a separate artefact
# - filed away from the tables, or lost, and the outputs no longer say what made
# them. One row per file per run.
he <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "codelists_lot.R"), envir = he)
sys.source(file.path(ROOT, "R", "build_lot.R"), envir = he)
assign("log_msg", function(...) invisible(NULL), envir = he)
assign("lot_out", function(x) paste0("wk.p_", x), envir = he)
assign("run_id", "R1", envir = he)
HSQL <- character(0)
assign("db_exec", function(con, s) { HSQL <<- c(HSQL, s); TRUE }, envir = he)
CLF <- get("CODELIST_FILES", envir = he)
drive_h <- function(files) {
  HSQL <<- character(0)
  options(lot_codelist_md5 = setNames(lapply(seq_along(files), function(i)
    list(md5 = sprintf("%032d", i), n_rows = i * 100L)), files))
  r <- tryCatch({ he$record_codelist_hashes(NULL, list()); NULL }, error = conditionMessage)
  options(lot_codelist_md5 = NULL); r
}
ok(is.null(drive_h(CLF)), "every code list read leaves a row")
ins <- grep("INSERT", HSQL, value = TRUE)[1]
for (f in CLF)
  ok(grepl(paste0("'", f, "'"), ins, fixed = TRUE), paste0(f, " is named in the row set"))
ok(grepl("'00000000000000000000000000000001'", ins, fixed = TRUE),
   "with the md5 that was taken when the file was read")
ok(any(grepl("DELETE FROM wk.p_LOT_CODELIST_METADATA WHERE RUN_ID = 'R1'",
             HSQL, fixed = TRUE)),
   "and a re-run replaces its own rows rather than doubling them")
# A file that was never read must not silently produce a row-less run.
err <- drive_h(CLF[-length(CLF)])
ok(!is.null(err) && grepl(CLF[length(CLF)], err, fixed = TRUE),
   "a code list with no recorded hash stops the build, naming the file")
# Recorded straight after the code lists are read, so a run that fails later
# still says what it was reading - and completion requires the rows.
ok(regexpr("phase_codelists(", body, fixed = TRUE) <
     regexpr("record_codelist_hashes(", body, fixed = TRUE) &&
     regexpr("record_codelist_hashes(", body, fixed = TRUE) <
     regexpr("phase_patient_input(", body, fixed = TRUE),
   "written as soon as the hashes are known, not at the end")
ok(grepl('"LOT_CODELIST_METADATA"', bl, fixed = TRUE) &&
     grepl('c("LOT_RUN_METADATA", "LOT_QC_SUMMARY", "LOT_CODELIST_METADATA")',
           bl, fixed = TRUE),
   "and a run with no hash rows is not called complete")

cat("\n-- the cohort is pinned, not re-read --\n")
# A Spark temporary view re-runs its query on every read, so lot_patient_input
# over the cohort table is not a snapshot: a cohort job rebuilding that table
# mid-run changes what LOT reads from there on. "Do not rebuild it" is not
# enforceable for a package pointed at many cohorts, so the run takes its own
# copy and reads that.
ok(grepl("CREATE OR REPLACE TABLE {lot_out('LOT_PATIENT_INPUT')} AS", bl, fixed = TRUE),
   "the cohort input is written to a table of its own")
ok(grepl("CREATE OR REPLACE TEMPORARY VIEW lot_patient_input AS\n    SELECT * FROM {lot_out('LOT_PATIENT_INPUT')}",
         bl, fixed = TRUE),
   "...and the view is repointed at it, so every later read hits the copy")
ok("LOT_PATIENT_INPUT" %in% OUTPUTS,
   "it is a prefixed output, so two cohorts cannot share one snapshot")
# Before anything reads the cohort. phase_patient_input defines the view;
# nothing between that and the copy may consume it.
pos <- function(f) regexpr(paste0("(?<![A-Za-z0-9_.])", f, "\\("), body, perl = TRUE)
ok(pos("phase_patient_input") < pos("materialize_cohort_input") &&
     pos("materialize_cohort_input") < pos("check_claim_ndc") &&
     pos("materialize_cohort_input") < pos("phase_mma_map"),
   "pinned before the first phase that joins it")

cat("\n-- the claim side of the NDC contract --\n")
# ndc_shape and ndc_short constrain the code list; both joins pad the CLAIM the
# same way, so a ten-digit claim NDC has the same layout problem and a
# canonical code then misses a real claim. phase_qc does not cover this: it
# profiles rx only, measures a different normalization from the join, warns
# only when the two length sets are wholly disjoint, swallows its errors, and
# runs after LOT1 is built.
ne <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "build_lot.R"), envir = ne)
for (nm in c("log_msg", "print")) assign(nm, function(...) invisible(NULL), envir = ne)
assign("cdm_src", function(t) paste0("cdm.", t), envir = ne)
cfg_ndc <- list(tbl_medical = "medical", tbl_rx = "rx")
prow <- function(src, n, a = 0, b = 0, o = 0, alpha = 0, nodig = 0, zero = 0)
  data.frame(SOURCE = src, n_ndc = n, n_11 = a, n_10 = b, n_other = o,
             n_alpha = alpha, n_nodigit = nodig, n_zero = zero)
NSQL <- character(0)
drive_ndc <- function(med, rx) {
  i <- 0
  assign("db_q", function(con, sql) { NSQL <<- c(NSQL, sql); i <<- i + 1
                                      if (i == 1) med else rx }, envir = ne)
  tryCatch({ ne$check_claim_ndc(NULL, cfg_ndc); NULL }, error = conditionMessage)
}
ok(is.null(drive_ndc(prow("medical", 500, a = 500), prow("rx", 9000, a = 9000))),
   "all eleven-digit claim NDCs pass")
ok(is.null(drive_ndc(prow("medical", 0), prow("rx", 9000, a = 9000))),
   "a source with no NDCs at all has nothing to mis-pad")
tend <- drive_ndc(prow("medical", 500, a = 500), prow("rx", 9000, a = 8000, b = 1000))
ok(!is.null(tend), "a ten-digit claim NDC stops the build")
ok(grepl("1000 ten-digit", tend, fixed = TRUE) && grepl("4-4-2", tend, fixed = TRUE),
   "...with the counts and why the pad is only right for one layout")
ok(!is.null(drive_ndc(prow("medical", 500, a = 500, alpha = 3), prow("rx", 10, a = 10))),
   "letters in a claim NDC stop it too, even at eleven digits")
# Split like the code side. Ten digits is a real NDC in a layout the pad has to
# guess - reviewable. Letters, wrong lengths and all-zero cannot be an NDC at
# all, and one waiver covering both would accept ABC123 -> 00000000123 along
# with the case that was actually reviewed.
ok(all(c("claim_ndc_short", "claim_ndc_shape") %in% WAIVABLE_CHECKS) &&
     !any(c("claim_ndc_short", "claim_ndc_shape") %in% FATAL_CHECKS),
   "the two claim-NDC conditions have separate names, both reviewable")
Sys.setenv(CODELIST_WAIVERS = "claim_ndc_short")
options(lot_waivers_applied = character(0))
ok(is.null(drive_ndc(prow("medical", 500, a = 500), prow("rx", 9000, a = 8000, b = 1000))),
   "waiving claim_ndc_short lets a reviewed ten-digit distribution through")
ok(identical(getOption("lot_waivers_applied"), "claim_ndc_short"),
   "...recorded as applied under its own name")
for (p2 in list(list(r = prow("medical", 500, a = 497, alpha = 3), w = "letters"),
                list(r = prow("medical", 500, a = 499, o = 1), w = "another length"),
                list(r = prow("medical", 500, a = 500, zero = 2), w = "all zeros"))) {
  err <- drive_ndc(p2$r, prow("rx", 10, a = 10))
  ok(!is.null(err) && grepl("cannot be an NDC", err, fixed = TRUE),
     paste0("...and does not let ", p2$w, " through with it"))
}
Sys.unsetenv("CODELIST_WAIVERS"); options(lot_waivers_applied = NULL)
# Reviewable, not fatal: these are the CDM's tables, so a run that could not
# proceed would have no remedy short of changing the join. The split is what
# matters - accepting one condition must not accept the other.
Sys.setenv(CODELIST_WAIVERS = "claim_ndc_shape")
options(lot_waivers_applied = character(0))
ok(is.null(drive_ndc(prow("medical", 500, a = 497, alpha = 3), prow("rx", 10, a = 10))),
   "waiving claim_ndc_shape lets a reviewed malformed distribution through")
ok(identical(getOption("lot_waivers_applied"), "claim_ndc_shape"),
   "...recorded as applied under its own name")
tenner <- drive_ndc(prow("medical", 500, a = 500), prow("rx", 9000, a = 8000, b = 1000))
ok(!is.null(tenner) && grepl("Ten-digit", tenner, fixed = TRUE),
   "...and does not let ten-digit values through with it")
Sys.unsetenv("CODELIST_WAIVERS"); options(lot_waivers_applied = NULL)
# Both named together: each is reported under its own name, not merged.
Sys.setenv(CODELIST_WAIVERS = "claim_ndc_shape,claim_ndc_short")
options(lot_waivers_applied = character(0))
ok(is.null(drive_ndc(prow("medical", 500, a = 497, alpha = 3),
                     prow("rx", 9000, a = 8000, b = 1000))),
   "naming both lets a run through that trips both")
ok(setequal(getOption("lot_waivers_applied"), c("claim_ndc_shape", "claim_ndc_short")),
   "...and records both as applied")
Sys.unsetenv("CODELIST_WAIVERS"); options(lot_waivers_applied = NULL)
# All zeros has eleven digits, so only a bucket of its own catches it. It is
# the key a claim with no NDC produces, and bad_ndc treats the same value as
# fatal on the code side.
zed <- drive_ndc(prow("medical", 500, a = 500, zero = 2), prow("rx", 10, a = 10))
ok(!is.null(zed), "an all-zero claim NDC stops it despite being eleven digits")
ok(grepl("2 all zeros", zed, fixed = TRUE), "...and is reported as its own count")
nod <- drive_ndc(prow("medical", 500, a = 499, o = 1, nodig = 1), prow("rx", 10, a = 10))
ok(!is.null(nod) && grepl("1 with no digits", nod, fixed = TRUE),
   "a value with no digits at all is counted and reported")
ok(grepl("cannot be an NDC", nod, fixed = TRUE),
   "...under claim_ndc_shape, not the ten-digit condition")
# The stub decides what the counts are, so it cannot show that the query would
# ever produce them. A value with no digits only reaches the profile because
# the WHERE stopped excluding it - assert that on the SQL.
ok(!any(grepl("AND regexp_replace(cast(t.NDC as string), \'[^0-9]\', \'\') <> \'\'",
              NSQL, fixed = TRUE)),
   "the profile no longer drops the values it is meant to report")
for (b in c("AS n_nodigit", "AS n_zero"))
  ok(all(grepl(b, NSQL, fixed = TRUE)), paste0("the profile counts ", b))
# Waivable, so a first run reports the distribution rather than blocking on a
# shape nobody has seen yet - and what fired is recorded, not just requested.


# Two writers record applied waivers. Each was covered alone; this drives them
# in sequence, so one cannot clobber what the other recorded.
Sys.setenv(CODELIST_WAIVERS = "uncoded_meds,claim_ndc_short")
options(lot_waivers_applied = character(0))
assign("db_q", mk_db_q("uncoded"), envir = ce)
invisible(ce$phase_codelists(NULL))
invisible(drive_ndc(prow("medical", 500, a = 500), prow("rx", 9000, a = 8000, b = 1000)))
assign("db_q", mk_db_q("uncoded"), envir = ce)
invisible(ce$phase_codelists(NULL))
ok(setequal(getOption("lot_waivers_applied"), c("uncoded_meds", "claim_ndc_short")),
   "both waivers survive phase_codelists running a second time")
Sys.unsetenv("CODELIST_WAIVERS"); options(lot_waivers_applied = NULL)
# It has to measure what the join measures, or it answers about another string.
ok(all(grepl("regexp_replace(v, '[^0-9]', '') AS digits", NSQL, fixed = TRUE)),
   "the profile strips to digits, as the join does")
ok(any(grepl("cdm.medical", NSQL, fixed = TRUE)) && any(grepl("cdm.rx", NSQL, fixed = TRUE)),
   "and covers medical as well as rx - phase_qc never looked at medical")
ok(all(grepl("INNER JOIN lot_patient_input p ON t.PATID = p.PATID", NSQL, fixed = TRUE)),
   "scoped to the cohort, so it is not a whole scan of medical")

cat("\n-- some conditions have no reading worth accepting --\n")
# A code counted twice, a code matching every claim with no NDC, a medication
# with no class, an always-zero output column. There is no version of those a
# run should carry on through, so they are not waivable at all.
ok(length(intersect(WAIVABLE_CHECKS, FATAL_CHECKS)) == 0,
   "the two lists do not overlap")
for (f in FATAL_CHECKS) {
  Sys.setenv(CODELIST_WAIVERS = f)
  ok(inherits(tryCatch(check_settings(), error = function(e) e), "error"),
     paste0("naming '", f, "' in CODELIST_WAIVERS is refused up front"))
}
Sys.setenv(CODELIST_WAIVERS = "bad_ndc")
msg <- tryCatch({ check_settings(); "" }, error = conditionMessage)
ok(grepl("cannot be waived", msg, fixed = TRUE),
   "and told why, rather than 'no such check'")
# Refusing at startup is not enough: LOT2-5 can be run on its own and reach the
# code lists without check_settings, so the waiver list itself filters.
ok(length(codelist_waivers()) == 0,
   "codelist_waivers() hands back nothing that cannot be waived")
assign("db_q", mk_db_q("bad_ndc"), envir = ce)
ok(inherits(tryCatch(ce$phase_codelists(NULL), error = function(e) e), "error"),
   "so the check still stops the build even with the waiver set")
Sys.setenv(CODELIST_WAIVERS = "uncoded_meds,bad_ndc")
ok(identical(codelist_waivers(), "uncoded_meds"),
   "a mixed list keeps the reviewable name and drops the rest")
Sys.unsetenv("CODELIST_WAIVERS")

cat("\n-- LOT2-5 reads tables, not repeated CDM scans --\n")
# LOT1 leaves sct_claims_raw, tx_auto_dates and tx_allo_cart_dates as views
# over raw medical/procedure/diagnosis. LOT2-5 reads them once per line, so
# leaving them lazy means Spark re-runs those scans every time. Skipping the
# rebuild is right; skipping the materialization was not.
ok(grepl("materialize_sct_views(con)", body, fixed = TRUE),
   "build_lot() calls materialize_sct_views(), not merely defines it")
mv_at <- regexpr("SCT_MATERIALIZE <- list", bl, fixed = TRUE)
mv <- substr(bl, mv_at, mv_at + 400)
ok(regexpr("sct_claims_raw", mv, fixed = TRUE) <
     regexpr("tx_auto_dates", mv, fixed = TRUE),
   "sct_claims_raw first, so the other two read a table not a CDM scan")
ok(grepl("CREATE OR REPLACE TEMPORARY VIEW {mv$view} AS SELECT * FROM {lot_out(mv$name)}",
         bl, fixed = TRUE),
   "and each view is repointed at its table afterwards")
# The probe must not be the expensive thing it is checking for.
ok(grepl("SHOW VIEWS", bl, fixed = TRUE) &&
     !grepl("SELECT 1 FROM {v} LIMIT 1", bl, fixed = TRUE),
   "existence is asked of the catalogue, not by running the view")

pe <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "build_lot.R"), envir = pe)
assign("log_msg", function(...) invisible(NULL), envir = pe)
asked <- character(0)
vw <- function(names, temp = TRUE)
  data.frame(viewName = names, isTemporary = temp, stringsAsFactors = FALSE)
assign("db_q", function(con, sql) {
  asked <<- c(asked, sql)
  vw(get("LOT2_5_INPUT_VIEWS", envir = pe))
}, envir = pe)
ok(isTRUE(pe$lot_inputs_present(NULL)), "all ten present is detected")
ok(length(asked) == 1 && grepl("SHOW VIEWS", asked[1], fixed = TRUE),
   "with one catalogue query, not ten reads")
assign("db_q", function(con, sql) vw(c("lot_patient_input", "mma_rollup")), envir = pe)
ok(!isTRUE(pe$lot_inputs_present(NULL)), "a missing view is detected")
# SHOW VIEWS lists persistent views too. A persistent table of the same name
# elsewhere in the schema is not the view LOT1 built, and answering yes to it
# would be the false positive that stopping was meant to prevent.
assign("db_q", function(con, sql)
  vw(get("LOT2_5_INPUT_VIEWS", envir = pe), temp = FALSE), envir = pe)
ok(!isTRUE(pe$lot_inputs_present(NULL)),
   "persistent views of the same names do not count as present")
assign("db_q", function(con, sql)
  data.frame(viewName = get("LOT2_5_INPUT_VIEWS", envir = pe)), envir = pe)
ok(!isTRUE(pe$lot_inputs_present(NULL)),
   "and a catalogue with no isTemporary column cannot confirm them either")
assign("db_q", function(con, sql) stop("no such command"), envir = pe)
ok(!isTRUE(pe$lot_inputs_present(NULL)),
   "and a catalogue that cannot answer counts as absent, not as present")
# What build_lot() does about it. Rebuilding would re-read the code lists and
# the cohort table, and the loader compares a file's hash across one read, not
# across two phases - so the run could finish "complete" with LOT1 built from
# one snapshot and LOT_LONG from another. It stops instead, and
# prepare_lot_inputs() is left for a LOT2-5 session entered deliberately.
ok(grepl("  if (!lot_inputs_present(con))\n    stop(", bl, fixed = TRUE),
   "a missing session view stops the run rather than rebuilding it")
# The message names prepare_lot_inputs(); what must not appear is a CALL to it.
ok(!grepl("prepare_lot_inputs(con)", bl, fixed = TRUE),
   "build_lot() never calls prepare_lot_inputs() - one run, one snapshot")
ok(!grepl("prepare_lot_inputs", bl, fixed = TRUE),
   "...and the standalone rebuild is gone entirely, not merely unreferenced")

cat("\n-- LOT_LONG has to be chronologically possible --\n")
# The lines form a chain: each starts strictly after the previous one ended,
# and none runs past the patient's observation. Both are re-derivable, so a
# breach means the iterative builder went wrong - it should stop, not report.
le <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "build_lot.R"), envir = le)
assign("log_msg", function(...) invisible(NULL), envir = le)
assign("lot_out", function(x) x, envir = le)
assign("glue", function(..., .envir = parent.frame()) {
  t <- paste0(..., collapse = "")
  for (v in c("t")) t <- gsub("\\{t\\}", "LOT_LONG", t)
  gsub("\\{cfg\\$max_lot\\}", "5", t)
}, envir = le)
LL_OK <- list(n_rows = 100, n_patients = 40, n_null_start = 0, n_null_end = 0,
              n_end_before_start = 0, n_bad_lot_num = 0)
ll_stub <- function(shape = list(), dup = 0, gaps = 0, seq_bad = 0, past_obs = 0) {
  sh <- modifyList(LL_OK, shape)
  assign("db_q", function(con, sql) {
    if (grepl("HAVING count(*) > 1", sql, fixed = TRUE)) return(data.frame(n = dup))
    if (grepl("lag(LOT_BASE_END_DT)", sql, fixed = TRUE)) return(data.frame(n = seq_bad))
    if (grepl("l.LOT_BASE_END_DT > p.OBS_END_DT", sql, fixed = TRUE)) return(data.frame(n = past_obs))
    if (grepl("HAVING lo <> 1", sql, fixed = TRUE)) return(data.frame(n = gaps))
    as.data.frame(sh)
  }, envir = le)
}
cfg_ll <- list(max_lot = 5L)
ll_stub()
ok(!inherits(tryCatch(le$check_lot_long(NULL, cfg_ll), error = function(e) e), "error"),
   "a sound LOT_LONG passes")
ll_stub(seq_bad = 3)
ok(inherits(tryCatch(le$check_lot_long(NULL, cfg_ll), error = function(e) e), "error"),
   "a line starting on or before the previous line's end stops the build")
ll_stub(past_obs = 2)
ok(inherits(tryCatch(le$check_lot_long(NULL, cfg_ll), error = function(e) e), "error"),
   "a line ending after the patient's observation stops the build")
ll_stub(dup = 1)
ok(inherits(tryCatch(le$check_lot_long(NULL, cfg_ll), error = function(e) e), "error"),
   "a duplicate (PATID, LOT_NUM) still stops the build")
ll_stub(gaps = 4)
ok(inherits(tryCatch(le$check_lot_long(NULL, cfg_ll), error = function(e) e), "error"),
   "lines that do not run 1..n still stop the build")
ll_stub(shape = list(n_end_before_start = 1))
ok(inherits(tryCatch(le$check_lot_long(NULL, cfg_ll), error = function(e) e), "error"),
   "a line ending before it starts still stops the build")
# Every other check here compares dates, and a comparison with NULL is unknown
# rather than true - so a line with no start or no end passed all of them.
ll_stub(shape = list(n_null_start = 2))
ok(inherits(tryCatch(le$check_lot_long(NULL, cfg_ll), error = function(e) e), "error"),
   "a line with no start date stops the build")
ll_stub(shape = list(n_null_end = 3))
ok(inherits(tryCatch(le$check_lot_long(NULL, cfg_ll), error = function(e) e), "error"),
   "a line with no end date stops the build")
ll_stub(shape = list(n_null_start = 1))
ok(grepl("no start date", tryCatch({ le$check_lot_long(NULL, cfg_ll); "" },
                                   error = conditionMessage), fixed = TRUE),
   "and says so, rather than reporting a downstream symptom")

cat("\n-- an empty table says it is empty, not 'missing value' --\n")
# sum() over no rows is SQL NULL, so every count above arrives as NA and the
# comparisons become "missing value where TRUE/FALSE needed". The queries
# coalesce, and the empty case stops before any of them is read - a stub
# feeding zeros would prove neither.
for (f in c("check_lot_long", "check_cohort_input")) {
  src <- paste(readLines(file.path(ROOT, "R", "build_lot.R"), warn = FALSE),
               collapse = "\n")
  body <- sub(paste0(".*", f, " <- function"), "", src)
  body <- sub("\n[a-zA-Z_]+ <- function.*", "", body)
  sums <- gregexpr("sum(CASE WHEN", body, fixed = TRUE)[[1]]
  cosums <- gregexpr("coalesce(sum(CASE WHEN", body, fixed = TRUE)[[1]]
  ok(length(sums[sums > 0]) == length(cosums[cosums > 0]) && length(cosums[cosums > 0]) > 0,
     paste0(f, ": every aggregate is coalesced (", length(cosums[cosums > 0]), ")"))
}
# And it stops on empty before reading them, so a lost coalesce still cannot
# turn this into an R error.
ll_stub(shape = list(n_rows = 0, n_null_start = NA_integer_,
                     n_null_end = NA_integer_, n_end_before_start = NA_integer_,
                     n_bad_lot_num = NA_integer_))
msg <- tryCatch({ le$check_lot_long(NULL, cfg_ll); "" }, error = conditionMessage)
ok(grepl("it is empty", msg, fixed = TRUE),
   "an empty LOT_LONG reports being empty")
ok(!grepl("missing value", msg, fixed = TRUE),
   "...even when the counts come back NA, as they would without the coalesce")

cat("\n-- the checks group by the key extraction actually joins on --\n")
# The NDC join pads to eleven digits, so '123456789' and '0123456789' are one
# key there. Grouping by the stored code would call them two, and a code
# naming two medications would go unreported.
cd2 <- paste(readLines(file.path(ROOT, "R", "steps", "01_codelists.R"), warn = FALSE),
             collapse = "\n")
ok(grepl("lpad(regexp_replace(CL_CODE, '[^0-9]', ''), 11, '0')", cd2, fixed = TRUE) &&
     grepl("GROUP BY CL_CODE_TYPE, join_key", cd2, fixed = TRUE),
   "code_to_med groups NDC rows by the padded key, not the stored code")
mm2 <- paste(readLines(file.path(ROOT, "R", "steps", "03_mma_map.R"), warn = FALSE),
             collapse = "\n")
ok(grepl("lpad(regexp_replace(c.CL_CODE, '[^0-9]', ''), 11, '0')", mm2, fixed = TRUE),
   "and that is the same expression the NDC join uses")
sc2 <- paste(readLines(file.path(ROOT, "R", "steps", "05_sct.R"), warn = FALSE),
             collapse = "\n")
ok(grepl("WHERE CL_CODE_TYPE IN ('ICD10PROC', 'ICD9PROC', 'HCPCS')", sc2, fixed = TRUE),
   "SCT also checks across the types that share a claim column")
# S11 maps the spellings it knows and passes anything else through. Only AUTO,
# ALLO and CART are ever selected from - UNKNOWN is a bucket nothing reads - so
# an unmapped spelling is not an error anywhere, it just never matches.
ok(grepl("ELSE upper(trim(SCT_TYPE))", sc2, fixed = TRUE),
   "the normalizer still passes an unrecognized spelling through unchanged")
se2 <- new.env(parent = globalenv())
for (nm in c("log_msg", "print")) assign(nm, function(...) invisible(NULL), envir = se2)
assign("run_step", function(...) invisible(TRUE), envir = se2)
assign("glue", function(..., .envir = parent.frame()) paste0(..., collapse = ""),
       envir = se2)
sys.source(file.path(ROOT, "R", "steps", "05_sct.R"), envir = se2)
sct_db_q <- function(bad, bad_type = NULL, bad_ver = NULL) function(con, sql) {
  if (grepl("NOT IN ('AUTO', 'ALLO', 'CART', 'UNKNOWN')", sql, fixed = TRUE))
    return(if (is.null(bad)) data.frame(SCT_TYPE = character(0), n_codes = integer(0))
           else data.frame(SCT_TYPE = bad, n_codes = 4L))
  if (grepl("CL_CODE_TYPE IS NULL", sql, fixed = TRUE))
    return(if (is.null(bad_type))
             data.frame(CL_CODE_TYPE = character(0), n_codes = integer(0))
           else data.frame(CL_CODE_TYPE = bad_type, n_codes = 7L))
  if (grepl("NOT LIKE 'ICD%9%DIAG%'", sql, fixed = TRUE))
    return(if (is.null(bad_ver))
             data.frame(CL_CODE_TYPE = character(0), n_codes = integer(0))
           else data.frame(CL_CODE_TYPE = bad_ver, n_codes = 5L))
  data.frame()
}
run_sct <- function(bad, bad_type = NULL, bad_ver = NULL) {
  assign("db_q", sct_db_q(bad, bad_type, bad_ver), envir = se2)
  tryCatch({ se2$phase_sct(NULL, list(sct_src = "src")); NULL },
           error = function(e) conditionMessage(e))
}
ok(is.null(run_sct(NULL)), "only the types the build reads: the phase runs")
unmapped <- run_sct("PERIPHERAL BLOOD")
ok(!is.null(unmapped), "an unmapped SCT_TYPE stops the build")
ok(grepl("PERIPHERAL BLOOD", unmapped, fixed = TRUE),
   "and the message names the spelling to add or fix")
# Which types count is decided by the query, not by the stub above, so assert
# the predicate itself. UNKNOWN is deliberate - the CASE creates it and nothing
# reads it - so stopping on it would fail every run that has one.
ok(grepl("NOT IN ('AUTO', 'ALLO', 'CART', 'UNKNOWN')", sc2, fixed = TRUE),
   "UNKNOWN is accepted alongside the three that are read")
for (t in c("AUTO", "ALLO", "CART"))
  ok(grepl(paste0("SCT_TYPE = '", t, "'"), paste(sc2, sql_of_10 <- paste(
       readLines(file.path(ROOT, "R", "steps", "10_lot2_5_base.R"), warn = FALSE),
       collapse = "\n")), fixed = TRUE),
     paste0(t, " is a type something downstream actually selects"))

# The same hole on the other arm of the same CASE: the claim joins read five
# code types, and anything the CASE does not map passes through and matches
# none of them. A blank one gets through too - the WHERE guards CL_CODE and
# SCT_TYPE but not this, where S01 drops blank types from the MM list.
ok(grepl("ELSE upper(trim(CL_CODE_TYPE))", sc2, fixed = TRUE),
   "the normalizer still passes an unrecognized code type through unchanged")
ok(!is.null(run_sct(NULL, "HCPC")), "an unmapped SCT code type stops the build")
ok(grepl("HCPC", run_sct(NULL, "HCPC"), fixed = TRUE),
   "and the message names the spelling to add or fix")
ok(!is.null(run_sct(NULL, "<null>")), "a blank or null code type stops it too")
# The accepted set is decided by the query, not by the stub above. Read both
# sides out of the SQL and require them to be the SAME set: a new extraction
# branch, or a type quietly dropped from the whitelist, fails here. Checking
# only that each read type appears somewhere in the file would not - the first
# version of this did exactly that and passed a type the whitelist rejects.
quoted <- function(x) sort(unique(gsub("'", "",
  regmatches(x, gregexpr("'[A-Z0-9]+'", x))[[1]])))
flat  <- gsub("\n", " ", sc2)
reads <- sort(unique(vapply(
  regmatches(flat, gregexpr("s\\.CL_CODE_TYPE = '[A-Z0-9]+'", flat))[[1]],
  function(m) sub("^.*'([A-Z0-9]+)'$", "\\1", m), character(1), USE.NAMES = FALSE)))
accepted <- quoted(regmatches(flat,
  regexpr("CL_CODE_TYPE NOT IN \\([^)]*\\)", flat)))
ok(setequal(accepted, reads) && length(reads) == 5,
   paste0("the accepted code types are exactly the ", length(reads),
          " an extraction branch reads: ", paste(reads, collapse = ", ")))

# Accepted is not right. The '%PROC%' arm sits after the exact ICD9PROC test,
# so ICD9PROCEDURE and ICD-9-PROC become ICD10PROC - which the check above
# accepts, because ICD10PROC is a real type. The claim join then reads ICD-10
# columns for an ICD-9 code.
ok(grepl("WHEN upper(trim(CL_CODE_TYPE)) LIKE '%PROC%'", sc2, fixed = TRUE),
   "the '%PROC%' arm is still there, after the exact ICD9PROC test")
badver <- run_sct(NULL, NULL, "ICD-9-PROC")
ok(!is.null(badver), "an ICD-9 spelling that maps to ICD-10 stops the build")
ok(grepl("ICD-9-PROC", badver, fixed = TRUE) && grepl("read as ICD-10", badver, fixed = TRUE),
   "and says which spelling and what would happen to it")
# The exact spellings the CASE does turn into an ICD-9 type. Asked of the raw
# value rather than by repeating the CASE, so this list is the contract.
for (sp in c("'ICD9PROC', 'ICD9DIAG', 'ICD9DX', 'ICD9', 'DIAG9'",
             "NOT LIKE 'ICD%9%DIAG%'"))
  ok(grepl(sp, sc2, fixed = TRUE),
     paste0("the ICD-9 spellings it accepts are named: ", sp))
ok(grepl("AS n_defs", cd2, fixed = TRUE),
   "one rollup medication, one definition - DISTINCT only removes identical rows")
ok(grepl("AS n_rollup", cd2, fixed = TRUE),
   "and no blank medication or class, which would make the rest meaningless")

cat("\n-- the SQL is structurally sane --\n")
# The equivalence test proves no source line was removed. It says nothing
# about whether what was ADDED is valid SQL - two real runtime failures got
# through it, so check the shapes that Spark rejects outright.
sql_files <- c(list.files(file.path(ROOT, "R", "steps"), "\\.R$", full.names = TRUE),
               file.path(ROOT, "R", "build_lot.R"))

# Spark refuses a persistent view over a temporary one
# (INVALID_TEMP_OBJ_REFERENCE), and every LOT output is built from temp views.
bad_view <- unlist(lapply(sql_files, function(f) {
  l <- readLines(f, warn = FALSE)
  l <- l[!grepl("^\\s*(#|--)", l)]
  grep("CREATE (OR REPLACE )?VIEW\\s*\\{?lot_out", l, value = TRUE)
}))
ok(length(bad_view) == 0,
   if (length(bad_view)) paste0("persistent view over a temp view: ", trimws(bad_view[1]))
   else "no persistent output is created as a VIEW")

# Two WHERE clauses for one SELECT is a parse error. It happened by inserting
# a filter after FROM in a query that already had a WHERE further down.
# Deliberately blunt: it does not track subqueries, so an inner WHERE followed
# by an outer one reads as the bug. Write the filter as one clause rather than
# teaching this to parse SQL - the value here is that it cannot be argued with.
double_where <- character(0)
for (f in sql_files) {
  l <- readLines(f, warn = FALSE)
  l <- l[!grepl("^\\s*(#|--)", l) & nzchar(trimws(l))]
  seen <- FALSE
  for (i in seq_along(l)) {
    t <- trimws(l[i])
    if (grepl("SELECT", t)) seen <- FALSE
    if (grepl("^WHERE\\b", t)) {
      if (seen) double_where <- c(double_where, paste0(basename(f), ": ", t))
      seen <- TRUE
    }
  }
}
ok(length(double_where) == 0,
   if (length(double_where)) paste0("two WHERE for one SELECT -- ", double_where[1])
   else "no SELECT carries two WHERE clauses")

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
Sys.setenv(CODELIST_WAIVERS = "no_such_check")
stops(check_settings(), "a waiver naming a check that does not exist")
clear()
Sys.setenv(CODELIST_WAIVERS = "uncoded_meds,ndc_short")
runs(check_settings(), "two reviewable check names are accepted")
clear()
Sys.setenv(CODELIST_WAIVERS = "uncoded_meds,bad_ndc")
stops(check_settings(), "one reviewable name plus one that cannot be waived")
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

cat("\n-- the README still describes this build --\n")
# Prose cannot be checked, but these two lists can, and both had gone stale.
# Membership only - a step file reordered in the layout still passes, so the
# order there is maintained by hand.
readme <- readLines(file.path(ROOT, "README.md"), warn = FALSE)
documented <- unique(unlist(regmatches(readme, gregexpr("`[a-z_0-9]+`", readme))))
documented <- gsub("`", "", documented)
missing_w <- setdiff(ALL_CHECKS, documented)
ok(length(missing_w) == 0,
   if (length(missing_w)) paste0("waiver not in the README: ",
                                 paste(missing_w, collapse = ", "))
   else "every waivable check is named in the README")
steps_on_disk <- basename(list.files(file.path(ROOT, "R", "steps"), "\\.R$"))
missing_s <- steps_on_disk[!vapply(steps_on_disk, function(f)
  any(grepl(f, readme, fixed = TRUE)), logical(1))]
ok(length(missing_s) == 0,
   if (length(missing_s)) paste0("step file not in the README layout: ",
                                 paste(missing_s, collapse = ", "))
   else paste0("all ", length(steps_on_disk), " step files appear in the README"))

report()
