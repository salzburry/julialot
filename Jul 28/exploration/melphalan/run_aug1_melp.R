#!/usr/bin/env Rscript
# The melphalan rule, built rather than measured.
#
#   # print the plan and what each cell costs; touches nothing, needs no connection
#   INPUT_COHORT_TABLE=ndmm_NDMM_COHORT Rscript exploration/melphalan/run_aug1_melp.R
#
#   # build them
#   DATABRICKS_PWD=... INPUT_COHORT_TABLE=ndmm_NDMM_COHORT COHORT_PREFIX=ndmm_ \
#     AUG1_EXECUTE=TRUE Rscript exploration/melphalan/run_aug1_melp.R
#
# Three complete LOT builds - the contract build, and the rule under each of the
# two readings of a coded transplant - and the difference between them. That
# difference is the MELP-adjusted line structure: lines per patient, reach to 2L
# and 3L, LOT1 length, regimens.
#
# Both rule cells implement the branch table, B.2 included: the request says in
# words that both doses stay in the current line, so melp_hold carries the
# run-out to them rather than only taking the boundary away. What the two cell
# names describe is the TRANSPLANT reading - the one thing the request does not
# cover - and that is the only difference between them. See exploration/FILES.md
# under exploration/melphalan/, where B.2 is recorded as settled.
#
# Execution is opt-in because a cell is a whole build, and there is no cheaper
# way: moving a boundary changes which line every later dose falls in, and none
# of that is recoverable from finished lines.
#
# It writes to its own throwaway prefixes and never to the study's. Each cell
# carries CONTRACT_DEVIATIONS in its LOT_BUILD_STATUS row, so every reader in
# this folder refuses it as the study's numbers.
#
# Each prefix is EMPTIED before it is rebuilt. Anything an earlier run left
# under it is dropped, so no table can survive into a later cell carrying an
# older engine's answer - see melp_drop_cell in R/cells.R.

.script_dir <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                            fixed = TRUE))) else getwd()
})
source(file.path(.script_dir, "R", "cells.R"))

LOT_ROOT <- normalizePath(file.path(.script_dir, "..", "..", "lot", "engine"), mustWork = TRUE)
env_flag <- function(nm) identical(toupper(trimws(Sys.getenv(nm, unset = ""))), "TRUE")
# The same resolver read_melp_metrics.R uses, so a recovery publishes where the
# build did instead of beside it.
out_dir  <- melp_out_dir(.script_dir)

report_plan <- function(cells) {
  cat("\nThe melphalan line-advancing rule, as three builds.\n\n")
  for (c_i in cells)
    cat(sprintf("  %-14s %-14s %s\n", c_i$id,
                if (is.na(c_i$mode)) "(no rule)" else c_i$mode, c_i$prefix))
  cat("\n")
  for (c_i in cells) cat("  ", c_i$id, "\n    ", c_i$what, "\n", sep = "")
  cat("\nRead off each build:\n\n")
  for (m in names(MELP_METRICS)) cat(sprintf("  %-19s %s\n", m, MELP_METRICS[[m]]))
  cat("\n", length(cells), " cells. EACH ONE IS A COMPLETE LOT BUILD.\n", sep = "")
  cat("No direction is predicted. The rule adds boundaries at A.2 and removes ",
      "them at\nB.2 and B.3, so which way a number moves is what the run is ",
      "for.\n", sep = "")
  cat("\n", MELP_B2_READING, "\n", sep = "")
}

