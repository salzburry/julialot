#!/usr/bin/env Rscript
# Checks on the per-line criteria layer. The shipped registry is empty, so the
# fixtures below are what exercise the builders.
#
#   Rscript "lot/tests/test_line_criteria.R"

ROOT <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                                 fixed = TRUE))) else getwd()
  dirname(d)
})
source(file.path(ROOT, "tests", "testutil.R"))
if (requireNamespace("glue", quietly = TRUE)) library(glue)
source(file.path(ROOT, "R", "line_criteria.R"))

cfg <- list(min_lot_length_days = 14L)
crit <- function(...) modifyList(
  list(name = "c1", label = "L", lines = "*", flag = "F1",
       sql = "LOT_MED_CNT > 0", on_fail = "flag"), list(...))

C_ANY   <- crit()
C_L2    <- crit(name = "c2", flag = "F2", lines = 2L)
C_L23   <- crit(name = "c3", flag = "F3", lines = c(2L, 3L), on_fail = "truncate")
C_PARAM <- crit(name = "c4", flag = "F4",
                sql = "LOT_BASE_LENGTH >= {cfg$min_lot_length_days}",
                on_fail = "truncate")

clear <- function() for (v in paste0("APPLY_", toupper(c("c1","c2","c3","c4"))))
  Sys.unsetenv(v)

cat("\n-- the shipped registry --\n")
runs(validate_line_criteria(), "the shipped registry validates")
# One criterion ships: S6.2.1.2's belantamab exclusion, applied here because
# lines do not exist when the NDMM cohort is built. See nndm/DECISIONS.md #2.
ok(length(LINE_CRITERIA) == 1 &&
     identical(LINE_CRITERIA[[1]]$name, "no_belantamab"),
   "the belantamab exclusion is the one criterion shipped")
ok(identical(LINE_CRITERIA[[1]]$on_fail, "truncate") &&
     identical(LINE_CRITERIA[[1]]$lines, "*"),
   "...asked of every line, and it removes rather than flags")
# The predicate is patient-level: false on every line of an affected patient, so
# first_failed_lot lands on their earliest and truncate leaves them with none.
# A line-level predicate would strand their earlier lines in the cohort.
ok(grepl("OVER (PARTITION BY PATID)", LINE_CRITERIA[[1]]$sql, fixed = TRUE),
   "...and it is patient-level, so the patient goes, not just the line")
# Whole-token, not LIKE: an abbreviation merely containing BELA must not match.
ok(grepl("array_contains(split(", LINE_CRITERIA[[1]]$sql, fixed = TRUE) &&
     !grepl("LIKE", LINE_CRITERIA[[1]]$sql, fixed = TRUE),
   "...matching whole MED_ABBR tokens, not substrings")

cat("\n-- a criterion has to be well formed --\n")
runs(validate_line_criteria(list(C_ANY, C_L23)), "well-formed criteria pass")
# Each of these must fail for its OWN reason, so assert the message too - a
# test that accepts any error passes on an unrelated crash.
badmsg <- function(expr, want, what) {
  e <- tryCatch(expr, error = function(e) e)
  ok(inherits(e, "error") && grepl(want, conditionMessage(e), fixed = TRUE), what)
}
badmsg(validate_line_criteria(list(crit(on_fail = "drop_line"))),
       "on_fail must be one of", "drop_line is no longer a mode")
badmsg(validate_line_criteria(list(crit(on_fail = "delete"))),
       "on_fail must be one of", "an unknown on_fail")
badmsg(validate_line_criteria(list(crit(lines = 0L))),
       "lines must be", "LOT_NUM 0 is not a line")
badmsg(validate_line_criteria(list(crit(lines = 1.5))),
       "lines must be", "1.5 is rejected, not truncated to LOT1")
badmsg(validate_line_criteria(list(crit(lines = NA_integer_))),
       "lines must be", "NA lines gives a message, not a raw R error")
