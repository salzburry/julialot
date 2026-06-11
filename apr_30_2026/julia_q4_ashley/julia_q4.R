#!/usr/bin/env Rscript
# Julia June-5 Q4: same Q1/Q2/Q3 dashboards, but on Ashley's planned
# study cohort. Q4 layers a LOT1 eligibility cutoff plus four June-5
# IE post-filters on top of the parent ELIG_COH_FINAL:
#
#   0. LOT1_START_DT >= Q4_LOT1_FROM     (default 2017-01-01; parent's
#                                         id_start defaults to 2016-01-01)
#   1. 12-mo CE before LOT1_START_DT     (parent CE_b is 6-mo before MM-dx)
#   2. No belantamab in any LOT          (no parent equivalent)
#   3. No MM oncology Tx in 12-mo
#      pre-LOT1 baseline                 (parent's MM_BASELINE_EVIDENCE is
#                                         6-mo before MM-dx; re-anchored
#                                         and re-derived from raw claims)
#   4. No other active cancer in 12-mo
#      pre-LOT1 baseline                 (parent's OTHER_MALIGN_FLAG is
#                                         6-mo before MM-dx; re-anchored
#                                         and re-derived from raw claims)
#
#   Rscript apr_30_2026/julia_q4_ashley/julia_q4.R
#
# Output: julia_q4_ashley_dashboard.html in cfg$output_dir.
#
# Reuses julia_q1_q3.R verbatim - all Q1/Q2/Q3 builders, steroid CSV,
# category CSV, coverage QC. The Q4 script just (a) computes Ashley's
# cohort, (b) writes a filtered LOT_LONG temp view, then (c) calls
# the Q1-Q3 helpers against that view. See README.md for the per-
# filter SQL pattern, required parent inputs, and known gaps.
#
# Why this lives in its own folder: cohort change vs Q1-Q3, so a
# user can compare {dashboard A on full cohort} vs {dashboard B on
# Ashley} without confusion. Parent pipeline files untouched.

