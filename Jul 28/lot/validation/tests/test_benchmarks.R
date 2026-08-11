#!/usr/bin/env Rscript
# Checks on the distribution benchmarks.
#
# The loader, the verdicts and the survival arithmetic all run here. What
# cannot run is the SQL, so the Kaplan-Meier FORMULA is checked against a
# worked example in R - the same expression the statement encodes - and the
# translation is checked by reading it. Getting the survival curve wrong would
# produce a plausible number nobody could tell from a right one, which is the
# failure worth spending a test on.
#
#   Rscript "lot/validation/tests/test_benchmarks.R"

ROOT <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                                 fixed = TRUE))) else getwd()
  dirname(d)
})

pass <- 0L; fail <- 0L
ok <- function(cond, what) {
  if (isTRUE(cond)) { pass <<- pass + 1L; cat("  ok     ", what, "\n") }
  else              { fail <<- fail + 1L; cat("  FAIL   ", what, "\n") }
}
runs  <- function(expr, what) ok(is.null(tryCatch({ expr; NULL },
                                 error = conditionMessage)), what)
stops <- function(expr, what) ok(!is.null(tryCatch({ expr; NULL },
                                 error = conditionMessage)), what)

source(file.path(ROOT, "R", "benchmarks.R"))
REF <- file.path(ROOT, "benchmarks.csv")

cat("\n-- the reference file ships empty, with every row already in it --\n")
runs(read_benchmarks(REF), "benchmarks.csv loads")
refs <- read_benchmarks(REF)
ok(all(BENCHMARK_COLS %in% names(refs)),
   "it carries every column the comparison needs")
# Blank rows rather than an empty file: whoever has the literature can see
# exactly which figures are wanted, and a row nobody filled reports itself.
ok(all(is.na(refs$published_value)),
   "no published value is filled in - none was invented")
ok(setequal(unique(refs$metric), names(BENCHMARK_METRICS)),
   "...and there is a row for every metric the harness measures")
ok(all(nzchar(refs$notes)),
   "...each carrying the definition a published figure has to match")
ok(sum(refs$metric == "pct_regimen_at_line") >= 15,
   "...with room for the top regimens at each of the first lines")

cat("\n-- and it is read strictly, because a wrong row is worse than no row --\n")
tmp <- file.path(tempdir(), "bench_test.csv")
wr <- function(rows) { write.csv(rows, tmp, row.names = FALSE, na = ""); tmp }
base <- refs[1, , drop = FALSE]
stops(read_benchmarks(file.path(tempdir(), "nope.csv")),
      "a missing file stops rather than comparing against nothing")
b <- base; b$published_value <- "2"; b$source <- ""
stops(read_benchmarks(wr(b)),
      "a published value with no source is refused - it would be a citation nobody can chase")
b <- base; b$published_value <- "about two"; b$source <- "Someone 2024"
stops(read_benchmarks(wr(b)), "...and a value that is not a number")
b <- base; b$metric <- "not_a_metric"
stops(read_benchmarks(wr(b)), "...and a metric the harness does not measure")
# Comparability is a claim about three things, and a blank is not one of them.
# Two studies can differ entirely because one counted maintenance as a line, so
# a median quoted as comparable without saying which algorithm produced it is
# the number most likely to be repeated and least able to be checked.
cited <- function(x) { x$published_value <- "2"; x$source <- "Someone 2024"
                       x$source_population <- "NDMM, US claims"
                       x$source_followup <- "median 36 months"
                       x$source_algorithm <- "IMWG-based, maintenance not a line"
                       x }
for (col in c("source_population", "source_followup", "source_algorithm")) {
  b <- cited(base); b$comparable <- "yes"; b[[col]] <- ""
  stops(read_benchmarks(wr(b)),
        paste0("claiming comparable with no ", col, " is refused"))
}
b <- cited(base); b$comparable <- "caveat"; b$source_algorithm <- ""
stops(read_benchmarks(wr(b)), "...and 'caveat' is a claim too, so it is held to the same")
# Staying silent is always allowed: blank comparable already falls back to "no".
b <- cited(base); b$comparable <- ""
b$source_population <- ""; b$source_followup <- ""; b$source_algorithm <- ""
runs(read_benchmarks(wr(b)),
     "...but a value recorded without claiming comparability needs none of it")
