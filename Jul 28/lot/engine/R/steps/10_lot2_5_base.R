#!/usr/bin/env Rscript
# The LOT2 to LOT5 base-period builder. A module of its own. It changes nothing
# in any LOT1 module.
#
# Assumes the LOT1 phases already produced these views and tables in the same
# connection and work schema:
#   - lot_patient_input    patient cohort + OBS_END_DT, ENDDATE_CE, etc.
#   - map_stacked          medication-available periods per agent
#   - permissible_subs     biosimilar substitution table
#   - mma_rollup           MED_ABBR -> maintenance flags
#   - tx_auto_dates        per-patient AUTO SCT dates, post-grouping
#   - tx_allo_cart_dates   per-patient ALLO/CART dates
#   - lot1_base_end        LOT1 row with LOT1_BASE_END_DT, end reason and so on
#
# Produces lot_long, one row per (PATID, LOT_NUM):
#   PATID, LOT_NUM, LOT_START_DT, LOT_START_TYPE,
#   LOT_BASE_MEDS, LOT_MED_CNT, LOT_BASE_DISCON_DT,
#   LOT_BASE_1ST_ADD_MED_DT, LOT_BASE_1ST_ADD_MED,
#   LOT_BASE_END_DT, LOT_BASE_END_REASON, LOT_BASE_LENGTH,
#   LOT_ALLO_LOT_FLG, LOT_CART_LOT_FLG, contains_mtx_reg,
#   LOT_BASE_END_DT_CE_SENS, LOT_BASE_END_REASON_CE_SENS
#
# Key parameters (defaults reflect study-team decisions):
#   induction_window_days   = 30   (LOT1 uses 60)
#     There is no LOT-level discontinuation buffer. The per-drug 90-day rule
#     lives in map_discon_gap_days.
#   cart_consolidation_days = 45   (supersedes the earlier 30d value)
#   sct_tandem_days         = 180  (>180d AUTO is unplanned)
#   allo_lot_span           = "single_day": ALLO LOT spans only ALLO_DT
#   max_lot                 = 5
#
# End reasons are decided by date. The tie-break applies only to equal dates.

# ---- Helpers ----

# Normalize a MED_ABBR to a column-safe token (matches LOT1 convention).
.lot_sanitize_col <- function(x) gsub("[^A-Za-z0-9]+", "_", toupper(x))

# The staging table for the LOT_LONG build. Everything writes here - the LOT1
# init and the LOT2..N appends. build_lot2_5() swaps the finished LOT_LONG into
# place only once every LOT has appended without error.
#
# So a failure mid-loop leaves a partial LOT_LONG_STAGE, never a partial
# LOT_LONG. The orchestrator's "LOT_LONG already exists" skip cannot be fooled
# by an incomplete build, and a good LOT_LONG from before is kept until a
# complete rebuild replaces it.
.LOT_LONG_STAGE <- "LOT_LONG_STAGE"

# 9999-12-31 sentinel for SQL least() with NULLs.
.SENTINEL <- "cast('9999-12-31' as date)"

# Build "least(coalesce(a, sentinel), coalesce(b, sentinel), ...)" expression.
.least_coalesce <- function(cols) {
  parts <- vapply(cols, function(c) sprintf("coalesce(%s, %s)", c, .SENTINEL), character(1))
  sprintf("least(%s)", paste(parts, collapse = ", "))
}

# The per-line stages, in build order. Each is written to <prefix>LOT<n>_<NAME>
# and its session view repointed, so the next stage reads a table.
#
# As temporary views this loop was the slowest part of a run. A view is a
# query, and Spark inlines its plan at every reference and re-runs it. These
# views sit on top of each other, so the cost compounds. lotN_base reads
# lotN_induction_meds three times and is itself read six times, and
# lotN_base_end reads lotN_base four more. Counted through the chain, the
# start-candidate query - four aggregates and a window function over every
# patient - is planned about a hundred times per line, and the whole structure
# is rebuilt for each of LOT2 to LOT5.
#
# Written to tables, each stage is planned once and every later reference is a
# scan. The SQL is the same. Only where its rows live has changed.
.LOTN_STAGES <- c("START_CANDIDATES", "START", "INDUCTION_MEDS", "BASE",
                  "SCT", "CONTAINS_MTX_REG", "BASE_END")

# lot3_base is a different table from lot2_base. A line's stages are named for
# that line, so nothing overwrites the line before it and each one is still
# readable after the run. lot_run_outputs() in build_lot.R builds the declared
# list from these two names.
lotn_table <- function(lot_num, stage) sprintf("LOT%d_%s", lot_num, stage)

# ---- Initialize lot_long from lot1_base_end (no LOT1 rewrite) ----

