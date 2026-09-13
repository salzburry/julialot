# The arithmetic in R/windows.R and R/person_time.R, executed.
#
# Every other executable check in this suite runs the whole emitted script over
# tests/fixtures/cdm and reads golden numbers off the finished tables. That is
# the right shape for the counting rules, and it cannot reach these: the fixture
# is seven patients, so every stratum falls under the 25-patient floor and every
# rate is suppressed to NULL before anything can look at it. A wrong rate
# formula, a 90% confidence interval, swapped bounds or a time-to-event boundary
# off by a day are all invisible that way.
#
# So each fragment is run on its own, over rows built for the rule it states.
# The expected values are worked out here from the protocol section the
# fragment cites, not read back off a run.

FRAG_SCHEMA <- list(
  # One row per case, so an expression can be evaluated against named inputs.
  d = list(table = "d", columns = c(
    ID = "VARCHAR", A = "DATE", B = "DATE", EV = "INTEGER", PY = "DOUBLE",
    PAID_STATUS = "VARCHAR")),

  # The washout's three tables, in the shape acute_washout_round_sql() reads.
  ev = list(table = "ev", columns = c(
    PATID = "VARCHAR", CONDITION = "VARCHAR", EVENT_DT = "DATE")),
  pe = list(table = "pe", columns = c(
    PATID = "VARCHAR", COHORT = "VARCHAR", LOT_NUM = "INTEGER",
    PERIOD_START = "DATE", PERIOD_END = "DATE")),
  ct = list(table = "ct", columns = c(
    PATID = "VARCHAR", COHORT = "VARCHAR", LOT_NUM = "INTEGER",
    PERIOD = "VARCHAR", CONDITION = "VARCHAR", EVENT_DT = "DATE")))

.fr <- function(id, a = NA, b = NA, ev = NA, py = NA, paid = NA)
  list(ID = id, A = a, B = b, EV = ev, PY = py, PAID_STATUS = paid)

# ---- the rows every fragment is evaluated over ------------------------------
#
#   R1  a one-day interval: A and B the same date
#   R2  ten days apart
#   R3  four events over TWO person-years - not one, because at one person-year
#       events/PY and events*PY are the same number and the rate formula could
#       be either
#   R4  four events over no person-time at all
#   R5  a patient indexed exactly 90 days before the study end
#   R6  ...one day later, so 90 days of potential follow-up is not reached
#   R7  ...the same, but dead before day 90
#   R8  a claim the warehouse marked denied with its one-letter code
#   R9  ...with the spelled-out word
#   R10 ...with nothing recorded, which is missing information, not a denial
#   R11 an anchor whose 365-day window and 12-calendar-month window differ
#   R12 enrolled to 2026, dead in 2020 - the death is what ends follow-up
#   R13 enrolled past the study end, so the study end is what ends it
FRAG_ROWS <- list(
  .fr("R1",  a = "2020-01-01", b = "2020-01-01"),
  .fr("R2",  a = "2020-01-01", b = "2020-01-11"),
  .fr("R3",  ev = 4L, py = 2),
  .fr("R4",  ev = 4L, py = 0),
  .fr("R5",  a = "2025-12-31", b = NA),
  .fr("R6",  a = "2026-01-01", b = NA),
  .fr("R7",  a = "2026-01-01", b = "2026-02-01"),
  .fr("R8",  paid = "D"),
  .fr("R9",  paid = "DENIED"),
  .fr("R10", paid = NA),
  .fr("R11", a = "2020-06-01"),
  .fr("R12", a = "2026-03-01", b = "2020-05-01"),
  .fr("R13", a = "2030-01-01"))

