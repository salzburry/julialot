#!/usr/bin/env Rscript
# The merge gate, held to failing on the greens it used to give wrongly.
#
#   Rscript validation/hygiene/gate_semantics.R
#
# A gate cannot demonstrate that it catches things by passing. Every bug this
# one has had was a false green - a suite that did not run, a suite that died
# after printing a clean summary, a regression hidden behind a fix - and none of
# them would show up as a red build. So the reading is separated into
# _gate_logic.R and driven here over synthetic suite output, where a green can
# be asserted to be wrong.

HERE <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                            fixed = TRUE))) else getwd()
})
VAL <- dirname(HERE)
source(file.path(VAL, "_gate_logic.R"))

pass <- 0L; fail <- 0L
ok <- function(cond, what) {
  if (isTRUE(cond)) { pass <<- pass + 1L; cat("  ok     ", what, "\n") }
  else              { fail <<- fail + 1L; cat("  FAIL   ", what, "\n") }
}

clean <- c("  ok      something", "", "12 passed, 0 failed")
one   <- c("  ok      something", "  FAIL   step_a.R: differs, at source line 12",
           "", "11 passed, 1 failed")

cat("\n-- a suite that passed, passes --\n")
v <- gate_verdict(clean, 0L)
ok(isTRUE(v$ok), "a clean summary and exit 0")
ok(identical(v$passed, 12L), "...and its assertions are counted")

cat("\n-- a suite that did not run is not a suite that passed --\n")
# Was: skipped incremented a counter the exit status never read.
v <- gate_verdict(character(0), 3L)
ok(!v$ok, "a skip fails the gate rather than being noted beside a green")
ok(isTRUE(v$skipped), "...and is still reported as a skip, not as a failure")

cat("\n-- a clean summary is not the same as a clean exit --\n")
# Was: a nonzero exit was ignored whenever a summary parsed.
ok(!gate_verdict(clean, 1L)$ok,
   "zero failures and a nonzero exit: the suite died after its last assertion")
ok(!gate_verdict(one, 0L, "step_a.R: differs")$ok,
   "a pinned failure and exit 0: the suite is no longer reporting it")
ok(isTRUE(gate_verdict(one, 1L, "step_a.R: differs")$ok),
   "...and the honest pair - one pinned failure, exit 1 - passes")

cat("\n-- pinned by identity, because a count hides a swap --\n")
# Was: six failures pinned as the number 6. Fix one, add one, still six.
swapped <- c("  FAIL   step_b.R: differs, at source line 3", "", "11 passed, 1 failed")
v <- gate_verdict(swapped, 1L, "step_a.R: differs")
ok(!v$ok, "one pinned failure fixed and one new one, same count, still red")
ok(any(grepl("^new: step_b", v$reasons)), "...the new one is named")
ok(any(grepl("stale", v$reasons)), "...and so is the pin that is now a lie")

cat("\n-- the pin survives an edit above the failing line --\n")
moved <- c("  FAIL   step_a.R: differs, at source line 999", "", "11 passed, 1 failed")
ok(isTRUE(gate_verdict(moved, 1L, "step_a.R: differs")$ok),
   "the same failure at a different source line is the same failure")

cat("\n-- the word FAIL in a log line is not a failure --\n")
# A suite that exercises a failure path prints the word as data. Matching it
# anywhere in the line reported a passing suite as failing.
logged <- c("2026-01-01 00:00:00   FAIL  attrition - SYNTAX", "", "12 passed, 0 failed")
ok(isTRUE(gate_verdict(logged, 0L)$ok),
   "a timestamped log line mentioning FAIL leaves the suite green")

cat("\n-- and it says so when it cannot tell which failures it has --\n")
mismatch <- c("  FAIL   step_a.R: differs", "", "9 passed, 3 failed")
v <- gate_verdict(mismatch, 1L, "step_a.R: differs")
ok(!v$ok, "three failures reported and one marked: not something to pin")
ok(any(grepl("cannot tell", v$reasons)), "...and it says that rather than guessing")

cat("\n-- no summary at all --\n")
ok(!gate_verdict(c("Error: could not open connection"), 1L)$ok,
   "a suite that produced no summary fails")

cat("\n-- the pins in run_gate.R are the ones port/lot.R actually has --\n")
# A pin for a suite that no longer exists, or a typo in an identity, would show
# up as "stale" on every run - but only if someone runs it. Checked here so a
# mis-typed pin is a red build rather than a permanently ignored line.
g <- paste(readLines(file.path(VAL, "run_gate.R"), warn = FALSE), collapse = "\n")
pinned <- regmatches(g, gregexpr('"[^"]+: differs[^"]*"', g))[[1]]
pinned <- gsub('"', "", pinned)
ok(length(pinned) == 6L, paste0("six failures are pinned (", length(pinned), ")"))
ok(!any(duplicated(pinned)), "...and none is pinned twice")
ok(all(fail_id(paste0("  FAIL   ", pinned, ", at source line 1")) == pinned),
   "...and each is written in the form a FAIL line reduces to")

cat("\n", strrep("-", 52), "\n", sep = "")
cat(sprintf("%d passed, %d failed\n", pass, fail))
if (fail > 0L) quit(status = 1L)
