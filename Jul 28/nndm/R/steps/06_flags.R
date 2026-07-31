# One row per patient carrying every filter's verdict.
#
# Ported from apr_30_2026/06_ndmm_dashboard.R lines 622-755.
# tests/test_same_as_source.R compares this against that range.

build_ndmm_flags <- function(con, elig_coh_final, map_stacked,
                           q2_ok_belantamab, q2_ok_priortx,
                           q2_ok_othercancer, q2_ok_pregnancy = NULL) {
  if (is.null(q2_ok_pregnancy))
    q2_ok_pregnancy <- .ndmm_table_ok(con, NDMM_PREGNANCY_PATIDS)
  bela_expr <- if (q2_ok_belantamab) glue("
        SELECT DISTINCT cast(PATID as string) AS PATID
        FROM {map_stacked}
        WHERE upper(MAP_MED_TYPE) LIKE 'BEL%'
  ") else "SELECT cast(NULL as string) AS PATID WHERE 1 = 0"

  prior_tx_expr <- if (q2_ok_priortx) glue("
        SELECT DISTINCT PATID FROM {NDMM_THERAPY_PRE_LOT1}
  ") else "SELECT cast(NULL as string) AS PATID WHERE 1 = 0"

  other_cancer_expr <- if (q2_ok_othercancer) glue("
        SELECT DISTINCT cast(PATID as string) AS PATID FROM {NDMM_OTHER_MALIG_PATIDS}
  ") else "SELECT cast(NULL as string) AS PATID WHERE 1 = 0"

  pregnancy_expr <- if (q2_ok_pregnancy) glue("
        SELECT DISTINCT cast(PATID as string) AS PATID FROM {NDMM_PREGNANCY_PATIDS}
  ") else "SELECT cast(NULL as string) AS PATID WHERE 1 = 0"

  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_FLAGS_ALL} AS
    WITH ec_l1 AS (
      SELECT cast(ec.PATID as string) AS PATID, l1.LOT1_START_DT,
             date_sub(l1.LOT1_START_DT, {NDMM_PRE_LOT1_DAYS}) AS pre_lot1_start,
             date_sub(l1.LOT1_START_DT, 1)                  AS pre_lot1_end,
             -- DEATH_DT is carried forward from the parent ELIG_COH_FINAL so
             -- the 3-month follow-up CE below can be re-derived ANCHORED AT
             -- LOT1 (the NDMM index); the parent CE_3mosf is anchored at the
             -- MM-dx index and so is NOT reused for it. Pregnancy is NOT carried
             -- from the parent flag - it is re-scanned from pregnancy.csv over
             -- the study period (NDMM_PREGNANCY_PATIDS).
             cast(ec.DEATH_DT as date)     AS DEATH_DT
      FROM {elig_coh_final} ec
      INNER JOIN {NDMM_LOT1_STARTS} l1
              ON cast(ec.PATID as string) = l1.PATID
    ),
    ce AS (
      SELECT ec_l1.PATID,
             max(CASE WHEN s.cov_start <= ec_l1.pre_lot1_start
                       AND s.cov_end   >= ec_l1.pre_lot1_end
                      THEN 1 ELSE 0 END) AS CE_pre_lot1_12mo
      FROM ec_l1
      LEFT JOIN {NDMM_ENROLL_SPANS} s ON s.PATID = ec_l1.PATID
      GROUP BY ec_l1.PATID
    ),
    -- 3-month follow-up CE re-derived ANCHORED AT LOT1 (the NDMM index): a
    -- span must cover [LOT1_START, least(LOT1_START + 90, study_end, death)].
    -- Uses NDMM_ENROLL_SPANS_STRICT (no-gap spans, gap_days=0):
    -- 'no gaps in enrollment' for the follow-up CE, vs <30-day gaps allowed
    -- for the 12-mo pre-LOT1 CE. Plus the carried-forward DEATH_DT.
    fuce AS (
      SELECT ec_l1.PATID,
             max(CASE WHEN s.cov_start <= ec_l1.LOT1_START_DT
                       AND s.cov_end   >= least(date_add(ec_l1.LOT1_START_DT, 90),
                                                date('{cfg$study_end}'),
                                                coalesce(ec_l1.DEATH_DT, date('{cfg$study_end}')))
                      THEN 1 ELSE 0 END) AS CE_lot1_3mo
      FROM ec_l1
      LEFT JOIN {NDMM_ENROLL_SPANS_STRICT} s ON s.PATID = ec_l1.PATID
      GROUP BY ec_l1.PATID
    ),
    bela AS ({bela_expr}),
    prior_tx AS ({prior_tx_expr}),
    other_cancer AS ({other_cancer_expr}),
    pregnancy AS ({pregnancy_expr})
    SELECT ec_l1.PATID,
           ce.CE_pre_lot1_12mo,
           coalesce(fuce.CE_lot1_3mo, 0)                        AS CE_lot1_3mo_fu,
           CASE WHEN bela.PATID         IS NULL THEN 1 ELSE 0 END AS NO_BELANTAMAB,
           CASE WHEN prior_tx.PATID     IS NULL THEN 1 ELSE 0 END AS NO_PRIOR_MM_TX,
           CASE WHEN other_cancer.PATID IS NULL THEN 1 ELSE 0 END AS NO_OTHER_CANCER_PRE_LOT1,
           CASE WHEN pregnancy.PATID    IS NULL THEN 1 ELSE 0 END AS NO_PREGNANCY
    FROM ec_l1
    LEFT JOIN ce           ON ec_l1.PATID = ce.PATID
    LEFT JOIN fuce         ON ec_l1.PATID = fuce.PATID
    LEFT JOIN bela         ON ec_l1.PATID = bela.PATID
    LEFT JOIN prior_tx     ON ec_l1.PATID = prior_tx.PATID
    LEFT JOIN other_cancer ON ec_l1.PATID = other_cancer.PATID
    LEFT JOIN pregnancy    ON ec_l1.PATID = pregnancy.PATID
  "))

  # Materialize NDMM_FLAGS_ALL once, then repoint the view at the physical
  # work-schema table. As a bare TEMPORARY VIEW this re-runs the whole scan
  # DAG (pregnancy + belantamab + prior-Tx + other-cancer over the study
  # period, plus both enrollment-span builds) on EVERY read - and it is read
  # heavily: ndmm_counts() alone issues six COUNT(DISTINCT) queries against
  # it (one per funnel step), then NDMM_PATIDS, the dashboard sections and the
  # validation drilldown read it again. Recomputing the scans six-plus times
  # back-to-back is what makes the NDMM stage appear to hang right after the
  # Overall attrition figure. Materializing collapses that to one computation;
  # every later read (including NDMM_PATIDS below) hits the table. Mirrors the
  # parent's S16 materialize-and-repoint (02_lot1.R); CACHE TABLE is not
  # available on SQL warehouses. The write is unconditional (not gated on
  # cfg$persist_to_schema, which governs the FINAL persist to the personal
  # schema, not intermediate work-schema materializations - same as the
  # parent's S16).
  #
  # Fail-safe: the parent assumes a writable work schema; this is a dashboard,
  # so if the CREATE TABLE is refused (e.g. a read-only work schema) we WARN
  # and keep the in-place temp view rather than aborting. Downstream numbers
  # are still correct - just recomputed on each read, i.e. slower.
  tryCatch({
    run_step(con, "S_ndmm_materialize_flags_all", glue("
      CREATE OR REPLACE TABLE {wrk(NDMM_FLAGS_ALL_TBL)} AS
      SELECT * FROM {NDMM_FLAGS_ALL}
    "), qc = glue("SELECT count(*) AS n_rows FROM {wrk(NDMM_FLAGS_ALL_TBL)}"))
    db_exec(con, glue("
      CREATE OR REPLACE TEMPORARY VIEW {NDMM_FLAGS_ALL} AS
      SELECT * FROM {wrk(NDMM_FLAGS_ALL_TBL)}
    "))
  }, error = function(e) {
    log_msg("WARN: could not materialize ", wrk(NDMM_FLAGS_ALL_TBL), " (",
            conditionMessage(e), "); keeping the in-place temp view - NDMM ",
            "counts/dashboard stay correct but run slower (flag scans are ",
            "recomputed on each read).")
  })

  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_PATIDS} AS
    SELECT PATID FROM {NDMM_FLAGS_ALL}
    WHERE CE_pre_lot1_12mo        = 1
      AND NO_BELANTAMAB           = 1
      AND NO_PRIOR_MM_TX          = 1
      AND NO_OTHER_CANCER_PRE_LOT1 = 1
      AND CE_lot1_3mo_fu          = 1
      AND NO_PREGNANCY            = 1
  "))
}

# Filtered LOT_LONG view feeding the regimen-transition helpers.
