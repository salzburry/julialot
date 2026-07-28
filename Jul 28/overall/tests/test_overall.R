#!/usr/bin/env Rscript
# =============================================================================
# test_overall.R -- the Overall cohort's own contract
# -----------------------------------------------------------------------------
#   Rscript "Jul 28/overall/tests/test_overall.R"
#
# Only assertions about THIS cohort. Engine-level and cross-cohort invariants
# live in ../../tests/test_engine.R.
# =============================================================================

.here <- local({
  fa <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (!length(fa)) getwd()
  else dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", fa[1]), fixed = TRUE)))
})
source(file.path(dirname(dirname(.here)), "tests", "harness.R"))
test_bootstrap(.here)

SPEC <- cohort_specs()$overall
OV   <- resolve_spec(SPEC, cfg = CFG)

section("definition")
ok(identical(SPEC$id, "overall") && identical(SPEC$folder, "overall"),
   "the folder name is the cohort id")
ok(identical(SPEC$flag_col, "COHORT_OVERALL"), "membership column is COHORT_OVERALL")
ok(identical(SPEC$source_file, file.path("overall", "cohort.R")),
   "loaded from overall/cohort.R")

section("independence")
src <- paste(readLines(file.path(dirname(.here), "cohort.R")), collapse = "\n")
code <- paste(grep("^\\s*#", strsplit(src, "\n")[[1]], value = TRUE, invert = TRUE),
              collapse = "\n")
ok(!grepl("ndmm", code, fixed = TRUE), "the definition never references ndmm")
ok(is.null(SPEC$base), "declares no base cohort")
ok(!grepl("SQL|SELECT|WHERE", code), "the definition contains no SQL")
ok(all(vapply(SPEC$gates, function(g) grepl(paste0('"', g, '"'), src, fixed = TRUE),
              logical(1))),
   "every gate is listed literally, not pulled from a shared constant")

section("no LOT dependency")
# The operational promise of this folder: Overall needs only ELIG_COH_ALLFLAGS.
ok(!needs_lot1(OV), "no LOT1-anchored gates")
ok(length(required_source_cols(list(overall = SPEC))$lot1_flags) == 0L,
   "requires no column from any LOT1 table")
mem <- sql_cohort(bind_lot1_aliases(OV), CFG)
mem_code <- paste(grep("^\\s*--", strsplit(mem, "\n")[[1]], value = TRUE, invert = TRUE),
                  collapse = "\n")
ok(!grepl("JOIN", mem_code, fixed = TRUE) && !grepl("LOT1", mem_code, fixed = TRUE),
   "the membership view joins nothing and never names a LOT1 table")

section("equivalence with pipeline_steps.R step 24")
# Phase 1 must be a numeric no-op: same predicates, same order, same ranking as
# build_criteria_catalog() (criteria_attrition.R:38) + the step-1 index gate.
ok(identical(unname(vapply(OV$resolved_gates, `[[`, character(1), "predicate")), c(
     "(f.inpt_qual = 1 OR f.outpt2_60 = 1)", "f.AGE_INDEX_YR >= 18",
     "f.CE_b = 1", "f.CE_f = 1", "f.MM_bl_agents = 0", "f.MM_FU_agents = 1",
     "f.MM_baseline_diag = 0", "f.OTHER_MALIGN_FLAG = 0", "f.PREGNANT_FLAG = 0",
     "f.CLINTRIAL_BASELINE = 0 AND f.CLINTRIAL_FOLLOWUP = 0")),
   "predicates match step 24 exactly, in funnel order")
ok(grepl("row_number() OVER (PARTITION BY PATID ORDER BY INDEX_DATE)",
         sql_index_sel(OV, CFG), fixed = TRUE) &&
   grepl("WHERE rn = 1", sql_index_sel(OV, CFG), fixed = TRUE),
   "reproduces the earliest-qualifying-index window function and rn = 1")

section("treatment start, not a LOT1")
# fu_mm_agents counts ANY MM agent (pipeline_steps.R:723, no drug-class filter);
# a LOT1 start excludes steroids (02_lot1.R:678). Overall wants the broader one.
ok("fu_mm_agents" %in% SPEC$gates, "requires a treatment start")
ok(!("has_lot1" %in% SPEC$gates), "does NOT require a LOT1 regimen start")

res <- test_summary("overall")
if (res[["fail"]] > 0L) quit(status = 1L)
