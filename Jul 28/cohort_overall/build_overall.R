#!/usr/bin/env Rscript
# =============================================================================
# build_overall.R -- build the Overall cohort from the Optum CDM
# -----------------------------------------------------------------------------
#   DATABRICKS_PWD=... Rscript "Jul 28/cohort_overall/build_overall.R"
#
# Runs on its own: reads the CDM, not ELIG_COH_ALLFLAGS.
#
# Writes to your personal schema (DOMINO_USER_NAME), all objects prefixed ovr_.
# The cohort is ovr_ELIG_COH_FINAL. The legacy ELIG_COH_FINAL is never touched.
# It stages the final cohort and publishes it only after reconciliation, writes
# an ovr_RUN_STATUS row, and drops the intermediates on success. Refuses to run
# if the output does not resolve to a personal schema.
#
# To inspect the SQL or the funnel without a warehouse, run the offline test
# suite: tests/test_cohort_overall.R.
#
# Not yet compared to the legacy cohort on patients -- that is
# tests/verify_cohort_overall.R, which needs a warehouse.
# =============================================================================

.here <- local({
  fa <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (!length(fa)) getwd()
  # R escapes spaces in the script path as "~+~", and this folder is under
  # "Jul 28". Un-escape first or nothing resolves.
  else dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", fa[1]),
                                  fixed = TRUE)))
})

source(file.path(.here, "ie_runner.R"))
if (!interactive()) ie_main(.here) else ie_bootstrap(.here)
