#!/usr/bin/env Rscript
# =============================================================================
# test_cohort_overall.R -- does this folder implement the SAME IE funnel?
# -----------------------------------------------------------------------------
#   Rscript "Jul 28/cohort_overall/tests/test_cohort_overall.R"
#
# This folder contains a SECOND copy of the criteria SQL. A second copy that
# nothing compares is how NDMM's continuous-enrolment and prior-therapy
# definitions drifted from Overall's. So the copy is compared, mechanically:
#
#   section 3  every criterion -- label, predicate, toggle, order -- against
#              build_criteria_catalog(), EVALUATED, not read as text
#   section 4  the active filter against build_criteria_sql() under the
#              project's real configuration
#   section 5  every generated SELECT against the SELECT pipeline_steps.R's
#              build_steps() generates for the same cfg
#
# ---------------------------------------------------------------------------
# WHAT "MATCHES" MEANS HERE -- PRECISELY
# ---------------------------------------------------------------------------
# NORMALIZED-TEXT equality, not token-for-token and not byte-for-byte. Both sides
# are put through two transformations before comparing:
#
#   1. whitespace collapsed to single spaces
#   2. the CREATE clause dropped, and this folder's object qualifier
#      (catalog.schema.ovr_) removed, so `ovr_mm_qualifying` in the output schema
#      compares equal to the legacy `mm_qualifying` temp view
#
# Both are asserted safe before use: the legacy side must contain no occurrence of
# the qualifier, and the output schema must differ from the CDM schema. An earlier
# revision of this header said "token for token", which overstated it.
#
# ---------------------------------------------------------------------------
# WHAT THIS CANNOT PROVE -- AND WHICH SCRIPT DOES
# ---------------------------------------------------------------------------
# That the two produce the same PATIENTS. Identical SQL on identical inputs must,
# but "must" is not "did".
#
#   tests/verify_cohort_overall.R    ovr_ELIG_COH_FINAL vs the legacy
#                                   ELIG_COH_FINAL, both directions, on PATID
#                                   *and* (PATID, INDEX_DATE), plus grain and the
#                                   key flag columns -- THE gate for this folder.
#                                   Needs a warehouse.
#   ../tests/verify_against_legacy.R  compares the SELECTION layer's cohorts
#                                   (coh_overall_cohort, coh_index_union,
#                                   coh_ndmm_cohort). It does NOT read anything
#                                   this folder produces. An earlier revision of
#                                   the README pointed at it as this folder's
#                                   validation gate; that was wrong.
#
# Neither has been run. Nothing here changes that.
#
# The legacy comparison (section 6) needs apr_30_2026, which is NOT shipped. When
# it is absent those assertions SKIP with a message, and the suite still passes --
# a production checkout has nothing to compare against, and a suite that failed
# for that reason would just be switched off.
#
# Nor does this suite execute anything: it does not open a connection, so it
# cannot catch a runtime fault. What it does instead is assert the structural
# properties that make one impossible -- every object name is formed by work(),
# every CREATE by ie_stmt(), both from a step's `name` (section 2).
# =============================================================================

.here <- local({
  fa <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (!length(fa)) getwd()
  else dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", fa[1]),
                                  fixed = TRUE)))
})
IE_DIR <- dirname(.here)
ROOT   <- dirname(IE_DIR)
REPO   <- dirname(ROOT)

# The micro-harness only (ok / throws / section / test_summary). test_bootstrap()
# loads the selection engine, which this folder does not use.
source(file.path(ROOT, "tests", "harness.R"))

source(file.path(IE_DIR, "ie_runner.R"))
ie_bootstrap(IE_DIR)

CFG    <- ie_cfg(IE_DIR)
H      <- ie_names(CFG)
FUNNEL <- ie_funnel(CFG, H)
VIEWS  <- FUNNEL$views
CRIT   <- FUNNEL$criteria

# ---- helpers ----------------------------------------------------------------
squash <- function(x) trimws(gsub("\\s+", " ", paste(x, collapse = "\n")))
QUALIFIER <- H$qualifier()                       # catalog.schema.ovr_
strip_create <- function(x)
  sub("^\\s*CREATE OR REPLACE (TEMPORARY VIEW|TABLE)\\s+\\S+\\s+AS\\s*", "",
      paste(x, collapse = "\n"))
