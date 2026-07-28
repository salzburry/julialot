# =============================================================================
# cohort_run.R -- the shared build engine behind every entry point
# -----------------------------------------------------------------------------
# Not run directly. The entry points are:
#
#   build_overall.R    Overall only  -- complete run, no NDMM, no LOT build
#   build_ndmm.R       NDMM only     -- complete run, no Overall, no
#                                       ELIG_COH_FINAL dependency
#   build_cohort.R     --cohort=...  -- one, the other, or both + shared PLD
#
# Each cohort's DEFINITION lives in its own file under cohorts/. This file holds
# the machinery they share: config, the schema guard, execution and reporting.
# Splitting it this way is what lets the two cohorts be genuinely independent
# without the SQL being written twice.
#
# What this engine does NOT do: scan raw claims. The per-criterion flags already
# exist upstream (ELIG_COH_ALLFLAGS from pipeline_steps.R step 23; the
# LOT1-anchored flags from the 06_ndmm_dashboard.R flag build). This is the
# SELECTION layer -- flags in, cohorts + attrition + PLD out.
#
# See PLAN.md for the architecture and the two upstream changes it assumes.
# =============================================================================

# ---- args -------------------------------------------------------------------
parse_args <- function(argv = commandArgs(trailingOnly = TRUE)) {
  get1 <- function(flag, default) {
    hit <- grep(paste0("^", flag, "="), argv, value = TRUE)
    if (length(hit)) sub(paste0("^", flag, "="), "", hit[1]) else default
  }
  list(cohort  = tolower(get1("--cohort", "")),
       dry_run = "--dry-run" %in% argv)
}

select_specs <- function(which_cohort, all = cohort_specs()) {
  if (identical(which_cohort, "both") || !nzchar(which_cohort)) return(all)
  ids <- trimws(strsplit(which_cohort, ",", fixed = TRUE)[[1]])
  bad <- setdiff(ids, names(all))
  if (length(bad))
    stop("unknown cohort(s): ", paste(bad, collapse = ", "),
         ". Known (one file each in cohorts/): ",
         paste(names(all), collapse = ", "), call. = FALSE)
  all[ids]
}

# ---- config -----------------------------------------------------------------
# Env-var driven, matching the existing pipeline's convention (see
# apr_30_2026/R/config_prompts.R and pipeline_inputs.csv). Anything the gates
# parameterise (min_age, outpatient_window, lot1_from) is read here so a single
# input file still drives the whole run.
load_cfg <- function() {
  env <- function(k, d) { v <- Sys.getenv(k, unset = ""); if (nzchar(v)) v else d }
  work <- env("PROJECT_WORK_SCHEMA", env("WORK_SCHEMA", ""))
  qual <- function(t) if (nzchar(work)) paste0(work, ".", t) else t
  cfg <- list(
    work_schema    = work,
    view_prefix    = env("COHORT_VIEW_PREFIX", "coh_"),
    # Upstream flag tables. These are INPUTS -- this engine never rebuilds them.
    index_flags    = qual(env("INDEX_FLAGS_TABLE", "ELIG_COH_ALLFLAGS")),
    lot1_flags     = qual(env("LOT1_FLAGS_TABLE",  "LOT1_FLAGS_ALL")),
    lot1_starts    = qual(env("LOT1_STARTS_TABLE", "LOT1_STARTS")),
    # Output
    persist_schema = env("PERSIST_SCHEMA", work),
    pld_table      = env("PLD_TABLE", "COHORT_PLD"),
    # Gate parameters (registry defaults apply when unset)
    min_age            = as.integer(env("MIN_AGE", "18")),
    outpatient_window  = as.integer(env("OUTPATIENT_WINDOW", "60")),
    lot1_from          = env("NDMM_LOT1_FROM", "2017-01-01")
  )
  if (!cfg$outpatient_window %in% c(30L, 60L, 90L))
    stop("OUTPATIENT_WINDOW must be 30, 60 or 90 (only those columns are ",
         "materialized upstream); got ", cfg$outpatient_window, call. = FALSE)
  cfg
}

# ---- schema guard -----------------------------------------------------------
# Assert the upstream flag tables actually carry every column the requested
# gates read, BEFORE running anything. A renamed or dropped upstream column
# would otherwise not error -- it would silently produce a different cohort.
assert_source_cols <- function(con, specs, cfg) {
  need <- required_source_cols(specs)
  for (src in names(need)) {
    if (!length(need[[src]])) next
    tbl  <- cfg[[src]]
    have <- toupper(names(DBI::dbGetQuery(con,
              paste0("SELECT * FROM ", tbl, " WHERE 1 = 0"))))
    miss <- setdiff(toupper(need[[src]]), have)
    if (length(miss))
      stop("table ", tbl, " is missing column(s) required by the requested ",
           "cohort gates: ", paste(miss, collapse = ", "),
           ". Refusing to build a cohort from an incomplete flag table.",
           call. = FALSE)
  }
  invisible(TRUE)
}