# ---- what each fragment must return -----------------------------------------
# Each entry: the SQL to evaluate, and the ID -> value the rule requires.
#
# `sql` is built by the fragment under test, never written out here - the point
# is to run the shipped expression.
frag_cases <- function(cfg) list(

  # s7.1 and s7.8.1 are explicit about which endpoint counts, and the June 2026
  # version REVERSED them, so each combination is stated.
  closed = list(
    sql = interval_days_sql("A", "B", from_incl = TRUE,  to_incl = TRUE),
    want = c(R1 = 1, R2 = 11)),
  from_index = list(
    sql = interval_days_sql("A", "B", from_incl = TRUE,  to_incl = FALSE),
    want = c(R1 = 0, R2 = 10)),
  june_2026 = list(
    sql = interval_days_sql("A", "B", from_incl = FALSE, to_incl = TRUE),
    want = c(R1 = 0, R2 = 10)),
  open = list(
    sql = interval_days_sql("A", "B", from_incl = FALSE, to_incl = FALSE),
    want = c(R1 = -1, R2 = 9)),

  # The mean Gregorian month, 30.4375 days. A duration is a LENGTH: two
  # patients followed the same number of days must report the same number of
  # months whichever month they were indexed in. 365 days / 30.4375 = 11.99,
  # and 30 days is 0.99 of a month rather than 1.
  months_365 = list(sql = days_to_months_sql("365"), want = c(R1 = 11.99)),
  months_30  = list(sql = days_to_months_sql("30"),  want = c(R1 = 0.99)),
  months_31  = list(sql = days_to_months_sql("31"),  want = c(R1 = 1.02)),

  # Person-time in years, both ends included, over 365.25 days.
  # A one-day interval is 1/365.25 = 0.0027; ten days apart is 11/365.25.
  py_one = list(sql = sprintf("round(%s, 6)", person_years_sql("A", "B", cfg)),
                want = c(R1 = round(1 / 365.25, 6),
                         R2 = round(11 / 365.25, 6))),

  # RATE = events / person-years * RATE_MULTIPLIER. Four events over two
  # person-years at a multiplier of 100,000 is 200,000 - and the person-time
  # is two rather than one on purpose: at one, a division and a multiplication
  # give the same answer, and the formula could be either.
  rate_value = list(
    sql = sprintf("round(%s, 4)", rate_sql("EV", "PY", cfg)),
    want = stats::setNames(
      list(4 / 2 * as.integer(cfg$rate_multiplier), NULL), c("R3", "R4"))),
  # Zero person-time is no rate, not a division by zero and not a zero rate.
  #
  # The OUTCOME, not the guard: both Spark and DuckDB return NULL for x/0 with
  # ANSI mode off, so removing the `> 0` test alone changes nothing either
  # engine would show. The guard says what is meant and the engines agree with
  # it; what this holds is that a zero-person-time stratum publishes no rate,
  # whichever of the two is doing the work.
  rate_zero_py = list(
    sql = sprintf("CASE WHEN %s IS NULL THEN 'null' ELSE 'a number' END",
                  rate_sql("EV", "PY", cfg)),
    want = c(R3 = "a number", R4 = "null")),

  # The Poisson interval on the log scale. ln(HI) - ln(RATE) is exactly
  # z / sqrt(events) whatever the person-time is, so the z and the side are
  # pinned without the rate having to be. z is 1.959964 for 95%; four events
  # give 1.959964 / 2 = 0.979982.
  ci_upper_gap = list(
    sql = sprintf("round(ln(%s) - ln(%s), 6)",
                  rate_ci_sql("EV", "PY", cfg, "hi"), rate_sql("EV", "PY", cfg)),
    want = c(R3 = 0.979982)),
  ci_lower_gap = list(
    sql = sprintf("round(ln(%s) - ln(%s), 6)",
                  rate_sql("EV", "PY", cfg), rate_ci_sql("EV", "PY", cfg, "lo")),
    want = c(R3 = 0.979982)),
  ci_ordered = list(
    sql = sprintf("CASE WHEN %s < %s AND %s < %s THEN 'lo<rate<hi' ELSE 'wrong way round' END",
                  rate_ci_sql("EV", "PY", cfg, "lo"), rate_sql("EV", "PY", cfg),
                  rate_sql("EV", "PY", cfg), rate_ci_sql("EV", "PY", cfg, "hi")),
    want = c(R3 = "lo<rate<hi")),

  # s7.8.2: ">=3 months of potential follow-up (or die before 3 months)".
  # POTENTIAL follow-up is calendar time to the study end, so a patient
  # indexed exactly TTE_MIN_POTENTIAL_FU_DAYS before it is in, one day later
  # is out, and one who died inside the window is in however late they were
  # indexed. R5 is the boundary the ">=" is about.
  tte = list(
    sql = tte_eligible_sql(cfg, index = "A", death = "B"),
    want = c(R5 = 1, R6 = 0, R7 = 1)),

  # A denied claim is not evidence a service happened. The dictionary spells
  # the values out and the warehouse stores one letter, so both are matched;
  # testing only the word excluded nothing and made paid_only a silent no-op.
  # NULL is missing information, not a denial.
  paid_only = list(
    sql = sprintf("CASE WHEN 1 = 1 %s THEN 'kept' ELSE 'dropped' END",
                  claim_status_sql(list(claim_status = "paid_only"), "d")),
    want = c(R8 = "dropped", R9 = "dropped", R10 = "kept")),
  claim_all = list(
    sql = sprintf("CASE WHEN 1 = 1 %s THEN 'kept' ELSE 'dropped' END",
                  claim_status_sql(list(claim_status = "all"), "d")),
    want = c(R8 = "kept", R9 = "kept", R10 = "kept")),

  # MONTHS_AS: a 12-month window is 365 days by default and 12 calendar months
  # when asked for. The two coincide unless the span crosses a leap day, which
  # is why the anchor is June and not January - from 2020-01-01 both land on
  # 2019-01-01 and the fixture could not tell the settings apart. Back from
  # 2020-06-01 the 365 days reach over 2020-02-29, so they stop a day later
  # than the twelve calendar months do.
  window_days = list(
    sql = sprintf("cast(cast(%s as date) as string)",
                  window_start_sql("A", 365, list(months_as = "fixed"))),
    want = c(R11 = "2019-06-02")),
  window_calendar = list(
    sql = sprintf("cast(cast(%s as date) as string)",
                  window_start_sql("A", 365, list(months_as = "calendar"))),
    want = c(R11 = "2019-06-01")),

  # s7.1: follow-up runs "until the end of continuous enrolment or end of
  # study period or death, whichever occurs first". Three arms, and each has
  # to be the one that binds on the row built for it. A NULL death must not
  # make the whole expression NULL, which is why it is coalesced first.
  fu_end = list(
    sql = sprintf("cast(cast(%s as date) as string)",
                  fu_end_sql(cfg, ce_end = "A", enddate = "A",
                             enddate_ce = "A", death = "B")),
    want = c(R5  = "2025-12-31",   # enrolment ends first, and no death
             R12 = "2020-05-01",   # death, six years before enrolment ends
             R13 = "2026-03-31"))) # enrolled past the study end

