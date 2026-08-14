#!/usr/bin/env Rscript
# The stockpiling sensitivity, held to what it claims to measure. No warehouse:
# the SQL is built as a string and read.
#
#   Rscript "lot/validation/tests/test_stockpiling.R"

ROOT <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                                 fixed = TRUE))) else getwd()
  dirname(d)
})
PARENT <- dirname(ROOT)
pass <- 0L; fail <- 0L
ok <- function(cond, what) {
  if (isTRUE(cond)) { pass <<- pass + 1L; cat("  ok    ", what, "\n") }
  else { fail <<- fail + 1L; cat("  FAIL  ", what, "\n") }
}
has <- function(x, s) grepl(s, x, fixed = TRUE)
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
sql_text <- function(x) paste0("'", gsub("'", "''", as.character(x)), "'")
source(file.path(ROOT, "R", "stockpiling.R"))
source(file.path(ROOT, "R", "rechallenge.R"))

cat("\n-- the windows are the build's own, and a junk one falls back --\n")
Sys.unsetenv(c("INDUCTION_WINDOW_DAYS", "INDUCTION_WINDOW_DAYS_LOT_N",
               "CART_CONSOLIDATION_DAYS"))
sc <- stock_cfg()
ok(identical(sc$ind1, 60L) && identical(sc$indn, 30L) && identical(sc$cart, 45L),
   "60 / 30 / 45 are the defaults, matching the engine's config")
cfgcsv <- readLines(file.path(PARENT, "engine", "config.csv"), warn = FALSE)
ok(any(grepl("^INDUCTION_WINDOW_DAYS,60", cfgcsv)) &&
     any(grepl("^INDUCTION_WINDOW_DAYS_LOT_N,30", cfgcsv)) &&
     any(grepl("^CART_CONSOLIDATION_DAYS,45", cfgcsv)),
   "...and those are the numbers the engine ships, not a second copy")
# A run's own contract wins over this environment: a line has to be judged by
# the window it was built under.
ok(identical(stock_cfg(list(INDUCTION_WINDOW_DAYS_LOT_N = "45"))$indn, 45L),
   "the run's recorded window is preferred over the environment")
ok(identical(stock_cfg(list(INDUCTION_WINDOW_DAYS_LOT_N = "nope"))$indn, 30L),
   "a window that is not a number falls back rather than becoming NA")

cat("\n-- the window expression is per start type, like the step's own --\n")
w <- stock_window_sql(sc)
ok(has(w, "cast(LOT_NUM as int) = 1") && has(w, "59"),
   "LOT1 gets its own 60-day window, inclusive of the first day")
ok(has(w, "LOT_START_TYPE = 'CART'") && has(w, "44"),
   "a CAR-T-started line closes at the 45-day consolidation window")
ok(has(w, "29"), "every other line gets 30")

cat("\n-- what it counts is an agent covered in but never filled in --\n")
ag <- stock_agents_sql("lines", "maps", "claims", sc, "r1")
ok(has(ag, "cast(m.MAP_START_DT as date) <  l.LOT_START_DT") &&
     has(ag, "cast(m.MAP_END_DT as date)   >= l.LOT_START_DT"),
   "carried means the episode opened before the line and still covers its start")
ok(has(ag, "cast(m.MAP_START_DT as date) >= l.LOT_START_DT") &&
     has(ag, "cast(m.MAP_START_DT as date) <= l.IND_END_DT"),
   "...and an agent with a fill inside the window is excluded as already in")
ok(has(ag, "WHERE f.MED_ABBR IS NULL"),
   "...by an anti-join, so only the agents a coverage rule would ADD come out")
# The regimen column is a formatted string, so matching agents inside it would
# make LEN match LENA. The exclusion is built from fills for that reason.
ok(!has(ag, "LOT_BASE_MEDS"),
   "membership is decided from fills, never by matching inside LOT_BASE_MEDS")
ok(has(ag, "m.MAP_MED_CLASS <> 'STEROID'"),
   "steroids are not agents here, the same way they are not in a regimen")
ok(has(ag, "WHERE LOT_START_TYPE <> 'SCT_ALLO'"),
   "ALLO lines are excluded - they carry no regimen for an agent to join")

