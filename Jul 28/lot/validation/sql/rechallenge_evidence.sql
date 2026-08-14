-- Re-challenge evidence for the LOT2+ line-boundary question.
--
-- Replace ${schema} with your work schema (e.g. osk02156) and ${prefix} with
-- the run's OBJECT_PREFIX. Set ${subs_table} to the permissible-substitution
-- table (SHOW TABLES IN hive_metastore.clnprw_codelists). Without it a
-- biosimilar of a regimen agent counts as an outside agent and the suppressed
-- numbers are an UPPER BOUND.
-- the run's OBJECT_PREFIX (e.g. ndmm_), or set them as notebook widgets.
--
-- Reads three tables from a FINISHED LOT run and writes nothing. Run the
-- blocks in order, each temp view feeds the next.
--   LOT_LONG_FINAL      the lines
--   MAP_STACKED         the supply episodes
--   MMA_MED_PROCESSED   the claim dates, one row per patient/agent/date

-- ===========================================================================
-- 1. Added-medication boundaries an open episode absorbed.
--    A claim for an agent outside the line's regimen, after the induction
--    window, that opened no episode of its own - so the build never saw it.
-- ===========================================================================
CREATE OR REPLACE TEMP VIEW stockpile_absorbed_add AS
WITH ln AS (
  SELECT cast(PATID as string)         AS PATID,
         cast(LOT_NUM as int)          AS LOT_NUM,
         cast(LOT_START_DT as date)    AS LOT_START_DT,
         LOT_START_TYPE,
         cast(LOT_BASE_END_DT as date) AS LOT_END_DT,
         LOT_BASE_END_REASON,
         CASE
  WHEN cast(LOT_NUM as int) = 1
    THEN date_add(cast(LOT_START_DT as date), 59)
  WHEN LOT_START_TYPE = 'CART'
    THEN date_add(cast(LOT_START_DT as date), 44)
  ELSE date_add(cast(LOT_START_DT as date), 29)
END       AS IND_END_DT
  FROM hive_metastore.${schema}.${prefix}LOT_LONG_FINAL
  WHERE LOT_START_TYPE <> 'SCT_ALLO'
),
-- The previous line's regimen, exploded to whole tokens. LOT_BASE_MEDS is a
-- space-separated string and matching inside it would make LEN match LENA.
prev_regimen AS (
  SELECT cast(PATID as string)   AS PATID,
         cast(LOT_NUM as int) + 1 AS LOT_NUM,
         m                        AS MED_ABBR
  FROM hive_metastore.${schema}.${prefix}LOT_LONG_FINAL
  LATERAL VIEW explode(split(coalesce(LOT_BASE_MEDS, ''), ' ')) e AS m
  WHERE m <> ''
),
-- This line's regimen: an episode that OPENED inside the window. The same
-- test 10_lot2_5_base.R joins base_meds on.
subs AS (
  SELECT upper(trim(original_med))   AS original_med,
       upper(trim(substitute_med)) AS substitute_med
FROM ${subs_table}
),
filled_raw AS (
  SELECT DISTINCT l.PATID, l.LOT_NUM,
         upper(trim(m.MAP_MED_TYPE)) AS MED_ABBR
  FROM ln l
  INNER JOIN hive_metastore.${schema}.${prefix}MAP_STACKED m
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
  INNER JOIN hive_metastore.${schema}.${prefix}MMA_MED_PROCESSED c
          ON cast(c.PATID as string) = l.PATID
         AND c.MED_CLASS <> 'STEROID'
         AND cast(c.DATE_SERVICE as date) >  l.IND_END_DT
         AND cast(c.DATE_SERVICE as date) <= l.LOT_END_DT
),
opened AS (
  SELECT DISTINCT cast(PATID as string)  AS PATID,
         upper(trim(MAP_MED_TYPE))       AS MED_ABBR,
         cast(MAP_START_DT as date)      AS CLAIM_DT
  FROM hive_metastore.${schema}.${prefix}MAP_STACKED
  WHERE MAP_MED_CLASS <> 'STEROID'
),
ep AS (
  SELECT cast(PATID as string)       AS PATID,
         upper(trim(MAP_MED_TYPE))   AS MED_ABBR,
         cast(MAP_START_DT as date)  AS EPISODE_START_DT,
         cast(MAP_END_DT as date)    AS EPISODE_END_DT
  FROM hive_metastore.${schema}.${prefix}MAP_STACKED
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
       'dbx'    AS STOCK_RUN_ID,
       'manual'   AS SOURCE_LOT_RUN_ID,
       'manual' AS SOURCE_LOT_STAMP,
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
         a.N_ABSORBED_CLAIMS
;

-- ===========================================================================
-- 2. Re-challenge events: an agent from an earlier line returning to a line
--    it is not part of. GAP_DAYS is the days since the previous claim for
--    that agent - the measure the decision turns on.
--    BOUNDARY = FIRED where the build ended the line, SUPPRESSED where an
--    open episode absorbed the claim and it did not.
-- ===========================================================================
CREATE OR REPLACE TEMP VIEW rechall_events AS
WITH ln AS (
  SELECT cast(PATID as string)         AS PATID,
         cast(LOT_NUM as int)          AS LOT_NUM,
         cast(LOT_START_DT as date)    AS LOT_START_DT,
         LOT_START_TYPE,
         cast(LOT_BASE_END_DT as date) AS LOT_END_DT,
         LOT_BASE_END_REASON,
         upper(trim(coalesce(LOT_BASE_1ST_ADD_MED, ''))) AS ADD_MED,
         CASE
  WHEN cast(LOT_NUM as int) = 1
    THEN date_add(cast(LOT_START_DT as date), 59)
  WHEN LOT_START_TYPE = 'CART'
    THEN date_add(cast(LOT_START_DT as date), 44)
  ELSE date_add(cast(LOT_START_DT as date), 29)
END       AS IND_END_DT
  FROM hive_metastore.${schema}.${prefix}LOT_LONG_FINAL
  WHERE LOT_START_TYPE <> 'SCT_ALLO'
),
-- Every agent in every line, as whole tokens. Matching inside the string
-- would make LEN match LENA.
subs AS (
  SELECT upper(trim(original_med))   AS original_med,
       upper(trim(substitute_med)) AS substitute_med
FROM ${subs_table}
),
line_meds_raw AS (
  SELECT cast(PATID as string) AS PATID,
         cast(LOT_NUM as int)  AS LOT_NUM,
         m                     AS MED_ABBR
  FROM hive_metastore.${schema}.${prefix}LOT_LONG_FINAL
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
  FROM stockpile_absorbed_add
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
  INNER JOIN hive_metastore.${schema}.${prefix}MMA_MED_PROCESSED c
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
  INNER JOIN hive_metastore.${schema}.${prefix}MAP_STACKED m
          ON cast(m.PATID as string) = r.PATID
         AND m.MAP_MED_CLASS <> 'STEROID'
         AND upper(trim(m.MAP_MED_TYPE)) <> r.MED_ABBR
         AND cast(m.MAP_START_DT as date)
               BETWEEN date_sub(r.RETURN_DT, 30)
                   AND date_add(r.RETURN_DT, 30)
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
       CASE WHEN datediff(r.RETURN_DT, pc.PREV_CLAIM_DT) IS NULL     THEN 'unknown'
WHEN datediff(r.RETURN_DT, pc.PREV_CLAIM_DT) <= 45       THEN '1: claim gap <=45d'
WHEN datediff(r.RETURN_DT, pc.PREV_CLAIM_DT) <= 90       THEN '2: claim gap 46-90d'
WHEN datediff(r.RETURN_DT, pc.PREV_CLAIM_DT) <= 180      THEN '3: claim gap 91-180d'
ELSE                        '4: claim gap >180d' END AS GAP_BAND,
       'dbx'    AS RECHALL_RUN_ID,
       'manual'   AS SOURCE_LOT_RUN_ID,
       'manual' AS SOURCE_LOT_STAMP,
       current_timestamp()   AS BUILT_AT
FROM ev1 r
LEFT JOIN prev_claim pc
       ON pc.PATID = r.PATID AND pc.LOT_NUM = r.LOT_NUM
      AND pc.MED_ABBR = r.MED_ABBR AND pc.RETURN_DT = r.RETURN_DT
LEFT JOIN partners p
       ON p.PATID = r.PATID AND p.LOT_NUM = r.LOT_NUM
      AND p.MED_ABBR = r.MED_ABBR AND p.RETURN_DT = r.RETURN_DT
;

-- ===========================================================================
-- 2b. SANITY CHECK. Run this BEFORE reading anything below. A gap is taken
--     from a claim strictly before the return, so it cannot be negative. If
--     N_NEGATIVE_GAP is not 0, an event has been paired with another return's
--     previous claim and every gap in the table is suspect - stop and say so.
-- ===========================================================================
SELECT
  count(*)                                              AS N_EVENTS,
  sum(CASE WHEN GAP_DAYS < 0 THEN 1 ELSE 0 END)         AS N_NEGATIVE_GAP,
  sum(CASE WHEN GAP_DAYS IS NULL THEN 1 ELSE 0 END)     AS N_NO_PRIOR_CLAIM,
  count(*) - count(DISTINCT concat_ws('|', PATID, cast(LOT_NUM as string),
                                      MED_ABBR))        AS N_DUPLICATE_KEYS
FROM rechall_events;

-- ===========================================================================
-- 3. THE ANSWER TABLE. Read down each band: where FIRED and SUPPRESSED look
--    alike, the build is splitting clinically identical patients on nothing
--    but leftover days-supply.
-- ===========================================================================
SELECT GAP_BAND, BOUNDARY,
       count(*)                  AS N_EVENTS,
       count(DISTINCT PATID)     AS N_PATIENTS,
       percentile_approx(GAP_DAYS, 0.5)  AS MEDIAN_GAP_DAYS,
       sum(CASE WHEN N_NEW_PARTNERS > 0 THEN 1 ELSE 0 END)
                                 AS N_WITH_NEW_PARTNER,
       percentile_approx(DAYS_INTO_LOT, 0.5) AS MEDIAN_DAYS_INTO_LOT
FROM rechall_events
GROUP BY GAP_BAND, BOUNDARY
ORDER BY GAP_BAND, BOUNDARY
;

-- ===========================================================================
-- 4. What each candidate threshold would keep as a line boundary.
-- ===========================================================================
SELECT BOUNDARY, count(*) AS N_EVENTS,
       sum(CASE WHEN GAP_DAYS >= 0 THEN 1 ELSE 0 END) AS KEEP_AT_0D,
           sum(CASE WHEN GAP_DAYS >= 46 THEN 1 ELSE 0 END) AS KEEP_AT_46D,
           sum(CASE WHEN GAP_DAYS >= 91 THEN 1 ELSE 0 END) AS KEEP_AT_91D,
           sum(CASE WHEN GAP_DAYS >= 181 THEN 1 ELSE 0 END) AS KEEP_AT_181D,
       sum(CASE WHEN GAP_DAYS IS NULL THEN 1 ELSE 0 END) AS N_NO_PRIOR_CLAIM
FROM rechall_events
GROUP BY BOUNDARY
ORDER BY BOUNDARY
;

-- ===========================================================================
-- 5. Which agents return, and after how long.
-- ===========================================================================
SELECT MED_ABBR,
       count(*)              AS N_EVENTS,
       count(DISTINCT PATID) AS N_PATIENTS,
       sum(CASE WHEN BOUNDARY = 'SUPPRESSED' THEN 1 ELSE 0 END)
                             AS N_SUPPRESSED,
       percentile_approx(GAP_DAYS, 0.5) AS MEDIAN_GAP_DAYS,
       sum(CASE WHEN N_NEW_PARTNERS > 0 THEN 1 ELSE 0 END)
                             AS N_WITH_NEW_PARTNER
FROM rechall_events
GROUP BY MED_ABBR
ORDER BY count(*) DESC
;

-- ===========================================================================
-- 7. What the build actually did. A suppressed return is not always a missing
--    boundary: the agent can return again later in the same line and open an
--    episode then, so the boundary exists but in the wrong place. Read this
--    before calling any suppressed count a missed boundary.
-- ===========================================================================
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
FROM rechall_events
GROUP BY GAP_BAND,
         CASE WHEN BOUNDARY = 'FIRED'          THEN 'on the first return'
              WHEN DAYS_BUILD_LATE IS NOT NULL THEN 'on a later return'
              ELSE                                  'never in this line' END
ORDER BY GAP_BAND, WHAT_THE_BUILD_DID
;

-- ===========================================================================
-- 8. For the boundaries the build made on a LATER return, the gap AT that
--    later return. This decides whether 'late' is a defect: a long gap there
--    means the boundary is in the right place and the first return was never
--    a candidate, and another short one a second boundary made out of
--    dosing rhythm.
-- ===========================================================================
WITH late AS (
  SELECT PATID, LOT_NUM, MED_ABBR, GAP_DAYS AS FIRST_GAP_DAYS,
         date_add(RETURN_DT, DAYS_BUILD_LATE) AS FIRED_DT
  FROM rechall_events
  WHERE BOUNDARY = 'SUPPRESSED' AND DAYS_BUILD_LATE IS NOT NULL
),
prev AS (
  SELECT l.PATID, l.LOT_NUM, l.MED_ABBR, l.FIRED_DT,
         max(cast(c.DATE_SERVICE as date)) AS PREV_BEFORE_FIRED
  FROM late l
  INNER JOIN hive_metastore.${schema}.${prefix}MMA_MED_PROCESSED c
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
SELECT CASE WHEN FIRED_GAP_DAYS IS NULL     THEN 'unknown'
WHEN FIRED_GAP_DAYS <= 45       THEN '1: claim gap <=45d'
WHEN FIRED_GAP_DAYS <= 90       THEN '2: claim gap 46-90d'
WHEN FIRED_GAP_DAYS <= 180      THEN '3: claim gap 91-180d'
ELSE                        '4: claim gap >180d' END AS GAP_BAND_AT_THE_BOUNDARY,
       count(*)                             AS N_EVENTS,
       count(DISTINCT PATID)                AS N_PATIENTS,
       percentile_approx(FIRED_GAP_DAYS, 0.5) AS MEDIAN_GAP_AT_BOUNDARY,
       percentile_approx(FIRST_GAP_DAYS, 0.5) AS MEDIAN_GAP_AT_FIRST_RETURN
FROM j
GROUP BY CASE WHEN FIRED_GAP_DAYS IS NULL     THEN 'unknown'
WHEN FIRED_GAP_DAYS <= 45       THEN '1: claim gap <=45d'
WHEN FIRED_GAP_DAYS <= 90       THEN '2: claim gap 46-90d'
WHEN FIRED_GAP_DAYS <= 180      THEN '3: claim gap 91-180d'
ELSE                        '4: claim gap >180d' END
ORDER BY GAP_BAND_AT_THE_BOUNDARY
;

-- ===========================================================================
-- 9. THE ONE THAT MATTERS. Every boundary these events produced, against the
--    build's OWN verdict on whether the agent had been stopped.
--    03_mma_map.R sets MAP_DISCON_FLG per episode: 1 = discontinued, 0 = the
--    drug carried on. The added-medication query reads the same table and
--    never looks at it. Row 3 is where MAP_STACKED says the agent continued
--    and the line was ended anyway. No threshold of this script's choosing.
-- ===========================================================================
WITH ep AS (
  SELECT cast(PATID as string)      AS PATID,
         upper(trim(MAP_MED_TYPE))  AS MED_ABBR,
         cast(MAP_END_DT as date)   AS EP_END_DT,
         cast(MAP_DISCON_FLG as int) AS DISCON_FLG
  FROM hive_metastore.${schema}.${prefix}MAP_STACKED
  WHERE MAP_MED_CLASS <> 'STEROID'
),
bnd AS (
  SELECT PATID, LOT_NUM, MED_ABBR, GAP_DAYS,
         CASE WHEN BOUNDARY = 'FIRED' THEN RETURN_DT
              ELSE date_add(RETURN_DT, DAYS_BUILD_LATE) END AS BOUNDARY_DT
  FROM rechall_events
  WHERE BOUNDARY = 'FIRED' OR DAYS_BUILD_LATE IS NOT NULL
),
ranked AS (
  SELECT b.PATID, b.LOT_NUM, b.MED_ABBR, b.BOUNDARY_DT, b.GAP_DAYS,
         e.DISCON_FLG, e.EP_END_DT,
         row_number() OVER (PARTITION BY b.PATID, b.LOT_NUM, b.MED_ABBR,
                                         b.BOUNDARY_DT
                            ORDER BY e.EP_END_DT DESC) AS rn
  FROM bnd b
  LEFT JOIN ep e
         ON e.PATID = b.PATID AND e.MED_ABBR = b.MED_ABBR
        AND e.EP_END_DT < b.BOUNDARY_DT
)
SELECT CASE
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
GROUP BY CASE
         WHEN DISCON_FLG IS NULL
           THEN '1: no prior episode for this agent'
         WHEN DISCON_FLG = 1
           THEN '2: prior episode MAP_DISCON_FLG = 1'
         ELSE '3: prior episode MAP_DISCON_FLG = 0'
       END
ORDER BY THE_BUILDS_OWN_VERDICT
;

-- ===========================================================================
-- 6. Line counts under each threshold, for scale. This is events, NOT a
--    resulting line structure: keeping or dropping a boundary renumbers every
--    later line for that patient. An exact structure needs an alternate build.
-- ===========================================================================
SELECT
  count(*)                                                  AS N_EVENTS,
  count(DISTINCT PATID)                                     AS N_PATIENTS,
  sum(CASE WHEN BOUNDARY = 'SUPPRESSED' THEN 1 ELSE 0 END)  AS N_BUILD_MISSED,
  sum(CASE WHEN GAP_DAYS <= 45 THEN 1 ELSE 0 END)           AS N_CONTINUOUS,
  sum(CASE WHEN GAP_DAYS > 180 THEN 1 ELSE 0 END)           AS N_TRUE_RESTART,
  percentile_approx(GAP_DAYS, array(0.25, 0.5, 0.75))       AS GAP_QUARTILES
FROM rechall_events;
