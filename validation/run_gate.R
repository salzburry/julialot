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
#
# "Absolute" has three shapes, not one. A leading "/" is the POSIX case and was
# the only one recognised, so on Windows a drive path or a UNC share was taken
# for a relative name and joined to the repo root - C:/work/Jul 28 became
# <repo>/C:/work/Jul 28, which resolves to nothing and lands back in the SKIP
# the paragraph above describes. R's own file.path uses "/" on every platform,
# so a backslash form is normalised before it is tested rather than matched
# separately.
STUDY <- local({
  v <- Sys.getenv("STUDY_FOLDER", unset = "")
  vv <- chartr("\\", "/", v)
  absolute <- startsWith(vv, "/") ||        # POSIX, and the UNC //server/share
    grepl("^[A-Za-z]:/", vv)                # a Windows drive letter
  # No default. It used to be "Jul 28", and that folder stopped carrying the
  # LOT package when the delivery folders were made - so the gate CI runs, with
  # no environment set, has been gating a delivery whose suites reference an
  # engine that is not there. Thirteen failures, every run, for as long as that
  # has been true.
  #
  # Guessing instead would be worse in the same way it is worse in the
  # harnesses: three folders here look like deliveries and two carry an engine,
  # so any rule that picks one picks it silently. Which delivery is being gated
  # is a thing the caller knows and this file does not.
  if (!nzchar(v))
    stop("Set STUDY_FOLDER to the delivery to gate - the folder name, e.g.\n",
         "  STUDY_FOLDER='Sep 10' Rscript validation/run_gate.R\n",
         "It had a default, and the default outlived the folder it named.",
         call. = FALSE)
  else if (absolute) vv
  else file.path(REPO, v)
})
Sys.setenv(STUDY_FOLDER = sub(paste0("^", REPO, "/"), "", STUDY))

