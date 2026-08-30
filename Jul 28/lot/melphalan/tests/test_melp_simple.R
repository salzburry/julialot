#!/usr/bin/env Rscript
# The melphalan rule as an engine rule, and the two cells that measure it.
# No warehouse: the SQL is built as a string and checked.
#
#   Rscript "lot/melphalan/tests/test_melp_simple.R"
#
# This replaces test_aug1_melp.R, which was the suite for the five-branch rule
# the study did not adopt. What is kept from it is everything that was really
# about melp_rule.R rather than about that rule: the off-path hooks, the
# newline discipline every spliced fragment needs, and the cell machinery's
# refusal to write over the study's own tables.

ROOT   <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                                 fixed = TRUE))) else getwd()
  dirname(d)
})
# This package sits beside the engine in lot/, so the engine is one hop up.
LOT <- file.path(dirname(ROOT), "engine")

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
            melp_simple_course_days = 28L, map_discon_gap_days = 90L)
off <- modifyList(CFG, list(apply_melp_rule = "off"))
on  <- modifyList(CFG, list(apply_melp_rule = "simplified"))

cat("\n-- off is not a setting, it is the absence of the rule --\n")
# The whole safety of putting this in the engine rests here. Every hook has to
# emit nothing, or the contract build is not the build that was validated.
ok(identical(melp_lot1_ctes(off), ""), "LOT1 gets no extra CTEs")
ok(identical(melp_lot1_base_from(off), "lot1_base lb"),
   "...and reads lot1_base exactly as the source does")
ok(identical(melp_lotn_ctes(off, 2, 30L, 45L, "single_day"), ""), "LOT2-5 gets none either")
ok(identical(melp_suppress_predicate(off), ""), "no predicate is added to the candidates")
ok(identical(melp_inject_arm(off, "t", "c", "e"), ""), "and no rows are added to them")
ok(identical(melp_short_course_ctes(off, "l", "s", "e"), ""), "no short-course CTEs")
ok(identical(melp_boundary_join(off), "") &&
     identical(melp_boundary_break_pred(off), ""),
   "...and nothing narrows the run-out chain's interrupt scan")
ok(!melp_rule_on(off) && melp_rule_on(on),
   "on and off are decided by the setting, not by a caller passing a flag")
stops(melp_rule_mode(list(apply_melp_rule = "sometimes")),
      "an unrecognised value stops rather than behaving like the rule is on")
# The two retired modes must not quietly still work. They named a whole
# algorithm, so a build asking for one has to fail loudly rather than get the
# short-course rule under a name that meant something else.
stops(melp_rule_mode(list(apply_melp_rule = "as_asked")),
      "as_asked is gone, and asking for it stops the build")
stops(melp_rule_mode(list(apply_melp_rule = "yield_to_sct")),
      "...and so is yield_to_sct")

# Where the hooks are, and that there are no others.
sf <- function(f) paste(readLines(file.path(LOT, "R", "steps", f), warn = FALSE),
                        collapse = "\n")
ok(has(sf("06_lot1_end.R"), "FROM {melp_lot1_base_from(cfg)}") &&
     has(sf("06_lot1_end.R"), "WITH{melp_lot1_ctes(cfg)}"),
   "LOT1 has exactly two decision hooks, both in 06")
# 04 carries three, and none is a decision: the short-course CTE, and the
# anti-join and predicate that read it, keep melphalan out of the run-out
# chain's interrupt scan. All three read map_stacked and the line's start,
# which 04 already has. The DECISION cannot live here - it reads lot1_base,
# which is what 04 builds.
ok(has(sf("04_lot1_base.R"), "melp_short_course_ctes(cfg, 'lot1_regimen_cutoff'") &&
     has(sf("04_lot1_base.R"), "boundary_join = melp_boundary_join(cfg)") &&
     has(sf("04_lot1_base.R"), "boundary_break_pred = melp_boundary_break_pred(cfg)"),
   "...and 04 carries only the short-course gate, which needs no line decision")
ok(has(sf("10_lot2_5_base.R"), "{melp_lotn_ctes(cfg, lot_num, induction_window_days,") &&
     has(sf("10_lot2_5_base.R"), "{melp_suppress_predicate(cfg)}") &&
     has(sf("10_lot2_5_base.R"), "melp_inject_arm(cfg"),
   "LOT2-5 has its three, in the step that builds the line")

cat("\n-- and every fragment opens with its own newline --\n")
# Each one splices straight after a {} in the step template, and glue() trims a
# template's leading blank line - so a fragment that does not open with one
# welds onto the text before it.
#
# Not a formatting nit. A fragment without its own newline produces
#   AND i.INJECT_DT <= lot2_start.OBS_END_DTAND lot2_start.LOT2_START_TYPE ...
# which parses as an identifier OBS_END_DTAND followed by a table name, and
# kills the build in Spark. The off-path tests above cannot catch it: off emits
# nothing, and nothing is what they check.
FRAGMENTS <- list(
  melp_lot1_ctes           = list(on),
  melp_lotn_ctes           = list(on, 2, 30L, 45L, "single_day"),
  melp_suppress_predicate  = list(on),
  melp_short_course_ctes   = list(on, "l", "s", "e"),
  melp_boundary_join       = list(on),
  melp_boundary_break_pred = list(on),
  melp_inject_arm          = list(on, "lot2_start", "LOT2_START_DT",
                                  "lot2_start.OBS_END_DT"),
  melp_allo_guard          = list(2L, "single_day"))
