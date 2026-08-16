#!/usr/bin/env Rscript
# Checks on the LOT runner: the cohort switch, the contract, and the setting
# validators. No warehouse needed.
#
#   Rscript "lot/engine/tests/test_runner.R"

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
              "ALLO_LOT_SPAN", "MAX_LOT", "CODELIST_WAIVERS",
              "FACE_VALIDITY_FATAL",
              # Not a setting - the one way past the contract check. Cleared
              # with the rest, or a stray value in the environment turns the
              # loop below into thirteen assertions that pass for the wrong
              # reason.
              "LOT_CONTRACT_OVERRIDE")
clear <- function() for (v in SETTINGS) Sys.unsetenv(v)

# Stand-in names. The package knows no real cohort, so the tests must not
# smuggle one in either.
TBL_A <- "COH_A_FINAL"; PFX_A <- "coh_a_"
PFX_B <- "coh_b_"

cat("\n-- the caller supplies the cohort, the package holds none --\n")
clear()
# The study window is not in CONTRACT - it is a per-run argument - so the base
# config a contract check runs against has to carry one.
WIN <- list(study_start = "2016-01-01", study_end = "2026-03-31")
base <- modifyList(modifyList(list(persist_to_schema = TRUE), CONTRACT), WIN)
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

cat("\n-- and the study window is the caller's too --\n")
# Not in CONTRACT: the algorithm is one thing, the window it is run over is the
# cohort's. Pinning it meant editing this folder to run the same rules against a
# study with different dates.
ok(!any(c("study_start", "study_end") %in% names(CONTRACT)),
   "the window is not pinned by CONTRACT")
w <- pin_study_window(base, "2016-01-01", "2026-03-31")
ok(identical(w$study_start, "2016-01-01") && identical(w$study_end, "2026-03-31"),
   "a window passed as an argument is taken as given")
# The common case passes two arguments, not four, and gets config.csv's window.
w2 <- pin_study_window(modifyList(base, list(study_start = "2016-01-01",
                                             study_end = "2025-06-30")), NULL, NULL)
ok(identical(w2$study_end, "2025-06-30"),
   "and no argument falls back to the configured one, rather than blank")
w3 <- pin_study_window(modifyList(base, list(study_end = "2025-06-30")),
                       NULL, "2026-03-31")
ok(identical(w3$study_end, "2026-03-31"),
   "an argument beats the configured value, so a run need not edit config.csv")
# check_settings() only sees the environment, so an argument has to be checked
# here or a command-line date reaches get_quarter_suffix() unvalidated.
stops(pin_study_window(base, "2016-01-01", "30-06-2025"),
      "an Excel-reformatted date passed as an argument")
stops(pin_study_window(base, "2016-01-01", "2026-13-31"),
      "a date that is ISO-shaped but not a date")
# as.Date() errors rather than returning NA on a string it cannot parse, so
# without a tryCatch this stopped with R's message instead of one naming the
# setting - which is the difference between a fixable error and a puzzle.
ok(grepl("study_end='2026-13-31'",
         tryCatch(pin_study_window(base, "2016-01-01", "2026-13-31"),
                  error = conditionMessage), fixed = TRUE),
   "...and the message names the setting and the value, not R's date parser")
stops(pin_study_window(base, "2026-03-31", "2016-01-01"),
      "a window that runs backwards")
stops(pin_study_window(modifyList(base, list(study_start = "", study_end = "")),
                       NULL, NULL),
      "no window at all, from either source")
stops(check_lot_contract(modifyList(cfg, list(study_end = ""))),
      "and the contract refuses an empty window even though it does not pin one")

cat("\n-- and the run records which window built it --\n")
# FINAL_METADATA_COLS drives the ALTER that adds these columns; the UPDATE sets
# them. Two lists of the same names, and nothing held them together: a column
# added to one and not the other is either a column that is created and stays
# NULL forever, or an UPDATE naming a column the table does not have. Read out
# of the file rather than restated, so this cannot drift either.
rfc <- local({
  b <- paste(readLines(file.path(ROOT, "R", "build_lot.R"), warn = FALSE),
             collapse = "\n")
  # Lazy, and anchored on both ends of the one statement: WHERE RUN_ID appears
  # in several other queries in this file, so a greedy cut lands in the wrong
  # one and the comparison then reads every column name in the file.
  m <- regmatches(b, regexpr("(?s)UPDATE \\{tbl\\}\\s*SET .*?WHERE RUN_ID", b,
                             perl = TRUE))
  if (!length(m)) "" else m
})
set_cols <- unique(regmatches(rfc, gregexpr("[A-Z][A-Z0-9_]+(?= =)", rfc,
                                            perl = TRUE))[[1]])
ok(setequal(set_cols, names(FINAL_METADATA_COLS)),
   paste0("the UPDATE sets exactly the columns FINAL_METADATA_COLS adds (",
          length(set_cols), " vs ", length(FINAL_METADATA_COLS), ")",
          if (!setequal(set_cols, names(FINAL_METADATA_COLS)))
            paste0(" -- only in one: ",
                   paste(union(setdiff(set_cols, names(FINAL_METADATA_COLS)),
                               setdiff(names(FINAL_METADATA_COLS), set_cols)),
                         collapse = ", ")) else ""))
ok(all(c("STUDY_START", "STUDY_END") %in% names(FINAL_METADATA_COLS)),
   paste0("and the window is among them - it is not in CONTRACT, so ",
          "CONTRACT_SETTINGS does not carry it"))

cat("\n-- two cohorts cannot collide --\n")
# The point of the module: same rules, different output names.
stops(check_lot_contract(modifyList(cfg, list(object_prefix = ""))),
      "a blank prefix is rejected, so outputs cannot collide")
stops(check_lot_contract(modifyList(cfg, list(input_cohort_table = ""))),
      "a blank cohort table is rejected")

cat("\n-- lot_out() prefixes LOT's outputs, wrk() leaves the cohort alone --\n")
# The cohort table is named by the cohort build; prefixing it here would look
# for coh_a_COH_A_FINAL.
cfg <- pin_cohort(modifyList(base, list(work_schema = "usr00000")), TBL_A, PFX_A)
assign("cfg", cfg, envir = globalenv())
sys.source(file.path(ROOT, "R", "db_utils_lot.R"), envir = globalenv())
ok(identical(lot_out("LOT1_BASE"), paste0("hive_metastore.usr00000.", PFX_A, "LOT1_BASE")),
   "lot_out() carries the prefix")
ok(identical(wrk(cfg$input_cohort_table), paste0("hive_metastore.usr00000.", TBL_A)),
   "wrk() reads the cohort table as the cohort named it")

# Read the real output names out of the steps rather than listing them
# by hand - a hand list goes stale the moment a step adds a table, which is
# exactly when a collision would slip through.
# build_lot.R too: the SCT materialization names live there rather than in the
# fresh-session path.
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

cat("\n-- what a run writes is declared, both directions --\n")
# LOT_TABLES is the declaration and this scan is the code; held together so a
# table added to a step without being declared - or declared and then removed
# from a step - fails here rather than surfacing as a surprise in a schema.
# LOT_LONG_STAGE is allowed on the written side without being declared:
# build_lot2_5 drops it after the publish, so a finished run does not have it.
lotn_env <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "cart_rule.R"), envir = lotn_env)
sys.source(file.path(ROOT, "R", "prior_regimen.R"), envir = lotn_env)
sys.source(file.path(ROOT, "R", "steps", "10_lot2_5_base.R"), envir = lotn_env)
undeclared <- setdiff(OUTPUTS, c(get("LOT_TABLES", envir = env), lotn_env$.LOT_LONG_STAGE))
ok(length(undeclared) == 0,
   if (length(undeclared)) paste0("steps write tables the declaration misses: ",
                                  paste(undeclared, collapse = ", "))
   else "every fixed name a step writes is declared in LOT_TABLES")
unwritten <- setdiff(get("LOT_TABLES", envir = env), OUTPUTS)
ok(length(unwritten) == 0,
   if (length(unwritten)) paste0("declared but nothing writes it: ",
                                 paste(unwritten, collapse = ", "))
   else "and nothing is declared that no step writes")
# The per-line stage tables have dynamic names the scan above cannot see.
# Their declaration is .LOTN_STAGES; hold it to the lotn_table() calls the
# loop actually makes, both directions again.
l25_txt <- paste(readLines(file.path(ROOT, "R", "steps", "10_lot2_5_base.R"),
                           warn = FALSE), collapse = "\n")
staged <- unique(unlist(regmatches(l25_txt,
  gregexpr('(?<=lotn_table\\(lot_num, ")[A-Z_0-9]+(?=")', l25_txt, perl = TRUE))))
ok(setequal(staged, lotn_env$.LOTN_STAGES),
   paste0("the seven per-line stages the loop writes are the seven declared (",
          paste(sort(staged), collapse = ", "), ")"))
# And lot_run_outputs() renders both parts: the fixed names always, the
# per-line names for the lines the loop reports having built. Rebound into
# the env holding .LOTN_STAGES and lotn_table, with the declaration beside
# them - which is also what the run itself requires: the loader sources the
# step files before build_lot() runs.
lro <- get("lot_run_outputs", envir = env)
assign("LOT_TABLES", get("LOT_TABLES", envir = env), envir = lotn_env)
environment(lro) <- lotn_env
ok(setequal(lro(integer(0)), get("LOT_TABLES", envir = env)),
   "with no lines built, the outputs are the fixed names alone")
with_lines <- lro(c(2L, 3L))
ok(all(c("LOT2_BASE", "LOT3_START_CANDIDATES", "LOT3_BASE_END") %in% with_lines) &&
     !any(grepl("^LOT[45]_", setdiff(with_lines, get("LOT_TABLES", envir = env)))),
   "with LOT2-3 built, their stage tables are declared and LOT4-5's are not")

cat("\n-- the cohort table is checked before any work --\n")
# A missing column would otherwise surface deep into the build.
fake_con <- structure(list(), class = "fakecon")
GOOD <- list(n_rows = 10, n_patients = 10, n_null_patid = 0, n_null_index = 0,
             n_null_end = 0, n_end_before_index = 0)
# DESCRIBE answers with columns; the shape query answers with counts.
CSQL <- character(0)
stub <- function(cols = REQUIRED_COHORT_COLS, shape = list()) {
  sh <- modifyList(GOOD, shape)
  CSQL <<- character(0)
  assign("db_q", function(con, sql) {
    CSQL <<- c(CSQL, sql)
    if (grepl("DESCRIBE", sql)) data.frame(col_name = cols, stringsAsFactors = FALSE)
    else as.data.frame(sh)
  }, envir = globalenv())
}
assign("log_msg", function(...) invisible(NULL), envir = globalenv())

stub()
runs(check_cohort_input(fake_con, "wk.COH"), "a sound cohort table is accepted")
stub(cols = tolower(REQUIRED_COHORT_COLS))
runs(check_cohort_input(fake_con, "wk.COH"), "column case does not matter")
stub(cols = setdiff(REQUIRED_COHORT_COLS, "ENDDATE_CE"))
stops(check_cohort_input(fake_con, "wk.COH"), "a missing column is named, not ignored")

cat("\n-- and for shape, not just column names --\n")
# The rules read this table row for row: no DISTINCT, no ranking. A repeated
# patient would multiply their claims and their lines.
stub(shape = list(n_rows = 12, n_patients = 10))
stops(check_cohort_input(fake_con, "wk.COH"), "more rows than patients is rejected")
stub(shape = list(n_rows = 0, n_patients = 0))
stops(check_cohort_input(fake_con, "wk.COH"), "an empty table cannot drive LOT")
stub(shape = list(n_null_patid = 1))
stops(check_cohort_input(fake_con, "wk.COH"), "a null PATID is rejected")
stub(shape = list(n_null_index = 3))
stops(check_cohort_input(fake_con, "wk.COH"), "a null INDEX_DATE is rejected")
stub(shape = list(n_null_end = 2))
stops(check_cohort_input(fake_con, "wk.COH"), "a null ENDDATE is rejected")
stub(shape = list(n_end_before_index = 1))
stops(check_cohort_input(fake_con, "wk.COH"), "an ENDDATE before INDEX_DATE is rejected")

# The table is an argument, so it has to reach the SQL. Passing cfg and letting
# the stub ignore it would pass just as well against a function that re-checked
# the source table and called the pinned copy sound.
stub()
got <- check_cohort_input(fake_con, "wk.SNAP")
ok(length(CSQL) == 2 && all(grepl("wk.SNAP", CSQL, fixed = TRUE)),
   "it asks about the table it was given, in both queries")
ok(identical(got, list(n_rows = 10, n_patients = 10)),
   "and hands back the counts materialize_cohort_input compares")
rm("db_q", "log_msg", envir = globalenv())

cat("\n-- and the cohort has to fit the window this run reads --\n")
# LOT bounds every claim scan by the cohort's own dates, so a cohort built to a
# wider window than the CDM vintage produces early line ends and invented
# discontinuations with nothing in the output to say so. The NDMM cohort ends
# 2026-03-31 and this build defaults to 2025-06-30, so it is the live case.
WSQL <- character(0)
wstub <- function(...) {
  w <- modifyList(list(min_index = "2017-02-01", max_index = "2024-11-30",
                       max_end = "2025-06-30", n_past_end = 0, n_before_start = 0),
                  list(...))
  WSQL <<- character(0)
  assign("db_q", function(con, sql) { WSQL <<- c(WSQL, sql); as.data.frame(w) },
         envir = globalenv())
}
assign("log_msg", function(...) invisible(NULL), envir = globalenv())
wcfg <- modifyList(cfg, list(study_start = "2016-01-01", study_end = "2025-06-30",
                             use_quarterly_tables = TRUE))

wstub()
runs(check_cohort_window(fake_con, "wk.COH", wcfg),
     "a cohort inside the window is accepted")
ok(grepl("date('2025-06-30')", WSQL[1], fixed = TRUE) &&
     grepl("date('2016-01-01')", WSQL[1], fixed = TRUE),
   "both ends of the configured window reach the query")

wstub(n_past_end = 412, max_end = "2026-03-31")
stops(check_cohort_window(fake_con, "wk.COH", wcfg),
      "a cohort observed past STUDY_END is refused, not silently truncated")
msg <- tryCatch(check_cohort_window(fake_con, "wk.COH", wcfg),
                error = conditionMessage)
ok(grepl("412", msg, fixed = TRUE) && grepl("2026-03-31", msg, fixed = TRUE) &&
     grepl("2025q2", msg, fixed = TRUE),
   "and the message names the count, the date and the vintage it would read")

wstub(n_before_start = 7, min_index = "2015-08-14")
stops(check_cohort_window(fake_con, "wk.COH", wcfg),
      "so is one indexed before STUDY_START")

# Without quarterly tables there is no vintage to name, but the window still
# bounds what the cohort may claim.
wstub(n_past_end = 1)
stops(check_cohort_window(fake_con, "wk.COH",
                          modifyList(wcfg, list(use_quarterly_tables = FALSE))),
      "the check does not depend on quarterly tables being on")
rm("db_q", "log_msg", envir = globalenv())

cat("\n-- build_lot() actually runs the phases, in order --\n")
# Every step file passing its own test proved nothing about whether build_lot()
# calls it. The line-criteria layer shipped complete, tested, and never invoked.
bl <- paste(readLines(file.path(ROOT, "R", "build_lot.R"), warn = FALSE),
            collapse = "\n")
