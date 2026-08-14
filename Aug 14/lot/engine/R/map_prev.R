# The preceding same-agent supply episode.
#
# Every boundary rule that asks "had the patient stopped this drug before it
# came back" needs the episode before the candidate one, and the flag that sits
# on it. Built once here rather than per query: five copies of the same lag()
# is five places for the partition, the order key or the flag choice to drift
# apart, and a boundary that ends a line disagreeing with the one that starts
# the next is the failure mode that matters most.
#
# Ordered by MAP_CNT, the counter 03_mma_map assigns as it opens each episode -
# not by MAP_START_DT. The two agree, because a new MAP only opens for a claim
# beyond every runout, so one drug's episodes never overlap. MAP_CNT is the
# construction order itself and does not rely on that argument holding.
#
# PREV_DISCON_FLG is the previous episode's flag, never the candidate's own.
# A MAP's flag describes the gap that follows it, so a returning episode's own
# flag is about its future, not about whether the patient had stopped.

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

# The test a returning agent has to pass to count as an initiation: the patient
# had stopped it, or had never had it. Written once so the line-ending query,
# the line-starting query and the post-runout confirmation cannot drift.
#
# The NULL branch is load-bearing. No preceding episode means a first exposure,
# and a bare PREV_DISCON_FLG = 1 would delete every one of them.
#
# Off, this returns nothing at all and the queries are left as they would be
# written without it, letting any agent whose cover lapsed advance a line. It
# reads returning_agent_requires_discontinuation. The threshold it tests is
# MAP_DISCON_GAP_DAYS, already set on the row; there is no second gap setting
# here and there must not be one.
#
# The setting is not in CONTRACT, so a run does not record which of the two
# algorithms produced its lines. That has to close before a run whose numbers
# are kept.
#
# The whole clause including the AND, so an off build emits the query without
# this test at all rather than a no-op predicate standing in for it.
prev_discon_gate_sql <- function(alias = "ms", on = TRUE) {
  if (!isTRUE(on)) return("")
  paste0("AND (", alias, ".PREV_DISCON_FLG IS NULL OR ",
         alias, ".PREV_DISCON_FLG = 1)")
}
