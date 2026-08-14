# Coverage-based regimen membership, measured against a finished run.
#
# Optum supplies no treatment end date. Cover is FILL_DT plus DAYS_SUP, and an
# overlapping refill pushes it out rather than opening a new episode
# (03_mma_map.R). So an episode opened in one line can still be covered across
# the whole of the next line's induction window while carrying that earlier
# line's MAP_START_DT.
#
# The build tests MAP_START_DT, so such an agent does not join the next line's
# regimen - see lot/RULES.md. The protocol reads wider ("all MM therapies
# received within 30 days on and following the LOT start date", July 30 cohort
# protocol p.19) and the LOT2-5 spec's worked example A assumes a continuing
# agent lands in LOT2. This sizes the difference.
#
# Two populations, not one, and they are not the same question:
#
#   passive    covered into the line by leftover days-supply, with no claim of
#              its own inside the window. The study team settled this: a patient
#              who has switched is no longer filling the old agent.
#   absorbed   a REAL claim inside the window, which landed while the earlier
#              episode was still open. 03_mma_map.R pushes the runout out and
#              keeps the old MAP_START_DT, so the fill leaves no episode of its
#              own and the agent is absent from the regimen anyway. Nothing the
#              study team decided covers this one - the patient is still filling
#              the drug.
#
# The split is drawn off MMA_MED_PROCESSED.DATE_SERVICE, the claim dates, since
# MAP_START_DT cannot see a fill it absorbed.
#
# It counts the agents a coverage rule would ADD to a regimen, and the three
# consequences that follow from a finished run. It does NOT give the resulting
# line structure: an added agent is a base agent, so it enters the run-out
# calculation and leaves the added-medication candidate list, and both move
# boundaries. An exact structure needs an alternate build.
#
# Absorption bites a second time, AFTER the induction window. 10_lot2_5_base.R
# reads MAP_START_DT again for the added-medication query, so a claim for an
# agent outside this line's regimen that lands while an episode of that agent is
# still open opens nothing and ends nothing. The LOT protocol's rule 2 ends a LOT
# on "initiation of a new MM agent that was not present in the induction
# regimen", so that is a boundary the protocol asks for and the build does not
# make. stock_absorbed_add_sql() counts those, and they are a separate question
# from regimen membership: one is an agent missing from a regimen string, the
# other is a line that never ended.
#
# LOT1 is structurally exempt - it starts at the patient's first non-steroid MM
# agent, so no such episode can precede it. LOT1 coming back non-zero means the
# window or the line table is not what this assumes, and is reported rather than
# filtered away.

# The env names are the engine's own, from config_lot.R - not a guess at them.
# LOT2-5's is INDUCTION_WINDOW_DAYS_LOT_N, which does not follow the pattern of
# the other two.
STOCK_SETTINGS <- list(
  ind1 = list(env = "INDUCTION_WINDOW_DAYS",       default = 60L),
  indn = list(env = "INDUCTION_WINDOW_DAYS_LOT_N", default = 30L),
  cart = list(env = "CART_CONSOLIDATION_DAYS",     default = 45L))

# Read from the run's own contract where the caller supplies it, so the window
# judged is the window built with. Falls back to config for a dry run.
stock_cfg <- function(from_run = NULL) {
  out <- list()
  for (nm in names(STOCK_SETTINGS)) {
    s <- STOCK_SETTINGS[[nm]]
    v <- if (!is.null(from_run) && !is.null(from_run[[s$env]])) from_run[[s$env]]
         else Sys.getenv(s$env, unset = "")
    v <- suppressWarnings(as.integer(trimws(v)))
    out[[nm]] <- if (is.na(v) || v < 1L) s$default else v
  }
  out
}

