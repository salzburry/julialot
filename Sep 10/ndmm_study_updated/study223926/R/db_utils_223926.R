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

# The run's own state, private to this package.
#
# In a private environment rather than a global `cfg`: the LOT engine keeps its
# own config under that name, so sourcing both in one session left whichever
# arrived second holding the name and the other's wrk() reading a config that
# was not its own. Every read goes through study_config().
.study_state <- new.env(parent = emptyenv())

set_study_config <- function(x) { .study_state$cfg <- x; invisible(x) }
study_config <- function() {
  if (is.null(.study_state$cfg))
    stop("No config. build_223926() calls set_study_config() before any step.",
         call. = FALSE)
  .study_state$cfg
}

# A module's own per-build state, registered by the module that owns it.
#
# reset_run_state() runs before source_modules(), so it cannot name a module's
# function directly: in a fresh process that function does not exist yet.
# Registration is by name, so re-sourcing a module replaces its hook rather
# than stacking another copy.
register_run_reset <- function(name, fn) {
  if (is.null(.study_state$resets)) .study_state$resets <- list()
  .study_state$resets[[name]] <- fn
  invisible(TRUE)
}

# Everything a build accumulates and a second build in the same session must
# not inherit. Called once, at the top of build_223926().
#
# The two helpers named directly live in files build.R always sources, so they
# are always there. Anything in R/modules/ registers itself instead.
reset_run_state <- function() {
  .study_state$cfg <- NULL
  reset_codelist_manifest()
  for (f in .study_state$resets) f()
  invisible(TRUE)
}

# A CDM table, with the quarterly suffix picked from STUDY_END - the same
# resolution the cohort build uses, so both read the same vintage.
quarter_suffix <- function(study_end) {
  d <- as.Date(study_end)
  sprintf("%sq%d", format(d, "%Y"), (as.integer(format(d, "%m")) - 1L) %/% 3L + 1L)
}
# The CDM's PHYSICAL table names, keyed by the short name the modules use.
#
# The two differ: modules say "diagnosis", the table is `t_med_diagnosis`, so
# the short name cannot be pasted straight into `t_<name>_<quarter>`. Names
# match the cohort build's, and each is overridable so a renamed table needs no
# code change.
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
# The cohort table the study was pointed at, as SQL names it.
#
# INPUT_COHORT_TABLE is the bare name the cohort build wrote it under - the
# name the LOT status row records and the lineage check compares - so it stays
# bare in cfg. In SQL the run's own catalog and schema go in front of it, as
# the LOT engine does with the same name; used bare it resolves against the
# session's current schema, which over the ODBC warehouse is `default`. A name
# given already qualified is used as it is.
input_cohort_tbl <- function() {
  cfg <- study_config()
  nm <- trimws(cfg$input_cohort_table)
  if (grepl(".", nm, fixed = TRUE)) nm
  else sprintf("%s.%s.%s", cfg$catalog, cfg$work_schema, nm)
}

# One string for one BUILD of a run, from the timestamp its status row carries.
#
# A run id is not a build. DOMINO_RUN_ID is reused for every build inside one
# Domino run, so two builds under one id can each leave a `complete` row with
# different settings and nothing but UPDATED_AT to tell them apart.
#
# Formatted in UTC and reduced to alphanumerics, so the same instant reads the
# same wherever it is compared and can stand as one path segment. A value that
# is not a timestamp comes back as the string it was, stripped, rather than as
# the empty one.
run_version_stamp <- function(x) {
  if (is.null(x) || !length(x)) return("")
  x <- x[[1L]]
  if (length(x) != 1L || is.na(x)) return("")
  if (inherits(x, "POSIXt")) return(format(x, "%Y%m%dT%H%M%SZ", tz = "UTC"))
  s <- trimws(as.character(x))
  if (!nzchar(s)) return("")
  t <- suppressWarnings(tryCatch(
    as.POSIXct(s, tz = "UTC", tryFormats = c("%Y-%m-%d %H:%M:%OS",
                                             "%Y-%m-%dT%H:%M:%OS",
                                             "%Y-%m-%d")),
    error = function(e) NA))
  if (!is.na(t)) return(format(t, "%Y%m%dT%H%M%SZ", tz = "UTC"))
  gsub("[^A-Za-z0-9]", "", s)
}