.script_dir <- local({
  override <- getOption("julia_q4.script_dir", NULL)
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
.parent_dir <- dirname(.script_dir)

# Source julia_q1_q3.R WITHOUT triggering its auto-main() and WITHOUT
# letting its .script_dir auto-resolution latch on to commandArgs()
# "--file=julia_q4.R" (which would point its R/ helper sources at the
# wrong folder). The override option below tells julia_q1_q3.R where
# to find its R/ helpers, CSV inputs, and pipeline_inputs.csv.
options(julia_q1_q3.no_autorun  = TRUE)
options(julia_q1_q3.script_dir  = .parent_dir)
source(file.path(.parent_dir, "julia_q1_q3.R"))

# Q4 needs load_codelist_csv() to materialise the MMA codelist as a
# VALUES fragment - the parent uses the same loader for S01 / step 03.
# julia_q1_q3.R does not source codelists_lot.R itself.
source(file.path(.parent_dir, "R", "codelists_lot.R"))

# Q4-only constants. Distinct view names so this script can run
# concurrently with julia_q1_q3.R without clobbering its temp views.
Q4_LOT_LONG_FILT       <- "_jjq4_lot_long_ashley"
Q4_ENROLL_SPANS        <- "_jjq4_enroll_spans"
Q4_LOT1_STARTS         <- "_jjq4_lot1_starts"
Q4_MMA_CODELIST        <- "_jjq4_mma_codelist"
Q4_THERAPY_PRE_LOT1    <- "_jjq4_therapy_pre_lot1"
Q4_OTHER_MALIG_CODES   <- "_jjq4_other_malig_codes"
Q4_MED_CLAIM_HEADER    <- "_jjq4_med_claim_header"
Q4_CONFINEMENT         <- "_jjq4_confinement"
Q4_OTHER_MALIG_PATIDS  <- "_jjq4_other_malig_patids"
Q4_FLAGS_ALL           <- "_jjq4_flags_all"   # per-PATID filter flags (for attrition)
Q4_ASHLEY_PATIDS       <- "_jjq4_ashley_patids"
Q4_PRE_LOT1_DAYS       <- 365L  # Julia June 5: 12-mo CE/baseline before 1L index date

# LOT1 eligible treatment cutoff (Julia June 5: "Received an eligible
# treatment for MM ... on or after 01 Jan 2017"). Hard-enforced in
# build_lot1_starts_q4() so the LOT1 view never returns pre-cutoff
# starts. Env-overridable for sensitivity runs (e.g. 2018-01-01).
# Independent of parent cfg$id_start which defaults to 2016-01-01.
Q4_LOT1_FROM <- Sys.getenv("Q4_LOT1_FROM", unset = "2017-01-01")

# Confinement table name (raw CDM) for the other-cancer pre-LOT1 IP
# classification. config_lot.R does not define this so Q4 sets it
# locally with the same env-var name the cohort pipeline uses.
Q4_TBL_CONFINEMENT <- Sys.getenv("TBL_CONFINEMENT", unset = "confinement")

# Steroid MED_ABBR values to exclude from the "MM oncology therapy"
# pre-LOT1 check. Same tokens as julia_q1_q3.R::STEROID_TOKENS so the
# Q4 exclusion stays consistent with Q2's augmentation semantics.
# (Steroids are supportive care; the spec wording "MM oncology therapy"
# targets actual MM agents, not supportive care.)
Q4_STEROID_ABBRS <- c("DEX","DEXA","DEXAMETHASONE","PRED","PREDNISONE")

# Cohort-pipeline knobs that julia_q1_q3.R's config_lot.R does NOT
# define (the cohort pipeline uses config_prompts.R instead). Defaults
# mirror config_prompts.R:43,90,98 verbatim, with env-var overrides
# matching the same env-var names so a user who already exports
# TBL_MEMBER_ENROLLMENT / GAP_DAYS / FINAL_TABLE_NAME for the parent
# cohort run picks up the same values here.
Q4_TBL_MEMBER_ENROLLMENT <- Sys.getenv("TBL_MEMBER_ENROLLMENT",
                                       unset = "member_enrollment")
Q4_GAP_DAYS              <- as.integer(Sys.getenv("GAP_DAYS",
                                                  unset = "30"))
Q4_FINAL_TABLE_NAME      <- Sys.getenv("FINAL_TABLE_NAME",
                                       unset = "ELIG_COH_FINAL")

# Build enrollment_spans (with Q4_GAP_DAYS allowance) directly from
# member_enrollment - the parent's temp view isn't persisted, so we
# rebuild it inside this script. SQL mirrors pipeline_steps.R:382-421
# verbatim so the gap semantics stay identical to CE_b/CE_f.
build_enrollment_spans_q4 <- function(con) {
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {Q4_ENROLL_SPANS} AS
    WITH base AS (
      SELECT PATID,
             cast(ELIGEFF as date) AS elig_eff,
             cast(ELIGEND as date) AS elig_end
      FROM {cdm_src(Q4_TBL_MEMBER_ENROLLMENT)}
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
             WHEN elig_eff <= date_add(max_end_so_far, {Q4_GAP_DAYS} + 1) THEN 0
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

# LOT1_START_DT per patient (Julia's '1L cohort index date'), with the
# Q4_LOT1_FROM cutoff enforced. Patients whose LOT1 starts before the
# cutoff are dropped from this view, which then propagates to every
# downstream Q4 step (CE / belantamab / MM-Tx / other-cancer all join
# from here).
build_lot1_starts_q4 <- function(con, lot_long) {
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {Q4_LOT1_STARTS} AS
    SELECT cast(PATID as string) AS PATID,
           LOT_START_DT AS LOT1_START_DT
    FROM {lot_long}
    WHERE LOT_NUM = 1
      AND LOT_START_DT IS NOT NULL
      AND LOT_START_DT >= date('{Q4_LOT1_FROM}')
  "))
}

# MMA codelist as a Q4-side VALUES fragment. Same CSV (cl_mma_codelist.csv)
# and same column normalisation as parent S01 / pipeline_steps.R step 03,
# but materialised inside this script so the prior-MM-Tx scan does not
# depend on the parent having left mma_codelist alive in the session.
# Steroid MED_ABBR rows are dropped here, once, so every downstream query
# inherits the steroid exclusion without having to repeat it.
build_q4_mma_codelist <- function() {
  codelist_src <- load_codelist_csv(
    "cl_mma_codelist.csv",
    c("CL_CODE_TYPE", "CL_CODE", "CL_MEDICATION_FULL", "CL_MED_CLASS", "CL_MED_ABBR"))
  ster_in <- paste0("'", Q4_STEROID_ABBRS, "'", collapse = ",")
  glue("
    CREATE OR REPLACE TEMPORARY VIEW {Q4_MMA_CODELIST} AS
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
# [LOT1_START - Q4_PRE_LOT1_DAYS, LOT1_START - 1]. Mirrors the parent's
# pipeline_steps.R:646-696 therapy_events four-source pattern
# (medical PROC_CD, medical BILL_PROC_CD, medical NDC, rx NDC) with
# NDC11 normalisation, but with a per-PATID date window driven off
# LOT1_START_DT instead of [study_start, study_end].
#
# This raw-claim scan is necessary because the parent's persisted
# MMA_MED_PROCESSED is built with `FST_DT >= INDEX_DATE` (MM-dx anchor)
# on every source branch (lot_program.R:316,336,359,386). It therefore
# cannot see any claims before the MM diagnosis, and would miss MM
# therapy occurring in the [LOT1_START - 365, INDEX_DATE - 1] portion
# of the 12-month 1L baseline that Julia's June 5 spec requires.
build_q4_therapy_pre_lot1 <- function(con, medical_tbl, rx_tbl) {
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {Q4_THERAPY_PRE_LOT1} AS
    WITH med_proc AS (
      SELECT /*+ BROADCAST(c) */ cast(m.PATID as string) AS PATID
      FROM {medical_tbl} m
      INNER JOIN {Q4_LOT1_STARTS} l1 ON cast(m.PATID as string) = l1.PATID
      INNER JOIN {Q4_MMA_CODELIST} c
        ON c.code_type IN ('HCPCS','CPT')
       AND upper(regexp_replace(coalesce(cast(m.PROC_CD as string),''), '[^A-Za-z0-9]', '')) = c.code
      WHERE cast(m.FST_DT as date)
              BETWEEN date_sub(l1.LOT1_START_DT, {Q4_PRE_LOT1_DAYS})
                  AND date_sub(l1.LOT1_START_DT, 1)
    ),
    med_bill AS (
      SELECT /*+ BROADCAST(c) */ cast(m.PATID as string) AS PATID
      FROM {medical_tbl} m
      INNER JOIN {Q4_LOT1_STARTS} l1 ON cast(m.PATID as string) = l1.PATID
      INNER JOIN {Q4_MMA_CODELIST} c
        ON c.code_type = 'HCPCS'
       AND upper(regexp_replace(coalesce(cast(m.BILL_PROC_CD as string),''), '[^A-Za-z0-9]', '')) = c.code
      WHERE cast(m.FST_DT as date)
              BETWEEN date_sub(l1.LOT1_START_DT, {Q4_PRE_LOT1_DAYS})
                  AND date_sub(l1.LOT1_START_DT, 1)
    ),
    med_ndc AS (
      SELECT /*+ BROADCAST(c) */ cast(m.PATID as string) AS PATID
      FROM {medical_tbl} m
      INNER JOIN {Q4_LOT1_STARTS} l1 ON cast(m.PATID as string) = l1.PATID
      INNER JOIN {Q4_MMA_CODELIST} c
        ON c.code_type = 'NDC'
       AND lpad(regexp_replace(coalesce(cast(m.NDC as string),''), '[^0-9]', ''), 11, '0')
         = lpad(regexp_replace(c.code, '[^0-9]', ''), 11, '0')
      WHERE cast(m.FST_DT as date)
              BETWEEN date_sub(l1.LOT1_START_DT, {Q4_PRE_LOT1_DAYS})
                  AND date_sub(l1.LOT1_START_DT, 1)
    ),
    rx_ndc AS (
      SELECT /*+ BROADCAST(c) */ cast(r.PATID as string) AS PATID
      FROM {rx_tbl} r
      INNER JOIN {Q4_LOT1_STARTS} l1 ON cast(r.PATID as string) = l1.PATID
      INNER JOIN {Q4_MMA_CODELIST} c
        ON c.code_type = 'NDC'
       AND lpad(regexp_replace(coalesce(cast(r.NDC as string),''), '[^0-9]', ''), 11, '0')
         = lpad(regexp_replace(c.code, '[^0-9]', ''), 11, '0')
      WHERE cast(r.FILL_DT as date)
              BETWEEN date_sub(l1.LOT1_START_DT, {Q4_PRE_LOT1_DAYS})
                  AND date_sub(l1.LOT1_START_DT, 1)
    )
    SELECT DISTINCT PATID FROM med_proc
    UNION SELECT DISTINCT PATID FROM med_bill
    UNION SELECT DISTINCT PATID FROM med_ndc
    UNION SELECT DISTINCT PATID FROM rx_ndc
  "))
}

# Other-malignancy codelist loaded from cl_other_malignancies CSV
# (default file: other_malig.csv, per config_prompts.R:76). Same
# loader and column normalisation as parent pipeline_steps.R step 06
# (which materialises work('other_malig_codes')). Built here so the
# Q4 IP/OP scan does not depend on the parent leaving its temp view
# alive in the session.
build_q4_other_malig_codes <- function() {
  src <- load_codelist_csv(
    "other_malig.csv",
    c("dx", "icd_family", "tumor_group"))
  glue("
    CREATE OR REPLACE TEMPORARY VIEW {Q4_OTHER_MALIG_CODES} AS
    SELECT
      upper(tumor_group) AS tumor_group,
      CASE WHEN upper(icd_family) IN ('9','ICD9','ICD-9','ICD9DIAG') THEN 'ICD9' ELSE 'ICD10' END AS icd_family,
      upper(regexp_replace(trim(dx), '[^A-Za-z0-9]', '')) AS dx
    FROM {src}
    WHERE dx IS NOT NULL AND tumor_group IS NOT NULL
  ")
}

# 5-column claim-header view used for IP/OP classification of other-
# cancer diagnoses. Mirror of parent step 07a (pipeline_steps.R:145-
# 171) but with a wider lower date bound so the Q4 pre-LOT1 baseline
# (which can extend back to Q4_LOT1_FROM - 365 days, i.e. one year
# before the cutoff) is fully visible. Upper bound is study_end.
# Confinement view mirrors parent step 07b verbatim.
build_q4_med_claim_header_and_confinement <- function(con, medical_tbl,
                                                      confinement_tbl) {
  lower <- glue("date_sub(date('{Q4_LOT1_FROM}'), {Q4_PRE_LOT1_DAYS})")
  upper <- glue("date('{cfg$study_end}')")
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {Q4_MED_CLAIM_HEADER} AS
    SELECT PATID, PAT_PLANID, CLMID, FST_DT, LOC_CD,
           max(CONF_ID) AS CONF_ID,
           max(POS)     AS POS,
           max(TOS_CD)  AS TOS_CD
    FROM {medical_tbl}
    WHERE FST_DT BETWEEN {lower} AND {upper}
    GROUP BY PATID, PAT_PLANID, CLMID, FST_DT, LOC_CD
  "))
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {Q4_CONFINEMENT} AS
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
build_q4_other_malig_pre_lot1 <- function(con, med_diag_tbl) {
  lower <- glue("date_sub(date('{Q4_LOT1_FROM}'), {Q4_PRE_LOT1_DAYS})")
  upper <- glue("date('{cfg$study_end}')")
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {Q4_OTHER_MALIG_PATIDS} AS
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
      INNER JOIN {Q4_OTHER_MALIG_CODES} o
              ON dx.dx = o.dx AND dx.icd_family = o.icd_family
    ),
    dx_with_setting AS (
      SELECT dm.PATID, dm.CLMID, dm.event_dt, dm.tumor_group,
             CASE WHEN h.POS IN ('21', '51', '61')
                    OR h.TOS_CD IN ('FAC_IP.ACUTE', 'FAC_IP.REHSNF', 'PROF.INPVIS', 'FAC_IP.SNF')
                    OR cf.CONF_ID IS NOT NULL
                  THEN 1 ELSE 0 END AS inpatient_flg
      FROM dx_mapped dm
      INNER JOIN {Q4_MED_CLAIM_HEADER} h
            ON dm.PATID      =   h.PATID
           AND dm.CLMID      =   h.CLMID
           AND dm.FST_DT     =   h.FST_DT
           AND dm.PAT_PLANID <=> h.PAT_PLANID
           AND dm.LOC_CD     <=> h.LOC_CD
      LEFT JOIN {Q4_CONFINEMENT} cf
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
             date_sub(LOT1_START_DT, {Q4_PRE_LOT1_DAYS}) AS pre_lot1_start,
             date_sub(LOT1_START_DT, 1)                  AS pre_lot1_end
      FROM {Q4_LOT1_STARTS}
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

# Per-PATID flag table for the four Q4 filters layered on top of
# ELIG_COH_FINAL. Rows are restricted to (ELIG_COH_FINAL INNER JOIN
# LOT1) - i.e. patients in the parent cohort who actually have a 1L
# treatment in LOT_LONG that starts on/after Q4_LOT1_FROM. Flags:
#
#   CE_pre_lot1_12mo        : >=1 enrollment span covers
#                             [LOT1_START - Q4_PRE_LOT1_DAYS, LOT1_START - 1]
#                             (Julia June 5: 12-mo CE before 1L; same gap
#                             semantics as parent CE_b/CE_f via
#                             Q4_ENROLL_SPANS)
#
#   NO_BELANTAMAB           : zero MAP_STACKED rows for the PATID where
#                             MAP_MED_TYPE LIKE 'BEL%'. Narrower than the
#                             lot1_studyteam_qs.R inventory predicate
#                             (which adds MAP_MED_CLASS LIKE '%BCMA%' to
#                             also catch bispecifics and CAR-T for
#                             descriptive counting): Julia's exclusion is
#                             belantamab specifically, so we drop the
#                             class match. Because MAP_STACKED only
#                             contains agents on the parent's MMA
#                             codelist, BEL* within MAP_STACKED reliably
#                             means belantamab.
#
#   NO_PRIOR_MM_TX          : zero PATID rows in Q4_THERAPY_PRE_LOT1 (the
#                             raw-claim four-source scan over the full
#                             pre-LOT1 window; see build_q4_therapy_pre_lot1
#                             for why we cannot reuse MMA_MED_PROCESSED).
#
#   NO_OTHER_CANCER_PRE_LOT1: zero PATID rows in Q4_OTHER_MALIG_PATIDS
#                             (Julia June 5: "Evidence of another active
#                             cancer ... during the 1L baseline period";
#                             re-anchored from parent OTHER_MALIGN_FLAG
#                             which uses 6-mo pre-MM-dx. IP/OP same-tumor-
#                             group logic mirrors parent step 22.)
build_q4_flags <- function(con, elig_coh_final, map_stacked,
                           q2_ok_belantamab, q2_ok_priortx,
                           q2_ok_othercancer) {
  bela_expr <- if (q2_ok_belantamab) glue("
        SELECT DISTINCT cast(PATID as string) AS PATID
        FROM {map_stacked}
        WHERE upper(MAP_MED_TYPE) LIKE 'BEL%'
  ") else "SELECT cast(NULL as string) AS PATID WHERE 1 = 0"

  prior_tx_expr <- if (q2_ok_priortx) glue("
        SELECT DISTINCT PATID FROM {Q4_THERAPY_PRE_LOT1}
  ") else "SELECT cast(NULL as string) AS PATID WHERE 1 = 0"

  other_cancer_expr <- if (q2_ok_othercancer) glue("
        SELECT DISTINCT cast(PATID as string) AS PATID FROM {Q4_OTHER_MALIG_PATIDS}
  ") else "SELECT cast(NULL as string) AS PATID WHERE 1 = 0"

  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {Q4_FLAGS_ALL} AS
    WITH ec_l1 AS (
      SELECT cast(ec.PATID as string) AS PATID, l1.LOT1_START_DT,
             date_sub(l1.LOT1_START_DT, {Q4_PRE_LOT1_DAYS}) AS pre_lot1_start,
             date_sub(l1.LOT1_START_DT, 1)                  AS pre_lot1_end
      FROM {elig_coh_final} ec
      INNER JOIN {Q4_LOT1_STARTS} l1
              ON cast(ec.PATID as string) = l1.PATID
    ),
    ce AS (
      SELECT ec_l1.PATID,
             max(CASE WHEN s.cov_start <= ec_l1.pre_lot1_start
                       AND s.cov_end   >= ec_l1.pre_lot1_end
                      THEN 1 ELSE 0 END) AS CE_pre_lot1_12mo
      FROM ec_l1
      LEFT JOIN {Q4_ENROLL_SPANS} s ON s.PATID = ec_l1.PATID
      GROUP BY ec_l1.PATID
    ),
    bela AS ({bela_expr}),
    prior_tx AS ({prior_tx_expr}),
    other_cancer AS ({other_cancer_expr})
    SELECT ec_l1.PATID,
           ce.CE_pre_lot1_12mo,
           CASE WHEN bela.PATID         IS NULL THEN 1 ELSE 0 END AS NO_BELANTAMAB,
           CASE WHEN prior_tx.PATID     IS NULL THEN 1 ELSE 0 END AS NO_PRIOR_MM_TX,
           CASE WHEN other_cancer.PATID IS NULL THEN 1 ELSE 0 END AS NO_OTHER_CANCER_PRE_LOT1
    FROM ec_l1
    LEFT JOIN ce           ON ec_l1.PATID = ce.PATID
    LEFT JOIN bela         ON ec_l1.PATID = bela.PATID
    LEFT JOIN prior_tx     ON ec_l1.PATID = prior_tx.PATID
    LEFT JOIN other_cancer ON ec_l1.PATID = other_cancer.PATID
  "))

  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {Q4_ASHLEY_PATIDS} AS
    SELECT PATID FROM {Q4_FLAGS_ALL}
    WHERE CE_pre_lot1_12mo        = 1
      AND NO_BELANTAMAB           = 1
      AND NO_PRIOR_MM_TX          = 1
      AND NO_OTHER_CANCER_PRE_LOT1 = 1
  "))
}

# Filtered LOT_LONG view feeding the Q1/Q2/Q3 helpers.
build_lot_long_filtered <- function(con, lot_long) {
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {Q4_LOT_LONG_FILT} AS
    SELECT l.*
    FROM {lot_long} l
    INNER JOIN {Q4_ASHLEY_PATIDS} a
            ON cast(l.PATID as string) = a.PATID
  "))
}

# Counts at each filter step for the attrition card. Steps after
# ELIG_COH_FINAL + LOT1 are CUMULATIVE - each row applies all previous
# Ashley filters plus the new one, so the table reads top-to-bottom as
# the funnel Julia/Ashley would expect.
q4_counts <- function(con, lot_long, elig_coh_final) {
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
     INNER JOIN {Q4_LOT1_STARTS} l1
             ON cast(ec.PATID as string) = l1.PATID"))$n
  ce12 <- db_q(con, glue(
    "SELECT count(DISTINCT PATID) AS n FROM {Q4_FLAGS_ALL}
     WHERE CE_pre_lot1_12mo = 1"))$n
  ce12_nobela <- db_q(con, glue(
    "SELECT count(DISTINCT PATID) AS n FROM {Q4_FLAGS_ALL}
     WHERE CE_pre_lot1_12mo = 1 AND NO_BELANTAMAB = 1"))$n
  ce12_nobela_nopriortx <- db_q(con, glue(
    "SELECT count(DISTINCT PATID) AS n FROM {Q4_FLAGS_ALL}
     WHERE CE_pre_lot1_12mo = 1
       AND NO_BELANTAMAB    = 1
       AND NO_PRIOR_MM_TX   = 1"))$n
  ashley <- db_q(con, glue(
    "SELECT count(DISTINCT PATID) AS n FROM {Q4_ASHLEY_PATIDS}"))$n
  list(whole = whole, elig = elig, elig_lot1 = elig_lot1,
       ce12 = ce12, ce12_nobela = ce12_nobela,
       ce12_nobela_nopriortx = ce12_nobela_nopriortx,
       ashley = ashley)
}

build_q4_overview_card <- function(counts, n_ster_codes, n_cat_rules,
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
    '<h3>Julia June 5 - NDMM (1L newly-diagnosed) planned cohort</h3>',
    '<p style="color:#555;font-size:13px">Q1 / Q2 / Q3 dashboards on ',
    'Julia&apos;s planned cohort: parent <code>ELIG_COH_FINAL</code> ',
    '(all default IE flags applied) plus a Q4-side LOT1 eligibility ',
    'cutoff (<code>LOT_START_DT &ge; ', Q4_LOT1_FROM, '</code>) and ',
    'four Q4-only post-filters from the June 5 PDF: <b>12-mo CE before ',
    'LOT1</b>, <b>no belantamab in any LOT</b>, <b>no MM oncology therapy ',
    'in the 12-mo 1L baseline</b>, and <b>no other active cancer in the ',
    '12-mo 1L baseline</b>. CE-pre-LOT1 uses the parent&apos;s <code>gap_days = ',
    Q4_GAP_DAYS, '</code> allowance. Belantamab detection scans ',
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
    '<code>other_malig.csv</code>) and a Q4-rebuilt 5-column ',
    '<code>med_claim_header</code> / <code>confinement</code> for IP/OP ',
    'classification.</p>',
    '<table style="font-size:13px;border-collapse:collapse;margin-top:8px">',
    '<tr style="background:#eef"><th style="text-align:left;padding:6px 12px">Filter step</th>',
    '<th style="text-align:right;padding:6px 12px">n patients</th>',
    '<th style="text-align:right;padding:6px 12px">% of whole</th></tr>',
    row("Whole LOT_LONG cohort",                                       counts$whole),
    row("+ in ELIG_COH_FINAL (parent IE)",                             counts$elig),
    row(paste0("+ has LOT1 start &ge; ", Q4_LOT1_FROM, " in LOT_LONG"), counts$elig_lot1),
    row("+ 12-mo CE pre-LOT1",                                         counts$ce12),
    row("+ no belantamab in any LOT",                                  counts$ce12_nobela),
    row("+ no MM oncology Tx in 12-mo pre-LOT1",                       counts$ce12_nobela_nopriortx),
    row("+ no other active cancer in 12-mo pre-LOT1 (NDMM final)",
        counts$ashley, bold = TRUE, bg = "#efe"),
    '</table>',
    notes_html,
    '<ul style="font-size:13px;color:#1a7a3a;margin-top:10px">',
    '<li><b>Q1</b>: regimen-category Sankeys per LOT pair (',
    n_cat_rules, ' regimen rules loaded).</li>',
    '<li><b>Q2</b>: steroid tokens appended to <code>LOT_BASE_MEDS</code> ',
    'inside the parent induction window (', n_ster_codes, ' codes loaded; ',
    '<code>SCT_ALLO</code>-started LOTs suppressed).</li>',
    '<li><b>Q3</b>: non-progressors dropped (inner-join LOTn &rarr; LOTn+1).</li>',
    '</ul></div>'),
    section = section, title = title)
}

# Cohort-attrition card for the NDMM cohort. Mirrors
# build_overall_attrition() shape (table + waterfall) so both cohorts
# read the same way in the combined dashboard. Driven by the `counts`
# struct that q4_counts() already computes during prepare_ndmm_cohort()
# - no extra SQL needed. The inline 7-row table inside the NDMM overview
# card stays as a quick-glance summary; this card is the detail view.
build_ndmm_attrition <- function(counts, section = "OVERVIEW",
                                 title_prefix = "") {
  df <- data.frame(
    step = c("01_whole", "02_elig", "03_lot1", "04_ce12",
             "05_nobela", "06_nopriortx", "07_noother_final"),
    description = c(
      "Whole LOT_LONG cohort",
      "+ in ELIG_COH_FINAL (parent IE)",
      paste0("+ LOT1 start >= ", Q4_LOT1_FROM, " in LOT_LONG"),
      "+ 12-mo CE pre-LOT1",
      "+ no belantamab in any LOT",
      "+ no MM oncology Tx in 12-mo pre-LOT1",
      "+ no other active cancer in 12-mo pre-LOT1 (NDMM final)"),
    n_patients = as.integer(c(
      counts$whole, counts$elig, counts$elig_lot1, counts$ce12,
      counts$ce12_nobela, counts$ce12_nobela_nopriortx, counts$ashley)),
    stringsAsFactors = FALSE
  )
  df$pct_of_prev <- NA_real_
  if (nrow(df) > 1) {
    for (i in 2:nrow(df)) {
      prev_n <- df$n_patients[i - 1]
      df$pct_of_prev[i] <- if (prev_n > 0)
        round(100 * df$n_patients[i] / prev_n, 1) else NA_real_
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
           subtitle = paste0("LOT1 cutoff ", Q4_LOT1_FROM,
                             " + four June 5 filters applied to LOT_LONG"),
           x = NULL, y = "Patients remaining") +
      theme_lot()
    save_plot(p_att, "ndmm_attrition.png", width = 10, height = 6,
              section = section,
              title = paste0(title_prefix, "NDMM attrition waterfall"))
  }
}

# NDMM (Ashley planned) cohort setup, shared by main_q4() and the
# combined dashboard. Computes the cohort, writes the filtered LOT_LONG
# view, augments it with steroid tokens into LOT_LONG_AUG, and loads
# category lookups. Leaves LOT_LONG_AUG populated for the NDMM cohort
# and returns the scalars the overview card + builders need. Does NOT
# touch dashboard_items.
prepare_ndmm_cohort <- function(con) {
  lot_long        <- wrk("LOT_LONG")
  elig_coh_final  <- wrk(Q4_FINAL_TABLE_NAME)
  map_stacked     <- wrk("MAP_STACKED")
  rx_tbl          <- cdm_src(cfg$tbl_rx)
  medical_tbl     <- cdm_src(cfg$tbl_medical)
  med_diag_tbl    <- cdm_src(cfg$tbl_med_diag)
  confinement_tbl <- cdm_src(Q4_TBL_CONFINEMENT)

  ok <- function(t) isTRUE(tryCatch(
    nrow(db_q(con, glue("SELECT 1 FROM {t} LIMIT 1"))) >= 0,
    error = function(e) FALSE))
  if (!ok(lot_long))       stop("Cannot read ", lot_long)
  if (!ok(elig_coh_final)) stop("Cannot read ", elig_coh_final,
                                " - NDMM cohort needs parent ELIG_COH_FINAL.")
  raw_ok <- ok(rx_tbl) && ok(medical_tbl)
  if (!raw_ok) {
    log_msg("  WARN: rx or medical unreadable; Q2 steroid augmentation ",
            "AND Q4 MM-Tx pre-LOT1 scan skipped.")
  }
  q2_ok <- raw_ok   # Q2 steroid augmentation still needs raw rx/medical
  # Q4 filters that depend on parent / raw inputs. Each filter is gated
  # by readability of its inputs; if any input is unreadable we log
  # loudly, skip the corresponding filter, and surface a note in the
  # OVERVIEW card. Q4 still runs with the filters it can apply rather
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
             "<code>lot_program.R</code>."))
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
             cfg$tbl_medical, "</code> / <code>", Q4_TBL_CONFINEMENT,
             "</code> unreadable."))
  }

  log_msg("Building enrollment spans (gap_days=", Q4_GAP_DAYS, ")")
  build_enrollment_spans_q4(con)

  log_msg("Pulling LOT1 starts (>= ", Q4_LOT1_FROM, ") from ", lot_long)
  build_lot1_starts_q4(con, lot_long)

  if (priortx_ok) {
    log_msg("Loading MMA codelist (steroid abbrs excluded) -> ", Q4_MMA_CODELIST)
    db_exec(con, build_q4_mma_codelist())
    log_msg("Scanning raw medical + rx for MM Tx in [LOT1-",
            Q4_PRE_LOT1_DAYS, ", LOT1-1] -> ", Q4_THERAPY_PRE_LOT1)
    build_q4_therapy_pre_lot1(con, medical_tbl, rx_tbl)
  }

  if (othercancer_ok) {
    log_msg("Loading other-malignancy codelist -> ", Q4_OTHER_MALIG_CODES)
    db_exec(con, build_q4_other_malig_codes())
    log_msg("Building Q4 med_claim_header and confinement views")
    build_q4_med_claim_header_and_confinement(con, medical_tbl, confinement_tbl)
    log_msg("Scanning other-malignancy claims in [LOT1-",
            Q4_PRE_LOT1_DAYS, ", LOT1-1] -> ", Q4_OTHER_MALIG_PATIDS)
    build_q4_other_malig_pre_lot1(con, med_diag_tbl)
  }

  log_msg("Applying NDMM filters: ELIG_COH_FINAL + 12-mo CE pre-LOT1 + ",
          "no belantamab + no MM oncology Tx in 12-mo pre-LOT1 + ",
          "no other-cancer in 12-mo pre-LOT1")
  build_q4_flags(con, elig_coh_final, map_stacked,
                 q2_ok_belantamab  = bela_ok,
                 q2_ok_priortx     = priortx_ok,
                 q2_ok_othercancer = othercancer_ok)

  log_msg("Building filtered LOT_LONG -> ", Q4_LOT_LONG_FILT)
  build_lot_long_filtered(con, lot_long)

  if (q2_ok) {
    log_msg("Loading steroid codes")
    n_ster <- load_steroid_codes(con)
    log_msg("  ", n_ster, " codes loaded")
  } else {
    n_ster <- 0L
  }

  log_msg("Augmenting filtered LOT_LONG with steroid tokens")
  augment_lot_long(con, Q4_LOT_LONG_FILT, rx_tbl, medical_tbl, n_ster)

  log_msg("Loading categories")
  lookups <- load_categories()
  n_rules <- length(lookups$lookup_1L) + length(lookups$lookup_2L)
  log_msg("  ", length(lookups$lookup_1L), " 1L rules, ",
          length(lookups$lookup_2L), " 2L+ rules loaded")

  counts <- q4_counts(con, lot_long, elig_coh_final)
  log_msg("Cohort sizes - whole: ", counts$whole,
          " | ELIG_COH_FINAL: ", counts$elig,
          " | + LOT1 >= ", Q4_LOT1_FROM, ": ", counts$elig_lot1,
          " | + 12-mo CE: ", counts$ce12,
          " | + no bela: ", counts$ce12_nobela,
          " | + no MM Tx pre-LOT1: ", counts$ce12_nobela_nopriortx,
          " | NDMM (final): ", counts$ashley)
  if (counts$ashley == 0)
    stop("NDMM cohort is empty - check ELIG_COH_FINAL and LOT_LONG inputs.")

  list(counts = counts, n_ster = n_ster, n_rules = n_rules,
       lookups = lookups, overview_notes = overview_notes)
}

main_q4 <- function() {
  stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")
  cfg$build_dashboard <<- TRUE

  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn,
                        pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  p <- prepare_ndmm_cohort(con)

  dashboard_items <<- list()
  build_q4_overview_card(p$counts, p$n_ster, p$n_rules, p$overview_notes)
  build_ndmm_attrition(p$counts)
  build_steroid_prevalence(con)
  for (n in 1:4) build_focused_pair(con, n, n + 1L)
  for (n in 1:4) build_category_pair(con, n, n + 1L, p$lookups)
  build_category_coverage(con, p$lookups)

  counts <- p$counts
  build_dashboard(
    out_name     = "julia_q4_ashley_dashboard.html",
    header_title = "MM LOT &mdash; Julia June 5 (NDMM planned cohort)",
    header_sub   = paste0("ELIG_COH_FINAL &bull; LOT1 &ge; ", Q4_LOT1_FROM,
                          " &bull; 12-mo CE pre-LOT1 &bull; no belantamab",
                          " &bull; no MM Tx pre-LOT1 &bull; no other cancer",
                          " pre-LOT1 &bull; ",
                          format(counts$ashley, big.mark = ","), " patients")
  )
  log_msg("Wrote ", file.path(cfg$output_dir,
                              "julia_q4_ashley_dashboard.html"))
}

if (!interactive() && !isTRUE(getOption("julia_q4.no_autorun"))) main_q4()
