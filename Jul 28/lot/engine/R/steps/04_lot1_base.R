# LOT1 start, induction meds, and the base regimen.

phase_lot1_base <- function(con, ctx) {
  meds <- ctx$meds; classes <- ctx$classes
  sanitize_col <- ctx$sanitize_col
  med_flag_exprs <- ctx$med_flag_exprs; class_flag_exprs <- ctx$class_flag_exprs

  # STEP 5 (6): LOT1_BASE
  # Stays a view. It is one aggregate over map_stacked, which is a table by
  # now, and both its readers below are written to tables. So it is planned
  # three times, and each is a grouped scan rather than the extraction run
  # again.
  run_step(con, "S08_lot1_start", "
    CREATE OR REPLACE TEMPORARY VIEW lot1_start AS
    SELECT
      ms.PATID,
      min(ms.MAP_START_DT) AS LOT1_START_DT
    FROM map_stacked ms
    WHERE ms.MAP_MED_CLASS <> 'STEROID'
    GROUP BY ms.PATID
  ", qc = "SELECT count(*) AS n_patients_with_lot1, min(LOT1_START_DT) AS min_lot1_start, max(LOT1_START_DT) AS max_lot1_start FROM lot1_start")

  # S08b: the last day LOT1's regimen may collect an agent on.
  #
  # A line picks its regimen over the whole induction window. Without a cutoff
  # it keeps collecting past its own end: where an allogeneic transplant ends
  # LOT1 early, the rest of the window would still gather drugs into the regimen
  # of a line already over. A drug first dispensed after the line ended would
  # count in its regimen AND start a later line - counted twice - and it would
  # move the run-out with it, because a regimen drug is a base drug.
  #
  # ALLO always. CAR-T only when the induction exemption is off.
  #
  # With the exemption on - the pinned setting - a CAR-T inside the window is
  # part of LOT1 and ends nothing, and one outside the window is outside the
  # regimen window too, so it has nothing to strand. With the exemption off the
  # CAR-T ends LOT1 the day before, and the rest of the window would collect
  # into a line already over. So the cutoff follows the exemption.
  #
  # An AUTO cannot strand anything either way. It only ever extends the line
  # (LOT_RULES.md §6.5). LOT2-5 has no exemption, so CAR-T always counts there.
  #
  # Floored at the line start. An ALLO on day one then gives a one-day line
  # whose regimen is that day's drugs, not an empty regimen with a cutoff
  # before its own start.
  run_step(con, "S08b_lot1_regimen_cutoff", glue("
    CREATE OR REPLACE TEMPORARY VIEW lot1_regimen_cutoff AS
    SELECT
      l1.PATID,
      l1.LOT1_START_DT,
      min(CASE WHEN ac.TX_DT >= l1.LOT1_START_DT
                AND (ac.SCT_TYPE = 'ALLO'
                     OR (ac.SCT_TYPE = 'CART'
                         AND {if (isTRUE(cfg$apply_cart_induction_rule)) 0L else 1L} = 1))
               THEN greatest(l1.LOT1_START_DT, date_sub(ac.TX_DT, 1)) END)
        AS REGIMEN_CUTOFF_DT
    FROM lot1_start l1
    LEFT JOIN tx_allo_cart_dates ac ON l1.PATID = ac.PATID
    GROUP BY l1.PATID, l1.LOT1_START_DT
  "), qc = "
    SELECT count(*) AS n_patients,
           sum(CASE WHEN REGIMEN_CUTOFF_DT IS NOT NULL THEN 1 ELSE 0 END) AS n_cut
    FROM lot1_regimen_cutoff")

  # Written to a table. S10 below reads it three times - twice through
  # base_meds, once through med_summary - and S16b four more. Each read would
  # otherwise run the join against map_stacked again. Thirteen over a run.
  materialize(con, "S09_lot1_induction_meds", view = "lot1_induction_meds", name = "LOT1_INDUCTION_MEDS", body = glue("
    SELECT DISTINCT
      ms.PATID,
      l1.LOT1_START_DT,
      ms.MAP_MED_TYPE AS MED_ABBR,
      ms.MAP_MED_CLASS AS MED_CLASS
    FROM map_stacked ms
    INNER JOIN lot1_regimen_cutoff l1
      ON ms.PATID = l1.PATID
    WHERE ms.MAP_START_DT >= l1.LOT1_START_DT
      AND ms.MAP_START_DT <= least(
            date_add(l1.LOT1_START_DT, {cfg$induction_window_days - 1}),
            coalesce(l1.REGIMEN_CUTOFF_DT, cast('9999-12-31' as date)))
      AND ms.MAP_MED_CLASS <> 'STEROID'  -- corticosteroids are not oncology agents
  "), qc = "
    SELECT count(*) AS n_rows, count(DISTINCT PATID) AS n_patients, avg(cnt) AS avg_induction_meds
    FROM (SELECT PATID, count(DISTINCT MED_ABBR) AS cnt FROM lot1_induction_meds GROUP BY PATID)")

  # LOT1 BASE: induction meds plus permissible subs, the run-out, and the first
  # add. Written here rather than in phase_lot1_end, because S15 reads it twice
  # before that phase is reached. Sixteen reads over a run.
  materialize(con, "S10_lot1_base", view = "lot1_base", name = "LOT1_BASE", body = glue("
    WITH map_restart AS ({map_restart_sql()}
    ),
    -- SUBSTITUTE_ONLY = 1 means the drug is here only as a permissible
    -- biosimilar substitute. A substitution does not advance the LOT (§4.4).
    -- So a substitute never ends a line on its own, confirms a run-out or
    -- opens the next one, whatever gaps its own episodes carry.
    base_meds AS ({regimen_with_subs_sql('lot1_induction_meds')}
    ),
    -- Steroids are kept out of base_meds by the lot1_induction_meds filter.
    -- Corticosteroids are not oncology agents, so they must not drive regimen
    -- membership, discontinuation or the add-med rules.
    --
    -- Per drug, this is the end of ITS cover in this line. A later episode of
    -- the same drug extends it rather than opening a line, unless a drug that
    -- would end the line arrives in between.
    --
    -- max(MAP_END_DT) over every episode would undo that. Drug A dosed days
    -- 0-27, discontinued at 27 by the 90-day gap, restarting 117-144, would
    -- give a line-level run-out of 144. The restart is then swallowed and LOT2
    -- never opens, because its trigger has to fall strictly after the previous
    -- end.
    discon_per_med AS (
{discon_per_med_sql('lot1_regimen_cutoff', 'LOT1_START_DT', end_col = 'REGIMEN_CUTOFF_DT',
                    own_gap_breaks = own_gap_breaks_chain(cfg))}
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
        -- Where the regimen ran out, capped at OBS_END_DT so a days-supply
        -- tail past death or study end cannot extend the line. This is the
        -- run-out, not yet a discontinuation. 06_lot1_end.R confirms it, once
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
      FROM map_stacked ms
      INNER JOIN base_core bc ON ms.PATID = bc.PATID
      LEFT JOIN base_meds bm
        ON ms.PATID = bm.PATID AND ms.MAP_MED_TYPE = bm.MED_ABBR
      LEFT JOIN map_restart mr
        ON mr.PATID = ms.PATID AND mr.MAP_MED_TYPE = ms.MAP_MED_TYPE
       AND mr.MAP_START_DT = ms.MAP_START_DT
      -- A regimen drug returning after a confirmed gap ends this line, like
      -- any other drug would. Without it the release is half a rule. While
      -- another regimen drug still holds this line open, the restart falls
      -- inside the line, cannot end it, and is then too early to open the next
      -- one. The treatment belongs to no line at all.
      WHERE (bm.MED_ABBR IS NULL
{return_release_sql(cfg, 'mr', 'bm')})
        AND ms.MAP_MED_CLASS <> 'STEROID'  -- a steroid cannot trigger an add-med
        AND ms.MAP_START_DT >= bc.LOT1_START_DT
        AND ms.MAP_START_DT <= coalesce(bc.LOT1_BASE_RUNOUT_DT, bc.OBS_END_DT)
    ),
    first_add_pick AS (
      -- When several non-induction drugs share the earliest add date, one is
      -- picked at random on a fixed seed. rand(42) gives the same answer in
      -- every run, so the pick repeats without being biased towards the front
      -- of the alphabet the way min() was.
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
      -- This uses the two-way formula on the derived end date.
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