norm_ours   <- function(x) squash(gsub(QUALIFIER, "", x, fixed = TRUE))
norm_legacy <- function(x) squash(strip_create(as.character(x)))

# The legacy pipeline, in an isolated environment.
#
# Isolated for two reasons: criteria_attrition.R defines its own `%||%` (which
# would shadow anything of that name out here), and the legacy modules expect
# glue. glue is shimmed with fmt() -- these templates use exactly one glue
# feature, {expr} evaluated in the calling frame, and taking a hard dependency on
# the package to substitute text would mean this suite could not run without it.
# apr_30_2026 is located HERE, not in the production code -- ie_config.R has no
# notion of it (section 9). Absent in production, in which case every comparison
# against it skips.
APR <- local({
  d <- Sys.getenv("APR30_DIR", unset = "")
  cands <- if (nzchar(d)) d else file.path(c(REPO, dirname(REPO)), "apr_30_2026")
  hit <- Filter(function(x) file.exists(file.path(x, "R", "pipeline_steps.R")),
                cands)
  if (length(hit)) hit[1] else ""
})
HAVE_LEGACY <- nzchar(APR)
legacy <- if (!HAVE_LEGACY) NULL else local({
  e <- new.env(parent = globalenv())
  e$glue <- function(..., .sep = "", .envir = parent.frame())
    fmt(paste0(..., collapse = .sep), .envir)
  for (f in c("codelists.R", "db_utils.R", "criteria_attrition.R",
              "pipeline_steps.R"))
    sys.source(file.path(APR, "R", f), envir = e)
  e
})
LEG_CATALOG <- if (HAVE_LEGACY) legacy$build_criteria_catalog(CFG) else list()
LEG_STEPS   <- if (HAVE_LEGACY)
  Filter(Negate(is.null), legacy$build_steps(CFG, new.env())) else list()
LEG_BY_NAME <- setNames(LEG_STEPS, vapply(LEG_STEPS, function(s) s$name,
                                          character(1)))
skip_legacy <- function(what)
  cat("  skip  ", what, " (apr_30_2026 is not present -- normal in production)\n",
      sep = "")

# =============================================================================
section("1. the funnel is complete and ordered")

steps <- vapply(CRIT, function(c) c$step, integer(1))
ok(identical(unname(steps), 1:10),
   "criteria declare steps 1..10 exactly once, in funnel order")
ok(length(unique(vapply(CRIT, function(c) c$id, character(1)))) == length(CRIT),
   "criterion ids are unique")
ok(all(vapply(CRIT, function(c) identical(c$anchor, "index"), logical(1))),
   "every criterion is INDEX-anchored -- Overall never anchors on LOT1")
ok(is.na(CRIT[[1]]$cfg_key),
   "step 1 has no toggle: without a qualifying dx there is no index date")
ok(all(vapply(CRIT[-1], function(c) !is.na(c$cfg_key), logical(1))),
   "steps 2..10 are each behind a named toggle")
ok(length(unique(vapply(VIEWS, function(v) v$name, character(1)))) == length(VIEWS),
   "step names are unique")

# =============================================================================
section("2. object naming cannot go wrong -- structurally, not by convention")
# The bug this replaces: views were created with the prefix and the
# checkpoint was then materialized under the UNPREFIXED name, so a clean run
# failed at the first checkpoint (or, worse, materialized a stale object of that
# name). The fix is not a corrected string -- it is that a step no longer names
# its own object at all.

ok(all(vapply(VIEWS, function(v)
     !grepl("CREATE\\s+OR\\s+REPLACE", v$select, ignore.case = TRUE),
     logical(1))),
   "no step contains a CREATE -- the statement is generated from `name`")
throws(ie_view("x", "d", "CREATE OR REPLACE TABLE foo AS SELECT 1"),
       "a step that tries to write its own CREATE is rejected")
ok(all(vapply(VIEWS, function(v)
     identical(sub("^CREATE OR REPLACE TABLE\\s+", "",
                   regmatches(ie_stmt(v, CFG, H),
                              regexpr("CREATE OR REPLACE TABLE\\s+\\S+",
                                      ie_stmt(v, CFG, H)))),
               H$work(v$name)),
     logical(1))),
   "every generated CREATE targets exactly work(name)")
