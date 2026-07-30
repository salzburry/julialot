# Step 1: every candidate index date - 1 inpatient or 2 outpatient in window.
# Keep them all; the earliest surviving one is picked in 08_assembly.R.

phase_index_date <- function(cfg, h, ctx) {
  work <- h$work

  list(
    # ---- Phase 3: index date (Step 1 gate) ----
    # ID-period events only. 1 inpatient (strict) OR 2 outpatient within
    # the window qualifies; keep every candidate, not just the earliest.
    list(
      name = "09_mm_inpatient_potential",
      description = "Finding ALL potential inpatient MM index dates (STRICT 203.0x/C90.0x only)",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('mm_inpatient_potential')} AS
        SELECT DISTINCT PATID, svc_dt AS potential_index, 'INPATIENT' AS index_source
        FROM {work('mm_dx_events_id')}
        WHERE inpatient_flg = 1
          AND mm_dx_strict_flg = 1
      "),
      qc = glue("SELECT count(*) AS n_potential_inpt FROM {work('mm_inpatient_potential')}")
    ),

    list(
      name = "10_mm_outpatient_pairs",
      description = "Building outpatient diagnosis date pairs",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('mm_outpatient_pairs')} AS
        WITH distinct_dates AS (
          SELECT DISTINCT PATID, svc_dt
          FROM {work('mm_dx_events_id')}
          WHERE outpatient_flg = 1
        ),
        with_next AS (
          SELECT PATID, svc_dt,
                 lead(svc_dt) OVER (PARTITION BY PATID ORDER BY svc_dt) AS next_dt
          FROM distinct_dates
        )
        SELECT PATID, svc_dt AS first_dt, next_dt,
               datediff(next_dt, svc_dt) AS diff_days
        FROM with_next
        WHERE next_dt IS NOT NULL
      "),
      qc = glue("SELECT count(*) AS n_pairs FROM {work('mm_outpatient_pairs')}")
    ),

    list(
      name = "11_mm_outpatient_potential",
      description = "Finding ALL potential outpatient MM index dates (2+ OP in window, not just earliest)",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('mm_outpatient_potential')} AS
        -- Each qualifying pair's first_dt is a potential index date
        -- Keep track of which windows (30/60/90) each date qualifies for
        SELECT DISTINCT
          PATID,
          first_dt AS potential_index,
          'OUTPATIENT' AS index_source,
          CASE WHEN diff_days <= {cfg$dx_window_90} THEN 1 ELSE 0 END AS qualifies_90,
          CASE WHEN diff_days <= {cfg$dx_window_60} THEN 1 ELSE 0 END AS qualifies_60,
          CASE WHEN diff_days <= {cfg$dx_window_30} THEN 1 ELSE 0 END AS qualifies_30
        FROM {work('mm_outpatient_pairs')}
        WHERE diff_days <= {cfg$dx_window_90}
      "),
      qc = glue("SELECT count(*) AS n_potential_outpt FROM {work('mm_outpatient_potential')}")
    ),

    list(
      name = "12_mm_qualifying",
      description = "Combining ALL potential index dates (IP or OP within 90d max window) - keeps all, not just earliest",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('mm_qualifying')} AS
        -- Option B: Always build with MAX window (90 days) so all candidates are preserved.
        -- The configured outpatient window ({cfg$outpatient_window}d) is applied later in Step 24
        -- via the outpt_qual flag, NOT here. This ensures that if a patient's earliest
        -- 90d-qualified date fails IE criteria, a later date can still be selected.
        -- Flags outpt2_30, outpt2_60, outpt2_90 are carried forward for attrition reporting.
        WITH all_potential AS (
          -- Inpatient potential index dates (always qualify regardless of window)
          SELECT PATID, potential_index, 1 AS inpt_qual, 0 AS outpt2_30, 0 AS outpt2_60, 0 AS outpt2_90
          FROM {work('mm_inpatient_potential')}
          UNION ALL
          -- Outpatient potential index dates (include ALL that qualify within 90d)
          SELECT PATID, potential_index, 0 AS inpt_qual,
                 qualifies_30 AS outpt2_30, qualifies_60 AS outpt2_60, qualifies_90 AS outpt2_90
          FROM {work('mm_outpatient_potential')}
        )
        -- Aggregate per PATID + potential_index to handle dates that qualify via both paths
        SELECT
          PATID,
          potential_index AS index_date,
          max(inpt_qual) AS inpt_qual,
          -- outpt_qual reflects the CONFIGURED window (used in Step 24 criteria filter)
          max(CASE WHEN inpt_qual = 1 THEN 0
                   ELSE outpt2_{cfg$outpatient_window} END) AS outpt_qual,
          max(outpt2_30) AS outpt2_30,
          max(outpt2_60) AS outpt2_60,
          max(outpt2_90) AS outpt2_90,
          CASE
            WHEN max(inpt_qual) = 1 THEN 'INPATIENT'
            WHEN max(outpt2_{cfg$outpatient_window}) = 1 THEN 'OUTPATIENT_2IN{cfg$outpatient_window}'
            ELSE 'OUTPATIENT_2IN90'
          END AS index_source
        FROM all_potential
        GROUP BY PATID, potential_index
      "),
      qc = glue("SELECT count(*) AS n_potential_index, count(DISTINCT PATID) AS n_patients FROM {work('mm_qualifying')}")
    )
  )
}
