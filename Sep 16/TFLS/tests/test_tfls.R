#!/usr/bin/env Rscript
# The shells, the statistics and the disclosure rule, checked without a
# warehouse.
#
#   Rscript TFLS/tests/test_tfls.R
#
# Four kinds of test. The shell files as data: what is refused, and that the
# refusal names the file and the row, because these files are edited by hand.
# The statistics against numbers worked out by hand, Kaplan-Meier included.
# The disclosure rule, cell by cell, including the floor that may only rise and
# the second cell that goes with a lone withheld one. And a whole table filled
# from frames small enough to count on one page, to see that a row nothing can
# fill says so and that nothing patient-level reaches the output.
#
# Nothing here connects to anything. Exit status is 1 if any check fails.

ROOT <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  # Rscript renders a space in a path as ~+~, so a folder with one in its name
  # resolves to nothing without this.
  d <- if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                                 fixed = TRUE))) else getwd()
  dirname(d)
})

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
  # Evaluated HERE, so an assertion whose expression raises is a failed
  # assertion rather than a dead run.
  cond <- tryCatch(cond, error = function(e) {
    what <<- paste0(what, "  [raised: ", conditionMessage(e), "]")
    FALSE
  })
  if (isTRUE(cond)) { pass <<- pass + 1L; cat("  ok     ", what, "\n") }
  else              { fail <<- fail + 1L; cat("  FAIL   ", what, "\n") }
}
stops <- function(expr, what)
  ok(inherits(tryCatch(expr, error = function(e) e), "error"), what)
stops_with <- function(expr, txt, what) {
  e <- tryCatch(expr, error = function(e) e)
  ok(inherits(e, "error") && all(vapply(txt, function(s)
    grepl(s, conditionMessage(e), fixed = TRUE), logical(1))),
    paste0(what, if (inherits(e, "error")) "" else "  [did not stop]"))
}
has <- function(x, s) grepl(s, x, fixed = TRUE)
near <- function(a, b, tol = 1e-6) !is.na(a) && !is.na(b) && abs(a - b) < tol

for (f in c("classes.R", "shells.R", "names.R", "stats.R", "suppress.R",
            "fill.R", "scope.R", "render.R", "publish.R"))
  source(file.path(ROOT, "R", f))

# The runner's functions, loaded without running the run. run_tfls.R ends by
# calling main() when it is not interactive, so it cannot be sourced from
# here; instead every top-level `name <- function(...)` in it is evaluated
# into an environment whose parent is this session, where R/ is already
# loaded, and the two globals a function reads are set by the test.
#
# Every check of the runner above this point reads it as text, and text is how
# a line survives that refers to a variable defined somewhere else: it parses,
# it reads as right, and it raises the first time the function runs.
runner_env <- function(out) {
  env <- new.env(parent = globalenv())
  for (ex in parse(file.path(ROOT, "run_tfls.R"), keep.source = FALSE)) {
    is_fn <- is.call(ex) && identical(ex[[1]], as.name("<-")) &&
      is.call(ex[[3]]) && identical(ex[[3]][[1]], as.name("function"))
    if (is_fn) eval(ex, env)
  }
  env$out_dir <- out
  env$shells_dir <- file.path(ROOT, "shells")
  env
}


# --- a shell set, written to a temporary directory ---------------------------
#
# Small enough to read, and every test that needs a broken shell starts from
# this one and breaks exactly one thing.

BASE <- list(
  tables = c(
    "table_id,sheet,title,objective,notes",
    "T1,T1,Baseline,Primary objective,Rows are the shell's own."),
  columns = c(
    "table_id,col_id,group,label,order,cohort,lot_num,class,subgroup,period",
    "T1,C1,1L (N=),Overall,1,1L,1,OVERALL,,",
    "T1,C2,1L (N=),Quad,2,1L,1,ACD38_QUAD,,",
    "T1,C3,1L (N=),Pom triplet,3,1L,1,POM_TRIP,,",
    "T1,C4,1L (N=),Gap,4,1L,1,GAP,,"),
  rows = c(
    "table_id,order,section,label,indent,stat,source,measure,filter,note",
    "T1,1,TRUE,Sex,0,,,,,",
    "T1,2,FALSE,Female,1,n_pct,S_DEMOGRAPHICS,SEX=Female,,",
    "T1,3,FALSE,Male,1,n_pct,S_DEMOGRAPHICS,SEX=Male,,",
    "T1,4,TRUE,Race,0,,,,,",
    "T1,5,FALSE,White,1,n_pct,S_DEMOGRAPHICS,RACE=White,,",
    "T1,6,FALSE,Black,1,n_pct,S_DEMOGRAPHICS,RACE=Black,,",
    "T1,7,FALSE,Asian,1,n_pct,S_DEMOGRAPHICS,RACE=Asian,,",
    "T1,8,TRUE,Age,0,,,,,",
    "T1,9,FALSE,Mean (SD),1,mean_sd,S_DEMOGRAPHICS,AGE_YEARS,,a",
    "T1,10,FALSE,Height,1,n_pct,S_DEMOGRAPHICS,HEIGHT_CM=tall,,",
    "T1,11,FALSE,Nothing behind this,1,n,,,,"),
  regimen_classes = c(
    "class_id,label,order,soc_categories,requires_drug,note",
    "OVERALL,Overall,1,,,The column total.",
    "ACD38_QUAD,Quad,2,Quadruplet with anti-CD38 backbone,,",
    "POM_TRIP,Pom triplet,3,Other triplet (non-anti-CD38),POM,",
    "BOTH,Quad or doublet,4,Quadruplet with anti-CD38 backbone|Doublet/monotherapy,,",
    "GAP,Gap,5,,,No category covers this heading yet."),
  footnotes = c("table_id,marker,text", "T1,a,Age is age at index."))

write_shells <- function(parts = list(), dir = tempfile("tfls_shells")) {
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  spec <- utils::modifyList(BASE, parts)
  for (nm in names(TFLS_SHELL_FILES))
    writeLines(spec[[nm]], file.path(dir, TFLS_SHELL_FILES[[nm]]))
  dir
}

# One line of a CSV with one field replaced, so a broken shell differs from the
# good one in exactly the thing being tested.
edit_field <- function(line, i, value) {
  f <- strsplit(line, ",", fixed = TRUE)[[1]]
  f[i] <- value
  paste(f, collapse = ",")
}

cat("\n-- the shells load, and say what is wrong when they do not --\n")
SH <- load_shells(write_shells())
ok(nrow(SH$tables) == 1 && nrow(SH$rows) == 11 && nrow(SH$columns) == 4,
   "a shell set loads: one table, eleven rows, four columns")
ok(identical(SH$rows$order_n, 1:11) && identical(SH$columns$order_n, 1:4),
   "the orders come back as whole numbers, in the shell's order")
ok(identical(SH$rows$section_flag, c(TRUE, FALSE, FALSE, TRUE, FALSE, FALSE,
                                     FALSE, TRUE, FALSE, FALSE, FALSE)),
   "the section flags are read as TRUE and FALSE, not as text")
stops_with(load_shells(write_shells(list(rows = c(BASE$rows[1:2],
             edit_field(BASE$rows[3], 6, "geometric_mean"), BASE$rows[4:12])))),
  c("shells/rows.csv row 2", "geometric_mean", "not implemented"),
  "a statistic the code does not implement stops the run, naming the file, the row and what is available")
stops_with(load_shells(write_shells(list(columns = c(BASE$columns[1:2],
             edit_field(BASE$columns[3], 8, "NOT_A_CLASS"), BASE$columns[4:5])))),
  c("shells/columns.csv row 2", "NOT_A_CLASS"),
  "a column naming a class that is neither defined nor a SOC category stops the run")
stops_with(load_shells(write_shells(list(rows = c(BASE$rows[1:3],
             edit_field(BASE$rows[4], 2, "2"), BASE$rows[5:12])))),
  c("shells/rows.csv", "order 2"),
  "two rows at one order in one table stop the run")
stops_with(load_shells(write_shells(list(columns = c(BASE$columns[1:3],
             edit_field(BASE$columns[4], 5, "2"), BASE$columns[5])))),
  c("shells/columns.csv", "order 2"),
  "...and so do two columns at one order")
stops_with(load_shells(write_shells(list(rows = c(BASE$rows[1:2],
             edit_field(BASE$rows[3], 8, "=Female"), BASE$rows[4:12])))),
  c("shells/rows.csv row 2", "measure that cannot be read"),
  "a measure with no column on the left of its comparison stops the run")
stops_with(load_shells(write_shells(list(rows = c(BASE$rows[1:2],
             edit_field(BASE$rows[3], 9, "PERIOD="), BASE$rows[4:12])))),
  c("shells/rows.csv row 2", "filter that cannot be read"),
  "...and a filter naming no value does too")
stops_with(load_shells(write_shells(list(
             tables = c(BASE$tables, "T2,T2,A table with no rows,,")))),
  c("shells/tables.csv", "T2", "no rows"),
  "a table_id with no rows stops the run")
stops_with(load_shells(write_shells(list(regimen_classes = c(
             BASE$regimen_classes[1:2],
             "ACD38_QUAD,Quad,2,Quadruplet with an anti-CD38 backbone,,",
             BASE$regimen_classes[4:6])))),
  c("shells/regimen_classes.csv row 2", "which the study does not write"),
  "a class mapped to a category the study never writes stops the run, so a typo cannot empty a column quietly")
stops_with(load_shells(write_shells(list(regimen_classes = c(
             BASE$regimen_classes[1:5], "POMONLY,Pom only,6,,POM,")))),
  c("shells/regimen_classes.csv row 5", "names no SOC category"),
  "a class that requires a drug but names no category stops the run: a drug alone is a second classifier")
stops_with(load_shells(write_shells(list(regimen_classes = c(
             BASE$regimen_classes[1:3],
             "POM2,Pom triplet,4,Other triplet (non-anti-CD38),POM BORT,",
             BASE$regimen_classes[5:6])))),
  c("shells/regimen_classes.csv row 3", "not a single drug abbreviation"),
  "...and so does a requires_drug holding two abbreviations")
stops_with(load_shells(write_shells(list(rows = c(BASE$rows[1:2],
             edit_field(BASE$rows[3], 1, "T9"), BASE$rows[4:12])))),
  c("shells/rows.csv row 2", "T9", "not in tables.csv"),
  "a row belonging to no table stops the run")
stops_with(load_shells(write_shells(list(rows = c(BASE$rows[1:2],
             edit_field(BASE$rows[3], 5, "7"), BASE$rows[4:12])))),
  c("shells/rows.csv row 2", "indent"),
  "an indent outside 0 to 2 stops the run")
stops_with(load_shells(write_shells(list(rows = c(BASE$rows[1:2],
             edit_field(BASE$rows[3], 3, "maybe"), BASE$rows[4:12])))),
  c("shells/rows.csv row 2", "not TRUE or FALSE"),
  "a section flag that is neither TRUE nor FALSE stops the run")
ok(inherits(tryCatch(load_shells(tempfile("nothing_here")),
                     error = function(e) e), "tfls_missing_shells"),
   "a shells directory that is not written yet is a condition of its own, so a runner can tell it from a broken file")

cat("\n-- measures, filters and subgroups --\n")
ok({ m <- parse_measure("SEX=Female")
     m$ok && m$column == "SEX" && m$op == "=" && identical(m$value, "Female") },
   "a measure splits into a column and a value")
ok({ m <- parse_measure("AGE_YEARS"); m$ok && m$column == "AGE_YEARS" &&
       !length(m$value) }, "a measure may be a column on its own")
ok({ m <- parse_measure("AGE_BAND=18-44|45-64|65-74")
     m$ok && identical(m$value, c("18-44", "45-64", "65-74")) },
   "a measure may name a union of values, which is how a shell asks for a band the study does not have")
ok({ m <- parse_measure("AGE_BAND=<75 years")
     m$ok && m$column == "AGE_BAND" && m$op == "=" &&
       identical(m$value, "<75 years") },
   "a value that looks like a comparison is a value: the band is not cut at its own '<'")
ok({ m <- parse_measure("AGE_YEARS>=75")
     m$ok && m$op == ">=" && identical(m$value, "75") },
   "a comparison on a number is read as one")
ok(!parse_measure("=Female")$ok && !parse_measure("SEX=")$ok &&
     !parse_measure("A B=1")$ok,
   "a measure with no column, no value, or a column that is not a name is refused")
ok({ f <- parse_filter("TTE_ELIGIBLE=1&MONTHS=12")
     length(f) == 2 && f[[2]]$column == "MONTHS" && f[[2]]$value == "12" },
   "a filter is any number of terms, separated by & or ;")
ok({ s <- parse_subgroup("S_COMORB_SUBGROUP:CONCEPT=neuropathy&HAS_HISTORY=1")
     s$ok && s$table == "S_COMORB_SUBGROUP" && length(s$terms) == 2 },
   "a subgroup may name the table it is on and several restrictions on it")
ok({ s <- parse_subgroup("S_MALIGNANCY:LOT_AFTER_WHICH>=2")
     s$ok && s$table == "S_MALIGNANCY" && s$terms[[1]]$op == ">=" },
   "...and the restriction may be a comparison on a number, not only a flag")
ok(!parse_subgroup("S_X:")$ok,
   "a subgroup naming a table and no restriction on it is refused")

cat("\n-- the regimen classes are a mapping onto the study's own categories --\n")
CL <- SH$classes
ok(identical(class_selection("OVERALL", CL)$kind, "all"),
   "OVERALL matches by definition: it is the column total, not a rule")
ok({ s <- class_selection("ACD38_QUAD", CL)
     identical(s$kind, "categories") &&
       identical(s$categories, "Quadruplet with anti-CD38 backbone") },
   "a class resolves to the SOC category it maps to")
ok({ s <- class_selection("BOTH", CL)
     identical(s$kind, "categories") && length(s$categories) == 2 },
   "a class may map to more than one category")
ok({ s <- class_selection("Doublet/monotherapy", CL)
     identical(s$kind, "categories") &&
       identical(s$categories, "Doublet/monotherapy") },
   "a column may name a SOC category straight out, without a class for it")
ok({ s <- class_selection("GAP", CL)
     identical(s$kind, "unmapped") && has(s$why, "no SOC category") },
   "a class mapped to nothing is unmapped, not empty: the cells say so rather than printing a zero")
ok(identical(class_selection("Quadruplet", CL)$kind, "unknown"),
   "a name that is neither a class nor a category is a defect in the shell")
ok({ s <- class_selection("POM_TRIP", CL)
     identical(s$categories, "Other triplet (non-anti-CD38)") && s$drug == "POM" },
   "a class may refine the study's category with a drug the regimen has to hold")
ok(identical(regimen_has_drug(c("POM BORT DEX", "BORT LEN DEX", "POMX DEX"), "POM"),
             c(TRUE, FALSE, FALSE)),
   "the drug is matched as a whole agent, so POM does not match POMX")
ok(identical(regimen_has_drug("dara bort len dex", "DARA"), TRUE),
   "...and the regimen is read whatever case it is written in")
ok(identical(class_categories("ACD38_QUAD", CL), "Quadruplet with anti-CD38 backbone") &&
     identical(class_label("ACD38_QUAD", CL), "Quad"),
   "a class carries the heading it prints under")

cat("\n-- the statistics, against numbers worked out by hand --\n")
ok({ s <- stat_n_pct(c(TRUE, TRUE, FALSE, FALSE, FALSE))
     s$n == 2 && s$denom == 5 && near(s$low, 40) && s$text == "2 (40.0%)" },
   "n_pct over five rows, two of them the level: 2 (40.0%)")
ok({ s <- stat_n_pct(3, denom = 12); s$text == "3 (25.0%)" },
   "...or from a count and a denominator the study table already carries")
ok({ s <- stat_n(c(TRUE, TRUE, FALSE)); s$n == 2 && s$text == "2" },
   "n is the count alone")
ok({ s <- stat_n_distinct(c("LEN DEX", "LEN DEX", "POM DEX"))
     s$n == 2 && s$text == "2" },
   "n_distinct counts the values a column takes, not the rows holding them: two regimens over three lines")
ok(stat_n_distinct(rep("LEN DEX", 100))$n == 1,
   "...so a hundred patients all on one regimen are one regimen")
ok(stat_n_distinct(c("LEN DEX", "", NA, "POM DEX"))$n == 2,
   "a line the study left empty names no regimen, so it is not counted as one")
ok({ s <- stat_mean_sd(c(1, 2, 3, 4, 5))
     near(s$value, 3) && near(s$low, sqrt(2.5)) && s$text == "3.0 (1.6)" },
   "mean_sd of 1..5 is 3 and the sample SD sqrt(2.5) = 1.58")
ok(!stat_mean_sd(numeric(0))$ok, "a mean over nothing is refused, not zero")
ok({ s <- stat_median_iqr(c(1, 2, 3, 4, 5))
     near(s$value, 3) && near(s$low, 2) && near(s$high, 4) &&
       s$text == "3.0 (2.0, 4.0)" },
   "median_iqr of 1..5 is 3 (2, 4)")
ok({ s <- stat_median_iqr(c(1, 2, 3, 4))
     near(s$value, 2.5) && near(s$low, 1.75) && near(s$high, 3.25) },
   "...and of 1..4 is 2.5 (1.75, 3.25), the quantiles R's default gives")
ok({ s <- stat_min_max(c(4, 1, 9))
     near(s$value, 1) && near(s$high, 9) && s$text == "1.0, 9.0" },
   "min_max is the two ends")
ok({ s <- stat_rate(events = 20, person_years = 200)
     near(s$value, 10000) && s$text == "10,000.00" },
   "a rate from 20 events in 200 person-years is 10,000 per 100,000 - the study's multiplier")
