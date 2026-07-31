#!/usr/bin/env Rscript
# The NDMM cohort is a port of the cohort half of
# apr_30_2026/06_ndmm_dashboard.R, not a rewrite. That file is 1,479 lines of
# which roughly 840 build the cohort and the rest render a dashboard; this
# package takes the first half only. Every ported file is compared line for
# line against the range it came from.
#
# Skipped when apr_30_2026 is not beside this folder, so a copied-out package
# still runs its other suites.
#
#   Rscript "Jul 28/nndm/tests/test_same_as_source.R"

ROOT <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                                 fixed = TRUE))) else getwd()
  dirname(d)
})
source(file.path(ROOT, "tests", "testutil.R"))

SRC <- file.path(dirname(dirname(ROOT)), "apr_30_2026", "06_ndmm_dashboard.R")
if (!file.exists(SRC)) {
  cat("apr_30_2026 not beside this folder -- nothing to compare against. Skipping.\n")
  quit(status = 0L)
}
src <- readLines(SRC, warn = FALSE)

# Where each file came from. The ranges are contiguous and non-overlapping, and
# together they are the cohort half of the source - asserted below, so a range
# that is quietly narrowed cannot drop code without saying so.
PARTS <- list(
  list(file = "R/nndm_constants.R",      from = 62,  to = 142),
  list(file = "R/steps/01_enrollment.R",  from = 143, to = 198),
  list(file = "R/steps/02_lot1_starts.R", from = 199, to = 216),
  list(file = "R/steps/03_prior_therapy.R", from = 217, to = 317),
  list(file = "R/steps/04_other_malig.R", from = 318, to = 533),
  list(file = "R/steps/05_pregnancy.R",   from = 534, to = 621),
  list(file = "R/steps/06_flags.R",       from = 622, to = 755),
  list(file = "R/steps/07_cohort.R",      from = 756, to = 839)
)

# Comments are compared out, so the copied comments can be tidied without
# weakening the check. Change a code line and it fails; change a comment and it
# does not. Whole-line comments only - stripping trailing ones would mangle a
# "#" inside a SQL string.
code_only <- function(lines) {
  keep <- !grepl("^\\s*(#|--)", lines) & nzchar(trimws(lines))
  trimws(lines[keep])
}

# The header each ported file adds above the copied body.
body_of <- function(lines) {
  i <- which(!grepl("^\\s*#", lines) & nzchar(trimws(lines)))
  if (!length(i)) return(character(0))
  lines[seq(min(i), length(lines))]
}

cat("\n-- every ported file is the source, line for line --\n")
for (p in PARTS) {
  f <- file.path(ROOT, p$file)
  if (!file.exists(f)) { ok(FALSE, paste0(p$file, ": missing")); next }
  got  <- code_only(body_of(readLines(f, warn = FALSE)))
  want <- code_only(src[p$from:p$to])
  if (identical(got, want)) {
    ok(TRUE, paste0(p$file, ": same code as lines ", p$from, "-", p$to,
                    " (", length(want), " lines)"))
  } else {
    n <- max(length(got), length(want))
    g <- c(got, rep(NA, n - length(got))); w <- c(want, rep(NA, n - length(want)))
    d <- which(is.na(g) | is.na(w) | g != w)[1]
    ok(FALSE, paste0(p$file, ": differs at source line ", p$from + d - 1,
                     "\n           source: ", if (is.na(w[d])) "<nothing>" else w[d],
                     "\n           ported: ", if (is.na(g[d])) "<nothing>" else g[d]))
  }
}

cat("\n-- and the ranges account for the whole cohort half --\n")
# Contiguous and in order, so no source line between the first and the last
# falls outside a ported file. A narrowed range would leave a gap here rather
# than silently dropping the code inside it.
gaps <- character(0)
for (i in seq_along(PARTS)[-1]) {
  if (PARTS[[i]]$from != PARTS[[i - 1]]$to + 1L)
    gaps <- c(gaps, paste0(PARTS[[i - 1]]$to, " -> ", PARTS[[i]]$from))
}
ok(length(gaps) == 0,
   if (length(gaps)) paste0("the ranges skip source lines: ", paste(gaps, collapse = ", "))
   else paste0("the ", length(PARTS), " ranges are contiguous, ",
               PARTS[[1]]$from, "-", PARTS[[length(PARTS)]]$to))

report()
