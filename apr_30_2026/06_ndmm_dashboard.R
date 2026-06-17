#!/usr/bin/env Rscript
# NDMM (newly-diagnosed multiple myeloma) cohort dashboard. Runs the
# same regimen-transition / steroid / coverage views as the overall
# regimen dashboard (05_regimen_dashboard.R), but on a 1L
# newly-diagnosed cohort. It layers a LOT1 eligibility cutoff plus six
# IE post-filters on top of the parent ELIG_COH_FINAL:
#
#   0. LOT1_START_DT >= NDMM_LOT1_FROM   (default 2017-01-01; parent's
#                                         id_start defaults to 2016-01-01)
#   1. 12-mo CE before LOT1_START_DT     (parent CE_b is 6-mo before MM-dx)
#   2. 3-mo follow-up CE from LOT1       (strict NO-gap, death-aware; spec
#                                         says no gaps for follow-up CE)
#   3. No belantamab in any LOT          (no parent equivalent)
#   4. No MM oncology Tx in 12-mo
#      pre-LOT1 baseline                 (parent's MM_BASELINE_EVIDENCE is
#                                         6-mo before MM-dx; re-anchored
#                                         and re-derived from raw claims)
#   5. No other active cancer in 12-mo
#      pre-LOT1 baseline                 (parent's OTHER_MALIGN_FLAG is
#                                         6-mo before MM-dx; re-anchored
#                                         and re-derived from raw claims)
#   6. No pregnancy                      (re-scanned from pregnancy.csv over
#                                         the study period; NDMM candidates)
#
#   Rscript apr_30_2026/06_ndmm_dashboard.R
#
# Output: ndmm_dashboard.html in cfg$output_dir.
#
# Reuses 05_regimen_dashboard.R verbatim - all regimen-transition
# builders, steroid CSV, category CSV, coverage QC. This script just
# (a) computes the NDMM cohort, (b) writes a filtered LOT_LONG temp
# view, then (c) calls the regimen builders against that view. See
# 06_ndmm_dashboard.md for the per-filter SQL pattern, required parent
# inputs, and known gaps. Parent pipeline files are untouched.

.script_dir <- local({
  override <- getOption("ndmm_dashboard.script_dir", NULL)
  if (!is.null(override)) return(override)
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

# Source the overall regimen dashboard WITHOUT triggering its
# auto-main() and pin its R/ helper + CSV resolution to this folder.
options(regimen_dashboard.no_autorun = TRUE)
options(regimen_dashboard.script_dir = .script_dir)
source(file.path(.script_dir, "05_regimen_dashboard.R"))

# Needs load_codelist_csv() to materialise the MMA codelist as a VALUES
# fragment - the parent uses the same loader for S01 / step 03.
# 05_regimen_dashboard.R does not source codelists_lot.R itself.
source(file.path(.script_dir, "R", "codelists_lot.R"))

# NDMM-only constants. Distinct view names so this script can run
# concurrently with 05_regimen_dashboard.R without clobbering its temp views.
NDMM_LOT_LONG_FILT       <- "_ndmm_lot_long"
# Persisted (work-schema) twin of NDMM_LOT_LONG_FILT. The temp view joins
# LOT_LONG to the NDMM cohort and is read ~20x downstream (KPIs, gallery,
# validation, modal map, and ~13x inside the LOT1-5 detail); materializing it
# once and repointing the view collapses those rejoins (same pattern as
# NDMM_FLAGS_ALL / LOT_LONG_AUG).
NDMM_LOT_LONG_FILT_TBL   <- "NDMM_LOT_LONG_FILT"
NDMM_ENROLL_SPANS        <- "_ndmm_enroll_spans"
NDMM_ENROLL_SPANS_STRICT <- "_ndmm_enroll_spans_strict"  # no-gap spans for the 3-mo FU CE
NDMM_LOT1_STARTS         <- "_ndmm_lot1_starts"
NDMM_MMA_CODELIST        <- "_ndmm_mma_codelist"
NDMM_THERAPY_PRE_LOT1    <- "_ndmm_therapy_pre_lot1"
NDMM_OTHER_MALIG_CODES   <- "_ndmm_other_malig_codes"
NDMM_MED_CLAIM_HEADER    <- "_ndmm_med_claim_header"
NDMM_CONFINEMENT         <- "_ndmm_confinement"
NDMM_OTHER_MALIG_PATIDS  <- "_ndmm_other_malig_patids"
NDMM_FLAGS_ALL           <- "_ndmm_flags_all"   # per-PATID filter flags (for attrition)
# Persisted (work-schema) twin of NDMM_FLAGS_ALL. The temp view above embeds
# every NDMM raw-claim scan (pregnancy / belantamab / prior-Tx / other-cancer)
# and is read many times downstream; materializing it once to this table and
# repointing the view collapses those repeated scans to a single computation.
NDMM_FLAGS_ALL_TBL       <- "NDMM_FLAGS_ALL"
NDMM_PATIDS       <- "_ndmm_patids"
NDMM_PREG_CODES          <- "_ndmm_preg_codes"
NDMM_PREGNANCY_PATIDS    <- "_ndmm_pregnancy_patids"
NDMM_STUDY_START         <- Sys.getenv("STUDY_START", unset = "2015-07-01")
NDMM_PRE_LOT1_DAYS       <- 365L  # NDMM spec: 12-mo CE/baseline before 1L index date

# Tumor_group labels treated as NON-exclusionary for the NDMM
# other-cancer filter ONLY (NDMM scope). These are plasma-cell /
# MM-adjacent diseases - the index MM itself (plasma cell leukemia,
# solitary + extramedullary plasmacytoma), its precursor (monoclonal
# gammopathy / MGUS), and MM bone disease (secondary malignant neoplasm
# of bone). The protocol's "another cancer" exclusion (studypop spec
# Criterion 7) targets a cancer DISTINCT from the index MM, so flagging
# these as non-exclusionary moves the NDMM filter toward protocol intent.
# Parent pipeline (step 22) and the shared other_malig.csv are NOT
# changed - this list only adds a flag column at NDMM codelist-load time.
#
# Matched case/whitespace-insensitively against the codelist's
# tumor_group column. Only the five "NOT HAVING ACHIEVED REMISSION"
# labels named in the spec are listed; "in remission" variants are left in
# the filter pending confirmation (see README). build_ndmm_other_-
# malig_codes() logs how many of these actually matched the codelist;
# a match count < length(this) means the stored labels differ from the
# wording below and is a run-review blocker.
NDMM_MM_ADJACENT_OVERRIDE <- c(
  "MONOCLONAL GAMMOPATHY",
  "SECONDARY MALIGNANT NEOPLASM OF BONE",
  "SOLITARY PLASMACYTOMA NOT HAVING ACHIEVED REMISSION",
  "PLASMA CELL LEUKEMIA NOT HAVING ACHIEVED REMISSION",
  "EXTRAMEDULLARY PLASMACYTOMA NOT HAVING ACHIEVED REMISSION"
)

# LOT1 eligible treatment cutoff (NDMM spec: "Received an eligible
# treatment for MM ... on or after 01 Jan 2017"). Hard-enforced in
# build_lot1_starts_ndmm() so the LOT1 view never returns pre-cutoff
# starts. Env-overridable for sensitivity runs (e.g. 2018-01-01).
# Independent of parent cfg$id_start which defaults to 2016-01-01.
NDMM_LOT1_FROM <- Sys.getenv("NDMM_LOT1_FROM", unset = "2017-01-01")

# Confinement table name (raw CDM) for the other-cancer pre-LOT1 IP
# classification. config_lot.R does not define this so NDMM sets it
# locally with the same env-var name the cohort pipeline uses.
NDMM_TBL_CONFINEMENT <- Sys.getenv("TBL_CONFINEMENT", unset = "confinement")

# Steroid MED_ABBR values to exclude from the "MM oncology therapy"
# pre-LOT1 check. Same tokens as 05_regimen_dashboard.R::STEROID_TOKENS so the
# NDMM exclusion stays consistent with the steroid-augmentation semantics.
# (Steroids are supportive care; the spec wording "MM oncology therapy"
# targets actual MM agents, not supportive care.)
NDMM_STEROID_ABBRS <- c("DEX","DEXA","DEXAMETHASONE","PRED","PREDNISONE")

# Cohort-pipeline knobs that 05_regimen_dashboard.R's config_lot.R does NOT
# define (the cohort pipeline uses config_prompts.R instead). Defaults
# mirror config_prompts.R:43,90,98 verbatim, with env-var overrides
# matching the same env-var names so a user who already exports
# TBL_MEMBER_ENROLLMENT / GAP_DAYS / FINAL_TABLE_NAME for the parent
# cohort run picks up the same values here.
NDMM_TBL_MEMBER_ENROLLMENT <- Sys.getenv("TBL_MEMBER_ENROLLMENT",
                                       unset = "member_enrollment")
NDMM_GAP_DAYS              <- as.integer(Sys.getenv("GAP_DAYS",
                                                  unset = "30"))
NDMM_FINAL_TABLE_NAME      <- Sys.getenv("FINAL_TABLE_NAME",
                                       unset = "ELIG_COH_FINAL")

# Build enrollment_spans (with NDMM_GAP_DAYS allowance) directly from
# member_enrollment - the parent's temp view isn't persisted, so we
# rebuild it inside this script. SQL mirrors pipeline_steps.R:382-421
# verbatim so the gap semantics stay identical to CE_b/CE_f.
build_enrollment_spans_ndmm <- function(con, view = NDMM_ENROLL_SPANS,
                                        gap_days = NDMM_GAP_DAYS) {
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {view} AS
    WITH base AS (
      SELECT PATID,
             cast(ELIGEFF as date) AS elig_eff,
             cast(ELIGEND as date) AS elig_end
      FROM {cdm_src(NDMM_TBL_MEMBER_ENROLLMENT)}
      WHERE ELIGEFF IS NOT NULL AND ELIGEND IS NOT NULL
    ),
    ordered AS (
      SELECT *,
        max(elig_end) OVER (
          PARTITION BY PATID
          ORDER BY elig_eff, elig_end
          ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ) AS max_end_so_far
      FROM base
    ),
    flagged AS (
      SELECT *,
        CASE WHEN max_end_so_far IS NULL THEN 1
             WHEN elig_eff <= date_add(max_end_so_far, {gap_days} + 1) THEN 0
             ELSE 1 END AS new_grp
      FROM ordered
    ),
    grouped AS (
      SELECT *,
        sum(new_grp) OVER (PARTITION BY PATID ORDER BY elig_eff, elig_end
                           ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS grp_id
      FROM flagged
    )
    SELECT PATID, grp_id,
           min(elig_eff) AS cov_start,
           max(elig_end) AS cov_end
    FROM grouped
    GROUP BY PATID, grp_id
  "))
}

# LOT1_START_DT per patient (the '1L cohort index date'), with the
# NDMM_LOT1_FROM cutoff enforced. Patients whose LOT1 starts before the
# cutoff are dropped from this view, which then propagates to every
# downstream NDMM step (CE / belantamab / MM-Tx / other-cancer all join
# from here).
build_lot1_starts_ndmm <- function(con, lot_long) {
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_LOT1_STARTS} AS
    SELECT cast(PATID as string) AS PATID,
           LOT_START_DT AS LOT1_START_DT
    FROM {lot_long}
    WHERE LOT_NUM = 1
      AND LOT_START_DT IS NOT NULL
      AND LOT_START_DT >= date('{NDMM_LOT1_FROM}')
  "))
}

# MMA codelist as a NDMM-side VALUES fragment. Same CSV (cl_mma_codelist.csv)
# and same column normalisation as parent S01 / pipeline_steps.R step 03,
# but materialised inside this script so the prior-MM-Tx scan does not
# depend on the parent having left mma_codelist alive in the session.
# Steroid MED_ABBR rows are dropped here, once, so every downstream query
# inherits the steroid exclusion without having to repeat it.
build_ndmm_mma_codelist <- function() {
  codelist_src <- load_codelist_csv(
    "cl_mma_codelist.csv",
    c("CL_CODE_TYPE", "CL_CODE", "CL_MEDICATION_FULL", "CL_MED_CLASS", "CL_MED_ABBR"))
  ster_in <- paste0("'", NDMM_STEROID_ABBRS, "'", collapse = ",")
  glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_MMA_CODELIST} AS
    SELECT upper(trim(CL_CODE_TYPE)) AS code_type,
           upper(regexp_replace(trim(CL_CODE), '[^A-Za-z0-9]', '')) AS code,
           upper(trim(CL_MED_ABBR))  AS med_abbr
    FROM {codelist_src}
    WHERE CL_CODE      IS NOT NULL AND trim(CL_CODE)      <> ''
      AND CL_CODE_TYPE IS NOT NULL AND trim(CL_CODE_TYPE) <> ''
      AND upper(coalesce(CL_MED_ABBR, '')) NOT IN ({ster_in})
  ")
}

# Distinct PATIDs with any MM oncology therapy claim in
# [LOT1_START - NDMM_PRE_LOT1_DAYS, LOT1_START - 1]. Mirrors the parent's
# pipeline_steps.R:646-696 therapy_events four-source pattern
# (medical PROC_CD, medical BILL_PROC_CD, medical NDC, rx NDC) with
# NDC11 normalisation, but with a per-PATID date window driven off
# LOT1_START_DT instead of [study_start, study_end].
#
# This raw-claim scan is necessary because the parent's persisted
# MMA_MED_PROCESSED is built with `FST_DT >= INDEX_DATE` (MM-dx anchor)
# on every source branch (02_lot1.R:316,336,359,386). It therefore
# cannot see any claims before the MM diagnosis, and would miss MM
# therapy occurring in the [LOT1_START - 365, INDEX_DATE - 1] portion
# of the 12-month 1L baseline that the NDMM spec requires.
build_ndmm_therapy_pre_lot1 <- function(con, medical_tbl, rx_tbl) {
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_THERAPY_PRE_LOT1} AS
    WITH med_proc AS (
      SELECT /*+ BROADCAST(c) */ cast(m.PATID as string) AS PATID
      FROM {medical_tbl} m
      INNER JOIN {NDMM_LOT1_STARTS} l1 ON cast(m.PATID as string) = l1.PATID
      INNER JOIN {NDMM_MMA_CODELIST} c
        ON c.code_type IN ('HCPCS','CPT')
       AND upper(regexp_replace(coalesce(cast(m.PROC_CD as string),''), '[^A-Za-z0-9]', '')) = c.code
      WHERE cast(m.FST_DT as date)
              BETWEEN date_sub(l1.LOT1_START_DT, {NDMM_PRE_LOT1_DAYS})
                  AND date_sub(l1.LOT1_START_DT, 1)
    ),
    med_bill AS (
      SELECT /*+ BROADCAST(c) */ cast(m.PATID as string) AS PATID
      FROM {medical_tbl} m
      INNER JOIN {NDMM_LOT1_STARTS} l1 ON cast(m.PATID as string) = l1.PATID
      INNER JOIN {NDMM_MMA_CODELIST} c
        ON c.code_type = 'HCPCS'
       AND upper(regexp_replace(coalesce(cast(m.BILL_PROC_CD as string),''), '[^A-Za-z0-9]', '')) = c.code
      WHERE cast(m.FST_DT as date)
              BETWEEN date_sub(l1.LOT1_START_DT, {NDMM_PRE_LOT1_DAYS})
                  AND date_sub(l1.LOT1_START_DT, 1)
    ),
    med_ndc AS (
      SELECT /*+ BROADCAST(c) */ cast(m.PATID as string) AS PATID
      FROM {medical_tbl} m
      INNER JOIN {NDMM_LOT1_STARTS} l1 ON cast(m.PATID as string) = l1.PATID
      INNER JOIN {NDMM_MMA_CODELIST} c
        ON c.code_type = 'NDC'
       AND lpad(regexp_replace(coalesce(cast(m.NDC as string),''), '[^0-9]', ''), 11, '0')
         = lpad(regexp_replace(c.code, '[^0-9]', ''), 11, '0')
      WHERE cast(m.FST_DT as date)
              BETWEEN date_sub(l1.LOT1_START_DT, {NDMM_PRE_LOT1_DAYS})
                  AND date_sub(l1.LOT1_START_DT, 1)
    ),
    rx_ndc AS (
      SELECT /*+ BROADCAST(c) */ cast(r.PATID as string) AS PATID
      FROM {rx_tbl} r
      INNER JOIN {NDMM_LOT1_STARTS} l1 ON cast(r.PATID as string) = l1.PATID
      INNER JOIN {NDMM_MMA_CODELIST} c
        ON c.code_type = 'NDC'
       AND lpad(regexp_replace(coalesce(cast(r.NDC as string),''), '[^0-9]', ''), 11, '0')
         = lpad(regexp_replace(c.code, '[^0-9]', ''), 11, '0')
      WHERE cast(r.FILL_DT as date)
              BETWEEN date_sub(l1.LOT1_START_DT, {NDMM_PRE_LOT1_DAYS})
                  AND date_sub(l1.LOT1_START_DT, 1)
    )
    SELECT DISTINCT PATID FROM med_proc
    UNION SELECT DISTINCT PATID FROM med_bill
    UNION SELECT DISTINCT PATID FROM med_ndc
    UNION SELECT DISTINCT PATID FROM rx_ndc
  "))
}

