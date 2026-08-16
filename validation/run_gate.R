#!/usr/bin/env Rscript
# Every suite the study folder ships, and the repository checks that hold it to
# its claims, in one run with one exit status.
#
# It lives here rather than in the study folder for the reason everything else
# here does: it names the port and hygiene suites, and the study folder may not.
#
#   Rscript validation/run_gate.R           # from the repository root
#
# No warehouse, no connection. This is what the merge gate runs, so that "all
# suites pass" is a thing a machine says rather than a thing an author reports.
#
# One suite is expected to fail. validation/port/lot.R compares the LOT steps
# against the delivery they were ported from and carries known differences.
# Excluding it would hide a real comparison; letting it fail would make the gate
# permanently red and therefore ignored. So they are PINNED below - BY IDENTITY,
# not by count. What is pinned is which comparisons fail, so a failure appearing
# is caught even when a failure disappears in the same commit. Both directions
# fail the gate: a new one is a regression, a missing one means this baseline no
# longer describes the code.
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
# STUDY_FOLDER takes either an absolute path or a name relative to the repo.
# Both forms were already in use and they did not agree: this file resolved the
# variable as a path, while the hygiene suites read it as a bare folder name and
# join it to the repo root themselves. An absolute value therefore ran the study
# suites correctly and made three hygiene suites SKIP against a path that could
# not exist - which the gate counts against itself, so the failure was at least
# loud. Normalised here, and handed on in the form the suites expect.
STUDY <- local({
  v <- Sys.getenv("STUDY_FOLDER", unset = "")
  if (!nzchar(v)) file.path(REPO, "Jul 28")
  else if (startsWith(v, "/")) v
  else file.path(REPO, v)
})
Sys.setenv(STUDY_FOLDER = sub(paste0("^", REPO, "/"), "", STUDY))

# suite -> the failures it is allowed to have, by identity. Absent means none.
EXPECTED_FAILURES <- list(
  "validation/port/lot.R" = c(
    # The line COUNT is part of the identity, not decoration. Without it a pin
    # reads "this file differs", which stays true however much more of it
    # diverges, so edits to an already-pinned file ride in unexamined. A count
    # moves when the divergence set moves, and re-pinning is a conscious act.
    # Counted over comment-stripped code, so prose does not churn it.
    "03_mma_map.R: differs beyond the approved deviations in 217 line(s)",
    "05_sct.R: differs beyond the approved deviations in 11 line(s)",
    "04_lot1_base.R: differs from 02_lot1.R in 127 line(s)",
    "05b_lot1_sct.R: differs beyond the approved deviations in 148 line(s)",
    "06_lot1_end.R: differs beyond the approved deviations in 205 line(s)",
    "08_persist.R: differs beyond the approved deviations in 111 line(s)",
    "10_lot2_5_base.R: differs from R/lot2_5_base.R in 823 line(s)")
)

# How one suite's output is read. Its own suite is validation/hygiene/
# gate_semantics.R, which holds it to failing on each green it must not give.
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

