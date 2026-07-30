#!/usr/bin/env Rscript
# =============================================================================
# verify_cohort_overall.R -- THE gate: does this build produce the same PATIENTS?
# -----------------------------------------------------------------------------
#   Rscript "Jul 28/cohort_overall/tests/verify_cohort_overall.R" --dry-run
#   DATABRICKS_PWD=... Rscript "Jul 28/cohort_overall/tests/verify_cohort_overall.R"
#
# Named verify_* so run_all_tests.R's test_*.R glob does NOT pick it up: a suite
# that cannot run offline must not be able to make the runner red for the wrong
# reason, or -- worse -- be quietly skipped and counted as passing.
#
# ---------------------------------------------------------------------------
# WHY THIS SCRIPT EXISTS
# ---------------------------------------------------------------------------
# ../../tests/verify_against_legacy.R compares the SELECTION layer's cohorts
# (coh_overall_cohort, coh_index_union, coh_ndmm_cohort). It never reads anything
# this folder produces. So it could pass in full while this build had failed,
# written nothing, or produced different patients -- and an earlier revision of
# the README nonetheless pointed at it as this folder's validation gate. It was
# not one. This is.
#
# ---------------------------------------------------------------------------
# WHAT IT COMPARES, AND WHY PATID ALONE IS NOT ENOUGH
# ---------------------------------------------------------------------------
#   1 grain          one row per PATID on BOTH sides
#   2 PATID set      EXCEPT in BOTH directions
#   3 (PATID, INDEX_DATE)  EXCEPT in BOTH directions
#   4 key fields     for shared patients: index_source, AGE_INDEX_YR, CE_b, CE_f,
#                    CE_3mosf, MM_bl_agents, MM_FU_agents, MM_baseline_diag,
#                    OTHER_MALIGN_FLAG, PREGNANT_FLAG, CLINTRIAL_*, DEATH_DT,
#                    ENDDATE, FU_DAYS
#   5 attrition      the funnel's own end count vs the cohort table
#
# Check 3 is the one PATID cannot substitute for. Because the criteria are applied
# BEFORE the index date is ranked, the SAME patient can legitimately survive on a
# DIFFERENT index date under a different implementation -- and every LOT number
# downstream is computed from that date. A PATID-only comparison would report full
# agreement while the study's exposure dates had moved.
#
# Check 4 catches the case where both cohorts pick the same patient and the same
# index date from differently-computed flags.
#
# EXCEPT IN BOTH DIRECTIONS, never counts. Two different cohorts of the same size
# pass a count check; A EXCEPT B and B EXCEPT A both empty is set equality.
#
# ---------------------------------------------------------------------------
# WHAT A PASS DOES AND DOES NOT MEAN
# ---------------------------------------------------------------------------
# A pass means this build reproduces the legacy cohort ON THE DATA AS IT STANDS.
# It does not mean the study definition is right -- only that reimplementing it
# did not change it. Both sides share the unknown-care-setting behaviour described
# in steps/00_inputs.R, so agreement here says nothing about that.
# =============================================================================

.here <- local({
  fa <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (!length(fa)) getwd()
  else dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", fa[1]),
                                  fixed = TRUE)))
})
IE_DIR <- dirname(.here)
source(file.path(IE_DIR, "ie_runner.R"))
ie_bootstrap(IE_DIR)

DRY <- "--dry-run" %in% commandArgs(trailingOnly = TRUE)
cfg <- ie_cfg(IE_DIR)
h   <- ie_names(cfg)
fun <- ie_funnel(cfg, h)

NEW <- h$work(cfg$final_table_name)
# The legacy persisted cohort: same name the LOT build reads. In the legacy
# pipeline it lands in personal_schema; fall back to the output schema.
OLD <- local({
  s <- Sys.getenv("LEGACY_COHORT_TABLE", unset = "")
  if (nzchar(s)) return(s)
  sch <- if (nzchar(cfg$personal_schema)) cfg$personal_schema else cfg$out_schema
  h$full_name(sch, cfg$final_table_name)
})

KEY_FIELDS <- c("index_source", "AGE_INDEX_YR", "CE_b", "CE_f", "CE_3mosf",
                "MM_bl_agents", "MM_FU_agents", "MM_baseline_diag",
                "OTHER_MALIGN_FLAG", "PREGNANT_FLAG", "CLINTRIAL_BASELINE",
                "CLINTRIAL_FOLLOWUP", "DEATH_DT", "ENDDATE", "FU_DAYS")

pat  <- function(t) paste0("SELECT DISTINCT cast(PATID as string) AS PATID FROM ", t)
pidx <- function(t) paste0("SELECT DISTINCT cast(PATID as string) AS PATID,",
                           " cast(INDEX_DATE as string) AS INDEX_DATE FROM ", t)
except_n <- function(x, y) paste0("SELECT count(*) AS n FROM (\n", x,
                                  "\n  EXCEPT\n", y, "\n)")
except_s <- function(x, y) paste0("SELECT * FROM (\n", x, "\n  EXCEPT\n", y,
                                  "\n) LIMIT 10")

grain_sql <- function(t) paste0(
  "SELECT count(*) AS n_rows, count(DISTINCT PATID) AS n_pat FROM ", t)

# Field-by-field disagreement over the patients BOTH sides selected on the SAME
# index date. Null-safe (`<=>`), so a NULL on both sides counts as agreement
# rather than as a difference.
fields_sql <- function() {
  cmp <- paste0("sum(CASE WHEN NOT (a.", KEY_FIELDS, " <=> b.", KEY_FIELDS,
                ") THEN 1 ELSE 0 END) AS d_", tolower(KEY_FIELDS),
                collapse = ",\n  ")
  paste0("SELECT count(*) AS n_compared,\n  ", cmp, "\n",
         "FROM ", NEW, " a JOIN ", OLD, " b\n",
         "  ON a.PATID = b.PATID AND a.INDEX_DATE = b.INDEX_DATE")
}

