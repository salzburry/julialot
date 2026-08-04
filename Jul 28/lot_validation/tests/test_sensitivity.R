#!/usr/bin/env Rscript
# Checks on the sensitivity harness.
#
# The grid and the guards are plain data and arithmetic, so all of it runs
# here. What cannot run is a cell - that is a complete LOT build against a
# warehouse - so the comparison logic is driven with fabricated results
# instead. Getting the SIGN wrong there would score a real finding as expected,
# which is the failure worth spending a test on.
#
#   Rscript "lot_validation/tests/test_sensitivity.R"

ROOT <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                                 fixed = TRUE))) else getwd()
  dirname(d)
})
# The folder the packages sit in, resolved from this file rather than named:
# it stays right whatever that folder is called.
PARENT <- dirname(ROOT)

pass <- 0L; fail <- 0L
ok <- function(cond, what) {
  if (isTRUE(cond)) { pass <<- pass + 1L; cat("  ok     ", what, "\n") }
  else              { fail <<- fail + 1L; cat("  FAIL   ", what, "\n") }
}
runs  <- function(expr, what) ok(is.null(tryCatch({ expr; NULL },
                                 error = conditionMessage)), what)
stops <- function(expr, what) ok(!is.null(tryCatch({ expr; NULL },
                                 error = conditionMessage)), what)

source(file.path(ROOT, "R", "sensitivity.R"))

cat("\n-- the grid is one at a time, not a cross-product --\n")
cells <- sens_plan()
# Six axes with two values each is thirteen builds. The cross-product would be
# 3^6 = 729, and nobody would run it.
ok(length(cells) == 1L + sum(vapply(SENS_AXES, function(a) length(a$values), integer(1))),
   paste0("one cell per alternative plus a reference (", length(cells), ")"))
ok(identical(cells[[1]]$id, "reference"),
   "...with the reference built like any other cell, not assumed from an existing run")
ok(length(cells) < prod(vapply(SENS_AXES, function(a) length(a$values) + 1L, integer(1))),
   "...and far fewer than the cross-product, which is the point")

cat("\n-- and it refuses a plan that would cost or destroy more than expected --\n")
runs(check_sens_plan(cells, "ndmm_"), "the shipped plan is safe to run")
# The failure that would be unrecoverable: a cell writing over the study's own
# tables while measuring them.
stops(check_sens_plan(cells, "sens_ref_"),
      "a cell that would write to the study's own prefix is refused")
stops(check_sens_plan(cells, "ndmm_", cap = 5L),
      "...and a grid past the cell cap, since each cell is a whole build")
dup <- c(cells, cells[2])
stops(check_sens_plan(dup, "ndmm_"), "...and two cells sharing a prefix")
ok(all(vapply(cells, function(c_i) grepl("^[A-Za-z][A-Za-z0-9_]*_$", c_i$prefix),
              logical(1))),
   "every cell prefix is a valid object prefix")

cat("\n-- every axis is a setting the build actually reads --\n")
# An axis naming a setting the build ignores would run thirteen builds that
# differ in nothing, and the table would show noise as signal.
e <- new.env(parent = globalenv())
sys.source(file.path(PARENT, "lot", "R", "load_inputs.R"), envir = e)
e$load_pipeline_inputs(file.path(PARENT, "lot"), "config.csv")
sys.source(file.path(PARENT, "lot", "R", "config_lot.R"), envir = e)
shipped <- get("cfg_defaults", envir = e)
missing <- Filter(function(a) is.null(shipped[[a$cfg]]), SENS_AXES)
ok(!length(missing),
   if (length(missing)) paste0("axis names a setting the config has not: ",
                               paste(vapply(missing, function(a) a$cfg, character(1)),
                                     collapse = ", "))
   else "every axis maps to a field of the build's own config")
cl <- readLines(file.path(PARENT, "lot", "config.csv"), warn = FALSE)
notenv <- Filter(function(a) !any(grepl(paste0("^", a$param, ","), cl)), SENS_AXES)
ok(!length(notenv),
   if (length(notenv)) paste0("axis is not a setting config.csv carries: ",
                              paste(vapply(notenv, function(a) a$param, character(1)),
                                    collapse = ", "))
   else "...and to an environment name the build takes")
