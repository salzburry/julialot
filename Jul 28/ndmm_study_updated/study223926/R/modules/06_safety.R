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
  # Table 3 types two conditions "Acute or chronic" and "Acute/Chronic", and a
  # LIKE test for either word matches both - so those conditions would be
  # counted through the acute washout chain AND as a chronic first occurrence,
  # and their incidence would be the sum of two different rules. Resolved to
  # one value per row before any of it reaches SQL.
  cl$acute_chronic <- canonical_acute_chronic(cl$acute_chronic, cl$condition)
  # One domain and one type per condition. The incidence denominator is built
  # per (condition, domain, type) and the numerator joins back on CONDITION
  # alone, so a condition listed under two domains would get a row per domain
  # each carrying the FULL person-time and the FULL event count - and summing
  # the table would double it.
  grp <- unique(cl[, c("condition", "domain", "acute_chronic")])
  bad <- unique(grp$condition[duplicated(grp$condition)])
  if (length(bad))
    stop("CODELIST ERROR: safety_events.csv gives more than one (domain, ",
         "acute_chronic) to: ", paste(bad, collapse = ", "),
         ".\nThe incidence denominator is per condition, domain and type and ",
         "the numerator is per condition, so such a condition is reported ",
         "twice at its full person-time. Give each condition one domain and ",
         "one type.", call. = FALSE)
  reg <- register_codelist_view(con, cl, "S_CL_SAFETY",
    cols = c("condition", "domain", "acute_chronic", "code_type", "code",
             "icd_family"))

  # Every claim of every selected patient that matches the list, collapsed to
  # one row per patient, condition and DATE - s7.8.1 rule 1.
  prepare_table(con, wrk("S_SAFETY_EVENTS"),
    "PATID string, COHORT string, CONDITION string, DOMAIN string,
     ACUTE_CHRONIC string, EVENT_DT date", cohort$key)
  prepare_table(con, wrk("S_SAFETY_RATES"),
    "COHORT string, LOT_NUM int, PERIOD string, CONDITION string,
     DOMAIN string, ACUTE_CHRONIC string, N_PATIENTS int, N_EVENTS int,
     N_AT_RISK int, PERSON_YEARS double, RATE double, RATE_LO double,
     RATE_HI double", cohort$key)
  run_step(con, paste0("safety_events_", cohort$key), sprintf("
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

  # The two periods, counted the SAME way.
  #
  # Baseline prevalence used to be a bare count(*) over every event date in the
  # window: no washout, no chronic collapse. So a patient with chronic kidney
  # disease coded at twelve visits contributed twelve events to the background
  # prevalence of a condition s7.8.1 says counts once, and the acute events had
  # no washout at baseline but did on treatment. Objective 1's prevalence and
  # Objective 2's incidence were then computed under different rules and could
  # not be compared - which is the comparison the study exists to make.
  #
  # One difference between the periods survives, and it is the protocol's:
  # the baseline denominator is the window's own person-time "irrespective of
  # prior event history" (s7.8.1), so no patient is dropped from it, and a
  # chronic condition's baseline first-occurrence counts for everyone.
  prepare_table(con, wrk("S_SAFETY_COUNTED"),
    "PATID string, COHORT string, LOT_NUM int, PERIOD string,
     CONDITION string, EVENT_DT date", cohort$key)

  db_exec(con, sprintf("
    CREATE OR REPLACE TEMPORARY VIEW s_acute_events AS
    SELECT e.PATID, e.COHORT, e.CONDITION, e.EVENT_DT
    FROM %s e WHERE e.COHORT = '%s' AND e.ACUTE_CHRONIC = 'acute'",
    wrk("S_SAFETY_EVENTS"), cohort$key))

  # Baseline is one window per patient, so it is shaped like a period table and
  # the same machinery runs over it. LOT_NUM is the cohort's own index line.
  db_exec(con, sprintf("
    CREATE OR REPLACE TEMPORARY VIEW s_periods_baseline AS
    SELECT PATID, COHORT, LOT_NUM,
           BASELINE_START AS PERIOD_START, BASELINE_END AS PERIOD_END,
           BASELINE_PY AS PERIOD_PY
    FROM %s WHERE COHORT = '%s'", wrk("S_PERIODS"), cohort$key))
  db_exec(con, sprintf("
    CREATE OR REPLACE TEMPORARY VIEW s_periods_this AS
    SELECT * FROM %s WHERE COHORT = '%s'", wrk("S_LOT_PERIODS"), cohort$key))

  # Chronic prior history, for the TREATMENT period only.
  db_exec(con, chronic_prior_history_sql(
    wrk("S_SAFETY_EVENTS"), wrk("S_LOT_PERIODS"), "s_chronic_prior"))

  chronic_sql <- function(periods, period_label, exclude_prior) {
    sprintf("
      INSERT INTO %1$s
      SELECT e.PATID, p.COHORT, p.LOT_NUM, '%5$s' AS PERIOD, e.CONDITION,
             min(e.EVENT_DT)
      FROM %2$s e
      INNER JOIN %3$s p ON p.PATID = e.PATID AND p.COHORT = e.COHORT
                       AND e.EVENT_DT BETWEEN p.PERIOD_START AND p.PERIOD_END
      %6$s
      WHERE e.COHORT = '%4$s' AND e.ACUTE_CHRONIC = 'chronic' %7$s
      GROUP BY e.PATID, p.COHORT, p.LOT_NUM, e.CONDITION",
      wrk("S_SAFETY_COUNTED"), wrk("S_SAFETY_EVENTS"), periods, cohort$key,
      period_label,
      if (exclude_prior)
        "LEFT JOIN s_chronic_prior h
                ON h.PATID = e.PATID AND h.COHORT = p.COHORT
               AND h.LOT_NUM = p.LOT_NUM AND h.CONDITION = e.CONDITION" else "",
      if (exclude_prior) "AND h.PATID IS NULL" else "")
  }

  for (per in list(
    list(label = "BASELINE",  view = "s_periods_baseline",
         exclude_prior = FALSE),
    list(label = "TREATMENT", view = "s_periods_this",
         exclude_prior = TRUE))) {
    run_acute_washout(con, "s_acute_events", per$view,
                      wrk("S_SAFETY_COUNTED"), cfg, per$label)
    db_exec(con, chronic_sql(per$view, per$label, per$exclude_prior))
  }

  # The rates, both periods, both driven from the DENOMINATOR - so a condition
  # with no events in a period gets a row saying zero rather than no row, which
  # downstream cannot be told apart from the module not having run.
  for (per in list(
    list(label = "BASELINE",  view = "s_periods_baseline",
         exclude_prior = FALSE),
    list(label = "TREATMENT", view = "s_periods_this",
         exclude_prior = TRUE))) {
    # Only the treatment denominator drops the not-at-risk; s7.8.1 says the
    # baseline one is taken irrespective of prior event history.
    py_expr <- if (per$exclude_prior)
      "sum(CASE WHEN c.ac = 'chronic' AND h.PATID IS NOT NULL
                THEN 0 ELSE p.PERIOD_PY END)" else "sum(p.PERIOD_PY)"
    at_risk_expr <- if (per$exclude_prior)
      "count(DISTINCT CASE WHEN c.ac = 'chronic' AND h.PATID IS NOT NULL
                           THEN NULL ELSE p.PATID END)" else
      "count(DISTINCT p.PATID)"
    prior_join <- if (per$exclude_prior)
      "LEFT JOIN s_chronic_prior h
              ON h.PATID = p.PATID AND h.COHORT = p.COHORT
             AND h.LOT_NUM = p.LOT_NUM AND h.CONDITION = c.condition" else ""

    run_step(con, paste0("safety_", tolower(per$label), "_", cohort$key),
      sprintf("
      INSERT INTO %1$s
      WITH cond AS (SELECT DISTINCT condition, domain, lower(acute_chronic) AS ac
                    FROM %2$s),
      den AS (
        SELECT p.COHORT, p.LOT_NUM, c.condition, c.domain, c.ac,
               %9$s AS PY, %10$s AS N_AT_RISK
        FROM %3$s p
        CROSS JOIN cond c
        %11$s
        WHERE p.PERIOD_PY IS NOT NULL
        GROUP BY p.COHORT, p.LOT_NUM, c.condition, c.domain, c.ac
      ),
      num AS (
        SELECT COHORT, LOT_NUM, CONDITION, count(*) AS N_EVENTS,
               count(DISTINCT PATID) AS N_PATIENTS
        FROM %5$s WHERE COHORT = '%4$s' AND PERIOD = '%12$s'
        GROUP BY COHORT, LOT_NUM, CONDITION
      )
      SELECT den.COHORT, den.LOT_NUM, '%12$s' AS PERIOD, den.condition,
             den.domain, den.ac,
             coalesce(num.N_PATIENTS, 0) AS N_PATIENTS,
             coalesce(num.N_EVENTS, 0) AS N_EVENTS,
             den.N_AT_RISK, den.PY AS PERSON_YEARS,
             %6$s AS RATE, %7$s AS RATE_LO, %8$s AS RATE_HI
      FROM den
      LEFT JOIN num ON num.COHORT = den.COHORT AND num.LOT_NUM = den.LOT_NUM
                   AND num.CONDITION = den.condition",
      wrk("S_SAFETY_RATES"), "S_CL_SAFETY", per$view, cohort$key,
      wrk("S_SAFETY_COUNTED"),
      rate_sql("coalesce(num.N_EVENTS, 0)", "den.PY", cfg),
      rate_ci_sql("coalesce(num.N_EVENTS, 0)", "den.PY", cfg, "lo"),
      rate_ci_sql("coalesce(num.N_EVENTS, 0)", "den.PY", cfg, "hi"),
      py_expr, at_risk_expr, prior_join, per$label),
      qc = sprintf("SELECT count(*) AS n_rows FROM %s
                    WHERE COHORT='%s' AND PERIOD='%s'",
                   wrk("S_SAFETY_RATES"), cohort$key, per$label))
  }
}
