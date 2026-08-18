# Re-challenge events, measured against a finished run.
#
# A line ends on a new MM agent that was not in the induction regimen, and the
# next line starts on an agent not in the previous line's regimen. Neither rule
# asks whether the patient has had the agent
# before, so an agent returning after an earlier line ends one line and opens
# another. Whether that is right is a clinical question, and the thing that
# decides it is not in the line table: how long the patient had actually been off
# the drug.
#
# GAP_DAYS is that measure - the days between the previous claim for the agent
# and the claim that brings it back. It comes from claim dates, so it reads the
# same for a patient whose cover had lapsed and one whose had not, which is what
# makes the two comparable at all. A gap the length of one dispense is continuous
# therapy that happens to look like a return; a gap of several months is a
# restart.
#
# Two populations, because the build treats them differently through no clinical
# difference:
#
#   FIRED       the returning claim opened an episode, so the build saw it, ended
#               the line as MED_ADD and opened the next one.
#   SUPPRESSED  an episode of that agent was still open, so the claim opened
#               nothing and the line did not end (see stockpiling.R).
#
# Reported side by side. If their gap distributions match, the boundary is being
# decided by leftover days-supply rather than by anything clinical, and the two
# should be made to agree. Where they are made to agree is what GAP_DAYS is for.
#
# It reports events and gaps. It does NOT give the resulting line structure under
# any threshold - that needs an alternate build.

RECHALL_SETTINGS <- list(
  ind1 = list(key = "induction_window_days",       env = "INDUCTION_WINDOW_DAYS",       default = 60L),
  indn = list(key = "lot_n_induction_window_days", env = "INDUCTION_WINDOW_DAYS_LOT_N", default = 30L),
  cart = list(key = "cart_consolidation_days",     env = "CART_CONSOLIDATION_DAYS",     default = 45L),
  # Not an engine setting, so it has no contract key - env only.
  partner = list(key = NULL, env = "RECHALL_PARTNER_DAYS", default = 30L))

# The engine windows come from the measured run's recorded CONTRACT_SETTINGS
# (lot_run_meta()'s $settings); the environment is only the dry-run fallback.
rechall_cfg <- function(from_run = NULL) {
  rec <- function(settings, key) {
    if (is.null(settings) || length(settings) != 1L || is.na(settings)) return(NULL)
    hit <- regmatches(settings, regexpr(paste0("(^|\\|)", key, "=[^|]*"), settings))
    if (!length(hit)) return(NULL)
    sub(paste0("^\\|?", key, "="), "", hit)
  }
  out <- list()
  for (nm in names(RECHALL_SETTINGS)) {
    s <- RECHALL_SETTINGS[[nm]]
    v <- if (!is.null(s$key) && !is.null(from_run))
           rec(from_run$settings, s$key) else NULL
    if (is.null(v)) v <- Sys.getenv(s$env, unset = "")
    v <- suppressWarnings(as.integer(trimws(v)))
    out[[nm]] <- if (is.na(v) || v < 1L) s$default else v
  }
  out
}

