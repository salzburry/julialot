# Secondary malignancies - Primary Objective 3.
#
# Table 4: "Occurrence of malignancy to be confirmed through the presence of at
# least 2 diagnosis codes occurring on separate dates. The date of the first
# ICD code will be used." So a single code is not an occurrence, and the date
# is the FIRST of the confirming pair - which puts the event earlier than its
# confirmation and shortens every time-to-malignancy figure.
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
    "COHORT string, LOT_NUM int, PERIOD string,
     SOC_CATEGORY string, AGE_GROUP string, CATEGORY string,
     N_PATIENTS int, N_AT_RISK int, PERSON_YEARS double, RATE double", cohort$key)
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
    input_cohort_tbl()),
    qc = sprintf("SELECT count(*) AS n_rows, count(DISTINCT PATID) AS n_pat
                  FROM %s WHERE COHORT='%s'", wrk("S_MALIGNANCY"), cohort$key),
    allow_empty = TRUE)

  # Every qualifying diagnosis DATE for a confirmed category, not just the
  # first. Baseline prevalence needs it: a cancer first coded years before
  # baseline and coded again during it IS present during baseline, whereas the
  # GLOBAL first date answers a different question - new onset - and returns
  # zero for the established malignancies the secondary 2L cohort describes.
  #
  # prepare_table + INSERT, not CREATE OR REPLACE: this module runs once per
  # cohort, so replacing the whole table would leave only the last cohort's
  # rows.
  prepare_table(con, wrk("S_MALIGNANCY_DATES"),
    "PATID string, COHORT string, CATEGORY string, SUBTYPE string,
     EVENT_DT date",
    cohort$key)
  db_exec(con, sprintf("
    INSERT INTO %1$s
    SELECT DISTINCT p.PATID, p.COHORT, cl.category AS CATEGORY,
                    cl.subtype AS SUBTYPE,
                    cast(d.FST_DT as date) AS EVENT_DT
    FROM %2$s p
    INNER JOIN %3$s d ON cast(d.PATID as string) = p.PATID
    INNER JOIN %4$s cl
           ON upper(regexp_replace(d.DIAG, '[^A-Za-z0-9]', '')) = cl.code_norm
          AND cl.icd_norm = %5$s
    -- Matched on SUBTYPE as well as category, which is the grain confirmation
    -- was established at. On category alone a single baseline code of one
    -- subtype borrowed the two-date confirmation of a different subtype in the
    -- same category and was reported as baseline prevalence on its own.
    INNER JOIN %6$s m ON m.PATID = p.PATID AND m.COHORT = p.COHORT
                     AND m.CATEGORY = cl.category
                     AND m.SUBTYPE <=> cl.subtype
    WHERE p.COHORT = '%7$s' AND d.FST_DT IS NOT NULL
      AND cast(d.FST_DT as date) <= p.FU_END",
    wrk("S_MALIGNANCY_DATES"), wrk("S_PERIODS"), cdm_src("diagnosis"), reg,
    icd_family_sql("d.ICD_FLAG"), wrk("S_MALIGNANCY"), cohort$key))

  # Malignancy is on the s7.8.1 chronic list, so incidence counts the first
  # occurrence only and a patient with one BEFORE the treatment period is not
  # at risk: they leave both the numerator and the person-time denominator.
  # Prevalence is reported only for a cohort whose criteria permit a prior
  # malignancy - for the others it would be zero by construction.
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

  # The line as a whole, then each regimen category, from the same query.
  for (sp in stratum_passes(cfg, "p")) {
  run_step(con, paste0("malignancy_rates_", cohort$key, "_", sp$key), sprintf("
    INSERT INTO %1$s
    WITH cats AS (SELECT DISTINCT category FROM %6$s),
    den AS (
      -- Malignancy is on the s7.8.1 chronic list, so it is counted once at
      -- first occurrence - and a patient who has that first occurrence stops
      -- being at risk of a first one there. The denominator has to end with
      -- them, exactly as 06_safety.R does for the other chronic conditions.
      -- Summing the whole PERIOD_PY regardless kept counting time in which a
      -- first event was no longer possible, which overstates at-risk time and
      -- understates incidence.
      SELECT p.COHORT, p.LOT_NUM, %12$s, c.category,
             sum(CASE
                   WHEN h.PATID IS NOT NULL THEN 0
                   WHEN fm.FIRST_DT IS NOT NULL THEN %11$s
                   ELSE p.PERIOD_PY END) AS PY,
             count(DISTINCT CASE WHEN h.PATID IS NOT NULL THEN NULL
                                 ELSE p.PATID END) AS N_AT_RISK
      FROM %4$s p
      CROSS JOIN cats c
      LEFT JOIN (SELECT PATID, COHORT, CATEGORY, min(FIRST_DT) AS FIRST_DT
                 FROM %10$s WHERE COHORT = '%5$s'
                 GROUP BY PATID, COHORT, CATEGORY) fm
             ON fm.PATID = p.PATID AND fm.COHORT = p.COHORT
            AND fm.CATEGORY = c.category
      LEFT JOIN s_malig_prior h
             ON h.PATID = p.PATID AND h.COHORT = p.COHORT
            AND h.LOT_NUM = p.LOT_NUM AND h.CATEGORY = c.category
      %13$s
      WHERE p.COHORT = '%5$s' AND p.PERIOD_PY IS NOT NULL
      GROUP BY p.COHORT, p.LOT_NUM, c.category%14$s
    ),
    num AS (
      SELECT p.COHORT, p.LOT_NUM, %12$s, m.CATEGORY,
             count(DISTINCT m.PATID) AS N_PATIENTS
      FROM %3$s m
      INNER JOIN %4$s p ON p.PATID = m.PATID AND p.COHORT = m.COHORT
      LEFT JOIN s_malig_prior h
             ON h.PATID = m.PATID AND h.COHORT = p.COHORT
            AND h.LOT_NUM = p.LOT_NUM AND h.CATEGORY = m.CATEGORY
      %13$s
      WHERE p.COHORT = '%5$s' AND h.PATID IS NULL
        AND m.FIRST_DT BETWEEN p.PERIOD_START AND p.PERIOD_END
      GROUP BY p.COHORT, p.LOT_NUM, m.CATEGORY%14$s
    )
    SELECT den.COHORT, den.LOT_NUM, 'TREATMENT' AS PERIOD,
           den.SOC_CATEGORY, den.AGE_GROUP, den.category,
           coalesce(num.N_PATIENTS, 0) AS N_PATIENTS, den.N_AT_RISK,
           den.PY AS PERSON_YEARS, %2$s AS RATE
    FROM den
    LEFT JOIN num ON num.COHORT = den.COHORT AND num.LOT_NUM = den.LOT_NUM
                 AND num.CATEGORY = den.category
                 AND num.SOC_CATEGORY = den.SOC_CATEGORY
                 AND num.AGE_GROUP = den.AGE_GROUP",
    wrk("S_MALIGNANCY_RATES"),
    rate_sql("coalesce(num.N_PATIENTS, 0)", "den.PY", cfg),
    wrk("S_MALIGNANCY"), wrk("S_LOT_PERIODS"), cohort$key, "S_CL_MALIG",
    "", "", "", wrk("S_MALIGNANCY"),
    # At-risk time to the first confirmed occurrence, both endpoints included -
    # the same convention PERIOD_PY uses.
    person_years_sql("p.PERIOD_START", "least(fm.FIRST_DT, p.PERIOD_END)", cfg),
    sp$cols, sp$join, sp$group),
    qc = sprintf("SELECT count(*) AS n_rows FROM %s WHERE COHORT='%s'",
                 wrk("S_MALIGNANCY_RATES"), cohort$key),
    allow_empty = TRUE)
  }

  if (reports_prevalence) {
    # Driven from the denominator crossed with the category list, like the
    # incidence block above: a category with no baseline events would otherwise
    # produce no row, which downstream cannot be told from the module not
    # having run for it.
    for (sp in stratum_passes(cfg, "p")) {
    run_step(con, paste0("malignancy_prevalence_", cohort$key, "_", sp$key),
      sprintf("
      INSERT INTO %1$s
      WITH cats AS (SELECT DISTINCT category FROM %6$s),
      den AS (
        SELECT p.COHORT, p.LOT_NUM, %8$s,
               sum(p.BASELINE_PY) AS PY,
               count(DISTINCT p.PATID) AS N_AT_RISK
        FROM %4$s p
        %9$s
        WHERE p.COHORT = '%5$s' GROUP BY p.COHORT, p.LOT_NUM%10$s
      ),
      num AS (
        -- ANY qualifying date inside the baseline window, not the global first
        -- one. s7.8.1 baseline is prevalence - what is PRESENT - and it is
        -- taken irrespective of prior event history, so a malignancy first
        -- coded before baseline and coded again during it belongs here.
        SELECT p.COHORT, p.LOT_NUM, %8$s, m.CATEGORY,
               count(DISTINCT m.PATID) AS N_PATIENTS
        FROM %7$s m
        INNER JOIN %4$s p ON p.PATID = m.PATID AND p.COHORT = m.COHORT
        %9$s
        WHERE p.COHORT = '%5$s'
          AND m.EVENT_DT BETWEEN p.BASELINE_START AND p.BASELINE_END
        GROUP BY p.COHORT, p.LOT_NUM, m.CATEGORY%10$s
      )
      SELECT den.COHORT, den.LOT_NUM, 'BASELINE' AS PERIOD,
             den.SOC_CATEGORY, den.AGE_GROUP, cats.category,
             coalesce(num.N_PATIENTS, 0), den.N_AT_RISK, den.PY, %2$s
      FROM den
      CROSS JOIN cats
      LEFT JOIN num ON num.COHORT = den.COHORT AND num.LOT_NUM = den.LOT_NUM
                   AND num.CATEGORY = cats.category
                   AND num.SOC_CATEGORY = den.SOC_CATEGORY
                   AND num.AGE_GROUP = den.AGE_GROUP",
      wrk("S_MALIGNANCY_RATES"),
      rate_sql("coalesce(num.N_PATIENTS, 0)", "den.PY", cfg),
      wrk("S_MALIGNANCY"), wrk("S_PERIODS"), cohort$key, "S_CL_MALIG",
      wrk("S_MALIGNANCY_DATES"), sp$cols, sp$join, sp$group),
      qc = sprintf("SELECT count(*) AS n_rows FROM %s
                    WHERE COHORT='%s' AND PERIOD='BASELINE'",
                   wrk("S_MALIGNANCY_RATES"), cohort$key))
    }
    log_msg("  ", cohort$key, " permits a prior malignancy, so baseline ",
            "prevalence is reported alongside incidence (s7.8.1).")
  } else {
    log_msg("  ", cohort$key, " excludes a prior malignancy (X2), so no ",
            "baseline prevalence is reported - it would be zero by ",
            "construction (s7.8.1).")
  }
}
