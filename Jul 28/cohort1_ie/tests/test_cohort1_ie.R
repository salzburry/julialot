#!/usr/bin/env Rscript
# =============================================================================
# test_cohort1_ie.R -- does this folder implement the SAME IE funnel?
# -----------------------------------------------------------------------------
#   Rscript "Jul 28/cohort1_ie/tests/test_cohort1_ie.R"
#
# This folder contains a SECOND copy of the criteria SQL. A second copy that
# nothing compares is how NDMM's continuous-enrolment and prior-therapy
# definitions drifted from Overall's in the first place. So the copy is compared,
# mechanically, on every run:
#
#   section 3  every criterion -- label, predicate, toggle, order -- against
#              build_criteria_catalog(), EVALUATED, not read as text
#   section 4  the active filter against build_criteria_sql() under the
#              project's real configuration
#   section 5  every generated statement against the statement
#              pipeline_steps.R's build_steps() generates for the same cfg,
#              token for token
#
# Section 5 is the one that matters. It renders BOTH sides with the same cfg and
# compares the SQL, so an edit to either copy fails this suite.
#
# ---------------------------------------------------------------------------
# WHAT THIS CANNOT PROVE
# ---------------------------------------------------------------------------
# That the two produce the same PATIENTS. Identical SQL on identical inputs must,
# but "must" is not "did", and citing a green text suite as evidence about
# patients is precisely what REVIEW_FINDINGS.md called out. The empirical check
# is tests/verify_against_legacy.R -- EXCEPT in both directions, on a warehouse.
# It has never been run. Nothing here changes that.
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

# The micro-harness only (ok / section / test_summary). test_bootstrap() loads the
# selection engine, which this folder does not use.
source(file.path(ROOT, "tests", "harness.R"))

source(file.path(IE_DIR, "ie_runner.R"))
ie_bootstrap(IE_DIR)

CFG    <- ie_cfg(IE_DIR)
H      <- ie_names(CFG)
FUNNEL <- ie_funnel(CFG, H)
VIEWS  <- FUNNEL$views
CRIT   <- FUNNEL$criteria

# ---- helpers ----------------------------------------------------------------
# Compare on meaning-bearing text: collapse whitespace, drop the view prefix.
# The prefix is the ONE intended difference from the legacy SQL, and it is
# stripped only after asserting the legacy side never contains it (section 5) --
# otherwise this normalization could hide a real difference.
squash <- function(x) trimws(gsub("\\s+", " ", paste(x, collapse = "\n")))
unprefix <- function(x) gsub(CFG$view_prefix, "", x, fixed = TRUE)
norm_sql <- function(x) unprefix(squash(x))

# The legacy pipeline, loaded into an isolated environment.
#
# Isolated for two reasons: criteria_attrition.R defines its own `%||%` (which
# would shadow anything of that name out here), and the legacy modules expect
# glue. `glue` is shimmed with fmt() -- these templates use exactly one glue
# feature, {expr} evaluated in the calling frame, and taking a hard dependency on
# the package to substitute text would mean this suite could not run without it.
legacy <- local({
  e <- new.env(parent = globalenv())
  e$glue <- function(..., .sep = "", .envir = parent.frame())
    fmt(paste0(..., collapse = .sep), .envir)
  apr <- CFG$apr_dir
  for (f in c("codelists.R", "db_utils.R", "criteria_attrition.R",
              "pipeline_steps.R"))
    sys.source(file.path(apr, "R", f), envir = e)
  e
})
LEG_CATALOG <- legacy$build_criteria_catalog(CFG)
LEG_STEPS   <- Filter(Negate(is.null), legacy$build_steps(CFG, new.env()))
LEG_BY_NAME <- setNames(LEG_STEPS, vapply(LEG_STEPS, function(s) s$name,
                                          character(1)))

# =============================================================================
section("1. the funnel is complete and ordered")

steps <- vapply(CRIT, function(c) c$step, integer(1))
ok(identical(unname(steps), 1:10),
   "criteria declare steps 1..10 exactly once, in funnel order")
ok(length(unique(vapply(CRIT, function(c) c$id, character(1)))) == length(CRIT),
   "criterion ids are unique")
