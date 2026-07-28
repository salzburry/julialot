#!/usr/bin/env Rscript
# =============================================================================
# test_engine.R -- engine + cross-cohort invariants
# -----------------------------------------------------------------------------
#   Rscript "Jul 28/tests/test_engine.R"
#
# Base R only, no warehouse: everything under test is pure config -> SQL text.
# =============================================================================

.here <- local({
  fa <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (!length(fa)) getwd()
  else dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", fa[1]), fixed = TRUE)))
})
source(file.path(.here, "harness.R"))
test_bootstrap(.here)

REG   <- gate_registry()
SPECS <- cohort_specs()
R     <- lapply(SPECS, resolve_spec, cfg = CFG)

plan <- build_plan(R, CFG)
step_names <- vapply(plan$steps, `[[`, character(1), "name")
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
section("one folder per cohort")

ROOT <- dirname(.here)
ok(setequal(basename(dirname(Sys.glob(file.path(ROOT, "*", "cohort.R")))),
            c("overall", "ndmm")),
   "each cohort is a folder containing cohort.R")
ok(identical(SPECS$overall$source_file, file.path("overall", "cohort.R")) &&
   identical(SPECS$ndmm$source_file,    file.path("ndmm",    "cohort.R")),
   "each spec records the folder it came from")
ok(identical(SPECS$overall$folder, SPECS$overall$id) &&
   identical(SPECS$ndmm$folder,    SPECS$ndmm$id),
   "the folder name IS the cohort id")

# Everything a cohort needs is in its folder; nothing reaches into the other's.
for (id in names(SPECS)) {
  # Non-test code only: a test legitimately NAMES the other cohort in order to
  # assert its absence, which is the opposite of a dependency on it.
  fs <- setdiff(list.files(file.path(ROOT, id), recursive = TRUE, full.names = TRUE,
                           pattern = "\\.R$"),
                list.files(file.path(ROOT, id, "tests"), recursive = TRUE,
                           full.names = TRUE, pattern = "\\.R$"))
  other <- setdiff(names(SPECS), id)
  txt <- unlist(lapply(fs, function(f)
    grep("^\\s*#", readLines(f, warn = FALSE), value = TRUE, invert = TRUE)))
  ok(!any(grepl(paste0("\\b", other, "\\b"), txt)),
     paste0(id, "/ non-test code never references ", other))
  ok(file.exists(file.path(ROOT, id, "build.R")),
     paste0(id, "/ has its own build entry point"))
  ok(length(list.files(file.path(ROOT, id, "tests"), pattern = "\\.R$")) > 0L,
     paste0(id, "/ has its own tests"))
}

# The shared engine is deliberately NOT copied into each folder: definitions are
# separate, the SQL generator is written once. Assert it lives in exactly one
# place so a stray copy cannot drift.
ok(setequal(basename(list.files(file.path(ROOT, "engine"), pattern = "\\.R$")),
            c("bootstrap.R", "cohort_specs.R", "cohort_sql.R", "cohort_run.R")),
   "the engine lives in engine/, as four files")
ok(!length(Sys.glob(file.path(ROOT, "*", "engine"))),
   "no cohort folder carries its own copy of the engine")
# bootstrap.R hardcodes the cohort filename because it is sourced first.
bt <- paste(readLines(file.path(ROOT, "engine", "bootstrap.R")), collapse = "\n")
ok(grepl('COHORT_FILE_NAME <- "cohort.R"', bt, fixed = TRUE) &&
   identical(COHORT_FILE, "cohort.R"),
   "bootstrap.R's cohort filename matches the loader's")

# A new cohort must need no engine edit.
tmp <- file.path(tempdir(), "cohort_root"); unlink(tmp, recursive = TRUE)
dir.create(file.path(tmp, "probe"), recursive = TRUE, showWarnings = FALSE)
for (id in names(SPECS)) {
  dir.create(file.path(tmp, id), showWarnings = FALSE)
  invisible(file.copy(file.path(ROOT, id, "cohort.R"), file.path(tmp, id)))
}
writeLines(c('list(id = "probe", label = "Probe", flag_col = "COHORT_PROBE",',
             '     order = 30L, gates = c("age_at_index"), params = list())'),
           file.path(tmp, "probe", "cohort.R"))
probe <- cohort_specs(tmp)
ok(identical(names(probe), c("overall", "ndmm", "probe")),
   "dropping in a folder registers a new cohort, ordered by `order`")
ok(identical(build_plan(list(probe = resolve_spec(probe$probe, CFG)), CFG)$steps[[1]]$name,
             "probe_index_sel"),
   "a newly added cohort builds with no engine change")
# The folder name is load-bearing: a mismatch must fail, not silently rename.
writeLines(c('list(id = "wrong", label = "X", flag_col = "C",',
             '     gates = c("age_at_index"), params = list())'),
           file.path(tmp, "probe", "cohort.R"))
throws(cohort_specs(tmp), "an id that disagrees with its folder is rejected")
throws(cohort_specs(file.path(tempdir(), "definitely_absent")),
       "a root with no cohort folders is rejected")

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
section("LOT-build input contract (Phase 2)")

# coh_index_union must be a DROP-IN for ELIG_COH_FINAL as the LOT build's input,
# so 02_lot1.R needs no edit -- only INPUT_COHORT_TABLE repointed. lot_patient_input
# (02_lot1.R:278) reads these columns; step 23 emits all of them, so projecting
# the full flag row is enough.
LOT_INPUT_COLS <- c("PATID", "INDEX_DATE", "ENDDATE", "ENDDATE_CE", "DEATH_DT",
                    "GDR_CD", "YRDOB", "AGE_INDEX_YR", "FU_DAYS", "FU_DAYS_CE")
ok(grepl("SELECT f.*", u, fixed = TRUE) &&
   grepl("INNER JOIN wk.ELIG_COH_ALLFLAGS f", u, fixed = TRUE),
   "the union view projects the full flag row, not just the key pair")
ok(all(vapply(LOT_INPUT_COLS, function(c) grepl(c, u, fixed = TRUE), logical(1))),
   "the union view documents every column lot_patient_input reads")
ok(grepl("SELECT DISTINCT PATID, INDEX_DATE FROM sel", u, fixed = TRUE),
   "de-duplication still happens on the key pair before the projection")

# --index-only exists to break the bootstrap ordering: the LOT build consumes
# the union view, but the membership views consume flags that only exist after
# the LOT build has run.
ok(isTRUE(parse_args(c("--index-only"))$index_only) &&
   !isTRUE(parse_args(character(0))$index_only),
   "--index-only is parsed, and off by default")
ok(which(step_names == "index_union") <
   min(which(step_names %in% c("overall_cohort", "ndmm_cohort"))),
   "the union view is produced before anything that needs the LOT1 flags")
# Truncating at index_union must leave a runnable prefix: the per-cohort index
# selections plus the union, and nothing that reads LOT1_FLAGS_ALL.
prefix <- plan$steps[seq_len(which(step_names == "index_union"))]
ok(!any(vapply(prefix, function(st) grepl("LOT1_FLAGS_ALL", st$sql, fixed = TRUE),
                logical(1))),
   "--index-only's prefix reads no LOT1 flag table (it does not exist yet)")

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


res <- test_summary("engine")
if (res[["fail"]] > 0L) quit(status = 1L)
