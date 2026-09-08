#!/usr/bin/env Rscript
# Study 223926 - the analytical cohort and its variables, from a finished LOT
# run.
#
#   Rscript build.R                          on a Databricks cluster
#   INPUT_COHORT_TABLE=ndmm_NDMM_COHORT OBJECT_PREFIX=s223926_ Rscript build.R
#
# SPARK_METHOD=databricks_connect drives a named cluster from outside and is
# the only mode that needs DATABRICKS_HOST, DATABRICKS_TOKEN and
# SPARK_CLUSTER_ID.
#
# Everything is a setting; config.csv lists them all with what each one does,
# and the environment beats the file. Three worth knowing before the first run:
#
#   MODULES=spine,cohorts,periods,demographics,tte   the parts that need no
#                                                    code list this repo lacks
#   COHORTS=1L,2L,3L,SEC2L                           which cohorts to build
#   DRY_RUN=TRUE                                     print the plan and stop
#
# This package reads the LOT tables and the cohort table and writes only its
# own S_* tables, so it can be re-run against a finished run as often as
# needed.

here <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (!length(a)) getwd()
  else dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                  fixed = TRUE)))
})

# sparklyr for the session. No DBI/odbc: on a Databricks cluster the Spark
# session already exists and sparklyr attaches to it, so there is no DSN and no
# password to hold.
#
# Loaded lazily rather than with library(), so DRY_RUN=TRUE resolves and prints
# a plan on a machine that has no Spark - which is where a plan is usually read.
if (!requireNamespace("sparklyr", quietly = TRUE) &&
    !identical(toupper(Sys.getenv("DRY_RUN", unset = "FALSE")), "TRUE"))
  stop("sparklyr is not installed. DRY_RUN=TRUE prints the plan without it.",
       call. = FALSE)
source(file.path(here, "R", "load_inputs.R"))
load_pipeline_inputs(here, "config.csv")
for (f in c("config_223926.R", "db_utils_223926.R", "registry.R", "windows.R",
            "person_time.R", "codelists.R", "lineage.R",
            "run_223926.R"))
  source(file.path(here, "R", f))

if (!interactive()) build_223926(here)