ok(all(vapply(CRIT, function(c) identical(c$anchor, "index"), logical(1))),
   "every criterion is INDEX-anchored -- cohort 1 never anchors on LOT1")
ok(is.na(CRIT[[1]]$cfg_key),
   "step 1 has no toggle: without a qualifying dx there is no index date")
ok(all(vapply(CRIT[-1], function(c) !is.na(c$cfg_key), logical(1))),
   "steps 2..10 are each behind a named toggle")
ok(length(unique(vapply(VIEWS, function(v) v$name, character(1)))) == length(VIEWS),
   "view names are unique")

# =============================================================================
section("2. it fails closed")

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
throws(ie_validate(missing_step),
       "a gap in the 1..10 funnel is rejected")

dup_step <- FUNNEL
dup_step$criteria[[4]]$step <- 3L
throws(ie_validate(dup_step), "a duplicated funnel step is rejected")

throws(ie_criterion(step = 3L, id = "x", label = "x", flag_col = "CE_b",
                    predicate = "CE_b = 1", anchor = "lot1"),
       "a LOT1-anchored criterion cannot be declared here at all")

# An unprefixed view would collide with the legacy pipeline's view of that name.
unpref <- FUNNEL
unpref$views[[1]]$sql <- gsub(CFG$view_prefix, "", unpref$views[[1]]$sql,
                              fixed = TRUE)
throws(ie_validate(unpref), "an unprefixed CREATE ... TEMPORARY VIEW is rejected")

ok(all(vapply(VIEWS, function(v) {
     m <- regmatches(v$sql, regexpr("CREATE OR REPLACE TEMPORARY VIEW\\s+\\S+", v$sql))
     if (!length(m)) return(TRUE)
     startsWith(sub("^CREATE OR REPLACE TEMPORARY VIEW\\s+", "", m), CFG$view_prefix)
   }, logical(1))),
   "every temp view this folder creates carries the prefix")

# =============================================================================
section("3. every criterion matches criteria_attrition.R's catalog")
# EVALUATED, not compared as source text. The catalog is built by calling the
# production function with the production cfg, so a changed label, window,
# operator or toggle name shows up here.

ours <- Filter(function(c) c$step >= 2L, CRIT)
ok(length(ours) == length(LEG_CATALOG),
   paste0("same number of catalog criteria (", length(ours), ")"))

