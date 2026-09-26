# The statistics a shell row may ask for, and nothing else.
#
# Each one is a function of numbers already read from a study table: a cell is
# a summary of a population, never a new clinical derivation. Every one returns
# the same shape - the value, its parts, the count it was computed from and the
# denominator the disclosure rule tests - so R/suppress.R can withhold a cell
# without knowing which statistic made it.
#
# Kaplan-Meier is written out below rather than taken from a survival package,
# because this folder must run wherever the study package runs. The estimator,
# the median and the log-log band are the same ones the dashboard uses, so a
# shell cell and the same figure on a page cannot disagree about a tie, a
# censoring at the last event time, or a cohort with no event at all.

TFLS_STATS <- c("n_pct", "mean_sd", "median_iqr", "min_max", "n", "n_distinct",
                "rate", "km_median", "km_prob", "km_events", "km_censored")

# The three that print values of the column they summarise, not a count: a
# mean, a median and its quartiles, the smallest and the largest. An
# identifier is never one of their columns (shells.R, check_row_arguments()).
TFLS_VALUE_STATS <- c("mean_sd", "median_iqr", "min_max")

# The four that read a curve. Their measure names an endpoint rather than a
# column, so the columns behind it are resolved in km_columns().
TFLS_KM_STATS <- c("km_median", "km_prob", "km_events", "km_censored")

tfls_stat_names <- function() TFLS_STATS

# What each statistic needs from the population, so a runner can say what a row
# would read before anything is read.
TFLS_STAT_NEEDS <- c(
  n_pct = "a count and the population it is out of",
  n = "a count",
  n_distinct = "a column, whose distinct values are counted",
  mean_sd = "a numeric column",
  median_iqr = "a numeric column",
  min_max = "a numeric column",
  rate = "a rate, or the events and person-years behind one",
  km_median = "a time and an event flag",
  km_prob = "a time, an event flag and a month",
  km_events = "an event flag",
  km_censored = "a time and an event flag")

# --- printing ---------------------------------------------------------------

fmt_count <- function(x) {
  n <- suppressWarnings(as.numeric(x))
  if (length(n) != 1L || is.na(n)) return("")
  formatC(n, format = "d", big.mark = ",")
}

fmt_dec <- function(x, digits = 1) {
  n <- suppressWarnings(as.numeric(x))
  if (length(n) != 1L || is.na(n)) return("")
  formatC(n, format = "f", digits = digits, big.mark = ",")
}

# A count and its share of the population, where the population is known. The
# shells ask for events and censorings as "n (%)", and the percentage is of the
# people the curve was drawn over.
count_pct_text <- function(n, denom) {
  d <- suppressWarnings(as.numeric(denom))[1]
  if (is.na(d) || d <= 0) return(fmt_count(n))
  paste0(fmt_count(n), " (", fmt_dec(100 * n / d, 1), "%)")
}

# The shape every statistic returns.
#
#   value/low/high  the number and, where the statistic has one, its parts
#   n               the count the cell is built on
#   denom           the population the floor is tested against
#   text            how it prints before suppression
#   ok/why          FALSE where the inputs could not make this statistic
#   kind            whose gap that is - see TFLS_REASON_KINDS in R/fill.R
stat_cell <- function(stat, value = NA_real_, low = NA_real_, high = NA_real_,
                      n = NA_real_, denom = NA_real_, text = "",
                      ok = TRUE, why = "", kind = "") {
  list(stat = stat, value = as.numeric(value), low = as.numeric(low),
       high = as.numeric(high), n = as.numeric(n), denom = as.numeric(denom),
       text = text, ok = ok, why = why, kind = kind)
}

stat_refused <- function(stat, why, kind = "not_computable")
  stat_cell(stat, ok = FALSE, why = why, kind = kind)

# --- counts -----------------------------------------------------------------

