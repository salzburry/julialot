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
                  "09_tte.R", "10_patterns.R")

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

build_223926 <- function(here) {
  cfg <- cfg_defaults()
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
  on.exit(disconnect_db(con), add = TRUE)
  if (!nzchar(cfg$work_schema)) {
    cfg$work_schema <- current_work_schema(con)
    set_study_config(cfg)
    log_msg("work schema resolved to ", cfg$work_schema)
  }

  lot_run <- check_lot_lineage(con, cfg)
  write_run_metadata(con, cfg, cohorts, mods, lot_run, deviations, "started")

  # Inputs the cohort module needs, built once rather than per cohort.
  build_enroll_spans(con, cfg)
  # A full medical + rx scan, so only when a follow-up reading actually reads
  # it. The shipped default's predicate is `1 = 1` and never touches the result.
  if (identical(cfg$fu_evidence_rule, "claim_after_index")) {
    build_fu_claims(con, cfg)
  } else {
    db_exec(con, sprintf(
      "CREATE OR REPLACE TEMPORARY VIEW %s AS
       SELECT cast(NULL as string) AS PATID, cast(NULL as int) AS N_CLAIMS_AFTER_INDEX,
              cast(NULL as int) AS N_CLAIMS_FROM_INDEX WHERE 1 = 0",
      wrk("S_FU_CLAIMS")))
    log_msg("FU_EVIDENCE_RULE=", cfg$fu_evidence_rule,
            " does not read claim counts, so the medical+rx scan is skipped.")
  }
  if ("hcru" %in% names(mods)) build_mm_dx_view(con, cfg)

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

  write_run_metadata(con, cfg, cohorts, mods, lot_run, deviations, "complete")
  log_msg(SEP)
  log_msg("complete: ", length(cohorts), " cohort(s), ", length(mods),
          " module(s)")
  invisible(TRUE)
}

# What produced these numbers, on the numbers' own row. Every setting outside
# the contract is a reading someone chose, and a table that does not say which
# reading cannot be reproduced from the table alone.
write_run_metadata <- function(con, cfg, cohorts, mods, lot_run, deviations,
                               state) {
  rid <- Sys.getenv("DOMINO_RUN_ID",
                    unset = format(Sys.time(), "%Y%m%d%H%M%S"))
  esc <- function(x) gsub("'", "''", paste(as.character(x), collapse = "; "))
  db_exec(con, sprintf("
    CREATE TABLE IF NOT EXISTS %s (
      RUN_ID string, STATE string, UPDATED_AT timestamp,
      COHORTS string, MODULES string, LOT_RUN_ID string,
      STUDY_START string, STUDY_END string,
      CONTRACT_DEVIATIONS string, OPEN_QUESTION_READINGS string,
      CODELISTS string)", wrk("S_RUN_METADATA")))
  db_exec(con, sprintf("DELETE FROM %s WHERE RUN_ID = '%s'",
                       wrk("S_RUN_METADATA"), rid))
  cl <- codelist_metadata()
  cl_str <- if (nrow(cl))
    paste(sprintf("%s(%s,%d rows)", cl$CODELIST, substr(cl$MD5, 1, 8),
                  cl$N_ROWS), collapse = "; ") else ""
  db_exec(con, sprintf("
    INSERT INTO %s VALUES ('%s','%s',current_timestamp(),'%s','%s','%s','%s',
                           '%s','%s','%s','%s')",
    wrk("S_RUN_METADATA"), rid, state,
    esc(names(cohorts)), esc(names(mods)),
    esc(lot_run$RUN_ID %||% ""), cfg$study_start, cfg$study_end,
    esc(if (length(deviations)) deviations else "none"),
    esc(open_question_readings(cfg)), esc(cl_str)))
  invisible(rid)
}
