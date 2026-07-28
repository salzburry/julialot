#!/usr/bin/env Rscript
# =============================================================================
# build_ndmm.R -- build the NDMM cohort. Complete run on its own.
# -----------------------------------------------------------------------------
#   Rscript "Jul 28/build_ndmm.R"
#   Rscript "Jul 28/build_ndmm.R" --dry-run     # print the SQL, touch nothing
#
# Definition: cohorts/ndmm.R      Engine: R/cohort_run.R
#
# Does NOT build the Overall cohort and never reads ELIG_COH_FINAL. It reads
# ELIG_COH_ALLFLAGS directly, selects its own index dates, and applies its
# LOT1-anchored gates against LOT1_STARTS / LOT1_FLAGS_ALL.
#
# It DOES require the LOT build to have run (its gates are anchored at
# LOT1_START_DT, so there is nothing to measure without a 1L regimen) -- but on
# the union view, not on Overall. See PLAN.md 3 and 6.
# =============================================================================

.root <- local({
  fa <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(fa)) dirname(normalizePath(
    gsub("~+~", " ", sub("^--file=", "", fa[1]), fixed = TRUE))) else getwd()
})
source(file.path(.root, "R", "bootstrap.R"))
cohort_bootstrap(.root)

if (!interactive()) run_build("ndmm")
