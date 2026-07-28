#!/usr/bin/env Rscript
# =============================================================================
# test_equivalence.R -- do the new cohorts do the same thing as the old?
#
#   PARTIALLY SOUND. Section 2 now calls the production build_criteria_sql()
#   with the project configuration loaded, so it compares against the cohort the
#   repo actually builds (REVIEW_FINDINGS.md finding 1 -- fixed).
#
#   STILL WEAK, and still open: section 3's setequal() cannot see funnel-order
#   changes, and section 4 compares token SETS, discarding order and
#   multiplicity. REVIEW_FINDINGS.md finding 6. Findings 2-5 are untouched.
# -----------------------------------------------------------------------------
#   Rscript "Jul 28/tests/test_equivalence.R"
#
# Every expectation here is DERIVED FROM THE PRODUCTION SOURCE, not hardcoded.
# The criteria are read out of criteria_attrition.R, pipeline_steps.R and the
# pre-change 06_ndmm_dashboard.R (via git), then compared to what this folder
# generates. If someone edits an IE criterion upstream, this suite fails --
# which is the point. A test that hardcodes the answer proves nothing about the
# thing it claims to be checking.
#
# ---------------------------------------------------------------------------
# WHAT THIS CAN AND CANNOT PROVE
# ---------------------------------------------------------------------------
# CAN (statically, here):  the IE predicates are the same text, in the same
#                          order, with the same index-selection rule; the LOT
#                          build files are byte-identical; the lifted flag SQL
#                          differs only in the two documented ways.
# CANNOT (needs the warehouse): that the two produce the same PATIENT COUNTS.
#                          Same SQL on the same inputs must, but "must" is not
#                          "did". PLAN.md section 5 is the row-count gate:
#                            coh_overall_cohort == ELIG_COH_FINAL
#                            coh_ndmm_cohort    == _ndmm_patids
#                          Until that runs, this suite is a strong static
#                          argument, not an empirical result.
# =============================================================================

.here <- local({
  fa <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (!length(fa)) getwd()
  else dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", fa[1]), fixed = TRUE)))
})
source(file.path(.here, "harness.R"))
ROOT <- test_bootstrap(.here)
REPO <- dirname(ROOT)
APR  <- file.path(REPO, "apr_30_2026")

# The commit this work branched from -- the "old" side of every comparison.
BASE <- Sys.getenv("EQUIV_BASE", unset = "f6b8873")

SPECS <- cohort_specs()
OV <- resolve_spec(SPECS$overall, cfg = CFG)
ND <- bind_lot1_aliases(resolve_spec(SPECS$ndmm, cfg = CFG))

# ---- helpers ----------------------------------------------------------------
git_show <- function(path) {
  out <- suppressWarnings(system2("git", c("-C", shQuote(REPO), "show",
                                           paste0(BASE, ":", path)),
                                  stdout = TRUE, stderr = FALSE))
  if (!length(out)) stop("cannot read ", path, " at ", BASE, call. = FALSE)
  out
}
# Normalize a SQL predicate for comparison: drop the table alias, collapse
# whitespace, drop a leading AND. Comparison is on MEANING-BEARING TEXT, so a
# reformatting is fine but a changed column or operator is not.
norm <- function(x) {
  x <- gsub("\\b[a-z0-9_]+\\.", "", x)      # alias prefixes (f. n. l1. s.)
  x <- gsub("^\\s*AND\\s+", "", x)
  # unname: vapply over the gate list carries gate ids as names, and identical()
  # compares names too -- without this, two identical predicate lists compare
  # unequal and the failure output prints two strings that look the same.
  unname(trimws(gsub("\\s+", " ", x)))
}
have_git <- identical(system2("git", c("-C", shQuote(REPO), "cat-file", "-e",
                                       paste0(BASE, "^{commit}")),
                              stdout = FALSE, stderr = FALSE), 0L)

# =============================================================================
section("1. the LOT rules are untouched")
# The strongest possible statement about "LOT rules unchanged": the files are
# byte-identical to the baseline, so there is nothing to reason about.
LOT_FILES <- c("02_lot1.R", "03_lot2_5.R", "R/lot2_5_base.R", "R/lot2_5_inputs.R",
               "R/config_lot.R", "R/codelists_lot.R", "R/db_utils_lot.R")
COHORT_FILES <- c("01_cohort.R", "R/pipeline_steps.R", "R/criteria_attrition.R",
                  "R/config_prompts.R", "R/codelists.R", "R/db_utils.R")
