#!/usr/bin/env Rscript
# ONE combined dashboard for both cohorts + exploratory.
#
#   Rscript apr_30_2026/07_combined_dashboard.R
#
# Output: combined_dashboard.html in cfg$output_dir.
#
# The two standalone dashboards still build exactly as before:
#   Rscript apr_30_2026/05_regimen_dashboard.R  -> whole (overall) cohort
#   Rscript apr_30_2026/06_ndmm_dashboard.R     -> NDMM cohort
# This script reuses their builders + cohort-prep functions to produce a
# single HTML whose left sidebar has three top-level groups:
#
#   Overall              whole parent LOT_LONG cohort
#                        (regimen transitions + steroids + QC + LOT1-5 detail)
#   NDMM                 1L newly-diagnosed cohort (IE filters)
#   Exploratory analysis ad-hoc / one-off requests
#
# Placement rule: an ad-hoc ask that REUSES the Overall or NDMM
# denominator (same patient counts) is added UNDER that cohort as a
# "QC:" or "Sensitivity:" item. An ask that CHANGES the cohort (a
# different denominator, e.g. a POMA-specific subset) goes under
# Exploratory analysis. Nothing in this repo currently needs the
# Exploratory group, so it ships as a scaffold describing the rule.
#
# Parent derivation logic is unchanged.

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

# Source 06_ndmm_dashboard.R (which itself sources 05_regimen_dashboard.R)
# AND 04_lot_detail_dashboard.R without letting any of them auto-run their
# own single-cohort main(). The script_dir overrides pin each file's
# R/ helper + CSV resolution to this folder, since commandArgs("--file=")
# now points at THIS combined script.
options(ndmm_dashboard.no_autorun       = TRUE)
options(ndmm_dashboard.script_dir       = .script_dir)
options(regimen_dashboard.script_dir    = .script_dir)
options(lot_detail_dashboard.no_autorun = TRUE)
source(file.path(.script_dir, "06_ndmm_dashboard.R"))
source(file.path(.script_dir, "04_lot_detail_dashboard.R"))

# Rewrite the section/title fields of items newly added by a builder so
# they cluster under one cohort heading in the combined sidebar while
# preserving their original subsection name in the title. Range
# [from_idx+1, length(dashboard_items)] is the freshly appended slice.
# This is the post-processing alternative to parameterising every
# save_*() call inside the LOT1-5 detail collector - new views added
# there will be re-sectioned automatically.
resection_recent_items <- function(from_idx, cohort_label,
                                   subsection_in_title = TRUE) {
  n <- length(dashboard_items)
  if (n <= from_idx) return(invisible())
  for (i in (from_idx + 1):n) {
    it <- dashboard_items[[i]]
    orig_section <- it$section
    if (isTRUE(subsection_in_title) &&
        !identical(orig_section, cohort_label)) {
      it$title <- paste0(orig_section, ": ", it$title)
    }
    it$section <- cohort_label
    dashboard_items[[i]] <<- it
  }
}

