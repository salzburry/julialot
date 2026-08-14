#!/usr/bin/env Rscript
# Treatment patterns and treatment-related outcomes for one finished LOT run.
#
#   DATABRICKS_PWD=... Rscript build.R <COHORT_TABLE> <lot_prefix_>
#   DATABRICKS_PWD=... Rscript build.R ndmm_NDMM_COHORT ndmm_
#
# Or set INPUT_COHORT_TABLE and OBJECT_PREFIX instead of passing them.
#
# Reads only. It writes five tables of its own and touches no cohort and no
# LOT table, so it can be re-run against a finished run as often as needed.

here <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (!length(a)) getwd()
  else dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]), fixed = TRUE)))
})
argv   <- commandArgs(trailingOnly = TRUE)
cohort <- if (length(argv) >= 1) argv[1] else Sys.getenv("INPUT_COHORT_TABLE", unset = "")
prefix <- if (length(argv) >= 2) argv[2] else Sys.getenv("OBJECT_PREFIX", unset = "")

library(DBI); library(odbc); library(glue)
source(file.path(here, "R", "load_inputs.R"))
load_pipeline_inputs(here, "config.csv")
for (f in c("config_out.R", "db_utils_out.R", "build_outcomes.R", "run_outcomes.R"))
  source(file.path(here, "R", f))
if (!interactive()) build_outcomes(here, cohort, prefix)
