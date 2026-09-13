#!/usr/bin/env Rscript
# The table builder, checked without a warehouse.
#
#   Rscript TFLS/tests/test_tfls.R
#
# Three things are worth testing here and nothing else is. The shell files are
# meant to be edited by hand, so a bad edit has to be refused by name rather
# than produce a quiet empty column. The statistics are arithmetic, so they can
# be held to numbers worked out by hand. And the disclosure rule decides what
# may leave the building, so it is checked at its boundaries and for the two
# ways a withheld cell can be recovered: from its own group, and from an
# identifier that should never have been written.

ROOT <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                                 fixed = TRUE))) else getwd()
  dirname(d)
})

pass <- 0L; fail <- 0L
ok <- function(cond, what) {
  cond <- tryCatch(cond, error = function(e) {
    what <<- paste0(what, "  [raised: ", conditionMessage(e), "]"); FALSE })
  if (isTRUE(cond)) { pass <<- pass + 1L; cat("  ok     ", what, "\n") }
  else              { fail <<- fail + 1L; cat("  FAIL   ", what, "\n") }
}
stops <- function(expr, what) ok(inherits(tryCatch(expr, error = function(e) e), "error"), what)
near <- function(a, b, tol = 1e-6) !is.na(a) && !is.na(b) && abs(a - b) < tol
has <- function(x, s) any(grepl(s, x, fixed = TRUE))

for (f in c("shells.R", "classes.R", "stats.R", "suppress.R", "fill.R", "render.R"))
  source(file.path(ROOT, "R", f))

SHELL_DIR <- file.path(ROOT, "shells")

# A shell directory of our own, so a test can break a file without touching
# the shipped one.
scratch_shells <- function(edit = function(f) invisible(NULL)) {
  d <- file.path(tempdir(), paste0("tfls_", sample.int(1e6, 1)))
  dir.create(d, showWarnings = FALSE, recursive = TRUE)
  for (f in TFLS_SHELL_FILES) file.copy(file.path(SHELL_DIR, f), file.path(d, f))
  edit(d)
  d
}
# Append one raw line to a shell file.
add_line <- function(d, f, line) {
  p <- file.path(d, TFLS_SHELL_FILES[[f]])
  writeLines(c(readLines(p), line), p)
}

cat("\n-- the shipped shells load --\n")
SH <- load_shells(SHELL_DIR)
ok(nrow(SH$tables) > 0 && nrow(SH$rows) > 0 && nrow(SH$columns) > 0,
   "the shells that ship with this folder load without complaint")
ok(all(SH$rows$table_id %in% SH$tables$table_id) &&
     all(SH$columns$table_id %in% SH$tables$table_id),
   "every row and column belongs to a declared table")
ok(all(nzchar(SH$rows$label)), "every row has a label to print")
ok(all(SH$rows$stat[!SH$rows$section_flag & nzchar(SH$rows$source)] %in% tfls_stat_names()),
   "every row that reads something names a statistic the code implements")
# The gap list is the point of the exercise, so it has to be non-empty and
# every one of its rows has to say why.
gap <- SH$rows[!SH$rows$section_flag & !nzchar(SH$rows$source), , drop = FALSE]
ok(nrow(gap) > 0 && all(nzchar(gap$note)),
   sprintf("all %d rows with no source carry a reason", nrow(gap)))

cat("\n-- a bad edit is refused, by file and row --\n")
stops(load_shells(scratch_shells(function(d)
        add_line(d, "rows", "T1,9999,FALSE,Invented,1,mystery_stat,S_DEMOGRAPHICS,SEX=Male,,"))),
      "a row naming a statistic the code does not implement")
stops(load_shells(scratch_shells(function(d)
        add_line(d, "columns", "T1,INVENTED,1L (N=),Invented,99,1L,1,NO_SUCH_CLASS,,"))),
      "a column naming a class that regimen_classes.csv does not define")
stops(load_shells(scratch_shells(function(d)
        add_line(d, "classes", "BAD_CLASS,Bad,11,Not A Study Category,"))),
      "a class mapping onto a category the study does not produce")
stops(load_shells(scratch_shells(function(d)
        add_line(d, "rows", "T1,1,FALSE,Duplicate order,1,n,S_DEMOGRAPHICS,SEX=Male,,"))),
      "two rows of one table claiming the same position")