body <- sub(".*build_lot <- function\\([^)]*\\) \\{", "", bl)
ORDER <- c("check_settings", "pin_output_schema", "pin_cohort",
           "pin_study_window", "check_lot_contract", "set_lot_config",
           "check_cohort_input", "check_cohort_window",
           "check_no_active_run", "clear_run_rows",
           "phase_codelists", "record_codelist_hashes",
           "phase_patient_input", "materialize_cohort_input",
           "check_claim_ndc",
           "phase_mma_map",
           # phase_sct ahead of phase_lot1_base, so a line's regimen can be
           # bounded by the transplant that ended the line. Not cosmetic: the
           # order IS the fix, and swapping it back silently restores a regimen
           # that collects agents after its own line is over.
           "phase_sct", "phase_lot1_base", "phase_lot1_sct",
           "phase_lot1_end", "phase_qc",
           "check_lot1_invariants", "phase_persist", "materialize_sct_views",
           "build_lot2_5",
           "check_lot_long", "phase_line_criteria", "check_lot_final",
           "phase_lot_attrition",
           "record_final_counts", "check_run_recorded")
at <- vapply(ORDER, function(f) {
  m <- regexpr(paste0("(?<![A-Za-z0-9_.])", f, "\\("), body, perl = TRUE)
  if (m == -1) NA_integer_ else as.integer(m)
}, integer(1))
# One assertion naming whatever is missing, rather than one per entry: the
# diagnostic is the same and the output is not twenty-two lines of "calls X()".
absent <- names(at)[is.na(at)]
ok(length(absent) == 0,
   if (length(absent)) paste0("build_lot() never calls: ", paste(absent, collapse = ", "))
   else paste0("build_lot() calls all ", length(ORDER), " phases and checks"))
ok(!any(is.na(at)) && !is.unsorted(at[!is.na(at)]),
   "and calls them in that order")

cat("\n-- the criteria layer reaches the warehouse --\n")
# lot/FILES.md promises these two tables. Nothing was producing them. Driven
# below rather than grepped for: the statements themselves are asserted.

# Those read the source, so the function could be a no-op and still pass them -
# it was, and it did. Driven from here, with the real SQL builders, so what
# reaches the warehouse is the wiring rather than a description of it.
pe <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "line_criteria.R"), envir = pe)
sys.source(file.path(ROOT, "R", "build_lot.R"), envir = pe)
assign("log_msg", function(...) invisible(NULL), envir = pe)
assign("lot_out", function(x) paste0("wk.p_", x), envir = pe)
PSQL <- character(0)
assign("run_step", function(con, name, sql, qc = NULL) {
  PSQL <<- c(PSQL, sql); invisible(TRUE) }, envir = pe)
# The real materialize(), rebound so its statements land in PSQL through the
# stubs above - the chain below asserts what actually reaches the warehouse.
pmat <- get("materialize", envir = globalenv())
environment(pmat) <- pe
assign("materialize", pmat, envir = pe)
LL_COLS <- c("PATID", "LOT_NUM", "LOT_START_DT", "LOT_BASE_END_DT",
             "LOT_START_TYPE", "END_REASON")
drive_plc <- function(crit = list(), cfg = list(max_lot = 5L), cols = LL_COLS) {
  PSQL <<- character(0)
  assign("LINE_CRITERIA", crit, envir = pe)
  assign("db_q", function(con, sql) data.frame(col_name = cols), envir = pe)
  tryCatch({ pe$phase_line_criteria(NULL, cfg); NULL }, error = conditionMessage)
}
has_sql <- function(x) any(grepl(x, PSQL, fixed = TRUE))
# Whole statement, not substring: "FROM lot_long" is a prefix of "FROM
# lot_long_final", so a substring match accepts a stage wired to the wrong
# source. It did, until this was exact.
is_sql <- function(x) any(trimws(PSQL) == x)
src_of <- function(v) any(grepl(paste0("FROM ", v, "$"), trimws(PSQL)))
ok(is.null(drive_plc()) && length(PSQL) == 6L,
   paste0("six statements: two views, two tables, two repoints (", length(PSQL), ")"))
# The chain: each stage reads the one before it. A stage pointed at the wrong
# source would still build something, and it would be wrong quietly.
ok(is_sql("CREATE OR REPLACE TEMPORARY VIEW lot_long_allflags AS SELECT * FROM lot_long"),
   "allflags is built from lot_long")
ok(is_sql("CREATE OR REPLACE TEMPORARY VIEW lot_long_final AS SELECT * FROM lot_long_allflags"),
   "final is built from allflags, not from lot_long again")
ok(is_sql("CREATE OR REPLACE TABLE wk.p_LOT_LONG_ALLFLAGS AS\nSELECT * FROM lot_long_allflags") &&
     is_sql("CREATE OR REPLACE TABLE wk.p_LOT_LONG_FINAL AS\nSELECT * FROM lot_long_final"),
   "and each table is written from its own view, both prefixed")
# ...and each view is then repointed at its table, so every later read - the
# reporter, the attrition, the progression rows - scans the table rather than
# re-running the criteria SQL.
ok(is_sql("CREATE OR REPLACE TEMPORARY VIEW lot_long_allflags AS SELECT * FROM wk.p_LOT_LONG_ALLFLAGS") &&
     is_sql("CREATE OR REPLACE TEMPORARY VIEW lot_long_final AS SELECT * FROM wk.p_LOT_LONG_FINAL"),
   "each view is repointed at the table it was written to")
# TABLE, not VIEW: Spark refuses a persistent view over a temporary one.
ok(!any(grepl("CREATE OR REPLACE VIEW", PSQL, fixed = TRUE)),
   "persisted as tables - a persistent view over a temp view is refused")
i_v <- which(grepl("VIEW lot_long_final AS SELECT * FROM lot_long_allflags", PSQL, fixed = TRUE))[1]
i_t <- which(grepl("TABLE wk.p_LOT_LONG_FINAL", PSQL, fixed = TRUE))[1]
ok(!is.na(i_v) && !is.na(i_t) && i_v < i_t,
   "the view exists before the table that selects from it")
# Spark inlines a temporary view's plan when the view is created, so the final
# view has to be defined after allflags is repointed - defined before, it
# would carry the flags query for ever, and the repoint would change nothing
# it reads.
i_ar <- which(grepl("VIEW lot_long_allflags AS SELECT * FROM wk.p_LOT_LONG_ALLFLAGS",
                    PSQL, fixed = TRUE))[1]
ok(!is.na(i_ar) && !is.na(i_v) && i_ar < i_v,
   "and after allflags is repointed, so it reads the table, not the query")

# With a criterion declared, so the chain is carrying something. Empty is the
# shipped state and every stage is SELECT * there - a mis-wired source would
# look identical.
CRIT <- list(list(name = "t_crit", label = "t", lines = "*", flag = "T_FLAG",
                  sql = "LOT_START_TYPE = 'MED'", on_fail = "truncate"))
old_env <- Sys.getenv("APPLY_T_CRIT", unset = NA)
Sys.setenv(APPLY_T_CRIT = "TRUE")
ok(is.null(drive_plc(CRIT)) && has_sql("AS T_FLAG") && src_of("lot_long"),
   "a declared criterion becomes a flag column on the allflags view")
ok(has_sql("first_failed_lot") && has_sql("T_FLAG = 0"),
   "...and an enabled truncate reaches the final view as a removal")
ok(is_sql("CREATE OR REPLACE TABLE wk.p_LOT_LONG_FINAL AS\nSELECT * FROM lot_long_final"),
   "with the persisted table still written from it")

# A flag that names a column LOT_LONG already has does not fail - the view ends
# up carrying the name twice - so it is asked of the table before building.
CLASH <- list(modifyList(CRIT[[1]], list(flag = "LOT_NUM")))
msg <- drive_plc(CLASH)
ok(!is.null(msg) && grepl("already a LOT_LONG column", msg, fixed = TRUE) &&
     grepl("LOT_NUM", msg, fixed = TRUE),
   "a flag colliding with an existing LOT_LONG column stops the build, named")
ok(is.null(drive_plc(CRIT)),
   "...and a flag that does not collide is unaffected")
# A criterion aimed above MAX_LOT is asked of no line, so every row passes it -
# which reads as satisfied rather than as never run.
HIGH <- list(modifyList(CRIT[[1]], list(lines = 6L)))
msg <- drive_plc(HIGH, cfg = list(max_lot = 5L))
ok(!is.null(msg) && grepl("above MAX_LOT", msg, fixed = TRUE),
   "a criterion aimed above MAX_LOT stops the build rather than passing every row")
ok(is.null(drive_plc(list(modifyList(CRIT[[1]], list(lines = 5L))),
                     cfg = list(max_lot = 5L))),
   "...and one aimed at the highest line is fine")

cat("\n-- and the run records which criteria it applied, and what they cost --\n")
# Driven through phase_line_criteria, not called directly: a reporter nothing
# invokes records nothing, which is the state this replaced.
options(lot_line_criteria = NULL)
invisible(drive_plc(CRIT))
ok(identical(getOption("lot_line_criteria"), "t_crit=on:truncate:NA"),
   "phase_line_criteria reports the criteria itself, not on request")
# The only thing in this package that removes patients, and nothing recorded it.
# "No patient had belantamab", "the criterion was off" and "this is not that
# study's cohort" all produce the same LOT_LONG_FINAL, so a set of outputs could
# not say which of the three it was.
assign("db_q", function(con, sql)
  if (grepl("DESCRIBE", sql)) data.frame(col_name = LL_COLS)
  else data.frame(T_FLAG = 37L, n = 4L), envir = pe)
assign("LINE_CRITERIA", CRIT, envir = pe)
Sys.setenv(APPLY_T_CRIT = "TRUE")
got <- pe$report_line_criteria(NULL, list(max_lot = 5L))
ok(identical(got, "t_crit=on:truncate:37"),
   paste0("an applied criterion is recorded with its mode and its cost (", got, ")"))
Sys.setenv(APPLY_T_CRIT = "FALSE")
got <- pe$report_line_criteria(NULL, list(max_lot = 5L))
ok(identical(got, "t_crit=off:truncate:37"),
   paste0("a criterion left off is recorded too, with what it would have cost (",
          got, ")"))
Sys.setenv(APPLY_T_CRIT = "TRUE")
ok(identical(getOption("lot_line_criteria"), "t_crit=on:truncate:37") ||
     identical({pe$report_line_criteria(NULL, list(max_lot = 5L))
                getOption("lot_line_criteria")}, "t_crit=on:truncate:37"),
   "and it reaches the option record_final_counts writes from")
# A count that cannot be read is unknown, never a reason to fail a build that is
# otherwise sound. A bare d[[col]] on a frame without the column gives
# integer(0), and if (is.na(integer(0))) is an error rather than FALSE - which
# would have taken the whole run down over a diagnostic.
assign("db_q", function(con, sql) stop("no such table"), envir = pe)
got <- tryCatch(pe$report_line_criteria(NULL, list(max_lot = 5L)),
                error = function(e) paste("STOPPED:", conditionMessage(e)))
ok(identical(got, "t_crit=on:truncate:NA"),
   paste0("a count that cannot be read is reported unknown, not fatal (", got, ")"))
assign("db_q", function(con, sql) data.frame(something_else = 1L), envir = pe)
ok(identical(tryCatch(pe$report_line_criteria(NULL, list(max_lot = 5L)),
                      error = function(e) "STOPPED"), "t_crit=on:truncate:NA"),
   "...and so is an answer that does not carry the column")

if (is.na(old_env)) Sys.unsetenv("APPLY_T_CRIT") else Sys.setenv(APPLY_T_CRIT = old_env)

cat("\n-- a bad code list stops the build, it does not warn and continue --\n")
# A warning inside a tryCatch that also swallowed query errors would let a code
# list that changed who counts as treated through silently.
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
# Extraction only joins NDC and HCPCS. ICD is not among them: it would match
# nothing.
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
# codes is an expected condition a study may accept; waiving it must not also
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


cat("\n-- an SCT on LOT1's start date does not end it the day before --\n")
# LOT1's SCT windows take a transplant on the line's own start date, and the
# end rule is "the day before the transplant". Unfloored, that is the day
# before LOT1 began: check_lot_long refuses the row and the build stops.
#
# LOT2-5 cannot reach this - there an SCT on the start date is the start
# (LOT_START_TYPE 'CART'/'SCT_ALLO'), which is why its windows read '>'. LOT1's
# start type is hardcoded 'MED' in 10_lot2_5_base.R, so the transplant has
# nowhere else to go and narrowing the window would drop it from the line
# structure entirely - and out of cart_is_late, which exists to notice it.
#
# The expression is lifted out of the SQL the step actually emits and evaluated,
# not grepped for: a test that matched the text would pass on an expression
# that computes nothing.
sctenv <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "cart_rule.R"), envir = sctenv)
sys.source(file.path(ROOT, "R", "prior_regimen.R"), envir = sctenv)
# induction_window_days is read by LOT1_AUTO_HOLD_DT, which bounds the hold date
# to LOT1's own window. Absent, glue interpolates a NULL and the whole body comes
# back empty, so every extraction below misses rather than failing on its own
# terms.
assign("cfg", list(sct_tandem_days = 180L, induction_window_days = 60L),
       envir = sctenv)
SSQL <- character(0)
assign("run_step", function(con, name, sql, qc = NULL) {
  SSQL <<- c(SSQL, sql); invisible(TRUE) }, envir = sctenv)
# The step writes lot1_sct through materialize() now. Captured as the view
# spelling so the extraction below stays about the emitted SQL body.
assign("materialize", function(con, step, view, name, body, qc = NULL) {
  SSQL <<- c(SSQL, paste0("CREATE OR REPLACE TEMPORARY VIEW ", view, " AS", body))
  invisible(NULL) }, envir = sctenv)
sys.source(file.path(ROOT, "R", "steps", "05b_lot1_sct.R"), envir = sctenv)
sctenv$phase_lot1_sct(NULL, NULL)
s15 <- SSQL[grepl("VIEW lot1_sct", SSQL, fixed = TRUE)][1]

# The whole CASE arm, between its own THEN and the ELSE NULL that closes it.
# glue strips the template's common indent, so the anchors cannot depend on how
# far in it sits - and neither anchor mentions the floor, so removing the floor
# fails the arithmetic below rather than the extraction.
b  <- regexpr("ELSE NULL\\s+END AS LOT1_TX_ENDDATE", s15)
th <- gregexpr("IS NOT NULL\\s+THEN ", s15)[[1]]
# The last THEN before that ELSE, not the first in the statement - earlier CASEs
# in the same view have the same shape and one of them matched instead.
k <- if (b > 0) rev(which(th > 0 & th < b))[1] else NA_integer_
ok(!is.na(k), "the LOT1_TX_ENDDATE arm is where it was")
expr_sql <- if (!is.na(k))
  substr(s15, th[k] + attr(th, "match.length")[k], b - 1L) else "NA"

