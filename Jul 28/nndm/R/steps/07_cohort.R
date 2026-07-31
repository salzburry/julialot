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
ndmm_counts <- function(con, mm_qualifying, base_cohort) {
  # whole/elig/elig_lot1 replaced: the population is no longer "patients in
  # LOT_LONG" filtered by a parent cohort. It is everyone with a qualifying MM
  # diagnosis, then those old enough, then those with an eligible 1L treatment.
  # Registered as a rewritten block in tests/test_same_as_source.R.
  whole <- db_q(con, glue(
    "SELECT count(DISTINCT PATID) AS n FROM {mm_qualifying}"))$n
  elig <- db_q(con, glue(
    "SELECT count(DISTINCT PATID) AS n FROM {base_cohort}"))$n
  elig_lot1 <- db_q(con, glue(
    "SELECT count(DISTINCT PATID) AS n FROM {NDMM_LOT1_STARTS}"))$n
  ce12 <- db_q(con, glue(
    "SELECT count(DISTINCT PATID) AS n FROM {NDMM_FLAGS_ALL}
     WHERE CE_pre_lot1_12mo = 1"))$n
  # From here the funnel follows the protocol's own order: S6.2.1.1's remaining
  # inclusion (CE during follow-up), then S6.2.1.2's four exclusions as it
  # lists them - prior MM therapy, other cancer, pregnancy, and belantamab
  # last. apr_30_2026 applied belantamab first and follow-up CE second-to-last.
  # The final cohort is the same conjunction either way, but the per-step
  # numbers are not, and the attrition is what gets read against the protocol.
  # Registered as a rewritten block in tests/test_same_as_source.R.
  ce12_fuce <- db_q(con, glue(
    "SELECT count(DISTINCT PATID) AS n FROM {NDMM_FLAGS_ALL}
     WHERE CE_pre_lot1_12mo = 1 AND CE_lot1_fu = 1"))$n
  fuce_nopriortx <- db_q(con, glue(
    "SELECT count(DISTINCT PATID) AS n FROM {NDMM_FLAGS_ALL}
     WHERE CE_pre_lot1_12mo = 1
       AND CE_lot1_fu       = 1
       AND NO_PRIOR_MM_TX   = 1"))$n
  noother <- db_q(con, glue(
    "SELECT count(DISTINCT PATID) AS n FROM {NDMM_FLAGS_ALL}
     WHERE CE_pre_lot1_12mo = 1 AND CE_lot1_fu = 1
       AND NO_PRIOR_MM_TX = 1 AND NO_OTHER_CANCER_PRE_LOT1 = 1"))$n
  noother_nopreg <- db_q(con, glue(
    "SELECT count(DISTINCT PATID) AS n FROM {NDMM_FLAGS_ALL}
     WHERE CE_pre_lot1_12mo = 1 AND CE_lot1_fu = 1
       AND NO_PRIOR_MM_TX = 1 AND NO_OTHER_CANCER_PRE_LOT1 = 1
       AND NO_PREGNANCY = 1"))$n
  # The last step adds NO_BELANTAMAB, which is every flag NDMM_PATIDS applies,
  # so this reads the cohort view rather than repeating the conjunction.
  ndmm_final <- db_q(con, glue(
    "SELECT count(DISTINCT PATID) AS n FROM {NDMM_PATIDS}"))$n
  list(whole = whole, elig = elig, elig_lot1 = elig_lot1,
       ce12 = ce12, ce12_fuce = ce12_fuce,
       fuce_nopriortx = fuce_nopriortx,
       noother = noother, noother_nopreg = noother_nopreg,
       ndmm_final = ndmm_final)
}
