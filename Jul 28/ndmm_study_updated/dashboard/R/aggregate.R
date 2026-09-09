# The live controls: what a viewer can change and see answered at once.
#
# There are two kinds of control, and confusing them is the one way a
# dashboard like this lies.
#
#   Live      a selection over numbers already computed - which cohort, which
#             line, which period, which stratum, what floor to suppress at.
#             Answered here, instantly, because nothing has to be re-derived.
#
#   Scenario  an open question. It changes the SQL, so it cannot be applied to
#             a finished table: S_SAFETY_RATES was computed under ONE reading
#             of the washout and no filter recovers another. Changing one
#             means reading a different scenario, or running one.
#
# Everything in this file is the first kind. The second is scenarios.R.

# Filter a table by the keys the spec declares. A key the viewer left at "all"
# is not filtered on.
apply_keys <- function(d, spec, sel) {
  if (is.null(d) || !nrow(d)) return(d)
  for (k in intersect(spec$keys, names(d))) {
    v <- sel[[k]]
    if (is.null(v) || !length(v) || identical(v, "all")) next
    d <- d[as.character(d[[k]]) %in% as.character(v), , drop = FALSE]
  }
  d
}

# A second suppression floor, applied on what was read.
#
# The package already suppressed into S_*_RELEASE at its own threshold. This
# can only ever hide MORE: a viewer may raise the floor, and lowering it below
# what the package applied would not reveal anything anyway, because those
# cells arrived NULL. Enforced rather than trusted, so a mis-set env var
# cannot turn the dashboard into a disclosure route.
apply_floor <- function(d, spec, min_n, package_min_n = 25L) {
  if (is.null(d) || !nrow(d)) return(d)
  # The spec's column when it names one, otherwise a count the table carries.
  # Returning early on "no n_col declared" left every undeclared table
  # unsuppressed.
  n_col <- infer_n_col(spec, names(d))
  if (is.null(n_col)) return(d)
  floor_n <- max(as.integer(min_n), as.integer(package_min_n))
  n <- suppressWarnings(as.numeric(d[[n_col]]))
  hit <- !is.na(n) & n < floor_n
  if (!any(hit)) return(d)
  vals <- intersect(c(spec$numerator, spec$events, spec$py, spec$rate,
                      spec$lo, spec$hi, spec$denom, spec$pct, spec$extra,
                      n_col),
                    names(d))
  for (cl in vals) d[[cl]][hit] <- NA
  d$SUPPRESSED <- as.integer(hit)
  attr(d, "floor") <- floor_n
  d
}

# Counts and percentages for a categorical column, with a (Missing) row so an
# absent value is visible rather than dropped.
tabulate_cat <- function(d, col, min_n = 25L) {
  if (is.null(d) || !nrow(d) || !col %in% names(d)) return(data.frame())
  v <- as.character(d[[col]])
  v[is.na(v) | !nzchar(trimws(v))] <- "(Missing)"
  tb <- sort(table(v), decreasing = TRUE)
  out <- data.frame(LEVEL = names(tb), N = as.integer(tb),
                    stringsAsFactors = FALSE)
  out$PCT <- round(100 * out$N / sum(out$N), 1)
  out$SUPPRESSED <- as.integer(out$N < min_n)
  out$N[out$SUPPRESSED == 1L] <- NA
  out$PCT[out$SUPPRESSED == 1L] <- NA
  out
}

