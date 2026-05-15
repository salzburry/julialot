#!/usr/bin/env Rscript
# ============================================================
# lot2_5_program.R - Standalone runner for LOT 2-5
#
# Builds LOT_LONG (one row per PATID x LOT_NUM, for LOT_NUM 1..5) per
# the LOT 2-5 spec (lot2to5_spec_DRAFT_apr30.xlsx). Does NOT modify
# lot_program.R or any LOT1 module.
#
# Prerequisites in the work schema (persisted by lot_program.R):
#   MAP_STACKED, LOT1_SCT, LOT1_BASE_END, ELIG_COH_FINAL
#   (or whatever cfg$input_cohort_table points to).
#
# All session-scoped temp views needed by the builder (lot_patient_input,
# sct_codelist, sct_claims_raw, tx_auto_dates, tx_allo_cart_dates,
# mma_rollup, permissible_subs) are rebuilt here from CSV codelists +
# the persisted CDM / cohort tables.
#
# Configuration overrides (env vars):
#   INDUCTION_WINDOW_DAYS_LOT_N    default 30
#   CART_CONSOLIDATION_DAYS        default 45
#   SCT_TANDEM_DAYS                default 180
#   ALLO_LOT_SPAN                  default "single_day"  ("extend_to_next")
#   MAX_LOT                        default 5
# ============================================================

.script_dir <- local({
  args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", args, value = TRUE)
  if (length(file_arg) > 0) {
    return(dirname(normalizePath(sub("^--file=", "", file_arg[1]))))
  }
  for (i in seq_len(sys.nframe())) {
    ofile <- tryCatch(sys.frame(i)$ofile, error = function(e) NULL)
    if (!is.null(ofile)) return(dirname(normalizePath(ofile)))
  }
  getwd()
})

source_dir <- file.path(.script_dir, "R")
# Apply CSV input overrides BEFORE config_lot.R reads Sys.getenv().
if (file.exists(file.path(source_dir, "load_inputs.R"))) {
  source(file.path(source_dir, "load_inputs.R"))
  load_pipeline_inputs(c(.script_dir, dirname(.script_dir)))
}
source(file.path(source_dir, "config_lot.R"))
source(file.path(source_dir, "db_utils_lot.R"))
source(file.path(source_dir, "codelists_lot.R"))
source(file.path(source_dir, "lot2_5_inputs.R"))
source(file.path(source_dir, "lot2_5_base.R"))

main <- function() {
  stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")

  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  log_msg("Connected. Configuration:")
  log_msg("  CDM Schema:   ", cfg$cdm_schema)
  log_msg("  Work Schema:  ", cfg$work_schema)
  log_msg("  Input Cohort: ", cfg$input_cohort_table)

  # Load CSV codelists - pass character vectors of required columns
  # (matches lot_program.R's calls; the loader does setdiff() on names).
  rollup_src <- load_codelist_csv("cl_mma_rollup.csv",
    c("CL_MEDICATION_FULL", "CL_MED_CLASS", "CL_MED_ABBR",
      "MONOMAINTENANCE", "DUALMAINTENANCEWITH", "CONDITIONING", "USED_FOR_OTHER_CANCERS"))
  subs_src <- load_codelist_csv("permissible_subs.csv",
    c("original_med", "substitute_med"))
  sct_src <- load_codelist_csv("cl_sct_codelist.csv",
    c("CL_CODE_TYPE", "CL_CODE", "SCT_TYPE"))

  # Rebuild session-scoped views the builder needs.
  prepare_lot_inputs(con, rollup_src = rollup_src, subs_src = subs_src, sct_src = sct_src)

  build_lot2_5(
    con,
    induction_window_days   = cfg$lot_n_induction_window_days,
    cart_consolidation_days = cfg$cart_consolidation_days,
    sct_tandem_days         = cfg$sct_tandem_days,
    allo_lot_span           = Sys.getenv("ALLO_LOT_SPAN", unset = "single_day"),
    max_lot                 = as.integer(Sys.getenv("MAX_LOT", unset = "5"))
  )

  log_msg("LOT_LONG written to ", wrk("LOT_LONG"))
}

if (!interactive()) {
  main()
}
