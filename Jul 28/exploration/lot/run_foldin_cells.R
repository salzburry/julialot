#!/usr/bin/env Rscript
# The MAP fold-in rule, built and measured as its own analysis.
#
#   # print the plan; touches nothing, needs no connection
#   INPUT_COHORT_TABLE=ndmm_NDMM_COHORT Rscript exploration/lot/run_foldin_cells.R
#
#   # build the two cells and read them
#   DATABRICKS_PWD=... INPUT_COHORT_TABLE=ndmm_NDMM_COHORT COHORT_PREFIX=ndmm_ \
#     FOLDIN_EXECUTE=TRUE Rscript exploration/lot/run_foldin_cells.R
#
#   # read cells already built, without rebuilding
#   ... FOLDIN_READ=TRUE Rscript exploration/lot/run_foldin_cells.R
#
# The rule, from the study team: a patient on drug A + drug B whose line was
# advanced by a new drug C, and whose drug B then reappears after the next
# line's regimen window - B should be PART of the line it reappears in, not a
# reason to start another one. Refined on 2026-08-20 into a count: one agent
# advancing the line in between and the return folds, two or more and it opens
# a line. The study adopted it on 2026-08-30, so APPLY_MAP_FOLDIN is TRUE in
# CONTRACT and this is the study's own algorithm.
#
# Which cell is the deviation flipped with that adoption. 'folded' is the
# contract build and records nothing; 'reference' is built with
# APPLY_MAP_FOLDIN=FALSE under LOT_CONTRACT_OVERRIDE, is stamped in
# CONTRACT_DEVIATIONS, and every reader that resolves run ownership refuses it
# as the study's numbers.
#
# Two complete LOT builds under their own foldin_* prefixes - one without the
# rule and the contract's - differenced. Two builds rather than arithmetic on a
# finished run, because a removed boundary changes the line's run-out and
# every later window; the sizing screen in analysis/questions counts today's
# boundaries, and this package is what those boundaries turn into.
#
# The cell machinery is the melphalan packages' - one set of status, input,
# deviation and settings checks for every rule experiment.
#
# The rule's branch behaviour is pinned against the engine's own SQL by a
# planted-patient harness in the repository's check suite - see the checks
# list in the repository README.

.script_dir <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                            fixed = TRUE))) else getwd()
})
source(file.path(.script_dir, "..", "melphalan", "R", "cells.R"))

LOT_ROOT <- normalizePath(file.path(.script_dir, "..", "..", "lot", "engine"), mustWork = TRUE)
env_flag <- function(nm) identical(toupper(trimws(Sys.getenv(nm, unset = ""))), "TRUE")
out_dir  <- melp_out_dir(.script_dir)

# `mode` is the deviation a cell must record, NA marking the contract build.
# Both moved when the study adopted the rule: 'folded' IS the contract now, and
# the cell without the rule is the one that deviates. `foldin` is what each
# hands to APPLY_MAP_FOLDIN, which is a separate thing - the contract cell
# names its value too, so an ambient setting cannot reach it.
FOLDIN_CELLS <- list(
  list(id = "reference", mode = "FALSE", foldin = "FALSE",
       what = paste0("no fold-in - a returning prior-line agent splits the ",
                     "line, which is what the build did before the study ",
                     "adopted the rule")),
  list(id = "folded", mode = NA_character_, foldin = "TRUE",
       what = paste0("the study's rule: a prior line's agent returning after ",
                     "the current line's regimen window joins that line ",
                     "instead of splitting it, when exactly ONE agent ",
                     "advanced the line between the drug's two doses. The ",
                     "line's SPAN owns the return - the regimen string and ",
                     "drug counts do not change - agents of EVERY earlier ",
                     "line fold, not only the last one's, and an AGENT is ",
                     "what is counted - transplants stay outside it, and a ",
                     "line one opened overrides the fold. Those three ",
                     "readings are open for the study team to confirm")))

