#!/usr/bin/env Rscript
# The melphalan rule as an engine rule, and the three cells built from it.
# No warehouse: the SQL is built as a string and checked, and the decision is
# lifted out of it and evaluated over cases.
#
#   Rscript "aug1_melp/tests/test_aug1_melp.R"

ROOT <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                                 fixed = TRUE))) else getwd()
  dirname(d)
})
PARENT <- dirname(ROOT)
LOT    <- file.path(PARENT, "lot")

pass <- 0L; fail <- 0L
ok <- function(cond, what) {
  if (isTRUE(cond)) { pass <<- pass + 1L; cat("  ok     ", what, "\n") }
  else              { fail <<- fail + 1L; cat("  FAIL   ", what, "\n") }
}
stops <- function(expr, what) ok(inherits(tryCatch(expr, error = function(e) e), "error"), what)
runs  <- function(expr, what) ok(!inherits(tryCatch(expr, error = function(e) e), "error"), what)
has   <- function(x, s) grepl(s, x, fixed = TRUE)

library(glue)
`%||%` <- function(a, b) if (is.null(a)) b else a
source(file.path(LOT, "R", "melp_rule.R"))
source(file.path(ROOT, "R", "cells.R"))

CFG <- list(melp_med_abbr = "MELP", melp_exposure_days = 30L,
            melp_restart_days = 60L, melp_advance_days = 180L, melp_sct_days = 14L)
off <- modifyList(CFG, list(apply_melp_rule = ""))
ask <- modifyList(CFG, list(apply_melp_rule = "as_asked"))
yld <- modifyList(CFG, list(apply_melp_rule = "yield_to_sct"))

cat("\n-- off is not a setting, it is the absence of the rule --\n")
# The whole safety of putting this in the engine rests here. Every hook has to
# emit nothing, or the contract build is not the build that was validated.
ok(identical(melp_lot1_ctes(off), ""), "LOT1 gets no extra CTEs")
ok(identical(melp_lot1_base_from(off), "lot1_base lb"),
   "...and reads lot1_base exactly as the source does")
ok(identical(melp_lotn_ctes(off, 2), ""), "LOT2-5 gets none either")
ok(identical(melp_suppress_predicate(off), ""), "no predicate is added to the candidates")
ok(identical(melp_inject_arm(off, "t", "c", "e"), ""), "and no rows are added to them")
ok(!melp_rule_on(off) && melp_rule_on(ask) && melp_rule_on(yld),
   "on and off are decided by the setting, not by a caller passing a flag")
stops(melp_rule_mode(list(apply_melp_rule = "sometimes")),
      "an unknown mode stops rather than behaving like one of the two")
# The port suite proves the same thing from the other side - the step files are
# the source once these two hooks are undone - so this is the R half of it.
sf <- function(f) paste(readLines(file.path(LOT, "R", "steps", f), warn = FALSE),
                        collapse = "\n")
ok(has(sf("06_lot1_end.R"), "FROM {melp_lot1_base_from(cfg)}") &&
     has(sf("06_lot1_end.R"), "WITH{melp_lot1_ctes(cfg)}"),
   "LOT1 has exactly two hooks, both in 06")
ok(!has(sf("04_lot1_base.R"), "melp_"),
   "...and none in 04, where tx_auto_dates does not exist yet")
ok(has(sf("10_lot2_5_base.R"), "{melp_lotn_ctes(cfg, lot_num)}") &&
     has(sf("10_lot2_5_base.R"), "{melp_suppress_predicate(cfg)}") &&
     has(sf("10_lot2_5_base.R"), "melp_inject_arm(cfg"),
   "LOT2-5 has its three, in the step that builds the line")
# The property both halves are really about, asserted directly: put each hook's
# off value back into the step text and nothing melphalan is left. The port
# suite pins the same thing from the source's side - it undoes the hooks as
# text - so a hook that started returning something else passes there and fails
# here, and one that was edited in the file fails there and passes here.
subst_off <- function(f) {
  txt <- sf(f)
  for (p in list(c("{melp_lot1_ctes(cfg)}",            melp_lot1_ctes(off)),
                 c("{melp_lot1_base_from(cfg)}",       melp_lot1_base_from(off)),
                 c("{melp_lotn_ctes(cfg, lot_num)}",   melp_lotn_ctes(off, 2)),
                 c("{melp_suppress_predicate(cfg)}",   melp_suppress_predicate(off))))
    txt <- gsub(p[1], p[2], txt, fixed = TRUE)
  # The inject arm spans two lines in the step, so it is cut rather than swapped.
  sub("(?s)\\{melp_inject_arm\\(cfg,.*?\\)\\}", melp_inject_arm(off, "t", "c", "e"),
      txt, perl = TRUE)
}
ok(!has(subst_off("06_lot1_end.R"), "melp_") &&
     !has(subst_off("10_lot2_5_base.R"), "melp_"),
   "with the rule off, no melphalan reaches the SQL either step builds")

