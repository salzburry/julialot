# LOT1 start, induction meds, and the base regimen.

phase_lot1_base <- function(con, ctx) {
  meds <- ctx$meds; classes <- ctx$classes
  sanitize_col <- ctx$sanitize_col
  med_flag_exprs <- ctx$med_flag_exprs; class_flag_exprs <- ctx$class_flag_exprs

  # STEP 5 (6): LOT1_BASE
  # Stays a view: one aggregate over map_stacked, which is a table by now, and
  # both its readers below are written to tables - so it is planned three
  # times and each is a grouped scan rather than a re-run of the extraction.
  run_step(con, "S08_lot1_start", "
    CREATE OR REPLACE TEMPORARY VIEW lot1_start AS
    SELECT
      ms.PATID,
      min(ms.MAP_START_DT) AS LOT1_START_DT
    FROM map_stacked ms
    WHERE ms.MAP_MED_CLASS <> 'STEROID'
    GROUP BY ms.PATID
  ", qc = "SELECT count(*) AS n_patients_with_lot1, min(LOT1_START_DT) AS min_lot1_start, max(LOT1_START_DT) AS max_lot1_start FROM lot1_start")

  # Written to a table: S10 below reads it three times (twice through
  # base_meds, once through med_summary) and S16b four more, and each read
  # would otherwise re-run the join against map_stacked. Thirteen over a run.
  materialize(con, "S09_lot1_induction_meds", view = "lot1_induction_meds", name = "LOT1_INDUCTION_MEDS", body = glue("
    SELECT DISTINCT
      ms.PATID,
      l1.LOT1_START_DT,
      ms.MAP_MED_TYPE AS MED_ABBR,
      ms.MAP_MED_CLASS AS MED_CLASS
    FROM map_stacked ms
    INNER JOIN lot1_start l1
      ON ms.PATID = l1.PATID
    WHERE ms.MAP_START_DT >= l1.LOT1_START_DT
      AND ms.MAP_START_DT <= date_add(l1.LOT1_START_DT, {cfg$induction_window_days - 1})
      AND ms.MAP_MED_CLASS <> 'STEROID'  -- corticosteroids are not oncology agents
  "), qc = "
    SELECT count(*) AS n_rows, count(DISTINCT PATID) AS n_patients, avg(cnt) AS avg_induction_meds
    FROM (SELECT PATID, count(DISTINCT MED_ABBR) AS cnt FROM lot1_induction_meds GROUP BY PATID)")

  # LOT1 BASE: induction meds + permissible subs, discon, first add.
  # Written here rather than in phase_lot1_end: S15 reads it twice before that
  # phase is reached. Sixteen reads over a run.
  materialize(con, "S10_lot1_base", view = "lot1_base", name = "LOT1_BASE", body = glue("
    WITH base_meds AS (
      SELECT PATID, MED_ABBR
      FROM lot1_induction_meds
      UNION
      SELECT im.PATID, ps.substitute_med AS MED_ABBR
      FROM lot1_induction_meds im
      INNER JOIN permissible_subs ps
        ON im.MED_ABBR = ps.original_med
    ),
    -- Steroids are excluded from base_meds by the lot1_induction_meds filter.
    -- because corticosteroids are not oncology agents and should
    -- not drive regimen membership, discontinuation, or add-med logic.
    -- Per drug, the end of ITS cover in this line: the FIRST episode flagged
    -- discontinued. A later episode of the same drug is a restart, and a
    -- restart opens the next line rather than extending this one.
    discon_per_med AS (
      SELECT
        ms.PATID,
        ms.MAP_MED_TYPE,
        coalesce(min(CASE WHEN ms.MAP_DISCON_FLG = 1 THEN ms.MAP_END_DT END),
                 max(ms.MAP_END_DT)) AS MED_END_DT
      FROM map_stacked ms
      INNER JOIN lot1_start l1 ON ms.PATID = l1.PATID
      INNER JOIN base_meds bm
        ON ms.PATID = bm.PATID
       AND ms.MAP_MED_TYPE = bm.MED_ABBR
      WHERE ms.MAP_START_DT >= l1.LOT1_START_DT
      GROUP BY ms.PATID, ms.MAP_MED_TYPE
    ),
    -- The regimen has run out when its LAST base agent has.
    discon_raw AS (
      SELECT PATID, max(MED_END_DT) AS RAW_DISCON_DT
      FROM discon_per_med
      GROUP BY PATID
    ),
    discon AS (
      SELECT
        p.PATID,
        -- Where the regimen ran out, capped at OBS_END_DT so days-supply
        -- tails past death or study end do not extend the line. This is the
        -- run-out, not yet a discontinuation: 06_lot1_end.R confirms it, once
        -- the post-runout trigger exists. The add-med window below wants this
        -- raw date.
        CASE
          WHEN d.RAW_DISCON_DT IS NOT NULL AND d.RAW_DISCON_DT <= p.OBS_END_DT
            THEN d.RAW_DISCON_DT
          ELSE NULL
        END AS LOT1_BASE_RUNOUT_DT
      FROM lot_patient_input p
      LEFT JOIN discon_raw d ON p.PATID = d.PATID
    ),
    med_summary AS (
      SELECT
        im.PATID,
        min(im.LOT1_START_DT) AS LOT1_START_DT,  -- same for all rows per PATID; min for determinism
        count(DISTINCT im.MED_ABBR) AS LOT1_MED_CNT,
        concat_ws(' ', sort_array(collect_set(im.MED_ABBR))) AS LOT1_BASE_MEDS,
        {med_flag_exprs},
        {class_flag_exprs}
      FROM lot1_induction_meds im
      GROUP BY im.PATID
    ),
    base_core AS (
      SELECT
        p.PATID,
        p.INDEX_DATE,
        p.ENDDATE,
        p.OBS_END_DT,
        p.DEATH_DT,
        p.GDR_CD,
        p.YRDOB,
        p.AGE_INDEX_YR,
        ms.LOT1_START_DT,
        ms.LOT1_MED_CNT,
        ms.LOT1_BASE_MEDS,
        d.LOT1_BASE_RUNOUT_DT,
        {paste0('ms.', paste(c(paste0('LOT1_MED_', vapply(meds, sanitize_col, character(1))), paste0('LOT1_CLASS_', vapply(classes, sanitize_col, character(1)))), collapse = ', ms.'))}
      FROM lot_patient_input p
      INNER JOIN med_summary ms ON p.PATID = ms.PATID
      LEFT JOIN discon d ON p.PATID = d.PATID
    ),
    first_add_candidates AS (
      SELECT
        ms.PATID,
        ms.MAP_START_DT,
        ms.MAP_MED_TYPE
      FROM map_prev ms
      INNER JOIN base_core bc ON ms.PATID = bc.PATID
      LEFT JOIN base_meds bm
        ON ms.PATID = bm.PATID AND ms.MAP_MED_TYPE = bm.MED_ABBR
      WHERE bm.MED_ABBR IS NULL
        AND ms.MAP_MED_CLASS <> 'STEROID'  -- a steroid cannot trigger an add-med
        -- A return counts as an initiation only where the patient had stopped
        -- the agent, or had never had it before.
        {prev_discon_gate_sql('ms', cfg$returning_agent_requires_discontinuation)}
        AND ms.MAP_START_DT >= bc.LOT1_START_DT
        AND ms.MAP_START_DT <= coalesce(bc.LOT1_BASE_RUNOUT_DT, bc.OBS_END_DT)
    ),
    first_add_pick AS (
      -- When multiple non-induction drugs share the earliest add date,
      -- pick one at random with a fixed seed. rand(42) is deterministic
      -- across runs, so the pick is reproducible but not alphabetically
      -- biased the way min() was.
      SELECT PATID, LOT1_BASE_1ST_ADD_MED_DT, LOT1_BASE_1ST_ADD_MED
      FROM (
        SELECT
          PATID,
          date_sub(MAP_START_DT, 1) AS LOT1_BASE_1ST_ADD_MED_DT,
          MAP_MED_TYPE              AS LOT1_BASE_1ST_ADD_MED,
          row_number() OVER (
            PARTITION BY PATID
            ORDER BY MAP_START_DT, rand(42)
          ) AS rn
        FROM first_add_candidates
      ) ranked
      WHERE rn = 1
    )
    SELECT
      bc.PATID, bc.INDEX_DATE, bc.ENDDATE, bc.OBS_END_DT, bc.DEATH_DT,
      bc.GDR_CD, bc.YRDOB, bc.AGE_INDEX_YR,
      bc.LOT1_START_DT, bc.LOT1_MED_CNT, bc.LOT1_BASE_MEDS,
      bc.LOT1_BASE_RUNOUT_DT,
      -- LOT1_BASE_LENGTH is set in S16, where LOT1_BASE_END_DT is final.
      -- This uses the 2-way formula on the derived end date.
      {paste0('bc.', paste(c(paste0('LOT1_MED_', vapply(meds, sanitize_col, character(1))), paste0('LOT1_CLASS_', vapply(classes, sanitize_col, character(1)))), collapse = ', bc.'))},
      fa.LOT1_BASE_1ST_ADD_MED_DT,
      fa.LOT1_BASE_1ST_ADD_MED
    FROM base_core bc
    LEFT JOIN first_add_pick fa
      ON bc.PATID = fa.PATID
  "), qc = "
    SELECT
      count(*) AS n_patients,
      avg(LOT1_MED_CNT) AS avg_induction_meds,
      sum(case when LOT1_BASE_RUNOUT_DT is not null then 1 else 0 end) as n_with_runout_dt,
      sum(case when LOT1_BASE_1ST_ADD_MED_DT is not null then 1 else 0 end) as n_with_add_med
    FROM lot1_base")


}
