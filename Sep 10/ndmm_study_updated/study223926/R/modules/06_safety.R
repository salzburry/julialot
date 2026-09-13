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

# What the safety list must satisfy beyond its shape: the protocol's chronic
# set typed chronic, no condition defined by an admission, one domain and one
# type per condition. The module runs it as it starts; the preflight runs it
# before the connection is opened. Returns the list with its acute/chronic
# types resolved to one value per row.
check_safety_list <- function(cfg, cl = load_codelist("safety_events.csv", cfg)) {
  assert_chronic_set(cl)
  # Table 3 types two conditions "Acute or chronic" and "Acute/Chronic", and a
  # LIKE test for either word matches both - so each would be counted through
  # the acute washout chain AND as a chronic first occurrence. Resolved to one
  # value per row before any of it reaches SQL.
  cl$acute_chronic <- canonical_acute_chronic(cl$acute_chronic, cl$condition)
  # A condition whose DEFINITION needs more than a code. Every condition here
  # is extracted from diagnosis rows alone, so an outpatient code would satisfy
  # `severe infection resulting in hospitalization`. That needs an admission
  # linkage this module does not implement, so a condition whose name says
  # hospitalisation stops the run.
  hosp_named <- unique(trimws(as.character(
    cl$condition[grepl("hospitali[sz]", cl$condition, ignore.case = TRUE)])))
  if (length(hosp_named))
    stop("SAFETY ERROR: ", paste(hosp_named, collapse = ", "),
         " is defined by an admission, and this module extracts every ",
         "condition from diagnosis rows alone - so an outpatient claim ",
         "carrying the code would count as the outcome. The endpoint needs a ",
         "CONFINEMENT or inpatient-claim linkage before it can be reported. ",
         "Remove the row to run the other conditions, or supply the ",
         "phenotype. See OPEN_QUESTIONS Q15 (Annex 3).", call. = FALSE)

  grp <- unique(cl[, c("condition", "domain", "acute_chronic")])
  bad <- unique(grp$condition[duplicated(grp$condition)])
  if (length(bad))
    stop("CODELIST ERROR: safety_events.csv gives more than one (domain, ",
         "acute_chronic) to: ", paste(bad, collapse = ", "),
         ".\nThe incidence denominator is per condition, domain and type and ",
         "the numerator is per condition, so such a condition is reported ",
         "twice at its full person-time. Give each condition one domain and ",
         "one type.", call. = FALSE)
  invisible(cl)
}