# One DESCRIBE, read the way every caller needs it: the column names in order,
# upper-cased, with the partition and metadata blocks Spark appends after a
# blank or `#` row cut off, and the normalised types beside them where the
# response carried a type column (`typed`). The raw column names travel along
# for a message.
# Two questions an error can answer, kept apart because they call for opposite
# responses.
#
# "It is not there" is a fact about the warehouse - a table or a column that
# was never written - and a reader can decide what an absence means: an older
# build that predates a column, a status that was never recorded. "It could
# not be read" is not a fact about anything: a permission refused, a session
# dropped, a statement the engine would not parse. Treating the second as the
# first turns every outage into "nothing was recorded", which is the answer
# that accepts. The LOT engine asks the same question of itself
# (missing_object_error in its db_utils_lot.R); the patterns are its.
missing_object_error <- function(err) {
  msg <- if (inherits(err, "condition")) conditionMessage(err) else as.character(err)
  length(msg) == 1L && !is.na(msg) &&
    grepl("TABLE_OR_VIEW_NOT_FOUND|Table or view not found|no such table|does not exist",
          msg, ignore.case = TRUE)
}
# ...and the same for a column the table does not carry, which is how an older
# writer's table answers a newer reader's SELECT.
missing_column_error <- function(err) {
  msg <- if (inherits(err, "condition")) conditionMessage(err) else as.character(err)
  length(msg) == 1L && !is.na(msg) &&
    grepl("UNRESOLVED_COLUMN|cannot resolve|no such column|has no column|Column .* not found",
          msg, ignore.case = TRUE)
}

# Is this table there to be read? Asked before an OPTIONAL read - one whose
# absence changes what a run can SAY rather than what it computes - so that the
# absence is reported once, in this package's words, instead of arriving as a
# warehouse error from the middle of a statement.
#
# A DESCRIBE, not a SELECT: it is the cheapest question that distinguishes an
# absent table from an empty one, and an empty table IS readable.
table_readable <- function(con, name)
  !inherits(tryCatch(db_q(con, sprintf("DESCRIBE %s", name)),
                     error = function(e) e), "error")

describe_columns <- function(con, name) {
  d <- db_q(con, sprintf("DESCRIBE %s", name))
  cn <- intersect(c("col_name", "COL_NAME", "name", "NAME"), names(d))
  tn <- intersect(c("data_type", "DATA_TYPE", "type", "TYPE"), names(d))
  col <- if (length(cn)) toupper(trimws(as.character(d[[cn[1]]]))) else character(0)
  keep <- nzchar(col) & !startsWith(col, "#")
  if (any(!keep)) keep <- keep & cumsum(!keep) == 0
  out <- data.frame(
    COL = col[keep],
    TYPE = if (length(tn)) .sql_type_norm(as.character(d[[tn[1]]])[keep])
           else rep(NA_character_, sum(keep)),
    stringsAsFactors = FALSE)
  attr(out, "typed") <- length(tn) > 0L
  attr(out, "raw_names") <- names(d)
  out
}

# Whether one LOT status row is the build a reader accepted: this run id,
# complete, and - where the reader recorded which build - this stamp. Every
# reader decides it here, beside the stamp it compares.
lot_build_owns <- function(row, run_id, version = "") {
  id <- trimws(as.character(run_id %||% "")); v <- trimws(as.character(version %||% ""))
  if (is.null(row) || !nrow(row) || !nzchar(id)) return(FALSE)
  identical(trimws(as.character(row$RUN_ID[1])), id) &&
    identical(tolower(trimws(as.character(row$STATE[1]))), "complete") &&
    (!nzchar(v) || identical(run_version_stamp(row$UPDATED_AT[1] %||% ""), v))
}

