#!/usr/bin/env Rscript
# The melphalan rule, held to the ask. No warehouse: the SQL is built as a
# string, and the branch decision is lifted out of it and evaluated over cases.
#
#   Rscript "exploration/lot/tests/test_melphalan.R"

ROOT <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                                 fixed = TRUE))) else getwd()
  dirname(d)
})
PARENT <- dirname(ROOT)
# This package sits in its own area beside lot/, so reads of the engine go
# through the study folder.
LOT    <- file.path(dirname(PARENT), "lot", "engine")
pass <- 0L; fail <- 0L
ok <- function(cond, what) {
  if (isTRUE(cond)) { pass <<- pass + 1L; cat("  ok    ", what, "\n") }
  else { fail <<- fail + 1L; cat("  FAIL  ", what, "\n") }
}
stops <- function(expr, what) ok(inherits(tryCatch(expr, error = function(e) e), "error"), what)
has   <- function(x, s) grepl(s, x, fixed = TRUE)
if (requireNamespace("glue", quietly = TRUE)) library(glue) else
  glue <- function(..., .envir = parent.frame()) {
    t <- paste0(..., collapse = "")
    m <- gregexpr("\\{[^{}]+\\}", t)[[1]]
    if (m[1] == -1L) return(t)
    len <- attr(m, "match.length"); out <- character(0); pos <- 1L
    for (i in seq_along(m)) {
      out <- c(out, substr(t, pos, m[i] - 1L),
               paste(as.character(eval(parse(
                 text = substr(t, m[i] + 1L, m[i] + len[i] - 2L)), .envir)), collapse = ""))
      pos <- m[i] + len[i]
    }
    paste0(c(out, substr(t, pos, nchar(t))), collapse = "")
  }
sql_text <- function(x) paste0("'", gsub("'", "''", as.character(x)), "'")
source(file.path(ROOT, "R", "melphalan.R"))

cat("\n-- the settings are the ask's, and a junk one stops rather than defaults --\n")
mc <- melp_cfg(function(nm, unset = "") unset)
ok(identical(mc$exposure_days, 30L), "an exposure is one administration - 30 days")
ok(identical(mc$restart_days, 60L) && identical(mc$advance_days, 180L),
   "60 and 180 days are the two thresholds the ask names")
ok(identical(mc$induction_1l, 60L) && identical(mc$induction_n, 30L),
   "the induction window is the build's own, not a second copy")
# 180 is the transplant tandem window, and that is the point of the rule.
tan <- readLines(file.path(LOT, "config.csv"), warn = FALSE)
ok(any(grepl("^SCT_TANDEM_DAYS,180", tan)),
   "...and 180 is the same number the transplant rule already uses")
stops(melp_cfg(function(nm, unset = "") if (nm == "MELP_ADVANCE_DAYS") "soon" else unset),
      "a threshold that is not a number stops rather than falling back")
stops(melp_cfg(function(nm, unset = "") if (nm == "MELP_RULE_MODE") "whatever" else unset),
      "an unknown transplant mode stops - the two readings are not a free string")

cat("\n-- the rule itself, lifted out of the SQL and run over cases --\n")
# Restating the branches here would be a second implementation that agrees with
# whatever this file believes. The CASE the warehouse runs is the one tested.
rule_of <- function(cfg) {
  s <- melp_rule_sql("L", "M", "A", cfg, "r1")
  # Cut at the alias, then back to the nearest CASE. Anchoring on the first arm
  # by name breaks the moment an arm is added or reordered, which it was.
  x <- strsplit(as.character(s), "END AS ADVANCES", fixed = TRUE)[[1]][1]
  x <- sub("(?s)^.*\\bCASE\\b", "", x, perl = TRUE)
  x <- gsub("\n\\s*", " ", trimws(x))
  els <- "NA"
  if (grepl("\\bELSE\\b", x)) {
    els <- trimws(sub("^.*\\bELSE\\b", "", x)); x <- sub("\\bELSE\\b.*$", "", x)
  }
  arms <- Filter(nzchar, trimws(strsplit(x, "\\bWHEN\\b")[[1]]))
  tr <- function(s) {
    s <- trimws(s)
    s <- gsub("([A-Za-z_][A-Za-z0-9_]*) IS NULL", "is.na(\\1)", s)
    s <- gsub("\\bAND\\b", "&", gsub("\\bOR\\b", "|", s))
    s <- gsub("(?<![<>!=])=(?!=)", "==", s, perl = TRUE)
    # After IS NULL, or the guard above would be rewritten into is.na(NA).
    gsub("\\bNULL\\b", "NA", s)
  }
  body <- paste0(paste(vapply(arms, function(a) {
    kv <- strsplit(a, "\\bTHEN\\b")[[1]]
    paste0("if (isTRUE(", tr(kv[1]), ")) ", tr(kv[2]), " else ")
  }, character(1)), collapse = ""), tr(els))
  # YIELD_THIS / YIELD_NEXT are computed a step earlier in the SQL, from the
  # mode. Passed in here so the decision under test is the flat CASE itself.
  function(GAP, INSIDE, YIELD_THIS = 0, YIELD_NEXT = 0) {
    e <- list2env(list(GAP = GAP, INSIDE = INSIDE, YIELD_THIS = YIELD_THIS,
                       YIELD_NEXT = YIELD_NEXT), parent = environment())
    tryCatch(eval(parse(text = body), envir = e), error = function(e) "PARSE-FAIL")
  }
}
r <- rule_of(mc)
ok(!identical(r(200, 1), "PARSE-FAIL"), "the branch decision lifts out of the SQL")

