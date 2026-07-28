#!/usr/bin/env Rscript
# =============================================================================
# build_lot1_flags.R -- the LOT1-anchored flag stage, standalone
# -----------------------------------------------------------------------------
#   Rscript "Jul 28/build_lot1_flags.R"
#
# Stage 3 of PLAN.md's four. Produces the two tables the NDMM cohort selects
# from, WITHOUT running a dashboard and WITHOUT an Overall cohort:
#
#   LOT1_STARTS      (PATID, INDEX_DATE, LOT1_START_DT)
#   LOT1_FLAGS_ALL   (PATID, INDEX_DATE, LOT1_START_DT, + one 0/1 column per
#                     LOT1-anchored criterion) -- NOTHING FILTERED
#
# Run order for a full NDMM build from scratch:
#
#   1. the cohort pipeline through step 23   -> ELIG_COH_ALLFLAGS
#   2. Rscript "Jul 28/build_ndmm.R" --index-only
#                                            -> coh_ndmm_index_sel, coh_index_union
#   3. the LOT build, INPUT_COHORT_TABLE=coh_index_union
#                                            -> LOT_LONG, MAP_STACKED
#   4. THIS SCRIPT                           -> LOT1_STARTS, LOT1_FLAGS_ALL
#   5. Rscript "Jul 28/build_ndmm.R"         -> the cohort + PLD
#
# Steps 1-3 are shared: run them once and BOTH cohorts select from the result.
#
# The criteria themselves live in apr_30_2026/R/lot1_flags.R, shared with
# 06_ndmm_dashboard.R so there is exactly one definition of each.
# =============================================================================

.root <- local({
  fa <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(fa)) dirname(normalizePath(
    gsub("~+~", " ", sub("^--file=", "", fa[1]), fixed = TRUE))) else getwd()
})

# The LOT helper stack. Defaults to the sibling apr_30_2026/ folder; override
# with APR30_DIR if the pipeline lives elsewhere (e.g. /mnt/code on Domino).
.apr30 <- Sys.getenv("APR30_DIR", unset = file.path(dirname(.root), "apr_30_2026"))
if (!dir.exists(file.path(.apr30, "R")))
  stop("cannot find the LOT helper stack at ", .apr30,
       "/R -- set APR30_DIR to the pipeline folder.", call. = FALSE)

library(glue)
library(DBI)
library(odbc)
.src <- function(f) source(file.path(.apr30, "R", f))
if (file.exists(file.path(.apr30, "R", "load_inputs.R"))) {
  .src("load_inputs.R")
  load_pipeline_inputs(c(.apr30, dirname(.apr30)))
}
.src("config_lot.R")      # cfg
.src("db_utils_lot.R")    # db_exec, db_q, run_step, wrk, cdm_src, log_msg
.src("codelists_lot.R")   # load_codelist_csv
.src("lot1_flags.R")      # the criteria

# ---- inputs -----------------------------------------------------------------
# PATIENT_INPUT is the whole point: point it at the union view and no Overall
# cohort has to exist. It defaults to the union view for that reason -- set it
# to ELIG_COH_FINAL for the legacy path.
PATIENT_INPUT <- Sys.getenv("LOT1_PATIENT_INPUT", unset = "coh_index_union")
LOT_LONG      <- Sys.getenv("LOT_LONG_TABLE",     unset = "LOT_LONG")
MAP_STACKED   <- Sys.getenv("MAP_STACKED_TABLE",  unset = "MAP_STACKED")

