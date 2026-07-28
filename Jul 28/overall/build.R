#!/usr/bin/env Rscript
# =============================================================================
# overall/build.R -- build the Overall cohort. Everything it needs is here.
# -----------------------------------------------------------------------------
#   Rscript "Jul 28/overall/build.R"
#   Rscript "Jul 28/overall/build.R" --dry-run    # print the SQL, touch nothing
#
#   overall/cohort.R    the definition (gate list, no SQL)
#   overall/tests/      its tests
#   ../engine/          the shared SQL generator
#
# Reads ELIG_COH_ALLFLAGS and nothing else. Overall has no LOT1-anchored gates,
# so this never touches the LOT build, the LOT1 flag tables, or the ndmm folder.
# =============================================================================

.here <- local({
  fa <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(fa)) dirname(normalizePath(
    gsub("~+~", " ", sub("^--file=", "", fa[1]), fixed = TRUE))) else getwd()
})
source(file.path(dirname(.here), "engine", "bootstrap.R"))
cohort_bootstrap(.here)

if (!interactive()) run_build("overall")
