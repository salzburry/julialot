#!/usr/bin/env Rscript
# The melphalan rule, built rather than measured.
#
#   # print the plan and what each cell costs; touches nothing, needs no connection
#   INPUT_COHORT_TABLE=ndmm_NDMM_COHORT Rscript lot/melphalan/run_aug1_melp.R
#
#   # build them
#   DATABRICKS_PWD=... INPUT_COHORT_TABLE=ndmm_NDMM_COHORT COHORT_PREFIX=ndmm_ \
#     AUG1_EXECUTE=TRUE Rscript lot/melphalan/run_aug1_melp.R
#
# Three complete LOT builds - the contract build, and the rule under each of the
# two readings of a coded transplant - and the difference between them. That
# difference is the MELP-adjusted line structure: lines per patient, reach to 2L
# and 3L, LOT1 length, regimens.
#
# Neither rule cell is the request implemented to the letter. On B.2 both take
# the narrow reading, described in lot/melphalan/README.md and left open as
# question 6 in lot/questions/melphalan_lot_rule.md.
#
# Execution is opt-in because a cell is a whole build, and there is no cheaper
# way: moving a boundary changes which line every later dose falls in, and none
# of that is recoverable from finished lines.
#
# It writes to its own throwaway prefixes and never to the study's. Each cell
# carries CONTRACT_DEVIATIONS in its LOT_BUILD_STATUS row, so every reader in
# this folder refuses it as the study's numbers.

.script_dir <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                            fixed = TRUE))) else getwd()
})
source(file.path(.script_dir, "R", "cells.R"))

LOT_ROOT <- normalizePath(file.path(.script_dir, "..", "engine"), mustWork = TRUE)
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
  cat("\n", MELP_B2_READING, "\n", sep = "")
}

