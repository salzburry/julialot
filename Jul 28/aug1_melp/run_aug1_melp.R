#!/usr/bin/env Rscript
# The melphalan rule, built rather than measured.
#
#   # print the plan and what each cell costs; touches nothing, needs no connection
#   INPUT_COHORT_TABLE=ndmm_NDMM_COHORT Rscript aug1_melp/run_aug1_melp.R
#
#   # build them
#   DATABRICKS_PWD=... INPUT_COHORT_TABLE=ndmm_NDMM_COHORT COHORT_PREFIX=ndmm_ \
#     AUG1_EXECUTE=TRUE Rscript aug1_melp/run_aug1_melp.R
#
# Three complete LOT builds - the contract build, the rule as asked, and the
# rule yielding a coded transplant to the SCT rule - and the difference between
# them. That difference is the MELP-adjusted line structure: lines per patient,
# reach to 2L and 3L, LOT1 length, regimens.
#
# Execution is opt-in because a cell is a whole build. There is no cheaper way:
# moving a line boundary changes which line every later dose falls in, which
# changes induction membership, regimens, discontinuation dates and every later
# line number. None of that is recoverable from finished lines, which is why
# lot_validation's measurement counts boundaries and stops there.
#
# It writes to its own throwaway prefixes and never to the study's. Each cell
# carries CONTRACT_DEVIATIONS in its LOT_BUILD_STATUS row, so the questions, the
# dashboard and the benchmark harness all refuse it as the study's numbers.

.script_dir <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                            fixed = TRUE))) else getwd()
})
source(file.path(.script_dir, "R", "cells.R"))

LOT_ROOT <- normalizePath(file.path(.script_dir, "..", "lot"), mustWork = TRUE)
env_flag <- function(nm) identical(toupper(trimws(Sys.getenv(nm, unset = ""))), "TRUE")
out_dir  <- file.path(.script_dir, "out")

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
}

run_cell <- function(c_i, cohort, cohort_pfx) {
  args <- c(file.path(LOT_ROOT, "build.R"), cohort, c_i$prefix)
  env  <- paste0("COHORT_PREFIX=", cohort_pfx)
  st   <- trimws(Sys.getenv("COHORT_STATUS_TABLE", unset = ""))
  if (nzchar(st)) env <- c(env, paste0("COHORT_STATUS_TABLE=", st))
  # A cell builds a different algorithm and says so. The reference cell changes
  # nothing and must not claim to - if it needed the override, it would not be
  # the thing the others are measured against.
  if (!is.na(c_i$mode))
    env <- c(env, "LOT_CONTRACT_OVERRIDE=TRUE",
             paste0("APPLY_MELP_RULE=", c_i$mode))
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

  built <- vapply(cells, function(c_i) run_cell(c_i, cohort, cohort_pfx), logical(1))
  if (!built[1])
    stop("The reference cell did not build. Every other number is read against ",
         "it, so there is nothing to report.", call. = FALSE)

  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)
  abbr <- toupper(trimws(Sys.getenv("MELP_MED_ABBR", unset = "MELP")))

  rows <- list()
  for (i in seq_along(cells)) {
    if (!built[i]) next
    c_i <- cells[[i]]
    # The cell's own run id, from its own status row. Reading LOT_ATTRITION
    # without it would take whichever run's progression rows came back first.
    st <- tryCatch(db_q(con, glue(
      "SELECT RUN_ID FROM {wrk(paste0(c_i$prefix, 'LOT_BUILD_STATUS'))} ",
      "ORDER BY UPDATED_AT DESC LIMIT 1")), error = function(e) NULL)
    if (is.null(st) || !nrow(st)) {
      cat("  no status row for ", c_i$id, " - skipped\n", sep = ""); next
    }
    m <- tryCatch(db_q(con, melp_metric_sql(
      wrk(paste0(c_i$prefix, "LOT_LONG_FINAL")),
      wrk(paste0(c_i$prefix, "LOT_ATTRITION")), st$RUN_ID[1], abbr)),
      error = function(e) NULL)
    if (is.null(m)) { cat("  metrics unavailable for ", c_i$id, "\n", sep = ""); next }
    rows[[length(rows) + 1L]] <- cbind(cell = c_i$id, mode = c_i$mode, m,
                                       stringsAsFactors = FALSE)
  }
  res <- do.call(rbind, rows)
  utils::write.csv(res, file.path(out_dir, "melp_cells.csv"), row.names = FALSE)

  cmp <- melp_compare(res)
  utils::write.csv(cmp, file.path(out_dir, "melp_vs_reference.csv"), row.names = FALSE)
  cat("\nAgainst the contract build:\n\n")
  for (i in seq_len(nrow(cmp)))
    cat(sprintf("  %-13s %-19s %10s -> %-10s %+8s  %s\n",
                cmp$cell[i], cmp$metric[i], format(cmp$reference[i]),
                format(cmp$observed[i]), format(cmp$change[i]),
                if (is.na(cmp$pct_change[i])) "" else paste0(cmp$pct_change[i], "%")))

  ap <- melp_modes_apart(res)
  if (!is.null(ap)) {
    utils::write.csv(ap, file.path(out_dir, "melp_modes_apart.csv"), row.names = FALSE)
    cat("\nThe two readings against each other. This is the open question in the\n",
        "request - whether the melphalan rule or the transplant rule owns a\n",
        "coded transplant - answered in patients:\n\n", sep = "")
    for (i in seq_len(nrow(ap)))
      cat(sprintf("  %-19s as_asked %-10s yield_to_sct %-10s  %+s\n",
                  ap$metric[i], format(ap$as_asked[i]),
                  format(ap$yield_to_sct[i]), format(ap$difference[i])))
  }
  cat("\nWrote ", out_dir, ".\n", sep = "")
  cat("These are three algorithms' numbers, not three readings of one. Each ",
      "cell's\ntables carry CONTRACT_DEVIATIONS, and every reader in this ",
      "folder refuses them\nas the study's.\n", sep = "")
}

if (!interactive()) main()
