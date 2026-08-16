# The LOT1 end date and reason.
#
# map_stacked, lot1_base and lot1_sct are each written to a table where they are
# built - S07, S10 and S15 - because all three are read before this phase runs.
# (CACHE TABLE is unsupported on SQL warehouses, so a table is the only way to
# hold a result.)

phase_lot1_end <- function(con, ctx) {
  meds <- ctx$meds

  # S16b: contains_mtx_reg - flag-only maintenance concept.
  # Does the LOT1 induction regimen contain a valid maintenance-approved subset
  # (mono or dual) PLUS an anchor agent (any additional induction drug outside
  # that subset)? The anchor may itself be maintenance-eligible in another context.
  # A table: it self-joins lot1_induction_meds four times, and S16 below reads
  # it again. One row per patient, so the write is small either way.
  materialize(con, "S16b_lot1_contains_mtx_reg", view = "lot1_contains_mtx_reg", name = "LOT1_CONTAINS_MTX_REG", body = glue("
    WITH
    -- Valid maintenance regimens from actual induction drugs only (NOT substitution-
    -- expanded base_meds). Permissible subs can create phantom regimen members whose
    -- original drug then falsely anchors a single-agent induction.
    valid_maint_regimens AS (
      -- Mono maintenance: drug has MONOMAINTENANCE=1 and is an actual induction drug
      SELECT DISTINCT im.PATID, im.MED_ABBR AS REGIMEN_KEY
      FROM lot1_induction_meds im
      INNER JOIN mma_rollup ru ON im.MED_ABBR = ru.CL_MED_ABBR
      WHERE ru.MONOMAINTENANCE = 1
      UNION
      -- Dual maintenance: drug lists partner via DUALMAINTENANCEWITH, both in induction
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

  # S16: LOT1_BASE_END - the final LOT1 end reason and date.
  # Priority (highest wins), not just a tie-break on equal dates:
  #   SCT_AUTO_CONT > SCT_ALLO > SCT_CART > SCT_AUTO (excess) > CART_INIT
  #   > MED_ADD > DEATH > DISCONTINUATION > STUDY_END
  # SCT_AUTO_CONT sits at the top only in the sense of being tested first; it
  # is gated on falling after every other branch's date, so it never displaces
  # an end that already came later. DEATH is excluded from it explicitly.
  # DEATH can outrank an earlier DISCONTINUATION, but only when no
  # LOT2-qualifying trigger sits between runout and death (the post-runout
  # guard below). The SCT / CART_INIT / MED_ADD branches each gate
  # themselves against DISCON_DT, so they only fire when their event is at
  # or before runout.
  # Disenrollment is not a censoring criterion, so a period that ends at
  # disenrollment is classified STUDY_END (there is no DISENROLLMENT reason).
  # MAINTENANCE_END and SCT_NO_MAINT are not final values; those cases
  # route by their earliest applicable event.
  # CART_INIT (MED_ADD followed by CART within cart_consolidation_days)
  # ends LOT1 on ENDING_CART_DT - 1, the day before the CAR-T infusion.
  # A table: it is read nine times downstream and each read would otherwise
  # re-run the post-runout guard below, which scans map_stacked twice.
  materialize(con, "S16_lot1_base_end", view = "lot1_base_end", name = "LOT1_BASE_END", body = glue("
    WITH{melp_lot1_ctes(cfg)}
    -- Post-runout guard: identify whether any LOT2-qualifying trigger
    -- exists strictly after LOT1_BASE_RUNOUT_DT and on/before OBS_END_DT.
    -- Prevents DEATH from preempting DISCONTINUATION when a patient ran out
    -- and then started new therapy (or had an SCT) before dying.
    --
    -- These CTEs MIRROR the actual LOT2 start-candidate logic from
    -- lot2_5_base.R (med_cand / auto_cand) so the guard fires exactly when
    -- LOT2 would actually have a valid start trigger:
    --   - MED: any non-steroid MM agent NOT in LOT1's permissible biosimilar
    --     substitutes. Same-drug restarts DO qualify.
    --   - AUTO: any AUTO outside LOT1's own {cfg$induction_window_days}-day
    --     applicable window AND not within sct_tandem_days (180d) of the
    --     immediately prior AUTO in patient history (planned tandem).
    --   - ALLO/CART: any after runout (no window check; always trigger),
    --     except a CAR-T inside LOT1 induction, which under the CAR-T rule is
    --     part of LOT1 and starts nothing - so LOT2 would not act on it.
    -- What cannot confirm this line's run-out, because it cannot start the next
    -- line either: this line's own regimen agents and their permissible
    -- substitutes. med_cand excludes both, so accepting one here would confirm a
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
      INNER JOIN lot1_base lb ON ms.PATID = lb.PATID
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
      -- N_BETWEEN: whether anything happened since the previous transplant. A
      -- pair 180 days apart with a medication in the middle is not a planned
      -- tandem, so the later transplant is free to start a line.
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
      -- Mirrors LOT2-5 auto_cand, which now measures the window that belongs to
      -- the line it is looking back at. The previous line here is always LOT1,
      -- so that is LOT1's own {cfg$induction_window_days} days, not the
      -- {cfg$lot_n_induction_window_days} this used to borrow from LOT2-5.
      --
      -- The two have to agree. This guard decides whether a run-out counts as a
      -- confirmed discontinuation; auto_cand decides whether the same AUTO opens
      -- LOT2. Reading different windows lets DEATH take a line whose run-out the
      -- next line does in fact open on.
      SELECT DISTINCT lb.PATID
      FROM lot1_base lb
      INNER JOIN post_runout_autos awp ON lb.PATID = awp.PATID
      WHERE lb.LOT1_BASE_RUNOUT_DT IS NOT NULL
        AND awp.TX_DT > lb.LOT1_BASE_RUNOUT_DT
        AND awp.TX_DT <= lb.OBS_END_DT
        AND awp.TX_DT > date_add(lb.LOT1_START_DT, {cfg$induction_window_days} - 1)
        AND NOT (awp.PREV_AUTO_DT IS NOT NULL
                 AND datediff(awp.TX_DT, awp.PREV_AUTO_DT) <= {cfg$sct_tandem_days}
                 AND awp.N_BETWEEN = 0)
    ),
    post_runout_sct AS (
      -- Any ALLO or CAR-T strictly after the run-out and inside observation.
      --
      -- An EXISTENCE test over rows, like post_runout_med and post_runout_auto
      -- beside it, and deliberately not a comparison against lot1_sct's dates.
      -- FIRST_ALLO_DT and FIRST_CART_DT are min() over the whole line, so an
      -- earlier infusion hides every later one behind it: a patient with a
      -- CAR-T on day 20 absorbed into a live LOT1, a run-out on day 39 and a
      -- second CAR-T on day 50 has FIRST_CART_DT = day 20, which is not after
      -- the run-out, while the day-50 infusion that should confirm it is never
      -- looked at. ENDING_CART_DT is no better - the induction exemption nulls
      -- both. This is the same aggregate-versus-row mistake R/cart_rule.R
      -- documents for the line-ending date, in the other direction.
      --
      -- No window test: the arm already requires the infusion to be after the
      -- run-out, so the line's treatment had stopped before it arrived and the
      -- induction exemption cannot reach it.
      SELECT DISTINCT lb.PATID
      FROM lot1_base lb
      INNER JOIN tx_allo_cart_dates ac ON lb.PATID = ac.PATID
      WHERE lb.LOT1_BASE_RUNOUT_DT IS NOT NULL
        AND ac.SCT_TYPE IN ('ALLO', 'CART')
        AND ac.TX_DT > lb.LOT1_BASE_RUNOUT_DT
        AND ac.TX_DT <= lb.OBS_END_DT
    ),
    post_runout_trigger AS (
      -- Every arm is an existence test on a per-row CTE. Nothing here reads an
      -- aggregate, which is what makes a later event impossible to hide.
      SELECT lb.PATID,
        CASE
          WHEN lb.LOT1_BASE_RUNOUT_DT IS NULL THEN 0
          WHEN prm.PATID IS NOT NULL THEN 1
          WHEN prs.PATID IS NOT NULL THEN 1
          WHEN pra.PATID IS NOT NULL THEN 1
          ELSE 0
        END AS POST_RUNOUT_TRIGGER_FLG
      FROM lot1_base lb
      LEFT JOIN post_runout_med prm ON lb.PATID = prm.PATID
      LEFT JOIN post_runout_sct prs ON lb.PATID = prs.PATID
      LEFT JOIN post_runout_auto pra ON lb.PATID = pra.PATID
    ),
    end_candidates AS (
      SELECT
        lb.*,
        coalesce(prt.POST_RUNOUT_TRIGGER_FLG, 0) AS POST_RUNOUT_TRIGGER_FLG,
        -- The run-out becomes a discontinuation here rather than in
        -- 04_lot1_base.R, because POST_RUNOUT_TRIGGER_FLG only exists at this
        -- point. Either confirms it: {cfg$lot_discon_confirm_days} days of
        -- observation after it, or a LOT2-qualifying trigger. Unconfirmed
        -- leaves it NULL and the cascade censors at OBS_END_DT - which would
        -- swallow the restart if elapsed time were the only test, since LOT2
        -- has to start after LOT1 ends.
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
        -- contains_mtx_reg flag (descriptive only; does not drive end-reason
        -- routing or create a standalone maintenance period)
        COALESCE(cmr.contains_mtx_reg, 0) AS contains_mtx_reg,
        -- CART_INIT: MED_ADD followed by CART within {cfg$cart_consolidation_days} days
        -- If a new medication is added but then, within 45 days of that new
        -- agent, the patient starts CAR-T, the LOT1 end reason should be the
        -- CAR-T initiation, not the medication add.
        -- datediff(A, B) = A - B in Databricks; CART_DT - ADD_START_DT BETWEEN 0 AND 45
        -- Note: LOT1_BASE_1ST_ADD_MED_DT is date_sub(ADD_START_DT, 1), so add 1 back
        -- ENDING_CART_DT, not FIRST_CART_DT: the earliest CAR-T eligible to
        -- end the line, which is NULL only when the patient has no such
        -- infusion at all. lot1_sct computes it per row - see R/cart_rule.R.
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
    -- The end this line would have had before an in-window AUTO is considered:
    -- the whole cascade below, minus its SCT_AUTO_CONT branch. Computed as its
    -- own CTE because LOT1_BASE_DISCON_DT is derived in end_candidates and SQL
    -- cannot reference a select-list alias from the same select list.
    --
    -- It exists so the SCT_AUTO_CONT branch has one thing to compare against
    -- instead of restating every branch it has to beat. An AUTO extends the
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
      -- End reason priority (highest wins), not just a tie-break on equal
      -- earliest dates:
      --   SCT_AUTO_CONT > SCT_ALLO > SCT_CART > SCT_AUTO (excess) > CART_INIT
      --   > MED_ADD > DEATH > DISCONTINUATION > STUDY_END
      -- DEATH can outrank an earlier DISCONTINUATION, but only when no
      -- LOT2-qualifying trigger sits between runout and death (the
      -- post-runout guard above). SCT / CART_INIT / MED_ADD each gate
      -- themselves against DISCON_DT so they fire only when their event is
      -- at or before runout.
      -- Disenrollment is not a censoring criterion, so a period that ends
      -- at disenrollment is STUDY_END. MAINTENANCE_END and SCT_NO_MAINT
      -- are not final values; those cases route by earliest applicable
      -- event. CART_INIT ends LOT1 on ENDING_CART_DT - 1 (day before infusion).
      CASE
        -- SCT_AUTO_CONT: an AUTO inside LOT1's own applicable window belongs to
        -- LOT1, so LOT1 cannot be finalised before it. Where the cascade below
        -- would have ended the line earlier, the line runs to the transplant and
        -- ends ON it - not the day before, because this AUTO continues the line
        -- rather than starting the next one.
        --
        -- Why the line ends there at all: the protocol ends a LOT on the SCT
        -- date when the SCT is not followed by a maintenance regimen within 180
        -- days, and this build carries no maintenance period, so that test can
        -- never be met and the SCT date always wins.
        --
        -- Placed first, and gated on being strictly after LOT1_NATURAL_END_DT,
        -- so it fires only when it genuinely extends the line. That makes it
        -- outrank MED_ADD as well as DISCONTINUATION and STUDY_END. It cannot
        -- reach the SCT_ALLO / SCT_CART / CART_INIT ends: 05b_lot1_sct.R drops
        -- every AUTO at or after the first ALLO or CAR-T, so an AUTO that
        -- survives to here is always earlier than those events, never after them.
        --
        -- DEATH is the one end it does not outrank, which is the explicit guard
        -- below rather than a consequence of the ordering: claims can carry a
        -- service date after the recorded death, and a line may not outlive the
        -- patient.
        WHEN ec.LOT1_AUTO_HOLD_DT IS NOT NULL
         AND ec.LOT1_AUTO_HOLD_DT > ec.LOT1_NATURAL_END_DT
         AND (ec.DEATH_DT IS NULL OR ec.LOT1_AUTO_HOLD_DT < ec.DEATH_DT)
        THEN 'SCT_AUTO_CONT'
        -- Rule 2: SCT (ALLO, CART, or excess AUTO)
        -- When CART_INIT_FLG=1 and the SCT IS the CART (reason=3), skip this branch
        -- so CART_INIT can handle it. Otherwise CART events always route to SCT_CART
        -- before CART_INIT is ever reached.
        -- Tie-break vs CART_INIT uses ENDING_CART_DT - 1 (CART_INIT's end date),
        -- so SCT only wins on ties when its end is <= CART_INIT's end.
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
        -- CART_INIT: MED_ADD followed by CART within {cfg$cart_consolidation_days} days.
        -- The end date is ENDING_CART_DT - 1, so gate against discon uses that.
        WHEN ec.CART_INIT_FLG = 1
         AND (ec.LOT1_BASE_DISCON_DT IS NULL OR date_sub(ec.ENDING_CART_DT, 1) <= ec.LOT1_BASE_DISCON_DT)
        THEN 'CART_INIT'
        -- MED_ADD: new non-base drug added (not followed by CART within 45 days)
        WHEN ec.LOT1_BASE_1ST_ADD_MED_DT IS NOT NULL
         AND ec.CART_INIT_FLG = 0
         AND (ec.LOT1_BASE_DISCON_DT IS NULL OR ec.LOT1_BASE_1ST_ADD_MED_DT <= ec.LOT1_BASE_DISCON_DT)
        THEN 'MED_ADD'
        -- DEATH outranks DISCONTINUATION, but only when no LOT2-start
        -- trigger exists between runout and death. If the patient ran out
        -- then started new therapy (or had an SCT) before dying, the runout
        -- is the true LOT1 end and the new event triggers LOT2.
        WHEN ec.DEATH_DT IS NOT NULL AND ec.DEATH_DT <= ec.OBS_END_DT
         AND ec.POST_RUNOUT_TRIGGER_FLG = 0 THEN 'DEATH'
        -- Rule 1: Discontinuation of all agents (also catches former MAINTENANCE_END patients)
        WHEN ec.LOT1_BASE_DISCON_DT IS NOT NULL THEN 'DISCONTINUATION'
        -- Study end (disenrollment not a censoring criterion per study design;
        -- DISENROLLMENT therefore never triggers in the primary cascade).
        ELSE 'STUDY_END'
      END AS LOT1_BASE_END_REASON,
      -- Corresponding end date (mirrors end-reason priority).
      -- CART_INIT ends LOT1 on ENDING_CART_DT - 1.
      CASE
        -- SCT_AUTO_CONT ends ON the AUTO, not the day before it. See the reason
        -- cascade above for why.
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
      -- LOT1_BASE_LENGTH: mirrors the LOT1_BASE_END_DT cascade exactly, so
      -- length always equals (LOT1_BASE_END_DT - LOT1_START_DT + 1). The
      -- cascade order matches the END_REASON priority
      -- (DEATH > DISCONTINUATION > STUDY_END).
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
        -- DEATH outranks DISCONTINUATION, but only when no post-runout
        -- LOT2-start trigger exists.
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


  # NDC format QC: do the code list and the claims agree on length?
}
