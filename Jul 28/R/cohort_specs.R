# =============================================================================
# cohort_specs.R -- gate registry + cohort specifications (config-as-R)
# -----------------------------------------------------------------------------
# Single source of truth for WHICH criteria define a cohort. Two cohorts
# (overall, ndmm) are declared as SIBLINGS: neither is derived from the other,
# so `build_cohort.R --cohort=ndmm` is a complete run on its own.
#
# Design (mirrors cohort_explorer/R/criteria_registry.R, applied to the
# production build instead of the Shiny app):
#
#   * The expensive work -- scanning raw claims to produce per-criterion 0/1
#     flags -- is cohort-AGNOSTIC and runs ONCE. It is already implemented:
#       - index-anchored flags  -> ELIG_COH_ALLFLAGS  (pipeline_steps.R step 23)
#       - LOT1-anchored flags   -> NDMM_FLAGS_ALL     (06_ndmm_dashboard.R)
#   * "Building a cohort" = AND-ing a named set of those flags. That is a
#     selection, not a rebuild. Adding a cohort costs a spec entry, not code.
#
# Config-as-R, not YAML, deliberately: the production R environment
# (apr_30_2026) has no `yaml` dependency and drives everything from env vars +
# pipeline_inputs.csv. cohort_explorer made the same call for the same reason.
# The gate ids here are 1:1 with jun_21_2026/cohort/gates/registry.yml, so the
# two representations can be diffed mechanically.
#
# NOTHING in this file changes a cohort DEFINITION. Phase 1 is deliberately
# numerically identical to today's pipeline -- see PLAN.md "Equivalence".
# =============================================================================

# ---- tiny helper: {param} interpolation without a glue dependency -----------
# Base R only, so the spec + SQL layers are testable anywhere (the warehouse
# stack still uses glue; this layer intentionally does not depend on it).
.interp <- function(tmpl, params) {
  out <- tmpl
  for (nm in names(params)) {
    out <- gsub(paste0("{", nm, "}"), as.character(params[[nm]]), out, fixed = TRUE)
  }
  out
}

# ---- anchors ----------------------------------------------------------------
# The anchor is the single most important property of a gate, and the thing the
# old Overall->NDMM chaining blurred. A gate anchored at LOT1_START is NOT a
# re-parameterisation of the same-named gate anchored at INDEX_DATE -- it is a
# different criterion over a different window. jun_21_2026's registry flagged
# this exact hazard for baseline CE (6mo@index vs 12mo@LOT1); encoding `anchor`
# makes it impossible to express that as a parameter override by accident.
ANCHORS <- c("index", "lot1")

# Which materialized flag table each anchor reads from, and the SQL alias used
# for it in generated predicates.
ANCHOR_SOURCE <- list(
  index = list(source = "index_flags", alias = "f"),
  lot1  = list(source = "lot1_flags",  alias = "n")
)

# =============================================================================
# Gate registry
# -----------------------------------------------------------------------------
# Each gate is one criterion. Fields:
#   id         stable key referenced by cohort specs
#   label      human label; may contain {param} placeholders
#   polarity   "incl" | "excl"   (drives attrition wording only)
#   anchor     "index" | "lot1"  (see ANCHORS above)
#   params     default parameter values (may be overridden per cohort)
#   tunable    TRUE  = the parameter filters a RAW column that is present in the
#                      flag table, so changing it is a pure selection change.
#              FALSE = the criterion is a pre-baked fixed-window flag; changing
#                      its window requires REBUILDING the flag table upstream.
#                      Guarding this is the difference between a config knob
#                      that works and one that silently lies.
#   sql        predicate template; {a} is replaced by the source table alias
#   source_col the flag/raw column(s) the predicate reads (checked by tests and
#              used to assert the flag table actually carries them)
#   note       provenance / known divergence, surfaced in the attrition report
# =============================================================================

