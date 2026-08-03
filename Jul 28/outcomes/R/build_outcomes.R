# Secondary Objective 1: treatment patterns and treatment-related outcomes.
#
# Protocol Table 4. Reads one finished LOT run and writes patient-per-line
# tables. It computes no line and no cohort of its own - the lines are lot's
# and the population is the cohort's, so a number here can always be traced
# back to the run that produced it.
#
# The three time-to-event outcomes, in the protocol's words:
#
#   TTNT  "Time from index LOT start date (excluded) to the earliest between
#          the start of the next LOT or death (included). Patients without a
#          subsequent LOT or date of death will be censored at their follow-up
#          end date"
#
#   TTD   "Time from index LOT start date (excluded) to the date of treatment
#          discontinuation (included). The discontinuation date is the earliest
#          of the date of treatment discontinuation (end of current LOT),
#          initiation of the next LOT, or death. Patients without treatment
#          discontinuation, next LOT or death will be censored at their
#          follow-up end date"
#
#   OS    "Time from LOT start date (excluded) to date of death (included).
#          Patients without a recorded date of death will be censored at their
#          follow-up end date"
#
# "Excluded" and "included" are the protocol's own: the index day does not
# count and the event day does. That is a plain date difference, which is what
# datediff gives.

# The follow-up end, per protocol 6.1: "from the index date (i.e., excluding
# index) until the end of continuous enrollment or end of study period or
# death, whichever occurs first."
#
# The cohort carries both halves: ENDDATE is min(death, study end) and
# ENDDATE_CE is where continuous enrolment stops. The earliest of the two is
# the protocol's follow-up end. ENDDATE_CE is NULL for a patient who never
# disenrolled, which is why it is coalesced rather than compared raw - a NULL
# inside least() would swallow the whole expression.
FU_END_SQL <- "least(cast(c.ENDDATE as date),
                     coalesce(cast(c.ENDDATE_CE as date), cast(c.ENDDATE as date)))"

