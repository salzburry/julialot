# The melphalan line-advancing rule, as an engine rule. Off unless
# APPLY_MELP_RULE names a mode, and off emits the same SQL as not having it.
#
# The ask, the cells and the comparison live in aug1_melp/. The rule itself is
# here because lot builds its own lines and reads nothing from a sibling
# package, and because the rule needs each line's own induction window - which
# only exists while that line is being built.
#
# It changes one thing: which melphalan MAP rows may be an added medication, and
# on what date. Everything else follows, because an added medication is what
# ends a line and starts the next one.
#
#   inside induction, next exposure < 180d    no advance          (engine agrees)
#   inside induction, next exposure >= 180d   the next one advances, on its date
#   outside, next < 60d                       the first advances  (engine agrees)
#   outside, next 60-179d                     neither advances
#   outside, next >= 180d                     the next one advances, on its date
#
# "Inside induction" is this exposure's date against this line's induction end,
# not whether the drug is in the regimen. Those are the same thing only for the
# first dose. A patient dosed on day 10 and again on day 100 has melphalan in
# the base regimen throughout, but the day-100 dose is outside the window and
# starts a B branch - and reading it off the regimen would call it A and lose
# the boundary. The induction end is the expression the step itself uses to
# bound its candidates, passed in rather than restated, so the rule and the
# engine cannot disagree about where the window closes.
#
# So the rule is two edits to the add-med candidates:
#
#   SUPPRESS  an exposure the engine takes as an add and the rule does not:
#             outside induction, next exposure 60 days or more away. B.2 and
#             B.3, where the first dose does not advance.
#
#             This stops melphalan ENDING the line. It does not hold the line
#             open: a line's discontinuation is its BASE agents' last cover, and
#             a melphalan first seen outside induction is not one of them. So
#             where the base regimen runs out between the two exposures, the
#             line ends there and the second exposure starts the next one under
#             the ordinary new-therapy rule. B.2 as written says both doses stay
#             in the current line, which would need melphalan to join a regimen
#             it never entered the induction window for - a concept this
#             algorithm does not have, and a clinical decision rather than an
#             implementation one. Both modes take this narrow reading, so
#             neither is the request implemented to the letter. Open question 6
#             in questions/melphalan_lot_rule.md; n_b2_line_starts counts the
#             lines it decides.
#   INJECT    an exposure the rule advances at and the engine has no candidate
#             for. Two of them:
#               the later dose of a >= 180-day pair, at its own date (A.2, B.3);
#               the first dose of a B.1 pair, where an earlier dose already put
#               melphalan in the regimen - so the engine makes no candidate at
#               any melphalan date in that line, and B.1's boundary would
#               otherwise be lost.
#
# A.1 needs neither. B.1 needs nothing where melphalan is not a base agent: the
# engine already opens a boundary there, and the injected row is the same
# (patient, date, drug) tuple, which the UNION folds together.
#
# Modes, for the case the ask does not cover - a coded transplant on the same
# event, where the SCT rule fires too:
#
#   as_asked      every exposure is judged, whatever is coded on it, so one
#                 clinical event can end a line twice. Named for the transplant
#                 reading - the ask carves nothing out - not for the whole rule.
#   yield_to_sct  an exposure with an AUTO coded within melp_sct_days is left to
#                 the transplant rule, which already allows a tandem inside 180
#                 days and ends the line on an excess one. The melphalan rule
#                 then fills only the gap where a transplant left no code.
#
# Both are built as cells and compared. Neither is treated as the answer.
MELP_RULE_MODES <- c("as_asked", "yield_to_sct")

# Read once. An unknown mode stops the build rather than quietly behaving like
# one of them, and "" is the contract build.
melp_rule_mode <- function(cfg) {
  m <- tolower(trimws(cfg$apply_melp_rule %||% ""))
  if (!nzchar(m)) return("")
  if (!m %in% MELP_RULE_MODES)
    stop("APPLY_MELP_RULE='", m, "' is not one of: ",
         paste(MELP_RULE_MODES, collapse = ", "),
         ". Leave it unset for the contract build.", call. = FALSE)
  m
}
melp_rule_on <- function(cfg) nzchar(melp_rule_mode(cfg))
melp_abbr    <- function(cfg) toupper(trimws(cfg$melp_med_abbr %||% "MELP"))