# A. first exposure inside the induction window.
ok(identical(r(179, 1), "NO_ADVANCE"), "A: inside induction, next under 180 days - no advance")
ok(identical(r(180, 1), "NEXT"),
   "A: inside induction, next at 180 days - the NEXT exposure starts a line")
ok(identical(r(400, 1), "NEXT"), "...and any later one likewise")
# B. first exposure outside it.
ok(identical(r(59, 0), "FIRST"),
   "B: outside induction, next under 60 days - the FIRST exposure starts a line")
ok(identical(r(60, 0), "NO_ADVANCE"), "B: outside induction, next at 60 days - neither advances")
ok(identical(r(179, 0), "NO_ADVANCE"), "...and at 179 days likewise")
ok(identical(r(180, 0), "NEXT"),
   "B: outside induction, next at 180 days - the NEXT exposure starts a line")
# The boundaries are where the ask puts them, not one day off.
ok(identical(r(179, 1), "NO_ADVANCE") && identical(r(180, 1), "NEXT"),
   "the 180-day boundary is inclusive, as '>= 180 days later' says")
ok(identical(r(59, 0), "FIRST") && identical(r(60, 0), "NO_ADVANCE"),
   "the 60-day boundary is exclusive, as '< 60 days later' says")
# A last exposure has nothing after it, so it decides nothing.
# NO_NEXT, not NO_ADVANCE. The rule says nothing about a lone exposure, and
# collapsing the two let the impact query remove its boundary anyway.
ok(identical(r(NA, 1), "NO_NEXT") && identical(r(NA, 0), "NO_NEXT"),
   "an exposure with no next one is NO_NEXT, distinct from the rule declining")
ok(identical(r(200, NA), "UNPLACED"),
   "...and one outside every line is UNPLACED, also distinct")

cat("\n-- the two readings of a coded transplant are both real --\n")
y <- rule_of(modifyList(mc, list(mode = "yield_to_sct")))
a <- rule_of(modifyList(mc, list(mode = "as_asked")))
ok(identical(y(200, 1, YIELD_THIS = 1), "YIELDED"),
   "yield_to_sct: an exposure with a coded transplant is left to the SCT rule")
ok(identical(a(200, 1, YIELD_THIS = 0), "NEXT"),
   "as_asked: the same exposure advances, because the ask does not carve it out")
# And the mode is what sets those flags, not the caller.
ok(grepl("HAS_AUTO = 1' THEN 1 ELSE 0 END AS YIELD_THIS|HAS_AUTO = 1 THEN 1 ELSE 0 END AS YIELD_THIS",
         melp_rule_sql("L", "M", "A", modifyList(mc, list(mode = "yield_to_sct")), "r")),
   "yield_to_sct sets YIELD_THIS from the coded transplant")
ok(grepl("WHEN 1 = 0 THEN 1 ELSE 0 END AS YIELD_THIS",
         melp_rule_sql("L", "M", "A", modifyList(mc, list(mode = "as_asked")), "r")),
   "...and as_asked never sets it, whatever is coded")
ok(identical(y(200, 1), a(200, 1)),
   "...and where no transplant is coded the two readings agree")