# Spark to R. Each name is a whole-word swap of an operator with the same
# meaning, so what runs below is the shipped arithmetic and not a paraphrase.
r <- expr_sql
r <- gsub("cast('9999-12-31' as date)", "SENTINEL", r, fixed = TRUE)
r <- gsub("date_sub(", "dsub(", r, fixed = TRUE)
r <- gsub("greatest(", "gt(", r, fixed = TRUE)
r <- gsub("least(", "lt(", r, fixed = TRUE)
r <- gsub("coalesce(", "cly(", r, fixed = TRUE)
r <- gsub("sd\\.", "", r)
SENTINEL <- as.Date("9999-12-31")
dsub <- function(x, n) x - n
gt   <- function(...) do.call(max, list(...))
lt   <- function(...) do.call(min, list(...))
cly  <- function(...) { v <- c(...); v[!is.na(v)][1] }
enddate <- function(start, auto = NA, allo = NA, cart = NA) {
  e <- new.env(parent = environment())
  assign("LOT1_START_DT", as.Date(start), envir = e)
  assign("ENDING_AUTO_DT", as.Date(auto),  envir = e)
  assign("FIRST_ALLO_DT",  as.Date(allo),  envir = e)
  assign("ENDING_CART_DT", as.Date(cart),  envir = e)
  eval(parse(text = r), envir = e)
}
ok(identical(enddate("2025-04-22", cart = "2025-04-22"), as.Date("2025-04-22")),
   "a CAR-T on the start date ends LOT1 on that date, not the day before")
ok(identical(enddate("2025-04-22", allo = "2025-04-22"), as.Date("2025-04-22")),
   "...and so does an allogeneic transplant on the start date")
# The floor is a floor, not a rewrite: a transplant later in the line still
# ends it the day before, which is the rule the whole algorithm is built on.
ok(identical(enddate("2025-04-22", cart = "2025-07-31"), as.Date("2025-07-30")),
   "a CAR-T later in the line still ends it the day before, unchanged")
ok(identical(enddate("2025-04-22", auto = "2025-06-01", cart = "2025-07-31"),
             as.Date("2025-05-31")),
   "and the earliest of the three still wins")

cat("\n-- the CAR-T induction rule --\n")
# Two defects shipped here, and both were the same mistake: the induction test
# was applied to min(TX_DT) instead of to the rows going into it. A patient with
# a CAR-T on day 20 and another on day 90 had the min taken first and nulled, so
# the day-90 infusion ended nothing and started nothing; and the day-20 one went
# on censoring later AUTOs out of LOT1 while being declared part of it.
#
# The suite could not have caught either: the fixture above sets no
# apply_cart_induction_rule, so every assertion ran the rule-off path.
sys.source(file.path(ROOT, "R", "cart_rule.R"), envir = globalenv())
ok(identical(cart_eligible_dt(FALSE, "X", "Y", 60), "X") &&
     identical(cart_exclude_predicate(FALSE, "X", "Y", 60, "E"), "") &&
     identical(cart_censor_predicate(FALSE, "T", "X", "Y", 60), ""),
   "rule off is a passthrough in all three helpers, so the SQL is unchanged")
ok(has(cart_eligible_dt(TRUE, "X", "Y", 60), "date_add(Y, 59)"),
   "the window is 60 days inclusive - day 0 through day 59")

# The exemption is conditional on LOT1 still running. Read as "inside the
# window" alone, the window outlived the line: a LOT1 that discontinued inside
# its own 60 days left an in-window CAR-T after the end that this predicate
# refused as a LOT2 start, and that nothing else could place. It belonged to no
# line at all.
xcl <- cart_exclude_predicate(TRUE, "ac.TX_DT", "pe.PREV_START_DT", 60,
                              "pe.PREV_END_DT")
ok(has(xcl, "AND ac.TX_DT <= pe.PREV_END_DT"),
   "the exclusion asks whether LOT1 was still running, not only whether the CAR-T is in the window")
ok(has(xcl, "BETWEEN pe.PREV_START_DT AND date_add(pe.PREV_START_DT, 59)"),
   "...and still asks the window question as well, so an in-line CAR-T is unaffected")
# Both halves are one NOT(), so a CAR-T failing either half is a candidate.
ok(length(gregexpr("AND NOT (", xcl, fixed = TRUE)[[1]]) == 1L,
   "...as one negated conjunction, so failing either half leaves the CAR-T a start candidate")
# The other side of the same rule: a CAR-T after the run-out has to be able to
# confirm the run-out it follows. Two wrong answers were shipped here in turn -
# ENDING_CART_DT, which the induction exemption nulls, and then FIRST_CART_DT,
# which is min() over the line and so hides a later infusion behind an earlier
# absorbed one. The property that rules both out is that the arm reads no
# aggregate at all.
e6 <- paste(readLines(file.path(ROOT, "R", "steps", "06_lot1_end.R"), warn = FALSE),
            collapse = "\n")
prt <- substr(e6, regexpr("post_runout_trigger AS", e6),
              regexpr("AS POST_RUNOUT_TRIGGER_FLG", e6))
ok(!grepl("sct\\.", prt),
   "no arm of the post-run-out trigger reads lot1_sct, whose dates are min() over the line")
ok(length(gregexpr("PATID IS NOT NULL", prt, fixed = TRUE)[[1]]) == 3L,
   "...all three event arms are existence tests over per-row CTEs, med / sct / auto")
ok(!grepl("> lb\\.LOT1_BASE_RUNOUT_DT", prt),
   "...and none of them compares a date, which is what let an earlier event hide a later one")

# The predicate itself, lifted out of the step's own SQL and evaluated over the
# patient it was got wrong for. A second copy written here would agree with
# whatever this file believed, so the text is translated rather than restated,
# and the translation has to consume all of it - a leftover SQL fragment makes
# eval() error rather than quietly testing something else.
prs <- substr(e6, regexpr("post_runout_sct AS", e6), regexpr("post_runout_trigger AS", e6))
wh  <- sub("(?s)^.*?WHERE\\s+", "", prs, perl = TRUE)
wh  <- gsub("\\s+", " ", sub("(?s)\\),.*$", "", wh, perl = TRUE))
r <- wh
r <- gsub("lb.LOT1_BASE_RUNOUT_DT IS NOT NULL", "!is.na(RUNOUT)", r, fixed = TRUE)
r <- gsub("ac.SCT_TYPE IN ('ALLO', 'CART')", "TYPE %in% c('ALLO','CART')", r, fixed = TRUE)
r <- gsub("ac.TX_DT > lb.LOT1_BASE_RUNOUT_DT", "TX > RUNOUT", r, fixed = TRUE)
r <- gsub("ac.TX_DT <= lb.OBS_END_DT", "TX <= OBS_END", r, fixed = TRUE)
r <- gsub(" AND ", " & ", r, fixed = TRUE)
ok(!grepl("ac\\.|lb\\.|SELECT|WHERE", r),
   "the post-run-out SCT predicate translates whole, so the case below tests the shipped text")
confirms <- function(TX, TYPE = "CART", RUNOUT = 39, OBS_END = 100)
  isTRUE(eval(parse(text = r)))

# LEN d0, a CAR-T absorbed into the live line on d20, LEN running out d39, a
# second CAR-T on d50, observation ending d100 - 61 days after the run-out, so
# it cannot be confirmed by observation either.
ok(!confirms(20), "an absorbed CAR-T before the run-out does not confirm it")
ok(confirms(50),  "...and the second one, after the run-out, does")
ok(any(vapply(c(20, 50), confirms, logical(1))),
   "...so the patient with both confirms, which reading min() over the two could not")
ok(confirms(50, TYPE = "ALLO") && !confirms(20, TYPE = "ALLO"),
   "the same holds for ALLO, which had the identical min() comparison")
ok(!confirms(120), "an infusion past the end of observation confirms nothing")

# Generated with the rule ON, which the fixture above never does.
cenv <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "cart_rule.R"), envir = cenv)
sys.source(file.path(ROOT, "R", "prior_regimen.R"), envir = cenv)
assign("cfg", list(sct_tandem_days = 180L, induction_window_days = 60L,
                   apply_cart_induction_rule = TRUE), envir = cenv)
CSQL <- character(0)
assign("run_step", function(con, name, sql, qc = NULL) {
  CSQL <<- c(CSQL, sql); invisible(TRUE) }, envir = cenv)
assign("materialize", function(con, step, view, name, body, qc = NULL) {
  CSQL <<- c(CSQL, paste0("CREATE OR REPLACE TEMPORARY VIEW ", view, " AS", body))
  invisible(NULL) }, envir = cenv)
sys.source(file.path(ROOT, "R", "steps", "05b_lot1_sct.R"), envir = cenv)
cenv$phase_lot1_sct(NULL, NULL)
c15 <- CSQL[grepl("VIEW lot1_sct", CSQL, fixed = TRUE)][1]
# The filter has to sit INSIDE the aggregate. min() over a gated column is the
# earliest eligible CAR-T; gating min() is the earliest CAR-T, deleted.
ok(has(c15, "min(CASE WHEN NOT ("),
   "the induction test is applied per row, inside min(), not to its result")
ok(has(c15, "AS ENDING_CART_DT") && has(c15, "min(ac.TX_DT) AS CART_DT"),
   "...so both dates exist: the earliest CAR-T, and the earliest that can end a line")
# The boundary reads the eligible one; LOT1_1ST_SCT_DT keeps the descriptive one.
end_arm <- substr(c15, regexpr("LOT1_TX_ENDDATE: earliest", c15),
                  regexpr("AS LOT1_TX_ENDDATE_REASON", c15))
ok(has(end_arm, "ENDING_CART_DT") && !has(end_arm, "FIRST_CART_DT"),
   "the LOT1 end date is built from the eligible CAR-T, not the first one")
ok(has(c15, "sd.FIRST_CART_DT,"),
   "...and the first CAR-T is still carried, because LOT1_1ST_SCT_DT is descriptive")
# The censor. An in-induction CAR-T is part of LOT1, so it cannot remove the
# AUTOs that follow it from LOT1.
ena <- substr(c15, regexpr("earliest_non_auto AS", c15),
              regexpr("auto_in_lot1 AS", c15))
ok(has(ena, "AND NOT (ac.SCT_TYPE = 'CART'"),
   "an in-induction CAR-T stops censoring the AUTOs after it")


cat("\n-- single AUTO allowed, tandem pair allowed, excess AUTO ends LOT1 --\n")
# ENDING_AUTO_DT is where that rule lives. Without these cases the whole CASE
# can be replaced with cast(NULL as date) and every suite stays green - no
# excess transplant ends LOT1, affected patients get one long line instead of
# two, and LOT_LONG row counts, LOT1 length and every downstream figure move.
# The only other test touching it injects it as an input.
#
# The nearest CASE before the alias, as above: earlier CASEs in this view have
# the same shape and matching forwards finds one of them.
ea <- regexpr("END AS ENDING_AUTO_DT", s15, fixed = TRUE)
cw <- gregexpr("CASE", s15, fixed = TRUE)[[1]]
j  <- if (ea > 0) rev(which(cw > 0 & cw < ea))[1] else NA_integer_
ok(!is.na(j), "the ENDING_AUTO_DT rule is where it was")
case_sql <- if (!is.na(j)) substr(s15, cw[j], ea + 3L) else "CASE ELSE NULL END"

# CASE WHEN a THEN x WHEN b THEN y ELSE z END -> nested if/else, so what runs
# is the shipped rule rather than a second copy of it that agrees with itself.
case_to_r <- function(x) {
  # Trailing -- comments first: collapsing the newlines would fold one into the
  # expression and comment out the rest of the rule.
  x <- paste(sub("--.*$", "", strsplit(x, "\n", fixed = TRUE)[[1]]), collapse = "\n")
  x <- gsub("\n\\s*", " ", trimws(x))
  x <- sub("^CASE\\s*", "", sub("\\s*END$", "", x))
  els <- "NA"
  if (grepl("\\bELSE\\b", x)) {
    els <- trimws(sub("^.*\\bELSE\\b", "", x)); x <- sub("\\bELSE\\b.*$", "", x)
  }
  arms <- Filter(nzchar, trimws(strsplit(x, "\\bWHEN\\b")[[1]]))
  tr <- function(s) {
    s <- gsub("\\b(ap|ab|ti)\\.", "", trimws(s))
    s <- gsub("([A-Za-z_][A-Za-z0-9_]*) IS NOT NULL", "!is.na(\\1)", s)
    s <- gsub("([A-Za-z_][A-Za-z0-9_]*) IS NULL", "is.na(\\1)", s)
    s <- gsub("datediff(", "dd(", gsub("coalesce(", "cly(", s, fixed = TRUE), fixed = TRUE)
    s <- gsub("\\bAND\\b", "&", gsub("\\bOR\\b", "|", s))
    s <- gsub("(?<![<>!=])=(?!=)", "==", s, perl = TRUE)
    gsub("\\bNULL\\b", "NA", s)
  }
  out <- vapply(arms, function(a) {
    kv <- strsplit(a, "\\bTHEN\\b")[[1]]
    paste0("if (isTRUE(", tr(kv[1]), ")) ", tr(kv[2]), " else ")
  }, character(1))
  paste0(paste(out, collapse = ""), tr(els))
}
dd <- function(a, b) as.numeric(a - b)
ending_auto <- function(a1 = NA, a2 = NA, a3 = NA, allo_between = 0,
                        n_between = 0) {
  e <- new.env(parent = environment())
  for (n in c("AUTO_DT_1", "AUTO_DT_2", "AUTO_DT_3"))
    assign(n, as.Date(get(c(AUTO_DT_1 = "a1", AUTO_DT_2 = "a2", AUTO_DT_3 = "a3")[n])), envir = e)
  assign("n_allo_between", allo_between, envir = e)
  assign("n_between", n_between, envir = e)
  eval(parse(text = case_to_r(case_sql)), envir = e)
}
D <- function(x) as.Date(x)
# One transplant is induction, not an ending event. Nothing to end the line.
ok(is.na(ending_auto(a1 = "2025-03-01")),
   "a single AUTO does not end LOT1 - it is part of induction")
# Two within 180 days with no ALLO between them is a planned tandem, also
# allowed, so the line ends only if a third arrives.
ok(is.na(ending_auto(a1 = "2025-03-01", a2 = "2025-06-01")),
   "a tandem pair does not end LOT1 either")
ok(identical(ending_auto(a1 = "2025-03-01", a2 = "2025-06-01", a3 = "2025-11-01"),
             D("2025-11-01")),
   "...but a third AUTO after a tandem does, on its own date")
# 246 days apart is not a tandem, so the second one is already excess.
ok(identical(ending_auto(a1 = "2025-03-01", a2 = "2025-11-02"), D("2025-11-02")),
   "two AUTOs more than 180 days apart are not a tandem - the second ends LOT1")
# An allogeneic transplant between them disqualifies the tandem, so likewise.
ok(identical(ending_auto(a1 = "2025-03-01", a2 = "2025-06-01", allo_between = 1),
             D("2025-06-01")),
   "an ALLO between the pair disqualifies the tandem, so the second ends LOT1")
# A medication starting between the two is the same disqualification, and the
# one the ALLO check above could not see. The gap alone does not make a pair
# planned: a patient treated in between was not waiting for a transplant.
ok(identical(ending_auto(a1 = "2025-03-01", a2 = "2025-06-01", n_between = 1),
             D("2025-06-01")),
   "...and so does anything else in the middle - a tandem needs a clear gap")
ok(is.na(ending_auto()), "no transplant at all ends nothing")


