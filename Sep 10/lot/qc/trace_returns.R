#!/usr/bin/env Rscript
# Trace the returning-drug rules (LOT_RULES.md 4.3 and 4.8) through real
# patients of a finished LOT run: "drugs that come back", and what the run
# did with each.
#
#   # list what it would do; no connection
#   Rscript lot/qc/trace_returns.R
#
#   # run it - the 2L question, as the study team asked it
#   DATABRICKS_PWD=... DOMINO_USER_NAME=usr00000 OBJECT_PREFIX=ndmm_ \
#     TRACE_EXECUTE=TRUE Rscript lot/qc/trace_returns.R
#
# Reads only. The traces land in out/: returns_trace.md, and the same rows as
# returns_trace_candidates.csv (every return in the run, all kinds),
# returns_trace_lines.csv, returns_trace_episodes.csv and
# returns_trace_summary.csv.
#
# Three kinds of return are traced and a fourth counted (R/return_trace.R):
# a previous-line drug that FOLDED into the line it returned in (4.8); a
# line's own drug that came back after a confirmed break and stayed in its
# line (4.3) - before the rule that return opened a new line; and an earlier
# drug that came back and OPENED a line, which neither rule prevents. Each
# patient's raw MAP episodes are shown beside the final lines, the returns
# marked, with a paragraph per return saying what the rule did and what the
# reading before 30 Aug 2026 would have done.
#
#   TRACE_KINDS        fold,own_return,opens_line (default all three)
#   TRACE_LINES        return lines to trace, comma-separated. Default 1,2:
#                      the 2L question - folds into 2L, own returns inside 2L,
#                      returns after 2L that opened 3L, and the own returns
#                      inside 1L that would have been a 2L before the rule.
#                      Empty traces every line.
#   TRACE_N            how many patients to trace (default 12), sampled
#                      round-robin over (kind, return line, drug)
#   TRACE_PATIDS       comma-separated ids to trace instead of sampling. A
#                      listed patient with no return is reported as such.
#   TRACE_MASK_PATID   TRUE masks ids to their last six characters. Off by
#                      default: the trace exists so a patient can be looked up.
#   QC_ALLOW_DEVIATION TRUE traces a run that deviated from the contract.
#
# Exit status is 0 when the trace was written, 1 when something stopped it.

.script_dir <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                            fixed = TRUE))) else getwd()
})
source(file.path(.script_dir, "R", "checks.R"))
source(file.path(.script_dir, "R", "foldin_trace.R"))
source(file.path(.script_dir, "R", "return_trace.R"))

LOT_ROOT <- normalizePath(file.path(.script_dir, "..", "engine"), mustWork = TRUE)
out_dir  <- file.path(.script_dir, "out")
env_flag <- function(nm) identical(toupper(trimws(Sys.getenv(nm, unset = ""))), "TRUE")

trace_n <- function() {
  raw <- trimws(Sys.getenv("TRACE_N", unset = "12"))
  n <- suppressWarnings(as.integer(raw))
  if (is.na(n) || n < 1L)
    stop("TRACE_N='", raw, "' is not a whole number of at least 1.", call. = FALSE)
  n
}
trace_patids <- function() {
  raw <- trimws(Sys.getenv("TRACE_PATIDS", unset = ""))
  if (!nzchar(raw)) return(NULL)
  foldin_trace_check_patids(strsplit(raw, ",", fixed = TRUE)[[1]])
}
trace_kinds <- function() return_trace_parse_kinds(Sys.getenv("TRACE_KINDS", unset = ""))
trace_lines <- function() {
  raw <- Sys.getenv("TRACE_LINES", unset = "1,2")
  return_trace_parse_lines(raw)
}