run_cell <- function(c_i, cohort, cohort_pfx) {
  args <- c(file.path(LOT_ROOT, "build.R"), cohort, c_i$prefix)
  env  <- paste0("COHORT_PREFIX=", cohort_pfx)
  st   <- trimws(Sys.getenv("COHORT_STATUS_TABLE", unset = ""))
  if (nzchar(st)) env <- c(env, paste0("COHORT_STATUS_TABLE=", st))
  # A cell builds a different algorithm and says so. The reference cell changes
  # nothing and must not claim to - if it needed the override, it would not be
  # the thing the others are measured against.
  #
  # Every cell names its melphalan mode, the reference included: a child
  # inherits the shell, and load_inputs.R fills an empty variable from
  # config.csv, so the contract mode has to be stated rather than left blank.
  env <- c(env, paste0("APPLY_MELP_RULE=", c_i$melp))
  if (!is.na(c_i$mode)) env <- c(env, "LOT_CONTRACT_OVERRIDE=TRUE")
  log_f <- file.path(out_dir, paste0("build_", c_i$id, ".log"))
  cat("  building ", c_i$id, " -> ", c_i$prefix, "  (log: ", log_f, ")\n", sep = "")
  rc <- system2("Rscript", args, env = env, stdout = log_f, stderr = log_f)
  if (!identical(as.integer(rc), 0L)) {
    cat("    FAILED (exit ", rc, ") - this cell contributes nothing. See the log.\n",
        sep = "")
    return(FALSE)
  }
  TRUE
}

main <- function() {
  cohort <- trimws(Sys.getenv("INPUT_COHORT_TABLE", unset = ""))
  study  <- trimws(Sys.getenv("OBJECT_PREFIX", unset = ""))
  base   <- trimws(Sys.getenv("AUG1_PREFIX_BASE", unset = "melp_"))
  cohort_pfx <- trimws(Sys.getenv("COHORT_PREFIX", unset = ""))
  cells  <- melp_cell_plan(MELP_CELLS, base)
  check_melp_plan(cells, study)
  report_plan(cells)

  if (!env_flag("AUG1_EXECUTE")) {
    cat("\nNothing was built. Set AUG1_EXECUTE=TRUE to run it.\n")
    return(invisible(NULL))
  }
  if (!nzchar(cohort))
    stop("INPUT_COHORT_TABLE is not set. Every cell has to be built over the ",
         "same cohort or the differences are the cohort's, not the rule's.",
         call. = FALSE)
  if (!nzchar(cohort_pfx))
    stop("COHORT_PREFIX is not set. A cell's own prefix is a throwaway, so the ",
         "build would find no cohort status under it and record no cohort at ",
         "all - and a cohort rebuilt mid-run would then read as the rule.",
         call. = FALSE)
  dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

  library(DBI); library(odbc); library(glue)
  e <- new.env(parent = globalenv())
  sys.source(file.path(LOT_ROOT, "R", "load_inputs.R"), envir = e)
  e$load_pipeline_inputs(LOT_ROOT, "config.csv")
  for (f in c("config_lot.R", "db_utils_lot.R")) source(file.path(LOT_ROOT, "R", f))
  set_lot_config(modifyList(cfg_defaults, list(
    work_schema = Sys.getenv("PROJECT_WORK_SCHEMA",
                    unset = Sys.getenv("DOMINO_USER_NAME", unset = "")))))

  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  # Empty each prefix before building into it, so what comes back is this run's
  # and only this run's. A rebuild alone does not give that: it replaces the
  # tables it writes and leaves anything else the previous build left, under
  # the same prefix and past every guard here. See melp_drop_cell.
  cat("\nClearing the prefixes. Whatever was built under them is gone after ",
      "this.\n", sep = "")
  for (c_i in cells) melp_drop_cell(con, c_i, study)

  built <- vapply(cells, function(c_i) run_cell(c_i, cohort, cohort_pfx), logical(1))
  # All three, not "the reference plus whatever worked". The experiment is the
  # three-way comparison: without one mode the transplant question is not
  # answered at all, and a two-cell output would still read as a finished run.
  if (!all(built))
    stop("These cells did not build: ",
         paste(vapply(cells[!built], function(c_i) c_i$id, character(1)),
               collapse = ", "),
         ". The result is the comparison between all three, so a partial run is ",
         "not a smaller answer - it is no answer. See the logs in ", out_dir, ".",
         call. = FALSE)

  # The reading half is melp_report(), in cells.R, because read_melp_metrics.R
  # runs the same half on its own when this one dies after the builds land.
  melp_report(con, cells, out_dir, lot_root = LOT_ROOT)
  cat("These are three algorithms' numbers, not three readings of one. Each ",
      "cell's\ntables carry CONTRACT_DEVIATIONS, and every reader in this ",
      "folder refuses them\nas the study's.\n", sep = "")
}

if (!interactive()) main()
