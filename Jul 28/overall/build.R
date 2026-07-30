#!/usr/bin/env Rscript
# =============================================================================
# Build the Overall cohort.
#
#   DATABRICKS_PWD=... Rscript "Jul 28/overall/build.R"
#
# R/ holds this cohort's helpers and IE steps, config.csv its switches. Shared
# defaults still come from ../pipeline_inputs.csv; the build stops if neither
# that nor a local copy is found. It reads the CDM directly and writes OVERALL_COH_FINAL to
# <catalog>.<schema>, along with every intermediate step as a real table.
# Nothing here depends on another cohort.
# =============================================================================
here <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (!length(a)) getwd()
  else dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]), fixed = TRUE)))
})
library(DBI); library(odbc); library(glue)
source(file.path(here, "R", "build_cohort.R"))
load_cohort_modules(here)
if (!interactive()) build_cohort(here, expect_table = "OVERALL_COH_FINAL", expect_prefix = "overall_")
