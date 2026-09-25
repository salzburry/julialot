#!/usr/bin/env Rscript
# Study 223926 - the analytical cohort and its variables, from a finished LOT
# run.
#
#   DATABRICKS_PWD=... INPUT_COHORT_TABLE=ndmm_NDMM_COHORT OBJECT_PREFIX=s223926_ Rscript build.R
#
# The connection is the Databricks ODBC driver through DBI, on the DSN in
# DATABRICKS_DSN (default RWDE) with the password in DATABRICKS_PWD - the same
# environment the cohort and LOT builds connect with. SPARK_METHOD=databricks
# attaches to the Spark session of the cluster the script runs on instead,
# and SPARK_METHOD=databricks_connect drives a named cluster from outside and
# is the only mode that needs DATABRICKS_HOST, DATABRICKS_TOKEN and
# SPARK_CLUSTER_ID.
#
# Everything is a setting; config.csv lists them all with what each one does,
# and the environment beats the file. Three worth knowing before the first run:
#
#   MODULES=spine,cohorts,periods,demographics,tte   the parts that need no
#                                                    code list at all
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

source(file.path(here, "R", "load_inputs.R"))
load_pipeline_inputs(here, "config.csv")
# The driver packages are loaded lazily rather than with library(), so
# DRY_RUN=TRUE resolves and prints a plan on a machine that has none - which
# is where a plan is usually read. Checked after config.csv is loaded, since
# that is where SPARK_METHOD may be set.
if (!identical(toupper(Sys.getenv("DRY_RUN", unset = "FALSE")), "TRUE")) {
  need <- if (identical(tolower(Sys.getenv("SPARK_METHOD", unset = "odbc")), "odbc"))
    c("DBI", "odbc") else "sparklyr"
  for (pkg in need)
    if (!requireNamespace(pkg, quietly = TRUE))
      stop(pkg, " is not installed. DRY_RUN=TRUE prints the plan without it.",
           call. = FALSE)
}
for (f in c("config_223926.R", "db_utils_223926.R", "registry.R", "contract.R",
            "windows.R", "person_time.R", "codelists.R", "lineage.R",
            "run_223926.R"))
  source(file.path(here, "R", f))

# From here on the run goes into its log as well as onto the console - the QC
# tables it prints, its warnings, and the reason it stopped, if it does. The
# error line R prints itself goes to stderr, which the tee does not carry, so
# run_logged() writes the reason into the file as the error is raised.
# Not on a DRY_RUN, which prints a plan, reads nothing, and is as often run on
# a laptop with no results folder as on Domino.
if (!interactive() &&
    !identical(toupper(Sys.getenv("DRY_RUN", unset = "FALSE")), "TRUE"))
  start_run_log()
if (!interactive()) run_logged(build_223926(here))
