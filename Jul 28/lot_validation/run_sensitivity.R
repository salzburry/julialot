#!/usr/bin/env Rscript
# Sweep the LOT thresholds and record what moves.
#
#   # print the plan and its cost - the default, and it touches nothing
#   INPUT_COHORT_TABLE=ndmm_NDMM_COHORT Rscript lot_validation/run_sensitivity.R
#
#   # actually run it
#   DATABRICKS_PWD=... INPUT_COHORT_TABLE=ndmm_NDMM_COHORT COHORT_PREFIX=ndmm_ \
#     SENS_EXECUTE=TRUE Rscript lot_validation/run_sensitivity.R
#
# EXECUTION IS OPT-IN because one cell is one complete LOT build. The default
# prints the grid, the directions and the cell count, and needs no connection.
#
# Every parameter here is pinned in the LOT contract and build_lot refuses a
# value that is not the contract's - a different threshold is a different
# algorithm. That is what a cell is, so each is launched with
# LOT_CONTRACT_OVERRIDE=TRUE. The build records its deviations in that cell's
# LOT_BUILD_STATUS, and everything that resolves run ownership refuses a run
# carrying them, so a cell cannot be reported as the study.
#
# Each cell runs as its own Rscript under its own throwaway prefix. A separate
# process, because the build pins a config and a run id globally and a second
# build in one session inherits the first's.
#
# A sweep leaves a full set of LOT tables per cell. SENS_DROP_AFTER=TRUE
# removes them once the metrics are read; off by default, because dropping
# tables is not something a measurement script should do quietly.

.script_dir <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(a)) dirname(normalizePath(sub("^--file=", "", a[1]))) else getwd()
})
source(file.path(.script_dir, "R", "sensitivity.R"))
source(file.path(.script_dir, "R", "run_binding.R"))

LOT_ROOT <- normalizePath(file.path(.script_dir, "..", "lot"), mustWork = TRUE)

env_flag <- function(nm) identical(toupper(trimws(Sys.getenv(nm, unset = ""))), "TRUE")

shipped <- local({
  e <- new.env(parent = globalenv())
  sys.source(file.path(LOT_ROOT, "R", "load_inputs.R"), envir = e)
  e$load_pipeline_inputs(LOT_ROOT, "config.csv")
  sys.source(file.path(LOT_ROOT, "R", "config_lot.R"), envir = e)
  get("cfg_defaults", envir = e)
})

print_plan <- function(cells) {
  cat("\nSensitivity grid - one at a time from the shipped configuration.\n\n")
  cat(sprintf("  %-34s %-9s %s\n", "cell", "value", "shipped"))
  for (c_i in cells) {
    if (is.na(c_i$param)) {
      cat(sprintf("  %-34s %-9s %s\n", c_i$id, "-", "the reference build"))
      next
    }
    cat(sprintf("  %-34s %-9s %s\n", c_i$id, c_i$value,
                shipped[[c_i$axis$cfg]]))
  }
  cat("\nExpected direction as each parameter INCREASES, stated before the run:\n\n")
  for (a in SENS_AXES) {
    cat("  ", a$param, "  (", a$confidence, ")\n", sep = "")
    for (m in names(a$expect))
      cat(sprintf("      %-20s %s\n", m, a$expect[[m]]))
    cat("      why: ", a$why, "\n\n", sep = "")
  }
  cat("Not swept, and why:\n",
      "  maintenance-as-LOT   not a setting. Maintenance is a flag and there is\n",
      "                       no maintenance period (lot/R/steps/05_sct.R:13), so\n",
      "                       there is nothing to vary. It is in the vignettes.\n",
      "  CE requirements      the cohort build's axis. nndm already reports it\n",
      "                       from one run (NDMM_FU_CE_COUNTS); sweeping it here\n",
      "                       would rebuild the cohort per cell.\n\n", sep = "")
  cat(length(cells), " cells. EACH ONE IS A COMPLETE LOT BUILD.\n", sep = "")
}

