#!/usr/bin/env Rscript
# Compare step order, QC, and unchanged SQL with apr_30_2026.
# Some steps deliberately differ; see CHANGED below.
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
              c("load_inputs.R", "config_prompts.R",
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
  # These steps now use the line-level inpatient flag.
  CHANGED <- c("07a_med_claim_header", "08a_mm_dx_events_all",
               "22_other_malig_flag",
               # a code that is only punctuation normalizes to "" and would
               # match blank claim values - for NDC, every claim with no NDC
               "01_mm_dx_codes", "03_mm_therapy_codes", "04_preg_codes",
               "05_clintrial_codes",
               "06_other_malig_codes", "18_therapy_events")
  # Compare what runs, not the comments around it. A tidied -- comment inside a
  # SQL string is not a change to the study logic.
  strip <- function(x) {
    l <- strsplit(as.character(x), "\n")[[1]]
    paste(trimws(l[!grepl("^\\s*--", l)]), collapse = "\n")
  }
  for (i in seq_along(a)) {
    same_sql <- identical(strip(a[[i]]$sql), strip(b[[i]]$sql))
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
  om  <- as.character(b[[match("22_other_malig_flag",
                                vapply(b, `[[`, character(1), "name"))]]$sql)
  ok(grepl("max(CASE WHEN POS IN ('21', '51', '61')", hdr, fixed = TRUE) &&
     grepl("THEN 1 ELSE 0 END) AS line_inpatient", hdr, fixed = TRUE),
      "med_claim_header flags each line before aggregating")
  ok(grepl("h.line_inpatient = 1 OR cf.CONF_ID IS NOT NULL", ev, fixed = TRUE),
      "inpatient_flg reads the aggregated line flag")
  ok(grepl("h.line_inpatient = 1 OR cf.CONF_ID IS NOT NULL", om, fixed = TRUE),
     "other-malignancy setting reads the same line flag")
  all_sql <- vapply(b, function(step) as.character(step$sql), character(1))
  ok(!any(grepl("h.POS IN ('21', '51', '61')", all_sql, fixed = TRUE)) &&
     !any(grepl("h.TOS_CD IN (", all_sql, fixed = TRUE)),
     "no step tests collapsed POS or TOS_CD")
  ok(grepl("CASE WHEN NOT (h.line_inpatient = 1 OR cf.CONF_ID IS NOT NULL)",
            ev, fixed = TRUE),
      "outpatient_flg cannot evaluate to NULL")

  # Each code-list filter is present, and BOTH NDC joins are guarded. Asserting
  # only "differs from source" let the Rx join ship without its guard.
  sql_of <- function(nm) as.character(b[[match(nm, vapply(b, `[[`, character(1),
                                                          "name"))]]$sql)
  BLANK <- list("01_mm_dx_codes"       = "regexp_replace(dx, '[^A-Za-z0-9]', '') <> ''",
                "03_mm_therapy_codes"  = "regexp_replace(CL_CODE, '[^A-Za-z0-9]', '') <> ''",
                "04_preg_codes"        = "regexp_replace(code, '[^A-Za-z0-9]', '') <> ''",
                "05_clintrial_codes"   = "regexp_replace(code, '[^A-Za-z0-9]', '') <> ''",
                "06_other_malig_codes" = "regexp_replace(dx, '[^A-Za-z0-9]', '') <> ''")
  for (nm in names(BLANK))
    ok(grepl(BLANK[[nm]], sql_of(nm), fixed = TRUE),
       paste0(nm, ": drops codes that normalize to blank"))
  te <- sql_of("18_therapy_events")
  ok(lengths(regmatches(te, gregexpr("regexp_replace(c.code, '[^0-9]', '') <> ''",
                                     te, fixed = TRUE))) == 2,
     "both NDC joins require digits in the code (medical and Rx)")
}

# Copies, so they must not have drifted. Local comments may differ.
code_lines <- function(path) {
  lines <- readLines(path, warn = FALSE)
  lines[!grepl("^[[:space:]]*#", lines)]
}
ok(identical(code_lines(file.path(ROOT, "R", "load_inputs.R")),
             code_lines(file.path(APR, "R", "load_inputs.R"))),
   "R/load_inputs.R has identical executable lines")

# config_prompts.R is deliberately smaller - the interactive prompts and the
# finalize_cfg round trip did nothing under Rscript. What still has to match is
# the study window, which CONTRACT does not cover.
apr_cfg <- apr$cfg_defaults
for (k in c("study_start", "study_end", "id_start", "id_end",
            "baseline_days", "gap_days", "dx_window_30", "dx_window_60",
            "dx_window_90"))
  ok(identical(new$cfg_defaults[[k]], apr_cfg[[k]]),
     paste0("cfg_defaults$", k, " = ", format(apr_cfg[[k]]), ", same as apr_30_2026"))
cat("\n", strrep("-", 52), "\n", sep = "")
cat(sprintf("%d passed, %d failed\n", pass, fail))
if (fail > 0L) quit(status = 1L)
