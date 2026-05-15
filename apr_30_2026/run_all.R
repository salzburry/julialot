#!/usr/bin/env Rscript
# ============================================================
# run_all.R - one Domino Job: full pipeline, then LOT1-5 dashboard
# ============================================================
# Runs run_pipeline.R, and only if it succeeds (exit 0) runs
# lot_long_dashboard.R. Both inherit one shared PIPELINE_LOG_FILE so
# the whole Job writes a single combined log artifact.
#
#   Domino Job command:  Rscript /mnt/code/.../run_all.R
#   (set DATABRICKS_PWD as a Domino env var / secret; run-control
#    env vars like FORCE_RERUN / SKIP_* still work and win over the CSV)
# ============================================================

.d <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(a)) dirname(normalizePath(sub("^--file=", "", a[1]))) else getwd()
})

# One combined log for the entire Job (pipeline stages + dashboard).
if (!nzchar(Sys.getenv("PIPELINE_LOG_FILE"))) {
  od <- Sys.getenv("OUTPUT_DIR", unset = "/mnt/artifacts/results")
  Sys.setenv(PIPELINE_LOG_FILE = file.path(
    od, paste0("pipeline_run_", format(Sys.time(), "%Y%m%d_%H%M%S"), ".log")))
}

rc <- system2("Rscript", file.path(.d, "run_pipeline.R"),
               stdout = "", stderr = "")
if (rc != 0) {
  stop(sprintf("run_pipeline.R failed (exit %d); dashboard skipped.", rc))
}
system2("Rscript", file.path(.d, "lot_long_dashboard.R"),
        stdout = "", stderr = "")
