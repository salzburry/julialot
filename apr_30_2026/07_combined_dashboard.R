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
# The "Exploratory analysis" cohort pill carries the study-team validation
# Q&A (Q1-Q6, "MM LOT Validation next steps"), built by
# build_validation_exploratory() from the shared R/validation_qs_jun29.R
# module (same logic as the standalone validation_qs_jun29.R program).
# build_exploratory_scaffold() remains below as documentation of the
# placement rule for future ad-hoc asks.
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

# Shared study-team validation Q&A logic (Q1-Q6, "MM LOT Validation next
# steps"). Same module the standalone validation_qs_jun29.R uses, so the
# Exploratory tables here and that program's CSVs can never drift apart.
# load_codelist_csv (needed only for the guarded raw-claim examples) may not
# be sourced by the dashboard chain; source it best-effort.
try(source(file.path(.script_dir, "R", "codelists_lot.R")), silent = TRUE)
source(file.path(.script_dir, "R", "validation_qs_jun29.R"))

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
  # Shared gate: an unavailable codelist yields one "analyses unavailable" card
  # instead of 0%/"0 of N" tables that read as real absence in the
  # stakeholder-visible Steroids section.
  build_steroid_section(con, lot_long_tbl, section = cohort_label,
                        title_prefix = "Steroids: ")
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
    '<p style="color:#888;font-size:12px">The study-team validation Q&amp;A ',
    '(Q1-Q6) is wired in here via <code>build_validation_exploratory()</code>; ',
    'further different-cohort ad-hoc analyses land here as they come in.</p>',
    '</div>'),
    section = "Exploratory analysis",
    title   = "About this section")
}

# ---- Exploratory objective: MM LOT Validation next steps (Q1-Q6) ----------
# Renders the six study-team validation questions as labelled tables under
# the Exploratory cohort pill. Per the study team's follow-up, every
# question is answered ONCE PER COHORT: the parent
# Overall LOT_LONG cohort, and the NDMM (1L) cohort when its pass succeeded
# (titles carry the cohort tag, e.g. "Q1 (NDMM): ..."). The shared signal
# views (steroid claims, raw CAR-T dates) are built once on the parent
# patient list - NDMM_LOT_LONG_FILT is LOT_LONG INNER JOINed to the NDMM
# patient set, so its patients are a strict subset and every per-question
# query joins back to its own cohort lot_long, which applies the restriction.
# Summary tables are stakeholder-visible; the raw-claim / MAP-journey patient
# examples carry "(sample)" so classify_item() routes them to the full-only
# Patient explorer (no raw PATID table leaks into the stakeholder view).
# Whole body is guarded so a failure degrades to one note card instead of
# killing the combined dashboard.
SEC_EXPL <- "Exploratory analysis"

