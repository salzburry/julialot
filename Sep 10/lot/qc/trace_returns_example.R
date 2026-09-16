#!/usr/bin/env Rscript
# Render the returning-drug trace on the six fixture patients, so the shape
# of what trace_returns.R writes can be read before a run against the
# warehouse - one patient per kind of return, with the paragraph and the
# episode table each gets.
#
#   Rscript lot/qc/trace_returns_example.R      # writes examples/returns_trace_example.md
#
# No connection. The queries are the trace's own, run through DuckDB on
# tests/returns_fixture.R, and the suite (tests/test_trace_returns.R) holds
# the committed example to a fresh render, so it cannot drift from the code.
# Needs python3 with duckdb and sqlglot; without them it says so and writes
# nothing.

# When sourced by the suite, .script_dir is already set to this folder and
# the render below is not run; the suite calls returns_example_md() itself.
if (!exists(".script_dir", inherits = FALSE)) .script_dir <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                            fixed = TRUE))) else getwd()
})
source(file.path(.script_dir, "R", "checks.R"))
source(file.path(.script_dir, "R", "foldin_trace.R"))
source(file.path(.script_dir, "R", "return_trace.R"))
source(file.path(.script_dir, "tests", "exec_harness.R"))
source(file.path(.script_dir, "tests", "returns_fixture.R"))

returns_example_note <- paste0(
  "**This is a rendered example on six FIXTURE patients, not a run.** Each ",
  "patient is one shape the trace tells apart: a fold into 2L, an own return ",
  "inside 1L, an own return inside 2L, a return across a transplant-opened 2L ",
  "that opened 3L, a return from two lines back that opened 4L, and a drug ",
  "carried over inside a window (counted, not traced). A real run lists every ",
  "return in the warehouse's finished LOT run and samples the patients to trace.")

returns_example_md <- function(root = .script_dir) {
  p <- qc_params(RETURNS_SETTINGS, "fixture")
  p$gap <- qc_int(RETURNS_SETTINGS, "map_discon_gap_days")
  p$melp_days <- qc_int(RETURNS_SETTINGS, "melp_simple_course_days")
  returns_render_fixture(RETURNS_FIXTURE, RETURNS_FIXTURE_TOTALS, p, root,
                         run_id = "fixture", pfx = "example_", n = 12L,
                         kinds = RETURN_TRACE_KINDS, lines = NULL,
                         source_note = returns_example_note)
}

if (!interactive() && !isTRUE(getOption("returns.example.norun"))) {
  r <- returns_example_md()
  if (is.null(r) || identical(r, "skip")) {
    cat("duckdb or sqlglot is not installed, or the row runner is missing: nothing rendered.\n")
  } else {
    out <- file.path(.script_dir, "examples")
    dir.create(out, showWarnings = FALSE, recursive = TRUE)
    writeLines(r$md, file.path(out, "returns_trace_example.md"))
    cat("Wrote ", file.path(out, "returns_trace_example.md"), ": ",
        nrow(r$cands), " return row(s), ", length(r$ids), " patient(s) traced.\n", sep = "")
  }
}
