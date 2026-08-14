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
# last one reached; the chain breaks only at an agent that would actually end the
# line, so a line another agent ended stays where that agent put it.
#
# What breaks it is deliberately narrow. A drug in this line's own regimen does
# not - base_meds carries the induction agents AND their permissible substitutes,
# and neither is a boundary, so a second regimen agent refilling mid-line cannot
# truncate the first one's cover. Steroids never do. `boundary_gate` lets a
# caller narrow it further to agents its own rules would accept as a line start.
#
# Transplant and CAR-T are deliberately not read here. One that ends a line does
# so at a higher priority than DISCONTINUATION, so a run-out chained past it
# never surfaces; one that does not end a line - LOT1's induction AUTO, a tandem
# inside 180 days, CAR-T inside LOT1's window - must not break the chain anyway.
#
# LEFT JOIN and aggregates rather than EXISTS: a correlated subquery fails under
# spark.sql.crossJoin.enabled=false.
discon_per_med_sql <- function(start_view, start_col, map_tbl = "map_stacked",
                               boundary_tbl = "map_stacked", boundary_gate = "") {
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
      interrupts AS (
        SELECT e.PATID, e.MAP_MED_TYPE, e.MAP_START_DT,
               max(CASE WHEN o.PATID IS NOT NULL AND obm.MED_ABBR IS NULL
                        THEN 1 ELSE 0 END) AS BREAKS
        FROM ep e
        LEFT JOIN ", boundary_tbl, " o
               ON o.PATID = e.PATID
              AND o.MAP_MED_TYPE <> e.MAP_MED_TYPE
              AND o.MAP_MED_CLASS <> 'STEROID'
              AND e.PREV_END IS NOT NULL
              AND o.MAP_START_DT >  e.PREV_END
              AND o.MAP_START_DT <  e.MAP_START_DT
              ", boundary_gate, "
        LEFT JOIN base_meds obm
               ON obm.PATID = o.PATID AND obm.MED_ABBR = o.MAP_MED_TYPE
        GROUP BY e.PATID, e.MAP_MED_TYPE, e.MAP_START_DT
      ),
      reached AS (
        SELECT e.PATID, e.MAP_MED_TYPE, e.MAP_END_DT,
               sum(i.BREAKS) OVER (PARTITION BY e.PATID, e.MAP_MED_TYPE
                                   ORDER BY e.MAP_START_DT
                                   ROWS BETWEEN UNBOUNDED PRECEDING
                                            AND CURRENT ROW) AS BROKEN_BY_HERE
        FROM ep e
        INNER JOIN interrupts i
                ON i.PATID = e.PATID AND i.MAP_MED_TYPE = e.MAP_MED_TYPE
               AND i.MAP_START_DT = e.MAP_START_DT
      )
      SELECT PATID, MAP_MED_TYPE, max(MAP_END_DT) AS MED_END_DT
      FROM reached
      WHERE BROKEN_BY_HERE = 0
      GROUP BY PATID, MAP_MED_TYPE")
}
