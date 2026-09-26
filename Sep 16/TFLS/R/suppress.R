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
#   * a number printed more than once - a repeated row, or T1b's Overall
#     columns, which are T1's - is one term in every sum and is withheld in
#     every place or none (cell_identity(), copy_units());
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
# population the populations do as well. `exact` is FALSE for a sum whose
# total holds more than its terms can name - a part inside a larger part - so
# one withheld term is not the total less the rest, and only what the printed
# terms leave out is read.
tfls_relation <- function(members, why, total = NA_integer_,
                          denominator = FALSE, kind = "column", exact = TRUE)
  list(members = as.integer(members), why = why, total = as.integer(total),
       denominator = isTRUE(denominator), kind = kind, exact = !isFALSE(exact))

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

# --- what a subgroup selects ------------------------------------------------
#
# A subgroup read as the fill applies it (fill.R, restrict_to_subgroup()): a
# set of conditions, each on one column of one table. Read that way the
# spelling drops out. NEUROPATHY=YES and NEUROPATHY=Y are one named subgroup,
# and both are S_COMORB_SUBGROUP:CONCEPT=neuropathy&HAS_HISTORY=1, which is
# what the fill reads for them; AGE_YEARS<75 and AGE_YEARS>=75 are two ranges
# of one number that do not meet. Cut at the last '=', as this file once cut
# them, the first pair were two levels each where there was one, so a split
# counted every patient twice and read as no split at all, and the second
# were two different variables - one of them none - so theirs was never seen.
#
# A condition is `in` (=, values compared as text, as the fill compares them),
# `out` (!=) or a `range` (<, <=, >, >=, one number). Its table is the one the
# subgroup names, a named subgroup's own, or '*': wherever the fill finds the
# column for the row being summarised, which is one place for every column of
# that row. Two conditions on one column are one: a band written as
# AGE_YEARS>=65&AGE_YEARS<75 is one range.
sg_cond <- function(tab, col, kind, vals = character(0), lo = -Inf,
                    lo_in = FALSE, hi = Inf, hi_in = FALSE) {
  var <- paste0(toupper(chr(tab)), ":", toupper(chr(col)))
  vals <- sort(unique(chr(vals)), method = "radix")
  what <- if (identical(kind, "range"))
    paste0(if (lo_in) "[" else "(", format(lo, digits = 15), ",",
           format(hi, digits = 15), if (hi_in) "]" else ")")
  else paste(vals, collapse = "|")
  list(var = var, kind = kind, vals = vals, lo = lo, lo_in = isTRUE(lo_in),
       hi = hi, hi_in = isTRUE(hi_in), key = paste0(var, " ", kind, " ", what))
}

sg_num <- function(v) suppressWarnings(as.numeric(chr(v)))

# Whether numbers fall in a range. A value that is not a number falls in none,
# as it does in the fill (apply_term()).
sg_in_range <- function(x, r)
  !is.na(x) & (x > r$lo | (r$lo_in & x == r$lo)) & (x < r$hi | (r$hi_in & x == r$hi))

sg_range <- function(lo, lo_in, hi, hi_in)
  sg_cond("", "", "range", lo = lo, lo_in = lo_in, hi = hi, hi_in = hi_in)

# The rows two conditions on one column both let through, as one condition, or
# NULL where that is no single list or range (a range with a value cut out).
sg_both <- function(a, b) {
  k <- paste(a$kind, b$kind)
  out <- switch(k,
    "in in" = sg_cond("", "", "in", intersect(a$vals, b$vals)),
    "in out" = sg_cond("", "", "in", setdiff(a$vals, b$vals)),
    "out in" = sg_cond("", "", "in", setdiff(b$vals, a$vals)),
    "out out" = sg_cond("", "", "out", union(a$vals, b$vals)),
    "in range" = sg_cond("", "", "in", a$vals[sg_in_range(sg_num(a$vals), b)]),
    "range in" = sg_cond("", "", "in", b$vals[sg_in_range(sg_num(b$vals), a)]),
    "range range" = {
      lo <- max(a$lo, b$lo); hi <- min(a$hi, b$hi)
      sg_range(lo, (a$lo < lo || a$lo_in) && (b$lo < lo || b$lo_in),
               hi, (a$hi > hi || a$hi_in) && (b$hi > hi || b$hi_in))
    },
    NULL)
  if (is.null(out)) return(NULL)
  sg_cond(sub(":.*$", "", a$var), sub("^[^:]*:", "", a$var), out$kind, out$vals,
          out$lo, out$lo_in, out$hi, out$hi_in)
}

