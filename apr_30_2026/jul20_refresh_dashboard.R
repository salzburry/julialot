#!/usr/bin/env Rscript
# July-20 refresh of the regimen dashboards: same dashboard, steroids removed,
# plus an "All regimens" section with a downloadable long list per LOT.
#
#   LOT_COHORT=NDMM    Rscript jul20_refresh_dashboard.R   (default)
#   LOT_COHORT=OVERALL Rscript jul20_refresh_dashboard.R
#
# A standalone wrapper around the existing dashboards (neither is modified):
# it sources 06_ndmm_dashboard.R with its no-autorun option (which itself
# sources 05_regimen_dashboard.R) and rebuilds the matching dashboard,
# section for section and in the same order, with exactly the two requested
# changes and nothing else:
#
#   REMOVED  - the steroid augmentation (LOT_BASE_MEDS_AUG is a passthrough of
#              the engine's LOT_BASE_MEDS, which never contains a steroid), so
#              every regimen string in every Sankey / table is steroid-free;
#   REMOVED  - the STEROIDS section (prevalence / missing-steroid / timing QC);
#   ADDED    - an "All regimens" section: every regimen per LOT (no top-N cut),
#              displayed in the same modal/clinical order the current dashboard
#              uses, downloadable from each table's CSV button and also written
#              as one CSV file per LOT next to the dashboard.
#
# NDMM mode (default - the cohort the July-20 questions name, and the same
# default as the sibling jul20_studyteam_qs.R) mirrors 06_ndmm_dashboard.R:
# KPI snapshot, the NDMM overview card with the six-filter funnel, the NDMM
# attrition table + waterfall, the other-cancer drop / override QC, payer,
# LOT-pair regimen Sankeys, category Sankeys + coverage, all regimens,
# patient gallery, and validation with the NDMM filter flags. Because this
# refresh writes no permanent tables, it does NOT re-derive the cohort:
#
#   - it READS the persisted NDMM_LOT_LONG_FILT and NDMM_FLAGS_ALL from the
#     last production 06_ndmm_dashboard.R run and rebinds them as the session
#     views the builders expect; it stops with a remediation message if
#     either is missing;
#   - the funnel/attrition counts are recomputed from those persisted flags
#     (same queries as 06); a per-filter status table shows how many patients
#     each flag excluded, with the caveat that a flag excluding zero patients
#     is either genuinely non-excluding or was skipped in the producing run
#     (skips are recorded in that run's own dashboard and log);
#   - the other-cancer QC needs the claim-scan views; they are rebuilt here
#     as session temp views when med_diagnosis / medical / confinement and
#     the other-malignancy codelist are readable, else the QC degrades to a
#     visible note explaining it is a refresh limitation, not a filter skip;
#   - a consistency check compares the persisted flags-derived NDMM count to
#     the persisted filtered LOT table and flags any mismatch prominently
#     (a mismatch means the two persisted tables come from different runs).
#
# OVERALL mode mirrors 05_regimen_dashboard.R: KPI snapshot, overview,
# parent-cohort attrition, payer, Sankeys, category views, all regimens,
# gallery, validation.
#
# Both modes keep the current regimen display order (REGIMEN_MODAL_MAP via
# build_modal_map), so the only visible regimen difference vs the current
# dashboards is the absence of steroid tokens. Two deliberate departures,
# both surfaced on the dashboard itself: the run-comparison view is omitted
# (it appends rows to the permanent lot_dashboard_run_summary table, and this
# script writes no permanent tables), and a steroid audit table is added to
# the Validation section proving no known steroid token occurs in any LOT
# regimen string.
#
# Run sequence for the July-20 pair (state the cohort explicitly when sending
# run instructions; do not rely on defaults):
#   LOT_COHORT=NDMM Rscript jul20_refresh_dashboard.R
#   LOT_COHORT=NDMM Rscript jul20_studyteam_qs.R
#
# Output: regimen_dashboard_refresh_ndmm.html (or _overall.html) in
# cfg$output_dir, plus jul20_all_regimens_lot<N>_<cohort>_<stamp>.csv files.
# Writes no permanent tables (only session temp views). Safe to run any time.

