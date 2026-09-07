# The melphalan line-advancing rule - LOT_RULES.md 4.7, and CONTRACT in
# build_lot.R. One rule, applied by every study build; APPLY_MELP_RULE turns it
# off and nothing else. A rule-off build is a different algorithm, so it needs
# LOT_CONTRACT_OVERRIDE and is recorded as a deviation - it exists so the rule's
# effect can be measured, which lot/melphalan/ does.
#
# The rule lives in the engine because it needs each line's induction window,
# and that exists only while the line is being built.
#
# It changes one thing: which melphalan MAP rows may be an added medication, and
# on what date. Everything else follows.
#
# A melphalan course covering melp_simple_course_days or fewer days, outside the
# line's induction window, does not advance the line on its own: the course is
# suppressed and the line carried to the end of its cover. If another
# engine-valid agent starts while that course still covers, the next line DOES
# start, and it starts on the melphalan date rather than the later agent's - so
# the course's first day is injected as the boundary. A course inside induction,
# or one longer than the cap, is left to the engine untouched.
# melp_decision_ctes() below does the work.
# The two values APPLY_MELP_RULE takes. There is one rule, so this is on/off,
# and it stays a WORD rather than a flag for two reasons: APPLY_MELP_RULE is a
# CONTRACT axis, and config.csv carries the word.
#
# "off" is the ONLY way to ask for a rule-off build from the environment. Blank
# cannot do it: load_inputs.R fills any variable that is unset OR empty from
# config.csv, and config.csv carries the contract value - so APPLY_MELP_RULE=
# reaches the build as 'simplified', and a comparison cell meant to hold the
# rule off would quietly measure the contract against itself. A word survives
# that fill; an empty string does not.
#
# Blank still means off for a cfg built in R rather than from the environment,
# which is how the tests and the emitters construct one.
MELP_RULE_ON  <- "simplified"
MELP_RULE_OFF <- "off"

# Read once, and the only question anything asks. An unrecognised value - a
# retired mode name included - stops the build rather than quietly acting like
# the rule is on.
melp_rule_on <- function(cfg) {
  m <- tolower(trimws(cfg$apply_melp_rule %||% ""))
  if (!nzchar(m) || identical(m, MELP_RULE_OFF)) return(FALSE)
  if (!identical(m, MELP_RULE_ON))
    stop("APPLY_MELP_RULE='", m, "' is not one of: ",
         paste(c(MELP_RULE_ON, MELP_RULE_OFF), collapse = ", "),
         ". The contract build is '", MELP_RULE_ON, "'; '", MELP_RULE_OFF,
         "' builds without the rule and needs LOT_CONTRACT_OVERRIDE.",
         call. = FALSE)
  TRUE
}
melp_abbr    <- function(cfg) toupper(trimws(cfg$melp_med_abbr %||% "MELP"))

