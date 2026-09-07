# Healthcare utilisation: hospitalisation, length of stay, emergency visits.
#
# s7.8.1 gives four rules that are easy to lose, and all four are here:
#
#   * MM-related means "a MM diagnosis in first or second position"
#   * "LOS will be computed from admit date (included) to discharge date
#     (excluded)"
#   * a hospitalisation is assigned to the period its ADMIT date falls in,
#     wherever the discharge falls
#   * one with no discharge date is counted in the patient and event counts and
#     "excluded from LOS summaries"
#
# The CDM has no ED field at all, so an ED visit is a construction and
# ED_DEFINITION says which. The three usual ones disagree materially -
# ../OPEN_QUESTIONS.md Q11.
# The three measures s7.2.4 asks for, and the event each is true of. Data
# rather than a literal repeated twice, because the rates below are driven from
# the DENOMINATOR and the measure list is what turns one line's person-time
# into one row per measure - a list that fell out of step with the map would
# silently drop a measure.
HCRU_MEASURES <- c(
  ALL_CAUSE_HOSPITALISATION  = "e.EVENT_TYPE = 'INPATIENT'",
  MM_RELATED_HOSPITALISATION = "e.EVENT_TYPE = 'INPATIENT' AND e.MM_RELATED = 1",
  ED_VISIT                   = "e.EVENT_TYPE = 'ED'")

# The family of a confinement diagnosis comes from CONFINEMENT.ICD_FLAG, which
# the data dictionary lists (../DATA_MAPPING.md section 4) - a comment here
# once claimed the table had no such column, and read the family off the admit
# date instead. The date is kept as a FALLBACK for a row whose flag is null or
# unrecognised, because an unrecognised family matches neither and would drop
# the row silently. An ICD-9 myeloma code (2030) and an ICD-10 one (C900) are
# different strings; matching either against a claim of the wrong vintage is a
# false hit nothing downstream could see.
ICD10_TRANSITION <- "2015-10-01"

