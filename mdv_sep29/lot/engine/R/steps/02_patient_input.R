# The cohort, as LOT reads it. OBS_END_DT is chosen here, and every MAP gap,
# discontinuation and SCT window downstream uses it.

phase_patient_input <- function(con) {
  # STEP 1: Load Part 1 cohort
  # OBS_END_DT = observation end for all LOT/MAP logic.
  # cfg$censor_at_disenrollment = TRUE, pinned on MDV:
  #   OBS_END_DT = coalesce(ENDDATE_CE, ENDDATE). On MDV, ENDDATE_CE is the last
  #   MDV record, so a patient is observed until they stop appearing.
  #   MDV has no enrollment (LOT_RULES.md 7.6; MDV_RULES.md section 4).
  # cfg$censor_at_disenrollment = FALSE, a contract deviation on MDV:
  #   OBS_END_DT = ENDDATE = min(death_dt, study_end).
  # ENDDATE_CE is preserved as a column either way for ad-hoc analyses.
  obs_end_dt_expr <- if (isTRUE(cfg$censor_at_disenrollment)) {
    "coalesce(cast(ENDDATE_CE AS date), cast(ENDDATE AS date))"
  } else {
    "cast(ENDDATE AS date)"
  }
  log_msg("  OBS_END_DT mode:    ",
          if (isTRUE(cfg$censor_at_disenrollment)) "ENDDATE_CE (the last MDV record)"
          else "ENDDATE (to study end or death; a contract deviation on MDV)")
  run_step(con, "S03_patient_input", glue("
    CREATE OR REPLACE TEMPORARY VIEW lot_patient_input AS
    SELECT
      PATID,
      cast(INDEX_DATE AS date) AS INDEX_DATE,
      cast(ENDDATE AS date)    AS ENDDATE,
      cast(ENDDATE_CE AS date) AS ENDDATE_CE,
      -- OBS_END_DT picked by cfg$censor_at_disenrollment (logged above).
      -- All MAP gap checks, LOT discontinuation confirmation, SCT windows,
      -- and LOT end date logic use this value.
      {obs_end_dt_expr} AS OBS_END_DT,
      cast(DEATH_DT AS date)   AS DEATH_DT,
      GDR_CD,
      YRDOB,
      AGE_INDEX_YR,
      FU_DAYS,
      FU_DAYS_CE
    FROM {wrk(cfg$input_cohort_table)}
  "), qc = "
    SELECT count(*) AS n_patients, min(INDEX_DATE) AS min_index, max(OBS_END_DT) AS max_obs_end,
           sum(case when ENDDATE_CE < ENDDATE then 1 else 0 end) AS n_disenrolled_before_enddate
    FROM lot_patient_input")

}
