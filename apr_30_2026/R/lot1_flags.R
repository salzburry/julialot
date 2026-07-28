# =============================================================================
# lot1_flags.R -- LOT1-anchored IE flags, as a reusable pipeline stage
# -----------------------------------------------------------------------------
# Lifted verbatim out of 06_ndmm_dashboard.R so the flags are a PIPELINE STAGE
# rather than a dashboard's private cohort logic. Two consumers:
#
#   06_ndmm_dashboard.R          sources this and calls build_lot1_flags()
#   "Jul 28"/build_lot1_flags.R  runs it as a standalone stage
#
# NOTHING about these criteria is NDMM-specific -- they are "IE criteria
# anchored at LOT1_START_DT". The NDMM_ naming was an artifact of where they
# were written, and is why they were never reusable. Renamed LOT1_ here.
#
# TWO GENERALISATIONS vs the original (everything else is character-for-
# character the same SQL):
#
#   1. The patient input is a PARAMETER, not hardcoded to ELIG_COH_FINAL.
#      Pass ELIG_COH_FINAL for the legacy path, or the "Jul 28" union view
#      (coh_index_union) to build the flags without an Overall cohort ever
#      being selected. The input must expose PATID + INDEX_DATE; both do.
#
#   2. Views are keyed by (PATID, INDEX_DATE), not PATID alone. The original
#      could key on PATID because ELIG_COH_FINAL is already one row per patient
#      (step 24 takes rn = 1). A union over cohorts that select DIFFERENT index
#      dates for the same patient can carry two rows, and a PATID-only key
#      would silently conflate them. See the per-view notes on which scans are
#      index-DEPENDENT (window anchored at LOT1, so keyed by the pair) and
#      which are index-INDEPENDENT (whole study period, so PATID is enough).
#
# Requires the LOT stack's helpers: cfg, db_exec, db_q, log_msg (config_lot.R,
# db_utils_lot.R) and load_codelist_csv (codelists_lot.R).
# =============================================================================

# ---- view names -------------------------------------------------------------
# Temp views. The persisted twin of LOT1_FLAGS_ALL is LOT1_FLAGS_ALL_TBL, which
# is what "Jul 28"/cohorts read via the LOT1_FLAGS_TABLE env var.
LOT1_ENROLL_SPANS        <- "_lot1_enroll_spans"
LOT1_ENROLL_SPANS_STRICT <- "_lot1_enroll_spans_strict"  # no-gap, for the 3-mo FU CE
LOT1_STARTS              <- "_lot1_starts"
LOT1_MMA_CODELIST        <- "_lot1_mma_codelist"
LOT1_THERAPY_PRE         <- "_lot1_therapy_pre"
LOT1_OTHER_MALIG_CODES   <- "_lot1_other_malig_codes"
LOT1_MED_CLAIM_HEADER    <- "_lot1_med_claim_header"
LOT1_CONFINEMENT         <- "_lot1_confinement"
LOT1_OTHER_MALIG_PATIDS  <- "_lot1_other_malig_patids"
LOT1_PREG_CODES          <- "_lot1_preg_codes"
LOT1_PREGNANCY_PATIDS    <- "_lot1_pregnancy_patids"
LOT1_FLAGS_ALL           <- "_lot1_flags_all"
LOT1_STARTS_TBL          <- Sys.getenv("LOT1_STARTS_TABLE", unset = "LOT1_STARTS")
LOT1_FLAGS_ALL_TBL       <- Sys.getenv("LOT1_FLAGS_TABLE",  unset = "LOT1_FLAGS_ALL")

# ---- parameters -------------------------------------------------------------
LOT1_STUDY_START   <- Sys.getenv("STUDY_START", unset = "2015-07-01")
# 12-mo CE/baseline before the 1L index date. Was a hard-coded 365L; lifted to
# an env var here, which cohort_explorer/ANALYTIC_COHORT.md flagged as the
# one-line change the pipeline owner should make. Default is unchanged.
LOT1_PRE_DAYS      <- as.integer(Sys.getenv("NDMM_PRE_LOT1_DAYS", unset = "365"))
LOT1_FROM          <- Sys.getenv("NDMM_LOT1_FROM", unset = "2017-01-01")
LOT1_TBL_CONFINEMENT <- Sys.getenv("TBL_CONFINEMENT", unset = "confinement")
LOT1_TBL_MEMBER_ENROLLMENT <- Sys.getenv("TBL_MEMBER_ENROLLMENT",
                                         unset = "member_enrollment")