for (nm in names(FRAGMENTS)) {
  v <- as.character(do.call(nm, FRAGMENTS[[nm]]))
  ok(nzchar(v) && startsWith(v, "\n"),
     paste0(nm, "() emits something and opens it with a newline"))
}
arm <- melp_inject_arm(on, "lot2_start", "LOT2_START_DT", "lot2_start.OBS_END_DT",
                       melp_allo_guard(2L, "single_day"))
ok(has(arm, "<= lot2_start.OBS_END_DT\n"),
   "the ALLO guard lands on its own line, not onto the column before it")
ok(!has(arm, "OBS_END_DTAND"),
   "...so the text that stopped every build in Spark cannot be produced")

cat("\n-- no correlated subquery reaches a join condition --\n")
# prior_regimen.R says a correlated subquery is not safe here, and Spark before
# 4.0 rejects one in a JOIN's ON clause outright. Both melphalan hooks that
# narrow a scan are anti-joins for that reason, and this holds them to it.
ok(!has(melp_boundary_break_pred(on), "EXISTS") &&
     has(melp_boundary_join(on), "LEFT JOIN melp_no_break"),
   "the short-course gate is an anti-join and a predicate, not an EXISTS")
ok(has(melp_boundary_break_pred(on), "nb2.PATID IS NOT NULL"),
   "...and the predicate reads the joined row rather than re-querying")

cat("\n-- the rule the study adopted --\n")
# A short course outside induction advances nothing on its own; a new agent
# starting inside the course advances it on the MELPHALAN date. Branch
# behaviour on real patients is proved end to end by the repository's
# planted-patient harnesses; these pin the shape of the SQL.
ok(identical(MELP_RULE_MODES, "simplified"),
   "one rule is left, and it is the one that was adopted")
stops(melp_decision_ctes(on, "L", "S", "E", "L.IND_END"),
      "it refuses a caller that hands in no base set or restart flags")
ss <- melp_decision_ctes(on, "L", "S", "E", "L.IND_END",
                         base_tbl = "bm", restart_tbl = "mr")
cutcte <- function(txt, cte) {
  i <- regexpr(paste0(cte, " AS \\("), txt)
  gsub("\\s+", " ",
       sub("(?s)\\).*$", "", substr(txt, i + attr(i, "match.length"), nchar(txt)),
           perl = TRUE))
}
ok(has(cutcte(ss, "melp_suppress"), "INSIDE = 0 AND SHORT = 1 AND CONFIRMED = 0"),
   "suppressed: outside induction, short, and nothing new started in the course")
ok(has(cutcte(ss, "melp_inject"), "INSIDE = 0 AND SHORT = 1 AND CONFIRMED = 1") &&
     has(cutcte(ss, "melp_inject"), "EXPO_DT AS INJECT_DT"),
   "injected: the confirmed course advances on ITS first day, not the agent's")
ok(has(ss, "<= 28") && !has(ss, "<= 30"),
   "the cap is the setting handed in, not a number written twice")
ok(has(ss, "MAP_MED_CLASS <> 'STEROID'") &&
     has(ss, "coalesce(cr.PREV_DISCON, 0) = 1 AND cb.SUBSTITUTE_ONLY = 0"),
   "a confirming agent passes the same candidate gate the engine applies")
ok(has(ss, "melp_suppress_dates") && has(ss, "melp_hold"),
   "...and the suppress-dates and hold CTEs keep their names, so every splice holds")
ok(has(cutcte(ss, "melp_hold"), "COURSE_END_DT"),
   paste0("the line owns the suppressed course's FULL cover, not just its ",
          "first day - the same clock the short test reads"))
ok(has(melp_prev_line_ctes(on, 30L, 45L), "melp_sc_base"),
   "the start-candidates splice builds its own base set")

cat("\n-- the two cells that measure it --\n")
cells <- melp_cell_plan()
ok(length(cells) == 2L, "two builds: the study's, and one without the rule")
ok(identical(cells[[2]]$id, "simplified") && is.na(cells[[2]]$mode),
   "the cell carrying the rule IS the contract build, so it deviates from nothing")
# Since the study adopted the rule, the cell WITHOUT it is the deviating one.
# A cell asking for no rule has to say the word: load_inputs.R fills an empty
# variable from config.csv, which carries the contract value, so a blank
# APPLY_MELP_RULE would build the contract and the package would compare it
# with itself.
ok(identical(cells[[1]]$mode, "off") && identical(cells[[1]]$melp, "off"),
   "...and the rule-off cell names the word rather than asking with a blank")
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
})

cat("\n-- the runner builds under its own prefixes --\n")
rs <- paste(readLines(file.path(ROOT, "run_melp_simple.R"), warn = FALSE),
            collapse = "\n")
ok(has(rs, 'melp_cell_plan(MELP_SIMPLE_CELLS, "melp_simple_")'),
   "the package builds under melp_simple_ prefixes, not the study's")
ok(has(rs, '"MELP_SIMPLE_COURSE_DAYS=28"') &&
     !has(rs, 'allowed = "melp_simple_course_days"'),
   "both cells carry the contract's 28-day cap - the package does not vary it")
ok(!has(rs, 'env, "APPLY_MELP_RULE="') &&
     has(rs, 'paste0("APPLY_MELP_RULE=", c_i$melp)'),
   "neither cell asks for the rule off with an empty value")
ok(has(rs, "melp_status_unchanged") && has(rs, "melp_check_code") &&
     has(rs, "melp_read_inputs"),
   "the read carries the package's run-ownership checks")

cat("\n", strrep("-", 52), "\n", sep = "")
cat(sprintf("%d passed, %d failed\n", pass, fail))
if (fail > 0L) quit(status = 1L)
