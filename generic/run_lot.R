#!/usr/bin/env Rscript
# ============================================================
# Generic LOT Framework — Pipeline Entry Point
# ============================================================
# Orchestrates the full LOT pipeline using a disease-specific
# YAML config. No disease-specific code here — everything is
# driven by configuration.
#
# Usage:
#   source("generic/run_lot.R")
#   run_generic_lot("generic/configs/mm_lot_config.yaml", con, "schema.COHORT")
# ============================================================

suppressPackageStartupMessages({
  library(DBI)
  library(glue)
})

# Source framework modules
script_dir <- if (exists("script_dir")) script_dir else {
  tryCatch(dirname(sys.frame(1)$ofile), error = function(e) "generic")
}
source(file.path(script_dir, "lot_config_schema.R"))
source(file.path(script_dir, "map_algorithm.R"))
source(file.path(script_dir, "lot_engine.R"))

# ============================================================
# LOGGING
# ============================================================
SEP  <- strrep("=", 70)
DASH <- strrep("-", 70)

lot_log <- function(...) {
  cat(sprintf("[%s] ", format(Sys.time(), "%Y-%m-%d %H:%M:%S")), ..., "\n")
  flush.console()
}

# ============================================================
# STEP RUNNER
# ============================================================
run_step <- function(con, step_name, sql, qc_sql = NULL) {
  cat("\n", DASH, "\n")
  lot_log("STEP: ", step_name)
  cat(DASH, "\n")

  t0 <- proc.time()
  DBI::dbExecute(con, sql)
  elapsed <- (proc.time() - t0)[["elapsed"]]
  lot_log("  Completed in ", round(elapsed, 1), "s")

  if (!is.null(qc_sql) && nzchar(qc_sql)) {
    qc <- DBI::dbGetQuery(con, qc_sql)
    print(qc)
  }
  invisible(TRUE)
}

# ============================================================
# MAIN PIPELINE
# ============================================================