# Whether no row meets both of two conditions on one column.
sg_disjoint <- function(a, b) {
  switch(paste(a$kind, b$kind),
    "in in" = !length(intersect(a$vals, b$vals)),
    "in out" = all(a$vals %in% b$vals),
    "out in" = all(b$vals %in% a$vals),
    "in range" = !any(sg_in_range(sg_num(a$vals), b)),
    "range in" = !any(sg_in_range(sg_num(b$vals), a)),
    "range range" = {
      lo <- max(a$lo, b$lo); hi <- min(a$hi, b$hi)
      lo > hi || (lo == hi && !(sg_in_range(lo, a) && sg_in_range(lo, b)))
    },
    FALSE)
}

# Whether every row meeting `a` meets `b`.
sg_within <- function(a, b) {
  if (identical(a$key, b$key)) return(TRUE)
  switch(paste(a$kind, b$kind),
    "in in" = all(a$vals %in% b$vals),
    "in out" = !any(a$vals %in% b$vals),
    "in range" = all(sg_in_range(sg_num(a$vals), b)),
    "out out" = all(b$vals %in% a$vals),
    "range range" =
      (a$lo > b$lo || (a$lo == b$lo && (b$lo_in || !a$lo_in))) &&
      (a$hi < b$hi || (a$hi == b$hi && (b$hi_in || !a$hi_in))),
    "range out" = !any(sg_in_range(sg_num(b$vals), a)),
    FALSE)
}

# A named subgroup as the conditions the fill reads for it
# (named_subgroup_patients()).
named_subgroup_conditions <- function(def, t) {
  if (!identical(chr(t$op), "=")) return(named_subgroup_op_why(t))
  v <- chr(t$value)
  if (!is.null(def$bands)) {
    band <- if (length(v) == 1L) subgroup_band(v) else ""
    if (!nzchar(band)) return(named_subgroup_value_why(t))
    b <- def$bands[[band]]
    return(list(if (identical(b$op, "<"))
                  sg_cond(def$table, def$column, "range", hi = b$cut)
                else sg_cond(def$table, def$column, "range", lo = b$cut, lo_in = TRUE)))
  }
  u <- toupper(v)
  want <- if (length(u) == 1L && u %in% TFLS_SUBGROUP_YES) "1"
          else if (length(u) == 1L && u %in% TFLS_SUBGROUP_NO) "0"
          else return(named_subgroup_value_why(t))
  c(if (!is.null(def$concept))
      list(sg_cond(def$table, def$concept_col, "in", def$concept)),
    list(sg_cond(def$table, def$flag, "in", want)))
}

