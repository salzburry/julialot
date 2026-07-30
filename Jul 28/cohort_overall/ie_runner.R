# =============================================================================
# ie_runner.R -- execution: bootstrap, connect, build, report
# -----------------------------------------------------------------------------
# No IE logic here. The criteria are in steps/, the funnel in ie_criteria.R, the
# counting and reconciliation in ie_attrition.R.
#
# TWO MODES, AND THAT IS DELIBERATE
#   --funnel    print the funnel and stop      (no connection)
#   --dry-run   print every statement and stop (no connection)
#   (neither)   build
#
# An earlier revision also offered --views, --no-persist and --attrition-only.
# All three were removed: --no-persist could not do what it said (checkpoint
# materialisation still wrote tables), --views rejected unknown names in dry-run
# but silently ran nothing in a real run, and --attrition-only depended on
# temporary views that no fresh Rscript session can have. Each added a way to
# report success having done nothing. Every step is a table now, so a failed build
# leaves its completed tables behind for inspection and is simply re-run.
#
# WHERE THE PLUMBING COMES FROM
# Connection, retry, logging and the CSV code-list loader come from
# ../lib/db_utils.R -- inside the folder that ships, a verbatim copy of
# apr_30_2026/R/db_utils.R with byte-identity asserted while that folder is still
# present. Nothing outside "Jul 28" is read at run time.
#
# Note what is NOT used from it: the view-to-table materializer. That helper takes
# a temporary view and turns it into a table, and there are no temporary views
# here -- every step is already a table. Calling it was the checkpoint-name bug.
#
# ---------------------------------------------------------------------------
# SITE-SPECIFIC TABLE CREATION
# ---------------------------------------------------------------------------
# By default a step runs as CREATE OR REPLACE TABLE <qualified name> AS <select>.
# If your site creates tables through a helper -- e.g. GSK Domino's
# personalSchemaFunctions.R, which 01_cohort.R sources from
# /mnt/code/R/helperScripts/databases/ -- set
#
#     IE_CREATE_TABLE_FN=<function name>
#
# to a function already defined in the session with the signature
#
#     f(con, table_name, select_sql) -> anything
#
# It is called instead of the plain CREATE. I could not read that helper (it is
# not in this repository and not on this machine), so its real signature is not
# assumed anywhere -- wire it up with a one-line adapter rather than editing this
# file.
# =============================================================================

ie_bootstrap <- function(here) {
  for (f in c("ie_config.R", "ie_criteria.R", "ie_attrition.R"))
    source(file.path(here, f))
  ie_load_steps(file.path(here, "steps"))
  invisible(here)
}

# db_utils.R needs glue; loaded only for a real run, so --dry-run and --funnel
# work on a machine with nothing installed.
ie_load_plumbing <- function(cfg) {
  f <- file.path(cfg$lib, "db_utils.R")
  if (!file.exists(f))
    stop("cannot find ", f, " -- it supplies the connection and retry helpers.",
         call. = FALSE)
  source(f)
  invisible(TRUE)
}

ie_connect <- function(cfg) {
  fn <- Sys.getenv("IE_CONNECT_FN",
                   unset = Sys.getenv("COHORT_CONNECT_FN", unset = ""))
  if (nzchar(fn)) {
    if (!exists(fn, mode = "function"))
      stop("IE_CONNECT_FN='", fn, "' is not a function defined in this session.",
           call. = FALSE)
    return(get(fn, mode = "function")(cfg))
  }
  if (!nzchar(cfg$pwd))
    stop("DATABRICKS_PWD is not set. It is deliberately not in ",
         "pipeline_inputs.csv -- export it, or use --dry-run to see the SQL ",
         "without connecting.", call. = FALSE)
  with_retry(function() {
    con <- connect_databricks(cfg)
    log_msg("Connected to Databricks (DSN ", cfg$dsn, ")")
    con
  }, max_retries = cfg$max_retries, base_sleep = cfg$base_sleep)
}

ie_parse_args <- function(argv = commandArgs(trailingOnly = TRUE)) {
  known <- c("--funnel", "--dry-run")
  bad <- setdiff(grep("^--", argv, value = TRUE), known)
  if (length(bad))
    stop("unknown option(s): ", paste(bad, collapse = ", "),
         ". This program takes ", paste(known, collapse = " / "),
         ", or no option to build.", call. = FALSE)
  list(funnel_only = "--funnel" %in% argv, dry_run = "--dry-run" %in% argv)
}