build_validation_exploratory <- function(con, ndmm_ok = FALSE) {
  lot_long <- wrk("LOT_LONG"); map_tbl <- wrk("MAP_STACKED"); sct_tbl <- wrk("LOT1_SCT")
  have_map <- isTRUE(tryCatch({ db_q(con, glue("SELECT 1 FROM {map_tbl} LIMIT 1")); TRUE },
                              error = function(e) FALSE))
  have_sct <- isTRUE(tryCatch({ db_q(con, glue("SELECT 1 FROM {sct_tbl} LIMIT 1")); TRUE },
                              error = function(e) FALSE))
  tokens <- tryCatch(vqs_resolve_agent_tokens(con),
                     error = function(e) list(poma = "POMA", elot = "ELOT",
                                              pano = "PANO", notes = character(0)))
  # Observation-window bounds for the raw-claim examples + the raw CAR-T scan
  # (the only source that can answer "CAR-T before LOT1").
  bounds   <- tryCatch(vqs_obs_bounds_src(con),
                       error = function(e) list(sql = NULL, available = FALSE))
  cart_raw <- if (have_sct)
    tryCatch(vqs_build_raw_cart_dates(con, lot_long, bounds$sql),
             error = function(e) NULL) else NULL
  # Steroid signal = steroid_codes.csv scanned on medical+rx (NOT a MAP_STACKED
  # STEROID class, which does not exist in this codelist and returns zero).
  ster <- tryCatch(vqs_build_steroid_claims(con, lot_long,
                     file.path(.script_dir, "steroid_codes.csv")),
                   error = function(e) list(view = NULL, note = conditionMessage(e)))
  ster_src <- if (!is.null(ster$view)) vqs_steroid_src(ster$view) else NULL

  # Cohort passes (study-team follow-up): Overall always; NDMM when
  # its cohort pass succeeded AND the filtered LOT_LONG view is readable.
  cohorts <- list(list(tag = "Overall", lot_long = lot_long))
  ndmm_ready <- isTRUE(ndmm_ok) && exists("NDMM_LOT_LONG_FILT") &&
    isTRUE(tryCatch({ db_q(con, glue("SELECT 1 FROM {NDMM_LOT_LONG_FILT} LIMIT 1")); TRUE },
                    error = function(e) FALSE))
  if (ndmm_ready)
    cohorts <- c(cohorts, list(list(tag = "NDMM", lot_long = NDMM_LOT_LONG_FILT)))

  add_html_card(paste0(
    '<div style="font-family:system-ui;padding:14px;max-width:900px">',
    '<h3>MM LOT Validation next steps (study-team Q&amp;A)</h3>',
    '<p style="color:#555;font-size:13px">Six follow-up questions from the ',
    'study team. Per the study team&rsquo;s follow-up, every ',
    'question is answered <b>once per cohort</b> &mdash; <b>Overall</b> (the ',
    'parent <code>LOT_LONG</code> cohort) and <b>NDMM</b> (the 1L ',
    'newly-diagnosed subset',
    if (ndmm_ready) '' else ' &mdash; <b>unavailable this run</b>, see the NDMM section',
    '); titles carry the cohort tag. The same logic backs the standalone ',
    '<code>validation_qs_jun29.R</code> program (CSV outputs).</p>',
    '<ul style="font-size:13px;color:#444">',
    '<li><b>Steroid signal</b>: <code>steroid_codes.csv</code> codes scanned on ',
    'medical (PROC_CD/BILL_PROC_CD/NDC) + rx (NDC) - the project\'s steroid ',
    'source (there is no STEROID class in the MMA codelist). ',
    if (is.null(ster_src)) '<b>Unavailable this run - Q3/Q4/Q5 skipped.</b> '
    else paste0('<i>', esc_html(ster$note), '</i> '),
    '"Steroid classified as part of LOT<i>n</i>" (the no-steroid denominator) = a ',
    'steroid claim in the <b>capped</b> induction window <code>[LOT_START, ',
    'LOT_INDUCTION_END_DT]</code> (= <code>least(LOT_BASE_END_DT, LOT_START+W-1)</code>; ',
    'W=', VQS_W1, 'd LOT1 / ', VQS_CART, 'd CART-started LOT<i>n</i> / ', VQS_W2, 'd other; ',
    'SCT_ALLO has no membership) - matching the Steroids panel exactly.</li>',
    '<li><b>Before/after windows</b> (7/14/30d) are cumulative (&le;N days), from ',
    'a steroid claim date; "after" is anchored to the <b>fixed</b> induction end ',
    '<code>LOT_START+W-1</code> (not the capped end).</li>',
    '<li><b>CAR-T (Q6)</b>: "during or closing LOT1" = <code>LOT1_SCT.',
    'FIRST_CART_DT</code> in <code>[LOT1_START, LOT_BASE_END_DT]</code>, ',
    'extended to <code>LOT_BASE_END_DT+1</code> <b>only when</b> ',
    '<code>LOT_BASE_END_REASON</code> is <code>SCT_CART</code>/',
    '<code>CART_INIT</code> (the engine sets the LOT end to the CAR-T date',
    '&minus;1 for a CAR-T-ending line, so the closing CAR-T lands one day past ',
    'the end). "Before LOT1" comes from raw SCT claims',
    if (is.null(cart_raw)) ' (unavailable this run &mdash; shown as NA)' else '',
    ', since <code>FIRST_CART_DT</code> only captures CAR-T on/after LOT1 start.</li>',
    '<li><b>Agent tokens</b>: POMA=', tokens$poma, ', ELOT=', tokens$elot,
    ', PANO=', tokens$pano, ' (best-effort from <code>cl_mma_codelist.csv</code>).</li>',
    '<li><b>Raw-claim examples</b> are ',
    if (isTRUE(bounds$available)) 'bounded to each patient&rsquo;s [INDEX_DATE, OBS_END_DT] window.'
    else 'NOT observation-window bounded this run (ELIG_COH_FINAL unavailable).',
    '</li>',
    '</ul></div>'),
    section = SEC_EXPL, title = "About this section")

  if (!ndmm_ready)
    vqs_note_card(paste0(
      "Q1-Q6 (NDMM) not available this run - the NDMM (1L) cohort was not ",
      "built (see the NDMM section for the reason). Only the Overall cohort ",
      "is answered below."),
      "Q1-Q6 (NDMM): unavailable this run")

  for (co in cohorts) {
    tag <- co$tag; ll <- co$lot_long
    # "Q1: ..." -> "Q1 (NDMM): ..."; also handles range titles ("Q3-Q5: ...").
    qt <- function(t) sub("^(Q[0-9]+(-Q[0-9]+)?)", paste0("\\1 (", tag, ")"), t)
    log_msg("  [Exploratory] cohort pass: ", tag, " (", ll, ")")

    # Q1 --------------------------------------------------------------------
    tryCatch({
      q1 <- vqs_q1_exclusion_agents(con, ll, tokens)
      save_table(q1, section = SEC_EXPL,
                 title = qt("Q1: LOT1 regimens with pomalidomide / elotuzumab / panobinostat"))
    }, error = function(e) log_msg("  [Exploratory/", tag, "] Q1 failed: ", conditionMessage(e)))

    # Q3 / Q4 / Q5 (steroid timing) - need the steroid_codes.csv signal ------
    if (!is.null(ster_src)) {
      tryCatch({
        q3 <- vqs_steroid_windows(con, ll, ster_src, lot_num = 1L, w = VQS_W1)
        save_table(q3, section = SEC_EXPL, title = qt(paste0(
          "Q3: LOT1 no-steroid patients - steroid before/after induction (n=",
          attr(q3, "line_without_steroid"), " of ", attr(q3, "line_patients"), ")")))
        # "who" (patient-level, full-only via "sample"); capped for the HTML.
        q3p <- vqs_steroid_windows_patients(con, ll, ster_src, lot_num = 1L, w = VQS_W1, limit = 500L)
        if (!is.null(q3p) && nrow(q3p) > 0)
          save_table(q3p, section = SEC_EXPL,
                     title = qt("Q3: LOT1 no-steroid patients - who got a steroid in-window (sample, max 500)"))
      }, error = function(e) log_msg("  [Exploratory/", tag, "] Q3 failed: ", conditionMessage(e)))
      tryCatch({
        q4 <- vqs_steroid_windows(con, ll, ster_src, lot_num = 2L, w = VQS_W2)
        save_table(q4, section = SEC_EXPL, title = qt(paste0(
          "Q4: LOT2 no-steroid patients - steroid before/after induction (n=",
          attr(q4, "line_without_steroid"), " of ", attr(q4, "line_patients"), ")")))
        q4p <- vqs_steroid_windows_patients(con, ll, ster_src, lot_num = 2L, w = VQS_W2, limit = 500L)
        if (!is.null(q4p) && nrow(q4p) > 0)
          save_table(q4p, section = SEC_EXPL,
                     title = qt("Q4: LOT2 no-steroid patients - who got a steroid in-window (sample, max 500)"))
      }, error = function(e) log_msg("  [Exploratory/", tag, "] Q4 failed: ", conditionMessage(e)))
      tryCatch({
        q5 <- vqs_q5_lot2_attribution(con, ll, ster_src, w1 = VQS_W1, w2 = VQS_W2)
        save_table(q5, section = SEC_EXPL,
                   title = qt("Q5: LOT2 pre-start steroid - attributable to LOT1?"))
      }, error = function(e) log_msg("  [Exploratory/", tag, "] Q5 failed: ", conditionMessage(e)))
    } else if (identical(tag, "Overall")) {
      # The steroid signal is cohort-independent (one CSV scan), so a missing
      # signal skips Q3-Q5 for BOTH cohorts - note it once, untagged.
      vqs_note_card(paste0("Q3/Q4/Q5 (steroid timing) skipped for all cohorts - ",
                           "no steroid signal. ",
                           if (!is.null(ster$note)) ster$note else ""),
                    "Q3-Q5: steroid analyses (unavailable)")
    }

    # Q2 examples (full-only: titles carry "(sample)") ----------------------
    if (have_map) {
      tryCatch({
        q2 <- vqs_q2_poma_examples(con, ll, map_tbl, tokens, n = 5L, bounds = bounds$sql)
        if (!is.null(q2$journey) && nrow(q2$journey) > 0)
          save_table(q2$journey, section = SEC_EXPL,
                     title = qt("Q2: Pomalidomide LOT1 - MAP journey examples (sample)"))
        if (!is.null(q2$raw) && nrow(q2$raw) > 0)
          save_table(q2$raw, section = SEC_EXPL,
                     title = qt("Q2: Pomalidomide LOT1 - raw claims before MAPs (sample)"))
        else
          vqs_note_card(paste0("Q2 raw-claim examples unavailable. ",
                               if (!is.null(q2$note)) q2$note else ""),
                        qt("Q2: Pomalidomide LOT1 - raw claims (sample, unavailable)"))
      }, error = function(e) log_msg("  [Exploratory/", tag, "] Q2 examples failed: ", conditionMessage(e)))
    }

    # Q6 (CAR-T) ------------------------------------------------------------
    if (have_sct) {
      tryCatch({
        q6 <- vqs_q6_cart(con, ll, sct_tbl, w1 = VQS_W1, cart_raw_tbl = cart_raw)
        save_table(q6, section = SEC_EXPL, title = qt("Q6: CAR-T prior to or during LOT1"))
      }, error = function(e) log_msg("  [Exploratory/", tag, "] Q6 failed: ", conditionMessage(e)))
      tryCatch({
        ex <- vqs_q6_cart_examples(con, ll, sct_tbl, map_tbl, n = 5L,
                                   bounds = bounds$sql, cart_raw_tbl = cart_raw)
        if (!is.null(ex$sct_raw) && nrow(ex$sct_raw) > 0)
          save_table(ex$sct_raw, section = SEC_EXPL,
                     title = qt("Q6: CAR-T prior/during LOT1 - raw SCT claims (sample)"))
        if (!is.null(ex$mma_raw) && nrow(ex$mma_raw) > 0)
          save_table(ex$mma_raw, section = SEC_EXPL,
                     title = qt("Q6: CAR-T prior/during LOT1 - raw MM claims (sample)"))
        if (!is.null(ex$journey) && nrow(ex$journey) > 0)
          save_table(ex$journey, section = SEC_EXPL,
                     title = qt("Q6: CAR-T prior/during LOT1 - MAP journey examples (sample)"))
        # Surface the example helper's note in both gap cases:
        #  - no example patients selected (carries the honest "before-LOT1 not
        #    assessed" caveat when the raw scan was unavailable), and
        #  - patients selected but the requested RAW CAR-T claims came back
        #    empty (the study team asked specifically for raw examples; don't let the
        #    MAP journey stand in silently for them).
        if (length(ex$patids) == 0)
          vqs_note_card(if (!is.null(ex$note)) ex$note else
                          "No CAR-T prior-to/during-LOT1 example patients selected.",
                        qt("Q6: CAR-T prior/during LOT1 - examples (none)"))
        else if (is.null(ex$sct_raw) || nrow(ex$sct_raw) == 0)
          vqs_note_card(paste0("Requested RAW CAR-T claim examples are unavailable",
                               if (!is.null(ex$journey) && nrow(ex$journey) > 0)
                                 " (the MAP-derived journey above is shown instead)"
                               else "", ". ",
                               if (!is.null(ex$note)) ex$note else ""),
                        qt("Q6: CAR-T prior/during LOT1 - raw SCT claims (sample, unavailable)"))
      }, error = function(e) log_msg("  [Exploratory/", tag, "] Q6 examples failed: ", conditionMessage(e)))
    }
  }
  invisible()
}

