# Another active cancer in the 12 months before LOT1.
#
# Ported from apr_30_2026/06_ndmm_dashboard.R lines 318-533.
# tests/test_same_as_source.R compares this against that range.

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
      -- And non-blank once normalised: '---' would otherwise match every
      -- diagnosis claim with a missing code. See 03_prior_therapy.R.
      AND regexp_replace(trim(dx), '[^A-Za-z0-9]', '') <> ''
  "))
  n_exp     <- length(NDMM_MM_ADJACENT_OVERRIDE)
  n_matched <- tryCatch(as.integer(db_q(con, glue("
    SELECT count(DISTINCT tumor_group) AS n
    FROM {NDMM_OTHER_MALIG_CODES}
    WHERE is_mm_adjacent_override = 1
  "))$n), error = function(e) NA_integer_)
  # The source logged this and carried on. An unmatched label means the
  # override is a silent no-op for that tumour group, so patients whose only
  # other cancer is MM-adjacent are excluded as having another cancer - a
  # smaller cohort, with nothing in the attrition saying why. Its own comment
  # calls that a run-review blocker, so stop rather than warn.
  if (is.na(n_matched) || n_matched < n_exp)
    stop("NDMM other-cancer override: matched ",
         if (is.na(n_matched)) "no" else n_matched, " of ", n_exp,
         " expected MM-adjacent tumor_group labels. The unmatched ones are ",
         "not overridden, so patients would be excluded for an MM-adjacent ",
         "condition. Run 'SELECT DISTINCT tumor_group FROM ",
         NDMM_OTHER_MALIG_CODES, "' on the warehouse and align ",
         "NDMM_MM_ADJACENT_OVERRIDE to the stored labels.", call. = FALSE)
  log_msg("  NDMM other-cancer override: matched all ", n_exp,
          " expected MM-adjacent tumor_group labels")
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
#                             (12-mo CE before 1L; same gap
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
#                             ("Evidence of another active
#                             cancer ... during the 1L baseline period";
#                             re-anchored from parent OTHER_MALIGN_FLAG
#                             which uses 6-mo pre-MM-dx. IP/OP same-tumor-
#                             group logic mirrors parent step 22.)
#
#   CE_lot1_3mo_fu          : 3-month follow-up CE re-derived ANCHORED AT
#                             LOT1 (the NDMM index): a span covers
#                             [LOT1_START, least(LOT1_START + 90, study_end,
#                             death)]. No-gap spans (NDMM_ENROLL_SPANS_STRICT)
#                             plus carried-forward DEATH_DT
#                             (>=3-mo CE during follow-up or death, NO gaps).
#
#   NO_PREGNANCY            : re-scanned from pregnancy.csv (dx / HCPCS / ICD
#                             procedure / revenue codes) over the study period,
#                             restricted to NDMM LOT1 candidates - NOT the
#                             parent PREGNANT_FLAG. NDMM exclusion.
# Readability probe used by the pregnancy gate (the scan view may not exist
# if its source claims tables are unavailable).
.ndmm_table_ok <- function(con, tbl) isTRUE(tryCatch(
  nrow(db_q(con, glue("SELECT 1 FROM {tbl} LIMIT 1"))) >= 0,
  error = function(e) FALSE))

# Pregnancy exclusion: re-scanned directly from pregnancy.csv
# over the study period, NOT carried from the parent PREGNANT_FLAG - so it is
# self-contained and uses the NDMM pregnancy codelist + an any-time-
# in-study-period window.
