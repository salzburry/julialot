#!/usr/bin/env Rscript
# =============================================================================
# build_cohort.R -- build either cohort, or both plus the shared PLD
# -----------------------------------------------------------------------------
#   Rscript "Jul 28/build_cohort.R" --cohort=both      # default
#   Rscript "Jul 28/build_cohort.R" --cohort=overall   # same as build_overall.R
#   Rscript "Jul 28/build_cohort.R" --cohort=ndmm      # same as build_ndmm.R
#   Rscript "Jul 28/build_cohort.R" --cohort=both --dry-run
#
# Use this one when you want BOTH cohorts stamped onto a single COHORT_PLD, and
# a single LOT build shared between them. For one cohort on its own, the
# dedicated entry points say what they do more plainly:
#
#   build_overall.R    build_ndmm.R
#
# Cohorts are discovered from cohorts/ -- one file per cohort. Adding a cohort
# means adding a file; this script needs no edit.
# =============================================================================

.root <- local({
  fa <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(fa)) dirname(normalizePath(
    gsub("~+~", " ", sub("^--file=", "", fa[1]), fixed = TRUE))) else getwd()
})
source(file.path(.root, "R", "bootstrap.R"))
cohort_bootstrap(.root)

if (!interactive()) run_build()   # NULL -> read --cohort (default: both)