# ---- the washout ------------------------------------------------------------
#
# Rule 4, s7.3.1: an acute event is incident again after a >=30 day washout
# from the last COUNTED event. Days 0, 20 and 40 are TWO counted events, not
# three: day 40 is 40 days from day 0, but only 20 from day 20 - and day 20
# never counted, so it is day 0 that day 40 is measured against.
#
# That is the difference between the chain and a lag(), and it is why the
# round is run until it adds nothing. A single round counts only the first
# event per patient and condition.
WASHOUT_EVENTS <- list(
  list(PATID = "W1", CONDITION = "c", EVENT_DT = "2020-01-01"),  # counted
  list(PATID = "W1", CONDITION = "c", EVENT_DT = "2020-01-21"),  # 20 days: no
  list(PATID = "W1", CONDITION = "c", EVENT_DT = "2020-02-10"),  # 40 days: yes
  list(PATID = "W1", CONDITION = "c", EVENT_DT = "2020-03-11"),  # 30 more: yes
  # Outside the period entirely, on both sides.
  list(PATID = "W1", CONDITION = "c", EVENT_DT = "2019-12-01"),
  list(PATID = "W1", CONDITION = "c", EVENT_DT = "2020-12-01"))

WASHOUT_PERIODS <- list(
  list(PATID = "W1", COHORT = "1L", LOT_NUM = 1L,
       PERIOD_START = "2020-01-01", PERIOD_END = "2020-06-30"))

