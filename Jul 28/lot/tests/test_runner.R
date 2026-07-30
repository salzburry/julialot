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
           "phase_codelists", "phase_patient_input", "phase_mma_map",
           "phase_lot1_base", "phase_sct", "phase_lot1_sct",
           "phase_lot1_end", "phase_qc",
           "check_lot1_invariants", "phase_persist", "materialize_sct_views",
           "build_lot2_5",
           "check_lot_long", "phase_line_criteria", "check_run_recorded")
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
ok(grepl("CODELIST_WAIVERS STRING", bl, fixed = TRUE),
   "and the status row records which checks were waived")
# 08_persist writes metadata inside a tryCatch, so confirm the row arrived.
ok(grepl("check_run_recorded", bl, fixed = TRUE),
   "a run with no metadata row is not called complete")

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
            "code_to_med", "bad_ndc"))
  ok(grepl(paste0(w, " <-"), cd, fixed = TRUE), paste0(w, " is checked"))
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
  if (grepl("AS bigint\\) = 0", sql))
    return(if (problem == "bad_ndc") data.frame(CL_CODE = "00000000000", CL_MED_ABBR = "X")
           else data.frame(CL_CODE = character(0), CL_MED_ABBR = character(0)))
  if (grepl("count\\(DISTINCT CL_MED_ABBR\\) AS n FROM mma_rollup", sql)) return(data.frame(n = 28))
  if (grepl("count\\(\\*\\) AS n FROM mma_codelist", sql)) return(data.frame(n = 500))
  if (grepl("SELECT DISTINCT CL_MED_ABBR FROM mma_rollup", sql, fixed = TRUE))
    return(data.frame(CL_MED_ABBR = c("LEN", "BOR")))
  if (grepl("SELECT DISTINCT CL_MED_CLASS FROM mma_rollup", sql, fixed = TRUE))
    return(data.frame(CL_MED_CLASS = c("IMID", "PI")))
  data.frame()
}
ce <- new.env(parent = globalenv())
for (nm in c("log_msg", "print")) assign(nm, function(...) invisible(NULL), envir = ce)
assign("run_step", function(...) invisible(TRUE), envir = ce)
assign("glue", function(..., .envir = parent.frame()) paste0(..., collapse = ""), envir = ce)
assign("load_codelist_csv", function(...) "(SELECT 1) src", envir = ce)
# codelist_waivers() lives in build_lot.R, which this env does not source.
assign("codelist_waivers", function()
  { v <- trimws(strsplit(Sys.getenv("CODELIST_WAIVERS", unset = ""), "[,|]")[[1]]); v[nzchar(v)] },
  envir = ce)
sys.source(file.path(ROOT, "R", "steps", "01_codelists.R"), envir = ce)
Sys.unsetenv("CODELIST_WAIVERS")
assign("db_q", mk_db_q("none"), envir = ce)
ok(!inherits(tryCatch(ce$phase_codelists(NULL), error = function(e) e), "error"),
   "a consistent pair of code lists runs")
for (prob in c("orphan", "uncoded", "type", "class", "code_to_med", "bad_ndc",
               "rollup_defs", "blank_keys")) {
  assign("db_q", mk_db_q(prob), envir = ce)
  ok(inherits(tryCatch(ce$phase_codelists(NULL), error = function(e) e), "error"),
     paste0("'", prob, "' stops the build"))
}
# A waiver names one check. The study team keeps steroids in a separate file,
# so the rollup has meds with no codes - an expected condition. Waiving that
# must NOT also waive a code naming two different drugs.
Sys.setenv(CODELIST_WAIVERS = "uncoded_meds")
assign("db_q", mk_db_q("uncoded"), envir = ce)
ok(!inherits(tryCatch(ce$phase_codelists(NULL), error = function(e) e), "error"),
   "waiving uncoded_meds lets the expected steroid case through")
assign("db_q", mk_db_q("code_to_med"), envir = ce)
ok(inherits(tryCatch(ce$phase_codelists(NULL), error = function(e) e), "error"),
   "and still stops on a code naming two medications")
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
assign("db_q", function(con, sql) {
  asked <<- c(asked, sql)
  data.frame(viewName = get("LOT2_5_INPUT_VIEWS", envir = pe),
             stringsAsFactors = FALSE)
}, envir = pe)
ok(isTRUE(pe$lot_inputs_present(NULL)), "all ten present is detected")
ok(length(asked) == 1 && grepl("SHOW VIEWS", asked[1], fixed = TRUE),
   "with one catalogue query, not ten reads")
assign("db_q", function(con, sql)
  data.frame(viewName = c("lot_patient_input", "mma_rollup"),
             stringsAsFactors = FALSE), envir = pe)
ok(!isTRUE(pe$lot_inputs_present(NULL)), "a missing view is detected")
assign("db_q", function(con, sql) stop("no such command"), envir = pe)
ok(!isTRUE(pe$lot_inputs_present(NULL)),
   "and if the catalogue cannot answer, it rebuilds rather than assumes")

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
LL_OK <- list(n_rows = 100, n_patients = 40, n_end_before_start = 0, n_bad_lot_num = 0)
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
Sys.setenv(CODELIST_WAIVERS = "uncoded_meds,bad_ndc")
runs(check_settings(), "two real check names are accepted")
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
# Prose cannot be checked, but these two lists can, and both had already gone
# stale: the README named six waivers where the code has eight, and its layout
# had the step files in an order the build does not run them in.
readme <- readLines(file.path(ROOT, "README.md"), warn = FALSE)
bl <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "build_lot.R"), envir = bl)
documented <- unique(unlist(regmatches(readme, gregexpr("`[a-z_0-9]+`", readme))))
documented <- gsub("`", "", documented)
missing_w <- setdiff(get("WAIVABLE_CHECKS", envir = bl), documented)
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
