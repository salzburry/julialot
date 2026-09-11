#!/usr/bin/env Rscript
# The fold-in trace, checked without a warehouse.
#
#   Rscript "lot/qc/tests/test_foldin_trace.R"
#
# Three kinds of test. The SQL as text: which tables it reads, which columns
# it joins on, that an id with a quote in it is refused. The SQL RUN, through
# DuckDB, against fixtures that differ from each other in one thing each - a
# return inside the window, a drug from two lines back, a substitute, a CAR-T
# window, a return after the line ended - so a wrong predicate is caught by
# the fixture built to catch it. And the R that samples, summarises, annotates
# and renders, on frames small enough to work out by hand.

ROOT <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                                 fixed = TRUE))) else getwd()
  dirname(d)
})

pass <- 0L; fail <- 0L
ok <- function(cond, what) {
  # Evaluated HERE, so an assertion whose expression raises is a failed
  # assertion rather than a dead run.
  cond <- tryCatch(cond, error = function(e) {
    what <<- paste0(what, "  [raised: ", conditionMessage(e), "]")
    FALSE
  })
  if (isTRUE(cond)) { pass <<- pass + 1L; cat("  ok     ", what, "\n") }
  else              { fail <<- fail + 1L; cat("  FAIL   ", what, "\n") }
}
stops <- function(expr, what) ok(inherits(tryCatch(expr, error = function(e) e), "error"), what)
has   <- function(x, s) grepl(s, x, fixed = TRUE)

source(file.path(ROOT, "R", "checks.R"))
source(file.path(ROOT, "R", "foldin_trace.R"))

# The same fake names test_lot_qc.R uses: none is a substring of another, so
# "reads this table" means what it says.
TBL <- list(final = "s.TFINAL", long = "s.TLONG", map = "s.TMAP",
            sct = "s.TSCT", auto = "s.TAUTO", allo = "s.TALLOCART",
            attrition = "s.TATTR", meta = "s.TMETA",
            cohort = "s.TCOHORT", subs = "s.TSUBS")
SETTINGS <- paste0(
  "allo_lot_span=single_day|apply_cart_induction_rule=TRUE|",
  "belantamab_med_abbr=BELA|cart_consolidation_days=45|",
  "catalog=hive_metastore|cdm_schema=clnprw_optum|censor_at_disenrollment=FALSE|",
  "codelist_dir=/mnt/code/codelist|dsn=RWDE|induction_window_days=60|",
  "lot_discon_confirm_days=90|lot_n_induction_window_days=30|",
  "map_discon_gap_days=90|max_lot=5|",
  "medical_day_supply=28|melp_exposure_days=30|",
  "melp_med_abbr=MELP|",
  "sct_auto_gap_days=60|sct_auto_window_days=13|sct_tandem_days=180|",
  "tbl_med_diag=med_diagnosis|tbl_med_proc=med_procedure|tbl_medical=medical|",
  "tbl_rx=rx|use_quarterly_tables=TRUE|apply_melp_rule=simplified|",
  "apply_map_foldin=TRUE|apply_own_return_fold=TRUE|",
  "cohort_status_table=")
P <- qc_params(SETTINGS, "run-abc")
SQL <- foldin_trace_sql(TBL, P)
IDS <- c("P000001", "P000002")

cat("\n-- the candidate query reads the fold's signature and nothing else --\n")
ok(has(SQL, "s.TFINAL") && has(SQL, "s.TMAP") && has(SQL, "s.TALLOCART") && has(SQL, "s.TSUBS"),
   "it reads the published lines, the episodes, the ALLO/CAR-T dates and the substitute pairs")
others <- c("s.TLONG", "s.TSCT", "s.TAUTO", "s.TATTR", "s.TMETA", "s.TCOHORT")
ok(!any(vapply(others, function(x) has(SQL, x), logical(1))),
   "...and no other table: not LOT_LONG, the SCT tables, the funnel, the metadata or the cohort")
ok(has(SQL, "MAP_MED_TYPE = w.MED_ABBR"),
   "the episode table is joined on MAP_MED_TYPE, the persisted drug column")
ok(!has(SQL, "MAP_MED_ABBR") && !grepl("ms2?[.]MED_ABBR", SQL),
   "...never on MED_ABBR or MAP_MED_ABBR, which the persisted table does not carry")
ok(has(SQL, "ELIGIBLE_END") && has(SQL, "LOT_BASE_END_DT"),
   "it reads the window end AND the line end - the fold sits between the two")
ok(has(SQL, "MAP_START_DT >  w.ELIGIBLE_END") && has(SQL, "MAP_START_DT <= w.LOT_BASE_END_DT"),
   "...the return after the window and on or before the line's end")
ok(has(SQL, "NOT EXISTS") && has(SQL, "ms2.MAP_START_DT <= w.ELIGIBLE_END"),
   "...and no episode of the drug inside the window")
ok(has(SQL, "s.substitute_med = w.MED_ABBR") && has(SQL, "s.original_med = w.MED_ABBR"),
   "both alias directions: the drug a substitute stands for, and the substitutes of a drug")
ok(has(SQL, "pl.LOT_NUM = a.LOT_NUM - 1"),
   "the previous line is the IMMEDIATELY previous one (4.8's scope)")
ok(has(SQL, "cast(ms.PATID as string)") && has(SQL, "cast(pl.PATID as string)") &&
     has(SQL, "cast(ms2.PATID as string)"),
   "PATID is cast to string in every join, as C1 does, because the warehouse may store it numeric")
ok(has(SQL, "qc_window_sql") == FALSE && has(SQL, "cut AS (") && has(SQL, "reg AS ("),
   "the window comes from qc_window_sql() in R/checks.R - its CTEs are in the statement")
ok(!has(SQL, "concat('...'"), "the candidate query masks nothing; masking is the runner's, in R")
ok(has(SQL, "min(ms.MAP_START_DT) AS RETURN_DT"), "RETURN_DT is the FIRST dose past the window")
ok(has(SQL, "w.LOT_START_TYPE,") && grepl("GROUP BY[^;]*w.LOT_START_TYPE", SQL),
   "the row carries LOT_START_TYPE, so a signature on a line a procedure opened can be told apart")
ok(has(foldin_trace_subs_sql(TBL), "s.TSUBS") && has(foldin_trace_subs_sql(TBL), "original_med"),
   "the substitute pairs are read for the R side, from the same table")

cat("\n-- the per-patient reads --\n")
L <- foldin_trace_lines_sql(TBL, IDS, P)
E <- foldin_trace_episodes_sql(TBL, IDS)
X <- foldin_trace_tx_sql(TBL, IDS)
ok(has(L, "s.TFINAL") && has(L, "IN ('P000001', 'P000002')") && has(L, "ELIGIBLE_END"),
   "the lines read carries the window end, off qc_window_sql(), for the ids given")
