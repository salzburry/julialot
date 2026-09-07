#!/usr/bin/env Rscript
# Every check this package can make without a warehouse.
#
#   Rscript tests/run_tests.R
#
# What is checked: the selection logic, the boundary conventions, the counting
# rules, the suppression rule, and that the SQL each module emits carries the
# settings it was given. What is NOT checked is any number - that needs the
# CDM, and the run's own step checks are where it is caught.

here <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (!length(a)) getwd() else dirname(dirname(normalizePath(
    sub("^--file=", "", a[1]))))
})
setwd(here)
suppressMessages({
  for (f in c("config_223926.R", "db_utils_223926.R", "registry.R", "windows.R",
              "person_time.R", "suppression.R", "codelists.R", "lineage.R",
              "run_223926.R"))
    source(file.path("R", f))
  for (f in list.files("R/modules", full.names = TRUE)) source(f)
})

.pass <- 0L; .fail <- character(0)
ok <- function(cond, what) {
  if (isTRUE(cond)) { .pass <<- .pass + 1L; cat("  ok   ", what, "\n") }
  else { .fail <<- c(.fail, what); cat("  FAIL ", what, "\n") }
}
errs <- function(expr) tryCatch({ expr; NA_character_ },
                                error = function(e) conditionMessage(e))
with_env <- function(vars, expr) {
  old <- Sys.getenv(names(vars), unset = NA)
  do.call(Sys.setenv, as.list(vars))
  on.exit({
    for (n in names(vars))
      if (is.na(old[[n]])) Sys.unsetenv(n) else do.call(Sys.setenv,
                                                        setNames(list(old[[n]]), n))
  }, add = TRUE)
  force(expr)
}
base_env <- c(INPUT_COHORT_TABLE = "ndmm_NDMM_COHORT", OBJECT_PREFIX = "s223926_")
cfg0 <- function(extra = c()) with_env(c(base_env, extra), cfg_defaults())

cat("\nconfig and contract\n")
{
  cfg <- cfg0()
  ok(length(contract_deviations(cfg)) == 0,
     "the shipped defaults deviate from the protocol in nothing")
  ok(is.na(errs(check_settings(cfg))), "the shipped defaults validate")
  ok(!is.na(errs(with_env(base_env, .env_enum("X", "nope", c("a", "b"))))),
     "an unrecognised enum stops rather than falling back to a default")
  d <- with_env(c(base_env, BASELINE_DAYS = "180"),
                contract_deviations(cfg_defaults()))
  ok(length(d) == 1 && grepl("baseline_days", d),
     "changing a contract value is reported as a deviation")
  ok(!is.na(errs(with_env(c(base_env, BASELINE_DAYS = "180"),
                          check_contract(cfg_defaults())))),
     "and stops the run without SETTINGS_OVERRIDE")
  ok(is.na(errs(with_env(c(base_env, BASELINE_DAYS = "180",
                           SETTINGS_OVERRIDE = "TRUE"),
                         check_contract(cfg_defaults())))),
     "and proceeds with it")
  ok(!is.na(errs(with_env(c(base_env, ED_DEFINITION = "carrier_pigeon"),
                          check_settings(cfg_defaults())))),
     "an unknown ED construction stops the run")
  ok(!is.na(errs(with_env(c(base_env, ED_DEFINITION = ","),
                          check_settings(cfg_defaults())))),
     "an empty ED construction stops the run rather than finding no visits")
  ok(!is.na(errs(with_env(c(base_env, LOT1_INDEX_FROM = "2017-01-01"),
                          check_settings(cfg_defaults())))),
     "a 1L index floor before the study start stops the run")
  r <- open_question_readings(cfg)
  ok(length(r) == 18 && all(grepl("=", r)),
     "every open question's reading is recorded for the run")
}

