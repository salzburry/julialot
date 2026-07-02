# =============================================================================
# criteria_registry.R  --  reusable IE-criteria registry + cohort definitions
# -----------------------------------------------------------------------------
# This is the single source of truth for the dashboard's Inclusion/Exclusion
# (IE) criteria. It is config-as-R (no yaml dependency) so the engine and the
# Shiny UI are driven by the SAME object.
#
# Design (mirrors the refactor's cohort gate registry + the pipeline's
# pipeline_inputs.csv IE toggles):
#   * The pipeline builds ONE broad "superset" cohort (every 1L-treated MM
#     patient) and stamps ONE boolean flag column per IE criterion onto it
#     (see build_flagged_cohort.R). Nothing is dropped at build time.
#   * "Selecting a cohort" = AND-ing a chosen set of those flags
#     (see cohort_select.R). Overall and NDMM are just different default flag
#     sets; the user may freely add/remove criteria at runtime.
#
# Two kinds of criterion:
#   type = "flag"   pre-computed boolean on the flagged cohort (e.g. baseline
#                   CE, no-belantamab). `keep_when` says which value is kept.
#   type = "param"  a live filter on a raw variable (age slider, gender
#                   multiselect). Evaluated in the app, never pre-baked, so the
#                   user can move the slider without rebuilding.
#
# Every criterion declares a `ui_category` (Demographics / Clinical / Labs /
# Treatments / Other) so the sidebar accordion is generated automatically,
# matching the "Inclusion Filters" panel in the sample dashboard.
# =============================================================================

# ---- IE criteria registry ---------------------------------------------------
# Each entry is one criterion. Fields:
#   id          stable key (used as the flag column name for type="flag")
#   label       UI label
#   desc        one-line description (tooltip / checkbox help)
#   polarity    "incl" | "excl"   (drives colour + attrition wording)
#   phase       "study_period" | "pre_lot" | "post_lot1"  (attrition ordering;
#               mirrors the gate registry phases)
#   ui_category one of the accordion buckets
#   type        "flag" | "param"
#   keep_when   (flag only) value kept when the criterion is ACTIVE (always 1L:
#               flags are coded so 1 = patient satisfies the criterion)
#   variable    (param only) raw column the filter reads
#   filter      (param only) "range" | "categorical"
#   default     (param only) default control value (range = c(lo, hi);
#               categorical = character vector of selected levels)

