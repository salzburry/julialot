#!/usr/bin/env Rscript
# The wrapper around the IE SQL - what gets written, and where.
# test_same_as_source.R covers the SQL itself. Runs offline.
#
#   Rscript "Jul 28/overall/tests/test_runner.R"

here <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (!length(a)) getwd()
  else dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]), fixed = TRUE)))
})
ROOT <- dirname(here)

pass <- 0L; fail <- 0L
ok <- function(cond, what) {
  if (isTRUE(cond)) { pass <<- pass + 1L; cat("  ok   ", what, "\n") }
  else              { fail <<- fail + 1L; cat("  FAIL ", what, "\n") }
}
stops <- function(expr, what) {
  ok(inherits(tryCatch(expr, error = function(e) e), "error"), what)
}
runs <- function(expr, what) {
  ok(!inherits(tryCatch(expr, error = function(e) e), "error"), what)
}

env <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "build_cohort.R"), envir = env)
CHECKPOINT_STEPS <- c("mm_dx_events_all", "mm_qualifying", "ELIG_COH_ALLFLAGS")
assign("CHECKPOINT_STEPS", CHECKPOINT_STEPS, envir = env)
for (f in c("step_view_name", "is_checkpoint", "check_output_contract",
            "check_settings", "resolve_checkpoints", "pin_output_schema"))
  assign(f, get(f, envir = env), envir = globalenv())

restore <- Sys.getenv(c("CHECKPOINT_STEPS", "OBJECT_PREFIX", "PROJECT_WORK_SCHEMA",
                        "DOMINO_USER_NAME", "APPLY_AGE_INCL", "OUTPATIENT_WINDOW",
                        "MIN_AGE", "STUDY_END"), unset = NA)
on.exit({
  for (n in names(restore)) {
    if (is.na(restore[[n]])) Sys.unsetenv(n)
    else do.call(Sys.setenv, setNames(list(restore[[n]]), n))
  }
}, add = TRUE)
clear <- function() Sys.unsetenv(names(restore))

cat("\n-- step_view_name: the view a step creates --\n")
ok(identical(step_view_name("CREATE OR REPLACE TEMPORARY VIEW ce_flags AS SELECT 1"),
             "ce_flags"), "reads the view name out of the SQL")
ok(identical(step_view_name("  CREATE OR REPLACE TEMPORARY VIEW  rvnu_cd_check  AS x"),
             "rvnu_cd_check"), "tolerates leading and repeated spaces")
ok(is.na(step_view_name("CREATE OR REPLACE TABLE x.y.z AS SELECT 1")),
   "NA when the step writes a table, not a view")

cat("\n-- is_checkpoint: what gets materialized --\n")
cfg <- list(final_table_name = "OVERALL_COH_FINAL")
ok(is_checkpoint("mm_qualifying", "*", cfg), "'*' materializes an ordinary step")
ok(!is_checkpoint("OVERALL_COH_FINAL", "*", cfg),
   "never the final cohort view (24b writes that table)")
ok(!is_checkpoint(NA_character_, "*", cfg), "never a step that writes a table")
ok(is_checkpoint("mm_qualifying", c("mm_qualifying", "ce_flags"), cfg),
   "an explicit list still works")
ok(!is_checkpoint("ce_flags", c("mm_qualifying"), cfg),
   "a step outside an explicit list is skipped")

cat("\n-- resolve_checkpoints --\n")
clear()
ok(identical(resolve_checkpoints(), CHECKPOINT_STEPS), "unset falls back to the default three")
Sys.setenv(CHECKPOINT_STEPS = "*")
ok(identical(resolve_checkpoints(), "*"), "'*' passes through")
Sys.setenv(CHECKPOINT_STEPS = "a|b , c")
ok(identical(resolve_checkpoints(), c("a", "b", "c")), "splits and trims a list")

cat("\n-- check_output_contract --\n")
Sys.setenv(CHECKPOINT_STEPS = "*")
good <- list(final_table_name = "OVERALL_COH_FINAL", object_prefix = "overall_",
             persist_to_schema = TRUE)
runs(check_output_contract(good, "OVERALL_COH_FINAL", "overall_"), "accepts the declared contract")
stops(check_output_contract(modifyList(good, list(final_table_name = "ELIG_COH_FINAL")),
                            "OVERALL_COH_FINAL", "overall_"),
      "rejects an ambient FINAL_TABLE_NAME")
stops(check_output_contract(modifyList(good, list(object_prefix = "ndmm_")),
                            "OVERALL_COH_FINAL", "overall_"),
      "rejects a prefix that would overwrite the other cohort")
stops(check_output_contract(modifyList(good, list(persist_to_schema = FALSE)),
                            "OVERALL_COH_FINAL", "overall_"),
      "rejects PERSIST_TO_SCHEMA=FALSE")
