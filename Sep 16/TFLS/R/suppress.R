# Disclosure: the one rule, applied to every cell.
#
# It is the study package's own rule, at the package's own floor, and this can
# only ever withhold more. The package suppressed its released tables at 25
# before any of this ran; a floor set here is taken together with that one and
# the higher of the two wins, so a mis-set environment variable cannot turn a
# shell into a disclosure route.
#
#   * a cell whose denominator is under the floor is withheld, and so is the
#     count it was computed from - withholding a percentage and publishing the
#     n it came from withholds nothing;
#   * and where the cell IS a count of patients - a level of a variable, or the
#     patients a mean was taken over - that count is the population behind the
#     cell, so the floor applies to it as well. A rate is not: the package
#     suppresses a rate on its at-risk count and publishes the few events
#     inside it, and this folder does the same;
#   * a curve is not a rate. Every statistic read off one publishes two counts
#     of patients, whatever it prints: the patients with the event, in N, and
#     the patients censored, which is DENOM less N. So both reach the floor or
#     the cell is withheld - the events and censored rows, and the median and
#     the probabilities too, whose N is the curve's events. A median over 30
#     patients of whom 3 had the event publishes the 3 in its N column, and a
#     12-month estimate of 90% publishes them again;
#   * and a curve goes whole: one of its cells withheld, for any reason,
#     withholds the rest of that column's curve, because its events and its
#     censored add up to its population and either one printed gives the other
#     away (curve_units());
#   * a row whose own filter narrows its column's population - TTE_ELIGIBLE=1 -
#     leaves out patients that every unfiltered row of the same population
#     still counts. The ones it leaves out are a number a reader can take, so
#     they reach the floor, or the row is withheld;
#   * a denominator that cannot be read is withheld too: a population that has
#     not been shown to reach the floor has not reached it;
#   * a sum the shell draws gives away whatever is missing from it. The reader
#     takes the printed terms from the printed total and has the rest, so the
#     rest has to reach the floor: one withheld cell, two withheld cells that
#     add up to 12, or patients no term of the sum counts at all. The sums are
#     read off the shell - a subtotal down a column, the levels of a variable
#     against the column's denominator, and a population against the columns
#     that split it: Overall against its regimen classes and its subgroups, in
#     the same table or in another one, as T5c's age columns split T4's
#     Overall. Withholding one cell can leave another sum short, so the pass is
#     repeated until none is, and it runs again over all the tables together;
#   * a withheld cell prints as "<25" (or whatever floor is in force), never as
#     a blank that could be read as a zero.

TFLS_PACKAGE_MIN_N <- 25L

# The floor actually applied. A reader may raise it; lowering it below the
# package's reveals nothing, because those cells were already withheld when the
# package wrote them.
tfls_floor <- function(requested, package_min_n = TFLS_PACKAGE_MIN_N) {
  v <- suppressWarnings(as.integer(requested))
  p <- suppressWarnings(as.integer(package_min_n))
  if (is.na(p)) p <- TFLS_PACKAGE_MIN_N
  if (length(v) != 1L || is.na(v)) p else max(v, p)
}

# TFLS_MIN_N as the run will use it. A value that is not a whole number is
# refused rather than quietly ignored: an operator who set it meant something.
tfls_floor_from_env <- function(raw = Sys.getenv("TFLS_MIN_N", unset = "")) {
  raw <- trimws(raw)
  if (!nzchar(raw)) return(tfls_floor(NA))
  v <- suppressWarnings(as.numeric(raw))
  if (is.na(v) || v != round(v) || v < 0)
    stop("TFLS_MIN_N='", raw, "' is not a whole number of patients.",
         call. = FALSE)
  tfls_floor(as.integer(v))
}

# The one test every cell goes through.
tfls_released <- function(n, floor_n)
  length(n) == 1L && !is.na(n) && !is.na(floor_n) && n >= floor_n

# What a withheld cell prints as.
suppressed_text <- function(floor_n) paste0("<", floor_n)

# --- identifiers ------------------------------------------------------------
#
# Nothing patient-level is read into a cell and nothing patient-level may be
# written. The check is on the way out, on every frame, because a shell is a
# file anyone may edit and an identifier that reaches out/ is a disclosure
# whether or not anything asked for it.

TFLS_ID_COLUMNS <- c("PATID", "PAT_PLANID", "PATIENT_ID", "MEMBER_ID", "CLMID",
                     "PERSON_ID", "MRN")