cat("\n-- ...and the invariants are actually asked, every one of them --\n")
# Nothing ran this function. The assertions above are about the contents of the
# list, so check_lot1_invariants() could have been turned into a no-op - or made
# to check only the first entry - with the whole suite still green. Both were
# tried; both passed. Driven now, one query at a time.
assign("log_msg", function(...) invisible(NULL), envir = env)
ISQL <- character(0)
# Answers are matched back to the invariant by its own SQL, not by call order,
# so "only the last one breached" means that one and cannot mean another.
drive_inv <- function(counts = rep(0L, length(inv))) {
  ISQL <<- character(0)
  assign("db_q", function(con, sql) {
    ISQL <<- c(ISQL, sql)
    j <- which(vapply(inv, function(v) identical(v$sql, sql), logical(1)))
    data.frame(n = if (length(j) == 1L) counts[[j]] else NA_integer_)
  }, envir = env)
  tryCatch({ env$check_lot1_invariants(NULL, list()); NULL }, error = conditionMessage)
}
ok(is.null(drive_inv()), "a LOT1 that breaches nothing passes")
ok(length(ISQL) == length(inv) && length(unique(ISQL)) == length(inv),
   paste0("every invariant is a query of its own (", length(ISQL), " of ",
          length(inv), ")"))
# One at a time, so a loop that stopped after the first would fail on the rest.
for (i in seq_along(inv)) {
  breach <- rep(0L, length(inv)); breach[i] <- 3L
  msg <- drive_inv(breach)
  ok(!is.null(msg) && grepl(inv[[i]]$name, msg, fixed = TRUE),
     paste0("a breach of '", inv[[i]]$name, "' stops the build, named"))
}
# A count that comes back NULL is not a count of zero: the query could not
# answer, and a check that cannot run is not a check that passed.
na_breach <- rep(0L, length(inv)); na_breach[2] <- NA_integer_
ok(!is.null(drive_inv(na_breach)), "an invariant that answers NA stops it too")
two <- rep(0L, length(inv)); two[c(1, length(inv))] <- 5L
msg <- drive_inv(two)
ok(!is.null(msg) && grepl(inv[[1]]$name, msg, fixed = TRUE) &&
     grepl(inv[[length(inv)]]$name, msg, fixed = TRUE),
   "and two breaches are both reported, not just the first")
# No tryCatch in the loop, by design. A connection error has to surface as
# itself rather than as "LOT1 is internally inconsistent".
assign("db_q", function(con, sql) stop("connection reset by peer"), envir = env)
msg <- tryCatch({ env$check_lot1_invariants(NULL, list()); NULL },
                error = conditionMessage)
ok(!is.null(msg) && grepl("connection reset", msg, fixed = TRUE) &&
     !grepl("internally inconsistent", msg, fixed = TRUE),
   "a query that cannot run surfaces as itself, not as a LOT1 defect")
rm("db_q", envir = env)

cat("\n-- the cohort is pinned, not re-read --\n")
# A Spark temporary view re-runs its query on every read, so lot_patient_input
# over the cohort table is not a snapshot: a cohort job rebuilding that table
# mid-run changes what LOT reads from there on. "Do not rebuild it" is not
# enforceable for a package pointed at many cohorts, so the run takes its own
# copy and reads that.
# The build_lot() wiring, which the run below cannot see: the first check has
# to hand its counts to the copy rather than throw them away.
ok(grepl("cohort <- check_cohort_input(con, wrk(cfg$input_cohort_table))", bl,
         fixed = TRUE) &&
     grepl("materialize_cohort_input(con, cohort)", bl, fixed = TRUE),
   "the first check hands its counts forward rather than throwing them away")
ok("LOT_PATIENT_INPUT" %in% OUTPUTS,
   "it is a prefixed output, so two cohorts cannot share one snapshot")

# Everything above reads the source. An early return leaves all of those lines
# in place, so the whole function could be made a no-op - no snapshot written,
# the view still on the live cohort table, the re-check never run - with every
# assertion still passing. Driven from here down, and
# check_cohort_input is the real one so the re-validation actually happens.
me <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "build_lot.R"), envir = me)
assign("log_msg", function(...) invisible(NULL), envir = me)
assign("lot_out", function(x) paste0("wk.p_", x), envir = me)
MSQL <- character(0); MQRY <- character(0)
assign("run_step", function(con, name, sql, qc = NULL) {
  MSQL <<- c(MSQL, sql); invisible(TRUE) }, envir = me)
assign("db_exec", function(con, sql) { MSQL <<- c(MSQL, sql); invisible(TRUE) }, envir = me)
# The real materialize(), rebound so its run_step and lot_out are the stubs
# above - the pinning below then exercises the statements it actually emits,
# not a paraphrase of them.
mat_real <- get("materialize", envir = globalenv())
environment(mat_real) <- me
assign("materialize", mat_real, envir = me)
MGOOD <- list(n_rows = 10, n_patients = 10, n_null_patid = 0, n_null_index = 0,
              n_null_end = 0, n_end_before_index = 0)
drive_mci <- function(before = list(n_rows = 10, n_patients = 10), shape = list()) {
  MSQL <<- character(0); MQRY <<- character(0)
  sh <- modifyList(MGOOD, shape)
  assign("db_q", function(con, sql) {
    MQRY <<- c(MQRY, sql)
    if (grepl("DESCRIBE", sql, fixed = TRUE))
      return(data.frame(col_name = REQUIRED_COHORT_COLS, stringsAsFactors = FALSE))
    as.data.frame(sh)
  }, envir = me)
  tryCatch({ me$materialize_cohort_input(NULL, before); NULL }, error = conditionMessage)
}
ok(is.null(drive_mci()), "a cohort that has not moved is pinned and passes")
i_tbl <- which(grepl("CREATE OR REPLACE TABLE wk.p_LOT_PATIENT_INPUT AS\nSELECT * FROM lot_patient_input",
                     MSQL, fixed = TRUE))[1]
i_vw  <- which(grepl("CREATE OR REPLACE TEMPORARY VIEW lot_patient_input AS SELECT * FROM wk.p_LOT_PATIENT_INPUT",
                     MSQL, fixed = TRUE))[1]
ok(!is.na(i_tbl), "the snapshot table is written from the session view")
ok(!is.na(i_vw), "...and the session view is repointed at the table")
# The other order would define the view from itself.
ok(!is.na(i_tbl) && !is.na(i_vw) && i_tbl < i_vw,
   "in that order, so the view is never defined from itself")
# Against the snapshot, not the table it came from: re-checking the source
# would pass on rows that were never copied.
ok(any(grepl("DESCRIBE wk.p_LOT_PATIENT_INPUT", MQRY, fixed = TRUE)) &&
     any(grepl("FROM wk.p_LOT_PATIENT_INPUT", MQRY, fixed = TRUE)),
   "the re-check asks about the snapshot, not the cohort table")
# The full check, not just the counts: a snapshot with a repeated patient is
# refused even though nothing about its size changed.
msg <- drive_mci(before = list(n_rows = 10, n_patients = 9),
                 shape = list(n_patients = 9))
ok(!is.null(msg) && grepl("one index per patient", msg, fixed = TRUE),
   "a snapshot that is malformed is refused, counts or no counts")
msg <- drive_mci(before = list(n_rows = 12, n_patients = 12))
ok(!is.null(msg) && grepl("changed size", msg, fixed = TRUE) &&
     grepl("12 rows", msg, fixed = TRUE) && grepl("10", msg, fixed = TRUE),
   "and a cohort that changed size stops the run, with both counts")
# Before anything reads the cohort. phase_patient_input defines the view;
# nothing between that and the copy may consume it.
pos <- function(f) regexpr(paste0("(?<![A-Za-z0-9_.])", f, "\\("), body, perl = TRUE)
ok(pos("phase_patient_input") < pos("materialize_cohort_input") &&
     pos("materialize_cohort_input") < pos("check_claim_ndc") &&
     pos("materialize_cohort_input") < pos("phase_mma_map"),
   "pinned before the first phase that joins it")

cat("\n-- the claim side of the NDC contract --\n")
# ndc_shape and ndc_short constrain the code list; both joins pad the claim the
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
# The claim side is REPORTED, never gated. Optum writes NONE or UNK where a
# medical claim has no NDC - 1.2bn rows of them - and stopping a build over
# that asked the operator to approve the vendor's word for null. A value that
# matches nothing is a non-match, which is what a join produces.
for (case in list(
      list(r = prow("rx", 9000, a = 8000, b = 1000), w = "a ten-digit value"),
      list(r = prow("rx", 10, a = 7, alpha = 3),     w = "letters"),
      list(r = prow("rx", 10, a = 9, o = 1),         w = "another length"),
      list(r = prow("rx", 10, a = 8, zero = 2),      w = "all zeros"),
      list(r = prow("rx", 10, a = 8, o = 2, nodig = 2), w = "no digits at all")))
  ok(is.null(drive_ndc(prow("medical", 500, a = 500), case$r)),
     paste0(case$w, " in a claim NDC is reported, not a wall"))
# What makes that safe: ndc_key() gives a key only to something that could be
# an NDC, so none of the above can collide with a code list entry.
k <- ndc_key("m.NDC")
ok(grepl("CASE WHEN", k, fixed = TRUE) && grepl("END", k, fixed = TRUE),
   "the claim side of the join is a CASE, so a non-NDC yields no key at all")
ok(grepl("= 11 THEN", k, fixed = TRUE) && grepl("= 10 THEN concat('0'", k, fixed = TRUE),
   "...eleven digits as they are, ten padded on the 4-4-2 layout")
ok(grepl("RLIKE '^0+$' THEN NULL", k, fixed = TRUE),
   "...and all zeros is not a product, so it gets none")
ok(!any(c("claim_ndc_short", "claim_ndc_shape") %in% WAIVABLE_CHECKS),
   "and neither claim-side condition is a waiver any more - there is nothing to waive")
ok(all(c("orphan_meds", "uncoded_meds", "ndc_short") %in% WAIVABLE_CHECKS),
   "...while the code list's own conditions, which are fixable at source, remain")

# The stub decides what the counts are, so it cannot show that the query would
# ever produce them. A value with no digits only reaches the profile because
# the WHERE stopped excluding it - assert that on the SQL.
ok(!any(grepl("AND regexp_replace(cast(t.NDC as string), \'[^0-9]\', \'\') <> \'\'",
              NSQL, fixed = TRUE)),
   "the profile keeps the values it is meant to report")
for (b in c("AS n_nodigit", "AS n_zero"))
  ok(all(grepl(b, NSQL, fixed = TRUE)), paste0("the profile counts ", b))
# Waivable, so a first run reports the distribution rather than blocking on a
# shape nobody has seen yet - and what fired is recorded, not just requested.


# Two writers record applied waivers. Each was covered alone; this drives them
# in sequence, so one cannot clobber what the other recorded.
Sys.setenv(CODELIST_WAIVERS = "uncoded_meds,orphan_meds")
options(lot_waivers_applied = character(0))
assign("db_q", mk_db_q("uncoded"), envir = ce)
invisible(ce$phase_codelists(NULL))
invisible(drive_ndc(prow("medical", 500, a = 500), prow("rx", 9000, a = 8000, b = 1000)))
assign("db_q", mk_db_q("uncoded"), envir = ce)
invisible(ce$phase_codelists(NULL))
ok("uncoded_meds" %in% getOption("lot_waivers_applied"),
   "a waiver survives phase_codelists running a second time")
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

cat("\n-- LOT_LONG has to be chronologically possible --\n")
# The lines form a chain: each starts strictly after the previous one ended,
# and none runs past the patient's observation. Both are re-derivable, so a
# breach means the iterative builder went wrong - it should stop, not report.
le <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "build_lot.R"), envir = le)
assign("log_msg", function(...) invisible(NULL), envir = le)
assign("lot_out", function(x) x, envir = le)
# No hand-rolled substitution here: testutil.R's stand-in interpolates for
# real, so {tbl} and {cfg$max_lot} resolve from the calling frame the way glue
# would. The stub this replaces rewrote a fixed {t} and would have gone quietly
# inert the moment that variable was renamed - which is exactly what happened.
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

cat("\n-- ...and so does the table downstream actually reads --\n")
# check_lot_long ran on LOT_LONG. LOT_LONG_FINAL is what the study reads, and
# a truncate criterion makes it a different table - one nothing was looking at.
LFSQL <- character(0)
lf_stub <- function(n_rows = 90, n_patients = 40, gaps = 0) {
  LFSQL <<- character(0)
  assign("db_q", function(con, sql) {
    LFSQL <<- c(LFSQL, sql)
    if (grepl("HAVING lo <> 1", sql, fixed = TRUE)) return(data.frame(n = gaps))
    data.frame(n_rows = n_rows, n_patients = n_patients)
  }, envir = le)
}
lf_stub()
ok(!inherits(tryCatch(le$check_lot_final(NULL, cfg_ll), error = function(e) e), "error"),
   "a sound LOT_LONG_FINAL passes")
lf_stub(n_rows = 0, n_patients = 0)
ok(grepl("removed every one of them",
         tryCatch({ le$check_lot_final(NULL, cfg_ll); "" }, error = conditionMessage),
         fixed = TRUE),
   "a criterion that truncates every patient at LOT 1 stops the run, and says why")
lf_stub(gaps = 7)
ok(inherits(tryCatch(le$check_lot_final(NULL, cfg_ll), error = function(e) e), "error"),
   "a removal that takes a line out of the middle stops the build")
lf_stub()
ok(identical(le$check_lot_final(NULL, cfg_ll), list(n_rows = 90, n_patients = 40)),
   "and its counts are handed to record_final_counts rather than scanned for twice")
# Both queries name LOT_LONG_FINAL, not LOT_LONG. check_lot_long already passed
# on the latter, so a check_lot_final that read it would agree with itself and
# report nothing. It also proves the name is really interpolated rather than
# left as a literal {tbl}, which is what the hand-rolled glue stub above used
# to hide.
ok(length(LFSQL) == 2 && all(grepl("LOT_LONG_FINAL", LFSQL, fixed = TRUE)),
   paste0("it asks about LOT_LONG_FINAL, in both queries (", length(LFSQL), ")"))

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
# sides out of the SQL and require them to be the same set: a new extraction
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

cat("\n-- and the one way past it marks what it built --\n")
# The sensitivity sweep varies contract-pinned thresholds by definition, so
# without a way past this it has no executable path at all. The override is
# only safe because a run that uses it cannot be mistaken for the study's: the
# deviations go into LOT_BUILD_STATUS, which is where every downstream reader
# already resolves which run owns a prefix's tables.
clear()
alt <- modifyList(pin_cohort(base, TBL_A, PFX_A), list(max_lot = 8L))
stops(check_lot_contract(alt), "a changed threshold is still refused by default")
Sys.setenv(LOT_CONTRACT_OVERRIDE = "TRUE")
runs(check_lot_contract(alt), "...and allowed only when the caller says so explicitly")
ok(identical(getOption("lot_contract_deviations"), "max_lot=8 (contract 5)"),
   "...recording exactly what deviated, in the words a reader needs")
# The build pins state in options, and a second build in one session inherits
# the first's - which is how a waiver list once leaked between runs.
runs(check_lot_contract(pin_cohort(base, TBL_A, PFX_A)),
     "a contract build after an overridden one still passes")
ok(identical(getOption("lot_contract_deviations"), character(0)),
   "...and carries none of the previous run's deviations")
ok("CONTRACT_DEVIATIONS" %in% names(BUILD_STATUS_COLS),
   "the status table has a column for them, so ownership and algorithm resolve together")
# Built from CONTRACT itself, CONTRACT_SETTINGS would record the values an
# overridden run was SUPPOSED to use rather than the ones it used. The dashboard reads
# max_lot out of that string to decide how many panels a run has.
Sys.setenv(LOT_CONTRACT_OVERRIDE = "TRUE")
ok(grepl("max_lot=8", contract_settings(alt), fixed = TRUE),
   "the recorded settings are what the run actually used")
