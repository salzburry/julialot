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
  allo_lot_span               = "single_day",
  max_lot                     = 5L,
  dsn                         = "RWDE",
  tbl_medical                 = "medical",
  tbl_med_proc                = "med_procedure",
  tbl_med_diag                = "med_diagnosis",
  tbl_rx                      = "rx"
)

# Code-list checks a run may waive by name. A single switch for all of them
# meant waiving one expected condition also waived the dangerous ones.
WAIVABLE_CHECKS <- c("orphan_meds", "uncoded_meds", "code_types", "multi_class",
                     "code_to_med", "bad_ndc", "rollup_defs", "blank_keys",
                     "subs_substitute", "subs_original", "ndc_shape",
                     "class_agreement")

codelist_waivers <- function() {
  v <- trimws(strsplit(Sys.getenv("CODELIST_WAIVERS", unset = ""), "[,|]")[[1]])
  v[nzchar(v)]
}

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
                   "SCT_TANDEM_DAYS", "CART_CONSOLIDATION_DAYS", "MAX_LOT")

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
  w <- setdiff(codelist_waivers(), WAIVABLE_CHECKS)
  if (length(w))
    bad <- c(bad, paste0("CODELIST_WAIVERS names no such check: ",
                         paste(w, collapse = ", "), " (choose from ",
                         paste(WAIVABLE_CHECKS, collapse = ", "), ")"))
  a <- Sys.getenv("ALLO_LOT_SPAN", unset = "")
  if (nzchar(a) && !a %in% c("single_day", "extend_to_next"))
    bad <- c(bad, paste0("ALLO_LOT_SPAN='", a,
                         "' (want single_day or extend_to_next)"))

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

  # LOT1 tables are replaced before LOT2-5 runs, so a failure in between leaves
  # new LOT1 output beside an older LOT_LONG. Splitting the persist step would
  # break the line-for-line port, so instead every run says what state it is
  # in: nothing here is complete until the last line below says so.
  write_build_status(con, cfg, "started")
  on.exit(if (!isTRUE(getOption("lot_complete", FALSE)))
            try(write_build_status(con, cfg, "failed"), silent = TRUE), add = TRUE)
  options(lot_complete = FALSE)

  ctx <- phase_codelists(con)
  phase_patient_input(con)
  phase_mma_map(con, ctx)
  phase_lot1_base(con, ctx)
  phase_sct(con, ctx)
  phase_lot1_sct(con, ctx)
  phase_lot1_end(con, ctx)
  phase_qc(con, ctx)
  check_lot1_invariants(con, cfg)
  phase_persist(con, ctx)

  # prepare_lot_inputs() exists to rebuild the session views when LOT2-5 runs
  # on its own. LOT1 has just built them here, and rebuilding means re-scanning
  # medical, procedure and diagnosis for SCT all over again - so only do it if
  # something is actually missing.
  if (!lot_inputs_present(con)) {
    log_msg("Session views missing; rebuilding them for LOT2-5.")
    prepare_lot_inputs(con)
  } else {
    log_msg("Session views from LOT1 are still here; not rebuilding them.")
    materialize_sct_views(con)
  }
  build_lot2_5(con,
               induction_window_days   = cfg$lot_n_induction_window_days,
               cart_consolidation_days = cfg$cart_consolidation_days,
               sct_tandem_days         = cfg$sct_tandem_days,
               allo_lot_span           = cfg$allo_lot_span,
               max_lot                 = cfg$max_lot)

  # Validate before deriving: publishing the criteria tables first would leave
  # them behind, built from a LOT_LONG that then failed its checks.
  check_lot_long(con, cfg)
  phase_line_criteria(con, cfg)
  check_run_recorded(con, cfg)
  write_build_status(con, cfg, "complete")
  # Only after the write succeeded. Setting it first meant a failed write left
  # the run marked "started" with on.exit believing it had finished.
  options(lot_complete = TRUE)

  log_msg(SEP)
  log_msg("LOT complete for ", cfg$input_cohort_table, " -> ", cfg$object_prefix, "*")
  log_msg(SEP)
  invisible(TRUE)
}

# The views LOT2-5 reads. All present means LOT1 ran in this session.
LOT2_5_INPUT_VIEWS <- c("lot_patient_input", "mma_rollup", "permissible_subs",
                        "sct_codelist", "sct_claims_raw", "tx_auto_dates",
                        "tx_allo_cart_dates", "map_stacked", "lot1_sct",
                        "lot1_base_end")