gate_registry <- function() list(

  # ---- index-anchored (ELIG_COH_ALLFLAGS; pipeline_steps.R step 23) ---------

  idx_qualifying = list(
    id = "idx_qualifying", polarity = "incl", anchor = "index",
    label = "Index qualifies: 1 inpatient MM dx, or 2 outpatient within {outpatient_window}d",
    params = list(outpatient_window = 60L), tunable = TRUE,
    sql = "({a}.inpt_qual = 1 OR {a}.outpt2_{outpatient_window} = 1)",
    source_col = c("inpt_qual", "outpt2_30", "outpt2_60", "outpt2_90"),
    note = "All three outpatient windows are materialized, so the window is selection-time tunable."
  ),

  age_at_index = list(
    id = "age_at_index", polarity = "incl", anchor = "index",
    label = "Age >= {min_age} at index year",
    params = list(min_age = 18L), tunable = TRUE,
    sql = "{a}.AGE_INDEX_YR >= {min_age}",
    source_col = "AGE_INDEX_YR"
  ),

  ce_baseline_6mo = list(
    id = "ce_baseline_6mo", polarity = "incl", anchor = "index",
    label = "Continuous enrollment, 6 months before index (<=30d gaps)",
    params = list(), tunable = FALSE,
    sql = "{a}.CE_b = 1",
    source_col = "CE_b",
    note = "Fixed 6-month window baked into step 14. NOT the same criterion as ce_pre_lot1_12mo."
  ),

  ce_followup_1d = list(
    id = "ce_followup_1d", polarity = "incl", anchor = "index",
    label = "At least 1 day of follow-up enrollment after index",
    params = list(), tunable = FALSE,
    sql = "{a}.CE_f = 1",
    source_col = "CE_f"
  ),

  ce_followup_3mo = list(
    id = "ce_followup_3mo", polarity = "incl", anchor = "index",
    label = "Continuous enrollment, 3 months after index (strict, death-aware)",
    params = list(), tunable = FALSE,
    sql = "{a}.CE_3mosf = 1",
    source_col = "CE_3mosf",
    note = "Materialized by step 23 but unused by Overall today. Index-anchored -- NOT a substitute for ce_fu_lot1_3mo."
  ),

  no_baseline_mm_agents = list(
    id = "no_baseline_mm_agents", polarity = "excl", anchor = "index",
    label = "No MM agents in the baseline window (new-user)",
    params = list(), tunable = FALSE,
    sql = "{a}.MM_bl_agents = 0",
    source_col = "MM_bl_agents"
  ),

  fu_mm_agents = list(
    id = "fu_mm_agents", polarity = "incl", anchor = "index",
    label = "At least one MM agent in follow-up (a treatment start exists)",
    params = list(), tunable = FALSE,
    sql = "{a}.MM_FU_agents = 1",
    source_col = "MM_FU_agents",
    note = "Required by BOTH cohorts: without a 1L start there is no LOT to anchor on."
  ),

  no_baseline_mm_evidence = list(
    id = "no_baseline_mm_evidence", polarity = "excl", anchor = "index",
    label = "No prior MM evidence in the baseline window",
    params = list(), tunable = FALSE,
    sql = "{a}.MM_baseline_diag = 0",
    source_col = "MM_baseline_diag"
  ),

  no_other_cancer_index = list(
    id = "no_other_cancer_index", polarity = "excl", anchor = "index",
    label = "No other malignancy (index-anchored baseline)",
    params = list(), tunable = FALSE,
    sql = "{a}.OTHER_MALIGN_FLAG = 0",
    source_col = "OTHER_MALIGN_FLAG"
  ),

  no_pregnancy_index = list(
    id = "no_pregnancy_index", polarity = "excl", anchor = "index",
    label = "No pregnancy (index-anchored)",
    params = list(), tunable = FALSE,
    sql = "{a}.PREGNANT_FLAG = 0",
    source_col = "PREGNANT_FLAG"
  ),

  no_clintrial = list(
    id = "no_clintrial", polarity = "excl", anchor = "index",
    label = "No clinical-trial participation (baseline or follow-up)",
    params = list(), tunable = FALSE,
    sql = "{a}.CLINTRIAL_BASELINE = 0 AND {a}.CLINTRIAL_FOLLOWUP = 0",
    source_col = c("CLINTRIAL_BASELINE", "CLINTRIAL_FOLLOWUP")
  ),

  # ---- LOT1-anchored (NDMM_FLAGS_ALL; 06_ndmm_dashboard.R) ------------------

  lot1_from = list(
    id = "lot1_from", polarity = "incl", anchor = "lot1",
    label = "1L start on/after {lot1_from}",
    params = list(lot1_from = "2017-01-01"), tunable = TRUE,
    sql = "{a}.LOT1_START_DT >= date('{lot1_from}')",
    source_col = "LOT1_START_DT",
    note = "Filters a raw date column, so the cutoff is selection-time tunable."
  ),

  ce_pre_lot1_12mo = list(
    id = "ce_pre_lot1_12mo", polarity = "incl", anchor = "lot1",
    label = "Continuous enrollment, 12 months before 1L start (<=30d gaps)",
    params = list(), tunable = FALSE,
    sql = "{a}.CE_pre_lot1_12mo = 1",
    source_col = "CE_pre_lot1_12mo",
    note = "A SEPARATE gate from ce_baseline_6mo -- different anchor AND different window."
  ),

  ce_fu_lot1_3mo = list(
    id = "ce_fu_lot1_3mo", polarity = "incl", anchor = "lot1",
    label = "Continuous enrollment, 3 months after 1L start (no gaps, death-aware)",
    params = list(), tunable = FALSE,
    sql = "{a}.CE_lot1_3mo_fu = 1",
    source_col = "CE_lot1_3mo_fu"
  ),

  no_belantamab = list(
    id = "no_belantamab", polarity = "excl", anchor = "lot1",
    label = "No belantamab in any line",
    params = list(), tunable = FALSE,
    sql = "{a}.NO_BELANTAMAB = 1",
    source_col = "NO_BELANTAMAB"
  ),

  no_prior_mm_tx = list(
    id = "no_prior_mm_tx", polarity = "excl", anchor = "lot1",
    label = "No MM oncology therapy in the 12 months before 1L start",
    params = list(), tunable = FALSE,
    sql = "{a}.NO_PRIOR_MM_TX = 1",
    source_col = "NO_PRIOR_MM_TX",
    note = "Deliberately overlaps no_baseline_mm_agents; re-derived from raw claims at the LOT1 anchor."
  ),

  no_other_cancer_pre_lot1 = list(
    id = "no_other_cancer_pre_lot1", polarity = "excl", anchor = "lot1",
    label = "No other active cancer in the 12 months before 1L start",
    params = list(), tunable = FALSE,
    sql = "{a}.NO_OTHER_CANCER_PRE_LOT1 = 1",
    source_col = "NO_OTHER_CANCER_PRE_LOT1",
    note = "Deliberately overlaps no_other_cancer_index; re-anchored and re-derived from raw claims."
  ),

  no_pregnancy_study = list(
    id = "no_pregnancy_study", polarity = "excl", anchor = "lot1",
    label = "No pregnancy code over the study period",
    params = list(), tunable = FALSE,
    sql = "{a}.NO_PREGNANCY = 1",
    source_col = "NO_PREGNANCY",
    note = "Re-scanned from pregnancy.csv over the study period, not carried from the index-anchored flag."
  )
)

