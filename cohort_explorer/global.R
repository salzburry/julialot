# =============================================================================
# global.R  --  loaded once at app startup (sourced by app.R)
# -----------------------------------------------------------------------------
# Sources the reusable engine, loads the flagged cohort, and exposes the
# registry/cohort objects + a couple of UI helpers to ui/server.
# =============================================================================

suppressPackageStartupMessages({
  library(shiny)
})
HAS_SURVIVAL <- requireNamespace("survival", quietly = TRUE)

# resolve this file's directory whether sourced by Rscript or runApp()
.app_dir <- tryCatch(dirname(sys.frame(1)$ofile), error = function(e) getwd())
if (is.null(.app_dir) || !nzchar(.app_dir)) .app_dir <- getwd()

# ---- engine modules ----
for (f in c("criteria_registry.R", "build_flagged_cohort.R", "cohort_select.R",
            "summaries.R", "km.R", "checks.R", "ui_helpers.R")) {
  src <- file.path(.app_dir, "R", f)
  if (file.exists(src)) source(src, local = FALSE)
}

# ---- config objects ----
REG     <- criteria_registry()
COHORTS <- cohort_definitions()
VARDICT <- variable_dictionary()
EPDICT  <- if (HAS_SURVIVAL) endpoint_dictionary() else list()

# ---- data source --------------------------------------------------------
# Real deployments set COHORT_EXPLORER_DATA to a CSV (the warehouse projection
# from build_flagged_cohort.R) or wire source_flagged_cohort_warehouse().
# Default: deterministic synthetic cohort so the app runs out of the box.
.data_src <- Sys.getenv("COHORT_EXPLORER_DATA", "synthetic")
FLAGGED   <- load_flagged_cohort(if (nzchar(.data_src)) .data_src else "synthetic")

# resolve the NULL soc default to the levels actually present
REG$flt_soc$default <- sort(unique(FLAGGED$soc_category))

MAX_LOT <- 5L

# variables offered in the "Select Variables" / strata controls
SUMMARY_VARS <- names(VARDICT)
STRATA_VARS  <- names(VARDICT)[vapply(names(VARDICT),
                                      function(v) var_type(v, VARDICT) == "cat",
                                      logical(1))]
