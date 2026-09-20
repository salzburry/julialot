#!/usr/bin/env Rscript
# Every check this package can make without a warehouse.
#
#   Rscript tests/run_tests.R
#
# What is checked: the selection logic, the boundary conventions, the counting
# rules, the suppression rule, and that the SQL each module emits carries the
# settings it was given. What is NOT checked is any number - that needs the
# CDM, and the run's own step checks are where it is caught.

# Resolved ONCE, before setwd() below, and both this suite's own path and its
# package root come off it.
#
# They were worked out separately, and the second one after the setwd. The
# --file= Rscript gives for `Rscript variables/tests/run_tests.R` is RELATIVE,
# so resolving it again from the new working directory named
# variables/variables/tests/run_tests.R - a file that does not exist. That is
# the path check_skip_wiring() reads, and it returns quietly when the file is
# missing, so the guard on this suite's skip wiring was off under exactly the
# invocation the delivery README documents. It ran only when the suite was
# started from its own directory, which is the case that needs it least.
.suite_path <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  # Rscript escapes a space in --file= as "~+~", so a path with one comes back
  # naming a directory that does not exist. Undone here, as every other suite
  # beside it does: without it this one ran only from its own directory, and
  # died the moment anything invoked it by absolute path - which is how
  # anything but a person runs it.
  if (!length(a)) NA_character_
  else normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]), fixed = TRUE),
                     mustWork = FALSE)
})
here <- if (is.na(.suite_path)) getwd() else dirname(dirname(.suite_path))
setwd(here)
suppressMessages({
  for (f in c("config_223926.R", "db_utils_223926.R", "registry.R",
              "contract.R", "windows.R",
              "person_time.R", "codelists.R", "lineage.R",
              "run_223926.R"))
    source(file.path("R", f))
  for (f in list.files("R/modules", full.names = TRUE)) source(f)
})

.pass <- 0L; .fail <- character(0)

# Coverage this run did NOT get. A suite whose executed blocks were skipped -
# no python3, no sqlglot, a neighbour package not beside this one - has tested
# a fraction of what it claims, and reporting "0 failed" for it reads as a
# clean run. Each skip is counted and named, and an incomplete run exits
# non-zero unless the caller says it expected one (ALLOW_SKIPPED_TESTS=TRUE).
.skipped <- character(0)
skip_note <- function(what) { .skipped <<- c(.skipped, what); cat("  SKIP  ", what, "\n") }

# The tally is only as good as its wiring: a bare cat("SKIP ...") prints like a
# skip and counts as nothing, which is exactly how the first pass at this went
# wrong - eight sites in one suite and six in another were missed by hand. Each
# suite now checks its OWN source, so a skip site added later is caught by the
# suite it was added to rather than by whoever next reads the diff.
#
# .suite_path is resolved at the top of this file, before the setwd() that
# would make a relative --file= resolve against the wrong directory.
check_skip_wiring <- function(path = .suite_path) {
  # Not run as a script - sourced, or started some way that gives no --file= -
  # so there is no path to read this suite's own source from. That is coverage
  # this run did not get rather than a pass, so it is counted.
  if (is.na(path))
    return(skip_note(paste0("this suite's own source could not be located, ",
                            "so its skip wiring is unchecked")))
  # A path that names no file is different: the suite worked out where it lives
  # and got it wrong, which is a defect in this file rather than a missing
  # capability. It returned quietly before, and two suites that resolved their
  # path AFTER a setwd() spent every run with this guard off - silently, and
  # under exactly the invocation the runbook documents.
  ok(file.exists(path),
     paste0("this suite can find its own source, so its skip wiring is checked",
            if (!file.exists(path)) paste0(" [", path, " is not a file]") else ""))
  if (!file.exists(path)) return(invisible(NULL))
  src <- readLines(path, warn = FALSE)
  # SKIP as a word, so a line that merely NAMES the ALLOW_SKIPPED_TESTS
  # variable is not read as a skip this suite printed.
  bad <- grep('cat\\(.*"[^"]*SKIP(?![A-Za-z_])', src, perl = TRUE)
  # Not a comment describing one, and not skip_note's own printing line.
  bad <- bad[!grepl("^\\s*#", src[bad]) & !grepl("skip_note", src[bad], fixed = TRUE)]
  ok(length(bad) == 0L,
     paste0("every SKIP this suite prints goes through skip_note(), so it is counted",
            if (length(bad)) paste0(" [bare cat at line(s) ", paste(bad, collapse = ", "), "]") else ""))
}
ok <- function(cond, what) {
  # `cond` is evaluated HERE, not by the caller, so an assertion whose
  # expression raises is a FAILED assertion rather than a dead run that loses
  # every result after it.
  cond <- tryCatch(cond, error = function(e) {
    what <<- paste0(what, "  [raised: ", conditionMessage(e), "]")
    FALSE
  })
  if (isTRUE(cond)) { .pass <<- .pass + 1L; cat("  ok   ", what, "\n") }
  else { .fail <<- c(.fail, what); cat("  FAIL ", what, "\n") }
}
errs <- function(expr) tryCatch({ expr; NA_character_ },
                                error = function(e) conditionMessage(e))
# with_env() is the package's own (R/config_223926.R).
# A function with its warehouse calls answered by `env`: the function itself
# and the helpers it reaches the warehouse through, each re-homed in `env` so
# their db_q/db_exec resolve to the stubs. A stub on the function alone does
# not reach describe_columns(), whose real db_q then sits through four retries
# for a package that is not installed.
stubbed <- function(fn, env, also = c("describe_columns", "ensure_columns", "ensure_table")) {
  for (nm in also) { g <- get(nm); environment(g) <- env; assign(nm, g, envir = env) }
  environment(fn) <- env
  fn
}
# The schema variables blank, so a host that carries one of them does not
# decide what a test sees.
base_env <- c(INPUT_COHORT_TABLE = "ndmm_NDMM_COHORT", OBJECT_PREFIX = "s223926_",
              WORK_SCHEMA = "", PROJECT_WORK_SCHEMA = "", DOMINO_USER_NAME = "",
              DOMINO_STARTING_USERNAME = "")
cfg0 <- function(extra = c()) with_env(c(base_env, extra), cfg_defaults())

# The modules, run against recorders. Computed once here because several checks
# below read what the run actually emitted rather than what the source says -
# see the "the modules, run against recorders" section for why.
source("tests/emit_sql.R")
RUN <- with_env(base_env, capture_emitted_sql("."))
# A second run with the two switches on, so the tables they write are covered
# too. Their code lists carry no codes yet, so the fixtures stand in.
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

  # Names that are pasted into SQL unquoted. A value that is not a name used
  # to reach the warehouse and fail there, in its words and after the
  # connection was open; one carrying a semicolon made a statement into two.
  bad_name <- function(...) {
    e <- errs(with_env(c(base_env, ...), check_settings(cfg_defaults())))
    !is.na(e) && grepl("is not a name this package can put in SQL", e, fixed = TRUE)
  }
  good_name <- function(...)
    is.na(errs(with_env(c(base_env, ...), check_settings(cfg_defaults()))))
  ok(bad_name(OBJECT_PREFIX = "bad prefix_") && bad_name(OBJECT_PREFIX = "x;DROP TABLE t;--") &&
       bad_name(OBJECT_PREFIX = "1abc_") && bad_name(OBJECT_PREFIX = "s223926-"),
     "an OBJECT_PREFIX with a space, a semicolon, a leading digit or a hyphen is refused before any SQL is built")
  ok(good_name(OBJECT_PREFIX = "s223926_") && good_name(OBJECT_PREFIX = "_alt") &&
       good_name(OBJECT_PREFIX = "ndmm_"),
     "...while every prefix the documentation uses is accepted")
  ok(bad_name(INPUT_COHORT_TABLE = "a.b.c.d") && bad_name(INPUT_COHORT_TABLE = "my table") &&
       bad_name(INPUT_COHORT_TABLE = "t;--"),
     "an INPUT_COHORT_TABLE with four parts, a space or a semicolon is refused")
  # strsplit() drops a trailing empty piece, so "s223926." split to one clean
  # part and passed - and reached the warehouse with the dot.
  ok(bad_name(OBJECT_PREFIX = "s223926.") && bad_name(INPUT_COHORT_TABLE = "cat.sch.") &&
       bad_name(INPUT_COHORT_TABLE = ".tbl") && bad_name(INPUT_COHORT_TABLE = "a..b"),
     "a trailing, leading or doubled dot is refused too")
  e_rid <- errs(with_env(c(base_env, DOMINO_RUN_ID = "r1'; DROP TABLE t; --"),
                         check_settings(cfg_defaults())))
  ok(!is.na(e_rid) && grepl("DOMINO_RUN_ID", e_rid, fixed = TRUE) &&
       is.na(errs(with_env(c(base_env, DOMINO_RUN_ID = "run-6543_ab.1"),
                           check_settings(cfg_defaults())))),
     "a DOMINO_RUN_ID that is not a plain token is refused, since it names the run in S_RUN_METADATA")
  rsrc_meta <- paste(readLines("R/run_223926.R", warn = FALSE), collapse = "\n")
  ok(grepl("DELETE FROM %s WHERE RUN_ID = %s\", tbl, q(rid)", rsrc_meta, fixed = TRUE),
     "...and it reaches the metadata DELETE escaped, the way it reaches the INSERT")
  ok(grepl("if (!is_sql_name(cfg$work_schema))", rsrc_meta, fixed = TRUE),
     "the schema read back from the session is held to the same rule as one given in the settings")
  ok(good_name(INPUT_COHORT_TABLE = "ndmm_NDMM_COHORT") &&
       good_name(INPUT_COHORT_TABLE = "other_cat.their_schema.NDMM_COHORT"),
     "...while a bare name and a fully qualified one are both accepted")
  ok(bad_name(LOT_PREFIX = "lot prefix_") && bad_name(COHORT_PREFIX = "c.p_") &&
       bad_name(COHORT_STATUS_TABLE = "sch.build_status") &&
       good_name(LOT_PREFIX = "ndmm_") && good_name(COHORT_STATUS_TABLE = "build_status"),
     "the other prefixes and the status table name follow the same rule, and a prefix cannot carry a dot")
  ok(bad_name(TBL_MEDICAL = "cat.sch.medical") && good_name(TBL_MEDICAL = "medical_v2"),
     "a CDM table override is a base name, because the quarter suffix and the schema are put around it")
  ok(bad_name(DATABRICKS_CATALOG = "hive metastore") && bad_name(OPTUM_CDM_SCHEMA = "a.b") &&
       good_name(DATABRICKS_CATALOG = "hive_metastore", OPTUM_CDM_SCHEMA = "clnprw_optum"),
     "and so do the catalog and the CDM schema")
  ok(all(vapply(names(SQL_NAME_SETTINGS), function(k)
           SQL_NAME_SETTINGS[[k]]$key %in% names(cfg0()), logical(1))),
     "every setting the name check names is a real setting")
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
  ok(identical(names(m), c("eligibility", "spine", "cohorts", "periods", "safety")),
     "asking for one module pulls in exactly what it needs, eligibility included - cohorts combines a patient with a line and needs both roots")
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
     "the cohort-and-TTE selection needs no code list at all")
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
  # ...and "3 months" is a month window, so the setting reaches it too. It did
  # not: MONTHS_AS said month windows use add_months(), while this boundary
  # was a fixed 90 days whatever the setting said.
  tc <- tte_eligible_sql(cfg0(c(MONTHS_AS = "calendar")))
  ok(grepl("add_months(p.INDEX_DATE, 3)", tc, fixed = TRUE) &&
       !grepl("date_add", tc, fixed = TRUE),
     "...measured the way MONTHS_AS says, on both of its arms")
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
  # Zero events: the log-normal interval is undefined, and the row used to
  # carry no interval at all. The exact Poisson limits for a count of zero
  # are 0 and -ln(0.025) / PY, scaled like the rate.
  ok(grepl("WHEN n = 0 AND py > 0 THEN 0.0 END", rate_ci_sql("n", "py", cfg, "lo"), fixed = TRUE) &&
       grepl("WHEN n = 0 AND py > 0 THEN 3.688879 / cast(py as double) * 100000 END",
             rate_ci_sql("n", "py", cfg, "hi"), fixed = TRUE),
     "a rate of zero events carries the exact Poisson limits, 0 and 3.688879 / PY")
  ok(grepl("WHEN n > 0 AND py > 0 THEN exp(ln(", rate_ci_sql("n", "py", cfg, "hi"), fixed = TRUE),
     "...and a rate with events keeps the log-normal interval")
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
  cfg_empty$modules <- "safety"
  e2 <- errs(preflight_codelists(mods, cfg_empty))
  ok(grepl("safety_events.csv", e2),
     "preflight names the missing file before the connection is opened")
  ok(grepl("Annex 3", e2),
     "a missing code list names the annex that owes it")
  # MODULES=all asks for everything that CAN run. A module whose list is not
  # usable is left out by name, with what needs it, and the rest runs: the
  # cohort and its attrition need no list and must not wait on Annex 3.
  cfg_all <- cfg_empty; cfg_all$modules <- "all"
  mods_all <- suppressMessages(resolve_modules(cfg_all))
  ran <- suppressMessages(preflight_codelists(mods_all, cfg_all))
  no_list <- c("eligibility", "spine", "cohorts", "attrition", "periods",
               "demographics", "tte")
  ok(identical(names(ran), no_list),
     "with MODULES=all and no usable list, the seven modules that need none run, in order, and nothing stops")
  lo <- attr(ran, "left_out")
  ok(setequal(names(lo), setdiff(names(mods_all), no_list)) &&
       grepl("safety_events.csv", lo[["safety"]]) && grepl("needs", lo[["release"]]) &&
       grepl("soc", lo[["patterns"]]),
     "...the other six are left out by name: those on an unusable list with the file, and those that need one of them with the module")
  ok(any(grepl("left out: ", describe_plan(cfg_all, resolve_cohorts(cfg_all), ran))),
     "...and the plan says so before anything is read")
  # The shipped code lists are shapes without content, so a default run over
  # the package's own codelists/ is exactly this: the cohort, its attrition,
  # windows, demographics and outcomes, and nothing on an unfilled list.
  ran_shipped <- suppressMessages(preflight_codelists(suppressMessages(resolve_modules(cfg0())), cfg))
  ok(identical(names(ran_shipped), no_list) && length(attr(ran_shipped, "left_out")) == 7L,
     "a default run over the shipped lists runs those seven and leaves the seven blocked on the annexes out by name")
  ok(identical(names(suppressMessages(preflight_codelists(
       suppressMessages(resolve_modules(cfg0(c(MODULES = "attrition")))), cfg))),
       c("eligibility", "spine", "cohorts", "attrition")),
     "...and asking for the attrition by name needs no list at all")
  # A list that loads but that its module would refuse: the HCRU list with a
  # CPT row only, under the default ED definition (revenue, pos). Found here,
  # before the connection - not by mod_hcru() after spine, cohorts, attrition,
  # periods and demographics have run for three cohorts and the run is left
  # recorded as failed.
  cdir <- tempfile(); dir.create(cdir)
  file.copy(list.files("codelists", full.names = TRUE), cdir)
  file.copy("tests/fixtures/codelists/mm_dx.csv", file.path(cdir, "mm_dx.csv"), overwrite = TRUE)
  writeLines(c("concept,code_type,code", "ED_VISIT,CPT,99285"), file.path(cdir, "hcru.csv"))
  cfg_cpt <- cfg; cfg_cpt$codelist_dir <- cdir; cfg_cpt$modules <- "all"
  ran_cpt <- suppressMessages(preflight_codelists(suppressMessages(resolve_modules(cfg_cpt)), cfg_cpt))
  ok(!"hcru" %in% names(ran_cpt) &&
       grepl("ED_DEFINITION asks for revenue, pos", attr(ran_cpt, "left_out")[["hcru"]]),
     "a list its module would refuse - an ED definition the HCRU list has no rows for - is left out by name before the connection, not after the modules before it have run")
  cfg_cpt$modules <- "hcru"
  e_cpt <- errs(preflight_codelists(suppressMessages(resolve_modules(cfg_cpt)), cfg_cpt))
  ok(grepl("module hcru", e_cpt) && grepl("ED_DEFINITION asks for revenue, pos", e_cpt),
     "...and asked for by name it stops there, with the module's own reason")
  ok(setequal(vapply(Filter(function(m) !is.null(m$check), MODULES), `[[`, character(1), "check"),
              c("check_charlson_list", "check_soc_list", "check_safety_list", "check_hcru_list",
                "check_malignancy_list")) &&
       all(vapply(c("mod_comorbidity", "mod_soc", "mod_safety", "mod_hcru", "mod_malignancy"), function(f)
         grepl("check_[a-z]+_list\\(cfg, cl\\)", paste(deparse(get(f)), collapse = "\n")), logical(1))),
     "...the same check each list-driven module makes as it starts, registered beside it")
  # The lists these preflights loaded are in the manifest; a later check
  # reads that manifest on its own terms.
  rm(list = ls(.codelist_seen), envir = .codelist_seen)
  unlink(cdir, recursive = TRUE)
  unlink(empty, recursive = TRUE)
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