.script_dir <- local({
  args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", args, value = TRUE)
  if (length(file_arg) > 0)
    return(dirname(normalizePath(sub("^--file=", "", file_arg[1]))))
  for (i in seq_len(sys.nframe())) {
    ofile <- tryCatch(sys.frame(i)$ofile, error = function(e) NULL)
    if (!is.null(ofile)) return(dirname(normalizePath(ofile)))
  }
  getwd()
})

# Source the existing NDMM dashboard WITHOUT running it; it sources the
# overall regimen dashboard (05) itself, so all shared helpers, builders,
# palettes and both dashboards' section builders arrive through it.
options(ndmm_dashboard.no_autorun = TRUE,
        ndmm_dashboard.script_dir = .script_dir,
        regimen_dashboard.no_autorun = TRUE,
        regimen_dashboard.script_dir = .script_dir)
source(file.path(.script_dir, "06_ndmm_dashboard.R"))

`%||%` <- function(a, b) if (is.null(a)) b else a

# The steroid short-codes used across the repo's codelists; the audit checks
# regimens against this fixed list (same list as the July-11 Q1 audit).
AUDIT_STEROID_TOKENS <- c("DEX", "DEXA", "DEXAMETHASONE", "DEXAMETH",
                          "PRED", "PREDNISONE", "PREDNISOLONE",
                          "METHYLPRED", "METHYLPREDNISOLONE", "MPRED")

