#!/usr/bin/env Rscript
# ============================================================
# lot2_5_base.R - LOT 2 through LOT 5 base period builder
#
# Implements the LOT 2-5 spec (lot2to5_spec_DRAFT_apr30.xlsx).
# Standalone module: does NOT modify lot_program.R or any LOT1 module.
#
# Assumes lot_program.R has already produced these views/tables in the
# same connection / work schema:
#   - lot_patient_input    (patient cohort + OBS_END_DT, ENDDATE_CE, etc.)
#   - map_stacked          (medication-available periods per agent)
#   - permissible_subs     (biosimilar substitution table)
#   - mma_rollup           (MED_ABBR -> maintenance flags)
#   - tx_auto_dates        (per-patient AUTO SCT dates, post-grouping)
#   - tx_allo_cart_dates   (per-patient ALLO/CART dates)
#   - lot1_base_end        (LOT1 row with LOT1_BASE_END_DT, REASON, etc.)
#
# Produces a long-format table lot_long with one row per (PATID, LOT_NUM):
#   PATID, LOT_NUM, LOT_START_DT, LOT_START_TYPE,
#   LOT_BASE_MEDS, LOT_MED_CNT, LOT_BASE_DISCON_DT,
#   LOT_BASE_1ST_ADD_MED_DT, LOT_BASE_1ST_ADD_MED,
#   LOT_BASE_END_DT, LOT_BASE_END_REASON, LOT_BASE_LENGTH,
#   LOT_ALLO_LOT_FLG, LOT_CART_LOT_FLG, contains_mtx_reg,
#   LOT_BASE_END_DT_CE_SENS, LOT_BASE_END_REASON_CE_SENS
#
# Key parameters (defaults reflect Apr 22 study-team decisions):
#   induction_window_days   = 30   (LOT1 uses 60)
#   (no LOT-level discontinuation buffer; per-drug 90d rule lives in map_discon_gap_days)
#   cart_consolidation_days = 45   (Apr 22; supersedes 30d protocol text)
#   sct_tandem_days         = 180  (>180d AUTO is unplanned)
#   allo_lot_span           = "single_day"  (Q2 resolved) - ALLO LOT spans only ALLO_DT
#   max_lot                 = 5
#
# Spec cross-references:
#   - 3.LOT2_5_BASE   tab in spec workbook
#   - 4.LOT2_5_BASE_END
#   - 9.Decision_Flow (date-driven; tie-break only on identical dates)
# ============================================================

# ============================================================
# Helpers
# ============================================================

# Normalize a MED_ABBR to a column-safe token (matches LOT1 convention).
.lot_sanitize_col <- function(x) gsub("[^A-Za-z0-9]+", "_", toupper(x))

# 9999-12-31 sentinel for SQL least() with NULLs.
.SENTINEL <- "cast('9999-12-31' as date)"

# Build "least(coalesce(a, sentinel), coalesce(b, sentinel), ...)" expression.
.least_coalesce <- function(cols) {
  parts <- vapply(cols, function(c) sprintf("coalesce(%s, %s)", c, .SENTINEL), character(1))
  sprintf("least(%s)", paste(parts, collapse = ", "))
}

# ============================================================
# Initialize lot_long from lot1_base_end (no LOT1 rewrite)
# ============================================================

