#!/usr/bin/env Rscript
# =============================================================================
# test_cohort_specs.R -- offline tests for the spec + SQL layer
# -----------------------------------------------------------------------------
#   Rscript "Jul 28/tests/test_cohort_specs.R"
#
# Base R only, no warehouse: everything under test is pure config -> SQL text.
# These lock the properties that make the flag design safe, not the SQL string
# itself (which is expected to evolve).
# =============================================================================

# NOTE: commandArgs() escapes spaces in the script path as "~+~" (this folder is
# "Jul 28"). Un-escape before normalizePath() or every source() below fails.
.here <- local({
  fa <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (!length(fa)) return(getwd())
  dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", fa[1]), fixed = TRUE)))
})
source(file.path(.here, "..", "R", "cohort_specs.R"))
source(file.path(.here, "..", "R", "cohort_sql.R"))
set_cohort_dir(file.path(.here, "..", "cohorts"))

# ---- micro test harness -----------------------------------------------------
.n_pass <- 0L; .n_fail <- 0L
ok <- function(cond, what) {
  if (isTRUE(cond)) { .n_pass <<- .n_pass + 1L; cat("  ok   ", what, "\n") }
  else { .n_fail <<- .n_fail + 1L; cat("  FAIL ", what, "\n") }
}
throws <- function(expr, what) {
  e <- tryCatch({ force(expr); NULL }, error = function(e) e)
  ok(!is.null(e), what)
}
section <- function(s) cat("\n", s, "\n", sep = "")

CFG <- list(work_schema = "wk", view_prefix = "coh_",
            index_flags = "wk.ELIG_COH_ALLFLAGS",
            lot1_flags  = "wk.LOT1_FLAGS_ALL",
            lot1_starts = "wk.LOT1_STARTS",
            persist_schema = "wk", pld_table = "COHORT_PLD",
            min_age = 18L, outpatient_window = 60L, lot1_from = "2017-01-01")

REG   <- gate_registry()
SPECS <- cohort_specs()
R     <- lapply(SPECS, resolve_spec, cfg = CFG)

# =============================================================================
section("registry integrity")

ok(all(vapply(REG, function(g) g$anchor %in% ANCHORS, logical(1))),
   "every gate declares a known anchor")
ok(all(vapply(REG, function(g) g$polarity %in% c("incl", "excl"), logical(1))),
   "every gate declares a known polarity")
ok(identical(names(REG), unname(vapply(REG, `[[`, character(1), "id"))),
   "registry names match gate ids")
ok(all(vapply(REG, function(g) is.logical(g$tunable) && !is.na(g$tunable), logical(1))),
   "every gate declares tunable TRUE/FALSE")
# A gate with parameters that is NOT tunable is a trap: the spec could appear
# to set a window that the pre-baked flag ignores.
ok(all(vapply(REG, function(g) length(g$params) == 0L || isTRUE(g$tunable), logical(1))),
   "parameterised gates are all selection-time tunable")

# =============================================================================
section("the decoupling property -- this is the point of the whole change")

ok(is.null(SPECS$ndmm$base) && is.null(SPECS$overall$base),
   "no spec declares a base cohort (siblings, not a chain)")

# ONE FILE PER COHORT. Each definition must stand alone on disk: no shared
# constant to edit by accident, no cross-reference between the two files.
COH_DIR <- file.path(.here, "..", "cohorts")
ok(setequal(basename(list.files(COH_DIR, pattern = "\\.R$")),
            c("overall.R", "ndmm.R")),
   "cohorts/ holds exactly one file per cohort")
ok(identical(SPECS$overall$source_file, "overall.R") &&
   identical(SPECS$ndmm$source_file, "ndmm.R"),
   "each spec records the file it was loaded from")
nd_src <- paste(readLines(file.path(COH_DIR, "ndmm.R")), collapse = "\n")
ov_src <- paste(readLines(file.path(COH_DIR, "overall.R")), collapse = "\n")
nd_code <- paste(grep("^\\s*#", strsplit(nd_src, "\n")[[1]], value = TRUE, invert = TRUE),
                 collapse = "\n")
ov_code <- paste(grep("^\\s*#", strsplit(ov_src, "\n")[[1]], value = TRUE, invert = TRUE),
                 collapse = "\n")
ok(!grepl("overall", nd_code, fixed = TRUE),
   "cohorts/ndmm.R does not reference overall anywhere in its code")
