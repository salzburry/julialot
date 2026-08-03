
# Raw claim ICD_FLAG, normalised. Both families are named and anything else is
# NULL - not the other family by default.
#
# Reading "not one of the ICD-9 spellings" as ICD-10 means a NULL
# or unexpected flag on a genuine ICD-9 claim was classed ICD-10 and then failed
# the family join silently: a missed MM diagnosis, or an exclusion claim that
# stopped excluding the patient it should. The codelist column is checked and
# stops the build because that file can be corrected; the CDM's values cannot,
# so this yields NULL, which matches neither family and is the honest answer for
# a row whose family is unknown.
#
# nine/ten are the labels the caller wants: a family column, or the DIAG / PROC
# code_type pairs.
RAW_ICD9  <- c("9", "ICD9", "ICD-9")
RAW_ICD10 <- c("10", "ICD10", "ICD-10")
icd_family_sql <- function(col, nine = "ICD9", ten = "ICD10") {
  q <- function(v) paste(sprintf("'%s'", v), collapse = ", ")
  paste0("CASE WHEN upper(trim(", col, ")) IN (", q(RAW_ICD9), ") THEN '", nine, "'",
         " WHEN upper(trim(", col, ")) IN (", q(RAW_ICD10), ") THEN '", ten, "'",
         " ELSE NULL END")
}
# Connection, retry, naming and materialization. No module-level state -
# build_cohort() creates it and passes it by argument.

# ---- Separators (pre-computed constants) ----
SEP_59  <- strrep("=", 59)
SEP_60  <- strrep("=", 60)
DASH_60 <- strrep("-", 60)

# ---- Logging ----
# One log file per run. PIPELINE_LOG_FILE wins; else a timestamped file under
# OUTPUT_DIR, falling back to tempdir().
.resolve_log_file <- function() {
  lf <- getOption("pipeline_log_file", default = NULL)
  if (!is.null(lf)) return(lf)
  envf <- Sys.getenv("PIPELINE_LOG_FILE", unset = "")
  if (nzchar(envf)) {
    lf <- envf
  } else {
    base_dir <- Sys.getenv("OUTPUT_DIR", unset = "")
    if (!nzchar(base_dir)) base_dir <- "/mnt/artifacts/results"
    ok <- tryCatch({ dir.create(base_dir, showWarnings = FALSE, recursive = TRUE); dir.exists(base_dir) },
                   error = function(e) FALSE)
    if (!isTRUE(ok)) base_dir <- tempdir()
    lf <- file.path(base_dir, paste0("pipeline_run_",
            format(Sys.time(), "%Y%m%d_%H%M%S"), ".log"))
  }
  options(pipeline_log_file = lf)
  cat(sprintf("[%s] [log] run log -> %s\n",
              format(Sys.time(), "%Y-%m-%d %H:%M:%S"), lf))
  lf
}

log_msg <- function(...) {
  prefix <- sprintf("[%s] ", format(Sys.time(), "%Y-%m-%d %H:%M:%S"))
  cat(prefix, ..., "\n")
  flush.console()
  try({
    lf <- .resolve_log_file()
    cat(prefix, ..., "\n", file = lf, append = TRUE)
  }, silent = TRUE)
}

# ---- Quarterly CDM table names (t_<table>_YYYYqQ) ----
get_quarter_suffix <- function(date_str) {
  d <- as.Date(date_str)
  paste0(format(d, "%Y"), "q", ceiling(as.integer(format(d, "%m")) / 3))
}

get_quarterly_table <- function(base_table, date_str) {
  paste0("t_", base_table, "_", get_quarter_suffix(date_str))
}

# ---- Naming helpers (closure factory) ----
# Naming functions that close over cfg and mat_tables. The step files unpack
# the ones they use. mat_tables is an environment, so what
# materialize_to_personal_schema() writes is visible to work_tbl().
make_naming_helpers <- function(cfg, mat_tables = new.env()) {
  full_name <- function(schema, object) {
    if (nzchar(cfg$catalog)) paste0(cfg$catalog, ".", schema, ".", object)
    else paste0(schema, ".", object)
  }
  cdm  <- function(tbl) full_name(cfg$cdm_schema, tbl)
  work <- function(tbl) tbl

  work_tbl <- function(name) {
    if (exists(name, envir = mat_tables)) return(get(name, envir = mat_tables))
    name
  }

  # Quarterly table resolution
  cdm_quarterly <- function(base_table) {
    cdm(get_quarterly_table(base_table, cfg$study_end))
  }
  cdm_src <- function(base_table) {
    if (isTRUE(cfg$use_quarterly_tables)) cdm_quarterly(base_table)
    else cdm(base_table)
  }

  list(full_name = full_name, cdm = cdm, work = work,
       work_tbl = work_tbl, cdm_src = cdm_src, cdm_quarterly = cdm_quarterly)
}

