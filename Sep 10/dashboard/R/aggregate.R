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
  # A count that cannot be read is not a count that cleared the floor.
  #
  # This tested `!is.na(n) & n < floor_n`, so a row whose denominator came back
  # NA - or as text, which is what a pre-suppressed marker like "<25" looks
  # like - was left alone and published its rate. released() in R/prepare.R
  # answers the same question the other way, and the two decide the same thing
  # in different panels, so they cannot disagree about which way to fail.
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
# `id_col` is the patient identifier, when the table has one. N stays what a
# row of the table is - on a line-grain table it is a count of lines, which is
# a legitimate figure - but the FLOOR is about patients, and a level was being
# released on its row count: three lines each from ten patients read as
# N = 30 and cleared a floor of 25, while the bar drawn from the same rows
# correctly withheld it.
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
  # SECONDARY suppression. Withholding one level and publishing the rest is not
  # withholding anything: the caption gives the stratum's size and the table
  # gives every other level, so the hidden cell is the subtraction. A stratum
  # of 100 with levels 97 and 3 published "97" beside "100 patients", and the 3
  # was there for anyone who took the difference.
  #
  # So where exactly one level is withheld, the smallest of the others goes
  # with it. Two unknowns cannot be recovered from one total. With only two
  # levels that withholds the variable entirely, which is the right answer:
  # one of two levels cannot be hidden at all.
  if (sum(out$SUPPRESSED) == 1L && nrow(out) > 1L) {
    open <- which(out$SUPPRESSED == 0L)
    out$SUPPRESSED[open[which.min(out$N[open])]] <- 1L
  }
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
  # ...including the counts themselves. N is the number of patients with a
  # value, and a suppressed row published it: a variable with three non-missing
  # values in a stratum of a hundred reported "N = 3" beside every summary
  # statistic withheld. N_MISSING goes too, because the stratum's size is in
  # the caption and the two subtract.
  #
  # tabulate_cat() has always withheld N for a suppressed level. This is the
  # same rule on the other half of the same table.
  if (out$SUPPRESSED == 1L) { out$N <- NA_integer_; out$N_MISSING <- NA_integer_ }
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
  # Both sides have to be stratified the same way.
  #
  # The keys came off `a` alone, and b[[k]] for a key b does not carry is NULL
  # - which paste() drops rather than complains about, so b's rows were keyed
  # on fewer columns than a's. One row against one row came back as TWO, one
  # of them a key that exists on neither side. Two scenarios whose tables have
  # different columns are not comparable, and that is worth saying rather than
  # joining on whatever they happen to share.
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
# Matched case-insensitively, and subset by POSITION.
#
# The test was built in upper case and then subtracted against the original
# names: intersect(toupper(names(d)), ID_COLUMNS) found "PATID" in a column
# actually called `patid`, and setdiff(names(d), "PATID") then removed
# nothing. A lower-case identifier reached the page - and warehouses do return
# them that way; PERMISSIBLE_SUBS in the LOT build is written lower case, and
# the melphalan reader already has to accept tableName or table_name.
#
# population_n() finds the identifier whatever its case, so the two disagreed
# about the same column: one counted patients off it, the other published it.
drop_identifiers <- function(d) {
  if (is.null(d) || !ncol(d)) return(d)
  d[, !toupper(names(d)) %in% ID_COLUMNS, drop = FALSE]
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


# ---- line to line ------------------------------------------------------------
# How one line relates to the next, per patient.
#
# Every LOT panel above describes lines one at a time - what opened them, how
# they ended, what was in them - and a line that is fine on its own can be
# nonsense beside its neighbour: a line that ran out of treatment followed
# the next day by an allograft line, a CAR-T consolidation end with no CAR-T
# start behind it, a regimen returning in full one line later. This is the
# view a reviewer needs to see that, and it is the one view the per-line
# panels cannot give.
#
# Pairs the consecutive lines (n, n+1) of one patient, in LOT_NUM order; a
# patient whose lines skip a number is not paired across the gap, because the
# engine builds lines contiguously and a gap is a table to question, not a
# transition. Every count is distinct PATIENTS. Nothing here carries an
# identifier out: the pairs are aggregated before anything is returned.

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

# The consecutive-line pairs of a table, one row per patient and pair, with
# the level of `from_col` on the earlier line and of `to_col` on the later.
lot_pairs <- function(d, from_col, to_col, blank = "(Missing)") {
  empty <- data.frame(ID = character(0), FROM_LOT = integer(0), TO_LOT = integer(0),
                      FROM = character(0), TO = character(0), stringsAsFactors = FALSE)
  if (is.null(d) || !nrow(d) || !all(c("PATID", "LOT_NUM", from_col, to_col) %in% names(d)))
    return(empty)
  r <- lot_rows(d)
  n <- length(r$id)
  if (n < 2L) return(empty)
  # A line's successor is the next row of the same patient, one number on.
  nxt <- c(r$id[-1] == r$id[-n] & r$ln[-1] == r$ln[-n] + 1L, FALSE)
  i <- which(nxt); j <- i + 1L
  if (!length(i)) return(empty)
  data.frame(ID = r$id[i], FROM_LOT = r$ln[i], TO_LOT = r$ln[j],
             FROM = blank_level(r$d[[from_col]][i], blank),
             TO = blank_level(r$d[[to_col]][j], blank), stringsAsFactors = FALSE)
}

# Which cells of a count table have to be hidden so that no count under the
# floor can be READ OFF, given which totals are published.
#
# `n` are the counts, `groups` a list of groupings (each a vector of group
# ids, one per cell) whose totals are published, and `min_n` the floor. A
# cell under the floor is hidden. Then, to a fixed point:
#
#   * a group with exactly one hidden cell has that cell recoverable as the
#     group total minus the open cells, so the smallest open cell of the
#     group is hidden with it;
#   * a group whose hidden cells sum to less than the floor has that sum
#     recoverable the same way - and a sum under the floor is a count under
#     the floor - so the smallest open cell of the group is hidden until the
#     hidden sum reaches the floor or nothing is left open.
#
# Hiding only ever adds, so this terminates. What it returns is which cells
# are hidden; the caller folds them into one row whose count is their sum,
# which is at or above the floor whenever an open cell remains beside it and
# is therefore not a count under the floor.
#
# The first version had only the first rule, and only over the source and
# destination groupings. Its caption published the pairs' whole population,
# and a line with one common pair and one rare one showed the common count
# beside that total: the rare count was the subtraction.
hide_for_disclosure <- function(n, groups, min_n) {
  hidden <- n < min_n
  repeat {
    before <- hidden
    for (grp in groups) for (g in unique(grp)) {
      w <- which(grp == g)
      open <- w[!hidden[w]]
      if (!any(hidden[w]) || !length(open)) next
      if (sum(hidden[w]) == 1L || sum(n[w][hidden[w]]) < min_n)
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

grouped_label <- function(n, noun)
  sprintf("(%d %s%s, grouped)", n, noun, if (n == 1L) "" else "s")

# Pairs counted, with what cannot be shown on its own folded into one row
# per line.
#
# Every count is distinct patients. The floor is applied per pair; then the
# disclosure rules above, over the two totals that ARE published: what
# opened line n+1 (every line n+1 has a predecessor, so the pairs INTO a
# start type sum to the count "what opened each line" publishes), and the
# pairs FROM each line, which the caption publishes and "lines by line
# number" publishes as the count of line n+1. How line n ended is not one:
# "how each line ended" counts every line n, with or without a successor,
# and the pairs from one end reason are not recoverable from it - and
# holding it anyway grouped four of five open cells on the synthetic run,
# because most end reasons have one rare destination.
count_transitions <- function(pr, min_n = 25L) {
  empty <- data.frame(FROM_LOT = integer(0), TO_LOT = integer(0), FROM = character(0),
                      TO = character(0), N_PATIENTS = integer(0), SUPPRESSED = integer(0),
                      stringsAsFactors = FALSE)
  if (!nrow(pr)) return(empty)
  key <- paste(pr$FROM_LOT, pr$TO_LOT, pr$FROM, pr$TO, sep = "\r")
  first <- !duplicated(key)
  out <- pr[first, c("FROM_LOT", "TO_LOT", "FROM", "TO"), drop = FALSE]
  out$N_PATIENTS <- as.integer(tapply(pr$ID, key, function(x) length(unique(x)))[key[first]])
  hidden <- hide_for_disclosure(out$N_PATIENTS, list(
    paste(out$TO_LOT, out$TO, sep = "\r"),
    as.character(out$FROM_LOT)), min_n)
  # A patient has one pair per FROM_LOT, so the folded cells are disjoint
  # and their sum is a count of distinct patients.
  shown <- fold_hidden(out, hidden, min_n, by = out$FROM_LOT, make_row = function(g)
    data.frame(FROM_LOT = g$FROM_LOT[1], TO_LOT = g$TO_LOT[1],
               FROM = grouped_label(nrow(g), "pair"), TO = "(shown only as a group)",
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
  count_transitions(pr, min_n)
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
    data.frame(SEQUENCE = grouped_label(nrow(g), "sequence"), N_LINES = NA_integer_,
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
    pr <- if (identical(view, "end_to_start"))
      lot_pairs(d, "LOT_BASE_END_REASON", "LOT_START_TYPE")
    else lot_pairs(d, "LOT_BASE_MEDS", "LOT_BASE_MEDS", blank = "(no regimen)")
    if (!is.na(from_lot)) pr <- pr[pr$FROM_LOT == as.integer(from_lot), , drop = FALSE]
    n <- length(unique(pr$ID))
    rows <- count_transitions(pr, fl)
    what <- sprintf("patients with a line and the one after it%s",
                    if (is.na(from_lot)) "" else sprintf(", from line %d", as.integer(from_lot)))
  }
  rel <- released(n, fl)
  list(rows = if (rel) rows else data.frame(), released = rel, n = n,
       note = if (rel) sprintf("%s %s. Counts are distinct patients. Anything that could not be shown on its own without a count under the floor of %s being readable is grouped into one row.",
                               fmt_num(n, 0), what, fmt_num(fl, 0))
              else sprintf("Withheld: fewer than %s patients in this selection.", fmt_num(fl, 0)))
}