ok(has(E, "s.TMAP") && has(E, "MAP_MED_TYPE") && has(E, "MAP_MED_CLASS") && has(E, "MAP_CNT") &&
     !has(E, "MED_ABBR"),
   "the episodes read takes MAP_MED_TYPE and MAP_MED_CLASS, never MED_ABBR")
ok(has(X, "s.TAUTO") && has(X, "s.TALLOCART") && has(X, "'SCT_AUTO'") &&
     has(X, "'SCT_ALLO'") && has(X, "'CART'"),
   "the transplant read unions both tables under the names LOT_START_TYPE uses")
stops(foldin_trace_in_list("P1'; DROP"), "an id with a quote in it is refused, not escaped")
stops(foldin_trace_lines_sql(TBL, c("P000001", "P1'; DROP"), P), "...in the lines read")
stops(foldin_trace_episodes_sql(TBL, "P1 OR 1=1"), "...in the episodes read")
stops(foldin_trace_tx_sql(TBL, "P1;--"), "...and in the transplant read")
stops(foldin_trace_in_list(character(0)), "an empty id list is refused rather than sent as IN ()")
ok(identical(foldin_trace_in_list(c("A1", "A1", " B-2 ")), "('A1', 'B-2')"),
   "ids are trimmed and de-duplicated on the way in")

cat("\n-- the runner --\n")
RUNNER <- paste(readLines(file.path(ROOT, "trace_foldin.R")), collapse = "\n")
ok(regexpr("env_flag(\"TRACE_EXECUTE\")", RUNNER, fixed = TRUE) <
     regexpr("library(DBI)", RUNNER, fixed = TRUE),
   "the TRACE_EXECUTE gate comes before library(DBI), so the plan prints where DBI is absent")
ok(!has(RUNNER, "INPUT_COHORT_TABLE"), "the cohort table is not asked for - nothing here reads it")
ok(!has(RUNNER, "Sys.getenv(\"DATABRICKS_PWD\""),
   "the password is read only through cfg$pwd, never by the runner itself")
ok(has(RUNNER, "apply_map_foldin") && has(RUNNER, "nothing to trace"),
   "a run without the fold-in is refused with a message naming apply_map_foldin")
ok(has(RUNNER, "ORDER BY UPDATED_AT DESC LIMIT 1") && has(RUNNER, "identical(status, \"complete\")"),
   "run ownership is the latest status row, and it has to be complete")
ok(has(RUNNER, "QC_ALLOW_DEVIATION"), "a deviating run needs QC_ALLOW_DEVIATION, as QC does")
ok(has(RUNNER, "TRACE_MASK_PATID") && has(RUNNER, "TRACE_PATIDS") && has(RUNNER, "TRACE_N"),
   "the three knobs are read")
ok(all(vapply(c("foldin_trace.md", "foldin_trace_lines.csv", "foldin_trace_episodes.csv",
                "foldin_trace_summary.csv"), function(f) has(RUNNER, f), logical(1))),
   "it writes the four files the documentation names")
ok(has(RUNNER, "options(scipen = 999)") && regexpr("options(scipen = 999)", RUNNER, fixed = TRUE) >
     regexpr("env_flag(\"TRACE_EXECUTE\")", RUNNER, fixed = TRUE),
   "counts are never printed in scientific notation: scipen is set once the run is on")
ok(has(RUNNER, "foldin_trace_subs_sql(t)") && has(RUNNER, "subs = subs"),
   "the substitute pairs are read and handed to the renderer")
ok(has(RUNNER, "TRACE_PATIDS refused") && has(RUNNER, "TRACE_N refused"),
   "a refused list or count is printed in the plan, not swallowed")
# The plan itself, run: a bad list is named and the exit is still 0.
plan <- suppressWarnings(system2("Rscript", shQuote(file.path(ROOT, "trace_foldin.R")),
                                 env = c(paste0("TRACE_PATIDS=", shQuote("P1'x")), "TRACE_N=x", "TRACE_EXECUTE="),
                                 stdout = TRUE, stderr = TRUE))
ok(any(has(plan, "TRACE_PATIDS refused")) && any(has(plan, "TRACE_N refused")) &&
     any(has(plan, "Nothing was read")) && is.null(attr(plan, "status")),
   "...and the dry run says which knob it would refuse, then exits 0 without reading")

cat("\n-- the sample --\n")
CANDS <- data.frame(
  PATID    = c("P3", "P1", "P2", "P5", "P4", "P1"),
  LOT_NUM  = c(2L, 2L, 2L, 2L, 3L, 3L),
  MED_ABBR = c("LEN", "LEN", "LEN", "BORT", "LEN", "POM"),
  stringsAsFactors = FALSE)
# Groups in order: (2,BORT)=P5; (2,LEN)=P1,P2,P3; (3,LEN)=P4; (3,POM)=P1.
# Rank 1 of each: P5, P1, P4, P1 again (taken once). Then rank 2: P2. Then P3.
ok(identical(foldin_trace_sample(CANDS, 4), c("P5", "P1", "P4", "P2")),
   "round-robin: rank 1 of every (line, drug) group first, then rank 2")
ok(identical(foldin_trace_sample(CANDS, 10), c("P5", "P1", "P4", "P2", "P3")),
   "...a patient in two groups is taken once, and n above the count gives everyone")
ok(identical(foldin_trace_sample(CANDS[sample(nrow(CANDS)), ], 4), c("P5", "P1", "P4", "P2")),
   "...and the order the candidates arrive in changes nothing")
ok(identical(foldin_trace_sample(CANDS, 1), "P5"), "n = 1 gives the first of the first group")
ok(identical(foldin_trace_sample(CANDS, 3, c("P2", "P9")), c("P2", "P9")),
   "TRACE_PATIDS restricts to the listed ids, in the order listed, whether or not they fold")
stops(foldin_trace_sample(CANDS, 3, "P2'; DROP"), "...and a listed id is validated too")
stops(foldin_trace_sample(CANDS, 0), "n = 0 is refused")
ok(identical(foldin_trace_sample(CANDS[0, ], 5), character(0)), "no candidates gives no sample")
MIXED <- data.frame(PATID = c("b", "B", "a", "A"), LOT_NUM = 2L, MED_ABBR = "LEN", stringsAsFactors = FALSE)
ok(identical(foldin_trace_sample(MIXED, 4), c("A", "B", "a", "b")),
   "ids are ordered byte-wise (radix), so the pick does not depend on the session locale")