# ---- Load code-list CSVs into Spark temp views ----
# Code-list files live on the server filesystem (/mnt/code/codelist/) as CSVs.
# R can read these directly, but Spark executors cannot access the driver's
# local filesystem. So we read each CSV in R and push it to Spark as a temp
# view via a SQL VALUES clause.
load_csv_codelists <- function(conn, cfg) {
  if (!isTRUE(cfg$use_csv_codelists)) return(invisible(NULL))

  csv_map <- cfg$codelist_csv_map
  required <- unique(c(cfg$cl_mm_dx, cfg$cl_mm_therapy, cfg$cl_preg,
                       cfg$cl_clintrial, cfg$cl_other_malig))
  missing <- setdiff(required, names(csv_map))
  if (length(missing))
    stop("No CSV mapping for: ", paste(missing, collapse = ", "), call. = FALSE)

  log_msg("Loading code lists from CSV: ", cfg$codelist_dir)

  # Only the five lists this build uses.
  for (tbl_name in required) {
    csv_file <- csv_map[[tbl_name]]
    csv_path <- file.path(cfg$codelist_dir, csv_file)
    tryCatch({
      # The code lists live outside version control, so the file name alone does not say
      # which version a run used. Hash it, and hash it again after the read:
      # if it were swapped mid-read the logged hash would describe a file we
      # did not load.
      md5 <- unname(tools::md5sum(csv_path))
      # Read CSV in R (driver-local filesystem access)
      df <- read.csv(csv_path, stringsAsFactors = FALSE, colClasses = "character")
      if (!identical(md5, unname(tools::md5sum(csv_path))))
        stop("file changed while it was being read", call. = FALSE)
      df[] <- lapply(df, trimws)
      n <- nrow(df)
      cols <- names(df)
      col_list <- paste(cols, collapse = ", ")

      if (n == 0) {
        sel <- paste(paste0("CAST(NULL AS STRING) AS ", cols), collapse = ", ")
        sql <- glue("CREATE OR REPLACE TEMPORARY VIEW {tbl_name} AS SELECT {sel} WHERE 1=0")
      } else {
        # Build VALUES rows from R data frame
        value_rows <- vapply(seq_len(n), function(i) {
          vals <- vapply(cols, function(c) {
            v <- df[[c]][i]
            if (is.na(v) || v == "") "NULL"
            else paste0("'", gsub("'", "''", v), "'")
          }, character(1))
          paste0("(", paste(vals, collapse = ","), ")")
        }, character(1))
        values_sql <- paste(value_rows, collapse = ",\n        ")
        sql <- glue("CREATE OR REPLACE TEMPORARY VIEW {tbl_name} AS
          SELECT {col_list} FROM VALUES
          {values_sql}
          AS t({col_list})")
      }

      DBI::dbExecute(conn$con, sql)
      log_msg("  >> ", tbl_name, " <- ", csv_file, " (",
              format(n, big.mark = ","), " rows, md5 ",
              if (is.na(md5)) "unavailable" else md5, ")")
    }, error = function(e) {
      log_msg("  ERROR: Required codelist ", csv_file, " failed: ",
              conditionMessage(e))
      stop("Cannot proceed without required codelist: ", tbl_name,
           call. = FALSE)
    })
  }
  log_msg("Code lists loaded")
}

# ---- Databricks connection ----
connect_databricks <- function(cfg) {
  if (!nzchar(cfg$pwd)) {
    stop("DATABRICKS_PWD environment variable is not set.")
  }
  DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 120)
}

db_ping <- function(con) {
  tryCatch({ DBI::dbGetQuery(con, "SELECT 1 AS ok"); TRUE },
           error = function(e) FALSE)
}

