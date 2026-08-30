# The melphalan line-advancing rule. Which mode runs is APPLY_MELP_RULE, and
# the study's is 'simplified' - see CONTRACT in build_lot.R and LOT_RULES.md
# 4.7. The other modes, and 'off', are comparison builds: each is a different
# algorithm, so each needs LOT_CONTRACT_OVERRIDE and is recorded as a deviation.
# The cells that build them live in exploration/melphalan/.
#
# The rule is in the engine, not in that folder, because it needs each line's
# induction window, which exists only while that line is being built.
#
# Every mode changes the same one thing: which melphalan MAP rows may be an
# added medication, and on what date. Everything else follows from that.
#
# THE STUDY'S RULE - 'simplified'. A melphalan course covering
# melp_simple_course_days or fewer days, outside the line's induction window,
# does not advance the line on its own: the course is suppressed and the line
# carried to the end of its cover. If another engine-valid agent starts while
# that course still covers, the next line DOES start, and it starts on the
# melphalan date rather than the later agent's - so the course's first day is
# injected as the boundary. A course inside induction, or one longer than the
# cap, is left to the engine untouched. melp_simplified_ctes() below.
#
# The rest of this header is the two five-branch modes, which the study team
# asked for first and did not adopt. They are kept because the comparison that
# chose between them is a cell anyone can rebuild.
#
#   inside induction, next exposure < 180d    no advance
#   inside induction, next >= 180d            the next one advances, on its date
#   outside, next < 60d                       the first advances
#   outside, next 60-179d                     neither advances
#   outside, next >= 180d                     the next one advances, on its date
#
# "Inside induction" compares this exposure's date with this line's induction
# end. It is not about whether melphalan is in the regimen. The two agree only
# for the first dose.
#
# So the rule does two things. It SUPPRESSES candidates outside induction whose
# next exposure is 60+ days away - both doses of a B.2 pair. And it INJECTS the
# advancing dose of a 180+ pair, and the first dose of a B.1 pair, which the
# engine may not otherwise offer.
#
# Suppressing both doses of a B.2 pair stops melphalan ending the line at
# either. It does not on its own keep the second dose INSIDE the line, which
# the request also asks for, so melp_hold carries the line to it.
#
# The two modes differ only where a coded transplant sits on the same event and
# the SCT rule fires too. as_asked judges every exposure anyway. yield_to_sct
# leaves an exposure with an AUTO within melp_sct_days to the transplant rule.
# Both are built as cells and compared. Neither is the answer.
#
# 'simplified' is a different rule, not a third reading of the same one, and it
# is the one the study team adopted. It is stated at the top of this file.
MELP_RULE_MODES <- c("as_asked", "yield_to_sct", "simplified")

# "off" is a mode name like the others, and it is the ONLY way to ask for a
# rule-off build from the environment. Blank cannot do it: load_inputs.R fills
# any variable that is unset OR empty from config.csv, and config.csv now
# carries the contract mode - so APPLY_MELP_RULE= reaches the build as
# 'simplified' and a comparison cell meant to hold the rule off would quietly
# measure the contract against itself. A word survives that fill; an empty
# string does not.
#
# Blank still means off for a cfg built in R rather than from the environment,
# which is how the tests and the emitters construct one.
MELP_RULE_OFF <- "off"

# Read once. An unknown mode stops the build rather than quietly acting like one
# of them. "simplified" is the contract build - see CONTRACT in build_lot.R.
melp_rule_mode <- function(cfg) {
  m <- tolower(trimws(cfg$apply_melp_rule %||% ""))
  if (!nzchar(m) || identical(m, MELP_RULE_OFF)) return("")
  if (!m %in% MELP_RULE_MODES)
    stop("APPLY_MELP_RULE='", m, "' is not one of: ",
         paste(c(MELP_RULE_MODES, MELP_RULE_OFF), collapse = ", "),
         ". The contract build is 'simplified'; '", MELP_RULE_OFF,
         "' builds without the rule and needs LOT_CONTRACT_OVERRIDE.",
         call. = FALSE)
  m
}
melp_rule_on <- function(cfg) nzchar(melp_rule_mode(cfg))
melp_abbr    <- function(cfg) toupper(trimws(cfg$melp_med_abbr %||% "MELP"))

