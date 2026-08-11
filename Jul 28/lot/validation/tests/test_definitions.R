#!/usr/bin/env Rscript
# Checks on the line-of-therapy definition comparison.
#
# Our column is checked against the code it cites. The source grid is checked
# for the one thing it exists to enforce: a cell that reads like a citation has
# to be one. An unsourced answer sitting beside a sourced one is the failure
# here - the table looks the same either way, and a concordance nobody can
# chase is worse than an empty cell.
#
#   Rscript "lot/validation/tests/test_definitions.R"

ROOT <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                                 fixed = TRUE))) else getwd()
  dirname(d)
})
# The LOT group this package sits in, and the study folder above it. Both are
# resolved from this file rather than named, so either can be renamed. The
# catalogue cites source locations from the study root - one frame that reaches
# the engine and the cohort builds alike - so a citation resolves against STUDY,
# while this package's own reads of the engine go through PARENT.
PARENT <- dirname(ROOT)
STUDY  <- dirname(PARENT)

pass <- 0L; fail <- 0L
ok <- function(cond, what) {
  if (isTRUE(cond)) { pass <<- pass + 1L; cat("  ok     ", what, "\n") }
  else              { fail <<- fail + 1L; cat("  FAIL   ", what, "\n") }
}
runs  <- function(expr, what) ok(is.null(tryCatch({ expr; NULL },
                                 error = conditionMessage)), what)
stops <- function(expr, what) ok(!is.null(tryCatch({ expr; NULL },
                                 error = conditionMessage)), what)

source(file.path(ROOT, "R", "definitions.R"))
SRC <- file.path(ROOT, "definitions_sources.csv")

cat("\n-- our side is complete, and every claim names where to check it --\n")
ours <- render_definitions()
ok(nrow(ours) >= 10, paste0("every dimension is answered (", nrow(ours), ")"))
ok(all(nzchar(ours$ours)) && all(nzchar(ours$ours_at)),
   "...each with an answer and a place in the code to check it")
ok(all(nzchar(ours$ask_the_protocol)),
   "...and the question to put to a protocol, so filling a cell is reading not interpreting")
# The three the ask named by name.
for (want in c("sct_auto_is_a_line", "maintenance_is_a_line", "gap_ends_a_line"))
  ok(want %in% ours$dimension_id,
     paste0("...including '", want, "', which the ask named"))

cat("\n-- and the citations are file AND line, to a line the file has --\n")
# A citation naming only a file sends the reader to eight hundred lines of SQL
# to find out whether one sentence is true, and a claim that expensive to check
# does not get checked. The README says "file and line", so this holds it to it.
#
# Format: `path:line`, comma-separated, a bare `:line` continuing the path.
cite_parts <- function(s) {
  path <- NA_character_; out <- list()
  for (b in trimws(strsplit(s, ",")[[1]])) {
    if (grepl("^:[0-9]+$", b)) {
      if (is.na(path)) return(NULL)
      out[[length(out) + 1L]] <- list(file = path, line = as.integer(sub("^:", "", b)))
    } else if (grepl("^[^ :]+:[0-9]+$", b)) {
      path <- sub(":[0-9]+$", "", b)
      out[[length(out) + 1L]] <- list(file = path, line = as.integer(sub("^.*:", "", b)))
    } else return(NULL)
  }
  out
}
unlined <- character(0); missing <- character(0); past_end <- character(0)
blank   <- character(0)
for (i in seq_len(nrow(ours))) {
  p <- cite_parts(ours$ours_at[i])
  if (is.null(p) || !length(p)) { unlined <- c(unlined, ours$dimension_id[i]); next }
  for (c_i in p) {
    f <- file.path(STUDY, c_i$file)
    if (!file.exists(f)) { missing <- c(missing, ours$dimension_id[i]); next }
    txt <- readLines(f, warn = FALSE)
    if (c_i$line > length(txt)) past_end <- c(past_end, ours$dimension_id[i])
    else if (!nzchar(trimws(txt[c_i$line]))) blank <- c(blank, ours$dimension_id[i])
  }
}
ok(!length(unlined),
   if (length(unlined)) paste0("cites a file with no line: ",
                               paste(unique(unlined), collapse = ", "))
   else "every citation is file:line, so a reader can check one claim in one look")
ok(!length(missing),
   if (length(missing)) paste0("cites a file that is not here: ",
                               paste(unique(missing), collapse = ", "))
   else "...naming a file that exists")
ok(!length(past_end) && !length(blank),
   if (length(past_end) || length(blank))
     paste0("cites a line the file does not have, or a blank one: ",
            paste(unique(c(past_end, blank)), collapse = ", "))
   else "...and a line that file actually has")
