# The melphalan line-advancing rule, measured against a finished run.
#
# The rule, as the study team asked it (questions/melphalan_lot_rule.md). An
# exposure is one administration; doses less than MELP_EXPOSURE_DAYS apart are
# the same one. For a pair of consecutive exposures:
#
#   first exposure INSIDE its line's induction window
#     next < 180 days    does not advance
#     next >= 180 days   the next exposure starts a line, on its own date
#
#   first exposure OUTSIDE the induction window
#     next < 60 days     the FIRST exposure starts a line, on its own date
#     next 60-179 days   neither advances
#     next >= 180 days   the next exposure starts a line, on its own date
#
# Applied to consecutive pairs, so a third exposure is judged against the second.
#
# This CHANGES NO CODE IN lot. It reads a finished run and counts the line
# boundaries the rule would add and remove, which is what the sensitivity
# question asks. It does not rebuild the lines, and it does not claim to: a
# split's date is exact, a merge's resulting regimen and end reason are not, and
# nothing here invents them.
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
melp_rule_sql <- function(lines_tbl, map_tbl, auto_tbl, cfg, run_id) {
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
    -- The line each exposure falls in, and that line's induction window.
    ln AS (
      SELECT cast(PATID as string) AS PATID,
             cast(LOT_NUM as int) AS LOT_NUM,
             cast(LOT_START_DT as date) AS LOT_START_DT,
             cast(LOT_BASE_END_DT as date) AS LOT_END_DT,
             LOT_BASE_END_REASON AS LOT_END_REASON,
             LOT_BASE_1ST_ADD_MED AS ADD_MED
      FROM {lines_tbl}
    ),
    placed AS (
      SELECT e.PATID, e.E, e.EXPO_DT, l.LOT_NUM, l.LOT_START_DT,
             CASE WHEN l.LOT_NUM = 1 THEN {cfg$induction_1l}
                  ELSE {cfg$induction_n} END AS IND_DAYS
      FROM expo e
      LEFT JOIN ln l
        ON l.PATID = e.PATID
       AND e.EXPO_DT >= l.LOT_START_DT AND e.EXPO_DT <= l.LOT_END_DT
    ),
    -- An exposure with a coded transplant on it. Under yield_to_sct the pair it
    -- opens is left to the transplant rule; under as_asked the flag is recorded
    -- and ignored, so the double-count is visible either way.
    with_sct AS (
      SELECT p.*,
             CASE WHEN a.PATID IS NOT NULL THEN 1 ELSE 0 END AS HAS_AUTO
      FROM placed p
      LEFT JOIN (SELECT DISTINCT cast(PATID as string) AS PATID,
                        cast(TX_DT as date) AS TX_DT FROM {auto_tbl}) a
        ON a.PATID = p.PATID
       AND abs(datediff(a.TX_DT, p.EXPO_DT)) <= {cfg$sct_days}
      GROUP BY p.PATID, p.E, p.EXPO_DT, p.LOT_NUM, p.LOT_START_DT, p.IND_DAYS,
               CASE WHEN a.PATID IS NOT NULL THEN 1 ELSE 0 END
    ),
    pairs AS (
      SELECT PATID, E, EXPO_DT, LOT_NUM, LOT_START_DT, IND_DAYS, HAS_AUTO,
             lead(EXPO_DT) OVER (PARTITION BY PATID ORDER BY EXPO_DT) AS NEXT_DT,
             datediff(EXPO_DT, LOT_START_DT) AS DAYS_INTO_LINE
      FROM with_sct
    ),
    judged AS (
      SELECT p.*,
             CASE WHEN NEXT_DT IS NULL THEN NULL
                  ELSE datediff(NEXT_DT, EXPO_DT) END AS GAP,
             -- Inside the window is measured the way the build measures it:
             -- the window includes its first day, so the bound is IND_DAYS - 1.
             CASE WHEN LOT_START_DT IS NULL THEN NULL
                  WHEN DAYS_INTO_LINE <= IND_DAYS - 1 THEN 1 ELSE 0 END AS INSIDE
      FROM pairs p
    ),
    ruled AS (
      SELECT j.*,
        CASE
          WHEN GAP IS NULL OR INSIDE IS NULL THEN NULL
          WHEN {if (identical(cfg$mode, 'yield_to_sct')) 'HAS_AUTO = 1' else '1 = 0'} THEN NULL
          WHEN INSIDE = 1 AND GAP >= {cfg$advance_days} THEN 'NEXT'
          WHEN INSIDE = 1                               THEN NULL
          WHEN GAP <  {cfg$restart_days}                THEN 'FIRST'
          WHEN GAP <  {cfg$advance_days}                THEN NULL
          ELSE                                               'NEXT'
        END AS ADVANCES
      FROM judged j
    )
    SELECT PATID, E AS EXPOSURE_NUM, EXPO_DT, NEXT_DT, GAP, LOT_NUM,
           LOT_START_DT, DAYS_INTO_LINE, IND_DAYS, INSIDE, HAS_AUTO, ADVANCES,
           CASE WHEN ADVANCES = 'FIRST' THEN EXPO_DT
                WHEN ADVANCES = 'NEXT'  THEN NEXT_DT END AS ADVANCE_DT,
           {sql_text(cfg$mode)}   AS MELP_RULE_MODE,
           {sql_text(run_id)}     AS MELP_RUN_ID,
           current_timestamp()    AS BUILT_AT
    FROM ruled")
}