ok({ s <- stat_rate(rate = 12.5, events = 1, person_years = 2)
     near(s$value, 12.5) },
   "where the study table carries the rate, that is the rate: it is not recomputed from rounded parts")
ok(!stat_rate()$ok, "a rate with nothing behind it is refused")

cat("\n-- Kaplan-Meier, on a curve that can be checked by hand --\n")
# Six subjects, an event at each of 1..6. The estimator multiplies 5/6, 4/5,
# 3/4, 2/3, 1/2, 0/1, so survival is 5/6, 2/3, 1/2, 1/3, 1/6, 0.
K <- km_estimate(1:6, rep(1, 6))
ok(nrow(K) == 6 && identical(K$TIME, as.numeric(1:6)) &&
     all(K$N_RISK == c(6, 5, 4, 3, 2, 1)),
   "one row per event time, with the number still at risk at each")
ok(all(vapply(seq_len(6), function(i)
       near(K$SURV[i], c(5/6, 2/3, 1/2, 1/3, 1/6, 0)[i]), logical(1))),
   "the survival at each step is the running product of (1 - d/n)")
ok(near(km_median(K), 3),
   "the median is the first time the curve is at or below 0.5, which is 3")
# Greenwood at t = 1 is 1/(6*5) = 0.0333; se on the log-log scale is
# sqrt(0.0333)/|log(5/6)| = 1.0014, so the band is S^exp(+/-1.96 se) =
# 0.8333^7.1197 = 0.2731 and 0.8333^0.1405 = 0.9747.
ok(near(K$LOWER[1], 0.2731, 1e-4) && near(K$UPPER[1], 0.9747, 1e-4),
   "the band at the first step is Greenwood's variance on the log-log scale: 0.2731 to 0.9747")
ok({ ci <- km_median_ci(K)
     near(ci[1], 1) && is.na(ci[2]) },
   "the interval around the median runs from the first time the band's lower limit reaches 0.5 (t = 1) and has no upper end here, because the band's upper limit never does")
ok({ s <- stat_km_median(1:6, rep(1, 6))
     s$text == "3.0 (1.0, not reached)" },
   "...and the cell says so rather than inventing a bound the follow-up does not reach")
# Five subjects, events at 1 and 3, the rest censored: 4/5 then 2/3 of that.
C <- km_estimate(c(1, 2, 3, 4, 5), c(1, 0, 1, 0, 0))
ok(nrow(C) == 2 && near(C$SURV[1], 0.8) && near(C$SURV[2], 0.8 * 2/3) &&
     C$N_RISK[2] == 3,
   "a censored subject leaves the risk set without a step: S is 0.8 then 0.533")
ok(is.na(km_median(C)) && stat_km_median(c(1,2,3,4,5), c(1,0,1,0,0))$text ==
     "not reached (1.0, not reached)",
   "a curve that never reaches 0.5 has no median, which is an answer and not a gap - and the interval keeps the bound the band does reach")
# The reviewer's case. A hundred subjects, 45 events - 35 in the first month
# and ten in the second - and 55 censored at ten months. The curve floors at
# 0.55 and never reaches a half, so there is no median; the band's lower limit
# passes 0.5 at the second month, and that is a bound the data supports.
R100 <- c(rep(1, 35), rep(2, 10), rep(10, 55))
E100 <- c(rep(1, 45), rep(0, 55))
ok({ ci <- km_median_ci(km_estimate(R100, E100)); near(ci[1], 2) && is.na(ci[2]) },
   "a median out of reach can still have a lower bound: the band reaches 0.5 at two months where the curve never does")
ok(identical(stat_km_median(R100, E100)$text, "not reached (2.0, not reached)"),
   "...and the cell keeps it, rather than dropping the whole interval and throwing away the one bound the follow-up supports")
ok({ s <- stat_km_median(R100, E100)
     is.na(s$value) && near(s$low, 2) && is.na(s$high) && s$n == 45 },
   "the bound reaches the cell's own columns as well as its text, so the CSV carries it too")
ok({ p <- km_prob_at(C, 2); isTRUE(p$ok) && near(p$surv, 0.8) },
   "the probability at a month is the step in force then")
ok({ p <- km_prob_at(C, 0.5)
     isTRUE(p$ok) && near(p$surv, 1) && is.na(p$lower) },
   "before the first event the estimate is 1 and the band is not a pair of ones")
ok(!isTRUE(km_prob_at(C, 9)$ok),
   "past the observed follow-up there is nothing to read, and the caller is told rather than handed the last step")
ok({ s <- stat_km_prob(c(1, 2, 3, 4, 5), c(1, 0, 1, 0, 0), 2)
     near(s$value, 80) && s$text == "80.0 (20.4, 96.9)" },
   "km_prob at 2 months is 80.0% with the Greenwood band 20.4 to 96.9")
ok({ e <- stat_km_events(c(1, 2, 3, 4, 5), c(1, 0, 1, 0, 0))
     cs <- stat_km_censored(c(1, 2, 3, 4, 5), c(1, 0, 1, 0, 0))
     e$n == 2 && cs$n == 3 && e$text == "2 (40.0%)" && cs$text == "3 (60.0%)" },
   "the events and the censorings are counted, and they sum to the curve's population")
T2 <- km_estimate(c(2, 2, 5, 5, 9), c(1, 1, 0, 1, 0))
ok(nrow(T2) == 2 && near(T2$SURV[1], 0.6) && near(T2$SURV[2], 0.4) &&
     T2$N_EVENT[1] == 2,
   "two events at one time are one step of 2/5, and a censoring at an event time stays at risk for it")
N0 <- km_estimate(c(4, 8, 12), c(0, 0, 0))
ok(nrow(N0) == 0 && attr(N0, "n") == 3 && attr(N0, "n_event") == 0 &&
     near(attr(N0, "follow_up"), 12),
   "a cohort with no event at all is a result: no steps, but the size and the follow-up come back")
ok(near(km_prob_at(N0, 6)$surv, 1) && is.na(km_median(N0)),
   "...and everyone is still event-free at six months")
ok(nrow(km_estimate(numeric(0), numeric(0))) == 0,
   "an empty curve is empty rather than an error")

# The curve is computed once per cohort and handed to every cell that reads
# it. What has to hold is that the cache changes nothing but the time it
# takes: a hit is the estimator's own answer, and a key two cohorts happen to
# share is not a hit.
local({
  km_cache_reset()
  t9 <- c(1, 3, 3, 7, 9, 11); e9 <- c(1L, 1L, 0L, 1L, 0L, 1L)
  ok(identical(km_estimate(t9, e9), km_estimate_uncached(t9, e9)) &&
       identical(km_estimate(t9, e9), km_estimate_uncached(t9, e9)),
     "a cached curve is the one the estimator returns, attributes and all")
  # Same length, same missing counts, same totals, different cohorts - so
  # the key matches and the inputs do not.
  a_t <- c(1, 5); b_t <- c(2, 4); ev2 <- c(1L, 1L)
  ok(identical(km_cache_key(a_t, ev2), km_cache_key(b_t, ev2)),
     "...two different cohorts can land on one key, which is why the key alone decides nothing")
  ka <- km_estimate(a_t, ev2); kb <- km_estimate(b_t, ev2)
  ok(identical(ka$TIME, a_t) && identical(kb$TIME, b_t) &&
       identical(kb, km_estimate_uncached(b_t, ev2)),
     "...and the second cohort gets its own curve, because the hit is checked before it is used")
  # Past the bound, so the entries this asks for again have been evicted.
  for (i in seq_len(.km_cache_max + 4L))
    km_estimate(as.numeric(seq_len(8L + i)), rep(1L, 8L + i))
  ok(identical(km_estimate(t9, e9), km_estimate_uncached(t9, e9)),
     "...and a cohort the cache has dropped is computed again, not lost")
  km_cache_reset()
})

cat("\n-- the disclosure rule --\n")
ok(tfls_floor(NA) == 25 && tfls_floor(10) == 25 && tfls_floor(3) == 25,
   "the floor is the protocol's 25 when nothing raises it")
ok(tfls_floor(40) == 40 && tfls_floor(26) == 26,
   "a higher floor is honoured")
ok(tfls_floor_from_env("10") == 25 && tfls_floor_from_env("") == 25 &&
     tfls_floor_from_env("40") == 40,
   "TFLS_MIN_N may raise the floor and may NEVER lower it")
stops_with(tfls_floor_from_env("banana"), "TFLS_MIN_N",
   "a TFLS_MIN_N that is not a whole number is refused rather than ignored")
ok(suppressed_text(25) == "<25" && suppressed_text(40) == "<40",
   "a withheld cell prints as the floor it did not reach, never as a blank")

mk_cells <- function(stat, n, denom, section_label = "S", column = "C1") {
  data.frame(TABLE_ID = "T1", ROW_ORDER = seq_along(n),
             ROW_LABEL = paste0("r", seq_along(n)), INDENT = 1L, SECTION = 0L,
             SECTION_LABEL = section_label, NOTE = "", STAT = stat,
             SOURCE = "S_X", MEASURE = "", COLUMN_ORDER = 1L,
             COLUMN_ID = column, COLUMN_LABEL = "Overall", COLUMN_GROUP = "",
             VALUE = n, LOW = NA_real_, HIGH = NA_real_, N = n, DENOM = denom,
             TEXT = as.character(n), FILLED = 1L, SUPPRESSED = 0L, REASON = "",
             REASON_KIND = "", stringsAsFactors = FALSE)
}
S1 <- suppress_cells(mk_cells("n_pct", c(30, 10, 60), c(100, 100, 100)), 25)
ok(S1$SUPPRESSED[2] == 1L && is.na(S1$N[2]) && is.na(S1$VALUE[2]) &&
     S1$TEXT[2] == "<25",
   "a cell resting on fewer than the floor is withheld, and the count it was computed from goes with it")
ok(S1$SUPPRESSED[1] == 1L && S1$SUPPRESSED[3] == 0L,
   "exactly one withheld cell in a group takes the smallest of the others with it, because the total less the rest would give it away")
S2 <- suppress_cells(mk_cells("n_pct", c(30, 10, 5), c(100, 100, 100)), 25)
ok(sum(S2$SUPPRESSED) == 2L && S2$SUPPRESSED[1] == 0L,
   "two withheld cells cannot be recovered from one total, so nothing more is withheld")
S3 <- suppress_cells(mk_cells("n_pct", c(30, 60), c(20, 20)), 25)
ok(all(S3$SUPPRESSED == 1L),
   "a population under the floor withholds every cell resting on it, however large the cell")
S4 <- suppress_cells(mk_cells("n_pct", c(30, 60), c(NA, 100)), 25)
ok(S4$SUPPRESSED[1] == 1L && has(S4$REASON[1], "could not be counted"),
   "a population that cannot be counted has not been shown to reach the floor, so it is withheld too")
S5 <- suppress_cells(mk_cells("rate", c(3, 4), c(300, 300)), 25)
ok(all(S5$SUPPRESSED == 0L),
   "a rate is withheld on its at-risk count, as the package withholds it, so the few events inside a large population are published")
S6 <- suppress_cells(rbind(mk_cells("n_pct", c(30, 10), c(100, 100), column = "C1"),
                           mk_cells("n_pct", c(30, 10), c(100, 100), column = "C2")), 25)
ok(sum(S6$SUPPRESSED) == 4L,
   "the groups are per column, so a lone withheld cell pairs up inside its own column")
S7 <- suppress_cells(mk_cells("n_pct", c(30, 10), c(100, 100)), 50)
ok(all(S7$SUPPRESSED == 1L) && all(S7$TEXT == "<50"),
   "a raised floor withholds more, and the cells say which floor they did not reach")

cat("\n-- the sums a reader can subtract within --\n")
#
# A withheld cell is no secret while the shell prints a sum it is the last
# unknown of. Three sums are read off the shell itself - a subtotal down a
# column, a total across a row, and the levels of a variable against the
# column's own N - and each fixture below is one of them.

# A frame of cells with the shell's shape in it: one cell per row and column,
# carrying the indentation the shell gives the row. A row may name its own
# section and its own statistic, because a section is what the sums are read
# within and only counts take part in one.
shaped_cells <- function(tid, section, columns, rows, denom, stat = "n_pct") {
  denom <- rep_len(denom, length(columns))
  out <- list()
  for (ri in seq_along(rows)) {
    r <- rows[[ri]]
    for (ci in seq_along(columns))
      out[[length(out) + 1L]] <- data.frame(
        TABLE_ID = tid, ROW_ORDER = ri, ROW_LABEL = r$label,
        INDENT = as.integer(r$indent), SECTION = 0L,
        SECTION_LABEL = if (is.null(r$section)) section else r$section,
        NOTE = "", STAT = if (is.null(r$stat)) stat else r$stat, SOURCE = "S_X",
        MEASURE = "", COLUMN_ORDER = ci, COLUMN_ID = columns[ci],
        COLUMN_LABEL = columns[ci], COLUMN_GROUP = "", VALUE = r$n[ci],
        LOW = NA_real_, HIGH = NA_real_, N = r$n[ci], DENOM = denom[ci],
        TEXT = as.character(r$n[ci]), FILLED = 1L, SUPPRESSED = 0L,
        REASON = "", REASON_KIND = "", stringsAsFactors = FALSE)
  }
  do.call(rbind, out)
}

# What a reader of the finished table can see of one cell: its count, or
# nothing at all where the cell was withheld.
seen <- function(s, label, column = s$COLUMN_ID[1]) {
  i <- which(s$ROW_LABEL == label & s$COLUMN_ID == column)[1]
  if (is.na(i) || s$SUPPRESSED[i] == 1L) NA_real_ else s$N[i]
}

# A sum gives a cell away when exactly one of its terms is missing from the
# page: that one term IS the sum less the published rest. Every term goes in,
# the total among them, and a total that is printed in the column header rather
# than in a cell goes in as the number it is.
gives_away <- function(terms) sum(is.na(terms)) == 1L

# The same test, over every sum the engine itself reads off the shell rather
# than over one written out by hand: no relation may be left with exactly one
# withheld member. This is the whole property of the pass.
no_lone_unknown <- function(s, shell = NULL)
  all(vapply(cell_relations(s, shell),
             function(r) sum(s$SUPPRESSED[r$members] == 1L) != 1L, logical(1)))

# 1. The reviewer's first fixture, as numbers: the age block of T1 down one
# column. The three bands are indented under the subtotal and sum to it.
AGE <- shaped_cells("T1", "Age distribution at index (N%)", "1L_OVERALL",
  list(list(label = "<75 years",        indent = 1, n = 121),
       list(label = "18 to 44 years",   indent = 2, n = 1),
       list(label = "45 to 64 years",   indent = 2, n = 60),
       list(label = "65 to 74 years",   indent = 2, n = 60),
       list(label = "75 years or more", indent = 1, n = 4)), 125)
ok(121 - 60 - 60 == 1 && 125 - 121 == 4,
   "the fixture is the reviewer's: the subtotal less its two published bands is the band of one, and the column N less the subtotal is the row of four")
SA <- suppress_cells(AGE, 25)
ok(seen(SA, "18 to 44 years") %in% NA_real_ &&
     seen(SA, "75 years or more") %in% NA_real_,
   "the two cells under the floor are withheld, as they were before")
ok(!gives_away(c(seen(SA, "<75 years"), seen(SA, "18 to 44 years"),
                 seen(SA, "45 to 64 years"), seen(SA, "65 to 74 years"))),
   "121 - 60 - 60 is a subtraction the published table no longer allows: the subtotal down the column has more than one term missing")
ok(!gives_away(c(125, seen(SA, "<75 years"), seen(SA, "75 years or more"))),
   "...and neither does 125 - 121, the column N against the rows outside the subtotal")
ok(sum(SA$SUPPRESSED) > 2L,
   "closing those two sums withheld more than the floor alone did, which is the only direction this rule may move in")
ok(all(is.na(SA$N[SA$SUPPRESSED == 1L])) &&
     all(is.na(SA$DENOM[SA$SUPPRESSED == 1L])) &&
     all(SA$TEXT[SA$SUPPRESSED == 1L] == "<25"),
   "every cell withheld by a sum keeps no number behind its text, and prints as the floor")
ok(has(SA$REASON[SA$ROW_LABEL == "45 to 64 years"], "subtotal '<75 years'"),
   "the reason names the sum that forced it, not the floor it does clear")
ok(no_lone_unknown(SA),
   "no sum the engine reads off this table is left with exactly one withheld member")
ok(identical(suppress_cells(SA, 25)$SUPPRESSED, SA$SUPPRESSED),
   "and the answer is a fixed point: running the rule again withholds nothing further")

# 2. The reviewer's second fixture, as numbers: one row of T1b across its
# columns. The two subgroup columns partition the overall one.
NEURO_COLUMNS <- data.frame(
  table_id = "T1b", label = c("Overall", "Baseline Neuropathy = Yes",
                              "Baseline Neuropathy = No"),
  order = 1:3, column_id = c("1L_OVERALL", "1L_NEURO_YES", "1L_NEURO_NO"),
  group = "1L (N=)", cohort = "1L", line = "1", class = "OVERALL",
  subgroup = c("", "S_COMORB_SUBGROUP:CONCEPT=neuropathy&HAS_HISTORY=1",
               "S_COMORB_SUBGROUP:CONCEPT=neuropathy&HAS_HISTORY=0"),
  period = "", note = "", stringsAsFactors = FALSE)
NEU <- shaped_cells("T1b", "Sex (N%)",
  c("1L_OVERALL", "1L_NEURO_YES", "1L_NEURO_NO"),
  list(list(label = "Male", indent = 1, n = c(60, 1, 59))), c(200, 30, 170))
