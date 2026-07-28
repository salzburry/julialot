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
#   cfg_key    the production toggle that decides whether this criterion is
#              APPLIED (criteria_attrition.R's cfg_key; pipeline_inputs.csv sets
#              it). NA_character_ = always applied, either because the pipeline
#              has no toggle for it (the step-1 index gate, every LOT1-anchored
#              criterion) or because it is not in the catalog at all.
#
#              A gate whose toggle is FALSE is still DECLARED and still emitted
#              as a PLD column -- it is simply not AND-ed into membership and
#              not counted in the funnel. That is the whole point of the flag
#              design: turning a criterion off changes the selection, not the
#              data.
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
    id = "idx_qualifying", cfg_key = NA_character_, polarity = "incl", anchor = "index",
    label = "Index qualifies: 1 inpatient MM dx, or 2 outpatient within {outpatient_window}d",
    params = list(outpatient_window = 60L), tunable = TRUE,
    sql = "({a}.inpt_qual = 1 OR {a}.outpt2_{outpatient_window} = 1)",
    source_col = c("inpt_qual", "outpt2_30", "outpt2_60", "outpt2_90"),
    note = "All three outpatient windows are materialized, so the window is selection-time tunable."
  ),

  age_at_index = list(
    id = "age_at_index", cfg_key = "apply_age_incl", polarity = "incl", anchor = "index",
    label = "Age >= {min_age} at index year",
    params = list(min_age = 18L), tunable = TRUE,
    sql = "{a}.AGE_INDEX_YR >= {min_age}",
    source_col = "AGE_INDEX_YR"
  ),

  ce_baseline_6mo = list(
    id = "ce_baseline_6mo", cfg_key = "apply_ce_b_incl", polarity = "incl", anchor = "index",
    label = "Continuous enrollment, 6 months before index (<=30d gaps)",
    params = list(), tunable = FALSE,
    sql = "{a}.CE_b = 1",
    source_col = "CE_b",
    note = "Fixed 6-month window baked into step 14. NOT the same criterion as ce_pre_lot1_12mo."
  ),

  ce_followup_1d = list(
    id = "ce_followup_1d", cfg_key = "apply_ce_f_incl", polarity = "incl", anchor = "index",
    label = "At least 1 day of follow-up enrollment after index",
    params = list(), tunable = FALSE,
    sql = "{a}.CE_f = 1",
    source_col = "CE_f"
  ),

  ce_followup_3mo = list(
    id = "ce_followup_3mo", cfg_key = NA_character_, polarity = "incl", anchor = "index",
    label = "Continuous enrollment, 3 months after index (strict, death-aware)",
    params = list(), tunable = FALSE,
    sql = "{a}.CE_3mosf = 1",
    source_col = "CE_3mosf",
    note = "Materialized by step 23 but unused by Overall today. Index-anchored -- NOT a substitute for ce_fu_lot1_3mo."
  ),

  no_baseline_mm_agents = list(
    id = "no_baseline_mm_agents", cfg_key = "apply_no_bl_agents_incl", polarity = "excl", anchor = "index",
    label = "No MM agents in the baseline window (new-user)",
    params = list(), tunable = FALSE,
    sql = "{a}.MM_bl_agents = 0",
    source_col = "MM_bl_agents"
  ),

  fu_mm_agents = list(
    id = "fu_mm_agents", cfg_key = "apply_fu_agents_incl", polarity = "incl", anchor = "index",
    label = "At least one MM agent claim in follow-up (any drug class)",
    params = list(), tunable = FALSE,
    sql = "{a}.MM_FU_agents = 1",
    source_col = "MM_FU_agents",
    note = paste(
      "ANY code in cl_mma_codelist, with NO drug-class filter (pipeline_steps.R:723)",
      "-- steroids included. This is NOT the same as having a LOT1: 02_lot1.R:678",
      "derives LOT1_START_DT as min(MAP_START_DT) WHERE MAP_MED_CLASS <> 'STEROID'.",
      "A patient whose only follow-up MM agents are steroids satisfies THIS gate but",
      "has no LOT1 row. Overall wants that patient; NDMM cannot use them (no anchor).",
      "See has_lot1.")
  ),

  no_baseline_mm_evidence = list(
    id = "no_baseline_mm_evidence", cfg_key = "apply_baseline_mm_excl", polarity = "excl", anchor = "index",
    label = "No prior MM evidence in the baseline window",
    params = list(), tunable = FALSE,
    sql = "{a}.MM_baseline_diag = 0",
    source_col = "MM_baseline_diag"
  ),

  no_other_cancer_index = list(
    id = "no_other_cancer_index", cfg_key = "apply_other_malig_excl", polarity = "excl", anchor = "index",
    label = "No other malignancy (index-anchored baseline)",
    params = list(), tunable = FALSE,
    sql = "{a}.OTHER_MALIGN_FLAG = 0",
    source_col = "OTHER_MALIGN_FLAG"
  ),

  no_pregnancy_index = list(
    id = "no_pregnancy_index", cfg_key = "apply_pregnancy_excl", polarity = "excl", anchor = "index",
    label = "No pregnancy (index-anchored)",
    params = list(), tunable = FALSE,
    sql = "{a}.PREGNANT_FLAG = 0",
    source_col = "PREGNANT_FLAG"
  ),

  no_clintrial = list(
    id = "no_clintrial", cfg_key = "apply_clintrial_excl", polarity = "excl", anchor = "index",
    label = "No clinical-trial participation (baseline or follow-up)",
    params = list(), tunable = FALSE,
    sql = "{a}.CLINTRIAL_BASELINE = 0 AND {a}.CLINTRIAL_FOLLOWUP = 0",
    source_col = c("CLINTRIAL_BASELINE", "CLINTRIAL_FOLLOWUP")
  ),

  # ---- LOT1-anchored (NDMM_FLAGS_ALL; 06_ndmm_dashboard.R) ------------------

  has_lot1 = list(
    id = "has_lot1", cfg_key = NA_character_, polarity = "incl", anchor = "lot1",
    label = "A LOT1 regimen start exists (non-steroid MM agent)",
    params = list(), tunable = FALSE,
    sql = "{a}.LOT1_START_DT IS NOT NULL",
    source_col = "LOT1_START_DT",
    note = paste(
      "STRICTLY STRONGER than fu_mm_agents, which counts any MM agent including",
      "steroids. The existing build already applies this correctly (INNER JOIN on",
      "NDMM_LOT1_STARTS, 06_ndmm_dashboard.R:658) AND already reports it",
      "(ndmm_counts()$elig_lot1 at :806, rendered at :900). The only change here is",
      "granularity: NDMM_LOT1_STARTS bakes the >= NDMM_LOT1_FROM cutoff into its",
      "definition (:207), so that one reported row fuses 'has a non-steroid",
      "regimen' with 'started on/after the cutoff'. Splitting them into has_lot1 +",
      "lot1_from separates the two counts. Same patients either way.")
  ),

  lot1_from = list(
    id = "lot1_from", cfg_key = NA_character_, polarity = "incl", anchor = "lot1",
    label = "1L start on/after {lot1_from}",
    params = list(lot1_from = "2017-01-01"), tunable = TRUE,
    sql = "{a}.LOT1_START_DT >= date('{lot1_from}')",
    source_col = "LOT1_START_DT",
    note = "Filters a raw date column, so the cutoff is selection-time tunable."
  ),

  ce_pre_lot1_12mo = list(
    id = "ce_pre_lot1_12mo", cfg_key = NA_character_, polarity = "incl", anchor = "lot1",
    label = "Continuous enrollment, 12 months before 1L start (<=30d gaps)",
    params = list(), tunable = FALSE,
    sql = "{a}.CE_pre_lot1_12mo = 1",
    source_col = "CE_pre_lot1_12mo",
    note = "A SEPARATE gate from ce_baseline_6mo -- different anchor AND different window."
  ),

  ce_fu_lot1_3mo = list(
    id = "ce_fu_lot1_3mo", cfg_key = NA_character_, polarity = "incl", anchor = "lot1",
    label = "Continuous enrollment, 3 months after 1L start (no gaps, death-aware)",
    params = list(), tunable = FALSE,
    sql = "{a}.CE_lot1_3mo_fu = 1",
    source_col = "CE_lot1_3mo_fu"
  ),

  no_belantamab = list(
    id = "no_belantamab", cfg_key = NA_character_, polarity = "excl", anchor = "lot1",
    label = "No belantamab in any line",
    params = list(), tunable = FALSE,
    sql = "{a}.NO_BELANTAMAB = 1",
    source_col = "NO_BELANTAMAB"
  ),

  no_prior_mm_tx = list(
    id = "no_prior_mm_tx", cfg_key = NA_character_, polarity = "excl", anchor = "lot1",
    label = "No MM oncology therapy in the 12 months before 1L start",
    params = list(), tunable = FALSE,
    sql = "{a}.NO_PRIOR_MM_TX = 1",
    source_col = "NO_PRIOR_MM_TX",
    note = "Deliberately overlaps no_baseline_mm_agents; re-derived from raw claims at the LOT1 anchor."
  ),

  no_other_cancer_pre_lot1 = list(
    id = "no_other_cancer_pre_lot1", cfg_key = NA_character_, polarity = "excl", anchor = "lot1",
    label = "No other active cancer in the 12 months before 1L start",
    params = list(), tunable = FALSE,
    sql = "{a}.NO_OTHER_CANCER_PRE_LOT1 = 1",
    source_col = "NO_OTHER_CANCER_PRE_LOT1",
    note = "Deliberately overlaps no_other_cancer_index; re-anchored and re-derived from raw claims."
  ),

  no_pregnancy_study = list(
    id = "no_pregnancy_study", cfg_key = NA_character_, polarity = "excl", anchor = "lot1",
    label = "No pregnancy code over the study period",
    params = list(), tunable = FALSE,
    sql = "{a}.NO_PREGNANCY = 1",
    source_col = "NO_PREGNANCY",
    note = "Re-scanned from pregnancy.csv over the study period, not carried from the index-anchored flag."
  )
)

