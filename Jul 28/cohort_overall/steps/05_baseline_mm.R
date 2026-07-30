# =============================================================================
# 05_baseline_mm.R -- step 7: no MM diagnosis already in baseline
# -----------------------------------------------------------------------------
#   step 7  MM_baseline_diag = 0
#
# >=1 strict MM diagnosis (203.0x / C90.0x) in index-183 .. index-1 excludes.
# If enabled, this adds a no-prior-diagnosis requirement on top of step 5's
# no-prior-treatment one. It is OFF in the current Overall config, so it does not
# affect the count -- the flag is still computed.
#
# Note the asymmetry: step 1 admits on 2 broad outpatient claims, but only a
# strict claim in baseline excludes -- broad codes cover MM-adjacent conditions
# that are not prior MM.
#
# Reads mm_dx_events_all, not mm_dx_events_id: the point is to look before the
# identification period, and the ID-period table has already been cut to it.
# =============================================================================

ie_step_baseline_mm <- function(cfg, h) {
  work <- h$work

  views <- list(
    ie_view(
      name = "mm_baseline_evidence_flag",
      legacy = "17_mm_baseline_evidence_flag",
      description = "Checking for any STRICT MM dx (203.0x/C90.0x) claim in baseline period",
      select = fmt("
        SELECT
          q.PATID,
          q.index_date,
          -- Per attrition table Step 7: >=1 MM claim (203.0x/C90.0x) in baseline
          -- Baseline excludes index_date (baseline = before index)
          -- mm_dx_strict_flg ensures only STRICT codes are counted
          max(CASE WHEN e.svc_dt BETWEEN date_sub(q.index_date, {cfg$baseline_days})
                                     AND date_sub(q.index_date, 1)
                    AND e.mm_dx_strict_flg = 1
               THEN 1 ELSE 0 END) AS MM_BASELINE_EVIDENCE
        FROM {work('mm_qualifying')} q
        LEFT JOIN {work('mm_dx_events_all')} e ON q.PATID = e.PATID
        GROUP BY q.PATID, q.index_date
      "),
      qc = fmt("SELECT sum(MM_BASELINE_EVIDENCE) AS n_with_baseline_mm FROM {work('mm_baseline_evidence_flag')}")
    )
  )

  criteria <- list(
    ie_criterion(
      step = 7L,
      id = "no_baseline_mm_evidence",
      attrition_id = "07_step7_bl_mm_evidence",
      label = "Step 7: BL MM evidence (excl)",
      flag_col = "MM_baseline_diag",
      predicate = "MM_baseline_diag = 0",
      cfg_key = "apply_baseline_mm_excl",
      polarity = "exclude",
      note = "Strict codes only. Ships off."
    )
  )

  list(views = views, criteria = criteria)
}