# The two answers most likely to be wrong if the build changed under us.
#
# On the code, not the header comment. 05_sct.R's "# SCT detection rules:"
# block names both rules and implements neither: the transplant rule is
# ENDING_AUTO_DT in 05b_lot1_sct.R. A comment is what a build says about
# itself, and these answers are about what it does.
code_of <- function(f) {
  l <- readLines(file.path(PARENT, "engine", "R", "steps", f), warn = FALSE)
  paste(l[!grepl("^\\s*(#|--)", l)], collapse = "\n")
}
sct1 <- code_of("05b_lot1_sct.R")
# Maintenance is never a line: no view or table is built for a maintenance
# period anywhere in the steps, and contains_mtx_reg is carried as a flag.
mviews <- unlist(lapply(list.files(file.path(PARENT, "engine", "R", "steps"), "\\.R$"),
  function(f) grep("(VIEW|TABLE)\\s+\\S*maint", code_of(f), value = TRUE, ignore.case = TRUE)))
ok(!length(mviews),
   if (length(mviews)) paste0("a maintenance period is built after all: ", mviews[1])
   else "...and 'maintenance is never a line' is what the build actually does")
# Single allowed, tandem allowed, excess ends it: the tandem arm yields the
# third transplant and the fallback the second. Either one collapsing to NULL
# is the rule gone.
ok(grepl("THEN ap.AUTO_DT_3", sct1, fixed = TRUE) &&
     grepl("THEN ap.AUTO_DT_2", sct1, fixed = TRUE) &&
     grepl("END AS ENDING_AUTO_DT", sct1, fixed = TRUE),
   "...and so is the single-plus-tandem transplant rule, in ENDING_AUTO_DT")
ok(grepl("n_allo_between", sct1, fixed = TRUE) &&
     grepl("sct_tandem_days", sct1, fixed = TRUE),
   "...with both of its disqualifiers - the 180 days and an ALLO between")

cat("\n-- the transplant answer covers later lines, not LOT1 alone --\n")
# 05_sct.R is the LOT1 rule and reads like the whole answer. It is not: at LOT2
# and later SCT_AUTO is a START type, so a transplant beyond what the previous
# line allowed becomes a line of its own - with no drug beside it. An answer
# stopping at LOT1 says "never a separate line", which is the opposite of what
# a protocol comparison would conclude.
l25 <- readLines(file.path(PARENT, "engine", "R", "steps", "10_lot2_5_base.R"), warn = FALSE)
ok(any(grepl("THEN 'SCT_AUTO'", l25, fixed = TRUE)),
   "SCT_AUTO really is one of the start types a later line takes")
auto <- ours[ours$dimension_id == "sct_auto_is_a_line", , drop = FALSE]
ok(grepl("start type", auto$ours, fixed = TRUE) &&
     grepl("line of its own", auto$ours, fixed = TRUE),
   "...and our answer says so, instead of stopping at the LOT1 rule")
cited <- cite_parts(auto$ours_at)
ok(any(vapply(cited, function(c_i)
       grepl("10_lot2_5_base", c_i$file, fixed = TRUE) &&
         grepl("SCT_AUTO|d_AUTO", l25[c_i$line]), logical(1))),
   "...citing the later-line code that decides it, not only the LOT1 comment")

cat("\n-- the grid ships empty, and empty does not read as agreement --\n")
runs(read_definition_sources(SRC), "the source grid loads")
src <- read_definition_sources(SRC)
ok(all(is.na(src$answer)), "no answer is filled in - none was invented")
ok(nrow(src) == nrow(ours) * length(unique(src$source_id)),
   "...with a cell for every dimension against every source slot")
ok(sum(unique(src$source_id) != "IMWG_consensus") >= 5,
   "...and room for the five pivotal trials the ask asked for, beside IMWG")
cmp <- compare_definitions(src)
ok(all(cmp$concordance == "not yet sourced"),
   "an unfilled dimension is 'not yet sourced'")
# The default has to fall this way. An empty comparison reading as agreement
# retires the question instead of answering it.
ok(!any(cmp$concordance == "agrees"),
   "...never 'agrees', which would retire the question rather than answer it")

cat("\n-- a cell that reads like a citation has to be one --\n")
tmp <- file.path(tempdir(), "defsrc.csv")
wr <- function(d) { write.csv(d, tmp, row.names = FALSE, na = ""); tmp }
base <- src[1, , drop = FALSE]
b <- base; b$answer <- "Counted as a separate line."
stops(read_definition_sources(wr(b)),
      "an answer with no citation is refused")
# The specific failure this file exists to prevent: a summary of a document
# reads exactly like the document, and is far easier to come by.
b <- base; b$answer <- "Counted as a separate line."; b$source_type <- "search_summary"
b$citation <- "a summary somebody pasted"
stops(read_definition_sources(wr(b)),
      "...and a summary of a document is rejected by name, not merely discouraged")