# One row per patient per line, with the next line's start beside it. Every
# outcome below is a date difference off this, so they cannot disagree about
# when a line started or what came after it.
#
# base_tbl is the cohort build's NDMM_BASE_COHORT, which carries MM_DX_DT. The
# cohort table itself does not: its INDEX_DATE is the 1L treatment start, and
# every column on it is anchored there. NULL when there is no such table - a
# cohort built by another package has no MM diagnosis date to offer - and the
# diagnosis columns are then absent rather than guessed.
outcomes_base_sql <- function(lines_tbl, cohort_tbl, base_tbl = NULL) {
  dx_join <- if (is.null(base_tbl)) "" else glue("
    LEFT JOIN (SELECT cast(PATID as string) AS PATID,
                      cast(MM_DX_DT as date) AS MM_DX_DT
               FROM {base_tbl}) x ON x.PATID = n.PATID")
  dx_cols <- if (is.null(base_tbl))
    "cast(NULL as date) AS MM_DX_DT, cast(NULL as int) AS DX_TO_LOT1_DAYS"
  else
    # Table 4: "Time from diagnosis date (excluded) until index date
    # (included)", and the cohort's INDEX_DATE is that 1L index.
    "x.MM_DX_DT, datediff(c.INDEX_DATE, x.MM_DX_DT) AS DX_TO_LOT1_DAYS"
  glue("
    WITH coh AS (
      SELECT cast(PATID as string) AS PATID,
             cast(INDEX_DATE as date) AS INDEX_DATE,
             cast(ENDDATE as date)    AS ENDDATE,
             cast(ENDDATE_CE as date) AS ENDDATE_CE,
             cast(DEATH_DT as date)   AS DEATH_DT
      FROM {cohort_tbl}
    ),
    ln AS (
      SELECT cast(PATID as string) AS PATID,
             cast(LOT_NUM as int)  AS LOT_NUM,
             cast(LOT_START_DT as date)    AS LOT_START_DT,
             cast(LOT_BASE_END_DT as date) AS LOT_END_DT,
             LOT_BASE_END_REASON           AS LOT_END_REASON,
             LOT_BASE_MEDS                 AS REGIMEN
      FROM {lines_tbl}
    ),
    nxt AS (
      SELECT l.*,
             -- The next line this patient actually has, whatever its number:
             -- lead() over the ordered lines rather than LOT_NUM + 1, so a
             -- gap in the numbering cannot silently read as 'no next line'.
             lead(l.LOT_START_DT) OVER (PARTITION BY l.PATID ORDER BY l.LOT_NUM)
               AS NEXT_LOT_START_DT,
             lead(l.LOT_NUM) OVER (PARTITION BY l.PATID ORDER BY l.LOT_NUM)
               AS NEXT_LOT_NUM
      FROM ln l
    )
    SELECT n.PATID, n.LOT_NUM, n.LOT_START_DT, n.LOT_END_DT, n.LOT_END_REASON,
           n.REGIMEN, n.NEXT_LOT_START_DT, n.NEXT_LOT_NUM,
           c.INDEX_DATE, c.DEATH_DT,
           {dx_cols},
           {FU_END_SQL} AS FU_END_DT
    FROM nxt n INNER JOIN coh c ON c.PATID = n.PATID{dx_join}")
}

# The three outcomes off that base. Each is a date and a 0/1, not a summary:
# a median with no event flag beside it cannot be recomputed or checked, and
# the study team fits the curves.
#
# An event date at or after the follow-up end is not an event - the patient
# ran out of observation rather than reaching the outcome - so it censors.
# Written once, here, so all three treat the boundary the same way.
outcomes_tte_sql <- function(base_sql, run_id) {
  glue("
    WITH b AS ({base_sql}),
    ev AS (
      SELECT b.*,
             -- TTNT: next line or death, whichever is first.
             least(coalesce(b.NEXT_LOT_START_DT, date('9999-12-31')),
                   coalesce(b.DEATH_DT,          date('9999-12-31'))) AS TTNT_DT,
             -- TTD: the line's own end as well, per Table 4.
             least(coalesce(b.LOT_END_DT,        date('9999-12-31')),
                   coalesce(b.NEXT_LOT_START_DT, date('9999-12-31')),
                   coalesce(b.DEATH_DT,          date('9999-12-31'))) AS TTD_DT,
             coalesce(b.DEATH_DT, date('9999-12-31'))                 AS OS_DT
      FROM b
    )
    SELECT PATID, LOT_NUM, LOT_START_DT, LOT_END_DT, LOT_END_REASON, REGIMEN,
           NEXT_LOT_NUM, NEXT_LOT_START_DT, DEATH_DT, FU_END_DT,
           MM_DX_DT, DX_TO_LOT1_DAYS,

           CASE WHEN TTNT_DT < FU_END_DT THEN 1 ELSE 0 END AS TTNT_EVENT,
           datediff(least(TTNT_DT, FU_END_DT), LOT_START_DT) AS TTNT_DAYS,

           CASE WHEN TTD_DT  < FU_END_DT THEN 1 ELSE 0 END AS TTD_EVENT,
           datediff(least(TTD_DT,  FU_END_DT), LOT_START_DT) AS TTD_DAYS,

           CASE WHEN OS_DT   < FU_END_DT THEN 1 ELSE 0 END AS OS_EVENT,
           datediff(least(OS_DT,   FU_END_DT), LOT_START_DT) AS OS_DAYS,

           -- Why TTNT ended, so a curve can be read without re-deriving it.
           CASE WHEN TTNT_DT >= FU_END_DT              THEN 'CENSORED'
                WHEN NEXT_LOT_START_DT IS NOT NULL
                 AND (DEATH_DT IS NULL
                      OR NEXT_LOT_START_DT <= DEATH_DT) THEN 'NEXT_LOT'
                ELSE 'DEATH' END                        AS TTNT_REASON,
           {sql_text(run_id)}  AS OUT_RUN_ID,
           current_timestamp() AS BUILT_AT
    FROM ev
    WHERE FU_END_DT >= LOT_START_DT")
}

# Table 4, "Treatment attrition": "Number and percent of patients who received
# each subsequent LOT, discontinued treatment and did not receive another,
# were lost to follow-up, or died".
#
# The four are exclusive and ordered, because a patient can look like more than
# one: someone who starts a next line and later dies is counted as receiving
# the next line, since that is what the row is about. Death is only counted
# where no next line followed.
outcomes_attrition_sql <- function(tte_tbl) {
  glue("
    SELECT LOT_NUM,
           count(*)                                            AS N_ON_LINE,
           sum(CASE WHEN NEXT_LOT_NUM IS NOT NULL
                    THEN 1 ELSE 0 END)                         AS N_NEXT_LOT,
           sum(CASE WHEN NEXT_LOT_NUM IS NULL AND OS_EVENT = 1
                    THEN 1 ELSE 0 END)                         AS N_DIED,
           sum(CASE WHEN NEXT_LOT_NUM IS NULL AND OS_EVENT = 0
                     AND TTD_EVENT = 1
                    THEN 1 ELSE 0 END)                         AS N_DISCON_NO_NEXT,
           sum(CASE WHEN NEXT_LOT_NUM IS NULL AND OS_EVENT = 0
                     AND TTD_EVENT = 0
                    THEN 1 ELSE 0 END)                         AS N_LOST_TO_FU
    FROM {tte_tbl}
    GROUP BY LOT_NUM ORDER BY LOT_NUM")
}

# Table 4, "Time from prior LOT to next LOT initiation": "among patients
# initiating a subsequent LOT as time from prior LOT start date (excluded) to
# next LOT start date (included)". Continuous months, so days / 30.4375 - the
# mean Gregorian month, not 30, which drifts by six days a year.
outcomes_line_gap_sql <- function(tte_tbl) {
  glue("
    SELECT LOT_NUM                              AS FROM_LOT,
           NEXT_LOT_NUM                         AS TO_LOT,
           count(*)                             AS N,
           round(avg(datediff(NEXT_LOT_START_DT, LOT_START_DT)) / 30.4375, 2)
                                                AS MEAN_MONTHS,
           round(percentile_approx(
                   datediff(NEXT_LOT_START_DT, LOT_START_DT), 0.5) / 30.4375, 2)
                                                AS MEDIAN_MONTHS,
           min(datediff(NEXT_LOT_START_DT, LOT_START_DT)) AS MIN_DAYS,
           max(datediff(NEXT_LOT_START_DT, LOT_START_DT)) AS MAX_DAYS
    FROM {tte_tbl}
    WHERE NEXT_LOT_NUM IS NOT NULL
    GROUP BY LOT_NUM, NEXT_LOT_NUM ORDER BY LOT_NUM, NEXT_LOT_NUM")
}

# Table 4, "Patients receiving each line": "Number and percent of patients
# receiving each 1L, 2L, 3L, and 4L regimens". Regimen as lot recorded it -
# the SOC categories in 6.2.2 are Annex 2's and are not applied here, so this
# is the raw distribution a category map would be built against.
outcomes_regimen_sql <- function(tte_tbl) {
  glue("
    SELECT LOT_NUM, REGIMEN, count(*) AS N,
           round(100.0 * count(*) / sum(count(*)) OVER (PARTITION BY LOT_NUM), 2)
             AS PCT_OF_LINE
    FROM {tte_tbl}
    GROUP BY LOT_NUM, REGIMEN
    ORDER BY LOT_NUM, N DESC")
}

# Table 4, "Time from diagnosis to 1L initiation": "Continuous (months); Time
# from diagnosis date (excluded) until index date (included)", at the 1L index.
#
# One row per patient, so the 1L rows only - the value is the same on every
# line a patient has, and repeating it per line would weight patients by how
# many lines they reached.
outcomes_dx_to_lot1_sql <- function(tte_tbl) {
  glue("
    SELECT count(*)                                        AS N,
           round(avg(DX_TO_LOT1_DAYS) / 30.4375, 2)        AS MEAN_MONTHS,
           round(percentile_approx(DX_TO_LOT1_DAYS, 0.5) / 30.4375, 2)
                                                           AS MEDIAN_MONTHS,
           round(percentile_approx(DX_TO_LOT1_DAYS, 0.25) / 30.4375, 2)
                                                           AS Q1_MONTHS,
           round(percentile_approx(DX_TO_LOT1_DAYS, 0.75) / 30.4375, 2)
                                                           AS Q3_MONTHS,
           min(DX_TO_LOT1_DAYS)                            AS MIN_DAYS,
           max(DX_TO_LOT1_DAYS)                            AS MAX_DAYS,
           -- A 1L start before the diagnosis would be negative, which the
           -- cohort build forbids: the index is the first therapy claim ON OR
           -- AFTER the diagnosis. Counted so that stays true.
           sum(CASE WHEN DX_TO_LOT1_DAYS < 0 THEN 1 ELSE 0 END) AS N_NEGATIVE
    FROM {tte_tbl}
    WHERE LOT_NUM = 1 AND DX_TO_LOT1_DAYS IS NOT NULL")
}
