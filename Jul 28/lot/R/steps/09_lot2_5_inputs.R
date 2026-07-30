#!/usr/bin/env Rscript
# Rebuild the upstream views lot2_5_base.R needs. 02_lot1.R
# persists MAP_STACKED, LOT1_SCT, LOT1_BASE_END + the cohort input
# table, but the temp views lot_patient_input, sct_codelist,
# sct_claims_raw, tx_auto_dates, tx_allo_cart_dates are session-scoped
# and gone once that script exits. This rebuilds them in a fresh
# session using the same SQL 02_lot1.R uses, with no edits to it.
#
# Codelists (mma_rollup, permissible_subs, sct_codelist) come via the
# CSV loaders in codelists_lot.R; the caller must have sourced that and
# pass the CSV-derived sources.

prepare_lot_inputs <- function(con,
                               rollup_src,
                               subs_src,
                               sct_src) {
  log_msg("Preparing upstream views for LOT2-5 builder...")

  # mma_rollup view - verbatim port of 02_lot1.R S00 so YES/YES%/1/0/NULL
  # values for MONOMAINTENANCE / CONDITIONING / USED_FOR_OTHER_CANCERS parse
  # the same way; otherwise contains_mtx_reg breaks for LOT2-5.
  run_step(con, "P00_mma_rollup", glue("
    CREATE OR REPLACE TEMPORARY VIEW mma_rollup AS
    SELECT
      lower(trim(CL_MEDICATION_FULL)) AS CL_MEDICATION_FULL,
      upper(trim(CL_MED_CLASS))       AS CL_MED_CLASS,
      upper(trim(CL_MED_ABBR))        AS CL_MED_ABBR,
      CASE WHEN upper(trim(cast(MONOMAINTENANCE AS string))) LIKE 'YES%'
            OR  trim(cast(MONOMAINTENANCE AS string)) = '1'
           THEN 1 ELSE 0 END AS MONOMAINTENANCE,
      CASE
        WHEN DUALMAINTENANCEWITH IS NULL
          OR upper(trim(cast(DUALMAINTENANCEWITH AS string))) IN ('', 'NULL', 'NONE', 'NA', 'N/A')
          THEN NULL
        ELSE upper(trim(cast(DUALMAINTENANCEWITH AS string)))
      END AS DUALMAINTENANCEWITH,
      CASE WHEN upper(trim(cast(CONDITIONING AS string))) LIKE 'YES%'
            OR  trim(cast(CONDITIONING AS string)) = '1'
           THEN 1 ELSE 0 END AS CONDITIONING,
      CASE WHEN upper(trim(cast(USED_FOR_OTHER_CANCERS AS string))) LIKE 'YES%'
            OR  trim(cast(USED_FOR_OTHER_CANCERS AS string)) = '1'
           THEN 1 ELSE 0 END AS USED_FOR_OTHER_CANCERS
    FROM {rollup_src}
    -- Steroids are maintained in a separate file, so their codes are not in
    -- cl_mma_codelist.csv. Dropping them here too keeps the two files saying
    -- the same thing: otherwise every run reports rollup medications that can
    -- never be matched, and LOT1 builds always-zero LOT1_MED_<steroid> columns
    -- that LOT2-5 does not carry. build_lot2_5() already filters this way when
    -- it discovers meds and classes - this makes LOT1 agree, which its comment
    -- there already claims.
    WHERE upper(coalesce(CL_MED_CLASS, '')) <> 'STEROID'
    WHERE CL_MED_ABBR IS NOT NULL AND trim(CL_MED_ABBR) <> ''
  "), qc = "SELECT count(*) AS n_rows, sum(MONOMAINTENANCE) AS n_monomaint FROM mma_rollup")

  # Diagnostic + guard: confirm mma_rollup actually has the columns the
  # builder will reference. If the CSV had wrong/extra columns and the
  # view definition above silently picked the wrong field, the next
  # step in lot2_5_base.R fails with an opaque UNRESOLVED_COLUMN error
  # from Databricks. Surface it here with a clear message instead.
  rollup_cols <- tryCatch(
    DBI::dbGetQuery(con, "DESCRIBE mma_rollup"),
    error = function(e) {
      log_msg("  WARN: DESCRIBE mma_rollup failed: ", conditionMessage(e))
      NULL
    }
  )
  if (!is.null(rollup_cols) && is.data.frame(rollup_cols)) {
    col_name_col <- intersect(c("col_name", "COL_NAME", "name", "NAME"),
                              names(rollup_cols))
    if (length(col_name_col) > 0) {
      have <- toupper(as.character(rollup_cols[[col_name_col[1]]]))
      log_msg("  mma_rollup columns (DESCRIBE): ", paste(have, collapse = ", "))
      need <- c("CL_MED_ABBR", "CL_MED_CLASS", "CL_MEDICATION_FULL",
                "MONOMAINTENANCE", "DUALMAINTENANCEWITH",
                "CONDITIONING", "USED_FOR_OTHER_CANCERS")
      missing <- setdiff(need, have)
      if (length(missing) > 0) {
        stop("mma_rollup is missing required columns: ",
             paste(missing, collapse = ", "),
             ". Check that cl_mma_rollup.csv has CL_MED_ABBR, CL_MED_CLASS, etc. ",
             "and that the codelist directory is correct (cfg$codelist_dir = '",
             cfg$codelist_dir, "').")
      }
    }
  }

  # permissible_subs view
  run_step(con, "P02_permissible_subs", glue("
    CREATE OR REPLACE TEMPORARY VIEW permissible_subs AS
    SELECT
      upper(trim(original_med))   AS original_med,
      upper(trim(substitute_med)) AS substitute_med
    FROM {subs_src}
    WHERE original_med IS NOT NULL AND substitute_med IS NOT NULL
  "), qc = "SELECT count(*) AS n_rows FROM permissible_subs")

  # lot_patient_input view: ALWAYS use ENDDATE for OBS_END_DT (primary semantics).
  # Primary semantics ignore disenrollment; the CE cap belongs to
  # the *_CE_SENS columns only. lot2_5_base.R computes those columns
  # unconditionally in the LOT_LONG INSERT, so we do not let
  # cfg$censor_at_disenrollment leak into primary OBS_END_DT.
  if (isTRUE(cfg$censor_at_disenrollment)) {
    log_msg("NOTE: cfg$censor_at_disenrollment=TRUE is set, but the LOT2-5",
            " builder forces OBS_END_DT = ENDDATE for primary analysis.",
            " Sensitivity output appears in LOT_BASE_END_*_CE_SENS columns.")
    log_msg("ASSUMPTION: persisted LOT1_BASE_END was built with",
            " cfg$censor_at_disenrollment=FALSE. If LOT1 was run under",
            " sensitivity, its row in LOT_LONG may already be CE-capped.")
  }
  run_step(con, "P03_patient_input", glue("
    CREATE OR REPLACE TEMPORARY VIEW lot_patient_input AS
    SELECT
      PATID,
      cast(INDEX_DATE AS date)  AS INDEX_DATE,
      cast(ENDDATE AS date)     AS ENDDATE,
      cast(ENDDATE_CE AS date)  AS ENDDATE_CE,
      cast(ENDDATE AS date)     AS OBS_END_DT,
      cast(DEATH_DT AS date)    AS DEATH_DT,
      GDR_CD, YRDOB, AGE_INDEX_YR, FU_DAYS, FU_DAYS_CE
    FROM {wrk(cfg$input_cohort_table)}
  "), qc = "SELECT count(*) AS n_patients FROM lot_patient_input")

  # sct_codelist view (matches 02_lot1.R S11)
  run_step(con, "P11_sct_codelist", glue("
    CREATE OR REPLACE TEMPORARY VIEW sct_codelist AS
    SELECT
      CASE
        WHEN upper(trim(CL_CODE_TYPE)) IN ('ICD10PROC', 'ICD10PCS') THEN 'ICD10PROC'
        WHEN upper(trim(CL_CODE_TYPE)) = 'ICD9PROC' THEN 'ICD9PROC'
        WHEN upper(trim(CL_CODE_TYPE)) LIKE '%PROC%'
          OR upper(trim(CL_CODE_TYPE)) = 'ICD' THEN 'ICD10PROC'
        WHEN upper(trim(CL_CODE_TYPE)) IN ('ICD10DIAG', 'ICD10DX', 'DIAG10')
          OR upper(trim(CL_CODE_TYPE)) LIKE 'ICD%10%DIAG%' THEN 'ICD10DIAG'
        WHEN upper(trim(CL_CODE_TYPE)) IN ('ICD9DIAG', 'ICD9DX', 'ICD9', 'DIAG9')
          OR upper(trim(CL_CODE_TYPE)) LIKE 'ICD%9%DIAG%' THEN 'ICD9DIAG'
        WHEN upper(trim(CL_CODE_TYPE)) IN ('DIAG', 'DX', 'DIAGNOSIS') THEN 'ICD10DIAG'
        WHEN upper(trim(CL_CODE_TYPE)) IN ('CPT', 'CPT4') THEN 'HCPCS'
        ELSE upper(trim(CL_CODE_TYPE))
      END AS CL_CODE_TYPE,
      upper(regexp_replace(trim(CL_CODE), '[^A-Za-z0-9]', '')) AS CL_CODE,
      CASE
        WHEN upper(trim(SCT_TYPE)) LIKE 'ALLO%' THEN 'ALLO'
        WHEN upper(trim(SCT_TYPE)) LIKE 'AUTO%' THEN 'AUTO'
        WHEN upper(trim(SCT_TYPE)) IN ('CAR-T', 'CART', 'CAR_T') THEN 'CART'
        ELSE upper(trim(SCT_TYPE))
      END AS SCT_TYPE
    FROM {sct_src}
    WHERE CL_CODE IS NOT NULL AND trim(CL_CODE) <> ''
      AND SCT_TYPE IS NOT NULL AND trim(SCT_TYPE) <> ''
  "), qc = "SELECT count(*) AS n_rows FROM sct_codelist")

  # sct_claims_raw view (matches 02_lot1.R S12)
  run_step(con, "P12_sct_claims_raw", glue("
    CREATE OR REPLACE TEMPORARY VIEW sct_claims_raw AS
    WITH sct_codes AS (SELECT /*+ BROADCAST */ * FROM sct_codelist),
    med_proc AS (
      SELECT m.PATID, cast(m.FST_DT AS date) AS DATE_SERVICE,
             s.SCT_TYPE, s.CL_CODE AS CODE
      FROM {cdm_src(cfg$tbl_medical)} m
      INNER JOIN lot_patient_input p ON m.PATID = p.PATID
      INNER JOIN sct_codes s
        ON s.CL_CODE_TYPE = 'HCPCS'
       AND upper(regexp_replace(coalesce(cast(m.PROC_CD as string),''), '[^A-Za-z0-9]', '')) = s.CL_CODE
      WHERE cast(m.FST_DT AS date) >= p.INDEX_DATE
        AND cast(m.FST_DT AS date) <= p.OBS_END_DT
    ),
    med_bill AS (
      SELECT m.PATID, cast(m.FST_DT AS date) AS DATE_SERVICE,
             s.SCT_TYPE, s.CL_CODE AS CODE
      FROM {cdm_src(cfg$tbl_medical)} m
      INNER JOIN lot_patient_input p ON m.PATID = p.PATID
      INNER JOIN sct_codes s
        ON s.CL_CODE_TYPE = 'HCPCS'
       AND upper(regexp_replace(coalesce(cast(m.BILL_PROC_CD as string),''), '[^A-Za-z0-9]', '')) = s.CL_CODE
      WHERE cast(m.FST_DT AS date) >= p.INDEX_DATE
        AND cast(m.FST_DT AS date) <= p.OBS_END_DT
    ),
    medproc AS (
      SELECT mp.PATID, cast(mp.FST_DT AS date) AS DATE_SERVICE,
             s.SCT_TYPE, s.CL_CODE AS CODE
      FROM {cdm_src(cfg$tbl_med_proc)} mp
      INNER JOIN lot_patient_input p ON mp.PATID = p.PATID
      INNER JOIN sct_codes s
        ON (  (s.CL_CODE_TYPE = 'ICD10PROC'
               AND coalesce(upper(mp.ICD_FLAG), '') NOT IN ('9', 'ICD9', 'ICD-9'))
           OR (s.CL_CODE_TYPE = 'ICD9PROC'
               AND upper(mp.ICD_FLAG) IN ('9', 'ICD9', 'ICD-9'))
           OR s.CL_CODE_TYPE = 'HCPCS')
       AND upper(regexp_replace(coalesce(cast(mp.PROC as string),''), '[^A-Za-z0-9]', '')) = s.CL_CODE
      WHERE cast(mp.FST_DT AS date) >= p.INDEX_DATE
        AND cast(mp.FST_DT AS date) <= p.OBS_END_DT
    ),
    med_diag AS (
      SELECT d.PATID, cast(d.FST_DT AS date) AS DATE_SERVICE,
             s.SCT_TYPE, s.CL_CODE AS CODE
      FROM {cdm_src(cfg$tbl_med_diag)} d
      INNER JOIN lot_patient_input p ON d.PATID = p.PATID
      INNER JOIN sct_codes s
        ON (  (s.CL_CODE_TYPE = 'ICD10DIAG'
               AND coalesce(upper(d.ICD_FLAG), '') NOT IN ('9', 'ICD9', 'ICD-9'))
           OR (s.CL_CODE_TYPE = 'ICD9DIAG'
               AND upper(d.ICD_FLAG) IN ('9', 'ICD9', 'ICD-9')))
       AND upper(regexp_replace(coalesce(cast(d.DIAG as string),''), '[^A-Za-z0-9]', '')) = s.CL_CODE
      WHERE cast(d.FST_DT AS date) >= p.INDEX_DATE
        AND cast(d.FST_DT AS date) <= p.OBS_END_DT
    ),
    combined AS (
      SELECT * FROM med_proc
      UNION ALL SELECT * FROM med_bill
      UNION ALL SELECT * FROM medproc
      UNION ALL SELECT * FROM med_diag
    )
    SELECT PATID, DATE_SERVICE, SCT_TYPE, min(CODE) AS CODE
    FROM combined
    GROUP BY PATID, DATE_SERVICE, SCT_TYPE
  "), qc = NULL)  # QC deferred to P12b materialization to avoid re-scanning raw CDM tables.

  # Materialize sct_claims_raw: it is the upstream heavy CDM-scan view that
  # feeds both TX_AUTO_DATES and TX_ALLO_CART_DATES. Without this, each of
  # those materializations would re-run the raw CDM scan. Persisting once
  # collapses both downstream materializations to cheap table reads.
  run_step(con, "P12b_materialize_sct_claims_raw", glue("
    CREATE OR REPLACE TABLE {lot_out('SCT_CLAIMS_RAW')} AS SELECT * FROM sct_claims_raw
  "), qc = glue("
    SELECT SCT_TYPE, count(*) AS n_claims, count(DISTINCT PATID) AS n_patients,
           min(DATE_SERVICE) AS min_date, max(DATE_SERVICE) AS max_date
    FROM {lot_out('SCT_CLAIMS_RAW')}
    GROUP BY SCT_TYPE
    ORDER BY SCT_TYPE"))
  db_exec(con, sprintf(
    "CREATE OR REPLACE TEMPORARY VIEW sct_claims_raw AS SELECT * FROM %s",
    lot_out("SCT_CLAIMS_RAW")
  ))

  # tx_auto_dates view (matches 02_lot1.R S13).
  # Verbatim aggregate state-machine - if 02_lot1.R S13 is updated,
  # update this block to match.
  run_step(con, "P13_tx_auto_dates", glue("
    CREATE OR REPLACE TEMPORARY VIEW tx_auto_dates AS
    WITH auto_dates AS (
      SELECT DISTINCT PATID, DATE_SERVICE AS dt
      FROM sct_claims_raw WHERE SCT_TYPE = 'AUTO'
    ),
    grouped AS (
      SELECT PATID, sort_array(collect_list(dt)) AS dates_arr
      FROM auto_dates GROUP BY PATID
    ),
    processed AS (
      SELECT PATID,
        aggregate(
          dates_arr,
          named_struct(
            'tx_dates', cast(array() as array<date>),
            'cur_start', cast(null as date),
            'cur_max_dt', cast(null as date),
            'cur_boundary_dt', cast(null as date),
            'cur_boundary_dist', cast(null as int),
            'last_tx_dt', cast(null as date)
          ),
          (s, x) -> CASE
            WHEN s.cur_start IS NULL THEN
              named_struct('tx_dates', s.tx_dates, 'cur_start', x, 'cur_max_dt', x,
                           'cur_boundary_dt', cast(null as date),
                           'cur_boundary_dist', cast(null as int),
                           'last_tx_dt', s.last_tx_dt)
            WHEN datediff(x, s.cur_start) <= {cfg$sct_auto_window_days} THEN
              named_struct('tx_dates', s.tx_dates, 'cur_start', s.cur_start, 'cur_max_dt', x,
                           'cur_boundary_dt', CASE
                             WHEN s.last_tx_dt IS NULL THEN NULL
                             WHEN abs(datediff(x, date_add(s.last_tx_dt, {cfg$sct_tandem_days} - 1)))
                                  <= {cfg$sct_auto_window_days}
                              AND (s.cur_boundary_dist IS NULL
                                   OR abs(datediff(x, date_add(s.last_tx_dt, {cfg$sct_tandem_days} - 1)))
                                      < s.cur_boundary_dist)
                               THEN x
                             ELSE s.cur_boundary_dt
                           END,
                           'cur_boundary_dist', CASE
                             WHEN s.last_tx_dt IS NULL THEN NULL
                             WHEN abs(datediff(x, date_add(s.last_tx_dt, {cfg$sct_tandem_days} - 1)))
                                  <= {cfg$sct_auto_window_days}
                              AND (s.cur_boundary_dist IS NULL
                                   OR abs(datediff(x, date_add(s.last_tx_dt, {cfg$sct_tandem_days} - 1)))
                                      < s.cur_boundary_dist)
                               THEN abs(datediff(x, date_add(s.last_tx_dt, {cfg$sct_tandem_days} - 1)))
                             ELSE s.cur_boundary_dist
                           END,
                           'last_tx_dt', s.last_tx_dt)
            ELSE
              CASE
                WHEN s.last_tx_dt IS NOT NULL
                 AND datediff(coalesce(s.cur_boundary_dt, s.cur_max_dt), s.last_tx_dt) < {cfg$sct_auto_gap_days}
                THEN named_struct('tx_dates', s.tx_dates, 'cur_start', x, 'cur_max_dt', x,
                                  'cur_boundary_dt', CASE
                                    WHEN abs(datediff(x, date_add(s.last_tx_dt, {cfg$sct_tandem_days} - 1)))
                                         <= {cfg$sct_auto_window_days}
                                    THEN x ELSE NULL END,
                                  'cur_boundary_dist', CASE
                                    WHEN abs(datediff(x, date_add(s.last_tx_dt, {cfg$sct_tandem_days} - 1)))
                                         <= {cfg$sct_auto_window_days}
                                    THEN abs(datediff(x, date_add(s.last_tx_dt, {cfg$sct_tandem_days} - 1)))
                                    ELSE NULL END,
                                  'last_tx_dt', s.last_tx_dt)
                ELSE named_struct(
                       'tx_dates', array_append(s.tx_dates, coalesce(s.cur_boundary_dt, s.cur_max_dt)),
                       'cur_start', x, 'cur_max_dt', x,
                       'cur_boundary_dt', CASE
                         WHEN abs(datediff(x, date_add(coalesce(s.cur_boundary_dt, s.cur_max_dt), {cfg$sct_tandem_days} - 1)))
                              <= {cfg$sct_auto_window_days}
                         THEN x ELSE NULL END,
                       'cur_boundary_dist', CASE
                         WHEN abs(datediff(x, date_add(coalesce(s.cur_boundary_dt, s.cur_max_dt), {cfg$sct_tandem_days} - 1)))
                              <= {cfg$sct_auto_window_days}
                         THEN abs(datediff(x, date_add(coalesce(s.cur_boundary_dt, s.cur_max_dt), {cfg$sct_tandem_days} - 1)))
                         ELSE NULL END,
                       'last_tx_dt', coalesce(s.cur_boundary_dt, s.cur_max_dt))
              END
          END,
          s -> CASE
            WHEN s.cur_start IS NULL THEN s.tx_dates
            WHEN s.last_tx_dt IS NOT NULL
             AND datediff(coalesce(s.cur_boundary_dt, s.cur_max_dt), s.last_tx_dt) < {cfg$sct_auto_gap_days}
            THEN s.tx_dates
            ELSE array_append(s.tx_dates, coalesce(s.cur_boundary_dt, s.cur_max_dt))
          END
        ) AS tx_dates
      FROM grouped
    ),
    exploded AS (
      SELECT PATID, posexplode(tx_dates) AS (pos, TX_DT) FROM processed
    )
    SELECT PATID, pos + 1 AS TX_SEQ, TX_DT FROM exploded
  "), qc = NULL)  # QC deferred to P15 materialization to avoid double-evaluating the heavy AUTO aggregate.

  # tx_allo_cart_dates view (matches 02_lot1.R S14)
  run_step(con, "P14_tx_allo_cart_dates", "
    CREATE OR REPLACE TEMPORARY VIEW tx_allo_cart_dates AS
    WITH allo_dates AS (
      SELECT DISTINCT PATID, DATE_SERVICE AS dt FROM sct_claims_raw WHERE SCT_TYPE = 'ALLO'
    ),
    cart_dates AS (
      SELECT DISTINCT PATID, DATE_SERVICE AS dt FROM sct_claims_raw WHERE SCT_TYPE = 'CART'
    ),
    allo_seq AS (
      SELECT PATID, 'ALLO' AS SCT_TYPE, dt AS TX_DT,
             row_number() OVER (PARTITION BY PATID ORDER BY dt) AS TX_SEQ FROM allo_dates
    ),
    cart_seq AS (
      SELECT PATID, 'CART' AS SCT_TYPE, dt AS TX_DT,
             row_number() OVER (PARTITION BY PATID ORDER BY dt) AS TX_SEQ FROM cart_dates
    )
    SELECT * FROM allo_seq UNION ALL SELECT * FROM cart_seq
  ", qc = NULL)  # QC deferred to P15 materialization to avoid re-evaluating the SCT scan twice.

  # Rebind the persisted LOT1 outputs to the temp view names lot2_5_base.R
  # uses. Only the tables actually referenced by lot2_5_base.R are rebound
  # (LOT1_BASE is persisted by LOT1 but not consumed here).
  for (tbl in c("MAP_STACKED", "LOT1_SCT", "LOT1_BASE_END")) {
    db_exec(con, sprintf(
      "CREATE OR REPLACE TEMPORARY VIEW %s AS SELECT * FROM %s",
      tolower(tbl), lot_out(tbl)
    ))
  }

  # Materialize tx_auto_dates and tx_allo_cart_dates as work-schema TABLES.
  # Both are temp views built from the heavy AUTO aggregate state-machine
  # / SCT scan. Each LOT iteration in build_lot2_5 reads tx_auto_dates 2x
  # and tx_allo_cart_dates 5x; without materialization Spark re-evaluates
  # the aggregate every time, costing ~8 AUTO-aggregate runs and ~20 SCT
  # scan runs across LOT2..LOT5. Materializing once collapses all
  # downstream reads to cheap table scans.
  # P13 / P14 build temp views without QC; P15 materializes once and the
  # QC runs against the cheap table scan, so the heavy aggregate / SCT scan
  # evaluates only once total instead of twice.
  for (mv in list(
    list(name = "TX_AUTO_DATES",
         view = "tx_auto_dates",
         qc   = glue("SELECT count(*) AS n_rows, count(DISTINCT PATID) AS n_patients,
                             min(TX_SEQ) AS min_seq, max(TX_SEQ) AS max_seq
                      FROM {lot_out('TX_AUTO_DATES')}")),
    list(name = "TX_ALLO_CART_DATES",
         view = "tx_allo_cart_dates",
         qc   = glue("SELECT SCT_TYPE, count(*) AS n_rows, count(DISTINCT PATID) AS n_patients
                      FROM {lot_out('TX_ALLO_CART_DATES')} GROUP BY SCT_TYPE ORDER BY SCT_TYPE"))
  )) {
    run_step(con, paste0("P15_materialize_", tolower(mv$name)), glue("
      CREATE OR REPLACE TABLE {lot_out(mv$name)} AS SELECT * FROM {mv$view}
    "), qc = mv$qc)
    db_exec(con, sprintf(
      "CREATE OR REPLACE TEMPORARY VIEW %s AS SELECT * FROM %s",
      mv$view, lot_out(mv$name)
    ))
  }

  log_msg("Upstream views ready.")
}
