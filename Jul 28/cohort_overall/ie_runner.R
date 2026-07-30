# =============================================================================
# ie_runner.R -- bootstrap, connect, build, report
# -----------------------------------------------------------------------------
# No IE logic. The criteria are in steps/, the funnel in ie_criteria.R, the
# counting in ie_attrition.R.
#
# One job: build the cohort. It prints the funnel it is about to run, then runs
# it. The offline test suite exercises the SQL without a warehouse.
#
# The build has been run many times against the same personal schema, so it
# writes a RUN_STATUS row, stages the final cohort and publishes it only after
# reconciliation, and drops intermediates on success. See ie_attrition.R.
# =============================================================================

ie_bootstrap <- function(here) {
  for (f in c("ie_config.R", "ie_criteria.R", "ie_codelists.R", "ie_attrition.R"))
    source(file.path(here, f))
  ie_load_steps(file.path(here, "steps"))
  invisible(here)
}

# db_utils.R supplies connect, retry, logging and run_step. It calls glue()
# only inside the CSV loader and the view materialiser, neither of which this
# build uses -- code lists load through ie_codelists.R -- so glue is not a
# dependency here.
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
         "design -- export it before running.", call. = FALSE)
  with_retry(function() {
    con <- connect_databricks(cfg)
    log_msg("Connected to Databricks (DSN ", cfg$dsn, ")")
    con
  }, max_retries = cfg$max_retries, base_sleep = cfg$base_sleep)
}

# One table per step, in build order. A failed step stops the run. conn is a
# mutable env: run_step replaces conn$con if it has to reconnect, so the caller
# reads conn$con afterwards to get the live handle.
ie_execute <- function(conn, funnel) {
  cfg <- funnel$cfg; h <- funnel$h
  for (i in seq_along(funnel$views)) {
    v <- funnel$views[[i]]
    with_retry(function() {
      run_step(v$name, ie_stmt(v, cfg, h), conn = conn, cfg = cfg,
               qc_sql = v$qc, description = v$description,
               step_num = i, total_steps = length(funnel$views),
               source_tables = v$source_tables)
    }, max_retries = cfg$max_retries, base_sleep = cfg$base_sleep)
    if (!is.null(v$qc_extra)) {
      d <- tryCatch(DBI::dbGetQuery(conn$con, v$qc_extra),
                    error = function(e) NULL)
      if (!is.null(d) && nrow(d))
        log_msg("  >> ", paste(names(d), unlist(d[1, ]), sep = "=",
                               collapse = "  "))
    }
  }
  invisible(conn)
}

ie_main <- function(here, argv = commandArgs(trailingOnly = TRUE)) {
  bad <- grep("^--", argv, value = TRUE)
  if (length(bad))
    stop("this builder takes no options (got ", paste(bad, collapse = ", "),
         "). Just run it to build.", call. = FALSE)
  ie_bootstrap(here)
  cfg <- ie_cfg(here)
  funnel <- ie_funnel(cfg)
  ie_print_funnel(funnel)

  if (!requireNamespace("DBI", quietly = TRUE))
    stop("DBI is required to build.", call. = FALSE)
  ie_require_output(cfg)   # fail before connecting if the schema is wrong
  ie_load_plumbing(cfg)

  # One mutable connection env for the whole run. run_step may reconnect and
  # replace conn$con; everything downstream reads conn$con, and on.exit closes
  # whatever is current -- not a handle captured before a reconnect.
  conn <- new.env(); conn$con <- ie_connect(cfg)
  on.exit(try(DBI::dbDisconnect(conn$con), silent = TRUE), add = TRUE)

  log_msg("writing to ", cfg$catalog, ".", cfg$out_schema)
  run_id  <- ie_run_id()
  started <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")
  ie_write_status(conn$con, funnel, run_id, "started", started = started)

  ie_load_codelists(conn$con, cfg, funnel$h)
  ie_execute(conn, funnel)

  rows <- ie_attrition_rows(conn$con, funnel)
  ie_print_attrition(rows, cfg)

  # Reconcile the staged cohort before anything is published.
  stg <- paste0(funnel$h$work(cfg$final_table_name), "__stg")
  bad <- ie_print_reconcile(
    ie_reconcile(conn$con, funnel, attr(rows, "cum_where"), final_tbl = stg),
    funnel)
  if (isTRUE(bad > 0L)) {
    ie_write_status(conn$con, funnel, run_id, "reconcile_failed",
                    started = started)
    stop("reconciliation failed -- see above. Nothing was published: ",
         funnel$h$work(cfg$final_table_name), " and the attrition table still ",
         "hold the previous build. Do not use these numbers.", call. = FALSE)
  }

  # Publish the cohort and the attrition table together, so the two always come
  # from the same run.
  ie_publish_final(conn$con, funnel)
  ie_persist_attrition(conn$con, rows, funnel)

  n <- DBI::dbGetQuery(conn$con, paste0(
    "SELECT count(*) AS n FROM ", funnel$h$work(cfg$final_table_name)))$n[1]
  ie_cleanup_intermediates(conn$con, funnel)
  ie_write_status(conn$con, funnel, run_id, "complete", n_final = n,
                  started = started)

  log_msg("cohort -> ", funnel$h$work(cfg$final_table_name), " (",
          format(n, big.mark = ","), " patients, run_id ", run_id, ")")
  invisible(funnel)
}