drop_identifiers <- function(d) {
  if (is.null(d) || !ncol(d)) return(d)
  d[, !toupper(names(d)) %in% TFLS_ID_COLUMNS, drop = FALSE]
}

assert_no_identifiers <- function(d, where = "this table") {
  if (is.null(d) || !ncol(d)) return(invisible(TRUE))
  hit <- names(d)[toupper(names(d)) %in% TFLS_ID_COLUMNS]
  if (length(hit))
    stop("TFLS DISCLOSURE ERROR: ", where, " carries the identifier column(s) ",
         paste(hit, collapse = ", "), ". Nothing patient-level is written.",
         call. = FALSE)
  invisible(TRUE)
}

# The only way anything leaves this folder.
tfls_write_csv <- function(d, path) {
  assert_no_identifiers(d, basename(path))
  utils::write.csv(d, path, row.names = FALSE, na = "")
  invisible(path)
}

# --- the rule, on one cell --------------------------------------------------

# A cell as R/fill.R holds it, withheld. The value, its parts and the count all
# go; the denominator goes too, because it is the population the floor is about
# and printing it beside a withheld cell publishes the number being protected.
withhold_cell <- function(cells, i, floor_n, reason) {
  for (cl in c("VALUE", "LOW", "HIGH", "N", "DENOM"))
    if (cl %in% names(cells)) cells[[cl]][i] <- NA_real_
  cells$TEXT[i] <- suppressed_text(floor_n)
  cells$SUPPRESSED[i] <- 1L
  cells$REASON[i] <- reason
  cells
}

# --- the sums a reader can subtract within ----------------------------------
#
# A withheld cell is no secret when it is the last unknown in a sum whose other
# terms are printed: the sum less the rest IS the cell. So the cells of one
# filled table are read as a set of relations - each one "this cell is the sum
# of those cells" - and the rule is the same for all of them.
#
# The relations are the shell's own and nothing clinical is assumed here:
#
#   down a column    the shell's indentation. A row at indent d is the parent
#                    of the run of rows immediately after it at indent d + 1,
#                    up to the next row at indent d or less. That is how the
#                    age block reads: "<75 years" over its three bands.
#   across a row     the shell's columns. A column with no subgroup is the
#                    total of the columns beside it that select the same
#                    population and whose subgroups name levels of one
#                    variable, as Overall is the total of Neuropathy Yes and
#                    Neuropathy No.
#   against the N    the levels of a variable in one column and one section sum
#                    to the column's own denominator, which is printed in the
#                    column header. This is the relation this file has always
#                    applied, and it is kept as one relation among the rest.
#
# Only counts of patients take part. A median, a rate, a curve and a count of
# distinct values do not sum to a total, so hiding a second one of them
# protects nothing and loses a number.
TFLS_GROUPED_STATS <- c("n_pct", "n")

# The statistics whose own N is a count of patients, and so is a population the
# floor is about. For the rest the floor is on the denominator alone, which is
# what the package applies to a rate: N_AT_RISK decides, and the events inside
# it are published with it or withheld with it. A count of distinct values is
# not a count of patients either - three regimens among a hundred patients
# tells a reader about the regimens - so it goes with the population it was
# read over rather than being tested as though it were one.
TFLS_COUNT_FLOOR_STATS <- c("n_pct", "n", "mean_sd", "median_iqr", "min_max")

# The statistics read off a survival curve. Written out here rather than taken
# from R/stats.R, so the rule does not hang on the order the files load in.
TFLS_CURVE_STATS <- c("km_events", "km_censored", "km_median", "km_prob")

# A statistic whose N does not add up across a split population: three regimens
# in one class and four in another are not seven between them. Its population
# still does, so its denominator takes part in a sum where its N cannot.
TFLS_NONADDITIVE_N_STATS <- c("n_distinct")

cell_group_key <- function(cells)
  paste(cells$TABLE_ID, cells$COLUMN_ID, cells$SECTION_LABEL, sep = "\r")

# A cell that can be a term of a sum: filled, not a heading, and a count. A
# heading has no number and a row nothing could fill has none either, so
# neither is a term and neither counts as a published one.
relation_terms <- function(cells)
  cells$FILLED == 1L & cells$SECTION == 0L & cells$STAT %in% TFLS_GROUPED_STATS