b <- cited(base); b$comparable <- "yes"
runs(read_benchmarks(wr(b)), "...and a fully described comparison loads")
# Semantic states that parse. Each has a number and a source and is wrong about
# what the number is, which no amount of column checking would catch.
b <- cited(base); b$comparable <- "caveat"; b$notes <- ""
stops(read_benchmarks(wr(b)), "'caveat' with no caveat is 'yes' with a hedge on it")
b <- cited(base); b$unit <- "count"; b$metric <- "pct_reaching_line"; b$line <- "2"
stops(read_benchmarks(wr(b)), "a percentage filed as a count")
b <- cited(base); b$metric <- "pct_reaching_line"; b$line <- "2"; b$unit <- "pct"
b$published_value <- "140"
stops(read_benchmarks(wr(b)), "...and a percentage outside 0-100")
b <- cited(base); b$metric <- "pct_reaching_line"; b$unit <- "pct"; b$line <- ""
stops(read_benchmarks(wr(b)), "a per-line metric with no line, which keys on a blank")
b <- cited(base); b$metric <- "pct_regimen_at_line"; b$unit <- "pct"; b$line <- "1"
b$regimen <- ""
stops(read_benchmarks(wr(b)), "...and a regimen benchmark with no regimen")
b2 <- rbind(cited(base), cited(base))
stops(read_benchmarks(wr(b2)),
      "two references on one key, which merge into one observation twice")
b <- base; b$published_value <- "2"; b$source <- "Someone 2024"; b$comparable <- "maybe"
stops(read_benchmarks(wr(b)), "...and a comparability that is not yes/caveat/no")
b <- base[, setdiff(names(base), "source_algorithm")]
stops(read_benchmarks(wr(b)), "...and a file missing a column")
b <- cited(base); b$comparable <- "no"
runs(read_benchmarks(wr(b)),
     "a complete row loads - including one recorded as not comparable, which is a finding")

cat("\n-- a difference is two studies differing until somebody says otherwise --\n")
obs <- data.frame(metric = "median_lines_per_patient", line = NA_integer_,
                  regimen = NA_character_, observed = 2, denom = 100,
                  censored = NA_integer_, events = NA_integer_,
                  stringsAsFactors = FALSE)
mkref <- function(val, cmp) {
  r <- refs[refs$metric == "median_lines_per_patient", , drop = FALSE]
  r$published_value <- val; r$comparable <- cmp; r$source <- "Someone 2024"; r
}
ok(identical(compare_benchmarks(obs, mkref(NA, ""))$verdict, "no reference supplied"),
   "a row nobody supplied says so rather than passing quietly")
ok(identical(compare_benchmarks(obs, mkref(3, "no"))$verdict, "recorded, not comparable"),
   "a source marked not comparable is recorded and scored as nothing")
# The default direction matters: an unmarked row must not become evidence.
ok(identical(compare_benchmarks(obs, mkref(3, NA))$verdict, "recorded, not comparable"),
   "...and an UNMARKED source defaults to not comparable, never to comparable")
ok(identical(compare_benchmarks(obs, mkref(3, "caveat"))$verdict, "compared with caveat"),
   "a caveated source is compared and says so")
r <- compare_benchmarks(obs, mkref(3, "yes"))
ok(identical(r$verdict, "compared") && identical(r$difference, -1),
   "...and a comparable one reports the difference")
ok(!any(grepl("^(pass|fail|PASS|FAIL)$", compare_benchmarks(obs, mkref(3, "yes"))$verdict)),
   "no verdict is a pass or a fail")

cat("\n-- the survival curve, against a worked example --\n")
# The formula the SQL encodes: S(t) = exp(cumsum(log(1 - d/n))), median is the
# first t where S <= 0.5. Five patients, three events, two censored.
#
#   t=10 n=5 d=1 -> .8      t=40 n=2 d=1 -> .3
#   t=20 n=4 d=1 -> .6      t=50 n=1 d=0 -> .3
#   t=30 n=3 d=0 -> .6      median = 40, the first t at or below .5
km_median <- function(t, ev) {
  tt <- sort(unique(t))
  d  <- vapply(tt, function(x) sum(ev[t == x]), numeric(1))
  lv <- vapply(tt, function(x) sum(t == x), numeric(1))
  n  <- length(t) - c(0, cumsum(lv)[-length(lv)])
  s  <- exp(cumsum(ifelse(n > 0 & d < n, log(1 - d / n),
                   ifelse(n > 0 & d == n, -1e9, 0))))
  m  <- tt[s <= 0.5]
  if (length(m)) min(m) else NA_real_
}
ok(identical(km_median(c(10, 20, 30, 40, 50), c(1, 1, 0, 1, 0)), 40),
   "the worked example gives the median the hand calculation does")
# Censoring is the whole point. Dropping the two censored patients leaves
# events at 10/20/40 and a median of 20 - half the truth, and exactly the
# number a naive 'median among those who progressed' would report.
ok(identical(km_median(c(10, 20, 40), c(1, 1, 1)), 20),
   "...and dropping the censored patients halves it, which is the error being avoided")
ok(identical(km_median(10, 1), 10),
   "a single patient with an event gives a curve that reaches zero, not NULL")
