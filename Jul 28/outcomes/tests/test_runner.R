#!/usr/bin/env Rscript
# The outcome definitions, held to protocol Table 4. No warehouse: the SQL is
# built as a string, and the arithmetic is checked by evaluating the same rule
# in R over hand-made cases.
#
#   Rscript "outcomes/tests/test_runner.R"

ROOT <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                                 fixed = TRUE))) else getwd()
  dirname(d)
})
pass <- 0L; fail <- 0L
ok <- function(cond, what) {
  if (isTRUE(cond)) { pass <<- pass + 1L; cat("  ok    ", what, "\n") }
  else { fail <<- fail + 1L; cat("  FAIL  ", what, "\n") }
}
stops <- function(expr, what) ok(inherits(tryCatch(expr, error = function(e) e), "error"), what)
runs  <- function(expr, what) ok(!inherits(tryCatch(expr, error = function(e) e), "error"), what)
has   <- function(x, s) grepl(s, x, fixed = TRUE)
if (requireNamespace("glue", quietly = TRUE)) library(glue) else
  glue <- function(..., .envir = parent.frame()) {
    t <- paste0(..., collapse = "")
    m <- gregexpr("\\{[^{}]+\\}", t)[[1]]
    if (m[1] == -1L) return(t)
    len <- attr(m, "match.length"); out <- character(0); pos <- 1L
    for (i in seq_along(m)) {
      out <- c(out, substr(t, pos, m[i] - 1L),
               paste(as.character(eval(parse(
                 text = substr(t, m[i] + 1L, m[i] + len[i] - 2L)), .envir)), collapse = ""))
      pos <- m[i] + len[i]
    }
    paste0(c(out, substr(t, pos, nchar(t))), collapse = "")
  }

sys.source(file.path(ROOT, "R", "load_inputs.R"), envir = globalenv())
load_pipeline_inputs(ROOT, "config.csv")
sys.source(file.path(ROOT, "R", "config_out.R"),     envir = globalenv())
sys.source(file.path(ROOT, "R", "db_utils_out.R"),   envir = globalenv())
sys.source(file.path(ROOT, "R", "build_outcomes.R"), envir = globalenv())
sys.source(file.path(ROOT, "R", "run_outcomes.R"),   envir = globalenv())

BASE <- outcomes_base_sql("s.LINES", "s.COH")
TTE  <- outcomes_tte_sql(BASE, "r1")

cat("\n-- the follow-up end is the protocol's, not the LOT run's --\n")
# 6.1: "from the index date ... until the end of continuous enrollment or end
# of study period or death, whichever occurs first."
ok(has(TTE, "least(cast(c.ENDDATE as date)") && has(TTE, "c.ENDDATE_CE"),
   "follow-up ends at the earlier of ENDDATE and ENDDATE_CE")
# A NULL inside least() swallows the expression, so a patient who never
# disenrolled would get a NULL follow-up end and drop out of every outcome.
ok(has(TTE, "coalesce(cast(c.ENDDATE_CE as date), cast(c.ENDDATE as date))"),
   "...and a patient who never disenrolled is not lost to a NULL")

cat("\n-- TTNT, TTD and OS as Table 4 defines them --\n")
ok(has(TTE, "coalesce(b.NEXT_LOT_START_DT") && has(TTE, "AS TTNT_DT"),
   "TTNT ends at the next LOT or death, whichever is first")
ok(has(TTE, "coalesce(b.LOT_END_DT") && has(TTE, "AS TTD_DT"),
   "TTD adds the line's own end to those two")
ok(has(TTE, "coalesce(b.DEATH_DT, date('9999-12-31'))                 AS OS_DT"),
   "OS ends at death only")
ok(has(TTE, "AS TTNT_EVENT") && has(TTE, "AS TTD_EVENT") && has(TTE, "AS OS_EVENT"),
   "each outcome carries its own event flag")
ok(has(TTE, "datediff(least(TTNT_DT, FU_END_DT), LOT_START_DT)"),
   "the time is measured to the event or the censoring date, whichever is first")

