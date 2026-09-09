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
              "person_time.R", "codelists.R", "lineage.R",
              "run_223926.R"))
    source(file.path("R", f))
  for (f in list.files("R/modules", full.names = TRUE)) source(f)
})

.pass <- 0L; .fail <- character(0)
ok <- function(cond, what) {
  # `cond` is evaluated HERE, not by the caller, so an assertion whose
  # expression raises is a FAILED assertion rather than a dead run. It used to
  # propagate: one mutation made split_statements() throw and the suite
  # stopped with a stack trace, losing every result after it and reporting no
  # count at all.
  cond <- tryCatch(cond, error = function(e) {
    what <<- paste0(what, "  [raised: ", conditionMessage(e), "]")
    FALSE
  })
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

# The modules, run against recorders. Computed once here because several checks
# below read what the run actually emitted rather than what the source says -
# see the "the modules, run against recorders" section for why.
source("tests/emit_sql.R")
RUN <- with_env(base_env, capture_emitted_sql("."))
# A second run with the two switches on, so the tables they write are covered
# too. Their code lists are undelivered, so the fixtures stand in.
RUN_OPT <- with_env(base_env, capture_emitted_sql(".", function(cfg) {
  cfg$frailty <- TRUE; cfg$comorbid_subgroups <- TRUE; cfg
}))
emitted_sql <- function(run = RUN)
  paste(vapply(run$sql, function(x) x$sql, character(1)), collapse = "\n")

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
  ok(length(r) == length(OPEN_QUESTION_SOURCE) &&
     all(nzchar(sub("^[^=]*=", "", r))),
     "every open question's reading is recorded for the run")
  ok(any(grepl("^frailty=", r)) && any(grepl("^comorbid_subgroups=", r)),
     "including whether frailty and the subgroup flags were asked for at all")
  # A reading this package does not apply must SAY so. Nine of these were
  # written onto the metadata row as the reading that produced the numbers
  # while the package applied none of them.
  ok(all(grepl("\\(upstream, ", r[OPEN_QUESTION_SOURCE == "upstream"], fixed = FALSE)),
     "and a reading applied upstream is labelled, not passed off as this run's")
  # ...and labelled with whether anything CHECKED it. With no upstream contract
  # to read, every one is an assertion, and says so.
  ok(all(grepl("\\(upstream, unverified\\)$", r[OPEN_QUESTION_SOURCE == "upstream"])),
     "with nothing to check it against, an upstream reading is marked unverified")
  # With the cohort build's own contract in hand, the value that shaped the
  # data is recorded - and where the two disagree, both are, because the
  # numbers followed the upstream one. STUDY_START is exactly that case today:
  # this package reads s7.1's body, the cohort build reads Figures 1 and 2.
  up <- c(study_start = "2016-01-01", outpatient_window = "90")
  r2 <- open_question_readings(cfg, up)
  ok(any(grepl("^study_start=2016-01-01 \\(upstream, verified; this run was set to 2018-01-01\\)$",
               r2)),
     "a disagreement records the value the cohort was built with, and this run's")
  ok(any(grepl("^mm_dx_outpatient_window_days=90 \\(upstream, verified\\)$", r2)),
     "and an agreement is recorded as verified, with no second value")
  ok(any(grepl("^pregnancy_window=.* \\(upstream, unverified\\)$", r2)),
     "while a rule the upstream contract does not carry stays an assertion")
  ok(length(r2) == length(r) && !any(grepl("upstream", r2[OPEN_QUESTION_SOURCE == "here"])),
     "and nothing this package applies is relabelled by any of it")
  ok(!any(grepl("\\(upstream\\)", r[OPEN_QUESTION_SOURCE == "here"])),
     "while a reading this package applies is not")
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
  s <- resolve_cohorts(cfg0(c(COHORTS = "1L,SEC2L",
                              SEC2L_INPUT_IS_WIDE = "TRUE")))$SEC2L
  ok(!("X2_other_cancer" %in% s$criteria),
     "the secondary 2L cohort drops the other-cancer exclusion on a wide input")
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
  ok(grepl("date_add(coalesce(l.PROTOCOL_DISCON_DT, l.LOT_BASE_END_DT), 30)",
           lp$end, fixed = TRUE),
     "the treatment period runs to discontinuation + 30 days")
  # Follow-up evidence is a per-LINE question. Joined on PATID alone it was
  # counted once against the 1L index and reused, so one claim between a
  # patient's 1L and 2L satisfied the after-2L test and the after-3L test too.
  coh_src <- paste(readLines("R/modules/01_cohorts.R", warn = FALSE),
                   collapse = "\n")
  ok(grepl("fu.PATID = s.PATID AND fu.LOT_NUM = s.LOT_NUM", coh_src,
           fixed = TRUE),
     "follow-up claim evidence is joined at the line grain, not the patient's")
  ok(grepl("GROUP BY l.PATID, l.LOT_NUM", coh_src, fixed = TRUE),
     "and counted at that grain in the first place")

  # The engine's LOT_BASE_DISCON_DT is a CANDIDATE run-out; the cascade can
  # select a different reason and date and leave it populated. Reading it put
  # TTD before the transplant that ended the line. Only 00_spine.R may name it,
  # and only to derive PROTOCOL_DISCON_DT from the selected end.
  discon_readers <- Filter(function(f)
    grepl("LOT_BASE_DISCON_DT", paste(readLines(f, warn = FALSE),
                                      collapse = "\n"), fixed = TRUE),
    c(list.files("R", pattern = "[.]R$", full.names = TRUE),
      list.files("R/modules", pattern = "[.]R$", full.names = TRUE)))
  stray <- setdiff(basename(discon_readers), c("00_spine.R", "windows.R",
                                               "09_tte.R"))
  ok(length(stray) == 0,
     paste0("only the spine derives the discontinuation date from the engine's ",
            "candidate run-out (offenders: ", paste(stray, collapse = ", "), ")"))
  ok(grepl("PROTOCOL_DISCON_DT", paste(readLines("R/modules/09_tte.R",
                                                 warn = FALSE), collapse = "\n"),
           fixed = TRUE),
     "and TTD reads the selected end, not that candidate")
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
  # The threshold itself. The policy it drives is asserted on the emitted
  # release SQL further down - there is no R implementation to test, and a
  # second one would be a policy that does not ship.
  cfg <- cfg0()
  ok(identical(as.integer(cfg$suppress_min_n), 25L),
     "the small-cell floor is 25 patients, as s7.2.3 and s7.8 both say")
  ok("release" %in% vapply(MODULES, `[[`, character(1), "key"),
     "and a module of its own applies it")
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
  # The escape hatch the message offers, checked rather than pinned as a
  # string: a message naming a selection that in fact needs a code list is
  # worse than no message.
  sugg <- regmatches(e2, regexpr("MODULES=[a-z,]+", e2))
  ok(length(sugg) == 1, "and the selection that runs without it")
  ok(length(sugg) == 1 &&
     length(required_codelists(suppressMessages(resolve_modules(
       cfg0(c(MODULES = sub("^MODULES=", "", sugg))))))) == 0,
     "which really does need no code list")
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
  ok(identical(split_statements("-- a; b\nSELECT 1"), "-- a; b\nSELECT 1"),
     "a semicolon in a line comment does not split it either")
  ok(identical(split_statements("/* a; b */ SELECT 1"), "/* a; b */ SELECT 1"),
     "nor one in a block comment")
  ok(identical(split_statements("/* ' */ SELECT 1;SELECT 2"),
               c("/* ' */ SELECT 1", "SELECT 2")),
     "a lone quote inside a block comment does not swallow the rest")
  ok(identical(split_statements("SELECT 'a' || 'b'; SELECT 2"),
               c("SELECT 'a' || 'b'", "SELECT 2")),
     "two literals in a row are two literals, not one escaped quote")
  ok(grepl("unterminated string", errs(split_statements("SELECT 'abc"))),
     "an unterminated literal stops rather than running as SQL")
  ok(grepl("unterminated block", errs(split_statements("/* abc"))),
     "and so does an unterminated block comment")
  # `*/` and `/*` can share a `/`. Read left to right as tokens, the `*/` at
  # the second character takes the `/` the opener needs, and the block comment
  # is never opened - which turns an unterminated comment into an unterminated
  # string. Where a comment closes is looked up separately for this reason.
  ok(grepl("unterminated block", errs(split_statements("**/*'"))),
     "a `*/` before a `/*` does not steal the slash the opener needs")
  ok(identical(split_statements("a b*/*-/'*/"), "a b*/*-/'*/"),
     "...and the comment it opens still closes at the next `*/`")

  # Two latent traps, found by an adversarial pass and closed before anything
  # emitted the shape that would have hit them.
  #
  # 1. Only `'` was tracked. Spark writes a quoted identifier in BACKTICKS and
  #    this package's SQL already uses them; under ANSI mode a double quote is
  #    an identifier too. A `;` inside either cut the statement in half.
  ok(identical(split_statements("SELECT `a;b` AS x"), "SELECT `a;b` AS x"),
     "a semicolon inside a backtick identifier does not split the statement")
  ok(identical(split_statements("SELECT \"a;b\" AS x"), "SELECT \"a;b\" AS x"),
     "nor one inside a double-quoted run")
  ok(identical(split_statements("SELECT `a--b`, \"c/*d\" FROM t"),
               "SELECT `a--b`, \"c/*d\" FROM t"),
     "and a comment marker inside either is not a comment")
  ok(identical(split_statements("SELECT `a``b`; SELECT 2"),
               c("SELECT `a``b`", "SELECT 2")),
     "a doubled backtick is an escaped one, and the real semicolon still splits")
  ok(identical(split_statements("SELECT \"\"\"\" AS x"), "SELECT \"\"\"\" AS x"),
     "a doubled double-quote likewise")
  ok(grepl("unterminated string", errs(split_statements("SELECT `abc"))),
     "an unterminated backtick stops, the same as an unterminated quote")
  # Each quote closes on ITSELF. A backtick does not end a single-quoted
  # literal, or `WHERE x = 'a`b'` would have become two statements at a
  # semicolon after it.
  ok(identical(split_statements("SELECT 'a`b;c' AS x"), "SELECT 'a`b;c' AS x"),
     "a backtick inside a string literal does not close it")
  ok(identical(split_statements("SELECT `a'b;c` AS x"), "SELECT `a'b;c` AS x"),
     "and a quote inside a backtick identifier does not close that")

  # 2. A template ending in a comment emitted that comment as a statement of
  #    its own, and the warehouse would reject it. It surfaces as a failing
  #    run, not as a bug here, which is why it is worth closing early.
  ok(identical(split_statements("SELECT 1; -- trailing note"), "SELECT 1"),
     "a trailing line comment is not sent as a statement of its own")
  ok(identical(split_statements("SELECT 1;\n/* tail */\n"), "SELECT 1"),
     "nor a trailing block comment")
  ok(length(split_statements("-- only a comment")) == 0,
     "a string that is nothing but a comment yields no statement")
  ok(identical(split_statements("-- why\nSELECT 1"), "-- why\nSELECT 1"),
     "while a comment BEFORE code keeps the statement, comment and all")
  ok(identical(split_statements("SELECT '-- not a comment'"),
               "SELECT '-- not a comment'"),
     "and a comment marker inside a literal does not make a statement empty")
  ok(identical(split_statements("/* a */ SELECT 1; /* b */ SELECT 2; /* c */"),
               c("/* a */ SELECT 1", "/* b */ SELECT 2")),
     "so a run of commented statements keeps the two with SQL in them")
  # The split walks the positions that can change state, not every character.
  # Written the other way - append each character to a growing vector - it was
  # quadratic: 30 KB took nearly three seconds, and a run emits 565 statements.
  big <- substr(paste(rep("SELECT a, b FROM t WHERE x = 1 AND y = 2 ", 800),
                      collapse = ""), 1, 30000)
  el <- function(s) min(replicate(3, system.time(split_statements(s))[["elapsed"]]))
  t1 <- el(substr(big, 1, 7500)); t4 <- el(big)
  ok(identical(split_statements(big), trimws(big)),
     "a statement with no semicolon comes back whole")
  ok(t4 < 0.25 && (t1 < 0.02 || t4 < t1 * 12),
     sprintf("and the cost grows with its length, not with its square (7.5KB %.3fs, 30KB %.3fs)",
             t1, t4))
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

cat("\na second build in the same session inherits nothing from the first\n")
{
  # Three pieces of package-level state outlive a build: the config, the
  # code-list manifest, and the input table's columns. A second build that
  # picked any of them up would report an md5 for a file it never opened, or
  # apply an exclusion flag its own input does not carry.
  set_study_config(cfg0())
  assign("mm_dx.csv", list(md5 = "stale", n_rows = 8, n_codes = 8),
         envir = .codelist_seen)
  assign("cols", c("PATID", "NO_PREGNANCY"), envir = .input_cols)
  ok(nrow(codelist_metadata()) == 1 && length(.cohort_cols()) == 2,
     "the state a build leaves behind is readable after it")
  reset_run_state()
  ok(nrow(codelist_metadata()) == 0,
     "reset_run_state() empties the code-list manifest, so nothing is claimed twice")
  ok(identical(.cohort_cols(), character(0)),
     "and forgets the previous input's columns, so no flag carries over")
  ok(grepl("No config", errs(study_config())),
     "and the config, so a step run before set_study_config() says so")
  ok(grepl("reset_run_state\\(\\)",
           paste(deparse(build_223926), collapse = "\n")),
     "and build_223926() calls it before it reads anything")

  # The config is private to this package. The LOT engine keeps its own under
  # the name `cfg` in the global environment; while this one did too, sourcing
  # both in a session left the second to arrive holding the name.
  set_study_config(cfg0())
  assign("cfg", list(catalog = "LOT_ENGINE_CONFIG", work_schema = "lot",
                     object_prefix = "lot_"), envir = globalenv())
  on.exit(rm("cfg", envir = globalenv()), add = TRUE)
  ok(identical(study_config()$catalog, "hive_metastore"),
     "a global `cfg` belonging to another package does not become this one's")
  set_study_config(local({ c2 <- cfg0(); c2$work_schema <- "wk"; c2 }))
  ok(wrk("S_TTE") == "hive_metastore.wk.s223926_S_TTE",
     "...and the table names still resolve off this package's own config")
  rm("cfg", envir = globalenv())
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

  # 1. Every per-cohort module clears its OWN scope before writing, so a
  #    re-run replaces its rows and leaves the other cohorts' alone. The claim
  #    "re-run as often as needed" is only true because of this.
  #
  #    Read off the emitted SQL, not the source. Grepping the function text for
  #    "prepare_table|CREATE OR REPLACE TABLE" accepted the second - which
  #    replaces the WHOLE table, so the 2L pass would delete the 1L rows. That
  #    is the exact failure the check exists to prevent, and it passed.
  per_cohort <- Filter(function(m) isTRUE(m$per_cohort), MODULES)
  pc_declared <- unique(unlist(lapply(per_cohort, `[[`, "outputs")))
  # Both runs, so the tables the two optional modules write are covered too -
  # the default selection never writes S_FRAILTY or S_COMORB_SUBGROUP.
  emitted <- c(vapply(RUN$sql, function(x) x$sql, character(1)),
               vapply(RUN_OPT$sql, function(x) x$sql, character(1)))
  ran <- unique(sub("^step:[^_]*_", "",
                    grep("^step:cohort_", vapply(RUN$sql, function(x) x$tag,
                                                 character(1)), value = TRUE)))
  # Only the outputs these runs actually wrote. A declared table nothing wrote
  # has no rows to scope, and a module can be deselected.
  pc_outputs <- Filter(function(tb)
    any(grepl(sprintf("INSERT INTO \\S*%s(\\s|$)", tb), emitted)), pc_declared)
  ok(length(pc_outputs) >= 15,
     sprintf("the two runs write %d of the %d per-cohort outputs, so what follows is not vacuous",
             length(pc_outputs), length(pc_declared)))
  # The table name ends the identifier, so the pattern requires whitespace or
  # end after it. `\b` does not work here: `_` is a word character, so there is
  # no boundary between the prefix and S_COHORT, and the check matched nothing
  # at all - passing whatever the modules did.
  wiped <- Filter(function(tb)
    any(grepl(sprintf("CREATE OR REPLACE TABLE \\S*%s(\\s|$)", tb), emitted)),
    pc_outputs)
  ok(length(wiped) == 0,
     paste0("no per-cohort output is written with CREATE OR REPLACE, which ",
            "would drop the other cohorts' rows",
            if (length(wiped)) paste0(" [", paste(wiped, collapse = ", "), "]")
            else ""))
  # And each one is cleared for each cohort that ran, by that cohort's key.
  unscoped <- unlist(lapply(pc_outputs, function(tb) {
    miss <- Filter(function(c1) !any(grepl(
      sprintf("DELETE FROM \\S*%s WHERE COHORT = '%s'", tb, c1), emitted)),
      ran)
    if (length(miss)) paste0(tb, " (", paste(miss, collapse = ", "), ")")
  }))
  ok(is.null(unscoped),
     paste0("and every one is cleared for each cohort by that cohort's own key",
            if (!is.null(unscoped))
              paste0(" [not: ", paste(unscoped, collapse = "; "), "]") else ""))
  # The delete a re-run issues names one cohort. An unscoped DELETE against a
  # shared output empties it for everyone.
  bare <- Filter(function(s)
    grepl("^\\s*DELETE FROM", s) && !grepl("WHERE", s), emitted)
  ok(length(bare) == 0,
     paste0("and no output is emptied outright by a DELETE with no WHERE (",
            length(bare), ")"))
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

  # And it is RUN, not read. The three checks above inspect the function's
  # text, which is how a guard survives being defused - the stop() is still
  # printed, it just never fires. So the guard is called against a status row
  # built to be wrong in exactly one field at a time, and each is required to
  # stop.
  # The columns the LOT engine's BUILD_STATUS_COLS actually declares, pinned as
  # literals. This list is the contract, and it is written out here rather than
  # derived from what lineage.R asks for - because the previous version of this
  # test built its fixture from the column names the SELECT used, so it agreed
  # with the SELECT instead of checking it, and a query naming two columns the
  # writer does not create passed every run of this suite.
  LOT_STATUS_COLS <- c("RUN_ID", "INPUT_COHORT_TABLE", "OBJECT_PREFIX", "STATE",
                       "STUDY_END", "CODELIST_WAIVERS_REQUESTED",
                       "CODELIST_WAIVERS_APPLIED", "CONTRACT_DEVIATIONS",
                       "UPDATED_AT")
  lin_sql <- regmatches(lg, regexpr("SELECT[^\"]*FROM %s", lg))
  asked <- if (length(lin_sql)) {
    body <- sub("\\s*FROM %s$", "", sub("^SELECT\\s*", "", lin_sql))
    # The deparsed source carries literal backslash-n where the SQL wrapped.
    body <- gsub("\\\\n", " ", body)
    toupper(trimws(strsplit(gsub("\\s+", " ", body), ",")[[1]]))
  } else character(0)
  ok(length(asked) > 0 && all(asked %in% LOT_STATUS_COLS),
     paste0("the lineage query names only columns the LOT writer declares",
            if (length(setdiff(asked, LOT_STATUS_COLS)))
              paste0(" [absent upstream: ",
                     paste(setdiff(asked, LOT_STATUS_COLS), collapse = ", "),
                     "]") else ""))

  lin_row <- function(...) {
    # Built from the pinned upstream list, so a fixture cannot invent a column.
    r <- as.list(setNames(rep("", length(LOT_STATUS_COLS)), LOT_STATUS_COLS))
    r$RUN_ID <- "r1"; r$STATE <- "complete"
    r$UPDATED_AT <- "2026-09-01 00:00:00"
    r$INPUT_COHORT_TABLE <- cfg0()$input_cohort_table
    r$STUDY_END <- cfg0()$study_end
    utils::modifyList(r, list(...))
  }
  lin_check <- function(...) {
    row <- lin_row(...)
    e <- new.env(parent = environment(check_lot_lineage))
    e$db_q <- function(con, sql) as.data.frame(row, stringsAsFactors = FALSE)
    f <- check_lot_lineage; environment(f) <- e
    errs(f(NULL, cfg0()))
  }
  ok(is.na(lin_check()), "a matching lineage row is accepted")
  ok(grepl("built over", lin_check(INPUT_COHORT_TABLE = "other_tbl") %||% ""),
     "a LOT run built over a different cohort table stops")
  ok(grepl("STUDY_END", lin_check(STUDY_END = "2025-12-31") %||% ""),
     "and so does one whose STUDY_END disagrees")
  ok(!is.na(lin_check(STATE = "failed")),
     "and one that did not finish")

  # The cohort build's own contract, read back. Driven the same way: the
  # function is given a CONTRACT_SETTINGS string and its answer is checked,
  # rather than its source read.
  up_read <- function(s, cfg = cfg0()) {
    e <- new.env(parent = environment(read_upstream_settings))
    said <- character(0)
    e$log_msg <- function(...) said <<- c(said, paste0(...))
    e$db_q <- if (is.null(s)) function(con, sql) stop("TABLE_OR_VIEW_NOT_FOUND")
              else function(con, sql)
                data.frame(CONTRACT_SETTINGS = s, stringsAsFactors = FALSE)
    f <- read_upstream_settings; environment(f) <- e
    list(out = f(NULL, cfg), said = said)
  }
  CS <- "gap_days=30|outpatient_window=90|study_end=2026-03-31|study_start=2016-01-01"
  a <- up_read(CS)
  ok(identical(a$out[["study_start"]], "2016-01-01") &&
       identical(a$out[["outpatient_window"]], "90"),
     "the cohort build's contract string is parsed into its settings")
  ok(any(grepl("the cohort was built with 2016-01-01, this run is set to 2018-01-01",
               a$said, fixed = TRUE)),
     "and a disagreement is named, with both values")
  ok(!any(grepl("outpatient_window", a$said, fixed = TRUE)),
     "while a setting the two agree on is not reported as a disagreement")
  b <- up_read(CS, cfg0(c(STUDY_START = "2016-01-01")))
  ok(!any(grepl("WARNING", b$said)) && any(grepl("verified", b$said)),
     "a run set to the same values as the cohort build reports no disagreement")
  # Not fatal, and not silent. The cohort is what it is; a mismatch is Q1.
  ok(!is.null(a$out), "a disagreement does not stop the run")
  c1 <- up_read(NULL)
  ok(is.null(c1$out) && any(grepl("unverified", c1$said)),
     "an unreadable metadata table leaves the readings unverified, and says so")
  ok(is.null(up_read("")$out) && is.null(up_read("NA")$out),
     "and so does a run that recorded no contract string")
  ok(is.null(up_read("nonsense with no equals")$out),
     "a string in no recognisable shape is not guessed at")
  ok(!is.na(lin_check(UPDATED_AT = "2026-08-01 00:00:00")),
     "and one built before the 2026-08-30 rule change")

  # 4. A nested cohort takes only patients IN its parent.
  ch <- paste(capture.output(print(mod_cohorts)), collapse = "\n")
  ok(grepl("IN_COHORT = 1", ch),
     "the nested-cohort parent join requires the parent's IN_COHORT")
  ok(grepl("s_parent_cohort", ch),
     "and reads the parent through a view, not the table being written")

  # 5. Code types are compared case-insensitively on both sides.
  ok(grepl("code_type_norm", hc),
     "the ED join uses the normalised code type the R check validates")
  cl_sql <- paste(vapply(Filter(function(x) x$tag == "codelist", RUN$sql),
                         function(x) x$sql, character(1)), collapse = "\n")
  ok(nzchar(cl_sql) && grepl("code_type_norm", cl_sql, fixed = TRUE),
     "and the code-list view the run emits publishes it")

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
  sec <- resolve_cohorts(cfg0(c(COHORTS = "1L,SEC2L",
                                SEC2L_INPUT_IS_WIDE = "TRUE")))$SEC2L
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

  # 13. An unrecognised or blank ICD family matches neither family. Read off
  # the statement the run emits, not the function's source - the normalisation
  # used to live inside register_codelist_view(), which the harness stubbed
  # out, so this SQL was never emitted, never parsed and never executed.
  ok(grepl("THEN 'ICD10' END", cl_sql, fixed = TRUE) &&
     !grepl("ELSE 'ICD10' END", cl_sql, fixed = TRUE),
     "the code-list side yields NULL for an unknown family, as the claim side does")
  ok(grepl("upper(regexp_replace(trim(", cl_sql, fixed = TRUE),
     "and normalises its codes the same way the claim side does")
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
  # Read off the statements the run emitted, not the module source: a table
  # written by a helper the module calls is still written, and a table named
  # only in a comment is not.
  declared <- unique(unlist(lapply(MODULES, `[[`, "outputs")))
  all_sql <- paste(emitted_sql(RUN), emitted_sql(RUN_OPT))
  never <- Filter(function(o) !grepl(o, all_sql, fixed = TRUE), declared)
  ok(length(never) == 0,
     paste0("every declared output is actually written (never written: ",
            paste(never, collapse = ", "), ")"))
  # And nothing is written that the registry does not declare: an undeclared
  # table is one nothing downstream knows to look for.
  # Only the qualified names, and matched through the work schema rather than
  # through an `S_` prefix: OBJECT_PREFIX sits between the schema and the name,
  # and a pattern anchored on `.S_` matches nothing at all once it is set - so
  # the check passes by finding nothing, which is the worst way to pass.
  wtgt <- unlist(regmatches(all_sql, gregexpr(
    "(INSERT INTO|MERGE INTO|DELETE FROM|CREATE OR REPLACE TABLE|CREATE TABLE IF NOT EXISTS)[ \n]+\\S+",
    all_sql)))
  written <- unique(sub(paste0("^.*\\.wk\\.", cfg0()$object_prefix), "",
    grep("\\.wk\\.", wtgt, value = TRUE)))
  ok(length(written) > 10,
     paste0("the emitted SQL names the work tables it writes (",
            length(written), " found)"))
  # The run's own scaffolding, which the registry does not and should not own:
  # the metadata row, and the two inputs the runner builds before the modules.
  written <- setdiff(written, c("S_RUN_METADATA", "S_ENROLL_SPANS",
                                "S_FU_CLAIMS"))
  ok(all(written %in% declared),
     paste0("and nothing is written that the registry does not declare (",
            paste(setdiff(written, declared), collapse = ", "), ")"))

  # 15. SOC categorisation is deterministic and not alphabetical.
  sc <- paste(capture.output(print(mod_soc)), collapse = "\n")
  ok(!grepl("max\\(CASE WHEN cl.CL_MED_ABBR IS NOT NULL THEN cl.soc_category", sc),
     "SOC does not pick a category with max(), which sorts alphabetically")
  ok(SOC_PRECEDENCE[1] == "CAR-T",
     "a CAR-T line is a CAR-T line, whatever it was given alongside")
  soc_sql <- paste(vapply(Filter(function(x) grepl("^step:soc_", x$tag), RUN$sql),
                          function(x) x$sql, character(1)), collapse = "\n")
  ok(grepl("N_AGENTS >= 4 AND HAS_CD38_BACKBONE = 1", soc_sql, fixed = TRUE),
     "and a size category is decided by the regimen's own agent count")
  # Both halves of the category name are claims, and both are tested. A
  # LIKE '%anti-CD38%' on the NAME also matches 'Other triplet (non-anti-CD38)',
  # so that category could never be produced.
  ok(!grepl("LIKE '%anti-CD38%'", soc_sql, fixed = TRUE),
     "the anti-CD38 backbone is read off the agents, not off the category name")
  ok(grepl("N_AGENTS  = 3 AND HAS_CD38_BACKBONE = 0", soc_sql, fixed = TRUE),
     "so a non-anti-CD38 triplet can still be one")
  ok(!grepl("N_AGENTS >= 4\n", soc_sql),
     "and a four-agent regimen with no anti-CD38 agent is not called one")

  # Mine, not the review's.
  rv <- paste(capture.output(print(register_codelist_view)), collapse = "\n")
  cl_all <- paste(vapply(Filter(function(x) x$tag == "codelist", RUN$sql),
                         function(x) x$sql, character(1)), collapse = "\n")
  ok(!grepl("UNION ALL", cl_all, fixed = TRUE),
     "the code-list view is not defined in terms of itself when chunked")
  ok(grepl("copy_to", rv),
     "a code list of thousands of rows is copied, not built as SQL text")
  sf <- paste(capture.output(print(mod_safety)), collapse = "\n")
  # Retry safety, through every comment form a statement can start with. A
  # block-comment prefix was classified safe while the line-comment form was
  # not, so an INSERT written that way would have been retried.
  ok(!sql_is_retry_safe("INSERT INTO t VALUES (1)"),
     "a bare INSERT is not retried")
  ok(!sql_is_retry_safe("-- why\nINSERT INTO t VALUES (1)"),
     "nor one behind a line comment")
  ok(!sql_is_retry_safe("/* why */ INSERT INTO t VALUES (1)"),
     "nor one behind a block comment")
  ok(!sql_is_retry_safe("/* a */\n-- b\n  MERGE INTO t USING s ON 1=1"),
     "nor a MERGE behind both")
  ok(sql_is_retry_safe("CREATE OR REPLACE TABLE t AS SELECT 1"),
     "while an idempotent statement still is")
  ok(sql_is_retry_safe("-- note\nDELETE FROM t WHERE COHORT = 'x'"),
     "and so is a scoped delete")
  # Found by an adversarial pass. The classifier read the first verb, and a
  # leading WITH is not a verb: `WITH a AS (...) INSERT INTO t SELECT ...` is
  # a write that read as safe, so it would be RETRIED - the duplicate-on-a-
  # lost-acknowledgement defect this whole guard exists to prevent. Nothing
  # emits that form today, which is exactly why it would go unnoticed.
  ok(!sql_is_retry_safe("WITH a AS (SELECT 1) INSERT INTO t SELECT * FROM a"),
     "a CTE in front of an INSERT does not make it retry-safe")
  ok(!sql_is_retry_safe("WITH a AS (SELECT 1) MERGE INTO t USING a ON 1=1"),
     "nor in front of a MERGE")
  ok(!sql_is_retry_safe("-- c\n/* d */ WITH a AS (SELECT 1) INSERT INTO t SELECT 1"),
     "nor one behind comments as well")
  ok(sql_is_retry_safe("WITH a AS (SELECT 1) SELECT * FROM a"),
     "while a CTE in front of a SELECT still is")
  ok(sql_is_retry_safe("CREATE OR REPLACE TABLE t AS WITH a AS (SELECT 1) SELECT * FROM a"),
     "and a CREATE OR REPLACE whose body happens to use one is unaffected")

  # And db_exec() HONOURS it. The predicate above can be right while the caller
  # ignores it, which is a lost acknowledgement writing the rows twice. Driven
  # through the real db_exec / with_retry: only db_exec_once, the one call that
  # reaches the driver, is replaced.
  exec_calls <- function(sql, fail_times = 0L) {
    seen <- character(0); left <- fail_times
    e <- new.env(parent = environment(db_exec))
    e$db_exec_once <- function(con, s) {
      seen <<- c(seen, s)
      if (left > 0L) { left <<- left - 1L; stop("Connection reset by peer") }
      invisible(1L)
    }
    e$with_retry <- function(fn, ...) {
      repeat {
        out <- tryCatch(fn(), error = function(x) x)
        if (!inherits(out, "error")) return(out)
        if (left <= 0L && !grepl("Connection reset", conditionMessage(out))) stop(out)
        if (left <= 0L && length(seen) > 20L) stop(out)
      }
    }
    f <- db_exec; environment(f) <- e
    err <- tryCatch({ f(NULL, sql); NULL }, error = conditionMessage)
    list(seen = seen, err = err)
  }
  a <- exec_calls("INSERT INTO t VALUES (1)", fail_times = 1L)
  ok(length(a$seen) == 1L && !is.null(a$err),
     "an INSERT that fails is sent once and the run stops, never sent again")
  b <- exec_calls("DELETE FROM t WHERE COHORT = 'x'", fail_times = 1L)
  ok(length(b$seen) == 2L && is.null(b$err),
     "while a scoped DELETE that fails the same way is retried and succeeds")
  c1 <- exec_calls("CREATE TABLE t (x int); INSERT INTO t VALUES (1)")
  ok(length(c1$seen) == 2L && grepl("^CREATE", c1$seen[1]) &&
       grepl("^INSERT", c1$seen[2]),
     "and a two-statement template reaches the driver as two statements, in order")

  # run_step's own guard: a step whose check comes back zero-rowed stops,
  # because nothing downstream can tell that from a real zero.
  step_run <- function(qc_n, allow_empty = FALSE) {
    e <- new.env(parent = environment(run_step))
    e$log_msg <- function(...) invisible(NULL)
    e$db_exec <- function(con, sql) invisible(1L)
    e$db_q <- function(con, sql) data.frame(n = qc_n)
    f <- run_step; environment(f) <- e
    tryCatch({ f(NULL, "s", "SELECT 1", qc = "SELECT count(*) AS n FROM t",
                 allow_empty = allow_empty); NULL },
             error = conditionMessage)
  }
  ok(grepl("produced 0 rows", step_run(0) %||% ""),
     "a step whose check returns zero rows stops the run")
  ok(is.null(step_run(7)),
     "one that returns rows carries on")
  ok(is.null(step_run(0, allow_empty = TRUE)),
     "and a step declared able to produce nothing is allowed to")
  # A step with no check is not a step that passed its check.
  e0 <- new.env(parent = environment(run_step))
  e0$log_msg <- function(...) invisible(NULL)
  e0$db_exec <- function(con, sql) invisible(1L)
  e0$db_q <- function(con, sql) stop("db_q must not be called with no qc")
  f0 <- run_step; environment(f0) <- e0
  ok(is.null(tryCatch({ f0(NULL, "s", "SELECT 1"); NULL }, error = conditionMessage)),
     "and a step given no check does not invent one")

  # Reusing an output prefix across package versions. Inserts are positional,
  # so a table that gained a column fails on the count and one whose column was
  # RENAMED accepts the insert and keeps the old name with the new meaning -
  # which is worse, because nothing fails. Both must stop BEFORE the scope is
  # cleared, or the cohort's rows are deleted and not replaced.
  # A warehouse DESCRIBE always returns types, so the fixture does too; the
  # missing-type response is tested separately below.
  ens <- function(found, types = NULL) {
    if (is.null(types))
      types <- ifelse(found %in% c("N_AT_RISK", "EXTRA"), "int", "string")
    errs(with_env(base_env, {
      env <- new.env(parent = environment(ensure_table))
      env$db_exec <- function(con, sql) invisible(0L)
      env$db_q <- function(con, sql)
        data.frame(col_name = found, data_type = types,
                   stringsAsFactors = FALSE)
      f <- ensure_table; environment(f) <- env
      f(NULL, "t", "PATID string, COHORT string, N_AT_RISK int")
    }))
  }
  ok(is.na(ens(c("PATID", "COHORT", "N_AT_RISK"))),
     "a table already matching the declared shape is written to")
  ok(!is.na(ens(c("PATID", "COHORT"))),
     "one missing a newly added column stops before its rows are cleared")
  ok(grepl("LOT_BASE_DISCON_DT",
           ens(c("PATID", "COHORT", "LOT_BASE_DISCON_DT"),
               c("string", "string", "int")) %||% ""),
     "and a renamed column is caught rather than silently reused")
  ok(!is.na(ens(character(0))),
     "a table whose schema cannot be read is not cleared either")
  # The three bypasses the prefix-only comparison allowed.
  ok(!is.na(ens(c("PATID", "COHORT", "N_AT_RISK", "EXTRA"))),
     "an extra trailing column is caught, not accepted as a matching prefix")
  ens_t <- function(cols, types)
    errs(with_env(base_env, {
      env <- new.env(parent = environment(ensure_table))
      env$db_exec <- function(con, sql) invisible(0L)
      env$db_q <- function(con, sql)
        data.frame(col_name = cols, data_type = types,
                   stringsAsFactors = FALSE)
      f <- ensure_table; environment(f) <- env
      f(NULL, "t", "PATID string, COHORT string, N_AT_RISK int")
    }))
  ok(is.na(ens_t(c("PATID", "COHORT", "N_AT_RISK"),
                 c("varchar", "string", "integer"))),
     "and equivalent type spellings still match")
  ok(!is.na(ens_t(c("PATID", "COHORT", "N_AT_RISK"),
                  c("string", "string", "double"))),
     "while an incompatible type is caught, which names alone could not be")
  # Types that are the same thing spelled differently, against types that are
  # a different thing. Collapsing whole families let a stored FLOAT satisfy a
  # declared DOUBLE, which narrows every rate and person-year written into it,
  # and let a bounded VARCHAR(n) satisfy a declared STRING, which rejects an
  # over-length write only AFTER the scope has been deleted.
  ok(is.na(ens_t(c("PATID", "COHORT", "N_AT_RISK"),
                 c("varchar", "text", "integer"))),
     "unbounded character and integer spellings are the same type")
  ok(!is.na(ens_t(c("PATID", "COHORT", "N_AT_RISK"),
                  c("varchar(2)", "string", "int"))),
     "a bounded VARCHAR(n) is not an unbounded STRING")
  ok(!is.na(ens_t(c("PATID", "COHORT", "N_AT_RISK"),
                  c("char(2)", "string", "int"))),
     "nor is a fixed CHAR(n)")
  ok(!identical(.sql_type_norm("float"), .sql_type_norm("double")),
     "FLOAT is not DOUBLE - single precision would silently narrow a rate")
  ok(!identical(.sql_type_norm("real"), .sql_type_norm("double")),
     "and neither is REAL")
  ok(!identical(.sql_type_norm("timestamp_ntz"), .sql_type_norm("timestamp")),
     "and a zoneless timestamp is not a timestamp")
  ok(identical(.sql_type_norm("double precision"), .sql_type_norm("double")),
     "while genuine spellings of one type still match")
  e_notype <- errs(with_env(base_env, {
    env <- new.env(parent = environment(ensure_table))
    env$db_exec <- function(con, sql) invisible(0L)
    env$db_q <- function(con, sql)
      data.frame(col_name = c("PATID", "COHORT", "N_AT_RISK"),
                 stringsAsFactors = FALSE)
    f <- ensure_table; environment(f) <- env
    f(NULL, "t", "PATID string, COHORT string, N_AT_RISK int")
  }))
  ok(!is.na(e_notype) && grepl("without a type column", e_notype),
     "a DESCRIBE with no type column stops rather than comparing names alone")

  e_read <- errs(with_env(base_env, {
    env <- new.env(parent = environment(ensure_table))
    env$db_exec <- function(con, sql) invisible(0L)
    env$db_q <- function(con, sql) stop("describe blew up")
    f <- ensure_table; environment(f) <- env
    f(NULL, "t", "PATID string")
  }))
  ok(!is.na(e_read) && grepl("could not read the schema", e_read),
     "and a DESCRIBE that fails stops rather than passing as unverifiable")

  # A wide input keeps patients who fail an exclusion so the secondary 2L
  # cohort can have them. IN_COHORT is built from enrolment and follow-up and
  # reads no flag, so without this the SAME record entered the primary 1L
  # cohort - which still excludes prior cancer - alongside SEC2L.
  wide_cols <- c(COHORT_TABLE_REQUIRED, unname(CRITERION_FLAG))
  p1L <- cohort_flag_pred(COHORTS[["1L"]], wide_cols)
  ok(grepl("NO_OTHER_CANCER_PRE_LOT1", p1L, fixed = TRUE),
     "the primary 1L cohort applies its prior-cancer exclusion from the flags")
  sec <- COHORTS[["SEC2L"]]
  sec$criteria <- setdiff(sec$criteria, "X2_other_cancer")
  ok(!grepl("NO_OTHER_CANCER_PRE_LOT1", cohort_flag_pred(sec, wide_cols),
            fixed = TRUE),
     "and the secondary 2L cohort, which permits it, does not")
  ok(grepl("NO_PREGNANCY", cohort_flag_pred(sec, wide_cols), fixed = TRUE),
     "while still applying the exclusions it keeps")
  ok(identical(cohort_flag_pred(COHORTS[["1L"]], COHORT_TABLE_REQUIRED), "1 = 1"),
     "a pre-filtered input carrying no flags is unaffected")
  e_wide <- errs(with_env(base_env, {
    env <- new.env(parent = environment(check_cohort_table))
    env$db_q <- function(con, sql)
      data.frame(col_name = COHORT_TABLE_REQUIRED, stringsAsFactors = FALSE)
    f <- check_cohort_table; environment(f) <- env
    f(NULL, cfg0(c(SEC2L_INPUT_IS_WIDE = "TRUE")))
  }))
  ok(!is.na(e_wide) && grepl("NO_OTHER_CANCER_PRE_LOT1", e_wide),
     "and asserting a wide input without those flags is refused")
  ok(grepl("coalesce(c.NO_OTHER_CANCER_PRE_LOT1, 1) = 1",
           emitted_sql(RUN), fixed = TRUE),
     "the emitted cohort SQL carries that predicate")

  # CAR-T is a protocol SOC category in its own right (s7.2.2), and the LOT
  # engine keeps LOT_CART_LOT_FLG set on a CAR-T line that also carries
  # non-steroid consolidation drugs. Reading the drug string first classified
  # such a line as an ordinary doublet, and that category then propagated into
  # the SOC counts, the patterns and the switch edges. The modality wins.
  soc_src <- paste(readLines("R/modules/05_soc.R", warn = FALSE),
                   collapse = "\n")
  ok(grepl("WHEN CART_FLG = 1 THEN 'CAR-T'", soc_src, fixed = TRUE),
     "a CAR-T line is CAR-T whether or not it recorded consolidation drugs")
  # Order inside the emitted CASE, not inside the file: BEST_CATEGORY is named
  # earlier in the source, in the CTE that computes it.
  soc_sql <- vapply(Filter(function(x) x$tag == "step:soc_1L", RUN$sql),
                    function(x) x$sql, character(1))
  cart_i <- regexpr("WHEN CART_FLG = 1", soc_sql, fixed = TRUE)
  drug_i <- regexpr("WHEN BEST_CATEGORY IS NULL", soc_sql, fixed = TRUE)
  ok(length(soc_sql) == 1 && cart_i > 0 && drug_i > 0 && cart_i < drug_i,
     "and that branch is reached before the drug-category logic")

  # The funnel has to APPLY the exclusions it reports, not merely list them.
  # Membership applies the retained flags; the funnel accumulated only the
  # enrolment and follow-up predicates, so its final N_REMAINING could exceed
  # the cohort it described. The executed reconciliation checks in
  # expectations.py cannot see this on a fixture where every flag is 1, so the
  # accumulation itself is asserted here.
  attr1 <- vapply(Filter(function(x) x$tag == "step:attrition_1L", RUN$sql),
                  function(x) x$sql, character(1))
  ok(length(attr1) == 1 &&
       all(vapply(c("MET_X1 = 1", "MET_X2 = 1", "MET_X3 = 1", "MET_X4 = 1"),
                  function(p) grepl(p, attr1, fixed = TRUE), logical(1))),
     "the 1L funnel applies every exclusion it reports a step for")
  last_arm <- if (length(attr1))
    tail(strsplit(attr1, "UNION ALL", fixed = TRUE)[[1]], 1) else ""
  ok(grepl("MET_X2 = 1", last_arm, fixed = TRUE) &&
       grepl("MET_I5 = 1", last_arm, fixed = TRUE),
     "and its last step carries every criterion above it, so it ends at the cohort")
  attrS <- vapply(Filter(function(x) x$tag == "step:attrition_SEC2L", RUN$sql),
                  function(x) x$sql, character(1))
  ok(length(attrS) == 1 && !grepl("MET_X2 = 1", attrS, fixed = TRUE),
     "while the secondary cohort's funnel does not apply the one it drops")

  # The input contract. A cohort table of patient ids and eligibility flags -
  # which BUILD_DELTA once recommended for the secondary 2L cohort - carries no
  # index date and no end dates, so it cannot drive a single module. It has to
  # be refused at the first step, by name, not five modules later with an
  # unresolved-column error that names neither the table nor the setting.
  flags_only <- c("PATID", "CE_PRE_LOT1_12MO", "CE_LOT1_FU", "NO_BELANTAMAB",
                  "NO_PRIOR_MM_TX", "NO_OTHER_CANCER_PRE_LOT1", "NO_PREGNANCY")
  e_thin <- errs(with_env(base_env, {
    env <- new.env(parent = environment(check_cohort_table))
    env$db_q <- function(con, sql)
      data.frame(col_name = flags_only, stringsAsFactors = FALSE)
    f <- check_cohort_table; environment(f) <- env
    f(NULL, cfg0())
  }))
  ok(!is.na(e_thin) && grepl("INDEX_DATE", e_thin),
     "a cohort table of ids and flags is refused, naming what it lacks")
  e_full <- errs(with_env(base_env, {
    env <- new.env(parent = environment(check_cohort_table))
    env$db_q <- function(con, sql)
      data.frame(col_name = c(COHORT_TABLE_REQUIRED, "EXTRA"),
                 stringsAsFactors = FALSE)
    f <- check_cohort_table; environment(f) <- env
    f(NULL, cfg0())
  }))
  ok(is.na(e_full), "and a table carrying every required column is accepted")

  # Columns are not the contract. The package reads this table as one row per
  # patient and its flags as clean 0/1 verdicts, and both ways of breaking that
  # are silent: a duplicated PATID multiplies that patient through every join,
  # and a NULL flag passes `coalesce(flag, 1) = 1` and admits a patient the
  # exclusion should have dropped.
  cohort_stub <- function(cols = c(COHORT_TABLE_REQUIRED, unname(CRITERION_FLAG)),
                          n_rows = 8, n_patients = 8, n_null_patid = 0,
                          bad = character(0)) {
    function(con, sql) {
      if (grepl("^\\s*DESCRIBE", sql))
        return(data.frame(col_name = cols, stringsAsFactors = FALSE))
      d <- data.frame(n_rows = n_rows, n_patients = n_patients,
                      n_null_patid = n_null_patid)
      for (f in intersect(unname(CRITERION_FLAG), cols))
        d[[paste0("bad_", f)]] <- if (f %in% bad) 3L else 0L
      d
    }
  }
  chk <- function(...) errs(with_env(base_env, {
    env <- new.env(parent = environment(check_cohort_table))
    env$db_q <- cohort_stub(...)
    f <- check_cohort_table; environment(f) <- env
    f(NULL, cfg0())
  }))
  ok(is.na(chk()), "a well-formed cohort table passes the value checks too")
  e_dup <- chk(n_rows = 11, n_patients = 8)
  ok(!is.na(e_dup) && grepl("11 rows for 8 patients", e_dup, fixed = TRUE),
     "a duplicated patient is refused, with both counts named")
  e_np <- chk(n_null_patid = 2)
  ok(!is.na(e_np) && grepl("NULL PATID", e_np, fixed = TRUE),
     "and a NULL PATID, which joins to nothing but is counted anyway")
  e_fl <- chk(bad = "NO_PREGNANCY")
  ok(!is.na(e_fl) && grepl("NO_PREGNANCY (3 row(s))", e_fl, fixed = TRUE),
     "a NULL or non-0/1 exclusion flag is refused, naming the column and the count")
  ok(!is.na(e_fl) && grepl("reads as eligible", e_fl, fixed = TRUE),
     "...and says what it would have done: admitted a patient it should exclude")
  # A pre-filtered input carries no flags, so there is nothing to check there.
  ok(is.na(chk(cols = COHORT_TABLE_REQUIRED)),
     "an input carrying no flags is not asked about flags it does not have")
  # The predicate itself, off the query the run really issues. The stubs above
  # answer with a count and cannot see inside the SQL, so a check narrowed to
  # IS NULL - which would let a 2 or a -1 through - passes them.
  shape_q <- Filter(function(x) x$tag == "query" &&
                      grepl("n_null_patid", x$sql, fixed = TRUE), RUN$sql)
  ok(length(shape_q) >= 1 &&
       grepl("count(DISTINCT PATID) AS n_patients", shape_q[[1]]$sql, fixed = TRUE),
     "the run asks its input's grain before building a cohort")
  ok(length(shape_q) >= 1 &&
       all(vapply(unname(CRITERION_FLAG), function(f)
         grepl(sprintf("%1$s IS NULL OR %1$s NOT IN (0, 1)", f),
               shape_q[[1]]$sql, fixed = TRUE), logical(1))),
     "...and tests every exclusion flag for NULL and for a value outside 0/1")

  # Two endpoints whose DEFINITION this package cannot implement from the code
  # list alone. Both must stop rather than report something else under the
  # protocol's name; the fixtures are the valid form, so the invalid one is
  # constructed here.
  hosp_cl <- data.frame(
    condition = c("severe_infection_resulting_in_hospitalisation", "anemia"),
    domain = c("infectious", "other"), acute_chronic = c("Acute", "Chronic"),
    code_type = "ICD10DIAG", code = c("Z119", "D649"), icd_family = "ICD10",
    stringsAsFactors = FALSE)
  e_hosp <- errs(with_env(base_env, {
    env <- new.env(parent = environment(mod_safety))
    env$load_codelist <- function(...) hosp_cl
    f <- mod_safety; environment(f) <- env
    f(NULL, cfg0(), COHORTS[["1L"]])
  }))
  ok(!is.na(e_hosp) && grepl("defined by an admission", e_hosp),
     "a hospitalisation-defined endpoint stops rather than counting outpatient codes")

  frail_cl <- data.frame(
    variable = c("weight_loss", "durable_medical_equipment"),
    coefficient = c(0.05, 0.1), code_type = c("ICD10DIAG", "HCPCS"),
    code = c("Z400", "E0143"), icd_family = "ICD10", stringsAsFactors = FALSE)
  e_frail <- errs(with_env(base_env, {
    env <- new.env(parent = environment(frailty_index))
    env$load_codelist <- function(...) frail_cl
    f <- frailty_index; environment(f) <- env
    f(NULL, cfg0(), COHORTS[["1L"]])
  }))
  ok(!is.na(e_frail) && grepl("code_type HCPCS", e_frail),
     "a frailty feature this module cannot source stops rather than scoring zero")
  int_cl <- frail_cl; int_cl$variable <- c("intercept", "weight_loss")
  int_cl$code_type <- "ICD10DIAG"
  e_int <- errs(with_env(base_env, {
    env <- new.env(parent = environment(frailty_index))
    env$load_codelist <- function(...) int_cl
    f <- frailty_index; environment(f) <- env
    f(NULL, cfg0(), COHORTS[["1L"]])
  }))
  ok(!is.na(e_int) && grepl("intercept", e_int),
     "and so does an intercept it would apply to nobody")

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

cat("\nstandalone\n")
{
  # Nothing this package runs may reach outside its own directory. The folder
  # is meant to be liftable: handed to someone, or moved, without carrying a
  # trail of siblings it silently needs.
  r_files <- c(list.files("R", pattern = "[.]R$", full.names = TRUE),
               list.files("R/modules", pattern = "[.]R$", full.names = TRUE),
               "build.R")
  src <- setNames(lapply(r_files, function(f) paste(readLines(f, warn = FALSE),
                                                    collapse = "\n")), r_files)
  # Comments and error messages cite sibling documents as evidence, and
  # ../OPEN_QUESTIONS.md resolves inside ndmm_study_updated/, which is the
  # boundary that has to hold. What must not happen is a path FUNCTION reaching
  # outside, so that is what is tested rather than the string ../ anywhere.
  code_only <- lapply(src, function(x)
    paste(grep("^\\s*#", strsplit(x, "\n")[[1]], value = TRUE, invert = TRUE),
          collapse = "\n"))
  path_fns <- "(file[.]path|source|read[.]csv|readRDS|readLines|list[.]files|file[.]exists|normalizePath|setwd)"
  escapes <- names(Filter(function(x)
    grepl(paste0(path_fns, "\\s*\\([^)]*[.][.]/"), x), code_only))
  ok(length(escapes) == 0,
     paste0("no path function reaches out of the package (offenders: ",
            paste(basename(escapes), collapse = ", "), ")"))
  hard <- names(Filter(function(x)
    grepl('"(/mnt|/home|/Users|[A-Z]:)', x), code_only))
  ok(length(hard) == 0,
     paste0("no absolute path is hard-coded (offenders: ",
            paste(basename(hard), collapse = ", "), ")"))
  repo <- names(Filter(function(x)
    grepl('"(Jul 28|docs|Apr 18|Questions)/', x), code_only))
  ok(length(repo) == 0,
     paste0("no code path names a sibling folder (offenders: ",
            paste(basename(repo), collapse = ", "), ")"))
  ok(all(file.exists(file.path("R", "modules", MODULE_FILES))),
     "every module file the runner sources is inside the package")
  ok(setequal(MODULE_FILES, list.files("R/modules", pattern = "[.]R$")),
     "and every file in R/modules/ is one the runner sources")
  ok(FALSE || file.exists("R/load_inputs.R"),
     "load_inputs.R is a copy in the package, not a source() into a sibling")

  # The code lists ship with the package, so it is complete on its own.
  ok(dir.exists("codelists"), "the package carries its own codelists/")
  cfgd <- cfg0()
  ok(!nzchar(cfgd$codelist_dir),
     "CODELIST_DIR defaults to empty, meaning the package's own directory")
  ok(basename(resolve_codelist_dir(cfgd, ".")) == "codelists",
     "and resolve_codelist_dir() points there")
  ok(grepl("elsewhere",
           errs(resolve_codelist_dir(cfg0(c(CODELIST_DIR = "elsewhere")), "."))) ||
     grepl("not a directory",
           errs(resolve_codelist_dir(cfg0(c(CODELIST_DIR = "elsewhere")), "."))),
     "a CODELIST_DIR that does not exist stops the run")
  shipped <- list.files("codelists", pattern = "[.]csv$")
  ok(setequal(shipped, names(CODELIST_SPEC)),
     paste0("every file the spec names ships as a template (missing: ",
            paste(setdiff(names(CODELIST_SPEC), shipped), collapse = ", "), ")"))

  # And every one of them refuses to load, because none is filled in.
  cfgl <- cfgd; cfgl$codelist_dir <- resolve_codelist_dir(cfgd, ".")
  loads <- Filter(function(f) is.na(errs(load_codelist(f, cfgl))),
                  names(CODELIST_SPEC))
  ok(length(loads) == 0,
     paste0("no shipped template loads clean - each is a to-do list the code ",
            "checks (loaded anyway: ", paste(loads, collapse = ", "), ")"))

  # The guard that let a whole blank list through.
  ok(all(names(CODELIST_SPEC) %in% names(CODELIST_CODE_COL)),
     "every code list declares which column carries its code")
  ok(all(vapply(names(CODELIST_SPEC), function(f)
    CODELIST_CODE_COL[[f]] %in% CODELIST_SPEC[[f]], logical(1))),
     "and that column is one of the file's own required columns")
  tmp <- tempfile(); dir.create(tmp)
  write.csv(data.frame(dx = "C900", icd_family = "ICD10"),
            file.path(tmp, "mm_dx.csv"), row.names = FALSE)
  cfgt <- cfgd; cfgt$codelist_dir <- tmp
  ok(is.na(errs(load_codelist("mm_dx.csv", cfgt))),
     "a filled list loads, and the guard reads the column the spec names")
  write.csv(data.frame(dx = "", icd_family = "ICD10"),
            file.path(tmp, "mm_dx.csv"), row.names = FALSE)
  ok(grepl("with no code", errs(load_codelist("mm_dx.csv", cfgt))),
     "and a blank one is refused on the SAME column, not skipped")
  unlink(tmp, recursive = TRUE)

  # Protocol structure that ships filled in, because it is the protocol's and
  # not a code list.
  se <- read.csv("codelists/safety_events.csv", stringsAsFactors = FALSE)
  ok(nrow(se) == 23, "safety_events.csv carries all 23 Table 3 rows")
  ok(all(PROTOCOL_CHRONIC_CONDITIONS[
    PROTOCOL_CHRONIC_CONDITIONS != "malignancies"] %in% se$condition),
     "and every condition the s7.8.1 chronic list names, by that name")
  ok(sum(grepl("or |/", se$acute_chronic)) == 2,
     "including the two the protocol types as both, which stop the run")
  qn <- read.csv("codelists/charlson_quan2011.csv", stringsAsFactors = FALSE)
  ok(nrow(qn) == 17, "charlson_quan2011.csv carries Quan's seventeen conditions")
  ok(qn$weight[qn$condition == "metastatic_solid_tumour"] == 6 &&
     qn$supersedes[qn$condition == "metastatic_solid_tumour"] == "any_malignancy",
     "with Quan's weights and his hierarchy, so mild+severe does not double")
  sm <- read.csv("codelists/secondary_malig.csv", stringsAsFactors = FALSE)
  ok(length(unique(sm$category)) == 10,
     "secondary_malig.csv carries Table 2's ten categories")
  so <- read.csv("codelists/soc_regimen_categories.csv", stringsAsFactors = FALSE)
  ok(setequal(so$soc_category[so$line_scope == "1L"], SOC_CATEGORIES_1L) &&
     setequal(so$soc_category[so$line_scope == "LATER"], SOC_CATEGORIES_LATER),
     "and soc_regimen_categories.csv carries s7.2.2's, both line scopes")
}

# ---------------------------------------------------------------------------
# The modules, actually run.
# ---------------------------------------------------------------------------
#
# Everything above reads source text. Source text cannot tell you whether a
# module's SQL parses or whether its R reaches the end of the function, and
# three defects that shipped were exactly that: a statement chopped in half by
# a semicolon inside a `--` comment, two CTE lists with a comma missing, and a
# `[[` on a name the vector did not carry. So the modules are run here against
# recorders, for every cohort, and every statement they emit is parsed.

cat("\nthe modules, run against recorders\n")
{
  run <- RUN
  ok(length(run$errors) == 0,
     paste0("every module runs for every cohort without an R error",
            if (length(run$errors))
              paste0(" [", paste(sprintf("%s: %s", names(run$errors),
                                         substr(unlist(run$errors), 1, 120)),
                                 collapse = " | "), "]") else ""))
  ok(length(run$sql) > 200,
     paste0("the run emits statements to check (", length(run$sql), ")"))
  ok(setequal(run$modules, names(MODULES)) && setequal(run$cohorts, names(COHORTS)),
     "with every registered module and cohort selected")
  # The secondary 2L cohort cannot be built from a primary-cohort input, and
  # dropping X2 from its criteria LIST does not change who is in it: membership
  # is an inner join onto that table. The refusal is the finding.
  e <- errs(suppressMessages(resolve_cohorts(cfg0(c(COHORTS = "1L,2L,SEC2L")))))
  ok(!is.na(e) && grepl("nested in the primary cohort", e),
     "SEC2L stops the run rather than silently building a nested cohort")
  ok(!is.na(e) && grepl("SEC2L_INPUT_IS_WIDE", e) &&
     grepl("SEC2L_APPLY_OTHER_CANCER", e),
     "and names both ways out")
  ok(is.na(errs(suppressMessages(resolve_cohorts(cfg0(
       c(COHORTS = "1L,2L,SEC2L", SEC2L_APPLY_OTHER_CANCER = "TRUE")))))),
     "building the nested version knowingly is allowed")
  cw <- suppressMessages(resolve_cohorts(cfg0(
    c(COHORTS = "1L,2L,SEC2L", SEC2L_INPUT_IS_WIDE = "TRUE"))))
  ok(!("X2_other_cancer" %in% cw$SEC2L$criteria),
     "and a wide input drops the other-cancer exclusion, as s7.8.1 says")

  # A statement no module can have meant: an unfilled sprintf placeholder, or
  # one that stops mid-clause. Both are checked by tests/parse_sql.py, which
  # needs Python and sqlglot; without them this reports SKIP rather than
  # passing quietly, because a check that cannot run is not a check that passed.
  f <- tempfile(fileext = ".sql")
  con <- file(f, "w")
  for (x in run$sql) {
    cat("-- @@STMT ", x$tag, "\n", sep = "", file = con)
    cat(x$sql, "\n", file = con)
  }
  close(con)
  ok(length(RUN_OPT$errors) == 0,
     paste0("and with FRAILTY and COMORBID_SUBGROUPS on",
            if (length(RUN_OPT$errors))
              paste0(" [", paste(sprintf("%s: %s", names(RUN_OPT$errors),
                                         substr(unlist(RUN_OPT$errors), 1, 120)),
                                 collapse = " | "), "]") else ""))

  out <- suppressWarnings(tryCatch(
    system2("python3", c("tests/parse_sql.py", shQuote(f)),
            stdout = TRUE, stderr = TRUE),
    error = function(e) "NO-PYTHON"))
  txt <- paste(out, collapse = "\n")
  if (any(grepl("^SKIP:", out)) || identical(txt, "NO-PYTHON") ||
      !length(out)) {
    cat("  SKIP  every emitted statement parses as Spark SQL",
        " (python3 + sqlglot not available)\n", sep = "")
  } else {
    ok(grepl("0 failure\\(s\\)", txt),
       paste0("every emitted statement parses as Spark SQL",
              if (!grepl("0 failure", txt)) paste0("\n", txt) else ""))
  }
  unlink(f)

  # The attrition funnel is monotone by construction: a step can only remove
  # rows. It was not - a criterion applied upstream reset the count to the
  # unfiltered total, so N_REMAINING went back up mid-funnel.
  # --- the CDM table names are the warehouse's, not ours -----------------
  #
  # The modules ask cdm_src() for a SHORT name ("diagnosis") because that is
  # what ../DATA_MAPPING.md calls the table in prose. The physical table is
  # `t_med_diagnosis_<quarter>`. That gap shipped: cdm_src() pasted the short
  # name straight in and every module reading a diagnosis pointed at a table
  # that does not exist.
  #
  # Nothing in this suite could catch it. The executing harness creates its
  # fixtures from whatever name the code emits, so it was self-consistently
  # wrong. The only defence is pinning the physical names against the build
  # that has actually run against this warehouse - Jul 28/ndmm/R/config.R -
  # which is why these are literals with a citation rather than derived.
  expected_cdm <- c(medical           = "t_medical",
                    diagnosis         = "t_med_diagnosis",
                    procedure         = "t_med_procedure",
                    rx                = "t_rx",
                    confinement       = "t_confinement",
                    member_enrollment = "t_member_enrollment",
                    member_elig       = "t_member_cont_enrollment",
                    dod               = "t_dod")
  wrong <- Filter(Negate(is.null), lapply(names(expected_cdm), function(k) {
    got <- with_env(base_env, { set_study_config(cfg0()); cdm_src(k) })
    want <- paste0(expected_cdm[[k]], "_", quarter_suffix(cfg0()$study_end))
    if (!endsWith(got, want)) sprintf("%s -> %s (want ...%s)", k, got, want)
    else NULL
  }))
  ok(length(wrong) == 0,
     paste0("every CDM short name resolves to the warehouse's physical table",
            if (length(wrong))
              paste0(" [", paste(unlist(wrong), collapse = "; "), "]") else ""))
  # And nothing emitted names a table that is not one of them.
  emitted_cdm <- unique(unlist(regmatches(emitted_sql(RUN),
    gregexpr("clnprw_optum\\.t_[a-z_]+_[0-9]{4}q[0-9]", emitted_sql(RUN)))))
  emitted_cdm <- sub("^clnprw_optum\\.", "", emitted_cdm)
  emitted_cdm <- sub("_[0-9]{4}q[0-9]$", "", emitted_cdm)
  ok(all(emitted_cdm %in% expected_cdm),
     paste0("and the run reads no CDM table outside that list (",
            paste(setdiff(emitted_cdm, expected_cdm), collapse = ", "), ")"))

  # --- suppression is applied, and its spec is complete -------------------
  #
  # The < 25 rule lived in an R helper that nothing called: every table left
  # the warehouse with raw cell counts. It is a module now, and these check it
  # cannot fall out of step with the tables it suppresses.
  rel_sql <- paste(vapply(Filter(function(x) grepl("^step:release_", x$tag),
                                 run$sql), function(x) x$sql, character(1)),
                   collapse = "\n")
  ok(nzchar(rel_sql), "the suppression rule is applied by a module of its own")
  ok(all(vapply(names(SUPPRESSION_SPEC), function(t)
           grepl(paste0(t, "_RELEASE"), rel_sql, fixed = TRUE), logical(1))),
     "and writes a release table for every table it declares")

  # The policy, not just the plumbing. This SQL is the only place the rule
  # exists - an R helper expressed a DIFFERENT one (it applied s7.8's SOC
  # exemption) and nothing called it, so the suite was green on a policy that
  # never shipped. Asserted here against what the module actually emits.
  #
  # The predicate is READ OUT of the emitted SQL rather than rebuilt here. It
  # used to be rebuilt, and a test that constructs the same string it looks for
  # only ever asserts that the code has not changed - it cannot say the policy
  # is right, and it passed for as long as the rule failed open on a NULL
  # count. What the policy IS is asserted separately, below and by execution.
  min_n <- as.integer(cfg0()$suppress_min_n)
  # Per table, not over the concatenation. Searching all six statements at
  # once found the FIRST "... ELSE N_PATIENTS END" anywhere - which belongs to
  # S_SAFETY_RATES, where N_PATIENTS is a value column suppressed on
  # N_AT_RISK - and read it as S_PATTERNS's own predicate.
  rel_one <- function(tb) {
    hit <- Filter(function(x) identical(x$tag, paste0("step:release_", tolower(tb))),
                  run$sql)
    if (length(hit)) hit[[1]]$sql else ""
  }
  hit_of <- function(tb, sp) {
    txt <- rel_one(tb)
    m <- regmatches(txt, regexpr(
      sprintf("CASE WHEN \\((?:[^()]|\\([^()]*\\))*\\) THEN NULL ELSE %s END", sp$n_col),
      txt, perl = TRUE))
    if (!length(m)) return(NA_character_)
    sub("^CASE WHEN ", "", sub(sprintf(" THEN NULL ELSE %s END$", sp$n_col), "", m[1]))
  }
  pol <- lapply(names(SUPPRESSION_SPEC), function(tb) {
    sp  <- SUPPRESSION_SPEC[[tb]]
    hit <- hit_of(tb, sp)
    if (is.na(hit)) return(list(tbl = tb, hit = FALSE,
                                unnulled = c(sp$n_col, sp$value_cols)))
    # Every column the spec names - the count included - nulled on the same
    # predicate. Publishing the n a suppressed rate came from suppresses
    # nothing.
    nulled <- vapply(c(sp$n_col, sp$value_cols), function(cl)
      grepl(sprintf("CASE WHEN %s THEN NULL ELSE %s END AS %s", hit, cl, cl),
            rel_one(tb), fixed = TRUE), logical(1))
    list(tbl = tb, hit = grepl(hit, rel_sql, fixed = TRUE),
         unnulled = names(nulled)[!nulled])
  })
  bad_hit <- vapply(pol, function(x) !x$hit, logical(1))
  ok(!any(bad_hit),
     paste0("every release table suppresses on its own n below ", min_n,
            if (any(bad_hit)) paste0(" [not: ",
              paste(vapply(pol[bad_hit], `[[`, character(1), "tbl"),
                    collapse = ", "), "]") else ""))
  unnulled <- unlist(lapply(pol, function(x)
    if (length(x$unnulled)) paste0(x$tbl, ".", x$unnulled)))
  ok(is.null(unnulled),
     paste0("and nulls the count with the values, on that same predicate",
            if (!is.null(unnulled))
              paste0(" [left readable: ", paste(unnulled, collapse = ", "), "]")
            else ""))
  # What that predicate SAYS, rather than that it is the same everywhere.
  # A count that cannot be read has not been shown to clear the floor, and
  # this is the last gate before a table leaves the warehouse.
  hits <- vapply(names(SUPPRESSION_SPEC),
                 function(tb) hit_of(tb, SUPPRESSION_SPEC[[tb]]) %||% NA_character_,
                 character(1))
  ok(all(!is.na(hits) & grepl("IS NULL", hits, fixed = TRUE)),
     "a row whose count is NULL is suppressed, not published")
  ok(all(!is.na(hits) & grepl(paste0("< ", min_n), hits, fixed = TRUE)),
     paste0("...and so is one below ", min_n))
  ok(!any(grepl("IS NOT NULL", hits, fixed = TRUE)),
     "...and no table still reads an unknown count as one that passed")
  # Every suppressed table is checked for a group that gives its withheld row
  # away by subtraction. The check was written for S_SAFETY_RATES and named
  # the other five nowhere.
  ok(all(vapply(names(SUPPRESSION_SPEC), function(tb)
           length(SUPPRESSION_SPEC[[tb]]$group_by) > 0L, logical(1))),
     "every suppressed table declares the stratum its rows divide up")
  # The scan is a db_q(), not a step, so it is read off the module's source.
  # What matters is that it walks the spec rather than naming one table.
  mod_src <- paste(readLines("R/modules/11_release.R", warn = FALSE),
                   collapse = "\n")
  ok(grepl("for (tbl in names(SUPPRESSION_SPEC))", mod_src, fixed = TRUE) &&
       grepl("SUPPRESSION_SPEC[[tbl]]$group_by", mod_src, fixed = TRUE),
     "and the recoverable-row scan walks every suppressed table, not one of them")
  ok(!grepl('"S_SAFETY_RATES_RELEASE"', mod_src, fixed = TRUE),
     "...naming none of them, so a new one is covered without an edit here")
  ok(grepl("AS SUPPRESSED", rel_sql, fixed = TRUE) &&
       grepl("AS SUPPRESSION_REASON", rel_sql, fixed = TRUE),
     "...and marks the row rather than dropping it - absent and suppressed differ")
  # s7.8's "(unless specific to SOC)" is not applied. Q29. Pinned so adding it
  # is a deliberate change to a tested rule, not a quiet one.
  ok(!grepl("exempt", rel_sql, ignore.case = TRUE),
     "the SOC exemption is not applied, which is Q29 and not an oversight")
  # The raw table is the one QC reads. Suppressing in place would leave no
  # counts to check a rate against.
  ok(!any(vapply(names(SUPPRESSION_SPEC), function(tb)
            grepl(sprintf("CREATE OR REPLACE TABLE \\S*%s\\b(?!_RELEASE)", tb),
                  rel_sql, perl = TRUE), logical(1))),
     "and writes beside the source table, never over it")
  # Every column the spec names must exist on the table it names, or the
  # suppression silently misses it.
  ddl <- paste(vapply(Filter(function(x)
      grepl("^CREATE TABLE IF NOT EXISTS", x$sql), run$sql),
      function(x) x$sql, character(1)), collapse = "\n")
  missing_cols <- unlist(lapply(names(SUPPRESSION_SPEC), function(t) {
    d <- regmatches(ddl, regexpr(paste0("CREATE TABLE IF NOT EXISTS \\S*", t,
                                        " \\([^;]*?\\)\n"), ddl))
    if (!length(d)) return(paste0(t, ": no DDL"))
    cols <- c(SUPPRESSION_SPEC[[t]]$n_col, SUPPRESSION_SPEC[[t]]$value_cols)
    cols[!vapply(cols, function(cl) grepl(paste0("\\b", cl, "\\b"), d),
                 logical(1))]
  }))
  ok(length(missing_cols) == 0,
     paste0("and every column it suppresses exists on that table",
            if (length(missing_cols))
              paste0(" [missing: ", paste(missing_cols, collapse = ", "), "]")
            else ""))
  # And nothing that publishes a patient count escapes the spec.
  counts <- Filter(function(t) {
    d <- regmatches(ddl, regexpr(paste0("CREATE TABLE IF NOT EXISTS \\S*", t,
                                        " \\([^;]*?\\)\n"), ddl))
    length(d) && grepl("N_PATIENTS", d)
  }, unique(unlist(lapply(MODULES, `[[`, "outputs"))))
  ok(all(counts %in% names(SUPPRESSION_SPEC)),
     paste0("and every table publishing a patient count is in the spec (",
            paste(setdiff(counts, names(SUPPRESSION_SPEC)), collapse = ", "),
            ")"))

  # --- a setting marked "here" must actually change the SQL ---------------
  #
  # The check that makes the label above true rather than a comment: emit the
  # whole run twice, once with the setting at its default and once at an
  # alternative, and require the emitted SQL to DIFFER. A setting that stops
  # being applied - or was never applied - fails here rather than being
  # recorded on every run as the reading that produced the numbers.
  ALTERNATIVES <- list(
    fu_evidence_rule = function(c) { c$fu_evidence_rule <- "claim_after_index"; c },
    sec2l_apply_other_cancer = function(c) {
      c$cohorts <- c("1L", "SEC2L"); c$sec2l_apply_other_cancer <- TRUE; c },
    sec2l_input_is_wide = function(c) {
      c$cohorts <- c("1L", "SEC2L"); c$sec2l_input_is_wide <- TRUE; c },
    censor_at_disenrollment = function(c) { c$censor_at_disenrollment <- FALSE; c },
    months_as = function(c) { c$months_as <- "calendar"; c },
    baseline_includes_index = function(c) { c$baseline_includes_index <- TRUE; c },
    comorbidity_baseline_includes_index =
      function(c) { c$comorbidity_baseline_includes_index <- FALSE; c },
    region_source = function(c) { c$region_source <- "region_column"; c },
    enrol_attr_at = function(c) { c$enrol_attr_at <- "latest_span"; c },
    ed_definition = function(c) { c$ed_definition <- c("revenue", "pos", "cpt"); c },
    ed_admitted = function(c) { c$ed_admitted <- "inpatient_only"; c },
    mm_hosp_position = function(c) { c$mm_hosp_position <- "claim_positions"; c },
    claim_status = function(c) { c$claim_status <- "paid_only"; c },
    frailty = function(c) { c$frailty <- TRUE; c },
    comorbid_subgroups = function(c) { c$comorbid_subgroups <- TRUE; c }
  )
  here_keys <- names(OPEN_QUESTION_SOURCE)[OPEN_QUESTION_SOURCE == "here"]
  ok(setequal(here_keys, names(ALTERNATIVES)),
     "every setting marked as applied here has an alternative to test it with")
  base_sql <- emitted_sql(RUN)
  inert <- character(0)
  for (k in intersect(here_keys, names(ALTERNATIVES))) {
    alt <- with_env(base_env, capture_emitted_sql(".", function(cfg) {
      cfg$sec2l_input_is_wide <- TRUE
      ALTERNATIVES[[k]](cfg)
    }))
    if (identical(emitted_sql(alt), base_sql)) inert <- c(inert, k)
  }
  ok(length(inert) == 0,
     paste0("and changing it changes the SQL the run emits",
            if (length(inert))
              paste0(" [inert: ", paste(inert, collapse = ", "), "]") else ""))

  # --- the statements, executed -----------------------------------------
  #
  # Parsing proves a statement is well formed. It cannot prove a rate is
  # divided by 365.25 rather than 365, that a GROUP BY still carries LOT_NUM,
  # or that a second run does not double every count. Mutation testing put
  # this suite's kill rate at 12% for exactly that reason.
  #
  # So the statements are run: transpiled to DuckDB and executed against the
  # fixtures in tests/fixtures/cdm, whose answers are derived by hand in
  # tests/fixtures/EXPECTED.md. DuckDB is not Spark and this does not replace
  # a run against the warehouse - it is the arithmetic that is being checked,
  # not the dialect.
  sf <- tempfile(fileext = ".sql")
  con <- file(sf, "w")
  for (x in run$sql) {
    cat("-- @@STMT ", x$tag, "\n", sep = "", file = con)
    cat(x$sql, "\n", file = con)
  }
  close(con)
  sd <- file.path(tempdir(), "staged")
  unlink(sd, recursive = TRUE); dir.create(sd, showWarnings = FALSE)
  for (n in names(run$staged))
    utils::write.csv(run$staged[[n]], file.path(sd, paste0(n, ".csv")),
                     row.names = FALSE)
  dout <- suppressWarnings(tryCatch(
    system2("python3", c("tests/run_duckdb.py", shQuote(sf), shQuote(sd),
                         "tests/fixtures/cdm", shQuote(cfg0()$object_prefix)),
            stdout = TRUE, stderr = TRUE),
    error = function(e) "NO-PYTHON"))
  dtxt <- paste(dout, collapse = "\n")
  if (any(grepl("^SKIP:", dout)) || identical(dtxt, "NO-PYTHON") ||
      !length(dout)) {
    cat("  SKIP  the emitted SQL executes and its numbers are right",
        " (python3 + duckdb + sqlglot not available)\n", sep = "")
  } else {
    ok(grepl("0 failed", dtxt) && !grepl("skipped", sub(", 0 skipped", "", dtxt)),
       paste0("every emitted statement executes against the fixtures",
              if (!grepl("0 failed", dtxt)) paste0("\n", dtxt) else ""))
    ok(grepl("0 wrong", dtxt),
       paste0("and every golden number comes out right",
              if (!grepl("0 wrong", dtxt)) paste0("\n", dtxt) else ""))
    ok(grepl("0 of \\d+ table\\(s\\) changed row count", dtxt),
       paste0("and a second run of the whole script doubles nothing",
              if (!grepl("0 of ", dtxt)) paste0("\n", dtxt) else ""))
  }
  unlink(c(sf, sd), recursive = TRUE)

  # --- and the same, with the Q27 route switched -------------------------
  #
  # MM_HOSP_POSITION=claim_positions replaces the whole MM-related subquery
  # with one that reads MED_DIAGNOSIS instead of CONFINEMENT. That SQL is
  # never emitted by the default run, so without this it would be the one
  # statement in the package no harness had ever executed - which is exactly
  # how t_diagnosis, a table name that does not exist, survived 173 tests.
  #
  # Only execution is checked, not the numbers: the fixtures carry no medical
  # claim linked to a confinement, so route B legitimately finds nothing there
  # and the MM-related golden numbers belong to route A.
  altb <- with_env(base_env, capture_emitted_sql(".", function(cfg) {
    cfg$mm_hosp_position <- "claim_positions"; cfg }))
  sfb <- tempfile(fileext = ".sql")
  conb <- file(sfb, "w")
  for (x in altb$sql) {
    cat("-- @@STMT ", x$tag, "\n", sep = "", file = conb)
    cat(x$sql, "\n", file = conb)
  }
  close(conb)
  sdb <- file.path(tempdir(), "staged_b")
  unlink(sdb, recursive = TRUE); dir.create(sdb, showWarnings = FALSE)
  for (n in names(altb$staged))
    utils::write.csv(altb$staged[[n]], file.path(sdb, paste0(n, ".csv")),
                     row.names = FALSE)
  boutx <- suppressWarnings(tryCatch(
    system2("python3", c("tests/run_duckdb.py", shQuote(sfb), shQuote(sdb),
                         "tests/fixtures/cdm", shQuote(cfg0()$object_prefix)),
            stdout = TRUE, stderr = TRUE),
    error = function(e) "NO-PYTHON"))
  btxt <- paste(boutx, collapse = "\n")
  if (any(grepl("^SKIP:", boutx)) || identical(btxt, "NO-PYTHON") ||
      !length(boutx))
    cat("  SKIP  the claim-position route executes too\n")
  else
    ok(grepl("0 failed", btxt),
       paste0("the claim-position route's SQL executes too",
              if (!grepl("0 failed", btxt)) paste0("\n", btxt) else ""))
  unlink(c(sfb, sdb), recursive = TRUE)

  attr_sql <- vapply(Filter(function(x) x$tag == "step:attrition_1L", run$sql),
                     function(x) x$sql, character(1))
  ok(length(attr_sql) == 1,
     "the 1L funnel is one statement, not a query per criterion")
  # One arm per criterion, each counting the cohort table under the predicates
  # accumulated so far.
  arms <- if (length(attr_sql))
    regmatches(attr_sql, gregexpr("SELECT count\\(\\*\\) FROM [^)]*",
                                  attr_sql))[[1]] else character(0)
  ok(length(arms) == length(COHORTS[["1L"]]$criteria),
     "with one count per criterion")
  ok(any(grepl("MET_N2 = 1", arms, fixed = TRUE)),
     "and applies MET_N2, which is I4 re-derived on the line's own index date")
  # Monotone: once a predicate is in, no later arm may drop it. The executing
  # harness checks the resulting NUMBERS are monotone; this checks the SQL
  # cannot express anything else.
  npred <- vapply(arms, function(q)
    lengths(regmatches(q, gregexpr("MET_", q, fixed = TRUE))), integer(1))
  ok(!is.unsorted(npred),
     "and never drops one, so N_REMAINING cannot go back up mid-funnel")
}

cat("\n-- the entry point, in a process that has loaded nothing --\n")
# THIS FILE sources every module before it asserts anything, and that is
# exactly what a production run does not do: build.R loads the common helpers
# and calls build_223926(), which loads the modules itself. So a helper that
# reaches into a module before source_modules() runs is invisible to every
# other assertion here, however many there are - and one did exactly that,
# stopping every fresh build before it read a setting.
#
# The only check that can see it is a real process. DRY_RUN prints the plan
# and returns without a connection, so this costs one R startup and needs no
# warehouse.
local({
  rs <- file.path(R.home("bin"), "Rscript")
  out <- suppressWarnings(system2(rs, shQuote(file.path(here, "build.R")),
    env = c("DRY_RUN=TRUE", "INPUT_COHORT_TABLE=t", "OBJECT_PREFIX=s223926_"),
    stdout = TRUE, stderr = TRUE))
  code <- attr(out, "status")
  ok(is.null(code) || identical(as.integer(code), 0L),
     paste0("build.R resolves and prints a plan in a fresh R process",
            if (!is.null(code))
              paste0("  [exit ", code, ": ",
                     paste(utils::tail(out, 3), collapse = " / "), "]") else ""))
  ok(any(grepl("DRY_RUN=TRUE", out, fixed = TRUE)),
     "...and reaches the dry-run line, rather than exiting somewhere earlier")
  # The failure this replaces was a missing function, which R reports this
  # way. Named so a regression is recognisable rather than just a bad exit.
  ok(!any(grepl("could not find function", out, fixed = TRUE)),
     "...with no helper reaching for something the process has not loaded")
})

cat("\n-- the arithmetic, executed on its own --\n")
# The whole-script harness runs over a seven-patient fixture, so every stratum
# in it is under the 25-patient floor and every rate is suppressed to NULL
# before a golden number could read one. Mutation testing showed what that
# leaves unheld: the rate could be a MULTIPLICATION, the interval a 90% one,
# its bounds swapped, the months divisor 31, the time-to-event boundary off by
# a day with its death arm deleted - and every one of those passed.
#
# So the fragments are executed here against rows built for the rule each one
# states. tests/exec_fragments.R carries the rows and the answers.
source(file.path(here, "tests", "exec_fragments.R"))
local({
  cfg <- cfg0()
  cs  <- frag_cases(cfg)
  qs  <- lapply(cs, function(x)
    sprintf("SELECT ID, %s AS V FROM d ORDER BY ID", x$sql))
  res <- run_fragments(qs, list(d = FRAG_ROWS), root = here)
  if (is.null(res) || identical(res, "skip")) {
    cat("  SKIP  the emitted arithmetic executes",
        " (python3 + duckdb + sqlglot not available)\n", sep = "")
    return(invisible(NULL))
  }
  errs_found <- frag_errors(res)
  ok(!length(errs_found),
     if (length(errs_found))
       paste0("a fragment did not run: ", paste(errs_found, collapse = "; "))
     else "every fragment transpiles and runs on its own")
  for (id in names(cs)) {
    sub  <- res[res$id == id, , drop = FALSE]
    vals <- stats::setNames(sub$value[sub$col == "V"],
                            sub$value[sub$col == "ID"])
    want <- cs[[id]]$want
    bad <- character(0)
    for (k in names(want)) {
      w <- want[[k]]
      g <- if (k %in% names(vals)) vals[[k]] else NA_character_
      same <- if (is.null(w)) identical(g, "")
              else if (is.numeric(w)) {
                gn <- suppressWarnings(as.numeric(g))
                !is.na(gn) && abs(gn - w) < 1e-9
              } else identical(g, as.character(w))
      if (!isTRUE(same))
        bad <- c(bad, sprintf("%s wanted %s, got %s", k,
                              if (is.null(w)) "no value" else format(w),
                              if (is.na(g) || !nzchar(g)) "no value" else g))
    }
    ok(!length(bad), paste0(id, ": ", cs[[id]]$what %||%
                              paste(names(want), collapse = "/"),
                            if (length(bad))
                              paste0("  [", paste(bad, collapse = "; "), "]")
                            else ""))
  }

  # The washout chain, run to convergence the way the module runs it.
  #
  # Days 0, 20 and 40: TWO counted events by a lag() and THREE by the chain,
  # because day 40 is measured against day 0 - the last event that COUNTED -
  # and not against day 20, which did not. That is the whole reason this is a
  # loop, and a single round counts only the first event of each patient and
  # condition.
  w_cfg <- utils::modifyList(cfg, list(acute_washout_days = 30L))
  rounds <- lapply(1:5, function(i)
    acute_washout_round_sql("ev", "pe", "ct", w_cfg, "TREATMENT"))
  qs2 <- stats::setNames(
    c(rounds, list("SELECT cast(EVENT_DT as string) AS DT FROM ct ORDER BY EVENT_DT")),
    c(paste0("round", 1:5), "counted"))
  res2 <- run_fragments(qs2, list(ev = WASHOUT_EVENTS, pe = WASHOUT_PERIODS,
                                  ct = list()), root = here)
  if (is.null(res2) || identical(res2, "skip")) return(invisible(NULL))
  ok(!length(frag_errors(res2)),
     if (length(frag_errors(res2)))
       paste0("the washout round did not run: ",
              paste(frag_errors(res2), collapse = "; "))
     else "the washout round transpiles and runs")
  got <- res2$value[res2$id == "counted" & res2$col == "DT"]
  ok(identical(got, WASHOUT_EXPECT),
     paste0("a >= 30 day washout is measured from the last COUNTED event",
            if (!identical(got, WASHOUT_EXPECT))
              paste0("  [got ", paste(got, collapse = ", "), "]") else ""))
  ok(length(got) == 3L,
     "...so days 0, 20 and 40 are three counted events, where lag() gives two")
  ok(!any(c("2019-12-01", "2020-12-01") %in% got),
     "...and an event outside the period is not counted at either end")
  # One round is not the rule. Re-run from empty with a single round.
  res3 <- run_fragments(
    stats::setNames(list(rounds[[1]],
                         "SELECT cast(EVENT_DT as string) AS DT FROM ct ORDER BY EVENT_DT"),
                    c("round1", "counted")),
    list(ev = WASHOUT_EVENTS, pe = WASHOUT_PERIODS, ct = list()), root = here)
  if (!is.null(res3) && !identical(res3, "skip"))
    ok(length(res3$value[res3$id == "counted" & res3$col == "DT"]) == 1L,
       "...and one round finds only the first, which is why it is a loop")
})

# The two readings of the same rule, over vectors. count_acute_lag() is the
# sensitivity alternative and MUST differ from the chain on this shape, or the
# comparison it exists for is comparing nothing.
{
  d <- WASHOUT_VECTOR
  ok(identical(count_acute_greedy(d, 30), WASHOUT_VECTOR_KEPT),
     "the chain counts days 0 and 40, measuring from the last COUNTED event")
  ok(identical(count_acute_lag(d, 30), d[1]),
     "and the single-pass reading counts only day 0, measuring from the last event")
  ok(!identical(count_acute_greedy(d, 30), count_acute_lag(d, 30)),
     "...so the two readings are genuinely different rules")
  # Day 60 is what separates them: 20 days after the event that counted, and
  # 40 after the one that did not. Three dates cannot tell the two apart.
  ok(!"2020-03-01" %in% as.character(count_acute_greedy(d, 30)),
     "...and the chain measures the fourth event from day 40, so it does not count")
  e <- as.Date(c("2020-01-01", "2020-01-31"))
  ok(identical(count_acute_greedy(e, 30), e),
     "exactly 30 days apart is two events - the washout is >= 30, not > 30")
  ok(identical(count_acute_lag(e, 30), e), "...on either reading")
}

cat("\n", .pass, " passed, ", length(.fail), " failed\n", sep = "")
if (length(.fail)) {
  cat("failed:\n", paste0("  ", .fail, collapse = "\n"), "\n", sep = "")
  quit(status = 1)
}
