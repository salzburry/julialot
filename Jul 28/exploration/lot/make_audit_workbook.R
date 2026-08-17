#!/usr/bin/env Rscript
# Turn one or two lot_audit_counts.csv files into a workbook somebody can read
# without being told what any of it means.
#
#   # one run
#   Rscript exploration/lot/make_audit_workbook.R out/lot_audit_counts.csv
#
#   # two runs, old first
#   Rscript exploration/lot/make_audit_workbook.R out/before_fix.csv out/lot_audit_counts.csv
#
#   OUT_XLSX=/path/audit.xlsx   to choose where it lands
#
# No warehouse and no connection: this reads the CSVs the audit run already
# wrote and reshapes them.
#
# run_lot_audit_counts.R writes LONG - one row per cell, finding/row/metric/
# value - because the counts return different columns from each other and
# stacking them wide produced repeated headers in one file. Long is right for
# writing and unreadable for reading, so this pivots it back.
#
# Two things it does that a naive pivot does not, and they are the reason the
# hand-made version had blank cells and mismatched rows.
#
#  1. A metric is a MEASURE if its name starts with N_, PCT_, MEDIAN_, MEAN_,
#     MIN_, MAX_ or P75_. Everything else - LOT_NUM, SHAPE, CAUSE,
#     LOT_START_TYPE, LOT_BASE_END_REASON, REGIMEN, STRANDED_IN_LOT - is a KEY
#     describing which slice the row is. Keys are repeated on every row rather
#     than left blank under a merged-looking header, so the sheet can be
#     filtered and sorted without falling apart.
#
#  2. Old and new are joined on those KEYS, never on row position. The whole
#     point of the comparison is that a slice can appear in one run and not the
#     other - a shape that stopped happening is the fix working - and a
#     positional join silently pairs row 2 of one with row 2 of the other and
#     reports both as changed.

.script_dir <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                            fixed = TRUE))) else getwd()
})

ARGS <- commandArgs(trailingOnly = TRUE)
if (!length(ARGS))
  stop("Give one lot_audit_counts.csv, or two with the OLD run first.",
       call. = FALSE)
if (length(ARGS) > 2)
  stop("At most two files: the old run and the new one.", call. = FALSE)
for (f in ARGS) if (!file.exists(f)) stop("No such file: ", f, call. = FALSE)

MEASURE_PREFIX <- c("N_", "PCT_", "MEDIAN_", "MEAN_", "MIN_", "MAX_", "P75_")
is_measure <- function(x) any(startsWith(x, MEASURE_PREFIX))

