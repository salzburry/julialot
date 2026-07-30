#!/usr/bin/env Rscript
# Same steps, same order, same SQL as apr_30_2026 - compared as exact strings.
# Two steps deliberately differ; see CHANGED below. Skips when apr_30_2026 is
# absent, which is normal in prod.
#
#   Rscript "Jul 28/overall/tests/test_same_as_source.R"

here <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (!length(a)) getwd()
  else dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]), fixed = TRUE)))
})
ROOT <- dirname(here)
# apr_30_2026 sits at the repo root; walk up until we find it.
APR <- Sys.getenv("APR30_DIR", unset = "")
if (!nzchar(APR)) {
  d <- ROOT
  repeat {
    if (dir.exists(file.path(d, "apr_30_2026"))) { APR <- file.path(d, "apr_30_2026"); break }
    up <- dirname(d); if (identical(up, d)) break
    d <- up
  }
}

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
  # These two differ on purpose. med_claim_header used to collapse lines with
  # max(POS) and then test it, so POS 21 + 81 came out 81 and stopped being
  # inpatient - 348 patients mislabelled, 7 dropped. Flagged per line now.
  CHANGED <- c("07a_med_claim_header", "08a_mm_dx_events_all")
  for (i in seq_along(a)) {
    same_sql <- identical(as.character(a[[i]]$sql), as.character(b[[i]]$sql))
    if (a[[i]]$name %in% CHANGED) {
      ok(!same_sql, paste0(a[[i]]$name, ": differs from source, as intended"))
    } else {
      ok(same_sql, paste0(a[[i]]$name, ": SQL identical"))
    }
    ok(identical(as.character(a[[i]]$qc), as.character(b[[i]]$qc)),
       paste0(a[[i]]$name, ": QC identical"))
  }

  # ...and they differ in the intended way, not some other way.
  hdr <- as.character(b[[match("07a_med_claim_header",
                               vapply(b, `[[`, character(1), "name"))]]$sql)
  ev  <- as.character(b[[match("08a_mm_dx_events_all",
                               vapply(b, `[[`, character(1), "name"))]]$sql)
  ok(grepl("AS line_inpatient", hdr, fixed = TRUE),
     "med_claim_header flags each line before aggregating")
  ok(grepl("h.line_inpatient = 1 OR cf.CONF_ID IS NOT NULL", ev, fixed = TRUE),
     "inpatient_flg reads the aggregated line flag")
  ok(!grepl("h.POS IN ('21', '51', '61')", ev, fixed = TRUE),
     "no step tests a collapsed max(POS) any more")
  # Both operands are 0/1 or IS NOT NULL, so NOT(...) can never be NULL and a
  # claim can no longer end up neither inpatient nor outpatient.
  ok(grepl("CASE WHEN NOT (h.line_inpatient = 1 OR cf.CONF_ID IS NOT NULL)",
           ev, fixed = TRUE),
     "outpatient_flg cannot evaluate to NULL")
}

# Copies, so they must not have drifted. criteria_attrition.R and db_utils.R
# are left out - both carry fixes the source doesn't have, and neither touches
# build_steps().
for (f in c("config_prompts.R", "codelists.R", "load_inputs.R"))
  ok(identical(readLines(file.path(ROOT, "R", f), warn = FALSE),
               readLines(file.path(APR, "R", f), warn = FALSE)),
     paste0("R/", f, " is a byte-identical copy"))
cat("\n", strrep("-", 52), "\n", sep = "")
cat(sprintf("%d passed, %d failed\n", pass, fail))
if (fail > 0L) quit(status = 1L)
