# =============================================================================
# cohort_select.R  --  reusable cohort selection from flags + live filters
# -----------------------------------------------------------------------------
# Given the flagged superset cohort and a set of ACTIVE criteria (flag toggles
# + param-filter values), return the selected sub-cohort and a step-by-step
# attrition waterfall. This is the "upon loading the flags the right cohort is
# selected" step, and it is a pure function -- no Shiny, no globals -- so it is
# unit-testable and reusable outside the app.
# =============================================================================

# Resolve which flag criteria are active: start from the cohort default set,
# then apply the user's checkbox overrides (named logical vector id -> on/off).
resolve_active_flags <- function(cohort_def, overrides = NULL,
                                 reg = criteria_registry()) {
  active <- cohort_def$active_flags
  if (!is.null(overrides)) {
    on  <- names(overrides)[isTRUE_vec(overrides)]
    off <- names(overrides)[!isTRUE_vec(overrides)]
    active <- union(setdiff(active, off), intersect(on, registry_flag_ids(reg)))
  }
  # keep registry order for stable attrition ordering
  intersect(registry_flag_ids(reg), active)
}

isTRUE_vec <- function(x) vapply(x, isTRUE, logical(1))

# Evaluate a single criterion -> logical keep mask over rows of df.
.criterion_mask <- function(df, crit, param_values = list()) {
  if (identical(crit$type, "flag")) {
    return(df[[crit$id]] == crit$keep_when)
  }
  # param filter
  v   <- df[[crit$variable]]
  val <- param_values[[crit$id]]
  if (is.null(val)) return(rep(TRUE, nrow(df)))          # no restriction
  if (identical(crit$filter, "range")) {
    return(!is.na(v) & v >= val[1] & v <= val[2])
  }
  if (identical(crit$filter, "categorical")) {
    if (length(val) == 0) return(rep(TRUE, nrow(df)))    # nothing selected = all
    # NA-safe: a missing value is its own "(Missing)" level, so a NEUTRAL filter
    # (all levels incl "(Missing)" selected) never silently drops NA rows -- only
    # an explicit deselect of "(Missing)" removes them. (v %in% val alone is
    # FALSE for NA and would quietly shrink the cohort with no filter applied.)
    cats <- as.character(v); cats[is.na(cats)] <- "(Missing)"
    return(cats %in% val)
  }
  stop("unknown filter type for ", crit$id, call. = FALSE)
}

# categorical levels for a variable, with NA rendered as an explicit
# "(Missing)" level (used by the UI control + neutral defaults so NA is
# selectable and never dropped by a neutral filter).
cat_levels <- function(v) {
  l <- as.character(v); l[is.na(l)] <- "(Missing)"; sort(unique(l))
}

# Main entry: select a cohort.
#   df             flagged superset cohort
#   active_flags   character vector of active flag-criterion ids
#   param_values   named list id -> control value (range c(lo,hi) / char vec)
#   active_params  character vector of active param-criterion ids (default: all
#                  params that have a non-NULL value)
# Returns list(data = sub-cohort df, attrition = data.frame, n_in = , n_out = ).
select_cohort <- function(df, active_flags = character(),
                          param_values = list(),
                          active_params = NULL,
                          reg = criteria_registry()) {
  if (is.null(active_params)) active_params <- names(param_values)

  # criterion application order: study_period -> pre_lot -> post_lot1, and
  # within a phase, flags before params, registry order otherwise. This makes
  # the attrition funnel read like the protocol.
  phase_rank <- c(study_period = 1L, pre_lot = 2L, post_lot1 = 3L)
  ids <- c(active_flags, active_params)
  ids <- ids[!duplicated(ids)]
  if (length(ids)) {
    ord <- order(
      phase_rank[vapply(ids, function(i) registry_get(i, reg)$phase, character(1))],
      match(ids, names(reg)))
    ids <- ids[ord]
  }

  keep <- rep(TRUE, nrow(df))
  rows <- list()
  n_prev <- sum(keep)
  rows[[length(rows) + 1L]] <- data.frame(
    step = 0L, criterion = tryCatch(active_pack()$superset_label,
                                    error = function(e) "Superset (1L-treated)"),
    polarity = "base", n_remaining = n_prev, n_dropped = 0L,
    stringsAsFactors = FALSE)

  for (i in seq_along(ids)) {
    crit <- registry_get(ids[i], reg)
    keep <- keep & .criterion_mask(df, crit, param_values)
    n_now <- sum(keep)
    rows[[length(rows) + 1L]] <- data.frame(
      step = i, criterion = crit$label, polarity = crit$polarity,
      n_remaining = n_now, n_dropped = n_prev - n_now,
      stringsAsFactors = FALSE)
    n_prev <- n_now
  }

  list(
    data      = df[keep, , drop = FALSE],
    attrition = do.call(rbind, rows),
    n_in      = nrow(df),
    n_out     = sum(keep))
}

# Convenience: levels available for a categorical param filter (for the UI).
param_levels <- function(df, crit_id, reg = criteria_registry()) {
  crit <- registry_get(crit_id, reg)
  if (!identical(crit$type, "param")) return(NULL)
  v <- df[[crit$variable]]
  if (identical(crit$filter, "range")) return(range(v, na.rm = TRUE))
  cat_levels(v)
}
