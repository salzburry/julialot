# An agent already in the previous line's regimen cannot start the next one.
#
# The protocol starts a subsequent LOT at "the first administration for a new MM
# agent that was not part of the previous LOT regimen". A drug that WAS that
# regimen is not such an agent, so it cannot open a line - however long it has
# been gone.
#
# "Previous regimen" is the immediately preceding line's, not every drug the
# patient has ever had. An agent from an older line that is absent from the one
# just ended still opens the next.
#
# Two halves, and they only work together:
#
#   1. the exclusion - a prior-regimen drug is not a line-start candidate
#   2. the run-out  - that drug's later episodes belong to the line it is in
#
# Without 2, prohibiting the restart leaves the returning episode owned by
# nothing: no boundary, no regimen, no next line. The treatment would be in
# map_stacked and in no row of LOT_LONG.

# The drugs themselves, added to the set med_cand already excludes - which
# otherwise holds only their permissible biosimilar substitutes, so the drug
# itself would open a line on itself.
prior_regimen_excl_sql <- function() {
  "
      UNION
      SELECT pma.PATID, pma.MED_ABBR
      FROM prev_meds_array pma"
}

# Where a line's cover ends, per drug: the body of discon_per_med.
#
# The drug's episodes are chained forward from the line's start and the run-out
# is the end of the last one reached - but the chain BREAKS at any episode with
# another non-steroid agent starting between it and the one before.
#
# The bound is the point. max(MAP_END_DT) on its own reaches every later episode
# of the drug, including ones belonging to a line built months afterwards: LENA
# in January and again in September would drag January's line forward to
# September even where an agent in March had already ended it, turning a real
# DISCONTINUATION into a MED_ADD. Chaining only while nothing intervenes is the
# "no agent in the middle" condition stated literally, and it leaves a line that
# another agent ended exactly where that agent put it.
#
# LEFT JOIN and an aggregate rather than EXISTS: a correlated subquery here
# fails under spark.sql.crossJoin.enabled=false, the same reason med_cand joins
# its exclusion set explicitly.
discon_per_med_sql <- function(start_view, start_col, map_tbl = "map_stacked") {
  paste0("
      WITH ep AS (
        SELECT ms.PATID, ms.MAP_MED_TYPE, ms.MAP_START_DT, ms.MAP_END_DT,
               lag(ms.MAP_END_DT) OVER (PARTITION BY ms.PATID, ms.MAP_MED_TYPE
                                        ORDER BY ms.MAP_START_DT) AS PREV_END
        FROM ", map_tbl, " ms
        INNER JOIN ", start_view, " ls ON ms.PATID = ls.PATID
        INNER JOIN base_meds bm ON ms.PATID = bm.PATID AND ms.MAP_MED_TYPE = bm.MED_ABBR
        WHERE ms.MAP_START_DT >= ls.", start_col, "
      ),
      broke AS (
        SELECT e.PATID, e.MAP_MED_TYPE, e.MAP_START_DT, e.MAP_END_DT,
               max(CASE WHEN o.PATID IS NOT NULL THEN 1 ELSE 0 END) AS BREAKS
        FROM ep e
        LEFT JOIN ", map_tbl, " o
               ON o.PATID = e.PATID
              AND o.MAP_MED_TYPE <> e.MAP_MED_TYPE
              AND o.MAP_MED_CLASS <> 'STEROID'
              AND e.PREV_END IS NOT NULL
              AND o.MAP_START_DT >  e.PREV_END
              AND o.MAP_START_DT <  e.MAP_START_DT
        GROUP BY e.PATID, e.MAP_MED_TYPE, e.MAP_START_DT, e.MAP_END_DT
      ),
      reached AS (
        SELECT b.*,
               sum(b.BREAKS) OVER (PARTITION BY b.PATID, b.MAP_MED_TYPE
                                   ORDER BY b.MAP_START_DT
                                   ROWS BETWEEN UNBOUNDED PRECEDING
                                            AND CURRENT ROW) AS BROKEN_BY_HERE
        FROM broke b
      )
      SELECT PATID, MAP_MED_TYPE, max(MAP_END_DT) AS MED_END_DT
      FROM reached
      WHERE BROKEN_BY_HERE = 0
      GROUP BY PATID, MAP_MED_TYPE")
}
