# =============================================================================
# harness.R -- shared test harness + bootstrap for every suite
# -----------------------------------------------------------------------------
# Sourced by tests/test_engine.R, tests/test_equivalence.R,
# overall/tests/test_overall.R and ndmm/tests/test_ndmm.R. Each suite reports
# its own pass/fail; run_all_tests.R runs them together and aggregates.
# =============================================================================

# NOTE: commandArgs() escapes spaces in the script path as "~+~" (this folder is
# "Jul 28"). Un-escape before normalizePath() or nothing resolves.
test_here <- function() {
  fa <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (!length(fa)) return(getwd())
  dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", fa[1]), fixed = TRUE)))
}

# Load the engine, point the loader at the Jul 28 root, and build CFG.
# `here` is a tests/ directory: either <root>/tests or <root>/<cohort>/tests.
#
# CFG is THE REAL CONFIGURATION -- load_cfg() reads pipeline_inputs.csv -- with
# only the table names overridden so assertions can match fixed strings.
# Hand-writing a CFG here is exactly how the suites came to validate a
# configuration nobody runs (REVIEW_FINDINGS.md finding 1): the old one carried
# a 60-day window and no IE toggles at all, so every toggled criterion read as
# ON. One source of truth now.
#
# Assigned here rather than at file scope because load_cfg() does not exist
# until the engine has been sourced.
test_bootstrap <- function(here) {
  root <- dirname(here)
  if (!length(Sys.glob(file.path(root, "*", "cohort.R")))) root <- dirname(root)
  engine <- Sys.getenv("COHORT_ENGINE_DIR", unset = file.path(root, "engine"))
  for (f in c("cohort_specs.R", "cohort_sql.R", "cohort_run.R"))
    source(file.path(engine, f))   # local = FALSE -> evaluates in globalenv()
  set_cohort_root(root)
  assign("CFG", utils::modifyList(load_cfg(), list(
    work_schema    = "wk",
    view_prefix    = "coh_",
    index_flags    = "wk.ELIG_COH_ALLFLAGS",
    lot1_flags     = "wk.LOT1_FLAGS_ALL",
    lot1_starts    = "wk.LOT1_STARTS",
    persist_schema = "wk",
    pld_table      = "COHORT_PLD")), envir = globalenv())
  root
}

# ---- micro test harness -----------------------------------------------------
.n_pass <- 0L; .n_fail <- 0L
ok <- function(cond, what) {
  if (isTRUE(cond)) { .n_pass <<- .n_pass + 1L; cat("  ok   ", what, "\n") }
  else              { .n_fail <<- .n_fail + 1L; cat("  FAIL ", what, "\n") }
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