LOT1_GAP_DAYS      <- as.integer(Sys.getenv("GAP_DAYS", unset = "30"))

# Steroid MED_ABBRs dropped from the MMA codelist, so the pre-LOT1 MM-therapy
# exclusion stays consistent with the steroid-augmentation semantics of the LOT
# build (02_lot1.R excludes MAP_MED_CLASS = 'STEROID' from LOT1_START_DT).
LOT1_STEROID_ABBRS <- c("DEX", "DEXA", "DEXAMETHASONE", "PRED", "PREDNISONE")

# Tumor_group labels treated as NON-exclusionary for the other-cancer filter.
# Plasma-cell / MM-adjacent entities that are the index MM rather than a second
# primary. Adds a flag column at codelist-load time; the underlying codelist is
# not modified. STILL PENDING CONFIRMATION against the stored labels -- the
# loader logs how many matched and warns on a shortfall.
LOT1_MM_ADJACENT_OVERRIDE <- c(
  "MULTIPLE MYELOMA",
  "PLASMA CELL LEUKEMIA",
  "PLASMACYTOMA",
  "MONOCLONAL GAMMOPATHY",
  "AMYLOIDOSIS"
)

# Probe: is a source table readable? A filter whose source is unavailable is
# SKIPPED (flag passes everyone) rather than failing the run -- preserved from
# the original, and reported by the caller.
.lot1_table_ok <- function(con, tbl) isTRUE(tryCatch(
  nrow(db_q(con, glue("SELECT 1 FROM {tbl} LIMIT 1"))) >= 0,
  error = function(e) FALSE))

