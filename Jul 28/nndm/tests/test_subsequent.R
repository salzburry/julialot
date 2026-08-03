#!/usr/bin/env Rscript
# The 2L and 3L cohorts, held to protocol 6.2.1.1. No warehouse: the SQL is
# built as a string and the guards are driven with stubs.
#
#   Rscript "nndm/tests/test_subsequent.R"

ROOT <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                                 fixed = TRUE))) else getwd()
  dirname(d)
})
source(file.path(ROOT, "tests", "testutil.R"))

sys.source(file.path(ROOT, "R", "load_inputs.R"), envir = globalenv())
load_pipeline_inputs(ROOT, "config.csv")
sys.source(file.path(ROOT, "R", "config.R"), envir = globalenv())
sys.source(file.path(ROOT, "R", "db_utils.R"), envir = globalenv())
sys.source(file.path(ROOT, "R", "nndm_constants.R"), envir = globalenv())
sys.source(file.path(ROOT, "R", "build_subsequent.R"), envir = globalenv())

SQL2 <- subseq_cohort_sql(2L, "s.c1", "s.c2", 365L, 3L, "s.LINES", "s.SPANS",
                          "s.STRICT", "r9")
SQL3 <- subseq_cohort_sql(3L, "s.c1", "s.c3", 365L, 3L, "s.LINES", "s.SPANS",
                          "s.STRICT", "r9")
FUN2 <- subseq_funnel_sql(2L, "s.c1", 365L, 3L, "s.LINES", "s.SPANS", "s.STRICT")

cat("\n-- the three criteria in 6.2.1.1 --\n")
# 1. "Received a subsequent LOT required to qualify for a specific cohort"
ok(has(SQL2, "WHERE l.LOT_NUM = 2") && has(SQL3, "WHERE l.LOT_NUM = 3"),
   "each cohort is indexed on its own line's rows")
ok(has(SQL2, "min(cast(l.LOT_START_DT as date)) AS COHORT_INDEX_DATE"),
   "the index date is that line's start - 'at the initiation of 2L'")
# 2. "CE of at least 12-months ... before the cohort index date (2L or 3L)"
ok(has(SQL2, "date_sub(g.COHORT_INDEX_DATE, 365)") &&
     has(SQL2, "s.cov_end >= date_sub(g.COHORT_INDEX_DATE, 1)"),
   "12 months of CE before the index, the window 1L uses")
fl <- paste(readLines(file.path(ROOT, "R", "steps", "06_flags.R"), warn = FALSE),
            collapse = "\n")
ok(has(fl, "date_sub(l1.LOT1_START_DT, 1)") &&
     has(fl, "{NDMM_PRE_LOT1_DAYS}) AS pre_lot1_start"),
   "...and that really is 1L's window, not one written twice differently")
# 3. "CE of at least 3-months during follow-up or death with no gaps"
ok(has(sub("^.*fu AS \\(", "", SQL2), "s.STRICT") &&
     has(sub("\\),\\s*fu AS.*$", "", sub("^.*pre AS \\(", "", SQL2)), "s.SPANS"),
   "follow-up reads the no-gap spans, the baseline the gap-merged ones")
ok(has(SQL2, "add_months(g.COHORT_INDEX_DATE, 3)"),
   "3 months of follow-up from that cohort's own index")
ok(has(SQL2, "coalesce(g.DEATH_DT, add_months(g.COHORT_INDEX_DATE, 3))"),
   "death cuts the window short rather than failing it")
# "or death" is the only stated alternative. A living patient whose 3 months
# run past the data has not shown 3 months.
ok(!has(SQL2, "study_end") && !has(SQL2, "2026-03-31"),
   "study end does NOT truncate it - a late line is not qualified by data ending")
ok(has(SQL2, "WHERE coalesce(pre.CE_PRE_12MO, 0) = 1 AND coalesce(fu.CE_FU, 0) = 1"),
   "failing either enrolment criterion keeps a patient out")

cat("\n-- both cohorts are drawn from the 1L cohort --\n")
# 6.2.1.1 applies the criteria "to the 1L cohort", and each is written "for
# each cohort" against "the cohort index date (2L or 3L)". A patient can miss
# 12 months before 2L and have them before 3L, so chaining 3L off 2L would
# drop patients the third bullet includes.
ok(has(SQL3, "FROM s.c1 c") && !has(SQL3, "FROM s.c2 c"),
   "3L is drawn from the 1L cohort, not from the 2L cohort")
ok(has(subseq_funnel_sql(3L, "s.c1", 365L, 3L, "s.LINES", "s.SPANS", "s.STRICT",
                         "s.c2"), "NOT EXISTS"),
   "...and the funnel counts how many 3L members the 2L cohort lacks")

cat("\n-- the funnel counts what the cohort keeps --\n")
ok(has(FUN2, "date_sub(g.ix, 365)") && has(FUN2, "add_months(g.ix, 3)") &&
     has(FUN2, "coalesce(g.DEATH_DT, add_months(g.ix, 3))"),
   "the funnel's two tests are the cohort's")

