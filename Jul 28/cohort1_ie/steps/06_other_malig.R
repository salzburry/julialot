# =============================================================================
# 06_other_malig.R -- IE Step 8: no other active cancer
# -----------------------------------------------------------------------------
#   Step 8  OTHER_MALIGN_FLAG = 0
#
# THE RULE, per tumour group, in baseline:
#   Path A  >=1 INPATIENT claim for that tumour group, or
#   Path B  >=2 OUTPATIENT claims for that tumour group within 30 days of each
#           other, the FIRST of which is in baseline.
#
# Same 1-IP-or-2-OP shape as Step 1, with three differences that all matter:
#
#   1. PER TUMOUR GROUP. The pair in Path B must be the SAME tumour group -- the
#      window partitions by (PATID, tumour_group). Two outpatient claims for two
#      different cancers do not confirm either one.
#
#   2. A FIXED 30-DAY WINDOW, hardcoded, NOT OUTPATIENT_WINDOW. Setting the
#      outpatient window to 60 or 90 changes Step 1 and leaves Step 8 at 30.
#
#   3. THE CONFIRMING CLAIM MAY FALL AFTER INDEX. Only `first_dt` has to be in
#      baseline; the second claim of the pair just has to be within 30 days of
#      it. So a patient can be excluded on the strength of a claim that post-
#      dates their index date. That is the study's intent -- the pair confirms a
#      cancer that was already present in baseline -- but it means Step 8 is not
#      purely a baseline-window criterion, unlike Steps 5 and 7.
#
# The exclusion joins on the DIAGNOSIS CODE (dx.dx = o.dx AND matching ICD
# family). `tumor_group` is a LABEL carried on the matched rows and used to
# partition the pair logic -- patients are excluded by code, grouped by label.
#
# Inpatient/outpatient classification is the same Approach 1 + 2 as Step 1,
# re-derived here off the same 5-column claim key, so the two steps cannot
# disagree about what an inpatient claim is.
#
# CONFIGURED OFF (APPLY_OTHER_MALIG_EXCL=FALSE), and this one is not a
# preference. The NDMM cohort re-applies other-malignancy at the LOT1 anchor with
# an MM-ADJACENT OVERRIDE that keeps five tumour groups (MGUS, secondary bone,
# solitary / extramedullary plasmacytoma, plasma-cell leukaemia). Turning it on
# here drops those patients upstream, before NDMM can put them back, and breaks
# the NDMM cohort. The consequence for cohort 1 is stated plainly in
# pipeline_inputs.csv: with FALSE, Overall has NO other-malignancy exclusion.
# =============================================================================