badmsg(validate_line_criteria(list(crit(lines = Inf))),
       "lines must be", "Inf lines is rejected")
badmsg(validate_line_criteria(list(crit(flag = "not a column"))),
       "flag is not a column name", "a flag that is not a column name")
badmsg(validate_line_criteria(list(crit(sql = "   "))),
       "sql must be", "an empty predicate")
badmsg(validate_line_criteria(list(crit(name = c("a", "b")))),
       "name must be one", "a name that is not one string")
badmsg(validate_line_criteria(list(crit(label = NA_character_))),
       "label must be one", "an NA label")
badmsg(validate_line_criteria(list(list(name = "c", label = "l"))),
       "missing", "missing fields are named, and nothing crashes after")
badmsg(validate_line_criteria(list(C_ANY, crit(name = "C1", flag = "FX"))),
       "duplicate name", "names differing only in case are duplicates")
badmsg(validate_line_criteria(list(C_ANY, crit(name = "cX", flag = "f1"))),
       "duplicate flag", "flags differing only in case are duplicates")

cat("\n-- on_fail may be left out; it means flag --\n")
no_mode <- list(name = "c9", label = "L", lines = "*", flag = "F9",
                sql = "LOT_MED_CNT > 0")
runs(validate_line_criteria(list(no_mode)), "a criterion without on_fail is valid")
ok(identical(normalize_criterion(no_mode)$on_fail, "flag"), "and defaults to flag")

cat("\n-- lines the criterion is not asked of must pass --\n")
# If a non-targeted line scored 0 it would fail every criterion aimed at
# another line, which would quietly empty the table.
s <- line_flag_sql(C_L2, cfg)
ok(has(s, "WHEN NOT (LOT_NUM IN (2)) THEN 1"), "a line outside the criterion passes")
ok(has(s, "AS F2"), "the flag is named")
ok(has(line_flag_sql(C_ANY, cfg), "WHEN NOT (1=1)"), "\"*\" asks it of every line")
ok(has(line_flag_sql(C_L23, cfg), "LOT_NUM IN (2, 3)"), "several lines at once")

cat("\n-- a threshold can come from config --\n")
ok(has(line_flag_sql(C_PARAM, cfg), "LOT_BASE_LENGTH >= 14"),
   "{cfg$...} is interpolated into the predicate")

cat("\n-- an unknown predicate fails, it does not pass --\n")
ok(has(s, "ELSE 0 END"), "NULL is not evidence the line qualifies")

cat("\n-- flags are computed whether or not they are enabled --\n")
clear()
f <- line_criteria_flags_sql(cfg, "lot_long", "LOT_LONG_ALLFLAGS", list(C_ANY, C_L2))
ok(has(f, "AS F1") && has(f, "AS F2"), "every criterion gets a column while disabled")
ok(has(f, "FROM lot_long"), "built from lot_long")
e <- line_criteria_flags_sql(cfg, "lot_long", "X", list())
ok(has(e, "SELECT * FROM lot_long"), "no criteria means a straight copy, not a broken view")

cat("\n-- a mistyped switch stops the build, it does not disable quietly --\n")
# The old behaviour treated APPLY_C1=Y as FALSE, so an intended criterion
# could go missing with no error at all.
clear(); Sys.setenv(APPLY_C1 = "Y")
stops(enabled_line_criteria(list(C_ANY)), "'Y' is rejected, not read as off")
Sys.setenv(APPLY_C1 = "TURE")
stops(enabled_line_criteria(list(C_ANY)), "a typo is rejected")
Sys.setenv(APPLY_C1 = "1")
stops(enabled_line_criteria(list(C_ANY)), "'1' is rejected")
clear()
ok(length(enabled_line_criteria(list(C_ANY, C_L2))) == 0, "unset means off")
Sys.setenv(APPLY_C1 = "true")
ok(length(enabled_line_criteria(list(C_ANY, C_L2))) == 1, "lowercase true enables")
Sys.setenv(APPLY_C1 = " FALSE ")
ok(length(enabled_line_criteria(list(C_ANY))) == 0, "whitespace is tolerated")
clear()

