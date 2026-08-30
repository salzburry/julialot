# The MAP fold-in rule - LOT_RULES.md 4.8. CONTRACT pins APPLY_MAP_FOLDIN TRUE,
# so the study's build runs it. Set FALSE - which only a comparison cell does -
# every hook here emits nothing and the statements are what they were before
# this file.
#
# The rule in one sentence: a drug of the IMMEDIATELY PREVIOUS line that comes
# back joins the line it returns in rather than starting one, when exactly one
# agent opened a line between its two doses. Two or more and it starts a line;
# none and this rule says nothing. LOT_RULES.md 4.8 has the wording, the worked
# examples and the boundaries; this file is how it is measured.
#
# The FOLD SET is the previous line's regimen and their permissible
# substitutes, minus this line's own base drugs - a drug in both regimens is
# this line's drug, and its restarts are 4.3's question - and then only the
# EPISODES the count folds. foldin_count_ctes() does the counting; everything
# else reads foldin_episodes.
#
# Four hooks, which is all the rest of this file is:
#
#   SUPPRESS   a fold-set episode is never an added-medication candidate, so it
#              cannot end the line - released restart or not.
#
#   NEVER TRIGGER   a folded drug cannot start the next line either, but only
#              where 4.3's release is ON. With the release withdrawn, which is
#              what CONTRACT pins, 4.3 already refuses the previous line's
#              whole regimen a line of its own and the fold set is a subset of
#              that, so this hook emits nothing in the contract build.
#
#   HOLD       suppressing and owning are two halves of one statement. The
#              line's run-out is carried to the last day any folded episode's
#              supply reaches, capped at observation. Same shape as melp_hold
#              in R/melp_rule.R, and it rides the same runout so the whole end
#              cascade still applies.
#
#   CHAIN      a folded episode must not break a base drug's run-out chain:
#              discon_per_med's interrupt scan reads a boundary source with the
#              folded drugs taken out.
#
# Untouched: LOT1 (no earlier line), transplant and CAR-T triggers, the
# tandem-interrupt rule.
#
# A FALSE build records the deviation in LOT_BUILD_STATUS and every reader that
# resolves run ownership refuses it as the study's. Measured against a build
# without it by exploration/lot/run_foldin_cells.R.

foldin_on <- function(cfg) isTRUE(cfg$apply_map_foldin)

