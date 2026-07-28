# =============================================================================
# cohort_run.R -- the shared build engine behind every entry point
# -----------------------------------------------------------------------------
# Not run directly. The entry points are:
#
#   overall/build.R    Overall only  -- complete run, no NDMM, no LOT build
#   ndmm/build.R       NDMM only     -- complete run, no Overall, no
#                                       ELIG_COH_FINAL dependency
#   build_both.R       --cohort=...  -- one, the other, or both + shared PLD
#
# Each cohort gets its own FOLDER holding its definition, its build script, its
# tests, and anything only it needs. This file holds the machinery they share:
# config, the schema guard, execution and reporting. Splitting it this way is
# what lets the two cohorts be genuinely independent without the SQL being
# written twice.
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
  list(cohort     = tolower(get1("--cohort", "")),
       dry_run       = "--dry-run"       %in% argv,
       index_only    = "--index-only"    %in% argv,
       rebuild_index = "--rebuild-index" %in% argv)
}

select_specs <- function(which_cohort, all = cohort_specs()) {
  if (identical(which_cohort, "both") || !nzchar(which_cohort)) return(all)
  ids <- trimws(strsplit(which_cohort, ",", fixed = TRUE)[[1]])
  bad <- setdiff(ids, names(all))
  if (length(bad))
    stop("unknown cohort(s): ", paste(bad, collapse = ", "),
         ". Known (one folder each): ",
         paste(names(all), collapse = ", "), call. = FALSE)
  all[ids]
}

# ---- config -----------------------------------------------------------------
# THE PROJECT'S OWN CONFIGURATION, not this engine's idea of it.
#
# pipeline_inputs.csv is the committed configuration: it sets OUTPATIENT_WINDOW
# to 90 and ships four exclusions FALSE (see its own DESIGN comment -- the
# parent runs to Step 6 and NDMM re-applies those criteria at the LOT1 anchor).
# An engine that reads only env vars cannot see any of that, and will happily
# build a cohort nobody uses. So load the CSV exactly the way every other entry
# point does, before reading anything.
#
# load_pipeline_inputs() only fills variables that are UNSET, so an explicit env
# var still wins -- same precedence as the rest of the stack.
.load_project_config <- function() {
  apr <- Sys.getenv("APR30_DIR", unset = "")
  if (!nzchar(apr)) {
    here <- tryCatch(dirname(normalizePath(sys.frame(1)$ofile)), error = function(e) NULL)
    roots <- c(if (!is.null(here)) dirname(dirname(here)), dirname(getwd()), getwd())
    hit <- Filter(function(d) file.exists(file.path(d, "apr_30_2026", "R", "load_inputs.R")),
                  roots)
    if (length(hit)) apr <- file.path(hit[1], "apr_30_2026")
  }
  f <- file.path(apr, "R", "load_inputs.R")
  if (!nzchar(apr) || !file.exists(f)) {
    warning("could not locate apr_30_2026/R/load_inputs.R (set APR30_DIR). ",
            "pipeline_inputs.csv was NOT loaded, so this run uses env vars and ",
            "defaults only -- it may not be the configured cohort.",
            call. = FALSE, immediate. = TRUE)
    return(invisible(FALSE))
  }
  source(f, local = TRUE)
  load_pipeline_inputs(c(apr, dirname(apr)))
}