# The exposure chain and the decision, as CTEs. Doses are global; the decision
# is per line. A dose is a dose, but "inside induction" belongs to the line
# being built.
#
# line_tbl / start_col / span_end name that line. induction_end is the step's
# own induction-end expression for it - 60 days at LOT1, 30 at LOT2-5, 45 on a
# CART-started line. It is handed in rather than rebuilt here. base_tbl names
# (PATID, MED_ABBR, SUBSTITUTE_ONLY) for the judged line and restart_tbl the
# restart flags (map_restart_sql's shape); each caller passes the ones already
# in scope in its statement, and melp_prev_line_ctes emits its own pair first
# because nothing usable exists yet where it splices.
#
# Per exposure (doses chained the same way), against the line handed in:
#
#   INSIDE     the exposure starts on or before the line's induction end
#   SHORT      the course covers melp_simple_course_days or fewer - from its
#              first dose to the last day any of its episodes' supply reaches
#   CONFIRMED  an engine-valid candidate of ANOTHER drug starts while the
#              course still covers: non-steroid, not melphalan, and either
#              outside the judged line's base set or a released restart of one
#              of its own drugs. A drug the line already holds does not
#              confirm anything - nothing new happened.
#
#   outside induction, SHORT, not confirmed  -> suppressed AND held: the
#                                               course stays in the line
#   outside induction, SHORT, confirmed      -> injected at the course's first
#                                               day: the next line starts on
#                                               the melphalan date, not the
#                                               confirming agent's later one
#   everything else                          -> left to the engine
melp_decision_ctes <- function(cfg, line_tbl, start_col, span_end, induction_end,
                               base_tbl = NULL, restart_tbl = NULL,
                               not_new_ctes = "", cart_from = NULL,
                               first_auto_exempt = FALSE, proc_line = NULL,
                               prior_held_ctes = "", no_regimen_line = NULL) {
  if (!melp_rule_on(cfg)) return("")
  if (is.null(base_tbl) || is.null(restart_tbl))
    stop("The melphalan short-course rule needs the judged line's base set and ",
         "restart flags to tell a confirming agent from a drug the line ",
         "already holds. This caller handed in neither.", call. = FALSE)
  abbr <- melp_abbr(cfg)
  # Present only when the fold-in is on and there is an earlier line to read.
  not_new_join <- if (!nzchar(not_new_ctes)) "" else
    "\n      LEFT JOIN melp_not_new nn
        ON nn.PATID = c.PATID AND nn.MED_ABBR = c.MAP_MED_TYPE"
  # No exception here, whatever else the returning drug does: "a returning drug
  # does not confirm a course, even where it opens a line" (LOT_RULES.md 4.7).
  # The boundary such a drug DOES make is a separate test, in the NOT EXISTS at
  # the end of melp_confirm.
  not_new_pred <- if (!nzchar(not_new_ctes)) "" else
    "\n        AND nn.MED_ABBR IS NULL"
  # The same set for melp_taken's "another agent got here first" scan: a
  # returning drug is not another agent, the fold-in has put it in this line
  # (4.8). Built from the earlier lines because a folded drug joins the
  # REPORTED regimen and the fold CTEs are spliced after these.
  # An anti-join and a WHERE test, not an EXISTS in the ON clause. `o` is
  # INNER JOINed here, so moving the condition out of the join changes
  # nothing - and Spark does not accept a correlated subquery in a join
  # condition before 4.0 (SPARK-45009).
  # A course an earlier line held inside its own window is not this line's to
  # judge. 4.7 asks whether a course is outside ANY window, and this one is
  # inside the owner's. Needed on top of the cover bound, which misses a course
  # covering INTO the next line (F37/F37c). A course the owner SUPPRESSED is
  # not in this set, so a later line still judges it (SPin).
  no_regimen_pred <- if (is.null(no_regimen_line)) "" else
    paste0("\n                   AND NOT (", no_regimen_line, ")")
  prior_held_pred <- if (!nzchar(prior_held_ctes)) "" else
    "\n        AND NOT EXISTS (SELECT 1 FROM melp_prior_held ph
                        WHERE ph.PATID = mc.PATID AND ph.EXPO_DT = mc.EXPO_DT)"
  # A MEDICATION boundary, the same idea as the transplant one at the end of
  # melp_confirm: an agent arriving after a drug that opened a line belongs to
  # that line and cannot make this line's course advance. LOT_RULES.md 4.7,
  # planted as ZB1/ZB2.
  #
  # Exactly one kind of drug can be that boundary without confirming the course
  # itself - a previous-line drug returning at a procedure-opened line, where
  # 4.8 refuses the fold. Anything else in the interval is either no candidate
  # at all or a candidate, and a candidate confirms, which makes the boundary
  # the melphalan date.
  #
  # Past the line's own window, because a return inside it joins this line's
  # regimen and opens nothing. STRICTLY before the agent, where the transplant
  # test says on-or-before: two drugs starting the same day start one line
  # together and neither is "after" the other, while a transplant and a same-day
  # drug are ordered by the engine's tie-break.
  confirm_med_boundary <- if (!nzchar(not_new_ctes) || is.null(proc_line)) "" else
    glue("
        AND NOT EXISTS (
          SELECT 1
          FROM map_stacked b
          INNER JOIN melp_not_new bn
            ON bn.PATID = b.PATID AND bn.MED_ABBR = b.MAP_MED_TYPE
          WHERE b.PATID = mc.PATID
            AND b.MAP_MED_CLASS <> 'STEROID'
            AND upper(trim(b.MAP_MED_TYPE)) <> '{abbr}'
            AND b.MAP_START_DT >  mc.EXPO_DT
            AND b.MAP_START_DT <  c.MAP_START_DT
            AND b.MAP_START_DT >  {induction_end}
            AND {proc_line}
        )")
  taken_not_new_join <- if (!nzchar(not_new_ctes)) "" else
    "\n      LEFT JOIN melp_not_new tnn
        ON tnn.PATID = o.PATID AND tnn.MED_ABBR = o.MAP_MED_TYPE"
  # ...with one exception, and only here. Where a PROCEDURE opened the judged
  # line, 4.8 refuses the fold outright, so the returning drug is folded into
  # nothing: it is line-defining, which is what this scan asks about. Planted
  # as ZB3/ZB3x.
  #
  # The test is the judged line's start type rather than a re-derivation of the
  # fold - the fold CTEs are spliced after these and cannot be read from here
  # (R/foldin_rule.R records the same one-way dependency from its side). It
  # does not need to be: a return inside a procedure-opened line has crossed
  # that procedure by construction, which is the whole of the override.
  taken_not_new_pred <- if (!nzchar(not_new_ctes)) "" else
    if (is.null(proc_line)) "\n        AND tnn.MED_ABBR IS NULL"
    else paste0("\n        AND (tnn.MED_ABBR IS NULL OR ", proc_line, ")")
  paste0("\n", glue("
    melp_doses AS (
      SELECT PATID, MAP_START_DT AS DOSE_DT
      FROM map_stacked
      WHERE upper(trim(MAP_MED_TYPE)) = '{abbr}'
      GROUP BY PATID, MAP_START_DT
    ),
    -- Chained, not pairwise: doses closer than melp_exposure_days are one
    -- administration.
    melp_runs AS (
      SELECT PATID, DOSE_DT,
             CASE WHEN datediff(DOSE_DT,
                    lag(DOSE_DT) OVER (PARTITION BY PATID ORDER BY DOSE_DT))
                       < {cfg$melp_exposure_days}
                  THEN 0 ELSE 1 END AS IS_NEW
      FROM melp_doses
    ),
    melp_dose_expo AS (
      SELECT PATID, DOSE_DT,
             min(DOSE_DT) OVER (PARTITION BY PATID, E) AS EXPO_DT
      FROM (SELECT PATID, DOSE_DT,
                   sum(IS_NEW) OVER (PARTITION BY PATID ORDER BY DOSE_DT
                                     ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS E
            FROM melp_runs) r
    ),
    -- How long the course covers: the latest supply end over its episodes.
    -- Days supplied, not dose dates - 'received for 28 days' is a statement
    -- about cover, and a single administration's episode carries its own.
    melp_course AS (
      SELECT d.PATID, d.EXPO_DT, max(m.MAP_END_DT) AS COURSE_END_DT
      FROM melp_dose_expo d
      INNER JOIN map_stacked m
        ON m.PATID = d.PATID AND m.MAP_START_DT = d.DOSE_DT
       AND upper(trim(m.MAP_MED_TYPE)) = '{abbr}'
      GROUP BY d.PATID, d.EXPO_DT
    ),
    -- The confirming agent: a different, non-steroid drug starting while the
    -- course still covers, and one the engine itself would accept as a
    -- candidate against this line - outside its base set, or a released
    -- restart that is not substitute-only. The same gate the candidate lists
    -- apply, read from the tables handed in, so the two cannot disagree.
{not_new_ctes}{prior_held_ctes}
    -- The confirming agent has to be a NEW one. A returning prior-line drug is
    -- the returning drug (4.8), not a change, so it confirms nothing. The join
    -- is present only with the fold-in on and from LOT2 up, and reads the same
    -- set the fold does - prior_lines_regimen_ctes() in R/prior_regimen.R.
    --
    -- No lower bound: the agent must start after the COURSE, not after the
    -- judged line. So a course covering into two lines is judged by both and
    -- they can disagree about CONFIRMED. Open - see STUDY_TEAM_ASKS.md 7.
    melp_confirm AS (
      SELECT DISTINCT mc.PATID, mc.EXPO_DT
      FROM melp_course mc
      -- The judged line, for the transplant test below: which transplants
      -- break a line is a question about THAT line's window and start.
      INNER JOIN {line_tbl} ON {line_tbl}.PATID = mc.PATID
      -- No lower bound HERE, and it is not an oversight - see the note above
      -- melp_confirm. Bounding confirmation by the judged line's start was
      -- tried, on the shape that argues for it: an allograft line one day after
      -- a suppressed course, with a new agent five days later, which confirms
      -- the course, takes its own hold away and collapses back to a single day
      -- while the line that OWNS the course suppressed it. The bound does carry
      -- that line to the course's cover - and the hold then runs straight past
      -- the new agent, which loses its line altogether: four unassigned days
      -- become three hundred and eighty-six. The missing piece is a cap on the
      -- hold at the next line-defining agent, and which of that agent and the
      -- melphalan carry ends the line is 4.7-against-7.2, a rule the study team
      -- has not been asked. Left as it is, with the shape recorded.
      INNER JOIN map_stacked c
        ON c.PATID = mc.PATID
       AND c.MAP_START_DT >  mc.EXPO_DT
       AND c.MAP_START_DT <= mc.COURSE_END_DT
       AND c.MAP_MED_CLASS <> 'STEROID'
       AND upper(trim(c.MAP_MED_TYPE)) <> '{abbr}'
      LEFT JOIN {base_tbl} cb
        ON cb.PATID = c.PATID AND cb.MED_ABBR = c.MAP_MED_TYPE
      LEFT JOIN {restart_tbl} cr
        ON cr.PATID = c.PATID AND cr.MAP_MED_TYPE = c.MAP_MED_TYPE
       AND cr.MAP_START_DT = c.MAP_START_DT{not_new_join}
      WHERE (cb.MED_ABBR IS NULL
{return_release_sql(cfg, 'cr', 'cb')}){not_new_pred}
        -- ...and nothing has ENDED the judged line between the course and the
        -- agent. An agent arriving after a breaking transplant belongs to the
        -- line that transplant opened, so it cannot make this line's course
        -- advance. Planted as SK/SKn. Same helper melp_taken reads, so
        -- ownership and confirmation cannot disagree about which transplants
        -- are boundaries.
        AND NOT EXISTS (
          SELECT 1
          FROM ({line_break_tx_sql()}
          ) ctx
          WHERE ctx.PATID = mc.PATID
            AND ctx.TX_DT >  mc.EXPO_DT
            AND ctx.TX_DT <= c.MAP_START_DT{line_break_window_pred(cfg, 'ctx',
                  induction_end, paste0(line_tbl, '.', start_col), cart_from,
                  first_auto_exempt)}
        ){confirm_med_boundary}
    ),
    -- A course belongs to ONE line: the latest whose start precedes it.
    -- Without this every line claims every later course and melp_hold takes
    -- the max, carrying the FIRST line to the LAST suppressed course in the
    -- record (SH).
    --
    -- The test is an intervening line-defining agent, not a gap: a course long
    -- after the drugs ran out is still this line's when nothing happened in
    -- between, which is the request's own case (SE). Same candidate gate as
    -- melp_confirm below, so ownership and confirmation cannot disagree about
    -- what counts as an agent.
    --
    -- KNOWN GAP. The gate does not ask whether that agent could open a line.
    -- One past the line's run-out, or landing exactly on its end, opens
    -- nothing under 4.1 but still disqualifies the course - and then no line
    -- judges it, so it takes one of its own. Not fixed: the bound wanted is
    -- the line's run-out, and discon_per_med computes that after these CTEs
    -- while reading melp_boundary_join from them. See LOT_RULES.md 4.7.
    melp_taken AS (
      SELECT DISTINCT mc.PATID, mc.EXPO_DT
      FROM melp_course mc
      INNER JOIN {line_tbl} ON {line_tbl}.PATID = mc.PATID
      INNER JOIN map_stacked o
        ON o.PATID = mc.PATID
       AND o.MAP_START_DT >  {line_tbl}.{start_col}
       AND o.MAP_START_DT <= mc.EXPO_DT
       AND o.MAP_MED_CLASS <> 'STEROID'
       AND upper(trim(o.MAP_MED_TYPE)) <> '{abbr}'
      LEFT JOIN {base_tbl} ob
        ON ob.PATID = o.PATID AND ob.MED_ABBR = o.MAP_MED_TYPE
      LEFT JOIN {restart_tbl} orr
        ON orr.PATID = o.PATID AND orr.MAP_MED_TYPE = o.MAP_MED_TYPE
       AND orr.MAP_START_DT = o.MAP_START_DT{taken_not_new_join}
      WHERE (ob.MED_ABBR IS NULL
{return_release_sql(cfg, 'orr', 'ob')}){taken_not_new_pred}
      UNION
      -- A line can also be opened by a procedure, and a course after one is
      -- no more this line's than a course after a new drug (SI).
      --
      -- Measured from the line's INDUCTION END, not its start: a transplant
      -- inside a line's own window belongs to that line and ends nothing
      -- (LOT_RULES.md 3.4 and 6.5). One past the window is a boundary, with
      -- one exception - a PLANNED TANDEM partner, which need not be in the
      -- window and continues the line however far out it sits (SJ).
      SELECT DISTINCT mc.PATID, mc.EXPO_DT
      FROM melp_course mc
      INNER JOIN {line_tbl} ON {line_tbl}.PATID = mc.PATID
      INNER JOIN ({line_break_tx_sql()}
      ) tx
        ON tx.PATID = mc.PATID
       AND tx.TX_DT <= mc.EXPO_DT{line_break_window_pred(cfg, 'tx', induction_end,
             paste0(line_tbl, '.', start_col), cart_from, first_auto_exempt)}
    ),
    melp_judged AS (
      SELECT mc.PATID, mc.EXPO_DT,
             -- Outside ANY induction window, in the ask's own words: a
             -- course starting BEFORE this line is outside its window like any
             -- other earlier date, not exempt from its judgement (SPin).
             -- ...and only where the line has an induction window to be
             -- inside. An ALLOGENEIC line spans its transplant date alone and
             -- takes no drugs at all - 4.6, and the induction step suppresses
             -- its regimen rows - so a course starting on that date is not an
             -- induction drug of it, however the window arithmetic reads.
             -- Read as INSIDE, the previous-line statement left the course
             -- unsuppressed and its later dose opened a line, while the new
             -- line's own statement judged the same course outside its window
             -- and suppressed it - so the line was started by a dose it then
             -- held out of its own regimen. Shipped checks A7 and C4 both call
             -- that a failure. Planted as P0008 in run_synthetic.py, where
             -- the shipped catalogue runs over every planted patient.
             CASE WHEN mc.EXPO_DT >= {line_tbl}.{start_col}
                   AND mc.EXPO_DT <= {induction_end}{no_regimen_pred}
                  THEN 1 ELSE 0 END AS INSIDE,
             CASE WHEN datediff(mc.COURSE_END_DT, mc.EXPO_DT) + 1
                       <= {cfg$melp_simple_course_days} THEN 1 ELSE 0 END AS SHORT,
             CASE WHEN cf.PATID IS NOT NULL THEN 1 ELSE 0 END AS CONFIRMED
      FROM melp_course mc
      LEFT JOIN melp_confirm cf
        ON cf.PATID = mc.PATID AND cf.EXPO_DT = mc.EXPO_DT
      INNER JOIN {line_tbl} ON {line_tbl}.PATID = mc.PATID
      LEFT JOIN melp_taken tk
        ON tk.PATID = mc.PATID AND tk.EXPO_DT = mc.EXPO_DT
      -- Bounded by the course's COVER, not by where it starts. A line judges
      -- the courses it can actually see: one that starts inside it, and one
      -- that started earlier and still covers into it - the course a
      -- transplant splits, which 4.7 says is outside the new line's induction
      -- window and not exempt from its judgement (SPin). Asking instead
      -- whether the course STARTS after the line let that split course fall
      -- between this test and melp_taken, judged by neither line.
      --
      -- A course whose cover ran out before this line began has no dose in it
      -- and belongs to an earlier line, so this line does not judge it.
      -- Unbounded, every later line re-judged it against its own window. Two
      -- defects followed: the fold-in lost the course as a returning drug's
      -- previous dose (F36/F36c), and the hold gave a transplant line a
      -- run-out before its own start, which QC check B7 calls a failure
      -- (SU1/SU2).
      WHERE mc.EXPO_DT <= {span_end}
        AND mc.COURSE_END_DT >= {line_tbl}.{start_col}
        AND tk.PATID IS NULL{prior_held_pred}
    ),
    -- A short unconfirmed course outside induction neither ends the line nor
    -- starts one...
    melp_suppress AS (
      SELECT DISTINCT PATID, EXPO_DT AS SUPPRESS_DT
      FROM melp_judged
      WHERE INSIDE = 0 AND SHORT = 1 AND CONFIRMED = 0
    ),
    -- ...and every dose in it comes off the candidate list, not just the
    -- first.
    melp_suppress_dates AS (
      SELECT DISTINCT d.PATID, d.DOSE_DT AS SUPPRESS_DT
      FROM melp_dose_expo d
      INNER JOIN melp_suppress s
        ON s.PATID = d.PATID AND s.SUPPRESS_DT = d.EXPO_DT
    ),
    -- A confirmed short course advances - on ITS first day. The confirming
    -- agent needs no help of its own: it is an engine candidate already, and
    -- later than this date by construction.
    -- Its FIRST day only. The rest of the course is melp_inject_rest below,
    -- which is where the reason for the split is written out.
    melp_inject AS (
      SELECT DISTINCT PATID, EXPO_DT AS INJECT_DT
      FROM melp_judged
      WHERE INSIDE = 0 AND SHORT = 1 AND CONFIRMED = 1
    ),
    -- ONE COURSE, ONE ANSWER - the same statement suppression makes above,
    -- for the other verdict. The course advances the line on its FIRST day and
    -- its later doses belong to the line that day opened; none of them may
    -- open a line of its own. melp_inject carries the boundary alone, because
    -- only the first day is one; this carries the rest (SQ).
    melp_inject_rest AS (
      SELECT DISTINCT d.PATID, d.DOSE_DT
      FROM melp_dose_expo d
      INNER JOIN melp_inject i
        ON i.PATID = d.PATID AND i.INJECT_DT = d.EXPO_DT
      WHERE d.DOSE_DT <> d.EXPO_DT
    ),
    -- Suppressing and owning are two halves of one statement: the line is
    -- carried to the course it refused a boundary to, to that course's LAST
    -- COVERED DAY. 'Received for 28 days' is a statement about cover, and the
    -- short test above measures cover, so ownership reads the same clock.
    -- Capped at the line's own span.
    melp_hold AS (
      SELECT s.PATID, max(least(c.COURSE_END_DT, {span_end})) AS MELP_HOLD_DT
      FROM (SELECT PATID, SUPPRESS_DT AS EXPO_DT, 0 AS IS_INJECT
            FROM melp_suppress
            UNION ALL
            -- An INJECTED course too, but ONLY where it has doses after its
            -- first: those are refused a line of their own like a suppressed
            -- course's, so the line they fall in has to reach them.
            --
            -- Two things this must not do. Not hold the line the boundary
            -- ENDS, which would carry it across its own boundary and turn a
            -- confirmed discontinuation into a medication addition on the
            -- melphalan date. And not hold anything for a SINGLE-dose course,
            -- where holding swallowed a later agent that should have opened a
            -- line of its own (SK).
            SELECT DISTINCT i.PATID, i.INJECT_DT AS EXPO_DT, 1 AS IS_INJECT
            FROM melp_inject i
            INNER JOIN melp_dose_expo dz
              ON dz.PATID = i.PATID AND dz.EXPO_DT = i.INJECT_DT
             AND dz.DOSE_DT <> dz.EXPO_DT) s
      INNER JOIN melp_course c
        ON c.PATID = s.PATID AND c.EXPO_DT = s.EXPO_DT
      INNER JOIN {line_tbl} ON {line_tbl}.PATID = s.PATID
      -- Bounded the same way melp_judged is: a course this line refused a
      -- boundary to is a course this line has to hold. Bounding the two
      -- differently suppressed a transplant-split course without giving it to
      -- anyone, and its later dose sat in no line.
      WHERE s.EXPO_DT <= {span_end}
        AND (s.IS_INJECT = 0 OR {line_tbl}.{start_col} >= s.EXPO_DT)
      GROUP BY s.PATID
    ),"))
}

# The course verdict as ONE relation, so every consumer reads the same row
# instead of deriving the decision again for itself.
#
# Emitted as a CTE where the decision chain is already in the statement, and
# built into a table where it is not - two bindings, one implementation. The
# columns are the same either way, so melp_no_break below does not know or care
# which it is reading.
#
# A SUPERSET of the judged set, deliberately. Three consumers want only what
# this line makes of the courses it OWNS; the break test wants every course,
# owned or not, in span or out, and asks a different induction question. So the
# rows stay and the differences become columns a filter can name:
#
#   INSIDE        the course starts within this line's induction window
#   AFTER_WINDOW  it starts strictly after that window - NOT the negation of
#                 INSIDE, because a course starting BEFORE the line is neither
#   SHORT         it covers melp_simple_course_days or fewer
#   CONFIRMED     another engine-valid agent started while it still covered
#   TAKEN         another line-defining agent or breaking transplant got there
#                 first, so the course is not this line's
#   IN_SPAN       it starts on or before this line's span end
#
# Each of those was a separate derivation before, and the defects review has
# been finding lived in the gaps between them.
melp_verdict_body <- function(cfg, line_tbl, start_col, span_end, induction_end) {
  glue("
      SELECT
        d.PATID, d.EXPO_DT, d.DOSE_DT, mc.COURSE_END_DT,
        CASE WHEN mc.EXPO_DT >= {line_tbl}.{start_col}
              AND mc.EXPO_DT <= {induction_end} THEN 1 ELSE 0 END AS INSIDE,
        CASE WHEN mc.EXPO_DT > {induction_end} THEN 1 ELSE 0 END AS AFTER_WINDOW,
        CASE WHEN datediff(mc.COURSE_END_DT, mc.EXPO_DT) + 1
                  <= {cfg$melp_simple_course_days} THEN 1 ELSE 0 END AS SHORT,
        CASE WHEN cf.PATID IS NOT NULL THEN 1 ELSE 0 END AS CONFIRMED,
        CASE WHEN tk.PATID IS NOT NULL THEN 1 ELSE 0 END AS TAKEN,
        CASE WHEN mc.EXPO_DT <= {span_end} THEN 1 ELSE 0 END AS IN_SPAN
      FROM melp_dose_expo d
      INNER JOIN melp_course mc
        ON mc.PATID = d.PATID AND mc.EXPO_DT = d.EXPO_DT
      INNER JOIN {line_tbl} ON {line_tbl}.PATID = mc.PATID
      LEFT JOIN melp_confirm cf
        ON cf.PATID = mc.PATID AND cf.EXPO_DT = mc.EXPO_DT
      LEFT JOIN melp_taken tk
        ON tk.PATID = mc.PATID AND tk.EXPO_DT = mc.EXPO_DT")
}

# The CTE form, for a statement that already carries the decision chain.
# Spliced after melp_decision_ctes, whose CTEs it reads.
melp_verdict_cte <- function(cfg, line_tbl, start_col, span_end, induction_end) {
  if (!melp_rule_on(cfg)) return("")
  paste0("\n", "    melp_verdict AS (",
         melp_verdict_body(cfg, line_tbl, start_col, span_end, induction_end),
         "\n    ),")
}

# Takes a suppressed MELPHALAN row off the engine's own candidate list. Empty
# when the rule is off, so the predicate chain it sits in is unchanged.
#
# Melphalan rows only, and dose dates rather than exposure dates. The rule's
# whole contract is that it changes which melphalan rows may be an added
# medication, and nothing else. A date-only match also removed any OTHER drug
# starting on a suppressed date, so a same-day switch to a new drug lost its
# boundary and the line never ended.
# Whether melphalan belongs in a line's REGIMEN, for the statement that builds
# LOT_BASE_MEDS and LOT_MED_CNT.
#
# A held course joins neither (LOT_RULES.md 4.7). The induction-meds table is
# built one step earlier and carries drug names without dates, so it cannot
# apply the verdict itself - a course held at the COURSE level had its later
# dose reported at the DOSE level, and a line whose whole melphalan exposure
# was held still named it and counted it.
#
# So the test is asked here, where the verdict CTEs are in scope: melphalan
# stays only if at least one of its episodes in this line's window was NOT
# held. One unheld dose is real exposure and the regimen should say so; none
# means the whole course was held, and the regimen should not.
melp_regimen_filter <- function(cfg, line_tbl, start_col, induction_end) {
  if (!melp_rule_on(cfg)) return("")
  paste0("\n", glue("
        WHERE NOT (upper(trim(im0.MED_ABBR)) = '{melp_abbr(cfg)}'
                   AND NOT EXISTS (
                     SELECT 1
                     FROM map_stacked mz
                     INNER JOIN {line_tbl} ON {line_tbl}.PATID = mz.PATID
                     WHERE mz.PATID = im0.PATID
                       AND upper(trim(mz.MAP_MED_TYPE)) = '{melp_abbr(cfg)}'
                       AND mz.MAP_START_DT >= {line_tbl}.{start_col}
                       AND mz.MAP_START_DT <= {induction_end}
                       AND NOT EXISTS (SELECT 1 FROM melp_suppress_dates sz
                                       WHERE sz.PATID = mz.PATID
                                         AND sz.SUPPRESS_DT = mz.MAP_START_DT)))"))
}

melp_suppress_predicate <- function(cfg, alias = "ms") {
  if (!melp_rule_on(cfg)) return("")
  paste0("\n", glue("
        AND NOT (upper(trim({alias}.MAP_MED_TYPE)) = '{melp_abbr(cfg)}'
                 AND EXISTS (SELECT 1 FROM melp_suppress_dates s
                             WHERE s.PATID = {alias}.PATID
                               AND s.SUPPRESS_DT = {alias}.MAP_START_DT))
        AND NOT (upper(trim({alias}.MAP_MED_TYPE)) = '{melp_abbr(cfg)}'
                 AND EXISTS (SELECT 1 FROM melp_inject_rest r
                             WHERE r.PATID = {alias}.PATID
                               AND r.DOSE_DT = {alias}.MAP_START_DT))"))
}

# The rows the rule adds, as a UNION arm on first_add_candidates. Bounded to
# the line the way the engine bounds its own candidates, so an injected date
# outside it cannot open a boundary. Strictly after the start: a date that
# already starts the line is a boundary already.

# An ALLO line under single_day ends on the ALLO date itself. An add cannot end
# it, so an injected candidate must not either. The engine keeps those lines out
# of its own candidates. This is the same exclusion, so the rule cannot open a
# boundary the engine has no concept of.
melp_allo_guard <- function(lot_num, allo_lot_span) {
  if (!identical(allo_lot_span, "single_day")) return("")
  # Its own newline, like every other fragment here. It splices straight after
  # {span_end}, and glue() trims a template's leading blank line. Without this
  # the guard welds onto the column before it and the statement reads
  # "... <= lot2_start.OBS_END_DTAND lot2_start.LOT2_START_TYPE <> ...".
  paste0("\n", glue("
        AND lot{lot_num}_start.LOT{lot_num}_START_TYPE <> 'SCT_ALLO'"))
}

melp_inject_arm <- function(cfg, line_tbl, start_col, span_end, extra = "") {
  if (!melp_rule_on(cfg)) return("")
  paste0("\n", glue("
      UNION
      SELECT i.PATID, i.INJECT_DT AS MAP_START_DT, '{melp_abbr(cfg)}' AS MAP_MED_TYPE
      FROM melp_inject i
      INNER JOIN {line_tbl} ON {line_tbl}.PATID = i.PATID
      WHERE i.INJECT_DT >  {line_tbl}.{start_col}
        AND i.INJECT_DT <= {span_end}{extra}"))
}

# The same decision, computed against the PREVIOUS line, for the statement that
# picks what starts the next one. med_cand lives in a different statement from
# the line build, so melp_inject is not in scope there and the exemption below
# had nothing to read.
#
# The previous line is the right line to judge against. Inside induction is a
# statement about the line an exposure sits in, and every exposure med_cand is
# looking at sits after the previous line started - so it is that line's window
# the branch table is asking about.
#
# The window expression is the one auto_cand measures in the same statement:
# the ALLO single day, the CAR-T consolidation window, or the previous line's
# own medication window.
melp_prev_line_ctes <- function(cfg, prev_med_window, cart_consolidation_days,
                               lot_num = NULL) {
  if (!melp_rule_on(cfg)) return("")
  # The simplified mode's confirm gate needs the previous regimen's base set
  # and the restart flags, and this splices before either exists in the
  # statement - prev_meds_expanded and map_restart are defined further down.
  # So it emits its own pair, built the same way, from prev_end (in scope).
  # The exploded meds go in their own CTE first: LATERAL VIEW and a JOIN in
  # one FROM do not survive translation.
  pre <- if (melp_rule_on(cfg)) paste0("\n", glue("
    melp_sc_prev AS (
      SELECT pe.PATID, m AS MED_ABBR
      FROM prev_end pe
      LATERAL VIEW explode(split(coalesce(pe.PREV_BASE_MEDS, ''), ' ')) e AS m
      WHERE m <> ''
    ),
    melp_sc_base AS ({regimen_with_subs_sql('melp_sc_prev')}
    ),
    melp_sc_restart AS ({map_restart_sql()}
    ),")) else ""
  ind_end <- glue("CASE
              WHEN prev_end.PREV_START_TYPE = 'SCT_ALLO'
                THEN prev_end.PREV_START_DT
              WHEN prev_end.PREV_START_TYPE = 'CART'
                THEN date_add(prev_end.PREV_START_DT, {cart_consolidation_days - 1})
              ELSE date_add(prev_end.PREV_START_DT, {prev_med_window - 1})
            END")
  # The CAR-T induction rule is LOT1's alone (LOT_RULES.md 6.4), so the
  # exemption is passed only where the previous line IS LOT1 - and LOT1 always
  # starts on a medication, so ind_end resolves to its own 60-day window there.
  # Without it this recomputation reads an in-window CAR-T as a break while the
  # LOT1 statement reads it as part of the line: one decision, computed twice,
  # differently. No planted shape shows a different answer today, but a
  # divergence nothing currently reads is still a divergence.
  cart_from <- if (isTRUE(cfg$apply_cart_induction_rule) &&
                   identical(lot_num, 2L)) ind_end else NULL
  # 3.4's first-transplant exemption is LOT1's alone in the same way, and the
  # same argument applies: LOT1's own statement never lets its first AUTO break
  # the line, wherever it falls, and this recomputation did. So the two
  # disagreed about one course - line 1's build confirmed it and ended the line
  # on the melphalan date, while this statement read the transplant as a break,
  # marked the course TAKEN, and refused to open line 2 there. Line 2 started on
  # the confirming agent's own later date instead, without the melphalan in its
  # regimen, and the days between belonged to no line. Moving line 1's only AUTO
  # from day 59 to day 60 was the whole difference. Planted as P0010.
  paste0(pre, melp_decision_ctes(
    cfg, "prev_end", "PREV_START_DT", "prev_end.OBS_END_DT", ind_end,
    no_regimen_line = "prev_end.PREV_START_TYPE = 'SCT_ALLO'",
    base_tbl = "melp_sc_base", restart_tbl = "melp_sc_restart",
    cart_from = cart_from,
    first_auto_exempt = identical(lot_num, 2L)))
}

# While the rule is on, melphalan's line-advancing decisions belong to it, so
# the prior-regimen exclusion must not veto them. Melphalan already in the
# previous line's regimen is barred from med_cand, and an injected boundary
# would then end a line without opening the next one, leaving the exposure in no
# line. Empty only on a rule-off build, so the study's LOT2-5 candidate list
# does carry this carve-out from the prior-regimen exclusion.
#
# The exemption names the DATES the rule says advance, not the drug: releasing
# melphalan wholesale would let exposures the rule refuses a line open one. The
# dates that MAY advance are exactly melp_inject, so the exemption reads it.
melp_prior_regimen_exempt <- function(cfg, alias = "ms") {
  if (!melp_rule_on(cfg)) return("")
  glue(" OR (upper(trim({alias}.MAP_MED_TYPE)) = '{melp_abbr(cfg)}'
                 AND EXISTS (SELECT 1 FROM melp_inject i
                             WHERE i.PATID = {alias}.PATID
                               AND i.INJECT_DT = {alias}.MAP_START_DT))")
}

# LOT1 is corrected in 06_lot1_end.R rather than in 04, because the decision
# reads lot1_base and that is what 04 builds. Nothing between the two reads the
# add-med columns - 05b takes only LOT1_START_DT and OBS_END_DT - so correcting
# at 06 and correcting at 04 give the same lines.
#
# end_candidates is the one place those columns enter 06, so this is one
# substitution rather than an edit per reference.
# Which melphalan episodes must not INTERRUPT a base drug's run-out chain: the
# SHORT courses outside the line's own induction window, minus the confirmed
# ones. A confirmed course opens a line, so it is a boundary like any other
# agent and has to break the chain; only a suppressed course refuses a boundary
# and so refuses to break one. Read the third column and the previous line's
# chain walks straight through a confirmed course and takes an episode
# belonging to the line that course opened - H4/H4c are that patient.
#
# A course inside induction is in the regimen and the scan already skips it. A
# course longer than the cap is left to the engine untouched (4.7), so it
# breaks the chain like any other drug; removing every melphalan row instead
# made an over-cap course stop ending the line at its own run-out (SM).
melp_short_course_ctes <- function(cfg, verdict) {
  if (!melp_rule_on(cfg)) return("")
  # One relation, and the three questions this test asks are three of its
  # columns rather than a second chaining of the doses and a second judging of
  # length and window - which is how the chain that knew a course was confirmed
  # and the chain that decided the break came to be different chains. Both
  # callers pass a verdict, so the argument is required.
  #
  # AFTER_WINDOW, not INSIDE = 0, and they are not the same question: a course
  # starting BEFORE the line is INSIDE = 0 and is not after the window. This
  # test has always asked the second.
  #
  # INSIDE = 0 would take pre-line courses OUT of the break set and stop them
  # interrupting, which is arguably what 4.7 wants: a course this line judged
  # and SUPPRESSED decides nothing, so it should refuse to break a chain
  # wherever it started. Measured rather than argued - swapping this one
  # predicate changes nothing the validation estate can see, over 618 patients
  # and every planted melphalan and fold-in case - so it stays a rule question
  # for the study team rather than a silent edit.
  paste0("\n", glue("
    melp_no_break AS (
      SELECT DISTINCT PATID, DOSE_DT AS MAP_START_DT
      FROM {verdict}
      WHERE AFTER_WINDOW = 1 AND SHORT = 1
        AND NOT (CONFIRMED = 1 AND TAKEN = 0 AND IN_SPAN = 1
                 AND DOSE_DT = EXPO_DT)
    ),"))
}

# How the interrupt scan reads it: an anti-join, and a test on the joined row.
# NOT an EXISTS in the scan's ON clause - Spark does not accept a correlated
# subquery in a join condition before 4.0 (SPARK-45009), and duckdb does, so
# the harnesses could not have caught it.
#
# The two halves go to discon_per_med_sql together: the join brings the row in,
# the predicate stops it counting as a break. Equivalent to filtering it out in
# the ON clause, because BREAKS is a max() over the group.
melp_boundary_join <- function(cfg) {
  if (!melp_rule_on(cfg)) return("")
  paste0("\n        LEFT JOIN melp_no_break nb2\n",
         "               ON nb2.PATID = o.PATID\n",
         "              AND nb2.MAP_START_DT = o.MAP_START_DT")
}

melp_boundary_break_pred <- function(cfg) {
  if (!melp_rule_on(cfg)) return("")
  paste0("\n                        AND NOT (upper(trim(o.MAP_MED_TYPE)) = '",
         melp_abbr(cfg), "'\n",
         "                                 AND nb2.PATID IS NOT NULL)")
}

# line_from: where LOT1's start and observation end are read from.
#
# 06 has lot1_base and passes it. 04 runs BEFORE lot1_base exists and passes a
# join of lot1_regimen_cutoff to the cohort instead - the same two columns, one
# statement earlier. Parameterised rather than written twice, because the whole
# point is that the two statements judge the courses the same way: 04 used to
# chain the doses and judge length and window for itself, and never ask whether
# a course was confirmed, which is why a confirmed course was no boundary there
# and a boundary in 06.
# end_ctes: emit the half that reads lot1_base itself.
#
# Everything from melp_lot1_base down - the held run-out substituted back in,
# the span it bounds, and the candidate list - belongs to 06, which runs after
# lot1_base exists. 04 runs while lot1_base is BEING created and must take the
# decision half alone.
#
# Taking the whole helper into 04 put a CTE reading FROM lot1_base inside the
# statement that creates it. Spark validates a CTE it never uses, so a clean
# session raises TABLE_OR_VIEW_NOT_FOUND there and a stale relation left over
# from an earlier run hides it - the worse of the two outcomes. duckdb prunes
# an unused CTE before binding it, so the harness ran green over SQL Spark
# would have refused.
melp_lot1_ctes <- function(cfg, line_from = "lot1_base", end_ctes = TRUE) {
  if (!melp_rule_on(cfg)) return("")
  paste0("\n", glue("
    -- The line's own drugs and their permissible substitutes, carrying WHICH
    -- of the two each one is. Same shape as base_meds in 04_lot1_base.R,
    -- because the candidate gate below has to read the same rule that step
    -- reads - see melp_add_candidates.
    -- Spliced rather than written out again, so this rule's idea of which
    -- drugs are one agent cannot drift from the engine's. Written out here, it
    -- expanded the pair one way only and re-derived an added medication the
    -- line itself had already refused.
    melp_base_meds AS ({regimen_with_subs_sql('lot1_induction_meds')}
    ),
    -- Spliced from prior_regimen.R rather than written again here, for the
    -- same reason: one definition of what a restart is.
    melp_map_restart AS ({map_restart_sql()}
    ),
    -- LOT1's induction end, the way 04_lot1_base.R bounds its induction meds.
    -- The window includes its first day, so the last day inside is start + W-1.
    -- LOT1 is always MED-started, so there is no CART or ALLO case here.
    melp_line AS (
      SELECT PATID, LOT1_START_DT, OBS_END_DT,
             date_add(LOT1_START_DT, {cfg$induction_window_days - 1}) AS IND_END_DT
      FROM {line_from}
    ),"),
    # The decision runs over the line's observation. The candidate list keeps
    # 04's own bound at the discontinuation date. Two different questions:
    # which line a dose belongs to, and how late an add can still end it.
    # The base set and restart flags above double as the simplified mode's
    # confirm gate - same tables, so the two rules cannot read different ones.
    melp_decision_ctes(cfg, "melp_line", "LOT1_START_DT", "melp_line.OBS_END_DT",
                       "melp_line.IND_END_DT",
                       base_tbl = "melp_base_meds",
                       restart_tbl = "melp_map_restart",
                       # A CAR-T inside LOT1's own window is part of LOT1
                       # (§6.4), so there it breaks the line only past that
                       # window. One outside it opens the next line as anywhere
                       # else. With the rule off there is no exemption at all.
                       cart_from = if (isTRUE(cfg$apply_cart_induction_rule))
                                     "melp_line.IND_END_DT" else NULL,
                       # 3.4: LOT1's first transplant never ends the line.
                       first_auto_exempt = TRUE),
    if (!end_ctes) "" else glue("
    -- lot1_base with the held run-out substituted, built ONCE and read by
    -- every CTE in 06 that asks when this line ran out.
    --
    -- One table, so every reader in 06 sees the same date. Substituting only at
    -- end_candidates would leave LOT1 reading two run-out dates in one
    -- statement: the post-run-out trigger CTEs would see the original and the
    -- final calculation the held one. A melphalan dose after the original
    -- run-out would then register as a trigger - evidence the patient restarted
    -- - and that trigger would be applied to the HELD run-out, confirming a
    -- discontinuation on a date without the observation the confirmation rule
    -- requires. The candidate list would be bounded at the original date too,
    -- so a drug added between the two could be missed as an addition while the
    -- line ran on past it.
    -- The hold only ever EXTENDS a run-out here, never replaces a NULL one.
    -- LOT1 is always medication-started, so it always has a regimen and a
    -- per-drug cover end: its run-out is NULL only when that cover runs past
    -- observation. Substituting the hold there would end a line on a
    -- suppressed melphalan date while a base drug is still being taken -
    -- turning treatment active at censoring into a discontinuation.
    melp_lot1_base AS (
      SELECT lb0.* EXCEPT (LOT1_BASE_RUNOUT_DT),
             CASE WHEN mh.MELP_HOLD_DT IS NOT NULL
                   AND lb0.LOT1_BASE_RUNOUT_DT IS NOT NULL
                   AND mh.MELP_HOLD_DT > lb0.LOT1_BASE_RUNOUT_DT
                  THEN mh.MELP_HOLD_DT
                  ELSE lb0.LOT1_BASE_RUNOUT_DT END AS LOT1_BASE_RUNOUT_DT
      FROM lot1_base lb0
      LEFT JOIN melp_hold mh ON mh.PATID = lb0.PATID
    ),
    -- The candidate list's own bound, off the held run-out for the same
    -- reason. 04_lot1_base.R stops its candidates at the run-out; carrying the
    -- line past that date without carrying this one leaves the stretch the
    -- hold added unable to produce an addition.
    melp_span AS (
      SELECT ml.PATID, ml.LOT1_START_DT, ml.OBS_END_DT, ml.IND_END_DT,
             coalesce(mb.LOT1_BASE_RUNOUT_DT, ml.OBS_END_DT) AS SPAN_END_DT
      FROM melp_line ml
      INNER JOIN melp_lot1_base mb ON mb.PATID = ml.PATID
    ),
    -- The add-med pick, worked out again with the rule applied. Same span,
    -- same steroid exclusion, the same returning-drug release and the same
    -- hash tie-break as 04_lot1_base.R. A patient with no melphalan gets
    -- the pick that step already made.
    --
    -- The release is why this is not simply every base drug being excluded.
    -- Without it, turning the melphalan rule on would give LOT1 a different
    -- returning-drug rule FOR EVERY PATIENT, melphalan or not: on the synthetic
    -- population that moves 16 patients, 12 of them with no melphalan at all -
    -- including a control whose LEN restarts after a confirmed gap and which
    -- would lose that boundary and its whole second line. With the release, 2
    -- patients move and both take melphalan. A cell that moves patients the
    -- rule cannot touch is not measuring the rule.
    melp_add_candidates AS (
      SELECT ms.PATID, ms.MAP_START_DT, ms.MAP_MED_TYPE
      FROM map_stacked ms
      INNER JOIN melp_span ON melp_span.PATID = ms.PATID
      LEFT JOIN melp_base_meds bm
        ON ms.PATID = bm.PATID AND ms.MAP_MED_TYPE = bm.MED_ABBR
      LEFT JOIN melp_map_restart mr
        ON mr.PATID = ms.PATID AND mr.MAP_MED_TYPE = ms.MAP_MED_TYPE
       AND mr.MAP_START_DT = ms.MAP_START_DT
      WHERE (bm.MED_ABBR IS NULL
{return_release_sql(cfg, 'mr', 'bm')})
        AND ms.MAP_MED_CLASS <> 'STEROID'
        AND ms.MAP_START_DT >= melp_span.LOT1_START_DT
        AND ms.MAP_START_DT <= melp_span.SPAN_END_DT{melp_suppress_predicate(cfg)}
      {melp_inject_arm(cfg, 'melp_span', 'LOT1_START_DT', 'melp_span.SPAN_END_DT')}
    ),
    melp_add_pick AS (
      SELECT PATID, LOT1_BASE_1ST_ADD_MED_DT, LOT1_BASE_1ST_ADD_MED
      FROM (
        SELECT PATID,
               date_sub(MAP_START_DT, 1) AS LOT1_BASE_1ST_ADD_MED_DT,
               MAP_MED_TYPE              AS LOT1_BASE_1ST_ADD_MED,
               row_number() OVER (PARTITION BY PATID
                                  ORDER BY MAP_START_DT,
                                           hash(PATID, MAP_MED_TYPE)) AS rn
        FROM melp_add_candidates
      ) ranked
      WHERE rn = 1
    ),"))
}

# What 06 reads instead of lot1_base. Unchanged when the rule is off. When it
# is on, the two add-med columns are swapped for the new pick. EXCEPT rather
# than naming the columns: lot1_base carries one per medication and one per
# class, so the list is as long as the code list and changes with it.
melp_lot1_verdict_cte <- function(cfg) {
  melp_verdict_cte(cfg, "melp_line", "LOT1_START_DT", "melp_line.OBS_END_DT",
                   "melp_line.IND_END_DT")
}

melp_lot1_base_from <- function(cfg) {
  if (!melp_rule_on(cfg)) return("lot1_base lb")
  # Only the add-med columns are swapped here. melp_add_pick is built after
  # melp_lot1_base and cannot be folded into it. The run-out is not swapped
  # here: melp_lot1_base carries it, so every reader in 06 gets the same date.
  "(SELECT mb.* EXCEPT (LOT1_BASE_1ST_ADD_MED_DT, LOT1_BASE_1ST_ADD_MED),
           mp.LOT1_BASE_1ST_ADD_MED_DT,
           mp.LOT1_BASE_1ST_ADD_MED
    FROM melp_lot1_base mb
    LEFT JOIN melp_add_pick mp ON mp.PATID = mb.PATID) lb"
}

# What every OTHER CTE in 06 reads for this line. Off, it is lot1_base itself.
melp_lot1_base_tbl <- function(cfg) {
  if (!melp_rule_on(cfg)) return("lot1_base lb")
  "melp_lot1_base lb"
}

# The same carry at LOT2-5, where there is no column swap to hang it on: the
# run-out is computed in the statement rather than read off an earlier table.
# Empty when the rule is off, so discon reads exactly as it did.
#
# A NULL run-out means two different things here, and they are told apart the
# way foldin_runout_case tells them apart. A line with NO regimen at all - a
# CAR-T with no consolidation drug - has no run-out to extend, so the hold
# SUPPLIES one, which is what keeps a suppressed exposure after such a line
# inside it. A line whose regimen cover runs past observation also has a NULL
# run-out, and there the hold must NOT substitute: the line would end on a
# suppressed melphalan date while a base drug is still being taken.
# `no_regimen` is the caller's test for the first case; the one call site
# passes the discon_raw join alias.
melp_runout_case <- function(cfg, col, alias = "mh",
                             no_regimen = "d.PATID IS NULL") {
  if (!melp_rule_on(cfg)) return(col)
  glue("CASE WHEN {alias}.MELP_HOLD_DT IS NOT NULL
             AND ((({col}) IS NULL AND {no_regimen})
                  OR {alias}.MELP_HOLD_DT > ({col}))
            THEN {alias}.MELP_HOLD_DT
            ELSE {col} END")
}
# A line whose type ends it on its own start date - a single-day ALLO, or a
# CAR-T line with no consolidation drug - is short-circuited in the end cascade
# BEFORE any run-out is consulted. Carrying the run-out cannot reach such a
# line, so a B.2 pair after one would have both doses outside every line even
# though the hold date exists.
#
# These two fragments let the hold override that short-circuit. The line then
# falls through to the ordinary cascade, where the carried run-out ends it on
# the dose - and every other end still outranks that, so a death or an added
# drug in between takes the line first.
#
# Both are present in the contract build, and empty only on a rule-off one. So
# the study's end cascade DOES carry MELP_HOLD_DT and this override: a line
# whose type would end it on its own start date can be carried past that date by
# a suppressed melphalan course. LOT_RULES.md 4.6 and 7.2 say so where they
# describe those single-day shapes.
melp_hold_col <- function(cfg, alias = "mh") {
  if (!melp_rule_on(cfg)) return("")
  paste0("\n", glue("        {alias}.MELP_HOLD_DT,"))
}
melp_line_type_guard <- function(cfg, lot_num, alias = "ec") {
  if (!melp_rule_on(cfg)) return("")
  paste0("\n", glue("           AND NOT ({alias}.MELP_HOLD_DT IS NOT NULL
                    AND {alias}.MELP_HOLD_DT > {alias}.LOT{lot_num}_START_DT)"))
}

melp_hold_join <- function(cfg, on_alias, alias = "mh") {
  if (!melp_rule_on(cfg)) return("")
  paste0("\n", glue("      LEFT JOIN melp_hold {alias} ON {on_alias}.PATID = {alias}.PATID"))
}

# LOT2-5 needs no such swap. first_add_candidates is inside the statement that
# builds the line, and tx_auto_dates already exists by step 10.
#
# The induction end is the step's own, handed in from build_lot_n()'s arguments
# rather than read off cfg here. A CART-started line closes at the consolidation
# window and an ALLO line has no window at all, and both live in the step. The
# test holds this expression against the one first_add_candidates uses.
# The last day of a line's own induction window, as SQL. A line's window
# depends on what started it, and two rules need the same answer - the
# melphalan rule to say what is inside induction, the fold-in to say which
# procedures belong to the line rather than opening the next one. Written once
# so they cannot drift apart.
lotn_induction_end <- function(lot_num, induction_window_days,
                               cart_consolidation_days) {
  ls <- glue("lot{lot_num}_start")
  glue("CASE
              WHEN {ls}.LOT{lot_num}_START_TYPE = 'SCT_ALLO'
                THEN {ls}.LOT{lot_num}_START_DT
              WHEN {ls}.LOT{lot_num}_START_TYPE = 'CART'
                THEN date_add({ls}.LOT{lot_num}_START_DT, {cart_consolidation_days - 1})
              ELSE date_add({ls}.LOT{lot_num}_START_DT, {induction_window_days - 1})
            END")
}

# The courses an EARLIER line held inside its own induction window.
#
# lot_long carries lines 1..N-1 by the time line N is built, with each line's
# start date and start type, so the window each of them owned is a CASE on the
# same three shapes lotn_induction_end() writes - line 1 keeps its own 60 days,
# an ALLO line is its start date alone, a CAR-T line gets the consolidation
# window, and everything else the LOT2-5 window. One reading of the window, in
# both places.
#
# Empty at LOT1, which has no earlier line, exactly like the fold set.
melp_prior_held_cte <- function(lot_num, induction_window_days,
                                cart_consolidation_days,
                                lot1_induction_window_days) {
  if (lot_num < 2) return("")
  paste0("\n", glue("
    melp_prior_held AS (
      SELECT DISTINCT mc.PATID, mc.EXPO_DT
      FROM melp_course mc
      INNER JOIN lot_long pl
        ON pl.PATID = mc.PATID AND pl.LOT_NUM < {lot_num}
      -- STRICTLY after the earlier line's start. A course that OPENED a line
      -- sits on that line's own first day, so it is trivially inside its
      -- window - and protecting it there would stop the line the transplant
      -- opened next from suppressing it, leaving its later dose an ordinary
      -- candidate with a line of its own (SQ). What this set is for is a
      -- course an earlier line took IN, not one that started it.
      WHERE mc.EXPO_DT > pl.LOT_START_DT
        AND mc.EXPO_DT <= CASE
              WHEN pl.LOT_START_TYPE = 'SCT_ALLO' THEN pl.LOT_START_DT
              WHEN pl.LOT_START_TYPE = 'CART'
                THEN date_add(pl.LOT_START_DT, {cart_consolidation_days - 1})
              WHEN pl.LOT_NUM = 1
                THEN date_add(pl.LOT_START_DT, {lot1_induction_window_days - 1})
              ELSE date_add(pl.LOT_START_DT, {induction_window_days - 1})
            END
    ),"))
}

# The verdict CTE for LOT2-5, bound the same way melp_lotn_ctes binds the
# decision it reads.""
melp_lotn_verdict_cte <- function(cfg, lot_num, induction_window_days,
                                  cart_consolidation_days) {
  if (!melp_rule_on(cfg)) return("")
  ls <- glue("lot{lot_num}_start")
  melp_verdict_cte(cfg, ls, glue("LOT{lot_num}_START_DT"),
                   glue("{ls}.OBS_END_DT"),
                   lotn_induction_end(lot_num, induction_window_days,
                                      cart_consolidation_days))
}

melp_lotn_ctes <- function(cfg, lot_num, induction_window_days,
                           cart_consolidation_days, allo_lot_span,
                           lot1_induction_window_days = 60L) {
  if (!melp_rule_on(cfg)) return("")
  ls <- glue("lot{lot_num}_start")
  # base_meds and map_restart are this statement's own CTEs, defined before
  # this splices - the same ones first_add_candidates reads.
  # A returning prior-line agent is not a NEW agent, so it cannot confirm a
  # short course - LOT_RULES.md 4.7 and 4.8. Only where the fold-in is on, and
  # only from LOT2 up, since LOT1 has no earlier line.
  #
  # The IMMEDIATELY PREVIOUS line, which is the same scope the fold set reads
  # (foldin_lotn_ctes). Reading every earlier line instead made one drug two
  # things at once: a drug last seen two lines back was too old to confirm a
  # course and, since 4.3 excludes only the previous regimen, still new enough
  # to open a line. It then started the next line on its own date while a
  # genuinely new drug in the same position started it on the melphalan date.
  # One scope for both rules, so "not new" cannot mean two things.
  not_new <- if (!isTRUE(cfg$apply_map_foldin) || lot_num < 2) "" else
    paste0("\n", prior_lines_regimen_ctes(glue("ll.LOT_NUM = {lot_num} - 1"),
                                          raw = "melp_prior_raw",
                                          out = "melp_not_new"))
  melp_decision_ctes(
    cfg, ls, glue("LOT{lot_num}_START_DT"), glue("{ls}.OBS_END_DT"),
    lotn_induction_end(lot_num, induction_window_days, cart_consolidation_days),
    base_tbl = "base_meds", restart_tbl = "map_restart",
    not_new_ctes = not_new,
    proc_line = if (!nzchar(not_new)) NULL else
      glue("{ls}.LOT{lot_num}_START_TYPE <> 'MED'"),
    prior_held_ctes = melp_prior_held_cte(lot_num, induction_window_days,
                                          cart_consolidation_days,
                                          lot1_induction_window_days),
    no_regimen_line = glue("{ls}.LOT{lot_num}_START_TYPE = 'SCT_ALLO'"))
}