criteria_registry <- function() {
  list(
    # --- treatment / disease definition (study-period & pre-LOT anchors) -----
    incl_qualifying_mm = list(
      id = "incl_qualifying_mm", label = "Qualifying MM diagnosis",
      desc = "1 inpatient or >=2 outpatient MM dx on separate days within 90d.",
      polarity = "incl", phase = "pre_lot", ui_category = "Clinical",
      type = "flag", keep_when = 1L),

    incl_eligible_1l_tx = list(
      id = "incl_eligible_1l_tx", label = "Eligible 1L treatment (>= 2017)",
      desc = "First eligible MM treatment on/after MM dx in the ID period.",
      polarity = "incl", phase = "pre_lot", ui_category = "Treatments",
      type = "flag", keep_when = 1L),

    incl_adult = list(
      id = "incl_adult", label = "Adult at index (age >= 18)",
      desc = "Age >= 18 years at index (calendar year of MM diagnosis).",
      polarity = "incl", phase = "pre_lot", ui_category = "Demographics",
      type = "flag", keep_when = 1L),

    # --- continuous enrollment (the 6m-vs-12m baseline is the Overall/NDMM fork)
    incl_baseline_ce_6m = list(
      id = "incl_baseline_ce_6m", label = "Baseline CE >= 6 months",
      desc = "Continuous enrollment >=6m before index (Overall default).",
      polarity = "incl", phase = "pre_lot", ui_category = "Other",
      type = "flag", keep_when = 1L),

    incl_baseline_ce_12m = list(
      id = "incl_baseline_ce_12m", label = "Baseline CE >= 12 months",
      desc = "Continuous enrollment >=12m before 1L index (NDMM default).",
      polarity = "incl", phase = "pre_lot", ui_category = "Other",
      type = "flag", keep_when = 1L),

    incl_fu_ce_3m = list(
      id = "incl_fu_ce_3m", label = "Follow-up CE >= 3 months",
      desc = "CE >=3m during follow-up (or death), no gaps (NDMM).",
      polarity = "incl", phase = "post_lot1", ui_category = "Other",
      type = "flag", keep_when = 1L),

    incl_new_user = list(
      id = "incl_new_user", label = "No baseline MM agents (new user)",
      desc = "No MM agents during the baseline period.",
      polarity = "incl", phase = "pre_lot", ui_category = "Treatments",
      type = "flag", keep_when = 1L),

    incl_fu_mm_agents = list(
      id = "incl_fu_mm_agents", label = "Treated (>=1 MM agent in follow-up)",
      desc = "At least one MM treatment start exists (defines the LOT).",
      polarity = "incl", phase = "post_lot1", ui_category = "Treatments",
      type = "flag", keep_when = 1L),

    # --- NDMM-specific exclusions (coded 1 = patient PASSES the exclusion) ----
    excl_prior_mm_tx = list(
      id = "excl_prior_mm_tx", label = "No prior MM therapy (12m baseline)",
      desc = "No MM oncology therapy in the 12m before 1L index.",
      polarity = "excl", phase = "post_lot1", ui_category = "Treatments",
      type = "flag", keep_when = 1L),

    excl_other_cancer = list(
      id = "excl_other_cancer", label = "No other cancer (12m baseline)",
      desc = "No other primary/metastatic malignancy in the 12m baseline.",
      polarity = "excl", phase = "post_lot1", ui_category = "Clinical",
      type = "flag", keep_when = 1L),

    excl_belantamab = list(
      id = "excl_belantamab", label = "No belantamab (any LOT)",
      desc = "No belantamab mafodotin (ADC) exposure in any LOT.",
      polarity = "excl", phase = "study_period", ui_category = "Treatments",
      type = "flag", keep_when = 1L),

    excl_pregnancy = list(
      id = "excl_pregnancy", label = "No pregnancy",
      desc = "No pregnancy/childbirth code during the study period.",
      polarity = "excl", phase = "study_period", ui_category = "Clinical",
      type = "flag", keep_when = 1L),

    # --- live demographic / clinical filters (param-type) --------------------
    # NOTE: param defaults are NULL = "all data" (no restriction). The UI
    # resolves NULL to the full observed range / all levels, so the initial
    # cohort equals the flag-only selection -- a filter only ever shrinks the
    # cohort when the user intentionally changes it. Do NOT hard-code level
    # lists here (that silently dropped Medicare / age>90 before).
    flt_age = list(
      id = "flt_age", label = "Age at index",
      desc = "Restrict to an age-at-index range.",
      polarity = "incl", phase = "pre_lot", ui_category = "Demographics",
      type = "param", variable = "age_index", filter = "range",
      default = NULL),

    flt_gender = list(
      id = "flt_gender", label = "Gender",
      desc = "Restrict to selected gender(s).",
      polarity = "incl", phase = "pre_lot", ui_category = "Demographics",
      type = "param", variable = "gender", filter = "categorical",
      default = NULL),

    flt_region = list(
      id = "flt_region", label = "Region",
      desc = "Restrict to selected US census region(s).",
      polarity = "incl", phase = "pre_lot", ui_category = "Demographics",
      type = "param", variable = "region", filter = "categorical",
      default = NULL),

    flt_payer = list(
      id = "flt_payer", label = "Payer / product type",
      desc = "Restrict to selected insurance product type(s).",
      polarity = "incl", phase = "pre_lot", ui_category = "Other",
      type = "param", variable = "payer_type", filter = "categorical",
      default = NULL),

    # --- movable time-period / threshold filters (in-memory sliders over raw
    #     measures carried on the analytic cohort -- no re-query needed) --------
    flt_baseline_ce = list(
      id = "flt_baseline_ce", label = "Baseline CE (months)",
      desc = "Require at least this many months of baseline continuous enrollment.",
      polarity = "incl", phase = "pre_lot", ui_category = "Other",
      type = "param", variable = "baseline_ce_months", filter = "range",
      default = NULL),

    flt_followup_ce = list(
      id = "flt_followup_ce", label = "Follow-up CE (months)",
      desc = "Require at least this many months of follow-up enrollment.",
      polarity = "incl", phase = "post_lot1", ui_category = "Other",
      type = "param", variable = "followup_ce_months", filter = "range",
      default = NULL),

    flt_dx_year = list(
      id = "flt_dx_year", label = "Year of MM diagnosis",
      desc = "Restrict to a diagnosis-year window.",
      polarity = "incl", phase = "pre_lot", ui_category = "Other",
      type = "param", variable = "dx_year", filter = "range", default = NULL),

    flt_lot_init_year = list(
      id = "flt_lot_init_year", label = "Year of 1L initiation",
      desc = "Restrict to a 1L-initiation-year window.",
      polarity = "incl", phase = "pre_lot", ui_category = "Other",
      type = "param", variable = "lot_init_year", filter = "range", default = NULL),

    flt_soc = list(
      id = "flt_soc", label = "1L SOC regimen category",
      desc = "Restrict to selected 1L standard-of-care regimen group(s).",
      polarity = "incl", phase = "post_lot1", ui_category = "Treatments",
      type = "param", variable = "soc_category", filter = "categorical",
      default = NULL)  # NULL = all levels (resolved at runtime from the data)
  )
}