# =============================================================================
# Cohort specifications
# -----------------------------------------------------------------------------
# SIBLINGS, not a chain. `ndmm` does not reference `overall` anywhere -- the
# fact that the two index-gate lists are currently IDENTICAL is a statement
# about the study definition, not a code dependency. That is the whole point:
#
#   Decoupling is not redefining.
#
# Phase 1 reproduces today's numbers exactly. Any future divergence in NDMM's
# index gates is a one-line edit here, reviewed by the study team, with no
# pipeline code change and no effect on Overall.
# =============================================================================

# The index gates every 1L-treated MM cohort currently shares. Written once so
# a spec reads as a definition, not a copy-paste; both cohorts still list their
# gates EXPLICITLY (via this constant) rather than inheriting them.
INDEX_GATES_1L_TREATED_MM <- c(
  "idx_qualifying",
  "age_at_index",
  "ce_baseline_6mo",
  "ce_followup_1d",
  "no_baseline_mm_agents",
  "fu_mm_agents",
  "no_baseline_mm_evidence",
  "no_other_cancer_index",
  "no_pregnancy_index",
  "no_clintrial"
)

cohort_specs <- function() list(

  overall = list(
    id       = "overall",
    label    = "Overall MM (1L-treated)",
    flag_col = "COHORT_OVERALL",
    desc     = paste("Every 1L-treated MM patient passing the index-anchored IE",
                     "funnel. Equivalent to today's ELIG_COH_FINAL."),
    gates    = INDEX_GATES_1L_TREATED_MM,
    params   = list()   # registry defaults; cfg supplies min_age / outpatient_window
  ),

  ndmm = list(
    id       = "ndmm",
    label    = "NDMM (newly diagnosed, 1L)",
    flag_col = "COHORT_NDMM",
    desc     = paste("Newly-diagnosed 1L cohort: the same index-anchored funnel",
                     "plus six LOT1-anchored criteria and a 1L start cutoff.",
                     "Runs standalone -- no Overall run required."),
    gates    = c(INDEX_GATES_1L_TREATED_MM,
                 "lot1_from",
                 "ce_pre_lot1_12mo",
                 "ce_fu_lot1_3mo",
                 "no_belantamab",
                 "no_prior_mm_tx",
                 "no_other_cancer_pre_lot1",
                 "no_pregnancy_study"),
    params   = list()
  )
)

# =============================================================================
# Resolution + validation
# =============================================================================