# `hit` is either the rows that meet the row's measure, as TRUE/FALSE, or the
# count itself where the study table already counted them.
count_of <- function(hit) {
  if (is.logical(hit)) return(sum(hit, na.rm = TRUE))
  v <- suppressWarnings(as.numeric(hit))
  if (length(v) == 1L) return(v)
  sum(v, na.rm = TRUE)
}

stat_n_pct <- function(hit, denom = NA) {
  n <- count_of(hit)
  d <- suppressWarnings(as.numeric(denom))
  if (is.logical(hit) && (length(d) != 1L || is.na(d))) d <- length(hit)
  pct <- if (length(d) == 1L && !is.na(d) && d > 0) 100 * n / d else NA_real_
  stat_cell("n_pct", value = n, low = pct, n = n, denom = d,
            text = if (is.na(pct)) fmt_count(n)
                   else paste0(fmt_count(n), " (", fmt_dec(pct, 1), "%)"))
}

stat_n <- function(hit, denom = NA) {
  n <- count_of(hit)
  d <- suppressWarnings(as.numeric(denom))
  if (is.logical(hit) && (length(d) != 1L || is.na(d))) d <- length(hit)
  stat_cell("n", value = n, n = n, denom = d, text = fmt_count(n))
}

# How many different values a column takes, which is a different question from
# how many patients hold them: a hundred patients on one regimen are one
# regimen, and counting the patients there answers "how many lines", not "how
# many regimens".
#
# `x` is the column itself, over the rows the column's population selects. A
# blank is not a value: a row the study left empty names no regimen, and
# counting it would add one that nobody was on. The count is of values and not
# of people, so the floor is tested on the population this was read over and
# not on the count - see TFLS_COUNT_FLOOR_STATS in R/suppress.R.
stat_n_distinct <- function(x, denom = NA) {
  v <- chr(x)
  n <- length(unique(v[nzchar(v)]))
  d <- suppressWarnings(as.numeric(denom))
  if (length(d) != 1L) d <- NA_real_
  stat_cell("n_distinct", value = n, n = n, denom = d, text = fmt_count(n))
}

# --- continuous -------------------------------------------------------------

num_of <- function(x) {
  v <- suppressWarnings(as.numeric(x))
  v[!is.na(v)]
}

stat_mean_sd <- function(x, denom = NA) {
  v <- num_of(x)
  if (!length(v)) return(stat_refused("mean_sd", "no values to average"))
  d <- suppressWarnings(as.numeric(denom))
  if (length(d) != 1L || is.na(d)) d <- length(v)
  # The sample standard deviation, which is undefined on one value.
  s <- if (length(v) > 1L) stats::sd(v) else NA_real_
  stat_cell("mean_sd", value = mean(v), low = s, n = length(v), denom = d,
            text = paste0(fmt_dec(mean(v), 1), " (", fmt_dec(s, 1), ")"))
}

stat_median_iqr <- function(x, denom = NA) {
  v <- num_of(x)
  if (!length(v)) return(stat_refused("median_iqr", "no values to order"))
  d <- suppressWarnings(as.numeric(denom))
  if (length(d) != 1L || is.na(d)) d <- length(v)
  q <- stats::quantile(v, c(.25, .5, .75), names = FALSE)
  stat_cell("median_iqr", value = q[2], low = q[1], high = q[3],
            n = length(v), denom = d,
            text = paste0(fmt_dec(q[2], 1), " (", fmt_dec(q[1], 1), ", ",
                          fmt_dec(q[3], 1), ")"))
}

stat_min_max <- function(x, denom = NA) {
  v <- num_of(x)
  if (!length(v)) return(stat_refused("min_max", "no values to bound"))
  d <- suppressWarnings(as.numeric(denom))
  if (length(d) != 1L || is.na(d)) d <- length(v)
  stat_cell("min_max", value = min(v), low = min(v), high = max(v),
            n = length(v), denom = d,
            text = paste0(fmt_dec(min(v), 1), ", ", fmt_dec(max(v), 1)))
}

