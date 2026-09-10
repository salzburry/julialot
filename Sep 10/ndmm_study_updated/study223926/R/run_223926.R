# The runner. Resolves the plan, refuses what it cannot vouch for, then walks
# the modules in dependency order, once per selected cohort where the module
# says so.
#
# Nothing here decides a clinical rule. The rules are in the modules, the
# windows in R/windows.R, the counting in R/person_time.R, and what may be
# selected in R/registry.R.

MODULE_FILES <- c("00_spine.R", "01_cohorts.R", "02_periods.R",
                  "03_demographics.R", "04_comorbidity.R", "05_soc.R",
                  "06_safety.R", "07_hcru.R", "08_malignancy.R",
                  "09_tte.R", "10_patterns.R", "11_release.R")

source_modules <- function(here) {
  for (f in MODULE_FILES) {
    p <- file.path(here, "R", "modules", f)
    if (!file.exists(p))
      stop("BUILD ERROR: module file ", p, " is missing.", call. = FALSE)
    source(p)
  }
  # Every registered module must have its function, or a selection that looks
  # valid would fail deep inside the run.
  for (m in MODULES)
    if (!exists(m$fn, mode = "function"))
      stop("BUILD ERROR: module '", m$key, "' registers ", m$fn,
           "(), which no file under R/modules/ defines.", call. = FALSE)
  invisible(TRUE)
}

# Everything the modules need that is built once rather than per cohort.
#
# A function of its own, and not inline in build_223926(), because the test
# harness has to walk exactly this path. It used to call build_fu_claims()
# directly, which is the ONE branch below that works - so the branch the
# shipped default takes was never emitted and never checked, and it could not
# run at all.
build_inputs <- function(con, cfg, mods) {
  check_cohort_table(con, cfg)
  build_enroll_spans(con, cfg)

  # A full medical + rx scan, so only when a follow-up reading actually reads
  # it. The shipped default's predicate is `1 = 1` and never touches the result.
  #
  # The empty stand-in is a TABLE, not a temporary view. Spark refuses a
  # qualified name for a temp view ("only accept single-part view names"), and
  # every reader here names tables through wrk(), which is
  # catalog.schema.prefix_name - so a temp view could not be referred to even
  # if it could be created. An empty table costs nothing.
  if (identical(cfg$fu_evidence_rule, "claim_after_index")) {
    build_fu_claims(con, cfg)
  } else {
    db_exec(con, sprintf(
      "CREATE OR REPLACE TABLE %s
       (PATID string, LOT_NUM int,
        N_CLAIMS_AFTER_INDEX int, N_CLAIMS_FROM_INDEX int)",
      wrk("S_FU_CLAIMS")))
    log_msg("FU_EVIDENCE_RULE=", cfg$fu_evidence_rule,
            " does not read claim counts, so the medical+rx scan is skipped.")
  }

  # Whoever declared mm_dx.csv gets the view: hcru's MM-related hospitalisation
  # test and comorbidity's MM adjustment both read it.
  if ("mm_dx.csv" %in% required_codelists(mods)) build_mm_dx_view(con, cfg)
  invisible(TRUE)
}

build_223926 <- function(here) {
  # First, before anything reads it. A second build in the same R session
  # would otherwise start holding the first's config, its code-list manifest
  # and the columns of its input table.
  reset_run_state()
  cfg <- cfg_defaults()
  cfg$codelist_dir <- resolve_codelist_dir(cfg, here)
  set_study_config(cfg)
  check_settings(cfg)
  deviations <- check_contract(cfg)

  cohorts <- resolve_cohorts(cfg)
  mods    <- resolve_modules(cfg)
  source_modules(here)

  cat(SEP, "\n", paste(describe_plan(cfg, cohorts, mods), collapse = "\n"),
      "\n", SEP, "\n", sep = "")
  if (isTRUE(cfg$dry_run)) {
    log_msg("DRY_RUN=TRUE - nothing was read and nothing was written.")
    return(invisible(list(cfg = cfg, cohorts = cohorts, modules = mods)))
  }

  # Code lists before the connection: a run that cannot finish should stop in
  # the first second, not after the expensive steps.
  preflight_codelists(mods, cfg)

  con <- connect_db(cfg)
  # ONE cleanup handler, registered once, so ordering cannot go wrong.
  #
  # on.exit callbacks run in registration order, so a disconnect registered
  # here and a failure-status write registered later ran in that order: the
  # connection was already closed when the failure row was attempted, its
  # error was swallowed by try(), and the run stayed recorded as `started`.
  # The status write now happens inside the same handler, before the
  # disconnect, and the disconnect is guaranteed by its own on.exit.
  .run_state <- new.env(parent = emptyenv())
  .run_state$ok <- FALSE
  .run_state$meta <- NULL
  on.exit({
    if (!isTRUE(.run_state$ok) && !is.null(.run_state$meta))
      try(.run_state$meta(), silent = TRUE)
    disconnect_db(con)
  }, add = TRUE)
  if (!nzchar(cfg$work_schema)) {
    cfg$work_schema <- current_work_schema(con)
    set_study_config(cfg)
    log_msg("work schema resolved to ", cfg$work_schema)
  }

  lot_run <- check_lot_lineage(con, cfg)
  # What the cohort build applied, so the readings this run records for its
  # rules are the ones that shaped the data rather than this run's own copy.
  upstream <- read_upstream_settings(con, cfg)
  # One id for the whole build, so `started`, `failed` and `complete` are rows
  # about the same run rather than three unrelated ones.
  rid <- new_run_id()
  write_run_metadata(con, cfg, cohorts, mods, lot_run, deviations, "started",
                     run_id = rid, upstream = upstream)
  # A build that dies mid-way would otherwise leave a `started` row and nothing
  # else, which reads as a run still going. The handler above writes `failed`
  # under the same id while the connection is still open.
  .run_state$meta <- function()
    write_run_metadata(con, cfg, cohorts, mods, lot_run, deviations, "failed",
                       run_id = rid, upstream = upstream)

  build_inputs(con, cfg, mods)

  for (m in mods) {
    log_msg(SEP)
    log_msg("module ", m$key, " - ", m$label)
    fn <- get(m$fn, mode = "function")
    if (isTRUE(m$per_cohort)) {
      for (co in cohorts) {
        log_msg("  cohort ", co$key)
        fn(con, cfg, co)
      }
    } else {
      fn(con, cfg, cohorts)
    }
  }

  # Still the build that was accepted? Every module read the LOT tables over
  # the minutes above; only now can the run vouch that they were one build's.
  check_lot_lineage_unchanged(con, lot_run)
  write_run_metadata(con, cfg, cohorts, mods, lot_run, deviations, "complete",
                     run_id = rid, upstream = upstream)
  .run_state$ok <- TRUE
  log_msg(SEP)
  log_msg("complete: ", length(cohorts), " cohort(s), ", length(mods),
          " module(s)")
  invisible(TRUE)
}