cat("\n-- the summary --\n")
# One more fold on a line already counted, so lines and pairs come apart:
# P2 folds LEN and POM in the same LOT2.
CANDS2 <- rbind(CANDS, data.frame(PATID = "P2", LOT_NUM = 2L, MED_ABBR = "POM", stringsAsFactors = FALSE))
S <- foldin_trace_summary(CANDS2, 1000, 2600)
g <- function(level, key) S[S$level == level & S$key == key, ]
v <- function(r) unname(unlist(r[c("n_patients", "n_lines", "n_pairs")]))
ok(identical(v(g("folds", "all")), c(5, 6, 7)),
   "5 patients, 6 lines, 7 (line, drug) pairs: a line with two folds is one line and two pairs")
ok(identical(v(g("by LOT_NUM", "LOT2")), c(4, 4, 5)) && identical(v(g("by LOT_NUM", "LOT3")), c(2, 2, 2)),
   "by line: LOT2 4/4/5, LOT3 2/2/2")
ok(identical(v(g("by drug", "LEN")), c(4, 4, 4)) && identical(v(g("by drug", "POM")), c(2, 2, 2)) &&
     identical(unname(unlist(g("by drug", "BORT")$n_patients)), 1),
   "by drug: LEN 4/4/4, POM 2/2/2, BORT 1")
ok(identical(unname(unlist(g("LOT_LONG_FINAL", "all lines")[c("n_patients", "n_lines")])), c(1000, 2600)),
   "the table's own totals are beside them, for scale")
ok(identical(v(S[grepl("non-MED", S$level), ]), c(0, 0, 0)),
   "with no start type in the frame every row is a fold and the defect row is 0/0/0")
S0 <- foldin_trace_summary(CANDS[0, ], 10, 20)
g0 <- function(level, key) S0[S0$level == level & S0$key == key, ]
ok(nrow(S0) == 3 && identical(v(g0("folds", "all")), c(0, 0, 0)) &&
     identical(unname(unlist(g0("LOT_LONG_FINAL", "all lines")[c("n_patients", "n_lines")])), c(10, 20)),
   "no folds gives the three header rows with zero fold counts, not an error")
# A signature on a CAR-T-opened line is not a fold: kept out of the fold
# counts, counted on the defect row.
CANDS3 <- CANDS2; CANDS3$LOT_START_TYPE <- c("MED", "MED", "MED", "CART", "MED", "MED", "MED")
S3 <- foldin_trace_summary(CANDS3, 1000, 2600)
g3 <- function(level, key) S3[S3$level == level & S3$key == key, ]
ok(identical(v(g3("folds", "all")), c(4, 5, 6)) && identical(v(S3[grepl("non-MED", S3$level), ]), c(1, 1, 1)) &&
     nrow(g3("by drug", "BORT")) == 0 && identical(v(g3("by LOT_NUM", "LOT2")), c(3, 3, 4)),
   "a signature on a non-MED line leaves the fold counts (P5's BORT) and is counted as a defect")

cat("\n-- annotate --\n")
LINES <- data.frame(
  PATID = "P000001", LOT_NUM = 1:2,
  LOT_START_DT = as.Date(c("2020-01-01", "2020-07-01")),
  LOT_START_TYPE = c("MED", "MED"),
  LOT_BASE_MEDS = c("BORT LEN", "CARF LEN"), LOT_MED_CNT = c(2L, 2L),
  LOT_BASE_END_DT = as.Date(c("2020-06-28", "2020-12-31")),
  LOT_BASE_END_REASON = c("DISCONTINUATION", "STUDY_END"),
  LOT_BASE_LENGTH = c(180L, 184L), LOT_BASE_1ST_ADD_MED = NA_character_,
  LOT_BASE_1ST_ADD_MED_DT = as.Date(NA), LOT_BASE_DISCON_DT = as.Date(c("2020-06-28", NA)),
  LOT_TX_AUTO_MAX_DT = as.Date(NA),
  ELIGIBLE_END = as.Date(c("2020-02-29", "2020-07-30")), stringsAsFactors = FALSE)
epi <- function(med, start, end, class = "NOVEL") data.frame(
  PATID = "P000001", MAP_START_DT = as.Date(start), MAP_END_DT = as.Date(end),
  MAP_MED_RUNOUT_DT = as.Date(end), MAP_MED_TYPE = med, MAP_MED_CLASS = class,
  MAP_CNT = 1, MAP_DISCON_FLG = 0, stringsAsFactors = FALSE)
EPS <- rbind(epi("BORT", "2020-01-01", "2020-02-01"),
             epi("LEN",  "2020-01-05", "2020-02-05"),
             epi("DEX",  "2020-01-05", "2020-02-05", "STEROID"),
             epi("LEN",  "2020-04-01", "2020-05-01"),
             epi("CARF", "2020-07-01", "2020-08-01"),
             epi("DEX",  "2020-07-01", "2020-08-01", "STEROID"),
             epi("LEN",  "2020-08-15", "2020-09-15"),
             epi("DEX",  "2020-08-15", "2020-09-15", "STEROID"),
             epi("LEN",  "2020-10-15", "2020-11-15"),
             epi("BORT", "2020-02-29", "2020-03-29"),
             epi("LEN",  "2020-12-31", "2021-01-31"),
             epi("BORT", "2021-02-01", "2021-03-01"))
FOLDS <- data.frame(PATID = "P000001", LOT_NUM = 2L, MED_ABBR = "LEN",
                    LOT_START_DT = as.Date("2020-07-01"), ELIGIBLE_END = as.Date("2020-07-30"),
                    LOT_BASE_END_DT = as.Date("2020-12-31"), PREV_BASE_MEDS = "BORT LEN",
                    RETURN_DT = as.Date("2020-08-15"), stringsAsFactors = FALSE)
A <- foldin_trace_annotate(LINES, EPS, NULL, FOLDS, P)
note_at <- function(med, d) A$note[A$MAP_MED_TYPE == med & A$MAP_START_DT == as.Date(d)]
ok(identical(note_at("LEN", "2020-08-15"), "FOLDED into LOT 2 (4.8)"),
   "the returning LEN dose is marked FOLDED into LOT 2")
ok(identical(note_at("LEN", "2020-10-15"), "FOLDED into LOT 2 (4.8)"),
   "...and so is its later dose inside the same line")
ok(identical(note_at("LEN", "2020-12-31"), "FOLDED into LOT 2 (4.8)") &&
     identical(A$line[A$MAP_MED_TYPE == "LEN" & A$MAP_START_DT == as.Date("2020-12-31")], "2"),
   "...and a dose on the line's last day is inside the line and FOLDED, as the query counts it")
ok(sum(grepl("FOLDED", A$note)) == 3, "nothing else is marked FOLDED")
ok(identical(note_at("BORT", "2020-02-29"), "induction"),
   "a dose on the window's last day is inside the window: induction")
ok(identical(note_at("LEN", "2020-01-05"), "induction") && identical(note_at("LEN", "2020-04-01"), ""),
   "LEN in LOT1 is induction inside the window and blank after it - a fold only in the line it folded into")