# =============================================================================
# Enrollment spans
# =============================================================================
# Built directly from member_enrollment; the cohort pipeline's temp view is not
# persisted. SQL mirrors pipeline_steps.R:382-421 verbatim so the gap semantics
# stay identical to CE_b / CE_f. Index-INDEPENDENT (pure coverage history), so
# keyed by PATID.
build_lot1_enrollment_spans <- function(con, view = LOT1_ENROLL_SPANS,
                                        gap_days = LOT1_GAP_DAYS) {
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {view} AS
    WITH base AS (
      SELECT PATID,
             cast(ELIGEFF as date) AS elig_eff,
             cast(ELIGEND as date) AS elig_end
      FROM {cdm_src(LOT1_TBL_MEMBER_ENROLLMENT)}
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

# =============================================================================
# LOT1 starts -- the 1L index date
# =============================================================================
# GENERALISED: carries INDEX_DATE, taken from the patient input, so every
# downstream view can key on the pair. The LOT1_FROM cutoff is enforced here and
# propagates to every downstream step, exactly as before.
#
# The INNER JOIN to patient_input is what restricts the LOT1 set to the cohort
# under construction. Pass coh_index_union to build these flags with no Overall
# cohort involved; pass ELIG_COH_FINAL for the legacy behaviour.
build_lot1_starts <- function(con, lot_long, patient_input) {
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {LOT1_STARTS} AS
    SELECT cast(l.PATID as string) AS PATID,
           cast(p.INDEX_DATE as date) AS INDEX_DATE,
           l.LOT_START_DT AS LOT1_START_DT
    FROM {lot_long} l
    INNER JOIN {patient_input} p
            ON cast(l.PATID as string) = cast(p.PATID as string)
    WHERE l.LOT_NUM = 1
      AND l.LOT_START_DT IS NOT NULL
      AND l.LOT_START_DT >= date('{LOT1_FROM}')
  "))
}

# =============================================================================
# MMA codelist (steroid abbrs dropped)
# =============================================================================
# Same CSV and column normalisation as pipeline_steps.R step 03, materialised
# here so the pre-LOT1 MM-Tx scan does not depend on the cohort pipeline having
# left mma_codelist alive in the session.
build_lot1_mma_codelist <- function() {
  codelist_src <- load_codelist_csv(
    "cl_mma_codelist.csv",
    c("CL_CODE_TYPE", "CL_CODE", "CL_MEDICATION_FULL", "CL_MED_CLASS", "CL_MED_ABBR"))
  ster_in <- paste0("'", LOT1_STEROID_ABBRS, "'", collapse = ",")
  glue("
    CREATE OR REPLACE TEMPORARY VIEW {LOT1_MMA_CODELIST} AS
    SELECT upper(trim(CL_CODE_TYPE)) AS code_type,
           upper(regexp_replace(trim(CL_CODE), '[^A-Za-z0-9]', '')) AS code,
           upper(trim(CL_MED_ABBR))  AS med_abbr
    FROM {codelist_src}
    WHERE CL_CODE      IS NOT NULL AND trim(CL_CODE)      <> ''
      AND CL_CODE_TYPE IS NOT NULL AND trim(CL_CODE_TYPE) <> ''
      AND upper(coalesce(CL_MED_ABBR, '')) NOT IN ({ster_in})
  ")
}

# =============================================================================
# MM oncology therapy in the pre-LOT1 baseline
# =============================================================================
# Mirrors the cohort pipeline's four-source therapy_events pattern
# (pipeline_steps.R:646-696: medical PROC_CD, medical BILL_PROC_CD, medical NDC,
# rx NDC) with NDC11 normalisation, but over a per-patient window driven off
# LOT1_START_DT instead of [study_start, study_end].
#
# The raw-claim scan is necessary because MMA_MED_PROCESSED is built with
# `FST_DT >= INDEX_DATE` on every source branch (02_lot1.R:316,336,359,386), so
# it cannot see claims before the MM diagnosis and would miss therapy in the
# [LOT1_START - 365, INDEX_DATE - 1] portion of the baseline.
#
# Index-DEPENDENT (window anchored at LOT1_START_DT) -> keyed by the pair.
build_lot1_therapy_pre <- function(con, medical_tbl, rx_tbl) {
  win <- glue("BETWEEN date_sub(l1.LOT1_START_DT, {LOT1_PRE_DAYS})
                   AND date_sub(l1.LOT1_START_DT, 1)")
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {LOT1_THERAPY_PRE} AS
    WITH med_proc AS (
      SELECT /*+ BROADCAST(c) */ cast(m.PATID as string) AS PATID, l1.INDEX_DATE
      FROM {medical_tbl} m
      INNER JOIN {LOT1_STARTS} l1 ON cast(m.PATID as string) = l1.PATID
      INNER JOIN {LOT1_MMA_CODELIST} c
        ON c.code_type IN ('HCPCS','CPT')
       AND upper(regexp_replace(coalesce(cast(m.PROC_CD as string),''), '[^A-Za-z0-9]', '')) = c.code
      WHERE cast(m.FST_DT as date) {win}
    ),
    med_bill AS (
      SELECT /*+ BROADCAST(c) */ cast(m.PATID as string) AS PATID, l1.INDEX_DATE
      FROM {medical_tbl} m
      INNER JOIN {LOT1_STARTS} l1 ON cast(m.PATID as string) = l1.PATID
      INNER JOIN {LOT1_MMA_CODELIST} c
        ON c.code_type = 'HCPCS'
       AND upper(regexp_replace(coalesce(cast(m.BILL_PROC_CD as string),''), '[^A-Za-z0-9]', '')) = c.code
      WHERE cast(m.FST_DT as date) {win}
    ),
    med_ndc AS (
      SELECT /*+ BROADCAST(c) */ cast(m.PATID as string) AS PATID, l1.INDEX_DATE
      FROM {medical_tbl} m
      INNER JOIN {LOT1_STARTS} l1 ON cast(m.PATID as string) = l1.PATID
      INNER JOIN {LOT1_MMA_CODELIST} c
        ON c.code_type = 'NDC'
       AND lpad(regexp_replace(coalesce(cast(m.NDC as string),''), '[^0-9]', ''), 11, '0')
         = lpad(regexp_replace(c.code, '[^0-9]', ''), 11, '0')
      WHERE cast(m.FST_DT as date) {win}
    ),
    rx_ndc AS (
      SELECT /*+ BROADCAST(c) */ cast(r.PATID as string) AS PATID, l1.INDEX_DATE
      FROM {rx_tbl} r
      INNER JOIN {LOT1_STARTS} l1 ON cast(r.PATID as string) = l1.PATID
      INNER JOIN {LOT1_MMA_CODELIST} c
        ON c.code_type = 'NDC'
       AND lpad(regexp_replace(coalesce(cast(r.NDC as string),''), '[^0-9]', ''), 11, '0')
         = lpad(regexp_replace(c.code, '[^0-9]', ''), 11, '0')
      WHERE cast(r.FILL_DT as date) {win}
    )
    SELECT DISTINCT PATID, INDEX_DATE FROM med_proc
    UNION SELECT DISTINCT PATID, INDEX_DATE FROM med_bill
    UNION SELECT DISTINCT PATID, INDEX_DATE FROM med_ndc
    UNION SELECT DISTINCT PATID, INDEX_DATE FROM rx_ndc
  "))
}

# =============================================================================
# Other-malignancy codelist
# =============================================================================
# Same loader and normalisation as pipeline_steps.R step 06. Tags each row with
# is_mm_adjacent_override; the exclusion scan reads only the 0 rows, while the
# QC card reads all rows so the overridden groups stay visible.
#
# Logs how many expected override labels matched: a partial match means the
# stored labels differ from LOT1_MM_ADJACENT_OVERRIDE and the override is a
# silent no-op for the unmatched groups (run-review blocker).
build_lot1_other_malig_codes <- function(con) {
  src <- load_codelist_csv("other_malig.csv", c("dx", "icd_family", "tumor_group"))
  ovr_in <- paste(sprintf("'%s'", gsub("'", "''", LOT1_MM_ADJACENT_OVERRIDE)),
                  collapse = ", ")
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {LOT1_OTHER_MALIG_CODES} AS
    SELECT
      upper(tumor_group) AS tumor_group,
      CASE WHEN upper(icd_family) IN ('9','ICD9','ICD-9','ICD9DIAG') THEN 'ICD9' ELSE 'ICD10' END AS icd_family,
      upper(regexp_replace(trim(dx), '[^A-Za-z0-9]', '')) AS dx,
      CASE WHEN upper(trim(tumor_group)) IN ({ovr_in}) THEN 1 ELSE 0 END AS is_mm_adjacent_override
    FROM {src}
    WHERE dx IS NOT NULL AND tumor_group IS NOT NULL
  "))
  n_exp     <- length(LOT1_MM_ADJACENT_OVERRIDE)
  n_matched <- tryCatch(as.integer(db_q(con, glue("
    SELECT count(DISTINCT tumor_group) AS n
    FROM {LOT1_OTHER_MALIG_CODES}
    WHERE is_mm_adjacent_override = 1
  "))$n), error = function(e) NA_integer_)
  log_msg("  LOT1 other-cancer override: matched ",
          if (is.na(n_matched)) "?" else n_matched, " of ", n_exp,
          " expected MM-adjacent tumor_group labels",
          if (is.na(n_matched) || n_matched < n_exp)
            paste0(" - WARNING: < expected. Inspect 'SELECT DISTINCT ",
                   "tumor_group FROM ", LOT1_OTHER_MALIG_CODES, "' on the ",
                   "warehouse and align LOT1_MM_ADJACENT_OVERRIDE to the ",
                   "stored labels before trusting the count.")
          else "")
  invisible(n_matched)
}

# Claim-header + confinement views for IP/OP classification. Mirror of steps
# 07a/07b, with a wider lower bound so the pre-LOT1 baseline (which reaches back
# to LOT1_FROM - LOT1_PRE_DAYS) is fully visible.
build_lot1_med_claim_header_and_confinement <- function(con, medical_tbl,
                                                        confinement_tbl) {
  lower <- glue("date_sub(date('{LOT1_FROM}'), {LOT1_PRE_DAYS})")
  upper <- glue("date('{cfg$study_end}')")
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {LOT1_MED_CLAIM_HEADER} AS
    SELECT PATID, PAT_PLANID, CLMID, FST_DT, LOC_CD,
           max(CONF_ID) AS CONF_ID,
           max(POS)     AS POS,
           max(TOS_CD)  AS TOS_CD
    FROM {medical_tbl}
    WHERE FST_DT BETWEEN {lower} AND {upper}
    GROUP BY PATID, PAT_PLANID, CLMID, FST_DT, LOC_CD
  "))
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {LOT1_CONFINEMENT} AS
    SELECT DISTINCT PATID, CONF_ID,
           cast(ADMIT_DATE as date) AS ADMIT_DATE,
           cast(DISCH_DATE as date) AS DISCH_DATE
    FROM {confinement_tbl}
    WHERE CONF_ID IS NOT NULL
      AND ADMIT_DATE IS NOT NULL
      AND DISCH_DATE IS NOT NULL
  "))
}

# Another active cancer in [LOT1_START - LOT1_PRE_DAYS, LOT1_START - 1].
# Re-anchored from step 22 (which uses [INDEX_DATE - 183, INDEX_DATE - 1]);
# the logic is identical:
#   Path A: >=1 inpatient claim for a tumor group in baseline
#   Path B: >=2 outpatient claims on separate days within 30d for the SAME
#           tumor group, where the FIRST falls in baseline (the second may fall
#           after LOT1 start, matching the parent)
# Index-DEPENDENT -> keyed by the pair.
build_lot1_other_malig_pre <- function(con, med_diag_tbl) {
  lower <- glue("date_sub(date('{LOT1_FROM}'), {LOT1_PRE_DAYS})")
  upper <- glue("date('{cfg$study_end}')")
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {LOT1_OTHER_MALIG_PATIDS} AS
    WITH dx AS (
      SELECT d.PATID, d.PAT_PLANID, d.CLMID, d.FST_DT, d.LOC_CD,
             cast(d.FST_DT as date) AS event_dt,
             upper(regexp_replace(d.DIAG, '[^A-Za-z0-9]', '')) AS dx,
             CASE WHEN upper(d.ICD_FLAG) IN ('9','ICD9','ICD-9') THEN 'ICD9' ELSE 'ICD10' END AS icd_family
      FROM {med_diag_tbl} d
      WHERE FST_DT BETWEEN {lower} AND {upper}
    ),
    dx_mapped AS (
      -- is_mm_adjacent_override = 0 only: the plasma-cell / MM-adjacent tumor
      -- groups are NOT exclusionary here. The QC card scans the same codelist
      -- WITHOUT this predicate so the overridden groups still show.
      SELECT /*+ BROADCAST(o) */
             dx.PATID, dx.PAT_PLANID, dx.CLMID, dx.FST_DT, dx.LOC_CD,
             dx.event_dt, o.tumor_group
      FROM dx
      INNER JOIN {LOT1_OTHER_MALIG_CODES} o
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
      INNER JOIN {LOT1_MED_CLAIM_HEADER} h
            ON dm.PATID      =   h.PATID
           AND dm.CLMID      =   h.CLMID
           AND dm.FST_DT     =   h.FST_DT
           AND dm.PAT_PLANID <=> h.PAT_PLANID
           AND dm.LOC_CD     <=> h.LOC_CD
      LEFT JOIN {LOT1_CONFINEMENT} cf
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
      SELECT cast(PATID as string) AS PATID, INDEX_DATE, LOT1_START_DT,
             date_sub(LOT1_START_DT, {LOT1_PRE_DAYS}) AS pre_lot1_start,
             date_sub(LOT1_START_DT, 1)               AS pre_lot1_end
      FROM {LOT1_STARTS}
    ),
    hits AS (
      SELECT DISTINCT l1.PATID, l1.INDEX_DATE
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
    SELECT PATID, INDEX_DATE FROM hits
  "))
}

# =============================================================================
# Pregnancy
# =============================================================================
# Re-scanned from pregnancy.csv over the study period rather than carried from
# the index-anchored PREGNANT_FLAG, so it is self-contained and uses the
# any-time-in-study-period window.
build_lot1_preg_codes <- function(con) {
  src <- load_codelist_csv("pregnancy.csv", c("code_type", "code"))
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {LOT1_PREG_CODES} AS
    SELECT upper(trim(code_type)) AS code_type,
           upper(regexp_replace(trim(code), '[^A-Za-z0-9]', '')) AS code
    FROM {src}
    WHERE code IS NOT NULL AND trim(code) <> ''
      AND code_type IS NOT NULL AND trim(code_type) <> ''
  "))
}

# Distinct candidate PATIDs with a pregnancy/childbirth claim (dx, HCPCS / ICD
# procedure, or revenue code) anywhere in the study period.
#
# Index-INDEPENDENT: the window is the whole study period, not a LOT1-relative
# one, so the answer is identical for every index a patient could have. Kept at
# PATID grain deliberately -- adding INDEX_DATE would only duplicate rows.
#
# Two scheduling-only optimisations, preserved from the original (the matched
# PATID set is identical):
#   1) restrict every source to LOT1 candidates up front instead of only at the
#      end; the trailing join is kept as a belt-and-braces no-op
#   2) scan `medical` ONCE -- stack() emits its HCPCS (PROC_CD) and REV
#      (RVNU_CD) rows in a single pass. The per-arm CASE reproduces the original
#      inclusion rules exactly (HCPCS keeps a blank-after-clean code, REV drops
#      blanks), and a blank code never matches a real pregnancy code.
build_lot1_pregnancy_patids <- function(con, med_diag_tbl, medical_tbl, med_proc_tbl) {
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {LOT1_PREGNANCY_PATIDS} AS
    WITH cand AS (
      SELECT DISTINCT PATID FROM {LOT1_STARTS}
    ),
    dx AS (
      SELECT cast(d.PATID as string) AS PATID,
             CASE WHEN upper(d.ICD_FLAG) IN ('9','ICD9','ICD-9') THEN 'ICD9DIAG' ELSE 'ICD10DIAG' END AS code_type,
             upper(regexp_replace(d.DIAG, '[^A-Za-z0-9]', '')) AS code
      FROM {med_diag_tbl} d
      INNER JOIN cand l1 ON cast(d.PATID as string) = l1.PATID
      WHERE d.DIAG IS NOT NULL
        AND cast(d.FST_DT as date) BETWEEN date('{LOT1_STUDY_START}') AND date('{cfg$study_end}')
    ),
    med AS (
      SELECT s.PATID, t.code_type, t.code
      FROM (
        SELECT cast(m.PATID as string) AS PATID, m.PROC_CD, m.RVNU_CD
        FROM {medical_tbl} m
        INNER JOIN cand l1 ON cast(m.PATID as string) = l1.PATID
        WHERE cast(m.FST_DT as date) BETWEEN date('{LOT1_STUDY_START}') AND date('{cfg$study_end}')
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
      INNER JOIN cand l1 ON cast(p.PATID as string) = l1.PATID
      WHERE p.PROC IS NOT NULL
        AND cast(p.FST_DT as date) BETWEEN date('{LOT1_STUDY_START}') AND date('{cfg$study_end}')
    ),
    events AS (
      SELECT * FROM dx
      UNION ALL SELECT * FROM med
      UNION ALL SELECT * FROM icd_proc
    ),
    matched AS (
      SELECT DISTINCT e.PATID
      FROM events e
      INNER JOIN {LOT1_PREG_CODES} p
              ON e.code_type = p.code_type AND e.code = p.code
    )
    SELECT DISTINCT m.PATID
    FROM matched m
    INNER JOIN cand l1 ON m.PATID = l1.PATID
  "))
}

# =============================================================================
# The flag table
# =============================================================================
# One row per (PATID, INDEX_DATE) LOT1 candidate, one 0/1 column per criterion.
# NOTHING IS FILTERED HERE -- the WHERE ... = 1 that used to follow now lives in
# the cohort spec ("Jul 28"/cohorts/*.R), which is what lets one flag build
# serve any number of cohorts.
#
#   CE_pre_lot1_12mo          >=1 enrollment span covers
#                             [LOT1_START - LOT1_PRE_DAYS, LOT1_START - 1]
#                             (same gap semantics as CE_b/CE_f)
#   CE_lot1_3mo_fu            a NO-GAP span covers [LOT1_START,
#                             least(LOT1_START + 90, study_end, death)]
#   NO_BELANTAMAB             no MAP_STACKED row with MAP_MED_TYPE LIKE 'BEL%'
#   NO_PRIOR_MM_TX            no row in the pre-LOT1 therapy scan
#   NO_OTHER_CANCER_PRE_LOT1  no row in the pre-LOT1 other-malignancy scan
#   NO_PREGNANCY              no row in the study-period pregnancy scan
#
# A filter whose source table is unavailable is SKIPPED: its q2_ok_* argument is
# FALSE, the corresponding CTE becomes an empty set, and the flag passes every
# patient. The caller reports the skip.
build_lot1_flags <- function(con, patient_input, map_stacked,
                             q2_ok_belantamab, q2_ok_priortx,
                             q2_ok_othercancer, q2_ok_pregnancy = NULL) {
  if (is.null(q2_ok_pregnancy))
    q2_ok_pregnancy <- .lot1_table_ok(con, LOT1_PREGNANCY_PATIDS)

  none_pair <- "SELECT cast(NULL as string) AS PATID, cast(NULL as date) AS INDEX_DATE WHERE 1 = 0"
  none_pid  <- "SELECT cast(NULL as string) AS PATID WHERE 1 = 0"

  bela_expr <- if (q2_ok_belantamab) glue("
        SELECT DISTINCT cast(PATID as string) AS PATID
        FROM {map_stacked}
        WHERE upper(MAP_MED_TYPE) LIKE 'BEL%'
  ") else none_pid

  prior_tx_expr <- if (q2_ok_priortx) glue("
        SELECT DISTINCT PATID, INDEX_DATE FROM {LOT1_THERAPY_PRE}
  ") else none_pair

  other_cancer_expr <- if (q2_ok_othercancer) glue("
        SELECT DISTINCT cast(PATID as string) AS PATID, INDEX_DATE
        FROM {LOT1_OTHER_MALIG_PATIDS}
  ") else none_pair

  pregnancy_expr <- if (q2_ok_pregnancy) glue("
        SELECT DISTINCT cast(PATID as string) AS PATID FROM {LOT1_PREGNANCY_PATIDS}
  ") else none_pid

  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {LOT1_FLAGS_ALL} AS
    WITH ec_l1 AS (
      SELECT cast(p.PATID as string) AS PATID,
             cast(p.INDEX_DATE as date) AS INDEX_DATE,
             l1.LOT1_START_DT,
             date_sub(l1.LOT1_START_DT, {LOT1_PRE_DAYS}) AS pre_lot1_start,
             date_sub(l1.LOT1_START_DT, 1)               AS pre_lot1_end,
             -- DEATH_DT carried from the patient input so the 3-month follow-up
             -- CE below can be re-derived ANCHORED AT LOT1. The index-anchored
             -- CE_3mosf is NOT reused for it -- different anchor, different
             -- criterion.
             cast(p.DEATH_DT as date) AS DEATH_DT
      FROM {patient_input} p
      INNER JOIN {LOT1_STARTS} l1
              ON cast(p.PATID as string) = l1.PATID
             AND cast(p.INDEX_DATE as date) = l1.INDEX_DATE
    ),
    ce AS (
      SELECT ec_l1.PATID, ec_l1.INDEX_DATE,
             max(CASE WHEN s.cov_start <= ec_l1.pre_lot1_start
                       AND s.cov_end   >= ec_l1.pre_lot1_end
                      THEN 1 ELSE 0 END) AS CE_pre_lot1_12mo
      FROM ec_l1
      LEFT JOIN {LOT1_ENROLL_SPANS} s ON s.PATID = ec_l1.PATID
      GROUP BY ec_l1.PATID, ec_l1.INDEX_DATE
    ),
    -- 3-month follow-up CE re-derived ANCHORED AT LOT1: a span must cover
    -- [LOT1_START, least(LOT1_START + 90, study_end, death)]. Uses the STRICT
    -- (no-gap) spans -- 'no gaps in enrollment' for the follow-up CE, vs
    -- <30-day gaps allowed for the 12-mo pre-LOT1 CE.
    fuce AS (
      SELECT ec_l1.PATID, ec_l1.INDEX_DATE,
             max(CASE WHEN s.cov_start <= ec_l1.LOT1_START_DT
                       AND s.cov_end   >= least(date_add(ec_l1.LOT1_START_DT, 90),
                                                date('{cfg$study_end}'),
                                                coalesce(ec_l1.DEATH_DT, date('{cfg$study_end}')))
                      THEN 1 ELSE 0 END) AS CE_lot1_3mo
      FROM ec_l1
      LEFT JOIN {LOT1_ENROLL_SPANS_STRICT} s ON s.PATID = ec_l1.PATID
      GROUP BY ec_l1.PATID, ec_l1.INDEX_DATE
    ),
    bela AS ({bela_expr}),
    prior_tx AS ({prior_tx_expr}),
    other_cancer AS ({other_cancer_expr}),
    pregnancy AS ({pregnancy_expr})
    SELECT ec_l1.PATID,
           ec_l1.INDEX_DATE,
           ec_l1.LOT1_START_DT,
           ce.CE_pre_lot1_12mo,
           coalesce(fuce.CE_lot1_3mo, 0)                          AS CE_lot1_3mo_fu,
           CASE WHEN bela.PATID         IS NULL THEN 1 ELSE 0 END AS NO_BELANTAMAB,
           CASE WHEN prior_tx.PATID     IS NULL THEN 1 ELSE 0 END AS NO_PRIOR_MM_TX,
           CASE WHEN other_cancer.PATID IS NULL THEN 1 ELSE 0 END AS NO_OTHER_CANCER_PRE_LOT1,
           CASE WHEN pregnancy.PATID    IS NULL THEN 1 ELSE 0 END AS NO_PREGNANCY
    FROM ec_l1
    LEFT JOIN ce           ON ec_l1.PATID = ce.PATID   AND ec_l1.INDEX_DATE = ce.INDEX_DATE
    LEFT JOIN fuce         ON ec_l1.PATID = fuce.PATID AND ec_l1.INDEX_DATE = fuce.INDEX_DATE
    -- belantamab and pregnancy are index-INDEPENDENT (any line / whole study
    -- period), so they join on PATID alone. The two pre-LOT1 window scans are
    -- index-DEPENDENT and join on the pair.
    LEFT JOIN bela         ON ec_l1.PATID = bela.PATID
    LEFT JOIN prior_tx     ON ec_l1.PATID = prior_tx.PATID
                          AND ec_l1.INDEX_DATE = prior_tx.INDEX_DATE
    LEFT JOIN other_cancer ON ec_l1.PATID = other_cancer.PATID
                          AND ec_l1.INDEX_DATE = other_cancer.INDEX_DATE
    LEFT JOIN pregnancy    ON ec_l1.PATID = pregnancy.PATID
  "))
}

# Materialize the flag table and the LOT1 starts, then repoint the temp views at
# the physical tables.
#
# As bare TEMPORARY VIEWs these re-run the whole scan DAG (pregnancy +
# belantamab + prior-Tx + other-cancer over the study period, plus both
# enrollment-span builds) on EVERY read -- and they are read heavily. That
# repeated recomputation is what made the NDMM stage appear to hang. Mirrors the
# S16 materialize-and-repoint in 02_lot1.R; CACHE TABLE is not available on SQL
# warehouses.
#
# Not gated on cfg$persist_to_schema, which governs the FINAL persist rather
# than intermediate work-schema materializations -- same as S16.
#
# Fail-safe: if the CREATE TABLE is refused (e.g. a read-only work schema) WARN
# and keep the in-place temp views. Downstream numbers stay correct, just slower.
# ORDER MATTERS. A repoint only affects views defined AFTER it -- a temp view's
# plan is bound when it is created, so repointing LOT1_STARTS once the flag view
# already references it would leave that view on the old plan. So:
#
#   build_lot1_starts()            -> materialize_lot1_starts()   <- HERE
#   ... the four claim scans ...                                     (they read
#   build_lot1_flags()                                                LOT1_STARTS
#   materialize_lot1_flags()                                          many times)
#
# Materializing starts first is also the bigger win: every scan joins it.
.materialize_and_repoint <- function(con, view, tbl, run_step_fn) {
  tryCatch({
    sql <- glue("CREATE OR REPLACE TABLE {wrk(tbl)} AS SELECT * FROM {view}")
    qc  <- glue("SELECT count(*) AS n_rows FROM {wrk(tbl)}")
    if (is.null(run_step_fn)) db_exec(con, sql)
    else run_step_fn(con, paste0("S_lot1_materialize_", tolower(tbl)), sql, qc = qc)
    db_exec(con, glue(
      "CREATE OR REPLACE TEMPORARY VIEW {view} AS SELECT * FROM {wrk(tbl)}"))
    TRUE
  }, error = function(e) {
    log_msg("WARN: could not materialize ", wrk(tbl), " (", conditionMessage(e),
            "); keeping the in-place temp view - counts stay correct but run ",
            "slower (scans recomputed on each read).")
    FALSE
  })
}

materialize_lot1_starts <- function(con, run_step_fn = NULL)
  .materialize_and_repoint(con, LOT1_STARTS, LOT1_STARTS_TBL, run_step_fn)

materialize_lot1_flags <- function(con, run_step_fn = NULL)
  .materialize_and_repoint(con, LOT1_FLAGS_ALL, LOT1_FLAGS_ALL_TBL, run_step_fn)