# Values that equal the shipped one would be a duplicate reference cell.
same <- Filter(function(a) as.integer(shipped[[a$cfg]]) %in% as.integer(a$values), SENS_AXES)
ok(!length(same),
   if (length(same)) paste0("an axis re-tests the shipped value: ",
                            paste(vapply(same, function(a) a$param, character(1)),
                                  collapse = ", "))
   else "no axis re-tests the value the reference cell already has")

cat("\n-- the direction is stated before the run, and it is a sign --\n")
for (a in SENS_AXES) {
  ok(length(a$expect) > 0 && all(unlist(a$expect) %in% c("up", "down", "none", "unclear")),
     paste0(a$param, " predicts a direction for every metric it names"))
  ok(all(names(a$expect) %in% names(SENS_METRICS)),
     paste0("...and every metric it names is one the harness measures"))
}
ok(any(vapply(SENS_AXES, function(a) identical(a$confidence, "to_confirm"), logical(1))),
   "the axes we are unsure about say so rather than predicting confidently")

cat("\n-- and the comparison scores the sign, not the size --\n")
mk <- function(...) {
  base <- data.frame(cell = "reference", param = "", value = NA_integer_,
                     shipped_value = NA_integer_, n_lines = 1000, n_patients = 500,
                     pct_reaching_lot2 = 40, median_lot1_length = 100,
                     stringsAsFactors = FALSE)
  rbind(base, ...)
}
row <- function(cell, param, value, shipped, ...) {
  d <- data.frame(cell = cell, param = param, value = value, shipped_value = shipped,
                  n_lines = 1000, n_patients = 500, pct_reaching_lot2 = 40,
                  median_lot1_length = 100, stringsAsFactors = FALSE)
  for (nm in names(list(...))) d[[nm]] <- list(...)[[nm]]
  d
}
# Gap up, lines down: what MAP_DISCON_GAP_DAYS predicts.
c1 <- sens_compare(mk(row("map_discon_gap_days_120", "MAP_DISCON_GAP_DAYS", 120, 90,
                          n_lines = 900)))
ok(identical(c1$verdict[c1$metric == "n_lines"], "as expected"),
   "a larger gap producing fewer lines reads as expected")
# The same movement with the parameter LOWERED is the opposite finding, which
# is why the sign is taken relative to the parameter's direction.
c2 <- sens_compare(mk(row("map_discon_gap_days_60", "MAP_DISCON_GAP_DAYS", 60, 90,
                          n_lines = 900)))
ok(identical(c2$verdict[c2$metric == "n_lines"], "AGAINST EXPECTATION"),
   "...and the same number from a SMALLER gap is against it, not for it")
c3 <- sens_compare(mk(row("map_discon_gap_days_120", "MAP_DISCON_GAP_DAYS", 120, 90,
                          n_patients = 480)))
ok(identical(c3$verdict[c3$metric == "n_patients"], "AGAINST EXPECTATION"),
   "a metric predicted not to move at all is caught when it does")
c4 <- sens_compare(mk(row("map_discon_gap_days_120", "MAP_DISCON_GAP_DAYS", 120, 90)))
ok(all(c4$verdict[c4$metric == "n_patients"] == "as expected"),
   "...and passes when it does not")
# "unclear" was recorded so the run could settle it. Scoring it as a hit or a
# miss would reward whichever guess had been written down.
c5 <- sens_compare(mk(row("induction_window_days_90", "INDUCTION_WINDOW_DAYS", 90, 60,
                          n_lines = 900)))
ok(identical(c5$verdict[c5$metric == "n_lines"], "recorded"),
   "an 'unclear' prediction is recorded, never scored")
c6 <- sens_compare(mk(row("map_discon_gap_days_120", "MAP_DISCON_GAP_DAYS", 120, 90,
                          n_lines = NA_real_)))
ok(identical(c6$verdict[c6$metric == "n_lines"], "no data"),
   "a cell that produced no number says so rather than counting as agreement")
stops(sens_compare(mk()[0, , drop = FALSE]),
      "a comparison with no reference cell stops rather than comparing to nothing")

