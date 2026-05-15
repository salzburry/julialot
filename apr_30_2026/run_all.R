#!/usr/bin/env Rscript
# ============================================================
# run_all.R - one Domino Job: full pipeline, then LOT1-5 dashboard
# ============================================================
# Runs run_pipeline.R, and only if it succeeds (exit 0) runs
# lot_long_dashboard.R. BOTH failures fail the Job (non-zero exit).
# pipeline_inputs.csv is loaded here first so the combined log lands
# in the same OUTPUT_DIR the stages write to.
#
#   Domino Job command:  Rscript /mnt/code/.../run_all.R
#   (set DATABRICKS_PWD as a Domino env var / secret; run-control
#    env vars like FORCE_RERUN / SKIP_* still work and win over the CSV)
# ============================================================

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

# One combined log for the whole Job (pipeline stages + dashboard).
if (!nzchar(Sys.getenv("PIPELINE_LOG_FILE"))) {
  od <- Sys.getenv("OUTPUT_DIR", unset = "/mnt/artifacts/results")
  try(dir.create(od, showWarnings = FALSE, recursive = TRUE), silent = TRUE)
  # Verify the dir is usable; if a bad/unwritable OUTPUT_DIR was set
  # (e.g. a typo in pipeline_inputs.csv) fall back to tempdir() so the
  # combined log is never silently lost. Logging never fails the Job.
  probe <- tryCatch({
    pf <- file.path(od, paste0(".logprobe_", Sys.getpid()))
    file.create(pf); on.exit(unlink(pf), add = TRUE); file.exists(pf)
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

rc1 <- system2("Rscript", file.path(.d, "run_pipeline.R"),
                stdout = "", stderr = "")
if (rc1 != 0) {
  stop(sprintf("run_pipeline.R failed (exit %d); dashboard skipped.", rc1))
}

rc2 <- system2("Rscript", file.path(.d, "lot_long_dashboard.R"),
                stdout = "", stderr = "")
if (rc2 != 0) {
  stop(sprintf("lot_long_dashboard.R failed (exit %d).", rc2))
}
