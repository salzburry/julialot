# What the narrower reading of the pregnancy window would cost, as a number
# rather than an argument.
#
# The protocol says "during the study period" and the validated program spec,
# citing an earlier section of it, says "during the baseline or follow-up
# period". This build applies the protocol's, which is the wider of the two and
# so excludes strictly more - a childbirth claim years from a patient's index
# date drops them here and would not there. See DECISIONS.md #9.
#
# Its own file, beside the criterion it prices. It lived in 00b_lot1_index.R
# for a while because that file is outside the April port comparison, which is
# a reason about tooling and not about where pregnancy logic belongs.
#
# One scan serves both windows, because the study period contains the
# patient-relative one: the narrower rule is a filter on the same matched
# events, not a second pass over the claims.

# Whether a patient's claim falls in the window the row is about. One
# definition, used by all three columns: the kept count is the negation of the
# excluded count, and they have to be negations of the SAME thing.
preg_hit_sql <- function()
  paste0("((w.which = 'study'   AND ev.w_study   = 1)",
         " OR (w.which = 'patient' AND ev.w_patient = 1))")

build_ndmm_preg_window_counts <- function(con, cfg) {
  db_exec(con, glue("
    CREATE OR REPLACE TABLE {wrk('NDMM_PREG_WINDOW_COUNTS')} AS
    WITH idx AS (
      SELECT l1.PATID, l1.LOT1_START_DT,
             -- Follow-up ends at the study end or death, whichever comes
             -- first, the same way the cohort clamps ENDDATE.
             least(date('{cfg$study_end}'),
                   coalesce(b.DEATH_DT, date('{cfg$study_end}'))) AS fu_end
      FROM {NDMM_LOT1_STARTS} l1
      INNER JOIN {NDMM_BASE_COHORT} b ON b.PATID = l1.PATID
    ),
    -- Every indexed patient gets a row, whether or not they have an event.
    --
    -- The LEFT JOIN is INSIDE this aggregate for that reason, and it is the
    -- whole correctness of the table. Built the other way round - events
    -- grouped first, then left-joined to patients - the flags are NULL for a
    -- patient with no pregnancy claim, NOT(NULL) is NULL, and
    -- CASE WHEN NULL THEN PATID END counts nobody. Every patient without a
    -- pregnancy claim then vanished from both cohort columns and the applied
    -- row reported a cohort of zero, which is the one number nobody would read
    -- as a bug in the table rather than a finding about the study.
    ev AS (
      SELECT idx.PATID,
             max(CASE WHEN e.PATID IS NOT NULL THEN 1 ELSE 0 END) AS w_study,
             max(CASE WHEN e.event_dt >= date_sub(idx.LOT1_START_DT,
                                                  {NDMM_PRE_LOT1_DAYS})
                       AND e.event_dt <= idx.fu_end
                      THEN 1 ELSE 0 END)                          AS w_patient
      FROM idx
      LEFT JOIN {NDMM_PREGNANCY_EVENTS} e ON e.PATID = idx.PATID
      GROUP BY idx.PATID
    ),
    w AS (SELECT * FROM (VALUES
      (1, 'study period (this run)', 'study'),
      (2, 'baseline + follow-up',    'patient')
    ) AS t(sort_key, rule, which))
    SELECT w.rule                                          AS PREG_WINDOW_RULE,
           -- Indexed candidates with a claim in that window. NOT the number
           -- excluded: a patient who already fails continuous enrolment or
           -- prior therapy is not additionally excluded by pregnancy, so
           -- labelling this as the excluded count overstated the effect.
           count(DISTINCT CASE WHEN {preg_hit_sql()} THEN ev.PATID END)
                                                           AS N_WITH_PREG_CLAIM,
           -- What this criterion actually removes: patients it drops who would
           -- otherwise be in the cohort. This is the incremental effect, and
           -- the difference between the two rows of THIS column is what the
           -- window decision costs.
           count(DISTINCT CASE WHEN {preg_hit_sql()}
                                AND {ndmm_criteria_where(except = 'NO_PREGNANCY', alias = 'f.')}
                               THEN ev.PATID END)          AS N_EXCL_INCREMENTAL,
           -- The whole conjunction with this criterion recomputed per window,
           -- so the row is a cohort size rather than one criterion's count -
           -- the same shape NDMM_FU_CE_COUNTS uses.
           count(DISTINCT CASE WHEN NOT ({preg_hit_sql()})
                                AND {ndmm_criteria_where(except = 'NO_PREGNANCY', alias = 'f.')}
                               THEN ev.PATID END)          AS N_COHORT,
           max(CASE WHEN w.which = 'study' THEN 1 ELSE 0 END)
                                                           AS IS_THIS_RUN
    FROM ev
    CROSS JOIN w
    INNER JOIN {NDMM_FLAGS_ALL} f ON f.PATID = ev.PATID
    GROUP BY w.rule, w.sort_key
    ORDER BY w.sort_key"))
  got <- db_q(con, glue("SELECT * FROM {wrk('NDMM_PREG_WINDOW_COUNTS')}"))
  log_msg("Pregnancy (criterion 8), by window. This run applies the protocol's ",
          "study period; the program spec says baseline + follow-up.")
  for (i in seq_len(nrow(got)))
    log_msg("    ", if (got$IS_THIS_RUN[i] == 1L) "->" else "  ", " ",
            got$PREG_WINDOW_RULE[i], ": ",
            format(got$N_WITH_PREG_CLAIM[i], big.mark = ","),
            " indexed candidates carry a claim, ",
            format(got$N_EXCL_INCREMENTAL[i], big.mark = ","),
            " of them are excluded by it alone, cohort ",
            format(got$N_COHORT[i], big.mark = ","))
  check_preg_window_counts(got)
  log_msg("  The gap between the two cohort figures is what the wider reading ",
          "costs. See DECISIONS.md #9 - the window is pending sign-off.")
  invisible(got)
}

# Invariants the numbers have to satisfy whatever the data says. The defect
# this catches produced a cohort of zero on the applied row while every other
# column looked sane, so it is checked on the values rather than only on the
# SQL that made them.
check_preg_window_counts <- function(got) {
  bad <- character(0)
  if (nrow(got) != 2L)
    bad <- c(bad, paste0("expected one row per window, got ", nrow(got)))
  else {
    st <- got[got$IS_THIS_RUN == 1L, , drop = FALSE]
    pt <- got[got$IS_THIS_RUN == 0L, , drop = FALSE]
    if (nrow(st) != 1L || nrow(pt) != 1L)
      bad <- c(bad, "exactly one row has to be the applied one")
    else {
      # Removing the criterion entirely gives one number, and each window has
      # to partition the same population into kept and excluded.
      tot <- c(st$N_COHORT + st$N_EXCL_INCREMENTAL,
               pt$N_COHORT + pt$N_EXCL_INCREMENTAL)
      if (tot[1] != tot[2])
        bad <- c(bad, paste0("the two windows do not partition the same ",
                             "population: ", tot[1], " vs ", tot[2],
                             ". Kept + excluded is the cohort with this ",
                             "criterion removed, which does not depend on the ",
                             "window."))
      # The study period contains the patient window, so it can only exclude
      # more and leave fewer.
      if (pt$N_COHORT < st$N_COHORT)
        bad <- c(bad, paste0("the narrower window left a SMALLER cohort (",
                             pt$N_COHORT, " < ", st$N_COHORT,
                             "), which the containment makes impossible."))
      if (pt$N_WITH_PREG_CLAIM > st$N_WITH_PREG_CLAIM)
        bad <- c(bad, paste0("more claims inside the patient window (",
                             pt$N_WITH_PREG_CLAIM, ") than in the study period (",
                             st$N_WITH_PREG_CLAIM, "), which contains it."))
    }
  }
  if (length(bad))
    stop("NDMM_PREG_WINDOW_COUNTS is not internally consistent, so it cannot ",
         "price the decision it exists for:\n  ", paste(bad, collapse = "\n  "),
         call. = FALSE)
  invisible(TRUE)
}
