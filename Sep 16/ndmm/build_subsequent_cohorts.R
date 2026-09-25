#!/usr/bin/env Rscript
# The 2L and 3L cohorts, with their own extra eligibility rules.
#
#   DATABRICKS_PWD=... Rscript ndmm/build_subsequent_cohorts.R <prefix_>
#
# Run this after the LOT build over the same prefix: the 2L and 3L index dates
# are line starts, and only lot knows them.
#
# Writes <prefix>NDMM_COHORT_2L, <prefix>NDMM_COHORT_3L and
# <prefix>NDMM_SUBSEQUENT_ATTRITION. Changes nothing else.
#
# The rules are in R/build_subsequent.R.

here <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (!length(a)) getwd()
  else dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]), fixed = TRUE)))
})
argv   <- commandArgs(trailingOnly = TRUE)
prefix <- if (length(argv) >= 1) argv[1] else Sys.getenv("OBJECT_PREFIX", unset = "")

library(DBI); library(odbc); library(glue)
source(file.path(here, "R", "build_ndmm.R"))
# The modules first. They define the logger - start_run_log() and run_logged()
# live in R/db_utils.R, which the loader sources - and they read config.csv, which
# can say where the log goes. Started before them, the log was a call to a
# function not yet defined, and every run stopped on it.
#
# From then on the run goes into its log as well as onto the console - the QC
# tables it prints, its warnings, and the reason it stopped, if it does. The
# error line R prints itself goes to stderr, which the tee does not carry, so
# run_logged() writes the reason into the file as the error is raised.
load_ndmm_modules(here)
source(file.path(here, "R", "build_subsequent.R"))
if (!interactive()) {
  start_run_log()
  run_logged(build_subsequent(here, prefix))
}
