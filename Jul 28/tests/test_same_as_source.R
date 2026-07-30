#!/usr/bin/env Rscript
# =============================================================================
# test_same_as_source.R -- is the split identical to apr_30_2026?
# -----------------------------------------------------------------------------
#   Rscript "Jul 28/tests/test_same_as_source.R"
#
# This is a refactor, so there is exactly one thing to prove: the steps this
# folder builds are the same steps, in the same order, with the same SQL, as
# apr_30_2026/R/pipeline_steps.R builds from the same config.
#
# Not normalised, not whitespace-collapsed. Identical strings.
#
# It skips when apr_30_2026 is absent, which is the normal state in prod.
# =============================================================================

here <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (!length(a)) getwd()
  else dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]), fixed = TRUE)))
})
ROOT <- dirname(here)
REPO <- dirname(ROOT)
APR  <- Sys.getenv("APR30_DIR", unset = file.path(REPO, "apr_30_2026"))

pass <- 0L; fail <- 0L
ok <- function(cond, what) {
  if (isTRUE(cond)) { pass <<- pass + 1L; cat("  ok   ", what, "\n") }
  else              { fail <<- fail + 1L; cat("  FAIL ", what, "\n") }
}

if (!file.exists(file.path(APR, "R", "pipeline_steps.R"))) {
  cat("apr_30_2026 not present -- nothing to compare against. Skipping.\n")
  quit(status = 0L)
}

# glue is not installed everywhere; the templates only use {expr}, so a small
# stand-in keeps this runnable offline.
if (!requireNamespace("glue", quietly = TRUE)) {
  glue <- function(..., .envir = parent.frame()) {
    t <- paste0(..., collapse = "")
    m <- gregexpr("\\{[^{}]+\\}", t)[[1]]
    if (m[1] == -1L) return(t)
    len <- attr(m, "match.length"); out <- character(0); pos <- 1L
    for (i in seq_along(m)) {
      out <- c(out, substr(t, pos, m[i] - 1L),
               paste(as.character(eval(parse(
                 text = substr(t, m[i] + 1L, m[i] + len[i] - 2L)), .envir)),
                 collapse = ""))
      pos <- m[i] + len[i]
    }
    paste0(c(out, substr(t, pos, nchar(t))), collapse = "")
  }
  assign("glue", glue, envir = globalenv())
}

# Build the config once and use it for both sides.
env_of <- function(dir, files, extra = NULL) {
  e <- new.env(parent = globalenv())
  for (f in files) sys.source(file.path(dir, f), envir = e)
  if (!is.null(extra)) for (f in extra) sys.source(f, envir = e)
  e
}

apr <- env_of(file.path(APR, "R"),
              c("load_inputs.R", "config_prompts.R", "codelists.R",
                "db_utils.R", "criteria_attrition.R", "pipeline_steps.R"))
apr$load_pipeline_inputs(c(APR, dirname(APR)))
cfg <- apr$cfg_defaults
cfg$outpatient_window <- apr$validate_outpatient_window(cfg$outpatient_window)

# This folder. Same helper files, but our split pipeline_steps.R + steps/.
new <- env_of(file.path(ROOT, "R"),
              c("load_inputs.R", "config_prompts.R", "codelists.R",
                "db_utils.R", "criteria_attrition.R", "pipeline_steps.R"))
new$load_phase_steps(file.path(ROOT, "R", "steps"))

a <- Filter(Negate(is.null), apr$build_steps(cfg, new.env()))
b <- Filter(Negate(is.null), new$build_steps(cfg, new.env()))

cat("\ncomparing ", length(a), " steps, config: window ", cfg$outpatient_window,
    "d, study ", cfg$study_start, " .. ", cfg$study_end, "\n\n", sep = "")

ok(length(a) == length(b),
   paste0("same number of steps (", length(a), " vs ", length(b), ")"))

if (length(a) == length(b)) {
  ok(identical(vapply(a, `[[`, character(1), "name"),
               vapply(b, `[[`, character(1), "name")),
     "same step names, in the same order")
  for (i in seq_along(a)) {
    ok(identical(as.character(a[[i]]$sql), as.character(b[[i]]$sql)),
       paste0(a[[i]]$name, ": SQL identical"))
    ok(identical(as.character(a[[i]]$qc), as.character(b[[i]]$qc)),
       paste0(a[[i]]$name, ": QC identical"))
  }
}

# These helper files are copies, so they must not have drifted.
#
# criteria_attrition.R is deliberately NOT in this list. It carries two fixes
# the source doesn't have: the FINAL COHORT row now names the configured
# window and reads that count off the cohort table, and a failed persist stops
# the run instead of warning. build_criteria_catalog() and build_criteria_sql()
# are untouched, so the step SQL compared above is unaffected.
for (f in c("config_prompts.R", "db_utils.R", "codelists.R", "load_inputs.R"))
  ok(identical(readLines(file.path(ROOT, "R", f), warn = FALSE),
               readLines(file.path(APR, "R", f), warn = FALSE)),
     paste0("R/", f, " is a byte-identical copy"))
cat("\n", strrep("-", 52), "\n", sep = "")
cat(sprintf("%d passed, %d failed\n", pass, fail))
if (fail > 0L) quit(status = 1L)
