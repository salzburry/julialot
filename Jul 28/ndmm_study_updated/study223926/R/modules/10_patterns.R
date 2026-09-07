# Treatment patterns, attrition and switching - Table 5.
#
# Three tables:
#   S_PATTERNS      N and % receiving each regimen category, by line
#   S_SWITCH        one row per transition, which is the Sankey's edge list
#   S_TX_ATTRITION  the four ways a line ends without a next one
#
# The attrition categories partition the denominator: received a subsequent
# LOT / discontinued and did not receive another / lost to follow-up / died.
# They are computed as a CASE with one arm each rather than as four counts, so
# they cannot overlap and cannot leave a patient out.
mod_patterns <- function(con, cfg, cohort) {
  run_step(con, paste0("patterns_", cohort$key), sprintf("
    CREATE TABLE IF NOT EXISTS %1$s (
      COHORT string, LOT_NUM int, SOC_CATEGORY string,
      N_PATIENTS int, N_DENOM int, PCT double);
    INSERT INTO %1$s
    SELECT s.COHORT, s.LOT_NUM, s.SOC_CATEGORY,
           count(DISTINCT s.PATID) AS N_PATIENTS,
           max(den.N) AS N_DENOM,
           round(100.0 * count(DISTINCT s.PATID) / max(den.N), 1) AS PCT
    FROM %2$s s
    CROSS JOIN (SELECT count(DISTINCT PATID) AS N FROM %3$s
                 WHERE COHORT = '%4$s') den
    WHERE s.COHORT = '%4$s'
    GROUP BY s.COHORT, s.LOT_NUM, s.SOC_CATEGORY",
    wrk("S_PATTERNS"), wrk("S_SOC"), wrk("S_PERIODS"), cohort$key),
    qc = sprintf("SELECT count(*) AS n_rows FROM %s WHERE COHORT='%s'",
                 wrk("S_PATTERNS"), cohort$key))

  run_step(con, paste0("switch_", cohort$key), sprintf("
    CREATE TABLE IF NOT EXISTS %1$s (
      COHORT string, FROM_LOT int, TO_LOT int, FROM_CATEGORY string,
      TO_CATEGORY string, N_PATIENTS int);
    INSERT INTO %1$s
    SELECT a.COHORT, a.LOT_NUM AS FROM_LOT, b.LOT_NUM AS TO_LOT,
           a.SOC_CATEGORY AS FROM_CATEGORY,
           -- A patient with no next line is an edge to a terminal node, not a
           -- missing row: the Sankey has to account for everyone who entered.
           coalesce(b.SOC_CATEGORY,
             CASE WHEN t.OS_EVENT = 1 THEN '(died)' ELSE '(no further therapy)' END)
             AS TO_CATEGORY,
           count(DISTINCT a.PATID) AS N_PATIENTS
    FROM %2$s a
    LEFT JOIN %2$s b ON b.PATID = a.PATID AND b.COHORT = a.COHORT
                    AND b.LOT_NUM = a.LOT_NUM + 1
    LEFT JOIN %3$s t ON t.PATID = a.PATID AND t.COHORT = a.COHORT
                    AND t.LOT_NUM = a.LOT_NUM
    WHERE a.COHORT = '%4$s' AND a.LOT_NUM < %5$d
    GROUP BY a.COHORT, a.LOT_NUM, b.LOT_NUM, a.SOC_CATEGORY, b.SOC_CATEGORY,
             t.OS_EVENT",
    wrk("S_SWITCH"), wrk("S_SOC"), wrk("S_TTE"), cohort$key,
    as.integer(cfg$max_lot)),
    qc = sprintf("SELECT count(*) AS n_edges FROM %s WHERE COHORT='%s'",
                 wrk("S_SWITCH"), cohort$key))

  run_step(con, paste0("tx_attrition_", cohort$key), sprintf("
    CREATE TABLE IF NOT EXISTS %1$s (
      COHORT string, LOT_NUM int, OUTCOME string, N_PATIENTS int,
      N_DENOM int, PCT double);
    INSERT INTO %1$s
    WITH cat AS (
      SELECT t.COHORT, t.LOT_NUM, t.PATID,
             CASE
               WHEN s.NEXT_LOT_START_DT IS NOT NULL THEN 'received_next_lot'
               WHEN t.OS_EVENT = 1                  THEN 'died'
               WHEN s.IS_PROTOCOL_DISCON = 1        THEN 'discontinued_no_further'
               ELSE 'lost_to_followup'
             END AS OUTCOME
      FROM %2$s t
      INNER JOIN %3$s s ON s.PATID = t.PATID AND s.LOT_NUM = t.LOT_NUM
      WHERE t.COHORT = '%4$s'
    )
    SELECT COHORT, LOT_NUM, OUTCOME, count(*) AS N_PATIENTS,
           sum(count(*)) OVER (PARTITION BY COHORT, LOT_NUM) AS N_DENOM,
           round(100.0 * count(*) /
                 sum(count(*)) OVER (PARTITION BY COHORT, LOT_NUM), 1) AS PCT
    FROM cat GROUP BY COHORT, LOT_NUM, OUTCOME",
    wrk("S_TX_ATTRITION"), wrk("S_TTE"), wrk("S_SPINE"), cohort$key),
    qc = sprintf("SELECT count(*) AS n_rows FROM %s WHERE COHORT='%s'",
                 wrk("S_TX_ATTRITION"), cohort$key))

  # The four categories partition the denominator. Checked rather than
  # asserted, because a CASE that stops partitioning is a silent double count.
  chk <- db_q(con, sprintf(
    "SELECT LOT_NUM, sum(N_PATIENTS) AS parts, max(N_DENOM) AS whole
     FROM %s WHERE COHORT='%s' GROUP BY LOT_NUM", wrk("S_TX_ATTRITION"),
    cohort$key))
  bad <- chk[chk$parts != chk$whole, , drop = FALSE]
  if (nrow(bad))
    stop("PATTERNS ERROR: the attrition categories do not sum to the ",
         "denominator for line(s) ", paste(bad$LOT_NUM, collapse = ", "),
         " of ", cohort$key, ". They are meant to partition it.", call. = FALSE)
}
