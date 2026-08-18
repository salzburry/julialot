# LOT1's own SCT summary. It needs lot1_base, so a fresh-session LOT2-5 run
# does not rebuild it.
#
# It reads the views phase_sct left behind, not anything out of ctx. ctx is in
# the signature to match the other phases, and for no other reason.

phase_lot1_sct <- function(con, ctx) {
  # S15: LOT1 SCT variables
  # Derives: LOT1_TX_AUTO_DT_1/2, TAND_FLG, SING_FLG,
  #          LOT1_TX_ENDDATE, LOT1_TX_ENDDATE_REASON, LOT1_1ST_SCT_DT
  # Written to a table rather than left for phase_lot1_end to copy. It is five
  # aggregates and a window function over the SCT dates, read twelve times over
  # a run: S16, phase_qc, phase_persist's QC row, and the LOT1 projection
  # LOT2-5 starts from.
  # A CAR-T inside LOT1's induction window does not end LOT1 - see
  # R/cart_rule.R. FIRST_CART_DT itself is left alone. LOT1_1ST_SCT_DT below is
  # descriptive, and under this rule that infusion really is the first SCT
  # during LOT1. Only the line-ending arithmetic is gated.
  cart_elig <- cart_eligible_dt(cfg$apply_cart_induction_rule,
                                "ac.TX_DT", "l.LOT1_START_DT",
                                cfg$induction_window_days)
  cart_censor <- cart_censor_predicate(cfg$apply_cart_induction_rule,
                                       "ac.SCT_TYPE", "ac.TX_DT",
                                       "l.LOT1_START_DT",
                                       cfg$induction_window_days)
  cart_note <- if (isTRUE(cfg$apply_cart_induction_rule))
    "A CAR-T inside induction is part of LOT1 and cannot end it (cart_rule.R)."
  else "CAR-T induction rule off: any CAR-T can end LOT1."
  materialize(con, "S15_lot1_sct", view = "lot1_sct", name = "LOT1_SCT", body = glue("
    WITH lot1 AS (
      SELECT PATID, LOT1_START_DT, OBS_END_DT FROM lot1_base
    ),
    -- AUTO dates within LOT1 observation window
    -- Censored at the earliest ALLO or CART. Both end LOT1 at once, so an
    -- AUTO after one of them is nothing to do with LOT1. The predicate is
    -- strict (<), so an AUTO ON the ALLO/CART date is dropped too: the line
    -- ended the day before, and that AUTO belongs to whatever follows.
    earliest_non_auto AS (
      SELECT ac.PATID, min(ac.TX_DT) AS FIRST_NON_AUTO_DT
      FROM tx_allo_cart_dates ac
      INNER JOIN lot1 l ON ac.PATID = l.PATID
      WHERE ac.SCT_TYPE IN ('ALLO', 'CART')
        AND ac.TX_DT >= l.LOT1_START_DT
        AND ac.TX_DT <= l.OBS_END_DT{cart_censor}
      GROUP BY ac.PATID
    ),
    auto_in_lot1 AS (
      SELECT a.PATID, a.TX_DT,
             row_number() OVER (PARTITION BY a.PATID ORDER BY a.TX_DT) AS LOT1_SEQ
      FROM tx_auto_dates a
      INNER JOIN lot1 l ON a.PATID = l.PATID
      LEFT JOIN earliest_non_auto ena ON a.PATID = ena.PATID
      WHERE a.TX_DT >= l.LOT1_START_DT
        AND a.TX_DT <= l.OBS_END_DT
        AND (ena.FIRST_NON_AUTO_DT IS NULL OR a.TX_DT < ena.FIRST_NON_AUTO_DT)
    ),
    auto_pivot AS (
      SELECT PATID,
        max(CASE WHEN LOT1_SEQ = 1 THEN TX_DT END) AS AUTO_DT_1,
        max(CASE WHEN LOT1_SEQ = 2 THEN TX_DT END) AS AUTO_DT_2,
        max(CASE WHEN LOT1_SEQ = 3 THEN TX_DT END) AS AUTO_DT_3
      FROM auto_in_lot1
      GROUP BY PATID
    ),
    -- First ALLO date within LOT1
    first_allo AS (
      SELECT ac.PATID, min(ac.TX_DT) AS ALLO_DT
      FROM tx_allo_cart_dates ac
      INNER JOIN lot1 l ON ac.PATID = l.PATID
      WHERE ac.SCT_TYPE = 'ALLO'
        AND ac.TX_DT >= l.LOT1_START_DT
        AND ac.TX_DT <= l.OBS_END_DT
      GROUP BY ac.PATID
    ),
    -- First CART date within LOT1
    -- Two dates, because a CAR-T is either descriptive or a boundary and which
    -- one is a property of the row. CART_DT is the earliest of any kind and
    -- feeds LOT1_1ST_SCT_DT; ENDING_CART_DT is the earliest eligible to end the
    -- line. Taking min() first and nulling it afterwards lost every later
    -- CAR-T behind an in-induction one. See R/cart_rule.R.
    first_cart AS (
      SELECT ac.PATID, min(ac.TX_DT) AS CART_DT,
             min({cart_elig}) AS ENDING_CART_DT
      FROM tx_allo_cart_dates ac
      INNER JOIN lot1 l ON ac.PATID = l.PATID
      WHERE ac.SCT_TYPE = 'CART'
        AND ac.TX_DT >= l.LOT1_START_DT
        AND ac.TX_DT <= l.OBS_END_DT
      GROUP BY ac.PATID
    ),
    -- Is there an ALLO between AUTO_DT_1 and AUTO_DT_2, inclusive? If so the
    -- pair is not a tandem.
    --
    -- Belt and braces. The censor above already drops any AUTO at or past the
    -- first ALLO, so an AUTO_DT_2 with an ALLO at or before it cannot reach
    -- here, and this branch is unreachable from LOT1's own inputs. Kept because
    -- it is cheap and the two guards fail safe on their own.
    allo_between AS (
      SELECT ap.PATID,
        sum(CASE WHEN ac.TX_DT >= ap.AUTO_DT_1 AND ac.TX_DT <= ap.AUTO_DT_2
                 THEN 1 ELSE 0 END) AS n_allo_between
      FROM auto_pivot ap
      LEFT JOIN tx_allo_cart_dates ac
        ON ap.PATID = ac.PATID AND ac.SCT_TYPE = 'ALLO'
      WHERE ap.AUTO_DT_2 IS NOT NULL
      GROUP BY ap.PATID
    ),
    -- A tandem is a tandem only if nothing happens between the two
    -- transplants. The gap alone does not make the pair planned. A patient
    -- treated in between was not waiting for a second transplant, and the
    -- protocol reads a tandem as planned and as a continuation of the line -
    -- which does not describe them.
    --
    -- Anything at all means a non-steroid medication starting, an allogeneic
    -- transplant, or a CAR-T. Strictly between, so a claim on either
    -- transplant date belongs to that transplant rather than interrupting the
    -- pair.
    --
    -- This is what makes it safe for the hold date below to follow a tandem
    -- partner past the line's own window. The extension can swallow nothing,
    -- because anything it could swallow breaks the tandem first.
    tandem_interrupt AS (
      SELECT ap.PATID,
             sum(CASE WHEN x.dt > ap.AUTO_DT_1 AND x.dt < ap.AUTO_DT_2
                      THEN 1 ELSE 0 END) AS n_between
      FROM auto_pivot ap
      LEFT JOIN ({tandem_interrupt_events_sql()}
      ) x ON ap.PATID = x.PATID
      WHERE ap.AUTO_DT_2 IS NOT NULL
      GROUP BY ap.PATID
    ),
    -- Derive tandem flag and LOT-ending AUTO date
    sct_derived AS (
      SELECT
        l.PATID,
        l.LOT1_START_DT,
        ap.AUTO_DT_1 AS LOT1_TX_AUTO_DT_1,
        ap.AUTO_DT_2 AS LOT1_TX_AUTO_DT_2,
        -- Tandem: two AUTO SCTs within 180 days, no ALLO between
        CASE
          WHEN ap.AUTO_DT_2 IS NOT NULL
           AND datediff(ap.AUTO_DT_2, ap.AUTO_DT_1) <= {cfg$sct_tandem_days}  -- Tandem if AUTO_DT_2 is within sct_tandem_days (180d) of AUTO_DT_1; no +1
           AND coalesce(ab.n_allo_between, 0) = 0
           AND coalesce(ti.n_between, 0) = 0
          THEN 1 ELSE 0
        END AS LOT1_SCT_AUTO_TAND_FLG,
        -- Single AUTO: has first AUTO but not a valid tandem
        CASE
          WHEN ap.AUTO_DT_1 IS NOT NULL
           AND NOT (ap.AUTO_DT_2 IS NOT NULL
                    AND datediff(ap.AUTO_DT_2, ap.AUTO_DT_1) <= {cfg$sct_tandem_days}  -- Tandem if AUTO_DT_2 is within sct_tandem_days (180d) of AUTO_DT_1; no +1
                    AND coalesce(ab.n_allo_between, 0) = 0
           AND coalesce(ti.n_between, 0) = 0)
          THEN 1 ELSE 0
        END AS LOT1_SCT_AUTO_SING_FLG,
        -- LOT-ending AUTO: excess AUTO beyond what's allowed
        -- Tandem -> 3rd AUTO ends LOT1; Single -> 2nd AUTO ends LOT1
        CASE
          WHEN ap.AUTO_DT_2 IS NOT NULL
           AND datediff(ap.AUTO_DT_2, ap.AUTO_DT_1) <= {cfg$sct_tandem_days}  -- Tandem if AUTO_DT_2 is within sct_tandem_days (180d) of AUTO_DT_1; no +1
           AND coalesce(ab.n_allo_between, 0) = 0
           AND coalesce(ti.n_between, 0) = 0
          THEN ap.AUTO_DT_3
          WHEN ap.AUTO_DT_1 IS NOT NULL
          THEN ap.AUTO_DT_2
          ELSE NULL
        END AS ENDING_AUTO_DT,
        fa.ALLO_DT AS FIRST_ALLO_DT,
        fc.CART_DT AS FIRST_CART_DT,
        fc.ENDING_CART_DT,
        -- LOT1_TX_AUTO_FLG: binary flag for any valid autologous HSCT
        CASE WHEN ap.AUTO_DT_1 IS NOT NULL THEN 1 ELSE 0 END AS LOT1_TX_AUTO_FLG,
        -- LOT1_TX_AUTO_MAX_DT: date of 2nd tandem AUTO if tandem, else single AUTO date
        CASE
          WHEN ap.AUTO_DT_2 IS NOT NULL
           AND datediff(ap.AUTO_DT_2, ap.AUTO_DT_1) <= {cfg$sct_tandem_days}
           AND coalesce(ab.n_allo_between, 0) = 0
           AND coalesce(ti.n_between, 0) = 0
          THEN ap.AUTO_DT_2
          ELSE ap.AUTO_DT_1
        END AS LOT1_TX_AUTO_MAX_DT,
        -- LOT1_AUTO_HOLD_DT: the last AUTO LOT1 OWNS that falls inside LOT1's
        -- own window, days 0..{cfg$induction_window_days - 1} from the line
        -- start. It is what stops the line being closed before a transplant
        -- that belongs to it - see the SCT_AUTO_CONT branch in 06_lot1_end.R.
        --
        -- Not LOT1_TX_AUTO_MAX_DT, and that is on purpose. That column has no
        -- upper bound: it takes any AUTO in the observation period, including
        -- one sitting after the line ended that starts LOT2 instead. Only an
        -- AUTO inside the window can hold the line open.
        --
        -- Owns here means the single AUTO, or the second of a tandem pair.
        -- Never the excess AUTO, which ENDING_AUTO_DT already closes the line
        -- on.
        --
        -- The FIRST transplant of a tandem must be in the window. The second
        -- need not be, and follows it however far out it sits. That is the
        -- protocol's rule: a planned tandem continues the line. It is safe here
        -- only because tandem_interrupt has already established that nothing
        -- happened between the two. A pair with a medication, an ALLO or a
        -- CAR-T in the middle is not a tandem, so the extension cannot swallow
        -- an event - the event breaks the pair first.
        CASE
          WHEN ap.AUTO_DT_2 IS NOT NULL
           AND datediff(ap.AUTO_DT_2, ap.AUTO_DT_1) <= {cfg$sct_tandem_days}
           AND coalesce(ab.n_allo_between, 0) = 0
           AND coalesce(ti.n_between, 0) = 0
           AND datediff(ap.AUTO_DT_1, l.LOT1_START_DT) < {cfg$induction_window_days}
          THEN ap.AUTO_DT_2
          WHEN ap.AUTO_DT_1 IS NOT NULL
           AND datediff(ap.AUTO_DT_1, l.LOT1_START_DT) < {cfg$induction_window_days}
          THEN ap.AUTO_DT_1
          ELSE NULL
        END AS LOT1_AUTO_HOLD_DT
      FROM lot1 l
      LEFT JOIN auto_pivot ap ON l.PATID = ap.PATID
      LEFT JOIN allo_between ab ON l.PATID = ab.PATID
      LEFT JOIN tandem_interrupt ti ON l.PATID = ti.PATID
      LEFT JOIN first_allo fa ON l.PATID = fa.PATID
      LEFT JOIN first_cart fc ON l.PATID = fc.PATID
    )
    SELECT
      sd.*,
      -- LOT1_TX_ENDDATE: the earliest LOT-ending SCT event, minus a day,
      -- floored at the line start. The windows above accept an SCT on the start
      -- date itself, and the day before that is earlier than the line, which
      -- check_lot_long refuses. Floored, the line is one day long and still
      -- ends SCT_CART.
      -- {cart_note}
      CASE
        WHEN coalesce(sd.ENDING_AUTO_DT, sd.FIRST_ALLO_DT, sd.ENDING_CART_DT) IS NOT NULL
        THEN greatest(sd.LOT1_START_DT, date_sub(
          least(
            coalesce(sd.ENDING_AUTO_DT, cast('9999-12-31' as date)),
            coalesce(sd.FIRST_ALLO_DT,  cast('9999-12-31' as date)),
            coalesce(sd.ENDING_CART_DT,   cast('9999-12-31' as date))
          ), 1))
        ELSE NULL
      END AS LOT1_TX_ENDDATE,
      -- LOT1_TX_ENDDATE_REASON: 1 = AUTO, 2 = ALLO, 3 = CART - whichever came
      -- first. On an exact same-day tie AUTO wins here, then ALLO, then CART -
      -- the opposite order from LOT2-5, which tests ALLO first. The end DATE
      -- is the same either way; only the recorded reason differs. Open
      -- question Q4 on the scenario workbook's Open questions sheet.
      CASE
        WHEN coalesce(sd.ENDING_AUTO_DT, sd.FIRST_ALLO_DT, sd.ENDING_CART_DT) IS NULL THEN NULL
        WHEN coalesce(sd.ENDING_AUTO_DT, cast('9999-12-31' as date))
             <= coalesce(sd.FIRST_ALLO_DT, cast('9999-12-31' as date))
         AND coalesce(sd.ENDING_AUTO_DT, cast('9999-12-31' as date))
             <= coalesce(sd.ENDING_CART_DT, cast('9999-12-31' as date))
        THEN 1
        WHEN coalesce(sd.FIRST_ALLO_DT, cast('9999-12-31' as date))
             <= coalesce(sd.ENDING_CART_DT, cast('9999-12-31' as date))
        THEN 2
        ELSE 3
      END AS LOT1_TX_ENDDATE_REASON,
      -- LOT1_1ST_SCT_DT: the first SCT of any type during LOT1.
      CASE
        WHEN coalesce(sd.LOT1_TX_AUTO_DT_1, sd.FIRST_ALLO_DT, sd.FIRST_CART_DT) IS NOT NULL
        THEN least(
          coalesce(sd.LOT1_TX_AUTO_DT_1, cast('9999-12-31' as date)),
          coalesce(sd.FIRST_ALLO_DT,     cast('9999-12-31' as date)),
          coalesce(sd.FIRST_CART_DT,      cast('9999-12-31' as date))
        )
        ELSE NULL
      END AS LOT1_1ST_SCT_DT
    FROM sct_derived sd
  "), qc = "
    SELECT
      count(*) AS n_patients,
      sum(CASE WHEN LOT1_TX_AUTO_DT_1 IS NOT NULL THEN 1 ELSE 0 END) AS n_with_auto,
      sum(CASE WHEN FIRST_ALLO_DT IS NOT NULL THEN 1 ELSE 0 END) AS n_with_allo,
      sum(CASE WHEN FIRST_CART_DT IS NOT NULL THEN 1 ELSE 0 END) AS n_with_cart,
      sum(LOT1_SCT_AUTO_TAND_FLG) AS n_tandem,
      sum(LOT1_SCT_AUTO_SING_FLG) AS n_single_auto,
      sum(CASE WHEN LOT1_TX_ENDDATE IS NOT NULL THEN 1 ELSE 0 END) AS n_with_sct_end
    FROM lot1_sct")
}