Sys.setenv(CHECKPOINT_STEPS = "mm_dx_events_all")
stops(check_output_contract(good, "OVERALL_COH_FINAL", "overall_"),
      "rejects a narrowed CHECKPOINT_STEPS")

cat("\n-- check_settings: the ones that used to fail open --\n")
clear()
runs(check_settings(), "unset is fine")
Sys.setenv(APPLY_AGE_INCL = "Y")
stops(check_settings(), "APPLY_AGE_INCL=Y (as.logical gives NA, read as off)")
Sys.setenv(APPLY_AGE_INCL = "false")
runs(check_settings(), "lowercase true/false accepted")
clear()
Sys.setenv(OUTPATIENT_WINDOW = "45")
stops(check_settings(), "OUTPATIENT_WINDOW=45 (silently became 90)")
clear()
Sys.setenv(MIN_AGE = "eighteen")
stops(check_settings(), "MIN_AGE that isn't a number")
clear()
Sys.setenv(STUDY_END = "30-06-2025")
stops(check_settings(), "a date that isn't YYYY-MM-DD")
clear()
Sys.setenv(PROJECT_WORK_SCHEMA = "hive_metastore.osk02156")
stops(check_settings(), "catalog.schema where a schema name belongs")

cat("\n-- pin_output_schema --\n")
clear()
Sys.setenv(DOMINO_USER_NAME = "osk02156", OBJECT_PREFIX = "overall_")
p <- pin_output_schema(list(catalog = "hive_metastore"))
ok(identical(p$work_schema, "osk02156") && identical(p$personal_schema, "osk02156"),
   "work and personal schema pinned to the same value")
ok(identical(p$object_prefix, "overall_"), "prefix carried onto cfg")
clear()
stops(pin_output_schema(list(catalog = "hive_metastore")),
      "stops when no schema resolves")

cat("\n-- every windowed CDM read is bounded (stage_cdm.R relies on it) --\n")
# stage_cdm.R copies medical / med_diagnosis / med_procedure / rx filtered to
# the study window. That is only a superset because every step bounds itself
# the same way. A new step reading outside the window would silently see fewer
# rows from the copy than from the CDM.
WINDOWED <- c("tbl_medical", "tbl_med_diag", "tbl_med_proc", "tbl_rx")
PROBES   <- "06c_validate_rvnu_cd"   # column probe, LIMIT 1, needs no rows
for (f in list.files(file.path(ROOT, "R", "steps"), full.names = TRUE)) {
  src <- paste(readLines(f, warn = FALSE), collapse = "\n")
  starts <- gregexpr('name = "([^"]+)"', src)[[1]]
  if (starts[1] == -1L) next
  names_found <- regmatches(src, gregexpr('name = "([^"]+)"', src))[[1]]
  ends <- c(starts[-1] - 1L, nchar(src))
  for (i in seq_along(starts)) {
    step <- gsub('^name = "|"$', "", names_found[i])
    block <- substr(src, starts[i], ends[i])
    reads <- vapply(WINDOWED, function(t) grepl(paste0("cdm_src(cfg$", t, ")"),
                                                block, fixed = TRUE), logical(1))
    if (!any(reads) || step %in% PROBES) next
    ok(grepl("BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')",
             block, fixed = TRUE),
       paste0(step, ": bounded by the study window"))
  }
}

cat("\n-- every function build_cohort.R calls actually exists --\n")
# A missed edit once left write_build_status() and check_normalized_codelist()
# called but never defined. Nothing caught it: the SQL tests don't run the
# runner, and R only resolves a function when the call is reached.
mod <- new.env(parent = globalenv())
for (f in c("load_inputs.R", "config_prompts.R", "db_utils.R", "codelists.R",
            "criteria_attrition.R", "pipeline_steps.R", "build_cohort.R"))
  sys.source(file.path(ROOT, "R", f), envir = mod)

src <- paste(readLines(file.path(ROOT, "R", "build_cohort.R"), warn = FALSE),
             collapse = "\n")
src <- gsub('"[^"]*"', '""', src)          # string literals hold SQL, not calls
src <- gsub("'[^']*'", "''", src)
src <- gsub("#[^\n]*", "", src)           # comments
# skip pkg::fn and list$fn - only bare names have to resolve here
called <- unique(sub("\\($", "", regmatches(src,
  gregexpr("(?<![$:\\w.])[A-Za-z_][A-Za-z0-9_.]*\\(", src, perl = TRUE))[[1]]))
missing <- Filter(function(f) !exists(f, envir = mod), called)
ok(length(missing) == 0,
   if (length(missing)) paste("undefined:", paste(missing, collapse = ", "))
   else paste0("all ", length(called), " calls resolve"))

cat("\n", strrep("-", 52), "\n", sep = "")
cat(sprintf("%d passed, %d failed\n", pass, fail))
if (fail > 0L) quit(status = 1L)
