# Key safety events: baseline prevalence (Objective 1) and on-treatment
# incidence (Objective 2).
#
# The two have DIFFERENT denominators and the difference is the whole point:
#
#   prevalence  denominator = the baseline window's own person-time, "for each
#               baseline period, IRRESPECTIVE OF PRIOR EVENT HISTORY" (s7.8.1)
#   incidence   denominator = person-time at risk in the treatment period, and
#               for a chronic condition a patient with a prior history is
#               "not considered at risk and will be excluded from BOTH the
#               numerator and the person-time denominator" (s7.8.1)
#
# The counting rules live in R/person_time.R.
mod_safety <- function(con, cfg, cohort) {
  cl <- load_codelist("safety_events.csv", cfg)
  assert_chronic_set(cl)
  reg <- register_codelist_view(con, cl, "S_CL_SAFETY",
    cols = c("condition", "domain", "acute_chronic", "code_type", "code",
             "icd_family"))

  # Every claim of every selected patient that matches the list, collapsed to
  # one row per patient, condition and DATE - s7.8.1 rule 1.
  run_step(con, paste0("safety_events_", cohort$key), sprintf("
    CREATE TABLE IF NOT EXISTS %1$s (
      PATID string, COHORT string, CONDITION string, DOMAIN string,
      ACUTE_CHRONIC string, EVENT_DT date);
    INSERT INTO %1$s
    SELECT DISTINCT p.PATID, p.COHORT, cl.condition, cl.domain,
                    lower(cl.acute_chronic) AS ACUTE_CHRONIC,
                    cast(d.FST_DT as date) AS EVENT_DT
    FROM %2$s p
    INNER JOIN %3$s d ON cast(d.PATID as string) = p.PATID
    INNER JOIN %4$s cl
           ON upper(regexp_replace(d.DIAG, '[^A-Za-z0-9]', '')) = cl.code_norm
          AND cl.icd_norm = %5$s
    WHERE p.COHORT = '%6$s' AND d.FST_DT IS NOT NULL",
    wrk("S_SAFETY_EVENTS"), wrk("S_PERIODS"), cdm_src("diagnosis"), reg,
    icd_family_sql("d.ICD_FLAG"), cohort$key),
    qc = sprintf("SELECT count(*) AS n_events,
                         count(DISTINCT CONDITION) AS n_conditions
                  FROM %s WHERE COHORT = '%s'",
                 wrk("S_SAFETY_EVENTS"), cohort$key))

  # --- baseline prevalence ------------------------------------------------
  run_step(con, paste0("safety_prevalence_", cohort$key), sprintf("
    CREATE TABLE IF NOT EXISTS %1$s (
      COHORT string, LOT_NUM int, PERIOD string, CONDITION string,
      DOMAIN string, ACUTE_CHRONIC string, N_PATIENTS int, N_EVENTS int,
      PERSON_YEARS double, RATE double, RATE_LO double, RATE_HI double);
    INSERT INTO %1$s
    SELECT p.COHORT, p.LOT_NUM, 'BASELINE' AS PERIOD, e.CONDITION, e.DOMAIN,
           e.ACUTE_CHRONIC,
           count(DISTINCT e.PATID) AS N_PATIENTS,
           count(*) AS N_EVENTS,
           max(den.PY) AS PERSON_YEARS,
           %2$s AS RATE, %3$s AS RATE_LO, %4$s AS RATE_HI
    FROM %5$s e
    INNER JOIN %6$s p ON p.PATID = e.PATID AND p.COHORT = e.COHORT
    CROSS JOIN (SELECT sum(BASELINE_PY) AS PY FROM %6$s WHERE COHORT = '%7$s') den
    WHERE p.COHORT = '%7$s'
      AND e.EVENT_DT BETWEEN p.BASELINE_START AND p.BASELINE_END
    GROUP BY p.COHORT, p.LOT_NUM, e.CONDITION, e.DOMAIN, e.ACUTE_CHRONIC",
    wrk("S_SAFETY_RATES"),
    rate_sql("count(*)", "max(den.PY)", cfg),
    rate_ci_sql("count(*)", "max(den.PY)", cfg, "lo"),
    rate_ci_sql("count(*)", "max(den.PY)", cfg, "hi"),
    wrk("S_SAFETY_EVENTS"), wrk("S_PERIODS"), cohort$key),
    qc = sprintf("SELECT count(*) AS n_rows FROM %s
                  WHERE COHORT='%s' AND PERIOD='BASELINE'",
                 wrk("S_SAFETY_RATES"), cohort$key))

  # --- on-treatment incidence --------------------------------------------
  # Chronic: patients with the condition before the treatment period leave
  # both the numerator and the denominator.
  db_exec(con, chronic_prior_history_sql(
    wrk("S_SAFETY_EVENTS"), wrk("S_LOT_PERIODS"), "s_chronic_prior"))

  # Acute events are counted through the greedy washout chain; chronic ones
  # are the first occurrence in the period, so they need no chain.
  db_exec(con, sprintf("
    CREATE TABLE IF NOT EXISTS %s
      (PATID string, COHORT string, LOT_NUM int, CONDITION string, EVENT_DT date)",
    wrk("S_SAFETY_COUNTED")))
  db_exec(con, sprintf("DELETE FROM %s WHERE COHORT = '%s'",
                       wrk("S_SAFETY_COUNTED"), cohort$key))

  db_exec(con, sprintf("
    CREATE OR REPLACE TEMPORARY VIEW s_acute_events AS
    SELECT e.PATID, e.COHORT, e.CONDITION, e.EVENT_DT
    FROM %s e WHERE e.COHORT = '%s' AND e.ACUTE_CHRONIC LIKE '%%acute%%'",
    wrk("S_SAFETY_EVENTS"), cohort$key))
  db_exec(con, sprintf("
    CREATE OR REPLACE TEMPORARY VIEW s_periods_this AS
    SELECT * FROM %s WHERE COHORT = '%s'", wrk("S_LOT_PERIODS"), cohort$key))

  run_acute_washout(con, "s_acute_events", "s_periods_this",
                    wrk("S_SAFETY_COUNTED"), cfg)

  # Chronic: one event per patient, condition and period - the first - and only
  # for patients with no prior history.
  db_exec(con, sprintf("
    INSERT INTO %1$s
    SELECT e.PATID, p.COHORT, p.LOT_NUM, e.CONDITION, min(e.EVENT_DT)
    FROM %2$s e
    INNER JOIN %3$s p ON p.PATID = e.PATID AND p.COHORT = e.COHORT
                     AND e.EVENT_DT BETWEEN p.PERIOD_START AND p.PERIOD_END
    LEFT JOIN s_chronic_prior h
           ON h.PATID = e.PATID AND h.COHORT = p.COHORT
          AND h.LOT_NUM = p.LOT_NUM AND h.CONDITION = e.CONDITION
    WHERE e.COHORT = '%4$s' AND e.ACUTE_CHRONIC LIKE '%%chronic%%'
      AND h.PATID IS NULL
    GROUP BY e.PATID, p.COHORT, p.LOT_NUM, e.CONDITION",
    wrk("S_SAFETY_COUNTED"), wrk("S_SAFETY_EVENTS"), wrk("S_LOT_PERIODS"),
    cohort$key))

  # The denominator. Acute conditions keep every patient's period person-time;
  # chronic ones drop the patients who were not at risk.
  run_step(con, paste0("safety_incidence_", cohort$key), sprintf("
    INSERT INTO %1$s
    WITH cond AS (SELECT DISTINCT condition, domain, lower(acute_chronic) AS ac
                  FROM %2$s),
    den AS (
      SELECT p.COHORT, p.LOT_NUM, c.condition, c.domain, c.ac,
             sum(CASE WHEN c.ac LIKE '%%chronic%%' AND h.PATID IS NOT NULL
                      THEN 0 ELSE p.PERIOD_PY END) AS PY,
             count(DISTINCT CASE WHEN c.ac LIKE '%%chronic%%' AND h.PATID IS NOT NULL
                                 THEN NULL ELSE p.PATID END) AS N_AT_RISK
      FROM %3$s p
      CROSS JOIN cond c
      LEFT JOIN s_chronic_prior h
             ON h.PATID = p.PATID AND h.COHORT = p.COHORT
            AND h.LOT_NUM = p.LOT_NUM AND h.CONDITION = c.condition
      WHERE p.COHORT = '%4$s' AND p.PERIOD_PY IS NOT NULL
      GROUP BY p.COHORT, p.LOT_NUM, c.condition, c.domain, c.ac
    ),
    num AS (
      SELECT COHORT, LOT_NUM, CONDITION, count(*) AS N_EVENTS,
             count(DISTINCT PATID) AS N_PATIENTS
      FROM %5$s WHERE COHORT = '%4$s'
      GROUP BY COHORT, LOT_NUM, CONDITION
    )
    SELECT den.COHORT, den.LOT_NUM, 'TREATMENT' AS PERIOD, den.condition,
           den.domain, den.ac,
           coalesce(num.N_PATIENTS, 0) AS N_PATIENTS,
           coalesce(num.N_EVENTS, 0) AS N_EVENTS,
           den.PY AS PERSON_YEARS,
           %6$s AS RATE, %7$s AS RATE_LO, %8$s AS RATE_HI
    FROM den
    LEFT JOIN num ON num.COHORT = den.COHORT AND num.LOT_NUM = den.LOT_NUM
                 AND num.CONDITION = den.condition",
    wrk("S_SAFETY_RATES"), "S_CL_SAFETY", wrk("S_LOT_PERIODS"), cohort$key,
    wrk("S_SAFETY_COUNTED"),
    rate_sql("coalesce(num.N_EVENTS, 0)", "den.PY", cfg),
    rate_ci_sql("coalesce(num.N_EVENTS, 0)", "den.PY", cfg, "lo"),
    rate_ci_sql("coalesce(num.N_EVENTS, 0)", "den.PY", cfg, "hi")),
    qc = sprintf("SELECT count(*) AS n_rows FROM %s
                  WHERE COHORT='%s' AND PERIOD='TREATMENT'",
                 wrk("S_SAFETY_RATES"), cohort$key))
}