cat("\n-- and a number that did not move is not the opposite finding --\n")
# The prediction is about the ALGORITHM. Whether anyone in the cohort sits near
# the threshold is not, and a window nobody's claims straddle moves nothing
# however it is set. Scoring that as AGAINST EXPECTATION reports a valid result
# as a failure, and a sweep full of them stops being read.
c7 <- sens_compare(mk(row("map_discon_gap_days_120", "MAP_DISCON_GAP_DAYS", 120, 90,
                          n_lines = 1000)))
ok(identical(c7$verdict[c7$metric == "n_lines"], "no movement"),
   "a predicted direction that produced no change at all is its own verdict")
ok(!identical(c7$verdict[c7$metric == "n_lines"], "AGAINST EXPECTATION"),
   "...and specifically NOT against expectation, which would be a false failure")
# The asymmetry is deliberate: predicting "none" and getting movement is a miss.
ok(identical(c3$verdict[c3$metric == "n_patients"], "AGAINST EXPECTATION"),
   "...while movement where none was predicted stays a miss")
# Both sides of the boundary still score, so nothing became unfalsifiable.
ok(identical(c1$verdict[c1$metric == "n_lines"], "as expected") &&
     identical(c2$verdict[c2$metric == "n_lines"], "AGAINST EXPECTATION"),
   "...and a real move in either direction still scores as it did")
ok(any(grepl("no movement", readLines(file.path(ROOT, "run_sensitivity.R"),
                                      warn = FALSE), fixed = TRUE)),
   "the runner reports them separately rather than burying them in the CSV")

cat("\n-- a prediction that could not come true is not a prediction --\n")
# MAX_LOT is the case: pct_reaching_lot3 cannot move between MAX_LOT 3 and 8,
# because LOT3 is built at both. Predicting "up" there guarantees a permanent
# false failure in every sweep.
ml <- Filter(function(a) identical(a$param, "MAX_LOT"), SENS_AXES)[[1]]
ok(identical(ml$expect$pct_reaching_lot3, "none"),
   "MAX_LOT predicts no change in reaching LOT3, since every cell builds LOT3")
ok(all(as.integer(ml$values) >= 3L),
   "...which is only true because no cell caps below the line being measured")
# The general form of it: a metric measuring line n cannot be predicted to move
# by a cap that leaves line n built in every cell.
capped <- Filter(function(a) {
  if (!identical(a$param, "MAX_LOT")) return(FALSE)
  ln <- as.integer(sub("^pct_reaching_lot", "", grep("^pct_reaching_lot",
                                                     names(a$expect), value = TRUE)))
  any(!is.na(ln) & ln <= min(as.integer(a$values)) &
        unlist(a$expect[grep("^pct_reaching_lot", names(a$expect))]) != "none")
}, SENS_AXES)
ok(!length(capped),
   "no cap axis predicts movement in a line every one of its cells still builds")

cat("\n-- a switch reaches the build as a switch --\n")
# The one non-numeric axis, and the coercion is the hazard: as.integer(TRUE) is
# 1, and config_lot.R reads that back through as.logical("1") as NA. A cell that
# builds with the shipped setting reports "no movement" on every metric and
# reads as a result - a silent copy of the reference is worse than a failed cell.
ce <- Filter(function(a) identical(a$param, "CENSOR_AT_DISENROLLMENT"), SENS_AXES)
ok(length(ce) == 1L, "continuous enrolment as censoring is an axis")
cec <- Filter(function(c_i) identical(c_i$param, "CENSOR_AT_DISENROLLMENT"), sens_plan())
ok(length(cec) == 1L, "...with one cell, because it is on or off")
# Through the trip it actually takes: the value is pasted into an env string,
# and config_lot.R reads that string back with as.logical(). as.logical(1L) is
# TRUE and as.logical("1") is NA, so testing the value directly passes on the
# very coercion this exists to catch.
env <- sub("^[^=]+=", "", paste0(cec[[1]]$param, "=", cec[[1]]$value))
ok(length(cec) == 1L && identical(as.logical(env), TRUE),
   "...and survives the env-string round trip, so the cell is not the reference again")
# The ordering used by sens_compare to decide which side of the shipped value a
# cell sits on. as.numeric("TRUE") is NA, which would score nothing.
ok(sens_rank("FALSE") == 0 && sens_rank("TRUE") == 1 && sens_rank("60") == 60,
   "...and FALSE ranks below TRUE, beside the numeric axes")
