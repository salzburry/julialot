#!/usr/bin/env Rscript
# The melphalan rule as an engine rule, and the three cells built from it.
# No warehouse: the SQL is built as a string and checked, and the decision is
# lifted out of it and evaluated over cases.
#
#   Rscript "exploration/melphalan/tests/test_aug1_melp.R"

ROOT <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                                 fixed = TRUE))) else getwd()
  dirname(d)
})
PARENT <- dirname(ROOT)
# The engine is not a sibling any more - this package sits in exploration/,
# so the engine is reached through the study folder. PARENT stays the area,
# because the proposal is documented in exploration/FILES.md.
LOT    <- file.path(dirname(PARENT), "lot", "engine")

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
# prior_regimen.R first: melp_rule.R splices map_restart_sql() into LOT1's
# recomputed candidate list, so the two drive one definition of a restart
# rather than a copy each. The engine loads both; so does this.
source(file.path(LOT, "R", "prior_regimen.R"))
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
ok(identical(melp_lotn_ctes(off, 2, 30L, 45L, "single_day"), ""), "LOT2-5 gets none either")
ok(identical(melp_suppress_predicate(off), ""), "no predicate is added to the candidates")
ok(identical(melp_inject_arm(off, "t", "c", "e"), ""), "and no rows are added to them")
ok(!melp_rule_on(off) && melp_rule_on(ask) && melp_rule_on(yld),
   "on and off are decided by the setting, not by a caller passing a flag")
stops(melp_rule_mode(list(apply_melp_rule = "sometimes")),
      "an unknown mode stops rather than behaving like one of the two")
# Where the hooks are, and that there are no others. The step files carry
# exactly two in 06 and three in 10; anything else melphalan in them is a hook
# nobody registered here.
sf <- function(f) paste(readLines(file.path(LOT, "R", "steps", f), warn = FALSE),
                        collapse = "\n")
ok(has(sf("06_lot1_end.R"), "FROM {melp_lot1_base_from(cfg)}") &&
     has(sf("06_lot1_end.R"), "WITH{melp_lot1_ctes(cfg)}"),
   "LOT1 has exactly two hooks, both in 06")
ok(!has(sf("04_lot1_base.R"), "melp_"),
   "...and none in 04, where tx_auto_dates does not exist yet")
ok(has(sf("10_lot2_5_base.R"), "{melp_lotn_ctes(cfg, lot_num, induction_window_days,") &&
     has(sf("10_lot2_5_base.R"), "{melp_suppress_predicate(cfg)}") &&
     has(sf("10_lot2_5_base.R"), "melp_inject_arm(cfg"),
   "LOT2-5 has its three, in the step that builds the line")
cat("\n-- and every fragment opens with its own newline --\n")
# Each one splices straight after a {} in the step template, and glue() trims a
# template's leading blank line - so a fragment that does not open with one
# welds onto the text before it.
#
# Not a formatting nit. melp_allo_guard was the one without, and every
# melphalan cell died in Spark on
#   AND i.INJECT_DT <= lot2_start.OBS_END_DTAND lot2_start.LOT2_START_TYPE ...
# which parses as an identifier OBS_END_DTAND followed by a table name. The
# off-path tests above all passed, because off emits nothing and nothing is
# what they check.
#
# Checked for all of them, not for that one: the next fragment added has the
# same choice to get wrong.
FRAGMENTS <- list(
  melp_lot1_ctes          = list(yld),
  melp_lotn_ctes          = list(yld, 2, 30L, 45L, "single_day"),
  melp_suppress_predicate = list(yld),
  melp_inject_arm         = list(yld, "lot2_start", "LOT2_START_DT",
                                 "lot2_start.OBS_END_DT"),
  melp_allo_guard         = list(2L, "single_day"))
for (nm in names(FRAGMENTS)) {
  v <- as.character(do.call(nm, FRAGMENTS[[nm]]))
  ok(nzchar(v) && startsWith(v, "\n"),
     paste0(nm, "() emits something and opens it with a newline"))
}
# The splice that broke, assembled rather than described.
arm <- melp_inject_arm(yld, "lot2_start", "LOT2_START_DT", "lot2_start.OBS_END_DT",
                       melp_allo_guard(2L, "single_day"))
ok(has(arm, "<= lot2_start.OBS_END_DT\n"),
   "the ALLO guard lands on its own line, not onto the column before it")
ok(!has(arm, "OBS_END_DTAND"),
   "...so the text that stopped every cell in Spark cannot be produced")

# The property both halves are really about, asserted directly: put each hook's
# off value back into the step text and nothing melphalan is left. The port
# suite pins the same thing from the source's side - it undoes the hooks as
# text - so a hook that started returning something else passes there and fails
# here, and one that was edited in the file fails there and passes here.
subst_off <- function(f) {
  txt <- sf(f)
  for (p in list(c("{melp_lot1_ctes(cfg)}",            melp_lot1_ctes(off)),
                 c("{melp_lot1_base_from(cfg)}",       melp_lot1_base_from(off)),
                 c("{melp_lotn_ctes(cfg, lot_num, induction_window_days, cart_consolidation_days, allo_lot_span)}",
                   melp_lotn_ctes(off, 2, 30L, 45L, "single_day")),
                 c("{melp_prev_line_ctes(cfg, prev_med_window, cart_consolidation_days)}",
                   melp_prev_line_ctes(off, 60L, 45L)),
                 c("{melp_hold_join(cfg, 'ls')}",      melp_hold_join(off, "ls")),
                 c("{melp_suppress_predicate(cfg)}",   melp_suppress_predicate(off)),
                 c("{melp_prior_regimen_exempt(cfg)}", melp_prior_regimen_exempt(off))))
    txt <- gsub(p[1], p[2], txt, fixed = TRUE)
  # The inject arm spans two lines in the step, so it is cut rather than swapped.
  txt <- sub("(?s)\\{melp_inject_arm\\(cfg,.*?\\)\\}", melp_inject_arm(off, "t", "c", "e"),
             txt, perl = TRUE)
  # melp_runout_case() is called in R rather than spliced in a template - it
  # wraps an expression the step already had - so it is cut the same way. Off,
  # it hands that expression straight back, which is what the step read before.
  sub("(?s)melp_runout_case\\(cfg, paste0\\(.*?\\)\\)", "<off>", txt, perl = TRUE)
}
ok(!has(subst_off("06_lot1_end.R"), "melp_") &&
     !has(subst_off("10_lot2_5_base.R"), "melp_"),
   "with the rule off, no melphalan reaches the SQL either step builds")