if (length(ours) == length(LEG_CATALOG)) {
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
section("4. the ACTIVE filter is the configured one")
# Not "every criterion is implemented" -- which cohort actually gets built.
# pipeline_inputs.csv ships four exclusions FALSE, so a suite that assumed all
# criteria were on would be validating a cohort nobody runs.

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

final_sql <- Find(function(v) identical(v$name, CFG$final_table_name), VIEWS)$sql
leg_final <- LEG_BY_NAME[["24_ELIG_COH_FINAL"]]$sql
idx_rule <- function(s) regmatches(s, regexpr("\\(inpt_qual = 1 OR outpt2_[0-9]+ = 1\\)", s))
ok(identical(idx_rule(final_sql), idx_rule(as.character(leg_final))),
   paste0("the step 1 index rule is identical: ", idx_rule(final_sql)))
ok(identical(idx_rule(final_sql), CRIT[[1]]$predicate),
   "...and it comes from the step 1 criterion, not a second copy in the SQL")

# Filter-then-rank. Reversed, this drops patients whose earliest candidate index
# fails a gate but a later one passes.
ok(regexpr("WITH filtered", final_sql) < regexpr("ranked AS", final_sql),
   "the criteria are applied BEFORE the index date is ranked")
ok(grepl("row_number\\(\\) OVER \\(PARTITION BY PATID ORDER BY INDEX_DATE\\)",
         final_sql),
   "the surviving earliest index date is taken per patient")

# =============================================================================
section("5. every statement matches build_steps(), token for token")
# The strongest static statement available: render both sides from the same cfg
# and compare. Legacy view names are unprefixed, so the prefix is stripped --
# after asserting it never occurs on the legacy side, so the strip cannot mask a
# genuine difference.

ok(!any(grepl(CFG$view_prefix, vapply(LEG_STEPS, function(s) s$sql, character(1)),
              fixed = TRUE)),
   paste0("no legacy statement contains '", CFG$view_prefix,
          "', so stripping it is safe"))

# The persist step is the one intentional exception: it writes IE_FINAL_TABLE
# (C1_ELIG_COH_FINAL) rather than FINAL_TABLE_NAME, because writing the legacy
# pipeline's output table from here would replace the cohort the LOT build reads.
EXEMPT <- "24b_persist_final_cohort"

matched <- 0L
for (v in VIEWS) {
  if (is.na(v$legacy) || identical(v$legacy, EXEMPT)) next
  leg <- LEG_BY_NAME[[v$legacy]]
  if (is.null(leg)) {
    ok(FALSE, paste0(v$name, ": legacy step '", v$legacy, "' does not exist"))
    next
  }
  matched <- matched + 1L
  ok(identical(norm_sql(v$sql), squash(as.character(leg$sql))),
     paste0(v$name, ": SQL == pipeline_steps.R ", v$legacy))
  if (!is.null(v$qc) && !is.null(leg$qc))
    ok(identical(norm_sql(v$qc), squash(as.character(leg$qc))),
       paste0(v$name, ": QC == pipeline_steps.R ", v$legacy))
}
ok(matched >= 18L,
   paste0("every non-exempt statement was compared against a legacy one (",
          matched, ")"))

# Nothing in build_steps() is silently left out. The legacy steps this folder
# does not reproduce must be named, with a reason.
ours_legacy <- na.omit(vapply(VIEWS, function(v) v$legacy, character(1)))
unmatched <- setdiff(names(LEG_BY_NAME), ours_legacy)
ok(length(unmatched) == 0L,
   paste0("no legacy step is unimplemented",
          if (length(unmatched)) paste0(" (missing: ",
                                        paste(unmatched, collapse = ", "), ")")
          else ""))

# =============================================================================
section("6. it cannot overwrite the legacy pipeline's outputs")

ok(!identical(toupper(CFG$ie_final_table), toupper(CFG$final_table_name)),
   paste0("the persisted cohort is ", CFG$ie_final_table, ", not ",
          CFG$final_table_name))
persist_v <- Find(function(v) startsWith(v$name, "persist_"), VIEWS)
# The WRITE TARGET, not the whole statement -- the SELECT legitimately reads the
# temp view whose base name IS ELIG_COH_FINAL (prefixed to c1_ELIG_COH_FINAL).
target <- if (is.null(persist_v)) NA_character_ else
  sub("^CREATE OR REPLACE TABLE\\s+", "",
      regmatches(persist_v$sql,
                 regexpr("CREATE OR REPLACE TABLE\\s+\\S+", persist_v$sql)))
ok(!is.na(target) && endsWith(target, CFG$ie_final_table),
   paste0("the persist statement's write target is ", target))
ok(!is.na(target) && !grepl(paste0("\\.", CFG$final_table_name, "$"), target),
   "...and it is not the legacy pipeline's cohort table")

old <- Sys.getenv("IE_FINAL_TABLE", unset = NA)
Sys.setenv(IE_FINAL_TABLE = CFG$final_table_name)
throws(ie_cfg(IE_DIR),
       "pointing IE_FINAL_TABLE at the legacy table is refused outright")
if (is.na(old)) Sys.unsetenv("IE_FINAL_TABLE") else Sys.setenv(IE_FINAL_TABLE = old)

ok(all(vapply(VIEWS, function(v) !grepl("DROP TABLE|DELETE FROM|INSERT INTO",
                                        v$sql), logical(1))),
   "no statement drops, deletes from, or inserts into anything")

# apr_30_2026 is read for config and plumbing and written to never. The whole
# directory is asserted byte-identical to the branch point by
# tests/test_equivalence.R section 1; this checks the narrower claim that nothing
# HERE names a path inside it as a write target.
srcs <- unlist(lapply(c(Sys.glob(file.path(IE_DIR, "*.R")),
                        Sys.glob(file.path(IE_DIR, "steps", "*.R"))),
                      readLines, warn = FALSE))
ok(!any(grepl("apr_30_2026.*(writeLines|write\\.csv|file\\.copy|unlink)", srcs)),
   "no file here writes into apr_30_2026")

.res <- test_summary("cohort1_ie")
if (.res[["fail"]] > 0L) quit(status = 1L)
