#!/usr/bin/env Rscript
# =============================================================================
# run_all_tests.R -- run every suite and aggregate
# -----------------------------------------------------------------------------
#   Rscript "Jul 28/run_all_tests.R"
#
#   tests/test_engine.R          engine + cross-cohort invariants
#   tests/test_equivalence.R     new cohorts vs the old pipeline (see its header
#                                for what this can and cannot prove)
#   overall/tests/test_overall.R the Overall cohort's own contract
#   ndmm/tests/test_ndmm.R       the NDMM cohort's own contract
#
# Each suite is also runnable on its own -- a cohort folder's tests never need
# the other cohort's.
# =============================================================================

.here <- local({
  fa <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (!length(fa)) getwd()
  else dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", fa[1]), fixed = TRUE)))
})

# Root-level suites (engine, equivalence) plus each cohort folder's own.
# Globbed, not listed: adding a suite must not require editing this file.
suites <- unique(c(sort(Sys.glob(file.path(.here, "tests", "test_*.R"))),
                   sort(Sys.glob(file.path(.here, "*", "tests", "test_*.R")))))

fails <- 0L
for (s in suites) {
  cat("\n", strrep("=", 60), "\n", sub(paste0("^", .here, "/"), "", s), "\n",
      strrep("=", 60), "\n", sep = "")
  rc <- system2("Rscript", shQuote(s), stdout = "", stderr = "")
  if (rc != 0L) fails <- fails + 1L
}

cat("\n", strrep("=", 60), "\n", sep = "")
if (fails == 0L) cat("ALL SUITES PASSED (", length(suites), " suites)\n", sep = "")
else { cat(fails, " of ", length(suites), " suites FAILED\n", sep = ""); quit(status = 1L) }
