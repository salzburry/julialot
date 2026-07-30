#!/usr/bin/env Rscript
# =============================================================================
# build_overall.R -- build the Overall cohort from the Optum CDM
# -----------------------------------------------------------------------------
#   DATABRICKS_PWD=... Rscript "Jul 28/cohort_overall/build_overall.R"
#
# Runs on its own: reads the CDM, not ELIG_COH_ALLFLAGS.
#
# Writes to your own schema -- PROJECT_WORK_SCHEMA, else DOMINO_USER_NAME, the
# same resolution config_lot.R uses -- so on Domino that is
# hive_metastore.<user>.ovr_*. The cohort is ovr_ELIG_COH_FINAL; the legacy
# ELIG_COH_FINAL is never touched.
#
# The final cohort is staged and published with the attrition table only after
# reconciliation passes. ovr_RUN_STATUS records the run and the active criteria.
# Intermediates are dropped on success.
#
# To inspect the SQL or the funnel without a warehouse, run the offline test
# suite: tests/test_cohort_overall.R.
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
