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
# they are PINNED below - BY IDENTITY, not by count.
#
# By count was the first version and it was a false green waiting to happen:
# fix one of the six, introduce one regression, and the count is still six. What
# is pinned is which comparisons fail, so a failure appearing is caught even
# when a failure disappears in the same commit. Both directions fail the gate -
# a new one is a regression, a missing one means this baseline is now a lie.
#
# The pin drops the trailing source line number, which moves whenever anything
# above it is edited. What identifies a failure is which step differs and how,
# not where in the file the differing line happens to sit.

HERE <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                                 fixed = TRUE))) else getwd()
  d
})
REPO   <- dirname(HERE)
STUDY  <- Sys.getenv("STUDY_FOLDER", unset = file.path(REPO, "Jul 28"))

# suite -> the failures it is allowed to have, by identity. Absent means none.
EXPECTED_FAILURES <- list(
  "validation/port/lot.R" = c(
    # The line COUNT is part of the identity, not decoration. Without it the
    # pin was "this file differs", which stayed true however much more of it
    # diverged - and every file the CAR-T and melphalan work touched was
    # already pinned, so those changes rode in unexamined. A count moves when
    # the divergence set moves, and re-pinning is then a conscious act.
    # Counted over comment-stripped code, so prose does not churn it.
    "03_mma_map.R: differs beyond the approved deviations in 217 line(s)",
    "04_lot1_base.R: differs from 02_lot1.R in 126 line(s)",
    "05b_lot1_sct.R: differs beyond the approved deviations in 148 line(s)",
    "06_lot1_end.R: differs beyond the approved deviations in 204 line(s)",
    "08_persist.R: differs beyond the approved deviations in 111 line(s)",
    "10_lot2_5_base.R: differs from R/lot2_5_base.R in 824 line(s)")
)

# How one suite's output is read. Its own suite is validation/hygiene/
# gate_semantics.R, which holds it to failing on each of the three greens it
# used to give wrongly.
source(file.path(HERE, "_gate_logic.R"))

suites <- c(
  sort(list.files(STUDY, pattern = "\\.R$", recursive = TRUE, full.names = TRUE)),
  sort(list.files(HERE, pattern = "\\.R$", recursive = TRUE, full.names = TRUE))
)
suites <- suites[grepl("/tests/", suites) |
                 grepl("/validation/(port|hygiene)/", suites) |
                 # Not under tests/, and advertised in the study README as a
                 # check that exits non-zero if any of the study team's worked
                 # scenarios moves. A check nothing runs is a check in name
                 # only, so it is named here rather than left to be remembered.
                 grepl("/run_melp_scenarios\\.R$", suites)]
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
  want <- EXPECTED_FAILURES[[rel[i]]]; want <- if (is.null(want)) character(0) else want
  v <- gate_verdict(out, st, want)
  total <- total + v$passed
  if (v$skipped) skipped <- skipped + 1L
  if (v$ok) {
    cat(sprintf("  %-52s ok    %4d assertions%s\n", rel[i], v$passed,
                if (v$pinned) sprintf("  (%d pinned failures)", v$pinned) else ""))
  } else {
    bad <- bad + 1L
    cat(sprintf("  %-52s FAIL\n", rel[i]))
    for (r in v$reasons) cat("         ", r, "\n")
    if (any(grepl("^no summary", v$reasons)))
      for (l in utils::tail(out, 8)) cat("           ", l, "\n")
  }
}

cat(strrep("-", 74), "\n", sep = "")
cat(sprintf("  %d suites, %d assertions, %d skipped, %d not as expected\n",
            length(suites), total, skipped, bad))
if (skipped > 0L)
  cat("  A skipped suite proved nothing, so it counts against the gate.\n")
if (bad > 0L) {
  cat("\n  Not green. A pinned failure that STOPPED failing is as much a problem\n")
  cat("  as a new one: the baseline in this file is then wrong, and the next\n")
  cat("  regression would land in the space it left.\n\n")
  quit(status = 1L)
}
cat("\n  Green.\n\n")