# What each finding is, in one line, plus which way is good. Anything not named
# here still appears; it just carries no note, which is a prompt to add one
# rather than a reason to hide the row.
# What each check is, in plain words. Three parts: what the condition is, which
# way is good, and why it matters. A finding not named here still appears - it
# just carries no note, which is a prompt to write one rather than a reason to
# hide the row.
NOTES <- list(
  "regimen-agent-begins-after-line-end" = c(
    "The line lists a drug the patient never started while the line was running.",
    "DOWN. Zero is the goal.",
    "Drugs are picked up over the first 60 days of a line, but the end date is worked out later. So a line cut short by a transplant can list a drug the patient only began afterwards. That drug then feeds the run-out date and the next line too, so it is not just a label."),
  "transplant-belonging-to-no-line" = c(
    "A stem cell transplant that sits inside no line at all.",
    "Shapes a and b DOWN to zero. Shape c is a number to report, and can rise.",
    "Every other transplant check starts from a line, so a transplant with no line has no row to be wrong on - it simply disappears. This one starts from the transplants instead."),
  "tandem-pair-whose-first-transplant-is-out-of-window" = c(
    "Two transplants close together where the first came too late to belong to its line.",
    "Neither. It shows how many patients the fix could touch.",
    "Two transplants within 180 days are read as one planned pair, which stops the second starting a line. That only holds if a line was keeping the pair. If the first was already outside the line's window, nothing was - so the second ends up owned by nobody."),
  "runout-unconfirmed-by-a-tandem-no-line-held" = c(
    "A transplant after the line ran out that one rule called a pair and another did not.",
    "Can move either way - it counts a patient pattern, not a mistake.",
    "One rule decides whether the line really stopped; another decides whether that transplant starts the next line. When they disagree the line stays open and swallows the transplant."),
  "empty-regimen-transplant-line-durations" = c(
    "Transplant lines with no drugs listed, and how long they run.",
    "Neither. Background for a decision.",
    "An allogeneic line lasts a day and lists nothing. A CAR-T line with no follow-up drug is similar. How long such a line should run is unsettled, so it is reported rather than judged."),
  "outside-line-days-by-cause" = c(
    "Days of treatment no line covers, and why.",
    "After the last line DOWN. Past the cap rising is the price of creating more lines.",
    "This is real treatment the model does not describe. The cap number rises whenever more lines are created, because more patients reach the limit and everything past it is invisible."),
  "in-window-cart-not-in-final-table" = c(
    "Patients whose CAR-T came early in line 1, so it never appears as its own line.",
    "Neither - it is about what the output shows.",
    "A CAR-T in the first 60 days counts as part of line 1 on purpose. But it gets no row of its own, so anyone counting CAR-T from the line table alone misses these patients."),
  "line-length-by-start-type" = c(
    "How long lines last, by line number and by what started them.",
    "Neither.",
    "Big movements are normal whenever line boundaries move. This shows how big a change was, not whether it was right."),
  "post-end-regimen-by-line-and-end-reason" = c(
    "The first problem again, split by line and by what ended the line.",
    "DOWN.",
    "The split is the diagnosis. Expected on allogeneic lines at any point and on CAR-T lines from line 2. A row on an autologous line would mean something else."),
  "post-end-agent-also-starts-a-later-line" = c(
    "A wrongly listed drug that also appears in a later line - the same drug counted twice.",
    "DOWN.",
    "This is why the first problem matters. Count drugs across lines and these patients are counted twice."),
  "runout-extends-past-the-transplant-end" = c(
    "Lines a transplant ended while the patient still had drug supply left.",
    "Neither.",
    "Worked out from the fill records, because the line table stores no run-out date at all."))

read_long <- function(path) {
  d <- utils::read.csv(path, stringsAsFactors = FALSE, colClasses = "character")
  need <- c("finding", "row", "metric", "value")
  miss <- setdiff(need, names(d))
  if (length(miss))
    stop(path, " is not a lot_audit_counts.csv - it has no ",
         paste(miss, collapse = ", "), " column. This reads the LONG file the ",
         "audit run writes, not a sheet somebody has already pivoted.",
         call. = FALSE)
  d$row <- as.integer(d$row)
  d
}

# Long -> wide, one data frame per finding, columns in the order the query
# returned them rather than alphabetically.
widen <- function(long) {
  out <- list()
  for (f in unique(long$finding)) {
    d <- long[long$finding == f, , drop = FALSE]
    metrics <- unique(d$metric)
    w <- data.frame(row = sort(unique(d$row)))
    for (m in metrics) {
      s <- d[d$metric == m, c("row", "value")]
      w[[m]] <- s$value[match(w$row, s$row)]
    }
    w$row <- NULL
    out[[f]] <- w
  }
  out
}

key_cols <- function(df) names(df)[!vapply(names(df), is_measure, logical(1))]

# A key that survives a slice being present in one run only. Empty keys - a
# finding that returns a single unlabelled row - collapse to one bucket, which
# is correct: there is one row to compare.
key_of <- function(df) {
  k <- key_cols(df)
  if (!length(k)) return(rep("(whole finding)", nrow(df)))
  do.call(paste, c(lapply(k, function(c_i) df[[c_i]]), sep = " | "))
}

