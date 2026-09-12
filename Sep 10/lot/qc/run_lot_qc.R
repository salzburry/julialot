#!/usr/bin/env Rscript
# QC on a finished LOT run.
#
#   # list the checks and what each one is for; no connection
#   Rscript lot/qc/run_lot_qc.R
#
#   # run them
#   DATABRICKS_PWD=... DOMINO_USER_NAME=usr00000 OBJECT_PREFIX=ndmm_ \
#     INPUT_COHORT_TABLE=ndmm_NDMM_COHORT \
#     QC_EXECUTE=TRUE Rscript lot/qc/run_lot_qc.R
#
# Reads and writes nothing to the warehouse. The report lands in out/.
#
# The build already refuses a LOT_LONG whose lines overlap, run backwards or
# skip a number - the checks it can afford on every run. This asks the slower
# questions: does each end reason agree with its own date, does every drug in a
# regimen have a treatment episode inside that line's window, do the funnel and
# the table describe the same run. It asks them after the fact, so a run
# already on disk can be checked without rebuilding it.
#
# Exit status is 0 when nothing failed, 1 when something did. A failure means
# the build produced something its own definition says it cannot.

.script_dir <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  # Rscript renders a space in a path as ~+~, so a folder with one in its name
  # resolves to nothing without this.
  if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                            fixed = TRUE))) else getwd()
})
source(file.path(.script_dir, "R", "checks.R"))
check_qc_catalogue()

LOT_ROOT <- normalizePath(file.path(.script_dir, "..", "engine"), mustWork = TRUE)
out_dir  <- file.path(.script_dir, "out")
env_flag <- function(nm) identical(toupper(trimws(Sys.getenv(nm, unset = ""))), "TRUE")

report_catalogue <- function(checks) {
  cat("\nQC on a finished LOT run.\n\n")
  g <- ""
  for (c_i in checks) {
    if (!identical(c_i$group, g)) { g <- c_i$group; cat("  ", g, "\n", sep = "") }
    cat(sprintf("    %-4s %-5s %s\n", c_i$id, c_i$severity, c_i$what))
  }
  cat("\n  ", length(checks), " checks. ",
      sum(vapply(checks, function(c_i) identical(c_i$severity, "fail"), logical(1))),
      " of them are failures if they find anything; the rest are reported.\n", sep = "")
}

