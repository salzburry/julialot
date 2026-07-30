#!/usr/bin/env Rscript
# =============================================================================
# build_cohort1.R -- build cohort 1 (Overall) from the Optum CDM
# -----------------------------------------------------------------------------
#   Rscript "Jul 28/cohort1_ie/build_cohort1.R" --funnel    # the funnel, no connection
#   Rscript "Jul 28/cohort1_ie/build_cohort1.R" --dry-run   # every statement, no connection
#   DATABRICKS_PWD=... Rscript "Jul 28/cohort1_ie/build_cohort1.R"
#
# Those are the only modes. See ie_runner.R for why the partial-run options were
# removed.
#
# COMPLETE ON ITS OWN. It reads the CDM, not ELIG_COH_ALLFLAGS, so 01_cohort.R
# does not have to have run. Every object is a real table in your own schema,
# prefixed c1_, and the cohort is c1_ELIG_COH_FINAL -- the legacy pipeline's
# ELIG_COH_FINAL is never written.
#
# After building, it reconciles the cohort table against the funnel (grain,
# count, membership both ways, and that the selected index date is the earliest
# SURVIVING candidate) and exits non-zero if any check fails.
#
# NOT VALIDATED AGAINST THE LEGACY COHORT. Reconciliation is internal
# consistency. Agreement with ELIG_COH_FINAL is tests/verify_cohort1.R, which
# needs a warehouse and has not been run. Read README.md before quoting a number.
# =============================================================================

.here <- local({
  fa <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (!length(fa)) getwd()
  # commandArgs() escapes spaces in the script path as "~+~" and this folder is
  # under "Jul 28" -- un-escape before normalizePath() or nothing resolves.
  else dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", fa[1]),
                                  fixed = TRUE)))
})

source(file.path(.here, "ie_runner.R"))
if (!interactive()) {
  ie_main(.here)
} else {
  ie_bootstrap(.here)
  message("sourced. cfg <- ie_cfg(\"", .here, "\"); f <- ie_funnel(cfg); ",
          "ie_print_funnel(f)")
}