compare <- function(old_w, new_w) {
  rows <- list()
  for (f in union(names(old_w), names(new_w))) {
    o <- old_w[[f]]; n <- new_w[[f]]
    ref <- if (!is.null(n)) n else o
    keys <- key_cols(ref)
    meas <- setdiff(names(ref), keys)
    ok <- if (is.null(o)) character(0) else key_of(o)
    nk <- if (is.null(n)) character(0) else key_of(n)
    for (k in union(ok, nk)) {
      oi <- match(k, ok); ni <- match(k, nk)
      lab <- if (!is.na(ni)) n[ni, keys, drop = FALSE] else o[oi, keys, drop = FALSE]
      if (!length(keys)) lab <- data.frame(SLICE = k, stringsAsFactors = FALSE)
      r <- data.frame(FINDING = f, lab, stringsAsFactors = FALSE, check.names = FALSE)
      # A slice missing from a run is not a missing VALUE. These are all GROUP
      # BY counts, so a slice the query returned no row for matched nothing -
      # the count is genuinely zero, and writing 0 is what lets the sheet read
      # "9 -> 0" instead of making someone derive it from the STATUS column.
      #
      # Only for counts. The average of an empty set is not zero, it is
      # nothing, and a 0 in MEDIAN_LENGTH_DAYS would be read as a real median
      # of zero days. Those stay empty.
      absent <- function(m) if (startsWith(m, "N_")) "0" else ""
      for (m in meas) {
        r[[paste0("OLD_", m)]] <-
          if (is.na(oi) || is.null(o[[m]])) absent(m) else o[[m]][oi]
        r[[paste0("NEW_", m)]] <-
          if (is.na(ni) || is.null(n[[m]])) absent(m) else n[[m]][ni]
      }
      r$STATUS <- if (is.na(oi)) "NEW (new run only)"
                  else if (is.na(ni)) "GONE (old run only)"
                  else {
                    same <- vapply(meas, function(m)
                      identical(o[[m]][oi], n[[m]][ni]), logical(1))
                    if (all(same)) "SAME" else "CHANGED"
                  }
      nt <- NOTES[[f]]
      r$WHAT_IT_IS        <- if (is.null(nt)) "" else nt[1]
      r$WHICH_WAY_IS_GOOD <- if (is.null(nt)) "" else nt[2]
      r$WHY_IT_MATTERS    <- if (is.null(nt)) "" else nt[3]
      rows[[length(rows) + 1L]] <- r
    }
  }
  rows
}

# Sheets are per finding, because the findings do not share columns and one
# stacked sheet is what forces the blank cells this exists to remove.
bind_same <- function(rows) {
  out <- list()
  for (r in rows) {
    k <- paste(names(r), collapse = "")
    out[[k]] <- if (is.null(out[[k]])) r else rbind(out[[k]], r)
  }
  unname(out)
}

old_long <- read_long(ARGS[1])
new_long <- if (length(ARGS) == 2) read_long(ARGS[2]) else NULL
old_w <- widen(old_long)
new_w <- if (is.null(new_long)) NULL else widen(new_long)

cat("Findings in the ", if (is.null(new_w)) "run" else "old run", ": ",
    length(old_w), "\n", sep = "")
if (!is.null(new_w)) cat("Findings in the new run: ", length(new_w), "\n", sep = "")
for (f in names(if (is.null(new_w)) old_w else new_w)) {
  d <- (if (is.null(new_w)) old_w else new_w)[[f]]
  cat("  ", f, " - keys: ",
      if (length(key_cols(d))) paste(key_cols(d), collapse = ", ") else "(none)",
      "\n", sep = "")
}

sheets <- list()
readme <- data.frame(
  SECTION = c("What this is", rep("", 4)),
  DETAIL = c(
    if (is.null(new_w))
      "One LOT audit run, one sheet per finding, every key column filled on every row."
    else
      "Two LOT audit runs compared. One sheet per finding. Old and new are joined on the LABEL columns, never on row position, so a slice present in only one run is reported as such rather than silently paired with a different slice.",
    "STATUS: SAME, CHANGED, GONE (old run only), or NEW (new run only).",
    "Every row carries WHAT_IT_IS and WHICH_WAY_IS_GOOD, so no sheet has to be read against a separate key.",
    "A slice present in only one run shows 0 in the other for N_ counts - these are GROUP BY counts, so no row means nothing matched. Averages and medians are left empty instead, because the average of an empty set is not zero.",
    "The comparison spans everything that changed between the two builds, which may be more than one fix. Check CODE_MD5 and the run stamp in LOT_RUN_METADATA for each run before attributing a movement to a particular change."),
  stringsAsFactors = FALSE)
