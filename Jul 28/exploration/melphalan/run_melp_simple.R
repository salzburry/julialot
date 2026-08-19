#!/usr/bin/env Rscript
# The simplified melphalan fallback, built and measured as its own analysis.
#
#   # print the plan; touches nothing, needs no connection
#   INPUT_COHORT_TABLE=ndmm_NDMM_COHORT Rscript exploration/melphalan/run_melp_simple.R
#
#   # build the two cells and read them
#   DATABRICKS_PWD=... INPUT_COHORT_TABLE=ndmm_NDMM_COHORT COHORT_PREFIX=ndmm_ \
#     MELP_SIMPLE_EXECUTE=TRUE Rscript exploration/melphalan/run_melp_simple.R
#
#   # read cells already built, without rebuilding (after a failure in the read)
#   ... MELP_SIMPLE_READ=TRUE Rscript exploration/melphalan/run_melp_simple.R
#
# The rule under test, from the study team's follow-up note: melphalan received
# for MELP_SIMPLE_COURSE_DAYS or fewer (28 by default) outside any induction
# window does not advance the line on its own. If a new agent starts while
# that course still covers, the next line starts on the MELPHALAN date, not
# the agent's later one - their day-100/105 example.
#
# This is separate from the three-cell package (run_aug1_melp.R), which
# evaluates the original five-branch rule. Two complete LOT builds under their
# own melp_simple_* prefixes: the contract build and the simplified rule. The
# difference between them is what the simplification does, in patients.
#
# Two things are not settled by running this:
#   - whether the cap should be 28 days or an imputed 30. Rebuild with
#     MELP_SIMPLE_COURSE_DAYS=30 (it reaches the simplified cell only) and
#     compare the two reads.
#   - what "melphalan mono" should mean where MELP+DEX was collapsed to
#     melphalan by the code list - steroids are not captured, so a
#     melphalan-with-steroid line reads as melphalan alone here.
#
# The rule's branch behaviour, the day-100/105 case included, is pinned
# against the engine's own SQL by a planted-patient harness in the
# repository's check suite - see the checks list in the repository README.

.script_dir <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                            fixed = TRUE))) else getwd()
})
source(file.path(.script_dir, "R", "cells.R"))

LOT_ROOT <- normalizePath(file.path(.script_dir, "..", "..", "lot", "engine"), mustWork = TRUE)
env_flag <- function(nm) identical(toupper(trimws(Sys.getenv(nm, unset = ""))), "TRUE")
out_dir  <- melp_out_dir(.script_dir)

MELP_SIMPLE_CELLS <- list(
  list(id = "reference", mode = NA_character_,
       what = "the contract build, unchanged - the baseline the rule is measured against"),
  list(id = "simplified", mode = "simplified",
       what = paste0("a short melphalan course outside induction does not ",
                     "advance a line on its own; a new agent starting inside ",
                     "the course advances it on the melphalan date")))

report_plan <- function(cells, cap) {
  cat("\nThe simplified melphalan rule, as two builds.\n\n")
  for (c_i in cells)
    cat(sprintf("  %-11s %-11s %s\n", c_i$id,
                if (is.na(c_i$mode)) "(no rule)" else c_i$mode, c_i$prefix))
  cat("\n")
  for (c_i in cells) cat("  ", c_i$id, "\n    ", c_i$what, "\n", sep = "")
  cat("\n  course cap: ", cap, " days",
      if (!identical(cap, "28")) "  (overridden from the 28-day default)" else "",
      "\n", sep = "")
  cat("\n", length(cells), " cells. EACH ONE IS A COMPLETE LOT BUILD.\n", sep = "")
}

run_cell <- function(c_i, cohort, cohort_pfx, cap) {
  args <- c(file.path(LOT_ROOT, "build.R"), cohort, c_i$prefix)
  env  <- paste0("COHORT_PREFIX=", cohort_pfx)
  st   <- trimws(Sys.getenv("COHORT_STATUS_TABLE", unset = ""))
  if (nzchar(st)) env <- c(env, paste0("COHORT_STATUS_TABLE=", st))
  if (!is.na(c_i$mode)) {
    env <- c(env, "LOT_CONTRACT_OVERRIDE=TRUE",
             paste0("APPLY_MELP_RULE=", c_i$mode),
             # The cap reaches the mode cell only. The reference must be the
             # contract build with no deviation at all - the setting is inert
             # while the rule is off, so it changes nothing there anyway.
             paste0("MELP_SIMPLE_COURSE_DAYS=", cap))
  }
  log_f <- file.path(out_dir, paste0("build_simple_", c_i$id, ".log"))
  cat("  building ", c_i$id, " -> ", c_i$prefix, "  (log: ", log_f, ")\n", sep = "")
  rc <- system2("Rscript", args, env = env, stdout = log_f, stderr = log_f)
  if (!identical(as.integer(rc), 0L)) {
    cat("    FAILED (exit ", rc, ") - see the log.\n", sep = "")
    return(FALSE)
  }
  TRUE
}

