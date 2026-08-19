# The MAP fold-in rule. Off unless APPLY_MAP_FOLDIN is TRUE. Off, every hook
# here emits nothing, so the contract build's SQL is unchanged.
#
# The rule, from the study team: a patient on drug A + drug B in one line,
# advanced to the next line by a new drug C, whose drug B then reappears after
# that next line's induction window - B should be PART of the line it
# reappears in, not a reason to start another one.
#
# In engine terms, for each line from LOT2 up:
#
#   the FOLD SET is every agent of every EARLIER line's regimen, and their
#   permissible substitutes - except agents that are also in this line's own
#   base set, which keep the engine's own rules (a drug in both regimens is
#   this line's drug, and its restarts are the engine's ordinary open
#   question, not this rule's).
#
#   SUPPRESS   a fold-set episode is never an added-medication candidate, so
#              it cannot end the line - released restart or not. The release
#              exists to solve ownership, and this rule solves ownership the
#              other way (the hold below), so it is switched off for these
#              drugs.
#
#   NEVER TRIGGER   a fold-set drug of the lines BEFORE the previous one
#              cannot start the next line either. The previous line's own
#              regimen keeps today's exclusion-with-release: a drug restarting
#              with no newer line in between is the engine's ordinary restart
#              rule, which the study team has not asked to change.
#
#   HOLD       suppressing and owning are two halves of one statement. The
#              line's run-out is carried to the last day any folded episode's
#              supply reaches (capped at observation), so the treatment the
#              rule refuses a line to still sits inside a line. Same shape as
#              melp_hold in R/melp_rule.R, and it rides the same runout so the
#              whole end cascade - confirmation, death, a real addition in
#              between - still applies.
#
#   CHAIN      a folded episode must not break a base drug's run-out chain
#              either: discon_per_med's interrupt scan reads a boundary source
#              with the folded drugs taken out.
#
# What this deliberately does NOT change: LOT1 (it has no earlier line);
# transplant and CAR-T triggers; the tandem-interrupt rule (whether a folded
# drug still breaks a planned tandem is a separate open question); and the
# regimen itself - a folded drug does not join LOT_BASE_MEDS, exactly as a
# held melphalan dose does not. The line's span owns it; its window does not
# rename it.
#
# Pinned FALSE in CONTRACT. A TRUE build records the deviation in
# LOT_BUILD_STATUS and every reader that resolves run ownership refuses it as
# the study's. Built and measured by exploration/lot/run_foldin_cells.R.

foldin_on <- function(cfg) isTRUE(cfg$apply_map_foldin)