# A cell that can be a term of a SPLIT - Overall against its classes or its
# subgroups. Every statistic, not only the counts: a printed cell carries its
# population in DENOM whatever it prints, and populations add up across a split.
partition_terms <- function(cells)
  cells$FILLED == 1L & cells$SECTION == 0L

# The row of the shell a cell sits in, for reading the table across its rows. A
# frame that does not carry the shell's own order is read in the order it came
# in, which is the order fill.R writes it in.
cell_row_order <- function(cells)
  if ("ROW_ORDER" %in% names(cells)) cells$ROW_ORDER else seq_len(nrow(cells))

# One relation: the rows of the cell frame one sum ties together, the words for
# why a cell of it was withheld, and what the sum is a sum OF - a cell of the
# frame (`total`), the column's own denominator (`denominator`), or nothing a
# reader can see, in which case only a lone unknown gives anything away.
# `kind` says what adds up: down a column the counts do; across a split
# population the populations do as well.
tfls_relation <- function(members, why, total = NA_integer_,
                          denominator = FALSE, kind = "column")
  list(members = as.integer(members), why = why, total = as.integer(total),
       denominator = isTRUE(denominator), kind = kind)

# The shell's columns for these cells, however the caller holds them: the whole
# shell, its columns frame, or nothing. Nothing still works - the sums down a
# column are in the cell frame itself - and only the sums across a row are lost
# with it, so an older caller withholds what it always did and more.
#
# The names are the shell's own, through the shell's own alias list, because a
# caller may hold the frame as columns.csv spells it - col_id, lot_num - rather
# than as load_shells() renames it. A selector the frame does not carry at all
# is read as empty, which can only put more columns in one sum and so withhold
# more; only table_id and the column id are asked for, because without them no
# cell can be found.
relation_columns <- function(shell) {
  if (is.null(shell)) return(NULL)
  d <- if (is.data.frame(shell)) shell else shell$columns
  if (is.null(d) || !is.data.frame(d) || !nrow(d)) return(NULL)
  names(d) <- tolower(trimws(names(d)))
  alias <- TFLS_SHELL_SCHEMA$columns$alias
  for (nm in names(alias)) {
    if (nm %in% names(d)) next
    hit <- intersect(alias[[nm]], names(d))
    if (length(hit)) names(d)[match(hit[1], names(d))] <- nm
  }
  if (!all(c("table_id", "column_id") %in% names(d))) return(NULL)
  for (nm in c("label", "cohort", "line", "class", "subgroup", "period"))
    if (!nm %in% names(d)) d[[nm]] <- rep("", nrow(d))
  d
}

# The variable a subgroup column names, and which level of it. A subgroup is a
# restriction - S_FRAILTY:FRAIL=1, or CONCEPT=neuropathy&HAS_HISTORY=0 - so
# what stands before the last '=' names the variable and what follows it is the
# level. Columns agreeing on the variable are the levels the shell has for it,
# and that set is taken as the partition.
subgroup_variable <- function(x) {
  raw <- chr(x)
  at <- gregexpr("=", raw, fixed = TRUE)[[1]]
  at <- at[at > 0L]
  if (!length(at)) return(list(var = "", level = ""))
  i <- max(at)
  list(var = trimws(substr(raw, 1L, i - 1L)),
       level = trimws(substr(raw, i + 1L, nchar(raw))))
}

