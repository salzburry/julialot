# Rebuild what LOT2-5 needs when it runs on its own, in a session where LOT1
# did not.
#
# This used to carry its own copies of the code-list, cohort and SCT SQL -
# "the same SQL 02_lot1.R uses", except the copies drifted. Guards added to
# the LOT1 code lists never reached these, and the cohort view here ignored
# censor_at_disenrollment entirely. So it calls the LOT1 phases now, and holds
# only what is genuinely different: rebinding the tables LOT1 persisted, and
# materializing the heavy SCT views.

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
