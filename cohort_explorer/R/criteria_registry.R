# =============================================================================
# criteria_registry.R  --  reusable IE-criteria registry + cohort definitions
# -----------------------------------------------------------------------------
# This is the single source of truth for the dashboard's Inclusion/Exclusion
# (IE) criteria. It is config-as-R (no yaml dependency) so the engine and the
# Shiny UI are driven by the SAME object.
#
# Design (mirrors the pipeline's cohort gate registry + its IE toggles):
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
# matching a standard "Inclusion Filters" panel layout.
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

criteria_registry <- function() active_pack()$criteria

# ---- Cohort definitions -----------------------------------------------------
# A cohort = the set of FLAG criteria active by default + the param filters it
# starts with. These mirror the pipeline's Overall and NDMM study definitions.
# Param filters always start at their registry default (the user tunes them).
cohort_definitions <- function() active_pack()$cohorts

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