# The exposure chain and the decision, as CTEs. Doses are global; the decision
# is per line. A dose is a dose, but "inside induction" belongs to the line
# being built.
#
# line_tbl / start_col / span_end name that line. induction_end is the step's
# own induction-end expression for it - 60 days at LOT1, 30 at LOT2-5, 45 on a
# CART-started line. It is handed in rather than rebuilt here.
#
# base_tbl / restart_tbl are read only by the simplified mode - see
# melp_simplified_ctes. The five-branch modes never ask what else the patient
# takes, so both stay unused there and their SQL is unchanged.
melp_decision_ctes <- function(cfg, line_tbl, start_col, span_end, induction_end,
                               base_tbl = NULL, restart_tbl = NULL) {
  mode <- melp_rule_mode(cfg)
  if (!nzchar(mode)) return("")
  if (identical(mode, "simplified"))
    return(melp_simplified_ctes(cfg, line_tbl, start_col, span_end,
                                induction_end, base_tbl, restart_tbl))
  abbr <- melp_abbr(cfg)
  yield_this <- if (identical(mode, "yield_to_sct")) "p.HAS_AUTO" else "0"
  yield_next <- if (identical(mode, "yield_to_sct")) "coalesce(p.NEXT_HAS_AUTO, 0)" else "0"
  # Each fragment opens with its own newline. glue() trims a template's leading
  # blank line, so one spliced after "WITH" or after ")," would weld onto it.
  paste0("\n", glue("
    melp_doses AS (
      SELECT PATID, MAP_START_DT AS DOSE_DT
      FROM map_stacked
      WHERE upper(trim(MAP_MED_TYPE)) = '{abbr}'
      GROUP BY PATID, MAP_START_DT
    ),
    -- Chained, not pairwise. Three doses 20 days apart are one
    -- administration. A plain lag() gap would make the third a new exposure at
    -- 40 days from the first, and the rule would judge a pair that is not one.
    melp_runs AS (
      SELECT PATID, DOSE_DT,
             CASE WHEN datediff(DOSE_DT,
                    lag(DOSE_DT) OVER (PARTITION BY PATID ORDER BY DOSE_DT))
                       < {cfg$melp_exposure_days}
                  THEN 0 ELSE 1 END AS IS_NEW
      FROM melp_doses
    ),
    -- Every dose with its exposure's first date. The suppress list has to
    -- reach the LATER doses of a suppressed exposure too. A B.2 exposure made
    -- of doses on days 70 and 98 is one administration. Suppressing only day
    -- 70 left day 98 on the candidate list - the boundary B.2 says is not
    -- there, opened by the second half of the same administration.
    melp_dose_expo AS (
      SELECT PATID, DOSE_DT,
             min(DOSE_DT) OVER (PARTITION BY PATID, E) AS EXPO_DT
      FROM (SELECT PATID, DOSE_DT,
                   sum(IS_NEW) OVER (PARTITION BY PATID ORDER BY DOSE_DT
                                     ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS E
            FROM melp_runs) r
    ),
    melp_expo AS (
      SELECT DISTINCT PATID, EXPO_DT FROM melp_dose_expo
    ),
    melp_expo_sct AS (
      SELECT e.PATID, e.EXPO_DT,
             max(CASE WHEN a.PATID IS NOT NULL THEN 1 ELSE 0 END) AS HAS_AUTO
      FROM melp_expo e
      LEFT JOIN (SELECT DISTINCT PATID, TX_DT FROM tx_auto_dates) a
        ON a.PATID = e.PATID
       AND abs(datediff(a.TX_DT, e.EXPO_DT)) <= {cfg$melp_sct_days}
      GROUP BY e.PATID, e.EXPO_DT
    ),
    melp_pairs AS (
      SELECT PATID, EXPO_DT, HAS_AUTO,
             lead(EXPO_DT)  OVER (PARTITION BY PATID ORDER BY EXPO_DT) AS NEXT_DT,
             lead(HAS_AUTO) OVER (PARTITION BY PATID ORDER BY EXPO_DT) AS NEXT_HAS_AUTO
      FROM melp_expo_sct
    ),
    melp_judged AS (
      SELECT p.PATID, p.EXPO_DT, p.NEXT_DT,
             datediff(p.NEXT_DT, p.EXPO_DT) AS GAP,
             CASE WHEN p.EXPO_DT <= {induction_end} THEN 1 ELSE 0 END AS INSIDE,
             {yield_this} AS YIELD_THIS,
             {yield_next} AS YIELD_NEXT
      FROM melp_pairs p
      INNER JOIN {line_tbl} ON {line_tbl}.PATID = p.PATID
      WHERE p.EXPO_DT >= {line_tbl}.{start_col}
        AND p.EXPO_DT <= {span_end}
    ),
    -- Off the candidate list: the first dose of a B.2 or B.3 pair, and the
    -- later dose of a B.2 one. A yielded exposure is not judged at all, so it
    -- keeps whatever the engine gave it.
    melp_suppress AS (
      SELECT DISTINCT PATID, EXPO_DT AS SUPPRESS_DT
      FROM melp_judged
      WHERE INSIDE = 0 AND YIELD_THIS = 0
        AND GAP IS NOT NULL AND GAP >= {cfg$melp_restart_days}
      UNION
      -- B.2 says both doses stay in the current line, and the arm above only
      -- ever reaches the first of the pair. A trailing exposure has no next
      -- one, so its GAP is NULL. It is judged by nothing and falls through to
      -- the engine, which sees a melphalan MAP outside induction, calls it an
      -- added medication and advances the line at it. That is exactly the
      -- boundary B.2 says is not there. It survived because every other branch
      -- hides it: in A.1 melphalan is in the regimen and a repeat extends the
      -- line instead, and in B.3 the later dose is meant to advance. Only a
      -- B.2 pair whose second dose is the patient's last one shows it.
      --
      -- B.3's later dose is kept out by the upper bound. That one does
      -- advance, on its own date, and the inject arm puts it back.
      SELECT DISTINCT PATID, NEXT_DT AS SUPPRESS_DT
      FROM melp_judged
      WHERE INSIDE = 0 AND YIELD_THIS = 0 AND YIELD_NEXT = 0
        AND GAP IS NOT NULL
        AND GAP >= {cfg$melp_restart_days}
        AND GAP <  {cfg$melp_advance_days}
      UNION
      -- A.1's later exposure. Inside induction with the next one under
      -- melp_advance_days, the rule says the pair does not advance the line -
      -- and that is a statement about the LATER exposure, since the first is
      -- in the regimen and advances nothing by construction.
      --
      -- It needs saying here because the general returning-drug rule would
      -- otherwise release it. Melphalan inside induction is one of the line's
      -- own drugs, so the prior-regimen exclusion holds it - but only while it
      -- is still being taken. A gap of map_discon_gap_days between the two
      -- exposures makes the second a restart, and a restart opens a line like
      -- any other drug's. That general rule and this one disagree on the same
      -- date, and the melphalan branch is the one the request decides.
      --
      -- The upper bound leaves A.2 alone: at melp_advance_days or more the
      -- later exposure DOES advance, and the inject arm puts it back.
      SELECT DISTINCT PATID, NEXT_DT AS SUPPRESS_DT
      FROM melp_judged
      WHERE INSIDE = 1 AND YIELD_THIS = 0 AND YIELD_NEXT = 0
        AND GAP IS NOT NULL
        AND GAP <  {cfg$melp_advance_days}
    ),
    -- The suppressed EXPOSURES, expanded to every dose in them. The decision
    -- is per exposure. The candidate list is per dose. Suppressing only the
    -- exposure's first date left its later doses as candidates - see
    -- melp_dose_expo. Kept apart from melp_suppress so the decision CTE still
    -- reads as the branch table, and so the test harnesses can read its arms.
    melp_suppress_dates AS (
      SELECT DISTINCT d.PATID, d.DOSE_DT AS SUPPRESS_DT
      FROM melp_dose_expo d
      INNER JOIN melp_suppress s
        ON s.PATID = d.PATID AND s.SUPPRESS_DT = d.EXPO_DT
    ),
    -- Back on to it. Two arms, because the rule advances at two dates.
    --
    -- UNRESOLVED, and left as it stands. An arm acting on EXPO_DT needs
    -- YIELD_THIS = 0. An arm acting on NEXT_DT needs both flags. So a pair
    -- whose FIRST dose sat beside a transplant, with none at the second, does
    -- not advance at the second. The other reading - a boundary asks only
    -- about the exposure it falls on - would advance it.
    --
    -- Which is right turns on whether a conditioning dose starts the 180-day
    -- clock for the next one. No worked scenario carries a coded transplant,
    -- so none of them tells the two apart. tests/test_aug1_melp.R pins what
    -- the build does today, so answering the question is a visible change.
    melp_inject AS (
      -- A.2 and B.3: the later dose of a >= 180-day pair, at its own date.
      SELECT DISTINCT PATID, NEXT_DT AS INJECT_DT
      FROM melp_judged
      WHERE GAP IS NOT NULL AND GAP >= {cfg$melp_advance_days}
        AND YIELD_THIS = 0 AND YIELD_NEXT = 0
      UNION
      -- B.1: outside induction with the next dose inside 60 days, so this
      -- dose starts a line. The engine opens that boundary itself unless an
      -- earlier dose put melphalan in the regimen, and then it opens none at
      -- all. So this arm is what keeps B.1 from being lost on a patient whose
      -- first exposure was inside induction. Where the engine did open it, the
      -- row is the same tuple and the UNION folds the two together.
      SELECT DISTINCT PATID, EXPO_DT AS INJECT_DT
      FROM melp_judged
      WHERE INSIDE = 0 AND GAP IS NOT NULL AND GAP < {cfg$melp_restart_days}
        AND YIELD_THIS = 0
    ),
    -- The suppressed exposures again, this time as a date the line is carried
    -- to. It is the SAME list, deliberately: suppressing an exposure and
    -- owning it are two halves of one statement.
    --
    -- Taking a boundary off the candidate list only stops melphalan ENDING
    -- the line there. It does not keep the exposure INSIDE the line, and
    -- where the line's own regimen ran out first, the line ends at that
    -- run-out and the exposure falls outside it - into no line at all, since
    -- the same rule has just refused it as a line start. Every branch that
    -- says an exposure does not advance is therefore also saying which line
    -- it belongs to, and this is where that half is applied.
    --
    -- Every arm of melp_suppress, not just B.2's. All three say the same
    -- thing about their exposure:
    --
    --   B.2 both doses          both doses stay in the current line
    --   A.1 the later exposure  the pair does not advance the LOT
    --   B.3 the first exposure  does not advance for the first dose
    --
    -- Scoping this to B.2 alone left A.1's later exposure and B.3's first one
    -- suppressed but unowned - refused a line of their own by one half of the
    -- rule and not given one by the other.
    --
    -- Dose dates rather than exposure dates, via melp_suppress_dates, so a
    -- suppressed exposure made of several doses is owned to its last one.
    --
    -- Carried on the RUN-OUT rather than as an end reason of its own. The
    -- run-out is where the line's treatment stopped, and under this rule it
    -- did not stop at the regimen: a melphalan administration the request
    -- assigns to this line happened later. Moving that date keeps the whole
    -- end cascade intact - the 90-day confirmation is measured from the dose,
    -- a death or an addition in between still takes the line first, and the
    -- reason stays DISCONTINUATION rather than becoming a fourth
    -- transplant-shaped end nothing else knows about.
    --
    -- Bounded by the line's own span, so an exposure past the end of
    -- observation cannot extend a line beyond it.
    melp_hold AS (
      SELECT s.PATID, max(s.SUPPRESS_DT) AS MELP_HOLD_DT
      FROM melp_suppress_dates s
      INNER JOIN {line_tbl} ON {line_tbl}.PATID = s.PATID
      WHERE s.SUPPRESS_DT >= {line_tbl}.{start_col}
        AND s.SUPPRESS_DT <= {span_end}
      GROUP BY s.PATID
    ),"))
}

# The simplified rule's decision, emitting the same four CTE names the
# consumers read - melp_suppress_dates, melp_inject, melp_hold and the chain
# they hang off - so every splice point downstream is shared with the
# five-branch modes.
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
#
# base_tbl names (PATID, MED_ABBR, SUBSTITUTE_ONLY) for the judged line and
# restart_tbl the restart flags (map_restart_sql's shape). Each caller passes
# the ones already in scope in its statement; melp_prev_line_ctes emits its
# own pair first, because nothing usable exists yet where it splices.
melp_simplified_ctes <- function(cfg, line_tbl, start_col, span_end,
                                 induction_end, base_tbl, restart_tbl) {
  if (is.null(base_tbl) || is.null(restart_tbl))
    stop("The simplified melphalan rule needs the judged line's base set and ",
         "restart flags to tell a confirming agent from a drug the line ",
         "already holds. This caller handed in neither.", call. = FALSE)
  abbr <- melp_abbr(cfg)
  paste0("\n", glue("
    melp_doses AS (
      SELECT PATID, MAP_START_DT AS DOSE_DT
      FROM map_stacked
      WHERE upper(trim(MAP_MED_TYPE)) = '{abbr}'
      GROUP BY PATID, MAP_START_DT
    ),
    -- Chained, not pairwise, like the five-branch modes: doses closer than
    -- melp_exposure_days are one administration.
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
    melp_confirm AS (
      SELECT DISTINCT mc.PATID, mc.EXPO_DT
      FROM melp_course mc
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
       AND cr.MAP_START_DT = c.MAP_START_DT
      WHERE (cb.MED_ABBR IS NULL
             OR (coalesce(cr.PREV_DISCON, 0) = 1 AND cb.SUBSTITUTE_ONLY = 0))
    ),
    -- A course belongs to ONE line: the latest whose start precedes it.
    --
    -- Without this the bounds below - the line start to OBSERVATION end - let
    -- every line claim every later course, and melp_hold takes the max, so the
    -- FIRST line is carried to the LAST suppressed course in the record. A
    -- patient with LEN to day 200, a second line opening at day 300 and a lone
    -- melphalan course at day 900 had line 1 ending day 299 MED_ADD, its real
    -- day-200 discontinuation gone, and line 2 carried to day 927.
    --
    -- The test is an intervening line-defining agent, not a gap. A course long
    -- after the drugs ran out still belongs to the line when nothing else
    -- happened in between - that is the request's own case, and the planted SE
    -- patient pins it. What disqualifies a course is another agent the engine
    -- would open a line on, arriving first: the line ends there, and what comes
    -- after belongs to the line that agent started.
    --
    -- Same candidate gate as melp_confirm below, so ownership and confirmation
    -- cannot disagree about what counts as an agent.
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
       AND orr.MAP_START_DT = o.MAP_START_DT
      WHERE (ob.MED_ABBR IS NULL
             OR (coalesce(orr.PREV_DISCON, 0) = 1 AND ob.SUBSTITUTE_ONLY = 0))
      UNION
      -- A line can also be opened by a procedure, and a course after one is
      -- no more this line's than a course after a new drug. Scanning
      -- medications alone left exactly that hole: a CAR-T opening line 2 on
      -- day 100 did not stop line 1 claiming a course on day 200, and line
      -- 1's own day-50 discontinuation became a day-99 SCT_CART end.
      --
      -- Measured from the line's INDUCTION END, not its start: a transplant
      -- inside a line's own window belongs to that line and ends nothing
      -- (LOT_RULES.md 3.4 and 6.5), so it must not disqualify the line from
      -- a course of its own afterwards. One past the window is a boundary.
      SELECT DISTINCT mc.PATID, mc.EXPO_DT
      FROM melp_course mc
      INNER JOIN {line_tbl} ON {line_tbl}.PATID = mc.PATID
      INNER JOIN (SELECT DISTINCT PATID, TX_DT FROM tx_auto_dates
                  UNION
                  SELECT DISTINCT PATID, TX_DT FROM tx_allo_cart_dates) tx
        ON tx.PATID = mc.PATID
       AND tx.TX_DT >  {induction_end}
       AND tx.TX_DT <= mc.EXPO_DT
    ),
    melp_judged AS (
      SELECT mc.PATID, mc.EXPO_DT,
             CASE WHEN mc.EXPO_DT <= {induction_end} THEN 1 ELSE 0 END AS INSIDE,
             CASE WHEN datediff(mc.COURSE_END_DT, mc.EXPO_DT) + 1
                       <= {cfg$melp_simple_course_days} THEN 1 ELSE 0 END AS SHORT,
             CASE WHEN cf.PATID IS NOT NULL THEN 1 ELSE 0 END AS CONFIRMED
      FROM melp_course mc
      LEFT JOIN melp_confirm cf
        ON cf.PATID = mc.PATID AND cf.EXPO_DT = mc.EXPO_DT
      INNER JOIN {line_tbl} ON {line_tbl}.PATID = mc.PATID
      LEFT JOIN melp_taken tk
        ON tk.PATID = mc.PATID AND tk.EXPO_DT = mc.EXPO_DT
      WHERE mc.EXPO_DT >= {line_tbl}.{start_col}
        AND mc.EXPO_DT <= {span_end}
        AND tk.PATID IS NULL
    ),
    -- A short unconfirmed course outside induction neither ends the line nor
    -- starts one...
    melp_suppress AS (
      SELECT DISTINCT PATID, EXPO_DT AS SUPPRESS_DT
      FROM melp_judged
      WHERE INSIDE = 0 AND SHORT = 1 AND CONFIRMED = 0
    ),
    -- ...and every dose in it comes off the candidate list, not just the
    -- first - same reason as the five-branch modes.
    melp_suppress_dates AS (
      SELECT DISTINCT d.PATID, d.DOSE_DT AS SUPPRESS_DT
      FROM melp_dose_expo d
      INNER JOIN melp_suppress s
        ON s.PATID = d.PATID AND s.SUPPRESS_DT = d.EXPO_DT
    ),
    -- A confirmed short course advances - on ITS first day. The confirming
    -- agent needs no help of its own: it is an engine candidate already, and
    -- later than this date by construction.
    melp_inject AS (
      SELECT DISTINCT PATID, EXPO_DT AS INJECT_DT
      FROM melp_judged
      WHERE INSIDE = 0 AND SHORT = 1 AND CONFIRMED = 1
    ),
    -- Suppressing and owning are two halves of one statement, exactly as in
    -- the five-branch modes: the line is carried to the course it refused a
    -- boundary to. Carried to the course's LAST COVERED DAY, not its first
    -- dose - 'received for 28 days' is a statement about cover, and the
    -- short test above already measures cover, so ownership reads the same
    -- clock. The five-branch modes hold to dose dates because their branch
    -- table is written in dose dates; this rule is written in days of
    -- supply. Capped at the line's own span.
    melp_hold AS (
      SELECT s.PATID, max(least(c.COURSE_END_DT, {span_end})) AS MELP_HOLD_DT
      FROM melp_suppress s
      INNER JOIN melp_course c
        ON c.PATID = s.PATID AND c.EXPO_DT = s.SUPPRESS_DT
      INNER JOIN {line_tbl} ON {line_tbl}.PATID = s.PATID
      WHERE s.SUPPRESS_DT >= {line_tbl}.{start_col}
        AND s.SUPPRESS_DT <= {span_end}
      GROUP BY s.PATID
    ),"))
}

# Takes a suppressed MELPHALAN row off the engine's own candidate list. Empty
# when the rule is off, so the predicate chain it sits in is unchanged.
#
# Melphalan rows only, and dose dates rather than exposure dates. The rule's
# whole contract is that it changes which melphalan rows may be an added
# medication, and nothing else. A date-only match also removed any OTHER drug
# starting on a suppressed date, so a same-day switch to a new drug lost its
# boundary and the line never ended.
melp_suppress_predicate <- function(cfg, alias = "ms") {
  if (!melp_rule_on(cfg)) return("")
  paste0("\n", glue("
        AND NOT (upper(trim({alias}.MAP_MED_TYPE)) = '{melp_abbr(cfg)}'
                 AND EXISTS (SELECT 1 FROM melp_suppress_dates s
                             WHERE s.PATID = {alias}.PATID
                               AND s.SUPPRESS_DT = {alias}.MAP_START_DT))"))
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
melp_prev_line_ctes <- function(cfg, prev_med_window, cart_consolidation_days) {
  if (!melp_rule_on(cfg)) return("")
  # The simplified mode's confirm gate needs the previous regimen's base set
  # and the restart flags, and this splices before either exists in the
  # statement - prev_meds_expanded and map_restart are defined further down.
  # So it emits its own pair, built the same way, from prev_end (in scope).
  # The exploded meds go in their own CTE first: LATERAL VIEW and a JOIN in
  # one FROM do not survive translation.
  pre <- if (identical(melp_rule_mode(cfg), "simplified")) paste0("\n", glue("
    melp_sc_prev AS (
      SELECT pe.PATID, m AS MED_ABBR
      FROM prev_end pe
      LATERAL VIEW explode(split(coalesce(pe.PREV_BASE_MEDS, ''), ' ')) e AS m
      WHERE m <> ''
    ),
    melp_sc_base AS (
      SELECT PATID, MED_ABBR, min(IS_SUB) AS SUBSTITUTE_ONLY
      FROM (
        SELECT PATID, MED_ABBR, 0 AS IS_SUB FROM melp_sc_prev
        UNION ALL
        SELECT p.PATID, ps.substitute_med AS MED_ABBR, 1 AS IS_SUB
        FROM melp_sc_prev p
        INNER JOIN permissible_subs ps ON p.MED_ABBR = ps.original_med
      )
      GROUP BY PATID, MED_ABBR
    ),
    melp_sc_restart AS ({map_restart_sql()}
    ),")) else ""
  paste0(pre, melp_decision_ctes(
    cfg, "prev_end", "PREV_START_DT", "prev_end.OBS_END_DT",
    glue("CASE
              WHEN prev_end.PREV_START_TYPE = 'SCT_ALLO'
                THEN prev_end.PREV_START_DT
              WHEN prev_end.PREV_START_TYPE = 'CART'
                THEN date_add(prev_end.PREV_START_DT, {cart_consolidation_days - 1})
              ELSE date_add(prev_end.PREV_START_DT, {prev_med_window - 1})
            END"),
    base_tbl = "melp_sc_base", restart_tbl = "melp_sc_restart"))
}

# While the rule is on, melphalan's line-advancing decisions belong to it, so
# the prior-regimen exclusion must not veto them. Melphalan already in the
# previous line's regimen is barred from med_cand, and an injected boundary
# would then end a line without opening the next one, leaving the exposure in no
# line. Empty only on a rule-off build, so the study's LOT2-5 candidate list
# does carry this carve-out from the prior-regimen exclusion.
#
# The exemption names the DATES the rule says advance, not the drug. Releasing
# every melphalan row would be wider than any branch allows:
#
#   the first exposure of a B.2 pair          - both doses stay in the line
#   the later exposure of a B.2 pair          - the same
#   the first exposure of a B.3 pair          - only the later one advances
#   the later exposure of an A.1 pair         - the pair does not advance
#
# All four could then open a line, and the branch table says none of them may.
# The dates that MAY are exactly melp_inject: B.1's first exposure, and the
# later exposure of an A.2 or B.3 pair. So the exemption reads that list.
melp_prior_regimen_exempt <- function(cfg, alias = "ms") {
  if (!melp_rule_on(cfg)) return("")
  glue(" OR (upper(trim({alias}.MAP_MED_TYPE)) = '{melp_abbr(cfg)}'
                 AND EXISTS (SELECT 1 FROM melp_inject i
                             WHERE i.PATID = {alias}.PATID
                               AND i.INJECT_DT = {alias}.MAP_START_DT))")
}

# LOT1 is corrected in 06_lot1_end.R rather than in 04. yield_to_sct needs
# tx_auto_dates, and that view is built in 05. Nothing between the two reads the
# add-med columns - 05b takes only LOT1_START_DT and OBS_END_DT - so correcting
# at 06 and correcting at 04 give the same lines.
#
# end_candidates is the one place those columns enter 06, so this is one
# substitution rather than an edit per reference.
melp_lot1_ctes <- function(cfg) {
  if (!melp_rule_on(cfg)) return("")
  paste0("\n", glue("
    -- The line's own drugs and their permissible substitutes, carrying WHICH
    -- of the two each one is. Same shape as base_meds in 04_lot1_base.R,
    -- because the candidate gate below has to read the same rule that step
    -- reads - see melp_add_candidates.
    melp_base_meds AS (
      SELECT PATID, MED_ABBR, min(IS_SUB) AS SUBSTITUTE_ONLY
      FROM (
        SELECT PATID, MED_ABBR, 0 AS IS_SUB FROM lot1_induction_meds
        UNION ALL
        SELECT im.PATID, ps.substitute_med AS MED_ABBR, 1 AS IS_SUB
        FROM lot1_induction_meds im
        INNER JOIN permissible_subs ps ON im.MED_ABBR = ps.original_med
      )
      GROUP BY PATID, MED_ABBR
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
      FROM lot1_base
    ),"),
    # The decision runs over the line's observation. The candidate list keeps
    # 04's own bound at the discontinuation date. Two different questions:
    # which line a dose belongs to, and how late an add can still end it.
    # The base set and restart flags above double as the simplified mode's
    # confirm gate - same tables, so the two rules cannot read different ones.
    melp_decision_ctes(cfg, "melp_line", "LOT1_START_DT", "melp_line.OBS_END_DT",
                       "melp_line.IND_END_DT",
                       base_tbl = "melp_base_meds",
                       restart_tbl = "melp_map_restart"),
    glue("
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
    -- rand(42) tie-break as 04_lot1_base.R. A patient with no melphalan gets
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
             OR (coalesce(mr.PREV_DISCON, 0) = 1 AND bm.SUBSTITUTE_ONLY = 0))
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
                                  ORDER BY MAP_START_DT, rand(42)) AS rn
        FROM melp_add_candidates
      ) ranked
      WHERE rn = 1
    ),"))
}

# What 06 reads instead of lot1_base. Unchanged when the rule is off. When it
# is on, the two add-med columns are swapped for the new pick. EXCEPT rather
# than naming the columns: lot1_base carries one per medication and one per
# class, so the list is as long as the code list and changes with it.
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
melp_lotn_ctes <- function(cfg, lot_num, induction_window_days,
                           cart_consolidation_days, allo_lot_span) {
  if (!melp_rule_on(cfg)) return("")
  ls <- glue("lot{lot_num}_start")
  # base_meds and map_restart are this statement's own CTEs, defined before
  # this splices - the same ones first_add_candidates reads.
  melp_decision_ctes(
    cfg, ls, glue("LOT{lot_num}_START_DT"), glue("{ls}.OBS_END_DT"),
    glue("CASE
              WHEN {ls}.LOT{lot_num}_START_TYPE = 'SCT_ALLO'
                THEN {ls}.LOT{lot_num}_START_DT
              WHEN {ls}.LOT{lot_num}_START_TYPE = 'CART'
                THEN date_add({ls}.LOT{lot_num}_START_DT, {cart_consolidation_days - 1})
              ELSE date_add({ls}.LOT{lot_num}_START_DT, {induction_window_days - 1})
            END"),
    base_tbl = "base_meds", restart_tbl = "map_restart")
}
