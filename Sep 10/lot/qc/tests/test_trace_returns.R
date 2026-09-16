#!/usr/bin/env Rscript
# The returning-drug trace, checked without a warehouse.
#
#   Rscript "lot/qc/tests/test_trace_returns.R"
#
# Three kinds of test, as test_foldin_trace.R has them. The SQL as text: which
# tables each kind reads and the predicates that make it that kind. The SQL
# executed through DuckDB on tests/returns_fixture.R - six patients, one per
# shape - and on variants of them that differ in one thing each. And the R
# that filters, samples, summarises, annotates and renders, held to the
# fixture's answers and to the committed example.

ROOT <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                                 fixed = TRUE))) else getwd()
  dirname(d)
})

pass <- 0L; fail <- 0L
ok <- function(cond, what) {
  cond <- tryCatch(cond, error = function(e) {
    what <<- paste0(what, "  [raised: ", conditionMessage(e), "]")
    FALSE
  })
  if (isTRUE(cond)) { pass <<- pass + 1L; cat("  ok     ", what, "\n") }
  else              { fail <<- fail + 1L; cat("  FAIL   ", what, "\n") }
}
stops <- function(expr, what) ok(inherits(tryCatch(expr, error = function(e) e), "error"), what)
has   <- function(x, s) grepl(s, x, fixed = TRUE)
errs  <- function(expr) tryCatch({ expr; NA_character_ }, error = function(e) conditionMessage(e))

source(file.path(ROOT, "R", "checks.R"))
source(file.path(ROOT, "R", "foldin_trace.R"))
source(file.path(ROOT, "R", "return_trace.R"))
source(file.path(ROOT, "tests", "exec_harness.R"))
source(file.path(ROOT, "tests", "returns_fixture.R"))

TBL <- list(final = "s.TFINAL", long = "s.TLONG", map = "s.TMAP",
            sct = "s.TSCT", auto = "s.TAUTO", allo = "s.TALLOCART",
            attrition = "s.TATTR", meta = "s.TMETA",
            cohort = "s.TCOHORT", subs = "s.TSUBS")
P <- return_trace_params(RETURNS_SETTINGS, "run-abc")
Q <- return_trace_queries(TBL, P)
ok(identical(P$gap, qc_int(RETURNS_SETTINGS, "map_discon_gap_days")) &&
     identical(P$melp_days, qc_int(RETURNS_SETTINGS, "melp_simple_course_days")),
   "return_trace_params adds the two settings the frozen QC catalogue does not carry, so no caller has to remember them")
ok(is.na(return_trace_params(sub("[|]melp_simple_course_days=[^|]*", "", RETURNS_SETTINGS),
                             "run-abc")$melp_days),
   "...and a run built before the course cap was recorded gets NA, which is the melp_confirmed arm not being emitted")
ok(inherits(try(return_trace_params(sub("[|]map_discon_gap_days=[^|]*", "", RETURNS_SETTINGS),
                                    "run-abc"), silent = TRUE), "try-error"),
   "...while a run missing the discontinuation gap still refuses to be traced")

cat("\n-- the fixture is a build the engine could have produced --\n")
ok(identical(returns_fixture_defects(), character(0)),
   "no fixture line ends MED_ADD with the added agent past a confirmed run-out - the engine's own gate would have made it DISCONTINUATION")
BROKEN <- RETURNS_FIXTURE
BROKEN$map[[1]] <- rf_ep("R000001", "BORT", "2020-01-01", "2020-05-15", discon = 1L, cnt = 5L)
bd <- returns_fixture_defects(BROKEN)
ok(length(bd) == 1L && grepl("R000001 LOT 1", bd[1], fixed = TRUE) &&
     grepl("past a run-out on 2020-05-15", bd[1], fixed = TRUE),
   "...and the check is not vacuous: pulling one episode's cover back before the added agent is caught, with the date it would have ended on")

cat("\n-- the queries, as text --\n")
ok(identical(names(Q), c("fold", "own_return", "opens_line", "carried_over")),
   "four kinds, in the order the report explains them")
ok(identical(Q$fold, foldin_trace_sql(TBL, P)),
   "the fold is the fold-in trace's own query, unchanged, so the two reports agree on what a fold is")
others <- c("s.TLONG", "s.TSCT", "s.TATTR", "s.TMETA", "s.TCOHORT")
for (k in c("own_return", "opens_line", "carried_over")) {
  q <- Q[[k]]
  ok(has(q, "s.TFINAL") && has(q, "s.TMAP") && has(q, "s.TALLOCART"),
     paste0(k, " reads the published lines, the episodes and the ALLO/CAR-T dates (for the window's cutoff)"))
  ok(!any(vapply(others, function(x) has(q, x), logical(1))),
     paste0(k, " ...and no other table: not LOT_LONG, the SCT tables, the funnel, the metadata or the cohort"))
  ok(has(q, "MAP_MED_TYPE = w.MED_ABBR") || has(q, "MAP_MED_TYPE = w.MED_ABBR"),
     paste0(k, " joins the episode table on MAP_MED_TYPE, the persisted drug column"))
  ok(!grepl("ms2?[.]MED_ABBR|MAP_MED_ABBR", q),
     paste0(k, " ...never on MED_ABBR or MAP_MED_ABBR"))
  ok(has(q, "STEROID"), paste0(k, " keeps steroids out - a steroid never opened a line under either reading"))
}
ok(!has(Q$own_return, "s.TSUBS"),
   "an own return needs no substitute pair: the drug is the line's own, under its own name")
ok(has(Q$opens_line, "s.TSUBS") && has(Q$carried_over, "s.TSUBS"),
   "the line-opening and carried-over kinds read the substitute pairs: a previous line carrying the drug under either name counts (4.4)")
# The own return's predicates.
ok(has(Q$own_return, "lag(MAP_DISCON_FLG) OVER (PARTITION BY cast(PATID as string), MAP_MED_TYPE") &&
     has(Q$own_return, "coalesce(e.PREV_DISCON, 0) = 1"),
   "an own return follows a CONFIRMED break: the immediately preceding episode of the drug carries MAP_DISCON_FLG = 1, the engine's own restart test")
ok(has(Q$own_return, "e.MAP_START_DT >  w.ELIGIBLE_END") && has(Q$own_return, "e.MAP_START_DT <= w.LOT_BASE_END_DT"),
   "...and the return is inside the line, after the induction window")
ok(has(Q$own_return, "AND e.PREV_START >= w.LOT_START_DT"),
   "...of a drug the line already held: the dose the break follows was itself inside this line, which is what a fold's own first return fails")
ok(has(Q$own_return, "LEFT JOIN in_window iw") && has(Q$own_return, "AS HAS_WINDOW_EP"),
   "...and whether the window admitted it is carried for the narrative, not required - a folded drug has no window episode and is the line's all the same")
ok(has(Q$own_return, "'own_return' AS KIND") && has(Q$own_return, "w.LOT_NUM AS RETURN_LINE"),
   "...tagged with its kind, on the line it sits in")
# The line-opening return's predicates.
ok(has(Q$opens_line, "pl.LOT_NUM <= a.LOT_NUM - 2") && has(Q$opens_line, "max(pl.LOT_NUM) AS FROM_LOT"),
   "a line-opening return was in a line two or more back, and the nearest such line is named")