with_retry <- function(fn, max_retries = 3L, base_sleep = 5) {
  attempt <- 1
  repeat {
    result <- tryCatch(fn(), error = function(e) e)
    if (!inherits(result, "error")) return(result)
    # Some failures cannot be retried - retrying a dead session just repeats
    # the same error against the same connection.
    if (inherits(result, "fatal_error")) stop(result)
    if (attempt >= max_retries) stop(result)
    sleep_s <- base_sleep * (2^(attempt - 1))
    log_msg("Retryable failure: ", conditionMessage(result))
    log_msg("Retrying in ", sleep_s, "s (attempt ", attempt + 1, "/", max_retries, ")")
    Sys.sleep(sleep_s)
    attempt <- attempt + 1
  }
}

# ---- Materialization to personal schema (GSK helper) ----
# Transient Delta/Spark errors worth retrying. CREATE OR REPLACE TABLE
# on a large source can take many minutes; if the target Delta table is
# touched concurrently (auto-optimize, another session, an overlapping
# run) the commit throws MetadataChangedException / a CONCURRENT_*
# error. These are transient - a fresh attempt usually succeeds.
.mat_transient_patterns <- c(
  "DELTA_METADATA_CHANGED", "MetadataChangedException",
  "ConcurrentModificationException", "ConcurrentAppend",
  "ConcurrentDeleteRead", "ConcurrentDeleteDelete",
  "ConcurrentTransaction", "CONCURRENT_", "concurrent update",
  "DELTA_CONCURRENT", "could not be committed"
)

materialize_to_personal_schema <- function(con, view_name, cfg, mat_tables) {
  if (!nzchar(cfg$personal_schema)) {
    log_msg("WARN: personal_schema not set, skipping materialization of ", view_name)
    return(FALSE)
  }
  prefix <- if (is.null(cfg$object_prefix)) "" else tolower(cfg$object_prefix)
  remote_table <- paste0(prefix, tolower(view_name))
  full_table_name <- if (nzchar(cfg$catalog)) {
    paste0(cfg$catalog, ".", cfg$personal_schema, ".", remote_table)
  } else {
    paste0(cfg$personal_schema, ".", remote_table)
  }

  max_attempts <- as.integer(Sys.getenv("MATERIALIZE_RETRIES", unset = "3"))
  if (is.na(max_attempts) || max_attempts < 1) max_attempts <- 3L

  # Write to a new staging table, then publish it to the final name.
  # The long write touches no existing table metadata, so a concurrent commit
  # can't collide with it. Publishing is a second copy, not a rename - it
  # re-reads the staged table instead of the query, but it still writes the
  # rows again. Both times are logged; measure before assuming it is cheap.
  for (attempt in seq_len(max_attempts)) {
    t0 <- Sys.time()
    stg <- paste0(full_table_name, "__stg_",
                  format(t0, "%Y%m%d%H%M%S"), "_", Sys.getpid(),
                  "_a", attempt)
    log_msg("  >> Materializing ", view_name, " -> ", full_table_name,
            " via staging (attempt ", attempt, "/", max_attempts,
            ", started ", format(t0, "%H:%M:%S"), ") ...")
    res <- tryCatch({
      try(DBI::dbExecute(con, glue("DROP TABLE IF EXISTS {stg}")), silent = TRUE)
      # Heavy write to a NEW table (no replace-in-place => not exposed
      # to the concurrent-metadata failure during the long scan).
      DBI::dbExecute(con, glue(
        "CREATE TABLE {stg} AS SELECT * FROM `{view_name}`"))
      t1 <- Sys.time()
      el_stg <- round(as.numeric(difftime(t1, t0, units = "secs")), 1)
      log_msg("  >> Staged ", view_name, " in ", el_stg,
              " s; publishing to ", full_table_name, " ...")
      # Second copy, reading the staged table rather than re-running the query.
      DBI::dbExecute(con, glue(
        "CREATE OR REPLACE TABLE {full_table_name} AS SELECT * FROM {stg}"))
      el_pub <- round(as.numeric(difftime(Sys.time(), t1, units = "secs")), 1)
      DBI::dbExecute(con, glue(
        "CREATE OR REPLACE TEMPORARY VIEW {view_name} AS SELECT * FROM {full_table_name}"))
      try(DBI::dbExecute(con, glue("DROP TABLE IF EXISTS {stg}")), silent = TRUE)
      assign(view_name, full_table_name, envir = mat_tables)
      el <- round(as.numeric(difftime(Sys.time(), t0, units = "secs")), 1)
      log_msg("  >> Materialized ", view_name, " OK in ", el,
              " s (stage ", el_stg, " s + publish ", el_pub,
              " s, view alias re-pointed)")
      TRUE
    }, error = function(e) e)

    if (isTRUE(res)) return(TRUE)

    # Best-effort: never leak the staging table.
    try(DBI::dbExecute(con, glue("DROP TABLE IF EXISTS {stg}")), silent = TRUE)

    msg <- conditionMessage(res)
    el  <- round(as.numeric(difftime(Sys.time(), t0, units = "secs")), 1)
    transient <- any(vapply(.mat_transient_patterns,
                            function(p) grepl(p, msg, ignore.case = TRUE),
                            logical(1)))
    if (!transient) {
      log_msg("  >> WARN: Materialization of ", view_name,
              " failed after ", el, " s (permanent, not retrying): ", msg)
      return(FALSE)
    }
    if (attempt >= max_attempts) {
      log_msg("  >> WARN: Materialization of ", view_name,
              " still failing after ", attempt, " attempt(s) (", el,
              " s): transient Delta concurrency error. Last: ", msg)
      return(FALSE)
    }
    wait_s <- 15 * (2 ^ (attempt - 1))   # 15s, 30s, 60s ...
    log_msg("  >> Transient Delta concurrency error after ", el,
            " s (attempt ", attempt, "/", max_attempts,
            "). Retrying in ", wait_s, " s. Detail: ", msg)
    Sys.sleep(wait_s)
  }
  FALSE
}

