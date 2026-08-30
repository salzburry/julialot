#!/usr/bin/env Rscript
# The MAP fold-in rule as an engine rule, and the two cells built from it.
# No warehouse: the SQL is built as a string and checked. The branch
# behaviour on planted patients is proved end to end by the repository's
# planted-patient harness; these pin the shape of the SQL, that off is the
# absence of the rule, and that LOT1 never hears of it.
#
#   Rscript "exploration/lot/tests/test_foldin.R"

ROOT <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                                 fixed = TRUE))) else getwd()
  dirname(d)
})
STUDY <- dirname(dirname(ROOT))
LOT   <- file.path(STUDY, "lot", "engine")

pass <- 0L; fail <- 0L
ok <- function(cond, what) {
  if (isTRUE(cond)) { pass <<- pass + 1L; cat("  ok     ", what, "\n") }
  else              { fail <<- fail + 1L; cat("  FAIL   ", what, "\n") }
}
has <- function(x, s) grepl(s, x, fixed = TRUE)

library(glue)
`%||%` <- function(a, b) if (is.null(a)) b else a
# The fold-in consults the melphalan rule - a course that rule suppressed is
# not a line-defining agent - so it loads first here, as it does in the engine.
# prior_regimen.R carries the transplant helpers both rules read.
source(file.path(LOT, "R", "prior_regimen.R"))
source(file.path(LOT, "R", "melp_rule.R"))
source(file.path(LOT, "R", "foldin_rule.R"))

# map_discon_gap_days is what separates one course of a drug from the next, so
# the rule reads it now.
off <- list(apply_map_foldin = FALSE, map_discon_gap_days = 90L,
            sct_tandem_days = 180L)
on_ <- list(apply_map_foldin = TRUE,  map_discon_gap_days = 90L,
            sct_tandem_days = 180L)

cat("\n-- off is not a setting, it is the absence of the rule --\n")
ok(identical(foldin_lotn_ctes(off, 2), ""), "the line build gets no extra CTEs")
ok(identical(foldin_prior_ctes(off, 1), ""), "the start candidates get none either")
ok(identical(foldin_suppress_predicate(off), ""), "no predicate is added to the candidates")
ok(identical(foldin_trigger_predicate(off), ""), "...or to the next line's trigger")
ok(identical(foldin_boundary_tbl(off), "map_stacked"),
   "the interrupt scan reads map_stacked exactly as the source does")
ok(identical(foldin_runout_case(off, "X"), "X"), "and the run-out expression is untouched")
ok(identical(foldin_hold_col(off), "") && identical(foldin_hold_join(off, "ls"), "") &&
     identical(foldin_line_type_guard(off, 2), ""),
   "no hold column, join or guard reaches the statement")

cat("\n-- the fold set is the previous line's regimen, and its substitutes --\n")
s <- foldin_lotn_ctes(on_, "{lot_num}")
ok(has(s, "WHERE ll.LOT_NUM = {lot_num} - 1 AND m <> ''"),
   "the line build folds the IMMEDIATELY PREVIOUS line's regimen")
# Read through the AGENT, so the set is the same whichever half of a
# permissible pair the regimen happens to name. Expanding the raw regimen was
# one-directional: a regimen naming the reference product picked up its
# substitute, a regimen naming the substitute did not pick up the reference
# product, and the pair folded one way only.
ok(has(s, "coalesce(ps.original_med, p.MED_ABBR) AS AGENT"),
   "...each regimen drug read under the agent it belongs to")
ok(has(s, "INNER JOIN permissible_subs ps ON ps.original_med = a.AGENT"),
   "...and expanded back to every substitute for that agent, both directions")
p <- foldin_prior_ctes(on_, "{prev}")
ok(has(p, "WHERE ll.LOT_NUM = {prev} AND m <> ''"),
   paste0("the trigger reads the same one line - the regimen of the line ",
          "before the one being started"))

cat("\n-- suppressing and owning are two halves of one statement --\n")
ok(has(foldin_suppress_predicate(on_), "bm.MED_ABBR IS NULL") &&
     has(foldin_suppress_predicate(on_), "foldin_episodes") &&
     has(foldin_suppress_predicate(on_), "fm.MAP_START_DT = ms.MAP_START_DT"),
   "a folded EPISODE is no candidate - unless the drug is in this line's own base")
