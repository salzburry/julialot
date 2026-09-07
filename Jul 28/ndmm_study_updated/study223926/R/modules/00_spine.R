# The spine: one row per patient per line, with the next line's start beside it.
#
# Every later module joins to this, so the "which line comes next" arithmetic
# is done once. LOT_LONG_FINAL is the LOT engine's output after its own line
# criteria; LOT_LONG is the same lines before them, and reading it here would
# count patients the study removed.
mod_spine <- function(con, cfg, cohorts) {
  src <- lot_tbl("LOT_LONG_FINAL")
  run_step(con, "spine", sprintf("
    CREATE OR REPLACE TABLE %s AS
    SELECT
      cast(l.PATID as string)      AS PATID,
      cast(l.LOT_NUM as int)       AS LOT_NUM,
      l.LOT_START_DT,
      l.LOT_START_TYPE,
      l.LOT_BASE_MEDS,
      l.LOT_MED_CNT,
      l.LOT_BASE_DISCON_DT,
      l.LOT_BASE_END_DT,
      l.LOT_BASE_END_REASON,
      l.LOT_BASE_END_DT_CE_SENS,
      l.LOT_BASE_END_REASON_CE_SENS,
      l.LOT_ALLO_LOT_FLG,
      l.LOT_CART_LOT_FLG,
      l.LOT_TX_AUTO_FLG,
      l.LOT_TX_AUTO_TAND_FLG,
      l.LOT_TX_AUTO_MAX_DT,
      lead(l.LOT_START_DT) OVER (PARTITION BY l.PATID ORDER BY l.LOT_NUM)
        AS NEXT_LOT_START_DT,
      lead(l.LOT_NUM) OVER (PARTITION BY l.PATID ORDER BY l.LOT_NUM)
        AS NEXT_LOT_NUM,
      -- The protocol's 'discontinuation' is the union of three end reasons,
      -- not the one the engine spells DISCONTINUATION. Table 4's footnote:
      -- 'discontinuation of a regimen occurs when all MM agents in the LOT are
      -- stopped OR when a new agent/qualifying SCT event is introduced'.
      -- Reading LOT_BASE_END_REASON literally would undercount TTD badly.
      CASE WHEN l.LOT_BASE_END_REASON IN
             ('DISCONTINUATION','MED_ADD','CART_INIT','SCT_AUTO','SCT_ALLO',
              'SCT_CART','SCT_AUTO_CONT')
           THEN 1 ELSE 0 END AS IS_PROTOCOL_DISCON
    FROM %s l
    WHERE l.LOT_NUM <= %d", wrk("S_SPINE"), src, as.integer(cfg$max_lot)),
    qc = sprintf("SELECT count(*) AS n_lines, count(DISTINCT PATID) AS n_pat,
                         min(LOT_NUM) AS min_lot, max(LOT_NUM) AS max_lot
                  FROM %s", wrk("S_SPINE")))
}
