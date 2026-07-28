# =============================================================================
# harness.R -- shared test harness + bootstrap for every suite
# -----------------------------------------------------------------------------
# Sourced by tests/test_engine.R, overall/tests/test_overall.R and
# ndmm/tests/test_ndmm.R. Each suite reports its own pass/fail; run_all_tests.R
# runs them together and aggregates.
# =============================================================================

# NOTE: commandArgs() escapes spaces in the script path as "~+~" (this folder is
# "Jul 28"). Un-escape before normalizePath() or nothing resolves.
test_here <- function() {
  fa <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (!length(fa)) return(getwd())
  dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", fa[1]), fixed = TRUE)))
}

# Load the engine and point the loader at the Jul 28 root. `here` is a tests/
# directory: either <root>/tests or <root>/<cohort>/tests.
test_bootstrap <- function(here) {
  root <- dirname(here)
  if (!length(Sys.glob(file.path(root, "*", "cohort.R")))) root <- dirname(root)
  engine <- Sys.getenv("COHORT_ENGINE_DIR", unset = file.path(root, "engine"))
  for (f in c("cohort_specs.R", "cohort_sql.R", "cohort_run.R"))
    source(file.path(engine, f))
  set_cohort_root(root)
  root
}

.n_pass <- 0L; .n_fail <- 0L
ok <- function(cond, what) {
  if (isTRUE(cond)) { .n_pass <<- .n_pass + 1L; cat("  ok   ", what, "\n") }
  else { .n_fail <<- .n_fail + 1L; cat("  FAIL ", what, "\n") }
}
throws <- function(expr, what) {
  e <- tryCatch({ force(expr); NULL }, error = function(e) e)
  ok(!is.null(e), what)
}
section <- function(s) cat("\n", s, "\n", sep = "")
test_summary <- function(label) {
  cat("\n", strrep("-", 52), "\n", sep = "")
  cat(sprintf("%s: %d passed, %d failed\n", label, .n_pass, .n_fail))
  invisible(c(pass = .n_pass, fail = .n_fail))
}

CFG <- list(work_schema = "wk", view_prefix = "coh_",
            index_flags = "wk.ELIG_COH_ALLFLAGS",
            lot1_flags  = "wk.LOT1_FLAGS_ALL",
            lot1_starts = "wk.LOT1_STARTS",
            persist_schema = "wk", pld_table = "COHORT_PLD",
            min_age = 18L, outpatient_window = 60L, lot1_from = "2017-01-01")
