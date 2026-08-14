-- Re-challenge evidence for the LOT2+ line-boundary question.
--
-- Replace ${schema} with your work schema (e.g. osk02156) and ${prefix} with
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
filled AS (
  SELECT DISTINCT l.PATID, l.LOT_NUM,
         upper(trim(m.MAP_MED_TYPE)) AS MED_ABBR
  FROM ln l
  INNER JOIN hive_metastore.${schema}.${prefix}MAP_STACKED m
          ON cast(m.PATID as string) = l.PATID
         AND m.MAP_MED_CLASS <> 'STEROID'
         AND cast(m.MAP_START_DT as date) >= l.LOT_START_DT
         AND cast(m.MAP_START_DT as date) <= l.IND_END_DT
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
line_meds AS (
  SELECT cast(PATID as string) AS PATID,
         cast(LOT_NUM as int)  AS LOT_NUM,
         m                     AS MED_ABBR
  FROM hive_metastore.${schema}.${prefix}LOT_LONG_FINAL
  LATERAL VIEW explode(split(coalesce(LOT_BASE_MEDS, ''), ' ')) e AS m
  WHERE m <> ''
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
-- The previous claim for the SAME agent. The whole measure: how long the
-- patient had been off the drug, read off claims rather than off cover.
prev_claim AS (
  SELECT r.PATID, r.LOT_NUM, r.MED_ABBR, r.RETURN_DT,
         max(cast(c.DATE_SERVICE as date)) AS PREV_CLAIM_DT
  FROM rechall r
  INNER JOIN hive_metastore.${schema}.${prefix}MMA_MED_PROCESSED c
          ON cast(c.PATID as string) = r.PATID
         AND upper(trim(c.MED_ABBR))  = r.MED_ABBR
         AND cast(c.DATE_SERVICE as date) < r.RETURN_DT
  GROUP BY r.PATID, r.LOT_NUM, r.MED_ABBR, r.RETURN_DT
),
-- Agents starting alongside the return. A drug coming back on its own reads
-- as continuation, and with a new partner as a new regimen.
partners AS (
  SELECT r.PATID, r.LOT_NUM, r.MED_ABBR,
         count(DISTINCT upper(trim(m.MAP_MED_TYPE))) AS N_NEW_PARTNERS
  FROM rechall r
  INNER JOIN hive_metastore.${schema}.${prefix}MAP_STACKED m
          ON cast(m.PATID as string) = r.PATID
         AND m.MAP_MED_CLASS <> 'STEROID'
         AND upper(trim(m.MAP_MED_TYPE)) <> r.MED_ABBR
         AND cast(m.MAP_START_DT as date)
               BETWEEN date_sub(r.RETURN_DT, 30)
                   AND date_add(r.RETURN_DT, 30)
  GROUP BY r.PATID, r.LOT_NUM, r.MED_ABBR
)
SELECT r.PATID, r.LOT_NUM, r.MED_ABBR, r.BOUNDARY,
       r.FIRST_SEEN_LOT, r.LOT_START_DT, r.LOT_END_DT,
       r.LOT_BASE_END_REASON, r.RETURN_DT,
       pc.PREV_CLAIM_DT,
       datediff(r.RETURN_DT, pc.PREV_CLAIM_DT)  AS GAP_DAYS,
       datediff(r.RETURN_DT, r.LOT_START_DT)    AS DAYS_INTO_LOT,
       coalesce(p.N_NEW_PARTNERS, 0)            AS N_NEW_PARTNERS,
       CASE WHEN datediff(r.RETURN_DT, pc.PREV_CLAIM_DT) IS NULL     THEN 'unknown'
WHEN datediff(r.RETURN_DT, pc.PREV_CLAIM_DT) <= 45       THEN '1: <=45d  continuous'
WHEN datediff(r.RETURN_DT, pc.PREV_CLAIM_DT) <= 90       THEN '2: 46-90d  lapse'
WHEN datediff(r.RETURN_DT, pc.PREV_CLAIM_DT) <= 180      THEN '3: 91-180d stopped'
ELSE                        '4: >180d   restart' END AS GAP_BAND,
       'dbx'    AS RECHALL_RUN_ID,
       'manual'   AS SOURCE_LOT_RUN_ID,
       'manual' AS SOURCE_LOT_STAMP,
       current_timestamp()   AS BUILT_AT
FROM rechall r
LEFT JOIN prev_claim pc
       ON pc.PATID = r.PATID AND pc.LOT_NUM = r.LOT_NUM
      AND pc.MED_ABBR = r.MED_ABBR
LEFT JOIN partners p
       ON p.PATID = r.PATID AND p.LOT_NUM = r.LOT_NUM
      AND p.MED_ABBR = r.MED_ABBR
;

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
