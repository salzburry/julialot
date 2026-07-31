# Runner for the NDMM (1L newly-diagnosed) cohort. Standalone: one module,
# pointed at a cohort prefix.
#
# The rules in R/steps are a port of the cohort half of
# apr_30_2026/06_ndmm_dashboard.R. What is here is the runner around them,
# which is not a port of anything: the source's prepare_ndmm_cohort() is
# entangled with the dashboard it feeds, and skips a filter whose inputs it
# cannot read. This build stops instead - a count nobody can reproduce is
# worse than no count.

`%||%` <- function(a, b) if (is.null(a)) b else a

# Settings that decide what the cohort means. A different value here is a
# different cohort, so they are checked rather than defaulted.
CONTRACT <- list(
  catalog              = "hive_metastore",
  cdm_schema           = "clnprw_optum",
  codelist_dir         = "/mnt/code/codelist",
  use_quarterly_tables = TRUE,
  study_end            = "2025-06-30",
  # The 1L eligible-treatment period opens here (protocol S6.2.1.1).
  lot1_from            = "2017-01-01",
  # 12 months of CE and of baseline before the 1L index date.
  pre_lot1_days        = 365L,
  # Days after index a no-gap span must cover for the follow-up CE. Zero is
  # the index date itself - one day - which the study team confirmed for 1L,
  # overriding the protocol's three months. See README.
  fu_ce_days           = 0L,
  gap_days             = 30L,
  # The pregnancy scan runs over [study_start, study_end], so this moves who is
  # excluded. It reaches the SQL through NDMM_STUDY_START, which reads the same
  # environment variable.
  study_start          = "2015-07-01",
  # What Jul 28/overall writes. Its config.csv sets FINAL_TABLE_NAME to this;
  # the name is pinned here because reading the wrong table would build a
  # different cohort, not fail.
  cohort_table         = "OVERALL_COH_FINAL",
  tbl_medical          = "medical",
  tbl_med_proc         = "med_procedure",
  tbl_med_diag         = "med_diagnosis",
  tbl_rx               = "rx",
  tbl_confinement      = "confinement",
  tbl_member_enroll    = "member_enrollment"
)

# The upstream tables this build reads, and which build writes each. It cannot
# make any of them, so it says which one is missing rather than failing inside
# a join twenty statements later. The cohort table is named by cfg, because
# Jul 28/overall's own config decides what it is called.
upstream_tables <- function(cfg) {
  setNames(list("Jul 28/lot", "Jul 28/lot", "Jul 28/overall"),
           c("LOT_LONG", "MAP_STACKED", cfg$cohort_table))
}

# What the run writes. All prefixed, so two cohorts sit side by side.
OUTPUTS <- c("NDMM_FLAGS_ALL", "NDMM_LOT_LONG_FILT", "NDMM_COHORT",
             "NDMM_ATTRITION", "NDMM_CODELIST_METADATA", "NDMM_BUILD_STATUS")