ok(!grepl("ndmm", ov_code, fixed = TRUE),
   "cohorts/overall.R does not reference ndmm anywhere in its code")
# Each file must literally enumerate its gates -- a shared constant would mean
# editing one cohort silently edits the other.
ok(!grepl("INDEX_GATES", paste(nd_code, ov_code), fixed = TRUE),
   "neither cohort file pulls its gates from a shared constant")
ok(all(vapply(SPECS$ndmm$gates,
              function(g) grepl(paste0('"', g, '"'), nd_src, fixed = TRUE), logical(1))),
   "cohorts/ndmm.R literally lists every one of its gates")
ok(all(vapply(SPECS$overall$gates,
              function(g) grepl(paste0('"', g, '"'), ov_src, fixed = TRUE), logical(1))),
   "cohorts/overall.R literally lists every one of its gates")

# A new cohort must need no engine edit.
tmp <- file.path(tempdir(), "cohorts_extra")
dir.create(tmp, showWarnings = FALSE)
invisible(file.copy(list.files(COH_DIR, full.names = TRUE), tmp, overwrite = TRUE))
writeLines(c('list(id = "probe", label = "Probe", flag_col = "COHORT_PROBE",',
             '     order = 30L, gates = c("age_at_index"), params = list())'),
           file.path(tmp, "probe.R"))
probe <- cohort_specs(tmp)
ok(identical(names(probe), c("overall", "ndmm", "probe")),
   "dropping a file into cohorts/ registers a new cohort, ordered by `order`")
ok(identical(build_plan(list(probe = resolve_spec(probe$probe, CFG)), CFG)$steps[[1]]$name,
             "probe_index_sel"),
   "a newly added cohort builds with no engine change")
throws(cohort_specs(file.path(tempdir(), "definitely_absent")),
       "a missing cohorts/ directory is rejected")
ok(!any(grepl("ELIG_COH_FINAL", c(
     sql_index_sel(R$ndmm, CFG), sql_cohort(bind_lot1_aliases(R$ndmm), CFG)))),
   "NDMM's generated SQL never reads ELIG_COH_FINAL")

# =============================================================================
section("equivalence with today's pipeline (Phase 1 must be a no-op)")

ov <- R$overall
ok(identical(unname(vapply(ov$resolved_gates, `[[`, character(1), "anchor")),
             rep("index", length(ov$resolved_gates))),
   "Overall has only index-anchored gates")
ok(!needs_lot1(ov), "Overall does not require the LOT1 flag tables")
ok(grepl("row_number() OVER (PARTITION BY PATID ORDER BY INDEX_DATE)",
         sql_index_sel(ov, CFG), fixed = TRUE),
   "Overall reproduces step 24's earliest-qualifying-index window function")
# The 10 predicates of build_criteria_catalog() + the step-1 index gate.
todays_overall <- c(
  "(f.inpt_qual = 1 OR f.outpt2_60 = 1)", "f.AGE_INDEX_YR >= 18",
  "f.CE_b = 1", "f.CE_f = 1", "f.MM_bl_agents = 0", "f.MM_FU_agents = 1",
  "f.MM_baseline_diag = 0", "f.OTHER_MALIGN_FLAG = 0", "f.PREGNANT_FLAG = 0",
  "f.CLINTRIAL_BASELINE = 0 AND f.CLINTRIAL_FOLLOWUP = 0")
ok(identical(unname(vapply(ov$resolved_gates, `[[`, character(1), "predicate")),
             todays_overall),
   "Overall's predicates match pipeline_steps.R step 24 exactly, in order")

nd <- bind_lot1_aliases(R$ndmm)
nd_lot1 <- Filter(function(g) identical(g$anchor, "lot1"), nd$resolved_gates)
ok(identical(unname(vapply(nd_lot1, `[[`, character(1), "predicate")), c(
     "l1.LOT1_START_DT IS NOT NULL",
     "l1.LOT1_START_DT >= date('2017-01-01')",
     "n.CE_pre_lot1_12mo = 1", "n.CE_lot1_3mo_fu = 1", "n.NO_BELANTAMAB = 1",
     "n.NO_PRIOR_MM_TX = 1", "n.NO_OTHER_CANCER_PRE_LOT1 = 1",
     "n.NO_PREGNANCY = 1")),
   "NDMM's LOT1 predicates match 06_ndmm_dashboard.R's NDMM_PATIDS filter")
