#!/usr/bin/env Rscript
# Trace the fold-in rule (LOT_RULES.md 4.8) through real patients of a
# finished LOT run.
#
#   # list what it would do; no connection
#   Rscript lot/qc/trace_foldin.R
#
#   # run it
#   DATABRICKS_PWD=... DOMINO_USER_NAME=usr00000 OBJECT_PREFIX=ndmm_ \
#     TRACE_EXECUTE=TRUE Rscript lot/qc/trace_foldin.R
#
# Reads only. The traces land in out/: foldin_trace.md, and the same rows as
# foldin_trace_lines.csv, foldin_trace_episodes.csv, foldin_trace_summary.csv.
#
# The study team asked to look at patients the fold-in rule touched - a drug of
# the immediately previous line that came back after exactly one other agent
# opened a line, and joined that line's regimen instead of ending it - with
# their raw MAP episodes beside the final lines. Not a check: nothing here
# passes or fails. R/foldin_trace.R says how a fold is recognised in the
# published tables, since the engine keeps no flag.
#
#   TRACE_N            how many patients to trace (default 10), sampled
#                      round-robin over (line, drug) so the ten show a spread
#   TRACE_PATIDS       comma-separated ids to trace instead of sampling. A
#                      listed patient with no fold is reported as such.
#   TRACE_MASK_PATID   TRUE masks ids to their last six characters. Off by
#                      default: the trace exists so a patient can be looked up.
#   QC_ALLOW_DEVIATION TRUE traces a run that deviated from the contract.
#
# Exit status is 0 when the trace was written, 1 when something stopped it.

.script_dir <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  # Rscript renders a space in a path as ~+~, so a folder with one in its name
  # resolves to nothing without this.
  if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                            fixed = TRUE))) else getwd()
})
source(file.path(.script_dir, "R", "checks.R"))
source(file.path(.script_dir, "R", "foldin_trace.R"))

LOT_ROOT <- normalizePath(file.path(.script_dir, "..", "engine"), mustWork = TRUE)
out_dir  <- file.path(.script_dir, "out")
env_flag <- function(nm) identical(toupper(trimws(Sys.getenv(nm, unset = ""))), "TRUE")