# ---- dry run ----------------------------------------------------------------
ie_print_sql <- function(funnel) {
  cfg <- funnel$cfg; h <- funnel$h; vs <- funnel$views
  for (i in seq_along(vs)) {
    v <- vs[[i]]
    cat("\n", strrep("-", 78), "\n", sep = "")
    cat("-- [", i, "/", length(vs), "] ", h$work(v$name), "  --  ",
        v$description, "\n", sep = "")
    if (!is.na(v$legacy))
      cat("-- reproduces pipeline_steps.R step ", v$legacy, "\n", sep = "")
    if (length(v$source_tables))
      cat("-- reads: ", paste(v$source_tables, collapse = ", "), "\n", sep = "")
    cat(strrep("-", 78), "\n", sep = "")
    cat(ie_stmt(v, cfg, h), ";\n", sep = "")
  }
  cat("\n", strrep("=", 78), "\n", sep = "")
  cat("  ", length(vs), " table(s) in ", h$out_schema(),
      ". Nothing was executed.\n", sep = "")
  cat("  cohort -> ", h$work(cfg$final_table_name), "\n", sep = "")
  cat(strrep("=", 78), "\n", sep = "")
  invisible(vs)
}

# ---- real run ---------------------------------------------------------------
# One table per step, in build order, all fatal on failure. There is no partial
# mode: a step that fails stops the run, and the tables built before it are
# already on disk.
ie_execute <- function(con, funnel) {
  cfg <- funnel$cfg; h <- funnel$h
  conn <- new.env(); conn$con <- con
  create_fn <- Sys.getenv("IE_CREATE_TABLE_FN", unset = "")
  if (nzchar(create_fn) && !exists(create_fn, mode = "function"))
    stop("IE_CREATE_TABLE_FN='", create_fn,
         "' is not a function defined in this session.", call. = FALSE)

  for (i in seq_along(funnel$views)) {
    v <- funnel$views[[i]]
    target <- h$work(v$name)
    if (nzchar(create_fn)) {
      log_msg("[", i, "/", length(funnel$views), "] ", v$description)
      log_msg("  >> ", create_fn, "(con, ", target, ", <select>)")
      with_retry(function() get(create_fn, mode = "function")(conn$con, target,
                                                             v$select),
                 max_retries = cfg$max_retries, base_sleep = cfg$base_sleep)
      with_retry(function() run_qc(conn$con, v$qc),
                 max_retries = cfg$max_retries, base_sleep = cfg$base_sleep)
    } else {
      with_retry(function() {
        run_step(v$name, ie_stmt(v, cfg, h), conn = conn, cfg = cfg,
                 qc_sql = v$qc, description = v$description,
                 step_num = i, total_steps = length(funnel$views),
                 source_tables = v$source_tables)
      }, max_retries = cfg$max_retries, base_sleep = cfg$base_sleep)
    }
    # Diagnostics that the legacy QC does not ask for. Non-fatal: they answer
    # questions about the data, they do not gate the build.
    if (!is.null(v$qc_extra)) {
      out <- tryCatch(DBI::dbGetQuery(conn$con, v$qc_extra),
                      error = function(e) NULL)
      if (!is.null(out) && nrow(out))
        log_msg("  >> diagnostics: ",
                paste(names(out), unlist(out[1, ]), sep = "=", collapse = "  "))
    }
  }
  invisible(conn$con)
}

# ---- entry point ------------------------------------------------------------
ie_main <- function(here, argv = commandArgs(trailingOnly = TRUE)) {
  args <- ie_parse_args(argv)
  ie_bootstrap(here)
  cfg <- ie_cfg(here)
  funnel <- ie_funnel(cfg)
  ie_print_funnel(funnel)

  if (isTRUE(args$funnel_only)) return(invisible(funnel))
  if (isTRUE(args$dry_run)) { ie_print_sql(funnel); return(invisible(funnel)) }

  if (!requireNamespace("DBI", quietly = TRUE))
    stop("DBI is required for a real run. Use --dry-run to emit the SQL.",
         call. = FALSE)
  ie_load_plumbing(cfg)
  con <- ie_connect(cfg)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  conn <- new.env(); conn$con <- con
  load_csv_codelists(conn, cfg)
  ie_execute(con, funnel)

  rows <- ie_attrition_rows(con, funnel)
  ie_print_attrition(rows, cfg)
  ie_export_attrition_csv(rows)
  ie_persist_attrition(con, rows, funnel)

  bad <- ie_print_reconcile(
    ie_reconcile(con, funnel, attr(rows, "cum_where")), funnel)

  # The completion message states the object and the number, so "built" cannot be
  # printed over a run that produced nothing.
  n <- tryCatch(DBI::dbGetQuery(con, paste0(
    "SELECT count(*) AS n FROM ", funnel$h$work(cfg$final_table_name)))$n[1],
    error = function(e) NA)
  log_msg("cohort 1 -> ", funnel$h$work(cfg$final_table_name), " (",
          if (is.na(n)) "COUNT FAILED" else format(n, big.mark = ","),
          " patients)")
  if (isTRUE(bad > 0L))
    stop("reconciliation failed -- see the table above. The cohort table does ",
         "not match the funnel, so do not use these numbers.", call. = FALSE)
  invisible(funnel)
}
