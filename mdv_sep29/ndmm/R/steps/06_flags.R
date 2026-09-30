# One row per patient carrying every filter's verdict.
#

build_ndmm_flags <- function(con, elig_coh_final, map_stacked) {
  bela_expr <- glue("
        SELECT DISTINCT cast(PATID as string) AS PATID
        FROM {map_stacked}
        WHERE upper(MAP_MED_TYPE) LIKE 'BEL%'
  ")

  # Belantamab before the 1L index. The exclusion covers any LOT and names no
  # period, so belantamab earlier in the patient's history disqualifies them
  # even though the 12-month prior-therapy window cannot reach it. lot settles
  # the other half, from the index onward - it cannot settle this one, because
  # the claims it reads start at the index.
  bela_pre_expr <- glue("
        SELECT DISTINCT cast(PATID as string) AS PATID
        FROM {map_stacked}
        WHERE upper(MAP_MED_TYPE) LIKE 'BEL%' AND PRE_LOT1 = 1
  ")

  prior_tx_expr <- glue("
        SELECT DISTINCT PATID FROM {NDMM_THERAPY_PRE_LOT1}
  ")

  other_cancer_expr <- glue("
        SELECT DISTINCT cast(PATID as string) AS PATID FROM {NDMM_OTHER_MALIG_PATIDS}
  ")

  pregnancy_expr <- glue("
        SELECT DISTINCT cast(PATID as string) AS PATID FROM {NDMM_PREGNANCY_PATIDS}
  ")

  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_FLAGS_ALL} AS
    WITH ec_l1 AS (
      SELECT cast(ec.PATID as string) AS PATID, l1.LOT1_START_DT,
             date_sub(l1.LOT1_START_DT, {NDMM_PRE_LOT1_DAYS}) AS pre_lot1_start,
             date_sub(l1.LOT1_START_DT, 1)                  AS pre_lot1_end,
             -- DEATH_DT is carried forward so the follow-up criterion below
             -- can be worked out from LOT1, the index used here.
             cast(ec.DEATH_DT as date)     AS DEATH_DT
      FROM {elig_coh_final} ec
      INNER JOIN {NDMM_LOT1_STARTS} l1
              ON cast(ec.PATID as string) = l1.PATID
    ),
    -- Criterion 4 on MDV: the patient's records reach back to the start of
    -- the baseline window - the lookback that 12 months of continuous
    -- enrollment bought on Optum. MDV has no enrollment to be continuous;
    -- 01_observation.R has why this is the translation.
    ce AS (
      SELECT ec_l1.PATID,
             max(CASE WHEN o.OBS_START_DT <= ec_l1.pre_lot1_start
                      THEN 1 ELSE 0 END) AS CE_pre_lot1_12mo
      FROM ec_l1
      LEFT JOIN {NDMM_OBS_PERIOD} o ON o.PATID = ec_l1.PATID
      GROUP BY ec_l1.PATID
    ),
    -- Criterion 5 on MDV: the patient is still seen at the hospital at
    -- least(LOT1_START + NDMM_FU_CE_DAYS, study_end, death), and at LOT1_START
    -- itself - the floor, written as its own predicate as in the Optum build
    -- (DECISIONS.md #1). NDMM_FU_CE_DAYS is 0, and the index act is a record
    -- on the index date, so every patient with an index passes - unless they
    -- are recorded dead before it. The death date is the FF1 discharge date
    -- as recorded, so a 1L start after it is a contradiction in the data, not
    -- a patient who can be followed from the index (DECISIONS M12,
    -- NDMM_DEATH_CONFLICTS).
    fuce AS (
      SELECT ec_l1.PATID,
             max(CASE WHEN o.OBS_START_DT <= ec_l1.LOT1_START_DT
                       AND o.OBS_END_DT   >= least(date_add(ec_l1.LOT1_START_DT, {NDMM_FU_CE_DAYS}),
                                                   date('{cfg$study_end}'),
                                                   coalesce(ec_l1.DEATH_DT, date('{cfg$study_end}')))
                       AND o.OBS_END_DT   >= ec_l1.LOT1_START_DT
                       AND (ec_l1.DEATH_DT IS NULL
                            OR ec_l1.DEATH_DT >= ec_l1.LOT1_START_DT)
                      THEN 1 ELSE 0 END) AS CE_fu
      FROM ec_l1
      LEFT JOIN {NDMM_OBS_PERIOD} o ON o.PATID = ec_l1.PATID
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
  # belantamab, prior therapy and other cancer over the study period, plus the
  # observation period - and ndmm_counts() alone reads it six times, once
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
