#!/usr/bin/env Rscript
# Checks on the per-line criteria layer. The shipped registry is empty, so the
# fixtures below are what exercise the builders.
#
#   Rscript "Jul 28/lot/tests/test_line_criteria.R"

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
C_L2    <- crit(name = "c2", flag = "F2", lines = 2L, on_fail = "drop_line")
C_L23   <- crit(name = "c3", flag = "F3", lines = c(2L, 3L), on_fail = "truncate")
C_PARAM <- crit(name = "c4", flag = "F4",
                sql = "LOT_BASE_LENGTH >= {cfg$min_lot_length_days}",
                on_fail = "drop_patient")

clear <- function() for (v in paste0("APPLY_", toupper(c("c1","c2","c3","c4"))))
  Sys.unsetenv(v)

cat("\n-- the shipped registry --\n")
runs(validate_line_criteria(), "the empty registry validates")
ok(length(LINE_CRITERIA) == 0, "nothing ships enabled, so LOT is unchanged")

cat("\n-- a criterion has to be well formed --\n")
runs(validate_line_criteria(list(C_ANY, C_L2)), "well-formed criteria pass")
stops(validate_line_criteria(list(crit(on_fail = "delete"))), "an unknown on_fail")
stops(validate_line_criteria(list(crit(lines = 0L))), "LOT_NUM 0 is not a line")
stops(validate_line_criteria(list(crit(flag = "not a column"))), "a flag that is not a column name")
stops(validate_line_criteria(list(crit(sql = "   "))), "an empty predicate")
stops(validate_line_criteria(list(C_ANY, crit(name = "cX"))), "two criteria writing one flag")
stops(validate_line_criteria(list(C_ANY, crit(flag = "FX"))), "two criteria with one name")
stops(validate_line_criteria(list(list(name = "c", label = "l"))), "missing fields")

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

cat("\n-- nothing enabled changes nothing --\n")
clear()
fin <- line_criteria_final_sql(cfg, "A", "B", list(C_ANY, C_L2, C_L23, C_PARAM))
ok(has(fin, "SELECT * FROM A") && !has(fin, "WHERE"),
   "all four disabled leaves the rows alone")

cat("\n-- on_fail decides what a failing line does --\n")
clear(); Sys.setenv(APPLY_C2 = "TRUE")
fin <- line_criteria_final_sql(cfg, "A", "B", list(C_ANY, C_L2, C_L23, C_PARAM))
ok(has(fin, "F2 = 0"), "the enabled criterion filters")
ok(!has(fin, "F1 = 0") && !has(fin, "F3 = 0") && !has(fin, "F4 = 0"),
   "the disabled ones do not")
ok(has(fin, "line_fail_drop = 0"), "drop_line removes just that line")

clear(); Sys.setenv(APPLY_C3 = "TRUE")
fin <- line_criteria_final_sql(cfg, "A", "B", list(C_L23))
ok(has(fin, "min(CASE WHEN line_fail_trunc = 1 THEN LOT_NUM END) OVER (PARTITION BY PATID)"),
   "truncate finds the patient's first failing line")
ok(has(fin, "LOT_NUM < first_trunc_lot"),
   "and drops it and every later line, since LOT N leans on LOT N-1")

clear(); Sys.setenv(APPLY_C4 = "TRUE")
fin <- line_criteria_final_sql(cfg, "A", "B", list(C_PARAM))
ok(has(fin, "max(line_fail_patient) OVER (PARTITION BY PATID)") &&
     has(fin, "patient_fails = 0"),
   "drop_patient removes all of the patient's lines")

cat("\n-- several criteria, different on_fail, one pass --\n")
clear(); Sys.setenv(APPLY_C2 = "TRUE", APPLY_C3 = "TRUE", APPLY_C4 = "TRUE")
fin <- line_criteria_final_sql(cfg, "A", "B", list(C_ANY, C_L2, C_L23, C_PARAM))
ok(has(fin, "F2 = 0") && has(fin, "F3 = 0") && has(fin, "F4 = 0"),
   "each enabled criterion is in its own bucket")
ok(has(fin, "line_fail_drop = 0") && has(fin, "first_trunc_lot") &&
     has(fin, "patient_fails = 0"),
   "all three kinds apply together")
clear()

cat("\n-- criteria are off unless config says otherwise --\n")
ok(length(enabled_line_criteria(list(C_ANY, C_L2))) == 0, "unset means off")
Sys.setenv(APPLY_C1 = "true")
ok(length(enabled_line_criteria(list(C_ANY, C_L2))) == 1, "lowercase true still enables")
Sys.setenv(APPLY_C1 = "Y")
ok(length(enabled_line_criteria(list(C_ANY, C_L2))) == 0,
   "'Y' is not TRUE, so it stays off rather than half-on")
clear()

report()