ok(grepl("max_lot=5", contract_settings(pin_cohort(base, TBL_A, PFX_A)), fixed = TRUE),
   "...which is unchanged for a contract build, since the two agree there")
clear()

cat("\n-- settings that would otherwise fail open --\n")
# as.integer("60.5") is 60, so the NA test accepted it and the run used 60
# while the operator had asked for 60.5. Their setting was ignored, silently.
for (bad_int in c("60.5", "6e1", "-5", " 60.0 ")) {
  Sys.setenv(INDUCTION_WINDOW_DAYS = bad_int)
  m <- tryCatch({ check_settings(); "" }, error = conditionMessage)
  ok(grepl("want a whole number", m, fixed = TRUE),
     paste0("INDUCTION_WINDOW_DAYS='", bad_int, "' is refused, not truncated"))
}
Sys.setenv(INDUCTION_WINDOW_DAYS = "60")
ok(identical(tryCatch({ check_settings(); "" }, error = conditionMessage), ""),
   "...and a whole number is still accepted")
Sys.unsetenv("INDUCTION_WINDOW_DAYS")
# run_id goes into fifteen SQL string literals, and every other identifier that
# reaches SQL is checked. An apostrophe in it closes the literal early.
Sys.setenv(DOMINO_RUN_ID = "R1'; DROP TABLE x; --")
ok(grepl("DOMINO_RUN_ID", tryCatch({ check_settings(); "" }, error = conditionMessage),
         fixed = TRUE),
   "a run id that would not survive being quoted is refused")
Sys.setenv(DOMINO_RUN_ID = "run-2026.07.31_01")
ok(identical(tryCatch({ check_settings(); "" }, error = conditionMessage), ""),
   "...and the shapes a platform actually issues are accepted")
Sys.unsetenv("DOMINO_RUN_ID")
clear()
runs(check_settings(), "unset is fine")
Sys.setenv(CENSOR_AT_DISENROLLMENT = "Y")
stops(check_settings(), "as.logical('Y') is NA, not FALSE")
clear()
# Same coercion, and it was not in the list: a typo made this NA, isTRUE(NA) is
# FALSE, and a run told to stop on a face-validity band carried on instead.
Sys.setenv(FACE_VALIDITY_FATAL = "Ture")
stops(check_settings(), "a mistyped FACE_VALIDITY_FATAL is rejected, not read as off")
clear()
Sys.setenv(MAP_DISCON_GAP_DAYS = "ninety")
stops(check_settings(), "a window that will not parse")
clear()
Sys.setenv(STUDY_END = "30-06-2025")
stops(check_settings(), "an Excel-reformatted STUDY_END")
clear()
Sys.setenv(STUDY_START = "01-01-2016")
stops(check_settings(), "...and an Excel-reformatted STUDY_START, same rule")
clear()
# Both parse, in the wrong order. Each passes its own format check, and the
# result would be a window no cohort can satisfy.
Sys.setenv(STUDY_START = "2026-01-01", STUDY_END = "2025-06-30")
stops(check_settings(), "a study window that runs backwards")
clear()
Sys.setenv(STUDY_START = "2016-01-01", STUDY_END = "2025-06-30")
runs(check_settings(), "and the configured window is accepted")
clear()
Sys.setenv(PROJECT_WORK_SCHEMA = "hive_metastore.usr00000")
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

cat("\n-- the lists whose contents are the safety property --\n")
# Each of these is a constant vector, and what makes it right is its contents,
# not the code that reads them. Dropping an entry passed the whole suite:
# REQUIRED_COHORT_COLS losing a column means a cohort missing it clears
# preflight and fails deep in the build, LOT2_5_INPUT_VIEWS losing one means
# the presence check answers yes when it is absent. So each is read from the
# thing that decides it, rather than restated here as a fourth copy.

# 1. The columns LOT reads off the cohort table are the ones phase_patient_input
#    selects from it. OBS_END_DT is the exception: it is derived, not read.
pin <- readLines(file.path(ROOT, "R", "steps", "02_patient_input.R"), warn = FALSE)
sel <- pin[(grep("^\\s*SELECT\\s*$", pin)[1] + 1):(grep("FROM \\{wrk\\(", pin)[1] - 1)]
sel <- sel[!grepl("^\\s*--", sel)]
selcols <- setdiff(unique(unlist(regmatches(sel, gregexpr("[A-Z][A-Z0-9_]{2,}", sel)))),
                   c("AS", "DATE", "CASE", "WHEN", "THEN", "ELSE", "END", "NULL",
                     "SELECT", "FROM", "OBS_END_DT"))
ok(setequal(selcols, REQUIRED_COHORT_COLS),
   paste0("every cohort column the build reads is one preflight requires (",
          length(REQUIRED_COHORT_COLS), ")"))

# 2. Waiting on a view nobody creates never ends, and a view LOT2-5 reads that
#    is not listed is a hole in the check. Both directions, plus the three
#    materialize_sct_views needs immediately afterwards.
L25_FILE   <- file.path(ROOT, "R", "steps", "10_lot2_5_base.R")
lot1_files <- setdiff(list.files(file.path(ROOT, "R", "steps"), "\\.R$", full.names = TRUE),
                      L25_FILE)
# A session name is created two ways now: CREATE VIEW directly, or
# materialize(view = ...), which writes the table and repoints the view at it.
# Both leave the name readable, so both count as creating it.
views_in <- function(x) unique(unlist(c(
  regmatches(x, gregexpr("(?<=CREATE OR REPLACE TEMPORARY VIEW )[a-z_0-9]+",
                         x, perl = TRUE)),
  regmatches(x, gregexpr("(?<=view = \")[a-z_0-9]+", x, perl = TRUE)),
  regmatches(x, gregexpr("(?<=view = glue\\(\")[a-z_0-9]+", x, perl = TRUE)))))
src_25   <- readLines(L25_FILE, warn = FALSE)
made_1   <- views_in(unlist(lapply(lot1_files, readLines, warn = FALSE)))
made_25  <- views_in(src_25)
ok(all(LOT2_5_INPUT_VIEWS %in% made_1),
   "every view the presence check waits for is one a LOT1 step creates")
# Only the ones LOT1 leaves behind. LOT2-5 also reads lot_long and lot, which
# it builds itself as it goes, and requiring those up front would never pass.
l25  <- paste(src_25, collapse = "\n")
need <- Filter(function(v) grepl(paste0("(FROM|JOIN)\\s+", v, "\\b"), l25),
               setdiff(made_1, made_25))
ok(all(need %in% LOT2_5_INPUT_VIEWS),
   paste0("and every view LOT1 leaves that LOT2-5 reads is listed (", length(need), ")"))
ok(all(vapply(SCT_MATERIALIZE, function(m) m$view %in% LOT2_5_INPUT_VIEWS, logical(1))),
   "including the three materialized right after the check")
# Both checks above start from views something creates, so a reference to one
# nothing defines is invisible to them - it would surface as
# TABLE_OR_VIEW_NOT_FOUND partway through a run. Read every FROM and JOIN
# instead, and require each name to be a view a step creates or a CTE in the
# same file. Comments first: "INNER JOIN because a med in only one file..."
# is prose, and reads as a reference to a table called "because".
uncomment <- function(lines)
  vapply(lines, function(l) {
    at <- sort(c(gregexpr("--", l, fixed = TRUE)[[1]], gregexpr("#", l, fixed = TRUE)[[1]]))
    at <- at[at > 0]
    for (i in at) {
      h <- substr(l, 1, i - 1)
      if (nchar(gsub("[^\"']", "", h)) %% 2 == 0) return(substr(l, 1, i - 1))
    }
    l
  }, character(1), USE.NAMES = FALSE)
step_files_all <- list.files(file.path(ROOT, "R", "steps"), "\\.R$", full.names = TRUE)
all_made <- views_in(unlist(lapply(step_files_all, readLines, warn = FALSE)))
dangling <- unlist(lapply(step_files_all, function(f) {
  txt  <- paste(uncomment(readLines(f, warn = FALSE)), collapse = "\n")
  refs <- unique(unlist(regmatches(txt,
    gregexpr("(?<=\\bFROM |\\bJOIN )[a-z_][a-z_0-9]*", txt, perl = TRUE))))
  ctes <- unique(unlist(regmatches(txt,
    gregexpr("[a-z_][a-z_0-9]*(?=\\s+AS\\s*\\()", txt, perl = TRUE))))
  d <- setdiff(refs, c(all_made, ctes))
  if (length(d)) paste0(basename(f), ": ", paste(d, collapse = ", ")) else NULL
}))
ok(length(dangling) == 0,
   if (length(dangling)) paste0("a step reads something nothing creates -- ",
                                paste(dangling, collapse = "; "))
   else "every view a step reads is one a step creates, or a CTE beside it")

step_src <- unlist(lapply(list.files(file.path(ROOT, "R", "steps"), "\\.R$",
                                     full.names = TRUE), readLines, warn = FALSE))
# 3. A check name the code raises but neither list carries would be reported and
#    then fall through unclassified; one listed but never raised is a waiver
#    offered for a condition nothing tests.
# A PCRE lookbehind has to be fixed length, so the decide() calls are matched
# whole and trimmed rather than looked behind.
dec <- regmatches(bl, gregexpr('decide\\([a-z]+, "[^"]+"', bl))[[1]]
used <- unique(c(unlist(regmatches(step_src, gregexpr('(?<=check = ")[^"]+',
                                                      step_src, perl = TRUE))),
                 sub('"$', "", sub('^decide\\([a-z]+, "', "", dec))))
ok(setequal(used, ALL_CHECKS),
   paste0("every check the code raises is classified waivable or fatal (",
          length(ALL_CHECKS), ")"))
ok(length(intersect(WAIVABLE_CHECKS, FATAL_CHECKS)) == 0,
   "and none is in both lists, which would make a fatal check waivable")

# 4. A file loaded but not declared is refused at load; a file declared but not
#    loaded stops the run at record_codelist_hashes, which wants all four.
loaded_files <- unique(unlist(regmatches(step_src,
  gregexpr('(?<=load_codelist_csv\\(")[^"]+', step_src, perl = TRUE))))
# Read here rather than relying on an environment set up further down the file.
cl_env <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "codelists_lot.R"), envir = cl_env)
CLFILES <- get("CODELIST_FILES", envir = cl_env)
ok(setequal(loaded_files, CLFILES),
   paste0("the declared code lists are exactly the ones read (",
          length(CLFILES), ")"))

cat("\n-- config.csv and CONTRACT say the same thing --\n")
# These were compared against a third copy of the values kept in this file, so
# CONTRACT could drift from both and nothing said so - changing max_lot to 6L
# in CONTRACT alone passed the whole suite. Loaded the way build.R loads it and
# handed to the real check_lot_contract instead: one place holds the values,
# and the comparison is the production one rather than a restatement of it.
rows <- read.csv(file.path(ROOT, "config.csv"), stringsAsFactors = FALSE,
                 comment.char = "#")
shipped <- setNames(trimws(as.character(rows$value)), trimws(rows$name))
cnames <- names(shipped)[nzchar(names(shipped)) & !startsWith(names(shipped), "#")]
# The environment wins over the file, so anything already set would mask it.
# Cleared for the load and put back afterwards, whatever this shell had.
was <- Sys.getenv(cnames, unset = NA_character_, names = TRUE)
for (n in cnames) Sys.unsetenv(n)
cc <- new.env(parent = globalenv())
suppressMessages({
  sys.source(file.path(ROOT, "R", "load_inputs.R"), envir = cc)
  cc$load_pipeline_inputs(ROOT, "config.csv")
  sys.source(file.path(ROOT, "R", "config_lot.R"), envir = cc)
})
for (n in cnames)
  if (is.na(was[[n]])) Sys.unsetenv(n) else do.call(Sys.setenv, setNames(list(was[[n]]), n))
loaded <- get("cfg_defaults", envir = cc)
# Only the cohort and prefix are supplied, because the caller supplies those.
# persist_to_schema is left as the file set it, so a file saying FALSE fails.
cres <- tryCatch({ check_lot_contract(modifyList(loaded,
          list(object_prefix = "x_", input_cohort_table = "T"))); NULL },
        error = conditionMessage)
ok(is.null(cres),
   paste0("config.csv, loaded as build.R loads it, satisfies CONTRACT",
          if (!is.null(cres)) paste0(" -- ", gsub("\n", " ", cres)) else ""))
# Which cfg setting each config.csv name feeds, read out of config_lot.R rather
# than listed here. Listing them was a fourth copy of the values this section
# exists to de-duplicate, and it could not see a new setting at all: absent from
# the list, it was absent from the comparison and the count still matched.
cl_lines <- readLines(file.path(ROOT, "R", "config_lot.R"), warn = FALSE)
maps <- regmatches(cl_lines, regexec('^\\s*([A-Za-z_.][A-Za-z0-9_.]*)\\s*=.*Sys\\.getenv\\("([A-Z0-9_]+)"',
                                     cl_lines))
maps <- Filter(function(m) length(m) == 3L, maps)
ENV2CFG <- setNames(vapply(maps, `[`, character(1), 2), vapply(maps, `[`, character(1), 3))
# A misspelled name sets an environment variable nothing reads, so the setting
# silently keeps its default and the contract still passes.
# APPLY_<NAME> is generated by the line-criteria framework rather than written
# in config_lot.R, so those names are read even though the scan cannot see them.
lc <- local({ e <- new.env(); sys.source(file.path(ROOT, "R", "line_criteria.R"), envir = e); e$LINE_CRITERIA })
# Every name config_lot.R reads, including the assignments that wrap onto a
# second line - the per-line regex above cannot see those, and reported
# APPLY_CART_INDUCTION_RULE as a setting nothing reads.
cl_flat <- paste(cl_lines, collapse = " ")
env_read <- unique(unlist(regmatches(cl_flat,
  gregexpr('(?<=Sys\\.getenv\\(")[A-Z][A-Z0-9_]+', cl_flat, perl = TRUE))))
unread <- setdiff(cnames, c(names(ENV2CFG), env_read,
                            paste0("APPLY_", toupper(vapply(lc, `[[`, character(1), "name")))))
ok(length(unread) == 0,
   if (length(unread)) paste0("config.csv names settings nothing reads: ",
                              paste(unread, collapse = ", "))
   else paste0("every one of the ", length(cnames), " names in config.csv is read"))

# And the other direction. The check above walks config.csv -> CONTRACT, so a
# pinned setting absent from the file passed: config_lot.R defaults it, the
# loaded values still satisfy CONTRACT, and an operator reading the file cannot
# see the setting at all. LOT_DISCON_CONFIRM_DAYS and APPLY_CART_INDUCTION_RULE
# were both in CONTRACT and in neither the file nor this comparison.
#
contract_env <- intersect(toupper(names(CONTRACT)), env_read)
invisible_pins <- setdiff(contract_env, cnames)
ok(length(invisible_pins) == 0,
   if (length(invisible_pins))
     paste0("CONTRACT pins settings config.csv does not show: ",
            paste(invisible_pins, collapse = ", "))
   else paste0("every CONTRACT setting config_lot.R reads from the environment (",
               length(contract_env), ") is visible in config.csv"))