# --- rates ------------------------------------------------------------------

# Per 100,000 person-years, which is how the study package writes a rate
# (its RATE_MULTIPLIER default) and how every rate row of the shells is
# labelled; bind_run() refuses a run that recorded another multiplier. Where
# the table carries the rate already, that is what is read: recomputing it
# from rounded events and person-years would give a second answer to a
# question the package has answered.
TFLS_RATE_PER <- 100000
stat_rate <- function(rate = NA, events = NA, person_years = NA, denom = NA,
                      low = NA, high = NA, per = TFLS_RATE_PER) {
  r <- suppressWarnings(as.numeric(rate))[1]
  e <- suppressWarnings(as.numeric(events))[1]
  py <- suppressWarnings(as.numeric(person_years))[1]
  if (is.na(r)) {
    if (is.na(e) || is.na(py) || py <= 0)
      return(stat_refused("rate",
        "no rate, and no events and person-years to make one from"))
    r <- per * e / py
  }
  stat_cell("rate", value = r, low = suppressWarnings(as.numeric(low))[1],
            high = suppressWarnings(as.numeric(high))[1],
            n = e, denom = suppressWarnings(as.numeric(denom))[1],
            text = fmt_dec(r, 2))
}

# --- Kaplan-Meier -----------------------------------------------------------

# The estimator: one row per event time, with the number at risk, the number of
# events, the survival and a log-log band from Greenwood's variance.
#
# A cohort with no event at all is a result and not missing data - everyone is
# still event-free at the end of their follow-up - so the rows come back empty
# with the sample size and the follow-up attached.
# One curve per cohort, however many cells read it.
#
# A survival table asks the same (time, event) pair for a median, a
# probability at 12 months, one at 24, an event count and a censored count -
# five cells, each of which called this and got the same curve back. The
# estimator walks the whole cohort once per distinct event time, so it is the
# most expensive thing in a fill, and the table paid for it five times.
#
# Keyed on a cheap summary of the inputs and then CHECKED: two different
# cohorts can share a key, so a key match is a candidate and identical() is
# what decides. A miss computes exactly what this function computed before,
# and nothing that reads the result writes to it.
#
# Bounded, because the key holds the cohort's own vectors: a fill walks many
# cohorts and an unbounded cache would keep every one of them. The oldest
# goes first, which suits the one pattern this exists for - several cells of
# one table, one after another.
.km_cache <- new.env(parent = emptyenv())
.km_cache_max <- 16L

km_cache_reset <- function() {
  rm(list = ls(.km_cache, all.names = TRUE), envir = .km_cache)
  assign(".order", character(0), envir = .km_cache)
  invisible(TRUE)
}
km_cache_reset()

km_cache_key <- function(time, event) {
  nt <- suppressWarnings(as.numeric(time))
  ne <- suppressWarnings(as.numeric(event))
  paste(length(time), length(event), sum(is.na(nt)), sum(is.na(ne)),
        sum(nt, na.rm = TRUE), sum(ne, na.rm = TRUE), sep = "|")
}

km_estimate <- function(time, event) {
  key <- km_cache_key(time, event)
  hit <- if (exists(key, envir = .km_cache, inherits = FALSE))
    get(key, envir = .km_cache, inherits = FALSE) else NULL
  if (!is.null(hit) && identical(hit$time, time) && identical(hit$event, event))
    return(hit$km)
  out <- km_estimate_uncached(time, event)
  ord <- c(setdiff(get(".order", envir = .km_cache), key), key)
  while (length(ord) > .km_cache_max) {
    suppressWarnings(rm(list = ord[1], envir = .km_cache))
    ord <- ord[-1]
  }
  assign(key, list(time = time, event = event, km = out), envir = .km_cache)
  assign(".order", ord, envir = .km_cache)
  out
}