cat("\nselection\n")
{
  ok(identical(names(resolve_modules(cfg0())), names(MODULES)),
     "MODULES=all runs every module in dependency order")
  m <- resolve_modules(cfg0(c(MODULES = "safety")))
  ok(identical(names(m), c("spine", "cohorts", "periods", "safety")),
     "asking for one module pulls in exactly what it needs")
  ok(which(names(m) == "periods") < which(names(m) == "safety"),
     "and orders a dependency before its dependant")
  e <- errs(resolve_modules(cfg0(c(MODULES = "patterns", SKIP_MODULES = "soc"))))
  ok(grepl("soc is in SKIP_MODULES but patterns needs it", e),
     "skipping something a selected module needs stops, naming both")
  ok(grepl("unknown module", errs(resolve_modules(cfg0(c(MODULES = "nope"))))),
     "an unknown module name stops the run")
  ok(grepl("nested in 1L", errs(resolve_cohorts(cfg0(c(COHORTS = "2L,3L"))))),
     "a nested cohort without its parent stops the run")
  ok(identical(names(resolve_cohorts(cfg0(c(COHORTS = "3L,1L,2L")))),
               c("1L", "2L", "3L")),
     "cohorts come out in line order however they were asked for")
  s <- resolve_cohorts(cfg0(c(COHORTS = "1L,SEC2L")))$SEC2L
  ok(!("X2_other_cancer" %in% s$criteria),
     "the secondary 2L cohort drops the other-cancer exclusion by default")
  s2 <- resolve_cohorts(cfg0(c(COHORTS = "1L,SEC2L",
                               SEC2L_APPLY_OTHER_CANCER = "TRUE")))$SEC2L
  ok("X2_other_cancer" %in% s2$criteria,
     "and applies it when the setting says to")
  ok(setequal(required_codelists(resolve_modules(cfg0(
       c(MODULES = "spine,cohorts,periods,demographics,tte")))), character(0)),
     "the cohort-and-TTE selection needs no code list this repo lacks")
}

cat("\nwindow conventions\n")
{
  cfg <- cfg0()
  ok(interval_days_sql("a", "b", TRUE, TRUE) == "(datediff(b, a) + 1)",
     "a closed interval counts both endpoints")
  ok(interval_days_sql("a", "b", TRUE, FALSE) == "datediff(b, a)",
     "the protocol's time-to-event convention - index included, event excluded")
  ok(interval_days_sql("a", "b", FALSE, FALSE) == "(datediff(b, a) - 1)",
     "neither endpoint counts")
  bl <- baseline_window_sql("IX", cfg)
  ok(grepl("date_sub(IX, 1)", bl$end, fixed = TRUE) && !bl$includes_index,
     "the baseline ends the day before the index - s7.1")
  blc <- baseline_window_sql("IX", cfg, include_index = TRUE)
  ok(blc$end == "IX", "and includes it for comorbidities - s7.8.1")
  ok(grepl("date_sub(IX, 365)", bl$start, fixed = TRUE),
     "a 12-month window is 365 days by default")
  bc <- baseline_window_sql("IX", cfg0(c(MONTHS_AS = "calendar")))
  ok(grepl("add_months(IX, -12)", bc$start, fixed = TRUE),
     "MONTHS_AS=calendar switches to calendar months")
  ok(grepl("ENDDATE_CE", fu_end_sql(cfg)),
     "follow-up ends at the end of continuous enrolment by default - s7.1")
  ok(!grepl("ENDDATE_CE",
            fu_end_sql(cfg0(c(CENSOR_AT_DISENROLLMENT = "FALSE")))),
     "and does not when the LOT engine's reading is selected instead")
  ok(grepl("date_add(p.INDEX_DATE, 90)", tte_eligible_sql(cfg), fixed = TRUE),
     "the analysis set uses 3 months of potential follow-up")
  lp <- lot_period_sql(cfg)
  ok(grepl("date_add(coalesce(l.LOT_BASE_DISCON_DT, l.LOT_BASE_END_DT), 30)",
           lp$end, fixed = TRUE),
     "the treatment period runs to discontinuation + 30 days")
  ok(grepl("date_sub(l.NEXT_LOT_START_DT, 1)", lp$end, fixed = TRUE),
     "or the day before the next line, whichever is earlier")
  ok(grepl("p.FU_END", lp$end, fixed = TRUE),
     "and never past the end of the patient's follow-up")
  ok(grepl("100000", rate_sql("n", "py", cfg)),
     "a rate is per RATE_MULTIPLIER person-years")
  ok(grepl("50000", rate_sql("n", "py", cfg0(c(RATE_MULTIPLIER = "50000")))),
     "and the multiplier is a setting")
}

