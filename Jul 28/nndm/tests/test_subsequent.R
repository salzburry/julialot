#!/usr/bin/env Rscript
# The 2L and 3L cohorts, held to protocol 6.2.1.1. No warehouse: the SQL is
# built as a string and the guards are driven with stubs, so what is checked
# here is the rule, not the connection.
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

SQL2 <- subseq_cohort_sql(2L, "s.c1", "s.c2", 365L, 3L, "2026-03-31",
                          "s.LINES", "s.SPANS", "s.SPANS_STRICT")
SQL3 <- subseq_cohort_sql(3L, "s.c2", "s.c3", 365L, 3L, "2026-03-31",
                          "s.LINES", "s.SPANS", "s.SPANS_STRICT")
FUN2 <- subseq_funnel_sql(2L, "s.c1", 365L, 3L, "2026-03-31",
                          "s.LINES", "s.SPANS", "s.SPANS_STRICT")

cat("\n-- criterion 1: received that line --\n")
ok(has(SQL2, "WHERE l.LOT_NUM = 2"), "2L indexes on the LOT 2 rows")
ok(has(SQL3, "WHERE l.LOT_NUM = 3"), "3L indexes on the LOT 3 rows")
ok(has(SQL2, "min(cast(l.LOT_START_DT as date)) AS COHORT_INDEX_DATE"),
   "the index date is that line's start")
ok(has(SQL2, "INNER JOIN idx i"),
   "a patient with no such line is not in the cohort at all")

cat("\n-- criterion 2: 12 months of CE before the index --\n")
ok(has(SQL2, "date_sub(g.COHORT_INDEX_DATE, 365)"),
   "the baseline window opens 365 days before the index")
# The day before the index, the same window 06_flags.R uses at 1L. The index
# day itself is the follow-up criterion's.
ok(has(SQL2, "s.cov_end >= date_sub(g.COHORT_INDEX_DATE, 1)"),
   "...and closes the day before it, as at 1L")
fl <- paste(readLines(file.path(ROOT, "R", "steps", "06_flags.R"), warn = FALSE),
            collapse = "\n")
ok(has(fl, "date_sub(l1.LOT1_START_DT, 1)") &&
     has(fl, "{NDMM_PRE_LOT1_DAYS}) AS pre_lot1_start"),
   "...which is the window 1L actually uses, not one written twice differently")
ok(has(SQL2, "LEFT JOIN s.SPANS s"),
   "the baseline reads the gap-merged spans - gaps of <= 30 days stay continuous")
pre_block <- sub("^.*pre AS \\(", "", sub("\\),\\s*fu AS.*$", "", SQL2))
ok(has(pre_block, "s.SPANS") && !has(pre_block, "SPANS_STRICT"),
   "...and only those - the strict spans would be a stricter rule than the protocol's")

cat("\n-- criterion 3: 3 months of follow-up CE, or death --\n")
fu_block <- sub("^.*fu AS \\(", "", SQL2)
ok(has(fu_block, "SPANS_STRICT"),
   "follow-up reads the NO-GAP spans - 'no gaps in enrollment'")
ok(has(SQL2, "add_months(g.COHORT_INDEX_DATE, 3)"),
   "the follow-up window is 3 months from that cohort's own index")
ok(has(SQL2, "coalesce(g.DEATH_DT, date('2026-03-31'))"),
   "death truncates the window rather than failing it")
ok(has(SQL2, "date('2026-03-31')"), "study end truncates it too")
# The 1L cohort's follow-up window is one day, by the study team's answer.
# This one is the protocol's three months. Neither is a literal in the SQL.
ok(NDMM_FU_CE_DAYS == 0L && SUBSEQ_FU_CE_MONTHS == 3L,
   "1L follows up for 0 days and these cohorts for 3 months - two named numbers")
ok(has(subseq_cohort_sql(2L, "a", "b", 365L, 6L, "2026-03-31", "l", "s", "t"),
       "add_months(g.COHORT_INDEX_DATE, 6)"),
   "...and the window is what is passed in, not baked in")

cat("\n-- both criteria are required, and the funnel counts the same ones --\n")
ok(has(SQL2, "WHERE coalesce(pre.CE_PRE_12MO, 0) = 1 AND coalesce(fu.CE_FU, 0) = 1"),
   "a patient failing either criterion is not in the cohort")
ok(has(FUN2, "date_sub(g.ix, 365)") && has(FUN2, "s.cov_end >= date_sub(g.ix, 1)"),
   "the funnel's baseline test is the cohort's")
ok(has(FUN2, "add_months(g.ix, 3)") &&
     has(FUN2, "coalesce(g.DEATH_DT, date('2026-03-31'))"),
   "the funnel's follow-up test is the cohort's")
ok(has(FUN2, "AS n_from") && has(FUN2, "AS n_reached") &&
     has(FUN2, "AS n_ce_pre") && has(FUN2, "AS n_final"),
   "the funnel reports every step, so the drop at each is on the record")

