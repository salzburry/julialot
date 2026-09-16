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

# The suffix a chronic condition's hospitalisation series carries. Figure 3's
# note: "Hospitalizations due to chronic conditions will be considered an
# acute event and can be counted more than once." So every chronic condition
# is two series - the condition itself, counted once at first instance, and
# its hospitalisations, counted through the acute washout with the whole
# period as person-time - and the second is reported under the condition's
# name with this suffix, in the same domain.
SAFETY_HOSP_SUFFIX <- " (hospitalisation)"

# The CONDITION a domain's aggregate row carries. s7.8.1: rates "calculated as
# individual conditions within categories, and aggregated" - so beside every
# condition's row there is one per domain, under this name, whose numerator is
# the domain's conditions' counted events together.
SAFETY_DOMAIN_ANY <- "(any in domain)"
# The PERIOD label on S_SAFETY_COUNTED under which the acute washout's own
# answer is kept - the distinct events of the patient's whole observed
# timeline, before any of them is attributed to a period.
SAFETY_TIMELINE_PERIOD <- "TIMELINE"

# What the safety list must satisfy beyond its shape: the protocol's chronic
# set typed chronic, each condition's setting known, one domain and one type
# per condition. The module runs it as it starts; the preflight runs it before
# the connection is opened. Returns the list with its acute/chronic types and
# settings resolved to one value per row.
#
# `setting` is optional in the file. `any` reads every diagnosis row; `inpatient`
# reads only diagnoses on a claim carrying a confinement id - business rule
# 14's definition of an inpatient record - and dates the event at the
# admission. A file without the column is `any` throughout.
check_safety_list <- function(cfg, cl = load_codelist("safety_events.csv", cfg)) {
  assert_chronic_set(cl)
  # Table 3 types two conditions "Acute or chronic" and "Acute/Chronic", and a
  # LIKE test for either word matches both - so each would be counted through
  # the acute washout chain AND as a chronic first occurrence. Resolved to one
  # value per row before any of it reaches SQL.
  cl$acute_chronic <- canonical_acute_chronic(cl$acute_chronic, cl$condition)
  cl$setting <- canonical_setting(if ("setting" %in% names(cl)) cl$setting else NULL,
                                  nrow(cl))
  # The hospitalisation series is derived under the condition's name with a
  # suffix; a condition already spelled that way would collide with it.
  clash <- unique(cl$condition[endsWith(as.character(cl$condition), SAFETY_HOSP_SUFFIX) |
                                 trimws(as.character(cl$condition)) == SAFETY_DOMAIN_ANY])
  if (length(clash))
    stop("CODELIST ERROR: safety_events.csv names ", paste(clash, collapse = ", "),
         ", and the suffix '", SAFETY_HOSP_SUFFIX, "' and the name '",
         SAFETY_DOMAIN_ANY, "' are reserved for the hospitalisation series ",
         "and the domain aggregate this module derives. Rename it.", call. = FALSE)
  # A condition whose DEFINITION is an admission. Read from every diagnosis
  # row, an outpatient claim carrying the code would satisfy `severe infection
  # resulting in hospitalization` - so a condition whose name says
  # hospitalisation has to say `inpatient`, and is then extracted from
  # inpatient claims only.
  hosp_named <- unique(trimws(as.character(cl$condition[
    grepl("hospitali[sz]", cl$condition, ignore.case = TRUE) &
      cl$setting != "inpatient"])))
  if (length(hosp_named))
    stop("SAFETY ERROR: ", paste(hosp_named, collapse = ", "),
         " is defined by an admission, but its `setting` is not `inpatient` - ",
         "so an outpatient claim carrying the code would count as the outcome. ",
         "Set setting=inpatient on its rows: the event is then a diagnosis on ",
         "a claim carrying a confinement id (business rule 14), dated at the ",
         "admission. See OPEN_QUESTIONS Q15 (Annex 3).", call. = FALSE)

  grp <- unique(cl[, c("condition", "domain", "acute_chronic", "setting")])
  bad <- unique(grp$condition[duplicated(grp$condition)])
  if (length(bad))
    stop("CODELIST ERROR: safety_events.csv gives more than one (domain, ",
         "acute_chronic, setting) to: ", paste(bad, collapse = ", "),
         ".\nThe incidence denominator is per condition, domain and type and ",
         "the numerator is per condition, so such a condition is reported ",
         "twice at its full person-time. Give each condition one domain, one ",
         "type and one setting.", call. = FALSE)
  invisible(cl)
}