# Down a column: a parent row and the run of rows indented one step under it.
#
# A child that could not be filled is not a term, which leaves the sum reading
# for less than the parent holds. That is the safe way round: it can only make
# the relation fire where the true sum would not have, and firing withholds.
relations_down_column <- function(cells, ok) {
  out <- list()
  if (!"INDENT" %in% names(cells)) return(out)
  ind <- suppressWarnings(as.integer(cells$INDENT))
  ind[is.na(ind)] <- 0L
  sec <- if ("SECTION" %in% names(cells)) cells$SECTION == 1L
         else rep(FALSE, nrow(cells))
  lab <- if ("SECTION_LABEL" %in% names(cells)) chr(cells$SECTION_LABEL)
         else rep("", nrow(cells))
  rlab <- if ("ROW_LABEL" %in% names(cells)) chr(cells$ROW_LABEL)
          else rep("", nrow(cells))
  ord <- cell_row_order(cells)
  key <- paste(cells$TABLE_ID, cells$COLUMN_ID, sep = "\r")
  for (k in unique(key)) {
    idx <- which(key == k)
    idx <- idx[order(ord[idx], idx)]
    for (a in seq_along(idx)) {
      i <- idx[a]
      if (sec[i] || !ok[i]) next
      kids <- integer(0)
      b <- a + 1L
      while (b <= length(idx)) {
        j <- idx[b]
        # A heading, a new section or a row back out at the parent's own level
        # ends the run. Anything deeper belongs to a child, not to this parent.
        if (sec[j] || !identical(lab[j], lab[i]) || ind[j] <= ind[i]) break
        if (ind[j] == ind[i] + 1L && ok[j]) kids <- c(kids, j)
        b <- b + 1L
      }
      if (!length(kids)) next
      out[[length(out) + 1L]] <- tfls_relation(c(i, kids), paste0(
        "withheld with another cell under the subtotal '",
        rlab[i], "' in this column, which that subtotal less ",
        "the published rest would otherwise give away"), total = i)
    }
  }
  out
}

# Across columns: a population and the columns that split it.
#
# A column with no subgroup is a population - Overall, or one regimen class. It
# is split two ways. Columns that name levels of one variable (a subgroup) over
# that same population split it; and a regimen class is itself one level of the
# class, so Overall is split by the class columns beside it. A split in ANOTHER
# table counts the same: T5c has no Overall of its own, and its two age columns
# for a line split T4's Overall for that line, row for row.
#
# Every statistic takes part, not only the counts. A printed cell carries its
# population in DENOM whatever it prints, and populations add up across a split
# - Overall's mean age and one subgroup's give away the other subgroup's size
# between them, and the old rule, which read counts alone, never saw that.
#
# In one table a row is matched by where it sits. Between tables it is matched by
# what it reads - statistic, source, measure and filter - because T5c's rwTTNT
# median is T4's rwTTNT median over part of the same patients.
#
# One level is not a split, so two are asked for.
relations_partition <- function(cells, ok, shell) {
  out <- list()
  cols <- relation_columns(shell)
  if (is.null(cols)) return(out)
  cls <- toupper(chr(cols$class)); cls[!nzchar(cls)] <- "OVERALL"
  base <- paste(chr(cols$cohort), chr(cols$line), chr(cols$period), sep = "\r")
  sub <- lapply(chr(cols$subgroup), subgroup_variable)
  varn <- vapply(sub, `[[`, character(1), "var")
  lvl  <- vapply(sub, `[[`, character(1), "level")
  has_sub <- nzchar(chr(cols$subgroup))
  by_sub <- has_sub & nzchar(varn) & nzchar(lvl)
  by_cls <- !has_sub & cls != "OVERALL"
  part_of <- rep(NA_character_, nrow(cols))
  part_of[by_sub] <- paste(chr(cols$table_id[by_sub]), base[by_sub], cls[by_sub],
                           "subgroup", varn[by_sub], sep = "\r")
  part_of[by_cls] <- paste(chr(cols$table_id[by_cls]), base[by_cls], "class",
                           sep = "\r")

  tid <- chr(cells$TABLE_ID); cid <- chr(cells$COLUMN_ID)
  ord <- cell_row_order(cells)
  rkey <- if ("ROW_KEY" %in% names(cells)) chr(cells$ROW_KEY)
          else rep("", nrow(cells))
  for (pk in unique(part_of[!is.na(part_of)])) {
    lv <- which(part_of == pk)
    if (length(lv) < 2L) next
    ptid <- chr(cols$table_id[lv[1]])
    in_lv <- which(ok & tid == ptid & cid %in% chr(cols$column_id[lv]))
    if (!length(in_lv)) next
    # The population the levels split: a subgroup splits the column of its own
    # class; a class splits Overall.
    total_col <- !has_sub & base == base[lv[1]] &
      (if (by_sub[lv[1]]) cls == cls[lv[1]] else cls == "OVERALL")
    for (t in which(total_col)) {
      ttid <- chr(cols$table_id[t]); tcid <- chr(cols$column_id[t])
      tlab <- chr(cols$label[t]); if (!nzchar(tlab)) tlab <- tcid
      same <- identical(ttid, ptid)
      where <- if (same) "" else paste0(" in ", ttid)
      for (ti in which(ok & tid == ttid & cid == tcid)) {
        parts <- if (same) in_lv[ord[in_lv] == ord[ti]]
                 else if (nzchar(rkey[ti])) in_lv[rkey[in_lv] == rkey[ti]]
                 else integer(0)
        if (!length(parts)) next
        out[[length(out) + 1L]] <- tfls_relation(c(ti, parts), paste0(
          "withheld with another cell of the columns that split '", tlab, "'",
          where, ", which that total less the published rest would otherwise ",
          "give away"), total = ti, kind = "partition")
      }
    }
  }
  out
}

