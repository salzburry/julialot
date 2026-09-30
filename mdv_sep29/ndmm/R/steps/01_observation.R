# When each candidate is observed at the hospital: the first and the last day
# they appear in any MDV source.
#
# This replaces the Optum build's enrollment spans. MDV has no insurance
# enrollment: a patient is seen while they attend a contributing hospital, and
# a patient who stops attending looks exactly like one who stopped needing
# care. So the two continuous-enrollment criteria become observation criteria
# (DECISIONS.md, "MDV"):
#
#   criterion 4  records reaching back PRE_LOT1_DAYS before the index - the
#                lookback that "12 months of continuous enrollment" bought
#   criterion 5  records reaching FU_CE_DAYS past it - 0, the index date
#                itself, which the index act always satisfies
#
# and ENDDATE_CE, the date the Optum cohort's enrollment ended, is the last day
# the patient is seen.
#
# Three sources, so a patient who visits without being given a drug still
# counts as seen: every act, every diagnosis month, and every FF1 episode. A
# diagnosis month is dated to its first day, so it can start a patient's
# observation up to a month before their first visit that month and end it up
# to a month before their last; act and FF1 dates are exact. Scoped to the
# base cohort, because an act-table scan of the whole warehouse buys nothing.
#
# The patient key is the hospital's own, so a patient who moves between two
# contributing hospitals is two patients here, each observed at one.
build_ndmm_obs_period <- function(con) {
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_OBS_PERIOD} AS
    WITH pts AS (
      SELECT DISTINCT PATID FROM {NDMM_BASE_COHORT}
    ),
    dx AS (
      SELECT d.PATID, min(d.DX_MONTH) AS first_dt, max(d.DX_MONTH) AS last_dt
      FROM {NDMM_DX} d
      INNER JOIN pts ON pts.PATID = d.PATID
      GROUP BY d.PATID
    ),
    act AS (
      SELECT a.PATID, min(a.ACT_DT) AS first_dt, max(a.ACT_DT) AS last_dt
      FROM ({mdv_act_select()}
      ) a
      INNER JOIN pts ON pts.PATID = a.PATID
      GROUP BY a.PATID
    ),
    ff1 AS (
      SELECT f.PATID, min(f.FF1_START_DT) AS first_dt, max(f.FF1_END_DT) AS last_dt
      FROM {NDMM_FF1} f
      INNER JOIN pts ON pts.PATID = f.PATID
      GROUP BY f.PATID
    )
    SELECT pts.PATID,
           least(dx.first_dt, act.first_dt, ff1.first_dt)   AS OBS_START_DT,
           greatest(dx.last_dt, act.last_dt, ff1.last_dt)   AS OBS_END_DT
    FROM pts
    LEFT JOIN dx  ON dx.PATID  = pts.PATID
    LEFT JOIN act ON act.PATID = pts.PATID
    LEFT JOIN ff1 ON ff1.PATID = pts.PATID
  "))
}