# Two built cells in, four files out. Everything is computed first and written
# afterwards, so a read that cannot produce the whole set writes none of it.
melp_simple_report <- function(con, cells, out_dir, lot_root = NULL) {
  status <- setNames(lapply(cells, function(c_i) cell_status(con, c_i)),
                     vapply(cells, function(c_i) c_i$id, character(1)))
  inputs <- melp_read_inputs(con, cells, status,
                             allowed = "melp_simple_course_days")
  if (!is.null(lot_root)) melp_check_code(inputs, lot_root)
  st  <- melp_settings(inputs, vary = c("apply_melp_rule",
                                        "melp_simple_course_days"))
  cap <- melp_parse_settings(
    inputs$simplified$CONTRACT_SETTINGS)$melp_simple_course_days
  cat("\nBoth cells were built over cohort attempt ",
      inputs[[1]]$COHORT_RUN_ID[1], " / ", inputs[[1]]$COHORT_STAMP[1],
      ", the same code and code lists. Course cap: ", cap, " days.\n", sep = "")

  rows <- list(); by_line <- list()
  for (c_i in cells) {
    final <- wrk(paste0(c_i$prefix, "LOT_LONG_FINAL"))
    map_t <- wrk(paste0(c_i$prefix, "MAP_STACKED"))
    cat("  reading ", c_i$id, " from ", final, "\n", sep = "")
    m <- melp_metrics(con, final,
      wrk(paste0(c_i$prefix, "LOT_ATTRITION")), status[[c_i$id]]$run_id, st$abbr,
      map_tbl = map_t, expo_days = st$expo_days, restart_days = st$restart_days,
      advance_days = st$advance_days, ind1 = st$ind1, indn = st$indn,
      cart = st$cart)
    if (is.null(m))
      stop("Metrics could not be read for ", c_i$id, " (", final, "): a ",
           "statement returned no row, so that cell was never fully built.",
           call. = FALSE)
    rows[[length(rows) + 1L]] <- cbind(cell = c_i$id, mode = c_i$mode, m,
                                       stringsAsFactors = FALSE)
    d <- db_q(con, melp_by_line_sql(final, map_t, st$abbr))
    if (!nrow(d))
      stop("Melphalan could not be counted by line for ", c_i$id, " (", final,
           ").", call. = FALSE)
    by_line[[length(by_line) + 1L]] <- cbind(cell = c_i$id, d,
                                             stringsAsFactors = FALSE)
  }
  res  <- do.call(rbind, rows)
  mono <- do.call(rbind, by_line)
  cmp  <- melp_compare(res, cells)

  pfx_of <- function(id) {
    hit <- Filter(function(c_i) identical(c_i$id, id), cells)
    hit[[1]]$prefix
  }
  # Patient by patient, not totals subtracted: one moved boundary shifts every
  # later line, and two patients moving opposite ways cancel in an aggregate.
  pd <- db_q(con, melp_modes_patients_sql(
    wrk(paste0(pfx_of("reference"), "LOT_LONG_FINAL")),
    wrk(paste0(pfx_of("simplified"), "LOT_LONG_FINAL"))))
  if (!nrow(pd))
    stop("The two builds could not be compared patient by patient.", call. = FALSE)

  melp_status_unchanged(con, cells, status)

  dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
  out <- list(melp_simple_cells.csv        = melp_stamp(res, inputs, status),
              melp_simple_vs_reference.csv = melp_stamp(cmp, inputs, status),
              melp_simple_patients.csv     = melp_stamp(pd, inputs, status),
              melp_simple_by_line.csv      = melp_stamp(mono, inputs, status))
  tmp <- file.path(out_dir, paste0(".", names(out), ".part"))
  on.exit(unlink(tmp[file.exists(tmp)]), add = TRUE)
  for (i in seq_along(out))
    utils::write.csv(out[[i]], tmp[i], row.names = FALSE)
  for (i in seq_along(out))
    if (!file.rename(tmp[i], file.path(out_dir, names(out)[i])))
      stop("Could not move ", names(out)[i], " into ", out_dir, ".", call. = FALSE)

  cat("\nThe simplified rule against the contract build:\n\n")
  for (i in seq_len(nrow(cmp)))
    cat(sprintf("  %-19s %10s -> %-10s %+8s  %s\n",
                cmp$metric[i], format(cmp$reference[i]),
                format(cmp$observed[i]), format(cmp$change[i]),
                if (is.na(cmp$pct_change[i])) "" else paste0(cmp$pct_change[i], "%")))
  cat("\nPatient by patient. A patient counts as differing when their line\n",
      "count, or any line's start, end or end reason, differs:\n\n", sep = "")
  cat("  ", pd$N_PATIENTS[1], " patients in either build\n", sep = "")
  cat("  ", pd$N_DIFFERENT[1], " whose lines differ\n", sep = "")
  cat("  ", pd$N_LINE_COUNT_DIFFERENT[1], " of those have a different NUMBER of lines\n", sep = "")
  cat("  ", pd$N_SAME_COUNT_DIFFERENT_LINES[1],
      " have the same number of lines in different places\n", sep = "")

  nf <- function(x) if (length(x) != 1L || is.na(x)) "-" else format(x)
  cat("\nMelphalan-only lines at 2L and 3L, among the melphalan-exposed:\n\n")
  cat(sprintf("  %-11s %4s %7s %7s %9s %10s\n",
              "cell", "LOT", "lines", "mono", "mono pts", "med-start"))
  for (i in which(mono$LOT_NUM %in% c(2L, 3L)))
    cat(sprintf("  %-11s %4s %7s %7s %9s %10s\n",
                mono$cell[i], mono$LOT_NUM[i], nf(mono$N_LINES[i]),
                nf(mono$N_MONO[i]), nf(mono$N_PAT_MONO[i]),
                nf(mono$N_MONO_MED_START[i])))
  cat("\nNot settled by this run: whether the cap should be ", cap,
      " or an imputed 30\n(rebuild the simplified cell with ",
      "MELP_SIMPLE_COURSE_DAYS=30 and compare), and\nwhat melphalan-with-DEX ",
      "should count as - steroids are not captured, so a\nmelphalan-plus-",
      "steroid line reads as melphalan alone in every count above.\n", sep = "")
  cat("\nWrote ", out_dir, ".\n", sep = "")
  invisible(list(cells = res, compare = cmp, patients = pd, by_line = mono))
}