# Gap bands, chosen to separate the readings rather than to be round numbers.
# Bands of the CLAIM-to-claim interval. That is not time off treatment: days
# supplied, schedule and route all sit between the two. The labels say what was
# measured and nothing more.
rechall_band_sql <- function(col = "GAP_DAYS") {
  glue("CASE WHEN {col} IS NULL     THEN 'unknown'
             WHEN {col} <= 45       THEN '1: claim gap <=45d'
             WHEN {col} <= 90       THEN '2: claim gap 46-90d'
             WHEN {col} <= 180      THEN '3: claim gap 91-180d'
             ELSE                        '4: claim gap >180d' END")
}

# One row per re-challenge event.
#
# An event is an agent returning inside a line it is not part of, where the agent
# appeared in ANY earlier line for that patient - not only the immediately
# previous one, since a drug coming back after two lines is the same clinical
# event.
rechall_events_sql <- function(lines_tbl, map_tbl, claims_tbl, absorbed_tbl,
                               cfg, run_id, lot_run = NA_character_,
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
             upper(trim(coalesce(LOT_BASE_1ST_ADD_MED, ''))) AS ADD_MED,
             {stock_window_sql(cfg)}       AS IND_END_DT
      FROM {lines_tbl}
      WHERE LOT_START_TYPE <> 'SCT_ALLO'
    ),
    -- Every agent in every line, as whole tokens. Matching inside the string
    -- would make LEN match LENA.
    subs AS (
      {subs_cte_sql(subs, subs_tbl)}
    ),
    line_meds_raw AS (
      SELECT cast(PATID as string) AS PATID,
             cast(LOT_NUM as int)  AS LOT_NUM,
             m                     AS MED_ABBR
      FROM {lines_tbl}
      LATERAL VIEW explode(split(coalesce(LOT_BASE_MEDS, ''), ' ')) e AS m
      WHERE m <> ''
    ),
    -- The engine's base_meds is the regimen AND its permissible substitutes, so
    -- a biosimilar of a regimen agent is inside the regimen and never an
    -- addition. Without the pairs this is wider than the engine and counts
    -- substitutions as returns.
    line_meds AS (
      SELECT PATID, LOT_NUM, MED_ABBR FROM line_meds_raw
      UNION
      SELECT r.PATID, r.LOT_NUM, s.substitute_med AS MED_ABBR
      FROM line_meds_raw r INNER JOIN subs s ON r.MED_ABBR = s.original_med
    ),
    -- The earliest line each agent appeared in, per patient.
    first_seen AS (
      SELECT PATID, MED_ABBR, min(LOT_NUM) AS FIRST_SEEN_LOT
      FROM line_meds
      GROUP BY PATID, MED_ABBR
    ),
    -- The build SAW the return: it opened an episode, so the line ended MED_ADD
    -- and the next line opened on it. LOT_BASE_END_DT is the day before.
    fired AS (
      SELECT l.PATID, l.LOT_NUM, l.ADD_MED AS MED_ABBR,
             date_add(l.LOT_END_DT, 1) AS RETURN_DT,
             cast('FIRED' as string)   AS BOUNDARY
      FROM ln l
      WHERE l.LOT_BASE_END_REASON = 'MED_ADD' AND l.ADD_MED <> ''
    ),
    -- The build did NOT see it: an open episode absorbed the claim.
    suppressed AS (
      SELECT cast(PATID as string)          AS PATID,
             cast(LOT_NUM as int)           AS LOT_NUM,
             upper(trim(MED_ABBR))          AS MED_ABBR,
             cast(FIRST_ABSORBED_DT as date) AS RETURN_DT,
             cast('SUPPRESSED' as string)   AS BOUNDARY
      FROM {absorbed_tbl}
    ),
    ev AS (
      SELECT * FROM fired
      UNION ALL
      SELECT * FROM suppressed
    ),
    -- Only a RETURN: the agent belongs to an earlier line and not to this one.
    rechall AS (
      SELECT e.PATID, e.LOT_NUM, e.MED_ABBR, e.RETURN_DT, e.BOUNDARY,
             l.LOT_START_DT, l.LOT_END_DT, l.LOT_BASE_END_REASON,
             fs.FIRST_SEEN_LOT
      FROM ev e
      INNER JOIN ln l ON l.PATID = e.PATID AND l.LOT_NUM = e.LOT_NUM
      INNER JOIN first_seen fs
              ON fs.PATID = e.PATID AND fs.MED_ABBR = e.MED_ABBR
             AND fs.FIRST_SEEN_LOT < e.LOT_NUM
      LEFT JOIN line_meds lm
              ON lm.PATID = e.PATID AND lm.LOT_NUM = e.LOT_NUM
             AND lm.MED_ABBR = e.MED_ABBR
      WHERE lm.MED_ABBR IS NULL
    ),
    -- One boundary opportunity per (line, agent): the FIRST return. An agent
    -- absorbed once and then opening an episode later in the same line is one
    -- clinical event the build reacted to late, not two events. Counting both
    -- would double the event total and the patients in it.
    ranked AS (
      SELECT r.*,
             row_number() OVER (PARTITION BY r.PATID, r.LOT_NUM, r.MED_ABBR
                                ORDER BY r.RETURN_DT, r.BOUNDARY)
                                                        AS rn,
             count(*) OVER (PARTITION BY r.PATID, r.LOT_NUM, r.MED_ABBR)
                                                        AS N_RETURNS_IN_LINE,
             min(CASE WHEN r.BOUNDARY = 'FIRED' THEN r.RETURN_DT END)
               OVER (PARTITION BY r.PATID, r.LOT_NUM, r.MED_ABBR)
                                                        AS FIRST_FIRED_DT
      FROM rechall r
    ),
    ev1 AS (SELECT * FROM ranked WHERE rn = 1),
    -- The previous claim for the SAME agent. The whole measure: how long the
    -- patient had been off the drug, read off claims rather than off cover.
    -- Keyed on RETURN_DT as well: the same agent can return more than once in a
    -- line, and pairing an event with another return's previous claim gives a
    -- gap measured between two unrelated dates.
    prev_claim AS (
      SELECT r.PATID, r.LOT_NUM, r.MED_ABBR, r.RETURN_DT,
             max(cast(c.DATE_SERVICE as date)) AS PREV_CLAIM_DT
      FROM ev1 r
      INNER JOIN {claims_tbl} c
              ON cast(c.PATID as string) = r.PATID
             AND upper(trim(c.MED_ABBR))  = r.MED_ABBR
             AND cast(c.DATE_SERVICE as date) < r.RETURN_DT
      GROUP BY r.PATID, r.LOT_NUM, r.MED_ABBR, r.RETURN_DT
    ),
    -- Agents starting alongside the return. A drug coming back on its own reads
    -- as continuation, and with a new partner as a new regimen. Keyed on
    -- RETURN_DT for the same reason: the window is measured around it.
    partners AS (
      SELECT r.PATID, r.LOT_NUM, r.MED_ABBR, r.RETURN_DT,
             count(DISTINCT upper(trim(m.MAP_MED_TYPE))) AS N_NEW_PARTNERS
      FROM ev1 r
      INNER JOIN {map_tbl} m
              ON cast(m.PATID as string) = r.PATID
             AND m.MAP_MED_CLASS <> 'STEROID'
             AND upper(trim(m.MAP_MED_TYPE)) <> r.MED_ABBR
             AND cast(m.MAP_START_DT as date)
                   BETWEEN date_sub(r.RETURN_DT, {cfg$partner})
                       AND date_add(r.RETURN_DT, {cfg$partner})
      GROUP BY r.PATID, r.LOT_NUM, r.MED_ABBR, r.RETURN_DT
    )
    SELECT r.PATID, r.LOT_NUM, r.MED_ABBR, r.BOUNDARY,
           r.FIRST_SEEN_LOT, r.LOT_START_DT, r.LOT_END_DT,
           r.LOT_BASE_END_REASON, r.RETURN_DT,
           r.N_RETURNS_IN_LINE,
           -- Where the build did act, but on a later return than this one, how
           -- much later. The boundary was made in the wrong place, not missed.
           CASE WHEN r.BOUNDARY = 'SUPPRESSED'
                THEN datediff(r.FIRST_FIRED_DT, r.RETURN_DT) END
                                                    AS DAYS_BUILD_LATE,
           pc.PREV_CLAIM_DT,
           datediff(r.RETURN_DT, pc.PREV_CLAIM_DT)  AS GAP_DAYS,
           datediff(r.RETURN_DT, r.LOT_START_DT)    AS DAYS_INTO_LOT,
           coalesce(p.N_NEW_PARTNERS, 0)            AS N_NEW_PARTNERS,
           {rechall_band_sql('datediff(r.RETURN_DT, pc.PREV_CLAIM_DT)')} AS GAP_BAND,
           {sql_text(run_id)}    AS RECHALL_RUN_ID,
           {sql_text(lot_run)}   AS SOURCE_LOT_RUN_ID,
           {sql_text(lot_stamp)} AS SOURCE_LOT_STAMP,
           current_timestamp()   AS BUILT_AT
    FROM ev1 r
    LEFT JOIN prev_claim pc
           ON pc.PATID = r.PATID AND pc.LOT_NUM = r.LOT_NUM
          AND pc.MED_ABBR = r.MED_ABBR AND pc.RETURN_DT = r.RETURN_DT
    LEFT JOIN partners p
           ON p.PATID = r.PATID AND p.LOT_NUM = r.LOT_NUM
          AND p.MED_ABBR = r.MED_ABBR AND p.RETURN_DT = r.RETURN_DT")
}