# ===========================================================================
# The new section: every regimen per LOT, one table per line, in the same
# display order the rest of the dashboard uses (modal start-order, clinical
# fallback). Counting stays on the canonical alphabetical LOT_BASE_MEDS key;
# display_regimen is display-only. Each table is downloadable via its CSV
# button, and the full list is also written as a CSV file per LOT.
# ===========================================================================
build_all_regimens_section <- function(con, lot_long, out_dir, stamp,
                                       cohort_tag,
                                       section = "All regimens") {
  denom <- db_q(con, glue("
    SELECT LOT_NUM, count(DISTINCT cast(PATID as string)) AS n_patients
    FROM {lot_long} GROUP BY LOT_NUM ORDER BY LOT_NUM"))
  if (nrow(denom) == 0) {
    add_html_card(paste0(
      '<div style="font-family:system-ui;padding:12px;max-width:760px">',
      '<h3>All regimens unavailable</h3><p style="color:#555;font-size:13px">',
      'No LOT rows were found in <code>', esc_html(lot_long), '</code>.</p></div>'),
      section = section, title = "All regimens (unavailable)")
    return(invisible(NULL))
  }

  all_reg <- db_q(con, glue("
    WITH l AS (
      SELECT LOT_NUM, cast(PATID as string) AS PATID,
             CASE WHEN LOT_BASE_MEDS IS NULL OR trim(LOT_BASE_MEDS) = ''
                  THEN concat('(no drug regimen - ',
                              coalesce(LOT_START_TYPE, 'unknown'), ' start)')
                  ELSE LOT_BASE_MEDS END AS regimen,
             CASE WHEN LOT_BASE_MEDS IS NULL OR trim(LOT_BASE_MEDS) = ''
                  THEN 0 ELSE 1 END AS is_drug_regimen
      FROM {lot_long}
    )
    SELECT LOT_NUM, regimen, max(is_drug_regimen) AS is_drug_regimen,
           count(DISTINCT PATID) AS n_patients,
           count(*)              AS n_lines
    FROM l GROUP BY LOT_NUM, regimen
    ORDER BY LOT_NUM, n_patients DESC, regimen"))

  denom_map <- setNames(as.numeric(denom$n_patients),
                        as.character(as.integer(as.numeric(denom$LOT_NUM))))

  for (ln in sort(unique(as.integer(as.numeric(all_reg$LOT_NUM))))) {
    d <- all_reg[as.integer(as.numeric(all_reg$LOT_NUM)) == ln, , drop = FALSE]
    dn <- denom_map[[as.character(ln)]] %||% NA_real_
    disp <- as.character(d$regimen)
    is_drug <- as.numeric(d$is_drug_regimen) == 1
    disp[is_drug] <- disp_regimen(disp[is_drug])
    df <- data.frame(
      rank             = seq_len(nrow(d)),
      display_regimen  = disp,
      regimen_key      = as.character(d$regimen),
      n_patients       = as.integer(as.numeric(d$n_patients)),
      pct_of_line      = ifelse(rep(isTRUE(dn > 0), nrow(d)),
                                round(100 * as.numeric(d$n_patients) / dn, 1),
                                NA_real_),
      n_lines          = as.integer(as.numeric(d$n_lines)),
      stringsAsFactors = FALSE)

    f <- file.path(out_dir, paste0("jul20_all_regimens_lot", ln, "_",
                                   cohort_tag, "_", stamp, ".csv"))
    ok <- isTRUE(tryCatch({ write.csv(df, f, row.names = FALSE); TRUE },
                          error = function(e) {
                            log_msg("  WARN: could not write ", f, " - ",
                                    conditionMessage(e))
                            FALSE
                          }))
    if (ok) log_msg("  wrote all-regimens LOT", ln, " -> ", f,
                    " (", nrow(df), " rows)")

    save_table(df, section = section,
               title = paste0("LOT", ln, " - all regimens (", nrow(df),
                              " distinct; every row, no top-N cut)"))
  }

  denom_df <- data.frame(line = paste0("LOT", as.integer(as.numeric(denom$LOT_NUM))),
                         n_line_patients = as.integer(as.numeric(denom$n_patients)),
                         stringsAsFactors = FALSE)
  save_table(denom_df, section = section,
             title = "Per-line patient denominators (behind pct_of_line)")

  add_html_card(paste0(
    '<div style="font-family:system-ui;padding:12px;max-width:860px">',
    '<h3 style="margin:0 0 6px">Reading these lists</h3>',
    '<p style="color:#555;font-size:13px">One table per line of therapy, every ',
    'regimen string included. <code>display_regimen</code> uses the same ',
    'most-common real-world agent order as the rest of this dashboard; ',
    '<code>regimen_key</code> is the engine&#39;s canonical alphabetical form ',
    'that the counts group on. Transplant / CAR-T-only lines appear as a ',
    'labelled &quot;(no drug regimen ...)&quot; row so each list reconciles to ',
    'its line denominator. Steroids never enter these strings. Use each ',
    'table&#39;s CSV button to download the full list, or take the ',
    'per-LOT CSV files written next to this dashboard.</p></div>'),
    section = section, title = "About the all-regimens lists")

  invisible(denom_df)
}

# ===========================================================================
# Steroid audit for the Validation section: no known steroid token should
# occur in any LOT regimen string (the engine excludes steroids from LOT
# membership by construction; this proves it on the data being displayed).
# ===========================================================================
build_steroid_audit_table <- function(con, lot_long, section = "Validation") {
  ster_arr <- paste(sprintf("'%s'", AUDIT_STEROID_TOKENS), collapse = ", ")
  audit <- tryCatch(db_q(con, glue("
    WITH ll AS (
      SELECT filter(split(LOT_BASE_MEDS, ' '), x -> length(x) > 0) AS meds
      FROM {lot_long}
      WHERE LOT_BASE_MEDS IS NOT NULL AND trim(LOT_BASE_MEDS) <> ''
    )
    SELECT count(*) AS n_lot_regimen_rows,
           sum(CASE WHEN size(array_intersect(meds, array({ster_arr}))) > 0
                    THEN 1 ELSE 0 END) AS n_rows_with_steroid_token
    FROM ll")), error = function(e) NULL)
  if (is.null(audit) || nrow(audit) == 0) {
    add_html_card(paste0(
      '<div style="font-family:system-ui;padding:12px;max-width:760px">',
      '<h3>Steroid audit unavailable</h3><p style="color:#555;font-size:13px">',
      'The steroid-in-regimen audit query could not run; the regimen strings ',
      'are still built steroid-free by the engine, but this run could not ',
      're-verify it.</p></div>'),
      section = section, title = "Steroid audit (unavailable)")
    return(invisible(NULL))
  }
  hits <- suppressWarnings(as.integer(as.numeric(audit$n_rows_with_steroid_token[1])))
  save_table(audit, section = section,
             title = paste0("Steroid audit - steroid tokens in any LOT regimen ",
                            "(expected 0",
                            if (isTRUE(hits > 0)) "; FAILED - investigate" else "",
                            ")"))
  if (isTRUE(hits > 0))
    log_msg("WARNING: steroid audit FAILED - ", hits,
            " regimen row(s) contain a steroid token.")
  invisible(hits)
}

# ===========================================================================
# NDMM helpers for the read-only refresh: rebind the session views the 06
# builders expect onto the PERSISTED tables from the last production NDMM
# run, and derive filter-status evidence from the flags themselves.
# ===========================================================================
ndmm_bind_persisted_views <- function(con) {
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_FLAGS_ALL} AS
    SELECT * FROM {wrk(NDMM_FLAGS_ALL_TBL)}"))
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_LOT_LONG_FILT} AS
    SELECT * FROM {wrk(NDMM_LOT_LONG_FILT_TBL)}"))
  # Same final-selection predicate 06 uses when it builds NDMM_PATIDS.
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_PATIDS} AS
    SELECT PATID FROM {NDMM_FLAGS_ALL}
    WHERE CE_pre_lot1_12mo        = 1
      AND NO_BELANTAMAB           = 1
      AND NO_PRIOR_MM_TX          = 1
      AND NO_OTHER_CANCER_PRE_LOT1 = 1
      AND CE_lot1_3mo_fu          = 1
      AND NO_PREGNANCY            = 1"))
  invisible(TRUE)
}

# Per-filter exclusion counts from the persisted flags. A filter excluding
# zero patients is either genuinely non-excluding or was skipped in the
# producing run (a skipped filter passes all patients); the producing run's
# own dashboard/log records which.
ndmm_filter_status <- function(con) {
  d <- db_q(con, glue("
    SELECT count(*) AS n_flag_rows,
           sum(CASE WHEN CE_pre_lot1_12mo         = 0 THEN 1 ELSE 0 END) AS x_ce12,
           sum(CASE WHEN NO_BELANTAMAB            = 0 THEN 1 ELSE 0 END) AS x_bela,
           sum(CASE WHEN NO_PRIOR_MM_TX           = 0 THEN 1 ELSE 0 END) AS x_priortx,
           sum(CASE WHEN NO_OTHER_CANCER_PRE_LOT1 = 0 THEN 1 ELSE 0 END) AS x_othercancer,
           sum(CASE WHEN CE_lot1_3mo_fu           = 0 THEN 1 ELSE 0 END) AS x_fuce,
           sum(CASE WHEN NO_PREGNANCY             = 0 THEN 1 ELSE 0 END) AS x_preg
    FROM {NDMM_FLAGS_ALL}"))
  n <- function(x) as.integer(as.numeric(x))
  df <- data.frame(
    ndmm_filter = c("12-mo CE pre-LOT1", "No belantamab in any LOT",
                    "No MM oncology Tx in 12-mo pre-LOT1",
                    "No other active cancer in 12-mo pre-LOT1",
                    "3-mo follow-up CE (from LOT1)", "No pregnancy"),
    n_patients_failing = c(n(d$x_ce12[1]), n(d$x_bela[1]), n(d$x_priortx[1]),
                           n(d$x_othercancer[1]), n(d$x_fuce[1]), n(d$x_preg[1])),
    stringsAsFactors = FALSE)
  df$note <- ifelse(df$n_patients_failing == 0,
    "0 failures: either genuinely non-excluding, or the filter was skipped in the producing run (see that run's dashboard/log)",
    "")
  df
}

# Rebuild the session views the other-cancer QC reads (temp views only; the
# expensive scan runs when the QC queries them). Returns TRUE on success.
ndmm_rebuild_other_cancer_views <- function(con) {
  med_diag_tbl    <- cdm_src(cfg$tbl_med_diag)
  medical_tbl     <- cdm_src(cfg$tbl_medical)
  confinement_tbl <- cdm_src(NDMM_TBL_CONFINEMENT)
  ok <- function(t) isTRUE(tryCatch(
    nrow(db_q(con, glue("SELECT 1 FROM {t} LIMIT 1"))) >= 0,
    error = function(e) FALSE))
  if (!(ok(med_diag_tbl) && ok(medical_tbl) && ok(confinement_tbl)))
    return(FALSE)
  isTRUE(tryCatch({
    build_ndmm_other_malig_codes(con)
    build_ndmm_med_claim_header_and_confinement(con, medical_tbl, confinement_tbl)
    build_ndmm_other_malig_pre_lot1(con, med_diag_tbl)
    TRUE
  }, error = function(e) {
    log_msg("  WARN: other-cancer QC views could not be rebuilt (",
            conditionMessage(e), ") - the QC will show as unavailable.")
    FALSE
  }))
}

# ===========================================================================
main_refresh <- function() {
  stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")
  cfg$build_dashboard <<- TRUE

  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn,
                        pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  out_dir <- cfg$output_dir
  if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  stamp <- format(Sys.time(), "%Y%m%d_%H%M%S")

  # NDMM by default, matching jul20_studyteam_qs.R so the July-20 pair always
  # runs on one population unless the cohort is overridden explicitly.
  cohort_mode <- toupper(Sys.getenv("LOT_COHORT", unset = "NDMM"))
  if (cohort_mode %in% c("OVERALL", "FULL")) cohort_mode <- "OVERALL"
  else cohort_mode <- "NDMM"

  readable <- function(t) isTRUE(tryCatch(
    nrow(db_q(con, glue("SELECT 1 FROM {t} LIMIT 1"))) >= 0,
    error = function(e) FALSE))

  log_msg(SEP)
  log_msg("July-20 regimen dashboard refresh [", cohort_mode,
          "] - steroid-free + all-regimen downloads")
  log_msg(SEP)

  if (cohort_mode == "NDMM") {
    # ---- NDMM: mirror 06_ndmm_dashboard.R from the persisted cohort ------
    if (!readable(wrk(NDMM_LOT_LONG_FILT_TBL)) ||
        !readable(wrk(NDMM_FLAGS_ALL_TBL)))
      stop("Cannot read ", wrk(NDMM_LOT_LONG_FILT_TBL), " and/or ",
           wrk(NDMM_FLAGS_ALL_TBL), ". This refresh reads the persisted NDMM ",
           "cohort - run 06_ndmm_dashboard.R first, or set LOT_COHORT=OVERALL ",
           "for the overall-cohort refresh.")
    ndmm_bind_persisted_views(con)
    lot_view   <- NDMM_LOT_LONG_FILT
    cohort_tag <- "ndmm"
    out_name   <- "regimen_dashboard_refresh_ndmm.html"

    # Funnel counts from the persisted flags (same queries as 06); the LOT1
    # starts view they need is a cheap projection of LOT_LONG.
    lot_long_full <- wrk("LOT_LONG")
    elig_tbl <- wrk(NDMM_FINAL_TABLE_NAME)
    counts <- NULL
    if (readable(lot_long_full) && readable(elig_tbl)) {
      counts <- tryCatch({
        build_lot1_starts_ndmm(con, lot_long_full)
        ndmm_counts(con, lot_long_full, elig_tbl)
      }, error = function(e) {
        log_msg("  WARN: NDMM funnel counts unavailable (", conditionMessage(e), ")")
        NULL
      })
    } else {
      log_msg("  WARN: ", lot_long_full, " or ", elig_tbl,
              " unreadable - NDMM funnel counts unavailable.")
    }

    filter_status <- tryCatch(ndmm_filter_status(con), error = function(e) NULL)

    # Consistency: the flags-derived final count must match the persisted
    # filtered LOT table; a mismatch means the two tables come from
    # different runs and the refresh should not be trusted until 06 re-runs.
    n_filt <- as.numeric(db_q(con, glue(
      "SELECT count(DISTINCT cast(PATID as string)) AS n FROM {lot_view}"))$n[1])
    n_flags_final <- as.numeric(db_q(con, glue(
      "SELECT count(DISTINCT PATID) AS n FROM {NDMM_PATIDS}"))$n[1])
    tables_in_sync <- isTRUE(n_filt == n_flags_final)
    if (!tables_in_sync)
      log_msg("WARNING: persisted NDMM tables look OUT OF SYNC - ",
              "NDMM_LOT_LONG_FILT has ", n_filt, " patients but the flags ",
              "select ", n_flags_final, ". Re-run 06_ndmm_dashboard.R.")

    # Steroid augmentation BYPASSED: n_codes = 0 builds LOT_LONG_AUG as a
    # plain passthrough temp view and returns before materialization, so the
    # persisted REGIMEN_LOT_LONG_AUG of the production dashboards is never
    # touched.
    clear_steroid_counts()
    augment_lot_long(con, lot_view,
                     cdm_src(cfg$tbl_rx), cdm_src(cfg$tbl_medical), 0L)
    REGIMEN_MODAL_MAP <<- build_modal_map(con, lot_view)
    lookups <- load_categories()
    n_rules <- length(lookups$lookup_1L) + length(lookups$lookup_2L)

    qc_views_ok <- ndmm_rebuild_other_cancer_views(con)

    # ---- Build: 06's sections minus steroids, plus all regimens ----------
    dashboard_items <<- list()
    build_cohort_kpis(con, lot_view, section = "OVERVIEW")

    refresh_notes <- c(
      paste0("<b>July-20 refresh</b>: steroid views removed and the steroid ",
             "display augmentation bypassed - regimen strings come straight ",
             "from the engine&#39;s steroid-free <code>LOT_BASE_MEDS</code> ",
             "(see the steroid audit under Validation). An All-regimens ",
             "section with CSV downloads is added. Everything else is the ",
             "existing NDMM dashboard content."),
      paste0("This refresh READS the persisted <code>",
             wrk(NDMM_LOT_LONG_FILT_TBL), "</code> / <code>",
             wrk(NDMM_FLAGS_ALL_TBL), "</code> from the last production ",
             "06_ndmm_dashboard.R run; it does not re-derive the filters. ",
             "Whether a filter was skipped in that run is recorded in that ",
             "run&#39;s dashboard/log - see the per-filter status table."),
      if (!tables_in_sync)
        paste0("<b>WARNING: the persisted NDMM tables look out of sync</b> (",
               format(n_filt, big.mark = ","), " patients in the filtered LOT ",
               "table vs ", format(n_flags_final, big.mark = ","),
               " selected by the flags). Re-run 06_ndmm_dashboard.R before ",
               "trusting this refresh.") else NULL)

    if (!is.null(counts)) {
      build_ndmm_overview_card(counts, 0L, n_rules, notes = refresh_notes)
      build_ndmm_attrition(counts)
    } else {
      add_html_card(paste0(
        '<div style="font-family:system-ui;padding:14px;max-width:900px;',
        'background:#fff3cd;border:1px solid #d9a800;border-radius:6px;',
        'color:#5a4500"><b>NDMM funnel counts unavailable this run</b> - ',
        'the parent <code>LOT_LONG</code> / <code>ELIG_COH_FINAL</code> ',
        'tables could not be read, so the overview funnel and attrition ',
        'waterfall are omitted. The cohort itself (below) still comes from ',
        'the persisted NDMM tables. ',
        paste(refresh_notes, collapse = " "), '</div>'),
        section = "OVERVIEW", title = "NDMM overview (degraded)")
    }
    if (!is.null(filter_status))
      save_table(filter_status, section = "OVERVIEW",
                 title = "NDMM per-filter status (from the persisted flags)")

    if (qc_views_ok) {
      build_ndmm_other_cancer_qc(con)
    } else {
      add_html_card(paste0(
        '<div style="font-family:system-ui;padding:14px;max-width:900px;',
        'background:#fff3cd;border:1px solid #d9a800;border-radius:6px;',
        'color:#5a4500"><b>Other-cancer QC not rebuilt in this refresh.</b><br>',
        'The QC needs the other-malignancy claim-scan views; their source ',
        'tables or codelist were unavailable to this run. This is a refresh ',
        'limitation, not evidence the filter was skipped - the production ',
        'NDMM dashboard carries the authoritative QC.</div>'),
        section = "OVERVIEW", title = "Other-cancer drop QC (not rebuilt)")
    }

    # (STEROIDS section intentionally omitted - the July-20 request.)
    build_payer_lot_qc(con, section = "Payer")
    for (n in 1:4) build_focused_pair(con, n, n + 1L)
    for (n in 1:4) build_category_pair(con, n, n + 1L, lookups)
    build_category_coverage(con, lookups)
    build_all_regimens_section(con, lot_view, out_dir, stamp, cohort_tag)
    build_patient_gallery(con, lot_view, section = "Patient examples")
    build_validation_views(con, lot_view, section = "Validation",
                           ndmm_flags_tbl = NDMM_FLAGS_ALL)
    build_steroid_audit_table(con, lot_view, section = "Validation")
    add_html_card(paste0(
      '<div style="font-family:system-ui;padding:12px;max-width:760px">',
      '<h3>Run comparison omitted</h3><p style="color:#555;font-size:13px">',
      'The run-comparison view appends rows to the permanent ',
      '<code>lot_dashboard_run_summary</code> table. This refresh script ',
      'writes no permanent tables, so that view is left to the production ',
      'dashboard runs.</p></div>'),
      section = "Validation", title = "Run comparison (omitted by design)")

    n_final <- if (!is.null(counts)) counts$ndmm_final else n_filt
    build_dashboard(
      out_name     = out_name,
      header_title = "MM LOT &mdash; NDMM (1L newly-diagnosed) planned cohort &mdash; July-20 refresh (steroid-free)",
      header_sub   = paste0("ELIG_COH_FINAL &bull; LOT1 &ge; ", NDMM_LOT1_FROM,
                            " &bull; 12-mo CE pre-LOT1 &bull; 3-mo FU CE",
                            " &bull; no belantamab &bull; no MM Tx pre-LOT1",
                            " &bull; no other cancer pre-LOT1 &bull; no pregnancy",
                            " &bull; all regimens per LOT (CSV downloads)",
                            " &bull; ", format(n_final, big.mark = ","),
                            " patients")
    )
    log_msg("Wrote ", file.path(cfg$output_dir, out_name))

  } else {
    # ---- OVERALL: mirror 05_regimen_dashboard.R --------------------------
    lot_long   <- wrk("LOT_LONG")
    cohort_tag <- "overall"
    out_name   <- "regimen_dashboard_refresh_overall.html"
    if (!readable(lot_long))
      stop("Cannot read ", lot_long,
           ". Build the LOT pipeline (02_lot1.R / 03_lot2_5.R) first.")

    clear_steroid_counts()
    augment_lot_long(con, lot_long,
                     cdm_src(cfg$tbl_rx), cdm_src(cfg$tbl_medical), 0L)
    REGIMEN_MODAL_MAP <<- build_modal_map(con, lot_long)
    lookups <- load_categories()
    n_rules <- length(lookups$lookup_1L) + length(lookups$lookup_2L)
    log_msg("  ", n_rules, " category rules loaded; steroid augmentation bypassed.")

    dashboard_items <<- list()
    build_cohort_kpis(con, lot_long, section = "OVERVIEW")
    add_html_card(paste0(
      '<div style="font-family:system-ui;padding:14px;max-width:900px">',
      '<h3>Regimen transitions - overall cohort (July-20 refresh: steroids removed)</h3>',
      '<p style="color:#555;font-size:13px">The same regimen dashboard, rebuilt ',
      'with two changes requested on July 20 and nothing else:</p>',
      '<ul style="font-size:13px;color:#1a7a3a;margin-top:0">',
      '<li><b>Steroids removed</b>: the steroid display augmentation is bypassed ',
      'and the STEROIDS views are omitted. Regimen strings come straight from ',
      'the engine&#39;s <code>LOT_BASE_MEDS</code>, which never contains a ',
      'steroid (see the steroid audit under Validation). LOT boundaries and ',
      'counts are unchanged - steroids never entered the LOT rules.</li>',
      '<li><b>All regimens per LOT</b>: a new section lists every regimen for ',
      'each line, with a CSV download per list.</li>',
      '</ul>',
      '<p style="color:#555;font-size:13px">Category transitions (',
      n_rules, ' regimen rules loaded) and all other views are built by the ',
      'existing dashboard code, in the existing display order. ',
      'Non-progressors are dropped from the Sankeys (inner-join LOTn &rarr; ',
      'LOTn+1), as before.</p></div>'),
      section = "OVERVIEW", title = "What this refresh shows")
    build_overall_attrition(con)
    # (STEROIDS section intentionally omitted - the July-20 request.)
    build_payer_lot_qc(con, section = "Payer")
    for (n in 1:4) build_focused_pair(con, n, n + 1L)
    for (n in 1:4) build_category_pair(con, n, n + 1L, lookups)
    build_category_coverage(con, lookups)
    build_all_regimens_section(con, lot_long, out_dir, stamp, cohort_tag)
    build_patient_gallery(con, lot_long, section = "Patient examples")
    build_validation_views(con, lot_long, section = "Validation")
    build_steroid_audit_table(con, lot_long, section = "Validation")
    add_html_card(paste0(
      '<div style="font-family:system-ui;padding:12px;max-width:760px">',
      '<h3>Run comparison omitted</h3><p style="color:#555;font-size:13px">',
      'The run-comparison view appends rows to the permanent ',
      '<code>lot_dashboard_run_summary</code> table. This refresh script ',
      'writes no permanent tables, so that view is left to the production ',
      'dashboard runs.</p></div>'),
      section = "Validation", title = "Run comparison (omitted by design)")

    build_dashboard(
      out_name     = out_name,
      header_title = "MM LOT &mdash; Regimen transitions (overall cohort) &mdash; July-20 refresh (steroid-free)",
      header_sub   = paste0("Steroid-free regimens &bull; LOT-pair Sankeys ",
                            "&bull; By category &bull; All regimens per LOT ",
                            "(CSV downloads)")
    )
    log_msg("Wrote ", file.path(cfg$output_dir, out_name))
  }
}

if (!interactive() && !isTRUE(getOption("jul20_refresh_dashboard.no_autorun"))) {
  main_refresh()
}
