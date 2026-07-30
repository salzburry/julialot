# =============================================================================
# ie_criteria.R -- load the steps, order the funnel, validate it
# -----------------------------------------------------------------------------
# Two orderings, and they are not the same:
#   build order   what depends on what. The file numbers, 00 -> 09.
#   funnel order  what drops whom. The `step` field, 1 -> 10.
#
# CE (steps 3-4) is built before age (step 2) because death_dt needs
# mm_qualifying and therapy needs ce_flags. The attrition table still reports age
# second. `step` is what the funnel is generated from.
# =============================================================================

# Build order.
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

# Step 0 (">=1 MM dx") is the starting pool, not a gate. It is counted, never
# applied.
IE_FUNNEL_STEPS <- 1:10

ie_load_steps <- function(dir) {
  for (s in c(IE_STEPS, list(IE_ASSEMBLE))) {
    f <- file.path(dir, s$file)
    if (!file.exists(f)) stop("missing step file: ", f, call. = FALSE)
    source(f)
    if (!exists(s$fn, mode = "function"))
      stop(s$file, " did not define ", s$fn, "()", call. = FALSE)
  }
  invisible(TRUE)
}

ie_funnel <- function(cfg, h = ie_names(cfg), validate = TRUE) {
  views <- list(); criteria <- list()
  for (s in IE_STEPS) {
    part <- do.call(s$fn, list(cfg = cfg, h = h))
    views <- c(views, part$views)
    criteria <- c(criteria, part$criteria)
  }
  criteria <- criteria[order(vapply(criteria, function(c) c$step, integer(1)))]
  # Assembly last: it generates the final filter from the criteria, so the SQL
  # cannot drift from the declared funnel.
  views <- c(views, do.call(IE_ASSEMBLE$fn,
                            list(cfg = cfg, h = h, criteria = criteria))$views)

  out <- list(views = views, criteria = criteria, cfg = cfg, h = h)
  if (isTRUE(validate)) ie_validate(out)
  out
}

# cfg_key NA means the gate cannot be switched off (step 1).
ie_is_active <- function(cr, cfg) {
  if (is.na(cr$cfg_key)) return(TRUE)
  isTRUE(cfg[[cr$cfg_key]])
}
ie_active_criteria <- function(criteria, cfg)
  Filter(function(cr) ie_is_active(cr, cfg), criteria)

# Steps 2-10 as a WHERE fragment, rendered the way build_criteria_sql() does:
# "AND <predicate>", joined by newline + 10 spaces. Step 1 is left out because
# the legacy step 24 filter emits it on its own line.
ie_criteria_sql <- function(criteria, cfg) {
  act <- Filter(function(cr) cr$step >= 2L, ie_active_criteria(criteria, cfg))
  paste(vapply(act, function(cr) paste0("AND ", cr$predicate), character(1)),
        collapse = "\n          ")
}

