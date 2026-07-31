# The filtered cohort, and the counts the attrition is read from.
#
# Ported from apr_30_2026/06_ndmm_dashboard.R lines 756-839.
# tests/test_same_as_source.R compares this against that range.

build_lot_long_filtered <- function(con, lot_long) {
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_LOT_LONG_FILT} AS
    SELECT l.*
    FROM {lot_long} l
    INNER JOIN {NDMM_PATIDS} a
            ON cast(l.PATID as string) = a.PATID
  "))

  # Materialize once, then repoint the view at the work-schema table. This
  # filtered LOT_LONG is read ~20x downstream (NDMM augmentation, modal map,
  # KPIs, gallery, validation, run-comparison, and ~13x inside the LOT1-5
  # detail collector); as a bare TEMPORARY VIEW each read re-runs the LOT_LONG
  # join. Materialize-and-repoint (same pattern as NDMM_FLAGS_ALL / LOT_LONG_AUG
  # and the parent S16; CACHE TABLE is unavailable on SQL warehouses) so every
  # downstream read hits the table. Fail-safe: a non-writable work schema
  # WARN-degrades to the in-place view (correct, just slower). No change to
  # which patients/LOT rows are included - identical rows, materialized once.
  tryCatch({
    run_step(con, "S_ndmm_materialize_lot_long_filt", glue("
      CREATE OR REPLACE TABLE {wrk(NDMM_LOT_LONG_FILT_TBL)} AS
      SELECT * FROM {NDMM_LOT_LONG_FILT}
    "), qc = glue("SELECT count(*) AS n_rows FROM {wrk(NDMM_LOT_LONG_FILT_TBL)}"))
    db_exec(con, glue("
      CREATE OR REPLACE TEMPORARY VIEW {NDMM_LOT_LONG_FILT} AS
      SELECT * FROM {wrk(NDMM_LOT_LONG_FILT_TBL)}
    "))
  }, error = function(e) {
    log_msg("WARN: could not materialize ", wrk(NDMM_LOT_LONG_FILT_TBL), " (",
            conditionMessage(e), "); keeping the in-place temp view - NDMM ",
            "LOT-detail views stay correct but run slower (the join is ",
            "recomputed on each read).")
  })
}

# Counts at each filter step for the attrition card. Steps after
# ELIG_COH_FINAL + LOT1 are CUMULATIVE - each row applies all previous
# NDMM filters plus the new one, so the table reads top-to-bottom as
# the funnel a clinical reviewer would expect.
ndmm_counts <- function(con, lot_long, elig_coh_final) {
  whole <- db_q(con, glue(
    "SELECT count(DISTINCT PATID) AS n FROM {lot_long}"))$n
  # ELIG_COH_FINAL intersected with LOT_LONG so the funnel is monotonic
  # (the parent cohort can contain PATIDs that never enter LOT_LONG; the
  # bare ELIG_COH_FINAL count could otherwise exceed the row above).
  elig <- db_q(con, glue(
    "SELECT count(DISTINCT ec.PATID) AS n
     FROM {elig_coh_final} ec
     INNER JOIN (SELECT DISTINCT cast(PATID as string) AS PATID FROM {lot_long}) ll
             ON cast(ec.PATID as string) = ll.PATID"))$n
  elig_lot1 <- db_q(con, glue(
    "SELECT count(DISTINCT ec.PATID) AS n
     FROM {elig_coh_final} ec
     INNER JOIN {NDMM_LOT1_STARTS} l1
             ON cast(ec.PATID as string) = l1.PATID"))$n
  ce12 <- db_q(con, glue(
    "SELECT count(DISTINCT PATID) AS n FROM {NDMM_FLAGS_ALL}
     WHERE CE_pre_lot1_12mo = 1"))$n
  ce12_nobela <- db_q(con, glue(
    "SELECT count(DISTINCT PATID) AS n FROM {NDMM_FLAGS_ALL}
     WHERE CE_pre_lot1_12mo = 1 AND NO_BELANTAMAB = 1"))$n
  ce12_nobela_nopriortx <- db_q(con, glue(
    "SELECT count(DISTINCT PATID) AS n FROM {NDMM_FLAGS_ALL}
     WHERE CE_pre_lot1_12mo = 1
       AND NO_BELANTAMAB    = 1
       AND NO_PRIOR_MM_TX   = 1"))$n
  noother <- db_q(con, glue(
    "SELECT count(DISTINCT PATID) AS n FROM {NDMM_FLAGS_ALL}
     WHERE CE_pre_lot1_12mo = 1 AND NO_BELANTAMAB = 1
       AND NO_PRIOR_MM_TX = 1 AND NO_OTHER_CANCER_PRE_LOT1 = 1"))$n
  noother_fuce <- db_q(con, glue(
    "SELECT count(DISTINCT PATID) AS n FROM {NDMM_FLAGS_ALL}
     WHERE CE_pre_lot1_12mo = 1 AND NO_BELANTAMAB = 1
       AND NO_PRIOR_MM_TX = 1 AND NO_OTHER_CANCER_PRE_LOT1 = 1
       AND CE_lot1_fu = 1"))$n
  ndmm_final <- db_q(con, glue(
    "SELECT count(DISTINCT PATID) AS n FROM {NDMM_PATIDS}"))$n
  list(whole = whole, elig = elig, elig_lot1 = elig_lot1,
       ce12 = ce12, ce12_nobela = ce12_nobela,
       ce12_nobela_nopriortx = ce12_nobela_nopriortx,
       noother = noother, noother_fuce = noother_fuce,
       ndmm_final = ndmm_final)
}