# Columns a table gained after it was first created, added in place.
#
# S_RUN_METADATA is CREATE IF NOT EXISTS, so a prefix first written by an
# earlier version of this package keeps the earlier shape. Only ever ADDS: an
# existing column keeps its type. The DESCRIBE has to succeed, because the
# named insert that follows needs every column to exist.
ensure_columns <- function(con, name, cols) {
  d <- describe_columns(con, name)
  want <- toupper(names(cols))
  if (!nrow(d))
    stop("SCHEMA ERROR: could not establish the columns of ", name,
         ", so a column cannot be added to it.", call. = FALSE)
  # A DESCRIBE without a type column cannot say whether the columns that exist
  # can take what this writer inserts, so an unrecognised response stops rather
  # than passing on names alone - the same reading as in ensure_table().
  if (!isTRUE(attr(d, "typed")))
    stop("SCHEMA ERROR: the schema of ", name, " came back without a type ",
         "column (found: ", paste(attr(d, "raw_names"), collapse = ", "),
         "). Column names alone cannot establish that writing into it is ",
         "safe, so nothing is written.", call. = FALSE)
  # An existing column keeps its type, and a type this writer cannot insert
  # into is found here - before the DELETE that precedes the insert, rather
  # than by the insert failing after the row is already gone.
  for (m in intersect(d$COL, want)) {
    ht <- d$TYPE[match(m, d$COL)]
    wt <- .sql_type_norm(cols[[match(m, want)]])
    if (!identical(ht, wt))
      stop("SCHEMA ERROR: ", name, ".", m, " is ", ht, " where this package ",
           "writes ", wt, ". The insert would fail after the run's own row ",
           "had been cleared, so nothing is written. This happens when an ",
           "output prefix is reused across package versions: run against a ",
           "fresh OBJECT_PREFIX, or drop the table.", call. = FALSE)
  }
  missing <- setdiff(want, d$COL)
  for (m in missing) {
    db_exec(con, sprintf("ALTER TABLE %s ADD COLUMNS (%s %s)", name, m,
                         cols[[match(m, want)]]))
    log_msg("  schema evolution on ", name, ": added ", m)
  }
  invisible(missing)
}

# Spark's sql() takes ONE statement, and several module templates are written
# as a CREATE TABLE IF NOT EXISTS followed by an INSERT, so they are split here
# on semicolons outside quotes and comments - the templates carry `--` notes,
# and a `;` in one of those would chop a statement in half.
#
# Only the positions that can change state are matched - a quote, a comment
# opener, a newline, a semicolon - because walking every character is quadratic
# in statement length. `*/` is deliberately absent: it can share a `/` with a
# `/*`, since in `**/*` the block-comment opener starts at the third character,
# so where a block comment closes is looked up separately below.
#
# All three quote characters are tracked, not just `'`: Spark writes a quoted
# identifier in BACKTICKS and this package's own SQL uses them, and under ANSI
# mode a double quote is an identifier too. Each closes on itself, and doubled
# inside means an escaped one. In a string literal Spark's escape is also the
# backslash, which is how codelist_stage_sql() writes its values, so a quote
# behind an ODD number of backslashes does not close the literal - otherwise
# 'Alzheimer\'s disease' ends at the apostrophe. A backtick has no such escape.
.SQL_TOKENS <- "--|/\\*|'|\"|`|;|\n"
.SQL_QUOTES <- c("'", "\"", "`")

.escaped_by_backslash <- function(sql, p) {
  k <- 0L; j <- p - 1L
  while (j >= 1L && substr(sql, j, j) == "\\") { k <- k + 1L; j <- j - 1L }
  k %% 2L == 1L
}