# Mean/SD/median/IQR/min/max/missing for a continuous column. Reported on the
# stratum, so it is suppressed on the stratum's own size.
summarise_num <- function(d, col, min_n = 25L) {
  if (is.null(d) || !nrow(d) || !col %in% names(d)) return(data.frame())
  x <- suppressWarnings(as.numeric(d[[col]]))
  n <- sum(!is.na(x))
  out <- data.frame(VARIABLE = col, N = n, N_MISSING = sum(is.na(x)),
                    MEAN = NA_real_, SD = NA_real_, MEDIAN = NA_real_,
                    Q1 = NA_real_, Q3 = NA_real_, MIN = NA_real_, MAX = NA_real_,
                    stringsAsFactors = FALSE)
  if (n >= min_n) {
    q <- stats::quantile(x, c(.25, .5, .75), na.rm = TRUE, names = FALSE)
    out$MEAN <- round(mean(x, na.rm = TRUE), 2)
    out$SD <- round(stats::sd(x, na.rm = TRUE), 2)
    out$Q1 <- round(q[1], 2); out$MEDIAN <- round(q[2], 2); out$Q3 <- round(q[3], 2)
    out$MIN <- round(min(x, na.rm = TRUE), 2); out$MAX <- round(max(x, na.rm = TRUE), 2)
  }
  out$SUPPRESSED <- as.integer(n < min_n)
  out
}

# Kaplan-Meier, written out rather than taken from survival::, so the app has
# no dependency a Domino environment might not carry. The estimator is the
# textbook one; survival:: is used when it IS available and the two are held
# to each other in tests/run_tests.R.
km_estimate <- function(time, event) {
  keep <- !is.na(time) & !is.na(event) & time >= 0
  time <- as.numeric(time)[keep]; event <- as.integer(event)[keep]
  if (!length(time)) return(data.frame())
  # A cohort with no event at all is a RESULT: everyone is still event-free at
  # the end of their follow-up. Returning a bare data.frame() made the panel
  # say "Nothing to show", which reads as missing data. The rows are empty
  # because there is no step to draw, but the sample size and the follow-up it
  # was observed over come back so the curve can be drawn flat across it.
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
    # Greenwood, accumulated on the log scale for the CI.
    if (at_risk > d) var_sum <<- var_sum + d / (at_risk * (at_risk - d))
    # Log-log band. se is sd(log(-log S)) = sqrt(Greenwood) / |log S|.
    #
    # The sign matters and is easy to invert: log(S) is NEGATIVE, so writing
    # the exponent as se/log(surv) flips it. Spelled with abs() and an explicit
    # sign, because the first version divided by log(surv) and put the upper
    # bound in the lower column - a band drawn upside down.
    se <- if (surv > 0 && surv < 1 && var_sum > 0)
      sqrt(var_sum) / abs(log(surv)) else NA_real_
    # exponent > 1 pushes S down (the lower bound); < 1 pulls it up.
    lo <- if (is.na(se)) NA_real_ else surv^exp( 1.96 * se)
    hi <- if (is.na(se)) NA_real_ else surv^exp(-1.96 * se)
    data.frame(TIME = t, N_RISK = at_risk, N_EVENT = d, SURV = surv,
               LOWER = min(max(lo, 0), 1), UPPER = min(max(hi, 0), 1),
               stringsAsFactors = FALSE)
  })
  out <- do.call(rbind, Filter(Negate(is.null), rows))
  if (is.null(out)) out <- data.frame(
    TIME = numeric(0), N_RISK = numeric(0), N_EVENT = numeric(0),
    SURV = numeric(0), LOWER = numeric(0), UPPER = numeric(0))
  attr(out, "n") <- n
  attr(out, "n_event") <- sum(event == 1L)
  # How far the cohort was actually observed. A curve drawn to the last EVENT
  # stops early whenever the last subjects are censored, and stops at zero
  # when none had an event at all.
  attr(out, "follow_up") <- max(time)
  out
}

# The step function as points to draw: survival starts at 1 before the first
# event and holds its last value to the end of observed follow-up.
#
# Separate from km_estimate() so that function still returns exactly one row
# per event time - which is what the survival:: cross-check compares, and what
# km_median() reads.
km_steps <- function(km) {
  fu <- attr(km, "follow_up") %||% NA_real_
  if (is.null(km) || !nrow(km))
    return(if (is.na(fu)) data.frame(TIME = numeric(0), SURV = numeric(0))
           else data.frame(TIME = c(0, fu), SURV = c(1, 1)))
  t <- c(0, km$TIME); v <- c(1, km$SURV)
  if (!is.na(fu) && fu > km$TIME[nrow(km)]) {
    t <- c(t, fu); v <- c(v, km$SURV[nrow(km)])
  }
  data.frame(TIME = t, SURV = v)
}