# Run QC after materialization so it scans the saved table.
run_qc <- function(con, qc_sql) {
  if (is.null(qc_sql)) return(invisible(NULL))
  qc <- DBI::dbGetQuery(con, qc_sql)
  if (!nrow(qc)) {
    log_msg("  >> Result: no rows")
    return(invisible(qc))
  }
  formatted <- vapply(qc, function(col) {
    value <- as.character(col[[1]])
    number <- suppressWarnings(as.numeric(value))
    if (is.na(number)) value else format(number, big.mark = ",")
  }, character(1))
  metrics <- paste0(names(formatted), " = ", formatted)
  log_msg("  >> Result: ", paste(metrics, collapse = ", "))
  flush.console()
  invisible(qc)
}

# ---- Step runner ----
# conn is a mutable environment holding conn$con
run_step <- function(step_name, sql, conn, cfg, qc_sql = NULL, description = NULL,
                     step_num = NULL, total_steps = NULL, source_tables = NULL) {
  started_at <- Sys.time()

  progress_prefix <- if (!is.null(step_num) && !is.null(total_steps)) {
    sprintf("[Step %d/%d] ", step_num, total_steps)
  } else ""

  step_desc <- if (!is.null(description)) description else step_name
  cat("\n", DASH_60, "\n", sep = "")
  log_msg(progress_prefix, step_desc)

  if (!is.null(source_tables) && length(source_tables) > 0) {
    log_msg("  >> Reading from: ", paste(source_tables, collapse = ", "))
  }
  cat(DASH_60, "\n")
  flush.console()

  tryCatch({
    # A dropped connection cannot be repaired in place. The step SQL reads the
    # aliases materialize_to_personal_schema() creates, and those are
    # session-scoped -- a new session has none of them, so the retry fails on a
    # missing view and the real cause is buried. Stop and let the run restart.
    if (!db_ping(conn$con)) {
      stop(errorCondition(
        "Lost the Databricks connection. The session's views are gone; rerun the build.",
        class = c("fatal_error", "error", "condition")))
    }

    DBI::dbExecute(conn$con, sql)

    run_qc(conn$con, qc_sql)

    ended_at <- Sys.time()
    log_msg("  >> Completed in ", round(as.numeric(difftime(ended_at, started_at, units = "secs")), 1), "s")
    flush.console()

  }, error = function(e) {
    log_msg("STEP FAILED: ", step_name, " - ", conditionMessage(e))
    stop(e)
  })
}