# ---- Cohort definitions -----------------------------------------------------
# A cohort = the set of FLAG criteria active by default + the param filters it
# starts with. These mirror studies/overall.yml and studies/ndmm.yml exactly.
# Param filters always start at their registry default (the user tunes them).
cohort_definitions <- function() {
  list(
    overall = list(
      id = "overall",
      label = "Overall (parent LOT cohort)",
      desc  = paste("Step-6 denominator: qualifying MM + adult + 6m baseline CE",
                    "+ treatment-naive + treated. NDMM-specific exclusions OFF."),
      # Active inclusion/exclusion flags by default:
      active_flags = c("incl_qualifying_mm", "incl_adult",
                       "incl_baseline_ce_6m", "incl_new_user",
                       "incl_fu_mm_agents")
    ),
    ndmm = list(
      id = "ndmm",
      label = "NDMM (1L newly-diagnosed)",
      desc  = paste("Overall + tightened CE (12m baseline, 3m strict follow-up)",
                    "+ eligible-1L-from-2017 + NDMM exclusions",
                    "(no prior MM tx / other cancer / belantamab / pregnancy)."),
      active_flags = c("incl_qualifying_mm", "incl_adult",
                       "incl_eligible_1l_tx",
                       "incl_baseline_ce_12m", "incl_fu_ce_3m",
                       "incl_new_user", "incl_fu_mm_agents",
                       "excl_prior_mm_tx", "excl_other_cancer",
                       "excl_belantamab", "excl_pregnancy")
    )
  )
}

# ---- small registry helpers (used by engine + UI) ---------------------------

# All flag-type criterion ids (the columns build_flagged_cohort must emit).
registry_flag_ids <- function(reg = criteria_registry()) {
  vapply(reg, function(c) if (identical(c$type, "flag")) c$id else NA_character_,
         character(1)) -> ids
  unname(ids[!is.na(ids)])
}

# All param-type criteria.
registry_param_ids <- function(reg = criteria_registry()) {
  vapply(reg, function(c) if (identical(c$type, "param")) c$id else NA_character_,
         character(1)) -> ids
  unname(ids[!is.na(ids)])
}

# Criteria grouped by ui_category, preserving registry order. Returns a named
# list category -> character vector of criterion ids. Drives the accordion.
registry_by_category <- function(reg = criteria_registry()) {
  cats <- vapply(reg, function(c) c$ui_category, character(1))
  ids  <- vapply(reg, function(c) c$id, character(1))
  split(unname(ids), factor(cats, levels = unique(cats)))
}

# Look up one criterion by id (stops if unknown -> fail closed).
registry_get <- function(id, reg = criteria_registry()) {
  if (is.null(reg[[id]])) stop("unknown criterion id: ", id, call. = FALSE)
  reg[[id]]
}
