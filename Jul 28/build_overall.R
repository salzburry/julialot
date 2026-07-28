#!/usr/bin/env Rscript
# =============================================================================
# build_overall.R -- build the Overall cohort. Complete run on its own.
# -----------------------------------------------------------------------------
#   Rscript "Jul 28/build_overall.R"
#   Rscript "Jul 28/build_overall.R" --dry-run     # print the SQL, touch nothing
#
# Definition: cohorts/overall.R      Engine: R/cohort_run.R
#
# Builds NDMM neither directly nor indirectly. Overall has no LOT1-anchored
# gates, so this needs only ELIG_COH_ALLFLAGS -- the LOT build and the
# LOT1 flag tables are not read at all.
# =============================================================================

.root <- local({
  fa <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(fa)) dirname(normalizePath(
    gsub("~+~", " ", sub("^--file=", "", fa[1]), fixed = TRUE))) else getwd()
})
source(file.path(.root, "R", "bootstrap.R"))
cohort_bootstrap(.root)

if (!interactive()) run_build("overall")