main <- function() {
  cohort <- trimws(Sys.getenv("INPUT_COHORT_TABLE", unset = ""))
  study  <- trimws(Sys.getenv("OBJECT_PREFIX", unset = ""))
  cohort_pfx <- trimws(Sys.getenv("COHORT_PREFIX", unset = ""))
  cap    <- trimws(Sys.getenv("MELP_SIMPLE_COURSE_DAYS", unset = "28"))
  if (!grepl("^[0-9]+$", cap))
    stop("MELP_SIMPLE_COURSE_DAYS='", cap, "' is not a whole number of days.",
         call. = FALSE)
  cells <- melp_cell_plan(MELP_SIMPLE_CELLS, "melp_simple_")
  check_melp_plan(cells, study)
  report_plan(cells, cap)

  build <- env_flag("MELP_SIMPLE_EXECUTE")
  read  <- env_flag("MELP_SIMPLE_READ")
  if (!build && !read) {
    cat("\nNothing was built. MELP_SIMPLE_EXECUTE=TRUE builds and reads; ",
        "MELP_SIMPLE_READ=TRUE\nreads cells already built.\n", sep = "")
    return(invisible(NULL))
  }

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

  if (build) {
    if (!nzchar(cohort))
      stop("INPUT_COHORT_TABLE is not set. Both cells have to be built over ",
           "the same cohort or the difference is the cohort's, not the rule's.",
           call. = FALSE)
    if (!nzchar(cohort_pfx))
      stop("COHORT_PREFIX is not set, so the build would record no cohort ",
           "attempt at all.", call. = FALSE)
    dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
    cat("\nClearing the prefixes. Whatever was built under them is gone after ",
        "this.\n", sep = "")
    for (c_i in cells) melp_drop_cell(con, c_i, study)
    built <- vapply(cells, function(c_i) run_cell(c_i, cohort, cohort_pfx, cap),
                    logical(1))
    if (!all(built))
      stop("These cells did not build: ",
           paste(vapply(cells[!built], function(c_i) c_i$id, character(1)),
                 collapse = ", "),
           ". The result is the comparison between the two, so a partial run ",
           "is no answer. See the logs in ", out_dir, ".", call. = FALSE)
  }

  melp_simple_report(con, cells, out_dir, lot_root = LOT_ROOT)
  cat("These are two algorithms' numbers. The simplified cell carries its ",
      "deviation in\nLOT_BUILD_STATUS, and every reader that resolves run ",
      "ownership refuses it as\nthe study's.\n", sep = "")
}

if (!interactive()) main()
