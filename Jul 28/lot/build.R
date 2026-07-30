#!/usr/bin/env Rscript
# Build LOT for one cohort.
#
#   DATABRICKS_PWD=... Rscript build.R <COHORT_TABLE> <prefix_>
#   DATABRICKS_PWD=... Rscript build.R MY_COH_FINAL mystudy_
#
# Or set INPUT_COHORT_TABLE and OBJECT_PREFIX instead of passing them.
#
# The cohort table is read as named; every LOT output gets the prefix, so two
# cohorts can be built into one schema without overwriting each other. This
# folder holds no cohort names of its own.

here <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (!length(a)) getwd()
  else dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]), fixed = TRUE)))
})
argv         <- commandArgs(trailingOnly = TRUE)
cohort_table <- if (length(argv) >= 1) argv[1] else Sys.getenv("INPUT_COHORT_TABLE", unset = "")
prefix       <- if (length(argv) >= 2) argv[2] else Sys.getenv("OBJECT_PREFIX", unset = "")

library(DBI); library(odbc); library(glue)
source(file.path(here, "R", "build_lot.R"))
load_lot_modules(here)
if (!interactive()) build_lot(here, cohort_table, prefix)
