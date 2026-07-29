#!/usr/bin/env Rscript
# =============================================================================
# verify_against_legacy.R -- the check that actually settles equivalence
# -----------------------------------------------------------------------------
#   Rscript "Jul 28/tests/verify_against_legacy.R" --dry-run   # print the SQL
#   DATABRICKS_PWD=... Rscript "Jul 28/tests/verify_against_legacy.R"
#
# Everything else in tests/ compares SQL TEXT. Identical text on identical
# inputs must produce identical rows -- but *must* is not *did*, and the whole
# point of the review was that a green text suite had been cited as if it were
# evidence about patients. This compares PATIENT SETS on the warehouse.
#
# EXCEPT IN BOTH DIRECTIONS, never counts. Two different cohorts of the same
# size pass a count check; A EXCEPT B and B EXCEPT A both empty is set equality.
#
# ---------------------------------------------------------------------------
# WHAT IT COMPARES
# ---------------------------------------------------------------------------
#   coh_overall_cohort   vs  ELIG_COH_FINAL
#       The Overall cohort against the one the legacy pipeline persisted.
#
#   coh_index_union      vs  ELIG_COH_FINAL
#       The LOT build's input. If these differ, every LOT number downstream is
#       computed over a different population and nothing else is comparable.
#
#   coh_ndmm_cohort      vs  the legacy six-flag NDMM filter
#       06_ndmm_dashboard.R's _ndmm_patids is a temp view and is never
#       persisted, so it is reconstructed here from LOT1_FLAGS_ALL using
#       exactly the WHERE clause build_ndmm_patids() applies. That
#       reconstruction is asserted token-for-token against the pre-change
#       dashboard by tests/test_equivalence.R section 3.
#
# A non-empty result in either direction is a FAILURE, reported with the count
# and a sample of PATIDs so it can be chased. Exit status is non-zero, so this
# is usable as a release gate.
#
# ---------------------------------------------------------------------------
# WHAT A PASS DOES AND DOES NOT MEAN
# ---------------------------------------------------------------------------
# A pass means the new selection layer reproduces the legacy cohorts ON THE DATA
# AS IT STANDS. It does not validate the LOT algorithms (unchanged, and asserted
# byte-identical elsewhere), and it does not mean the study definition is right
# -- only that this refactor did not change it.
# =============================================================================

.here <- local({
  fa <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (!length(fa)) getwd()
  else dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", fa[1]), fixed = TRUE)))
})
source(file.path(.here, "harness.R"))
ROOT <- test_bootstrap(.here)
DRY  <- "--dry-run" %in% commandArgs(trailingOnly = TRUE)

cfg   <- load_cfg()
specs <- lapply(cohort_specs(), resolve_spec, cfg = cfg)

# The legacy NDMM definition: build_ndmm_patids()'s WHERE clause, over the
# persisted flag table. Derived from the spec's own LOT1-anchored gates so it
# cannot drift from what the cohort applies -- if a gate is added, this moves
# with it, and the comparison stays honest.
legacy_ndmm_sql <- function(cfg, spec) {
  g <- Filter(function(x) identical(x$anchor, "lot1"), active_gates(spec))
  # has_lot1 / lot1_from live on LOT1_STARTS, the rest on the flag table; the
  # flag table carries LOT1_START_DT too, so both read from it here.
  preds <- gsub("\\b(n|l1)\\.", "f.", vapply(g, `[[`, character(1), "predicate"))
  paste0("SELECT DISTINCT cast(f.PATID as string) AS PATID\n",
         "FROM ", cfg$lot1_flags, " f\n",
         "WHERE 1 = 1\n  AND ", paste(preds, collapse = "\n  AND "))
}

patids <- function(sql) paste0("SELECT DISTINCT cast(PATID as string) AS PATID FROM (\n",
                               sql, "\n)")

