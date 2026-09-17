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

# A suite whose package or baseline is not there says so and stops. It must not
# read as a pass, so it never exits 0 - but there are two different reasons and
# the gate should not read them the same way.
#
#   5  The PACKAGE is not in the delivery being checked. overall/ is the
#      all-myeloma cohort and the study delivery does not contain it, so the
#      suite comparing it to its baseline has nothing to say about that
#      delivery and never will. Counted as a failure, the gate could not be
#      green for ANY delivery that is not the whole repository, which is every
#      delivery. Reported as not applicable, and named.
#
#   3  Anything else missing - the baseline it compares against, a tool. That
#      is a suite that should have run and did not, and it counts against the
#      gate.
#
# What the 5 does and does not bound. Only a path under PKG_BASE can be one, so
# a missing baseline or dependency cannot become one - but among package paths
# it is not selective: lot/engine missing would be a 5 too, so gating a folder
# whose engine had gone would report port/lot.R as "not part of this delivery"
# rather than as a problem.
#
# What stops that being a hole is not this function. It is EXPECTED_SUITES in
# run_gate.R: a delivery pins the suites it has BY NAME, and a package that
# disappears takes its suites with it, which the gate reports as MISSING and
# fails on. The exemption says "no suite here checks that", and the pin says
# "these suites must be here" - the second is the guard, and it is the one to
# look at if this ever seems to excuse too much.
#
# Every 5 is printed by name rather than absorbed into a count, and
# validation/hygiene/gate_semantics.R pins the verdict, because a status that
# passes the gate having run no assertions is the one most worth holding
# still.
need_dirs <- function(...) {
  paths   <- c(...)
  missing <- Filter(function(p) !dir.exists(p) && !file.exists(p), paths)
  if (!length(missing)) return(invisible(TRUE))
  under_pkg <- startsWith(missing, paste0(normalizePath(PKG_BASE, mustWork = FALSE), "/")) |
               startsWith(missing, paste0(PKG_BASE, "/"))
  if (all(under_pkg)) {
    cat("NOT IN THIS DELIVERY: ", paste(basename(missing), collapse = ", "),
        " is not part of ", basename(PKG_BASE),
        ", so there is nothing here to check.\n", sep = "")
    quit(status = 5L)
  }
  cat("SKIP: not present:", paste(missing, collapse = ", "),
      "\n  (looked under", PKG_BASE, "- set PKG_BASE or STUDY_FOLDER to the",
      "delivery that carries it)\n")
  quit(status = 3L)
}
