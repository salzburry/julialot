# =============================================================================
# cohorts/ndmm.R -- the NDMM cohort definition
# -----------------------------------------------------------------------------
# ONE FILE, ONE COHORT. This file is the complete definition of the NDMM
# cohort. It does not reference cohorts/overall.R, does not inherit from it, and
# does not require it to have been built. `Rscript "Jul 28/build_ndmm.R"` is a
# complete run.
#
# The ten index-anchored gates below are spelled out in full rather than shared
# with overall.R via a constant. That is deliberate: a shared constant means
# editing NDMM's index criteria silently edits Overall's, which is the coupling
# this whole change exists to remove. The cost is that the two lists must be
# kept in step BY REVIEW when they are meant to agree -- and a test reports it
# when they drift, rather than preventing the drift.
#
# They are identical to Overall's today. That is a fact about the current study
# definition, not a constraint (PLAN.md 4).
#
# Build it:  Rscript "Jul 28/build_ndmm.R"
# =============================================================================

list(
  id       = "ndmm",
  label    = "NDMM (newly diagnosed, 1L)",
  flag_col = "COHORT_NDMM",
  order    = 20L,
  desc     = paste(
    "Newly-diagnosed 1L cohort: the index-anchored IE funnel plus a LOT1",
    "anchor, a 1L start cutoff, and six LOT1-anchored criteria.",
    "Runs standalone -- no Overall run, no ELIG_COH_FINAL dependency."),

  gates = c(
    # ---- index-anchored ------------------------------------------------------
    # Currently identical to overall.R. Change them here to change NDMM only.
    "idx_qualifying",
    "age_at_index",
    "ce_baseline_6mo",
    "ce_followup_1d",
    "no_baseline_mm_agents",
    "fu_mm_agents",
    "no_baseline_mm_evidence",
    "no_other_cancer_index",
    "no_pregnancy_index",
    "no_clintrial",

    # ---- LOT1-anchored -------------------------------------------------------
    # has_lot1 must precede every gate that reads LOT1_START_DT. It is STRICTLY
    # STRONGER than fu_mm_agents above: that one counts any MM agent including
    # steroids, this one requires a non-steroid regimen start (PLAN.md 4a).
    # Splitting has_lot1 from lot1_from gives the funnel two rows where the
    # existing build reports one fused row -- same patients either way.
    "has_lot1",                  # a LOT1 regimen start exists
    "lot1_from",                 # 1L start on/after the cutoff

    # The six criteria documented in 06_ndmm_dashboard.R's header, IN THE ORDER
    # ITS OWN ATTRITION FUNNEL APPLIES THEM (ndmm_counts()). The final AND-set is
    # the same whatever the order, so this does not change the cohort -- but the
    # INTERMEDIATE attrition counts are order-dependent, and this folder is meant
    # to reproduce the legacy report, not merely the legacy cohort. An earlier
    # draft had ce_fu_lot1_3mo fourth and would have produced a funnel that
    # silently disagreed with the dashboard's at every middle row.
    "ce_pre_lot1_12mo",          # 12-mo CE before 1L start
    "no_belantamab",             # no belantamab in any line
    "no_prior_mm_tx",            # no MM oncology Tx in the 12-mo pre-1L window
    "no_other_cancer_pre_lot1",  # no other active cancer in that window
    "ce_fu_lot1_3mo",            # 3-mo CE after 1L start (strict, no gaps)
    "no_pregnancy_study"         # no pregnancy over the study period
  ),

  # `lot1_from` is tunable (it filters raw LOT1_START_DT). Left empty so the
  # cutoff comes from NDMM_LOT1_FROM, matching 06_ndmm_dashboard.R:122.
  # The CE windows are NOT tunable here -- they are baked into the upstream flag
  # build, and validation rejects any attempt to override them from a spec.
  params = list()
)
