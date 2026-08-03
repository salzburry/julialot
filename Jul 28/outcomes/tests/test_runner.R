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
# The event rule is LIFTED OUT OF THE GENERATED SQL and evaluated, not restated
# here. A hand-written copy is a second implementation: it agrees with whatever
# the author believed, passes, and says nothing about what the warehouse runs.
# Changing the shipped boundary has to fail these.
sql_cond <- function(sql, flag) {
  # Cut at the flag, then back to the nearest CASE WHEN. Matching forwards from
  # "CASE WHEN" takes the first one in the whole statement, which is in the
  # base subquery - the extracted text was then several clauses of unrelated SQL.
  head <- strsplit(sql, paste0("THEN 1 ELSE 0 END AS ", flag), fixed = TRUE)[[1]][1]
  stopifnot(!is.na(head), nchar(head) < nchar(sql))
  x <- sub("(?s)^.*CASE WHEN ", "", head, perl = TRUE)
  x <- gsub("\n\\s*", " ", trimws(x))
  x <- gsub("coalesce(", "cly(", x, fixed = TRUE)
  x <- gsub("\\bAND\\b", "&", gsub("\\bNOT\\b", "!", gsub("\\bOR\\b", "|", x)))
  gsub("(?<![<>!=])=(?!=)", "==", x, perl = TRUE)   # SQL = is R ==
}
cly <- function(...) { v <- c(...); v[!is.na(v)][1] }
COND <- lapply(c(TTNT = "TTNT_EVENT", TTD = "TTD_EVENT", OS = "OS_EVENT"),
               function(f) sql_cond(as.character(TTE), f))
ok(all(vapply(COND, nzchar, logical(1))), "all three event rules lift out of the SQL")

# fu_end is DERIVED, not supplied. The cohort clamps ENDDATE at the death date
# (build_nndm.R: least(study_end, coalesce(DEATH_DT, study_end))), so a case
# pairing a death with a later follow-up end is a row the cohort cannot write -
# and it was the case that hid a strict boundary making every death a censoring.
fu_end_of <- function(study_end, death, ce_end = NA) {
  as.Date(min(c(as.Date(study_end),
                if (!is.na(death))  as.Date(death),
                if (!is.na(ce_end)) as.Date(ce_end))), origin = "1970-01-01")
}
SENT <- as.Date("9999-12-31")
fire <- function(which, ...) {
  e <- list2env(list(...), parent = environment())
  isTRUE(eval(parse(text = COND[[which]]), envir = e))
}
tte <- function(start, nxt, death, study_end, ce_end = NA) {
  d <- function(x) if (is.null(x) || is.na(x)) SENT else as.Date(x)
  s <- as.Date(start); f <- fu_end_of(study_end, death, ce_end)
  ev <- min(d(nxt), d(death))
  list(event = as.integer(fire("TTNT", TTNT_DT = ev, FU_END_DT = f)),
       days = as.numeric(min(ev, f) - s), fu_end = f)
}
a <- tte("2020-01-01", "2020-07-01", NA, "2021-01-01")
ok(a$event == 1 && a$days == 182, "a next line inside follow-up is an event at its own date")
b <- tte("2020-01-01", NA, "2020-04-10", "2021-01-01")
ok(b$fu_end == as.Date("2020-04-10"),
   "a death IS the follow-up end - the cohort clamps ENDDATE at it")
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
# Disenrolled, then died outside observation. The death is not an event: it was
# never seen. This is the one case where a strict test happens to be right, and
# the reason the fix is "on or before" rather than "on".
h <- tte("2020-01-01", NA, "2020-09-01", "2021-01-01", ce_end = "2020-06-30")
ok(h$fu_end == as.Date("2020-06-30") && h$event == 0 && h$days == 181,
   "disenrolled before dying: censored at disenrolment, not an event")

# OS and TTD, on their own lifted rules. OS was identically 0: a death IS the
# follow-up end, so a strict test could never fire and the curve had no events.
dth <- as.Date("2020-04-10")
ok(fire("OS", OS_DT = dth, FU_END_DT = dth), "OS: a death on the follow-up end is an event")
ok(!fire("OS", OS_DT = SENT, FU_END_DT = as.Date("2021-01-01")),
   "OS: no death is not an event - the sentinel cannot reach the boundary")
ok(!fire("OS", OS_DT = dth, FU_END_DT = as.Date("2020-01-31")),
   "OS: a death after observation ended is still censoring")
# TTD is the exception: a line whose own end IS the run-out did not end.
fu <- as.Date("2026-03-31")
ok(!fire("TTD", TTD_DT = fu, FU_END_DT = fu, LOT_END_DT = fu,
         LOT_END_REASON = "STUDY_END"),
   "TTD: a line still running when the study stopped is censored, not discontinued")
dis <- as.Date("2025-11-02")
ok(fire("TTD", TTD_DT = dis, FU_END_DT = fu, LOT_END_DT = dis,
        LOT_END_REASON = "DISCONTINUATION"),
   "TTD: a line that actually ended is an event at its end")
ok(fire("TTD", TTD_DT = dth, FU_END_DT = dth, LOT_END_DT = dth,
        LOT_END_REASON = "DEATH"),
   "TTD: a line ended by death is an event, on the boundary")

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

cat("\n-- the diagnosis date comes from the base cohort, not the cohort --\n")
# NDMM_COHORT's INDEX_DATE is the 1L treatment start; the MM diagnosis date is
# a different date and is not on it. NDMM_BASE_COHORT carries MM_DX_DT and is
# checkpointed, so it is read from there rather than the cohort being rebuilt.
DX <- outcomes_tte_sql(outcomes_base_sql("s.LINES", "s.COH", "s.BASE"), "r1")
ok(has(DX, "FROM s.BASE") && has(DX, "LEFT JOIN"),
   "the base cohort is joined for MM_DX_DT")