cat("\ncounting rules\n")
{
  d <- as.Date(c("2020-01-01", "2020-01-21", "2020-02-10"))
  ok(length(count_acute_greedy(d, 30)) == 2,
     "the washout is measured from the last COUNTED event, so 0/20/40 is two")
  ok(length(count_acute_lag(d, 30)) == 1,
     "and a lag-based reading would say one - they are different rules")
  ok(identical(count_acute_greedy(as.Date(c("2020-01-01", "2020-01-01")), 30),
               as.Date("2020-01-01")),
     "same-day claims are one event")
  ok(length(count_acute_greedy(as.Date(character(0)), 30)) == 0,
     "no events is no events, not an error")
  ok(length(count_acute_greedy(as.Date(c("2020-01-01", "2020-01-31")), 30)) == 2,
     "exactly 30 days apart is two events - the washout is >= 30")
  cl_ok <- data.frame(
    condition = c("chronic_kidney_disease", "corneal_ulcer"),
    acute_chronic = c("Chronic", "Acute"), stringsAsFactors = FALSE)
  ok(is.na(errs(assert_chronic_set(cl_ok))),
     "a code list that types the s7.8.1 conditions chronic passes")
  cl_bad <- data.frame(condition = c("peripheral_neuropathy"),
                       acute_chronic = "Acute", stringsAsFactors = FALSE)
  ok(grepl("names these as chronic", errs(assert_chronic_set(cl_bad))),
     "one that types a named chronic condition acute stops the run")
}

cat("\nsuppression\n")
{
  cfg <- cfg0()
  df <- data.frame(STRATUM = c("a", "b"), N_PATIENTS = c(30, 10),
                   RATE = c(1.5, 9.9), stringsAsFactors = FALSE)
  out <- suppressMessages(apply_suppression(df, cfg = cfg))
  ok(out$SUPPRESSED[2] == 1 && is.na(out$RATE[2]),
     "a stratum below 25 patients is suppressed, values and all")
  ok(out$SUPPRESSED[1] == 0 && out$RATE[1] == 1.5,
     "one above it is untouched")
  ok(nrow(out) == 2,
     "a suppressed row is marked, not deleted - absent and suppressed differ")
  out2 <- suppressMessages(apply_suppression(df, cfg = cfg,
                                             exempt = c(FALSE, TRUE)))
  ok(out2$SUPPRESSED[2] == 0 && out2$RATE[2] == 9.9,
     "the SOC exemption in s7.8 keeps a small stratum")
  ok(grepl("SOC-exempt", out2$SUPPRESSION_REASON[2]),
     "and says why it was kept")
  ok(grepl("no column", errs(apply_suppression(df, "NOPE", cfg))),
     "suppressing on a column that is not there stops the run")
}

