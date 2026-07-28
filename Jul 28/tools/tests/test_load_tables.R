#!/usr/bin/env Rscript
# =============================================================================
# test_load_tables.R -- exercise the loader's SQL with no warehouse, no packages
# -----------------------------------------------------------------------------
#   Rscript "Jul 28/tools/tests/test_load_tables.R"
#
# load_tables_spec.R is pure: registry + SQL builders, no DB and no libraries.
# Everything it needs (glue, cfg, wrk, cdm_src) is stubbed here, so the column
# list and the per-table date rules are actually executed rather than eyeballed.
#
# This tests GENERATED SQL, which is all that can be tested offline. It does not
# establish that a copy reproduces the source -- only a real load can, by
# comparing counts against the CDM.
# =============================================================================

.here <- local({
  fa <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (!length(fa)) getwd()
  else dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", fa[1]), fixed = TRUE)))
})

# ---- stubs ------------------------------------------------------------------
# Minimal glue: substitute {expr} evaluated in the caller. Non-nested braces
# only, which is all the spec uses.
glue <- function(..., .envir = parent.frame()) {
  s <- paste0(...)
  repeat {
    m <- regexpr("\\{[^{}]*\\}", s)
    if (m == -1L) break
    len  <- attr(m, "match.length")
    expr <- substr(s, m + 1L, m + len - 2L)
    val  <- paste(as.character(eval(parse(text = expr), envir = .envir)), collapse = "")
    s <- paste0(substr(s, 1L, m - 1L), val, substr(s, m + len, nchar(s)))
  }
  s
}
cfg <- list(catalog = "hive_metastore", cdm_schema = "clnprw_optum",
            work_schema = "myschema", study_start = "2015-07-01",
            study_end = "2025-06-30", use_quarterly_tables = TRUE)
wrk     <- function(t) paste0(cfg$catalog, ".", cfg$work_schema, ".", t)
cdm_src <- function(t) paste0(cfg$catalog, ".", cfg$cdm_schema, ".t_", t, "_2025q2")

source(file.path(dirname(.here), "load_tables_spec.R"))

# ---- harness ----------------------------------------------------------------
.n_pass <- 0L; .n_fail <- 0L
ok <- function(c, w) {
  if (isTRUE(c)) { .n_pass <<- .n_pass + 1L; cat("  ok   ", w, "\n") }
  else           { .n_fail <<- .n_fail + 1L; cat("  FAIL ", w, "\n") }
}
throws <- function(e, w) ok(!is.null(tryCatch({ force(e); NULL }, error = function(x) x)), w)
section <- function(s) cat("\n", s, "\n", sep = "")

TBL  <- function(n) Filter(function(t) identical(t$name, n), SOURCE_TABLES)[[1]]
ARGS <- parse_args(character(0))
WIN  <- window_bounds(ARGS)

# =============================================================================
section("the registry covers what the pipeline reads")

ok(length(SOURCE_TABLES) == 8L, "all 8 CDM source tables are registered")
ok(setequal(vapply(SOURCE_TABLES, `[[`, character(1), "name"),
            c("medical", "med_diagnosis", "med_procedure", "rx", "confinement",
              "member_enrollment", "member_cont_enrollment", "dod")),
   "the registered names match every cdm_src() target in the repo")
ok(all(vapply(SOURCE_TABLES, function(t) "PATID" %in% t$cols, logical(1))),
   "every table keeps PATID (it is the join key everywhere)")
ok(all(vapply(SOURCE_TABLES, function(t) nzchar(t$why), logical(1))),
   "every table records why it is needed")

# Columns that would break a specific stage if dropped. Each is derived from a
# real read, so this list is a regression guard, not a restatement.
NEEDED <- list(
  medical       = c("PROC_CD", "BILL_PROC_CD", "NDC",   # MM agent matching
                    "POS", "TOS_CD", "CONF_ID",          # IP/OP classification
                    "PAT_PLANID", "CLMID", "LOC_CD",     # claim-header join key
                    "RVNU_CD"),                          # pregnancy REV codes
  med_diagnosis = c("DIAG", "ICD_FLAG", "PAT_PLANID", "CLMID", "LOC_CD"),
  med_procedure = c("PROC", "ICD_FLAG"),
  rx            = c("NDC", "DAYS_SUP"),                  # DAYS_SUP -> MAP build
  confinement   = c("CONF_ID", "ADMIT_DATE", "DISCH_DATE"),
  member_enrollment      = c("ELIGEFF", "ELIGEND"),
  member_cont_enrollment = c("GDR_CD", "YRDOB", "ELIGEND"),
  dod           = "YMDOD")
for (n in names(NEEDED))
  ok(all(NEEDED[[n]] %in% TBL(n)$cols),
     paste0(n, " keeps every column the pipeline reads (",
            paste(setdiff(NEEDED[[n]], TBL(n)$cols), collapse = ", "), ")"))

# =============================================================================
section("date rules are per-table, not one blanket filter")

