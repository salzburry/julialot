#!/usr/bin/env Rscript
# The QC catalogue, checked without a warehouse.
#
#   Rscript "lot/qc/tests/test_lot_qc.R"
#
# What can be tested without a warehouse is the SQL as a string, the settings
# parsing, and the rules that turn a count into a verdict. The checks are
# generated with fake table names and inspected.

ROOT <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                                 fixed = TRUE))) else getwd()
  dirname(d)
})

pass <- 0L; fail <- 0L

# Coverage this run did NOT get. A suite whose executed blocks were skipped -
# no duckdb, no sqlglot, no python3 - has tested a fraction of what it claims,
# and reporting "0 failed" for it reads as a clean run. Each skip is counted
# and named, and an incomplete run exits non-zero unless the caller says it
# expected one (ALLOW_SKIPPED_TESTS=TRUE).
skipped <- 0L
skip_note <- function(what) { skipped <<- skipped + 1L; cat("  SKIP   ", what, "\n") }

# The tally is only as good as its wiring: a bare cat("SKIP ...") prints like a
# skip and counts as nothing, which is exactly how the first pass at this went
# wrong - eight sites in one suite and six in another were missed by hand. Each
# suite now checks its OWN source, so a skip site added later is caught by the
# suite it was added to rather than by whoever next reads the diff.
.suite_path <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(a)) normalizePath(sub("^--file=", "", a[1]), mustWork = FALSE) else NA_character_
})
check_skip_wiring <- function(path = .suite_path) {
  if (is.na(path) || !file.exists(path)) return(invisible(NULL))
  src <- readLines(path, warn = FALSE)
  bad <- grep('cat\\(.*"[^"]*SKIP', src)
  # Not a comment describing one, and not skip_note's own printing line.
  bad <- bad[!grepl("^\\s*#", src[bad]) & !grepl("skip_note", src[bad], fixed = TRUE)]
  ok(length(bad) == 0L,
     paste0("every SKIP this suite prints goes through skip_note(), so it is counted",
            if (length(bad)) paste0(" [bare cat at line(s) ", paste(bad, collapse = ", "), "]") else ""))
}
test_report_status <- function(pass, fail, skipped) {
  cat(sprintf("%d passed, %d failed, %d skipped\n", pass, fail, skipped))
  if (skipped > 0L)
    cat("  ", skipped, " block(s) did not run, so this is NOT a clean run. ",
        "Install duckdb and sqlglot, or set ALLOW_SKIPPED_TESTS=TRUE to accept it.\n", sep = "")
  allow <- identical(toupper(trimws(Sys.getenv("ALLOW_SKIPPED_TESTS"))), "TRUE")
  if (fail > 0L || (skipped > 0L && !allow)) quit(status = 1L)
}
ok <- function(cond, what) {
  # `cond` is evaluated here, not by the caller, so an assertion whose
  # expression raises counts as a failure instead of aborting the run and
  # losing every result after it.
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

# The table names the runner hands in. None is a substring of another, unlike
# the real ones - LOT_LONG sits inside LOT_LONG_FINAL - so "reads this table"
# below means what it says instead of matching the shorter name by accident.
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
SQL <- lapply(LOT_QC_CHECKS, function(c_i) c_i$sql(TBL, P))
names(SQL) <- vapply(LOT_QC_CHECKS, function(c_i) c_i$id, character(1))

cat("\n-- the catalogue holds together --\n")
ok(length(LOT_QC_CHECKS) > 0, "there are checks")
ok(isTRUE(check_qc_catalogue()), "the shipped catalogue passes its own validation")
# Ids end up in a report. Two rows with one id is two findings nobody can tell
# apart afterwards.
stops(check_qc_catalogue(list(modifyList(LOT_QC_CHECKS[[1]], list(id = "")))),
      "a check with no id at all is refused - two of them would be one row")
stops(check_qc_catalogue(c(LOT_QC_CHECKS, LOT_QC_CHECKS[1])),
      "...and a duplicate id is refused")
stops(check_qc_catalogue(list(modifyList(LOT_QC_CHECKS[[1]], list(severity = "minor")))),
      "...and a severity outside fail/warn/info is refused")
stops(check_qc_catalogue(list(modifyList(LOT_QC_CHECKS[[1]], list(why = NULL)))),
      "...and a check with no stated reason is refused")
stops(check_qc_catalogue(list(modifyList(LOT_QC_CHECKS[[1]], list(sql = "SELECT 1")))),
      "...and a check whose sql is not a function is refused")

cat("\n-- every check answers the same shape --\n")
# The runner reads N_BAD off every result and nothing else. A check that
# returned a different shape would be scored as an error, which reads in the
# report like a defect in the run rather than in the check.
ok(all(vapply(SQL, function(s) has(s, "AS N_BAD"), logical(1))),
   "each one selects N_BAD")
ok(all(vapply(SQL, function(s) has(s, "AS DETAIL"), logical(1))),
   "...and DETAIL beside it")
ok(all(vapply(SQL, function(s) has(s, "SELECT count(*) AS N_BAD"), logical(1))),
   "...as an aggregate over a subquery, so no match gives 0 rather than no row")

cat("\n-- a check only reads the tables it declares --\n")
keys <- names(TBL)
for (c_i in LOT_QC_CHECKS) {
  used <- keys[vapply(keys, function(k) has(SQL[[c_i$id]], TBL[[k]]), logical(1))]
  ok(setequal(used, c_i$needs),
     paste0(c_i$id, " declares exactly the tables it reads"))
}
ok(all(unlist(lapply(LOT_QC_CHECKS, function(c_i) c_i$needs)) %in% keys),
   "every declared table is one the runner supplies")

cat("\n-- no patient id leaves in the clear --\n")
# The report is a file that gets circulated. Every check that names a patient
# names the last six characters of the id, so the masking expression has to be
# present wherever a raw PATID is selected.
for (id in names(SQL)) {
  s <- SQL[[id]]
  # A raw PATID reaching the output would be selected as an alias. The masked
  # form always goes through concat('...', lower(substr(...))).
  bare <- grepl("(^|[ ,(])PATID AS |[.]PATID AS ", s)
  ok(!bare || has(s, "concat('...', lower(substr("),
     paste0(id, " masks any patient id it reports"))
}

cat("\n-- the run's own settings, not this folder's config --\n")
ok(P$ind1 == 60 && P$indn == 30 && P$cart == 45,
   "the three regimen windows come out of the recorded settings")
ok(P$tandem == 180 && P$auto_gap == 60,
   "...and so do the transplant thresholds")
ok(P$confirm == 90 && P$max_lot == 5,
   "...and so do B8's confirmation window and the line cap it stops at")
# induction_window_days is a suffix of lot_n_induction_window_days, and the
# real string is sorted so the short key comes first - which an unanchored
# search would find correctly by luck. Asked of a string with the long key
# first, an unanchored search reads LOT1's 60-day window as the later-line 30.
REVERSED <- "lot_n_induction_window_days=30|induction_window_days=60"
ok(qc_setting(REVERSED, "induction_window_days") == "60" &&
     qc_setting(REVERSED, "lot_n_induction_window_days") == "30",
   "a key that is a suffix of another is not read out of it, whichever comes first")
ok(qc_setting(SETTINGS, "induction_window_days") == "60" &&
     qc_setting(SETTINGS, "lot_n_induction_window_days") == "30",
   "...and the same pair reads correctly out of the real sorted string")
ok(qc_setting(SETTINGS, "allo_lot_span") == "single_day",
   "...the first key in the string is found")
ok(qc_setting(SETTINGS, "apply_melp_rule") == "simplified",
   "...and the melphalan rule the run applied is readable")
ok(qc_setting(SETTINGS, "cohort_status_table") == "",
   "...and so is the last one, empty")
# A run built by a version that recorded a different set cannot be judged by
# this one. Defaulting would judge it by numbers it never used.
stops(qc_setting(SETTINGS, "no_such_setting"),
      "a setting the run did not record stops the QC rather than defaulting")
stops(qc_int("induction_window_days=sixty", "induction_window_days"),
      "...and a setting that is not a number stops it too")

cat("\n-- disenrollment changes what observation end means --\n")
prim <- qc_params(SETTINGS, "r")
sens <- qc_params(sub("censor_at_disenrollment=FALSE",
                      "censor_at_disenrollment=TRUE", SETTINGS, fixed = TRUE), "r")
ok(!prim$censor && prim$obs_end == "cast(c.ENDDATE as date)",
   "the primary run compares against ENDDATE")
ok(sens$censor && has(sens$obs_end, "ENDDATE_CE"),
   "...and a censoring run against ENDDATE_CE")
# B3, B4, B8 and D4 all compare a date against observation end. Reading it off
# the wrong column turns every one of them into a check of a different run.
for (id in c("B3", "B4", "B8", "D4"))
  ok(has(LOT_QC_CHECKS[[which(names(SQL) == id)]]$sql(TBL, sens), "ENDDATE_CE"),
     paste0(id, " follows the run's censoring setting"))

cat("\n-- a count becomes a verdict --\n")
ok(qc_outcome(0, "fail") == "pass" && qc_outcome(0, "warn") == "pass" &&
     qc_outcome(0, "info") == "pass", "zero is a pass whatever the severity")
ok(qc_outcome(3, "fail") == "FAIL", "a failure check with findings fails")
ok(qc_outcome(3, "warn") == "warn" && qc_outcome(3, "info") == "info",
   "...while warn and info report without failing")
# A check that could not run is not a check that found nothing. The runner
# counts an error against the exit status for the same reason.
ok(qc_outcome(NA, "fail") == "error", "no answer is an error, not a pass")

cat("\n-- the checks say what they are meant to say --\n")
ok(has(SQL$A1, "datediff(LOT_BASE_END_DT, LOT_START_DT) + 1"),
   "A1 compares the length column against the span its dates describe")
ok(has(SQL$A6, "size(split(trim(LOT_BASE_MEDS), ' '))"),
   "A6 counts the regimen string rather than trusting the count column")
# The enum is what the build writes. CART_INIT is produced; SUBSTITUTION and
# MAINTENANCE_END are produced by nothing. A5 and B5 are where that is
# written down.
ok(has(SQL$B5, "'CART_INIT'"), "B5 accepts CART_INIT, which the build writes")
ok(!has(SQL$B5, "'SUBSTITUTION'") && !has(SQL$B5, "'MAINTENANCE_END'"),
   "...and not the two reasons nothing in the build produces")
ok(has(SQL$B6, "LOT_BASE_1ST_ADD_MED_DT < LOT_START_DT"),
   "B6 catches an added-medication date before its own line")
# A7 asks about MED starts and nothing else. An AUTO can open a line at LOT2-5
# with no drug joining its 30-day window, so that line legitimately carries no
# regimen. Asking about 'MED' is what stops the next start type reopening this;
# A5 pins the enum so one cannot appear unnoticed.
ok(has(SQL$A7, "LOT_START_TYPE = 'MED'") && !has(SQL$A7, "NOT IN ('SCT_ALLO'"),
   "A7 asks only whether a medication-started line carries a regimen")
ok(has(SQL$A5, "NOT IN ('MED', 'SCT_ALLO', 'SCT_AUTO', 'CART')"),
   "...and A5 still pins the four start types A7 leans on")
# C2's exemption belongs to the earlier returning-drug rule, where a confirmed
# gap released the drug so it could be both in the regimen and the added
# medication. LOT_RULES.md 4.3 withdrew that release, so under the settings the
# study pins there is nothing to exempt.
ok(has(SQL$C2, "array_contains(split(coalesce(f.LOT_BASE_MEDS, ''), ' ')"),
   "C2 still catches an added medication that is already in the regimen")
ok(!has(SQL$C2, "coalesce(r.PREV_DISCON, 0) = 0"),
   "...with no exemption, because the pinned rule releases no such drug")
# The exemption comes back for a comparison build, where the release is back
# too. The check reads the run's own setting rather than tolerating both.
ok(has(c_i_sql_off <- LOT_QC_CHECKS[[which(vapply(LOT_QC_CHECKS,
         function(c_i) identical(c_i$id, "C2"), logical(1)))]]$sql(
           TBL, modifyList(P, list(own_return_fold = FALSE))),
       "coalesce(r.PREV_DISCON, 0) = 0"),
   "...and it returns for a build where the older rule is switched back on")
# The lag, not "any earlier episode". Read the loose way it would excuse a drug
# that discontinued once and has been running ever since.
ok(has(SQL$C2, "lag(MAP_DISCON_FLG) OVER (PARTITION BY PATID, MAP_MED_TYPE"),
   "...read as the engine reads it, off the episode immediately before")
pr <- paste(readLines(file.path(dirname(ROOT), "engine", "R", "prior_regimen.R"),
                      warn = FALSE), collapse = "\n")
ok(has(pr, "lag(ms.MAP_DISCON_FLG) OVER (PARTITION BY ms.PATID, ms.MAP_MED_TYPE"),
   "...which is the expression the engine itself releases the drug on")
# C1 is the regimen rule asked backwards, so it has to use all three windows.
ok(has(SQL$C1, "THEN 59") && has(SQL$C1, "THEN 44") && has(SQL$C1, "ELSE                                29"),
   "C1 applies LOT1's window, CAR-T's and the later-line one, each inclusive")
ok(has(SQL$C1, "LEFT JOIN s.TMAP") && has(SQL$C1, "WHERE ms.PATID IS NULL"),
   "...and finds the regimen drugs with no episode in that window")
# ...and the transplant cutoff, not the window alone. A regimen drug whose
# episode started after the transplant that ended the line is still inside the
# nominal 30, 45 or 60 days, so the window on its own passes exactly the shape
# REGIMEN_CUTOFF_DT exists to prevent.
ok(has(SQL$C1, "AS ELIGIBLE_END") && has(SQL$C1, "coalesce(c.CUTOFF_DT"),
   "...bounded by the transplant cutoff as well, the way the engine bounds it")
ok(has(SQL$C1, "l.LOT_NUM  > 1 AND x.TX_DT >  l.LOT_START_DT"),
   "...reading a later line's cutoff from the day after its own start")
# C4 is the other direction. Both halves pass on a regimen missing the drug
# that STARTED the line: C1 because everything listed is eligible, A7 because
# the string is not empty.
ok(has(SQL$C4, "AS ELIGIBLE_END") && has(SQL$C4, "NOT array_contains"),
   "C4 asks the reverse: an eligible episode in the window reached the regimen")
ok(has(SQL$C4, "ms.MAP_MED_CLASS <> 'STEROID'") &&
     has(SQL$C4, "l.LOT_START_TYPE <> 'SCT_ALLO'"),
   "...over the episodes the induction step would have taken, and no others")
# The two share one window definition, or they stop describing the same rule.
# Asked by feeding the helper a value neither check could produce on its own
# and looking for it in both; comparing qc_window_sql(TBL, P) with itself would
# be true however the checks are written.
marked <- qc_params(sub("induction_window_days=60", "induction_window_days=61",
                        SETTINGS, fixed = TRUE), "r")
c1m <- LOT_QC_CHECKS[[which(names(SQL) == "C1")]]$sql(TBL, marked)
c4m <- LOT_QC_CHECKS[[which(names(SQL) == "C4")]]$sql(TBL, marked)
ok(has(qc_window_sql(TBL, marked), "THEN 60") &&
     has(c1m, "THEN 60") && has(c4m, "THEN 60"),
   "...and both take their window from the one helper, not from a copy each")
# The CAR-T exemption follows the run here too: with the rule on, an in-window
# CAR-T is part of LOT1 and cuts nothing off its regimen.
ok(has(qc_window_sql(TBL, P), "OR 1 = 0"),
   "the LOT1 cutoff ignores CAR-T while the induction rule is on")
cart_off <- qc_params(sub("apply_cart_induction_rule=TRUE",
                          "apply_cart_induction_rule=FALSE", SETTINGS, fixed = TRUE), "r")
ok(has(qc_window_sql(TBL, cart_off), "OR x.SCT_TYPE = 'CART'"),
   "...and takes it when the run turned that rule off")
ok(has(SQL$D3, "= 'STEROID'"),
   "D3 looks for steroids in the episodes, which is where any would survive")
# Steroids are excluded from lines by class at every decision point, and the
# rollup drops them as it loads. A steroid episode surviving that is a state
# the build tolerates rather than a line defect, so a run over a production
# list still carrying dexamethasone must not fail its QC for it.
d3 <- Filter(function(c_i) identical(c_i$id, "D3"), LOT_QC_CHECKS)[[1]]
ok(identical(d3$severity, "warn"),
   "...and it reports rather than fails: the list's state, not a line defect")
# B8: the confirmation window. The count is only meaningful against this run's
# own window - a hardcoded 90 would misread a run built with a different one,
# and it reads lot_discon_confirm_days now that the run records it rather than
# borrowing the per-drug gap.
gapped <- qc_params(sub("lot_discon_confirm_days=90", "lot_discon_confirm_days=77",
                        SETTINGS, fixed = TRUE), "r")
b8 <- Filter(function(c_i) identical(c_i$id, "B8"), LOT_QC_CHECKS)[[1]]
ok(has(b8$sql(TBL, gapped), "< 77"),
   "B8's confirmation window follows the run's recorded window, not a constant")
ok(!has(b8$sql(TBL, qc_params(sub("map_discon_gap_days=90", "map_discon_gap_days=77",
                                  SETTINGS, fixed = TRUE), "r")), "< 77"),
   "...and not the per-drug gap, which is a different 90-day rule")
ok(has(SQL$B8, "= 'DISCONTINUATION'"),
   "...and it counts only lines that ended by running out")
# A run-out inside the window is legitimate when the patient came back: the
# return confirms it, so the line keeps DISCONTINUATION and the next line opens.
# B8 has to exempt those or it would fail every confirmed-by-return line.
ok(has(SQL$B8, "LOT_NUM = LAST_LOT_NUM"),
   "B8 fires only where no later line exists - a return confirms the run-out")
ok(has(SQL$B8, "LOT_NUM < 5"),
   "...and exempts the max_lot cap, where no later line would be built anyway")
ok(has(SQL$B9, "= 'DEATH'") && has(SQL$B9, "LOT_BASE_DISCON_DT < LOT_BASE_END_DT"),
   "B9 counts deaths with a strictly earlier run-out - the two readings' gap")
# B8 was info while the confirmation buffer was an unresolved ambiguity between
# two readings. The study team adjudicated in favour of the one that has it and
# the build applies it, so the count is now an invariant: an unconfirmed
# DISCONTINUATION is a line the buffer should have censored.
ok(identical(Filter(function(c_i) identical(c_i$id, "B8"), LOT_QC_CHECKS)[[1]]$severity, "fail"),
   "B8 is an invariant now the buffer is applied, so a row in it fails the run")
ok(identical(Filter(function(c_i) identical(c_i$id, "B9"), LOT_QC_CHECKS)[[1]]$severity, "info"),
   "B9 reports a documented ambiguity, so it can never fail a run")
# B5c asks whether a line covered a transplant inside its own window. The
# build stops reading a line's AUTOs at the first ALLO or CAR-T, so an AUTO
# after one of those is not the line's to cover. Without the censor the check
# fails a correct run: an ALLO on day 9 ends LOT1, and an AUTO on day 20 is
# still inside the 60-day window.
ok(has(SQL$B5c, "NOT EXISTS") && has(SQL$B5c, "x.SCT_TYPE IN ('ALLO', 'CART')"),
   "B5c applies the same ALLO/CAR-T censor the build applies")
ok(has(SQL$B5c, "x.TX_DT <= a.TX_DT"),
   "...only for an event at or before the transplant it is judging")
# And from the day the build censors from. 05b_lot1_sct.R reads LOT1's boundary
# events with >= the line start; 10_lot2_5_base.R reads a later line's with >,
# so the transplant that started that line is not a censor on it. LOT1's rule
# applied everywhere would switch this check off for every CAR-T- and
# ALLO-started line, since the start event would censor everything after it.
ok(has(SQL$B5c, "(l.LOT_NUM = 1  AND x.TX_DT >= l.LOT_START_DT)"),
   "...censoring LOT1 from its start date, as 05b_lot1_sct.R does")
ok(has(SQL$B5c, "(l.LOT_NUM  > 1 AND x.TX_DT >  l.LOT_START_DT)"),
   "...and a later line from the day after, so its own start event is not a censor")
# The exemption follows the run. With the CAR-T induction rule on, an infusion
# inside LOT1's window is part of LOT1 and does not stop the build reading
# LOT1's later AUTOs - so it must not stop this check either.
b5c <- Filter(function(c_i) identical(c_i$id, "B5c"), LOT_QC_CHECKS)[[1]]
noexempt <- qc_params(sub("apply_cart_induction_rule=TRUE",
                          "apply_cart_induction_rule=FALSE", SETTINGS, fixed = TRUE), "r")
ok(P$cart_exempt && has(SQL$B5c, "x.SCT_TYPE = 'CART' AND l.LOT_NUM = 1"),
   "...and exempts an in-induction CAR-T at LOT1 when the run applied that rule")
ok(!noexempt$cart_exempt &&
     !has(b5c$sql(TBL, noexempt), "x.SCT_TYPE = 'CART' AND l.LOT_NUM = 1"),
   "...and does not, when the run did not")
# E5 has one excuse with two conditions, both needed: the build ran out of
# lines and the event trails the last one. Negated, that is the OR below.
# Joined the other way, a trailing event on a patient with room for another
# line fails the date half and goes unreported.
ok(has(SQL$E5, "AND (a.n_lines < 5\n            OR a.dt <= max(l.LOT_BASE_END_DT))"),
   "E5 reports an unassigned transplant unless BOTH conditions excuse it")
# Every claim source in 05_sct.R is bounded to [INDEX_DATE, OBS_END_DT], so
# TX_AUTO_DATES cannot carry an event past the end of follow-up. One that does
# is a broken input, which is why this fails rather than reports.
e5 <- Filter(function(c_i) identical(c_i$id, "E5"), LOT_QC_CHECKS)[[1]]
ok(identical(e5$severity, "fail"),
   "...and a row in it fails the run, since no row can be explained by follow-up")
sct_src <- paste(readLines(file.path(dirname(ROOT), "engine", "R", "steps", "05_sct.R"),
                           warn = FALSE), collapse = "\n")
# Each arm on its own, not a count of the two bounds across the file: totals
# still match after both predicates go from one arm, or after every lower bound
# goes. Each CTE is cut out by name and asked directly.
#
# The arms and the alias each one bounds on. A source added to the union
# without an entry here fails the count below rather than passing unexamined.
SCT_ARMS <- c(med_proc = "m", med_bill = "m", medproc = "mp", med_diag = "d")
unbounded <- character(0)
for (nm in names(SCT_ARMS)) {
  al <- SCT_ARMS[[nm]]
  i <- regexpr(paste0("\n    ", nm, " AS ("), sct_src, fixed = TRUE)
  if (i < 0) { unbounded <- c(unbounded, paste0(nm, " (no such CTE)")); next }
  rest <- substring(sct_src, i)
  j <- regexpr("\n    ),", rest, fixed = TRUE)
  arm <- substring(rest, 1, if (j > 0) j else nchar(rest))
  lo <- has(arm, paste0("cast(", al, ".FST_DT AS date) >= p.INDEX_DATE"))
  hi <- has(arm, paste0("cast(", al, ".FST_DT AS date) <= p.OBS_END_DT"))
  if (!lo || !hi)
    unbounded <- c(unbounded, paste0(nm, " (",
                                     paste(c("no lower bound", "no upper bound")[c(!lo, !hi)],
                                           collapse = ", "), ")"))
}
ok(!length(unbounded),
   if (length(unbounded))
     paste0("...but an SCT claim source is not bounded at both ends: ",
            paste(unbounded, collapse = "; "))
   else "...which rests on each of the four SCT claim sources being bounded at both ends")
# And that those four are the sources. Counting arms is not enough: four
# occurrences of "SELECT * FROM" is equally true of a union that names medproc
# twice and med_diag not at all. So the names are pulled out and compared as a
# multiset.
sct_union <- substring(sct_src, regexpr("combined AS (", sct_src, fixed = TRUE))
sct_union <- substring(sct_union, 1, regexpr("\n    ),", sct_union, fixed = TRUE))
union_arms <- sort(trimws(gsub("^SELECT \\* FROM ", "",
  regmatches(sct_union,
             gregexpr("SELECT \\* FROM [A-Za-z_][A-Za-z0-9_]*", sct_union))[[1]])))
ok(identical(union_arms, sort(names(SCT_ARMS))),
   paste0("...and the union reads exactly those four, once each (found: ",
          paste(union_arms, collapse = ", "), ")"))
# The one case E5 cannot judge, kept as its own number rather than folded in.
# A patient with no line has no ownership to check; that is the funnel's
# reconciliation question, and folding it in would turn a known cohort
# disagreement into a red run indistinguishable from a real orphan.
ok(has(SQL$E5, "WHERE a.n_lines > 0"),
   "E5 asks only about patients who have a line at all")
# And only from the first line onward. The SCT step keeps claims from
# INDEX_DATE and LOT1 opens on the first non-steroid episode, so a transplant
# can land before any line exists. Splitting on whether the patient has a line
# at all would make that mismatch a blocking defect for one patient and a
# reported number for another.
ok(has(SQL$E5, "AND a.dt >= a.first_start"),
   "...and only from the day their first line starts")
e5b <- Filter(function(c_i) identical(c_i$id, "E5b"), LOT_QC_CHECKS)[[1]]
ok(identical(e5b$severity, "warn"),
   "...and E5b reports the rest without failing the run")
ok(has(SQL$E5b, "x.TX_DT < coalesce((SELECT min(c.LOT_START_DT)"),
   "...taking a transplant before the first line and one on a patient with none")
ok(has(SQL$E2, "< 60") && has(SQL$E2, "> 180"),
   "E2 holds a tandem pair to the recorded 60-to-180 band")
ok(has(SQL$E3, "= 180"),
   "E3 counts the pairs sitting exactly on the boundary the two readings differ on")
ok(has(SQL$F3, "KIND = 'progression'") && has(SQL$F3, "count(DISTINCT PATID)"),
   "F3 recomputes the progression rows from the lines rather than trusting them")
# F2 names the final row by KIND. Taking the last non-progression row by
# STEP_NUM is the final row only when one was written, so a funnel that stopped
# early handed over the row above it and the counts matched.
ok(has(SQL$F2, "KIND = 'final'") && !has(SQL$F2, "ORDER BY STEP_NUM"),
   "F2 finds the final row by KIND, not by taking whichever row came last")
ok(has(SQL$F2, "n_final <> 1"),
   "...and a missing or duplicated final row is itself the failure")
ok(has(SQL$F2, "funnel_l <> published_l") && has(SQL$F2, "max(N_LINES)"),
   "...comparing lines as well as patients, which a truncating criterion splits")
# F3's expected rows are generated from max_lot, not discovered from the two
# sides. A missing LOT4 and LOT5 are on neither side of a join, so a join
# compared the rows that were there and passed.
ok(has(SQL$F3, "WITH want AS") && has(SQL$F3, "SELECT 5 AS LOT_NUM"),
   "F3 generates the rows it expects, 1 through max_lot")
ok(has(SQL$F3, "w.LOT_NUM IS NULL") && has(SQL$F3, "coalesce(s.n_rows, 0) <> 1"),
   "...rejecting a line outside that range, and anything other than one row each")
# The cap is the run's, not a constant: a run built at max_lot=3 must not be
# asked for LOT4 and LOT5 rows nobody promised.
capped <- qc_params(sub("max_lot=5", "max_lot=3", SETTINGS, fixed = TRUE), "r")
f3 <- Filter(function(c_i) identical(c_i$id, "F3"), LOT_QC_CHECKS)[[1]]
ok(has(f3$sql(TBL, capped), "SELECT 3 AS LOT_NUM") &&
     !has(f3$sql(TBL, capped), "SELECT 4 AS LOT_NUM"),
   "...and it expects exactly the run's own cap, no more")

cat("\n-- every check is pinned to the run being read --\n")
# A check that reads a run-scoped table without naming the run would mix two
# attempts' rows under one prefix.
for (id in c("F2", "F3", "F4"))
  ok(has(SQL[[id]], "RUN_ID = 'run-abc'"),
     paste0(id, " reads only this run's rows"))

cat("\n-- the report carries what a reader needs to judge it --\n")
res <- data.frame(id = c("A1", "E3"), group = c("Structure", "Transplant"),
                  severity = c("fail", "info"), result = c("pass", "info"),
                  n_bad = c(0, 4), detail = c("", "...abc123"),
                  what = c("length agrees", "boundary pairs"),
                  stringsAsFactors = FALSE)
md <- qc_markdown(res, "run-abc", "ndmm_", P, "")
ok(any(grepl("run-abc", md)), "the report names the run")
ok(any(grepl("LOT1 60 days", md)), "...and the windows it was judged by")
dev <- qc_markdown(res, "run-abc", "melp_reference_", P, "apply_melp_rule=off ()")
ok(any(grepl("Not a contract build", dev)),
   "a deviating run says so on the report, not only on the console")
ok(!any(grepl("Not a contract build", md)),
   "...and a contract build does not")
# The report is a markdown table, so a pipe in a detail string would split a
# cell and silently shift every column after it.
piped <- res; piped$detail[1] <- "a|b"
ok(any(grepl("a/b", qc_markdown(piped, "r", "p_", P, ""), fixed = TRUE)),
   "a pipe in a detail cannot break the table")

cat("\n-- the runner binds to the status table the engine actually writes --\n")
# Read off BUILD_STATUS_COLS rather than restated here: a column renamed in the
# engine has to move this test, not pass it. The runner asked for STATUS and
# ordered by RUN_TIMESTAMP, which are not columns of this table - RUN_TIMESTAMP
# belongs to LOT_RUN_METADATA - so QC against a fresh build died on the query.
RUNNER <- paste(readLines(file.path(ROOT, "run_lot_qc.R"), warn = FALSE), collapse = "\n")
BL <- paste(readLines(file.path(dirname(ROOT), "engine", "R", "build_lot.R"),
                      warn = FALSE), collapse = "\n")
status_cols <- local({
  b <- regmatches(BL, regexpr("BUILD_STATUS_COLS <- c\\((?s).*?\\)", BL, perl = TRUE))
  unique(unlist(regmatches(b, gregexpr("[A-Z][A-Z0-9_]+(?= = \")", b, perl = TRUE))))
})
ok(all(c("STATE", "UPDATED_AT", "RUN_ID") %in% status_cols),
   paste0("LOT_BUILD_STATUS declares STATE and UPDATED_AT (", length(status_cols),
          " columns read from the engine)"))
ok(!("STATUS" %in% status_cols) && !("RUN_TIMESTAMP" %in% status_cols),
   "...and declares neither STATUS nor RUN_TIMESTAMP")
qcq <- regmatches(RUNNER, regexpr("SELECT RUN_ID(?s).*?LIMIT 1", RUNNER, perl = TRUE))
ok(length(qcq) == 1L && has(qcq, "STATE") && has(qcq, "ORDER BY UPDATED_AT"),
   "so the runner selects STATE and orders by UPDATED_AT")
ok(length(qcq) == 1L && !has(qcq, "STATUS,") && !has(qcq, "RUN_TIMESTAMP"),
   "...and names neither of the two columns that are not there")
ok(all(vapply(c("STATE", "CONTRACT_DEVIATIONS", "RUN_ID"),
              function(cl) cl %in% status_cols, logical(1))),
   "...and every column it selects is one the engine writes")

cat("\n-- a check that did not run counts against the exit status --\n")
# The comment beside it promises all three do. n_skip was computed and then
# left out of the sum, so a QC run that skipped every check exited 0.
ok(has(RUNNER, "if (n_fail + n_error + n_skip > 0) quit(status = 1L)"),
   "failures, errors AND skips decide the exit status")

cat("\n", strrep("-", 52), "\n", sep = "")
cat("\n-- a check that could not run is not a check that passed --\n")
{
  # The runner reports an error as its own outcome so a check that could not
  # run cannot be read as one that found nothing. One path missed that: a
  # query returning no N_BAD column reached qc_outcome() with a zero-length
  # value and stopped the runner outright, losing every check after it.
  ok(identical(qc_outcome(0, "fail"), "pass"), "no violations is a pass")
  ok(identical(qc_outcome(3, "fail"), "FAIL"), "a violation of a fail check is a failure")
  ok(identical(qc_outcome(3, "warn"), "warn") &&
       identical(qc_outcome(3, "info"), "info"),
     "and the softer severities score as themselves")
  ok(identical(qc_outcome(NA_real_, "fail"), "error"),
     "a count that came back NA is an error, not a pass")
  ok(identical(qc_outcome(numeric(0), "fail"), "error"),
     "and so is no count at all, rather than stopping the whole run")
  ok(identical(qc_outcome(NULL, "fail"), "error"),
     "including a NULL, which is what a missing column reads as")
}

cat("\n-- the checks, RUN rather than read --\n")
{
  # These are the checks that decide whether a LOT build is trustworthy, and
  # text cannot tell a working one from a WHERE that can never be true.
  source(file.path(ROOT, "tests", "exec_harness.R"))
  source(file.path(ROOT, "tests", "exec_cases.R"))
  # The run's own parameters, built from the recorded settings by the text
  # tests above rather than written out by hand. A list with the wrong field
  # names would leave p$obs_end, p$confirm and the rest empty in the SQL, which
  # still runs and tests a weaker condition than the check states.
  res <- run_exec_cases(LOT_QC_CHECKS, EXEC_CASES, CLEAN_FIXTURE, P, ROOT)
  if (is.null(res)) {
    skip_note("the execution harness could not be run")
  } else if (identical(res, "skip")) {
    skip_note("duckdb or sqlglot is not installed - every executed check below was skipped")
  } else {
    ok(nrow(res) == length(EXEC_CASES),
       sprintf("every planted case ran (%d of %d)", nrow(res), length(EXEC_CASES)))
    # Coverage is part of the claim. A catalogue that grows without a case
    # growing with it is a catalogue back to being read rather than run.
    uncovered <- setdiff(vapply(LOT_QC_CHECKS, function(c_i) c_i$id, character(1)),
                         names(EXEC_CASES))
    ok(length(uncovered) == 0,
       paste0("every check in the catalogue has a planted case",
              if (length(uncovered))
                paste0(" [missing: ", paste(uncovered, collapse = ", "), "]") else ""))
    for (i in seq_len(nrow(res))) {
      r <- res[i, ]
      id <- r$id
      if (!is.na(r$error) && nzchar(r$error)) {
        ok(FALSE, sprintf("%s ran: %s", id, substr(r$error, 1, 60)))
        next
      }
      ok(identical(r$n_clean, "0"),
         sprintf("%s counts nothing on clean data", id))
      # A case may state how many violations its fixture carries. Where it
      # does, the count has to match: a check with several disjuncts still
      # counts something after one of them goes, and "more than zero" cannot
      # tell that a third of it is missing.
      want <- EXEC_CASES[[id]]$n
      got <- suppressWarnings(as.numeric(r$n_planted))
      ok(!is.na(got) && (if (is.null(want)) got > 0 else got == want),
         sprintf("%s counts %s%s", id, EXEC_CASES[[id]]$what,
                 if (is.null(want)) "" else sprintf(" (all %d of them)", want)))
      ok(nzchar(r$detail),
         sprintf("%s names the row it found, so the report can be acted on", id))
    }
    # The masking is what makes a QC report circulatable, and it is only
    # provable by running: the DETAIL is built in SQL.
    dets <- res$detail[nzchar(res$detail)]
    # Case-INSENSITIVE, and the mask is what makes it necessary: the
    # expression lowercases, so a search for the fixture's own "P000001" could
    # never match whatever the mask emitted. Widening the mask to reveal the
    # whole id therefore changed nothing the suite could see.
    ok(length(dets) > 0 && !any(grepl("p000001", tolower(dets), fixed = TRUE)),
       "and no DETAIL carries a whole patient id - every one is masked")
    ok(all(grepl("^[.][.][.]", dets[grepl("[.][.][.]", dets)])),
       "with the mask in the shape the runner documents")
    # And it truncates. Shape alone is not the control: an expression that
    # concatenates "..." onto the whole identifier passes both checks above.
    # The rule is the last six characters, so that is asserted on the masked
    # token - the "..." and the run of characters after it - rather than on the
    # rest of the DETAIL ("...000009 LOT1: length 999").
    tok <- regmatches(dets, regexpr("^[.][.][.][^ ]*", dets))
    kept <- nchar(sub("^[.][.][.]", "", tok))
    ok(length(kept) > 0 && all(kept <= 6L),
       paste0("...and no more than six characters of the id survive the mask",
              if (length(kept) && any(kept > 6L))
                paste0(" [", max(kept), " did: ",
                       paste(utils::head(tok[kept > 6L], 2), collapse = ", "), "]")
              else ""))
  }
}

check_skip_wiring()
test_report_status(pass, fail, skipped)
