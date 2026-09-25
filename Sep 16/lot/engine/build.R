#!/usr/bin/env Rscript
# Build LOT for one cohort.
#
#   DATABRICKS_PWD=... Rscript build.R <COHORT_TABLE> <prefix_>
#   DATABRICKS_PWD=... Rscript build.R MY_COH_FINAL mystudy_
#
# The study window comes from config.csv. To build the same algorithm against a
# cohort with a different one, pass it instead of editing anything:
#
#   Rscript build.R MY_COH_FINAL mystudy_ 2018-01-01 2026-03-31
#
# Or set INPUT_COHORT_TABLE, OBJECT_PREFIX, STUDY_START and STUDY_END instead of
# passing them.
#
# The cohort table is read as named; every LOT output gets the prefix, so two
# cohorts can be built into one schema without overwriting each other. This
# folder holds no cohort names of its own, and no study's dates.
#
# The window has to be the one the cohort was built to. LOT bounds every claim
# scan by the cohort's own INDEX_DATE and OBS_END_DT, and study_end selects the
# quarterly CDM tables - so a cohort observed past it finds no claims there and
# the run would finish with lines that end early. check_cohort_window() stops
# instead.

here <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (!length(a)) getwd()
  else dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]), fixed = TRUE)))
})
argv         <- commandArgs(trailingOnly = TRUE)
cohort_table <- if (length(argv) >= 1) argv[1] else Sys.getenv("INPUT_COHORT_TABLE", unset = "")
prefix       <- if (length(argv) >= 2) argv[2] else Sys.getenv("OBJECT_PREFIX", unset = "")
# NULL rather than "", so pin_study_window() falls back to the configured
# window instead of treating an absent argument as an empty one.
study_start  <- if (length(argv) >= 3) argv[3] else NULL
study_end    <- if (length(argv) >= 4) argv[4] else NULL

library(DBI); library(odbc); library(glue)
source(file.path(here, "R", "build_lot.R"))
# The modules first. They define the logger - start_run_log() and run_logged()
# live in R/db_utils_lot.R, which the loader sources - and they read config.csv, which
# can say where the log goes. Started before them, the log was a call to a
# function not yet defined, and every run stopped on it.
#
# From then on the run goes into its log as well as onto the console - the QC
# tables it prints, its warnings, and the reason it stopped, if it does. The
# error line R prints itself goes to stderr, which the tee does not carry, so
# run_logged() writes the reason into the file as the error is raised.
load_lot_modules(here)
if (!interactive()) {
  start_run_log()
  run_logged(build_lot(here, cohort_table, prefix, study_start, study_end))
}
