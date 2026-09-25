#!/usr/bin/env Rscript
# Build the NDMM (1L newly-diagnosed) cohort for one cohort prefix.
#
#   DATABRICKS_PWD=... Rscript build.R <prefix_>
#   DATABRICKS_PWD=... Rscript build.R mystudy_
#
# Or set OBJECT_PREFIX instead of passing it.
#
# Standalone: reads the raw Optum CDM and the production code lists, and no
# table another build makes. Writes <prefix>NDMM_COHORT - which is a cohort
# the lot build can then be pointed at - and <prefix>NDMM_ATTRITION. This folder
# holds no cohort names of its own.

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
if (!interactive()) {
  start_run_log()
  run_logged(build_ndmm(here, prefix))
}