ok(all(vapply(VIEWS, function(v) startsWith(H$work(v$name), QUALIFIER),
              logical(1))),
   paste0("every object is schema-qualified and prefixed (", QUALIFIER, ")"))
ok(all(vapply(VIEWS, function(v)
     !grepl("TEMPORARY VIEW", v$select, ignore.case = TRUE), logical(1))),
   "nothing creates a temporary view (a SQL warehouse re-runs a view per read)")
ok(!any(grepl("materialize_to_personal_schema\\s*\\(",
              readLines(file.path(IE_DIR, "ie_runner.R"), warn = FALSE))),
   "the view-to-table materializer is never CALLED -- there are no views to convert")

# =============================================================================
section("3. it fails closed")

bad_key <- FUNNEL
bad_key$criteria[[2]]$cfg_key <- "apply_age_incll"
throws(ie_validate(bad_key),
       "a cfg_key that is not a real key is rejected (it would read as OFF)")

bad_col <- FUNNEL
bad_col$criteria[[3]]$flag_col <- "CE_baseline_6mo"
throws(ie_validate(bad_col),
       "a flag_col the assembly does not produce is rejected")

missing_step <- FUNNEL
missing_step$criteria <- missing_step$criteria[-5]
throws(ie_validate(missing_step), "a gap in the 1..10 funnel is rejected")

dup_step <- FUNNEL
dup_step$criteria[[4]]$step <- 3L
throws(ie_validate(dup_step), "a duplicated funnel step is rejected")

throws(ie_criterion(step = 3L, id = "x", label = "x", flag_col = "CE_b",
                    predicate = "CE_b = 1", anchor = "lot1"),
       "a LOT1-anchored criterion cannot be declared here at all")

# Configuration that the project's own readers accept silently. Each of these
# would otherwise change the cohort with nothing in the log.
with_env <- function(k, v, expr) {
  old <- Sys.getenv(k, unset = NA)
  do.call(Sys.setenv, setNames(list(v), k))
  on.exit(if (is.na(old)) Sys.unsetenv(k) else
          do.call(Sys.setenv, setNames(list(old), k)), add = TRUE)
  force(expr)
}
throws(with_env("OUTPATIENT_WINDOW", "45", ie_cfg(IE_DIR)),
       "OUTPATIENT_WINDOW=45 is rejected (validate_() would substitute 90)")
throws(with_env("APPLY_AGE_INCL", "Y", ie_cfg(IE_DIR)),
       "APPLY_AGE_INCL=Y is rejected (as.logical -> NA -> silently OFF)")
throws(with_env("MIN_AGE", "eighteen", ie_cfg(IE_DIR)),
       "MIN_AGE=eighteen is rejected")
throws(with_env("STUDY_END", "2026-06-30", ie_cfg(IE_DIR)),
       "a STUDY_END that disagrees with config_prompts.R is rejected, not ignored")
# An EMPTY prefix is indistinguishable from unset and falls back to the default,
# which is safe. A malformed one does not, and must be rejected: it is the only
# thing keeping these tables off the legacy pipeline's names.
throws(with_env("IE_OBJ_PREFIX", "ovr ", ie_cfg(IE_DIR)),
       "a malformed object prefix is rejected")
throws(with_env("IE_OBJ_PREFIX", "a.b", ie_cfg(IE_DIR)),
       "a prefix containing a dot is rejected (it would re-qualify the object)")
ok(identical(with_env("IE_OBJ_PREFIX", "", ie_cfg(IE_DIR))$obj_prefix, "ovr_"),
   "an empty prefix falls back to the default rather than producing bare names")

# The study window. cfg_defaults hardcodes it, so the INERT name must error and
# the IE_-prefixed name must work -- reviewer finding: a CSV STUDY_END logs
# "applied" and reaches nothing, and quarterly tables resolve off study_end.
throws(with_env("STUDY_END", "2026-06-30", ie_cfg(IE_DIR)),
       "STUDY_END (inert) that disagrees with cfg_defaults is rejected")
ok(identical(with_env("IE_STUDY_END", "2026-06-30", ie_cfg(IE_DIR))$study_end,
             "2026-06-30"),
   "IE_STUDY_END does take effect -- it is the working knob")
