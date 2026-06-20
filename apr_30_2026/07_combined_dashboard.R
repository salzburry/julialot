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
# single HTML. The left sidebar has cohort pills:
#
#   Summary  executive landing page - Overall vs NDMM headline numbers,
#            data-quality strip, and a Key findings panel (built last, then
#            sorted to the front by tag_and_order()); the opening view.
#   Overall  whole parent LOT_LONG cohort (regimen transitions + steroids +
#            payer + QC + LOT1-5 detail)
#   NDMM     1L newly-diagnosed cohort (IE filters)
#
# Within each cohort, tag_and_order() groups views into collapsible buckets
# (Cohort & attrition / Treatment patterns / Steroids & payer, plus the
# full-only Patient explorer / Validation / Debug), and a Stakeholder/Full
# toggle hides the full-only buckets by default.
#
# An empty "Exploratory analysis" group is intentionally NOT built (it would
# return only when a real different-denominator ad-hoc analysis exists).
# build_exploratory_scaffold() is kept below as documentation of that rule.
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
                                 include_debug = FALSE,
                                 ndmm_flags_tbl = NULL) {
  # Per-step progress logging: these builders are otherwise silent, so a slow
  # or stalled one used to look like the run simply stopped after the cohort's
  # attrition figure. Each line names the view group about to be built, so the
  # last line printed before a stall pinpoints the culprit (for both cohorts).
  log_msg("[", cohort_label, "] views 1/8: steroid prevalence + missing-steroid LOT1 + DEXA-vs-LENA timing + pre-LOT steroid")
  build_steroid_prevalence(con, section = cohort_label, title_prefix = "Steroids: ")
  build_missing_steroid_lot1(con, section = cohort_label, title_prefix = "Steroids: ")
  build_steroid_timing_qc(con, lot_long_tbl, section = cohort_label, title_prefix = "Steroids: ")
  build_pre_lot_steroid_qc(con, lot_long_tbl, section = cohort_label, title_prefix = "Steroids: ")
  log_msg("[", cohort_label, "] views 2/8: focused regimen-pair transitions")
  for (n in 1:4)
    build_focused_pair(con, n, n + 1L, section = cohort_label,
                       title_prefix = "Transitions: ")
  log_msg("[", cohort_label, "] views 3/8: category-pair transitions")
  for (n in 1:4)
    build_category_pair(con, n, n + 1L, lookups, section = cohort_label,
                        title_prefix = "Transitions: ")
  log_msg("[", cohort_label, "] views 4/8: category coverage QC")
  build_category_coverage(con, lookups, section = cohort_label,
                          title_prefix = "QC: ")
  log_msg("[", cohort_label, "] views 5/8: patient gallery")
  build_patient_gallery(con, lot_long_tbl, section = cohort_label,
                        title_prefix = "Examples: ")
  log_msg("[", cohort_label, "] views 6/8: validation views")
  build_validation_views(con, lot_long_tbl, section = cohort_label,
                         title_prefix = "Validation: ",
                         ndmm_flags_tbl = ndmm_flags_tbl)
  log_msg("[", cohort_label, "] views 6b/8: payer split (Medicare vs Commercial)")
  build_payer_lot_qc(con, section = cohort_label, title_prefix = "Payer: ")

  # LOT1-5 detail (FUNNEL, START_TYPE, END_REASON, LENGTH, REGIMENS,
  # PROGRESSION, GAPS, TRANSITIONS, SANKEY, MEDCOUNT, MTX, TREND,
  # MED JOURNEY, +DEBUG/DRILLDOWN if include_debug). The collector
  # tags items with its original section names; we re-section them
  # under cohort_label and fold the original name into the title.
  log_msg("[", cohort_label, "] views 7/8: LOT1-5 detail (funnel/sankey/transitions/...)")
  before <- length(dashboard_items)
  collect_lot_long_views(con, lot_long_tbl, include_debug = include_debug)
  resection_recent_items(before, cohort_label)
  log_msg("[", cohort_label, "] views 8/8: done (", length(dashboard_items), " items)")
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

# ---- Summary landing page (data-driven, opens first) ----------------
# Side-by-side Overall vs NDMM headline numbers pulled straight from
# query_cohort_kpis() - no hard-coded findings. Every figure is computed
# at build time from each cohort's LOT_LONG. The NDMM column degrades to
# "n/a" when that cohort could not be built this run. Rendered as a
# self-contained html_card (sandboxed iframe), so it cannot affect the
# rest of the dashboard's navigation.
build_summary_landing <- function(kpi_overall, kpi_ndmm, ndmm_ok, run_ts,
                                   n_ster = NA, n_rules = NA, study_end = NA) {
  has_o <- length(kpi_overall) > 0 && !is.null(kpi_overall$n_patients) &&
           !is.na(kpi_overall$n_patients)
  has_n <- isTRUE(ndmm_ok) && length(kpi_ndmm) > 0 &&
           !is.null(kpi_ndmm$n_patients) && !is.na(kpi_ndmm$n_patients)

  fmt_days <- function(x)
    if (length(x) == 0 || is.null(x) || is.na(x)) "-" else paste0(fmt_n(x), " d")
  reached <- function(k, key)
    paste0(fmt_n(k[[key]]), " <span style='color:#6B7280'>(",
           fmt_pct(k[[key]], k$n_patients), ")</span>")

  ov <- if (has_o) list(
    pat = fmt_n(kpi_overall$n_patients),
    pct = "&mdash;",
    l2  = reached(kpi_overall, "n_lot2"),
    l3  = reached(kpi_overall, "n_lot3"),
    med = fmt_days(kpi_overall$lot1_median_len),
    rng = fmt_date_range(kpi_overall$lot1_min, kpi_overall$lot1_max)
  ) else NULL
  nd <- if (has_n) list(
    pat = fmt_n(kpi_ndmm$n_patients),
    pct = fmt_pct(kpi_ndmm$n_patients, if (has_o) kpi_overall$n_patients else NA),
    l2  = reached(kpi_ndmm, "n_lot2"),
    l3  = reached(kpi_ndmm, "n_lot3"),
    med = fmt_days(kpi_ndmm$lot1_median_len),
    rng = fmt_date_range(kpi_ndmm$lot1_min, kpi_ndmm$lot1_max)
  ) else NULL
  ovcell <- function(key) if (is.null(ov)) "-" else ov[[key]]
  ndcell <- function(key)
    if (is.null(nd)) "<span style='color:#a06000'>n/a</span>" else nd[[key]]

  rowh <- function(metric, key, hint = "")
    paste0('<tr>',
      '<td style="padding:10px 14px;border-bottom:1px solid #EEE">',
        '<div style="font-weight:600;color:#2A2A33">', metric, '</div>',
        if (nzchar(hint))
          paste0('<div style="font-size:11px;color:#9aa0aa">', hint, '</div>')
        else '',
      '</td>',
      '<td style="padding:10px 14px;border-bottom:1px solid #EEE;text-align:right;',
        'font-variant-numeric:tabular-nums">', ovcell(key), '</td>',
      '<td style="padding:10px 14px;border-bottom:1px solid #EEE;text-align:right;',
        'font-variant-numeric:tabular-nums">', ndcell(key), '</td>',
    '</tr>')

  body <- paste0(
    rowh("Patients (any LOT)", "pat", "distinct PATID"),
    rowh("NDMM as % of Overall", "pct", "shared-denominator check"),
    rowh("Reached LOT2+", "l2"),
    rowh("Reached LOT3+", "l3"),
    rowh("Median LOT1 length", "med", "LOT_BASE_LENGTH"),
    rowh("LOT1 start range", "rng", "earliest &rarr; latest")
  )

  ndmm_note <- if (!has_n)
    paste0('<p style="margin:10px 0 0;font-size:12px;color:#a06000">',
           'The NDMM (1L) cohort could not be built this run, so its column ',
           'shows <b>n/a</b>. See the NDMM section for the reason.</p>') else ""

  or_na <- function(x)
    if (length(x) == 0 || is.null(x) || (length(x) == 1 && is.na(x))) "n/a"
    else as.character(x)
  # One headline stat callout (accent = coloured top border per cohort).
  stat_card <- function(label, value, sub, accent)
    paste0('<div style="flex:1 1 200px;border:1px solid #E5E7EB;border-top:3px solid ',
           accent, ';border-radius:10px;padding:14px 16px;background:#fff">',
           '<div style="font-size:11px;text-transform:uppercase;letter-spacing:.05em;',
           'color:#6B7280;font-weight:800">', label, '</div>',
           '<div style="font-size:30px;font-weight:800;color:#1f2937;line-height:1.1;',
           'margin-top:3px">', value, '</div>',
           '<div style="font-size:12px;color:#6B7280;margin-top:2px">', sub, '</div></div>')
  ov_pat <- if (has_o) fmt_n(kpi_overall$n_patients) else "n/a"
  nd_pat <- if (has_n) fmt_n(kpi_ndmm$n_patients) else "n/a"
  nd_sub <- if (has_n)
      paste0(fmt_pct(kpi_ndmm$n_patients, if (has_o) kpi_overall$n_patients else NA),
             " of Overall")
    else "cohort unavailable this run"
  stat_band <- paste0(
    '<div style="display:flex;gap:14px;margin:0 0 18px;flex-wrap:wrap">',
    stat_card("Overall cohort",   ov_pat, "patients with any LOT", "#0E7C7B"),
    stat_card("NDMM cohort (1L)",  nd_pat, nd_sub,                  "#F36633"),
    '</div>')
  dq <- paste0(
    '<div style="margin-top:16px;padding:10px 12px;background:#F7F8FA;',
         'border:1px solid #E5E7EB;border-radius:8px;font-size:12px;color:#6B7280">',
    '<b style="color:#2A2A33">Run &amp; data quality</b>',
    ' &nbsp;&bull;&nbsp; Study end ',     or_na(study_end),
    ' &nbsp;&bull;&nbsp; Steroid codes ', or_na(n_ster),
    ' &nbsp;&bull;&nbsp; Category rules ', or_na(n_rules),
    ' &nbsp;&bull;&nbsp; Generated ',     run_ts,
    ' &nbsp;&bull;&nbsp; Overall: ', if (has_o) 'built' else 'unavailable',
    ' &nbsp;&bull;&nbsp; NDMM: ',    if (has_n) 'built' else 'unavailable',
    '</div>')

  # Optional stakeholder-ask findings recorded by the steroid/payer builders -
  # the exact numbers shown in their detail views, reused here, grouped by
  # cohort (Overall then NDMM). Failsafe: any problem yields an empty panel.
  findings_html <- tryCatch({
    all_f <- if (exists("dashboard_findings")) dashboard_findings else list()
    render_cohort <- function(coh) {
      ff <- Filter(function(f) identical(f$cohort, coh), all_f)
      if (length(ff) == 0) return("")
      rows <- paste(vapply(ff, function(f)
        paste0('<li style="margin:4px 0"><b style="color:#0E7C7B">', f$group,
               '</b> &mdash; ', f$text, '</li>'), character(1)), collapse = "")
      paste0('<div style="margin-top:8px"><div style="font-size:12px;font-weight:800;',
             'text-transform:uppercase;letter-spacing:.04em;color:#6B7280">', coh,
             '</div><ul style="margin:2px 0 0;padding-left:18px;font-size:13px;',
             'color:#2A2A33;line-height:1.5">', rows, '</ul></div>')
    }
    blocks <- paste0(render_cohort("Overall"), render_cohort("NDMM"))
    if (!nzchar(blocks)) "" else
      paste0('<h3 style="margin:20px 0 6px;font-size:15px;font-weight:800">Key findings ',
             '<span style="font-weight:600;color:#6B7280;font-size:12px">',
             '(full detail in each cohort&rsquo;s Steroids &amp; payer section)</span></h3>',
             blocks)
  }, error = function(e) "")

  card <- paste0(
'<div style="font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;',
     'padding:18px 20px;max-width:920px;color:#2A2A33">',
  '<h2 style="margin:0 0 4px;font-size:20px;font-weight:800">Executive summary</h2>',
  '<p style="margin:0 0 14px;font-size:13px;color:#6B7280;line-height:1.5">',
    'Headline numbers for the two cohorts in this build. ',
    '<b>Overall</b> is the whole parent line-of-therapy cohort; ',
    '<b>NDMM</b> is the 1L newly-diagnosed subset (inclusion/exclusion gates applied). ',
    'All figures are computed at build time from each cohort&rsquo;s LOT_LONG ',
    '&mdash; nothing here is hard-coded.',
  '</p>',
  stat_band,
  '<table style="border-collapse:collapse;width:100%;font-size:14px">',
    '<thead><tr>',
      '<th style="text-align:left;padding:8px 14px;border-bottom:2px solid #F36633;',
        'font-size:12px;text-transform:uppercase;letter-spacing:.04em;color:#6B7280">Metric</th>',
      '<th style="text-align:right;padding:8px 14px;border-bottom:2px solid #F36633;',
        'color:#D24E1F">Overall</th>',
      '<th style="text-align:right;padding:8px 14px;border-bottom:2px solid #F36633;',
        'color:#0E7C7B">NDMM</th>',
    '</tr></thead>',
    '<tbody>', body, '</tbody>',
  '</table>',
  ndmm_note,
  findings_html,
  dq,
'</div>')

  add_html_card(card, section = "Summary", title = "Executive summary")
}

# ---- Bucket + audience tagging --------------------------------------
# Classify every item into a stakeholder-facing bucket and an audience by
# the title prefix its builder emits (folded in by resection_recent_items
# / the shared title_prefix= args). The bucket drives a two-level nav
# (cohort pill -> collapsible bucket); the audience drives the
# Stakeholder/Full toggle. Buckets and audience are aligned so the three
# stakeholder buckets are uniformly stakeholder and the three internal
# buckets are uniformly full - in stakeholder view the internal buckets
# simply disappear, leaving a clean three-bucket nav per cohort.
#
# The data still ships in the file regardless of audience (acceptable
# here: internal GSK audience with equivalent data access), so the toggle
# is a presentation cut, not a privacy boundary.
COHORT_ORDER <- c("Summary", "Overall", "NDMM")
BUCKET_ORDER <- c("Summary", "Cohort & attrition", "Treatment patterns",
                  "Steroids & payer", "Patient explorer", "Validation",
                  "Debug", "Other")

classify_item <- function(title) {
  rules <- list(
    c("^Executive summary",                                  "Summary",            "stakeholder"),
    c("^(KPI snapshot|Overview & cohort)",                   "Cohort & attrition", "stakeholder"),
    c("^(Attrition|OVERVIEW|FUNNEL): ",                      "Cohort & attrition", "stakeholder"),
    c(paste0("^(Transitions|START_TYPE|END_REASON|LENGTH|REGIMENS|",
             "PROGRESSION|GAPS|TRANSITIONS|SANKEY|MEDCOUNT|MTX|TREND): "),
                                                             "Treatment patterns", "stakeholder"),
    c("^(Steroids|Payer): ",                                 "Steroids & payer",   "stakeholder"),
    c("^(Examples|MED JOURNEY): ",                           "Patient explorer",   "full"),
    c("^(Validation|QC): ",                                  "Validation",         "full"),
    c("^(DEBUG|DRILLDOWN): ",                                "Debug",              "full")
  )
  for (r in rules) if (grepl(r[1], title)) return(list(bucket = r[2], audience = r[3]))
  # Fail closed: an unrecognized title (e.g. a future builder with a new
  # prefix) lands in "Other" as full-only, so it is hidden from the
  # stakeholder view by default rather than leaking an unvetted view.
  list(bucket = "Other", audience = "full")
}

# Tag $bucket + $audience on every item, then stable-sort into
# (cohort, bucket) order so the nav reads top-down as a stakeholder would
# expect, with unknowns falling to the end of their cohort.
tag_and_order <- function() {
  n <- length(dashboard_items)
  for (i in seq_len(n)) {
    it <- dashboard_items[[i]]
    cl <- classify_item(it$title)
    it$bucket   <- cl$bucket
    it$audience <- cl$audience
    dashboard_items[[i]] <<- it
  }
  rank <- function(x, levels) {
    m <- match(x, levels); ifelse(is.na(m), length(levels) + 1L, m)
  }
  cr <- vapply(dashboard_items, function(it) rank(it$section, COHORT_ORDER), integer(1))
  br <- vapply(dashboard_items, function(it) rank(it$bucket,  BUCKET_ORDER), integer(1))
  dashboard_items <<- dashboard_items[order(cr, br, seq_len(n))]
}

main_combined <- function() {
  stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")
  cfg$build_dashboard <<- TRUE

  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn,
                        pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  # One run timestamp for both cohorts so a row pair in
  # lot_dashboard_run_summary clearly belongs to the same dashboard
  # build.
  run_ts_combined <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")

  dashboard_items <<- list()
  dashboard_findings <<- list()

  # Cohort prefixes keep the LOT1-5 static PNG artifacts (lotlong_*.png)
  # from clobbering each other across the two cohort passes. The HTML
  # dashboard renders the in-memory plotly objects, so it is correct
  # without this; the prefix is just for the on-disk PNG sidecars.
  on.exit(cfg$plot_filename_prefix <<- NULL, add = TRUE)

  # ---- Overall (whole cohort) ----
  log_msg("==== Building OVERALL cohort views ====")
  cfg$plot_filename_prefix <<- "overall_"
  p_overall <- prepare_overall_cohort(con)
  kpi_overall <- query_cohort_kpis(con, wrk("LOT_LONG"))
  build_cohort_kpis(con, wrk("LOT_LONG"), section = "Overall",
                    title = "KPI snapshot")
  build_overview_card(p_overall$n_ster, p_overall$n_rules,
                      section = "Overall",
                      title   = "Overview & cohort definition")
  build_overall_attrition(con, section = "Overall",
                          title_prefix = "Attrition: ")
  # LOT1-5 detail runs on parent LOT_LONG so the funnel/start-type/end-
  # reason counts match the persisted parent. include_debug = TRUE here
  # so the audit + drilldown cards are produced once (under Overall).
  collect_cohort_views(con, "Overall", p_overall$lookups,
                       lot_long_tbl  = wrk("LOT_LONG"),
                       include_debug = TRUE)
  build_run_comparison(con, "Overall", wrk("LOT_LONG"),
                       section = "Overall",
                       title_prefix = "Validation: ",
                       run_ts = run_ts_combined)

  # ---- NDMM (1L newly-diagnosed cohort) ----
  # Wrapped so a missing parent input (e.g. ELIG_COH_FINAL) degrades to
  # an explanatory card instead of killing the whole combined dashboard;
  # Overall + Exploratory still render.
  log_msg("==== Building NDMM cohort views ====")
  cfg$plot_filename_prefix <<- "ndmm_"
  kpi_ndmm <- list()
  ndmm_ok <- tryCatch({
    p_ndmm <- prepare_ndmm_cohort(con)
    kpi_ndmm <- query_cohort_kpis(con, NDMM_LOT_LONG_FILT)
    build_cohort_kpis(con, NDMM_LOT_LONG_FILT, section = "NDMM",
                      title = "KPI snapshot")
    build_ndmm_overview_card(p_ndmm$counts, p_ndmm$n_ster, p_ndmm$n_rules,
                             p_ndmm$overview_notes, section = "NDMM",
                             title = "Overview & cohort definition")
    build_ndmm_attrition(p_ndmm$counts, section = "NDMM",
                         title_prefix = "Attrition: ")
    build_ndmm_other_cancer_qc(con, section = "NDMM",
                               title_prefix = "QC: ")
    # LOT1-5 detail re-runs on NDMM_LOT_LONG_FILT so every count reflects
    # the NDMM denominator. Debug/drilldown already produced under Overall.
    collect_cohort_views(con, "NDMM", p_ndmm$lookups,
                         lot_long_tbl   = NDMM_LOT_LONG_FILT,
                         include_debug  = FALSE,
                         ndmm_flags_tbl = NDMM_FLAGS_ALL)
    build_run_comparison(con, "NDMM", NDMM_LOT_LONG_FILT,
                         section = "NDMM",
                         title_prefix = "Validation: ",
                         run_ts = run_ts_combined)
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

  cfg$plot_filename_prefix <<- NULL

  # ---- Summary landing page + nav structuring ----
  # Built last (it needs both cohorts' KPIs); tag_and_order() then assigns
  # every item a bucket + audience and stable-sorts the whole list into
  # (cohort, bucket) order, so the Summary leads and each cohort reads
  # top-down (cohort & attrition -> treatment -> steroids & payer ->
  # internal). The empty Exploratory scaffold is intentionally not built -
  # it returns only when a real different-denominator analysis exists.
  build_summary_landing(kpi_overall, kpi_ndmm, ndmm_ok, run_ts_combined,
                        n_ster = p_overall$n_ster, n_rules = p_overall$n_rules,
                        study_end = cfg$study_end)
  tag_and_order()

  build_dashboard(
    out_name     = "combined_dashboard.html",
    header_title = "MM LOT &mdash; combined (Overall + NDMM)",
    header_sub   = paste0("Summary &bull; Overall &bull; NDMM",
                          if (!ndmm_ok) " (unavailable)" else ""),
    cohort_sections = c("Summary", "Overall", "NDMM")
  )
  log_msg("Wrote ", file.path(cfg$output_dir, "combined_dashboard.html"))
}

if (!interactive() && !isTRUE(getOption("combined_dashboard.no_autorun")))
  main_combined()