ok(setequal(setdiff(nd$gates, ov$gates),
            c("has_lot1", "lot1_from", "ce_pre_lot1_12mo", "ce_fu_lot1_3mo",
              "no_belantamab", "no_prior_mm_tx", "no_other_cancer_pre_lot1",
              "no_pregnancy_study")),
   "NDMM = Overall's gate set plus the seven documented additions and has_lot1")

# ---------------------------------------------------------------------------
# fu_mm_agents vs has_lot1 -- these are NOT the same criterion.
#   fu_mm_agents : any cl_mma_codelist claim in follow-up, NO class filter
#                  (pipeline_steps.R:723) -- steroids count.
#   has_lot1     : a LOT1 regimen start, which 02_lot1.R:678 derives as
#                  min(MAP_START_DT) WHERE MAP_MED_CLASS <> 'STEROID'.
# A steroid-only follow-up satisfies the first and not the second. Overall
# keeps that patient; NDMM cannot (no LOT1 anchor to hang its gates on).
ok(identical(REG$fu_mm_agents$anchor, "index") &&
   identical(REG$has_lot1$anchor, "lot1"),
   "fu_mm_agents and has_lot1 are distinct gates at distinct anchors")
ok("fu_mm_agents" %in% SPECS$overall$gates && !("has_lot1" %in% SPECS$overall$gates),
   "Overall requires a treatment start but NOT a LOT1 regimen start")
ok(all(c("fu_mm_agents", "has_lot1") %in% SPECS$ndmm$gates),
   "NDMM requires both: a treatment start AND a LOT1 anchor")
nd_ids <- unname(vapply(nd$resolved_gates, `[[`, character(1), "id"))
ok(which(nd_ids == "has_lot1") < which(nd_ids == "lot1_from"),
   "has_lot1 is evaluated before any gate that reads LOT1_START_DT")

# =============================================================================
section("index-gate drift between the two files")

# Separate files CAN drift. They are identical today, and that is what makes
# Phase 1 a numeric no-op -- so assert it, and make the assertion the place
# where an intentional future divergence gets acknowledged.
d <- index_gate_diff(SPECS$overall, SPECS$ndmm)
ok(isTRUE(d$identical),
   "overall and ndmm currently declare identical index gates, in the same order")
ok(length(d$only_in_a) == 0L && length(d$only_in_b) == 0L,
   "neither file carries an index gate the other lacks")
# Drift must be DETECTED, not prevented -- diverging is a legitimate study
# decision, silently diverging is not.
fake <- SPECS$ndmm; fake$gates <- setdiff(fake$gates, "no_clintrial")
d2 <- index_gate_diff(SPECS$overall, fake)
ok(!isTRUE(d2$identical) && identical(d2$only_in_a, "no_clintrial"),
   "removing a gate from one file is reported as drift")
fake2 <- SPECS$ndmm
fake2$gates <- c(rev(Filter(function(g) identical(REG[[g]]$anchor, "index"), fake2$gates)),
                 Filter(function(g) identical(REG[[g]]$anchor, "lot1"), fake2$gates))
ok(isTRUE(index_gate_diff(SPECS$overall, fake2)$reordered),
   "same gates in a different funnel order is reported as drift too")

# =============================================================================
section("anchor discipline")

# The hazard jun_21_2026's registry called out: NDMM's 12-month CE must be its
# OWN gate, not a re-parameterisation of the 6-month index-anchored one.
ok(!identical(REG$ce_baseline_6mo$anchor, REG$ce_pre_lot1_12mo$anchor),
   "baseline CE and pre-LOT1 CE are distinct gates at distinct anchors")
ok(!identical(REG$ce_followup_3mo$anchor, REG$ce_fu_lot1_3mo$anchor),
   "index-anchored and LOT1-anchored 3-month follow-up CE are distinct gates")
# Ordering: a LOT1 gate can never be evaluated before the index is selected.
for (s in R) {
  a <- vapply(s$resolved_gates, `[[`, character(1), "anchor")
  ok(identical(a, a[order(match(a, ANCHORS))]),
     paste0(s$id, ": index-anchored gates are ordered before LOT1-anchored"))
}
nd_aid <- unname(vapply(R$ndmm$resolved_gates, `[[`, character(1), "attrition_id"))
ok(identical(nd_aid, sprintf("%02d_%s", seq_along(nd_aid),
                             unname(vapply(R$ndmm$resolved_gates, `[[`, character(1), "id")))),
   "attrition ids are renumbered contiguously after anchor ordering")