# Days 1 Jan, 10 Feb and 11 Mar. Three counted events, and the run needs more
# than one round to find them: each round adds the earliest still-eligible one.
WASHOUT_EXPECT <- c("2020-01-01", "2020-02-10", "2020-03-11")

# The same rule over vectors, on four dates rather than three.
#
# Three cannot separate the chain from a lag: with days 0, 20 and 40 both
# readings of "the last counted event" happen to give the same answer for day
# 40. A fourth at day 60 does separate them - measured from day 40, which
# counted, it is 20 days and does not count; measured from day 20, which did
# not, it is 40 days and would.
WASHOUT_VECTOR <- as.Date(c("2020-01-01", "2020-01-21", "2020-02-10",
                            "2020-03-01"))
WASHOUT_VECTOR_KEPT <- as.Date(c("2020-01-01", "2020-02-10"))

# ---- running them -----------------------------------------------------------
.frag_json_val <- function(n, v) {
  if (is.null(v) || (length(v) == 1L && is.na(v))) sprintf('"%s":null', n)
  else if (is.numeric(v)) sprintf('"%s":%s', n, format(v, scientific = FALSE))
  else sprintf('"%s":"%s"', n, v)
}

.frag_json_rows <- function(rows, cols)
  paste(vapply(rows, function(r)
    paste0("{", paste(vapply(names(cols), function(n) .frag_json_val(n, r[[n]]),
                             character(1)), collapse = ","), "}"),
    character(1)), collapse = ",")

.frag_json_str <- function(s)
  gsub("\n", "\\\\n", gsub('"', '\\\\"', gsub("\\\\", "\\\\\\\\", s)))

# Returns id / row / col / value, or "skip" without duckdb and sqlglot.
run_fragments <- function(queries, rows, schema = FRAG_SCHEMA, root = ".") {
  py <- file.path(root, "tests", "run_expr.py")
  if (!file.exists(py)) return(NULL)
  tabs <- paste(vapply(names(schema), function(k) {
    cols <- schema[[k]]$columns
    sprintf('"%s":{"columns":{%s},"rows":[%s]}', schema[[k]]$table,
            paste(sprintf('"%s":"%s"', names(cols), cols), collapse = ","),
            .frag_json_rows(rows[[k]] %||% list(), cols))
  }, character(1)), collapse = ",")
  qs <- paste(vapply(names(queries), function(id)
    sprintf('{"id":"%s","sql":"%s"}', id, .frag_json_str(queries[[id]])),
    character(1)), collapse = ",")
  f <- tempfile(fileext = ".json")
  writeLines(sprintf('{"tables":{%s},"queries":[%s]}', tabs, qs), f)
  out <- suppressWarnings(system2("python3", c(shQuote(py), shQuote(f)),
                                  stdout = TRUE, stderr = TRUE))
  unlink(f)
  if (!length(out)) return(NULL)
  if (grepl("^SKIP", out[1])) return("skip")
  out <- out[nzchar(trimws(out))]
  if (!length(out)) return(NULL)
  do.call(rbind, lapply(out, function(l) {
    p <- strsplit(l, "\t", fixed = TRUE)[[1]]
    length(p) <- 4L; p[is.na(p)] <- ""
    data.frame(id = p[1], row = p[2], col = p[3], value = p[4],
               stringsAsFactors = FALSE)
  }))
}

frag_errors <- function(res) {
  if (is.null(res) || identical(res, "skip")) return(character(0))
  bad <- res[res$row == "ERROR", , drop = FALSE]
  if (!nrow(bad)) return(character(0))
  paste0(bad$id, ": ", bad$col)
}