# suite -> the failures it is allowed to have, by identity. Absent means none.
EXPECTED_FAILURES <- list(
  "validation/port/lot.R" = c(
    # The COUNT and the digest after it are part of the identity, not
    # decoration. Without them a pin reads "this file differs", which stays
    # true however much more of it diverges, so edits to an already-pinned
    # file ride in unexamined. The count alone is not enough either: repairing
    # one divergence and adding another of the same size keeps it. The digest
    # is taken over the differing lines themselves, so any change to WHICH
    # lines differ moves it, and re-pinning is a conscious act. Both are read
    # over comment-stripped code, so prose does not churn them.
    # permissible_subs is written out rather than left a temporary view, so the
    # QC package can read which drugs are one agent instead of guessing.
    "01_codelists.R: differs beyond the approved deviations in 2 line(s) [6d3ee77f]",
    "03_mma_map.R: differs beyond the approved deviations in 217 line(s) [1bc3749e]",
    "05_sct.R: differs beyond the approved deviations in 11 line(s) [6457f58f]",
    # lot1_regimen_cutoff, the regimen window and the per-drug episode scan
    # both bounded by it, the same-day add-med tie-break as a row hash rather
    # than a seeded rand, the short-course boundary gate as an anti-join, and
    # the melphalan verdict built here rather than judged again for the break
    # test alone - the same helper 06 reads, bound one statement earlier and
    # WITHOUT the half of it that reads lot1_base, which this statement is in
    # the middle of creating.
    "04_lot1_base.R: differs from 02_lot1.R in 148 line(s) [435b8d49]",
    # LOT1_AUTO_HOLD_DT, and a tandem that needs a clear gap between its two
    # transplants.
    "05b_lot1_sct.R: differs beyond the approved deviations in 176 line(s) [524fd363]",
    # The SCT_AUTO_CONT branch and the end_natural CTE it compares against, the
    # post-run-out trigger as existence tests, and the run-out guard on LOT1's
    # own window with the tandem gap.
    "06_lot1_end.R: differs beyond the approved deviations in 245 line(s) [09c4a054]",
    # Re-pinned from 111 [4ef6f10b]. The two delete-then-insert pairs became
    # single units: run_step takes both statements together with
    # retry_as_unit = TRUE, so a retry of the metadata or QC write cannot leave
    # the DELETE applied and the INSERT not. Same change as the per-line append
    # in 10_lot2_5_base.R below, and the reason both counts moved.
    #
    # It moved when the delivery folders were made and has been unreportable
    # ever since: this suite resolved the engine under a folder that no longer
    # had one, and skipped. The count drifted while nothing could say so, which
    # is the state a pin exists to prevent.
    "08_persist.R: differs beyond the approved deviations in 112 line(s) [49276166]",
    # SCT_AUTO_CONT and end_natural at LOT2-5, LOT{n}_AUTO_HOLD_DT, auto_cand
    # reading the previous line's own window, the regimen cutoff, and the tandem
    # gap, the add-med tie-break as a row hash, the short-course and not-new
    # gates as anti-joins rather than correlated subqueries in a join
    # condition, a held melphalan course kept out of the line's regimen, and
    # the LOT_LONG publish lifted into publish_lot_long() so the drop that
    # follows it can be refused without failing a build that already wrote a
    # complete LOT_LONG, and the short-course break test told that this
    # statement already carries the verdict, so a confirmed course stops a
    # run-out chain. Re-pinned deliberately, which is what this list is for.
    # Re-pinned from 952 [3b7c6844]. Three lines: the per-line append is now
    # "DELETE FROM <stage> WHERE LOT_NUM = n" and the INSERT as one
    # retry_as_unit step, so retrying a line's append cannot append it twice.
    # The rest of the delta to that pin was SQL comment prose.
    #
    # Re-pinned to 955 [04f35190] - the value it had before 4.6 reached the
    # fold, and back to it because the guard now rides ENTIRELY inside
    # fragments this file registers. The hold, the regimen union, the working
    # base set and the added-medication test each refuse an ALLO-started line,
    # and none of them needs allo_lot_span any more: the span sets how long
    # the line runs, not whether it names anything. So the splices carry no
    # setting, the undeviated text is what it was, and no line was added or
    # removed.
    "10_lot2_5_base.R: differs from R/lot2_5_base.R in 955 line(s) [04f35190]")
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
                 # Not under tests/, and advertised in a delivery's README as
                 # a check that exits non-zero if any of the study team's worked
                 # scenarios moves. A check nothing runs is a check in name
                 # only, so it is named here rather than left to be remembered.
                 # Jul 28 no longer has one - the worked scenarios belonged to
                 # the five-branch melphalan rule, which was retired - but
                 # Aug 14 still does, and STUDY_FOLDER can point at either.
                 grepl("/run_melp_scenarios\\.R$", suites)]