mod_safety <- function(con, cfg, cohort) {
  cl <- load_codelist("safety_events.csv", cfg)
  cl <- check_safety_list(cfg, cl)
  reg <- register_codelist_view(con, cl, "S_CL_SAFETY",
    cols = c("condition", "domain", "acute_chronic", "code_type", "code",
             "icd_family"))

  # Every claim of every selected patient that matches the list, collapsed to
  # one row per patient, condition and DATE - s7.8.1 rule 1.
  prepare_table(con, wrk("S_SAFETY_EVENTS"),
    "PATID string, COHORT string, CONDITION string, DOMAIN string,
     ACUTE_CHRONIC string, EVENT_DT date", cohort$key)
  prepare_table(con, wrk("S_SAFETY_RATES"),
    "COHORT string, LOT_NUM int, PERIOD string,
     SOC_CATEGORY string, AGE_BAND string,
     CONDITION string, DOMAIN string, ACUTE_CHRONIC string,
     N_PATIENTS int, N_EVENTS int,
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
    # A cohort with no safety event at all is a valid study result. The rates
    # below are driven from the DENOMINATOR, so every condition still gets a
    # row saying zero; the guard that matters is on the denominator, which
    # cannot legitimately be empty.
    allow_empty = TRUE,
    qc = sprintf("SELECT count(*) AS n_events,
                         count(DISTINCT CONDITION) AS n_conditions
                  FROM %s WHERE COHORT = '%s'",
                 wrk("S_SAFETY_EVENTS"), cohort$key))

  # The two periods, counted the SAME way: both run the same washout and
  # chronic-collapse machinery, because Objective 1's prevalence and Objective
  # 2's incidence have to be comparable. One protocol difference survives - the
  # baseline denominator is the window's own person-time "irrespective of prior
  # event history", so nobody is dropped from it.
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
    # Only the treatment denominator drops the not-at-risk; s7.8.1 takes the
    # baseline one irrespective of prior event history.
    #
    # A chronic condition counts ONCE, at first instance, so a patient who has
    # that event stops being at risk and the denominator ends with them: at-risk
    # time runs to the earlier of the first counted event and the period end.
    py_expr <- if (per$exclude_prior)
      sprintf("sum(CASE
                     WHEN c.ac = 'chronic' AND h.PATID IS NOT NULL THEN 0
                     WHEN c.ac = 'chronic' AND fc.FIRST_DT IS NOT NULL
                       THEN %s
                     ELSE p.PERIOD_PY END)",
              person_years_sql("p.PERIOD_START",
                               "least(fc.FIRST_DT, p.PERIOD_END)", cfg))
      else "sum(p.PERIOD_PY)"
    at_risk_expr <- if (per$exclude_prior)
      "count(DISTINCT CASE WHEN c.ac = 'chronic' AND h.PATID IS NOT NULL
                           THEN NULL ELSE p.PATID END)" else
      "count(DISTINCT p.PATID)"
    prior_join <- if (per$exclude_prior)
      sprintf("LEFT JOIN s_chronic_prior h
              ON h.PATID = p.PATID AND h.COHORT = p.COHORT
             AND h.LOT_NUM = p.LOT_NUM AND h.CONDITION = c.condition
       LEFT JOIN (SELECT PATID, COHORT, LOT_NUM, CONDITION,
                         min(EVENT_DT) AS FIRST_DT
                  FROM %s WHERE COHORT = '%s' AND PERIOD = '%s'
                  GROUP BY PATID, COHORT, LOT_NUM, CONDITION) fc
              ON fc.PATID = p.PATID AND fc.COHORT = p.COHORT
             AND fc.LOT_NUM = p.LOT_NUM AND fc.CONDITION = c.condition",
              wrk("S_SAFETY_COUNTED"), cohort$key, per$label) else ""

    # Once for the line as a whole, then once per regimen category where the
    # soc module ran. The query is the same both times - one more column in
    # the GROUP BY - so a category's person-time, washout and interval are the
    # line's own arithmetic over a subset of its patients.
    den_pass <- stratum_passes(cfg, "p")
    num_pass <- stratum_passes(cfg, "n")
    for (si in seq_along(den_pass)) {
      sd <- den_pass[[si]]; sn <- num_pass[[si]]
      run_step(con, paste0("safety_", tolower(per$label), "_", sd$key, "_",
                           cohort$key),
      sprintf("
      INSERT INTO %1$s
      WITH cond AS (SELECT DISTINCT condition, domain, lower(acute_chronic) AS ac
                    FROM %2$s),
      den AS (
        SELECT p.COHORT, p.LOT_NUM, %14$s,
               c.condition, c.domain, c.ac,
               %9$s AS PY, %10$s AS N_AT_RISK
        FROM %3$s p
        CROSS JOIN cond c
        %11$s
        %13$s
        WHERE p.PERIOD_PY IS NOT NULL
        GROUP BY p.COHORT, p.LOT_NUM, c.condition, c.domain, c.ac%15$s
      ),
      num AS (
        SELECT n.COHORT, n.LOT_NUM, %17$s, n.CONDITION,
               count(*) AS N_EVENTS, count(DISTINCT n.PATID) AS N_PATIENTS
        FROM %5$s n
        %16$s
        WHERE n.COHORT = '%4$s' AND n.PERIOD = '%12$s'
        GROUP BY n.COHORT, n.LOT_NUM, n.CONDITION%18$s
      )
      SELECT den.COHORT, den.LOT_NUM, '%12$s' AS PERIOD,
             den.SOC_CATEGORY, den.AGE_BAND,
             den.condition, den.domain, den.ac,
             coalesce(num.N_PATIENTS, 0) AS N_PATIENTS,
             coalesce(num.N_EVENTS, 0) AS N_EVENTS,
             den.N_AT_RISK, den.PY AS PERSON_YEARS,
             %6$s AS RATE, %7$s AS RATE_LO, %8$s AS RATE_HI
      FROM den
      LEFT JOIN num ON num.COHORT = den.COHORT AND num.LOT_NUM = den.LOT_NUM
                   AND num.CONDITION = den.condition
                   AND num.SOC_CATEGORY = den.SOC_CATEGORY
                   AND num.AGE_BAND = den.AGE_BAND",
      wrk("S_SAFETY_RATES"), "S_CL_SAFETY", per$view, cohort$key,
      wrk("S_SAFETY_COUNTED"),
      rate_sql("coalesce(num.N_EVENTS, 0)", "den.PY", cfg),
      rate_ci_sql("coalesce(num.N_EVENTS, 0)", "den.PY", cfg, "lo"),
      rate_ci_sql("coalesce(num.N_EVENTS, 0)", "den.PY", cfg, "hi"),
      py_expr, at_risk_expr, prior_join, per$label,
      sd$join, sd$cols, sd$group, sn$join, sn$cols, sn$group),
      qc = sprintf("SELECT count(*) AS n_rows FROM %s
                    WHERE COHORT='%s' AND PERIOD='%s'",
                   wrk("S_SAFETY_RATES"), cohort$key, per$label))
    }
  }
}