ok(identical(with_env("IE_STUDY_END", "2026-06-30",
                      ie_names(ie_cfg(IE_DIR))$cdm_src("medical")),
             paste0(CFG$catalog, ".", CFG$cdm_schema, ".t_medical_2026q2")),
   "...and it moves quarterly table resolution with it")
throws(with_env("IE_STUDY_END", "30-06-2026", ie_cfg(IE_DIR)),
       "a non-ISO IE_STUDY_END is rejected")
throws(with_env("IE_STUDY_END", "2015-01-01", ie_cfg(IE_DIR)),
       "a study window that ends before the ID period is rejected")
throws(with_env("IE_BASELINE_DAYS", "-1", ie_cfg(IE_DIR)),
       "a negative baseline length is rejected")
throws(with_env("IE_OUT_SCHEMA", CFG$cdm_schema, ie_cfg(IE_DIR)),
       "writing into the CDM schema is rejected")
ok(is.list(with_env("OUTPATIENT_WINDOW", "60", ie_cfg(IE_DIR))),
   "...but a legitimate OUTPATIENT_WINDOW=60 is accepted")

# =============================================================================
section("4. every criterion matches criteria_attrition.R's catalog")
# EVALUATED, not compared as source text: the catalog is built by calling the
# production function with the production cfg, so a changed label, window,
# operator or toggle name shows up here.

ours <- Filter(function(c) c$step >= 2L, CRIT)
if (!HAVE_LEGACY) skip_legacy("the whole catalog comparison") else
ok(length(ours) == length(LEG_CATALOG),
   paste0("same number of catalog criteria (", length(ours), ")"))

if (HAVE_LEGACY && length(ours) == length(LEG_CATALOG)) {
  for (i in seq_along(ours)) {
    a <- ours[[i]]; b <- LEG_CATALOG[[i]]
    ok(identical(a$attrition_id, b$attrition_id),
       paste0("step ", a$step, ": attrition id == ", b$attrition_id))
    ok(identical(as.character(a$label), as.character(b$label)),
       paste0("step ", a$step, ": label == \"", as.character(b$label), "\""))
    ok(identical(squash(paste0("AND ", a$predicate)),
                 squash(as.character(b$filter_sql))),
       paste0("step ", a$step, ": predicate == ", squash(as.character(b$filter_sql))))
    ok(identical(a$cfg_key, b$cfg_key),
       paste0("step ", a$step, ": toggle == ", b$cfg_key))
  }
}

# =============================================================================
section("5. the ACTIVE filter is the configured one")

if (!HAVE_LEGACY) skip_legacy("filter fragment vs build_criteria_sql()") else
ok(identical(squash(ie_criteria_sql(CRIT, CFG)),
             squash(legacy$build_criteria_sql(LEG_CATALOG, CFG))),
   "steps 2..10 filter fragment == build_criteria_sql() under this config")
ok(identical(CFG$outpatient_window, 90L),
   "OUTPATIENT_WINDOW is 90 (pipeline_inputs.csv), not the 60 an earlier suite assumed")

off <- vapply(Filter(function(c) !ie_is_active(c, CFG), CRIT),
              function(c) c$id, character(1))
ok(setequal(off, c("no_baseline_mm_evidence", "no_other_cancer",
                   "no_pregnancy", "no_clintrial")),
   "the four criteria that ship OFF are exactly the four in pipeline_inputs.csv")
ok(all(c("MM_baseline_diag", "OTHER_MALIGN_FLAG", "PREGNANT_FLAG",
         "CLINTRIAL_BASELINE", "CLINTRIAL_FOLLOWUP") %in%
       unlist(lapply(CRIT, function(c) c$flag_col))),
   "...and their flags are still computed, so they can be re-applied downstream")

final_sel <- Find(function(v) identical(v$name, CFG$final_table_name), VIEWS)$select
idx_rule <- function(s) regmatches(s, regexpr("\\(inpt_qual = 1 OR outpt2_[0-9]+ = 1\\)", s))
if (!HAVE_LEGACY) skip_legacy("the step 1 index rule vs legacy step 24") else
ok(identical(idx_rule(final_sel),
             idx_rule(as.character(LEG_BY_NAME[["24_ELIG_COH_FINAL"]]$sql))),
   paste0("the step 1 index rule is identical: ", idx_rule(final_sel)))