mod_hcru <- function(con, cfg, cohort) {
  cl <- load_codelist("hcru.csv", cfg)
  ed <- cl[tolower(trimws(cl$concept)) == "ed_visit", , drop = FALSE]
  if (!nrow(ed))
    stop("CODELIST ERROR: hcru.csv carries no ED_VISIT rows, so no emergency ",
         "visit could be found. The construction is undecided - ",
         "../OPEN_QUESTIONS.md Q11 - and a rate of zero would read as a ",
         "finding.", call. = FALSE)
  have <- unique(tolower(trimws(ed$code_type)))
  # The R check is case-insensitive, so the SQL join must be too - otherwise a
  # file typed 'rvnu' passes validation and then matches nothing, and the run
  # reports zero ED visits as if that were a finding. register_codelist_view()
  # publishes code_type_norm for exactly this.
  want <- c(revenue = "rvnu", pos = "pos", cpt = "cpt")
  chosen <- want[cfg$ed_definition]
  absent <- chosen[!chosen %in% have]
  if (length(absent))
    stop("CODELIST ERROR: ED_DEFINITION asks for ",
         paste(names(absent), collapse = ", "), " but hcru.csv has no rows of ",
         "code_type ", paste(absent, collapse = ", "), ". Fill them or narrow ",
         "ED_DEFINITION.", call. = FALSE)
  reg <- register_codelist_view(con, ed, "S_CL_ED",
                                cols = c("concept", "code_type", "code"))

  arms <- c()
  if ("revenue" %in% cfg$ed_definition)
    arms <- c(arms, sprintf(
      "(cl.code_type_norm = 'RVNU' AND upper(regexp_replace(trim(m.RVNU_CD),'[^A-Za-z0-9]','')) = cl.code_norm)"))
  if ("pos" %in% cfg$ed_definition)
    arms <- c(arms, sprintf(
      "(cl.code_type_norm = 'POS' AND upper(regexp_replace(trim(m.POS),'[^A-Za-z0-9]','')) = cl.code_norm)"))
  if ("cpt" %in% cfg$ed_definition)
    arms <- c(arms, sprintf(
      "(cl.code_type_norm = 'CPT' AND upper(regexp_replace(trim(m.PROC_CD),'[^A-Za-z0-9]','')) = cl.code_norm)"))

  prepare_table(con, wrk("S_HCRU_EVENTS"),
    "PATID string, COHORT string, EVENT_TYPE string, EVENT_DT date,
     END_DT date, LOS_DAYS int, MM_RELATED int, HAS_DISCHARGE int", cohort$key)
  prepare_table(con, wrk("S_HCRU_RATES"),
    "COHORT string, LOT_NUM int, PERIOD string, MEASURE string,
     N_PATIENTS int, N_EVENTS int, PERSON_YEARS double, RATE double,
     MEAN_LOS double, MEDIAN_LOS double, N_LOS_EXCLUDED int", cohort$key)
  run_step(con, paste0("hcru_events_", cohort$key), sprintf("
    INSERT INTO %1$s
    -- Inpatient stays. One unduplicated row per hospitalisation, which is what
    -- CONFINEMENT is; the claim-header fallback the cohort build uses for the
    -- MM diagnosis is not needed here because CONF_ID is the grain.
    SELECT p.PATID, p.COHORT, 'INPATIENT' AS EVENT_TYPE,
           cast(cf.ADMIT_DATE as date) AS EVENT_DT,
           cast(cf.DISCH_DATE as date) AS END_DT,
           CASE WHEN cf.DISCH_DATE IS NOT NULL
                THEN %2$s END AS LOS_DAYS,
           CASE WHEN mm.PATID IS NOT NULL THEN 1 ELSE 0 END AS MM_RELATED,
           CASE WHEN cf.DISCH_DATE IS NOT NULL THEN 1 ELSE 0 END AS HAS_DISCHARGE
    FROM %3$s p
    INNER JOIN %4$s cf ON cast(cf.PATID as string) = p.PATID
    LEFT JOIN (
      -- MM in the first or second diagnosis position on the confinement.
      --
      -- The two positions are exploded into rows rather than joined with an
      -- OR: an OR predicate cannot be hashed, so Spark falls back to a nested
      -- loop over the whole of CONFINEMENT. Restricted to this cohort's own
      -- patients for the same reason - the outer join throws the rest away
      -- afterwards, having read them.
      SELECT DISTINCT d.PATID, d.CONF_ID
      FROM (
        SELECT cast(c2.PATID as string) AS PATID, c2.CONF_ID,
               coalesce(%11$s,
                        CASE WHEN cast(c2.ADMIT_DATE as date) >= date('%10$s')
                             THEN 'ICD10' ELSE 'ICD9' END) AS icd_norm,
               dx.code AS raw_code
        FROM %4$s c2
        LATERAL VIEW explode(array(c2.DIAG1, c2.DIAG2)) dx AS code
        WHERE c2.ADMIT_DATE IS NOT NULL
      ) d
      INNER JOIN (SELECT DISTINCT PATID FROM %3$s WHERE COHORT = '%6$s') pc
              ON pc.PATID = d.PATID
      INNER JOIN %5$s mmc
              ON upper(regexp_replace(coalesce(d.raw_code,''),'[^A-Za-z0-9]','')) = mmc.code_norm
             AND mmc.icd_norm = d.icd_norm
    ) mm ON mm.PATID = p.PATID AND mm.CONF_ID = cf.CONF_ID
    WHERE p.COHORT = '%6$s' AND cf.ADMIT_DATE IS NOT NULL
    UNION ALL
    -- Emergency visits, grouped to one per patient per day so a multi-line
    -- claim is one visit.
    SELECT DISTINCT p.PATID, p.COHORT, 'ED' AS EVENT_TYPE,
           cast(m.FST_DT as date) AS EVENT_DT,
           cast(m.FST_DT as date) AS END_DT,
           cast(NULL as int) AS LOS_DAYS, 0 AS MM_RELATED, 1 AS HAS_DISCHARGE
    FROM %3$s p
    INNER JOIN %7$s m ON cast(m.PATID as string) = p.PATID
    INNER JOIN %8$s cl ON %9$s
    WHERE p.COHORT = '%6$s' AND m.FST_DT IS NOT NULL %12$s %13$s",
    wrk("S_HCRU_EVENTS"),
    interval_days_sql("cast(cf.ADMIT_DATE as date)",
                      "cast(cf.DISCH_DATE as date)", TRUE, FALSE),
    wrk("S_PERIODS"), cdm_src("confinement"), "S_CL_MM_DX", cohort$key,
    cdm_src("medical"), reg, paste(arms, collapse = " OR "), ICD10_TRANSITION,
    icd_family_sql("c2.ICD_FLAG"),
    # An ED claim that carries a CONF_ID is one that became an admission -
    # business rule 14: a record without a CONF_ID is non-inpatient.
    if (identical(cfg$ed_admitted, "inpatient_only"))
      "AND (m.CONF_ID IS NULL OR trim(m.CONF_ID) = '')" else "",
    claim_status_sql(cfg, "m")),
    # A count FIRST: run_step's zero-row guard reads the first column, and a
    # string there makes as.numeric() give NA and the guard skip silently.
    qc = sprintf("SELECT count(*) AS n_events,
                    sum(CASE WHEN EVENT_TYPE='INPATIENT' THEN 1 ELSE 0 END) AS n_ip,
                    sum(CASE WHEN EVENT_TYPE='ED' THEN 1 ELSE 0 END) AS n_ed
                  FROM %s WHERE COHORT='%s'", wrk("S_HCRU_EVENTS"), cohort$key))

  # Both periods, in one table, assigned by ADMIT date.
  #
  # The denominator is grouped BY LINE, not summed across the cohort. An
  # uncorrelated total would give every line of a four-line cohort the same
  # person-time and understate each line's rate roughly fourfold. It is also a
  # separate CTE rather than a derived table in FROM, because a FROM-clause
  # subquery cannot see a sibling alias.
  #
  # And the SELECT is driven from that denominator, not from the events: a line
  # with person-time and no events is a rate of zero, and it has to appear as
  # one. Driven from the aggregate it produced no row at all, which downstream
  # is indistinguishable from the module not having run for that line.
  for (per in list(
    list(name = "BASELINE",  start = "p.BASELINE_START", end = "p.BASELINE_END",
         py = "BASELINE_PY", src = wrk("S_PERIODS")),
    list(name = "TREATMENT", start = "p.PERIOD_START",  end = "p.PERIOD_END",
         py = "PERIOD_PY", src = wrk("S_LOT_PERIODS")))) {
    run_step(con, paste0("hcru_rates_", cohort$key, "_", tolower(per$name)),
      sprintf("
      INSERT INTO %1$s
      WITH den AS (
        SELECT COHORT, LOT_NUM, sum(%2$s) AS PY
        FROM %3$s WHERE COHORT = '%4$s' GROUP BY COHORT, LOT_NUM
      ),
      hits AS (
        SELECT p.COHORT, p.LOT_NUM, e.PATID, e.LOS_DAYS, e.HAS_DISCHARGE,
               meas.MEASURE, meas.HIT
        FROM %5$s e
        INNER JOIN %3$s p ON p.PATID = e.PATID AND p.COHORT = e.COHORT
        LATERAL VIEW explode(map(%10$s)) meas AS MEASURE, HIT
        WHERE p.COHORT = \'%4$s\'
          AND e.EVENT_DT BETWEEN %6$s AND %7$s
      ),
      agg AS (
        SELECT COHORT, LOT_NUM, MEASURE,
               count(DISTINCT CASE WHEN HIT = 1 THEN PATID END) AS N_PATIENTS,
               sum(HIT) AS N_EVENTS,
               avg(CASE WHEN HIT = 1 THEN LOS_DAYS END) AS MEAN_LOS,
               -- percentile(), not percentile_approx(): the latter returns an
               -- observed value of the input type, so with LOS_DAYS an int the
               -- median of a 3-day and a 4-day stay is 3, never 3.5 - and it
               -- is approximate as well. Exact costs nothing at this size.
               percentile(CASE WHEN HIT = 1 THEN LOS_DAYS END, 0.5)
                 AS MEDIAN_LOS,
               sum(CASE WHEN HIT = 1 AND HAS_DISCHARGE = 0 THEN 1 ELSE 0 END)
                 AS N_LOS_EXCLUDED
        FROM hits GROUP BY COHORT, LOT_NUM, MEASURE
      ),
      meas_list AS (SELECT explode(array(%11$s)) AS MEASURE)
      SELECT d.COHORT, d.LOT_NUM, \'%8$s\' AS PERIOD, m.MEASURE,
             coalesce(a.N_PATIENTS, 0) AS N_PATIENTS,
             coalesce(a.N_EVENTS, 0) AS N_EVENTS,
             d.PY AS PERSON_YEARS,
             %9$s AS RATE,
             -- Left NULL rather than zeroed: the mean length of no stays is
             -- not zero days, and a zero here would be averaged downstream.
             a.MEAN_LOS, a.MEDIAN_LOS,
             coalesce(a.N_LOS_EXCLUDED, 0) AS N_LOS_EXCLUDED
      FROM den d
      CROSS JOIN meas_list m
      LEFT JOIN agg a ON a.COHORT = d.COHORT AND a.LOT_NUM = d.LOT_NUM
                     AND a.MEASURE = m.MEASURE",
      wrk("S_HCRU_RATES"), per$py, per$src, cohort$key,
      wrk("S_HCRU_EVENTS"), per$start, per$end, per$name,
      rate_sql("coalesce(a.N_EVENTS, 0)", "d.PY", cfg),
      paste(sprintf("'%s', CASE WHEN %s THEN 1 ELSE 0 END",
                    names(HCRU_MEASURES), HCRU_MEASURES), collapse = ", "),
      paste(sprintf("'%s'", names(HCRU_MEASURES)), collapse = ", ")),
      qc = sprintf("SELECT count(*) AS n_rows FROM %s
                    WHERE COHORT=\'%s\' AND PERIOD=\'%s\'",
                   wrk("S_HCRU_RATES"), cohort$key, per$name),
      allow_empty = TRUE)
  }
}

# The MM diagnosis codes, as a view, for the MM-related hospitalisation test.
# Read from the same mm_dx.csv the cohort build used, so the two cannot
# disagree about what myeloma is.
build_mm_dx_view <- function(con, cfg) {
  cl <- load_codelist("mm_dx.csv", cfg)
  register_codelist_view(con, cl, "S_CL_MM_DX", cols = c("dx", "icd_family"),
                         code_col = "dx")
}
