# Connection, logging, naming and the step runner.
#
# Naming: everything this package writes is work schema + OBJECT_PREFIX +
# table, and it reads the cohort and the LOT tables by their own prefixes. Two
# runs on different prefixes sit side by side.
#
# Two runs on the SAME prefix are safe because every per-cohort table is
# emptied of that cohort's rows before it is written, so a re-run replaces
# rather than appends.

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
# The CDM's PHYSICAL table names, keyed by the short name the modules use.
#
# The two differ: modules say "diagnosis", the table is `t_med_diagnosis`.
# Pasting the short name straight into `t_<name>_<quarter>` produced a table
# that does not exist. Names match the cohort build's config, and each is
# overridable so a renamed table needs no code change.
CDM_TABLE_NAMES <- c(
  medical           = "medical",
  diagnosis         = "med_diagnosis",
  procedure         = "med_procedure",
  rx                = "rx",
  confinement       = "confinement",
  member_enrollment = "member_enrollment",
  member_elig       = "member_cont_enrollment",
  dod               = "dod"
)

cdm_table_name <- function(short) {
  if (!short %in% names(CDM_TABLE_NAMES))
    stop("CDM ERROR: no physical table name registered for '", short,
         "'. Known: ", paste(names(CDM_TABLE_NAMES), collapse = ", "), ".",
         call. = FALSE)
  cfg <- study_config()
  ov <- cfg[[paste0("tbl_", short)]]
  if (!is.null(ov) && nzchar(ov)) ov else unname(CDM_TABLE_NAMES[[short]])
}

