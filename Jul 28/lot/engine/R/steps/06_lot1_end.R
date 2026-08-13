# The LOT1 end date and reason.
#
# map_stacked, lot1_base and lot1_sct used to be copied to tables here, at the
# top of this phase. Each is now written where it is built - S07, S10 and S15 -
# because every one of them is read before this phase is reached, and a copy
# taken afterwards leaves those earlier reads re-running the query. There is
# nothing left to materialize here. (CACHE TABLE is not supported on SQL
# warehouses, so a table is the only way to hold a result.)

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
  #   SCT_ALLO > SCT_CART > SCT_AUTO (excess) > CART_INIT > MED_ADD
  #   > DEATH > DISCONTINUATION > STUDY_END
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
  # Written here rather than copied to a table by phase_persist, which is
  # where it used to be: that copy came after phase_qc and the LOT1
  # invariants had already read the view, and it never repointed the view, so
  # LOT2-5 started from the query as well. It is read nine times downstream,
  # and each read re-ran the post-runout guard below, which scans map_stacked
  # twice on its own.
  materialize(con, "S16_lot1_base_end", view = "lot1_base_end", name = "LOT1_BASE_END", body = glue("
    WITH{melp_lot1_ctes(cfg)}
    -- Post-runout guard: identify whether any LOT2-qualifying trigger
    -- exists strictly after LOT1_BASE_DISCON_DT and on/before OBS_END_DT.
    -- Prevents DEATH from preempting DISCONTINUATION when a patient ran out
    -- and then started new therapy (or had an SCT) before dying.
    --
    -- These CTEs MIRROR the actual LOT2 start-candidate logic from
    -- lot2_5_base.R (med_cand / auto_cand) so the guard fires exactly when
    -- LOT2 would actually have a valid start trigger:
    --   - MED: any non-steroid MM agent NOT in LOT1's permissible biosimilar
    --     substitutes. Same-drug restarts DO qualify.
    --   - AUTO: any AUTO outside LOT1 30-day applicable window
    --     (LOT2-5 auto_cand uses 30d for any MED-started prior LOT,
    --     regardless of LOT1's own 60d induction window) AND not within
    --     sct_tandem_days (180d) of the immediately prior AUTO in patient
    --     history (planned tandem).
    --   - ALLO/CART: any after runout (no window check; always trigger),
    --     except a CAR-T inside LOT1 induction, which under the CAR-T rule is
    --     part of LOT1 and starts nothing - so LOT2 would not act on it.
    post_runout_excluded_meds AS (
      SELECT im.PATID, ps.substitute_med AS MED_ABBR
      FROM lot1_induction_meds im
      INNER JOIN permissible_subs ps ON im.MED_ABBR = ps.original_med
    ),
    post_runout_med AS (
      SELECT DISTINCT ms.PATID
      FROM map_stacked ms
      INNER JOIN lot1_base lb ON ms.PATID = lb.PATID
      LEFT JOIN post_runout_excluded_meds prem
        ON ms.PATID = prem.PATID AND ms.MAP_MED_TYPE = prem.MED_ABBR
      WHERE lb.LOT1_BASE_DISCON_DT IS NOT NULL
        AND ms.MAP_START_DT > lb.LOT1_BASE_DISCON_DT
        AND ms.MAP_START_DT <= lb.OBS_END_DT
        AND ms.MAP_MED_CLASS <> 'STEROID'
        AND prem.MED_ABBR IS NULL
    ),
    post_runout_autos AS (
      SELECT a.PATID, a.TX_DT,
             lag(a.TX_DT) OVER (PARTITION BY a.PATID ORDER BY a.TX_DT) AS PREV_AUTO_DT
      FROM tx_auto_dates a
    ),
    post_runout_auto AS (
      -- Mirrors LOT2-5 auto_cand: LOT1 is MED-started in lot_long, so the
      -- applicable window from LOT2 perspective is cfg$lot_n_induction_window_days
      -- (default 30d). LOT1's own 60d induction window is NOT used here because the
      -- guard models what LOT2's auto_cand would see, not what LOT1 itself uses.
      SELECT DISTINCT lb.PATID
      FROM lot1_base lb
      INNER JOIN post_runout_autos awp ON lb.PATID = awp.PATID
      WHERE lb.LOT1_BASE_DISCON_DT IS NOT NULL
        AND awp.TX_DT > lb.LOT1_BASE_DISCON_DT
        AND awp.TX_DT <= lb.OBS_END_DT
        AND awp.TX_DT > date_add(lb.LOT1_START_DT, {cfg$lot_n_induction_window_days} - 1)
        AND NOT (awp.PREV_AUTO_DT IS NOT NULL
                 AND datediff(awp.TX_DT, awp.PREV_AUTO_DT) <= {cfg$sct_tandem_days})
    ),
    post_runout_trigger AS (
      SELECT lb.PATID,
        CASE
          WHEN lb.LOT1_BASE_DISCON_DT IS NULL THEN 0
          WHEN prm.PATID IS NOT NULL THEN 1
          WHEN sct.FIRST_ALLO_DT IS NOT NULL AND sct.FIRST_ALLO_DT > lb.LOT1_BASE_DISCON_DT THEN 1
          WHEN sct.ENDING_CART_DT IS NOT NULL AND sct.ENDING_CART_DT > lb.LOT1_BASE_DISCON_DT THEN 1
          WHEN pra.PATID IS NOT NULL THEN 1
          ELSE 0
        END AS POST_RUNOUT_TRIGGER_FLG
      FROM lot1_base lb
      LEFT JOIN lot1_sct sct ON lb.PATID = sct.PATID
      LEFT JOIN post_runout_med prm ON lb.PATID = prm.PATID
      LEFT JOIN post_runout_auto pra ON lb.PATID = pra.PATID
    ),
    end_candidates AS (
      SELECT
        lb.*,
        coalesce(prt.POST_RUNOUT_TRIGGER_FLG, 0) AS POST_RUNOUT_TRIGGER_FLG,
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
    )
    SELECT
      ec.*,
      -- End reason priority (highest wins), not just a tie-break on equal
      -- earliest dates:
      --   SCT_ALLO > SCT_CART > SCT_AUTO (excess) > CART_INIT > MED_ADD
      --   > DEATH > DISCONTINUATION > STUDY_END
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
    FROM end_candidates ec
  "), qc = "
    SELECT LOT1_BASE_END_REASON, count(*) AS n,
           sum(CART_INIT_FLG) AS n_cart_init,
           sum(contains_mtx_reg) AS n_contains_mtx_reg
    FROM lot1_base_end
    GROUP BY LOT1_BASE_END_REASON
    ORDER BY LOT1_BASE_END_REASON")


  # NDC format QC: do the code list and the claims agree on length?
}
