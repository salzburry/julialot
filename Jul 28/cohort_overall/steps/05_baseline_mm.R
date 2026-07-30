# =============================================================================
# 05_baseline_mm.R -- IE Step 7: no MM diagnosis already in baseline
# -----------------------------------------------------------------------------
#   Step 7  MM_baseline_diag = 0
#
# ">=1 STRICT MM diagnosis (203.0x / C90.0x) in index-183 .. index-1" excludes.
# Step 5 said the patient was not already being TREATED for MM; this says they
# were not already DIAGNOSED with it. Both are needed for "newly diagnosed": a
# patient can carry an MM diagnosis for months before their first claim for an
# MM agent.
#
# STRICT CODES ONLY, and that is the asymmetry worth noticing. Step 1 admits a
# patient on 2 BROAD outpatient claims (203.x / C90.x), but only a STRICT claim
# in baseline excludes them. So a broad-code history in baseline does not
# disqualify anyone. Deliberate: broad codes cover MM-adjacent conditions that
# are not a prior MM diagnosis.
#
# Reads mm_dx_events_all, not mm_dx_events_id -- the whole point is to look
# BEFORE the identification period, and mm_dx_events_id has already been cut to
# it. Using the ID-period view here would make the flag silently blind for
# indexes early in the study.
#
# CONFIGURED OFF (APPLY_BASELINE_MM_EXCL=FALSE in pipeline_inputs.csv). The flag
# is still computed. See the README section on the four criteria that ship off.
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
      note = paste("STRICT codes only. Ships OFF:",
                   "APPLY_BASELINE_MM_EXCL=FALSE in pipeline_inputs.csv.")
    )
  )

  list(views = views, criteria = criteria)
}