# Against the column's own N: the levels of a variable, under one section
# heading, in one column. The total is not a cell here - it is the denominator
# printed in the column header - so the levels alone are the relation.
#
# Two of them, where the section is nested. Every count cell of the section is
# the group this file has always taken, kept so that nothing it used to
# withhold is published now. The outdented rows of the section are the levels
# the denominator is really split into - "<75 years" and "at least 75 years",
# not the three bands inside the first - and that is the sum a cell outside a
# subtotal can be read off.
relations_against_denominator <- function(cells, ok) {
  out <- list()
  key <- cell_group_key(cells)
  ind <- if ("INDENT" %in% names(cells)) suppressWarnings(as.integer(cells$INDENT))
         else rep(0L, nrow(cells))
  ind[is.na(ind)] <- 0L
  for (g in unique(key[ok])) {
    w <- which(ok & key == g)
    if (length(w) < 2L) next
    top <- w[ind[w] == min(ind[w])]
    # Flat, the group IS the levels the denominator splits into, so its sum is
    # the denominator. Nested, it holds subtotals and the rows under them
    # together, which add up to more than anything - so it is kept for a lone
    # unknown only, and the outdented rows carry the sum.
    flat <- length(top) == length(w)
    out[[length(out) + 1L]] <- tfls_relation(w, paste0(
      "withheld with another cell of its group, which the group total ",
      "would otherwise give away"), denominator = flat)
    if (flat || length(top) < 2L) next
    out[[length(out) + 1L]] <- tfls_relation(top, paste0(
      "withheld with another cell of the levels this column's ",
      "denominator is split into, which that denominator less the published ",
      "rest would otherwise give away"), denominator = TRUE)
  }
  out
}

# A survival curve, one column's: its events, its censored, its median and its
# probabilities, withheld together or not at all.
#
# They are one population read several ways, and events and censored add up
# to it. The sums across a split were closed a row at a time, and each row
# gave up its own smallest term - the events row one class, the censored row,
# whose N is the censored, another. Each class's patients are printed beside
# whichever count survives, so a withheld events cell was its population less
# the censored printed under it, and with that one known the events row gave
# up the class the floor had withheld in the first place. A median or a
# probability does not add up, but it is read off the same patients and says
# how many of them had the event by when, so it goes with them.
#
# Keyed by table, column and curve - fill.R's CURVE_KEY, what the row reads as
# the fill reads it (curve_key()), so two spellings of one curve are one unit.
# A frame without the key is grouped by source and measure, which can only put
# more cells in one unit.
curve_units <- function(cells) {
  curve <- partition_terms(cells) & cells$STAT %in% TFLS_CURVE_STATS
  if (!any(curve)) return(list())
  what <- if ("CURVE_KEY" %in% names(cells)) chr(cells$CURVE_KEY)
          else rep("", nrow(cells))
  bare <- !nzchar(what)
  what[bare] <- paste(chr(cells$SOURCE), chr(cells$MEASURE), sep = "|")[bare]
  key <- paste(cells$TABLE_ID, cells$COLUMN_ID, what, sep = "\r")
  u <- split(which(curve), key[curve])
  unname(Filter(function(m) length(m) > 1L, u))
}

TFLS_CURVE_WHY <- paste0(
  "withheld with the rest of the curve it is read from: a curve's events and ",
  "censored add up to its population, so one printed beside the other gives ",
  "the other away")

# Every sum that holds among the cells of these tables.
cell_relations <- function(cells, shell = NULL) {
  ok <- relation_terms(cells)
  part <- partition_terms(cells)
  if (!any(part)) return(list())
  c(if (any(ok)) relations_down_column(cells, ok),
    relations_partition(cells, part, shell),
    if (any(ok)) relations_against_denominator(cells, ok))
}

