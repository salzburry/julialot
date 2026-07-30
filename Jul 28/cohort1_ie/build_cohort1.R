#!/usr/bin/env Rscript
# =============================================================================
# build_cohort1.R -- build cohort 1 (Overall) from the Optum CDM
# -----------------------------------------------------------------------------
#   Rscript "Jul 28/cohort1_ie/build_cohort1.R" --funnel      # the funnel only
#   Rscript "Jul 28/cohort1_ie/build_cohort1.R" --dry-run     # every statement
#   DATABRICKS_PWD=... Rscript "Jul 28/cohort1_ie/build_cohort1.R"
#
#   --views=a,b        run only these views (they must already have their inputs)
#   --no-persist       build the temp views, write no tables
#   --no-attrition     skip the attrition table
#   --attrition-only   count off views this session already built
#
# COMPLETE ON ITS OWN. It reads the CDM, not ELIG_COH_ALLFLAGS, so 01_cohort.R
# does not have to have run. It writes C1_ELIG_COH_FINAL and never touches the
# legacy pipeline's ELIG_COH_FINAL.
#
# NOT VALIDATED AGAINST THE WAREHOUSE. The SQL is asserted token-for-token
# against pipeline_steps.R by tests/test_cohort1_ie.R, which is a strong static
# argument and not an empirical one. Read README.md before quoting a number from
# this.
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