ok(identical(note_at("CARF", "2020-07-01"), "opens LOT 2") && identical(note_at("BORT", "2020-01-01"), "opens LOT 1"),
   "the drug whose episode starts on a MED line's start date opens it")
ok(all(A$note[A$MAP_MED_CLASS == "STEROID"] == ""),
   "a steroid is shown and never marked, on the start date, in the window or on the fold date")
ok(identical(A$line[A$MAP_MED_TYPE == "BORT" & A$MAP_START_DT == as.Date("2021-02-01")], "") &&
     identical(note_at("BORT", "2021-02-01"), ""),
   "an episode outside every line has no line and no note")
ok(identical(A$line[A$MAP_START_DT == as.Date("2020-08-15") & A$MAP_MED_TYPE == "LEN"], "2"),
   "the line column is the line whose span holds the episode's start")
ok(!is.unsorted(A$MAP_START_DT) && nrow(A) == nrow(EPS), "rows come back in date order, one per episode")
ok(identical(names(A), c("PATID", "MAP_START_DT", "MAP_END_DT", "MAP_MED_RUNOUT_DT", "MAP_MED_TYPE",
                         "MAP_MED_CLASS", "MAP_CNT", "MAP_DISCON_FLG", "line", "note")),
   "the columns are the ones the CSV and the markdown table name")
# A transplant event: interleaved as a row of its own, and it opens the line
# it started.
LINES_TX <- LINES; LINES_TX$LOT_START_TYPE[2] <- "SCT_AUTO"
TX <- data.frame(PATID = "P000001", TX_DT = as.Date("2020-07-01"), TX_TYPE = "SCT_AUTO",
                 stringsAsFactors = FALSE)
A2 <- foldin_trace_annotate(LINES_TX, EPS, TX, FOLDS, P)
txrow <- A2[A2$MAP_MED_CLASS == "TRANSPLANT", ]
ok(nrow(txrow) == 1 && identical(txrow$MAP_MED_TYPE, "SCT_AUTO") && identical(txrow$note, "opens LOT 2") &&
     identical(txrow$line, "2"),
   "a transplant is a row of class TRANSPLANT, and the one that started a line opens it")
ok(identical(A2$note[A2$MAP_MED_TYPE == "CARF"], "induction"),
   "...and on an SCT_AUTO line a drug starting on the start date is induction, not the opener")
ok(nrow(foldin_trace_annotate(LINES, EPS, NULL, FOLDS[0, ], P)) == nrow(EPS) &&
     !any(grepl("FOLDED", foldin_trace_annotate(LINES, EPS, NULL, FOLDS[0, ], P)$note)),
   "with no fold rows nothing is marked FOLDED")
# A previous-line drug dosed on the start date beside the opener is in the
# window, so it is in the regimen, but it cannot have opened the line (4.3).
LINES_OP <- LINES; LINES_OP$LOT_BASE_MEDS[2] <- "BORT CARF LEN"; LINES_OP$LOT_MED_CNT[2] <- 3L
EPS_OP <- rbind(EPS, epi("BORT", "2020-07-01", "2020-08-01"))
A3 <- foldin_trace_annotate(LINES_OP, EPS_OP, NULL, FOLDS, P)
n3 <- function(med, d) A3$note[A3$MAP_MED_TYPE == med & A3$MAP_START_DT == as.Date(d)]
ok(identical(n3("BORT", "2020-07-01"), "induction") && identical(n3("CARF", "2020-07-01"), "opens LOT 2"),
   "a previous-line drug starting on the start date is induction, not the opener; the new agent opens")
SUBS <- data.frame(original_med = "BORT", substitute_med = "BORTBS", stringsAsFactors = FALSE)
EPS_OP2 <- rbind(EPS, epi("BORTBS", "2020-07-01", "2020-08-01"))
A4 <- foldin_trace_annotate(LINES_OP, EPS_OP2, NULL, FOLDS, P, subs = SUBS)
A4n <- foldin_trace_annotate(LINES_OP, EPS_OP2, NULL, FOLDS, P)
ok(identical(A4$note[A4$MAP_MED_TYPE == "BORTBS"], "induction") &&
     identical(A4n$note[A4n$MAP_MED_TYPE == "BORTBS"], "opens LOT 2"),
   "...under any of its names (4.4) when the substitute pairs are given, by its own name without them")
# The signature on a CAR-T-opened line is not the rule's doing, and the note
# says so instead of crediting 4.8.
L_SIG <- LINES; L_SIG$LOT_START_TYPE[2] <- "CART"; L_SIG$ELIGIBLE_END[2] <- as.Date("2020-08-14")
A5 <- foldin_trace_annotate(L_SIG, EPS, NULL, FOLDS, P)
ok(!any(grepl("FOLDED", A5$note)) &&
     identical(A5$note[A5$MAP_MED_TYPE == "LEN" & A5$MAP_START_DT == as.Date("2020-08-15")],
               "signature on LOT 2, a CART line: not a 4.8 fold, raise as a build defect"),
   "on a CAR-T-opened line the returning dose is marked as a signature to raise, never FOLDED")
stops(foldin_trace_annotate(LINES[, setdiff(names(LINES), "ELIGIBLE_END")], EPS, NULL, FOLDS, P),
      "lines without a window end are refused rather than annotated against nothing")

cat("\n-- the narrative --\n")
N <- foldin_trace_narrative(FOLDS[1, ], LINES, EPS, P)
ok(has(N, "LEN was in LOT 1's regimen (BORT LEN)"), "it names the drug and the previous line's regimen")
ok(has(N, "LOT 2 opened on 2020-07-01 with CARF"), "it names the line, the date and the opener")
ok(!has(N, "DEX"), "...and the steroid starting that day is not an opener")
ok(has(N, "returned on 2020-08-15, 45 days after LOT 2 opened"), "it gives the return date and the day count")
ok(has(N, "outside its 30-day induction window (window ended 2020-07-30)"),
   "it gives the window length and where it ended")
ok(has(N, "joined LOT 2's regimen (CARF LEN)"), "it says the drug joined the regimen")
# The pre-rule outcome, three ways. On this fixture CARF's only episode ends
# 2020-08-01, so LOT 2's own regimen had run out before LEN came back: the
# return was no added-medication candidate, it confirmed the run-out.
ok(has(N, "had run out on 2020-08-01") && has(N, "DISCONTINUATION on 2020-08-01") &&
     has(N, "new line would have opened on 2020-08-15 with LEN") && !has(N, "MED_ADD"),
   "own regimen run out before the return: DISCONTINUATION at the run-out, confirmed by the return, new line on it")