main <- function() {
  report_catalogue(LOT_QC_CHECKS)
  if (!env_flag("QC_EXECUTE")) {
    cat("\nNothing was read. Set QC_EXECUTE=TRUE to run them.\n")
    return(invisible(NULL))
  }

  library(DBI); library(odbc); library(glue)
  source(file.path(LOT_ROOT, "R", "load_inputs.R"))
  load_pipeline_inputs(LOT_ROOT, "config.csv")
  for (f in c("config_lot.R", "db_utils_lot.R")) source(file.path(LOT_ROOT, "R", f))
  cfg <- get("cfg_defaults", envir = globalenv())

  schema <- Sys.getenv("PROJECT_WORK_SCHEMA",
              unset = Sys.getenv("DOMINO_USER_NAME",
                unset = Sys.getenv("DOMINO_STARTING_USERNAME", unset = "")))
  if (!nzchar(schema))
    stop("No work schema. Set DOMINO_USER_NAME to the schema the build wrote ",
         "into, or PROJECT_WORK_SCHEMA to override.", call. = FALSE)
  cfg$work_schema <- schema

  # The prefix names which run is being checked. Blank would ask for
  # unprefixed tables and report on whatever happens to be there.
  pfx <- trimws(Sys.getenv("OBJECT_PREFIX", unset = ""))
  if (!nzchar(pfx))
    stop("No OBJECT_PREFIX. It is what names the run's tables, so without it ",
         "this would check whatever unprefixed tables exist.", call. = FALSE)
  if (!grepl("^[A-Za-z][A-Za-z0-9_]*_$", pfx))
    stop("OBJECT_PREFIX '", pfx, "' should be a name ending in '_'.", call. = FALSE)
  cfg$object_prefix <- pfx

  # The cohort table is the whole physical name, prefix included, because that
  # is how the build takes it. Several checks read it for death dates and the
  # observation window; without it they would be skipped rather than passed.
  cohort <- trimws(Sys.getenv("INPUT_COHORT_TABLE", unset = ""))
  if (!nzchar(cohort))
    stop("No INPUT_COHORT_TABLE. The end-reason and episode checks read the ",
         "cohort for its observation windows and death dates. Give the whole ",
         "name including the prefix, e.g. ", pfx, "NDMM_COHORT.", call. = FALSE)

  set_lot_config(cfg)
  dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
  stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")
  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  # lot_out() for what the build wrote - it adds the prefix. wrk() for the
  # cohort table, which is named by whoever built it and comes in whole.
  t <- list(final     = lot_out("LOT_LONG_FINAL"),
            long      = lot_out("LOT_LONG"),
            map       = lot_out("MAP_STACKED"),
            sct       = lot_out("LOT1_SCT"),
            # Every processed autologous event, before any line claims one.
            # The per-line SCT tables cannot answer an ownership question: an
            # AUTO outside a line's window is stored as ENDING_AUTO_DT and never
            # as TX_AUTO_DT_1, so a check reading those columns cannot see it -
            # and would report clean on the orphan it exists to find.
            auto      = lot_out("TX_AUTO_DATES"),
            # The allogeneic and CAR-T events, for the one thing the ownership
            # checks need them for: the build stops reading a line's AUTOs at
            # the first of these, so a check on unowned AUTOs must stop there
            # too or it reports the censor as a defect.
            allo      = lot_out("TX_ALLO_CART_DATES"),
            # Which drugs are one agent. C1 has to answer that the way the
            # engine does - a substitute and the drug it replaces are one
            # agent in both directions - and cannot without the pairs.
            subs      = lot_out("PERMISSIBLE_SUBS"),
            attrition = lot_out("LOT_ATTRITION"),
            meta      = lot_out("LOT_RUN_METADATA"),
            cohort    = wrk(cohort))

  # Which run owns the prefix. The latest status row, whatever state it
  # reached - the same answer every other reader in this folder resolves, and
  # for the same reason: the build replaces its tables before it validates
  # them, so a rerun that replaced them and then failed still owns them.
  # STATE and UPDATED_AT are this table's columns. RUN_TIMESTAMP belongs to
  # LOT_RUN_METADATA, and naming it here failed the query outright.
  st <- db_q(con, glue("
    SELECT RUN_ID, STATE, CONTRACT_DEVIATIONS
    FROM {lot_out('LOT_BUILD_STATUS')}
    ORDER BY UPDATED_AT DESC LIMIT 1"))
  if (!nrow(st))
    stop("No row in ", lot_out("LOT_BUILD_STATUS"), ", so there is no run to ",
         "check under prefix '", pfx, "'.", call. = FALSE)
  run_id <- as.character(st$RUN_ID[1])
  status <- as.character(st$STATE[1])
  devs   <- trimws(as.character(st$CONTRACT_DEVIATIONS[1] %||% ""))

  if (!identical(status, "complete"))
    stop("The run owning this prefix is '", status, "', not complete. Its ",
         "tables are whatever the failed attempt left behind, so QC on them ",
         "would describe a partial build.", call. = FALSE)

  # A deviating run is a different algorithm, and most of these checks are
  # statements about the contract one. Checking a sensitivity or melphalan cell
  # is a reasonable thing to want, so it is allowed - but it has to be asked
  # for, and the report says which run it was.
  if (nzchar(devs) && !env_flag("QC_ALLOW_DEVIATION"))
    stop("This run is not a contract build: ", devs, ". Most checks here are ",
         "statements about the contract algorithm. Set QC_ALLOW_DEVIATION=TRUE ",
         "to check it anyway - the report will carry the deviation.",
         call. = FALSE)

  meta <- db_q(con, glue("
    SELECT CONTRACT_SETTINGS FROM {t$meta} WHERE RUN_ID = '{run_id}'"))
  if (!nrow(meta))
    stop("No LOT_RUN_METADATA row for run ", run_id, ". Without it there is no ",
         "record of which windows the run used, and every check that depends on ",
         "one would be checking this config against another run's lines.",
         call. = FALSE)
  settings <- as.character(meta$CONTRACT_SETTINGS[1])

  p <- qc_params(settings, run_id)

  cat("\nRun ", run_id, " under prefix ", pfx, "\n", sep = "")
  cat("  windows: LOT1 ", p$ind1, "d, later lines ", p$indn, "d, CAR-T ", p$cart,
      "d; tandem ", p$tandem, "d, autologous gap ", p$auto_gap, "d\n", sep = "")
  cat("  observation end: ", if (p$censor)
        "capped at disenrollment" else "ENDDATE, disenrollment ignored", "\n", sep = "")
  cat("  melphalan rule: ", p$melp_rule, "\n", sep = "")
  if (nzchar(devs)) cat("  NOT A CONTRACT BUILD: ", devs, "\n", sep = "")

  # A table this version reads that the run did not write is a version
  # difference, not a defect. Its checks are skipped by name.
  have <- vapply(t, function(x)
    isTRUE(tryCatch({ db_q(con, paste0("SELECT 1 FROM ", x, " LIMIT 1")); TRUE },
                    error = function(e) FALSE)), logical(1))
  if (any(!have))
    cat("  absent: ", paste(names(have)[!have], collapse = ", "),
        " - checks needing them are skipped\n", sep = "")

  # The per-line raw SCT tables, for the lines this run built. E1 reads the raw
  # flags because LOT_LONG derives its single flag as the negation of its
  # tandem flag, so both being 1 cannot survive the projection.
  #
  # The line numbers come from the run's own published table, not from max_lot:
  # per-line stage tables are kept on purpose and a run replaces only the lines
  # it builds, so a LOT4_SCT left by an earlier run would put that run's
  # patients into this run's result.
  #
  # A line this run did build must have its raw SCT table readable, or QC
  # stops. Treating an unreadable table as absent would shorten E1's union and
  # report a clean result over the lines it managed to read.
  p$sct_extra <- local({
    lots <- tryCatch(
      db_q(con, paste0("SELECT DISTINCT LOT_NUM FROM ", t$final,
                       " WHERE LOT_NUM >= 2 ORDER BY LOT_NUM"))$LOT_NUM,
      error = function(e) integer(0))
    lots <- sort(unique(as.integer(lots[!is.na(lots)])))
    got <- character(0)
    missing <- character(0)
    for (k in lots) {
      nm <- lot_out(paste0("LOT", k, "_SCT"))
      okk <- isTRUE(tryCatch({ db_q(con, paste0("SELECT 1 FROM ", nm, " LIMIT 1")); TRUE },
                             error = function(e) FALSE))
      if (okk) got[as.character(k)] <- nm else missing <- c(missing, nm)
    }
    if (length(missing))
      stop("QC cannot validate transplants for lines this run built: ",
           paste(missing, collapse = ", "), " unreadable. A missing raw SCT ",
           "table would shorten E1's union silently, so the check would pass ",
           "over the lines it could read. Fix the table or the prefix; do not ",
           "run QC without it.", call. = FALSE)
    got
  })
  cat("  raw transplant tables: LOT1",
      if (length(p$sct_extra)) paste0(", LOT", names(p$sct_extra), collapse = "") else "",
      " (E1 reads these, not the published flags)\n", sep = "")

  rows <- list()
  for (c_i in LOT_QC_CHECKS) {
    missing <- setdiff(c_i$needs, names(have)[have])
    if (length(missing)) {
      rows[[length(rows) + 1L]] <- data.frame(
        id = c_i$id, group = c_i$group, severity = c_i$severity,
        result = "skip", n_bad = NA_integer_,
        detail = paste0("needs ", paste(missing, collapse = ", ")),
        what = c_i$what, stringsAsFactors = FALSE)
      next
    }
    q <- tryCatch(db_q(con, c_i$sql(t, p)), error = function(e) e)
    if (inherits(q, "error")) {
      # An error is not a pass. It is reported as its own outcome so a check
      # that could not run cannot be read as one that found nothing.
      rows[[length(rows) + 1L]] <- data.frame(
        id = c_i$id, group = c_i$group, severity = c_i$severity,
        result = "error", n_bad = NA_integer_,
        detail = conditionMessage(q), what = c_i$what, stringsAsFactors = FALSE)
      next
    }
    n <- as.numeric(q$N_BAD[1])
    res <- qc_outcome(n, c_i$severity)
    rows[[length(rows) + 1L]] <- data.frame(
      id = c_i$id, group = c_i$group, severity = c_i$severity,
      result = res, n_bad = n,
      detail = if (n == 0) "" else as.character(q$DETAIL[1] %||% ""),
      what = c_i$what, stringsAsFactors = FALSE)
    cat(sprintf("  %-4s %-6s %-8s %s\n", c_i$id, res,
                if (n == 0) "" else format(n, big.mark = ","), c_i$what))
  }
  res <- do.call(rbind, rows)
  res$run_id <- run_id

  utils::write.csv(res, file.path(out_dir, "lot_qc_results.csv"), row.names = FALSE)
  writeLines(qc_markdown(res, run_id, pfx, p, devs),
             file.path(out_dir, "lot_qc_report.md"))

  n_fail  <- sum(res$result == "FAIL")
  n_error <- sum(res$result == "error")
  n_skip  <- sum(res$result == "skip")
  cat("\n", nrow(res), " checks: ", sum(res$result == "pass"), " passed, ",
      n_fail, " failed, ", n_error, " errored, ", n_skip, " skipped.\n", sep = "")
  cat("Wrote ", out_dir, ".\n", sep = "")
  # An error is a check that did not run, and a QC pass that skipped checks is
  # not a pass. All three count against the exit status.
  if (n_fail + n_error + n_skip > 0) quit(status = 1L)
}

if (!interactive()) main()