# Every setting the file carries is either pinned by CONTRACT or named here as
# deliberately not pinned. A new one is caught by being neither.
NOT_PINNED <- c("persist_to_schema",   # check_lot_contract requires it TRUE
                # The study window is the cohort's, not the algorithm's, so it
                # is a per-run argument. pin_study_window() validates it and
                # check_lot_contract() still refuses an empty one.
                "study_start", "study_end",
                # Whatever the cohort build calls its status table. Empty means
                # try the usual names, so pinning it would tie this algorithm
                # to one cohort build's naming.
                "cohort_status_table", "cohort_prefix",
                # A run choice, not part of what a LOT run means: it changes
                # whether a plausibility warning stops the build, not the lines.
                "face_validity_fatal")
keys <- unname(ENV2CFG[intersect(cnames, names(ENV2CFG))])
loose <- setdiff(keys, c(names(CONTRACT), NOT_PINNED))
ok(length(loose) == 0,
   if (length(loose)) paste0("config.csv settings neither pinned nor excused: ",
                             paste(loose, collapse = ", "))
   else paste0("every one of the ", length(keys), " settings is pinned or excused"))
# ...and it is the file being read, not defaults that happen to agree.
pinned <- intersect(keys, names(CONTRACT))
ok(length(pinned) > 0 &&
     all(vapply(pinned, function(k) isTRUE(all.equal(loaded[[k]], CONTRACT[[k]])),
                logical(1))),
   paste0("all ", length(pinned), " settings the file carries match CONTRACT"))
# The caller passes the cohort, so config.csv must not pin one.
ok(!any(c("INPUT_COHORT_TABLE", "OBJECT_PREFIX") %in% names(shipped)),
   "config.csv does not name a cohort")

cat("\n-- the CDM vintage every read hits --\n")
# get_quarter_suffix decides which quarterly tables the whole study reads, via
# cdm_src at ten call sites, and had no test at all. CONTRACT pins STUDY_END so
# the input is guaranteed; the arithmetic that turns it into a table name was
# not. An off-by-one quarter names t_medical_2025q1, which exists, so it would
# read real data from the wrong vintage and nothing would say so.
qe <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "db_utils_lot.R"), envir = qe)
assign("log_msg", function(...) invisible(NULL), envir = qe)
QCFG <- list(catalog = "hive_metastore", cdm_schema = "clnprw_optum",
             use_quarterly_tables = TRUE, study_end = "2025-06-30")
assign("lot_config", function() QCFG, envir = qe)
# Derived a different way than the code does - (m + 2) %/% 3 against its
# ceiling(m / 3) - so this is a second opinion, not a restatement.
want_q <- function(d) {
  dt <- as.Date(d)
  sprintf("%sq%d", format(dt, "%Y"), (as.integer(format(dt, "%m")) + 2L) %/% 3L)
}
# Every call goes through this: a mutation that makes the function stop would
# otherwise propagate out of ok() and take the rest of the file with it.
qs <- function(x) tryCatch(qe$get_quarter_suffix(x),
                           error = function(e) paste("stopped:", conditionMessage(e)))
months <- sprintf("2025-%02d-15", 1:12)
got  <- vapply(months, qs, character(1), USE.NAMES = FALSE)
ok(identical(got, vapply(months, want_q, character(1), USE.NAMES = FALSE)),
   paste0("every month lands in the right quarter (", paste(unique(got), collapse = " "), ")"))
# The boundaries are where an off-by-one shows: 03-31 and 04-01 must differ.
ok(identical(qs("2025-03-31"), "2025q1") && identical(qs("2025-04-01"), "2025q2") &&
     identical(qs("2025-12-31"), "2025q4"),
   "and the quarter boundaries fall between the months, not across them")
ok(identical(qs("2024-09-30"), "2024q3"),
   "the year comes from the date, not from today")
# config.csv's value, not a CONTRACT entry - the window is passed per run now.
# `loaded` is that file read the way build.R reads it, so this is the vintage a
# production run hits when the caller passes no window of its own.
ok(identical(qs(loaded$study_end), want_q(loaded$study_end)),
   paste0("the configured STUDY_END resolves to ", want_q(loaded$study_end)))
# as.Date("30-06-2025") does not fail - it returns year 0030. Without the
# year < 1900 guard that is accepted and the suffix becomes 30q2.
ok(identical(qs("30-06-2025"), "2025q2"),
   "an Excel-reformatted date is recovered, not read as the year 30")
# All five layouts the recovery declares, not just the ones as.Date happens to
# survive. It ERRORS rather than returning NA on a string it cannot read, so
# the two month-first ones - what a US-locale Excel writes - never reached the
# loop at all, and neither did the message below.
EXCEL <- c("30-06-2025", "30/06/2025", "06/30/2025", "2025/06/30", "06-30-2025")
got_x <- vapply(EXCEL, qs, character(1), USE.NAMES = FALSE)
ok(all(got_x == "2025q2"),
   paste0("every layout the recovery lists is recovered (",
          paste(unique(got_x), collapse = " "), ")"))
# No whitespace case: as.Date skips surrounding spaces itself, so an assertion
# on "  2025-06-30  " passes with or without the trimws() it would be testing.
# 03/04/2025 is 3 April day-first and 4 March month-first, and those fall in
# different quarters - a different set of CDM tables for the whole study.
# Nothing in the string says which was meant, so it is refused rather than
# guessed; the unambiguous layouts above still recover.
amb <- qs("03/04/2025")
ok(grepl("ambiguous", amb, fixed = TRUE) && grepl("2025-04-03", amb, fixed = TRUE) &&
     grepl("2025-03-04", amb, fixed = TRUE),
   "an ambiguous date is refused, naming both readings")
lni <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "load_inputs.R"), envir = lni)
ok(inherits(tryCatch(suppressMessages(lni$.normalize_iso_date("03/04/2025", "STUDY_END")),
                     error = function(e) e), "error"),
   "and the config loader refuses it too, before it reaches the settings")
ok(identical(suppressMessages(lni$.normalize_iso_date("30-06-2025", "STUDY_END")),
             "2025-06-30"),
   "...while an unambiguous Excel date still normalizes")
msg <- tryCatch({ qe$get_quarter_suffix("nonsense"); "" }, error = conditionMessage)
ok(grepl("STUDY_END", msg, fixed = TRUE) && grepl("YYYY-MM-DD", msg, fixed = TRUE),
   "a date it cannot parse stops the build, naming the setting and the format")
# The consumer: quarterly on appends the suffix, off reads the plain table.
ok(identical(qe$cdm_src("medical"), "hive_metastore.clnprw_optum.t_medical_2025q2"),
   "cdm_src builds the quarterly name from it")
QCFG$use_quarterly_tables <- FALSE
ok(identical(qe$cdm_src("medical"), "hive_metastore.clnprw_optum.medical"),
   "...and reads the plain table when quarterly tables are off")
QCFG$use_quarterly_tables <- TRUE

cat("\n-- a count reaches SQL as digits --\n")
sc <- get("sql_count", envir = globalenv())
ok(identical(sc(1e5), "100000") && identical(sc(1e6), "1000000") &&
     identical(sc(2^40), "1099511627776"),
   "powers of ten, which as.character() would render 1e+05")
ok(identical(sc(123456), "123456") && identical(sc(100000L), "100000"),
   "and ordinary values and integers are unchanged")
# A count that came back NULL is not a count of zero, and 'NA' in the statement
# would be a column name to Spark.
ok(identical(sc(NA_real_), "NULL") && identical(sc(NULL), "NULL"),
   "a missing count is NULL, not the text NA")

cat("\n-- a DELETE and its INSERT are retried together --\n")
# with_retry wraps the whole call, so what it retries has to be safe to run
# twice. Two db_exec calls are retried separately: if the INSERT reaches the
# warehouse but the answer is lost, the retry inserts a second copy and the
# DELETE that would have cleared it has already run. Driven against a
# connection that fails once, so the re-run is observed rather than assumed.
de <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "db_utils_lot.R"), envir = de)
assign("log_msg", function(...) invisible(NULL), envir = de)
# base_sleep 0, or this test waits five seconds to prove a retry happened.
assign("lot_config", function() list(max_retries = 4L, base_sleep = 0),
       envir = de)
RAN <- character(0); fail_on <- NULL
assign("db_exec_once", function(con, sql) {
  RAN <<- c(RAN, sql)
  if (!is.null(fail_on) && sql == fail_on && sum(RAN == sql) == 1L)
    stop("connection reset by peer")
  invisible(1L)
}, envir = de)

RAN <- character(0); fail_on <- NULL
de$db_replace(NULL, "DEL", "INS")
ok(identical(RAN, c("DEL", "INS")), "a clean call runs each statement once")

RAN <- character(0); fail_on <- "INS"
de$db_replace(NULL, "DEL", "INS")
ok(identical(RAN, c("DEL", "INS", "DEL", "INS")),
   "and a lost answer to the INSERT re-runs the DELETE, so the rows land once")


cat("\n-- LOT will not build on a cohort whose own build did not finish --\n")
# Both cohort builds publish the physical cohort table before they are marked
# complete - they validate it, write attrition and record metadata afterwards.
# So a failed cohort build leaves a readable, well-formed table that passes
# every shape check below it, because those ask whether the table looks right,
# not whether anyone stood behind it.
src <- readLines(file.path(ROOT, "R", "build_lot.R"), warn = FALSE)
ok(any(grepl("check_cohort_build", src, fixed = TRUE)),
   "the cohort's build status is checked, not just the cohort's shape")
bodyf <- function(nm) {
  i <- grep(paste0("^", nm, " <- function"), src)
  if (!length(i)) return(character(0))
  j <- grep("^}", src); src[i[1]:min(j[j > i[1]])]
}
cb <- bodyf("check_cohort_build")
ok(any(grepl('identical\\(f\\$state, "complete"\\)', cb)),
   "...and only 'complete' is accepted")
# A reused prefix can leave two status tables side by side. Taking the first
# readable one lets an earlier cohort's status be recorded as the owner of a
# different cohort, so a row that names another cohort is dropped and an
# undecidable tie stops the run.
ok(any(grepl("final_table_name", cb, fixed = TRUE)),
   "a status row that names its cohort is checked against the input cohort")
ok(any(grepl("names_it, FALSE", cb, fixed = TRUE)),
   "...and one naming a different cohort is not used")
ok(any(grepl("More than one cohort build-status table", cb, fixed = TRUE)),
   "...and two candidates that cannot be told apart stop the run")
ok(any(grepl("LOT_IGNORE_COHORT_STATE", cb, fixed = TRUE)),
   "...with one named override, the way the other run-state guards have one")
# wrk() here does not prefix - only lot_out() does, and only for our own
# outputs. The cohort build's tables carry the cohort build's prefix, so
# looking for a bare "NDMM_BUILD_STATUS" finds nothing on any real run.
ok(any(grepl("paste0(cp, nm)", cb, fixed = TRUE)) &&
     any(grepl("cohort_prefix(cfg)", cb, fixed = TRUE)),
   "...looking for the PREFIXED name, since lot's wrk() adds no prefix")
ok(any(grepl("nzchar(named)", cb, fixed = TRUE)) &&
     sum(grepl("^\\s*stop\\(", cb)) >= 2,
   "a COHORT_STATUS_TABLE that cannot be read stops the run rather than being skipped")
cpf <- bodyf("cohort_prefix")
ok(any(grepl("object_prefix", cpf, fixed = TRUE)),
   "...and the cohort prefix defaults to this run's own")
ok(any(grepl("COHORT_RUN_ID", src, fixed = TRUE)),
   "the cohort run id is recorded, so the lines can be tied to their cohort")
# Before the cohort is pinned or read, not after.
run <- bodyf("build_lot_run")
if (!length(run)) run <- src
ib <- grep("check_cohort_build", run)[1]
ip <- grep("phase_patient_input|materialize_cohort_input", run)[1]
ok(!is.na(ib) && !is.na(ip) && ib < ip,
   "...checked before anything is pinned or built from it")

# check_cohort_build runs before the copy, and the code lists load in between.
# A cohort rebuilt in that gap replaces the physical table, and the snapshot
# check that follows compares only row and patient counts - which a same-size
# rebuild passes. So it is asked again once the snapshot exists.
ok(any(grepl("recheck_cohort_build", src, fixed = TRUE)),
   "the cohort is checked again after it has been copied")
ir <- grep("recheck_cohort_build\\(con, cfg, cohort_status\\)", run)[1]
im <- grep("materialize_cohort_input", run)[1]
ok(!is.na(ir) && !is.na(im) && ir > im,
   "...after the snapshot exists, not before it")
rc <- bodyf("recheck_cohort_build")
ok(any(grepl("before$stamp", rc, fixed = TRUE)) &&
     any(grepl("before$run_id", rc, fixed = TRUE)),
   "...and the same ATTEMPT is required, not just the same run id")
# A cohort re-run keeps its run id and rewrites its rows under it, so the id
# alone does not name an attempt. The status row's timestamp moves every time.
ok(any(grepl("COHORT_STAMP", src, fixed = TRUE)),
   "the attempt's timestamp is recorded beside its run id")

cat("\n-- a run's own metadata rows are cleared, or the run stops --\n")
# A re-run keeps its run id, so rows an earlier attempt left under it would be
# read as this run's. A missing table is the first run and fine; a permission
# or a lock is not, and swallowing it leaves stale metadata looking current.
cr <- bodyf("clear_run_rows")
ok(!any(grepl("try\\(db_exec", cr)),
   "a failed delete is not swallowed by try()")
ok(any(grepl("TABLE_OR_VIEW_NOT_FOUND", cr, fixed = TRUE)),
   "...a table that does not exist yet is still fine")
ok(any(grepl("^\\s*stop\\(", cr)),
   "...and anything else stops the run")
ok(sum(grepl("bad <- c\\(bad", cr)) >= 1 && any(grepl("collapse", cr)),
   "...naming every table it could not clear, not just the first")
# ...and because it stops, the failed-status handler has to be armed BEFORE it.
# It was armed after: a DELETE that raised left the "started" row written with
# no handler registered, so nothing wrote "failed" and check_no_active_run()
# refused every later run on the prefix until someone cleared it by hand. The
# NDMM runner has this assertion (ndmm/tests/test_runner.R) and this one did
# not, which is how the ordering drifted.
bl_body <- sub(".*build_lot <- function\\([^)]*\\) \\{", "",
               paste(readLines(file.path(ROOT, "R", "build_lot.R"), warn = FALSE),
                     collapse = "\n"))
i_bs <- regexpr('write_build_status(con, cfg, "started")', bl_body, fixed = TRUE)
i_oe <- regexpr('"failed"', bl_body, fixed = TRUE)
i_cr <- regexpr("clear_run_rows(con, cfg)", bl_body, fixed = TRUE)
ok(i_bs > 0 && i_oe > 0 && i_cr > 0 && i_bs < i_oe,
   "the failed-status handler is armed after the started row is written")
ok(i_oe < i_cr,
   "...and before clear_run_rows, whose stop would otherwise strand the prefix")