# =============================================================================
section("validation fails closed")

throws(validate_spec(list(id = "x", label = "x", flag_col = "C", gates = "nope")),
       "unknown gate id is rejected")
throws(validate_spec(list(id = "x", label = "x", flag_col = "C",
                          gates = c("age_at_index", "age_at_index"))),
       "duplicate gate is rejected")
throws(validate_spec(list(id = "x", label = "x", flag_col = "C", gates = character(0))),
       "empty gate list is rejected")
throws(validate_spec(list(id = "x", label = "x", gates = "age_at_index")),
       "missing flag_col is rejected")
throws(validate_spec(list(id = "x", label = "x", flag_col = "C",
                          gates = "age_at_index",
                          params = list(age_at_index = list(nope = 1)))),
       "unknown parameter is rejected")
throws(validate_spec(list(id = "x", label = "x", flag_col = "C",
                          gates = "age_at_index",
                          params = list(ce_baseline_6mo = list(min_age = 21)))),
       "parameterising an undeclared gate is rejected")
# The important one: silently "overriding" a pre-baked window would produce a
# cohort that does not match its own stated definition.
throws(validate_spec(list(id = "x", label = "x", flag_col = "C",
                          gates = "ce_baseline_6mo",
                          params = list(ce_baseline_6mo = list(months = 12)))),
       "overriding a non-tunable gate's window is rejected")

# =============================================================================
section("parameter precedence: registry < cfg < spec")

ok(grepl("AGE_INDEX_YR >= 18", R$overall$resolved_gates$age_at_index$predicate),
   "cfg supplies min_age")
r70 <- resolve_spec(SPECS$overall, cfg = modifyList(CFG, list(min_age = 70L)))
ok(grepl("AGE_INDEX_YR >= 70", r70$resolved_gates$age_at_index$predicate),
   "cfg overrides the registry default")
sp <- SPECS$overall; sp$params <- list(age_at_index = list(min_age = 65L))
ok(grepl("AGE_INDEX_YR >= 65",
         resolve_spec(sp, cfg = CFG)$resolved_gates$age_at_index$predicate),
   "spec params override cfg")
ok(grepl("Age >= 65", resolve_spec(sp, cfg = CFG)$resolved_gates$age_at_index$label_resolved),
   "labels are interpolated with the resolved parameters")
w90 <- resolve_spec(SPECS$overall, cfg = modifyList(CFG, list(outpatient_window = 90L)))
ok(grepl("outpt2_90", w90$resolved_gates$idx_qualifying$predicate, fixed = TRUE),
   "the outpatient window selects the matching materialized column")

# =============================================================================
section("generated SQL")

plan <- build_plan(R, CFG)
step_names <- vapply(plan$steps, `[[`, character(1), "name")
ok(identical(step_names, c("overall_index_sel", "ndmm_index_sel", "index_union",
                           "overall_cohort", "ndmm_cohort", "pld", "pld_persist")),
   "plan emits the expected steps in dependency order")
ok(which(step_names == "index_union") < which(step_names == "ndmm_cohort"),
   "the LOT-build input is produced before any LOT1-anchored membership view")

u <- plan$steps[[which(step_names == "index_union")]]$sql
ok(grepl("SELECT DISTINCT PATID, INDEX_DATE", u, fixed = TRUE) &&
   grepl("UNION ALL", u, fixed = TRUE),
   "the union view de-duplicates (PATID, INDEX_DATE) across cohorts")

ovc <- plan$steps[[which(step_names == "overall_cohort")]]$sql
ovc_code <- paste(grep("^\\s*--", strsplit(ovc, "\n")[[1]], value = TRUE, invert = TRUE),
                  collapse = "\n")
ok(!grepl("JOIN", ovc_code, fixed = TRUE) &&
   !grepl("LOT1", ovc_code, fixed = TRUE),
   "Overall's membership view never joins the LOT1 tables")
ndc <- plan$steps[[which(step_names == "ndmm_cohort")]]$sql
ok(grepl("LEFT JOIN wk.LOT1_STARTS", ndc, fixed = TRUE) &&
   grepl("LEFT JOIN wk.LOT1_FLAGS_ALL", ndc, fixed = TRUE),
   "NDMM's membership view LEFT-joins the LOT1 tables")
