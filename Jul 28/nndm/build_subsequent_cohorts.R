#!/usr/bin/env Rscript
# The 2L and 3L cohorts, per protocol 6.2.1.1 "Additional eligibility for 2L
# and 3L RRMM Cohorts".
#
#   DATABRICKS_PWD=... Rscript nndm/build_subsequent_cohorts.R <prefix_>
#
# Run this AFTER the LOT build over the same prefix: the 2L and 3L index dates
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
source(file.path(here, "R", "build_nndm.R"))
load_nndm_modules(here)
source(file.path(here, "R", "build_subsequent.R"))
if (!interactive()) build_subsequent(here, prefix)