stops(load_shells(scratch_shells(function(d)
        add_line(d, "tables", "T9,T9. Nothing,A table with no rows,,"))),
      "a table with no rows, which would print as a title over an empty page")
stops(load_shells(file.path(tempdir(), "tfls_absent")),
      "a shell directory that is not there at all")

cat("\n-- measures, filters and unions --\n")
ok(identical(parse_measure("SEX=Female")$column, "SEX") &&
     identical(parse_measure("SEX=Female")$value, "Female"),
   "an equality reads as a column and a value")
ok(identical(parse_measure("AGE_BAND=18-44|45-64|65-74")$value,
             c("18-44", "45-64", "65-74")),
   "a union reads as several values, which is how the shell's '<75 years' is asked for")
ok(identical(parse_measure("MONTHS>=12")$op, ">="),
   "a comparison keeps its operator, which T3's interval columns need")
ok(!nzchar(parse_measure("")$column), "an empty measure names no column, so the row reads its table whole")

cat("\n-- classes map onto the study's own categories --\n")
CL <- SH$classes
ok(class_is_overall("OVERALL"), "the overall column is not a category test")
ok(identical(class_categories("ACD38_QUAD", CL), "Quadruplet with anti-CD38 backbone"),
   "a class resolves to the study category it maps onto")
ok(length(class_categories("BISPECIFIC", CL)) == 2,
   "a class may roll up more than one category")
ok(!any(class_categories("BCMA", CL) %in% class_categories("BISPECIFIC", CL)),
   "BCMA and Bi-specific share no category, so a patient is counted in one column only")
ok(in_class("Doublet/monotherapy", "DOUBLET_MONO", CL) &&
     !in_class("Doublet/monotherapy", "ACD38_QUAD", CL),
   "membership is decided by the category the study assigned")
ok(length(class_categories("POM_TRIP", CL)) == 0,
   "the pomalidomide column maps onto nothing, because the study vocabulary has no such category")
ok(length(unknown_soc_categories("CAR-T|Doublet/monotherapy")) == 0,
   "the study's own categories are recognised")
ok(length(unknown_soc_categories("Quadruplet with anti-CD39 backbone")) == 1,
   "...and a misspelled one is caught, since it would silently empty a column")

cat("\n-- the statistics, against numbers worked out by hand --\n")
ok(identical(stat_n_pct(c(TRUE, TRUE, FALSE, FALSE), denom = 4)$text, "2 (50.0%)"),
   "n_pct: 2 of 4 is 2 (50.0%)")
ok(identical(stat_n_pct(logical(0), denom = 10)$text, "0 (0.0%)"),
   "...and nobody is zero, not a blank")
ok(identical(stat_n(c(TRUE, TRUE, TRUE))$text, "3"), "n counts the hits")
# mean 3, sd of 1..5 = sqrt(2.5) = 1.5811
ok(identical(stat_mean_sd(1:5)$text, "3.0 (1.6)"), "mean_sd: 1..5 is 3.0 (1.6)")
# median 3, quartiles of 1..5 are 2 and 4 under R's default type-7
ok(identical(stat_median_iqr(1:5)$text, "3.0 (2.0, 4.0)"),
   "median_iqr: 1..5 is 3.0 (2.0, 4.0)")
ok(identical(stat_min_max(c(4, 1, 9))$text, "1.0, 9.0"), "min_max takes the ends")
ok(near(stat_mean_sd(c(2, NA, 4))$value, 3), "a missing value is left out rather than read as zero")
ok(!stat_mean_sd(numeric(0))$ok && nzchar(stat_mean_sd(numeric(0))$why),
   "nothing to average is refused with a reason, not reported as zero")

cat("\n-- Kaplan-Meier, on a curve small enough to check by hand --\n")
# Five patients: events at 1 and 4, censored at 2, 3 and 5.
#   t=1: at risk 5, 1 event -> S = 4/5 = 0.8
#   t=4: at risk 2, 1 event -> S = 0.8 * 1/2 = 0.4
T5 <- c(1, 2, 3, 4, 5); E5 <- c(1, 0, 0, 1, 0)
km <- km_estimate(T5, E5)
ok(nrow(km) == 2 && near(km$SURV[1], 0.8) && near(km$SURV[2], 0.4),
   "the curve steps only at events: 0.8 then 0.4")
ok(km$N_RISK[1] == 5 && km$N_RISK[2] == 2,
   "the risk set drops for censored patients as well as for events")
