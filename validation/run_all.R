#!/usr/bin/env Rscript
# Every validation suite, one summary.
#
#   Rscript validation/run_all.R
#
# A suite that cannot find the package or the baseline it compares against
# reports SKIP and is counted separately - a checkout may hold one and not the
# other, and that is not a pass. The exit status is non-zero if anything failed
# OR was skipped, because a release check that quietly ran nothing is the
# failure this whole directory exists to prevent.

HERE <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (!length(a)) getwd()
  else dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                  fixed = TRUE)))
})

suites <- sort(c(list.files(file.path(HERE, "port"), "[.]R$", full.names = TRUE),
                 list.files(file.path(HERE, "hygiene"), "[.]R$", full.names = TRUE)))

cat(strrep("=", 64), "\n", sep = "")
cat("  VALIDATION SUITES\n")
cat(strrep("=", 64), "\n", sep = "")

pass <- 0L; fail <- 0L; skip <- 0L; total <- 0L
for (s in suites) {
  rel <- sub(paste0("^", HERE, "/"), "", s)
  out <- suppressWarnings(system2("Rscript", shQuote(s), stdout = TRUE, stderr = TRUE))
  st  <- attr(out, "status")
  st  <- if (is.null(st)) 0L else st
  line <- grep("passed, [0-9]+ failed", out, value = TRUE)
  if (identical(st, 3L)) {
    skip <- skip + 1L
    cat(sprintf("  %-34s SKIP  %s\n", rel,
                sub("^SKIP: ", "", grep("^SKIP", out, value = TRUE)[1])))
  } else if (length(line)) {
    n <- as.integer(sub("^\\s*([0-9]+) passed.*", "\\1", line[length(line)]))
    f <- as.integer(sub(".*passed, ([0-9]+) failed.*", "\\1", line[length(line)]))
    total <- total + n
    if (f > 0L || st != 0L) {
      fail <- fail + 1L
      cat(sprintf("  %-34s FAIL  %s passed, %s failed\n", rel, n, f))
      for (l in grep("FAIL", out, value = TRUE)) cat("        ", l, "\n")
    } else {
      pass <- pass + 1L
      cat(sprintf("  %-34s ok    %s assertions\n", rel, n))
    }
  } else {
    fail <- fail + 1L
    cat(sprintf("  %-34s ERROR\n", rel))
    for (l in utils::tail(out, 6)) cat("        ", l, "\n")
  }
}

cat(strrep("-", 64), "\n", sep = "")
cat(sprintf("  %d suite(s) ok, %d failed, %d skipped -- %d assertions\n",
            pass, fail, skip, total))
if (skip > 0L)
  cat("  A skipped suite proved nothing. Point BASELINE_DIR / PKG_BASE at them.\n")
cat(strrep("=", 64), "\n", sep = "")

if (fail > 0L || skip > 0L) quit(status = 1L)