cat("\n-- the rule is the ask's, branch by branch --\n")
# The decision is lifted out of the generated SQL rather than restated here. A
# second copy would agree with whatever this file believes.
decide <- function(cfg) {
  s <- melp_decision_ctes(cfg, "L", "S", "E", "BM")
  cut <- function(txt, cte) {
    i <- regexpr(paste0(cte, " AS \\("), txt)
    sub("(?s)\\).*$", "", substr(txt, i + attr(i, "match.length"), nchar(txt)), perl = TRUE)
  }
  list(suppress = gsub("\\s+", " ", cut(s, "melp_suppress")),
       inject   = gsub("\\s+", " ", cut(s, "melp_inject")))
}
d <- decide(ask)
ok(has(d$suppress, "INSIDE = 0") && has(d$suppress, "GAP >= 60"),
   "a boundary is removed only outside induction, and only at 60 days or more")
ok(!has(d$suppress, "GAP >= 180") && has(d$inject, "GAP >= 180"),
   "...while a boundary is added only at 180 days or more")
ok(has(d$inject, "NEXT_DT AS INJECT_DT") && has(d$suppress, "EXPO_DT AS SUPPRESS_DT"),
   "the added boundary is at the next exposure, the removed one at this exposure")
# B.1 is the branch where the rule and the engine already agree, so it must
# appear in neither list - suppressing it would delete a boundary both want.
ok(has(d$suppress, "GAP IS NOT NULL"),
   "an exposure with nothing after it is in neither list")

cat("\n-- inside induction is the base-meds join, not a second window --\n")
# Writing datediff(EXPO_DT, LOT_START_DT) <= 59 here would be a second
# definition of induction. It would also be wrong at LOT2-5, where the window is
# 30, and at a CART-started line, where it is 45.
s <- melp_decision_ctes(ask, "L", "S", "E", "BM")
ok(has(s, "CASE WHEN bm.MED_ABBR IS NOT NULL THEN 1 ELSE 0 END AS INSIDE"),
   "a melphalan that induction admitted is inside, by the join the engine uses")
ok(!grepl("INSIDE", sub("(?s)AS INSIDE.*$", "", s, perl = TRUE)) &&
     !has(s, "induction_window_days"),
   "...and no window length is named a second time")

cat("\n-- the two modes differ in exactly one thing --\n")
a <- melp_decision_ctes(ask, "L", "S", "E", "BM")
y <- melp_decision_ctes(yld, "L", "S", "E", "BM")
ok(has(y, "p.HAS_AUTO AS YIELD_THIS") &&
     has(y, "coalesce(p.NEXT_HAS_AUTO, 0) AS YIELD_NEXT"),
   "yield_to_sct reads the coded transplant on this exposure and on the next")
ok(has(a, "0 AS YIELD_THIS") && has(a, "0 AS YIELD_NEXT"),
   "...and as_asked reads neither, because the ask carves nothing out")
# The rest has to be the same text, or the two cells differ in something nobody
# asked about and the comparison between them means nothing.
strip <- function(x) gsub("(p\\.HAS_AUTO|coalesce\\(p\\.NEXT_HAS_AUTO, 0\\)|0) AS YIELD_(THIS|NEXT)",
                          "<Y>", x)
ok(identical(strip(a), strip(y)),
   "...and nothing else about the two builds is different")
# The boundary A.2 and B.3 open falls on the NEXT exposure, so that is the flag
# that decides whether to yield it.
ok(has(d$inject, "YIELD_THIS = 0 AND YIELD_NEXT = 0"),
   "an added boundary is yielded on the exposure it would fall on")
ok(has(d$suppress, "YIELD_THIS = 0") && !has(d$suppress, "YIELD_NEXT"),
   "...and a removed one on the exposure that made it")

cat("\n-- the cells, and what they cannot do --\n")
cells <- melp_cell_plan()
ok(length(cells) == 3L, "three builds: the study's, and the two readings")
ok(identical(cells[[1]]$id, "reference") && is.na(cells[[1]]$mode),
   "the reference is built like the others, not assumed from an existing run")
ok(all(vapply(cells[-1], function(c_i) c_i$mode %in% MELP_RULE_MODES, logical(1))),
   "...and every other cell names a mode the engine accepts")