COMPARISONS <- list(
  list(name = "overall cohort",
       why  = "the Overall cohort vs the one the legacy pipeline persisted",
       a_label = sql_view(cfg, "overall_cohort"),
       b_label = cfg$index_flags_final,
       a = patids(paste0("SELECT PATID FROM ", sql_view(cfg, "overall_cohort"))),
       b = patids(paste0("SELECT PATID FROM ", cfg$index_flags_final))),

  list(name = "LOT build input",
       why  = "if these differ, every LOT number downstream is over a different population",
       a_label = sql_table(cfg, "index_union"),
       b_label = cfg$index_flags_final,
       a = patids(paste0("SELECT PATID FROM ", sql_table(cfg, "index_union"))),
       b = patids(paste0("SELECT PATID FROM ", cfg$index_flags_final))),

  list(name = "NDMM cohort",
       why  = "vs the legacy six-flag filter, reconstructed from LOT1_FLAGS_ALL",
       a_label = sql_view(cfg, "ndmm_cohort"),
       b_label = paste0("legacy filter over ", cfg$lot1_flags),
       a = patids(paste0("SELECT PATID FROM ", sql_view(cfg, "ndmm_cohort"))),
       b = patids(legacy_ndmm_sql(cfg, specs$ndmm)))
)

except_sql <- function(x, y) paste0("SELECT count(*) AS n FROM (\n", x,
                                    "\n  EXCEPT\n", y, "\n)")
sample_sql <- function(x, y) paste0("SELECT PATID FROM (\n", x, "\n  EXCEPT\n",
                                    y, "\n) LIMIT 10")

# =============================================================================
cat(strrep("=", 74), "\n", sep = "")
cat("VERIFY NEW COHORTS AGAINST THE LEGACY ONES\n")
cat("  work schema : ", cfg$work_schema, "\n", sep = "")
cat("  window      : ", cfg$outpatient_window, "d   1L cutoff ", cfg$lot1_from, "\n", sep = "")
cat(strrep("=", 74), "\n", sep = "")

if (DRY) {
  for (c in COMPARISONS) {
    cat("\n-- [", c$name, "] ", c$why, "\n", sep = "")
    cat("-- new only (must be 0):\n", except_sql(c$a, c$b), ";\n", sep = "")
    cat("-- legacy only (must be 0):\n", except_sql(c$b, c$a), ";\n", sep = "")
  }
  cat("\n-- Both directions must return 0. A count check alone would pass two\n",
      "-- different cohorts that happen to be the same size.\n", sep = "")
  quit(status = 0L)
}

if (!requireNamespace("DBI", quietly = TRUE))
  stop("DBI is required. Use --dry-run to emit the SQL.", call. = FALSE)
con <- connect(cfg)
on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

fails <- 0L
for (c in COMPARISONS) {
  cat("\n", c$name, " -- ", c$why, "\n", sep = "")
  cat("  new: ", c$a_label, "\n  old: ", c$b_label, "\n", sep = "")
  for (d in list(list(lab = "in NEW but not OLD", x = c$a, y = c$b),
                 list(lab = "in OLD but not NEW", x = c$b, y = c$a))) {
    n <- tryCatch(DBI::dbGetQuery(con, except_sql(d$x, d$y))$n[1],
                  error = function(e) { cat("  ERROR: ", conditionMessage(e), "\n", sep = ""); NA })
    if (is.na(n)) { fails <- fails + 1L; next }
    if (n == 0) {
      cat("  ok   ", d$lab, ": 0\n", sep = "")
    } else {
      fails <- fails + 1L
      cat("  FAIL ", d$lab, ": ", format(n, big.mark = ","), "\n", sep = "")
      smp <- tryCatch(DBI::dbGetQuery(con, sample_sql(d$x, d$y))$PATID,
                      error = function(e) character(0))
      if (length(smp)) cat("       sample: ", paste(smp, collapse = ", "), "\n", sep = "")
    }
  }
}

cat("\n", strrep("=", 74), "\n", sep = "")
if (fails == 0L) {
  cat("EQUIVALENT. Every comparison is empty in BOTH directions.\n")
  cat("This is evidence about patients, not about SQL text.\n")
} else {
  cat(fails, " comparison(s) FAILED. The new cohorts do NOT reproduce the legacy\n",
      "ones -- do not ship this until each difference is explained.\n", sep = "")
}
cat(strrep("=", 74), "\n", sep = "")
if (fails > 0L) quit(status = 1L)