cat("\nthe two roots, and the nesting that is now a setting\n")
{
  # Eligibility is a ROOT: it declares no needs, so it is buildable with no LOT
  # run in existence. That is the whole point of splitting it out - eight of
  # the eleven criteria are settled before this package runs and none of them
  # needs a line.
  ok(identical(MODULES$eligibility$needs, character(0)) &&
       identical(MODULES$spine$needs, character(0)),
     "eligibility and spine are independent roots: neither declares a need, so either builds without the other")
  ok(setequal(MODULES$cohorts$needs, c("eligibility", "spine")),
     "...and cohorts is the first module that needs both, because it is where a patient and a line are combined")
  ok(identical(names(suppressMessages(resolve_modules(
       cfg0(c(MODULES = "eligibility"))))), "eligibility"),
     "...so asking for eligibility alone pulls in nothing at all - no spine, no LOT run needed")

  # Nesting is a setting. The parent join is what makes a 1L index outside the
  # window cost the patient their 2L and 3L rows too.
  emit_for <- function(env) {
    set_study_config(cfg0(env))
    co <- resolve_cohorts(study_config())
    sql <- character(0)
    e <- new.env(parent = environment(mod_cohorts))
    e$run_step <- function(con, name, statement, ...) { sql <<- c(sql, statement); invisible(NULL) }
    e$prepare_table <- function(...) invisible(NULL)
    e$db_exec <- function(con, s) { sql <<- c(sql, s); invisible(NULL) }
    e$db_q <- function(con, s) data.frame(n_indexed = 1, n_in_cohort = 1)
    f <- stubbed(mod_cohorts, e)
    f(NULL, study_config(), co$`2L`)
    paste(sql, collapse = "\n")
  }
  nested_sql <- emit_for(character(0))
  flat_sql   <- emit_for(c(COHORT_NESTED = "FALSE"))
  # NO parent join of ANY form, not just the absence of one alias. There were
  # two ways to write it - a direct INNER JOIN on S_COHORT and the staged
  # temporary view - and the flat path kept the first while the row said
  # NESTED = 0. Testing for the view's name passed on SQL that still required
  # the parent, so the test is over `par` and over the parent table's name.
  parent_join <- function(sql)
    grepl("s_parent_cohort", sql, fixed = TRUE) ||
      grepl("par.IN_COHORT", sql, fixed = TRUE) ||
      grepl("par ON par.PATID", sql, fixed = TRUE)
  ok(parent_join(nested_sql),
     "by default a nested cohort still requires the cohort above, which is s7.2.1 read literally")
  ok(!parent_join(flat_sql),
     "...and COHORT_NESTED=FALSE drops that requirement in EVERY form it is written, so each line stands on its own index")
  ok(!grepl("\\bpar\\b", flat_sql) && !grepl("s223926_S_COHORT par", flat_sql, fixed = TRUE),
     "...with the parent alias nowhere in the statement, so no join can survive under another spelling")
  ok(grepl("1 AS NESTED", nested_sql, fixed = TRUE) &&
       grepl("0 AS NESTED", flat_sql, fixed = TRUE),
     "...with the row saying which way it went, so a number cannot be read under the wrong one")
  ok(grepl("N1_received_line; N2_ce_pre; I5_followup", nested_sql, fixed = TRUE),
     "and every row carries the criteria ITS verdict was computed over - 2L is judged on three, not on the nine that sit on the row")

  # The SELECTION has to follow the setting too, or the setting is one the code
  # does not honour: a 2L-only run of second-line initiators is exactly what
  # COHORT_NESTED=FALSE exists to allow, and the parent requirement refused it
  # while only the JOIN was made conditional.
  sel <- function(env) tryCatch(names(resolve_cohorts(cfg0(env))),
                                error = function(e) paste("ERROR:", conditionMessage(e)))
  ok(identical(sel(c(COHORTS = "2L", COHORT_NESTED = "FALSE")), "2L") &&
       identical(sel(c(COHORTS = "3L", COHORT_NESTED = "FALSE")), "3L"),
     "with nesting off, a later line can be selected on its own - which is the analysis the setting is for")
  ok(grepl("^ERROR:", sel(c(COHORTS = "2L"))[1]) &&
       grepl("COHORT_NESTED=FALSE", sel(c(COHORTS = "2L"))[1], fixed = TRUE),
     "...while the default still refuses it, and the refusal names the setting that would allow it")
  ok(identical(sel(c(COHORTS = "1L,2L")), c("1L", "2L")),
     "...and a selection carrying its parent is unaffected either way")
  set_study_config(cfg0())
}

cat("\na run builds the inputs its own modules read, and no others\n")
{
  # The point of splitting eligibility out is that it can be built where there
  # is no LOT run. That is a property of the CONTROLLER, not of the module
  # graph: the graph said needs=character(0) while build_223926() proved LOT
  # lineage and built enrolment spans for every run, so a standalone
  # eligibility run still failed in an environment with no LOT status table -
  # before the module it selected ever ran.
  sel_mods <- function(m) suppressMessages(resolve_modules(cfg0(c(MODULES = m))))
  elig <- sel_mods("eligibility")
  ok(identical(names(elig), "eligibility") &&
       !reads_lot(elig) && !reads_enroll_spans(elig) && !reads_fu_claims(elig),
     "an eligibility-only run reads no LOT table, no enrolment span and no claim count, so none is prepared for it")
  ok(reads_input_cohort(elig),
     "...it does read the input cohort table, so that contract is still checked")
  for (m in c("attrition", "periods", "tte", "all")) {
    mm <- sel_mods(m)
    ok(reads_lot(mm) && reads_enroll_spans(mm),
       paste0("MODULES=", m, " reads the LOT tables and the enrolment spans, so both are prepared and the lineage is proved"))
  }
  rsrc <- paste(readLines("R/run_223926.R", warn = FALSE), collapse = "\n")
  ok(grepl("if (reads_lot(mods)) check_lot_lineage_unchanged", rsrc, fixed = TRUE) &&
       grepl("lot_run <- if (reads_lot(mods)) check_lot_lineage", rsrc, fixed = TRUE),
     "...and BOTH lineage checks follow the same question, so a run cannot prove a build it never read and then recheck it")
  # The provenance query is a READ of the cohort build's metadata, so it
  # follows the same question as the table it is about. "Reads
  # INPUT_COHORT_TABLE and nothing else" has to be true of the database too,
  # not only of the module's own SQL.
  ok(grepl("upstream <- if (reads_input_cohort(mods)) read_upstream_settings", rsrc, fixed = TRUE),
     "...and the upstream provenance query follows what reads the cohort build, so a run that reads none of it queries none of it")
}

cat("\nthe cohort table, as SQL names it\n")
{
  # Bare, the name resolved against the session's current schema: the working
  # schema on a cluster session, `default` over the ODBC warehouse - and every
  # scenario stopped at DESCRIBE with ndmm_NDMM_COHORT "cannot be found".
  set_study_config(local({ c1 <- cfg0(); c1$work_schema <- "osk02156"; c1 }))
  ok(identical(input_cohort_tbl(), "hive_metastore.osk02156.ndmm_NDMM_COHORT"),
     "the input cohort table is read under the run's catalog and schema, like every other table")
  ok(identical(cfg0()$input_cohort_table, "ndmm_NDMM_COHORT"),
     "...while the setting itself stays the bare name the LOT status row records, for the lineage comparison")
  set_study_config(local({ c1 <- cfg0(c(INPUT_COHORT_TABLE = "other_cat.their_schema.NDMM_COHORT")); c1$work_schema <- "osk02156"; c1 }))
  ok(identical(input_cohort_tbl(), "other_cat.their_schema.NDMM_COHORT"),
     "...and a name given already qualified is used as it is")
  set_study_config(cfg0())
  bare <- Filter(function(x) grepl("(^|[^.A-Za-z0-9_])ndmm_NDMM_COHORT", x$sql), RUN$sql)
  ok(!length(bare),
     paste0("no emitted statement names the cohort table bare (", length(bare), " did)"))
  # ONE module reads the upstream table, and it is mod_eligibility(). That is
  # the layering, stated as a test rather than as a comment: everything else
  # takes the cohort build's verdict off S_ELIGIBILITY, so a change to the
  # input's shape reaches the package through a table the package declares.
  # A second reader appearing here is the layering quietly coming undone.
  reads <- Filter(function(x) grepl("hive_metastore.wk.ndmm_NDMM_COHORT",
                                    x$sql, fixed = TRUE), RUN$sql)
  # Exactly one statement DERIVES from the upstream table, and it builds
  # S_ELIGIBILITY. The others that name it are read-only: describe_columns()
  # and the value check in check_cohort_table(), which is what the input
  # contract is checked by and writes nothing.
  writes <- Filter(function(x) grepl("CREATE OR REPLACE TABLE", x$sql, fixed = TRUE) ||
                               grepl("INSERT INTO", x$sql, fixed = TRUE), reads)
  ok(length(writes) == 1L &&
       grepl("S_ELIGIBILITY", writes[[1]]$sql, fixed = TRUE),
     paste0("exactly one emitted statement derives from the input cohort table (",
            length(writes), " did), and it is the one that builds S_ELIGIBILITY"))
  ok(all(vapply(setdiff(names(reads), names(writes)), function(n)
           !grepl("INSERT INTO|CREATE OR REPLACE TABLE", reads[[n]]$sql), logical(1))),
     "...and every other statement naming it only reads it, which is the input contract check")
  ok(sum(grepl("hive_metastore.wk.s223926_S_ELIGIBILITY",
               vapply(RUN$sql, function(x) x$sql, character(1)),
               fixed = TRUE)) >= 4,
     "...and the modules that used to read it now read S_ELIGIBILITY, under the work schema")
}