check_settings <- function() {
  bad <- character(0)
  for (v in c("STUDY_END", "LOT1_FROM", "STUDY_START")) {
    x <- trimws(Sys.getenv(v, unset = ""))
    if (nzchar(x) && !grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", x))
      bad <- c(bad, paste0(v, "='", x, "' (want YYYY-MM-DD)"))
  }
  for (v in c("PRE_LOT1_DAYS", "FU_CE_DAYS", "GAP_DAYS")) {
    x <- trimws(Sys.getenv(v, unset = ""))
    # The text, not what coercion makes of it: as.integer("60.5") is 60.
    if (nzchar(x) && !grepl("^[0-9]+$", x))
      bad <- c(bad, paste0(v, "='", x, "' (want a whole number)"))
  }
  r <- Sys.getenv("DOMINO_RUN_ID", unset = "")
  if (nzchar(r) && !grepl("^[A-Za-z0-9_.-]+$", r))
    bad <- c(bad, paste0("DOMINO_RUN_ID='", r, "' (want letters, digits, _ . -)"))
  if (length(bad))
    stop("Settings that would build a different cohort:\n  ",
         paste(bad, collapse = "\n  "), call. = FALSE)
  invisible(TRUE)
}

pin_output_schema <- function(cfg) {
  schema <- Sys.getenv("PROJECT_WORK_SCHEMA",
              unset = Sys.getenv("DOMINO_USER_NAME",
                unset = Sys.getenv("DOMINO_STARTING_USERNAME", unset = "")))
  if (!nzchar(schema))
    stop("No output schema. Set DOMINO_USER_NAME to your personal schema, ",
         "or PROJECT_WORK_SCHEMA to override.", call. = FALSE)
  if (!grepl("^[A-Za-z_][A-Za-z0-9_]*$", schema))
    stop("Output schema '", schema, "' is not a schema name.", call. = FALSE)
  cfg$work_schema <- schema
  cfg
}

# The caller says which cohort. Every table read and written carries the
# prefix, so this folder names no cohort of its own.
pin_prefix <- function(cfg, prefix) {
  prefix <- trimws(as.character(prefix %||% ""))
  if (!nzchar(prefix))
    stop("NDMM needs an output prefix.\n",
         "  Rscript build.R <prefix_>\n",
         "  or set OBJECT_PREFIX.", call. = FALSE)
  if (!grepl("^[A-Za-z][A-Za-z0-9_]*_$", prefix))
    stop("Prefix '", prefix, "' should be a name ending in '_', e.g. mystudy_.",
         call. = FALSE)
  cfg$object_prefix <- prefix
  cfg
}

check_contract <- function(cfg) {
  wrong <- Filter(Negate(is.null), lapply(names(CONTRACT), function(k) {
    if (isTRUE(all.equal(cfg[[k]], CONTRACT[[k]]))) NULL
    else paste0(k, " = ", format(cfg[[k]]), " (want ", format(CONTRACT[[k]]), ")")
  }))
  if (length(wrong))
    stop("This cohort is defined as:\n  ", paste(unlist(wrong), collapse = "\n  "),
         call. = FALSE)
  invisible(TRUE)
}

# Every raw CDM table a step reads. member_enrollment is the first one used -
# both enrollment-span builds sit on it - and it was missing from this list,
# so the preflight passed and the run then failed inside phase one.
raw_tables <- function(cfg) {
  c(cfg$tbl_medical, cfg$tbl_rx, cfg$tbl_med_diag, cfg$tbl_med_proc,
    cfg$tbl_confinement, cfg$tbl_member_enroll)
}

# Every upstream table, before any work. The source skipped a filter whose
# inputs it could not read and carried on, which produces a cohort that is
# smaller than it should be with nothing in the output saying so.
check_upstream <- function(con, cfg) {
  missing <- character(0)
  up <- upstream_tables(cfg)
  for (t in names(up)) {
    got <- tryCatch({ db_q(con, glue("SELECT 1 FROM {wrk(t)} LIMIT 1")); TRUE },
                    error = function(e) FALSE)
    if (!got) missing <- c(missing, paste0(wrk(t), " (built by ", up[[t]], ")"))
  }
  raw <- raw_tables(cfg)
  for (t in raw) {
    got <- tryCatch({ db_q(con, glue("SELECT 1 FROM {cdm_src(t)} LIMIT 1")); TRUE },
                    error = function(e) FALSE)
    if (!got) missing <- c(missing, cdm_src(t))
  }
  if (length(missing))
    stop("Cannot read:\n  ", paste(missing, collapse = "\n  "),
         "\nEvery NDMM filter needs its input. Skipping one would drop patients ",
         "the criteria do not exclude, and the attrition would not say so.",
         call. = FALSE)
  log_msg("Upstream inputs present (", length(up), " built, ",
          length(raw), " raw)")
  invisible(TRUE)
}

# The SQL does not read cfg. It reads the NDMM_* constants in
# nndm_constants.R, which is ported code with its own environment variables -
# NDMM_LOT1_FROM among them. So a contract checked against cfg proves nothing
# about the query that runs. This compares the constants themselves, after the
# modules are loaded, and is the only check that speaks for the SQL.
CONSTANT_SETTINGS <- list(
  list(const = "NDMM_LOT1_FROM",     cfg = "lot1_from",
       note = "set by NDMM_LOT1_FROM, not LOT1_FROM"),
  list(const = "NDMM_PRE_LOT1_DAYS", cfg = "pre_lot1_days", note = ""),
  list(const = "NDMM_FU_CE_DAYS",    cfg = "fu_ce_days",    note = ""),
  list(const = "NDMM_GAP_DAYS",      cfg = "gap_days",      note = ""),
  list(const = "NDMM_STUDY_START",   cfg = "study_start",
       note = "set by STUDY_START"),
  # Table names are settings too: an ambient TBL_CONFINEMENT changes what the
  # other-cancer rule reads while cfg, and so the contract, is unmoved.
  list(const = "NDMM_TBL_CONFINEMENT",       cfg = "tbl_confinement",   note = ""),
  list(const = "NDMM_TBL_MEMBER_ENROLLMENT", cfg = "tbl_member_enroll", note = "")
  # NDMM_FINAL_TABLE_NAME is defined in the ported constants and read by
  # nothing - the runner passes the cohort table in. Nothing to check, because
  # nothing uses it; the test below only requires constants the steps read.

)

check_constants <- function(cfg) {
  wrong <- character(0)
  for (s in CONSTANT_SETTINGS) {
    if (!exists(s$const, envir = globalenv()))
      stop("Module constant ", s$const, " is not loaded; the modules must be ",
           "sourced before the settings can be checked.", call. = FALSE)
    got <- get(s$const, envir = globalenv())
    if (!isTRUE(all.equal(as.character(got), as.character(cfg[[s$cfg]]))))
      wrong <- c(wrong, paste0(s$const, " = ", format(got), " but ", s$cfg,
                               " = ", format(cfg[[s$cfg]]),
                               if (nzchar(s$note)) paste0(" (", s$note, ")") else ""))
  }
  if (length(wrong))
    stop("The SQL would not use the settings this run checked:\n  ",
         paste(wrong, collapse = "\n  "),
         "\nThese constants are what the queries read. A cohort built from ",
         "them is not the cohort the contract describes.", call. = FALSE)
  invisible(TRUE)
}

# The nine rows of the attrition, in the order the protocol applies the
# criteria: S6.2.1.1's inclusions, then S6.2.1.2's four exclusions as it lists
# them, belantamab last. Names are the criterion, not the column, because this
# table is what gets read.
ATTRITION_STEPS <- list(
  list(key = "whole",          label = "Patients in LOT_LONG"),
  list(key = "elig",           label = "+ in ELIG_COH_FINAL (parent IE)"),
  list(key = "elig_lot1",      label = "+ 1L start on or after LOT1_FROM"),
  list(key = "ce12",           label = "+ 12-month CE before index"),
  list(key = "ce12_fuce",      label = "+ CE during follow-up"),
  list(key = "fuce_nopriortx", label = "+ no MM oncology therapy in 12-month baseline"),
  list(key = "noother",        label = "+ no other cancer in 12-month baseline"),
  list(key = "noother_nopreg", label = "+ no pregnancy in study period"),
  list(key = "ndmm_final",     label = "+ no belantamab in any LOT (NDMM 1L cohort)")
)

ATTRITION_COLS <- c(RUN_ID = "STRING", STEP_NUM = "INT", CRITERION = "STRING",
                    N_PATIENTS = "BIGINT", PCT_OF_START = "DOUBLE",
                    RECORDED_AT = "TIMESTAMP")

# The attrition as a table, not only a log line. It is the deliverable here -
# the request was the count and the funnel that reaches it.
write_attrition <- function(con, cfg, counts) {
  tbl <- wrk("NDMM_ATTRITION")
  cols <- names(ATTRITION_COLS)
  db_exec(con, glue("CREATE TABLE IF NOT EXISTS {tbl} (",
                    paste(cols, ATTRITION_COLS, collapse = ", "), ")"))
  start <- counts[[ATTRITION_STEPS[[1]]$key]]
  vals <- vapply(seq_along(ATTRITION_STEPS), function(i) {
    s <- ATTRITION_STEPS[[i]]
    n <- counts[[s$key]]
    pct <- if (is.null(start) || is.na(start) || start == 0) "NULL"
           else sql_count(round(100 * n / start, 2))
    glue("('{run_id}', {i}, {sql_text(s$label)}, {sql_count(n)}, {pct}, current_timestamp())")
  }, character(1), USE.NAMES = FALSE)
  db_replace(con,
    glue("DELETE FROM {tbl} WHERE RUN_ID = '{run_id}'"),
    glue("INSERT INTO {tbl} ({paste(cols, collapse = ', ')}) VALUES ",
         paste(vals, collapse = ", ")))
  log_msg("Attrition written to ", tbl)
  invisible(TRUE)
}

# The funnel only ever narrows. A step larger than the one above it means a
# join fanned out or a filter was applied to the wrong population.
check_attrition_monotonic <- function(counts) {
  n <- vapply(ATTRITION_STEPS, function(s) as.numeric(counts[[s$key]]), numeric(1))
  bad <- which(n[-1] > n[-length(n)])
  if (length(bad))
    stop("The attrition grows at step ", bad[1] + 1L, " (",
         ATTRITION_STEPS[[bad[1] + 1L]]$label, "): ", n[bad[1]], " -> ",
         n[bad[1] + 1L], ". Each step is a subset of the one above it, so this ",
         "is a fan-out, not a count.", call. = FALSE)
  if (n[length(n)] == 0)
    stop("The NDMM cohort is empty. Every patient was excluded by some ",
         "criterion; the attrition above says which one.", call. = FALSE)
  invisible(TRUE)
}

CODELIST_METADATA_COLS <- c(RUN_ID = "STRING", CSV_NAME = "STRING",
                            MD5 = "STRING", N_ROWS = "BIGINT",
                            RECORDED_AT = "TIMESTAMP")

# load_codelist_csv() hashes every CSV it reads, because the code lists live
# outside git and the file name alone does not say which version a run used.
# Those hashes were being collected into an option and then dropped. Written
# here, so the outputs say which code lists built them.
write_codelist_metadata <- function(con, cfg) {
  seen <- getOption("nndm_codelist_md5", list())
  if (!length(seen))
    stop("No codelist hashes to record. Every run reads ",
         length(CODELIST_FILES), " code lists; this one recorded none, so the ",
         "cohort cannot be traced to the files that built it.", call. = FALSE)
  tbl  <- wrk("NDMM_CODELIST_METADATA")
  cols <- names(CODELIST_METADATA_COLS)
  db_exec(con, glue("CREATE TABLE IF NOT EXISTS {tbl} (",
                    paste(cols, CODELIST_METADATA_COLS, collapse = ", "), ")"))
  vals <- vapply(names(seen), function(nm)
    glue("('{run_id}', {sql_text(nm)}, {sql_text(seen[[nm]]$md5)}, ",
         "{sql_count(seen[[nm]]$n_rows)}, current_timestamp())"),
    character(1), USE.NAMES = FALSE)
  db_replace(con,
    glue("DELETE FROM {tbl} WHERE RUN_ID = '{run_id}'"),
    glue("INSERT INTO {tbl} ({paste(cols, collapse = ', ')}) VALUES ",
         paste(vals, collapse = ", ")))
  log_msg("Codelist versions written to ", tbl, " (", length(seen), ")")
  invisible(TRUE)
}

BUILD_STATUS_COLS <- c(RUN_ID = "STRING", OBJECT_PREFIX = "STRING",
                       STATE = "STRING", N_NDMM = "BIGINT",
                       UPDATED_AT = "TIMESTAMP")

write_build_status <- function(con, cfg, state, n = NA) {
  tbl <- wrk("NDMM_BUILD_STATUS")
  cols <- names(BUILD_STATUS_COLS)
  db_exec(con, glue("CREATE TABLE IF NOT EXISTS {tbl} (",
                    paste(cols, BUILD_STATUS_COLS, collapse = ", "), ")"))
  db_replace(con,
    glue("DELETE FROM {tbl} WHERE RUN_ID = '{run_id}'"),
    glue("INSERT INTO {tbl} ({paste(cols, collapse = ', ')}) VALUES (",
         "'{run_id}', '{cfg$object_prefix}', '{state}', {sql_count(n)}, ",
         "current_timestamp())"))
  log_msg("Build status: ", state, " (run ", run_id, ")")
  invisible(TRUE)
}

load_nndm_modules <- function(here) {
  source(file.path(here, "R", "load_inputs.R"))
  load_pipeline_inputs(here, "config.csv")
  for (f in c("config.R", "db_utils.R", "codelists.R", "nndm_constants.R"))
    source(file.path(here, "R", f))
  for (f in sort(list.files(file.path(here, "R", "steps"), "\\.R$", full.names = TRUE)))
    source(f)
  invisible(TRUE)
}

build_nndm <- function(here, prefix) {
  check_settings()
  cfg <- pin_output_schema(cfg_defaults)
  cfg <- pin_prefix(cfg, prefix)
  check_contract(cfg)
  check_constants(cfg)
  set_lot_config(cfg)

  stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")
  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  log_msg(SEP)
  log_msg("NDMM 1L cohort - prefix ", cfg$object_prefix, " - run ", run_id)
  log_msg("  1L start on or after: ", cfg$lot1_from)
  log_msg("  Baseline / CE before index: ", cfg$pre_lot1_days, " days")
  log_msg("  Follow-up CE: ", cfg$fu_ce_days, " day(s) after index")
  log_msg(SEP)

  check_upstream(con, cfg)
  write_build_status(con, cfg, "started")
  # after = FALSE, or this fires after the disconnect above and writes to a
  # closed connection.
  on.exit(if (!isTRUE(getOption("nndm_complete", FALSE)))
            try(write_build_status(con, cfg, "failed"), silent = TRUE),
          add = TRUE, after = FALSE)
  options(nndm_complete = FALSE, nndm_codelist_md5 = list())

  lot_long       <- wrk("LOT_LONG")
  map_stacked    <- wrk("MAP_STACKED")
  elig_coh_final <- wrk(cfg$cohort_table)

  log_msg("Enrollment spans (gap_days=", cfg$gap_days, ", and a no-gap set)")
  build_enrollment_spans_ndmm(con)
  build_enrollment_spans_ndmm(con, NDMM_ENROLL_SPANS_STRICT, 0L)

  log_msg("1L starts on or after ", NDMM_LOT1_FROM, " from ", lot_long)
  build_lot1_starts_ndmm(con, lot_long)

  log_msg("MM therapy in the ", NDMM_PRE_LOT1_DAYS, " days before 1L")
  db_exec(con, build_ndmm_mma_codelist())
  build_ndmm_therapy_pre_lot1(con, cdm_src(cfg$tbl_medical), cdm_src(cfg$tbl_rx))

  log_msg("Other cancer in the ", NDMM_PRE_LOT1_DAYS, " days before 1L")
  build_ndmm_other_malig_codes(con)
  build_ndmm_med_claim_header_and_confinement(con, cdm_src(cfg$tbl_medical),
                                              cdm_src(cfg$tbl_confinement))
  build_ndmm_other_malig_pre_lot1(con, cdm_src(cfg$tbl_med_diag))

  log_msg("Pregnancy across the study period")
  build_ndmm_preg_codes(con)
  build_ndmm_pregnancy_patids(con, cdm_src(cfg$tbl_med_diag),
                              cdm_src(cfg$tbl_medical), cdm_src(cfg$tbl_med_proc))

  log_msg("Per-patient filter flags")
  build_ndmm_flags(con, elig_coh_final, map_stacked, TRUE, TRUE, TRUE, TRUE)
  build_lot_long_filtered(con, lot_long)

  counts <- ndmm_counts(con, lot_long, elig_coh_final)
  for (i in seq_along(ATTRITION_STEPS))
    log_msg("  ", i, ". ", ATTRITION_STEPS[[i]]$label, ": ",
            format(counts[[ATTRITION_STEPS[[i]]$key]], big.mark = ","))
  # Before it is written, so a fanned-out funnel is not published as a count.
  check_attrition_monotonic(counts)

  run_step(con, "N90_ndmm_cohort", glue("
    CREATE OR REPLACE TABLE {wrk('NDMM_COHORT')} AS
    SELECT DISTINCT PATID FROM {NDMM_PATIDS}"),
    qc = glue("SELECT count(*) AS n_patients FROM {wrk('NDMM_COHORT')}"))
  write_attrition(con, cfg, counts)
  write_codelist_metadata(con, cfg)

  write_build_status(con, cfg, "complete", counts$ndmm_final)
  options(nndm_complete = TRUE)
  log_msg(SEP)
  log_msg("NDMM 1L cohort: ", format(counts$ndmm_final, big.mark = ","),
          " patients -> ", wrk("NDMM_COHORT"))
  log_msg(SEP)
  invisible(counts)
}