# Small note card used when a guarded example pull yields nothing, so the
# Exploratory section explains the gap rather than silently omitting it.
vqs_note_card <- function(msg, title) {
  add_html_card(paste0(
    '<div style="font-family:system-ui;padding:12px;max-width:760px">',
    '<h3 style="margin:0 0 6px">', title, '</h3>',
    '<p style="color:#a06000;font-size:13px">', msg, '</p></div>'),
    section = SEC_EXPL, title = title)
}

# ---- Summary landing page (data-driven, opens first) ----------------
# Side-by-side Overall vs NDMM headline numbers pulled straight from
# query_cohort_kpis() - no hard-coded findings. Every figure is computed
# at build time from each cohort's LOT_LONG. The NDMM column degrades to
# "n/a" when that cohort could not be built this run. Rendered as a
# self-contained html_card (sandboxed iframe), so it cannot affect the
# rest of the dashboard's navigation.
build_summary_landing <- function(kpi_overall, kpi_ndmm, ndmm_ok, run_ts,
                                   n_ster = NA, n_rules = NA, study_end = NA,
                                   n_hcpcs = NA, n_ndc = NA, n_cpt = NA,
                                   ndmm_notes = character(0)) {
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
  is_num <- function(x) !is.null(x) && length(x) == 1 && !is.na(x)
  # Steroid codelist state. The tracked CSV can ship HCPCS-only (NDC absent ->
  # oral steroids undercounted) or be missing/empty entirely (no codes at all
  # -> the steroid analyses did not run, so a "0 of N" finding must NOT read as
  # a real zero). Distinguish unavailable from HCPCS-only below.
  # steroid_state() (defined in 05) is the shared source of truth, so the
  # Summary, the overview banner and the per-cohort gate always agree - and
  # unset counts (rx/medical unreadable) collapse to "unavailable" too.
  st_steroid   <- steroid_state(n_hcpcs, n_cpt, n_ndc)
  ster_unavail <- st_steroid == "unavailable"
  codes_known  <- is_num(n_hcpcs) || is_num(n_ndc) || is_num(n_cpt)
  ster_codes <- if (ster_unavail) "none loaded"
    else if (codes_known) {
      parts <- c(if (is_num(n_hcpcs)) paste0(n_hcpcs, " HCPCS"),
                 if (is_num(n_cpt) && n_cpt > 0) paste0(n_cpt, " CPT"),
                 if (is_num(n_ndc)) paste0(n_ndc, " NDC"))
      if (length(parts) == 0) or_na(n_ster) else paste(parts, collapse = " + ")
    } else or_na(n_ster)
  # NDMM gate status: built / built with warnings (configured gates skipped) /
  # unavailable - so a degraded run cannot look fully valid on the landing page.
  ndmm_status <- if (!has_n) "unavailable"
    else if (length(ndmm_notes) > 0) "built with warnings"
    else "built"

  warn_box <- function(html) paste0(
    '<div style="margin-top:12px;padding:10px 12px;background:#FFF7ED;',
    'border:1px solid #FED7AA;border-left:4px solid #EA8C00;border-radius:8px;',
    'font-size:12.5px;color:#7c4a03">', html, '</div>')
  alert_box <- function(html) paste0(
    '<div style="margin-top:12px;padding:10px 12px;background:#FEF2F2;',
    'border:1px solid #FECACA;border-left:4px solid #DC2626;border-radius:8px;',
    'font-size:12.5px;color:#7f1d1d">', html, '</div>')
  # Unavailable (no usable codes / inputs unreadable) is a red alert and
  # suppresses steroid findings; procedure-only (HCPCS/CPT present, no NDC)
  # keeps findings with an amber undercount caveat.
  ster_warn <- if (ster_unavail) alert_box(paste0(
      '<b>Steroid codelist unavailable.</b> No usable steroid codes were ',
      'loaded (<code>steroid_codes.csv</code> missing/empty/unreadable, or the ',
      'rx/medical inputs were unreadable), so the steroid analyses did not run ',
      '&mdash; steroid findings are omitted here rather than shown as a real ',
      'zero. Supply a valid codelist and re-run.'))
    else if (st_steroid == "procedure_only") warn_box(paste0(
      '<b>Steroid codelist has 0 NDC codes.</b> Oral pharmacy steroids are ',
      'undercounted &mdash; steroid figures here reflect ',
      '<b>procedure-code (HCPCS/CPT)-observed</b> claims only. Replace ',
      '<code>steroid_codes.csv</code> with an NDC-complete file before ',
      'stakeholder distribution.'))
    else ""
  ndmm_warn <- if (has_n && length(ndmm_notes) > 0) warn_box(paste0(
    '<b>NDMM built with warnings.</b> One or more configured NDMM gates were ',
    'skipped this run (a required source was unavailable), so the NDMM cohort ',
    'is broader than the full specification:<ul style="margin:6px 0 0;padding-left:18px">',
    paste(vapply(as.character(ndmm_notes),
                 function(x) paste0("<li>", x, "</li>"), character(1)), collapse = ""),
    '</ul>')) else ""

  dq <- paste0(
    '<div style="margin-top:16px;padding:10px 12px;background:#F7F8FA;',
         'border:1px solid #E5E7EB;border-radius:8px;font-size:12px;color:#6B7280">',
    '<b style="color:#2A2A33">Run &amp; data quality</b>',
    ' &nbsp;&bull;&nbsp; Study end ',      or_na(study_end),
    ' &nbsp;&bull;&nbsp; Steroid codes: ', ster_codes,
    ' &nbsp;&bull;&nbsp; Category rules ', or_na(n_rules),
    ' &nbsp;&bull;&nbsp; Generated ',      run_ts,
    ' &nbsp;&bull;&nbsp; Overall: ', if (has_o) 'built' else 'unavailable',
    ' &nbsp;&bull;&nbsp; NDMM: ', ndmm_status,
    '</div>')

  # Optional stakeholder-ask findings recorded by the steroid/payer builders -
  # the exact numbers shown in their detail views, reused here, grouped by
  # cohort (Overall then NDMM). Failsafe: any problem yields an empty panel.
  findings_html <- tryCatch({
    all_f <- if (exists("dashboard_findings")) dashboard_findings else list()
    # No steroid-finding suppression needed here: build_steroid_section() gates
    # at record time per cohort, so a steroid finding only exists when THAT
    # cohort's steroids were available. (Suppressing on the global state would
    # wrongly drop valid Overall findings if a later NDMM pass cleared it.)
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
    '<b>NDMM</b> is the 1L newly-diagnosed subset (inclusion/exclusion gates applied; ',
    'any skipped gates are flagged below). ',
    'All figures are computed at build time from each cohort&rsquo;s LOT_LONG ',
    '&mdash; nothing here is hard-coded.',
  '</p>',
  stat_band,
  '<table style="border-collapse:collapse;width:100%;font-size:14px">',
    '<thead><tr>',
      '<th style="text-align:left;padding:8px 14px;border-bottom:2px solid #F36633;',
        'font-size:12px;text-transform:uppercase;letter-spacing:.04em;color:#6B7280">Metric</th>',
      '<th style="text-align:right;padding:8px 14px;border-bottom:2px solid #F36633;',
        'color:#0E7C7B">Overall</th>',
      '<th style="text-align:right;padding:8px 14px;border-bottom:2px solid #F36633;',
        'color:#D24E1F">NDMM</th>',
    '</tr></thead>',
    '<tbody>', body, '</tbody>',
  '</table>',
  ndmm_note,
  ster_warn,
  ndmm_warn,
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
COHORT_ORDER <- c("Summary", "Overall", "NDMM", "Exploratory analysis")
BUCKET_ORDER <- c("Summary", "Cohort & attrition", "Treatment patterns",
                  "Steroids & payer", "Exploratory", "Patient explorer",
                  "Validation", "Debug", "Other")

classify_item <- function(title) {
  # Rule order matters. Anchored internal prefixes are matched FIRST so a
  # debug/validation view whose title happens to contain "sample" stays in
  # its bucket. Then a catch-all routes any remaining raw patient-example /
  # sample table (notably the "Steroids: ... examples (sample)" and
  # "... - example patients" tables) into the full-only Patient explorer,
  # BEFORE the stakeholder Steroids/Treatment rules can claim it - so no
  # raw PATID table leaks into the stakeholder view. Aggregate steroid
  # summaries (prevalence, before/same/after, mean lead time) have no
  # example/sample marker and stay stakeholder.
  rules <- list(
    c("^Executive summary",                                  "Summary",            "stakeholder"),
    c("^(Examples|MED JOURNEY): ",                           "Patient explorer",   "full"),
    c("^(Validation|QC): ",                                  "Validation",         "full"),
    c("^(DEBUG|DRILLDOWN): ",                                "Debug",              "full"),
    c("[Ee]xample|[Ss]ample",                                "Patient explorer",   "full"),
    c("^(KPI snapshot|Overview & cohort)",                   "Cohort & attrition", "stakeholder"),
    c("^(Attrition|OVERVIEW|FUNNEL): ",                      "Cohort & attrition", "stakeholder"),
    c(paste0("^(Transitions|START_TYPE|END_REASON|LENGTH|REGIMENS|",
             "PROGRESSION|GAPS|TRANSITIONS|SANKEY|MEDCOUNT|MTX|TREND): "),
                                                             "Treatment patterns", "stakeholder"),
    c("^(Steroids|Payer): ",                                 "Steroids & payer",   "stakeholder"),
    # Exploratory objective (study-team validation Q1-Q6). Reached only after
    # the example/sample rule above, so Q2/Q6 "(sample)" tables still route to
    # the full-only Patient explorer; the Q-summary + intro stay stakeholder.
    c("^(About this section|Q[0-9]|Exploratory)",            "Exploratory",        "stakeholder")
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
  # Capture the Overall pass's steroid codelist state now, before the NDMM pass
  # can overwrite or clear() the global cfg$steroid_*_count. The Summary (built
  # last) reports this rather than the final global state, so a degraded NDMM
  # pass cannot make valid Overall steroid evidence read as "unavailable".
  ster_hcpcs_sum <- cfg$steroid_hcpcs_count
  ster_cpt_sum   <- cfg$steroid_cpt_count
  ster_ndc_sum   <- cfg$steroid_ndc_count
  kpi_overall <- build_cohort_kpis(con, wrk("LOT_LONG"), section = "Overall",
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
  ndmm_notes <- character(0)
  # Checkpoint the collector lengths so a late NDMM builder failure can roll
  # back any partial NDMM cards/findings appended before it - otherwise the
  # Summary (which renders recorded findings) and the NDMM pill could show
  # partial NDMM content beside an "unavailable" status.
  ndmm_items0 <- length(dashboard_items)
  ndmm_find0  <- length(dashboard_findings)
  ndmm_ok <- tryCatch({
    p_ndmm <- prepare_ndmm_cohort(con)
    ndmm_notes <- if (!is.null(p_ndmm$overview_notes)) p_ndmm$overview_notes
                  else character(0)
    kpi_ndmm <- build_cohort_kpis(con, NDMM_LOT_LONG_FILT, section = "NDMM",
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
    # Roll back any partial NDMM items/findings appended before the failure so
    # an unavailable NDMM never shows stale partial content (only the card below).
    if (length(dashboard_items) > ndmm_items0)
      dashboard_items <<- dashboard_items[seq_len(ndmm_items0)]
    if (length(dashboard_findings) > ndmm_find0)
      dashboard_findings <<- dashboard_findings[seq_len(ndmm_find0)]
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

  # ---- Exploratory objective (study-team validation Q1-Q6) ----
  # Ad-hoc study-team questions, answered once per cohort (Overall always;
  # NDMM when its pass succeeded - ndmm_ok gates the NDMM answers); placed in
  # their own cohort pill per the study team's request. Guarded so a failure
  # can't sink the dashboard.
  log_msg("==== Building EXPLORATORY objective views ====")
  tryCatch(build_validation_exploratory(con, ndmm_ok = ndmm_ok), error = function(e) {
    log_msg("  WARN: Exploratory objective could not be built: ", conditionMessage(e))
    add_html_card(paste0(
      '<div style="font-family:system-ui;padding:14px;max-width:900px">',
      '<h3>Exploratory analysis - not available</h3>',
      '<p style="color:#a06000;font-size:13px">The study-team validation ',
      'questions could not be built in this run:</p>',
      '<pre style="font-size:12px;background:#f7f7f7;padding:8px;border-radius:6px;',
      'white-space:pre-wrap">', conditionMessage(e), '</pre></div>'),
      section = SEC_EXPL, title = "About this section")
  })

  # ---- Summary landing page + nav structuring ----
  # Built last (it needs both cohorts' KPIs); tag_and_order() then assigns
  # every item a bucket + audience and stable-sorts the whole list into
  # (cohort, bucket) order, so the Summary leads and each cohort reads
  # top-down (cohort & attrition -> treatment -> steroids & payer ->
  # internal). The Exploratory cohort (study-team validation Q1-Q6) was built
  # just above and sorts after NDMM via COHORT_ORDER.
  build_summary_landing(kpi_overall, kpi_ndmm, ndmm_ok, run_ts_combined,
                        n_ster = p_overall$n_ster, n_rules = p_overall$n_rules,
                        study_end = cfg$study_end,
                        n_hcpcs = ster_hcpcs_sum,
                        n_ndc   = ster_ndc_sum,
                        n_cpt   = ster_cpt_sum,
                        ndmm_notes = ndmm_notes)
  tag_and_order()

  build_dashboard(
    out_name     = "combined_dashboard.html",
    header_title = "MM LOT &mdash; combined (Overall + NDMM + Exploratory)",
    header_sub   = paste0("Summary &bull; Overall &bull; NDMM",
                          if (!ndmm_ok) " (unavailable)" else "",
                          " &bull; Exploratory"),
    cohort_sections = c("Summary", "Overall", "NDMM", "Exploratory analysis")
  )
  log_msg("Wrote ", file.path(cfg$output_dir, "combined_dashboard.html"))
}

if (!interactive() && !isTRUE(getOption("combined_dashboard.no_autorun")))
  main_combined()
