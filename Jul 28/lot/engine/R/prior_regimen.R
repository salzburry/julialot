# A drug in the previous line's regimen cannot start the next line while it is
# still running. A later LOT starts on a new MM agent that was not part of the
# previous LOT regimen, and a drug the patient never stopped is not new. Its
# later episodes belong to the line it is already in, so that line's run-out
# chains forward over them.
#
# The engine's OLDER rule released it once discontinued: map_discon_gap_days
# flags the episode whose gap to the next reaches the threshold, and an episode
# after such a gap was a restart that could open a line like any other drug.
# apply_own_return_fold withdraws that release, and CONTRACT pins it TRUE - so
# in the study's build a drug the patient has had before never starts a line,
# whatever the gap. The release survives only for comparison builds. See
# return_release_on() below, which is the one place that decides.
#
# The release and the run-out chain are two halves of one rule and neither is
# safe alone. Release the drug without breaking the chain and a line opens
# inside a line still notionally running. Break the chain without releasing the
# drug and the returning treatment belongs to no line at all. See
# discon_per_med_sql below.

# THE RETURNING-DRUG RELEASE, LOT_RULES.md 4.3 - one definition for all eight
# places that ask, because a guard reading a different rule from the candidate
# it mirrors ends a line on an event the next line then refuses to open on.
#
# apply_own_return_fold FALSE is the engine's older rule: a gap of
# map_discon_gap_days releases the drug, and its next episode opens a line like
# any other agent.
#
# TRUE - what CONTRACT pins - withdraws that. A line advances on an agent that
# was not in the previous regimen, and a drug the patient has had before is not
# one, whatever the gap. Nothing was given in between, so the drug is returning
# to the line it left.
#
# Both halves move together: return_release_sql() withdraws the release, and
# own_gap_breaks_chain() stops discon_per_med breaking the line at the same
# gap.
return_release_on <- function(cfg) !isTRUE(cfg$apply_own_return_fold)

return_release_sql <- function(cfg, restart, base, extra = "") {
  if (!return_release_on(cfg)) return(extra)
  paste0("\n             OR (coalesce(", restart, ".PREV_DISCON, 0) = 1 AND ",
         base, ".SUBSTITUTE_ONLY = 0)", extra)
}

# Whether a drug's OWN gap breaks its line's run-out chain. Off under the
# rule: the line runs over the gap, so the returning episode sits inside the
# line it left rather than in no line at all. Another drug interrupting still
# breaks it - that is the `interrupts` scan, and it is untouched.
own_gap_breaks_chain <- function(cfg) return_release_on(cfg)

# The prior-LOT drugs themselves, added to the set med_cand excludes. Without
# them that set holds only their permissible biosimilar substitutes.
prior_regimen_excl_sql <- function() {
  "
      UNION ALL
      SELECT pma.PATID, pma.MED_ABBR, 0 AS IS_SUB
      FROM prev_meds_array pma"
}