km_estimate_uncached <- function(time, event) {
  keep <- !is.na(time) & !is.na(event) & time >= 0
  time <- as.numeric(time)[keep]; event <- as.integer(event)[keep]
  if (!length(time)) return(km_empty(0L, 0L, NA_real_))
  o <- order(time, -event)
  time <- time[o]; event <- event[o]
  ut <- sort(unique(time[event == 1L]))
  n <- length(time)
  surv <- 1; var_sum <- 0
  rows <- lapply(ut, function(t) {
    at_risk <- sum(time >= t)
    d <- sum(time == t & event == 1L)
    if (at_risk <= 0) return(NULL)
    surv <<- surv * (1 - d / at_risk)
    # Greenwood, accumulated on the log scale for the band.
    if (at_risk > d) var_sum <<- var_sum + d / (at_risk * (at_risk - d))
    # se is sd(log(-log S)) = sqrt(Greenwood) / |log S|. log(S) is negative, so
    # an exponent written as se/log(surv) would invert the band; it is spelled
    # with abs() and an explicit sign instead.
    se <- if (surv > 0 && surv < 1 && var_sum > 0)
      sqrt(var_sum) / abs(log(surv)) else NA_real_
    lo <- if (is.na(se)) NA_real_ else surv^exp( 1.96 * se)
    hi <- if (is.na(se)) NA_real_ else surv^exp(-1.96 * se)
    data.frame(TIME = t, N_RISK = at_risk, N_EVENT = d, SURV = surv,
               LOWER = min(max(lo, 0), 1), UPPER = min(max(hi, 0), 1),
               stringsAsFactors = FALSE)
  })
  out <- do.call(rbind, Filter(Negate(is.null), rows))
  if (is.null(out)) out <- km_empty(0L, 0L, NA_real_)
  attr(out, "n") <- n
  attr(out, "n_event") <- sum(event == 1L)
  # How far the cohort was actually observed. A curve read to the last EVENT
  # stops early whenever the last subjects are censored, and stops at zero
  # when none of them had an event.
  attr(out, "follow_up") <- max(time)
  out
}

km_empty <- function(n = 0L, n_event = 0L, follow_up = NA_real_) {
  out <- data.frame(TIME = numeric(0), N_RISK = numeric(0),
                    N_EVENT = numeric(0), SURV = numeric(0),
                    LOWER = numeric(0), UPPER = numeric(0),
                    stringsAsFactors = FALSE)
  attr(out, "n") <- n
  attr(out, "n_event") <- n_event
  attr(out, "follow_up") <- follow_up
  out
}

# Median survival: the first time the curve is at or below 0.5. NA where it
# never gets there, which is a real answer and not a missing one.
km_median <- function(km) {
  if (!nrow(km)) return(NA_real_)
  hit <- which(km$SURV <= 0.5)
  if (!length(hit)) return(NA_real_)
  km$TIME[hit[1]]
}

# The interval around the median: the times at which the band still covers a
# survival of 0.5, which is the test-inversion interval Brookmeyer and Crowley
# describe, read off the log-log band the estimator already carries.
#
# The band is [LOWER, UPPER] and both fall with time, LOWER first. So 0.5 is
# inside the band from the first time LOWER reaches it until the first time
# UPPER does, and those two times are the interval's ends in that order. Taking
# them the other way round would return an interval whose lower end is after
# its upper end.
#
# A bound the follow-up never reaches comes back NA. There is no number to give
# and inventing one would report a precision the data does not hold.
km_median_ci <- function(km) {
  out <- c(NA_real_, NA_real_)
  if (!nrow(km)) return(out)
  lo <- which(!is.na(km$LOWER) & km$LOWER <= 0.5)
  hi <- which(!is.na(km$UPPER) & km$UPPER <= 0.5)
  if (length(lo)) out[1] <- km$TIME[lo[1]]
  if (length(hi)) out[2] <- km$TIME[hi[1]]
  out
}

