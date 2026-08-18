#!/usr/bin/env Rscript
# The 2L and 3L cohorts, held to protocol 6.2.1.1. No warehouse: the SQL is
# built as a string and the guards are driven with stubs.
#
#   Rscript "ndmm/tests/test_subsequent.R"

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
sys.source(file.path(ROOT, "R", "ndmm_constants.R"), envir = globalenv())
sys.source(file.path(ROOT, "R", "build_subsequent.R"), envir = globalenv())

SQL2 <- subseq_cohort_sql(2L, "s.c1", "s.c2", 365L, 90L, "s.LINES", "s.SPANS",
                          "s.STRICT", "r9")
SQL3 <- subseq_cohort_sql(3L, "s.c2", "s.c3", 365L, 90L, "s.LINES", "s.SPANS",
                          "s.STRICT", "r9")
FUN2 <- subseq_funnel_sql(2L, "s.c1", 365L, 90L, "s.LINES", "s.SPANS", "s.STRICT")

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
ok(has(SQL2, "date_add(g.COHORT_INDEX_DATE, 90)"),
   "90 days of follow-up from that cohort's own index")
ok(has(SQL2, "coalesce(g.DEATH_DT, date_add(g.COHORT_INDEX_DATE, 90))"),
   "death cuts the window short rather than failing it")
# date_add, not add_months: the same shape 06_flags.R uses for the 1L window,
# so the two follow-up rules differ only in their number.
ok(!has(SQL2, "add_months") && has(fl, "date_add(ec_l1.LOT1_START_DT"),
   "...counted in days, the way 1L counts its own follow-up")
# "or death" is the only stated alternative. A living patient whose 3 months
# run past the data has not shown 3 months.
ok(!has(SQL2, "study_end") && !has(SQL2, "2026-03-31"),
   "study end does NOT truncate it - a late line is not qualified by data ending")
ok(has(SQL2, "WHERE coalesce(pre.CE_PRE, 0) = 1 AND coalesce(fu.CE_FU, 0) = 1"),
   "failing either enrolment criterion keeps a patient out")

cat("\n-- 1L -> 2L -> 3L: each cohort is drawn from the one before it --\n")
ok(has(SQL2, "FROM s.c1 c"), "2L is drawn from the 1L cohort")
ok(has(SQL3, "FROM s.c2 c") && !has(SQL3, "FROM s.c1 c"),
   "3L is drawn from the 2L cohort")
bs <- paste(readLines(file.path(ROOT, "R", "build_subsequent.R"), warn = FALSE),
            collapse = "\n")
ok(has(bs, "from <- out"), "the loop feeds each cohort into the next")
# Receiving the lines in order is guaranteed by the line numbering, so what
# chaining adds is that the prior cohort's ENROLMENT windows were met too.
# The funnel is run twice for 3L - once off 2L, once off 1L - and the
# difference is reported rather than left to be inferred.
ok(has(bs, "fun(cohort)$n_final - f$n_final") && has(bs, "N_EXCLUDED_BY_PRIOR"),
   "what the chain costs is counted and written, not silent")

cat("\n-- the funnel counts what the cohort keeps --\n")
ok(has(FUN2, "date_sub(g.ix, 365)") && has(FUN2, "date_add(g.ix, 90)") &&
     has(FUN2, "coalesce(g.DEATH_DT, date_add(g.ix, 90))"),
   "the funnel's two tests are the cohort's")

cat("\n-- both windows are settings, and every output records them --\n")
ok(subseq_days("SUBSEQ_PRE_DAYS", 365L) == 365L &&
     subseq_days("SUBSEQ_FU_CE_DAYS", 90L) == 90L,
   "365 and 90 days by default - the protocol's 12 months and 3 months")
withr <- function(v, val, f) {
  old <- Sys.getenv(v, unset = NA)
  do.call(Sys.setenv, setNames(list(val), v)); on.exit({
    if (is.na(old)) Sys.unsetenv(v) else do.call(Sys.setenv, setNames(list(old), v))
  })
  f()
}
ok(withr("SUBSEQ_PRE_DAYS", "180", function() subseq_days("SUBSEQ_PRE_DAYS", 365L)) == 180L,
   "...and the environment moves them")