cat("\ncode lists\n")
{
  cfg <- cfg0()
  tmp <- tempfile(); dir.create(tmp)
  cfg$codelist_dir <- tmp
  write.csv(data.frame(condition = c("a", "b"), domain = "x",
                       acute_chronic = "Acute", code_type = "ICD10DIAG",
                       code = c("C900", ""), icd_family = "ICD10"),
            file.path(tmp, "safety_events.csv"), row.names = FALSE)
  e <- errs(load_codelist("safety_events.csv", cfg))
  ok(grepl("row\\(s\\) with no code", e),
     "a code list with an unfilled row stops the module that needs it")
  ok(grepl("zero for want of a code list rather than for want of events", e),
     "and says why that matters")
  write.csv(data.frame(condition = "a", domain = "x", acute_chronic = "Acute",
                       code_type = "ICD10DIAG", code = "C900",
                       icd_family = "ICD-XI"),
            file.path(tmp, "safety_events.csv"), row.names = FALSE)
  ok(grepl("icd_family", errs(load_codelist("safety_events.csv", cfg))),
     "an unrecognised ICD family stops the run rather than matching nothing")
  ok(grepl("not a file this package is defined on",
           errs(load_codelist("made_up.csv", cfg))),
     "a filename this package does not know stops the run")
  # Preflight checks existence, so it needs a directory the file is not in.
  empty <- tempfile(); dir.create(empty)
  cfg_empty <- cfg; cfg_empty$codelist_dir <- empty
  mods <- suppressMessages(resolve_modules(cfg0(c(MODULES = "safety"))))
  e2 <- errs(preflight_codelists(mods, cfg_empty))
  ok(grepl("safety_events.csv", e2),
     "preflight names the missing file before the connection is opened")
  unlink(empty, recursive = TRUE)
  ok(grepl("Annex 3", e2),
     "a missing code list names the annex that owes it")
  ok(grepl("MODULES=spine,cohorts,periods,demographics,tte", e2),
     "and the selection that runs without it")
  unlink(tmp, recursive = TRUE)
}

cat("\nsparklyr plumbing\n")
{
  ok(length(split_statements("CREATE TABLE a (x int); INSERT INTO a VALUES (1)")) == 2,
     "a CREATE + INSERT template is split - Spark sql() takes one statement")
  ok(identical(split_statements("SELECT 'a;b' AS x"), "SELECT 'a;b' AS x"),
     "a semicolon inside a quoted literal does not split the statement")
  ok(identical(split_statements("SELECT 'it''s; fine' AS x"),
               "SELECT 'it''s; fine' AS x"),
     "an escaped quote inside a literal does not end the string early")
  ok(length(split_statements("SELECT 1;  ;\n")) == 1,
     "empty statements between semicolons are dropped")
  ok(grepl("one statement", errs(db_q(NULL, "SELECT 1; SELECT 2"))),
     "db_q refuses more than one statement rather than running the first")
  ok(grepl("SPARK_METHOD", errs(cfg0(c(SPARK_METHOD = "carrier_pigeon")))),
     "an unknown SPARK_METHOD stops at config time, before any connection")
  ok(identical(cfg0()$spark_method, "databricks"),
     "the default is the on-cluster session, which authenticates nothing")
  ok(!("pwd" %in% names(cfg0())),
     "no password setting survives the move off ODBC")
}

cat("\nmodule wiring\n")
{
  ok(all(vapply(MODULES, function(m) exists(m$fn, mode = "function"),
                logical(1))),
     "every registered module has the function it names")
  ok(all(vapply(MODULES, function(m)
    all(m$needs %in% names(MODULES)), logical(1))),
     "every declared dependency is a module that exists")
  ok(!any(duplicated(unlist(lapply(MODULES, `[[`, "outputs")))),
     "no two modules claim the same output table")
  ok(all(vapply(MODULES, function(m) length(m$outputs) > 0, logical(1))),
     "every module writes something")
  cfg <- cfg0()
  set_study_config(cfg); cfg$work_schema <- "wk"; set_study_config(cfg)
  ok(wrk("S_TTE") == "hive_metastore.wk.s223926_S_TTE",
     "an output table is catalog + schema + prefix + name")
  ok(cdm_src("medical") == "hive_metastore.clnprw_optum.t_medical_2026q1",
     "a CDM table picks its quarterly suffix from STUDY_END")
  ok(quarter_suffix("2025-06-30") == "2025q2",
     "and the suffix arithmetic is right off a quarter boundary")
  set_study_config(cfg0(c(LOT_PREFIX = "lot_")))
  cfg2 <- study_config(); cfg2$work_schema <- "wk"; set_study_config(cfg2)
  ok(lot_tbl("LOT_LONG_FINAL") == "hive_metastore.wk.lot_LOT_LONG_FINAL",
     "the LOT tables are read by the LOT build's own prefix")
}

