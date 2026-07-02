#!/usr/bin/env Rscript
# GSK MM LOT - cohort attrition pipeline. Optum CDM -> Databricks/Spark
# -> ELIG_COH_FINAL.
#
# Run modes:
#   Static       non-interactive (Rscript); env-var / config defaults.
#   Interactive  R console; prompts for study parameters + IE criteria.
#   PROMPT_USER=TRUE/FALSE forces/suppresses prompts.
#
# All runtime state (cfg, connection, materialized tables) is created in
# main() and passed by argument - no mutable globals.

library(DBI)
library(odbc)
library(glue)
library(dplyr)
library(dbplyr)

# Source GSK helper for personal schema operations
tryCatch(
  source("/mnt/code/R/helperScripts/databases/personalSchemaFunctions.R"),
  error = function(e) message("NOTE: personalSchemaFunctions.R not found; materialization disabled")
)

# ---- Source modules (order matters) ----
# Resolve script directory robustly (same pattern as 02_lot1.R /
# 03_lot2_5.R): Rscript --file= first, then a source()'d $ofile, then
# the working dir. This makes both `Rscript 01_cohort.R` and
# the run_pipeline.R subprocess launch (full path, no wd change) resolve
# R/ correctly, instead of looking for ./R relative to the caller's cwd.
.script_dir <- local({
  args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", args, value = TRUE)
  if (length(file_arg) > 0) {
    return(dirname(normalizePath(sub("^--file=", "", file_arg[1]))))
  }
  for (i in seq_len(sys.nframe())) {
    ofile <- tryCatch(sys.frame(i)$ofile, error = function(e) NULL)
    if (!is.null(ofile)) return(dirname(normalizePath(ofile)))
  }
  getwd()
})
source_dir <- file.path(.script_dir, "R")
# Apply pipeline_inputs.csv overrides BEFORE config_prompts.R reads
# Sys.getenv(), so a direct `Rscript 01_cohort.R` honours the same single
# input file as the orchestrated run.
if (file.exists(file.path(source_dir, "load_inputs.R"))) {
  source(file.path(source_dir, "load_inputs.R"))
  load_pipeline_inputs(c(.script_dir, dirname(.script_dir)))
}
source(file.path(source_dir, "config_prompts.R"))
source(file.path(source_dir, "db_utils.R"))
source(file.path(source_dir, "codelists.R"))
source(file.path(source_dir, "criteria_attrition.R"))
source(file.path(source_dir, "pipeline_steps.R"))

