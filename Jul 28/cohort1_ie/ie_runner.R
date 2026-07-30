# =============================================================================
# ie_runner.R -- execution: bootstrap, connect, run, report
# -----------------------------------------------------------------------------
# No IE logic in this file. The criteria are in steps/, the funnel in
# ie_criteria.R, the counting in ie_attrition.R. This is the part that talks to
# the warehouse.
#
# WHAT IS BORROWED RATHER THAN COPIED
# The connection, retry, logging, checkpoint-materialisation and CSV code-list
# loader all come from apr_30_2026/R/db_utils.R, sourced read-only. That is
# plumbing, not study definition: copying it would create a second thing to keep
# in step for no benefit, and the reason this folder exists is that the CRITERIA
# should be runnable on their own -- not that the ODBC boilerplate should be.
#
# COHORT_CONNECT_FN / IE_CONNECT_FN names a function already defined in the
# session to connect differently; you get a clear error if it is not there,
# rather than a fallback that quietly connects somewhere else.
# =============================================================================

# Checkpoints. These three views are scanned repeatedly by everything after them,
# so they are materialized to real tables and the temp view is repointed at the
# table. Same three the legacy pipeline checkpoints, for the same reason. Names
# are prefixed, so they cannot overwrite the legacy pipeline's checkpoints.
IE_CHECKPOINTS <- c("mm_dx_events_all", "mm_qualifying")

ie_bootstrap <- function(here) {
  for (f in c("ie_config.R", "ie_criteria.R", "ie_attrition.R"))
    source(file.path(here, f))
  ie_load_steps(file.path(here, "steps"))
  invisible(here)
}

# db_utils.R needs glue; it is only loaded for a real run, so --dry-run works on
# a machine with nothing installed.
ie_load_plumbing <- function(cfg) {
  f <- file.path(cfg$apr_dir, "R", "db_utils.R")
  if (!file.exists(f))
    stop("cannot find ", f, " -- it supplies the connection and retry helpers.",
         call. = FALSE)
  source(f)
  invisible(TRUE)
}

ie_connect <- function(cfg) {
  fn <- Sys.getenv("IE_CONNECT_FN", unset = Sys.getenv("COHORT_CONNECT_FN", unset = ""))
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
  get1 <- function(flag, default) {
    hit <- grep(paste0("^", flag, "="), argv, value = TRUE)
    if (length(hit)) sub(paste0("^", flag, "="), "", hit[1]) else default
  }
  list(dry_run        = "--dry-run"        %in% argv,
       funnel_only    = "--funnel"         %in% argv,
       attrition_only = "--attrition-only" %in% argv,
       no_persist     = "--no-persist"     %in% argv,
       no_attrition   = "--no-attrition"   %in% argv,
       views          = { v <- get1("--views", "")
                          if (nzchar(v)) trimws(strsplit(v, ",", fixed = TRUE)[[1]])
                          else character(0) })
}

# ---- dry run ----------------------------------------------------------------
ie_print_sql <- function(funnel, only = character(0)) {
  vs <- funnel$views
  if (length(only)) {
    bad <- setdiff(only, vapply(vs, function(v) v$name, character(1)))
    if (length(bad))
      stop("unknown view(s): ", paste(bad, collapse = ", "), call. = FALSE)
    vs <- Filter(function(v) v$name %in% only, vs)
  }
  for (i in seq_along(vs)) {
    v <- vs[[i]]
    cat("\n", strrep("-", 78), "\n", sep = "")
    cat("-- [", i, "/", length(vs), "] ", v$name, "  --  ", v$description,
        "\n", sep = "")
    if (!is.na(v$legacy))
      cat("-- reproduces pipeline_steps.R step ", v$legacy, "\n", sep = "")
    if (length(v$source_tables))
      cat("-- reads: ", paste(v$source_tables, collapse = ", "), "\n", sep = "")
    cat(strrep("-", 78), "\n", sep = "")
    cat(trimws(v$sql), ";\n", sep = "")
  }
  cat("\n", strrep("=", 78), "\n", sep = "")
  cat("  ", length(vs), " statement(s). Nothing was executed.\n", sep = "")
  cat(strrep("=", 78), "\n", sep = "")
  invisible(vs)
}

