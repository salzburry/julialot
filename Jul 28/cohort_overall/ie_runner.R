# =============================================================================
# ie_runner.R -- bootstrap, connect, build, report
# -----------------------------------------------------------------------------
# No IE logic. The criteria are in steps/, the funnel in ie_criteria.R, the
# counting in ie_attrition.R.
#
# Three modes:
#   --funnel    print the funnel and stop   (no connection)
#   --dry-run   print the SQL and stop      (no connection)
#   (none)      build
#
# An earlier version also had --views, --no-persist and --attrition-only. All
# three could report success having done nothing, so they are gone. Every step is
# a table, so a failed build leaves its finished tables behind and is re-run from
# the top.
#
# Connection, retry, logging and the code-list loader come from ../lib/db_utils.R
# -- inside the folder that ships.
# =============================================================================

ie_bootstrap <- function(here) {
  for (f in c("ie_config.R", "ie_criteria.R", "ie_attrition.R"))
    source(file.path(here, f))
  ie_load_steps(file.path(here, "steps"))
  invisible(here)
}

# db_utils.R needs glue, so it is loaded only for a real run. --dry-run and
# --funnel work on a machine with nothing installed.
ie_load_plumbing <- function(cfg) {
  f <- file.path(cfg$lib, "db_utils.R")
  if (!file.exists(f)) stop("cannot find ", f, call. = FALSE)
  source(f)
  invisible(TRUE)
}

ie_connect <- function(cfg) {
  fn <- Sys.getenv("IE_CONNECT_FN", unset = "")
  if (nzchar(fn)) {
    if (!exists(fn, mode = "function"))
      stop("IE_CONNECT_FN='", fn, "' is not a function in this session.",
           call. = FALSE)
    return(get(fn, mode = "function")(cfg))
  }
  if (!nzchar(cfg$pwd))
    stop("DATABRICKS_PWD is not set. It stays out of pipeline_inputs.csv by ",
         "design -- export it, or use --dry-run.", call. = FALSE)
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
    stop("unknown option(s): ", paste(bad, collapse = ", "), ". Takes ",
         paste(known, collapse = " / "), ", or nothing to build.",
         call. = FALSE)
  list(funnel_only = "--funnel" %in% argv, dry_run = "--dry-run" %in% argv)
}

ie_print_sql <- function(funnel) {
  cfg <- funnel$cfg; h <- funnel$h; vs <- funnel$views
  for (i in seq_along(vs)) {
    v <- vs[[i]]
    cat("\n", strrep("-", 78), "\n", sep = "")
    cat("-- [", i, "/", length(vs), "] ", h$work(v$name), "  --  ",
        v$description, "\n", sep = "")
    if (!is.na(v$legacy))
      cat("-- from pipeline_steps.R step ", v$legacy, "\n", sep = "")
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

# One table per step, in build order. A failed step stops the run.
ie_execute <- function(con, funnel) {
  cfg <- funnel$cfg; h <- funnel$h
  conn <- new.env(); conn$con <- con
  for (i in seq_along(funnel$views)) {
    v <- funnel$views[[i]]
    with_retry(function() {
      run_step(v$name, ie_stmt(v, cfg, h), conn = conn, cfg = cfg,
               qc_sql = v$qc, description = v$description,
               step_num = i, total_steps = length(funnel$views),
               source_tables = v$source_tables)
    }, max_retries = cfg$max_retries, base_sleep = cfg$base_sleep)
    # Diagnostics the legacy QC does not ask for. Non-fatal.
    if (!is.null(v$qc_extra)) {
      d <- tryCatch(DBI::dbGetQuery(conn$con, v$qc_extra),
                    error = function(e) NULL)
      if (!is.null(d) && nrow(d))
        log_msg("  >> ", paste(names(d), unlist(d[1, ]), sep = "=",
                               collapse = "  "))
    }
  }
  invisible(conn$con)
}

ie_main <- function(here, argv = commandArgs(trailingOnly = TRUE)) {
  args <- ie_parse_args(argv)
  ie_bootstrap(here)
  cfg <- ie_cfg(here)
  funnel <- ie_funnel(cfg)
  ie_print_funnel(funnel)

  if (isTRUE(args$funnel_only)) return(invisible(funnel))
  if (isTRUE(args$dry_run)) { ie_print_sql(funnel); return(invisible(funnel)) }

  if (!requireNamespace("DBI", quietly = TRUE))
    stop("DBI is required to build. Use --dry-run to see the SQL.",
         call. = FALSE)
  ie_load_plumbing(cfg)
  con <- ie_connect(cfg)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  log_msg("writing to schema ", cfg$out_schema,
          if (identical(cfg$out_schema, cfg$personal_schema))
            " (personal)" else " (work; DOMINO_USER_NAME not set)")
  conn <- new.env(); conn$con <- con
  load_csv_codelists(conn, cfg)
  ie_execute(con, funnel)

  rows <- ie_attrition_rows(con, funnel)
  ie_print_attrition(rows, cfg)
  ie_persist_attrition(con, rows, funnel)
  bad <- ie_print_reconcile(
    ie_reconcile(con, funnel, attr(rows, "cum_where")), funnel)

  # Name the table and the count, so "built" cannot be printed over a run that
  # produced nothing.
  n <- tryCatch(DBI::dbGetQuery(con, paste0(
    "SELECT count(*) AS n FROM ", funnel$h$work(cfg$final_table_name)))$n[1],
    error = function(e) NA)
  log_msg("cohort -> ", funnel$h$work(cfg$final_table_name), " (",
          if (is.na(n)) "COUNT FAILED" else format(n, big.mark = ","),
          " patients)")
  if (isTRUE(bad > 0L))
    stop("reconciliation failed -- see above. Do not use these numbers.",
         call. = FALSE)
  invisible(funnel)
}