COMPARISONS <- list(
  list(name = "PATID set", why = "who is in the cohort",
       a = pat(NEW), b = pat(OLD)),
  list(name = "(PATID, INDEX_DATE)",
       why = "filter-then-rank can move a surviving patient to a different index",
       a = pidx(NEW), b = pidx(OLD))
)

cat(strrep("=", 78), "\n", sep = "")
cat("VERIFY COHORT OVERALL AGAINST THE LEGACY COHORT\n")
cat("  new : ", NEW, "\n", sep = "")
cat("  old : ", OLD, "\n", sep = "")
cat("  window ", cfg$outpatient_window, "d   study ", cfg$study_start, " .. ",
    cfg$study_end, "   baseline ", cfg$baseline_days, "d\n", sep = "")
cat(strrep("=", 78), "\n", sep = "")

if (DRY) {
  for (c in COMPARISONS) {
    cat("\n-- [", c$name, "] ", c$why, "\n", sep = "")
    cat("-- new only (must be 0):\n", except_n(c$a, c$b), ";\n", sep = "")
    cat("-- old only (must be 0):\n", except_n(c$b, c$a), ";\n", sep = "")
  }
  cat("\n-- grain (n_rows must equal n_pat on both sides):\n")
  cat(grain_sql(NEW), ";\n", grain_sql(OLD), ";\n", sep = "")
  cat("\n-- key fields over shared (PATID, INDEX_DATE) -- every d_* must be 0:\n")
  cat(fields_sql(), ";\n", sep = "")
  cat("\n-- Both directions must be 0. A count check alone would pass two\n",
      "-- different cohorts that happen to be the same size.\n", sep = "")
  quit(status = 0L)
}

if (!requireNamespace("DBI", quietly = TRUE))
  stop("DBI is required. Use --dry-run to emit the SQL.", call. = FALSE)
ie_load_plumbing(cfg)
con <- ie_connect(cfg)
on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

fails <- 0L
say <- function(ok, lab, detail) {
  if (!ok) fails <<- fails + 1L
  cat(sprintf("  %-4s %-46s %s\n", if (ok) "ok" else "FAIL", lab, detail))
}

cat("\ngrain\n")
for (t in c(NEW, OLD)) {
  g <- tryCatch(DBI::dbGetQuery(con, grain_sql(t)),
                error = function(e) { cat("  ERROR ", t, ": ",
                                          conditionMessage(e), "\n", sep = ""); NULL })
  if (is.null(g)) { fails <- fails + 1L; next }
  say(g$n_rows[1] == g$n_pat[1], paste0("one row per PATID in ", t),
      paste0(format(g$n_rows[1], big.mark = ","), " rows / ",
             format(g$n_pat[1], big.mark = ","), " patients"))
}

for (c in COMPARISONS) {
  cat("\n", c$name, " -- ", c$why, "\n", sep = "")
  for (d in list(list(lab = "in NEW but not OLD", x = c$a, y = c$b),
                 list(lab = "in OLD but not NEW", x = c$b, y = c$a))) {
    n <- tryCatch(DBI::dbGetQuery(con, except_n(d$x, d$y))$n[1],
                  error = function(e) { cat("  ERROR: ", conditionMessage(e),
                                            "\n", sep = ""); NA })
    if (is.na(n)) { fails <- fails + 1L; next }
    say(n == 0, d$lab, format(n, big.mark = ","))
    if (n > 0) {
      smp <- tryCatch(DBI::dbGetQuery(con, except_s(d$x, d$y)),
                      error = function(e) NULL)
      if (!is.null(smp) && nrow(smp))
        cat("       sample: ",
            paste(apply(smp, 1, paste, collapse = "/"), collapse = ", "),
            "\n", sep = "")
    }
  }
}

cat("\nkey fields over shared (PATID, INDEX_DATE)\n")
fv <- tryCatch(DBI::dbGetQuery(con, fields_sql()),
               error = function(e) { cat("  ERROR: ", conditionMessage(e),
                                         "\n", sep = ""); NULL })
if (is.null(fv)) {
  fails <- fails + 1L
} else {
  cat("  ", format(fv$n_compared[1], big.mark = ","),
      " shared (PATID, INDEX_DATE) pair(s)\n", sep = "")
  for (f in KEY_FIELDS) {
    n <- fv[[paste0("d_", tolower(f))]][1]
    say(n == 0, paste0(f, " agrees"), format(n, big.mark = ","))
  }
}

cat("\nfunnel reconciliation\n")
rows <- tryCatch(ie_attrition_rows(con, fun), error = function(e) NULL)
if (is.null(rows)) {
  cat("  ERROR: could not compute the funnel (is the flags table built?)\n")
  fails <- fails + 1L
} else {
  rec <- ie_reconcile(con, fun, attr(rows, "cum_where"))
  for (r in rec) say(r$ok, r$name, r$detail)
}

cat("\n", strrep("=", 78), "\n", sep = "")
if (fails == 0L) {
  cat("EQUIVALENT. Same patients, same index dates, same key fields, both\n",
      "directions, and the cohort table reconciles with its own funnel.\n",
      "This is evidence about patients, not about SQL text.\n", sep = "")
} else {
  cat(fails, " check(s) FAILED. This build does NOT reproduce the legacy cohort",
      "\n-- do not ship or quote it until each difference is explained.\n",
      sep = "")
}
cat(strrep("=", 78), "\n", sep = "")
if (fails > 0L) quit(status = 1L)