ok(identical(idx_rule(final_sel), CRIT[[1]]$predicate),
   "...and it comes from the step 1 criterion, not a second copy in the SQL")
ok(regexpr("WITH filtered", final_sel) < regexpr("ranked AS", final_sel),
   "the criteria are applied BEFORE the index date is ranked")
ok(grepl("row_number\\(\\) OVER \\(PARTITION BY PATID ORDER BY INDEX_DATE\\)",
         final_sel),
   "the surviving earliest index date is taken per patient")

# =============================================================================
section("6. every SELECT matches build_steps() after normalization")

if (!HAVE_LEGACY) skip_legacy("every SELECT vs build_steps()") else
ok(!any(grepl(QUALIFIER, vapply(LEG_STEPS, function(s) as.character(s$sql),
                                character(1)), fixed = TRUE)),
   paste0("no legacy statement contains '", QUALIFIER,
          "', so removing it cannot mask a difference"))
ok(!identical(tolower(CFG$out_schema), tolower(CFG$cdm_schema)),
   "the output schema differs from the CDM schema, so the strip is unambiguous")

# Legacy step 24b persisted the final temp view into a table. There is no
# counterpart here BY DESIGN: every step is already a table, so the cohort is
# persisted by step 24 itself. Reproducing 24b would re-introduce exactly the
# read-a-different-object-than-you-built bug this revision removed.
DELIBERATELY_ABSENT <- "24b_persist_final_cohort"

matched <- 0L
for (v in if (HAVE_LEGACY) VIEWS else list()) {
  if (is.na(v$legacy)) next
  leg <- LEG_BY_NAME[[v$legacy]]
  if (is.null(leg)) {
    ok(FALSE, paste0(v$name, ": legacy step '", v$legacy, "' does not exist"))
    next
  }
  matched <- matched + 1L
  ok(identical(norm_ours(v$select), norm_legacy(leg$sql)),
     paste0(v$name, ": SELECT == pipeline_steps.R ", v$legacy))
  if (!is.null(v$qc) && !is.null(leg$qc))
    ok(identical(norm_ours(v$qc), squash(as.character(leg$qc))),
       paste0(v$name, ": QC == pipeline_steps.R ", v$legacy))
}
if (HAVE_LEGACY)
ok(matched >= 27L,
   paste0("every step was compared against a legacy one (", matched, ")"))

ours_legacy <- na.omit(vapply(VIEWS, function(v) v$legacy, character(1)))
unmatched <- setdiff(names(LEG_BY_NAME), ours_legacy)
if (HAVE_LEGACY)
ok(setequal(unmatched, intersect(DELIBERATELY_ABSENT, names(LEG_BY_NAME))),
   paste0("the only legacy step not reproduced is the one deliberately absent",
          if (length(unmatched)) paste0(" (", paste(unmatched, collapse = ", "), ")")
          else " (none present in this config)"))

# qc_extra is this folder's own diagnostic and must NOT be part of the comparison.
extra <- Filter(function(v) !is.null(v$qc_extra), VIEWS)
ok(length(extra) >= 1L &&
   any(vapply(extra, function(v) identical(v$name, "mm_dx_events_all"),
              logical(1))),
   "mm_dx_events_all carries a qc_extra diagnostic (unknown care setting)")
if (HAVE_LEGACY)
ok(all(vapply(extra, function(v) {
     leg <- LEG_BY_NAME[[v$legacy]]
     is.null(leg) || !identical(norm_ours(v$qc_extra), squash(as.character(leg$qc)))
   }, logical(1))),
   "...and qc_extra is not compared to the legacy QC -- it asks a new question")

# =============================================================================
section("7. it cannot touch the legacy pipeline's objects")

ok(!identical(toupper(paste0(CFG$obj_prefix, CFG$final_table_name)),
              toupper(CFG$final_table_name)),
   paste0("the cohort table is ", H$work(CFG$final_table_name), ", not ",
          CFG$final_table_name))