main <- function() {
  # ---- 1. Prompts & config ----
  user_cfg    <- prompt_user_options(cfg_defaults)
  ie_criteria <- prompt_ie_criteria(cfg_defaults)
  cfg         <- finalize_cfg(cfg_defaults, user_cfg, ie_criteria)

  log_msg("=", SEP_59)
  log_msg("ATTRITION COHORT PIPELINE - run_id: ", run_id)
  if (isTRUE(cfg$use_csv_codelists)) {
    log_msg("CODE LISTS: CSV files from ", cfg$codelist_dir)
  } else {
    log_msg("CODE LISTS: Server-side tables from ", cfg$ref_schema)
  }
  if (isTRUE(cfg$use_quarterly_tables)) {
    log_msg("TABLES: Using quarterly tables (t_<table>_", get_quarter_suffix(cfg$study_end), ")")
  } else {
    log_msg("TABLES: Using single consolidated tables")
  }
  log_msg("OUTPATIENT WINDOW: ", cfg$outpatient_window, " days")
  log_msg("OUTPUT TABLE: ", cfg$final_table_name)
  log_msg("=", SEP_59)

  # ---- 2. Connect ----
  conn <- new.env()
  conn$con <- with_retry(function() {
    c <- connect_databricks(cfg)
    log_msg("Connected to Databricks")
    c
  }, max_retries = cfg$max_retries, base_sleep = cfg$base_sleep)
  # In batch mode, disconnect on exit. In interactive mode, keep connection
  # alive so the user can run inspect_pipeline() and ad-hoc queries.
  if (!interactive()) {
    on.exit({ if (!is.null(conn$con)) try(DBI::dbDisconnect(conn$con), silent = TRUE) }, add = TRUE)
  }

  # ---- 2b. Load code-list CSVs into Spark temp views ----
  load_csv_codelists(conn, cfg)

  # ---- 3. Build & run pipeline steps ----
  mat_tables <- new.env()
  steps <- build_steps(cfg, mat_tables)
  steps <- Filter(Negate(is.null), steps)
  total_steps <- length(steps)

  cat("\n", SEP_60, "\n", sep = "")
  cat("  STARTING PIPELINE: ", total_steps, " steps to process\n")
  cat(SEP_60, "\n")

  for (i in seq_along(steps)) {
    s <- steps[[i]]
    table_name <- sub("^\\d+[a-z]?_", "", s$name)
    is_ckpt <- isTRUE(cfg$materialize_checkpoints) &&
               table_name %in% CHECKPOINT_STEPS

    # Checkpoint steps defer QC: the view is materialized right after,
    # so QC scans the persisted table instead of forcing the heavy view
    # to compute once for QC and again for materialization.
    with_retry(function() {
      run_step(s$name, s$sql, conn = conn, cfg = cfg,
               qc_sql = if (is_ckpt) NULL else s$qc,
               description = s$description,
               step_num = i, total_steps = total_steps,
               source_tables = s$source_tables)
    }, max_retries = cfg$max_retries, base_sleep = cfg$base_sleep)

    if (is_ckpt) {
      ok <- materialize_to_personal_schema(conn$con, table_name, cfg,
                                           mat_tables, replace = TRUE)
      # A genuine materialization failure is fatal: downstream steps
      # would silently recompute the heavy view and a missing checkpoint
      # could go unnoticed. personal_schema being unset is NOT a failure
      # - the function skips by design and the pipeline runs (slower)
      # off the temp views, exactly as the original did.
      if (nzchar(cfg$personal_schema) && !isTRUE(ok)) {
        stop("Checkpoint '", table_name, "' failed to materialize to ",
             "personal schema '", cfg$personal_schema, "'. See the WARN ",
             "above for the cause. Aborting so the failure is not masked.")
      }
      # personal_schema set + ok: the view was repointed, so this QC is
      # a cheap scan. personal_schema unset: QC runs against the temp
      # view (the heavy path), same as the original pipeline.
      with_retry(function() run_qc(conn$con, s$qc),
                 max_retries = cfg$max_retries, base_sleep = cfg$base_sleep)
    }
  }

  # ---- 4. Attrition report ----
  log_msg("=", SEP_59)
  log_msg("PIPELINE COMPLETE - Generating attrition report...")

  tryCatch({
    h <- make_naming_helpers(cfg, mat_tables)
    catalog <- build_criteria_catalog(cfg)
    attrition_rows <- run_attrition_report(catalog, cfg, conn, h$work_tbl)
    # Persist to work schema so Part 2's LOT dashboard can render the
    # attrition chart. Honors PERSIST_TO_SCHEMA=FALSE the same way Step 24b
    # does; best-effort otherwise (failure logs WARN, does not abort the
    # attrition report).
    if (isTRUE(cfg$persist_to_schema)) {
      persist_attrition_table(attrition_rows, cfg, conn)
    } else {
      log_msg("PERSIST_TO_SCHEMA=FALSE; skipping attrition_report warehouse persist")
    }
    print_cohort_characteristics(cfg, conn, h$work_tbl)
    print_dod_validation(cfg, conn, h$cdm_src, h$work_tbl)
    print_inpatient_validation(conn, h$work_tbl)
  }, error = function(e) {
    log_msg("WARN: Could not generate full attrition report: ", conditionMessage(e))
  })

  log_msg("=", SEP_59)

  # Return context for interactive debugging (invisible in batch mode)
  invisible(list(cfg = cfg, conn = conn, mat_tables = mat_tables,
                 h = make_naming_helpers(cfg, mat_tables)))
}

# ---- Entry point ----
if (!interactive()) {
  main()
} else {
  log_msg("Source loaded. Call main() to run pipeline.")
  log_msg("After main(), use: ctx <- main(); inspect_pipeline(ctx$conn, ctx$cfg, ctx$h$work_tbl)")
}