if (!have_git) {
  ok(FALSE, paste0("baseline commit ", BASE, " is reachable (set EQUIV_BASE)"))
} else {
  for (f in c(LOT_FILES, COHORT_FILES)) {
    rc <- system2("git", c("-C", shQuote(REPO), "diff", "--quiet", BASE, "--",
                           shQuote(file.path("apr_30_2026", f))),
                  stdout = FALSE, stderr = FALSE)
    ok(identical(rc, 0L), paste0("unchanged since ", BASE, ": ", f))
  }
}
# The LOT build's ONLY change is which table it reads, and that was already a
# config knob -- so "the LOT rules are the same" is a fact about the code, not a
# promise about a rewrite.
cl <- readLines(file.path(APR, "R", "config_lot.R"))
ok(any(grepl('input_cohort_table\\s*=\\s*Sys.getenv\\("INPUT_COHORT_TABLE"', cl)),
   "the LOT input is a pre-existing env knob (INPUT_COHORT_TABLE), not a new edit")
ok(any(grepl('unset\\s*=\\s*"ELIG_COH_FINAL"', cl)),
   "its default is still ELIG_COH_FINAL, so an unconfigured run is unchanged")

# =============================================================================
section("2. Overall's IE criteria == build_criteria_sql() under the real config")

# Derived by CALLING the production functions, not by parsing them. The catalog
# lists every possible criterion; build_criteria_sql() decides which are applied
# (`if (isTRUE(cfg[[cr$cfg_key]]))`), and pipeline_inputs.csv ships four FALSE.
# Reading the catalog and ignoring cfg_key -- what this section used to do --
# validated against a configuration nobody runs.
glue <- function(..., .envir = parent.frame()) {   # stub: no CRAN here
  x <- paste0(...)
  repeat {
    m <- regexpr("\\{[^{}]*\\}", x); if (m == -1L) break
    len <- attr(m, "match.length")
    v <- paste(as.character(eval(parse(text = substr(x, m + 1L, m + len - 2L)),
                                 envir = .envir)), collapse = "")
    x <- paste0(substr(x, 1L, m - 1L), v, substr(x, m + len, nchar(x)))
  }
  x
}
# Source into an ISOLATED env and lift out only the two functions we call.
# criteria_attrition.R:212 defines its own `%||%` (empty-string-aware), which
# would otherwise shadow the engine's null-coalescing one and break
# active_gates(). Importing the whole file is not worth that.
.prod <- new.env(parent = globalenv())
local({ glue <- glue; sys.source(file.path(APR, "R", "criteria_attrition.R"), envir = .prod) })
environment(.prod$build_criteria_catalog) <- list2env(list(glue = glue),
                                                      parent = globalenv())
build_criteria_catalog <- .prod$build_criteria_catalog
build_criteria_sql     <- .prod$build_criteria_sql

PCFG <- load_cfg()          # loads pipeline_inputs.csv, then env, then defaults
OVC  <- resolve_spec(SPECS$overall, cfg = PCFG)
NDC  <- bind_lot1_aliases(resolve_spec(SPECS$ndmm, cfg = PCFG))

ok(identical(PCFG$outpatient_window, 90L),
   sprintf("the configured outpatient window is used (%d, not 60)",
           PCFG$outpatient_window))

# The four the project ships OFF, with the reason recorded in the CSV: the
# parent runs to Step 6 and NDMM re-applies these at the LOT1/study anchor.
OFF <- c("apply_baseline_mm_excl", "apply_other_malig_excl",
         "apply_pregnancy_excl", "apply_clintrial_excl")
for (k in OFF)
  ok(isTRUE(!isTRUE(PCFG[[k]])), paste0("configuration has ", k, " OFF"))
for (k in c("apply_age_incl", "apply_ce_b_incl", "apply_ce_f_incl",
            "apply_no_bl_agents_incl", "apply_fu_agents_incl"))
  ok(isTRUE(PCFG[[k]]), paste0("configuration has ", k, " ON"))

# --- what the pipeline would actually put in step 24's WHERE ------------------
applied <- build_criteria_sql(build_criteria_catalog(PCFG), PCFG)
applied <- trimws(strsplit(applied, "\n", fixed = TRUE)[[1]])
applied <- applied[nzchar(applied)]

