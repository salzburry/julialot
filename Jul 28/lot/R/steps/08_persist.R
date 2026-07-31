# Write the outputs. Every table goes through lot_out(), so it carries the
# cohort prefix and cannot overwrite another cohort's.

phase_persist <- function(con, ctx) {
  if (isTRUE(cfg$persist_to_schema)) {
    # MAP_STACKED, LOT1_BASE, LOT1_SCT already materialized before S16.
    # Only persist the remaining outputs here.
    persist_tables <- list(
      list(step = "S20", name = "LOT1_BASE_END",     view = "lot1_base_end"),
      list(step = "S21", name = "MMA_MED_PROCESSED", view = "mma_med_processed")
    )
    for (pt in persist_tables) {
      run_step(con, paste0(pt$step, "_persist_", tolower(pt$name)), glue("
        CREATE OR REPLACE TABLE {lot_out(pt$name)} AS
        SELECT * FROM {pt$view}
      "), qc = glue("SELECT count(*) AS n_rows FROM {lot_out(pt$name)}"))
    }

    # Persist run metadata - parameters + key counts for rerun comparison
    tryCatch({
      cohort_n <- as.numeric(db_q(con, "SELECT count(DISTINCT PATID) AS n FROM lot_patient_input")$n)
      mma_n    <- as.numeric(db_q(con, "SELECT count(*) AS n FROM mma_med_processed")$n)
      map_n    <- as.numeric(db_q(con, "SELECT count(*) AS n FROM map_stacked")$n)
      lot1_n   <- as.numeric(db_q(con, "SELECT count(*) AS n FROM lot1_base")$n)

      # Create metadata table if not exists (full current schema).
      run_step(con, "S22a_create_metadata_table", glue("
        CREATE TABLE IF NOT EXISTS {lot_out('LOT_RUN_METADATA')} (
          RUN_ID STRING, RUN_TIMESTAMP TIMESTAMP,
          CDM_SCHEMA STRING, WORK_SCHEMA STRING, INPUT_COHORT_TABLE STRING,
          INDUCTION_WINDOW_DAYS INT, INDUCTION_WINDOW_DAYS_LOT_N INT,
          MAP_DISCON_GAP_DAYS INT, MEDICAL_DAY_SUPPLY INT,
          N_COHORT_PATIENTS BIGINT, N_MMA_CLAIMS BIGINT,
          N_MAPS BIGINT, N_LOT1_PATIENTS BIGINT
        )
      "))
      # An older table may pre-date INDUCTION_WINDOW_DAYS_LOT_N, and CREATE
      # TABLE IF NOT EXISTS will not add it. Look before altering: adding a
      # column that is already there errors.
      have_cols <- tryCatch({
        d  <- db_q(con, glue("DESCRIBE {lot_out('LOT_RUN_METADATA')}"))
        cn <- intersect(c("col_name", "COL_NAME", "name", "NAME"), names(d))
        if (length(cn)) toupper(trimws(as.character(d[[cn[1]]]))) else character(0)
      }, error = function(e) character(0))
      if (!("INDUCTION_WINDOW_DAYS_LOT_N" %in% have_cols)) {
        tryCatch({
          db_exec(con, glue("
            ALTER TABLE {lot_out('LOT_RUN_METADATA')} ADD COLUMNS (INDUCTION_WINDOW_DAYS_LOT_N INT)
          "))
          log_msg("  Metadata schema evolution: added INDUCTION_WINDOW_DAYS_LOT_N")
        }, error = function(e) {
          msg <- conditionMessage(e)
          if (!grepl("already exists|AlreadyExists|FIELD_ALREADY_EXISTS|DELTA_ADD_COLUMN_PARENT_NOT_STRUCT",
                     msg, ignore.case = TRUE)) {
            log_msg("  Metadata schema evolution warning: ", msg)
          }
        })
      } else {
        log_msg("  Metadata schema: INDUCTION_WINDOW_DAYS_LOT_N already present (no migration needed)")
      }
      # Delete any prior row for this exact run_id (idempotent re-runs)
      run_step(con, "S22b_dedup_metadata", glue("
        DELETE FROM {lot_out('LOT_RUN_METADATA')} WHERE RUN_ID = '{run_id}'
      "))
      # Explicit column list - robust against column ordering after ALTER
      # TABLE on older schemas (new columns are appended, not inserted in
      # the original position) and against extra legacy columns
      # (e.g. LOT_DISCON_GAP_DAYS on tables created before its removal).
      run_step(con, "S22c_insert_run_metadata", glue("
        INSERT INTO {lot_out('LOT_RUN_METADATA')} (
          RUN_ID, RUN_TIMESTAMP, CDM_SCHEMA, WORK_SCHEMA, INPUT_COHORT_TABLE,
          INDUCTION_WINDOW_DAYS, INDUCTION_WINDOW_DAYS_LOT_N,
          MAP_DISCON_GAP_DAYS, MEDICAL_DAY_SUPPLY,
          N_COHORT_PATIENTS, N_MMA_CLAIMS, N_MAPS, N_LOT1_PATIENTS
        )
        SELECT
          '{run_id}',
          current_timestamp(),
          '{cfg$cdm_schema}',
          '{cfg$work_schema}',
          '{cfg$input_cohort_table}',
          {cfg$induction_window_days},
          {cfg$lot_n_induction_window_days},
          {cfg$map_discon_gap_days},
          {cfg$medical_day_supply},
          {sql_count(cohort_n)},
          {sql_count(mma_n)},
          {sql_count(map_n)},
          {sql_count(lot1_n)}
      "))
    }, error = function(e) {
      log_msg("  WARNING: Run metadata persist failed: ", conditionMessage(e))
    })

    # Persist QC summary - one row per check for governance
    tryCatch({
      # Table-driven QC checks: name -> SQL that returns a single count
      qc_defs <- list(
        list(name = "CODELIST_ORPHAN_MEDS", sql = "
          SELECT count(DISTINCT c.CL_MED_ABBR) AS n
          FROM mma_extractable_codelist c LEFT JOIN mma_rollup r ON c.CL_MED_ABBR = r.CL_MED_ABBR
          WHERE r.CL_MED_ABBR IS NULL"),
        list(name = "MAP_END_BEFORE_START", sql = "
          SELECT count(*) AS n FROM map_stacked WHERE MAP_END_DT < MAP_START_DT"),
        list(name = "LOT1_END_PAST_OBS", sql = "
          SELECT sum(case when lb.LOT1_BASE_END_DT > p.OBS_END_DT then 1 else 0 end) AS n
          FROM lot1_base_end lb INNER JOIN lot_patient_input p ON lb.PATID = p.PATID"),
        list(name = "SCT_TANDEM_AND_SINGLE", sql = "
          SELECT sum(CASE WHEN LOT1_SCT_AUTO_TAND_FLG = 1 AND LOT1_SCT_AUTO_SING_FLG = 1 THEN 1 ELSE 0 END) AS n
          FROM lot1_sct")
      )
      qc_rows <- vapply(qc_defs, function(qd) {
        val <- tryCatch(as.numeric(db_q(con, qd$sql)$n), error = function(e) NA)
        status <- if (is.na(val)) "ERROR" else if (val == 0) "PASS" else "WARN"
        glue("SELECT '{qd$name}' AS CHECK_NAME, {sql_count(val)} AS CHECK_VALUE, '{status}' AS CHECK_STATUS, '{run_id}' AS RUN_ID")
      }, character(1))

      qc_union <- paste(qc_rows, collapse = "\n        UNION ALL\n        ")
      run_step(con, "S23a_create_qc_table", glue("
        CREATE TABLE IF NOT EXISTS {lot_out('LOT_QC_SUMMARY')} (
          CHECK_NAME STRING, CHECK_VALUE BIGINT, CHECK_STATUS STRING, RUN_ID STRING
        )
      "))
      run_step(con, "S23b_dedup_qc", glue("
        DELETE FROM {lot_out('LOT_QC_SUMMARY')} WHERE RUN_ID = '{run_id}'
      "))
      run_step(con, "S23c_insert_qc_summary", glue("
        INSERT INTO {lot_out('LOT_QC_SUMMARY')}
        {qc_union}
      "))
    }, error = function(e) {
      log_msg("  WARNING: QC summary persist failed: ", conditionMessage(e))
    })

  } else {
    log_msg("Persist disabled (PERSIST_TO_SCHEMA=FALSE).")
  }
}
