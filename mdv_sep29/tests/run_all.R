#!/usr/bin/env Rscript
# Every suite this folder ships, in one run with one exit status.
#
#   Rscript tests/run_all.R          # from this folder, or by path from anywhere
#
# The list is written out rather than discovered: a suite that disappears is a
# failure here, not a smaller green.
#
# A suite that skips (python3 without duckdb and sqlglot, or without pyspark
# and Java for the Spark suite) proved nothing, and counts against the run.
# SPARK_PYTHON names the python that has pyspark, where it is not python3.

HERE <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                               fixed = TRUE)))
  else getwd()
})
ROOT <- dirname(HERE)

SUITES <- c(
  "ndmm/tests/test_runner.R",
  "ndmm/tests/test_mdv_build.R",
  "lot/engine/tests/test_runner.R",
  "lot/engine/tests/test_line_criteria.R",
  "lot/engine/tests/test_mdv_extract.R",
  "lot/validation/tests/test_vignettes.R",
  "tests/test_spark_sql.R")

bad <- 0L; total <- 0L
for (s in SUITES) {
  path <- file.path(ROOT, s)
  if (!file.exists(path)) {
    cat(sprintf("  %-40s MISSING\n", s)); bad <- bad + 1L; next
  }
  out <- suppressWarnings(system2("Rscript", shQuote(path), stdout = TRUE, stderr = TRUE))
  st  <- attr(out, "status"); st <- if (is.null(st)) 0L else st
  sm  <- utils::tail(grep("[0-9]+ passed, [0-9]+ failed", out, value = TRUE), 1)
  n   <- if (length(sm)) as.integer(sub("^\\s*([0-9]+) passed.*", "\\1", sm)) else 0L
  skp <- length(sm) && grepl("[1-9][0-9]* skipped", sm)
  if (st == 0L && length(sm) && !skp) {
    total <- total + n
    cat(sprintf("  %-40s ok    %4d assertions\n", s, n))
  } else {
    bad <- bad + 1L
    cat(sprintf("  %-40s FAIL  %s\n", s,
                if (skp) "skipped" else if (!length(sm)) "no summary line" else sm))
    for (l in utils::tail(out, 12)) cat("      ", l, "\n")
  }
}

cat(sprintf("\n  %d suites, %d assertions, %d not as expected\n",
            length(SUITES), total, bad))
if (bad > 0L) quit(status = 1L)
cat("  Green.\n")