ok(60 - 59 == 1,
   "the fixture is the reviewer's: the overall column less the published subgroup is the withheld one")
SN <- suppress_cells(NEU, 25, list(columns = NEURO_COLUMNS))
ok(seen(SN, "Male", "1L_NEURO_YES") %in% NA_real_,
   "the subgroup of one is withheld by the floor")
ok(!gives_away(c(seen(SN, "Male", "1L_OVERALL"), seen(SN, "Male", "1L_NEURO_YES"),
                 seen(SN, "Male", "1L_NEURO_NO"))),
   "60 - 59 is a subtraction the published table no longer allows: the total across the row has more than one term missing")
ok(has(SN$REASON[SN$COLUMN_ID == "1L_NEURO_NO"], "'Overall'"),
   "the reason names the total column that forced it")
ok(no_lone_unknown(SN, list(columns = NEURO_COLUMNS)),
   "no sum the engine reads off this table is left with exactly one withheld member either")
ok(sum(suppress_cells(NEU, 25)$SUPPRESSED) == 1L &&
     sum(SN$SUPPRESSED) > sum(suppress_cells(NEU, 25)$SUPPRESSED),
   "a caller that passes no shell still withholds everything the floor asks for, and the shell only ever adds to it")

# The same row again, with the shell's columns held as columns.csv spells them
# - col_id and lot_num - rather than as load_shells() renames them. The sum is
# the same sum and has to be read either way.
RAW_COLUMNS <- data.frame(
  table_id = "T1b", col_id = c("1L_OVERALL", "1L_NEURO_YES", "1L_NEURO_NO"),
  label = c("Overall", "Baseline Neuropathy = Yes", "Baseline Neuropathy = No"),
  cohort = "1L", lot_num = "1", class = "OVERALL",
  subgroup = c("", "NEUROPATHY=YES", "NEUROPATHY=NO"), period = "",
  stringsAsFactors = FALSE)
SR <- suppress_cells(NEU, 25, list(columns = RAW_COLUMNS))
ok(identical(SR$SUPPRESSED, SN$SUPPRESSED) && no_lone_unknown(SR, list(columns = RAW_COLUMNS)),
   "the columns read the same under the CSV's own spellings, so 60 - 59 is closed there too")
ok(sum(suppress_cells(NEU, 25, list(columns = RAW_COLUMNS[, c("table_id", "col_id")]))$SUPPRESSED) >= 1L,
   "and a columns frame carrying nothing to split the table by still withholds what the floor asks")

# The sum across a row holds within one row and not down a column. A second
# row, in a section of its own so that no sum down a column reaches it, is
# untouched by what the first row gave up.
TWO_ROW <- rbind(NEU, shaped_cells("T1b", "Race (N%)",
  c("1L_OVERALL", "1L_NEURO_YES", "1L_NEURO_NO"),
  list(list(label = "White", indent = 1, n = c(140, 40, 100))), c(200, 30, 170)))
TWO_ROW$ROW_ORDER[TWO_ROW$ROW_LABEL == "White"] <- 2L
S2R <- suppress_cells(TWO_ROW, 25, list(columns = NEURO_COLUMNS))
ok(sum(S2R$SUPPRESSED) == 2L && all(S2R$SUPPRESSED[S2R$ROW_LABEL == "White"] == 0L),
   "the row with a cell under the floor loses a second cell of its own row, and the row beside it loses nothing")

# 3. Three levels, two of them under the floor. The total less the published
# level is the two withheld ones together - 100 - 80 = 20 men across the two
# neuropathy groups - and 20 is a count of patients under the floor whether or
# not it says how it splits. It used to be published, on the reasoning that no
# single cell could be isolated; but the suite withholds "ten men" further down
# because 40 - 30 gives them away, and "20 men in these two groups" is the same
# disclosure split in two. So the level of 80 goes too.
THREE <- shaped_cells("T1b", "Sex (N%)",
  c("1L_OVERALL", "1L_NEURO_YES", "1L_NEURO_NO"),
  list(list(label = "Male", indent = 1, n = c(100, 10, 10))), c(300, 30, 30))
THREE <- rbind(THREE, shaped_cells("T1b", "Sex (N%)", "1L_OTHER",
  list(list(label = "Male", indent = 1, n = 80)), 240))
THREE$COLUMN_ORDER[THREE$COLUMN_ID == "1L_OTHER"] <- 4L
THREE_COLUMNS <- rbind(NEURO_COLUMNS, data.frame(
  table_id = "T1b", label = "Baseline Neuropathy = Unknown", order = 4L,
  column_id = "1L_OTHER", group = "1L (N=)", cohort = "1L", line = "1",
  class = "OVERALL",
  subgroup = "S_COMORB_SUBGROUP:CONCEPT=neuropathy&HAS_HISTORY=unknown",
  period = "", note = "", stringsAsFactors = FALSE))
S3L <- suppress_cells(THREE, 25, list(columns = THREE_COLUMNS))
ok(sum(S3L$SUPPRESSED) == 3L && !is.na(seen(S3L, "Male", "1L_OVERALL")) &&
     is.na(seen(S3L, "Male", "1L_OTHER")),
   "two levels under the floor take the third with them, because the total less it is 20 patients between them")
ok(!gives_away(c(seen(S3L, "Male", "1L_OVERALL"), seen(S3L, "Male", "1L_NEURO_YES"),
                 seen(S3L, "Male", "1L_NEURO_NO"), seen(S3L, "Male", "1L_OTHER"))),
   "...and with three unknowns the arithmetic isolates none of them")
ok(grepl("add up to fewer than 25", S3L$REASON[S3L$COLUMN_ID == "1L_OTHER"], fixed = TRUE),
   "...and the reason says it was the combined remainder, not a lone unknown")
ok(no_lone_unknown(S3L, list(columns = THREE_COLUMNS)),
   "...and no sum of this table is left with one member missing")

# 4. The parent of a subtotal, withheld itself. The bands published under it
# would sum to it, so one band goes with it. The shell draws the sum, not the
# numbers: the subtotal row is rolled up from a different source than its
# bands, so it is withheld on its own count rather than on theirs.
PARENT <- shaped_cells("T1", "Age distribution at index (N%)", "C1",
  list(list(label = "<75 years",      indent = 1, n = 20),
       list(label = "18 to 44 years", indent = 2, n = 30),
       list(label = "45 to 64 years", indent = 2, n = 40)), 200)
SP <- suppress_cells(PARENT, 25)
ok(seen(SP, "<75 years") %in% NA_real_,
   "the subtotal row under the floor is withheld")
ok(sum(SP$SUPPRESSED) == 2L && seen(SP, "18 to 44 years") %in% NA_real_,
   "...and the smallest band goes with it, because the published bands would add up to the withheld parent")
ok(!gives_away(c(seen(SP, "<75 years"), seen(SP, "18 to 44 years"),
                 seen(SP, "45 to 64 years"))),
   "so the subtotal has two terms missing and gives neither away")
ok(no_lone_unknown(SP),
   "...and no sum of this table is left with one member missing")

# 5. A table the shell draws no sum in: one level on its own under each
# heading, and statistics that do not add up to a total. Nothing beyond the
# floor may be withheld here - the rule withholds to close a sum, and there is
# no sum to close.
FLAT <- shaped_cells("T1", "Sex (N%)", "C1",
  list(list(label = "Male", indent = 1, n = 40),
       list(label = "Mean and SD", indent = 1, n = 100, section = "Age at index",
            stat = "mean_sd"),
       list(label = "Median and IQR", indent = 1, n = 100,
            section = "Age at index", stat = "median_iqr")), 200)
SF <- suppress_cells(FLAT, 25)
ok(sum(SF$SUPPRESSED) == 0L,
   "where the shell draws no sum among the cells, nothing beyond the floor is withheld")
ok(sum(suppress_cells(FLAT, 25, list(columns = NEURO_COLUMNS))$SUPPRESSED) == 0L,
   "...and a shell whose columns do not split this table's own adds no sum either")

# 6. A cascade that ends with the whole table withheld: the column N gives the
# subtotal away, and the subtotal then gives its one band away. The sweeps have
# to see the second sum only after the first has been closed, and then stop.
CASCADE <- shaped_cells("T1", "Age distribution at index (N%)", "C1",
  list(list(label = "<75 years",        indent = 1, n = 40),
       list(label = "18 to 44 years",   indent = 2, n = 40),
       list(label = "75 years or more", indent = 1, n = 10)), 50)
SC <- suppress_cells(CASCADE, 25)
ok(all(SC$SUPPRESSED == 1L) && all(SC$TEXT == "<25") && all(is.na(SC$N)),
   "the sweeps run until every cell of the table is withheld, and stop there rather than going round again")
ok(identical(suppress_cells(SC, 25)$SUPPRESSED, SC$SUPPRESSED),
   "a table with nothing left to publish is the fixed point of the rule")
ok(has(SC$REASON[SC$ROW_LABEL == "18 to 44 years"], "subtotal '<75 years'"),
   "the last cell to go says which sum forced it, and it is the one closed on the second sweep")

cat("\n-- nothing patient-level is written --\n")
ok(identical(names(drop_identifiers(data.frame(PATID = "P1", N = 1))), "N"),
   "an identifier column is dropped whatever else is in the frame")
stops_with(assert_no_identifiers(data.frame(patid = "P1", N = 1), "a frame"),
  "DISCLOSURE", "a frame carrying an identifier is refused, whatever case it is spelled in")
stops_with(tfls_write_csv(data.frame(PATID = "P1"), file.path(tempdir(), "no.csv")),
  "DISCLOSURE", "...and the writer refuses it, so no code path can put one in out/")

cat("\n-- filling a table --\n")
# Forty patients in one cohort and one line. Thirty are female, ten are male;
# thirty are white and the other ten split five and five. Twenty-six are on a
# quadruplet and fourteen on a pomalidomide triplet.
IDS <- sprintf("P%02d", 1:40)
DEMO <- data.frame(
  PATID = IDS, COHORT = "1L",
  SEX = c(rep("Female", 30), rep("Male", 10)),
  RACE = c(rep("White", 30), rep("Black", 5), rep("Asian", 5)),
  AGE_YEARS = c(rep(70, 20), rep(80, 20)), stringsAsFactors = FALSE)
SOC <- data.frame(
  PATID = IDS, COHORT = "1L", LOT_NUM = 1L,
  REGIMEN = c(rep("DARA BORT LEN DEX", 26), rep("POM BORT DEX", 14)),
  SOC_CATEGORY = c(rep("Quadruplet with anti-CD38 backbone", 26),
                   rep("Other triplet (non-anti-CD38)", 14)),
  stringsAsFactors = FALSE)
TABLES <- list(S_DEMOGRAPHICS = DEMO, S_SOC = SOC)
READER <- function(name) TABLES[[toupper(name)]]
CTX <- fill_context(READER, SH$classes)
F1 <- fill_table(SH, "T1", CTX, floor_n = 25)
cell <- function(f, order, col) {
  i <- which(f$cells$ROW_ORDER == order & f$cells$COLUMN_ID == col)
  f$cells[i[1], , drop = FALSE]
}
ok(nrow(F1$cells) == 11 * 4,
   "every row of the shell meets every column of it, headings included")
ok(near(cell(F1, 9, "C1")$VALUE, 75) && cell(F1, 9, "C1")$TEXT == "75.0 (5.1)",
   "the mean age over the forty is 75.0 with an SD of 5.06, computed from the rows the column selects")
ok(cell(F1, 6, "C1")$TEXT == "<25" && cell(F1, 7, "C1")$TEXT == "<25",
   "two levels of five are withheld")
ok(cell(F1, 5, "C1")$SUPPRESSED == 1L && cell(F1, 5, "C1")$TEXT == "<25",
   "...and the level of thirty goes with them: forty less thirty is the ten patients between them, as forty less the thirty women is the ten men")
ok(cell(F1, 2, "C1")$SUPPRESSED == 1L && cell(F1, 3, "C1")$SUPPRESSED == 1L,
   "the ten men are withheld and the thirty women go with them, because a lone withheld level is the total less the rest")
ok(near(cell(F1, 2, "C2")$DENOM, 26) || cell(F1, 2, "C2")$SUPPRESSED == 1L,
   "the quadruplet column is the twenty-six lines the study put in that category")
ok(cell(F1, 2, "C4")$FILLED == 0L &&
     has(cell(F1, 2, "C4")$REASON, "no SOC category") &&
     cell(F1, 2, "C4")$REASON_KIND == "shell",
   "a column whose class maps to no category is reported unfilled, not filled with a zero")
ok({ p <- soc_patients(CTX, line = "1", cohort = "1L",
                       categories = "Other triplet (non-anti-CD38)", drug = "POM")
     length(p) == 14 },
   "a class that refines the study's category with a drug selects the lines whose regimen holds it")
ok({ p <- soc_patients(CTX, line = "1", cohort = "1L",
                       categories = "Other triplet (non-anti-CD38)", drug = "DARA")
     length(p) == 0 },
   "...and none where no regimen in that category holds it")
ok(cell(F1, 10, "C1")$FILLED == 0L && cell(F1, 10, "C1")$TEXT == "not filled" &&
     has(cell(F1, 10, "C1")$REASON, "HEIGHT_CM is not a column of S_DEMOGRAPHICS") &&
     cell(F1, 10, "C1")$REASON_KIND == "not_in_run",
   "a row naming a measure the study does not produce is reported with its reason, never left blank")
ok(cell(F1, 11, "C1")$FILLED == 0L &&
     has(cell(F1, 11, "C1")$REASON, "no source table") &&
     cell(F1, 11, "C1")$REASON_KIND == "shell",
   "a row with no source is the shell's gap to close, and it says so")
ok(all(c("HEIGHT_CM is not a column of S_DEMOGRAPHICS") %in% F1$unfilled$REASON) &&
     all(F1$unfilled$REASON_KIND %in% TFLS_REASON_KINDS),
   "every unfilled row reaches the unfilled list, each with the kind of gap it is")
ok(sum(F1$unfilled$COLUMN_ID == "(all)") == 2,
   "a row nothing could fill in any column is listed once, against every column")
ok(all(F1$cells$SECTION[F1$cells$ROW_ORDER %in% c(1, 4, 8)] == 1L) &&
     all(F1$cells$TEXT[F1$cells$SECTION == 1L] == ""),
   "a heading is a heading: it carries no number and is not reported as unfilled")
ok(!any(toupper(names(render_csv(F1))) %in% TFLS_ID_COLUMNS) &&
     !any(toupper(names(all_unfilled(list(F1)))) %in% TFLS_ID_COLUMNS),
   "no output frame carries a PATID column")
ok({ tf <- tempfile(fileext = ".csv"); tfls_write_csv(render_csv(F1), tf)
     back <- utils::read.csv(tf, colClasses = "character")
     nrow(back) == 44 && !any(toupper(names(back)) %in% TFLS_ID_COLUMNS) },
   "...and the written CSV carries none either")
ok(!any(grepl("P0[0-9]", unlist(lapply(render_csv(F1), as.character)))),
   "no identifier appears in any cell of the output, under any column name")

cat("\n-- the subgroups, off the tables the study writes them on --\n")
SUB <- data.frame(PATID = IDS, COHORT = "1L", CONCEPT = "neuropathy",
                  HAS_HISTORY = c(rep(1L, 30), rep(0L, 10)),
                  stringsAsFactors = FALSE)
FRAIL <- data.frame(PATID = IDS, COHORT = "1L", CFI = 0.3,
                    FRAIL = c(rep(1L, 26), rep(0L, 14)), stringsAsFactors = FALSE)
MALIG <- data.frame(PATID = IDS[1:20], COHORT = "1L",
                    CATEGORY = "haematologic",
                    LOT_AFTER_WHICH = c(rep(1L, 12), rep(2L, 8)),
                    stringsAsFactors = FALSE)
TABLES2 <- c(TABLES, list(S_COMORB_SUBGROUP = SUB, S_FRAILTY = FRAIL,
                          S_MALIGNANCY = MALIG))
CTX2 <- fill_context(function(n) TABLES2[[toupper(n)]], SH$classes)
sub_rows <- function(d, sg, ctx = CTX2, where = "S_DEMOGRAPHICS") {
  r <- restrict_to_subgroup(d, sg, ctx, where, "1L")
  if (!isTRUE(r$ok)) return(r)
  nrow(r$rows)
}
ok(identical(sub_rows(DEMO, "NEUROPATHY=YES"), 30L) &&
     identical(sub_rows(DEMO, "NEUROPATHY=NO"), 10L),
   "a neuropathy subgroup is the patients the study's own baseline flag holds")
ok(identical(sub_rows(DEMO, "S_COMORB_SUBGROUP:CONCEPT=neuropathy&HAS_HISTORY=0"), 10L),
   "...and the column may say the same thing by naming the table and the flag")
ok(identical(sub_rows(DEMO, "FRAILTY=YES"), 26L) &&
     identical(sub_rows(DEMO, "FRAILTY=NO"), 14L),
   "a frailty subgroup is the patients the study's own index marks")
ok(identical(sub_rows(DEMO, "AGE=GE75"), 20L) &&
     identical(sub_rows(DEMO, "AGE=LT75"), 20L),
   "an age subgroup is a band of the age the study recorded at index")
ok(identical(sub_rows(DEMO, "S_MALIGNANCY:LOT_AFTER_WHICH>=2"), 8L) &&
     identical(sub_rows(DEMO, "S_MALIGNANCY:LOT_AFTER_WHICH=1"), 12L),
   "a subgroup may be a comparison on a number, which is how an interval column selects")
