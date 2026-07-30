#!/usr/bin/env Rscript
# =============================================================================
# ndmm/build.R -- build the NDMM cohort base
# -----------------------------------------------------------------------------
#   DATABRICKS_PWD=... Rscript "Jul 28/ndmm/build.R"
#
# Runs the shared steps in ../R/steps with the switches in config.csv.
# Writes NDMM_COH_FINAL. It does not read the Overall cohort.
#
# This is only the index-anchored half. NDMM's own criteria are anchored on the
# LOT1 start date, so they can only run after the LOT build:
#
#   ndmm/build.R       ->  NDMM_COH_FINAL
#   ../lot/02_lot1.R   ->  LOT1_STARTS, LOT_LONG  (INPUT_COHORT_TABLE=NDMM_COH_FINAL)
#   ndmm/ndmm_flags.R  ->  the NDMM cohort
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
if (!interactive()) build_cohort(here, root, expect_table = "NDMM_COH_FINAL")
