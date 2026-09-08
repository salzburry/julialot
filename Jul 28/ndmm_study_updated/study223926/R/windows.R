# The period algebra, as SQL fragments.
#
# Every window in the protocol is built here and nowhere else, so a boundary
# convention is written once. The protocol is explicit about which end of an
# interval is included and which excluded, and it REVERSED those conventions
# from the June 2026 version (../VERSION_DIFF.md section 1). Carrying the old
# ones forward shifts every duration by a day, silently, so they are named in
# the argument list rather than assumed.
#
# These emit SQL rather than computing in R because the warehouse holds the
# data; tests/test_windows.R checks the emitted text, and the arithmetic is
# checked against a reference implementation over hand-made cases.

# Days between two dates, with each endpoint declared.
#
#   from_incl  to_incl   meaning                       expression
#   TRUE       TRUE      a closed interval             datediff(to, from) + 1
#   TRUE       FALSE     time-to-event from the index  datediff(to, from)
#   FALSE      TRUE      the June 2026 convention      datediff(to, from)
#   FALSE      FALSE     neither endpoint counts       datediff(to, from) - 1
interval_days_sql <- function(from, to, from_incl = TRUE, to_incl = FALSE) {
  adj <- (if (isTRUE(from_incl)) 1L else 0L) + (if (isTRUE(to_incl)) 1L else 0L) - 1L
  base <- sprintf("datediff(%s, %s)", to, from)
  if (adj == 0L) base else sprintf("(%s %s %d)", base, if (adj > 0) "+" else "-", abs(adj))
}

# A duration reported in months. Fixed at the mean Gregorian month, because a
# reported duration is a length and not a window: two patients whose follow-up
# is the same number of days must report the same number of months whatever
# month they were indexed in. MONTHS_AS governs window CONSTRUCTION, below,
# and deliberately does not reach this.
DAYS_PER_MONTH <- 30.4375
days_to_months_sql <- function(days_expr)
  sprintf("round(cast(%s as double) / %s, 2)", days_expr, format(DAYS_PER_MONTH))

# The start of a window `n_days` (or the equivalent months) before an anchor.
# MONTHS_AS decides which, and is an open question - ../OPEN_QUESTIONS.md Q21.
window_start_sql <- function(anchor, n_days, cfg) {
  if (identical(cfg$months_as, "calendar")) {
    n_months <- round(n_days / DAYS_PER_MONTH)
    sprintf("add_months(%s, -%d)", anchor, as.integer(n_months))
  } else {
    sprintf("date_sub(%s, %d)", anchor, as.integer(n_days))
  }
}

# The baseline period for one LOT index.
#
# s7.1: "the 12-month period prior to the index date for each LOT (does not
# include index date)". s7.8.1 then says comorbidities are assessed "over the
# 12-month baseline period, including the index date". The two are not the
# same window; `include_index` is which one you are building, and the default
# for each is a setting. ../OPEN_QUESTIONS.md Q14.
baseline_window_sql <- function(anchor, cfg, include_index = NULL) {
  if (is.null(include_index)) include_index <- isTRUE(cfg$baseline_includes_index)
  list(
    start = window_start_sql(anchor, cfg$baseline_days, cfg),
    end   = if (isTRUE(include_index)) anchor else sprintf("date_sub(%s, 1)", anchor),
    includes_index = isTRUE(include_index)
  )
}

# The end of a patient's follow-up.
#
# s7.1: "from the index date (i.e., including index) until the end of
# continuous enrollment or end of study period or death, whichever occurs
# first."
#
# The LOT engine's primary reading is the opposite - LOT_RULES.md 7.6,
# "Disenrollment is not censoring" - and it carries both, so this reads
# ENDDATE_CE or ENDDATE off the cohort rather than recomputing either.
# ../OPEN_QUESTIONS.md Q13.
# `ce_end` is the end of the enrolment span covering THIS cohort's own index
# date, from S_ENROLL_SPANS. It has to be, and it used to not be: ENDDATE_CE on
# the input cohort table is the end of continuous enrolment measured from the
# 1L index, and reusing it for 2L, 3L and SEC2L gave every cohort the same
# follow-up end as 1L. A patient who lapsed after 1L and re-enrolled before 2L
# then got FU_END < INDEX_DATE - negative follow-up, negative TTNT/TTD/OS - in
# a cohort whose own MET_N2 had just certified 12 months of continuous
# enrolment before that index from the same spans. The cohort table's value is
# kept only as a fallback for a patient no span covers.
fu_end_sql <- function(cfg, ce_end = "fe.COV_END", enddate = "c.ENDDATE",
                       enddate_ce = "c.ENDDATE_CE", death = "c.DEATH_DT") {
  horizon <- if (isTRUE(cfg$censor_at_disenrollment))
    sprintf("coalesce(%s, %s, %s)", ce_end, enddate_ce, enddate) else enddate
  # least() ignores nothing: a NULL death would make the whole expression NULL,
  # so it is coalesced to the horizon first.
  sprintf("least(%s, date('%s'), coalesce(%s, %s))",
          horizon, cfg$study_end, death, horizon)
}

