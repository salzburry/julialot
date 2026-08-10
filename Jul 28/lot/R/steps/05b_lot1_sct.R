# LOT1's own SCT summary. Needs lot1_base, so it is not part of what a
# fresh-session LOT2-5 run rebuilds.
#
# It reads views phase_sct left behind rather than anything out of ctx, so ctx
# is in the signature for consistency with the other phases and nothing more.

phase_lot1_sct <- function(con, ctx) {
  # S15: LOT1 SCT variables
  # Derives: LOT1_TX_AUTO_DT_1/2, TAND_FLG, SING_FLG,
  #          LOT1_TX_ENDDATE, LOT1_TX_ENDDATE_REASON, LOT1_1ST_SCT_DT
  # Written to a table rather than left for phase_lot1_end to copy: five
  # aggregates and a window function over the SCT dates, read twelve times
  # over the run - S16, phase_qc, phase_persist's QC row, and the LOT1
  # projection LOT2-5 starts from.
  materialize(con, "S15_lot1_sct", view = "lot1_sct", name = "LOT1_SCT", body = glue("
    WITH lot1 AS (
      SELECT PATID, LOT1_START_DT, OBS_END_DT FROM lot1_base
    ),
    -- AUTO dates within LOT1 observation window
    -- Censored at earliest ALLO/CART: ALLO and CART immediately end LOT1,
    -- so AUTO events after an ALLO/CART are not relevant to LOT1.
    earliest_non_auto AS (
      SELECT ac.PATID, min(ac.TX_DT) AS FIRST_NON_AUTO_DT
      FROM tx_allo_cart_dates ac
      INNER JOIN lot1 l ON ac.PATID = l.PATID
      WHERE ac.SCT_TYPE IN ('ALLO', 'CART')
        AND ac.TX_DT >= l.LOT1_START_DT
        AND ac.TX_DT <= l.OBS_END_DT
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
    first_cart AS (
      SELECT ac.PATID, min(ac.TX_DT) AS CART_DT
      FROM tx_allo_cart_dates ac
      INNER JOIN lot1 l ON ac.PATID = l.PATID
      WHERE ac.SCT_TYPE = 'CART'
        AND ac.TX_DT >= l.LOT1_START_DT
        AND ac.TX_DT <= l.OBS_END_DT
      GROUP BY ac.PATID
    ),
    -- Check for ALLO between AUTO_DT_1 and AUTO_DT_2 (inclusive)
    -- Tandem disqualified if ALLO exists such that AUTO_DT_1 <= ALLO <= AUTO_DT_2
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
          THEN 1 ELSE 0
        END AS LOT1_SCT_AUTO_TAND_FLG,
        -- Single AUTO: has first AUTO but not a valid tandem
        CASE
          WHEN ap.AUTO_DT_1 IS NOT NULL
           AND NOT (ap.AUTO_DT_2 IS NOT NULL
                    AND datediff(ap.AUTO_DT_2, ap.AUTO_DT_1) <= {cfg$sct_tandem_days}  -- Tandem if AUTO_DT_2 is within sct_tandem_days (180d) of AUTO_DT_1; no +1
                    AND coalesce(ab.n_allo_between, 0) = 0)
          THEN 1 ELSE 0
        END AS LOT1_SCT_AUTO_SING_FLG,
        -- LOT-ending AUTO: excess AUTO beyond what's allowed
        -- Tandem -> 3rd AUTO ends LOT1; Single -> 2nd AUTO ends LOT1
        CASE
          WHEN ap.AUTO_DT_2 IS NOT NULL
           AND datediff(ap.AUTO_DT_2, ap.AUTO_DT_1) <= {cfg$sct_tandem_days}  -- Tandem if AUTO_DT_2 is within sct_tandem_days (180d) of AUTO_DT_1; no +1
           AND coalesce(ab.n_allo_between, 0) = 0
          THEN ap.AUTO_DT_3
          WHEN ap.AUTO_DT_1 IS NOT NULL
          THEN ap.AUTO_DT_2
          ELSE NULL
        END AS ENDING_AUTO_DT,
        fa.ALLO_DT AS FIRST_ALLO_DT,
        fc.CART_DT AS FIRST_CART_DT,
        -- LOT1_TX_AUTO_FLG: binary flag for any valid autologous HSCT
        CASE WHEN ap.AUTO_DT_1 IS NOT NULL THEN 1 ELSE 0 END AS LOT1_TX_AUTO_FLG,
        -- LOT1_TX_AUTO_MAX_DT: date of 2nd tandem AUTO if tandem, else single AUTO date
        CASE
          WHEN ap.AUTO_DT_2 IS NOT NULL
           AND datediff(ap.AUTO_DT_2, ap.AUTO_DT_1) <= {cfg$sct_tandem_days}
           AND coalesce(ab.n_allo_between, 0) = 0
          THEN ap.AUTO_DT_2
          ELSE ap.AUTO_DT_1
        END AS LOT1_TX_AUTO_MAX_DT
      FROM lot1 l
      LEFT JOIN auto_pivot ap ON l.PATID = ap.PATID
      LEFT JOIN allo_between ab ON l.PATID = ab.PATID
      LEFT JOIN first_allo fa ON l.PATID = fa.PATID
      LEFT JOIN first_cart fc ON l.PATID = fc.PATID
    )
    SELECT
      sd.*,
      -- LOT1_TX_ENDDATE: earliest LOT-ending SCT event - 1 day, floored at the
      -- line start. The windows above take an SCT on the start date itself, and
      -- the day before that is earlier than the line - which check_lot_long
      -- refuses. Floored, the line is one day long and still ends SCT_CART.
      CASE
        WHEN coalesce(sd.ENDING_AUTO_DT, sd.FIRST_ALLO_DT, sd.FIRST_CART_DT) IS NOT NULL
        THEN greatest(sd.LOT1_START_DT, date_sub(
          least(
            coalesce(sd.ENDING_AUTO_DT, cast('9999-12-31' as date)),
            coalesce(sd.FIRST_ALLO_DT,  cast('9999-12-31' as date)),
            coalesce(sd.FIRST_CART_DT,   cast('9999-12-31' as date))
          ), 1))
        ELSE NULL
      END AS LOT1_TX_ENDDATE,
      -- LOT1_TX_ENDDATE_REASON: 1=AUTO, 2=ALLO, 3=CART (whichever is earliest)
      CASE
        WHEN coalesce(sd.ENDING_AUTO_DT, sd.FIRST_ALLO_DT, sd.FIRST_CART_DT) IS NULL THEN NULL
        WHEN coalesce(sd.ENDING_AUTO_DT, cast('9999-12-31' as date))
             <= coalesce(sd.FIRST_ALLO_DT, cast('9999-12-31' as date))
         AND coalesce(sd.ENDING_AUTO_DT, cast('9999-12-31' as date))
             <= coalesce(sd.FIRST_CART_DT, cast('9999-12-31' as date))
        THEN 1
        WHEN coalesce(sd.FIRST_ALLO_DT, cast('9999-12-31' as date))
             <= coalesce(sd.FIRST_CART_DT, cast('9999-12-31' as date))
        THEN 2
        ELSE 3
      END AS LOT1_TX_ENDDATE_REASON,
      -- LOT1_1ST_SCT_DT: first SCT of any type during LOT1
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