# Other-malignancy codelist loaded from cl_other_malignancies CSV
# (default file: other_malig.csv, per config_prompts.R:76). Same loader
# and column normalisation as parent pipeline_steps.R step 06 (which
# materialises work('other_malig_codes')). Built here so the NDMM IP/OP
# scan does not depend on the parent leaving its temp view alive.
#
# Tags each row with is_mm_adjacent_override (1 for the
# NDMM_MM_ADJACENT_OVERRIDE tumor groups, else 0). The actual exclusion
# scan (build_ndmm_other_malig_pre_lot1) reads only
# is_mm_adjacent_override = 0 rows; the QC card reads all rows so the
# overridden groups stay visible. Logs how many of the expected override
# labels matched the codelist - a partial match means the stored labels
# differ from NDMM_MM_ADJACENT_OVERRIDE and the override is a silent no-op
# for the unmatched groups (run-review blocker). Takes con (was a pure
# SQL-string builder) so it can run the post-create match-count probe.
build_ndmm_other_malig_codes <- function(con) {
  src <- load_codelist_csv(
    "other_malig.csv",
    c("dx", "icd_family", "tumor_group"))
  ovr_in <- paste(sprintf("'%s'", gsub("'", "''", NDMM_MM_ADJACENT_OVERRIDE)),
                  collapse = ", ")
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_OTHER_MALIG_CODES} AS
    SELECT
      upper(tumor_group) AS tumor_group,
      CASE WHEN upper(icd_family) IN ('9','ICD9','ICD-9','ICD9DIAG') THEN 'ICD9' ELSE 'ICD10' END AS icd_family,
      upper(regexp_replace(trim(dx), '[^A-Za-z0-9]', '')) AS dx,
      CASE WHEN upper(trim(tumor_group)) IN ({ovr_in}) THEN 1 ELSE 0 END AS is_mm_adjacent_override
    FROM {src}
    WHERE dx IS NOT NULL AND tumor_group IS NOT NULL
  "))
  n_exp     <- length(NDMM_MM_ADJACENT_OVERRIDE)
  n_matched <- tryCatch(as.integer(db_q(con, glue("
    SELECT count(DISTINCT tumor_group) AS n
    FROM {NDMM_OTHER_MALIG_CODES}
    WHERE is_mm_adjacent_override = 1
  "))$n), error = function(e) NA_integer_)
  log_msg("  NDMM other-cancer override: matched ",
          if (is.na(n_matched)) "?" else n_matched, " of ", n_exp,
          " expected MM-adjacent tumor_group labels",
          if (is.na(n_matched) || n_matched < n_exp)
            paste0(" - WARNING: < expected. Inspect 'SELECT DISTINCT ",
                   "tumor_group FROM ", NDMM_OTHER_MALIG_CODES, "' on the ",
                   "warehouse and align NDMM_MM_ADJACENT_OVERRIDE to the ",
                   "stored labels before trusting the NDMM count.")
          else "")
  invisible(n_matched)
}

# 5-column claim-header view used for IP/OP classification of other-
# cancer diagnoses. Mirror of parent step 07a (pipeline_steps.R:145-
# 171) but with a wider lower date bound so the NDMM pre-LOT1 baseline
# (which can extend back to NDMM_LOT1_FROM - 365 days, i.e. one year
# before the cutoff) is fully visible. Upper bound is study_end.
# Confinement view mirrors parent step 07b verbatim.
build_ndmm_med_claim_header_and_confinement <- function(con, medical_tbl,
                                                      confinement_tbl) {
  lower <- glue("date_sub(date('{NDMM_LOT1_FROM}'), {NDMM_PRE_LOT1_DAYS})")
  upper <- glue("date('{cfg$study_end}')")
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_MED_CLAIM_HEADER} AS
    SELECT PATID, PAT_PLANID, CLMID, FST_DT, LOC_CD,
           max(CONF_ID) AS CONF_ID,
           max(POS)     AS POS,
           max(TOS_CD)  AS TOS_CD
    FROM {medical_tbl}
    WHERE FST_DT BETWEEN {lower} AND {upper}
    GROUP BY PATID, PAT_PLANID, CLMID, FST_DT, LOC_CD
  "))
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_CONFINEMENT} AS
    SELECT DISTINCT PATID, CONF_ID,
           cast(ADMIT_DATE as date) AS ADMIT_DATE,
           cast(DISCH_DATE as date) AS DISCH_DATE
    FROM {confinement_tbl}
    WHERE CONF_ID IS NOT NULL
      AND ADMIT_DATE IS NOT NULL
      AND DISCH_DATE IS NOT NULL
  "))
}

# Distinct PATIDs with evidence of another active cancer in the
# [LOT1_START - 365, LOT1_START - 1] window. Re-anchored from parent
# step 22 (pipeline_steps.R:858-947) which uses [INDEX_DATE - 183,
# INDEX_DATE - 1] (6-mo pre-MM-dx). Logic is identical:
#
#   - Path A: >=1 inpatient claim for a tumor group in baseline
#   - Path B: >=2 outpatient claims on separate days within 30d for
#            the same tumor group, where the FIRST falls in baseline
#            (the second can fall after LOT1 start, matching parent)
#
# IP/OP classification uses the same POS/TOS/CONF_ID predicate as the
# parent. Tumor-group grain is preserved end-to-end.
build_ndmm_other_malig_pre_lot1 <- function(con, med_diag_tbl) {
  lower <- glue("date_sub(date('{NDMM_LOT1_FROM}'), {NDMM_PRE_LOT1_DAYS})")
  upper <- glue("date('{cfg$study_end}')")
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_OTHER_MALIG_PATIDS} AS
    WITH dx AS (
      SELECT d.PATID, d.PAT_PLANID, d.CLMID, d.FST_DT, d.LOC_CD,
             cast(d.FST_DT as date) AS event_dt,
             upper(regexp_replace(d.DIAG, '[^A-Za-z0-9]', '')) AS dx,
             CASE WHEN upper(d.ICD_FLAG) IN ('9','ICD9','ICD-9') THEN 'ICD9' ELSE 'ICD10' END AS icd_family
      FROM {med_diag_tbl} d
      WHERE FST_DT BETWEEN {lower} AND {upper}
    ),
    dx_mapped AS (
      -- is_mm_adjacent_override = 0 only: the five plasma-cell /
      -- MM-adjacent tumor groups are NOT exclusionary for NDMM (NDMM
      -- scope). The QC card scans the same codelist WITHOUT this
      -- predicate so the overridden groups still show in the breakdown.
      SELECT /*+ BROADCAST(o) */
             dx.PATID, dx.PAT_PLANID, dx.CLMID, dx.FST_DT, dx.LOC_CD,
             dx.event_dt, o.tumor_group
      FROM dx
      INNER JOIN {NDMM_OTHER_MALIG_CODES} o
              ON dx.dx = o.dx AND dx.icd_family = o.icd_family
             AND o.is_mm_adjacent_override = 0
    ),
    dx_with_setting AS (
      SELECT dm.PATID, dm.CLMID, dm.event_dt, dm.tumor_group,
             CASE WHEN h.POS IN ('21', '51', '61')
                    OR h.TOS_CD IN ('FAC_IP.ACUTE', 'FAC_IP.REHSNF', 'PROF.INPVIS', 'FAC_IP.SNF')
                    OR cf.CONF_ID IS NOT NULL
                  THEN 1 ELSE 0 END AS inpatient_flg
      FROM dx_mapped dm
      INNER JOIN {NDMM_MED_CLAIM_HEADER} h
            ON dm.PATID      =   h.PATID
           AND dm.CLMID      =   h.CLMID
           AND dm.FST_DT     =   h.FST_DT
           AND dm.PAT_PLANID <=> h.PAT_PLANID
           AND dm.LOC_CD     <=> h.LOC_CD
      LEFT JOIN {NDMM_CONFINEMENT} cf
        ON h.PATID = cf.PATID AND h.CONF_ID = cf.CONF_ID
    ),
    inpatient_flag AS (
      SELECT DISTINCT PATID, tumor_group, event_dt
      FROM dx_with_setting WHERE inpatient_flg = 1
    ),
    outpatient_dates AS (
      SELECT DISTINCT PATID, tumor_group, event_dt
      FROM dx_with_setting WHERE inpatient_flg = 0
    ),
    with_next AS (
      SELECT PATID, tumor_group, event_dt,
             lead(event_dt) OVER (PARTITION BY PATID, tumor_group ORDER BY event_dt) AS next_dt
      FROM outpatient_dates
    ),
    outpatient_pairs AS (
      SELECT PATID, tumor_group, event_dt AS first_dt, next_dt,
             datediff(next_dt, event_dt) AS diff_days
      FROM with_next WHERE next_dt IS NOT NULL
    ),
    l1 AS (
      SELECT cast(PATID as string) AS PATID, LOT1_START_DT,
             date_sub(LOT1_START_DT, {NDMM_PRE_LOT1_DAYS}) AS pre_lot1_start,
             date_sub(LOT1_START_DT, 1)                  AS pre_lot1_end
      FROM {NDMM_LOT1_STARTS}
    ),
    hits AS (
      SELECT DISTINCT l1.PATID
      FROM l1
      LEFT JOIN inpatient_flag ip
             ON cast(ip.PATID as string) = l1.PATID
            AND ip.event_dt BETWEEN l1.pre_lot1_start AND l1.pre_lot1_end
      LEFT JOIN outpatient_pairs op
             ON cast(op.PATID as string) = l1.PATID
            AND op.diff_days <= 30
            AND op.first_dt BETWEEN l1.pre_lot1_start AND l1.pre_lot1_end
      WHERE ip.PATID IS NOT NULL OR op.PATID IS NOT NULL
    )
    SELECT PATID FROM hits
  "))
}

