# =============================================================================
# bootstrap.R -- shared startup for the three entry points
# -----------------------------------------------------------------------------
# Resolves this folder, sources the layer in dependency order, and points the
# cohort loader at cohorts/. Every entry point is then two lines.
#
# NOTE: commandArgs() escapes spaces in a script path as "~+~", and this folder
# is "Jul 28". Un-escape before normalizePath() or nothing below resolves.
# =============================================================================

cohort_bootstrap <- function(root) {
  source(file.path(root, "R", "cohort_specs.R"))
  source(file.path(root, "R", "cohort_sql.R"))
  source(file.path(root, "R", "cohort_run.R"))
  set_cohort_dir(file.path(root, COHORT_DIR))
  invisible(root)
}