# Survival at a landmark, read off the step function.
km_at <- function(km, t) {
  if (!nrow(km)) return(c(SURV = NA_real_, LOWER = NA_real_, UPPER = NA_real_))
  prior <- km[km$TIME <= t, , drop = FALSE]
  if (!nrow(prior)) return(c(SURV = 1, LOWER = NA_real_, UPPER = NA_real_))
  r <- prior[nrow(prior), ]
  c(SURV = r$SURV, LOWER = r$LOWER, UPPER = r$UPPER)
}

# Median survival: the first time the curve is at or below 0.5. NA when it
# never gets there, which is a real answer and not a missing one.
km_median <- function(km) {
  if (!nrow(km)) return(NA_real_)
  hit <- which(km$SURV <= 0.5)
  if (!length(hit)) return(NA_real_)
  km$TIME[hit[1]]
}

# The same measure under two scenarios, and the difference.
#
# Joined on the keys the spec declares, so a row present in one and not the
# other is visible as a row rather than silently dropped - a scenario that
# moves a stratum below the floor is exactly the thing worth seeing.
compare_tables <- function(a, b, spec, value = NULL) {
  value <- value %||% spec$rate %||% spec$n_col
  keys <- intersect(c(spec$keys, spec$facet, spec$groups), names(a))
  if (is.null(a) || is.null(b) || !nrow(a) || !nrow(b) || !length(keys) ||
      !value %in% names(a) || !value %in% names(b))
    return(data.frame())
  ka <- do.call(paste, c(lapply(keys, function(k) as.character(a[[k]])), sep = "\r"))
  kb <- do.call(paste, c(lapply(keys, function(k) as.character(b[[k]])), sep = "\r"))
  all_k <- union(ka, kb)
  out <- do.call(rbind, lapply(strsplit(all_k, "\r", fixed = TRUE), function(p)
    stats::setNames(as.data.frame(as.list(p), stringsAsFactors = FALSE), keys)))
  # match() takes the FIRST row for a key. A table with a duplicated stratum
  # therefore compared one of its rows and dropped the other without saying so
  # - and a duplicated stratum is a real failure mode, which is why the package
  # has a grain check at all. Counted, and reported on the row.
  dup_a <- table(ka)[all_k]; dup_b <- table(kb)[all_k]
  out$A <- suppressWarnings(as.numeric(a[[value]][match(all_k, ka)]))
  out$B <- suppressWarnings(as.numeric(b[[value]][match(all_k, kb)]))
  n_dup <- pmax(ifelse(is.na(dup_a), 0L, dup_a), ifelse(is.na(dup_b), 0L, dup_b))
  if (any(n_dup > 1L)) out$N_ROWS_FOR_KEY <- as.integer(n_dup)
  out$DELTA <- out$B - out$A
  out$PCT_CHANGE <- ifelse(!is.na(out$A) & out$A != 0,
                           round(100 * (out$B - out$A) / out$A, 1), NA_real_)
  # Named VALUE_COL, not MEASURE: S_HCRU_RATES has its own MEASURE column and
  # overwriting it made every row of the comparison say "RATE".
  out$VALUE_COL <- value
  rownames(out) <- NULL
  out[order(-abs(out$DELTA %||% 0), na.last = TRUE), ]
}

# --- a subject-level table, aggregated ---------------------------------------
#
# A `subject` table is one row per PATID. Rendering it as a grid is a LINE
# LISTING: every patient, with their identifier, on a page several people can
# open. That is what this dashboard did until an adversarial pass found it -
# five panels, 1,200 rows each, PATID included.
#
# So a subject table is summarised instead, never listed. The spec already
# names which of its columns are categorical and which continuous, and
# tabulate_cat() and summarise_num() already knew how to summarise them - they
# were written, tested, and called by nothing, which is exactly the defect the
# release module's review found in the old R suppression helper.
#
# Suppression is on the STRATUM: a level or a summary computed from fewer than
# the floor is withheld, because the stratum is the population the rule is
# about.
ID_COLUMNS <- c("PATID", "PAT_PLANID", "PATIENT_ID", "MEMBER_ID", "CLMID")