cat("\n-- and the active-run check draws that same line --\n")
# It did not. Every read failure took the "no table yet on a first run" path,
# so a permission failure or a dropped connection turned the concurrency guard
# off for the length of a build - two runs on one prefix replacing each other's
# tables while the other reads them, both finishing. Driven, not grepped: what
# matters is what the function does with what comes back.
ar <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "db_utils_lot.R"), envir = ar)
sys.source(file.path(ROOT, "R", "build_lot.R"), envir = ar)
assign("log_msg", function(...) invisible(NULL), envir = ar)
assign("lot_out", function(x) paste0("wk.p_", x), envir = ar)
assign("run_id", "R2", envir = ar)
drive_ar <- function(x) {
  # Applying the part of the WHERE clause under test, because the warehouse
  # would. A stub that returns the same rows whatever it is asked cannot tell a
  # query that excludes this run's id from one that does not.
  assign("db_q", function(con, s) {
    if (is.character(x)) stop(x)
    if (grepl("RUN_ID <> 'R2'", s, fixed = TRUE))
      x[as.character(x$RUN_ID) != "R2", , drop = FALSE] else x
  }, envir = ar)
  tryCatch({ ar$check_no_active_run(NULL, list(object_prefix = "p_")); NULL },
           error = conditionMessage)
}
ok(is.null(drive_ar(data.frame(RUN_ID = character(0), UPDATED_AT = character(0)))),
   "a prefix nobody else is building is fine")
ok(!is.null(drive_ar(data.frame(RUN_ID = "R1", UPDATED_AT = "x"))),
   "...another run on it stops this one")
# Including one carrying this run's own id. run_id comes from DOMINO_RUN_ID, so
# a second attempt in one Domino execution shares it, and excluding that id
# would walk straight past a live first attempt.
same <- drive_ar(data.frame(RUN_ID = "R2", UPDATED_AT = "x"))
ok(!is.null(same) && grepl("this run's own id", same, fixed = TRUE),
   "...as does a second attempt under this run's own id, saying which it is")
ok(is.null(drive_ar("TABLE_OR_VIEW_NOT_FOUND")),
   "...a first run, with no status table yet, is not blocked by its absence")
for (case in list(list(m = "HTTP 403: permission denied", w = "a refused read"),
                  list(m = "Connection reset by peer",    w = "a dropped connection"))) {
  e <- drive_ar(case$m)
  ok(!is.null(e) && grepl("Could not read", e, fixed = TRUE) &&
       grepl(case$m, e, fixed = TRUE),
     paste0("...while ", case$w, " stops, rather than passing as a first run"))
}
Sys.setenv(LOT_IGNORE_ACTIVE_RUN = "TRUE")
ok(is.null(drive_ar("HTTP 403: permission denied")),
   "...and the override the message names lets an operator past an unreadable one")
Sys.unsetenv("LOT_IGNORE_ACTIVE_RUN")

cat("\n-- face validity: does the output look like myeloma --\n")
# The invariants ask whether the output is internally consistent. These ask
# whether it is clinically plausible - a run can pass every structural check
# with transplants in late lines or a median line lasting three days, and
# nothing else here would notice.
ok(exists("FACE_VALIDITY") && length(FACE_VALIDITY) >= 5,
   paste0("face-validity checks ship (", length(FACE_VALIDITY), ")"))
fvn <- vapply(FACE_VALIDITY, `[[`, character(1), "name")
ok(!anyDuplicated(fvn), "each has its own name, so a row identifies a check")
ok(all(vapply(FACE_VALIDITY, function(f)
        all(c("name","what","lo","hi","sql") %in% names(f)), logical(1))),
   "...and each declares what it measures and the band it expects")
ok(all(vapply(FACE_VALIDITY, function(f) f$lo <= f$hi, logical(1))),
   "no band is inverted")
ok(all(vapply(FACE_VALIDITY, function(f) grepl("{t}", f$sql, fixed = TRUE), logical(1))),
   "every check reads the final table through the placeholder, not a fixed name")
# The study population, not LOT_LONG. A criterion that truncates a patient
# changes who is in the cohort, so plausibility has to be asked of what ships.
fvb <- bodyf("run_face_validity")
ok(any(grepl('lot_out("LOT_LONG_FINAL")', fvb, fixed = TRUE)),
   "asked of LOT_LONG_FINAL - the population that ships, not the pre-criteria one")
# Reported, not fatal. An unusual cohort can legitimately fail one, and
# stopping a build on a plausibility judgement would be wrong.
ok(any(grepl("cfg$face_validity_fatal", fvb, fixed = TRUE)),
   "out-of-band is a warning by default, fatal only when asked for")
ok(all(c("VALUE", "EXPECT_LO", "EXPECT_HI", "VERDICT") %in%
         names(FACE_VALIDITY_COLS)),
   "the band is recorded beside the value, so a reader can judge both")
# The number matters more than the verdict: a wrong band should not hide a
# figure somebody needs to see.
ok(any(grepl("VALUE = \"DOUBLE\"", paste(fvb, collapse = " "), fixed = TRUE)) ||
     "VALUE" %in% names(FACE_VALIDITY_COLS),
   "every check records what it found, whether or not it passed")
# Clinically the direction of each of these is not in question, even if the
# threshold is: transplant early, CAR-T late, allo rare.
ok(all(c("auto_sct_is_early", "cart_is_late", "allo_sct_is_rare") %in% fvn),
   "the three whose clinical direction is uncontroversial are among them")
ok(any(grepl("run_face_validity(con, cfg)", src, fixed = TRUE)),
   "and the build runs them")
ifv <- grep("run_face_validity\\(con, cfg\\)", run)[1]
icf <- grep("check_lot_final\\(con, cfg\\)", run)[1]
ok(!is.na(ifv) && !is.na(icf) && ifv > icf,
   "...after the final table has been checked, so it is asking about real output")

cat("\n-- the LOT funnel, and the two ways it can lie --\n")
# The cohort build's attrition stops at the cohort. Two steps here lose
# patients for reasons that are not a criterion at all - no mapped therapy
# episode, or episodes that never form a line - and without this table that
# loss is only a row-count difference somebody has to notice.
ok(all(c("RUN_ID", "STEP_NUM", "KIND", "STEP", "N_PATIENTS", "N_LINES",
         "PCT_OF_START", "PCT_OF_PREV", "RECORDED_AT") %in% names(LOT_ATTRITION_COLS)),
   "the funnel records patients AND lines per step")

cat("\n-- every table made from a column list is brought up to it --\n")
# CREATE TABLE IF NOT EXISTS does nothing to a table an earlier run left, so a
# column added to a *_COLS list reaches a fresh prefix and no other, and the
# INSERT naming it fails - for LOT_ATTRITION at the very end of the run, after
# the lines are built.
#
# LOT_FACE_VALIDITY and LOT_ATTRITION had no migration at all. So this is
# DERIVED from the file rather than a list written here - a whitelist would
# have passed on both of them, which is how they went uncounted.
made <- unique(regmatches(bl, gregexpr(
  "CREATE TABLE IF NOT EXISTS \\{tbl\\} \\(\",\n\\s*paste\\(cols, [A-Z_]+", bl))[[1]])
made <- sub(".*paste\\(cols, ", "", made)
ok(length(made) >= 4L,
   paste0("every table created from a column list is found (", length(made), ")"))
missing <- Filter(function(sp)
  !grepl(paste0("lot_ensure_cols(con, tbl, ", sp, ")"), bl, fixed = TRUE), made)
ok(!length(missing),
   if (length(missing))
     paste0("created from a column list but never brought up to it: ",
            paste(missing, collapse = ", "))
   else paste0("...and every one is brought up to its list (", length(made), ")"))
# How far patients get - LOT1, then LOT2, and so on. Nobody was removed there:
# a patient with no LOT3 did not progress, or their follow-up ended. Read as
# exclusions those would be the study losing people it never lost.
ok(any(grepl('kind = "progression", step = paste0("Reached LOT", k)', src, fixed = TRUE)),
   "the funnel carries how far patients got, line by line")
ok(any(grepl("seq_len(as.integer(cfg$max_lot))", src, fixed = TRUE)),
   "...every line to max_lot, so a line nobody reached is a zero row and not a missing one")
ok(any(grepl("FROM lot_long_final GROUP BY LOT_NUM", src, fixed = TRUE)),
   "...counted on the population that ships")
# The share of the row above is the number being asked for: for a criterion its
# own cost, for a progression row the proportion going on to the next line.
ok(any(grepl("pct_of(s$n$patients, prev)", src, fixed = TRUE)),
   "...with the share of the previous row, which is what line-to-line attrition means")
# Not every row is attrition. NDMM's index is a treatment qualifier - its step
# 3 is "eligible 1L treatment", and that claim's date becomes INDEX_DATE - so
# every member already has a qualifying claim on the same cl_mma_codelist.csv
# that lot maps. "Has a mapped episode" and "has LOT1" therefore derive a fact
# the cohort already established: they should not move, and a drop is the two
# scans disagreeing rather than patients the study lost.
ok(any(grepl('kind = "reconciliation", step = "With a mapped MM therapy episode"',
             src, fixed = TRUE)) &&
     any(grepl('kind = "reconciliation", step = "With LOT1 built"', src, fixed = TRUE)),
   "...and marks the two derive-it-again rows as reconciliation, not attrition")
ok(any(grepl('kind = "criterion"', src, fixed = TRUE)),
   "...leaving the criterion rows as the only real narrowing")
# Read as attrition, a drop there looks like expected loss - the one reading
# that lets a real discrepancy through.
ok(any(grepl("attrition: it is that scan and this one disagreeing", src, fixed = TRUE)),
   "a drop at a reconciliation row is called out as two scans disagreeing")
# lot runs over cohorts it did not build. One indexed on a diagnosis or an
# enrolment date has no such guarantee, so this warns rather than stops.
ok(any(grepl("report_lot_reconciliation(steps)", src, fixed = TRUE)) &&
     !any(grepl("report_lot_reconciliation <- function(steps) {\n  stop", src, fixed = TRUE)),
   "...as a warning, since a cohort indexed on something else narrows here for real")
# Both, because a truncating criterion drops the first failing line and every
# later one - a patient can survive with fewer lines, and patients alone would
# show nothing. no_belantamab is patient-level so today they move together.
ok(any(grepl("count(DISTINCT PATID) AS p, count(*) AS l", src, fixed = TRUE)),
   "...counted from the same query, so the two can never come from different rows")
ok("LOT_ATTRITION" %in% RUN_SCOPED_TABLES,
   "...and its rows are cleared per run, like every other run-scoped table")
# The criteria rows go through the build's own truncate SQL. A second copy of
# that rule here would be reporting on itself.
ok(any(grepl("line_criteria_final_sql(cfg, \"lot_long_allflags\", v,", src, fixed = TRUE)),
   "the criterion steps reuse the production truncate SQL rather than restating it")
ok(any(grepl("crit = on[seq_len(i)]", src, fixed = TRUE)),
   "...cumulatively, so each row is the population after that criterion and the ones above it")
# A funnel that widens means a fan-out; a last criterion step that disagrees
# with LOT_LONG_FINAL means the criteria counted are not the ones that built it.
# Driven, not grepped. The check is arithmetic over a list, so it can be run
# here in full - a warehouse is only needed to produce the numbers.
mk <- function(..., kinds = NULL) {
  v <- list(...)
  if (is.null(kinds))
    kinds <- c("input", "reconciliation", "reconciliation",
               "criterion", "final")[seq_along(v)]
  lapply(seq_along(v), function(i)
    list(kind = kinds[i], step = paste0("step ", i),
         n = list(patients = v[[i]][1], lines = v[[i]][2])))
}
PROG <- c("input", "reconciliation", "reconciliation", "criterion", "final",
          "progression", "progression", "progression")
runs2 <- function(expr, what) ok(is.null(tryCatch({ expr; NULL },
                                error = conditionMessage)), what)
stops2 <- function(expr, what) ok(!is.null(tryCatch({ expr; NULL },
                                 error = conditionMessage)), what)
runs2(check_lot_attrition(mk(c(100, NA), c(90, NA), c(80, 200), c(70, 150), c(70, 150))),
      "a funnel that only narrows passes")
stops2(check_lot_attrition(mk(c(100, NA), c(110, NA), c(80, 200), c(70, 150), c(70, 150))),
       "a step with more patients than the one above stops the build")
# The line count is NA for the first two steps. The rise is between the third
# and fourth, and the message has to say so rather than name the first pair it
# finds in a vector the NAs have shifted.
msg <- tryCatch(check_lot_attrition(
         mk(c(100, NA), c(90, NA), c(80, 200), c(70, 260), c(70, 260))),
       error = conditionMessage)
ok(!is.null(msg) && grepl("step 4", msg) && grepl("lines", msg),
   "...and a rise in LINES names the step it happened at, not one the NAs shifted it to")
# Both come from the same criteria SQL over the same view, so they cannot
# differ unless the criteria counted are not the ones that built the table.
stops2(check_lot_attrition(mk(c(100, NA), c(90, NA), c(80, 200), c(70, 150), c(60, 140))),
       "a last step that disagrees with LOT_LONG_FINAL stops the build")

# The progression rows sit after the final row, so that comparison has to find
# it rather than take the last entry.
runs2(check_lot_attrition(mk(c(100, NA), c(90, NA), c(80, 200), c(70, 150), c(70, 150),
                             c(70, 70), c(40, 40), c(15, 15), kinds = PROG)),
      "a funnel with progression rows after the final one still passes")
stops2(check_lot_attrition(mk(c(100, NA), c(90, NA), c(80, 200), c(70, 150), c(65, 150),
                              c(65, 65), c(40, 40), c(15, 15), kinds = PROG)),
       "...and the criterion/final comparison still fires with rows after it")
# Every patient in LOT_LONG_FINAL has a LOT1, so the first progression row is
# that same population counted a second way.
stops2(check_lot_attrition(mk(c(100, NA), c(90, NA), c(80, 200), c(70, 150), c(70, 150),
                              c(66, 66), c(40, 40), c(15, 15), kinds = PROG)),
       "a LOT1 count that disagrees with LOT_LONG_FINAL stops the build")
# Nobody reaching LOT5 is an answer, not a gap - a zero row must not trip the
# monotonic check.
runs2(check_lot_attrition(mk(c(100, NA), c(90, NA), c(80, 200), c(70, 150), c(70, 150),
                             c(70, 70), c(0, 0), c(0, 0), kinds = PROG)),
      "...and a line nobody reached is a zero row, not a failure")
iat <- grep("phase_lot_attrition\\(con, cfg\\)", run)[1]
ok(!is.na(iat) && !is.na(icf) && iat > icf,
   "it is written after the final table is validated, not before")
# Declared-but-off criteria are deliberately absent: a row costing nothing
# reads as a harmless criterion rather than as one that never ran.
ok(any(grepl("A funnel is what", src, fixed = TRUE)) &&
     any(grepl("report_line_criteria", src, fixed = TRUE)),
   "criteria that were left off stay out of the funnel and in the run metadata")

cat("\n-- an agent joins a regimen by being filled in the window, not by cover --\n")
# Optum supplies no treatment end date. Cover is FILL_DT plus DAYS_SUP, pushed
# out by overlapping refills, so an episode opened in the previous line can still
# be covered across the whole of this line's induction window. Membership tests
# MAP_START_DT, so that episode does not join: a patient who has switched is no
# longer filling the old agent, and the residual cover is a dispensing artefact.
#
# Pinned because the protocol reads wider - "all MM therapies identified during
# the first 30 days of the LOT" - and the study team settled it this way. Anyone
# widening it to cover has to bring MAP_END_DT into this block, which fails here.
ind_block <- local({
  i <- regexpr('_induction_meds"', l25_txt, fixed = TRUE)
  rest <- substring(l25_txt, i)
  j <- regexpr("\n  materialize\\(|\n  run_step\\(", rest, perl = TRUE)
  substring(rest, 1, if (j > 0) j else nchar(rest))
})
ok(grepl("ms.MAP_START_DT >= ls.LOT{lot_num}_START_DT", ind_block, fixed = TRUE),
   "regimen membership is bounded below by the line's own start date")