# =============================================================================
# Cohort specifications -- ONE FILE PER COHORT, loaded from cohorts/
# -----------------------------------------------------------------------------
#   cohorts/overall.R   the Overall cohort, complete
#   cohorts/ndmm.R      the NDMM cohort, complete
#
# SIBLINGS, not a chain. Neither file references the other, neither inherits
# from the other, and each spells out its own gate list in full. Editing one
# cannot change the other -- there is no shared constant to edit by accident.
#
#   Decoupling is not redefining.
#
# The two index-gate lists are currently IDENTICAL. That is a statement about
# the study definition, not a code dependency, and it is what makes Phase 1
# numerically a no-op. `index_gate_diff()` below reports drift between them so
# the agreement stays a REVIEWED fact rather than an assumed one.
#
# Adding a cohort = adding a file. Nothing else changes.
# =============================================================================

# One FOLDER per cohort, each holding everything for that cohort:
#
#   overall/          ndmm/
#     cohort.R          cohort.R              <- the definition (this loader)
#     build.R           build.R               <- its entry point
#     tests/            build_lot1_flags.R    <- NDMM also needs the flag stage
#                       tests/
#
# A cohort is discovered by the presence of <folder>/cohort.R. Adding a cohort
# is adding a folder; no engine file changes.
#
# The engine itself (this file, cohort_sql.R, cohort_run.R) is SHARED at
# Jul 28/engine/ rather than copied into each folder -- the cohort DEFINITIONS
# are separate, the SQL generator is written once. If a folder ever needs to be
# genuinely portable on its own, copy engine/ into it and set COHORT_ENGINE_DIR.
COHORT_FILE <- "cohort.R"