ok(has(Q$opens_line, "w.LOT_START_TYPE = 'MED' AND w.LOT_NUM >= 3") && has(Q$opens_line, "e.MAP_START_DT = w.LOT_START_DT"),
   "...it opened a medication-started line: its episode starts on the line's start date")
ok(has(Q$opens_line, "NOT EXISTS") && has(Q$opens_line, "FROM prev_carried pc") && has(Q$opens_line, "pl.LOT_NUM = a.LOT_NUM - 1"),
   "...and the IMMEDIATELY previous line did not carry it, under any name: that drug cannot open a line (4.3)")
ok(has(Q$opens_line, "w.LOT_NUM - 1 AS RETURN_LINE") && has(Q$opens_line, "PREV_LINE_START_TYPE"),
   "...belongs to the line before the one it opened, and says what opened that line")
ok(has(Q$carried_over, "INNER JOIN prev_carried pc") && has(Q$carried_over, "INNER JOIN in_window iw") &&
     has(Q$carried_over, "'carried_over' AS KIND"),
   "a carried-over drug is a previous-line drug with an episode inside this line's window")
ok(all(vapply(Q[-1], function(q) has(q, "qc_window_sql") || has(q, "ELIGIBLE_END"), logical(1))) &&
     has(Q$own_return, "date_add(l.LOT_START_DT,"),
   "every kind reads the window from qc_window_sql() in R/checks.R, the one definition C1 reads")

cat("\n-- the filters --\n")
ok(identical(return_trace_parse_kinds(""), RETURN_TRACE_KINDS), "TRACE_KINDS empty means all three traced kinds")
ok(identical(return_trace_parse_kinds("own_return, fold"), c("own_return", "fold")),
   "...and a list is taken as given, in its order")
e <- errs(return_trace_parse_kinds("fold,carried_over"))
ok(!is.na(e) && has(e, "carried_over"),
   "carried_over cannot be traced, only counted, so asking for it is refused by name")
ok(is.null(return_trace_parse_lines("")) && identical(return_trace_parse_lines("1,2"), c(1L, 2L)),
   "TRACE_LINES empty is every line; '1,2' is lines 1 and 2")
stops(return_trace_parse_lines("1,two"), "TRACE_LINES with a word in it is refused")
stops(return_trace_parse_lines("0"), "...and a line 0")
stops(return_trace_sample(NULL, 3, patids = "P1'; DROP"), "an id with a quote in it is refused before any query is built")