ok({ r <- restrict_to_subgroup(DEMO, "S_FRAILTY:FRAIL=1", CTX, "S_DEMOGRAPHICS", "1L")
     !isTRUE(r$ok) && identical(r$kind, "not_in_run") &&
       has(r$why, "was not read by this run") },
   "a subgroup on a table the run did not write is the study run's gap, and the reason says which table")

cat("\n-- the eligibility flag is a flag, not a filter --\n")
TT <- data.frame(PATID = IDS, COHORT = "1L", LOT_NUM = 1L,
                 TTE_ELIGIBLE = c(rep(1L, 20), rep(0L, 20)),
                 OS_MONTHS = seq_len(40), OS_EVENT = 1L,
                 stringsAsFactors = FALSE)
ok({ e <- km_analysis_rows(TT); nrow(e) == 40 },
   "a curve is over every row of the time-to-event table by default: the study leaves the restriction to the reader")
ok({ e <- km_analysis_rows(TT, TRUE); nrow(e) == 20 },
   "...and over the marked analysis set only when the run was set to apply it, which the caption then says")

cat("\n-- a count of regimens is not a count of patients --\n")
# The shell row asks how many different regimens the lines in a column hold.
# The table it reads is one row per patient and line, so counting the patients
# there answers a different question, and a hundred patients on one regimen
# would render a hundred.
REG_SH <- load_shells(write_shells(list(
  tables = c("table_id,sheet,title,objective,notes",
             "T1,T1,Regimens,Primary objective,"),
  columns = c("table_id,col_id,group,label,order,cohort,lot_num,class,subgroup,period",
              "T1,C1,1L (N=),Overall,1,1L,1,OVERALL,,"),
  rows = c("table_id,order,section,label,indent,stat,source,measure,filter,note",
           "T1,1,FALSE,Total number of unique regimens,0,n_distinct,S_SOC,REGIMEN,,",
           "T1,2,FALSE,Patients treated,0,n,S_SOC,REGIMEN,,"),
  footnotes = "table_id,marker,text")))
reg_fill <- function(regimens) {
  soc <- data.frame(PATID = sprintf("r%03d", seq_along(regimens)), COHORT = "1L",
                    LOT_NUM = 1L, REGIMEN = regimens, stringsAsFactors = FALSE)
  fill_table(REG_SH, "T1", fill_context(
    function(n) if (identical(toupper(chr(n)), "S_SOC")) soc else NULL,
    REG_SH$classes), floor_n = 25)
}
REG_ONE <- reg_fill(rep("LEN DEX", 100))
REG_THREE <- reg_fill(rep(c("LEN DEX", "POM DEX", "DARA BORT LEN DEX"),
                          length.out = 99))
ok(cell(REG_ONE, 1, "C1")$TEXT == "1",
   "a hundred patients all on one regimen render 1, which is how many regimens there are")
ok(cell(REG_THREE, 1, "C1")$TEXT == "3",
   "three regimens over ninety-nine patients render 3")
ok(cell(REG_ONE, 2, "C1")$TEXT == "100",
   "...while n over the same table still counts the patients, which is the other question and the other statistic")
ok({ r <- fill_table(load_shells(write_shells(list(
       tables = c("table_id,sheet,title,objective,notes",
                  "T1,T1,Regimens,Primary objective,"),
       columns = c("table_id,col_id,group,label,order,cohort,lot_num,class,subgroup,period",
                   "T1,C1,1L (N=),Overall,1,1L,1,OVERALL,,"),
       rows = c("table_id,order,section,label,indent,stat,source,measure,filter,note",
                "T1,1,FALSE,Unique regimens,0,n_distinct,S_PATTERNS,SOC_CATEGORY,,"),
       footnotes = "table_id,marker,text"))), "T1", fill_context(
         function(n) if (identical(toupper(chr(n)), "S_PATTERNS"))
           data.frame(COHORT = "1L", LOT_NUM = 1L,
                      SOC_CATEGORY = c("Doublet/monotherapy", "Other"),
                      N_PATIENTS = c(60, 40), N_DENOM = 100,
                      stringsAsFactors = FALSE) else NULL,
         SH$classes), floor_n = 25)
     r$cells$FILLED[1] == 0L && has(r$cells$REASON[1], "table of totals") },
   "and over a table of totals it is refused with its reason: the values there are the strata the package wrote, not what the population holds")

cat("\n-- a run is bound by what it declared, not by what sits under the prefix --\n")
# One prefix, two runs. This one selected the 1L cohort and two modules. The
# 2L rows, the safety table and the released copy beside S_PATTERNS are what an
# earlier run left under the same prefix, and none of them is this run's.
md_row <- function(cohorts, modules, readings = "") data.frame(
  RUN_ID = "r2", STATE = "complete", UPDATED_AT = "2026-09-10 09:00:00",
  COHORTS = cohorts, MODULES = modules, OPEN_QUESTION_READINGS = readings,
  stringsAsFactors = FALSE)
RUN <- run_scope(md_row("1L", "cohorts; demographics"))
LEFT <- list(
  S_DEMOGRAPHICS = data.frame(
    PATID = sprintf("q%03d", 1:70), COHORT = c(rep("1L", 30), rep("2L", 40)),
    AGE_YEARS = c(rep(70, 30), rep(80, 40)), stringsAsFactors = FALSE),
  S_SAFETY_RATES = data.frame(
    COHORT = "1L", LOT_NUM = 1L, PERIOD = "TREATMENT", EVENT = "Neutropenia",
    N_AT_RISK = 30, N_PATIENTS = 12, N_EVENTS = 12, PERSON_YEARS = 20,
    RATE = 600, stringsAsFactors = FALSE),
  S_PATTERNS = data.frame(
    COHORT = "1L", LOT_NUM = 1L, SOC_CATEGORY = "Doublet/monotherapy",
    N_PATIENTS = 30, N_DENOM = 30, PCT = 100, stringsAsFactors = FALSE),
  S_PATTERNS_RELEASE = data.frame(
    COHORT = "1L", LOT_NUM = 1L, SOC_CATEGORY = "Doublet/monotherapy",
    N_PATIENTS = 70, N_DENOM = 70, PCT = 100, stringsAsFactors = FALSE))
UNDER_PREFIX <- function(name) LEFT[[toupper(chr(name))]]
BOUND <- run_reader(UNDER_PREFIX, RUN)

ok({ st <- run_table_status(RUN, "S_SAFETY_RATES")
     !isTRUE(st$ok) && has(st$why, "safety module, which this run did not run") &&
       has(st$why, "cohorts, demographics") },
   "a table whose module the run's own MODULES does not name is not this run's, and the reason names both the module and what the run did record")
ok(is.null(BOUND("S_SAFETY_RATES")) && !is.null(UNDER_PREFIX("S_SAFETY_RATES")),
   "...so it reads as absent, though the table an earlier run left under the prefix is right there")
ok({ d <- BOUND("S_DEMOGRAPHICS")
     !is.null(d) && nrow(d) == 30 && all(chr(d$COHORT) == "1L") },
   "a table the run did write comes back with the cohorts it selected, and with none of the 2L rows an earlier run built")
ok(is.null(BOUND("S_NOT_A_TABLE")) &&
     has(run_table_status(RUN, "S_NOT_A_TABLE")$why, "not a table the study package writes"),
   "a name no module in the package's registry writes is refused by name rather than read from whatever sits under the prefix")
RAW_RUN <- run_scope(md_row("1L", "cohorts; periods; soc; patterns"))
REL_RUN <- run_scope(md_row("1L", "cohorts; periods; soc; patterns; release"))
ok(run_reader(UNDER_PREFIX, RAW_RUN)("S_PATTERNS")$N_PATIENTS == 30,
   "a released copy an earlier run left behind is not preferred where this run did not run the release module: the rebuilt raw table is what is read")
ok(run_reader(UNDER_PREFIX, REL_RUN)("S_PATTERNS")$N_PATIENTS == 70,
   "...and where the run did run it, the released copy is read, so the suppression stays the package's own")

# The third state, which is neither of those two: the run says it released and
# the released copy is not there. Reading the raw one would publish exactly
# what the release was run to remove, under a run that says it removed it - so
# nothing is read, and the reason says which of absent and empty it was.
GONE <- function(store)
  run_reader(function(t) store[[toupper(t)]], REL_RUN)
REL_ONLY_RAW <- list(S_PATTERNS = UNDER_PREFIX("S_PATTERNS"))
REL_EMPTY <- c(REL_ONLY_RAW,
               list(S_PATTERNS_RELEASE = UNDER_PREFIX("S_PATTERNS_RELEASE")[0, , drop = FALSE]))
ok(is.null(GONE(REL_ONLY_RAW)("S_PATTERNS")),
   "a run that released a table and left no released copy reads nothing, not the raw table it was meant to replace")
ok(is.null(GONE(REL_EMPTY)("S_PATTERNS")),
   "...and a released copy with no rows in it is the same refusal, not an empty answer that falls back")
# A refusal is recorded as the read happens, so the reader is asked after it
# has been used - the same way the runner's unfilled list asks it.
MISSING_READER <- GONE(REL_ONLY_RAW); invisible(MISSING_READER("S_PATTERNS"))
EMPTY_READER <- GONE(REL_EMPTY); invisible(EMPTY_READER("S_PATTERNS"))
RAW_READER <- run_reader(UNDER_PREFIX, RAW_RUN); invisible(RAW_READER("S_PATTERNS"))
ok(has(reader_refusal(MISSING_READER, "S_PATTERNS"), "not under the prefix") &&
     has(reader_refusal(EMPTY_READER, "S_PATTERNS"), "there with no rows"),
   "...and the refusal says which of the two it was, because a missing table and an empty one are different failures")
ok(!nzchar(reader_refusal(RAW_READER, "S_PATTERNS")),
   "...while a run that never released refuses nothing, since the raw table is what it has")

# The run's own verdict on its release, applied here and not only by the
# dashboard. These shells are what a study hands out, and filling them at a
# higher floor does not close a recoverable cell: the subtraction is inside the
# released copy this reads FROM, and it happened before anything here looked.
md_rel <- function(rec, tabs = "") {
  d <- md_row("1L", "cohorts; periods; soc; patterns; release")
  d$RELEASE_RECOVERABLE <- rec
  d$RELEASE_RECOVERABLE_TABLES <- tabs
  d
}
BAD_TXT <- "S_PATTERNS_RELEASE: 1 COHORT/LOT_NUM group(s) with one suppressed SOC_CATEGORY"
ok(!nzchar(release_verdict(run_scope(md_rel("none")))) &&
     !length(release_refused(run_scope(md_rel("none")))),
   "a run whose release left nothing recoverable is read as it always was")
ok(identical(release_verdict(run_scope(md_rel(""))), TFLS_RELEASE_NOT_RECORDED) &&
     !length(release_refused(run_scope(md_rel("")))),
   "...and a build from before the column existed is not refused here: the snapshot job is the gate for that one")
ok(!nzchar(release_verdict(run_scope(md_rel("NONE")))) &&
     !nzchar(release_verdict(run_scope(md_rel(" None ")))),
   "...and the clean sentinel clears whatever case it is written in, because this column comes back through a warehouse, a CSV and sometimes a hand edit")
ok(nzchar(release_verdict(run_scope(md_rel("NOTHING RECOVERABLE")))),
   "...while anything else is a finding whatever its case, so folding can lift a needless refusal and never turn a finding into a clear")
ok(setequal(release_refused(run_scope(md_rel("release module did not run"))),
            TFLS_RELEASED_TABLES),
   "...while a run that never ran the release module loses every released table, because it has not been shown to have no recoverable cell - it has not looked")
ok(identical(release_refused(run_scope(md_rel(BAD_TXT, "S_PATTERNS"))), "S_PATTERNS"),
   "a finding refuses the table the run itself named, read from its list rather than out of its sentence")
ok(setequal(release_refused(run_scope(md_rel(
     "one group in the patterns release is recoverable by subtraction"))),
     TFLS_RELEASED_TABLES),
   "...a reworded finding with no list behind it refuses every released table, since an answer that cannot be read is not one that clears")
ok(setequal(release_refused(run_scope(md_rel(BAD_TXT, "S_NOT_A_TABLE"))), "S_PATTERNS") &&
     setequal(release_refused(run_scope(md_rel(BAD_TXT, "S_PATTERNS; S_NOT_A_TABLE"))),
              "S_PATTERNS"),
   "...and a list naming anything that is not a released table is discarded whole, so a stale field cannot narrow the refusal onto a table that does not exist")
local({
  blocked <- run_reader(UNDER_PREFIX, run_scope(md_rel(BAD_TXT, "S_PATTERNS")))
  d <- blocked("S_PATTERNS")
  ok(is.null(d),
     "the reader gives nothing for a table the run's own record says has a recoverable withheld cell")
  ok(is.null(blocked("S_PATTERNS_RELEASE")),
     "...under either spelling, so asking for the released copy by name is not the way round it")
  ok(has(reader_refusal(blocked, "S_PATTERNS"), BAD_TXT) &&
       has(reader_refusal(blocked, "S_PATTERNS"), "TFLS_ALLOW_RECOVERABLE=TRUE"),
     "...and the row resting on it is reported unfilled in the run's own words, with the one named way past it")
  # A verdict naming one table refuses only that one. S_SWITCH is refused here
  # too, but for the reason it always was - this run released it and the copy
  # is not under the prefix - and not by the verdict.
  invisible(blocked("S_SWITCH"))
  ok(has(reader_refusal(blocked, "S_SWITCH"), "not under the prefix") &&
       !has(reader_refusal(blocked, "S_SWITCH"), "TFLS_ALLOW_RECOVERABLE"),
     "...while a verdict naming one table refuses only that one: every other table fails or reads for its own reasons")
})
local({
  old <- Sys.getenv("TFLS_ALLOW_RECOVERABLE")
  Sys.setenv(TFLS_ALLOW_RECOVERABLE = "TRUE")
  on.exit(Sys.setenv(TFLS_ALLOW_RECOVERABLE = old))
  allowed <- run_reader(UNDER_PREFIX, run_scope(md_rel(BAD_TXT, "S_PATTERNS")))
  ok(!is.null(allowed("S_PATTERNS")),
     "...and one named switch fills them anyway, so doing it knowing that is a decision someone made")
})
FRAIL_OFF <- run_scope(md_row("1L", "cohorts; periods; comorbidity", "frailty=FALSE"))
FRAIL_ON <- run_scope(md_row("1L", "cohorts; periods; comorbidity", "frailty=TRUE"))
ok({ st <- run_table_status(FRAIL_OFF, "S_FRAILTY")
     !isTRUE(st$ok) && has(st$why, "FRAILTY") },
   "an output a switch turns on is not the run's where the run recorded the switch off")
ok(isTRUE(run_table_status(FRAIL_ON, "S_FRAILTY")$ok),
   "...and is the run's where it recorded it on")
ok(isTRUE(run_table_status(run_scope(md_row("1L", "cohorts; periods; comorbidity",
     "study_start=2016-01-01 (upstream, verified; this run was set to 2018-01-01); frailty=TRUE")),
     "S_FRAILTY")$ok),
   "a reading whose note carries a semicolon of its own does not hide the reading written after it")

# The same prefix, read through a shell: one column for the cohort the run
# selected and one for the cohort it did not, and a row reading a module that
# did not run.
SCOPE_SH <- load_shells(write_shells(list(
  tables = c("table_id,sheet,title,objective,notes",
             "T1,T1,Baseline by cohort,Primary objective,"),
  columns = c("table_id,col_id,group,label,order,cohort,lot_num,class,subgroup,period",
              "T1,C1,1L (N=),1L,1,1L,,OVERALL,,",
              "T1,C2,2L (N=),2L,2,2L,,OVERALL,,"),
  rows = c("table_id,order,section,label,indent,stat,source,measure,filter,note",
           "T1,1,FALSE,Mean age (SD),0,mean_sd,S_DEMOGRAPHICS,AGE_YEARS,,",
           "T1,2,FALSE,Neutropenia,0,n,S_SAFETY_RATES,N_PATIENTS,,"),
  footnotes = "table_id,marker,text")))
SCOPE_F <- fill_table(SCOPE_SH, "T1", fill_context(
  BOUND, SCOPE_SH$classes,
  absent_why = function(table) run_table_status(RUN, table)$why), floor_n = 25)
ok(cell(SCOPE_F, 1, "C1")$TEXT == "70.0 (0.0)" &&
     cell(SCOPE_F, 1, "C1")$FILLED == 1L,
   "the column of the cohort the run selected is filled from the run's own thirty rows")
ok(cell(SCOPE_F, 1, "C2")$FILLED == 0L &&
     cell(SCOPE_F, 1, "C2")$TEXT == "not filled" &&
     is.na(cell(SCOPE_F, 1, "C2")$VALUE) && is.na(cell(SCOPE_F, 1, "C2")$N),
   "the cohort the run did not select contributes nothing: no mean age of forty rows it never built, and no zero either")
ok(cell(SCOPE_F, 2, "C1")$FILLED == 0L &&
     cell(SCOPE_F, 2, "C1")$TEXT == "not filled" &&
     has(cell(SCOPE_F, 2, "C1")$REASON, "safety module, which this run did not run") &&
     has(cell(SCOPE_F, 2, "C1")$REASON, "cohorts, demographics") &&
     cell(SCOPE_F, 2, "C1")$REASON_KIND == "not_in_run",
   "a row reading a module that did not run says so, naming the run's own declaration, rather than counting the table left behind")
ok(any(vapply(SCOPE_F$unfilled$REASON, has, logical(1), "safety module")) &&
     !any(SCOPE_F$cells$FILLED == 1L & SCOPE_F$cells$SOURCE == "S_SAFETY_RATES"),
   "...and it reaches the unfilled list once, with no cell of that table filled anywhere in the table")

