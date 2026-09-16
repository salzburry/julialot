# Every window a later module measures against, in one table per grain.
#
# S_PERIODS      one row per patient per cohort: baseline, follow-up, and the
#                time-to-event analysis flag.
# S_LOT_PERIODS  one row per patient per line: the treatment period an event is
#                attributed to.
#
# Nothing downstream recomputes a window. The conventions are in R/windows.R,
# and the protocol reversed several of them between its June and August 2026
# versions (../VERSION_DIFF.md), so one place to change them is the point.
mod_periods <- function(con, cfg, cohort) {
  bl  <- baseline_window_sql("co.INDEX_DATE", cfg)
  blc <- baseline_window_sql("co.INDEX_DATE", cfg,
                             include_index = cfg$comorbidity_baseline_includes_index)
  fu  <- fu_end_sql(cfg)
  tte <- tte_eligible_sql(cfg, index = "co.INDEX_DATE")
  fu_days <- sprintf("CASE WHEN %s >= co.INDEX_DATE THEN %s END",
                     fu, interval_days_sql("co.INDEX_DATE", fu, TRUE, TRUE))
  fu_months <- sprintf("CASE WHEN %s >= co.INDEX_DATE THEN %s END",
                       fu, days_to_months_sql(
                         interval_days_sql("co.INDEX_DATE", fu, TRUE, TRUE)))

  # The diagnosis date, which three Table 4 and Table 5 rows are anchored on:
  # year of MM diagnosis, follow-up time from diagnosis, and time from
  # diagnosis to 1L initiation. The cohort build's MM_DX_DT is the qualifying
  # I1 diagnosis, the date age and the 1L index are measured against, and is
  # the default. Table 4 also defines one of its own - "first medical claim
  # for MM within the baseline period on or prior to 1L" - which can differ
  # from it. DX_DATE_SOURCE says which is taken; the row says which it got,
  # because under Table 4's reading a patient with no MM claim inside that
  # window falls back to the cohort's date.
  dx_src <- dx_date_source_sql(con, cfg)
  # Table 5: "Time from diagnosis date (included) until index date (excluded)".
  # Table 4: "Time from diagnosis date (included) to patient's follow-up end
  # date (included)". Guarded like FU_DAYS: an index or a follow-up end before
  # the diagnosis is not a negative duration.
  dx_to_index <- sprintf("CASE WHEN co.INDEX_DATE >= %s THEN %s END", dx_src$dt,
                         interval_days_sql(dx_src$dt, "co.INDEX_DATE", TRUE, FALSE))
  fu_from_dx  <- sprintf("CASE WHEN %s >= %s THEN %s END", fu, dx_src$dt,
                         interval_days_sql(dx_src$dt, fu, TRUE, TRUE))

  prepare_table(con, wrk("S_PERIODS"),
    "PATID string, COHORT string, LOT_NUM int, INDEX_DATE date,
     INDEX_YEAR int,
     BASELINE_START date, BASELINE_END date,
     COMORB_BASELINE_START date, COMORB_BASELINE_END date,
     FU_END date, FU_DAYS int, FU_MONTHS double,
     BASELINE_PY double, TTE_ELIGIBLE int,
     MM_DX_DT date, DX_DT date, DX_DT_SOURCE string, DX_YEAR int,
     DX_TO_INDEX_DAYS int, DX_TO_INDEX_MONTHS double,
     FU_FROM_DX_DAYS int, FU_FROM_DX_MONTHS double", cohort$key)
  run_step(con, paste0("periods_", cohort$key), sprintf("
    INSERT INTO %1$s
    SELECT co.PATID, co.COHORT, co.LOT_NUM, co.INDEX_DATE,
           -- Table 4 reports the year of index beside the year of diagnosis,
           -- and the SOC and transplant tables are asked for by calendar
           -- year, so the year is a column and not a shell's arithmetic.
           year(co.INDEX_DATE) AS INDEX_YEAR,
           %2$s AS BASELINE_START, %3$s AS BASELINE_END,
           %4$s AS COMORB_BASELINE_START, %5$s AS COMORB_BASELINE_END,
           %6$s AS FU_END,
           %7$s AS FU_DAYS,
           %8$s AS FU_MONTHS,
           %9$s AS BASELINE_PY,
           %10$s AS TTE_ELIGIBLE,
           c.MM_DX_DT,
           %15$s AS DX_DT,
           %16$s AS DX_DT_SOURCE,
           year(%15$s) AS DX_YEAR,
           %17$s AS DX_TO_INDEX_DAYS,
           %18$s AS DX_TO_INDEX_MONTHS,
           %19$s AS FU_FROM_DX_DAYS,
           %20$s AS FU_FROM_DX_MONTHS
    FROM %11$s co
    INNER JOIN %12$s c ON c.PATID = co.PATID
    -- The enrolment span covering THIS cohort's index date, so follow-up ends
    -- where this patient's enrolment ends after THIS index - not after 1L's.
    LEFT JOIN %14$s fe
           ON fe.PATID = co.PATID
          AND fe.COV_START <= co.INDEX_DATE AND fe.COV_END >= co.INDEX_DATE
    %21$s
    WHERE co.COHORT = '%13$s' AND co.IN_COHORT = 1",
    wrk("S_PERIODS"), bl$start, bl$end, blc$start, blc$end, fu,
    # s7.1: follow-up runs FROM the index date, index included, to the
    # follow-up end, included. Guarded the same way PERIOD_PY is: a follow-up
    # end before the index is not negative follow-up, it is none, and a
    # negative FU_DAYS would be averaged into a mean and drawn on a curve.
    fu_days, fu_months,
    # The baseline denominator for prevalence. s7.8.1: "the total amount of PY
    # present in the baseline period (i.e., 12 months prior to each LOT),
    # irrespective of prior event history" - so it is the window's own length,
    # the same for every patient, not their observed enrolment inside it.
    person_years_sql(bl$start, bl$end, cfg),
    tte, wrk("S_COHORT"), wrk("S_ELIGIBILITY"), cohort$key,
    wrk("S_ENROLL_SPANS"),
    dx_src$dt, dx_src$source,
    dx_to_index, days_to_months_sql(dx_to_index),
    fu_from_dx, days_to_months_sql(fu_from_dx),
    dx_src$join),
    qc = sprintf("SELECT count(*) AS n_rows, sum(TTE_ELIGIBLE) AS n_tte,
                         round(avg(FU_MONTHS), 2) AS mean_fu_months,
                         sum(CASE WHEN DX_DT IS NULL THEN 1 ELSE 0 END) AS n_no_dx
                  FROM %s WHERE COHORT = '%s'", wrk("S_PERIODS"), cohort$key))

  per <- lot_period_sql(cfg)
  # Table 5: "Time from prior LOT to next LOT initiation ... Defined among
  # patients initiating a subsequent LOT as time from prior LOT start date
  # (included) to next LOT start date (excluded)". A next line that starts
  # after this cohort's follow-up ended is not one the cohort observed the
  # patient initiate - it is where TTNT censors them and where the treatment
  # patterns stop - so the interval is NULL there, not a duration the cohort
  # did not see.
  next_days <- sprintf("CASE WHEN l.NEXT_LOT_START_DT IS NOT NULL
                             AND l.NEXT_LOT_START_DT <= p.FU_END THEN %s END",
                       interval_days_sql("l.LOT_START_DT", "l.NEXT_LOT_START_DT",
                                         TRUE, FALSE))
  prepare_table(con, wrk("S_LOT_PERIODS"),
    "PATID string, COHORT string, LOT_NUM int,
     PERIOD_START date, PERIOD_END date, PERIOD_PY double,
     LOT_START_DT date, PROTOCOL_DISCON_DT date, NEXT_LOT_START_DT date,
     NEXT_LOT_DAYS int, NEXT_LOT_MONTHS double",
    cohort$key)
  run_step(con, paste0("lot_periods_", cohort$key), sprintf("
    INSERT INTO %1$s
    SELECT l.PATID, p.COHORT, l.LOT_NUM,
           %2$s AS PERIOD_START, %3$s AS PERIOD_END,
           CASE WHEN %3$s >= %2$s THEN %4$s END AS PERIOD_PY,
           l.LOT_START_DT, l.PROTOCOL_DISCON_DT, l.NEXT_LOT_START_DT,
           %8$s AS NEXT_LOT_DAYS,
           %9$s AS NEXT_LOT_MONTHS
    FROM %5$s l
    INNER JOIN %6$s p ON p.PATID = l.PATID AND p.COHORT = '%7$s'
    WHERE l.LOT_NUM >= p.LOT_NUM",
    wrk("S_LOT_PERIODS"), per$start, per$end,
    person_years_sql(per$start, per$end, cfg),
    wrk("S_SPINE"), wrk("S_PERIODS"), cohort$key,
    next_days, days_to_months_sql(next_days)),
    qc = sprintf("SELECT count(*) AS n_rows,
                         sum(CASE WHEN PERIOD_END < PERIOD_START THEN 1 ELSE 0 END) AS n_empty
                  FROM %s WHERE COHORT = '%s'", wrk("S_LOT_PERIODS"), cohort$key))
}

# Where the diagnosis date comes from, as SQL over the S_PERIODS insert's
# aliases: `c` is S_ELIGIBILITY, `dx` the per-patient first claim in the 1L
# diagnosis window. Returns the date expression, the expression naming which
# source supplied it, and the join that brings `dx` in - empty where the
# cohort's date is taken as it is and no claim is read.
dx_date_source_sql <- function(con, cfg) {
  if (identical(cfg$dx_date_source, "cohort_mm_dx"))
    return(list(dt = "c.MM_DX_DT", source = "'cohort_mm_dx'", join = ""))
  # The 1L index is the input cohort's own, COHORT_INDEX_DATE, for every
  # cohort - a 2L row's diagnosis is anchored on the patient's 1L, not on the
  # 2L baseline. The MM code list is the one the cohort build used, so the two
  # cannot disagree about what a myeloma claim is.
  w <- dx_window_sql("c.COHORT_INDEX_DATE", cfg)
  db_exec(con, sprintf("
    CREATE OR REPLACE TEMPORARY VIEW s_dx_baseline AS
    SELECT c.PATID, min(cast(d.FST_DT as date)) AS DX_DT
    FROM %s c
    INNER JOIN %s d ON cast(d.PATID as string) = c.PATID
    INNER JOIN %s mm
           ON upper(regexp_replace(d.DIAG, '[^A-Za-z0-9]', '')) = mm.code_norm
          AND mm.icd_norm = %s
    WHERE d.FST_DT IS NOT NULL
      AND cast(d.FST_DT as date) BETWEEN %s AND %s
    GROUP BY c.PATID",
    wrk("S_ELIGIBILITY"), cdm_src("diagnosis"), "S_CL_MM_DX",
    icd_family_sql("d.ICD_FLAG"), w$start, w$end))
  list(dt = "coalesce(dx.DX_DT, c.MM_DX_DT)",
       source = "CASE WHEN dx.DX_DT IS NOT NULL THEN 'baseline_claim' ELSE 'cohort_mm_dx' END",
       join = "LEFT JOIN s_dx_baseline dx ON dx.PATID = co.PATID")
}