cat("\n-- a flag-only criterion is a real no-op --\n")
# Not just row-neutral: no window scan and no extra columns either.
clear(); Sys.setenv(APPLY_C1 = "TRUE")
fin <- line_criteria_final_sql(cfg, "A", "B", list(C_ANY))
ok(has(fin, "SELECT * FROM A"), "flag-only leaves the rows alone")
ok(!has(fin, "OVER (PARTITION BY") && !has(fin, "first_failed_lot"),
   "and adds no window scan or scratch column")
clear()
fin <- line_criteria_final_sql(cfg, "A", "B", list(C_ANY, C_L23, C_PARAM))
ok(has(fin, "SELECT * FROM A"), "nothing enabled is also a straight copy")

cat("\n-- truncate drops the failing line and everything after --\n")
clear(); Sys.setenv(APPLY_C3 = "TRUE")
fin <- line_criteria_final_sql(cfg, "A", "B", list(C_ANY, C_L23))
ok(has(fin, "min(CASE WHEN F3 = 0 THEN LOT_NUM END) OVER (PARTITION BY PATID)"),
   "it finds the patient's first failing line")
ok(has(fin, "LOT_NUM < first_failed_lot"),
   "and drops it and every later line, since LOT N leans on LOT N-1")
ok(!has(fin, "F1 = 0"), "a disabled criterion does not filter")
ok(has(fin, "EXCEPT (first_failed_lot)"), "the scratch column stays out of the result")
clear()

cat("\n-- the belantamab abbreviation has to match the code list --\n")
# The criterion tests LOT_BASE_MEDS for one MED_ABBR token. If the code list
# does not use that token it matches nothing and excludes nobody - and "no
# patient had belantamab" looks exactly like "the abbreviation is wrong". This
# is the check that tells them apart, so it is driven, not read.
be <- new.env(parent = globalenv())
assign("enabled_line_criteria", function(...) LINE_CRITERIA, envir = be)
assign("log_msg", function(...) invisible(NULL), envir = be)
assign("glue", glue::glue, envir = be)
bl <- readLines(file.path(ROOT, "R", "build_lot.R"), warn = FALSE)
i <- grep("^check_belantamab_abbr <- function", bl)
j <- i + which(bl[i:length(bl)] == "}")[1] - 1L
eval(parse(text = paste(bl[i:j], collapse = "\n")), envir = be)

drive_bl <- function(n) {
  assign("db_q", function(con, sql) data.frame(n = n), envir = be)
  tryCatch({ be$check_belantamab_abbr(NULL, list(belantamab_med_abbr = "BELA")); "" },
           error = conditionMessage)
}
ok(identical(drive_bl(3L), ""), "an abbreviation the code list carries passes")
m <- drive_bl(0L)
ok(grepl("no row of cl_mma_codelist.csv", m, fixed = TRUE) &&
     grepl("BELA", m, fixed = TRUE),
   "one it does not stops the run, naming the abbreviation")
ok(grepl("exclude nobody", m, fixed = TRUE),
   "...and says what would have happened, which is the whole point")
# A query that errors is not evidence the abbreviation is fine.
assign("db_q", function(con, sql) stop("no such table"), envir = be)
ok(grepl("no row of cl_mma_codelist.csv",
         tryCatch({ be$check_belantamab_abbr(NULL, list(belantamab_med_abbr = "BELA")); "" },
                  error = conditionMessage), fixed = TRUE),
   "and a failed count is treated as no match, not as a pass")
# Switched off, it must not ask - the code list need not carry belantamab then.
assign("enabled_line_criteria", function(...) list(), envir = be)
assign("db_q", function(con, sql) stop("should not be called"), envir = be)
ok(is.null(be$check_belantamab_abbr(NULL, list(belantamab_med_abbr = "BELA"))),
   "with the criterion off the check does not run at all")

report()
