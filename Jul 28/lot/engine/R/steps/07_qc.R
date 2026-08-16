# QC counts on what was built.

phase_qc <- function(con, ctx) {
  meds <- ctx$meds

  # The NDC format QC that ran here is gone: it measured lengths the join does
  # not use. check_claim_ndc covers both claim tables and ndc_shape, ndc_short
  # and bad_ndc cover the code list, both before extraction. lot/FILES.md has
  # the arithmetic behind the two NDC shapes.

  # Validation QC suite: reporting on MAP and LOT, not gating. The whole block
  # is wrapped below, so a failure here prints and the run carries on. The
  # same conditions are re-checked fail-loud in check_lot1_invariants().
  log_msg("Running validation QC suite...")
  tryCatch({
    # A) MMA_MED coverage by source
    log_msg("  [A] MMA_MED extraction coverage:")
    coverage <- db_q(con, "
      SELECT CODE_TYPE, CLAIM_TYPE, count(*) AS n_claims, count(DISTINCT PATID) AS n_patients, count(DISTINCT MED_ABBR) AS n_meds
      FROM mma_med_processed
      GROUP BY CODE_TYPE, CLAIM_TYPE
      ORDER BY CODE_TYPE, CLAIM_TYPE
    ")
    print(coverage)

    # B) MAP correctness spot checks
    log_msg("  [B] MAP algorithm spot checks:")
    # Check no MAP has end < start
    bad_maps <- db_q(con, "SELECT count(*) AS n_bad FROM map_stacked WHERE MAP_END_DT < MAP_START_DT")$n_bad
    log_msg("    MAPs with END < START: ", bad_maps, if (bad_maps > 0) " ** INVESTIGATE **" else " (OK)")

    # Check MAP_END_DT = max(rx_runout, med_runout)
    runout_check <- db_q(con, "
      SELECT count(*) AS n_mismatch
      FROM map_stacked
      WHERE MAP_END_DT <> greatest(
        coalesce(MAP_RX_RUNOUT_DT, cast('1900-01-01' as date)),
        coalesce(MAP_MED_RUNOUT_DT, cast('1900-01-01' as date))
      )
      AND MAP_END_DT IS NOT NULL
    ")$n_mismatch
    log_msg("    MAPs where END_DT != max(rx_runout, med_runout): ", runout_check,
            if (runout_check > 0) " ** INVESTIGATE **" else " (OK)")

    # MAPs with both rx and med sources (mixed claim type coverage)
    both_src <- db_q(con, "
      SELECT count(*) AS n_maps_both_sources
      FROM map_stacked
      WHERE MAP_RX_RUNOUT_DT IS NOT NULL AND MAP_MED_RUNOUT_DT IS NOT NULL
    ")$n_maps_both_sources
    log_msg("    MAPs with both pharmacy + medical sources: ", format(both_src, big.mark = ","))

    # C) ENDDATE_CE vs ENDDATE sensitivity
    log_msg("  [C] OBS_END_DT (ENDDATE_CE) sensitivity:")
    ce_sens <- db_q(con, "
      SELECT
        sum(case when ENDDATE_CE < ENDDATE then 1 else 0 end) AS n_disenrolled_early,
        count(*) AS n_total,
        avg(case when ENDDATE_CE < ENDDATE then datediff(ENDDATE, ENDDATE_CE) else 0 end) AS avg_gap_days
      FROM lot_patient_input
    ")
    log_msg("    Patients disenrolled before study ENDDATE: ",
            format(ce_sens$n_disenrolled_early, big.mark = ","),
            " / ", format(ce_sens$n_total, big.mark = ","),
            " (", round(100 * ce_sens$n_disenrolled_early / max(ce_sens$n_total, 1), 1), "%)")
    log_msg("    Avg gap (ENDDATE - ENDDATE_CE): ", round(ce_sens$avg_gap_days, 1), " days")

    # D) LOT1 completeness
    log_msg("  [D] LOT1 completeness:")
    lot1_check <- db_q(con, "
      SELECT
        count(*) AS n_lot1,
        sum(case when lb.LOT1_BASE_END_DT > p.OBS_END_DT then 1 else 0 end) AS n_end_past_obs
      FROM lot1_base_end lb
      INNER JOIN lot_patient_input p ON lb.PATID = p.PATID
    ")
    log_msg("    LOT1 patients: ", format(lot1_check$n_lot1, big.mark = ","))
    log_msg("    LOT1_BASE_END_DT > OBS_END_DT: ", lot1_check$n_end_past_obs,
            if (lot1_check$n_end_past_obs > 0) " ** INVESTIGATE **" else " (OK)")

    # E) Rollup flag sanity
    log_msg("  [E] Rollup flag validation:")
    flag_check <- db_q(con, "
      SELECT CL_MED_ABBR, CL_MED_CLASS, MONOMAINTENANCE, CONDITIONING, USED_FOR_OTHER_CANCERS
      FROM mma_rollup
      ORDER BY CL_MED_CLASS, CL_MED_ABBR
    ")
    print(flag_check)

    # F) SCT consistency
    log_msg("  [F] SCT validation:")
    sct_check <- db_q(con, "
      SELECT
        sum(CASE WHEN LOT1_TX_ENDDATE IS NOT NULL AND LOT1_TX_ENDDATE > lb.OBS_END_DT THEN 1 ELSE 0 END)
          AS n_sct_end_past_obs,
        sum(CASE WHEN LOT1_SCT_AUTO_TAND_FLG = 1 AND LOT1_SCT_AUTO_SING_FLG = 1 THEN 1 ELSE 0 END)
          AS n_both_tandem_and_single,
        sum(CASE WHEN LOT1_TX_AUTO_DT_1 IS NOT NULL AND LOT1_TX_AUTO_DT_1 < lb.LOT1_START_DT THEN 1 ELSE 0 END)
          AS n_auto_before_lot1
      FROM lot1_sct sct
      INNER JOIN lot1_base lb ON sct.PATID = lb.PATID
    ")
    log_msg("    SCT end date past OBS_END_DT: ", sct_check$n_sct_end_past_obs,
            if (sct_check$n_sct_end_past_obs > 0) " ** INVESTIGATE **" else " (OK)")
    log_msg("    Both tandem AND single flag: ", sct_check$n_both_tandem_and_single,
            if (sct_check$n_both_tandem_and_single > 0) " ** BUG **" else " (OK)")
    log_msg("    AUTO DT_1 before LOT1_START: ", sct_check$n_auto_before_lot1,
            if (sct_check$n_auto_before_lot1 > 0) " ** INVESTIGATE **" else " (OK)")

    log_msg("Validation QC suite complete.")
  }, error = function(e) {
    log_msg("WARNING: Validation QC suite failed: ", e$message)
  })

}