# The line's own induction window, the way 10_lot2_5_base.R bounds it: LOT1 gets
# 60, a CAR-T-started line the 45-day consolidation window, everything else 30.
# An ALLO line carries no regimen at all, so it is excluded rather than given a
# window of zero - a zero-length window would report every ALLO line as unable
# to gain an agent, which is true but is not a finding.
# The engine's regimen is the induction meds AND their permissible substitutes
# (10_lot2_5_base.R: base_meds), so a biosimilar of a regimen agent is inside the
# regimen and can never be an addition. permissible_subs is a temporary view
# built from a code list, not a warehouse table, so a program measuring a
# finished run has to be handed the pairs.
#
# NULL renders a zero-row relation, which makes every substitute look like an
# outside agent and overstates what is counted. Callers that cannot supply the
# pairs should say so rather than pass NULL quietly.
subs_cte_sql <- function(pairs = NULL, tbl = NULL) {
  # A warehouse table wins where the code list is published there; otherwise the
  # pairs are inlined from the CSV the engine itself reads.
  if (!is.null(tbl) && nzchar(tbl))
    return(glue("SELECT upper(trim(original_med))   AS original_med,
                   upper(trim(substitute_med)) AS substitute_med
            FROM {tbl}"))
  if (is.null(pairs) || !nrow(pairs))
    return("SELECT cast(null as string) AS original_med,
                   cast(null as string) AS substitute_med
            WHERE 1 = 0")
  vals <- paste(sprintf("(%s, %s)",
                        sql_text(toupper(trimws(pairs$original_med))),
                        sql_text(toupper(trimws(pairs$substitute_med)))),
                collapse = ",\n                   ")
  glue("SELECT * FROM (VALUES\n                   {vals}\n                 ) AS s(original_med, substitute_med)")
}

stock_window_sql <- function(cfg) {
  glue("CASE
          WHEN cast(LOT_NUM as int) = 1
            THEN date_add(cast(LOT_START_DT as date), {cfg$ind1 - 1})
          WHEN LOT_START_TYPE = 'CART'
            THEN date_add(cast(LOT_START_DT as date), {cfg$cart - 1})
          ELSE date_add(cast(LOT_START_DT as date), {cfg$indn - 1})
        END")
}

# One row per (line, agent) a coverage rule would add.
#
# "Covered into the line" is an episode that opened strictly before the line
# started and whose cover reaches the line's start date. Reaching only part way
# into the window still counts: the question is whether the patient was on the
# agent when the line opened, and DAYS_COVERED_IN_WINDOW carries how long for.
#
# The exclusion is a fill in the window, not membership in LOT_BASE_MEDS. The
# two agree, but LOT_BASE_MEDS is a formatted string and matching agents inside
# it would turn a substring into a match - LEN inside LENA.
stock_agents_sql <- function(lines_tbl, map_tbl, claims_tbl, cfg, run_id,
                             lot_run = NA_character_, lot_stamp = NA_character_) {
  glue("
    WITH ln AS (
      SELECT cast(PATID as string)         AS PATID,
             cast(LOT_NUM as int)          AS LOT_NUM,
             cast(LOT_START_DT as date)    AS LOT_START_DT,
             LOT_START_TYPE,
             cast(LOT_BASE_DISCON_DT as date) AS LOT_DISCON_DT,
             cast(LOT_BASE_END_DT as date) AS LOT_END_DT,
             LOT_BASE_END_REASON,
             cast(LOT_MED_CNT as int)      AS LOT_MED_CNT,
             upper(trim(coalesce(LOT_BASE_1ST_ADD_MED, ''))) AS ADD_MED,
             {stock_window_sql(cfg)}       AS IND_END_DT
      FROM {lines_tbl}
      WHERE LOT_START_TYPE <> 'SCT_ALLO'
    ),
    -- A real claim inside the window, from the claim dates rather than the
    -- episode dates. An episode that was already open absorbs the fill and
    -- keeps its old MAP_START_DT, so this is the only place the fill is
    -- visible at all.
    real_fills AS (
      SELECT DISTINCT l.PATID, l.LOT_NUM,
             upper(trim(c.MED_ABBR)) AS MED_ABBR
      FROM ln l
      INNER JOIN {claims_tbl} c
              ON cast(c.PATID as string) = l.PATID
             AND c.MED_CLASS <> 'STEROID'
             AND cast(c.DATE_SERVICE as date) >= l.LOT_START_DT
             AND cast(c.DATE_SERVICE as date) <= l.IND_END_DT
    ),
    -- Agents that OPENED an episode inside the window: already in the regimen,
    -- so they are not what this measures.
    filled AS (
      SELECT DISTINCT l.PATID, l.LOT_NUM,
             upper(trim(m.MAP_MED_TYPE)) AS MED_ABBR
      FROM ln l
      INNER JOIN {map_tbl} m
              ON cast(m.PATID as string) = l.PATID
             AND m.MAP_MED_CLASS <> 'STEROID'
             AND cast(m.MAP_START_DT as date) >= l.LOT_START_DT
             AND cast(m.MAP_START_DT as date) <= l.IND_END_DT
    ),
    -- Agents whose cover reaches the line's start from an earlier episode. One
    -- row per agent per line: a patient can have several episodes of the same
    -- drug overlapping, and they are one carried exposure, not several.
    carried AS (
      SELECT l.PATID, l.LOT_NUM, l.LOT_START_DT, l.IND_END_DT, l.LOT_DISCON_DT,
             l.LOT_END_DT, l.LOT_BASE_END_REASON, l.LOT_MED_CNT, l.ADD_MED,
             upper(trim(m.MAP_MED_TYPE))       AS MED_ABBR,
             min(cast(m.MAP_START_DT as date)) AS EPISODE_START_DT,
             max(cast(m.MAP_END_DT as date))   AS EPISODE_END_DT
      FROM ln l
      INNER JOIN {map_tbl} m
              ON cast(m.PATID as string) = l.PATID
             AND m.MAP_MED_CLASS <> 'STEROID'
             AND cast(m.MAP_START_DT as date) <  l.LOT_START_DT
             AND cast(m.MAP_END_DT as date)   >= l.LOT_START_DT
      GROUP BY l.PATID, l.LOT_NUM, l.LOT_START_DT, l.IND_END_DT, l.LOT_DISCON_DT,
               l.LOT_END_DT, l.LOT_BASE_END_REASON, l.LOT_MED_CNT, l.ADD_MED,
               upper(trim(m.MAP_MED_TYPE))
    )
    SELECT c.PATID, c.LOT_NUM, c.MED_ABBR,
           c.LOT_START_DT, c.IND_END_DT, c.LOT_DISCON_DT, c.LOT_END_DT,
           c.LOT_BASE_END_REASON, c.LOT_MED_CNT,
           c.EPISODE_START_DT, c.EPISODE_END_DT,
           datediff(least(c.EPISODE_END_DT, c.IND_END_DT), c.LOT_START_DT) + 1
                                                        AS DAYS_COVERED_IN_WINDOW,
           CASE WHEN c.EPISODE_END_DT >= c.IND_END_DT THEN 1 ELSE 0 END
                                                        AS COVERS_WHOLE_WINDOW,
           -- The agent's cover outlasts what the line ran out on, so as a base
           -- agent it would carry the run-out later and lengthen the line.
           CASE WHEN c.LOT_DISCON_DT IS NOT NULL
                 AND c.EPISODE_END_DT > c.LOT_DISCON_DT THEN 1 ELSE 0 END
                                                        AS WOULD_EXTEND_RUNOUT,
           -- This agent is what ended the line as an added medication. In the
           -- regimen it could not be an addition, so that boundary would go.
           CASE WHEN c.LOT_BASE_END_REASON = 'MED_ADD' AND c.ADD_MED = c.MED_ABBR
                THEN 1 ELSE 0 END                       AS WOULD_REMOVE_ADD_MED,
           -- The split that matters. 1 = a real claim inside the window that an
           -- open episode absorbed; 0 = leftover cover and nothing else.
           CASE WHEN rf.MED_ABBR IS NOT NULL THEN 1 ELSE 0 END
                                                        AS HAS_REAL_FILL_IN_WINDOW,
           {sql_text(run_id)}  AS STOCK_RUN_ID,
           -- The attempt these rows describe. Without it a reader cannot prove
           -- which build the numbers came off once the LOT tables move on.
           {sql_text(lot_run)}   AS SOURCE_LOT_RUN_ID,
           {sql_text(lot_stamp)} AS SOURCE_LOT_STAMP,
           current_timestamp()   AS BUILT_AT
    FROM carried c
    LEFT JOIN filled f
           ON f.PATID = c.PATID AND f.LOT_NUM = c.LOT_NUM
          AND f.MED_ABBR = c.MED_ABBR
    LEFT JOIN real_fills rf
           ON rf.PATID = c.PATID AND rf.LOT_NUM = c.LOT_NUM
          AND rf.MED_ABBR = c.MED_ABBR
    WHERE f.MED_ABBR IS NULL")
}

# One row per affected line, so a line gaining two agents counts once.
stock_impact_sql <- function(agents_tbl) {
  glue("
    SELECT PATID, LOT_NUM,
           LOT_START_DT, LOT_MED_CNT,
           count(*)                                   AS N_AGENTS_ADDED,
           LOT_MED_CNT + count(*)                     AS LOT_MED_CNT_AFTER,
           concat_ws(' ', sort_array(collect_set(MED_ABBR))) AS MEDS_ADDED,
           max(COVERS_WHOLE_WINDOW)                   AS ANY_COVERS_WHOLE_WINDOW,
           max(WOULD_EXTEND_RUNOUT)                   AS WOULD_EXTEND_RUNOUT,
           max(WOULD_REMOVE_ADD_MED)                  AS WOULD_REMOVE_ADD_MED,
           max(HAS_REAL_FILL_IN_WINDOW)               AS HAS_REAL_FILL_IN_WINDOW,
           max(STOCK_RUN_ID)                          AS STOCK_RUN_ID,
           max(SOURCE_LOT_RUN_ID)                     AS SOURCE_LOT_RUN_ID,
           max(SOURCE_LOT_STAMP)                      AS SOURCE_LOT_STAMP,
           max(BUILT_AT)                              AS BUILT_AT
    FROM {agents_tbl}
    GROUP BY PATID, LOT_NUM, LOT_START_DT, LOT_MED_CNT")
}

# One row per (line, agent) whose added-medication boundary absorption swallowed.
#
# The build's added-medication query (10_lot2_5_base.R) takes agents outside this
# line's regimen whose MAP_START_DT falls after the induction window and on or
# before the line's end, and ends the line the day before the earliest. A claim
# landing while an episode of that same agent is still open opens no episode, so
# it is not a candidate and the boundary is never made.
#
# A claim opened an episode exactly when an episode of that agent starts on the
# claim's own date - episode starts are a subset of claim dates, so no start on
# that date means an open episode took it.
#
# WAS_IN_PREV_REGIMEN splits re-challenge from a first exposure. It does not
# decide correctness: rule 2 measures "new" against THIS line's induction
# regimen, so both are boundaries the protocol asks for. It is there because a
# returning agent and a never-seen one are different clinically.
stock_absorbed_add_sql <- function(lines_tbl, map_tbl, claims_tbl, cfg, run_id,
                                   lot_run = NA_character_,
                                   lot_stamp = NA_character_, subs = NULL,
                                   subs_tbl = NULL) {
  glue("
    WITH ln AS (
      SELECT cast(PATID as string)         AS PATID,
             cast(LOT_NUM as int)          AS LOT_NUM,
             cast(LOT_START_DT as date)    AS LOT_START_DT,
             LOT_START_TYPE,
             cast(LOT_BASE_END_DT as date) AS LOT_END_DT,
             LOT_BASE_END_REASON,
             {stock_window_sql(cfg)}       AS IND_END_DT
      FROM {lines_tbl}
      WHERE LOT_START_TYPE <> 'SCT_ALLO'
    ),
    -- The previous line's regimen, exploded to whole tokens. LOT_BASE_MEDS is a
    -- space-separated string and matching inside it would make LEN match LENA.
    prev_regimen AS (
      SELECT cast(PATID as string)   AS PATID,
             cast(LOT_NUM as int) + 1 AS LOT_NUM,
             m                        AS MED_ABBR
      FROM {lines_tbl}
      LATERAL VIEW explode(split(coalesce(LOT_BASE_MEDS, ''), ' ')) e AS m
      WHERE m <> ''
    ),
    -- This line's regimen: an episode that OPENED inside the window. The same
    -- test 10_lot2_5_base.R joins base_meds on.
    subs AS (
      {subs_cte_sql(subs, subs_tbl)}
    ),
    filled_raw AS (
      SELECT DISTINCT l.PATID, l.LOT_NUM,
             upper(trim(m.MAP_MED_TYPE)) AS MED_ABBR
      FROM ln l
      INNER JOIN {map_tbl} m
              ON cast(m.PATID as string) = l.PATID
             AND m.MAP_MED_CLASS <> 'STEROID'
             AND cast(m.MAP_START_DT as date) >= l.LOT_START_DT
             AND cast(m.MAP_START_DT as date) <= l.IND_END_DT
    ),
    -- The engine's base_meds: the regimen agents AND their permissible
    -- substitutes. A biosimilar of a regimen agent is inside the regimen and
    -- can never be an addition.
    filled AS (
      SELECT PATID, LOT_NUM, MED_ABBR FROM filled_raw
      UNION
      SELECT f.PATID, f.LOT_NUM, s.substitute_med AS MED_ABBR
      FROM filled_raw f INNER JOIN subs s ON f.MED_ABBR = s.original_med
    ),
    -- Claims after the window and on or before the line ended. A claim after the
    -- line ended belongs to the next line, not to this one's add-med search.
    cand AS (
      SELECT l.PATID, l.LOT_NUM, l.LOT_START_DT, l.IND_END_DT, l.LOT_END_DT,
             l.LOT_BASE_END_REASON,
             upper(trim(c.MED_ABBR))      AS MED_ABBR,
             cast(c.DATE_SERVICE as date) AS CLAIM_DT
      FROM ln l
      INNER JOIN {claims_tbl} c
              ON cast(c.PATID as string) = l.PATID
             AND c.MED_CLASS <> 'STEROID'
             AND cast(c.DATE_SERVICE as date) >  l.IND_END_DT
             AND cast(c.DATE_SERVICE as date) <= l.LOT_END_DT
    ),
    opened AS (
      SELECT DISTINCT cast(PATID as string)  AS PATID,
             upper(trim(MAP_MED_TYPE))       AS MED_ABBR,
             cast(MAP_START_DT as date)      AS CLAIM_DT
      FROM {map_tbl}
      WHERE MAP_MED_CLASS <> 'STEROID'
    ),
    ep AS (
      SELECT cast(PATID as string)       AS PATID,
             upper(trim(MAP_MED_TYPE))   AS MED_ABBR,
             cast(MAP_START_DT as date)  AS EPISODE_START_DT,
             cast(MAP_END_DT as date)    AS EPISODE_END_DT
      FROM {map_tbl}
      WHERE MAP_MED_CLASS <> 'STEROID'
    ),
    absorbed AS (
      SELECT c.PATID, c.LOT_NUM, c.LOT_START_DT, c.IND_END_DT, c.LOT_END_DT,
             c.LOT_BASE_END_REASON, c.MED_ABBR,
             min(c.CLAIM_DT) AS FIRST_ABSORBED_DT,
             count(*)        AS N_ABSORBED_CLAIMS
      FROM cand c
      LEFT JOIN filled f
             ON f.PATID = c.PATID AND f.LOT_NUM = c.LOT_NUM
            AND f.MED_ABBR = c.MED_ABBR
      LEFT JOIN opened o
             ON o.PATID = c.PATID AND o.MED_ABBR = c.MED_ABBR
            AND o.CLAIM_DT = c.CLAIM_DT
      WHERE f.MED_ABBR IS NULL AND o.MED_ABBR IS NULL
      GROUP BY c.PATID, c.LOT_NUM, c.LOT_START_DT, c.IND_END_DT, c.LOT_END_DT,
               c.LOT_BASE_END_REASON, c.MED_ABBR
    )
    SELECT a.PATID, a.LOT_NUM, a.MED_ABBR,
           a.LOT_START_DT, a.IND_END_DT, a.LOT_END_DT, a.LOT_BASE_END_REASON,
           a.FIRST_ABSORBED_DT, a.N_ABSORBED_CLAIMS,
           datediff(a.FIRST_ABSORBED_DT, a.LOT_START_DT) AS DAYS_INTO_LOT,
           -- The line would have ended the day before this claim, so this is how
           -- much of the line the missing boundary would have cut off.
           datediff(a.LOT_END_DT, a.FIRST_ABSORBED_DT) + 1 AS DAYS_LINE_WOULD_LOSE,
           min(ep.EPISODE_START_DT) AS EPISODE_START_DT,
           max(ep.EPISODE_END_DT)   AS EPISODE_END_DT,
           max(CASE WHEN p.MED_ABBR IS NOT NULL THEN 1 ELSE 0 END)
                                                        AS WAS_IN_PREV_REGIMEN,
           {sql_text(run_id)}    AS STOCK_RUN_ID,
           {sql_text(lot_run)}   AS SOURCE_LOT_RUN_ID,
           {sql_text(lot_stamp)} AS SOURCE_LOT_STAMP,
           max(current_timestamp()) AS BUILT_AT
    FROM absorbed a
    LEFT JOIN ep
           ON ep.PATID = a.PATID AND ep.MED_ABBR = a.MED_ABBR
          AND ep.EPISODE_START_DT <= a.FIRST_ABSORBED_DT
          AND ep.EPISODE_END_DT   >= a.FIRST_ABSORBED_DT
    LEFT JOIN prev_regimen p
           ON p.PATID = a.PATID AND p.LOT_NUM = a.LOT_NUM
          AND p.MED_ABBR = a.MED_ABBR
    GROUP BY a.PATID, a.LOT_NUM, a.MED_ABBR, a.LOT_START_DT, a.IND_END_DT,
             a.LOT_END_DT, a.LOT_BASE_END_REASON, a.FIRST_ABSORBED_DT,
             a.N_ABSORBED_CLAIMS")
}

# By line number, one row per line however many agents it absorbed.
stock_absorbed_by_lot_sql <- function(absorbed_tbl, lines_tbl) {
  glue("
    WITH all_lines AS (
      SELECT cast(LOT_NUM as int) AS LOT_NUM, count(*) AS N_LINES
      FROM {lines_tbl}
      GROUP BY cast(LOT_NUM as int)
    ),
    per_line AS (
      SELECT PATID, LOT_NUM,
             max(WAS_IN_PREV_REGIMEN)     AS ANY_RECHALLENGE,
             max(1 - WAS_IN_PREV_REGIMEN) AS ANY_FIRST_EXPOSURE,
             min(DAYS_INTO_LOT)           AS DAYS_INTO_LOT
      FROM {absorbed_tbl}
      GROUP BY PATID, LOT_NUM
    ),
    hit AS (
      SELECT LOT_NUM,
             count(*)                  AS N_LINES_AFFECTED,
             count(DISTINCT PATID)     AS N_PATIENTS_AFFECTED,
             sum(ANY_RECHALLENGE)      AS N_RECHALLENGE,
             sum(ANY_FIRST_EXPOSURE)   AS N_FIRST_EXPOSURE,
             percentile_approx(DAYS_INTO_LOT, 0.5) AS MEDIAN_DAYS_INTO_LOT
      FROM per_line
      GROUP BY LOT_NUM
    )
    SELECT a.LOT_NUM, a.N_LINES,
           coalesce(h.N_LINES_AFFECTED, 0)    AS N_ABSORBED_ADD_MED,
           coalesce(h.N_PATIENTS_AFFECTED, 0) AS N_PATIENTS_AFFECTED,
           coalesce(h.N_RECHALLENGE, 0)       AS N_RECHALLENGE,
           coalesce(h.N_FIRST_EXPOSURE, 0)    AS N_FIRST_EXPOSURE,
           h.MEDIAN_DAYS_INTO_LOT,
           round(100.0 * coalesce(h.N_LINES_AFFECTED, 0) / nullif(a.N_LINES, 0), 2)
                                              AS PCT_LINES_AFFECTED
    FROM all_lines a
    LEFT JOIN hit h ON h.LOT_NUM = a.LOT_NUM
    ORDER BY a.LOT_NUM")
}

# By line number, against every line at that number - so the share is a share of
# the lines that could have been affected, not of the affected ones.
stock_by_lot_sql <- function(impact_tbl, lines_tbl) {
  glue("
    WITH all_lines AS (
      SELECT cast(LOT_NUM as int) AS LOT_NUM,
             count(*)                 AS N_LINES,
             count(DISTINCT cast(PATID as string)) AS N_PATIENTS
      FROM {lines_tbl}
      GROUP BY cast(LOT_NUM as int)
    ),
    hit AS (
      SELECT LOT_NUM,
             count(*)                 AS N_LINES_AFFECTED,
             count(DISTINCT PATID)    AS N_PATIENTS_AFFECTED,
             sum(N_AGENTS_ADDED)      AS N_AGENTS_ADDED,
             sum(WOULD_EXTEND_RUNOUT) AS N_WOULD_EXTEND,
             sum(WOULD_REMOVE_ADD_MED) AS N_WOULD_REMOVE_ADD,
             sum(HAS_REAL_FILL_IN_WINDOW) AS N_WITH_REAL_FILL,
             max(SOURCE_LOT_RUN_ID)   AS SOURCE_LOT_RUN_ID,
             max(SOURCE_LOT_STAMP)    AS SOURCE_LOT_STAMP
      FROM {impact_tbl}
      GROUP BY LOT_NUM
    )
    SELECT a.LOT_NUM, a.N_LINES, a.N_PATIENTS,
           coalesce(h.N_LINES_AFFECTED, 0)    AS N_LINES_AFFECTED,
           coalesce(h.N_PATIENTS_AFFECTED, 0) AS N_PATIENTS_AFFECTED,
           coalesce(h.N_AGENTS_ADDED, 0)      AS N_AGENTS_ADDED,
           coalesce(h.N_WOULD_EXTEND, 0)      AS N_WOULD_EXTEND,
           coalesce(h.N_WOULD_REMOVE_ADD, 0)  AS N_WOULD_REMOVE_ADD,
           coalesce(h.N_WITH_REAL_FILL, 0)    AS N_WITH_REAL_FILL,
           h.SOURCE_LOT_RUN_ID, h.SOURCE_LOT_STAMP,
           round(100.0 * coalesce(h.N_LINES_AFFECTED, 0) / nullif(a.N_LINES, 0), 2)
                                              AS PCT_LINES_AFFECTED
    FROM all_lines a
    LEFT JOIN hit h ON h.LOT_NUM = a.LOT_NUM
    ORDER BY a.LOT_NUM")
}

# Which agents carry, and how often. The distribution matters as much as the
# total: a rule change concentrated in one continuing oral is a different
# conversation from one spread across every agent.
stock_by_med_sql <- function(agents_tbl) {
  glue("
    SELECT MED_ABBR,
           count(*)                     AS N_LINES,
           count(DISTINCT PATID)        AS N_PATIENTS,
           sum(COVERS_WHOLE_WINDOW)     AS N_COVERS_WHOLE_WINDOW,
           sum(WOULD_EXTEND_RUNOUT)     AS N_WOULD_EXTEND,
           sum(WOULD_REMOVE_ADD_MED)    AS N_WOULD_REMOVE_ADD,
           sum(HAS_REAL_FILL_IN_WINDOW) AS N_WITH_REAL_FILL,
           percentile_approx(DAYS_COVERED_IN_WINDOW, 0.5) AS MEDIAN_DAYS_COVERED,
           max(SOURCE_LOT_RUN_ID)       AS SOURCE_LOT_RUN_ID,
           max(SOURCE_LOT_STAMP)        AS SOURCE_LOT_STAMP
    FROM {agents_tbl}
    GROUP BY MED_ABBR
    ORDER BY count(*) DESC")
}