split_statements <- function(sql) {
  g   <- gregexpr(.SQL_TOKENS, sql)
  pos <- g[[1L]]
  if (pos[1L] == -1L)
    return(.slice_statements(sql, integer(0), "code"))
  tok <- regmatches(sql, g)[[1L]]
  n <- length(pos)
  close_at <- gregexpr("\\*/", sql)[[1L]]
  close_at <- if (close_at[1L] == -1L) integer(0) else as.integer(close_at)

  cuts <- integer(0)
  # Where each comment runs from and to, so a statement that is nothing but
  # comments can be told from one that has SQL in it.
  cs <- integer(0); ce <- integer(0); open_at <- NA_integer_
  state <- "code"   # code | quote | line_comment | block_comment
  qch <- ""
  i <- 1L
  while (i <= n) {
    ch <- tok[i]
    if (state == "code") {
      if (ch == ";") {
        cuts <- c(cuts, pos[i])
      } else if (ch %in% .SQL_QUOTES) {
        state <- "quote"; qch <- ch
      } else if (ch == "--") {
        state <- "line_comment"; open_at <- pos[i]
      } else if (ch == "/*") {
        # Jump to where the comment closes rather than walking its text. No
        # close is the unterminated case; `state` carries that to the error.
        q <- close_at[close_at >= pos[i] + 2L]
        if (!length(q)) { state <- "block_comment"; open_at <- pos[i]; break }
        cs <- c(cs, pos[i]); ce <- c(ce, q[1L] + 1L)
        resume <- q[1L] + 2L
        while (i < n && pos[i + 1L] < resume) i <- i + 1L
      }
    } else if (state == "quote") {
      # A doubled quote inside a quoted run is an escaped one, not the end.
      # Adjacent by POSITION, not merely the next token: 'a' || 'b' has two
      # quotes in a row with text between them, and the first string closes.
      # So is a string quote behind an odd run of backslashes.
      if (ch == qch) {
        if (qch != "`" && .escaped_by_backslash(sql, pos[i])) {
          # escaped: the string goes on
        } else if (i < n && tok[i + 1L] == qch && pos[i + 1L] == pos[i] + 1L)
          i <- i + 1L
        else state <- "code"
      }
    } else if (state == "line_comment") {
      if (ch == "\n") {
        state <- "code"; cs <- c(cs, open_at); ce <- c(ce, pos[i] - 1L)
      }
    }
    i <- i + 1L
  }
  if (identical(state, "line_comment")) {
    cs <- c(cs, open_at); ce <- c(ce, nchar(sql)); state <- "code"
  }
  .slice_statements(sql, cuts, state, cs, ce)
}

# Is there any SQL in this span, or only comments and whitespace? A template
# ending in a comment would otherwise emit that comment as a statement of its
# own, which the warehouse rejects.
.span_has_code <- function(sql, s, e, cs, ce) {
  if (s > e) return(FALSE)
  ov <- which(ce >= s & cs <= e)
  if (!length(ov)) return(nzchar(trimws(substring(sql, s, e))))
  ov <- ov[order(cs[ov])]
  cur <- s
  for (k in ov) {
    a <- max(cs[k], s); b <- min(ce[k], e)
    if (a > cur && nzchar(trimws(substring(sql, cur, a - 1L)))) return(TRUE)
    cur <- max(cur, b + 1L)
  }
  cur <= e && nzchar(trimws(substring(sql, cur, e)))
}

# Cut out of the original string rather than reassembled character by
# character, so a split costs one substring per statement.
.slice_statements <- function(sql, cuts, state, cs = integer(0), ce = integer(0)) {
  if (state == "quote")
    stop("split_statements: unterminated string literal in generated SQL")
  if (state == "block_comment")
    stop("split_statements: unterminated block comment in generated SQL")
  starts <- c(1L, cuts + 1L)
  ends   <- c(cuts - 1L, nchar(sql))
  out <- trimws(substring(sql, starts, ends))
  keep <- nzchar(out) &
    vapply(seq_along(starts), function(k)
      .span_has_code(sql, starts[k], ends[k], cs, ce), logical(1))
  out[keep]
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
  # BOTH comment forms are stripped before the verb is read, so a
  # block-commented INSERT is not classified retry-safe.
  head <- st
  repeat {
    was <- head
    head <- sub("^\\s+", "", head)
    head <- sub("^--[^\n]*(\n|$)", "", head)
    head <- sub("^/\\*.*?\\*/", "", head)
    if (identical(head, was)) break
  }
  head <- toupper(head)
  # A leading WITH does not make a statement a read: `WITH a AS (...) INSERT
  # INTO t SELECT * FROM a` is a write whose first verb is WITH, so the first
  # verb alone cannot decide it.
  if (grepl("^WITH\\b", head))
    return(!grepl("\\b(INSERT|MERGE)\\s+INTO\\b", head))
  !grepl("^(INSERT|MERGE)\\b", head)
}