cat("\n-- and the two boundary effects that follow from it --\n")
ok(has(ag, "c.EPISODE_END_DT > c.LOT_DISCON_DT") && has(ag, "WOULD_EXTEND_RUNOUT"),
   "an agent outlasting the line's run-out is flagged: as a base agent it extends it")
ok(has(ag, "c.LOT_BASE_END_REASON = 'MED_ADD' AND c.ADD_MED = c.MED_ABBR") &&
     has(ag, "WOULD_REMOVE_ADD_MED"),
   "an agent that ended the line as an addition is flagged: in the regimen it could not")
ok(has(ag, "min(cast(m.MAP_START_DT as date))") &&
     has(ag, "max(cast(m.MAP_END_DT as date))"),
   "several overlapping episodes of one drug are one carried exposure, not several")

cat("\n-- and it separates a real absorbed refill from leftover cover --\n")
# The one the study team settled is leftover cover. A claim that landed inside
# the window and was swallowed by an already-open episode is a different case:
# the patient was still filling the drug. MAP_START_DT cannot see it, so the
# split has to come off the claim dates.
ok(has(ag, "cast(c.DATE_SERVICE as date) >= l.LOT_START_DT") &&
     has(ag, "cast(c.DATE_SERVICE as date) <= l.IND_END_DT"),
   "a real fill is a claim date inside the window, not an episode start")
ok(has(ag, "FROM ln l\n      INNER JOIN {claims_tbl} c") ||
     has(ag, "INNER JOIN claims c"),
   "...read from the claims table, which is the only place it survives")
ok(has(ag, "HAS_REAL_FILL_IN_WINDOW"),
   "...and carried as its own column rather than folded into the total")
ok(has(ag, "c.MED_CLASS <> 'STEROID'"),
   "steroid claims are not agents here either")
im0 <- stock_impact_sql("agents")
ok(has(im0, "max(HAS_REAL_FILL_IN_WINDOW)"),
   "the split survives the per-line rollup")
ok(has(stock_by_lot_sql("impact", "lines"), "N_WITH_REAL_FILL"),
   "...and reaches the by-LOT table, where the decision gets read")
run0 <- paste(readLines(file.path(ROOT, "run_stockpiling_rule.R"), warn = FALSE),
              collapse = "\n")
ok(has(run0, "MMA_MED_PROCESSED"),
   "the runner reads the claim table by name")
ok(has(run0, "would be reported as passive"),
   "...and stops when it cannot, rather than calling every carried agent passive")

cat("\n-- the rollups do not turn a missing answer into a zero --\n")
im <- stock_impact_sql("agents")
ok(has(im, "GROUP BY PATID, LOT_NUM"),
   "impact is per line, so a line gaining two agents counts once")
ok(has(im, "LOT_MED_CNT + count(*)"), "...and carries the regimen size before and after")
bl <- stock_by_lot_sql("impact", "lines")
ok(has(bl, "FROM {lines_tbl}") || has(bl, "FROM lines"),
   "the denominator is every line at that LOT, not the affected ones")
ok(has(bl, "LEFT JOIN hit"),
   "...so a LOT with no affected lines is a zero row rather than a missing one")
ok(has(bl, "nullif(a.N_LINES, 0)"),
   "the share divides by nullif, so an empty LOT is NULL and not a divide by zero")

cat("\n-- the boundaries absorption swallowed after the window --\n")
aa <- stock_absorbed_add_sql("lines", "maps", "claims", sc, "r1", "run", "stamp")
ok(has(aa, "cast(c.DATE_SERVICE as date) >  l.IND_END_DT"),
   "it looks strictly AFTER the induction window, where add-med candidates live")
ok(has(aa, "cast(c.DATE_SERVICE as date) <= l.LOT_END_DT"),
   "...and no further than the line's end, since a later claim is the next line's")
ok(has(aa, "INNER JOIN claims c") && has(aa, "c.DATE_SERVICE"),
   "the claim dates are the source; MAP_START_DT cannot see a fill it absorbed")
ok(has(aa, "o.CLAIM_DT = c.CLAIM_DT") && has(aa, "o.MED_ABBR IS NULL"),
   "absorbed = no episode starts on the claim's own date")