# Locate the Jul 28 root (the folder holding the cohort folders).
default_cohort_root <- function() {
  here <- tryCatch(dirname(normalizePath(sys.frame(1)$ofile)),
                   error = function(e) NULL)
  cand <- c(if (!is.null(here)) dirname(here),   # engine/ -> root
            getwd(), dirname(getwd()))
  hit <- Filter(function(d) length(Sys.glob(file.path(d, "*", COHORT_FILE))) > 0, cand)
  if (!length(hit))
    stop("cannot locate any <cohort>/", COHORT_FILE, " (looked in: ",
         paste(cand, collapse = ", "), ")", call. = FALSE)
  hit[1]
}

# Load every cohort folder. Each cohort.R's last expression IS its spec (a
# list), so a definition is a plain data literal with no registration
# side-effects -- readable, diffable and reviewable on its own.
cohort_specs <- function(root = NULL) {
  root  <- root %||% .COHORT_ROOT_CACHE %||% default_cohort_root()
  files <- sort(Sys.glob(file.path(root, "*", COHORT_FILE)))
  if (!length(files))
    stop("no <cohort>/", COHORT_FILE, " found under ", root, call. = FALSE)

  specs <- lapply(files, function(f) {
    s <- tryCatch(source(f, local = new.env())$value,
                  error = function(e)
                    stop("failed to load ", basename(dirname(f)), "/",
                         basename(f), ": ", conditionMessage(e), call. = FALSE))
    if (!is.list(s) || is.null(s$id))
      stop(basename(dirname(f)), "/", basename(f), " must evaluate to a spec ",
           "list with an `id` field as its final expression.", call. = FALSE)
    s$folder      <- basename(dirname(f))
    s$source_file <- file.path(s$folder, basename(f))
    # The folder name IS the cohort id. Anything else makes "which folder builds
    # this cohort?" a lookup instead of an answer.
    if (!identical(s$folder, s$id))
      stop("cohort id '", s$id, "' does not match its folder '", s$folder,
           "'. Rename one so they agree.", call. = FALSE)
    s
  })

  ids <- vapply(specs, `[[`, character(1), "id")
  if (anyDuplicated(ids))
    stop("duplicate cohort id(s): ",
         paste(unique(ids[duplicated(ids)]), collapse = ", "), call. = FALSE)

  # Explicit `order` (not folder name) drives multi-cohort runs, so the PLD's
  # column order and the step order are stable however the folders are named.
  ord <- order(vapply(specs, function(s) as.integer(s$order %||% 100L), integer(1)),
               ids)
  stats::setNames(specs[ord], ids[ord])
}

