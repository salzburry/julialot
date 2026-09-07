# How an event is counted, and how much person-time it is counted against.
#
# s7.8.1 states four rules and they are the whole of this file:
#
#   1. "Multiple claims occurring on the same day will be treated as a single
#      event. Events identified on claims occurring more than 1 day apart will
#      be considered distinct events."
#   2. Baseline prevalence: "The denominator will represent the total amount of
#      PY present in the baseline period... IRRESPECTIVE OF PRIOR EVENT
#      HISTORY."
#   3. Incidence, chronic: "only the first occurrence of the condition will be
#      considered an incident event. Individuals with a documented history of
#      the chronic condition prior to the treatment period will not be
#      considered at risk and will be EXCLUDED FROM BOTH THE NUMERATOR AND THE
#      PERSON-TIME DENOMINATOR for that condition."
#   4. Incidence, acute: "each new event occurring during the treatment period
#      will be counted as an incident event", with "a >=30 day washout between
#      acute events of the same type".
#
# Rule 2 and rule 3 have different denominators. A module that computes one
# denominator and uses it for both is wrong in a way no total will reveal.

# The nine s7.8.1 names as read from screen 44: "Chronic events that should
# only be captured once, at first instance: Chronic kidney disease, Moderate to
# severe renal impairment or end stage renal disease, Pulmonary hypertension,
# Peripheral neuropathy, Parkinson's disease, Other movement disorders,
# malignancies, Thrombocytopenia, Anemia".
#
# Table 3 marks more conditions chronic than this list names (fibrosis and
# cirrhosis, non-alcoholic steatohepatitis). The code list's own
# `acute_chronic` column is the authority, because it comes from the same annex
# as the codes; this list is a cross-check that catches a mistyped column, not
# a second definition.
PROTOCOL_CHRONIC_CONDITIONS <- c(
  "chronic_kidney_disease",
  "moderate_to_severe_renal_impairment_or_esrd",
  "pulmonary_hypertension",
  "peripheral_neuropathy",
  "parkinsons_disease",
  "other_movement_disorders",
  "thrombocytopenia",
  "anemia",
  # Objective 3's own condition. Screen 44 names "malignancies" in the same
  # list; without it the cross-check cannot catch a secondary_malig.csv that
  # types the condition acute, which would count every recurrence.
  "malignancies"
)

# Stops on a condition s7.8.1 names as chronic that the code list types acute.
# The reverse is allowed: Table 3 is wider than the s7.8.1 list.
assert_chronic_set <- function(codelist, condition_col = "condition",
                               type_col = "acute_chronic") {
  have <- unique(trimws(tolower(as.character(codelist[[condition_col]]))))
  typed <- tolower(as.character(codelist[[type_col]]))
  named <- intersect(PROTOCOL_CHRONIC_CONDITIONS, have)
  wrong <- character(0)
  for (cond in named) {
    t <- unique(typed[trimws(tolower(as.character(codelist[[condition_col]]))) == cond])
    if (!any(grepl("chronic", t))) wrong <- c(wrong, paste0(cond, " (typed: ",
                                                            paste(t, collapse = "/"), ")"))
  }
  if (length(wrong))
    stop("CODELIST ERROR: s7.8.1 names these as chronic - only the first ",
         "occurrence counts and a prior history removes the patient from the ",
         "denominator - but the code list types them otherwise:\n  ",
         paste(wrong, collapse = "\n  "),
         "\nTyped acute, each recurrence would be counted and no patient would ",
         "ever leave the denominator. Fix the column or say why it differs.",
         call. = FALSE)
  missing <- setdiff(PROTOCOL_CHRONIC_CONDITIONS, have)
  if (length(missing))
    message("[person_time] s7.8.1 names ", length(missing),
            " chronic condition(s) the code list does not carry: ",
            paste(missing, collapse = ", "),
            ". Check the naming before reading a rate for them.")
  invisible(TRUE)
}

# Rule 1 - the same-day collapse - is not here. It is a DISTINCT on the event
# select in 06_safety.R and 08_malignancy.R, because it has to happen where the
# claim rows are read and cannot be applied afterwards.
#
# There was a distinct_event_dates_sql() here that expressed the rule and that
# no module called. Deleting it: a helper that states a protocol rule and is
# wired to nothing reads, to anyone checking, as the rule being applied
# centrally - and mutating it breaks no test, because nothing runs it.

