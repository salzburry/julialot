# An agent in the previous line's regimen cannot start the next one WHILE IT IS
# STILL RUNNING: the protocol starts a later LOT on "a new MM agent that was not
# part of the previous LOT regimen", and a drug the patient has not stopped is
# not new. Its later episodes belong to the line it is already in, so that
# line's run-out chains forward over them.
#
# Once it has been discontinued it is released. map_discon_gap_days marks the
# episode whose gap to the next reaches the threshold, and an episode arriving
# after such a gap is a restart, not a continuation - so it may open a line like
# any other agent. The exclusion used to be unconditional, which left a line
# spanning its own agent's 185-day absence.
#
# The two halves of that are one rule and ship together. Releasing the drug
# without breaking the run-out chain would open a line inside a line that was
# still notionally running; breaking the chain without releasing the drug would
# leave the returning treatment in no line at all. See discon_per_med_sql below.

# The prior-LOT drugs themselves, added to the set med_cand excludes - which
# otherwise holds only their permissible biosimilar substitutes.
prior_regimen_excl_sql <- function() {
  "
      UNION ALL
      SELECT pma.PATID, pma.MED_ABBR, 0 AS IS_SUB
      FROM prev_meds_array pma"
}

# The release applies to a drug that WAS the previous regimen. It does not apply
# to one excluded only for being a permissible biosimilar substitute: §4.4 says a
# substitute never starts a line, and an old discontinued episode of it must not
# become a way around that. So the exclusion set carries WHY each drug is in it,
# and only the actual regimen drugs are releasable.

# Per (patient, drug, episode): was this episode preceded by a confirmed
# discontinuation of the same drug? Spliced as a CTE by every caller that has to
# tell a restart from a continuation - the start candidates and the run-out
# guards that mirror them. One definition, because a guard reading a different
# rule from the candidate it mirrors is how a line ends on an event the next
# line then refuses to open on.
map_restart_sql <- function() {
  "
      SELECT ms.PATID, ms.MAP_MED_TYPE, ms.MAP_START_DT,
             coalesce(lag(ms.MAP_DISCON_FLG) OVER (PARTITION BY ms.PATID, ms.MAP_MED_TYPE
                                      ORDER BY ms.MAP_START_DT), 0) AS PREV_DISCON
      FROM map_stacked ms"
}

# Where a line's cover ends, per drug: the body of discon_per_med. A drug's
# episodes chain forward from the line's start, and the run-out is the end of the
# last one reached; the chain breaks only at an agent that would actually end the
# line, so a line another agent ended stays where that agent put it.
#
# A confirmed discontinuation of the drug itself breaks it too. map_discon_gap_days
# marks an episode whose gap to the next reaches the threshold, and that flag sat
# on the very row this scan reads without ever being consulted - so a line
# extended over its own agent's 185-day absence and ran for seven months with no
# cover. The chain now stops at the last episode before the gap.
#
# This is half a rule. Stopping the chain without also letting the drug open a
# line leaves the returning treatment belonging to nothing at all, so
# prior_regimen_excl_sql() releases it in the same commit. Neither half is safe
# alone.
#
# What else breaks it is deliberately narrow. A drug in this line's own regimen does
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
                               boundary_tbl = "map_stacked", boundary_gate = "",
                               end_col = NULL) {
  # The scan is bounded BELOW by the line start and, without this, not at all
  # above: a base agent's later episodes chain forward for as long as the
  # patient keeps filling it. Bounding regimen membership at the date the line
  # was cut short is therefore only half a fix - a refill of an agent that
  # legitimately IS in the regimen still pushes the run-out past the transplant.
  # Both halves or neither.
  upper <- if (is.null(end_col)) "" else paste0("
          AND ms.MAP_START_DT <= coalesce(ls.", end_col,
          ", cast('9999-12-31' as date))")
  paste0("
      WITH ep AS (
        SELECT ms.PATID, ms.MAP_MED_TYPE, ms.MAP_START_DT, ms.MAP_END_DT,
               lag(ms.MAP_END_DT) OVER (PARTITION BY ms.PATID, ms.MAP_MED_TYPE
                                        ORDER BY ms.MAP_START_DT) AS PREV_END,
               -- Did this drug's PREVIOUS episode end in a confirmed
               -- discontinuation? MAP_DISCON_FLG sits on the episode before the
               -- gap, so the lag is what tells this episode it is a restart.
               --
               -- Never for a substitute. A substitution does not advance the
               -- LOT, so a gap in a substitute's own episodes must not break the
               -- chain either. Letting it break here while the start, add-med
               -- and run-out gates all refuse the same drug would end a line on
               -- a restart that no line can then own - the treatment would
               -- belong to nothing. The four paths have to read one rule.
               CASE WHEN bm.SUBSTITUTE_ONLY = 1 THEN 0 ELSE
                 coalesce(lag(ms.MAP_DISCON_FLG) OVER (PARTITION BY ms.PATID, ms.MAP_MED_TYPE
                                          ORDER BY ms.MAP_START_DT), 0) END AS PREV_DISCON
        FROM ", map_tbl, " ms
        INNER JOIN ", start_view, " ls ON ms.PATID = ls.PATID
        INNER JOIN base_meds bm ON ms.PATID = bm.PATID AND ms.MAP_MED_TYPE = bm.MED_ABBR
        WHERE ms.MAP_START_DT >= ls.", start_col, upper, "
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
               sum(i.BREAKS + e.PREV_DISCON) OVER (PARTITION BY e.PATID, e.MAP_MED_TYPE
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

# Every event that breaks a planned tandem: a non-steroid medication starting,
# an allogeneic transplant, or a CAR-T. A tandem is only a tandem if nothing
# happens between the two transplants - the gap alone does not make the pair
# planned, and a patient treated in between was not waiting for a second
# transplant.
#
# One definition, spliced into all five places that ask the question: the tandem
# flags at LOT1 and LOT2-5, the next line's AUTO start gate, and the two
# run-out guards that mirror it. Five copies of this rule is how the five drift
# apart, and a tandem test that disagrees with the gate it mirrors puts a
# transplant in no line at all.
tandem_interrupt_events_sql <- function() "
        SELECT PATID, MAP_START_DT AS dt FROM map_stacked
        WHERE MAP_MED_CLASS <> 'STEROID'
        UNION ALL
        SELECT PATID, TX_DT AS dt FROM tx_allo_cart_dates
        WHERE SCT_TYPE IN ('ALLO', 'CART')"
