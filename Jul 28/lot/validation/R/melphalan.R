# The melphalan line-advancing rule, measured against a finished run.
# See lot/FILES.md, under lot/melphalan/, for the rule as proposed.
#
# An exposure is one administration; doses under MELP_EXPOSURE_DAYS apart are the
# same one. Consecutive pairs, so a third is judged against the second.
#
#   first exposure inside its line's induction window
#     next < 180d    no advance
#     next >= 180d   the next exposure starts a line
#   first exposure outside it
#     next < 60d     the first exposure starts a line
#     next 60-179d   no advance
#     next >= 180d   the next exposure starts a line
#
# Changes nothing in lot. Counts the line boundaries the rule adds and removes -
# not a resulting line count, which needs a build: moving a boundary changes
# which line an exposure falls in, induction membership, regimens and every
# later line number.
#
# Placement trap: the build ends a line the day before an added drug, so a
# melphalan dose outside the induction window sits on day 0 of the line it
# created. Measured against that line it reads as inside induction, turning
# every B branch into an A. The reference line is the previous one wherever this
# drug made the boundary.

MELP_SETTINGS <- list(
  abbr          = list(env = "MELP_MED_ABBR",      default = "MELP",
                       what = "the medication abbreviation the rule is about"),
  exposure_days = list(env = "MELP_EXPOSURE_DAYS", default = 30L,
                       what = "doses closer together than this are one exposure"),
  restart_days  = list(env = "MELP_RESTART_DAYS",  default = 60L,
                       what = "outside induction, a next exposure sooner than this advances at the FIRST dose"),
  advance_days  = list(env = "MELP_ADVANCE_DAYS",  default = 180L,
                       what = "a next exposure at or beyond this advances at ITS OWN date"),
  induction_1l  = list(env = "INDUCTION_WINDOW_DAYS", default = 60L,
                       what = "LOT1's induction window, as the build applies it"),
  induction_n   = list(env = "INDUCTION_WINDOW_DAYS_LOT_N", default = 30L,
                       what = "the same window for LOT2 and later"))

# Two readings of what happens when a coded transplant sits on the same event.
# The ask does not say - it describes the rule in isolation - so both are here
# and the run says which it used.
#
#   as_asked        every exposure is judged, whether or not an AUTO is coded on
#                   it. The rule as written.
#   yield_to_sct    an exposure with an AUTO coded within melp_sct_days is left
#                   to the transplant rule, which already allows a tandem within
#                   180 days and ends the line on an excess one. The rule then
#                   only fills the gap where a transplant left no procedure code.
MELP_MODES <- c("as_asked", "yield_to_sct")

melp_cfg <- function(env = Sys.getenv) {
  out <- lapply(MELP_SETTINGS, function(s) {
    v <- trimws(env(s$env, unset = ""))
    if (!nzchar(v)) return(s$default)
    if (is.character(s$default)) return(v)
    if (!grepl("^[0-9]+$", v))
      stop(s$env, "='", v, "' (want a whole number)", call. = FALSE)
    as.integer(v)
  })
  m <- tolower(trimws(env("MELP_RULE_MODE", unset = "yield_to_sct")))
  if (!m %in% MELP_MODES)
    stop("MELP_RULE_MODE='", m, "' is not one of: ",
         paste(MELP_MODES, collapse = ", "), call. = FALSE)
  out$mode <- m
  out$sct_days <- {
    v <- trimws(env("MELP_SCT_DAYS", unset = ""))
    if (!nzchar(v)) 14L else if (grepl("^[0-9]+$", v)) as.integer(v) else
      stop("MELP_SCT_DAYS='", v, "' (want a whole number)", call. = FALSE)
  }
  out
}