ok(near(km_prob_at(km, 1)$surv, 0.8) && near(km_prob_at(km, 3)$surv, 0.8) &&
     near(km_prob_at(km, 4)$surv, 0.4),
   "the probability between two events is the earlier one, not an interpolation")
ok(!km_prob_at(km, 99)$ok && has(km_prob_at(km, 99)$why, "past the observed follow-up"),
   "a landmark past the observed follow-up is refused rather than extrapolated")
ok(near(km_median(km), 4),
   "the median is the first time the curve reaches or passes one half")
ok(is.na(km_median(km_estimate(c(1, 2, 3), c(1, 0, 0)))),
   "a curve that never reaches one half has no median, and says so")
ok(identical(stat_km_median(c(1, 2, 3), c(1, 0, 0))$text, "not reached"),
   "...which prints as 'not reached', never as a blank or a zero")
ok(identical(stat_km_events(T5, E5)$text, "2 (40.0%)") &&
     identical(stat_km_censored(T5, E5)$text, "3 (60.0%)"),
   "events and censored are counted against the same denominator and sum to it")
ok(has(stat_km_median(T5, E5)$text, "4.0"),
   "the median cell prints the median it computed")
ci <- km_median_ci(km)
ok(near(ci[1], 1) && is.na(ci[2]),
   "the median interval reaches its lower bound and says the upper is not reached")
ok(all(km$LOWER <= km$SURV + 1e-9) && all(km$UPPER >= km$SURV - 1e-9),
   "the confidence band contains its own estimate")
ok(all(km$LOWER >= 0) && all(km$UPPER <= 1),
   "...and stays inside nought and one, which a naive band does not")

cat("\n-- the disclosure rule --\n")
ok(tfls_floor(5) == 25L, "a floor under the package's own is raised to it")
ok(tfls_floor(50) == 50L, "a higher floor is taken as asked")
ok(tfls_floor(NA) == 25L, "an unreadable floor falls back to the package's")
stops(tfls_floor_from_env("banana"), "a floor that is not a number is refused rather than ignored")
ok(tfls_floor_from_env("40") == 40L, "a floor from the environment is honoured when it raises")
ok(tfls_floor_from_env("3") == 25L, "...and cannot be used to lower the floor")
ok(!tfls_released(24, 25) && tfls_released(25, 25),
   "the floor is a minimum, so exactly the floor is released")
ok(!tfls_released(NA, 25),
   "a denominator nobody can read has not been shown to clear the floor")
ok(identical(suppressed_text(25), "<25"),
   "a withheld cell prints as '<25', which cannot be read as zero")

# Three levels of one variable, down one column: 100, 10 and 90 of 200. The
# middle one is under the floor, and publishing the other two beside the
# column total would give it away as the difference.
cells <- empty_cells()
for (i in 1:3) cells <- rbind(cells, data.frame(
  TABLE_ID = "T", ROW_ORDER = i, ROW_LABEL = c("Male", "Female", "Unknown")[i],
  INDENT = 1L, SECTION = 0L, SECTION_LABEL = "Sex (N%)", NOTE = "",
  STAT = "n_pct", SOURCE = "S_X", MEASURE = "M", COLUMN_ORDER = 1L,
  COLUMN_ID = "a", COLUMN_LABEL = "Overall", COLUMN_GROUP = "1L",
  VALUE = c(100, 10, 90)[i], LOW = NA_real_, HIGH = NA_real_,
  N = c(100, 10, 90)[i], DENOM = 200, TEXT = "x", FILLED = 1L,
  SUPPRESSED = 0L, REASON = "", REASON_KIND = "", stringsAsFactors = FALSE))
sup <- suppress_cells(cells, 25)
ok(sup$SUPPRESSED[2] == 1L, "a cell of ten patients is withheld at a floor of 25")
ok(sum(sup$SUPPRESSED) >= 2,
   "...and a second cell goes with it, or the withheld one is the column total minus the rest")
ok(sup$SUPPRESSED[3] == 1L,
   "the second is the smallest of those left, which is the one that hides the most")
ok(all(sup$TEXT[sup$SUPPRESSED == 1L] == "<25"),
   "every withheld cell says so in the same words")
ok(all(nzchar(sup$REASON[sup$SUPPRESSED == 1L])),
   "...and carries the reason it was withheld")
