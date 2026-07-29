#!/usr/bin/env Rscript
# =============================================================================
# test_ndmm.R -- the NDMM cohort's own contract
# -----------------------------------------------------------------------------
#   Rscript "Jul 28/ndmm/tests/test_ndmm.R"
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

SPEC <- cohort_specs()$ndmm
ND   <- bind_lot1_aliases(resolve_spec(SPEC, cfg = CFG))

section("definition")
ok(identical(SPEC$id, "ndmm") && identical(SPEC$folder, "ndmm"),
   "the folder name is the cohort id")
ok(identical(SPEC$flag_col, "COHORT_NDMM"), "membership column is COHORT_NDMM")
ok(identical(SPEC$source_file, file.path("ndmm", "cohort.R")),
   "loaded from ndmm/cohort.R")

section("independence from Overall -- the point of the whole change")
src <- paste(readLines(file.path(dirname(.here), "cohort.R")), collapse = "\n")
code <- paste(grep("^\\s*#", strsplit(src, "\n")[[1]], value = TRUE, invert = TRUE),
              collapse = "\n")
ok(!grepl("overall", code, fixed = TRUE), "the definition never references overall")
ok(is.null(SPEC$base), "declares no base cohort (not derived from Overall)")
ok(!grepl("SQL|SELECT|WHERE", code), "the definition contains no SQL")
ok(all(vapply(SPEC$gates, function(g) grepl(paste0('"', g, '"'), src, fixed = TRUE),
              logical(1))),
   "every gate is listed literally, not pulled from a shared constant")
gen <- c(sql_index_sel(ND, CFG), sql_cohort(ND, CFG))
ok(!any(grepl("ELIG_COH_FINAL", gen, fixed = TRUE)),
   "the generated SQL never reads ELIG_COH_FINAL")
ok(!any(grepl("overall", gen, fixed = TRUE)),
   "the generated SQL never reads anything belonging to Overall")

section("LOT1-anchored gates")
lot1 <- Filter(function(g) identical(g$anchor, "lot1"), ND$resolved_gates)
# Order matters: the final AND-set does not depend on it, but the attrition
# funnel does, and this folder reproduces the legacy REPORT, not just the legacy
# cohort. This is ndmm_counts()' order in 06_ndmm_dashboard.R -- CE_lot1_3mo_fu
# is FIFTH, after other-cancer. tests/test_equivalence.R derives the same order
# from the dashboard source rather than hardcoding it.
ok(identical(unname(vapply(lot1, `[[`, character(1), "predicate")), c(
     "l1.LOT1_START_DT IS NOT NULL",
     "l1.LOT1_START_DT >= date('2017-01-01')",
     "n.CE_pre_lot1_12mo = 1", "n.NO_BELANTAMAB = 1", "n.NO_PRIOR_MM_TX = 1",
     "n.NO_OTHER_CANCER_PRE_LOT1 = 1", "n.CE_lot1_3mo_fu = 1",
     "n.NO_PREGNANCY = 1")),
   "match 06_ndmm_dashboard.R's NDMM_PATIDS filter and funnel order, plus has_lot1")
ids <- unname(vapply(ND$resolved_gates, `[[`, character(1), "id"))
ok(which(ids == "has_lot1") < which(ids == "lot1_from"),
   "has_lot1 precedes every gate that reads LOT1_START_DT")
a <- vapply(ND$resolved_gates, `[[`, character(1), "anchor")
ok(identical(unname(a), unname(a[order(match(a, ANCHORS))])),
   "index-anchored gates are all evaluated before LOT1-anchored ones")

section("treatment start vs LOT1 start")
# fu_mm_agents counts ANY MM agent including steroids (pipeline_steps.R:723);
# has_lot1 requires a non-steroid regimen (02_lot1.R:678). NDMM needs BOTH --
# its gates are anchored at LOT1_START_DT, so with no LOT1 there is no anchor.
ok(all(c("fu_mm_agents", "has_lot1") %in% SPEC$gates),
   "requires a treatment start AND a LOT1 anchor")

section("the flag stage ships with this cohort")
ok(file.exists(file.path(dirname(.here), "build_lot1_flags.R")),
   "ndmm/build_lot1_flags.R is in this folder")
fs <- paste(readLines(file.path(dirname(.here), "build_lot1_flags.R")), collapse = "\n")
ok(grepl("LOT1_PATIENT_INPUT", fs, fixed = TRUE) &&
   grepl("coh_index_union", fs, fixed = TRUE),
   "the flag stage defaults to the union view, not ELIG_COH_FINAL")

res <- test_summary("ndmm")
if (res[["fail"]] > 0L) quit(status = 1L)
