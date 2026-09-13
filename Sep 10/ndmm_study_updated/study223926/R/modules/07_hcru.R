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
# rather than a literal repeated twice: the rates below are driven from the
# DENOMINATOR, and this list is what turns one line's person-time into one row
# per measure.
HCRU_MEASURES <- c(
  ALL_CAUSE_HOSPITALISATION  = "e.EVENT_TYPE = 'INPATIENT'",
  MM_RELATED_HOSPITALISATION = "e.EVENT_TYPE = 'INPATIENT' AND e.MM_RELATED = 1",
  ED_VISIT                   = "e.EVENT_TYPE = 'ED'")

# The family of a confinement diagnosis comes from CONFINEMENT.ICD_FLAG
# (../DATA_MAPPING.md section 4). The admit date is a FALLBACK for a row whose
# flag is null or unrecognised, because an unrecognised family matches neither
# and would drop the row silently. An ICD-9 myeloma code (2030) and an ICD-10
# one (C900) are different strings, and matching either against a claim of the
# wrong vintage is a false hit nothing downstream could see.
ICD10_TRANSITION <- "2015-10-01"

# What the HCRU list must satisfy beyond its shape: ED_VISIT rows, of every
# code type ED_DEFINITION reads. The module runs it as it starts; the
# preflight runs it before the connection is opened. Returns the ED rows.
check_hcru_list <- function(cfg, cl = load_codelist("hcru.csv", cfg)) {
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
  # publishes code_type_norm for it.
  want <- c(revenue = "rvnu", pos = "pos", cpt = "cpt")
  chosen <- want[cfg$ed_definition]
  absent <- chosen[!chosen %in% have]
  if (length(absent))
    stop("CODELIST ERROR: ED_DEFINITION asks for ",
         paste(names(absent), collapse = ", "), " but hcru.csv has no rows of ",
         "code_type ", paste(absent, collapse = ", "), ". Fill them or narrow ",
         "ED_DEFINITION.", call. = FALSE)
  invisible(ed)
}

