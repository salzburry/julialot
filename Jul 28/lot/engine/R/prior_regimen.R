# A drug in the previous line's regimen cannot start the next line while it is
# still running. A later LOT starts on a new MM agent that was not part of the
# previous LOT regimen, and a drug the patient never stopped is not new. Its later episodes belong to the line it is already in, so that line's
# run-out chains forward over them.
#
# Once the drug is discontinued it is released. map_discon_gap_days flags the
# episode whose gap to the next reaches the threshold. An episode after such a
# gap is a restart, not a continuation, so it may open a line like any other
# drug.
#
# The release and the run-out chain are two halves of one rule and neither is
# safe alone. Release the drug without breaking the chain and a line opens
# inside a line still notionally running. Break the chain without releasing the
# drug and the returning treatment belongs to no line at all. See
# discon_per_med_sql below.

# The prior-LOT drugs themselves, added to the set med_cand excludes. Without
# them that set holds only their permissible biosimilar substitutes.
prior_regimen_excl_sql <- function() {
  "
      UNION ALL
      SELECT pma.PATID, pma.MED_ABBR, 0 AS IS_SUB
      FROM prev_meds_array pma"
}

# Only a drug that WAS the previous regimen is released this way. A drug
# excluded for being a permissible biosimilar substitute is not. §4.4 says a
# substitute never starts a line, and an old discontinued episode of it must not
# become a way around that. So the exclusion set records WHY each drug is in it,
# and only the real regimen drugs can be released.

# Per patient, drug and episode: did a confirmed discontinuation of the same
# drug come first? Spliced in as a CTE by every caller that has to tell a
# restart from a continuation - the start candidates, and the run-out guards
# that mirror them. One definition for all of them. A guard reading a different
# rule from the candidate it mirrors ends a line on an event the next line then
# refuses to open on.
map_restart_sql <- function() {
  "
      SELECT ms.PATID, ms.MAP_MED_TYPE, ms.MAP_START_DT,
             coalesce(lag(ms.MAP_DISCON_FLG) OVER (PARTITION BY ms.PATID, ms.MAP_MED_TYPE
                                      ORDER BY ms.MAP_START_DT), 0) AS PREV_DISCON
      FROM map_stacked ms"
}