ok(is.na(km_median(c(10, 20), c(0, 0))),
   "...and no events at all gives no median rather than a number")

cat("\n-- and the statement encodes that, not the naive version --\n")
bn <- readLines(file.path(ROOT, "R", "benchmarks.R"), warn = FALSE)
sql <- bench_ttnt_sql("F", "P", 1)
# LEFT JOIN to the next line: an INNER JOIN here is the naive version, and it
# is a one-word difference.
ok(grepl("LEFT JOIN nxt n USING (PATID)", sql, fixed = TRUE),
   "patients without the next line are kept, not inner-joined away")
ok(grepl("ELSE datediff(o.obs_end, c.t0) END AS t", sql, fixed = TRUE),
   "...and censored at their observation end rather than dropped")
ok(grepl("exp(sum(CASE WHEN n_risk > 0 AND d < n_risk THEN log(1.0 - d / n_risk)",
         sql, fixed = TRUE),
   "the survival expression is the one the worked example checks")
ok(grepl("WHEN n_risk > 0 AND d = n_risk THEN -1e9", sql, fixed = TRUE),
   "...with d = n floored, so the curve reaches zero instead of going NULL")
ok(grepl("min(t) FROM surv WHERE s_t <= 0.5", sql, fixed = TRUE),
   "...and the median is the first time at or below one half")
ok(any(grepl("not the median among those who progressed", bn, fixed = TRUE)),
   "the naive version is named as the thing being avoided")

cat("\n-- a duration that is really a censoring is not folded in --\n")
d <- bench_duration_sql("F")
ok(grepl("LOT_BASE_END_REASON,'') <> 'STUDY_END'", d, fixed = TRUE),
   "lines still open at study end are excluded from the median")
ok(grepl("AS censored", d, fixed = TRUE),
   "...and counted, so the reader can see how much was set aside")
ok(any(grepl("LOT_BASE_LENGTH is inclusive", bn, fixed = TRUE)),
   "the inclusive length is stated, since an off-by-one here is a day per line")

cat("\n-- a regimen percentage is out of everyone at that line --\n")
# An allogeneic line carries no regimen string by construction - induction rows
# are suppressed for it. Summing the named regimens to get the denominator
# drops those patients, and every percentage comes out high under a heading
# that says "% of line-n patients". Same mistake that made the transition
# Sankeys read a blank regimen as no line at all.
rg <- bench_regimen_sql("F", 5)
ok(grepl("tot AS (SELECT LOT_NUM, count(*) AS n_line FROM pat", rg, fixed = TRUE),
   "the denominator is counted over every line at n, not over the named ones")
ok(!grepl("sum(n) AS n_line", rg, fixed = TRUE),
   "...not by summing the regimens, which excludes the blank-regimen ALLO lines")
# The filter still belongs on the NUMERATOR: a blank regimen is not a regimen
# to name, it is a patient with no regimen string.
ok(grepl("trim(LOT_BASE_MEDS) <> ''", rg, fixed = TRUE),
   "...while the rows themselves are still only the named regimens")
ok(regexpr("n_line FROM pat", rg, fixed = TRUE) <
     regexpr("trim(LOT_BASE_MEDS)", rg, fixed = TRUE),
   "...and the patient count is taken before the regimen filter, not after it")
ok(grepl("including \nallogeneic lines|including allogeneic lines",
         BENCHMARK_METRICS$pct_regimen_at_line$defn),
   "the definition says what the denominator is, since the top-N will not sum to 100")

cat("\n-- and a measurement names the run it came from --\n")
# lot_out() with a blank prefix resolves to the UNPREFIXED tables. If some
# older run's are sitting in the schema they read perfectly, and the benchmark
# table comes out of a different study with nothing in it to say so.
source(file.path(ROOT, "R", "run_binding.R"))
.status <- NULL
wrk <- function(t) paste0("sch.", t)
db_q <- function(con, sql) if (is.null(.status)) stop("no such table") else .status
log_msg <- function(...) invisible(NULL)
stops(require_lot_run(NULL, "", "BENCH_IGNORE_BUILD_STATE"),
      "a blank OBJECT_PREFIX is refused, not resolved to the unprefixed tables")
stops(require_lot_run(NULL, "ndmm", "BENCH_IGNORE_BUILD_STATE"),
      "...and a prefix that is not one")
stops(require_lot_run(NULL, "ndmm_", "BENCH_IGNORE_BUILD_STATE"),
      "a prefix with no run recorded is refused rather than measured on trust")
.status <- data.frame(RUN_ID = "r2", STATE = "running",
                      INPUT_COHORT_TABLE = "ndmm_NDMM_COHORT",
                      STUDY_END = "2024Q4", stringsAsFactors = FALSE)
stops(require_lot_run(NULL, "ndmm_", "BENCH_IGNORE_BUILD_STATE"),
      "...and so is a run that did not finish, since it replaced the tables anyway")
