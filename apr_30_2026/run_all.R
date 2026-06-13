#!/usr/bin/env Rscript
# One Domino Job: full pipeline, then the LOT1-5 dashboard. Runs
# run_pipeline.R and, only if it exits 0, runs 04_lot_detail_dashboard.R.
# Either failure fails the Job. pipeline_inputs.csv is loaded first so
# the combined log lands in the OUTPUT_DIR the stages write to.
#
#   Domino Job command:  Rscript /mnt/code/.../run_all.R
#   Set DATABRICKS_PWD as a Domino env var/secret. Run-control env
#   vars (FORCE_RERUN, SKIP_*) still work and win over the CSV.

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
  # NOTE: no on.exit() here - this is top-level script scope, not a
  # function, so on.exit() would error, get caught, and force the
  # tempdir() fallback even for a perfectly good OUTPUT_DIR. Do
  # explicit create + check + cleanup instead (also leaves no
  # .logprobe file behind).
  probe <- tryCatch({
    pf <- file.path(od, paste0(".logprobe_", Sys.getpid()))
    ok <- isTRUE(file.create(pf))
    ex <- file.exists(pf)
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

rc1 <- system2("Rscript", file.path(.d, "run_pipeline.R"),
                stdout = "", stderr = "")
if (rc1 != 0) {
  stop(sprintf("run_pipeline.R failed (exit %d); dashboard skipped.", rc1))
}

rc2 <- system2("Rscript", file.path(.d, "04_lot_detail_dashboard.R"),
                stdout = "", stderr = "")
if (rc2 != 0) {
  stop(sprintf("04_lot_detail_dashboard.R failed (exit %d).", rc2))
}