cat("\n-- 1L and these cohorts follow up for different lengths --\n")
ok(NDMM_FU_CE_DAYS == 0L && SUBSEQ_FU_CE_MONTHS == 3L,
   "0 days at 1L by the study team's answer, 3 months here by the protocol")

cat("\n-- the lines have to come from a finished run over this cohort attempt --\n")
STATUS <- list(RUN_ID = "L1", STATE = "complete", UPDATED_AT = "t2",
               INPUT_COHORT_TABLE = "sch.ndmm_NDMM_COHORT",
               CONTRACT_DEVIATIONS = "", COHORT_RUN_ID = "N1",
               COHORT_STAMP = "s1")
NNDM <- list(RUN_ID = "N1", UPDATED_AT = "s1")
mk <- function(lot = STATUS, nndm = NNDM) {
  e <- new.env(parent = globalenv())
  assign("wrk", function(t) paste0("sch.ndmm_", t), envir = e)
  assign("log_msg", function(...) invisible(NULL), envir = e)
  assign("db_q", function(con, sql) {
    if (grepl("NDMM_BUILD_STATUS", sql, fixed = TRUE)) {
      if (is.null(nndm)) stop("TABLE_OR_VIEW_NOT_FOUND")
      return(as.data.frame(nndm, stringsAsFactors = FALSE))
    }
    if (is.null(lot)) stop("TABLE_OR_VIEW_NOT_FOUND")
    as.data.frame(lot, stringsAsFactors = FALSE)
  }, envir = e)
  f <- subseq_check_lot_run; environment(f) <- e
  g <- subseq_check_cohort_attempt; environment(g) <- e
  assign("subseq_check_cohort_attempt", g, envir = e)
  f
}
# Refused FOR THE STATED REASON. A test that only asks "did it error" passes
# on a typo in the checker as readily as on the check.
refuses <- function(f, why, what) {
  m <- tryCatch({ f(NULL, "ndmm_"); "" }, error = conditionMessage)
  ok(nzchar(m) && grepl(why, m, fixed = TRUE), what)
}
runs(mk()(NULL, "ndmm_"), "a complete run over this cohort attempt is accepted")
refuses(mk(modifyList(STATUS, list(STATE = "running"))), "is marked 'running'",
        "an unfinished run is refused - it replaces the lines before validating")
refuses(mk(modifyList(STATUS, list(INPUT_COHORT_TABLE = "sch.other_NDMM_COHORT"))),
        "sch.other_NDMM_COHORT", "a run built over another cohort is refused")
refuses(mk(modifyList(STATUS, list(CONTRACT_DEVIATIONS = "gap_days=60"))),
        "LOT_CONTRACT_OVERRIDE", "a run with a contract override is refused")
refuses(mk(lot = NULL), "No LOT run is recorded",
        "no LOT run at all is refused, not treated as zero rows")
# A re-run under one prefix replaces NDMM_COHORT and both span tables in
# place, so the name still matches while the data is a later attempt.
refuses(mk(nndm = list(RUN_ID = "N2", UPDATED_AT = "s2")), "now holds run N2",
        "NNDM rerun after the LOT build is refused - lines from A, spans from B")
refuses(mk(nndm = list(RUN_ID = "N1", UPDATED_AT = "s2")), "now holds run N1",
        "...and a same-id re-run is caught by the stamp")
runs(mk(modifyList(STATUS, list(COHORT_RUN_ID = "")))(NULL, "ndmm_"),
     "a LOT run predating those columns is not failed on a blank")
runs(mk(nndm = NULL)(NULL, "ndmm_"),
     "no NNDM status table is reported, not treated as a mismatch")

cat("\n-- it can actually run --\n")
# Every function called has to exist, or the first thing a production run
# finds is a typo. set_nndm_config() was one.
scan_names <- local({
  fns <- character(0); bound <- character(0)
  walk <- function(e) {
    if (is.call(e)) {
      if (is.name(e[[1]])) {
        nm <- as.character(e[[1]])
        if (nm %in% c("<-", "=", "<<-") && length(e) > 2L && is.name(e[[2]]))
          bound <<- c(bound, as.character(e[[2]]))
        else fns <<- c(fns, nm)
      }
      for (i in seq_along(e)) if (!is.null(e[[i]])) try(walk(e[[i]]), silent = TRUE)
    } else if (is.function(e)) walk(body(e))
  }
  for (f in c(file.path(ROOT, "R", "build_subsequent.R"),
              file.path(ROOT, "build_subsequent_cohorts.R")))
    for (x in parse(f, keep.source = FALSE)) walk(x)
  list(called = unique(fns), bound = unique(bound))
})
env <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "build_nndm.R"), envir = env)
missing <- Filter(function(f) !exists(f, envir = env) && !exists(f, envir = globalenv()) &&
                    !exists(f, envir = baseenv()) &&
                    !any(vapply(search(), function(s) exists(f, where = s, inherits = FALSE),
                                logical(1))),
                  setdiff(scan_names$called, scan_names$bound))
ok(!length(missing),
   if (length(missing)) paste0("calls a function that does not exist: ",
                               paste(missing, collapse = ", "))
   else "every function it calls exists")

report()
