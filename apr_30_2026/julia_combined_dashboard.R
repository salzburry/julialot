#!/usr/bin/env Rscript
# Julia June 5 - ONE combined dashboard for both cohorts + exploratory.
#
#   Rscript apr_30_2026/julia_combined_dashboard.R
#
# Output: julia_combined_dashboard.html in cfg$output_dir.
#
# The two standalone dashboards still build exactly as before:
#   Rscript apr_30_2026/julia_q1_q3.R              -> whole cohort
#   Rscript apr_30_2026/julia_q4_ashley/julia_q4.R -> NDMM cohort
# This script reuses their builders + cohort-prep functions to produce a
# single HTML whose left sidebar has three top-level groups:
#
#   Overall              whole parent LOT_LONG cohort (Q1/Q2/Q3 + QC)
#   NDMM                 1L newly-diagnosed cohort (June 5 IE filters)
#   Exploratory analysis ad-hoc / one-off requests
#
# Placement rule (Julia, 10-Jun): an ad-hoc ask that REUSES the Overall
# or NDMM denominator (same patient counts) is added UNDER that cohort
# as a "QC:" or "Sensitivity:" item. An ask that CHANGES the cohort
# (a different denominator, e.g. a POMA-specific subset) goes under
# Exploratory analysis. Nothing in this repo currently needs the
# Exploratory group, so it ships as a scaffold describing the rule.
#
# Parent pipeline files are NOT edited.

.script_dir <- local({
  args <- commandArgs(trailingOnly = FALSE)
  fa <- grep("^--file=", args, value = TRUE)
  if (length(fa) > 0)
    return(dirname(normalizePath(sub("^--file=", "", fa[1]))))
  for (i in seq_len(sys.nframe())) {
    o <- tryCatch(sys.frame(i)$ofile, error = function(e) NULL)
    if (!is.null(o)) return(dirname(normalizePath(o)))
  }
  getwd()
})

# Source julia_q4.R (which itself sources julia_q1_q3.R) without letting
# either auto-run its own single-cohort main(). The script_dir overrides
# pin each file's R/ helper + CSV resolution to the right folder, since
# commandArgs("--file=") now points at THIS combined script.
options(julia_q4.no_autorun = TRUE)
options(julia_q4.script_dir = file.path(.script_dir, "julia_q4_ashley"))
source(file.path(.script_dir, "julia_q4_ashley", "julia_q4.R"))

# ---- Per-cohort view collection -------------------------------------
# Runs the shared Q1/Q2/Q3 + QC builders against whatever LOT_LONG_AUG
# currently holds, tagging every item with section = cohort_label so the
# sidebar groups them under one collapsible cohort heading. Q-area title
# prefixes ("Q1: ", "Q2: ", "QC: ") cluster the views within a cohort.
# Callers MUST have populated LOT_LONG_AUG for this cohort (via
# prepare_overall_cohort / prepare_ndmm_cohort) immediately before, and
# must not repopulate it until this returns - every builder pulls its
# data to R here, so the next cohort can safely overwrite the view.
collect_cohort_views <- function(con, cohort_label, lookups) {
  build_steroid_prevalence(con, section = cohort_label, title_prefix = "Q2: ")
  for (n in 1:4)
    build_focused_pair(con, n, n + 1L, section = cohort_label,
                       title_prefix = "Q1: ")
  for (n in 1:4)
    build_category_pair(con, n, n + 1L, lookups, section = cohort_label,
                        title_prefix = "Q1: ")
  build_category_coverage(con, lookups, section = cohort_label,
                          title_prefix = "QC: ")
}

# ---- Exploratory analysis scaffold ----------------------------------
build_exploratory_scaffold <- function() {
  add_html_card(paste0(
    '<div style="font-family:system-ui;padding:14px;max-width:900px">',
    '<h3>Exploratory analysis</h3>',
    '<p style="color:#555;font-size:13px">Home for ad-hoc / one-off ',
    'requests. Placement rule:</p>',
    '<ul style="font-size:13px;color:#444">',
    '<li>An ask that <b>reuses the Overall or NDMM cohort</b> (same ',
    'patient denominator) is added <b>under that cohort</b> in the left ',
    'sidebar as a <code>QC:</code> or <code>Sensitivity:</code> ',
    'item - not here.</li>',
    '<li>An ask that <b>changes the cohort</b> (a different denominator, ',
    'e.g. a POMA-specific subset) is added <b>here</b> as its own view, ',
    'with the cohort definition stated on the view.</li>',
    '</ul>',
    '<p style="color:#888;font-size:12px">No different-cohort ad-hoc ',
    'analyses are wired in yet, so this group is currently a ',
    'placeholder. New ones land here as they come in.</p>',
    '</div>'),
    section = "Exploratory analysis",
    title   = "About this section")
}

main_combined <- function() {
  stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")
  cfg$build_dashboard <<- TRUE

  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn,
                        pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  dashboard_items <<- list()

  # ---- Overall (whole cohort) ----
  log_msg("==== Building OVERALL cohort views ====")
  p_overall <- prepare_overall_cohort(con)
  build_overview_card(p_overall$n_ster, p_overall$n_rules,
                      section = "Overall",
                      title   = "Overview & cohort definition")
  collect_cohort_views(con, "Overall", p_overall$lookups)

  # ---- NDMM (1L newly-diagnosed cohort) ----
  # Wrapped so a missing parent input (e.g. ELIG_COH_FINAL) degrades to
  # an explanatory card instead of killing the whole combined dashboard;
  # Overall + Exploratory still render.
  log_msg("==== Building NDMM cohort views ====")
  ndmm_ok <- tryCatch({
    p_ndmm <- prepare_ndmm_cohort(con)
    build_q4_overview_card(p_ndmm$counts, p_ndmm$n_ster, p_ndmm$n_rules,
                           p_ndmm$overview_notes, section = "NDMM",
                           title = "Overview & cohort definition")
    collect_cohort_views(con, "NDMM", p_ndmm$lookups)
    TRUE
  }, error = function(e) {
    log_msg("  WARN: NDMM cohort could not be built: ", conditionMessage(e))
    add_html_card(paste0(
      '<div style="font-family:system-ui;padding:14px;max-width:900px">',
      '<h3>NDMM cohort - not available</h3>',
      '<p style="color:#a06000;font-size:13px">The NDMM (1L) cohort ',
      'could not be built in this run:</p>',
      '<pre style="font-size:12px;background:#f7f7f7;padding:8px;',
      'border-radius:6px;white-space:pre-wrap">',
      conditionMessage(e), '</pre>',
      '<p style="color:#555;font-size:13px">Most often this means the ',
      'parent <code>ELIG_COH_FINAL</code> / <code>MAP_STACKED</code> ',
      'tables are not present in the work schema. Build the parent ',
      'pipeline first, then re-run.</p></div>'),
      section = "NDMM", title = "Overview & cohort definition")
    FALSE
  })

  # ---- Exploratory analysis ----
  build_exploratory_scaffold()

  build_dashboard(
    out_name     = "julia_combined_dashboard.html",
    header_title = "MM LOT &mdash; Julia June 5 (combined)",
    header_sub   = paste0("Overall &bull; NDMM",
                          if (!ndmm_ok) " (unavailable)" else "",
                          " &bull; Exploratory analysis")
  )
  log_msg("Wrote ", file.path(cfg$output_dir, "julia_combined_dashboard.html"))
}

if (!interactive() && !isTRUE(getOption("julia_combined.no_autorun")))
  main_combined()
