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
#   * where exactly one cell in a group is withheld, a second goes with it,
#     because the group's total less the published rest is the withheld cell;
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

# Which cells pair up for the complementary rule.
#
# The group is the one a reader can subtract within: the levels of a variable,
# in one column of one table. The levels sit under a section heading in the
# shell and the column is the population, so those two name it. Only the counts
# take part - a median and a rate do not sum to a published total, so hiding a
# second one of them protects nothing and loses a number.
TFLS_GROUPED_STATS <- c("n_pct", "n")

# The statistics whose own N is a count of patients, and so is a population the
# floor is about. For the rest the floor is on the denominator alone, which is
# what the package applies to a rate: N_AT_RISK decides, and the events inside
# it are published with it or withheld with it.
TFLS_COUNT_FLOOR_STATS <- c("n_pct", "n", "mean_sd", "median_iqr", "min_max")

cell_group_key <- function(cells)
  paste(cells$TABLE_ID, cells$COLUMN_ID, cells$SECTION_LABEL, sep = "\r")

# The floor, then the complementary rule, over a frame of cells.
#
# A section heading has no number, and a row nothing could fill has none
# either; neither is a cell the rule is about, and neither is counted as a
# published cell when the group is weighed up.
suppress_cells <- function(cells, floor_n) {
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
  # Complementary suppression. Publishing every level but one, beside the
  # total, gives the withheld level away as the difference, so the smallest of
  # the published levels goes with it. With only two levels that withholds the
  # variable entirely, which is the right answer.
  key <- cell_group_key(cells)
  grouped <- live & cells$STAT %in% TFLS_GROUPED_STATS
  for (g in unique(key[grouped])) {
    w <- which(grouped & key == g)
    if (length(w) < 2L) next
    supp <- w[cells$SUPPRESSED[w] == 1L]
    if (length(supp) != 1L) next
    open <- w[cells$SUPPRESSED[w] == 0L]
    if (!length(open)) next
    n <- cells$N[open]
    n[is.na(n)] <- Inf
    cells <- withhold_cell(cells, open[which.min(n)], floor_n,
      "withheld with the one other cell of its group, which the group total would otherwise give away")
  }
  cells
}