# The text, not what coercion makes of it: as.integer("60.5") is 60.
ok(inherits(tryCatch(withr("SUBSEQ_PRE_DAYS", "365.5",
     function() subseq_days("SUBSEQ_PRE_DAYS", 365L)), error = function(e) e), "error"),
   "...a fractional number of days is refused, not truncated")
S180 <- subseq_cohort_sql(2L, "s.c1", "s.c2", 180L, 30L, "s.LINES", "s.SPANS",
                          "s.STRICT", "r9")
ok(has(S180, "date_sub(g.COHORT_INDEX_DATE, 180)") &&
     has(S180, "date_add(g.COHORT_INDEX_DATE, 30)"),
   "...and the SQL uses what it is given, with nothing baked in")
# A cohort has to say which windows made it, or a re-run under different
# settings is indistinguishable from the one before it.
ok(has(S180, "180") && has(S180, "AS CE_PRE_DAYS") && has(S180, "AS CE_FU_DAYS"),
   "each cohort table records the two windows")
# The flag is CE_PRE, not CE_PRE_12MO: at SUBSEQ_PRE_DAYS=180 the second name
# would claim a window the column is not.
ok(!has(S180, "12MO") && has(S180, "AS CE_PRE"),
   "...and the flag does not name a window it may not be")
ok(has(bs, "CE_PRE_DAYS, CE_FU_DAYS, SUBSEQ_RUN_ID"),
   "...and so does the attrition table")
# The gap allowance is not one of these: it is baked into the span tables the
# 1L build wrote, so it cannot be changed from here.
ok(!has(bs, 'Sys.getenv("GAP_DAYS'),
   "the gap allowance is not settable here - it belongs to the spans")

cat("\n-- the lines have to come from a finished run over this cohort attempt --\n")
# The fakes carry exactly the columns lot/engine declares, read out of its source.
# An invented LOT_BUILD_STATUS column would make the guard read NA, decide it
# had nothing to compare, and wave every run through while the tests passed.
LOTCOLS <- local({
  bl <- readLines(file.path(dirname(ROOT), "lot", "engine", "R", "build_lot.R"), warn = FALSE)
  grab <- function(first) {
    i <- grep(first, bl)[1]
    j <- i + which(grepl("\\)\\s*$", bl[i:length(bl)]))[1] - 1L
    e <- new.env(); eval(parse(text = paste(bl[i:j], collapse = "\n")), envir = e)
    names(get(ls(e)[1], envir = e))
  }
  list(status = grab("^BUILD_STATUS_COLS <- c\\("),
       meta   = grab("^FINAL_METADATA_COLS <- c\\("))
})
ok(!any(c("COHORT_RUN_ID", "COHORT_STAMP") %in% LOTCOLS$status),
   "LOT_BUILD_STATUS does not carry the cohort attempt")
ok(all(c("COHORT_RUN_ID", "COHORT_STAMP") %in% LOTCOLS$meta),
   "...LOT_RUN_METADATA does, so that is the table to read")
ok(has(bs, 'wrk("LOT_RUN_METADATA")') &&
     !grepl('COHORT_RUN_ID[^\\n]*LOT_BUILD_STATUS', bs),
   "...and the guard reads it there")

STATUS <- setNames(as.list(rep("", length(LOTCOLS$status))), LOTCOLS$status)
STATUS[c("RUN_ID", "STATE", "UPDATED_AT", "INPUT_COHORT_TABLE")] <-
  list("L1", "complete", "t2", "sch.ndmm_NDMM_COHORT")
META <- setNames(as.list(rep("", length(LOTCOLS$meta))), LOTCOLS$meta)
META[c("COHORT_RUN_ID", "COHORT_STAMP")] <- list("N1", "s1")
META$RUN_ID <- "L1"
NDMM <- list(RUN_ID = "N1", UPDATED_AT = "s1")