cat("\n-- the queries, RUN on the fixture --\n")
# The text tests above read the queries over fake table names; the executed
# ones need the harness's own, which the fixture rows are loaded under.
QX <- return_trace_queries(EXEC_TABLES, P)
rr <- returns_run_rows(QX, RETURNS_FIXTURE, ROOT)
if (is.null(rr)) {
  cat("  SKIP    the row runner could not be run\n")
} else if (identical(rr, "skip")) {
  cat("  SKIP    duckdb or sqlglot is not installed\n")
} else {
  err <- function(r) attr(r, "error")
  for (k in names(rr))
    ok(is.null(err(rr[[k]])), paste0("the ", k, " query runs", if (!is.null(err(rr[[k]]))) paste0(" [", err(rr[[k]]), "]") else ""))
  C <- return_trace_stack(rr)
  key <- function(d) paste(d$PATID, d$KIND, d$LOT_NUM, d$MED_ABBR)
  ok(nrow(C) == 8L, paste0("eight return rows on the eight patients, one per shape (got ", nrow(C), ")"))
  ok(all(C$MED_ABBR != "DEX"), "and no steroid among them, though DEX comes back in four of the patients")
  g <- function(pat, kind) C[C$PATID == pat & C$KIND == kind, , drop = FALSE]
  r <- g("R000001", "fold")
  ok(nrow(r) == 1L && r$LOT_NUM == 2L && r$MED_ABBR == "LEN" && format(r$RETURN_DT) == "2020-08-15" &&
       r$RETURN_LINE == 2L && r$PREV_BASE_MEDS == "BORT LEN",
     "R000001: LEN folded into LOT 2 on 2020-08-15, from a LOT 1 regimen of BORT LEN")
  ok(nrow(C[C$PATID == "R000001", ]) == 1L, "...and that is R000001's only return: a fold is not also an own return")
  r <- g("R000002", "own_return")
  ok(nrow(r) == 1L && r$LOT_NUM == 1L && r$MED_ABBR == "LEN" && format(r$RETURN_DT) == "2020-11-30" &&
       format(r$PREV_EP_START) == "2020-01-01" && format(r$PREV_EP_END) == "2020-04-30" && r$RETURN_LINE == 1L,
     "R000002: LEN came back to LOT 1 on 2020-11-30 after its 2020-01-01..2020-04-30 episode")
  r <- g("R000003", "own_return")
  ok(nrow(r) == 1L && r$LOT_NUM == 2L && r$MED_ABBR == "POM" && format(r$RETURN_DT) == "2021-05-01" &&
       format(r$PREV_EP_END) == "2020-12-15" && r$RETURN_LINE == 2L,
     "R000003: POM came back to LOT 2 on 2021-05-01 after a break from 2020-12-15")
  r <- g("R000004", "opens_line")
  ok(nrow(r) == 1L && r$LOT_NUM == 3L && r$MED_ABBR == "LEN" && r$FROM_LOT == 1L &&
       r$PREV_LINE_START_TYPE == "SCT_AUTO" && r$RETURN_LINE == 2L && format(r$PREV_EP_END) == "2020-06-30",
     "R000004: LEN from LOT 1 opened LOT 3 across a transplant-opened LOT 2; the return belongs to LOT 2")
  r <- g("R000005", "opens_line")
  ok(nrow(r) == 1L && r$LOT_NUM == 4L && r$MED_ABBR == "LEN" && r$FROM_LOT == 1L &&
       r$PREV_LINE_START_TYPE == "MED" && r$RETURN_LINE == 3L && r$PREV_BASE_MEDS == "POM",
     "R000005: LEN from LOT 1, two lines back, opened LOT 4 after a LOT 3 of POM")
  r <- g("R000006", "carried_over")
  ok(nrow(r) == 1L && r$LOT_NUM == 2L && r$MED_ABBR == "LEN" && format(r$RETURN_DT) == "2020-07-10",
     "R000006: LEN carried over into LOT 2's window on 2020-07-10 - counted, not a return")
  ok(nrow(C[C$PATID == "R000006" & C$KIND != "carried_over", ]) == 0L,
     "...and is no fold and no own return")

  # Variants that differ in one thing each.
  variant <- function(f) { d <- RETURNS_FIXTURE; f(d) }
  runk <- function(d, k) { r <- returns_run_rows(QX[k], d, ROOT)[[k]]; r }
  # (a) the break before the return is not confirmed: no own return.
  V <- variant(function(d) { d$map[[7]]$MAP_DISCON_FLG <- 0L; d })
  r <- runk(V, "own_return")
  ok(is.null(err(r)) && !any(r$PATID == "R000002"),
     "(a) with the earlier LEN episode's MAP_DISCON_FLG at 0, R000002's return is a continuation, not an own return")
  # (b) the return inside the window is induction, not a return.
  V <- variant(function(d) { d$map[[15]]$MAP_START_DT <- "2020-09-20"; d$map[[15]]$MAP_END_DT <- "2020-12-31"; d })
  r <- runk(V, "own_return")
  ok(is.null(err(r)) && !any(r$PATID == "R000003"),
     "(b) POM back on 2020-09-20, inside LOT 2's 30-day window, is not an own return")
  V <- variant(function(d) { d$map[[15]]$MAP_START_DT <- "2020-09-30"; d })
  r <- runk(V, "own_return")
  ok(is.null(err(r)) && !any(r$PATID == "R000003"), "(b) ...and the window's last day is inside it")
  V <- variant(function(d) { d$map[[15]]$MAP_START_DT <- "2020-10-01"; d })
  r <- runk(V, "own_return")
  ok(is.null(err(r)) && any(r$PATID == "R000003" & r$RETURN_DT == "2020-10-01"),
     "(b) ...while the day after it is outside, and the return is one")
  # (c) a return after the line ended is not this line's.
  V <- variant(function(d) { d$map[[15]]$MAP_START_DT <- "2021-09-15"; d$map[[15]]$MAP_END_DT <- "2021-12-31"; d })
  r <- runk(V, "own_return")
  ok(is.null(err(r)) && !any(r$PATID == "R000003"),
     "(c) POM back after LOT 2 ended (2021-08-31) is not a return to LOT 2")
  # (d) with LOT 3 carrying LEN, LEN cannot have opened LOT 4 by this route.
  V <- variant(function(d) { d$final[[11]]$LOT_BASE_MEDS <- "POM LEN"; d$final[[11]]$LOT_MED_CNT <- 2L; d })
  r <- runk(V, "opens_line")
  ok(is.null(err(r)) && !any(r$PATID == "R000005"),
     "(d) with the immediately previous line carrying LEN, its LOT 4 start is no line-opening return (4.3's drug cannot open a line)")
  # (e) a permissible substitute: LOT 1 named the reference product, LOT 4 the biosimilar.
  V <- variant(function(d) {
    d$subs <- list(list(original_med = "LEN", substitute_med = "LENBS"))
    d$final[[12]]$LOT_BASE_MEDS <- "LENBS"
    d$map[[26]]$MAP_MED_TYPE <- "LENBS"; d$map[[26]]$MAP_MED_ABBR <- "LENBS"; d })
  r <- runk(V, "opens_line")
  ok(is.null(err(r)) && any(r$PATID == "R000005" & r$MED_ABBR == "LENBS" & r$FROM_LOT == "1"),
     "(e) the biosimilar opening LOT 4 where LOT 1 named the reference product is the same drug coming back (4.4)")
  # (f) a second confirmed break in the same line is a second own return.
  V <- variant(function(d) {
    d$map[[9]]$MAP_END_DT <- "2021-01-31"; d$map[[9]]$MAP_DISCON_FLG <- 1L
    d$final[[3]]$LOT_BASE_END_DT <- "2021-12-31"; d$final[[3]]$LOT_BASE_DISCON_DT <- "2021-12-31"
    d$map[[length(d$map) + 1L]] <- rf_ep("R000002", "LEN", "2021-06-01", "2021-12-31", discon = 1L, cnt = 7L)
    d })
  r <- runk(V, "own_return")
  ok(is.null(err(r)) && sum(r$PATID == "R000002") == 2L && all(sort(r$RETURN_DT[r$PATID == "R000002"]) == c("2020-11-30", "2021-06-01")),
     "(f) LEN back twice after two confirmed breaks is two own returns, each with its own date")
  # (g) a steroid's return is not a return of any kind.
  V <- variant(function(d) { d$final[[3]]$LOT_BASE_MEDS <- "DEX"; d$final[[3]]$LOT_MED_CNT <- 1L;
    d$map[[7]]$MAP_DISCON_FLG <- 0L; d })
  r <- runk(V, "own_return")
  ok(is.null(err(r)) && !any(r$PATID == "R000002"),
     "(g) DEX coming back after a break is not an own return: a steroid never opened a line")

  cat("\n-- the shapes two independent readings of the engine went looking for --\n")
  # Each of these was executed against the engine's own code by a reviewer and
  # named a defect; each is the shape that defect was found on.

  # A folded drug's LATER course, back after a confirmed break, is 4.3's and
  # not a second fold: the engine keeps it through the line's effective
  # regimen (foldin_base_meds_eff), so it is neither an added medication nor a
  # next-line start. Gated on a window episode, the trace reported nothing.
  V <- variant(function(d) {
    d$map[[5]]$MAP_END_DT <- "2020-09-30"; d$map[[5]]$MAP_DISCON_FLG <- 1L
    d$map[[length(d$map) + 1L]] <- rf_ep("R000001", "LEN", "2021-01-05", "2021-01-31", cnt = 1L)
    d })
  r <- runk(V, "own_return")
  ok(is.null(err(r)) && any(r$PATID == "R000001" & r$RETURN_DT == "2021-01-05" & r$LOT_NUM == "2" &
                              r$HAS_WINDOW_EP == "0"),
     "a folded drug back again after a confirmed break is an own return of the line it was folded into, flagged as having no window episode")
  ok(is.null(err(r)) && sum(r$PATID == "R000001") == 1L,
     "...and the fold's own first return is not one: its previous dose was in the line before")
  rvv <- returns_run_rows(c(QX["fold"], QX["own_return"],
                            list(lines = foldin_trace_lines_sql(EXEC_TABLES, "R000001", P),
                                 eps = foldin_trace_episodes_sql(EXEC_TABLES, "R000001"),
                                 tx = foldin_trace_tx_sql(EXEC_TABLES, "R000001"))), V, ROOT)
  CV <- return_trace_stack(rvv[c("fold", "own_return")])
  annv <- return_trace_annotate(rvv$lines, rvv$eps, rvv$tx, CV, P)
  nv <- annv$note[annv$MAP_MED_TYPE == "LEN" & format(annv$MAP_START_DT) == "2021-01-05"]
  ok(identical(nv, "RETURNED to LOT 2 after a 97-day break (4.3)"),
     "...and the episode reads as that return, not as a second fold - the fold note is written first and this one over it")
  nb <- return_trace_narrative(CV[CV$KIND == "own_return", , drop = FALSE][1, , drop = FALSE],
                               rvv$lines, rvv$eps, P, all_rows = CV)
  ok(has(nb, "because 4.8 folded it in") && has(nb, "carries a folded drug in the line's regimen"),
     "...and its paragraph says how the drug came to be the line's, rather than claiming a window episode it has not got")

  # A procedure between the break and the return: under the older reading it
  # would have opened a line of its own first, so the counterfactual for the
  # return is not in these tables.
  V <- variant(function(d) { d$auto <- c(d$auto, list(rf_auto("R000002", "2020-08-01"))); d })
  rv <- returns_run_rows(c(QX["own_return"],
                           list(lines = foldin_trace_lines_sql(EXEC_TABLES, "R000002", P),
                                eps = foldin_trace_episodes_sql(EXEC_TABLES, "R000002"),
                                tx = foldin_trace_tx_sql(EXEC_TABLES, "R000002"))), V, ROOT)
  CV <- return_trace_stack(rv["own_return"])
  nv <- return_trace_narrative(CV[CV$PATID == "R000002", , drop = FALSE][1, , drop = FALSE],
                               rv$lines, rv$eps, P, tx = rv$tx, all_rows = CV)
  ok(nrow(CV[CV$PATID == "R000002", ]) == 1L,
     "a first autologous transplant between the break and the return does not stop the return being an own return - it never ended line 1 (3.4)")
  ok(has(nv, "a SCT_AUTO on 2020-08-01 falls between the break and the return") &&
       has(nv, "cannot be read from these tables") && !has(nv, "the next line would have started on 2020-11-30"),
     "...but the paragraph stops short of saying what the older reading would have opened, and names the procedure")

  # A permissible substitute covering the gap: the flag is per drug name, so
  # the return is still one, but the older reading's run-out is the pair's.
  V <- variant(function(d) {
    d$subs <- list(rf_subs("POM", "POMBS"))
    d$map[[length(d$map) + 1L]] <- rf_ep("R000003", "POMBS", "2020-12-20", "2021-04-20", cnt = 4L)
    d })
  rv <- returns_run_rows(c(QX["own_return"],
                           list(lines = foldin_trace_lines_sql(EXEC_TABLES, "R000003", P),
                                eps = foldin_trace_episodes_sql(EXEC_TABLES, "R000003"),
                                subs = foldin_trace_subs_sql(EXEC_TABLES))), V, ROOT)
  CV <- return_trace_stack(rv["own_return"])
  nv <- return_trace_narrative(CV[CV$PATID == "R000003", , drop = FALSE][1, , drop = FALSE],
                               rv$lines, rv$eps, P, subs = rv$subs, all_rows = CV)
  ok(nrow(CV[CV$PATID == "R000003", ]) == 1L,
     "a substitute dosed inside the gap leaves the return an own return: MAP_DISCON_FLG is per drug name, as the engine's own restart test is")
  ok(has(nv, "no supply of POM itself") && has(nv, "Its permissible substitute POMBS was dosed inside the gap") &&
       has(nv, "had run out on 2021-04-20") && !has(nv, "run out on 2020-12-15"),
     "...and the paragraph counts the substitute's cover as the line's (4.4): the older reading's run-out is the pair's 2021-04-20, not POM's own 2020-12-15")

  # ...while a return under the SUBSTITUTE's name is no own return at all.
  V <- variant(function(d) {
    d$subs <- list(rf_subs("POM", "POMBS"))
    d$map[[15]]$MAP_MED_TYPE <- "POMBS"; d$map[[15]]$MAP_MED_ABBR <- "POMBS"; d })
  r <- runk(V, "own_return")
  ok(is.null(err(r)) && !any(r$PATID == "R000003"),
     "a return under the substitute's name is not an own return: the older reading never released a substitute's restart either")

  # A new agent in the gap ends the line before the return, so the return
  # lands in the next line - as a fold, not an own return.
  V <- variant(function(d) {
    d$final[[5]]$LOT_BASE_END_DT <- "2021-01-31"; d$final[[5]]$LOT_BASE_END_REASON <- "MED_ADD"
    d$final[[length(d$final) + 1L]] <- rf_fin("R000003", 3L, "2021-02-01", "MED", "CARF POM", "2021-08-31")
    d$map[[length(d$map) + 1L]] <- rf_ep("R000003", "CARF", "2021-02-01", "2021-08-31", cnt = 7L)
    d })
  rr2 <- returns_run_rows(QX, V, ROOT)
  C2 <- return_trace_stack(rr2)
  ok(!any(C2$PATID == "R000003" & C2$KIND == "own_return") &&
       any(C2$PATID == "R000003" & C2$KIND == "fold" & C2$LOT_NUM == 3L),
     "an agent arriving in the gap ends the line first, so the return belongs to the next line and reads as a fold, not an own return")

  # The line before was a procedure line: the added-medication sentence is
  # read off its own end reason, never asserted.
  V <- variant(function(d) {
    d$final[[7]]$LOT_START_TYPE <- "CART"; d$final[[7]]$LOT_BASE_END_DT <- "2020-09-01"
    d$final[[7]]$LOT_BASE_END_REASON <- "SCT_CART"
    d$final[[7]]$LOT_BASE_1ST_ADD_MED <- NA; d$final[[7]]$LOT_BASE_1ST_ADD_MED_DT <- NA
    d$auto <- list(); d$allo <- list(rf_allo("R000004", "2020-09-01", "CART")); d })
  rv <- returns_run_rows(c(QX["opens_line"],
                           list(lines = foldin_trace_lines_sql(EXEC_TABLES, "R000004", P),
                                eps = foldin_trace_episodes_sql(EXEC_TABLES, "R000004"))), V, ROOT)
  CV <- return_trace_stack(rv["opens_line"])
  CV <- CV[CV$PATID == "R000004", , drop = FALSE]
  nv <- return_trace_narrative(CV[1, , drop = FALSE], rv$lines, rv$eps, P, all_rows = CV)
  ok(nrow(CV) == 1L && has(nv, "LOT 2 had already closed on a procedure (SCT_CART on 2020-09-01)") &&
       !has(nv, "added medication"),
     "a single-day CAR-T line the return did not end is reported as already closed, not as an added medication")

  # ...and a line that had already run out: the return confirmed it (5.3).
  V <- variant(function(d) {
    d$final[[7]]$LOT_BASE_END_REASON <- "DISCONTINUATION"
    d$final[[7]]$LOT_BASE_DISCON_DT <- "2020-11-30"
    d$final[[7]]$LOT_BASE_1ST_ADD_MED <- NA; d$final[[7]]$LOT_BASE_1ST_ADD_MED_DT <- NA; d })
  rv <- returns_run_rows(c(QX["opens_line"],
                           list(lines = foldin_trace_lines_sql(EXEC_TABLES, "R000004", P),
                                eps = foldin_trace_episodes_sql(EXEC_TABLES, "R000004"))), V, ROOT)
  CV <- return_trace_stack(rv["opens_line"])
  CV <- CV[CV$PATID == "R000004", , drop = FALSE]
  nv <- return_trace_narrative(CV[1, , drop = FALSE], rv$lines, rv$eps, P, all_rows = CV)
  ok(has(nv, "had already run out") && has(nv, "confirmed that run-out (5.3)") && !has(nv, "added medication"),
     "...and one that had run out first says the return confirmed it, not that it ended the line")

  # The refusal-across-a-procedure reading belongs only to a drug that line's
  # own fold set held. Further back, 4.8 never judged it.
  V <- list(final = list(
      rf_fin("R000009", 1L, "2020-01-01", "MED", "BORT LEN", "2020-06-30", "MED_ADD",
             add_med = "CARF", add_dt = "2020-07-01"),
      rf_fin("R000009", 2L, "2020-07-01", "MED", "CARF", "2021-01-31", "SCT_ALLO"),
      rf_fin("R000009", 3L, "2021-02-01", "SCT_ALLO", "", "2021-02-01", "SCT_ALLO"),
      rf_fin("R000009", 4L, "2021-03-01", "MED", "LEN", "2021-09-30")),
    map = list(rf_ep("R000009", "BORT", "2020-01-01", "2020-05-31", discon = 1L, cnt = 5L),
               rf_ep("R000009", "LEN", "2020-01-01", "2020-04-30", discon = 1L, cnt = 4L),
               rf_ep("R000009", "CARF", "2020-07-01", "2021-01-31", discon = 1L, cnt = 7L),
               rf_ep("R000009", "LEN", "2021-03-01", "2021-09-30", cnt = 7L)),
    allo = list(rf_allo("R000009", "2021-02-01", "ALLO")), auto = list(), subs = list())
  rv <- returns_run_rows(c(QX["opens_line"],
                           list(lines = foldin_trace_lines_sql(EXEC_TABLES, "R000009", P),
                                eps = foldin_trace_episodes_sql(EXEC_TABLES, "R000009"))), V, ROOT)
  CV <- return_trace_stack(rv["opens_line"])
  ok(nrow(CV) == 1L && CV$FROM_LOT == 1L && CV$LOT_NUM == 4L,
     "a drug from LOT 1 opening LOT 4 after a procedure-opened LOT 3 is a line-opening return")
  nv <- return_trace_narrative(CV[1, , drop = FALSE], rv$lines, rv$eps, P, all_rows = CV)
  annv <- return_trace_annotate(rv$lines, rv$eps, NULL, CV, P)
  ok(!has(nv, "refuses a fold across a procedure") && has(nv, "out of its scope"),
     "...and its paragraph does not credit 4.8's refusal: LOT 3's fold set was LOT 2's regimen, which never held the drug")
  ok(any(grepl("out of 4.8's scope", annv$note, fixed = TRUE)) &&
       !any(grepl("no fold across it", annv$note, fixed = TRUE)),
     "...nor does the episode note")

  # Melphalan: the one previous-line drug that opens a line (4.7), and the
  # drug that confirms such a course.
  V <- list(final = list(
      rf_fin("R000010", 1L, "2020-01-01", "MED", "LEN MELP", "2020-11-30", "MED_ADD",
             add_med = "MELP", add_dt = "2020-12-01"),
      rf_fin("R000010", 2L, "2020-12-01", "MED", "DARA MELP", "2021-06-30")),
    map = list(rf_ep("R000010", "LEN", "2020-01-01", "2020-06-30", discon = 1L, cnt = 6L),
               rf_ep("R000010", "MELP", "2020-02-01", "2020-03-01", discon = 1L, cnt = 1L),
               rf_ep("R000010", "MELP", "2020-12-01", "2020-12-28", cnt = 1L),
               rf_ep("R000010", "DARA", "2020-12-10", "2021-06-30", cnt = 7L)),
    allo = list(), auto = list(), subs = list())
  rv <- returns_run_rows(c(QX["opens_line"], QX["carried_over"],
                           list(lines = foldin_trace_lines_sql(EXEC_TABLES, "R000010", P),
                                eps = foldin_trace_episodes_sql(EXEC_TABLES, "R000010"))), V, ROOT)
  CV <- return_trace_stack(rv[c("opens_line", "carried_over")])
  ok(nrow(CV) == 1L && CV$KIND == "opens_line" && CV$OPEN_VIA == "melp_course" &&
       CV$MED_ABBR == "MELP" && CV$LOT_NUM == 2L && CV$RETURN_LINE == 1L,
     "a short melphalan course of the previous line's regimen that 4.7 confirmed is a line-opening return, not a carried-over backbone")
  nv <- return_trace_narrative(CV[1, , drop = FALSE], rv$lines, rv$eps, P, all_rows = CV)
  ok(has(nv, "confirmed by DARA") && has(nv, "the one agent 4.3 exempts"),
     "...and its paragraph names the agent that confirmed it and the exemption it rests on")
  V2 <- list(final = list(
      rf_fin("R000011", 1L, "2020-01-01", "MED", "BORT LEN", "2020-06-30", "MED_ADD", add_med = "CARF", add_dt = "2020-07-01"),
      rf_fin("R000011", 2L, "2020-07-01", "MED", "CARF", "2021-01-31", "MED_ADD", add_med = "POM", add_dt = "2021-02-01"),
      rf_fin("R000011", 3L, "2021-02-01", "MED", "POM", "2021-08-24", "MED_ADD", add_med = "MELP", add_dt = "2021-08-25"),
      rf_fin("R000011", 4L, "2021-08-25", "MED", "LEN MELP", "2022-03-31")),
    map = list(rf_ep("R000011", "BORT", "2020-01-01", "2020-05-31", discon = 1L, cnt = 5L),
               rf_ep("R000011", "LEN", "2020-01-01", "2020-04-30", discon = 1L, cnt = 4L),
               rf_ep("R000011", "CARF", "2020-07-01", "2020-12-31", discon = 1L, cnt = 6L),
               rf_ep("R000011", "POM", "2021-02-01", "2021-07-31", discon = 1L, cnt = 6L),
               rf_ep("R000011", "MELP", "2021-08-25", "2021-09-21", cnt = 1L),
               rf_ep("R000011", "LEN", "2021-09-01", "2022-03-31", cnt = 7L)),
    allo = list(), auto = list(), subs = list())
  rv <- returns_run_rows(c(QX["opens_line"],
                           list(lines = foldin_trace_lines_sql(EXEC_TABLES, "R000011", P),
                                eps = foldin_trace_episodes_sql(EXEC_TABLES, "R000011"))), V2, ROOT)
  CV <- return_trace_stack(rv["opens_line"])
  CV <- CV[CV$PATID == "R000011", , drop = FALSE]
  ok(nrow(CV) == 1L && CV$OPEN_VIA == "melp_confirmed" && CV$MED_ABBR == "LEN" &&
       format(CV$RETURN_DT) == "2021-09-01" && CV$LOT_NUM == 4L,
     "a drug two lines back that arrived while a short course still covered is a line-opening return dated at its own episode, not at the line's start")
  nv <- return_trace_narrative(CV[1, , drop = FALSE], rv$lines, rv$eps, P, all_rows = CV)
  ok(has(nv, "while a melphalan course that started on 2021-08-25 was still covering") &&
       has(nv, "28 days or fewer, which is 4.7's short one") &&
       has(nv, "on the MELPHALAN's date rather than the agent's") &&
       has(nv, "the melphalan opened LOT 4") && !has(nv, "LEN opened LOT 4"),
     "...and its paragraph names the cap the run recorded and credits the melphalan with opening the line, never the returning drug")
  # A LONG melphalan course is melphalan behaving as any other agent: 4.7 is
  # about a course of melp_simple_course_days or fewer, and reading a 59-day
  # one as the rule's put the rule's name on a line it never touched, and
  # called an ordinary window join a line-opening return.
  VLONG <- list(final = list(
      rf_fin("R000012", 1L, "2020-01-01", "MED", "BORT LEN", "2020-06-30", "MED_ADD", add_med = "CARF", add_dt = "2020-07-01"),
      rf_fin("R000012", 2L, "2020-07-01", "MED", "CARF", "2020-12-31", "MED_ADD", add_med = "MELP", add_dt = "2021-01-01"),
      rf_fin("R000012", 3L, "2021-01-01", "MED", "MELP BORT", "2021-08-31")),
    map = list(rf_ep("R000012", "BORT", "2020-01-01", "2020-05-31", discon = 1L, cnt = 5L),
               rf_ep("R000012", "LEN", "2020-01-01", "2020-04-30", discon = 1L, cnt = 4L),
               rf_ep("R000012", "CARF", "2020-07-01", "2020-12-31", discon = 1L, cnt = 6L),
               rf_ep("R000012", "MELP", "2021-01-01", "2021-02-28", cnt = 2L),
               rf_ep("R000012", "BORT", "2021-01-10", "2021-08-31", cnt = 8L)),
    allo = list(), auto = list(), subs = list())
  r <- returns_run_rows(QX["opens_line"], VLONG, ROOT)$opens_line
  ok(is.null(err(r)) && !any(r$PATID == "R000012"),
     "a 59-day melphalan course is not 4.7's short one, so the drug that arrived inside it is no line-opening return")
  rc <- returns_run_rows(QX["carried_over"], VLONG, ROOT)$carried_over
  ok(is.null(err(rc)) && !any(rc$PATID == "R000012"),
     "...and it is not carried over either: LOT 2 did not hold BORT, so nothing here is a return the rules decided")
  # ...and a course inside the cap, but which the drug arrived AFTER, is not
  # 4.7's either: the confirming agent starts while the course still covers.
  # The date has to sit INSIDE the line's induction window and OUTSIDE the
  # course - the course runs to 2021-09-21, the window runs past it - or the
  # row would be missing because the window never admitted it and the test
  # would say nothing about the cover bound, which is what it is here to test.
  w4 <- rv$lines[as.integer(rv$lines$LOT_NUM) == 4L, , drop = FALSE]
  ok(nrow(w4) == 1L && as.Date("2021-09-22") > as.Date("2021-09-21") &&
       as.Date("2021-09-22") <= as.Date(as.character(w4$ELIGIBLE_END[1])),
     "the late arrival below is inside LOT 4's induction window and past the course's last day, so what it tests is the cover and not the window")
  VLATE <- V2
  VLATE$map[[6]] <- rf_ep("R000011", "LEN", "2021-09-22", "2022-03-31", cnt = 7L)
  r <- returns_run_rows(QX["opens_line"], VLATE, ROOT)$opens_line
  ok(is.null(err(r)) && !any(r$PATID == "R000011" & r$OPEN_VIA == "melp_confirmed"),
     "a drug arriving after the short course stopped covering did not confirm it, and is not reported as having")
  # 4.7 chains BEFORE it measures: doses closer together than
  # melp_exposure_days are one course, and the cover is the latest supply end
  # over all of it (engine/R/melp_rule.R). Two episodes 20 days apart are one
  # 55-day course - not 4.7's short one - though the first episode alone is 28
  # days and would clear the cap on its own.
  VCHAIN <- V2
  VCHAIN$map[[5]] <- rf_ep("R000011", "MELP", "2021-08-25", "2021-09-21", cnt = 1L)
  VCHAIN$map[[length(VCHAIN$map) + 1L]] <-
    rf_ep("R000011", "MELP", "2021-09-14", "2021-10-18", cnt = 1L)
  r <- returns_run_rows(QX["opens_line"], VCHAIN, ROOT)$opens_line
  ok(is.null(err(r)) && !any(r$PATID == "R000011" & r$OPEN_VIA == "melp_confirmed"),
     "two melphalan doses inside the exposure distance are ONE course, so a 55-day one is not 4.7's short course and confirms nothing - the opening episode's own 28 days do not decide it")
  # ...and a dose BEYOND the exposure distance starts a second course, so the
  # first is still the short one it was.
  VSPLIT <- V2
  VSPLIT$map[[length(VSPLIT$map) + 1L]] <-
    rf_ep("R000011", "MELP", "2021-10-25", "2021-11-21", cnt = 1L)
  r <- returns_run_rows(QX["opens_line"], VSPLIT, ROOT)$opens_line
  ok(is.null(err(r)) && sum(r$PATID == "R000011" & r$OPEN_VIA == "melp_confirmed") == 1L,
     "...while a later dose past that distance is a course of its own and leaves the first one short")

  # The arm, not a bare name: a CTE or a comment can carry the word, and a
  # test that matched one would pass on a query that emits no such row.
  arm <- function(pp, via) has(return_trace_opens_sql(EXEC_TABLES, pp),
                              paste0("'", via, "' AS OPEN_VIA"))
  Pnd <- P; Pnd$melp_days <- NA
  ok(!arm(Pnd, "melp_confirmed") && arm(Pnd, "melp_course"),
     "a run that recorded no course cap gets no melp_confirmed row at all - the claim has no evidence behind it - while the exemption arm, which needs no length, stands")
  Pne <- P; Pne$melp_expo <- NA
  ok(!arm(Pne, "melp_confirmed") && arm(Pne, "melp_course"),
     "...and neither does one that recorded no exposure distance: without it there is no chained course for the cap to measure")
  Poff <- P; Poff$melp_rule <- "off"
  ok(!arm(Poff, "melp_course") && !arm(Poff, "melp_confirmed") && arm(P, "melp_course"),
     "...and neither melphalan arm is emitted for a run that did not apply the melphalan rule")
  ok(has(nv, "What these tables cannot show is whether 4.7 was the rule that acted") &&
       !has(nv, "confirmed it,"),
     "...and its paragraph says what the published tables cannot settle rather than asserting the rule acted")

  # LOT 5 is the last line the engine builds, so the older reading had no next
  # line to open.
  V <- variant(function(d) {
    d$final[[3]]$LOT_NUM <- 5L; d })
  rv <- returns_run_rows(c(QX["own_return"],
                           list(lines = foldin_trace_lines_sql(EXEC_TABLES, "R000002", P),
                                eps = foldin_trace_episodes_sql(EXEC_TABLES, "R000002"))), V, ROOT)
  CV <- return_trace_stack(rv["own_return"])
  if (nrow(CV)) {
    nv <- return_trace_narrative(CV[1, , drop = FALSE], rv$lines, rv$eps, P, all_rows = CV)
    ok(has(nv, "is the last line the engine builds (max_lot 5)") && has(nv, "no line at all"),
       "an own return inside the top line says the older reading would have left it in no line")
  } else ok(FALSE, "an own return inside the top line is still a return")

  cat("\n-- scope, sample and summary, on the executed rows --\n")
  S2 <- return_trace_in_scope(C, RETURN_TRACE_KINDS, 2L)
  ok(setequal(key(S2), c("R000001 fold 2 LEN", "R000003 own_return 2 POM", "R000004 opens_line 3 LEN")),
     "return line 2 is: the fold into LOT 2, the own return inside LOT 2, and the return after LOT 2 that opened LOT 3")
  S1 <- return_trace_in_scope(C, RETURN_TRACE_KINDS, 1L)
  ok(setequal(key(S1), c("R000002 own_return 1 LEN", "R000007 opens_line 2 MELP")),
     "return line 1 is the own return inside LOT 1 - the one that would have made a 2L before the rule - and the melphalan course that opened LOT 2 after it")
  ok(nrow(return_trace_in_scope(C, "fold", NULL)) == 1L && nrow(return_trace_in_scope(C, RETURN_TRACE_KINDS, NULL)) == 7L,
     "the kinds filter narrows to a kind; no line filter keeps every return line; carried_over is never in scope")
  ids <- return_trace_sample(C, 12L)
  ok(identical(ids, c("R000001", "R000002", "R000003", "R000007", "R000004", "R000005", "R000008")),
     "the sample takes one patient per (kind, line, drug) round-robin, kinds in the report's order, and is deterministic")
  ok(identical(return_trace_sample(C, 2L), c("R000001", "R000002")), "...and TRACE_N cuts it")
  ok(identical(return_trace_sample(C, 12L, patids = c("R000006", "R000001")), c("R000006", "R000001")),
     "...while a listed set bypasses it, in the listed order")
  ok(!"R000006" %in% ids, "...and the carried-over patient, with nothing to trace, is never sampled")
  sm <- return_trace_summary(C, 8, 20)
  gs <- function(kind, level, k = "") sm[sm$kind == kind & sm$level == level & sm$key == k, , drop = FALSE]
  ok(gs("LOT_LONG_FINAL", "all lines")$n_patients == 8 && gs("LOT_LONG_FINAL", "all lines")$n_lines == 20,
     "the summary carries the table's own totals")
  ok(gs("own_return", "all")$n_returns == 2 && gs("own_return", "by return line", "LOT1")$n_patients == 1 &&
       gs("opens_line", "all")$n_returns == 4 && gs("opens_line", "by return line", "LOT3")$n_returns == 2 &&
       gs("opens_line", "by drug", "MELP")$n_returns == 1 && gs("carried_over", "all")$n_returns == 1,
     "...and counts every kind by line and by drug, carried_over included")
  ok(identical(unique(sm$kind[-1]), RETURN_TRACE_ALL_KINDS), "...in the report's order")
  ok(gs("opens_line", "by open path", "new_agent")$n_returns == 2 &&
       gs("opens_line", "by open path", "melp_course")$n_returns == 1 &&
       gs("opens_line", "by open path", "melp_confirmed")$n_returns == 1 &&
       sum(sm$level == "by open path") == 3L &&
       sum(sm$n_returns[sm$level == "by open path"]) == gs("opens_line", "all")$n_returns,
     "...and opens_line is split by the arm that opened the line, so one total does not read as one rule")
  ok(!any(sm$level == "by open path" & sm$kind != "opens_line"),
     "...a split only opens_line has, since no other kind records a path")

  cat("\n-- annotation and narrative --\n")
  ids_all <- unique(C$PATID)
  rp <- returns_run_rows(list(lines = foldin_trace_lines_sql(EXEC_TABLES, ids_all, P),
                              eps = foldin_trace_episodes_sql(EXEC_TABLES, ids_all),
                              tx = foldin_trace_tx_sql(EXEC_TABLES, ids_all),
                              subs = foldin_trace_subs_sql(EXEC_TABLES)), RETURNS_FIXTURE, ROOT)
  ann <- return_trace_annotate(rp$lines, rp$eps, rp$tx, C, P, subs = rp$subs)
  note_of <- function(pat, med, dt) ann$note[ann$PATID == pat & ann$MAP_MED_TYPE == med & format(ann$MAP_START_DT) == dt]
  ok(identical(note_of("R000001", "LEN", "2020-08-15"), "FOLDED into LOT 2 (4.8)"),
     "the folded episode carries the fold-in trace's own note")
  ok(identical(note_of("R000002", "LEN", "2020-11-30"), "RETURNED to LOT 1 after a 214-day break (4.3)") &&
       identical(note_of("R000002", "LEN", "2020-01-01"), "break follows: 214 days to the return"),
     "an own return marks the return and the episode before the break, with the gap in days")
  # An episode can be both: the drug came back, ran out, and came back again
  # inside the same line, so the middle course is one row's return and the next
  # row's break. Both notes belong on it - either alone loses a return.
  TWICE <- list(final = list(
      rf_fin("R000013", 1L, "2020-01-01", "MED", "LEN", "2021-12-31", "DISCONTINUATION",
             discon = "2021-12-31")),
    map = list(rf_ep("R000013", "LEN", "2020-01-01", "2020-02-29", discon = 1L, cnt = 2L),
               rf_ep("R000013", "LEN", "2020-08-01", "2020-09-30", discon = 1L, cnt = 2L),
               rf_ep("R000013", "LEN", "2021-03-01", "2021-12-31", cnt = 10L)),
    allo = list(), auto = list(), subs = list())
  rt <- returns_run_rows(c(QX["own_return"],
                           list(lines = foldin_trace_lines_sql(EXEC_TABLES, "R000013", P),
                                eps = foldin_trace_episodes_sql(EXEC_TABLES, "R000013"))), TWICE, ROOT)
  CT <- return_trace_stack(rt["own_return"])
  ok(nrow(CT) == 2L && all(CT$LOT_NUM == 1L) &&
       identical(sort(format(CT$RETURN_DT)), c("2020-08-01", "2021-03-01")),
     "a drug that comes back twice inside one line is two own returns, both on that line")
  at <- return_trace_annotate(rt$lines, rt$eps, NULL, CT, P)
  mid <- at$note[at$MAP_MED_TYPE == "LEN" & format(at$MAP_START_DT) == "2020-08-01"]
  ok(identical(mid, "RETURNED to LOT 1 after a 154-day break (4.3); break follows: 152 days to the return"),
     "...and the middle episode keeps both notes - its own return and the break that follows it")
  ok(identical(at$note[at$MAP_MED_TYPE == "LEN" & format(at$MAP_START_DT) == "2020-01-01"],
               "break follows: 154 days to the return") &&
       identical(at$note[at$MAP_MED_TYPE == "LEN" & format(at$MAP_START_DT) == "2021-03-01"],
                 "RETURNED to LOT 1 after a 152-day break (4.3)"),
     "...while the episodes that are only one of the two carry only that one")
  at2 <- return_trace_annotate(rt$lines, rt$eps, NULL, CT[c(2L, 1L), , drop = FALSE], P)
  ok(identical(at2$note, at$note),
     "...and the notes do not depend on the order the rows arrived in")
  ok(identical(note_of("R000004", "LEN", "2020-12-01"), "opens LOT 3 - LOT 2 was opened by SCT_AUTO, so no fold across it"),
     "a return across a transplant-opened line says so on the episode that opened the next")
  ok(identical(note_of("R000005", "LEN", "2021-09-01"), "opens LOT 4 - back from LOT 1, out of 4.8's scope"),
     "...and one from two lines back names the line it came from")
  ok(identical(note_of("R000006", "LEN", "2020-07-10"), "induction"),
     "a carried-over drug's window episode is plain induction")
  ok(all(ann$note[ann$MAP_MED_CLASS == "STEROID"] == ""), "steroid episodes are shown and never marked")
  nar <- function(pat, kind) {
    r <- C[C$PATID == pat & C$KIND == kind, , drop = FALSE][1, , drop = FALSE]
    return_trace_narrative(r, rp$lines, rp$eps, P, tx = rp$tx, subs = rp$subs, all_rows = C[C$PATID == pat, , drop = FALSE])
  }
  n2 <- nar("R000002", "own_return")
  ok(has(n2, "LEN is in LOT 1's own regimen (LEN)") && has(n2, "break of 214 days") &&
       has(n2, "came back on 2020-11-30, 334 days after LOT 1 opened") && has(n2, "Under 4.3") &&
       has(n2, "LOT 1 is 2020-01-01 to 2021-03-31 (DISCONTINUATION)"),
     "an own return's paragraph: the drug, the break, the return, and the line running on over it")
  ok(has(n2, "Before 30 Aug 2026 the break released the drug") && has(n2, "would have ended DISCONTINUATION on 2020-04-30") &&
       has(n2, "next line would have started on 2020-11-30 with LEN"),
     "...and what the reading before the rule made of it: a run-out confirmed, then a new line on the return")
  n3 <- nar("R000003", "own_return")
  ok(has(n3, "POM is in LOT 2's own regimen (POM)") && has(n3, "outside the window (window ended 2020-09-30)"),
     "an own return inside 2L reads the later-line window")
  n4 <- nar("R000004", "opens_line")
  ok(has(n4, "LEN was last in LOT 1's regimen (BORT LEN)") && has(n4, "LOT 2 was opened by a transplant or CAR-T (SCT_AUTO)") &&
       has(n4, "4.8 refuses a fold across a procedure") &&
       has(n4, "It was an added medication: LOT 2 ended MED_ADD on 2020-11-30, and LEN opened LOT 3 (LEN).") &&
       has(n4, "changed nothing here"),
     "a return across a transplant-opened line: the refusal, the added medication read off LOT 2's own end reason, and that the rules changed nothing")
  n5 <- nar("R000005", "opens_line")
  ok(has(n5, "LOT 3 (POM) did not carry it") && has(n5, "immediately previous line's regimen only") &&
       has(n5, "it was a new agent like any other") && has(n5, "LOT 3 ended MED_ADD on 2021-08-31"),
     "a return from two lines back: out of 4.8's scope, opened a line")
  n1 <- nar("R000001", "fold")
  ok(has(n1, "under 4.8 it joined LOT 2's regimen (CARF LEN)") && has(n1, "would have ended MED_ADD on 2020-08-14"),
     "a fold's paragraph is the fold-in trace's own")
  # Two returns in one patient: only the earliest carries the pre-rule reading.
  V <- variant(function(d) {
    d$map[[9]]$MAP_END_DT <- "2021-01-31"; d$map[[9]]$MAP_DISCON_FLG <- 1L
    d$final[[3]]$LOT_BASE_END_DT <- "2021-12-31"; d$final[[3]]$LOT_BASE_DISCON_DT <- "2021-12-31"
    d$map[[length(d$map) + 1L]] <- rf_ep("R000002", "LEN", "2021-06-01", "2021-12-31", discon = 1L, cnt = 7L)
    d })
  rv <- returns_run_rows(c(QX["own_return"], list(lines = foldin_trace_lines_sql(EXEC_TABLES, "R000002", P),
                                                 eps = foldin_trace_episodes_sql(EXEC_TABLES, "R000002"))), V, ROOT)
  CV <- return_trace_stack(rv["own_return"])
  second <- CV[CV$PATID == "R000002" & format(CV$RETURN_DT) == "2021-06-01", , drop = FALSE]
  ns <- return_trace_narrative(second, rv$lines, rv$eps, P, all_rows = CV)
  ok(has(ns, "cannot be read from these tables alone") && has(ns, "earlier return on 2020-11-30"),
     "a patient's second return carries no local pre-rule reading, and names the first")

  cat("\n-- rendering, and the committed example --\n")
  r <- returns_render_fixture(RETURNS_FIXTURE, RETURNS_FIXTURE_TOTALS, P, ROOT, run_id = "run-abc",
                              pfx = "t_", n = 12L)
  md <- r$md
  ok(md[1] == "# Returning-drug trace - prefix `t_`" && any(has(md, "Run `run-abc`")),
     "the report names the run and the prefix, the prefix quoted so its trailing underscore does not read as a typo")
  ok(sum(grepl("^## Patient ", md)) == 7L && !any(has(md, "## Patient R000006")),
     "one section per traced patient, the carried-over patient not among them")
  ok(any(has(md, "**Came back and opened a line (outside 4.8) - MELP, LOT 2.**")) &&
       any(has(md, "**Came back and opened a line (outside 4.8) - LEN, LOT 4.**")),
     "...and every shape the trace tells apart has a worked patient, the two melphalan ones included")
  ok(any(has(md, "**Folded into the line it returned in (4.8) - LEN, LOT 2.**")) &&
       any(has(md, "**Came back to its own line after a break (4.3) - LEN, LOT 1.**")) &&
       any(has(md, "**Came back and opened a line (outside 4.8) - LEN, LOT 3.**")),
     "each paragraph is headed by its kind, drug and line")
  ok(any(has(md, "| carried_over | all |  | 1 | 1 | 1 |")), "the summary counts the carried-over drug")
  ok(any(has(md, "Patient ids are NOT masked")), "the report says the ids are unmasked")
  r_masked <- return_trace_patient_md(mask_patid_r("R000002"), C[C$PATID == "R000002", ], rp$lines[rp$lines$PATID == "R000002", ],
                                      rp$eps[rp$eps$PATID == "R000002", ], ann[ann$PATID == "R000002", ], P)
  ok(r_masked[1] == "## Patient ...000002", "a masked heading shows the last six characters")
  r_none <- return_trace_patient_md("R000006", C[C$PATID == "R000006", ], rp$lines[rp$lines$PATID == "R000006", ],
                                    rp$eps[rp$eps$PATID == "R000006", ], ann[ann$PATID == "R000006", ], P)
  ok(any(has(r_none, "No returning drug found for this patient")) && any(has(r_none, "Lines (LOT_LONG_FINAL):")),
     "a listed patient with no return says so and still shows its lines and episodes")
  r_missing <- return_trace_patient_md("NOBODY", NULL, NULL, NULL, NULL, P)
  ok(any(has(r_missing, "no line in LOT_LONG_FINAL")), "an id with no line at all is reported as one to check")
  # The example the study team reads is exactly a fresh render of the fixture.
  ex_path <- file.path(ROOT, "examples", "returns_trace_example.md")
  ex_env <- new.env(); ex_env$.script_dir <- ROOT
  old_opt <- options(returns.example.norun = TRUE)
  sys.source(file.path(ROOT, "trace_returns_example.R"), envir = ex_env)
  options(old_opt)
  fresh <- tryCatch(ex_env$returns_example_md(ROOT), error = function(e) e)
  ok(file.exists(ex_path) && !inherits(fresh, "error") && !is.null(fresh) && !identical(fresh, "skip") &&
       identical(readLines(ex_path, warn = FALSE), fresh$md),
     "examples/returns_trace_example.md is a fresh render of the fixture, line for line")
}

