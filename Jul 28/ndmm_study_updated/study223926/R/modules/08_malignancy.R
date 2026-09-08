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

  prepare_table(con, wrk("S_MALIGNANCY"),
    "PATID string, COHORT string, CATEGORY string, SUBTYPE string,
     FIRST_DT date, CONFIRM_DT date, N_DATES int,
     LOT_AFTER_WHICH int, MONTHS_FROM_DX double, MONTHS_FROM_INDEX double",
    cohort$key)
  prepare_table(con, wrk("S_MALIGNANCY_RATES"),
    "COHORT string, LOT_NUM int, PERIOD string, CATEGORY string,
     N_PATIENTS int, PERSON_YEARS double, RATE double", cohort$key)
  run_step(con, paste0("malignancy_", cohort$key), sprintf("
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
        -- Bounded by this cohort's own observation. Unbounded, a second
        -- diagnosis after disenrollment, after death, or in a later enrolment
        -- span confirmed an earlier event retrospectively - the study would be
        -- reporting an occurrence it did not observe. FU_END is per patient
        -- and per cohort, so the same malignancy can be confirmed for a later
        -- cohort that did observe it and not for an earlier one that did not.
        AND cast(d.FST_DT as date) <= p.FU_END
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
    ),
    -- The line the malignancy fell after, as a join rather than a correlated
    -- scalar subquery: Spark rejects a correlation on a non-equality
    -- predicate, and LOT_START_DT <= FIRST_DT is one.
    lot_after AS (
      SELECT c.PATID, c.COHORT, c.category, c.subtype,
             max(l.LOT_NUM) AS LOT_AFTER_WHICH
      FROM confirmed c
      LEFT JOIN %7$s l
             ON l.PATID = c.PATID AND l.LOT_START_DT <= c.FIRST_DT
      GROUP BY c.PATID, c.COHORT, c.category, c.subtype
    )
    SELECT c.PATID, c.COHORT, c.category, c.subtype, c.FIRST_DT, c.CONFIRM_DT,
           c.N_DATES, la.LOT_AFTER_WHICH,
           %8$s AS MONTHS_FROM_DX,
           %9$s AS MONTHS_FROM_INDEX
    FROM confirmed c
    INNER JOIN lot_after la ON la.PATID = c.PATID AND la.COHORT = c.COHORT
                           AND la.category = c.category
                           AND la.subtype <=> c.subtype
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

  # Every qualifying diagnosis DATE for a confirmed category, not just the
  # first. Baseline prevalence needs it: a cancer first coded years before
  # baseline and coded again during it IS present during baseline, and asking
  # whether the GLOBAL first date falls in the window answers a different
  # question - new onset - and returns zero for exactly the established
  # malignancies the secondary 2L cohort exists to describe.
  db_exec(con, sprintf("
    CREATE OR REPLACE TABLE %1$s AS
    SELECT DISTINCT p.PATID, p.COHORT, cl.category AS CATEGORY,
                    cast(d.FST_DT as date) AS EVENT_DT
    FROM %2$s p
    INNER JOIN %3$s d ON cast(d.PATID as string) = p.PATID
    INNER JOIN %4$s cl
           ON upper(regexp_replace(d.DIAG, '[^A-Za-z0-9]', '')) = cl.code_norm
          AND cl.icd_norm = %5$s
    INNER JOIN %6$s m ON m.PATID = p.PATID AND m.COHORT = p.COHORT
                     AND m.CATEGORY = cl.category
    WHERE p.COHORT = '%7$s' AND d.FST_DT IS NOT NULL
      AND cast(d.FST_DT as date) <= p.FU_END",
    wrk("S_MALIGNANCY_DATES"), wrk("S_PERIODS"), cdm_src("diagnosis"), reg,
    icd_family_sql("d.ICD_FLAG"), wrk("S_MALIGNANCY"), cohort$key))

  # Malignancies are on the s7.8.1 chronic list, so incidence counts the first
  # occurrence only and a patient with one before the period is not at risk.
  # Prevalence is reported only for a cohort whose criteria permit a prior
  # malignancy - for the others it would be zero by construction, which is not
  # a finding.
  # Malignancy is on the s7.8.1 chronic list, so a patient with one BEFORE the
  # treatment period is not at risk and leaves both the numerator and the
  # person-time denominator. This is Primary Objective 3's own rule and the
  # module used to state it in a comment without applying it.
  db_exec(con, sprintf("
    CREATE OR REPLACE TEMPORARY VIEW s_malig_prior AS
    SELECT DISTINCT p.PATID, p.COHORT, p.LOT_NUM, m.CATEGORY
    FROM %s p
    INNER JOIN %s m ON m.PATID = p.PATID AND m.COHORT = p.COHORT
    WHERE p.COHORT = '%s' AND m.FIRST_DT < p.PERIOD_START",
    wrk("S_LOT_PERIODS"), wrk("S_MALIGNANCY"), cohort$key))

  # X2 reaches 2L and 3L through the cohort they are nested in, so the test
  # walks the chain rather than reading this cohort's own list.
  reports_prevalence <- !cohort_applies(cohort, "X2_other_cancer")

  run_step(con, paste0("malignancy_rates_", cohort$key), sprintf("
    INSERT INTO %1$s
    WITH cats AS (SELECT DISTINCT category FROM %6$s),
    den AS (
      SELECT p.COHORT, p.LOT_NUM, c.category,
             sum(CASE WHEN h.PATID IS NOT NULL THEN 0 ELSE p.PERIOD_PY END) AS PY
      FROM %4$s p
      CROSS JOIN cats c
      LEFT JOIN s_malig_prior h
             ON h.PATID = p.PATID AND h.COHORT = p.COHORT
            AND h.LOT_NUM = p.LOT_NUM AND h.CATEGORY = c.category
      WHERE p.COHORT = '%5$s' AND p.PERIOD_PY IS NOT NULL
      GROUP BY p.COHORT, p.LOT_NUM, c.category
    ),
    num AS (
      SELECT p.COHORT, p.LOT_NUM, m.CATEGORY,
             count(DISTINCT m.PATID) AS N_PATIENTS
      FROM %3$s m
      INNER JOIN %4$s p ON p.PATID = m.PATID AND p.COHORT = m.COHORT
      LEFT JOIN s_malig_prior h
             ON h.PATID = m.PATID AND h.COHORT = p.COHORT
            AND h.LOT_NUM = p.LOT_NUM AND h.CATEGORY = m.CATEGORY
      WHERE p.COHORT = '%5$s' AND h.PATID IS NULL
        AND m.FIRST_DT BETWEEN p.PERIOD_START AND p.PERIOD_END
      GROUP BY p.COHORT, p.LOT_NUM, m.CATEGORY
    )
    SELECT den.COHORT, den.LOT_NUM, 'TREATMENT' AS PERIOD, den.category,
           coalesce(num.N_PATIENTS, 0) AS N_PATIENTS, den.PY AS PERSON_YEARS,
           %2$s AS RATE
    FROM den
    LEFT JOIN num ON num.COHORT = den.COHORT AND num.LOT_NUM = den.LOT_NUM
                 AND num.CATEGORY = den.category",
    wrk("S_MALIGNANCY_RATES"),
    rate_sql("coalesce(num.N_PATIENTS, 0)", "den.PY", cfg),
    wrk("S_MALIGNANCY"), wrk("S_LOT_PERIODS"), cohort$key, "S_CL_MALIG"),
    qc = sprintf("SELECT count(*) AS n_rows FROM %s WHERE COHORT='%s'",
                 wrk("S_MALIGNANCY_RATES"), cohort$key),
    allow_empty = TRUE)

  if (reports_prevalence) {
    # Driven from the denominator crossed with the category list, like the
    # incidence block above and for the same reason: a category with no
    # baseline events produced no row at all, and downstream that is
    # indistinguishable from the module not having run for it.
    run_step(con, paste0("malignancy_prevalence_", cohort$key), sprintf("
      INSERT INTO %1$s
      WITH cats AS (SELECT DISTINCT category FROM %6$s),
      den AS (
        SELECT COHORT, LOT_NUM, sum(BASELINE_PY) AS PY
        FROM %4$s WHERE COHORT = '%5$s' GROUP BY COHORT, LOT_NUM
      ),
      num AS (
        -- ANY qualifying date inside the baseline window, not the global first
        -- one. s7.8.1 baseline is prevalence - what is PRESENT - and it is
        -- taken irrespective of prior event history, so a malignancy first
        -- coded before baseline and coded again during it belongs here.
        SELECT p.COHORT, p.LOT_NUM, m.CATEGORY,
               count(DISTINCT m.PATID) AS N_PATIENTS
        FROM %7$s m
        INNER JOIN %4$s p ON p.PATID = m.PATID AND p.COHORT = m.COHORT
        WHERE p.COHORT = '%5$s'
          AND m.EVENT_DT BETWEEN p.BASELINE_START AND p.BASELINE_END
        GROUP BY p.COHORT, p.LOT_NUM, m.CATEGORY
      )
      SELECT den.COHORT, den.LOT_NUM, 'BASELINE' AS PERIOD, cats.category,
             coalesce(num.N_PATIENTS, 0), den.PY, %2$s
      FROM den
      CROSS JOIN cats
      LEFT JOIN num ON num.COHORT = den.COHORT AND num.LOT_NUM = den.LOT_NUM
                   AND num.CATEGORY = cats.category",
      wrk("S_MALIGNANCY_RATES"),
      rate_sql("coalesce(num.N_PATIENTS, 0)", "den.PY", cfg),
      wrk("S_MALIGNANCY"), wrk("S_PERIODS"), cohort$key, "S_CL_MALIG",
      wrk("S_MALIGNANCY_DATES")),
      qc = sprintf("SELECT count(*) AS n_rows FROM %s
                    WHERE COHORT='%s' AND PERIOD='BASELINE'",
                   wrk("S_MALIGNANCY_RATES"), cohort$key))
    log_msg("  ", cohort$key, " permits a prior malignancy, so baseline ",
            "prevalence is reported alongside incidence (s7.8.1).")
  } else {
    log_msg("  ", cohort$key, " excludes a prior malignancy (X2), so no ",
            "baseline prevalence is reported - it would be zero by ",
            "construction (s7.8.1).")
  }
}
