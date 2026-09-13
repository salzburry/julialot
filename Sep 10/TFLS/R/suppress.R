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
#     cell, so the floor applies to it as well. A rate and a curve are not:
#     the package suppresses a rate on its at-risk count and publishes the few
#     events inside it, and a curve rests on the people it was drawn over;
#   * a denominator that cannot be read is withheld too: a population that has
#     not been shown to reach the floor has not reached it;
#   * a cell that is the last unknown in a sum the shell itself draws is the
#     difference of published numbers, so a second cell of that sum is withheld
#     with it. The sums are the three below: a subtotal down a column, a total
#     across a row, and the levels of a variable against the column's own
#     denominator. Withholding one cell can leave another sum with a single
#     unknown, so the pass is repeated until no sum has one;
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

cell_group_key <- function(cells)
  paste(cells$TABLE_ID, cells$COLUMN_ID, cells$SECTION_LABEL, sep = "\r")

# A cell that can be a term of a sum: filled, not a heading, and a count. A
# heading has no number and a row nothing could fill has none either, so
# neither is a term and neither counts as a published one.
relation_terms <- function(cells)
  cells$FILLED == 1L & cells$SECTION == 0L & cells$STAT %in% TFLS_GROUPED_STATS

# The row of the shell a cell sits in, for reading the table across its rows. A
# frame that does not carry the shell's own order is read in the order it came
# in, which is the order fill.R writes it in.
cell_row_order <- function(cells)
  if ("ROW_ORDER" %in% names(cells)) cells$ROW_ORDER else seq_len(nrow(cells))

# One relation: the rows of the cell frame one sum ties together, and the words
# for why a cell of it was withheld.
tfls_relation <- function(members, why)
  list(members = as.integer(members), why = why)

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
        "withheld with the one other cell under the subtotal '",
        rlab[i], "' in this column, which that subtotal less ",
        "the published rest would otherwise give away"))
    }
  }
  out
}

# Across a row: a total column and the levels of one variable beside it.
#
# The total has to be a cell of the table, because it is the anchor - without
# it the levels sum to nothing a reader can see. One level is not a partition
# of a total, so two are asked for before the shell is read as splitting it.
relations_across_row <- function(cells, ok, shell) {
  out <- list()
  cols <- relation_columns(shell)
  if (is.null(cols)) return(out)
  ord <- cell_row_order(cells)
  at <- paste(cells$TABLE_ID, ord, cells$COLUMN_ID, sep = "\r")
  for (tid in unique(chr(cells$TABLE_ID))) {
    cd <- cols[chr(cols$table_id) == tid, , drop = FALSE]
    if (nrow(cd) < 3L) next
    pop <- paste(chr(cd$cohort), chr(cd$line), chr(cd$class), chr(cd$period),
                 sep = "\r")
    sub <- lapply(chr(cd$subgroup), subgroup_variable)
    varn <- vapply(sub, `[[`, character(1), "var")
    lvl <- vapply(sub, `[[`, character(1), "level")
    is_total <- !nzchar(chr(cd$subgroup))
    is_level <- !is_total & nzchar(varn) & nzchar(lvl)
    rows <- unique(ord[chr(cells$TABLE_ID) == tid & cells$SECTION == 0L])
    for (t in which(is_total)) {
      # The header the total prints under, for the reason. A frame with no
      # labels in it names the column by its id instead of by nothing.
      tlab <- chr(cd$label[t])
      if (!nzchar(tlab)) tlab <- chr(cd$column_id[t])
      for (v in unique(varn[is_level & pop == pop[t]])) {
        part <- unique(chr(cd$column_id[is_level & pop == pop[t] & varn == v]))
        if (length(part) < 2L) next
        for (ro in rows) {
          ti <- match(paste(tid, ro, chr(cd$column_id[t]), sep = "\r"), at)
          pi <- match(paste(tid, ro, part, sep = "\r"), at)
          pi <- pi[!is.na(pi)]
          if (is.na(ti) || !ok[ti]) next
          pi <- pi[ok[pi]]
          if (!length(pi)) next
          out[[length(out) + 1L]] <- tfls_relation(c(ti, pi), paste0(
            "withheld with the one other cell on this row that the total ",
            "column '", tlab, "' sums, which that total less the ",
            "published rest would otherwise give away"))
        }
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
    out[[length(out) + 1L]] <- tfls_relation(w, paste0(
      "withheld with the one other cell of its group, which the group total ",
      "would otherwise give away"))
    top <- w[ind[w] == min(ind[w])]
    if (length(top) < 2L || length(top) == length(w)) next
    out[[length(out) + 1L]] <- tfls_relation(top, paste0(
      "withheld with the one other cell of the levels this column's ",
      "denominator is split into, which that denominator less the published ",
      "rest would otherwise give away"))
  }
  out
}

# Every sum that holds among the cells of these tables.
cell_relations <- function(cells, shell = NULL) {
  ok <- relation_terms(cells)
  if (!any(ok)) return(list())
  c(relations_down_column(cells, ok),
    relations_across_row(cells, ok, shell),
    relations_against_denominator(cells, ok))
}

# The relations, closed.
#
# One sweep at a time, and each sweep decides from the state the sweep started
# in: every relation holding exactly one withheld cell among its terms gives up
# its smallest published one. Withholding that cell can leave a relation it is
# also a term of with one unknown, so the sweeps repeat until one changes
# nothing. It terminates because a sweep that changes anything withholds at
# least one more cell of a finite frame and nothing is ever published back.
close_relations <- function(cells, relations, floor_n) {
  if (!length(relations)) return(cells)
  guard <- nrow(cells) + 1L
  repeat {
    was <- cells$SUPPRESSED
    n0 <- cells$N
    fired <- FALSE
    for (r in relations) {
      m <- r$members
      if (sum(was[m] == 1L) != 1L) next
      open <- m[was[m] == 0L]
      if (!length(open)) next
      n <- n0[open]
      n[is.na(n)] <- Inf
      pick <- open[which.min(n)]
      # Another relation may have taken it already this sweep, and then the
      # relation has its second unknown and there is nothing left to give away.
      if (cells$SUPPRESSED[pick] == 1L) next
      cells <- withhold_cell(cells, pick, floor_n, r$why)
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
  for (i in which(live)) {
    d <- cells$DENOM[i]
    n <- cells$N[i]
    if (is.na(d))
      cells <- withhold_cell(cells, i, floor_n,
        "the population behind this cell could not be counted, so it has not been shown to reach the floor")
    else if (!tfls_released(d, floor_n))
      cells <- withhold_cell(cells, i, floor_n,
        paste0("fewer than ", floor_n, " in the population this cell is out of"))
    else if (cells$STAT[i] %in% TFLS_COUNT_FLOOR_STATS && !tfls_released(n, floor_n))
      cells <- withhold_cell(cells, i, floor_n,
        paste0("fewer than ", floor_n, " patients in this cell"))
  }
  close_relations(cells, cell_relations(cells, shell), floor_n)
}