# Claims: filtered on their own event date.
for (n in c("medical", "med_diagnosis", "med_procedure", "rx", "confinement"))
  ok(!is.null(TBL(n)$date$col), paste0(n, " is windowed on an event date"))
ok(identical(TBL("rx")$date$col, "FILL_DT"), "rx windows on FILL_DT, not FST_DT")
ok(identical(TBL("confinement")$date$col, "ADMIT_DATE"), "confinement windows on ADMIT_DATE")

# Enrollment: OVERLAP. This is the one that silently breaks every CE criterion
# if it is filtered like a claim -- a 2010-2020 span covers a 2016 baseline.
e <- TBL("member_enrollment")
ok(is.null(e$date$col) && identical(e$date$from, "ELIGEFF") &&
   identical(e$date$to, "ELIGEND"),
   "member_enrollment uses an overlap rule, not a start-date filter")
esql <- copy_sql(e, ARGS, WIN, use_patients = FALSE)
ok(grepl("cast(s.ELIGEND as date) >= date('2015-07-01')", esql, fixed = TRUE) &&
   grepl("cast(s.ELIGEFF as date) <= date('2025-06-30')", esql, fixed = TRUE),
   "the overlap predicate keeps any span touching the window")
# The failure mode this guards: filtering spans by their START would drop a
# 2010-2020 span and silently break every CE criterion.
ok(!grepl("cast(s.ELIGEFF as date) >=", esql, fixed = TRUE),
   "it never filters spans out by their START date")

# Not filtered at all, and for stated reasons.
for (n in c("member_cont_enrollment", "dod"))
  ok(is.null(TBL(n)$date),
     paste0(n, " is not date-filtered (ranking / post-window death)"))
ok(!grepl("WHERE", copy_sql(TBL("dod"), ARGS, WIN, FALSE), fixed = TRUE),
   "dod copies every row when no patient sample is used")

# =============================================================================
section("generated SQL")

m <- copy_sql(TBL("medical"), ARGS, WIN, use_patients = FALSE)
ok(grepl("CREATE OR REPLACE TABLE hive_metastore.myschema.medical", m, fixed = TRUE),
   "writes to the work schema under the plain CDM base name")
ok(grepl("FROM hive_metastore.clnprw_optum.t_medical_2025q2 s", m, fixed = TRUE),
   "reads the quarterly source resolved by cdm_src()")
ok(!grepl("s.*", m, fixed = TRUE) && grepl("s.PROC_CD", m, fixed = TRUE),
   "projects named columns, not SELECT *")
ok(length(gregexpr("s\\.", m)[[1]]) == length(TBL("medical")$cols) + 1L,
   "projects exactly the registered column count (+1 for the FROM alias)")
ok(grepl("BETWEEN date('2015-07-01') AND date('2025-06-30')", m, fixed = TRUE),
   "windows claims to the configured study period by default")

# --years narrows; the study window remains the default.
wy <- window_bounds(parse_args("--years=2018:2022"))
ok(identical(wy$lo, "2018-01-01") && identical(wy$hi, "2022-12-31"),
   "--years=2018:2022 becomes a full-year window")
ok(grepl("date('2018-01-01')", copy_sql(TBL("rx"), ARGS, wy, FALSE), fixed = TRUE),
   "the narrowed window reaches the generated SQL")

# Escape hatches.
ac <- copy_sql(TBL("medical"), parse_args("--all-columns"), WIN, FALSE)
ok(grepl("SELECT s.*", ac, fixed = TRUE), "--all-columns falls back to SELECT *")
ay <- copy_sql(TBL("medical"), parse_args("--all-years"), WIN, FALSE)
ok(!grepl("BETWEEN", ay, fixed = TRUE), "--all-years drops the date filter")

# Patient sampling composes with, rather than replaces, the date filter.
ps <- copy_sql(TBL("medical"), ARGS, WIN, use_patients = TRUE)
ok(grepl("IN (SELECT PATID FROM hive_metastore.myschema.src_patients)", ps, fixed = TRUE) &&
   grepl("BETWEEN", ps, fixed = TRUE),
   "a patient sample ANDs with the window rather than replacing it")

# =============================================================================
section("argument validation fails closed")

throws(parse_args("--patients=lots"), "a non-numeric --patients is rejected")
throws(parse_args("--years=2018"),    "a malformed --years is rejected")
# The range check lives in window_bounds(), which main() calls before it
# connects -- so a reversed range still fails before anything is written.
throws(window_bounds(parse_args("--years=2022:2018")),
       "a reversed --years range is rejected")
ok(identical(parse_args(character(0))$patients, "all"),
   "the default is all patients (a slim copy, not a sample)")
ok(!parse_args(character(0))$all_columns && !parse_args(character(0))$all_years,
   "narrow columns and the study window are the DEFAULT, not opt-in")

# =============================================================================
cat("\n", strrep("-", 52), "\n", sep = "")
cat(sprintf("load_tables: %d passed, %d failed\n", .n_pass, .n_fail))
if (.n_fail > 0L) quit(status = 1L)