# The curve read at one time: the step in force at that month, with its band.
#
# Before the first event the estimate is 1 and the band is degenerate, so the
# band comes back NA rather than as a pair of ones. Past the end of observed
# follow-up there is nothing to read, and the caller is told so rather than
# handed the last step as though the cohort had been followed that far.
km_prob_at <- function(km, months) {
  m <- suppressWarnings(as.numeric(months))[1]
  fu <- attr(km, "follow_up")
  if (is.na(m)) return(list(ok = FALSE, why = "no month to read the curve at"))
  if (is.null(fu) || is.na(fu) || m > fu)
    return(list(ok = FALSE, why = paste0(
      "month ", m, " is past the observed follow-up of this population")))
  hit <- which(km$TIME <= m)
  if (!length(hit))
    return(list(ok = TRUE, surv = 1, lower = NA_real_, upper = NA_real_,
                n_risk = attr(km, "n")))
  i <- hit[length(hit)]
  list(ok = TRUE, surv = km$SURV[i], lower = km$LOWER[i], upper = km$UPPER[i],
       n_risk = km$N_RISK[i])
}

# A bound of the interval, or the follow-up not reaching it. Never a blank: a
# blank between two brackets reads as a number nobody wrote down.
km_bound_text <- function(x)
  if (is.na(x)) "not reached" else fmt_dec(x, 1)

# The four statistics a shell may ask of a curve. Each is given the times and
# the event flags, so a row reads a study table and nothing else.
stat_km_median <- function(time, event, denom = NA) {
  km <- km_estimate(time, event)
  n <- attr(km, "n")
  d <- suppressWarnings(as.numeric(denom))
  if (length(d) != 1L || is.na(d)) d <- n
  med <- km_median(km)
  ci <- km_median_ci(km)
  # The median can be out of reach while a bound of it is not: with 45 events
  # among 100 subjects the band's lower limit passes 0.5 without the curve
  # itself getting there, and that lower bound is what the data supports. So
  # the interval is printed whenever either end is estimable, and "not reached"
  # stands in for the median as it does for a bound. An interval with neither
  # end is left off rather than printed as a pair of words.
  band <- if (all(is.na(ci))) "" else
    paste0(" (", km_bound_text(ci[1]), ", ", km_bound_text(ci[2]), ")")
  stat_cell("km_median", value = med, low = ci[1], high = ci[2],
            n = attr(km, "n_event"), denom = d,
            text = paste0(km_bound_text(med), band))
}

stat_km_prob <- function(time, event, months, denom = NA) {
  km <- km_estimate(time, event)
  n <- attr(km, "n")
  d <- suppressWarnings(as.numeric(denom))
  if (length(d) != 1L || is.na(d)) d <- n
  p <- km_prob_at(km, months)
  if (!isTRUE(p$ok)) return(stat_refused("km_prob", p$why))
  txt <- paste0(fmt_dec(100 * p$surv, 1),
                if (is.na(p$lower)) "" else
                  paste0(" (", fmt_dec(100 * p$lower, 1), ", ",
                         fmt_dec(100 * p$upper, 1), ")"))
  stat_cell("km_prob", value = 100 * p$surv, low = 100 * p$lower,
            high = 100 * p$upper, n = attr(km, "n_event"), denom = d,
            text = txt)
}

stat_km_events <- function(time, event, denom = NA) {
  km <- km_estimate(time, event)
  n <- attr(km, "n")
  d <- suppressWarnings(as.numeric(denom))
  if (length(d) != 1L || is.na(d)) d <- n
  e <- attr(km, "n_event")
  stat_cell("km_events", value = e, n = e, denom = d,
            text = count_pct_text(e, d))
}

stat_km_censored <- function(time, event, denom = NA) {
  km <- km_estimate(time, event)
  n <- attr(km, "n")
  d <- suppressWarnings(as.numeric(denom))
  if (length(d) != 1L || is.na(d)) d <- n
  cens <- n - attr(km, "n_event")
  stat_cell("km_censored", value = cens, n = cens, denom = d,
            text = count_pct_text(cens, d))
}