# It changes the observation window, not a threshold inside it, so it is the one
# axis that can change who has a line at all - and it can do so in EITHER
# direction, so it predicts no direction. The no_belantamab criterion reads the
# same shortened window and truncates every line of a patient it catches, so a
# belantamab claim after disenrolment is visible to the reference cell and
# invisible to this one: the patient the primary run removes is kept here.
# Declaring "down" would score that valid result AGAINST EXPECTATION forever.
ok(length(ce) == 1L && all(unlist(ce[[1]]$expect) == "unclear"),
   "it predicts no direction, because the window moves the population both ways")
ok(length(ce) == 1L && identical(ce[[1]]$confidence, "to_confirm"),
   "...and says so rather than claiming the directions are derived")
ok(any(grepl("no_belantamab", ce[[1]]$why, fixed = TRUE)),
   "...naming the mechanism that can push the counts UP, so a riser is traceable")
# That mechanism has to still be in the build this claims it about.
lc <- readLines(file.path(PARENT, "lot", "R", "line_criteria.R"), warn = FALSE)
ok(any(grepl('name    = "no_belantamab"', lc, fixed = TRUE)) &&
     any(grepl('on_fail = "truncate"', lc, fixed = TRUE)) &&
     any(grepl("m.MAP_START_DT <= p.OBS_END_DT", lc, fixed = TRUE)),
   "...and that criterion still reads OBS_END_DT and still truncates the patient")
# Every threshold axis leaves the population alone, and still says so.
ok(all(vapply(Filter(function(a) !identical(a$param, "CENSOR_AT_DISENROLLMENT"), SENS_AXES),
              function(a) identical(a$expect$n_patients, "none"), logical(1))),
   "...while every threshold axis says the cohort is fixed before LOT runs")

cat("\n-- what the ask wanted that cannot be swept --\n")
# Silently dropping two of the four axes would read as coverage.
rs <- readLines(file.path(ROOT, "run_sensitivity.R"), warn = FALSE)
sn <- readLines(file.path(ROOT, "R", "sensitivity.R"), warn = FALSE)
# Case-insensitive: the assertion is that the axis is named, not how a sentence
# happens to start.
ok(any(grepl("maintenance-as-lot", rs, ignore.case = TRUE)) &&
     any(grepl("maintenance-as-lot", sn, ignore.case = TRUE)),
   "maintenance-as-LOT is named as not being a setting, not quietly dropped")
ok(any(grepl("NDMM_FU_CE_COUNTS", rs, fixed = TRUE)),
   "...and CE ELIGIBILITY is pointed at the build that already reports it")
ok(any(grepl("CENSOR_AT_DISENROLLMENT", rs, fixed = TRUE)),
   "...while CE as censoring is named as one that IS swept, not lumped in with it")
sct <- readLines(file.path(PARENT, "lot", "R", "steps", "05_sct.R"), warn = FALSE)
ok(any(grepl("Maintenance is a descriptive flag only", sct, fixed = TRUE)),
   "...and that claim about maintenance is checked against the code, not asserted")

cat("\n-- execution is opt-in, because a cell is a whole build --\n")
ok(any(grepl('env_flag("SENS_EXECUTE")', rs, fixed = TRUE)),
   "the default prints the plan and runs nothing")
ok(any(grepl("EACH ONE IS A COMPLETE LOT BUILD", rs, fixed = TRUE)),
   "...and says what a cell costs before anyone commits to it")
# A build pins a config and a run id globally; a second in the same session
# would inherit the first's.
ok(any(grepl("system2(\"Rscript\"", rs, fixed = TRUE)),
   "each cell runs as its own process rather than in this one")
# LOT_ATTRITION is keyed by run id, and the cell's id is not this script's.
rb <- readLines(file.path(ROOT, "R", "run_binding.R"), warn = FALSE)
ok(any(grepl("lot_run_row(con, c_i$prefix)", rs, fixed = TRUE)),
   "...and its metrics are read against that cell's own run id")
ok(any(grepl("LOT_BUILD_STATUS", rb, fixed = TRUE)) &&
     any(grepl("ORDER BY UPDATED_AT DESC LIMIT 1", rb, fixed = TRUE)),
   "...resolved by the one helper both harnesses use, from the latest status row")
