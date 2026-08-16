#!/usr/bin/env Rscript
# Build the dashboard for one cohort, after the cohort build and the LOT build.
#
#   DATABRICKS_PWD=... Rscript build.R <COHORT_TABLE> <lot_prefix_> [<cohort_prefix_>]
#   DATABRICKS_PWD=... Rscript build.R NDMM_COHORT ndmm_
#
# Or set INPUT_COHORT_TABLE, LOT_PREFIX and COHORT_PREFIX instead of passing
# them. The cohort prefix defaults to the LOT prefix - one study, one prefix -
# and is only needed when the cohort build wrote under a different one.
#
# Reading only. This writes no warehouse table, so it can be re-run against a
# finished study whenever the numbers are wanted again.
#
# What it shows is R/sections.R, and each section has a SHOW_<NAME> switch in
# config.csv.

here <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (!length(a)) getwd()
  else dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]), fixed = TRUE)))
})
argv          <- commandArgs(trailingOnly = TRUE)
cohort_table  <- if (length(argv) >= 1) argv[1] else Sys.getenv("INPUT_COHORT_TABLE", unset = "")
lot_prefix    <- if (length(argv) >= 2) argv[2] else Sys.getenv("LOT_PREFIX", unset = "")
cohort_prefix <- if (length(argv) >= 3) argv[3] else NULL

library(DBI); library(odbc)
source(file.path(here, "R", "build_dashboard.R"))
load_dash_modules(here)
if (!interactive())
  build_dashboard_run(here, cohort_table, lot_prefix, cohort_prefix)