EPS_COV <- rbind(EPS, epi("CARF", "2020-08-01", "2020-09-01"))
N_COV <- foldin_trace_narrative(FOLDS[1, ], LINES, EPS_COV, P)
ok(has(N_COV, "added medication") && has(N_COV, "MED_ADD on 2020-08-14") && has(N_COV, "cover ran to 2020-09-01") &&
     has(N_COV, "new line would have opened on 2020-08-15") && !has(N_COV, "DISCONTINUATION"),
   "own regimen still covered on the return: MED_ADD the day before, a new line on the return")
TX_CART <- data.frame(PATID = "P000001", TX_DT = as.Date("2020-09-01"), TX_TYPE = "CART", stringsAsFactors = FALSE)
N_BR <- foldin_trace_narrative(FOLDS[1, ], LINES, EPS_COV, P, tx = TX_CART)
ok(has(N_BR, "CAR-T on 2020-09-01, 17 days later") && has(N_BR, "CART_INIT on 2020-08-31") &&
     has(N_BR, "45-day consolidation window") && !has(N_BR, "MED_ADD on"),
   "...and with a CAR-T inside 45 days of it, bridging: CART_INIT the day before the infusion (7.3)")
TX_LATE <- TX_CART; TX_LATE$TX_DT <- as.Date("2020-10-15")
ok(has(foldin_trace_narrative(FOLDS[1, ], LINES, EPS_COV, P, tx = TX_LATE), "MED_ADD on 2020-08-14"),
   "...a CAR-T 61 days after the return is past the window, so MED_ADD stands")
ok(has(foldin_trace_narrative(FOLDS[1, ], LINES, EPS, P, tx = TX_CART), "DISCONTINUATION on 2020-08-01"),
   "...and a CAR-T after a return that was no candidate changes nothing: still the run-out")
N_NONE <- foldin_trace_narrative(FOLDS[1, ], LINES, EPS[EPS$MAP_MED_TYPE == "LEN", ], P)
ok(has(N_NONE, "cannot be said") && has(N_NONE, "MED_ADD on 2020-08-14") && has(N_NONE, "DISCONTINUATION") &&
     has(N_NONE, "not in the read"),
   "with no own-regimen episode in the read the paragraph hedges between the two instead of asserting one")
ok(!grepl("\u2014", N) && !has(N, " - ") && !grepl("\u2014", N_COV) && !grepl("\u2014", N_BR),
   "plain sentences, no dashes")
# A previous-line drug on the start date is not an opener (4.3), under any
# name (4.4).
N_OP <- foldin_trace_narrative(FOLDS[1, ], LINES_OP, EPS_OP, P)
ok(has(N_OP, "opened on 2020-07-01 with CARF.") && !has(N_OP, "BORT and CARF"),
   "the opener list leaves out a drug the previous regimen carried")
ok(has(foldin_trace_narrative(FOLDS[1, ], LINES_OP, EPS_OP2, P, subs = SUBS), "with CARF.") &&
     has(foldin_trace_narrative(FOLDS[1, ], LINES_OP, EPS_OP2, P), "with BORTBS and CARF."),
   "...its substitute too, when the pairs are given")
# A CAR-T-opened line: 4.8 refuses the fold there, so the signature is a
# defect and the paragraph says so rather than reading it as the rule.
F_CART <- FOLDS; F_CART$ELIGIBLE_END <- as.Date("2020-08-14"); F_CART$RETURN_DT <- as.Date("2020-08-20")
F_CART$LOT_START_TYPE <- "CART"
L_CART <- LINES; L_CART$LOT_START_TYPE[2] <- "CART"; L_CART$ELIGIBLE_END[2] <- as.Date("2020-08-14")
N2 <- foldin_trace_narrative(F_CART[1, ], L_CART, EPS, P)
ok(has(N2, "was opened by a transplant (CART)") && has(N2, "45-day induction window") &&
     has(N2, "4.8 refuses a fold across a procedure") && has(N2, "build defect") && has(N2, "C1 accepts") &&
     !has(N2, "under 4.8 it joined") && !has(N2, "Without the rule"),
   "a CAR-T-started line: the signature is reported as a build defect, not as 4.8 at work")
F_CART2 <- F_CART; F_CART2$LOT_START_TYPE <- NULL
ok(has(foldin_trace_narrative(F_CART2[1, ], L_CART, EPS, P), "build defect"),
   "...read off the line's own start type when the candidate row has none")
F_CUT <- FOLDS; F_CUT$ELIGIBLE_END <- as.Date("2020-07-10")
ok(has(foldin_trace_narrative(F_CUT[1, ], LINES, EPS, P), "cut short by a transplant"),
   "a window ending before its nominal day says a transplant cut it")

cat("\n-- rendering and masking --\n")
ok(identical(mask_patid_r("P0000ABCDEF"), "...abcdef"), "mask: '...' and the last six characters, lower case")
ok(identical(mask_patid_r(c("AB", "123456789")), c("...ab", "...456789")),
   "...a short id keeps what it has; a long one keeps six")
ok(identical(mask_patid_r(12345678), "...345678"), "...and a numeric id is masked as its digits")
SUMM <- foldin_trace_summary(FOLDS, 10, 20)
SEC <- foldin_trace_patient_md("P000001", FOLDS, LINES, EPS, A, P)
MD_U <- foldin_trace_markdown("run-abc", "ndmm_", P, SUMM, list(SEC), masked = FALSE, n_candidates = 1)
MD_M <- foldin_trace_markdown("run-abc", "ndmm_", P, SUMM, list(SEC), masked = TRUE, n_candidates = 1)
ok(any(has(MD_U, "NOT masked")) && any(has(MD_U, "stays inside the study environment")),
   "the unmasked report says its ids are real and that it stays inside the study environment")
ok(any(has(MD_M, "MASKED")) && !any(has(MD_M, "NOT masked")), "the masked report says so")
ok(any(has(MD_U, "## Patient P000001")) && any(has(MD_U, "FOLDED into LOT 2 (4.8)")) &&
     any(has(MD_U, "| LOT_NUM | LOT_START_DT |")) && any(has(MD_U, "LEN was in LOT 1's regimen")),
   "a patient section carries the heading, the narrative, the lines table and the marked episode")
ok(any(has(MD_U, "1 patient(s) carry a fold")) && any(has(MD_U, "run-abc")) && any(has(MD_U, "LOT1 60 days")),
   "the header carries the run, the candidate count and the windows")
SEC0 <- foldin_trace_patient_md("P000002", FOLDS[0, ], LINES, EPS, A, P)
ok(any(has(SEC0, "No fold found for this patient")) && any(has(SEC0, "| LOT_NUM |")),
   "a listed patient with no fold is reported as such, with the lines shown")