# WHICH suites, not how many. The list above is discovered from disk, so
# deleting a package deletes its suite and the gate goes green over a smaller
# repository - the one failure mode a green count cannot show you. That is not
# hypothetical: two packages were removed from the study folder in one commit
# and took 99 assertions with them, and nothing here would have objected.
#
# So the set is pinned the way EXPECTED_FAILURES is pinned - by identity, and
# failing in BOTH directions. A suite that disappears is the case this exists
# for. A suite that appears fails too, because a list nobody has to update is a
# list that stops describing anything; adding the name is the conscious act.
#
# Study-folder entries are relative to the study folder, and keyed by which
# delivery they describe, because STUDY_FOLDER can be repointed at another one
# and the deliveries do not have the same shape. "Aug 14" is a fork of "Jul 28"
# with the returning-agent rule changed; it still carries the packages Jul 28
# has since moved out, so one flat list would refuse whichever delivery it was
# not written for.
EXPECTED_SUITES <- list(
  "Jul 28" = c(
    "analysis/outcomes/tests/test_runner.R",
    "analysis/questions/tests/test_setup.R",
    "exploration/lot/tests/test_benchmarks.R",
    "exploration/lot/tests/test_definitions.R",
    "exploration/lot/tests/test_melphalan.R",
    "exploration/lot/tests/test_sensitivity.R",
    "exploration/lot/tests/test_stockpiling.R",
    "exploration/melphalan/run_melp_scenarios.R",
    "exploration/melphalan/tests/test_aug1_melp.R",
    "lot/engine/tests/test_line_criteria.R",
    "lot/engine/tests/test_runner.R",
    "lot/qc/tests/test_lot_qc.R",
    "lot/validation/tests/test_vignettes.R",
    "ndmm/tests/test_runner.R",
    "ndmm/tests/test_same_as_overall.R",
    "ndmm/tests/test_subsequent.R",
    "overall/tests/test_runner.R",
    "reporting/dashboard/tests/test_runner.R"),
  "Aug 14" = c(
    "lot/dashboard/tests/test_runner.R",
    "lot/engine/tests/test_line_criteria.R",
    "lot/engine/tests/test_runner.R",
    "lot/melphalan/run_melp_scenarios.R",
    "lot/melphalan/tests/test_aug1_melp.R",
    "lot/outcomes/tests/test_runner.R",
    "lot/qc/tests/test_lot_qc.R",
    "lot/questions/tests/test_setup.R",
    "lot/safety/tests/test_safety_codelists.R",
    "lot/tools/tests/test_remove_steroids.R",
    "lot/validation/tests/test_benchmarks.R",
    "lot/validation/tests/test_definitions.R",
    "lot/validation/tests/test_melphalan.R",
    "lot/validation/tests/test_sensitivity.R",
    "lot/validation/tests/test_stockpiling.R",
    "lot/validation/tests/test_vignettes.R",
    "ndmm/tests/test_runner.R",
    "ndmm/tests/test_same_as_overall.R",
    "ndmm/tests/test_subsequent.R",
    "overall/tests/test_runner.R"))

# The repo-side suites are the same whichever delivery is being gated.
EXPECTED_HERE <- c(
  "hygiene/codelist_code_types.R",
  "hygiene/gate_semantics.R",
  "hygiene/lot_contract_binding.R",
  "hygiene/lot_selfcontained.R",
  "hygiene/sql_splices.R",
  "hygiene/study_folder_standalone.R",
  "port/lot.R",
  "port/ndmm.R",
  "port/overall.R")

DELIVERY <- basename(STUDY)
if (is.null(EXPECTED_SUITES[[DELIVERY]])) {
  cat("\n  No pinned suite list for delivery '", DELIVERY, "'. Add one to\n",
      "  EXPECTED_SUITES in this file, so a suite that disappears from it is\n",
      "  still caught.\n\n", sep = "")
  quit(status = 1L)
}

found <- c(sub(paste0("^", STUDY, "/"), "", suites[startsWith(suites, paste0(STUDY, "/"))]),
           sub(paste0("^", HERE, "/"), "",  suites[startsWith(suites, paste0(HERE, "/"))]))
want  <- c(EXPECTED_SUITES[[DELIVERY]], EXPECTED_HERE)
gone  <- setdiff(want, found)
extra <- setdiff(found, want)
if (length(gone) || length(extra)) {
  cat("\n", strrep("=", 74), "\n", sep = "")
  cat("  THE SUITE LIST HAS MOVED\n")
  cat(strrep("=", 74), "\n", sep = "")
  for (s in gone)  cat("  MISSING  ", s, "\n", sep = "")
  for (s in extra) cat("  NEW      ", s, "\n", sep = "")
  cat("\n  A missing suite is a check that stopped running, and a green count\n")
  cat("  below would be green over less of the repository than last time. A new\n")
  cat("  one only needs adding to EXPECTED_SUITES in this file. Either way the\n")
  cat("  list is edited deliberately, not discovered.\n\n")
  quit(status = 1L)
}

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
