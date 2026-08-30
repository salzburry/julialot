#!/usr/bin/env Rscript
# Checks on the line-of-therapy definition comparison.
#
# Our column is checked against the code it cites. The source grid is checked
# for the one thing it exists to enforce: a cell that reads like a citation has
# to be one. An unsourced answer sitting beside a sourced one is the failure
# here - the table looks the same either way, and a concordance nobody can
# chase is worse than an empty cell.
#
#   Rscript "exploration/lot/tests/test_definitions.R"

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
# This package sits in its own area beside lot/, so reads of the engine go
# through the study folder.
LOT    <- file.path(dirname(PARENT), "lot", "engine")
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
# does not get checked. lot/FILES.md says "file and line", so this holds it to it.
#
# Format: `path:line`, comma-separated, a bare `:line` continuing the path.
# A citation is "path | anchor", several separated by " ;; ". The anchor is a
# literal that has to appear in that file, and this resolves it to the line it
# is on - so every check below still works on a (file, line) pair and none of
# them had to change.
#
# It was "path:line". Line numbers do not survive editing: four separate edits
# in one week moved code above a citation and left it pointing at whatever had
# drifted into its slot. The suite caught each one, which is why they were
# never wrong for long - but re-pointing by hand is work the anchor form does
# not need. An anchor moves with the code it names, and a citation whose code
# is GONE fails, which is the case worth failing on.
#
# The FIRST match wins, and a repeated anchor is fine. Several of these rules
# are written identically in five places - the tandem window, the steroid
# exclusion - and any occurrence serves a reader who greps for it equally well.
# What must fail is an anchor that is not there AT ALL, which is the case that
# means the code it quotes has gone.
cite_parts <- function(s) {
  out <- list()
  for (b in trimws(strsplit(s, ";;", fixed = TRUE)[[1]])) {
    if (!nzchar(b)) next
    halves <- trimws(strsplit(b, "|", fixed = TRUE)[[1]])
    if (length(halves) != 2L || !all(nzchar(halves))) return(NULL)
    f <- file.path(STUDY, halves[1])
    if (!file.exists(f)) {
      out[[length(out) + 1L]] <- list(file = halves[1], line = NA_integer_,
                                      anchor = halves[2])
      next
    }
    hit <- which(grepl(halves[2], readLines(f, warn = FALSE), fixed = TRUE))
    out[[length(out) + 1L]] <- list(
      file = halves[1], anchor = halves[2],
      line = if (length(hit)) hit[1] else NA_integer_, absent = !length(hit))
  }
  out
}
unlined <- character(0); missing <- character(0); gone <- character(0)
for (i in seq_len(nrow(ours))) {
  p <- cite_parts(ours$ours_at[i])
  if (is.null(p) || !length(p)) { unlined <- c(unlined, ours$dimension_id[i]); next }
  for (c_i in p) {
    if (!file.exists(file.path(STUDY, c_i$file))) {
      missing <- c(missing, paste0(ours$dimension_id[i], " -> ", c_i$file)); next
    }
    if (isTRUE(c_i$absent))
      gone <- c(gone, paste0(ours$dimension_id[i], " -> '", c_i$anchor,
                             "' is not in ", basename(c_i$file)))
  }
}
ok(!length(unlined),
   if (length(unlined)) paste0("cites something that is not 'path | anchor': ",
                               paste(unique(unlined), collapse = ", "))
   else "every citation is 'path | anchor', so a reader can grep one claim")
ok(!length(missing),
   if (length(missing)) paste0("cites a file that is not here: ",
                               paste(unique(missing), collapse = ", "))
   else "...naming a file that exists")
ok(!length(gone),
   if (length(gone)) paste0("the code it quotes is gone: ",
                            paste(unique(gone), collapse = "; "))
   else "...and the line each one quotes is still in that file")
# And a line of CODE, not a comment. A comment is what the build says about
# itself; the point of a citation here is to show what it DOES. A comment can be
# accurate, out of date, or aspirational and reads the same in all three states,
# so a citation landing on one rests a protocol comparison on prose.
commented <- character(0)
for (i in seq_len(nrow(ours))) {
  p <- cite_parts(ours$ours_at[i]); if (is.null(p)) next
  for (c_i in p) {
    f <- file.path(STUDY, c_i$file); if (!file.exists(f)) next
    txt <- readLines(f, warn = FALSE)
    if (c_i$line <= length(txt) && grepl("^\\s*(#|--)", txt[c_i$line]))
      commented <- c(commented, paste0(ours$dimension_id[i], " -> ",
                                       basename(c_i$file), ":", c_i$line))
  }
}
ok(!length(commented),
   if (length(commented)) paste0("cites a comment rather than code: ",
                                 paste(unique(commented), collapse = ", "))
   else "...and a line of code rather than a comment about it")
