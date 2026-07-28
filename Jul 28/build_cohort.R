#!/usr/bin/env Rscript
# =============================================================================
# build_cohort.R -- ONE entry point, either cohort, standalone
# -----------------------------------------------------------------------------
#   Rscript "Jul 28/build_cohort.R" --cohort=ndmm
#   Rscript "Jul 28/build_cohort.R" --cohort=overall
#   Rscript "Jul 28/build_cohort.R" --cohort=both          # default
#   Rscript "Jul 28/build_cohort.R" --cohort=ndmm --dry-run # print SQL, no DB
#
# `--cohort=ndmm` is a complete run. It does not build the Overall cohort and
# does not read ELIG_COH_FINAL. That is the whole point of this folder.
#
# What this script does NOT do: it does not scan raw claims. The per-criterion
# flags already exist upstream (ELIG_COH_ALLFLAGS from pipeline_steps.R step
# 23; the LOT1-anchored flags from the 06_ndmm_dashboard.R flag build). This
# script is the SELECTION layer -- it turns those flags into cohorts, an
# attrition funnel, and one shared patient-level dataset.
#
# See PLAN.md for the architecture and the two upstream changes it assumes.
# =============================================================================

# Same resolution pattern as 01_cohort.R / 06_ndmm_dashboard.R, with one
# addition: commandArgs() escapes spaces in the script path as "~+~", and this
# folder is "Jul 28". Un-escape before normalizePath() or R/ never resolves.
.script_dir <- local({
  args <- commandArgs(trailingOnly = FALSE)
  fa <- grep("^--file=", args, value = TRUE)
  if (length(fa)) return(dirname(normalizePath(
    gsub("~+~", " ", sub("^--file=", "", fa[1]), fixed = TRUE))))
  for (i in seq_len(sys.nframe())) {
    o <- tryCatch(sys.frame(i)$ofile, error = function(e) NULL)
    if (!is.null(o)) return(dirname(normalizePath(o)))
  }
  getwd()
})

source(file.path(.script_dir, "R", "cohort_specs.R"))
source(file.path(.script_dir, "R", "cohort_sql.R"))

# ---- args -------------------------------------------------------------------
parse_args <- function(argv = commandArgs(trailingOnly = TRUE)) {
  get1 <- function(flag, default) {
    hit <- grep(paste0("^", flag, "="), argv, value = TRUE)
    if (length(hit)) sub(paste0("^", flag, "="), "", hit[1]) else default
  }
  list(
    cohort  = tolower(get1("--cohort", "both")),
    dry_run = "--dry-run" %in% argv
  )
}

select_specs <- function(which_cohort, all = cohort_specs()) {
  if (identical(which_cohort, "both")) return(all)
  ids <- strsplit(which_cohort, ",", fixed = TRUE)[[1]]
  ids <- trimws(ids)
  bad <- setdiff(ids, names(all))
  if (length(bad))
    stop("unknown cohort(s): ", paste(bad, collapse = ", "),
         ". Known: ", paste(names(all), collapse = ", "), call. = FALSE)
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
    # Upstream flag tables. These are INPUTS -- this script never rebuilds them.
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

# ---- main -------------------------------------------------------------------
main <- function() {
  args  <- parse_args()
  cfg   <- load_cfg()
  specs <- lapply(select_specs(args$cohort), resolve_spec, cfg = cfg)
  plan  <- build_plan(specs, cfg)

  cat(strrep("=", 72), "\n", sep = "")
  cat("COHORT BUILD -- ", paste(names(specs), collapse = ", "), "\n", sep = "")
  for (s in plan$specs) {
    cat("\n", s$label, " (", s$id, ") -> ", s$flag_col, "\n", sep = "")
    for (g in s$resolved_gates)
      cat(sprintf("  %-2d %-5s %-9s %s\n", g$step_no, g$polarity, g$anchor,
                  g$label_resolved))
  }
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

# Connection seam. Kept separate and minimal so the selection layer above is
# testable without a warehouse; the production stack should pass its own
# connect_databricks(cfg) in via COHORT_CONNECT_FN.
connect <- function() {
  fn <- Sys.getenv("COHORT_CONNECT_FN", unset = "")
  if (nzchar(fn) && exists(fn, mode = "function")) return(get(fn, mode = "function")())
  stop("no connection configured. Set COHORT_CONNECT_FN to a zero-arg function ",
       "returning a DBI connection (the pipeline's connect_databricks(cfg) ",
       "wrapped), or run with --dry-run.", call. = FALSE)
}

if (!interactive() && sys.nframe() == 0L) main()