# The treatment period a safety event is attributed to.
#
# s7.3.2, screen 29: "An event will be attributed to a LOT if it occurs between
# the LOT's start date (included) and the start date (excluded) of a subsequent
# LOT, or discontinuation date of the prior LOT + 30 days of discontinuation,
# whichever comes first. If the patient experiences an event > 30 days after
# discontinuation, the event will not be counted (even if the patient
# eventually started a subsequent LOT)."
#
# So the window is closed at both ends here: [start, end], where end is the day
# before the next line starts, or discontinuation + 30, whichever is earlier.
# It is also clipped to the patient's follow-up end - an event cannot be
# observed after observation stopped.
lot_period_sql <- function(cfg, start = "l.LOT_START_DT",
                           next_start = "l.NEXT_LOT_START_DT",
                           discon = "l.PROTOCOL_DISCON_DT",
                           line_end = "l.LOT_BASE_END_DT",
                           fu_end = "p.FU_END") {
  # PROTOCOL_DISCON_DT, derived in 00_spine.R from the SELECTED end reason -
  # not LOT_BASE_DISCON_DT, which is the engine's candidate medication run-out
  # and can be populated while a different reason and date won the cascade.
  # 00_spine.R carries the reasoning.
  #
  # It is only populated where the line protocol-discontinued; where it is NULL
  # the line ended for another reason and its own end date bounds it.
  discon_bound <- sprintf("date_add(coalesce(%s, %s), %d)",
                          discon, line_end, as.integer(cfg$lot_post_discon_days))
  next_bound <- sprintf("date_sub(%s, 1)", next_start)
  list(
    start = start,
    end = sprintf("least(coalesce(%s, %s), %s, %s)",
                  next_bound, discon_bound, discon_bound, fu_end)
  )
}

# The time-to-event analysis set.
#
# s7.8.2, screen 48: "Outcomes will only be assessed in the subset of patients
# who have >=3 months of potential follow-up (or die before 3 months) from
# their index date".
#
# POTENTIAL follow-up: calendar time in the database, not observed enrolment.
# A patient indexed less than 90 days before the study end has not had the
# chance to be observed for 90 days, whoever they are; a patient who died
# inside 90 days has been fully observed. This is a FLAG, never a filter - the
# descriptive denominators for Objectives 1 to 3 are the whole cohort.
tte_eligible_sql <- function(cfg, index = "p.INDEX_DATE", death = "c.DEATH_DT") {
  d <- as.integer(cfg$tte_min_potential_fu_days)
  sprintf(paste0("CASE WHEN date_add(%s, %d) <= date('%s') THEN 1 ",
                 "WHEN %s IS NOT NULL AND %s < date_add(%s, %d) THEN 1 ",
                 "ELSE 0 END"),
          index, d, cfg$study_end, death, death, index, d)
}

# Person-time in years over a window, both ends included.
person_years_sql <- function(from, to, cfg)
  sprintf("cast(%s as double) / 365.25",
          interval_days_sql(from, to, from_incl = TRUE, to_incl = TRUE))

# A rate per RATE_MULTIPLIER person-years, NULL rather than a division by zero.
rate_sql <- function(events, pyears, cfg)
  sprintf("CASE WHEN %s > 0 THEN (cast(%s as double) / %s) * %d END",
          pyears, events, pyears, as.integer(cfg$rate_multiplier))

# A Poisson 95% CI on a count over person-time, on the log scale. Reported
# beside every rate; s7.8 asks for 95% CIs and names no method, so the
# conventional one is used and named here rather than in each module.
rate_ci_sql <- function(events, pyears, cfg, side = c("lo", "hi")) {
  side <- match.arg(side)
  z <- if (side == "lo") "-1.959964" else "1.959964"
  sprintf(paste0("CASE WHEN %s > 0 AND %s > 0 THEN ",
                 "exp(ln(cast(%s as double) / %s) + (%s) * (1.0 / sqrt(cast(%s as double)))) * %d END"),
          events, pyears, events, pyears, z, events, as.integer(cfg$rate_multiplier))
}

# The claim-status filter, as a WHERE fragment.
#
# MEDICAL.PAID_STATUS separates PAID from DENIED. A denied claim is not
# evidence a service happened, and counting one as an ED visit, a
# hospitalisation or a diagnosis inflates every rate built on it. Nothing in
# this package or the cohort build has ever filtered on it, so `all` is the
# default and the run records which reading it took.
#
# The V9.0 dictionary spells the values PAID and DENIED. The warehouse stores
# them as single characters - P and D - which the 03 Sep 2026 profile confirmed
# (../SQL Result 2.pdf, result 21: P 1,672,870,316 lines, D 340,788,413, no
# other value). Testing against the spelled-out word therefore excluded
# nothing, and paid_only was a silent no-op. Both encodings are matched now.
#
# NULL is not treated as denied. It is 3.9% of lines among myeloma patients
# and the dictionary says the CDM fills the field in, so a null is missing
# information rather than evidence of a denial.
claim_status_sql <- function(cfg, alias) {
  if (identical(cfg$claim_status, "paid_only"))
    sprintf("AND upper(trim(coalesce(%s.PAID_STATUS, ''))) NOT IN ('D', 'DENIED')",
            alias)
  else ""
}