ok(all(is.na(sup$N[sup$SUPPRESSED == 1L])) && all(is.na(sup$VALUE[sup$SUPPRESSED == 1L])),
   "a withheld cell keeps no number behind the text")
# Two levels: withholding one has to withhold the other, which takes the whole
# variable with it. That is the right answer, not an over-reaction.
two <- suppress_cells(cells[1:2, , drop = FALSE], 25)
ok(all(two$SUPPRESSED == 1L),
   "with only two levels, one under the floor takes the variable with it")

cat("\n-- nothing patient-level can be written --\n")
ok(identical(names(drop_identifiers(data.frame(PATID = 1, N = 2))), "N"),
   "an identifier column is dropped on the way out")
stops(assert_no_identifiers(data.frame(PATID = "x", N = 1)),
   "and a frame that still carries one stops the run rather than being written")
ok(isTRUE(assert_no_identifiers(data.frame(COHORT = "1L", N = 1))) ||
     is.null(assert_no_identifiers(data.frame(COHORT = "1L", N = 1))),
   "a frame with no identifier passes")

cat("\n-- filling a table, from a reader that is not a warehouse --\n")
# One cohort, six patients, three of them women; four in a doublet, two in a
# quad. Small enough to hand-count, and under the floor on purpose.
DEMO <- data.frame(
  PATID = sprintf("p%02d", 1:6), COHORT = "1L", LOT_NUM = 1L,
  AGE_YEARS = c(60, 70, 80, 55, 66, 77),
  AGE_BAND = c("45-64", "65-74", "75+", "45-64", "65-74", "75+"),
  SEX = c("Female", "Female", "Female", "Male", "Male", "Male"),
  stringsAsFactors = FALSE)
SOC <- data.frame(
  PATID = sprintf("p%02d", 1:6), COHORT = "1L", LOT_NUM = 1L,
  REGIMEN = c("DARA BORT LENA DEX", "DARA BORT LENA DEX", "LENA DEX",
              "LENA DEX", "POM DEX", "POM DEX"),
  N_AGENTS = c(4L, 4L, 2L, 2L, 2L, 2L),
  SOC_CATEGORY = c(rep("Quadruplet with anti-CD38 backbone", 2),
                   rep("Doublet/monotherapy", 4)),
  MATCHED = 1L, stringsAsFactors = FALSE)
reader <- function(name) switch(toupper(name),
  S_DEMOGRAPHICS = DEMO, S_SOC = SOC, NULL)
ctx <- fill_context(reader, SH$classes)

write_shells <- function(rows_extra = character(0), rows_edit = identity) {
  d <- file.path(tempdir(), paste0("tfls_x_", sample.int(1e6, 1)))
  dir.create(d, showWarnings = FALSE, recursive = TRUE)
  writeLines(c("table_id,sheet,title,objective,notes",
               "X,x,A test table,,"), file.path(d, "tables.csv"))
  writeLines(c("table_id,col_id,group,label,order,cohort,lot_num,class,subgroup,period",
               "X,ALL,1L (N=),Overall,1,1L,1,OVERALL,,",
               "X,QUAD,1L (N=),aCD38 Quad,2,1L,1,ACD38_QUAD,,"),
             file.path(d, "columns.csv"))
  rows <- rows_edit(c(
    "table_id,order,section,label,indent,stat,source,measure,filter,note",
    "X,1,TRUE,Sex (N%),0,,,,,",
    "X,2,FALSE,Female,1,n_pct,S_DEMOGRAPHICS,SEX=Female,,",
    "X,3,FALSE,Male,1,n_pct,S_DEMOGRAPHICS,SEX=Male,,",
    "X,4,FALSE,Age at index,0,mean_sd,S_DEMOGRAPHICS,AGE_YEARS,,"))
  writeLines(c(rows, rows_extra), file.path(d, "rows.csv"))
  file.copy(file.path(SHELL_DIR, "regimen_classes.csv"), file.path(d, "regimen_classes.csv"))
  writeLines("table_id,marker,text", file.path(d, "footnotes.csv"))
  load_shells(d)
}
sh1 <- write_shells()
f1 <- fill_table(sh1, "X", ctx, floor_n = 1)
cell_of <- function(f, ord, col) {
  r <- f$cells[f$cells$ROW_ORDER == ord & f$cells$COLUMN_ID == col, , drop = FALSE]
  if (!nrow(r)) NA_character_ else r$TEXT[1]
}
ok(identical(cell_of(f1, 2, "ALL"), "3 (50.0%)"),
   "three women of six is 3 (50.0%) in the overall column")
