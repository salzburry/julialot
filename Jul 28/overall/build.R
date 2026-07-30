#!/usr/bin/env Rscript
# =============================================================================
# overall/build.R -- build the Overall cohort
# -----------------------------------------------------------------------------
#   DATABRICKS_PWD=... Rscript "Jul 28/overall/build.R"
#
# Runs the shared steps in ../R/steps with the switches in config.csv.
# Writes OVERALL_COH_FINAL. Does not read or need any other cohort.
# =============================================================================
here <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (!length(a)) getwd()
  else dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]), fixed = TRUE)))
})
root <- dirname(here)
library(DBI); library(odbc); library(glue)
source(file.path(root, "R", "build_cohort.R"))
load_cohort_modules(root, here)
if (!interactive()) build_cohort(here, root)
