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
mod_hcru <- function(con, cfg, cohort) {
  cl <- load_codelist("hcru.csv", cfg)
  ed <- cl[tolower(trimws(cl$concept)) == "ed_visit", , drop = FALSE]
  if (!nrow(ed))
    stop("CODELIST ERROR: hcru.csv carries no ED_VISIT rows, so no emergency ",
         "visit could be found. The construction is undecided - ",
         "../OPEN_QUESTIONS.md Q11 - and a rate of zero would read as a ",
         "finding.", call. = FALSE)
  have <- unique(tolower(trimws(ed$code_type)))
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
      "(cl.code_type = 'RVNU' AND upper(regexp_replace(trim(m.RVNU_CD),'[^A-Za-z0-9]','')) = cl.code_norm)"))
  if ("pos" %in% cfg$ed_definition)
    arms <- c(arms, "(cl.code_type = 'POS' AND trim(m.POS) = cl.code_norm)")
  if ("cpt" %in% cfg$ed_definition)
    arms <- c(arms, sprintf(
      "(cl.code_type = 'CPT' AND upper(regexp_replace(trim(m.PROC_CD),'[^A-Za-z0-9]','')) = cl.code_norm)"))

  run_step(con, paste0("hcru_events_", cohort$key), sprintf("
    CREATE TABLE IF NOT EXISTS %1$s (
      PATID string, COHORT string, EVENT_TYPE string, EVENT_DT date,
      END_DT date, LOS_DAYS int, MM_RELATED int, HAS_DISCHARGE int);
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
      SELECT DISTINCT cast(c2.PATID as string) AS PATID, c2.CONF_ID
      FROM %4$s c2
      INNER JOIN %5$s mmc
              ON upper(regexp_replace(coalesce(c2.DIAG1,''),'[^A-Za-z0-9]','')) = mmc.code_norm
              OR upper(regexp_replace(coalesce(c2.DIAG2,''),'[^A-Za-z0-9]','')) = mmc.code_norm
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
    WHERE p.COHORT = '%6$s' AND m.FST_DT IS NOT NULL",
    wrk("S_HCRU_EVENTS"),
    interval_days_sql("cast(cf.ADMIT_DATE as date)",
                      "cast(cf.DISCH_DATE as date)", TRUE, FALSE),
    wrk("S_PERIODS"), cdm_src("confinement"), "S_CL_MM_DX", cohort$key,
    cdm_src("medical"), reg, paste(arms, collapse = " OR ")),
    qc = sprintf("SELECT EVENT_TYPE, count(*) AS n FROM %s WHERE COHORT='%s'
                  GROUP BY EVENT_TYPE", wrk("S_HCRU_EVENTS"), cohort$key))

  # Both periods, in one table, assigned by ADMIT date.
  for (per in list(
    list(name = "BASELINE",  start = "p.BASELINE_START", end = "p.BASELINE_END",
         py = "p.BASELINE_PY", src = wrk("S_PERIODS"), lot = "p.LOT_NUM"),
    list(name = "TREATMENT", start = "p.PERIOD_START",  end = "p.PERIOD_END",
         py = "p.PERIOD_PY", src = wrk("S_LOT_PERIODS"), lot = "p.LOT_NUM"))) {
    run_step(con, paste0("hcru_rates_", cohort$key, "_", tolower(per$name)),
      sprintf("
      CREATE TABLE IF NOT EXISTS %1$s (
        COHORT string, LOT_NUM int, PERIOD string, MEASURE string,
        N_PATIENTS int, N_EVENTS int, PERSON_YEARS double, RATE double,
        MEAN_LOS double, MEDIAN_LOS double, N_LOS_EXCLUDED int);
      INSERT INTO %1$s
      SELECT p.COHORT, %2$s AS LOT_NUM, '%3$s' AS PERIOD, meas.MEASURE,
             count(DISTINCT CASE WHEN meas.HIT = 1 THEN e.PATID END) AS N_PATIENTS,
             sum(meas.HIT) AS N_EVENTS,
             max(den.PY) AS PERSON_YEARS,
             %4$s AS RATE,
             avg(CASE WHEN meas.HIT = 1 THEN e.LOS_DAYS END) AS MEAN_LOS,
             percentile_approx(CASE WHEN meas.HIT = 1 THEN e.LOS_DAYS END, 0.5)
               AS MEDIAN_LOS,
             sum(CASE WHEN meas.HIT = 1 AND e.HAS_DISCHARGE = 0 THEN 1 ELSE 0 END)
               AS N_LOS_EXCLUDED
      FROM %5$s e
      INNER JOIN %6$s p ON p.PATID = e.PATID AND p.COHORT = e.COHORT
      CROSS JOIN (SELECT sum(%7$s) AS PY FROM %6$s WHERE COHORT = '%8$s') den
      LATERAL VIEW explode(map(
        'ALL_CAUSE_HOSPITALISATION',
          CASE WHEN e.EVENT_TYPE = 'INPATIENT' THEN 1 ELSE 0 END,
        'MM_RELATED_HOSPITALISATION',
          CASE WHEN e.EVENT_TYPE = 'INPATIENT' AND e.MM_RELATED = 1 THEN 1 ELSE 0 END,
        'ED_VISIT',
          CASE WHEN e.EVENT_TYPE = 'ED' THEN 1 ELSE 0 END
      )) meas AS MEASURE, HIT
      WHERE p.COHORT = '%8$s'
        AND e.EVENT_DT BETWEEN %9$s AND %10$s
      GROUP BY p.COHORT, %2$s, meas.MEASURE",
      wrk("S_HCRU_RATES"), per$lot, per$name,
      rate_sql("sum(meas.HIT)", "max(den.PY)", cfg),
      wrk("S_HCRU_EVENTS"), per$src, per$py, cohort$key, per$start, per$end),
      qc = sprintf("SELECT count(*) AS n_rows FROM %s
                    WHERE COHORT='%s' AND PERIOD='%s'",
                   wrk("S_HCRU_RATES"), cohort$key, per$name),
      allow_empty = TRUE)
  }
}

# The MM diagnosis codes, as a view, for the MM-related hospitalisation test.
# Read from the same mm_dx.csv the cohort build used, so the two cannot
# disagree about what myeloma is.
build_mm_dx_view <- function(con, cfg) {
  cl <- load_codelist("mm_dx.csv", cfg, code_col = "dx")
  register_codelist_view(con, cl, "S_CL_MM_DX", cols = c("dx", "icd_family"),
                         code_col = "dx")
}
