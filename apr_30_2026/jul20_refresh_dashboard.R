#!/usr/bin/env Rscript
# July-20 refresh of the regimen dashboard: same dashboard, steroids removed,
# plus an "All regimens" section with a downloadable long list per LOT.
#
#   Rscript jul20_refresh_dashboard.R
#
# A standalone wrapper around 05_regimen_dashboard.R (which is NOT modified).
# It sources 05 with its no-autorun option and rebuilds the same dashboard,
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
# Everything else is the existing dashboard, built by 05's own builders:
# KPI snapshot, overview, cohort attrition, payer split, LOT-pair regimen
# Sankeys, category Sankeys + coverage, patient gallery, validation views.
# Regimen display order is unchanged (REGIMEN_MODAL_MAP via build_modal_map),
# so the only visible regimen difference vs the current dashboard is the
# absence of steroid tokens.
#
# Two deliberate departures, both surfaced on the dashboard itself:
#   - The run-comparison view is omitted: it appends rows to the permanent
#     <work>.lot_dashboard_run_summary table, and this answer script writes
#     no permanent tables. A note card marks the omission.
#   - A steroid audit table is added to the Validation section proving that
#     no known steroid token occurs in any LOT regimen string.
#
# Cohort: the NDMM study cohort by default (NDMM_LOT_LONG_FILT) - the cohort
# the July-20 questions name, and the same default as the sibling
# jul20_studyteam_qs.R, so running the pair without env overrides always uses
# one population. Set LOT_COHORT=OVERALL (or FULL) to refresh the overall-
# cohort dashboard that 05 builds; the parent attrition card appears only in
# overall mode (it describes the parent cohort funnel, not the NDMM subset).
#
# Run sequence for the pair (state the cohort explicitly when sending run
# instructions; do not rely on defaults):
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

# Source the existing regimen dashboard WITHOUT running it. 05 sources
# load_inputs / config_lot / db_utils_lot / dashboard_lot / dashboard_validation
# itself, so all shared helpers, builders and palettes arrive through it.
options(regimen_dashboard.no_autorun = TRUE,
        regimen_dashboard.script_dir = .script_dir)
source(file.path(.script_dir, "05_regimen_dashboard.R"))

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
  if (cohort_mode %in% c("OVERALL", "FULL")) {
    cohort_mode <- "OVERALL"
    lot_long <- wrk("LOT_LONG")
    cohort_label <- "overall cohort"
    out_name <- "regimen_dashboard_refresh_overall.html"
    cohort_tag <- "overall"
  } else {
    cohort_mode <- "NDMM"
    lot_long <- wrk("NDMM_LOT_LONG_FILT")
    cohort_label <- "NDMM newly-diagnosed 1L study cohort"
    out_name <- "regimen_dashboard_refresh_ndmm.html"
    cohort_tag <- "ndmm"
  }

  log_msg(SEP)
  log_msg("July-20 regimen dashboard refresh [", cohort_label,
          "] - steroid-free + all-regimen downloads")
  log_msg(SEP)

  readable <- function(t) isTRUE(tryCatch(
    nrow(db_q(con, glue("SELECT 1 FROM {t} LIMIT 1"))) >= 0,
    error = function(e) FALSE))
  if (!readable(lot_long)) {
    if (cohort_mode == "NDMM")
      stop("Cannot read ", lot_long, ". Run 06_ndmm_dashboard.R first to persist ",
           "NDMM_LOT_LONG_FILT, or set LOT_COHORT=OVERALL for the overall cohort.")
    stop("Cannot read ", lot_long,
         ". Build the LOT pipeline (02_lot1.R / 03_lot2_5.R) first.")
  }

  # --- Setup: steroid augmentation BYPASSED --------------------------------
  # n_codes = 0 makes augment_lot_long() build LOT_LONG_AUG as a plain
  # passthrough temp view (LOT_BASE_MEDS_AUG = LOT_BASE_MEDS) and return
  # before the materialization step, so the persisted REGIMEN_LOT_LONG_AUG
  # table of the production dashboard is never touched. Every 05 builder that
  # reads LOT_LONG_AUG therefore shows the engine's steroid-free regimens.
  clear_steroid_counts()
  augment_lot_long(con, lot_long,
                   cdm_src(cfg$tbl_rx), cdm_src(cfg$tbl_medical), 0L)
  REGIMEN_MODAL_MAP <<- build_modal_map(con, lot_long)

  lookups <- load_categories()
  n_rules <- length(lookups$lookup_1L) + length(lookups$lookup_2L)
  log_msg("  ", n_rules, " category rules loaded; steroid augmentation bypassed.")

  # --- Build: the existing dashboard, minus steroids, plus all regimens ----
  dashboard_items <<- list()

  build_cohort_kpis(con, lot_long, section = "OVERVIEW")

  add_html_card(paste0(
    '<div style="font-family:system-ui;padding:14px;max-width:900px">',
    '<h3>Regimen transitions - ', esc_html(cohort_label),
    ' (July-20 refresh: steroids removed)</h3>',
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

  if (cohort_mode == "OVERALL") build_overall_attrition(con)

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
    '<code>lot_dashboard_run_summary</code> table. This refresh script writes ',
    'no permanent tables, so that view is left to the production dashboard ',
    'runs.</p></div>'),
    section = "Validation", title = "Run comparison (omitted by design)")

  build_dashboard(
    out_name     = out_name,
    header_title = paste0("MM LOT &mdash; Regimen transitions (",
                          esc_html(cohort_label), ") &mdash; July-20 refresh"),
    header_sub   = paste0("Steroid-free regimens &bull; LOT-pair Sankeys ",
                          "&bull; By category &bull; All regimens per LOT ",
                          "(CSV downloads)")
  )
  log_msg("Wrote ", file.path(cfg$output_dir, out_name))
}

if (!interactive() && !isTRUE(getOption("jul20_refresh_dashboard.no_autorun"))) {
  main_refresh()
}
