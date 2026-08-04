#!/usr/bin/env Rscript
# One Domino Job: full pipeline, strict cohort-design verification, then the
# combined dashboard. Runs run_pipeline.R and, only if it exits 0, verifies that
# the persisted Overall cohort is the parent Step-6 denominator. It then runs
# 07_combined_dashboard.R (Summary + Overall + NDMM) and verifies that the
# materialized NDMM output matches all six required gates. Any failure fails the
# Job rather than silently publishing a broader/degraded cohort.
#
#   Domino Job command:  Rscript /mnt/code/.../run_all.R
#   Set DATABRICKS_PWD as a Domino env var/secret. Run-control env
#   vars (FORCE_RERUN, SKIP_*) still work and win over the CSV.
#
# To run the standalone LOT1-5 detail dashboard on its own (without
# Overall/NDMM cohorts), invoke 04_lot_detail_dashboard.R directly.

.d <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(a)) dirname(normalizePath(sub("^--file=", "", a[1]))) else getwd()
})

# Honour pipeline_inputs.csv BEFORE resolving OUTPUT_DIR / the log path,
# so the combined log lands where the stages write their outputs.
if (file.exists(file.path(.d, "R", "load_inputs.R"))) {
  source(file.path(.d, "R", "load_inputs.R"))
  load_pipeline_inputs(c(.d, dirname(.d)))
}

.env_bool <- function(name, default = "FALSE") {
  x <- toupper(trimws(Sys.getenv(name, unset = default)))
  x %in% c("TRUE", "T", "1")
}

# One combined log for the whole Job (pipeline stages + dashboard).
if (!nzchar(Sys.getenv("PIPELINE_LOG_FILE"))) {
  od <- Sys.getenv("OUTPUT_DIR", unset = "/mnt/artifacts/results")
  try(dir.create(od, showWarnings = FALSE, recursive = TRUE), silent = TRUE)
  probe <- tryCatch({
    pf <- file.path(od, paste0(".logprobe_", Sys.getpid()))
    ok <- isTRUE(file.create(pf)); ex <- file.exists(pf)
    if (ex) unlink(pf)
    ok && ex
  }, error = function(e) FALSE)
  if (!dir.exists(od) || !isTRUE(probe)) {
    cat(sprintf("[run_all] OUTPUT_DIR '%s' is not writable; logging to tempdir().\n", od))
    od <- tempdir()
  }
  lf <- file.path(od, paste0("pipeline_run_",
          format(Sys.time(), "%Y%m%d_%H%M%S"), ".log"))
  Sys.setenv(PIPELINE_LOG_FILE = lf)
  cat(sprintf("[run_all] combined run log -> %s\n", lf))
}

run_child <- function(script, args = character(0), label = script) {
  rc <- system2("Rscript", c(file.path(.d, script), args), stdout = "", stderr = "")
  if (rc != 0) stop(sprintf("%s failed (exit %d).", label, rc))
  invisible(rc)
}

# 1) Build/reuse parent + LOT outputs.
run_child("run_pipeline.R", label = "run_pipeline.R")

# 2) Before dashboard generation, fail if a stale Step-7/10 parent cohort was
#    reused or if required NDMM inputs/codelists are unavailable.
run_child("verify_ndmm_design.R", "--pre-dashboard",
          label = "verify_ndmm_design.R --pre-dashboard")

# 3) Build combined dashboard. Record the current log length so the strict
#    skipped-gate scan examines only lines appended by this dashboard pass.
log_file <- Sys.getenv("PIPELINE_LOG_FILE", unset = "")
log_before <- if (nzchar(log_file) && file.exists(log_file))
  length(readLines(log_file, warn = FALSE)) else 0L
run_child("07_combined_dashboard.R", label = "07_combined_dashboard.R")

if (.env_bool("NDMM_FAIL_ON_SKIPPED_GATE", "TRUE") &&
    nzchar(log_file) && file.exists(log_file)) {
  all_lines <- readLines(log_file, warn = FALSE)
  new_lines <- if (length(all_lines) > log_before)
    all_lines[(log_before + 1L):length(all_lines)] else character(0)
  patterns <- c(
    "belantamab exclusion skipped",
    "MM-tx pre-LOT1 exclusion skipped",
    "other-cancer pre-LOT1 exclusion skipped",
    "pregnancy exclusion skipped"
  )
  hit <- vapply(patterns, function(p) any(grepl(p, new_lines, ignore.case = TRUE, fixed = TRUE)), logical(1))
  if (any(hit)) {
    stop("NDMM dashboard ran with required gate(s) skipped: ",
         paste(patterns[hit], collapse = "; "),
         ". Primary output is invalid; fix inputs and rerun.")
  }
}

# 4) Verify the persisted NDMM flags/table: all six fields non-null, final
#    patient count equals NDMM_LOT_LONG_FILT, and LOT1 starts respect 2017-01-01.
run_child("verify_ndmm_design.R", "--post-dashboard",
          label = "verify_ndmm_design.R --post-dashboard")

cat("[run_all] Overall Step-6 and NDMM six-gate verification passed.\n")
