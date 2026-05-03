#!/usr/bin/env Rscript
# ============================================================
# lot2_5_program.R - Standalone runner for LOT 2-5
#
# Builds LOT_LONG (one row per PATID x LOT_NUM, for LOT_NUM 1..5) using
# the LOT 2-5 spec (lot2to5_spec_DRAFT_apr30.xlsx). Does NOT touch
# lot_program.R or any LOT1 module.
#
# Prerequisites:
#   1. lot_program.R has been run on the same connection / work schema,
#      so MAP_STACKED, LOT1_BASE, LOT1_SCT, LOT1_BASE_END are persisted
#      and the upstream tx_auto_dates / tx_allo_cart_dates views exist
#      OR can be reconstructed from the persisted SCT inputs.
#   2. permissible_subs and mma_rollup are loaded by codelists_lot.R.
#
# Configuration overrides (env vars):
#   INDUCTION_WINDOW_DAYS_LOT_N   default 30
#   LOT_DISCON_GAP_DAYS           default 90
#   CART_CONSOLIDATION_DAYS       default 45
#   SCT_TANDEM_DAYS               default 180
#   ALLO_LOT_SPAN                 default "single_day"  ("extend_to_next")
#   MAX_LOT                       default 5
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
source(file.path(source_dir, "config_lot.R"))
source(file.path(source_dir, "db_utils_lot.R"))
source(file.path(source_dir, "codelists_lot.R"))
source(file.path(source_dir, "lot2_5_base.R"))

main <- function() {
  stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")

  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  # Re-bind persisted upstream tables to temp views the builder expects.
  # lot_program.R materializes these; we just point views at them.
  for (mv in list(
    list(view = "lot_patient_input", tbl = "LOT_PATIENT_INPUT"),
    list(view = "map_stacked",        tbl = "MAP_STACKED"),
    list(view = "lot1_base",          tbl = "LOT1_BASE"),
    list(view = "lot1_sct",           tbl = "LOT1_SCT"),
    list(view = "lot1_base_end",      tbl = "LOT1_BASE_END"),
    list(view = "tx_auto_dates",      tbl = "TX_AUTO_DATES"),
    list(view = "tx_allo_cart_dates", tbl = "TX_ALLO_CART_DATES"),
    list(view = "permissible_subs",   tbl = "PERMISSIBLE_SUBS"),
    list(view = "mma_rollup",         tbl = "MMA_ROLLUP")
  )) {
    db_exec(con, sprintf(
      "CREATE OR REPLACE TEMPORARY VIEW %s AS SELECT * FROM %s",
      mv$view, wrk(mv$tbl)
    ))
  }

  build_lot2_5(
    con,
    induction_window_days   = as.integer(Sys.getenv("INDUCTION_WINDOW_DAYS_LOT_N", unset = "30")),
    lot_discon_gap_days     = cfg$lot_discon_gap_days,
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