ok(grepl("ms.MAP_START_DT <= least(", ind_block, fixed = TRUE) &&
   grepl("date_add(", ind_block, fixed = TRUE),
   "...and above by the induction window, on the same column")
ok(grepl("REGIMEN_CUTOFF_DT", ind_block, fixed = TRUE),
   "...and by the transplant that ended the line, whichever of the two is earlier")
# The other half, and the one that looks unnecessary. Bounding MEMBERSHIP is not
# enough on its own: discon_per_med chains a base agent's own later episodes
# forward from the line's start, so a refill of an agent that legitimately IS in
# the regimen still pushes the run-out past the transplant after membership has
# been corrected. Both call sites pass the cutoff, or the fix is half applied.
pr <- paste(readLines(file.path(ROOT, "R", "prior_regimen.R"), warn = FALSE),
            collapse = "\n")
ok(grepl("AND ms.MAP_START_DT <= coalesce(ls.", pr, fixed = TRUE),
   "the per-drug episode scan takes an upper bound at all")
for (f in c("04_lot1_base.R", "10_lot2_5_base.R")) {
  s <- paste(readLines(file.path(ROOT, "R", "steps", f), warn = FALSE), collapse = "\n")
  ok(grepl("discon_per_med_sql", s, fixed = TRUE) &&
     grepl("end_col = 'REGIMEN_CUTOFF_DT'", s, fixed = TRUE),
     paste0("...and ", f, " passes it, so membership and the run-out are cut on the same date"))
}
ok(!grepl("MAP_END_DT", ind_block, fixed = TRUE),
   "...and never on MAP_END_DT, so stockpiled cover cannot carry an agent in")


cat("\n-- a drug is held by its line while it runs, and released once stopped --\n")
# Two halves of one rule, and each alone is worse than neither. Breaking the
# run-out chain without releasing the drug leaves the returning treatment in no
# line at all; releasing it without breaking the chain opens a line inside a line
# still notionally running. So both are asserted together, and the run-out guards
# that mirror the candidates are asserted with them - a guard reading a different
# rule from the candidate it mirrors lets DEATH take a line whose run-out the
# next line does in fact open on.
ok(grepl("lag(ms.MAP_DISCON_FLG)", pr, fixed = TRUE),
   "the per-drug episode chain reads the discontinuation flag at all")
ok(grepl("sum(i.BREAKS + e.PREV_DISCON)", pr, fixed = TRUE),
   "...and a confirmed gap breaks the chain, so a line cannot span its own agent's absence")
ok(grepl("map_restart_sql <- function", pr, fixed = TRUE),
   "what counts as a restart is defined once")
restart_sites <- sum(vapply(c("04_lot1_base.R", "06_lot1_end.R", "10_lot2_5_base.R"), function(f)
  length(gregexpr("{map_restart_sql()}",
    paste(readLines(file.path(ROOT, "R", "steps", f), warn = FALSE), collapse = "\n"),
    fixed = TRUE)[[1]]), integer(1)))
ok(restart_sites == 5L,
   paste0("...and spliced into all five that ask - the start candidate, the two ",
          "add-medication blocks, and both run-out guards (", restart_sites, ")"))
for (f in c("04_lot1_base.R", "06_lot1_end.R", "10_lot2_5_base.R")) {
  src <- paste(readLines(file.path(ROOT, "R", "steps", f), warn = FALSE), collapse = "\n")
  n <- length(gregexpr("coalesce(mr.PREV_DISCON, 0) = 1", src, fixed = TRUE)[[1]])
  ok(n >= 1L, paste0(f, ": a discontinued drug is released"))
}
# The half that was missing. A restart is kept out of the run-out and may START
# the next line - but while another regimen drug still holds this line open, the
# restart falls inside it. Unless it can END the line too, it is inside a line it
# cannot close and too early to open the next: no line owns the treatment.
for (f in c("04_lot1_base.R", "10_lot2_5_base.R")) {
  src <- paste(readLines(file.path(ROOT, "R", "steps", f), warn = FALSE), collapse = "\n")
  ok(grepl("WHERE (bm.MED_ABBR IS NULL OR coalesce(mr.PREV_DISCON, 0) = 1)",
           src, fixed = TRUE),
     paste0(f, ": a restart can end the line even while another regimen drug runs"))
}
# Provenance. The release is for a drug that WAS the previous regimen, never for
# one excluded only as a permissible substitute - S4.4 says a substitute cannot
# start a line, and an old discontinued episode must not be a way around it.
l25src <- paste(readLines(file.path(ROOT, "R", "steps", "10_lot2_5_base.R"),
                          warn = FALSE), collapse = "\n")
ok(grepl("min(IS_SUB) AS SUBSTITUTE_ONLY", l25src, fixed = TRUE),
   "the exclusion set records WHY each drug is in it")
ok(grepl("AND pme.SUBSTITUTE_ONLY = 0", l25src, fixed = TRUE),
   "...and only an actual previous-regimen drug is releasable, not a substitute")


cat("\n-- a transplant inside a line's window cannot be left outside the line --\n")
# The two halves of one rule, and they only work together. SCT_AUTO_CONT holds
# the line open across its own applicable window; the next line's AUTO gate
# refuses a transplant inside that same window. Set to different widths, a
# transplant falls in the space between them and lands in no line at all - which
# is what a 30-day gate after a 60-day LOT1 did.

# The hold date is bounded by the window. Unbounded, it would drag a line's end
# out to a transplant that belongs to the NEXT line, which is the opposite
# defect and a much louder one.
s05b <- paste(readLines(file.path(ROOT, "R", "steps", "05b_lot1_sct.R"),
                        warn = FALSE), collapse = "\n")
# From the CASE, not from the comment above it - prose naming the window would
# otherwise satisfy a check about the code applying it.
hold <- local({
  e <- regexpr("END AS LOT1_AUTO_HOLD_DT", s05b, fixed = TRUE)
  cs <- gregexpr("CASE", s05b, fixed = TRUE)[[1]]
  b  <- rev(cs[cs > 0 & cs < e])[1]
  if (is.na(b) || e < 0) "" else substr(s05b, b, e)
})
ok(nchar(hold) > 0, "the hold date rule is where it was")
ok(length(gregexpr("cfg$induction_window_days", hold, fixed = TRUE)[[1]]) == 2L,
   "the hold date is bounded by the line's own window, on both the single and tandem arm")
ok(!grepl("OBS_END_DT", hold, fixed = TRUE),
   "...and not by the observation end, which is what LOT1_TX_AUTO_MAX_DT uses")

# The same question at LOT2-5, which is where it was got wrong. The hold date
# there was first taken from LOT{n}_TX_AUTO_MAX_DT, whose tandem arm bounds the
# second transplant by sct_tandem_days from the FIRST one and by nothing else -
# so a partner 180 days after an AUTO on the last day of a 30-day window sat 209
# days past the line start and still counted. Reported and clamped that is
# harmless; deciding an end date it swallows an added medication months later,
# and the line that agent should have started never opens.
holdn <- local({
  e <- regexpr("END AS LOT{lot_num}_AUTO_HOLD_DT", l25_txt, fixed = TRUE)
  cs <- gregexpr("CASE", l25_txt, fixed = TRUE)[[1]]
  b  <- rev(cs[cs > 0 & cs < e])[1]
  if (is.na(b) || e < 0) "" else substr(l25_txt, b, e)
})
ok(nchar(holdn) > 0, "LOT2-5 has a hold date of its own")
ok(length(gregexpr("LOT_WINDOW_DAYS", holdn, fixed = TRUE)[[1]]) == 2L,
   "...bounded by the line's own window on the tandem arm as well as the single one")
ok(length(gregexpr("LOT_WINDOW_DAYS",
                   substr(l25_txt, regexpr("LOTN_TX_AUTO_MAX_DT", l25_txt, fixed = TRUE),
                          regexpr("END AS LOT{lot_num}_TX_AUTO_MAX_DT", l25_txt,
                                  fixed = TRUE))[[1]], fixed = TRUE)[[1]]) == 2L,
   "...and it is a different column from TX_AUTO_MAX_DT, which bounds one arm only")
ok(!grepl("ec.LOT{lot_num}_TX_AUTO_MAX_DT", l25_txt, fixed = TRUE),
   "...so no end-date branch reads the one-armed column by mistake")

# A tandem partner follows its pair past the window. That is only safe because a
# tandem needs a clear gap: anything the extension could swallow breaks the pair
# before the extension is reached. The two halves are checked together, because
# either alone is a defect - the window bound alone loses the partner, and the
# extension alone is the day-209 swallow this suite already pins against.
for (h in list(list(hold, "LOT1", "cfg$induction_window_days"),
               list(holdn, "LOT2-5", "LOT_WINDOW_DAYS"))) {
  ok(grepl(paste0("datediff(ap.AUTO_DT_1, "), h[[1]], fixed = TRUE) &&
     !grepl("datediff(ap.AUTO_DT_2, l", h[[1]], fixed = TRUE),
     paste0(h[[2]], ": the tandem arm bounds the FIRST transplant by the window, ",
            "so the partner may sit beyond it"))
  ok(grepl("n_between", h[[1]], fixed = TRUE),
     paste0("...and only when nothing happened between the two"))
}
# One definition of what breaks a tandem, spliced everywhere it is asked. Five
# copies is how the five drift apart, and a tandem test that disagrees with the
# start gate it mirrors puts a transplant in no line at all.
ok(grepl("tandem_interrupt_events_sql <- function", pr, fixed = TRUE),
   "what breaks a tandem is defined once")
sites <- sum(vapply(c("05b_lot1_sct.R", "06_lot1_end.R", "10_lot2_5_base.R"),
  function(f) length(gregexpr("{tandem_interrupt_events_sql()}",
    paste(readLines(file.path(ROOT, "R", "steps", f), warn = FALSE), collapse = "\n"),
    fixed = TRUE)[[1]]), integer(1)))
ok(sites == 5L,
   paste0("...and spliced into all five places that ask - two tandem flags, the ",
          "start gate, and its two run-out mirrors (", sites, ")"))

# One gate, stated three times - reason, date, length. If they drift, a line
# reports one reason and the date of another.
gates <- regmatches(e6, gregexpr(
  "(?s)WHEN ec\\.LOT1_AUTO_HOLD_DT IS NOT NULL.*?THEN", e6, perl = TRUE))[[1]]
gates <- sub("\\s*THEN$", "", gates)
ok(length(gates) == 3L,
   "the SCT_AUTO_CONT gate is asked in all three cascades - reason, date and length")
ok(length(unique(trimws(gsub("\\s+", " ", gates)))) == 1L,
   "...and it is the same gate in each, so they cannot take different branches")
ok(grepl("THEN ec.LOT1_AUTO_HOLD_DT", e6, fixed = TRUE) &&
   !grepl("date_sub(ec.LOT1_AUTO_HOLD_DT", e6, fixed = TRUE),
   "the line ends ON the transplant, not the day before it as the other AUTO reasons do")

# Spark to R, whole-word swaps only, so what runs below is the shipped gate.
# The guard afterwards is what makes that claim checkable: any SQL keyword left
# behind means a clause was dropped rather than translated, and a dropped clause
# is exactly how a gate silently widens.
gate_r <- gsub("\\s+", " ", gates[1])
gate_r <- gsub("ec\\.", "", gate_r)
gate_r <- gsub("\\b([A-Z_0-9]+) IS NOT NULL", "!is.na(\\1)", gate_r)
gate_r <- gsub("\\b([A-Z_0-9]+) IS NULL", "is.na(\\1)", gate_r)
gate_r <- gsub("\\bAND\\b", "&&", gate_r)
gate_r <- gsub("\\bOR\\b", "||", gate_r)
gate_r <- trimws(sub("^\\s*WHEN\\b", "", gate_r))
ok(!grepl("\\b(WHEN|THEN|IS|NULL|AND|OR)\\b", gsub("is\\.na", "", gate_r)),
   "the gate translates whole - nothing was left behind as unread SQL")

fires <- function(hold, natural, death = NA) {
  eval(parse(text = gate_r),
       list(LOT1_AUTO_HOLD_DT = hold, LOT1_NATURAL_END_DT = natural,
            DEATH_DT = death))
}
d <- function(n) as.Date("2020-01-01") + n
# LEN with 20 days supply, run-out d19, transplant d40. The line used to be
# finalised at d19 and the transplant refused by LOT2 for sitting inside LOT1's
# window, so it appeared nowhere.
ok(isTRUE(fires(d(40), d(19))),
   "a transplant after an early run-out extends the line rather than vanishing")
ok(isFALSE(fires(d(20), d(59))),
   "...but a line that already covers its transplant is left alone")
# NOT an added-medication override, which is unreachable and was wrong to claim.
# At LOT1 an agent starting inside the 60-day window joins the regimen instead of
# being an addition, so MED_ADD needs a start at day 60 or later, which is at or
# after the furthest a hold date can reach; the same arithmetic holds on a 30-day
# and a 45-day line. A tandem partner CAN reach past the window, but a medication
# between the two transplants breaks the tandem before it gets there. So the
# branch below is about a later natural end of any kind, and d+29 is simply one.
ok(isTRUE(fires(d(40), d(29))),
   "...and about the natural end's date, not about which branch produced it")
ok(isFALSE(fires(d(40), d(19), death = d(30))),
   "a death before the transplant still ends the line - a line may not outlive the patient")
ok(isFALSE(fires(NA, d(19))),
   "and a line with no in-window transplant is untouched")

# The other half. auto_cand measures the window of the line it is looking BACK
# at, so at LOT2 that is LOT1's 60 and not LOT2-5's own 30.
ac <- local({
  b <- regexpr("auto_cand AS", l25_txt, fixed = TRUE)
  rest <- substring(l25_txt, b)
  e <- regexpr("GROUP BY pe.PATID", rest, fixed = TRUE)
  substr(rest, 1, if (e > 0) e else nchar(rest))
})
ok(nchar(ac) > 0 && grepl("PREV_START_TYPE", ac, fixed = TRUE),
   "the next-line AUTO candidate block is where it was")
ok(grepl("ELSE                 {prev_med_window} - 1", ac, fixed = TRUE),
   "the next-line AUTO gate reads the previous line's own window, not this line's")
ok(!grepl("{induction_window_days} - 1", ac, fixed = TRUE),
   "...so it no longer applies the LOT2-5 window to a LOT1 predecessor")
ok(grepl("prev_med_window <- if (lot_num == 2L) lot1_induction_window_days",
         l25_txt, fixed = TRUE),
   "...and that window is LOT1's exactly when the previous line is LOT1")
# The run-out guard mirrors auto_cand; disagreeing lets DEATH take a line whose
# run-out the next line does in fact open on.
pra <- substr(e6, regexpr("post_runout_auto AS", e6, fixed = TRUE),
              regexpr("post_runout_sct AS", e6, fixed = TRUE))
# Code only. The comment beside it names the setting this used to borrow, and a
# check that reads prose would pass on the explanation rather than the rule.
pra_code <- paste(grep("^\\s*--", strsplit(pra, "\n")[[1]], value = TRUE, invert = TRUE),
                  collapse = "\n")
ok(grepl("{cfg$induction_window_days} - 1", pra_code, fixed = TRUE) &&
   !grepl("lot_n_induction_window_days", pra_code, fixed = TRUE),
   "the run-out guard reads the same window auto_cand does, so the two agree")

report()
