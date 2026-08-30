# The MAP fold-in rule. Off unless APPLY_MAP_FOLDIN is TRUE. Off, every hook
# here emits nothing, so the contract build's SQL is unchanged.
#
# The rule, from the study team: a patient on drug A + drug B in one line,
# advanced to the next line by a new drug C, whose drug B then reappears after
# that next line's induction window - B should be PART of the line it
# reappears in, not a reason to start another one.
#
# THE COUNT, from their 20 Aug refinement, is what decides it. Look at what was
# given between the drug's two doses:
#
#   one agent advanced the line   -> the return does NOT start a line. It is
#                                    bundled into the line it returns in.
#   two or more advanced it       -> the return DOES start a line. Treatment
#                                    has moved on twice; the drug is not
#                                    coming back to the line it left.
#   none advanced it              -> not this rule's case. Nothing moved, so
#                                    the drug is returning to the line it left
#                                    and the engine's own restart rule keeps it.
#
# So the fold is per EPISODE, not per drug: the same drug can fold on one
# return and open a line on the next. foldin_count_ctes() below does the
# counting, and everything else reads foldin_episodes.
#
# In engine terms, for each line from LOT2 up:
#
#   the FOLD SET is every agent of every EARLIER line's regimen, and their
#   permissible substitutes - except agents that are also in this line's own
#   base set, which keep the engine's own rules (a drug in both regimens is
#   this line's drug, and its restarts are the engine's ordinary open
#   question, not this rule's) - and then only the EPISODES the count folds.
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
# THE COUNT. The study team's 20 Aug refinement: a returning drug folds only
# when ONE agent advanced the line between its two doses. Two or more advances
# and the return starts a line of its own - the treatment has moved far enough
# that the drug is not coming back to the line it left.
#
# So the fold set is per EPISODE, not per drug. The same drug can fold on one
# return and start a line on the next.
#
# The interval is dose to dose, as the request words it, and NOT cover end to
# dose. A drug's cover often runs past the line it belonged to, so measuring
# from where it stopped would put the advance that ended that line BEFORE the
# interval and count zero - which is the request's own example, and it must
# fold.
#
# What counts as an advance is a LINE that opened in between. That is the
# parenthetical "advancing the LOT" read directly: a line is what an advance
# produces, whatever opened it. A transplant-started line counts, which the
# request does not say in words - it says "agents" - and is the reading to put
# back to the study team.
#
# count = 0 is not the request's case at all: nothing advanced the line, so the
# drug is returning to the line it left, and that is the engine's ordinary
# restart rule. Left alone. Only 1 folds.
#
# `n_start` and `n_tbl` name the line being built, so its own start counts as
# an advance too - lot_long does not hold it yet. The start-candidate statement
# has no such line and passes NULL.
foldin_count_ctes <- function(n_start = NULL, n_tbl = NULL,
                              meds = "foldin_meds", line_pred,
                              melp_on = FALSE) {
  # A melphalan course the melphalan rule SUPPRESSED is not a line-defining
  # agent - that rule has already decided it opens nothing - so it must not
  # disqualify a return from folding either. Without this the two rules
  # disagree about the same episode: one says it defines no boundary, the
  # other counts it as the agent that arrived first.
  #
  # This is the only direction that can be read here. The melphalan CTEs are
  # spliced BEFORE these, so this side may consult them; the reverse would
  # need melphalan to consult the fold, and each rule reading the other has no
  # order that works. What remains is written down in STUDY_TEAM_ASKS.md.
  not_supp <- if (!melp_on) "" else "
       AND NOT EXISTS (SELECT 1 FROM melp_suppress_dates msd
                       WHERE msd.PATID = o.PATID
                         AND msd.SUPPRESS_DT = o.MAP_START_DT)"
  this_line <- if (is.null(n_start)) "0" else glue(
    "max(CASE WHEN {n_start} >  e.PREV_DOSE_DT
                AND {n_start} <  e.MAP_START_DT THEN 1 ELSE 0 END)")
  # paste0, not glue: glue trims a template's leading newline, and this
  # fragment splices straight after a table alias - without it the statement
  # read "FROM foldin_epi eINNER JOIN ...".
  join_n <- if (is.null(n_tbl)) "" else
    paste0("\n      INNER JOIN ", n_tbl, " ON ", n_tbl, ".PATID = e.PATID")
  # The in-this-line test, and only where there IS a line being built. The
  # start-candidate statement has none, and needs none: lot_long has grown by
  # the time it judges a later line, so its count is already the whole history.
  between_sel <- if (is.null(n_start)) "" else
    ",\n             max(CASE WHEN o.PATID IS NOT NULL THEN 1 ELSE 0 END) AS N_BETWEEN"
  between_pred <- if (is.null(n_start)) "" else " AND N_BETWEEN = 0"
  between_join <- if (is.null(n_start)) "" else paste0("
      LEFT JOIN map_stacked o
        ON o.PATID = e.PATID
       AND o.MAP_START_DT >  ", n_start, "
       AND o.MAP_START_DT <  e.MAP_START_DT
       AND o.MAP_MED_CLASS <> 'STEROID'
       AND NOT EXISTS (SELECT 1 FROM base_meds ob
                       WHERE ob.PATID = o.PATID AND ob.MED_ABBR = o.MAP_MED_TYPE)
       AND NOT EXISTS (SELECT 1 FROM ", meds, " ofm
                       WHERE ofm.PATID = o.PATID
                         AND ofm.MED_ABBR = o.MAP_MED_TYPE)", not_supp)
  glue("
    -- Every episode of a fold-set drug, under the AGENT it belongs to. A
    -- permissible substitute is the same agent as the drug it replaces, so
    -- the pair has to share one dose history: partitioned by the raw
    -- abbreviation, a substitute's first appearance had no previous dose at
    -- all, its interval was undefined, and it folded where the drug it
    -- replaces would have.
    foldin_agent AS (
      SELECT ms.PATID, ms.MAP_MED_TYPE, ms.MAP_START_DT,
             coalesce(min(ps.original_med), ms.MAP_MED_TYPE) AS AGENT
      FROM map_stacked ms
      INNER JOIN {meds} fm
        ON fm.PATID = ms.PATID AND fm.MED_ABBR = ms.MAP_MED_TYPE
      LEFT JOIN permissible_subs ps ON ps.substitute_med = ms.MAP_MED_TYPE
      GROUP BY ms.PATID, ms.MAP_MED_TYPE, ms.MAP_START_DT
    ),
    foldin_epi AS (
      SELECT a.PATID, a.MAP_MED_TYPE, a.MAP_START_DT,
             lag(a.MAP_START_DT) OVER (PARTITION BY a.PATID, a.AGENT
                                       ORDER BY a.MAP_START_DT) AS PREV_DOSE_DT
      FROM foldin_agent a
    ),
    -- How many lines opened strictly between the two doses. A LEFT JOIN and a
    -- count, not a correlated subquery: the translation has to survive Spark
    -- and the harness alike.
    foldin_counted AS (
      SELECT e.PATID, e.MAP_MED_TYPE, e.MAP_START_DT,
             count(l.LOT_NUM) + {this_line} AS N_ADVANCES{between_sel}
      FROM foldin_epi e{join_n}
      LEFT JOIN lot_long l
        ON l.PATID = e.PATID AND {line_pred}
       AND l.LOT_START_DT >  e.PREV_DOSE_DT
       AND l.LOT_START_DT <  e.MAP_START_DT{between_join}
      WHERE e.PREV_DOSE_DT IS NOT NULL
      GROUP BY e.PATID, e.MAP_MED_TYPE, e.MAP_START_DT
    ),
    -- Exactly one advance, and the return has to be in THIS line.
    --
    -- The count is line-relative while the lines are being built: at LOT2 only
    -- LOT2 has opened, at LOT3 both LOT2 and LOT3 have. Without the second
    -- test the same return folded into LOT2 (count 1 there) and started a
    -- line at LOT3 (count 2), and LOT2's end reason changed from its own
    -- discontinuation to the next line's addition for a drug that never
    -- joined it.
    --
    -- So a return with another line-defining agent between this line's start
    -- and itself belongs to a later line, and this one does not claim it.
    -- Same shape as melp_taken in R/melp_rule.R, for the same reason.
    foldin_episodes AS (
      SELECT PATID, MAP_MED_TYPE AS MED_ABBR, MAP_START_DT
      FROM foldin_counted WHERE N_ADVANCES = 1{between_pred}
    ),")
}

foldin_lotn_ctes <- function(cfg, lot_num) {
  if (!foldin_on(cfg)) return("")
  # Built out here: a nested glue() inside the template below does not parse,
  # because the inner quotes close the outer one.
  count_ctes <- foldin_count_ctes(
    n_start   = glue("lot{lot_num}_start.LOT{lot_num}_START_DT"),
    n_tbl     = glue("lot{lot_num}_start"),
    line_pred = glue("l.LOT_NUM < {lot_num}"),
    melp_on   = melp_rule_on(cfg))
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
{count_ctes}
    -- What may interrupt a base drug's run-out chain, with the folded drugs
    -- taken out: a returning prior-line agent is part of this line under the
    -- rule, and part of the line breaks nothing. Own-base rows are kept -
    -- the interrupt scan already excludes them itself, so keeping them
    -- leaves that path byte-for-byte the engine's.
    foldin_boundary_src AS (
      SELECT ms.*
      FROM map_stacked ms
      LEFT JOIN foldin_episodes fm
        ON fm.PATID = ms.PATID AND fm.MED_ABBR = ms.MAP_MED_TYPE
       AND fm.MAP_START_DT = ms.MAP_START_DT
      LEFT JOIN base_meds bm2
        ON bm2.PATID = ms.PATID AND bm2.MED_ABBR = ms.MAP_MED_TYPE
      WHERE fm.MED_ABBR IS NULL OR bm2.MED_ABBR IS NOT NULL
    ),
    foldin_hold AS (
      SELECT ms.PATID,
             max(least(ms.MAP_END_DT, ls.OBS_END_DT)) AS FOLDIN_HOLD_DT
      FROM map_stacked ms
      INNER JOIN lot{lot_num}_start ls ON ls.PATID = ms.PATID
      INNER JOIN foldin_episodes fm
        ON fm.PATID = ms.PATID AND fm.MED_ABBR = ms.MAP_MED_TYPE
       AND fm.MAP_START_DT = ms.MAP_START_DT
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
                 AND EXISTS (SELECT 1 FROM foldin_episodes fm
                             WHERE fm.PATID = ms.PATID
                               AND fm.MED_ABBR = ms.MAP_MED_TYPE
                               AND fm.MAP_START_DT = ms.MAP_START_DT))"))
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
  # The same count, over the lines lot_long holds at this point - 1..prev. The
  # line being started does not exist yet, so there is no own-start term.
  count_ctes <- foldin_count_ctes(meds = "foldin_sc_meds",
                                  line_pred = glue("l.LOT_NUM <= {prev}"))
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
    ),
{count_ctes}"))
}

# An older line's agent never starts a line while the rule is on - it belongs
# to the line it returned in, which the hold above has already stretched over
# it.
foldin_trigger_predicate <- function(cfg) {
  if (!foldin_on(cfg)) return("")
  paste0("\n", glue("
        AND NOT EXISTS (SELECT 1 FROM foldin_episodes fm
                        WHERE fm.PATID = ms.PATID
                          AND fm.MED_ABBR = ms.MAP_MED_TYPE
                          AND fm.MAP_START_DT = ms.MAP_START_DT)"))
}
