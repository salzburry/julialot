#!/usr/bin/env Rscript
# Standalone POMA-in-1L study-team questions -> one Excel workbook.
#
#   Rscript poma_studyteam_qs.R
#
# Six follow-up questions on the NDMM 1L study cohort, one tab per question
# plus patient journeys and the coverage note. The CAR-T and raw-claim logic is
# reused from R/validation_qs.R so it cannot drift from the dashboard.
#
# Questions, against patients whose 1L regimen contains POMA (pomalidomide):
#   Q1  Trace a mix of patients from raw claims to their assigned lines.
#   Q2  Who also received SCT or CAR-T, split by when: autologous at 1L is
#       normal first-line care; an allogeneic transplant or CAR-T that closes
#       the first line is the "not treatment-naive" signal; the same therapy on
#       a later line is expected progression and is context only.
#   Q3  An audit. The cohort excludes other cancers, so the rate has to be 0 and
#       anything else is a build bug. The association needs a population that
#       still has those patients, and is in broad_studyteam_qs.R.
#   Q4  Claims-based trial evidence before the POMA at 1L, from
#       NDMM_CLINTRIAL_FLAGS. Evidence, not proof - a code identifies neither
#       the study drug nor the condition.
#   Q5  Continuous pharmacy benefit: the 12-month pre-LOT1 check the study
#       relies on, plus a longer look-back on INDEX_DATE. The cohort sets
#       INDEX_DATE to the 1L start, so both are the same anchor.
#   Q6  Follow-up length, POMA-1L against other-1L, on both of the cohort's
#       definitions - with what ended it and the index-year accrual behind it.
#       Q2 and Q4 are rates over that window, so this is what says whether
#       their two sides are comparable.
#
# Runs on this cohort only, and every table is this run's own. Anything needing
# a second cohort is in broad_studyteam_qs.R. Builds nothing persistent -
# session temp views over LOT_LONG_FINAL, MAP_STACKED, LOT1_SCT,
# NDMM_CLINTRIAL_FLAGS, NDMM_FLAGS_ALL and the raw CDM.
#
# Two limits, stated in the workbook rather than hidden:
#  - Q2's summary uses LOT1's end reason, which is authoritative for "allo or
#    CAR-T closed LOT1". The full breakdown, including CAR-T before LOT1, reuses
#    vqs_q6_cart on a POMA-filtered view.
#  - Q5 rebuilds enrollment spans from member_enrollment (gaps of 30 days or
#    less) and keeps the span covering each anchor. It does not collapse to a
#    min/max, which would bridge non-continuous coverage.

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

source(file.path(.script_dir, "_setup.R"))
qs_setup(.script_dir)
source(file.path(.script_dir, "validation_helpers.R"))        # vqs_* helpers (shared)

# Ensure the Excel engine is present. Try to load openxlsx; if missing, try to
# install it once; report whether it is now usable. The deliverable is an .xlsx,
# so main() fails closed when this returns FALSE (unless ALLOW_CSV_FALLBACK).
wbx_ensure_openxlsx <- function() {
  if (requireNamespace("openxlsx", quietly = TRUE)) return(TRUE)
  log_msg("openxlsx not installed - attempting install.packages('openxlsx')...")
  tryCatch(utils::install.packages("openxlsx", repos = getOption("repos"), quiet = TRUE),
           error = function(e) log_msg("  openxlsx install failed: ", conditionMessage(e)))
  requireNamespace("openxlsx", quietly = TRUE)
}

# Excel writer. Writes one .xlsx via openxlsx. If openxlsx is unavailable it
# fails closed (stop) unless allow_csv=TRUE, in which case it emits one CSV per
# table as an explicit, opt-in degraded mode.
# A "sheet" is list(name, title, subtitle=NULL, narrative=character(), tables=
# named list of data.frames or list(caption, df)).
wbx_write_workbook <- function(sheets, xlsx_path, csv_dir, stamp, allow_csv = FALSE) {
  san <- function(x) gsub("[^A-Za-z0-9]+", "_", x)
  if (!requireNamespace("openxlsx", quietly = TRUE)) {
    if (!isTRUE(allow_csv))
      stop("openxlsx is required to build the Excel workbook, but it is not ",
           "installed and could not be installed. Install it (install.packages",
           "('openxlsx')) and re-run, or set ALLOW_CSV_FALLBACK=TRUE to emit one CSV ",
           "per table instead of the .xlsx.")
    log_msg("WARNING: openxlsx unavailable and ALLOW_CSV_FALLBACK set - emitting one ",
            "CSV per table INSTEAD of the single .xlsx deliverable. Install openxlsx ",
            "for the single-file workbook.")
    for (s in sheets) for (nm in names(s$tables)) {
      entry <- s$tables[[nm]]; df <- entry
      if (is.list(entry) && !is.data.frame(entry)) df <- entry$df
      if (is.data.frame(df) && nrow(df) > 0) {
        f <- file.path(csv_dir, sprintf("poma_studyteam_qs_%s__%s_%s.csv",
                                        san(s$name), san(nm), stamp))
        utils::write.csv(df, f, row.names = FALSE)
        log_msg("  wrote ", f, " (", nrow(df), " rows)")
      }
    }
    return(invisible(FALSE))
  }
  ox <- function(f) getExportedValue("openxlsx", f)
  wb <- ox("createWorkbook")()
  st_title <- ox("createStyle")(fontSize = 14, textDecoration = "bold",
                                fontColour = "#FFFFFF", fgFill = "#1F3864")
  st_sub   <- ox("createStyle")(fontColour = "#FFFFFF", fgFill = "#2E5496",
                                textDecoration = "italic")
  st_narr  <- ox("createStyle")(wrapText = TRUE, valign = "top")
  st_cap   <- ox("createStyle")(textDecoration = "bold", fgFill = "#D6E0F0")
  st_hdr   <- ox("createStyle")(textDecoration = "bold", fontColour = "#FFFFFF",
                                fgFill = "#2E5496", border = "TopBottomLeftRight",
                                halign = "left")
  for (s in sheets) {
    sn <- substr(gsub("[\\/?*:\\[\\]]", "", s$name), 1, 31)
    ox("addWorksheet")(wb, sn)
    r <- 1L
    ox("writeData")(wb, sn, s$title, startRow = r, startCol = 1)
    ox("addStyle")(wb, sn, st_title, rows = r, cols = 1:10, gridExpand = TRUE)
    r <- r + 1L
    if (!is.null(s$subtitle)) {
      ox("writeData")(wb, sn, s$subtitle, startRow = r, startCol = 1)
      ox("addStyle")(wb, sn, st_sub, rows = r, cols = 1:10, gridExpand = TRUE)
      r <- r + 1L
    }
    r <- r + 1L
    for (line in s$narrative %||% character()) {
      ox("writeData")(wb, sn, line, startRow = r, startCol = 1)
      ox("addStyle")(wb, sn, st_narr, rows = r, cols = 1, gridExpand = TRUE)
      r <- r + 1L
    }
    r <- r + 1L
    for (nm in names(s$tables %||% list())) {
      entry <- s$tables[[nm]]
      cap <- nm; df <- entry
      if (is.list(entry) && !is.data.frame(entry)) { cap <- entry$caption %||% nm; df <- entry$df }
      ox("writeData")(wb, sn, cap, startRow = r, startCol = 1)
      ox("addStyle")(wb, sn, st_cap, rows = r, cols = 1:10, gridExpand = TRUE)
      r <- r + 1L
      if (is.data.frame(df) && nrow(df) > 0) {
        ox("writeData")(wb, sn, df, startRow = r, startCol = 1,
                        headerStyle = st_hdr, withFilter = FALSE)
        r <- r + nrow(df) + 2L
      } else {
        ox("writeData")(wb, sn, "(no rows / not available)", startRow = r, startCol = 1)
        r <- r + 2L
      }
    }
    ox("setColWidths")(wb, sn, cols = 1:14, widths = "auto")
  }
  ox("saveWorkbook")(wb, xlsx_path, overwrite = TRUE)
  log_msg("wrote workbook -> ", xlsx_path, " (", length(sheets), " sheets)")
  invisible(TRUE)
}