mk <- function(lot = STATUS, meta = META, ndmm = NDMM) {
  e <- new.env(parent = globalenv())
  assign("wrk", function(t) paste0("sch.ndmm_", t), envir = e)
  assign("log_msg", function(...) invisible(NULL), envir = e)
  assign("db_q", function(con, sql) {
    hit <- function(t) grepl(t, sql, fixed = TRUE)
    d <- if (hit("LOT_RUN_METADATA")) meta
         else if (hit("NDMM_BUILD_STATUS")) ndmm
         else lot
    if (is.null(d)) stop("TABLE_OR_VIEW_NOT_FOUND")
    as.data.frame(d, stringsAsFactors = FALSE)
  }, envir = e)
  for (fn in c("subseq_check_cohort_attempt", "subseq_row", "subseq_unproven")) {
    g <- get(fn); environment(g) <- e; assign(fn, g, envir = e)
  }
  f <- subseq_check_lot_run; environment(f) <- e
  f
}
# Refused for the stated reason. A test that only asks "did it error" passes
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
refuses(mk(ndmm = list(RUN_ID = "N2", UPDATED_AT = "s2")), "now holds run N2",
        "NDMM rerun after the LOT build is refused - lines from A, spans from B")
refuses(mk(ndmm = list(RUN_ID = "N1", UPDATED_AT = "s2")), "now holds run N1",
        "...and a same-id re-run is caught by the stamp")
# A complete LOT run always wrote its metadata row. Missing means something is
# wrong with what is on disk, not that this is an older run.
refuses(mk(meta = NULL), "has no row in",
        "a complete run with no metadata row is refused, not waved through")

# The unprovable cases stop too. Logging and carrying on lets a
# damaged or older-vintage warehouse build cohorts nothing could tie to their
# lines - a subset cohort over mixed vintages looks exactly like a right one.
# Accepting an unproven lineage is now an operator's named decision.
refuses(mk(meta = modifyList(META, list(COHORT_RUN_ID = ""))),
        "NDMM_SUBSEQ_ALLOW_UNPROVEN",
        "a LOT run that recorded no cohort attempt is refused, naming the override")
refuses(mk(ndmm = NULL), "NDMM_SUBSEQ_ALLOW_UNPROVEN",
        "no NDMM status table is refused - the attempt cannot be compared")
refuses(mk(modifyList(STATUS, list(INPUT_COHORT_TABLE = ""))),
        "NDMM_SUBSEQ_ALLOW_UNPROVEN",
        "a blank INPUT_COHORT_TABLE is refused - no proof the lines are this cohort's")
refuses(mk(STATUS[setdiff(names(STATUS), "CONTRACT_DEVIATIONS")]),
        "NDMM_SUBSEQ_ALLOW_UNPROVEN",
        "a status row too old to say whether the run was contract is refused")
# The stamp exists because two attempts can reuse a run id. Counting a blank one
# as a match proves nothing in the one case the run id alone cannot separate.
refuses(mk(meta = modifyList(META, list(COHORT_STAMP = ""))),
        "NDMM_SUBSEQ_ALLOW_UNPROVEN",
        "a recorded attempt with no stamp is refused - it cannot tell two apart")
# The override accepts every unprovable case by name, on the record - and only
# those: a proven MISMATCH still stops with it set.
withr("NDMM_SUBSEQ_ALLOW_UNPROVEN", "TRUE", function() {
  runs(mk(meta = modifyList(META, list(COHORT_RUN_ID = "")))(NULL, "ndmm_"),
       "the override accepts a recorded-nothing lineage, on the record")
  runs(mk(ndmm = NULL)(NULL, "ndmm_"),
       "...and a missing NDMM status table")
  refuses(mk(ndmm = list(RUN_ID = "N2", UPDATED_AT = "s2")), "now holds run N2",
          "...but a PROVEN mismatch still stops - the override is not a skip")
})

# The window pins. Any pair but the protocol's builds a different cohort into
# the study's table names, so it stops unless asked for as a sensitivity.
runs(subseq_check_windows(365L, 90L), "the contract windows pass silently")
m <- tryCatch({ subseq_check_windows(180L, 90L); "" }, error = conditionMessage)
ok(grepl("SUBSEQ_PRE_DAYS=180", m, fixed = TRUE) &&
     grepl("NDMM_SUBSEQ_OVERRIDE", m, fixed = TRUE),
   "a non-contract baseline window stops, naming the value and the override")