ps    <- readLines(file.path(APR, "R", "pipeline_steps.R"))
k24   <- grep("24_ELIG_COH_FINAL", ps)[1]; s24 <- ps[k24:(k24 + 30)]
step1 <- gsub("\\{cfg\\$outpatient_window\\}", PCFG$outpatient_window,
              grep("inpt_qual", s24, value = TRUE)[1])

old_overall <- norm(c(step1, applied))
new_overall <- norm(vapply(active_gates(OVC), `[[`, character(1), "predicate"))

ok(length(old_overall) == length(new_overall),
   sprintf("same number of APPLIED criteria (pipeline %d, spec %d)",
           length(old_overall), length(new_overall)))
ok(identical(old_overall, new_overall),
   "every applied Overall predicate matches build_criteria_sql(), in order")
if (!identical(old_overall, new_overall))
  for (x in seq_len(max(length(old_overall), length(new_overall))))
    cat("      pipeline: ", if (x <= length(old_overall)) old_overall[x] else "<none>",
        "\n      spec    : ", if (x <= length(new_overall)) new_overall[x] else "<none>",
        "\n", sep = "")

# The disabled criteria must be DECLARED but not APPLIED -- still PLD columns,
# just not AND-ed into membership. That is what makes them a config decision.
declared <- vapply(OVC$resolved_gates, `[[`, character(1), "id")
active   <- vapply(active_gates(OVC), `[[`, character(1), "id")
for (g in c("no_baseline_mm_evidence", "no_other_cancer_index",
            "no_pregnancy_index", "no_clintrial")) {
  ok(g %in% declared && !(g %in% active),
     paste0(g, " is declared but not applied"))
}
ok(!any(grepl("OTHER_MALIGN_FLAG|PREGNANT_FLAG|CLINTRIAL|MM_baseline_diag",
              sql_index_sel(OVC, PCFG))),
   "no disabled criterion reaches the generated WHERE clause")
# The schema guard must not demand columns for criteria the config disabled --
# that would fail a run over a criterion nobody is applying.
need_ov <- required_source_cols(list(overall = OVC))$index_flags
ok(!any(c("OTHER_MALIGN_FLAG", "PREGNANT_FLAG", "CLINTRIAL_BASELINE",
          "MM_baseline_diag") %in% need_ov),
   "the schema guard does not require columns for disabled criteria")
ok(all(c("CE_b", "CE_f", "MM_FU_agents", "AGE_INDEX_YR") %in% need_ov),
   "the schema guard still requires every applied criterion's column")

# --- and the same for NDMM: the parent-level exclusions stay off so the -------
# MM-adjacent override at the LOT1 anchor is not pre-empted upstream.
nd_active <- vapply(active_gates(NDC), `[[`, character(1), "id")
ok(!("no_other_cancer_index" %in% nd_active),
   "NDMM does NOT apply the index-anchored other-cancer exclusion")
ok("no_other_cancer_pre_lot1" %in% nd_active,
   "NDMM DOES apply the LOT1-anchored one (where the override lives)")
ok(!("no_pregnancy_index" %in% nd_active) && "no_pregnancy_study" %in% nd_active,
   "NDMM uses the study-period pregnancy scan, not the index-anchored flag")
# pipeline_inputs.csv states TRUE here "breaks the NDMM cohort" -- assert we
# never generate that configuration by accident.
ok(!any(grepl("OTHER_MALIGN_FLAG", sql_index_sel(NDC, PCFG), fixed = TRUE)),
   "NDMM never drops MM-adjacent patients upstream (the documented breakage)")

# --- the index-selection rule -------------------------------------------------
sel <- sql_index_sel(OVC, PCFG)
ok(any(grepl("row_number() OVER (PARTITION BY PATID ORDER BY INDEX_DATE)", s24,
             fixed = TRUE)) &&
   grepl("row_number() OVER (PARTITION BY PATID ORDER BY INDEX_DATE)", sel,
         fixed = TRUE),
   "same earliest-index window function as step 24")
ok(any(grepl("WHERE rn = 1", s24, fixed = TRUE)) &&
   grepl("WHERE rn = 1", sel, fixed = TRUE),
   "same rn = 1 selection as step 24")
ok(regexpr("WHERE 1 = 1", sel, fixed = TRUE) < regexpr("row_number()", sel, fixed = TRUE),
   "criteria are applied BEFORE the ranking, as step 24 does")
ok(grepl("outpt2_90", sel, fixed = TRUE) && !grepl("outpt2_60", sel, fixed = TRUE),
   "the generated SQL uses the configured 90-day outpatient column")

