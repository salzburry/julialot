#!/usr/bin/env Rscript
# Which treatments sit inside a line that does not name them.
#
#   Rscript lot/qc/extract_review.R [dir]
#
# Reads the CSVs lot/qc/extract_patients.R wrote (default out/extract). No
# connection, no python, no warehouse. Prints a short table and nothing else.
#
# Why this and not the whole extract. The question a returning drug raises is
# not what every episode did - it is which episodes fall inside a line whose
# regimen leaves them out. A drug carried over from the line before is one
# legitimate way that happens and is marked as such. What is left is the set
# worth arguing about, and it is small enough to read.
#
# For each of those it prints whether the drug was in the PREVIOUS line's
# regimen, which is what makes it a fold candidate at all, and whether a
# transplant opened a line between the drug's previous COURSE and this one.
#
# The course, not the episode. 4.8 measures dose to dose from PREV_COURSE_DT,
# and episodes closer together than map_discon_gap_days are one course - so
# anchoring on the previous episode can put a transplant inside the window that
# the rule reads as outside it, or the other way about. The gap is read off the
# run's own contract settings in run_pin.csv rather than assumed.
#
# It does NOT decide anything. It cannot: the fold turns on an advance count
# this file has no way to compute, and a drug carried over from the line before
# is not told apart from a return here. Two columns and a filter are not the
# rule. What it is for is finding the rows worth running the engine over.

args <- commandArgs(trailingOnly = TRUE)
dir  <- if (length(args) >= 1) args[1] else file.path("lot", "qc", "out", "extract")
if (!dir.exists(dir)) dir <- file.path("out", "extract")
if (!dir.exists(dir)) stop("No extract directory. Pass it as the first argument.",
                           call. = FALSE)

rd <- function(n) {
  f <- file.path(dir, paste0(n, ".csv"))
  if (!file.exists(f)) stop("Missing ", f, call. = FALSE)
  utils::read.csv(f, stringsAsFactors = FALSE, colClasses = "character")
}
lines <- rd("lot_long_final"); maps <- rd("map_stacked")
# map_discon_gap_days off the run's own settings, so the course grouping is the
# one the run used. Absent, this says so rather than assuming a number.
gap <- local({
  f <- file.path(dir, "run_pin.csv")
  v <- if (file.exists(f)) {
    p <- utils::read.csv(f, stringsAsFactors = FALSE, colClasses = "character")
    if ("CONTRACT_SETTINGS" %in% names(p))
      sub(".*map_discon_gap_days=([0-9]+).*", "\\1", p$CONTRACT_SETTINGS[1]) else ""
  } else ""
  n <- suppressWarnings(as.integer(v))
  if (is.na(n)) stop("No map_discon_gap_days in run_pin.csv, so the previous ",
                     "course cannot be found without guessing at the gap.",
                     call. = FALSE)
  n
})
auto  <- rd("tx_auto_dates");  allo <- rd("tx_allo_cart_dates")

d <- function(x) as.Date(x)
words <- function(s) { s <- trimws(as.character(s %||% "")); if (!nzchar(s)) character(0) else strsplit(s, " +")[[1]] }
`%||%` <- function(a, b) if (is.null(a)) b else a

lines$LOT_NUM <- as.integer(lines$LOT_NUM)
lines <- lines[order(lines$PATID, lines$LOT_NUM), ]
maps  <- maps[order(maps$PATID, d(maps$MAP_START_DT), maps$MAP_MED_TYPE), ]

# Every transplant date that IS a line start - the only ones 4.8's override
# reads. A transplant the line owns opens no line and never reaches the test.
tx_opened <- unique(rbind(
  data.frame(PATID = auto$PATID, DT = auto$TX_DT, KIND = "AUTO", stringsAsFactors = FALSE),
  if (nrow(allo)) data.frame(PATID = allo$PATID, DT = allo$TX_DT,
                             KIND = allo$SCT_TYPE, stringsAsFactors = FALSE)
  else data.frame(PATID = character(0), DT = character(0), KIND = character(0))))
starts <- paste(lines$PATID, lines$LOT_START_DT)
tx_opened <- tx_opened[paste(tx_opened$PATID, tx_opened$DT) %in% starts, , drop = FALSE]

