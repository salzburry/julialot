#!/usr/bin/env Rscript
# =============================================================================
# load_tables.R -- pull slim copies of the CDM sources into your own schema
# -----------------------------------------------------------------------------
#   Rscript "Jul 28/tools/load_tables.R"                    # study window, needed cols
#   Rscript "Jul 28/tools/load_tables.R" --years=2018:2022   # just a few years
#   Rscript "Jul 28/tools/load_tables.R" --patients=5000     # + a patient sample
#   Rscript "Jul 28/tools/load_tables.R" --dry-run           # print the SQL
#
# WHY: every script here reads the shared Optum CDM through cdm_src(), which
# resolves to catalog.clnprw_optum.t_<table>_2025q2 -- a CUMULATIVE table, all
# columns, all history, on a schema you cannot write to, whose physical name
# changes every quarter. That is a bad thing to iterate against.
#
# This copies only the COLUMNS the pipeline actually reads, only for the YEARS
# you ask for, into YOUR schema under stable names. `medical` goes from ~40
# columns of full history to 12 columns over the study window.
#
# ---------------------------------------------------------------------------
# NAMING -- so the rest of the stack just works
# ---------------------------------------------------------------------------
#     clnprw_optum.t_medical_2025q2        ->   <your schema>.medical
#     clnprw_optum.t_med_diagnosis_2025q2  ->   <your schema>.med_diagnosis
#     clnprw_optum.t_rx_2025q2             ->   <your schema>.rx
#
# The CDM base names are kept deliberately, with the t_/quarter decoration
# dropped, because that lets the WHOLE PIPELINE read your copies with two
# environment variables and no code change:
#
#     export OPTUM_CDM_SCHEMA=<your schema>
#     export USE_QUARTERLY_TABLES=FALSE
#
# cdm_src() then resolves to <your schema>.medical. Set SRC_PREFIX=src_ if you
# would rather tag them for browsing -- but then nothing can be redirected.
#
# ---------------------------------------------------------------------------
# WHAT IS SAFE TO NARROW, AND WHAT IS NOT
# ---------------------------------------------------------------------------
# Columns: derived from every cdm_src() call in the repo, per table (see the
# registry below). Verified against the live schema before any copy runs -- a
# missing column stops the load rather than producing a table that fails later.
#
# Dates: NOT one rule for all tables.
#   claims  (medical, med_diagnosis, med_procedure, rx, confinement)
#           filtered on their event date. The pipeline never scans outside
#           [study_start, study_end], so the default window is exact, not a
#           sample.
#   member_enrollment
#           filtered by OVERLAP, not by start date. A span running 2010-2020
#           covers the baseline; `ELIGEFF >= study_start` would throw it away
#           and silently break every CE criterion.
#   member_cont_enrollment, dod
#           NOT filtered. Demographics are picked by latest ELIGEND and death
#           can fall after study_end; filtering either would change which row
#           wins.
# =============================================================================

.here <- local({
  fa <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(fa)) dirname(normalizePath(
    gsub("~+~", " ", sub("^--file=", "", fa[1]), fixed = TRUE))) else getwd()
})

.apr30 <- Sys.getenv("APR30_DIR",
                     unset = file.path(dirname(dirname(.here)), "apr_30_2026"))
if (!dir.exists(file.path(.apr30, "R")))
  stop("cannot find the pipeline helpers at ", .apr30, "/R -- set APR30_DIR.",
       call. = FALSE)

library(glue); library(DBI); library(odbc)
.src <- function(f) source(file.path(.apr30, "R", f))
if (file.exists(file.path(.apr30, "R", "load_inputs.R"))) {
  .src("load_inputs.R")
  # Honour pipeline_inputs.csv so this tool sees the SAME catalog, schemas and
  # study window as the pipeline rather than its own idea of them.
  load_pipeline_inputs(c(.apr30, dirname(.apr30)))
}
.src("config_lot.R")
.src("db_utils_lot.R")

# The registry and the SQL builders (pure; separately testable).
source(file.path(.here, "load_tables_spec.R"))

# =============================================================================
# guards
# =============================================================================
assert_writable_target <- function() {
  stop_if_blank(cfg$work_schema,
    "no work schema configured. Set PROJECT_WORK_SCHEMA (or WORK_SCHEMA).")
  if (identical(tolower(trimws(cfg$work_schema)), tolower(trimws(cfg$cdm_schema))))
    stop("refusing to run: work schema == CDM schema (", cfg$work_schema,
         "). This tool writes tables; the CDM is read-only.", call. = FALSE)
  invisible(TRUE)
}