cdm_src <- function(short) {
  cfg <- study_config()
  base_tbl <- cdm_table_name(short)
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
# Split on semicolons outside quotes and comments. The module templates carry
# `--` notes, and a `;` in one of those would otherwise chop the statement in
# half; the quote tracking guards against a code-list value doing the same.
split_statements <- function(sql) {
  chars <- strsplit(sql, "", fixed = TRUE)[[1]]
  n <- length(chars)
  out <- character(0); cur <- character(0)
  state <- "code"   # code | quote | line_comment | block_comment
  i <- 1L
  while (i <= n) {
    ch <- chars[i]
    nx <- if (i < n) chars[i + 1L] else ""
    if (state == "code") {
      if (ch == "'") {
        state <- "quote"
      } else if (ch == "-" && nx == "-") {
        state <- "line_comment"
        cur <- c(cur, ch, nx); i <- i + 2L; next
      } else if (ch == "/" && nx == "*") {
        state <- "block_comment"
        cur <- c(cur, ch, nx); i <- i + 2L; next
      } else if (ch == ";") {
        out <- c(out, paste(cur, collapse = "")); cur <- character(0)
        i <- i + 1L; next
      }
    } else if (state == "quote") {
      # '' inside a quoted string is an escaped quote, not the end of one.
      if (ch == "'" && nx == "'") {
        cur <- c(cur, ch, nx); i <- i + 2L; next
      }
      if (ch == "'") state <- "code"
    } else if (state == "line_comment") {
      if (ch == "\n") state <- "code"
    } else if (state == "block_comment") {
      if (ch == "*" && nx == "/") {
        state <- "code"
        cur <- c(cur, ch, nx); i <- i + 2L; next
      }
    }
    cur <- c(cur, ch)
    i <- i + 1L
  }
  if (state == "quote")
    stop("split_statements: unterminated string literal in generated SQL")
  if (state == "block_comment")
    stop("split_statements: unterminated block comment in generated SQL")
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

# Is re-running this statement safe if the first attempt's answer was lost?
#
# CREATE OR REPLACE, DROP and DELETE land in the same state either way. INSERT
# does not: one that commits and loses its acknowledgement is inserted twice by
# the retry, and the cohort-scope DELETE ran earlier, outside the retry.
# So INSERT and MERGE run once and raise.
sql_is_retry_safe <- function(st) {
  # Strip BOTH comment forms before looking at the verb. A line-comment prefix
  # was handled and a /* block */ prefix was not, so a block-commented INSERT
  # was classified retry-safe. Nothing emitted here uses that form today, which
  # is exactly why it would go unnoticed if something started to.
  head <- st
  repeat {
    was <- head
    head <- sub("^\\s+", "", head)
    head <- sub("^--[^\n]*(\n|$)", "", head)
    head <- sub("^/\\*.*?\\*/", "", head)
    if (identical(head, was)) break
  }
  !grepl("^(INSERT|MERGE)\\b", toupper(head))
}

# Execute. Accepts one statement or several, in one string or a vector.
db_exec <- function(con, sql) {
  stmts <- unlist(lapply(sql, split_statements), use.names = FALSE)
  for (st in stmts) {
    run1 <- function()
      sparklyr::invoke(sparklyr::spark_session(con), "sql", st)
    if (sql_is_retry_safe(st)) with_retry(run1) else run1()
  }
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
# Create a table if it is not there, then remove the rows this run is about to
# rewrite. Called by every module that appends rather than replaces.
#
# `scope` is the WHERE that identifies this run's rows - usually
# COHORT = '2L'. A module that writes the whole table in one statement uses
# CREATE OR REPLACE TABLE instead and does not need either of these.
# CREATE TABLE IF NOT EXISTS reconciles nothing, and every INSERT here is
# positional. A gained column fails on the count; a renamed one inserts cleanly
# and keeps the old name with the new meaning, which is worse.
#
# The schema is therefore compared BEFORE the scope is cleared, so a mismatch
# cannot leave the table short.
# Aliases only - different spellings of one type, never a different type.
#
# FLOAT is not DOUBLE: single precision turns 16,777,217 into 16,777,216.
# VARCHAR(n) is not STRING: it rejects an over-length write. TIMESTAMP_NTZ
# carries no zone. A parameterised type keeps its parameters, so it never
# matches an unparameterised declaration.
.sql_type_norm <- function(x) {
  x <- toupper(trimws(as.character(x)))
  x <- gsub("\\s+", " ", x)
  alias <- function(v, canon, names) ifelse(v %in% names, canon, v)
  # Unbounded character types only. VARCHAR(2) keeps its length and will not
  # match a declared STRING, which is the point.
  x <- alias(x, "STRING",    c("STRING", "VARCHAR", "TEXT"))
  x <- alias(x, "INT",       c("INT", "INTEGER", "INT4"))
  x <- alias(x, "BIGINT",    c("BIGINT", "LONG", "INT8"))
  x <- alias(x, "SMALLINT",  c("SMALLINT", "SHORT", "INT2"))
  x <- alias(x, "TINYINT",   c("TINYINT", "BYTE"))
  # DOUBLE and FLOAT are deliberately NOT merged.
  x <- alias(x, "DOUBLE",    c("DOUBLE", "DOUBLE PRECISION", "FLOAT8"))
  x <- alias(x, "FLOAT",     c("FLOAT", "REAL", "FLOAT4"))
  x <- alias(x, "BOOLEAN",   c("BOOLEAN", "BOOL"))
  x
}

ensure_table <- function(con, name, schema_sql) {
  db_exec(con, sprintf("CREATE TABLE IF NOT EXISTS %s (%s)", name, schema_sql))
  decl <- trimws(strsplit(gsub("\n", " ", schema_sql), ",")[[1]])
  decl <- decl[nzchar(decl)]
  want_col <- toupper(sub("\\s.*$", "", decl))
  want_typ <- .sql_type_norm(sub("^\\S+\\s+", "", decl))

  # The table was just created if it was absent, so it HAS a schema now. A
  # DESCRIBE that errors or comes back empty means the schema could not be
  # established, and that is a stop - not a pass. Treating it as "nothing to
  # compare" let an unverified table reach the DELETE below.
  d <- tryCatch(db_q(con, sprintf("DESCRIBE %s", name)),
                error = function(e)
                  stop("SCHEMA ERROR: could not read the schema of ", name,
                       " - ", conditionMessage(e),
                       "\nIt is not safe to clear rows from a table whose ",
                       "shape has not been established.", call. = FALSE))
  cn <- intersect(c("col_name", "COL_NAME", "name", "NAME"), names(d))
  tn <- intersect(c("data_type", "DATA_TYPE", "type", "TYPE"), names(d))
  have_col <- if (length(cn)) toupper(trimws(as.character(d[[cn[1]]]))) else
    character(0)
  # DESCRIBE appends partition/metadata blocks after a blank or `#` row.
  keep <- nzchar(have_col) & !startsWith(have_col, "#")
  if (any(!keep)) keep <- keep & cumsum(!keep) == 0
  have_col <- have_col[keep]
  # A DESCRIBE without a type column is not a licence to compare names only.
  # Every warehouse this runs against returns data_type; its absence means the
  # response is not the one this check was written for, and the safe reading of
  # an unrecognised response is to stop rather than to clear rows on the
  # strength of half a comparison.
  if (!length(tn))
    stop("SCHEMA ERROR: the schema of ", name, " came back without a type ",
         "column (found: ", paste(names(d), collapse = ", "),
         "). Column names alone cannot establish that writing into it is ",
         "safe, so its rows are not cleared.", call. = FALSE)
  have_typ <- .sql_type_norm(as.character(d[[tn[1]]])[keep])

  if (!length(have_col))
    stop("SCHEMA ERROR: ", name, " reported no columns after being created. ",
         "Its shape could not be established, so its rows are not cleared.",
         call. = FALSE)

  # The WHOLE ordered schema, not a prefix of it. Comparing only the first
  # length(want) names accepted a table with extra trailing columns, and the
  # positional insert then failed on the column count - after the scope had
  # already been deleted.
  bad <- !identical(have_col, want_col) || !identical(have_typ, want_typ)
  if (bad)
    stop("SCHEMA ERROR: ", name, " exists with a different shape.\n",
         "  declared: ", paste(paste(want_col, want_typ), collapse = ", "),
         "\n  found:    ",
         paste(paste(have_col, have_typ), collapse = ", "), "\n",
         "Inserts here are positional, so writing into it would put values in ",
         "the wrong columns, fail on the count, or silently reuse a renamed ",
         "one. This happens when an output prefix is reused across package ",
         "versions. Drop the table, or run against a fresh OBJECT_PREFIX.",
         call. = FALSE)
  invisible(name)
}

clear_scope <- function(con, name, scope) {
  db_exec(con, sprintf("DELETE FROM %s WHERE %s", name, scope))
  invisible(name)
}
# The two together, which is what a per-cohort module wants.
prepare_table <- function(con, name, schema_sql, cohort_key) {
  ensure_table(con, name, schema_sql)
  clear_scope(con, name, sprintf("COHORT = '%s'", cohort_key))
}

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