out <- list()
for (p in unique(lines$PATID)) {
  lp <- lines[lines$PATID == p, , drop = FALSE]
  mp <- maps[maps$PATID == p, , drop = FALSE]
  for (i in seq_len(nrow(mp))) {
    med <- mp$MAP_MED_TYPE[i]; st <- d(mp$MAP_START_DT[i])
    j <- which(d(lp$LOT_START_DT) <= st & st <= d(lp$LOT_BASE_END_DT))
    if (!length(j)) { covered <- "NO LINE"; reg <- character(0); prev <- character(0); span <- "" }
    else {
      j <- j[1]
      reg <- words(lp$LOT_BASE_MEDS[j])
      prev <- if (j > 1) words(lp$LOT_BASE_MEDS[j - 1]) else character(0)
      covered <- paste0("L", lp$LOT_NUM[j])
      span <- paste(lp$LOT_START_DT[j], "->", lp$LOT_BASE_END_DT[j])
    }
    if (med %in% reg) next                      # the line names it: nothing to ask
    # The previous COURSE of this drug, which is what 4.8 measures from: walk
    # back through the drug's earlier episodes while each sits within the gap
    # of the one after it, and take where that run began.
    earlier <- mp[mp$MAP_MED_TYPE == med & d(mp$MAP_START_DT) < st, , drop = FALSE]
    prev_ep <- NA_character_
    if (nrow(earlier)) {
      k <- nrow(earlier)
      prev_ep <- earlier$MAP_START_DT[k]
      while (k > 1 &&
             as.numeric(d(earlier$MAP_START_DT[k]) - d(earlier$MAP_END_DT[k - 1])) < gap) {
        k <- k - 1; prev_ep <- earlier$MAP_START_DT[k]
      }
    }
    tx <- tx_opened[tx_opened$PATID == p, , drop = FALSE]
    between <- if (is.na(prev_ep)) character(0)
               else tx$DT[d(tx$DT) > d(prev_ep) & d(tx$DT) < st]
    out[[length(out) + 1]] <- data.frame(
      PATID = p, DRUG = med,
      EPISODE = paste(mp$MAP_START_DT[i], "->", mp$MAP_END_DT[i]),
      IN = covered, LINE_SPAN = span,
      LINE_NAMES = paste(reg, collapse = " "),
      PREV_LINE = paste(prev, collapse = " "),
      IN_PREV = if (med %in% prev) "yes" else "no",
      PREV_COURSE = prev_ep %||% NA_character_,
      TX_OPENED_BETWEEN = if (length(between)) paste(between, collapse = ",") else "-",
      stringsAsFactors = FALSE)
  }
}
if (!length(out)) { cat("\nEvery episode is named by the line it falls in.\n"); quit(status = 0L) }
r <- do.call(rbind, out)

cat("\nTreatments inside a line whose regimen does not name them\n")
cat(strrep("-", 118), "\n", sep = "")
cat(sprintf("%-11s %-5s %-26s %-4s %-26s %-20s\n",
            "PATID", "DRUG", "EPISODE", "IN", "LINE SPAN", "THAT LINE NAMES"))
for (i in seq_len(nrow(r)))
  cat(sprintf("%-11s %-5s %-26s %-4s %-26s %-20s\n",
              r$PATID[i], r$DRUG[i], r$EPISODE[i], r$IN[i], r$LINE_SPAN[i], r$LINE_NAMES[i]))
cat("\nand what 4.8 reads for each\n")
cat(strrep("-", 118), "\n", sep = "")
cat(sprintf("%-11s %-5s %-12s %-8s %-22s %-24s\n",
            "PATID", "DRUG", "PREV COURSE", "IN PREV", "TX OPENED A LINE BETWEEN", "PREVIOUS LINE NAMES"))
for (i in seq_len(nrow(r)))
  cat(sprintf("%-11s %-5s %-12s %-8s %-22s %-24s\n",
              r$PATID[i], r$DRUG[i], r$PREV_COURSE[i] %||% "-", r$IN_PREV[i],
              r$TX_OPENED_BETWEEN[i], r$PREV_LINE[i]))
cat("\n", nrow(r), " episode(s) over ", length(unique(r$PATID)), " patient(s).\n", sep = "")
