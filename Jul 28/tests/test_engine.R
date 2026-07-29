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
# Numbered over APPLIED gates only: a criterion the configuration disables has
# no attrition row, so the ids must skip it rather than leave a hole.
nd_act <- active_gates(R$ndmm)
nd_aid <- unname(vapply(nd_act, `[[`, character(1), "attrition_id"))
ok(identical(nd_aid, sprintf("%02d_%s", seq_along(nd_aid),
                             unname(vapply(nd_act, `[[`, character(1), "id")))),
   "attrition ids are contiguous over the APPLIED gates")
ok(all(is.na(vapply(Filter(function(g) !isTRUE(g$active), R$ndmm$resolved_gates),
                    `[[`, character(1), "attrition_id"))),
   "a disabled criterion gets no attrition id at all")

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
ok(!grepl(paste("INNER JOIN", sql_view(CFG, "overall_cohort")), pld, fixed = TRUE) &&
    grepl(paste("LEFT JOIN",  sql_view(CFG, "overall_cohort")), pld, fixed = TRUE),
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
section("execution path (Phase 2 fixes)")

# A temp view must NEVER be schema-qualified -- Databricks rejects it outright,
# and the legacy pipeline gets this right (db_utils.R:60 returns the bare name).
# Every CREATE across a full plan is checked, not a sample.
creates <- unlist(regmatches(
  vapply(plan$steps, `[[`, character(1), "sql"),
  gregexpr("CREATE OR REPLACE (TEMPORARY VIEW|TABLE) [^ \n]+",
           vapply(plan$steps, `[[`, character(1), "sql"))))
tmp_views <- grep("TEMPORARY VIEW", creates, value = TRUE)
tables    <- grep("REPLACE TABLE",  creates, value = TRUE)
ok(length(tmp_views) > 0L && !any(grepl("\\.", sub(".*VIEW ", "", tmp_views))),
   "no temp view is schema-qualified")
ok(length(tables) > 0L && all(grepl("\\.", sub(".*TABLE ", "", tables))),
   "every persisted table IS schema-qualified")
ok(identical(sql_view(CFG, "pld"), "coh_pld") &&
   grepl("^hive|^wk\\.|\\.", sql_table(CFG, "pld")),
   "sql_view() and sql_table() differ exactly in qualification")

# The union must be a real TABLE: the LOT build is a separate process and a
# session-scoped view dies with the connection that created it.
u_sql <- plan$steps[[which(step_names == "index_union")]]$sql
ok(grepl("^CREATE OR REPLACE TABLE", u_sql),
   "coh_index_union is a persisted table, not a temp view")
ok(all(grepl("^CREATE OR REPLACE TABLE",
             vapply(plan$steps[grepl("_index_sel$", step_names)], `[[`,
                    character(1), "sql"))),
   "the per-cohort index selections are persisted too")
# INPUT_COHORT_TABLE is consumed as wrk(<name>) by 02_lot1.R:278, so the name
# handed over must be UNqualified.
ok(!grepl("\\.", sql_table_short(CFG, "index_union")),
   "the name given to INPUT_COHORT_TABLE is unqualified, as the LOT build expects")

# --index-only must not demand the table the NEXT stage creates.
idx_only_sql <- vapply(plan$steps[seq_len(which(step_names == "index_union"))],
                       `[[`, character(1), "sql")
ok(!("lot1_flags" %in% names(sources_to_check(R, CFG, idx_only_sql))),
   "--index-only does not preflight LOT1_FLAGS_ALL (the stage after it makes it)")
ok("index_flags" %in% names(sources_to_check(R, CFG, idx_only_sql)),
   "--index-only still preflights the flag table it does read")
ok("lot1_flags" %in% names(sources_to_check(R, CFG,
     vapply(plan$steps, `[[`, character(1), "sql"))),
   "a full run does preflight LOT1_FLAGS_ALL")
ok(identical(names(sources_to_check(R, CFG, NULL)),
             names(Filter(length, required_source_cols(R)))),
   "with no plan supplied, every source with required columns is checked")

ok(isTRUE(parse_args("--rebuild-index")$rebuild_index) &&
   !isTRUE(parse_args(character(0))$rebuild_index),
   "--rebuild-index is parsed, and off by default")

# ---- one index per PATID (Phase 3) ------------------------------------------
# LOT_LONG is keyed by (PATID, LOT_NUM) and carries no INDEX_DATE, so two index
# dates for one patient cannot be represented downstream. The run must be
# REJECTED rather than fan out. Only the wiring is testable offline -- whether
# any patient actually diverges is a fact about data.
u_step <- plan$steps[[which(step_names == "index_union")]]
ok(!is.null(u_step$check), "the union step carries a check")
ok(identical(u_step$check$column, "n_diverging") &&
   grepl("count(DISTINCT INDEX_DATE) > 1", u_step$check$sql, fixed = TRUE) &&
   grepl("GROUP BY PATID", u_step$check$sql, fixed = TRUE),
   "the check counts patients holding more than one index date")
ok(grepl(sql_table(CFG, "index_union"), u_step$check$sql, fixed = TRUE),
   "it checks the union table the LOT build will actually read")
ok(grepl("cannot represent", u_step$check$message, fixed = TRUE) &&
   grepl("separate runs", u_step$check$message, fixed = TRUE),
   "the failure message says why, and what to do instead")
# No other step should silently depend on the pair being a key.
ok(!any(vapply(plan$steps, function(st)
          grepl("count(DISTINCT INDEX_DATE)", st$sql, fixed = TRUE), logical(1))),
   "no build step tries to handle multiple indexes itself")
# A single-cohort run cannot diverge -- rn = 1 guarantees one row per patient --
# but the check is cheap and stays, so the invariant is verified either way.
solo_u <- build_plan(list(ndmm = R$ndmm), CFG)$steps
solo_u <- solo_u[[which(vapply(solo_u, `[[`, character(1), "name") == "index_union")]]
ok(!is.null(solo_u$check),
   "a single-cohort run still verifies one index per PATID")

# ---- criterion provenance (Phase 4) -----------------------------------------
# A flag whose criterion never ran passes EVERY patient, which in the data is
# indistinguishable from a criterion that excluded nobody. LOT1_FLAGS_RUN
# records which ran; unevaluated_gates() is the pure decision, so it is testable
# without a warehouse.
meta_all_ok <- data.frame(
  criterion = c("belantamab", "prior_mm_tx", "other_cancer", "pregnancy"),
  evaluated = c(TRUE, TRUE, TRUE, TRUE), stringsAsFactors = FALSE)
ok(identical(unevaluated_gates(R, meta_all_ok), character(0)),
   "nothing is flagged when every criterion was evaluated")

meta_skipped <- transform(meta_all_ok,
  evaluated = c(TRUE, FALSE, TRUE, FALSE))       # prior_mm_tx + pregnancy skipped
bad <- unevaluated_gates(R, meta_skipped)
ok(setequal(bad, c("no_prior_mm_tx", "no_pregnancy_study")),
   "a skipped criterion is traced back to the gate(s) that apply it")
ok(identical(unevaluated_gates(list(overall = R$overall), meta_skipped),
             character(0)),
   "Overall is unaffected -- it applies no LOT1-anchored criterion")
ok(identical(unevaluated_gates(R, NULL), character(0)) &&
   identical(unevaluated_gates(R, meta_all_ok[0, ]), character(0)),
   "absent metadata yields no false positives (it warns elsewhere, not errors)")

# Only the four skippable criteria carry a `criterion` key; the rest cannot be
# skipped, so claiming otherwise would be a false alarm.
crit <- vapply(REG, function(g) g$criterion %||% NA_character_, character(1))
ok(setequal(unname(crit[!is.na(crit)]),
            c("belantamab", "prior_mm_tx", "other_cancer", "pregnancy")),
   "exactly the four source-dependent criteria are marked skippable")
ok(all(vapply(REG[!is.na(crit)], function(g) identical(g$anchor, "lot1"), logical(1))),
   "all of them are LOT1-anchored (the index flags are built with the cohort)")

# ---- legacy-name compatibility (Phase 5) ------------------------------------
# Renaming the PERSISTED table broke consumers that read it by name in the
# warehouse; the NDMM_* aliases in the dashboard are R variables and do nothing
# for them. Asserted against the real consumer files, so this fails if either
# starts reading a column the view does not carry.
APR <- file.path(dirname(ROOT), "apr_30_2026")
lf  <- paste(readLines(file.path(ROOT, "ndmm", "lot1_flags.R")), collapse = "\n")

ok(grepl('LOT1_COMPAT_TBL <- Sys.getenv("LOT1_COMPAT_TABLE", unset = "NDMM_FLAGS_ALL")',
         lf, fixed = TRUE),
   "the pre-rename name is republished as NDMM_FLAGS_ALL")
ok(grepl("CREATE OR REPLACE VIEW {target} AS SELECT * FROM {src}", lf, fixed = TRUE),
   "it is a VIEW over the current flag table, so consumers stay current")

# Every column the known consumers select must be declared required.
consumers <- c(file.path(APR, "poma_studyteam_qs.R"),
               file.path(dirname(ROOT), "cohort_explorer", "warehouse",
                         "08_analytic_cohort.R"))
used <- unique(unlist(lapply(consumers, function(f) {
  if (!file.exists(f)) return(character(0))
  txt <- paste(readLines(f, warn = FALSE), collapse = "\n")
  unlist(regmatches(txt, gregexpr(
    "\\b(NO_[A-Z_]+|CE_pre_lot1_12mo|CE_lot1_3mo_fu)\\b", txt)))
})))
# NB: run gregexpr on the EXTRACTED block, not on lf -- regmatches must be
# given the same string the match positions came from.
blk <- regmatches(lf, regexpr("LOT1_COMPAT_REQUIRED <- c\\([^)]*\\)", lf))
req <- gsub('"', "", regmatches(blk, gregexpr('"[A-Za-z0-9_]+"', blk))[[1]])
ok(length(used) > 0L && all(used %in% req),
   paste0("every column the legacy consumers read is required by the view (",
          paste(setdiff(used, req), collapse = ", "), ")"))
ok("PATID" %in% req, "PATID is required (both consumers join on it)")

# Dropping someone else's table is not a default.
ok(grepl("replace_table = FALSE", lf, fixed = TRUE),
   "replacing a physical legacy table is opt-in, not the default")
ok(grepl("already exists as a physical TABLE", lf, fixed = TRUE) &&
   grepl("format(nrows, big.mark", lf, fixed = TRUE) &&
   grepl("LOT1_REPLACE_LEGACY_TABLE=TRUE", lf, fixed = TRUE),
   "it reports what is there (row count) and how to proceed, rather than dropping silently")
ok(grepl("DROP TABLE IF EXISTS", lf, fixed = TRUE) &&
   grepl('if (identical(kind, "TABLE")) {', lf, fixed = TRUE),
   "a drop only happens on the explicitly-allowed path")

# apr_30_2026 is untouched, so the dashboard still writes NDMM_FLAGS_ALL itself,
# exactly as it always did -- legacy consumers are unaffected on that path and
# need nothing from this folder. The compat view matters only when THIS folder's
# stage is used INSTEAD of the dashboard, and it must never clobber a table the
# dashboard wrote.
dash <- paste(readLines(file.path(APR, "06_ndmm_dashboard.R")), collapse = "\n")
stg  <- paste(readLines(file.path(ROOT, "ndmm", "build_lot1_flags.R")), collapse = "\n")
ok(!grepl("write_lot1_compat_view", dash, fixed = TRUE),
   "the dashboard does NOT call into this folder (it is untouched)")
ok(grepl("NDMM_FLAGS_ALL", dash, fixed = TRUE),
   "the dashboard still writes the legacy name itself, as it always did")
ok(grepl("write_lot1_compat_view", stg, fixed = TRUE),
   "only this folder's stage publishes the compatibility view")
ok(grepl("replace_table = FALSE", lf, fixed = TRUE),
   "and it refuses to clobber a physical table the dashboard may have written")

# ---- the warehouse verifier (Phase 6) ---------------------------------------
# Everything else in tests/ compares SQL TEXT. This is the script that compares
# PATIENTS, so its shape is worth locking down even though running it needs a
# warehouse.
VERIFY <- file.path(ROOT, "tests", "verify_against_legacy.R")
ok(file.exists(VERIFY), "the warehouse verifier exists")
vf <- paste(readLines(VERIFY), collapse = "\n")

ok(grepl("EXCEPT", vf, fixed = TRUE), "it uses EXCEPT")
ok(grepl("in NEW but not OLD", vf, fixed = TRUE) &&
   grepl("in OLD but not NEW", vf, fixed = TRUE),
   "BOTH directions -- one alone proves nothing about set equality")
# A count check would pass two different cohorts of the same size. Make sure the
# pass condition is emptiness, not a count comparison.
ok(!grepl("count(*) AS n_a", vf, fixed = TRUE) &&
   grepl("except_sql", vf, fixed = TRUE),
   "the pass condition is an empty difference, not matching counts")
ok(grepl("quit(status = 1L)", vf, fixed = TRUE),
   "it exits non-zero on any difference, so it is usable as a release gate")
ok(grepl("ELIG_COH_FINAL", vf, fixed = TRUE) &&
   grepl("index_union", vf, fixed = TRUE) &&
   grepl("ndmm_cohort", vf, fixed = TRUE),
   "it compares Overall, the LOT build input, and NDMM")
# The legacy NDMM set must be DERIVED from the spec, not hardcoded, or it drifts
# the moment a gate changes and silently compares the cohort to itself.
ok(grepl("active_gates(spec)", vf, fixed = TRUE),
   "the legacy NDMM filter is derived from the spec's own LOT1 gates")
ok(grepl("_ndmm_patids is a temp view", vf, fixed = TRUE),
   "it says why the legacy NDMM set has to be reconstructed at all")

# =============================================================================
section("attrition funnel")

af <- plan$attrition$ndmm
ok(length(gregexpr("UNION ALL", af, fixed = TRUE)[[1]]) ==
     length(active_gates(R$ndmm)),
   "the funnel has one arm per APPLIED gate plus a terminal FINAL arm")
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
ok(all(c("CE_b", "CE_f", "MM_FU_agents", "MM_bl_agents", "AGE_INDEX_YR") %in%
       need$index_flags),
   "every APPLIED criterion's column is collected for the schema guard")
# The guard must not demand columns for criteria the configuration disabled --
# that would fail a run over a criterion nobody is applying.
ok(!any(c("CLINTRIAL_FOLLOWUP", "OTHER_MALIGN_FLAG", "PREGNANT_FLAG") %in%
        need$index_flags),
   "no column is required for a disabled criterion")
ok(all(c("NO_BELANTAMAB", "CE_pre_lot1_12mo", "LOT1_START_DT") %in% need$lot1_flags),
   "LOT1 flag columns are collected for the schema guard")
need_ov <- required_source_cols(list(overall = SPECS$overall))
ok(length(need_ov$lot1_flags) == 0L,
   "an Overall-only run requires no LOT1 columns at all")

# =============================================================================


res <- test_summary("engine")
if (res[["fail"]] > 0L) quit(status = 1L)
