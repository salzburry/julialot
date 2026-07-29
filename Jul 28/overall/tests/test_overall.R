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

section("the CONFIGURED cohort, not every criterion")

# What Overall applies is a configuration decision: criteria_attrition.R gates
# each criterion on its cfg_key, and pipeline_inputs.csv ships four FALSE. The
# authoritative comparison against build_criteria_sql() lives in
# tests/test_equivalence.R; here we only assert that this cohort reflects the
# configuration it was resolved with, in step-24 order.
applied  <- vapply(active_gates(OV), `[[`, character(1), "id")
declared <- vapply(OV$resolved_gates, `[[`, character(1), "id")

ok(identical(applied, declared[declared %in% applied]),
   "applied gates keep their declared funnel order")
for (g in declared) {
  key  <- gate_registry()[[g]]$cfg_key
  want <- if (is.na(key)) TRUE else isTRUE(CFG[[key]])
  ok(identical(g %in% applied, want),
     paste0(g, if (want) " is applied" else " is NOT applied",
            if (!is.na(key)) paste0("  (", key, ")") else "  (no toggle)"))
}
ok(grepl(paste0("outpt2_", CFG$outpatient_window), sql_index_sel(OV, CFG),
         fixed = TRUE),
   paste0("the index gate uses the configured ", CFG$outpatient_window,
          "-day outpatient window"))
ok(grepl("row_number() OVER (PARTITION BY PATID ORDER BY INDEX_DATE)",
         sql_index_sel(OV, CFG), fixed = TRUE) &&
   grepl("WHERE rn = 1", sql_index_sel(OV, CFG), fixed = TRUE),
   "reproduces step 24's earliest-qualifying-index selection")

# =============================================================================
section("treatment start, not a LOT1")
# fu_mm_agents counts ANY MM agent (pipeline_steps.R:723, no drug-class filter);
# a LOT1 start excludes steroids (02_lot1.R:678). Overall wants the broader one.
ok("fu_mm_agents" %in% SPEC$gates, "requires a treatment start")
ok(!("has_lot1" %in% SPEC$gates), "does NOT require a LOT1 regimen start")

res <- test_summary("overall")
if (res[["fail"]] > 0L) quit(status = 1L)
