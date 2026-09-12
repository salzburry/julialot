#!/usr/bin/env Rscript
# Checks on the per-line criteria layer. The shipped registry is empty, so the
# fixtures below are what exercise the builders.
#
#   Rscript "lot/engine/tests/test_line_criteria.R"

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
# One criterion ships: the belantamab exclusion. It is applied here because
# lines do not yet exist when the cohort build runs.
ok(length(LINE_CRITERIA) == 1 &&
     identical(LINE_CRITERIA[[1]]$name, "no_belantamab"),
   "the belantamab exclusion is the one criterion shipped")
ok(identical(LINE_CRITERIA[[1]]$on_fail, "truncate") &&
     identical(LINE_CRITERIA[[1]]$lines, "*"),
   "...asked of every line, and it removes rather than flags")
# The predicate is patient-level: false on every line of an affected patient, so
# first_failed_lot lands on their earliest and truncate leaves them with none.
# A line-level predicate would strand their earlier lines in the cohort. It is
# patient-level by construction now - the view it reads is one row per PATID.
ok(grepl("GROUP BY s.PATID", LINE_CRITERIA[[1]]$patients, fixed = TRUE) &&
     grepl("p_no_belantamab.", LINE_CRITERIA[[1]]$sql, fixed = TRUE),
   "...and it is patient-level, so the patient goes, not just the line")
# "any LOT" must not collapse to "any LOT the build got round to constructing".
# Reading LOT_BASE_MEDS or LOT_BASE_1ST_ADD_MED bounds it by MAX_LOT and by the
# drug's position in the line; asking the claims does not.
ok(!grepl("LOT_BASE_MEDS", LINE_CRITERIA[[1]]$sql, fixed = TRUE) &&
     !grepl("LOT_BASE_1ST_ADD_MED", LINE_CRITERIA[[1]]$sql, fixed = TRUE) &&
     grepl("map_stacked", LINE_CRITERIA[[1]]$patients, fixed = TRUE),
   "...asked of the claims, so it is not bounded by MAX_LOT or by med position")
# Bounded by the patient's own LOT span, not by the cohort index: a cohort whose
# index precedes its first line would otherwise count pre-LOT therapy.
ok(grepl("min(LOT_START_DT) AS FIRST_LOT_DT", LINE_CRITERIA[[1]]$patients, fixed = TRUE) &&
     grepl("m.MAP_START_DT <= p.OBS_END_DT", LINE_CRITERIA[[1]]$patients, fixed = TRUE),
   "...over the span from the first line to the end of observation")
# Whole value, not LIKE: an abbreviation merely containing BELA must not match.
ok(grepl("= '{cfg$belantamab_med_abbr}'", LINE_CRITERIA[[1]]$patients, fixed = TRUE) &&
     !grepl("LIKE", LINE_CRITERIA[[1]]$patients, fixed = TRUE),
   "...matching a whole MED_ABBR, not a substring")

cat("\n-- patient-level facts a criterion asks of something other than lot_long --\n")
# lot_long carries lines, not claims. A criterion needing a per-patient fact
# declares `patients`; the view it builds is LEFT JOINed into allflags so the
# predicate can read it.
C_PAT <- crit(name = "cp", flag = "FP",
              patients = paste0("CREATE OR REPLACE TEMPORARY VIEW lc_cp_patients",
                                " AS SELECT PATID, 1 AS HAS FROM src"),
              sql = "coalesce(p_cp.HAS, 0) = 0")
runs(validate_line_criteria(list(C_PAT)), "a criterion may declare one")
pv <- line_criteria_patient_sql(cfg, list(C_PAT))
ok(length(pv) == 1 && identical(pv[[1]]$name, "lc_cp_patients"),
   "its view is handed back for the phase to build first")
fs <- line_criteria_flags_sql(cfg, "lot_long", "out", list(C_PAT))
ok(grepl("LEFT JOIN lc_cp_patients p_cp ON s.PATID = p_cp.PATID", fs, fixed = TRUE),
   "...and joined on PATID, under the alias the predicate reads")
# s.*, or the joined view's columns land in the output and PATID appears twice.
ok(grepl("SELECT s.*", fs, fixed = TRUE) && grepl("FROM lot_long s", fs, fixed = TRUE),
   "the join projects the source's columns only")
ok(!grepl("LEFT JOIN", line_criteria_flags_sql(cfg, "lot_long", "out", list(C_ANY)),
          fixed = TRUE),
   "a criterion that declares none is unchanged - no join, no alias")
# Both names are built from the criterion's, so a rename that touches one and
# not the other builds a view nothing joins, or reads an alias nothing defines.
# The predicate is then NULL, the flag 0, and truncate removes every patient.
badmsg2 <- function(expr, want, what) {
  e <- tryCatch(expr, error = function(e) e)
  ok(inherits(e, "error") && grepl(want, conditionMessage(e), fixed = TRUE), what)
}
badmsg2(validate_line_criteria(list(modifyList(C_PAT, list(name = "cq")))),
        "patients must create the view lc_cq_patients",
        "a renamed criterion whose view name did not follow is refused")
badmsg2(validate_line_criteria(list(modifyList(C_PAT, list(sql = "1 = 1")))),
        "never reads p_cp",
        "...and so is a predicate that never reads the view it asked for")

cat("\n-- a criterion has to be well formed --\n")
runs(validate_line_criteria(list(C_ANY, C_L23)), "well-formed criteria pass")
# Each of these must fail for its own reason, so assert the message too - a
# test that accepts any error passes on an unrelated crash.
badmsg <- function(expr, want, what) {
  e <- tryCatch(expr, error = function(e) e)
  ok(inherits(e, "error") && grepl(want, conditionMessage(e), fixed = TRUE), what)
}
badmsg(validate_line_criteria(list(crit(on_fail = "drop_line"))),
       "on_fail must be one of", "drop_line is not a mode")
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
# Reading APPLY_C1=Y as FALSE would let an intended criterion go missing with
# no error at all.
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
# does not use that token it matches nothing and excludes nobody, which looks
# exactly like a cohort in which no patient had belantamab.
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
ok(grepl("no such table",
         tryCatch({ be$check_belantamab_abbr(NULL, list(belantamab_med_abbr = "BELA")); "" },
                  error = conditionMessage), fixed = TRUE),
   "and a failed count stops with its own message, not as a pass")
# Switched off, it must not ask - the code list need not carry belantamab then.
assign("enabled_line_criteria", function(...) list(), envir = be)
assign("db_q", function(con, sql) stop("should not be called"), envir = be)
ok(is.null(be$check_belantamab_abbr(NULL, list(belantamab_med_abbr = "BELA"))),
   "with the criterion off the check does not run at all")

report()
