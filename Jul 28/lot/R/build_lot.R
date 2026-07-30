# Runner for the LOT build. Standalone: one module, pointed at a cohort table.
#
# The rules are the same for every cohort. What changes per run is which table
# is read and which prefix the outputs carry, and the caller supplies both.
# No cohort is named anywhere in this folder. Everything else is pinned below
# and checked before the first query.

`%||%` <- function(a, b) if (is.null(a)) b else a

# Settings that decide what a LOT run means. A different value here is a
# different result, so they are checked rather than defaulted. Change a value
# here and in config.csv together, deliberately.
CONTRACT <- list(
  catalog                     = "hive_metastore",
  cdm_schema                  = "clnprw_optum",
  codelist_dir                = "/mnt/code/codelist",
  use_quarterly_tables        = TRUE,
  # Picks the quarterly CDM tables, so a different date is different source
  # data for every read.
  study_end                   = "2025-06-30",
  censor_at_disenrollment     = FALSE,
  induction_window_days       = 60L,
  lot_n_induction_window_days = 30L,
  map_discon_gap_days         = 90L,
  medical_day_supply          = 28L,
  sct_auto_window_days        = 13L,
  sct_auto_gap_days           = 60L,
  sct_tandem_days             = 180L,
  cart_consolidation_days     = 45L,
  dsn                         = "RWDE",
  tbl_medical                 = "medical",
  tbl_med_proc                = "med_procedure",
  tbl_med_diag                = "med_diagnosis",
  tbl_rx                      = "rx"
)

# The columns LOT reads off whatever cohort table it is pointed at. Checked
# against the real table before any work starts, so a cohort that cannot drive
# LOT says so immediately instead of failing somewhere in the middle.
REQUIRED_COHORT_COLS <- c("PATID", "INDEX_DATE", "ENDDATE", "ENDDATE_CE",
                          "DEATH_DT", "GDR_CD", "YRDOB", "AGE_INDEX_YR",
                          "FU_DAYS", "FU_DAYS_CE")

# Bad values fail open: as.logical("Y") is NA, which reads as FALSE. An
# integer setting that will not parse becomes NA and silently widens a window.
BOOL_SETTINGS <- c("USE_QUARTERLY_TABLES", "CENSOR_AT_DISENROLLMENT",
                   "PERSIST_TO_SCHEMA")
INT_SETTINGS  <- c("INDUCTION_WINDOW_DAYS", "INDUCTION_WINDOW_DAYS_LOT_N",
                   "MAP_DISCON_GAP_DAYS", "MEDICAL_DAY_SUPPLY",
                   "SCT_AUTO_WINDOW_DAYS", "SCT_AUTO_GAP_DAYS",
                   "SCT_TANDEM_DAYS", "CART_CONSOLIDATION_DAYS")