report_plan <- function() {
  cat("\nReturning-drug trace on a finished LOT run.\n\n")
  listed <- tryCatch(trace_patids(), error = function(e) {
    cat("  TRACE_PATIDS refused: ", conditionMessage(e), "\n", sep = ""); NULL })
  n_txt <- tryCatch(as.character(trace_n()), error = function(e) {
    cat("  TRACE_N refused: ", conditionMessage(e), "\n", sep = ""); "?" })
  kinds <- tryCatch(trace_kinds(), error = function(e) {
    cat("  TRACE_KINDS refused: ", conditionMessage(e), "\n", sep = ""); character(0) })
  lines <- tryCatch(trace_lines(), error = function(e) {
    cat("  TRACE_LINES refused: ", conditionMessage(e), "\n", sep = ""); NULL })
  cat("  reads   LOT_LONG_FINAL, MAP_STACKED, TX_ALLO_CART_DATES, TX_AUTO_DATES,\n",
      "         PERMISSIBLE_SUBS, LOT_RUN_METADATA, LOT_BUILD_STATUS under OBJECT_PREFIX\n",
      "  finds   every (patient, line, drug) where a drug came back:\n",
      "           fold        4.8 - a previous-line drug that joined the line it returned in\n",
      "           own_return  4.3 - a line's own drug back after a confirmed break, kept in its line\n",
      "           opens_line  an earlier drug that came back and opened a line (neither rule)\n",
      "         and counts the drugs carried over inside a window, which are neither\n",
      "  writes  ", file.path(out_dir, "returns_trace.md"), "\n",
      "          and returns_trace_candidates.csv, returns_trace_lines.csv,\n",
      "          returns_trace_episodes.csv, returns_trace_summary.csv beside it\n", sep = "")
  cat("  kinds   ", paste(kinds, collapse = ", "), "\n", sep = "")
  cat("  lines   ", if (is.null(lines)) "every return line" else paste(lines, collapse = ", "),
      " (TRACE_LINES; the line a return belongs to for the 2L question)\n", sep = "")
  cat("  traces  ",
      if (!is.null(listed)) paste0(length(listed), " listed patient(s) (TRACE_PATIDS)")
      else paste0(n_txt, " patients, round-robin over (kind, line, drug) (TRACE_N)"), "\n", sep = "")
  cat("  ids     ", if (env_flag("TRACE_MASK_PATID")) "masked (TRACE_MASK_PATID)"
                    else "unmasked, so the patients can be looked up", "\n", sep = "")
}

