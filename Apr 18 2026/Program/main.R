#!/usr/bin/env Rscript
# ============================================================
# GSK MM LOT — Cohort Attrition Pipeline (Modular)
# ============================================================
# Optum CDM -> Databricks/Spark -> ELIG_COH_FINAL
#
# Supported run modes:
#   Static  — non-interactive (Rscript), uses env-var / config defaults
#   Interactive — R console, prompts for study parameters + IE criteria
#   Override: set PROMPT_USER=TRUE to force prompts, FALSE to suppress
#
# Runtime state (cfg, connection, materialized tables) is created
# in main() and passed through function arguments — no mutable globals.
#
# Module layout:
#   R/config_prompts.R       — cfg_defaults template, env-var loading, prompts
#   R/db_utils.R             — make_naming_helpers(), connection, retry, step runner
#   R/codelists.R            — quarterly table helpers
#   R/criteria_attrition.R   — criteria catalog, filter builder, attrition
#   R/pipeline_steps.R       — build_steps(cfg, mat_tables)
# ============================================================

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
# Resolve script directory without relying on %||% (not available before modules load)
.ofile <- tryCatch(sys.frame(1)$ofile, error = function(e) NULL)
source_dir <- file.path(dirname(if (!is.null(.ofile)) .ofile else "."), "R")
source(file.path(source_dir, "config_prompts.R"))
source(file.path(source_dir, "db_utils.R"))
source(file.path(source_dir, "codelists.R"))
source(file.path(source_dir, "criteria_attrition.R"))
source(file.path(source_dir, "pipeline_steps.R"))

# ============================================================
# MAIN
# ============================================================
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
    with_retry(function() {
      run_step(s$name, s$sql, conn = conn, cfg = cfg, qc_sql = s$qc,
               description = s$description,
               step_num = i, total_steps = total_steps,
               source_tables = s$source_tables)
    }, max_retries = cfg$max_retries, base_sleep = cfg$base_sleep)

    # Materialize checkpoints for Spark performance
    if (isTRUE(cfg$materialize_checkpoints)) {
      table_name <- sub("^\\d+[a-z]?_", "", s$name)
      if (table_name %in% CHECKPOINT_STEPS) {
        materialize_to_personal_schema(conn$con, table_name, cfg, mat_tables, replace = TRUE)
      }
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