cat("\n-- 3L is a subset of 2L, not of 1L --\n")
ok(has(SQL3, "FROM s.c2 c"),
   "3L is drawn from the 2L cohort table")
ok(has(SQL2, "FROM s.c1 c"),
   "...and 2L from the 1L cohort table")
bs <- paste(readLines(file.path(ROOT, "R", "build_subsequent.R"), warn = FALSE),
            collapse = "\n")
ok(has(bs, "from <- out"),
   "the loop feeds each cohort into the next, so a 2L failure cannot reach 3L")
ok(!has(bs, "NDMM_COHORT_1L") && has(bs, 'wrk("NDMM_COHORT")'),
   "the 1L cohort is read, never written")
ok(!has(bs, "LOT_LONG_FINAL')} AS") && !has(bs, "CREATE OR REPLACE TABLE {wrk('LOT"),
   "nothing here writes a LOT table")

cat("\n-- the lines have to come from a finished run over this cohort --\n")
mk <- function(...) {
  d <- data.frame(..., stringsAsFactors = FALSE)
  e <- new.env(parent = globalenv())
  assign("db_q", function(con, sql) d, envir = e)
  assign("log_msg", function(...) invisible(NULL), envir = e)
  assign("wrk", function(t) paste0("sch.ndmm_", t), envir = e)
  environment(subseq_check_lot_run) <- e
  subseq_check_lot_run
}
good <- list(RUN_ID = "r1", STATE = "complete", UPDATED_AT = "t",
             INPUT_COHORT_TABLE = "sch.ndmm_NDMM_COHORT", CONTRACT_DEVIATIONS = "")
runs(do.call(mk, good)(NULL, "ndmm_"), "a complete run over this cohort is accepted")
stops(do.call(mk, modifyList(good, list(STATE = "running")))(NULL, "ndmm_"),
      "an unfinished run is refused - it replaces the lines before validating them")
stops(do.call(mk, modifyList(good, list(STATE = "failed")))(NULL, "ndmm_"),
      "a failed run is refused")
stops(do.call(mk, modifyList(good, list(
        INPUT_COHORT_TABLE = "sch.other_NDMM_COHORT")))(NULL, "ndmm_"),
      "a run built over another cohort is refused")
stops(do.call(mk, modifyList(good, list(
        CONTRACT_DEVIATIONS = "gap_days=60")))(NULL, "ndmm_"),
      "a run built with LOT_CONTRACT_OVERRIDE is refused")
local({
  e <- new.env(parent = globalenv())
  assign("db_q", function(con, sql) stop("TABLE_OR_VIEW_NOT_FOUND"), envir = e)
  assign("wrk", function(t) paste0("sch.", t), envir = e)
  f <- subseq_check_lot_run; environment(f) <- e
  stops(f(NULL, "ndmm_"), "no LOT run at all is refused, not treated as zero rows")
})
# The status row is read by name, so a column order change cannot silently
# read STATE out of the wrong column.
ok(has(bs, 'match(toupper(nm), toupper(names(d)))'),
   "the status row is read by column name")

cat("\n-- the settings that defined the 1L cohort still hold --\n")
for (g in c("check_settings()", "check_contract(cfg)", "check_constants(cfg)"))
  ok(has(bs, g), paste0("build_subsequent() runs ", g))
ok(has(bs, "pin_output_schema(cfg_defaults)") && has(bs, "pin_prefix(cfg, prefix)"),
   "the schema and prefix are pinned the same way build_nndm() pins them")
ok(has(bs, "set_lot_config(cfg)"),
   "...and the config is set, so wrk() prefixes every name")

cat("\n-- the entrypoint --\n")
ep <- paste(readLines(file.path(ROOT, "build_subsequent_cohorts.R"), warn = FALSE),
            collapse = "\n")
ok(has(ep, "build_subsequent(here, prefix)"), "the script calls the builder")
ok(has(ep, 'source(file.path(here, "R", "build_subsequent.R"))'),
   "...and loads the rules, which load_nndm_modules() does not")
ok(has(ep, "if (!interactive())"),
   "sourcing it in a session does not start a build")
# Every function it calls has to exist, or the first thing a production run
# finds is a typo. set_nndm_config() was one.
scan_names <- local({
  fns <- character(0); bound <- character(0)
  walk <- function(e) {
    if (is.call(e)) {
      if (is.name(e[[1]])) {
        nm <- as.character(e[[1]])
        # Anything given a name here - including a helper defined inside
        # another function - counts as defined.
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
called <- setdiff(scan_names$called, scan_names$bound)
env <- new.env(parent = globalenv())
sys.source(file.path(ROOT, "R", "build_nndm.R"), envir = env)
missing <- Filter(function(f) !exists(f, envir = env) && !exists(f, envir = globalenv()) &&
                    !exists(f, envir = baseenv()) &&
                    !any(vapply(search(), function(s) exists(f, where = s, inherits = FALSE),
                                logical(1))),
                  called)
ok(!length(missing),
   if (length(missing)) paste0("calls a function that does not exist: ",
                               paste(missing, collapse = ", "))
   else "every function it calls exists")

report()