main <- function() {
  report_plan()
  if (!env_flag("TRACE_EXECUTE")) {
    cat("\nNothing was read. Set TRACE_EXECUTE=TRUE to run it.\n")
    return(invisible(NULL))
  }
  options(scipen = 999)
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
  pfx <- trimws(Sys.getenv("OBJECT_PREFIX", unset = ""))
  if (!nzchar(pfx))
    stop("No OBJECT_PREFIX. It is what names the run's tables, so without it ",
         "this would trace whatever unprefixed tables exist.", call. = FALSE)
  if (!grepl("^[A-Za-z][A-Za-z0-9_]*_$", pfx))
    stop("OBJECT_PREFIX '", pfx, "' should be a name ending in '_'.", call. = FALSE)
  cfg$object_prefix <- pfx

  n_want <- trace_n()
  listed <- trace_patids()
  kinds  <- trace_kinds()
  lines_in <- trace_lines()
  masked <- env_flag("TRACE_MASK_PATID")

  set_lot_config(cfg)
  dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
  stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")
  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  t <- list(final = lot_out("LOT_LONG_FINAL"),
            map   = lot_out("MAP_STACKED"),
            allo  = lot_out("TX_ALLO_CART_DATES"),
            auto  = lot_out("TX_AUTO_DATES"),
            subs  = lot_out("PERMISSIBLE_SUBS"),
            meta  = lot_out("LOT_RUN_METADATA"))

  status_row <- function()
    db_q(con, glue("
      SELECT RUN_ID, STATE, UPDATED_AT, CONTRACT_DEVIATIONS
      FROM {lot_out('LOT_BUILD_STATUS')}
      ORDER BY UPDATED_AT DESC LIMIT 1"))
  st <- status_row()
  if (!nrow(st))
    stop("No row in ", lot_out("LOT_BUILD_STATUS"), ", so there is no run to ",
         "trace under prefix '", pfx, "'.", call. = FALSE)
  run_id <- as.character(st$RUN_ID[1])
  status <- as.character(st$STATE[1])
  devs   <- trimws(as.character(st$CONTRACT_DEVIATIONS[1] %||% ""))
  pinned <- foldin_trace_build_pin(st)
  if (!identical(status, "complete"))
    stop("The run owning this prefix is '", status, "', not complete. Its ",
         "tables are whatever the failed attempt left behind, so a trace over ",
         "them would describe a partial build.", call. = FALSE)
  if (nzchar(devs) && !env_flag("QC_ALLOW_DEVIATION"))
    stop("This run is not a contract build: ", devs, ". Set ",
         "QC_ALLOW_DEVIATION=TRUE to trace it anyway - the report will carry ",
         "the deviation.", call. = FALSE)

  meta <- db_q(con, glue("
    SELECT CONTRACT_SETTINGS FROM {t$meta} WHERE RUN_ID = '{run_id}'"))
  if (!nrow(meta))
    stop("No LOT_RUN_METADATA row for run ", run_id, ". Without it there is no ",
         "record of which windows the run used, and every signature here is ",
         "read against the window.", call. = FALSE)
  settings <- as.character(meta$CONTRACT_SETTINGS[1])
  p <- qc_params(settings, run_id)
  p$gap <- qc_int(settings, "map_discon_gap_days")
  # The melphalan course cap, for the one reading that asserts a course is
  # short. A run that did not record it gets no such row rather than the
  # claim on no evidence.
  p$melp_days <- qc_int(settings, "melp_simple_course_days")

  # Without the rules there is nothing to trace: an own return's signature
  # cannot occur in a build that released the drug, and a fold's cannot occur
  # in one that did not fold. Such rows would be defects, which is the QC's
  # job (checks C1 and C2), not this trace's.
  if (!isTRUE(p$foldin) || !isTRUE(p$own_return_fold))
    stop("Run ", run_id, " did not apply the returning-drug rules (apply_map_foldin=",
         if (isTRUE(p$foldin)) "TRUE" else "not TRUE", ", apply_own_return_fold=",
         if (isTRUE(p$own_return_fold)) "TRUE" else "not TRUE",
         " in its CONTRACT_SETTINGS), so there is nothing to trace.", call. = FALSE)

  cat("\nRun ", run_id, " under prefix ", pfx, "\n", sep = "")
  cat("  windows: LOT1 ", p$ind1, "d, later lines ", p$indn, "d, CAR-T ", p$cart,
      "d; a break is ", p$gap, " days or more\n", sep = "")
  if (nzchar(devs)) cat("  NOT A CONTRACT BUILD: ", devs, "\n", sep = "")

  totals <- db_q(con, foldin_trace_totals_sql(t))
  qs <- return_trace_queries(t, p)
  results <- lapply(qs, function(q) db_q(con, q))
  cands <- return_trace_stack(results)
  subs  <- db_q(con, foldin_trace_subs_sql(t))
  fmt <- function(x) format(x, scientific = FALSE, trim = TRUE)
  for (k in RETURN_TRACE_ALL_KINDS) {
    d <- cands[cands$KIND == k, , drop = FALSE]
    cat("  ", sprintf("%-12s", k), nrow(d), " return(s) over ", length(unique(d$PATID)),
        " patient(s)\n", sep = "")
  }
  cat("  in a table of ", fmt(totals$N_PATIENTS[1]), " patients and ",
      fmt(totals$N_LINES[1]), " lines\n", sep = "")
  # A fold's signature on a line a transplant or CAR-T opened is a build
  # defect, not the rule (R/foldin_trace.R). Said here so it is not read as 4.8.
  n_odd <- sum(cands$KIND == "fold" & !is.na(cands$LOT_START_TYPE) & cands$LOT_START_TYPE != "MED")
  if (n_odd > 0L)
    cat("  ", n_odd, " fold signature(s) sit on a line a transplant or CAR-T opened: 4.8 ",
        "refuses a fold there, so these are build defects to raise, not folds\n", sep = "")

  summary <- return_trace_summary(cands, totals$N_PATIENTS[1], totals$N_LINES[1])
  scope <- return_trace_in_scope(cands, kinds, lines_in)
  n_scope_patients <- length(unique(scope$PATID))
  ids <- return_trace_sample(scope, n_want, listed)
  if (!is.null(listed)) {
    cat("  tracing ", length(ids), " listed patient(s); ",
        sum(ids %in% cands$PATID), " of them carry a return of some kind\n", sep = "")
  } else {
    cat("  tracing ", length(ids), " of ", n_scope_patients, " patient(s) with a return in scope",
        if (n_scope_patients > length(ids)) paste0(" (TRACE_N=", n_want, ")") else "", "\n", sep = "")
  }

  sections <- list(); lines_out <- NULL; eps_out <- NULL
  if (length(ids)) {
    lines <- db_q(con, foldin_trace_lines_sql(t, ids, p))
    eps   <- db_q(con, foldin_trace_episodes_sql(t, ids))
    tx    <- db_q(con, foldin_trace_tx_sql(t, ids))
    rows  <- cands[cands$PATID %in% ids, , drop = FALSE]
    ann   <- return_trace_annotate(lines, eps, tx, rows, p, subs = subs)
    for (id in ids) {
      shown <- if (masked) mask_patid_r(id) else id
      sections[[length(sections) + 1L]] <- return_trace_patient_md(
        shown, rows[rows$PATID == id, , drop = FALSE],
        lines[as.character(lines$PATID) == id, , drop = FALSE],
        eps[as.character(eps$PATID) == id, , drop = FALSE],
        ann[as.character(ann$PATID) == id, , drop = FALSE], p,
        tx_p = tx[as.character(tx$PATID) == id, , drop = FALSE], subs = subs)
    }
    lines_out <- lines[, c("PATID", TRACE_LINE_COLS), drop = FALSE]
    eps_out   <- ann[, c("PATID", TRACE_EPISODE_COLS), drop = FALSE]
  } else {
    cat("  no patient to trace: no return in scope in this run\n")
    lines_out <- data.frame(PATID = character(0))
    eps_out   <- data.frame(PATID = character(0))
  }
  cands_out <- cands
  if (masked) {
    lines_out$PATID <- mask_patid_r(lines_out$PATID)
    eps_out$PATID   <- mask_patid_r(eps_out$PATID)
    cands_out$PATID <- mask_patid_r(cands_out$PATID)
  }

  now <- foldin_trace_build_pin(status_row())
  if (!identical(now, pinned))
    stop("The run under prefix '", pfx, "' changed while its tables were being ",
         "read (", pinned, " -> ", now, "), so what was read is not one ",
         "build's. Nothing was written; run the trace again against the ",
         "finished build.", call. = FALSE)

  utils::write.csv(summary, file.path(out_dir, "returns_trace_summary.csv"), row.names = FALSE)
  utils::write.csv(cands_out, file.path(out_dir, "returns_trace_candidates.csv"), row.names = FALSE)
  utils::write.csv(lines_out, file.path(out_dir, "returns_trace_lines.csv"), row.names = FALSE)
  utils::write.csv(eps_out, file.path(out_dir, "returns_trace_episodes.csv"), row.names = FALSE)
  md <- return_trace_markdown(run_id, pfx, p, summary, sections, masked,
                              kinds = kinds, lines = lines_in,
                              n_candidates = n_scope_patients, n_traced = length(ids),
                              listed = !is.null(listed))
  if (nzchar(devs))
    md <- append(md, c(paste0("**Not a contract build.** `", devs, "`."), ""), after = 2L)
  writeLines(md, file.path(out_dir, "returns_trace.md"))
  cat("Wrote ", out_dir, ".\n", sep = "")
}

if (!interactive()) {
  out <- tryCatch(main(), error = function(e) e)
  if (inherits(out, "error")) {
    cat("\nERROR: ", conditionMessage(out), "\n", sep = "")
    quit(status = 1L)
  }
}
