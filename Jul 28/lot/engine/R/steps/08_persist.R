# Write the outputs. Every table goes through lot_out(), so it carries the
# cohort prefix and cannot overwrite another cohort's.

phase_persist <- function(con, ctx) {
  if (isTRUE(cfg$persist_to_schema)) {
    # No table is copied here. MAP_STACKED, MMA_MED_PROCESSED, LOT1_BASE,
    # LOT1_SCT and LOT1_BASE_END are each written by the step that builds them,
    # with their views repointed at the table. A copy at this phase would come
    # too late: every read before it - phase_lot1_base, phase_lot1_sct,
    # phase_qc, the LOT1 invariants - would re-run the query instead.
    #
    # So the counts below read tables. They count what this run built, which is
    # what the metadata row is for.

    # Save the run metadata: the parameters and the headline counts, so two
    # runs can be compared.
    tryCatch({
      cohort_n <- as.numeric(db_q(con, "SELECT count(DISTINCT PATID) AS n FROM lot_patient_input")$n)
      mma_n    <- as.numeric(db_q(con, "SELECT count(*) AS n FROM mma_med_processed")$n)
      map_n    <- as.numeric(db_q(con, "SELECT count(*) AS n FROM map_stacked")$n)
      lot1_n   <- as.numeric(db_q(con, "SELECT count(*) AS n FROM lot1_base")$n)

      # Create the metadata table if it is not there, with the current
      # schema.
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
      # column that is already there is an error.
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
      # The DELETE clears any earlier row for this run_id and the INSERT
      # writes the new one. One step, retried from the DELETE: split into two
      # steps they are retried apart, and an INSERT whose answer was lost is
      # sent twice after the DELETE that would have cleared the first has
      # already run.
      #
      # The INSERT names its columns. ALTER TABLE adds new ones at the end
      # rather than in place, and an older table may still carry columns since
      # removed, so position cannot be trusted.
      run_step(con, "S22b_write_run_metadata", c(
        glue("DELETE FROM {lot_out('LOT_RUN_METADATA')} WHERE RUN_ID = '{run_id}'"),
        glue("
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
      ")), retry_as_unit = TRUE)
    }, error = function(e) {
      log_msg("  WARNING: Run metadata persist failed: ", conditionMessage(e))
    })

    # Save the QC summary: one row per check, for governance.
    tryCatch({
      # The QC checks as data: a name, and SQL returning one count.
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
      # One step for the same reason as the metadata write above.
      run_step(con, "S23b_write_qc_summary", c(
        glue("DELETE FROM {lot_out('LOT_QC_SUMMARY')} WHERE RUN_ID = '{run_id}'"),
        glue("
        INSERT INTO {lot_out('LOT_QC_SUMMARY')}
        {qc_union}
      ")), retry_as_unit = TRUE)
    }, error = function(e) {
      log_msg("  WARNING: QC summary persist failed: ", conditionMessage(e))
    })

  }
  # No disabled branch: check_lot_contract() stops any run without
  # PERSIST_TO_SCHEMA=TRUE before a connection opens.
}