report_plan <- function(cells) {
  cat("\nThe MAP fold-in rule, as two builds.\n\n")
  for (c_i in cells)
    cat(sprintf("  %-11s %-11s %s\n", c_i$id,
                if (identical(c_i$foldin, "TRUE")) "fold-in" else "(no rule)",
                c_i$prefix))
  cat("\n")
  for (c_i in cells) cat("  ", c_i$id, "\n    ", c_i$what, "\n", sep = "")
  cat("\n", length(cells), " cells. EACH ONE IS A COMPLETE LOT BUILD.\n", sep = "")
}

run_cell <- function(c_i, cohort, cohort_pfx) {
  args <- c(file.path(LOT_ROOT, "build.R"), cohort, c_i$prefix)
  env  <- paste0("COHORT_PREFIX=", cohort_pfx)
  st   <- trimws(Sys.getenv("COHORT_STATUS_TABLE", unset = ""))
  if (nzchar(st)) env <- c(env, paste0("COHORT_STATUS_TABLE=", st))
  # Both cells name both settings rather than inheriting the shell: a child
  # gets the parent's exports, and an ambient value reaching one arm and not
  # the other would put two changes between the cells instead of one. The
  # melphalan mode is named rather than blanked - load_inputs.R fills an empty
  # variable from config.csv, so APPLY_MELP_RULE= would pin nothing at all.
  env <- c(env, paste0("APPLY_MAP_FOLDIN=", c_i$foldin),
           "APPLY_MELP_RULE=simplified")
  # The override goes on the cell that is not the contract build - since the
  # study adopted the rule, that is the reference.
  if (!is.na(c_i$mode)) env <- c(env, "LOT_CONTRACT_OVERRIDE=TRUE")
  log_f <- file.path(out_dir, paste0("build_foldin_", c_i$id, ".log"))
  cat("  building ", c_i$id, " -> ", c_i$prefix, "  (log: ", log_f, ")\n", sep = "")
  rc <- system2("Rscript", args, env = env, stdout = log_f, stderr = log_f)
  if (!identical(as.integer(rc), 0L)) {
    cat("    FAILED (exit ", rc, ") - see the log.\n", sep = "")
    return(FALSE)
  }
  TRUE
}