# no-LOT1 patients are dropped by a COUNTABLE predicate rather than by join
# semantics -- same row set, but has_lot1 and lot1_from can be counted apart.
ok(!grepl("INNER JOIN wk.LOT1", ndc, fixed = TRUE) &&
   grepl("AND l1.LOT1_START_DT IS NOT NULL", ndc, fixed = TRUE),
   "the no-LOT1 drop is an explicit predicate, separable from the cutoff")

pld <- plan$steps[[which(step_names == "pld")]]$sql
ok(grepl("AS COHORT_OVERALL", pld, fixed = TRUE) &&
   grepl("AS COHORT_NDMM", pld, fixed = TRUE),
   "the PLD carries one 0/1 membership column per cohort")
ok(!grepl("INNER JOIN wk.coh_overall_cohort", pld, fixed = TRUE) &&
    grepl("LEFT JOIN wk.coh_overall_cohort", pld, fixed = TRUE),
   "the PLD LEFT-joins membership: it is the superset, it drops nobody")
ok(grepl("n.NO_BELANTAMAB", pld, fixed = TRUE) &&
   grepl("n.CE_pre_lot1_12mo", pld, fixed = TRUE),
   "the PLD exposes the LOT1-anchored flags as columns")

# One cohort alone must still produce a usable PLD.
solo <- build_plan(list(ndmm = R$ndmm), CFG)
solo_pld <- solo$steps[[which(vapply(solo$steps, `[[`, character(1), "name") == "pld")]]$sql
ok(grepl("AS COHORT_NDMM", solo_pld, fixed = TRUE) &&
   !grepl("COHORT_OVERALL", solo_pld, fixed = TRUE),
   "--cohort=ndmm alone yields a PLD with only the NDMM membership column")
ok(!grepl("overall", solo$steps[[1]]$sql, fixed = TRUE),
   "--cohort=ndmm alone emits no Overall step")

# =============================================================================
section("attrition funnel")

af <- plan$attrition$ndmm
ok(length(gregexpr("UNION ALL", af, fixed = TRUE)[[1]]) ==
     length(R$ndmm$resolved_gates),
   "the funnel has one arm per gate plus a terminal FINAL arm")
ok(grepl("count(DISTINCT PATID)", af, fixed = TRUE), "the funnel counts distinct patients")
ok(grepl("_final", af, fixed = TRUE), "the funnel ends with the built cohort as a check row")
# Cumulative, not per-gate: arm k must carry all k predicates.
first_arm <- strsplit(af, "UNION ALL", fixed = TRUE)[[1]][1]
last_idx_arm <- strsplit(af, "UNION ALL", fixed = TRUE)[[1]][10]
ok(length(gregexpr("AND ", first_arm, fixed = TRUE)[[1]]) <
   length(gregexpr("AND ", last_idx_arm, fixed = TRUE)[[1]]),
   "funnel arms are cumulative (later arms carry more predicates)")
ok(grepl("wk.coh_ndmm_index_sel", af, fixed = TRUE),
   "LOT1-anchored funnel arms count off the selected-index set, not raw candidates")
ok(grepl("_has_lot1", af, fixed = TRUE) && grepl("_lot1_from", af, fixed = TRUE),
   "has_lot1 and lot1_from get SEPARATE funnel rows (one fused row today)")
ok(!grepl("INNER JOIN", af, fixed = TRUE),
   "funnel arms LEFT-join, so has_lot1 is counted by its own predicate")

# =============================================================================
section("schema guard inputs")

need <- required_source_cols(R)
ok(all(c("CE_b", "MM_FU_agents", "CLINTRIAL_FOLLOWUP", "AGE_INDEX_YR") %in%
       need$index_flags),
   "index flag columns are collected for the schema guard")
ok(all(c("NO_BELANTAMAB", "CE_pre_lot1_12mo", "LOT1_START_DT") %in% need$lot1_flags),
   "LOT1 flag columns are collected for the schema guard")
need_ov <- required_source_cols(list(overall = SPECS$overall))
ok(length(need_ov$lot1_flags) == 0L,
   "an Overall-only run requires no LOT1 columns at all")

# =============================================================================
cat("\n", strrep("-", 52), "\n", sep = "")
cat(sprintf("%d passed, %d failed\n", .n_pass, .n_fail))
if (.n_fail > 0L) quit(status = 1L)
