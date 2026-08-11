#!/usr/bin/env Rscript
# The outcome definitions, held to protocol Table 4. No warehouse: the SQL is
# built as a string, and the arithmetic is checked by evaluating the same rule
# in R over hand-made cases.
#
#   Rscript "lot/outcomes/tests/test_runner.R"

ROOT <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                                 fixed = TRUE))) else getwd()
  dirname(d)
})
# The cohort builds are not in the LOT group this package sits in - they are
# what a LOT run is pointed at - so the one check that reads NDMM's code starts
# two levels up. Resolved from this file rather than named.
STUDY <- dirname(dirname(ROOT))
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
TTE  <- outcomes_tte_sql(BASE, "r1", "L1")

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
# The event rule is lifted out of the generated SQL and evaluated, not restated
# here. A hand-written copy is a second implementation: it agrees with whatever
# the author believed, passes, and says nothing about what the warehouse runs.
# Changing the shipped boundary has to fail these.
sql_cond <- function(sql, flag) {
  # Cut at the flag, then back to the nearest CASE WHEN. Matching forwards from
  # "CASE WHEN" takes the first one in the whole statement, which is in the
  # base subquery, which is several clauses of unrelated SQL.
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
# (build_ndmm.R: least(study_end, coalesce(DEATH_DT, study_end))), so a case
# pairing a death with a later follow-up end is a row the cohort cannot write,
# and a strict boundary is invisible to it.
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

# OS and TTD, on their own lifted rules. A death is the follow-up end, so a
# strict test can never fire and the curve carries no events at all.
dth <- as.Date("2020-04-10")
ok(fire("OS", OS_DT = dth, FU_END_DT = dth), "OS: a death on the follow-up end is an event")
ok(!fire("OS", OS_DT = SENT, FU_END_DT = as.Date("2021-01-01")),
   "OS: no death is not an event - the sentinel cannot reach the boundary")
ok(!fire("OS", OS_DT = dth, FU_END_DT = as.Date("2020-01-31")),
   "OS: a death after observation ended is still censoring")
# TTD is the exception: a line whose own end is the run-out has not ended.
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
DX <- outcomes_tte_sql(outcomes_base_sql("s.LINES", "s.COH", "s.BASE"), "r1", "L1")
ok(has(DX, "FROM s.BASE") && has(DX, "LEFT JOIN"),
   "the base cohort is joined for MM_DX_DT")
# glue() trims a template's leading blank line, so the fragment began at the
# "L" of LEFT and interpolating it straight after n.PATID emitted
# "n.PATIDLEFT JOIN". A substring test passes on that - "LEFT JOIN" is still in
# there - so the join has to be checked where it attaches.
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
D1 <- outcomes_dx_to_lot1_sql("s.TTE", "r1", "L1")
ok(has(D1, "WHERE LOT_NUM = 1"),
   "one row per patient: the 1L rows only, not once per line reached")
# The cohort build takes the first therapy claim ON OR after the diagnosis, so
# a negative gap would mean that rule had broken.
ok(has(D1, "DX_TO_LOT1_DAYS < 0 THEN 1 ELSE 0 END) AS N_NEGATIVE"),
   "a 1L start before the diagnosis is counted, not silently averaged in")

cat("\n-- attrition: exclusive, and the categories mean what they say --\n")
ATT <- outcomes_attrition_sql("s.TTE", "2026-03-31", "r1", "L1", TRUE)
ok(has(ATT, "AS N_NEXT_LOT") && has(ATT, "AS N_DIED") &&
     has(ATT, "AS N_DISCON_NO_NEXT") && has(ATT, "AS N_LOST_TO_FU"),
   "all four of Table 4's categories are counted")
# A patient who starts a next line and later dies belongs to the next-line
# count; every other category is conditioned on there being no next line.
#
# "Received the next LOT" has to mean OBSERVED to receive it. lot ignores
# disenrolment, so LOT_LONG_FINAL carries lines starting after a patient's
# follow-up ended. Keying on the COLUMN credits progressions nobody watched and
# locks those patients out of every other category.
ok(!has(ATT, "NEXT_LOT_NUM IS NOT NULL") && !has(ATT, "NEXT_LOT_NUM IS NULL"),
   "no category keys on the next-line column, which ignores follow-up")
ok(length(gregexpr("TTNT_REASON = 'NEXT_LOT'", ATT)[[1]]) >= 4,
   "the observed next-LOT event conditions all five categories")
# Table 4's four are not exhaustive. A patient still on treatment when the
# data runs out was observed to the end of the study - they are not lost.
ok(has(ATT, "AS N_ONGOING"),
   "still on treatment at the study end is its own count, not lost to follow-up")
ok(grepl("FU_END_DT <\\s+date\\('2026-03-31'\\)", ATT) &&
     has(ATT, "FU_END_DT >= date('2026-03-31')"),
   "...and the two are separated by whether observation stopped before the study did")
# Table 4 asks for number AND percent, so each category carries both.
ok(all(vapply(c("NEXT_LOT", "DIED", "DISCON_NO_NEXT", "LOST_TO_FU", "ONGOING"),
              function(k) has(ATT, paste0("AS PCT_", k)), logical(1))),
   "each category carries its percent, as Table 4 asks")
# The five partition the line: every patient lands in exactly one. Driven off
# the SQL's own predicates, not a second copy of them. A copy keyed on the
# next-line column agrees with an implementation that keys on it too.
pred <- function(alias) {
  # Cut at the alias, then back to the NEAREST preceding "sum(CASE WHEN".
  # Matching forwards takes the first one in the statement and swallows every
  # category between - as in sql_cond above.
  head <- strsplit(ATT, paste0("THEN 1 ELSE 0 END)     AS ", alias), fixed = TRUE)[[1]][1]
  if (is.na(head) || nchar(head) == nchar(ATT))
    head <- strsplit(ATT, paste0("AS ", alias), fixed = TRUE)[[1]][1]
  x <- sub("(?s)^.*sum\\(CASE WHEN ", "", head, perl = TRUE)
  x <- sub("\\s*THEN 1 ELSE 0 END\\)?\\s*$", "", x)
  x <- gsub("\n\\s*", " ", trimws(x))
  # A predicate this cannot read is a failed assertion below, not a dead suite.
  if (grepl("(CASE WHEN|ELSE 0 END)", x)) return("NA")
  x <- gsub("\\bAND\\b", "&", gsub("\\bNOT\\b", "!", x))
  gsub("date\\('([0-9-]+)'\\)", "as.Date('\\1')", gsub("(?<![<>!=])=(?!=)", "==", x, perl = TRUE))
}
CATS <- c("N_NEXT_LOT", "N_DIED", "N_DISCON_NO_NEXT", "N_LOST_TO_FU", "N_ONGOING")
PRED <- lapply(CATS, pred); names(PRED) <- CATS
part <- function(ttnt_ev, reason, os, ttd, fu_end) {
  e <- list2env(list(TTNT_EVENT = ttnt_ev, TTNT_REASON = reason, OS_EVENT = os,
                     TTD_EVENT = ttd, FU_END_DT = as.Date(fu_end)),
                parent = environment())
  # A predicate that will not evaluate fails the assertions below rather than
  # killing the run - a mutation should be reported, not crash the report.
  vapply(PRED, function(p) as.integer(isTRUE(tryCatch(
    eval(parse(text = p), envir = e), error = function(e) NA))), 0L)
}
cases <- list(part(1, "NEXT_LOT", 0, 1, "2026-03-31"),
              part(0, "CENSORED", 1, 1, "2022-01-01"),
              part(0, "CENSORED", 0, 1, "2026-03-31"),
              part(0, "CENSORED", 0, 0, "2022-06-30"),
              part(0, "CENSORED", 0, 0, "2026-03-31"))
ok(all(vapply(cases, sum, 0) == 1),
   "every patient lands in exactly one of the five, so they sum to the line")
ok(cases[[4]]["N_LOST_TO_FU"] == 1 && cases[[5]]["N_ONGOING"] == 1,
   "...disenrolled early is lost; on treatment at the study end is ongoing")
# The case the column-based version got wrong: a next line lot recorded but the
# study never observed. Censored by TTNT, so not a progression - and it still
# has to land somewhere, or it would vanish from the line's own total.
u <- part(0, "CENSORED", 0, 0, "2022-06-30")
ok(u["N_NEXT_LOT"] == 0 && sum(u) == 1,
   "a next line after follow-up is not a progression, and is still counted once")

cat("\n-- months are months --\n")
GAP <- outcomes_line_gap_sql("s.TTE", "r1", "L1", TRUE)
ok(has(GAP, "30.4375"),
   "a month is the mean Gregorian month, not 30 days")
# "Among patients initiating a subsequent LOT" - observed to initiate it. A line
# lot recorded after the patient's follow-up ended has its gap measured over
# time nobody watched, so it is not one of these patients.
ok(has(GAP, "(t.TTNT_EVENT = 1 AND t.TTNT_REASON = 'NEXT_LOT')") &&
     !has(GAP, "NEXT_LOT_NUM IS NOT NULL"),
   "the gap is measured only over next lines the study observed")
ok(abs(365.25 / 30.4375 - 12) < 1e-9, "...which divides the year into twelve")

cat("\n-- a line cohort has to belong to the run being measured --\n")
# Readable is not current. Re-running LOT leaves the 2L/3L tables untouched and
# perfectly readable, and eligibility from the old run would be stamped onto the
# new run's lines - with every output correctly carrying this run's ids, so no
# stamp check could catch it. ALL_LINES stays right; LINE_ELIGIBLE goes quietly
# wrong. The subsequent build records its source LOT run; this asks.
#
# Naming the same LOT run is not the same as being the same build, so all five
# stamps the subsequent build writes are read, not one of them.
#
# `rows` is one row per probed line cohort, in order, so 2L and 3L can differ -
# which is the partial-rerun case and cannot be modelled with a single row.
FULL <- list(PATID = "p", SOURCE_LOT_RUN_ID = "L1", SUBSEQ_RUN_ID = "S1",
             CE_PRE_DAYS = "365", CE_FU_DAYS = "90",
             SOURCE_COHORT_RUN_ID = "C1", SOURCE_COHORT_STAMP = "2026-01-01")
ATTEMPT <- c(run = "C1", stamp = "2026-01-01")
fsc <- function(rows, lot_run = "L1", attempt = ATTEMPT) {
  if (is.null(rows) || !is.null(names(rows))) rows <- list(rows, rows)
  i <- 0L
  e <- new.env(parent = globalenv())
  assign("coh_tbl", function(x) paste0("sch.ndmm_", x), envir = e)
  assign("log_msg", function(...) invisible(NULL), envir = e)
  assign("db_q", function(con, sql) {
    i <<- i + 1L
    r <- rows[[min(i, length(rows))]]
    if (is.null(r)) stop("TABLE_OR_VIEW_NOT_FOUND")
    as.data.frame(r, stringsAsFactors = FALSE)
  }, envir = e)
  f <- find_subsequent_cohorts; environment(f) <- e
  tryCatch(f(NULL, lot_run, attempt = attempt), error = conditionMessage)
}
without <- function(k) { r <- FULL; r[[k]] <- NULL; r }
ok(length(fsc(FULL)$tables) == 2L, "a line cohort built from this LOT run is used")
m <- fsc(modifyList(FULL, list(SOURCE_LOT_RUN_ID = "L0")))
ok(is.character(m) && grepl("built from LOT run L0", m, fixed = TRUE),
   "one built from another run stops the build, naming it")
m2 <- fsc(list(PATID = "p"))
ok(is.character(m2) && grepl("records no source LOT run", m2, fixed = TRUE),
   "...and one that cannot say which run it came from is not current by omission")
ok(is.list(fsc(NULL)) && !length(fsc(NULL)$tables),
   "no line cohort at all is fine - the run reports ALL_LINES alone")
# The join the suite did not make. It checked that this returns nothing, and
# separately that the SQL builder accepts NULL, and never fed one to the other
# - so the runner's `attr(subseq, "provenance")[[1]]` sat between two green
# assertions and died with "subscript out of bounds" on every run without line
# cohorts: the overall cohort, and any NDMM run before the 2L/3L build.
sc0 <- fsc(NULL)
ok(is.null(sc0$provenance),
   "...with no provenance at all, rather than an empty list for the runner to subscript")
runs(outcomes_tte_sql(BASE, "r1", "L1", sc0$provenance),
     "...and that is exactly the value the runner hands the SQL builder")
runs(outcomes_attrition_sql("t", "2026-03-31", "r1", "L1", FALSE, sc0$provenance),
     "...and the summaries take it too")
sc1 <- fsc(FULL)
ok(is.character(sc1$provenance) && identical(sc1$provenance[["pre"]], "365"),
   "...while a run WITH line cohorts hands over the windows they were built to")
runs(outcomes_tte_sql(BASE, "r1", "L1", sc1$provenance),
     "...which the SQL builder takes in the same call")

# The two ways to get a wrong denominator with every id correct on the output.
m3 <- fsc(list(FULL, modifyList(FULL, list(SUBSEQ_RUN_ID = "S2"))))
ok(is.character(m3) && grepl("disagree on which subsequent-cohort run", m3),
   "2L and 3L from different subsequent runs are not one build, even on one LOT run")
m4 <- fsc(list(FULL, modifyList(FULL, list(CE_PRE_DAYS = "180"))))
ok(is.character(m4) && grepl("disagree on the continuous-enrolment window", m4),
   "...nor are two built to different continuous-enrolment windows")
m5 <- fsc(list(FULL, modifyList(FULL, list(SOURCE_COHORT_STAMP = "2026-06-01"))))
ok(is.character(m5) && grepl("disagree on the stamp", m5),
   "...nor two built over different attempts of the same cohort")
# A sensitivity build under overridden windows is the case that matters, and it
# is caught by the pair being read at all rather than by judging the numbers:
# whatever they are, they are logged and they have to agree.
ok(length(fsc(modifyList(FULL, list(CE_PRE_DAYS = "180", CE_FU_DAYS = "30")))$tables) == 2L,
   "a non-default window is not refused - it is read, and the run says so")
# Absent columns are 'cannot check', which is the override's business, not a
# silent pass.
for (k in c("SUBSEQ_RUN_ID", "CE_PRE_DAYS", "CE_FU_DAYS",
            "SOURCE_COHORT_RUN_ID", "SOURCE_COHORT_STAMP")) {
  r <- fsc(without(k))
  ok(is.character(r) && grepl("record no", r, fixed = TRUE),
     paste0("a line cohort with no ", k, " cannot be shown to be this build's"))
}
# Agreeing with each other is not the same as belonging to the lines: both
# tables can consistently describe cohort attempt B while the lines were built
# over attempt A, and nothing compared the two chains.
m6 <- fsc(FULL, attempt = c(run = "C2", stamp = "2026-06-01"))
ok(is.character(m6) && grepl("were built over cohort attempt C1", m6),
   "line cohorts agreeing on an attempt the LOT lines were NOT built over")
m7 <- fsc(FULL, attempt = NULL)
ok(is.character(m7) && grepl("was not established", m7),
   "...and where the LOT attempt could not be established, that is said, not assumed")
ok(length(fsc(FULL, attempt = ATTEMPT)$tables) == 2L,
   "...while the matching pair is what an ordinary run looks like")

# The stamp it checks is the one the subsequent build actually writes. All five,
# now that all five are read - a check against a column nothing writes would
# stop every run, and one nothing reads is the gap this closed.
bs <- paste(readLines(file.path(STUDY, "ndmm", "R", "build_subsequent.R"),
                      warn = FALSE), collapse = "\n")
ok(all(vapply(c("SOURCE_LOT_RUN_ID", "SOURCE_COHORT_RUN_ID",
                "SOURCE_COHORT_STAMP", "SUBSEQ_RUN_ID", "CE_PRE_DAYS",
                "CE_FU_DAYS"),
              function(k) has(bs, paste0("AS ", k)), logical(1))),
   "...and the cohort build writes every stamp this reads")

cat("\n-- and the meaning of LINE_ELIGIBLE travels with it --\n")
# LINE_ELIGIBLE is a restriction whose meaning is set by the continuous
# enrolment windows the 2L/3L build used, and the label is the same whatever
# they were. A sensitivity build under 180/30 is accepted deliberately - that
# is the sweep's business - but it said so only in the run log, which does not
# outlive the session, while the table it produced looked exactly like a
# 365/90 one. A reader opening OUT_TTE a month later had no way to ask.
SP <- c(subseq = "S1", pre = "180", fu = "30")
tte_p <- outcomes_tte_sql(BASE, "r1", "L1", SP)
for (col in c("SUBSEQ_RUN_ID", "CE_PRE_DAYS", "CE_FU_DAYS"))
  ok(has(tte_p, paste0("AS ", col)),
     paste0("OUT_TTE carries ", col, ", not only the log"))
ok(has(tte_p, "'180' AS CE_PRE_DAYS") && has(tte_p, "'30' AS CE_FU_DAYS"),
   "...with the windows the build actually used")
# Every table with a DENOM or a LINE_ELIGIBLE, so provenance cannot land on one
# output and not the next.
for (nm in c("OUT_ATTRITION", "OUT_LINE_GAP", "OUT_REGIMEN")) {
  q <- switch(nm,
    OUT_ATTRITION = outcomes_attrition_sql("t", "2026-03-31", "r1", "L1", TRUE, SP),
    OUT_LINE_GAP  = outcomes_line_gap_sql("t", "r1", "L1", TRUE, SP),
    OUT_REGIMEN   = outcomes_regimen_sql("t", "r1", "L1", TRUE, SP))
  ok(has(q, "AS SUBSEQ_RUN_ID") && has(q, "AS CE_PRE_DAYS") && has(q, "AS CE_FU_DAYS"),
     paste0("...and so does ", nm))
}
# No line cohorts: the flag is NULL and so is its provenance. A blank there
# would read as a window somebody chose.
tte_n <- outcomes_tte_sql(BASE, "r1", "L1", NULL)
ok(has(tte_n, "NULL AS SUBSEQ_RUN_ID") && has(tte_n, "NULL AS CE_PRE_DAYS"),
   "with no line cohorts the provenance is NULL, as LINE_ELIGIBLE is")

cat("\n-- Table 4 is answered over both denominators, not one chosen here --\n")
# 2L can mean "of the patients we followed from 1L" or "of the patients we could
# properly observe at 2L" - NDMM_COHORT_2L adds 365 days of enrolment before the
# line and 90 after. They answer different questions and give different numbers,
# and nothing in the protocol picks one, so both are reported and the reader picks.
REG <- outcomes_regimen_sql("s.TTE", "r1", "L1", TRUE)
EL <- outcomes_base_sql("s.LINES", "s.COH", NULL, list("2" = "s.C2", "3" = "s.C3"))
TTE_EL <- outcomes_tte_sql(EL, "r1", "L1")
ok(has(EL, "AS LINE_ELIGIBLE"), "the line's own cohort marks the row")
ok(has(EL, "WHEN n.LOT_NUM = 1 THEN 1"),
   "...1L is eligible by construction - it is the cohort")
# NULL, not 0: not eligible and not-asked are different answers, and 0 would
# shrink the restricted denominator by every line nobody set a criterion for.
ok(!has(EL, "ELSE 0 END AS LINE_ELIGIBLE"),
   "...and a line with no cohort of its own is NULL, not ineligible")
# The same glue trim that welded the diagnosis join on. Two fragments now.
ok(!grepl("PATID(LEFT|INNER) JOIN", EL),
   "...and no join is welded onto the column before it")
NO <- outcomes_base_sql("s.LINES", "s.COH")
ok(has(NO, "cast(NULL as int) AS LINE_ELIGIBLE"),
   "with no line cohorts the flag is NULL rather than assumed")
for (o in list(c("OUT_ATTRITION", "ATT"), c("OUT_LINE_GAP", "GAP"),
               c("OUT_REGIMEN", "REG"))) {
  s <- get(o[2])
  # The gap keys on the DESTINATION line's flag; the others on the row's own.
  el <- if (identical(o[1], "OUT_LINE_GAP")) "t.NEXT_LINE_ELIGIBLE = 1"
        else "t.LINE_ELIGIBLE = 1"
  ok(has(s, "SELECT 'ALL_LINES' AS DENOM UNION ALL SELECT 'LINE_ELIGIBLE'") &&
       has(s, paste0("d.DENOM = 'ALL_LINES' OR ", el)),
     paste0(o[1], " reports both denominators"))
  ok(has(s, "GROUP BY d.DENOM"), paste0("...and ", o[1], " groups by which one"))
}
# The regimen percentage is within its own denominator, or ALL_LINES rows would
# be scaled by a total that includes the restricted ones.
ok(has(REG, "PARTITION BY d.DENOM, t.LOT_NUM"),
   "the regimen percentage is of its own denominator and line")
# One denominator when there is only one, rather than an empty second that
# would read as "nobody qualified".
ok(!has(outcomes_attrition_sql("s.TTE", "2026-03-31", "r1", "L1"), "LINE_ELIGIBLE'"),
   "with no line cohorts only ALL_LINES is reported")
# A gap belongs to the line being INITIATED. Keying on this row's flag makes
# every 1L-to-2L gap eligible, because 1L always is, so the restricted answer
# would silently be the unrestricted one and NDMM_COHORT_2L would never apply.
ok(has(GAP, "t.NEXT_LINE_ELIGIBLE = 1") && !has(GAP, "OR t.LINE_ELIGIBLE = 1"),
   "the gap is restricted by the line it goes TO, not the one it comes from")
# And OUT_TTE has to carry both, or the summaries cannot read either. This is
# the composed statement, not the base fragment: the projection names its
# columns, so anything the base computes and it omits is gone by the time the
# summaries run - and the run then dies on the first one.
FINAL <- substring(as.character(TTE_EL),
                   tail(gregexpr("\n    SELECT ", as.character(TTE_EL))[[1]], 1))
ok(has(FINAL, "LINE_ELIGIBLE, NEXT_LINE_ELIGIBLE"),
   "OUT_TTE projects both eligibilities, which is what the summaries read")

cat("\n-- every output says which run it is, not just the first one --\n")
ro  <- paste(readLines(file.path(ROOT, "R", "run_outcomes.R"), warn = FALSE),
             collapse = "\n")
# The README promises "a run that dies part-way leaves a mismatch rather than a
# silent mix", and only OUT_TTE carried a run id. The summaries are written
# sequentially with CREATE OR REPLACE, so a failure between them leaves this
# run's OUT_TTE beside the last run's summaries, and a run id on each is what
# says so.
for (o in list(c("OUT_TTE", "TTE"), c("OUT_ATTRITION", "ATT"),
               c("OUT_LINE_GAP", "GAP"), c("OUT_REGIMEN", "REG"),
               c("OUT_DX_TO_LOT1", "D1"))) {
  s <- get(o[2])
  ok(has(s, "AS OUT_RUN_ID") && has(s, "AS BUILT_AT"),
     paste0(o[1], " carries the outcomes run id and a build time"))
}
# Which LOT run supplied the lines is not the same question as which outcomes
# run wrote the table. OUT_TTE is the analytical table, so it needs both: on its
# own it could not say which run's lines it holds.
for (o in list(c("OUT_TTE", "TTE"), c("OUT_ATTRITION", "ATT"),
               c("OUT_LINE_GAP", "GAP"), c("OUT_REGIMEN", "REG"),
               c("OUT_DX_TO_LOT1", "D1")))
  ok(has(get(o[2]), "AS LOT_RUN_ID"),
     paste0(o[1], " also names the LOT run its lines came from"))
ok(has(ro, "check_stamps(con"),
   "and the runner asks the tables, rather than logging that they are stamped")
ok(has(ro, "LOT_RUN_ID IS NULL OR LOT_RUN_ID <>"),
   "...on both ids, so a table stamped by this run over other lines is caught")
# The one optional output is the one that can be left behind: a run with no
# readable base cohort writes the other four and would leave an earlier run's
# diagnosis table beside them, outside the check above.
ok(has(ro, 'DROP TABLE IF EXISTS {d1}'),
   "a skipped diagnosis table is dropped, not left from an earlier run")
# Both names the cohort builds use, as lot resolves them.
ok(has(ro, 'c("NDMM_BUILD_STATUS", "build_status")'),
   "the cohort attempt is looked for under either build-status name")

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
# The attempt tables, named the way lot and ndmm name their columns. LOT records
# which cohort attempt it read; the cohort build records which attempt is on
# disk now. Equal here, so the good case passes and each mismatch is its own row.
META  <- list(RUN_ID = "L1", COHORT_RUN_ID = "N7", COHORT_STAMP = "2026-04-01 09:00:00")
NDMMS <- list(RUN_ID = "N7", UPDATED_AT = "2026-04-01 09:00:00")
mk <- function(lot = STATUS, meta = META, ndmm = NDMMS) {
  e <- new.env(parent = globalenv())
  assign("out_tbl", function(t) paste0("sch.ndmm_", t), envir = e)
  assign("coh_tbl", function(t) paste0("sch.ndmm_", t), envir = e)
  assign("log_msg", function(...) invisible(NULL), envir = e)
  # Routed by table name: one fixture answering every query cannot tell a guard
  # that reads the right table from one that reads the wrong one.
  assign("db_q", function(con, sql) {
    # LOT_BUILD_STATUS before the cohort's, or the shared "BUILD_STATUS" tail
    # would route lot's own status row to the cohort branch.
    pick <- if (grepl("LOT_RUN_METADATA", sql, fixed = TRUE)) meta
            else if (grepl("LOT_BUILD_STATUS", sql, fixed = TRUE)) lot
            else if (grepl("BUILD_STATUS", sql, ignore.case = TRUE)) ndmm
            else lot
    if (is.null(pick)) stop("TABLE_OR_VIEW_NOT_FOUND")
    as.data.frame(pick, stringsAsFactors = FALSE)
  }, envir = e)
  assign("check_cohort_attempt", check_cohort_attempt, envir = e)
  environment(e$check_cohort_attempt) <- e
  f <- check_lot_run; environment(f) <- e; f
}
refuses <- function(f, why, what, se = SE) {
  m <- tryCatch({ f(NULL, "ndmm_", "ndmm_NDMM_COHORT", se); "" }, error = conditionMessage)
  ok(nzchar(m) && grepl(why, m, fixed = TRUE), what)
}
runs(mk()(NULL, "ndmm_", "ndmm_NDMM_COHORT", SE),
     "a complete run over this cohort is accepted")
# What check_lot_run() hands to find_subsequent_cohorts(), joined for real.
# These two were tested apart and the seam between them was where the bug sat:
# the run id came back as a character carrying an `attempt` attribute, trimws()
# is sub() and sub() returns "the same attributes as x", and identical()
# compares attributes - so identical(src, trimws(lot_run)) was FALSE for the
# same eight characters and EVERY valid 2L/3L cohort was reported as built from
# another run. The no-line path worked; the ordinary path stopped.
#
# Two assertions, deliberately independent. The first is about the shape
# check_lot_run() returns; the second is about find_subsequent_cohorts()
# surviving an attributed run id whatever the shape, because this function is
# handed a run id by a caller it does not control. Tying the second to the
# first would leave the behaviour untested the moment the shape changed.
ok(!identical("L1", trimws(structure("L1", attempt = "x"))),
   "an attributed string is not identical() to its own text - the trap")
FULL_N7 <- modifyList(FULL, list(SOURCE_COHORT_RUN_ID = META$COHORT_RUN_ID,
                                 SOURCE_COHORT_STAMP  = META$COHORT_STAMP))
ATT <- c(run = META$COHORT_RUN_ID, stamp = META$COHORT_STAMP)
sc_attr <- fsc(FULL_N7, lot_run = structure("L1", attempt = ATT), attempt = ATT)
ok(is.list(sc_attr) && length(sc_attr$tables) == 2L,
   "a run id wearing an attribute still matches the cohorts built from it")
lr <- mk()(NULL, "ndmm_", "ndmm_NDMM_COHORT", SE)
ok(is.list(lr) && identical(names(lr), c("run", "attempt")),
   "...and check_lot_run returns named fields rather than a string with cargo")
ok(is.list(lr) && is.null(attributes(lr$run)),
   "...whose run id is a plain character, so a text comparison is a text comparison")
sc_real <- if (is.list(lr)) fsc(FULL_N7, lot_run = lr$run, attempt = lr$attempt) else NULL
ok(is.list(sc_real) && length(sc_real$tables) == 2L,
   "...and the two joined give the line cohorts, not a stale report")
refuses(mk(modifyList(STATUS, list(STATE = "running"))), "is marked 'running'",
        "an unfinished LOT run is refused")
refuses(mk(modifyList(STATUS, list(INPUT_COHORT_TABLE = "sch.other_COH"))),
        "sch.other_COH", "a run built over another cohort is refused")
refuses(mk(modifyList(STATUS, list(CONTRACT_DEVIATIONS = "gap_days=60"))),
        "LOT_CONTRACT_OVERRIDE", "a run with a contract override is refused")
refuses(mk(lot = NULL), "No LOT run is recorded", "no LOT run at all is refused")
# The attrition split is decided by the study end and this package holds its own
# copy. overall hardcodes 2025-06-30 and ndmm pins 2026-03-31, so the two
# cohorts in this folder disagree by construction - and running long scores
# every still-treated patient as lost to follow-up with nothing logged.
refuses(mk(), "2026-03-31", "a run built to a different study end is refused",
        se = "2025-06-30")
# Re-running the cohort under the same prefix replaces the cohort, the
# enrolment spans and NDMM_BASE_COHORT in place. The table name still matches,
# so name-checking alone accepts lines from attempt A measured against dates
# from attempt B - the defect already fixed in the 2L/3L builder.
refuses(mk(ndmm = list(RUN_ID = "N8", UPDATED_AT = "2026-04-02 11:00:00")),
        "cohort run N7", "a cohort rebuilt since the LOT run is refused")
refuses(mk(ndmm = modifyList(NDMMS, list(UPDATED_AT = "2026-04-02 11:00:00"))),
        "cohort run N7", "...and so is the same run id with a later stamp")
refuses(mk(meta = NULL), "has no row in", "a complete run with no metadata row is refused")
# Nothing recorded is nothing to compare - and a comparison that could not be
# made is not one that passed. All three stop, so outcomes measured over an
# unproven lineage cannot land in tables carrying this run's OUT_RUN_ID. An
# operator who wants them accepts that by name.
Sys.unsetenv("OUT_ALLOW_UNPROVEN_LINEAGE")
refuses(mk(meta = modifyList(META, list(COHORT_RUN_ID = ""))),
        "records no cohort attempt",
        "a run that recorded no cohort attempt is refused, not reported")
refuses(mk(ndmm = NULL), "No cohort build status",
        "...and so is a cohort with no build status at all")
# The stamp exists because two attempts can reuse a run id, so a blank one
# proves nothing.
refuses(mk(meta = modifyList(META, list(COHORT_STAMP = ""))),
        "with no stamp",
        "...and a recorded attempt with no stamp, which cannot tell two apart")
# The three that were written as `!is.na(x) && nzchar(x) && x != want`, which
# passes when x is missing - so a status row that recorded nothing proved
# everything, and outcomes ran with no evidence the lines were this
# population's, this algorithm's, or this window's.
refuses(mk(modifyList(STATUS, list(INPUT_COHORT_TABLE = ""))),
        "records no INPUT_COHORT_TABLE",
        "a run that recorded no input cohort cannot be shown to be this population's")
refuses(mk(STATUS[setdiff(names(STATUS), "INPUT_COHORT_TABLE")]),
        "records no INPUT_COHORT_TABLE", "...whether the value is blank or the column absent")
refuses(mk(modifyList(STATUS, list(STUDY_END = ""))),
        "records no STUDY_END",
        "a run that recorded no study end cannot be shown to share this window")
# Blank and absent are different here, and the difference IS the check. Blank
# is a positive statement - the contract algorithm - and is what every
# production run writes; a missing column says nothing and was read as blank.
refuses(mk(STATUS[setdiff(names(STATUS), "CONTRACT_DEVIATIONS")]),
        "no CONTRACT_DEVIATIONS column",
        "a status table with no contract column cannot be shown to be a contract build")
runs(mk(modifyList(STATUS, list(CONTRACT_DEVIATIONS = "")))(
       NULL, "ndmm_", "ndmm_NDMM_COHORT", SE),
     "...while a blank one is a contract build, which is every production run")
# Three states, and NULL was being read as the blank. The engine always writes
# this column as a quoted string, so '' comes from a build and NULL does not -
# NULL is what the in-place column upgrade leaves on rows that predate the
# column, which converts "the column is missing" into "the column is present
# and says nothing" and walks past the check written for that case.
refuses(mk(modifyList(STATUS, list(CONTRACT_DEVIATIONS = NA_character_))),
        "CONTRACT_DEVIATIONS column that is NULL",
        "...and a NULL is the absence of a statement, not the blank one")
# Named, on the record, and only then.
Sys.setenv(OUT_ALLOW_UNPROVEN_LINEAGE = "TRUE")
runs(mk(ndmm = NULL)(NULL, "ndmm_", "ndmm_NDMM_COHORT", SE),
     "OUT_ALLOW_UNPROVEN_LINEAGE=TRUE accepts an unproven lineage deliberately")
Sys.unsetenv("OUT_ALLOW_UNPROVEN_LINEAGE")

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
