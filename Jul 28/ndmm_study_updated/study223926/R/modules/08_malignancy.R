# Secondary malignancies - Primary Objective 3.
#
# Table 4: "Occurrence of malignancy to be confirmed through the presence of at
# least 2 diagnosis codes occurring on separate dates. The date of the first
# ICD code will be used." So a single code is not an occurrence, and the date
# is the FIRST of the confirming pair, not the second - which puts the event
# earlier than the confirmation, and is what makes the time-to-malignancy
# figures shorter than a confirmation-dated version would give.
#
# s7.8.1 also splits the two cohorts:
#   1L nested - prior malignancy is excluded by X2, so incidence only
#   2L (secondary) - prior malignancy is permitted, so prevalence AND incidence
# That split is read off the cohort's own criteria rather than hard-coded, so
# it follows SEC2L_APPLY_OTHER_CANCER.
mod_malignancy <- function(con, cfg, cohort) {
  cl <- load_codelist("secondary_malig.csv", cfg)
  reg <- register_codelist_view(con, cl, "S_CL_MALIG",
    cols = c("category", "subtype", "code_type", "code", "icd_family"))

  run_step(con, paste0("malignancy_", cohort$key), sprintf("
    CREATE TABLE IF NOT EXISTS %1$s (
      PATID string, COHORT string, CATEGORY string, SUBTYPE string,
      FIRST_DT date, CONFIRM_DT date, N_DATES int,
      LOT_AFTER_WHICH int, MONTHS_FROM_DX double, MONTHS_FROM_INDEX double);
    INSERT INTO %1$s
    WITH dates AS (
      SELECT DISTINCT p.PATID, p.COHORT, cl.category, cl.subtype,
                      cast(d.FST_DT as date) AS EVENT_DT
      FROM %2$s p
      INNER JOIN %3$s d ON cast(d.PATID as string) = p.PATID
      INNER JOIN %4$s cl
             ON upper(regexp_replace(d.DIAG, '[^A-Za-z0-9]', '')) = cl.code_norm
            AND cl.icd_norm = %5$s
      WHERE p.COHORT = '%6$s' AND d.FST_DT IS NOT NULL
    ),
    confirmed AS (
      SELECT PATID, COHORT, category, subtype,
             min(EVENT_DT) AS FIRST_DT,
             min(CASE WHEN rn = 2 THEN EVENT_DT END) AS CONFIRM_DT,
             count(*) AS N_DATES
      FROM (SELECT *, row_number() OVER (PARTITION BY PATID, COHORT, category,
                                                      subtype
                                         ORDER BY EVENT_DT) AS rn
            FROM dates) t
      GROUP BY PATID, COHORT, category, subtype
      HAVING count(*) >= 2
    )
    SELECT c.PATID, c.COHORT, c.category, c.subtype, c.FIRST_DT, c.CONFIRM_DT,
           c.N_DATES,
           (SELECT max(l.LOT_NUM) FROM %7$s l
             WHERE l.PATID = c.PATID AND l.LOT_START_DT <= c.FIRST_DT)
             AS LOT_AFTER_WHICH,
           %8$s AS MONTHS_FROM_DX,
           %9$s AS MONTHS_FROM_INDEX
    FROM confirmed c
    INNER JOIN %2$s p ON p.PATID = c.PATID AND p.COHORT = c.COHORT
    INNER JOIN %10$s co ON co.PATID = c.PATID",
    wrk("S_MALIGNANCY"), wrk("S_PERIODS"), cdm_src("diagnosis"), reg,
    icd_family_sql("d.ICD_FLAG"), cohort$key, wrk("S_SPINE"),
    # Table 4: diagnosis date (included) until the malignancy date (included).
    days_to_months_sql(interval_days_sql("co.MM_DX_DT", "c.FIRST_DT", TRUE, TRUE)),
    days_to_months_sql(interval_days_sql("p.INDEX_DATE", "c.FIRST_DT", TRUE, TRUE)),
    cfg$input_cohort_table),
    qc = sprintf("SELECT count(*) AS n_rows, count(DISTINCT PATID) AS n_pat
                  FROM %s WHERE COHORT='%s'", wrk("S_MALIGNANCY"), cohort$key),
    allow_empty = TRUE)

  # Malignancies are on the s7.8.1 chronic list, so incidence counts the first
  # occurrence only and a patient with one before the period is not at risk.
  # Prevalence is reported only for a cohort whose criteria permit a prior
  # malignancy - for the others it would be zero by construction, which is not
  # a finding.
  reports_prevalence <- !("X2_other_cancer" %in% cohort$criteria)
  run_step(con, paste0("malignancy_rates_", cohort$key), sprintf("
    CREATE TABLE IF NOT EXISTS %1$s (
      COHORT string, LOT_NUM int, PERIOD string, CATEGORY string,
      N_PATIENTS int, PERSON_YEARS double, RATE double);
    INSERT INTO %1$s
    SELECT p.COHORT, p.LOT_NUM, 'TREATMENT' AS PERIOD, m.CATEGORY,
           count(DISTINCT m.PATID) AS N_PATIENTS,
           max(den.PY) AS PERSON_YEARS,
           %2$s AS RATE
    FROM %3$s m
    INNER JOIN %4$s p ON p.PATID = m.PATID AND p.COHORT = m.COHORT
    CROSS JOIN (SELECT sum(PERIOD_PY) AS PY FROM %4$s WHERE COHORT='%5$s') den
    WHERE p.COHORT = '%5$s'
      AND m.FIRST_DT BETWEEN p.PERIOD_START AND p.PERIOD_END
    GROUP BY p.COHORT, p.LOT_NUM, m.CATEGORY",
    wrk("S_MALIGNANCY_RATES"),
    rate_sql("count(DISTINCT m.PATID)", "max(den.PY)", cfg),
    wrk("S_MALIGNANCY"), wrk("S_LOT_PERIODS"), cohort$key),
    qc = sprintf("SELECT count(*) AS n_rows FROM %s WHERE COHORT='%s'",
                 wrk("S_MALIGNANCY_RATES"), cohort$key),
    allow_empty = TRUE)

  if (reports_prevalence) {
    db_exec(con, sprintf("
      INSERT INTO %1$s
      SELECT p.COHORT, p.LOT_NUM, 'BASELINE' AS PERIOD, m.CATEGORY,
             count(DISTINCT m.PATID), max(den.PY), %2$s
      FROM %3$s m
      INNER JOIN %4$s p ON p.PATID = m.PATID AND p.COHORT = m.COHORT
      CROSS JOIN (SELECT sum(BASELINE_PY) AS PY FROM %4$s WHERE COHORT='%5$s') den
      WHERE p.COHORT = '%5$s'
        AND m.FIRST_DT BETWEEN p.BASELINE_START AND p.BASELINE_END
      GROUP BY p.COHORT, p.LOT_NUM, m.CATEGORY",
      wrk("S_MALIGNANCY_RATES"),
      rate_sql("count(DISTINCT m.PATID)", "max(den.PY)", cfg),
      wrk("S_MALIGNANCY"), wrk("S_PERIODS"), cohort$key))
    log_msg("  ", cohort$key, " permits a prior malignancy, so baseline ",
            "prevalence is reported alongside incidence (s7.8.1).")
  } else {
    log_msg("  ", cohort$key, " excludes a prior malignancy (X2), so no ",
            "baseline prevalence is reported - it would be zero by ",
            "construction (s7.8.1).")
  }
}