# Resolve a spec into an ordered list of gates with parameters filled in.
# Order is ALWAYS index-anchored gates first, then LOT1-anchored, regardless of
# how the spec lists them: a LOT1-anchored gate cannot be evaluated before the
# index is selected and the LOT build has run. Spec order is preserved within
# each anchor so the attrition funnel reads in the study team's order.
resolve_spec <- function(spec, cfg = list(), reg = gate_registry()) {
  validate_spec(spec, reg)
  gates <- lapply(spec$gates, function(gid) {
    g <- reg[[gid]]
    p <- g$params
    # Precedence: registry default < cfg (pipeline-wide) < spec params (per cohort).
    for (nm in names(p)) if (!is.null(cfg[[nm]])) p[[nm]] <- cfg[[nm]]
    for (nm in names(spec$params[[gid]])) p[[nm]] <- spec$params[[gid]][[nm]]
    g$resolved_params <- p
    g$label_resolved  <- .interp(g$label, p)
    g$alias           <- ANCHOR_SOURCE[[g$anchor]]$alias
    g$source          <- ANCHOR_SOURCE[[g$anchor]]$source
    g$predicate       <- .interp(.interp(g$sql, p), list(a = g$alias))
    g
  })
  names(gates) <- spec$gates
  ord <- order(match(vapply(gates, `[[`, character(1), "anchor"), ANCHORS),
               seq_along(gates))
  gates <- gates[ord]
  # Stamp the funnel position AFTER ordering so attrition ids are contiguous
  # and sort lexically (01_, 02_, ...) in the report.
  for (i in seq_along(gates)) {
    gates[[i]]$step_no <- i
    gates[[i]]$attrition_id <- sprintf("%02d_%s", i, gates[[i]]$id)
  }
  spec$resolved_gates <- gates
  spec$anchors_used   <- unique(vapply(gates, `[[`, character(1), "anchor"))
  spec
}

# Fail closed: an unknown gate id, an unknown parameter, or a duplicate is a
# spec bug that would otherwise silently produce a WRONG cohort.
validate_spec <- function(spec, reg = gate_registry()) {
  for (f in c("id", "label", "flag_col", "gates"))
    if (is.null(spec[[f]]))
      stop("cohort spec is missing required field: ", f, call. = FALSE)
  if (!length(spec$gates))
    stop("cohort spec '", spec$id, "' declares no gates.", call. = FALSE)

  dup <- unique(spec$gates[duplicated(spec$gates)])
  if (length(dup))
    stop("cohort spec '", spec$id, "' lists duplicate gates: ",
         paste(dup, collapse = ", "), call. = FALSE)

  unknown <- setdiff(spec$gates, names(reg))
  if (length(unknown))
    stop("cohort spec '", spec$id, "' references unknown gates: ",
         paste(unknown, collapse = ", "), call. = FALSE)

  for (gid in names(spec$params)) {
    if (!gid %in% spec$gates)
      stop("cohort spec '", spec$id, "' parameterises gate '", gid,
           "' which it does not declare.", call. = FALSE)
    bad <- setdiff(names(spec$params[[gid]]), names(reg[[gid]]$params))
    if (length(bad))
      stop("cohort spec '", spec$id, "', gate '", gid, "': unknown parameter(s) ",
           paste(bad, collapse = ", "), call. = FALSE)
    # A non-tunable gate's window is baked into the upstream flag build. Letting
    # a spec "override" it would produce a cohort that does not match its own
    # stated definition -- refuse loudly instead.
    if (!isTRUE(reg[[gid]]$tunable) && length(spec$params[[gid]]))
      stop("cohort spec '", spec$id, "', gate '", gid, "' is not selection-time ",
           "tunable: its window is baked into the upstream flag table. Change it ",
           "in the flag build and rebuild, or add a new gate id.", call. = FALSE)
  }
  invisible(TRUE)
}

# Flag columns each anchor's source table must carry for a set of specs. The
# build asserts these against the live schema before generating any SQL, so a
# renamed upstream column fails at step 0 rather than silently dropping a
# criterion from the cohort definition.
required_source_cols <- function(specs, reg = gate_registry()) {
  gids <- unique(unlist(lapply(specs, `[[`, "gates")))
  out <- list()
  for (a in ANCHORS) {
    cols <- unique(unlist(lapply(gids, function(g)
      if (identical(reg[[g]]$anchor, a)) reg[[g]]$source_col else NULL)))
    out[[ANCHOR_SOURCE[[a]]$source]] <- sort(cols)
  }
  out
}

# Does this spec need the LOT build (and therefore the LOT1-anchored flags)?
# Overall does not; NDMM does. Used to skip the LOT1 joins entirely for
# cohorts that have no LOT1-anchored gates -- Overall's generated SQL stays
# byte-comparable to today's step 24.
needs_lot1 <- function(spec) "lot1" %in%
  vapply(spec$resolved_gates %||% list(), `[[`, character(1), "anchor")

`%||%` <- function(x, y) if (is.null(x)) y else x