# Env-var driven on top of that, matching config_prompts.R's own names and
# defaults exactly -- including OUTPATIENT_WINDOW = 90, which is the pipeline's
# default (config_prompts.R:99), not 60.
load_cfg <- function(load_project = TRUE) {
  if (isTRUE(load_project)) .load_project_config()
  env <- function(k, d) { v <- Sys.getenv(k, unset = ""); if (nzchar(v)) v else d }
  # as.logical("TRUE"/"FALSE") -> TRUE/FALSE; anything else -> NA, which
  # isTRUE() then treats as OFF. Same as config_prompts.R.
  flag <- function(k) as.logical(env(k, "TRUE"))
  work <- env("PROJECT_WORK_SCHEMA", env("WORK_SCHEMA", ""))
  qual <- function(t) if (nzchar(work)) paste0(work, ".", t) else t
  cfg <- list(
    catalog        = env("DATABRICKS_CATALOG", ""),
    dsn            = env("DATABRICKS_DSN", ""),
    pwd            = Sys.getenv("DATABRICKS_PWD", unset = ""),
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
    outpatient_window  = as.integer(env("OUTPATIENT_WINDOW", "90")),
    lot1_from          = env("NDMM_LOT1_FROM", "2017-01-01"),
    # The IE toggles. Names match criteria_attrition.R's cfg_key values, so a
    # gate's cfg_key indexes straight into this list.
    apply_age_incl          = flag("APPLY_AGE_INCL"),
    apply_ce_b_incl         = flag("APPLY_CE_B_INCL"),
    apply_ce_f_incl         = flag("APPLY_CE_F_INCL"),
    apply_no_bl_agents_incl = flag("APPLY_NO_BL_AGENTS_INCL"),
    apply_fu_agents_incl    = flag("APPLY_FU_AGENTS_INCL"),
    apply_baseline_mm_excl  = flag("APPLY_BASELINE_MM_EXCL"),
    apply_other_malig_excl  = flag("APPLY_OTHER_MALIG_EXCL"),
    apply_pregnancy_excl    = flag("APPLY_PREGNANCY_EXCL"),
    apply_clintrial_excl    = flag("APPLY_CLINTRIAL_EXCL")
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
# `plan_sql` is the SQL of the steps about to run. A source is only checked if
# some step actually references it -- otherwise --index-only demands
# LOT1_FLAGS_ALL, the table the stage AFTER it is supposed to create, and a
# clean bootstrap can never start.
# Which sources this run must check: those with required columns AND actually
# referenced by a step about to run. Pure, so the --index-only case is testable
# without a warehouse -- the bug it fixes was invisible to a text-only suite
# precisely because it lived past the connection.
sources_to_check <- function(specs, cfg, plan_sql = NULL) {
  need <- required_source_cols(specs)
  keep <- names(need)[vapply(names(need), function(src)
    length(need[[src]]) > 0L &&
      (is.null(plan_sql) || any(grepl(cfg[[src]], plan_sql, fixed = TRUE))),
    logical(1))]
  need[keep]
}

assert_source_cols <- function(con, specs, cfg, plan_sql = NULL) {
  all_need <- required_source_cols(specs)
  need     <- sources_to_check(specs, cfg, plan_sql)
  for (src in setdiff(names(all_need), names(need)))
    if (length(all_need[[src]]))
      cat("[preflight] skipping ", cfg[[src]],
          " -- no step in this run reads it\n", sep = "")
  for (src in names(need)) {
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
  cat("  If that makes them select DIFFERENT index dates for the same patient,\n",
      "  this run will be REJECTED after the union is built -- LOT_LONG has no\n",
      "  INDEX_DATE and cannot represent two histories per patient. Build them in\n",
      "  separate runs, or align the gates. See REVIEW_FINDINGS.md finding 3.\n",
      sep = "")
  invisible(NULL)
}

.table_exists <- function(con, fq) isTRUE(tryCatch({
  DBI::dbGetQuery(con, paste0("SELECT 1 FROM ", fq, " LIMIT 1")); TRUE
}, error = function(e) FALSE))

# ---- connection seam --------------------------------------------------------
# Kept minimal and separate so the whole selection layer is testable without a
# warehouse; the production stack passes its own connect_databricks(cfg) in.
# Connects the same way 02_lot1.R:63 and 05_regimen_dashboard.R:1622 do -- DSN
# from the project config, password from the environment. So `Rscript
# ndmm/build.R` works with DATABRICKS_PWD set and nothing else, which is what
# the rest of the stack already requires.
#
# COHORT_CONNECT_FN overrides it with the name of a zero-arg function, for a
# host that connects differently. The previous default was to refuse and point
# at COHORT_CONNECT_FN=my_connect -- a command that could not work, because
# nothing defines my_connect.
.assert_connect_config <- function() {
  fn <- Sys.getenv("COHORT_CONNECT_FN", unset = "")
  if (nzchar(fn) && !exists(fn, mode = "function"))
    stop("COHORT_CONNECT_FN is set to '", fn, "' but no such function is ",
         "defined in this session. Source the file that defines it first, or ",
         "unset COHORT_CONNECT_FN to connect via DATABRICKS_DSN + ",
         "DATABRICKS_PWD like the rest of the pipeline.", call. = FALSE)
  invisible(TRUE)
}

connect <- function(cfg) {
  .assert_connect_config()
  fn <- Sys.getenv("COHORT_CONNECT_FN", unset = "")
  if (nzchar(fn)) return(get(fn, mode = "function")())
  if (!requireNamespace("odbc", quietly = TRUE))
    stop("package 'odbc' is required for the default DSN connection. Use ",
         "--dry-run, or set COHORT_CONNECT_FN.", call. = FALSE)
  if (!nzchar(cfg$dsn))
    stop("no ODBC DSN configured. Set DATABRICKS_DSN (pipeline_inputs.csv ",
         "normally supplies it).", call. = FALSE)
  if (!nzchar(cfg$pwd))
    stop("DATABRICKS_PWD is not set. It stays in the environment / secret ",
         "store by design -- pipeline_inputs.csv does not carry it.",
         call. = FALSE)
  DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 120)
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
  cat("  outpatient window ", cfg$outpatient_window, "d   min age ", cfg$min_age,
      "   1L cutoff ", cfg$lot1_from, "\n", sep = "")
  for (s in plan$specs) {
    cat("\n", s$label, " (", s$id, ")  ->  ", s$flag_col,
        "   [", s$source_file %||% "?", "]\n", sep = "")
    for (g in s$resolved_gates)
      if (isTRUE(g$active))
        cat(sprintf("  %-2d %-5s %-9s %s\n", g$step_no, g$polarity, g$anchor,
                    g$label_resolved))
      else
        cat(sprintf("  -- %-5s %-9s %s   [OFF: %s=FALSE]\n", g$polarity, g$anchor,
                    g$label_resolved, toupper(g$cfg_key)))
    n_off <- length(s$resolved_gates) - length(active_gates(s))
    if (n_off > 0L)
      cat("  (", n_off, " criteria declared but NOT applied -- they remain 0/1 ",
          "columns on the PLD)\n", sep = "")
  }
  cat("\n", strrep("-", 72), "\n", sep = "")
  report_index_gate_drift(plan$specs)

  # --index-only: stop after the union view. Needed to break the bootstrap
  # ordering -- the LOT build consumes coh_index_union, but the membership
  # views consume the LOT1 flags that only exist once the LOT build and the
  # flag stage have run. So: index-only -> LOT build -> flag stage -> full run.
  if (isTRUE(args$index_only)) {
    keep <- seq_len(which(vapply(plan$steps, `[[`, character(1), "name") == "index_union"))
    plan$steps <- plan$steps[keep]
    plan$attrition <- list()
    cat("--index-only: stopping after ", sql_table(cfg, "index_union"),
        "\n  next: LOT build with INPUT_COHORT_TABLE=",
        sql_table_short(cfg, "index_union"),
        "\n  then: build_lot1_flags.R",
        "\n  then: this script again, without --index-only\n", sep = "")
  }
  cat(strrep("=", 72), "\n", sep = "")

  if (args$dry_run) {
    for (st in plan$steps) {
      cat("\n-- [", st$name, "] ", st$description, "\n", st$sql, ";\n", sep = "")
      if (!is.null(st$check))
        cat("\n-- [check: ", st$name, "] run must ABORT unless ",
            st$check$column, " = 0\n", st$check$sql, ";\n", sep = "")
    }
    for (id in names(plan$attrition))
      cat("\n-- [attrition:", id, "]\n", plan$attrition[[id]], ";\n", sep = "")
    return(invisible(plan))
  }

  # Validate the connection CONFIG before the package requirement: a bad
  # COHORT_CONNECT_FN is the user's typo and should say so, rather than be
  # masked by a generic "DBI is required".
  .assert_connect_config()
  if (!requireNamespace("DBI", quietly = TRUE))
    stop("DBI is required to execute. Use --dry-run to emit SQL only.",
         call. = FALSE)
  con <- connect(cfg)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  # REUSE, don't silently rebuild. The index tables are what the LOT build and
  # the flag stage consumed; recomputing them here would quietly re-derive the
  # cohort from whatever ELIG_COH_ALLFLAGS looks like NOW and pair it with LOT
  # output built from something else. Same reason a build system does not
  # re-run a step whose output already exists.
  idx_steps <- grepl("_index_sel$|^index_union$",
                     vapply(plan$steps, `[[`, character(1), "name"))
  if (!isTRUE(args$rebuild_index) && !isTRUE(args$index_only)) {
    have <- vapply(plan$steps[idx_steps], function(st)
      .table_exists(con, sub(".*CREATE OR REPLACE TABLE ([^ \n]+).*", "\\1",
                             sub("\n.*", "", st$sql))), logical(1))
    if (length(have) && all(have)) {
      cat("[reuse] index tables already exist -- reusing them so this run ",
          "selects from the SAME rows the LOT build consumed.\n",
          "        Pass --rebuild-index to recompute from ", cfg$index_flags,
          ".\n", sep = "")
      plan$steps <- plan$steps[!idx_steps]
    } else if (any(have)) {
      stop("the index tables are only PARTIALLY present, so this run would mix ",
           "vintages. Re-run with --index-only --rebuild-index to rebuild them ",
           "all, then redo the LOT build and the flag stage.", call. = FALSE)
    }
  }

  assert_source_cols(con, specs, cfg,
                     plan_sql = vapply(plan$steps, `[[`, character(1), "sql"))

  for (st in plan$steps) {
    cat("[step] ", st$name, " -- ", st$description, "\n", sep = "")
    DBI::dbExecute(con, st$sql)
    # A step's check runs IMMEDIATELY after it, so a violated invariant stops
    # the run before anything downstream is built on it.
    if (!is.null(st$check)) {
      v <- DBI::dbGetQuery(con, st$check$sql)[[st$check$column]][1]
      if (!isTRUE(as.numeric(v) == 0))
        stop("[", st$name, "] check failed: ", format(v, big.mark = ","), " ",
             st$check$message, call. = FALSE)
      cat("[check] ", st$name, " ok\n", sep = "")
    }
  }

  for (id in names(plan$attrition)) {
    cat("\n---- attrition: ", id, " ----\n", sep = "")
    print(DBI::dbGetQuery(con, plan$attrition[[id]]))
  }

  invisible(plan)
}
