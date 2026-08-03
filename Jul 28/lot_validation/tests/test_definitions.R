#!/usr/bin/env Rscript
# Checks on the line-of-therapy definition comparison.
#
# Our column is checked against the code it cites. The source grid is checked
# for the one thing it exists to enforce: a cell that reads like a citation has
# to be one. An unsourced answer sitting beside a sourced one is the failure
# here - the table looks the same either way, and a concordance nobody can
# chase is worse than an empty cell.
#
#   Rscript "lot_validation/tests/test_definitions.R"

ROOT <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                                 fixed = TRUE))) else getwd()
  dirname(d)
})
JUL28 <- dirname(ROOT)

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

cat("\n-- and the files it cites are really there, saying what it says --\n")
missing <- character(0)
for (i in seq_len(nrow(ours))) {
  f <- sub("[: ].*$", "", ours$ours_at[i])
  if (!file.exists(file.path(JUL28, f))) missing <- c(missing, ours$dimension_id[i])
}
ok(!length(missing),
   if (length(missing)) paste0("cites a file that is not here: ",
                               paste(missing, collapse = ", "))
   else "every citation names a file that exists")
# The two answers most likely to be wrong if the build changed under us.
sct <- readLines(file.path(JUL28, "lot", "R", "steps", "05_sct.R"), warn = FALSE)
ok(any(grepl("Maintenance is a descriptive flag only", sct, fixed = TRUE)),
   "...and 'maintenance is never a line' is what the build actually says")
ok(any(grepl("Single AUTO allowed; tandem pair allowed; excess AUTO ends LOT1",
             sct, fixed = TRUE)),
   "...and so is the single-plus-tandem transplant rule")

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
# The specific failure this file exists to prevent, and the one that was
# actually available here: search works, fetching does not, and a search
# summary reads exactly like a source.
b <- base; b$answer <- "Counted as a separate line."; b$source_type <- "search_summary"
b$citation <- "a web search result"
stops(read_definition_sources(wr(b)),
      "...and a search summary is rejected by name, not merely discouraged")
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
ok(any(grepl("denied by this environment's", dn, fixed = TRUE)) ||
     any(grepl("denied by network policy", rd, fixed = TRUE)),
   "the network denial is stated, so empty reads as blocked rather than skipped")
ok(any(grepl("search summary", dn, fixed = TRUE)),
   "...and so is the reason a search result was not used instead")

cat("\n", strrep("-", 52), "\n", sep = "")
cat(sprintf("%d passed, %d failed\n", pass, fail))
if (fail > 0L) quit(status = 1L)