# glue() trims a template's leading blank line, so the fragment began at the
# "L" of LEFT and interpolating it straight after n.PATID emitted
# "n.PATIDLEFT JOIN". The substring test above passes on that - "LEFT JOIN" is
# still in there - so the join has to be checked where it attaches.
ok(!has(DX, "n.PATIDLEFT"),
   "...and the join is a separate token, not welded onto the column before it")
ok(has(DX, "datediff(c.INDEX_DATE, x.MM_DX_DT) AS DX_TO_LOT1_DAYS"),
   "time to 1L is measured from the diagnosis to the cohort's 1L index")
ok(has(DX, "LEFT JOIN"),
   "...left, so a patient missing from the base cohort keeps every other outcome")
# Without it the columns are absent rather than guessed - an overall-cohort run
# has no MM diagnosis date to offer.
ok(has(TTE, "cast(NULL as date) AS MM_DX_DT") && !has(TTE, "FROM s.BASE"),
   "with no base cohort the diagnosis columns are NULL, not invented")
D1 <- outcomes_dx_to_lot1_sql("s.TTE")
ok(has(D1, "WHERE LOT_NUM = 1"),
   "one row per patient: the 1L rows only, not once per line reached")
# The cohort build takes the first therapy claim ON OR AFTER the diagnosis, so
# a negative gap would mean that rule had broken.
ok(has(D1, "DX_TO_LOT1_DAYS < 0 THEN 1 ELSE 0 END) AS N_NEGATIVE"),
   "a 1L start before the diagnosis is counted, not silently averaged in")

cat("\n-- attrition: exclusive, and the categories mean what they say --\n")
ATT <- outcomes_attrition_sql("s.TTE", "2026-03-31")
ok(has(ATT, "AS N_NEXT_LOT") && has(ATT, "AS N_DIED") &&
     has(ATT, "AS N_DISCON_NO_NEXT") && has(ATT, "AS N_LOST_TO_FU"),
   "all four of Table 4's categories are counted")
# A patient who starts a next line and later dies belongs to the next-line
# count; every other category is conditioned on there being no next line.
ok(length(gregexpr("NEXT_LOT_NUM IS NULL", ATT)[[1]]) >= 3,
   "the others are all conditioned on there being no next line")
# Table 4's four are not exhaustive. A patient still on treatment when the
# data runs out was observed to the end of the study - they are not lost.
ok(has(ATT, "AS N_ONGOING"),
   "still on treatment at the study end is its own count, not lost to follow-up")
ok(has(ATT, "FU_END_DT < date('2026-03-31')") &&
     has(ATT, "FU_END_DT >= date('2026-03-31')"),
   "...and the two are separated by whether observation stopped before the study did")
# The five partition the line: every patient lands in exactly one.
part <- function(next_lot, os, ttd, fu_end, study_end = "2026-03-31") {
  c(next_lot = as.integer(!is.na(next_lot)),
    died     = as.integer(is.na(next_lot) && os == 1),
    discon   = as.integer(is.na(next_lot) && os == 0 && ttd == 1),
    lost     = as.integer(is.na(next_lot) && os == 0 && ttd == 0 &&
                            as.Date(fu_end) <  as.Date(study_end)),
    ongoing  = as.integer(is.na(next_lot) && os == 0 && ttd == 0 &&
                            as.Date(fu_end) >= as.Date(study_end)))
}
cases <- list(part(2, 0, 1, "2026-03-31"), part(NA, 1, 1, "2022-01-01"),
              part(NA, 0, 1, "2026-03-31"), part(NA, 0, 0, "2022-06-30"),
              part(NA, 0, 0, "2026-03-31"))
ok(all(vapply(cases, sum, 0) == 1),
   "every patient lands in exactly one of the five, so they sum to the line")
ok(cases[[4]]["lost"] == 1 && cases[[5]]["ongoing"] == 1,
   "...disenrolled early is lost; on treatment at the study end is ongoing")

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
               STUDY_END = "2026-03-31", CONTRACT_DEVIATIONS = "")
SE <- STATUS$STUDY_END
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
refuses <- function(f, why, what, se = SE) {
  m <- tryCatch({ f(NULL, "ndmm_", "ndmm_NDMM_COHORT", se); "" }, error = conditionMessage)
  ok(nzchar(m) && grepl(why, m, fixed = TRUE), what)
}
runs(mk()(NULL, "ndmm_", "ndmm_NDMM_COHORT", SE),
     "a complete run over this cohort is accepted")
refuses(mk(modifyList(STATUS, list(STATE = "running"))), "is marked 'running'",
        "an unfinished LOT run is refused")
refuses(mk(modifyList(STATUS, list(INPUT_COHORT_TABLE = "sch.other_COH"))),
        "sch.other_COH", "a run built over another cohort is refused")
refuses(mk(modifyList(STATUS, list(CONTRACT_DEVIATIONS = "gap_days=60"))),
        "LOT_CONTRACT_OVERRIDE", "a run with a contract override is refused")
refuses(mk(lot = NULL), "No LOT run is recorded", "no LOT run at all is refused")
# The attrition split is decided by the study end and this package holds its own
# copy. overall hardcodes 2025-06-30 and nndm pins 2026-03-31, so the two
# cohorts in this folder disagree by construction - and running long scores
# every still-treated patient as lost to follow-up with nothing logged.
refuses(mk(), "2026-03-31", "a run built to a different study end is refused",
        se = "2025-06-30")

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
