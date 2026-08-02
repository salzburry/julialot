# Another active cancer in the 12 months before LOT1.
#

build_ndmm_other_malig_codes <- function(con) {
  src <- load_codelist_csv(
    "other_malig.csv",
    c("dx", "icd_family", "tumor_group"))
  met_pred <- ndmm_metastatic_sql("om.dx")
  ovr_in <- paste(sprintf("'%s'", gsub("'", "''", ndmm_mm_adjacent_groups())),
                  collapse = ", ")
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_OTHER_MALIG_CODES} AS
    -- Normalised first, then joined. Every column reference below is
    -- qualified, and both sides of the join are already normalised, so no name
    -- can bind to the wrong relation.
    --
    -- This was a correlated EXISTS whose inner relation carries columns called
    -- dx and icd_family too. Unqualified, those bound to the inner ones, the
    -- predicate compared each MM code to itself, and every other-cancer code
    -- came back overridden - which switched the whole exclusion off.
    WITH om AS (
      SELECT upper(tumor_group) AS tumor_group,
             CASE WHEN upper(icd_family) IN ('9','ICD9','ICD-9','ICD9DIAG') THEN 'ICD9' ELSE 'ICD10' END AS icd_family,
             upper(regexp_replace(trim(dx), '[^A-Za-z0-9]', '')) AS dx
      FROM {src}
      WHERE dx IS NOT NULL AND tumor_group IS NOT NULL
        -- And non-blank once normalised: '---' would otherwise match every
        -- diagnosis claim with a missing code. See 03_prior_therapy.R.
        AND regexp_replace(trim(dx), '[^A-Za-z0-9]', '') <> ''
    )
    SELECT om.tumor_group,
           om.icd_family,
           om.dx,
           -- The criterion is another cancer, meaning other than the index MM,
           -- and this code list is the study's generic one: it carries MM's
           -- own codes. Anything on the diagnosis code list is the index
           -- disease by definition - the same file decides who is an MM
           -- patient - so it cannot also make them an other-cancer patient,
           -- whatever its wording says about remission or relapse. The label
           -- list covers what is adjacent to MM without being on it.
           --
           -- The label is per code here: other_malig.csv carries 1,618
           -- distinct tumor_group values over 1,643 codes, so naming a label
           -- in NDMM_MM_ADJACENT_OVERRIDE picks out a code. That is why there
           -- is no separate per-code file - there is nothing it could say that
           -- the label list cannot. C79.51 and C79.52 are different labels and
           -- are decided separately; see DECISIONS.md.
           CASE WHEN trim(om.tumor_group) IN ({ovr_in}) OR m.dx IS NOT NULL
                THEN 1 ELSE 0 END AS is_mm_adjacent_override,
           -- The group two outpatient claims must share to confirm each other.
           -- The rule is about the same primary tumour type, and the ICD
           -- category - the first three characters - is that: every C50.x is
           -- breast, every C34.x lung, every C79.x a secondary neoplasm, which
           -- is the and/or-metastatic-cancer half of the same sentence. The
           -- label cannot do this: other_malig.csv carries 1,618 of them over
           -- 1,643 codes, so pairing on it means pairing on the identical code
           -- and one cancer written two ways never confirms itself.
           --
           -- dx is already punctuation-stripped, so this is C7951 -> C79 and
           -- 1985 -> 198. ICD-10 always starts with a letter and ICD-9 never
           -- does, so the two families cannot collide in one group.
           CASE WHEN {met_pred} THEN 'MET'
                ELSE substr(om.dx, 1, 3) END AS primary_group,
           -- The same without the metastatic collapse, carried only so
           -- NDMM_OTHER_MALIG_GRAIN can price what that collapse costs.
           substr(om.dx, 1, 3) AS category_group
    FROM om
    LEFT JOIN {NDMM_MM_DX_CODES} m
           ON m.dx = om.dx AND m.icd_family = om.icd_family
  "))
  report_metastatic_group(con)

  # Only the five required labels are counted. The remission variants are a
  # proposal, not a contract with the code list, so their absence is reported
  # rather than fatal - see build_ndmm_mm_adjacent_groups().
  req    <- gsub("'", "''", NDMM_MM_ADJACENT_OVERRIDE)
  req_in <- paste(sprintf("'%s'", req), collapse = ", ")
  n_exp     <- length(NDMM_MM_ADJACENT_OVERRIDE)
  n_matched <- tryCatch(as.integer(db_q(con, glue("
    SELECT count(DISTINCT tumor_group) AS n
    FROM {NDMM_OTHER_MALIG_CODES}
    WHERE is_mm_adjacent_override = 1
      AND upper(trim(tumor_group)) IN ({req_in})
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

# Claim-header view for telling inpatient from outpatient on other-cancer
# diagnoses. The lower bound reaches back a year before NDMM_LOT1_FROM so the
# whole baseline window is visible; the upper bound is study_end.
build_ndmm_med_claim_header_and_confinement <- function(con, medical_tbl,
                                                      confinement_tbl) {
  lower <- glue("date_sub(date('{NDMM_LOT1_FROM}'), {NDMM_PRE_LOT1_DAYS})")
  upper <- glue("date('{cfg$study_end}')")
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_MED_CLAIM_HEADER} AS
    -- Flag each line before max(POS) can hide an inpatient code. A claim with
    -- an inpatient line (POS 21) and a lexically larger non-inpatient one (81)
    -- has max(POS) = 81, so classifying from the maxima alone reads it as
    -- outpatient. One inpatient other-cancer claim excludes on its own, while
    -- an outpatient one needs a second within 30 days - so that patient stayed
    -- in the cohort. 00_mm_cohort.R has always done this; this view did not.
    SELECT PATID, PAT_PLANID, CLMID, FST_DT, LOC_CD,
           max(CONF_ID) AS CONF_ID,
           max(POS)     AS POS,
           max(TOS_CD)  AS TOS_CD,
           max(CASE WHEN POS IN ('21', '51', '61')
                      OR TOS_CD IN ('FAC_IP.ACUTE', 'FAC_IP.REHSNF', 'PROF.INPVIS', 'FAC_IP.SNF')
                    THEN 1 ELSE 0 END) AS line_inpatient
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

# Patients with another active cancer in [LOT1_START - 365, LOT1_START - 1].
# Two ways to qualify:
#
#   - one inpatient claim for a tumour group inside the window, or
#   - two outpatient claims on different days within 30d for the same tumour
#     group, both inside the window
#
# Tumour-group grain is kept end to end, so two different cancers do not
# combine into one.
build_ndmm_other_malig_pre_lot1 <- function(con, med_diag_tbl) {
  lower <- glue("date_sub(date('{NDMM_LOT1_FROM}'), {NDMM_PRE_LOT1_DAYS})")
  upper <- glue("date('{cfg$study_end}')")
  # The claim scan is split out from the rule it feeds. It reads med_diagnosis
  # over the whole baseline window and joins the claim header and confinement,
  # which is the expensive part of this file; the rule over it is arithmetic.
  # Separated so NDMM_OTHER_MALIG_GRAIN can ask what the grouping grain costs
  # without scanning the claims a second time.
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_OTHER_MALIG_EVENTS} AS
    WITH dx AS (
      SELECT d.PATID, d.PAT_PLANID, d.CLMID, d.FST_DT, d.LOC_CD,
             cast(d.FST_DT as date) AS event_dt,
             upper(regexp_replace(d.DIAG, '[^A-Za-z0-9]', '')) AS dx,
             {icd_family_sql('d.ICD_FLAG')} AS icd_family
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
             dx.event_dt, o.tumor_group, o.primary_group, o.category_group
      FROM dx
      INNER JOIN {NDMM_OTHER_MALIG_CODES} o
              ON dx.dx = o.dx AND dx.icd_family = o.icd_family
             AND o.is_mm_adjacent_override = 0
    ),
    dx_with_setting AS (
      SELECT dm.PATID, dm.CLMID, dm.event_dt, dm.tumor_group, dm.primary_group,
             dm.category_group,
             -- line_inpatient is 0/1, so a missing POS/TOS stays null-safe.
             CASE WHEN h.line_inpatient = 1 OR cf.CONF_ID IS NOT NULL
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
    )
    SELECT PATID, tumor_group, primary_group, category_group, event_dt,
           inpatient_flg
    FROM dx_with_setting"))

  # The rule, over that. Path B pairs on primary_group - the ICD category -
  # not on tumor_group. Two outpatient claims for one cancer coded at different
  # subsites, or one \"in remission\" and one \"not having achieved remission\",
  # are one primary tumour type and now confirm each other. Pairing on the
  # label, as the source does, means pairing on the identical code.
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW {NDMM_OTHER_MALIG_PATIDS} AS
    WITH inpatient_flag AS (
      SELECT DISTINCT PATID, primary_group AS grp, event_dt
      FROM {NDMM_OTHER_MALIG_EVENTS} WHERE inpatient_flg = 1
    ),
    outpatient_dates AS (
      SELECT DISTINCT PATID, primary_group AS grp, event_dt
      FROM {NDMM_OTHER_MALIG_EVENTS} WHERE inpatient_flg = 0
    ),
    with_next AS (
      SELECT PATID, grp, event_dt,
             lead(event_dt) OVER (PARTITION BY PATID, grp ORDER BY event_dt) AS next_dt
      FROM outpatient_dates
    ),
    outpatient_pairs AS (
      SELECT PATID, grp, event_dt AS first_dt, next_dt,
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
            -- Both claims in the baseline, not just the first. The source
            -- bounded first_dt alone, so a claim the day before the index and
            -- its confirmation a month after it excluded the patient on one
            -- baseline claim - and the criterion is other cancer IN the 1L
            -- baseline. next_dt is always after first_dt, so the lower bound
            -- is redundant; it is written out so the pair reads as a pair.
            AND op.next_dt  BETWEEN l1.pre_lot1_start AND l1.pre_lot1_end
      WHERE ip.PATID IS NOT NULL OR op.PATID IS NOT NULL
    )
    SELECT PATID FROM hits
  "))
}

# One row per patient, carrying the six filter flags. Restricted to patients
# who have a 1L treatment starting on or after NDMM_LOT1_FROM. Flags:
#
#   CE_pre_lot1_12mo        : an enrollment span covers
#                             [LOT1_START - NDMM_PRE_LOT1_DAYS, LOT1_START - 1]
#
#   NO_BELANTAMAB           : no belantamab row for the patient. Drug only, not
#                             the wider BCMA class - the exclusion names the
#                             one drug.
#
#   NO_PRIOR_MM_TX          : no row in NDMM_THERAPY_PRE_LOT1, the four-source
#                             raw-claim scan over the baseline window.
#
#   NO_OTHER_CANCER_PRE_LOT1: no row in NDMM_OTHER_MALIG_PATIDS - another
#                             active cancer during the baseline.
#
#   CE_lot1_fu              : a no-gap span covers [LOT1_START, least(LOT1_START
#                             + NDMM_FU_CE_DAYS, study_end, death)].
#                             NDMM_FU_CE_DAYS is 0 here - one day, the index
#                             date itself. See README.
#
#   NO_PREGNANCY            : no pregnancy code - diagnosis, HCPCS, ICD
#                             procedure or revenue - anywhere in the study
#                             period.
# Readability probe used by the pregnancy gate (the scan view may not exist
# if its source claims tables are unavailable).
.ndmm_table_ok <- function(con, tbl) isTRUE(tryCatch(
  nrow(db_q(con, glue("SELECT 1 FROM {tbl} LIMIT 1"))) >= 0,
  error = function(e) FALSE))

# Pregnancy exclusion, read straight from pregnancy.csv over the study period.
# Self-contained, so it depends on no other build.
