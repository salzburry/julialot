# Where the packages under test and the baseline they were migrated from live.
#
# These suites sit here rather than inside each package because they are not
# part of what ships: the deployable artifact is the package folder alone, and
# these name a baseline that is not in it.
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

# PKG_BASE and STUDY_FOLDER name the same thing: the delivery being checked.
# They were resolved separately, and PKG_BASE alone still defaulted to "Jul 28"
# after the LOT package moved out of it. So run_gate.R could set STUDY_FOLDER to
# a delivery, run these suites against it, and have two of them look in Jul 28,
# find no lot/engine there, and SKIP - reporting "not present" for a package
# that was present in the folder actually being gated.
#
# PKG_BASE still wins when it is set, because a release job may lay a checkout
# out some other way; STUDY_FOLDER is what the gate sets, and it is followed
# now rather than ignored.
.pkg_base_default <- function() {
  sf <- trimws(Sys.getenv("STUDY_FOLDER", unset = ""))
  if (!nzchar(sf)) return(file.path(REPO, "Jul 28"))
  vv <- chartr("\\", "/", sf)
  if (startsWith(vv, "/") || grepl("^[A-Za-z]:/", vv)) vv else file.path(REPO, sf)
}
PKG_BASE  <- Sys.getenv("PKG_BASE",  unset = .pkg_base_default())
BASELINE  <- Sys.getenv("BASELINE_DIR", unset = file.path(REPO, "apr_30_2026"))

# Path segments rather than one name: the LOT packages sit in a lot/ group now,
# so the engine is pkg_dir("lot", "engine") and a cohort build is still
# pkg_dir("ndmm"). The suites name the package they check; where it sits is
# theirs to say, not this file's.
# The package under the delivery being checked, and no search past it.
#
# One root cannot describe this repository: the LOT packages live in one
# delivery and ndmm/, overall/ and the rest still live in another. Searching
# the other deliveries for a missing package looks like the fix and is not -
# THREE of them carry an ndmm/, so the search resolves to whichever sorts
# first, which is Aug 14's fork rather than the one this delivery is built on.
# That is the same silent wrong answer the emitters were changed to refuse.
#
# Which cohort belongs with which engine is a fact about the delivery, not
# something a filesystem walk can recover. So a package that is not under this
# root is reported absent, with the root named, and the suite skips - the gate
# counts that against itself. Fixing it for real means either the delivery
# becomes self-contained or this file gains a declared map, and both are
# decisions about the repository rather than about this file.
pkg_dir <- function(...) file.path(PKG_BASE, ...)

# A suite whose package or baseline is not there says so and exits 0. It is not
# a failure - a checkout may hold one and not the other - but it must not read
# as a pass either, so run_all.R counts skips separately and reports them.
need_dirs <- function(...) {
  missing <- Filter(function(p) !dir.exists(p) && !file.exists(p), c(...))
  if (length(missing)) {
    cat("SKIP: not present:", paste(missing, collapse = ", "),
        "\n  (looked under", PKG_BASE, "- set PKG_BASE or STUDY_FOLDER to the",
        "delivery that carries it)\n")
    quit(status = 3L)
  }
  invisible(TRUE)
}
