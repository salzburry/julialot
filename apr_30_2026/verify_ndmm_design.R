#!/usr/bin/env Rscript
# Verifies this project's contract: Overall stops at parent Step 6 and NDMM
# is the LOT1>=2017 cohort passing all six NDMM gates.

.script_dir <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(a)) dirname(normalizePath(sub("^--file=", "", a[1]))) else getwd()
})
source_dir <- file.path(.script_dir, "R")
source(file.path(source_dir, "load_inputs.R"))
load_pipeline_inputs(c(.script_dir, dirname(.script_dir)))
source(file.path(source_dir, "config_lot.R"))
source(file.path(source_dir, "db_utils_lot.R"))

bool <- function(name, default) {
  x <- toupper(trimws(Sys.getenv(name, unset = if (default) "TRUE" else "FALSE")))
  if (x %in% c("TRUE", "T", "1")) return(TRUE)
  if (x %in% c("FALSE", "F", "0")) return(FALSE)
  stop(name, " must be TRUE/FALSE; got '", x, "'.")
}
sq <- function(x) paste0("'", gsub("'", "''", x, fixed = TRUE), "'")
query <- function(con, sql) DBI::dbGetQuery(con, sql)
readable <- function(con, tbl, nonempty = FALSE) tryCatch({
  r <- query(con, if (nonempty) paste0("SELECT count(*) AS n FROM ", tbl)
                   else paste0("SELECT 1 AS ok FROM ", tbl, " LIMIT 1"))
  !nonempty || as.numeric(r$n[1]) > 0
}, error = function(e) FALSE)

check_csv <- function(file, cols) {
  path <- file.path(cfg$codelist_dir, file)
  if (!file.exists(path)) stop("Missing codelist: ", path)
  x <- read.csv(path, stringsAsFactors = FALSE, colClasses = "character", check.names = FALSE)
  if (!nrow(x)) stop("Codelist has zero rows: ", path)
  miss <- setdiff(tolower(cols), tolower(names(x)))
  if (length(miss)) stop(path, " missing column(s): ", paste(miss, collapse = ", "))
}

check_config <- function() {
  if (!bool("NDMM_PROJECT_MODE", TRUE)) return(invisible(FALSE))
  want <- c(APPLY_AGE_INCL=TRUE, APPLY_CE_B_INCL=TRUE, APPLY_CE_F_INCL=TRUE,
            APPLY_NO_BL_AGENTS_INCL=TRUE, APPLY_FU_AGENTS_INCL=TRUE,
            APPLY_BASELINE_MM_EXCL=FALSE, APPLY_OTHER_MALIG_EXCL=FALSE,
            APPLY_PREGNANCY_EXCL=FALSE, APPLY_CLINTRIAL_EXCL=FALSE)
  defaults <- c(APPLY_AGE_INCL=TRUE, APPLY_CE_B_INCL=TRUE, APPLY_CE_F_INCL=TRUE,
                APPLY_NO_BL_AGENTS_INCL=TRUE, APPLY_FU_AGENTS_INCL=TRUE,
                APPLY_BASELINE_MM_EXCL=TRUE, APPLY_OTHER_MALIG_EXCL=TRUE,
                APPLY_PREGNANCY_EXCL=TRUE, APPLY_CLINTRIAL_EXCL=TRUE)
  got <- vapply(names(want), function(n) bool(n, defaults[[n]]), logical(1))
  bad <- names(want)[got != want]
  if (length(bad)) stop("Overall must stop at Step 6. Fix stale env override(s): ",
                        paste0(bad, "=", got[bad], collapse = ", "))
  if (as.integer(cfg$outpatient_window) != 90L) stop("OUTPATIENT_WINDOW must be 90.")
  if (Sys.getenv("NDMM_LOT1_FROM", "2017-01-01") != "2017-01-01")
    stop("NDMM_LOT1_FROM must be 2017-01-01 for the primary run.")
  cat("[verify_ndmm_design] Config OK: Overall=Step 6; NDMM cutoff=2017-01-01.\n")
}

