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
    -- MAX_LOT is applied OUTSIDE the window, in an outer query.
    --
    -- SQL evaluates WHERE before a window function, so `WHERE LOT_NUM <= 4` in
    -- the same SELECT as lead() hides line 5 from line 4's lead - and line 4
    -- then looks like the patient's last line. Its treatment period falls back
    -- to discontinuation + 30 days and runs INTO line 5, taking line 5's events
    -- with it; TTNT censors everyone who reached the top line; and
    -- S_TX_ATTRITION calls them 'discontinued_no_further'. The window has to
    -- see every line the engine built.
    SELECT * FROM (
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
           THEN 1 ELSE 0 END AS IS_PROTOCOL_DISCON,
      -- The DATE that goes with the reason above, derived once here so TTD and
      -- the treatment window cannot disagree.
      --
      -- NOT LOT_BASE_DISCON_DT. In the engine that column is a CANDIDATE - the
      -- medication run-out - and the end cascade may select a different reason
      -- and a different date while leaving the run-out populated. A line whose
      -- selected end is a MED_ADD on 31 May can carry a run-out of 30 June, and
      -- one continued by an in-window AUTO transplant carries a run-out days
      -- after the line started. Reading the candidate put TTD before the
      -- transplant that caused it and closed the treatment window ahead of the
      -- event it was meant to contain, losing the event and its person-time.
      --
      -- LOT_BASE_END_DT is by construction the date matching the selected
      -- LOT_BASE_END_REASON, so where the reason is a protocol discontinuation
      -- the end date IS the discontinuation date. Where the engine's own
      -- DISCONTINUATION wins, the two agree anyway.
      CASE WHEN l.LOT_BASE_END_REASON IN
             ('DISCONTINUATION','MED_ADD','CART_INIT','SCT_AUTO','SCT_ALLO',
              'SCT_CART','SCT_AUTO_CONT')
           THEN l.LOT_BASE_END_DT END AS PROTOCOL_DISCON_DT
    FROM %s l
    ) w
    WHERE w.LOT_NUM <= %d", wrk("S_SPINE"), src, as.integer(cfg$max_lot)),
    qc = sprintf("SELECT count(*) AS n_lines, count(DISTINCT PATID) AS n_pat,
                         min(LOT_NUM) AS min_lot, max(LOT_NUM) AS max_lot
                  FROM %s", wrk("S_SPINE")))
}