ok(any(grepl('env_flag("SENS_DROP_AFTER")', rs, fixed = TRUE)),
   "dropping a cell's tables is opt-in, not what a measurement script does quietly")

cat("\n-- and a cell can actually be built, which is not a given --\n")
# Every axis here varies a CONTRACT-pinned value, and build_lot refuses one -
# correctly, because a different threshold is a different algorithm. Without
# the override, twelve of thirteen cells stop at preflight and the sweep
# produces nothing. Nothing in the plan or the comparison logic would show it:
# they never touch the LOT entry point.
bl <- readLines(file.path(PARENT, "lot", "R", "build_lot.R"), warn = FALSE)
contract_keys <- names(get("CONTRACT", envir = local({
  e <- new.env(parent = globalenv()); sys.source(
    file.path(PARENT, "lot", "R", "build_lot.R"), envir = e, keep.source = FALSE); e
})))
pinned <- Filter(function(a) a$cfg %in% contract_keys, SENS_AXES)
ok(length(pinned) > 0,
   paste0("the axes really are contract-pinned (", length(pinned), " of ",
          length(SENS_AXES), "), so this is not hypothetical"))
ok(any(grepl("LOT_CONTRACT_OVERRIDE=TRUE", rs, fixed = TRUE)),
   "so each alternative cell says it is building an alternative")
ok(any(grepl("LOT_CONTRACT_OVERRIDE", bl, fixed = TRUE)),
   "...and the build has that door, rather than the sweep hoping for one")
# The reference cell changes nothing, so it must not claim to.
ref_guarded <- grep("if \\(!is\\.na\\(c_i\\$param\\)\\)", rs)
ok(length(ref_guarded) &&
     any(grepl("LOT_CONTRACT_OVERRIDE=TRUE", rs[ref_guarded[1] + 0:2], fixed = TRUE)),
   "...only the cells that change something, not the reference build")
# The override is only safe because a cell cannot be read as the study.
ok(any(grepl("CONTRACT_DEVIATIONS", bl, fixed = TRUE)),
   "a deviating build records what it deviated on, in its own status table")
for (f in c(file.path(ROOT, "R", "run_binding.R"),
            file.path(PARENT, "questions", "_setup.R"),
            file.path(PARENT, "dashboard", "R", "db_utils_dash.R")))
  ok(any(grepl("CONTRACT_DEVIATIONS|deviations", readLines(f, warn = FALSE))),
     paste0("...and ", basename(f), " refuses a run carrying them"))

cat("\n-- thirteen builds, one cohort, and it is checked rather than intended --\n")
# COHORT_PREFIX defaults to the RUN's own prefix, which for a cell is a
# throwaway. The build then looks for sens_max_lot_8_NDMM_BUILD_STATUS, finds
# nothing, warns and carries on with no cohort run id at all - so nothing would
# record that the cells read one cohort, and a cohort rebuilt mid-sweep would
# read as the parameter's effect.
ok(any(grepl('paste0("COHORT_PREFIX=", cohort_pfx)', rs, fixed = TRUE)),
   "each cell is told where the cohort's status table lives")
ok(any(grepl("COHORT_PREFIX is required to execute", rs, fixed = TRUE)),
   "...and executing without it is refused, not defaulted")
ok(any(grepl("lot_run_meta(con, c_i$prefix)", rs, fixed = TRUE)),
   "each cell's cohort attempt is read back from what it recorded")
ok(any(grepl("COHORT CHANGED DURING THE SWEEP", rs, fixed = TRUE)),
   "...and cells that did not share one attempt are reported, not averaged over")
# The pair, not the id: a cohort re-run keeps its id and rewrites its rows.
ok(any(grepl("cohort_at", rs, fixed = TRUE)) ||
     any(grepl("COHORT_STAMP", readLines(file.path(ROOT, "R", "run_binding.R"),
                                         warn = FALSE), fixed = TRUE)),
   "...identified by run id AND stamp, since a re-run keeps its id")

cat("\n", strrep("-", 52), "\n", sep = "")
cat(sprintf("%d passed, %d failed\n", pass, fail))
if (fail > 0L) quit(status = 1L)