# And a line of code that carries the claim. "Not a comment" is weaker than it
# reads: a function declaration is code, and so is the line that creates a view
# rather than the exclusion built on it. Neither proves the sentence beside it.
#
# So each dimension names the tokens its answer turns on and the cited lines
# have to carry them between them. Nothing mechanical can certify that a
# citation supports a claim, but this catches a citation narrowing to one
# clause of a multi-part answer.
unproven <- character(0)
for (i in seq_len(nrow(ours))) {
  want <- LOT_DIMENSIONS[[i]]$proves
  if (is.null(want)) { unproven <- c(unproven, paste0(ours$dimension_id[i],
                                                      " (names no tokens)")); next }
  p <- cite_parts(ours$ours_at[i]); if (is.null(p)) next
  txt <- paste(vapply(p, function(c_i) {
    f <- file.path(STUDY, c_i$file)
    if (!file.exists(f)) return("")
    l <- readLines(f, warn = FALSE)
    if (c_i$line > length(l)) "" else l[c_i$line]
  }, character(1)), collapse = "\n")
  miss <- want[!vapply(want, function(w) grepl(w, txt, fixed = TRUE), logical(1))]
  if (length(miss))
    unproven <- c(unproven, paste0(ours$dimension_id[i], " (",
                                   paste(miss, collapse = ", "), ")"))
}
ok(!length(unproven),
   if (length(unproven))
     paste0("cited lines do not carry what the answer turns on: ",
            paste(unproven, collapse = "; "))
   else "...and between them the cited lines carry every term the answer turns on")

# Between them is not each of them. The check above concatenates the cited
# lines, so a citation carrying nothing is invisible while its siblings cover
# the tokens - which is how a citation drifts off its target unnoticed when
# lines are added or removed above it.
#
# So every citation has to land near something its dimension turns on. A window
# rather than the line itself: a statement spans lines, and permissible_subs on
# the JOIN proves the SELECT two lines above it.
CITE_WINDOW <- 3L
adrift <- character(0)
for (i in seq_len(nrow(ours))) {
  want <- LOT_DIMENSIONS[[i]]$proves
  if (is.null(want)) next
  p <- cite_parts(ours$ours_at[i]); if (is.null(p)) next
  for (c_i in p) {
    f <- file.path(STUDY, c_i$file)
    if (!file.exists(f)) next
    l <- readLines(f, warn = FALSE)
    near <- paste(l[max(1L, c_i$line - CITE_WINDOW):min(length(l), c_i$line + CITE_WINDOW)],
                  collapse = "\n")
    if (!any(vapply(want, function(w) grepl(w, near, fixed = TRUE), logical(1))))
      adrift <- c(adrift, paste0(ours$dimension_id[i], " -> ", basename(c_i$file),
                                 ":", c_i$line))
  }
}
ok(!length(adrift),
   if (length(adrift))
     paste0("citation lands nowhere near what its dimension turns on: ",
            paste(adrift, collapse = "; "))
   else "...and each citation on its own lands within 3 lines of one of them")