ok(has(s, "foldin_hold AS (") &&
     has(s, "max(least(ms.MAP_END_DT, ls.OBS_END_DT)) AS FOLDIN_HOLD_DT"),
   "the hold carries the line to the folded cover, capped at observation")
ok(has(s, "WHERE bm.MED_ABBR IS NULL") &&
     has(s, "ms.MAP_START_DT >= ls.LOT{lot_num}_START_DT"),
   "...over episodes STARTING in the line, own-base drugs kept out")
ok(has(foldin_runout_case(on_, "X"), "(X) IS NULL AND d.PATID IS NULL") &&
     has(foldin_runout_case(on_, "X"), "fh.FOLDIN_HOLD_DT > (X)"),
   paste0("the hold extends a run-out that exists, and SUPPLIES one for a ",
          "line with no regimen at all - never for cover running past ",
          "observation"))
ok(has(s, "foldin_boundary_src AS (") &&
     identical(foldin_boundary_tbl(on_), "foldin_boundary_src") &&
     has(s, "fm.MED_ABBR IS NULL OR bm2.MED_ABBR IS NOT NULL"),
   "a folded episode no longer breaks a base drug's run-out chain")
ok(has(foldin_trigger_predicate(on_), "foldin_episodes") &&
     has(foldin_trigger_predicate(on_), "fm.MAP_START_DT = ms.MAP_START_DT"),
   "an older line's FOLDED episode never starts a line while the rule is on")

cat("\n-- the count: one advance folds, two or more do not --\n")
# The study team's 20 Aug refinement. The whole rule now turns on N_ADVANCES,
# so the arithmetic is pinned here and the behaviour on planted patients by
# the harness named in the repository README.
ok(has(s, "foldin_folded AS (") && has(s, "WHERE N_ADVANCES = 1"),
   "exactly one advance between the two doses folds, and nothing else does")
ok(has(s, "count(DISTINCT fo.OPENER)") &&
     has(s, "fo.OPEN_DT >  k.PREV_COURSE_DT") &&
     has(s, "fo.OPEN_DT <  k.MAP_START_DT"),
   "...counted as the different AGENTS that opened a line in between")
# The request says AGENTS, so a line is read through the drug that started it
# and a transplant-started line counts nothing. Both halves are pinned: the
# MED-only filter, and the substitute collapse that keeps a biosimilar swap
# from reading as a second agent.
# The fold set is the IMMEDIATELY PREVIOUS line's regimen, which is the
# request's own shape - A + B in one line, C advances it, B comes back. A drug
# from further back is out of scope and the engine's ordinary rules keep it.
ok(has(s, "foldin_openers AS (") && has(s, "l.LOT_START_TYPE = 'MED'"),
   "an agent is the drug a MED-started line opened on - a procedure is not one")
ok(has(s, "min(coalesce(ps.original_med, ms.MAP_MED_TYPE)) AS OPENER"),
   "...and a permissible substitute is the same agent as the drug it replaces")
# ONE row per line. A doublet opening a line advanced the LOT once, and the
# request counts agents advancing it twice or more - counting each opener drug
# made a two-drug start two advances and refused a fold it should have taken.
ok(has(s, "GROUP BY l.PATID, l.LOT_START_DT"),
   "...and a line contributes ONE advance however many drugs opened it")
ok(has(s, "lag(c.MAP_START_DT) OVER (PARTITION BY c.PATID, c.AGENT"),
   "the interval is dose to dose, and a substitute shares the agent's doses")
# A course carries the answer to its own later episodes. Judged one episode at
# a time, a returning course was split between two owners: its first episode
# folded and its follow-up, with no advance behind it, opened a line.
ok(has(s, "foldin_course AS (") && has(s, "IS_RETURN") &&
     has(s, "INNER JOIN foldin_folded f"),
   "a course is one answer - every episode in it folds, or none does")
ok(has(s, "FROM tx_auto_dates") && has(s, "FROM tx_allo_cart_dates"),
   "a procedure counts as an intervening boundary, not only a medication")
ok(has(s, "N_BETWEEN = 0"),
   "...and a return with another agent before it belongs to a later line")
# The start-candidate statement judges a later line once lot_long has grown,
# so it needs no in-this-line test and must not carry one.
ok(has(p, "WHERE N_ADVANCES = 1") && !has(p, "N_BETWEEN"),
   "the trigger side counts the same way, over the lines it can already see")

