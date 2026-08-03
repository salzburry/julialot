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
sys.source(file.path(JUL28, "lot", "R", "load_inputs.R"), envir = e)
e$load_pipeline_inputs(file.path(JUL28, "lot"), "config.csv")
sys.source(file.path(JUL28, "lot", "R", "config_lot.R"), envir = e)
shipped <- get("cfg_defaults", envir = e)
missing <- Filter(function(a) is.null(shipped[[a$cfg]]), SENS_AXES)
ok(!length(missing),
   if (length(missing)) paste0("axis names a setting the config has not: ",
                               paste(vapply(missing, function(a) a$cfg, character(1)),
                                     collapse = ", "))
   else "every axis maps to a field of the build's own config")
cl <- readLines(file.path(JUL28, "lot", "config.csv"), warn = FALSE)
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

cat("\n-- what the ask wanted that cannot be swept --\n")
# Silently dropping two of the four axes would read as coverage.
rs <- readLines(file.path(ROOT, "run_sensitivity.R"), warn = FALSE)
sn <- readLines(file.path(ROOT, "R", "sensitivity.R"), warn = FALSE)
ok(any(grepl("maintenance-as-LOT", rs, fixed = TRUE)) &&
     any(grepl("maintenance-as-LOT", sn, fixed = TRUE)),
   "maintenance-as-LOT is named as not being a setting, not quietly dropped")
ok(any(grepl("NDMM_FU_CE_COUNTS", rs, fixed = TRUE)),
   "...and CE is pointed at the build that already reports it")
sct <- readLines(file.path(JUL28, "lot", "R", "steps", "05_sct.R"), warn = FALSE)
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
ok(any(grepl("LOT_BUILD_STATUS", rs, fixed = TRUE)) &&
     any(grepl("ORDER BY UPDATED_AT DESC LIMIT 1", rs, fixed = TRUE)),
   "...and its metrics are read against that cell's own run id")
ok(any(grepl('env_flag("SENS_DROP_AFTER")', rs, fixed = TRUE)),
   "dropping a cell's tables is opt-in, not what a measurement script does quietly")

cat("\n", strrep("-", 52), "\n", sep = "")
cat(sprintf("%d passed, %d failed\n", pass, fail))
if (fail > 0L) quit(status = 1L)