# =============================================================================
section("3. NDMM's IE criteria == the pre-change _ndmm_patids filter")

if (!have_git) {
  ok(FALSE, "baseline commit reachable")
} else {
  old <- git_show("apr_30_2026/06_ndmm_dashboard.R")
  a <- grep("VIEW \\{NDMM_PATIDS\\}", old)[1]
  b <- grep('"\\)\\)', old); b <- b[b > a][1]
  wh <- old[a:b]
  wh <- grep("^\\s*(WHERE|AND)\\s", wh, value = TRUE)
  old_ndmm <- norm(sub("^\\s*WHERE\\s+", "", wh))

  nd_lot1 <- Filter(function(g) identical(g$anchor, "lot1"), ND$resolved_gates)
  new_ndmm <- norm(vapply(nd_lot1, `[[`, character(1), "predicate"))

  # has_lot1 + lot1_from replace what the old code did through
  # NDMM_LOT1_STARTS: an INNER JOIN whose view definition already carried
  # `LOT_START_DT >= NDMM_LOT1_FROM`. Same restriction, expressed as predicates.
  implicit <- c("LOT1_START_DT IS NOT NULL",
                sprintf("LOT1_START_DT >= date('%s')", CFG$lot1_from))
  ok(identical(new_ndmm[1:2], implicit),
     "has_lot1 + lot1_from are the first two LOT1-anchored predicates")
  ok(setequal(setdiff(new_ndmm, implicit), old_ndmm),
     "the remaining NDMM predicates are exactly the old six, unchanged")
  ok(length(setdiff(old_ndmm, new_ndmm)) == 0L,
     "no criterion from the old filter was dropped")

  # The old restriction really was baked into the LOT1 view, not applied loosely.
  l1 <- old[grep("VIEW \\{NDMM_LOT1_STARTS\\}", old)[1] + (0:8)]
  ok(any(grepl("LOT_NUM = 1", l1, fixed = TRUE)) &&
     any(grepl("LOT_START_DT >= date\\('\\{NDMM_LOT1_FROM\\}'\\)", l1)),
     "the old LOT1 view did fuse 'has a 1L' with the cutoff (so splitting is a no-op)")

  # And the dashboard's own selection is unchanged by the lift.
  now <- readLines(file.path(APR, "06_ndmm_dashboard.R"))
  a2 <- grep("VIEW \\{NDMM_PATIDS\\}", now)[1]
  b2 <- grep('"\\)\\)', now); b2 <- b2[b2 > a2][1]
  now_wh <- norm(sub("^\\s*WHERE\\s+", "",
                     grep("^\\s*(WHERE|AND)\\s", now[a2:b2], value = TRUE)))
  ok(identical(sort(now_wh), sort(old_ndmm)),
     "the dashboard still selects NDMM with the identical six-flag filter")
}

# =============================================================================
section("4. the lifted flag SQL is the same SQL")

