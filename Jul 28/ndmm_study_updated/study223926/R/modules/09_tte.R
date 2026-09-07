# TTNT, TTD and OS - Table 5.
#
# The endpoint conventions REVERSED between the June and August 2026 versions
# (../VERSION_DIFF.md section 1). The August ones are: the interval opens ON the
# index (included) and closes BEFORE the event (excluded), so every duration is
# datediff(event, index) with no adjustment.
#
# The one that will bite: TTD's event is "the date of treatment
# discontinuation", and the protocol's footnote defines discontinuation as all
# agents stopped OR a new agent OR a qualifying SCT. The engine spells those as
# three different LOT_BASE_END_REASON values, so the event set is the union -
# IS_PROTOCOL_DISCON on the spine. Reading LOT_BASE_END_REASON = 'DISCONTINUATION'
# would undercount TTD badly. ../BUILD_DELTA.md section 5.
mod_tte <- function(con, cfg, cohort) {
  # Each event date is written once and reused, so the date column and the
  # days column can never describe different events.
  ttnt_dt <- "least(coalesce(s.NEXT_LOT_START_DT, p.FU_END),
                    coalesce(c.DEATH_DT, p.FU_END), p.FU_END)"
  ttd_dt  <- "least(coalesce(CASE WHEN s.IS_PROTOCOL_DISCON = 1
                                  THEN coalesce(s.LOT_BASE_DISCON_DT, s.LOT_BASE_END_DT)
                             END, p.FU_END),
                    coalesce(s.NEXT_LOT_START_DT, p.FU_END),
                    coalesce(c.DEATH_DT, p.FU_END), p.FU_END)"
  os_dt   <- "coalesce(c.DEATH_DT, p.FU_END)"

  days <- function(to) interval_days_sql("p.INDEX_DATE", to, TRUE, FALSE)
  mons <- function(to) days_to_months_sql(days(to))

  run_step(con, paste0("tte_", cohort$key), sprintf("
    CREATE TABLE IF NOT EXISTS %1$s (
      PATID string, COHORT string, LOT_NUM int, INDEX_DATE date,
      TTE_ELIGIBLE int,
      TTNT_DT date, TTNT_DAYS int, TTNT_MONTHS double, TTNT_EVENT int,
      TTD_DT date,  TTD_DAYS int,  TTD_MONTHS double,  TTD_EVENT int,
      OS_DT date,   OS_DAYS int,   OS_MONTHS double,   OS_EVENT int);
    INSERT INTO %1$s
    SELECT p.PATID, p.COHORT, p.LOT_NUM, p.INDEX_DATE, p.TTE_ELIGIBLE,
           %2$s AS TTNT_DT, %3$s AS TTNT_DAYS, %4$s AS TTNT_MONTHS,
           CASE WHEN s.NEXT_LOT_START_DT IS NOT NULL OR c.DEATH_DT IS NOT NULL
                THEN 1 ELSE 0 END AS TTNT_EVENT,
           %5$s AS TTD_DT, %6$s AS TTD_DAYS, %7$s AS TTD_MONTHS,
           CASE WHEN s.IS_PROTOCOL_DISCON = 1
                  OR s.NEXT_LOT_START_DT IS NOT NULL
                  OR c.DEATH_DT IS NOT NULL THEN 1 ELSE 0 END AS TTD_EVENT,
           %8$s AS OS_DT, %9$s AS OS_DAYS, %10$s AS OS_MONTHS,
           CASE WHEN c.DEATH_DT IS NOT NULL THEN 1 ELSE 0 END AS OS_EVENT
    FROM %11$s p
    INNER JOIN %12$s s ON s.PATID = p.PATID AND s.LOT_NUM = p.LOT_NUM
    INNER JOIN %13$s c ON c.PATID = p.PATID
    WHERE p.COHORT = '%14$s'",
    wrk("S_TTE"),
    ttnt_dt, days(ttnt_dt), mons(ttnt_dt),
    ttd_dt,  days(ttd_dt),  mons(ttd_dt),
    os_dt,   days(os_dt),   mons(os_dt),
    wrk("S_PERIODS"), wrk("S_SPINE"), cfg$input_cohort_table, cohort$key),
    qc = sprintf("SELECT count(*) AS n_rows, sum(TTE_ELIGIBLE) AS n_tte,
                         sum(OS_EVENT) AS n_deaths FROM %s WHERE COHORT='%s'",
                 wrk("S_TTE"), cohort$key))

  # The analysis set is a flag on every row, never a filter: Objectives 1 to 3
  # are described over the whole cohort and only the time-to-event outcomes are
  # restricted. s7.8.2.
  n <- db_q(con, sprintf(
    "SELECT count(*) AS n, sum(TTE_ELIGIBLE) AS k FROM %s WHERE COHORT='%s'",
    wrk("S_TTE"), cohort$key))
  log_msg("  ", cohort$key, ": ", n$k[1], " of ", n$n[1],
          " rows are in the time-to-event analysis set (>= ",
          cfg$tte_min_potential_fu_days, " days of potential follow-up, or ",
          "death before it).")
}