run_cell <- function(c_i, cohort, cohort_pfx) {
  args <- c(file.path(LOT_ROOT, "build.R"), cohort, c_i$prefix)
  # The cohort build's prefix, not this cell's. COHORT_PREFIX defaults to the
  # run's own prefix, which for a cell is a throwaway - so the build would look
  # for sens_max_lot_8_NDMM_BUILD_STATUS, find nothing, and record no cohort at
  # all. A cohort refreshed mid-sweep would then read as the parameter.
  env <- paste0("COHORT_PREFIX=", cohort_pfx)
  st  <- trimws(Sys.getenv("COHORT_STATUS_TABLE", unset = ""))
  if (nzchar(st)) env <- c(env, paste0("COHORT_STATUS_TABLE=", st))
  # A cell is an alternative algorithm, so it says so. The reference cell
  # changes nothing and does not need it.
  if (!is.na(c_i$param))
    env <- c(env, "LOT_CONTRACT_OVERRIDE=TRUE",
             paste0(c_i$param, "=", c_i$value))
  log_f <- file.path(out_dir, paste0("build_", c_i$id, ".log"))
  cat("  building ", c_i$id, " -> ", c_i$prefix, "  (log: ", log_f, ")\n", sep = "")
  st <- system2("Rscript", args, env = env, stdout = log_f, stderr = log_f)
  if (!identical(as.integer(st), 0L)) {
    cat("    FAILED (exit ", st, ") - this cell contributes nothing. ",
        "See the log.\n", sep = "")
    return(FALSE)
  }
  TRUE
}