if (!have_git) {
  ok(FALSE, "baseline commit reachable")
} else {
  old_txt <- paste(git_show("apr_30_2026/06_ndmm_dashboard.R"), collapse = "\n")
  new_txt <- paste(readLines(file.path(APR, "R", "lot1_flags.R")), collapse = "\n")

  # Renames applied when lifting NDMM_* -> LOT1_*. Longest first so
  # NDMM_ENROLL_SPANS_STRICT is not eaten by NDMM_ENROLL_SPANS.
  REN <- c("NDMM_ENROLL_SPANS_STRICT" = "LOT1_ENROLL_SPANS_STRICT",
           "NDMM_ENROLL_SPANS" = "LOT1_ENROLL_SPANS",
           "NDMM_LOT1_STARTS" = "LOT1_STARTS",
           "NDMM_MMA_CODELIST" = "LOT1_MMA_CODELIST",
           "NDMM_THERAPY_PRE_LOT1" = "LOT1_THERAPY_PRE",
           "NDMM_OTHER_MALIG_CODES" = "LOT1_OTHER_MALIG_CODES",
           "NDMM_MED_CLAIM_HEADER" = "LOT1_MED_CLAIM_HEADER",
           "NDMM_CONFINEMENT" = "LOT1_CONFINEMENT",
           "NDMM_OTHER_MALIG_PATIDS" = "LOT1_OTHER_MALIG_PATIDS",
           "NDMM_PREGNANCY_PATIDS" = "LOT1_PREGNANCY_PATIDS",
           "NDMM_PREG_CODES" = "LOT1_PREG_CODES",
           "NDMM_FLAGS_ALL" = "LOT1_FLAGS_ALL",
           "NDMM_PRE_LOT1_DAYS" = "LOT1_PRE_DAYS",
           "NDMM_LOT1_FROM" = "LOT1_FROM",
           "NDMM_STUDY_START" = "LOT1_STUDY_START",
           "NDMM_TBL_MEMBER_ENROLLMENT" = "LOT1_TBL_MEMBER_ENROLLMENT",
           # Generalisation (1): the patient input became a parameter. Treated
           # as a RENAME, so it is accounted for rather than showing up as an
           # unexplained diff.
           "{elig_coh_final}" = "{patient_input}")
  apply_ren <- function(x) { for (k in names(REN)) x <- gsub(k, REN[[k]], x, fixed = TRUE); x }

  # Every CREATE ... VIEW body, comments stripped, whitespace collapsed.
  bodies <- function(txt) {
    m <- gregexpr("CREATE OR REPLACE TEMPORARY VIEW.*?\n\\s*\"\\)", txt)
    b <- regmatches(txt, m)[[1]]
    b <- gsub("--[^\n]*", "", b)
    trimws(gsub("\\s+", " ", b))
  }
  key <- function(x) sub("^CREATE OR REPLACE TEMPORARY VIEW (\\S+).*", "\\1", x)

  ob <- apply_ren(bodies(old_txt)); nb <- bodies(new_txt)
  # Compare only the views the module actually owns, and only the FIRST
  # occurrence of each name (later ones are materialize-and-repoint stubs).
  first <- function(v) v[!duplicated(key(v))]
  ob <- first(ob); nb <- first(nb)
  shared <- intersect(key(nb), key(ob))
  ok(length(shared) >= 8L,
     sprintf("matched %d lifted views against the original", length(shared)))

  # Views expected to be character-identical: no anchor change, no new key.
  IDENTICAL_EXPECTED <- c("{LOT1_MMA_CODELIST}", "{LOT1_OTHER_MALIG_CODES}",
                          "{LOT1_MED_CLAIM_HEADER}", "{LOT1_CONFINEMENT}",
                          "{LOT1_PREG_CODES}")
  for (k in intersect(IDENTICAL_EXPECTED, shared)) {
    o <- ob[match(k, key(ob))]; n <- nb[match(k, key(nb))]
    ok(identical(o, n), paste0("byte-identical SQL: ", k))
  }

  # Views that DID change may only have gained INDEX_DATE keying. Rather than
  # enumerate every token, normalize the way norm() does -- strip alias
  # prefixes and trailing commas -- so what is left is only meaning-bearing.
  # Anything outside ALLOWED is a real change to the criteria and fails.
  tok <- function(x) {
    t <- strsplit(x, " ")[[1]]
    t <- sub(",$", "", t)                    # trailing commas carry no meaning
    t <- gsub("\\b[a-z0-9_]+\\.", "", t)       # alias prefixes (p. l. l1. ec_l1.)
    t[nzchar(t)]
  }
  # Everything generalisation (2) can legitimately introduce: the INDEX_DATE
  # column, the join that attaches it, and the alias/CTE names carrying it.
  ALLOWED <- c("INDEX_DATE", "cast(INDEX_DATE", "cast(PATID", "cast(DEATH_DT",
               "as", "date)", "string)", "AS", "AND", "ON", "=",
               "INNER", "JOIN", "SELECT", "DISTINCT", "FROM", "WITH",
               "PATID", "LOT_NUM", "LOT_START_DT", "(", ")", "1)",
               "{patient_input}", "{LOT1_STARTS}", "{LOT1_PRE_DAYS})",
               "cand", "{win}", "BETWEEN", "date_sub(LOT1_START_DT",
               "l", "p", "u", "ec")
  for (k in setdiff(shared, IDENTICAL_EXPECTED)) {
    o <- tok(ob[match(k, key(ob))]); n <- tok(nb[match(k, key(nb))])
    changed <- setdiff(union(setdiff(o, n), setdiff(n, o)), ALLOWED)
    ok(length(changed) == 0L,
       paste0("only documented changes in ", k,
              if (length(changed)) paste0(" -- UNEXPECTED: ",
                                          paste(changed, collapse = " | ")) else ""))
  }
}

