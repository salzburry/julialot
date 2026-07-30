#!/usr/bin/env Rscript
# =============================================================================
# Build the NDMM cohort base.
#
#   DATABRICKS_PWD=... Rscript "Jul 28/ndmm/build.R"
#
# Self-contained: R/ holds this cohort's helpers and IE steps, config.csv its
# switches. It reads the CDM directly and writes NDMM_COH_FINAL to
# <catalog>.<schema>, along with every intermediate step as a real table.
# Nothing here depends on another cohort.
#
# This is the index-anchored half only. NDMM's own criteria are anchored on the
# LOT1 start date, so they run after the LOT build:
#
#   ndmm/build.R      ->  NDMM_COH_FINAL
#   ../lot/02_lot1.R  ->  LOT1_STARTS, LOT_LONG  (INPUT_COHORT_TABLE=NDMM_COH_FINAL)
#   ndmm/ndmm_flags.R ->  the NDMM cohort            (not written yet)
# =============================================================================
here <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (!length(a)) getwd()
  else dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]), fixed = TRUE)))
})
library(DBI); library(odbc); library(glue)
source(file.path(here, "R", "build_cohort.R"))
load_cohort_modules(here)
if (!interactive()) build_cohort(here, expect_table = "NDMM_COH_FINAL")
