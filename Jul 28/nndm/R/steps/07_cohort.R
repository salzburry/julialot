# The filtered cohort, and the counts the attrition is read from.
#

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
  n_of <- function(sql) db_q(con, sql)$n
  # whole/elig/elig_lot1 replaced: the population is no longer "patients in
  # LOT_LONG" filtered by a parent cohort. It is everyone with a qualifying MM
  # diagnosis, then those old enough, then those with an eligible 1L treatment.
  # These three count off their own tables rather than off a flag.
  whole <- n_of(glue(
    "SELECT count(DISTINCT PATID) AS n FROM {mm_qualifying}"))
  elig <- n_of(glue(
    "SELECT count(DISTINCT PATID) AS n FROM {base_cohort}"))
  elig_lot1 <- n_of(glue(
    "SELECT count(DISTINCT PATID) AS n FROM {NDMM_LOT1_STARTS}"))

  # From here the funnel follows the protocol's own order: S6.2.1.1's remaining
  # inclusion (CE during follow-up), then S6.2.1.2's four exclusions as it
  # lists them - prior MM therapy, other cancer, pregnancy, and belantamab
  # last. The source applied belantamab first and follow-up CE second-to-last.
  # The final cohort is the same conjunction either way, but the per-step
  # numbers are not, and the attrition is what gets read against the protocol.
  #
  # Each row is NDMM_CRITERIA's first i criteria, so a row is the row above it
  # plus exactly one - that shape is the list's, not something restated here.
  cum <- list()
  for (i in seq_len(length(NDMM_CRITERIA) - 1L))
    cum[[NDMM_CRITERIA[[i]]$key]] <- n_of(glue(
      "SELECT count(DISTINCT PATID) AS n FROM {NDMM_FLAGS_ALL}
       WHERE {ndmm_criteria_where(i)}"))

  # The last criterion completes the conjunction NDMM_PATIDS is defined on, so
  # this row reads that view rather than repeating it - the published number is
  # then the cohort's own, not a recount that has to agree with it.
  ndmm_final <- n_of(glue(
    "SELECT count(DISTINCT PATID) AS n FROM {NDMM_PATIDS}"))
  # Keyed off the last criterion rather than repeating its name. The three at
  # the front are this function's own - they count off their own tables - but
  # the final row is the last entry of NDMM_CRITERIA, and writing its key here
  # as well was the one place two lists still had to agree by hand.
  c(list(whole = whole, elig = elig, elig_lot1 = elig_lot1), cum,
    setNames(list(ndmm_final), NDMM_CRITERIA[[length(NDMM_CRITERIA)]]$key))
}

# The final row of the funnel, whatever the last criterion happens to be called.
# The runner used to name that key literally, which is the same two-lists-agree
# problem ndmm_counts() removed one line above.
ndmm_final_count <- function(counts)
  counts[[NDMM_CRITERIA[[length(NDMM_CRITERIA)]]$key]]