# A line's regimen plus the permissible biosimilar substitutes for it, with
# SUBSTITUTE_ONLY recording WHY each drug is in the set. Four callers need this
# set - LOT1 and LOT2-5 both build their base_meds from it, and both run-out
# guards build the drugs they must not accept from it. They read the same rule,
# so they get it from here. A guard spelling it out differently from the
# candidate set it mirrors ends a line on an event the next line refuses to
# open on. min() so a drug that is both a real regimen drug and somebody's
# substitute counts as the former.
regimen_with_subs_sql <- function(src) {
  paste0("\n",
         "      SELECT PATID, MED_ABBR, min(IS_SUB) AS SUBSTITUTE_ONLY
      FROM (
        SELECT PATID, MED_ABBR, 0 AS IS_SUB
        FROM ", src, "
        UNION ALL
        SELECT im.PATID, ps.substitute_med AS MED_ABBR, 1 AS IS_SUB
        FROM ", src, " im
        INNER JOIN permissible_subs ps ON im.MED_ABBR = ps.original_med
        UNION ALL
        -- ...and the same the other way. A line whose regimen names the
        -- SUBSTITUTE has to exclude the drug it stands in for just as surely:
        -- 4.4 makes the pair one agent whichever half the patient was given
        -- first. Expanding one way only, a patient on a biosimilar in 1L had
        -- the reference product open 2L for them, while the mirror-image
        -- patient stayed in one line.
        SELECT im.PATID, ps.original_med AS MED_ABBR, 1 AS IS_SUB
        FROM ", src, " im
        INNER JOIN permissible_subs ps ON im.MED_ABBR = ps.substitute_med
      )
      GROUP BY PATID, MED_ABBR")
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
                               end_col = NULL, own_gap_breaks = TRUE,
                               base_tbl = "base_meds") {
  # The scan starts at the line start. Without this it has no upper bound at
  # all: a base drug's later episodes chain forward for as long as the patient
  # keeps filling it. So bounding regimen membership at the date the line was
  # cut short is only half a fix. A refill of a drug that really IS in the
  # regimen still pushes the run-out past the transplant. Both halves or
  # neither.
  upper <- if (is.null(end_col)) "" else paste0("
          AND ms.MAP_START_DT <= coalesce(ls.", end_col,
          ", cast('9999-12-31' as date))")
  # Zero throughout when the returning-drug rule is on: a drug's own gap no
  # longer breaks its line, because the episode after it belongs to the line
  # it left rather than to the next one. Another drug interrupting still
  # breaks the chain - that is the `interrupts` scan below, untouched.
  prev_discon <- if (!own_gap_breaks) "cast(0 AS int) AS PREV_DISCON" else
    "CASE WHEN bm.SUBSTITUTE_ONLY = 1 THEN 0 ELSE
                 coalesce(lag(ms.MAP_DISCON_FLG) OVER (PARTITION BY ms.PATID, ms.MAP_MED_TYPE
                                          ORDER BY ms.MAP_START_DT), 0) END AS PREV_DISCON"
  paste0("
      WITH ep AS (
        SELECT ms.PATID, ms.MAP_MED_TYPE, ms.MAP_START_DT, ms.MAP_END_DT,
               -- Where the interrupt scan for THIS episode starts. Normally
               -- the drug's own previous episode. NULL for a first episode -
               -- the scan finds nothing and the chain is unbroken - with one
               -- exception: a drug that is in base_meds ONLY as a permissible
               -- substitute need never have been given in this line at all,
               -- so its first episode here can sit long after the regimen
               -- stopped, with another drug in between. That one scans from
               -- the line's start.
               --
               -- A real regimen drug needs no such widening, and giving it
               -- one is not free: its first episode starts inside the
               -- induction window by construction, and any non-steroid drug
               -- starting before that is in the window too, so it is in
               -- base_meds and could never be a boundary. Widening every row
               -- turned a narrow range join into one that spilled gigabytes
               -- on six hundred patients.
               CASE WHEN bm.SUBSTITUTE_ONLY = 1
                    THEN coalesce(lag(ms.MAP_END_DT) OVER (PARTITION BY ms.PATID, ms.MAP_MED_TYPE
                                             ORDER BY ms.MAP_START_DT),
                                  ls.", start_col, ")
                    ELSE lag(ms.MAP_END_DT) OVER (PARTITION BY ms.PATID, ms.MAP_MED_TYPE
                                             ORDER BY ms.MAP_START_DT)
               END AS SCAN_FROM,
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
               ", prev_discon, "
        FROM ", map_tbl, " ms
        INNER JOIN ", start_view, " ls ON ms.PATID = ls.PATID
        INNER JOIN ", base_tbl, " bm ON ms.PATID = bm.PATID AND ms.MAP_MED_TYPE = bm.MED_ABBR
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
              -- SCAN_FROM, not PREV_END. A drug in base_meds need not have
              -- been given in this line at all: base_meds carries the
              -- permissible substitutes of the regimen, and a patient may
              -- take one only much later. Scanning only between a drug's OWN
              -- episodes left that drug's single distant episode with no
              -- interval to look in, so nothing could break its chain and the
              -- line's run-out reached it. The line then ran months past its
              -- own treatment, and a biosimilar return ended the line
              -- somewhere the drug it stands in for would not.
              AND o.MAP_START_DT >  e.SCAN_FROM
              AND o.MAP_START_DT <  e.MAP_START_DT
              ", boundary_gate, "
        LEFT JOIN ", base_tbl, " obm
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
        SELECT p.PATID, p.TX_DT, 'AUTO' AS SCT_KIND, p.PREV_AUTO_DT,
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
        SELECT PATID, TX_DT, SCT_TYPE AS SCT_KIND,
               cast(NULL AS date) AS PREV_AUTO_DT, 0 AS N_BETWEEN
        FROM tx_allo_cart_dates")

# When one of those transplants BREAKS the line, by kind. Three kinds, three
# rules, and the engine states each; reading one window over all of them is
# what this replaces.
#
#   AUTO   past the line own induction window, and not a planned tandem:
#          within sct_tandem_days of the AUTO before it, nothing in between,
#          and that earlier AUTO inside the window. All three are what
#          auto_cand and the LOT1 post-runout guard test, ownership condition
#          included - a pair whose first transplant the line never held was
#          never the line tandem.
#
#   ALLO   strictly after the line START, no window. That is how
#          lot{n}_regimen_cutoff cuts a regimen, and how LOT1 does it too.
#
#   CART   the same at LOT2-5. At LOT1 the induction rule (LOT_RULES.md 6.4)
#          keeps a CAR-T INSIDE the window as part of the line, so there it
#          breaks only past the window - cart_from carries which of the two
#          dates applies. Outside the window a CAR-T opens the next line at
#          LOT1 as anywhere else.
#
# paste0 around the glue, not glue alone: glue trims a template leading
# newline and this fragment splices straight after another predicate, which
# without it read "... <= mc.EXPO_DTAND NOT (...".
line_break_window_pred <- function(cfg, alias, induction_end, line_start,
                                   cart_from = NULL) {
  cart <- if (is.null(cart_from) || identical(cart_from, line_start)) "" else
    paste0("\n                 AND (", alias, ".SCT_KIND <> 'CART' OR ",
           alias, ".TX_DT > ", cart_from, ")")
  paste0("\n       AND ((", alias, ".SCT_KIND = 'AUTO'
                 AND ", alias, ".TX_DT > ", induction_end, "
                 AND NOT (", alias, ".PREV_AUTO_DT IS NOT NULL
                          AND datediff(", alias, ".TX_DT, ", alias,
                              ".PREV_AUTO_DT) <= ", cfg$sct_tandem_days, "
                          AND ", alias, ".N_BETWEEN = 0
                          AND ", alias, ".PREV_AUTO_DT <= ", induction_end, "))
            OR (", alias, ".SCT_KIND <> 'AUTO'
                 AND ", alias, ".TX_DT > ", line_start, cart, "))")
}

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
    -- Each regimen drug under its AGENT. A drug that IS a permissible
    -- substitute collapses to the one it replaces, so the set below is the
    -- same whichever half of the pair the regimen happens to name.
    {raw}_agent AS (
      SELECT DISTINCT p.PATID, coalesce(ps.original_med, p.MED_ABBR) AS AGENT
      FROM {raw} p
      LEFT JOIN permissible_subs ps ON ps.substitute_med = p.MED_ABBR
    ),
    -- Every drug that IS one of those agents: the agent itself, and every
    -- permissible substitute for it. Expanding the raw regimen instead was
    -- one-directional - a regimen naming the reference product picked up its
    -- substitute, but a regimen naming the substitute did not pick up the
    -- reference product, so the same pair folded one way and not the other.
    -- §4.4 makes them one agent, so both directions have to read the same.
    {out} AS (
      SELECT PATID, AGENT AS MED_ABBR FROM {raw}_agent
      UNION
      SELECT a.PATID, ps.substitute_med AS MED_ABBR
      FROM {raw}_agent a
      INNER JOIN permissible_subs ps ON ps.original_med = a.AGENT
    ),")