# The A.2 and B.3 boundaries fall on the NEXT exposure, so that is the one
# yielding has to look at. Carrying only this exposure's flag let a coded
# transplant open a melphalan boundary in yield mode.
ok(identical(y(200, 1, YIELD_NEXT = 1), "YIELDED_NEXT"),
   "yield_to_sct looks at the exposure the boundary would fall on, not this one")
ok(identical(y(200, 0, YIELD_NEXT = 1), "YIELDED_NEXT"),
   "...in the outside-induction branch too, where the boundary is also the next one")
ok(identical(a(200, 1, YIELD_NEXT = 0), "NEXT"),
   "...and as_asked judges it anyway, because the ask carves out nothing")

cat("\n-- the branch a dose lands in is not the one the build already gave it --\n")
# A melphalan dose first seen outside the induction window is an add-med, and
# the build ends the line the DAY before it - so the dose sits on day 0 of the
# line it created. Placing it by "which line contains this date" reads that as
# inside induction and turns every B branch into an A.
rl <- melp_rule_sql("L", "M", "A", mc, "r1")
ok(has(rl, "PREV_REASON = 'MED_ADD'") && has(rl, "PREV_ADD_MED = upper('MELP')"),
   "an exposure on a line start this drug created is spotted")
ok(has(rl, "THEN l.PREV_START_DT ELSE l.LOT_START_DT END AS REF_START_DT"),
   "...and measured against the PREVIOUS line, not the one it opened")
ok(has(rl, "THEN l.PREV_LOT_NUM ELSE l.LOT_NUM END   AS REF_LOT_NUM"),
   "...so the induction window is that line's as well")
ok(has(rl, "datediff(EXPO_DT, REF_START_DT) AS DAYS_INTO_LINE"),
   "...and the distance into the line is measured from it")
# The merge is keyed on the exposure that made the boundary, not on a date join.
ok(has(im0 <- melp_impact_sql("R", "L", mc, "r1"), "CREATED_BOUNDARY = 1") &&
     has(im0, "ADVANCES IN ('NO_ADVANCE', 'NEXT', 'YIELDED_NEXT')"),
   "a removed boundary is one this exposure created, where the rule moves it")
ok(!has(im0, "r.ADVANCE_DT = date_add"),
   "...not any boundary with no advance date, which NO_NEXT and YIELDED share")
# No resulting line count is offered, because it is not recoverable.
ok(!has(im0, "N_LINES_RULE"),
   "no resulting line count is published - boundaries are not lines")

cat("\n-- it reads a finished run and rebuilds nothing --\n")
rs <- paste(readLines(file.path(ROOT, "run_melphalan_rule.R"), warn = FALSE),
            collapse = "\n")
sq <- paste(melp_rule_sql("L", "M", "A", mc, "r1"),
            melp_impact_sql("R", "L", mc, "r1"), melp_branch_sql("R"))
ok(!has(sq, "LOT_LONG_FINAL AS") && !has(rs, "build.R"),
   "it writes no LOT table and starts no build")
ok(all(vapply(c("MELP_RULE_EXPOSURES", "MELP_RULE_BRANCHES", "MELP_RULE_IMPACT"),
              function(n) has(rs, n), logical(1))),
   "its three outputs are its own, under its own names")
ok(has(rs, "require_lot_run(con, prefix)"),
   "it holds the run to the same ownership rule the other programs use")
ok(has(rs, 'env_flag("MELP_EXECUTE")'),
   "execution is opt-in - the default prints the rule and connects to nothing")
# Every row says which reading produced it, or two runs are indistinguishable.
ok(has(sq, "AS MELP_RULE_MODE") && has(sq, "AS MELP_RUN_ID"),
   "every row carries the mode and the run that wrote it")

cat("\n-- the impact is counted in both directions, not netted --\n")
im <- melp_impact_sql("R", "L", mc, "r1")
ok(has(im, "AS N_SPLIT") && has(im, "AS N_MERGE"),
   "boundaries added and boundaries removed are separate columns")
# A merge is an exposure that CREATED a boundary - the build ended a line by
# adding this drug at it - where the rule declines. CREATED_BOUNDARY is set in
# the exposure table from the previous line's end reason and added drug, so the
# drug is already checked there; keying on the reason alone would count every
# add-med line whatever ended it.
rl2 <- melp_rule_sql("L", "M", "A", mc, "r1")
ok(has(rl2, "PREV_REASON = 'MED_ADD'") && has(rl2, "PREV_ADD_MED = upper('MELP')"),
   "a removed boundary is an add-med line ended by THIS drug, not any drug")
