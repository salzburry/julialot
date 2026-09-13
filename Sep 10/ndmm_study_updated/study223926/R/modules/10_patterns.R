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
  # Death per LINE, not per cohort index. S_TTE carries only the cohort's own
  # index line, so joining it on LOT_NUM would leave every later line with a
  # NULL death flag and draw a patient who died after line 2 on the Sankey as
  # having stopped therapy alive.
  db_exec(con, sprintf("
    CREATE OR REPLACE TEMPORARY VIEW s_line_end AS
    -- Bounded by the cohort's own observation, exactly as 05_soc.R is. A line
    -- that STARTS after FU_END is not a line this cohort saw, and a next line
    -- beginning after FU_END is not therapy this cohort observed the patient
    -- receiving - it is where the patient was censored. s7.8.2 allows
    -- censoring as a terminal Sankey outcome; calling it `received_next_lot`
    -- made S_TX_ATTRITION disagree with TTNT, which censors the same patient,
    -- and with S_SOC, which drops the same line.
    SELECT s.PATID, p.COHORT, s.LOT_NUM,
           CASE WHEN s.NEXT_LOT_START_DT IS NOT NULL
                 AND s.NEXT_LOT_START_DT <= p.FU_END
                THEN s.NEXT_LOT_START_DT END AS NEXT_LOT_START_DT,
           -- A discontinuation after follow-up is not an observed
           -- discontinuation either.
           CASE WHEN s.IS_PROTOCOL_DISCON = 1
                 AND coalesce(s.PROTOCOL_DISCON_DT, s.LOT_BASE_END_DT) <= p.FU_END
                THEN 1 ELSE 0 END AS IS_PROTOCOL_DISCON,
           p.FU_END,
           CASE WHEN c.DEATH_DT IS NOT NULL AND c.DEATH_DT <= p.FU_END
                 AND (s.NEXT_LOT_START_DT IS NULL
                      OR s.NEXT_LOT_START_DT > p.FU_END
                      OR c.DEATH_DT < s.NEXT_LOT_START_DT)
                THEN 1 ELSE 0 END AS DIED_ON_LINE
    FROM %s s
    INNER JOIN %s p ON p.PATID = s.PATID AND p.COHORT = '%s'
    INNER JOIN %s c ON c.PATID = s.PATID
    WHERE s.LOT_NUM >= p.LOT_NUM AND s.LOT_START_DT <= p.FU_END",
    wrk("S_SPINE"), wrk("S_PERIODS"), cohort$key, input_cohort_tbl()))

  prepare_table(con, wrk("S_PATTERNS"),
    "COHORT string, LOT_NUM int, SOC_CATEGORY string,
     N_PATIENTS int, N_DENOM int, PCT double", cohort$key)
  run_step(con, paste0("patterns_", cohort$key), sprintf("
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

  prepare_table(con, wrk("S_SWITCH"),
    "COHORT string, FROM_LOT int, TO_LOT int, FROM_CATEGORY string,
     TO_CATEGORY string, N_PATIENTS int", cohort$key)
  run_step(con, paste0("switch_", cohort$key), sprintf("
    INSERT INTO %1$s
    SELECT a.COHORT, a.LOT_NUM AS FROM_LOT, b.LOT_NUM AS TO_LOT,
           a.SOC_CATEGORY AS FROM_CATEGORY,
           -- A patient with no next line is an edge to a terminal node, not a
           -- missing row: the Sankey has to account for everyone who entered.
           coalesce(b.SOC_CATEGORY,
             CASE WHEN e.DIED_ON_LINE = 1 THEN '(died)'
                  ELSE '(no further therapy)' END)
             AS TO_CATEGORY,
           count(DISTINCT a.PATID) AS N_PATIENTS
    FROM %2$s a
    LEFT JOIN %2$s b ON b.PATID = a.PATID AND b.COHORT = a.COHORT
                    AND b.LOT_NUM = a.LOT_NUM + 1
    LEFT JOIN s_line_end e ON e.PATID = a.PATID AND e.COHORT = a.COHORT
                          AND e.LOT_NUM = a.LOT_NUM
    WHERE a.COHORT = '%3$s' AND a.LOT_NUM < %4$d
    GROUP BY a.COHORT, a.LOT_NUM, b.LOT_NUM, a.SOC_CATEGORY, b.SOC_CATEGORY,
             e.DIED_ON_LINE",
    wrk("S_SWITCH"), wrk("S_SOC"), cohort$key, as.integer(cfg$max_lot)),
    qc = sprintf("SELECT count(*) AS n_edges FROM %s WHERE COHORT='%s'",
                 wrk("S_SWITCH"), cohort$key))

  prepare_table(con, wrk("S_TX_ATTRITION"),
    "COHORT string, LOT_NUM int, SOC_CATEGORY string, AGE_BAND string,
     OUTCOME string, N_PATIENTS int, N_DENOM int, PCT double", cohort$key)
  # The line as a whole, then each regimen category. The denominator and the
  # percentage are the pass's own: within a category they are out of that
  # category, which is what a column headed by one asks for.
  for (sp in stratum_passes(cfg, "e")) {
    run_step(con, paste0("tx_attrition_", cohort$key, "_", sp$key), sprintf("
    INSERT INTO %1$s
    WITH cat AS (
      SELECT e.COHORT, e.LOT_NUM, e.PATID, %3$s,
             CASE
               WHEN e.NEXT_LOT_START_DT IS NOT NULL THEN 'received_next_lot'
               WHEN e.DIED_ON_LINE = 1              THEN 'died'
               WHEN e.IS_PROTOCOL_DISCON = 1        THEN 'discontinued_no_further'
               ELSE 'lost_to_followup'
             END AS OUTCOME
      FROM s_line_end e
      %4$s
      WHERE e.COHORT = '%2$s'
    )
    SELECT COHORT, LOT_NUM, SOC_CATEGORY, AGE_BAND, OUTCOME,
           count(*) AS N_PATIENTS,
           sum(count(*)) OVER (PARTITION BY COHORT, LOT_NUM, SOC_CATEGORY,
                                            AGE_BAND) AS N_DENOM,
           round(100.0 * count(*) /
                 sum(count(*)) OVER (PARTITION BY COHORT, LOT_NUM,
                                     SOC_CATEGORY, AGE_BAND), 1) AS PCT
    FROM cat GROUP BY COHORT, LOT_NUM, SOC_CATEGORY, AGE_BAND, OUTCOME",
    wrk("S_TX_ATTRITION"), cohort$key, sp$cols, sp$join),
    qc = sprintf("SELECT count(*) AS n_rows FROM %s WHERE COHORT='%s'",
                 wrk("S_TX_ATTRITION"), cohort$key))
  }

  # The four categories partition the denominator. Checked rather than
  # asserted, because a CASE that stops partitioning is a silent double count.
  chk <- db_q(con, sprintf(
    "SELECT LOT_NUM, SOC_CATEGORY, AGE_BAND, sum(N_PATIENTS) AS parts,
            max(N_DENOM) AS whole
     FROM %s WHERE COHORT='%s' GROUP BY LOT_NUM, SOC_CATEGORY, AGE_BAND",
    wrk("S_TX_ATTRITION"), cohort$key))
  bad <- chk[chk$parts != chk$whole, , drop = FALSE]
  if (nrow(bad))
    stop("PATTERNS ERROR: the attrition categories do not sum to the ",
         "denominator for line(s) ", paste(bad$LOT_NUM, collapse = ", "),
         " of ", cohort$key, ". They are meant to partition it.", call. = FALSE)

  # And each stratification partitions the line. This is the claim the whole
  # thing rests on - a stratum's rows and the line's own row are the same
  # patients counted two ways - so it is checked here rather than assumed
  # wherever the two are read together. Checked on every stratification the run
  # wrote, one at a time, because they are margins: a by-age row carries the
  # total label in the category column and the other way round.
  for (nm in names(STRATUM_TOTALS)) {
    if (identical(nm, "SOC_CATEGORY") && !soc_stratified(cfg)) next
    if (identical(nm, "AGE_BAND") && !age_stratified(cfg)) next
    others <- setdiff(names(STRATUM_TOTALS), nm)
    only_this <- paste(sprintf("%s = '%s'", others, STRATUM_TOTALS[others]),
                       collapse = " AND ")
    part <- db_q(con, sprintf(
      "SELECT LOT_NUM, OUTCOME,
              sum(CASE WHEN %4$s = '%3$s' THEN 0 ELSE N_PATIENTS END) AS parts,
              max(CASE WHEN %4$s = '%3$s' THEN N_PATIENTS END) AS whole
       FROM %1$s WHERE COHORT='%2$s' AND %5$s GROUP BY LOT_NUM, OUTCOME",
      wrk("S_TX_ATTRITION"), cohort$key, STRATUM_TOTALS[[nm]], nm, only_this))
    off <- part[!is.na(part$whole) & part$parts != part$whole, , drop = FALSE]
    if (nrow(off))
      stop("PATTERNS ERROR: the ", nm, " strata do not sum to the line for ",
           nrow(off), " outcome(s) of ", cohort$key,
           ", so a stratum column and the line's own column would disagree. ",
           "Every line the spine carries needs exactly one row to take ", nm,
           " from.", call. = FALSE)
  }
}
