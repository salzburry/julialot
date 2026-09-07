# Connection, logging, naming and the step runner.
#
# Naming: everything this package writes is work schema + OBJECT_PREFIX +
# table, and it reads the cohort and the LOT tables by their own prefixes. Two
# runs on different prefixes sit side by side; two on the same prefix would
# overwrite each other, which is what check_no_active_run() is for.

SEP <- strrep("=", 70)

log_msg <- function(...) {
  a <- lapply(list(...), function(x)
    if (inherits(x, "integer64")) format(as.numeric(x), scientific = FALSE) else x)
  do.call(cat, c(list(sprintf("[%s] ", format(Sys.time(), "%Y-%m-%d %H:%M:%S"))),
                 a, "\n"))
  flush.console()
}

set_study_config <- function(x) { assign("cfg", x, envir = globalenv()); invisible(x) }
study_config <- function() {
  if (!exists("cfg", envir = globalenv()))
    stop("No config. build_223926() calls set_study_config() before any step.",
         call. = FALSE)
  get("cfg", envir = globalenv())
}

# A CDM table, with the quarterly suffix picked from STUDY_END - the same
# resolution the cohort build uses, so both read the same vintage.
quarter_suffix <- function(study_end) {
  d <- as.Date(study_end)
  sprintf("%sq%d", format(d, "%Y"), (as.integer(format(d, "%m")) - 1L) %/% 3L + 1L)
}
cdm_src <- function(base_tbl) {
  cfg <- study_config()
  nm <- if (isTRUE(cfg$use_quarterly_tables))
    paste0("t_", base_tbl, "_", quarter_suffix(cfg$study_end)) else base_tbl
  sprintf("%s.%s.%s", cfg$catalog, cfg$cdm_schema, nm)
}
# A table this run writes.
wrk <- function(base_tbl) {
  cfg <- study_config()
  sprintf("%s.%s.%s%s", cfg$catalog, cfg$work_schema, cfg$object_prefix, base_tbl)
}
# A table the cohort build wrote.
cohort_tbl <- function(base_tbl) {
  cfg <- study_config()
  p <- if (nzchar(cfg$cohort_prefix)) cfg$cohort_prefix else cfg$object_prefix
  sprintf("%s.%s.%s%s", cfg$catalog, cfg$work_schema, p, base_tbl)
}
# A table the LOT build wrote.
lot_tbl <- function(base_tbl) {
  cfg <- study_config()
  p <- if (nzchar(cfg$lot_prefix)) cfg$lot_prefix else cfg$object_prefix
  sprintf("%s.%s.%s%s", cfg$catalog, cfg$work_schema, p, base_tbl)
}

# Spark's sql() takes ONE statement. Several module templates are written as a
# CREATE TABLE IF NOT EXISTS followed by an INSERT, because that reads as one
# thing, so they are split here rather than in each module.
#
# Split on semicolons that are not inside a quoted string. The generated SQL
# has no semicolons inside literals today; the quote tracking is here so that a
# code list value containing one cannot quietly truncate a statement.
split_statements <- function(sql) {
  chars <- strsplit(sql, "", fixed = TRUE)[[1]]
  out <- character(0); cur <- character(0); inq <- FALSE
  i <- 1L
  while (i <= length(chars)) {
    ch <- chars[i]
    if (ch == "'") {
      # '' inside a quoted string is an escaped quote, not the end of one.
      if (inq && i < length(chars) && chars[i + 1L] == "'") {
        cur <- c(cur, ch, ch); i <- i + 2L; next
      }
      inq <- !inq
    }
    if (ch == ";" && !inq) {
      out <- c(out, paste(cur, collapse = "")); cur <- character(0)
    } else {
      cur <- c(cur, ch)
    }
    i <- i + 1L
  }
  out <- c(out, paste(cur, collapse = ""))
  out <- trimws(out)
  out[nzchar(out)]
}

