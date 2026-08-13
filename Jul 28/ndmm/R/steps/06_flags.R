# One row per patient carrying every filter's verdict.
#

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

  # Belantamab before the 1L index. The exclusion covers any LOT and names no
  # period, so belantamab earlier in the patient's history disqualifies them
  # even though the 12-month prior-therapy window cannot reach it. lot settles
  # the other half, from the index onward - it cannot settle this one, because
  # the claims it reads start at the index.
  bela_pre_expr <- if (q2_ok_belantamab) glue("
        SELECT DISTINCT cast(PATID as string) AS PATID
        FROM {map_stacked}
        WHERE upper(MAP_MED_TYPE) LIKE 'BEL%' AND PRE_LOT1 = 1
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
             -- DEATH_DT is carried forward so the follow-up CE below can be
             -- worked out from LOT1, the index used here. Pregnancy is not
             -- carried at all - it is re-scanned from pregnancy.csv over the
             -- study period.
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
    -- Follow-up CE re-derived ANCHORED AT LOT1 (the NDMM index): a span must
    -- cover [LOT1_START, least(LOT1_START + NDMM_FU_CE_DAYS, study_end, death)]
    -- and must reach LOT1_START itself - the second condition, which is the
    -- floor written as its own predicate.
    --
    -- The floor is the signed rule (DECISIONS.md #1: the span must cover the
    -- 1L index date). Without it a death IMPUTED before the index pulled the
    -- target back behind it - a month-only death on 10 Jan imputing to 15 Jan
    -- with a 20 Jan index let enrolment ending 19 Jan pass, covering no part
    -- of the index day. DEATH_DT is re-clamped to the index later, in
    -- NDMM_COHORT, which is after eligibility has already been decided.
    -- Uses NDMM_ENROLL_SPANS_STRICT (no-gap spans, gap_days=0):
    -- 'no gaps in enrollment' for the follow-up CE, vs <30-day gaps allowed
    -- for the 12-mo pre-LOT1 CE. Plus the carried-forward DEATH_DT.
    fuce AS (
      SELECT ec_l1.PATID,
             max(CASE WHEN s.cov_start <= ec_l1.LOT1_START_DT
                       AND s.cov_end   >= least(date_add(ec_l1.LOT1_START_DT, {NDMM_FU_CE_DAYS}),
                                                date('{cfg$study_end}'),
                                                coalesce(ec_l1.DEATH_DT, date('{cfg$study_end}')))
                       AND s.cov_end   >= ec_l1.LOT1_START_DT
                      THEN 1 ELSE 0 END) AS CE_fu
      FROM ec_l1
      LEFT JOIN {NDMM_ENROLL_SPANS_STRICT} s ON s.PATID = ec_l1.PATID
      GROUP BY ec_l1.PATID
    ),
    bela AS ({bela_expr}),
    bela_pre AS ({bela_pre_expr}),
    prior_tx AS ({prior_tx_expr}),
    other_cancer AS ({other_cancer_expr}),
    pregnancy AS ({pregnancy_expr})
    SELECT ec_l1.PATID,
           ce.CE_pre_lot1_12mo,
           coalesce(fuce.CE_fu, 0)                              AS CE_lot1_fu,
           CASE WHEN bela.PATID         IS NULL THEN 1 ELSE 0 END AS NO_BELANTAMAB,
           CASE WHEN bela_pre.PATID     IS NULL THEN 1 ELSE 0 END AS NO_BELANTAMAB_PRE_LOT1,
           CASE WHEN prior_tx.PATID     IS NULL THEN 1 ELSE 0 END AS NO_PRIOR_MM_TX,
           CASE WHEN other_cancer.PATID IS NULL THEN 1 ELSE 0 END AS NO_OTHER_CANCER_PRE_LOT1,
           CASE WHEN pregnancy.PATID    IS NULL THEN 1 ELSE 0 END AS NO_PREGNANCY
    FROM ec_l1
    LEFT JOIN ce           ON ec_l1.PATID = ce.PATID
    LEFT JOIN fuce         ON ec_l1.PATID = fuce.PATID
    LEFT JOIN bela         ON ec_l1.PATID = bela.PATID
    LEFT JOIN bela_pre     ON ec_l1.PATID = bela_pre.PATID
    LEFT JOIN prior_tx     ON ec_l1.PATID = prior_tx.PATID
    LEFT JOIN other_cancer ON ec_l1.PATID = other_cancer.PATID
    LEFT JOIN pregnancy    ON ec_l1.PATID = pregnancy.PATID
  "))

  # Write NDMM_FLAGS_ALL to the schema and repoint the view at it. As a bare
  # temporary view it re-runs the whole scan DAG on every read - pregnancy,
  # belantamab, prior therapy and other cancer over the study period, plus both
  # enrollment-span builds - and ndmm_counts() alone reads it six times, once
  # per funnel step, before NDMM_PATIDS reads it again.
  #
  # This is one call to checkpoint(), the same materialize-and-repoint the other
  # ten views use, and it stops if the write fails. Catching the failure and
  # warning instead would be correct arithmetic, but NDMM_FLAGS_ALL is a
  # declared output, so the run would report complete with the table missing
  # and every later read would re-run the DAG anyway.
  #
  # It stays here rather than moving to the runner because NDMM_PATIDS below is
  # defined over this view, and Spark inlines a temporary view's plan -
  # repointing after NDMM_PATIDS exists would leave that view on the old query.
  checkpoint(con, "NDMM_FLAGS_ALL")

  # The conjunction is NDMM_CRITERIA's, in its order, so this view and the
  # attrition's rows are the same six criteria by construction rather than by
  # two lists agreeing. AND commutes, so the order the flags are written in does
  # not change which patients come back.
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_PATIDS} AS
    SELECT PATID FROM {NDMM_FLAGS_ALL}
    WHERE {ndmm_criteria_where()}
  "))
}

# Filtered LOT_LONG view feeding the regimen-transition helpers.
