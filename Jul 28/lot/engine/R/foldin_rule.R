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
#   one agent opened a line       -> the return does NOT start a line. It is
#                                    bundled into the line it returns in.
#   two or more different agents  -> the return DOES start a line. Treatment
#                                    has moved on twice; the drug is not
#                                    coming back to the line it left.
#   no agent did                  -> not this rule's case. Nothing moved, so
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
# What is counted is DIFFERENT AGENTS that opened a line, which is the request
# in its own words: "two or more different agents were introduced in between".
# So a line is read through the drug that started it, and two things follow
# that counting LINES did not do:
#
#   one agent that opens two lines is ONE agent. A drug opening a line,
#   discontinuing, and opening another on a released restart (§4.3) used to
#   count twice and refuse the fold. It counts once.
#
#   a line opened by a TRANSPLANT or CAR-T has no agent, so it counts nothing.
#   A drug returning into an ALLO or CAR-T line therefore sees no advance at
#   all, and the engine's ordinary restart rule keeps it.
#
# The second is a consequence of the wording rather than an aim of it, and it
# is written down in STUDY_TEAM_ASKS.md as such.
#
# count = 0 is not the request's case at all: nothing advanced the line, so the
# drug is returning to the line it left, and that is the engine's ordinary
# restart rule. Left alone. Only 1 folds.
#
# `n_start` and `n_tbl` name the line being built, so its own start counts as
# an advance too - lot_long does not hold it yet. The start-candidate statement
# has no such line and passes NULL.
foldin_count_ctes <- function(cfg, discon_days, n_start = NULL, n_tbl = NULL,
                              n_induction = NULL, n_type = NULL,
                              meds = "foldin_meds",
                              line_pred, melp_on = FALSE) {
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
                          WHERE msd.PATID = ms.PATID
                            AND msd.SUPPRESS_DT = ms.MAP_START_DT)"
  # The line being built is not in lot_long yet, so its own opener is unioned
  # into the set below. The start-candidate statement has no such line.
  this_line <- if (is.null(n_start) || is.null(n_type)) "" else paste0("
      UNION
      SELECT ", n_tbl, ".PATID, ", n_start, " AS OPEN_DT,
             coalesce(ps.original_med, ms.MAP_MED_TYPE) AS OPENER
      FROM ", n_tbl, "
      INNER JOIN map_stacked ms
        ON ms.PATID = ", n_tbl, ".PATID AND ms.MAP_START_DT = ", n_start, "
       AND ms.MAP_MED_CLASS <> 'STEROID'
      LEFT JOIN permissible_subs ps ON ps.substitute_med = ms.MAP_MED_TYPE
      WHERE ", n_type, " = 'MED'")
  # paste0, not glue: glue trims a template's leading newline, and this
  # fragment splices straight after a table alias - without it the statement
  # read "FROM foldin_course_prev kINNER JOIN ...".
  join_n <- if (is.null(n_tbl)) "" else
    paste0("\n      INNER JOIN ", n_tbl, " ON ", n_tbl, ".PATID = k.PATID")
  # The in-this-line test, and only where there IS a line being built. The
  # start-candidate statement has none, and needs none: lot_long has grown by
  # the time it judges a later line, so its count is already the whole history.
  #
  # Procedures are in it as well as medications. Scanning map_stacked alone
  # left the same hole the melphalan rule had: a CAR-T opening the next line
  # is not a medication row, so an earlier line went on claiming a return that
  # arrived after it, and that line's own discontinuation became the
  # procedure's end reason.
  #
  # The two arms are bounded differently, and each takes the bound its own
  # rule uses. A DRUG that is neither this line's regimen nor a fold-set agent
  # is a boundary from the line's START. A TRANSPLANT is one only past the
  # line's INDUCTION END, because a transplant inside a line's own window
  # belongs to it and opens nothing (LOT_RULES.md 3.4 and 6.5) - the same
  # bound melp_taken uses, off the same lotn_induction_end(). Bounding both
  # arms at the start, as one shared condition did, made an in-window
  # transplant refuse a fold the line should have taken.
  induction <- if (is.null(n_induction)) n_start else n_induction
  between_sel <- if (is.null(n_start)) "" else
    ",\n             max(CASE WHEN o.PATID IS NOT NULL THEN 1 ELSE 0 END) AS N_BETWEEN"
  between_pred <- if (is.null(n_start)) "" else " AND N_BETWEEN = 0"
  between_join <- if (is.null(n_start)) "" else paste0("
      LEFT JOIN (
        SELECT ms.PATID, ms.MAP_START_DT AS AT_DT
        FROM map_stacked ms
        INNER JOIN ", n_tbl, " ON ", n_tbl, ".PATID = ms.PATID
        WHERE ms.MAP_MED_CLASS <> 'STEROID'
          AND ms.MAP_START_DT > ", n_start, "
          AND NOT EXISTS (SELECT 1 FROM base_meds ob
                          WHERE ob.PATID = ms.PATID
                            AND ob.MED_ABBR = ms.MAP_MED_TYPE)
          AND NOT EXISTS (SELECT 1 FROM ", meds, " ofm
                          WHERE ofm.PATID = ms.PATID
                            AND ofm.MED_ABBR = ms.MAP_MED_TYPE)", not_supp, "
        UNION
        -- A planned tandem continues the line and opens nothing, so it is no
        -- advance either. Same helper the melphalan rule reads, so the two
        -- rules cannot disagree about which transplants are a boundary. The
        -- line table is joined in here because both the window bound and the
        -- tandem's own ownership test need this line's window.
        SELECT tx.PATID, tx.TX_DT AS AT_DT
        FROM (", line_break_tx_sql(), "
        ) tx
        INNER JOIN ", n_tbl, " ON ", n_tbl, ".PATID = tx.PATID
        WHERE tx.TX_DT > ", induction,
        line_break_tandem_pred(cfg, "tx", induction), "
      ) o
        ON o.PATID = k.PATID
       AND o.AT_DT <  k.MAP_START_DT")
  glue("
    -- Every episode of a fold-set drug, under the AGENT it belongs to. A
    -- permissible substitute is the same agent as the drug it replaces, so
    -- the pair shares one history: partitioned by the raw abbreviation, a
    -- substitute's first appearance had no previous dose at all and folded
    -- where the drug it replaces would not have.
    foldin_agent AS (
      SELECT ms.PATID, ms.MAP_MED_TYPE, ms.MAP_START_DT, min(ms.MAP_END_DT) AS MAP_END_DT,
             coalesce(min(ps.original_med), ms.MAP_MED_TYPE) AS AGENT
      FROM map_stacked ms
      INNER JOIN {meds} fm
        ON fm.PATID = ms.PATID AND fm.MED_ABBR = ms.MAP_MED_TYPE
      LEFT JOIN permissible_subs ps ON ps.substitute_med = ms.MAP_MED_TYPE
      GROUP BY ms.PATID, ms.MAP_MED_TYPE, ms.MAP_START_DT
    ),
    -- A COURSE is episodes of one agent with no discontinuation between them -
    -- the engine's own {discon_days}-day gap. It does not decide the fold; it
    -- CARRIES it. A returning course was being split between two owners: its
    -- first episode folded, and its own follow-up weeks later had no advance
    -- behind it, so it was judged separately, not folded, and opened a line.
    -- One course, one answer.
    -- Two steps, because a window function cannot be nested inside another.
    foldin_runs AS (
      SELECT PATID, MAP_MED_TYPE, MAP_START_DT, AGENT,
             CASE WHEN datediff(MAP_START_DT,
                    lag(MAP_END_DT) OVER (PARTITION BY PATID, AGENT
                                          ORDER BY MAP_START_DT))
                       >= {discon_days} THEN 1 ELSE 0 END AS IS_RETURN
      FROM foldin_agent
    ),
    foldin_course AS (
      SELECT PATID, MAP_MED_TYPE, MAP_START_DT, AGENT,
             min(MAP_START_DT) OVER (PARTITION BY PATID, AGENT, R) AS COURSE_START_DT
      FROM (SELECT PATID, MAP_MED_TYPE, MAP_START_DT, AGENT,
                   sum(IS_RETURN) OVER (PARTITION BY PATID, AGENT
                                        ORDER BY MAP_START_DT
                                        ROWS BETWEEN UNBOUNDED PRECEDING
                                                 AND CURRENT ROW) AS R
            FROM foldin_runs) q
    ),
    -- Every episode beside the agent's PREVIOUS one. That pair is the
    -- request's two doses, and the interval between them is what the count
    -- reads - dose to dose, not stop to return.
    foldin_epi AS (
      SELECT c.PATID, c.MAP_MED_TYPE, c.MAP_START_DT, c.AGENT, c.COURSE_START_DT,
             lag(c.MAP_START_DT) OVER (PARTITION BY c.PATID, c.AGENT
                                       ORDER BY c.MAP_START_DT) AS PREV_COURSE_DT
      FROM foldin_course c
    ),
    -- The AGENT that opened each line. The request counts two or more
    -- different AGENTS, not lines, so a line is read through the drug that
    -- started it: the non-steroid medication dosed on its start date.
    --
    -- Two consequences of taking that wording literally, both intended:
    -- a line opened by a transplant or CAR-T has no agent and contributes
    -- nothing to the count, and one agent that opens two lines is still one
    -- agent. A permissible substitute collapses to the drug it replaces -
    -- §4.4 already says a substitution is not a change of agent.
    foldin_openers AS (
      SELECT DISTINCT l.PATID, l.LOT_START_DT AS OPEN_DT,
             coalesce(ps.original_med, ms.MAP_MED_TYPE) AS OPENER
      FROM lot_long l
      INNER JOIN map_stacked ms
        ON ms.PATID = l.PATID AND ms.MAP_START_DT = l.LOT_START_DT
       AND ms.MAP_MED_CLASS <> 'STEROID'
      LEFT JOIN permissible_subs ps ON ps.substitute_med = ms.MAP_MED_TYPE
      WHERE l.LOT_START_TYPE = 'MED' AND {line_pred}{this_line}
    ),
    -- How many different agents opened a line strictly between the two doses.
    -- A LEFT JOIN and a count, not a correlated subquery: the translation has
    -- to survive Spark and the harness alike. count(DISTINCT) rather than
    -- count(): the in-this-line join beside it multiplies rows, and distinct
    -- is what the request asks for anyway.
    foldin_counted AS (
      SELECT k.PATID, k.AGENT, k.COURSE_START_DT, k.MAP_START_DT,
             count(DISTINCT fo.OPENER) AS N_ADVANCES{between_sel}
      FROM foldin_epi k{join_n}
      LEFT JOIN foldin_openers fo
        ON fo.PATID = k.PATID
       AND fo.OPEN_DT >  k.PREV_COURSE_DT
       AND fo.OPEN_DT <  k.MAP_START_DT{between_join}
      WHERE k.PREV_COURSE_DT IS NOT NULL
      GROUP BY k.PATID, k.AGENT, k.COURSE_START_DT, k.MAP_START_DT
    ),
    -- A course folds if any of its episodes does, and then all of them do.
    foldin_folded AS (
      SELECT DISTINCT PATID, AGENT, COURSE_START_DT
      FROM foldin_counted
      WHERE N_ADVANCES = 1{between_pred}
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
    -- Same shape as melp_taken in R/melp_rule.R, for the same reason.
    foldin_episodes AS (
      SELECT c.PATID, c.MAP_MED_TYPE AS MED_ABBR, c.MAP_START_DT
      FROM foldin_course c
      INNER JOIN foldin_folded f
        ON f.PATID = c.PATID AND f.AGENT = c.AGENT
       AND f.COURSE_START_DT = c.COURSE_START_DT
    ),")
}

foldin_lotn_ctes <- function(cfg, lot_num, induction_end = NULL) {
  if (!foldin_on(cfg)) return("")
  # Built out here: a nested glue() inside the template below does not parse,
  # because the inner quotes close the outer one.
  count_ctes <- foldin_count_ctes(
    cfg         = cfg,
    discon_days = cfg$map_discon_gap_days,
    n_start     = glue("lot{lot_num}_start.LOT{lot_num}_START_DT"),
    n_tbl       = glue("lot{lot_num}_start"),
    n_induction = induction_end,
    n_type      = glue("lot{lot_num}_start.LOT{lot_num}_START_TYPE"),
    line_pred   = glue("l.LOT_NUM < {lot_num}"),
    melp_on     = melp_rule_on(cfg))
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
  count_ctes <- foldin_count_ctes(cfg, discon_days = cfg$map_discon_gap_days,
                                  meds = "foldin_sc_meds",
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
