#!/usr/bin/env Rscript
# The QC catalogue, checked without a warehouse.
#
#   Rscript "lot/qc/tests/test_lot_qc.R"
#
# Nothing here has run against a warehouse, so what can be tested is the SQL as
# a string, the settings parsing, and the rules that turn a count into a
# verdict. The checks are generated with fake table names and inspected.

ROOT <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                                 fixed = TRUE))) else getwd()
  dirname(d)
})

pass <- 0L; fail <- 0L
ok <- function(cond, what) {
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
            sct = "s.TSCT", attrition = "s.TATTR", meta = "s.TMETA",
            cohort = "s.TCOHORT")
SETTINGS <- paste0(
  "allo_lot_span=single_day|belantamab_med_abbr=BELA|cart_consolidation_days=45|",
  "catalog=hive_metastore|cdm_schema=clnprw_optum|censor_at_disenrollment=FALSE|",
  "codelist_dir=/mnt/code/codelist|dsn=RWDE|induction_window_days=60|",
  "lot_discon_confirm_days=90|lot_n_induction_window_days=30|",
  "map_discon_gap_days=90|max_lot=5|",
  "medical_day_supply=28|melp_advance_days=180|melp_exposure_days=30|",
  "melp_med_abbr=MELP|melp_restart_days=60|melp_sct_days=14|",
  "sct_auto_gap_days=60|sct_auto_window_days=13|sct_tandem_days=180|",
  "tbl_med_diag=med_diagnosis|tbl_med_proc=med_procedure|tbl_medical=medical|",
  "tbl_rx=rx|use_quarterly_tables=TRUE|apply_melp_rule=")
P <- qc_params(SETTINGS, "run-abc")
SQL <- lapply(LOT_QC_CHECKS, function(c_i) c_i$sql(TBL, P))
names(SQL) <- vapply(LOT_QC_CHECKS, function(c_i) c_i$id, character(1))

cat("\n-- the catalogue holds together --\n")
ok(length(LOT_QC_CHECKS) > 0, "there are checks")
ok(isTRUE(check_qc_catalogue()), "the shipped catalogue passes its own validation")
# Ids end up in a report and in a sign-off. Two rows with one id is two
# findings nobody can tell apart afterwards.
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
ok(all(qc_needs() %in% keys), "every declared table is one the runner supplies")

cat("\n-- no patient id leaves in the clear --\n")
# The report is a file that gets circulated. Every check that names a patient
# names the last six characters of the id, and the test is that the masking
# expression is present wherever a raw PATID is selected.
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
# induction_window_days is a suffix of lot_n_induction_window_days. The real
# string is sorted, so the short key happens to come first and would be found
# correctly even by a search with no anchor on it - which means asking it of
# the real string proves nothing. Asked of a string with the long key first,
# an unanchored search reads LOT1's 60-day window as the later-line 30, and
# C1 then passes on every LOT1 regimen drug that joined after day 30.
REVERSED <- "lot_n_induction_window_days=30|induction_window_days=60"
ok(qc_setting(REVERSED, "induction_window_days") == "60" &&
     qc_setting(REVERSED, "lot_n_induction_window_days") == "30",
   "a key that is a suffix of another is not read out of it, whichever comes first")
ok(qc_setting(SETTINGS, "induction_window_days") == "60" &&
     qc_setting(SETTINGS, "lot_n_induction_window_days") == "30",
   "...and the same pair reads correctly out of the real sorted string")
ok(qc_setting(SETTINGS, "allo_lot_span") == "single_day",
   "...the first key in the string is found")
ok(qc_setting(SETTINGS, "apply_melp_rule") == "",
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
# The enum is the build's, not the program spec's. CART_INIT is produced and
# is not in the spec; SUBSTITUTION and MAINTENANCE_END are in the spec and are
# produced by nothing. A5 and B5 are where that is written down.
ok(has(SQL$B5, "'CART_INIT'"), "B5 accepts CART_INIT, which the build writes")
ok(!has(SQL$B5, "'SUBSTITUTION'") && !has(SQL$B5, "'MAINTENANCE_END'"),
   "...and not the two reasons the spec lists that nothing produces")
ok(has(SQL$B6, "LOT_BASE_1ST_ADD_MED_DT < LOT_START_DT"),
   "B6 catches an added-medication date before its own line")
# C1 is the regimen rule asked backwards, so it has to use all three windows.
ok(has(SQL$C1, "THEN 59") && has(SQL$C1, "THEN 44") && has(SQL$C1, "ELSE                                 29"),
   "C1 applies LOT1's window, CAR-T's and the later-line one, each inclusive")
ok(has(SQL$C1, "LEFT JOIN s.TMAP") && has(SQL$C1, "WHERE ms.PATID IS NULL"),
   "...and finds the regimen drugs with no episode in that window")
ok(has(SQL$D3, "= 'STEROID'"),
   "D3 looks for steroids in the episodes, where the spec says they should be")
# The spec keeps steroid claims in the episode data - DEXA is its own worked
# example - and excludes them from lines by class, which the engine does at
# every decision point. So a steroid episode is a spec-consistent state, not a
# defect, and a run over a production list still carrying dexamethasone must
# not fail its QC for it.
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
   "B9 counts deaths with a strictly earlier run-out - the spec-vs-build gap")
# B8 was info while the confirmation buffer was an unresolved ambiguity between
# the spec's own tabs. The study team adjudicated in favour of the tab that has
# it and the build applies it, so the count is now an invariant: an unconfirmed
# DISCONTINUATION is a line the buffer should have censored.
ok(identical(Filter(function(c_i) identical(c_i$id, "B8"), LOT_QC_CHECKS)[[1]]$severity, "fail"),
   "B8 is an invariant now the buffer is applied, so a row in it fails the run")
ok(identical(Filter(function(c_i) identical(c_i$id, "B9"), LOT_QC_CHECKS)[[1]]$severity, "info"),
   "B9 reports a documented ambiguity, so it can never fail a run")
ok(has(SQL$E2, "< 60") && has(SQL$E2, "> 180"),
   "E2 holds a tandem pair to the recorded 60-to-180 band")
ok(has(SQL$E3, "= 180"),
   "E3 counts the pairs sitting exactly on the boundary the two readings differ on")
ok(has(SQL$F3, "KIND = 'progression'") && has(SQL$F3, "count(DISTINCT PATID)"),
   "F3 recomputes the progression rows from the lines rather than trusting them")
ok(has(SQL$F2, "KIND <> 'progression'"),
   "F2 takes the funnel's last step, which the progression rows are not part of")

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
dev <- qc_markdown(res, "run-abc", "melp_as_asked_", P, "apply_melp_rule=as_asked ()")
ok(any(grepl("Not a contract build", dev)),
   "a deviating run says so on the report, not only on the console")
ok(!any(grepl("Not a contract build", md)),
   "...and a contract build does not")
# The report is a markdown table, so a pipe in a detail string would split a
# cell and silently shift every column after it.
piped <- res; piped$detail[1] <- "a|b"
ok(any(grepl("a/b", qc_markdown(piped, "r", "p_", P, ""), fixed = TRUE)),
   "a pipe in a detail cannot break the table")

cat("\n", strrep("-", 52), "\n", sep = "")
cat(sprintf("%d passed, %d failed\n", pass, fail))
if (fail > 0L) quit(status = 1L)