# The cell's own run id, from its own status row. Reading LOT_ATTRITION or
# LOT_RUN_METADATA without it would take whichever run's rows came back first.
cell_run_id <- function(con, c_i) {
  st <- tryCatch(db_q(con, glue(
    "SELECT RUN_ID FROM {wrk(paste0(c_i$prefix, 'LOT_BUILD_STATUS'))} ",
    "ORDER BY UPDATED_AT DESC LIMIT 1")), error = function(e) NULL)
  if (is.null(st) || !nrow(st))
    stop("No LOT_BUILD_STATUS row under ", c_i$prefix, ", so there is no run ",
         "to read ", c_i$id, "'s numbers from.", call. = FALSE)
  st$RUN_ID[1]
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

  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)
  abbr <- toupper(trimws(Sys.getenv("MELP_MED_ABBR", unset = "MELP")))

  # What each cell was built over, before anything is read off it.
  inputs <- list()
  for (c_i in cells) {
    # The error is kept, not swallowed. A query that failed and a run with no
    # metadata row are different problems, and reporting the first as the second
    # sends the reader to look for a missing row that is there.
    r <- tryCatch(db_q(con, melp_inputs_sql(
      wrk(paste0(c_i$prefix, "LOT_RUN_METADATA")),
      wrk(paste0(c_i$prefix, "LOT_CODELIST_METADATA")),
      wrk(paste0(c_i$prefix, "LOT_BUILD_STATUS")),
      cell_run_id(con, c_i))), error = function(e) e)
    if (inherits(r, "error"))
      stop("Could not read what ", c_i$id, " was built over: ",
           conditionMessage(r), call. = FALSE)
    if (!nrow(r))
      stop("No LOT_RUN_METADATA row for ", c_i$id, ". Without it there is no ",
           "record of which cohort attempt or code lists it was built over, and ",
           "the comparison cannot be shown to be about the rule.", call. = FALSE)
    inputs[[c_i$id]] <- r
  }
  melp_check_inputs(inputs)
  melp_check_deviations(inputs, cells)
  cat("\nAll three cells were built over cohort attempt ",
      inputs[[1]]$COHORT_RUN_ID[1], " / ", inputs[[1]]$COHORT_STAMP[1],
      ", the same code and the same code lists.\n", sep = "")

  rows <- list()
  for (i in seq_along(cells)) {
    c_i <- cells[[i]]
    # The MAP stack and the build's own windows, so the B.2 count is that
    # population rather than every line melphalan happens to appear in.
    m <- melp_metrics(con,
      wrk(paste0(c_i$prefix, "LOT_LONG_FINAL")),
      wrk(paste0(c_i$prefix, "LOT_ATTRITION")), cell_run_id(con, c_i), abbr,
      map_tbl      = wrk(paste0(c_i$prefix, "MAP_STACKED")),
      expo_days    = cfg$melp_exposure_days,
      restart_days = cfg$melp_restart_days,
      advance_days = cfg$melp_advance_days,
      ind1         = cfg$induction_window_days,
      indn         = cfg$lot_n_induction_window_days,
      cart         = cfg$cart_consolidation_days)
    if (is.null(m))
      stop("Metrics could not be read for ", c_i$id, ". The result is the ",
           "comparison between all three, so this is a stop rather than a row ",
           "left out of it.", call. = FALSE)
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
    cat("\nThe two readings against each other, in aggregate. This is the\n",
        "downstream consequence of the two interpretations, not a count of the\n",
        "events where both rules fired:\n\n", sep = "")
    for (i in seq_len(nrow(ap)))
      cat(sprintf("  %-19s as_asked %-10s yield_to_sct %-10s  %+s\n",
                  ap$metric[i], format(ap$as_asked[i]),
                  format(ap$yield_to_sct[i]), format(ap$difference[i])))
  }
  # And the same question patient by patient, which is the number the request
  # actually turns on: how many patients the transplant reading moves.
  #
  # The prefixes come from the plan, not from the default spelled out again.
  # AUG1_PREFIX_BASE moves every cell, so a prefix written out here reads
  # nothing under a custom base - or, worse, reads a previous experiment's
  # tables that happen to still be there and reports them as this run's.
  pfx_of <- function(id) {
    hit <- Filter(function(c_i) identical(c_i$id, id), cells)
    if (!length(hit)) stop("no ", id, " cell in the plan", call. = FALSE)
    hit[[1]]$prefix
  }
  # And it is required, not best-effort. This is the comparison the two modes
  # exist for, so a run that skipped it is not a finished experiment.
  pd <- tryCatch(db_q(con, melp_modes_patients_sql(
    wrk(paste0(pfx_of("as_asked"), "LOT_LONG_FINAL")),
    wrk(paste0(pfx_of("yield_to_sct"), "LOT_LONG_FINAL")))), error = function(e) e)
  if (inherits(pd, "error") || !nrow(pd))
    stop("The two readings could not be compared patient by patient: ",
         if (inherits(pd, "error")) conditionMessage(pd) else "no rows",
         ". That comparison is what the two modes are for, so this is a stop ",
         "rather than an output left out.", call. = FALSE)
  {
    utils::write.csv(pd, file.path(out_dir, "melp_modes_patients.csv"),
                     row.names = FALSE)
    cat("\nAnd patient by patient. A patient counts as differing when their line\n",
        "count, or any line's start, end or end reason, is not the same under\n",
        "both readings:\n\n", sep = "")
    cat("  ", pd$N_PATIENTS[1], " patients in either build\n", sep = "")
    cat("  ", pd$N_DIFFERENT[1], " whose lines differ between the two readings\n", sep = "")
    cat("  ", pd$N_LINE_COUNT_DIFFERENT[1], " of those have a different NUMBER of lines\n", sep = "")
    cat("  ", pd$N_SAME_COUNT_DIFFERENT_LINES[1],
        " have the same number of lines in different places -\n",
        "      which is why the aggregate above understates it\n", sep = "")
    cat("  ", pd$N_ONLY_ONE_SIDE[1], " appear in one build and not the other\n", sep = "")
  }
  cat("\nWrote ", out_dir, ".\n", sep = "")
  cat("These are three algorithms' numbers, not three readings of one. Each ",
      "cell's\ntables carry CONTRACT_DEVIATIONS, and every reader in this ",
      "folder refuses them\nas the study's.\n", sep = "")
}

if (!interactive()) main()