`%||%` <- function(a, b) if (is.null(a)) b else a

# Best-effort optional table: return the data on success, else a one-row table
# naming the failure. Assigning NULL into a list element would DELETE it (R
# semantics), so an unavailable optional pull would vanish with no trace; this
# keeps a visible "unavailable" row in the workbook (and logs the reason).
best_effort <- function(expr, label) {
  r <- tryCatch(expr, error = function(e) {
    log_msg("  NOTE: '", label, "' unavailable - ", conditionMessage(e))
    data.frame(status = sprintf("'%s' unavailable: %s", label, conditionMessage(e)),
               stringsAsFactors = FALSE)
  })
  if (is.null(r))
    data.frame(status = sprintf("'%s' returned no data (optional pull unavailable this run)", label),
               stringsAsFactors = FALSE)
  else r
}

main <- function() {
  stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")

  # Fail closed on the Excel engine before running any query, so a missing
  # openxlsx does not waste warehouse time and cannot masquerade as success.
  allow_csv <- tolower(Sys.getenv("ALLOW_CSV_FALLBACK", unset = "")) %in% c("1", "true", "yes")
  have_xlsx <- wbx_ensure_openxlsx()
  if (!have_xlsx && !allow_csv)
    stop("openxlsx is required to build the Excel workbook, and it is not ",
         "installed / could not be installed here. Run install.packages('openxlsx') ",
         "and re-run, or set ALLOW_CSV_FALLBACK=TRUE to emit one CSV per table instead.")
  if (!have_xlsx)
    log_msg("WARNING: openxlsx unavailable; ALLOW_CSV_FALLBACK is set -> CSV-per-table ",
            "degraded mode (NOT the .xlsx deliverable).")

  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  out_dir <- cfg$output_dir
  if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  stamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
  num <- function(x) suppressWarnings(as.numeric(x))

  # The LOT run under this prefix is over the study cohort already, so its
  # output is the study population - there is no separate filtered copy to read.
  # Every LOT / POMA query flows from lot_long.
  .pop         <- qs_population()
  cohort_label <- .pop$label
  lot_long     <- .pop$table
  map_tbl   <- qs_tbl("MAP_STACKED")
  sct_tbl   <- qs_tbl("LOT1_SCT")
  final_tbl <- wrk(cfg$input_cohort_table)

  log_msg(SEP); log_msg("POMA-in-1L study-team questions [", cohort_label, "] -> single Excel workbook"); log_msg(SEP)
  if (!vqs_readable(con, lot_long))
    stop("Cannot read ", lot_long, ". Run the LOT build for this prefix first.")
  qs_check_run_binding(con)
  have_map   <- vqs_readable(con, map_tbl)
  have_sct   <- vqs_readable(con, sct_tbl)
  have_final <- vqs_readable(con, final_tbl)
  for (chk in list(c(have_map, map_tbl), c(have_sct, sct_tbl),
                   c(have_final, final_tbl)))
    if (!isTRUE(as.logical(chk[1])))
      log_msg("WARNING: ", chk[2], " not readable - dependent sections will note the gap.")

  tokens <- vqs_resolve_agent_tokens(con)               # builds mma_codelist view; resolves POMA
  poma   <- tokens$poma
  log_msg("POMA token = '", poma, "'. ", paste(tokens$notes, collapse = " "))
  bounds <- vqs_obs_bounds_src(con)                     # observation-window scoping for raw pulls
  cart_raw <- if (have_sct) tryCatch(vqs_build_raw_cart_dates(con, lot_long, bounds$sql),
                                     error = function(e) NULL) else NULL

  # POMA-at-1L patient set (NDMM study cohort, via LOT_LONG_FINAL). This is the
  # denominator every question depends on, so it runs fail-fast (no error swallow):
  # if it errored we would report "0 POMA patients" and skip Q2/Q5, indistinguishable
  # from a true zero. lot_long readability is already checked above.
  poma_ids <- db_q(con, glue("
    SELECT cast(PATID as string) AS PATID FROM {lot_long}
    WHERE LOT_NUM = 1 AND LOT_BASE_MEDS IS NOT NULL
      AND array_contains(split(LOT_BASE_MEDS, ' '), '{poma}')"))$PATID
  n_poma <- length(unique(poma_ids))
  n_lot1 <- num(db_q(con, glue(
    "SELECT count(DISTINCT PATID) n FROM {lot_long} WHERE LOT_NUM = 1"))$n)
  log_msg(sprintf("POMA-at-1L: %d of %d LOT1 patients (%.1f%%).",
                  n_poma, n_lot1, if (isTRUE(n_lot1 > 0)) 100 * n_poma / n_lot1 else NA_real_))

  sheets <- list()
  add_sheet <- function(...) sheets[[length(sheets) + 1L]] <<- list(...)

  # ---- Read Me -----------------------------------------------------------
  add_sheet(name = "Read Me", title = paste0("POMA-in-1L study-team questions - ", cohort_label),
    subtitle = paste0("Generated ", stamp, " by poma_studyteam_qs.R against ", cfg$work_schema),
    narrative = c(
      "Every table here is computed on the NDMM newly-diagnosed 1L STUDY cohort (LOT_LONG_FINAL). Nothing reads a second cohort - see broad_studyteam_qs.R for the questions that need one.",
      sprintf("POMA-at-1L denominator: %d of %d LOT1 patients.", n_poma, n_lot1),
      "Q1 = real patient journeys (raw claims -> MAP -> assigned LOT, with dates).",
      "Q2 = POMA-1L split by transplant type and TIMING (autologous-at-1L vs allo/CAR-T that closed 1L vs later-line context).",
      "Q3 = an NDMM audit: other-cancer rate must be 0, since NDMM excludes those patients by construction. The POMA-vs-other association needs a broad cohort and is in broad_studyteam_qs.R.",
      "Q4 = was there trial evidence before the 1L POMA? Windows cut at this cohort's own 1L start, with diagnosis-to-1L as its own column. Claims-based evidence, not proof of therapy.",
      "Q5 = LOT1-anchored NDMM proof (ce_ge_12mo_pre_lot1 / len_thal_in_12mo_pre_lot1, the 12-mo pre-LOT1 check) PLUS a longer LEN/THAL look-back on the cohort's INDEX_DATE, which is the same date (the cohort sets INDEX_DATE = LOT1_START_DT).",
      "Q6 = follow-up length, POMA-1L against other-1L, on both of the cohort's definitions, with what ended it and the index-year accrual behind it. Q2 and Q4 are rates over that window, so read Q6 before treating their two sides as comparable.",
      "Operational definitions are shared with R/validation_qs.R (single source of truth)."),
    tables = list())

  # ---- Optum coverage validation ----------------------------------------
  add_sheet(name = "Optum coverage (validation)",
    title = "Does Optum separate medical & pharmacy coverage?",
    subtitle = "Reasoned from how the cohort is built, not a warehouse query.",
    narrative = c(
      "Bottom line: essentially no. Optum CDM restricts membership to individuals with BOTH medical and pharmacy",
      "benefits, so there is no medical-only sub-population; coverage is one continuous-enrollment span, not two",
      "separable streams.",
      "The cohort's 6-month continuous-enrollment requirement (CE_b) enforces medical AND pharmacy benefits before index.",
      "Implication for Q5: oral LEN/THAL fills are OBSERVABLE (when adjudicated and on the code list), and the baseline",
      "MM-therapy exclusion already drops any baseline MM-therapy claim (medical or pharmacy). NDMM tightens this further - filter #4 excludes MM",
      "oncology therapy across the 12-month pre-LOT1 window - which is the PRIMARY check the Q5 tab reports (LOT1-anchored",
      "columns). The index-anchored columns beside them run the look-back back to the start of coverage; they are a longer",
      "window on the same anchor, not a second one. Not observable: samples, cash-pay/out-of-plan",
      "fills, NDCs missing from the code list."),
    tables = list())

  # ---- Q1: patient journeys (mix) ---------------------------------------
  # The example set is AUTO-picked to span archetypes, but an analyst can pin a
  # curated list via EXAMPLE_PATIDS (comma/space separated) after eyeballing
  # a first run - so the workbook can show clinically chosen patients, not just
  # whatever the heuristic surfaced.
  q1_tables <- list(); q1_notes <- character()
  curated <- strsplit(Sys.getenv("EXAMPLE_PATIDS", unset = ""), "[,; ]+")[[1]]
  curated <- trimws(curated); curated <- curated[nzchar(curated)]
  if (have_map) {
    # Decide the example set: curated (EXAMPLE_PATIDS) only when the IDs are VERIFIED
    # to be in the NDMM cohort, otherwise auto-selection. Curated IDs are used only
    # after they pass the NDMM membership check; if that check errors or leaves
    # nothing, we FAIL CLOSED to auto-selection (which is NDMM-bounded), so an
    # unverified ID can never reach the raw MM / SCT pulls and leak a non-NDMM
    # patient into this NDMM-only workbook.
    use_curated <- length(curated) > 0
    if (use_curated) {
      req <- unique(curated)
      chk <- tryCatch(db_q(con, glue("SELECT DISTINCT cast(PATID as string) PATID FROM {lot_long}
                                      WHERE cast(PATID as string) IN ({vqs_in_list(req)})"))$PATID,
                      error = function(e) NULL)
      if (is.null(chk)) {
        use_curated <- FALSE
        q1_notes <- c(q1_notes, "EXAMPLE_PATIDS given but the NDMM-membership check failed; falling back to auto-selection to avoid including non-NDMM patients.")
      } else {
        ids <- req[req %in% chk]
        dropped <- setdiff(req, ids)
        if (length(ids) > 0) {
          q1_notes <- c(q1_notes,
            sprintf("Curated example patients from EXAMPLE_PATIDS: %d in NDMM cohort%s.",
                    length(ids),
                    if (length(dropped)) sprintf("; %d dropped as NOT in NDMM: %s",
                                                 length(dropped), paste(dropped, collapse = ", ")) else ""))
        } else {
          use_curated <- FALSE
          q1_notes <- c(q1_notes, sprintf("None of the %d EXAMPLE_PATIDS were in the NDMM cohort; falling back to auto-selection.", length(req)))
        }
      }
    }
    if (!use_curated) {
      # a diverse example set: deepest progressors + POMA-1L + allo + auto + CART
      pick <- function(sql) tryCatch(db_q(con, sql)$PATID, error = function(e) character(0))
      deep <- pick(glue("WITH pm AS (SELECT cast(PATID as string) PATID, max(LOT_NUM) mx
                          FROM {lot_long} GROUP BY PATID)
                         SELECT PATID FROM pm ORDER BY mx DESC, PATID LIMIT 3"))
      allo <- pick(glue("SELECT DISTINCT cast(PATID as string) PATID FROM {lot_long}
                         WHERE LOT_NUM=1 AND LOT_BASE_END_REASON='SCT_ALLO' ORDER BY PATID LIMIT 2"))
      auto <- pick(glue("SELECT DISTINCT cast(PATID as string) PATID FROM {lot_long}
                         WHERE LOT_NUM=1 AND (LOT_TX_AUTO_SING_FLG=1 OR LOT_TX_AUTO_TAND_FLG=1)
                         ORDER BY PATID LIMIT 2"))
      cart <- if (have_sct) pick(glue("SELECT DISTINCT cast(PATID as string) PATID FROM {lot_long}
                         WHERE LOT_BASE_END_REASON IN ('SCT_CART','CART_INIT') OR LOT_CART_LOT_FLG=1
                         ORDER BY PATID LIMIT 2")) else character(0)
      pomj <- head(poma_ids, 2)
      ids  <- unique(c(deep, pomj, allo, auto, cart))
      q1_notes <- c(q1_notes, "Example patients auto-selected (deep progressors + POMA-1L + allo/auto SCT + CAR-T). Pin a curated set with EXAMPLE_PATIDS and re-run.")
    }
    if (length(ids) > 0) {
      # final LOT assignment for the picked patients
      # final LOT assignment + MAP journey are core (LOT_LONG/MAP_STACKED are
      # guarded readable above); the raw-CDM pulls are best-effort (the vqs_*
      # helpers degrade to NULL when the raw claims / codelists are unreachable).
      q1_tables[["Assigned lines (LOT_LONG) for the example patients"]] <-
        db_q(con, glue("
          SELECT cast(PATID as string) PATID, LOT_NUM,
                 cast(LOT_START_DT as string) LOT_START_DT, LOT_START_TYPE,
                 LOT_BASE_MEDS, cast(LOT_BASE_END_DT as string) LOT_BASE_END_DT,
                 LOT_BASE_END_REASON, LOT_ALLO_LOT_FLG, LOT_CART_LOT_FLG,
                 LOT_TX_AUTO_SING_FLG, LOT_TX_AUTO_TAND_FLG,
                 cast(LOT_TX_AUTO_DT_1 as string) LOT_TX_AUTO_DT_1,
                 cast(LOT_TX_AUTO_DT_2 as string) LOT_TX_AUTO_DT_2
          FROM {lot_long} WHERE cast(PATID as string) IN ({vqs_in_list(ids)})
          ORDER BY PATID, LOT_NUM"))
      q1_tables[["MAP segments the engine built"]] <- vqs_map_journey(con, map_tbl, lot_long, ids)
      q1_tables[["Raw MM-therapy claims (all routes: rx NDC, medical PROC_CD/BILL_PROC_CD/NDC)"]] <-
        best_effort(vqs_raw_mma_claims(con, ids, bounds = bounds$sql), "Raw MM-therapy claims")
      if (have_sct)
        q1_tables[["Raw SCT / CAR-T claims (medical PROC_CD/BILL_PROC_CD + med_procedure + med_diagnosis)"]] <-
          best_effort(vqs_raw_sct_claims(con, ids, bounds = bounds$sql), "Raw SCT / CAR-T claims")
      q1_notes <- c(q1_notes,
                    sprintf("Example patients (%d): %s.", length(ids), paste(ids, collapse = ", ")),
                    "Chain: raw claims (routes above) -> MAP segments -> assigned LOT, all with dates.",
                    if (!bounds$available) "Raw claims are NOT observation-window bounded (the cohort table is unavailable)." else
                      "Raw claims scoped to [INDEX_DATE, OBS_END_DT] from the cohort table.")
    } else q1_notes <- c(q1_notes, "No example patients could be selected from LOT_LONG.")
  } else q1_notes <- paste0(map_tbl, " not readable - journeys skipped. Build MAP_STACKED (02_lot1.R).")
  add_sheet(name = "Q1 journeys", title = "Q1 - Patient journeys: raw claims -> assigned LOT",
    subtitle = paste0("A mix of patients (deep progressors, POMA-1L, autologous/allogeneic SCT, CAR-T), each traced with dates. Cohort: ",
                      cohort_label, "."),
    narrative = q1_notes, tables = q1_tables)

  # ---- Q2: POMA-1L who also received SCT / CAR-T ------------------------
  q2_tables <- list(); q2_notes <- character()
  if (n_poma > 0) {
    q2_tables[["POMA-1L transplant summary (by type and timing)"]] <- db_q(con, glue("
      WITH poma1l AS (SELECT DISTINCT cast(PATID as string) PATID FROM {lot_long}
                      WHERE LOT_NUM=1 AND array_contains(split(LOT_BASE_MEDS,' '),'{poma}')),
      fl AS (SELECT cast(PATID as string) PATID,
               max(CASE WHEN LOT_TX_AUTO_SING_FLG=1 OR LOT_TX_AUTO_TAND_FLG=1 THEN 1 ELSE 0 END) auto_at_1l,
               max(CASE WHEN LOT_BASE_END_REASON='SCT_ALLO' THEN 1 ELSE 0 END) allo_closed_1l,
               max(CASE WHEN LOT_BASE_END_REASON IN ('SCT_CART','CART_INIT') THEN 1 ELSE 0 END) cart_closed_1l
             FROM {lot_long} WHERE LOT_NUM=1 GROUP BY cast(PATID as string)),
      ctx AS (SELECT cast(PATID as string) PATID,
                max(coalesce(LOT_ALLO_LOT_FLG,0)) allo_any, max(coalesce(LOT_CART_LOT_FLG,0)) cart_any
              FROM {lot_long} GROUP BY cast(PATID as string))
      SELECT count(*) AS poma_1l_pts,
             sum(f.auto_at_1l)      AS autologous_at_1l,
             sum(f.allo_closed_1l)  AS allo_closed_1l,
             sum(f.cart_closed_1l)  AS cart_closed_1l,
             sum(CASE WHEN f.allo_closed_1l=1 OR f.cart_closed_1l=1 THEN 1 ELSE 0 END) AS red_flag_closed_1l,
             sum(CASE WHEN c.allo_any=1 OR c.cart_any=1 THEN 1 ELSE 0 END)             AS allo_or_cart_any_line
      FROM poma1l p JOIN fl f USING (PATID) JOIN ctx c USING (PATID)"))

    # Authoritative CAR-T-relative-to-LOT1 for the POMA-1L subset (reuses vqs_q6_cart).
    # Optional add-on: both the temp-view creation and the query are inside the
    # guard, so a create-view or SCT-table hiccup leaves a visible "unavailable"
    # row rather than aborting the workbook.
    if (have_sct)
      q2_tables[["POMA-1L CAR-T relative to LOT1 (authoritative; vqs_q6_cart)"]] <- best_effort({
        db_exec(con, glue("CREATE OR REPLACE TEMPORARY VIEW poma1l_lot_long_tmp AS
                           SELECT ll.* FROM {lot_long} ll
                           JOIN (SELECT DISTINCT PATID FROM {lot_long}
                                 WHERE LOT_NUM=1 AND array_contains(split(LOT_BASE_MEDS,' '),'{poma}')) p
                             ON cast(ll.PATID as string) = cast(p.PATID as string)"))
        vqs_q6_cart(con, "poma1l_lot_long_tmp", sct_tbl, w1 = VQS_W1, cart_raw_tbl = cart_raw)
      }, "POMA-1L CAR-T relative to LOT1")
    q2_notes <- c(
      "Autologous SCT at 1L is standard first-line care and is NOT evidence of prior treatment.",
      "The red flag is an allogeneic SCT or CAR-T that CLOSES the first line (end reason SCT_ALLO / SCT_CART / CART_INIT).",
      "allo_or_cart_any_line is context only: the same therapy on a LATER line is expected progression, not a non-naive signal.",
      # The 'before LOT1' rows of vqs_q6_cart come from the raw CAR-T scan (cart_raw);
      # when that scan is unavailable those metrics are NA - say so instead of
      # implying the table covers before-LOT1.
      if (have_sct && !is.null(cart_raw))
        "The vqs_q6_cart table gives the authoritative timing, INCLUDING CAR-T BEFORE LOT1 (from raw CAR-T claim dates)."
      else if (have_sct)
        paste0("NOTE: the raw CAR-T scan was unavailable this run (cart_raw is NULL), so CAR-T BEFORE LOT1 could NOT be ",
               "assessed - the 'before'/'prior-or-during' rows in the vqs_q6_cart table are NA. During/closing-LOT1 timing is still valid.")
      else NULL,
      if (!have_sct) paste0(sct_tbl, " not readable - the authoritative CAR-T-relative-to-LOT1 table is omitted.") else NULL)
  } else q2_notes <- sprintf("No POMA-at-1L patients (token '%s'). Set POMA_MED_ABBR if the token differs.", poma)
  add_sheet(name = "Q2 POMA & SCT-CART", title = "Q2 - POMA-1L patients who also received SCT or CAR-T",
    subtitle = paste0("Split by transplant type and timing; later-line transplant is context, not a red flag. Cohort: ",
                      cohort_label, "."),
    narrative = q2_notes, tables = q2_tables)

  # ---- Q3: other cancer, on this cohort -----------------------------------
  #
  # The ASSOCIATION half of Q3 is not here: this cohort excluded those patients
  # by construction, so measured here it is zero against zero. It is in
  # broad_studyteam_qs.R, over a broad cohort.
  #
  # What is left is the audit. Other cancer must be 0 - the cohort is filtered
  # to NO_OTHER_CANCER_PRE_LOT1 = 1, so a non-zero value is a bug in the NDMM
  # build, not a signal. Reads NDMM's own flag from NDMM_FLAGS_ALL, not the
  # broad claim-presence method above, which uses a different window and would
  # false-alarm. A missing flag row is counted separately rather than coerced
  # to clean, so a broken join shows up as itself: both must be 0.
  ndmm_flags <- qs_tbl("NDMM_FLAGS_ALL")
  q3_ndmm_df <- if (vqs_readable(con, ndmm_flags)) best_effort(db_q(con, glue("
      WITH poma1l AS (SELECT DISTINCT cast(PATID as string) PATID FROM {lot_long}
                      WHERE LOT_NUM=1 AND array_contains(split(LOT_BASE_MEDS,' '),'{poma}')),
      lot1 AS (SELECT DISTINCT cast(PATID as string) PATID FROM {lot_long} WHERE LOT_NUM=1),
      fl AS (SELECT cast(PATID as string) PATID,
                    min(coalesce(NO_OTHER_CANCER_PRE_LOT1,1)) AS no_other_cancer
             FROM {ndmm_flags} GROUP BY cast(PATID as string))
      SELECT CASE WHEN p.PATID IS NOT NULL THEN 'POMA-1L (NDMM)' ELSE 'other-1L (NDMM)' END grp,
             count(*)                                                                              n_pts,
             sum(CASE WHEN fl.PATID IS NOT NULL AND fl.no_other_cancer=0 THEN 1 ELSE 0 END)        n_other_cancer,
             round(100.0*sum(CASE WHEN fl.PATID IS NOT NULL AND fl.no_other_cancer=0 THEN 1 ELSE 0 END)/count(*),1) pct_other_cancer,
             sum(CASE WHEN fl.PATID IS NULL THEN 1 ELSE 0 END)                                     missing_flag_rows
      FROM lot1 l LEFT JOIN poma1l p USING (PATID) LEFT JOIN fl ON fl.PATID = l.PATID
      GROUP BY 1 ORDER BY 1")), "NDMM other-cancer audit")
    else {
      # NDMM_FLAGS_ALL unreadable: the "must be 0" audit could not run. Do not let
      # it fall through to the writer's bland "(no rows / not available)" - emit a
      # loud, explicit marker so a missing audit is never mistaken for a passing one.
      log_msg("  AUDIT UNAVAILABLE: ", ndmm_flags, " unreadable - Q3 NDMM audit did not run; output NOT shareable until rerun.")
      data.frame(status = sprintf(
        "NDMM AUDIT COULD NOT RUN - %s unreadable. Rerun 06_ndmm_dashboard.R; output is NOT shareable until this table shows n_other_cancer=0 / missing_flag_rows=0.",
        ndmm_flags), stringsAsFactors = FALSE)
    }

  add_sheet(name = "Q3 POMA & other cancers", title = "Q3 - other cancer in the NDMM cohort (audit)",
    subtitle = "Must be 0. The POMA-vs-other ASSOCIATION is a broad-cohort question and is in broad_studyteam_qs.R.",
    narrative = c(
      "The NDMM study cohort excludes genuine other cancers by construction, so its other-cancer rate MUST be 0.",
      "A non-zero value is a BUG in the NDMM build, not a real signal. It uses NDMM's own 12-mo pre-LOT1 flag.",
      "missing_flag_rows must also be 0: it counts NDMM 1L patients with NO row in NDMM_FLAGS_ALL (a broken join), not coerced to clean.",
      "THE ASSOCIATION IS NOT HERE, and cannot be. 'Does POMA use track with another cancer' needs a population that still",
      "contains those patients; this one removed them, so asking it here compares zero with zero. broad_studyteam_qs.R answers it",
      "over a broad cohort, and names the run it used."),
    tables = list(
      "NDMM cohort AUDIT - other cancer MUST be 0 (excluded by construction)" = q3_ndmm_df))

  # The 1L-anchored answer, from this cohort's own build. One prefix, one
  # cohort: no overlap to report, no second index to reconcile, and the
  # diagnosis-to-1L window - the one the broad build's pair cannot isolate - is
  # its own column. Patients with no row are counted rather than coerced to
  # clean, the same way the Q3 audit treats a broken join.
  ndmm_trial  <- qs_ndmm_trial_flags(con)
  ndmm_tr_tbl <- ndmm_trial$table
  q4_ndmm_df <- if (isTRUE(ndmm_trial$ok)) best_effort({
    db_q(con, glue("
      WITH poma1l AS (SELECT DISTINCT cast(PATID as string) PATID FROM {lot_long}
                      WHERE LOT_NUM=1 AND array_contains(split(LOT_BASE_MEDS,' '),'{poma}')),
      lot1 AS (SELECT DISTINCT cast(PATID as string) PATID FROM {lot_long} WHERE LOT_NUM=1),
      t AS (SELECT cast(PATID as string) PATID, CLINTRIAL_PRE_DX, CLINTRIAL_DX_TO_LOT1,
                   CLINTRIAL_POST_LOT1, CLINTRIAL_PRE_LOT1_12MO,
                   -- The days column for THIS window, not the any-time-before-1L
                   -- one: it is NULL unless CLINTRIAL_DX_TO_LOT1 = 1, so the
                   -- median below is over the patients the count is about.
                   CLINTRIAL_DX_TO_LOT1_DAYS
            FROM {ndmm_tr_tbl})
      SELECT CASE WHEN p.PATID IS NOT NULL THEN 'POMA-1L' ELSE 'other-1L' END AS grp,
             count(*)                                                           AS n_pts,
             sum(CASE WHEN t.PATID IS NULL THEN 1 ELSE 0 END)                   AS missing_flag_rows,
             sum(coalesce(t.CLINTRIAL_DX_TO_LOT1,0))                            AS n_dx_to_lot1,
             round(100.0*sum(coalesce(t.CLINTRIAL_DX_TO_LOT1,0))/nullif(count(t.PATID),0),1)     AS pct_dx_to_lot1,
             sum(coalesce(t.CLINTRIAL_PRE_LOT1_12MO,0))                         AS n_12mo_pre_lot1,
             round(100.0*sum(coalesce(t.CLINTRIAL_PRE_LOT1_12MO,0))/nullif(count(t.PATID),0),1)  AS pct_12mo_pre_lot1,
             sum(coalesce(t.CLINTRIAL_PRE_DX,0))                                AS n_pre_dx,
             sum(coalesce(t.CLINTRIAL_POST_LOT1,0))                             AS n_post_lot1,
             percentile_approx(t.CLINTRIAL_DX_TO_LOT1_DAYS, 0.5)                AS median_days_dx_to_lot1
      FROM lot1 l LEFT JOIN t USING (PATID) LEFT JOIN poma1l p USING (PATID)
      GROUP BY 1 ORDER BY 1"))
  }, "1L-anchored clinical trial") else NULL

  add_sheet(name = "Q4 POMA & clinical trials", title = "Q4 - trial evidence before the 1L start",
    subtitle = if (isTRUE(ndmm_trial$ok))
      "Claims-based trial evidence on this cohort's own 1L index - evidence to review, not proof of therapy."
    else
      paste0("Not available this run: ", ndmm_trial$why),
    narrative = if (isTRUE(ndmm_trial$ok)) c(
        paste0("From ", ndmm_tr_tbl, ": every window is cut at this cohort's own 1L start, so there is no second index",
               " and no overlap with another cohort."),
        "WHAT IT IS: claims-based trial EVIDENCE - a trial diagnosis, procedure or revenue code. It does not identify the study drug,",
        "the condition treated, or whether a blinded agent was received, so it does not establish that a patient had MM therapy in",
        "that window, and a zero does not establish that they did not. Treat a positive as a patient to review, not as a proven line.",
        "HEADLINE n_dx_to_lot1 / pct_dx_to_lot1: trial evidence between the MM diagnosis and the day before LOT1. That is the",
        "stretch a first line would have displaced.",
        "CAVEAT on comparing that column across groups: the diagnosis-to-1L interval is days for one patient and years for another,",
        "so the chance of catching a code differs per patient. n_12mo_pre_lot1 is a FIXED window and is the more comparable one",
        "between POMA-1L and other-1L; read the two together rather than either alone.",
        "n_12mo_pre_lot1 is also the window filter #4 uses for prior MM therapy. It SPANS pre-diagnosis and diagnosis-to-1L, so do",
        "NOT add it to n_pre_dx or n_dx_to_lot1 - those three plus n_post_lot1 already partition the period.",
        "median_days_dx_to_lot1 is over the SAME window as the headline count (NULL unless CLINTRIAL_DX_TO_LOT1=1), so the count and",
        "the timing describe one set of patients. It separates 'trial evidence, then POMA' from a trial code in the same week as 1L.",
        "n_post_lot1 is at-or-after LOT1: context, never evidence of a prior line.",
        "missing_flag_rows must be 0. It counts LOT1 patients with no row in the flag table - a broken join, not a clean patient.",
        "Clinical trial does NOT filter this cohort. The flag is descriptive and is not one of the criteria, so nothing was removed for it.",
        "Claims-based trial evidence is a lower bound (a fully masked study drug may carry no trial code).")
      else
        paste0("The 1L-anchored flag is not available: ", ndmm_trial$why,
               " The cohort build writes it; re-run that build. The older diagnosis-anchored view is in broad_studyteam_qs.R,",
               " and it cannot answer whether the evidence preceded LOT1."),
    tables = if (isTRUE(ndmm_trial$ok))
      list("Trial evidence before the 1L start - THIS COHORT (claims-based)" = q4_ndmm_df)
      else list())

  # ---- Q5: pharmacy-benefit continuity + LEN/THAL look-back -------------
  q5_tables <- list(); q5_notes <- character()
  if (have_final && n_poma > 0 && length(tokens$notes) &&
      !any(grepl("unavailable", tokens$notes, ignore.case = TRUE))) {
    # The index columns are anchored on the cohort's INDEX_DATE, which this
    # cohort sets to LOT1_START_DT - the same date as lot1_dt. So they are not
    # a second, earlier window: they are a longer look-back on the same anchor
    # (back to the start of the covering enrollment span), and a cross-check
    # that the cohort's index and the LOT run's LOT1 start still agree. Named
    # for what they measure rather than for a diagnosis anchor that is not
    # what INDEX_DATE holds.
    q5_tables[["POMA-1L: 12-mo pre-LOT1 check + full-history look-back"]] <- tryCatch(db_q(con, glue("
      WITH poma1l AS (SELECT DISTINCT cast(PATID as string) PATID FROM {lot_long}
                      WHERE LOT_NUM=1 AND array_contains(split(LOT_BASE_MEDS,' '),'{poma}')),
      lot1 AS (SELECT cast(PATID as string) PATID, min(cast(LOT_START_DT as date)) lot1_dt
               FROM {lot_long} WHERE LOT_NUM=1 GROUP BY cast(PATID as string)),
      idx AS (SELECT cast(PATID as string) PATID, cast(INDEX_DATE as date) INDEX_DATE FROM {final_tbl}),
      base AS (SELECT cast(PATID as string) PATID, cast(ELIGEFF as date) elig_eff, cast(ELIGEND as date) elig_end
               FROM {cdm_src('member_enrollment')} WHERE ELIGEFF IS NOT NULL AND ELIGEND IS NOT NULL),
      ordered AS (SELECT *, max(elig_end) OVER (PARTITION BY PATID ORDER BY elig_eff, elig_end
                    ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) max_end_prev FROM base),
      flagged AS (SELECT *, CASE WHEN max_end_prev IS NULL THEN 1
                                 WHEN elig_eff > date_add(max_end_prev, 31) THEN 1 ELSE 0 END new_grp FROM ordered),
      grouped AS (SELECT *, sum(new_grp) OVER (PARTITION BY PATID ORDER BY elig_eff, elig_end
                    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) grp_id FROM flagged),
      spans AS (SELECT PATID, grp_id, min(elig_eff) cov_start, max(elig_end) cov_end
                FROM grouped GROUP BY PATID, grp_id),
      idx_span AS (SELECT i.PATID, i.INDEX_DATE, s.cov_start FROM idx i JOIN spans s
                   ON s.PATID=i.PATID AND s.cov_start <= i.INDEX_DATE AND s.cov_end >= i.INDEX_DATE),
      lot1_span AS (SELECT l.PATID, l.lot1_dt, s.cov_start AS lot1_cov_start FROM lot1 l JOIN spans s
                    ON s.PATID=l.PATID AND s.cov_start <= l.lot1_dt AND s.cov_end >= l.lot1_dt),
      len_thal AS (SELECT DISTINCT lpad(regexp_replace(CL_CODE,'[^0-9]',''),11,'0') ndc
                   FROM mma_codelist WHERE upper(CL_CODE_TYPE)='NDC'
                     AND (lower(CL_MEDICATION_FULL) LIKE '%lenalidomid%'
                          OR lower(CL_MEDICATION_FULL) LIKE '%thalidomid%')),
      early_oral AS (SELECT cast(r.PATID as string) PATID, cast(r.FILL_DT as date) fill_dt
                     FROM {cdm_src(cfg$tbl_rx)} r JOIN len_thal t
                       ON lpad(regexp_replace(coalesce(cast(r.NDC as string),''),'[^0-9]',''),11,'0') = t.ndc),
      early_flag AS (SELECT x.PATID,
                       max(CASE WHEN o.fill_dt >= x.cov_start
                                 AND o.fill_dt <  date_sub(x.INDEX_DATE,183) THEN 1 ELSE 0 END) pre_baseline_len_thal
                     FROM idx_span x LEFT JOIN early_oral o ON o.PATID=x.PATID GROUP BY x.PATID),
      lot1_flag AS (SELECT ls.PATID,
                      max(CASE WHEN o.fill_dt >= date_sub(ls.lot1_dt,365)
                                AND o.fill_dt <  ls.lot1_dt THEN 1 ELSE 0 END) len_thal_pre_lot1_12mo
                    FROM lot1_span ls LEFT JOIN early_oral o ON o.PATID=ls.PATID GROUP BY ls.PATID)
      -- LEFT JOIN so poma_1l_pts is the FULL POMA-1L denominator; a patient with no
      -- LOT1-/index-covering enrollment span is retained and shown by the *_with_*_span
      -- counts. Those SHOULD equal the denominator (the cohort enforces CE); a gap flags
      -- a LOT_LONG / cohort / enrollment mismatch to investigate, not a silent drop.
      SELECT count(*)                                                                    AS poma_1l_pts,
             -- LOT1-anchored NDMM check: CE mirrors filter #1; len_thal is the LEN/THAL
             -- SUBSET of filter #4's 12-mo pre-LOT1 window (filter #4 also scans medical
             -- PROC/BILL_PROC/NDC + rx NDC for all non-steroid MM oncology therapy)
             count(ls.PATID)                                                             AS poma_1l_with_lot1_span,
             sum(CASE WHEN ls.lot1_cov_start IS NOT NULL
                       AND datediff(ls.lot1_dt, ls.lot1_cov_start) >= 365 THEN 1 ELSE 0 END) AS ce_ge_12mo_pre_lot1,
             sum(coalesce(lf.len_thal_pre_lot1_12mo,0))                                  AS len_thal_in_12mo_pre_lot1,
             -- Same anchor (the cohort sets INDEX_DATE = LOT1_START_DT), longer window:
             -- coverage back to the start of the span, and any LEN/THAL fill in it up to
             -- 6 months before index. Also a cross-check that the two dates still agree.
             count(x.PATID)                                                              AS poma_1l_with_index_span,
             sum(CASE WHEN x.cov_start IS NOT NULL
                       AND datediff(x.INDEX_DATE, x.cov_start) > 183 THEN 1 ELSE 0 END)  AS ce_gt_6mo_pre_index,
             sum(coalesce(ef.pre_baseline_len_thal,0))                                   AS len_thal_gt_6mo_pre_index
      FROM poma1l p LEFT JOIN idx_span x USING (PATID) LEFT JOIN early_flag ef USING (PATID)
                    LEFT JOIN lot1_span ls USING (PATID) LEFT JOIN lot1_flag lf USING (PATID)")),
      error = function(e) { q5_notes <<- paste("Q5 query failed:", conditionMessage(e)); NULL })
    q5_notes <- c(q5_notes,
      "LOT1-ANCHORED NDMM CHECK (the study proof, shown directly in the table, anchored on LOT1_START_DT):",
      "ce_ge_12mo_pre_lot1 = POMA-1L patients with >=12 months continuous enrollment before LOT1 (mirrors NDMM filter #1)",
      "- should equal poma_1l_pts. len_thal_in_12mo_pre_lot1 = those with a LEN/THAL fill in [LOT1_START-365, LOT1_START-1]",
      "- this is the LEN/THAL SUBSET of NDMM filter #4's no-prior-therapy window (filter #4 itself is broader: all",
      "non-steroid MM oncology therapy across medical PROC/BILL_PROC/NDC + rx NDC). It should be 0, since NDMM already",
      "excludes observable MM therapy in that window; a nonzero value flags a discrepancy to investigate.",
      "INDEX-ANCHORED LOOK-BACK (secondary): the cohort sets INDEX_DATE = LOT1_START_DT, so these columns share the",
      "anchor above - they are NOT an earlier, independent window. ce_gt_6mo_pre_index is a weaker form of",
      "ce_ge_12mo_pre_lot1 (>6 months rather than >=12). len_thal_gt_6mo_pre_index runs the LEN/THAL scan from the START",
      "of the covering enrollment span up to 6 months before index, so it reaches further back than the 12-month window",
      "and overlaps it - read it as a longer look-back, not as a separate finding, and never add the two together.",
      "Because the anchors are the same date, the pair also cross-checks them: poma_1l_with_index_span differing from",
      "poma_1l_with_lot1_span means the cohort's INDEX_DATE and this LOT run's LOT1 start no longer agree.",
      "poma_1l_pts = full POMA-1L denominator; poma_1l_with_lot1_span / poma_1l_with_index_span = those with a continuous",
      "span covering LOT1 / index (should match the denominator - if lower, investigate a LOT_LONG / cohort / enrollment mismatch).",
      "Every Optum member has pharmacy benefit. Continuous spans are rebuilt from raw member_enrollment (<=30-day gaps).")
  } else {
    q5_notes <- if (n_poma == 0) "No POMA-at-1L patients - Q5 skipped." else
      paste0("Q5 needs ", final_tbl, " and the cl_mma_codelist (mma_codelist view). One is unavailable this run.")
  }
  add_sheet(name = "Q5 POMA & pharmacy benefit", title = "Q5 - POMA-1L pharmacy-benefit continuity + hidden LEN/THAL",
    subtitle = paste0("Read the LOT1-anchored columns (ce_ge_12mo_pre_lot1 / len_thal_in_12mo_pre_lot1) as the NDMM proof; ",
                      "the index-anchored columns are a longer look-back on the SAME anchor, not a second window. ",
                      "See the 'Optum coverage' tab for the coverage validation."),
    narrative = q5_notes, tables = q5_tables)

  # ---- Q6: follow-up, POMA-1L against other-1L ----------------------------
  # Whether the rest of the workbook compares like with like. Q2 and Q4 are
  # rates over a window, and the study end is fixed, so a group that indexed
  # later has less room - a lower rate on one side can be the calendar.
  #
  # Both follow-up lengths, because the cohort carries two: FU_DAYS to death or
  # the study end, FU_DAYS_CE also capped at disenrolment. The dashboard shows
  # the same pair.
  q6_tables <- list(); q6_notes <- character(0)
  # One CASE for all three tables, or they stop being about the same people.
  q6_grp <- "CASE WHEN p.PATID IS NOT NULL THEN 'POMA-1L' ELSE 'other-1L' END"
  # LEFT JOIN, so a LOT1 patient with no cohort row is counted rather than
  # dropped: percentile_approx ignores NULLs, so a drop shrinks the median's
  # denominator while n_pts still reports the whole group. Q3 does the same
  # with missing_flag_rows.
  q6_ctes <- glue("
      WITH poma1l AS (SELECT DISTINCT cast(PATID as string) PATID FROM {lot_long}
                      WHERE LOT_NUM=1 AND array_contains(split(LOT_BASE_MEDS,' '),'{poma}')),
      lot1 AS (SELECT DISTINCT cast(PATID as string) PATID FROM {lot_long} WHERE LOT_NUM=1),
      fu AS (SELECT cast(PATID as string) PATID,
                    cast(INDEX_DATE as date) INDEX_DATE,
                    cast(ENDDATE as date)    ENDDATE,
                    cast(ENDDATE_CE as date) ENDDATE_CE,
                    cast(DEATH_DT as date)   DEATH_DT,
                    cast(FU_DAYS as int)     FU_DAYS,
                    cast(FU_DAYS_CE as int)  FU_DAYS_CE
             FROM {final_tbl})")
  q6_from <- "
      FROM lot1 l LEFT JOIN poma1l p USING (PATID) LEFT JOIN fu f ON f.PATID = l.PATID"
  if (have_final) {
    q6_tables[["Follow-up days by group (both definitions)"]] <- best_effort(
      db_q(con, glue("{q6_ctes}
      SELECT {q6_grp}                                    AS grp,
             count(*)                                    AS n_pts,
             sum(CASE WHEN f.PATID IS NULL THEN 1 ELSE 0 END) AS missing_cohort_rows,
             round(avg(f.FU_DAYS), 1)                    AS mean_fu_days,
             round(stddev_samp(f.FU_DAYS), 1)            AS sd_fu_days,
             percentile_approx(f.FU_DAYS, 0.25)          AS p25_fu_days,
             percentile_approx(f.FU_DAYS, 0.5)           AS median_fu_days,
             percentile_approx(f.FU_DAYS, 0.75)          AS p75_fu_days,
             round(avg(f.FU_DAYS_CE), 1)                 AS mean_fu_days_ce,
             round(stddev_samp(f.FU_DAYS_CE), 1)         AS sd_fu_days_ce,
             percentile_approx(f.FU_DAYS_CE, 0.25)       AS p25_fu_days_ce,
             percentile_approx(f.FU_DAYS_CE, 0.5)        AS median_fu_days_ce,
             percentile_approx(f.FU_DAYS_CE, 0.75)       AS p75_fu_days_ce,
             min(f.FU_DAYS_CE)                           AS min_fu_days_ce,
             max(f.FU_DAYS_CE)                           AS max_fu_days_ce
      {q6_from}
      GROUP BY 1 ORDER BY 1")), "POMA-1L vs other-1L follow-up days")

    # What ended it. A short median because people died and a short median
    # because they left the data are the same number and different findings.
    # "no cohort row" is a category rather than a silent drop, so the four
    # always sum to the group.
    q6_tables[["What ended follow-up, by group"]] <- best_effort(
      db_q(con, glue("{q6_ctes}
      SELECT grp, fu_ended_by, n_pts,
             round(100.0 * n_pts / sum(n_pts) OVER (PARTITION BY grp), 1) AS pct_of_grp
      FROM (
        SELECT {q6_grp} AS grp,
               CASE WHEN f.PATID IS NULL
                      THEN 'no cohort row (broken join)'
                    WHEN f.DEATH_DT IS NOT NULL AND f.DEATH_DT <= f.ENDDATE_CE
                      THEN 'died'
                    WHEN f.ENDDATE_CE < f.ENDDATE
                      THEN 'disenrolled'
                    ELSE 'followed to study end' END AS fu_ended_by,
               count(*) AS n_pts
        {q6_from}
        GROUP BY 1, 2
      ) e ORDER BY grp, fu_ended_by")), "POMA-1L vs other-1L follow-up end reason")

    # The mechanism, if the two medians differ. Accrual is the first thing to
    # rule out, and it is the one this cohort can rule out on its own.
    q6_tables[["Index year by group, with follow-up"]] <- best_effort(
      db_q(con, glue("{q6_ctes}
      SELECT {q6_grp}                             AS grp,
             cast(year(f.INDEX_DATE) as string)   AS index_year,
             count(*)                             AS n_pts,
             percentile_approx(f.FU_DAYS_CE, 0.5) AS median_fu_days_ce
      {q6_from}
      WHERE f.INDEX_DATE IS NOT NULL
      GROUP BY 1, 2 ORDER BY 1, 2")), "POMA-1L vs other-1L index year")

    q6_notes <- c(
      "READ THIS BEFORE Q2 AND Q4. Both are rates over a follow-up window, and the study end is fixed - so a group that indexed later",
      "has less room, and a lower rate on one side can be the calendar rather than the treatment.",
      "TWO DEFINITIONS. *_fu_days runs from the day after the index date to death or the study end and ignores disenrolment - the LOT",
      "run's primary analysis. *_fu_days_ce is also capped where continuous enrolment stops, which is the protocol's follow-up period",
      "and what the outcomes build censors on. Where the two differ, the difference is disenrolment.",
      "WHAT ENDED IT is in that order: a patient who disenrolled and died afterwards counts as disenrolled, because that death is",
      "outside the window this cohort observes. The categories are exclusive and cover the group. They are NOT the outcomes build's",
      "N_LOST_TO_FU / N_ONGOING, which are per-LINE and only over what is left after the next line, death and discontinuation.",
      "missing_cohort_rows / 'no cohort row' counts LOT1 patients with no row in the cohort table - a broken join, and it must be 0.",
      "The percentiles ignore NULLs, so a dropped patient would shrink the median's denominator while n_pts still counted them.",
      "INDEX YEAR is what to check first if the medians differ. Its n_pts excludes patients with no cohort row - they have no index",
      "date - so it is short by exactly missing_cohort_rows and matches once that is 0.")
  } else {
    q6_notes <- paste0("Q6 needs ", final_tbl,
                       ", which is unreadable this run - the follow-up columns are the cohort build's.")
  }
  add_sheet(name = "Q6 POMA & follow-up", title = "Q6 - follow-up length, POMA-1L against other-1L",
    subtitle = paste0("Whether the rates on the other tabs are measured over comparable windows. ",
                      "Cohort: ", cohort_label, "."),
    narrative = q6_notes, tables = q6_tables)

  # ---- write --------------------------------------------------------------
  xlsx <- file.path(out_dir, paste0("poma_studyteam_qs_ndmm_", stamp, ".xlsx"))
  wrote_xlsx <- wbx_write_workbook(sheets, xlsx, out_dir, stamp, allow_csv = allow_csv)
  log_msg(SEP)
  if (isTRUE(wrote_xlsx))
    log_msg("POMA-in-1L study-team questions complete. Excel workbook -> ", xlsx)
  else
    log_msg("POMA-in-1L study-team questions complete in DEGRADED mode: one CSV per table in ",
            out_dir, " (openxlsx unavailable). Install openxlsx to get the single .xlsx.")
  log_msg(SEP)
}

if (!interactive()) main()