# The connection is one of two things, and every statement is SQL text, so they
# differ only here: a DBI connection - the Databricks ODBC driver the cohort
# and LOT builds use - or a sparklyr session. A sparklyr session inherits
# DBIConnection too, so it is told apart first.
is_spark_con <- function(con) inherits(con, "spark_connection")
is_dbi_con   <- function(con) inherits(con, "DBIConnection") && !is_spark_con(con)

# The calls that reach the DBI driver, separate so a test can answer them
# without DBI installed.
dbi_exec       <- function(con, sql) DBI::dbExecute(con, sql)
dbi_query      <- function(con, sql) DBI::dbGetQuery(con, sql)
dbi_disconnect <- function(con) DBI::dbDisconnect(con)

# A BIGINT comes back from the ODBC driver as bit64::integer64, a 64-bit
# integer stored in a double's bit pattern; pasted or compared without bit64
# attached, a count of 1780 reads as 8.794368e-321. Converted once, here.
# Every count this package reads is far below 2^53, so nothing is lost.
.unint64 <- function(d) {
  if (!is.data.frame(d) || !ncol(d)) return(d)
  for (j in seq_along(d))
    if (inherits(d[[j]], "integer64")) d[[j]] <- as.numeric(d[[j]])
  d
}

# The one call that reaches the driver, separate so what surrounds it - which
# statement is retried and which is not - can be driven without a warehouse.
db_exec_once <- function(con, sql) {
  if (is_dbi_con(con)) dbi_exec(con, sql)
  else sparklyr::invoke(sparklyr::spark_session(con), "sql", sql)
}

