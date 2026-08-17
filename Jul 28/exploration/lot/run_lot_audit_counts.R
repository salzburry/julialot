#!/usr/bin/env Rscript
# Real-data frequencies for the LOT assignment findings.
#
#   # list the counts this will run; no connection, touches nothing
#   Rscript run_lot_audit_counts.R
#
#   # run them
#   DATABRICKS_PWD=... DOMINO_USER_NAME=usr00000 OBJECT_PREFIX=ndmm_ \
#     INPUT_COHORT_TABLE=ndmm_NDMM_COHORT \
#     AUDIT_EXECUTE=TRUE Rscript run_lot_audit_counts.R
#
# Read-only. Every statement is a SELECT; nothing is written to the warehouse.
# Results print as a table and land in out/lot_audit_counts.csv.
#
# The audit that produced these questions ran against synthetic patients, so its
# frequencies are shape and not prevalence. This is the same set of questions put
# to the finished build, and its answers are the ones that can be quoted.
#
# AUDIT_TABLE picks which line table to count. It defaults to LOT_LONG, which is
# line assignment on its own; LOT_LONG_FINAL additionally applies the line
# criteria, so counting it mixes assignment behaviour with cohort exclusions.
# Run both only if you want that comparison deliberately.

.script_dir <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  # Rscript renders a space in a path as ~+~, so a folder with one in its name
  # resolves to nothing without this.
  if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                            fixed = TRUE))) else getwd()
})
LOT_ROOT <- normalizePath(file.path(.script_dir, "..", "..", "lot", "engine"), mustWork = TRUE)
out_dir  <- file.path(.script_dir, "out")
env_flag <- function(nm) identical(toupper(trimws(Sys.getenv(nm, unset = ""))), "TRUE")