# ---- real run ---------------------------------------------------------------
ie_execute <- function(con, funnel, args) {
  cfg <- funnel$cfg
  conn <- new.env(); conn$con <- con
  mat_tables <- new.env()
  vs <- funnel$views
  if (length(args$views))
    vs <- Filter(function(v) v$name %in% args$views, vs)
  if (isTRUE(args$no_persist))
    vs <- Filter(function(v) !startsWith(v$name, "persist_"), vs)

  for (i in seq_along(vs)) {
    v <- vs[[i]]
    is_ckpt <- v$name %in% IE_CHECKPOINTS ||
               identical(v$name, cfg$flags_view)
    with_retry(function() {
      run_step(v$name, v$sql, conn = conn, cfg = cfg,
               qc_sql = if (is_ckpt) NULL else v$qc,
               description = v$description,
               step_num = i, total_steps = length(vs),
               source_tables = v$source_tables)
    }, max_retries = cfg$max_retries, base_sleep = cfg$base_sleep)

    # Checkpoint: materialize, then QC the cheap table instead of recomputing the
    # heavy view. A materialization failure is fatal -- silently falling back to
    # recomputing the view is how a run takes hours and nobody knows why.
    if (is_ckpt) {
      ok <- materialize_to_personal_schema(conn$con, v$name, cfg, mat_tables,
                                           replace = TRUE)
      if (nzchar(cfg$personal_schema) && !isTRUE(ok))
        stop("checkpoint '", v$name, "' failed to materialize to '",
             cfg$personal_schema, "'. See the WARN above.", call. = FALSE)
      with_retry(function() run_qc(conn$con, v$qc),
                 max_retries = cfg$max_retries, base_sleep = cfg$base_sleep)
    }
  }
  invisible(conn$con)
}

# Probe that a temp view exists before counting off it. LIMIT 0 so nothing is
# scanned -- this is a name resolution check, not a read.
ie_require_views <- function(con, funnel, names) {
  missing <- character(0)
  for (n in names) {
    obj <- funnel$h$work(n)
    ok <- tryCatch({ DBI::dbGetQuery(con, paste0("SELECT * FROM ", obj,
                                                 " LIMIT 0")); TRUE },
                   error = function(e) FALSE)
    if (!ok) missing <- c(missing, obj)
  }
  if (length(missing))
    stop("these views do not exist in this session: ",
         paste(missing, collapse = ", "),
         ". They are TEMPORARY views, so they died with the session that built ",
         "them. Run the build without --attrition-only.", call. = FALSE)
  invisible(TRUE)
}

# ---- entry point ------------------------------------------------------------
ie_main <- function(here, argv = commandArgs(trailingOnly = TRUE)) {
  args <- ie_parse_args(argv)
  ie_bootstrap(here)
  cfg <- ie_cfg(here)
  funnel <- ie_funnel(cfg)
  ie_print_funnel(funnel)

  if (isTRUE(args$funnel_only)) return(invisible(funnel))
  if (isTRUE(args$dry_run)) {
    ie_print_sql(funnel, args$views)
    return(invisible(funnel))
  }

  if (!requireNamespace("DBI", quietly = TRUE))
    stop("DBI is required for a real run. Use --dry-run to emit the SQL.",
         call. = FALSE)
  ie_load_plumbing(cfg)
  con <- ie_connect(cfg)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  if (!isTRUE(args$attrition_only)) {
    conn <- new.env(); conn$con <- con
    load_csv_codelists(conn, cfg)
    ie_execute(con, funnel, args)
    log_msg("cohort 1 built: ", cfg$ie_final_table)
  } else {
    # The attrition table is counted off temp views. Those live in the session
    # that made them, so --attrition-only only works in a session that already
    # built the cohort. Check rather than let the counts fail one query in.
    ie_require_views(con, funnel, c(cfg$flags_view, "mm_dx_events_id"))
    log_msg("--attrition-only: counting off the views already in this session")
  }

  if (!isTRUE(args$no_attrition)) {
    rows <- ie_attrition_rows(con, funnel)
    ie_print_attrition(rows, cfg)
    ie_export_attrition_csv(rows)
    if (isTRUE(cfg$persist_to_schema) && !isTRUE(args$no_persist))
      ie_persist_attrition(con, rows, funnel)
  }
  invisible(funnel)
}