# What produced these numbers, on the numbers' own row. Every setting outside
# the contract is a reading someone chose, and a table that does not say which
# reading cannot be reproduced from the table alone.
# Allocated ONCE per build and passed to every status write. Generating it
# inside each write gave a build lasting more than a second a `started` row
# under one id and a `complete` row under another, so the first looked like a
# run that never finished and neither could be traced to the other.
new_run_id <- function()
  Sys.getenv("DOMINO_RUN_ID", unset = format(Sys.time(), "%Y%m%d%H%M%S"))

# The metadata row's shape, declared once. The CREATE, the column upgrade and
# the INSERT all read this, so a column added here reaches all three - and the
# insert names its columns, so an older table that gained one keeps working.
RUN_METADATA_COLS <- c(
  RUN_ID = "string", STATE = "string", UPDATED_AT = "timestamp",
  COHORTS = "string", MODULES = "string",
  LOT_RUN_ID = "string", LOT_RUN_VERSION = "string",
  STUDY_START = "string", STUDY_END = "string",
  CONTRACT_DEVIATIONS = "string", OPEN_QUESTION_READINGS = "string",
  CODELISTS = "string")

write_run_metadata <- function(con, cfg, cohorts, mods, lot_run, deviations,
                               state, run_id = NULL, upstream = NULL) {
  rid <- if (is.null(run_id) || !nzchar(run_id)) new_run_id() else run_id
  esc <- function(x) gsub("'", "''", paste(as.character(x), collapse = "; "))
  q   <- function(x) paste0("'", esc(x), "'")
  tbl <- wrk("S_RUN_METADATA")
  db_exec(con, sprintf("CREATE TABLE IF NOT EXISTS %s (%s)", tbl,
                       paste(names(RUN_METADATA_COLS), RUN_METADATA_COLS,
                             collapse = ", ")))
  ensure_columns(con, tbl, RUN_METADATA_COLS)
  db_exec(con, sprintf("DELETE FROM %s WHERE RUN_ID = '%s'", tbl, rid))
  cl <- codelist_metadata()
  cl_str <- if (nrow(cl))
    paste(sprintf("%s(%s,%d rows)", cl$CODELIST, substr(cl$MD5, 1, 8),
                  cl$N_ROWS), collapse = "; ") else ""
  vals <- c(RUN_ID                 = q(rid),
            STATE                  = q(state),
            UPDATED_AT             = "current_timestamp()",
            COHORTS                = q(names(cohorts)),
            MODULES                = q(names(mods)),
            LOT_RUN_ID             = q(lot_run$RUN_ID %||% ""),
            LOT_RUN_VERSION        = q(lot_run_version(lot_run)),
            STUDY_START            = q(cfg$study_start),
            STUDY_END              = q(cfg$study_end),
            CONTRACT_DEVIATIONS    = q(if (length(deviations)) deviations else "none"),
            OPEN_QUESTION_READINGS = q(open_question_readings(cfg, upstream)),
            CODELISTS              = q(cl_str))
  # One declaration drives all three statements; a column declared with no
  # value, or a value with no column, stops the build here rather than in the
  # warehouse's words.
  stopifnot(identical(names(vals), names(RUN_METADATA_COLS)))
  db_exec(con, sprintf("INSERT INTO %s (%s) VALUES (%s)", tbl,
                       paste(names(vals), collapse = ", "),
                       paste(vals, collapse = ", ")))
  invisible(rid)
}