cat("\n-- rendering --\n")
MD <- render_markdown(F1, SH)
ok(has(MD[1], "## T1. Baseline"), "the table prints under its own title")
LAB <- grep("^\\|", MD, value = TRUE)
ord <- vapply(c("Sex", "Female", "Male", "Race", "White", "Black", "Asian",
                "Age", "Mean (SD)", "Height", "Nothing behind this"),
              function(l) which(vapply(LAB, has, logical(1), l))[1], numeric(1))
ok(!any(is.na(ord)) && identical(order(ord), seq_along(ord)),
   "the renderer keeps the shell's row order, heading by heading")
ok(has(LAB[which(vapply(LAB, has, logical(1), "Female"))[1]], "&nbsp;&nbsp;Female"),
   "a row at indent 1 prints indented, because markdown drops the leading spaces")
ok(!has(LAB[which(vapply(LAB, has, logical(1), "| **Sex"))[1]], "&nbsp;&nbsp;Sex"),
   "...and a heading at indent 0 is not indented")
ok(has(LAB[1], "1L (N=)<br>Overall") && has(LAB[1], "1L (N=)<br>Quad"),
   "the column heading carries the group the shell put it in")
ok(any(vapply(MD, has, logical(1), "a. Age is age at index.")),
   "the footnotes print under the table")
ok(has(LAB[which(vapply(LAB, has, logical(1), "Mean (SD)"))[1]], "Mean (SD) [a]"),
   "a row carrying a footnote marker prints it")
ok(!any(vapply(MD, has, logical(1), "reads the S_ATTRITION")),
   "a note that is not a marker is not printed as one")
ok(any(vapply(MD, has, logical(1), "withheld and print as <25")) &&
     any(vapply(MD, has, logical(1), "could not be filled")),
   "the caption says what the floor was, how much it withheld and how much could not be filled")
ok({ cs <- render_csv(F1)
     identical(cs$ROW_ORDER, rep(1:11, each = 4)) &&
       identical(cs$COLUMN_ID[1:4], c("C1", "C2", "C3", "C4")) },
   "the tidy CSV is one row per cell, in the shell's order")
ok(all(c("REASON", "REASON_KIND", "SUPPRESSED", "FILLED") %in% names(render_csv(F1))),
   "...and carries why each cell is what it is")

cat("\n-- the generated contract, against the package that emits it --\n")
# R/scope.R no longer restates the package's registry; it reads the contract
# the package emits. The restatement is gone, so the drift it could carry is
# gone with it - but the shipped COPY can still fall behind the registry, and
# this is what stops that: regenerate from the package and compare.
#
# Byte-for-byte, not field-by-field. A field comparison passes a file that is
# right in the fields it happens to check, and the point of shipping a
# generated artefact is that it is the generator's output and nothing else.
local({
  reg <- file.path(dirname(ROOT), "variables", "R")
  if (!all(file.exists(file.path(reg, c("registry.R", "contract.R"))))) {
    cat("  --     the study package is not beside this folder, so the shipped",
        "contract is unchecked\n")
    return(invisible(NULL))
  }
  pkg <- new.env(parent = baseenv())
  e <- tryCatch({ for (f in c("registry.R", "contract.R"))
                    sys.source(file.path(reg, f), envir = pkg); NULL },
                error = function(x) x)
  ok(is.null(e), "the study package's contract emitter loads on its own")
  if (!is.null(e)) return(invisible(NULL))

  tmp <- file.path(tempdir(), "tfls_contract_check.csv")
  on.exit(unlink(tmp), add = TRUE)
  pkg$write_study_contract(tmp)
  shipped <- file.path(ROOT, TFLS_CONTRACT_FILE)
  ok(file.exists(shipped), "the contract is shipped with this folder, so a snapshot fills where the package is not installed")
  ok(identical(readLines(shipped, warn = FALSE), readLines(tmp, warn = FALSE)),
     "...and it is exactly what the package emits today: regenerated here and compared line for line")
  # The one value the run records about it. Computed by two copies of one
  # function, so the two are held to agree on the same file, and to agree
  # with the value a run would have written.
  ok(identical(contract_text_md5(shipped), pkg$contract_text_md5(shipped)) &&
       identical(contract_text_md5(shipped), pkg$study_contract_md5()),
     "...and hashes to the STUDY_CONTRACT_MD5 a run of that package records, by this folder's copy of the function and the package's")
  crlf <- file.path(tempdir(), "tfls_contract_crlf.csv")
  on.exit(unlink(crlf), add = TRUE)
  writeBin(charToRaw(paste0(paste(readLines(shipped, warn = FALSE), collapse = "\r\n"), "\r\n")), crlf)
  ok(identical(contract_text_md5(crlf), contract_text_md5(shipped)),
     "...and the same contract with other line endings hashes the same, so a Windows copy is not refused")

  # And the three objects built from it are the package's own answers.
  d <- pkg$study_contract()
  ok(setequal(TFLS_RELEASED_TABLES, names(pkg$SUPPRESSION_SPEC)),
     "the tables believed to have a released copy are the package's SUPPRESSION_SPEC")
  ok(setequal(names(TFLS_MODULE_OUTPUTS), unique(d$MODULE)) &&
       all(vapply(names(TFLS_MODULE_OUTPUTS), function(m)
             setequal(TFLS_MODULE_OUTPUTS[[m]], d$TABLE[d$MODULE == m]),
             logical(1))),
     "...and every module's outputs are the package's, table for table")
  ok(setequal(names(TFLS_OPTIONAL_OUTPUTS), d$TABLE[nzchar(d$SWITCH)]) &&
       all(TFLS_OPTIONAL_OUTPUTS[d$TABLE[nzchar(d$SWITCH)]] == d$SWITCH[nzchar(d$SWITCH)]),
     "...and the outputs a switch turns on are named under the switch the package records them by")
})

# A contract that is well formed and not the run's. read_study_contract()
# cannot see that - nothing in the file says which package emitted it - so it
# is the run's recorded hash that refuses it, in bind_run(), before anything
# is read under the prefix.
local({
  have <- tryCatch(contract_text_md5(file.path(ROOT, TFLS_CONTRACT_FILE)),
                   error = function(e) NA_character_)
  ok(!is.na(have), "the shipped contract can be hashed the way a run records it")
  md_row <- function(...) data.frame(
    RUN_ID = "r1", STATE = "complete", UPDATED_AT = "2026-09-15 00:00:00",
    COHORTS = "1L; 2L", MODULES = "eligibility; spine; cohorts; release",
    ..., stringsAsFactors = FALSE)
  bind <- function(md) {
    env <- runner_env(tempdir())
    reader <- function(t) if (identical(t, "S_RUN_METADATA")) md else NULL
    attr(reader, "read_errors") <- new.env()
    tryCatch({ capture.output(env$bind_run(reader, "here")); "BOUND" },
             error = function(x) conditionMessage(x))
  }
  ok(identical(bind(md_row(STUDY_CONTRACT_MD5 = have)), "BOUND"),
     "a run driven by the contract shipped here binds")
  e <- bind(md_row(STUDY_CONTRACT_MD5 = "00000000000000000000000000000000"))
  ok(grepl("is not the one the run under here was driven by", e, fixed = TRUE) &&
       grepl("Nothing was filled", e, fixed = TRUE),
     "a run driven by a different contract is refused before anything is read - a well-formed contract from another version can name a suppressed table as unsuppressed")
  ok(grepl("write_study_contract()", e, fixed = TRUE),
     "...and the message says where the right one comes from")
  said <- character(0)
  r <- local({
    env <- runner_env(tempdir())
    reader <- function(t) if (identical(t, "S_RUN_METADATA")) md_row() else NULL
    attr(reader, "read_errors") <- new.env()
    said <<- capture.output(out <- tryCatch(env$bind_run(reader, "here"), error = function(x) x))
    out
  })
  ok(is.data.frame(r) && any(grepl("recorded no contract hash", said, fixed = TRUE)),
     "a run that predates STUDY_CONTRACT_MD5 binds, and says out loud that this could not be checked")
  said2 <- capture.output(check_contract_binding(md_row(STUDY_CONTRACT_MD5 = "NA"), "here", ROOT))
  ok(any(grepl("recorded no contract hash", said2, fixed = TRUE)),
     "...as does one whose snapshot wrote the missing value as the string NA")
  # What the rates are per. The shells say 100,000 and read the rate as
  # written, so a run scaled otherwise is refused, and one that recorded no
  # multiplier binds with a warning.
  ok(identical(bind(md_row(STUDY_CONTRACT_MD5 = have, RATE_MULTIPLIER = "100000")), "BOUND"),
     "a run whose rates are per 100,000 person-years binds")
  e_per <- bind(md_row(STUDY_CONTRACT_MD5 = have, RATE_MULTIPLIER = "1000"))
  ok(grepl("per 1000 person-years (RATE_MULTIPLIER)", e_per, fixed = TRUE) &&
       grepl("labelled per 100,000", e_per, fixed = TRUE) && grepl("Nothing was filled", e_per, fixed = TRUE),
     "...and one scaled per 1,000 is refused before anything is read - the labels would be wrong by that factor")
  said3 <- capture.output(check_rate_multiplier(md_row(STUDY_CONTRACT_MD5 = have), "here"))
  ok(any(grepl("recorded no rate multiplier", said3, fixed = TRUE)),
     "a run that predates RATE_MULTIPLIER binds, and says out loud that this could not be checked")

  # WHICH study code, opt in. The run records the fingerprint of the R that
  # produced it; pinned, a run of any other code is refused.
  with_pin <- function(v, md) {
    old <- Sys.getenv("TFLS_STUDY_CODE_MD5", unset = NA)
    Sys.setenv(TFLS_STUDY_CODE_MD5 = v)
    on.exit(if (is.na(old)) Sys.unsetenv("TFLS_STUDY_CODE_MD5")
            else Sys.setenv(TFLS_STUDY_CODE_MD5 = old), add = TRUE)
    bind(md)
  }
  code_row <- function(...) md_row(STUDY_CONTRACT_MD5 = have, ...)
  ok(identical(bind(code_row(STUDY_CODE_MD5 = "abc123")), "BOUND"),
     "with TFLS_STUDY_CODE_MD5 unset, a run of any study code binds")
  ok(identical(with_pin("abc123", code_row(STUDY_CODE_MD5 = "abc123")), "BOUND"),
     "...and the approved fingerprint binds when it matches")
  e_code <- with_pin("abc123", code_row(STUDY_CODE_MD5 = "def456"))
  ok(grepl("produced by study code def456", e_code, fixed = TRUE) &&
       grepl("fill only from abc123", e_code, fixed = TRUE),
     "...while a run produced by other code is refused, naming both fingerprints")
  e_nocode <- with_pin("abc123", code_row())
  ok(grepl("records no code fingerprint", e_nocode, fixed = TRUE),
     "...and so is one that predates the column, rather than passed over")

  # Once per run. The recheck after the fill binds the same run again, and a
  # run that predates the column would otherwise warn twice.
  said3 <- local({
    env <- runner_env(tempdir())
    reader <- function(t) if (identical(t, "S_RUN_METADATA")) md_row() else NULL
    attr(reader, "read_errors") <- new.env()
    capture.output(env$bind_run(reader, "here", check_contract = FALSE))
  })
  ok(!any(grepl("recorded no contract hash", said3, fixed = TRUE)),
     "the recheck binds without repeating the contract warning")

  # A snapshot's metadata row is text. An all-digit hash left to read.csv
  # would come back as a number, and as a different string.
  snap <- file.path(tempdir(), paste0("tfls_snap_", sample.int(1e6, 1)))
  dir.create(file.path(snap, "p_"), recursive = TRUE)
  on.exit(unlink(snap, recursive = TRUE), add = TRUE)
  utils::write.csv(data.frame(RUN_ID = "20260915053000", STATE = "complete",
                              STUDY_CONTRACT_MD5 = "12345678901234567890123456789012",
                              stringsAsFactors = FALSE),
                   file.path(snap, "p_", "S_RUN_METADATA.csv"), row.names = FALSE)
  md_snap <- runner_env(tempdir())$snapshot_reader(snap, "p_")("S_RUN_METADATA")
  ok(identical(md_snap$STUDY_CONTRACT_MD5, "12345678901234567890123456789012") &&
       identical(md_snap$RUN_ID, "20260915053000"),
     "a snapshot reads the metadata row as text, so an all-digit hash or run id is the string it was")
})

# Every way the shipped contract can be wrong, refused rather than read.
#
# It used to be read loosely: any RELEASED value that was not "1" became FALSE,
# blank keys passed, a duplicate table passed, and a truncated file passed. All
# four failures push the SAME direction - the reader believes fewer tables are
# released than really are - and believing less here means the recoverability
# gate has nothing to refuse. So each is a stop.
local({
  good <- readLines(file.path(ROOT, TFLS_CONTRACT_FILE), warn = FALSE)
  with_contract <- function(lines) {
    d <- file.path(tempdir(), paste0("tfls_contract_", sample.int(1e6, 1)))
    dir.create(file.path(d, dirname(TFLS_CONTRACT_FILE)), recursive = TRUE,
               showWarnings = FALSE)
    writeLines(lines, file.path(d, TFLS_CONTRACT_FILE))
    on.exit(unlink(d, recursive = TRUE), add = TRUE)
    tryCatch({ read_study_contract(d); "READ" },
             error = function(e) conditionMessage(e))
  }
  ok(identical(with_contract(good), "READ"),
     "the shipped contract reads")

  maybe <- sub("^(safety,S_SAFETY_RATES),1,", "\\1,maybe,", good)
  ok(!identical(maybe, good) &&
       grepl("RELEASED must be 0 or 1", with_contract(maybe), fixed = TRUE),
     "a RELEASED value that is not a flag is refused, because reading it as 'not released' is the answer that publishes")

  blank <- c(good, "tte,,0,")
  ok(grepl("needs a module and a table", with_contract(blank), fixed = TRUE),
     "a row with no table is refused rather than carried as an empty name")

  dup <- c(good, "patterns,S_TTE,0,")
  ok(grepl("appear more than once", with_contract(dup), fixed = TRUE),
     "a table claimed by two modules is refused, since the first claim would silently win")

  trunc <- good[1:3]
  ok(grepl("names no released table and no release module", with_contract(trunc), fixed = TRUE),
     "a file cut short is refused - it loses the flags AND the release module together, which agree perfectly and describe a package with no disclosure control")

  no_copy <- grep("^release,", good, value = TRUE, invert = TRUE)
  ok(grepl("not the ones the release module writes", with_contract(no_copy), fixed = TRUE),
     "...and so is one whose release rows were dropped while the flags stayed, which is the same disagreement the other way")
})

