# =============================================================================
# 06_other_malig.R -- step 8: no other active cancer
# -----------------------------------------------------------------------------
#   step 8  OTHER_MALIGN_FLAG = 0
#
# Per tumour group, in baseline: >=1 inpatient claim, or >=2 outpatient claims
# within 30 days of each other, the first of them in baseline.
#
# Same 1-IP-or-2-OP shape as step 1, with four differences that matter:
#
#   1. Per tumour group. The pair must be the same group -- the window partitions
#      by (PATID, tumor_group). Two claims for two different cancers confirm
#      neither.
#   2. A hardcoded 30-day window, not OUTPATIENT_WINDOW. Moving the outpatient
#      window to 60 or 90 changes step 1 and leaves this at 30.
#   3. The confirming claim may fall after index. Only first_dt has to be in
#      baseline, so a patient can be excluded on a claim that post-dates their
#      index date. Intended -- the pair confirms a cancer already present in
#      baseline -- but it means this is not purely a baseline-window gate.
#   4. Unknown care setting counts as OUTPATIENT here. This step writes
#      inpatient_flg with ELSE 0 and treats everything non-inpatient as
#      outpatient; step 1 writes the negation and gets neither. So the same claim
#      is classified differently by the two gates. Inherited as-is -- see
#      00_inputs.R. Step 8 ships off, so it does not affect the current count.
#
# Exclusion joins on the diagnosis code (dx.dx = o.dx plus ICD family).
# tumor_group is a label on the matched rows, used to partition the pair logic:
# excluded by code, grouped by label.
#
# Ships off (APPLY_OTHER_MALIG_EXCL=FALSE), and that is not a preference. NDMM
# re-applies other-malignancy at the LOT1 anchor with an MM-adjacent override that
# keeps five tumour groups (MGUS, secondary bone, solitary and extramedullary
# plasmacytoma, plasma-cell leukaemia). Turning it on here drops those patients
# before NDMM can put them back. Consequence for Overall, per
# pipeline_inputs.csv: no other-malignancy exclusion at all.
# =============================================================================

ie_step_other_malig <- function(cfg, h) {
  work <- h$work; cdm_src <- h$cdm_src

  views <- list(
    ie_view(
      name = "other_malig_flag",
      legacy = "22_other_malig_flag",
      description = "EXCLUSION: Other malignancy flag (>=1 IP or >=2 OP within 30d)",
      source_tables = c("med_diagnosis", "medical", "confinement"),
      select = fmt("
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
      note = "Fixed 30d pair window, not OUTPATIENT_WINDOW. Ships off."
    )
  )

  list(views = views, criteria = criteria)
}