main <- function() {
  # Same connection pattern as 02_lot1.R:63 and 05_regimen_dashboard.R:1622.
  stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")
  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  patient_input <- wrk(PATIENT_INPUT)
  lot_long      <- wrk(LOT_LONG)
  map_stacked   <- wrk(MAP_STACKED)
  medical_tbl   <- cdm_src(cfg$tbl_medical)
  rx_tbl        <- cdm_src(cfg$tbl_rx)
  med_diag_tbl  <- cdm_src(cfg$tbl_med_diag)
  med_proc_tbl  <- cdm_src(cfg$tbl_med_proc)
  confinement   <- cdm_src(LOT1_TBL_CONFINEMENT)

  log_msg(strrep("=", 60))
  log_msg("LOT1 FLAG STAGE")
  log_msg("  patient input : ", patient_input)
  log_msg("  LOT_LONG      : ", lot_long)
  log_msg("  1L cutoff     : ", LOT1_FROM)
  log_msg("  pre-1L window : ", LOT1_PRE_DAYS, " days")
  log_msg("  -> ", wrk(LOT1_STARTS_TBL), ", ", wrk(LOT1_FLAGS_ALL_TBL))
  log_msg(strrep("=", 60))

  # A filter whose source is unreadable is SKIPPED, not fatal -- its flag then
  # passes every patient. Same policy as the dashboard; reported either way, so
  # a skipped filter can never be mistaken for a criterion that found nothing.
  bela_ok        <- .lot1_table_ok(con, map_stacked)
  priortx_ok     <- .lot1_table_ok(con, medical_tbl) && .lot1_table_ok(con, rx_tbl)
  othercancer_ok <- .lot1_table_ok(con, med_diag_tbl) &&
                    .lot1_table_ok(con, medical_tbl) &&
                    .lot1_table_ok(con, confinement)

  log_msg("Building enrollment spans (gap_days=", LOT1_GAP_DAYS, ")")
  build_lot1_enrollment_spans(con)
  build_lot1_enrollment_spans(con, LOT1_ENROLL_SPANS_STRICT, 0L)  # no-gap, 3-mo FU CE

  log_msg("Pulling LOT1 starts (>= ", LOT1_FROM, ") from ", lot_long)
  build_lot1_starts(con, lot_long, patient_input)
  materialize_lot1_starts(con, run_step)   # before the scans: they all join it

  if (priortx_ok) {
    log_msg("Loading MMA codelist (steroid abbrs excluded)")
    db_exec(con, build_lot1_mma_codelist())
    log_msg("Scanning medical + rx for MM Tx in [LOT1-", LOT1_PRE_DAYS, ", LOT1-1]")
    build_lot1_therapy_pre(con, medical_tbl, rx_tbl)
  } else {
    log_msg("  WARN: medical/rx unreadable; prior-MM-Tx exclusion SKIPPED ",
            "(NO_PRIOR_MM_TX passes everyone this run).")
  }

  if (othercancer_ok) {
    log_msg("Loading other-malignancy codelist")
    build_lot1_other_malig_codes(con)
    build_lot1_med_claim_header_and_confinement(con, medical_tbl, confinement)
    log_msg("Scanning other-malignancy claims in [LOT1-", LOT1_PRE_DAYS, ", LOT1-1]")
    build_lot1_other_malig_pre(con, med_diag_tbl)
  } else {
    log_msg("  WARN: med_diagnosis/medical/confinement unreadable; other-cancer ",
            "exclusion SKIPPED (NO_OTHER_CANCER_PRE_LOT1 passes everyone).")
  }

  preg_ok <- .lot1_table_ok(con, med_diag_tbl) && .lot1_table_ok(con, medical_tbl) &&
             .lot1_table_ok(con, med_proc_tbl)
  if (preg_ok) {
    preg_ok <- tryCatch({
      log_msg("Loading pregnancy codelist and scanning [", LOT1_STUDY_START, ", ",
              cfg$study_end, "]")
      build_lot1_preg_codes(con)
      build_lot1_pregnancy_patids(con, med_diag_tbl, medical_tbl, med_proc_tbl)
      TRUE
    }, error = function(e) {
      log_msg("  WARN: pregnancy exclusion SKIPPED (", conditionMessage(e), ").")
      FALSE
    })
  } else {
    log_msg("  WARN: source tables unreadable; pregnancy exclusion SKIPPED.")
  }
  if (!bela_ok)
    log_msg("  WARN: ", map_stacked, " unreadable; belantamab exclusion SKIPPED.")

  log_msg("Building the flag table (no filtering)")
  build_lot1_flags(con, patient_input, map_stacked,
                   q2_ok_belantamab  = bela_ok,
                   q2_ok_priortx     = priortx_ok,
                   q2_ok_othercancer = othercancer_ok,
                   q2_ok_pregnancy   = preg_ok)
  materialize_lot1_flags(con, run_step)

  # Per-flag prevalence. Not an attrition funnel (these are not applied in any
  # order here) -- just how many candidates each criterion would keep, so a
  # skipped filter showing 100% is obvious at a glance.
  summ <- db_q(con, glue("
    SELECT count(*) AS n_rows,
           count(DISTINCT PATID) AS n_patients,
           sum(CE_pre_lot1_12mo)         AS n_ce_pre_lot1,
           sum(CE_lot1_3mo_fu)           AS n_ce_fu_3mo,
           sum(NO_BELANTAMAB)            AS n_no_belantamab,
           sum(NO_PRIOR_MM_TX)           AS n_no_prior_tx,
           sum(NO_OTHER_CANCER_PRE_LOT1) AS n_no_other_cancer,
           sum(NO_PREGNANCY)             AS n_no_pregnancy
    FROM {wrk(LOT1_FLAGS_ALL_TBL)}"))
  log_msg(strrep("-", 60))
  log_msg("LOT1 candidates: ", summ$n_rows, " rows / ", summ$n_patients, " patients")
  for (k in setdiff(names(summ), c("n_rows", "n_patients")))
    log_msg(sprintf("  %-22s %10s  (%.1f%%)", k, format(summ[[k]], big.mark = ","),
                    100 * summ[[k]] / max(summ$n_rows, 1)))
  log_msg(strrep("=", 60))
  log_msg("Done. Now run: Rscript \"Jul 28/build_ndmm.R\"")
  invisible(summ)
}

if (!interactive()) main()