trace_n <- function() {
  raw <- trimws(Sys.getenv("TRACE_N", unset = "10"))
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

report_plan <- function() {
  cat("\nFold-in trace on a finished LOT run.\n\n")
  # A refused list or count is printed here, not swallowed: the plan is what
  # an operator checks before the run, and a plan that shows a sample for a
  # list the run will then refuse is a plan for a different run.
  listed <- tryCatch(trace_patids(), error = function(e) {
    cat("  TRACE_PATIDS refused: ", conditionMessage(e), "\n", sep = ""); NULL })
  n_txt <- tryCatch(as.character(trace_n()), error = function(e) {
    cat("  TRACE_N refused: ", conditionMessage(e), "\n", sep = ""); "?" })
  cat("  reads   LOT_LONG_FINAL, MAP_STACKED, TX_ALLO_CART_DATES, TX_AUTO_DATES,\n",
      "         PERMISSIBLE_SUBS, LOT_RUN_METADATA, LOT_BUILD_STATUS under OBJECT_PREFIX\n",
      "  finds   every (patient, line, drug) carrying the fold's signature:\n",
      "         a regimen drug of line n that line n-1 carried, with no episode\n",
      "         inside line n's induction window and one inside the line after it\n",
      "  writes  ", file.path(out_dir, "foldin_trace.md"), "\n",
      "          and foldin_trace_lines.csv, foldin_trace_episodes.csv,\n",
      "          foldin_trace_summary.csv beside it\n", sep = "")
  cat("  traces  ",
      if (!is.null(listed)) paste0(length(listed), " listed patient(s) (TRACE_PATIDS)")
      else paste0(n_txt, " patients, round-robin over (line, drug) (TRACE_N)"), "\n", sep = "")
  cat("  ids     ", if (env_flag("TRACE_MASK_PATID")) "masked (TRACE_MASK_PATID)"
                    else "unmasked, so the patients can be looked up", "\n", sep = "")
}

main <- function() {
  report_plan()
  if (!env_flag("TRACE_EXECUTE")) {
    cat("\nNothing was read. Set TRACE_EXECUTE=TRUE to run it.\n")
    return(invisible(NULL))
  }

  # Counts go to the console and to CSV as numbers, and a round total such as
  # 100000 lines would print as 1e+05 without this. Same hazard sql_count()
  # in the engine's db_utils_lot.R notes.
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

  # The prefix names WHICH run is being traced. Blank would ask for unprefixed
  # tables and trace whatever happens to be there.
  pfx <- trimws(Sys.getenv("OBJECT_PREFIX", unset = ""))
  if (!nzchar(pfx))
    stop("No OBJECT_PREFIX. It is what names the run's tables, so without it ",
         "this would trace whatever unprefixed tables exist.", call. = FALSE)
  if (!grepl("^[A-Za-z][A-Za-z0-9_]*_$", pfx))
    stop("OBJECT_PREFIX '", pfx, "' should be a name ending in '_'.", call. = FALSE)
  cfg$object_prefix <- pfx

  # No cohort table: nothing here reads observation windows or death dates,
  # so unlike run_lot_qc.R it is not asked for.
  n_want <- trace_n()
  listed <- trace_patids()
  masked <- env_flag("TRACE_MASK_PATID")

  set_lot_config(cfg)
  dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
  stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")
  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  t <- list(final = lot_out("LOT_LONG_FINAL"),
            map   = lot_out("MAP_STACKED"),
            # The allogeneic and CAR-T dates bound the window - a transplant
            # cuts it - and both transplant tables are shown in the trace so a
            # reader sees what opened each line.
            allo  = lot_out("TX_ALLO_CART_DATES"),
            auto  = lot_out("TX_AUTO_DATES"),
            # Which drugs are one agent. The previous line carrying a drug's
            # substitute is the previous line carrying the drug (4.4).
            subs  = lot_out("PERMISSIBLE_SUBS"),
            meta  = lot_out("LOT_RUN_METADATA"))

  # Which run owns the prefix: the latest status row, the same answer every
  # other reader in this folder resolves. UPDATED_AT is kept as well as the id,
  # because the id alone does not identify a build - the engine keeps one run
  # id for a session, so a rebuild can leave a second complete row under it.
  # The whole pin (foldin_trace_build_pin) is asked again after the reads.
  status_row <- function()
    db_q(con, glue("
      SELECT RUN_ID, STATE, UPDATED_AT, CONTRACT_DEVIATIONS
      FROM {lot_out('LOT_BUILD_STATUS')}
      ORDER BY UPDATED_AT DESC LIMIT 1"))
  build_pin <- foldin_trace_build_pin
  st <- status_row()
  if (!nrow(st))
    stop("No row in ", lot_out("LOT_BUILD_STATUS"), ", so there is no run to ",
         "trace under prefix '", pfx, "'.", call. = FALSE)
  run_id <- as.character(st$RUN_ID[1])
  status <- as.character(st$STATE[1])
  devs   <- trimws(as.character(st$CONTRACT_DEVIATIONS[1] %||% ""))
  pinned <- build_pin(st)

  if (!identical(status, "complete"))
    stop("The run owning this prefix is '", status, "', not complete. Its ",
         "tables are whatever the failed attempt left behind, so a trace over ",
         "them would describe a partial build.", call. = FALSE)

  # A deviating run is a different algorithm. Tracing one can be a reasonable
  # thing to want, so it is allowed - but it has to be asked for, and the
  # report says which run it was.
  if (nzchar(devs) && !env_flag("QC_ALLOW_DEVIATION"))
    stop("This run is not a contract build: ", devs, ". Set ",
         "QC_ALLOW_DEVIATION=TRUE to trace it anyway - the report will carry ",
         "the deviation.", call. = FALSE)

  meta <- db_q(con, glue("
    SELECT CONTRACT_SETTINGS FROM {t$meta} WHERE RUN_ID = '{run_id}'"))
  if (!nrow(meta))
    stop("No LOT_RUN_METADATA row for run ", run_id, ". Without it there is no ",
         "record of which windows the run used, and the fold's signature is ",
         "read against the window.", call. = FALSE)
  settings <- as.character(meta$CONTRACT_SETTINGS[1])
  p <- qc_params(settings, run_id)

  # Without the rule there is nothing to trace: the signature this reads
  # cannot occur in a build that did not fold, and a query that found rows in
  # one would be reporting a defect, which is C1's job.
  if (!isTRUE(p$foldin))
    stop("Run ", run_id, " did not apply the fold-in (apply_map_foldin is not ",
         "TRUE in its CONTRACT_SETTINGS), so there is nothing to trace.",
         call. = FALSE)

  cat("\nRun ", run_id, " under prefix ", pfx, "\n", sep = "")
  cat("  windows: LOT1 ", p$ind1, "d, later lines ", p$indn, "d, CAR-T ", p$cart,
      "d\n", sep = "")
  if (nzchar(devs)) cat("  NOT A CONTRACT BUILD: ", devs, "\n", sep = "")

  totals <- db_q(con, foldin_trace_totals_sql(t))
  cands  <- db_q(con, foldin_trace_sql(t, p))
  subs   <- db_q(con, foldin_trace_subs_sql(t))
  n_cand_patients <- length(unique(as.character(cands$PATID)))
  fmt <- function(x) format(x, scientific = FALSE, trim = TRUE)
  cat("  ", nrow(cands), " fold(s) over ", n_cand_patients, " patient(s), in a table of ",
      fmt(totals$N_PATIENTS[1]), " patients and ", fmt(totals$N_LINES[1]), " lines\n", sep = "")
  # The signature on a line a transplant or CAR-T opened is a defect, not the
  # rule (R/foldin_trace.R, foldin_trace_sql). It is traced like the rest so
  # the reader sees it, and said here so it is not read as the rule at work.
  n_odd <- sum(!is.na(cands$LOT_START_TYPE) & as.character(cands$LOT_START_TYPE) != "MED")
  if (n_odd > 0L)
    cat("  ", n_odd, " of them sit on a line a transplant or CAR-T opened: 4.8 ",
        "refuses a fold there, so these are build defects to raise, not folds\n", sep = "")

  summary <- foldin_trace_summary(cands, totals$N_PATIENTS[1], totals$N_LINES[1])

  # Who gets traced. Never a silent truncation: the console says how many
  # there were and how many are in the file.
  ids <- foldin_trace_sample(cands, n_want, listed)
  if (!is.null(listed)) {
    cat("  tracing ", length(ids), " listed patient(s); ",
        sum(ids %in% cands$PATID), " of them carry a fold\n", sep = "")
  } else {
    cat("  tracing ", length(ids), " of ", n_cand_patients, " patient(s) with a fold",
        if (n_cand_patients > length(ids)) paste0(" (TRACE_N=", n_want, ")") else "",
        "\n", sep = "")
  }

  sections <- list()
  lines_out <- NULL; eps_out <- NULL
  if (length(ids)) {
    lines <- db_q(con, foldin_trace_lines_sql(t, ids, p))
    eps   <- db_q(con, foldin_trace_episodes_sql(t, ids))
    tx    <- foldin_trace_tx_read(con, t, ids)
    # The folds of the traced patients, and every one of each patient's folds:
    # a paragraph has to know whether its return is the patient's first. The
    # full frame stays as it is for the counts and the sample, which are
    # population questions. Narrowed here because the annotation asks the fold
    # set once per episode.
    folds <- cands[as.character(cands$PATID) %in% ids, , drop = FALSE]
    ann   <- foldin_trace_annotate(lines, eps, tx, folds, p, subs = subs)
    for (id in ids) {
      folds_p <- folds[as.character(folds$PATID) == id, , drop = FALSE]
      lines_p <- lines[as.character(lines$PATID) == id, , drop = FALSE]
      eps_p   <- eps[as.character(eps$PATID) == id, , drop = FALSE]
      tx_p    <- tx[as.character(tx$PATID) == id, , drop = FALSE]
      ann_p   <- ann[as.character(ann$PATID) == id, , drop = FALSE]
      shown   <- if (masked) mask_patid_r(id) else id
      sections[[length(sections) + 1L]] <-
        foldin_trace_patient_md(shown, folds_p, lines_p, eps_p, ann_p, p,
                                tx_p = tx_p, subs = subs)
    }
    lines_out <- lines[, c("PATID", TRACE_LINE_COLS), drop = FALSE]
    eps_out   <- ann[, c("PATID", TRACE_EPISODE_COLS), drop = FALSE]
    if (masked) {
      lines_out$PATID <- mask_patid_r(lines_out$PATID)
      eps_out$PATID   <- mask_patid_r(eps_out$PATID)
    }
  } else {
    cat("  no patient to trace: the rule touched nobody in this run\n")
    lines_out <- data.frame(PATID = character(0))
    eps_out   <- data.frame(PATID = character(0))
  }

  # Still the same build. A rebuild under this prefix during the reads would
  # have replaced what the later ones returned, and the report would name the
  # pinned run while showing another build's lines. The whole pin is compared
  # rather than the id, which is reused by design, and it is compared before
  # anything is written, so a run that lost its build leaves the previous trace
  # on disk rather than half-replacing it.
  now <- build_pin(status_row())
  if (!identical(now, pinned))
    stop("The run under prefix '", pfx, "' changed while its tables were being ",
         "read (", pinned, " -> ", now, "), so what was read is not one ",
         "build's. Nothing was written; run the trace again against the ",
         "finished build.", call. = FALSE)

  utils::write.csv(summary, file.path(out_dir, "foldin_trace_summary.csv"), row.names = FALSE)
  utils::write.csv(lines_out, file.path(out_dir, "foldin_trace_lines.csv"), row.names = FALSE)
  utils::write.csv(eps_out, file.path(out_dir, "foldin_trace_episodes.csv"), row.names = FALSE)
  md <- foldin_trace_markdown(run_id, pfx, p, summary, sections, masked,
                              n_candidates = n_cand_patients, n_traced = length(ids),
                              listed = !is.null(listed))
  if (nzchar(devs))
    md <- append(md, c(paste0("**Not a contract build.** `", devs, "`."), ""), after = 2L)
  writeLines(md, file.path(out_dir, "foldin_trace.md"))
  cat("Wrote ", out_dir, ".\n", sep = "")
}

if (!interactive()) {
  out <- tryCatch(main(), error = function(e) e)
  if (inherits(out, "error")) {
    cat("\nERROR: ", conditionMessage(out), "\n", sep = "")
    quit(status = 1L)
  }
}