cat("\nprotocol readings carried into the SQL\n")
{
  cfg <- cfg0(); cfg$work_schema <- "wk"; set_study_config(cfg)
  sp <- capture.output(print(mod_spine))
  ok(any(grepl("MED_ADD", sp)) && any(grepl("CART_INIT", sp)),
     "IS_PROTOCOL_DISCON unions the engine's three end reasons, per Table 4")
  ok(any(grepl("LOT_LONG_FINAL", sp)),
     "the spine reads the LOT output AFTER the line criteria, not before")
  tt <- capture.output(print(mod_tte))
  ok(any(grepl("IS_PROTOCOL_DISCON", tt)),
     "TTD's event is that union, not the DISCONTINUATION rows alone")
  hc <- capture.output(print(mod_hcru))
  ok(any(grepl("DIAG1", hc)) && any(grepl("DIAG2", hc)),
     "MM-related hospitalisation is a diagnosis in position 1 or 2 - s7.8.1")
  ok(any(grepl("HAS_DISCHARGE", hc)),
     "a stay with no discharge date is counted but kept out of LOS - s7.8.1")
  ml <- capture.output(print(mod_malignancy))
  ok(any(grepl("count\\(\\*\\) >= 2", ml)),
     "a secondary malignancy needs two codes on separate dates - Table 4")
  ok(any(grepl("FIRST_DT", ml)),
     "and is dated at the first of them, not the confirming one")
}

