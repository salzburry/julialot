# =============================================================================
# bootstrap.R -- shared startup for the three entry points
# -----------------------------------------------------------------------------
# Resolves the Jul 28 root from wherever the entry point lives, sources the
# engine in dependency order, and points the cohort loader at the root. Every
# entry point is then two lines.
#
# NOTE: commandArgs() escapes spaces in a script path as "~+~", and this folder
# is "Jul 28". Un-escape before normalizePath() or nothing below resolves.
# =============================================================================

# `here` is the directory of the calling entry point:
#   overall/build.R, ndmm/build.R  -> a cohort folder, root is its parent
#   build_both.R                   -> the root itself
cohort_bootstrap <- function(here) {
  root   <- if (length(Sys.glob(file.path(here, "*", COHORT_FILE_NAME)))) here
            else dirname(here)
  engine <- Sys.getenv("COHORT_ENGINE_DIR", unset = file.path(root, "engine"))
  if (!dir.exists(engine))
    stop("cannot find the engine at ", engine,
         " -- set COHORT_ENGINE_DIR if this folder was moved.", call. = FALSE)
  source(file.path(engine, "cohort_specs.R"))
  source(file.path(engine, "cohort_sql.R"))
  source(file.path(engine, "cohort_run.R"))
  set_cohort_root(root)
  invisible(root)
}

# bootstrap.R is sourced before cohort_specs.R defines COHORT_FILE, so it needs
# its own copy of the name. Kept in sync by a test.
COHORT_FILE_NAME <- "cohort.R"