cat("\n-- the runner --\n")
src <- paste(readLines(file.path(ROOT, "trace_returns.R"), warn = FALSE), collapse = "\n")
RT_SRC <- paste(readLines(file.path(ROOT, "R", "return_trace.R"), warn = FALSE), collapse = "\n")
ok(has(src, 'Sys.getenv("TRACE_LINES", unset = "1,2")'),
   "TRACE_LINES defaults to 1,2 - the 2L question, with the own returns inside 1L that used to make a 2L")
ok(has(src, 'Sys.getenv("TRACE_N", unset = "12")'), "TRACE_N defaults to 12")
ok(has(src, "if (!isTRUE(p$foldin) || !isTRUE(p$own_return_fold))") && has(src, "there is nothing to trace"),
   "a run without both returning-drug rules is refused: the signatures would be defects, not the rules")
ok(has(src, "p <- return_trace_params(settings, run_id)") &&
     has(RT_SRC, 'p$gap <- qc_int(settings, "map_discon_gap_days")'),
   "the break length is read off the run's own recorded settings, not config.csv")
ok(has(src, "foldin_trace_build_pin(status_row())") && has(src, "changed while its tables were being"),
   "the build is pinned before the reads and compared after them, before anything is written")
ok(all(vapply(c("returns_trace.md", "returns_trace_candidates.csv", "returns_trace_lines.csv",
                "returns_trace_episodes.csv", "returns_trace_summary.csv"),
              function(f) has(src, f), logical(1))),
   "it writes the report and the four CSVs beside it")
ok(has(src, "cands_out$PATID <- mask_patid_r(cands_out$PATID)"),
   "...and masks the candidate list too when asked, not only the traced patients")
ok(!has(src, "DELETE") && !has(src, "INSERT") && !has(src, "CREATE"), "it reads only")

cat(sprintf("\n%d passed, %d failed\n", pass, fail))
if (fail > 0L) quit(status = 1L)
