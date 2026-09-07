# Every window a later module measures against, in one table per grain.
#
# S_PERIODS      one row per patient per cohort: baseline, follow-up, and the
#                time-to-event analysis flag.
# S_LOT_PERIODS  one row per patient per line: the treatment period an event is
#                attributed to.
#
# Nothing downstream recomputes a window. The conventions are in R/windows.R
# and the protocol reversed several of them between June and August 2026
# (../VERSION_DIFF.md), so one place to change them is the point.
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

  prepare_table(con, wrk("S_PERIODS"),
    "PATID string, COHORT string, LOT_NUM int, INDEX_DATE date,
     BASELINE_START date, BASELINE_END date,
     COMORB_BASELINE_START date, COMORB_BASELINE_END date,
     FU_END date, FU_DAYS int, FU_MONTHS double,
     BASELINE_PY double, TTE_ELIGIBLE int", cohort$key)
  run_step(con, paste0("periods_", cohort$key), sprintf("
    INSERT INTO %1$s
    SELECT co.PATID, co.COHORT, co.LOT_NUM, co.INDEX_DATE,
           %2$s AS BASELINE_START, %3$s AS BASELINE_END,
           %4$s AS COMORB_BASELINE_START, %5$s AS COMORB_BASELINE_END,
           %6$s AS FU_END,
           %7$s AS FU_DAYS,
           %8$s AS FU_MONTHS,
           %9$s AS BASELINE_PY,
           %10$s AS TTE_ELIGIBLE
    FROM %11$s co
    INNER JOIN %12$s c ON c.PATID = co.PATID
    -- The enrolment span covering THIS cohort's index date, so follow-up ends
    -- where this patient's enrolment ends after THIS index - not after 1L's.
    LEFT JOIN %14$s fe
           ON fe.PATID = co.PATID
          AND fe.COV_START <= co.INDEX_DATE AND fe.COV_END >= co.INDEX_DATE
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
    tte, wrk("S_COHORT"), cfg$input_cohort_table, cohort$key,
    wrk("S_ENROLL_SPANS")),
    qc = sprintf("SELECT count(*) AS n_rows, sum(TTE_ELIGIBLE) AS n_tte,
                         round(avg(FU_MONTHS), 2) AS mean_fu_months
                  FROM %s WHERE COHORT = '%s'", wrk("S_PERIODS"), cohort$key))

  per <- lot_period_sql(cfg)
  prepare_table(con, wrk("S_LOT_PERIODS"),
    "PATID string, COHORT string, LOT_NUM int,
     PERIOD_START date, PERIOD_END date, PERIOD_PY double,
     LOT_START_DT date, LOT_BASE_DISCON_DT date, NEXT_LOT_START_DT date",
    cohort$key)
  run_step(con, paste0("lot_periods_", cohort$key), sprintf("
    INSERT INTO %1$s
    SELECT l.PATID, p.COHORT, l.LOT_NUM,
           %2$s AS PERIOD_START, %3$s AS PERIOD_END,
           CASE WHEN %3$s >= %2$s THEN %4$s END AS PERIOD_PY,
           l.LOT_START_DT, l.LOT_BASE_DISCON_DT, l.NEXT_LOT_START_DT
    FROM %5$s l
    INNER JOIN %6$s p ON p.PATID = l.PATID AND p.COHORT = '%7$s'
    WHERE l.LOT_NUM >= p.LOT_NUM",
    wrk("S_LOT_PERIODS"), per$start, per$end,
    person_years_sql(per$start, per$end, cfg),
    wrk("S_SPINE"), wrk("S_PERIODS"), cohort$key),
    qc = sprintf("SELECT count(*) AS n_rows,
                         sum(CASE WHEN PERIOD_END < PERIOD_START THEN 1 ELSE 0 END) AS n_empty
                  FROM %s WHERE COHORT = '%s'", wrk("S_LOT_PERIODS"), cohort$key))
}