main <- function() {
  cohort <- trimws(Sys.getenv("INPUT_COHORT_TABLE", unset = ""))
  study  <- trimws(Sys.getenv("OBJECT_PREFIX", unset = ""))
  base   <- trimws(Sys.getenv("SENS_PREFIX_BASE", unset = "sens_"))
  cap    <- suppressWarnings(as.integer(Sys.getenv("SENS_MAX_CELLS", unset = "24")))
  cohort_pfx <- trimws(Sys.getenv("COHORT_PREFIX", unset = ""))
  cells  <- sens_plan(SENS_AXES, base)

  check_sens_plan(cells, study, if (is.na(cap)) 24L else cap)
  print_plan(cells)

  if (!env_flag("SENS_EXECUTE")) {
    cat("\nNothing was run. Set SENS_EXECUTE=TRUE to build them.\n")
    return(invisible(NULL))
  }
  if (!nzchar(cohort))
    stop("INPUT_COHORT_TABLE is required to execute: every cell builds LOT over ",
         "the same cohort, and only the thresholds differ.", call. = FALSE)
  # "The same cohort" has to be provable, not just intended.
  if (!nzchar(cohort_pfx))
    stop("COHORT_PREFIX is required to execute. Each cell writes to its own ",
         "throwaway prefix, and the build looks for the cohort's status table ",
         "under the run's prefix unless told otherwise - so without this every ",
         "cell would record no cohort run id, and nothing afterwards could ",
         "show that all ", length(cells), " read one cohort. Set it to the ",
         "prefix of the build that wrote ", cohort, ".", call. = FALSE)
  stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")

  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  rows <- list(); attempts <- list()
  for (c_i in cells) {
    if (!run_cell(c_i, cohort, cohort_pfx)) next
    # The cell's own run id: LOT_ATTRITION is keyed by it. A cell that did not
    # finish is skipped, not refused - it costs that cell and the sweep goes on.
    st <- lot_run_row(con, c_i$prefix)
    if (is.null(st) || !isTRUE(st$complete)) {
      cat("    cell ", c_i$id, " did not finish - skipped.\n", sep = "")
      next
    }
    m <- tryCatch(db_q(con, sens_metric_sql(
      wrk(paste0(c_i$prefix, "LOT_LONG_FINAL")),
      wrk(paste0(c_i$prefix, "LOT_ATTRITION")),
      st$run)), error = function(e) NULL)
    if (is.null(m)) { cat("    metrics unavailable for ", c_i$id, "\n", sep = ""); next }
    # Which cohort attempt this cell read - a sweep is thirteen sequential
    # builds, and a cohort can be rebuilt while it runs.
    md <- lot_run_meta(con, c_i$prefix)
    attempts[[c_i$id]] <- if (is.null(md) || is.na(md$cohort_run) ||
                              !nzchar(trimws(md$cohort_run))) NA_character_ else
      paste0(md$cohort_run, " @ ", md$cohort_at)
    rows[[length(rows) + 1L]] <- cbind(
      data.frame(cell = c_i$id, param = if (is.na(c_i$param)) "" else c_i$param,
                 value = if (is.na(c_i$value)) NA_integer_ else c_i$value,
                 shipped_value = if (is.na(c_i$param)) NA_integer_
                                 else as.integer(shipped[[c_i$axis$cfg]]),
                 prefix = c_i$prefix, stringsAsFactors = FALSE), m)
    if (env_flag("SENS_DROP_AFTER")) {
      for (t in c("LOT_LONG_FINAL", "LOT_LONG", "LOT_LONG_ALLFLAGS", "MAP_STACKED",
                  "LOT_ATTRITION", "LOT_RUN_METADATA", "LOT_BUILD_STATUS"))
        try(db_exec(con, paste0("DROP TABLE IF EXISTS ",
                                wrk(paste0(c_i$prefix, t)))), silent = TRUE)
      cat("    dropped ", c_i$prefix, "* \n", sep = "")
    }
  }

  if (!length(rows)) { cat("\nNo cell produced metrics.\n"); return(invisible(NULL)) }
  res <- do.call(rbind, rows)
  res$cohort_attempt <- unlist(attempts[res$cell])
  write.csv(res, file.path(out_dir, "sensitivity_metrics.csv"), row.names = FALSE)

  # One cohort, or the table is not a sensitivity table. If the cohort was
  # rebuilt mid-sweep, part of every difference is the patients while the
  # output says the threshold did it - and no number here would show that.
  seen <- unique(unlist(attempts))
  if (length(seen) > 1L) {
    cat("\nCOHORT CHANGED DURING THE SWEEP - these cells did not read one ",
        "cohort attempt:\n", sep = "")
    for (nm in names(attempts)) cat("  ", nm, "  ", attempts[[nm]], "\n", sep = "")
    cat("Part of every difference below is the patients, not the parameter. ",
        "Re-run the sweep against a cohort that is not being rebuilt.\n", sep = "")
  } else if (length(seen) == 1L && is.na(seen)) {
    cat("\nNo cell recorded a cohort attempt, so nothing here shows that all ",
        length(rows), " read one cohort. Check COHORT_PREFIX names the build ",
        "that wrote ", cohort, ".\n", sep = "")
  } else {
    cat("\nAll ", length(rows), " cells read cohort attempt ", seen, ".\n", sep = "")
  }

  cmp <- sens_compare(res, SENS_AXES)
  if (!is.null(cmp)) {
    write.csv(cmp, file.path(out_dir, "sensitivity_vs_expected.csv"), row.names = FALSE)
    against <- cmp[cmp$verdict == "AGAINST EXPECTATION", , drop = FALSE]
    flat    <- cmp[cmp$verdict == "no movement", , drop = FALSE]
    cat("\n", nrow(cmp), " predictions, ", nrow(against), " against expectation, ",
        nrow(flat), " with no movement at all.\n", sep = "")
    if (nrow(against))
      for (i in seq_len(nrow(against)))
        cat("  AGAINST: ", against$cell[i], " ", against$metric[i],
            " expected ", against$expected[i], ", moved ", against$moved[i],
            " (", against$confidence[i], ")\n", sep = "")
    cat("A prediction against expectation is the finding here - either the ",
        "algorithm does something we did not think it did, or we read it wrong.\n",
        sep = "")
    if (nrow(flat)) {
      for (i in seq_len(nrow(flat)))
        cat("  no movement: ", flat$cell[i], " ", flat$metric[i],
            " expected ", flat$expected[i], ", unchanged at ", flat$reference[i],
            "\n", sep = "")
      cat("No movement is not the opposite finding. A threshold no patient sits ",
          "near cannot move anything however it is set, and that is the cohort ",
          "rather than the algorithm - worth looking at, not a contradiction.\n",
          sep = "")
    }
  }
  cat("\nWrote ", out_dir, "\n", sep = "")
}

out_dir <- Sys.getenv("OUTPUT_DIR", unset = file.path(.script_dir, "out"))
if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

if (!interactive()) {
  # Only when executing: the plan needs no connection and no packages, which is
  # what makes it readable before anyone commits warehouse time to it.
  if (env_flag("SENS_EXECUTE")) {
    library(DBI); library(odbc); library(glue)
    e <- new.env(parent = globalenv())
    sys.source(file.path(LOT_ROOT, "R", "load_inputs.R"), envir = e)
    e$load_pipeline_inputs(LOT_ROOT, "config.csv")
    for (f in c("config_lot.R", "db_utils_lot.R")) source(file.path(LOT_ROOT, "R", f))
    set_lot_config(modifyList(cfg_defaults, list(
      work_schema = Sys.getenv("PROJECT_WORK_SCHEMA",
                      unset = Sys.getenv("DOMINO_USER_NAME", unset = "")))))
  }
  main()
}
