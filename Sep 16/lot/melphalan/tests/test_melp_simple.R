#!/usr/bin/env Rscript
# The melphalan rule as an engine rule, and the two cells that measure it.
# No warehouse: the SQL is built as a string and checked.
#
#   Rscript "lot/melphalan/tests/test_melp_simple.R"
#
# What is covered: the off-path hooks, the newline discipline every spliced
# fragment needs, and the cell machinery's refusal to write over the study's
# own tables.

ROOT   <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                                 fixed = TRUE))) else getwd()
  dirname(d)
})
# This package sits beside the engine in lot/, so the engine is one hop up.
LOT <- file.path(dirname(ROOT), "engine")

pass <- 0L; fail <- 0L

# Coverage this run did NOT get. A suite whose executed blocks were skipped -
# no duckdb, no sqlglot, no python3 - has tested a fraction of what it claims,
# and reporting "0 failed" for it reads as a clean run. Each skip is counted
# and named, and an incomplete run exits non-zero unless the caller says it
# expected one (ALLOW_SKIPPED_TESTS=TRUE).
skipped <- 0L
# The reason is kept, not just counted. test_report_status() replays these at
# the end instead of guessing at a remedy - see there for what that cost.
skip_reasons <- character(0)
skip_note <- function(what) {
  skipped <<- skipped + 1L
  skip_reasons <<- c(skip_reasons, what)
  cat("  SKIP   ", what, "\n")   # skip_note's own print, not a bare one
}

