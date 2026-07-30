#!/usr/bin/env Rscript
# Build LOT for one cohort.
#
#   DATABRICKS_PWD=... Rscript "Jul 28/lot/build.R" overall
#
# The rules are the same for every cohort. R/build_lot.R's COHORTS list says
# which cohort table to read and what to call that cohort's outputs.

here <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (!length(a)) getwd()
  else dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]), fixed = TRUE)))
})
cohort <- local({
  a <- commandArgs(trailingOnly = TRUE)
  if (length(a)) trimws(a[1]) else Sys.getenv("LOT_COHORT", unset = "")
})
library(DBI); library(odbc); library(glue)
source(file.path(here, "R", "build_lot.R"))
load_lot_modules(here)
if (!interactive()) build_lot(here, cohort)