cat("\nregressions from the adversarial review\n")
{
  cfg <- cfg0(); cfg$work_schema <- "wk"; set_study_config(cfg)

  # 1. Every per-cohort module clears its scope before writing, so a re-run
  #    replaces rather than appends. The claim "re-run as often as needed" is
  #    only true because of this.
  per_cohort <- Filter(function(m) isTRUE(m$per_cohort), MODULES)
  no_clear <- Filter(function(m) {
    src <- paste(capture.output(print(get(m$fn, mode = "function"))),
                 collapse = "\n")
    !grepl("prepare_table|CREATE OR REPLACE TABLE", src)
  }, per_cohort)
  ok(length(no_clear) == 0,
     paste0("every per-cohort module clears before writing (offenders: ",
            paste(names(no_clear), collapse = ", "), ")"))
  ok(!any(grepl("CREATE TABLE IF NOT EXISTS",
                unlist(lapply(MODULES, function(m)
                  capture.output(print(get(m$fn, mode = "function"))))))),
     "no module still creates a table inline instead of via prepare_table()")

  # 2. A FROM-clause subquery cannot see a sibling alias.
  hc <- paste(capture.output(print(mod_hcru)), collapse = "\n")
  ok(!grepl("sum\\(p\\.(BASELINE|PERIOD)_PY\\)", hc),
     "the HCRU denominator does not reference an outer alias from a subquery")
  ok(grepl("GROUP BY COHORT, LOT_NUM", hc),
     "and it is grouped by line, not summed across the whole cohort")

  # 3. The lineage guard actually stops.
  lg <- paste(capture.output(print(check_lot_lineage)), collapse = "\n")
  ok(!grepl("checkable", lg),
     "the lineage guard has no always-FALSE condition swallowing its stop()")
  ok(grepl("LINEAGE ERROR: this package will not read", lg, fixed = TRUE),
     "a checked-and-wrong lineage stops unconditionally")
  ok(grepl("lot_allow_unproven_lineage", lg),
     "and the waiver applies only where the status could not be read")
  ok("lot_allow_unproven_lineage" %in% names(cfg0()),
     "LOT_ALLOW_UNPROVEN_LINEAGE is a real setting, not just a message")

  # 4. A nested cohort takes only patients IN its parent.
  ch <- paste(capture.output(print(mod_cohorts)), collapse = "\n")
  ok(grepl("IN_COHORT = 1", ch),
     "the nested-cohort parent join requires the parent's IN_COHORT")
  ok(grepl("s_parent_cohort", ch),
     "and reads the parent through a view, not the table being written")

  # 5. Code types are compared case-insensitively on both sides.
  ok(grepl("code_type_norm", hc),
     "the ED join uses the normalised code type the R check validates")
  ok(grepl("code_type_norm", paste(capture.output(print(register_codelist_view)),
                                   collapse = "\n")),
     "and register_codelist_view publishes it")

  # 6. Time-to-event dates and events are clipped to the follow-up end.
  tt <- paste(capture.output(print(mod_tte)), collapse = "\n")
  ok(grepl("obs_death", tt) && grepl("p.FU_END", tt),
     "OS is clipped to FU_END like TTNT and TTD, not left unbounded")
  ok(grepl("DEATH_DT <= p.FU_END", tt),
     "and a death after follow-up ended is a censoring, not an event")

  # 7 and 8. Malignancy: per-line denominator, and the chronic rule applied.
  ml <- paste(capture.output(print(mod_malignancy)), collapse = "\n")
  ok(grepl("s_malig_prior", ml),
     "a prior malignancy removes the patient from numerator and denominator")
  ok(grepl("GROUP BY p.COHORT, p.LOT_NUM, c.category", ml),
     "and the denominator is per line, not the cohort total")
  ok(!grepl("SELECT max\\(l.LOT_NUM\\) FROM", ml),
     "LOT_AFTER_WHICH is a join, not a non-equality correlated subquery")

  # 9. Patterns knows who died on a LATER line.
  pt <- paste(capture.output(print(mod_patterns)), collapse = "\n")
  ok(grepl("s_line_end", pt) && grepl("DIED_ON_LINE", pt),
     "death is resolved per line, not read off the cohort's index-line TTE row")
  ok(!grepl("t.OS_EVENT", pt),
     "so no later line silently reads a NULL death flag")

  # 10. X2 reaches the nested cohorts through the one they are nested in.
  ok(cohort_applies(COHORTS[["2L"]], "X2_other_cancer"),
     "2L inherits the other-cancer exclusion from 1L")
  ok(cohort_applies(COHORTS[["3L"]], "X2_other_cancer"),
     "and so does 3L")
  sec <- resolve_cohorts(cfg0(c(COHORTS = "1L,SEC2L")))$SEC2L
  ok(!cohort_applies(sec, "X2_other_cancer"),
     "while the secondary 2L cohort, as resolved, does not")
  sec_on <- resolve_cohorts(cfg0(c(COHORTS = "1L,SEC2L",
                                   SEC2L_APPLY_OTHER_CANCER = "TRUE")))$SEC2L
  ok(cohort_applies(sec_on, "X2_other_cancer"),
     "unless the setting puts it back")

  # 11. Every code list a module loads is declared, so preflight can see it.
  loaded <- unique(unlist(lapply(names(MODULES), function(k) {
    src <- paste(capture.output(print(get(MODULES[[k]]$fn, mode = "function"))),
                 collapse = "\n")
    regmatches(src, gregexpr('"[a-z0-9_]+\\.csv"', src))[[1]]
  })))
  loaded <- gsub('"', "", loaded)
  ok(all(loaded %in% required_codelists(MODULES)),
     paste0("every code list a module loads is declared (undeclared: ",
            paste(setdiff(loaded, required_codelists(MODULES)),
                  collapse = ", "), ")"))
  ok("mm_dx.csv" %in% MODULES$hcru$codelists,
     "hcru declares mm_dx.csv, which its MM-related test loads")

  # 12. run_step's zero-row guard can read the first column.
  ok(grepl("count\\(\\*\\) AS n_events", hc),
     "the HCRU QC puts a count first so the zero-row guard is not skipped")

  # 13. An unrecognised or blank ICD family matches neither family.
  rv <- paste(capture.output(print(register_codelist_view)), collapse = "\n")
  ok(grepl("THEN 'ICD10' END", rv) && !grepl("ELSE 'ICD10' END", rv),
     "the code-list side yields NULL for an unknown family, as the claim side does")
  tmp <- tempfile(); dir.create(tmp)
  cfgb <- cfg; cfgb$codelist_dir <- tmp
  write.csv(data.frame(condition = "a", domain = "x", acute_chronic = "Acute",
                       code_type = "ICD10DIAG", code = "C900", icd_family = ""),
            file.path(tmp, "safety_events.csv"), row.names = FALSE)
  ok(grepl("<blank>", errs(load_codelist("safety_events.csv", cfgb))),
     "a blank icd_family is refused, not silently read as ICD-10")
  unlink(tmp, recursive = TRUE)

  # 14. S_ATTRITION is written by something.
  ok("attrition" %in% names(MODULES) &&
     "S_ATTRITION" %in% MODULES$attrition$outputs,
     "the attrition funnel is a module of its own")
  declared <- unlist(lapply(MODULES, `[[`, "outputs"))
  written <- unlist(lapply(names(MODULES), function(k) {
    src <- paste(capture.output(print(get(MODULES[[k]]$fn, mode = "function"))),
                 collapse = "\n")
    Filter(function(o) grepl(o, src, fixed = TRUE), MODULES[[k]]$outputs)
  }))
  ok(setequal(declared, written),
     paste0("every declared output is actually written (never written: ",
            paste(setdiff(declared, written), collapse = ", "), ")"))

  # 15. SOC categorisation is deterministic and not alphabetical.
  sc <- paste(capture.output(print(mod_soc)), collapse = "\n")
  ok(!grepl("max\\(CASE WHEN cl.CL_MED_ABBR IS NOT NULL THEN cl.soc_category", sc),
     "SOC does not pick a category with max(), which sorts alphabetically")
  ok(SOC_PRECEDENCE[1] == "CAR-T",
     "a CAR-T line is a CAR-T line, whatever it was given alongside")
  ok(grepl("N_AGENTS >= 4", sc) && grepl("N_AGENTS = 3", sc),
     "and a size category is decided by the regimen's own agent count")

  # Mine, not the review's.
  ok(!grepl("SELECT \\* FROM %s UNION ALL", rv),
     "the code-list view is not defined in terms of itself when chunked")
  ok(grepl("copy_to", rv),
     "a code list of thousands of rows is copied, not built as SQL text")
  sf <- paste(capture.output(print(mod_safety)), collapse = "\n")
  ok(grepl("canonical_acute_chronic", sf),
     "acute_chronic is resolved to one rule before it reaches SQL")
  ok(!grepl("LIKE '%acute%'", sf, fixed = TRUE),
     "so 'Acute or chronic' is not counted through both counting rules")
  ok(!("index_excluded_abbrs" %in% names(cfg0())),
     "the dead 1L index-agent setting is gone - that rule lives in ndmm/")
  ok("malignancies" %in% PROTOCOL_CHRONIC_CONDITIONS,
     "the s7.8.1 chronic cross-check covers Objective 3's own condition")
  cm <- paste(capture.output(print(mod_comorbidity)), collapse = "\n")
  ok(grepl("supersedes", cm),
     "Charlson applies Quan's hierarchy where the code list declares it")
}

cat("\n", .pass, " passed, ", length(.fail), " failed\n", sep = "")
if (length(.fail)) {
  cat("failed:\n", paste0("  ", .fail, collapse = "\n"), "\n", sep = "")
  quit(status = 1)
}