# Verify every projected column exists BEFORE copying anything. A typo here
# would otherwise produce a table that looks fine and fails three stages later.
assert_columns <- function(con, tables) {
  bad <- list()
  for (t in tables) {
    src  <- cdm_src(t$name)
    have <- toupper(names(db_q(con, glue("SELECT * FROM {src} WHERE 1 = 0"))))
    need <- toupper(c(t$cols, t$date$col, t$date$from, t$date$to))
    miss <- setdiff(need, have)
    if (length(miss)) bad[[t$name]] <- miss
  }
  if (length(bad)) {
    msg <- paste(vapply(names(bad), function(n)
      paste0("  ", n, ": ", paste(bad[[n]], collapse = ", ")), character(1)),
      collapse = "\n")
    stop("these columns are not in the source tables:\n", msg,
         "\nThe registry in this file is out of date with the CDM. Fix it ",
         "before loading -- do not fall back to --all-columns and hope.",
         call. = FALSE)
  }
  invisible(TRUE)
}

# =============================================================================
# patient set (optional) -- chosen once, reused for every table so the copy is
# referentially consistent. Ordered by hash(PATID) so it is REPRODUCIBLE: the
# same --patients value gives the same ids every run.
# =============================================================================
build_patient_set <- function(con, spec, dry) {
  if (identical(spec, "all")) return(invisible(NULL))
  sql <- if (grepl("^from:", spec)) {
    s <- sub("^from:", "", spec); if (!grepl("\\.", s)) s <- wrk(s)
    glue("CREATE OR REPLACE TABLE {wrk(PATIENTS_TBL)} AS
          SELECT DISTINCT cast(PATID as string) AS PATID FROM {s}")
  } else {
    glue("CREATE OR REPLACE TABLE {wrk(PATIENTS_TBL)} AS
          SELECT PATID FROM (
            SELECT DISTINCT cast(PATID as string) AS PATID
            FROM {cdm_src('member_enrollment')}
          ) ORDER BY hash(PATID) LIMIT {as.integer(spec)}")
  }
  if (dry) { cat("\n-- [patients]\n", sql, ";\n", sep = ""); return(invisible(NULL)) }
  log_msg("Selecting the patient set -> ", wrk(PATIENTS_TBL))
  db_exec(con, sql)
  n <- db_q(con, glue("SELECT count(*) AS n FROM {wrk(PATIENTS_TBL)}"))$n
  if (!isTRUE(n > 0)) stop("the patient set is empty.", call. = FALSE)
  log_msg("  ", format(n, big.mark = ","), " patients")
  invisible(NULL)
}

# =============================================================================
table_exists <- function(con, fq) isTRUE(tryCatch({
  db_q(con, glue("SELECT 1 FROM {fq} LIMIT 1")); TRUE
}, error = function(e) FALSE))

# Fail CLOSED: a copy that errors must not leave the previous table in place
# looking current. That is how a schema ends up mixed-vintage and unattributable.
copy_one <- function(con, t, args, win, use_patients) {
  fq <- target(t$name)
  if (!args$refresh && table_exists(con, fq)) {
    n <- db_q(con, glue("SELECT count(*) AS n FROM {fq}"))$n
    log_msg(sprintf("  SKIP  %-24s %14s rows (exists; --refresh to rebuild)",
                    t$name, format(n, big.mark = ",")))
    return(list(table = t$name, rows = n, action = "skipped"))
  }
  t0 <- Sys.time()
  db_exec(con, copy_sql(t, args, win, use_patients))
  n <- db_q(con, glue("SELECT count(*) AS n FROM {fq}"))$n
  log_msg(sprintf("  OK    %-24s %14s rows  %6.1fs  [%d cols]", t$name,
                  format(n, big.mark = ","),
                  as.numeric(difftime(Sys.time(), t0, units = "secs")),
                  if (args$all_columns) NA_integer_ else length(t$cols)))
  if (!isTRUE(n > 0))
    log_msg("  WARN: ", t$name, " copied 0 rows -- check the window and the sample.")
  list(table = t$name, rows = n, action = "loaded")
}

# What was copied, from where, which columns, which window, when. Without this a
# schema full of copies is unattributable a week later.
write_manifest <- function(con, results, args, win, use_patients) {
  q <- function(x) paste0("'", gsub("'", "''", x), "'")
  rows <- vapply(results, function(r) {
    t <- Filter(function(x) identical(x$name, r$table), SOURCE_TABLES)[[1]]
    paste0("(", paste(q(r$table), q(cdm_src(t$name)), q(target(t$name)),
                      as.integer(r$rows), q(r$action),
                      q(if (args$all_columns) "ALL" else paste(t$cols, collapse = " ")),
                      q(if (args$all_years || is.null(t$date)) "all"
                        else paste0(win$lo, "..", win$hi)),
                      q(if (use_patients) args$patients else "all"),
                      q(format(Sys.time(), "%Y-%m-%d %H:%M:%S")),
                      sep = ", "), ")")
  }, character(1))
  db_exec(con, glue("
    CREATE OR REPLACE TABLE {wrk(MANIFEST_TBL)} (
      table_name STRING, source_table STRING, target_table STRING,
      n_rows BIGINT, action STRING, columns_kept STRING,
      date_window STRING, patient_filter STRING, loaded_at STRING)"))
  db_exec(con, glue("INSERT INTO {wrk(MANIFEST_TBL)} VALUES {paste(rows, collapse = ', ')}"))
  log_msg("Manifest -> ", wrk(MANIFEST_TBL))
}

# =============================================================================
main <- function() {
  args <- parse_args()
  assert_writable_target()
  win  <- window_bounds(args)
  use_patients <- !identical(args$patients, "all")

  tables <- SOURCE_TABLES
  if (nzchar(args$only)) {
    want <- trimws(strsplit(args$only, ",", fixed = TRUE)[[1]])
    known <- vapply(SOURCE_TABLES, `[[`, character(1), "name")
    if (length(setdiff(want, known)))
      stop("unknown table(s): ", paste(setdiff(want, known), collapse = ", "),
           ". Known: ", paste(known, collapse = ", "), call. = FALSE)
    tables <- Filter(function(t) t$name %in% want, SOURCE_TABLES)
  }

  cat(strrep("=", 78), "\n", sep = "")
  cat("LOAD CDM SOURCES -> ", cfg$catalog, ".", cfg$work_schema, "\n", sep = "")
  cat("  from      : ", cfg$cdm_schema,
      if (isTRUE(cfg$use_quarterly_tables))
        paste0("  (quarterly: ", get_quarter_suffix(cfg$study_end), ")") else "",
      "\n", sep = "")
  cat("  columns   : ", if (args$all_columns) "ALL (--all-columns)"
                        else "only what the pipeline reads", "\n", sep = "")
  cat("  dates     : ", if (args$all_years) "ALL (--all-years)"
                        else paste0(win$lo, " .. ", win$hi, "   ", win$label),
      "\n", sep = "")
  cat("  patients  : ", args$patients, "\n", sep = "")
  cat(strrep("-", 78), "\n", sep = "")
  for (t in tables)
    cat(sprintf("  %-26s %2s cols  %-9s  %s\n", target(t$name),
                if (args$all_columns) "*" else length(t$cols),
                if (args$all_years || is.null(t$date)) "all dates"
                else if (!is.null(t$date$col)) t$date$col else "overlap",
                t$why))
  cat(strrep("=", 78), "\n", sep = "")

  if (args$dry_run) {
    build_patient_set(NULL, args$patients, dry = TRUE)
    for (t in tables)
      cat("\n-- [", t$name, "] ", t$why, "\n",
          copy_sql(t, args, win, use_patients), ";\n", sep = "")
    return(invisible(NULL))
  }

  stop_if_blank(cfg$pwd, "DATABRICKS_PWD is not set.")
  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  if (!args$all_columns) assert_columns(con, tables)
  build_patient_set(con, args$patients, dry = FALSE)

  log_msg("Copying ", length(tables), " tables...")
  results <- lapply(tables, copy_one, con = con, args = args, win = win,
                    use_patients = use_patients)
  write_manifest(con, results, args, win, use_patients)

  cat("\n", strrep("=", 78), "\n", sep = "")
  cat(sum(vapply(results, function(r) r$action == "loaded", logical(1))),
      " loaded, ",
      sum(vapply(results, function(r) r$action == "skipped", logical(1))),
      " skipped.  Manifest: ", wrk(MANIFEST_TBL), "\n", sep = "")
  if (!nzchar(PREFIX)) {
    cat("\nRun the pipeline against these copies:\n\n")
    cat("    export OPTUM_CDM_SCHEMA=", cfg$work_schema, "\n", sep = "")
    cat("    export USE_QUARTERLY_TABLES=FALSE\n\n")
  }
  exact <- !use_patients && !nzchar(args$years) && !args$all_columns
  cat(if (exact)
        paste0("This is an EXACT slice: the study window is what the pipeline\n",
               "scans anyway, and the dropped columns are never read. Counts\n",
               "should match production.\n")
      else
        paste0("NOT an exact slice",
               if (use_patients) " (patient sample)" else "",
               if (nzchar(args$years)) " (narrowed years)" else "",
               " -- counts will NOT match production.\n"))
  cat(strrep("=", 78), "\n", sep = "")
  invisible(results)
}

if (!interactive()) main()