# The fold set and the hold, for the statement that builds line N's base.
# lot_long holds lines 1..N-1 at this point, so "every earlier line" is a
# scan of it. The exploded regimen goes in its own CTE first: LATERAL VIEW
# and a JOIN in one FROM do not survive translation.
#
# base_meds and lot{n}_start are this statement's own; the hold keeps
# own-base drugs out so a drug in both regimens stays under the engine's
# rules, and takes episodes STARTING in the line - an episode already running
# when the line began belongs to the line that collected it.
foldin_lotn_ctes <- function(cfg, lot_num) {
  if (!foldin_on(cfg)) return("")
  paste0("\n", glue("
    foldin_prev AS (
      SELECT ll.PATID, m AS MED_ABBR
      FROM lot_long ll
      LATERAL VIEW explode(split(coalesce(ll.LOT_BASE_MEDS, ''), ' ')) e AS m
      WHERE ll.LOT_NUM < {lot_num} AND m <> ''
    ),
    foldin_meds AS (
      SELECT PATID, MED_ABBR FROM foldin_prev
      UNION
      SELECT p.PATID, ps.substitute_med AS MED_ABBR
      FROM foldin_prev p
      INNER JOIN permissible_subs ps ON p.MED_ABBR = ps.original_med
    ),
    -- What may interrupt a base drug's run-out chain, with the folded drugs
    -- taken out: a returning prior-line agent is part of this line under the
    -- rule, and part of the line breaks nothing. Own-base rows are kept -
    -- the interrupt scan already excludes them itself, so keeping them
    -- leaves that path byte-for-byte the engine's.
    foldin_boundary_src AS (
      SELECT ms.*
      FROM map_stacked ms
      LEFT JOIN foldin_meds fm
        ON fm.PATID = ms.PATID AND fm.MED_ABBR = ms.MAP_MED_TYPE
      LEFT JOIN base_meds bm2
        ON bm2.PATID = ms.PATID AND bm2.MED_ABBR = ms.MAP_MED_TYPE
      WHERE fm.MED_ABBR IS NULL OR bm2.MED_ABBR IS NOT NULL
    ),
    foldin_hold AS (
      SELECT ms.PATID,
             max(least(ms.MAP_END_DT, ls.OBS_END_DT)) AS FOLDIN_HOLD_DT
      FROM map_stacked ms
      INNER JOIN lot{lot_num}_start ls ON ls.PATID = ms.PATID
      INNER JOIN foldin_meds fm
        ON fm.PATID = ms.PATID AND fm.MED_ABBR = ms.MAP_MED_TYPE
      LEFT JOIN base_meds bm
        ON bm.PATID = ms.PATID AND bm.MED_ABBR = ms.MAP_MED_TYPE
      WHERE bm.MED_ABBR IS NULL
        AND ms.MAP_START_DT >= ls.LOT{lot_num}_START_DT
        AND ms.MAP_START_DT <= ls.OBS_END_DT
      GROUP BY ms.PATID
    ),"))
}

# Takes fold-set rows off the added-medication candidate list. Own-base rows
# pass through untouched - bm is first_add_candidates' own join.
foldin_suppress_predicate <- function(cfg) {
  if (!foldin_on(cfg)) return("")
  paste0("\n", glue("
        AND NOT (bm.MED_ABBR IS NULL
                 AND EXISTS (SELECT 1 FROM foldin_meds fm
                             WHERE fm.PATID = ms.PATID
                               AND fm.MED_ABBR = ms.MAP_MED_TYPE))"))
}

# What discon_per_med scans for interrupting drugs. The engine's own source
# when the rule is off.
foldin_boundary_tbl <- function(cfg) {
  if (!foldin_on(cfg)) return("map_stacked") else "foldin_boundary_src"
}

# The carry onto the run-out. A NULL run-out means two different things and
# they are told apart:
#
#   the regimen's cover runs past observation (a discon_per_med row exists,
#   capped away) - the hold must NOT replace it, or the line ends on the
#   folded cover while a base drug is still being taken;
#
#   the line has NO regimen at all - a single-day ALLO, or a CAR-T with no
#   consolidation drug, where discon_per_med produced no row - so there is
#   no run-out to extend and the hold has to SUPPLY one, or the guard below
#   lifts the short-circuit and the line falls through to study end with the
#   folded treatment dangling inside it. F9/F10 in the planted harness pin
#   this shape.
#
# `no_regimen` is the caller's test for the second case; the one call site
# passes the discon_raw join alias.
foldin_runout_case <- function(cfg, col, alias = "fh",
                               no_regimen = "d.PATID IS NULL") {
  if (!foldin_on(cfg)) return(col)
  glue("CASE WHEN {alias}.FOLDIN_HOLD_DT IS NOT NULL
             AND ((({col}) IS NULL AND {no_regimen})
                  OR {alias}.FOLDIN_HOLD_DT > ({col}))
            THEN {alias}.FOLDIN_HOLD_DT
            ELSE {col} END")
}

foldin_hold_col <- function(cfg, alias = "fh") {
  if (!foldin_on(cfg)) return("")
  paste0("\n", glue("        {alias}.FOLDIN_HOLD_DT,"))
}

foldin_hold_join <- function(cfg, on_alias, alias = "fh") {
  if (!foldin_on(cfg)) return("")
  paste0("\n", glue("      LEFT JOIN foldin_hold {alias} ON {on_alias}.PATID = {alias}.PATID"))
}

# A line whose type ends it on its own start date - a single-day ALLO, or a
# CAR-T line with no consolidation drug - is short-circuited before any
# run-out is read, so a hold hanging on the run-out could not reach it and
# the folded treatment would sit in no line. The hold overrides the
# short-circuit, exactly as melp_line_type_guard does - melp_rule.R carries
# the shape's full reasoning - and every other end still outranks the held
# run-out.
foldin_line_type_guard <- function(cfg, lot_num, alias = "ec") {
  if (!foldin_on(cfg)) return("")
  paste0("\n", glue("           AND NOT ({alias}.FOLDIN_HOLD_DT IS NOT NULL
                    AND {alias}.FOLDIN_HOLD_DT > {alias}.LOT{lot_num}_START_DT)"))
}

# The fold set for the NEXT line's start candidates: the lines BEFORE the
# previous one. The previous line's own regimen is already excluded there,
# with the release the engine ships - a drug restarting with no newer line in
# between stays the engine's ordinary restart, untouched by this rule.
foldin_prior_ctes <- function(cfg, prev) {
  if (!foldin_on(cfg)) return("")
  paste0("\n", glue("
    foldin_sc_prev AS (
      SELECT ll.PATID, m AS MED_ABBR
      FROM lot_long ll
      LATERAL VIEW explode(split(coalesce(ll.LOT_BASE_MEDS, ''), ' ')) e AS m
      WHERE ll.LOT_NUM < {prev} AND m <> ''
    ),
    foldin_sc_meds AS (
      SELECT PATID, MED_ABBR FROM foldin_sc_prev
      UNION
      SELECT p.PATID, ps.substitute_med AS MED_ABBR
      FROM foldin_sc_prev p
      INNER JOIN permissible_subs ps ON p.MED_ABBR = ps.original_med
    ),"))
}

# An older line's agent never starts a line while the rule is on - it belongs
# to the line it returned in, which the hold above has already stretched over
# it.
foldin_trigger_predicate <- function(cfg) {
  if (!foldin_on(cfg)) return("")
  paste0("\n", glue("
        AND NOT EXISTS (SELECT 1 FROM foldin_sc_meds fm
                        WHERE fm.PATID = ms.PATID
                          AND fm.MED_ABBR = ms.MAP_MED_TYPE)"))
}
