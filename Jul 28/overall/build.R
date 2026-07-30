#!/usr/bin/env Rscript
# Build the Overall cohort. Writes OVERALL_COH_FINAL.
#
#   DATABRICKS_PWD=... Rscript "Jul 28/overall/build.R"
#
# R/ holds the helpers and IE steps, config.csv everything else.

here <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (!length(a)) getwd()
  else dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]), fixed = TRUE)))
})
library(DBI); library(odbc); library(glue)
source(file.path(here, "R", "build_cohort.R"))
load_cohort_modules(here)
if (!interactive()) build_cohort(here, expect_table = "OVERALL_COH_FINAL", expect_prefix = "overall_")
