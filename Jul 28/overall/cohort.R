# =============================================================================
# cohorts/overall.R -- the Overall cohort definition
# -----------------------------------------------------------------------------
# ONE FILE, ONE COHORT. This file is the complete definition of the Overall
# cohort. It references no other cohort, and no other cohort references it.
# Editing it cannot change NDMM.
#
# Gate ids resolve against the registry in R/cohort_specs.R, which holds the
# SQL for each criterion. This file chooses and orders them -- it never contains
# SQL. That split is the point: the definition is reviewable by the study team
# without reading any code.
#
# Build it:  Rscript "Jul 28/build_overall.R"
# =============================================================================

list(
  id       = "overall",
  label    = "Overall MM (index IE + follow-up MM-agent evidence)",
  flag_col = "COHORT_OVERALL",
  order    = 10L,           # position in multi-cohort runs (PLD column order)
  desc     = paste(
    "MM patients passing the index-anchored IE funnel, with >=1 MM-agent claim",
    "in follow-up. NOT '1L-treated': fu_mm_agents requires an MM-agent claim of",
    "ANY class, not a LOT1 regimen, so steroid-only follow-up qualifies and this",
    "is a SUPERSET of the 1L-regimen population.",
    "Equivalent to today's ELIG_COH_FINAL (pipeline_steps.R step 24)."),

  # ---- Gates, in attrition-funnel order --------------------------------------
  # All index-anchored: Overall never anchors on LOT1, so it needs neither the
  # LOT build nor the LOT1 flag tables. `--cohort=overall` runs with the LOT
  # stage switched off entirely.
  #
  # These ten are, in order, the step-1 index gate from pipeline_steps.R:1062
  # plus the ten criteria in build_criteria_catalog() (criteria_attrition.R:38).
  #
  # NOTE: fu_mm_agents is "any MM agent claim, any drug class" -- it does NOT
  # require a LOT1 regimen start. A patient whose only follow-up MM agents are
  # steroids belongs to Overall (see the gate's note, and PLAN.md 4a).
  gates = c(
    "idx_qualifying",           # 1 inpatient MM dx, or 2 outpatient in-window
    "age_at_index",             # age >= min_age
    "ce_baseline_6mo",          # 6-mo CE before index
    "ce_followup_1d",           # >= 1 day FU enrollment
    "no_baseline_mm_agents",    # new-user
    "fu_mm_agents",             # a treatment start exists (any class)
    "no_baseline_mm_evidence",  # no prior MM evidence in baseline
    "no_other_cancer_index",    # no other malignancy
    "no_pregnancy_index",       # no pregnancy
    "no_clintrial"              # no clinical-trial participation
  ),

  # Per-gate parameter overrides. Empty = registry defaults, with pipeline-wide
  # values (MIN_AGE, OUTPATIENT_WINDOW) applied from cfg. Only gates marked
  # `tunable` may be overridden; anything else is rejected at validation.
  params = list()
)