# The exposure chain and the decision, as CTEs. Global doses, per-line decision:
# a dose is a dose, but "inside induction" belongs to the line being built.
#
# line_tbl / start_col / span_end name that line. induction_end is the step's
# own induction-end expression for it - 60 days at LOT1, 30 at LOT2-5, 45 on a
# CART-started line - handed in rather than rebuilt here.
melp_decision_ctes <- function(cfg, line_tbl, start_col, span_end, induction_end) {
  mode <- melp_rule_mode(cfg)
  if (!nzchar(mode)) return("")
  abbr <- melp_abbr(cfg)
  yield_this <- if (identical(mode, "yield_to_sct")) "p.HAS_AUTO" else "0"
  yield_next <- if (identical(mode, "yield_to_sct")) "coalesce(p.NEXT_HAS_AUTO, 0)" else "0"
  # Each fragment opens with its own newline: glue() trims a template's leading
  # blank line, so one spliced after "WITH" or after ")," welds onto it.
  paste0("\n", glue("
    melp_doses AS (
      SELECT PATID, MAP_START_DT AS DOSE_DT
      FROM map_stacked
      WHERE upper(trim(MAP_MED_TYPE)) = '{abbr}'
      GROUP BY PATID, MAP_START_DT
    ),
    -- Chained, not pairwise: three doses 20 days apart are one administration.
    -- A plain lag() gap would make the third a new exposure at 40 days from the
    -- first, and the rule would judge a pair that is not one.
    melp_runs AS (
      SELECT PATID, DOSE_DT,
             CASE WHEN datediff(DOSE_DT,
                    lag(DOSE_DT) OVER (PARTITION BY PATID ORDER BY DOSE_DT))
                       < {cfg$melp_exposure_days}
                  THEN 0 ELSE 1 END AS IS_NEW
      FROM melp_doses
    ),
    melp_expo AS (
      SELECT PATID, min(DOSE_DT) AS EXPO_DT
      FROM (SELECT PATID, DOSE_DT,
                   sum(IS_NEW) OVER (PARTITION BY PATID ORDER BY DOSE_DT
                                     ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS E
            FROM melp_runs) r
      GROUP BY PATID, E
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
    -- Off the candidate list: the first dose of a B.2 or B.3 pair. A yielded
    -- exposure is not judged at all, so it keeps whatever the engine did.
    melp_suppress AS (
      SELECT DISTINCT PATID, EXPO_DT AS SUPPRESS_DT
      FROM melp_judged
      WHERE INSIDE = 0 AND YIELD_THIS = 0
        AND GAP IS NOT NULL AND GAP >= {cfg$melp_restart_days}
    ),
    -- On to it. Two arms, because the rule advances at two different dates and
    -- yielding looks at whichever exposure the boundary would fall on.
    melp_inject AS (
      -- A.2 and B.3: the later dose of a >= 180-day pair, at its own date.
      SELECT DISTINCT PATID, NEXT_DT AS INJECT_DT
      FROM melp_judged
      WHERE GAP IS NOT NULL AND GAP >= {cfg$melp_advance_days}
        AND YIELD_THIS = 0 AND YIELD_NEXT = 0
      UNION
      -- B.1: outside induction with the next dose inside 60 days, so this dose
      -- starts a line. The engine opens that boundary itself unless an earlier
      -- dose put melphalan in the regimen, and then it opens none at all - so
      -- this arm is what keeps B.1 from being lost on a patient whose first
      -- exposure was inside induction. Where the engine did open it, the row is
      -- the same tuple and the UNION folds the two together.
      SELECT DISTINCT PATID, EXPO_DT AS INJECT_DT
      FROM melp_judged
      WHERE INSIDE = 0 AND GAP IS NOT NULL AND GAP < {cfg$melp_restart_days}
        AND YIELD_THIS = 0
    ),"))
}

# Takes a suppressed date off the engine's own candidate list. Empty when off,
# so the predicate chain it sits in is unchanged.
melp_suppress_predicate <- function(cfg, alias = "ms") {
  if (!melp_rule_on(cfg)) return("")
  paste0("\n", glue("
        AND NOT EXISTS (SELECT 1 FROM melp_suppress s
                        WHERE s.PATID = {alias}.PATID
                          AND s.SUPPRESS_DT = {alias}.MAP_START_DT)"))
}

# The rows the rule adds, as a UNION arm on first_add_candidates. Bounded to the
# line the way the engine bounds its own candidates, so an injected date outside
# it cannot open a boundary. Strictly after the start: a date that already
# starts the line is already a boundary.
# An ALLO line under single_day ends on the ALLO date itself, so an add cannot
# end it and an injected candidate must not either. The engine excludes those
# lines from its own candidates; this is the same exclusion, so the rule cannot
# open a boundary the engine has no concept of.
melp_allo_guard <- function(lot_num, allo_lot_span) {
  if (!identical(allo_lot_span, "single_day")) return("")
  glue("
        AND lot{lot_num}_start.LOT{lot_num}_START_TYPE <> 'SCT_ALLO'")
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

# LOT1 is corrected in 06_lot1_end.R rather than in 04, because yield_to_sct
# needs tx_auto_dates and that view is built in 05. Nothing between the two
# reads the add-med columns - 05b takes only LOT1_START_DT and OBS_END_DT - so
# correcting at 06 and correcting at 04 give the same lines.
#
# end_candidates is the one place the columns enter 06, so this is one
# substitution rather than an edit per reference.
melp_lot1_ctes <- function(cfg) {
  if (!melp_rule_on(cfg)) return("")
  paste0("\n", glue("
    melp_base_meds AS (
      SELECT PATID, MED_ABBR FROM lot1_induction_meds
      UNION
      SELECT im.PATID, ps.substitute_med AS MED_ABBR
      FROM lot1_induction_meds im
      INNER JOIN permissible_subs ps ON im.MED_ABBR = ps.original_med
    ),
    -- LOT1's induction end, the way 04_lot1_base.R bounds its induction meds:
    -- the window includes its first day, so the last day inside is start + W-1.
    -- LOT1 is always MED-started, so there is no CART or ALLO case here.
    melp_line AS (
      SELECT PATID, LOT1_START_DT, OBS_END_DT,
             date_add(LOT1_START_DT, {cfg$induction_window_days - 1}) AS IND_END_DT,
             coalesce(LOT1_BASE_DISCON_DT, OBS_END_DT) AS SPAN_END_DT
      FROM lot1_base
    ),"),
    # The decision runs over the line's observation, and the candidate list
    # keeps 04's own bound at the discontinuation date. Two different questions:
    # which line a dose belongs to, and how late an add can still end it.
    melp_decision_ctes(cfg, "melp_line", "LOT1_START_DT", "melp_line.OBS_END_DT",
                       "melp_line.IND_END_DT"),
    glue("
    -- The add-med pick, recomputed with the rule applied. Same span, same
    -- steroid exclusion and the same rand(42) tie-break as 04_lot1_base.R, so
    -- a patient with no melphalan gets the pick that step already made.
    melp_add_candidates AS (
      SELECT ms.PATID, ms.MAP_START_DT, ms.MAP_MED_TYPE
      FROM map_stacked ms
      INNER JOIN melp_line ON melp_line.PATID = ms.PATID
      LEFT JOIN melp_base_meds bm
        ON ms.PATID = bm.PATID AND ms.MAP_MED_TYPE = bm.MED_ABBR
      WHERE bm.MED_ABBR IS NULL
        AND ms.MAP_MED_CLASS <> 'STEROID'
        AND ms.MAP_START_DT >= melp_line.LOT1_START_DT
        AND ms.MAP_START_DT <= melp_line.SPAN_END_DT{melp_suppress_predicate(cfg)}
      {melp_inject_arm(cfg, 'melp_line', 'LOT1_START_DT', 'melp_line.SPAN_END_DT')}
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

# What 06 reads instead of lot1_base. Unchanged when the rule is off, and the
# two add-med columns swapped for the recomputed pick when it is on. EXCEPT
# rather than naming the columns: lot1_base carries one per medication and one
# per class, so the list is the code list's length and changes with it.
melp_lot1_base_from <- function(cfg) {
  if (!melp_rule_on(cfg)) return("lot1_base lb")
  "(SELECT lb0.* EXCEPT (LOT1_BASE_1ST_ADD_MED_DT, LOT1_BASE_1ST_ADD_MED),
           mp.LOT1_BASE_1ST_ADD_MED_DT,
           mp.LOT1_BASE_1ST_ADD_MED
    FROM lot1_base lb0
    LEFT JOIN melp_add_pick mp ON mp.PATID = lb0.PATID) lb"
}

# LOT2-5 needs no such swap: first_add_candidates is inside the statement that
# builds the line, and tx_auto_dates already exists by step 10.
# The induction end is the step's own, handed in from build_lot_n()'s arguments
# rather than read off cfg here: a CART-started line closes at the consolidation
# window and an ALLO line has no window at all, and those live in the step. The
# test holds this expression against the one first_add_candidates uses.
melp_lotn_ctes <- function(cfg, lot_num, induction_window_days,
                           cart_consolidation_days, allo_lot_span) {
  if (!melp_rule_on(cfg)) return("")
  ls <- glue("lot{lot_num}_start")
  melp_decision_ctes(
    cfg, ls, glue("LOT{lot_num}_START_DT"), glue("{ls}.OBS_END_DT"),
    glue("CASE
              WHEN {ls}.LOT{lot_num}_START_TYPE = 'SCT_ALLO'
                THEN {ls}.LOT{lot_num}_START_DT
              WHEN {ls}.LOT{lot_num}_START_TYPE = 'CART'
                THEN date_add({ls}.LOT{lot_num}_START_DT, {cart_consolidation_days - 1})
              ELSE date_add({ls}.LOT{lot_num}_START_DT, {induction_window_days - 1})
            END"))
}