# `setting`, resolved: blank or absent is `any`; anything else must be one of
# the two words, because a misspelling would silently read every row.
canonical_setting <- function(x, n) {
  v <- if (is.null(x)) rep("", n) else tolower(trimws(ifelse(is.na(x), "", as.character(x))))
  v[!nzchar(v)] <- "any"
  bad <- unique(v[!v %in% c("any", "inpatient")])
  if (length(bad))
    stop("CODELIST ERROR: safety_events.csv has setting value(s) this module ",
         "does not know: ", paste(bad, collapse = ", "),
         ". Use any (every diagnosis row) or inpatient (diagnoses on a claim ",
         "carrying a confinement id, dated at the admission), or leave it ",
         "blank for any.", call. = FALSE)
  v
}

mod_safety <- function(con, cfg, cohort) {
  cl <- load_codelist("safety_events.csv", cfg)
  cl <- check_safety_list(cfg, cl)
  reg <- register_codelist_view(con, cl, "S_CL_SAFETY",
    cols = c("condition", "domain", "acute_chronic", "setting", "code_type",
             "code", "icd_family"))

  # Every claim of every selected patient that matches the list, collapsed to
  # one row per patient, condition and DATE - s7.8.1 rule 1.
  #
  # Each row also says whether the claim was an INPATIENT one: a diagnosis on
  # a medical claim carrying a confinement id that CONFINEMENT knows, which is
  # business rule 14's definition, joined on the documented claim key. Two
  # things turn on it. A condition whose `setting` is inpatient is extracted
  # from those rows alone, dated at the admission. And every chronic
  # condition gets a second series under SAFETY_HOSP_SUFFIX - its
  # hospitalisations, one per admission, typed acute - which is Figure 3's
  # "Hospitalizations due to chronic conditions will be considered an acute
  # event and can be counted more than once".
  prepare_table(con, wrk("S_SAFETY_EVENTS"),
    "PATID string, COHORT string, CONDITION string, DOMAIN string,
     ACUTE_CHRONIC string, EVENT_DT date, INPATIENT int, ADMIT_DT date",
    cohort$key)
  prepare_table(con, wrk("S_SAFETY_RATES"),
    "COHORT string, LOT_NUM int, PERIOD string,
     SOC_CATEGORY string, AGE_GROUP string,
     CONDITION string, DOMAIN string, ACUTE_CHRONIC string,
     N_PATIENTS int, N_EVENTS int,
     N_AT_RISK int, PERSON_YEARS double, RATE double, RATE_LO double,
     RATE_HI double", cohort$key)
  run_step(con, paste0("safety_events_", cohort$key), sprintf("
    INSERT INTO %1$s
    WITH raw AS (
      SELECT p.PATID, p.COHORT, cl.condition, cl.domain,
             lower(cl.acute_chronic) AS ac, lower(cl.setting) AS setting,
             cast(d.FST_DT as date) AS FST_DT,
             CASE WHEN cf.CONF_ID IS NOT NULL THEN 1 ELSE 0 END AS INPATIENT,
             cast(cf.ADMIT_DATE as date) AS ADMIT_DT
      FROM %2$s p
      INNER JOIN %3$s d ON cast(d.PATID as string) = p.PATID
      INNER JOIN %4$s cl
             ON upper(regexp_replace(d.DIAG, '[^A-Za-z0-9]', '')) = cl.code_norm
            AND cl.icd_norm = %5$s
      -- The claim the diagnosis sits on, by the FULL documented key (the
      -- Optum join diagram: PATID | PAT_PLANID, CLMID, FST_DT, LOC_CD), and
      -- only where it carries a confinement id. PAT_PLANID and LOC_CD are
      -- nullable on both sides, so they are compared null-safely.
      LEFT JOIN %7$s m
             ON cast(m.PATID as string) = cast(d.PATID as string)
            AND m.PAT_PLANID <=> d.PAT_PLANID
            AND m.CLMID = d.CLMID
            AND cast(m.FST_DT as date) = cast(d.FST_DT as date)
            AND m.LOC_CD <=> d.LOC_CD
            AND m.CONF_ID IS NOT NULL AND trim(m.CONF_ID) <> ''
      -- ...and the stay it belongs to, which is where the admission date is.
      LEFT JOIN %8$s cf
             ON cast(cf.PATID as string) = cast(m.PATID as string)
            AND cf.CONF_ID = m.CONF_ID
            AND cf.ADMIT_DATE IS NOT NULL
      WHERE p.COHORT = '%6$s' AND d.FST_DT IS NOT NULL
    )
    SELECT DISTINCT PATID, COHORT, CONDITION, DOMAIN, ACUTE_CHRONIC, EVENT_DT,
                    INPATIENT, ADMIT_DT
    FROM (
      -- The condition's own series. An inpatient-defined condition is its
      -- admissions, dated at the admit date; any other condition is every
      -- claim, dated at the claim.
      SELECT PATID, COHORT, condition AS CONDITION, domain AS DOMAIN,
             ac AS ACUTE_CHRONIC,
             CASE WHEN setting = 'inpatient' THEN ADMIT_DT ELSE FST_DT END AS EVENT_DT,
             INPATIENT, ADMIT_DT
      FROM raw
      WHERE setting = 'any' OR INPATIENT = 1
      UNION ALL
      -- A chronic condition's hospitalisations, as an acute series of their
      -- own. Not for a condition already defined by its admissions: that
      -- series would be the same rows twice.
      SELECT PATID, COHORT, concat(condition, '%9$s') AS CONDITION,
             domain AS DOMAIN, 'acute' AS ACUTE_CHRONIC,
             ADMIT_DT AS EVENT_DT, INPATIENT, ADMIT_DT
      FROM raw
      WHERE ac = 'chronic' AND setting = 'any' AND INPATIENT = 1
    ) s",
    wrk("S_SAFETY_EVENTS"), wrk("S_PERIODS"), cdm_src("diagnosis"), reg,
    icd_family_sql("d.ICD_FLAG"), cohort$key,
    cdm_src("medical"), cdm_src("confinement"), SAFETY_HOSP_SUFFIX),
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

  # DISTINCT on the date: an event table row is per claim setting as well, so
  # a code on an outpatient and an inpatient claim of one day is two rows and
  # one event - s7.8.1 rule 1.
  db_exec(con, sprintf("
    CREATE OR REPLACE TEMPORARY VIEW s_acute_events AS
    SELECT DISTINCT e.PATID, e.COHORT, e.CONDITION, e.EVENT_DT
    FROM %s e WHERE e.COHORT = '%s' AND e.ACUTE_CHRONIC = 'acute'",
    wrk("S_SAFETY_EVENTS"), cohort$key))

  # The conditions a rate row is written for: the list's own, plus the
  # hospitalisation series every chronic condition reads from every claim gets.
  # Driven from here rather than from the events, so a condition with no
  # event in a period still gets a row saying zero.
  db_exec(con, sprintf("
    CREATE OR REPLACE TEMPORARY VIEW s_safety_conditions AS
    SELECT DISTINCT condition, domain, lower(acute_chronic) AS ac FROM %1$s
    UNION ALL
    SELECT DISTINCT concat(condition, '%2$s') AS condition, domain, 'acute' AS ac
    FROM %1$s
    WHERE lower(acute_chronic) = 'chronic' AND lower(setting) = 'any'",
    reg, SAFETY_HOSP_SUFFIX))

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

  # The acute washout runs ONCE, over the patient's whole observed timeline,
  # and the events it keeps are then attributed to the periods by date.
  #
  # s7.8.1's washout is a statement about EVENTS - "a >= 30 day washout
  # between acute events of the same type" - not about periods, and run
  # period by period it forgot the boundary: an infection coded 3 days before
  # the index and again 5 days after it was a baseline event AND a new
  # incident event on treatment, and one on the last day of line 1's window
  # and again two days into line 2's was two events. Run once from the
  # cohort's baseline start to its follow-up end, an event is distinct from
  # the last counted one whichever period each falls in, and a period holds
  # the distinct events dated inside it. The chain starts at the baseline
  # start, so a baseline event is never suppressed by history before the
  # window - s7.8.1 takes the baseline "irrespective of prior event history".
  # ../OPEN_QUESTIONS.md Q34.
  #
  # The chain's own answer stays on the table under PERIOD = 'TIMELINE', so a
  # reader can see the distinct events before their attribution; the rate
  # queries read a period's label and never that one.
  db_exec(con, sprintf("
    CREATE OR REPLACE TEMPORARY VIEW s_periods_timeline AS
    SELECT PATID, COHORT, LOT_NUM,
           BASELINE_START AS PERIOD_START, FU_END AS PERIOD_END,
           cast(NULL as double) AS PERIOD_PY
    FROM %s WHERE COHORT = '%s'", wrk("S_PERIODS"), cohort$key))
  run_acute_washout(con, "s_acute_events", "s_periods_timeline",
                    wrk("S_SAFETY_COUNTED"), cfg, SAFETY_TIMELINE_PERIOD)
  for (per in list(
    list(label = "BASELINE",  view = "s_periods_baseline",
         exclude_prior = FALSE),
    list(label = "TREATMENT", view = "s_periods_this",
         exclude_prior = TRUE))) {
    db_exec(con, sprintf("
      INSERT INTO %1$s
      SELECT t.PATID, p.COHORT, p.LOT_NUM, '%4$s' AS PERIOD, t.CONDITION, t.EVENT_DT
      FROM %1$s t
      INNER JOIN %2$s p ON p.PATID = t.PATID AND p.COHORT = t.COHORT
                       AND t.EVENT_DT BETWEEN p.PERIOD_START AND p.PERIOD_END
      WHERE t.COHORT = '%3$s' AND t.PERIOD = '%5$s'",
      wrk("S_SAFETY_COUNTED"), per$view, cohort$key, per$label,
      SAFETY_TIMELINE_PERIOD))
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
      WITH cond AS (SELECT condition, domain, ac FROM %2$s),
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
             den.SOC_CATEGORY, den.AGE_GROUP,
             den.condition, den.domain, den.ac,
             coalesce(num.N_PATIENTS, 0) AS N_PATIENTS,
             coalesce(num.N_EVENTS, 0) AS N_EVENTS,
             den.N_AT_RISK, den.PY AS PERSON_YEARS,
             %6$s AS RATE, %7$s AS RATE_LO, %8$s AS RATE_HI
      FROM den
      LEFT JOIN num ON num.COHORT = den.COHORT AND num.LOT_NUM = den.LOT_NUM
                   AND num.CONDITION = den.condition
                   AND num.SOC_CATEGORY = den.SOC_CATEGORY
                   AND num.AGE_GROUP = den.AGE_GROUP",
      wrk("S_SAFETY_RATES"), "s_safety_conditions", per$view, cohort$key,
      wrk("S_SAFETY_COUNTED"),
      rate_sql("coalesce(num.N_EVENTS, 0)", "den.PY", cfg),
      rate_ci_sql("coalesce(num.N_EVENTS, 0)", "den.PY", cfg, "lo"),
      rate_ci_sql("coalesce(num.N_EVENTS, 0)", "den.PY", cfg, "hi"),
      py_expr, at_risk_expr, prior_join, per$label,
      sd$join, sd$cols, sd$group, sn$join, sn$cols, sn$group),
      qc = sprintf("SELECT count(*) AS n_rows FROM %s
                    WHERE COHORT='%s' AND PERIOD='%s'",
                   wrk("S_SAFETY_RATES"), cohort$key, per$label))

      # s7.8.1: rates "calculated as individual conditions within categories,
      # and aggregated". The aggregate over a domain, as one more row per
      # domain under SAFETY_DOMAIN_ANY: its numerator is every counted event
      # of the domain's own conditions - not the derived hospitalisation
      # series, which would count a chronic condition's admission beside its
      # first occurrence - and each patient once. On treatment a patient is at
      # risk of the aggregate while at risk of at least one condition in it,
      # and contributes the whole period: only the chronic first-occurrence
      # rule truncates at-risk time, and it truncates one condition, not the
      # domain. At baseline nobody leaves it.
      dom_py <- if (per$exclude_prior)
        "sum(CASE WHEN coalesce(hp.N_PRIOR, 0) < dm.N_COND THEN p.PERIOD_PY ELSE 0 END)"
        else "sum(p.PERIOD_PY)"
      dom_at_risk <- if (per$exclude_prior)
        "count(DISTINCT CASE WHEN coalesce(hp.N_PRIOR, 0) < dm.N_COND THEN p.PATID END)"
        else "count(DISTINCT p.PATID)"
      dom_prior <- if (per$exclude_prior) sprintf("
        LEFT JOIN (SELECT h.PATID, h.COHORT, h.LOT_NUM, cl.domain,
                          count(DISTINCT h.CONDITION) AS N_PRIOR
                   FROM s_chronic_prior h
                   INNER JOIN (SELECT DISTINCT condition, domain FROM %s) cl
                           ON cl.condition = h.CONDITION
                   GROUP BY h.PATID, h.COHORT, h.LOT_NUM, cl.domain) hp
               ON hp.PATID = p.PATID AND hp.COHORT = p.COHORT
              AND hp.LOT_NUM = p.LOT_NUM AND hp.domain = dm.domain", "S_CL_SAFETY")
        else ""
      run_step(con, paste0("safety_", tolower(per$label), "_domain_", sd$key,
                           "_", cohort$key),
      sprintf("
      INSERT INTO %1$s
      WITH doms AS (SELECT domain, count(DISTINCT condition) AS N_COND
                    FROM %2$s GROUP BY domain),
      den AS (
        SELECT p.COHORT, p.LOT_NUM, %13$s, dm.domain,
               %9$s AS PY, %10$s AS N_AT_RISK
        FROM %3$s p
        CROSS JOIN doms dm
        %11$s
        %14$s
        WHERE p.PERIOD_PY IS NOT NULL
        GROUP BY p.COHORT, p.LOT_NUM, dm.domain%15$s
      ),
      num AS (
        SELECT n.COHORT, n.LOT_NUM, %17$s, cl.domain,
               count(*) AS N_EVENTS, count(DISTINCT n.PATID) AS N_PATIENTS
        FROM %5$s n
        INNER JOIN (SELECT DISTINCT condition, domain FROM %2$s) cl
                ON cl.condition = n.CONDITION
        %16$s
        WHERE n.COHORT = '%4$s' AND n.PERIOD = '%12$s'
        GROUP BY n.COHORT, n.LOT_NUM, cl.domain%18$s
      )
      SELECT den.COHORT, den.LOT_NUM, '%12$s' AS PERIOD,
             den.SOC_CATEGORY, den.AGE_GROUP,
             '%19$s' AS CONDITION, den.domain, 'aggregate' AS ACUTE_CHRONIC,
             coalesce(num.N_PATIENTS, 0) AS N_PATIENTS,
             coalesce(num.N_EVENTS, 0) AS N_EVENTS,
             den.N_AT_RISK, den.PY AS PERSON_YEARS,
             %6$s AS RATE, %7$s AS RATE_LO, %8$s AS RATE_HI
      FROM den
      LEFT JOIN num ON num.COHORT = den.COHORT AND num.LOT_NUM = den.LOT_NUM
                   AND num.domain = den.domain
                   AND num.SOC_CATEGORY = den.SOC_CATEGORY
                   AND num.AGE_GROUP = den.AGE_GROUP",
      wrk("S_SAFETY_RATES"), "S_CL_SAFETY", per$view, cohort$key,
      wrk("S_SAFETY_COUNTED"),
      rate_sql("coalesce(num.N_EVENTS, 0)", "den.PY", cfg),
      rate_ci_sql("coalesce(num.N_EVENTS, 0)", "den.PY", cfg, "lo"),
      rate_ci_sql("coalesce(num.N_EVENTS, 0)", "den.PY", cfg, "hi"),
      dom_py, dom_at_risk, dom_prior, per$label,
      sd$cols, sd$join, sd$group, sn$join, sn$cols, sn$group,
      SAFETY_DOMAIN_ANY),
      qc = sprintf("SELECT count(*) AS n_rows FROM %s
                    WHERE COHORT='%s' AND PERIOD='%s' AND CONDITION='%s'",
                   wrk("S_SAFETY_RATES"), cohort$key, per$label,
                   SAFETY_DOMAIN_ANY))
    }
  }
}