# ---- drift report -----------------------------------------------------------
# One file per cohort means the index-gate lists CAN diverge. When they are
# meant to agree, they must be kept in step by REVIEW -- so say so at run time
# instead of letting an unintended edit pass unnoticed.
report_index_gate_drift <- function(specs) {
  if (length(specs) < 2L) return(invisible(NULL))
  reg <- gate_registry()
  n_idx <- length(Filter(function(g) identical(reg[[g]]$anchor, "index"),
                         specs[[1]]$gates))
  d <- index_gate_diff(specs[[1]], specs[[2]], reg)
  if (isTRUE(d$identical)) {
    cat("index gates: ", specs[[1]]$id, " and ", specs[[2]]$id,
        " agree (", n_idx, " gates)\n", sep = "")
    return(invisible(NULL))
  }
  cat("NOTE: ", specs[[1]]$id, " and ", specs[[2]]$id,
      " have DIFFERENT index-anchored gates.\n", sep = "")
  if (length(d$only_in_a))
    cat("  only in ", specs[[1]]$id, ": ", paste(d$only_in_a, collapse = ", "), "\n", sep = "")
  if (length(d$only_in_b))
    cat("  only in ", specs[[2]]$id, ": ", paste(d$only_in_b, collapse = ", "), "\n", sep = "")
  if (isTRUE(d$reordered))
    cat("  same set, different funnel order\n")
  cat("  Intended? If so the cohorts select different index dates and the LOT\n",
      "  build fans out over their union (PLAN.md 3). If not, fix the cohorts/ file.\n",
      sep = "")
  invisible(NULL)
}

# ---- connection seam --------------------------------------------------------
# Kept minimal and separate so the whole selection layer is testable without a
# warehouse; the production stack passes its own connect_databricks(cfg) in.
connect <- function() {
  fn <- Sys.getenv("COHORT_CONNECT_FN", unset = "")
  if (nzchar(fn) && exists(fn, mode = "function")) return(get(fn, mode = "function")())
  stop("no connection configured. Set COHORT_CONNECT_FN to a zero-arg function ",
       "returning a DBI connection (the pipeline's connect_databricks(cfg) ",
       "wrapped), or run with --dry-run.", call. = FALSE)
}

# ---- the run ----------------------------------------------------------------
# `cohort` fixes which cohort(s) to build. The dedicated entry points pass their
# own id; build_cohort.R passes NULL and reads --cohort.
run_build <- function(cohort = NULL, argv = commandArgs(trailingOnly = TRUE)) {
  args  <- parse_args(argv)
  which <- if (!is.null(cohort)) cohort else args$cohort
  cfg   <- load_cfg()
  specs <- lapply(select_specs(which), resolve_spec, cfg = cfg)
  plan  <- build_plan(specs, cfg)

  cat(strrep("=", 72), "\n", sep = "")
  cat("COHORT BUILD -- ", paste(names(specs), collapse = ", "), "\n", sep = "")
  for (s in plan$specs) {
    cat("\n", s$label, " (", s$id, ")  ->  ", s$flag_col,
        "   [cohorts/", s$source_file %||% "?", "]\n", sep = "")
    for (g in s$resolved_gates)
      cat(sprintf("  %-2d %-5s %-9s %s\n", g$step_no, g$polarity, g$anchor,
                  g$label_resolved))
  }
  cat("\n", strrep("-", 72), "\n", sep = "")
  report_index_gate_drift(plan$specs)
  cat(strrep("=", 72), "\n", sep = "")

  if (args$dry_run) {
    for (st in plan$steps)
      cat("\n-- [", st$name, "] ", st$description, "\n", st$sql, ";\n", sep = "")
    for (id in names(plan$attrition))
      cat("\n-- [attrition:", id, "]\n", plan$attrition[[id]], ";\n", sep = "")
    return(invisible(plan))
  }

  if (!requireNamespace("DBI", quietly = TRUE))
    stop("DBI is required to execute. Use --dry-run to emit SQL only.",
         call. = FALSE)
  con <- connect()
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  assert_source_cols(con, specs, cfg)

  for (st in plan$steps) {
    cat("[step] ", st$name, " -- ", st$description, "\n", sep = "")
    DBI::dbExecute(con, st$sql)
  }

  for (id in names(plan$attrition)) {
    cat("\n---- attrition: ", id, " ----\n", sep = "")
    print(DBI::dbGetQuery(con, plan$attrition[[id]]))
  }

  invisible(plan)
}