# Ask the catalogue, not the data. "SELECT 1 FROM v LIMIT 1" on a lazy view
# runs the view - and three of these are raw CDM scans, so the existence check
# itself would have cost real time.
lot_inputs_present <- function(con) {
  have <- tryCatch(tolower(db_q(con, "SHOW VIEWS")$viewName),
                   error = function(e) NULL)
  # If the catalogue cannot answer, say no: rebuilding is slow but correct.
  if (is.null(have)) return(FALSE)
  all(tolower(LOT2_5_INPUT_VIEWS) %in% have)
}

# LOT1 leaves these three as views over the raw CDM, and LOT2-5 reads them
# once per line - roughly 8 AUTO aggregates and 20 SCT scans if left lazy.
# sct_claims_raw goes first, so the other two write from a table.
SCT_MATERIALIZE <- list(
  list(view = "sct_claims_raw",     name = "SCT_CLAIMS_RAW"),
  list(view = "tx_auto_dates",      name = "TX_AUTO_DATES"),
  list(view = "tx_allo_cart_dates", name = "TX_ALLO_CART_DATES")
)

materialize_sct_views <- function(con) {
  for (mv in SCT_MATERIALIZE) {
    t0 <- Sys.time()
    run_step(con, paste0("L20_materialize_", tolower(mv$name)),
             glue("CREATE OR REPLACE TABLE {lot_out(mv$name)} AS SELECT * FROM {mv$view}"),
             qc = glue("SELECT count(*) AS n_rows, count(DISTINCT PATID) AS n_patients
                        FROM {lot_out(mv$name)}"))
    db_exec(con, glue(
      "CREATE OR REPLACE TEMPORARY VIEW {mv$view} AS SELECT * FROM {lot_out(mv$name)}"))
    log_msg("  ", mv$name, " materialized in ",
            round(as.numeric(difftime(Sys.time(), t0, units = "secs")), 1), " s")
  }
  log_msg("SCT views materialized; LOT2-5 reads tables, not CDM scans.")
  invisible(TRUE)
}

# One row per run saying whether its outputs belong together. Without it a
# failed run leaves tables that look complete.
BUILD_STATUS_COLS <- c(
  RUN_ID = "STRING", INPUT_COHORT_TABLE = "STRING", OBJECT_PREFIX = "STRING",
  STATE = "STRING", CODELIST_WAIVERS = "STRING", UPDATED_AT = "TIMESTAMP")

write_build_status <- function(con, cfg, state) {
  tbl  <- lot_out("LOT_BUILD_STATUS")
  cols <- names(BUILD_STATUS_COLS)
  db_exec(con, glue("CREATE TABLE IF NOT EXISTS {tbl} (",
                    paste(cols, BUILD_STATUS_COLS, collapse = ", "), ")"))

  # CREATE TABLE IF NOT EXISTS does nothing to a table an earlier version of
  # this package left behind, so a column added since is still absent. Naming
  # the columns in the INSERT below stops a positional mis-fill - it cannot
  # supply a column that is not there, and the insert would simply fail. Add
  # it, the way LOT_RUN_METADATA does in 08_persist. Look before adding:
  # adding a column that already exists is an error.
  have <- tryCatch({
    d  <- db_q(con, glue("DESCRIBE {tbl}"))
    cn <- intersect(c("col_name", "COL_NAME", "name", "NAME"), names(d))
    if (length(cn)) toupper(trimws(as.character(d[[cn[1]]]))) else character(0)
  }, error = function(e) character(0))
  # No answer means DESCRIBE failed, not that the table has no columns. Acting
  # on that would try to add all six to a table that already has them.
  for (m in if (length(have)) setdiff(cols, have) else character(0)) {
    tryCatch({
      db_exec(con, glue("ALTER TABLE {tbl} ADD COLUMNS ({m} {BUILD_STATUS_COLS[[m]]})"))
      log_msg("  Build status schema evolution: added ", m)
    }, error = function(e) {
      msg <- conditionMessage(e)
      # Unlike the metadata table, every one of these is in the INSERT, so a
      # column we could not add is a failure now rather than a warning.
      if (!grepl("already exists|AlreadyExists|FIELD_ALREADY_EXISTS",
                 msg, ignore.case = TRUE))
        stop("Cannot add ", m, " to ", tbl, ": ", msg, call. = FALSE)
    })
  }

  db_exec(con, glue("DELETE FROM {tbl} WHERE RUN_ID = '{run_id}'"))
  waivers <- paste(codelist_waivers(), collapse = "|")
  vals <- c(RUN_ID             = glue("'{run_id}'"),
            INPUT_COHORT_TABLE = glue("'{cfg$input_cohort_table}'"),
            OBJECT_PREFIX      = glue("'{cfg$object_prefix}'"),
            STATE              = glue("'{state}'"),
            CODELIST_WAIVERS   = glue("'{waivers}'"),
            UPDATED_AT         = "current_timestamp()")
  # One declaration drives the CREATE, the upgrade and the INSERT, so they
  # cannot drift apart again - a column added to BUILD_STATUS_COLS with no
  # value here stops the build rather than reaching the warehouse.
  stopifnot(identical(names(vals), cols))
  db_exec(con, glue("INSERT INTO {tbl} ({paste(cols, collapse = ', ')}) ",
                    "VALUES ({paste(vals, collapse = ', ')})"))
  log_msg("Build status: ", state, " (run ", run_id, ")")
  invisible(TRUE)
}

# The QC phase reports these and carries on - it prints "** BUG **" and the run
# still finishes. They are not judgement calls: each one is impossible unless
# something upstream is wrong, so re-run them here where a breach stops the
# build. The distributions and coverage tables in phase_qc stay informational.
LOT1_INVARIANTS <- list(
  list(name = "MAP ends before it starts",
       sql = "SELECT count(*) AS n FROM map_stacked WHERE MAP_END_DT < MAP_START_DT"),
  list(name = "MAP end is not the later runout",
       sql = "SELECT count(*) AS n FROM map_stacked
              WHERE MAP_END_DT <> greatest(
                coalesce(MAP_RX_RUNOUT_DT, cast('1900-01-01' as date)),
                coalesce(MAP_MED_RUNOUT_DT, cast('1900-01-01' as date)))
                AND MAP_END_DT IS NOT NULL"),
  list(name = "LOT1 ends after observation",
       sql = "SELECT count(*) AS n FROM lot1_base_end lb
              INNER JOIN lot_patient_input p ON lb.PATID = p.PATID
              WHERE lb.LOT1_BASE_END_DT > p.OBS_END_DT"),
  list(name = "AUTO transplant both tandem and single",
       sql = "SELECT count(*) AS n FROM lot1_sct
              WHERE LOT1_SCT_AUTO_TAND_FLG = 1 AND LOT1_SCT_AUTO_SING_FLG = 1"),
  list(name = "AUTO transplant before LOT1 started",
       sql = "SELECT count(*) AS n FROM lot1_sct sct
              INNER JOIN lot1_base lb ON sct.PATID = lb.PATID
              WHERE sct.LOT1_TX_AUTO_DT_1 IS NOT NULL
                AND sct.LOT1_TX_AUTO_DT_1 < lb.LOT1_START_DT")
)

check_lot1_invariants <- function(con, cfg) {
  bad <- character(0)
  for (iv in LOT1_INVARIANTS) {
    # No tryCatch: a check that cannot run is not a check that passed.
    n <- db_q(con, iv$sql)$n
    if (is.na(n) || n > 0) bad <- c(bad, paste0(iv$name, ": ", n))
  }
  if (length(bad))
    stop("LOT1 is internally inconsistent:\n  ", paste(bad, collapse = "\n  "),
         call. = FALSE)
  log_msg("LOT1 invariants OK (", length(LOT1_INVARIANTS), " checked)")
  invisible(TRUE)
}

# 08_persist.R writes the metadata and QC summary inside a tryCatch, so a
# failure there only logs a warning. Rather than edit the ported file, check
# the row actually arrived - a run with no record of how it was configured is
# not a run anyone can validate later.
check_run_recorded <- function(con, cfg) {
  for (t in c("LOT_RUN_METADATA", "LOT_QC_SUMMARY")) {
    n <- tryCatch(db_q(con, glue(
           "SELECT count(*) AS n FROM {lot_out(t)} WHERE RUN_ID = '{run_id}'"))$n,
         error = function(e) 0L)
    if (is.na(n) || n < 1)
      stop("This run left no row in ", lot_out(t), ". The outputs exist but ",
           "nothing records how they were built.", call. = FALSE)
  }
  log_msg("Run recorded in LOT_RUN_METADATA and LOT_QC_SUMMARY")
  invisible(TRUE)
}

# LOT_LONG invariants. These are structural, not judgement calls, so a breach
# stops the build rather than printing INVESTIGATE.
check_lot_long <- function(con, cfg) {
  t <- lot_out("LOT_LONG")
  q <- db_q(con, glue("
    SELECT count(*) AS n_rows,
           count(DISTINCT PATID) AS n_patients,
           sum(CASE WHEN LOT_BASE_END_DT < LOT_START_DT THEN 1 ELSE 0 END) AS n_end_before_start,
           sum(CASE WHEN LOT_NUM < 1 OR LOT_NUM > {cfg$max_lot} THEN 1 ELSE 0 END) AS n_bad_lot_num
    FROM {t}"))
  d <- db_q(con, glue("
    SELECT count(*) AS n FROM (
      SELECT PATID, LOT_NUM FROM {t} GROUP BY PATID, LOT_NUM HAVING count(*) > 1)"))$n
  # A line has to start after the previous one ended. Every LOT_N candidate is
  # taken strictly after PREV_END_DT, so anything else means the chain broke.
  seq_bad <- db_q(con, glue("
    SELECT count(*) AS n FROM (
      SELECT LOT_START_DT,
             lag(LOT_BASE_END_DT) OVER (PARTITION BY PATID ORDER BY LOT_NUM) AS prev_end
      FROM {t})
    WHERE prev_end IS NOT NULL AND LOT_START_DT <= prev_end"))$n
  # And no line may run past the patient's observation. Every branch of the
  # end-date rule is bounded by OBS_END_DT, so a breach is a real defect.
  past_obs <- db_q(con, glue("
    SELECT count(*) AS n
    FROM {t} l
    INNER JOIN lot_patient_input p ON l.PATID = p.PATID
    WHERE l.LOT_BASE_END_DT > p.OBS_END_DT"))$n
  g <- db_q(con, glue("
    SELECT count(*) AS n FROM (
      SELECT PATID, min(LOT_NUM) AS lo, max(LOT_NUM) AS hi, count(DISTINCT LOT_NUM) AS k
      FROM {t} GROUP BY PATID HAVING lo <> 1 OR k <> hi - lo + 1)"))$n
  bad <- character(0)
  if (q$n_rows == 0)           bad <- c(bad, "it is empty")
  if (d > 0)                   bad <- c(bad, paste0(d, " duplicate (PATID, LOT_NUM)"))
  if (q$n_end_before_start > 0) bad <- c(bad, paste0(q$n_end_before_start, " lines end before they start"))
  if (q$n_bad_lot_num > 0)     bad <- c(bad, paste0(q$n_bad_lot_num, " lines outside 1..", cfg$max_lot))
  if (g > 0)                   bad <- c(bad, paste0(g, " patients whose lines do not run 1..n"))
  if (seq_bad > 0)             bad <- c(bad, paste0(seq_bad, " lines starting on or before the previous line's end"))
  if (past_obs > 0)            bad <- c(bad, paste0(past_obs, " lines ending after the patient's observation"))
  if (length(bad))
    stop(t, " is not usable: ", paste(bad, collapse = "; "), call. = FALSE)
  log_msg("LOT_LONG OK: ", q$n_rows, " lines for ", q$n_patients, " patients")
  invisible(TRUE)
}

# The criteria layer, on top of LOT_LONG. With no criteria declared both
# tables are copies, so downstream can always read them.
phase_line_criteria <- function(con, cfg) {
  run_step(con, "L40_lot_long_allflags",
           line_criteria_flags_sql(cfg, "lot_long", "lot_long_allflags"))
  run_step(con, "L41_lot_long_final",
           line_criteria_final_sql(cfg, "lot_long_allflags", "lot_long_final"))
  # Both are tables, always. Writing them as views when no criterion is
  # declared would save two writes, but Spark refuses a persistent view over a
  # temporary one (INVALID_TEMP_OBJ_REFERENCE) and these are built from temp
  # views - so that "optimization" failed every run.
  for (v in list(list(view = "lot_long_allflags", name = "LOT_LONG_ALLFLAGS"),
                 list(view = "lot_long_final",    name = "LOT_LONG_FINAL"))) {
    run_step(con, paste0("L42_persist_", tolower(v$name)),
             glue("CREATE OR REPLACE TABLE {lot_out(v$name)} AS SELECT * FROM {v$view}"),
             qc = glue("SELECT count(*) AS n_rows FROM {lot_out(v$name)}"))
  }
  invisible(TRUE)
}