check_parent <- function(con) {
  cohort <- wrk(cfg$input_cohort_table); attr <- wrk("attrition_report")
  if (!readable(con, cohort, TRUE) || !readable(con, attr, TRUE))
    stop("Parent cohort/attrition metadata missing. Run FORCE_RERUN=TRUE Rscript run_all.R.")
  ncol <- paste0("n_", as.integer(cfg$outpatient_window))
  s <- query(con, paste0(
    "WITH latest AS (SELECT run_id, max(created_at) created_at FROM ", attr,
    " WHERE lower(final_table_name)=lower(", sq(cfg$input_cohort_table),
    ") GROUP BY run_id ORDER BY created_at DESC LIMIT 1), r AS (SELECT a.step_id,a.", ncol,
    " n FROM ", attr, " a JOIN latest l ON a.run_id=l.run_id WHERE lower(a.final_table_name)=lower(",
    sq(cfg$input_cohort_table), ")) SELECT ",
    "max(CASE WHEN step_id='06_step6_fu_therapy' THEN 1 ELSE 0 END) has_step6,",
    "max(CASE WHEN step_id IN ('07_step7_bl_mm_evidence','08_step8_other_cancer',",
    "'09_step9_pregnancy','10_step10_clintrial') THEN 1 ELSE 0 END) has_post6,",
    "max(CASE WHEN step_id='06_step6_fu_therapy' THEN n END) step6_n FROM r"))
  if (!nrow(s) || as.integer(s$has_step6[1]) != 1L || as.integer(s$has_post6[1]) != 0L)
    stop("Latest attrition run is not Step-6-only. Rebuild with FORCE_RERUN=TRUE.")
  cohort_n <- as.numeric(query(con, paste0("SELECT count(DISTINCT PATID) n FROM ", cohort))$n[1])
  if (cohort_n != as.numeric(s$step6_n[1]))
    stop("Parent table count does not match Step-6 attrition count. Rebuild with FORCE_RERUN=TRUE.")
  cat("[verify_ndmm_design] Parent Step-6 cohort OK; n=", format(cohort_n, big.mark=","), ".\n", sep="")
}

check_inputs <- function(con) {
  nonempty <- c(wrk(cfg$input_cohort_table), wrk("MAP_STACKED"), wrk("LOT_LONG"))
  raw <- c(cdm_src("member_enrollment"), cdm_src(cfg$tbl_medical), cdm_src(cfg$tbl_rx),
           cdm_src(cfg$tbl_med_diag), cdm_src(cfg$tbl_med_proc), cdm_src("confinement"))
  bad <- c(nonempty[!vapply(nonempty, function(t) readable(con,t,TRUE), logical(1))],
           raw[!vapply(raw, function(t) readable(con,t,FALSE), logical(1))])
  if (length(bad)) stop("Required NDMM input(s) missing/unreadable: ", paste(bad, collapse=", "))
}

check_post <- function(con) {
  flags <- wrk("NDMM_FLAGS_ALL"); lots <- wrk("NDMM_LOT_LONG_FILT")
  if (!readable(con, flags, TRUE) || !readable(con, lots, TRUE))
    stop("NDMM materialized outputs missing/empty: ", flags, " / ", lots)
  s <- query(con, paste0(
    "SELECT count(*) n_candidates, ",
    "sum(CASE WHEN CE_pre_lot1_12mo IS NULL OR CE_lot1_3mo_fu IS NULL OR NO_BELANTAMAB IS NULL ",
    "OR NO_PRIOR_MM_TX IS NULL OR NO_OTHER_CANCER_PRE_LOT1 IS NULL OR NO_PREGNANCY IS NULL THEN 1 ELSE 0 END) n_null, ",
    "sum(CASE WHEN CE_pre_lot1_12mo=1 AND CE_lot1_3mo_fu=1 AND NO_BELANTAMAB=1 ",
    "AND NO_PRIOR_MM_TX=1 AND NO_OTHER_CANCER_PRE_LOT1=1 AND NO_PREGNANCY=1 THEN 1 ELSE 0 END) n_final FROM ", flags))
  if (as.numeric(s$n_null[1]) != 0) stop("NDMM flag table contains NULL gate values.")
  n_final <- as.numeric(s$n_final[1])
  lot_n <- as.numeric(query(con, paste0("SELECT count(DISTINCT PATID) n FROM ", lots))$n[1])
  if (n_final <= 0 || lot_n != n_final) stop("Six-gate NDMM count does not match filtered LOT_LONG.")
  min_d <- as.Date(query(con, paste0("SELECT min(LOT_START_DT) d FROM ", lots, " WHERE LOT_NUM=1"))$d[1])
  if (is.na(min_d) || min_d < as.Date("2017-01-01")) stop("NDMM LOT1 cutoff check failed.")
  cat("[verify_ndmm_design] NDMM six-gate output OK; n=", format(n_final,big.mark=","), ".\n", sep="")
}

check_config()
check_csv("pregnancy.csv", c("code_type","code"))
check_csv("other_malig.csv", c("dx","icd_family","tumor_group"))
check_csv("cl_mma_codelist.csv", c("CL_CODE_TYPE","CL_CODE","CL_MEDICATION_FULL","CL_MED_CLASS","CL_MED_ABBR"))
stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")
con <- DBI::dbConnect(odbc::odbc(), dsn=cfg$dsn, pwd=cfg$pwd, timeout=120)
on.exit(try(DBI::dbDisconnect(con), silent=TRUE), add=TRUE)
check_inputs(con)
check_parent(con)
if ("--post-dashboard" %in% commandArgs(TRUE)) check_post(con)
cat("[verify_ndmm_design] verification passed.\n")