b <- base; b$answer <- "x"; b$source_type <- "recollection"; b$citation <- "I remember"
stops(read_definition_sources(wr(b)), "...as is something written from memory")
b <- base; b$answer <- "x"; b$source_type <- "hearsay"; b$citation <- "someone said"
stops(read_definition_sources(wr(b)), "...and a source type that is not on the list")
# Registry records and papers change; a citation without a date cannot be
# checked against what was read.
b <- base; b$answer <- "x"; b$source_type <- "registry"; b$citation <- "NCT01234567"
stops(read_definition_sources(wr(b)),
      "a registry citation with no retrieved date is refused, because records change")
b <- base; b$answer <- "x"; b$source_type <- "protocol"
b$citation <- "Protocol v3.0 section 5.2"
runs(read_definition_sources(wr(b)), "a protocol citation with a section loads")
b <- base; b$answer <- "x"; b$source_type <- "registry"; b$citation <- "NCT01234567 eligibility"
b$retrieved <- "2026-08-03"
runs(read_definition_sources(wr(b)), "...and a dated registry citation loads")
b <- base; b$dimension_id <- "no_such_dimension"
stops(read_definition_sources(wr(b)), "a dimension that does not exist is refused")
b <- base; b$answer <- "x"; b$source_type <- "protocol"; b$citation <- "s5"
b$concordance <- "sort of"
stops(read_definition_sources(wr(b)), "...and a concordance that is not agrees/differs/unclear")

cat("\n-- and a sourced cell is compared, once it is one --\n")
b <- src
i <- which(b$dimension_id == "maintenance_is_a_line" & b$source_id == "IMWG_consensus")[1]
b$answer[i] <- "Induction, ASCT and maintenance are one line."
b$source_type[i] <- "publication"; b$citation[i] <- "Author 2015, section 2"
b$retrieved[i] <- "2026-08-03"; b$concordance[i] <- "differs"
c2 <- compare_definitions(read_definition_sources(wr(b)))
row <- c2[c2$dimension_id == "maintenance_is_a_line", , drop = FALSE]
ok(nrow(row) == 1 && identical(row$concordance, "differs"),
   "a filled cell is compared and keeps the judgement recorded with it")
ok(all(c2$concordance[c2$dimension_id != "maintenance_is_a_line"] == "not yet sourced"),
   "...and one sourced dimension does not make the others look answered")
b$concordance[i] <- ""
c3 <- compare_definitions(read_definition_sources(wr(b)))
ok(identical(c3$concordance[c3$dimension_id == "maintenance_is_a_line"], "unclear"),
   "a sourced answer with no judgement is 'unclear', not agreement")

cat("\n-- why the columns are empty is recorded, not left to be guessed --\n")
dn <- readLines(file.path(ROOT, "R", "definitions.R"), warn = FALSE)
rd <- readLines(file.path(ROOT, "run_definitions.R"), warn = FALSE)
ok(any(grepl("are not in this folder", dn, fixed = TRUE)) &&
     any(grepl("are not in this folder", rd, fixed = TRUE)),
   "the reason is stated, so empty reads as unsourced rather than skipped")
ok(any(grepl("summary of a document", dn, fixed = TRUE)),
   "...and so is why a summary of one was not used instead")

cat("\n-- the grid is one row per (dimension, source), and says so --\n")
# Nothing checked the source side of the key, so a typo was a new source, a
# second row was an addition rather than a correction, and one slot could hold
# a different trial on every row - twelve trials rendered as one column.
dtmp <- file.path(tempdir(), "defsrc.csv")
dwr <- function(rows) { write.csv(rows, dtmp, row.names = FALSE, na = ""); dtmp }
g <- read.csv(file.path(ROOT, "definitions_sources.csv"), stringsAsFactors = FALSE,
              colClasses = "character")
answered <- function(x, n = 1L) {
  x$source_type[n] <- "registry"; x$citation[n] <- "NCT04000000 eligibility"
  x$retrieved[n] <- "2026-08-11"; x$answer[n] <- "transplant is not a line"
  x$concordance[n] <- "differs"; x
}
runs(read_definition_sources(dwr(answered(g))), "a governed answered row loads")
b <- g; b$source_id[1] <- "trail_1"
stops(read_definition_sources(dwr(b)), "a mistyped source_id is not a new source")
b <- answered(g); b <- rbind(b, b[1, ])
stops(read_definition_sources(dwr(b)),
      "two rows for one (dimension, source) - a correction replaces, it does not add")
b <- answered(answered(g, 1L), 2L)
b$source_id[2] <- b$source_id[1]
b$citation[2] <- "NCT09999999 eligibility"
stops(read_definition_sources(dwr(b)),
      "one slot citing two NCT ids - that is two trials in one column")

cat("\n", strrep("-", 52), "\n", sep = "")
cat(sprintf("%d passed, %d failed\n", pass, fail))
if (fail > 0L) quit(status = 1L)
