# =============================================================================
# ie_criteria.R -- the funnel: load the steps, order them, validate them
# -----------------------------------------------------------------------------
# TWO ORDERINGS, and conflating them is how a funnel goes wrong.
#
#   BUILD order   the order the SQL runs in, driven by dependencies.
#                 It is the file numbering: 00 -> 09.
#   FUNNEL order  the order the gates drop patients in, driven by the study's
#                 attrition table. It is the `step` field: 1 -> 10.
#
# They differ. Continuous enrolment (Steps 3-4) is built before age (Step 2)
# because death_dt needs mm_qualifying and therapy needs ce_flags; the attrition
# table still reports age second. Nothing anywhere depends on the two agreeing,
# and `step` is what the funnel is generated from.
#
# ---------------------------------------------------------------------------
# WHAT FAILS CLOSED HERE
# ---------------------------------------------------------------------------
# Every one of these has a matching way to go wrong silently, which is why it is
# checked rather than commented:
#
#   a cfg_key that is not a real configuration key
#       cfg[[typo]] is NULL, isTRUE(NULL) is FALSE, so the criterion would just
#       never apply and the cohort would quietly be larger.
#   a flag_col that ALLFLAGS does not produce
#       the predicate would reference a column that does not exist. On Spark
#       that is an error, but only at RUN time, after the expensive scans.
#   a missing or duplicated funnel step
#       a gap in 1..10 means a criterion was dropped in a refactor.
#   an object name that is not the prefixed, schema-qualified one
#       would collide with the legacy pipeline's object of the same name, and
#       whichever ran second would win. Structurally, work() is the only place a
#       name is formed and ie_stmt() the only place a CREATE is formed -- both
#       from a step's `name` -- so this is asserted, not hoped for.
# =============================================================================

# Build order. The number in the file name IS this order.
IE_STEPS <- list(
  list(file = "00_inputs.R",        fn = "ie_step_inputs"),
  list(file = "01_index.R",         fn = "ie_step_index"),
  list(file = "02_enrollment_ce.R", fn = "ie_step_enrollment_ce"),
  list(file = "03_demographics.R",  fn = "ie_step_demographics"),
  list(file = "04_therapy.R",       fn = "ie_step_therapy"),
  list(file = "05_baseline_mm.R",   fn = "ie_step_baseline_mm"),
  list(file = "06_other_malig.R",   fn = "ie_step_other_malig"),
  list(file = "07_pregnancy.R",     fn = "ie_step_pregnancy"),
  list(file = "08_clintrial.R",     fn = "ie_step_clintrial")
)
IE_ASSEMBLE <- list(file = "09_assemble.R", fn = "ie_step_assemble")

# The funnel is 1..10. Step 0 (">=1 MM dx, any position") is the starting pool,
# not a gate -- it is counted, never applied.
IE_FUNNEL_STEPS <- 1:10

ie_load_steps <- function(dir) {
  for (s in c(IE_STEPS, list(IE_ASSEMBLE))) {
    f <- file.path(dir, s$file)
    if (!file.exists(f))
      stop("missing step file: ", f, call. = FALSE)
    source(f)
    if (!exists(s$fn, mode = "function"))
      stop(s$file, " did not define ", s$fn, "()", call. = FALSE)
  }
  invisible(TRUE)
}

# ---- assemble ---------------------------------------------------------------
ie_funnel <- function(cfg, h = ie_names(cfg), validate = TRUE) {
  views <- list(); criteria <- list()
  for (s in IE_STEPS) {
    part <- do.call(s$fn, list(cfg = cfg, h = h))
    views <- c(views, part$views)
    criteria <- c(criteria, part$criteria)
  }
  # Funnel order, not build order. This is the order the filter and the attrition
  # table are generated in.
  criteria <- criteria[order(vapply(criteria, function(c) c$step, integer(1)))]

  # Assembly last, and it needs the criteria: the final filter is generated from
  # them, so the SQL cannot drift from the declared funnel.
  part <- do.call(IE_ASSEMBLE$fn, list(cfg = cfg, h = h, criteria = criteria))
  views <- c(views, part$views)

  out <- list(views = views, criteria = criteria, cfg = cfg, h = h)
  if (isTRUE(validate)) ie_validate(out)
  out
}

# ---- the funnel, filtered by configuration ---------------------------------
# cfg_key NA means the criterion cannot be switched off (Step 1).
ie_is_active <- function(cr, cfg) {
  if (is.na(cr$cfg_key)) return(TRUE)
  isTRUE(cfg[[cr$cfg_key]])
}
ie_active_criteria <- function(criteria, cfg) {
  Filter(function(cr) ie_is_active(cr, cfg), criteria)
}

# Steps 2-10 as a WHERE fragment, rendered the way build_criteria_sql() renders
# it: each active predicate prefixed with "AND ", joined by newline + 10 spaces.
# Step 1 is excluded because the Step 24 filter emits it on its own line.
ie_criteria_sql <- function(criteria, cfg) {
  act <- ie_active_criteria(criteria, cfg)
  act <- Filter(function(cr) cr$step >= 2L, act)
  paste(vapply(act, function(cr) paste0("AND ", cr$predicate), character(1)),
        collapse = "\n          ")
}