# Whether the printed terms of a sum leave enough out.
#
# The reader has the total and the printed terms, and so the difference: the
# cells not printed, plus any patients none of the terms counts. That
# difference is a count of patients like any other, so it reaches the floor or
# it is given away - two withheld cells of 10 and 5 add up to 15, and 15 is a
# number on the page. A difference of zero with a cell withheld says that cell
# is zero, which is withheld everywhere else in this folder, so it is not
# published here by subtraction either. A sum whose printed terms come to MORE
# than the total is not a split (a patient counted in two of its terms) and
# nothing is read off it. A total nobody can see leaves nothing to subtract
# from.
relation_covers <- function(cells, was, r, floor_n) {
  m <- r$members
  if (isTRUE(r$denominator)) {
    pub <- m[was[m] == 0L]
    if (!length(pub)) return(TRUE)
    tot_n <- cells$DENOM[pub[1]]; tot_d <- NA_real_
    lv <- m
    stat <- cells$STAT[pub[1]]
  } else if (length(r$total) == 1L && !is.na(r$total)) {
    t <- r$total
    if (was[t] == 1L) return(TRUE)
    tot_n <- cells$N[t]; tot_d <- cells$DENOM[t]
    lv <- setdiff(m, t)
    stat <- cells$STAT[t]
  } else return(TRUE)
  pub <- lv[was[lv] == 0L]
  hidden <- any(was[lv] == 1L)
  short <- function(total, parts) {
    if (length(total) != 1L || is.na(total) || anyNA(parts)) return(FALSE)
    x <- total - sum(parts)
    if (x < 0) return(FALSE)
    (hidden || x > 0) && !tfls_released(x, floor_n)
  }
  if (!stat %in% TFLS_NONADDITIVE_N_STATS && short(tot_n, cells$N[pub]))
    return(FALSE)
  if (identical(r$kind, "partition")) {
    if (short(tot_d, cells$DENOM[pub])) return(FALSE)
    # A curve's censored patients add up across a split too.
    if (stat %in% TFLS_CURVE_STATS &&
        short(tot_d - tot_n, cells$DENOM[pub] - cells$N[pub])) return(FALSE)
  }
  TRUE
}

# The relations, closed.
#
# One sweep at a time, and each sweep decides from the state the sweep started
# in. A relation gives up one more of its printed cells when exactly one of its
# terms is withheld - that one term IS the total less the rest - or when what
# its printed terms leave out does not reach the floor. It gives up its
# smallest printed term, and a term before its total. Withholding that cell can
# leave another relation it is a term of short, so the sweeps repeat until one
# changes nothing. It terminates because a sweep that changes anything
# withholds at least one more cell of a finite frame and nothing is ever
# published back.
#
# `units` are the curves (curve_units()). A curve with any cell withheld loses
# the rest of them at the end of the sweep. And a relation that has to give up
# a term takes one whose curve is already going where it has one - the rest of
# that curve is withheld anyway, so it costs nothing - which is what makes the
# events row and the censored row give up the SAME class rather than one each.
close_relations <- function(cells, relations, floor_n, units = list()) {
  if (!length(relations) && !length(units)) return(cells)
  unit_of <- rep(NA_integer_, nrow(cells))
  for (k in seq_along(units)) unit_of[units[[k]]] <- k
  going <- function(i) !is.na(unit_of[i]) &&
    any(cells$SUPPRESSED[units[[unit_of[i]]]] == 1L)
  guard <- nrow(cells) + 1L
  repeat {
    was <- cells$SUPPRESSED
    n0 <- cells$N
    fired <- FALSE
    for (r in relations) {
      m <- r$members
      why <- if (sum(was[m] == 1L) == 1L) r$why
             else if (!relation_covers(cells, was, r, floor_n)) paste0(
               "withheld because the cells of a sum it belongs to that are not ",
               "printed would otherwise add up to fewer than ", floor_n,
               ", which the total less the printed rest gives away")
             else NULL
      if (is.null(why)) next
      open <- m[was[m] == 0L]
      terms <- setdiff(open, r$total)
      if (length(terms)) open <- terms
      if (!length(open)) next
      free <- vapply(open, going, logical(1))
      if (any(free)) open <- open[free]
      n <- n0[open]
      n[is.na(n)] <- Inf
      pick <- open[which.min(n)]
      # Another relation may have taken it already this sweep, and then the
      # relation has its second unknown and there is nothing left to give away.
      if (cells$SUPPRESSED[pick] == 1L) next
      cells <- withhold_cell(cells, pick, floor_n, why)
      fired <- TRUE
    }
    for (u in units) {
      w <- cells$SUPPRESSED[u] == 1L
      if (!any(w) || all(w)) next
      for (i in u[!w]) cells <- withhold_cell(cells, i, floor_n, TFLS_CURVE_WHY)
      fired <- TRUE
    }
    guard <- guard - 1L
    if (!fired || guard <= 0L) break
  }
  cells
}