# =============================================================================
section("5. every lifted constant equals the original")

# Compare the R-level constants ELEMENT BY ELEMENT against the pre-change file,
# by EVALUATING both definitions -- not by spot-checking names I typed in.
#
# This section exists because the first version of it did spot-check hardcoded
# names, and missed that LOT1_MM_ADJACENT_OVERRIDE had been reconstructed from
# memory rather than copied: four of its five tumor-group labels were wrong.
#
# The other-cancer exclusion matches on ICD CODES (dx.dx = o.dx, lot1_flags.R:350);
# tumor_group is a label on those code rows that the override uses to pick which
# ICD codes to drop from the exclusion list. Labels matching nothing = those
# codes stay exclusionary = patients wrongly dropped. The pipeline does warn on a
# shortfall at run time ("matched N of 5"), so this was not silent -- but
# catching it here is cheaper than catching it in a run review.
# Extract, evaluate, compare.
if (!have_git) {
  ok(FALSE, "baseline commit reachable")
} else {
  old_lines <- git_show("apr_30_2026/06_ndmm_dashboard.R")
  new_lines <- readLines(file.path(APR, "R", "lot1_flags.R"))

  # Pull `NAME <- <expr>` (possibly multi-line) and evaluate it in an empty env.
  const_value <- function(lines, name) {
    i <- grep(paste0("^", name, "\\s*<-"), lines)
    if (!length(i)) return(NULL)
    i <- i[1]
    for (n in seq(i, min(i + 20, length(lines)))) {
      txt <- paste(lines[i:n], collapse = "\n")
      v <- tryCatch(eval(parse(text = txt), envir = new.env()),
                    error = function(e) NULL)
      if (!is.null(v)) return(v)
    }
    NULL
  }

  # old name -> new name. Every constant the lift carried across.
  CONSTS <- c("NDMM_STEROID_ABBRS"         = "LOT1_STEROID_ABBRS",
              "NDMM_MM_ADJACENT_OVERRIDE"  = "LOT1_MM_ADJACENT_OVERRIDE",
              "NDMM_PRE_LOT1_DAYS"         = "LOT1_PRE_DAYS",
              "NDMM_LOT1_FROM"             = "LOT1_FROM",
              "NDMM_STUDY_START"           = "LOT1_STUDY_START",
              "NDMM_GAP_DAYS"              = "LOT1_GAP_DAYS",
              "NDMM_TBL_CONFINEMENT"       = "LOT1_TBL_CONFINEMENT",
              "NDMM_TBL_MEMBER_ENROLLMENT" = "LOT1_TBL_MEMBER_ENROLLMENT")

  for (o in names(CONSTS)) {
    n  <- CONSTS[[o]]
    ov <- const_value(old_lines, o)
    nv <- const_value(new_lines, n)
    if (is.null(ov) || is.null(nv)) {
      ok(FALSE, paste0("could not evaluate ", o, " / ", n)); next
    }
    same <- identical(as.character(ov), as.character(nv))
    ok(same, paste0(o, " -> ", n, " (", length(ov), " value(s))",
                    if (!same) paste0(
                      " -- OLD: ", paste(setdiff(ov, nv), collapse = " | "),
                      " ;; NEW: ", paste(setdiff(nv, ov), collapse = " | ")) else ""))
  }
}

# --- windows that live inside the SQL rather than in a constant ---------------
lf <- paste(readLines(file.path(APR, "R", "lot1_flags.R")), collapse = "\n")
ok(grepl("date_add\\(ec_l1.LOT1_START_DT, 90\\)", lf),
   "the follow-up CE window is still 90 days")
ok(grepl("op.diff_days <= 30", lf, fixed = TRUE),
   "the other-cancer outpatient pair window is still 30 days")
ok(grepl("MAP_MED_TYPE\\) LIKE 'BEL%'", lf),
   "the belantamab match is still the BEL% prefix on MAP_MED_TYPE")

# =============================================================================
section("6. what is NOT proven here")
# Stated as assertions so it cannot quietly drop out of the report.
ok(TRUE, "STATIC ONLY: identical SQL text, not identical row counts")
ok(TRUE, "the warehouse gate remains: coh_overall_cohort == ELIG_COH_FINAL")
ok(TRUE, "the warehouse gate remains: coh_ndmm_cohort == _ndmm_patids")

res <- test_summary("equivalence")
if (res[["fail"]] > 0L) quit(status = 1L)
