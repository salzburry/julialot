#!/usr/bin/env Rscript
# =============================================================================
# test_equivalence.R -- do the new cohorts do the same thing as the old?
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
section("2. Overall's IE criteria == build_criteria_catalog() + step 24")

# --- extract the catalog's filter_sql, in declaration order -------------------
ca  <- readLines(file.path(APR, "R", "criteria_attrition.R"))
i   <- grep("build_criteria_catalog <- function", ca)[1]
j   <- grep("^\\}", ca); j <- j[j > i][1]
blk <- ca[i:j]
raw <- regmatches(blk, regexpr("filter_sql\\s*=\\s*(glue\\()?\"[^\"]*\"", blk))
cat_sql <- sub(".*\"(.*)\"$", "\\1", raw)
cat_sql <- gsub("\\{cfg\\$min_age\\}", CFG$min_age, cat_sql)

# --- the step-1 index gate, inline in step 24 ---------------------------------
ps  <- readLines(file.path(APR, "R", "pipeline_steps.R"))
k   <- grep("24_ELIG_COH_FINAL", ps)[1]; s24 <- ps[k:(k + 30)]
step1 <- grep("inpt_qual", s24, value = TRUE)[1]
step1 <- gsub("\\{cfg\\$outpatient_window\\}", CFG$outpatient_window, step1)

old_overall <- norm(c(step1, cat_sql))
new_overall <- norm(vapply(OV$resolved_gates, `[[`, character(1), "predicate"))

ok(length(old_overall) == length(new_overall),
   sprintf("same number of criteria (old %d, new %d)",
           length(old_overall), length(new_overall)))
ok(identical(old_overall, new_overall),
   "every Overall predicate matches the production catalog, in the same order")
if (!identical(old_overall, new_overall)) {
  n <- max(length(old_overall), length(new_overall))
  for (x in seq_len(n)) {
    a <- if (x <= length(old_overall)) old_overall[x] else "<none>"
    b <- if (x <= length(new_overall)) new_overall[x] else "<none>"
    if (!identical(a, b)) cat("      old: ", a, "\n      new: ", b, "\n", sep = "")
  }
}

# --- the index-selection rule -------------------------------------------------
sel <- sql_index_sel(OV, CFG)
ok(any(grepl("row_number() OVER (PARTITION BY PATID ORDER BY INDEX_DATE)", s24,
             fixed = TRUE)) &&
   grepl("row_number() OVER (PARTITION BY PATID ORDER BY INDEX_DATE)", sel,
         fixed = TRUE),
   "same earliest-index window function as step 24")
ok(any(grepl("WHERE rn = 1", s24, fixed = TRUE)) &&
   grepl("WHERE rn = 1", sel, fixed = TRUE),
   "same rn = 1 selection as step 24")
# Filter-THEN-rank, not rank-then-filter: a patient whose earliest candidate
# index fails IE may still enter on a later one. Getting this backwards would
# change the cohort without changing a single criterion.
ok(regexpr("WHERE 1 = 1", sel, fixed = TRUE) <
   regexpr("row_number()", sel, fixed = TRUE),
   "criteria are applied BEFORE the ranking, as step 24 does")

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