# One entry per finding. `sql` is a glue template over the table names below.
# `expect` records what the synthetic cohort gave, purely so a wildly different
# real number is noticeable rather than silently accepted.
AUDIT_COUNTS <- list(
  # 1. The one confirmed correctness defect. Induction medications are gathered
  #    across the whole window while the line's end is fixed later in the
  #    cascade, so a transplant that closes the line early can leave an agent in
  #    the regimen whose first supply begins after the line ended. That agent
  #    also reaches the run-out and the next line's prior-regimen exclusion.
  list(id = "regimen-agent-begins-after-line-end",
       what = "Lines naming a regimen agent whose first supply episode starts after the line ended",
       expect = "synthetic: 30 of 10,659 lines carrying a regimen",
       sql = "
      WITH exploded AS (
        SELECT l.PATID, l.LOT_NUM, l.LOT_START_DT, l.LOT_BASE_END_DT,
               explode(split(l.LOT_BASE_MEDS, ' ')) AS MED_ABBR
        FROM {t$long} l
        WHERE coalesce(trim(l.LOT_BASE_MEDS), '') <> ''
      ),
      offending AS (
        SELECT DISTINCT e.PATID, e.LOT_NUM, e.MED_ABBR
        FROM exploded e
        WHERE e.MED_ABBR <> ''
          AND NOT EXISTS (SELECT 1 FROM {t$map} m
                          WHERE m.PATID = e.PATID
                            AND m.MAP_MED_TYPE = e.MED_ABBR
                            AND m.MAP_START_DT BETWEEN e.LOT_START_DT
                                                   AND e.LOT_BASE_END_DT)
      )
      SELECT count(*)                                   AS N_AGENT_LINE_PAIRS,
             count(DISTINCT concat_ws('|', PATID, LOT_NUM)) AS N_LINES,
             count(DISTINCT PATID)                       AS N_PATIENTS
      FROM offending"),

  # 1b. FIXED - the size of the tandem AUTO ownership fix, measured from the
  #     transplants rather than from the lines. auto_cand refused a transplant
  #     a line of its own whenever it landed within sct_tandem_days of the one
  #     before it, without asking whether a line had ever HELD that pair. Where
  #     the earlier transplant fell outside its line's window, nothing held the
  #     line open to the later one, so it belonged to no line and was dropped
  #     from the published row - LOT_LONG clamps the AUTO columns to the span.
  #
  #     Run this against a build from BEFORE the fix to size what it was
  #     costing, and against one after to confirm it is zero. The excused shape
  #     - a transplant trailing the last line once max_lot is used up - is
  #     reported separately, since that one is a reconciliation number and not
  #     a defect at any version.
  list(id = "transplant-belonging-to-no-line",
       what = "FIXED: processed autologous transplants inside no line, split by whether a line was still available",
       expect = "synthetic before the fix: 1 of 14 unowned at 600 patients, 12 of 26 at 2,000; after: 0",
       sql = "
      WITH unowned AS (
        SELECT x.PATID, x.TX_DT,
               (SELECT count(*) FROM {t$long} c WHERE c.PATID = x.PATID) AS N_LINES,
               (SELECT max(c.LOT_BASE_END_DT) FROM {t$long} c WHERE c.PATID = x.PATID) AS LAST_END
        FROM {t$auto} x
        WHERE EXISTS (SELECT 1 FROM {t$long} c WHERE c.PATID = x.PATID)
          AND x.TX_DT >= (SELECT min(c.LOT_START_DT) FROM {t$long} c
                           WHERE c.PATID = x.PATID)
          AND NOT EXISTS (SELECT 1 FROM {t$long} l
                           WHERE l.PATID = x.PATID
                             AND x.TX_DT BETWEEN l.LOT_START_DT AND l.LOT_BASE_END_DT)
      )
      SELECT CASE WHEN TX_DT <= LAST_END THEN 'a. in a gap between two lines'
                  WHEN N_LINES < {max_lot} THEN 'b. after the last line, with lines still available - THE DEFECT'
                  ELSE 'c. after the last line at the cap - a reconciliation number, not a defect'
             END                     AS SHAPE,
             count(*)                AS N_TRANSPLANTS,
             count(DISTINCT PATID)   AS N_PATIENTS
      FROM unowned GROUP BY 1 ORDER BY 1"),

  # 1c. FIXED - the population the same fix moves, measured from the pairs.
  #     A tandem whose FIRST transplant sits outside its line's window is the
  #     shape that was being treated as a planned tandem when no line had
  #     hold of it. This is the group whose line structure the fix can change,
  #     so it bounds the impact whichever direction the numbers move.
  list(id = "tandem-pair-whose-first-transplant-is-out-of-window",
       what = "FIXED: AUTO pairs within sct_tandem_days whose earlier transplant fell outside its line's window",
       expect = "synthetic: bounds the 12 patients the fix moved at 2,000",
       sql = "
      WITH paired AS (
        SELECT PATID, TX_DT,
               lag(TX_DT) OVER (PARTITION BY PATID ORDER BY TX_DT) AS PREV_TX_DT
        FROM {t$auto}
      ),
      owning AS (
        SELECT p.PATID, p.TX_DT, p.PREV_TX_DT, l.LOT_NUM,
               l.LOT_START_DT, l.LOT_START_TYPE
        FROM paired p
        INNER JOIN {t$long} l
          ON l.PATID = p.PATID
         AND p.PREV_TX_DT BETWEEN l.LOT_START_DT AND l.LOT_BASE_END_DT
        WHERE p.PREV_TX_DT IS NOT NULL
          AND datediff(p.TX_DT, p.PREV_TX_DT) <= {tandem_days}
      )
      SELECT LOT_NUM,
             count(*)              AS N_PAIRS,
             count(DISTINCT PATID) AS N_PATIENTS,
             sum(CASE WHEN PREV_TX_DT > date_add(LOT_START_DT,
                   CASE LOT_START_TYPE WHEN 'SCT_ALLO' THEN 0
                                       WHEN 'CART' THEN {cart_days} - 1
                                       WHEN 'MED' THEN CASE WHEN LOT_NUM = 1
                                              THEN {lot1_window} - 1
                                              ELSE {lotn_window} - 1 END
                                       ELSE {lotn_window} - 1 END)
                  THEN 1 ELSE 0 END) AS N_FIRST_OUT_OF_WINDOW
      FROM owning GROUP BY LOT_NUM ORDER BY LOT_NUM"),

  # 1d. FIXED - the guard-mirror defect, sized from the disagreement itself.
  #     auto_cand gained the ownership condition on its tandem exemption and
  #     the two post-run-out guards kept the older test, so for a window the
  #     two disagreed about the same transplant: the guard declined to confirm
  #     a run-out on account of a tandem the next-line gate had already ruled
  #     was not one. The line then ran on and absorbed the transplant instead
  #     of ending and letting the next line open on it.
  #
  #     This counts the shape the disagreement needed: a transplant after a
  #     line's run-out, within sct_tandem_days of the one before it, where THAT
  #     earlier transplant fell outside the line's window. Nonzero on a build
  #     from before the fix is the population whose line lengths and counts the
  #     fix moves; it is the same query either side, because what it counts is
  #     the patient shape and not the verdict.
  list(id = "runout-unconfirmed-by-a-tandem-no-line-held",
       what = "FIXED: post-run-out AUTOs the old guard excused as tandem partners of an out-of-window transplant",
       expect = "the population the guard-mirror fix moves; zero means the shape does not occur here",
       sql = "
      WITH paired AS (
        SELECT PATID, TX_DT,
               lag(TX_DT) OVER (PARTITION BY PATID ORDER BY TX_DT) AS PREV_TX_DT
        FROM {t$auto}
      )
      SELECT l.LOT_NUM,
             count(*)                AS N_TRANSPLANTS,
             count(DISTINCT l.PATID) AS N_PATIENTS
      FROM paired p
      INNER JOIN {t$long} l ON l.PATID = p.PATID
      WHERE p.PREV_TX_DT IS NOT NULL
        -- after this line ran out, and inside it, so the guard was the thing
        -- deciding whether the run-out counted as a discontinuation
        AND p.TX_DT >  l.LOT_BASE_END_DT
        AND datediff(p.TX_DT, p.PREV_TX_DT) <= {tandem_days}
        -- the earlier transplant belongs to this line...
        AND p.PREV_TX_DT BETWEEN l.LOT_START_DT AND l.LOT_BASE_END_DT
        -- ...but fell outside its window, so no line ever held the pair
        AND p.PREV_TX_DT > date_add(l.LOT_START_DT,
              CASE l.LOT_START_TYPE WHEN 'SCT_ALLO' THEN 0
                                    WHEN 'CART' THEN {cart_days} - 1
                                    ELSE CASE WHEN l.LOT_NUM = 1
                                              THEN {lot1_window} - 1
                                              ELSE {lotn_window} - 1 END END)
      GROUP BY l.LOT_NUM ORDER BY l.LOT_NUM"),

  # 1e. NOT a defect - the size of the 90-day threshold, which nothing has
  #     ever measured. A break in supply of even one day starts a new episode.
  #     The 90 days is a separate question: did the patient STOP? Only a drug
  #     that comes back after a confirmed stop is released to open a new line;
  #     under 90 days it stays blocked by the previous line's regimen.
  #
  #     So a difference of days in when a refill was picked up decides whether
  #     a patient gets an extra line. That is the rule as designed. What is not
  #     known is how many patients sit close enough to the threshold for a
  #     delayed pickup or a pharmacy switch to move them across it, which is
  #     what this bands.
  #
  #     Restricted to drugs that were in some line's regimen, because those are
  #     the only ones the release rule applies to. A drug nobody was on cannot
  #     be blocked by a previous regimen in the first place.
  list(id = "return-gap-around-the-90-day-threshold",
       what = "DECISION: how close returning drugs sit to the 90-day line that frees them to open a new LOT",
       expect = "no target - nothing has measured this. Read the two bands either side of 90.",
       sql = "
      WITH in_a_regimen AS (
        SELECT DISTINCT l.PATID, explode(split(l.LOT_BASE_MEDS, ' ')) AS MED_ABBR
        FROM {t$long} l
        WHERE coalesce(trim(l.LOT_BASE_MEDS), '') <> ''
      ),
      gaps AS (
        SELECT m.PATID, m.MAP_MED_TYPE,
               datediff(lead(m.MAP_START_DT) OVER (PARTITION BY m.PATID, m.MAP_MED_TYPE
                                                   ORDER BY m.MAP_START_DT),
                        m.MAP_END_DT) AS GAP_DAYS
        FROM {t$map} m
      )
      SELECT CASE WHEN g.GAP_DAYS <  30 THEN 'a. under 30 days'
                  WHEN g.GAP_DAYS <  76 THEN 'b. 30 to 75'
                  WHEN g.GAP_DAYS <  83 THEN 'c. 76 to 82 - within 2 weeks under'
                  WHEN g.GAP_DAYS <  90 THEN 'd. 83 to 89 - within 1 week under'
                  WHEN g.GAP_DAYS <  97 THEN 'e. 90 to 96 - within 1 week over'
                  WHEN g.GAP_DAYS < 104 THEN 'f. 97 to 103 - within 2 weeks over'
                  WHEN g.GAP_DAYS < 181 THEN 'g. 104 to 180'
                  ELSE                       'h. over 180 days' END AS RETURN_GAP,
             CASE WHEN g.GAP_DAYS >= {discon_days} THEN 'released - may open a LOT'
                  ELSE 'still blocked by the previous regimen' END AS EFFECT,
             count(*)                    AS N_RETURNS,
             count(DISTINCT g.PATID)     AS N_PATIENTS
      FROM gaps g
      INNER JOIN in_a_regimen r
         ON r.PATID = g.PATID AND r.MED_ABBR = g.MAP_MED_TYPE
      WHERE g.GAP_DAYS IS NOT NULL
      GROUP BY 1, 2
      ORDER BY 1"),

  # 2. Not a defect - an open study-team question about how long a
  #    regimen-less transplant line should run. Reported so the decision is
  #    made against real durations rather than a synthetic guess.
  list(id = "empty-regimen-transplant-line-durations",
       what = "DECISION, not a defect: how long transplant lines with no regimen actually run",
       expect = "synthetic: 605/685 ASCT lines empty, mean 506.9d vs 110.5d with a regimen",
       sql = "
      SELECT l.LOT_START_TYPE,
             CASE WHEN l.LOT_MED_CNT = 0 THEN 'empty regimen' ELSE 'has regimen' END AS REGIMEN,
             count(*)                                   AS N_LINES,
             round(avg(l.LOT_BASE_LENGTH), 1)           AS MEAN_LENGTH_DAYS,
             percentile_approx(l.LOT_BASE_LENGTH, 0.5)  AS MEDIAN_LENGTH_DAYS,
             percentile_approx(l.LOT_BASE_LENGTH, 0.75) AS P75_LENGTH_DAYS
      FROM {t$long} l
      GROUP BY 1, 2
      ORDER BY 1, 2"),

  # 3. Treatment outside every line, split by cause. The unpartitioned total is
  #    meaningless: leftover supply deliberately does not carry into a new line,
  #    an ALLO line is one day by design, and therapy past LOT5 is the cap. Only
  #    the residual bucket is a question.
  list(id = "outside-line-days-by-cause",
       what = "Non-steroid agent-DAYS owned by no line, partitioned by cause",
       expect = "no synthetic target - the unpartitioned 11.1% was an invalid measure",
       sql = "
      WITH bounds AS (
        SELECT PATID, min(LOT_START_DT) AS FIRST_START,
               max(LOT_BASE_END_DT)     AS LAST_END,
               max(LOT_NUM)             AS MAX_LOT
        FROM {t$long} GROUP BY PATID
      ),
      drug_days AS (
        SELECT m.PATID, m.MAP_MED_TYPE, m.MAP_CNT,
               explode(sequence(m.MAP_START_DT, m.MAP_END_DT, interval 1 day)) AS SUPPLY_DT
        FROM {t$map} m
        WHERE m.MAP_MED_CLASS <> 'STEROID'
          AND m.MAP_START_DT IS NOT NULL AND m.MAP_END_DT IS NOT NULL
          AND m.MAP_END_DT >= m.MAP_START_DT
      ),
      orphan AS (
        SELECT d.*, b.FIRST_START, b.LAST_END, b.MAX_LOT
        FROM drug_days d
        LEFT JOIN bounds b ON b.PATID = d.PATID
        WHERE NOT EXISTS (SELECT 1 FROM {t$long} l
                          WHERE l.PATID = d.PATID
                            AND d.SUPPLY_DT BETWEEN l.LOT_START_DT AND l.LOT_BASE_END_DT)
      ),
      total AS (SELECT count(*) AS N_ALL_AGENT_DAYS FROM drug_days)
      SELECT CASE
               WHEN FIRST_START IS NULL             THEN 'patient has no LOT'
               WHEN SUPPLY_DT <  FIRST_START        THEN 'before LOT1'
               WHEN MAX_LOT = 5 AND SUPPLY_DT > LAST_END THEN 'past the LOT5 cap'
               WHEN SUPPLY_DT >  LAST_END           THEN 'after the last observed LOT'
               ELSE 'gap between LOTs'
             END                                     AS CAUSE,
             count(*)                                AS N_ORPHAN_AGENT_DAYS,
             round(100.0 * count(*) / max(N_ALL_AGENT_DAYS), 2) AS PCT_OF_ALL_AGENT_DAYS,
             count(DISTINCT PATID)                   AS N_PATIENTS,
             count(DISTINCT concat_ws('|', cast(PATID AS string), MAP_MED_TYPE,
                                      cast(MAP_CNT AS string))) AS N_EPISODES
      FROM orphan CROSS JOIN total
      GROUP BY 1
      ORDER BY 2 DESC"),

  # 5. In-window CAR-T is deliberately not a boundary and IS kept in LOT1_SCT.
  #    The question is only whether the final deliverable can see it.
  list(id = "in-window-cart-not-in-final-table",
       what = "Patients with a CAR-T inside LOT1's induction window, invisible in LOT_LONG",
       expect = "output-surface gap, not a boundary error",
       sql = "
      WITH lot1 AS (
        SELECT PATID, LOT_START_DT AS LOT1_START_DT
        FROM {t$long} WHERE LOT_NUM = 1
      ),
      in_window AS (
        SELECT s.PATID
        FROM {t$sct} s
        INNER JOIN lot1 l ON l.PATID = s.PATID
        WHERE s.FIRST_CART_DT IS NOT NULL
          AND s.FIRST_CART_DT BETWEEN l.LOT1_START_DT
                                  AND date_add(l.LOT1_START_DT, {lot1_window - 1})
      ),
      cart_line AS (
        SELECT DISTINCT PATID FROM {t$long} WHERE LOT_START_TYPE = 'CART'
      )
      SELECT count(*)                                                  AS N_PATIENTS_IN_WINDOW_CART,
             sum(CASE WHEN c.PATID IS NOT NULL THEN 1 ELSE 0 END)      AS N_ALSO_WITH_A_CART_LINE_LATER
      FROM in_window i LEFT JOIN cart_line c ON c.PATID = i.PATID"),

  # Context for the Q1 duration tab. Not a finding on its own.
  list(id = "line-length-by-start-type",
       what = "Line duration by line number and start type - context for the Q1 tab",
       expect = "no target; this is the distribution the findings above bear on",
       sql = "
      SELECT l.LOT_NUM, l.LOT_START_TYPE,
             count(*)                                   AS N_LINES,
             round(avg(l.LOT_BASE_LENGTH), 1)           AS MEAN_LENGTH_DAYS,
             percentile_approx(l.LOT_BASE_LENGTH, 0.5)  AS MEDIAN_LENGTH_DAYS,
             percentile_approx(l.LOT_BASE_LENGTH, 0.75) AS P75_LENGTH_DAYS
      FROM {t$long} l
      GROUP BY 1, 2
      ORDER BY 1, 2"),

  # 7. The post-end regimen defect, sized where the fix would have to reach.
  #    Split by line number and by what ended the line, because the analysis
  #    says which paths can strand: ALLO at every line, CAR-T at LOT2-5 only
  #    (LOT1's induction exemption closes that one), and AUTO nowhere, since the
  #    in-LOT AUTO window is the regimen window. A count landing on SCT_AUTO or
  #    on a LOT1 SCT_CART contradicts that reading and is the finding.
  list(id = "post-end-regimen-by-line-and-end-reason",
       what = "Lines naming a regimen agent whose first episode starts after the line ended, by LOT and end reason",
       expect = "expected on SCT_ALLO at any line and SCT_CART at LOT2+; anything else contradicts the analysis",
       sql = "
      WITH exploded AS (
        SELECT l.PATID, l.LOT_NUM, l.LOT_START_DT, l.LOT_BASE_END_DT,
               l.LOT_BASE_END_REASON,
               explode(split(l.LOT_BASE_MEDS, ' ')) AS MED_ABBR
        FROM {t$long} l
        WHERE coalesce(trim(l.LOT_BASE_MEDS), '') <> ''
      ),
      offending AS (
        SELECT DISTINCT e.PATID, e.LOT_NUM, e.LOT_BASE_END_REASON, e.MED_ABBR
        FROM exploded e
        WHERE e.MED_ABBR <> ''
          AND NOT EXISTS (SELECT 1 FROM {t$map} m
                          WHERE m.PATID = e.PATID
                            AND m.MAP_MED_TYPE = e.MED_ABBR
                            AND m.MAP_START_DT BETWEEN e.LOT_START_DT
                                                   AND e.LOT_BASE_END_DT)
      )
      SELECT LOT_NUM, LOT_BASE_END_REASON,
             count(*)                                        AS N_AGENT_LINE_PAIRS,
             count(DISTINCT concat_ws('|', PATID, LOT_NUM))  AS N_LINES,
             count(DISTINCT PATID)                           AS N_PATIENTS
      FROM offending
      GROUP BY 1, 2
      ORDER BY 1, 2"),

  # 8. The consequence that is not cosmetic: the same agent counted in a line it
  #    post-dates AND opening a later line. This is the number the decision turns
  #    on, because it is the one that moves a line count rather than a string.
  list(id = "post-end-agent-also-starts-a-later-line",
       what = "Stranded regimen agents that also appear in a LATER line's regimen for the same patient",
       expect = "no target; this is double attribution, and the reason the defect is not cosmetic",
       sql = "
      WITH exploded AS (
        SELECT l.PATID, l.LOT_NUM, l.LOT_START_DT, l.LOT_BASE_END_DT,
               explode(split(l.LOT_BASE_MEDS, ' ')) AS MED_ABBR
        FROM {t$long} l
        WHERE coalesce(trim(l.LOT_BASE_MEDS), '') <> ''
      ),
      stranded AS (
        SELECT DISTINCT e.PATID, e.LOT_NUM, e.MED_ABBR
        FROM exploded e
        WHERE e.MED_ABBR <> ''
          AND NOT EXISTS (SELECT 1 FROM {t$map} m
                          WHERE m.PATID = e.PATID
                            AND m.MAP_MED_TYPE = e.MED_ABBR
                            AND m.MAP_START_DT BETWEEN e.LOT_START_DT
                                                   AND e.LOT_BASE_END_DT)
      )
      SELECT s.LOT_NUM                                       AS STRANDED_IN_LOT,
             count(*)                                        AS N_AGENT_LINE_PAIRS,
             count(DISTINCT concat_ws('|', s.PATID, s.LOT_NUM)) AS N_LINES,
             count(DISTINCT s.PATID)                         AS N_PATIENTS
      FROM stranded s
      INNER JOIN exploded later
              ON later.PATID = s.PATID
             AND later.LOT_NUM > s.LOT_NUM
             AND later.MED_ABBR = s.MED_ABBR
      GROUP BY 1
      ORDER BY 1"),

  # 9. The second-order half of the same fix. Bounding regimen MEMBERSHIP is not
  #    enough on its own: discon_per_med chains a base agent's own later episodes
  #    forward from the line's START with no upper bound, so a refill after the
  #    transplant still pushes RAW_DISCON_DT past it. Counted separately because
  #    it survives the membership fix and needs its own cutoff.
  list(id = "runout-extends-past-the-transplant-end",
       what = "Lines ended by a transplant whose regimen was still covered after that end",
       expect = "no target; these are the lines where bounding membership alone would not be enough",
       # Off map_stacked, not off a run-out column. LOT_LONG does not carry one:
       # LOT_BASE_RUNOUT_DT lives on the per-line *_BASE tables and stops there,
       # and only LOT_BASE_DISCON_DT is projected. This query used to name the
       # run-out anyway and failed on the warehouse with an unresolved column -
       # invisibly, because the execute path could not run at all until the
       # config ordering above was fixed.
       #
       # DISCON_DT is not the substitute either. It is the CONFIRMED
       # discontinuation, and a line ended by a transplant usually has none, so
       # reading it would answer zero for a reason that has nothing to do with
       # the question. The line's own cover is what the question is about, so
       # it is taken from the episodes: the last cover end among the agents the
       # line names, over episodes that had started by the time it ended.
       sql = "
      WITH ended_by_tx AS (
        SELECT l.PATID, l.LOT_NUM, l.LOT_BASE_END_DT, l.LOT_BASE_END_REASON,
               explode(split(l.LOT_BASE_MEDS, ' ')) AS MED_ABBR
        FROM {t$long} l
        WHERE l.LOT_BASE_END_REASON IN ('SCT_AUTO', 'SCT_ALLO', 'SCT_CART')
          AND coalesce(trim(l.LOT_BASE_MEDS), '') <> ''
      ),
      cover AS (
        SELECT e.PATID, e.LOT_NUM, e.LOT_BASE_END_DT, e.LOT_BASE_END_REASON,
               max(m.MAP_END_DT) AS LAST_COVER_DT
        FROM ended_by_tx e
        INNER JOIN {t$map} m
          ON m.PATID = e.PATID
         AND m.MAP_MED_TYPE = e.MED_ABBR
         AND m.MAP_START_DT <= e.LOT_BASE_END_DT
        WHERE e.MED_ABBR <> ''
        GROUP BY 1, 2, 3, 4
      )
      SELECT LOT_NUM, LOT_BASE_END_REASON,
             count(*)                AS N_LINES,
             count(DISTINCT PATID)   AS N_PATIENTS,
             percentile_approx(datediff(LAST_COVER_DT, LOT_BASE_END_DT), 0.5)
                                     AS MEDIAN_DAYS_PAST_END,
             max(datediff(LAST_COVER_DT, LOT_BASE_END_DT))
                                     AS MAX_DAYS_PAST_END
      FROM cover
      WHERE LAST_COVER_DT > LOT_BASE_END_DT
      GROUP BY 1, 2
      ORDER BY 1, 2")
)

report_plan <- function() {
  cat("\nReal-data frequencies for the LOT assignment findings.\n\n")
  cat("Read-only: every statement is a SELECT. Nothing is written to the warehouse.\n\n")
  for (a in AUDIT_COUNTS) {
    cat("  ", a$id, "\n    ", a$what, "\n    ", a$expect, "\n", sep = "")
  }
  # The trailer says what happens NEXT, so it has to know whether this is the
  # dry run. Printed unconditionally it told an operator who had already set
  # AUDIT_EXECUTE to set it - which reads as the flag not having been picked
  # up, and sends them after the wrong thing when the next line is an error.
  cat("\n", length(AUDIT_COUNTS), " counts.", sep = "")
  if (env_flag("AUDIT_EXECUTE")) {
    cat(" Running them now.\n\n")
  } else {
    cat(" Set AUDIT_EXECUTE=TRUE to run them.\n")
    cat("Needs DATABRICKS_PWD, DOMINO_USER_NAME (or PROJECT_WORK_SCHEMA),\n")
    cat("OBJECT_PREFIX and INPUT_COHORT_TABLE.\n\n")
  }
}

main <- function() {
  report_plan()
  if (!env_flag("AUDIT_EXECUTE")) return(invisible(0L))

  library(DBI); library(odbc); library(glue)
  source(file.path(LOT_ROOT, "R", "load_inputs.R"))
  load_pipeline_inputs(LOT_ROOT, "config.csv")
  for (f in c("config_lot.R", "db_utils_lot.R")) source(file.path(LOT_ROOT, "R", f))

  # cfg_defaults, not lot_config(). config_lot.R defines cfg_defaults when it is
  # sourced; lot_config() reads the config that set_lot_config() installs, and
  # that has not happened yet - it happens below, once the schema and prefix
  # this script is given have been folded in. Calling it here stopped the whole
  # execute path on its own guard, which is why only the plan ever printed.
  cfg <- get("cfg_defaults", envir = globalenv())
  schema <- trimws(Sys.getenv("PROJECT_WORK_SCHEMA",
             unset = Sys.getenv("DOMINO_USER_NAME",
             unset = Sys.getenv("DOMINO_STARTING_USERNAME", unset = ""))))
  if (!nzchar(schema))
    stop("No work schema. Set DOMINO_USER_NAME to the schema the build wrote into, ",
         "or PROJECT_WORK_SCHEMA to override.", call. = FALSE)
  cfg$work_schema <- schema

  pfx <- trimws(Sys.getenv("OBJECT_PREFIX", unset = ""))
  if (!nzchar(pfx))
    stop("No OBJECT_PREFIX. It names the run's tables, so without it this would ",
         "count whatever unprefixed tables happen to exist.", call. = FALSE)
  if (!grepl("^[A-Za-z][A-Za-z0-9_]*_$", pfx))
    stop("OBJECT_PREFIX '", pfx, "' should be a name ending in '_'.", call. = FALSE)
  cfg$object_prefix <- pfx

  cohort <- trimws(Sys.getenv("INPUT_COHORT_TABLE", unset = ""))
  if (!nzchar(cohort))
    stop("No INPUT_COHORT_TABLE. The death-date count reads the cohort for its ",
         "observation window. Give the whole name including the prefix, e.g. ",
         pfx, "NDMM_COHORT.", call. = FALSE)

  set_lot_config(cfg)
  dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
  stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")

  # Which line table to count. LOT_LONG_FINAL is the study deliverable, with the
  # line criteria applied; LOT_LONG is what the engine built before them.
  which_tbl <- trimws(Sys.getenv("AUDIT_TABLE", unset = "LOT_LONG"))
  if (!which_tbl %in% c("LOT_LONG_FINAL", "LOT_LONG"))
    stop("AUDIT_TABLE must be LOT_LONG_FINAL or LOT_LONG.", call. = FALSE)

  # OBS_END_DT is not persisted - it is chosen at build time from ENDDATE or
  # ENDDATE_CE. Match whichever the run used, or the death filter will disagree
  # with the build's own idea of when observation stopped.
  obs_col <- if (isTRUE(cfg$censor_at_disenrollment)) "ENDDATE_CE" else "ENDDATE"

  lot1_window <- cfg$induction_window_days
  # Named locally so the new AUDIT_COUNTS templates read the settings the run
  # used rather than restating them - a count that hard-codes 180 or 45 stops
  # sizing the build the moment a contract deviation moves either.
  lotn_window <- cfg$lot_n_induction_window_days
  cart_days   <- cfg$cart_consolidation_days
  tandem_days <- cfg$sct_tandem_days
  max_lot     <- cfg$max_lot
  discon_days <- cfg$map_discon_gap_days
  t <- list(long   = lot_out(which_tbl),
            map    = lot_out("MAP_STACKED"),
            sct    = lot_out("LOT1_SCT"),
            auto   = lot_out("TX_AUTO_DATES"),
            cohort = wrk(cohort))

  cat("Counting against:\n")
  for (nm in names(t)) cat("  ", nm, ": ", t[[nm]], "\n", sep = "")
  cat("  observation column: ", obs_col, "\n\n", sep = "")

  # Substitution reciprocity is a codelist question, not a warehouse one:
  # permissible_subs is loaded from CSV into a session view and is not persisted,
  # so it is checked here against the file the build would read. A one-way pair
  # is not automatically wrong - some are deliberately directional - but the set
  # should be reviewed rather than assumed symmetric.
  subs_csv <- file.path(cfg$codelist_dir, "permissible_subs.csv")
  cat("== substitution-reciprocity\n")
  if (!file.exists(subs_csv)) {
    cat("   SKIPPED: no permissible_subs.csv at ", subs_csv, "\n\n", sep = "")
  } else {
    ps <- utils::read.csv(subs_csv, stringsAsFactors = FALSE)
    key <- paste(ps$original_med, ps$substitute_med)
    rev <- paste(ps$substitute_med, ps$original_med)
    one_way <- ps[!(key %in% rev), c("original_med", "substitute_med")]
    cat("   ", nrow(ps), " pairs, ", nrow(one_way), " present in one direction only\n", sep = "")
    if (nrow(one_way)) print(head(one_way, 20), row.names = FALSE)
    cat("\n")
  }

  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  rows <- list()
  failed <- 0L
  for (a in AUDIT_COUNTS) {
    cat("== ", a$id, "\n", sep = "")
    cat("   ", a$what, "\n", sep = "")
    sql <- glue(a$sql, .open = "{", .close = "}")
    res <- tryCatch(DBI::dbGetQuery(con, sql), error = function(e) e)
    if (inherits(res, "error")) {
      failed <- failed + 1L
      cat("   FAILED: ", conditionMessage(res), "\n\n", sep = "")
      next
    }
    print(res, row.names = FALSE)
    cat("   (", a$expect, ")\n\n", sep = "")
    # Long format, one row per cell. The counts return different columns from
    # each other, so writing them as separate CSV tables into one file produced
    # repeated headers and a file nothing could read.
    if (nrow(res)) {
      for (i in seq_len(nrow(res))) for (nm in names(res)) {
        rows[[length(rows) + 1L]] <- data.frame(
          finding = a$id, row = i, metric = nm,
          value = as.character(res[[nm]][i]),
          stringsAsFactors = FALSE)
      }
    }
  }

  csv <- file.path(out_dir, "lot_audit_counts.csv")
  utils::write.csv(do.call(rbind, rows), csv, row.names = FALSE)
  cat("Wrote ", csv, "\n", sep = "")
  if (failed) {
    cat(failed, " count(s) failed - see the messages above.\n", sep = "")
    return(invisible(1L))
  }
  invisible(0L)
}

if (!interactive()) quit(status = main())