# The two answers most likely to be wrong if the build changed under us.
#
# On the code, not the header comment. 05_sct.R's "# SCT detection rules:"
# block names both rules and implements neither: the transplant rule is
# ENDING_AUTO_DT in 05b_lot1_sct.R. A comment is what a build says about
# itself, and these answers are about what it does.
code_of <- function(f) {
  l <- readLines(file.path(LOT, "R", "steps", f), warn = FALSE)
  paste(l[!grepl("^\\s*(#|--)", l)], collapse = "\n")
}
sct1 <- code_of("05b_lot1_sct.R")
# Maintenance is never a line: no view or table is built for a maintenance
# period anywhere in the steps, and contains_mtx_reg is carried as a flag.
mviews <- unlist(lapply(list.files(file.path(LOT, "R", "steps"), "\\.R$"),
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
l25 <- readLines(file.path(LOT, "R", "steps", "10_lot2_5_base.R"), warn = FALSE)
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

cat("\n-- an unsourced cell does not read as agreement --\n")
# What is asserted is that nothing was invented, NOT that the grid is empty.
# The two coincide while it ships blank, and asserting the second would turn
# the suite red on the first honestly sourced answer. Every assertion below
# holds at zero filled cells and at all of them.
runs(read_definition_sources(SRC), "the source grid loads")
src <- read_definition_sources(SRC)
ok(nrow(src) == nrow(ours) * length(unique(src$source_id)),
   "a cell for every dimension against every source slot")
ok(sum(unique(src$source_id) != "IMWG_consensus") >= 5,
   "...and room for the five pivotal trials the ask asked for, beside IMWG")
answered <- !is.na(src$answer) & nzchar(trimws(src$answer))
cat("      (", sum(answered), " of ", nrow(src), " cells are sourced)\n", sep = "")
ok(all(!is.na(src$citation[answered]) & nzchar(trimws(src$citation[answered]))),
   "every answer that is filled in cites where it came from")
ok(all(src$source_type[answered] %in% names(DEF_SOURCE_TYPES)),
   "...from a source type this grid accepts")
cmp <- compare_definitions(src)
unsourced <- cmp$dimension_id[!cmp$dimension_id %in%
                                src$dimension_id[answered]]
ok(all(cmp$concordance[cmp$dimension_id %in% unsourced] == "not yet sourced"),
   "a dimension nobody sourced is 'not yet sourced'")
# The default has to fall this way. An empty comparison reading as agreement
# retires the question instead of answering it.
ok(!any(cmp$concordance[cmp$dimension_id %in% unsourced] == "agrees"),
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
b$notes[i] <- "the paper folds maintenance into the induction line"
c2 <- compare_definitions(read_definition_sources(wr(b)))
row <- c2[c2$dimension_id == "maintenance_is_a_line", , drop = FALSE]
ok(nrow(row) == 1 && identical(row$concordance, "differs"),
   "a filled cell is compared and keeps the judgement recorded with it")
ok(all(c2$concordance[c2$dimension_id != "maintenance_is_a_line"] == "not yet sourced"),
   "...and one sourced dimension does not make the others look answered")
b$concordance[i] <- ""
c3 <- compare_definitions(read_definition_sources(wr(b)))
# Three states, not two. "unclear" is a judgement somebody made - they read the
# source and could not tell - and a blank cell is nobody having looked.
# Rendering the second as the first retired the question by describing it as
# answered ambiguously, which is "agrees" one step quieter.
ok(identical(c3$concordance[c3$dimension_id == "maintenance_is_a_line"],
             "sourced, not judged"),
   "a sourced answer with no judgement says so, rather than borrowing 'unclear'")
ok(!any(c3$concordance == "agrees"), "...and it is still never agreement")

cat("\n-- a properly filled grid passes, end to end --\n")
# What the suite above cannot say on its own. Both grids are filled the
# way the skill is meant to fill them, and the command that checks them - the
# one a contributor runs before handing work back, and the one the reader
# behind it is shared with - is run in a real process against the result. If
# filling these files correctly cannot produce an exit 0, the whole evidence
# workflow is a scaffold that can only stay empty.
VD <- file.path(tempdir(), "vfilled")
dir.create(file.path(VD, "R"), recursive = TRUE, showWarnings = FALSE)
invisible(file.copy(list.files(file.path(ROOT, "R"), full.names = TRUE),
                    file.path(VD, "R"), overwrite = TRUE))
full <- src
# One NCT id per trial slot, and none on IMWG, which is not a trial. That is
# what a properly filled grid looks like, so the fixture has to look like it -
# a fixture that fills every cell identically would be exercising a file the
# reader is right to refuse.
nct <- c(trial_1 = "NCT01001001", trial_2 = "NCT01001002", trial_3 = "NCT01001003",
         trial_4 = "NCT01001004", trial_5 = "NCT01001005")
for (k in seq_len(nrow(full))) {
  s <- full$source_id[k]
  full$answer[k]      <- "The trial counts this as a separate line."
  full$source_type[k] <- if (s %in% names(nct)) "registry" else "guideline"
  full$citation[k]    <- if (s %in% names(nct))
    paste(nct[[s]], "eligibility") else "IMWG 2016 consensus, section 3"
  full$retrieved[k]   <- "2026-08-03"
  full$concordance[k] <- c("agrees", "differs", "unclear")[1 + (k %% 3)]
  full$notes[k]       <- "explained: the trial's wording differs on maintenance"
}
write.csv(full, file.path(VD, "definitions_sources.csv"), row.names = FALSE, na = "")
invisible(file.copy(file.path(ROOT, "benchmarks.csv"), VD, overwrite = TRUE))
runs(read_definition_sources(file.path(VD, "definitions_sources.csv")),
     "a grid with every one of its cells sourced loads")
cf <- compare_definitions(read_definition_sources(file.path(VD, "definitions_sources.csv")))
ok(!any(cf$concordance == "not yet sourced"),
   "...and no dimension is still reported as unsourced")
ok(all(cf$concordance %in% c("agrees", "differs", "unclear")),
   "...every one carries a judgement instead")
# Both readers over the filled copy, in a fresh process, so a grid somebody
# fills correctly is provably loadable rather than only loadable here.
rc <- suppressWarnings(system2(file.path(R.home("bin"), "Rscript"),
  c("-e", shQuote(paste0(
      "source('", file.path(VD, "R", "definitions.R"), "');",
      "source('", file.path(VD, "R", "benchmarks.R"), "');",
      "invisible(read_definition_sources('", file.path(VD, "definitions_sources.csv"), "'));",
      "invisible(read_benchmarks('", file.path(VD, "benchmarks.csv"), "'))"))),
  stdout = NULL, stderr = NULL))
ok(identical(rc, 0L),
   paste0("a filled grid loads through both readers in a clean session (", rc, ")"))

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
  # 'differs' carries how. It is the finding this grid exists to produce and
  # the one verdict that means nothing on its own.
  x$concordance[n] <- "differs"
  x$notes[n] <- "the trial counts the transplant within the induction line"
  x
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
# ...and the way round that check: cite no NCT at all and it never bites, so a
# trial slot could be a different protocol on every row while passing the check
# written to stop exactly that.
b <- answered(g); b$source_id[1] <- "trial_1"
b$source_type[1] <- "protocol"; b$citation[1] <- "Protocol v3.0 section 5.2"
b$retrieved[1] <- ""
stops(read_definition_sources(dwr(b)),
      "...and a trial slot answered without naming its trial at all")
b <- answered(g); b$source_id[1] <- "IMWG_consensus"
b$source_type[1] <- "guideline"; b$citation[1] <- "IMWG 2016 consensus, section 3"
runs(read_definition_sources(dwr(b)),
     "...while IMWG is not a trial and is not asked for an NCT id")
# One id per CELL as well as per slot. The slot check reads the first match, so
# "NCT-A and NCT-B" passed it while naming two trials - and two such cells
# agreeing on their first match are three trials in one column.
b <- answered(g); b$source_id[1] <- "trial_1"
b$citation[1] <- "NCT04000000 and NCT05000000 eligibility"
stops(read_definition_sources(dwr(b)),
      "...and one citation naming two trials, of which only the first is read")
# IMWG has no NCT id, so its identity is the document. Unchecked, one slot
# could quote the consensus on one dimension and another guideline on the next,
# rendered as one column headed IMWG.
# Two IMWG rows on DIFFERENT dimensions - the same slot answering twice, which
# is what the slot is for.
iw <- which(g$source_id == "IMWG_consensus")[1:2]
b <- answered(answered(g, iw[1]), iw[2])
b$source_type[iw] <- "guideline"
b$citation[iw[1]] <- "IMWG 2016 consensus, section 3"
b$citation[iw[2]] <- "NCCN v2.2025, section MM-4"
stops(read_definition_sources(dwr(b)),
      "the IMWG slot quoting two different documents")
b$citation[iw[2]] <- "IMWG 2016 consensus, section 5"
runs(read_definition_sources(dwr(b)),
     "...while two sections of the one document are one source")
# The slot itself is required. Deleting it left a grid that loaded, satisfied a
# dimensions-by-sources row count, and answered a different question.
stops(read_definition_sources(dwr(g[g$source_id != "IMWG_consensus", ])),
      "a grid with the IMWG block deleted entirely")

cat("\n-- an answered row that says nothing about itself --\n")
# Both of these were unchecked, and both are worse than a blank row rather than
# equivalent to one.
b <- answered(g); b$dimension_id[1] <- ""
stops(read_definition_sources(dwr(b)),
      "an answer with no dimension_id, which matches no dimension")
# The reason it matters: `filled$dimension_id == d$dimension_id` is NA for a
# blank, an NA subscript returns an all-NA row, and ONE malformed row is then
# selected against EVERY dimension - each rendered with an answer nobody wrote.
b <- answered(g); b$source_id[1] <- ""
stops(read_definition_sources(dwr(b)),
      "...and an answer with no source_id, which every other check is keyed on")
b <- answered(g); b$notes[1] <- ""
stops(read_definition_sources(dwr(b)),
      "'differs' with no note saying how - the one verdict that needs one")
b <- answered(g); b$concordance[1] <- "agrees"; b$notes[1] <- ""
runs(read_definition_sources(dwr(b)),
     "...while 'agrees' stands on its own, since the answer beside it is the how")

cat("\n", strrep("-", 52), "\n", sep = "")
cat(sprintf("%d passed, %d failed\n", pass, fail))
if (fail > 0L) quit(status = 1L)