# ---- validation -------------------------------------------------------------
# Each of these has a matching way to go wrong quietly, which is why it is
# checked and not just commented.
ie_validate <- function(funnel) {
  cfg <- funnel$cfg; criteria <- funnel$criteria; views <- funnel$views
  h <- funnel$h

  steps <- vapply(criteria, function(c) c$step, integer(1))
  if (anyDuplicated(steps))
    stop("duplicate IE step(s): ",
         paste(unique(steps[duplicated(steps)]), collapse = ", "), call. = FALSE)
  gap <- setdiff(IE_FUNNEL_STEPS, steps)
  if (length(gap))
    stop("no criterion declares step(s) ", paste(gap, collapse = ", "),
         ". A gap means a criterion was lost -- every step in the attrition ",
         "catalog has to be here, even one that ships off.", call. = FALSE)
  extra <- setdiff(steps, IE_FUNNEL_STEPS)
  if (length(extra))
    stop("step(s) outside 1-10: ", paste(extra, collapse = ", "),
         ". Widening the funnel means updating the attrition table too.",
         call. = FALSE)

  ids <- vapply(criteria, function(c) c$id, character(1))
  if (anyDuplicated(ids))
    stop("duplicate criterion id(s): ",
         paste(unique(ids[duplicated(ids)]), collapse = ", "), call. = FALSE)

  # A cfg_key that is not a real key reads as FALSE forever, so the gate never
  # applies and the cohort is quietly larger.
  for (cr in criteria) {
    if (is.na(cr$cfg_key)) next
    if (!cr$cfg_key %in% names(cfg))
      stop("criterion '", cr$id, "' has cfg_key '", cr$cfg_key,
           "', which is not a config key -- it would read as OFF on every run. ",
           "Known: ", paste(grep("^apply_", names(cfg), value = TRUE),
                            collapse = ", "), call. = FALSE)
  }

  vnames <- vapply(views, function(v) v$name, character(1))
  if (anyDuplicated(vnames))
    stop("duplicate table name(s): ",
         paste(unique(vnames[duplicated(vnames)]), collapse = ", "),
         call. = FALSE)

  # Every object must be the prefixed, qualified name, and nothing may create a
  # view. An unprefixed name would collide with the legacy pipeline's object.
  for (v in views) {
    stmt <- ie_stmt(v, cfg, h)
    target <- sub("^CREATE OR REPLACE TABLE\\s+", "",
                  regmatches(stmt, regexpr("CREATE OR REPLACE TABLE\\s+\\S+",
                                           stmt)))
    if (!identical(target, h$work(v$name)))
      stop("step '", v$name, "' would create ", target, ", not ",
           h$work(v$name), call. = FALSE)
    if (!grepl(cfg$obj_prefix, target, fixed = TRUE))
      stop("step '", v$name, "' creates ", target, " without the '",
           cfg$obj_prefix, "' prefix.", call. = FALSE)
    if (grepl("TEMPORARY VIEW", v$select, ignore.case = TRUE))
      stop("step '", v$name, "' creates a temporary view.", call. = FALSE)
  }

  # A predicate reading a column the assembly does not produce would error only
  # at run time, after the expensive scans.
  flags <- Find(function(v) identical(v$name, cfg$flags_view), views)
  if (is.null(flags))
    stop("no step named ", cfg$flags_view, call. = FALSE)
  for (cr in criteria)
    for (col in cr$flag_col)
      if (!grepl(paste0("\\b", col, "\\b"), flags$select))
        stop("criterion '", cr$id, "' (step ", cr$step, ") reads '", col,
             "', which ", cfg$flags_view, " does not produce. Add it to ",
             "steps/09_assemble.R.", call. = FALSE)

  invisible(TRUE)
}

# ---- the funnel, printed ----------------------------------------------------
ie_print_funnel <- function(funnel) {
  cfg <- funnel$cfg
  cat("\n", strrep("=", 78), "\n", sep = "")
  cat("  OVERALL COHORT -- IE FUNNEL\n")
  cat("  window ", cfg$outpatient_window, "d   baseline ", cfg$baseline_days,
      "d   min age ", cfg$min_age, "   ID ", cfg$id_start, " .. ", cfg$id_end,
      "\n", sep = "")
  cat("  output -> ", funnel$h$work(cfg$final_table_name), "\n", sep = "")
  cat(strrep("=", 78), "\n", sep = "")
  cat(sprintf("  %-4s %-8s %-34s %s\n", "step", "state", "criterion",
              "predicate"))
  cat(strrep("-", 78), "\n", sep = "")
  cat(sprintf("  %-4s %-8s %-34s %s\n", "0", "count",
              "base: >=1 MM dx (any position)", "-"))
  for (cr in funnel$criteria) {
    state <- if (is.na(cr$cfg_key)) "always"
             else if (ie_is_active(cr, cfg)) "ON" else "off"
    cat(sprintf("  %-4d %-8s %-34s %s\n", cr$step, state, cr$id, cr$predicate))
  }
  cat(strrep("-", 78), "\n", sep = "")
  off <- Filter(function(cr) !ie_is_active(cr, cfg), funnel$criteria)
  if (length(off))
    cat("  off by config: ",
        paste(vapply(off, function(c) c$id, character(1)), collapse = ", "),
        "\n  Their flags are still computed, as columns on ",
        funnel$h$work(cfg$flags_view), ".\n", sep = "")
  cat(strrep("=", 78), "\n\n", sep = "")
  invisible(funnel)
}
