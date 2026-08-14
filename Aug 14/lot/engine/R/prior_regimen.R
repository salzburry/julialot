# An agent in the previous line's regimen cannot start the next one: the protocol
# starts a later LOT on "a new MM agent that was not part of the previous LOT
# regimen". Its later episodes therefore belong to the line it is already in, so
# that line's run-out chains forward over them.

# The prior-LOT drugs themselves, added to the set med_cand excludes - which
# otherwise holds only their permissible biosimilar substitutes.
prior_regimen_excl_sql <- function() {
  "
      UNION
      SELECT pma.PATID, pma.MED_ABBR
      FROM prev_meds_array pma"
}

# Where a line's cover ends, per drug: the body of discon_per_med. A drug's
# episodes chain forward from the line's start, and the run-out is the end of the
# last one reached; the chain breaks at any episode with another non-steroid
# agent starting between it and the one before, which is what keeps a line that
# another agent ended where that agent put it.
#
# LEFT JOIN and an aggregate rather than EXISTS: a correlated subquery fails
# under spark.sql.crossJoin.enabled=false.
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