# Per-PATID flag table for the six NDMM filters layered on top of
# ELIG_COH_FINAL. Rows are restricted to (ELIG_COH_FINAL INNER JOIN
# LOT1) - i.e. patients in the parent cohort who actually have a 1L
# treatment in LOT_LONG that starts on/after NDMM_LOT1_FROM. Flags:
#
#   CE_pre_lot1_12mo        : >=1 enrollment span covers
#                             [LOT1_START - NDMM_PRE_LOT1_DAYS, LOT1_START - 1]
#                             (NDMM spec: 12-mo CE before 1L; same gap
#                             semantics as parent CE_b/CE_f via
#                             NDMM_ENROLL_SPANS)
#
#   NO_BELANTAMAB           : zero MAP_STACKED rows for the PATID where
#                             MAP_MED_TYPE LIKE 'BEL%'. Narrower than the
#                             lot1_studyteam_qs.R inventory predicate
#                             (which adds MAP_MED_CLASS LIKE '%BCMA%' to
#                             also catch bispecifics and CAR-T for
#                             descriptive counting): the exclusion is
#                             belantamab specifically, so we drop the
#                             class match. Because MAP_STACKED only
#                             contains agents on the parent's MMA
#                             codelist, BEL* within MAP_STACKED reliably
#                             means belantamab.
#
#   NO_PRIOR_MM_TX          : zero PATID rows in NDMM_THERAPY_PRE_LOT1 (the
#                             raw-claim four-source scan over the full
#                             pre-LOT1 window; see build_ndmm_therapy_pre_lot1
#                             for why we cannot reuse MMA_MED_PROCESSED).
#
#   NO_OTHER_CANCER_PRE_LOT1: zero PATID rows in NDMM_OTHER_MALIG_PATIDS
#                             (NDMM spec: "Evidence of another active
#                             cancer ... during the 1L baseline period";
#                             re-anchored from parent OTHER_MALIGN_FLAG
#                             which uses 6-mo pre-MM-dx. IP/OP same-tumor-
#                             group logic mirrors parent step 22.)
#
#   CE_lot1_3mo_fu          : 3-month follow-up CE re-derived ANCHORED AT
#                             LOT1 (the NDMM index): a span covers
#                             [LOT1_START, least(LOT1_START + 90, study_end,
#                             death)]. No-gap spans (NDMM_ENROLL_SPANS_STRICT)
#                             per spec + carried-forward DEATH_DT (NDMM spec:
#                             >=3-mo CE during follow-up or death, NO gaps).
#
#   NO_PREGNANCY            : re-scanned from pregnancy.csv (dx / HCPCS / ICD
#                             procedure / revenue codes) over the study period,
#                             restricted to NDMM LOT1 candidates - NOT the
#                             parent PREGNANT_FLAG. NDMM spec exclusion.
# Readability probe used by the pregnancy gate (the scan view may not exist
# if its source claims tables are unavailable).
.ndmm_table_ok <- function(con, tbl) isTRUE(tryCatch(
  nrow(db_q(con, glue("SELECT 1 FROM {tbl} LIMIT 1"))) >= 0,
  error = function(e) FALSE))

# Pregnancy exclusion (NDMM spec E3): re-scanned directly from pregnancy.csv
# over the study period, NOT carried from the parent PREGNANT_FLAG - so it is
# self-contained and uses the NDMM pregnancy codelist + the spec's any-time-
# in-study-period window.
build_ndmm_preg_codes <- function(con) {
  src <- load_codelist_csv("pregnancy.csv", c("code_type", "code"))
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_PREG_CODES} AS
    SELECT upper(trim(code_type)) AS code_type,
           upper(regexp_replace(trim(code), '[^A-Za-z0-9]', '')) AS code
    FROM {src}
    WHERE code IS NOT NULL AND trim(code) <> ''
      AND code_type IS NOT NULL AND trim(code_type) <> ''
  "))
}

