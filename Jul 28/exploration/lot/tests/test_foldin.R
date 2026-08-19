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
source(file.path(LOT, "R", "foldin_rule.R"))

off <- list(apply_map_foldin = FALSE)
on_ <- list(apply_map_foldin = TRUE)

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

cat("\n-- the fold set is every earlier line's regimen, and its substitutes --\n")
s <- foldin_lotn_ctes(on_, "{lot_num}")
ok(has(s, "WHERE ll.LOT_NUM < {lot_num} AND m <> ''"),
   "the line build folds the regimens of every line before this one")
ok(has(s, "INNER JOIN permissible_subs ps ON p.MED_ABBR = ps.original_med"),
   "...expanded by the permissible substitutes, so a biosimilar folds too")
p <- foldin_prior_ctes(on_, "{prev}")
ok(has(p, "WHERE ll.LOT_NUM < {prev} AND m <> ''"),
   paste0("the trigger folds only the lines BEFORE the previous one - the ",
          "previous line's own regimen keeps the engine's release"))

cat("\n-- suppressing and owning are two halves of one statement --\n")
ok(has(foldin_suppress_predicate(on_), "bm.MED_ABBR IS NULL") &&
     has(foldin_suppress_predicate(on_), "foldin_meds"),
   "a fold-set episode is no candidate - unless the drug is in this line's own base")
ok(has(s, "foldin_hold AS (") &&
     has(s, "max(least(ms.MAP_END_DT, ls.OBS_END_DT)) AS FOLDIN_HOLD_DT"),
   "the hold carries the line to the folded cover, capped at observation")
ok(has(s, "WHERE bm.MED_ABBR IS NULL") &&
     has(s, "ms.MAP_START_DT >= ls.LOT{lot_num}_START_DT"),
   "...over episodes STARTING in the line, own-base drugs kept out")
ok(has(foldin_runout_case(on_, "X"), "(X) IS NOT NULL AND fh.FOLDIN_HOLD_DT > (X)"),
   "the hold only ever extends a run-out that exists")
ok(has(s, "foldin_boundary_src AS (") &&
     identical(foldin_boundary_tbl(on_), "foldin_boundary_src") &&
     has(s, "fm.MED_ABBR IS NULL OR bm2.MED_ABBR IS NOT NULL"),
   "a folded episode no longer breaks a base drug's run-out chain")
ok(has(foldin_trigger_predicate(on_), "foldin_sc_meds"),
   "an older line's agent never starts a line while the rule is on")

cat("\n-- the splices are in the step, and only where they belong --\n")
sf <- function(f) paste(readLines(file.path(LOT, "R", "steps", f), warn = FALSE),
                        collapse = "\n")
s10 <- sf("10_lot2_5_base.R")
ok(has(s10, "{foldin_prior_ctes(cfg, prev)}") &&
     has(s10, "{foldin_trigger_predicate(cfg)}"),
   "the start candidates carry the fold's trigger exclusion")
ok(has(s10, "{foldin_lotn_ctes(cfg, lot_num)}") &&
     has(s10, "{foldin_suppress_predicate(cfg)}"),
   "the line build carries the fold's candidate exclusion")
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

cat("\n-- the contract pins it off --\n")
bl <- paste(readLines(file.path(LOT, "R", "build_lot.R"), warn = FALSE),
            collapse = "\n")
ok(has(bl, "apply_map_foldin            = FALSE"),
   "APPLY_MAP_FOLDIN is FALSE in CONTRACT, so TRUE is a recorded deviation")
ok(has(bl, '"APPLY_MAP_FOLDIN"'), "...and the setting is type-checked")
ok(has(bl, '"foldin_rule.R"'), "...and the rule file is loaded with the engine")

cat("\n-- the cell package --\n")
rf <- paste(readLines(file.path(ROOT, "run_foldin_cells.R"), warn = FALSE),
            collapse = "\n")
ok(has(rf, 'melp_cell_plan(FOLDIN_CELLS, "foldin_")'),
   "the package builds under its own foldin_ prefixes")
ok(has(rf, '"LOT_CONTRACT_OVERRIDE=TRUE", "APPLY_MAP_FOLDIN=TRUE"'),
   "the mode cell is built as a recorded deviation")
ok(has(rf, 'key = "apply_map_foldin"') && has(rf, 'vary = "apply_map_foldin"'),
   "the shared cell checks govern this rule's own setting")
ok(has(rf, "melp_status_unchanged") && has(rf, "melp_check_code") &&
     has(rf, "melp_read_inputs"),
   "the read carries the same run-ownership checks as the melphalan packages")

cat("\n", strrep("-", 52), "\n", sep = "")
cat(sprintf("%d passed, %d failed\n", pass, fail))
if (fail > 0L) quit(status = 1L)