check_settings <- function() {
  bad <- character(0)
  for (v in BOOL_SETTINGS) {
    x <- Sys.getenv(v, unset = "")
    if (nzchar(x) && !(toupper(x) %in% c("TRUE", "FALSE")))
      bad <- c(bad, paste0(v, "='", x, "' (want TRUE or FALSE)"))
  }
  for (v in INT_SETTINGS) {
    x <- Sys.getenv(v, unset = "")
    if (nzchar(x) && is.na(suppressWarnings(as.integer(x))))
      bad <- c(bad, paste0(v, "='", x, "' (want a whole number)"))
  }
  s <- Sys.getenv("PROJECT_WORK_SCHEMA", unset = "")
  if (grepl(".", s, fixed = TRUE))
    bad <- c(bad, paste0("PROJECT_WORK_SCHEMA='", s,
                         "' is catalog.schema; it wants a schema name"))
  e <- Sys.getenv("STUDY_END", unset = "")
  if (nzchar(e) && !grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", e))
    bad <- c(bad, paste0("STUDY_END='", e, "' (want YYYY-MM-DD)"))

  if (length(bad))
    stop("Settings that would build a different LOT:\n  ",
         paste(bad, collapse = "\n  "), call. = FALSE)
  invisible(TRUE)
}

# One schema for everything: <catalog>.<schema>. No schema is an error rather
# than a silently skipped write.
pin_output_schema <- function(cfg) {
  schema <- Sys.getenv("PROJECT_WORK_SCHEMA",
              unset = Sys.getenv("DOMINO_USER_NAME",
                unset = Sys.getenv("DOMINO_STARTING_USERNAME", unset = "")))
  if (!nzchar(schema))
    stop("No output schema. Set DOMINO_USER_NAME to your personal schema ",
         "(e.g. osk02156), or PROJECT_WORK_SCHEMA to override.", call. = FALSE)
  # It goes straight into table names, so check the value we resolved rather
  # than each variable it could have come from.
  if (!grepl("^[A-Za-z_][A-Za-z0-9_]*$", schema))
    stop("Output schema '", schema, "' is not a schema name.", call. = FALSE)
  cfg$work_schema <- schema
  cfg
}

# The caller says which table to read and what to call the outputs. This folder
# holds no cohort names of its own - that is what keeps it a package rather
# than part of one study.
pin_cohort <- function(cfg, cohort_table, prefix) {
  cohort_table <- trimws(as.character(cohort_table %||% ""))
  prefix       <- trimws(as.character(prefix %||% ""))
  if (!nzchar(cohort_table) || !nzchar(prefix))
    stop("LOT needs a cohort table and an output prefix.\n",
         "  Rscript build.R <COHORT_TABLE> <prefix_>\n",
         "  or set INPUT_COHORT_TABLE and OBJECT_PREFIX.", call. = FALSE)
  # Both end up in SQL identifiers, so keep them to what an identifier allows.
  if (!grepl("^[A-Za-z_][A-Za-z0-9_]*$", cohort_table))
    stop("Cohort table '", cohort_table, "' is not a table name. Give the ",
         "table only - the catalog and schema come from the settings.",
         call. = FALSE)
  if (!grepl("^[A-Za-z][A-Za-z0-9_]*_$", prefix))
    stop("Prefix '", prefix, "' should be a name ending in '_', e.g. mystudy_.",
         call. = FALSE)
  cfg$input_cohort_table <- cohort_table
  cfg$object_prefix      <- prefix
  cfg
}

# A cohort table missing a column LOT needs would fail deep into the build, so
# ask the table up front.
check_cohort_input <- function(con, cfg) {
  tbl  <- wrk(cfg$input_cohort_table)
  cols <- tryCatch(toupper(db_q(con, glue("DESCRIBE {tbl}"))[[1]]),
                   error = function(e)
                     stop("Cannot read the cohort table ", tbl, ": ",
                          conditionMessage(e), call. = FALSE))
  miss <- setdiff(REQUIRED_COHORT_COLS, cols)
  if (length(miss))
    stop(tbl, " cannot drive LOT. Missing: ", paste(miss, collapse = ", "),
         call. = FALSE)

  # The rules read this table row for row - no DISTINCT, no ranking. A repeated
  # patient would multiply their claims and their lines, so check the shape too,
  # not just the column names. ENDDATE_CE may be null: the primary branch uses
  # ENDDATE and the sensitivity branch falls back to it.
  q <- db_q(con, glue("
    SELECT count(*) AS n_rows,
           count(DISTINCT PATID) AS n_patients,
           sum(CASE WHEN PATID IS NULL THEN 1 ELSE 0 END) AS n_null_patid,
           sum(CASE WHEN INDEX_DATE IS NULL THEN 1 ELSE 0 END) AS n_null_index,
           sum(CASE WHEN ENDDATE IS NULL THEN 1 ELSE 0 END) AS n_null_end,
           sum(CASE WHEN ENDDATE < INDEX_DATE THEN 1 ELSE 0 END) AS n_end_before_index
    FROM {tbl}"))
  bad <- character(0)
  if (q$n_rows == 0)            bad <- c(bad, "it is empty")
  if (q$n_null_patid > 0)       bad <- c(bad, paste0(q$n_null_patid, " rows have no PATID"))
  if (q$n_null_index > 0)       bad <- c(bad, paste0(q$n_null_index, " rows have no INDEX_DATE"))
  if (q$n_null_end > 0)         bad <- c(bad, paste0(q$n_null_end, " rows have no ENDDATE"))
  if (q$n_end_before_index > 0) bad <- c(bad, paste0(q$n_end_before_index,
                                                     " rows end before they start"))
  if (q$n_rows != q$n_patients)
    bad <- c(bad, paste0(q$n_rows, " rows for ", q$n_patients,
                         " patients - one index per patient is required"))
  if (length(bad))
    stop(tbl, " cannot drive LOT: ", paste(bad, collapse = "; "), call. = FALSE)
  log_msg("  Cohort input OK: ", q$n_patients, " patients")
  invisible(TRUE)
}

check_lot_contract <- function(cfg) {
  wrong <- Filter(Negate(is.null), lapply(names(CONTRACT), function(k) {
    got <- cfg[[k]]
    if (isTRUE(all.equal(got, CONTRACT[[k]]))) NULL
    else paste0(k, " = ", format(got), " (want ", format(CONTRACT[[k]]), ")")
  }))
  if (length(wrong))
    stop("This build is defined as:\n  ", paste(unlist(wrong), collapse = "\n  "),
         call. = FALSE)
  # Without a prefix every run writes the same table names, so a second cohort
  # would overwrite the first instead of sitting beside it.
  if (!nzchar(cfg$object_prefix))
    stop("No output prefix. LOT outputs would collide with another cohort's.",
         call. = FALSE)
  if (!nzchar(cfg$input_cohort_table))
    stop("No cohort table to read.", call. = FALSE)
  if (!isTRUE(cfg$persist_to_schema))
    stop("PERSIST_TO_SCHEMA is FALSE, so nothing would be written. ",
         "Set it TRUE to build LOT.", call. = FALSE)
  invisible(TRUE)
}

# config.csv has to load before config_lot.R, which reads Sys.getenv() at
# source time.
load_lot_modules <- function(here) {
  source(file.path(here, "R", "load_inputs.R"))
  load_pipeline_inputs(here, "config.csv")
  for (f in c("config_lot.R", "db_utils_lot.R", "codelists_lot.R", "line_criteria.R"))
    source(file.path(here, "R", f))
  steps <- sort(list.files(file.path(here, "R", "steps"), "\\.R$", full.names = TRUE))
  for (f in steps) source(f)
  invisible(TRUE)
}

# The run. Phases in order, each one leaving temp views the next reads.
build_lot <- function(here, cohort_table, prefix) {
  check_settings()
  cfg <- pin_output_schema(cfg_defaults)
  cfg <- pin_cohort(cfg, cohort_table, prefix)
  check_lot_contract(cfg)
  # Every helper reads the config, so publish it before anything runs.
  set_lot_config(cfg)

  stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")
  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  log_msg("Connected. Run ID: ", run_id)
  log_msg("Configuration:")
  log_msg("  CDM Schema:        ", cfg$cdm_schema)
  log_msg("  Work Schema:       ", cfg$work_schema)
  log_msg("  Input Cohort:      ", cfg$input_cohort_table)
  log_msg("  Output Prefix:     ", cfg$object_prefix)
  log_msg("  Induction Window (LOT1):   ", cfg$induction_window_days, " days")
  log_msg("  Induction Window (LOT2-5): ", cfg$lot_n_induction_window_days, " days")
  log_msg("  Discon Gap (per-drug, MAP-level): ", cfg$map_discon_gap_days, " days")
  log_msg("  Medical Day Supply: ", cfg$medical_day_supply, " days")

  check_cohort_input(con, cfg)

  ctx <- phase_codelists(con)
  phase_patient_input(con)
  phase_mma_map(con, ctx)
  phase_lot1_base(con, ctx)
  phase_sct(con, ctx)
  phase_lot1_end(con, ctx)
  phase_qc(con, ctx)
  phase_persist(con, ctx)

  log_msg(SEP)
  log_msg("LOT1 complete for ", cfg$input_cohort_table, " -> ", cfg$object_prefix, "*")
  log_msg(SEP)
  invisible(TRUE)
}