cat("\n-- the splices are in the step, and only where they belong --\n")
sf <- function(f) paste(readLines(file.path(LOT, "R", "steps", f), warn = FALSE),
                        collapse = "\n")
s10 <- sf("10_lot2_5_base.R")
ok(has(s10, "{foldin_prior_ctes(cfg, prev)}") &&
     has(s10, "{foldin_trigger_predicate(cfg)}"),
   "the start candidates carry the fold's trigger exclusion")
ok(has(s10, "{foldin_lotn_ctes(cfg, lot_num, lotn_induction_end(") &&
     has(s10, "{foldin_suppress_predicate(cfg)}"),
   "the line build carries the fold's candidate exclusion, and the line's window")
ok(has(s10, "boundary_tbl = foldin_boundary_tbl(cfg)"),
   "...and discon_per_med reads the filtered boundary source")
ok(has(s10, "foldin_runout_case(cfg,") &&
     has(s10, "{foldin_hold_col(cfg, 'fh')}") &&
     has(s10, "{foldin_hold_join(cfg, 'ls')}"),
   "...and the hold rides the run-out the way the melphalan hold does")
ok(length(gregexpr("{foldin_line_type_guard(cfg, lot_num)}", s10, fixed = TRUE)[[1]]) == 4L,
   "the hold overrides the ALLO and CART short-circuits at all four sites")
ok(!has(sf("04_lot1_base.R"), "foldin") && !has(sf("06_lot1_end.R"), "foldin"),
   "LOT1 never hears of the rule - it has no earlier line to fold from")

cat("\n-- the contract carries it --\n")
bl <- paste(readLines(file.path(LOT, "R", "build_lot.R"), warn = FALSE),
            collapse = "\n")
ok(has(bl, "apply_map_foldin            = TRUE"),
   "APPLY_MAP_FOLDIN is TRUE in CONTRACT, so a build without it deviates")
cfgcsv <- paste(readLines(file.path(LOT, "config.csv"), warn = FALSE),
                collapse = "\n")
ok(has(cfgcsv, "APPLY_MAP_FOLDIN,TRUE,"),
   "...and config.csv ships the same value, so a run does not stop on it")
ok(has(bl, '"APPLY_MAP_FOLDIN"'), "...and the setting is type-checked")
ok(has(bl, '"foldin_rule.R"'), "...and the rule file is loaded with the engine")

cat("\n-- the cell package --\n")
rf <- paste(readLines(file.path(ROOT, "run_foldin_cells.R"), warn = FALSE),
            collapse = "\n")
ok(has(rf, 'melp_cell_plan(FOLDIN_CELLS, "foldin_")'),
   "the package builds under its own foldin_ prefixes")
# Since the study adopted the rule it is the cell WITHOUT it that deviates.
ok(has(rf, 'mode = "FALSE", foldin = "FALSE"') &&
     has(rf, 'mode = NA_character_, foldin = "TRUE"'),
   "the no-rule cell deviates and the folded cell is the contract build")
ok(has(rf, 'if (!is.na(c_i$mode)) env <- c(env, "LOT_CONTRACT_OVERRIDE=TRUE")'),
   "...and the override goes on whichever cell is not the contract")
ok(has(rf, 'paste0("APPLY_MAP_FOLDIN=", c_i$foldin)') &&
     has(rf, '"APPLY_MELP_RULE=simplified"'),
   "both cells name both settings, so an ambient one reaches neither")
ok(has(rf, 'key = "apply_map_foldin"') && has(rf, 'vary = "apply_map_foldin"'),
   "the shared cell checks govern this rule's own setting")
ok(has(rf, "melp_status_unchanged") && has(rf, "melp_check_code") &&
     has(rf, "melp_read_inputs"),
   "the read carries the same run-ownership checks as the melphalan packages")
ok(has(rf, "foldin_changed_lines.csv") && has(rf, "FULL OUTER JOIN b") &&
     has(rf, "LINE_CHANGED"),
   "every moved patient's lines are written before/after, not only aggregates")

cat("\n", strrep("-", 52), "\n", sep = "")
cat(sprintf("%d passed, %d failed\n", pass, fail))
if (fail > 0L) quit(status = 1L)
