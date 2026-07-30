# =============================================================================
# 01_index.R -- IE Step 1: a qualifying MM diagnosis, and the index date
# -----------------------------------------------------------------------------
# THE RULE
#   1 INPATIENT MM diagnosis (STRICT codes 203.0x / C90.0x), or
#   2 OUTPATIENT MM diagnoses (BROAD codes) on separate days within the
#     configured window (30 / 60 / 90 days).
#
# Step 0 -- ">=1 MM dx, any position" -- is not a gate. It is the starting pool,
# counted straight off mm_dx_events_id in the attrition table.
#
# THE PART THAT IS EASY TO GET WRONG
# This step does NOT pick one index date. It keeps EVERY qualifying candidate,
# one row per (PATID, index_date), and it builds them at the WIDEST window (90d)
# regardless of how OUTPATIENT_WINDOW is set. The configured window is applied
# later, as a predicate, alongside every other gate.
#
# That is not an optimisation, it changes who is in the cohort. If the earliest
# candidate index date fails a downstream gate -- say the patient was not
# enrolled for the full baseline before it -- a LATER candidate can still carry
# them in. Narrowing to the earliest date here would drop those patients
# silently. See 09_assemble.R for where the choice actually happens.
#
# So `outpt2_30 / outpt2_60 / outpt2_90` are all carried forward: the predicate
# reads the configured one, and the attrition table reports all three side by
# side without rebuilding anything.
# =============================================================================

ie_step_index <- function(cfg, h) {
  work <- h$work

  views <- list(
    # Inpatient candidates. STRICT codes only, and no window applies -- one
    # inpatient claim is sufficient on its own.
    ie_view(
      name = "mm_inpatient_potential",
      legacy = "09_mm_inpatient_potential",
      description = "Finding ALL potential inpatient MM index dates (STRICT 203.0x/C90.0x only)",
      select = fmt("
        SELECT DISTINCT PATID, svc_dt AS potential_index, 'INPATIENT' AS index_source
        FROM {work('mm_dx_events_id')}
        WHERE inpatient_flg = 1
          AND mm_dx_strict_flg = 1
      "),
      qc = fmt("SELECT count(*) AS n_potential_inpt FROM {work('mm_inpatient_potential')}")
    ),

    # Outpatient pairs: consecutive DISTINCT service dates. Distinct dates is
    # what makes "2 claims on separate days" hold -- two claims on one day are
    # one date and cannot pair with each other.
    ie_view(
      name = "mm_outpatient_pairs",
      legacy = "10_mm_outpatient_pairs",
      description = "Building outpatient diagnosis date pairs",
      select = fmt("
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
      qc = fmt("SELECT count(*) AS n_pairs FROM {work('mm_outpatient_pairs')}")
    ),

    # The FIRST date of a qualifying pair is the candidate index. Built at 90d,
    # with a flag per window so the configured one can be selected later.
    ie_view(
      name = "mm_outpatient_potential",
      legacy = "11_mm_outpatient_potential",
      description = "Finding ALL potential outpatient MM index dates (2+ OP in window, not just earliest)",
      select = fmt("
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
      qc = fmt("SELECT count(*) AS n_potential_outpt FROM {work('mm_outpatient_potential')}")
    ),

    # One row per (PATID, candidate index date). A date reachable both ways is
    # aggregated, and inpatient wins: outpt_qual is forced to 0 for an inpatient
    # date so the two paths never double-count in the attrition table.
    ie_view(
      name = "mm_qualifying",
      legacy = "12_mm_qualifying",
      description = "Combining ALL potential index dates (IP or OP within 90d max window) - keeps all, not just earliest",
      select = fmt("
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
      qc = fmt("SELECT count(*) AS n_potential_index, count(DISTINCT PATID) AS n_patients FROM {work('mm_qualifying')}")
    )
  )

  criteria <- list(
    # No cfg_key: this one cannot be switched off. Without a qualifying MM
    # diagnosis there is no index date, so there is nothing to anchor the other
    # nine criteria to.
    #
    # The predicate reads outpt2_<window>, NOT outpt_qual. They agree for the
    # configured window by construction, and the legacy Step 24 filter is
    # written on outpt2_<window> -- kept identical so the two are comparable
    # character for character.
    ie_criterion(
      step = 1L,
      id = "idx_qualifying",
      attrition_id = "01_step1_qualifying",
      label = "Step 1: Qualifying MM dx (IP/OP)",
      flag_col = c("inpt_qual", fmt("outpt2_{cfg$outpatient_window}")),
      predicate = fmt("(inpt_qual = 1 OR outpt2_{cfg$outpatient_window} = 1)"),
      cfg_key = NA_character_,
      polarity = "include",
      note = paste("1 inpatient MM dx (strict 203.0x/C90.0x) or 2 outpatient",
                   "(broad) within", cfg$outpatient_window, "days.")
    )
  )

  list(views = views, criteria = criteria)
}