Sys.setenv(BENCH_IGNORE_BUILD_STATE = "TRUE")
runs(require_lot_run(NULL, "ndmm_", "BENCH_IGNORE_BUILD_STATE"),
     "...unless the operator says they know it failed before writing anything")
Sys.unsetenv("BENCH_IGNORE_BUILD_STATE")
.status$STATE <- "complete"
got <- require_lot_run(NULL, "ndmm_", "BENCH_IGNORE_BUILD_STATE")
ok(identical(got$run, "r2") && identical(got$cohort, "ndmm_NDMM_COHORT"),
   "a finished run comes back with its id and the cohort it was built from")
# The status tables disagree on case between the two builds, so the read has to.
.status <- data.frame(run_id = "r3", state = "COMPLETE",
                      input_cohort_table = "c", stringsAsFactors = FALSE)
ok(identical(require_lot_run(NULL, "ndmm_", "X")$run, "r3"),
   "...whatever case the status table spells its columns in")
# STUDY_END was added later; naming it in the SELECT would make an older run's
# status table unreadable, which reads as no run at all - the softest failure.
ok(is.na(require_lot_run(NULL, "ndmm_", "X")$study_end),
   "...and a status table predating STUDY_END still reads, without it")
# A sensitivity cell is a complete, well-formed LOT run of a different
# algorithm. Comparing its distributions to a published figure would attribute
# the difference to this cohort rather than to the threshold that was changed.
.status <- data.frame(RUN_ID = "r4", STATE = "complete", INPUT_COHORT_TABLE = "c",
                      CONTRACT_DEVIATIONS = "max_lot=8 (contract 5)",
                      stringsAsFactors = FALSE)
m <- tryCatch({ require_lot_run(NULL, "ndmm_", "X"); "" }, error = conditionMessage)
ok(grepl("LOT_CONTRACT_OVERRIDE", m, fixed = TRUE) && grepl("max_lot=8", m, fixed = TRUE),
   "a run built as a different algorithm is refused, and says which setting")
.status$CONTRACT_DEVIATIONS <- ""
runs(require_lot_run(NULL, "ndmm_", "X"),
     "...while an empty deviation column is a contract build, which is every production run")

cat("\n-- and it measures as many lines as that run actually built --\n")
# cfg$max_lot is what this package is configured for. Point the harness at a
# run built with a different cap and it asks for lines that run never built, or
# leaves out lines it did - with nothing in the output to say which.
.status <- data.frame(CONTRACT_SETTINGS = "allo_lot_span=single_day|max_lot=8|sct_tandem_days=180",
                      RUN_TIMESTAMP = "2026-01-01", stringsAsFactors = FALSE)
ok(identical(lot_run_contract(NULL, "ndmm_", "max_lot"), "8"),
   "the measured run's own max_lot is read out of what it recorded")
ok(identical(lot_run_contract(NULL, "ndmm_", "sct_tandem_days"), "180"),
   "...by name, not by position in the string")
# max_lot=5 must not match a key that merely ends in it.
.status$CONTRACT_SETTINGS <- "lot_n_induction_window_days=30|max_lot=5"
ok(identical(lot_run_contract(NULL, "ndmm_", "max_lot"), "5"),
   "...and a key that another key ends with does not match it")
.status <- NULL
ok(is.null(lot_run_contract(NULL, "ndmm_", "max_lot")),
   "an older run with no metadata gives nothing, so the caller can say it fell back")
rb <- readLines(file.path(ROOT, "run_benchmarks.R"), warn = FALSE)
ok(any(grepl("bench_reaching_sql(final, max_lot)", rb, fixed = TRUE)) &&
     !any(grepl("as.integer(cfg$max_lot) - 1L", rb, fixed = TRUE)),
   "the runner measures to the run's value, not to this package's config")

cat("\n-- what the ask wanted that a harness cannot supply --\n")
rb <- readLines(file.path(ROOT, "run_benchmarks.R"), warn = FALSE)
ok(any(grepl("Nothing here invents one", rb, fixed = TRUE)),
   "the script says the published figures are not its to write")
ok(any(grepl("BENCH_EXECUTE", rb, fixed = TRUE)),
   "...and measuring is opt-in, so the definitions can be read first")
ok(any(grepl("require_lot_run(con, cfg$object_prefix", rb, fixed = TRUE)),
   "...and it binds to one finished run before it measures anything")
ok(any(grepl("res$run_id <- run$run", rb, fixed = TRUE)),
   "...which travels out with the numbers, since a benchmark table outlives its session")

cat("\n", strrep("-", 52), "\n", sep = "")
cat(sprintf("%d passed, %d failed\n", pass, fail))
if (fail > 0L) quit(status = 1L)
