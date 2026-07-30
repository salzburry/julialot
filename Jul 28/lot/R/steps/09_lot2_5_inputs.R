# Rebuild the shared LOT inputs for a session running LOT2-5 on its own.
#
# It calls the LOT1 phases so both paths apply the same rules, then does the
# only things that differ: rebind the tables LOT1 persisted, and materialize
# the heavy SCT views.

prepare_lot_inputs <- function(con) {
  log_msg("Preparing upstream views for LOT2-5...")

  # The same definitions LOT1 uses, guards and all. phase_sct() stops at S14;
  # S15 is phase_lot1_sct(), which needs lot1_base and is not rebuilt here.
  ctx <- phase_codelists(con)
  phase_patient_input(con)
  phase_sct(con, ctx)

  # Rebind the persisted LOT1 outputs to the temp view names lot2_5_base.R
  # uses. Only the tables actually referenced there are rebound (LOT1_BASE is
  # persisted by LOT1 but not consumed here).
  for (tbl in c("MAP_STACKED", "LOT1_SCT", "LOT1_BASE_END")) {
    db_exec(con, glue(
      "CREATE OR REPLACE TEMPORARY VIEW {tolower(tbl)} AS SELECT * FROM {lot_out(tbl)}"))
  }

  # Same reason as the combined run: LOT2-5 reads these once per line, and
  # left as views over the raw CDM they are re-scanned every time.
  materialize_sct_views(con)

  log_msg("Upstream views ready.")
  invisible(ctx)
}