# A subgroup's conditions, one per column, and the key that names the
# population they select. `ok` is FALSE, with the reason, for a subgroup that
# is not one this reads - a condition with nothing to compare, a range against
# something that is not one number, a named subgroup's value it does not have -
# and shells.R refuses such a column when the shell is loaded, because what
# its cells add up to with the columns beside it could not be told.
subgroup_conditions <- function(x) {
  raw <- chr(x)
  none <- list(ok = TRUE, conds = list(), key = "", why = "")
  if (!nzchar(raw)) return(none)
  bad <- function(why) list(ok = FALSE, conds = list(), key = paste0("?", raw),
                            why = why)
  sg <- parse_subgroup(raw)
  if (!isTRUE(sg$ok)) return(bad(sg$why))
  out <- list()
  add <- function(cn) {
    at <- match(cn$var, vapply(out, `[[`, "", "var"))
    if (is.na(at)) return(c(out, list(cn)))
    both <- sg_both(out[[at]], cn)
    if (is.null(both)) return(NULL)
    out[[at]] <- both
    out
  }
  for (t in sg$terms) {
    col <- toupper(chr(t$column)); op <- chr(t$op); v <- chr(t$value)
    if (!nzchar(op) || !length(v))
      return(bad(paste0("'", chr(t$raw), "' names the column ", chr(t$column),
                        " but compares it with nothing")))
    def <- if (!nzchar(sg$table)) TFLS_SUBGROUPS[[col]] else NULL
    cns <- if (!is.null(def)) named_subgroup_conditions(def, t)
    else if (op %in% c("=", "!=")) {
      list(sg_cond(if (nzchar(sg$table)) sg$table else "*", col,
                   if (identical(op, "=")) "in" else "out", v))
    } else {
      y <- sg_num(v)
      if (length(v) != 1L || is.na(y))
        return(bad(paste0("'", chr(t$raw), "' compares ", chr(t$column),
                          " with '", paste(v, collapse = "|"), "', and ", op,
                          " takes one number")))
      tab <- if (nzchar(sg$table)) sg$table else "*"
      list(switch(op,
        "<" = sg_cond(tab, col, "range", hi = y),
        "<=" = sg_cond(tab, col, "range", hi = y, hi_in = TRUE),
        ">" = sg_cond(tab, col, "range", lo = y),
        ">=" = sg_cond(tab, col, "range", lo = y, lo_in = TRUE)))
    }
    if (is.character(cns)) return(bad(cns))
    for (cn in cns) {
      nx <- add(cn)
      if (is.null(nx))
        return(bad(paste0("'", raw, "' puts two conditions on ",
                          sub("^\\*:", "", cn$var), " that are not one list ",
                          "of values or one range between them")))
      out <- nx
    }
  }
  keys <- vapply(out, `[[`, "", "key")
  o <- order(keys, method = "radix")
  list(ok = TRUE, conds = out[o],
       key = paste(keys[o], collapse = " & "), why = "")
}

# Whether every patient of subgroup `a` is one of subgroup `b`: each thing `b`
# asks for, `a` asks for too, or something narrower on the same column.
sg_population_within <- function(a, b) {
  av <- vapply(a$conds, `[[`, "", "var")
  all(vapply(b$conds, function(cb) {
    at <- match(cb$var, av)
    !is.na(at) && sg_within(a$conds[[at]], cb)
  }, logical(1)))
}

# The largest sets of levels no two of which meet: each is a split of what
# they are all drawn from. Levels that all miss one another are one set, as
# before; AGE_YEARS=2 and AGE_YEARS>=2 beside AGE_YEARS=1 are two.
sg_families <- function(n, disjoint) {
  if (!n) return(list())
  apart <- matrix(TRUE, n, n)
  for (i in seq_len(n)) for (j in seq_len(n))
    if (i != j) apart[i, j] <- isTRUE(disjoint(i, j))
  if (all(apart)) return(list(seq_len(n)))
  fams <- list()
  grow <- function(cur, cand) {
    if (!length(cand)) {
      # Maximal: nothing outside the set misses all of it.
      rest <- setdiff(seq_len(n), cur)
      if (!any(vapply(rest, function(k) all(apart[k, cur]), logical(1))))
        fams[[length(fams) + 1L]] <<- cur
      return(invisible())
    }
    k <- cand[1]
    grow(c(cur, k), cand[-1][apart[k, cand[-1]]])
    grow(cur, cand[-1])
  }
  if (n <= 12L) grow(integer(0), seq_len(n))
  else for (s in seq_len(n)) {
    cur <- s
    for (k in seq_len(n)) if (!k %in% cur && all(apart[k, cur])) cur <- c(cur, k)
    fams[[length(fams) + 1L]] <- sort(cur)
  }
  unique(lapply(fams, sort))
}