cat("\n-- the arithmetic, on cases rather than on the text --\n")
# The same rule the SQL applies, in R, so a case can be reasoned about.
tte <- function(start, nxt, death, fu_end) {
  d <- function(x) if (is.null(x) || is.na(x)) as.Date("9999-12-31") else as.Date(x)
  s <- as.Date(start); f <- as.Date(fu_end)
  ev <- min(d(nxt), d(death))
  list(event = as.integer(ev < f), days = as.numeric(min(ev, f) - s))
}
a <- tte("2020-01-01", "2020-07-01", NA, "2021-01-01")
ok(a$event == 1 && a$days == 182, "a next line inside follow-up is an event at its own date")
b <- tte("2020-01-01", NA, "2020-04-10", "2021-01-01")
ok(b$event == 1 && b$days == 100, "death with no next line is an event at the death date")
d <- tte("2020-01-01", NA, NA, "2020-06-30")
ok(d$event == 0 && d$days == 181, "neither: censored at the follow-up end")
e <- tte("2020-01-01", "2021-06-01", NA, "2021-01-01")
ok(e$event == 0 && e$days == 366,
   "a next line AFTER follow-up ends is censoring, not an event")
f <- tte("2020-01-01", "2020-07-01", "2020-09-01", "2021-01-01")
ok(f$event == 1 && f$days == 182, "next line before death: the earlier one wins")
g <- tte("2020-01-01", "2020-09-01", "2020-07-01", "2021-01-01")
ok(g$event == 1 && g$days == 182, "...and death before the next line, likewise")

cat("\n-- the next line is the one that follows, not LOT_NUM + 1 --\n")
# A gap in the numbering would read as "no next line" and censor a patient who
# plainly had one.
ok(has(TTE, "lead(l.LOT_START_DT) OVER (PARTITION BY l.PATID ORDER BY l.LOT_NUM)"),
   "the next line comes from lead() over the patient's ordered lines")
# On the code, not the text: this file's own comment says "LOT_NUM + 1", and
# matching that would pass whatever the SQL did.
CODE <- paste(grep("^\\s*--", strsplit(as.character(TTE), "\n")[[1]],
                   invert = TRUE, value = TRUE), collapse = "\n")
ok(!has(CODE, "LOT_NUM + 1"), "...and not from an assumed numbering")

cat("\n-- attrition: the four outcomes are exclusive --\n")
ATT <- outcomes_attrition_sql("s.TTE")
ok(has(ATT, "AS N_NEXT_LOT") && has(ATT, "AS N_DIED") &&
     has(ATT, "AS N_DISCON_NO_NEXT") && has(ATT, "AS N_LOST_TO_FU"),
   "all four of Table 4's categories are counted")
# A patient who starts a next line and later dies belongs to the next-line
# count; every other category is conditioned on there being no next line.
ok(length(gregexpr("NEXT_LOT_NUM IS NULL", ATT)[[1]]) == 3,
   "the other three are all conditioned on there being no next line")

cat("\n-- months are months --\n")
GAP <- outcomes_line_gap_sql("s.TTE")
ok(has(GAP, "30.4375"),
   "a month is the mean Gregorian month, not 30 days")
ok(abs(365.25 / 30.4375 - 12) < 1e-9, "...which divides the year into twelve")

cat("\n-- it reads a finished run and nothing else --\n")
bo <- paste(readLines(file.path(ROOT, "R", "run_outcomes.R"), warn = FALSE), collapse = "\n")
ok(!has(bo, "CREATE OR REPLACE TABLE {wrk(") && !has(bo, "LOT_LONG_FINAL} AS"),
   "it writes no cohort table and no LOT table")
ok(has(bo, 'out_tbl("LOT_LONG_FINAL")') && has(bo, "wrk(cfg$input_cohort_table)"),
   "the lines carry the LOT prefix and the cohort is named whole")

STATUS <- list(RUN_ID = "L1", STATE = "complete", UPDATED_AT = "t",
               INPUT_COHORT_TABLE = "sch.ndmm_NDMM_COHORT",
               CONTRACT_DEVIATIONS = "")