m <- tryCatch({ subseq_check_windows(365L, 30L); "" }, error = conditionMessage)
ok(grepl("SUBSEQ_FU_CE_DAYS=30", m, fixed = TRUE),
   "...and so does a non-contract follow-up window")
withr("NDMM_SUBSEQ_OVERRIDE", "TRUE", function()
  runs(subseq_check_windows(180L, 30L),
       "overridden windows build, marked as a sensitivity in the log"))
# And the build actually asks. A guard nothing calls is a guard that exists
# only in its tests.
ok(any(grepl("subseq_check_windows(pre_days, fu_days)",
             deparse(body(build_subsequent)), fixed = TRUE)),
   "build_subsequent() calls the window check before it does anything else")

cat("\n-- it can actually run --\n")
# Every function called has to exist, or the first thing a production run
# finds is a typo. set_ndmm_config() was one.
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
sys.source(file.path(ROOT, "R", "build_ndmm.R"), envir = env)
missing <- Filter(function(f) !exists(f, envir = env) && !exists(f, envir = globalenv()) &&
                    !exists(f, envir = baseenv()) &&
                    !any(vapply(search(), function(s) exists(f, where = s, inherits = FALSE),
                                logical(1))),
                  setdiff(scan_names$called, scan_names$bound))
ok(!length(missing),
   if (length(missing)) paste0("calls a function that does not exist: ",
                               paste(missing, collapse = ", "))
   else "every function it calls exists")

cat("\n-- two subsequent builds on one prefix --\n")
# The three outputs carry no run id in their names, so two of these at once
# interleave and both reach complete having published a pair that is partly the
# other's. The 1L build has had this check; this one had none.
sc <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "build_subsequent.R"), sc)
assign("wrk", function(x) paste0("sch.p_", x), envir = sc)
assign("log_msg", function(...) invisible(NULL), envir = sc)
assign("sql_text", function(x) paste0("'", x, "'"), envir = sc)
assign("missing_object_error", function(e)
  grepl("TABLE_OR_VIEW_NOT_FOUND", conditionMessage(e), fixed = TRUE), envir = sc)
drive_ar <- function(rows) {
  assign("db_q", function(con, sql) if (inherits(rows, "condition")) stop(rows) else rows,
         envir = sc)
  tryCatch({ sc$subseq_check_no_active_run(NULL, list(object_prefix = "p_")); "" },
           error = conditionMessage)
}
none <- data.frame(ATTEMPT = character(0), UPDATED_AT = character(0))
ok(identical(drive_ar(none), ""), "nothing started on the prefix is fine")
m <- drive_ar(data.frame(ATTEMPT = "A1", UPDATED_AT = "2026-08-13"))
ok(grepl("Another subsequent build is marked started", m, fixed = TRUE) &&
     grepl("A1", m, fixed = TRUE),
   "a build already started stops this one, naming the attempt")
ok(identical(drive_ar(simpleError("TABLE_OR_VIEW_NOT_FOUND: p_x")), ""),
   "no status table yet is the first run, not a failure")
m2 <- drive_ar(simpleError("permission denied"))
ok(grepl("is unknown", m2, fixed = TRUE),
   "...but any other read failure is the check not running, which is not a pass")
was <- Sys.getenv("NDMM_SUBSEQ_IGNORE_ACTIVE_RUN", unset = NA)
Sys.setenv(NDMM_SUBSEQ_IGNORE_ACTIVE_RUN = "TRUE")
ok(identical(drive_ar(data.frame(ATTEMPT = "A1", UPDATED_AT = "x")), ""),
   "...and the override named in the message is the way past")
if (is.na(was)) Sys.unsetenv("NDMM_SUBSEQ_IGNORE_ACTIVE_RUN") else
  Sys.setenv(NDMM_SUBSEQ_IGNORE_ACTIVE_RUN = was)

report()