ok(has(aa, "f.MED_ABBR IS NULL"),
   "only agents outside this line's regimen, the way 10_lot2_5_base.R joins base_meds")
ok(has(aa, "LATERAL VIEW explode(split(coalesce(LOT_BASE_MEDS, ''), ' '))"),
   "the previous regimen splits to whole tokens, so LEN cannot match LENA")
ok(has(aa, "cast(LOT_NUM as int) + 1 AS LOT_NUM"),
   "...and it is the PREVIOUS line's regimen that the re-challenge flag reads")
ok(has(aa, "LOT_START_TYPE <> 'SCT_ALLO'"),
   "ALLO lines carry no regimen, so they are excluded here too")
abl <- stock_absorbed_by_lot_sql("absorbed", "lines")
ok(has(abl, "LEFT JOIN hit") && has(abl, "nullif(a.N_LINES, 0)"),
   "the by-LOT rollup zero-fills and divides safely, like its sibling")
ok(has(abl, "GROUP BY PATID, LOT_NUM"),
   "a line absorbing two agents counts once, not twice")

cat("\n-- re-challenge: the gap, and the joins that make it mean anything --\n")
rc <- rechall_cfg()
re <- rechall_events_sql("lines", "maps", "claims", "absorbed", rc, "r1", "run", "stamp")
ok(has(re, "cast(c.DATE_SERVICE as date) < r.RETURN_DT"),
   "the gap runs from a claim strictly BEFORE the return, so it cannot be negative")
ok(has(re, "AND pc.MED_ABBR = r.MED_ABBR AND pc.RETURN_DT = r.RETURN_DT"),
   "prev_claim is joined on RETURN_DT, not just the agent - a line can hold two returns")
ok(has(re, "AND p.MED_ABBR = r.MED_ABBR AND p.RETURN_DT = r.RETURN_DT"),
   "...and so is the partner count, whose window is measured around that date")
ok(has(re, "GROUP BY r.PATID, r.LOT_NUM, r.MED_ABBR, r.RETURN_DT"),
   "both are grouped on the same key they are joined on")
ok(has(re, "row_number() OVER (PARTITION BY r.PATID, r.LOT_NUM, r.MED_ABBR"),
   "one boundary opportunity per line and agent: the earliest return")
ok(has(re, "fs.FIRST_SEEN_LOT < e.LOT_NUM") && has(re, "lm.MED_ABBR IS NULL"),
   "an event is an agent from an EARLIER line that is absent from this one")
lt <- rechall_late_sql("events")
ok(has(lt, "WHEN DAYS_BUILD_LATE IS NOT NULL   THEN 'on a later return'"),
   "a suppressed return the build acted on later is not a missing boundary")
ok(has(lt, "'never in this line'"),
   "...and one it never acted on in that line is reported apart from it")
ok(has(re, "DAYS_BUILD_LATE"),
   "a boundary the build made on a later return is late, not missing")
run2 <- paste(readLines(file.path(ROOT, "run_rechallenge_evidence.R"), warn = FALSE),
              collapse = "\n")
ok(has(run2, "GAP_DAYS < 0 THEN 1 ELSE 0 END) AS n_neg"),
   "the runner stops on a negative gap rather than reporting it")
ok(has(run2, "STOCKPILE_ABSORBED_ADD"),
   "...and refuses to run without the absorbed table, which is half the events")

cat("\n-- the program says what it cannot answer --\n")
run <- paste(readLines(file.path(ROOT, "run_stockpiling_rule.R"), warn = FALSE),
             collapse = "\n")
ok(has(run, "STOCK_EXECUTE"),
   "measuring is opt-in, so a dry run cannot write to a warehouse")
ok(has(run, "require_lot_run"),
   "it refuses a run whose own build did not finish, like its siblings")
ok(has(run, "needs an alternate build"),
   "...and says the resulting line structure is not what it reports")
ok(has(run, "WARNING: LOT1 shows"),
   "a non-zero LOT1 is reported rather than filtered, since it falsifies the premise")

cat("\n", strrep("-", 52), "\n", sep = "")
cat(sprintf("%d passed, %d failed\n", pass, fail))
if (fail > 0L) quit(status = 1L)