# The tally is only as good as its wiring: a bare cat("SKIP ...") prints like a
# skip and counts as nothing, which is exactly how the first pass at this went
# wrong - eight sites in one suite and six in another were missed by hand. Each
# suite now checks its OWN source, so a skip site added later is caught by the
# suite it was added to rather than by whoever next reads the diff.
.suite_path <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  # The same "~+~" unescape. check_skip_wiring() reads THIS file, and without
  # it the path named no file, the check returned quietly, and the guard on
  # every suite's skip wiring was off on any checkout whose path has a space.
  if (length(a)) normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]), fixed = TRUE),
                               mustWork = FALSE) else NA_character_
})
check_skip_wiring <- function(path = .suite_path) {
  # Not run as a script - sourced, or started some way that gives no --file= -
  # so there is no path to read this suite's own source from. That is coverage
  # this run did not get rather than a pass, so it is counted.
  if (is.na(path))
    return(skip_note(paste0("this suite's own source could not be located, ",
                            "so its skip wiring is unchecked")))
  # A path that names no file is different: the suite worked out where it lives
  # and got it wrong, which is a defect in this file rather than a missing
  # capability. It returned quietly before, and two suites that resolved their
  # path AFTER a setwd() spent every run with this guard off - silently, and
  # under exactly the invocation the runbook documents.
  ok(file.exists(path),
     paste0("this suite can find its own source, so its skip wiring is checked",
            if (!file.exists(path)) paste0(" [", path, " is not a file]") else ""))
  if (!file.exists(path)) return(invisible(NULL))
  src <- readLines(path, warn = FALSE)
  # SKIP as a word, so a line that merely NAMES the ALLOW_SKIPPED_TESTS
  # variable is not read as a skip this suite printed. It is, spelt without
  # the lookahead - which is how the first run of this after the reporting
  # changed flagged the sentence that tells you how to accept a skip.
  bad <- grep('cat\\(.*"[^"]*SKIP(?![A-Za-z_])', src, perl = TRUE)
  # Not a comment describing one, and not skip_note's own printing line.
  bad <- bad[!grepl("^\\s*#", src[bad]) & !grepl("skip_note", src[bad], fixed = TRUE)]
  ok(length(bad) == 0L,
     paste0("every SKIP this suite prints goes through skip_note(), so it is counted",
            if (length(bad)) paste0(" [bare cat at line(s) ", paste(bad, collapse = ", "), "]") else ""))
}
test_report_status <- function(pass, fail, skipped) {
  cat(sprintf("%d passed, %d failed, %d skipped\n", pass, fail, skipped))
  if (skipped > 0L) {
    # What actually skipped, in its own words. This used to print the same
    # sentence in every suite - "Install duckdb and sqlglot" - whatever the
    # block had skipped for. On the dashboard suite that named the wrong
    # remedy: the block wanted survival::, both of the named packages were
    # already installed, and the reader was sent to reinstall them.
    cat("  ", skipped, " block(s) did not run, so this is NOT a clean run:\n", sep = "")
    for (r in skip_reasons) cat("    - ", r, "\n", sep = "")
    cat("  Fix those, or set ALLOW_SKIPPED_TESTS=TRUE to accept it.\n")
  }
  allow <- identical(toupper(trimws(Sys.getenv("ALLOW_SKIPPED_TESTS"))), "TRUE")
  if (fail > 0L || (skipped > 0L && !allow)) quit(status = 1L)
}
ok <- function(cond, what) {
  # An assertion that RAISES is a failure, not the end of the run. Without
  # this the first one to error takes the script down and every check after it
  # is simply never made - and the summary line that would have said so is
  # never printed either.
  cond <- tryCatch(cond, error = function(e) {
    what <<- paste0(what, "  [raised: ", conditionMessage(e), "]"); FALSE })
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
ok(identical(melp_short_course_ctes(off, "v"), ""), "no short-course CTEs")
ok(identical(melp_boundary_join(off), "") &&
     identical(melp_boundary_break_pred(off), ""),
   "...and nothing narrows the run-out chain's interrupt scan")
ok(!melp_rule_on(off) && melp_rule_on(on),
   "on and off are decided by the setting, not by a caller passing a flag")
stops(melp_rule_on(list(apply_melp_rule = "sometimes")),
      "an unrecognised value stops rather than behaving like the rule is on")
# The two retired modes must not quietly still work. They named a whole
# algorithm, so a build asking for one has to fail loudly rather than get the
# short-course rule under a name that meant something else.
stops(melp_rule_on(list(apply_melp_rule = "as_asked")),
      "as_asked is gone, and asking for it stops the build")
stops(melp_rule_on(list(apply_melp_rule = "yield_to_sct")),
      "...and so is yield_to_sct")

# Where the hooks are, and that there are no others.
sf <- function(f) paste(readLines(file.path(LOT, "R", "steps", f), warn = FALSE),
                        collapse = "\n")
ok(has(sf("06_lot1_end.R"), "FROM {melp_lot1_base_from(cfg)}") &&
     has(sf("06_lot1_end.R"), "WITH{melp_lot1_ctes(cfg)}"),
   "LOT1 has exactly two decision hooks, both in 06")
# 04 carries the decision as well as the short-course gate. The decision reads
# LOT1_START_DT and OBS_END_DT and nothing else of the line, and both exist a
# statement earlier: lot1_regimen_cutoff has the start, the cohort has the
# observation end. It is the same helper as 06, differing only in where the
# line comes from, so the two statements cannot judge a course differently.
ok(has(sf("04_lot1_base.R"), "melp_lot1_ctes(cfg, line_from =") &&
     has(sf("04_lot1_base.R"), "melp_lot1_verdict_cte(cfg)") &&
     has(sf("04_lot1_base.R"), "melp_short_course_ctes(cfg, 'melp_verdict')") &&
     has(sf("04_lot1_base.R"), "boundary_join = melp_boundary_join(cfg)") &&
     has(sf("04_lot1_base.R"), "boundary_break_pred = melp_boundary_break_pred(cfg)"),
   "...and 04 reads the same verdict 06 does, rather than judging again itself")
ok(has(sf("10_lot2_5_base.R"), "{melp_lotn_ctes(cfg, lot_num, induction_window_days,") &&
     has(sf("10_lot2_5_base.R"), "{melp_suppress_predicate(cfg)}") &&
     has(sf("10_lot2_5_base.R"), "melp_inject_arm(cfg"),
   "LOT2-5 has its three, in the step that builds the line")

cat("\n-- and every fragment opens with its own newline --\n")
# Each one splices straight after a {} in the step template, and glue() trims a
# template's leading blank line, so a fragment that does not open with one
# welds onto the text before it:
#   AND i.INJECT_DT <= lot2_start.OBS_END_DTAND lot2_start.LOT2_START_TYPE ...
# which Spark parses as an identifier OBS_END_DTAND followed by a table name.
# The off-path tests above cannot catch it, since off emits nothing.
FRAGMENTS <- list(
  melp_lot1_ctes           = list(on),
  melp_lotn_ctes           = list(on, 2, 30L, 45L, "single_day"),
  melp_suppress_predicate  = list(on),
  melp_short_course_ctes   = list(on, "melp_verdict"),
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
# starting inside the course advances it on the melphalan date. These
# assertions pin the shape of the SQL.
ok(identical(MELP_RULE_ON, "simplified") && identical(MELP_RULE_OFF, "off"),
   "one rule is left, and APPLY_MELP_RULE is on or off")
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
# Since the study adopted the rule, the cell without it is the deviating one.
# A cell asking for no rule has to say the word: load_inputs.R fills an empty
# variable from config.csv, which carries the contract value, so a blank
# APPLY_MELP_RULE would build the contract and compare it with itself.
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

cat("\n-- what a cell has to be before its numbers are read --\n")
# Every guard in cells.R exists because a comparison can look right and be
# between two different worlds.

# "a=1|b=2" to a named list, splitting on the first = only.
ps <- melp_parse_settings("apply_melp_rule=simplified|melp_med_abbr=MELP")
ok(identical(ps$apply_melp_rule, "simplified") && identical(ps$melp_med_abbr, "MELP"),
   "settings parse back out of the pipe-separated string the build records")
ok(identical(melp_parse_settings("note=a=b")$note, "a=b"),
   "...and a value with an = in it survives, because only the first one splits")
ok(length(melp_parse_settings(NA)) == 0L && length(melp_parse_settings("")) == 0L,
   "...while nothing recorded parses to nothing, rather than to a bad row")

row <- function(...) { d <- list(...); lapply(d, function(x) x) }
inp <- function(cohort = "C1", stamp = "S1", start = "2016-01-01",
                end = "2023-12-31", code = "M1", cl = "L1", dev = NA,
                set = "apply_melp_rule=simplified|melp_med_abbr=MELP") 
  row(COHORT_RUN_ID = cohort, COHORT_STAMP = stamp, STUDY_START = start,
      STUDY_END = end, CODE_MD5 = code, CODELIST_MD5 = cl,
      CONTRACT_DEVIATIONS = dev, CONTRACT_SETTINGS = set)

runs(melp_check_inputs(list(reference = inp(), simplified = inp())),
     "two cells built over the same cohort, code and code lists compare")
stops(melp_check_inputs(list(reference = inp(), simplified = inp(stamp = "S2"))),
      "a cohort re-run between the cells stops the read")
stops(melp_check_inputs(list(reference = inp(code = "M1"),
                             simplified = inp(code = "M2"))),
      "...and so does a cell built by different code")
stops(melp_check_inputs(list(reference = inp(cl = NA), simplified = inp(cl = NA))),
      "a field NEITHER cell recorded is not agreement - there is nothing to compare")

# Which cell deviates flipped when the study adopted the rule, so this is
# checked off each cell's own `mode` rather than off its name.
devs <- function(ref, sim)
  list(reference = inp(dev = ref), simplified = inp(dev = sim))
runs(melp_check_deviations(devs("apply_melp_rule=off (simplified)", NA), MELP_CELLS),
     "the rule-off cell records its deviation and the contract cell records none")
stops(melp_check_deviations(devs("apply_melp_rule=off (simplified)",
                                 "max_lot=3 (5)"), MELP_CELLS),
      "a contract cell that deviates at all is not the contract build")
stops(melp_check_deviations(devs(NA, NA), MELP_CELLS),
      "a cell built without the rule that records no deviation is refused")
stops(melp_check_deviations(devs("apply_melp_rule=as_asked (simplified)", NA), MELP_CELLS),
      "...and one recording a different value for it is not the cell it claims")
stops(melp_check_deviations(devs(paste0("apply_melp_rule=off (simplified)",
                                        "|max_lot=3 (5)"), NA), MELP_CELLS),
      "a cell that changed something ELSE is measuring more than the rule")
# The fold-in package passes its own key. A deviation on apply_melp_rule would
# then be the "something else" this refuses.
stops(melp_check_deviations(devs("apply_melp_rule=off (simplified)", NA),
                            MELP_CELLS, key = "apply_map_foldin"),
      "the setting the cells differ on is the caller's to name")

st <- function(a, b) list(reference = inp(set = a), simplified = inp(set = b))
SET <- paste0("apply_melp_rule=simplified|melp_med_abbr=MELP|",
              "melp_exposure_days=30|induction_window_days=60|",
              "lot_n_induction_window_days=30|cart_consolidation_days=45")
got <- melp_settings(st(sub("simplified", "off", SET), SET))
ok(identical(got$abbr, "MELP") && identical(got$expo_days, 30L) &&
     identical(got$ind1, 60L) && identical(got$indn, 30L) &&
     identical(got$cart, 45L),
   "the windows the numbers are read under come off the cells, as whole numbers")
stops(melp_settings(st("", SET)),
      "a cell that recorded no settings has no record of what it was built under")
stops(melp_settings(st(paste0(SET, "|max_lot=3"), paste0(SET, "|max_lot=5"))),
      "cells differing on a setting no metric reads are still not one experiment")
runs(melp_settings(st(sub("simplified", "off", SET), SET), vary = "apply_melp_rule"),
     "...while the setting they exist to differ on is allowed to differ")
stops(melp_settings(st(sub("melp_exposure_days=30", "melp_exposure_days=30.5", SET),
                       sub("melp_exposure_days=30", "melp_exposure_days=30.5", SET))),
      "a window recorded as 30.5 stops rather than being truncated to 30")
stops(melp_settings(st(sub("melp_exposure_days=30", "melp_exposure_days=3e1", SET),
                       sub("melp_exposure_days=30", "melp_exposure_days=3e1", SET))),
      "...and so does 3e1, which as.integer() would also read as 30")
stops(melp_settings(st(sub("melp_med_abbr=MELP", "melp_med_abbr=ME'LP", SET),
                       sub("melp_med_abbr=MELP", "melp_med_abbr=ME'LP", SET))),
      "an abbreviation with a quote in it is refused, not escaped")
stops(melp_settings(st(sub("\\|cart_consolidation_days=45", "", SET),
                       sub("\\|cart_consolidation_days=45", "", SET))),
      "a cell missing a window this package reads is refused by name")

res <- data.frame(cell = c("reference", "simplified"),
                  stringsAsFactors = FALSE)
for (m in names(MELP_METRICS)) res[[m]] <- c(10, 15)
cmp <- melp_compare(res, MELP_CELLS)
ok(nrow(cmp) == length(MELP_METRICS) &&
     all(cmp$change == 5) && all(cmp$pct_change == 50),
   "each cell is reported against the reference, as a change and a percentage")
ok(!any(cmp$cell == "reference"), "...and the reference is not compared with itself")
res0 <- res; for (m in names(MELP_METRICS)) res0[[m]] <- c(0, 3)
ok(all(is.na(melp_compare(res0, MELP_CELLS)$pct_change)),
   "a percentage off a zero reference is not reported rather than being infinite")
stops(melp_compare(res[, setdiff(names(res), "n_melp_add")], MELP_CELLS),
      "a metric named in MELP_METRICS that no statement selects is named, not silently dropped")
stops(melp_compare(res[res$cell != "reference", , drop = FALSE], MELP_CELLS),
      "and a result set with no reference cell in it stops")

stamped <- melp_stamp(data.frame(x = 1:2), list(reference = inp(), simplified = inp()),
                      list(reference = list(run_id = "R1"),
                           simplified = list(run_id = "R2")))
ok(all(c("COHORT_RUN_ID", "COHORT_STAMP", "CODE_MD5", "LOT_RUN_IDS", "READ_AT")
         %in% names(stamped)) && identical(stamped$LOT_RUN_IDS[1], "R1/R2"),
   "every CSV carries the cohort, the code and both runs it was read from")
ok(is.null(melp_stamp(NULL, list(), list())),
   "...and nothing to stamp is not an error")

ok(identical(melp_out_dir("/tmp/x"), file.path("/tmp/x", "out")),
   "both scripts write beside the script by default")
local({
  old <- Sys.getenv("OUTPUT_DIR", unset = NA)
  Sys.setenv(OUTPUT_DIR = "/tmp/elsewhere")
  ok(identical(melp_out_dir("/tmp/x"), "/tmp/elsewhere"),
     "...and OUTPUT_DIR moves the runner and the recovery read together")
  if (is.na(old)) Sys.unsetenv("OUTPUT_DIR") else Sys.setenv(OUTPUT_DIR = old)
})

# Which run owns a prefix, and whether it moved while it was being read.
local({
  answer <- NULL
  assign("db_q", function(con, sql) answer, envir = globalenv())
  assign("wrk", function(x) x, envir = globalenv())
  cell <- list(id = "reference", prefix = "melp_reference_")

  answer <- data.frame(RUN_ID = "R1", STATE = "complete", UPDATED_AT = "T1",
                       stringsAsFactors = FALSE)
  s1 <- cell_status(NULL, cell)
  ok(identical(s1$run_id, "R1") && identical(s1$updated_at, "T1"),
     "a completed run is the cell, and the read carries which run it was")
  answer <- data.frame(RUN_ID = "R1", STATE = "started", UPDATED_AT = "T1",
                       stringsAsFactors = FALSE)
  stops(cell_status(NULL, cell),
        "a prefix being rebuilt right now is not a cell")
  answer <- data.frame(RUN_ID = "R1", STATE = "failed", UPDATED_AT = "T1",
                       stringsAsFactors = FALSE)
  stops(cell_status(NULL, cell), "...and neither is one a build died in")
  answer <- data.frame(RUN_ID = character(0), STATE = character(0),
                       UPDATED_AT = character(0), stringsAsFactors = FALSE)
  stops(cell_status(NULL, cell), "a prefix nothing has ever built has no numbers")
  assign("db_q", function(con, sql) stop("no such table"), envir = globalenv())
  stops(cell_status(NULL, cell),
        "a status table that cannot be read is reported as that, not as a missing row")

  # And again immediately before anything is written.
  answer <- data.frame(RUN_ID = "R1", STATE = "complete", UPDATED_AT = "T1",
                       stringsAsFactors = FALSE)
  assign("db_q", function(con, sql) answer, envir = globalenv())
  before <- list(reference = cell_status(NULL, cell))
  runs(melp_status_unchanged(NULL, list(cell), before),
       "a cell that did not move while it was read publishes")
  answer <- data.frame(RUN_ID = "R2", STATE = "complete", UPDATED_AT = "T2",
                       stringsAsFactors = FALSE)
  stops(melp_status_unchanged(NULL, list(cell), before),
        "...and one rebuilt underneath the read stops before anything is written")
  answer <- data.frame(RUN_ID = "R1", STATE = "complete", UPDATED_AT = "T2",
                       stringsAsFactors = FALSE)
  stops(melp_status_unchanged(NULL, list(cell), before),
        "...including a re-run that kept the run id and only moved the stamp")

  # One statement failing is the whole read failing: the answer is the
  # comparison, not a best effort at one cell.
  assign("db_q", function(con, sql) stop("optimizer died"), envir = globalenv())
  stops(melp_metrics(NULL, "f", "a", "R1", "MELP", map_tbl = "m"),
        "a metrics statement that fails names itself and the warehouse's message")
  assign("db_q", function(con, sql) data.frame(), envir = globalenv())
  ok(is.null(melp_metrics(NULL, "f", "a", "R1", "MELP", map_tbl = "m")),
     "...and one that comes back empty is no answer either")
  rm("db_q", "wrk", envir = globalenv())
})

sq <- melp_inputs_sql("META", "CODES", "STATUS", "R1")
ok(has(sq, "FROM META") && has(sq, "FROM CODES") && has(sq, "FROM STATUS") &&
     has(sq, "m.RUN_ID = 'R1'"),
   "what a cell was built over is read from all three tables the run wrote it to")
ok(has(sq, "max(s.CONTRACT_DEVIATIONS)"),
   "...with the deviations taken from LOT_BUILD_STATUS, which is the column that has them")

cat("\n-- the headline row is exactly MELP_METRICS --\n")
# The claim cells.R makes about this suite, now true: every lower-case alias
# melp_metric_sql() selects is a metric, and every metric is selected. A
# statement that loses an alias fails here rather than in melp_compare(), and
# an alias nothing names cannot be added without saying what it counts.
aliases <- local({
  qs <- melp_metric_sql("F", "A", "R1", "MELP", map_tbl = "M")
  unique(unlist(regmatches(qs, gregexpr(
    "(?<=AS )(n_|median_|pct_)[a-z0-9_]+", qs, perl = TRUE))))
})
ok(setequal(aliases, names(MELP_METRICS)),
   paste0("every metric is selected and every alias is a metric (",
          length(aliases), ")"))
extra <- setdiff(aliases, names(MELP_METRICS))
gone  <- setdiff(names(MELP_METRICS), aliases)
ok(!length(extra), if (length(extra))
     paste0("an alias no metric names: ", paste(extra, collapse = ", "))
   else "...no alias is unnamed")
ok(!length(gone), if (length(gone))
     paste0("a metric no statement selects: ", paste(gone, collapse = ", "))
   else "...and no metric is unselected")
# The by-line table's aliases are upper case for exactly this reason.
bl <- unlist(regmatches(melp_by_line_sql("F", "M"), gregexpr(
  "(?<=AS )(n_|median_|pct_)[a-z0-9_]+", melp_by_line_sql("F", "M"), perl = TRUE)))
ok(!length(bl),
   "the by-line table names nothing the headline row would read as a metric")

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

cat("\n-- and both are RUN, not just read --\n")
# Everything above inspects SQL as text, which cannot tell that a join lost a
# bound, that a CASE can never be true, or that a count measures something
# other than what its alias says. So the measurement SQL and the rule's
# decision chain are executed against fixtures whose answers are worked out by
# hand, in tests/exec_cells.R and tests/exec_rule.R. Skipped where duckdb and
# sqlglot are not installed; the transpile to duckdb is a compromise, not a
# substitute for a warehouse run.
source(file.path(ROOT, "tests", "exec_cells.R"))
source(file.path(ROOT, "tests", "exec_rule.R"))

XCFG <- list(apply_melp_rule = "simplified", melp_med_abbr = "MELP",
             melp_exposure_days = 30L, melp_simple_course_days = 28L,
             sct_tandem_days = 180L, map_discon_gap_days = 90L)

MQ <- melp_metric_sql(EXEC_TABLES$final, EXEC_TABLES$attrition, "RUN1", "MELP",
                      map_tbl = EXEC_TABLES$map, expo_days = 30L, ind1 = 60L,
                      indn = 30L, cart = 45L)
MQ[["by_line"]]  <- melp_by_line_sql(EXEC_TABLES$final, EXEC_TABLES$map, "MELP")
MQ[["patients"]] <- melp_modes_patients_sql(EXEC_TABLES$final,
                                            EXEC_TABLES$final_b)
mres <- run_exec_queries(MQ, ROOT)
rres <- run_exec_queries(list(rule = rule_query(XCFG),
                              no_break = no_break_query(XCFG)),
                         ROOT, schema = RULE_SCHEMA, data = rule_data())

if (identical(mres, "skip") || identical(rres, "skip") ||
      is.null(mres) || is.null(rres)) {
  skip_note("duckdb/sqlglot not installed - the SQL was not executed")
} else {
  ok(!length(exec_errors(mres)),
     if (length(exec_errors(mres)))
       paste0("a metrics statement did not run: ",
              paste(exec_errors(mres), collapse = "; "))
     else "every metrics statement transpiles and runs")
  ok(!length(exec_errors(rres)),
     if (length(exec_errors(rres)))
       paste0("the rule's chain did not run: ",
              paste(exec_errors(rres), collapse = "; "))
     else "the rule's decision chain transpiles and runs on its own")

  # Which statement each metric comes back in - the read cbinds them, so a
  # metric only has to be found somewhere.
  found <- function(m) {
    for (id in names(MQ)) {
      v <- exec_cell(mres, id, m)
      if (!is.na(v)) return(v)
    }
    NA_character_
  }
  for (m in names(EXEC_EXPECT_METRICS)) {
    want <- EXEC_EXPECT_METRICS[[m]]
    got  <- suppressWarnings(as.numeric(found(m)))
    ok(!is.na(got) && isTRUE(all.equal(got, want)),
       sprintf("%-20s = %s%s", m, format(want),
               if (is.na(got)) "  [not returned]"
               else if (!isTRUE(all.equal(got, want)))
                 paste0("  [got ", format(got), "]") else ""))
  }

  # And by line, where the row is the LOT number rather than the position.
  lot_row <- function(n) {
    hit <- mres$row[mres$id == "by_line" & mres$col == "LOT_NUM" &
                      mres$value == n]
    if (length(hit)) hit[1] else NA_character_
  }
  for (n in names(EXEC_EXPECT_BY_LINE)) {
    r <- lot_row(n)
    for (cl in names(EXEC_EXPECT_BY_LINE[[n]])) {
      want <- EXEC_EXPECT_BY_LINE[[n]][[cl]]
      got  <- if (is.na(r)) NA_real_ else exec_num(mres, "by_line", cl, r)
      ok(!is.na(got) && isTRUE(all.equal(got, want)),
         sprintf("LOT%s %-18s = %s%s", n, cl, format(want),
                 if (is.na(got)) "  [not returned]"
                 else if (!isTRUE(all.equal(got, want)))
                   paste0("  [got ", format(got), "]") else ""))
    }
  }

  for (cl in names(EXEC_EXPECT_PATIENTS)) {
    want <- EXEC_EXPECT_PATIENTS[[cl]]
    got  <- exec_num(mres, "patients", cl)
    ok(!is.na(got) && isTRUE(all.equal(got, want)),
       sprintf("two readings: %-28s = %s%s", cl, format(want),
               if (is.na(got)) "  [not returned]"
               else if (!isTRUE(all.equal(got, want)))
                 paste0("  [got ", format(got), "]") else ""))
  }

  # The rule, patient by patient. Each row is one branch of 4.7.
  rule_row <- function(pat) {
    hit <- rres$row[rres$id == "rule" & rres$col == "PATID" &
                      rres$value == pat]
    if (length(hit)) hit[1] else NA_character_
  }
  for (pat in names(RULE_CASES)) {
    c_i <- RULE_CASES[[pat]]
    r   <- rule_row(pat)
    bad <- character(0)
    for (cl in names(c_i$expect)) {
      want <- c_i$expect[[cl]]
      got  <- if (is.na(r)) NA_character_ else exec_cell(rres, "rule", cl, r)
      same <- if (length(want) == 1L && is.na(want)) !nzchar(got %||% "")
              else if (is.character(want)) identical(got, want)
              else identical(suppressWarnings(as.numeric(got)), as.numeric(want))
      if (!isTRUE(same))
        bad <- c(bad, paste0(cl, " wanted ",
                             if (length(want) == 1L && is.na(want)) "none"
                             else format(want), ", got ",
                             if (is.na(got) || !nzchar(got)) "none" else got))
    }
    ok(!is.na(r) && !length(bad),
       paste0(pat, ": ", c_i$what,
              if (is.na(r)) "  [no course judged at all]"
              else if (length(bad)) paste0("  [", paste(bad, collapse = "; "), "]")
              else ""))
  }

  # The doses the run-out chain must not break at, as a set.
  nb <- local({
    r <- rres[rres$id == "no_break", , drop = FALSE]
    if (!nrow(r)) return(character(0))
    sort(vapply(unique(r$row), function(i)
      paste(r$value[r$row == i & r$col == "PATID"],
            r$value[r$row == i & r$col == "DOSE_DT"]), character(1)))
  })
  ok(setequal(nb, NO_BREAK_EXPECT),
     if (setequal(nb, NO_BREAK_EXPECT))
       paste0("the run-out chain refuses a boundary at exactly these doses (",
              length(nb), ")")
     else paste0("the no-break set is wrong -- extra: ",
                 paste(setdiff(nb, NO_BREAK_EXPECT), collapse = ", "),
                 " | missing: ",
                 paste(setdiff(NO_BREAK_EXPECT, nb), collapse = ", ")))

  # Every case in the fixture carries an expectation and every rule branch
  # keeps one, so a patient added without an expectation is caught here.
  ok(all(vapply(RULE_CASES, function(c_i) length(c_i$expect) > 0L, logical(1))),
     "every planted patient carries an expectation")
}

# The suppression predicate carries both halves. The decision chain cannot show
# this: the predicate is spliced into the steps' candidate lists, not into the
# chain. A suppressed course's later doses and an injected course's later doses
# are refused a line for the same reason, and dropping either half gives one of
# them a line of its own.
sp <- melp_suppress_predicate(on)
ok(has(sp, "melp_suppress_dates") && has(sp, "melp_inject_rest"),
   "no melphalan dose the rule refused a line is left on the candidate list")

cat("\n", strrep("-", 52), "\n", sep = "")
check_skip_wiring()
test_report_status(pass, fail, skipped)