# Never rendered, whatever a spec says. An identifier that reaches the page is
# a disclosure whether or not anything asked for it.
drop_identifiers <- function(d) {
  if (is.null(d) || !ncol(d)) return(d)
  keep <- setdiff(names(d), intersect(toupper(names(d)), ID_COLUMNS))
  d[, keep, drop = FALSE]
}

# n_population is the number of PATIENTS this stratum rests on, and the
# caller works it out with population_n() because only it knows the grain.
# nrow() is that number only at patient grain: on LOT_LONG_FINAL, which is one
# row per patient AND line, ten patients with three lines each came to 30 and
# published a summary the floor should have withheld. NULL keeps the old
# reading for a caller that has not been given a population.
summarise_subject <- function(d, spec, min_n = 25L, n_population = NULL) {
  if (is.null(d) || !nrow(d)) return(data.frame())
  cats <- intersect(spec$categorical %||% character(0), names(d))
  nums <- intersect(spec$continuous %||% character(0), names(d))
  # A table declaring neither still gets a summary rather than a listing: every
  # column that is not an identifier or a key is summarised by its type.
  if (!length(cats) && !length(nums)) {
    rest <- setdiff(names(drop_identifiers(d)), c(spec$keys, "SUPPRESSED"))
    nums <- rest[vapply(rest, function(cl) is.numeric(d[[cl]]), logical(1))]
    cats <- setdiff(rest, nums)
  }
  n_stratum <- n_population %||% nrow(d)
  rows <- list()
  for (cl in cats) {
    tb <- tabulate_cat(d, cl, min_n = min_n)
    if (!nrow(tb)) next
    rows[[length(rows) + 1L]] <- data.frame(
      VARIABLE = cl, LEVEL = tb$LEVEL, N = tb$N, PCT = tb$PCT,
      MEAN = NA_real_, SD = NA_real_, MEDIAN = NA_real_,
      SUPPRESSED = tb$SUPPRESSED, stringsAsFactors = FALSE)
  }
  for (cl in nums) {
    s <- summarise_num(d, cl, min_n = min_n)
    if (!nrow(s)) next
    rows[[length(rows) + 1L]] <- data.frame(
      VARIABLE = cl, LEVEL = "(continuous)", N = s$N, PCT = NA_real_,
      MEAN = s$MEAN, SD = s$SD, MEDIAN = s$MEDIAN,
      SUPPRESSED = s$SUPPRESSED, stringsAsFactors = FALSE)
  }
  if (!length(rows)) return(data.frame())
  out <- do.call(rbind, rows)
  # The whole stratum under the floor: nothing about it may be published, not
  # even a level that happens to hold more than the floor on its own. An
  # uncountable population is withheld too - it has not been shown to reach
  # the floor.
  if (is.na(n_stratum) || n_stratum < min_n) {
    out$N <- NA; out$PCT <- NA; out$MEAN <- NA; out$SD <- NA; out$MEDIAN <- NA
    out$SUPPRESSED <- 1L
  }
  attr(out, "n_stratum") <- n_stratum
  rownames(out) <- NULL
  out
}

# A count column to suppress on, when the spec did not name one.
#
# apply_floor() used to be a no-op on any table whose spec had no n_col - which
# is every subject, funnel, check and undeclared table. An undeclared table
# publishing N_PATIENTS therefore reached the page raw, and "a new module
# appears in the dashboard on its own" quietly meant "and skips suppression".
COUNT_COLUMNS <- c("N_AT_RISK", "N_PATIENTS", "N_REMAINING", "N", "N_DENOM")

infer_n_col <- function(spec, cols) {
  if (!is.null(spec$n_col) && spec$n_col %in% cols) return(spec$n_col)
  hit <- intersect(COUNT_COLUMNS, toupper(cols))
  if (!length(hit)) return(NULL)
  cols[match(hit[1], toupper(cols))]
}