# Distinct NDMM-candidate PATIDs with a pregnancy/childbirth claim (dx,
# HCPCS / ICD procedure, or revenue code) anywhere in the study period.
# Restricted to NDMM LOT1 candidates up front in each source (and again by
# the trailing INNER JOIN) so the UNION / de-dupe / codelist-join work runs
# on cohort claims only. This is logical row pruning - Spark may still
# physically scan source partitions before the join, depending on layout/
# stats - not a guaranteed I/O reduction.
build_ndmm_pregnancy_patids <- function(con, med_diag_tbl, medical_tbl, med_proc_tbl) {
  # Two scheduling-only optimisations (the matched PATID set is identical):
  #   1) Restrict every source to NDMM LOT1 candidates UP FRONT (INNER JOIN
  #      NDMM_LOT1_STARTS) instead of only at the very end. The output is
  #      DISTINCT PATID intersected with NDMM_LOT1_STARTS either way, so the
  #      early join only prunes claims that the trailing join would drop
  #      anyway. The trailing join is kept as a belt-and-braces no-op so the
  #      result stays cohort-restricted even if a future source arm forgets
  #      the push-down.
  #   2) Scan the large `medical` table ONCE: stack() emits its HCPCS
  #      (PROC_CD) and REV (RVNU_CD) rows in a single pass instead of two
  #      separate scans. The per-arm CASE reproduces the original inclusion
  #      rules exactly - HCPCS keeps a blank-after-clean code (only PROC_CD
  #      IS NOT NULL was required), REV drops blanks (trim(RVNU_CD) <> '') -
  #      and a blank code never matches a real pregnancy code, so the matched
  #      PATIDs are unchanged.
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_PREGNANCY_PATIDS} AS
    WITH dx AS (
      SELECT cast(d.PATID as string) AS PATID,
             CASE WHEN upper(d.ICD_FLAG) IN ('9','ICD9','ICD-9') THEN 'ICD9DIAG' ELSE 'ICD10DIAG' END AS code_type,
             upper(regexp_replace(d.DIAG, '[^A-Za-z0-9]', '')) AS code
      FROM {med_diag_tbl} d
      INNER JOIN {NDMM_LOT1_STARTS} l1 ON cast(d.PATID as string) = l1.PATID
      WHERE d.DIAG IS NOT NULL
        AND cast(d.FST_DT as date) BETWEEN date('{NDMM_STUDY_START}') AND date('{cfg$study_end}')
    ),
    med AS (
      SELECT s.PATID, t.code_type, t.code
      FROM (
        SELECT cast(m.PATID as string) AS PATID, m.PROC_CD, m.RVNU_CD
        FROM {medical_tbl} m
        INNER JOIN {NDMM_LOT1_STARTS} l1 ON cast(m.PATID as string) = l1.PATID
        WHERE cast(m.FST_DT as date) BETWEEN date('{NDMM_STUDY_START}') AND date('{cfg$study_end}')
      ) s
      LATERAL VIEW stack(2,
        'HCPCS', CASE WHEN s.PROC_CD IS NOT NULL
                      THEN upper(regexp_replace(s.PROC_CD, '[^A-Za-z0-9]', '')) END,
        'REV',   CASE WHEN s.RVNU_CD IS NOT NULL AND trim(s.RVNU_CD) <> ''
                      THEN upper(trim(s.RVNU_CD)) END
      ) t AS code_type, code
      WHERE t.code IS NOT NULL
    ),
    icd_proc AS (
      SELECT cast(p.PATID as string) AS PATID,
             CASE WHEN upper(p.ICD_FLAG) IN ('9','ICD9','ICD-9') THEN 'ICD9PROC' ELSE 'ICD10PROC' END AS code_type,
             upper(regexp_replace(p.PROC, '[^A-Za-z0-9]', '')) AS code
      FROM {med_proc_tbl} p
      INNER JOIN {NDMM_LOT1_STARTS} l1 ON cast(p.PATID as string) = l1.PATID
      WHERE p.PROC IS NOT NULL
        AND cast(p.FST_DT as date) BETWEEN date('{NDMM_STUDY_START}') AND date('{cfg$study_end}')
    ),
    events AS (
      SELECT * FROM dx
      UNION ALL SELECT * FROM med
      UNION ALL SELECT * FROM icd_proc
    ),
    matched AS (
      SELECT DISTINCT e.PATID
      FROM events e
      INNER JOIN {NDMM_PREG_CODES} p
              ON e.code_type = p.code_type AND e.code = p.code
    )
    SELECT DISTINCT m.PATID
    FROM matched m
    INNER JOIN {NDMM_LOT1_STARTS} l1 ON m.PATID = l1.PATID
  "))
}