# The floor, then the relations, over a frame of cells.
#
# `shell` is the shell definition the cells were filled from, for the columns
# a row is totalled across. It is optional: without it the sums down a column
# and against the column's denominator are still read off the frame itself, so
# a caller that does not pass it withholds everything it used to and more.
suppress_cells <- function(cells, floor_n, shell = NULL) {
  if (is.null(cells) || !nrow(cells)) return(cells)
  if (!"SUPPRESSED" %in% names(cells)) cells$SUPPRESSED <- 0L
  if (!"REASON" %in% names(cells)) cells$REASON <- ""
  live <- cells$FILLED == 1L & cells$SECTION == 0L
  pop_n <- if ("POP_N" %in% names(cells)) suppressWarnings(as.numeric(cells$POP_N))
           else rep(NA_real_, nrow(cells))
  for (i in which(live)) {
    d <- cells$DENOM[i]
    n <- cells$N[i]
    st <- cells$STAT[i]
    # A curve's two counts. km_censored carries the censored in N; the rest
    # carry the events there.
    ev <- if (identical(st, "km_censored")) d - n else n
    cz <- if (identical(st, "km_censored")) n else d - n
    if (is.na(d))
      cells <- withhold_cell(cells, i, floor_n,
        "the population behind this cell could not be counted, so it has not been shown to reach the floor")
    else if (!tfls_released(d, floor_n))
      cells <- withhold_cell(cells, i, floor_n,
        paste0("fewer than ", floor_n, " in the population this cell is out of"))
    else if (st %in% TFLS_COUNT_FLOOR_STATS && !tfls_released(n, floor_n))
      cells <- withhold_cell(cells, i, floor_n,
        paste0("fewer than ", floor_n, " patients in this cell"))
    else if (st %in% TFLS_CURVE_STATS && !tfls_released(ev, floor_n))
      cells <- withhold_cell(cells, i, floor_n, paste0(
        "fewer than ", floor_n, " patients with the event on the curve this ",
        "cell is read from, and the curve publishes them"))
    else if (st %in% TFLS_CURVE_STATS && !tfls_released(cz, floor_n))
      cells <- withhold_cell(cells, i, floor_n, paste0(
        "fewer than ", floor_n, " patients censored on the curve this cell is ",
        "read from, and its population less its events publishes them"))
    else if (!is.na(pop_n[i]) && pop_n[i] > d &&
             !tfls_released(pop_n[i] - d, floor_n))
      cells <- withhold_cell(cells, i, floor_n, paste0(
        "fewer than ", floor_n, " of this column's patients are left out by ",
        "this row's own filter, and a row without it still counts them"))
  }
  close_relations(cells, cell_relations(cells, shell), floor_n,
                  curve_units(cells))
}

# The sums that run between tables.
#
# Each table was closed on its own when it was filled. A population split in
# one table and totalled in another - T5c's age columns and T4's Overall - is
# only a sum once both are in hand, so the tables go through the pass again
# together, every relation within and between, and whatever it withholds is
# withheld in the table it came from. Nothing is ever published back, so a
# second pass can only add.
suppress_across_tables <- function(filled, shell, floor_n) {
  frames <- lapply(filled, `[[`, "cells")
  sizes <- vapply(frames, function(f) if (is.null(f)) 0L else nrow(f), integer(1))
  if (sum(sizes) == 0L) return(filled)
  all <- do.call(rbind, frames[sizes > 0L])
  rownames(all) <- NULL
  all <- close_relations(all, cell_relations(all, shell), floor_n,
                         curve_units(all))
  at <- 0L
  for (k in seq_along(filled)) {
    if (sizes[k] == 0L) next
    part <- all[at + seq_len(sizes[k]), , drop = FALSE]
    rownames(part) <- NULL
    filled[[k]]$cells <- part
    at <- at + sizes[k]
  }
  filled
}