init_lot_long_from_lot1 <- function(con, meds, classes) {
  # Project LOT1's outputs into the long schema. LOT1_<X> is renamed LOT_<X>,
  # and the per-MED and per-CLASS flags become LOT_MED_<MED_ABBR> and
  # LOT_CLASS_<CLASS>.
  med_select <- paste(vapply(meds, function(m) {
    sc <- .lot_sanitize_col(m)
    sprintf("lbe.LOT1_MED_%s AS LOT_MED_%s", sc, sc)
  }, character(1)), collapse = ",\n      ")
  class_select <- paste(vapply(classes, function(cl) {
    sc <- .lot_sanitize_col(cl)
    sprintf("lbe.LOT1_CLASS_%s AS LOT_CLASS_%s", sc, sc)
  }, character(1)), collapse = ",\n      ")

  # Straight into the staging table, so the projection is planned once.
  materialize(con, "L25_init_lot_long", view = "lot_long", name = .LOT_LONG_STAGE, body = glue("
    SELECT
      lbe.PATID,
      cast(1 as int)                        AS LOT_NUM,
      lbe.LOT1_START_DT                     AS LOT_START_DT,
      cast('MED' as string)                 AS LOT_START_TYPE,
      lbe.LOT1_BASE_MEDS                    AS LOT_BASE_MEDS,
      lbe.LOT1_MED_CNT                      AS LOT_MED_CNT,
      lbe.LOT1_BASE_DISCON_DT               AS LOT_BASE_DISCON_DT,
      lbe.LOT1_BASE_1ST_ADD_MED_DT          AS LOT_BASE_1ST_ADD_MED_DT,
      lbe.LOT1_BASE_1ST_ADD_MED             AS LOT_BASE_1ST_ADD_MED,
      lbe.LOT1_BASE_END_DT                  AS LOT_BASE_END_DT,
      lbe.LOT1_BASE_END_REASON              AS LOT_BASE_END_REASON,
      lbe.LOT1_BASE_LENGTH                  AS LOT_BASE_LENGTH,
      cast(0 as int)                        AS LOT_ALLO_LOT_FLG,
      cast(0 as int)                        AS LOT_CART_LOT_FLG,
      lbe.contains_mtx_reg                  AS contains_mtx_reg,
      CASE
        WHEN p.ENDDATE_CE IS NOT NULL AND lbe.LOT1_BASE_END_DT > p.ENDDATE_CE
          THEN p.ENDDATE_CE
        ELSE lbe.LOT1_BASE_END_DT
      END                                   AS LOT_BASE_END_DT_CE_SENS,
      CASE
        WHEN p.ENDDATE_CE IS NOT NULL
         AND lbe.LOT1_BASE_END_DT > p.ENDDATE_CE
         AND p.ENDDATE_CE < p.ENDDATE
          THEN 'DISENROLLMENT'
        ELSE lbe.LOT1_BASE_END_REASON
      END                                   AS LOT_BASE_END_REASON_CE_SENS,
      -- LOT-scoped AUTO and SCT fields, clamped to
      -- [LOT1_START_DT, LOT1_BASE_END_DT]. SING and TAND are worked out again
      -- from the clamped in-LOT dates, so a DT_1 inside the line with a DT_2
      -- outside it lands on SING.
      CASE WHEN sct.LOT1_TX_AUTO_DT_1 IS NOT NULL
            AND sct.LOT1_TX_AUTO_DT_1 <= lbe.LOT1_BASE_END_DT
           THEN 1 ELSE 0 END                      AS LOT_TX_AUTO_FLG,
      CASE WHEN sct.LOT1_TX_AUTO_DT_2 IS NOT NULL
            AND sct.LOT1_TX_AUTO_DT_2 <= lbe.LOT1_BASE_END_DT
            AND coalesce(sct.LOT1_SCT_AUTO_TAND_FLG, 0) = 1
           THEN 1 ELSE 0 END                      AS LOT_TX_AUTO_TAND_FLG,
      CASE WHEN sct.LOT1_TX_AUTO_DT_1 IS NOT NULL
            AND sct.LOT1_TX_AUTO_DT_1 <= lbe.LOT1_BASE_END_DT
            AND NOT (
              sct.LOT1_TX_AUTO_DT_2 IS NOT NULL
              AND sct.LOT1_TX_AUTO_DT_2 <= lbe.LOT1_BASE_END_DT
              AND coalesce(sct.LOT1_SCT_AUTO_TAND_FLG, 0) = 1
            )
           THEN 1 ELSE 0 END                      AS LOT_TX_AUTO_SING_FLG,
      CASE WHEN sct.LOT1_TX_AUTO_DT_1 <= lbe.LOT1_BASE_END_DT
           THEN sct.LOT1_TX_AUTO_DT_1 END         AS LOT_TX_AUTO_DT_1,
      CASE WHEN sct.LOT1_TX_AUTO_DT_2 <= lbe.LOT1_BASE_END_DT
           THEN sct.LOT1_TX_AUTO_DT_2 END         AS LOT_TX_AUTO_DT_2,
      CASE
        WHEN sct.LOT1_TX_AUTO_DT_2 IS NOT NULL
         AND sct.LOT1_TX_AUTO_DT_2 <= lbe.LOT1_BASE_END_DT
         AND coalesce(sct.LOT1_SCT_AUTO_TAND_FLG, 0) = 1
          THEN sct.LOT1_TX_AUTO_DT_2
        WHEN sct.LOT1_TX_AUTO_DT_1 IS NOT NULL
         AND sct.LOT1_TX_AUTO_DT_1 <= lbe.LOT1_BASE_END_DT
          THEN sct.LOT1_TX_AUTO_DT_1
        ELSE NULL
      END                                         AS LOT_TX_AUTO_MAX_DT,
      {med_select},
      {class_select}
    FROM lot1_base_end lbe
    INNER JOIN lot_patient_input p ON lbe.PATID = p.PATID
    LEFT JOIN lot1_sct sct          ON lbe.PATID = sct.PATID
  "), qc = glue("SELECT count(*) AS n_lot1_rows FROM {lot_out(.LOT_LONG_STAGE)}"))
}

# ---- Build a single LOT_N (N >= 2) ----
# Strategy:
#   1. Per patient, work out the candidate trigger DATES after LOT_(N-1) ends:
#      d_MED, d_ALLO, d_CART and d_AUTO, the last unplanned only.
#   2. LOT_N_START_DT is the earliest of them. Date first; the type tie-break
#      applies only when several candidates share that date.
#   3. LOT_N's regimen, run-out and first add have the same shape as LOT1's,
#      with a 30-day induction window. Skipped for ALLO and CART single-day
#      lines.
#   4. LOT_N's end date and reason: the earliest qualifying event.
build_lot_n <- function(con, lot_num,
                        induction_window_days,
                        cart_consolidation_days,
                        sct_tandem_days,
                        allo_lot_span,
                        meds, classes,
                        apply_cart_induction_rule   = FALSE,
                        lot1_induction_window_days  = 60) {
  stopifnot(lot_num >= 2)
  prev <- lot_num - 1
  pfx  <- sprintf("L%02d", 30 + (lot_num - 2) * 6)  # step prefix per LOT iteration

  # The CAR-T induction rule reaches LOT2 and no further. At LOT2 the previous
  # line IS LOT1, so PREV_START_DT is LOT1's start and the window is LOT1's
  # own. At LOT3 and beyond the previous line is not LOT1 and the rule says
  # nothing.
  #
  # It is needed here as well as in the LOT1 end logic. Stop the infusion
  # ending LOT1 without stopping it starting LOT2 and the same two lines
  # remain, moved by a day - see R/cart_rule.R.
  cart_on <- isTRUE(apply_cart_induction_rule) && lot_num == 2L
  cart_excl <- cart_exclude_predicate(cart_on, "ac.TX_DT", "pe.PREV_START_DT",
                                      lot1_induction_window_days,
                                      "pe.PREV_END_DT")
  cart_note <- if (cart_on)
    "A CAR-T inside LOT1's induction window is part of LOT1 and starts nothing."
  else "No CAR-T exclusion at this line."

  # The window of the line auto_cand looks BACK at, in the MED-started case. At
  # LOT2 the previous line is always LOT1 - prev_end filters LOT_NUM = 1, and
  # LOT1 goes into lot_long as 'MED' - so the window is LOT1's own 60 days, not
  # the 30 that LOT2-5 use for themselves.
  #
  # It read 30 for every MED-started predecessor, LOT1 included. That left the
  # gate 30 days short of the window LOT1 really owns an AUTO over. A
  # transplant on days 30 to 59 was refused as a LOT2 start while LOT1 no
  # longer covered it. The SCT_AUTO_CONT branch in 06_lot1_end.R is the other
  # half of the same rule, and holds LOT1 open across exactly that range.
  prev_med_window <- if (lot_num == 2L) lot1_induction_window_days
                     else               induction_window_days


  # ---- Step N.1: compute candidate trigger dates ----
  materialize(con, paste0(pfx, "_lot", lot_num, "_start_candidates"),
              view = glue("lot{lot_num}_start_candidates"),
              name = lotn_table(lot_num, "START_CANDIDATES"), body = glue("
    WITH
    prev_end AS (
      SELECT ll.PATID,
             ll.LOT_BASE_END_DT  AS PREV_END_DT,
             ll.LOT_BASE_MEDS    AS PREV_BASE_MEDS,
             ll.LOT_START_DT     AS PREV_START_DT,
             ll.LOT_START_TYPE   AS PREV_START_TYPE,
             -- auto_cand needs this. An AUTO that ENDED the previous line has
             -- already been judged excess there, and must not be judged again
             -- here as a tandem partner.
             ll.LOT_BASE_END_REASON AS PREV_END_REASON,
             p.OBS_END_DT,
             p.DEATH_DT,
             p.ENDDATE,
             p.ENDDATE_CE
      FROM lot_long ll
      INNER JOIN lot_patient_input p ON ll.PATID = p.PATID
      WHERE ll.LOT_NUM = {prev}
        AND ll.LOT_BASE_END_DT IS NOT NULL
    ),
    -- The previous line's regimen and its permissible biosimilar substitutes.
    -- Neither starts LOT_N. A substitute continues the drug it replaces, and
    -- the drug itself was part of the previous regimen.
    --
    -- An explicit JOIN, not a correlated subquery. That would fail under
    -- spark.sql.crossJoin.enabled=false.
    prev_meds_array AS (
      SELECT pe.PATID, m AS MED_ABBR
      FROM prev_end pe
      LATERAL VIEW explode(split(coalesce(pe.PREV_BASE_MEDS, ''), ' ')) e AS m
      WHERE m <> ''
    ),
    -- SUBSTITUTE_ONLY = 1 means the drug is excluded only for being a
    -- permissible substitute. min() so a drug that is both a real previous
    -- regimen drug and somebody's substitute counts as the former.
    prev_meds_expanded AS (
      SELECT PATID, MED_ABBR, min(IS_SUB) AS SUBSTITUTE_ONLY
      FROM (
      SELECT pma.PATID, ps.substitute_med AS MED_ABBR, 1 AS IS_SUB
      FROM prev_meds_array pma
      INNER JOIN permissible_subs ps ON pma.MED_ABBR = ps.original_med
{prior_regimen_excl_sql()}
      )
      GROUP BY PATID, MED_ABBR
    ),
    -- d_MED: the earliest non-steroid MM drug strictly after PREV_END_DT,
    -- leaving out the previous line's regimen and its permissible biosimilar
    -- substitutes. A drug that WAS the previous regimen does NOT trigger
    -- LOT_N. The line it belongs to extends over it - see R/prior_regimen.R.
    map_restart AS ({map_restart_sql()}
    ),
    med_cand AS (
      SELECT pe.PATID, min(ms.MAP_START_DT) AS d_MED
      FROM prev_end pe
      INNER JOIN map_stacked ms ON pe.PATID = ms.PATID
      LEFT JOIN prev_meds_expanded pme
        ON pe.PATID = pme.PATID AND ms.MAP_MED_TYPE = pme.MED_ABBR
      LEFT JOIN map_restart mr
        ON mr.PATID = ms.PATID AND mr.MAP_MED_TYPE = ms.MAP_MED_TYPE
       AND mr.MAP_START_DT = ms.MAP_START_DT
      WHERE ms.MAP_START_DT > pe.PREV_END_DT
        AND ms.MAP_START_DT <= pe.OBS_END_DT
        AND ms.MAP_MED_CLASS <> 'STEROID'
        -- Released once discontinued. The exclusion holds a drug the patient
        -- is still taking inside the line that owns it. A drug returning after
        -- a confirmed gap is a restart, and opens a line like any other.
        AND (pme.MED_ABBR IS NULL
             OR (coalesce(mr.PREV_DISCON, 0) = 1
                 AND pme.SUBSTITUTE_ONLY = 0){melp_prior_regimen_exempt(cfg)})
      GROUP BY pe.PATID
    ),
    -- d_ALLO: earliest ALLO strictly after PREV_END_DT.
    allo_cand AS (
      SELECT pe.PATID, min(ac.TX_DT) AS d_ALLO
      FROM prev_end pe
      INNER JOIN tx_allo_cart_dates ac ON pe.PATID = ac.PATID
      WHERE ac.SCT_TYPE = 'ALLO'
        AND ac.TX_DT > pe.PREV_END_DT
        AND ac.TX_DT <= pe.OBS_END_DT
      GROUP BY pe.PATID
    ),
    -- d_CART: earliest CAR-T strictly after PREV_END_DT.
    -- {cart_note}
    cart_cand AS (
      SELECT pe.PATID, min(ac.TX_DT) AS d_CART
      FROM prev_end pe
      INNER JOIN tx_allo_cart_dates ac ON pe.PATID = ac.PATID
      WHERE ac.SCT_TYPE = 'CART'
        AND ac.TX_DT > pe.PREV_END_DT
        AND ac.TX_DT <= pe.OBS_END_DT{cart_excl}
      GROUP BY pe.PATID
    ),
    -- d_AUTO: earliest AUTO after PREV_END_DT that triggers a new LOT.
    -- The rule: an AUTO starts a new LOT UNLESS
    --   (i) it falls inside the previous LOT's window from PREV_START_DT
    --       ({prev_med_window}d MED or AUTO-started, 1d ALLO-started,
    --       {cart_consolidation_days}d CART-started), or
    --   (ii) it lands on or before sct_tandem_days (180d) after the AUTO right
    --        before it, which makes the pair a planned tandem. tx_auto_dates
    --        has already merged AUTO claims less than 60 days apart into one
    --        event, so by the time this CTE sees an AUTO only the 180-day
    --        upper bound is left to test.
    --
    -- The PREV_AUTO_DT IS NOT NULL guard from the earlier rule is gone. A
    -- first-ever AUTO CAN trigger a new LOT. That is LOT2-5 only; at LOT1 the
    -- first AUTO is still part of induction.
    autos_with_prev AS (
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
    auto_cand AS (
      SELECT pe.PATID, min(awp.TX_DT) AS d_AUTO
      FROM prev_end pe
      INNER JOIN autos_with_prev awp ON pe.PATID = awp.PATID
      WHERE awp.TX_DT > pe.PREV_END_DT
        AND awp.TX_DT <= pe.OBS_END_DT
        -- (i) outside the previous LOT's window. The MED and AUTO-started
        -- case is {prev_med_window} days here: LOT1's own window when the
        -- previous line is LOT1, and this line's otherwise.
        AND awp.TX_DT > date_add(
              pe.PREV_START_DT,
              CASE pe.PREV_START_TYPE
                WHEN 'SCT_ALLO' THEN 0
                WHEN 'CART'     THEN {cart_consolidation_days} - 1
                ELSE                 {prev_med_window} - 1
              END)
        -- (ii) not a planned tandem. tx_auto_dates has already grouped AUTO
        -- claims less than 60 days apart into one event, so only the
        -- sct_tandem_days upper bound is left to test here, as at LOT1.
        --
        -- The exception is the AUTO that ended the previous line. That one has
        -- already been ruled EXCESS by the previous line's own rule: LOT1
        -- allows a single AUTO and a tandem pair, and ends the line on the one
        -- beyond them. Testing it again as a tandem partner of the transplant
        -- before it leaves the event in no line. AUTO 1 in March, AUTO 2 in
        -- June as a tandem, AUTO 3 in November ends LOT1 on 31 October - and
        -- was then rejected here for being within 180 days of AUTO 2, so LOT2
        -- never opened. The line-ending SCT sits one day after the end date,
        -- which is exactly where that AUTO is.
        AND NOT (awp.PREV_AUTO_DT IS NOT NULL
                 AND datediff(awp.TX_DT, awp.PREV_AUTO_DT) <= {sct_tandem_days}
                 AND awp.N_BETWEEN = 0
                 AND NOT (pe.PREV_END_REASON = 'SCT_AUTO'
                          AND awp.TX_DT = date_add(pe.PREV_END_DT, 1)))
      GROUP BY pe.PATID
    )
    SELECT
      pe.PATID,
      pe.PREV_END_DT,
      pe.OBS_END_DT,
      pe.DEATH_DT,
      pe.ENDDATE,
      pe.ENDDATE_CE,
      m.d_MED, al.d_ALLO, c.d_CART, au.d_AUTO
    FROM prev_end pe
    LEFT JOIN med_cand  m  ON pe.PATID = m.PATID
    LEFT JOIN allo_cand al ON pe.PATID = al.PATID
    LEFT JOIN cart_cand c  ON pe.PATID = c.PATID
    LEFT JOIN auto_cand au ON pe.PATID = au.PATID
  "), qc = glue("SELECT count(*) AS n_with_prev_lot,
                        sum(CASE WHEN d_MED IS NOT NULL THEN 1 ELSE 0 END) AS n_med_cand,
                        sum(CASE WHEN d_ALLO IS NOT NULL THEN 1 ELSE 0 END) AS n_allo_cand,
                        sum(CASE WHEN d_CART IS NOT NULL THEN 1 ELSE 0 END) AS n_cart_cand,
                        sum(CASE WHEN d_AUTO IS NOT NULL THEN 1 ELSE 0 END) AS n_auto_cand
                 FROM lot{lot_num}_start_candidates"))

  # ---- Step N.2: pick LOT_N_START_DT and LOT_N_START_TYPE ----
  least_expr <- .least_coalesce(c("d_MED", "d_ALLO", "d_CART", "d_AUTO"))
  materialize(con, paste0(pfx, "_lot", lot_num, "_start"),
              view = glue("lot{lot_num}_start"),
              name = lotn_table(lot_num, "START"), body = glue("
    SELECT
      sc.PATID,
      sc.PREV_END_DT, sc.OBS_END_DT, sc.DEATH_DT, sc.ENDDATE, sc.ENDDATE_CE,
      sc.d_MED, sc.d_ALLO, sc.d_CART, sc.d_AUTO,
      {least_expr} AS LOT{lot_num}_START_DT,
      -- Same-day tie-break, highest first: SCT_ALLO > CART > SCT_AUTO > MED.
      CASE
        WHEN sc.d_ALLO IS NOT NULL AND sc.d_ALLO = {least_expr} THEN 'SCT_ALLO'
        WHEN sc.d_CART IS NOT NULL AND sc.d_CART = {least_expr} THEN 'CART'
        WHEN sc.d_AUTO IS NOT NULL AND sc.d_AUTO = {least_expr} THEN 'SCT_AUTO'
        WHEN sc.d_MED  IS NOT NULL AND sc.d_MED  = {least_expr} THEN 'MED'
      END AS LOT{lot_num}_START_TYPE
    FROM lot{lot_num}_start_candidates sc
    WHERE coalesce(sc.d_MED, sc.d_ALLO, sc.d_CART, sc.d_AUTO) IS NOT NULL
  "), qc = glue("SELECT LOT{lot_num}_START_TYPE, count(*) AS n
                 FROM lot{lot_num}_start
                 GROUP BY LOT{lot_num}_START_TYPE
                 ORDER BY LOT{lot_num}_START_TYPE"))

  # The last day this line's regimen may collect a drug on. Same rule as
  # lot1_regimen_cutoff in 04_lot1_base.R, and that comment says why it exists:
  # a line used to keep collecting drugs across a window it had already been cut
  # short in, so a drug first dispensed after the line ended was counted in its
  # regimen and started a later line too.
  #
  # ALLO and CAR-T here, where LOT1 has ALLO only. LOT1's induction exemption
  # keeps an in-window CAR-T inside the line and closes that door. LOT2-5 has no
  # such exemption, and a CAR-T ends the line the day before the infusion
  # whatever the regimen window says.
  #
  # A transplant that STARTED this line is not a cutoff on it. The exclusion
  # takes only transplants strictly after the start date.
  run_step(con, paste0(pfx, "_lot", lot_num, "_regimen_cutoff"), glue("
    CREATE OR REPLACE TEMPORARY VIEW lot{lot_num}_regimen_cutoff AS
    SELECT
      ls.PATID,
      ls.LOT{lot_num}_START_DT,
      ls.LOT{lot_num}_START_TYPE,
      min(CASE WHEN ac.SCT_TYPE IN ('ALLO', 'CART')
                AND ac.TX_DT > ls.LOT{lot_num}_START_DT
               THEN date_sub(ac.TX_DT, 1) END) AS REGIMEN_CUTOFF_DT
    FROM lot{lot_num}_start ls
    LEFT JOIN tx_allo_cart_dates ac ON ls.PATID = ac.PATID
    GROUP BY ls.PATID, ls.LOT{lot_num}_START_DT, ls.LOT{lot_num}_START_TYPE
  "), qc = glue("
    SELECT count(*) AS n_pats,
           sum(CASE WHEN REGIMEN_CUTOFF_DT IS NOT NULL THEN 1 ELSE 0 END) AS n_cut
    FROM lot{lot_num}_regimen_cutoff"))

  # ---- Step N.3: LOT_N regimen, discontinuation, first add ----
  # ALLO and CART starts have their own regimen rules, handled at the end-date
  # stage.
  med_flag_exprs <- paste(vapply(meds, function(m)
    glue("max(case when im.MED_ABBR = '{m}' then 1 else 0 end) as LOT{lot_num}_MED_{.lot_sanitize_col(m)}"),
    character(1)), collapse = ",\n        ")
  class_flag_exprs <- paste(vapply(classes, function(cl)
    glue("max(case when im.MED_CLASS = '{cl}' then 1 else 0 end) as LOT{lot_num}_CLASS_{.lot_sanitize_col(cl)}"),
    character(1)), collapse = ",\n        ")

  materialize(con, paste0(pfx, "_lot", lot_num, "_induction_meds"),
              view = glue("lot{lot_num}_induction_meds"),
              name = lotn_table(lot_num, "INDUCTION_MEDS"), body = glue("
    SELECT DISTINCT
      ms.PATID,
      ls.LOT{lot_num}_START_DT,
      ls.LOT{lot_num}_START_TYPE,
      ms.MAP_MED_TYPE  AS MED_ABBR,
      ms.MAP_MED_CLASS AS MED_CLASS
    FROM map_stacked ms
    INNER JOIN lot{lot_num}_regimen_cutoff ls ON ms.PATID = ls.PATID
    WHERE ms.MAP_START_DT >= ls.LOT{lot_num}_START_DT
      -- A CAR-T-started LOT uses the 45-day consolidation window. Every other
      -- start type uses the 30-day induction window. Either is cut short by a
      -- transplant that ended the line inside it.
      AND ms.MAP_START_DT <= least(
            date_add(
              ls.LOT{lot_num}_START_DT,
              CASE WHEN ls.LOT{lot_num}_START_TYPE = 'CART'
                   THEN {cart_consolidation_days - 1}
                   ELSE {induction_window_days - 1} END),
            coalesce(ls.REGIMEN_CUTOFF_DT, cast('9999-12-31' as date)))
      AND ms.MAP_MED_CLASS <> 'STEROID'
      -- A single-day ALLO LOT holds no MM therapy, so it gets no regimen
      -- rows.
      AND ls.LOT{lot_num}_START_TYPE <> 'SCT_ALLO'
  "), qc = glue("SELECT count(*) AS n_rows, count(DISTINCT PATID) AS n_pats
                 FROM lot{lot_num}_induction_meds"))

  materialize(con, paste0(pfx, "_lot", lot_num, "_base"),
              view = glue("lot{lot_num}_base"),
              name = lotn_table(lot_num, "BASE"), body = glue("
    WITH map_restart AS ({map_restart_sql()}
    ),
    -- SUBSTITUTE_ONLY = 1 means the drug is here only as a permissible
    -- biosimilar substitute. A substitution does not advance the LOT (§4.4).
    -- So a substitute never ends a line on its own, confirms a run-out or
    -- opens the next one, whatever gaps its own episodes carry. min() so a
    -- drug that is both a real regimen drug and somebody's substitute counts
    -- as the former and keeps the release.
    base_meds AS (
      SELECT PATID, MED_ABBR, min(IS_SUB) AS SUBSTITUTE_ONLY
      FROM (
        SELECT PATID, MED_ABBR, 0 AS IS_SUB FROM lot{lot_num}_induction_meds
        UNION ALL
        SELECT im.PATID, ps.substitute_med AS MED_ABBR, 1 AS IS_SUB
        FROM lot{lot_num}_induction_meds im
        INNER JOIN permissible_subs ps ON im.MED_ABBR = ps.original_med
      )
      GROUP BY PATID, MED_ABBR
    ),{melp_lotn_ctes(cfg, lot_num, induction_window_days, cart_consolidation_days, allo_lot_span)}
    -- Per drug, the end of ITS cover in this line: the FIRST episode flagged
    -- discontinued. A later episode of the same drug does NOT open the next
    -- line. It was in this line's regimen, so this line extends over it, and
    -- the chain stops at the first break a different drug causes.
    --
    -- max(MAP_END_DT) over every episode quietly undid that. Drug A dosed days
    -- 0-27, discontinued at 27 by the 90-day gap, restarting 117-144, gave a
    -- line-level runout of 144. The restart was swallowed, and LOT2 never
    -- opened, because its trigger has to fall strictly after the previous end.
    -- MAP_DISCON_FLG had been right all along and was read by nothing but a QC
    -- count.
    discon_per_med AS (
{discon_per_med_sql(glue('lot{lot_num}_regimen_cutoff'), glue('LOT{lot_num}_START_DT'), end_col = 'REGIMEN_CUTOFF_DT')}
    ),
    -- The regimen has run out when its LAST base agent has.
    discon_raw AS (
      SELECT PATID, max(MED_END_DT) AS RAW_DISCON_DT
      FROM discon_per_med
      GROUP BY PATID
    ),
    discon AS (
      SELECT
        ls.PATID,
        -- Where the regimen ran out, capped at OBS_END_DT so a days-supply
        -- tail past death or study end cannot extend the line. Still the
        -- run-out, not a discontinuation. The end statement below confirms it,
        -- where POST_RUNOUT_TRIGGER_FLG exists.
        CASE
          WHEN d.RAW_DISCON_DT IS NOT NULL AND d.RAW_DISCON_DT <= ls.OBS_END_DT
            THEN d.RAW_DISCON_DT
          ELSE NULL
        END AS LOT{lot_num}_BASE_RUNOUT_DT
      FROM lot{lot_num}_start ls
      LEFT JOIN discon_raw d ON ls.PATID = d.PATID
    ),
    med_summary AS (
      SELECT
        im.PATID,
        count(DISTINCT im.MED_ABBR) AS LOT{lot_num}_MED_CNT,
        concat_ws(' ', sort_array(collect_set(im.MED_ABBR))) AS LOT{lot_num}_BASE_MEDS,
        {med_flag_exprs},
        {class_flag_exprs}
      FROM lot{lot_num}_induction_meds im
      GROUP BY im.PATID
    ),
    first_add_candidates AS (
      SELECT ms.PATID, ms.MAP_START_DT, ms.MAP_MED_TYPE
      FROM map_stacked ms
      INNER JOIN lot{lot_num}_start ls ON ms.PATID = ls.PATID
      LEFT JOIN base_meds bm
        ON ms.PATID = bm.PATID AND ms.MAP_MED_TYPE = bm.MED_ABBR
      LEFT JOIN map_restart mr
        ON mr.PATID = ms.PATID AND mr.MAP_MED_TYPE = ms.MAP_MED_TYPE
       AND mr.MAP_START_DT = ms.MAP_START_DT
      LEFT JOIN discon d ON ls.PATID = d.PATID
      -- A regimen drug returning after a confirmed gap ends this line, like
      -- any other drug would. Without this the release is half a rule. The
      -- restart is kept out of the run-out and may START the next line, but
      -- while another regimen drug still holds this line open the restart falls
      -- inside it, cannot end it, and is then too early to open the next one.
      -- The treatment belongs to no line at all.
      WHERE (bm.MED_ABBR IS NULL
             OR (coalesce(mr.PREV_DISCON, 0) = 1 AND bm.SUBSTITUTE_ONLY = 0))
        AND ms.MAP_MED_CLASS <> 'STEROID'
        -- The lookback gate, per start type:
        --   MED / SCT_AUTO    -> any drug after the 30-day induction window
        --   CART              -> any drug after the 45-day consolidation window
        --   SCT_ALLO (extend) -> any drug strictly after LOT_START_DT. An ALLO
        --                        line has no induction window, so the very next
        --                        MM drug ends it.
        AND ms.MAP_START_DT > CASE
              WHEN ls.LOT{lot_num}_START_TYPE = 'SCT_ALLO'
                THEN ls.LOT{lot_num}_START_DT
              WHEN ls.LOT{lot_num}_START_TYPE = 'CART'
                THEN date_add(ls.LOT{lot_num}_START_DT, {cart_consolidation_days - 1})
              ELSE date_add(ls.LOT{lot_num}_START_DT, {induction_window_days - 1})
            END
        AND ms.MAP_START_DT <= coalesce(d.LOT{lot_num}_BASE_RUNOUT_DT, ls.OBS_END_DT)
        -- A single_day ALLO LOT ends on the ALLO date itself, so an add-med
        -- cannot apply.
        AND NOT (ls.LOT{lot_num}_START_TYPE = 'SCT_ALLO' AND {if (allo_lot_span == 'single_day') 1L else 0L} = 1){melp_suppress_predicate(cfg)}
      {melp_inject_arm(cfg, glue('lot{lot_num}_start'), glue('LOT{lot_num}_START_DT'),
                       glue('lot{lot_num}_start.OBS_END_DT'), melp_allo_guard(lot_num, allo_lot_span))}
    ),
    first_add_pick AS (
      SELECT PATID, LOT{lot_num}_BASE_1ST_ADD_MED_DT, LOT{lot_num}_BASE_1ST_ADD_MED
      FROM (
        SELECT
          PATID,
          date_sub(MAP_START_DT, 1) AS LOT{lot_num}_BASE_1ST_ADD_MED_DT,
          MAP_MED_TYPE              AS LOT{lot_num}_BASE_1ST_ADD_MED,
          row_number() OVER (PARTITION BY PATID ORDER BY MAP_START_DT, rand(42)) AS rn
        FROM first_add_candidates
      ) ranked
      WHERE rn = 1
    )
    SELECT
      ls.PATID,
      ls.LOT{lot_num}_START_DT,
      ls.LOT{lot_num}_START_TYPE,
      ls.OBS_END_DT,
      ls.DEATH_DT,
      ls.ENDDATE,
      ls.ENDDATE_CE,
      coalesce(ms.LOT{lot_num}_MED_CNT, 0)   AS LOT{lot_num}_MED_CNT,
      coalesce(ms.LOT{lot_num}_BASE_MEDS, '') AS LOT{lot_num}_BASE_MEDS,
      d.LOT{lot_num}_BASE_RUNOUT_DT,
      fa.LOT{lot_num}_BASE_1ST_ADD_MED_DT,
      fa.LOT{lot_num}_BASE_1ST_ADD_MED,
      -- The per-MED and per-CLASS flags, matching LOT1. NULL becomes 0 for a
      -- single-day ALLO or CART LOT, which has no induction rows.
      {paste(vapply(meds, function(m) sprintf('coalesce(ms.LOT%d_MED_%s, 0) AS LOT%d_MED_%s',
                                              lot_num, .lot_sanitize_col(m), lot_num, .lot_sanitize_col(m)),
                    character(1)), collapse = ', ')},
      {paste(vapply(classes, function(cl) sprintf('coalesce(ms.LOT%d_CLASS_%s, 0) AS LOT%d_CLASS_%s',
                                                  lot_num, .lot_sanitize_col(cl), lot_num, .lot_sanitize_col(cl)),
                    character(1)), collapse = ', ')}
    FROM lot{lot_num}_start ls
    LEFT JOIN med_summary    ms ON ls.PATID = ms.PATID
    LEFT JOIN discon         d  ON ls.PATID = d.PATID
    LEFT JOIN first_add_pick fa ON ls.PATID = fa.PATID
  "), qc = glue("SELECT count(*) AS n_pats,
                        avg(LOT{lot_num}_MED_CNT) AS avg_meds,
                        sum(CASE WHEN LOT{lot_num}_BASE_RUNOUT_DT IS NOT NULL THEN 1 ELSE 0 END) AS n_runout,
                        sum(CASE WHEN LOT{lot_num}_BASE_1ST_ADD_MED_DT IS NOT NULL THEN 1 ELSE 0 END) AS n_add_med
                 FROM lot{lot_num}_base"))

  # ---- Step N.4: LOT_N SCT events scoped to this LOT ----
  # The AUTO, ALLO and CART events inside [LOT_N_START_DT, OBS_END_DT].
  materialize(con, paste0(pfx, "_lot", lot_num, "_sct"),
              view = glue("lot{lot_num}_sct"),
              name = lotn_table(lot_num, "SCT"), body = glue("
    WITH lb AS (
      -- LOT_WINDOW_DAYS is the window that decides which AUTOs are in-LOT:
      -- 30d MED or AUTO-started, 1d ALLO-started, 45d CART-started. An
      -- AUTO_DT_1 outside it is not in-LOT and becomes the ENDING_AUTO_DT that
      -- closes the LOT instead.
      SELECT PATID, LOT{lot_num}_START_DT, LOT{lot_num}_START_TYPE, OBS_END_DT,
        CASE LOT{lot_num}_START_TYPE
          WHEN 'SCT_ALLO' THEN 1
          WHEN 'CART'     THEN {cart_consolidation_days}
          ELSE                 {induction_window_days}
        END AS LOT_WINDOW_DAYS
      FROM lot{lot_num}_base
    ),
    -- At LOT2 and beyond an unplanned AUTO can BE the start, so
    -- LOT_N_START_DT = AUTO_DT. The AUTOs inside the line after that start are
    -- scoped here. The end rules for an excess AUTO are LOT1's tandem rule.
    --
    -- For the end rules the SCT scans must IGNORE the start-date SCT itself on
    -- an ALLO- or CART-started LOT. With TX_DT >= LOT_START_DT here,
    -- earliest_non_auto, first_allo and first_cart all latch onto the start
    -- event and hide any later SCT that should end LOT_N. AUTO uses >= because
    -- an SCT_AUTO-started LOT has to capture its start AUTO as AUTO_DT_1 -
    -- within the line, not an end trigger.
    earliest_non_auto AS (
      SELECT ac.PATID, min(ac.TX_DT) AS FIRST_NON_AUTO_DT
      FROM tx_allo_cart_dates ac
      INNER JOIN lb l ON ac.PATID = l.PATID
      WHERE ac.SCT_TYPE IN ('ALLO', 'CART')
        AND ac.TX_DT > l.LOT{lot_num}_START_DT
        AND ac.TX_DT <= l.OBS_END_DT
      GROUP BY ac.PATID
    ),
    auto_in_lot AS (
      SELECT a.PATID, a.TX_DT,
             row_number() OVER (PARTITION BY a.PATID ORDER BY a.TX_DT) AS LOT_SEQ
      FROM tx_auto_dates a
      INNER JOIN lb l ON a.PATID = l.PATID
      LEFT JOIN earliest_non_auto ena ON a.PATID = ena.PATID
      WHERE a.TX_DT >= l.LOT{lot_num}_START_DT
        AND a.TX_DT <= l.OBS_END_DT
        AND (ena.FIRST_NON_AUTO_DT IS NULL OR a.TX_DT < ena.FIRST_NON_AUTO_DT)
    ),
    auto_pivot AS (
      SELECT PATID,
        max(CASE WHEN LOT_SEQ = 1 THEN TX_DT END) AS AUTO_DT_1,
        max(CASE WHEN LOT_SEQ = 2 THEN TX_DT END) AS AUTO_DT_2,
        max(CASE WHEN LOT_SEQ = 3 THEN TX_DT END) AS AUTO_DT_3
      FROM auto_in_lot
      GROUP BY PATID
    ),
    first_allo AS (
      SELECT ac.PATID, min(ac.TX_DT) AS ALLO_DT
      FROM tx_allo_cart_dates ac
      INNER JOIN lb l ON ac.PATID = l.PATID
      WHERE ac.SCT_TYPE = 'ALLO'
        AND ac.TX_DT > l.LOT{lot_num}_START_DT
        AND ac.TX_DT <= l.OBS_END_DT
      GROUP BY ac.PATID
    ),
    first_cart AS (
      SELECT ac.PATID, min(ac.TX_DT) AS CART_DT
      FROM tx_allo_cart_dates ac
      INNER JOIN lb l ON ac.PATID = l.PATID
      WHERE ac.SCT_TYPE = 'CART'
        AND ac.TX_DT > l.LOT{lot_num}_START_DT
        AND ac.TX_DT <= l.OBS_END_DT
      GROUP BY ac.PATID
    ),
    -- A tandem is a tandem only if nothing happens between the two
    -- transplants. Same rule as 05b_lot1_sct.R, and that comment says why: it
    -- is what makes it safe for the hold date to follow a tandem partner past
    -- this line's own window.
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
    allo_between AS (
      SELECT ap.PATID,
        sum(CASE WHEN ac.TX_DT >= ap.AUTO_DT_1 AND ac.TX_DT <= ap.AUTO_DT_2 THEN 1 ELSE 0 END) AS n_allo_between
      FROM auto_pivot ap
      LEFT JOIN tx_allo_cart_dates ac
        ON ap.PATID = ac.PATID AND ac.SCT_TYPE = 'ALLO'
      WHERE ap.AUTO_DT_2 IS NOT NULL
      GROUP BY ap.PATID
    )
    SELECT
      l.PATID,
      -- AUTO_DT_1 is in-LOT only if it falls inside LOT_WINDOW_DAYS from
      -- LOT_START_DT. Outside that window it is not in-LOT - the TX_AUTO_*
      -- fields and the TAND and SING flags go NULL or 0 - and it becomes the
      -- ENDING_AUTO_DT that closes LOT N. AUTO_DT_2 is in-LOT only when
      -- AUTO_DT_1 is in-LOT and AUTO_DT_2 is a valid tandem, at or within
      -- sct_tandem_days after AUTO_DT_1.
      CASE WHEN ap.AUTO_DT_1 IS NOT NULL
            AND datediff(ap.AUTO_DT_1, l.LOT{lot_num}_START_DT) < l.LOT_WINDOW_DAYS
           THEN ap.AUTO_DT_1 END AS LOT{lot_num}_TX_AUTO_DT_1,
      CASE WHEN ap.AUTO_DT_1 IS NOT NULL
            AND datediff(ap.AUTO_DT_1, l.LOT{lot_num}_START_DT) < l.LOT_WINDOW_DAYS
            AND ap.AUTO_DT_2 IS NOT NULL
            AND datediff(ap.AUTO_DT_2, ap.AUTO_DT_1) <= {sct_tandem_days}
            AND coalesce(ab.n_allo_between, 0) = 0
         AND coalesce(ti.n_between, 0) = 0
           THEN ap.AUTO_DT_2 END AS LOT{lot_num}_TX_AUTO_DT_2,
      CASE
        WHEN ap.AUTO_DT_1 IS NOT NULL
         AND datediff(ap.AUTO_DT_1, l.LOT{lot_num}_START_DT) < l.LOT_WINDOW_DAYS
         AND ap.AUTO_DT_2 IS NOT NULL
         AND datediff(ap.AUTO_DT_2, ap.AUTO_DT_1) <= {sct_tandem_days}
         AND coalesce(ab.n_allo_between, 0) = 0
         AND coalesce(ti.n_between, 0) = 0
        THEN 1 ELSE 0
      END AS LOT{lot_num}_SCT_AUTO_TAND_FLG,
      CASE
        WHEN ap.AUTO_DT_1 IS NOT NULL
         AND datediff(ap.AUTO_DT_1, l.LOT{lot_num}_START_DT) < l.LOT_WINDOW_DAYS
         AND NOT (ap.AUTO_DT_2 IS NOT NULL
                  AND datediff(ap.AUTO_DT_2, ap.AUTO_DT_1) <= {sct_tandem_days}
                  AND coalesce(ab.n_allo_between, 0) = 0
         AND coalesce(ti.n_between, 0) = 0)
        THEN 1 ELSE 0
      END AS LOT{lot_num}_SCT_AUTO_SING_FLG,
      CASE
        WHEN ap.AUTO_DT_1 IS NULL THEN NULL
        -- AUTO_DT_1 outside the window is the ENDING_AUTO_DT, and triggers
        -- LOT N+1.
        WHEN datediff(ap.AUTO_DT_1, l.LOT{lot_num}_START_DT) >= l.LOT_WINDOW_DAYS
          THEN ap.AUTO_DT_1
        -- A valid in-LOT tandem: AUTO_DT_3 ends LOT N.
        WHEN ap.AUTO_DT_2 IS NOT NULL
         AND datediff(ap.AUTO_DT_2, ap.AUTO_DT_1) <= {sct_tandem_days}
         AND coalesce(ab.n_allo_between, 0) = 0
         AND coalesce(ti.n_between, 0) = 0
        THEN ap.AUTO_DT_3
        -- A single in-LOT AUTO: AUTO_DT_2 ends LOT N, where it exists and is
        -- not a tandem.
        ELSE ap.AUTO_DT_2
      END AS ENDING_AUTO_DT,
      fa.ALLO_DT AS FIRST_ALLO_DT,
      fc.CART_DT AS FIRST_CART_DT,
      CASE WHEN ap.AUTO_DT_1 IS NOT NULL
            AND datediff(ap.AUTO_DT_1, l.LOT{lot_num}_START_DT) < l.LOT_WINDOW_DAYS
           THEN 1 ELSE 0 END AS LOT{lot_num}_TX_AUTO_FLG,
      -- LOTN_TX_AUTO_MAX_DT: the second tandem AUTO where the pair is a valid
      -- tandem, otherwise AUTO_DT_1. In-LOT only.
      CASE
        WHEN ap.AUTO_DT_1 IS NOT NULL
         AND datediff(ap.AUTO_DT_1, l.LOT{lot_num}_START_DT) < l.LOT_WINDOW_DAYS
         AND ap.AUTO_DT_2 IS NOT NULL
         AND datediff(ap.AUTO_DT_2, ap.AUTO_DT_1) <= {sct_tandem_days}
         AND coalesce(ab.n_allo_between, 0) = 0
         AND coalesce(ti.n_between, 0) = 0
        THEN ap.AUTO_DT_2
        WHEN ap.AUTO_DT_1 IS NOT NULL
         AND datediff(ap.AUTO_DT_1, l.LOT{lot_num}_START_DT) < l.LOT_WINDOW_DAYS
        THEN ap.AUTO_DT_1
        ELSE NULL
      END AS LOT{lot_num}_TX_AUTO_MAX_DT,
      -- LOT{lot_num}_AUTO_HOLD_DT: the last AUTO this line owns that falls
      -- inside the line's OWN window. The twin of LOT1_AUTO_HOLD_DT in
      -- 05b_lot1_sct.R, and it holds the line open the same way - see the
      -- SCT_AUTO_CONT branch below.
      --
      -- Not LOT{lot_num}_TX_AUTO_MAX_DT above, and that is on purpose. It
      -- reads as if it were the same thing and it is not: its tandem arm
      -- bounds AUTO_DT_2 by sct_tandem_days from AUTO_DT_1 and never by
      -- LOT_WINDOW_DAYS. A tandem partner 180 days after an AUTO on the last
      -- day of a 30-day window sits 209 days past the line start and still
      -- passes. That is harmless while the column is only reported and clamped
      -- afterwards. It is not harmless once it decides an end date: the line
      -- would swallow an added medication months later, and the line that drug
      -- should have started would never open.
      CASE
        WHEN ap.AUTO_DT_2 IS NOT NULL
         AND datediff(ap.AUTO_DT_2, ap.AUTO_DT_1) <= {sct_tandem_days}
         AND coalesce(ab.n_allo_between, 0) = 0
         AND coalesce(ti.n_between, 0) = 0
         AND datediff(ap.AUTO_DT_1, l.LOT{lot_num}_START_DT) < l.LOT_WINDOW_DAYS
        THEN ap.AUTO_DT_2
        WHEN ap.AUTO_DT_1 IS NOT NULL
         AND datediff(ap.AUTO_DT_1, l.LOT{lot_num}_START_DT) < l.LOT_WINDOW_DAYS
        THEN ap.AUTO_DT_1
        ELSE NULL
      END AS LOT{lot_num}_AUTO_HOLD_DT
    FROM lb l
    LEFT JOIN auto_pivot   ap ON l.PATID = ap.PATID
    LEFT JOIN allo_between ab ON l.PATID = ab.PATID
    LEFT JOIN tandem_interrupt ti ON l.PATID = ti.PATID
    LEFT JOIN first_allo   fa ON l.PATID = fa.PATID
    LEFT JOIN first_cart   fc ON l.PATID = fc.PATID
  "), qc = glue("SELECT count(*) AS n_pats,
                        sum(LOT{lot_num}_TX_AUTO_FLG) AS n_with_auto,
                        sum(LOT{lot_num}_SCT_AUTO_TAND_FLG) AS n_tandem,
                        sum(CASE WHEN FIRST_ALLO_DT IS NOT NULL THEN 1 ELSE 0 END) AS n_with_allo,
                        sum(CASE WHEN FIRST_CART_DT IS NOT NULL THEN 1 ELSE 0 END) AS n_with_cart
                 FROM lot{lot_num}_sct"))

  # ---- Step N.5: contains_mtx_reg ----
  materialize(con, paste0(pfx, "_lot", lot_num, "_contains_mtx_reg"),
              view = glue("lot{lot_num}_contains_mtx_reg"),
              name = lotn_table(lot_num, "CONTAINS_MTX_REG"), body = glue("
    WITH valid_maint_regimens AS (
      SELECT DISTINCT im.PATID, im.MED_ABBR AS REGIMEN_KEY
      FROM lot{lot_num}_induction_meds im
      INNER JOIN mma_rollup ru ON im.MED_ABBR = ru.CL_MED_ABBR
      WHERE ru.MONOMAINTENANCE = 1
      UNION
      SELECT DISTINCT
        im.PATID,
        concat_ws(' ', sort_array(array(im.MED_ABBR, im2.MED_ABBR))) AS REGIMEN_KEY
      FROM lot{lot_num}_induction_meds im
      INNER JOIN mma_rollup ru ON im.MED_ABBR = ru.CL_MED_ABBR
      INNER JOIN lot{lot_num}_induction_meds im2
        ON im.PATID = im2.PATID
        AND im.MED_ABBR <> im2.MED_ABBR
        AND array_contains(
          transform(split(coalesce(ru.DUALMAINTENANCEWITH, ''), ','), v -> upper(trim(v))),
          im2.MED_ABBR)
    ),
    anchored AS (
      SELECT DISTINCT vmr.PATID
      FROM valid_maint_regimens vmr
      INNER JOIN lot{lot_num}_induction_meds im ON vmr.PATID = im.PATID
      WHERE NOT array_contains(split(vmr.REGIMEN_KEY, ' '), im.MED_ABBR)
    )
    SELECT
      p.PATID,
      CASE WHEN a.PATID IS NOT NULL THEN 1 ELSE 0 END AS contains_mtx_reg
    FROM (SELECT DISTINCT PATID FROM lot{lot_num}_induction_meds) p
    LEFT JOIN anchored a ON p.PATID = a.PATID
  "), qc = glue("SELECT contains_mtx_reg, count(*) AS n
                 FROM lot{lot_num}_contains_mtx_reg GROUP BY contains_mtx_reg"))

  # ---- Step N.6: LOT_N base end ----
  # A single-day ALLO ends on ALLO_DT. A CART line takes every drug within
  # cart_consolidation_days as part of LOT_N. Everything else follows LOT1's
  # end-reason rules, in the same order.
  #
  # allo_lot_span 'single_day' fixes start = end = ALLO_DT with reason
  # SCT_ALLO. 'extend_to_next' lets the LOT run to the next event and take the
  # natural end reason: MED_ADD, DISCONTINUATION, DEATH or STUDY_END.
  allo_single_day <- (allo_lot_span == "single_day")

  materialize(con, paste0(pfx, "_lot", lot_num, "_base_end"),
              view = glue("lot{lot_num}_base_end"),
              name = lotn_table(lot_num, "BASE_END"), body = glue("
    WITH
    -- The post-runout guard. Is there a LOT_(N+1)-qualifying trigger strictly
    -- after LOT_BASE_RUNOUT_DT and on or before OBS_END_DT? It stops DEATH
    -- taking a line from DISCONTINUATION where the patient ran out, then
    -- started new therapy or had an SCT, and only then died. Without it, the
    -- post-runout therapy is quietly swallowed by the DEATH branch.
    --
    -- The post_runout CTEs MIRROR LOT_(N+1)'s own start-candidate rules
    -- (med_cand / auto_cand), so the guard fires exactly when LOT_(N+1) would
    -- have a valid start trigger:
    --   - MED: any non-steroid MM drug outside this LOT's regimen and its
    --     permissible substitutes, matching med_cand.
    --   - AUTO: any AUTO outside LOT N's window from LOT_START_DT - 30d MED or
    --     AUTO-started, 1d ALLO-started, 45d CART-started - and not within
    --     sct_tandem_days (180d) of the AUTO right before it, which would make
    --     the pair a planned tandem. This mirrors auto_cand exactly, with
    --     PREV_END_DT swapped for LOT_BASE_RUNOUT_DT.
    --   - ALLO/CART: any after the run-out. No window check; both always
    --     trigger a new LOT.
    --
    -- What cannot confirm this line's run-out is what cannot start the next
    -- line: this line's own regimen drugs and their permissible substitutes.
    -- med_cand excludes both, so accepting one here would confirm a
    -- discontinuation on an event no next line is allowed to open on.
    post_runout_excluded_meds AS (
      SELECT PATID, MED_ABBR, min(IS_SUB) AS SUBSTITUTE_ONLY
      FROM (
        SELECT im.PATID, im.MED_ABBR, 0 AS IS_SUB
        FROM lot{lot_num}_induction_meds im
        UNION ALL
        SELECT im.PATID, ps.substitute_med AS MED_ABBR, 1 AS IS_SUB
        FROM lot{lot_num}_induction_meds im
        INNER JOIN permissible_subs ps ON im.MED_ABBR = ps.original_med
      )
      GROUP BY PATID, MED_ABBR
    ),
    map_restart AS ({map_restart_sql()}
    ),
    post_runout_med AS (
      SELECT DISTINCT ms.PATID
      FROM map_stacked ms
      INNER JOIN lot{lot_num}_base lb ON ms.PATID = lb.PATID
      LEFT JOIN post_runout_excluded_meds prem
        ON ms.PATID = prem.PATID AND ms.MAP_MED_TYPE = prem.MED_ABBR
      LEFT JOIN map_restart mr
        ON mr.PATID = ms.PATID AND mr.MAP_MED_TYPE = ms.MAP_MED_TYPE
       AND mr.MAP_START_DT = ms.MAP_START_DT
      WHERE lb.LOT{lot_num}_BASE_RUNOUT_DT IS NOT NULL
        AND ms.MAP_START_DT > lb.LOT{lot_num}_BASE_RUNOUT_DT
        AND ms.MAP_START_DT <= lb.OBS_END_DT
        AND ms.MAP_MED_CLASS <> 'STEROID'
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
      SELECT DISTINCT lb.PATID
      FROM lot{lot_num}_base lb
      INNER JOIN post_runout_autos awp ON lb.PATID = awp.PATID
      WHERE lb.LOT{lot_num}_BASE_RUNOUT_DT IS NOT NULL
        AND awp.TX_DT > lb.LOT{lot_num}_BASE_RUNOUT_DT
        AND awp.TX_DT <= lb.OBS_END_DT
        AND awp.TX_DT > date_add(
              lb.LOT{lot_num}_START_DT,
              CASE lb.LOT{lot_num}_START_TYPE
                WHEN 'SCT_ALLO' THEN 0
                WHEN 'CART'     THEN {cart_consolidation_days} - 1
                ELSE                 {induction_window_days} - 1
              END)
        AND NOT (awp.PREV_AUTO_DT IS NOT NULL
                 AND datediff(awp.TX_DT, awp.PREV_AUTO_DT) <= {sct_tandem_days}
                 AND awp.N_BETWEEN = 0)
    ),
    post_runout_trigger AS (
      SELECT lb.PATID,
        CASE
          WHEN lb.LOT{lot_num}_BASE_RUNOUT_DT IS NULL THEN 0
          WHEN prm.PATID IS NOT NULL THEN 1
          WHEN sct.FIRST_ALLO_DT IS NOT NULL AND sct.FIRST_ALLO_DT > lb.LOT{lot_num}_BASE_RUNOUT_DT THEN 1
          WHEN sct.FIRST_CART_DT IS NOT NULL AND sct.FIRST_CART_DT > lb.LOT{lot_num}_BASE_RUNOUT_DT THEN 1
          WHEN pra.PATID IS NOT NULL THEN 1
          ELSE 0
        END AS POST_RUNOUT_TRIGGER_FLG
      FROM lot{lot_num}_base lb
      LEFT JOIN lot{lot_num}_sct sct ON lb.PATID = sct.PATID
      LEFT JOIN post_runout_med prm ON lb.PATID = prm.PATID
      LEFT JOIN post_runout_auto pra ON lb.PATID = pra.PATID
    ),
    end_candidates AS (
      SELECT
        lb.*,
        coalesce(prt.POST_RUNOUT_TRIGGER_FLG, 0) AS POST_RUNOUT_TRIGGER_FLG,
        -- The run-out becomes a discontinuation here. Either thing confirms
        -- it: {cfg$lot_discon_confirm_days} days of observation after it, or a
        -- LOT-start trigger. Mirrors 06_lot1_end.R.
        CASE
          WHEN lb.LOT{lot_num}_BASE_RUNOUT_DT IS NOT NULL
           AND (coalesce(prt.POST_RUNOUT_TRIGGER_FLG, 0) = 1
                OR datediff(lb.OBS_END_DT, lb.LOT{lot_num}_BASE_RUNOUT_DT)
                     >= {cfg$lot_discon_confirm_days})
            THEN lb.LOT{lot_num}_BASE_RUNOUT_DT
          ELSE NULL
        END AS LOT{lot_num}_BASE_DISCON_DT,
        sct.LOT{lot_num}_TX_AUTO_DT_1, sct.LOT{lot_num}_TX_AUTO_DT_2,
        sct.LOT{lot_num}_SCT_AUTO_TAND_FLG, sct.LOT{lot_num}_SCT_AUTO_SING_FLG,
        sct.ENDING_AUTO_DT, sct.FIRST_ALLO_DT, sct.FIRST_CART_DT,
        sct.LOT{lot_num}_TX_AUTO_FLG,
        sct.LOT{lot_num}_TX_AUTO_MAX_DT,
        sct.LOT{lot_num}_AUTO_HOLD_DT,
        coalesce(cmr.contains_mtx_reg, 0) AS contains_mtx_reg,
        -- LOT_TX_ENDDATE and REASON: the earliest LOT-ending SCT event, minus
        -- a day. The SCT that STARTED LOT_N must not trigger its own end. On
        -- an SCT_AUTO, SCT_ALLO or CART start that event sits on
        -- LOT_N_START_DT.
        CASE
          WHEN coalesce(
                 CASE WHEN sct.ENDING_AUTO_DT > lb.LOT{lot_num}_START_DT THEN sct.ENDING_AUTO_DT END,
                 CASE WHEN sct.FIRST_ALLO_DT  > lb.LOT{lot_num}_START_DT THEN sct.FIRST_ALLO_DT  END,
                 CASE WHEN sct.FIRST_CART_DT  > lb.LOT{lot_num}_START_DT THEN sct.FIRST_CART_DT  END
               ) IS NOT NULL
          THEN date_sub(
            least(
              coalesce(CASE WHEN sct.ENDING_AUTO_DT > lb.LOT{lot_num}_START_DT THEN sct.ENDING_AUTO_DT END, {.SENTINEL}),
              coalesce(CASE WHEN sct.FIRST_ALLO_DT  > lb.LOT{lot_num}_START_DT THEN sct.FIRST_ALLO_DT  END, {.SENTINEL}),
              coalesce(CASE WHEN sct.FIRST_CART_DT  > lb.LOT{lot_num}_START_DT THEN sct.FIRST_CART_DT  END, {.SENTINEL})
            ), 1)
          ELSE NULL
        END AS LOT_TX_ENDDATE,
        -- Same-day SCT end priority, inherited from LOT1:
        -- SCT_ALLO > SCT_CART > SCT_AUTO. ALLO takes an ALLO==CART or
        -- ALLO==AUTO tie, CART takes CART==AUTO, and otherwise it is AUTO.
        CASE
          WHEN coalesce(
                 CASE WHEN sct.ENDING_AUTO_DT > lb.LOT{lot_num}_START_DT THEN sct.ENDING_AUTO_DT END,
                 CASE WHEN sct.FIRST_ALLO_DT  > lb.LOT{lot_num}_START_DT THEN sct.FIRST_ALLO_DT  END,
                 CASE WHEN sct.FIRST_CART_DT  > lb.LOT{lot_num}_START_DT THEN sct.FIRST_CART_DT  END
               ) IS NULL THEN NULL
          WHEN coalesce(CASE WHEN sct.FIRST_ALLO_DT > lb.LOT{lot_num}_START_DT THEN sct.FIRST_ALLO_DT END, {.SENTINEL})
               <= coalesce(CASE WHEN sct.FIRST_CART_DT  > lb.LOT{lot_num}_START_DT THEN sct.FIRST_CART_DT  END, {.SENTINEL})
           AND coalesce(CASE WHEN sct.FIRST_ALLO_DT > lb.LOT{lot_num}_START_DT THEN sct.FIRST_ALLO_DT END, {.SENTINEL})
               <= coalesce(CASE WHEN sct.ENDING_AUTO_DT > lb.LOT{lot_num}_START_DT THEN sct.ENDING_AUTO_DT END, {.SENTINEL})
          THEN 2
          WHEN coalesce(CASE WHEN sct.FIRST_CART_DT > lb.LOT{lot_num}_START_DT THEN sct.FIRST_CART_DT END, {.SENTINEL})
               <= coalesce(CASE WHEN sct.ENDING_AUTO_DT > lb.LOT{lot_num}_START_DT THEN sct.ENDING_AUTO_DT END, {.SENTINEL})
          THEN 3
          ELSE 1
        END AS LOT_TX_ENDDATE_REASON,
        -- CART_INIT, inherited from LOT1: a MED_ADD followed by a CART within
        -- cart_consolidation_days.
        CASE
          WHEN sct.FIRST_CART_DT IS NOT NULL
           AND lb.LOT{lot_num}_BASE_1ST_ADD_MED_DT IS NOT NULL
           AND datediff(sct.FIRST_CART_DT, date_add(lb.LOT{lot_num}_BASE_1ST_ADD_MED_DT, 1))
               BETWEEN 0 AND {cart_consolidation_days}
          THEN 1 ELSE 0
        END AS CART_INIT_FLG
      FROM lot{lot_num}_base lb
      LEFT JOIN lot{lot_num}_sct              sct ON lb.PATID = sct.PATID
      LEFT JOIN lot{lot_num}_contains_mtx_reg cmr ON lb.PATID = cmr.PATID
      LEFT JOIN post_runout_trigger           prt ON lb.PATID = prt.PATID
    ),
    -- The end this line would have had before an in-window AUTO is weighed:
    -- the date cascade below, minus its SCT_AUTO_CONT branch. Its own CTE
    -- because LOT{lot_num}_BASE_DISCON_DT is derived in end_candidates, and
    -- SQL cannot read a select-list alias from the same select list. Same
    -- shape as end_natural in 06_lot1_end.R.
    end_natural AS (
      SELECT
        ec.*,
        CASE
          WHEN ec.LOT{lot_num}_START_TYPE = 'SCT_ALLO' AND {if (allo_single_day) 1L else 0L} = 1
            THEN ec.LOT{lot_num}_START_DT
          WHEN ec.LOT{lot_num}_START_TYPE = 'CART' AND ec.LOT{lot_num}_MED_CNT = 0
            THEN ec.LOT{lot_num}_START_DT
          WHEN ec.LOT_TX_ENDDATE IS NOT NULL
           AND NOT (ec.CART_INIT_FLG = 1 AND ec.LOT_TX_ENDDATE_REASON = 3)
           AND (ec.LOT{lot_num}_BASE_1ST_ADD_MED_DT IS NULL
                OR (ec.CART_INIT_FLG = 1 AND ec.LOT_TX_ENDDATE <= date_sub(ec.FIRST_CART_DT, 1))
                OR (ec.CART_INIT_FLG = 0 AND ec.LOT_TX_ENDDATE <= ec.LOT{lot_num}_BASE_1ST_ADD_MED_DT))
           AND (ec.LOT{lot_num}_BASE_DISCON_DT IS NULL OR ec.LOT_TX_ENDDATE <= ec.LOT{lot_num}_BASE_DISCON_DT)
          THEN ec.LOT_TX_ENDDATE
          WHEN ec.CART_INIT_FLG = 1
           AND (ec.LOT{lot_num}_BASE_DISCON_DT IS NULL OR date_sub(ec.FIRST_CART_DT, 1) <= ec.LOT{lot_num}_BASE_DISCON_DT)
          THEN date_sub(ec.FIRST_CART_DT, 1)
          WHEN ec.LOT{lot_num}_BASE_1ST_ADD_MED_DT IS NOT NULL
           AND ec.CART_INIT_FLG = 0
           AND (ec.LOT{lot_num}_BASE_DISCON_DT IS NULL OR ec.LOT{lot_num}_BASE_1ST_ADD_MED_DT <= ec.LOT{lot_num}_BASE_DISCON_DT)
          THEN ec.LOT{lot_num}_BASE_1ST_ADD_MED_DT
          WHEN ec.DEATH_DT IS NOT NULL AND ec.DEATH_DT <= ec.OBS_END_DT
           AND ec.POST_RUNOUT_TRIGGER_FLG = 0 THEN ec.DEATH_DT
          WHEN ec.LOT{lot_num}_BASE_DISCON_DT IS NOT NULL THEN ec.LOT{lot_num}_BASE_DISCON_DT
          ELSE ec.OBS_END_DT
        END AS LOT{lot_num}_NATURAL_END_DT
      FROM end_candidates ec
    )
    SELECT
      ec.*,
      -- The two special start types: a single-day ALLO, and a CAR-T with no
      -- consolidation.
      --   ALLO single_day: the LOT spans only the ALLO date itself.
      --   CAR-T with no consolidation drugs: the LOT spans only FIRST_CART_DT.
      --   ALLO extend_to_next: falls through to the natural end reasons.
      CASE
        -- SCT_AUTO_CONT. An AUTO inside this line's own window belongs to it,
        -- so the line cannot be closed before the transplant. It ends ON the
        -- AUTO, not the day before. 06_lot1_end.R has the full reasoning; this
        -- is the same rule at LOT2-5.
        --
        -- It is tested ahead of the two special start types on purpose. A
        -- CAR-T-started line with no consolidation drugs ends on its own start
        -- date, so every AUTO in its {cart_consolidation_days}-day window falls
        -- after the end. That made it the one case where an orphaned
        -- transplant was certain rather than possible.
        --
        -- It reads LOT{lot_num}_AUTO_HOLD_DT, not the
        -- LOT{lot_num}_TX_AUTO_MAX_DT beside it, which is bounded by the window
        -- on one arm only. The two names look alike and mean different things.
        -- lot{lot_num}_sct says why.
        WHEN ec.LOT{lot_num}_AUTO_HOLD_DT IS NOT NULL
         AND ec.LOT{lot_num}_AUTO_HOLD_DT > ec.LOT{lot_num}_NATURAL_END_DT
         AND (ec.DEATH_DT IS NULL OR ec.LOT{lot_num}_AUTO_HOLD_DT < ec.DEATH_DT)
        THEN 'SCT_AUTO_CONT'
        WHEN ec.LOT{lot_num}_START_TYPE = 'SCT_ALLO' AND {if (allo_single_day) 1L else 0L} = 1
          THEN 'SCT_ALLO'
        WHEN ec.LOT{lot_num}_START_TYPE = 'CART' AND ec.LOT{lot_num}_MED_CNT = 0
          THEN 'SCT_CART'
        WHEN ec.LOT_TX_ENDDATE IS NOT NULL
         AND NOT (ec.CART_INIT_FLG = 1 AND ec.LOT_TX_ENDDATE_REASON = 3)
         AND (ec.LOT{lot_num}_BASE_1ST_ADD_MED_DT IS NULL
              OR (ec.CART_INIT_FLG = 1 AND ec.LOT_TX_ENDDATE <= date_sub(ec.FIRST_CART_DT, 1))
              OR (ec.CART_INIT_FLG = 0 AND ec.LOT_TX_ENDDATE <= ec.LOT{lot_num}_BASE_1ST_ADD_MED_DT))
         AND (ec.LOT{lot_num}_BASE_DISCON_DT IS NULL OR ec.LOT_TX_ENDDATE <= ec.LOT{lot_num}_BASE_DISCON_DT)
        THEN CASE ec.LOT_TX_ENDDATE_REASON
               WHEN 1 THEN 'SCT_AUTO'
               WHEN 2 THEN 'SCT_ALLO'
               WHEN 3 THEN 'SCT_CART'
               ELSE 'SCT'
             END
        WHEN ec.CART_INIT_FLG = 1
         AND (ec.LOT{lot_num}_BASE_DISCON_DT IS NULL OR date_sub(ec.FIRST_CART_DT, 1) <= ec.LOT{lot_num}_BASE_DISCON_DT)
        THEN 'CART_INIT'
        WHEN ec.LOT{lot_num}_BASE_1ST_ADD_MED_DT IS NOT NULL
         AND ec.CART_INIT_FLG = 0
         AND (ec.LOT{lot_num}_BASE_DISCON_DT IS NULL OR ec.LOT{lot_num}_BASE_1ST_ADD_MED_DT <= ec.LOT{lot_num}_BASE_DISCON_DT)
        THEN 'MED_ADD'
        -- DEATH outranks DISCONTINUATION. A patient who runs out and then
        -- dies gets REASON = DEATH, and the run-out date is still recorded in
        -- LOT{lot_num}_BASE_DISCON_DT. That only applies when no qualifying
        -- LOT-start trigger sits in (DISCON_DT, OBS_END_DT]. If the patient ran
        -- out, then started new therapy or had an SCT before dying, the run-out
        -- is the line's real end and the new event opens LOT N+1.
        WHEN ec.DEATH_DT IS NOT NULL AND ec.DEATH_DT <= ec.OBS_END_DT
         AND ec.POST_RUNOUT_TRIGGER_FLG = 0 THEN 'DEATH'
        WHEN ec.LOT{lot_num}_BASE_DISCON_DT IS NOT NULL THEN 'DISCONTINUATION'
        ELSE 'STUDY_END'
      END AS LOT{lot_num}_BASE_END_REASON,
      CASE
        WHEN ec.LOT{lot_num}_AUTO_HOLD_DT IS NOT NULL
         AND ec.LOT{lot_num}_AUTO_HOLD_DT > ec.LOT{lot_num}_NATURAL_END_DT
         AND (ec.DEATH_DT IS NULL OR ec.LOT{lot_num}_AUTO_HOLD_DT < ec.DEATH_DT)
        THEN ec.LOT{lot_num}_AUTO_HOLD_DT
        ELSE ec.LOT{lot_num}_NATURAL_END_DT
      END AS LOT{lot_num}_BASE_END_DT
    FROM end_natural ec
  "), qc = glue("SELECT LOT{lot_num}_BASE_END_REASON, count(*) AS n
                 FROM lot{lot_num}_base_end
                 GROUP BY LOT{lot_num}_BASE_END_REASON
                 ORDER BY LOT{lot_num}_BASE_END_REASON"))

  # ---- Step N.7: append to lot_long ----
  # The sensitivity columns cap LOT_BASE_END_DT_CE_SENS at ENDDATE_CE. The
  # reason becomes DISENROLLMENT only where ELIGEND is the cap that binds.
  med_insert <- paste(vapply(meds, function(m) {
    sc <- .lot_sanitize_col(m)
    sprintf("lbe.LOT%d_MED_%s AS LOT_MED_%s", lot_num, sc, sc)
  }, character(1)), collapse = ",\n      ")
  class_insert <- paste(vapply(classes, function(cl) {
    sc <- .lot_sanitize_col(cl)
    sprintf("lbe.LOT%d_CLASS_%s AS LOT_CLASS_%s", lot_num, sc, sc)
  }, character(1)), collapse = ",\n      ")

  run_step(con, paste0(pfx, "_lot", lot_num, "_append_long"), glue("
    INSERT INTO {lot_out(.LOT_LONG_STAGE)}
    SELECT
      lbe.PATID,
      cast({lot_num} as int)               AS LOT_NUM,
      lbe.LOT{lot_num}_START_DT            AS LOT_START_DT,
      lbe.LOT{lot_num}_START_TYPE          AS LOT_START_TYPE,
      lbe.LOT{lot_num}_BASE_MEDS           AS LOT_BASE_MEDS,
      lbe.LOT{lot_num}_MED_CNT             AS LOT_MED_CNT,
      lbe.LOT{lot_num}_BASE_DISCON_DT      AS LOT_BASE_DISCON_DT,
      lbe.LOT{lot_num}_BASE_1ST_ADD_MED_DT AS LOT_BASE_1ST_ADD_MED_DT,
      lbe.LOT{lot_num}_BASE_1ST_ADD_MED    AS LOT_BASE_1ST_ADD_MED,
      lbe.LOT{lot_num}_BASE_END_DT         AS LOT_BASE_END_DT,
      lbe.LOT{lot_num}_BASE_END_REASON     AS LOT_BASE_END_REASON,
      CASE
        WHEN lbe.LOT{lot_num}_BASE_END_REASON = 'DISCONTINUATION'
          THEN datediff(lbe.LOT{lot_num}_BASE_DISCON_DT, lbe.LOT{lot_num}_START_DT) + 1
        ELSE datediff(lbe.LOT{lot_num}_BASE_END_DT, lbe.LOT{lot_num}_START_DT) + 1
      END                                  AS LOT_BASE_LENGTH,
      CASE WHEN lbe.LOT{lot_num}_START_TYPE = 'SCT_ALLO' THEN 1 ELSE 0 END AS LOT_ALLO_LOT_FLG,
      CASE WHEN lbe.LOT{lot_num}_START_TYPE = 'CART'     THEN 1 ELSE 0 END AS LOT_CART_LOT_FLG,
      lbe.contains_mtx_reg,
      CASE
        WHEN lbe.ENDDATE_CE IS NOT NULL AND lbe.LOT{lot_num}_BASE_END_DT > lbe.ENDDATE_CE
          THEN lbe.ENDDATE_CE
        ELSE lbe.LOT{lot_num}_BASE_END_DT
      END AS LOT_BASE_END_DT_CE_SENS,
      CASE
        WHEN lbe.ENDDATE_CE IS NOT NULL
         AND lbe.LOT{lot_num}_BASE_END_DT > lbe.ENDDATE_CE
         AND lbe.ENDDATE_CE < lbe.ENDDATE
          THEN 'DISENROLLMENT'
        ELSE lbe.LOT{lot_num}_BASE_END_REASON
      END AS LOT_BASE_END_REASON_CE_SENS,
      -- LOT-scoped AUTO flags, clamped to [LOT_START_DT, LOT_BASE_END_DT].
      -- lotN_sct collects through OBS_END_DT, so AUTOs after the LOT ended are
      -- filtered out here. SING and TAND are worked out again from the clamped
      -- in-LOT dates, so a DT_1 inside the line with a DT_2 outside it lands on
      -- SING rather than on neither flag.
      CASE WHEN lbe.LOT{lot_num}_TX_AUTO_DT_1 IS NOT NULL
            AND lbe.LOT{lot_num}_TX_AUTO_DT_1 <= lbe.LOT{lot_num}_BASE_END_DT
           THEN 1 ELSE 0 END                          AS LOT_TX_AUTO_FLG,
      -- TAND only if both are in-LOT, AUTO_DT_2 is within sct_tandem_days of
      -- AUTO_DT_1, and the pre-clamp tandem rules already accepted it - no ALLO
      -- between, and the rest, from lotN_sct.
      CASE WHEN lbe.LOT{lot_num}_TX_AUTO_DT_2 IS NOT NULL
            AND lbe.LOT{lot_num}_TX_AUTO_DT_2 <= lbe.LOT{lot_num}_BASE_END_DT
            AND coalesce(lbe.LOT{lot_num}_SCT_AUTO_TAND_FLG, 0) = 1
           THEN 1 ELSE 0 END                          AS LOT_TX_AUTO_TAND_FLG,
      -- SING means an in-LOT DT_1 that is not a TAND.
      CASE WHEN lbe.LOT{lot_num}_TX_AUTO_DT_1 IS NOT NULL
            AND lbe.LOT{lot_num}_TX_AUTO_DT_1 <= lbe.LOT{lot_num}_BASE_END_DT
            AND NOT (
              lbe.LOT{lot_num}_TX_AUTO_DT_2 IS NOT NULL
              AND lbe.LOT{lot_num}_TX_AUTO_DT_2 <= lbe.LOT{lot_num}_BASE_END_DT
              AND coalesce(lbe.LOT{lot_num}_SCT_AUTO_TAND_FLG, 0) = 1
            )
           THEN 1 ELSE 0 END                          AS LOT_TX_AUTO_SING_FLG,
      CASE WHEN lbe.LOT{lot_num}_TX_AUTO_DT_1 <= lbe.LOT{lot_num}_BASE_END_DT
           THEN lbe.LOT{lot_num}_TX_AUTO_DT_1 END     AS LOT_TX_AUTO_DT_1,
      CASE WHEN lbe.LOT{lot_num}_TX_AUTO_DT_2 <= lbe.LOT{lot_num}_BASE_END_DT
           THEN lbe.LOT{lot_num}_TX_AUTO_DT_2 END     AS LOT_TX_AUTO_DT_2,
      -- MAX_DT is the second in-LOT AUTO where the pair is a valid in-LOT
      -- tandem, otherwise the first.
      CASE
        WHEN lbe.LOT{lot_num}_TX_AUTO_DT_2 IS NOT NULL
         AND lbe.LOT{lot_num}_TX_AUTO_DT_2 <= lbe.LOT{lot_num}_BASE_END_DT
         AND coalesce(lbe.LOT{lot_num}_SCT_AUTO_TAND_FLG, 0) = 1
          THEN lbe.LOT{lot_num}_TX_AUTO_DT_2
        WHEN lbe.LOT{lot_num}_TX_AUTO_DT_1 IS NOT NULL
         AND lbe.LOT{lot_num}_TX_AUTO_DT_1 <= lbe.LOT{lot_num}_BASE_END_DT
          THEN lbe.LOT{lot_num}_TX_AUTO_DT_1
        ELSE NULL
      END                                             AS LOT_TX_AUTO_MAX_DT,
      {med_insert},
      {class_insert}
    FROM lot{lot_num}_base_end lbe
  "), qc = glue("SELECT count(*) AS n_appended FROM {lot_out(.LOT_LONG_STAGE)} WHERE LOT_NUM = {lot_num}"))

  # Refresh the lot_long view so it picks up the rows just inserted.
  db_exec(con, glue("CREATE OR REPLACE TEMPORARY VIEW lot_long AS SELECT * FROM {lot_out(.LOT_LONG_STAGE)}"))
}

# ---- Top-level driver ----

build_lot2_5 <- function(con,
                        induction_window_days   = 30,
                        cart_consolidation_days = 45,
                        sct_tandem_days         = 180,
                        allo_lot_span           = "single_day",
                        max_lot                 = 5,
                        # LOT1's window, not this file's. The CAR-T rule is
                        # about LOT1's 60 days. Off by default, so a caller that
                        # does not ask for it gets the algorithm unchanged.
                        apply_cart_induction_rule  = FALSE,
                        lot1_induction_window_days = 60) {
  stopifnot(allo_lot_span %in% c("single_day", "extend_to_next"))
  stopifnot(max_lot >= 2L && max_lot <= 9L)

  log_msg("Building LOT_LONG (LOT1..LOT", max_lot, ")")
  log_msg("  induction_window_days   = ", induction_window_days)
  log_msg("  cart_consolidation_days = ", cart_consolidation_days)
  log_msg("  sct_tandem_days         = ", sct_tandem_days)
  log_msg("  allo_lot_span           = ", allo_lot_span)
  log_msg("  cart induction rule     = ",
          if (isTRUE(apply_cart_induction_rule))
            paste0("on (LOT1 window ", lot1_induction_window_days, "d)") else "off")

  # Read the med and class universes off the rollup, so the flag columns match
  # LOT1's output exactly. STEROID is excluded, because LOT1 uses the same
  # filter and no LOT1_MED_<DEXA> or <PRED> column will exist.
  #
  # ORDER BY names the alias - MED_ABBR or MED_CLASS - not the underlying
  # column. After SELECT DISTINCT col AS alias the projection carries only the
  # alias, and a strict Spark or Databricks runtime rejects ORDER BY on the
  # underlying name with UNRESOLVED_COLUMN. LOT1 (S00) avoids this by not
  # aliasing.
  meds <- db_q(con, "
    SELECT DISTINCT CL_MED_ABBR AS MED_ABBR
    FROM mma_rollup
    WHERE upper(coalesce(CL_MED_CLASS, '')) <> 'STEROID'
    ORDER BY MED_ABBR
  ")$MED_ABBR
  classes <- db_q(con, "
    SELECT DISTINCT CL_MED_CLASS AS MED_CLASS
    FROM mma_rollup
    WHERE upper(coalesce(CL_MED_CLASS, '')) <> 'STEROID'
      AND CL_MED_CLASS IS NOT NULL
    ORDER BY MED_CLASS
  ")$MED_CLASS

  init_lot_long_from_lot1(con, meds = meds, classes = classes)

  # Which lines were really built. The loop stops at the first line with no
  # patients to roll forward, so a run need not reach max_lot, and the per-line
  # stage tables exist only for the lines it did reach. Recorded so the run can
  # say what it wrote rather than what it was configured to write.
  built <- integer(0)
  for (n in 2:max_lot) {
    log_msg("--- LOT", n, " ---")
    nrows_before <- db_q(con, glue("SELECT count(*) AS n FROM {lot_out(.LOT_LONG_STAGE)} WHERE LOT_NUM = {n - 1}"))$n
    if (nrows_before == 0L) {
      log_msg("  No LOT", n - 1, " rows; nothing to roll forward. Stopping.")
      break
    }
    build_lot_n(con, lot_num = n,
                induction_window_days   = induction_window_days,
                cart_consolidation_days = cart_consolidation_days,
                sct_tandem_days         = sct_tandem_days,
                allo_lot_span           = allo_lot_span,
                meds = meds, classes = classes,
                apply_cart_induction_rule  = apply_cart_induction_rule,
                lot1_induction_window_days = lot1_induction_window_days)
    built <- c(built, n)
  }
  options(lot_lines_built = built)

  # Publish in one step. Only now is the staging table promoted to the final
  # LOT_LONG. Every LOT - 1 to max_lot, or up to the natural break above -
  # appended without error, so this is a complete build. Had any append failed,
  # build_lot_n() would have stop()ped before reaching here, leaving
  # LOT_LONG_STAGE partial and the previous LOT_LONG untouched. So the
  # orchestrator never mistakes a partial build for a finished one.
  run_step(con, "L99_publish_lot_long",
    glue("CREATE OR REPLACE TABLE {lot_out('LOT_LONG')} AS SELECT * FROM {lot_out(.LOT_LONG_STAGE)}"),
    qc = glue("SELECT count(*) AS n_rows FROM {lot_out('LOT_LONG')}"))
  db_exec(con, glue("DROP TABLE IF EXISTS {lot_out(.LOT_LONG_STAGE)}"))
  db_exec(con, glue("CREATE OR REPLACE TEMPORARY VIEW lot_long AS SELECT * FROM {lot_out('LOT_LONG')}"))

  # The final summary, read off the published LOT_LONG.
  summary <- db_q(con, glue("
    SELECT LOT_NUM, LOT_START_TYPE, LOT_BASE_END_REASON, count(*) AS n
    FROM {lot_out('LOT_LONG')}
    GROUP BY LOT_NUM, LOT_START_TYPE, LOT_BASE_END_REASON
    ORDER BY LOT_NUM, LOT_START_TYPE, LOT_BASE_END_REASON
  "))
  log_msg("LOT_LONG summary (LOT_NUM x START_TYPE x END_REASON):")
  print(summary)

  # The per-line stage tables stay behind. They are each line's working - its
  # start candidates, its regimen, its transplants, its end reason - and reading
  # one answers why a patient's LOT3 ended where it did, with no re-run.
  # LOT_LONG_STAGE is the exception and was dropped above. It is a half-built
  # LOT_LONG, and leaving it would put a table beside the real one that looks
  # like it and is not.
  if (length(built))
    log_msg("Per-line stage tables written: LOT", paste(built, collapse = "/LOT"),
            " x {", paste(.LOTN_STAGES, collapse = ", "), "}")

  invisible(lot_out("LOT_LONG"))
}