# Where a line's cover ends, per drug. This is the body of discon_per_med.
#
# A drug's episodes chain forward from the line's start. The run-out is the end
# of the last one reached. The chain breaks only at a drug that would really end
# the line, so a line another drug ended stays where that drug put it.
#
# A confirmed discontinuation of the drug itself breaks it too.
# map_discon_gap_days flags an episode whose gap to the next reaches the
# threshold, and the chain stops at the last episode before that gap. Without
# this a line stretches over its own drug's absence and runs for months with no
# cover.
#
# That is half a rule. Stopping the chain without letting the drug open a line
# leaves the returning treatment belonging to nothing, so
# prior_regimen_excl_sql() releases it. Neither half is safe alone.
#
# What else breaks the chain is kept narrow on purpose. A drug in this line's
# own regimen does not break it. base_meds holds the induction drugs AND their
# permissible substitutes, and neither is a boundary, so a second regimen drug
# refilling mid-line cannot cut the first one's cover short. Steroids never
# break it. `boundary_gate` lets a caller narrow it further, to drugs its own
# rules would accept as a line start.
#
# Transplant and CAR-T are left out on purpose. One that ends a line outranks
# DISCONTINUATION, so a run-out chained past it never shows. One that does not
# end a line - LOT1's induction AUTO, a tandem inside 180 days, CAR-T inside
# LOT1's window - must not break the chain anyway.
#
# LEFT JOIN and aggregates rather than EXISTS. A correlated subquery fails under
# spark.sql.crossJoin.enabled=false.
discon_per_med_sql <- function(start_view, start_col, map_tbl = "map_stacked",
                               boundary_tbl = "map_stacked", boundary_gate = "",
                               end_col = NULL) {
  # The scan starts at the line start. Without this it has no upper bound at
  # all: a base drug's later episodes chain forward for as long as the patient
  # keeps filling it. So bounding regimen membership at the date the line was
  # cut short is only half a fix. A refill of a drug that really IS in the
  # regimen still pushes the run-out past the transplant. Both halves or
  # neither.
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
               -- LOT, so a gap in a substitute's own episodes must not break
               -- the chain either. Let it break here while the start, add-med
               -- and run-out gates all refuse the same drug, and a line ends on
               -- a restart that no line can then own. The treatment would
               -- belong to nothing. All four paths read one rule.
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
# an allogeneic transplant, or a CAR-T. A tandem is a tandem only if nothing
# happens between the two transplants. The gap alone does not make the pair
# planned, and a patient treated in between was not waiting for a second
# transplant.
#
# One definition, spliced into all five places that ask. The tandem flags at
# LOT1 and at LOT2-5, the next line's AUTO start gate, and the two run-out
# guards that mirror it. Five copies of a rule is how five copies drift apart,
# and a tandem test that disagrees with the gate it mirrors puts a transplant
# in no line at all.
tandem_interrupt_events_sql <- function() "
        SELECT PATID, MAP_START_DT AS dt FROM map_stacked
        WHERE MAP_MED_CLASS <> 'STEROID'
        UNION ALL
        SELECT PATID, TX_DT AS dt FROM tx_allo_cart_dates
        WHERE SCT_TYPE IN ('ALLO', 'CART')"

# Every transplant and CAR-T, with what the tandem test needs beside each one.
#
# Two rules ask which procedures BREAK a line - the melphalan rule, to say
# whether a later course still belongs to it, and the fold-in, to count what
# advanced the line between a returning drug's two doses. Both used to take
# any date in tx_auto_dates or tx_allo_cart_dates past the line's window, and
# that is not the engine's rule: a PLANNED TANDEM continues the line and opens
# nothing. An AUTO in LOT1's window with its tandem partner on day 180 then
# switched the melphalan rule off for the rest of that patient.
#
# PREV_AUTO_DT and N_BETWEEN are what line_break_tandem_pred() below reads.
# ALLO and CAR-T rows carry no previous AUTO, so that predicate never excludes
# them - they always break the line once they are past its window.
line_break_tx_sql <- function() glue("
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
        UNION ALL
        SELECT PATID, TX_DT, cast(NULL AS date) AS PREV_AUTO_DT, 0 AS N_BETWEEN
        FROM tx_allo_cart_dates")

# The planned-tandem exemption, in the same three parts auto_cand and the LOT1
# post-runout guard test: within sct_tandem_days of the AUTO before it, nothing
# in between, and that earlier AUTO inside the line's own window. The last part
# is the ownership condition - a pair whose first transplant the line never
# held was never the line's tandem - and leaving it out would exempt a pair the
# start gate has already decided is not one.
#
# paste0 around the glue, not glue alone: glue trims a template's leading
# newline and this fragment splices straight after another predicate, which
# without it read "... <= mc.EXPO_DTAND NOT (...".
line_break_tandem_pred <- function(cfg, alias, induction_end) paste0("\n", glue("
       AND NOT ({alias}.PREV_AUTO_DT IS NOT NULL
                AND datediff({alias}.TX_DT, {alias}.PREV_AUTO_DT) <= {cfg$sct_tandem_days}
                AND {alias}.N_BETWEEN = 0
                AND {alias}.PREV_AUTO_DT <= {induction_end})"))

# The agents of a patient's EARLIER lines, and their permissible substitutes.
#
# Two rules need the same set and must not drift apart. The fold-in builds its
# fold set from it. The melphalan rule reads it to answer a different question:
# whether the agent starting inside a short course is a NEW one. A drug from an
# earlier line coming back is, in the request's own words, "the returning
# drug" - never a new drug - so it cannot be what confirms a course.
#
# The exploded regimen goes in its own CTE first: LATERAL VIEW and a JOIN in
# one FROM do not survive translation.
prior_lines_regimen_ctes <- function(line_pred, raw = "prior_raw",
                                     out = "prior_meds") glue("
    {raw} AS (
      SELECT ll.PATID, m AS MED_ABBR
      FROM lot_long ll
      LATERAL VIEW explode(split(coalesce(ll.LOT_BASE_MEDS, \'\'), \' \')) e AS m
      WHERE {line_pred} AND m <> \'\'
    ),
    {out} AS (
      SELECT PATID, MED_ABBR FROM {raw}
      UNION
      SELECT p.PATID, ps.substitute_med AS MED_ABBR
      FROM {raw} p
      INNER JOIN permissible_subs ps ON p.MED_ABBR = ps.original_med
    ),")