ok(!any(vapply(VIEWS, function(v)
     grepl(paste0("CREATE[^\n]*\\b", CFG$final_table_name, "\\b"),
           ie_stmt(v, CFG, H)) &&
     !grepl(CFG$obj_prefix, ie_stmt(v, CFG, H), fixed = TRUE), logical(1))),
   "no statement writes an unprefixed object")
ok(all(vapply(VIEWS, function(v) !grepl("DROP TABLE|DELETE FROM|INSERT INTO",
                                        v$select), logical(1))),
   "no step drops, deletes from, or inserts into anything")

srcs <- unlist(lapply(c(Sys.glob(file.path(IE_DIR, "*.R")),
                        Sys.glob(file.path(IE_DIR, "steps", "*.R"))),
                      readLines, warn = FALSE))
ok(!any(grepl("apr_30_2026.*(writeLines|write\\.csv|file\\.copy|unlink)", srcs)),
   "no file here writes into apr_30_2026")

# =============================================================================
section("8. the runner offers only modes it can honour")
# --no-persist could not suppress table writes, --views ran nothing silently on a
# typo, and --attrition-only needed temp views no fresh session can have. All
# three are gone, and an unknown option is an error rather than a no-op.

ok(setequal(names(ie_parse_args(character(0))), c("funnel_only", "dry_run")),
   "the only modes are --funnel and --dry-run (plus the default build)")
for (dead in c("--no-persist", "--views=x", "--attrition-only", "--no-attrition"))
  throws(ie_parse_args(dead),
         paste0(dead, " is rejected rather than silently ignored"))

# =============================================================================
section("9. \"Jul 28\" is the deployable unit -- nothing outside it is read")
# The folder that goes to production is "Jul 28". A run-time read of
# apr_30_2026 would mean the deployable unit is not actually deployable.

RUNTIME <- c(Sys.glob(file.path(IE_DIR, "*.R")),
             Sys.glob(file.path(IE_DIR, "steps", "*.R")))
offenders <- Filter(function(f) {
  src <- readLines(f, warn = FALSE)
  code <- grep("^\\s*#", src, invert = TRUE, value = TRUE)   # ignore comments
  any(grepl("apr_30_2026", code))
}, RUNTIME)
ok(length(offenders) == 0L,
   paste0("no run-time file resolves a path into apr_30_2026",
          if (length(offenders))
            paste0(" (", paste(basename(offenders), collapse = ", "), ")") else ""))
ok(file.exists(file.path(ROOT, "lib", "config_prompts.R")) &&
   file.exists(file.path(ROOT, "lib", "load_inputs.R")) &&
   file.exists(file.path(ROOT, "lib", "db_utils.R")) &&
   file.exists(file.path(ROOT, "lib", "codelists.R")),
   "the plumbing this folder needs is inside Jul 28/lib")
ok(file.exists(file.path(ROOT, "pipeline_inputs.csv")),
   "the configuration it reads is Jul 28/pipeline_inputs.csv")
ok(identical(normalizePath(CFG$lib, mustWork = FALSE),
             normalizePath(file.path(ROOT, "lib"), mustWork = FALSE)),
   "ie_cfg() resolved lib to Jul 28/lib, not to apr_30_2026/R")

ok(is.null(CFG$apr_dir),
   "the configuration carries no apr_30_2026 path at all")
# The production state: APR30_DIR pointing nowhere must change nothing, because
# nothing in the build consults it.
prod <- with_env("APR30_DIR", file.path(tempdir(), "no-such-apr"), {
  c2 <- ie_cfg(IE_DIR)
  list(cfg = c2, funnel = ie_funnel(c2))
})
ok(length(prod$funnel$views) == length(VIEWS) &&
   length(prod$funnel$criteria) == length(CRIT),
   "with apr_30_2026 unreachable, the funnel still builds identically")
ok(identical(prod$cfg$study_end, CFG$study_end) &&
   identical(prod$cfg$outpatient_window, CFG$outpatient_window),
   "...with the same configuration, read from Jul 28")
ok(identical(sort(vapply(prod$funnel$views, function(v) v$select, character(1))),
             sort(vapply(VIEWS, function(v) v$select, character(1)))),
   "...and byte-identical SQL")

.res <- test_summary("cohort_overall")
if (.res[["fail"]] > 0L) quit(status = 1L)