# B.3 MOVES a boundary: the rule declines at the first dose and puts one at the
# later dose. Counting only NO_ADVANCE would record the new boundary as a split
# and leave the first standing - an addition with no removal.
ok(has(im, "ADVANCES IN ('NO_ADVANCE', 'NEXT', 'YIELDED_NEXT')"),
   "a created boundary goes when the rule declines at it OR moves it later")
ok(!has(im, "ADVANCES = 'NO_ADVANCE'"),
   "...so B.3's move is a removal and an addition, not an addition alone")
# B.3 with a transplant coded on the later dose. Yielding hands that later event
# to the SCT rule, so there is no split - but the rule still declines at this
# dose. Left out, the run kept a boundary the rule removed and yielded away the
# event that was to replace it: a B.3 patient scored as no change at all.
ok(has(im, "'YIELDED_NEXT'"),
   "...and a yielded later dose still removes the boundary this one made")
# First keeps it - that is B.1, where the rule and the build agree - and the
# undecided reasons say nothing, so they cannot remove anything. YIELDED is one
# of them: there the coded transplant is on THIS dose, so the rule was never
# applied to it.
ok(!has(im, "'FIRST'") && !has(im, "'NO_NEXT'") && !has(im, "'YIELDED'"),
   "...while B.1 keeps its boundary and the undecided reasons remove none")
ok(!has(im, "'UNPLACED'"),
   "...including an exposure that fell outside every line")
# A split has to be inside a line, not on its start - a date that already
# starts a line is already a boundary and would be counted twice.
ok(has(im, "r.ADVANCE_DT >  l.LOT_START_DT"),
   "an added boundary is strictly inside a line, so a line start is not doubled")
ok(has(rs, "NOT a resulting line count"),
   "the run says these are boundaries, not the line count after a rebuild")

cat("\n-- the printed advance count is the exposures that advance --\n")
# Every case the rule can meet, put through the lifted CASE. None comes back
# NULL, so "ADVANCES IS NOT NULL" is the row count and printing it as the
# advances reported every exposure as advancing a line.
every <- list(r(NA, NA), r(NA, 1), r(NA, 0), r(200, NA), r(59, 0), r(100, 0),
              r(200, 0), r(100, 1), r(200, 1), y(200, 1, YIELD_THIS = 1),
              y(200, 0, YIELD_NEXT = 1))
ok(!any(vapply(every, function(v) length(v) != 1L || is.na(v), logical(1))),
   "every exposure gets a reason, so the reason column is never null")
ok(has(rl, "CASE WHEN ADVANCES = 'FIRST' THEN EXPO_DT") &&
     has(rl, "WHEN ADVANCES = 'NEXT'  THEN NEXT_DT END AS ADVANCE_DT"),
   "...while ADVANCE_DT is set by FIRST and NEXT alone")
ok(has(rs, "sum(CASE WHEN ADVANCE_DT IS NOT NULL THEN 1 ELSE 0 END) AS n_adv"),
   "...so the run counts advances off ADVANCE_DT")
ok(!has(rs, "WHEN ADVANCES IS NOT NULL THEN 1"),
   "...and not off the reason, which would print the total as the advances")

cat("\n-- the branch summary shows both exposures' transplant flags --\n")
# A YIELDED_NEXT row has no transplant coded on the exposure itself: the arm is
# only reached once YIELDED has declined it, and YIELDED is this dose's flag.
ok(identical(y(200, 1, YIELD_THIS = 1, YIELD_NEXT = 1), "YIELDED"),
   "a transplant on this dose is decided before the next dose is looked at")
bs <- melp_branch_sql("R")
ok(has(bs, "sum(HAS_AUTO)") && has(bs, "sum(coalesce(NEXT_HAS_AUTO, 0))"),
   "...so the summary counts the next dose's transplant beside this one's")
ok(has(rl, "NEXT_HAS_AUTO"), "...and the exposure table carries it to be counted")

cat("\n", strrep("-", 52), "\n", sep = "")
cat(sprintf("%d passed, %d failed\n", pass, fail))
if (fail > 0L) quit(status = 1L)