cat("\n-- publishing one run's output over another's --\n")
# Exercised with real files, not read as source text. This is the step that can
# destroy a delivered TFL set, and the failure it has to survive is a PARTIAL
# one: a move that works for four files and not the fifth.
local({
  setup <- function(n_old = 3L, n_new = 3L) {
    root <- file.path(tempdir(), paste0("tfls_pub_", sample.int(1e6, 1)))
    out <- file.path(root, "out"); st <- file.path(out, ".stage")
    dir.create(st, recursive = TRUE, showWarnings = FALSE)
    for (i in seq_len(n_old))
      writeLines(paste0("OLD", i), file.path(out, sprintf("tfls_t%d.csv", i)))
    writeLines("OLD-MD", file.path(out, "tfls.md"))
    writeLines("mine", file.path(out, "notes.txt"))   # not the tool's
    for (i in seq_len(n_new))
      writeLines(paste0("NEW", i), file.path(st, sprintf("tfls_t%d.csv", i)))
    writeLines("NEW-MD", file.path(st, "tfls.md"))
    list(root = root, out = out, stage = st)
  }
  read1 <- function(p) if (file.exists(p)) readLines(p, warn = FALSE)[1] else NA_character_

  d <- setup()
  publish_outputs(d$stage, d$out, "r1")
  ok(identical(read1(file.path(d$out, "tfls_t1.csv")), "NEW1") &&
       identical(read1(file.path(d$out, "tfls.md")), "NEW-MD"),
     "a clean publish replaces the previous run's tables with this run's")
  ok(identical(read1(file.path(d$out, "notes.txt")), "mine"),
     "...and leaves a file the tool does not own exactly where it was")
  ok(!length(list.files(d$out, pattern = "^[.]tfls_previous")),
     "...with no set-aside copy left behind once it has succeeded")

  # A table dropped from the shell set must not survive as last run's CSV.
  d2 <- setup(n_old = 4L, n_new = 2L)
  publish_outputs(d2$stage, d2$out, "r2")
  ok(!file.exists(file.path(d2$out, "tfls_t3.csv")) &&
       !file.exists(file.path(d2$out, "tfls_t4.csv")),
     "a table no longer in the shell set does not stay behind from the run before")

  # THE FAILURE, injected rather than provoked. A locked file is what happens
  # in the field, and no portable filesystem trick reproduces it - so the one
  # call that can half-succeed is stubbed to half-succeed: every move in works
  # except the last, exactly the shape that leaves a directory holding two
  # runs.
  d3 <- setup()
  e <- local({
    f <- publish_outputs
    env <- new.env(parent = environment(publish_outputs))
    real <- base::file.rename
    # winslash, because dirname() returns "/" separators on every platform
    # while normalizePath() returns "\\" on Windows unless it is told
    # otherwise. Compared as they came, the two sides could never be equal
    # there: the stub would fall through to the real rename, the injected
    # failure would never happen, and every assertion below would pass
    # against a publish that had not been made to fail.
    into_out <- normalizePath(d3$out, winslash = "/", mustWork = FALSE)
    env$file.rename <- function(from, to) {
      moving_in <- length(to) > 1L &&
        all(dirname(normalizePath(to, winslash = "/", mustWork = FALSE)) ==
              into_out) &&
        any(grepl("[.]stage", from))
      if (!moving_in) return(real(from, to))
      keep <- seq_along(from)[-length(from)]
      out <- rep(FALSE, length(from))
      out[keep] <- real(from[keep], to[keep])
      out
    }
    environment(f) <- env
    tryCatch({ f(d3$stage, d3$out, "r3"); NA_character_ },
             error = function(x) conditionMessage(x))
  })
  ok(!is.na(e), "a publish that cannot complete stops rather than leaving the directory half replaced")
  ok(identical(read1(file.path(d3$out, "tfls_t1.csv")), "OLD1") &&
       identical(read1(file.path(d3$out, "tfls_t3.csv")), "OLD3") &&
       identical(read1(file.path(d3$out, "tfls.md")), "OLD-MD"),
     "...and every table of the run that WAS published is back, so the delivery is one run's and not two halves")
  ok(is.na(e) || grepl("previous run has been put back", e, fixed = TRUE) ||
       grepl("still published and unchanged", e, fixed = TRUE),
     "...and the message says so, rather than claiming nothing was touched when files had already gone")

  # The two directories this step names are named from the RUN ID, which is
  # warehouse data. Neither may leave the output directory, and the staging
  # one may not be shared.
  d5 <- setup()
  ok(safe_segment(tfls_path_tag("s223926_1_")) &&
       identical(tfls_path_tag("a/b"), "a_b") &&
       safe_segment(tfls_path_tag("../../etc")) &&
       safe_segment(tfls_path_tag("")) && safe_segment(tfls_path_tag(NA)),
     paste0("a run id becomes a name a directory can take, whatever the ",
            "warehouse had in it"))
  st5 <- tfls_staging_dir(d5$out, "../../escape")
  ok(identical(normalizePath(dirname(st5), winslash = "/", mustWork = FALSE),
               normalizePath(d5$out, winslash = "/", mustWork = FALSE)),
     paste0("...so the staging directory is inside the output directory, ",
            "which is what the unlink that clears it makes matter"))
  ok(!identical(tfls_staging_dir(d5$out, "r5"), tfls_staging_dir(d5$out, "r5")),
     paste0("...and two fills of the SAME run id stage in different ",
            "directories, because the first thing each does is clear its own"))
  d5b <- setup()
  pub5 <- function(id) publish_outputs(d5b$stage, d5b$out, id)
  e5 <- tryCatch({ pub5("../../escape"); NA_character_ },
                 error = function(x) conditionMessage(x))
  ok(is.na(e5) &&
       !length(list.files(dirname(dirname(d5b$out)), all.files = TRUE,
                          pattern = "^[.]tfls_previous_")),
     paste0("...and a run id that would have named a set-aside outside the ",
            "output directory names one inside it instead"))

  # A restore that cannot be made whole says so. Reporting a clean restore
  # over a directory holding part of each run is the one outcome this file
  # exists to prevent.
  d6 <- setup()
  e6 <- local({
    f <- restore_set_aside
    env <- new.env(parent = environment(restore_set_aside))
    env$file.remove <- function(x) rep(FALSE, length(x))
    environment(f) <- env
    prev6 <- file.path(d6$out, ".tfls_previous_r6")
    dir.create(prev6, showWarnings = FALSE, recursive = TRUE)
    file.rename(file.path(d6$out, "tfls_t1.csv"),
                file.path(prev6, "tfls_t1.csv"))
    tryCatch({ f(prev6, d6$out, partial = TRUE); NA_character_ },
             error = function(x) conditionMessage(x))
  })
  ok(!is.na(e6) && grepl("holds part of one run", e6, fixed = TRUE) &&
       grepl("tfls_t2.csv", e6, fixed = TRUE),
     paste0("a restore whose removals did not all succeed stops and names ",
            "the files, rather than putting the previous run back beside ",
            "them and calling it whole"))

  # The markers are the only trace a killed publish leaves, so a marker that
  # was not written is a publish that must not proceed.
  d7 <- setup()
  e7 <- local({
    f <- publish_outputs
    env <- new.env(parent = environment(publish_outputs))
    real <- base::file.create
    env$file.create <- function(...) {
      p <- c(...)[1]
      if (grepl("set_aside_complete", p, fixed = TRUE)) return(FALSE)
      real(...)
    }
    environment(f) <- env
    tryCatch({ f(d7$stage, d7$out, "r7"); NA_character_ },
             error = function(x) conditionMessage(x))
  })
  ok(!is.na(e7) && grepl("could not record the set-aside", e7, ignore.case = TRUE),
     paste0("a set-aside whose marker cannot be written stops the publish, ",
            "because that marker is what a kill part-way is read by"))
  ok(identical(read1(file.path(d7$out, "tfls_t1.csv")), "OLD1") &&
       identical(read1(file.path(d7$out, "tfls.md")), "OLD-MD") &&
       !length(list.files(d7$out, pattern = "^[.]tfls_previous",
                          all.files = TRUE)),
     "...and the previous run is back, whole, with no set-aside left behind")

  # The second marker cannot undo anything - the run is published by then -
  # so it does not fail the publish. What it must not do is leave a
  # set-aside the next publish would read as a half-finished move.
  d8 <- setup()
  e8 <- local({
    f <- publish_outputs
    env <- new.env(parent = environment(publish_outputs))
    real <- base::file.create
    env$file.create <- function(...) {
      p <- c(...)[1]
      if (grepl("move_in_complete", p, fixed = TRUE)) return(FALSE)
      real(...)
    }
    environment(f) <- env
    tryCatch({ f(d8$stage, d8$out, "r8"); NA_character_ },
             error = function(x) conditionMessage(x))
  })
  ok(is.na(e8) && identical(read1(file.path(d8$out, "tfls_t1.csv")), "NEW1") &&
       !length(list.files(d8$out, pattern = "^[.]tfls_previous",
                          all.files = TRUE)),
     paste0("a completed publish whose second marker cannot be written is ",
            "still published, and leaves no set-aside for the next one to ",
            "misread"))

  # The marker's REMOVAL, which is what makes a restore safe to interrupt.
  # Left in place, it still says the move in had begun - so a restore that
  # put half the previous run back and stopped left the next recovery
  # reading those rescued files as this run's half-published output, whose
  # first act is to delete them.
  dA <- setup()
  eA <- local({
    f <- restore_set_aside
    env <- new.env(parent = environment(restore_set_aside))
    real <- base::unlink
    env$unlink <- function(x, ...) {
      if (any(grepl("set_aside_complete", x, fixed = TRUE))) return(0L)
      real(x, ...)
    }
    environment(f) <- env
    prevA <- file.path(dA$out, ".tfls_previous_rA")
    dir.create(prevA, showWarnings = FALSE, recursive = TRUE)
    for (i in 1:3)
      file.rename(file.path(dA$out, sprintf("tfls_t%d.csv", i)),
                  file.path(prevA, sprintf("tfls_t%d.csv", i)))
    file.create(file.path(prevA, ".set_aside_complete"))
    list(err = tryCatch({ f(prevA, dA$out, partial = FALSE); NA_character_ },
                        error = function(x) conditionMessage(x)),
         prev = prevA)
  })
  ok(!is.na(eA$err) && grepl("set-aside marker", eA$err, fixed = TRUE),
     paste0("a set-aside marker that will not clear stops the restore, ",
            "because while it is there a restore cut short is read as this ",
            "run's output and deleted"))
  ok(identical(sort(basename(list.files(eA$prev, pattern = "[.]csv$"))),
               c("tfls_t1.csv", "tfls_t2.csv", "tfls_t3.csv")) &&
       !length(list.files(dA$out, pattern = "^tfls_.*[.]csv$")),
     paste0("...before anything was moved, so the previous run is whole ",
            "where it was and the next attempt can try again"))

  # The discard renames the BASENAME. Substituted over the whole path, an
  # output directory sitting under a folder of that name had its parent
  # rewritten instead, and the rename could never land.
  d9 <- setup()
  odd <- file.path(d9$root, ".tfls_previous_outer", "out")
  dir.create(file.path(odd, ".tfls_previous_r9"), recursive = TRUE)
  writeLines("OLD1", file.path(odd, "tfls_t1.csv"))
  ok(isTRUE(discard_set_aside(file.path(odd, ".tfls_previous_r9"))) &&
       !dir.exists(file.path(odd, ".tfls_previous_r9")) &&
       identical(read1(file.path(odd, "tfls_t1.csv")), "OLD1"),
     paste0("a set-aside is discarded even where the output directory's own ",
            "path carries the set-aside prefix"))

  # Two publishers. Domino can start two Jobs into one artifacts directory,
  # and the second would move its files in between the first one's.
  d4 <- setup()
  # The literal name, not the constant: this block has to reach its
  # assertions against a publisher that has no such constant.
  lock4 <- file.path(d4$out, ".tfls_publish.lock")
  dir.create(lock4)
  e4 <- tryCatch({ publish_outputs(d4$stage, d4$out, "r4"); NA_character_ },
                 error = function(x) conditionMessage(x))
  ok(!is.na(e4) && grepl("Another publish holds", e4, fixed = TRUE) &&
       identical(read1(file.path(d4$out, "tfls_t1.csv")), "OLD1"),
     "a second publisher into the same directory is refused, and the published run is untouched")
  # The property the lock exists for: the refused publisher must not take the
  # holder's lock with it on the way out, or the next one interleaves.
  ok(dir.exists(lock4),
     "...and leaves the other publisher's lock where it was")
  ok(grepl("remove the directory and run again", e4, fixed = TRUE),
     "...and the message says what a lock left by a killed publish is, and what to do")
  unlink(lock4, recursive = TRUE)
  publish_outputs(d4$stage, d4$out, "r4")
  ok(identical(read1(file.path(d4$out, "tfls_t1.csv")), "NEW1") &&
       !dir.exists(file.path(d4$out, TFLS_PUBLISH_LOCK)),
     "...and once it is gone the publish goes through and leaves no lock behind")

  # A KILLED publish, not a failed one: the process is gone mid-move and
  # nothing ran after it. Simulated by a file.rename that raises after the
  # first move in, so the set-aside directory and its marker are left exactly
  # as a kill would leave them. The next publish has to put that right before
  # it starts, and to a WHOLE set.
  killed_during <- function(d, when) {
    f <- publish_outputs
    env <- new.env(parent = environment(publish_outputs))
    real <- base::file.rename
    n <- 0L
    env$file.rename <- function(from, to) {
      # winslash on both sides - see the stub above for what comparing them
      # unnormalised costs on Windows.
      into_out <- all(dirname(normalizePath(to, winslash = "/", mustWork = FALSE)) ==
                        normalizePath(d$out, winslash = "/", mustWork = FALSE))
      moving_in <- into_out && any(grepl("[.]stage", from))
      setting_aside <- !into_out && any(grepl("tfls_previous", to))
      if ((when == "move_in" && moving_in) ||
          (when == "set_aside" && setting_aside)) {
        # Two files move, then the process dies. Two rather than one so a
        # file only the new run has can be among them - list.files() puts
        # tfls.md first, and every run has that.
        k <- seq_len(min(2L, length(from)))
        real(from[k], to[k])
        stop("killed")
      }
      real(from, to)
    }
    environment(f) <- env
    tryCatch(f(d$stage, d$out, paste0("k_", when)), error = function(x) NULL)
    # A killed process leaves its lock; the operator removes it, as the
    # message above says.
    unlink(file.path(d$out, TFLS_PUBLISH_LOCK), recursive = TRUE)
  }
  tool_files <- function(out) sort(list.files(out, pattern = TFLS_OUTPUT_PATTERN))
  prev_dirs <- function(out) list.files(out, pattern = "^[.]tfls_previous_", all.files = TRUE)

  d5 <- setup()
  # A table only the NEW run has, sorting right after tfls.md, so that it is
  # the second file to land - and so that a recovery which failed to remove
  # the interrupted run's files would leave it there to be seen. Every name
  # the old run has would be overwritten by the restore and hide that.
  writeLines("NEW-A0", file.path(d5$stage, "tfls_a0.csv"))
  killed_during(d5, "move_in")
  ok(length(prev_dirs(d5$out)) == 1L,
     "a publish killed while moving its tables in leaves the set-aside directory, which is the only trace of it")
  ok(identical(tool_files(d5$out), c("tfls.md", "tfls_a0.csv")) &&
       identical(read1(file.path(d5$out, "tfls.md")), "NEW-MD"),
     "...and the output directory holding two new files and no old ones: a mixture no reader could tell from a run")
  # Recovery on its own first, so what it leaves is seen before anything is
  # published over it.
  said <- capture.output(n5 <- recover_interrupted_publish(d5$out))
  ok(n5 == 1L && any(grepl("while moving its tables in", said, fixed = TRUE)),
     "the next publish says it found the interrupted one, and at which step")
  ok(identical(tool_files(d5$out), c("tfls.md", "tfls_t1.csv", "tfls_t2.csv", "tfls_t3.csv")) &&
       all(vapply(1:3, function(i) identical(read1(file.path(d5$out, sprintf("tfls_t%d.csv", i))), paste0("OLD", i)), logical(1))) &&
       identical(read1(file.path(d5$out, "tfls.md")), "OLD-MD") &&
       !length(prev_dirs(d5$out)),
     "...and resolves it to the PREVIOUS set, whole - the new run's two files gone, tfls_a0.csv included, and every old one back")
  # Then the next run's own stage, published over that.
  for (i in 1:3) writeLines(paste0("NEXT", i), file.path(d5$stage, sprintf("tfls_t%d.csv", i)))
  writeLines("NEXT-MD", file.path(d5$stage, "tfls.md"))
  said <- capture.output(publish_outputs(d5$stage, d5$out, "r5"))
  ok(identical(tool_files(d5$out), c("tfls.md", "tfls_t1.csv", "tfls_t2.csv", "tfls_t3.csv")) &&
       identical(read1(file.path(d5$out, "tfls_t1.csv")), "NEXT1") &&
       identical(read1(file.path(d5$out, "tfls_t3.csv")), "NEXT3") &&
       !length(prev_dirs(d5$out)),
     "...and what is published afterwards is the next run, whole, with the set-aside gone")

  d6 <- setup()
  killed_during(d6, "set_aside")
  ok(length(prev_dirs(d6$out)) == 1L &&
       identical(read1(file.path(d6$out, "tfls_t3.csv")), "OLD3") &&
       !file.exists(file.path(d6$out, "tfls.md")) &&
       !file.exists(file.path(d6$out, "tfls_t1.csv")),
     "a publish killed while setting the previous tables aside leaves some of them moved and some not")
  # This time the recovery is checked on its own, so the restored set can be
  # seen before anything is published over it.
  said <- capture.output(n <- recover_interrupted_publish(d6$out))
  ok(n == 1L && identical(tool_files(d6$out), c("tfls.md", "tfls_t1.csv", "tfls_t2.csv", "tfls_t3.csv")) &&
       identical(read1(file.path(d6$out, "tfls_t1.csv")), "OLD1") &&
       !length(prev_dirs(d6$out)),
     "...and recovery puts the PREVIOUS run back whole, because the new one never began to land")
  ok(any(grepl("while setting the previous tables aside", said, fixed = TRUE)),
     "...saying so")

  # Killed between the last move in and the discard of the set-aside: the new
  # set is complete and only the cleanup was lost, so recovery must NOT put
  # the old one back over it.
  d7 <- setup()
  prev7 <- file.path(d7$out, ".tfls_previous_k_done")
  dir.create(prev7)
  for (f in list.files(d7$out, pattern = TFLS_OUTPUT_PATTERN, full.names = TRUE))
    file.rename(f, file.path(prev7, basename(f)))
  file.create(file.path(prev7, TFLS_MARK_ASIDE))
  for (f in list.files(d7$stage, full.names = TRUE))
    file.rename(f, file.path(d7$out, basename(f)))
  file.create(file.path(prev7, TFLS_MARK_MOVED))
  said <- capture.output(recover_interrupted_publish(d7$out))
  ok(identical(read1(file.path(d7$out, "tfls_t1.csv")), "NEW1") &&
       !dir.exists(prev7) && any(grepl("only its cleanup was lost", said, fixed = TRUE)),
     "a publish killed after its last move in is recognised as complete, and the new set is kept")

  # The RECOVERY killed part-way. It restores by moving files one at a time,
  # and if it dies after some of them the next pass must move the rest - not
  # delete the ones it already put back because a marker still says the
  # output directory holds the interrupted run's files.
  d8 <- setup()
  killed_during(d8, "move_in")
  said <- capture.output(e8 <- tryCatch({
    f <- recover_interrupted_publish
    env <- new.env(parent = environment(recover_interrupted_publish))
    real <- base::file.rename
    env$file.rename <- function(from, to) {
      restoring <- length(from) > 1L && any(grepl("tfls_previous", from))
      if (restoring) { real(from[1], to[1]); stop("killed") }
      real(from, to)
    }
    # The moves happen in restore_set_aside(), called by the function under
    # test; re-homed too, or its file.rename is the real one.
    for (nm in c("restore_set_aside", "discard_set_aside")) {
      g <- get(nm); environment(g) <- env; env[[nm]] <- g
    }
    environment(f) <- env
    f(d8$out); NA_character_
  }, error = function(x) conditionMessage(x)))
  ok(identical(e8, "killed") && length(prev_dirs(d8$out)) == 1L,
     "a recovery killed after putting one file back leaves the set-aside, and the rest still in it")
  ok(!file.exists(file.path(prev_dirs(d8$out) |> (\(p) file.path(d8$out, p))(), TFLS_MARK_ASIDE)),
     "...with the first marker already gone, so the state reads as 'set aside cut short'")
  said <- capture.output(recover_interrupted_publish(d8$out))
  ok(identical(tool_files(d8$out), c("tfls.md", "tfls_t1.csv", "tfls_t2.csv", "tfls_t3.csv")) &&
       all(vapply(1:3, function(i) identical(read1(file.path(d8$out, sprintf("tfls_t%d.csv", i))), paste0("OLD", i)), logical(1))) &&
       identical(read1(file.path(d8$out, "tfls.md")), "OLD-MD") && !length(prev_dirs(d8$out)),
     "...and the next pass moves the rest back rather than deleting what the last pass restored: the previous set, whole")

  # A discard cut short. The set-aside is renamed out of the way before it
  # is removed, so nothing reads its markers while they are half gone.
  d9 <- setup()
  publish_outputs(d9$stage, d9$out, "r9")
  gone <- file.path(d9$out, ".tfls_discard_r9")
  dir.create(gone); writeLines("OLD9", file.path(gone, "tfls_t9.csv"))
  file.create(file.path(gone, TFLS_MARK_ASIDE))
  said <- capture.output(recover_interrupted_publish(d9$out))
  ok(!dir.exists(gone) && identical(read1(file.path(d9$out, "tfls_t1.csv")), "NEW1") &&
       !file.exists(file.path(d9$out, "tfls_t9.csv")),
     "a discard that was cut short is removed, and the published set is not touched")
  ok(!grepl("unlink(prev, recursive = TRUE)", paste(deparse(publish_outputs), collapse = "\n"), fixed = TRUE) &&
       grepl("discard_set_aside(prev)", paste(deparse(publish_outputs), collapse = "\n"), fixed = TRUE),
     "...and the publisher never unlinks a set-aside in place, where a kill would remove its markers in list order")

  # Nothing to publish is not a publish of nothing.
  d10 <- setup(n_new = 0L)
  unlink(file.path(d10$stage, "tfls.md"))
  e10 <- tryCatch({ publish_outputs(d10$stage, d10$out, "r10"); NA_character_ },
                  error = function(x) conditionMessage(x))
  ok(!is.na(e10) && grepl("Nothing to publish", e10, fixed = TRUE) &&
       identical(read1(file.path(d10$out, "tfls_t1.csv")), "OLD1") &&
       !length(prev_dirs(d10$out)),
     "an empty staging directory stops before anything is set aside, and the previous run stays published")

  # The messages do not point at a staging directory the runner has removed
  # by the time they print.
  ok(!grepl("complete in \", stage", paste(deparse(publish_outputs), collapse = "\n"), fixed = TRUE) &&
       !grepl("tables are in \", stage", paste(deparse(publish_outputs), collapse = "\n"), fixed = TRUE),
     "no refusal claims this run's tables are still in the staging directory, which write_outputs() removes on exit")
})