# ---- validation -------------------------------------------------------------
ie_validate <- function(funnel) {
  cfg <- funnel$cfg; criteria <- funnel$criteria; views <- funnel$views

  steps <- vapply(criteria, function(c) c$step, integer(1))
  if (anyDuplicated(steps))
    stop("duplicate IE step(s): ",
         paste(unique(steps[duplicated(steps)]), collapse = ", "), call. = FALSE)
  missing <- setdiff(IE_FUNNEL_STEPS, steps)
  if (length(missing))
    stop("the funnel is incomplete -- no criterion declares step(s) ",
         paste(missing, collapse = ", "),
         ". Every step in criteria_attrition.R's catalog must be represented, ",
         "even one that ships switched off.", call. = FALSE)
  extra <- setdiff(steps, IE_FUNNEL_STEPS)
  if (length(extra))
    stop("step(s) outside the 1-10 funnel: ", paste(extra, collapse = ", "),
         ". Widening the funnel means updating IE_FUNNEL_STEPS and the ",
         "attrition table together.", call. = FALSE)

  ids <- vapply(criteria, function(c) c$id, character(1))
  if (anyDuplicated(ids))
    stop("duplicate criterion id(s): ",
         paste(unique(ids[duplicated(ids)]), collapse = ", "), call. = FALSE)

  # A cfg_key that is not a real key reads as FALSE forever.
  for (cr in criteria) {
    if (is.na(cr$cfg_key)) next
    if (!cr$cfg_key %in% names(cfg))
      stop("criterion '", cr$id, "' has cfg_key '", cr$cfg_key,
           "', which is not a configuration key. It would read as OFF on every ",
           "run and the criterion would never apply. Known keys: ",
           paste(grep("^apply_", names(cfg), value = TRUE), collapse = ", "),
           call. = FALSE)
  }

  vnames <- vapply(views, function(v) v$name, character(1))
  if (anyDuplicated(vnames))
    stop("duplicate table name(s): ",
         paste(unique(vnames[duplicated(vnames)]), collapse = ", "),
         call. = FALSE)

  # Every object this folder creates must be the prefixed, schema-qualified name,
  # and nothing here may create a temporary view (a Databricks SQL warehouse
  # re-runs a view's definition on every reference).
  h <- funnel$h
  for (v in views) {
    stmt <- ie_stmt(v, cfg, h)
    target <- sub("^CREATE OR REPLACE TABLE\\s+", "",
                  regmatches(stmt, regexpr("CREATE OR REPLACE TABLE\\s+\\S+", stmt)))
    if (!identical(target, h$work(v$name)))
      stop("step '", v$name, "' would create ", target, " rather than ",
           h$work(v$name), call. = FALSE)
    if (!grepl(cfg$obj_prefix, target, fixed = TRUE))
      stop("step '", v$name, "' creates ", target, ", which does not carry the '",
           cfg$obj_prefix, "' prefix -- it could overwrite the legacy ",
           "pipeline's object of the same name.", call. = FALSE)
    if (grepl("TEMPORARY VIEW", v$select, ignore.case = TRUE))
      stop("step '", v$name, "' creates a temporary view. Every object here is ",
           "a table; see ie_config.R.", call. = FALSE)
  }

  # Every column a predicate reads has to be produced by the assembly step.
  flags_sql <- Find(function(v) identical(v$name, cfg$flags_view), views)
  if (is.null(flags_sql))
    stop("no step named ", cfg$flags_view,
         " -- the assembly step did not run.", call. = FALSE)
  for (cr in criteria) {
    for (col in cr$flag_col) {
      if (!grepl(paste0("\\b", col, "\\b"), flags_sql$select))
        stop("criterion '", cr$id, "' (step ", cr$step, ") reads column '", col,
             "', which ", cfg$flags_view, " does not produce. Add it to ",
             "steps/09_assemble.R -- the assembly SELECT is explicit, not ",
             "generated from the criteria list.", call. = FALSE)
    }
  }

  invisible(TRUE)
}

# ---- human-readable funnel --------------------------------------------------
ie_print_funnel <- function(funnel) {
  cfg <- funnel$cfg
  cat("\n", strrep("=", 78), "\n", sep = "")
  cat("  COHORT 1 (OVERALL) -- IE FUNNEL\n")
  cat("  window ", cfg$outpatient_window, "d   baseline ", cfg$baseline_days,
      "d   min age ", cfg$min_age, "   ID ", cfg$id_start, " .. ", cfg$id_end,
      "\n", sep = "")
  cat(strrep("=", 78), "\n", sep = "")
  cat(sprintf("  %-4s %-8s %-34s %s\n", "step", "state", "criterion", "predicate"))
  cat(strrep("-", 78), "\n", sep = "")
  cat(sprintf("  %-4s %-8s %-34s %s\n", "0", "count", "base: >=1 MM dx (any position)", "-"))
  for (cr in funnel$criteria) {
    state <- if (is.na(cr$cfg_key)) "always"
             else if (ie_is_active(cr, cfg)) "ON" else "off"
    cat(sprintf("  %-4d %-8s %-34s %s\n", cr$step, state, cr$id, cr$predicate))
  }
  cat(strrep("-", 78), "\n", sep = "")
  off <- Filter(function(cr) !ie_is_active(cr, cfg), funnel$criteria)
  if (length(off)) {
    cat("  ", length(off), " criteri", if (length(off) == 1) "on" else "a",
        " switched OFF by the configuration: ",
        paste(vapply(off, function(c) c$id, character(1)), collapse = ", "),
        "\n", sep = "")
    cat("  The flags are still computed -- they are columns on ",
        funnel$h$work(cfg$flags_view), ".\n", sep = "")
  }
  cat(strrep("=", 78), "\n\n", sep = "")
  invisible(funnel)
}