with_retry <- function(fn, max_retries = study_config()$max_retries,
                       base_sleep = study_config()$base_sleep) {
  permanent <- c("AnalysisException", "TABLE_OR_VIEW_NOT_FOUND",
                 "Table or view not found", "ParseException", "Syntax error",
                 "AMBIGUOUS_REFERENCE", "UNRESOLVED_COLUMN")
  for (i in seq_len(max_retries + 1L)) {
    out <- tryCatch(fn(), error = function(e) e)
    if (!inherits(out, "error")) return(out)
    msg <- conditionMessage(out)
    if (any(vapply(permanent, function(p) grepl(p, msg, fixed = TRUE), logical(1))))
      stop(out)
    if (i > max_retries) stop(out)
    s <- base_sleep * 2^(i - 1L)
    log_msg("  retry ", i, "/", max_retries, " in ", s, "s: ",
            substr(msg, 1, 160))
    Sys.sleep(s)
  }
}

# Execute. Accepts one statement or several, in one string or a vector.
db_exec <- function(con, sql) {
  stmts <- unlist(lapply(sql, split_statements), use.names = FALSE)
  for (st in stmts)
    with_retry(function() sparklyr::invoke(sparklyr::spark_session(con), "sql", st))
  invisible(length(stmts))
}

# Query, collected to a local data frame. Small results only - every caller
# here is a count or a handful of rows.
db_q <- function(con, sql) {
  stmts <- split_statements(sql)
  if (length(stmts) != 1L)
    stop("QUERY ERROR: db_q() takes one statement, got ", length(stmts),
         ". Use db_exec() for DDL.", call. = FALSE)
  with_retry(function() sparklyr::sdf_collect(sparklyr::sdf_sql(con, stmts[1])))
}

# One named step: run it, then run its check. A step whose check comes back
# empty or zero-rowed is reported, not swallowed - an empty intermediate is how
# a cohort silently becomes nobody.
run_step <- function(con, name, sql, qc = NULL, allow_empty = FALSE) {
  log_msg("step ", name)
  db_exec(con, sql)
  if (is.null(qc)) return(invisible(NULL))
  res <- db_q(con, qc)
  log_msg("  ", name, ": ",
          paste(sprintf("%s=%s", names(res), vapply(res, function(x)
            format(x[1]), character(1))), collapse = ", "))
  n <- suppressWarnings(as.numeric(res[[1]][1]))
  if (!allow_empty && !is.na(n) && n == 0)
    stop("STEP ERROR: ", name, " produced 0 rows. Nothing downstream can tell ",
         "that from a real zero, so the run stops here.", call. = FALSE)
  invisible(res)
}

# The Spark connection.
#
#   databricks          running ON a Databricks cluster or notebook - the
#                       session already exists and sparklyr attaches to it.
#                       Nothing to authenticate.
#   databricks_connect  running outside it, against a named cluster. Needs
#                       DATABRICKS_HOST, DATABRICKS_TOKEN and SPARK_CLUSTER_ID.
#   local               a local Spark, for a smoke test over fixtures. It has
#                       no CDM, so only the framework can be exercised.
connect_db <- function(cfg) {
  if (!requireNamespace("sparklyr", quietly = TRUE))
    stop("CONNECTION ERROR: sparklyr is not installed.", call. = FALSE)
  sc <- switch(cfg$spark_method,
    databricks = sparklyr::spark_connect(method = "databricks"),
    databricks_connect = {
      for (nm in c("host", "token", "cluster_id"))
        if (!nzchar(cfg[[paste0("databricks_", nm)]]))
          stop("CONNECTION ERROR: SPARK_METHOD=databricks_connect needs ",
               toupper(paste0("databricks_", nm)), ".", call. = FALSE)
      sparklyr::spark_connect(
        method = "databricks_connect",
        cluster_id = cfg$databricks_cluster_id,
        host = cfg$databricks_host, token = cfg$databricks_token)
    },
    local = sparklyr::spark_connect(master = "local"),
    stop("CONNECTION ERROR: SPARK_METHOD '", cfg$spark_method,
         "' is not one of databricks, databricks_connect, local.",
         call. = FALSE))
  log_msg("connected: ", cfg$spark_method, ", Spark ",
          tryCatch(as.character(sparklyr::spark_version(sc)),
                   error = function(e) "unknown"))
  sc
}

disconnect_db <- function(con)
  try(sparklyr::spark_disconnect(con), silent = TRUE)

# The schema a run writes into, when WORK_SCHEMA is not set. current_database()
# is the portable spelling; current_schema() exists only on newer Spark.
current_work_schema <- function(con)
  as.character(db_q(con, "SELECT current_database() AS s")$s[1])