mk <- function(lot = STATUS) {
  e <- new.env(parent = globalenv())
  assign("out_tbl", function(t) paste0("sch.ndmm_", t), envir = e)
  assign("log_msg", function(...) invisible(NULL), envir = e)
  assign("db_q", function(con, sql) {
    if (is.null(lot)) stop("TABLE_OR_VIEW_NOT_FOUND")
    as.data.frame(lot, stringsAsFactors = FALSE)
  }, envir = e)
  f <- check_lot_run; environment(f) <- e; f
}
refuses <- function(f, why, what) {
  m <- tryCatch({ f(NULL, "ndmm_", "ndmm_NDMM_COHORT"); "" }, error = conditionMessage)
  ok(nzchar(m) && grepl(why, m, fixed = TRUE), what)
}
runs(mk()(NULL, "ndmm_", "ndmm_NDMM_COHORT"), "a complete run over this cohort is accepted")
refuses(mk(modifyList(STATUS, list(STATE = "running"))), "is marked 'running'",
        "an unfinished LOT run is refused")
refuses(mk(modifyList(STATUS, list(INPUT_COHORT_TABLE = "sch.other_COH"))),
        "sch.other_COH", "a run built over another cohort is refused")
refuses(mk(modifyList(STATUS, list(CONTRACT_DEVIATIONS = "gap_days=60"))),
        "LOT_CONTRACT_OVERRIDE", "a run with a contract override is refused")
refuses(mk(lot = NULL), "No LOT run is recorded", "no LOT run at all is refused")

cat("\n-- the arguments are pinned the way the other packages pin them --\n")
stops(pin_cohort(cfg_defaults, "", "ndmm_"), "a missing cohort table stops it")
stops(pin_cohort(cfg_defaults, "NDMM_COHORT", "ndmm"), "a prefix without a trailing _ stops it")
stops(pin_cohort(cfg_defaults, "sch.NDMM_COHORT", "ndmm_"),
      "a schema-qualified cohort name stops it - the schema comes from settings")
runs(pin_cohort(cfg_defaults, "ndmm_NDMM_COHORT", "ndmm_"), "a whole cohort name and a prefix are taken")

cat("\n-- it can actually run --\n")
scan <- local({
  fns <- character(0); bound <- character(0)
  walk <- function(e) {
    if (is.call(e)) {
      if (is.name(e[[1]])) {
        nm <- as.character(e[[1]])
        if (nm %in% c("<-", "=", "<<-") && length(e) > 2L && is.name(e[[2]]))
          bound <<- c(bound, as.character(e[[2]])) else fns <<- c(fns, nm)
      }
      # A parameter is a name the function itself binds - with_retry(fn) calls
      # fn(), and fn is not a missing function.
      if (is.call(e) && identical(as.character(e[[1]])[1], "function") &&
          !is.null(names(e[[2]]))) bound <<- c(bound, names(e[[2]]))
      for (i in seq_along(e)) if (!is.null(e[[i]])) try(walk(e[[i]]), silent = TRUE)
    } else if (is.function(e)) { bound <<- c(bound, names(formals(e))); walk(body(e)) }
  }
  for (f in c(list.files(file.path(ROOT, "R"), "[.]R$", full.names = TRUE),
              file.path(ROOT, "build.R")))
    for (x in parse(f, keep.source = FALSE)) walk(x)
  setdiff(unique(fns), unique(bound))
})
missing <- Filter(function(f) !exists(f, envir = globalenv()) && !exists(f, envir = baseenv()) &&
                    !any(vapply(search(), function(s) exists(f, where = s, inherits = FALSE),
                                logical(1))), scan)
ok(!length(missing),
   if (length(missing)) paste0("calls a function that does not exist: ",
                               paste(missing, collapse = ", "))
   else "every function it calls exists")

cat("\n", strrep("-", 52), "\n", sep = "")
cat(sprintf("%d passed, %d failed\n", pass, fail))
if (fail > 0L) quit(status = 1L)
