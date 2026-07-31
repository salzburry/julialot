#!/usr/bin/env Rscript
# Build the NDMM (1L newly-diagnosed) cohort for one cohort prefix.
#
#   DATABRICKS_PWD=... Rscript build.R <prefix_>
#   DATABRICKS_PWD=... Rscript build.R mystudy_
#
# Or set OBJECT_PREFIX instead of passing it.
#
# Reads that prefix's LOT_LONG, MAP_STACKED and ELIG_COH_FINAL, so the LOT and
# cohort builds have to have run first. Writes <prefix>NDMM_COHORT and
# <prefix>NDMM_ATTRITION. This folder holds no cohort names of its own.

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
if (!interactive()) build_nndm(here, prefix)