# The same for regimen classes, as column_class_key() resolves them: two
# classes miss one another when no category is in both, and one is inside
# another when its categories are and the other asks for no drug it does not.
class_key_parts <- function(k) {
  drug <- if (grepl(" +", k, fixed = TRUE)) sub("^.* \\+", "", k) else ""
  cats <- strsplit(sub(" \\+.*$", "", k), "|", fixed = TRUE)[[1]]
  list(cats = cats[nzchar(cats)], drug = drug)
}

class_disjoint <- function(a, b) {
  if (identical(a, b)) return(FALSE)
  pa <- class_key_parts(a); pb <- class_key_parts(b)
  !length(intersect(pa$cats, pb$cats))
}

class_within <- function(a, b) {
  pa <- class_key_parts(a); pb <- class_key_parts(b)
  all(pa$cats %in% pb$cats) && (!nzchar(pb$drug) || identical(pa$drug, pb$drug))
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
# A column is a population - Overall, one regimen class, a subgroup of either.
# Columns that select parts of one population no two of which meet split it:
# the levels of a subgroup split the column of the same class with no
# subgroup, and the regimen classes split Overall. A split in ANOTHER table
# counts the same: T5c has no Overall of its own, and its two age columns for
# a line split T4's Overall for that line, row for row - and a split whose
# levels sit in two tables is still one split.
#
# The parts are what the columns select (subgroup_conditions(),
# column_class_key()), not how they are written: a level spelled two ways is
# one level, printed twice (cell_identity()), and levels are a split only when
# they cannot meet, which a list of values, a range or a named subgroup's
# definition shows. Levels that could meet are never taken for a split: their
# sum can pass the total, and a sum past its total is read as no sum at all,
# which would drop the split they were in.
#
# A population inside another is a sum that holds too, with what the rest
# leaves out as its unknown - AGE_YEARS=2 inside AGE_YEARS>=2, a lone subgroup
# inside its column's Overall. Such a sum need not add up exactly, so it is
# closed on what it leaves out alone (`exact` FALSE), never on one withheld
# term: the one term is not the total less the rest when something besides
# the terms is in the total.
#
# Every statistic takes part, not only the counts. A printed cell carries its
# population in DENOM whatever it prints, and populations add up across a split
# - Overall's mean age and one subgroup's give away the other subgroup's size
# between them, and the old rule, which read counts alone, never saw that.
#
# In one table a row is matched by where it sits. Between tables it is matched by
# what it reads - statistic, source, measure and filter - because T5c's rwTTNT
# median is T4's rwTTNT median over part of the same patients. What it reads,
# not how the shell spells it (fill.R, row_keys()): matched on the text, a T5c
# writing s_tte or TTNT_MONTHS matched no row of T4, and its split went
# unclosed.
relations_partition <- function(cells, ok, shell) {
  out <- list()
  cols <- relation_columns(shell)
  if (is.null(cols)) return(out)
  cls <- column_class_key(cols$class, shell_classes(shell))
  base <- paste(chr(cols$cohort), chr(cols$line), chr(cols$period), sep = "\r")
  sgc <- lapply(chr(cols$subgroup), subgroup_conditions)
  pkey <- vapply(sgc, `[[`, "", "key")
  has_sub <- nzchar(chr(cols$subgroup))
  known <- has_sub & vapply(sgc, function(x) isTRUE(x$ok), logical(1))

  tid <- chr(cells$TABLE_ID); cid <- chr(cells$COLUMN_ID)
  ord <- cell_row_order(cells)
  rkey <- if ("ROW_KEY" %in% names(cells)) chr(cells$ROW_KEY)
          else rep("", nrow(cells))
  col_of_cell <- match(paste(tid, cid, sep = "\r"),
                       paste(chr(cols$table_id), chr(cols$column_id), sep = "\r"))
  live <- which(ok & !is.na(col_of_cell))
  by_col <- split(live, col_of_cell[live])
  cells_of <- function(k) by_col[[as.character(k)]] %||% integer(0)
  sec <- if ("SECTION" %in% names(cells)) cells$SECTION == 1L else rep(FALSE, nrow(cells))
  laid <- which(!sec & !is.na(col_of_cell))
  by_col_laid <- split(laid, col_of_cell[laid])
  laid_of <- function(k) by_col_laid[[as.character(k)]] %||% integer(0)

  # One sum per printed cell of each column holding the total: the cells of
  # the part columns on the same row. `parts` holds the columns of each part.
  # An exact split is exact on a row only where every part is on the page
  # there: a table closed on its own before the tables are read together does
  # not have the part another table prints, and without it one withheld term
  # is not the total less the rest. A part that is on the page but could not
  # be filled still counts as there, as it always has - the sum then fires
  # where the true one might not, and firing withholds.
  emit <- function(total_cols, parts, exact, what) {
    if (!length(total_cols) || !length(parts)) return(invisible())
    pc <- lapply(parts, function(cs) unlist(lapply(cs, cells_of)))
    pl <- lapply(parts, function(cs) unlist(lapply(cs, laid_of)))
    if (!length(unlist(pc))) return(invisible())
    for (t in total_cols) {
      ttid <- chr(cols$table_id[t])
      tlab <- chr(cols$label[t]); if (!nzchar(tlab)) tlab <- chr(cols$column_id[t])
      for (ti in cells_of(t)) {
        on_row <- function(x) x[(tid[x] == ttid & ord[x] == ord[ti]) |
                                  (tid[x] != ttid & nzchar(rkey[ti]) & rkey[x] == rkey[ti])]
        got <- setdiff(unlist(lapply(pc, on_row)), ti)
        if (!length(got)) next
        whole <- exact && all(vapply(pl, function(x) length(on_row(x)) > 0L, logical(1)))
        where <- if (all(tid[got] == ttid)) "" else paste0(" in ", ttid)
        out[[length(out) + 1L]] <<- tfls_relation(c(ti, got), paste0(
          "withheld with another cell of the columns ", what, " '", tlab, "'",
          where, ", which that total less the published rest would otherwise ",
          "give away"), total = ti, kind = "partition", exact = whole)
      }
    }
  }

  # The splits of one population among columns of one kind. `pops` are the
  # distinct parts, `members[[k]]` the columns selecting part k, `families`
  # the sets of parts no two of which meet, `inside(k, j)` whether part k lies
  # in part j, and `totals` the columns holding the population itself.
  close_splits <- function(pops, members, families, inside, totals, what) {
    multi <- Filter(function(f) length(f) >= 2L, families)
    in_multi <- unique(unlist(multi))
    for (f in families) {
      cols_f <- members[f]
      lone <- length(f) == 1L
      # Against the population itself: a split of two or more adds up to it;
      # a lone part, where no split holds it, leaves the rest as its unknown.
      if (!lone) emit(totals, cols_f, TRUE, what)
      else if (!f %in% in_multi) emit(totals, cols_f, FALSE, what)
      # Against a part that holds every one of these.
      for (j in setdiff(seq_along(pops), f)) {
        if (!all(vapply(f, function(k) inside(k, j), logical(1)))) next
        if (lone && any(vapply(multi, function(g) f %in% g &&
                                 all(vapply(g, function(k) inside(k, j), logical(1))),
                               logical(1)))) next
        emit(members[[j]], cols_f, FALSE, "inside")
      }
    }
  }

  # Subgroups, within each population of one base and one class. A split is
  # read on one column at a time: levels alike in everything else and apart on
  # that column. Neuropathy with a history and without are alike in CONCEPT
  # and apart on HAS_HISTORY; with a history of neuropathy and of diabetes are
  # apart on CONCEPT, but a patient can have both, one row each, so they are
  # no split.
  scope <- paste(base, cls, sep = "\r")
  for (sc in unique(scope[known])) {
    idx <- which(known & scope == sc)
    keys <- unique(pkey[idx])
    pops <- lapply(keys, function(k) sgc[[idx[match(k, pkey[idx])]]])
    members <- lapply(keys, function(k) idx[pkey[idx] == k])
    totals <- which(!has_sub & scope == sc)
    inside <- function(k, j) sg_population_within(pops[[k]], pops[[j]])
    groups <- list()
    for (k in seq_along(pops)) for (cn in pops[[k]]$conds) {
      ctx <- setdiff(vapply(pops[[k]]$conds, `[[`, "", "key"), cn$key)
      g <- paste(c(cn$var, sort(ctx, method = "radix")), collapse = "\n")
      groups[[g]] <- list(k = c(groups[[g]]$k, k),
                          conds = c(groups[[g]]$conds, list(cn)))
    }
    fams <- list()
    for (g in groups) {
      fs <- sg_families(length(g$conds),
                        function(i, j) sg_disjoint(g$conds[[i]], g$conds[[j]]))
      fams <- c(fams, lapply(fs, function(f) sort(g$k[f])))
    }
    close_splits(pops, members, unique(fams), inside, totals, "that split")
  }

  # Regimen classes, within each population of one base and one subgroup.
  by_cls <- cls != "OVERALL"
  cscope <- paste(base, pkey, sep = "\r")
  for (sc in unique(cscope[by_cls])) {
    idx <- which(by_cls & cscope == sc)
    keys <- unique(cls[idx])
    members <- lapply(keys, function(k) idx[cls[idx] == k])
    totals <- which(!by_cls & cscope == sc)
    fam <- sg_families(length(keys),
                       function(i, j) class_disjoint(keys[i], keys[j]))
    close_splits(as.list(keys), members, fam,
                 function(k, j) class_within(keys[k], keys[j]), totals,
                 "that split")
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

# A column's regimen class as class_selection() resolves it - the categories
# it selects and the drug that refines them - so a class named by its id and
# the same class named by its category are one class, as they are one
# selection. Where the shell's classes are not in hand, or the class cannot be
# resolved (and so is never filled), its text stands in.
shell_classes <- function(shell)
  if (is.list(shell) && !is.data.frame(shell) && is.data.frame(shell$classes))
    shell$classes else NULL

column_class_key <- function(class, classes = NULL) {
  vapply(chr(class), function(v) {
    if (!nzchar(v)) return("OVERALL")
    if (!is.null(classes) && exists("class_selection", mode = "function")) {
      sel <- class_selection(v, classes)
      if (identical(sel$kind, "all")) return("OVERALL")
      if (identical(sel$kind, "categories"))
        return(paste0(paste(sort(unique(soc_key(sel$categories)), method = "radix"),
                            collapse = "|"),
                      if (nzchar(chr(sel$drug))) paste0(" +", toupper(chr(sel$drug))) else ""))
    }
    toupper(v)
  }, character(1), USE.NAMES = FALSE)
}

# One number printed more than once: the same row read over the same population
# - a shell repeating a row, or T1b's Overall columns, which are T1's. The
# copies are one cell. Counted as several, a split with two printed copies of a
# level summed past its total and was taken for no split at all, and one with
# two withheld copies saw two unknowns where there was one; and a copy
# withheld in one place and printed in another is simply printed. So copies are
# counted once in every sum and withheld together.
#
# A population is keyed by what selects it, not by the column's name or table:
# cohort, line, period, class and subgroup, the subgroup read as the
# conditions the fill applies (subgroup_conditions()): NEUROPATHY=YES and
# NEUROPATHY=Y are one population, and so is the neuropathy column that names
# S_COMORB_SUBGROUP's rows for it. A cell with no row key - a frame built
# by hand - is only ever itself.
cell_population <- function(cells, shell) {
  own <- paste(cells$TABLE_ID, cells$COLUMN_ID, sep = "\r")
  cols <- relation_columns(shell)
  if (is.null(cols)) return(own)
  norm_list <- function(x, as_num = FALSE) vapply(chr(x), function(v) {
    p <- trimws(strsplit(v, "|", fixed = TRUE)[[1]])
    p <- p[nzchar(p)]
    if (as_num) { n <- suppressWarnings(as.integer(p)); p[!is.na(n)] <- as.character(n[!is.na(n)]) }
    paste(sort(unique(toupper(p)), method = "radix"), collapse = "|")
  }, character(1))
  sub_key <- vapply(chr(cols$subgroup), function(s) subgroup_conditions(s)$key,
                    character(1))
  cls <- column_class_key(cols$class, shell_classes(shell))
  pop <- paste(norm_list(cols$cohort), norm_list(cols$line, TRUE),
               toupper(chr(cols$period)), cls, sub_key, sep = "\r")
  at <- match(own, paste(chr(cols$table_id), chr(cols$column_id), sep = "\r"))
  ifelse(is.na(at), own, pop[at])
}

cell_identity <- function(cells, shell = NULL) {
  rk <- if ("ROW_KEY" %in% names(cells)) chr(cells$ROW_KEY) else rep("", nrow(cells))
  keyed <- partition_terms(cells) & nzchar(gsub("\r", "", rk, fixed = TRUE))
  id <- paste0("#", seq_len(nrow(cells)))
  id[keyed] <- paste(cell_population(cells, shell)[keyed], rk[keyed], sep = "\r\r")
  id
}

copy_units <- function(cells, shell = NULL, id = cell_identity(cells, shell)) {
  u <- split(seq_len(nrow(cells)), id)
  unname(Filter(function(m) length(m) > 1L, u))
}

# The groups that are withheld together, merged where they share a cell: a
# repeated row of a curve takes the curve's other rows with it, and they take
# every copy of themselves.
merge_units <- function(units, n) {
  if (!length(units)) return(list())
  root <- seq_len(n)
  find <- function(i) { while (root[i] != i) i <- root[i]; i }
  for (u in units) {
    r <- find(u[1])
    for (i in u[-1]) { ri <- find(i); if (ri != r) root[ri] <- r }
  }
  cells <- unique(unlist(units))
  top <- vapply(cells, find, integer(1))
  unname(Filter(function(m) length(m) > 1L, split(cells, top)))
}

TFLS_COPY_WHY <- paste0(
  "withheld with every other copy of the same number: the same row over the ",
  "same population is printed more than once, and a copy printed elsewhere ",
  "would print it here")

# Every sum that holds among the cells of these tables.
#
# A number printed twice is one term of a sum, not two (cell_identity()): each
# relation keeps the first copy of every member, and the copies follow it
# through copy_units(). A relation left with one member is no sum.
cell_relations <- function(cells, shell = NULL, id = cell_identity(cells, shell)) {
  ok <- relation_terms(cells)
  part <- partition_terms(cells)
  if (!any(part)) return(list())
  rel <- c(if (any(ok)) relations_down_column(cells, ok),
           relations_partition(cells, part, shell),
           if (any(ok)) relations_against_denominator(cells, ok))
  rel <- lapply(rel, function(r) {
    m <- r$members
    keep <- !duplicated(id[m]) | (!is.na(r$total) & m == r$total)
    r$members <- m[keep]
    r
  })
  Filter(function(r) length(r$members) >= 2L, rel)
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
# terms is withheld - that one term IS the total less the rest, where the sum
# is exact (tfls_relation()) - or when what
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
close_relations <- function(cells, relations, floor_n, units = list(),
                            ids = NULL) {
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
      why <- if (!isFALSE(r$exact) && sum(was[m] == 1L) == 1L) r$why
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
      for (i in u[!w]) {
        copy <- !is.null(ids) && any(cells$SUPPRESSED[u][ids[u] == ids[i]] == 1L)
        cells <- withhold_cell(cells, i, floor_n,
                               if (copy) TFLS_COPY_WHY else TFLS_CURVE_WHY)
      }
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
  ids <- cell_identity(cells, shell)
  close_relations(cells, cell_relations(cells, shell, ids), floor_n,
                  merge_units(c(curve_units(cells), copy_units(cells, shell, ids)),
                              nrow(cells)),
                  ids)
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
  ids <- cell_identity(all, shell)
  all <- close_relations(all, cell_relations(all, shell, ids), floor_n,
                         merge_units(c(curve_units(all), copy_units(all, shell, ids)),
                                     nrow(all)),
                         ids)
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