# The fold set and the hold, for the statement that builds line N's base.
# lot_long holds lines 1..N-1 at this point, so the previous line's regimen is
# a scan of it. The set itself comes from prior_lines_regimen_ctes() in
# R/prior_regimen.R - one definition, so this and the melphalan rule's
# "is this agent NEW" test cannot disagree about the same pair of drugs.
#
# base_meds and lot{n}_start are this statement's own; the hold keeps
# own-base drugs out so a drug in both regimens stays under the engine's
# rules, and takes episodes STARTING in the line - an episode already running
# when the line began belongs to the line that collected it.
# THE COUNT - LOT_RULES.md 4.8 for why each measure is the one it is. What the
# SQL below needs stated:
#
#   The interval is DOSE TO DOSE, not cover-end to dose. A drug's cover often
#   runs past the line it belonged to, so measuring from where it stopped puts
#   the advance that ended that line before the interval.
#
#   What is counted is DIFFERENT AGENTS that opened a line, not lines. One
#   agent opening two lines is one advance; two drugs opening a line together
#   are one advance too.
#
#   TRANSPLANTS AND CAR-T ARE NOT IN THE COUNT - it counts drugs. They keep the
#   engine's own rules, and one that OPENED A LINE between the two doses
#   OVERRIDES the fold whatever the count says. One the line OWNS - an AUTO
#   inside its own window, a planned tandem partner - opens no line, so it
#   never reaches the test.
#
#   count = 0 is not this rule's case. Only 1 folds.
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
  # The same exclusion, in the WHERE of foldin_agent rather than a join.
  # The MELP test is not decoration. melp_suppress_dates carries a patient and
  # a DATE, so matching on those alone removes whatever else started that day -
  # a returning drug landing on the same date as a suppressed course was
  # dropped from the fold set and opened a line of its own.
  not_supp_ms <- if (!melp_on) "" else paste0("
      WHERE NOT (upper(trim(ms.MAP_MED_TYPE)) = '", melp_abbr(cfg), "'
                 AND EXISTS (SELECT 1 FROM melp_suppress_dates msd
                             WHERE msd.PATID = ms.PATID
                               AND msd.SUPPRESS_DT = ms.MAP_START_DT))")
  not_supp <- if (!melp_on) "" else paste0("
          AND NOT (upper(trim(ms.MAP_MED_TYPE)) = '", melp_abbr(cfg), "'
                   AND EXISTS (SELECT 1 FROM melp_suppress_dates msd
                               WHERE msd.PATID = ms.PATID
                                 AND msd.SUPPRESS_DT = ms.MAP_START_DT))")
  this_tx <- if (is.null(n_start) || is.null(n_type)) "" else paste0("
      UNION
      SELECT ", n_tbl, ".PATID, ", n_start, " AS OPEN_DT
      FROM ", n_tbl, "
      WHERE ", n_type, " <> 'MED'")
  this_line <- if (is.null(n_start) || is.null(n_type)) "" else paste0("
      UNION
      SELECT ", n_tbl, ".PATID, ", n_start, " AS OPEN_DT,
             min(coalesce(ps.original_med, ms.MAP_MED_TYPE)) AS OPENER
      FROM ", n_tbl, "
      INNER JOIN map_stacked ms
        ON ms.PATID = ", n_tbl, ".PATID AND ms.MAP_START_DT = ", n_start, "
       AND ms.MAP_MED_CLASS <> 'STEROID'
      LEFT JOIN permissible_subs ps ON ps.substitute_med = ms.MAP_MED_TYPE
      WHERE ", n_type, " = 'MED'
      GROUP BY ", n_tbl, ".PATID, ", n_start)
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
        WHERE 1 = 1", line_break_window_pred(cfg, "tx", induction, n_start), "
      ) o
        ON o.PATID = k.PATID
       -- At or before, not strictly before. A genuinely new agent arriving on
       -- the SAME DAY as the return takes preference: the return belongs to
       -- the line that agent opens, not to the one it was coming back to.
       -- Strictly-before let the same-day case fold, and then the reported
       -- regimen alone corrected it - so the drug named the new line while
       -- still extending the old one's run-out, one episode doing two jobs in
       -- two lines. Every consumer reads foldin_episodes, so the preference
       -- belongs here rather than in any one of them.
       AND o.AT_DT <= k.MAP_START_DT")
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
      -- A melphalan course the melphalan rule SUPPRESSED is not here at all.
      -- It decides nothing, so it must neither fold itself nor stand as the
      -- PREVIOUS dose of a later course - and standing as one is not a
      -- harmless omission: the interval is measured dose to dose, so an
      -- intervening suppressed course reset it and the later course counted
      -- the advances since ITSELF rather than since the drug's real last
      -- dose. A long course that would otherwise have folded then did not,
      -- and the line reported one drug fewer for a course that decided
      -- nothing.{not_supp_ms}
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
             -- Measured against the MAXIMUM cover reached so far, not the
             -- immediately preceding episode's end. A short substitute
             -- episode inside the reference product's cover would otherwise
             -- hand the next episode that short end as its predecessor and
             -- read a break the agent never had - the pair shares one
             -- history, so what matters is how far that history reaches.
             CASE WHEN datediff(MAP_START_DT,
                    max(MAP_END_DT) OVER (PARTITION BY PATID, AGENT
                                          ORDER BY MAP_START_DT, MAP_MED_TYPE
                                          ROWS BETWEEN UNBOUNDED PRECEDING
                                                   AND 1 PRECEDING))
                       >= {discon_days} THEN 1 ELSE 0 END AS IS_RETURN
      FROM foldin_agent
    ),
    foldin_course AS (
      SELECT PATID, MAP_MED_TYPE, MAP_START_DT, AGENT,
             min(MAP_START_DT) OVER (PARTITION BY PATID, AGENT, R) AS COURSE_START_DT
      FROM (SELECT PATID, MAP_MED_TYPE, MAP_START_DT, AGENT,
                   sum(IS_RETURN) OVER (PARTITION BY PATID, AGENT
                                        ORDER BY MAP_START_DT, MAP_MED_TYPE
                                        ROWS BETWEEN UNBOUNDED PRECEDING
                                                 AND CURRENT ROW) AS R
            FROM foldin_runs) q
    ),
    -- Every episode beside the agent's PREVIOUS one. That pair is the
    -- request's two doses, and the interval between them is what the count
    -- reads - dose to dose, not stop to return.
    --
    -- MAP_MED_TYPE is the tiebreak in all three windows above, and it is not
    -- decoration. The partition is the AGENT, so a reference product and its
    -- substitute dosed on ONE day are two peers with equal sort keys, and
    -- Spark leaves the order between such peers undefined - two runs of the
    -- same build could read a different predecessor. duckdb happening to be
    -- stable proves nothing about the warehouse. The key makes the answer the
    -- same every run; which of the pair sorts first is not a judgement this
    -- rule makes.
    foldin_epi AS (
      SELECT c.PATID, c.MAP_MED_TYPE, c.MAP_START_DT, c.AGENT, c.COURSE_START_DT,
             lag(c.MAP_START_DT) OVER (PARTITION BY c.PATID, c.AGENT
                                       ORDER BY c.MAP_START_DT,
                                                c.MAP_MED_TYPE) AS PREV_COURSE_DT
      FROM foldin_course c
    ),
    -- The AGENT that opened each line. The request counts two or more
    -- different AGENTS, not lines, so a line is read through the drug that
    -- started it: the non-steroid medication dosed on its start date. One
    -- agent that opens a line, discontinues, and opens another on a released
    -- restart (LOT_RULES.md 4.3) is one agent, not two. A permissible
    -- substitute collapses to the drug it replaces - 4.4 already says a
    -- substitution is not a change of agent.
    --
    -- MED-started lines only. A line a transplant or CAR-T opened has no
    -- agent, and foldin_tx_between below is what reads those instead.
    foldin_openers AS (
      -- ONE row per line. A line opened by a doublet advanced the LOT once,
      -- not twice, and the request counts agents ADVANCING THE LOT twice or
      -- more - so the line contributes a single opener, and two lines opened
      -- by the same agent still collapse to one. min() only has to be
      -- deterministic; which of two co-starters names the line is not a
      -- judgement this rule makes.
      --
      -- But it must choose among drugs that COULD have opened the line. A
      -- drug of the previous line's regimen cannot (4.3), so a returning drug
      -- dosed on the start date is not what advanced anything - and min()
      -- picked it anyway whenever it sorted first, labelling two consecutive
      -- lines with the same agent and collapsing two advances into one.
      SELECT l.PATID, l.LOT_START_DT AS OPEN_DT,
             min(coalesce(ps.original_med, ms.MAP_MED_TYPE)) AS OPENER
      FROM lot_long l
      INNER JOIN map_stacked ms
        ON ms.PATID = l.PATID AND ms.MAP_START_DT = l.LOT_START_DT
       AND ms.MAP_MED_CLASS <> 'STEROID'
      LEFT JOIN permissible_subs ps ON ps.substitute_med = ms.MAP_MED_TYPE
      LEFT JOIN lot_long pl
        ON pl.PATID = l.PATID AND pl.LOT_NUM = l.LOT_NUM - 1
       AND array_contains(split(coalesce(pl.LOT_BASE_MEDS, ''), ' '),
                          coalesce(ps.original_med, ms.MAP_MED_TYPE))
      WHERE l.LOT_START_TYPE = 'MED' AND {line_pred}
        AND pl.PATID IS NULL
      GROUP BY l.PATID, l.LOT_START_DT{this_line}
    ),
    -- Transplants and CAR-T keep the engine's own rules and are not counted
    -- as agents at all. One that OPENED A LINE in between overrides the fold
    -- outright: it is a standalone boundary, and a drug returning across it is
    -- not returning to the line it left.
    --
    -- Read as a line start rather than re-derived from the transplant tables,
    -- which is what makes it exact. A transplant the line owns - inside its
    -- own window, or a planned tandem partner - opens no line, so it is not
    -- in here and does not override anything.
    foldin_tx_opened AS (
      SELECT l.PATID, l.LOT_START_DT AS OPEN_DT
      FROM lot_long l
      WHERE l.LOT_START_TYPE <> 'MED' AND {line_pred}{this_tx}
    ),
    -- How many different agents opened a line strictly between the two doses,
    -- and whether a transplant opened one there too. A LEFT JOIN and a count,
    -- not a correlated subquery: the translation has to survive Spark and the
    -- harness alike. count(DISTINCT) rather than count(): the joins beside it
    -- multiply rows, and distinct is what the request asks for anyway.
    foldin_counted AS (
      SELECT k.PATID, k.AGENT, k.COURSE_START_DT, k.MAP_START_DT,
             count(DISTINCT fo.OPENER) AS N_ADVANCES,
             max(CASE WHEN tx.PATID IS NOT NULL THEN 1 ELSE 0 END) AS N_TX{between_sel}
      FROM foldin_epi k{join_n}
      LEFT JOIN foldin_openers fo
        ON fo.PATID = k.PATID
       AND fo.OPEN_DT >  k.PREV_COURSE_DT
       AND fo.OPEN_DT <  k.MAP_START_DT
      LEFT JOIN foldin_tx_opened tx
        ON tx.PATID = k.PATID
       AND tx.OPEN_DT >  k.PREV_COURSE_DT
       AND tx.OPEN_DT <  k.MAP_START_DT{between_join}
      -- EVERY episode after the drug's first is judged, and each is a return:
      -- a new episode opens only for a claim beyond every run-out (§2.3), so
      -- an episode always follows a break in cover. It is NOT restricted to
      -- episodes after a discon_days gap. The request's own worked case is a
      -- 60-day break - shorter than the 90-day discontinuation - and reading
      -- COMING BACK AFTER BEING STOPPED as the engine's discontinuation would
      -- refuse to fold the very example the rule was written for. Scenario S01
      -- is that case.
      WHERE k.PREV_COURSE_DT IS NOT NULL
      GROUP BY k.PATID, k.AGENT, k.COURSE_START_DT, k.MAP_START_DT
    ),
    -- A course folds if any of its episodes does, and then all of them do.
    foldin_folded AS (
      SELECT DISTINCT PATID, AGENT, COURSE_START_DT
      FROM foldin_counted
      WHERE N_ADVANCES = 1 AND N_TX = 0{between_pred}
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
{prior_lines_regimen_ctes(glue('ll.LOT_NUM = {lot_num} - 1'), raw = 'foldin_prev', out = 'foldin_meds')}
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

# The folded episodes as REGIMEN rows, for med_summary. A drug this rule bundles
# into a line joins that line's regimen string and its drug count - and its med
# and class flags with them, since all four come off the same set.
#
# Bounded like foldin_hold, and cut short the same way the induction step is:
# episodes of a fold-set drug STARTING inside the line, own-base drugs excluded
# because they are in the regimen already, and nothing past a transplant that
# ended the line. Without that cutoff a folded episode after the line closed
# still named itself in the regimen, and QC C1 caught it - a regimen drug with
# no episode anywhere inside its line.
#
# base_meds ITSELF is not rewritten. It is built before these CTEs and the fold
# consults it, so feeding the fold back into that table has no order that
# works. What the readers get instead is foldin_base_meds() below - base_meds
# with the folded drugs taken out, which is what discon_per_med's boundary scan
# reads, and which exists exactly because part of the line must not break the
# line. So the working set the readers see does change; the table it is
# derived from does not.
foldin_regimen_union <- function(cfg, lot_num, induction_end) {
  if (!foldin_on(cfg)) return("")
  # A melphalan course the melphalan rule SUPPRESSED, by date. Two things here
  # have to know about it, and for one reason: that rule has already decided
  # the course opens nothing, so this one must not read the same rows as a
  # drug arriving. Same test foldin_count_ctes uses, so the count and the
  # regimen cannot disagree about one episode.
  supp <- function(alias) if (!melp_rule_on(cfg)) "" else paste0("
        AND NOT (upper(trim(", alias, ".MAP_MED_TYPE)) = '", cfg$melp_med_abbr, "'
                 AND EXISTS (SELECT 1 FROM melp_suppress_dates msd
                             WHERE msd.PATID = ", alias, ".PATID
                               AND msd.SUPPRESS_DT = ", alias, ".MAP_START_DT))")
  paste0("\n", glue("
      UNION
      SELECT ms.PATID, ms.MAP_MED_TYPE AS MED_ABBR, ms.MAP_MED_CLASS AS MED_CLASS
      FROM map_stacked ms
      INNER JOIN lot{lot_num}_start ON lot{lot_num}_start.PATID = ms.PATID
      INNER JOIN lot{lot_num}_regimen_cutoff rc ON rc.PATID = ms.PATID
      INNER JOIN foldin_episodes fm
        ON fm.PATID = ms.PATID AND fm.MED_ABBR = ms.MAP_MED_TYPE
       AND fm.MAP_START_DT = ms.MAP_START_DT
      LEFT JOIN base_meds bm
        ON bm.PATID = ms.PATID AND bm.MED_ABBR = ms.MAP_MED_TYPE
      WHERE bm.MED_ABBR IS NULL{supp('ms')}
        AND ms.MAP_START_DT >= lot{lot_num}_start.LOT{lot_num}_START_DT
        AND ms.MAP_START_DT <= least(
              lot{lot_num}_start.OBS_END_DT,
              coalesce(rc.REGIMEN_CUTOFF_DT, cast(\'9999-12-31\' as date)))
        -- ...and nothing at or after a transplant that BREAKS this line. The
        -- regimen cutoff above covers ALLO and CAR-T only; an AUTO ends a line
        -- too, and a folded episode the day after one belongs to the line that
        -- AUTO opened. Same test 4.7 and the count use, so a transplant the
        -- line owns - in its window, or a planned tandem partner - excludes
        -- nothing.
        AND NOT EXISTS (
          SELECT 1
          FROM ({line_break_tx_sql()}
          ) btx
          WHERE btx.PATID = ms.PATID
            AND btx.TX_DT <= ms.MAP_START_DT{line_break_window_pred(cfg, \'btx\',
                  induction_end, glue(\'lot{lot_num}_start.LOT{lot_num}_START_DT\'))}
        )
        -- ...and nothing at or after a genuinely NEW agent, which ends the
        -- line as an added medication. A SUPPRESSED melphalan course is not
        -- one: the melphalan rule has already decided it opens nothing, and
        -- reading it as an arrival here dropped a correctly folded drug from
        -- the regimen while leaving the line's dates untouched - so the line
        -- reported a doublet as a single agent and nothing in the shape of the
        -- line showed it. A return landing on the SAME DAY as one
        -- belongs to the line that agent opens, not to this one: the count
        -- looks strictly before the return, so it does not see a same-day
        -- arrival and folds anyway. Without this the line reported a drug
        -- whose only episode began after the line had ended, and the next line
        -- reported it too.
        AND NOT EXISTS (
          SELECT 1 FROM map_stacked nb
          WHERE nb.PATID = ms.PATID
            AND nb.MAP_MED_CLASS <> \'STEROID\'
            AND nb.MAP_START_DT >  {induction_end}
            AND nb.MAP_START_DT <= ms.MAP_START_DT
            AND NOT EXISTS (SELECT 1 FROM base_meds ob
                            WHERE ob.PATID = nb.PATID
                              AND ob.MED_ABBR = nb.MAP_MED_TYPE)
            AND NOT EXISTS (SELECT 1 FROM foldin_meds ofm
                            WHERE ofm.PATID = nb.PATID
                              AND ofm.MED_ABBR = nb.MAP_MED_TYPE){supp('nb')}
        )"))
}

# The line's WORKING base set with the folded drugs in it. discon_per_med reads
# this, so a folded drug's cover chains the line's run-out the way any regimen
# drug's does.
#
# Without it the two halves of §4.3 came apart on a folded drug. The reported
# regimen carries it, so the NEXT line refuses it a line of its own - correctly.
# But the working set did not, so the line it folded into stopped at its own
# drugs' cover, and a SECOND return of that drug fell after the line had ended
# and before the next one could open: treatment in no line at all.
#
# base_meds itself is untouched, and the fold is computed from it, so there is
# no circle: base_meds -> the fold -> this.
#
# SUBSTITUTE_ONLY = 0. A folded drug is in the line on its own account, not as
# somebody's stand-in, and the release the flag gates is switched off for it
# anyway.
foldin_base_meds <- function(cfg) {
  if (!foldin_on(cfg)) return("base_meds")
  "foldin_base_meds_eff"
}

foldin_base_meds_ctes <- function(cfg) {
  if (!foldin_on(cfg)) return("")
  paste0("\n", glue("
    foldin_base_meds_eff AS (
      SELECT PATID, MED_ABBR, min(SUBSTITUTE_ONLY) AS SUBSTITUTE_ONLY
      FROM (
        SELECT PATID, MED_ABBR, SUBSTITUTE_ONLY FROM base_meds
        UNION ALL
        SELECT DISTINCT PATID, MED_ABBR, 0 AS SUBSTITUTE_ONLY FROM foldin_episodes
        UNION ALL
        -- The folded drug's permissible substitutes, both directions. A drug
        -- the fold made part of this line brings its whole agent with it, or
        -- the equivalent product arriving next ends the line the fold just
        -- claimed - and the next line refuses to open on it, because there it
        -- IS recognised as the same agent. That left the treatment in no line.
        SELECT DISTINCT fe.PATID, ps.substitute_med AS MED_ABBR,
               1 AS SUBSTITUTE_ONLY
        FROM foldin_episodes fe
        INNER JOIN permissible_subs ps ON fe.MED_ABBR = ps.original_med
        UNION ALL
        SELECT DISTINCT fe.PATID, ps.original_med AS MED_ABBR,
               1 AS SUBSTITUTE_ONLY
        FROM foldin_episodes fe
        INNER JOIN permissible_subs ps ON fe.MED_ABBR = ps.substitute_med
      )
      GROUP BY PATID, MED_ABBR
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

# The fold set for the NEXT line's start candidates. Emitted only where §4.3's
# release is still on: with it withdrawn, §4.3 refuses the previous line's
# regimen a line of its own and the fold set is a subset of that regimen, so
# there is nothing left here to refuse.
foldin_prior_ctes <- function(cfg, prev) {
  if (!foldin_on(cfg) || !return_release_on(cfg)) return("")
  # The same count, over the lines lot_long holds at this point - 1..prev. The
  # line being started does not exist yet, so there is no own-start term.
  count_ctes <- foldin_count_ctes(cfg, discon_days = cfg$map_discon_gap_days,
                                  meds = "foldin_sc_meds",
                                  line_pred = glue("l.LOT_NUM <= {prev}"))
  paste0("\n", glue("
{prior_lines_regimen_ctes(glue('ll.LOT_NUM = {prev}'), raw = 'foldin_sc_prev', out = 'foldin_sc_meds')}
{count_ctes}"))
}

# An older line's agent never starts a line while the rule is on - it belongs
# to the line it returned in, which the hold above has already stretched over
# it.
foldin_trigger_predicate <- function(cfg) {
  if (!foldin_on(cfg) || !return_release_on(cfg)) return("")
  paste0("\n", glue("
        AND NOT EXISTS (SELECT 1 FROM foldin_episodes fm
                        WHERE fm.PATID = ms.PATID
                          AND fm.MED_ABBR = ms.MAP_MED_TYPE
                          AND fm.MAP_START_DT = ms.MAP_START_DT)"))
}