sheets[["Read me"]] <- readme
# The same notes as their own sheet. A reader who wants to know what a check
# asks should not have to scroll a wide results sheet to the last column.
sheets[["Definitions"]] <- data.frame(
  CHECK = names(NOTES),
  WHAT_IT_IS = vapply(NOTES, function(x) x[1], character(1)),
  WHICH_WAY_IS_GOOD = vapply(NOTES, function(x) x[2], character(1)),
  WHY_IT_MATTERS = vapply(NOTES, function(x) x[3], character(1)),
  row.names = NULL, stringsAsFactors = FALSE)

if (is.null(new_w)) {
  for (f in names(old_w)) {
    d <- old_w[[f]]
    nt <- NOTES[[f]]
    d$WHAT_IT_IS        <- if (is.null(nt)) "" else nt[1]
    d$WHICH_WAY_IS_GOOD <- if (is.null(nt)) "" else nt[2]
    d$WHY_IT_MATTERS    <- if (is.null(nt)) "" else nt[3]
    sheets[[substr(gsub("[^A-Za-z0-9]+", " ", f), 1, 31)]] <- d
  }
} else {
  for (blk in bind_same(compare(old_w, new_w))) {
    nm <- substr(gsub("[^A-Za-z0-9]+", " ", blk$FINDING[1]), 1, 31)
    sheets[[nm]] <- blk
  }
}

out <- Sys.getenv("OUT_XLSX", unset = file.path(dirname(ARGS[1]), "lot_audit_workbook.xlsx"))
# Braces, not a bare multi-line if/else. At top level R closes the expression
# at the newline and then meets a stray `else`, which is a parse error rather
# than a runtime one - the whole file fails to load.
writer <- {
  if (requireNamespace("openxlsx", quietly = TRUE)) "openxlsx"
  else if (requireNamespace("writexl", quietly = TRUE)) "writexl"
  else ""
}

if (identical(writer, "openxlsx")) {
  wb <- openxlsx::createWorkbook()
  hdr <- openxlsx::createStyle(textDecoration = "bold", fgFill = "#1F3864",
                               fontColour = "white", wrapText = TRUE)
  for (nm in names(sheets)) {
    openxlsx::addWorksheet(wb, nm)
    openxlsx::writeData(wb, nm, sheets[[nm]], headerStyle = hdr)
    openxlsx::freezePane(wb, nm, firstActiveRow = 2)
    openxlsx::setColWidths(wb, nm, seq_along(sheets[[nm]]), widths = "auto")
  }
  openxlsx::saveWorkbook(wb, out, overwrite = TRUE)
  cat("\nWrote ", out, " (", length(sheets), " sheets)\n", sep = "")
} else if (identical(writer, "writexl")) {
  writexl::write_xlsx(sheets, out)
  cat("\nWrote ", out, " (", length(sheets), " sheets, no formatting - ",
      "install openxlsx for widths and a frozen header)\n", sep = "")
} else {
  # Neither package. One CSV per sheet rather than nothing, and say so plainly:
  # a silent fallback would look like the workbook simply failed to appear.
  dir <- file.path(dirname(out), "audit_workbook_csv")
  dir.create(dir, showWarnings = FALSE, recursive = TRUE)
  for (nm in names(sheets))
    utils::write.csv(sheets[[nm]],
                     file.path(dir, paste0(gsub(" ", "_", nm), ".csv")),
                     row.names = FALSE)
  cat("\nNeither openxlsx nor writexl is installed, so there is no .xlsx.\n",
      "Wrote ", length(sheets), " CSVs to ", dir, " instead - same content, ",
      "one file per sheet.\ninstall.packages(\"openxlsx\") then re-run for a ",
      "single workbook.\n", sep = "")
}