ok(identical(cell_of(f1, 3, "ALL"), "3 (50.0%)"), "and three men likewise")
# The quad column holds two patients, both women, so the men are none. At a
# floor of 1 the empty cell is withheld, and withholding one of two levels
# would give it away against the column total, so the other goes too. Both
# cells of that block are withheld, which is the rule working rather than a
# lost number.
ok(identical(cell_of(f1, 3, "QUAD"), "<1"),
   "a column where nobody has the level withholds it rather than printing a zero")
ok(identical(cell_of(f1, 2, "QUAD"), "<1"),
   "...and the one remaining level goes with it, since the column total would give it away")
ok(identical(cell_of(f1, 2, "ALL"), "3 (50.0%)") && identical(cell_of(f1, 3, "ALL"), "3 (50.0%)"),
   "the overall column, where both levels clear the floor, publishes both")
ok(identical(cell_of(f1, 4, "ALL"), "68.0 (9.7)"),
   "the mean age of the six is 68.0 with an SD of 9.7")
ok(!any(f1$cells$ROW_ORDER == 1 & f1$cells$SECTION == 0L),
   "a heading row occupies no cell of its own")
ok(!"PATID" %in% names(f1$cells) && !"PATID" %in% names(f1$unfilled),
   "nothing the filler returns carries a patient identifier")

f2 <- fill_table(sh1, "X", ctx, floor_n = 25)
live2 <- f2$cells$FILLED == 1L & f2$cells$SECTION == 0L
ok(all(f2$cells$SUPPRESSED[live2] == 1L) && all(f2$cells$TEXT[live2] == "<25"),
   "the same table under the real floor withholds every cell, since six patients is under it")

cat("\n-- a row nothing can fill is reported, never blanked --\n")
sh2 <- write_shells(rows_extra =
  "X,5,FALSE,Year of MM diagnosis,1,n_pct,,,,the study output carries no diagnosis date")
f3 <- fill_table(sh2, "X", ctx, floor_n = 1)
ok(nrow(f3$unfilled) >= 1, "the row with no source comes back on the unfilled list")
ok(has(paste(f3$unfilled$REASON, f3$unfilled$REASON_KIND), "no source") ||
     has(f3$unfilled$REASON, "diagnosis"),
   "...with a reason, so the gap is readable rather than a blank line")
sh3 <- write_shells(rows_edit = function(r) sub("SEX=Female", "SEX=Nonexistent", r, fixed = TRUE))
f4 <- fill_table(sh3, "X", ctx, floor_n = 1)
ok(identical(cell_of(f4, 2, "ALL"), "<1") || identical(cell_of(f4, 2, "ALL"), "0 (0.0%)"),
   "a measure that matches nobody is a withheld or an explicit zero, never a blank")
sh4 <- write_shells(rows_edit = function(r)
  sub(",S_DEMOGRAPHICS,SEX=Female", ",S_NOT_A_TABLE,SEX=Female", r, fixed = TRUE))
f5 <- fill_table(sh4, "X", ctx, floor_n = 1)
ok(nrow(f5$unfilled) >= 1 && has(f5$unfilled$SOURCE, "S_NOT_A_TABLE"),
   "a row naming a table the run did not write names it in the reason")

cat("\n-- rendering keeps the shell's shape --\n")
md <- render_markdown(f1, sh1)
ok(has(md, "Sex (N%)") && has(md, "Female") && has(md, "Male"),
   "every row of the shell reaches the page")
ok(which(grepl("Sex (N%)", md, fixed = TRUE))[1] <
     which(grepl("Female", md, fixed = TRUE))[1],
   "in the shell's order, heading before its rows")
ok(has(md, "Overall") && has(md, "aCD38 Quad"), "and both columns are headed")
cap <- render_caption(f2)
ok(has(cap, "25"), "the caption names the floor the table was built under")
csv <- render_csv(f1)
ok(is.data.frame(csv) && nrow(csv) > 0 && !"PATID" %in% names(csv),
   "the CSV rendering carries the same cells and no identifier")

cat(sprintf("\n%d passed, %d failed\n", pass, fail))
if (fail > 0L) quit(status = 1L)
