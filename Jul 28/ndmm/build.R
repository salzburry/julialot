#!/usr/bin/env Rscript
# =============================================================================
# ndmm/build.R -- build the NDMM cohort. Everything it needs is here.
# -----------------------------------------------------------------------------
#   Rscript "Jul 28/ndmm/build.R"
#   Rscript "Jul 28/ndmm/build.R" --index-only    # stop at the LOT-build input
#   Rscript "Jul 28/ndmm/build.R" --dry-run       # print the SQL, touch nothing
#
#   ndmm/cohort.R             the definition (gate list, no SQL)
#   ndmm/build_lot1_flags.R   the LOT1-anchored flag stage NDMM needs
#   ndmm/tests/               its tests
#   ../engine/                the shared SQL generator
#
# Does NOT build the Overall cohort and never reads ELIG_COH_FINAL. It reads
# ELIG_COH_ALLFLAGS directly, selects its own index dates, and applies its
# LOT1-anchored gates against LOT1_STARTS / LOT1_FLAGS_ALL.
#
# It DOES need the LOT build to have run -- its gates are anchored at
# LOT1_START_DT, so there is nothing to measure without a 1L regimen. On the
# union view, not on Overall. Run order: build_lot1_flags.R header, PLAN.md 6.
# =============================================================================

.here <- local({
  fa <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(fa)) dirname(normalizePath(
    gsub("~+~", " ", sub("^--file=", "", fa[1]), fixed = TRUE))) else getwd()
})
source(file.path(dirname(.here), "engine", "bootstrap.R"))
cohort_bootstrap(.here)

if (!interactive()) run_build("ndmm")