# Exposures, then the rule, then what it would do to the line boundaries.
#
# One statement, so every count comes off the same reading of the doses. The
# lines table supplies both the line a dose falls in and the induction window
# that applies to it, which differs at LOT1 and later.
melp_rule_sql <- function(lines_tbl, map_tbl, auto_tbl, cfg, run_id,
                          lot_run = NA_character_, lot_stamp = NA_character_) {
  # Chained, not pairwise: three doses 20 days apart are one exposure, which is
  # what "one administration" means. A plain lag() gap would make the third a
  # new exposure because it is 40 days from the first.
  glue("
    WITH doses AS (
      SELECT cast(PATID as string) AS PATID,
             cast(MAP_START_DT as date) AS DOSE_DT
      FROM {map_tbl}
      WHERE upper(trim(MAP_MED_TYPE)) = upper('{cfg$abbr}')
      GROUP BY 1, 2
    ),
    runs AS (
      SELECT PATID, DOSE_DT,
             CASE WHEN datediff(DOSE_DT,
                    lag(DOSE_DT) OVER (PARTITION BY PATID ORDER BY DOSE_DT))
                       < {cfg$exposure_days}
                  THEN 0 ELSE 1 END AS IS_NEW
      FROM doses
    ),
    expo_id AS (
      SELECT PATID, DOSE_DT,
             sum(IS_NEW) OVER (PARTITION BY PATID ORDER BY DOSE_DT
                               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS E
      FROM runs
    ),
    expo AS (
      SELECT PATID, E, min(DOSE_DT) AS EXPO_DT
      FROM expo_id GROUP BY PATID, E
    ),
    -- The line each exposure falls in - and, where THIS DRUG created that
    -- line's boundary, the line before it. The build ends a line the day before
    -- an added medication, so a melphalan dose first seen outside the induction
    -- window lands on day 0 of the line it created. Measured against that line
    -- it would read as inside induction, and every B branch would become an A.
    ln AS (
      SELECT cast(PATID as string) AS PATID,
             cast(LOT_NUM as int) AS LOT_NUM,
             cast(LOT_START_DT as date) AS LOT_START_DT,
             cast(LOT_BASE_END_DT as date) AS LOT_END_DT,
             LOT_BASE_END_REASON AS LOT_END_REASON,
             upper(trim(coalesce(LOT_BASE_1ST_ADD_MED, ''))) AS ADD_MED
      FROM {lines_tbl}
    ),
    ln_prev AS (
      SELECT l.*,
             lag(LOT_NUM)      OVER (PARTITION BY PATID ORDER BY LOT_NUM) AS PREV_LOT_NUM,
             lag(LOT_START_DT) OVER (PARTITION BY PATID ORDER BY LOT_NUM) AS PREV_START_DT,
             lag(LOT_END_DT)   OVER (PARTITION BY PATID ORDER BY LOT_NUM) AS PREV_END_DT,
             lag(LOT_END_REASON) OVER (PARTITION BY PATID ORDER BY LOT_NUM) AS PREV_REASON,
             lag(ADD_MED)      OVER (PARTITION BY PATID ORDER BY LOT_NUM) AS PREV_ADD_MED
      FROM ln l
    ),
    placed AS (
      SELECT e.PATID, e.E, e.EXPO_DT,
             -- Did the build open this line BECAUSE of this exposure?
             CASE WHEN l.PATID IS NOT NULL
                   AND e.EXPO_DT = l.LOT_START_DT
                   AND l.PREV_REASON = 'MED_ADD'
                   AND l.PREV_ADD_MED = upper('{cfg$abbr}')
                  THEN 1 ELSE 0 END                        AS CREATED_BOUNDARY,
             CASE WHEN l.PATID IS NOT NULL
                   AND e.EXPO_DT = l.LOT_START_DT
                   AND l.PREV_REASON = 'MED_ADD'
                   AND l.PREV_ADD_MED = upper('{cfg$abbr}')
                  THEN l.PREV_LOT_NUM ELSE l.LOT_NUM END   AS REF_LOT_NUM,
             CASE WHEN l.PATID IS NOT NULL
                   AND e.EXPO_DT = l.LOT_START_DT
                   AND l.PREV_REASON = 'MED_ADD'
                   AND l.PREV_ADD_MED = upper('{cfg$abbr}')
                  THEN l.PREV_START_DT ELSE l.LOT_START_DT END AS REF_START_DT,
             CASE WHEN l.PATID IS NOT NULL
                   AND e.EXPO_DT = l.LOT_START_DT
                   AND l.PREV_REASON = 'MED_ADD'
                   AND l.PREV_ADD_MED = upper('{cfg$abbr}')
                  THEN l.PREV_END_DT ELSE NULL END          AS BOUNDARY_END_DT,
             l.LOT_NUM AS IN_LOT_NUM
      FROM expo e
      LEFT JOIN ln_prev l
        ON l.PATID = e.PATID
       AND e.EXPO_DT >= l.LOT_START_DT AND e.EXPO_DT <= l.LOT_END_DT
    ),
    windowed AS (
      SELECT p.*,
             CASE WHEN REF_LOT_NUM = 1 THEN {cfg$induction_1l}
                  WHEN REF_LOT_NUM IS NOT NULL THEN {cfg$induction_n} END AS IND_DAYS
      FROM placed p
    ),
    -- An exposure with a coded transplant on it. Under yield_to_sct the pair it
    -- opens is left to the transplant rule; under as_asked the flag is recorded
    -- and ignored, so the double-count is visible either way.
    with_sct AS (
      SELECT w.PATID, w.E, w.EXPO_DT, w.CREATED_BOUNDARY, w.REF_LOT_NUM,
             w.REF_START_DT, w.BOUNDARY_END_DT, w.IN_LOT_NUM, w.IND_DAYS,
             max(CASE WHEN a.PATID IS NOT NULL THEN 1 ELSE 0 END) AS HAS_AUTO
      FROM windowed w
      LEFT JOIN (SELECT DISTINCT cast(PATID as string) AS PATID,
                        cast(TX_DT as date) AS TX_DT FROM {auto_tbl}) a
        ON a.PATID = w.PATID
       AND abs(datediff(a.TX_DT, w.EXPO_DT)) <= {cfg$sct_days}
      GROUP BY w.PATID, w.E, w.EXPO_DT, w.CREATED_BOUNDARY, w.REF_LOT_NUM,
               w.REF_START_DT, w.BOUNDARY_END_DT, w.IN_LOT_NUM, w.IND_DAYS
    ),
    -- The NEXT exposure's transplant flag as well as this one's. The A.2 and
    -- B.3 boundaries fall on the next exposure, so that is the one yielding has
    -- to look at; carrying only this exposure's flag would let a coded
    -- transplant open a melphalan boundary in yield mode.
    pairs AS (
      SELECT PATID, E, EXPO_DT, CREATED_BOUNDARY, REF_LOT_NUM, REF_START_DT,
             BOUNDARY_END_DT, IN_LOT_NUM, IND_DAYS, HAS_AUTO,
             lead(EXPO_DT)  OVER (PARTITION BY PATID ORDER BY EXPO_DT) AS NEXT_DT,
             lead(HAS_AUTO) OVER (PARTITION BY PATID ORDER BY EXPO_DT) AS NEXT_HAS_AUTO,
             datediff(EXPO_DT, REF_START_DT) AS DAYS_INTO_LINE
      FROM with_sct
    ),
    judged AS (
      SELECT p.*,
             CASE WHEN NEXT_DT IS NULL THEN NULL
                  ELSE datediff(NEXT_DT, EXPO_DT) END AS GAP,
             -- Inside the window is measured the way the build measures it:
             -- the window includes its first day, so the bound is IND_DAYS - 1.
             CASE WHEN REF_START_DT IS NULL THEN NULL
                  WHEN DAYS_INTO_LINE <= IND_DAYS - 1 THEN 1 ELSE 0 END AS INSIDE
      FROM pairs p
    ),
    -- Whether the boundary this pair would open falls on an exposure the
    -- transplant rule already owns. Computed here so the decision below is
    -- flat: a CASE nested inside a CASE arm reads as one rule and is two.
    yielding AS (
      SELECT j.*,
             CASE WHEN {if (identical(cfg$mode, 'yield_to_sct')) 'HAS_AUTO = 1' else '1 = 0'} THEN 1 ELSE 0 END AS YIELD_THIS,
             CASE WHEN {if (identical(cfg$mode, 'yield_to_sct')) 'coalesce(NEXT_HAS_AUTO, 0) = 1' else '1 = 0'} THEN 1 ELSE 0 END AS YIELD_NEXT
      FROM judged j
    ),
    ruled AS (
      SELECT y.*,
        CASE
          WHEN INSIDE IS NULL                             THEN 'UNPLACED'
          WHEN GAP IS NULL                                THEN 'NO_NEXT'
          WHEN YIELD_THIS = 1                             THEN 'YIELDED'
          WHEN INSIDE = 1 AND GAP >= {cfg$advance_days}
                          AND YIELD_NEXT = 1              THEN 'YIELDED_NEXT'
          WHEN INSIDE = 1 AND GAP >= {cfg$advance_days}   THEN 'NEXT'
          WHEN INSIDE = 1                                 THEN 'NO_ADVANCE'
          WHEN GAP <  {cfg$restart_days}                  THEN 'FIRST'
          WHEN GAP <  {cfg$advance_days}                  THEN 'NO_ADVANCE'
          WHEN YIELD_NEXT = 1                             THEN 'YIELDED_NEXT'
          ELSE                                                 'NEXT'
        END AS ADVANCES
      FROM yielding y
    )
    SELECT PATID, E AS EXPOSURE_NUM, EXPO_DT, NEXT_DT, GAP, IN_LOT_NUM,
           REF_LOT_NUM, REF_START_DT, DAYS_INTO_LINE, IND_DAYS, INSIDE,
           CREATED_BOUNDARY, BOUNDARY_END_DT, HAS_AUTO, NEXT_HAS_AUTO, ADVANCES,
           CASE WHEN ADVANCES = 'FIRST' THEN EXPO_DT
                WHEN ADVANCES = 'NEXT'  THEN NEXT_DT END AS ADVANCE_DT,
           {sql_text(cfg$mode)}   AS MELP_RULE_MODE,
           {sql_text(run_id)}     AS MELP_RUN_ID,
           -- The LOT attempt these rows were measured against. A re-run keeps
           -- its RUN_ID and replaces the lines in place, so the id alone cannot
           -- say which attempt this is.
           {sql_text(lot_run)}    AS SOURCE_LOT_RUN_ID,
           {sql_text(lot_stamp)}  AS SOURCE_LOT_STAMP,
           current_timestamp()    AS BUILT_AT
    FROM ruled")
}

# What the rule does to the line BOUNDARIES. Not to the line count: moving a
# boundary changes which line an exposure falls in, whether an agent is inside
# an induction window, regimen membership, discontinuation dates and every later
# line number. None of that is recoverable from finished boundaries, so no
# resulting line count is offered and none should be inferred from these two
# columns by subtraction.
#
# Two directions, counted separately because they are not the same claim:
#
#   splits   an advance date strictly inside a line. The rule would cut there.
#   merges   an exposure that created a boundary - the build ended a line by
#            adding this drug at it - where the rule does not put a boundary at
#            that exposure's own date. Three branches do that:
#              NO_ADVANCE    B.2, neither dose advances. The boundary goes.
#              NEXT          B.3, the later dose advances. The boundary moves -
#                            removed here, added at the later date as a split.
#              YIELDED_NEXT  B.3 again, with a transplant coded on the later
#                            dose. Yielding hands that later event to the SCT
#                            rule, so there is no split - but the rule still
#                            declines at this dose, so this boundary still goes.
#                            Leaving it out kept a boundary the rule removed and
#                            yielded the event that was to replace it.
#            FIRST keeps it, which is B.1 agreeing with the build.
#            Keyed on the exposure, not on a date join to the line end: a date
#            join fires whenever no advance date matches, which includes an
#            exposure with no next dose, one outside every line, and one the
#            transplant rule was left to handle (YIELDED, where the coded
#            transplant is on this dose). The rule says nothing about those, so
#            removing their boundary would be unjustified.
melp_impact_sql <- function(rule_tbl, lines_tbl, cfg, run_id,
                            lot_run = NA_character_, lot_stamp = NA_character_) {
  glue("
    WITH ln AS (
      SELECT cast(PATID as string) AS PATID, cast(LOT_NUM as int) AS LOT_NUM,
             cast(LOT_START_DT as date) AS LOT_START_DT,
             cast(LOT_BASE_END_DT as date) AS LOT_END_DT
      FROM {lines_tbl}
    ),
    now AS (SELECT PATID, count(*) AS N_LINES_NOW FROM ln GROUP BY PATID),
    splits AS (
      SELECT r.PATID, count(DISTINCT r.ADVANCE_DT) AS N_SPLIT
      FROM {rule_tbl} r
      INNER JOIN ln l ON l.PATID = r.PATID
                     AND r.ADVANCE_DT >  l.LOT_START_DT
                     AND r.ADVANCE_DT <= l.LOT_END_DT
      WHERE r.ADVANCE_DT IS NOT NULL
      GROUP BY r.PATID
    ),
    merges AS (
      SELECT PATID, count(*) AS N_MERGE
      FROM {rule_tbl}
      WHERE CREATED_BOUNDARY = 1
        AND ADVANCES IN ('NO_ADVANCE', 'NEXT', 'YIELDED_NEXT')
      GROUP BY PATID
    )
    SELECT n.PATID,
           n.N_LINES_NOW,
           coalesce(s.N_SPLIT, 0)                          AS N_SPLIT,
           coalesce(m.N_MERGE, 0)                          AS N_MERGE,
           {sql_text(cfg$mode)}   AS MELP_RULE_MODE,
           {sql_text(run_id)}     AS MELP_RUN_ID,
           -- The LOT attempt these rows were measured against. A re-run keeps
           -- its RUN_ID and replaces the lines in place, so the id alone cannot
           -- say which attempt this is.
           {sql_text(lot_run)}    AS SOURCE_LOT_RUN_ID,
           {sql_text(lot_stamp)}  AS SOURCE_LOT_STAMP,
           current_timestamp()    AS BUILT_AT
    FROM now n
    LEFT JOIN splits s ON s.PATID = n.PATID
    LEFT JOIN merges m ON m.PATID = n.PATID
    WHERE coalesce(s.N_SPLIT, 0) > 0 OR coalesce(m.N_MERGE, 0) > 0")
}

# The branch table from the request, so the reading can be checked against the
# patient examples before anyone acts on the totals.
melp_branch_sql <- function(rule_tbl) {
  glue("
    SELECT CASE WHEN INSIDE IS NULL THEN 'exposure outside every line'
                WHEN INSIDE = 1     THEN 'A first dose inside induction'
                ELSE                     'B first dose outside induction' END AS FIRST_DOSE,
           CASE WHEN GAP IS NULL     THEN 'no next exposure'
                WHEN GAP <  60        THEN '< 60 days'
                WHEN GAP <  180       THEN '60-179 days'
                ELSE                       '>= 180 days' END                  AS NEXT_EXPOSURE,
           ADVANCES                                                           AS EFFECT,
           -- Both exposures' transplant flags. The boundary in A.2 and B.3 falls
           -- on the NEXT exposure, so that is the one yielding looks at - and a
           -- YIELDED_NEXT row has HAS_AUTO = 0 by construction. Reporting only
           -- this exposure's flag showed no transplant overlap on exactly the
           -- rows that were yielded because of one.
           sum(HAS_AUTO)                          AS N_WITH_CODED_TRANSPLANT,
           sum(coalesce(NEXT_HAS_AUTO, 0))        AS N_NEXT_WITH_CODED_TRANSPLANT,
           count(*)                               AS N_EXPOSURES,
           count(DISTINCT PATID)                  AS N_PATIENTS,
           max(MELP_RULE_MODE)                    AS MELP_RULE_MODE,
           max(MELP_RUN_ID)                       AS MELP_RUN_ID,
           max(SOURCE_LOT_RUN_ID)                 AS SOURCE_LOT_RUN_ID,
           max(SOURCE_LOT_STAMP)                  AS SOURCE_LOT_STAMP,
           current_timestamp()                    AS BUILT_AT
    FROM {rule_tbl}
    GROUP BY 1, 2, 3 ORDER BY 1, 2, 3")
}
