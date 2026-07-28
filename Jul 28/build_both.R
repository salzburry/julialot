#!/usr/bin/env Rscript
# =============================================================================
# build_both.R -- both cohorts, stamped onto one shared PLD
# -----------------------------------------------------------------------------
#   Rscript "Jul 28/build_both.R"                  # both (default)
#   Rscript "Jul 28/build_both.R" --cohort=ndmm    # same as ndmm/build.R
#   Rscript "Jul 28/build_both.R" --dry-run
#
# Use this when you want BOTH cohorts as membership columns on a single
# COHORT_PLD, and one LOT build shared between them. For one cohort on its own,
# its own folder says what it does more plainly:
#
#   overall/build.R      ndmm/build.R
#
# Cohorts are discovered as <folder>/cohort.R -- adding a cohort is adding a
# folder, and this script needs no edit.
# =============================================================================

.here <- local({
  fa <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(fa)) dirname(normalizePath(
    gsub("~+~", " ", sub("^--file=", "", fa[1]), fixed = TRUE))) else getwd()
})
source(file.path(.here, "engine", "bootstrap.R"))
cohort_bootstrap(.here)

if (!interactive()) run_build()   # NULL -> read --cohort (default: both)
