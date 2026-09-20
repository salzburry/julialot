# The live controls: a selection over numbers already computed - which cohort,
# which line, which period, which stratum, what floor to suppress at. Answered
# here, instantly, because nothing has to be re-derived.
#
# The other kind of control is an open question. It changes the SQL, so it
# cannot be applied to a finished table: S_SAFETY_RATES was computed under one
# reading of the washout and no filter recovers another. That kind is
# scenarios.R.

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
# The package already suppressed into S_*_RELEASE at its own threshold, and
# this can only ever hide more: lowering the floor below the package's reveals
# nothing, because those cells arrived NULL. Enforced rather than trusted, so a
# mis-set env var cannot turn the dashboard into a disclosure route.
apply_floor <- function(d, spec, min_n, package_min_n = 25L) {
  if (is.null(d) || !nrow(d)) return(d)
  # The spec's column when it names one, otherwise a count the table carries,
  # so a table that declared none is suppressed too.
  n_col <- infer_n_col(spec, names(d))
  if (is.null(n_col)) return(d)
  floor_n <- max(as.integer(min_n), as.integer(package_min_n))
  n <- suppressWarnings(as.numeric(d[[n_col]]))
  # A count that cannot be read is not a count that cleared the floor: a
  # denominator that comes back NA, or as text such as the pre-suppressed
  # marker "<25", is withheld. released() in R/prepare.R decides it the same
  # way, so two panels cannot disagree about which way to fail.
  hit <- is.na(n) | n < floor_n
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
#
# `id_col` is the patient identifier, when the table has one. N stays what a
# row of the table is - on a line-grain table that is a count of lines, which
# is a legitimate figure - but the floor is about patients: three lines each
# from ten patients is N = 30 and ten people.
# COMPLEMENTARY SUPPRESSION, in one place because two copies of it diverged.
#
# Withholding one cell of a set whose total is published hides nothing: a
# stratum of 100 with levels 97 and 3 gives the 3 away as the difference. So
# where exactly one cell is withheld, the smallest of the others goes with it
# - two unknowns cannot be recovered from one total.
#
# With only TWO cells that withholds both, and that is the answer, not an edge
# case to guard against: one of two cells plus the total is the other cell.
# The table said so and the chart beside it did not, because the chart asked
# for more than one cell to remain rather than for any at all, so a chart of
# 60 and 3 drew the 60 and published the 3 by subtraction. One function now,
# called by both.
#
# `released` is the cells still shown; `value` is what each publishes, and the
# smallest of those is the one whose loss costs the reader least.
suppress_complement <- function(released, value) {
  if (length(released) < 2L || sum(!released) != 1L) return(released)
  open <- which(released)
  if (!length(open)) return(released)
  released[open[which.min(value[open])]] <- FALSE
  released
}

tabulate_cat <- function(d, col, min_n = 25L, id_col = NULL) {
  if (is.null(d) || !nrow(d) || !col %in% names(d)) return(data.frame())
  v <- as.character(d[[col]])
  v[is.na(v) | !nzchar(trimws(v))] <- "(Missing)"
  tb <- sort(table(v), decreasing = TRUE)
  out <- data.frame(LEVEL = names(tb), N = as.integer(tb),
                    stringsAsFactors = FALSE)
  out$PCT <- round(100 * out$N / sum(out$N), 1)
  pop <- if (!is.null(id_col) && id_col %in% names(d)) {
    ids <- as.character(d[[id_col]])
    vapply(out$LEVEL, function(l)
      length(unique(ids[v == l & !is.na(ids) & nzchar(ids)])), integer(1))
  } else out$N
  out$SUPPRESSED <- as.integer(pop < min_n)
  # ...and the level beside it, where withholding one would publish it
  # anyway. suppress_complement() above is the rule and says why.
  out$SUPPRESSED <- as.integer(
    !suppress_complement(out$SUPPRESSED == 0L, out$N))
  out$N[out$SUPPRESSED == 1L] <- NA
  out$PCT[out$SUPPRESSED == 1L] <- NA
  out
}

# Mean/SD/median/IQR/min/max/missing for a continuous column.
#
# ROWS AND PATIENTS ARE NOT THE SAME NUMBER, and this reports on both. A
# subject table is one row per patient in most panels and one row per LINE in
# some, and the caption prints whichever it is - "120 patients in this
# selection (310 lines)". So:
#
#   the floor is on PATIENTS, as tabulate_cat()'s is, through `id_col`.
#   Counting rows instead let forty lines belonging to nine patients clear a
#   floor of twenty-five, which is the floor not applying at all.
#
#   the missing group is read on BOTH scales, because both totals are
#   published. A categorical column's missing values are a level and take the
#   floor like any other; a continuous column's are a count, and N against a
#   caption gives them away by subtraction on whichever scale N is read - the
#   argument the comment below already makes about N_MISSING.
#
# Two cells, one published total. Withholding either withholds both, so N is
# the one withheld.
summarise_num <- function(d, col, min_n = 25L, n_population = NULL,
                          id_col = NULL) {
  if (is.null(d) || !nrow(d) || !col %in% names(d)) return(data.frame())
  x <- suppressWarnings(as.numeric(d[[col]]))
  n <- sum(!is.na(x))
  # The patients behind those rows. No identifier and a row is a patient,
  # which is what this reported before and is right for a patient-grain
  # table.
  n_pat <- if (!is.null(id_col) && id_col %in% names(d)) {
    ids <- as.character(d[[id_col]])
    length(unique(ids[!is.na(x) & !is.na(ids) & nzchar(ids)]))
  } else n
  out <- data.frame(VARIABLE = col, N = n, N_MISSING = sum(is.na(x)),
                    MEAN = NA_real_, SD = NA_real_, MEDIAN = NA_real_,
                    Q1 = NA_real_, Q3 = NA_real_, MIN = NA_real_, MAX = NA_real_,
                    stringsAsFactors = FALSE)
  if (n_pat >= min_n) {
    q <- stats::quantile(x, c(.25, .5, .75), na.rm = TRUE, names = FALSE)
    out$MEAN <- round(mean(x, na.rm = TRUE), 2)
    out$SD <- round(stats::sd(x, na.rm = TRUE), 2)
    out$Q1 <- round(q[1], 2); out$MEDIAN <- round(q[2], 2); out$Q3 <- round(q[3], 2)
    out$MIN <- round(min(x, na.rm = TRUE), 2); out$MAX <- round(max(x, na.rm = TRUE), 2)
  }
  out$SUPPRESSED <- as.integer(n_pat < min_n)
  # The counts go with them. N is the number of rows with a value, and
  # "N = 3" beside withheld statistics publishes the number the floor exists to
  # protect; N_MISSING goes too, because it subtracts against the stratum size
  # in the caption. tabulate_cat() applies the same rule to a suppressed level.
  if (out$SUPPRESSED == 1L) { out$N <- NA_integer_; out$N_MISSING <- NA_integer_ }
  # ...and the same subtraction the other way round, on each scale the
  # caption publishes. The statistics rest on min_n patients or more and
  # stay, because the floor permits them; what cannot stay is the count that
  # gives away the group this column has no value for. An empty group
  # discloses nobody, so it is left.
  #
  # Rows first, which needs nothing passed in: N_MISSING is that complement
  # already. Then patients, where the stratum is known - and a stratum
  # counted in patients minus a count of ROWS is not a group of anybody, so
  # the patient scale is compared with the patient count.
  small <- function(k) !is.na(k) && k > 0L && k < min_n
  n_absent_rows <- sum(is.na(x))
  pop <- suppressWarnings(as.integer(n_population))[1]
  n_absent_pat <- if (is.na(pop)) NA_integer_ else pop - n_pat
  if (small(n_absent_rows) || small(n_absent_pat)) {
    out$N <- NA_integer_; out$N_MISSING <- NA_integer_
  }
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
  # A cohort with no event at all is a result: everyone is still event-free at
  # the end of their follow-up. There is no step to draw, so the rows are
  # empty, but the sample size and the follow-up it was observed over come back
  # so the curve can be drawn flat across it.
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
    # log(S) is negative, so an exponent written as se/log(surv) inverts the
    # band. Spelled with abs() and an explicit sign instead.
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
  want <- c(spec$keys, spec$facet, spec$groups)
  keys <- intersect(want, names(a))
  if (is.null(a) || is.null(b) || !nrow(a) || !nrow(b) || !length(keys) ||
      !value %in% names(a) || !value %in% names(b))
    return(data.frame())
  # Both sides have to be stratified the same way. Keys taken off `a` alone
  # leave b keyed on fewer columns, because paste() drops a NULL rather than
  # complaining, and one row against one row then comes back as two. Two
  # scenarios whose tables have different columns are not comparable.
  missing_b <- setdiff(keys, names(b))
  if (length(missing_b)) {
    out <- data.frame()
    attr(out, "why") <- paste0(
      "These two readings are not stratified the same way: ",
      paste(missing_b, collapse = ", "),
      " is on one side and not the other, so their rows do not correspond.")
    return(out)
  }
  ka <- do.call(paste, c(lapply(keys, function(k) as.character(a[[k]])), sep = "\r"))
  kb <- do.call(paste, c(lapply(keys, function(k) as.character(b[[k]])), sep = "\r"))
  all_k <- union(ka, kb)
  out <- do.call(rbind, lapply(strsplit(all_k, "\r", fixed = TRUE), function(p)
    stats::setNames(as.data.frame(as.list(p), stringsAsFactors = FALSE), keys)))
  # match() takes the first row for a key, so a duplicated stratum would be
  # compared on one of its rows with the other dropped silently. Counted, and
  # reported on the row.
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
# A `subject` table is one row per PATID, and a grid of it is a line listing:
# every patient, with their identifier, on a page several people can open. So
# it is summarised instead, never listed, over the columns the spec names as
# categorical and continuous.
#
# Suppression is on the stratum: a level or a summary computed from fewer than
# the floor is withheld, because the stratum is the population the rule is
# about.
# The same list the shells refuse on the way out (TFLS_ID_COLUMNS in
# TFLS/R/suppress.R). Two folders, one list: a column one of them would drop
# and the other would draw is the gap an identifier gets through.
ID_COLUMNS <- c("PATID", "PAT_PLANID", "PATIENT_ID", "MEMBER_ID", "CLMID",
                "PERSON_ID", "MRN")

# Never rendered, whatever a spec says. An identifier that reaches the page is
# a disclosure whether or not anything asked for it.
#
# Matched case-insensitively and subset by position, because a warehouse does
# return a column as `patid`: matching on the upper-cased names and then
# subtracting against the original ones removes nothing. population_n() finds
# the identifier whatever its case, and the two have to agree about the same
# column.
drop_identifiers <- function(d) {
  if (is.null(d) || !ncol(d)) return(d)
  d[, !toupper(names(d)) %in% ID_COLUMNS, drop = FALSE]
}

# n_population is the number of patients this stratum rests on; the caller
# works it out with population_n(), because only it knows the grain. nrow() is
# that number only at patient grain - on LOT_LONG_FINAL, one row per patient
# and line, ten patients with three lines each is 30 rows. NULL falls back to
# nrow() for a caller given no population.
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
  # The identifier, whatever case the source returned it in, so each level's
  # floor is on its patients rather than its rows.
  idc <- names(d)[match(toupper(spec$id %||% "PATID"), toupper(names(d)))]
  if (length(idc) != 1L || is.na(idc)) idc <- NULL
  rows <- list()
  for (cl in cats) {
    tb <- tabulate_cat(d, cl, min_n = min_n, id_col = idc)
    if (!nrow(tb)) next
    rows[[length(rows) + 1L]] <- data.frame(
      VARIABLE = cl, LEVEL = tb$LEVEL, N = tb$N, PCT = tb$PCT,
      MEAN = NA_real_, SD = NA_real_, MEDIAN = NA_real_,
      SUPPRESSED = tb$SUPPRESSED, stringsAsFactors = FALSE)
  }
  for (cl in nums) {
    s <- summarise_num(d, cl, min_n = min_n, n_population = n_stratum,
                       id_col = idc)
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

# A count column to suppress on, when the spec did not name one - which is
# every subject, funnel, check and undeclared table. Without it, a module that
# appears in the dashboard on its own would skip suppression as well.
COUNT_COLUMNS <- c("N_AT_RISK", "N_PATIENTS", "N_REMAINING", "N", "N_DENOM")

infer_n_col <- function(spec, cols) {
  if (!is.null(spec$n_col) && spec$n_col %in% cols) return(spec$n_col)
  hit <- intersect(COUNT_COLUMNS, toupper(cols))
  if (!length(hit)) return(NULL)
  cols[match(hit[1], toupper(cols))]
}


# ---- line to line ------------------------------------------------------------
# How one line relates to the next, per patient.
#
# The per-line panels describe lines one at a time, and a line that is fine on
# its own can be nonsense beside its neighbour: a line that ran out of
# treatment followed the next day by an allograft line, a CAR-T consolidation
# end with no CAR-T start behind it, a regimen returning in full one line
# later. These views are where that shows.
#
# Pairs the consecutive lines (n, n+1) of one patient, in LOT_NUM order; a
# patient whose lines skip a number is not paired across the gap, because the
# engine builds lines contiguously and a gap is a table to question, not a
# transition. Every count is distinct patients, and the pairs are aggregated
# before anything is returned, so no identifier leaves here.

# A level as a label: "(Missing)" where it is empty, unless the caller says
# what empty means - an empty regimen is a real thing, an allograft or
# CAR-T-only line carries none (LOT_RULES.md 4.6).
blank_level <- function(x, blank = "(Missing)") {
  x <- as.character(x)
  x[is.na(x) | !nzchar(trimws(x))] <- blank
  x
}

# The rows of a LOT table that can be paired - a patient id and an integer
# line number - in patient and line order.
lot_rows <- function(d) {
  id <- as.character(d$PATID); ln <- suppressWarnings(as.integer(d$LOT_NUM))
  ok <- !is.na(id) & nzchar(trimws(id)) & !is.na(ln)
  o <- which(ok)[order(id[ok], ln[ok])]
  list(d = d[o, , drop = FALSE], id = id[o], ln = ln[o])
}

# The rows in order, and for each whether the next row is the same patient's
# next line: a line's successor is the next row of the same patient, one
# number on.
lot_succession <- function(d) {
  r <- lot_rows(d); n <- length(r$id)
  r$nxt <- if (n > 1L) c(r$id[-1] == r$id[-n] & r$ln[-1] == r$ln[-n] + 1L, FALSE)
           else rep(FALSE, n)
  r
}

# The consecutive-line pairs of a table, one row per patient and pair, with
# the level of `from_col` on the earlier line and of `to_col` on the later.
lot_pairs <- function(d, from_col, to_col, blank = "(Missing)") {
  empty <- data.frame(ID = character(0), FROM_LOT = integer(0), TO_LOT = integer(0),
                      FROM = character(0), TO = character(0), stringsAsFactors = FALSE)
  if (is.null(d) || !nrow(d) || !all(c("PATID", "LOT_NUM", from_col, to_col) %in% names(d)))
    return(empty)
  r <- lot_succession(d)
  i <- which(r$nxt); j <- i + 1L
  if (!length(i)) return(empty)
  data.frame(ID = r$id[i], FROM_LOT = r$ln[i], TO_LOT = r$ln[j],
             FROM = blank_level(r$d[[from_col]][i], blank),
             TO = blank_level(r$d[[to_col]][j], blank), stringsAsFactors = FALSE)
}

# The lines with NO line after them, counted by line number and the level of
# `from_col`: the part of "how each line ended" that is not a pair. What
# count_transitions() needs to know how much of a published end-reason total
# the pairs from it account for.
lot_line_ends <- function(d, from_col, blank = "(Missing)") {
  empty <- data.frame(FROM_LOT = integer(0), FROM = character(0), N = integer(0),
                      stringsAsFactors = FALSE)
  if (is.null(d) || !nrow(d) || !all(c("PATID", "LOT_NUM", from_col) %in% names(d)))
    return(empty)
  r <- lot_succession(d)
  i <- which(!r$nxt)
  if (!length(i)) return(empty)
  from <- blank_level(r$d[[from_col]][i], blank)
  key <- paste(r$ln[i], from, sep = "\r")
  first <- !duplicated(key)
  data.frame(FROM_LOT = r$ln[i][first], FROM = from[first],
             N = as.integer(tapply(r$id[i], key, function(x) length(unique(x)))[key[first]]),
             stringsAsFactors = FALSE)
}

# Which cells of a count table have to be hidden so that no count under the
# floor can be read off any one of the totals that are published.
#
# `n` are the counts, `groups` a list of groupings (each a vector of group ids,
# one per cell, NA for a cell outside that grouping) whose totals are
# published, and `min_n` the floor. A cell under the floor is hidden, as is any
# cell `hidden` marks from the start. Then, to a fixed point: a group's hidden
# cells sum to the group total less its open cells, so where that sum is under
# the floor the smallest open cell of the group is hidden too, until the sum
# reaches the floor or nothing is left open. One hidden cell under the floor is
# the case of one; one hidden cell at or above it is a count that may be read,
# so nothing more is hidden for it. Hiding only ever adds, so this terminates.
#
# The caller folds the hidden cells into one row whose count is their sum,
# which is at or above the floor whenever an open cell remains beside it and is
# therefore not a count under the floor. Each total is held on its own - one
# published total less the cells shown beside it, which is the subtraction a
# reader makes - rather than every total taken together, which is a linear
# programme this panel does not run.
hide_for_disclosure <- function(n, groups, min_n, hidden = n < min_n) {
  repeat {
    before <- hidden
    for (grp in groups) for (g in unique(grp[!is.na(grp)])) {
      w <- which(!is.na(grp) & grp == g)
      open <- w[!hidden[w]]
      if (!any(hidden[w]) || !length(open)) next
      if (sum(n[w][hidden[w]]) < min_n)
        hidden[open[which.min(n[open])]] <- TRUE
    }
    if (identical(hidden, before)) break
  }
  hidden
}

# The hidden cells of a count table folded into one row per group, made by
# `make_row` from the group's cells, whose count is their sum - itself
# withheld when that sum is still under the floor. A regimen table has a
# long tail of rare pairs, and forty shaded rows say less than one row that
# says how many patients they hold between them.
#
# The row does not say how many cells it holds. That number is a published fact
# like any other, and with the other totals beside it, it can pick out the one
# way of filling the hidden cells that fits.
fold_hidden <- function(out, hidden, min_n, by, make_row) {
  shown <- out[!hidden, , drop = FALSE]
  shown$SUPPRESSED <- rep(0L, nrow(shown))
  if (any(hidden)) {
    folded <- do.call(rbind, lapply(split(out[hidden, , drop = FALSE], by[hidden]), make_row))
    folded$SUPPRESSED <- as.integer(folded$N_PATIENTS < min_n)
    shown <- rbind(shown, folded)
  }
  shown$N_PATIENTS[shown$SUPPRESSED == 1L] <- NA
  shown
}

# Pairs counted, with what cannot be shown on its own folded into one row
# per line.
#
# Every count is distinct patients. The floor is applied per pair; then the
# disclosure rule above, over the three totals the other panels publish:
#
#   * what opened line n+1 - every line n+1 has a predecessor, so the pairs
#     into a start type sum to the count "what opened each line" gives;
#   * the pairs from each line, which the caption gives and "lines by line
#     number" gives as the count of line n+1;
#   * how line n ended - that total counts every line n ending a given way,
#     with or without a line after it, so the pairs from an end reason sum to
#     it less the lines with none. Those lines join the group as a cell that is
#     never shown: the reader does not have their count, so where there are
#     enough of them a hidden pair can stand on them, and where there are few
#     or none - every line n has a next line, which the per-line counts say
#     when they agree - pairs are hidden until the pairs and the lines together
#     reach the floor.
#
# `ends` is lot_line_ends() for the same table and column, over the lines
# the pairs came from.
count_transitions <- function(pr, min_n = 25L, ends = NULL) {
  empty <- data.frame(FROM_LOT = integer(0), TO_LOT = integer(0), FROM = character(0),
                      TO = character(0), N_PATIENTS = integer(0), SUPPRESSED = integer(0),
                      stringsAsFactors = FALSE)
  if (!nrow(pr)) return(empty)
  key <- paste(pr$FROM_LOT, pr$TO_LOT, pr$FROM, pr$TO, sep = "\r")
  first <- !duplicated(key)
  out <- pr[first, c("FROM_LOT", "TO_LOT", "FROM", "TO"), drop = FALSE]
  out$N_PATIENTS <- as.integer(tapply(pr$ID, key, function(x) length(unique(x)))[key[first]])
  from_key <- function(lot, from) paste(lot, from, sep = "\r")
  if (is.null(ends)) ends <- lot_line_ends(NULL, "")
  cover <- ends[ends$N > 0L & from_key(ends$FROM_LOT, ends$FROM) %in%
                  from_key(out$FROM_LOT, out$FROM), , drop = FALSE]
  k <- nrow(out); m <- nrow(cover)
  hidden <- hide_for_disclosure(
    c(out$N_PATIENTS, cover$N),
    list(c(paste(out$TO_LOT, out$TO, sep = "\r"), rep(NA, m)),
         c(as.character(out$FROM_LOT), rep(NA, m)),
         c(from_key(out$FROM_LOT, out$FROM), from_key(cover$FROM_LOT, cover$FROM))),
    min_n, hidden = c(out$N_PATIENTS < min_n, rep(TRUE, m)))[seq_len(k)]
  # A patient has one pair per FROM_LOT, so the folded cells are disjoint
  # and their sum is a count of distinct patients.
  shown <- fold_hidden(out, hidden, min_n, by = out$FROM_LOT, make_row = function(g)
    data.frame(FROM_LOT = g$FROM_LOT[1], TO_LOT = g$TO_LOT[1],
               FROM = "(grouped pairs)", TO = "(shown only as a group)",
               N_PATIENTS = sum(g$N_PATIENTS), stringsAsFactors = FALSE))
  shown <- shown[order(shown$FROM_LOT, startsWith(shown$FROM, "("), shown$FROM,
                       -shown$N_PATIENTS, shown$TO), , drop = FALSE]
  rownames(shown) <- NULL
  shown
}

lot_transitions <- function(d, from_col, to_col, min_n = 25L, from_lot = NA,
                            blank = "(Missing)") {
  pr <- lot_pairs(d, from_col, to_col, blank)
  if (!is.na(from_lot)) pr <- pr[pr$FROM_LOT == as.integer(from_lot), , drop = FALSE]
  count_transitions(pr, min_n, lot_line_ends(d, from_col, blank))
}

# The whole sequence of one column across a patient's lines, counted.
#
# "MED > SCT_AUTO > MED" is a patient whose first line was a medication
# regimen, whose second opened on a transplant and whose third on a new
# agent. Counted on distinct patients, with the same disclosure rule as the
# pairs over the one published total - every patient has a line 1, so the
# rows sum to the count "lines by line number" publishes for line 1 - and
# what cannot be shown alone folded into one row.
lot_sequences <- function(d, col = "LOT_START_TYPE", min_n = 25L) {
  empty <- data.frame(SEQUENCE = character(0), N_LINES = integer(0),
                      N_PATIENTS = integer(0), PCT = numeric(0), SUPPRESSED = integer(0),
                      stringsAsFactors = FALSE)
  if (is.null(d) || !nrow(d) || !all(c("PATID", "LOT_NUM", col) %in% names(d))) return(empty)
  r <- lot_rows(d)
  if (!length(r$id)) return(empty)
  # Rows are already in patient and line order, so split() keeps each
  # patient's lines in sequence.
  seqs <- vapply(split(blank_level(r$d[[col]]), r$id), paste, character(1), collapse = " > ")
  tb <- sort(table(seqs), decreasing = TRUE)
  out <- data.frame(SEQUENCE = names(tb),
                    N_LINES = lengths(strsplit(names(tb), " > ", fixed = TRUE)),
                    N_PATIENTS = as.integer(tb), stringsAsFactors = FALSE)
  total <- sum(out$N_PATIENTS)
  hidden <- hide_for_disclosure(out$N_PATIENTS, list(rep("all", nrow(out))), min_n)
  shown <- fold_hidden(out, hidden, min_n, by = rep("all", nrow(out)), make_row = function(g)
    data.frame(SEQUENCE = "(grouped sequences)", N_LINES = NA_integer_,
               N_PATIENTS = sum(g$N_PATIENTS), stringsAsFactors = FALSE))
  shown$PCT <- round(100 * shown$N_PATIENTS / total, 1)   # NA where withheld
  shown <- shown[, c("SEQUENCE", "N_LINES", "N_PATIENTS", "PCT", "SUPPRESSED")]
  rownames(shown) <- NULL
  shown
}

# One of the three line-to-line views, prepared the way a panel wants it:
# the rows, whether the whole view is released, and its caption. The
# population is the patients with at least two consecutive lines (or, for
# sequences, with any line), counted on the identifier and tested against
# the floor before a single cell is looked at.
LOT_SEQUENCE_VIEWS <- c("end_to_start", "regimen", "sequences")

lot_sequence_view <- function(d, view, floor_n, from_lot = NA, package_min_n = 25L) {
  fl <- effective_floor(floor_n, package_min_n)
  view <- match.arg(view, LOT_SEQUENCE_VIEWS)
  if (is.null(d) || !nrow(d))
    return(list(rows = data.frame(), released = FALSE, n = 0L,
                note = "Nothing to show for this selection."))
  if (identical(view, "sequences")) {
    rows <- lot_sequences(d, "LOT_START_TYPE", min_n = fl)
    n <- if ("PATID" %in% names(d)) length(unique(as.character(d$PATID))) else NA_integer_
    what <- "patients, every line counted; the line selector does not apply here"
  } else {
    cols <- if (identical(view, "end_to_start"))
      c("LOT_BASE_END_REASON", "LOT_START_TYPE") else c("LOT_BASE_MEDS", "LOT_BASE_MEDS")
    blank <- if (identical(view, "regimen")) "(no regimen)" else "(Missing)"
    pr <- lot_pairs(d, cols[1], cols[2], blank)
    if (!is.na(from_lot)) pr <- pr[pr$FROM_LOT == as.integer(from_lot), , drop = FALSE]
    n <- length(unique(pr$ID))
    rows <- count_transitions(pr, fl, lot_line_ends(d, cols[1], blank))
    what <- sprintf("patients with a line and the one after it%s",
                    if (is.na(from_lot)) "" else sprintf(", from line %d", as.integer(from_lot)))
  }
  rel <- released(n, fl)
  list(rows = if (rel) rows else data.frame(), released = rel, n = n,
       note = if (rel) sprintf("%s %s. Counts are distinct patients. Anything that could not be shown on its own without a count under the floor of %s being readable is grouped into one row.",
                               fmt_num(n, 0), what, fmt_num(fl, 0))
              else sprintf("Withheld: fewer than %s patients in this selection.", fmt_num(fl, 0)))
}
