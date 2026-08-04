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
fsc <- function(row, lot_run = "L1") {
  e <- new.env(parent = globalenv())
  assign("coh_tbl", function(x) paste0("sch.ndmm_", x), envir = e)
  assign("log_msg", function(...) invisible(NULL), envir = e)
  assign("db_q", function(con, sql) {
    if (is.null(row)) stop("TABLE_OR_VIEW_NOT_FOUND")
    as.data.frame(row, stringsAsFactors = FALSE)
  }, envir = e)
  f <- find_subsequent_cohorts; environment(f) <- e
  tryCatch(f(NULL, lot_run), error = conditionMessage)
}
ok(length(fsc(list(PATID = "p", SOURCE_LOT_RUN_ID = "L1"))) == 2L,
   "a line cohort built from this LOT run is used")
m <- fsc(list(PATID = "p", SOURCE_LOT_RUN_ID = "L0"))
ok(is.character(m) && grepl("built from LOT run L0", m, fixed = TRUE),
   "one built from another run stops the build, naming it")
m2 <- fsc(list(PATID = "p"))
ok(is.character(m2) && grepl("records no source LOT run", m2, fixed = TRUE),
   "...and one that cannot say which run it came from is not current by omission")
ok(is.list(fsc(NULL)) && !length(fsc(NULL)),
   "no line cohort at all is fine - the run reports ALL_LINES alone")
# The stamp it checks is the one the subsequent build actually writes.
bs <- paste(readLines(file.path(dirname(ROOT), "ndmm", "R", "build_subsequent.R"),
                      warn = FALSE), collapse = "\n")
ok(has(bs, "AS SOURCE_LOT_RUN_ID") && has(bs, "AS SOURCE_COHORT_RUN_ID") &&
     has(bs, "AS SOURCE_COHORT_STAMP"),
   "...and the cohort build writes that lineage rather than only its own run id")

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
# Nothing recorded is nothing to compare. Saying so beats inventing a match.
runs(mk(meta = modifyList(META, list(COHORT_RUN_ID = "")))(
       NULL, "ndmm_", "ndmm_NDMM_COHORT", SE),
     "a run that recorded no cohort attempt is reported, not refused")
runs(mk(ndmm = NULL)(NULL, "ndmm_", "ndmm_NDMM_COHORT", SE),
     "...and so is a cohort with no build status at all")

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