cat("\n-- the runner --\n")
RUNNER <- paste(readLines(file.path(ROOT, "run_tfls.R")), collapse = "\n")

local({
  out <- file.path(tempdir(), paste0("tfls_e2e_", sample.int(1e6, 1)))
  on.exit(unlink(out, recursive = TRUE), add = TRUE)
  env <- runner_env(out)
  dir.create(out, showWarnings = FALSE, recursive = TRUE)
  writeLines("stale", file.path(out, "tfls_T9.csv"))
  e <- tryCatch({ capture.output(env$write_outputs(list(F1), SH, 25, "e2e-1")); NA_character_ },
                error = function(x) conditionMessage(x))
  ok(is.na(e),
     paste0("write_outputs() runs end to end and returns",
            if (!is.na(e)) paste0("  [", e, "]") else ""))
  ok(file.exists(file.path(out, "tfls_T1.csv")) &&
       file.exists(file.path(out, "tfls.md")) &&
       file.exists(file.path(out, "tfls_unfilled.csv")),
     "...and the three files the documentation names are in the output directory")
  ok(!file.exists(file.path(out, "tfls_T9.csv")),
     "...with a table from a previous run gone")
  ok(!length(list.files(out, pattern = "^[.]tfls_", all.files = TRUE)),
     "...and nothing of the staging, the set-aside or the lock left behind")
  ok(any(grepl("^Run e2e-1, floor 25[.]$", readLines(file.path(out, "tfls.md"), warn = FALSE))),
     "...and tfls.md names the run and the floor it was filled under")
})
ok(has(RUNNER, 'gsub("~+~", " "'),
   "the script directory survives a space in a folder name")
ok(all(vapply(c("classes.R", "shells.R", "names.R", "stats.R", "suppress.R",
                "fill.R", "scope.R", "render.R", "publish.R"),
              function(f) has(RUNNER, f), logical(1))) &&
     setequal(list.files(file.path(ROOT, "R"), pattern = "[.]R$"),
              c("classes.R", "shells.R", "names.R", "stats.R", "suppress.R",
                "fill.R", "scope.R", "render.R", "publish.R")),
   "it sources the nine files that are in R/, and no file that is not")
ok(regexpr('if (!nzchar(src))', RUNNER, fixed = TRUE) <
     regexpr("library(DBI)", RUNNER, fixed = TRUE),
   "the source gate comes before library(DBI), so the plan prints where no driver is installed")
ok(!has(RUNNER, 'Sys.getenv("DATABRICKS_PWD"'),
   "the password is read only through the study package's own configuration, never by the runner")
ok(has(RUNNER, "tfls_floor_from_env()"),
   "the floor comes from the one function that will not let it fall below the protocol's")
ok(all(vapply(c("tfls_unfilled.csv", "tfls.md", "tfls_<table>.csv"),
              function(f) has(RUNNER, f), logical(1))),
   "it writes the files the documentation names")
ok(has(RUNNER, "tfls_write_csv"), "...through the writer that refuses an identifier")
ok(has(RUNNER, "run_identity(recheck())"),
   "the run is checked again after the tables were read, so a rebuild landing mid-read is caught")
ok(has(RUNNER, "reader <- run_reader(") && !has(RUNNER, "reader <- snapshot_reader(") &&
     !has(RUNNER, "reader <- warehouse_reader("),
   "every fill reads through the run-scoped reader, so neither source is handed to a fill unwrapped")
ok(has(RUNNER, "run_table_status(scope, table)$why"),
   "...and a row nothing could fill is told why in the run's own declaration")
ok(has(RUNNER, "run_scope(md)"),
   "the run is bound by what its metadata says it built, not only by its state")
ok(has(RUNNER, "TFLS_TTE_ELIGIBLE_ONLY") && has(RUNNER, "TFLS_COHORT_TABLE"),
   "the two settings that change what a number means are read, and the run says which way it went")
ok(has(RUNNER, "safe_segment(prefix)"),
   "a prefix is refused unless it is a plain name, because it is pasted into a path and a table name")

# A FILE path and a TABLE name are different problems and safe_segment() only
# answers the first. It allows a dot, which is a second identifier in a table
# name, and it refuses names this warehouse takes once they are quoted.
ok(identical(sql_name("s223926_"), "`s223926_`") &&
     !is.na(sql_name("_wk")) && !is.na(sql_name("wk-1")) &&
     !is.na(sql_name("2024")) && !is.na(sql_name("select")),
   "a table name is quoted rather than matched, so a leading underscore, a hyphen, an all-digit name and a reserved word all read")
ok(identical(sql_name("x; DROP TABLE p; --"), "`x; DROP TABLE p; --`"),
   "...and a statement comes out as one identifier with that name, which no warehouse has")
ok(is.na(sql_name("has`tick")) && is.na(sql_name("")) && is.na(sql_name(NA)),
   "...while a backtick, an empty name and a missing one are refused, because quoting cannot hold them")
ok(identical(sql_qualified_name("cat.sch.t"), "`cat`.`sch`.`t`") &&
     identical(sql_qualified_name("t"), "`t`"),
   "the input cohort table comes already qualified, and is quoted part by part")
ok(is.na(sql_qualified_name("a.b.c.d")) && is.na(sql_qualified_name("a.`b")),
   "...but no more than three parts, and none of them unquotable")
ok(has(RUNNER, "is.na(sql_name(sch$value))") && has(RUNNER, "is.na(sql_name(cat_$value))") &&
     has(RUNNER, "is.na(sql_qualified_name(coh$value))") &&
     !has(RUNNER, "safe_segment(schema)") && !has(RUNNER, "safe_segment(catalog)") &&
     !has(RUNNER, "safe_table_name("),
   "the three names that are only ever warehouse names are gated on quoting, not on a pattern")

# The same warehouse as the study run, by its names. An environment that
# carried that run used to stop short of the fill, because this wanted the
# same facts under names of its own.
local({
  env <- runner_env(tempdir())
  vars <- c("PROJECT_WORK_SCHEMA", "WORK_SCHEMA", "DOMINO_USER_NAME",
            "DOMINO_STARTING_USERNAME", "TFLS_CATALOG", "DATABRICKS_CATALOG",
            "TFLS_COHORT_TABLE", "INPUT_COHORT_TABLE")
  with_names <- function(..., f = function() env$warehouse_names()) {
    old <- Sys.getenv(vars, unset = NA)
    Sys.unsetenv(vars)
    on.exit({ for (v in vars) if (is.na(old[[v]])) Sys.unsetenv(v) else do.call(Sys.setenv, as.list(setNames(old[[v]], v))) }, add = TRUE)
    set <- c(...)
    if (length(set)) do.call(Sys.setenv, as.list(set))
    tryCatch(f(), error = function(e) conditionMessage(e))
  }
  r <- with_names(PROJECT_WORK_SCHEMA = "wk1", DATABRICKS_CATALOG = "cat1", INPUT_COHORT_TABLE = "ndmm_NDMM_COHORT")
  ok(is.list(r) && identical(r$schema, "wk1") && identical(r$catalog, "cat1") &&
       identical(r$cohort_table, "ndmm_NDMM_COHORT"),
     "the schema, catalog and cohort table the LOT build and the study run were given carry over to the fill unchanged")
  # Everything filled here is an S_* table, so the schema is the one the
  # STUDY run wrote into, resolved in that run's own order. Read the other
  # way round, an environment that gave the LOT build one schema and the
  # study another sent the fill to the LOT build's and reported the study's
  # tables missing.
  r <- with_names(WORK_SCHEMA = "study", PROJECT_WORK_SCHEMA = "lot",
                  DOMINO_USER_NAME = "usr00000")
  ok(is.list(r) && identical(r$schema, "study") &&
       identical(unname(r$from["schema"]), "WORK_SCHEMA"),
     paste0("...and where the two schema names differ, the fill reads the ",
            "one the study run wrote into, which is the order that run ",
            "resolves them in"))
  r <- with_names(PROJECT_WORK_SCHEMA = "lot", DOMINO_USER_NAME = "usr00000")
  ok(is.list(r) && identical(r$schema, "lot"),
     paste0("...with PROJECT_WORK_SCHEMA still the answer where the study ",
            "run had no override of its own"))
  # `catalog.schema` is how a schema reads on the warehouse, and the study
  # run accepts it, stripping the catalog when it matches. Taken whole it
  # became a schema of its own: every table was looked for under
  # catalog.`catalog.schema`, so a run written under a supported setting
  # was reported missing.
  r <- with_names(WORK_SCHEMA = "hive_metastore.usr00000",
                  DATABRICKS_CATALOG = "hive_metastore")
  ok(is.list(r) && identical(r$schema, "usr00000") &&
       identical(r$catalog, "hive_metastore"),
     paste0("a schema written as catalog.schema is read as the study run ",
            "reads it, with the matching catalog stripped"))
  r <- with_names(WORK_SCHEMA = "other.usr00000",
                  DATABRICKS_CATALOG = "hive_metastore")
  ok(is.character(r) && grepl("names catalog 'other'", r, fixed = TRUE) &&
       grepl("hive_metastore", r, fixed = TRUE),
     paste0("...and one naming a DIFFERENT catalog stops, naming both, ",
            "rather than reading tables from a warehouse nobody asked for"))
  r <- with_names(DOMINO_USER_NAME = "usr00000")
  ok(is.list(r) && identical(r$schema, "usr00000") && identical(r$catalog, "hive_metastore") &&
       identical(unname(r$from["schema"]), "DOMINO_USER_NAME"),
     "...and where they were given no schema, the Domino user's own, as the LOT engine resolves it")
  r <- with_names(PROJECT_WORK_SCHEMA = "wk1", TFLS_CATALOG = "cat2", DATABRICKS_CATALOG = "cat1",
                  TFLS_COHORT_TABLE = "other.sch.t", INPUT_COHORT_TABLE = "ndmm_NDMM_COHORT")
  ok(is.list(r) && identical(r$catalog, "cat2") && identical(r$cohort_table, "other.sch.t"),
     "...while a TFLS_* name still wins where a fill has to look elsewhere")
  r <- with_names()
  ok(is.character(r) && grepl("No WORK_SCHEMA", r, fixed = TRUE) &&
       grepl("PROJECT_WORK_SCHEMA", r, fixed = TRUE) && grepl("DOMINO_USER_NAME", r, fixed = TRUE),
     "with no schema from anywhere the fill stops, naming both places one could come from")
  r <- with_names(DOMINO_USER_NAME = "has`tick")
  ok(is.character(r) && grepl("DOMINO_USER_NAME 'has`tick' cannot be quoted", r, fixed = TRUE),
     "...and an unquotable name is refused under the name it came from")
})
ok(has(RUNNER, "safe_segment(prefix)") && has(RUNNER, "file.path(root, prefix)"),
   "...while the prefix keeps the path rule, because a path is built from it")
ok(has(RUNNER, "release_verdict(scope)") && has(RUNNER, "release_refused(scope)") &&
     has(RUNNER, "TFLS_ALLOW_RECOVERABLE is on"),
   "every run says on screen what its source's release left recoverable, since these tables are what a study hands out")
ok(has(RUNNER, 'd <- env_chr("TFLS_OUT_DIR")'),
   "the output directory can be moved, because a platform that captures one directory as a run's results does not capture the code tree")
ok(has(RUNNER, "envir = read_errors") && has(RUNNER, "why <- read_error(reader,") &&
     has(RUNNER, "is there and has no rows"),
   "a read that failed is reported with what it failed with, and told apart from a table that is there and empty")
ok(has(RUNNER, 'attr(f, "read_errors") <- read_errors') &&
     !has(RUNNER, "\nread_errors <- new.env"),
   "...and the record belongs to the reader, not the session, so one bind's failure is never reported against the next")
ok(has(RUNNER, "stage <- tfls_staging_dir(out_dir, run_id)") &&
     regexpr("tfls_write_csv(render_csv(f),\n                   file.path(stage,", RUNNER, fixed = TRUE) <
       regexpr("publish_outputs(stage, out_dir, run_id)", RUNNER, fixed = TRUE),
   "the run is written to a staging directory BEFORE anything published is touched, so a render that raises leaves the previous run whole")
ok(has(RUNNER, "publish_outputs(stage, out_dir, run_id)") &&
     !has(RUNNER, "file.rename(") && !has(RUNNER, "unlink(prev"),
   "...and the replacement itself is one call into R/publish.R, not file moves inlined where no test can reach them, with none of its locals referred to from here")
ok(has(RUNNER, "on.exit(unlink(stage, recursive = TRUE)"),
   "...with the staging directory cleaned up however the run ends")


# ---------------------------------------------------------------------------
# A second pass over the same code, written against the shells as data rather
# than against the functions: a broken shell file has to be refused by name, a
# curve small enough to check on paper has to come out right, and the
# disclosure rule has to hold at its edges. Kept in its own scope so the two
# passes cannot lend each other a fixture.
# ---------------------------------------------------------------------------
local({
  SHELL_DIR <- file.path(ROOT, "shells")
  # This pass asks whether a string appears anywhere in a rendered page, so it
  # needs the any() form rather than the host's single-string test.
  has <- function(x, s) any(grepl(s, x, fixed = TRUE))

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
  uniq <- SH$rows[SH$rows$label == "Total number of unique regimens", , drop = FALSE]
  ok(nrow(uniq) == 1 && identical(uniq$stat[1], "n_distinct") &&
       grepl("not how many patients", uniq$note[1], fixed = TRUE),
     "the row asking how many regimens asks for a count of distinct values, and its note says what it counts")

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
  ok(identical(stat_km_median(c(1, 2, 3), c(1, 0, 0))$text,
               "not reached (1.0, not reached)"),
     "...which prints as 'not reached', never as a blank or a zero, and beside the interval's own bounds")
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
  invisible(NULL)
})