# What the rule does to the line COUNT, which is the sensitivity question.
#
# Two directions, counted separately because they are not the same claim:
#
#   splits   an advance date strictly inside a line. The line would be cut in
#            two, so the patient gains a line. Exact - the date is the rule's.
#   merges   a line the build ended MED_ADD on this drug, where the rule says
#            that exposure does not advance. The boundary goes, so the patient
#            loses one. Exact as a count; the merged line's regimen, end reason
#            and length are NOT derived here, because they cannot be read off
#            two finished lines - they come from claims and need a build.
melp_impact_sql <- function(rule_tbl, lines_tbl, cfg, run_id) {
  glue("
    WITH ln AS (
      SELECT cast(PATID as string) AS PATID, cast(LOT_NUM as int) AS LOT_NUM,
             cast(LOT_START_DT as date) AS LOT_START_DT,
             cast(LOT_BASE_END_DT as date) AS LOT_END_DT,
             LOT_BASE_END_REASON AS LOT_END_REASON,
             upper(trim(coalesce(LOT_BASE_1ST_ADD_MED, ''))) AS ADD_MED
      FROM {lines_tbl}
    ),
    now AS (SELECT PATID, count(*) AS N_LINES_NOW FROM ln GROUP BY PATID),
    -- A boundary the rule ADDS: an advance date inside a line but not on its
    -- own start, since a date that already starts a line is already a boundary.
    splits AS (
      SELECT r.PATID, count(DISTINCT r.ADVANCE_DT) AS N_SPLIT
      FROM {rule_tbl} r
      INNER JOIN ln l ON l.PATID = r.PATID
                     AND r.ADVANCE_DT >  l.LOT_START_DT
                     AND r.ADVANCE_DT <= l.LOT_END_DT
      WHERE r.ADVANCE_DT IS NOT NULL
      GROUP BY r.PATID
    ),
    -- A boundary the rule REMOVES: the build ended this line by adding this
    -- drug, and no exposure at that boundary advances under the rule.
    merges AS (
      SELECT l.PATID, count(*) AS N_MERGE
      FROM ln l
      LEFT JOIN {rule_tbl} r
             ON r.PATID = l.PATID
            AND r.ADVANCE_DT = date_add(l.LOT_END_DT, 1)
      WHERE l.LOT_END_REASON = 'MED_ADD'
        AND l.ADD_MED = upper('{cfg$abbr}')
        AND r.PATID IS NULL
      GROUP BY l.PATID
    )
    SELECT n.PATID,
           n.N_LINES_NOW,
           coalesce(s.N_SPLIT, 0)                          AS N_SPLIT,
           coalesce(m.N_MERGE, 0)                          AS N_MERGE,
           n.N_LINES_NOW + coalesce(s.N_SPLIT, 0) - coalesce(m.N_MERGE, 0)
                                                           AS N_LINES_RULE,
           {sql_text(cfg$mode)}   AS MELP_RULE_MODE,
           {sql_text(run_id)}     AS MELP_RUN_ID,
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
           coalesce(ADVANCES, 'no advance')                                   AS EFFECT,
           sum(HAS_AUTO)                          AS N_WITH_CODED_TRANSPLANT,
           count(*)                               AS N_EXPOSURES,
           count(DISTINCT PATID)                  AS N_PATIENTS
    FROM {rule_tbl}
    GROUP BY 1, 2, 3 ORDER BY 1, 2, 3")
}