SEC9 <- foldin_trace_patient_md("9999", FOLDS[0, ], LINES[0, ], EPS[0, ], A[0, ], P)
ok(any(has(SEC9, "no line in LOT_LONG_FINAL")) && any(has(SEC9, "Check the id")) &&
     !any(has(SEC9, "No fold found")) && !any(has(SEC9, "(no rows)")),
   "an id with no line at all is called an id to check, not a patient with no fold")
ok(any(has(foldin_trace_md_table(data.frame(n = 100000, d = as.Date("2020-01-01"))), "| 100000 |")) &&
     !any(has(foldin_trace_md_table(data.frame(n = 100000)), "1e+05")),
   "a round count renders as digits in a table cell, never in scientific notation")
ok(any(has(MD_U, "non-MED line")) && any(has(MD_U, "build defect")),
   "the header says what the defect row of the summary is")

cat("\n-- the candidate query, RUN rather than read --\n")
{
  source(file.path(ROOT, "tests", "exec_harness.R"))
  # The persisted episode table carries MAP_CNT, which the QC fixture does
  # not need and this trace shows. Added to the shape here, not upstream.
  EXEC_SCHEMA$map$columns <- c(EXEC_SCHEMA$map$columns, MAP_CNT = "INTEGER")

  fin <- function(n, start, type, meds, end, reason = "STUDY_END", pat = "P000001") list(
    PATID = pat, LOT_NUM = n, LOT_START_DT = start, LOT_START_TYPE = type,
    LOT_BASE_MEDS = meds, LOT_MED_CNT = length(strsplit(meds, " ")[[1]]),
    LOT_BASE_DISCON_DT = NA, LOT_BASE_1ST_ADD_MED = NA, LOT_BASE_1ST_ADD_MED_DT = NA,
    LOT_BASE_END_DT = end, LOT_BASE_END_REASON = reason,
    LOT_BASE_LENGTH = as.integer(as.Date(end) - as.Date(start)) + 1L,
    LOT_BASE_END_DT_CE_SENS = end, LOT_BASE_END_REASON_CE_SENS = reason, LOT_TX_AUTO_MAX_DT = NA)
  ep <- function(med, start, end, class = "NOVEL", pat = "P000001") list(
    PATID = pat, MAP_MED_ABBR = med, MAP_MED_TYPE = med, MAP_MED_CLASS = class,
    MAP_START_DT = start, MAP_END_DT = end, MAP_DISCON_FLG = 0L,
    MAP_MED_RUNOUT_DT = end, MAP_RX_RUNOUT_DT = NA, ELIGIBLE_END = end, MAP_CNT = 1L)
  subs_row <- function(orig, subst) list(original_med = orig, substitute_med = subst)

  run_rows <- function(queries, data) {
    py <- file.path(ROOT, "tests", "run_duckdb_rows.py")
    schema <- paste(vapply(names(EXEC_SCHEMA), function(k) {
      cols <- EXEC_SCHEMA[[k]]$columns
      sprintf('"%s":{"columns":{%s}}', EXEC_SCHEMA[[k]]$table,
              paste(sprintf('"%s":"%s"', names(cols), cols), collapse = ","))
    }, character(1)), collapse = ",")
    qs <- paste(vapply(names(queries), function(id)
      sprintf('{"id":"%s","sql":"%s"}', id, .exec_json_str(queries[[id]])), character(1)),
      collapse = ",")
    spec <- sprintf('{"tables":{%s},"data":{%s},"queries":[%s]}',
                    schema, .exec_json_data(data), qs)
    f <- tempfile(fileext = ".json"); writeLines(spec, f)
    out <- suppressWarnings(system2("python3", c(shQuote(py), shQuote(f)),
                                    stdout = TRUE, stderr = TRUE))
    if (!length(out)) return(NULL)
    if (grepl("^SKIP", out[1])) return("skip")
    res <- list(); id <- NULL; buf <- character(0)
    flush <- function() {
      if (is.null(id)) return()
      if (length(buf) && grepl("^!! ", buf[1])) {
        res[[id]] <<- structure(list(), error = sub("^!! ", "", buf[1]))
      } else if (!length(buf)) {
        res[[id]] <<- structure(list(), error = "no header")
      } else {
        cols <- strsplit(buf[1], "\t", fixed = TRUE)[[1]]
        rows <- lapply(buf[-1], function(l) {
          v <- strsplit(l, "\t", fixed = TRUE)[[1]]; length(v) <- length(cols); v[is.na(v)] <- ""; v
        })
        d <- as.data.frame(do.call(rbind, c(list(character(0)), rows)), stringsAsFactors = FALSE)
        if (!length(rows)) d <- as.data.frame(matrix(character(0), 0, length(cols)), stringsAsFactors = FALSE)
        names(d) <- cols
        res[[id]] <<- d
      }
    }
    for (l in out) {
      if (grepl("^== ", l)) { flush(); id <- sub("^== ", "", l); buf <- character(0) }
      else buf <- c(buf, l)
    }
    flush()
    res
  }
  err <- function(r) attr(r, "error")
  cands_of <- function(data) run_rows(list(c = foldin_trace_sql(EXEC_TABLES, P)), data)

  # (a) the planted fold. LOT1 BORT LEN, LOT2 opened by CARF, LEN back on
  # 2020-08-15 - after the 30-day window that ends 2020-07-30, inside the line.
  BASE <- list(
    final = list(fin(1L, "2020-01-01", "MED", "BORT LEN", "2020-06-28", "DISCONTINUATION"),
                 fin(2L, "2020-07-01", "MED", "CARF LEN", "2020-12-31")),
    map = list(ep("BORT", "2020-01-01", "2020-02-01"), ep("LEN", "2020-01-05", "2020-02-05"),
               ep("CARF", "2020-07-01", "2020-08-01"), ep("LEN", "2020-08-15", "2020-09-15")),
    allo = list(), auto = list(), subs = list())
  probe <- cands_of(BASE)
  if (is.null(probe)) {
    cat("  SKIP    the row runner could not be run\n")
  } else if (identical(probe, "skip")) {
    cat("  SKIP    duckdb or sqlglot is not installed\n")
  } else {
    r <- probe$c
    ok(is.null(err(r)), paste0("the candidate query runs", if (!is.null(err(r))) paste0(" [", err(r), "]") else ""))
    ok(!is.null(r) && is.null(err(r)) && nrow(r) == 1 && r$LOT_NUM == "2" && r$MED_ABBR == "LEN" &&
         r$RETURN_DT == "2020-08-15" && r$ELIGIBLE_END == "2020-07-30" &&
         r$PREV_BASE_MEDS == "BORT LEN" && r$LOT_BASE_END_DT == "2020-12-31" && r$PATID == "P000001",
       "(a) the planted fold is the one row: LOT2, LEN, returned 2020-08-15, window ended 2020-07-30")

    # (b) the same patient with LEN ALSO dosed inside the window - the
    # 2020-08-15 dose stays. That is the continued-backbone shape, the most
    # common one in the data, and the one clause (b) exists to keep out: only
    # the NOT EXISTS excludes it, since the late dose alone satisfies (c).
    B <- BASE; B$map[[5]] <- ep("LEN", "2020-07-20", "2020-08-20")
    r <- cands_of(B)$c
    ok(is.null(err(r)) && nrow(r) == 0,
       "(b) a drug dosed inside the window AND after it is an ordinary regimen drug, not a fold")
    B3 <- BASE; B3$map[[5]] <- ep("LEN", "2020-07-30", "2020-08-30")
    r <- cands_of(B3)$c
    ok(is.null(err(r)) && nrow(r) == 0, "(b) ...and a dose on the window's last day is inside it")
    B_IN <- BASE; B_IN$map[[4]] <- ep("LEN", "2020-07-20", "2020-08-20")
    r <- cands_of(B_IN)$c
    ok(is.null(err(r)) && nrow(r) == 0, "(b) ...and a return only inside the window is not reported")

    # (c) two lines back: LOT2 did not carry LEN, so its return in LOT3 is out
    # of 4.8's scope even though it sits outside LOT3's window.
    C <- BASE
    C$final <- list(fin(1L, "2020-01-01", "MED", "BORT LEN", "2020-06-28", "DISCONTINUATION"),
                    fin(2L, "2020-07-01", "MED", "CARF", "2020-09-30"),
                    fin(3L, "2020-10-01", "MED", "POM LEN", "2020-12-31"))
    C$map <- list(ep("BORT", "2020-01-01", "2020-02-01"), ep("LEN", "2020-01-05", "2020-02-05"),
                  ep("CARF", "2020-07-01", "2020-08-01"), ep("POM", "2020-10-01", "2020-11-01"),
                  ep("LEN", "2020-11-20", "2020-12-20"))
    r <- cands_of(C)$c
    ok(is.null(err(r)) && nrow(r) == 0, "(c) a drug from two lines back is not reported")
    # ...and the control that proves (c) is the scope and not the shape: give
    # LOT2 LEN as well and the LOT3 return IS a fold.
    C2 <- C; C2$final[[2]]$LOT_BASE_MEDS <- "CARF LEN"; C2$final[[2]]$LOT_MED_CNT <- 2L
    C2$map[[6]] <- ep("LEN", "2020-07-05", "2020-08-05")
    r <- cands_of(C2)$c
    ok(is.null(err(r)) && nrow(r) == 1 && r$LOT_NUM == "3" && r$MED_ABBR == "LEN",
       "(c) ...and with LOT2 carrying LEN too, the LOT3 return is one")

    # (d) a permissible substitute is the same agent, both directions.
    D <- BASE
    D$subs <- list(subs_row("BORT", "BORTBS"))
    D$final <- list(fin(1L, "2020-01-01", "MED", "BORT", "2020-06-28", "DISCONTINUATION"),
                    fin(2L, "2020-07-01", "MED", "CARF BORTBS", "2020-12-31"))
    D$map <- list(ep("BORT", "2020-01-01", "2020-02-01"), ep("CARF", "2020-07-01", "2020-08-01"),
                  ep("BORTBS", "2020-08-15", "2020-09-15"))
    r <- cands_of(D)$c
    ok(is.null(err(r)) && nrow(r) == 1 && r$MED_ABBR == "BORTBS" && r$PREV_BASE_MEDS == "BORT",
       "(d) the substitute returning where the previous line named the reference product: one row, BORTBS")
    D2 <- D
    D2$final[[1]]$LOT_BASE_MEDS <- "BORTBS"; D2$final[[2]]$LOT_BASE_MEDS <- "CARF BORT"
    D2$map[[1]] <- ep("BORTBS", "2020-01-01", "2020-02-01"); D2$map[[3]] <- ep("BORT", "2020-08-15", "2020-09-15")
    r <- cands_of(D2)$c
    ok(is.null(err(r)) && nrow(r) == 1 && r$MED_ABBR == "BORT" && r$PREV_BASE_MEDS == "BORTBS",
       "(d) ...and the reverse direction: one row, BORT")
    D3 <- D; D3$subs <- list()
    r <- cands_of(D3)$c
    ok(is.null(err(r)) && nrow(r) == 0,
       "(d) ...and without the pair the two are different drugs and nothing is reported")

    # (e) a CAR-T-started line takes the 45-day window: day 40 is inside it,
    # day 50 is not. The signature on such a line is NOT a fold - 4.8 refuses
    # one across a procedure that opened the line - so the row comes back
    # with its start type, for the narrative to report it as a defect.
    E1 <- BASE
    E1$final[[2]]$LOT_START_TYPE <- "CART"
    E1$allo <- list(list(PATID = "P000001", TX_DT = "2020-07-01", SCT_TYPE = "CART"))
    E1$map[[4]] <- ep("LEN", "2020-08-10", "2020-09-10")
    r <- cands_of(E1)$c
    ok(is.null(err(r)) && nrow(r) == 0, "(e) a CAR-T line: a return on day 40 is inside the 45-day window")
    E2 <- E1; E2$map[[4]] <- ep("LEN", "2020-08-20", "2020-09-20")
    r <- cands_of(E2)$c
    ok(is.null(err(r)) && nrow(r) == 1 && r$ELIGIBLE_END == "2020-08-14" && r$RETURN_DT == "2020-08-20" &&
         r$LOT_START_TYPE == "CART",
       "(e) ...and on day 50 the signature appears, window ending on day 45, carrying its CART start type")
    # The same return on a MED line is already a fold at day 40 - the window
    # is the line's own, not always 30.
    E3 <- E1; E3$final[[2]]$LOT_START_TYPE <- "MED"; E3$allo <- list()
    r <- cands_of(E3)$c
    ok(is.null(err(r)) && nrow(r) == 1 && r$ELIGIBLE_END == "2020-07-30" && r$LOT_START_TYPE == "MED",
       "(e) ...while on a MED line day 40 is already past the 30-day window")

    # (f) a return after the line ended could not have reached the regimen.
    F1 <- BASE; F1$map[[4]] <- ep("LEN", "2021-01-15", "2021-02-15")
    r <- cands_of(F1)$c
    ok(is.null(err(r)) && nrow(r) == 0, "(f) a return after LOT_BASE_END_DT is not counted")
    F2 <- BASE; F2$map[[4]] <- ep("LEN", "2020-12-31", "2021-01-31")
    r <- cands_of(F2)$c
    ok(is.null(err(r)) && nrow(r) == 1 && r$RETURN_DT == "2020-12-31",
       "(f) ...and one on the line's last day is")

    # (g) two returns: RETURN_DT is the first, and there is still one row.
    G <- BASE; G$map[[5]] <- ep("LEN", "2020-10-15", "2020-11-15")
    r <- cands_of(G)$c
    ok(is.null(err(r)) && nrow(r) == 1 && r$RETURN_DT == "2020-08-15",
       "(g) two doses past the window give one row, dated at the first")

    # The per-patient reads, run on the planted fold and fed to the renderer -
    # the whole chain from warehouse shape to marked row, without a warehouse.
    # Twice: the MED line, where the fold is the rule's, and the CAR-T line,
    # where the same signature is a defect. The renderer calls sit inside
    # ok() so a query that returns nothing is a FAIL with a count line, not
    # a halted suite.
    Q <- list(lines = foldin_trace_lines_sql(EXEC_TABLES, "P000001", P),
              eps = foldin_trace_episodes_sql(EXEC_TABLES, "P000001"),
              tx = foldin_trace_tx_sql(EXEC_TABLES, "P000001"),
              tot = foldin_trace_totals_sql(EXEC_TABLES),
              subs = foldin_trace_subs_sql(EXEC_TABLES),
              c = foldin_trace_sql(EXEC_TABLES, P))
    E2$auto <- list(list(PATID = "P000001", TX_DT = "2019-06-01"))
    rr <- run_rows(Q, E2)
    ok(all(vapply(rr, function(x) is.null(err(x)), logical(1))),
       paste0("the per-patient reads run",
              paste0(unlist(lapply(names(rr), function(n) if (!is.null(err(rr[[n]]))) paste0(" [", n, ": ", err(rr[[n]]), "]"))), collapse = "")))
    ok(nrow(rr$lines) == 2 && identical(rr$lines$ELIGIBLE_END, c("2020-02-29", "2020-08-14")),
       "the lines read gives each line its own window end: 60 days at LOT1, 45 on the CAR-T line")
    ok(nrow(rr$eps) == 4 && all(c("MAP_MED_TYPE", "MAP_MED_CLASS", "MAP_CNT", "MAP_DISCON_FLG") %in% names(rr$eps)),
       "the episodes read returns every raw episode with the columns the table shows")
    ok(nrow(rr$tx) == 2 && identical(rr$tx$TX_TYPE, c("SCT_AUTO", "CART")),
       "the transplant read returns both tables' events, named as LOT_START_TYPE names them")
    ok(identical(unname(unlist(rr$tot)), c("1", "2")), "the totals read counts patients and lines")
    ok(is.null(err(rr$subs)) && nrow(rr$subs) == 0 && identical(names(rr$subs), c("original_med", "substitute_med")),
       "the substitute read returns the pairs, none planted here")
    ok({
      ann <- foldin_trace_annotate(rr$lines, rr$eps, rr$tx, rr$c, P, subs = rr$subs)
      nrow(rr$c) == 1 && !any(grepl("FOLDED", ann$note)) &&
        identical(ann$note[ann$MAP_MED_TYPE == "LEN" & ann$MAP_START_DT == as.Date("2020-08-20")],
                  "signature on LOT 2, a CART line: not a 4.8 fold, raise as a build defect") &&
        identical(ann$note[ann$MAP_MED_TYPE == "CART"], "opens LOT 2") &&
        identical(ann$note[ann$MAP_MED_TYPE == "SCT_AUTO"], "") &&
        identical(ann$line[ann$MAP_MED_TYPE == "SCT_AUTO"], "")
    }, "annotated off the executed rows: LEN's return is the signature to raise, the CAR-T opens LOT 2, the early AUTO is in no line")
    ok({
      nn <- foldin_trace_narrative(rr$c[1, ], rr$lines, rr$eps, P, tx = rr$tx, subs = rr$subs)
      nrow(rr$c) == 1 && has(nn, "was opened by a transplant (CART)") && has(nn, "50 days after LOT 2") &&
        has(nn, "45-day") && has(nn, "build defect")
    }, "...and the narrative off the same rows reports the CAR-T line's signature as a defect")
    # The MED line: the planted fold, whole chain. CARF's cover ends
    # 2020-08-01, before LEN's return, so the pre-rule reading is the run-out.
    G2 <- BASE; G2$auto <- list(list(PATID = "P000001", TX_DT = "2019-06-01"))
    G2$subs <- list(subs_row("BORT", "BORTBS"))
    r2 <- run_rows(Q, G2)
    ok(all(vapply(r2, function(x) is.null(err(x)), logical(1))) && nrow(r2$c) == 1 && nrow(r2$subs) == 1,
       "the reads run on the MED-line fold too, the planted pair coming back")
    ok({
      ann2 <- foldin_trace_annotate(r2$lines, r2$eps, r2$tx, r2$c, P, subs = r2$subs)
      nrow(r2$c) == 1 && sum(ann2$note == "FOLDED into LOT 2 (4.8)") == 1 &&
        ann2$MAP_MED_TYPE[ann2$note == "FOLDED into LOT 2 (4.8)"] == "LEN" &&
        identical(ann2$note[ann2$MAP_MED_TYPE == "CARF"], "opens LOT 2")
    }, "annotated off the executed rows: LEN's return is the one FOLDED row and CARF opens LOT 2")
    ok({
      nn2 <- foldin_trace_narrative(r2$c[1, ], r2$lines, r2$eps, P, tx = r2$tx, subs = r2$subs)
      nrow(r2$c) == 1 && has(nn2, "opened on 2020-07-01 with CARF") && has(nn2, "under 4.8 it joined LOT 2's regimen (CARF LEN)") &&
        has(nn2, "had run out on 2020-08-01") && has(nn2, "DISCONTINUATION on 2020-08-01")
    }, "...and the narrative off the same rows reads the fold, and the run-out the return confirmed")

    # mask_patid_r against MASK_PATID itself: the SQL rule from R/checks.R run
    # through DuckDB on the same ids, so the two copies are held to each other.
    MIDS <- c("P0000ABCDEF", "AB", "123456789", "abcdefg")
    M <- list(final = lapply(MIDS, function(id) fin(1L, "2020-01-01", "MED", "BORT", "2020-06-28", pat = id)),
              map = list(), allo = list(), auto = list(), subs = list())
    rm <- run_rows(list(m = paste0("SELECT cast(PATID as string) AS PATID, ", mask("PATID"),
                                   " AS MASKED FROM ", EXEC_TABLES$final, " ORDER BY PATID")), M)$m
    ok(is.null(err(rm)) && nrow(rm) == 4 && identical(rm$MASKED, mask_patid_r(rm$PATID)),
       "mask_patid_r gives what MASK_PATID gives, id for id, through DuckDB")
  }
}

cat(sprintf("%d passed, %d failed\n", pass, fail))
if (fail > 0L) quit(status = 1L)