# Rule 3, first half. Patients with the condition before their treatment
# period - not at risk, so out of the numerator AND the denominator.
chronic_prior_history_sql <- function(events, periods, out) {
  sprintf("CREATE OR REPLACE TEMPORARY VIEW %s AS
    SELECT DISTINCT p.PATID, p.COHORT, p.LOT_NUM, e.CONDITION
    FROM %s p
    INNER JOIN %s e
      ON e.PATID = p.PATID
     -- On COHORT as well as PATID. Both tables carry every cohort, so without
     -- it this is a k-fold cross product per patient before the DISTINCT -
     -- and it is only accidentally right today, because the event table
     -- happens to hold the same rows under every cohort tag.
     AND e.COHORT = p.COHORT
     AND e.EVENT_DT < p.PERIOD_START", out, periods, events)
}

# Rule 4. One round of the washout chain.
#
# The washout is between COUNTED events, not between observed ones, so it
# cannot be done with lag(): events on days 0, 20 and 40 with a 30-day washout
# are two counted events (0 and 40), and lag() gives one, because it compares
# each event with its predecessor rather than with the last one that counted.
#
# Each round adds the earliest still-eligible event per patient and condition,
# so the number of rounds needed is the largest number of counted events any
# one patient has for any one condition. run_acute_washout() loops until a
# round adds nothing.
acute_washout_round_sql <- function(events, periods, counted, cfg,
                                    period_label = "TREATMENT") {
  w <- as.integer(cfg$acute_washout_days)
  sprintf("
    INSERT INTO %s
    SELECT PATID, COHORT, LOT_NUM, '%s' AS PERIOD, CONDITION, EVENT_DT
    FROM (
      SELECT e.PATID, p.COHORT, p.LOT_NUM, e.CONDITION, e.EVENT_DT,
             row_number() OVER (PARTITION BY e.PATID, p.COHORT, p.LOT_NUM, e.CONDITION
                                ORDER BY e.EVENT_DT) AS rn
      FROM %s e
      INNER JOIN %s p
        ON p.PATID = e.PATID
       AND e.EVENT_DT BETWEEN p.PERIOD_START AND p.PERIOD_END
      LEFT JOIN %s c
        ON c.PATID = e.PATID AND c.COHORT = p.COHORT
       AND c.LOT_NUM = p.LOT_NUM AND c.CONDITION = e.CONDITION
       AND c.PERIOD = '%s' AND c.EVENT_DT = e.EVENT_DT
      WHERE c.PATID IS NULL
        AND NOT EXISTS (
          SELECT 1 FROM %s c2
          WHERE c2.PATID = e.PATID AND c2.COHORT = p.COHORT
            AND c2.LOT_NUM = p.LOT_NUM AND c2.CONDITION = e.CONDITION
            AND c2.PERIOD = '%s'
            AND datediff(e.EVENT_DT, c2.EVENT_DT) < %d
            AND c2.EVENT_DT <= e.EVENT_DT
        )
    ) t
    WHERE rn = 1", counted, period_label, events, periods, counted,
          period_label, counted, period_label, w)
}

# The loop. Bounded, because an unbounded loop against a warehouse is a way to
# spend a night; the bound is generous and being hit is a finding, not a
# tuning problem.
run_acute_washout <- function(con, events, periods, counted, cfg,
                              period_label = "TREATMENT", max_rounds = 60L) {
  n_sql <- sprintf("SELECT count(*) AS n FROM %s WHERE PERIOD = '%s'",
                   counted, period_label)
  for (i in seq_len(max_rounds)) {
    before <- db_q(con, n_sql)$n[1]
    db_exec(con, acute_washout_round_sql(events, periods, counted, cfg,
                                         period_label))
    after <- db_q(con, n_sql)$n[1]
    log_msg("  washout round ", i, ": ", after - before, " event(s) counted")
    if (after == before) return(invisible(i))
  }
  stop("PERSON-TIME ERROR: the acute washout chain had not converged after ",
       max_rounds, " rounds, so at least one patient has more than that many ",
       "counted events of one type in one treatment period. That is not a ",
       "tuning problem - read the events before raising the bound.",
       call. = FALSE)
}

# A reference implementation of the same rule, over vectors, used by
# tests/test_person_time.R. Two implementations of one rule is a cost; the
# alternative is a SQL loop nothing checks.
count_acute_greedy <- function(dates, washout_days) {
  d <- sort(unique(as.Date(dates)))
  if (!length(d)) return(as.Date(character(0)))
  # Indices, not the dates themselves: `for (x in some_dates)` iterates over
  # the underlying numerics and drops the class.
  keep <- 1L
  last <- 1L
  for (i in seq_along(d)[-1]) {
    if (as.integer(d[i] - d[last]) >= washout_days) {
      keep <- c(keep, i)
      last <- i
    }
  }
  d[keep]
}

# The single-pass alternative, for comparison in a sensitivity. Named so that
# a run using it says so.
count_acute_lag <- function(dates, washout_days) {
  d <- sort(unique(as.Date(dates)))
  if (!length(d)) return(as.Date(character(0)))
  gaps <- c(Inf, as.integer(diff(d)))
  d[gaps >= washout_days]
}
