# The LOT1 end date and reason.
#
# map_stacked, lot1_base and lot1_sct are each written to a table where they
# are built - S07, S10 and S15 - because all three are read before this phase
# runs. CACHE TABLE is not supported on SQL warehouses, so a table is the only
# way to hold a result.

phase_lot1_end <- function(con, ctx) {

  # S16b: contains_mtx_reg. Maintenance as a flag and nothing else.
  #
  # Does LOT1's induction regimen hold a valid maintenance-approved subset, mono
  # or dual, PLUS an anchor drug - any other induction drug outside that subset?
  # The anchor may itself be maintenance-eligible in another context.
  #
  # A table, because it self-joins lot1_induction_meds four times and S16 below
  # reads it again. One row per patient, so the write is small either way.
  materialize(con, "S16b_lot1_contains_mtx_reg", view = "lot1_contains_mtx_reg", name = "LOT1_CONTAINS_MTX_REG", body = glue("
    WITH
    -- Valid maintenance regimens, from real induction drugs only - NOT the
    -- substitution-expanded base_meds. Permissible subs can add regimen members
    -- that were never dispensed, and the original drug then wrongly anchors a
    -- single-drug induction.
    valid_maint_regimens AS (
      -- Mono maintenance: MONOMAINTENANCE = 1, and the drug is a real
      -- induction drug.
      SELECT DISTINCT im.PATID, im.MED_ABBR AS REGIMEN_KEY
      FROM lot1_induction_meds im
      INNER JOIN mma_rollup ru ON im.MED_ABBR = ru.CL_MED_ABBR
      WHERE ru.MONOMAINTENANCE = 1
      UNION
      -- Dual maintenance: the drug names a partner in DUALMAINTENANCEWITH, and
      -- both are in induction.
      SELECT DISTINCT
        im.PATID,
        concat_ws(' ', sort_array(array(im.MED_ABBR, im2.MED_ABBR))) AS REGIMEN_KEY
      FROM lot1_induction_meds im
      INNER JOIN mma_rollup ru ON im.MED_ABBR = ru.CL_MED_ABBR
      INNER JOIN lot1_induction_meds im2
        ON im.PATID = im2.PATID
        AND im.MED_ABBR <> im2.MED_ABBR
        AND array_contains(
          transform(split(coalesce(ru.DUALMAINTENANCEWITH, ''), ','), v -> upper(trim(v))),
          im2.MED_ABBR)
    ),
    -- Anchor check: at least one induction drug outside the maintenance subset
    anchored AS (
      SELECT DISTINCT vmr.PATID
      FROM valid_maint_regimens vmr
      INNER JOIN lot1_induction_meds im ON vmr.PATID = im.PATID
      WHERE NOT array_contains(split(vmr.REGIMEN_KEY, ' '), im.MED_ABBR)
    )
    SELECT DISTINCT
      p.PATID,
      CASE WHEN a.PATID IS NOT NULL THEN 1 ELSE 0 END AS contains_mtx_reg
    FROM (SELECT DISTINCT PATID FROM lot1_induction_meds) p
    LEFT JOIN anchored a ON p.PATID = a.PATID
  "), qc = "
    SELECT contains_mtx_reg, count(*) AS n
    FROM lot1_contains_mtx_reg
    GROUP BY contains_mtx_reg")

  # S16: LOT1_BASE_END - LOT1's final end reason and date.
  #
  # Priority, highest first. This is a ranking, not just a tie-break on equal
  # dates:
  #   SCT_AUTO_CONT > SCT_ALLO > SCT_CART > SCT_AUTO (excess) > CART_INIT
  #   > MED_ADD > DEATH > DISCONTINUATION > STUDY_END
  #
  # SCT_AUTO_CONT is at the top only in the sense of being tested first. It is
  # gated on falling after every other branch's date, so it never takes an end
  # that already came later. DEATH is excluded from it by name.
  #
  # DEATH can outrank an earlier DISCONTINUATION, but only when no
  # LOT2-qualifying trigger sits between the run-out and the death - the
  # post-runout guard below. The SCT, CART_INIT and MED_ADD branches each gate
  # themselves against DISCON_DT, so they fire only when their event is at or
  # before the run-out.
  #
  # Disenrollment is not a censoring criterion, so a period ending at
  # disenrollment is STUDY_END. There is no DISENROLLMENT reason.
  # MAINTENANCE_END and SCT_NO_MAINT are not final values either. Those cases
  # route by their earliest applicable event. CART_INIT - a MED_ADD followed by
  # a CART within cart_consolidation_days - ends LOT1 on ENDING_CART_DT - 1,
  # the day before the infusion.
  #
  # A table, because it is read nine times downstream and each read would
  # otherwise re-run the post-runout guard below, which scans map_stacked
  # twice.
  materialize(con, "S16_lot1_base_end", view = "lot1_base_end", name = "LOT1_BASE_END", body = glue("
    WITH{melp_lot1_ctes(cfg)}
    -- The post-runout guard. Is there a LOT2-qualifying trigger strictly after
    -- LOT1_BASE_RUNOUT_DT and on or before OBS_END_DT? It stops DEATH taking a
    -- line from DISCONTINUATION where the patient ran out, then started new
    -- therapy or had an SCT, and only then died.
    --
    -- These CTEs MIRROR LOT2's own start-candidate rules in lot2_5_base.R
    -- (med_cand / auto_cand), so the guard fires exactly when LOT2 would have a
    -- valid start trigger:
    --   - MED: any non-steroid MM drug NOT among LOT1's permissible biosimilar
    --     substitutes. A same-drug restart DOES qualify.
    --   - AUTO: any AUTO outside LOT1's own {cfg$induction_window_days}-day
    --     window, and not within sct_tandem_days (180d) of the AUTO right
    --     before it in the patient's history - that pair is a planned tandem.
    --   - ALLO/CART: any after the run-out. No window check; it always
    --     triggers. The one exception is a CAR-T inside LOT1 induction, which
    --     under the CAR-T rule is part of LOT1 and starts nothing, so LOT2
    --     would not act on it.
    --
    -- What cannot confirm this line's run-out is what cannot start the next
    -- line: this line's own regimen drugs and their permissible substitutes.
    -- med_cand excludes both, so accepting one here would confirm a
    -- discontinuation on an event no next line is allowed to open on.
    post_runout_excluded_meds AS (
      SELECT PATID, MED_ABBR, min(IS_SUB) AS SUBSTITUTE_ONLY
      FROM (
        SELECT im.PATID, im.MED_ABBR, 0 AS IS_SUB
        FROM lot1_induction_meds im
        UNION ALL
        SELECT im.PATID, ps.substitute_med AS MED_ABBR, 1 AS IS_SUB
        FROM lot1_induction_meds im
        INNER JOIN permissible_subs ps ON im.MED_ABBR = ps.original_med
      )
      GROUP BY PATID, MED_ABBR
    ),
    map_restart AS ({map_restart_sql()}
    ),
    post_runout_med AS (
      SELECT DISTINCT ms.PATID
      FROM map_stacked ms
      INNER JOIN {melp_lot1_base_tbl(cfg)} ON ms.PATID = lb.PATID
      LEFT JOIN post_runout_excluded_meds prem
        ON ms.PATID = prem.PATID AND ms.MAP_MED_TYPE = prem.MED_ABBR
      LEFT JOIN map_restart mr
        ON mr.PATID = ms.PATID AND mr.MAP_MED_TYPE = ms.MAP_MED_TYPE
       AND mr.MAP_START_DT = ms.MAP_START_DT
      WHERE lb.LOT1_BASE_RUNOUT_DT IS NOT NULL
        AND ms.MAP_START_DT > lb.LOT1_BASE_RUNOUT_DT
        AND ms.MAP_START_DT <= lb.OBS_END_DT
        AND ms.MAP_MED_CLASS <> 'STEROID'
        -- Mirrors med_cand, which releases a drug returning after a confirmed
        -- gap. A guard reading a different rule from the candidate it mirrors
        -- lets DEATH take a line whose run-out the next line does open on.
        AND (prem.MED_ABBR IS NULL
             OR (coalesce(mr.PREV_DISCON, 0) = 1 AND prem.SUBSTITUTE_ONLY = 0))
    ),
    post_runout_autos AS (
      -- N_BETWEEN: did anything happen since the previous transplant? A pair
      -- 180 days apart with a medication in the middle is not a planned tandem,
      -- so the later transplant is free to start a line.
      SELECT p.PATID, p.TX_DT, p.PREV_AUTO_DT,
             coalesce(sum(CASE WHEN x.dt > p.PREV_AUTO_DT AND x.dt < p.TX_DT
                               THEN 1 ELSE 0 END), 0) AS N_BETWEEN
      FROM (
        SELECT a.PATID, a.TX_DT,
               lag(a.TX_DT) OVER (PARTITION BY a.PATID ORDER BY a.TX_DT) AS PREV_AUTO_DT
        FROM tx_auto_dates a
      ) p
      LEFT JOIN ({tandem_interrupt_events_sql()}
      ) x ON p.PATID = x.PATID
      GROUP BY p.PATID, p.TX_DT, p.PREV_AUTO_DT
    ),
    post_runout_auto AS (
      -- Mirrors LOT2-5's auto_cand, which measures the window belonging to the
      -- line it looks back at. Here the previous line is always LOT1, so the
      -- window is LOT1's own {cfg$induction_window_days} days, not the
      -- {cfg$lot_n_induction_window_days} LOT2-5 uses for its own lines.
      --
      -- The two have to agree. This guard decides whether a run-out counts as a
      -- confirmed discontinuation. auto_cand decides whether the same AUTO opens
      -- LOT2. Read different windows and DEATH takes a line whose run-out the
      -- next line does in fact open on.
      SELECT DISTINCT lb.PATID
      FROM {melp_lot1_base_tbl(cfg)}
      INNER JOIN post_runout_autos awp ON lb.PATID = awp.PATID
      WHERE lb.LOT1_BASE_RUNOUT_DT IS NOT NULL
        AND awp.TX_DT > lb.LOT1_BASE_RUNOUT_DT
        AND awp.TX_DT <= lb.OBS_END_DT
        AND awp.TX_DT > date_add(lb.LOT1_START_DT, {cfg$induction_window_days} - 1)
        -- The tandem exemption, with the same ownership condition auto_cand
        -- carries: a pair only counts as a tandem where the EARLIER transplant
        -- fell inside the line's window, because that is the only case a line
        -- was ever holding the pair. Without it this guard refuses to confirm
        -- a run-out on account of a tandem that auto_cand has already decided
        -- is not one - and then the two disagree about the same AUTO, which is
        -- exactly what the note above says must not happen.
        AND NOT (awp.PREV_AUTO_DT IS NOT NULL
                 AND datediff(awp.TX_DT, awp.PREV_AUTO_DT) <= {cfg$sct_tandem_days}
                 AND awp.N_BETWEEN = 0
                 AND awp.PREV_AUTO_DT <= date_add(lb.LOT1_START_DT,
                                                  {cfg$induction_window_days} - 1))
    ),
    post_runout_sct AS (
      -- Any ALLO or CAR-T strictly after the run-out and inside observation.
      --
      -- An EXISTENCE test over rows, like post_runout_med and post_runout_auto
      -- beside it. It is deliberately not a comparison against lot1_sct's
      -- dates. FIRST_ALLO_DT and FIRST_CART_DT are min() over the whole line,
      -- so an earlier infusion hides every later one behind it. Take a patient
      -- with a CAR-T on day 20 absorbed into a live LOT1, a run-out on day 39
      -- and a second CAR-T on day 50: FIRST_CART_DT is day 20, which is not
      -- after the run-out, and the day-50 infusion that should confirm it is
      -- never looked at. ENDING_CART_DT is no better, because the induction
      -- exemption nulls both. This is the aggregate-versus-row mistake
      -- R/cart_rule.R describes for the line-ending date, running the other way.
      --
      -- No window test. The arm already requires the infusion to be after the
      -- run-out, so the line's treatment had stopped before it arrived and the
      -- induction exemption cannot reach it.
      SELECT DISTINCT lb.PATID
      FROM {melp_lot1_base_tbl(cfg)}
      INNER JOIN tx_allo_cart_dates ac ON lb.PATID = ac.PATID
      WHERE lb.LOT1_BASE_RUNOUT_DT IS NOT NULL
        AND ac.SCT_TYPE IN ('ALLO', 'CART')
        AND ac.TX_DT > lb.LOT1_BASE_RUNOUT_DT
        AND ac.TX_DT <= lb.OBS_END_DT
    ),
    post_runout_trigger AS (
      -- Every arm is an existence test on a per-row CTE. Nothing here reads an
      -- aggregate, and that is what makes a later event impossible to hide.
      SELECT lb.PATID,
        CASE
          WHEN lb.LOT1_BASE_RUNOUT_DT IS NULL THEN 0
          WHEN prm.PATID IS NOT NULL THEN 1
          WHEN prs.PATID IS NOT NULL THEN 1
          WHEN pra.PATID IS NOT NULL THEN 1
          ELSE 0
        END AS POST_RUNOUT_TRIGGER_FLG
      FROM {melp_lot1_base_tbl(cfg)}
      LEFT JOIN post_runout_med prm ON lb.PATID = prm.PATID
      LEFT JOIN post_runout_sct prs ON lb.PATID = prs.PATID
      LEFT JOIN post_runout_auto pra ON lb.PATID = pra.PATID
    ),
    end_candidates AS (
      SELECT
        lb.*,
        coalesce(prt.POST_RUNOUT_TRIGGER_FLG, 0) AS POST_RUNOUT_TRIGGER_FLG,
        -- The run-out becomes a discontinuation here, not in 04_lot1_base.R,
        -- because POST_RUNOUT_TRIGGER_FLG does not exist before this point.
        -- Either thing confirms it: {cfg$lot_discon_confirm_days} days of
        -- observation after it, or a LOT2-qualifying trigger. Unconfirmed, it
        -- stays NULL and the cascade censors at OBS_END_DT. If elapsed time
        -- were the only test that would swallow the restart, since LOT2 has to
        -- start after LOT1 ends.
        CASE
          WHEN lb.LOT1_BASE_RUNOUT_DT IS NOT NULL
           AND (coalesce(prt.POST_RUNOUT_TRIGGER_FLG, 0) = 1
                OR datediff(lb.OBS_END_DT, lb.LOT1_BASE_RUNOUT_DT)
                     >= {cfg$lot_discon_confirm_days})
            THEN lb.LOT1_BASE_RUNOUT_DT
          ELSE NULL
        END AS LOT1_BASE_DISCON_DT,
        sct.LOT1_TX_AUTO_DT_1,
        sct.LOT1_TX_AUTO_DT_2,
        sct.LOT1_SCT_AUTO_TAND_FLG,
        sct.LOT1_SCT_AUTO_SING_FLG,
        sct.LOT1_TX_ENDDATE,
        sct.LOT1_TX_ENDDATE_REASON,
        sct.LOT1_1ST_SCT_DT,
        sct.FIRST_ALLO_DT,
        sct.FIRST_CART_DT,
        sct.ENDING_CART_DT,
        sct.LOT1_AUTO_HOLD_DT,
        -- The contains_mtx_reg flag. Descriptive only. It does not route an
        -- end reason and it does not create a maintenance period.
        COALESCE(cmr.contains_mtx_reg, 0) AS contains_mtx_reg,
        -- CART_INIT: a MED_ADD followed by a CART within
        -- {cfg$cart_consolidation_days} days. Where a new medication is added
        -- and the patient starts CAR-T within 45 days of it, LOT1's end reason
        -- is the CAR-T initiation, not the add.
        --
        -- datediff(A, B) is A - B in Databricks, so this is
        -- CART_DT - ADD_START_DT BETWEEN 0 AND 45. LOT1_BASE_1ST_ADD_MED_DT is
        -- date_sub(ADD_START_DT, 1), so the 1 is added back.
        --
        -- ENDING_CART_DT, not FIRST_CART_DT: the earliest CAR-T allowed to end
        -- the line, which is NULL only when the patient has no such infusion at
        -- all. lot1_sct works it out per row - see R/cart_rule.R.
        CASE
          WHEN sct.ENDING_CART_DT IS NOT NULL
           AND lb.LOT1_BASE_1ST_ADD_MED_DT IS NOT NULL
           AND datediff(sct.ENDING_CART_DT, date_add(lb.LOT1_BASE_1ST_ADD_MED_DT, 1)) BETWEEN 0 AND {cfg$cart_consolidation_days}
          THEN 1
          ELSE 0
        END AS CART_INIT_FLG
      FROM {melp_lot1_base_from(cfg)}
      LEFT JOIN lot1_sct sct ON lb.PATID = sct.PATID
      LEFT JOIN lot1_contains_mtx_reg cmr ON lb.PATID = cmr.PATID
      LEFT JOIN post_runout_trigger   prt ON lb.PATID = prt.PATID
    ),
    -- The end this line would have had before an in-window AUTO is weighed:
    -- the whole cascade below, minus its SCT_AUTO_CONT branch. It is its own
    -- CTE because LOT1_BASE_DISCON_DT is derived in end_candidates, and SQL
    -- cannot read a select-list alias from the same select list.
    --
    -- It exists so the SCT_AUTO_CONT branch has one thing to compare against,
    -- rather than restating every branch it has to beat. An AUTO extends the
    -- line only when it lands strictly after this date.
    end_natural AS (
      SELECT
        ec.*,
        CASE
          WHEN ec.LOT1_TX_ENDDATE IS NOT NULL
           AND NOT (ec.CART_INIT_FLG = 1 AND ec.LOT1_TX_ENDDATE_REASON = 3)
           AND (ec.LOT1_BASE_1ST_ADD_MED_DT IS NULL
                OR (ec.CART_INIT_FLG = 1 AND ec.LOT1_TX_ENDDATE <= date_sub(ec.ENDING_CART_DT, 1))
                OR (ec.CART_INIT_FLG = 0 AND ec.LOT1_TX_ENDDATE <= ec.LOT1_BASE_1ST_ADD_MED_DT))
           AND (ec.LOT1_BASE_DISCON_DT IS NULL OR ec.LOT1_TX_ENDDATE <= ec.LOT1_BASE_DISCON_DT)
          THEN ec.LOT1_TX_ENDDATE
          WHEN ec.CART_INIT_FLG = 1
           AND (ec.LOT1_BASE_DISCON_DT IS NULL OR date_sub(ec.ENDING_CART_DT, 1) <= ec.LOT1_BASE_DISCON_DT)
          THEN date_sub(ec.ENDING_CART_DT, 1)
          WHEN ec.LOT1_BASE_1ST_ADD_MED_DT IS NOT NULL
           AND ec.CART_INIT_FLG = 0
           AND (ec.LOT1_BASE_DISCON_DT IS NULL OR ec.LOT1_BASE_1ST_ADD_MED_DT <= ec.LOT1_BASE_DISCON_DT)
          THEN ec.LOT1_BASE_1ST_ADD_MED_DT
          WHEN ec.DEATH_DT IS NOT NULL AND ec.DEATH_DT <= ec.OBS_END_DT
           AND ec.POST_RUNOUT_TRIGGER_FLG = 0 THEN ec.DEATH_DT
          WHEN ec.LOT1_BASE_DISCON_DT IS NOT NULL THEN ec.LOT1_BASE_DISCON_DT
          ELSE ec.OBS_END_DT
        END AS LOT1_NATURAL_END_DT
      FROM end_candidates ec
    )
    SELECT
      ec.*,
      -- End reason priority, highest first. A ranking, not just a tie-break on
      -- equal earliest dates:
      --   SCT_AUTO_CONT > SCT_ALLO > SCT_CART > SCT_AUTO (excess) > CART_INIT
      --   > MED_ADD > DEATH > DISCONTINUATION > STUDY_END
      --
      -- DEATH can outrank an earlier DISCONTINUATION, but only when no
      -- LOT2-qualifying trigger sits between the run-out and the death - the
      -- post-runout guard above. SCT, CART_INIT and MED_ADD each gate
      -- themselves against DISCON_DT, so they fire only when their event is at
      -- or before the run-out.
      --
      -- Disenrollment is not a censoring criterion, so a period ending at
      -- disenrollment is STUDY_END. MAINTENANCE_END and SCT_NO_MAINT are not
      -- final values; those cases route by their earliest applicable event.
      -- CART_INIT ends LOT1 on ENDING_CART_DT - 1, the day before the
      -- infusion.
      CASE
        -- SCT_AUTO_CONT. An AUTO inside LOT1's own window belongs to LOT1, so
        -- LOT1 cannot be closed before it. Where the cascade below would have
        -- ended the line earlier, the line runs to the transplant and ends ON
        -- it - not the day before, because this AUTO continues the line rather
        -- than starting the next one.
        --
        -- Why it ends there at all: a LOT ends on the SCT date when no
        -- maintenance regimen follows within 180 days. This build
        -- carries no maintenance period, so that test can never be met and the
        -- SCT date always wins.
        --
        -- Tested first, and gated on being strictly after LOT1_NATURAL_END_DT,
        -- so it fires only when it really extends the line. That puts it above
        -- MED_ADD as well as DISCONTINUATION and STUDY_END. It cannot reach the
        -- SCT_ALLO, SCT_CART or CART_INIT ends: 05b_lot1_sct.R drops every AUTO
        -- at or after the first ALLO or CAR-T, so an AUTO surviving to here is
        -- always earlier than those events, never later.
        --
        -- DEATH is the one end it does not outrank. That is the explicit guard
        -- below, not a side effect of the ordering. Claims can carry a service
        -- date after the recorded death, and a line may not outlive the
        -- patient.
        WHEN ec.LOT1_AUTO_HOLD_DT IS NOT NULL
         AND ec.LOT1_AUTO_HOLD_DT > ec.LOT1_NATURAL_END_DT
         AND (ec.DEATH_DT IS NULL OR ec.LOT1_AUTO_HOLD_DT < ec.DEATH_DT)
        THEN 'SCT_AUTO_CONT'
        -- Rule 2: SCT - ALLO, CART, or an excess AUTO.
        --
        -- When CART_INIT_FLG = 1 and the SCT IS the CART (reason = 3), this
        -- branch is skipped so CART_INIT can take it. Otherwise every CART
        -- routes to SCT_CART and CART_INIT is never reached.
        --
        -- The tie-break against CART_INIT uses ENDING_CART_DT - 1, CART_INIT's
        -- own end date, so SCT wins a tie only when its end is at or before
        -- CART_INIT's.
        WHEN ec.LOT1_TX_ENDDATE IS NOT NULL
         AND NOT (ec.CART_INIT_FLG = 1 AND ec.LOT1_TX_ENDDATE_REASON = 3)
         AND (ec.LOT1_BASE_1ST_ADD_MED_DT IS NULL
              OR (ec.CART_INIT_FLG = 1 AND ec.LOT1_TX_ENDDATE <= date_sub(ec.ENDING_CART_DT, 1))
              OR (ec.CART_INIT_FLG = 0 AND ec.LOT1_TX_ENDDATE <= ec.LOT1_BASE_1ST_ADD_MED_DT))
         AND (ec.LOT1_BASE_DISCON_DT IS NULL OR ec.LOT1_TX_ENDDATE <= ec.LOT1_BASE_DISCON_DT)
        THEN CASE ec.LOT1_TX_ENDDATE_REASON
               WHEN 1 THEN 'SCT_AUTO'
               WHEN 2 THEN 'SCT_ALLO'
               WHEN 3 THEN 'SCT_CART'
               ELSE 'SCT'
             END
        -- CART_INIT: a MED_ADD followed by a CART within
        -- {cfg$cart_consolidation_days} days. Its end date is
        -- ENDING_CART_DT - 1, so the gate against the run-out uses that.
        WHEN ec.CART_INIT_FLG = 1
         AND (ec.LOT1_BASE_DISCON_DT IS NULL OR date_sub(ec.ENDING_CART_DT, 1) <= ec.LOT1_BASE_DISCON_DT)
        THEN 'CART_INIT'
        -- MED_ADD: a new non-base drug added, with no CART within 45 days.
        WHEN ec.LOT1_BASE_1ST_ADD_MED_DT IS NOT NULL
         AND ec.CART_INIT_FLG = 0
         AND (ec.LOT1_BASE_DISCON_DT IS NULL OR ec.LOT1_BASE_1ST_ADD_MED_DT <= ec.LOT1_BASE_DISCON_DT)
        THEN 'MED_ADD'
        -- DEATH outranks DISCONTINUATION, but only when no LOT2-start trigger
        -- sits between the run-out and the death. If the patient ran out, then
        -- started new therapy or had an SCT before dying, the run-out is LOT1's
        -- real end and the new event opens LOT2.
        WHEN ec.DEATH_DT IS NOT NULL AND ec.DEATH_DT <= ec.OBS_END_DT
         AND ec.POST_RUNOUT_TRIGGER_FLG = 0 THEN 'DEATH'
        -- Rule 1: every drug discontinued.
        WHEN ec.LOT1_BASE_DISCON_DT IS NOT NULL THEN 'DISCONTINUATION'
        -- Study end. Disenrollment is not a censoring criterion in this study,
        -- so DISENROLLMENT never fires in the primary cascade.
        ELSE 'STUDY_END'
      END AS LOT1_BASE_END_REASON,
      -- The matching end date. Same order as the end reason above. CART_INIT
      -- ends LOT1 on ENDING_CART_DT - 1.
      CASE
        -- SCT_AUTO_CONT ends ON the AUTO, not the day before. The reason
        -- cascade above says why.
        WHEN ec.LOT1_AUTO_HOLD_DT IS NOT NULL
         AND ec.LOT1_AUTO_HOLD_DT > ec.LOT1_NATURAL_END_DT
         AND (ec.DEATH_DT IS NULL OR ec.LOT1_AUTO_HOLD_DT < ec.DEATH_DT)
        THEN ec.LOT1_AUTO_HOLD_DT
        WHEN ec.LOT1_TX_ENDDATE IS NOT NULL
         AND NOT (ec.CART_INIT_FLG = 1 AND ec.LOT1_TX_ENDDATE_REASON = 3)
         AND (ec.LOT1_BASE_1ST_ADD_MED_DT IS NULL
              OR (ec.CART_INIT_FLG = 1 AND ec.LOT1_TX_ENDDATE <= date_sub(ec.ENDING_CART_DT, 1))
              OR (ec.CART_INIT_FLG = 0 AND ec.LOT1_TX_ENDDATE <= ec.LOT1_BASE_1ST_ADD_MED_DT))
         AND (ec.LOT1_BASE_DISCON_DT IS NULL OR ec.LOT1_TX_ENDDATE <= ec.LOT1_BASE_DISCON_DT)
        THEN ec.LOT1_TX_ENDDATE
        WHEN ec.CART_INIT_FLG = 1
         AND (ec.LOT1_BASE_DISCON_DT IS NULL OR date_sub(ec.ENDING_CART_DT, 1) <= ec.LOT1_BASE_DISCON_DT)
        THEN date_sub(ec.ENDING_CART_DT, 1)
        WHEN ec.LOT1_BASE_1ST_ADD_MED_DT IS NOT NULL
         AND ec.CART_INIT_FLG = 0
         AND (ec.LOT1_BASE_DISCON_DT IS NULL OR ec.LOT1_BASE_1ST_ADD_MED_DT <= ec.LOT1_BASE_DISCON_DT)
        THEN ec.LOT1_BASE_1ST_ADD_MED_DT
        WHEN ec.DEATH_DT IS NOT NULL AND ec.DEATH_DT <= ec.OBS_END_DT
         AND ec.POST_RUNOUT_TRIGGER_FLG = 0 THEN ec.DEATH_DT
        WHEN ec.LOT1_BASE_DISCON_DT IS NOT NULL THEN ec.LOT1_BASE_DISCON_DT
        ELSE ec.OBS_END_DT  -- OBS_END_DT = ENDDATE (disenrollment not a censoring criterion)
      END AS LOT1_BASE_END_DT,
      -- LOT1_BASE_LENGTH mirrors the LOT1_BASE_END_DT cascade exactly, so the
      -- length is always LOT1_BASE_END_DT - LOT1_START_DT + 1. The order here
      -- matches the END_REASON priority: DEATH > DISCONTINUATION > STUDY_END.
      CASE
        WHEN ec.LOT1_AUTO_HOLD_DT IS NOT NULL
         AND ec.LOT1_AUTO_HOLD_DT > ec.LOT1_NATURAL_END_DT
         AND (ec.DEATH_DT IS NULL OR ec.LOT1_AUTO_HOLD_DT < ec.DEATH_DT)
        THEN datediff(ec.LOT1_AUTO_HOLD_DT, ec.LOT1_START_DT) + 1
        WHEN ec.LOT1_TX_ENDDATE IS NOT NULL
         AND NOT (ec.CART_INIT_FLG = 1 AND ec.LOT1_TX_ENDDATE_REASON = 3)
         AND (ec.LOT1_BASE_1ST_ADD_MED_DT IS NULL
              OR (ec.CART_INIT_FLG = 1 AND ec.LOT1_TX_ENDDATE <= date_sub(ec.ENDING_CART_DT, 1))
              OR (ec.CART_INIT_FLG = 0 AND ec.LOT1_TX_ENDDATE <= ec.LOT1_BASE_1ST_ADD_MED_DT))
         AND (ec.LOT1_BASE_DISCON_DT IS NULL OR ec.LOT1_TX_ENDDATE <= ec.LOT1_BASE_DISCON_DT)
        THEN datediff(ec.LOT1_TX_ENDDATE, ec.LOT1_START_DT) + 1
        WHEN ec.CART_INIT_FLG = 1
         AND (ec.LOT1_BASE_DISCON_DT IS NULL OR date_sub(ec.ENDING_CART_DT, 1) <= ec.LOT1_BASE_DISCON_DT)
        THEN datediff(date_sub(ec.ENDING_CART_DT, 1), ec.LOT1_START_DT) + 1
        WHEN ec.LOT1_BASE_1ST_ADD_MED_DT IS NOT NULL
         AND ec.CART_INIT_FLG = 0
         AND (ec.LOT1_BASE_DISCON_DT IS NULL OR ec.LOT1_BASE_1ST_ADD_MED_DT <= ec.LOT1_BASE_DISCON_DT)
        THEN datediff(ec.LOT1_BASE_1ST_ADD_MED_DT, ec.LOT1_START_DT) + 1
        -- DEATH outranks DISCONTINUATION, but only when there is no
        -- post-runout LOT2-start trigger.
        WHEN ec.DEATH_DT IS NOT NULL AND ec.DEATH_DT <= ec.OBS_END_DT
         AND ec.POST_RUNOUT_TRIGGER_FLG = 0
        THEN datediff(ec.DEATH_DT, ec.LOT1_START_DT) + 1
        WHEN ec.LOT1_BASE_DISCON_DT IS NOT NULL
        THEN datediff(ec.LOT1_BASE_DISCON_DT, ec.LOT1_START_DT) + 1
        ELSE datediff(ec.OBS_END_DT, ec.LOT1_START_DT) + 1
      END AS LOT1_BASE_LENGTH
    FROM end_natural ec
  "), qc = "
    SELECT LOT1_BASE_END_REASON, count(*) AS n,
           sum(CART_INIT_FLG) AS n_cart_init,
           sum(contains_mtx_reg) AS n_contains_mtx_reg
    FROM lot1_base_end
    GROUP BY LOT1_BASE_END_REASON
    ORDER BY LOT1_BASE_END_REASON")


  # NDC format QC. Do the code list and the claims agree on length?
}
