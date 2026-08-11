#!/usr/bin/env Rscript
# Every suite the study folder ships, and the repository checks that hold it to
# its claims, in one run with one exit status.
#
# It lives here rather than in the study folder for the reason everything else
# here does: it names the port and hygiene suites, and the study folder may not.
# The first version of this file sat inside it and was caught by the very check
# it was written to run - which is the check working.
#
#   Rscript validation/run_gate.R           # from the repository root
#
# No warehouse, no connection. This is what the merge gate runs, and it exists
# so that "all suites pass" is a thing a machine says rather than a thing an
# author reports.
#
# One suite is expected to fail. validation/port/lot.R compares the LOT steps
# against the delivery they were ported from and has six failures that predate
# this folder's current state. Excluding it would hide a real comparison;
# letting it fail would make the gate permanently red and therefore ignored. So
# its failure count is PINNED below, and the gate fails if the number moves in
# either direction - more is a regression, fewer means someone fixed something
# and the baseline is now a lie.

HERE <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                                 fixed = TRUE))) else getwd()
  d
})
REPO   <- dirname(HERE)
STUDY  <- Sys.getenv("STUDY_FOLDER", unset = file.path(REPO, "Jul 28"))

# suite -> expected failures. Absent means zero.
EXPECTED_FAILURES <- list("validation/port/lot.R" = 6L)

suites <- c(
  sort(list.files(STUDY, pattern = "\\.R$", recursive = TRUE, full.names = TRUE)),
  sort(list.files(HERE, pattern = "\\.R$", recursive = TRUE, full.names = TRUE))
)
suites <- suites[grepl("/tests/", suites) | grepl("/validation/(port|hygiene)/", suites)]
suites <- suites[!grepl("testutil\\.R$|/_|run_gate\\.R$|run_all\\.R$", suites)]
rel <- sub(paste0("^", REPO, "/"), "", suites)

cat("\n", strrep("=", 74), "\n", sep = "")
cat("  THE MERGE GATE - EVERY SUITE\n")
cat(strrep("=", 74), "\n", sep = "")

bad <- 0L; total <- 0L; skipped <- 0L
for (i in seq_along(suites)) {
  out <- suppressWarnings(system2("Rscript", shQuote(suites[i]),
                                  stdout = TRUE, stderr = TRUE))
  st <- attr(out, "status"); st <- if (is.null(st)) 0L else st
  line <- grep("[0-9]+ passed, [0-9]+ failed", out, value = TRUE)
  want <- EXPECTED_FAILURES[[rel[i]]]; want <- if (is.null(want)) 0L else want
  if (identical(st, 3L)) {
    skipped <- skipped + 1L
    cat(sprintf("  %-52s SKIP\n", rel[i])); next
  }
  if (!length(line)) {
    bad <- bad + 1L
    cat(sprintf("  %-52s NO SUMMARY (exit %s)\n", rel[i], st))
    for (l in utils::tail(out, 8)) cat("        ", l, "\n")
    next
  }
  last <- line[length(line)]
  p <- as.integer(sub("^\\D*([0-9]+) passed.*", "\\1", last))
  f <- as.integer(sub(".*passed, ([0-9]+) failed.*", "\\1", last))
  total <- total + p
  if (identical(f, want)) {
    cat(sprintf("  %-52s ok    %4d assertions%s\n", rel[i], p,
                if (want > 0L) sprintf("  (%d expected failures)", want) else ""))
  } else {
    bad <- bad + 1L
    cat(sprintf("  %-52s FAIL  %d failed, expected %d\n", rel[i], f, want))
    for (l in grep("FAIL", out, value = TRUE)) cat("        ", l, "\n")
  }
}

cat(strrep("-", 74), "\n", sep = "")
cat(sprintf("  %d suites, %d assertions, %d skipped, %d not as expected\n",
            length(suites), total, skipped, bad))
if (skipped > 0L)
  cat("  A skipped suite proved nothing.\n")
if (bad > 0L) {
  cat("\n  Not green. A suite whose failure count MOVED is as much a problem as\n")
  cat("  a new failure: the pinned baseline in this file is then wrong.\n\n")
  quit(status = 1L)
}
cat("\n  Green.\n\n")