ie_step_other_malig <- function(cfg, h) {
  work <- h$work; cdm_src <- h$cdm_src

  views <- list(
    ie_view(
      name = "other_malig_flag",
      legacy = "22_other_malig_flag",
      description = "EXCLUSION: Other malignancy flag (>=1 IP or >=2 OP within 30d)",
      source_tables = c("med_diagnosis", "medical", "confinement"),
      sql = fmt("
        CREATE OR REPLACE TEMPORARY VIEW {work('other_malig_flag')} AS
        WITH dx AS (
          -- Carry the full 5-column claim key so dx_with_setting can join
          -- med_claim_header on the same grain (see step 07a comment).
          SELECT d.PATID, d.PAT_PLANID, d.CLMID, d.FST_DT, d.LOC_CD,
                 cast(d.FST_DT as date) AS event_dt,
                 upper(regexp_replace(d.DIAG, '[^A-Za-z0-9]', '')) AS dx,
                 CASE WHEN upper(d.ICD_FLAG) IN ('9','ICD9','ICD-9') THEN 'ICD9' ELSE 'ICD10' END AS icd_family
          FROM {cdm_src(cfg$tbl_med_diag)} d
          WHERE FST_DT BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
        ),
        dx_mapped AS (
          SELECT /*+ BROADCAST(o) */
                 dx.PATID, dx.PAT_PLANID, dx.CLMID, dx.FST_DT, dx.LOC_CD,
                 dx.event_dt, o.tumor_group
          FROM dx
          INNER JOIN {work('other_malig_codes')} o ON dx.dx = o.dx AND dx.icd_family = o.icd_family
        ),
        -- Classify inpatient vs outpatient using same Approach 1+2 as MM qualifying
        dx_with_setting AS (
          SELECT dm.PATID, dm.CLMID, dm.event_dt, dm.tumor_group,
                 CASE WHEN h.POS IN ('21', '51', '61')
                        OR h.TOS_CD IN ('FAC_IP.ACUTE', 'FAC_IP.REHSNF', 'PROF.INPVIS', 'FAC_IP.SNF')
                        OR cf.CONF_ID IS NOT NULL
                      THEN 1 ELSE 0 END AS inpatient_flg
          FROM dx_mapped dm
          INNER JOIN {work('med_claim_header')} h
            -- Null-safe on PAT_PLANID / LOC_CD; see comment in step 08a.
            ON dm.PATID      =   h.PATID
           AND dm.CLMID      =   h.CLMID
           AND dm.FST_DT     =   h.FST_DT
           AND dm.PAT_PLANID <=> h.PAT_PLANID
           AND dm.LOC_CD     <=> h.LOC_CD
          LEFT JOIN {work('confinement')} cf
            ON h.PATID = cf.PATID AND h.CONF_ID = cf.CONF_ID
        ),
        -- Path A: >=1 inpatient claim for a tumor group in baseline
        inpatient_flag AS (
          SELECT DISTINCT PATID, tumor_group, event_dt
          FROM dx_with_setting
          WHERE inpatient_flg = 1
        ),
        -- Path B: >=2 outpatient claims on separate days within 30 days
        outpatient_dates AS (
          SELECT DISTINCT PATID, tumor_group, event_dt
          FROM dx_with_setting
          WHERE inpatient_flg = 0
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
        )
        SELECT
          q.PATID,
          q.index_date,
          -- >=1 inpatient OR >=2 outpatient within 30d, same tumor group, in baseline
          max(CASE
            -- Path A: single inpatient claim in baseline
            WHEN ip.event_dt BETWEEN date_sub(q.index_date, {cfg$baseline_days})
                                 AND date_sub(q.index_date, 1)
            THEN 1
            -- Path B: 2 outpatient claims within 30d, first in baseline
            -- Only the first of the 2 codes
            -- is required to occur inside the baseline period. The confirming
            -- second claim may fall after index, as long as the pair is
            -- within 30 days of each other.
            WHEN op.diff_days <= 30
              AND op.first_dt BETWEEN date_sub(q.index_date, {cfg$baseline_days})
                                  AND date_sub(q.index_date, 1)
            THEN 1
            ELSE 0
          END) AS OTHER_MALIGN_FLAG
        FROM {work('mm_qualifying')} q
        LEFT JOIN inpatient_flag ip ON q.PATID = ip.PATID
        LEFT JOIN outpatient_pairs op ON q.PATID = op.PATID
        GROUP BY q.PATID, q.index_date
      "),
      qc = fmt("SELECT sum(OTHER_MALIGN_FLAG) AS n_other_malig FROM {work('other_malig_flag')}")
    )
  )

  criteria <- list(
    ie_criterion(
      step = 8L,
      id = "no_other_cancer",
      attrition_id = "08_step8_other_cancer",
      label = "Step 8: Other cancer (excl)",
      flag_col = "OTHER_MALIGN_FLAG",
      predicate = "OTHER_MALIGN_FLAG = 0",
      cfg_key = "apply_other_malig_excl",
      polarity = "exclude",
      note = paste("Fixed 30d pair window, NOT OUTPATIENT_WINDOW.",
                   "Ships OFF by design so NDMM can re-apply it at LOT1 with",
                   "the MM-adjacent override; see the file header.")
    )
  )

  list(views = views, criteria = criteria)
}