cat("\n-- the rule is the ask's, branch by branch --\n")
# The decision is lifted out of the generated SQL rather than restated here. A
# second copy would agree with whatever this file believes.
decide <- function(cfg) {
  s <- melp_decision_ctes(cfg, "L", "S", "E", "L.IND_END")
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
ok(has(d$suppress, "GAP IS NOT NULL"),
   "an exposure with nothing after it is in neither list")
# B.1 - outside induction, next dose inside 60 days - has its own arm. The
# engine opens that boundary itself only when melphalan is not a base agent.
# Dosed on day 10, day 100 and day 140, melphalan is in the regimen from day 10,
# so the engine makes no candidate at any melphalan date in that line - and
# without this arm the day-100 boundary B.1 calls for is simply lost.
ok(has(d$inject, "INSIDE = 0") && has(d$inject, "GAP < 60") &&
     has(d$inject, "EXPO_DT AS INJECT_DT"),
   "B.1 puts a boundary at this exposure, whatever the engine did with it")
ok(length(gregexpr("INJECT_DT", d$inject)[[1]]) == 2L,
   "...so there are two injected dates, not one: this exposure and the next")
# And it is decided on this exposure's transplant flag, since that is where the
# boundary falls - the >= 180 arm is the one that looks at the next exposure.
b1 <- sub("^.*UNION", "", d$inject, perl = TRUE)
ok(has(b1, "YIELD_THIS = 0") && !has(b1, "YIELD_NEXT"),
   "...and yielded on the exposure it lands on, not the one after it")

cat("\n-- inside induction is THIS exposure's date, not the drug's membership --\n")
# The two are the same only for the first dose. Dosed on day 10 and again on day
# 100, melphalan is in the base regimen throughout - so reading it off the
# regimen calls the day-100 dose an A branch, and B.1 or B.2 is lost. That was
# the bug: the rule and the July measurement, which computes DAYS_INTO_LINE per
# exposure, disagreed about the same patient.
s <- melp_decision_ctes(ask, "L", "S", "E", "L.IND_END")
ok(has(s, "CASE WHEN p.EXPO_DT <= L.IND_END THEN 1 ELSE 0 END AS INSIDE"),
   "each exposure is judged on its own date against the line's induction end")
ok(!has(s, "MED_ABBR IS NOT NULL") && !has(s, "base_meds"),
   "...and not on whether the drug reached the regimen")
# The window itself is the step's, handed in. Naming a number here would be a
# second definition of induction, and wrong at LOT2-5 and on a CART line.
ok(!has(s, "induction_window_days") && !has(s, "IND_DAYS"),
   "...and no window length is written down a second time")
# The LOT N expression has to be the step's own, character for character.
norm <- function(x) gsub("\\s+", " ", trimws(x))
step10 <- sf("10_lot2_5_base.R")
# The step's expression, rendered with the same two numbers the rule is given,
# so what is compared is the SQL each would emit rather than the source text.
eng <- norm(regmatches(step10, regexpr(
  "CASE\\s*\\n\\s*WHEN ls\\.LOT\\{lot_num\\}_START_TYPE = 'SCT_ALLO'(?s).*?\\n\\s*END",
  step10, perl = TRUE)))
eng <- gsub("{cart_consolidation_days - 1}", "44", eng, fixed = TRUE)
eng <- gsub("{induction_window_days - 1}",   "29", eng, fixed = TRUE)
rule <- melp_lotn_ctes(ask, "{lot_num}", 30L, 45L, "single_day")
got <- norm(sub("(?s)^.*?p\\.EXPO_DT <= (CASE.*?END) THEN 1 ELSE 0 END AS INSIDE.*$",
                "\\1", rule, perl = TRUE))
ok(nzchar(eng) && identical(gsub("lot\\{lot_num\\}_start", "ls", got), eng),
   "the LOT2-5 induction end is the one first_add_candidates uses, not a copy")

cat("\n-- the two modes differ in exactly one thing --\n")
a <- melp_decision_ctes(ask, "L", "S", "E", "L.IND_END")
y <- melp_decision_ctes(yld, "L", "S", "E", "L.IND_END")
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
# Removal has two arms, and each is yielded on the exposure whose boundary it
# takes away: the first dose of the pair by its own flag, and B.2's later dose
# - which is NEXT from the row that judges the pair - by that row's next flag.
# Guarding the second arm on YIELD_THIS alone would remove a boundary on an
# exposure the transplant rule was left to decide.
sup <- strsplit(d$suppress, "UNION", fixed = TRUE)[[1]]
ok(length(sup) == 3L &&
     has(sup[1], "YIELD_THIS = 0") && !has(sup[1], "YIELD_NEXT") &&
     has(sup[2], "YIELD_THIS = 0 AND YIELD_NEXT = 0") &&
     has(sup[3], "YIELD_THIS = 0 AND YIELD_NEXT = 0"),
   "...and a removed one on whichever exposure it would have fallen on")
# A.1's later exposure. The email says a first dose inside induction with the
# next under 180 days does not advance the LOT, and nothing in the file said so
# until now: the two out-of-induction arms both test INSIDE = 0.
ok(has(sup[3], "INSIDE = 1") && has(sup[3], "NEXT_DT AS SUPPRESS_DT"),
   "A.1's later exposure is taken off the candidate list, on its own date")
ok(has(sup[3], paste0("GAP < ", CFG$melp_advance_days)) &&
     !has(sup[3], paste0("GAP >= ", CFG$melp_restart_days)),
   "...bounded above only - A.2 is the same shape past 180 days and does advance")
ok(sum(vapply(sup, function(s) has(s, "INSIDE = 1"), logical(1))) == 1L,
   "...and it is the only arm that acts inside induction")

# B.2 again, as a date the line is carried to rather than a boundary removed.
# Taking both boundaries away stops melphalan ENDING the line; it does not keep
# the later dose INSIDE it. Where the regimen runs out between the two, the
# line ends at the run-out and the second dose lands in no line at all - the
# same rule having just refused it as a line start.
hold <- gsub("\\s+", " ", local({
  s2 <- melp_decision_ctes(ask, "L", "S", "E", "L.IND_END")
  i <- regexpr("melp_hold AS \\(", s2)
  sub("(?s)\\) GROUP BY.*$", "", substr(s2, i + attr(i, "match.length"), nchar(s2)), perl = TRUE)
}))
ok(has(hold, "max(j.NEXT_DT) AS MELP_HOLD_DT"),
   "the hold is the LATER exposure of the pair, which is the one at risk")
ok(has(hold, "INSIDE = 0") && has(hold, "GAP >= 60") && has(hold, "GAP < 180"),
   "...and it is B.2's window exactly - not A.1, not B.1, not B.3")
ok(has(hold, "j.NEXT_DT <= E"),
   "...bounded by the line's span, so it cannot reach past observation")
# Carried on the run-out rather than as an end reason of its own, so the 90-day
# confirmation is measured from the dose and every other end still outranks it.
ok(has(melp_lot1_base_from(ask), "AS LOT1_BASE_RUNOUT_DT") &&
     has(melp_lot1_base_from(ask), "mh.MELP_HOLD_DT > lb0.LOT1_BASE_RUNOUT_DT"),
   "LOT1 carries its run-out forward to the hold, and only forward")
ok(identical(melp_runout_case(off, "X"), "X"),
   "...and with the rule off the run-out expression is handed straight back")
ok(has(melp_runout_case(ask, "X"), "mh.MELP_HOLD_DT > X") &&
     has(melp_runout_case(ask, "X"), "ELSE X END"),
   "LOT2-5 wraps its own run-out the same way")
ok(!has(melp_lot1_base_from(ask), "LOT1_BASE_RUNOUT_DT,\n           mp."),
   "the swapped run-out is EXCEPTed from lb0.*, so the column is not ambiguous")

cat("\n-- the reader that answers the three questions --\n")
# read_melp_asks.R had no cover at all: the gate could go green with the file
# asking the wrong question of the warehouse. No connection here, so what is
# checked is the text - which query is asked, and which guards stand in front
# of it.
ra <- paste(readLines(file.path(ROOT, "read_melp_asks.R"), warn = FALSE),
            collapse = "\n")
ok(!grepl("(?m)^\\s*(db_exec|dbExecute|CREATE|INSERT|DROP|UPDATE|DELETE)\\b", ra, perl = TRUE),
   "the reader only reads - no statement in it writes to the warehouse")
ok(has(ra, "melp_read_inputs") && has(ra, "melp_check_inputs") ||
     has(ra, "melp_read_inputs"),
   "it holds all cells to one cohort attempt, code list set and study window")
ok(has(ra, "melp_status_unchanged(con, cells, status)"),
   "...and re-checks the build status before anything is written")
ok(has(ra, 'identical(melp_check_code(inputs, LOT_ROOT), FALSE)') &&
     has(ra, "stop("),
   "a cell built by older engine code stops the read rather than warning")
ok(has(ra, "apply_cart_induction_rule") && has(ra, "Rebuild those cells"),
   "the CAR-T 60-day rule is a precondition, not a column in the output")
# The three questions, each recognisable in the SQL that answers it.
ok(has(ra, "LOT_BASE_LENGTH") && has(ra, "MEDIAN_CHANGE"),
   "Q1 answers the CHANGE in line duration, not three tables to subtract by eye")
ok(has(ra, "GROUP BY r.LOT_NUM, r.REGIMEN") && has(ra, "PCT_OF_LINE"),
   "Q2 answers the distribution of regimens at each line")
ok(has(ra, "IS_MELP_MONO") && has(ra, "q2$LOT_NUM == 2"),
   "...and pulls 2L melphalan monotherapy out of that table rather than beside it")
ok(has(ra, "melp_sct_sql()") && has(ra, "ms.MAP_START_DT >= l.LOT_START_DT"),
   "Q3 keys a melphalan LOT on a DOSE inside the line, not on the regimen string")
# The regimen string is the wrong test for Q3 and the file says why, so the
# next reader does not simplify it back.
ok(has(ra, "never reaches LOT_BASE_MEDS"),
   "...and the reason is recorded, since a regimen test looks simpler and is wrong")
ok(has(ra, "ASK_CSVS") && has(ra, "unlink(f)"),
   "last run's CSVs are cleared before this one starts, not as it writes")
ok(has(ra, "melp_ask2_melp_lots_by_line.csv"),
   "...including the name Q2 used before it carried the distribution")

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

# --- clearing a prefix before it is rebuilt ---------------------------------
# No warehouse, so db_q and db_exec are replaced for this block: the first
# answers SHOW TABLES from a fixture, the second records what it was asked to
# drop. What is under test is which names come out, and there is no way to
# check that against a real connection here.
local({
  seen <- character(0)
  listed <- c("melp_reference_LOT_LONG_FINAL", "melp_reference_MAP_STACKED",
              "melp_reference_OLD_TABLE_FROM_A_PREVIOUS_BUILD",
              # What SHOW TABLES ... LIKE must not be trusted to have excluded.
              "ndmm_LOT_LONG_FINAL", "xmelp_reference_STRAY")
  fake <- function(cols) {
    assign("db_q", function(con, sql) setNames(list(listed), cols[1]),
           envir = globalenv())
    assign("db_exec", function(con, sql) { seen <<- c(seen, sql); 1L },
           envir = globalenv())
  }
  # lot_config too: this suite never loads the engine's config machinery, and
  # sourcing it here to reach two fields would make the whole test depend on it.
  assign("lot_config", function() list(catalog = "cat", work_schema = "wrk"),
         envir = globalenv())

  fake("tableName")
  dropped <- melp_drop_cell(NULL, cells[[1]], "ndmm_")
  ok(identical(dropped, sort(c("melp_reference_LOT_LONG_FINAL",
                               "melp_reference_MAP_STACKED",
                               "melp_reference_OLD_TABLE_FROM_A_PREVIOUS_BUILD"))),
     "the prefix is emptied - including a table this build no longer writes")
  ok(!any(grepl("ndmm_|xmelp_", seen)),
     "...and nothing outside the cell's own prefix is touched")
  ok(length(seen) == 3L && all(startsWith(seen, "DROP TABLE IF EXISTS cat.wrk.")),
     "...one drop per table, fully qualified")

  # The name column is tableName on Databricks and table_name elsewhere. Taken
  # positionally this would pick whichever column came first and drop nothing.
  seen <- character(0); fake("table_name")
  ok(length(melp_drop_cell(NULL, cells[[1]], "ndmm_")) == 3L,
     "the table-name column is found by name, not by position")
  seen <- character(0); fake("database")
  stops(melp_drop_cell(NULL, cells[[1]], "ndmm_"),
        "a listing with no recognisable name column stops rather than dropping nothing quietly")

  # The guard that keeps this away from the study, on the destructive path too.
  seen <- character(0); fake("tableName")
  stops(melp_drop_cell(NULL, cells[[1]], "melp_reference_"),
        "clearing refuses the study's own prefix, not just building does")
  ok(!length(seen), "...and refuses it before issuing any drop")
  rm("db_q", "db_exec", "lot_config", envir = globalenv())
})
rs <- paste(readLines(file.path(ROOT, "run_aug1_melp.R"), warn = FALSE), collapse = "\n")
# The building half is the runner's; the reading half is melp_report() in
# cells.R, because read_melp_metrics.R runs that half on its own. Checks about
# the reading look at both files, so moving it between them cannot lose one.
rr <- paste(rs, paste(readLines(file.path(ROOT, "R", "cells.R"), warn = FALSE),
                      collapse = "\n"), sep = "\n")
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
# All three or none. Stopping only when the reference fails leaves a run that
# built a reference and one mode looking like a finished experiment, when the
# transplant question has not been looked at at all.
ok(has(rs, "if (!all(built))") && !has(rs, "if (!built[1])"),
   "a cell that did not build stops the run, whichever cell it was")
ok(has(rs, "not a smaller answer"),
   "...and says why, rather than reporting what it managed")
# The same for a cell that built but whose numbers cannot be read.
ok(has(rr, "this is a stop rather than a row"),
   "...as does a cell whose metrics come back empty")

cat("\n-- what is read off the builds --\n")
# Several statements now, one plan each - Spark's optimizer died on the single
# nineteen-subquery one. Joined for the text checks, which are about what the
# set of them selects rather than about any one.
sqls <- melp_metric_sql("F", "A", "r1", "MELP", map_tbl = "M")
sql  <- paste(sqls, collapse = "\n")
ok(all(vapply(names(MELP_METRICS), function(m) has(sql, paste0("AS ", m)), logical(1))),
   paste0("all ", length(MELP_METRICS), " metrics are actually selected"))
# And the other way. A column the query computes and MELP_METRICS does not name
# is read off every build and then reported by nothing - the work is done and
# the answer never reaches the output.
# By the naming rule rather than by position: every metric is n_/median_/pct_,
# and the CTEs alias working columns of their own (EXPO_DT, IS_NEW) which are
# not outputs and never carry those prefixes.
selected <- unique(unlist(regmatches(sql,
  gregexpr("(?<=AS )(n_|median_|pct_)[a-z0-9_]+", sql, perl = TRUE))))
ok(setequal(selected, names(MELP_METRICS)),
   paste0("...and nothing is selected that is never reported (",
          paste(setdiff(selected, names(MELP_METRICS)), collapse = ", "), ")"))
ok(has(sql, "RUN_ID = 'r1'"),
   "the progression rows are this cell's, not whichever run answered first")
# The four melphalan figures are what makes the double-count visible.
ok(has(sql, "AS n_melp_add") && has(sql, "AS n_sct_auto_end"),
   "lines ended by melphalan and by transplant are counted separately")
# Built from MELP_METRICS rather than listed out again. Spelled out, the
# fixture had to be edited every time a metric was added, and until it was,
# melp_compare()'s own "named but not selected" guard fired on the fixture
# instead of on the SQL - a real check failing for a fake reason.
three_cells <- function(...) {
  d <- as.data.frame(as.list(stats::setNames(
         rep(list(c(1, 1, 1)), length(MELP_METRICS)), names(MELP_METRICS))),
       stringsAsFactors = FALSE)
  d <- cbind(cell = c("reference", "as_asked", "yield_to_sct"), d,
             stringsAsFactors = FALSE)
  v <- list(...)
  for (nm in names(v)) d[[nm]] <- v[[nm]]
  d
}
cmp <- melp_compare(three_cells(n_lines = c(1000, 1100, 1050),
                                n_melp_add = c(30, 45, 38)))
ok(identical(cmp$change[cmp$cell == "as_asked" & cmp$metric == "n_lines"], 100),
   "a cell is reported as its difference from the reference")
ok(nrow(cmp) == 2L * length(MELP_METRICS),
   "...for every metric and every cell, so nothing is quietly dropped")
# A metric named in MELP_METRICS but not selected by the SQL is named as such,
# rather than failing deep in the arithmetic several lines from the cause.
stops(melp_compare(data.frame(cell = c("reference", "as_asked"),
                              n_lines = c(1000, 1100), stringsAsFactors = FALSE)),
      "a metric the SQL does not select is named, not a crash in the arithmetic")
ap <- melp_modes_apart(three_cells(n_lines = c(1000, 1100, 1050),
                                   n_melp_add = c(30, 45, 38)))
ok(!is.null(ap) && identical(ap$difference[ap$metric == "n_melp_add"], 7),
   "the two readings are also compared with each other, which is the open question")

cat("\n-- the three cells have to have seen the same world --\n")
# A table name is not a cohort attempt. Re-running the cohort build under the
# same prefix replaces NDMM_COHORT in place, so a reference over attempt A and
# two cells over attempt B all complete and the A-to-B difference is reported as
# the effect of melphalan. LOT records the attempt, the code and the code lists;
# this reads them back rather than trusting three sequential builds.
row <- function(...) { d <- list(...); as.data.frame(d, stringsAsFactors = FALSE) }
same <- function() list(
  reference    = row(COHORT_RUN_ID = "c1", COHORT_STAMP = "s1", STUDY_START = "2016-01-01",
                     STUDY_END = "2026-03-31", CODE_MD5 = "m", CODELIST_MD5 = "k",
                     CONTRACT_DEVIATIONS = NA_character_),
  as_asked     = row(COHORT_RUN_ID = "c1", COHORT_STAMP = "s1", STUDY_START = "2016-01-01",
                     STUDY_END = "2026-03-31", CODE_MD5 = "m", CODELIST_MD5 = "k",
                     CONTRACT_DEVIATIONS = "apply_melp_rule=as_asked (contract )"),
  yield_to_sct = row(COHORT_RUN_ID = "c1", COHORT_STAMP = "s1", STUDY_START = "2016-01-01",
                     STUDY_END = "2026-03-31", CODE_MD5 = "m", CODELIST_MD5 = "k",
                     CONTRACT_DEVIATIONS = "apply_melp_rule=yield_to_sct (contract )"))
runs(melp_check_inputs(same()), "three cells over one cohort attempt are comparable")
# Every column the query names has to be a column the build actually writes.
# CONTRACT_DEVIATIONS is in LOT_BUILD_STATUS and not in LOT_RUN_METADATA, and
# selecting it from the metadata table failed the whole query - which tryCatch
# then reported as "no metadata row", sending the reader to look for a row that
# was there. Checked against build_lot.R's own declarations rather than a list
# repeated here, so a column moving between the two tables is caught.
bl <- paste(readLines(file.path(LOT, "R", "build_lot.R"), warn = FALSE), collapse = "\n")
cols_of <- function(decl) {
  blk <- regmatches(bl, regexpr(paste0(decl, "\\s*<-\\s*c\\((?s).*?\\n\\n"), bl, perl = TRUE))
  unique(unlist(regmatches(blk, gregexpr("[A-Z][A-Z0-9_]+(?=\\s*=\\s*\")", blk, perl = TRUE))))
}
meta_cols   <- cols_of("FINAL_METADATA_COLS")
# RUN_ID is not in that vector - the metadata table is created with its settings
# columns elsewhere - so it is taken from build_lot.R filtering the table on it,
# which is the same evidence rather than a name written down here.
if (grepl("FROM {meta_tbl} WHERE RUN_ID =", bl, fixed = TRUE))
  meta_cols <- c(meta_cols, "RUN_ID")
status_cols <- cols_of("BUILD_STATUS_COLS")
cl_cols     <- cols_of("CODELIST_METADATA_COLS")
ok(length(meta_cols) && length(status_cols) && length(cl_cols),
   "the build's column declarations can be read, so this check means something")
ok("CONTRACT_DEVIATIONS" %in% status_cols && !("CONTRACT_DEVIATIONS" %in% meta_cols),
   "CONTRACT_DEVIATIONS is the status row's column, not the metadata row's")
isql <- melp_inputs_sql("META", "CL", "ST", "r1")
named <- function(alias) unique(unlist(regmatches(isql, gregexpr(
  paste0("(?<=", alias, "\\.)[A-Z][A-Z0-9_]+"), isql, perl = TRUE))))
ok(all(named("m") %in% meta_cols),
   paste0("every column read off LOT_RUN_METADATA is one it has (",
          paste(setdiff(named("m"), meta_cols), collapse = ", "), ")"))
ok(all(named("s") %in% status_cols),
   paste0("every column read off LOT_BUILD_STATUS is one it has (",
          paste(setdiff(named("s"), status_cols), collapse = ", "), ")"))
ok(all(named("c") %in% cl_cols),
   paste0("every column read off LOT_CODELIST_METADATA is one it has (",
          paste(setdiff(named("c"), cl_cols), collapse = ", "), ")"))
ok(has(rr, "Could not read what ") && has(rr, "conditionMessage(r)"),
   "a query that failed is reported as itself, not as a missing row")
for (f in c("COHORT_RUN_ID", "COHORT_STAMP", "STUDY_END", "CODE_MD5", "CODELIST_MD5")) {
  r <- same(); r$as_asked[[f]] <- "other"
  stops(melp_check_inputs(r), paste0("...and a cell with a different ", f, " is refused"))
}
# The cohort attempt is the one that is easy to miss: the run id can be the same
# across a re-run, so the stamp is checked too.
r <- same(); r$yield_to_sct$COHORT_STAMP <- "s2"
msg <- tryCatch(melp_check_inputs(r), error = conditionMessage)
ok(grepl("COHORT_STAMP", msg, fixed = TRUE) && grepl("yield_to_sct", msg, fixed = TRUE),
   "...naming the field and the cell, so it can be fixed in one go")
r <- same(); for (n in names(r)) r[[n]]$COHORT_RUN_ID <- NA_character_
stops(melp_check_inputs(r),
      "a field no cell recorded is refused, not treated as agreement")

cat("\n-- and each cell has to be the algorithm it says it is --\n")
runs(melp_check_deviations(same(), melp_cell_plan()),
     "the reference deviates on nothing and each mode records the rule")
r <- same(); r$reference$CONTRACT_DEVIATIONS <- "max_lot=8 (contract 5)"
stops(melp_check_deviations(r, melp_cell_plan()),
      "a reference that deviates is refused - it is not the contract build")
r <- same(); r$as_asked$CONTRACT_DEVIATIONS <- NA_character_
stops(melp_check_deviations(r, melp_cell_plan()),
      "...and a mode cell that recorded no melphalan deviation did not build the rule")
# The mode has to be the one that cell is for. Two cells that both built
# as_asked would compare a build against itself and report no difference as the
# answer to the transplant question.
r <- same(); r$yield_to_sct$CONTRACT_DEVIATIONS <- "apply_melp_rule=as_asked (contract )"
stops(melp_check_deviations(r, melp_cell_plan()),
      "a cell that built the other mode is refused, not read as its own")
# And nothing else may have moved. The cells are three separate processes, so a
# second setting reaching one of them would be reported as the rule's effect.
r <- same()
r$as_asked$CONTRACT_DEVIATIONS <- "apply_melp_rule=as_asked (contract )|max_lot=8 (contract 5)"
msg <- tryCatch(melp_check_deviations(r, melp_cell_plan()), error = conditionMessage)
ok(grepl("other than the rule", msg, fixed = TRUE) && grepl("max_lot", msg, fixed = TRUE),
   "...and a cell that changed a second setting is named for that setting")
# Matched inside its own entry: a mode name appearing in some other deviation's
# text must not stand in for the melphalan one.
r <- same(); r$as_asked$CONTRACT_DEVIATIONS <- "codelist_dir=/x/as_asked (contract /mnt/code/codelist)"
stops(melp_check_deviations(r, melp_cell_plan()),
      "...and the mode is read from the melphalan entry, not from anywhere in the string")

cat("\n-- the modes are compared patient by patient, not only in totals --\n")
# Subtracting totals does not answer "how many patients does this move". The
# SCT rule may win the end-reason priority anyway, one boundary can shift
# several later lines, and two patients moving opposite ways cancel.
ps <- melp_modes_patients_sql("A", "Y")
ok(has(ps, "FULL OUTER JOIN"),
   "a patient in one build and not the other is counted, not dropped")
ok(has(ps, "LOT_START_DT") && has(ps, "LOT_BASE_END_DT") && has(ps, "LOT_BASE_END_REASON"),
   "a patient differs if any line's start, end or end reason differs")
ok(has(ps, "AS N_SAME_COUNT_DIFFERENT_LINES"),
   "...and the same-count-different-lines case is counted, which totals hide")
ok(has(ps, "<=>"),
   "the comparison is null-safe, or a patient in one build reads as no difference")
ok(has(rr, "downstream consequence") && has(rr, "not a count of the"),
   "the aggregate delta is described as a consequence, not as the overlap count")
# The tables it compares come from the plan. AUG1_PREFIX_BASE moves every cell,
# so a literal "melp_as_asked_" reads nothing under a custom base - or reads a
# previous experiment's leftovers and reports them as this run's.
ok(!has(rr, '"melp_as_asked_"') && !has(rr, '"melp_yield_to_sct_"'),
   "the patient comparison names no prefix of its own")
ok(has(rr, 'pfx_of("as_asked")') && has(rr, 'pfx_of("yield_to_sct")'),
   "...it takes both from the cell plan, so a custom prefix base is honoured")
ok(has(rr, "rather than an output left out"),
   "...and a comparison that could not be made stops the run rather than being skipped")

cat("\n-- B.2 removes a boundary; it does not hold the line open --\n")
# The rule as written says both doses stay in the current line. Suppression
# cannot deliver that: a line's discontinuation is its base agents' last cover,
# and a melphalan first seen outside induction is not one of them. So where the
# regimen runs out between the two doses, the line ends there and the second
# dose starts the next one. Making melphalan a member of a regimen whose
# induction window it never entered is a clinical decision, not an
# implementation one - so it is recorded as open, and counted.
ok(has(sql, "AS n_b2_line_starts"),
   "the lines that decision governs are counted, not left to be argued about")
# All four conditions, because any one alone lets in lines with no B.2 pair -
# a line DARA started, with melphalan merely joining its induction window,
# satisfies "starts after a runout and has melphalan in the regimen".
ok(has(sql, "x.PREV_REASON = 'DISCONTINUATION'"),
   "...the previous line ended by running out")
ok(has(sql, "e.EXPO_DT = x.LOT_START_DT"),
   "...the line starts on a melphalan exposure")
# Landing on the start date is not enough. The same-day tie-break in
# 10_lot2_5_base.R is SCT_ALLO > CART > SCT_AUTO > MED, so an AUTO coded on the
# melphalan date takes the start type - and that line is the transplant's.
ok(has(sql, "x.LOT_START_TYPE = 'MED'"),
   "...and melphalan started it, not a procedure coded on the same day")
tie <- sf("10_lot2_5_base.R")
# The ordering itself, not the sentence around it, so tidying the comment
# cannot silently stop this from being checked.
ok(grepl("SCT_ALLO > CART > SCT_AUTO > MED", tie, fixed = TRUE),
   "...which is the tie-break the engine documents, not an assumption here")
ok(has(sql, "e.PREV_EXPO_DT >= x.PREV_START_DT") &&
     has(sql, "e.PREV_EXPO_DT <  x.LOT_START_DT"),
   "...with the exposure before it inside the previous line")
ok(has(sql, "datediff(e.PREV_EXPO_DT, x.PREV_START_DT) >"),
   "...outside that line's own induction window, which makes it B and not A")
ok(has(sql, "BETWEEN 60 AND 179"),
   "...and the pair 60-179 days apart, which is B.2 and not B.1 or B.3")
# The pair has to be the one the engine judged. The engine uses lead() over the
# ordered exposures, so it judges consecutive pairs only. Joining to any earlier
# exposure in range counts pairs it never looked at: exposures on days 100, 160
# and 250 give it 100-160 and 160-250, and a range join would also match
# 100-250, reporting one line twice.
ok(has(sql, "lag(EXPO_DT) OVER (PARTITION BY PATID ORDER BY EXPO_DT) AS PREV_EXPO_DT"),
   "the pair is the consecutive one, carried on the exposure itself")
# LOT_START_TYPE = 'MED' says a medication won the tie-break, not which one:
# d_MED is the earliest qualifying non-steroid agent and the engine does not
# keep the drug. So a line DARA also started on that date exists under either
# B.2 reading, and only the subset with no other starter is evidence.
ok(has(sql, "AS n_b2_melp_only"),
   "the counterfactual subset is counted separately from the coincident starts")
ok(has(sql, "AND upper(trim(o.MAP_MED_TYPE)) <> 'MELP'") &&
     has(sql, "o.MAP_START_DT = x.LOT_START_DT") &&
     has(sql, "o.MAP_MED_CLASS <> 'STEROID'"),
   "...excluding a line another non-steroid agent starts on the same date")
ok(has(sql, "NOT EXISTS"),
   "...as an exclusion, so the subset is of the same population")
# One join to mx per count, so neither can match a line against two earlier
# exposures. Counted against the number of counts rather than a fixed 1, since
# the counterfactual subset is a second subquery of the same shape.
ok(length(gregexpr("INNER JOIN mx", sql)[[1]]) ==
     length(gregexpr("AS n_b2", sql)[[1]]) && !has(sql, "INNER JOIN mx e1"),
   "...by one join each, so a line cannot match two earlier exposures and count twice")
# The exposures are chained the way the engine chains them, or the count is
# about a different set of exposures than the rule acted on.
ok(has(sql, "< 30 THEN 0 ELSE 1 END AS IS_NEW"),
   "...over exposures merged on the same threshold the rule uses")
# Both variants have to be well-formed, not just the one the runner uses. The
# no-MAP fallback is two conditional slots in one projection, and getting the
# arity wrong there emits an alias with nothing in front of it - which parses
# nowhere and would only be found by running it.
for (v in list(list("no MAP",   paste(melp_metric_sql("F", "A", "r1", "MELP"), collapse = "\n")),
               list("with MAP", paste(melp_metric_sql("F", "A", "r1", "MELP", map_tbl = "M"), collapse = "\n")))) {
  ok(!grepl(",\\s*AS [a-z]", v[[2]]),
     paste0(v[[1]], ": no alias is left with no expression in front of it"))
  ok(!grepl("^\\s*AS [a-z]", v[[2]], perl = TRUE) &&
       !grepl("\\n\\s*\\n\\s*AS [a-z]", v[[2]], perl = TRUE),
     paste0("...", v[[1]], ": nor one separated from its expression by a blank line"))
  ok(length(gregexpr("AS n_b2", v[[2]])[[1]]) == 2L,
     paste0("...", v[[1]], ": and both B.2 columns are aliased once each"))
}
ok(has(paste(melp_metric_sql("F", "A", "r1", "MELP"), collapse = "\n"), "cast(NULL as bigint)"),
   "with no MAP table to read, the B.2 columns are NULL rather than wrong")
mrs <- paste(readLines(file.path(LOT, "R", "melp_rule.R"), warn = FALSE), collapse = "\n")
# The request asks for two things at B.2 and suppression is only one of them,
# so the file has to name the other where it does the suppressing - and the
# hold has to actually be there. This used to check the opposite: that the file
# admitted it did NOT hold the line, and pointed at open question 6.
ok(has(mrs, "melp_hold carries the line to it") &&
     has(mrs, "melp_hold AS (") && !grepl("[Oo]pen question 6", mrs),
   "...and the rule names the hold where it suppresses, the question being settled")
# The proposal, the open questions and the two readings are in lot/FILES.md,
# under this package's own entry. Not in lot/LOT_RULES.md: that document is the
# rules the build applies, and this is not one of them - it is off in CONTRACT
# and every cell that turns it on is a recorded deviation.
doc <- paste(readLines(file.path(PARENT, "FILES.md"), warn = FALSE),
             collapse = "\n")
ok(grepl("^6\\.", doc, perl = TRUE) || has(doc, "\n6. In B.2"),
   "...and it is on the study team's list with the other five")
ok(has(doc, "n_b2_line_starts"),
   "...pointing at the number that settles it")
# The count is the group the reading decides: a line melphalan started straight
# after the previous one ran out, rather than every melphalan line.
ok(!has(sql, "w.LOT_START_TYPE = 'MED'"),
   "and it does not settle for start-type MED, which any drug can produce")
ok(!has(doc, "both doses stay in the current line - which is what this builds"),
   "the folder documentation does not claim the reading the code does not implement")
ok(has(doc, "It does not hold the line open"),
   "...it says which of the two readings is built")
# And nothing anywhere may claim to be the whole rule. Neither mode is: the
# names are about the TRANSPLANT reading, and on B.2 both take the narrow one.
# This was the label the detailed section already contradicted.
claims <- function(x) grepl("(exactly|precisely) as (written|asked)", x, ignore.case = TRUE)
ok(!any(vapply(MELP_CELLS, function(c_i) claims(c_i$what), logical(1))),
   "no cell describes itself as the rule exactly as written")
ok(!claims(doc) && !claims(rs),
   "...nor does the folder documentation or the runner")
ok(exists("MELP_B2_READING") && has(MELP_B2_READING, "carried to the"),
   "the B.2 reading is stated as a value, so the plan can print it")
ok(has(rs, "MELP_B2_READING"),
   "...and the plan does print it, before anyone commits three builds")

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

cat("\n-- the study team's worked scenarios land where they drew them --\n")
# The four patients that came with the restated ask, as data rather than as a
# reading of a picture. They are the only statement of the rule that names
# dates, and one of them found a branch the other three cannot reach: the later
# dose of a B.2 pair, when it is the patient's last exposure, was judged by
# nothing and started a line the rule says is absent. Three of these passing is
# what that defect looked like, so the count matters as much as the verdict.
source(file.path(ROOT, "R", "scenarios.R"))
ok(length(MELP_SCENARIOS) == 4L,
   paste0("all four scenarios are here (", length(MELP_SCENARIOS), ")"))
for (sc in MELP_SCENARIOS) {
  r <- melp_scenario_run(ask, sc)
  ok(identical(as.numeric(r$starts), as.numeric(sc$starts)),
     paste0(sc$id, ": new line at ",
            if (length(r$starts)) paste(r$starts, collapse = ", ") else "none",
            " - drawn as ",
            if (length(sc$starts)) paste(sc$starts, collapse = ", ") else "none"))
}
# The one that isolates it, held by name: if the later dose of that pair ever
# stops being suppressed, this is the assertion that says so.
e1 <- Filter(function(s) identical(s$id, "example_1"), MELP_SCENARIOS)[[1]]
r1 <- melp_scenario_run(ask, e1)
ok(all(e1$doses %in% r1$suppress),
   "example 1: both doses of the B.2 pair have their boundary removed, not just the first")
# And the settings the scenarios are judged against are the shipped ones, or
# the branches move and the agreement above means nothing.
sc_cfg <- utils::read.csv(file.path(LOT, "config.csv"), stringsAsFactors = FALSE,
                          comment.char = "#")
val <- function(nm) as.integer(trimws(sc_cfg[[2]][trimws(sc_cfg[[1]]) == nm][1]))
ok(val("MELP_EXPOSURE_DAYS") == ask$melp_exposure_days &&
     val("MELP_RESTART_DAYS") == ask$melp_restart_days &&
     val("MELP_ADVANCE_DAYS") == ask$melp_advance_days,
   "...against the thresholds the engine actually ships")


cat("\n-- the mixed-yield case, pinned because it is not decided --\n")
# yield_to_sct is optional and off by default, so nothing below touches a
# contract run. What it pins is a behaviour nobody has chosen.
#
# An arm acting on EXPO_DT asks YIELD_THIS; an arm acting on NEXT_DT asks BOTH.
# So a pair whose FIRST dose sat beside a transplant and whose second did not
# is not advanced at the second - the first dose's flag suppresses a boundary
# that would fall on the second. Read as "yielding looks at whichever exposure
# the boundary falls on", it would advance. Read as "a yielded exposure is not
# judged, so the pair it heads is not this rule's", it does not.
#
# Neither reading is implemented by accident and neither has been chosen. None
# of the four worked scenarios carries a coded transplant, so none of them can
# tell the two apart. This pins what the build does today, so that answering
# the question is a visible change to a test rather than a silent one.
melp <- paste(readLines(file.path(ROOT, "..", "..", "lot", "engine", "R", "melp_rule.R"),
                        warn = FALSE), collapse = "\n")
inj <- sub("(?s).*melp_inject AS \\(", "", melp, perl = TRUE)
inj <- sub("(?s)UNION.*", "", inj, perl = TRUE)
ok(grepl("YIELD_THIS = 0 AND YIELD_NEXT = 0", inj, fixed = TRUE),
   "the later-dose inject arm requires BOTH yield flags, not only the later one")
ok(grepl("UNRESOLVED", melp, fixed = TRUE),
   "...and the file says so, rather than reading as a settled rule")
# The scenarios cannot speak to it, and say so rather than appearing to cover it.
sc <- paste(readLines(file.path(ROOT, "R", "scenarios.R"), warn = FALSE),
            collapse = "\n")
ok(grepl("YIELD_THIS <- 0L", sc, fixed = TRUE) &&
     grepl("YIELD_NEXT <- 0L", sc, fixed = TRUE),
   "the worked scenarios hold both flags at zero, so none of them distinguishes them")
ok(grepl("No coded transplant in any scenario", sc, fixed = TRUE),
   "...and that is stated in the scenarios rather than left to be noticed")

cat("\n", strrep("-", 52), "\n", sep = "")
cat(sprintf("%d passed, %d failed\n", pass, fail))
if (fail > 0L) quit(status = 1L)