mod_hcru <- function(con, cfg, cohort) {
  cl <- load_codelist("hcru.csv", cfg)
  ed <- check_hcru_list(cfg, cl)
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

  # Which route decides that a stay is MM-related - open question Q27. The two
  # disagree by a factor of two: over 241,362 myeloma-patient stays the
  # confinement's own first two diagnoses find 32,508 and the claim positions
  # find 65,206, of which 33,904 only the claim route finds. s7.8.1 does not say
  # which it means, so both are built and the run records which it took.
  mm_hosp_subq <- if (identical(cfg$mm_hosp_position, "claim_positions")) sprintf(
    "-- Route B. MM in DIAG_POSITION 1 or 2 on a claim carrying the stay's
      -- CONF_ID, which is the route business rule 13 documents: twenty-five
      -- positions, claim-line grain. DIAG_POSITION is stored zero-padded
      -- ('01'..'25', confirmed 03 Sep 2026), so it is cast rather than compared
      -- as a string.
      SELECT DISTINCT cast(m2.PATID as string) AS PATID, m2.CONF_ID
      FROM       %1$s m2
      -- The FULL documented key. The Optum join diagram gives MEDICAL to
      -- MED_DIAGNOSIS as (PATID | PAT_PLANID, CLMID, FST_DT, LOC_CD); joining
      -- on patient and claim id alone let a claim id that repeats on another
      -- service date carry its myeloma diagnosis onto the wrong admission, so
      -- a stay a year away became MM-related. LOC_CD is compared null-safely
      -- because it is nullable on both sides and a plain = would drop the row.
      INNER JOIN %2$s dg
              ON cast(dg.PATID as string) = cast(m2.PATID as string)
             AND dg.PAT_PLANID <=> m2.PAT_PLANID
             AND dg.CLMID = m2.CLMID
             AND cast(dg.FST_DT as date) = cast(m2.FST_DT as date)
             AND dg.LOC_CD <=> m2.LOC_CD
      INNER JOIN (SELECT DISTINCT PATID FROM %3$s WHERE COHORT = '%4$s') pc
              ON pc.PATID = cast(m2.PATID as string)
      INNER JOIN %5$s mmc
              ON upper(regexp_replace(coalesce(dg.DIAG,''),'[^A-Za-z0-9]','')) = mmc.code_norm
             AND mmc.icd_norm = coalesce(%6$s,
                                         CASE WHEN cast(dg.FST_DT as date) >= date('%7$s')
                                              THEN 'ICD10' ELSE 'ICD9' END)
      WHERE m2.CONF_ID IS NOT NULL AND trim(m2.CONF_ID) <> ''
        AND try_cast(dg.DIAG_POSITION as int) IN (1, 2)",
    cdm_src("medical"), cdm_src("diagnosis"), wrk("S_PERIODS"), cohort$key,
    "S_CL_MM_DX", icd_family_sql("dg.ICD_FLAG"), ICD10_TRANSITION)
  else sprintf(
    "-- Route A. MM in the first or second diagnosis position on the
      -- confinement record itself.
      --
      -- The two positions are exploded into rows rather than joined with an
      -- OR: an OR predicate cannot be hashed, so Spark falls back to a nested
      -- loop over the whole of CONFINEMENT. Restricted to this cohort's own
      -- patients for the same reason - the outer join throws the rest away
      -- afterwards, having read them.
      SELECT DISTINCT d.PATID, d.CONF_ID
      FROM (
        SELECT cast(c2.PATID as string) AS PATID, c2.CONF_ID,
               coalesce(%1$s,
                        CASE WHEN cast(c2.ADMIT_DATE as date) >= date('%2$s')
                             THEN 'ICD10' ELSE 'ICD9' END) AS icd_norm,
               dx.code AS raw_code
        FROM %3$s c2
        LATERAL VIEW explode(array(c2.DIAG1, c2.DIAG2)) dx AS code
        WHERE c2.ADMIT_DATE IS NOT NULL
      ) d
      INNER JOIN (SELECT DISTINCT PATID FROM %4$s WHERE COHORT = '%5$s') pc
              ON pc.PATID = d.PATID
      INNER JOIN %6$s mmc
              ON upper(regexp_replace(coalesce(d.raw_code,''),'[^A-Za-z0-9]','')) = mmc.code_norm
             AND mmc.icd_norm = d.icd_norm",
    icd_family_sql("c2.ICD_FLAG"), ICD10_TRANSITION, cdm_src("confinement"),
    wrk("S_PERIODS"), cohort$key, "S_CL_MM_DX")

  prepare_table(con, wrk("S_HCRU_EVENTS"),
    "PATID string, COHORT string, EVENT_TYPE string, EVENT_DT date,
     END_DT date, LOS_DAYS int, MM_RELATED int, HAS_DISCHARGE int", cohort$key)
  prepare_table(con, wrk("S_HCRU_RATES"),
    "COHORT string, LOT_NUM int, PERIOD string,
     SOC_CATEGORY string, AGE_GROUP string, MEASURE string,
     N_PATIENTS int, N_EVENTS int, N_AT_RISK int,
     PERSON_YEARS double, RATE double,
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
      %11$s
    ) mm ON mm.PATID = p.PATID AND mm.CONF_ID = cf.CONF_ID
    WHERE p.COHORT = '%5$s' AND cf.ADMIT_DATE IS NOT NULL
    UNION ALL
    -- Emergency visits, grouped to one per patient per day so a multi-line
    -- claim is one visit.
    SELECT DISTINCT p.PATID, p.COHORT, 'ED' AS EVENT_TYPE,
           cast(m.FST_DT as date) AS EVENT_DT,
           cast(m.FST_DT as date) AS END_DT,
           cast(NULL as int) AS LOS_DAYS, 0 AS MM_RELATED, 1 AS HAS_DISCHARGE
    FROM %3$s p
    INNER JOIN %6$s m ON cast(m.PATID as string) = p.PATID
    INNER JOIN %7$s cl ON %8$s
    WHERE p.COHORT = '%5$s' AND m.FST_DT IS NOT NULL %9$s %10$s",
    wrk("S_HCRU_EVENTS"),
    interval_days_sql("cast(cf.ADMIT_DATE as date)",
                      "cast(cf.DISCH_DATE as date)", TRUE, FALSE),
    wrk("S_PERIODS"), cdm_src("confinement"), cohort$key,
    cdm_src("medical"), reg, paste(arms, collapse = " OR "),
    # An ED claim that carries a CONF_ID is one that became an admission -
    # business rule 14: a record without a CONF_ID is non-inpatient.
    if (identical(cfg$ed_admitted, "inpatient_only"))
      "AND (m.CONF_ID IS NULL OR trim(m.CONF_ID) = '')" else "",
    claim_status_sql(cfg, "m"), mm_hosp_subq),
    # A cohort with no hospitalisation and no ED visit is a valid study result.
    # The rates below are driven from the DENOMINATOR, so every measure still
    # gets a row saying zero.
    allow_empty = TRUE,
    # A count first: run_step's zero-row guard reads the first column, and a
    # string there makes as.numeric() give NA and the guard skip silently.
    qc = sprintf("SELECT count(*) AS n_events,
                    sum(CASE WHEN EVENT_TYPE='INPATIENT' THEN 1 ELSE 0 END) AS n_ip,
                    sum(CASE WHEN EVENT_TYPE='ED' THEN 1 ELSE 0 END) AS n_ed
                  FROM %s WHERE COHORT='%s'", wrk("S_HCRU_EVENTS"), cohort$key))

  # Both periods, in one table, assigned by ADMIT date. Grouped BY LINE, not
  # summed across the cohort, since a total would give every line the same
  # person-time. The SELECT is driven from the denominator, not the events, so
  # a line with person-time and no events is a rate of zero rather than no row.
  for (per in list(
    list(name = "BASELINE",  start = "p.BASELINE_START", end = "p.BASELINE_END",
         py = "BASELINE_PY", src = wrk("S_PERIODS")),
    list(name = "TREATMENT", start = "p.PERIOD_START",  end = "p.PERIOD_END",
         py = "PERIOD_PY", src = wrk("S_LOT_PERIODS")))) {
    # The line as a whole, then each regimen category, from the same query.
    for (sp in stratum_passes(cfg, "p")) {
    run_step(con, paste0("hcru_rates_", cohort$key, "_", tolower(per$name),
                         "_", sp$key),
      sprintf("
      INSERT INTO %1$s
      WITH den AS (
        -- N_AT_RISK is the STRATUM size - everyone contributing person-time -
        -- as against N_PATIENTS, which counts only those with the event. The
        -- suppression rule is about the stratum, so it needs this column.
        -- Both restricted to the SAME observed periods. sum() skips NULL
        -- person-time but count(DISTINCT PATID) did not, and S_LOT_PERIODS
        -- keeps later lines whose period is empty with PERIOD_PY NULL - so a
        -- patient contributing no observed time still counted towards the
        -- stratum size, and a stratum that should have failed the fewer-than-25
        -- rule was released. Safety and malignancy already scope both to the
        -- at-risk set; this now matches them.
        SELECT p.COHORT, p.LOT_NUM, %12$s, sum(p.%2$s) AS PY,
               count(DISTINCT CASE WHEN p.%2$s IS NOT NULL THEN p.PATID END)
                 AS N_AT_RISK
        FROM %3$s p
        %13$s
        WHERE p.COHORT = '%4$s' GROUP BY p.COHORT, p.LOT_NUM%14$s
      ),
      hits AS (
        SELECT p.COHORT, p.LOT_NUM, %12$s,
               e.PATID, e.LOS_DAYS, e.HAS_DISCHARGE,
               meas.MEASURE, meas.HIT
        FROM %5$s e
        INNER JOIN %3$s p ON p.PATID = e.PATID AND p.COHORT = e.COHORT
        %13$s
        LATERAL VIEW explode(map(%10$s)) meas AS MEASURE, HIT
        WHERE p.COHORT = \'%4$s\'
          AND e.EVENT_DT BETWEEN %6$s AND %7$s
      ),
      agg AS (
        SELECT COHORT, LOT_NUM, SOC_CATEGORY, AGE_GROUP, MEASURE,
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
        FROM hits GROUP BY COHORT, LOT_NUM, SOC_CATEGORY, AGE_GROUP, MEASURE
      ),
      meas_list AS (SELECT explode(array(%11$s)) AS MEASURE)
      SELECT d.COHORT, d.LOT_NUM, \'%8$s\' AS PERIOD,
             d.SOC_CATEGORY, d.AGE_GROUP, m.MEASURE,
             coalesce(a.N_PATIENTS, 0) AS N_PATIENTS,
             coalesce(a.N_EVENTS, 0) AS N_EVENTS,
             d.N_AT_RISK,
             d.PY AS PERSON_YEARS,
             %9$s AS RATE,
             -- Left NULL rather than zeroed: the mean length of no stays is
             -- not zero days, and a zero here would be averaged downstream.
             a.MEAN_LOS, a.MEDIAN_LOS,
             coalesce(a.N_LOS_EXCLUDED, 0) AS N_LOS_EXCLUDED
      FROM den d
      CROSS JOIN meas_list m
      LEFT JOIN agg a ON a.COHORT = d.COHORT AND a.LOT_NUM = d.LOT_NUM
                     AND a.MEASURE = m.MEASURE
                     AND a.SOC_CATEGORY = d.SOC_CATEGORY
                     AND a.AGE_GROUP = d.AGE_GROUP",
      wrk("S_HCRU_RATES"), per$py, per$src, cohort$key,
      wrk("S_HCRU_EVENTS"), per$start, per$end, per$name,
      rate_sql("coalesce(a.N_EVENTS, 0)", "d.PY", cfg),
      paste(sprintf("'%s', CASE WHEN %s THEN 1 ELSE 0 END",
                    names(HCRU_MEASURES), HCRU_MEASURES), collapse = ", "),
      paste(sprintf("'%s'", names(HCRU_MEASURES)), collapse = ", "),
      sp$cols, sp$join, sp$group),
      qc = sprintf("SELECT count(*) AS n_rows FROM %s
                    WHERE COHORT=\'%s\' AND PERIOD=\'%s\'",
                   wrk("S_HCRU_RATES"), cohort$key, per$name),
      allow_empty = TRUE)
    }
  }
}

# The MM diagnosis codes, as a view, for the MM-related hospitalisation test.
# Read from the same code list the cohort build used, so the two cannot
# disagree about what myeloma is.
build_mm_dx_view <- function(con, cfg) {
  cl <- load_codelist("mm_dx.csv", cfg)
  register_codelist_view(con, cl, "S_CL_MM_DX", cols = c("dx", "icd_family"),
                         code_col = "dx")
}