#' Run the generic LOT pipeline
#'
#' @param config_path Path to a disease-specific YAML config
#' @param con A DBI database connection (e.g., Databricks via ODBC)
#' @param cohort_table Fully qualified name of the patient cohort table.
#'   Must contain at minimum: PATID (or configured patient_id_field),
#'   INDEX_DATE, OBS_END_DT
#' @param cohort_view_name Name for the cohort temp view (default: lot_patient_input)
#' @param persist_schema Optional schema to persist output tables to
#' @return Invisibly returns the config used
run_generic_lot <- function(config_path, con, cohort_table,
                            cohort_view_name = "lot_patient_input",
                            persist_schema = NULL) {

  cat("\n", SEP, "\n")
  lot_log("GENERIC LOT FRAMEWORK")
  cat(SEP, "\n")

  # --- Load & validate config ---
  lot_log("Loading config: ", config_path)
  cfg <- load_lot_config(config_path)
  lot_log("Disease: ", cfg$disease$name, " (", cfg$disease$abbreviation, ")")
  lot_log("Parameters:")
  lot_log("  Induction window:    ", cfg$parameters$induction_window_days, " days")
  lot_log("  MAP gap threshold:   ", cfg$parameters$map_gap_days, " days")
  lot_log("  Medical day supply:  ", cfg$parameters$medical_day_supply, " days")
  lot_log("  Discon gap:          ", cfg$parameters$lot_discon_gap_days, " days")
  if (length(cfg$parameters$excluded_classes_from_lot_start) > 0) {
    lot_log("  Excluded from LOT start: ",
            paste(cfg$parameters$excluded_classes_from_lot_start, collapse = ", "))
  }
  cat(SEP, "\n\n")

  # --- Step 0: Register patient cohort ---
  run_step(con, "Register patient cohort", glue("
    CREATE OR REPLACE TEMPORARY VIEW {cohort_view_name} AS
    SELECT * FROM {cohort_table}
  "), qc = glue("SELECT count(*) AS n_patients FROM {cohort_view_name}"))

  # --- Step 1: Register medication rollup ---
  rollup_sql <- build_rollup_sql(cfg$medications$rollup)
  run_step(con, "Register medication rollup", glue("
    CREATE OR REPLACE TEMPORARY VIEW generic_mma_rollup AS
    {rollup_sql}
  "), qc = "SELECT count(*) AS n_medications, count(DISTINCT CL_MED_CLASS) AS n_classes FROM generic_mma_rollup")

  # --- Step 2: Register medication codelist ---
  if (!is.null(cfg$medications$codelist)) {
    codelist_sql <- build_codelist_sql(cfg$medications$codelist)
    run_step(con, "Register medication codelist (inline)", glue("
      CREATE OR REPLACE TEMPORARY VIEW generic_mma_codelist AS
      SELECT
        upper(trim(CL_CODE_TYPE)) AS CL_CODE_TYPE,
        upper(regexp_replace(trim(CL_CODE), '[^A-Za-z0-9]', '')) AS CL_CODE,
        CL_MEDICATION_FULL, CL_MED_CLASS, CL_MED_ABBR
      FROM ({codelist_sql}) raw
    "), qc = "SELECT CL_CODE_TYPE, count(*) AS n FROM generic_mma_codelist GROUP BY CL_CODE_TYPE")
  } else {
    # External table
    run_step(con, "Register medication codelist (table)", glue("
      CREATE OR REPLACE TEMPORARY VIEW generic_mma_codelist AS
      SELECT
        upper(trim(CL_CODE_TYPE)) AS CL_CODE_TYPE,
        upper(regexp_replace(trim(CL_CODE), '[^A-Za-z0-9]', '')) AS CL_CODE,
        CL_MEDICATION_FULL, CL_MED_CLASS, CL_MED_ABBR
      FROM {cfg$medications$codelist_table}
    "), qc = "SELECT CL_CODE_TYPE, count(*) AS n FROM generic_mma_codelist GROUP BY CL_CODE_TYPE")
  }

  # --- Step 3: Register permissible substitutions (optional) ---
  has_perm_subs <- FALSE
  if (!is.null(cfg$medications$permissible_substitutions)) {
    perm_sql <- build_permissible_subs_sql(cfg$medications$permissible_substitutions)
    if (!is.null(perm_sql)) {
      run_step(con, "Register permissible substitutions", glue("
        CREATE OR REPLACE TEMPORARY VIEW generic_permissible_subs AS
        {perm_sql}
      "), qc = "SELECT count(*) AS n_substitutions FROM generic_permissible_subs")
      has_perm_subs <- TRUE
    }
  }

  # --- Step 4: Extract medication claims ---
  med_claims_sql <- generate_med_claims_sql(cfg, cohort_view_name, "generic_mma_codelist")
  run_step(con, "Extract medication claims (MMA_MED)", med_claims_sql,
    qc = "SELECT count(*) AS n_claims, count(DISTINCT PATID) AS n_patients, count(DISTINCT MED_ABBR) AS n_meds FROM generic_mma_med")

  # --- Step 5: MAP algorithm ---
  map_sql <- generate_map_sql(cfg, "generic_mma_med", cohort_view_name)
  run_step(con, "MAP algorithm", map_sql,
    qc = "SELECT count(*) AS n_maps, count(DISTINCT PATID) AS n_patients, avg(datediff(MAP_END_DT, MAP_START_DT)+1) AS avg_map_days FROM generic_map_med")

  # --- Step 6: LOT1 start ---
  lot1_start_sql <- generate_lot1_start_sql(cfg)
  run_step(con, "LOT1 start dates", lot1_start_sql,
    qc = "SELECT count(*) AS n_patients FROM generic_lot1_start")

  # --- Step 7: LOT1 induction medications ---
  lot1_ind_sql <- generate_lot1_induction_sql(cfg)
  run_step(con, "LOT1 induction medications", lot1_ind_sql,
    qc = "SELECT count(DISTINCT PATID) AS n_patients, avg(cnt) AS avg_induction_meds FROM (SELECT PATID, count(DISTINCT MED_ABBR) AS cnt FROM generic_lot1_induction_meds GROUP BY PATID)")

  # --- Step 8: LOT1 base ---
  lot1_base_sql <- generate_lot1_base_sql(cfg, "generic_map_med", cohort_view_name, has_perm_subs)
  run_step(con, "LOT1 base (regimen + discon + add-med)", lot1_base_sql,
    qc = "SELECT count(*) AS n, avg(LOT1_MED_CNT) AS avg_meds, avg(LOT1_BASE_LENGTH) AS avg_length, sum(case when LOT1_BASE_DISCON_DT is not null then 1 else 0 end) AS n_discon FROM generic_lot1_base")

  # --- Step 9: Procedure detection (optional, disease-specific) ---
  has_procedures <- FALSE
  if (!is.null(cfg$procedures) && length(cfg$procedures$codelist) > 0) {
    proc_sql <- build_procedure_codelist_sql(cfg$procedures$codelist)
    if (!is.null(proc_sql)) {
      run_step(con, "Register procedure codelist", glue("
        CREATE OR REPLACE TEMPORARY VIEW generic_procedure_codelist AS
        SELECT
          upper(trim(CL_CODE_TYPE)) AS CL_CODE_TYPE,
          upper(regexp_replace(trim(CL_CODE), '[^A-Za-z0-9]', '')) AS CL_CODE,
          upper(trim(PROCEDURE_TYPE)) AS PROCEDURE_TYPE
        FROM ({proc_sql}) raw
      "), qc = "SELECT PROCEDURE_TYPE, count(*) AS n FROM generic_procedure_codelist GROUP BY PROCEDURE_TYPE")

      # Procedure claims extraction (simplified — disease-specific hooks can override)
      if (!is.null(cfg$claims_mapping$medical_table)) {
        cm <- cfg$claims_mapping
        pid <- cm$patient_id_field
        med_date <- if (!is.null(cm$medical_date_field)) cm$medical_date_field else "FST_DT"

        run_step(con, "Extract procedure claims", glue("
          CREATE OR REPLACE TEMPORARY VIEW generic_lot_procedures AS
          WITH proc_claims AS (
            SELECT m.{pid} AS PATID,
                   cast(m.{med_date} AS date) AS PROCEDURE_DT,
                   pc.PROCEDURE_TYPE
            FROM {cm$medical_table} m
            INNER JOIN {cohort_view_name} p ON m.{pid} = p.{pid}
            INNER JOIN generic_procedure_codelist pc
              ON upper(regexp_replace(coalesce(cast(m.PROC_CD as string),''), '[^A-Za-z0-9]', '')) = pc.CL_CODE
            WHERE cast(m.{med_date} AS date) >= p.INDEX_DATE
              AND cast(m.{med_date} AS date) <= p.OBS_END_DT
          ),
          earliest AS (
            SELECT PATID, PROCEDURE_TYPE, min(PROCEDURE_DT) AS PROCEDURE_END_DT
            FROM proc_claims pc
            INNER JOIN generic_lot1_base lb ON pc.PATID = lb.PATID
            WHERE pc.PROCEDURE_DT >= lb.LOT1_START_DT
            GROUP BY PATID, PROCEDURE_TYPE
          )
          SELECT PATID, min(PROCEDURE_END_DT) AS PROCEDURE_END_DT
          FROM earliest
          GROUP BY PATID
        "), qc = "SELECT count(*) AS n_patients_with_procedures FROM generic_lot_procedures")
        has_procedures <- TRUE
      }
    }
  }

  # --- Step 10: LOT1 end determination ---
  lot1_end_sql <- generate_lot1_end_sql(cfg, has_procedures)
  run_step(con, "LOT1 end determination", lot1_end_sql,
    qc = "SELECT LOT1_BASE_END_REASON, count(*) AS n FROM generic_lot1_base_end GROUP BY LOT1_BASE_END_REASON ORDER BY n DESC")

  # --- Step 11: Multi-line LOT (LOT2+) ---
  multi_lot_sql <- generate_multi_lot_sql(cfg, "generic_map_med", cohort_view_name)
  run_step(con, "Multi-line LOT assignment", multi_lot_sql,
    qc = "SELECT LOT_NUMBER, count(*) AS n_patients FROM generic_lot_multi GROUP BY LOT_NUMBER ORDER BY LOT_NUMBER")

  # --- Persist outputs (optional) ---
  if (!is.null(persist_schema) && nzchar(persist_schema)) {
    lot_log("Persisting output tables to schema: ", persist_schema)

    persist_views <- c(
      "generic_map_med"       = "MAP_STACKED",
      "generic_lot1_base"     = "LOT1_BASE",
      "generic_lot1_base_end" = "LOT1_BASE_END",
      "generic_lot_multi"     = "LOT_MULTI"
    )

    for (view_name in names(persist_views)) {
      tbl_name <- persist_views[[view_name]]
      full_tbl <- paste0(persist_schema, ".", cfg$disease$abbreviation, "_", tbl_name)
      tryCatch({
        run_step(con, paste0("Persist ", tbl_name), glue("
          CREATE TABLE IF NOT EXISTS {full_tbl} AS SELECT * FROM {view_name}
        "))
      }, error = function(e) {
        lot_log("WARNING: Could not persist ", full_tbl, ": ", e$message)
      })
    }
  }

  cat("\n", SEP, "\n")
  lot_log("GENERIC LOT PIPELINE COMPLETE")
  lot_log("Disease: ", cfg$disease$name)
  cat(SEP, "\n")

  invisible(cfg)
}