# Execute. Accepts one statement or several, in one string or a vector.
#
# A statement is retried only if it is safe to run twice. An INSERT that
# committed and lost its answer would be sent again, and the rows written
# twice, so those are sent once and a failure is a failure.
db_exec <- function(con, sql) {
  stmts <- unlist(lapply(sql, split_statements), use.names = FALSE)
  for (st in stmts) {
    if (sql_is_retry_safe(st)) with_retry(function() db_exec_once(con, st))
    else db_exec_once(con, st)
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
  with_retry(function()
    if (is_dbi_con(con)) .unint64(dbi_query(con, stmts[1]))
    else sparklyr::sdf_collect(sparklyr::sdf_sql(con, stmts[1])))
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

# Create a table if it is not there, then remove the rows this run is about to
# rewrite. `scope` is the WHERE that identifies them, usually COHORT = '2L'; a
# module that writes the whole table in one statement uses CREATE OR REPLACE
# TABLE and needs neither.
#
# CREATE TABLE IF NOT EXISTS reconciles nothing and every INSERT here is
# positional, so the schema is compared before the scope is cleared. A gained
# column fails on the count; a renamed one inserts cleanly and keeps the old
# name with the new meaning, which is worse.
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

# Which (table, shape) pairs this run has already established.
#
# prepare_table() is called once per COHORT, and ensure_table() is the half of
# it that does not vary by cohort: the CREATE is idempotent and the DESCRIBE
# reads a shape that cannot change while this run is the only writer. Over four
# cohorts that is four CREATEs and four DESCRIBEs per table where one of each
# would do - 114 of a full run's 684 statements, every one a round trip to the
# warehouse and none of them able to return a different answer.
#
# Keyed on the shape as well as the name, so a table asked for under a
# different declaration is checked again rather than assumed. The guard that
# catches a table left by an older package version still runs - it runs the
# FIRST time, which is the only time it can find anything.
#
# Per RUN, not per process: reset by build_223926() so a second build in one
# session re-establishes everything rather than trusting the first build's
# answers about tables it may since have dropped.
.ensured <- new.env(parent = emptyenv())
ensure_table_reset <- function() rm(list = ls(.ensured), envir = .ensured)

ensure_table <- function(con, name, schema_sql) {
  key <- paste(name, gsub("\\s+", " ", schema_sql))
  if (!is.null(get0(key, envir = .ensured, ifnotfound = NULL))) return(invisible(NULL))
  db_exec(con, sprintf("CREATE TABLE IF NOT EXISTS %s (%s)", name, schema_sql))
  decl <- trimws(strsplit(gsub("\n", " ", schema_sql), ",")[[1]])
  decl <- decl[nzchar(decl)]
  want_col <- toupper(sub("\\s.*$", "", decl))
  want_typ <- .sql_type_norm(sub("^\\S+\\s+", "", decl))

  # The table was just created if it was absent, so it HAS a schema now. A
  # DESCRIBE that errors or comes back empty means the schema could not be
  # established, which is a stop: rows are not cleared from a table whose shape
  # is unknown.
  d <- tryCatch(describe_columns(con, name),
                error = function(e)
                  stop("SCHEMA ERROR: could not read the schema of ", name,
                       " - ", conditionMessage(e),
                       "\nIt is not safe to clear rows from a table whose ",
                       "shape has not been established.", call. = FALSE))
  have_col <- d$COL
  # A DESCRIBE without a type column is not a licence to compare names only.
  # Every warehouse this runs against returns data_type, so its absence means
  # an unrecognised response, and that stops.
  if (!isTRUE(attr(d, "typed")))
    stop("SCHEMA ERROR: the schema of ", name, " came back without a type ",
         "column (found: ", paste(attr(d, "raw_names"), collapse = ", "),
         "). Column names alone cannot establish that writing into it is ",
         "safe, so its rows are not cleared.", call. = FALSE)
  have_typ <- d$TYPE

  if (!length(have_col))
    stop("SCHEMA ERROR: ", name, " reported no columns after being created. ",
         "Its shape could not be established, so its rows are not cleared.",
         call. = FALSE)

  # The WHOLE ordered schema, not a prefix of it: comparing only the first
  # length(want) names accepts a table with extra trailing columns, which the
  # positional insert then fails on.
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
  # Recorded only after the shape has been ESTABLISHED. Every path above that
  # could not establish it raises, so a table is never remembered as verified
  # on the strength of a check that did not finish.
  assign(key, TRUE, envir = .ensured)
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

# The connection, by SPARK_METHOD.
#
#   odbc                the Databricks ODBC driver through DBI: the DSN in
#                       DATABRICKS_DSN and the password in DATABRICKS_PWD,
#                       exactly as the cohort and LOT builds connect. The
#                       default, and the one a server without a Spark
#                       session can run.
#   databricks          running ON a Databricks cluster or notebook - the
#                       session already exists and sparklyr attaches to it.
#                       Nothing to authenticate.
#   databricks_connect  running outside it, against a named cluster. Needs
#                       DATABRICKS_HOST, DATABRICKS_TOKEN and SPARK_CLUSTER_ID.
#   local               a local Spark, for a smoke test over fixtures. It has
#                       no CDM, so only the framework can be exercised.
connect_db <- function(cfg) {
  if (identical(cfg$spark_method, "odbc")) return(connect_odbc(cfg))
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
         "' is not one of odbc, databricks, databricks_connect, local.",
         call. = FALSE))
  log_msg("connected: ", cfg$spark_method, ", Spark ",
          tryCatch(as.character(sparklyr::spark_version(sc)),
                   error = function(e) "unknown"))
  sc
}

connect_odbc <- function(cfg) {
  for (pkg in c("DBI", "odbc"))
    if (!requireNamespace(pkg, quietly = TRUE))
      stop("CONNECTION ERROR: ", pkg, " is not installed.", call. = FALSE)
  if (!nzchar(cfg$pwd))
    stop("CONNECTION ERROR: DATABRICKS_PWD environment variable is not set.",
         call. = FALSE)
  con <- odbc_connect(cfg$dsn, cfg$pwd)
  log_msg("connected: odbc, DSN ", cfg$dsn)
  con
}

# The one call that opens the driver, separate so connect_odbc() can be
# driven by a test without a DSN.
odbc_connect <- function(dsn, pwd)
  DBI::dbConnect(odbc::odbc(), dsn = dsn, pwd = pwd, timeout = 120)

disconnect_db <- function(con) {
  if (is_dbi_con(con)) try(dbi_disconnect(con), silent = TRUE)
  else try(sparklyr::spark_disconnect(con), silent = TRUE)
}

# The schema a run writes into, when WORK_SCHEMA is not set. current_database()
# is the portable spelling; current_schema() exists only on newer Spark.
current_work_schema <- function(con)
  as.character(db_q(con, "SELECT current_database() AS s")$s[1])
