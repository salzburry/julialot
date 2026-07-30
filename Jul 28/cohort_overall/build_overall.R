#!/usr/bin/env Rscript
# =============================================================================
# build_overall.R -- build the Overall cohort from the Optum CDM
# -----------------------------------------------------------------------------
#   Rscript "Jul 28/cohort_overall/build_overall.R" --funnel    # the funnel
#   Rscript "Jul 28/cohort_overall/build_overall.R" --dry-run   # the SQL
#   DATABRICKS_PWD=... Rscript "Jul 28/cohort_overall/build_overall.R"
#
# Runs on its own: reads the CDM, not ELIG_COH_ALLFLAGS.
#
# Writes 27 tables to your personal schema (DOMINO_USER_NAME), all prefixed
# ovr_. The cohort is ovr_ELIG_COH_FINAL. The legacy ELIG_COH_FINAL is never
# touched.
#
# After building it reconciles the cohort against the funnel -- grain, count,
# membership both ways, and that the index date is the earliest surviving
# candidate -- and exits non-zero if a check fails.
#
# Not yet compared to the legacy cohort. That is
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
if (!interactive()) {
  ie_main(.here)
} else {
  ie_bootstrap(.here)
  message("sourced. cfg <- ie_cfg(\"", .here, "\"); ",
          "ie_print_funnel(ie_funnel(cfg))")
}