cat("\nthe connection layer\n")
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
  # Spark's escape inside a string is the backslash, which is how a staged
  # code list writes its values. The splitter read \' as the end of the
  # string: 'Alzheimer\'s disease' was refused as unterminated before it
  # reached the driver, and a label with two apostrophes and a ; between them
  # was cut into two statements.
  ok(identical(split_statements("SELECT 'Alzheimer\\'s disease' AS v; SELECT 2"),
               c("SELECT 'Alzheimer\\'s disease' AS v", "SELECT 2")),
     "a backslash-escaped quote does not end the string")
  ok(identical(split_statements("SELECT 'Patient\\'s symptom; clinician\\'s note' AS v"),
               "SELECT 'Patient\\'s symptom; clinician\\'s note' AS v"),
     "...so a semicolon between two of them stays inside the statement")
  ok(identical(split_statements("SELECT 'a\\\\'; SELECT 2"), c("SELECT 'a\\\\'", "SELECT 2")),
     "...while a quote behind a doubled backslash - a backslash in the value - does end it")
  ok(identical(split_statements("SELECT 'a\\\\\\''; SELECT 2"), c("SELECT 'a\\\\\\''", "SELECT 2")),
     "...and behind three, it is escaped again: what counts is whether the run is odd")
  ok(!is.na(errs(split_statements("SELECT 'a\\'"))),
     "...and a string that ends in an escaped quote is still unterminated")
  ok(identical(split_statements("SELECT `a\\`; SELECT 2"), c("SELECT `a\\`", "SELECT 2")),
     "a backtick identifier has no backslash escape, so a backslash before its closing backtick means nothing")
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

  # All three quote characters, not just `'`: Spark writes a quoted identifier
  # in BACKTICKS and this package's SQL uses them, and under ANSI mode a double
  # quote is an identifier too. A `;` inside either would cut a statement in
  # half.
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
  ok(identical(cfg0()$spark_method, "odbc"),
     "the default connection is the Databricks ODBC driver - the one the cohort and LOT builds use")
  ok(identical(cfg0()$dsn, "RWDE") && identical(cfg0(c(DATABRICKS_DSN = "OTHER"))$dsn, "OTHER"),
     "...on the DSN the cohort build defaults to, overridable")
  ok(identical(cfg0(c(DATABRICKS_PWD = "s3cret"))$pwd, "s3cret") && identical(cfg0()$pwd, ""),
     "...with the password from the environment alone")
  # The schema a run writes into, resolved as the cohort and LOT builds
  # resolve theirs. The deploy guide had the Job export PROJECT_WORK_SCHEMA
  # and this package did not read it; and a schema given with its catalog,
  # as it reads on the warehouse, was prefixed with the catalog again.
  ok(identical(cfg0()$work_schema, "") &&
       identical(cfg0(c(WORK_SCHEMA = "osk02156"))$work_schema, "osk02156") &&
       identical(cfg0(c(PROJECT_WORK_SCHEMA = "proj"))$work_schema, "proj") &&
       identical(cfg0(c(DOMINO_USER_NAME = "usr00000"))$work_schema, "usr00000") &&
       identical(cfg0(c(WORK_SCHEMA = "w", PROJECT_WORK_SCHEMA = "p", DOMINO_USER_NAME = "u"))$work_schema, "w"),
     "the work schema resolves as the cohort and LOT builds resolve theirs: WORK_SCHEMA, then PROJECT_WORK_SCHEMA, then the Domino user's own schema, else the session's")
  ok(identical(cfg0(c(WORK_SCHEMA = "hive_metastore.osk02156"))$work_schema, "osk02156") &&
       identical(with_env(c(base_env, WORK_SCHEMA = "hive_metastore.osk02156"),
                          { set_study_config(cfg_defaults()); wrk("S_SPINE") }),
                 "hive_metastore.osk02156.s223926_S_SPINE"),
     "...a schema given with its catalog is read as the schema - handed over whole it became hive_metastore.hive_metastore.osk02156, a name with too many parts")
  set_study_config(cfg0())
  ok(grepl("DATABRICKS_CATALOG", errs(cfg0(c(WORK_SCHEMA = "other.osk02156")))) &&
       grepl("not a schema name", errs(cfg0(c(PROJECT_WORK_SCHEMA = "a.b.c")))),
     "...while a catalog that is not the run's, or a name that is not a schema, stops at config time")

  # connect_db() over odbc opens the driver through odbc_connect(), the one
  # call a test cannot make, and stops by name when the password is missing.
  dbi_con <- structure(list(), class = c("fake", "DBIConnection"))
  opened <- NULL
  cenv <- new.env(parent = environment(connect_db))
  cenv$odbc_connect <- function(dsn, pwd) { opened <<- list(dsn = dsn, pwd = pwd); dbi_con }
  cenv$requireNamespace <- function(...) TRUE   # DBI and odbc need not be installed here
  cenv$log_msg <- function(...) invisible(NULL)
  cdb <- stubbed(connect_db, cenv, also = "connect_odbc")
  con <- cdb(cfg0(c(DATABRICKS_PWD = "pw")))
  ok(is_dbi_con(con) && identical(opened, list(dsn = "RWDE", pwd = "pw")),
     "SPARK_METHOD=odbc opens the Databricks ODBC DSN with the password from the environment, and nothing of Spark")
  ok(grepl("DATABRICKS_PWD", errs(cdb(cfg0()))),
     "...and stops, naming the variable, when the password is not set")

  # db_exec_once() and db_q() dispatch on the connection: a DBI connection is
  # sent through DBI, anything else through sparklyr, and a BIGINT the driver
  # returns as integer64 is a plain number by the time a caller sees it.
  said <- character(0)
  denv <- new.env(parent = environment(db_exec_once))
  denv$dbi_exec  <- function(con, sql) { said <<- c(said, sql); 1L }
  denv$dbi_query <- function(con, sql) data.frame(n = structure(1780, class = "integer64"))
  denv$with_retry <- function(fn, ...) fn()
  ok(identical(stubbed(db_exec_once, denv, also = character(0))(dbi_con, "CREATE TABLE t (x int)"), 1L) &&
       identical(said, "CREATE TABLE t (x int)"),
     "a DBI connection executes through DBI")
  q <- stubbed(db_q, denv, also = character(0))(dbi_con, "SELECT count(*) AS n FROM t")
  ok(is.numeric(q$n) && !inherits(q$n, "integer64"),
     "...and a BIGINT it reads comes back as a plain number, not a 64-bit bit pattern")
  spark_con <- structure(list(), class = c("spark_connection", "spark_shell_connection", "DBIConnection"))
  ok(is_spark_con(spark_con) && !is_dbi_con(spark_con) && is_dbi_con(dbi_con),
     "...a sparklyr session inherits DBIConnection as well, and is told apart from a DBI connection")
  said <- character(0)
  e_sp <- errs(stubbed(db_exec_once, denv, also = character(0))(spark_con, "SELECT 1"))
  ok(!is.na(e_sp) && !length(said),
     "...so a Spark session is never sent through DBI")
  closed <- FALSE
  xenv <- new.env(parent = environment(disconnect_db))
  xenv$dbi_disconnect <- function(con) closed <<- TRUE
  stubbed(disconnect_db, xenv, also = character(0))(dbi_con)
  ok(closed, "...and a DBI connection is closed through DBI")

  # Over ODBC a code list is staged as one VALUES statement in a temporary
  # view, the way the cohort build loads its lists over the same driver.
  cl <- data.frame(code = c("C90.0", "it's"), icd_family = c("10", ""), stringsAsFactors = FALSE)
  st <- codelist_stage_sql("cl_x_raw", cl)
  ok(grepl("^CREATE OR REPLACE TEMPORARY VIEW cl_x_raw AS", st) &&
       grepl("('C90.0', '10')", st, fixed = TRUE) && grepl("('it\\'s', '')", st, fixed = TRUE) &&
       grepl("AS t(code, icd_family)", st, fixed = TRUE),
     "over ODBC a code list is one VALUES statement behind a temporary view - every cell a string literal, in the file's column order")
  esc <- codelist_stage_sql("e_raw", data.frame(v = c("a\\b", "x\\", "back\\nslash", "Alzheimer's disease"),
                                                stringsAsFactors = FALSE))
  ok(grepl("('a\\\\b')", esc, fixed = TRUE) && grepl("('x\\\\')", esc, fixed = TRUE) &&
       grepl("('back\\\\nslash')", esc, fixed = TRUE) && grepl("('Alzheimer\\'s disease')", esc, fixed = TRUE) &&
       !grepl("''", esc, fixed = TRUE),
     "...a backslash doubled and an apostrophe escaped with one, Spark's rules - '' is two literals joined there, and would have made Alzheimers")
  st0 <- codelist_stage_sql("e_raw", cl[0, , drop = FALSE])
  ok(grepl("WHERE 1 = 0", st0, fixed = TRUE) && grepl("AS t(code, icd_family)", st0, fixed = TRUE),
     "...and an empty list is an empty view of the same shape, not a VALUES with nothing in it")
  big <- data.frame(code = sprintf("C%05d", 1:5318), icd_family = "10", stringsAsFactors = FALSE)
  t0 <- proc.time()[["elapsed"]]
  sb <- codelist_stage_sql("big_raw", big)
  tb <- proc.time()[["elapsed"]] - t0
  ok(length(gregexpr("\n  (", sb, fixed = TRUE)[[1]]) == 5318L && tb < 2,
     sprintf("...pregnancy.csv's 5,318 rows in one statement, built in %.2fs", tb))
  said <- character(0)
  renv <- new.env(parent = environment(register_codelist_view))
  renv$db_exec <- function(con, sql) { said <<- c(said, sql); invisible(1L) }
  v <- stubbed(register_codelist_view, renv, also = character(0))(dbi_con, cl, "CL_X", c("code", "icd_family"))
  ok(identical(v, "CL_X") && length(said) == 2L &&
       grepl("TEMPORARY VIEW cl_x_raw AS", said[1], fixed = TRUE) &&
       grepl("TEMPORARY VIEW CL_X AS", said[2], fixed = TRUE) && grepl("FROM cl_x_raw", said[2], fixed = TRUE),
     "...staged first, then normalised into the view every module joins on, both over the same connection")
  said <- character(0)
  e_cp <- errs(stubbed(register_codelist_view, renv, also = character(0))(spark_con, cl, "CL_Y", c("code", "icd_family")))
  ok(!is.na(e_cp) && !any(grepl("VALUES", said, fixed = TRUE)),
     "...and over a Spark session a code list is copied, never staged as SQL text")
  # The whole path from the list to the driver - register_codelist_view(),
  # db_exec(), the splitter - with only the driver call answered. The encoder
  # and the splitter have to agree about the backslash escape, or a label with
  # an apostrophe never reaches the warehouse.
  reached <- character(0)
  penv <- new.env(parent = environment(register_codelist_view))
  penv$dbi_exec <- function(con, sql) { reached <<- c(reached, sql); 1L }
  penv$with_retry <- function(fn, ...) fn()
  penv$log_msg <- function(...) invisible(NULL)
  stage_path <- stubbed(register_codelist_view, penv, also = c("db_exec", "db_exec_once"))
  labels <- c("Alzheimer's disease", "Patient's symptom; clinician's note", "plain")
  cl_lab <- data.frame(condition = labels, code = c("G30", "R69", "Z00"), stringsAsFactors = FALSE)
  v <- stage_path(dbi_con, cl_lab, "CL_LAB", c("condition", "code"))
  ok(identical(v, "CL_LAB") && length(reached) == 2L &&
       grepl("TEMPORARY VIEW cl_lab_raw AS", reached[1], fixed = TRUE) &&
       grepl("('Alzheimer\\'s disease', 'G30')", reached[1], fixed = TRUE) &&
       grepl("('Patient\\'s symptom; clinician\\'s note', 'R69')", reached[1], fixed = TRUE) &&
       grepl("TEMPORARY VIEW CL_LAB AS", reached[2], fixed = TRUE),
     "from the list to the driver, an apostrophe in a label and a semicolon between two of them reach it as two whole statements: the stage and the view")
  # The stage statement is Spark SQL, checked by the same parser the emitted
  # statements go through; SKIP rather than pass where it cannot run.
  sf <- tempfile(fileext = ".sql")
  writeLines(c("-- @@STMT codelist_stage", st, "-- @@STMT codelist_stage_empty", st0), sf)
  pout <- suppressWarnings(tryCatch(
    system2("python3", c("tests/parse_sql.py", shQuote(sf)), stdout = TRUE, stderr = TRUE),
    error = function(e) "NO-PYTHON"))
  ptxt <- paste(pout, collapse = "\n")
  if (any(grepl("^SKIP:", pout)) || identical(ptxt, "NO-PYTHON") || !length(pout)) {
    skip_note("the staged code list parses as Spark SQL (python3 + sqlglot not available)")
  } else {
    ok(grepl("0 failure\\(s\\)", ptxt),
       paste0("the staged code list parses as Spark SQL",
              if (!grepl("0 failure", ptxt)) paste0("\n", ptxt) else ""))
  }
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
  # ...and dates each by what happened. The engine ends a line the day BEFORE
  # an added agent or a line-opening transplant, so the footnote's
  # 'introduced' date is the day after; a run-out and an in-window AUTO end
  # the line on the last day its therapy covered.
  spine_sql <- paste(vapply(Filter(function(x) x$tag == "step:spine", RUN$sql),
                            function(x) x$sql, character(1)), collapse = "\n")
  ok(grepl("IN ('DISCONTINUATION','SCT_AUTO_CONT')\n             THEN l.LOT_BASE_END_DT", spine_sql, fixed = TRUE) &&
       grepl("('MED_ADD','CART_INIT','SCT_AUTO','SCT_ALLO','SCT_CART')\n             THEN cast(date_add(l.LOT_BASE_END_DT, 1) as date)", spine_sql, fixed = TRUE),
     "the discontinuation date is the run-out day for a run-out and the introduction day for an added agent or transplant - Table 4 footnote, Q33")
  ok(any(grepl("LOT_LONG_FINAL", sp)),
     "the spine reads the LOT output AFTER the line criteria, not before")
  tt <- capture.output(print(mod_tte))
  ok(any(grepl("IS_PROTOCOL_DISCON", tt)),
     "TTD's event is that union, not the DISCONTINUATION rows alone")
  # The acute washout is a statement about events, not periods: run once
  # over the cohort's baseline-start-to-follow-up-end timeline, and the
  # periods then take the distinct events dated inside them.
  saf_src <- readLines("R/modules/06_safety.R", warn = FALSE)
  ok(sum(grepl("run_acute_washout(", saf_src, fixed = TRUE)) == 1L,
     "the acute washout chain runs once per cohort, over the whole timeline - s7.8.1, Q34")
  all_sql <- paste(vapply(RUN$sql, function(x) x$sql, character(1)), collapse = "\n")
  ok(grepl("TEMPORARY VIEW s_periods_timeline", all_sql, fixed = TRUE) &&
       grepl("BASELINE_START AS PERIOD_START, FU_END AS PERIOD_END", all_sql, fixed = TRUE),
     "...from the cohort's baseline start to its follow-up end")
  ok(grepl("'TIMELINE' AS PERIOD", all_sql, fixed = TRUE) &&
       grepl("AND t.PERIOD = 'TIMELINE'", all_sql, fixed = TRUE) &&
       grepl("'BASELINE' AS PERIOD, t.CONDITION, t.EVENT_DT", all_sql, fixed = TRUE) &&
       grepl("'TREATMENT' AS PERIOD, t.CONDITION, t.EVENT_DT", all_sql, fixed = TRUE),
     "...and each period is filled from the chain's TIMELINE rows by date, never re-run")
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
  ok(any(grepl("AFTER_INDEX", ml)) &&
       any(grepl("CASE WHEN c.FIRST_DT >= p.INDEX_DATE THEN", ml, fixed = TRUE)),
     "a malignancy before the index is flagged and gets no duration from it - Table 4, 2L only after 2L")
  mp_sql <- paste(vapply(Filter(function(x) grepl("^step:malignancy_prevalence_SEC2L", x$tag), RUN$sql),
                         function(x) x$sql, character(1)), collapse = "\n")
  ok(grepl("BETWEEN date_add(p.DX_DT, 1) AND date_sub(p.INDEX_DATE, 1)", mp_sql, fixed = TRUE) &&
       grepl("CASE WHEN p.INDEX_DATE > p.DX_DT THEN", mp_sql, fixed = TRUE),
     "the secondary cohort's prevalence window runs from the diagnosis to the index, both excluded, with that interval's person-time - s7.8.4")
  ms_sql <- paste(vapply(Filter(function(x) grepl("^step:malignancy_sequences_1L", x$tag), RUN$sql),
                         function(x) x$sql, character(1)), collapse = "\n")
  ok(grepl("'after_index' AS SCOPE", ms_sql, fixed = TRUE) && grepl("m.AFTER_INDEX = 1", ms_sql, fixed = TRUE) &&
       grepl("'after_2l' AS SCOPE", ms_sql, fixed = TRUE) && grepl("m.FIRST_DT > l2.LOT_START_DT", ms_sql, fixed = TRUE),
     "the treatment sequences of those with a malignancy are tabulated after the index and, as the sensitivity, after 2L - Table 4")
  ok(grepl("CASE WHEN s4.LOT_START_DT <= q.FIRST_DT THEN s4.SOC_CATEGORY END)", ms_sql, fixed = TRUE) &&
       grepl("ORDER BY count(*) DESC, SEQUENCE) AS RANK", ms_sql, fixed = TRUE),
     "...in regimen categories up to MAX_LOT, ranked by how many patients received each")
  # "Sequences" is not pinned to a side of the malignancy, so all three
  # readings are rows, on LINES, each with its own denominator.
  ok(all(vapply(c("'to_malignancy' AS LINES", "'after_malignancy' AS LINES",
                  "'all_observed' AS LINES", "s1.LOT_START_DT >  q.FIRST_DT",
                  "'(no further therapy)'",
                  "PARTITION BY COHORT, SCOPE, LINES"),
                function(p) grepl(p, ms_sql, fixed = TRUE), logical(1))),
     "...split around the malignancy both ways and whole, each reading its own denominator - Q32")
  ok(identical(SUPPRESSION_SPEC$S_MALIGNANCY_SEQUENCES$group_by, c("COHORT", "SCOPE", "LINES")),
     "and the release copy suppresses within a reading, not across them")

  # The diagnosis-anchored rows of Table 4 and Table 5, read off the SQL the
  # periods module actually emits. Three durations, each with its own
  # endpoint convention, and one definition of the date they hang on.
  per_sql <- vapply(Filter(function(x) grepl("^step:periods_1L", x$tag), RUN$sql),
                    function(x) x$sql, character(1))
  per_sql <- paste(per_sql, collapse = "\n")
  ok(grepl("AS DX_DT", per_sql, fixed = TRUE) && grepl("AS DX_YEAR", per_sql, fixed = TRUE),
     "S_PERIODS carries the diagnosis date and its year - Table 4, year of MM diagnosis")
  # Table 5: diagnosis (included) to index (excluded) - a bare datediff.
  ok(grepl("datediff\\(co\\.INDEX_DATE, c\\.MM_DX_DT\\) END AS DX_TO_INDEX_DAYS", per_sql),
     "time from diagnosis to index counts the diagnosis day and not the index day - Table 5")
  # Table 4: diagnosis (included) to follow-up end (included) - one more.
  ok(grepl("c\\.MM_DX_DT\\) \\+ 1\\) END AS FU_FROM_DX_DAYS", per_sql),
     "follow-up from diagnosis counts both ends - Table 4")
  # The default is the cohort build's qualifying diagnosis - the date I2 and
  # I3 are already measured against - and it scans no claim for it.
  ok(!any(vapply(RUN$sql, function(x) grepl("s_dx_baseline", x$sql, fixed = TRUE), logical(1))) &&
       grepl("c.MM_DX_DT AS DX_DT", per_sql, fixed = TRUE) &&
       grepl("'cohort_mm_dx' AS DX_DT_SOURCE", per_sql, fixed = TRUE),
     "by default the diagnosis date is the cohort's own, and no claim is scanned for it")
  # Table 4's own definition, as the other reading: the first MM claim inside
  # the 1L baseline, index day included, anchored on the input cohort's 1L
  # index for every cohort, against the MM code list the cohort build used.
  alt_dx <- with_env(base_env, capture_emitted_sql(".", function(cfg) {
    cfg$dx_date_source <- "baseline_first_claim"; cfg }))
  dxv <- vapply(Filter(function(x) grepl("TEMPORARY VIEW s_dx_baseline", x$sql, fixed = TRUE),
                       alt_dx$sql), function(x) x$sql, character(1))
  ok(length(dxv) > 0 &&
       all(grepl("BETWEEN date_sub(c.COHORT_INDEX_DATE, 365) AND c.COHORT_INDEX_DATE",
                 dxv, fixed = TRUE)),
     "DX_DATE_SOURCE=baseline_first_claim takes the first MM claim within the 1L baseline on or prior to 1L - Table 4")
  ok(all(grepl("S_CL_MM_DX", dxv, fixed = TRUE)),
     "...matched against the same MM code list the cohort build used")
  alt_per <- paste(vapply(Filter(function(x) grepl("^step:periods_1L", x$tag), alt_dx$sql),
                          function(x) x$sql, character(1)), collapse = "\n")
  ok(grepl("coalesce(dx.DX_DT, c.MM_DX_DT) AS DX_DT", alt_per, fixed = TRUE) &&
       grepl("'baseline_claim' ELSE 'cohort_mm_dx'", alt_per, fixed = TRUE),
     "...and the row says which source supplied the date, since a patient with no claim in the window falls back")
  # And the code list follows the reading: the scan needs mm_dx.csv, the
  # cohort's date does not, so a run with no code list at all is still possible.
  mods_dx <- suppressMessages(resolve_modules(with_env(
    c(base_env, DX_DATE_SOURCE = "baseline_first_claim"), cfg_defaults())))
  mods_nodx <- suppressMessages(resolve_modules(cfg0()))
  ok("mm_dx.csv" %in% mods_dx$periods$codelists &&
       !("mm_dx.csv" %in% mods_nodx$periods$codelists),
     "the periods module needs the MM code list only under the reading that scans claims")
  # s7.8.1: characteristics "at the time of index date where possible. If
  # data is missing at index, data from the baseline period present nearest
  # index will be used." The rows in play overlap the baseline through the
  # index; the covering row wins; the nearest baseline row stands in.
  dm_sql <- paste(vapply(Filter(function(x) grepl("^step:demographics_1L", x$tag), RUN$sql),
                         function(x) x$sql, character(1)), collapse = "\n")
  ok(grepl("e.ELIGEFF <= p.INDEX_DATE AND e.ELIGEND >= p.BASELINE_START", dm_sql, fixed = TRUE),
     "demographics read the enrolment rows overlapping the baseline through the index - s7.8.1")
  ok(grepl("CASE WHEN e.ELIGEFF <= p.INDEX_DATE AND e.ELIGEND >= p.INDEX_DATE THEN 0 ELSE 1 END, e.ELIGEND DESC",
           dm_sql, fixed = TRUE),
     "...the row covering the index first, then the one ending nearest it")
  ok(grepl("'baseline_nearest'", dm_sql, fixed = TRUE) && grepl("AS ATTR_SOURCE", dm_sql, fixed = TRUE),
     "...and the row records which of the two supplied it")
  # Table 5: prior LOT start (included) to next LOT start (excluded), among
  # patients initiating a subsequent LOT - which is one this cohort observed.
  lp_sql <- paste(vapply(Filter(function(x) grepl("^step:lot_periods_1L", x$tag), RUN$sql),
                         function(x) x$sql, character(1)), collapse = "\n")
  ok(grepl("l.NEXT_LOT_START_DT <= p.FU_END THEN datediff(l.NEXT_LOT_START_DT, l.LOT_START_DT) END AS NEXT_LOT_DAYS",
           lp_sql, fixed = TRUE),
     "time from a line to the next counts the start day, not the next start, and only within follow-up - Table 5")
}