suites <- suites[!grepl("testutil\\.R$|/_|run_gate\\.R$|run_all\\.R$", suites)]
# A tests/ directory holds suites AND the fixtures and row-runners they source.
# "Everything under tests/" ran the fixtures as if they were suites: a file
# that defines data and asserts nothing exits 0 having checked nothing, and the
# gate counted it as a suite that passed. Sep 10 has seven such helpers -
# exec_cases.R, returns_fixture.R and the rest - which is how a delivery with
# ten real suites would have been pinned with seventeen.
#
# A suite is named for what it is. Jul 28 and Aug 14 discover exactly the same
# files under this rule as without it, so it tightens without moving them.
suites <- suites[grepl("/(test_[^/]*|run_tests|run_melp_scenarios)\\.R$", suites) |
                 grepl("/validation/(port|hygiene)/", suites)]
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
    "exploration/lot/tests/test_foldin.R",
    "exploration/lot/tests/test_sensitivity.R",
    "exploration/lot/tests/test_stockpiling.R",
    # The five lot/ suites this list used to carry are not here any more. The
    # LOT package moved out of Jul 28 into a delivery of its own, and the pin
    # was not moved with it - so the gate reported five MISSING suites and
    # exited non-zero on every run, for the DEFAULT delivery, which is the one
    # CI gates. A red that is the pin's own bookkeeping trains a reader to
    # scroll past it, and that is the state it was in.
    #
    # They are pinned under "Sep 10" below, which is where they live. Removing
    # them here is the conscious act this list asks for, not a suite quietly
    # dropping out: the same five names appear in the entry above.
    "ndmm/tests/test_runner.R",
    "ndmm/tests/test_same_as_overall.R",
    "ndmm/tests/test_subsequent.R",
    "overall/tests/test_runner.R",
    "reporting/dashboard/tests/test_runner.R"),
  # The study delivery, self-contained: the cohort, the lines, the variables,
  # the shells and the dashboard in one folder, with nothing resolved outside
  # it. Sep 10 was the same five stages minus the cohort, which was still in
  # Jul 28 - so three repo-side suites could not run against it and the folder
  # promised a stage 1 it did not carry.
  "Sep 16" = c(
    "TFLS/tests/test_tfls.R",
    "dashboard/tests/run_tests.R",
    "lot/engine/tests/test_line_criteria.R",
    "lot/engine/tests/test_runner.R",
    "lot/melphalan/tests/test_melp_simple.R",
    "lot/qc/tests/test_foldin_trace.R",
    "lot/qc/tests/test_lot_qc.R",
    "lot/qc/tests/test_trace_returns.R",
    "lot/validation/tests/test_vignettes.R",
    "ndmm/tests/test_runner.R",
    "ndmm/tests/test_subsequent.R",
    "variables/tests/run_tests.R"),
  "Sep 10" = c(
    "TFLS/tests/test_tfls.R",
    "dashboard/tests/run_tests.R",
    "lot/engine/tests/test_line_criteria.R",
    "lot/engine/tests/test_runner.R",
    "lot/melphalan/tests/test_melp_simple.R",
    "lot/qc/tests/test_foldin_trace.R",
    "lot/qc/tests/test_lot_qc.R",
    "lot/qc/tests/test_trace_returns.R",
    "lot/validation/tests/test_vignettes.R",
    "variables/study223926/tests/run_tests.R"),
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
  "hygiene/emitted_sql_shape.R",
  "hygiene/gate_semantics.R",
  "hygiene/lot_contract_binding.R",
  "hygiene/lot_selfcontained.R",
  "hygiene/sql_splices.R",
  "hygiene/study_folder_standalone.R",
  "hygiene/vignette_catalogue_current.R",
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

bad <- 0L; total <- 0L; skipped <- 0L; n_a <- character(0)
for (i in seq_along(suites)) {
  out <- suppressWarnings(system2("Rscript", shQuote(suites[i]),
                                  stdout = TRUE, stderr = TRUE))
  st <- attr(out, "status"); st <- if (is.null(st)) 0L else st
  want <- EXPECTED_FAILURES[[rel[i]]]; want <- if (is.null(want)) character(0) else want
  v <- gate_verdict(out, st, want)
  total <- total + v$passed
  if (v$skipped) skipped <- skipped + 1L
  if (isTRUE(v$not_applicable)) n_a <- c(n_a, rel[i])
  if (v$ok) {
    cat(sprintf("  %-52s %s\n", rel[i],
        if (isTRUE(v$not_applicable)) "n/a   not part of this delivery"
        else sprintf("ok    %4d assertions%s", v$passed,
                if (v$pinned) sprintf("  (%d pinned failures)", v$pinned) else "")))
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
# Named, every time. A suite that checks a package this delivery does not carry
# is not a failure, but it is also not a check that ran - so it is listed
# rather than absorbed into a count nobody reads.
if (length(n_a))
  cat("  not part of this delivery, so not checked here: ",
      paste(n_a, collapse = ", "), "\n", sep = "")
if (bad > 0L) {
  cat("\n  Not green. A pinned failure that STOPPED failing is as much a problem\n")
  cat("  as a new one: the baseline in this file is then wrong, and the next\n")
  cat("  regression would land in the space it left.\n\n")
  quit(status = 1L)
}
cat("\n  Green.\n\n")
