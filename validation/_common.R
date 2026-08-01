# Where the packages under test and the baseline they were migrated from live.
#
# These suites used to sit inside each package, at <pkg>/tests/, and worked out
# where they were from their own path. They are here instead because they are
# not part of what ships: the deployable artifact is the package folder alone,
# and these name a baseline that is not in it. Keeping them inside meant either
# shipping the baseline's name to production or deleting the only thing that
# continuously proves the migration still holds. Outside, both are satisfied.
#
# Both roots are overridable, so a release job can point at a checkout laid out
# some other way, or at a renamed package folder, without editing a test.

validation_root <- function() {
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (!length(a)) getwd()
       else dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                       fixed = TRUE)))
  # <repo>/validation/<subdir>/<file>.R -> <repo>
  dirname(dirname(d))
}

REPO      <- validation_root()
PKG_BASE  <- Sys.getenv("PKG_BASE",  unset = file.path(REPO, "Jul 28"))
BASELINE  <- Sys.getenv("BASELINE_DIR", unset = file.path(REPO, "apr_30_2026"))

pkg_dir <- function(name) file.path(PKG_BASE, name)

# A suite whose package or baseline is not there says so and exits 0. It is not
# a failure - a checkout may hold one and not the other - but it must not read
# as a pass either, so run_all.R counts skips separately and reports them.
need_dirs <- function(...) {
  missing <- Filter(function(p) !dir.exists(p) && !file.exists(p), c(...))
  if (length(missing)) {
    cat("SKIP: not present:", paste(missing, collapse = ", "), "\n")
    quit(status = 3L)
  }
  invisible(TRUE)
}
