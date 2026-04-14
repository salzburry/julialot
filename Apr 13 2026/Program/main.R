#!/usr/bin/env Rscript
# ============================================================
# GSK MM LOT — Cohort Attrition Pipeline (Modular)
# ============================================================
# Optum CDM -> Databricks/Spark -> ELIG_COH_FINAL
#
# Supported run modes:
#   Static  — non-interactive, uses env-var / config defaults
#   Interactive — prompts for study parameters + IE criteria
#
# Module layout:
#   R/config_prompts.R       — cfg defaults, env-var loading, prompts
#   R/db_utils.R             — connection, retry, naming, materialization
#   R/codelists.R            — server-side code-list loading, quarterly tables
#   R/criteria_attrition.R   — criteria catalog, filter builder, attrition
#   R/pipeline_steps.R       — build_steps(), run_step()
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
source_dir <- file.path(dirname(sys.frame(1)$ofile %||% "."), "R")
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
  user_cfg    <- prompt_user_options()
  ie_criteria <- prompt_ie_criteria()
  finalize_cfg(user_cfg, ie_criteria)

  log_msg("=", SEP_59)
  log_msg("ATTRITION COHORT PIPELINE - run_id: ", run_id)
  log_msg("CODE LISTS: Server-side tables from ", cfg$ref_schema)
  if (isTRUE(cfg$use_quarterly_tables)) {
    log_msg("TABLES: Using quarterly tables (t_<table>_", get_quarter_suffix(cfg$study_end), ")")
  } else {
    log_msg("TABLES: Using single consolidated tables")
  }
  log_msg("OUTPATIENT WINDOW: ", cfg$outpatient_window, " days")
  log_msg("OUTPUT TABLE: ", cfg$final_table_name)
  log_msg("=", SEP_59)

  # ---- 2. Connect ----
  con_env$con <- with_retry(function() {
    conn <- connect_databricks()
    log_msg("Connected to Databricks")
    conn
  })
  on.exit({ if (!is.null(con_env$con)) try(DBI::dbDisconnect(con_env$con), silent = TRUE) }, add = TRUE)

  # ---- 3. Build & run pipeline steps ----
  steps <- build_steps()
  steps <- Filter(Negate(is.null), steps)
  total_steps <- length(steps)

  cat("\n", SEP_60, "\n", sep = "")
  cat("  STARTING PIPELINE: ", total_steps, " steps to process\n")
  cat(SEP_60, "\n")

  for (i in seq_along(steps)) {
    s <- steps[[i]]
    with_retry(function() {
      run_step(s$name, s$sql, qc_sql = s$qc,
               description = s$description,
               step_num = i, total_steps = total_steps,
               source_tables = s$source_tables)
    })

    # Materialize checkpoints for Spark performance
    if (isTRUE(cfg$materialize_checkpoints)) {
      table_name <- sub("^\\d+[a-z]?_", "", s$name)
      if (table_name %in% CHECKPOINT_STEPS) {
        materialize_to_personal_schema(con_env$con, table_name, replace = TRUE)
      }
    }
  }

  # ---- 4. Attrition report ----
  log_msg("=", SEP_59)
  log_msg("PIPELINE COMPLETE - Generating attrition report...")

  tryCatch({
    catalog <- build_criteria_catalog()
    run_attrition_report(catalog)
    print_cohort_characteristics()
    print_dod_validation()
    print_inpatient_validation()
  }, error = function(e) {
    log_msg("WARN: Could not generate full attrition report: ", conditionMessage(e))
  })

  log_msg("=", SEP_59)
}

# ---- Entry point ----
if (!interactive()) {
  main()
} else {
  log_msg("Source loaded. Call main() to run pipeline.")
}