# ---- Per-cohort view collection -------------------------------------
# Runs both the shared regimen-transition / steroid builders AND the
# LOT1-5 detail collector from 04_lot_detail_dashboard.R against this
# cohort's data, tagging every produced item with section = cohort_label
# so the combined sidebar groups them under one collapsible cohort
# heading.
#
# Within the cohort group, title prefixes cluster related views:
#   Transitions: / Steroids: / QC:   regimen builders (Sankeys, steroids)
#   FUNNEL: / START_TYPE: / ...       LOT1-5 detail (carried in by re-section)
#
# Callers MUST have populated LOT_LONG_AUG for this cohort (via
# prepare_overall_cohort / prepare_ndmm_cohort) immediately before, and
# must not repopulate it until this returns. lot_long_tbl is what the
# LOT1-5 collector aggregates over; usually the cohort-filtered LOT_LONG
# view so all the FUNNEL / START_TYPE / etc. detail reflects the cohort.
# include_debug = TRUE only on the first call (Overall) - the DEBUG/QC
# work-table inventory + ANY-PATID drilldown are schema-wide, not
# cohort-scoped, so repeating them for NDMM would mislead.
collect_cohort_views <- function(con, cohort_label, lookups, lot_long_tbl,
                                 include_debug = FALSE) {
  build_steroid_prevalence(con, section = cohort_label, title_prefix = "Steroids: ")
  for (n in 1:4)
    build_focused_pair(con, n, n + 1L, section = cohort_label,
                       title_prefix = "Transitions: ")
  for (n in 1:4)
    build_category_pair(con, n, n + 1L, lookups, section = cohort_label,
                        title_prefix = "Transitions: ")
  build_category_coverage(con, lookups, section = cohort_label,
                          title_prefix = "QC: ")
  build_patient_gallery(con, lot_long_tbl, section = cohort_label,
                        title_prefix = "Examples: ")

  # LOT1-5 detail (FUNNEL, START_TYPE, END_REASON, LENGTH, REGIMENS,
  # PROGRESSION, GAPS, TRANSITIONS, SANKEY, MEDCOUNT, MTX, TREND,
  # MED JOURNEY, +DEBUG/DRILLDOWN if include_debug). The collector
  # tags items with its original section names; we re-section them
  # under cohort_label and fold the original name into the title.
  before <- length(dashboard_items)
  collect_lot_long_views(con, lot_long_tbl, include_debug = include_debug)
  resection_recent_items(before, cohort_label)
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

  # Cohort prefixes keep the LOT1-5 static PNG artifacts (lotlong_*.png)
  # from clobbering each other across the two cohort passes. The HTML
  # dashboard renders the in-memory plotly objects, so it is correct
  # without this; the prefix is just for the on-disk PNG sidecars.
  on.exit(cfg$plot_filename_prefix <<- NULL, add = TRUE)

  # ---- Overall (whole cohort) ----
  log_msg("==== Building OVERALL cohort views ====")
  cfg$plot_filename_prefix <<- "overall_"
  p_overall <- prepare_overall_cohort(con)
  build_cohort_kpis(con, wrk("LOT_LONG"), section = "Overall",
                    title = "KPI snapshot")
  build_overview_card(p_overall$n_ster, p_overall$n_rules,
                      section = "Overall",
                      title   = "Overview & cohort definition")
  build_overall_attrition(con, section = "Overall",
                          title_prefix = "Attrition: ")
  # LOT1-5 detail runs on parent LOT_LONG (un-augmented) so the FUNNEL /
  # START_TYPE / END_REASON / etc. counts match the persisted parent
  # exactly - LOT_LONG_AUG only adds steroid tokens to LOT_BASE_MEDS for
  # the category-transition view, it does not change LOT boundaries or
  # end reasons.
  # include_debug = TRUE here so the audit + drilldown cards are
  # produced once (under Overall).
  collect_cohort_views(con, "Overall", p_overall$lookups,
                       lot_long_tbl  = wrk("LOT_LONG"),
                       include_debug = TRUE)

  # ---- NDMM (1L newly-diagnosed cohort) ----
  # Wrapped so a missing parent input (e.g. ELIG_COH_FINAL) degrades to
  # an explanatory card instead of killing the whole combined dashboard;
  # Overall + Exploratory still render.
  log_msg("==== Building NDMM cohort views ====")
  cfg$plot_filename_prefix <<- "ndmm_"
  ndmm_ok <- tryCatch({
    p_ndmm <- prepare_ndmm_cohort(con)
    build_cohort_kpis(con, NDMM_LOT_LONG_FILT, section = "NDMM",
                      title = "KPI snapshot")
    build_ndmm_overview_card(p_ndmm$counts, p_ndmm$n_ster, p_ndmm$n_rules,
                             p_ndmm$overview_notes, section = "NDMM",
                             title = "Overview & cohort definition")
    build_ndmm_attrition(p_ndmm$counts, section = "NDMM",
                         title_prefix = "Attrition: ")
    build_ndmm_other_cancer_qc(con, section = "NDMM",
                               title_prefix = "QC: ")
    # LOT1-5 detail re-runs on the cohort-filtered LOT_LONG view
    # (NDMM_LOT_LONG_FILT, built by prepare_ndmm_cohort) so every FUNNEL /
    # START_TYPE / etc. number reflects the NDMM-restricted denominator.
    # DEBUG/DRILLDOWN already produced under Overall - skip here.
    collect_cohort_views(con, "NDMM", p_ndmm$lookups,
                         lot_long_tbl  = NDMM_LOT_LONG_FILT,
                         include_debug = FALSE)
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
  cfg$plot_filename_prefix <<- NULL
  build_exploratory_scaffold()

  build_dashboard(
    out_name     = "combined_dashboard.html",
    header_title = "MM LOT &mdash; combined (Overall + NDMM)",
    header_sub   = paste0("Overall &bull; NDMM",
                          if (!ndmm_ok) " (unavailable)" else "",
                          " &bull; Exploratory analysis")
  )
  log_msg("Wrote ", file.path(cfg$output_dir, "combined_dashboard.html"))
}

if (!interactive() && !isTRUE(getOption("combined_dashboard.no_autorun")))
  main_combined()