runs(check_melp_plan(cells, "ndmm_"), "the plan is safe to run beside the study")
stops(check_melp_plan(cells, "melp_reference_"),
      "a cell that would write over the study's own prefix is refused")
rs <- paste(readLines(file.path(ROOT, "run_aug1_melp.R"), warn = FALSE), collapse = "\n")
ok(has(rs, 'env_flag("AUG1_EXECUTE")'),
   "execution is opt-in - three complete builds is not a default")
ok(has(rs, "LOT_CONTRACT_OVERRIDE=TRUE"),
   "a cell says it is building an alternative algorithm")
# The reference must NOT carry it. If it needed the override it would not be
# the contract build, and every delta would be measured against the wrong thing.
ref_guard <- grep("if \\(!is\\.na\\(c_i\\$mode\\)\\)", strsplit(rs, "\n")[[1]])
ok(length(ref_guard) == 1L,
   "...and only the cells that change something, not the reference")
ok(has(rs, "COHORT_PREFIX"),
   "every cell is built over the same cohort, named rather than inferred")

cat("\n-- what is read off the builds --\n")
sql <- melp_metric_sql("F", "A", "r1", "MELP")
ok(all(vapply(names(MELP_METRICS), function(m) has(sql, paste0("AS ", m)), logical(1))),
   paste0("all ", length(MELP_METRICS), " metrics are actually selected"))
ok(has(sql, "RUN_ID = 'r1'"),
   "the progression rows are this cell's, not whichever run answered first")
# The four melphalan figures are what makes the double-count visible.
ok(has(sql, "AS n_melp_add") && has(sql, "AS n_sct_auto_end"),
   "lines ended by melphalan and by transplant are counted separately")
cmp <- melp_compare(data.frame(
  cell = c("reference", "as_asked", "yield_to_sct"),
  n_patients = c(500, 500, 500), n_lines = c(1000, 1100, 1050),
  median_lines = c(2, 2, 2), pct_reaching_lot2 = c(40, 44, 42),
  pct_reaching_lot3 = c(20, 21, 20), median_lot1_length = c(100, 90, 95),
  median_lot1_meds = c(3, 3, 3), n_lot1_regimens = c(50, 50, 50),
  n_cart_init = c(10, 10, 10), n_melp_add = c(30, 45, 38),
  n_melp_lines = c(60, 70, 65), n_sct_auto_end = c(80, 80, 74),
  n_pat_with_melp = c(55, 55, 55), stringsAsFactors = FALSE))
ok(identical(cmp$change[cmp$cell == "as_asked" & cmp$metric == "n_lines"], 100),
   "a cell is reported as its difference from the reference")
ok(nrow(cmp) == 2L * length(MELP_METRICS),
   "...for every metric and every cell, so nothing is quietly dropped")
ap <- melp_modes_apart(data.frame(
  cell = c("reference", "as_asked", "yield_to_sct"),
  n_patients = c(500, 500, 500), n_lines = c(1000, 1100, 1050),
  median_lines = c(2, 2, 2), pct_reaching_lot2 = c(40, 44, 42),
  pct_reaching_lot3 = c(20, 21, 20), median_lot1_length = c(100, 90, 95),
  median_lot1_meds = c(3, 3, 3), n_lot1_regimens = c(50, 50, 50),
  n_cart_init = c(10, 10, 10), n_melp_add = c(30, 45, 38),
  n_melp_lines = c(60, 70, 65), n_sct_auto_end = c(80, 80, 74),
  n_pat_with_melp = c(55, 55, 55), stringsAsFactors = FALSE))
ok(!is.null(ap) && identical(ap$difference[ap$metric == "n_melp_add"], 7),
   "the two readings are also compared with each other, which is the open question")

cat("\n-- and no direction is predicted, deliberately --\n")
# The sensitivity sweep predicts a sign before the run and scores it. That works
# where a threshold moves a number one way. This rule moves boundaries both ways
# at once, so a prediction would be a guess dressed as a test.
ok(!any(grepl("expect|predict", readLines(file.path(ROOT, "R", "cells.R"),
                                          warn = FALSE), ignore.case = TRUE) &
          !grepl("^\\s*#", readLines(file.path(ROOT, "R", "cells.R"), warn = FALSE))),
   "no cell carries a predicted direction")
ok(any(grepl("no direction is predicted", rs, ignore.case = TRUE)),
   "...and the run says so rather than leaving it looking like an omission")

cat("\n", strrep("-", 52), "\n", sep = "")
cat(sprintf("%d passed, %d failed\n", pass, fail))
if (fail > 0L) quit(status = 1L)