# Every line of every patient the rule moved, before and after, one row per
# patient and line with both cells' dates side by side - so the study team
# reviews patients, not only aggregates. All lines of a moved patient are
# kept, changed or not, because a renumbered line only makes sense next to
# the ones around it. Null-safe comparisons, so a line present on one side
# only, or a date going missing, reads as a change rather than vanishing.
foldin_changed_sql <- function(a_tbl, b_tbl) {
  side <- function(t) paste0("
      SELECT cast(PATID as string) AS PATID, LOT_NUM, LOT_START_DT,
             LOT_BASE_END_DT, LOT_BASE_END_REASON, LOT_BASE_MEDS,
             LOT_BASE_DISCON_DT, LOT_BASE_1ST_ADD_MED
      FROM ", t)
  paste0("
    WITH a AS (", side(a_tbl), "),
    b AS (", side(b_tbl), "),
    j AS (
      SELECT coalesce(a.PATID, b.PATID)     AS PATID,
             coalesce(a.LOT_NUM, b.LOT_NUM) AS LOT_NUM,
             a.LOT_START_DT         AS REF_START_DT,
             b.LOT_START_DT         AS FOLD_START_DT,
             a.LOT_BASE_END_DT      AS REF_END_DT,
             b.LOT_BASE_END_DT      AS FOLD_END_DT,
             a.LOT_BASE_END_REASON  AS REF_END_REASON,
             b.LOT_BASE_END_REASON  AS FOLD_END_REASON,
             a.LOT_BASE_MEDS        AS REF_REGIMEN,
             b.LOT_BASE_MEDS        AS FOLD_REGIMEN,
             a.LOT_BASE_DISCON_DT   AS REF_DISCON_DT,
             b.LOT_BASE_DISCON_DT   AS FOLD_DISCON_DT,
             a.LOT_BASE_1ST_ADD_MED AS REF_1ST_ADD_MED,
             b.LOT_BASE_1ST_ADD_MED AS FOLD_1ST_ADD_MED,
             CASE WHEN a.PATID IS NULL OR b.PATID IS NULL
                    OR NOT (a.LOT_START_DT        <=> b.LOT_START_DT)
                    OR NOT (a.LOT_BASE_END_DT     <=> b.LOT_BASE_END_DT)
                    OR NOT (a.LOT_BASE_END_REASON <=> b.LOT_BASE_END_REASON)
                    OR NOT (a.LOT_BASE_MEDS       <=> b.LOT_BASE_MEDS)
                    OR NOT (a.LOT_BASE_DISCON_DT  <=> b.LOT_BASE_DISCON_DT)
                    -- The stored first-added medication too: a same-day case
                    -- where only the pick changes moves no date, and would
                    -- otherwise be invisible here.
                    OR NOT (a.LOT_BASE_1ST_ADD_MED <=> b.LOT_BASE_1ST_ADD_MED)
                  THEN 1 ELSE 0 END AS LINE_CHANGED
      FROM a FULL OUTER JOIN b
        ON a.PATID = b.PATID AND a.LOT_NUM = b.LOT_NUM
    ),
    moved AS (SELECT DISTINCT PATID FROM j WHERE LINE_CHANGED = 1)
    SELECT j.* FROM j INNER JOIN moved m ON m.PATID = j.PATID
    ORDER BY j.PATID, j.LOT_NUM")
}

# Two built cells in, four files out. Everything is computed first and
# written afterwards, so a read that cannot produce the whole set writes none.
foldin_report <- function(con, cells, out_dir, lot_root = NULL) {
  status <- setNames(lapply(cells, function(c_i) cell_status(con, c_i)),
                     vapply(cells, function(c_i) c_i$id, character(1)))
  inputs <- melp_read_inputs(con, cells, status, key = "apply_map_foldin")
  if (!is.null(lot_root)) melp_check_code(inputs, lot_root)
  st <- melp_settings(inputs, vary = "apply_map_foldin")
  cat("\nBoth cells were built over cohort attempt ",
      inputs[[1]]$COHORT_RUN_ID[1], " / ", inputs[[1]]$COHORT_STAMP[1],
      ", the same code and code lists.\n", sep = "")

  rows <- list()
  for (c_i in cells) {
    final <- wrk(paste0(c_i$prefix, "LOT_LONG_FINAL"))
    cat("  reading ", c_i$id, " from ", final, "\n", sep = "")
    m <- melp_metrics(con, final,
      wrk(paste0(c_i$prefix, "LOT_ATTRITION")), status[[c_i$id]]$run_id, st$abbr,
      map_tbl = wrk(paste0(c_i$prefix, "MAP_STACKED")),
      expo_days = st$expo_days, restart_days = st$restart_days,
      advance_days = st$advance_days, ind1 = st$ind1, indn = st$indn,
      cart = st$cart)
    if (is.null(m))
      stop("Metrics could not be read for ", c_i$id, " (", final, "): a ",
           "statement returned no row, so that cell was never fully built.",
           call. = FALSE)
    rows[[length(rows) + 1L]] <- cbind(cell = c_i$id, mode = c_i$mode, m,
                                       stringsAsFactors = FALSE)
  }
  res <- do.call(rbind, rows)
  cmp <- melp_compare(res, cells)

  pfx_of <- function(id) {
    hit <- Filter(function(c_i) identical(c_i$id, id), cells)
    hit[[1]]$prefix
  }
  # Patient by patient, not totals subtracted: one removed boundary renumbers
  # every later line, and two patients moving opposite ways cancel in an
  # aggregate.
  pd <- db_q(con, melp_modes_patients_sql(
    wrk(paste0(pfx_of("reference"), "LOT_LONG_FINAL")),
    wrk(paste0(pfx_of("folded"), "LOT_LONG_FINAL"))))
  if (!nrow(pd))
    stop("The two builds could not be compared patient by patient.", call. = FALSE)
  # The roster behind those totals: every moved patient's lines, both cells
  # side by side. Zero rows is an answer (the rule moved nobody), so the file
  # is written either way.
  ch <- db_q(con, foldin_changed_sql(
    wrk(paste0(pfx_of("reference"), "LOT_LONG_FINAL")),
    wrk(paste0(pfx_of("folded"), "LOT_LONG_FINAL"))))

  melp_status_unchanged(con, cells, status)

  dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
  out <- list(foldin_cells.csv         = melp_stamp(res, inputs, status),
              foldin_vs_reference.csv  = melp_stamp(cmp, inputs, status),
              foldin_patients.csv      = melp_stamp(pd, inputs, status),
              foldin_changed_lines.csv = melp_stamp(ch, inputs, status))
  tmp <- file.path(out_dir, paste0(".", names(out), ".part"))
  on.exit(unlink(tmp[file.exists(tmp)]), add = TRUE)
  for (i in seq_along(out))
    utils::write.csv(out[[i]], tmp[i], row.names = FALSE)
  for (i in seq_along(out))
    if (!file.rename(tmp[i], file.path(out_dir, names(out)[i])))
      stop("Could not move ", names(out)[i], " into ", out_dir, ".", call. = FALSE)

  cat("\nThe fold-in against the contract build:\n\n")
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
  cat("\n  foldin_changed_lines.csv holds every moved patient's lines, both\n",
      "  cells side by side - the file to review patient by patient.\n", sep = "")
  cat("\nThe sizing screen in analysis/questions counts the CURRENT boundaries\n",
      "where a PREVIOUS-line agent returns; these two builds are what those\n",
      "boundaries turn into once the run-outs and windows move with them.\n",
      "The cell folds agents of EVERY earlier line, so the screen's count is\n",
      "a lower bound on the population this pair moves.\n", sep = "")
  cat("\nWrote ", out_dir, ".\n", sep = "")
  invisible(list(cells = res, compare = cmp, patients = pd))
}

main <- function() {
  cohort <- trimws(Sys.getenv("INPUT_COHORT_TABLE", unset = ""))
  study  <- trimws(Sys.getenv("OBJECT_PREFIX", unset = ""))
  cohort_pfx <- trimws(Sys.getenv("COHORT_PREFIX", unset = ""))
  cells <- melp_cell_plan(FOLDIN_CELLS, "foldin_")
  check_melp_plan(cells, study)
  report_plan(cells)

  build <- env_flag("FOLDIN_EXECUTE")
  read  <- env_flag("FOLDIN_READ")
  if (!build && !read) {
    cat("\nNothing was built. FOLDIN_EXECUTE=TRUE builds and reads; ",
        "FOLDIN_READ=TRUE\nreads cells already built.\n", sep = "")
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
    built <- vapply(cells, function(c_i) run_cell(c_i, cohort, cohort_pfx),
                    logical(1))
    if (!all(built))
      stop("These cells did not build: ",
           paste(vapply(cells[!built], function(c_i) c_i$id, character(1)),
                 collapse = ", "),
           ". The result is the comparison between the two, so a partial run ",
           "is no answer. See the logs in ", out_dir, ".", call. = FALSE)
  }

  foldin_report(con, cells, out_dir, lot_root = LOT_ROOT)
  cat("These are two algorithms' numbers. The folded cell carries its ",
      "deviation in\nLOT_BUILD_STATUS, and every reader that resolves run ",
      "ownership refuses it as\nthe study's.\n", sep = "")
}

if (!interactive()) main()