build_ndmm_flags <- function(con, elig_coh_final, map_stacked,
                           q2_ok_belantamab, q2_ok_priortx,
                           q2_ok_othercancer, q2_ok_pregnancy = NULL) {
  if (is.null(q2_ok_pregnancy))
    q2_ok_pregnancy <- .ndmm_table_ok(con, NDMM_PREGNANCY_PATIDS)
  bela_expr <- if (q2_ok_belantamab) glue("
        SELECT DISTINCT cast(PATID as string) AS PATID
        FROM {map_stacked}
        WHERE upper(MAP_MED_TYPE) LIKE 'BEL%'
  ") else "SELECT cast(NULL as string) AS PATID WHERE 1 = 0"

  prior_tx_expr <- if (q2_ok_priortx) glue("
        SELECT DISTINCT PATID FROM {NDMM_THERAPY_PRE_LOT1}
  ") else "SELECT cast(NULL as string) AS PATID WHERE 1 = 0"

  other_cancer_expr <- if (q2_ok_othercancer) glue("
        SELECT DISTINCT cast(PATID as string) AS PATID FROM {NDMM_OTHER_MALIG_PATIDS}
  ") else "SELECT cast(NULL as string) AS PATID WHERE 1 = 0"

  pregnancy_expr <- if (q2_ok_pregnancy) glue("
        SELECT DISTINCT cast(PATID as string) AS PATID FROM {NDMM_PREGNANCY_PATIDS}
  ") else "SELECT cast(NULL as string) AS PATID WHERE 1 = 0"

  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_FLAGS_ALL} AS
    WITH ec_l1 AS (
      SELECT cast(ec.PATID as string) AS PATID, l1.LOT1_START_DT,
             date_sub(l1.LOT1_START_DT, {NDMM_PRE_LOT1_DAYS}) AS pre_lot1_start,
             date_sub(l1.LOT1_START_DT, 1)                  AS pre_lot1_end,
             -- DEATH_DT is carried forward from the parent ELIG_COH_FINAL so
             -- the 3-month follow-up CE below can be re-derived ANCHORED AT
             -- LOT1 (the NDMM index); the parent CE_3mosf is anchored at the
             -- MM-dx index and so is NOT reused for it. Pregnancy is NOT carried
             -- from the parent flag - it is re-scanned from pregnancy.csv over
             -- the study period (NDMM_PREGNANCY_PATIDS).
             cast(ec.DEATH_DT as date)     AS DEATH_DT
      FROM {elig_coh_final} ec
      INNER JOIN {NDMM_LOT1_STARTS} l1
              ON cast(ec.PATID as string) = l1.PATID
    ),
    ce AS (
      SELECT ec_l1.PATID,
             max(CASE WHEN s.cov_start <= ec_l1.pre_lot1_start
                       AND s.cov_end   >= ec_l1.pre_lot1_end
                      THEN 1 ELSE 0 END) AS CE_pre_lot1_12mo
      FROM ec_l1
      LEFT JOIN {NDMM_ENROLL_SPANS} s ON s.PATID = ec_l1.PATID
      GROUP BY ec_l1.PATID
    ),
    -- 3-month follow-up CE re-derived ANCHORED AT LOT1 (the NDMM index): a
    -- span must cover [LOT1_START, least(LOT1_START + 90, study_end, death)].
    -- Uses NDMM_ENROLL_SPANS_STRICT (no-gap spans, gap_days=0) per the spec:
    -- 'no gaps in enrollment' for the follow-up CE, vs <30-day gaps allowed
    -- for the 12-mo pre-LOT1 CE. Plus the carried-forward DEATH_DT.
    fuce AS (
      SELECT ec_l1.PATID,
             max(CASE WHEN s.cov_start <= ec_l1.LOT1_START_DT
                       AND s.cov_end   >= least(date_add(ec_l1.LOT1_START_DT, 90),
                                                date('{cfg$study_end}'),
                                                coalesce(ec_l1.DEATH_DT, date('{cfg$study_end}')))
                      THEN 1 ELSE 0 END) AS CE_lot1_3mo
      FROM ec_l1
      LEFT JOIN {NDMM_ENROLL_SPANS_STRICT} s ON s.PATID = ec_l1.PATID
      GROUP BY ec_l1.PATID
    ),
    bela AS ({bela_expr}),
    prior_tx AS ({prior_tx_expr}),
    other_cancer AS ({other_cancer_expr}),
    pregnancy AS ({pregnancy_expr})
    SELECT ec_l1.PATID,
           ce.CE_pre_lot1_12mo,
           coalesce(fuce.CE_lot1_3mo, 0)                        AS CE_lot1_3mo_fu,
           CASE WHEN bela.PATID         IS NULL THEN 1 ELSE 0 END AS NO_BELANTAMAB,
           CASE WHEN prior_tx.PATID     IS NULL THEN 1 ELSE 0 END AS NO_PRIOR_MM_TX,
           CASE WHEN other_cancer.PATID IS NULL THEN 1 ELSE 0 END AS NO_OTHER_CANCER_PRE_LOT1,
           CASE WHEN pregnancy.PATID    IS NULL THEN 1 ELSE 0 END AS NO_PREGNANCY
    FROM ec_l1
    LEFT JOIN ce           ON ec_l1.PATID = ce.PATID
    LEFT JOIN fuce         ON ec_l1.PATID = fuce.PATID
    LEFT JOIN bela         ON ec_l1.PATID = bela.PATID
    LEFT JOIN prior_tx     ON ec_l1.PATID = prior_tx.PATID
    LEFT JOIN other_cancer ON ec_l1.PATID = other_cancer.PATID
    LEFT JOIN pregnancy    ON ec_l1.PATID = pregnancy.PATID
  "))

  # Materialize NDMM_FLAGS_ALL once, then repoint the view at the physical
  # work-schema table. As a bare TEMPORARY VIEW this re-runs the whole scan
  # DAG (pregnancy + belantamab + prior-Tx + other-cancer over the study
  # period, plus both enrollment-span builds) on EVERY read - and it is read
  # heavily: ndmm_counts() alone issues six COUNT(DISTINCT) queries against
  # it (one per funnel step), then NDMM_PATIDS, the dashboard sections and the
  # validation drilldown read it again. Recomputing the scans six-plus times
  # back-to-back is what makes the NDMM stage appear to hang right after the
  # Overall attrition figure. Materializing collapses that to one computation;
  # every later read (including NDMM_PATIDS below) hits the table. Mirrors the
  # parent's S16 materialize-and-repoint (02_lot1.R); CACHE TABLE is not
  # available on SQL warehouses. The write is unconditional (not gated on
  # cfg$persist_to_schema, which governs the FINAL persist to the personal
  # schema, not intermediate work-schema materializations - same as the
  # parent's S16).
  #
  # Fail-safe: the parent assumes a writable work schema; this is a dashboard,
  # so if the CREATE TABLE is refused (e.g. a read-only work schema) we WARN
  # and keep the in-place temp view rather than aborting. Downstream numbers
  # are still correct - just recomputed on each read, i.e. slower.
  tryCatch({
    run_step(con, "S_ndmm_materialize_flags_all", glue("
      CREATE OR REPLACE TABLE {wrk(NDMM_FLAGS_ALL_TBL)} AS
      SELECT * FROM {NDMM_FLAGS_ALL}
    "), qc = glue("SELECT count(*) AS n_rows FROM {wrk(NDMM_FLAGS_ALL_TBL)}"))
    db_exec(con, glue("
      CREATE OR REPLACE TEMPORARY VIEW {NDMM_FLAGS_ALL} AS
      SELECT * FROM {wrk(NDMM_FLAGS_ALL_TBL)}
    "))
  }, error = function(e) {
    log_msg("WARN: could not materialize ", wrk(NDMM_FLAGS_ALL_TBL), " (",
            conditionMessage(e), "); keeping the in-place temp view - NDMM ",
            "counts/dashboard stay correct but run slower (flag scans are ",
            "recomputed on each read).")
  })

  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_PATIDS} AS
    SELECT PATID FROM {NDMM_FLAGS_ALL}
    WHERE CE_pre_lot1_12mo        = 1
      AND NO_BELANTAMAB           = 1
      AND NO_PRIOR_MM_TX          = 1
      AND NO_OTHER_CANCER_PRE_LOT1 = 1
      AND CE_lot1_3mo_fu          = 1
      AND NO_PREGNANCY            = 1
  "))
}

# Filtered LOT_LONG view feeding the regimen-transition helpers.
build_lot_long_filtered <- function(con, lot_long) {
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_LOT_LONG_FILT} AS
    SELECT l.*
    FROM {lot_long} l
    INNER JOIN {NDMM_PATIDS} a
            ON cast(l.PATID as string) = a.PATID
  "))

  # Materialize once, then repoint the view at the work-schema table. This
  # filtered LOT_LONG is read ~20x downstream (NDMM augmentation, modal map,
  # KPIs, gallery, validation, run-comparison, and ~13x inside the LOT1-5
  # detail collector); as a bare TEMPORARY VIEW each read re-runs the LOT_LONG
  # join. Materialize-and-repoint (same pattern as NDMM_FLAGS_ALL / LOT_LONG_AUG
  # and the parent S16; CACHE TABLE is unavailable on SQL warehouses) so every
  # downstream read hits the table. Fail-safe: a non-writable work schema
  # WARN-degrades to the in-place view (correct, just slower). No change to
  # which patients/LOT rows are included - identical rows, materialized once.
  tryCatch({
    run_step(con, "S_ndmm_materialize_lot_long_filt", glue("
      CREATE OR REPLACE TABLE {wrk(NDMM_LOT_LONG_FILT_TBL)} AS
      SELECT * FROM {NDMM_LOT_LONG_FILT}
    "), qc = glue("SELECT count(*) AS n_rows FROM {wrk(NDMM_LOT_LONG_FILT_TBL)}"))
    db_exec(con, glue("
      CREATE OR REPLACE TEMPORARY VIEW {NDMM_LOT_LONG_FILT} AS
      SELECT * FROM {wrk(NDMM_LOT_LONG_FILT_TBL)}
    "))
  }, error = function(e) {
    log_msg("WARN: could not materialize ", wrk(NDMM_LOT_LONG_FILT_TBL), " (",
            conditionMessage(e), "); keeping the in-place temp view - NDMM ",
            "LOT-detail views stay correct but run slower (the join is ",
            "recomputed on each read).")
  })
}

# Counts at each filter step for the attrition card. Steps after
# ELIG_COH_FINAL + LOT1 are CUMULATIVE - each row applies all previous
# NDMM filters plus the new one, so the table reads top-to-bottom as
# the funnel a clinical reviewer would expect.
ndmm_counts <- function(con, lot_long, elig_coh_final) {
  whole <- db_q(con, glue(
    "SELECT count(DISTINCT PATID) AS n FROM {lot_long}"))$n
  # ELIG_COH_FINAL intersected with LOT_LONG so the funnel is monotonic
  # (the parent cohort can contain PATIDs that never enter LOT_LONG; the
  # bare ELIG_COH_FINAL count could otherwise exceed the row above).
  elig <- db_q(con, glue(
    "SELECT count(DISTINCT ec.PATID) AS n
     FROM {elig_coh_final} ec
     INNER JOIN (SELECT DISTINCT cast(PATID as string) AS PATID FROM {lot_long}) ll
             ON cast(ec.PATID as string) = ll.PATID"))$n
  elig_lot1 <- db_q(con, glue(
    "SELECT count(DISTINCT ec.PATID) AS n
     FROM {elig_coh_final} ec
     INNER JOIN {NDMM_LOT1_STARTS} l1
             ON cast(ec.PATID as string) = l1.PATID"))$n
  ce12 <- db_q(con, glue(
    "SELECT count(DISTINCT PATID) AS n FROM {NDMM_FLAGS_ALL}
     WHERE CE_pre_lot1_12mo = 1"))$n
  ce12_nobela <- db_q(con, glue(
    "SELECT count(DISTINCT PATID) AS n FROM {NDMM_FLAGS_ALL}
     WHERE CE_pre_lot1_12mo = 1 AND NO_BELANTAMAB = 1"))$n
  ce12_nobela_nopriortx <- db_q(con, glue(
    "SELECT count(DISTINCT PATID) AS n FROM {NDMM_FLAGS_ALL}
     WHERE CE_pre_lot1_12mo = 1
       AND NO_BELANTAMAB    = 1
       AND NO_PRIOR_MM_TX   = 1"))$n
  noother <- db_q(con, glue(
    "SELECT count(DISTINCT PATID) AS n FROM {NDMM_FLAGS_ALL}
     WHERE CE_pre_lot1_12mo = 1 AND NO_BELANTAMAB = 1
       AND NO_PRIOR_MM_TX = 1 AND NO_OTHER_CANCER_PRE_LOT1 = 1"))$n
  noother_fuce <- db_q(con, glue(
    "SELECT count(DISTINCT PATID) AS n FROM {NDMM_FLAGS_ALL}
     WHERE CE_pre_lot1_12mo = 1 AND NO_BELANTAMAB = 1
       AND NO_PRIOR_MM_TX = 1 AND NO_OTHER_CANCER_PRE_LOT1 = 1
       AND CE_lot1_3mo_fu = 1"))$n
  ndmm_final <- db_q(con, glue(
    "SELECT count(DISTINCT PATID) AS n FROM {NDMM_PATIDS}"))$n
  list(whole = whole, elig = elig, elig_lot1 = elig_lot1,
       ce12 = ce12, ce12_nobela = ce12_nobela,
       ce12_nobela_nopriortx = ce12_nobela_nopriortx,
       noother = noother, noother_fuce = noother_fuce,
       ndmm_final = ndmm_final)
}

build_ndmm_overview_card <- function(counts, n_ster_codes, n_cat_rules,
                                   notes = list(), section = "OVERVIEW",
                                   title = "What this dashboard shows") {
  pct <- function(num, den)
    if (den > 0) sprintf("%.1f%%", 100 * num / den) else "-"
  row <- function(label, n, bold = FALSE, bg = "") {
    open  <- if (bold) "<b>" else ""
    close <- if (bold) "</b>" else ""
    bgsty <- if (nzchar(bg)) paste0(' style="background:', bg, '"') else ""
    paste0('<tr', bgsty, '><td style="padding:6px 12px">', open, label, close, '</td>',
           '<td style="text-align:right;padding:6px 12px">', open,
             format(n, big.mark = ","), close, '</td>',
           '<td style="text-align:right;padding:6px 12px">', open,
             pct(n, counts$whole), close, '</td></tr>')
  }
  notes_html <- if (length(notes))
    paste0('<p style="color:#a06000;font-size:12px;margin-top:8px"><b>Notes:</b> ',
           paste(notes, collapse = " "), '</p>') else ""
  add_html_card(paste0(
    ndc_missing_banner(),
    '<div style="font-family:system-ui;padding:14px;max-width:900px">',
    '<h3>NDMM (1L newly-diagnosed) planned cohort</h3>',
    '<p style="color:#555;font-size:13px">Regimen-transition + steroid dashboards on ',
    'The planned cohort: parent <code>ELIG_COH_FINAL</code> ',
    '(for this project the parent runs through Step 6 - its other-malignancy, ',
    'baseline-MM-dx, pregnancy and clinical-trial exclusions are OFF and are ',
    're-applied where the spec requires by the NDMM layer below, the ',
    'other-cancer one with the MM-adjacent override) plus a NDMM-side LOT1 eligibility ',
    'cutoff (<code>LOT_START_DT &ge; ', NDMM_LOT1_FROM, '</code>) and ',
    'six NDMM-only post-filters aligned to the spec: <b>12-mo CE before ',
    'LOT1</b>, <b>3-mo follow-up CE</b> (re-derived from the LOT1 index, ',
    'no-gap per spec, death-aware), <b>no belantamab in any LOT</b>, ',
    '<b>no MM oncology therapy in the 12-mo 1L baseline</b>, <b>no other ',
    'active cancer in the 12-mo 1L baseline</b>, and <b>no pregnancy</b> ',
    '(re-scanned from <code>pregnancy.csv</code> over the study period). CE-pre-LOT1 uses the parent&apos;s <code>gap_days = ',
    NDMM_GAP_DAYS, '</code> allowance. Belantamab detection scans ',
    '<code>MAP_STACKED</code> for <code>MAP_MED_TYPE LIKE &apos;BEL%&apos;</code> ',
    '- narrower than the <code>lot1_studyteam_qs.R</code> inventory ',
    'predicate (no <code>%BCMA%</code> class match) so bispecifics and ',
    'CAR-T are not over-excluded. MM-therapy pre-LOT1 scans raw ',
    '<code>medical</code> (PROC_CD / BILL_PROC_CD / NDC) and <code>rx</code> ',
    '(NDC) joined to the MMA codelist for the full ',
    '<code>[LOT1_START - 365, LOT1_START - 1]</code> window per patient ',
    '- not <code>MMA_MED_PROCESSED</code>, which the parent bounds at ',
    '<code>FST_DT &gt;= INDEX_DATE</code> and so cannot see pre-MM-dx ',
    'claims. Steroid <code>MED_ABBR</code> values (DEX/DEXA/PRED/...) ',
    'are dropped from the codelist before the scan since the spec wording ',
    'targets MM oncology therapy, not supportive care. Other-cancer ',
    'pre-LOT1 mirrors parent step 22 (<code>OTHER_MALIGN_FLAG</code>) ',
    '1-IP-or-2-OP-within-30d-same-tumor-group logic, re-anchored to the ',
    'LOT1 window using <code>cl_other_malignancies</code> (default ',
    '<code>other_malig.csv</code>) and a NDMM-rebuilt 5-column ',
    '<code>med_claim_header</code> / <code>confinement</code> for IP/OP ',
    'classification.</p>',
    '<table style="font-size:13px;border-collapse:collapse;margin-top:8px">',
    '<tr style="background:#eef"><th style="text-align:left;padding:6px 12px">Filter step</th>',
    '<th style="text-align:right;padding:6px 12px">n patients</th>',
    '<th style="text-align:right;padding:6px 12px">% of whole</th></tr>',
    row("Whole LOT_LONG cohort",                                       counts$whole),
    row("+ in ELIG_COH_FINAL (parent IE)",                             counts$elig),
    row(paste0("+ has LOT1 start &ge; ", NDMM_LOT1_FROM, " in LOT_LONG"), counts$elig_lot1),
    row("+ 12-mo CE pre-LOT1",                                         counts$ce12),
    row("+ no belantamab in any LOT",                                  counts$ce12_nobela),
    row("+ no MM oncology Tx in 12-mo pre-LOT1",                       counts$ce12_nobela_nopriortx),
    row("+ no other active cancer in 12-mo pre-LOT1",                  counts$noother),
    row("+ 3-mo follow-up CE (from LOT1)",                            counts$noother_fuce),
    row("+ no pregnancy (NDMM final)",
        counts$ndmm_final, bold = TRUE, bg = "#efe"),
    '</table>',
    notes_html,
    '<ul style="font-size:13px;color:#1a7a3a;margin-top:10px">',
    '<li><b>Category transitions</b>: regimen-category Sankeys per LOT pair (',
    n_cat_rules, ' regimen rules loaded).</li>',
    '<li><b>Steroid prevalence</b>: steroid tokens appended to <code>LOT_BASE_MEDS</code> ',
    'inside the parent induction window (', n_ster_codes, ' codes loaded; ',
    '<code>SCT_ALLO</code>-started LOTs suppressed).</li>',
    '<li><b>Progressor flows</b>: non-progressors dropped (inner-join LOTn &rarr; LOTn+1).</li>',
    '</ul></div>'),
    section = section, title = title)
}

# Cohort-attrition card for the NDMM cohort. Mirrors
# build_overall_attrition() shape (table + waterfall) so both cohorts
# read the same way in the combined dashboard. Driven by the `counts`
# struct that ndmm_counts() already computes during prepare_ndmm_cohort()
# - no extra SQL needed. The inline 7-row table inside the NDMM overview
# card stays as a quick-glance summary; this card is the detail view.
build_ndmm_attrition <- function(counts, section = "OVERVIEW",
                                 title_prefix = "") {
  df <- data.frame(
    step = c("01_whole", "02_elig", "03_lot1", "04_ce12",
             "05_nobela", "06_nopriortx", "07_noother", "08_fuce",
             "09_nopreg_final"),
    description = c(
      "Whole LOT_LONG cohort",
      "+ in ELIG_COH_FINAL (parent IE)",
      paste0("+ LOT1 start >= ", NDMM_LOT1_FROM, " in LOT_LONG"),
      "+ 12-mo CE pre-LOT1",
      "+ no belantamab in any LOT",
      "+ no MM oncology Tx in 12-mo pre-LOT1",
      "+ no other active cancer in 12-mo pre-LOT1",
      "+ 3-mo follow-up CE (from LOT1)",
      "+ no pregnancy (NDMM final)"),
    n_patients = as.integer(c(
      counts$whole, counts$elig, counts$elig_lot1, counts$ce12,
      counts$ce12_nobela, counts$ce12_nobela_nopriortx, counts$noother,
      counts$noother_fuce, counts$ndmm_final)),
    stringsAsFactors = FALSE
  )
  df$pct_of_prev <- NA_real_
  if (nrow(df) > 1) {
    for (i in 2:nrow(df)) {
      prev_n <- df$n_patients[i - 1]
      df$pct_of_prev[i] <- if (prev_n > 0)
        round(100 * df$n_patients[i] / prev_n, 2) else NA_real_
    }
  }
  save_table(df, section = section,
             title = paste0(title_prefix, "NDMM cohort attrition"))

  if (has_ggplot2) {
    plot_df <- df
    plot_df$description <- factor(plot_df$description,
                                  levels = rev(plot_df$description))
    p_att <- ggplot(plot_df,
                    aes(x = description, y = n_patients,
                        text = paste0("Step: ", description,
                                      "\nN: ", format(n_patients, big.mark = ",")))) +
      geom_col(fill = "#2E86AB", width = 0.7) +
      geom_text(aes(label = format(n_patients, big.mark = ",")),
                hjust = -0.1, size = 3.3, color = "grey20") +
      scale_y_continuous(labels = scales::comma_format(),
                         expand = expansion(mult = c(0, 0.2))) +
      coord_flip() +
      labs(title = "NDMM cohort attrition",
           subtitle = paste0("LOT1 cutoff ", NDMM_LOT1_FROM,
                             " + six NDMM IE filters applied to LOT_LONG"),
           x = NULL, y = "Patients remaining") +
      theme_lot()
    save_plot(p_att, "ndmm_attrition.png", width = 10, height = 6,
              section = section,
              title = paste0(title_prefix, "NDMM attrition waterfall"))
  }
}

# QC card: break the other-cancer hits down by tumor_group so reviewers
# can see WHICH families drive the drop, AND audit the NDMM MM-adjacent
# override. Runs the same dx / IP / OP-pair / pre-LOT1-window logic as
# build_ndmm_other_malig_pre_lot1() but WITHOUT the is_mm_adjacent_override
# predicate, so overridden groups stay visible. Emits three artifacts:
#
#   1. Override-impact summary card - partitions the pre-override drop
#      into re-included (only MM-adjacent hits) vs still-excluded
#      (genuine other cancer, with or without an MM-adjacent hit). This
#      is the C79.5/bone audit: bone-group patients who also carry a
#      genuine other-cancer code stay excluded.
#   2. Per-group table - one row per tumor_group with is_override flag,
#      n_patients_hit, n_exclusive_hit, IP/OP split, % of pre-override.
#   3. Bar chart - top 15 groups coloured by override status.
#
# Reads only the temp views prepare_ndmm_cohort() already built. No new
# persisted artifacts, no change to the filter logic (the override flag
# is applied in build_ndmm_other_malig_codes / build_ndmm_other_malig_pre_-
# lot1, not here). Each PATID is counted once per tumor_group, so column
# sums can exceed the distinct-PATID drop (a patient can hit >1 group).
build_ndmm_other_cancer_qc <- function(con, section = "OVERVIEW",
                                       title_prefix = "") {
  view_ok <- isTRUE(tryCatch(
    nrow(db_q(con, glue(
      "SELECT 1 FROM {NDMM_OTHER_MALIG_PATIDS} LIMIT 1"))) >= 0,
    error = function(e) FALSE))
  if (!view_ok) {
    add_html_card(paste0(
      '<div style="font-family:system-ui;padding:14px;max-width:900px;',
      'background:#fff3cd;border:1px solid #d9a800;border-radius:6px;',
      'color:#5a4500"><b>Other-cancer QC unavailable.</b><br>',
      'The no-other-cancer filter was skipped this run (one of ',
      '<code>med_diag</code> / <code>medical</code> / ',
      '<code>confinement</code> was not readable), so there is no ',
      'hit-set to break down.</div>'),
      section = section,
      title = paste0(title_prefix, "Other-cancer drop QC (unavailable)"))
    return(invisible())
  }

  med_diag_tbl <- cdm_src(cfg$tbl_med_diag)
  lower <- glue("date_sub(date('{NDMM_LOT1_FROM}'), {NDMM_PRE_LOT1_DAYS})")
  upper <- glue("date('{cfg$study_end}')")
  # Same override list the filter uses, re-derived here so the QC can
  # label each group and quantify the override's re-inclusion impact.
  # The QC scans ALL codelist rows (no is_mm_adjacent_override predicate)
  # so overridden groups remain visible in the breakdown.
  ovr_in <- paste(sprintf("'%s'", gsub("'", "''", NDMM_MM_ADJACENT_OVERRIDE)),
                  collapse = ", ")

  cte <- glue("
    WITH dx AS (
      SELECT d.PATID, d.PAT_PLANID, d.CLMID, d.FST_DT, d.LOC_CD,
             cast(d.FST_DT as date) AS event_dt,
             upper(regexp_replace(d.DIAG, '[^A-Za-z0-9]', '')) AS dx,
             CASE WHEN upper(d.ICD_FLAG) IN ('9','ICD9','ICD-9') THEN 'ICD9' ELSE 'ICD10' END AS icd_family
      FROM {med_diag_tbl} d
      WHERE FST_DT BETWEEN {lower} AND {upper}
    ),
    dx_mapped AS (
      SELECT /*+ BROADCAST(o) */
             dx.PATID, dx.PAT_PLANID, dx.CLMID, dx.FST_DT, dx.LOC_CD,
             dx.event_dt, o.tumor_group
      FROM dx
      INNER JOIN {NDMM_OTHER_MALIG_CODES} o
              ON dx.dx = o.dx AND dx.icd_family = o.icd_family
    ),
    dx_with_setting AS (
      SELECT dm.PATID, dm.CLMID, dm.event_dt, dm.tumor_group,
             CASE WHEN h.POS IN ('21', '51', '61')
                    OR h.TOS_CD IN ('FAC_IP.ACUTE', 'FAC_IP.REHSNF', 'PROF.INPVIS', 'FAC_IP.SNF')
                    OR cf.CONF_ID IS NOT NULL
                  THEN 1 ELSE 0 END AS inpatient_flg
      FROM dx_mapped dm
      INNER JOIN {NDMM_MED_CLAIM_HEADER} h
            ON dm.PATID      =   h.PATID
           AND dm.CLMID      =   h.CLMID
           AND dm.FST_DT     =   h.FST_DT
           AND dm.PAT_PLANID <=> h.PAT_PLANID
           AND dm.LOC_CD     <=> h.LOC_CD
      LEFT JOIN {NDMM_CONFINEMENT} cf
        ON h.PATID = cf.PATID AND h.CONF_ID = cf.CONF_ID
    ),
    ip_hits AS (
      SELECT DISTINCT PATID, tumor_group, event_dt
      FROM dx_with_setting WHERE inpatient_flg = 1
    ),
    op_dates AS (
      SELECT DISTINCT PATID, tumor_group, event_dt
      FROM dx_with_setting WHERE inpatient_flg = 0
    ),
    op_pairs AS (
      SELECT PATID, tumor_group, event_dt AS first_dt,
             lead(event_dt) OVER (PARTITION BY PATID, tumor_group ORDER BY event_dt) AS next_dt
      FROM op_dates
    ),
    l1 AS (
      SELECT cast(PATID as string) AS PATID, LOT1_START_DT,
             date_sub(LOT1_START_DT, {NDMM_PRE_LOT1_DAYS}) AS pre_lot1_start,
             date_sub(LOT1_START_DT, 1)                  AS pre_lot1_end
      FROM {NDMM_LOT1_STARTS}
    ),
    ip_in_window AS (
      SELECT DISTINCT cast(ip.PATID as string) AS PATID, ip.tumor_group
      FROM ip_hits ip
      JOIN l1 ON cast(ip.PATID as string) = l1.PATID
      WHERE ip.event_dt BETWEEN l1.pre_lot1_start AND l1.pre_lot1_end
    ),
    op_in_window AS (
      SELECT DISTINCT cast(op.PATID as string) AS PATID, op.tumor_group
      FROM op_pairs op
      JOIN l1 ON cast(op.PATID as string) = l1.PATID
      WHERE op.next_dt IS NOT NULL
        AND datediff(op.next_dt, op.first_dt) <= 30
        AND op.first_dt BETWEEN l1.pre_lot1_start AND l1.pre_lot1_end
    ),
    by_group AS (
      SELECT PATID, tumor_group,
             max(via_ip) AS via_ip, max(via_op) AS via_op
      FROM (
        SELECT PATID, tumor_group, 1 AS via_ip, 0 AS via_op FROM ip_in_window
        UNION ALL
        SELECT PATID, tumor_group, 0 AS via_ip, 1 AS via_op FROM op_in_window
      )
      GROUP BY PATID, tumor_group
    ),
    -- How many distinct tumor_groups did each PATID get flagged by?
    -- Drives the n_exclusive_hit column: PATIDs with n_groups = 1 are
    -- the ones who would actually become eligible if their single
    -- flagging group were removed from the codelist. PATIDs with
    -- n_groups > 1 are caught by multiple groups, so dropping any
    -- single group leaves them excluded - the n_patients_hit count
    -- overstates single-group-removal impact for those.
    patid_group_count AS (
      SELECT PATID, count(DISTINCT tumor_group) AS n_groups
      FROM by_group
      GROUP BY PATID
    ),
    -- Per-PATID override mix: did this patient get flagged by any
    -- override (MM-adjacent) group, any genuine other-cancer group, or
    -- both? Drives the override-impact summary below. has_override +
    -- has_genuine = 0 is impossible (every by_group row is one or the
    -- other), so the three classes partition the pre-override drop.
    patid_override_mix AS (
      SELECT PATID,
             max(CASE WHEN upper(trim(tumor_group)) IN ({ovr_in}) THEN 1 ELSE 0 END) AS has_override,
             max(CASE WHEN upper(trim(tumor_group)) IN ({ovr_in}) THEN 0 ELSE 1 END) AS has_genuine
      FROM by_group
      GROUP BY PATID
    )
  ")

  # Per-group breakdown (all groups, including overridden ones, so the
  # override's effect stays visible). is_override flags the now-non-
  # exclusionary groups.
  qc <- tryCatch(db_q(con, paste0(cte, glue("
    SELECT bg.tumor_group,
           CASE WHEN upper(trim(bg.tumor_group)) IN ({ovr_in}) THEN 1 ELSE 0 END AS is_override,
           count(DISTINCT bg.PATID)                                              AS n_patients_hit,
           count(DISTINCT CASE WHEN pgc.n_groups = 1 THEN bg.PATID END)          AS n_exclusive_hit,
           count(DISTINCT CASE WHEN bg.via_ip = 1 THEN bg.PATID END)             AS n_via_ip,
           count(DISTINCT CASE WHEN bg.via_op = 1 THEN bg.PATID END)             AS n_via_op
    FROM by_group bg
    INNER JOIN patid_group_count pgc ON pgc.PATID = bg.PATID
    GROUP BY bg.tumor_group
    ORDER BY n_patients_hit DESC
  "))), error = function(e) {
    log_msg("  WARN: other-cancer QC query failed: ", conditionMessage(e))
    NULL
  })

  # Override-impact summary: how the pre-override drop population splits
  # into re-included vs still-excluded. n_override_only_reincluded is
  # the actual headcount the NDMM scope override adds back to NDMM.
  impact <- tryCatch(db_q(con, paste0(cte, "
    SELECT
      count(DISTINCT PATID)                                                     AS n_preoverride_drop,
      count(DISTINCT CASE WHEN has_override=1 AND has_genuine=0 THEN PATID END)  AS n_override_only_reincluded,
      count(DISTINCT CASE WHEN has_override=1 AND has_genuine=1 THEN PATID END)  AS n_override_plus_genuine,
      count(DISTINCT CASE WHEN has_override=0 AND has_genuine=1 THEN PATID END)  AS n_genuine_only
    FROM patid_override_mix
  ")), error = function(e) NULL)

  if (is.null(qc) || nrow(qc) == 0) {
    add_html_card(paste0(
      '<div style="font-family:system-ui;padding:14px;max-width:900px">',
      '<b>Other-cancer QC: no hits to summarise.</b></div>'),
      section = section,
      title = paste0(title_prefix, "Other-cancer drop QC (empty)"))
    return(invisible())
  }

  # ---- Override-impact summary card (the C79.5 / MM-adjacent audit) ----
  # Partitions the pre-override drop into re-included vs still-excluded so
  # the bone-group ambiguity is auditable: patients with a genuine
  # other-cancer signal stay excluded even though their MM-adjacent codes
  # no longer count.
  if (!is.null(impact) && nrow(impact) == 1) {
    fmt   <- function(x) format(as.integer(x), big.mark = ",")
    pre   <- as.integer(impact$n_preoverride_drop)
    reinc <- as.integer(impact$n_override_only_reincluded)
    both  <- as.integer(impact$n_override_plus_genuine)
    gen   <- as.integer(impact$n_genuine_only)
    add_html_card(paste0(
      '<div style="font-family:system-ui;padding:14px;max-width:900px">',
      '<h3 style="margin:0 0 8px">NDMM other-cancer override impact</h3>',
      '<p style="color:#555;font-size:13px;margin:0 0 10px">Effect of treating the ',
      length(NDMM_MM_ADJACENT_OVERRIDE), ' plasma-cell / MM-adjacent tumor groups ',
      'as non-exclusionary for the NDMM other-cancer filter only (NDMM scope). ',
      'Parent pipeline + shared <code>other_malig.csv</code> are unchanged.</p>',
      '<table style="border-collapse:collapse;font-size:13px">',
      '<tr><td style="padding:4px 12px">Pre-override drop (old other-cancer logic)</td>',
      '<td style="text-align:right;padding:4px 12px"><b>', fmt(pre), '</b></td></tr>',
      '<tr style="background:#e8f5e9"><td style="padding:4px 12px">&minus; Re-included by the other-cancer filter (only MM-adjacent hits)</td>',
      '<td style="text-align:right;padding:4px 12px"><b>', fmt(reinc), '</b></td></tr>',
      '<tr><td style="padding:4px 12px">Still excluded: MM-adjacent <i>and</i> genuine other cancer</td>',
      '<td style="text-align:right;padding:4px 12px">', fmt(both), '</td></tr>',
      '<tr><td style="padding:4px 12px">Still excluded: genuine other cancer only</td>',
      '<td style="text-align:right;padding:4px 12px">', fmt(gen), '</td></tr>',
      '<tr style="border-top:2px solid #333"><td style="padding:4px 12px"><b>Current other-cancer drop (post-override)</b></td>',
      '<td style="text-align:right;padding:4px 12px"><b>', fmt(both + gen), '</b></td></tr>',
      '</table>',
      '<p style="color:#777;font-size:12px;margin-top:8px"><b>Note:</b> ',
      '"Re-included" means no longer dropped <i>by the other-cancer filter</i>; ',
      'these patients can still fail the CE / belantamab / prior-MM-Tx filters, ',
      'so the final NDMM count rises by &le; this number (see the attrition card). ',
      'The bone group <code>SECONDARY MALIGNANT NEOPLASM OF BONE</code> can be true ',
      'non-MM metastasis; the "MM-adjacent <i>and</i> genuine" row is exactly those ',
      'patients who keep a genuine other-cancer signal and stay excluded.</p>',
      '</div>'),
      section = section,
      title = paste0(title_prefix, "Other-cancer override impact"))
  }

  # pct denominator = pre-override drop (stable; per-group rows including
  # overridden ones read as % of the original drop population).
  n_total <- if (!is.null(impact) && nrow(impact) == 1)
    as.numeric(impact$n_preoverride_drop) else
    tryCatch(as.numeric(db_q(con, glue(
      "SELECT count(DISTINCT PATID) AS n FROM {NDMM_OTHER_MALIG_PATIDS}"))$n),
      error = function(e) NA_real_)
  qc$pct_of_drop <- if (is.finite(n_total) && n_total > 0)
    round(100 * as.numeric(qc$n_patients_hit) / n_total, 2) else NA_real_

  # Show only genuinely-excluded tumor groups; the 5 MM-adjacent groups
  # retained for NDMM (is_override=1) are not "drops" and are omitted here.
  qc_excl <- qc[as.integer(qc$is_override) == 0, , drop = FALSE]
  out <- data.frame(
    tumor_group        = qc_excl$tumor_group,
    n_patients_hit     = as.integer(qc_excl$n_patients_hit),
    n_exclusive_hit    = as.integer(qc_excl$n_exclusive_hit),
    n_via_ip           = as.integer(qc_excl$n_via_ip),
    n_via_op_pair      = as.integer(qc_excl$n_via_op),
    pct_of_preoverride = qc_excl$pct_of_drop,
    stringsAsFactors   = FALSE
  )
  save_table(out, section = section,
             title = paste0(title_prefix,
                            "Other-cancer drop by tumor_group (excluded only; 5 MM-adjacent retained groups omitted)"))

  if (has_ggplot2 && nrow(qc_excl) > 0) {
    top <- head(qc_excl[order(-as.numeric(qc_excl$n_patients_hit)), ], 15)
    top$tumor_group <- factor(top$tumor_group,
                              levels = rev(top$tumor_group))
    p <- ggplot(top,
                aes(x = tumor_group, y = as.numeric(n_patients_hit),
                    text = paste0("Tumor group: ", tumor_group,
                                  "\nPatients flagged: ",
                                  format(n_patients_hit, big.mark = ",")))) +
      geom_col(width = 0.7, fill = "#C73E1D") +
      geom_text(aes(label = format(as.numeric(n_patients_hit),
                                   big.mark = ",")),
                hjust = -0.1, size = 3.3, color = "grey20") +
      scale_y_continuous(labels = scales::comma_format(),
                         expand = expansion(mult = c(0, 0.2))) +
      coord_flip() +
      labs(title = "NDMM other-cancer filter: tumor groups still excluded",
           subtitle = paste0("Top ", nrow(top), " of ", nrow(qc_excl),
                             " excluded groups; bar = n_patients_hit (overlap ",
                             "counted). The 5 MM-adjacent groups retained for ",
                             "NDMM are not shown."),
           x = NULL, y = "Distinct patients flagged") +
      theme_lot()
    save_plot(p, "ndmm_other_cancer_qc.png", width = 10, height = 6,
              section = section,
              title = paste0(title_prefix,
                             "Other-cancer drop QC chart"))
  }
}

# NDMM cohort setup, shared by main_ndmm() and the
# combined dashboard. Computes the cohort, writes the filtered LOT_LONG
# view, augments it with steroid tokens into LOT_LONG_AUG, and loads
# category lookups. Leaves LOT_LONG_AUG populated for the NDMM cohort
# and returns the scalars the overview card + builders need. Does NOT
# touch dashboard_items.
prepare_ndmm_cohort <- function(con) {
  lot_long        <- wrk("LOT_LONG")
  elig_coh_final  <- wrk(NDMM_FINAL_TABLE_NAME)
  map_stacked     <- wrk("MAP_STACKED")
  rx_tbl          <- cdm_src(cfg$tbl_rx)
  medical_tbl     <- cdm_src(cfg$tbl_medical)
  med_diag_tbl    <- cdm_src(cfg$tbl_med_diag)
  confinement_tbl <- cdm_src(NDMM_TBL_CONFINEMENT)

  ok <- function(t) isTRUE(tryCatch(
    nrow(db_q(con, glue("SELECT 1 FROM {t} LIMIT 1"))) >= 0,
    error = function(e) FALSE))
  if (!ok(lot_long))       stop("Cannot read ", lot_long)
  if (!ok(elig_coh_final)) stop("Cannot read ", elig_coh_final,
                                " - NDMM cohort needs parent ELIG_COH_FINAL.")
  raw_ok <- ok(rx_tbl) && ok(medical_tbl)
  if (!raw_ok) {
    log_msg("  WARN: rx or medical unreadable; steroid augmentation ",
            "AND NDMM MM-Tx pre-LOT1 scan skipped.")
  }
  q2_ok <- raw_ok   # steroid augmentation still needs raw rx/medical
  # NDMM filters that depend on parent / raw inputs. Each filter is gated
  # by readability of its inputs; if any input is unreadable we log
  # loudly, skip the corresponding filter, and surface a note in the
  # OVERVIEW card. NDMM still runs with the filters it can apply rather
  # than aborting - degraded but auditable.
  bela_ok        <- ok(map_stacked)
  priortx_ok     <- raw_ok
  othercancer_ok <- ok(med_diag_tbl) && ok(medical_tbl) && ok(confinement_tbl)
  overview_notes <- character(0)
  if (!bela_ok) {
    log_msg("  WARN: ", map_stacked, " unreadable; belantamab exclusion ",
            "skipped.")
    overview_notes <- c(overview_notes,
      paste0("Belantamab exclusion <b>skipped</b> - <code>",
             map_stacked, "</code> unreadable. Rebuild via ",
             "<code>02_lot1.R</code>."))
  }
  if (!priortx_ok) {
    log_msg("  WARN: rx or medical unreadable; MM-tx pre-LOT1 ",
            "exclusion skipped.")
    overview_notes <- c(overview_notes,
      paste0("MM oncology Tx pre-LOT1 exclusion <b>skipped</b> - raw ",
             "<code>medical</code>/<code>rx</code> unreadable."))
  }
  if (!othercancer_ok) {
    log_msg("  WARN: med_diagnosis, medical, or confinement unreadable; ",
            "other-cancer pre-LOT1 exclusion skipped.")
    overview_notes <- c(overview_notes,
      paste0("Other-cancer pre-LOT1 exclusion <b>skipped</b> - one of ",
             "<code>", cfg$tbl_med_diag, "</code> / <code>",
             cfg$tbl_medical, "</code> / <code>", NDMM_TBL_CONFINEMENT,
             "</code> unreadable."))
  }

  log_msg("Building enrollment spans (gap_days=", NDMM_GAP_DAYS, ")")
  build_enrollment_spans_ndmm(con)
  build_enrollment_spans_ndmm(con, NDMM_ENROLL_SPANS_STRICT, 0L)  # no-gap, for 3-mo FU CE

  log_msg("Pulling LOT1 starts (>= ", NDMM_LOT1_FROM, ") from ", lot_long)
  build_lot1_starts_ndmm(con, lot_long)

  if (priortx_ok) {
    log_msg("Loading MMA codelist (steroid abbrs excluded) -> ", NDMM_MMA_CODELIST)
    db_exec(con, build_ndmm_mma_codelist())
    log_msg("Scanning raw medical + rx for MM Tx in [LOT1-",
            NDMM_PRE_LOT1_DAYS, ", LOT1-1] -> ", NDMM_THERAPY_PRE_LOT1)
    build_ndmm_therapy_pre_lot1(con, medical_tbl, rx_tbl)
  }

  if (othercancer_ok) {
    log_msg("Loading other-malignancy codelist -> ", NDMM_OTHER_MALIG_CODES)
    build_ndmm_other_malig_codes(con)
    log_msg("Building NDMM med_claim_header and confinement views")
    build_ndmm_med_claim_header_and_confinement(con, medical_tbl, confinement_tbl)
    log_msg("Scanning other-malignancy claims in [LOT1-",
            NDMM_PRE_LOT1_DAYS, ", LOT1-1] -> ", NDMM_OTHER_MALIG_PATIDS)
    build_ndmm_other_malig_pre_lot1(con, med_diag_tbl)
  }

  med_proc_tbl <- cdm_src(cfg$tbl_med_proc)
  # Fail-safe: a missing/malformed pregnancy.csv would otherwise hard-stop the
  # whole dashboard (load_codelist_csv stops). Wrap the load + scan so the run
  # degrades to a logged WARN + an overview note, like the other NDMM filters.
  preg_ok <- .ndmm_table_ok(con, med_diag_tbl) && .ndmm_table_ok(con, medical_tbl) &&
             .ndmm_table_ok(con, med_proc_tbl)
  if (preg_ok) {
    preg_ok <- tryCatch({
      log_msg("Loading pregnancy codelist -> ", NDMM_PREG_CODES)
      build_ndmm_preg_codes(con)
      log_msg("Scanning pregnancy claims in [", NDMM_STUDY_START, ", ",
              cfg$study_end, "] -> ", NDMM_PREGNANCY_PATIDS)
      build_ndmm_pregnancy_patids(con, med_diag_tbl, medical_tbl, med_proc_tbl)
      TRUE
    }, error = function(e) {
      log_msg("  WARN: pregnancy exclusion skipped (", conditionMessage(e),
              ") - pregnancy.csv missing/malformed or scan failed.")
      FALSE
    })
  } else {
    log_msg("  WARN: pregnancy exclusion skipped; med_diagnosis, medical, ",
            "or med_procedure unreadable.")
  }
  if (!preg_ok)
    overview_notes <- c(overview_notes,
      paste0("Pregnancy exclusion <b>skipped</b> - <code>pregnancy.csv</code> ",
             "or a source claims table unavailable. <code>NO_PREGNANCY</code> ",
             "passes all patients this run."))

  log_msg("Applying NDMM filters: ELIG_COH_FINAL + 12-mo CE pre-LOT1 + ",
          "3-mo FU CE (LOT1, no-gap) + no belantamab + no MM oncology Tx ",
          "in 12-mo pre-LOT1 + no other-cancer in 12-mo pre-LOT1 + no pregnancy")
  build_ndmm_flags(con, elig_coh_final, map_stacked,
                 q2_ok_belantamab  = bela_ok,
                 q2_ok_priortx     = priortx_ok,
                 q2_ok_othercancer = othercancer_ok,
                 q2_ok_pregnancy   = preg_ok)

  log_msg("Building filtered LOT_LONG -> ", NDMM_LOT_LONG_FILT)
  build_lot_long_filtered(con, lot_long)

  if (q2_ok) {
    log_msg("Loading steroid codes")
    n_ster <- load_steroid_codes(con)
    log_msg("  ", n_ster, " codes loaded")
  } else {
    n_ster <- 0L
  }

  log_msg("Augmenting filtered LOT_LONG with steroid tokens")
  augment_lot_long(con, NDMM_LOT_LONG_FILT, rx_tbl, medical_tbl, n_ster)
  REGIMEN_MODAL_MAP <<- build_modal_map(con, NDMM_LOT_LONG_FILT)

  log_msg("Loading categories")
  lookups <- load_categories()
  n_rules <- length(lookups$lookup_1L) + length(lookups$lookup_2L)
  log_msg("  ", length(lookups$lookup_1L), " 1L rules, ",
          length(lookups$lookup_2L), " 2L+ rules loaded")

  counts <- ndmm_counts(con, lot_long, elig_coh_final)
  log_msg("Cohort sizes - whole: ", counts$whole,
          " | ELIG_COH_FINAL: ", counts$elig,
          " | + LOT1 >= ", NDMM_LOT1_FROM, ": ", counts$elig_lot1,
          " | + 12-mo CE: ", counts$ce12,
          " | + no bela: ", counts$ce12_nobela,
          " | + no MM Tx pre-LOT1: ", counts$ce12_nobela_nopriortx,
          " | + no other-cancer: ", counts$noother,
          " | + 3-mo FU CE: ", counts$noother_fuce,
          " | + no pregnancy (NDMM final): ", counts$ndmm_final)
  if (counts$ndmm_final == 0)
    stop("NDMM cohort is empty - check ELIG_COH_FINAL and LOT_LONG inputs.")

  list(counts = counts, n_ster = n_ster, n_rules = n_rules,
       lookups = lookups, overview_notes = overview_notes)
}

main_ndmm <- function() {
  stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")
  cfg$build_dashboard <<- TRUE

  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn,
                        pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  p <- prepare_ndmm_cohort(con)

  dashboard_items <<- list()
  build_cohort_kpis(con, NDMM_LOT_LONG_FILT, section = "OVERVIEW")
  build_ndmm_overview_card(p$counts, p$n_ster, p$n_rules, p$overview_notes)
  build_ndmm_attrition(p$counts)
  build_ndmm_other_cancer_qc(con)
  build_steroid_prevalence(con)
  build_missing_steroid_lot1(con)
  build_steroid_timing_qc(con, NDMM_LOT_LONG_FILT, section = "STEROIDS")
  build_payer_lot_qc(con, section = "Payer")
  for (n in 1:4) build_focused_pair(con, n, n + 1L)
  for (n in 1:4) build_category_pair(con, n, n + 1L, p$lookups)
  build_category_coverage(con, p$lookups)
  build_patient_gallery(con, NDMM_LOT_LONG_FILT, section = "Patient examples")
  build_validation_views(con, NDMM_LOT_LONG_FILT, section = "Validation",
                         ndmm_flags_tbl = NDMM_FLAGS_ALL)
  build_run_comparison(con, "NDMM", NDMM_LOT_LONG_FILT, section = "Validation")

  counts <- p$counts
  build_dashboard(
    out_name     = "ndmm_dashboard.html",
    header_title = "MM LOT &mdash; NDMM (1L newly-diagnosed) planned cohort",
    header_sub   = paste0("ELIG_COH_FINAL &bull; LOT1 &ge; ", NDMM_LOT1_FROM,
                          " &bull; 12-mo CE pre-LOT1 &bull; 3-mo FU CE",
                          " &bull; no belantamab &bull; no MM Tx pre-LOT1",
                          " &bull; no other cancer pre-LOT1 &bull; no pregnancy",
                          " &bull; ",
                          format(counts$ndmm_final, big.mark = ","), " patients")
  )
  log_msg("Wrote ", file.path(cfg$output_dir,
                              "ndmm_dashboard.html"))
}

if (!interactive() && !isTRUE(getOption("ndmm_dashboard.no_autorun"))) main_ndmm()