cat("\nthe rules that hold the numbers up\n")
{
  cfg <- cfg0(); cfg$work_schema <- "wk"; set_study_config(cfg)

  # 1. Every per-cohort module clears its OWN scope before writing, so a
  #    re-run replaces its rows and leaves the other cohorts' alone. The claim
  #    "re-run as often as needed" is only true because of this.
  #
  #    Read off the emitted SQL, not the source: grepping the function text for
  #    "prepare_table|CREATE OR REPLACE TABLE" accepts the second, which
  #    replaces the WHOLE table, so the 2L pass would delete the 1L rows.
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
  # there, it just never fires. So the guard is called against a status row
  # built to be wrong in one field at a time, and each is required to stop.
  # The columns the LOT engine's BUILD_STATUS_COLS actually declares, pinned as
  # literals. Written out here rather than derived from what lineage.R asks
  # for: a fixture built from the column names the SELECT uses agrees with the
  # SELECT instead of checking it.
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
    # After the shipped lot_rules_epoch, so the default row is a run this
    # package will read and a test has to ASK for the refusal.
    r$UPDATED_AT <- "2026-09-21 00:00:00"
    r$INPUT_COHORT_TABLE <- cfg0()$input_cohort_table
    r$STUDY_END <- cfg0()$study_end
    utils::modifyList(r, list(...))
  }
  # The cohort attempt and the LOT code fingerprint are NOT on
  # LOT_BUILD_STATUS - BUILD_STATUS_COLS above declares nine columns and none
  # of these is among them. The LOT engine records them on LOT_RUN_METADATA,
  # keyed by RUN_ID, and FINAL_METADATA_COLS declares them there. Pinned as
  # literals for the same reason as LOT_STATUS_COLS: a fixture built from what
  # lineage.R asks for agrees with the query instead of checking it.
  LOT_METADATA_COLS <- c("N_LOT_LONG_ROWS", "N_LOT_LONG_PATIENTS",
                         "LOT_LONG_BY_LINE", "N_LOT_FINAL_ROWS",
                         "N_LOT_FINAL_PATIENTS", "CODE_MD5",
                         "CONTRACT_SETTINGS", "STUDY_START", "STUDY_END",
                         "LINE_CRITERIA_APPLIED", "COHORT_RUN_ID",
                         "COHORT_STAMP", "RUN_ID")
  mdsrc <- paste(capture.output(print(lot_run_inputs)), collapse = "\n")
  md_sql <- regmatches(mdsrc, regexpr("SELECT[^\"]*FROM %s", mdsrc))
  md_asked <- if (length(md_sql)) {
    b <- sub("\\s*FROM %s$", "", sub("^SELECT\\s*", "", md_sql))
    toupper(trimws(strsplit(gsub("\\s+", " ", gsub("\\\\n", " ", b)), ",")[[1]]))
  } else character(0)
  ok(length(md_asked) > 0 && all(md_asked %in% LOT_METADATA_COLS),
     paste0("the cohort-attempt query names only columns the LOT writer declares",
            if (length(setdiff(md_asked, LOT_METADATA_COLS)))
              paste0(" [absent upstream: ",
                     paste(setdiff(md_asked, LOT_METADATA_COLS), collapse = ", "),
                     "]") else ""))
  ok(!any(c("COHORT_RUN_ID", "COHORT_STAMP", "CODE_MD5") %in% asked),
     paste0("...and the BUILD_STATUS query does not ask for them, which ",
            "would raise unresolved columns before either check could run"))

  # meta  = what LOT_RUN_METADATA says this run was built from, or NULL for an
  #         older LOT run that predates those columns.
  # now   = what the cohort build-status table holds NOW, or NULL for none.
  # meta_err / now_err: the LOT_RUN_METADATA or cohort-status query RAISES
  # this message instead of answering, which is what a permission refused or
  # a dropped session looks like from here.
  lin_check <- function(..., meta = list(), now = list(), cfg = cfg0(),
                        meta_err = NULL, now_err = NULL) {
    row <- lin_row(...)
    e <- new.env(parent = environment(check_lot_lineage))
    mrow <- if (is.null(meta)) NULL else utils::modifyList(
      list(COHORT_RUN_ID = "c1", COHORT_STAMP = "2026-09-21 00:00:00",
           CODE_MD5 = "abcdef0123456789"), meta)
    nrow_ <- if (is.null(now)) NULL else utils::modifyList(
      list(RUN_ID = "c1", UPDATED_AT = "2026-09-21 00:00:00",
           STATE = "complete"), now)
    e$db_q <- function(con, sql) {
      if (grepl("LOT_RUN_METADATA", sql, fixed = TRUE)) {
        if (!is.null(meta_err)) stop(meta_err)
        if (is.null(mrow)) stop("TABLE_OR_VIEW_NOT_FOUND")
        return(as.data.frame(mrow, stringsAsFactors = FALSE))
      }
      # By the query's shape, not the table's name: the cohort build's status
      # is read newest-first with LIMIT 1, whichever of its names - or the
      # one COHORT_STATUS_TABLE gives it - it sits under. The LOT status is
      # read with LIMIT 5 and falls through to the row below.
      if (grepl("ORDER BY UPDATED_AT DESC LIMIT 1", sql, fixed = TRUE) &&
          !grepl("lot_build_status", sql, ignore.case = TRUE)) {
        if (!is.null(now_err)) stop(now_err)
        if (is.null(nrow_)) stop("TABLE_OR_VIEW_NOT_FOUND")
        return(as.data.frame(nrow_, stringsAsFactors = FALSE))
      }
      as.data.frame(row, stringsAsFactors = FALSE)
    }
    e$log_msg <- function(...) invisible(NULL)
    # The three helpers are called BY check_lot_lineage and defined beside it,
    # so they resolve to the global copies - and those reach the real
    # warehouse - unless they are re-homed in the fake as well.
    errs(stubbed(check_lot_lineage, e,
                 c("check_cohort_attempt", "lot_run_inputs",
                   "cohort_build_now", "check_lot_code"))(NULL, cfg))
  }
  ok(is.na(lin_check()), "a matching lineage row is accepted")
  ok(grepl("built over", lin_check(INPUT_COHORT_TABLE = "other_tbl") %||% ""),
     "a LOT run built over a different cohort table stops")
  ok(grepl("STUDY_END", lin_check(STUDY_END = "2025-12-31") %||% ""),
     "and so does one whose STUDY_END disagrees")
  e_failed <- lin_check(STATE = "failed")
  ok(!is.na(e_failed) && grepl("not 'complete'", e_failed) &&
       grepl("LOT build's own log", e_failed),
     "and one that did not finish, saying where that build recorded why")

  # The cohort ATTEMPT. Every check above compares a NAME, and a cohort table
  # can be rebuilt in place under the same name - so these are the ones that
  # tell attempt A's lines from attempt B's eligibility.
  e_stamp <- lin_check(now = list(UPDATED_AT = "2026-09-21 06:00:00"))
  ok(!is.na(e_stamp) && grepl("has been rebuilt since", e_stamp) &&
       grepl("2026-09-21 00:00:00", e_stamp) &&
       grepl("2026-09-21 06:00:00", e_stamp),
     "a cohort rebuilt in place under the same name stops, naming both attempts")
  ok(!is.na(lin_check(now = list(RUN_ID = "c2"))),
     "...and so does a different cohort run under that name")
  ok(is.na(lin_check(now = list(STATE = "started"))),
     "while the same attempt still under that name is accepted")
  # An older LOT run recorded no attempt. Nothing to compare, so nothing to
  # refuse - but it is said out loud rather than passed over.
  ok(is.na(lin_check(meta = list(COHORT_RUN_ID = "", COHORT_STAMP = ""))),
     "a LOT run that recorded no cohort attempt is accepted, not refused")
  ok(is.na(lin_check(meta = NULL)),
     "...and so is one whose LOT_RUN_METADATA is not there at all")
  ok(is.na(lin_check(meta_err = "[UNRESOLVED_COLUMN] A column with name `COHORT_RUN_ID` cannot be resolved")),
     "...and so is one whose LOT_RUN_METADATA predates the columns, which is how an older writer's table answers")

  # ABSENT and UNREADABLE are different answers. Every read failure used to
  # become NULL, which check_cohort_attempt() read as an older LOT run with
  # nothing recorded - so a permission refused, or a session dropped, was
  # accepted as "legacy". A run that could pair a rebuilt cohort with another
  # run's lines on the strength of an outage.
  perm <- "[INSUFFICIENT_PERMISSIONS] User does not have SELECT on table LOT_RUN_METADATA"
  e_perm <- lin_check(meta_err = perm)
  ok(!is.na(e_perm) && grepl("could not read", e_perm, fixed = TRUE) &&
       grepl("not the same as the table being absent", e_perm, fixed = TRUE),
     "a LOT_RUN_METADATA that cannot be READ stops, saying that is not the same as absent")
  ok(is.na(lin_check(meta_err = perm,
                     cfg = cfg0(c(LOT_ALLOW_UNPROVEN_LINEAGE = "TRUE")))),
     "...unless LOT_ALLOW_UNPROVEN_LINEAGE says to go on over a binding nothing checked")
  e_now <- lin_check(now_err = perm)
  ok(!is.na(e_now) && grepl("could not be read", e_now, fixed = TRUE) &&
       grepl("not the same as its being absent", e_now, fixed = TRUE),
     "and a cohort build-status table that cannot be read stops the same way")
  ok(is.na(lin_check(now_err = perm,
                     cfg = cfg0(c(LOT_ALLOW_UNPROVEN_LINEAGE = "TRUE")))),
     "...waived by the same flag, and by nothing else")
  # A status table the SETTING names, and that is not there, is a mistake in
  # the setting - not one of the two default names being unused.
  e_named <- lin_check(now = NULL, cfg = cfg0(c(COHORT_STATUS_TABLE = "my_status")))
  ok(!is.na(e_named) && grepl("SETTING ERROR: COHORT_STATUS_TABLE names", e_named, fixed = TRUE) &&
       grepl("my_status", e_named, fixed = TRUE),
     "a COHORT_STATUS_TABLE that names a table which is not there stops, naming the setting rather than reporting no status found")
  ok(!is.na(lin_check(now = NULL, cfg = cfg0(c(COHORT_STATUS_TABLE = "my_status",
                                                LOT_ALLOW_UNPROVEN_LINEAGE = "TRUE")))),
     "...and the waiver does not cover it, because a wrong setting is not an unproven lineage")
  ok(missing_object_error(simpleError("[TABLE_OR_VIEW_NOT_FOUND] The table x cannot be found")) &&
       missing_object_error(simpleError("Table or view not found: wk.t")) &&
       missing_object_error(simpleError("AnalysisException: Table wk.t does not exist")) &&
       !missing_object_error(simpleError(perm)) &&
       missing_column_error(simpleError("[UNRESOLVED_COLUMN.WITH_SUGGESTION] cannot resolve `y`")) &&
       missing_column_error(simpleError("cannot resolve 'COHORT_RUN_ID' given input columns: [RUN_ID]")) &&
       !missing_column_error(simpleError(perm)),
     "the two classifiers tell an absent object and an absent column from every other failure")
  # ...and the plain-English phrases are held to the thing they are about:
  # a grant or a principal that "does not exist" is not an absent table.
  ok(!missing_object_error(simpleError("PERMISSION_DENIED: principal `svc` does not exist")) &&
       !missing_object_error(simpleError("Grant does not exist for user x")) &&
       !missing_column_error(simpleError("Function cannot resolve the session")),
     "...so an outage whose words happen to include 'does not exist' is not read as an older run")
  # A missing grant is not retried: the lineage stop fires at once, not after
  # four sleeps.
  n_tries <- 0L
  e_retry <- errs(with_retry(function() { n_tries <<- n_tries + 1L; stop(perm) },
                             max_retries = 3L, base_sleep = 0))
  ok(!is.na(e_retry) && n_tries == 1L,
     "a permission error is permanent to with_retry(), as it is to the LOT engine's")
  # The completion-time recheck keeps the driver's reason.
  e_re <- errs(local({
    e <- new.env(parent = environment(check_lot_lineage_unchanged))
    e$db_q <- function(con, sql) stop(perm)
    e$log_msg <- function(...) invisible(NULL)
    stubbed(check_lot_lineage_unchanged, e, character(0))(NULL, list(RUN_ID = "lot1", UPDATED_AT = "2026-09-22 05:00:00"))
  }))
  ok(!is.na(e_re) && grepl("could not be re-read", e_re, fixed = TRUE) &&
       grepl("INSUFFICIENT_PERMISSIONS", e_re, fixed = TRUE),
     "the completion-time recheck stops with the driver's own words, so the failure record can tell a revoked grant from a dropped table")
  # The same distinction where the cohorts module asks whether the engine's
  # allflags table is there: absent is an older LOT build and the funnel goes
  # on without its opening step; unreadable stops.
  presence_of <- function(msg) {
    e <- new.env(parent = environment(table_presence))
    e$db_q <- function(con, sql) if (is.null(msg)) data.frame(col_name = "PATID") else stop(msg)
    stubbed(table_presence, e, character(0))(NULL, "t")
  }
  ok(identical(as.character(presence_of(NULL)), "ok") &&
       identical(as.character(presence_of("[TABLE_OR_VIEW_NOT_FOUND] t")), "absent") &&
       identical(as.character(presence_of(perm)), "unreadable") &&
       identical(attr(presence_of(perm), "why"), perm),
     "table_presence() answers ok, absent or unreadable, and carries the driver's words on the last")
  origin_of <- function(msg) {
    e <- new.env(parent = environment(attrition_origin))
    e$db_q <- function(con, sql) if (is.null(msg)) data.frame(col_name = "PATID") else stop(msg)
    said <- character(0)
    e$log_msg <- function(...) said <<- c(said, paste0(...))
    out <- errs(stubbed(attrition_origin, e, "table_presence")(NULL, cfg0(), COHORTS[["1L"]]))
    list(err = out, said = said)
  }
  ok(is.na(origin_of("[TABLE_OR_VIEW_NOT_FOUND] t")$err) &&
       any(grepl("is not there", origin_of("[TABLE_OR_VIEW_NOT_FOUND] t")$said, fixed = TRUE)),
     "an allflags table that is not there is an older LOT build: the funnel goes on without its opening step, and says so")
  e_af <- origin_of(perm)$err
  ok(!is.na(e_af) && grepl("ATTRITION ERROR", e_af, fixed = TRUE) &&
       grepl("INSUFFICIENT_PERMISSIONS", e_af, fixed = TRUE) &&
       grepl("not the same as its being absent", e_af, fixed = TRUE),
     "...while one that cannot be read stops, rather than recording a funnel with no opening step on the strength of an outage")
  # The attempt is known and the cohort's own status is not. That is unproven,
  # not wrong, so it is the one case the waiver covers.
  e_unproven <- lin_check(now = NULL)
  ok(!is.na(e_unproven) && grepl("no cohort build status could be found",
                                 e_unproven),
     "a known attempt with no cohort status to compare it to stops")
  ok(is.na(lin_check(now = NULL,
                     cfg = cfg0(c(LOT_ALLOW_UNPROVEN_LINEAGE = "TRUE")))),
     "...and LOT_ALLOW_UNPROVEN_LINEAGE is what waives exactly that case")

  # WHICH code. LOT_RULES_EPOCH refuses a build by the DATE it finished, which
  # says when it ran and not what it ran; this is the fingerprint of the R that
  # executed, and it is opt-in.
  ok("lot_code_md5" %in% names(cfg0()),
     "LOT_CODE_MD5 is a real setting, not just a message")
  ok(is.na(lin_check()),
     "with LOT_CODE_MD5 unset, a run built by any code is accepted")
  ok(is.na(lin_check(cfg = cfg0(c(LOT_CODE_MD5 = "abcdef0123456789")))),
     "...and the approved fingerprint is accepted when it matches")
  e_code <- lin_check(cfg = cfg0(c(LOT_CODE_MD5 = "0000000000000000")))
  ok(!is.na(e_code) && grepl("built by code abcdef0123456789", e_code) &&
       grepl("only 0000000000000000", e_code),
     "...while a run built by other code is refused, naming both fingerprints")
  e_nocode <- lin_check(meta = list(CODE_MD5 = ""),
                        cfg = cfg0(c(LOT_CODE_MD5 = "abcdef0123456789")))
  ok(!is.na(e_nocode) && grepl("records no code fingerprint", e_nocode),
     "...and so is one whose code this cannot name, rather than passed over")

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
  CS <- "gap_days=30|outpatient_window=90|study_end=2026-03-31|study_start=2016-01-01|lot1_from=2019-01-01"
  # The study period defines the cohort, so a disagreement on it stops the
  # run unless SETTINGS_OVERRIDE says to go on - and then it is a recorded
  # deviation, like a contract change.
  e_up <- tryCatch(up_read(CS), error = function(e) conditionMessage(e))
  ok(is.character(e_up) && grepl("UPSTREAM ERROR", e_up, fixed = TRUE) &&
       grepl("study_start: the cohort was built with 2016-01-01, this run is set to 2018-01-01", e_up, fixed = TRUE) &&
       grepl("SETTINGS_OVERRIDE", e_up, fixed = TRUE),
     "a cohort built under a different study period stops the run, naming both values")
  a <- up_read(CS, cfg0(c(SETTINGS_OVERRIDE = "TRUE")))
  ok(identical(a$out[["study_start"]], "2016-01-01") &&
       identical(a$out[["outpatient_window"]], "90"),
     "the cohort build's contract string is parsed into its settings")
  ok(any(grepl("the cohort was built with 2016-01-01, this run is set to 2018-01-01",
               a$said, fixed = TRUE)),
     "and under the override a disagreement is named, with both values")
  ok(identical(attr(a$out, "deviations"),
               "upstream study_start - the cohort was built with 2016-01-01, this run is set to 2018-01-01"),
     "...and returned as a deviation for the metadata row")
  ok(!any(grepl("outpatient_window", a$said, fixed = TRUE)) &&
       !any(grepl("lot1_index_from", a$said, fixed = TRUE)),
     "while a setting the two agree on is not reported as a disagreement")
  b <- up_read(CS, cfg0(c(STUDY_START = "2016-01-01")))
  ok(!any(grepl("WARNING", b$said)) && any(grepl("verified", b$said)) &&
       !length(attr(b$out, "deviations")),
     "a run set to the same values as the cohort build reports no disagreement")
  # The 1L index floor binds the same way: I1 is a criterion of the cohort.
  e_lot1 <- tryCatch(up_read("study_start=2018-01-01|lot1_from=2017-01-01"),
                     error = function(e) conditionMessage(e))
  ok(is.character(e_lot1) &&
       grepl("lot1_index_from: the cohort was built with 2017-01-01, this run is set to 2019-01-01", e_lot1, fixed = TRUE),
     "...and so does a cohort indexed from a different 1L floor than I1 states")
  # A setting that only shapes one criterion's reading is named, not fatal.
  c0 <- up_read("study_start=2018-01-01|lot1_from=2019-01-01|outpatient_window=60")
  ok(!is.null(c0$out) && any(grepl("outpatient_window", c0$said, fixed = TRUE)) &&
       any(grepl("WARNING", c0$said)) && !length(attr(c0$out, "deviations")),
     "a disagreement on the outpatient window is a warning, not a stop, and not a deviation")
  ok(identical(unname(UPSTREAM_SETTING_MAP[BINDING_UPSTREAM_SETTINGS]), c("study_start", "lot1_from")),
     "the two binding settings are the study period and the 1L index floor, under the cohort build's names")
  c1 <- up_read(NULL)
  ok(is.null(c1$out) && any(grepl("unverified", c1$said)),
     "a metadata table that cannot be read leaves the readings unverified, and says so")
  ok(is.null(up_read("")$out) && is.null(up_read("NA")$out),
     "and so does a run that recorded no contract string")
  ok(is.null(up_read("nonsense with no equals")$out),
     "a string in no recognisable shape is not guessed at")
  ok(!is.na(lin_check(UPDATED_AT = "2026-08-01 00:00:00")),
     "and one built before the rules last changed")

  # The epoch is a SETTING, and the reason is that it goes stale otherwise: the
  # shipped value sat at an August rule change after a September one had
  # superseded a further set of numbers, so every run between the two passed a
  # check written to stop exactly that. These hold it to being read from the
  # configuration rather than compiled in, in both directions.
  #
  # ONE pin, three values, read by this assertion and by the engine tie at
  # the end of this block. The date and the fingerprint were two literals in
  # two places, and re-pinning one while leaving the other is the exact
  # half-edit that put the epoch behind the engine twice. Here they move
  # together or neither moves.
  EPOCH_PIN <- list(
    date = "2026-09-19",
    # The engine's R, by its own code_fingerprint() - the same value it
    # records as CODE_MD5, so the two can be compared by eye.
    engine = "24e1fa2f4c8f80e48c2613cc6a9d8dad",
    # ...and its shipped settings, which code_fingerprint() does not read.
    # Most of what decides a line is pinned in the engine's own CONTRACT and
    # so is inside the R, but the study window is not, and a build reading a
    # different one is not the build this date was set for.
    settings = "7fff3707b2b8735d2457e7617cfae9c6")
  ok(identical(cfg0()$lot_rules_epoch, EPOCH_PIN$date),
     "the shipped epoch is the date the rules last changed")
  ok(is.na(lin_check(UPDATED_AT = "2026-09-20 00:00:00")),
     "a run finished after the shipped epoch is read")
  ok(!is.na(lin_check(UPDATED_AT = "2026-09-18 00:00:00")),
     "...and one finished the day before it is not")
  e_ep <- lin_check(UPDATED_AT = "2026-09-18 00:00:00")
  ok(grepl("2026-09-19", e_ep, fixed = TRUE) &&
       grepl("LOT_RULES_EPOCH", e_ep, fixed = TRUE),
     "...and the refusal names the date it applied and the setting that moves it")
  ok(is.na(lin_check(UPDATED_AT = "2026-09-18 00:00:00",
                     cfg = cfg0(c(LOT_RULES_EPOCH = "2026-09-01")))),
     "LOT_RULES_EPOCH moves the floor, so a delivery can name its own")
  ok(!is.na(lin_check(UPDATED_AT = "2026-09-20 00:00:00",
                      cfg = cfg0(c(LOT_RULES_EPOCH = "2026-10-01")))),
     "...in both directions")

  # The epoch's OWN date is refused. A rule change lands at a time of day and
  # UPDATED_AT is compared as a calendar date, so a run finished that day
  # cannot be placed either side of it; the guard refuses what it cannot
  # place rather than reading a number that may be superseded.
  ok(!is.na(lin_check(UPDATED_AT = "2026-09-19 23:59:59")),
     "a run finished ON the epoch cannot be placed either side of it, so it stops")
  ok(grepl("on or before", lin_check(UPDATED_AT = "2026-09-19 23:59:59"),
           fixed = TRUE),
     "...and the message says on or before, which is what the check does")

  # Which floor applied is on the run's own record, or a reader cannot tell a
  # run that cleared the shipped epoch from one that cleared a lowered one.
  ok("LOT_RULES_EPOCH" %in% names(RUN_METADATA_COLS),
     "S_RUN_METADATA carries the epoch the run was accepted against")

  # --- and the epoch is tied to the engine it was set for ---------------
  #
  # A date nothing holds to the code goes stale the next time the code
  # changes, and this one did, twice: the shipped value named an August rule
  # change after a September one, was moved to the September one, and was
  # superseded again two days later by the very next change to the fold-in.
  # Each time every run built in between passed a check written to stop
  # exactly those runs, and nothing failed.
  #
  # So the engine is fingerprinted - by its OWN function, not a restatement
  # of it - and compared to the fingerprint the shipped date was set for.
  # Change a rule and this stops, saying what to do: move LOT_RULES_EPOCH to
  # the date of the change and re-pin below. It is the one thing that cannot
  # be forgotten, because it is the same edit that changed the rule.
  #
  # Pinned by identity rather than by "it changed since last time": a
  # fingerprint file the suite writes could be regenerated without anyone
  # reading it, and that is the failure this replaces.
  local({
    top <- NA_character_
    for (up in c(".", "..")) {
      if (file.exists(file.path(up, "lot", "engine", "R", "build_lot.R"))) {
        top <- up; break
      }
    }
    if (is.na(top)) {
      skip_note(paste0("the LOT engine is not beside this package, so the ",
                       "epoch could not be held to the rules it was set for"))
      return(invisible(NULL))
    }
    eng <- file.path(top, "lot", "engine")
    e <- new.env(parent = globalenv())
    sys.source(file.path(eng, "R", "build_lot.R"), e)
    # What this covers, and what it cannot. The engine's R and the settings
    # it ships are both here. Its CODE LISTS are not: they live under
    # CODELIST_DIR on the platform, so no check in this folder can read
    # them, and a rollup moving a drug to another agent moves lines without
    # touching either fingerprint. That is recorded per run instead, in
    # LOT_CODELIST, and it is the same limit LOT_CODE_MD5 has always had.
    # Hashed through readLines/writeLines, not off the raw bytes, because
    # the raw bytes carry the checkout's line endings. Git hands this file
    # over as CRLF on Windows (i/lf w/crlf), so a byte hash there differs
    # from the same settings on a Linux checkout and the pin failed for a
    # reason that has nothing to do with the rules - which is the one
    # message this check must never send. code_fingerprint() beside it
    # normalises the same way, which is why its half passed where this
    # half did not.
    norm_md5 <- function(path) {
      tmp <- tempfile(); on.exit(unlink(tmp), add = TRUE)
      writeLines(readLines(path, warn = FALSE), tmp)
      unname(tools::md5sum(tmp))
    }
    got <- c(engine = e$code_fingerprint(eng),
             settings = norm_md5(file.path(eng, "config.csv")))
    # The same settings with the other line endings are the same settings.
    # Checked here rather than trusted, because the failure it prevents is
    # one this machine cannot have: a Windows checkout gets this file as
    # CRLF and a byte hash of it differs from the pin.
    local({
      crlf <- tempfile(); on.exit(unlink(crlf), add = TRUE)
      con <- file(crlf, "wb")
      writeBin(charToRaw(paste0(paste(
        readLines(file.path(eng, "config.csv"), warn = FALSE),
        collapse = "\r\n"), "\r\n")), con)
      close(con)
      ok(identical(norm_md5(crlf), unname(got["settings"])) &&
           !identical(unname(tools::md5sum(crlf)), unname(got["settings"])),
         paste0("the settings fingerprint is of the file's CONTENT, so a ",
                "checkout that writes CRLF does not read as a rule change"))
    })
    same <- identical(unname(got["engine"]), EPOCH_PIN$engine) &&
      identical(unname(got["settings"]), EPOCH_PIN$settings)
    ok(same,
       paste0("the shipped epoch is the date THIS engine's rules changed ",
              "(engine ", substr(got["engine"], 1, 8), "/",
              substr(got["settings"], 1, 8), ", pinned ",
              substr(EPOCH_PIN$engine, 1, 8), "/",
              substr(EPOCH_PIN$settings, 1, 8), ")", if (same) "" else
                paste0(" - the rules have changed since the epoch was set: ",
                       "move EPOCH_PIN$date to the date of that change, ",
                       "re-pin both fingerprints beside it, and let the ",
                       "shipped LOT_RULES_EPOCH follow")))
  })

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
  # s7.8.1 names "malignancies" as one chronic condition: the aggregate is one
  # more category through the same arithmetic, not a second implementation.
  ok(grepl("s_malig_first", ml) && grepl("MALIG_ANY_CATEGORY", ml) &&
       identical(MALIG_ANY_CATEGORY, "(any malignancy)"),
     "the any-malignancy aggregate is a category through the same views - s7.8.1")
  mr_sql <- paste(vapply(Filter(function(x) grepl("^step:malignancy_(rates|prevalence)_", x$tag), RUN$sql),
                         function(x) x$sql, character(1)), collapse = "\n")
  ok(grepl("UNION ALL SELECT '(any malignancy)' AS category", mr_sql, fixed = TRUE) &&
       grepl("FROM s_malig_first", mr_sql, fixed = TRUE) && grepl("FROM s_malig_dates", mr_sql, fixed = TRUE),
     "...in the incidence and the prevalence queries alike")
  ok(grepl("AS RATE_LO", mr_sql, fixed = TRUE) && grepl("AS RATE_HI", mr_sql, fixed = TRUE) &&
       all(c("RATE_LO", "RATE_HI") %in% SUPPRESSION_SPEC$S_MALIGNANCY_RATES$value_cols),
     "a malignancy rate carries its interval, and the release copy suppresses it with the rate - Table 4, 95% CI")
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
  # It reaches them BY nesting, so it stops reaching them when nesting is off:
  # under COHORT_NESTED=FALSE there is no parent join, membership never ANDs
  # MET_X2, and the 2L cohort holds the patients 1L excluded.
  ok(cohort_applies(COHORTS[["2L"]], "X2_other_cancer", cfg0()),
     "2L inherits it while COHORT_NESTED is on")
  ok(!cohort_applies(COHORTS[["2L"]], "X2_other_cancer",
                     cfg0(c(COHORT_NESTED = "FALSE"))),
     "...and does not once each line stands on its own index")
  ok(cohort_applies(COHORTS[["1L"]], "X2_other_cancer",
                    cfg0(c(COHORT_NESTED = "FALSE"))),
     "while a cohort's OWN criterion is unaffected by the setting")
  # And the caller that turns the answer into a published number follows it.
  # Whitespace-flattened: deparse wraps a long call, so a fixed match on the
  # written form fails for a reason that has nothing to do with the code.
  mg <- gsub("\\s+", " ",
             paste(capture.output(print(mod_malignancy)), collapse = " "))
  ok(grepl('cohort_applies(cohort, "X2_other_cancer", cfg)', mg, fixed = TRUE),
     "the baseline prevalence decision asks with cfg, not structurally")
  ok(grepl(".cohort_cols()", mg, fixed = TRUE),
     paste0("...and also refuses to publish it where the input was ",
            "pre-filtered, which makes it zero whatever the verdict is"))

  # 10b. Every file in R/ is loaded, by all three of the lists that load them.
  #
  # build.R has one, this suite has one, and the emit harness has a third.
  # contract.R was in build.R alone, so study_contract_md5() existed for a
  # production run and for nothing that tests one - the run wrote a metadata
  # row the suite could never have executed. A list is checked against the
  # directory rather than against another list: a file added to R/ and to none
  # of them is the same bug.
  # load_inputs.R is not in any of the three lists on purpose: build.R sources
  # it on its own, BEFORE the settings file reads Sys.getenv(), because its
  # whole job is to put config.csv's rows into the environment first. The two
  # harnesses set the environment themselves and must not have a file read
  # over the top of it. So it is excluded here and its own source checked
  # separately, rather than quietly widening what "every file" means.
  have <- setdiff(sort(list.files("R", "\\.R$")), "load_inputs.R")
  listed <- function(path, opener) {
    txt <- paste(readLines(path, warn = FALSE), collapse = "\n")
    blk <- regmatches(txt, regexpr(paste0(opener, "(?s).*?\\)"), txt, perl = TRUE))
    if (!length(blk)) return(character(0))
    sort(gsub('"', "", regmatches(blk, gregexpr('"[A-Za-z0-9_]+[.]R"', blk))[[1]]))
  }
  for (src in list(c("build.R", "for \\(f in c\\("),
                   c("tests/run_tests.R", "for \\(f in c\\("),
                   c("tests/emit_sql.R", "files <- c\\("))) {
    got <- listed(src[1], src[2])
    ok(identical(got, have),
       paste0(src[1], " sources every file in R/",
              if (!identical(got, have))
                paste0(" [missing: ", paste(setdiff(have, got), collapse = ", "),
                       "; extra: ", paste(setdiff(got, have), collapse = ", "),
                       "]") else ""))
  }

  ok(grepl('source(file.path(here, "R", "load_inputs.R"))',
           paste(readLines("build.R", warn = FALSE), collapse = "\n"),
           fixed = TRUE),
     "...and build.R sources load_inputs.R on its own, ahead of the settings")

  # 10c. The contract hash a run records is over the contract's LINES, so a
  # sibling reading a checkout with other line endings computes the same one.
  # local(), so the on.exit() cleanups run: in the bare block around this
  # they were registered against no frame and silently dropped.
  local({
    md5 <- study_contract_md5()
    tmp <- tempfile(fileext = ".csv"); on.exit(unlink(tmp), add = TRUE)
    write_study_contract(tmp)
    crlf <- tempfile(fileext = ".csv"); on.exit(unlink(crlf), add = TRUE)
    writeBin(charToRaw(paste0(paste(readLines(tmp, warn = FALSE), collapse = "\r\n"), "\r\n")), crlf)
    ok(grepl("^[0-9a-f]{32}$", md5) && identical(md5, contract_text_md5(tmp)) &&
         identical(md5, contract_text_md5(crlf)) &&
         !identical(md5, unname(tools::md5sum(crlf))),
       "STUDY_CONTRACT_MD5 is the md5 of the contract's lines: the same for a CRLF copy, where a byte hash differs")
  })

  # 10d. ONE connection across the delivery. The LOT build is the run that is
  # verified against the warehouse, so everything else has to open it the
  # same way: the same call, on the same two variables. Checked against the
  # engine and the two siblings whenever they are beside this package - the
  # engine's own line is read from its source, not restated here.
  local({
    # Found, not counted. The hop count was one too many for this package's
    # depth after it was flattened up a level, and the block went from CHECKING
    # the delivery to skipping it - nothing said so but the skip note.
    #
    # The search stays INSIDE the delivery: this package's own folder, then the
    # study root one above it. Reaching further would leave the folder, which
    # the repository's own hygiene check refuses - rightly, and it refused an
    # earlier version of these very lines.
    up_to_root <- c(".", "..")
    top <- NA_character_
    for (up in up_to_root) {
      if (file.exists(file.path(up, "lot", "engine", "R", "build_lot.R"))) {
        top <- up; break
      }
    }
    if (is.na(top)) top <- ".."
    engine <- file.path(top, "lot", "engine", "R", "build_lot.R")
    tfls <- file.path(top, "TFLS", "run_tfls.R")
    dash <- file.path(top, "dashboard", "global.R")
    if (!all(file.exists(c(engine, tfls, dash)))) {
      skip_note("the LOT engine, TFLS or the dashboard is not beside this package, so the one-connection check did not run")
      return(invisible(NULL))
    }
    # The CALL, from dbConnect( on: the engine assigns its connection on the
    # same line and this package returns it, which is not a difference in
    # how the warehouse is opened.
    line_of <- function(path) {
      x <- readLines(path, warn = FALSE)
      x <- grep("dbConnect(odbc::odbc()", x, fixed = TRUE, value = TRUE)
      sub("^.*?(DBI::dbConnect\\()", "\\1", trimws(x), perl = TRUE)
    }
    mine <- line_of("R/db_utils_223926.R")
    theirs <- sub("cfg\\$dsn", "dsn", sub("cfg\\$pwd", "pwd", line_of(engine)))
    ok(length(mine) == 1L && length(theirs) == 1L && identical(mine, theirs),
       paste0("this package opens the warehouse with the LOT engine's own line, character for character",
              if (!identical(mine, theirs)) paste0(" [", mine, " vs ", theirs, "]") else ""))
    ok(identical(cfg0()$dsn, Sys.getenv("DATABRICKS_DSN", unset = "RWDE")) &&
         grepl('DATABRICKS_DSN", unset = "RWDE"', paste(readLines(file.path(top, "lot", "engine", "R", "config_lot.R"), warn = FALSE), collapse = "\n"), fixed = TRUE),
       "...on the same DSN, from the same variable, with the same default")
    for (sib in list(c("TFLS", tfls), c("the dashboard", dash))) {
      src <- paste(readLines(sib[2], warn = FALSE), collapse = "\n")
      ok(!grepl("dbConnect(", src, fixed = TRUE) && grepl("connect_db(", src, fixed = TRUE) &&
           !grepl('Sys.getenv("DATABRICKS_PWD"', src, fixed = TRUE),
         paste0(sib[1], " has no connection of its own: it calls this package's connect_db(), and never reads the password itself"))
    }
  })

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
  # so a pattern anchored on `.S_` would match nothing once it is set and the
  # check would pass by finding nothing.
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

  rv <- paste(capture.output(print(register_codelist_view)), collapse = "\n")
  cl_all <- paste(vapply(Filter(function(x) x$tag == "codelist", RUN$sql),
                         function(x) x$sql, character(1)), collapse = "\n")
  ok(!grepl("UNION ALL", cl_all, fixed = TRUE),
     "the code-list view is not defined in terms of itself when chunked")
  ok(grepl("copy_to", rv) && grepl("codelist_stage_sql", rv) && grepl("is_dbi_con(con)", rv, fixed = TRUE),
     "a code list of thousands of rows is copied over a Spark session and staged as one statement over the ODBC driver - never chunked")
  sf <- paste(capture.output(print(mod_safety)), collapse = "\n")
  # Retry safety, through every comment form a statement can start with: a
  # block-commented INSERT must be classified the same way a bare one is.
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
  # A leading WITH is not a verb: `WITH a AS (...) INSERT INTO t SELECT ...`
  # is a write, and reading the first verb alone would call it retry-safe -
  # which is the duplicate-on-a-lost-acknowledgement this guard exists to
  # prevent.
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
  # RENAMED accepts the insert and keeps the old name with the new meaning.
  # Both must stop BEFORE the scope is cleared.
  # A warehouse DESCRIBE always returns types, so the fixture does too; the
  # missing-type response is tested separately below.
  ens <- function(found, types = NULL) {
    if (is.null(types))
      types <- ifelse(found %in% c("N_AT_RISK", "EXTRA"), "int", "string")
    # Each case is a DIFFERENT run against a different warehouse state. Within
    # one run ensure_table() establishes a shape once and does not re-ask, so
    # without this the second case would be answered from the first's memo -
    # which is the whole point of the memo and would make these checks vacuous.
    ensure_table_reset()
    errs(with_env(base_env, {
      env <- new.env(parent = environment(ensure_table))
      env$db_exec <- function(con, sql) invisible(0L)
      env$db_q <- function(con, sql)
        data.frame(col_name = found, data_type = types,
                   stringsAsFactors = FALSE)
      f <- stubbed(ensure_table, env)
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
  ens_t <- function(cols, types) {
    ensure_table_reset()   # a different run each time, as in ens() above
    errs(with_env(base_env, {
      env <- new.env(parent = environment(ensure_table))
      env$db_exec <- function(con, sql) invisible(0L)
      env$db_q <- function(con, sql)
        data.frame(col_name = cols, data_type = types,
                   stringsAsFactors = FALSE)
      f <- stubbed(ensure_table, env)
      f(NULL, "t", "PATID string, COHORT string, N_AT_RISK int")
    }))
  }
  # The memo that keeps prepare_table() from re-asking once per cohort. It has
  # to save the round trip WITHOUT ever standing in for a check that has not
  # been made: the first call establishes the shape, later ones in the same run
  # are answered from it, and a reset makes the next run ask again.
  local({
    ensure_table_reset()
    asked <- 0L
    run1 <- function(decl, found) with_env(base_env, {
      env <- new.env(parent = environment(ensure_table))
      env$db_exec <- function(con, sql) invisible(0L)
      env$db_q <- function(con, sql) { asked <<- asked + 1L
        data.frame(col_name = found,
                   data_type = ifelse(found == "N_AT_RISK", "int", "string"),
                   stringsAsFactors = FALSE) }
      errs(stubbed(ensure_table, env)(NULL, "t", decl))
    })
    good <- c("PATID", "COHORT", "N_AT_RISK")
    decl <- "PATID string, COHORT string, N_AT_RISK int"
    ok(is.na(run1(decl, good)) && asked == 1L,
       "the first call establishes a table's shape, and asks the warehouse to do it")
    ok(is.na(run1(decl, good)) && asked == 1L,
       "...a second call for the same table and the same shape is answered from that, not from another DESCRIBE")
    ok(!is.na(run1("PATID string, COHORT string", good)) && asked == 2L,
       "...a DIFFERENT declared shape is asked again, so the memo cannot answer a question it was not asked")
    ensure_table_reset()
    ok(is.na(run1(decl, good)) && asked == 3L,
       "...and a reset makes the next run establish it for itself, since a table may have been dropped in between")
    # The guard is not skipped on the strength of a check that did not finish.
    ensure_table_reset()
    ok(!is.na(run1(decl, c("PATID", "COHORT"))) &&
         !is.na(run1(decl, c("PATID", "COHORT"))),
       "a shape that does not match is refused every time it is asked, because a failed check is never recorded as established")
  })

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
    f <- stubbed(ensure_table, env)
    f(NULL, "t", "PATID string, COHORT string, N_AT_RISK int")
  }))
  ok(!is.na(e_notype) && grepl("without a type column", e_notype),
     "a DESCRIBE with no type column stops rather than comparing names alone")

  e_read <- errs(with_env(base_env, {
    env <- new.env(parent = environment(ensure_table))
    env$db_exec <- function(con, sql) invisible(0L)
    env$db_q <- function(con, sql) stop("describe blew up")
    f <- stubbed(ensure_table, env)
    f(NULL, "t", "PATID string")
  }))
  ok(!is.na(e_read) && grepl("could not read the schema", e_read),
     "and a DESCRIBE that fails stops rather than passing as unverifiable")

  # A wide input keeps patients who fail an exclusion so the secondary 2L
  # cohort can have them. IN_COHORT is built from enrolment and follow-up and
  # reads no flag, so without this the SAME record entered the primary 1L
  # cohort - which still excludes prior cancer - alongside SEC2L.
  wide_cols <- c(COHORT_TABLE_REQUIRED, unname(CRITERION_FLAG))
  p1L <- membership_predicate(COHORTS[["1L"]])
  ok(grepl("MET_X2 = 1", p1L, fixed = TRUE) &&
       grepl("coalesce(c.NO_OTHER_CANCER_PRE_LOT1, 1) = 1",
             cohort_flag_pred_one("X2_other_cancer", wide_cols), fixed = TRUE),
     "the primary 1L cohort applies its prior-cancer exclusion from the flags")
  sec <- COHORTS[["SEC2L"]]
  sec$criteria <- setdiff(sec$criteria, "X2_other_cancer")
  ok(!grepl("MET_X2 = 1", membership_predicate(sec), fixed = TRUE),
     "and the secondary 2L cohort, which permits it, does not")
  ok(grepl("MET_X3 = 1", membership_predicate(sec), fixed = TRUE),
     "while still applying the exclusions it keeps")
  ok(identical(cohort_flag_pred_one("X2_other_cancer", COHORT_TABLE_REQUIRED), "1 = 1"),
     "a pre-filtered input carrying no flags is unaffected: its MET_X* is 1 for everyone")
  e_wide <- errs(with_env(base_env, {
    env <- new.env(parent = environment(check_cohort_table))
    env$db_q <- function(con, sql)
      data.frame(col_name = COHORT_TABLE_REQUIRED, stringsAsFactors = FALSE)
    f <- stubbed(check_cohort_table, env)
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
  drug_i <- regexpr("WHEN BEST_CATEGORY IS NOT NULL", soc_sql, fixed = TRUE)
  ok(length(soc_sql) == 1 && cart_i > 0 && drug_i > 0 && cart_i < drug_i,
     "and that branch is reached before the drug-category logic")
  # A size category is a claim about the regimen and holds for unlisted
  # agents too; only a modality category needs a listed agent. So nothing
  # sends an unmatched regimen to 'Other' ahead of the size arms.
  ok(!grepl("WHEN BEST_CATEGORY IS NULL THEN 'Other'", soc_sql, fixed = TRUE) &&
       grepl("N_AGENTS  = 3 AND HAS_CD38_BACKBONE = 0", soc_sql, fixed = TRUE),
     "a regimen no list row names is still sized - s7.2.2's triplet and doublet are size claims")
  ok(grepl("explode(split(trim(coalesce(s.LOT_BASE_MEDS, '')), ", soc_sql, fixed = TRUE),
     "and a NULL regimen string explodes to a row, so a transplant line is kept")
  ok(grepl("year(LOT_START_DT) AS LOT_START_YEAR", soc_sql, fixed = TRUE),
     "and the line's start year is on the SOC row - Table 4, by year")
  ok(grepl("AUTO_FLG AS AUTO_SCT, ALLO_FLG AS ALLO_SCT, CART_FLG AS CART", soc_sql, fixed = TRUE) &&
       grepl("year(AUTO_SCT_DT) AS AUTO_SCT_YEAR", soc_sql, fixed = TRUE),
     "and the engine's line-scoped transplant flags and the transplant's year - Table 6, SCT by year by SOC")
  dem_sql <- vapply(Filter(function(x) x$tag == "step:demographics_1L", RUN$sql),
                    function(x) x$sql, character(1))
  ok(length(dem_sql) == 1 && grepl("coalesce(r.GDR_CD, c.GDR_CD, 'U')", dem_sql, fixed = TRUE),
     "sex is read off the enrolment row that supplies the other attributes, the cohort's copy behind it - s7.8.1")
  per1_sql <- vapply(Filter(function(x) x$tag == "step:periods_1L", RUN$sql),
                     function(x) x$sql, character(1))
  ok(length(per1_sql) == 1 && grepl("year(co.INDEX_DATE) AS INDEX_YEAR", per1_sql, fixed = TRUE),
     "and the index year is on the periods row - Table 4, year of index")

  # The funnel has to APPLY the exclusions it reports, not merely list them,
  # or its final N_REMAINING can exceed the cohort it describes. The executed
  # reconciliation cannot see this on a fixture where every flag is 1, so the
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
    f <- stubbed(check_cohort_table, env)
    f(NULL, cfg0())
  }))
  ok(!is.na(e_thin) && grepl("INDEX_DATE", e_thin),
     "a cohort table of ids and flags is refused, naming what it lacks")
  e_full <- errs(with_env(base_env, {
    env <- new.env(parent = environment(check_cohort_table))
    env$db_q <- function(con, sql)
      data.frame(col_name = c(COHORT_TABLE_REQUIRED, "EXTRA"),
                 stringsAsFactors = FALSE)
    f <- stubbed(check_cohort_table, env)
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
    f <- stubbed(check_cohort_table, env)
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

  # An endpoint whose DEFINITION is an admission. Read from every diagnosis
  # row it would count outpatient codes under the protocol's name, so a
  # hospitalisation-named condition has to say `inpatient`; said, it runs.
  # The fixtures are the valid form, so the invalid one is constructed here.
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
  ok(!is.na(e_hosp) && grepl("defined by an admission", e_hosp) &&
       grepl("setting=inpatient", e_hosp, fixed = TRUE),
     "a hospitalisation-defined endpoint with no inpatient setting stops rather than counting outpatient codes, naming the column")
  hosp_ok <- hosp_cl; hosp_ok$setting <- c("inpatient", "")
  ok(is.na(errs(check_safety_list(cfg0(), hosp_ok))),
     "...and passes once its rows say inpatient, a blank setting reading as any")
  hosp_bad <- hosp_cl; hosp_bad$setting <- c("inpatient", "outpatient")
  ok(grepl("setting value", errs(check_safety_list(cfg0(), hosp_bad))),
     "...while a setting word this module does not know stops rather than reading every row")
  hosp_clash <- hosp_ok; hosp_clash$condition[2] <- "anemia (hospitalisation)"
  ok(grepl("reserved", errs(check_safety_list(cfg0(), hosp_clash))),
     "...and a condition spelled like the derived hospitalisation series is refused")

  # The malignancy list may not carry a myeloma code: a secondary malignancy
  # is a malignancy OTHER than the one under treatment, and a myeloma code
  # would confirm every patient's own disease on their first two claims.
  # The check reads mm_dx.csv through the configuration, so it is pointed at
  # the fixture lists, whose mm_dx.csv carries C900 (ICD-10) and 2030 (ICD-9).
  cfg_fx <- cfg0(); cfg_fx$codelist_dir <- "tests/fixtures/codelists"
  mal_cl <- load_codelist("secondary_malig.csv", cfg_fx)
  ok(is.na(errs(check_malignancy_list(cfg_fx, mal_cl))),
     "a malignancy list with no myeloma code passes")
  mal_bad <- mal_cl[1, , drop = FALSE]
  mal_bad$code <- "C90.0"; mal_bad$icd_family <- "ICD-10"
  e_mal <- errs(check_malignancy_list(cfg_fx, rbind(mal_cl, mal_bad)))
  ok(!is.na(e_mal) && grepl("multiple myeloma", e_mal, fixed = TRUE) && grepl("C90.0", e_mal, fixed = TRUE),
     "...and one carrying a code mm_dx.csv names as myeloma is refused, naming the code - Table 4")
  mal_9 <- mal_bad; mal_9$code <- "203.0"; mal_9$icd_family <- "9"
  ok(!is.na(errs(check_malignancy_list(cfg_fx, rbind(mal_cl, mal_9)))),
     "...compared the way the SQL joins: punctuation stripped, within the ICD family")
  mal_other <- mal_bad; mal_other$icd_family <- "ICD9"
  ok(is.na(errs(check_malignancy_list(cfg_fx, rbind(mal_cl, mal_other)))),
     "...so the same digits under the other family are not a clash")
  ok(identical(MODULES$malignancy$check, "check_malignancy_list") &&
       "mm_dx.csv" %in% MODULES$malignancy$codelists,
     "and the preflight runs that check before the connection is opened")
  # What reaches the SQL: the claim key business rule 13 and the join diagram
  # document, the confinement for the admit date, and the derived series.
  sf_sql <- paste(vapply(Filter(function(x) grepl("^step:safety_events_1L", x$tag), RUN$sql),
                         function(x) x$sql, character(1)), collapse = "\n")
  ok(grepl("m.PAT_PLANID <=> d.PAT_PLANID", sf_sql, fixed = TRUE) &&
       grepl("m.CLMID = d.CLMID", sf_sql, fixed = TRUE) &&
       grepl("m.LOC_CD <=> d.LOC_CD", sf_sql, fixed = TRUE) &&
       grepl("m.CONF_ID IS NOT NULL AND trim(m.CONF_ID) <> ''", sf_sql, fixed = TRUE),
     "an inpatient safety event is a diagnosis on a claim carrying a confinement id, joined on the full claim key - business rule 14")
  ok(grepl("cf.CONF_ID = m.CONF_ID", sf_sql, fixed = TRUE) &&
       grepl("cast(cf.ADMIT_DATE as date) AS ADMIT_DT", sf_sql, fixed = TRUE),
     "...and the confinement supplies the admission date")
  ok(grepl("WHEN setting = 'inpatient' THEN ADMIT_DT ELSE FST_DT END AS EVENT_DT", sf_sql, fixed = TRUE) &&
       grepl("WHERE setting = 'any' OR INPATIENT = 1", sf_sql, fixed = TRUE),
     "an inpatient-defined condition is its admissions, dated at the admit date; any other is every claim")
  ok(grepl("WHERE ac = 'chronic' AND setting = 'any' AND INPATIENT = 1", sf_sql, fixed = TRUE) &&
       grepl("concat(condition, ' (hospitalisation)')", sf_sql, fixed = TRUE) &&
       grepl("'acute' AS ACUTE_CHRONIC", sf_sql, fixed = TRUE),
     "and every chronic condition's hospitalisations are an acute series of their own - Figure 3")
  sc_sql <- paste(vapply(Filter(function(x) grepl("s_safety_conditions AS", x$sql, fixed = TRUE), RUN$sql),
                         function(x) x$sql, character(1)), collapse = "\n")
  ok(nzchar(sc_sql) && grepl("lower(acute_chronic) = 'chronic' AND lower(setting) = 'any'", sc_sql, fixed = TRUE),
     "...and the rate rows are driven from that list, so the series gets a row of zeros where nothing happened")
  # s7.8.1: "calculated as individual conditions within categories, and
  # aggregated" - one row per domain beside the conditions' own.
  dg_sql <- paste(vapply(Filter(function(x) grepl("^step:safety_treatment_domain_total_1L", x$tag), RUN$sql),
                         function(x) x$sql, character(1)), collapse = "\n")
  ok(nzchar(dg_sql) && grepl("'(any in domain)' AS CONDITION", dg_sql, fixed = TRUE) &&
       grepl("'aggregate' AS ACUTE_CHRONIC", dg_sql, fixed = TRUE),
     "every domain gets an aggregate row beside its conditions - s7.8.1, 'and aggregated'")
  ok(grepl("count(DISTINCT h.CONDITION) AS N_PRIOR", dg_sql, fixed = TRUE) &&
       grepl("coalesce(hp.N_PRIOR, 0) < dm.N_COND THEN p.PERIOD_PY", dg_sql, fixed = TRUE),
     "...on treatment a patient is at risk of the aggregate while at risk of any condition in it, for the whole period")
  ok(grepl("INNER JOIN (SELECT DISTINCT condition, domain FROM S_CL_SAFETY) cl", dg_sql, fixed = TRUE) &&
       grepl("ON cl.condition = n.CONDITION", dg_sql, fixed = TRUE),
     "...and its numerator is the list's own conditions, so the derived hospitalisation series is not counted twice")

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

  sfc <- paste(capture.output(print(check_safety_list)), collapse = "\n")
  ok(grepl("canonical_acute_chronic", sfc) && grepl("cl <- check_safety_list(cfg, cl)", sf, fixed = TRUE),
     "acute_chronic is resolved to one rule before it reaches SQL - in the check the module takes its list from")
  ok(!grepl("LIKE '%acute%'", sf, fixed = TRUE),
     "so 'Acute or chronic' is not counted through both counting rules")
  ok(!("index_excluded_abbrs" %in% names(cfg0())),
     "the dead 1L index-agent setting is gone - that rule is the cohort build's")
  ok("malignancies" %in% PROTOCOL_CHRONIC_CONDITIONS,
     "the s7.8.1 chronic cross-check covers Objective 3's own condition")
  cm <- paste(capture.output(print(mod_comorbidity)), collapse = "\n")
  ok(grepl("supersedes", cm),
     "Charlson applies Quan's hierarchy where the code list declares it")
}

cat("\nthe cohort build barred the agents s7.2.1.1 names from the 1L index\n")
{
  # s7.2.1.1 I3: "Exclusions include: panobinostat and elotuzumab". Only the
  # cohort build applies that, and it records what it barred as LIKE patterns
  # on NDMM_RUN_METADATA.INDEX_EXCLUDED. This resolves the names through the
  # rollup and requires every abbreviation matched.
  rollup <- data.frame(CL_MEDICATION_FULL = c("Panobinostat", "elotuzumab", "daratumumab"),
                       CL_MED_CLASS = c("HDAC", "mAb", "anti-CD38"),
                       CL_MED_ABBR = c("PANO", "ELO", "DARA"),
                       stringsAsFactors = FALSE)
  idx_check <- function(recorded, cfg = cfg0(), rl = rollup, err = NULL,
                        no_rows = FALSE, run_id = "c1") {
    e <- new.env(parent = environment(check_cohort_index_exclusions))
    e$db_q <- function(con, sql) {
      if (!is.null(err)) stop(err)
      if (no_rows) return(data.frame(RUN_ID = character(0), INDEX_EXCLUDED = character(0)))
      data.frame(RUN_ID = "c1", INDEX_EXCLUDED = recorded, stringsAsFactors = FALSE)
    }
    e$load_codelist <- function(...) if (inherits(rl, "error")) stop(rl) else rl
    e$log_msg <- function(...) invisible(NULL)
    errs(stubbed(check_cohort_index_exclusions, e, character(0))(NULL, cfg, run_id))
  }
  ok(is.na(idx_check("PANO,ELO")),
     "a build that barred both agents, by abbreviation, is accepted")
  ok(is.na(idx_check("PANO%|EL_")),
     "...and so is one that barred them by the LIKE patterns the cohort build takes")
  e_none <- idx_check("")
  ok(!is.na(e_none) && grepl("did not bar panobinostat (PANO), elotuzumab (ELO)", e_none, fixed = TRUE) &&
       grepl("attempt c1", e_none, fixed = TRUE),
     "a build that barred neither stops, naming both agents, their abbreviations and the attempt")
  e_one <- idx_check("PANO")
  ok(!is.na(e_one) && grepl("did not bar elotuzumab (ELO)", e_one, fixed = TRUE) &&
       !grepl("panobinostat (PANO)", e_one, fixed = TRUE),
     "...and one that barred only panobinostat stops naming elotuzumab alone")
  ok(!is.na(idx_check("PAN")) && is.na(idx_check("PAN%,ELO")),
     "a pattern is matched as SQL LIKE, so PAN bars nothing and PAN% bars PANO")
  ok(is.na(idx_check("PANO", rl = rollup[rollup$CL_MED_ABBR != "ELO", ])),
     "an agent not on the rollup cannot set an index, so its absence from the bar list is not a failure")
  ok(is.na(idx_check("", cfg = with_env(c(base_env, COHORT_INDEX_EXCLUSIONS = "none"), cfg_defaults()))),
     "COHORT_INDEX_EXCLUSIONS=none checks nothing")
  ok(is.na(idx_check("", err = "TABLE_OR_VIEW_NOT_FOUND")),
     "a cohort build with no run metadata is unverified, not refused")
  ok(is.na(idx_check("", err = "[UNRESOLVED_COLUMN] A column with name `INDEX_EXCLUDED` cannot be resolved")),
     "...and so is one whose metadata predates the column")
  e_perm <- idx_check("", err = "PERMISSION_DENIED: cannot read")
  ok(!is.na(e_perm) && grepl("could not read", e_perm) && grepl("LOT_ALLOW_UNPROVEN_LINEAGE", e_perm),
     "...while metadata that could not be read is unproven and stops without the waiver")
  ok(is.na(idx_check("", err = "PERMISSION_DENIED: cannot read",
                     cfg = with_env(c(base_env, LOT_ALLOW_UNPROVEN_LINEAGE = "TRUE"), cfg_defaults()))),
     "...and continues under it")
  ok(is.na(idx_check("", no_rows = TRUE)),
     "and no row for the attempt is unverified rather than refused")
  ok(is.na(idx_check("", rl = simpleError("CODELIST ERROR: cl_mma_rollup.csv has no data rows."))),
     "and a rollup that is not usable here leaves the check unverified, not failed")
  ok(like_matches("PANO%", "PANOBINOSTAT") && like_matches("pano", "PANO") &&
       !like_matches("PANO", "PANOB") && like_matches("P_NO", "PANO") &&
       !like_matches("P.NO", "PANO"),
     "LIKE: % is any run, _ is one character, and a dot is a dot")
  rsrc <- paste(readLines("R/run_223926.R", warn = FALSE), collapse = "\n")
  ok(grepl("check_cohort_index_exclusions(con, cfg, lot_run$COHORT_ATTEMPT_ID", rsrc, fixed = TRUE),
     "the runner asks it of the cohort attempt the LOT run was built from")
  ok(identical(cfg0()$cohort_index_exclusions, "panobinostat,elotuzumab"),
     "and the shipped default is the protocol's two agents")
}

cat("\nstandalone\n")
{
  # Nothing this package runs may reach outside its own directory. The folder
  # is meant to be liftable - moved, or handed on, without carrying a trail of
  # neighbours it silently needs.
  r_files <- c(list.files("R", pattern = "[.]R$", full.names = TRUE),
               list.files("R/modules", pattern = "[.]R$", full.names = TRUE),
               "build.R")
  src <- setNames(lapply(r_files, function(f) paste(readLines(f, warn = FALSE),
                                                    collapse = "\n")), r_files)
  # Comments and error messages cite the documents beside the package, and
  # ../OPEN_QUESTIONS.md resolves inside variables/, which is the
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
  # A directory the package does not own. The point is that no code path names
  # one at all: what ships alongside is reached relatively, and anything else is
  # a working directory that does not travel with the package.
  own_dirs <- c("R", "modules", "tests", "codelists", "fixtures")
  # Two shapes: a path with a second segment that carries an extension or a
  # further slash, and a first segment with a space in it, which no directory
  # this package reaches ever has.
  named <- lapply(code_only, function(x)
    sub("/.*$", "", sub('^"', "", unlist(regmatches(x, gregexpr(
      paste0('"[A-Za-z][A-Za-z0-9_ -]*/[A-Za-z0-9_. -]*[/.]',
             '|"[A-Za-z][A-Za-z0-9_-]* [A-Za-z0-9_ -]*/'), x))))))
  repo <- names(Filter(function(v) length(setdiff(v, own_dirs)) > 0, named))
  ok(length(repo) == 0,
     paste0("no code path names a directory outside the package (offenders: ",
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
# Everything above reads source text, which cannot say whether a module's SQL
# parses or whether its R reaches the end of the function - a semicolon inside
# a `--` comment, a missing comma between two CTEs and a `[[` on an absent name
# are all invisible to it. So the modules are run here against recorders, for
# every cohort, and every statement they emit is parsed.

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
    skip_note("every emitted statement parses as Spark SQL (python3 + sqlglot not available)")
  } else {
    ok(grepl("0 failure\\(s\\)", txt),
       paste0("every emitted statement parses as Spark SQL",
              if (!grepl("0 failure", txt)) paste0("\n", txt) else ""))
  }
  unlink(f)

  # The attrition funnel is monotone by construction: a step can only remove
  # rows, so N_REMAINING can never go back up mid-funnel.
  # --- the CDM table names are the warehouse's, not ours -----------------
  #
  # The modules ask cdm_src() for a SHORT name ("diagnosis") because that is
  # what ../DATA_MAPPING.md calls the table in prose, while the physical table
  # is `t_med_diagnosis_<quarter>`.
  #
  # The executing harness creates its fixtures from whatever name the code
  # emits, so it cannot see that gap. The physical names are therefore pinned
  # here as literals, against the cohort build's own config - the one that has
  # actually run against this warehouse.
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

  # The policy, not just the plumbing: this SQL is the only place the rule
  # exists, so it is asserted against what the module actually emits.
  #
  # The predicate is READ OUT of the emitted SQL rather than rebuilt here. A
  # test that constructs the same string it looks for only asserts that the
  # code has not changed; what the policy IS is asserted below and by execution.
  min_n <- as.integer(cfg0()$suppress_min_n)
  # Per table, not over the concatenation: searching all six statements at once
  # finds the FIRST "... ELSE N_PATIENTS END" anywhere, which belongs to
  # S_SAFETY_RATES where N_PATIENTS is a value column suppressed on N_AT_RISK.
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
  # away by subtraction, not just the first one.
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
  # Joined WITH a trailing newline: the pattern below ends at ")\n", and the
  # last statement in a collapse has none - so whichever table happened to be
  # created last read as having no DDL at all.
  ddl <- paste0(paste(vapply(Filter(function(x)
      grepl("^CREATE TABLE IF NOT EXISTS", x$sql), run$sql),
      function(x) x$sql, character(1)), collapse = "\n"), "\n")
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
  # alternative, and require the emitted SQL to DIFFER. A setting that is not
  # applied fails here rather than being recorded on every run as the reading
  # that produced the numbers.
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
    comorbid_subgroups = function(c) { c$comorbid_subgroups <- TRUE; c },
    cohort_nested = function(c) { c$cohort_nested <- FALSE; c },
    dx_date_source = function(c) { c$dx_date_source <- "baseline_first_claim"; c },
    malig_prevalence_window = function(c) { c$malig_prevalence_window <- "baseline"; c }
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
  # or that a second run does not double every count.
  #
  # So the statements are run: transpiled to DuckDB and executed against the
  # fixtures in tests/fixtures/cdm, whose answers are derived by hand in
  # tests/fixtures/EXPECTED.md. DuckDB is not Spark, so what is checked here is
  # the arithmetic, not the dialect.
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
    skip_note("the emitted SQL executes and its numbers are right (python3 + duckdb + sqlglot not available)")
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

  # --- and the same, under the two readings the default run never emits ---
  #
  # DX_DATE_SOURCE=baseline_first_claim scans the diagnosis table for Table
  # 4's own diagnosis date, ENROL_ATTR_AT=latest_span takes the most recent
  # enrolment row instead of the one at the index, and
  # MALIG_PREVALENCE_WINDOW=baseline takes the 12-month window for the
  # secondary cohort's malignancy prevalence. None of those statements is in
  # the default run, so each is executed here against its own goldens
  # (tests/expectations_alt.py), derived in tests/fixtures/EXPECTED.md.
  alta <- with_env(base_env, capture_emitted_sql(".", function(cfg) {
    cfg$dx_date_source <- "baseline_first_claim"
    cfg$enrol_attr_at <- "latest_span"
    cfg$malig_prevalence_window <- "baseline"; cfg }))
  ok(length(alta$errors) == 0,
     paste0("the run builds under the alternative diagnosis-date and enrolment-row readings",
            if (length(alta$errors))
              paste0(" [", paste(names(alta$errors), collapse = ", "), "]") else ""))
  sfa <- tempfile(fileext = ".sql")
  cona <- file(sfa, "w")
  for (x in alta$sql) {
    cat("-- @@STMT ", x$tag, "\n", sep = "", file = cona)
    cat(x$sql, "\n", file = cona)
  }
  close(cona)
  sda <- file.path(tempdir(), "staged_a")
  unlink(sda, recursive = TRUE); dir.create(sda, showWarnings = FALSE)
  for (n in names(alta$staged))
    utils::write.csv(alta$staged[[n]], file.path(sda, paste0(n, ".csv")),
                     row.names = FALSE)
  aout <- suppressWarnings(tryCatch(
    system2("python3", c("tests/run_duckdb.py", shQuote(sfa), shQuote(sda),
                         "tests/fixtures/cdm", shQuote(cfg0()$object_prefix),
                         "tests/expectations_alt.py"),
            stdout = TRUE, stderr = TRUE),
    error = function(e) "NO-PYTHON"))
  atxt <- paste(aout, collapse = "\n")
  if (any(grepl("^SKIP:", aout)) || identical(atxt, "NO-PYTHON") || !length(aout)) {
    skip_note("the alternative readings execute and their numbers are right (python3 + duckdb + sqlglot not available)")
  } else {
    ok(grepl("0 failed", atxt),
       paste0("every statement of the alternative readings executes",
              if (!grepl("0 failed", atxt)) paste0("\n", atxt) else ""))
    ok(grepl("0 wrong", atxt),
       paste0("and Table 4's diagnosis date, the latest enrolment row and the baseline prevalence window come out as derived",
              if (!grepl("0 wrong", atxt)) paste0("\n", atxt) else ""))
  }
  unlink(c(sfa, sda), recursive = TRUE)

  # --- and the same, with the Q27 route switched -------------------------
  #
  # MM_HOSP_POSITION=claim_positions replaces the whole MM-related subquery
  # with one that reads MED_DIAGNOSIS instead of CONFINEMENT. That SQL is never
  # emitted by the default run, so without this it would be the one statement
  # in the package nothing had ever executed.
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
    skip_note("the claim-position route executes too (python3 + duckdb + sqlglot not available)")
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
  # Up to the arm's own close, not the first ')': every accumulated predicate
  # is parenthesised, so the WHERE carries parentheses of its own.
  # count(*) or count(DISTINCT ...): the arms that say where the funnel started
  # count patients across the engine's lines, which is one row per line.
  arms <- if (length(attr_sql))
    regmatches(attr_sql, gregexpr("(?s)SELECT count\\([^)]*\\) FROM .*?\\) AS N_REMAINING",
                                  attr_sql, perl = TRUE))[[1]] else character(0)
  # One per criterion, plus the two that say where the funnel's population
  # came from: 1L is nobody's subset, so it starts from the engine's lines and
  # the step below that is what the engine's own criteria removed.
  ok(length(arms) == length(COHORTS[["1L"]]$criteria) + 2L,
     "with one count per criterion, after the two that say where it started")
  ok(grepl("LOT_LONG_ALLFLAGS", attr_sql[1], fixed = TRUE) &&
       grepl("'indexed_at_line'", attr_sql[1], fixed = TRUE) &&
       grepl("'lot_line_criteria'", attr_sql[1], fixed = TRUE),
     paste0("...and the first two read the engine's own lines, so the ",
            "belantamab truncation is a loss the funnel shows rather than a ",
            "population it silently starts below"))
  a2_sql <- vapply(Filter(function(x) x$tag == "step:attrition_2L", run$sql),
                   function(x) x$sql, character(1))
  ok(length(a2_sql) == 1 &&
       grepl("'in_1L_cohort'", a2_sql, fixed = TRUE) &&
       !grepl("LOT_LONG_ALLFLAGS", a2_sql, fixed = TRUE),
     paste0("a nested cohort starts from the cohort it is drawn from instead, ",
            "so N1_received_line's loss is those who did not go on to it"))
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
# THIS FILE sources every module before it asserts anything, and a production
# run does not: build.R loads the common helpers and calls build_223926(),
# which loads the modules itself. A helper that reaches into a module before
# source_modules() runs is invisible to every other assertion here.
#
# Only a real process can see it. DRY_RUN prints the plan and returns without a
# connection, so this costs one R startup and needs no warehouse.
local({
  rs <- file.path(R.home("bin"), "Rscript")
  # The settings go into THIS process's environment, which the child inherits.
  # system2(env = ...) prefixes them onto the command line instead, which on
  # Windows exits 5 with no output.
  out <- with_env(c(DRY_RUN = "TRUE", INPUT_COHORT_TABLE = "t", OBJECT_PREFIX = "s223926_"),
    suppressWarnings(system2(rs, shQuote(file.path(here, "build.R")),
      stdout = TRUE, stderr = TRUE)))
  code <- attr(out, "status")
  ok(is.null(code) || identical(as.integer(code), 0L),
     paste0("build.R resolves and prints a plan in a fresh R process",
            if (!is.null(code))
              paste0("  [exit ", code, ": ",
                     paste(utils::tail(out, 3), collapse = " / "), "]") else ""))
  ok(any(grepl("DRY_RUN=TRUE", out, fixed = TRUE)),
     "...and reaches the dry-run line, rather than exiting somewhere earlier")
  # The failure this replaces was a missing function, which R reports this
  # way, so the failure reads as itself rather than as a bad exit code.
  ok(!any(grepl("could not find function", out, fixed = TRUE)),
     "...with no helper reaching for something the process has not loaded")
})

cat("\n-- membership follows the criteria list --\n")
# Removing a criterion from a cohort's list has to remove it from membership,
# not only from the funnel, and adding one has to add it to both. IN_COHORT and
# the funnel read the same two maps, and the checks below hold the emitted SQL
# to that.
in_cohort_pred <- function(sql)
  regmatches(sql, regexpr("(?s)CASE WHEN (.*?) THEN 1 ELSE 0 END AS IN_COHORT",
                          sql, perl = TRUE))
met_set <- function(x) sort(unique(regmatches(x, gregexpr("MET_[A-Z0-9]+ = 1", x))[[1]]))
last_arm_where <- function(attr_sql) {
  arms <- regmatches(attr_sql, gregexpr("(?s)SELECT count\\(\\*\\) FROM .*?\\) AS N_REMAINING",
                                        attr_sql, perl = TRUE))[[1]]
  arms[length(arms)]
}
step_sql <- function(r, tag) {
  x <- vapply(Filter(function(x) identical(x$tag, tag), r$sql),
              function(x) x$sql, character(1))
  if (length(x) == 1L) x else NA_character_
}
{
  coh_sql <- step_sql(run, "step:cohort_1L")
  ok(!is.na(coh_sql), "the 1L membership statement is emitted once")
  in_coh <- in_cohort_pred(coh_sql)
  ok(length(in_coh) == 1L && grepl("MET_N2 = 1", in_coh, fixed = TRUE),
     "with I4 in the 1L list, membership tests continuous enrolment on the line's index")
  ok(grepl("MET_I5 = 1", in_coh, fixed = TRUE),
     "...and follow-up, where I5 is in the list")
  ok(all(c("MET_X1 = 1", "MET_X2 = 1", "MET_X3 = 1", "MET_X4 = 1") %in% met_set(in_coh)),
     "...and every exclusion the list names, off the MET_X* columns")
  # Membership IS the funnel's last step: the same set of predicates, for
  # every cohort. The executing harness checks the two NUMBERS agree on the
  # fixture; this checks the SQL cannot express anything else.
  for (ck in names(COHORTS)) {
    m <- in_cohort_pred(step_sql(run, paste0("step:cohort_", ck)))
    a <- last_arm_where(step_sql(run, paste0("step:attrition_", ck)))
    ok(length(m) == 1L && identical(met_set(m), met_set(a)),
       paste0(ck, ": IN_COHORT and the funnel's last step apply the same predicates",
              " [", paste(met_set(m), collapse = " "), "]"))
  }
  msrc <- paste(readLines("R/modules/01_cohorts.R", warn = FALSE), collapse = "\n")
  ok(identical(criterion_predicates("I4_ce_pre"), "MET_N2 = 1") &&
       identical(criterion_predicates("X2_other_cancer"), "MET_X2 = 1") &&
       is.null(criterion_predicates("I1_mm_dx")) &&
       identical(membership_predicate(COHORTS[["1L"]]),
                 and_predicates(unlist(lapply(COHORTS[["1L"]]$criteria, criterion_predicates)))),
     "...because membership is the funnel's own per-criterion predicate list, composed once")
  ok(identical(CRITERION_SOURCE[["X4_belantamab"]], "cohort"),
     "the pre-1L belantamab flag is read off the cohort table, like the other exclusions")

  # --- a criterion nobody wrote code for --------------------------------
  # The guide says a criterion is added by listing it, naming its source and
  # giving it a predicate. So it is: I4_custom_ce - `here`, `MET_N2 = 1`, in
  # place of I4 - reaches membership as well as the funnel.
  custom <- with_env(base_env, capture_emitted_sql(".", env_edit = function(env) {
    env$CRITERION_SOURCE[["I4_custom_ce"]] <- "here"
    env$HERE_PRED[["I4_custom_ce"]] <- "MET_N2 = 1"
    env$COHORTS[["1L"]]$criteria <-
      sub("^I4_ce_pre$", "I4_custom_ce", env$COHORTS[["1L"]]$criteria)
    env
  }))
  ok(length(custom$errors) == 0,
     paste0("a cohort listing a custom `here` criterion still builds",
            if (length(custom$errors))
              paste0(" [", paste(names(custom$errors), collapse = ", "), "]") else ""))
  cm <- in_cohort_pred(step_sql(custom, "step:cohort_1L"))
  ca <- step_sql(custom, "step:attrition_1L")
  ok(length(cm) == 1L && grepl("MET_N2 = 1", cm, fixed = TRUE),
     "the custom criterion's predicate reaches membership")
  ok(grepl("'I4_custom_ce'", ca, fixed = TRUE) &&
       grepl("'here' AS APPLIED_BY", ca, fixed = TRUE),
     "...and the funnel reports it as a step this package applied")
  ok(identical(met_set(cm), met_set(last_arm_where(ca))),
     "...and the two agree on what admits a patient")
  # Declared `here` with nothing to apply: a criterion in name only. Stopped
  # before any table is touched, naming the map that is missing it.
  e_np <- errs(with_env(base_env, {
    env <- new.env(parent = environment(mod_cohorts))
    env$CRITERION_SOURCE <- c(CRITERION_SOURCE, I9_unwritten = "here")
    f <- mod_cohorts; environment(f) <- env
    co <- COHORTS[["1L"]]; co$criteria <- c(co$criteria, "I9_unwritten")
    f(NULL, cfg0(), co)
  }))
  ok(!is.na(e_np) && grepl("HERE_PRED gives no predicate", e_np) &&
       grepl("I9_unwritten", e_np),
     "a criterion declared `here` with no predicate stops the run, naming itself")
  ok(is.na(errs(with_env(base_env, {
    env <- new.env(parent = environment(mod_cohorts))
    env$db_exec <- function(con, sql) invisible(0L)
    env$db_q <- function(con, sql) data.frame(col_name = c("PATID", "COHORT"),
                                              data_type = "string")
    env$run_step <- function(con, name, sql, qc = NULL, allow_empty = FALSE) invisible(NULL)
    env$ensure_table <- function(con, name, schema_sql) invisible(name)
    env$prepare_table <- function(con, name, schema_sql, cohort_key) invisible(name)
    f <- mod_cohorts; environment(f) <- env
    f(NULL, cfg0(), COHORTS[["1L"]])
  }))), "...while the shipped list, every `here` criterion with a predicate, does not")

  # The same script, executed: the custom criterion re-derives what I4 did,
  # so every golden number - including the two that hold the funnel's last
  # step to count(IN_COHORT = 1) - has to come out unchanged.
  sfc <- tempfile(fileext = ".sql")
  conc <- file(sfc, "w")
  for (x in custom$sql) {
    cat("-- @@STMT ", x$tag, "\n", sep = "", file = conc)
    cat(x$sql, "\n", file = conc)
  }
  close(conc)
  sdc <- file.path(tempdir(), "staged_custom")
  unlink(sdc, recursive = TRUE); dir.create(sdc, showWarnings = FALSE)
  for (n in names(custom$staged))
    utils::write.csv(custom$staged[[n]], file.path(sdc, paste0(n, ".csv")),
                     row.names = FALSE)
  coutx <- suppressWarnings(tryCatch(
    system2("python3", c("tests/run_duckdb.py", shQuote(sfc), shQuote(sdc),
                         "tests/fixtures/cdm", shQuote(cfg0()$object_prefix)),
            stdout = TRUE, stderr = TRUE),
    error = function(e) "NO-PYTHON"))
  ctxt <- paste(coutx, collapse = "\n")
  if (any(grepl("^SKIP:", coutx)) || identical(ctxt, "NO-PYTHON") || !length(coutx)) {
    skip_note("a custom criterion admits exactly the funnel's last step (python3 + duckdb + sqlglot not available)")
  } else {
    ok(grepl("0 failed", ctxt) && grepl("0 wrong", ctxt),
       paste0("executed, a custom criterion admits exactly the funnel's last step",
              if (!grepl("0 failed", ctxt) || !grepl("0 wrong", ctxt))
                paste0("\n", ctxt) else ""))
  }
  unlink(c(sfc, sdc), recursive = TRUE)
}

cat("\n-- config.csv is every setting, and stays that way --\n")
{
  # CONTENTS.md and MODULES.md both say this file holds every setting. Nothing
  # held them to it, and nine were absent: six of the eight CDM table names,
  # the two retry knobs, and SETTINGS_OVERRIDE - the one that lets a run
  # proceed against a cohort it disagrees with. A setting a reader cannot find
  # in the settings file is a setting they do not know they have.
  cfg_src <- paste(readLines("R/config_223926.R", warn = FALSE), collapse = "\n")
  decl <- unique(sub('.*"([A-Z_0-9]+)".*', "\\1",
    regmatches(cfg_src,
      gregexpr('[.]env_(chr|int|lgl|date|num)[(]"[A-Z_0-9]+"', cfg_src))[[1]]))
  listed <- utils::read.csv("config.csv", stringsAsFactors = FALSE)$name
  absent <- setdiff(decl, listed)
  ok(length(decl) > 40,
     sprintf("the settings are read off the config builder itself (%d)", length(decl)))
  ok(length(absent) == 0,
     paste0("every setting the builder reads has a row in config.csv",
            if (length(absent))
              paste0(" [absent: ", paste(absent, collapse = ", "), "]") else ""))
}

cat("\n-- a run's version is its build, not its id --\n")
# DOMINO_RUN_ID is reused by every build inside one Domino run, and the LOT
# engine keeps its run id for a session. Two builds under one id are told
# apart by the timestamp their status row carries, and S_RUN_METADATA now
# records the LOT build's beside its id.
{
  ok(identical(run_version_stamp(as.POSIXct("2026-09-08 11:05:00", tz = "UTC")),
               "20260908T110500Z"),
     "a timestamp becomes one UTC stamp")
  ok(identical(run_version_stamp(as.POSIXct("2026-09-08 13:05:00", tz = "Europe/Berlin")),
               "20260908T110500Z"),
     "...the same stamp for the same instant, whatever zone it was read in")
  ok(identical(run_version_stamp("2026-09-08 11:05:00"), "20260908T110500Z") &&
       identical(run_version_stamp("2026-09-08T11:05:00"), "20260908T110500Z"),
     "...and from the string forms a CSV or a driver returns")
  ok(identical(run_version_stamp(""), "") && identical(run_version_stamp(NULL), "") &&
       identical(run_version_stamp(NA), ""),
     "nothing is not a version")
  ok(identical(run_version_stamp("build 7"), "build7") &&
       grepl("^[A-Za-z0-9]+$", run_version_stamp("2026-09-08 11:05:00")),
     "and a stamp is always one path segment")
  ok(identical(lot_run_version(list(RUN_ID = "r1", UPDATED_AT = "2026-09-01 00:00:00")),
               "20260901T000000Z") &&
       identical(lot_run_version(list(RUN_ID = "unproven")), ""),
     "the LOT build's version is its status row's stamp, and an unproven lineage has none")
  st_row <- data.frame(RUN_ID = "r1", STATE = "complete", UPDATED_AT = "2026-09-01 00:00:00",
                       stringsAsFactors = FALSE)
  ok(lot_build_owns(st_row, "r1", "20260901T000000Z") && lot_build_owns(st_row, "r1", "") &&
       !lot_build_owns(st_row, "r1", "20260902T000000Z") && !lot_build_owns(st_row, "r2") &&
       !lot_build_owns(transform(st_row, STATE = "started"), "r1") && !lot_build_owns(NULL, "r1"),
     "one rule says whether a status row is the accepted build: this id, complete, this stamp where recorded")

  # The metadata write: names its columns, carries the version, and upgrades
  # an older table rather than inserting into it positionally.
  meta_run <- function(schema_cols) {
    said <- character(0)
    env <- new.env(parent = environment(write_run_metadata))
    env$db_exec <- function(con, sql) { said <<- c(said, sql); invisible(0L) }
    env$db_q <- function(con, sql) data.frame(
      col_name = schema_cols,
      data_type = unname(RUN_METADATA_COLS[match(schema_cols, names(RUN_METADATA_COLS))]),
      stringsAsFactors = FALSE)
    env$log_msg <- function(...) invisible(NULL)
    # The column upgrade reads db_q through its own environment.
    f <- stubbed(write_run_metadata, env)
    with_env(base_env, f(NULL, cfg0(), COHORTS["1L"], MODULES["spine"],
                         list(RUN_ID = "r1", UPDATED_AT = "2026-09-01 00:00:00"),
                         character(0), "complete", run_id = "rid1"))
    said
  }
  full <- meta_run(names(RUN_METADATA_COLS))
  ins <- grep("^INSERT INTO", full, value = TRUE)
  ok(length(ins) == 1L && grepl("(RUN_ID, STATE, UPDATED_AT, ", ins, fixed = TRUE),
     "the metadata insert names its columns")
  ok(grepl("LOT_RUN_VERSION", ins, fixed = TRUE) && grepl("'20260901T000000Z'", ins, fixed = TRUE),
     "...and records which build of the LOT run these numbers rest on")
  ok(!any(grepl("ALTER TABLE", full, fixed = TRUE)),
     "a table already in shape is not altered")
  older <- meta_run(setdiff(names(RUN_METADATA_COLS), "LOT_RUN_VERSION"))
  alt <- grep("^ALTER TABLE", older, value = TRUE)
  ok(length(alt) == 1L && grepl("ADD COLUMNS (LOT_RUN_VERSION string)", alt, fixed = TRUE),
     "...while one written by an earlier version gains the column in place")
  ok(which(grepl("^ALTER TABLE", older)) < which(grepl("^INSERT INTO", older)),
     "...before the insert that needs it")
  ok(identical(names(RUN_METADATA_COLS)[1:3], c("RUN_ID", "STATE", "UPDATED_AT")),
     "the columns every reader binds a run by come first, unchanged")

  # A publication gate needs one question answered from the run's own record:
  # did the release leave a withheld cell that the rest of its group gives
  # away? Whether to regroup is the analyst's call and this package does not
  # make it - but a log line cannot be gated on, so the finding is a column.
  ok("RELEASE_RECOVERABLE" %in% names(RUN_METADATA_COLS),
     "the run records whether its release left a recoverable cell")
  local({
    release_recoverable_reset()
    ok(!length(release_recoverable()),
       "...which starts empty, so a second build under one run id does not inherit the first's finding")
    ok(!length(release_recoverable_tables()),
       "...both of it, the sentence and the list of tables it is about")
    release_recoverable_note(
      "S_SAFETY_RATES", "S_SAFETY_RATES_RELEASE: 3 COHORT/LOT_NUM group(s)")
    ok(length(release_recoverable()) == 1L &&
         grepl("S_SAFETY_RATES_RELEASE", release_recoverable()[[1]], fixed = TRUE),
       "...and names the table and the grouping, not just a count")
    # The sentence is for a person; the list is what a gate refuses on. A gate
    # that has to find table names inside a sentence is guessing, and the guess
    # fails open in one direction and shut in the other: a reworded warning
    # names no table, and a blanket refusal then follows from a change of
    # wording rather than from a change of risk.
    ok(identical(release_recoverable_tables(), "S_SAFETY_RATES"),
       "...and says which table in a field of its own, so a gate does not have to read the sentence")
    release_recoverable_note(
      "S_SAFETY_RATES", "S_SAFETY_RATES_RELEASE: 1 group with one suppressed AGE_GROUP")
    ok(length(release_recoverable()) == 2L &&
         identical(release_recoverable_tables(), "S_SAFETY_RATES"),
       "...and one table found twice is two findings and one table, not two")
    release_recoverable_note("S_SWITCH", "S_SWITCH_RELEASE: 2 COHORT group(s)")
    ok(setequal(release_recoverable_tables(), c("S_SAFETY_RATES", "S_SWITCH")),
       "...while a second table is a second name")
    release_recoverable_reset()
    ok(!length(release_recoverable()) && !length(release_recoverable_tables()),
       "...and the reset clears both, so a second build under one run id inherits neither")
  })
  # "none" and "not run" are different answers and a gate must tell them
  # apart: a run without the release module has not been shown to have no
  # recoverable cell, it has not looked.
  meta_of <- function(mods) with_env(base_env, {
    env <- new.env(parent = environment(write_run_metadata))
    sql <- character(0)
    env$db_exec <- function(con, s) { sql <<- c(sql, s); invisible(NULL) }
    env$db_q <- function(con, s) data.frame(
      col_name = names(RUN_METADATA_COLS),
      data_type = unname(RUN_METADATA_COLS), stringsAsFactors = FALSE)
    env$codelist_metadata <- function() data.frame()
    f <- stubbed(write_run_metadata, env)
    f(NULL, cfg0(), list(`1L` = COHORTS$`1L`), mods, list(RUN_ID = "L"),
      character(0), "complete", run_id = "R")
    paste(sql, collapse = "\n")
  })
  ok(grepl("release module did not run", meta_of(MODULES["periods"]), fixed = TRUE),
     "...so a run with no release module says it did not look")
  ok(grepl("'none'", meta_of(MODULES[c("periods", "release")]), fixed = TRUE),
     "...and one that ran it and found nothing says none")
  ok("RELEASE_RECOVERABLE_TABLES" %in% names(RUN_METADATA_COLS) &&
       grepl("RELEASE_RECOVERABLE_TABLES", meta_of(MODULES[c("periods", "release")]),
             fixed = TRUE),
     "...and the tables that finding is about are a column of their own, written on every run")
  # A column that exists with a type this writer cannot insert into is found
  # before the DELETE, not by the insert failing after the row is gone.
  e_typ <- errs(with_env(base_env, {
    env <- new.env(parent = environment(ensure_columns))
    env$db_exec <- function(con, sql) stop("nothing may be executed")
    env$db_q <- function(con, sql) data.frame(
      col_name = names(RUN_METADATA_COLS),
      data_type = ifelse(names(RUN_METADATA_COLS) == "STATE", "int",
                         unname(RUN_METADATA_COLS)), stringsAsFactors = FALSE)
    f <- stubbed(ensure_columns, env)
    f(NULL, "wk.t", RUN_METADATA_COLS)
  }))
  ok(!is.na(e_typ) && grepl("STATE is INT where this package writes STRING", e_typ),
     "...and a column of the wrong type stops the write before any row is cleared")
  # Names alone cannot say whether the columns can take the insert, so a
  # DESCRIBE without a type column stops here as it does in ensure_table().
  e_untyped <- errs(with_env(base_env, {
    env <- new.env(parent = environment(ensure_columns))
    env$db_exec <- function(con, sql) stop("nothing may be executed")
    env$db_q <- function(con, sql) data.frame(col_name = names(RUN_METADATA_COLS),
                                              stringsAsFactors = FALSE)
    f <- stubbed(ensure_columns, env)
    f(NULL, "wk.t", RUN_METADATA_COLS)
  }))
  ok(!is.na(e_untyped) && grepl("without a type column", e_untyped),
     "...as does a DESCRIBE that carries no type column: names alone are not a licence to write")
}

cat("\n-- a predicate with an OR in it --\n")
# Membership parenthesised each predicate and the funnel joined them bare, so
# `MET_N2 = 1 OR MET_I5 = 1` bound the funnel's cohort filter to its left arm
# only and the last step counted other cohorts' rows: membership 2, funnel 8.
# One composer now, for both.
{
  msrc <- paste(readLines("R/modules/01_cohorts.R", warn = FALSE), collapse = "\n")
  ok(grepl('paste0(" AND ", and_predicates(cum))', msrc, fixed = TRUE) &&
       grepl("cum <- c(cum, preds)", msrc, fixed = TRUE) &&
       grepl("and_predicates(unlist(lapply(cohort$criteria, criterion_predicates)))", msrc, fixed = TRUE),
     "membership and the funnel compose their predicates through one helper")
  ok(identical(and_predicates(c("MET_N2 = 1 OR MET_I5 = 1", "MET_X1 = 1")),
               "(MET_N2 = 1 OR MET_I5 = 1) AND (MET_X1 = 1)"),
     "...which parenthesises each one, so an OR cannot reach the cohort filter")
  orrun <- with_env(base_env, capture_emitted_sql(".", env_edit = function(env) {
    env$CRITERION_SOURCE[["I4_custom_or"]] <- "here"
    env$HERE_PRED[["I4_custom_or"]] <- "MET_N2 = 1 OR MET_I5 = 1"
    env$COHORTS[["1L"]]$criteria <-
      sub("^I4_ce_pre$", "I4_custom_or", env$COHORTS[["1L"]]$criteria)
    env
  }))
  ok(length(orrun$errors) == 0, "a cohort listing an OR criterion still builds")
  oa <- step_sql(orrun, "step:attrition_1L")
  om <- in_cohort_pred(step_sql(orrun, "step:cohort_1L"))
  ok(grepl("AND (MET_N2 = 1 OR MET_I5 = 1)", last_arm_where(oa), fixed = TRUE) &&
       grepl("(MET_N2 = 1 OR MET_I5 = 1)", om, fixed = TRUE),
     "the OR reaches both, parenthesised in both")
  # Executed: on the four-cohort fixture, every cohort's membership is its
  # funnel's last step and no step counts more than the one above it. The
  # shipped goldens do not describe this registry, so the run carries its
  # own.
  gold <- tempfile(fileext = ".py")
  eq <- function(ck) sprintf(
    '    ("%s: membership equals the funnel\'s last step", "SELECT f.N_REMAINING - (SELECT count(*) FROM wk.S_COHORT WHERE COHORT=\'%s\' AND IN_COHORT=1) FROM wk.S_ATTRITION f WHERE f.COHORT=\'%s\' AND f.STEP=(SELECT max(STEP) FROM wk.S_ATTRITION WHERE COHORT=\'%s\')", [(0,)]),',
    ck, ck, ck, ck)
  writeLines(c(
    "EXPECTATIONS = [",
    vapply(names(COHORTS), eq, character(1)),
    '    ("no funnel step counts more than the one above it", "SELECT count(*) FROM (SELECT N_REMAINING - lag(N_REMAINING) OVER (PARTITION BY COHORT ORDER BY STEP) AS d FROM wk.S_ATTRITION) t WHERE d > 0", [(0,)]),',
    '    ("the OR admits the 1L patients continuous enrolment admitted, and more or the same", "SELECT count(*) >= (SELECT count(*) FROM wk.S_COHORT WHERE COHORT=\'1L\' AND MET_N2 = 1) FROM wk.S_COHORT WHERE COHORT=\'1L\' AND IN_COHORT=1", [(True,)]),',
    "]"), gold)
  sfo <- tempfile(fileext = ".sql")
  cono <- file(sfo, "w")
  for (x in orrun$sql) {
    cat("-- @@STMT ", x$tag, "\n", sep = "", file = cono)
    cat(x$sql, "\n", file = cono)
  }
  close(cono)
  sdo <- file.path(tempdir(), "staged_or")
  unlink(sdo, recursive = TRUE); dir.create(sdo, showWarnings = FALSE)
  for (n in names(orrun$staged))
    utils::write.csv(orrun$staged[[n]], file.path(sdo, paste0(n, ".csv")),
                     row.names = FALSE)
  ooutx <- suppressWarnings(tryCatch(
    system2("python3", c("tests/run_duckdb.py", shQuote(sfo), shQuote(sdo),
                         "tests/fixtures/cdm", shQuote(cfg0()$object_prefix),
                         shQuote(gold)),
            stdout = TRUE, stderr = TRUE),
    error = function(e) "NO-PYTHON"))
  otxt <- paste(ooutx, collapse = "\n")
  if (any(grepl("^SKIP:", ooutx)) || identical(otxt, "NO-PYTHON") || !length(ooutx)) {
    skip_note("executed, an OR criterion keeps membership equal to the funnel (python3 + duckdb + sqlglot not available)")
  } else {
    ok(grepl("0 failed", otxt) && grepl("0 wrong", otxt),
       paste0("executed, an OR criterion keeps every cohort's membership equal to its funnel's last step, and the funnel never rises",
              if (!grepl("0 failed", otxt) || !grepl("0 wrong", otxt))
                paste0("\n", otxt) else ""))
  }
  unlink(c(sfo, sdo, gold), recursive = TRUE)
}

cat("\n-- the controller re-checks the LOT build before recording complete --\n")
# check_lot_lineage() accepts a build before any table is read, and a LOT
# rebuild landing while the modules read those tables would replace them under
# the same prefix. The real controller is driven here, with every warehouse
# call answered by a fake and every module stubbed out.
{
  drive <- function(later = list()) {
    said <- character(0); asks <- 0L
    rowA <- list(RUN_ID = "lot1", STATE = "complete",
                 UPDATED_AT = "2026-09-22 05:00:00",
                 INPUT_COHORT_TABLE = base_env[["INPUT_COHORT_TABLE"]],
                 STUDY_END = cfg0()$study_end, CONTRACT_DEVIATIONS = "")
    env <- new.env(parent = environment(build_223926))
    env$db_q <- function(con, sql) {
      if (grepl("LOT_BUILD_STATUS", sql, fixed = TRUE)) {
        asks <<- asks + 1L
        r <- if (asks == 1L) rowA else utils::modifyList(rowA, later)
        return(as.data.frame(r, stringsAsFactors = FALSE))
      }
      if (grepl("^\\s*DESCRIBE", sql))
        return(data.frame(col_name = names(RUN_METADATA_COLS),
                          data_type = unname(RUN_METADATA_COLS),
                          stringsAsFactors = FALSE))
      stop("no such table")
    }
    env$db_exec <- function(con, sql) { said <<- c(said, sql); invisible(0L) }
    env$log_msg <- function(...) invisible(NULL)
    env$connect_db <- function(cfg) structure(list(), class = "fake")
    env$disconnect_db <- function(con) invisible(NULL)
    env$current_work_schema <- function(con) "wk"
    env$preflight_codelists <- function(mods, cfg) mods
    env$source_modules <- function(here) invisible(TRUE)
    env$build_inputs <- function(con, cfg, mods) invisible(TRUE)
    # A run that READS the LOT tables, which is what these checks are about.
    # An empty module set is a run that reads none, and the controller now
    # skips the lineage proof for exactly that case - so an empty stub here
    # would test the skip rather than the proof. Named `spine`, because that is
    # the module whose presence answers the question, but with a body that does
    # nothing: these checks are about the controller around the modules.
    env$noop_mod <- function(con, cfg, cohorts) invisible(NULL)
    env$resolve_modules <- function(cfg)
      list(spine = utils::modifyList(MODULES$spine, list(fn = "noop_mod")))
    env$describe_plan <- function(cfg, cohorts, mods) character(0)
    # The lineage helpers too: check_lot_lineage() calls them, and a copy
    # left in the global environment reads through the real db_q. That used
    # to pass, because lot_run_inputs() turned the real driver's error into
    # NULL - the fail-open the fixture was hiding.
    for (nm in c("check_lot_lineage", "check_lot_lineage_unchanged",
                 "lot_run_inputs", "check_cohort_attempt", "cohort_build_now",
                 "check_lot_code",
                 "read_upstream_settings", "write_run_metadata", "ensure_columns",
                 "describe_columns")) {
      g <- get(nm); environment(g) <- env; env[[nm]] <- g
    }
    f <- build_223926; environment(f) <- env
    err <- NA_character_
    utils::capture.output(err <- errs(with_env(base_env, f("."))))
    list(err = err, sql = said, asks = asks)
  }
  state_of <- function(sql) {
    ins <- grep("^INSERT INTO", sql, value = TRUE)
    regmatches(ins, regexpr("'(started|complete|failed)'", ins))
  }
  steady <- drive()
  ok(is.na(steady$err) && identical(state_of(steady$sql), c("'started'", "'complete'")),
     paste0("a build whose LOT prefix stays put is recorded started, then complete",
            if (!is.na(steady$err)) paste0(" [", steady$err, "]") else ""))
  ok(steady$asks == 2L,
     "...with the LOT status read twice: once to accept the build, once before completing")
  ok(any(grepl("'20260922T050000Z'", steady$sql, fixed = TRUE)),
     "...and the accepted build's version on the metadata row")
  raced <- drive(list(UPDATED_AT = "2026-09-22 05:01:00"))
  ok(!is.na(raced$err) && grepl("LINEAGE ERROR", raced$err) && grepl("rebuilt while", raced$err),
     "a LOT rebuild completing under the same id while the modules ran stops the run")
  ok(identical(state_of(raced$sql), c("'started'", "'failed'")),
     "...which is recorded failed under its own id, never complete")
  ok(grepl("build 20260922T050000Z", raced$err) && grepl("build 20260922T050100Z", raced$err),
     "...naming the build it accepted and the one it found")
  going <- drive(list(STATE = "started", UPDATED_AT = "2026-09-22 05:01:00"))
  ok(!is.na(going$err) && identical(state_of(going$sql), c("'started'", "'failed'")),
     "and so does a rebuild still in progress")
  other <- drive(list(RUN_ID = "lot2", UPDATED_AT = "2026-09-22 05:01:00"))
  ok(!is.na(other$err) && grepl("now holds run lot2", other$err),
     "and another run altogether")
  rsrc <- paste(readLines("R/run_223926.R", warn = FALSE), collapse = "\n")
  ok(regexpr("check_lot_lineage_unchanged(con, lot_run)", rsrc, fixed = TRUE) <
       regexpr('deviations, "complete"', rsrc, fixed = TRUE) &&
       regexpr("for (m in mods) {", rsrc, fixed = TRUE) <
       regexpr("check_lot_lineage_unchanged(con, lot_run)", rsrc, fixed = TRUE),
     "the re-check sits after the last module and before the complete row")
}

cat("\n-- the arithmetic, executed on its own --\n")
# The whole-script harness runs over a seven-patient fixture, so every stratum
# in it is under the 25-patient floor and every rate is suppressed to NULL
# before a golden number could read one. That leaves the rate arithmetic
# itself - the multiplier, the interval bounds, the months divisor, the
# time-to-event boundary - unheld.
#
# So the fragments are executed here against rows built for the rule each one
# states. tests/exec_fragments.R carries the rows and the answers.
source(file.path(here, "tests", "exec_fragments.R"))

cat("\na staged code list survives the trip through the parser\n")
{
  rt <- data.frame(code = c("C900", "D649", "E11", "F1", "G2"),
                   condition = c("Alzheimer's disease", "a\\b", "x\\", "back\\nslash", "plain (1/2)"),
                   stringsAsFactors = FALSE)
  qs <- list(stage = codelist_stage_sql("cl_rt_raw", rt),
             read = "SELECT code, condition FROM cl_rt_raw ORDER BY code")
  res <- run_fragments(qs, list(), schema = list(), root = here)
  if (is.null(res) || identical(res, "skip")) {
    skip_note("a staged code list reads back as it went in (python3 + duckdb + sqlglot not available)")
  } else {
    got <- res[res$id == "read" & res$col == "condition", , drop = FALSE]
    got <- got$value[order(as.integer(got$row))]
    ok(!length(frag_errors(res)) && identical(got, rt$condition),
       paste0("every value reads back as it went in - an apostrophe, a backslash, a trailing backslash, a backslash before an n",
              if (!identical(got, rt$condition)) paste0(" [read back: ", paste(got, collapse = " | "), "]") else ""))
  }
}
local({
  cfg <- cfg0()
  cs  <- frag_cases(cfg)
  qs  <- lapply(cs, function(x)
    sprintf("SELECT ID, %s AS V FROM d ORDER BY ID", x$sql))
  res <- run_fragments(qs, list(d = FRAG_ROWS), root = here)
  if (is.null(res) || identical(res, "skip")) {
    skip_note("the emitted arithmetic executes (python3 + duckdb + sqlglot not available)")
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

  # The washout chain, run to convergence the way the module runs it. Days 0,
  # 20 and 40 are TWO counted events by a lag() and THREE by the chain, because
  # day 40 is measured against day 0 - the last event that COUNTED - and not
  # against day 20, which did not.
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

check_skip_wiring()
cat("\n", .pass, " passed, ", length(.fail), " failed, ", length(.skipped), " skipped\n", sep = "")
if (length(.fail))
  cat("failed:\n", paste0("  ", .fail, collapse = "\n"), "\n", sep = "")
if (length(.skipped)) {
  cat("skipped:\n", paste0("  ", .skipped, collapse = "\n"), "\n", sep = "")
  # The reasons are printed above; the remedy is whatever each one says. This
  # used to add "Install python3 with sqlglot" whatever had skipped, which is
  # the wrong remedy for the block that skips because the LOT engine is not
  # beside this package - and sends the reader to install something that is
  # already there.
  cat(length(.skipped), " block(s) did not run, so this is NOT a clean run. ",
      "Fix those, or set ALLOW_SKIPPED_TESTS=TRUE to accept it.\n", sep = "")
}
if (length(.fail) ||
      (length(.skipped) &&
         !identical(toupper(trimws(Sys.getenv("ALLOW_SKIPPED_TESTS"))), "TRUE")))
  quit(status = 1)