init_lot_long_from_lot1 <- function(con, meds, classes) {
  # Project LOT1 outputs into the long-format schema. LOT1 column names
  # are renamed LOT1_<X> -> LOT_<X>; per-MED and per-CLASS dynamic flags
  # become LOT_MED_<MED_ABBR> / LOT_CLASS_<CLASS>.
  med_select <- paste(vapply(meds, function(m) {
    sc <- .lot_sanitize_col(m)
    sprintf("lbe.LOT1_MED_%s AS LOT_MED_%s", sc, sc)
  }, character(1)), collapse = ",\n      ")
  class_select <- paste(vapply(classes, function(cl) {
    sc <- .lot_sanitize_col(cl)
    sprintf("lbe.LOT1_CLASS_%s AS LOT_CLASS_%s", sc, sc)
  }, character(1)), collapse = ",\n      ")

  run_step(con, "L25_init_lot_long", glue("
    CREATE OR REPLACE TEMPORARY VIEW lot_long_v AS
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
      -- LOT-scoped AUTO/SCT fields, clamped to [LOT1_START_DT, LOT1_BASE_END_DT]
      -- per workbook Q7 draft. SING/TAND classification is RECOMPUTED from
      -- the clamped in-LOT dates so a within-LOT DT_1 with an outside-LOT
      -- DT_2 lands on SING.
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
  "), qc = "SELECT count(*) AS n_lot1_rows FROM lot_long_v")

  # Materialize so iterative LOT N builders can self-join cheaply.
  run_step(con, "L26_materialize_lot_long",
    glue("CREATE OR REPLACE TABLE {wrk('LOT_LONG')} AS SELECT * FROM lot_long_v"),
    qc = glue("SELECT count(*) AS n_rows FROM {wrk('LOT_LONG')}"))
  db_exec(con, glue("CREATE OR REPLACE TEMPORARY VIEW lot_long AS SELECT * FROM {wrk('LOT_LONG')}"))
}

# ============================================================
# Build a single LOT_N (N >= 2)
# ============================================================
# Strategy (per Decision_Flow tab):
#   1. For each patient, compute candidate trigger DATES after LOT_(N-1) end:
#        d_MED, d_ALLO, d_CART, d_AUTO (unplanned only)
#   2. LOT_N_START_DT = min of candidates (date-first; tie-break by type
#      only when multiple candidates equal the min).
#   3. LOT_N regimen / discontinuation / first-add: same shape as LOT1
#      with 30-day induction window. Skipped for ALLO/CART singleton LOTs.
#   4. LOT_N end date and reason: earliest qualifying event.
build_lot_n <- function(con, lot_num,
                        induction_window_days,
                        cart_consolidation_days,
                        sct_tandem_days,
                        allo_lot_span,
                        meds, classes) {
  stopifnot(lot_num >= 2)
  prev <- lot_num - 1
  pfx  <- sprintf("L%02d", 30 + (lot_num - 2) * 6)  # step prefix per LOT iteration

  # ---- Step N.1: compute candidate trigger dates ----
  run_step(con, paste0(pfx, "_lot", lot_num, "_start_candidates"), glue("
    CREATE OR REPLACE TEMPORARY VIEW lot{lot_num}_start_candidates AS
    WITH
    prev_end AS (
      SELECT ll.PATID,
             ll.LOT_BASE_END_DT  AS PREV_END_DT,
             ll.LOT_BASE_MEDS    AS PREV_BASE_MEDS,
             ll.LOT_START_DT     AS PREV_START_DT,
             ll.LOT_START_TYPE   AS PREV_START_TYPE,
             p.OBS_END_DT,
             p.DEATH_DT,
             p.ENDDATE,
             p.ENDDATE_CE
      FROM lot_long ll
      INNER JOIN lot_patient_input p ON ll.PATID = p.PATID
      WHERE ll.LOT_NUM = {prev}
        AND ll.LOT_BASE_END_DT IS NOT NULL
    ),
    -- Permissible biosimilar substitutes of prior-LOT drugs.
    -- Spec: a biosimilar of a prior-LOT drug does NOT trigger LOT_N.
    -- A same-drug restart (the original prior-LOT drug itself) DOES trigger;
    -- the prior LOT ended by run-out and a fresh fill is a new line.
    -- Note: explicit JOIN avoids the implicit cross join + correlated
    -- subquery pattern, which would fail under spark.sql.crossJoin.enabled=false.
    prev_meds_array AS (
      SELECT pe.PATID, m AS MED_ABBR
      FROM prev_end pe
      LATERAL VIEW explode(split(coalesce(pe.PREV_BASE_MEDS, ''), ' ')) e AS m
      WHERE m <> ''
    ),
    prev_meds_expanded AS (
      SELECT pma.PATID, ps.substitute_med AS MED_ABBR
      FROM prev_meds_array pma
      INNER JOIN permissible_subs ps ON pma.MED_ABBR = ps.original_med
    ),
    -- d_MED: earliest non-steroid MM agent strictly after PREV_END_DT,
    -- excluding permissible biosimilar subs of prior-LOT drugs.
    -- Same-drug restarts are allowed and DO trigger LOT_N.
    med_cand AS (
      SELECT pe.PATID, min(ms.MAP_START_DT) AS d_MED
      FROM prev_end pe
      INNER JOIN map_stacked ms ON pe.PATID = ms.PATID
      LEFT JOIN prev_meds_expanded pme
        ON pe.PATID = pme.PATID AND ms.MAP_MED_TYPE = pme.MED_ABBR
      WHERE ms.MAP_START_DT > pe.PREV_END_DT
        AND ms.MAP_START_DT <= pe.OBS_END_DT
        AND ms.MAP_MED_CLASS <> 'STEROID'
        AND pme.MED_ABBR IS NULL
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
    cart_cand AS (
      SELECT pe.PATID, min(ac.TX_DT) AS d_CART
      FROM prev_end pe
      INNER JOIN tx_allo_cart_dates ac ON pe.PATID = ac.PATID
      WHERE ac.SCT_TYPE = 'CART'
        AND ac.TX_DT > pe.PREV_END_DT
        AND ac.TX_DT <= pe.OBS_END_DT
      GROUP BY pe.PATID
    ),
    -- d_AUTO (Q16, 06-May): earliest AUTO after PREV_END_DT that triggers a new LOT.
    -- Rule: AUTO starts a new LOT UNLESS
    --   (i) it falls inside the prior LOT's applicable window from PREV_START_DT
    --       (30d MED/AUTO-started, 1d ALLO-started, 45d CART-started), or
    --   (ii) the AUTO is on/before sct_tandem_days (180d) after the IMMEDIATELY
    --        prior AUTO (planned tandem). Upstream tx_auto_dates already merges
    --        AUTO claims < 60 d apart into a single event (sct_auto_gap_days),
    --        so by the time this CTE sees an AUTO, the < 60 d case has already
    --        been handled - tandem classification only needs the 180d upper bound.
    -- The PREV_AUTO_DT IS NOT NULL guard from the prior rule is dropped:
    -- first-ever AUTOs CAN trigger a new LOT (LOT2-5 only; LOT1 retains the
    -- protocol convention that the first AUTO is part of induction).
    autos_with_prev AS (
      SELECT a.PATID, a.TX_DT,
             lag(a.TX_DT) OVER (PARTITION BY a.PATID ORDER BY a.TX_DT) AS PREV_AUTO_DT
      FROM tx_auto_dates a
    ),
    auto_cand AS (
      SELECT pe.PATID, min(awp.TX_DT) AS d_AUTO
      FROM prev_end pe
      INNER JOIN autos_with_prev awp ON pe.PATID = awp.PATID
      WHERE awp.TX_DT > pe.PREV_END_DT
        AND awp.TX_DT <= pe.OBS_END_DT
        -- (i) outside prior LOT's applicable window
        AND awp.TX_DT > date_add(
              pe.PREV_START_DT,
              CASE pe.PREV_START_TYPE
                WHEN 'SCT_ALLO' THEN 0
                WHEN 'CART'     THEN {cart_consolidation_days} - 1
                ELSE                 {induction_window_days} - 1
              END)
        -- (ii) not a planned tandem. tx_auto_dates upstream already groups
        -- AUTO claims < 60 d apart into a single event, so tandem classification
        -- only needs the <= sct_tandem_days (180d) upper bound here (matches
        -- LOT1; Q9 resolved 13-May).
        AND NOT (awp.PREV_AUTO_DT IS NOT NULL
                 AND datediff(awp.TX_DT, awp.PREV_AUTO_DT) <= {sct_tandem_days})
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
  run_step(con, paste0(pfx, "_lot", lot_num, "_start"), glue("
    CREATE OR REPLACE TEMPORARY VIEW lot{lot_num}_start AS
    SELECT
      sc.PATID,
      sc.PREV_END_DT, sc.OBS_END_DT, sc.DEATH_DT, sc.ENDDATE, sc.ENDDATE_CE,
      sc.d_MED, sc.d_ALLO, sc.d_CART, sc.d_AUTO,
      {least_expr} AS LOT{lot_num}_START_DT,
      -- Same-day tie-break: SCT_ALLO > CART > SCT_AUTO > MED.
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

  # ---- Step N.3: LOT_N regimen, discontinuation, first add ----
  # ALLO and CART starts have different regimen rules; handled at the end-date stage.
  med_flag_exprs <- paste(vapply(meds, function(m)
    glue("max(case when im.MED_ABBR = '{m}' then 1 else 0 end) as LOT{lot_num}_MED_{.lot_sanitize_col(m)}"),
    character(1)), collapse = ",\n        ")
  class_flag_exprs <- paste(vapply(classes, function(cl)
    glue("max(case when im.MED_CLASS = '{cl}' then 1 else 0 end) as LOT{lot_num}_CLASS_{.lot_sanitize_col(cl)}"),
    character(1)), collapse = ",\n        ")

  run_step(con, paste0(pfx, "_lot", lot_num, "_induction_meds"), glue("
    CREATE OR REPLACE TEMPORARY VIEW lot{lot_num}_induction_meds AS
    SELECT DISTINCT
      ms.PATID,
      ls.LOT{lot_num}_START_DT,
      ls.LOT{lot_num}_START_TYPE,
      ms.MAP_MED_TYPE  AS MED_ABBR,
      ms.MAP_MED_CLASS AS MED_CLASS
    FROM map_stacked ms
    INNER JOIN lot{lot_num}_start ls ON ms.PATID = ls.PATID
    WHERE ms.MAP_START_DT >= ls.LOT{lot_num}_START_DT
      -- CAR-T-started LOTs use the 45-day consolidation window (Apr 22; Q3).
      -- All other start types use the 30-day induction window.
      AND ms.MAP_START_DT <= date_add(
            ls.LOT{lot_num}_START_DT,
            CASE WHEN ls.LOT{lot_num}_START_TYPE = 'CART'
                 THEN {cart_consolidation_days - 1}
                 ELSE {induction_window_days - 1} END)
      AND ms.MAP_MED_CLASS <> 'STEROID'
      -- ALLO singleton LOTs contain no MM therapies; suppress regimen rows.
      AND ls.LOT{lot_num}_START_TYPE <> 'SCT_ALLO'
  "), qc = glue("SELECT count(*) AS n_rows, count(DISTINCT PATID) AS n_pats
                 FROM lot{lot_num}_induction_meds"))

  run_step(con, paste0(pfx, "_lot", lot_num, "_base"), glue("
    CREATE OR REPLACE TEMPORARY VIEW lot{lot_num}_base AS
    WITH base_meds AS (
      SELECT PATID, MED_ABBR FROM lot{lot_num}_induction_meds
      UNION
      SELECT im.PATID, ps.substitute_med AS MED_ABBR
      FROM lot{lot_num}_induction_meds im
      INNER JOIN permissible_subs ps ON im.MED_ABBR = ps.original_med
    ),
    discon_raw AS (
      SELECT ms.PATID, max(ms.MAP_END_DT) AS RAW_DISCON_DT
      FROM map_stacked ms
      INNER JOIN lot{lot_num}_start ls ON ms.PATID = ls.PATID
      INNER JOIN base_meds bm ON ms.PATID = bm.PATID AND ms.MAP_MED_TYPE = bm.MED_ABBR
      WHERE ms.MAP_START_DT >= ls.LOT{lot_num}_START_DT
      GROUP BY ms.PATID
    ),
    discon AS (
      SELECT
        ls.PATID,
        -- Q1 (06-May): no LOT-level 90d confirmation buffer. LOT{lot_num}_BASE_DISCON_DT
        -- is the last med date (max MAP_END_DT) whenever a runout exists and falls on or
        -- before OBS_END_DT. Capping at OBS_END_DT prevents days-supply tails past
        -- death/study_end from extending the LOT (previously a CART-only carve-out;
        -- now applies uniformly to all LOT types).
        CASE
          WHEN d.RAW_DISCON_DT IS NOT NULL AND d.RAW_DISCON_DT <= ls.OBS_END_DT
            THEN d.RAW_DISCON_DT
          ELSE NULL
        END AS LOT{lot_num}_BASE_DISCON_DT
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
      LEFT JOIN discon d ON ls.PATID = d.PATID
      WHERE bm.MED_ABBR IS NULL
        AND ms.MAP_MED_CLASS <> 'STEROID'
        -- Per-start-type lookback gate:
        --   MED  / SCT_AUTO -> any agent after the 30-day induction window
        --   CART             -> any agent after the 45-day consolidation window
        --   SCT_ALLO (extend) -> any agent strictly after LOT_START_DT (no
        --                       induction window for ALLO; the very next MM
        --                       agent ends the ALLO LOT)
        AND ms.MAP_START_DT > CASE
              WHEN ls.LOT{lot_num}_START_TYPE = 'SCT_ALLO'
                THEN ls.LOT{lot_num}_START_DT
              WHEN ls.LOT{lot_num}_START_TYPE = 'CART'
                THEN date_add(ls.LOT{lot_num}_START_DT, {cart_consolidation_days - 1})
              ELSE date_add(ls.LOT{lot_num}_START_DT, {induction_window_days - 1})
            END
        AND ms.MAP_START_DT <= coalesce(d.LOT{lot_num}_BASE_DISCON_DT, ls.OBS_END_DT)
        -- ALLO single_day LOTs end on the ALLO date itself, so add-med is moot.
        AND NOT (ls.LOT{lot_num}_START_TYPE = 'SCT_ALLO' AND {if (allo_lot_span == 'single_day') 1L else 0L} = 1)
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
      d.LOT{lot_num}_BASE_DISCON_DT,
      fa.LOT{lot_num}_BASE_1ST_ADD_MED_DT,
      fa.LOT{lot_num}_BASE_1ST_ADD_MED,
      -- Dynamic per-MED and per-CLASS flags (mirror LOT1). NULL -> 0 for
      -- ALLO/CART singleton LOTs that have no induction rows.
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
                        sum(CASE WHEN LOT{lot_num}_BASE_DISCON_DT IS NOT NULL THEN 1 ELSE 0 END) AS n_discon,
                        sum(CASE WHEN LOT{lot_num}_BASE_1ST_ADD_MED_DT IS NOT NULL THEN 1 ELSE 0 END) AS n_add_med
                 FROM lot{lot_num}_base"))

  # ---- Step N.4: LOT_N SCT events scoped to this LOT ----
  # AUTO/ALLO/CART occurring within [LOT_N_START_DT, OBS_END_DT].
  run_step(con, paste0(pfx, "_lot", lot_num, "_sct"), glue("
    CREATE OR REPLACE TEMPORARY VIEW lot{lot_num}_sct AS
    WITH lb AS (
      -- Q16 (06-May): LOT_WINDOW_DAYS = applicable window for this LOT's
      -- in-LOT AUTO definition (30d MED/AUTO-started, 1d ALLO-started,
      -- 45d CART-started). An AUTO_DT_1 outside this window is NOT in-LOT
      -- and instead becomes the ENDING_AUTO_DT that closes the LOT.
      SELECT PATID, LOT{lot_num}_START_DT, LOT{lot_num}_START_TYPE, OBS_END_DT,
        CASE LOT{lot_num}_START_TYPE
          WHEN 'SCT_ALLO' THEN 1
          WHEN 'CART'     THEN {cart_consolidation_days}
          ELSE                 {induction_window_days}
        END AS LOT_WINDOW_DAYS
      FROM lot{lot_num}_base
    ),
    -- For LOTs N>=2, an unplanned AUTO can itself BE the start (LOT_N_START_DT = AUTO_DT).
    -- LOT-internal AUTOs after the start are scoped here. End-LOT logic for excess
    -- AUTOs uses the same tandem rule as LOT1.
    -- For end-LOT logic the SCT scans must IGNORE the start-date SCT itself
    -- on ALLO- or CART-started LOTs. If we use TX_DT >= LOT_START_DT here,
    -- earliest_non_auto / first_allo / first_cart all latch onto the start
    -- event, hiding any later SCT that should end LOT_N. AUTO uses >=
    -- because an SCT_AUTO-started LOT must capture its start AUTO as
    -- AUTO_DT_1 (within-LOT, not an end trigger).
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
      -- Q16 (06-May): AUTO_DT_1 is in-LOT only if within the LOT
      -- applicable window from LOT_START_DT (LOT_WINDOW_DAYS). If AUTO_DT_1
      -- falls outside the window, it is NOT in-LOT (the TX_AUTO_* fields and
      -- TAND/SING flags become NULL/0) and instead becomes the ENDING_AUTO_DT
      -- that closes LOT N. AUTO_DT_2 is in-LOT only when AUTO_DT_1 is in-LOT
      -- AND AUTO_DT_2 is a valid tandem (<= sct_tandem_days after AUTO_DT_1).
      CASE WHEN ap.AUTO_DT_1 IS NOT NULL
            AND datediff(ap.AUTO_DT_1, l.LOT{lot_num}_START_DT) < l.LOT_WINDOW_DAYS
           THEN ap.AUTO_DT_1 END AS LOT{lot_num}_TX_AUTO_DT_1,
      CASE WHEN ap.AUTO_DT_1 IS NOT NULL
            AND datediff(ap.AUTO_DT_1, l.LOT{lot_num}_START_DT) < l.LOT_WINDOW_DAYS
            AND ap.AUTO_DT_2 IS NOT NULL
            AND datediff(ap.AUTO_DT_2, ap.AUTO_DT_1) <= {sct_tandem_days}
            AND coalesce(ab.n_allo_between, 0) = 0
           THEN ap.AUTO_DT_2 END AS LOT{lot_num}_TX_AUTO_DT_2,
      CASE
        WHEN ap.AUTO_DT_1 IS NOT NULL
         AND datediff(ap.AUTO_DT_1, l.LOT{lot_num}_START_DT) < l.LOT_WINDOW_DAYS
         AND ap.AUTO_DT_2 IS NOT NULL
         AND datediff(ap.AUTO_DT_2, ap.AUTO_DT_1) <= {sct_tandem_days}
         AND coalesce(ab.n_allo_between, 0) = 0
        THEN 1 ELSE 0
      END AS LOT{lot_num}_SCT_AUTO_TAND_FLG,
      CASE
        WHEN ap.AUTO_DT_1 IS NOT NULL
         AND datediff(ap.AUTO_DT_1, l.LOT{lot_num}_START_DT) < l.LOT_WINDOW_DAYS
         AND NOT (ap.AUTO_DT_2 IS NOT NULL
                  AND datediff(ap.AUTO_DT_2, ap.AUTO_DT_1) <= {sct_tandem_days}
                  AND coalesce(ab.n_allo_between, 0) = 0)
        THEN 1 ELSE 0
      END AS LOT{lot_num}_SCT_AUTO_SING_FLG,
      CASE
        WHEN ap.AUTO_DT_1 IS NULL THEN NULL
        -- AUTO_DT_1 outside window: it is the ENDING_AUTO_DT (LOT N+1 trigger)
        WHEN datediff(ap.AUTO_DT_1, l.LOT{lot_num}_START_DT) >= l.LOT_WINDOW_DAYS
          THEN ap.AUTO_DT_1
        -- Valid tandem in-LOT: AUTO_DT_3 ends LOT N
        WHEN ap.AUTO_DT_2 IS NOT NULL
         AND datediff(ap.AUTO_DT_2, ap.AUTO_DT_1) <= {sct_tandem_days}
         AND coalesce(ab.n_allo_between, 0) = 0
        THEN ap.AUTO_DT_3
        -- Single in-LOT AUTO: AUTO_DT_2 ends LOT N (when it exists and is non-tandem)
        ELSE ap.AUTO_DT_2
      END AS ENDING_AUTO_DT,
      fa.ALLO_DT AS FIRST_ALLO_DT,
      fc.CART_DT AS FIRST_CART_DT,
      CASE WHEN ap.AUTO_DT_1 IS NOT NULL
            AND datediff(ap.AUTO_DT_1, l.LOT{lot_num}_START_DT) < l.LOT_WINDOW_DAYS
           THEN 1 ELSE 0 END AS LOT{lot_num}_TX_AUTO_FLG,
      -- LOTN_TX_AUTO_MAX_DT: 2nd tandem AUTO if valid tandem, else AUTO_DT_1 (in-LOT only).
      CASE
        WHEN ap.AUTO_DT_1 IS NOT NULL
         AND datediff(ap.AUTO_DT_1, l.LOT{lot_num}_START_DT) < l.LOT_WINDOW_DAYS
         AND ap.AUTO_DT_2 IS NOT NULL
         AND datediff(ap.AUTO_DT_2, ap.AUTO_DT_1) <= {sct_tandem_days}
         AND coalesce(ab.n_allo_between, 0) = 0
        THEN ap.AUTO_DT_2
        WHEN ap.AUTO_DT_1 IS NOT NULL
         AND datediff(ap.AUTO_DT_1, l.LOT{lot_num}_START_DT) < l.LOT_WINDOW_DAYS
        THEN ap.AUTO_DT_1
        ELSE NULL
      END AS LOT{lot_num}_TX_AUTO_MAX_DT
    FROM lb l
    LEFT JOIN auto_pivot   ap ON l.PATID = ap.PATID
    LEFT JOIN allo_between ab ON l.PATID = ab.PATID
    LEFT JOIN first_allo   fa ON l.PATID = fa.PATID
    LEFT JOIN first_cart   fc ON l.PATID = fc.PATID
  "), qc = glue("SELECT count(*) AS n_pats,
                        sum(LOT{lot_num}_TX_AUTO_FLG) AS n_with_auto,
                        sum(LOT{lot_num}_SCT_AUTO_TAND_FLG) AS n_tandem,
                        sum(CASE WHEN FIRST_ALLO_DT IS NOT NULL THEN 1 ELSE 0 END) AS n_with_allo,
                        sum(CASE WHEN FIRST_CART_DT IS NOT NULL THEN 1 ELSE 0 END) AS n_with_cart
                 FROM lot{lot_num}_sct"))

  # ---- Step N.5: contains_mtx_reg ----
  run_step(con, paste0(pfx, "_lot", lot_num, "_contains_mtx_reg"), glue("
    CREATE OR REPLACE TEMPORARY VIEW lot{lot_num}_contains_mtx_reg AS
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
  # ALLO singleton: end on ALLO_DT (Q2 resolved: single_day).
  # CART singleton-ish: agents within cart_consolidation_days are part of LOT_N.
  # Otherwise: same end-reason logic as LOT1, with the same priority order.
  # ALLO span Q2 - "single_day" hardcodes start = end = ALLO_DT with reason
  # SCT_ALLO; "extend_to_next" lets the LOT extend until the next event with
  # the natural end reason (MED_ADD / DISCONTINUATION / DEATH / STUDY_END).
  allo_single_day <- (allo_lot_span == "single_day")

  run_step(con, paste0(pfx, "_lot", lot_num, "_base_end"), glue("
    CREATE OR REPLACE TEMPORARY VIEW lot{lot_num}_base_end AS
    WITH
    -- Q1.1 (post-review fix): identify whether any LOT_(N+1)-qualifying
    -- trigger exists strictly after LOT_BASE_DISCON_DT and on/before
    -- OBS_END_DT. This is used to prevent DEATH from preempting
    -- DISCONTINUATION when a patient ran out and then started new therapy
    -- (or had an SCT) before dying. Without this gate, the post-runout
    -- therapy would be silently swallowed by the DEATH-ends-LOT branch.
    --
    -- The post_runout CTEs MIRROR the actual LOT_(N+1) start-candidate
    -- logic (med_cand / auto_cand) so the guard fires exactly when LOT
    -- (N+1) would actually have a valid start trigger:
    --   - MED: any non-steroid MM agent NOT in the prior LOT's permissible
    --     biosimilar substitutes. Same-drug restarts DO qualify, matching
    --     med_cand (lot2_5_base.R::med_cand) which only excludes
    --     prev_meds_expanded (substitutes), not the base meds themselves.
    --   - AUTO: any AUTO outside LOT N's applicable window from
    --     LOT_START_DT (30d MED/AUTO-started, 1d ALLO-started, 45d
    --     CART-started) AND not within sct_tandem_days (180d) of the
    --     immediately prior AUTO in patient history (planned tandem).
    --     Mirrors auto_cand exactly with PREV_END_DT swapped for
    --     LOT_BASE_DISCON_DT.
    --   - ALLO/CART: any after runout (no window check; ALLO and CART
    --     always trigger a new LOT).
    post_runout_excluded_meds AS (
      SELECT im.PATID, ps.substitute_med AS MED_ABBR
      FROM lot{lot_num}_induction_meds im
      INNER JOIN permissible_subs ps ON im.MED_ABBR = ps.original_med
    ),
    post_runout_med AS (
      SELECT DISTINCT ms.PATID
      FROM map_stacked ms
      INNER JOIN lot{lot_num}_base lb ON ms.PATID = lb.PATID
      LEFT JOIN post_runout_excluded_meds prem
        ON ms.PATID = prem.PATID AND ms.MAP_MED_TYPE = prem.MED_ABBR
      WHERE lb.LOT{lot_num}_BASE_DISCON_DT IS NOT NULL
        AND ms.MAP_START_DT > lb.LOT{lot_num}_BASE_DISCON_DT
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
      SELECT DISTINCT lb.PATID
      FROM lot{lot_num}_base lb
      INNER JOIN post_runout_autos awp ON lb.PATID = awp.PATID
      WHERE lb.LOT{lot_num}_BASE_DISCON_DT IS NOT NULL
        AND awp.TX_DT > lb.LOT{lot_num}_BASE_DISCON_DT
        AND awp.TX_DT <= lb.OBS_END_DT
        AND awp.TX_DT > date_add(
              lb.LOT{lot_num}_START_DT,
              CASE lb.LOT{lot_num}_START_TYPE
                WHEN 'SCT_ALLO' THEN 0
                WHEN 'CART'     THEN {cart_consolidation_days} - 1
                ELSE                 {induction_window_days} - 1
              END)
        AND NOT (awp.PREV_AUTO_DT IS NOT NULL
                 AND datediff(awp.TX_DT, awp.PREV_AUTO_DT) <= {sct_tandem_days})
    ),
    post_runout_trigger AS (
      SELECT lb.PATID,
        CASE
          WHEN lb.LOT{lot_num}_BASE_DISCON_DT IS NULL THEN 0
          WHEN prm.PATID IS NOT NULL THEN 1
          WHEN sct.FIRST_ALLO_DT IS NOT NULL AND sct.FIRST_ALLO_DT > lb.LOT{lot_num}_BASE_DISCON_DT THEN 1
          WHEN sct.FIRST_CART_DT IS NOT NULL AND sct.FIRST_CART_DT > lb.LOT{lot_num}_BASE_DISCON_DT THEN 1
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
        sct.LOT{lot_num}_TX_AUTO_DT_1, sct.LOT{lot_num}_TX_AUTO_DT_2,
        sct.LOT{lot_num}_SCT_AUTO_TAND_FLG, sct.LOT{lot_num}_SCT_AUTO_SING_FLG,
        sct.ENDING_AUTO_DT, sct.FIRST_ALLO_DT, sct.FIRST_CART_DT,
        sct.LOT{lot_num}_TX_AUTO_FLG,
        sct.LOT{lot_num}_TX_AUTO_MAX_DT,
        coalesce(cmr.contains_mtx_reg, 0) AS contains_mtx_reg,
        -- LOT_TX_ENDDATE / REASON: earliest LOT-ending SCT event - 1 day.
        -- Suppress the SCT that started LOT_N from triggering its own end:
        -- if start type is SCT_AUTO/SCT_ALLO/CART, that event is on LOT_N_START_DT.
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
        -- Same-day SCT end priority (Q14 resolved, inherits LOT1):
        -- SCT_ALLO > SCT_CART > SCT_AUTO. ALLO wins ALLO==CART or
        -- ALLO==AUTO ties; CART wins CART==AUTO; otherwise AUTO.
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
        -- CART_INIT (inherited from LOT1): MED_ADD followed by CART within cart_consolidation_days.
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
    )
    SELECT
      ec.*,
      -- Special-case start types (Q2 resolved single-day ALLO; Q3 draft for CAR-T-without-consolidation).
      --   ALLO single_day: LOT spans only the ALLO date itself.
      --   CAR-T with no consolidation agents: LOT spans only FIRST_CART_DT.
      --   ALLO extend_to_next: fall through to the natural end-reason logic.
      CASE
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
        -- Q1 (06-May): DEATH now outranks DISCONTINUATION. Patients who run out
        -- and then die get REASON = DEATH; runout date is still recorded in
        -- LOT{lot_num}_BASE_DISCON_DT.
        -- Q1.1: DEATH preempts DISCONTINUATION only when no qualifying
        -- LOT-start trigger exists in (DISCON_DT, OBS_END_DT]. If the patient
        -- ran out then started new therapy (or had an SCT) before dying,
        -- the runout is the true LOT end and the new event triggers LOT N+1.
        WHEN ec.DEATH_DT IS NOT NULL AND ec.DEATH_DT <= ec.OBS_END_DT
         AND ec.POST_RUNOUT_TRIGGER_FLG = 0 THEN 'DEATH'
        WHEN ec.LOT{lot_num}_BASE_DISCON_DT IS NOT NULL THEN 'DISCONTINUATION'
        ELSE 'STUDY_END'
      END AS LOT{lot_num}_BASE_END_REASON,
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
      END AS LOT{lot_num}_BASE_END_DT
    FROM end_candidates ec
  "), qc = glue("SELECT LOT{lot_num}_BASE_END_REASON, count(*) AS n
                 FROM lot{lot_num}_base_end
                 GROUP BY LOT{lot_num}_BASE_END_REASON
                 ORDER BY LOT{lot_num}_BASE_END_REASON"))

  # ---- Step N.7: append to lot_long ----
  # Sensitivity columns: cap LOT_BASE_END_DT_CE_SENS at ENDDATE_CE.
  # Reason flips to DISENROLLMENT only when ELIGEND is the binding cap.
  med_insert <- paste(vapply(meds, function(m) {
    sc <- .lot_sanitize_col(m)
    sprintf("lbe.LOT%d_MED_%s AS LOT_MED_%s", lot_num, sc, sc)
  }, character(1)), collapse = ",\n      ")
  class_insert <- paste(vapply(classes, function(cl) {
    sc <- .lot_sanitize_col(cl)
    sprintf("lbe.LOT%d_CLASS_%s AS LOT_CLASS_%s", lot_num, sc, sc)
  }, character(1)), collapse = ",\n      ")

  run_step(con, paste0(pfx, "_lot", lot_num, "_append_long"), glue("
    INSERT INTO {wrk('LOT_LONG')}
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
      -- LOT-scoped AUTO flags clamped to [LOT_START_DT, LOT_BASE_END_DT]
      -- per workbook Q7 draft. lot{n}_sct collects through OBS_END_DT, so
      -- AUTOs after the LOT ended are filtered here. SING/TAND classification
      -- is RECOMPUTED from the clamped in-LOT dates so a within-LOT DT_1
      -- with an outside-LOT DT_2 lands on SING (not on neither flag).
      CASE WHEN lbe.LOT{lot_num}_TX_AUTO_DT_1 IS NOT NULL
            AND lbe.LOT{lot_num}_TX_AUTO_DT_1 <= lbe.LOT{lot_num}_BASE_END_DT
           THEN 1 ELSE 0 END                          AS LOT_TX_AUTO_FLG,
      -- TAND only if both in-LOT, AUTO_DT_2 within sct_tandem_days of AUTO_DT_1, AND pre-clamp tandem rules
      -- already qualified it (no ALLO between, etc., from lot{n}_sct).
      CASE WHEN lbe.LOT{lot_num}_TX_AUTO_DT_2 IS NOT NULL
            AND lbe.LOT{lot_num}_TX_AUTO_DT_2 <= lbe.LOT{lot_num}_BASE_END_DT
            AND coalesce(lbe.LOT{lot_num}_SCT_AUTO_TAND_FLG, 0) = 1
           THEN 1 ELSE 0 END                          AS LOT_TX_AUTO_TAND_FLG,
      -- SING = has in-LOT DT_1, not classified as TAND.
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
      -- MAX_DT: 2nd in-LOT AUTO if valid in-LOT tandem, else 1st in-LOT AUTO.
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
  "), qc = glue("SELECT count(*) AS n_appended FROM {wrk('LOT_LONG')} WHERE LOT_NUM = {lot_num}"))

  # Refresh lot_long view to include the newly inserted rows.
  db_exec(con, glue("CREATE OR REPLACE TEMPORARY VIEW lot_long AS SELECT * FROM {wrk('LOT_LONG')}"))
}

# ============================================================
# Top-level driver
# ============================================================

build_lot2_5 <- function(con,
                        induction_window_days   = 30,
                        cart_consolidation_days = 45,
                        sct_tandem_days         = 180,
                        allo_lot_span           = "single_day",
                        max_lot                 = 5) {
  stopifnot(allo_lot_span %in% c("single_day", "extend_to_next"))
  stopifnot(max_lot >= 2L && max_lot <= 9L)

  log_msg("Building LOT_LONG (LOT1..LOT", max_lot, ")")
  log_msg("  induction_window_days   = ", induction_window_days)
  log_msg("  cart_consolidation_days = ", cart_consolidation_days)
  log_msg("  sct_tandem_days         = ", sct_tandem_days)
  log_msg("  allo_lot_span           = ", allo_lot_span, " (Q2)")

  # Discover med + class universes from the rollup so dynamic flag columns
  # match LOT1 output exactly. STEROID class excluded - LOT1 uses the same
  # filter, so persisted LOT1_MED_<DEXA>/<PRED> columns will not exist.
  meds <- db_q(con, "
    SELECT DISTINCT CL_MED_ABBR AS MED_ABBR
    FROM mma_rollup
    WHERE upper(coalesce(CL_MED_CLASS, '')) <> 'STEROID'
    ORDER BY CL_MED_ABBR
  ")$MED_ABBR
  classes <- db_q(con, "
    SELECT DISTINCT CL_MED_CLASS AS MED_CLASS
    FROM mma_rollup
    WHERE upper(coalesce(CL_MED_CLASS, '')) <> 'STEROID'
      AND CL_MED_CLASS IS NOT NULL
    ORDER BY CL_MED_CLASS
  ")$MED_CLASS

  init_lot_long_from_lot1(con, meds = meds, classes = classes)

  for (n in 2:max_lot) {
    log_msg("--- LOT", n, " ---")
    nrows_before <- db_q(con, glue("SELECT count(*) AS n FROM {wrk('LOT_LONG')} WHERE LOT_NUM = {n - 1}"))$n
    if (nrows_before == 0L) {
      log_msg("  No LOT", n - 1, " rows; nothing to roll forward. Stopping.")
      break
    }
    build_lot_n(con, lot_num = n,
                induction_window_days   = induction_window_days,
                cart_consolidation_days = cart_consolidation_days,
                sct_tandem_days         = sct_tandem_days,
                allo_lot_span           = allo_lot_span,
                meds = meds, classes = classes)
  }

  # Final summary
  summary <- db_q(con, glue("
    SELECT LOT_NUM, LOT_START_TYPE, LOT_BASE_END_REASON, count(*) AS n
    FROM {wrk('LOT_LONG')}
    GROUP BY LOT_NUM, LOT_START_TYPE, LOT_BASE_END_REASON
    ORDER BY LOT_NUM, LOT_START_TYPE, LOT_BASE_END_REASON
  "))
  log_msg("LOT_LONG summary (LOT_NUM x START_TYPE x END_REASON):")
  print(summary)

  invisible(wrk("LOT_LONG"))
}
