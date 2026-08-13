# How the merge gate reads one suite's output. Separated from run_gate.R so it
# can be tested against synthetic output, because every bug this file has had
# was a green that should have been red - and a gate cannot demonstrate that on
# itself by passing.
#
# Sourced by run_gate.R and by validation/hygiene/gate_semantics.R. The leading
# underscore keeps it out of the suite list.

# A FAIL line reduced to what it is about. The trailing source line number is
# dropped because it moves with any edit above it: what identifies a failure is
# which step differs and how, not where in the file the differing line sits.
fail_id <- function(x) {
  x <- sub("^\\s*FAIL\\s+", "", x)
  x <- sub(",?\\s*at (source )?line [0-9]+\\s*$", "", x)
  trimws(x)
}

# out    - the suite's combined stdout/stderr, one element per line
# status - its process exit status
# want   - the failures it is pinned to have, by identity; character(0) for none
#
# Returns ok, the assertion count, and every reason it is not ok.
gate_verdict <- function(out, status, want = character(0)) {
  no <- function(...) list(ok = FALSE, passed = 0L, skipped = FALSE,
                           reasons = c(...))

  # A skipped suite proved nothing, and nothing in this gate needs a warehouse
  # connection - so a skip here is a suite that should have run and did not.
  if (identical(status, 3L))
    return(list(ok = FALSE, passed = 0L, skipped = TRUE,
                reasons = "SKIP - nothing in this gate needs a connection"))

  line <- grep("[0-9]+ passed, [0-9]+ failed", out, value = TRUE)
  if (!length(line))
    return(no(paste0("no summary line (exit ", status, ")")))

  last <- line[length(line)]
  p <- as.integer(sub("^\\D*([0-9]+) passed.*", "\\1", last))
  f <- as.integer(sub(".*passed, ([0-9]+) failed.*", "\\1", last))

  # Anchored on the marker the harnesses print, not on the word anywhere in the
  # line: a suite that exercises a failure path logs FAIL as data, and matching
  # that reports a passing suite as failing.
  marks <- fail_id(grep("^\\s*FAIL\\s", out, value = TRUE))
  got <- unique(marks)

  reasons <- character(0)
  # Pinned by identity, not by count. By count is a false green waiting to
  # happen: fix one pinned failure, introduce one regression, count unchanged.
  for (l in setdiff(got, want))
    reasons <- c(reasons, paste0("new: ", l))
  for (l in setdiff(want, got))
    reasons <- c(reasons, paste0("no longer fails, so the pin is stale: ", l))
  # The process status as well as the summary. A suite can print a clean
  # summary and then die - a stop() after the last assertion, a quit() on a
  # condition the summary does not cover - and reading only the summary calls
  # that a pass.
  if (!identical(status == 0L, identical(f, 0L)))
    reasons <- c(reasons, paste0("exit status ", status, " does not match ", f,
                                 " failure(s) in the summary"))
  # Identities against the reported count. If they disagree this cannot say
  # which failures it is looking at, so it says that rather than pinning a set
  # it did not fully read.
  if (!identical(length(marks), f))
    reasons <- c(reasons, paste0("summary says ", f, " failure(s), ",
                                 length(marks), " marked - cannot tell which"))

  list(ok = !length(reasons), passed = p, skipped = FALSE, reasons = reasons,
       pinned = length(want))
}
