# The preceding same-agent supply episode, attached to every row of map_stacked
# and built once so no boundary query carries its own copy. Ordered by MAP_CNT,
# the counter 03_mma_map assigns as it opens each episode.

map_prev_sql <- function(map_tbl = "map_stacked") {
  paste0("
    SELECT ms.*,
           lag(ms.MAP_CNT)        OVER w AS PREV_MAP_CNT,
           lag(ms.MAP_START_DT)   OVER w AS PREV_MAP_START_DT,
           lag(ms.MAP_END_DT)     OVER w AS PREV_MAP_END_DT,
           lag(ms.MAP_DISCON_FLG) OVER w AS PREV_DISCON_FLG
    FROM ", map_tbl, " ms
    WINDOW w AS (PARTITION BY ms.PATID, ms.MAP_MED_TYPE ORDER BY ms.MAP_CNT)
  ")
}

# The test a returning agent passes to count as an initiation: the patient had
# stopped it, or had never had it. The NULL branch is a first exposure - a bare
# PREV_DISCON_FLG = 1 would delete every one. Off, this emits nothing at all.
prev_discon_gate_sql <- function(alias = "ms", on = TRUE) {
  if (!isTRUE(on)) return("")
  paste0("AND (", alias, ".PREV_DISCON_FLG IS NULL OR ",
         alias, ".PREV_DISCON_FLG = 1)")
}