# The distribution the decision turns on, with the two populations side by side.
# Where they agree, the gap is doing the work; where they diverge, days-supply is.
rechall_gap_sql <- function(events_tbl) {
  glue("
    SELECT GAP_BAND, BOUNDARY,
           count(*)                  AS N_EVENTS,
           count(DISTINCT PATID)     AS N_PATIENTS,
           percentile_approx(GAP_DAYS, 0.5)  AS MEDIAN_GAP_DAYS,
           sum(CASE WHEN N_NEW_PARTNERS > 0 THEN 1 ELSE 0 END)
                                     AS N_WITH_NEW_PARTNER,
           percentile_approx(DAYS_INTO_LOT, 0.5) AS MEDIAN_DAYS_INTO_LOT
    FROM {events_tbl}
    GROUP BY GAP_BAND, BOUNDARY
    ORDER BY GAP_BAND, BOUNDARY")
}

# A suppressed return is not always a boundary that never happened. The agent
# can return again later in the same line and open an episode then, so the build
# makes the boundary in the wrong place rather than not at all. The two are
# different findings and the totals hide it.
rechall_late_sql <- function(events_tbl) {
  glue("
    SELECT GAP_BAND,
           CASE WHEN BOUNDARY = 'FIRED'            THEN 'on the first return'
                WHEN DAYS_BUILD_LATE IS NOT NULL   THEN 'on a later return'
                ELSE                                    'never in this line' END
                                                   AS WHAT_THE_BUILD_DID,
           count(*)              AS N_EVENTS,
           count(DISTINCT PATID) AS N_PATIENTS,
           percentile_approx(GAP_DAYS, 0.5)        AS MEDIAN_GAP_DAYS,
           percentile_approx(DAYS_BUILD_LATE, 0.5) AS MEDIAN_DAYS_LATE,
           max(N_RETURNS_IN_LINE)                  AS MAX_RETURNS_IN_LINE
    FROM {events_tbl}
    GROUP BY GAP_BAND,
             CASE WHEN BOUNDARY = 'FIRED'          THEN 'on the first return'
                  WHEN DAYS_BUILD_LATE IS NOT NULL THEN 'on a later return'
                  ELSE                                  'never in this line' END
    ORDER BY GAP_BAND, WHAT_THE_BUILD_DID")
}

# Where the build made the boundary on a LATER return, the gap at that later
# return - which the event table does not carry, since it keeps the first one.
#
# It decides whether "84 days late" is a defect. If the later return follows a
# long gap, the build put the boundary in the right place and the first return
# was never a candidate. If it follows another short one, the build made a
# second boundary out of dosing rhythm, and those events belong with the ones
# that fired on a short gap rather than apart from them.
#
# FIRST_FIRED_DT is recovered as RETURN_DT + DAYS_BUILD_LATE, so this reads the
# finished event table and the claims, and needs no rebuild.
rechall_late_gap_sql <- function(events_tbl, claims_tbl) {
  glue("
    WITH late AS (
      SELECT PATID, LOT_NUM, MED_ABBR, GAP_DAYS AS FIRST_GAP_DAYS,
             date_add(RETURN_DT, DAYS_BUILD_LATE) AS FIRED_DT
      FROM {events_tbl}
      WHERE BOUNDARY = 'SUPPRESSED' AND DAYS_BUILD_LATE IS NOT NULL
    ),
    prev AS (
      SELECT l.PATID, l.LOT_NUM, l.MED_ABBR, l.FIRED_DT,
             max(cast(c.DATE_SERVICE as date)) AS PREV_BEFORE_FIRED
      FROM late l
      INNER JOIN {claims_tbl} c
              ON cast(c.PATID as string) = l.PATID
             AND upper(trim(c.MED_ABBR))  = l.MED_ABBR
             AND cast(c.DATE_SERVICE as date) < l.FIRED_DT
      GROUP BY l.PATID, l.LOT_NUM, l.MED_ABBR, l.FIRED_DT
    ),
    j AS (
      SELECT l.PATID, l.FIRST_GAP_DAYS,
             datediff(l.FIRED_DT, p.PREV_BEFORE_FIRED) AS FIRED_GAP_DAYS
      FROM late l
      LEFT JOIN prev p
             ON p.PATID = l.PATID AND p.LOT_NUM = l.LOT_NUM
            AND p.MED_ABBR = l.MED_ABBR AND p.FIRED_DT = l.FIRED_DT
    )
    SELECT {rechall_band_sql('FIRED_GAP_DAYS')} AS GAP_BAND_AT_THE_BOUNDARY,
           count(*)                             AS N_EVENTS,
           count(DISTINCT PATID)                AS N_PATIENTS,
           percentile_approx(FIRED_GAP_DAYS, 0.5) AS MEDIAN_GAP_AT_BOUNDARY,
           percentile_approx(FIRST_GAP_DAYS, 0.5) AS MEDIAN_GAP_AT_FIRST_RETURN
    FROM j
    GROUP BY {rechall_band_sql('FIRED_GAP_DAYS')}
    ORDER BY GAP_BAND_AT_THE_BOUNDARY")
}

# Bands of the COVER gap: days between the end of the agent's prior episode and
# the boundary the build made. This is time with no drug in hand, which is what
# MAP_DISCON_FLG is computed from - not the claim-to-claim interval.
rechall_cover_band_sql <- function(col = "COVER_GAP_DAYS") {
  glue("CASE WHEN {col} IS NULL THEN '0: no prior episode'
             WHEN {col} <=  7    THEN '1: 1-7d'
             WHEN {col} <= 30    THEN '2: 8-30d'
             WHEN {col} <= 89    THEN '3: 31-89d'
             ELSE                     '4: 90d+' END")
}

# Every boundary these events produced, against the build's OWN verdict on
# whether the agent had been stopped.
#
# 03_mma_map.R sets MAP_DISCON_FLG on an episode when the gap to the next supply
# reaches map_discon_gap_days: 1 is a discontinuation, 0 is the drug carrying on.
# The added-medication query reads map_stacked and never looks at it, so the same
# rows say "this agent continued" and "a new agent appeared" at once. This counts
# the boundaries where they disagree, in the build's own terms rather than a
# threshold of this program's choosing.
#
# A suppressed return needs no lookup: the claim landed inside a running episode,
# so there is no gap and the agent was continuing by construction.
#
# The boundary date is RETURN_DT where the build acted on the first return, and
# RETURN_DT + DAYS_BUILD_LATE where it acted on a later one.
# `by` is a named vector of extra grouping columns: the name becomes the output
# alias, the value the expression. The alias cannot be reused in GROUP BY, so the
# expression goes in both places.
rechall_discon_flag_sql <- function(events_tbl, map_tbl, by = NULL) {
  extra <- if (length(by))
    paste0(paste(sprintf("%s AS %s", by, names(by)), collapse = ",\n           "),
           ",\n           ") else ""
  extra_g <- if (length(by)) paste0(paste(by, collapse = ",\n             "),
                                    ",\n             ") else ""
  glue("
    WITH ep AS (
      SELECT cast(PATID as string)      AS PATID,
             upper(trim(MAP_MED_TYPE))  AS MED_ABBR,
             cast(MAP_END_DT as date)   AS EP_END_DT,
             cast(MAP_DISCON_FLG as int) AS DISCON_FLG
      FROM {map_tbl}
      WHERE MAP_MED_CLASS <> 'STEROID'
    ),
    bnd AS (
      SELECT PATID, LOT_NUM, MED_ABBR, GAP_DAYS, BOUNDARY,
             CASE WHEN BOUNDARY = 'FIRED' THEN RETURN_DT
                  ELSE date_add(RETURN_DT, DAYS_BUILD_LATE) END AS BOUNDARY_DT
      FROM {events_tbl}
      WHERE BOUNDARY = 'FIRED' OR DAYS_BUILD_LATE IS NOT NULL
    ),
    ranked AS (
      SELECT b.PATID, b.LOT_NUM, b.MED_ABBR, b.BOUNDARY_DT, b.GAP_DAYS,
             b.BOUNDARY,
             e.DISCON_FLG, e.EP_END_DT,
             datediff(b.BOUNDARY_DT, e.EP_END_DT) AS COVER_GAP_DAYS,
             row_number() OVER (PARTITION BY b.PATID, b.LOT_NUM, b.MED_ABBR,
                                             b.BOUNDARY_DT
                                ORDER BY e.EP_END_DT DESC) AS rn
      FROM bnd b
      LEFT JOIN ep e
             ON e.PATID = b.PATID AND e.MED_ABBR = b.MED_ABBR
            AND e.EP_END_DT < b.BOUNDARY_DT
    )
    SELECT {extra}CASE
             WHEN DISCON_FLG IS NULL
               THEN '1: no prior episode for this agent'
             WHEN DISCON_FLG = 1
               THEN '2: prior episode MAP_DISCON_FLG = 1'
             ELSE '3: prior episode MAP_DISCON_FLG = 0'
           END                                        AS THE_BUILDS_OWN_VERDICT,
           count(*)                                   AS N_BOUNDARIES,
           count(DISTINCT PATID)                      AS N_PATIENTS,
           percentile_approx(GAP_DAYS, 0.5)           AS MEDIAN_CLAIM_GAP_DAYS,
           percentile_approx(datediff(BOUNDARY_DT, EP_END_DT), 0.5)
                                                      AS MEDIAN_COVER_GAP_DAYS
    FROM ranked
    WHERE rn = 1
    GROUP BY {extra_g}CASE
             WHEN DISCON_FLG IS NULL
               THEN '1: no prior episode for this agent'
             WHEN DISCON_FLG = 1
               THEN '2: prior episode MAP_DISCON_FLG = 1'
             ELSE '3: prior episode MAP_DISCON_FLG = 0'
           END
    ORDER BY {extra_g}THE_BUILDS_OWN_VERDICT")
}

# Per agent: which drugs return, and after how long. A rule change concentrated
# in continuing orals is a different conversation from one spread across agents.
rechall_by_med_sql <- function(events_tbl) {
  glue("
    SELECT MED_ABBR,
           count(*)              AS N_EVENTS,
           count(DISTINCT PATID) AS N_PATIENTS,
           sum(CASE WHEN BOUNDARY = 'SUPPRESSED' THEN 1 ELSE 0 END)
                                 AS N_SUPPRESSED,
           percentile_approx(GAP_DAYS, 0.5) AS MEDIAN_GAP_DAYS,
           sum(CASE WHEN N_NEW_PARTNERS > 0 THEN 1 ELSE 0 END)
                                 AS N_WITH_NEW_PARTNER
    FROM {events_tbl}
    GROUP BY MED_ABBR
    ORDER BY count(*) DESC")
}

# What each candidate threshold would cost, in events. A threshold keeps an event
# as a line boundary when the patient had been off the drug at least that long.
rechall_threshold_sql <- function(events_tbl, days = c(0L, 46L, 91L, 181L)) {
  cols <- paste(vapply(days, function(d) glue(
    "sum(CASE WHEN GAP_DAYS >= {d} THEN 1 ELSE 0 END) AS KEEP_AT_{d}D"),
    character(1)), collapse = ",\n           ")
  glue("
    SELECT BOUNDARY, count(*) AS N_EVENTS,
           {cols},
           sum(CASE WHEN GAP_DAYS IS NULL THEN 1 ELSE 0 END) AS N_NO_PRIOR_CLAIM
    FROM {events_tbl}
    GROUP BY BOUNDARY
    ORDER BY BOUNDARY")
}