.COHORT_ROOT_CACHE <- NULL
set_cohort_root <- function(root) {
  if (!length(Sys.glob(file.path(root, "*", COHORT_FILE))))
    stop("no <cohort>/", COHORT_FILE, " under: ", root, call. = FALSE)
  .COHORT_ROOT_CACHE <<- root
  invisible(root)
}

# Report where two cohorts' index-anchored gates differ. Separate files mean the
# lists CAN drift; this makes drift visible instead of silent. Used by the tests
# and printed by the build so an unintended divergence is caught at review.
# (Separate FOLDERS make this more important, not less.)
index_gate_diff <- function(a, b, reg = gate_registry()) {
  idx <- function(s) Filter(function(g) identical(reg[[g]]$anchor, "index"), s$gates)
  ga <- idx(a); gb <- idx(b)
  list(only_in_a = setdiff(ga, gb),
       only_in_b = setdiff(gb, ga),
       reordered = identical(sort(ga), sort(gb)) && !identical(ga, gb),
       identical = identical(ga, gb))
}

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
    # ACTIVE = applied to membership. Mirrors build_criteria_sql()'s
    # `if (isTRUE(cfg[[cr$cfg_key]]))` exactly, including its isTRUE(): an
    # absent or NA toggle counts as OFF there, so it must here too.
    g$active <- if (is.na(g$cfg_key)) TRUE else isTRUE(cfg[[g$cfg_key]])
    g
  })
  names(gates) <- spec$gates
  ord <- order(match(vapply(gates, `[[`, character(1), "anchor"), ANCHORS),
               seq_along(gates))
  gates <- gates[ord]
  # Stamp the funnel position AFTER ordering so attrition ids are contiguous
  # and sort lexically (01_, 02_, ...) in the report.
  # Number the funnel over APPLIED gates only: an inactive criterion has no
  # attrition row, so contiguous ids must skip it rather than leave a hole.
  n <- 0L
  for (i in seq_along(gates)) {
    if (isTRUE(gates[[i]]$active)) {
      n <- n + 1L
      gates[[i]]$step_no <- n
      gates[[i]]$attrition_id <- sprintf("%02d_%s", n, gates[[i]]$id)
    } else {
      gates[[i]]$step_no <- NA_integer_
      gates[[i]]$attrition_id <- NA_character_
    }
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
# Columns needed by the gates that will actually be APPLIED. A disabled
# criterion reads nothing, so requiring its column would fail a run for a
# criterion the configuration has turned off.
required_source_cols <- function(specs, reg = gate_registry()) {
  gids <- unique(unlist(lapply(specs, function(s)
    if (!is.null(s$resolved_gates))
      vapply(active_gates(s), `[[`, character(1), "id") else s$gates)))
  out <- list()
  for (a in ANCHORS) {
    cols <- unique(unlist(lapply(gids, function(g)
      if (identical(reg[[g]]$anchor, a)) reg[[g]]$source_col else NULL)))
    out[[ANCHOR_SOURCE[[a]]$source]] <- sort(cols)
  }
  out
}

# The gates actually applied. Every SQL builder uses THIS, never resolved_gates
# directly -- a gate the configuration disables must not reach a predicate.
active_gates <- function(spec)
  Filter(function(g) isTRUE(g$active), spec$resolved_gates %||% list())

# Does this spec need the LOT build (and therefore the LOT1-anchored flags)?
# Overall does not; NDMM does. Used to skip the LOT1 joins entirely for
# cohorts that have no LOT1-anchored gates -- Overall's generated SQL stays
# byte-comparable to today's step 24.
needs_lot1 <- function(spec) "lot1" %in%
  vapply(active_gates(spec), `[[`, character(1), "anchor")

`%||%` <- function(x, y) if (is.null(x)) y else x
