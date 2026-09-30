# Shared test helpers. Kept inside the LOT folder so the package stays
# copy-pasteable - nothing here reaches outside it.

pass <- 0L; fail <- 0L
ok <- function(cond, what) {
  if (isTRUE(cond)) { pass <<- pass + 1L; cat("  ok    ", what, "\n") }
  else { fail <<- fail + 1L; cat("  FAIL  ", what, "\n") }
}
runs  <- function(expr, what) ok(!inherits(tryCatch(expr, error = function(e) e), "error"), what)
stops <- function(expr, what) ok(inherits(tryCatch(expr, error = function(e) e), "error"), what)
has   <- function(x, s) grepl(s, x, fixed = TRUE)

report <- function() {
  cat("\n", strrep("-", 52), "\n", sep = "")
  cat(sprintf("%d passed, %d failed\n", pass, fail))
  if (fail > 0L) quit(status = 1L)
}

# glue, as the builds use it. A hand-written stand-in used to take over where
# the package was missing, which tested a second interpolator rather than the
# one production runs; the suites now require the real one. It has to be
# attached rather than merely loadable: the suites sys.source() each file into
# environments parented on globalenv, so glue() is found on the search path or
# not at all.
if (!requireNamespace("glue", quietly = TRUE))
  stop("These suites need the glue package, as the builds do: ",
       "install.packages(\"glue\")", call. = FALSE)
library(glue)