cat("\n-- a line read without the regimen table --\n")
# The baseline rows name a line, and S_DEMOGRAPHICS carries none, so which
# patients are on it was read off S_SOC - and a run that skipped the SOC module
# refused every such row. S_LOT_PERIODS holds the same lines, so the Overall
# column fills from it, and fills the SAME, which is what these hold it to.
local({
  LP <- data.frame(PATID = IDS, COHORT = "1L", LOT_NUM = 1L,
                   PERIOD_START = as.Date("2020-01-01"),
                   PERIOD_END = as.Date("2021-01-01"), stringsAsFactors = FALSE)
  via <- function(tables) {
    rd <- function(name) tables[[toupper(name)]]
    fill_table(SH, "T1", fill_context(rd, SH$classes), floor_n = 25)$cells
  }
  pick <- function(cells, col) {
    x <- cells[cells$COLUMN_ID == col & cells$SECTION == 0L, ]
    x[order(x$ROW_ORDER), c("ROW_ORDER", "TEXT", "N", "DENOM", "FILLED", "SUPPRESSED")]
  }
  with_soc <- via(list(S_DEMOGRAPHICS = DEMO, S_SOC = SOC))
  without  <- via(list(S_DEMOGRAPHICS = DEMO, S_LOT_PERIODS = LP))
  a <- pick(with_soc, "C1"); b <- pick(without, "C1")
  rownames(a) <- NULL; rownames(b) <- NULL
  ok(sum(b$FILLED) > 0 && identical(a, b),
     "without S_SOC the Overall column fills from S_LOT_PERIODS, cell for cell as it does with it")
  cls <- without[without$COLUMN_ID == "C2" & without$SECTION == 0L, ]
  ok(nrow(cls) > 0 && all(cls$FILLED == 0L) &&
       all(grepl("S_SOC", cls$REASON[cls$ROW_LABEL == "Female"], fixed = TRUE)),
     "...while a regimen class column still needs S_SOC, and says so")
  none <- via(list(S_DEMOGRAPHICS = DEMO))
  c1 <- none[none$COLUMN_ID == "C1" & none$SECTION == 0L, ]
  ok(all(c1$FILLED == 0L) && all(grepl("LOT_NUM", c1$REASON[c1$ROW_LABEL == "Female"], fixed = TRUE)),
     "with neither table the line cannot be read, and the row is refused with the reason")
  # A line that started after this cohort's follow-up ended has an empty
  # period, and S_SOC never held it: ten such patients are not on the line.
  late <- LP
  late$PERIOD_END[1:10] <- as.Date("2019-06-01")
  lt <- via(list(S_DEMOGRAPHICS = DEMO, S_LOT_PERIODS = late))
  mean_row <- lt[lt$COLUMN_ID == "C1" & lt$ROW_LABEL == "Mean (SD)", ]
  ok(identical(as.numeric(mean_row$DENOM), 30),
     "a line whose period is empty - begun after follow-up ended - is not the cohort's, as S_SOC leaves it out")
})

# ---------------------------------------------------------------------------
# What a sum leaves out, a curve's two counts, and sums between tables.
#
# Three rules the suppression pass did not have. A curve publishes its events in
# N and its censored patients in DENOM less N, whatever the row prints. A row
# whose own filter narrows the column's population leaves out a number a reader
# can take. And a sum gives away whatever its printed terms leave out - not only
# a single missing cell - including a population split across two tables.
# ---------------------------------------------------------------------------
cat("\n-- a curve's two counts, and what a filter leaves out --\n")
local({
  km <- function(stat, n, denom, pop_n = NA_real_) {
    d <- mk_cells(stat, n, denom)
    d$POP_N <- pop_n
    d
  }
  # 30 patients, 3 events: every statistic of the curve publishes the 3.
  few <- suppress_cells(rbind(km("km_events", 3, 30), km("km_censored", 27, 30),
                              km("km_median", 3, 30), km("km_prob", 3, 30)), 25)
  ok(all(few$SUPPRESSED == 1L),
     "a curve with 3 events among 30 withholds its events, censored, median and probabilities alike")
  ok(all(grepl("with the event", few$REASON[few$STAT != "km_censored"], fixed = TRUE)),
     "...and says it was the events")
  # km_censored carries the censored in N, so its events are DENOM less N.
  cz <- suppress_cells(km("km_censored", 27, 30), 25)
  ok(cz$SUPPRESSED == 1L && grepl("with the event", cz$REASON, fixed = TRUE),
     "a censored row of 27 among 30 is withheld for the 3 events its population less it gives away")
  # 100 patients, 90 events: the 10 censored are published by subtraction.
  mostly <- suppress_cells(km("km_median", 90, 100), 25)
  ok(mostly$SUPPRESSED == 1L && grepl("censored", mostly$REASON, fixed = TRUE),
     "a median with 90 events among 100 is withheld for the 10 censored its N and DENOM give away")
  both <- suppress_cells(rbind(km("km_events", 40, 100), km("km_median", 40, 100),
                               km("km_prob", 40, 100)), 25)
  ok(all(both$SUPPRESSED == 0L),
     "a curve with 40 events and 60 censored is published in full")
  rate <- suppress_cells(mk_cells("rate", c(3, 4), c(300, 300)), 25)
  ok(all(rate$SUPPRESSED == 0L),
     "a rate is not a curve: the package's own rule for it stands")

  # A row filtered to TTE_ELIGIBLE=1 over a column of 70, 60 of them eligible:
  # 30 events and 30 censored, so the curve itself reaches the floor, and only
  # the 10 the filter leaves out do not.
  left <- suppress_cells(km("km_events", 30, 60, pop_n = 70), 25)
  ok(left$SUPPRESSED == 1L && grepl("left out by", left$REASON, fixed = TRUE),
     "a filter leaving 10 of the column's 70 out is withheld: any unfiltered row gives the 10 away")
  ok(suppress_cells(km("km_events", 30, 60, pop_n = 60), 25)$SUPPRESSED == 0L &&
       suppress_cells(km("km_events", 30, 60, pop_n = 100), 25)$SUPPRESSED == 0L,
     "...and one leaving none out, or 40, is not")
  ok(suppress_cells(km("km_events", 30, 60), 25)$SUPPRESSED == 0L,
     "a frame that does not say its population before the filter is read as it always was")
})

cat("\n-- what the printed terms of a sum leave out --\n")
local({
  # Sex over a column of 100 with no row for the 10 whose sex is not recorded:
  # 100 - 55 - 35 is those 10, on the page, with nothing withheld at all.
  miss <- suppress_cells(mk_cells("n_pct", c(55, 35), c(100, 100)), 25)
  ok(sum(miss$SUPPRESSED) == 2L,
     "levels leaving 10 of the column's 100 uncounted give the 10 away, so a level goes - and then the other")
  exact <- suppress_cells(mk_cells("n_pct", c(60, 40), c(100, 100)), 25)
  ok(all(exact$SUPPRESSED == 0L),
     "levels that add up to their denominator leave nothing out and nothing goes")
  # Two withheld cells whose total is itself under the floor.
  pair <- suppress_cells(mk_cells("n_pct", c(80, 10, 10), c(100, 100, 100)), 25)
  ok(all(pair$SUPPRESSED == 1L),
     "two withheld cells adding up to 20 take the 80 with them")
  pair2 <- suppress_cells(mk_cells("n_pct", c(60, 20, 20), c(100, 100, 100)), 25)
  ok(pair2$SUPPRESSED[1] == 0L && sum(pair2$SUPPRESSED) == 2L,
     "...while two adding up to 40 leave the 60 published")
})

cat("\n-- a population split by its regimen classes --\n")
local({
  CLS <- data.frame(table_id = "T4", label = c("Overall", "Quad", "Triplet", "Other"),
                    order = 1:4, column_id = c("1L_OVERALL", "1L_Q", "1L_T", "1L_O"),
                    group = "1L", cohort = "1L", line = "1",
                    class = c("OVERALL", "ACD38_QUAD", "OTHER_TRIP", "OTHER"),
                    subgroup = "", period = "", note = "", stringsAsFactors = FALSE)
  # A mean over each column: the classes' populations add up to Overall's, and
  # the 12 in the smallest class sit under the floor.
  ages <- shaped_cells("T4", "Age", CLS$column_id,
    list(list(label = "Age, mean", indent = 1, n = c(300, 200, 88, 12), stat = "mean_sd")),
    c(300, 200, 88, 12))
  sa <- suppress_cells(ages, 25, list(columns = CLS))
  ok(is.na(seen(sa, "Age, mean", "1L_O")) && is.na(seen(sa, "Age, mean", "1L_T")) &&
       !is.na(seen(sa, "Age, mean", "1L_OVERALL")),
     "a mean over a class of 12 is withheld, and so is the next class's: Overall's population less the rest gives the 12 away")
  ok(no_lone_unknown(sa, list(columns = CLS)),
     "...and no split is left with one member missing")
  old_rule <- suppress_cells(ages, 25, NULL)
  ok(!is.na(seen(old_rule, "Age, mean", "1L_T")),
     "without the shell's columns there is no split to read, as before")
})

cat("\n-- a population split in another table --\n")
local({
  SHIP <- load_shells(file.path(ROOT, "shells"))
  # 1L: 200 patients, 180 under 75 and 20 aged 75 or over. The 20 are under the
  # floor in T5c; T4's Overall less T5c's under-75 is exactly them.
  ids <- sprintf("P%03d", 1:200)
  tte <- data.frame(PATID = ids, COHORT = "1L", LOT_NUM = 1L, TTE_ELIGIBLE = 1L,
                    TTNT_MONTHS = seq_len(200) / 5, TTNT_EVENT = rep(0:1, 100),
                    TTD_MONTHS = seq_len(200) / 5, TTD_EVENT = rep(0:1, 100),
                    OS_MONTHS = seq_len(200) / 5, OS_EVENT = rep(0:1, 100),
                    stringsAsFactors = FALSE)
  demo <- data.frame(PATID = ids, COHORT = "1L", LOT_NUM = 1L,
                     AGE_GROUP = c(rep("<75", 180), rep("75+", 20)),
                     stringsAsFactors = FALSE)
  rd <- function(name) list(S_TTE = tte, S_DEMOGRAPHICS = demo)[[toupper(name)]]
  ctx <- fill_context(rd, SHIP$classes)
  row_of <- function(f, tid, col, label) {
    c <- f[[tid]]$cells
    c[c$COLUMN_ID == col & c$ROW_LABEL == label & c$SECTION == 0L, , drop = FALSE][1, ]
  }
  alone <- fill_table(SHIP, "T5c", ctx, 25)
  under <- alone$cells[alone$cells$COLUMN_ID == "AGE_1L_LT75" &
                         alone$cells$ROW_LABEL == "Events, n (%)", ][1, ]
  ok(under$FILLED == 1L && under$SUPPRESSED == 0L,
     "T5c on its own publishes the under-75 curve: it has no Overall to be read against")
  all_t <- fill_all(SHIP, ctx, 25)
  t4 <- row_of(all_t, "T4", "1L_OVERALL", "Events, n (%)")
  lt <- row_of(all_t, "T5c", "AGE_1L_LT75", "Events, n (%)")
  ge <- row_of(all_t, "T5c", "AGE_1L_GE75", "Events, n (%)")
  ok(t4$FILLED == 1L && t4$SUPPRESSED == 0L && t4$N == 100,
     "T4's 1L Overall is published: 100 events among 200")
  ok(ge$SUPPRESSED == 1L,
     "T5c's 20 patients aged 75 or over are under the floor")
  ok(lt$SUPPRESSED == 1L && grepl("in T4", lt$REASON, fixed = TRUE),
     "...and T5c's under-75 goes with them once the tables are read together, naming the table it was read against")
  t5 <- all_t[["T5c"]]$cells
  lt_all <- t5[t5$COLUMN_ID == "AGE_1L_LT75" & t5$FILLED == 1L & t5$SECTION == 0L, ]
  ok(nrow(lt_all) > 0 && all(lt_all$SUPPRESSED == 1L),
     "...every statistic of it, the medians and probabilities included")
  both <- rbind(all_t[["T4"]]$cells, all_t[["T5c"]]$cells)
  ok(no_lone_unknown(both, SHIP),
     "no sum between the two tables is left with one member missing")
  keys_match <- intersect(all_t[["T4"]]$cells$ROW_KEY[all_t[["T4"]]$cells$SECTION == 0L],
                          all_t[["T5c"]]$cells$ROW_KEY[all_t[["T5c"]]$cells$SECTION == 0L])
  ok(length(keys_match) >= 27L,
     "the shipped T4 and T5c read the same rows, so the two can be matched row for row")
})

# Warehouse mode reads through the STUDY PACKAGE's db_q(), which retries through
# with_retry(), whose defaults come from study_config(). A config built and never
# registered stopped every warehouse run at its first read with "No config" -
# and every check of the runner above read run_tfls.R as text, which is exactly
# how a line like that survives. So this one drives a read down the real
# db_q() -> with_retry() path. Only the driver call at the very bottom is
# answered here, through the seam the package leaves for it (dbi_query).
cat("\n-- warehouse mode reads through the study package's own db_q() --\n")
local({
  pdir <- file.path(dirname(ROOT), "variables")
  if (!file.exists(file.path(pdir, "R", "db_utils_223926.R"))) {
    cat("  --     the study package is not beside this folder, so the",
        "warehouse read path is unchecked\n")
    return(invisible(NULL))
  }
  # Built here rather than through runner_env(): the package has to sit
  # BETWEEN the runner's functions and this session, so warehouse_reader()
  # finds db_q() without the package landing on top of this file's helpers.
  load_runner <- function(parent) {
    env <- new.env(parent = parent)
    for (ex in parse(file.path(ROOT, "run_tfls.R"), keep.source = FALSE)) {
      is_fn <- is.call(ex) && identical(ex[[1]], as.name("<-")) &&
        is.call(ex[[3]]) && identical(ex[[3]][[1]], as.name("function"))
      if (is_fn) eval(ex, env)
    }
    env
  }
  fake_con <- structure(list(), class = "DBIConnection")
  # Answers every query and remembers what it was asked. Returns a function
  # that reads the record, because the stub's own frame is where it lives.
  answer <- function(spkg) {
    seen <- character(0)
    spkg$dbi_query <- function(con, sql) {
      seen <<- c(seen, sql)
      data.frame(RUN_ID = "r1", STATE = "complete", stringsAsFactors = FALSE)
    }
    function() seen
  }
  quietly <- function(expr) {
    out <- NULL
    utils::capture.output(out <- expr)
    out
  }

  # The runner as shipped.
  spkg <- new.env(parent = globalenv())
  run  <- load_runner(spkg)
  cfg  <- quietly(run$open_study_package(pdir, "usr00000", "hive_metastore",
                                         envir = spkg))
  ok(identical(spkg$study_config(), cfg),
     "opening the study package registers the config it builds")
  ok(identical(cfg$work_schema, "usr00000") && identical(cfg$catalog, "hive_metastore"),
     "...with the run's schema and catalog on it")
  sent <- answer(spkg)
  rd <- run$warehouse_reader(fake_con, "hive_metastore", "usr00000", "s223926_")
  got <- rd("S_RUN_METADATA")
  errs <- as.list(attr(rd, "read_errors"))
  ok(is.data.frame(got) && identical(got$STATE, "complete") && !length(errs),
     "a warehouse read reaches the connection and comes back as a table")
  ok(length(sent()) == 1L && has(sent(), "`s223926_S_RUN_METADATA`") &&
       has(sent(), "`hive_metastore`.`usr00000`."),
     "...having asked once, for the table under the run's own prefix and schema")

  # The defect, reproduced, so this block can tell the two apart: the same
  # package sourced the same way, the config never registered.
  bare  <- new.env(parent = globalenv())
  quietly(for (f in c("config_223926.R", "db_utils_223926.R"))
    source(file.path(pdir, "R", f), local = bare))
  sent2 <- answer(bare)
  rd2 <- load_runner(bare)$warehouse_reader(fake_con, "hive_metastore",
                                            "usr00000", "s223926_")
  got2 <- rd2("S_RUN_METADATA")
  ok(is.null(got2) &&
       has(unlist(as.list(attr(rd2, "read_errors"))), "No config") &&
       !length(sent2()),
     "an unregistered config stops before the connection, and says so")

  ok(has(RUNNER, "cfg <- open_study_package(pkg, schema, catalog)"),
     "main() opens the package through that one function, not by hand")

  # The two resolutions one after the other, as main() runs them. Each was
  # checked on its own, and they disagreed: a catalog given to TFLS alone,
  # with the schema written catalog.schema, passed warehouse_names() and then
  # stopped in the package, which checked the schema against
  # DATABRICKS_CATALOG's default instead.
  in_env <- function(set, f) {
    vars <- c("TFLS_CATALOG", "DATABRICKS_CATALOG", "WORK_SCHEMA",
              "PROJECT_WORK_SCHEMA", "DOMINO_USER_NAME", "DOMINO_STARTING_USERNAME")
    old <- Sys.getenv(vars, unset = NA)
    on.exit(for (v in vars) if (is.na(old[[v]])) Sys.unsetenv(v) else
      do.call(Sys.setenv, stats::setNames(list(old[[v]]), v)), add = TRUE)
    Sys.unsetenv(vars)
    do.call(Sys.setenv, as.list(set))
    tryCatch(f(), error = function(e) conditionMessage(e))
  }
  split_cat <- c(TFLS_CATALOG = "analytics", WORK_SCHEMA = "analytics.usr00000")
  both <- new.env(parent = globalenv())
  cfg3 <- in_env(split_cat, function() {
    brun <- load_runner(both)
    wn <- brun$warehouse_names()
    quietly(brun$open_study_package(pdir, wn$schema, wn$catalog, envir = both))
  })
  ok(is.list(cfg3) && identical(cfg3$catalog, "analytics") &&
       identical(cfg3$work_schema, "usr00000") &&
       identical(both$study_config(), cfg3),
     paste0("a catalog given to TFLS alone, with the schema written ",
            "catalog.schema, resolves once and opens the package with both"))
  own <- new.env(parent = globalenv())
  quietly(for (f in c("config_223926.R", "db_utils_223926.R"))
    source(file.path(pdir, "R", f), local = own))
  left <- in_env(split_cat, function() own$cfg_defaults())
  ok(is.character(left) && has(left, "names catalog 'analytics'"),
     "...where the package, left to resolve them itself, stops on that same environment")
  invisible(NULL)
})

check_skip_wiring()
test_report_status(pass, fail, skipped)
