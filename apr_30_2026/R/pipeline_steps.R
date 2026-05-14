# ============================================================
# pipeline_steps.R -- SQL pipeline step definitions
# ============================================================
build_steps <- function(cfg, mat_tables, phases = NULL) {
  # ---- Unpack naming helpers into local scope ----
  # These shadow the old globals so that ~114 glue interpolations
  # ({cdm(...)}, {ref(...)}, {work(...)}, etc.) require zero changes.
  h <- make_naming_helpers(cfg, mat_tables)
  full_name <- h$full_name; cdm <- h$cdm; ref <- h$ref
  work <- h$work; work_tbl <- h$work_tbl; cdm_src <- h$cdm_src

  # ---- Code-list sources ----
  # When use_csv_codelists is TRUE, CSVs have already been loaded into
  # temp views by load_csv_codelists() — reference the view names directly.
  # Otherwise, reference server-side tables via ref().
  if (isTRUE(cfg$use_csv_codelists)) {
    mm_dx_source       <- cfg$cl_mm_dx
    mm_therapy_source  <- cfg$cl_mm_therapy
    preg_source        <- cfg$cl_preg
    clintrial_source   <- cfg$cl_clintrial
    other_malig_source <- cfg$cl_other_malig
  } else {
    mm_dx_source       <- ref(cfg$cl_mm_dx)
    mm_therapy_source  <- ref(cfg$cl_mm_therapy)
    preg_source        <- ref(cfg$cl_preg)
    clintrial_source   <- ref(cfg$cl_clintrial)
    other_malig_source <- ref(cfg$cl_other_malig)
  }

  # ============================================================
  # BUILD COMBINED CRITERIA SQL (from unified criteria catalog)
  # ============================================================
  catalog      <- build_criteria_catalog(cfg)
  criteria_sql <- build_criteria_sql(catalog, cfg)

  # ----------------------------------------------------------
  # Follow-up cap — driven by cfg$censor_at_disenrollment.
  # Used by therapy_flags (Step 19), pregnancy_flag (Step 20),
  # clintrial_flag (Step 21) so the IE follow-up window matches
  # whatever LOT's OBS_END_DT is using.
  # PRIMARY:    least(study_end, death)             = ENDDATE
  # SENSITIVITY: least(study_end, death, ENDDATE_CE) ≈ ENDDATE_CE
  # All three steps already join death_dt as `d`. When the flag is on
  # we additionally join ce_flags as `ce` to access ENDDATE_CE.
  # ----------------------------------------------------------
  fu_cap_expr <- if (isTRUE(cfg$censor_at_disenrollment)) {
    glue("least(date('{cfg$study_end}'), coalesce(d.DEATH_DT, date('{cfg$study_end}')), coalesce(ce.ENDDATE_CE, date('{cfg$study_end}')))")
  } else {
    glue("least(date('{cfg$study_end}'), coalesce(d.DEATH_DT, date('{cfg$study_end}')))")
  }
  ce_join_for_fu_cap <- if (isTRUE(cfg$censor_at_disenrollment)) {
    glue("LEFT JOIN {work('ce_flags')} ce ON q.PATID = ce.PATID AND q.index_date = ce.index_date")
  } else {
    ""
  }
  phase_codelists <- function() list(
    # ----------------------------------------------------------
    # PHASE 1: NORMALIZE CODE LISTS (small tables, run once)
    # Source: server-side reference tables in cfg$ref_schema
    # ----------------------------------------------------------
    list(
      name = "01_mm_dx_codes",
      description = "Loading MM diagnosis codes (ICD-9/ICD-10)",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('mm_dx_codes')} AS
        SELECT
          CASE WHEN upper(icd_family) IN ('9','ICD9','ICD-9','ICD9DIAG') THEN 'ICD9' ELSE 'ICD10' END AS icd_family,
          upper(regexp_replace(trim(dx), '[^A-Za-z0-9]', '')) AS dx
        FROM {mm_dx_source}
        WHERE dx IS NOT NULL
      "),
      qc = glue("SELECT count(*) AS n_codes FROM {work('mm_dx_codes')}")
    ),

    list(
      name = "03_mm_therapy_codes",
      description = "Loading MM therapy codes (HCPCS/NDC) — sourced from cl_mma_codelist.csv (single source of truth with LOT S04)",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('mm_therapy_codes')} AS
        -- cl_mma_codelist.csv has columns CL_CODE_TYPE, CL_CODE (+ CL_MEDICATION_FULL, CL_MED_CLASS, CL_MED_ABBR)
        -- Aliased here to code_type/code to match downstream therapy join logic
        SELECT upper(trim(CL_CODE_TYPE)) AS code_type,
               upper(regexp_replace(trim(CL_CODE), '[^A-Za-z0-9]', '')) AS code
        FROM {mm_therapy_source}
        WHERE CL_CODE IS NOT NULL AND trim(CL_CODE) <> ''
          AND CL_CODE_TYPE IS NOT NULL AND trim(CL_CODE_TYPE) <> ''
      "),
      qc = glue("SELECT count(*) AS n_codes, count(DISTINCT code_type) AS n_code_types FROM {work('mm_therapy_codes')}")
    ),

    list(
      name = "04_preg_codes",
      description = "Loading pregnancy exclusion codes",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('preg_codes')} AS
        SELECT upper(trim(code_type)) AS code_type,
               upper(regexp_replace(trim(code), '[^A-Za-z0-9]', '')) AS code
        FROM {preg_source}
        WHERE code IS NOT NULL
      "),
      qc = glue("SELECT count(*) AS n_codes FROM {work('preg_codes')}")
    ),

    list(
      name = "05_clintrial_codes",
      description = "Loading clinical trial exclusion codes",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('clintrial_codes')} AS
        SELECT upper(trim(code_type)) AS code_type,
               upper(regexp_replace(trim(code), '[^A-Za-z0-9]', '')) AS code
        FROM {clintrial_source}
        WHERE code IS NOT NULL
      "),
      qc = glue("SELECT count(*) AS n_codes FROM {work('clintrial_codes')}")
    ),

    list(
      name = "06_other_malig_codes",
      description = "Loading other malignancy exclusion codes",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('other_malig_codes')} AS
        SELECT
          upper(tumor_group) AS tumor_group,
          CASE WHEN upper(icd_family) IN ('9','ICD9','ICD-9','ICD9DIAG') THEN 'ICD9' ELSE 'ICD10' END AS icd_family,
          upper(regexp_replace(trim(dx), '[^A-Za-z0-9]', '')) AS dx
        FROM {other_malig_source}
        WHERE dx IS NOT NULL AND tumor_group IS NOT NULL
      "),
      qc = glue("SELECT count(*) AS n_codes FROM {work('other_malig_codes')}")
    ),

    # ----------------------------------------------------------
    # SCHEMA PROBE: Validate RVNU_CD column exists on medical table
    # Per Optum CDM v9.0, the revenue code field is RVNU_CD (facility claims only).
    # This check fails early with a clear message if the column is missing,
    # rather than erroring deep in the pregnancy/clinical trial steps.
    # ----------------------------------------------------------
    list(
      name = "06c_validate_rvnu_cd",
      description = "Validating RVNU_CD column exists on medical table",
      source_tables = c("medical"),
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('rvnu_cd_check')} AS
        SELECT RVNU_CD FROM {cdm_src(cfg$tbl_medical)} LIMIT 1
      "),
      qc = glue("SELECT 'RVNU_CD column validated on medical table' AS status")
    )
  )
  phase_dx_events <- function() list(
    # ----------------------------------------------------------
    # PHASE 2: BUILD MM DIAGNOSIS EVENTS
    # FIXED: Build two tables:
    #   - mm_dx_events_all: full study period (for baseline flags)
    #   - mm_dx_events_id:  ID period only (for index qualification)
    # ----------------------------------------------------------
    list(
      name = "07a_med_claim_header",
      description = "Extracting medical claim headers from CDM (study period)",
      source_tables = c("medical"),
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('med_claim_header')} AS
        -- Claim grain is (PATID, PAT_PLANID, CLMID, FST_DT, LOC_CD). CLMID alone is
        -- not unique: it is a plan-assigned sequence number, so the same value can
        -- legitimately repeat across plan changes, service dates, or service-line
        -- locations. Grouping on only (PATID, CLMID) silently merges genuinely
        -- distinct claims and corrupts the inpatient_flg (which is then driven by
        -- max(POS) / max(TOS_CD) / max(CONF_ID) across the merged rows). This
        -- 5-column key matches the GSK house convention used elsewhere (e.g.
        -- vax_300081 R/02_codes/005_outcomes.Rmd).
        SELECT PATID, PAT_PLANID, CLMID, FST_DT, LOC_CD,
               max(CONF_ID) AS CONF_ID,
               max(POS)     AS POS,
               max(TOS_CD)  AS TOS_CD
        FROM {cdm_src(cfg$tbl_medical)}
        WHERE FST_DT BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
        GROUP BY PATID, PAT_PLANID, CLMID, FST_DT, LOC_CD
      "),
      qc = glue("
        SELECT count(*) AS n_claims,
               sum(CASE WHEN PAT_PLANID IS NULL THEN 1 ELSE 0 END) AS n_null_pat_planid,
               sum(CASE WHEN LOC_CD     IS NULL THEN 1 ELSE 0 END) AS n_null_loc_cd,
               sum(CASE WHEN FST_DT     IS NULL THEN 1 ELSE 0 END) AS n_null_fst_dt
        FROM {work('med_claim_header')}")
    ),

    # ----------------------------------------------------------
    # CONFINEMENT TABLE EXTRACT (per Optum Business Rules Approach 2)
    # Business rules: "inpatient should be restricted to cases where
    # CONF_ID is not NULL from the T_CONFINEMENT table"
    # This validates that CONF_ID corresponds to an actual confinement
    # Per Approach 2: confinement should have associated admission AND discharge dates
    # ----------------------------------------------------------
    list(
      name = "07b_confinement",
      description = "Extracting confinement records (Optum Approach 2)",
      source_tables = c("confinement"),
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('confinement')} AS
        SELECT DISTINCT PATID, CONF_ID,
               cast(ADMIT_DATE as date) AS ADMIT_DATE,
               cast(DISCH_DATE as date) AS DISCH_DATE
        FROM {cdm_src(cfg$tbl_confinement)}
        WHERE CONF_ID IS NOT NULL
          AND ADMIT_DATE IS NOT NULL
          AND DISCH_DATE IS NOT NULL
      "),
      qc = glue("SELECT count(*) AS n_confinements FROM {work('confinement')}")
    ),

    # All MM dx events in study period (for baseline lookback)
    # Inpatient identification using EITHER Approach 1 OR Approach 2
    # - Approach 1: POS IN (21, 51, 61) OR TOS_CD IN (FAC_IP.ACUTE, FAC_IP.REHSNF, PROF.INPVIS, FAC_IP.SNF)
    # - Approach 2: CONF_ID is validated in T_CONFINEMENT
    # Patient qualifies as inpatient if EITHER approach identifies them as inpatient
    # Join key matches the 5-column claim grain used by med_claim_header:
    # (PATID, PAT_PLANID, CLMID, FST_DT, LOC_CD).
    list(
      name = "08a_mm_dx_events_all",
      description = "Identifying MM diagnosis events (full study period, Approach 1+2 inpatient)",
      source_tables = c("med_diagnosis", "confinement"),
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('mm_dx_events_all')} AS
        SELECT /*+ BROADCAST(c) */
          d.PATID,
          d.PAT_PLANID,
          d.CLMID,
          d.LOC_CD,
          cast(d.FST_DT as date) AS svc_dt,
          upper(regexp_replace(d.DIAG, '[^A-Za-z0-9]', '')) AS diag,
          CASE WHEN upper(d.ICD_FLAG) IN ('9','ICD9','ICD-9') THEN 'ICD9' ELSE 'ICD10' END AS icd_family,
          h.CONF_ID,
          h.POS,
          h.TOS_CD,
          -- FIXED: Inpatient = Approach 1 (POS/TOS) OR Approach 2 (CONF_ID validated)
          -- Approach 1: POS 21/51/61; TOS_CD IN (FAC_IP.ACUTE, FAC_IP.REHSNF, PROF.INPVIS, FAC_IP.SNF)
          -- Approach 2: CONF_ID exists in T_CONFINEMENT with valid dates
          CASE WHEN h.POS IN ('21', '51', '61')
                 OR h.TOS_CD IN ('FAC_IP.ACUTE', 'FAC_IP.REHSNF', 'PROF.INPVIS', 'FAC_IP.SNF')
                 OR cf.CONF_ID IS NOT NULL
               THEN 1 ELSE 0 END AS inpatient_flg,
          -- Outpatient: NOT identified as inpatient by either approach
          CASE WHEN NOT (h.POS IN ('21', '51', '61')
                      OR h.TOS_CD IN ('FAC_IP.ACUTE', 'FAC_IP.REHSNF', 'PROF.INPVIS', 'FAC_IP.SNF')
                      OR cf.CONF_ID IS NOT NULL)
               THEN 1 ELSE 0 END AS outpatient_flg,
          -- STRICT MM dx flag: 203.0x / C90.0x only (for inpatient qualifying + baseline evidence)
          -- BROAD codes (203.x / C90.x) are used for Step 0 base and outpatient qualifying
          CASE WHEN (CASE WHEN upper(d.ICD_FLAG) IN ('9','ICD9','ICD-9') THEN 'ICD9' ELSE 'ICD10' END) = 'ICD9'
                      AND upper(regexp_replace(d.DIAG, '[^A-Za-z0-9]', '')) LIKE '2030%'
                 OR (CASE WHEN upper(d.ICD_FLAG) IN ('9','ICD9','ICD-9') THEN 'ICD9' ELSE 'ICD10' END) = 'ICD10'
                      AND upper(regexp_replace(d.DIAG, '[^A-Za-z0-9]', '')) LIKE 'C900%'
               THEN 1 ELSE 0 END AS mm_dx_strict_flg,
          -- QC flags for each approach
          CASE WHEN cf.CONF_ID IS NOT NULL THEN 1 ELSE 0 END AS conf_validated,
          CASE WHEN h.POS IN ('21', '51', '61') OR h.TOS_CD IN ('FAC_IP.ACUTE', 'FAC_IP.REHSNF', 'PROF.INPVIS', 'FAC_IP.SNF') THEN 1 ELSE 0 END AS pos_tos_inpatient
        FROM {cdm_src(cfg$tbl_med_diag)} d
        INNER JOIN {work('med_claim_header')} h
          -- PAT_PLANID and LOC_CD can be NULL on some Optum claim lines; use
          -- null-safe equality (Spark `<=>`) so a NULL on both sides matches
          -- instead of silently dropping the diagnosis row. PATID / CLMID /
          -- FST_DT should never be NULL on a valid claim, so plain `=` there.
          ON d.PATID      =   h.PATID
         AND d.CLMID      =   h.CLMID
         AND d.FST_DT     =   h.FST_DT
         AND d.PAT_PLANID <=> h.PAT_PLANID
         AND d.LOC_CD     <=> h.LOC_CD
        INNER JOIN {work('mm_dx_codes')} c
          ON upper(regexp_replace(d.DIAG, '[^A-Za-z0-9]', '')) = c.dx
          AND (CASE WHEN upper(d.ICD_FLAG) IN ('9','ICD9','ICD-9') THEN 'ICD9' ELSE 'ICD10' END) = c.icd_family
        LEFT JOIN {work('confinement')} cf
          ON h.PATID = cf.PATID AND h.CONF_ID = cf.CONF_ID
        WHERE cast(d.FST_DT as date) BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
      "),
      qc = glue("SELECT count(DISTINCT PATID) AS n_patients, sum(inpatient_flg) AS n_inpatient_events, sum(conf_validated) AS n_via_conf, sum(pos_tos_inpatient) AS n_via_pos_tos FROM {work('mm_dx_events_all')}")
    ),

    # MM dx events in ID period only (for index date qualification)
    list(
      name = "08b_mm_dx_events_id",
      description = "Filtering MM events to identification period",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('mm_dx_events_id')} AS
        SELECT * FROM {work('mm_dx_events_all')}
        WHERE svc_dt BETWEEN date('{cfg$id_start}') AND date('{cfg$id_end}')
      "),
      qc = glue("SELECT count(DISTINCT PATID) AS n_patients FROM {work('mm_dx_events_id')}")
    )
  )
  phase_index_date <- function() list(
    # ----------------------------------------------------------
    # PHASE 3: INDEX DATE DERIVATION (uses ID period events only)
    # ----------------------------------------------------------
    list(
      name = "09_mm_inpatient_potential",
      description = "Finding ALL potential inpatient MM index dates (STRICT 203.0x/C90.0x only per spec)",
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
  phase_enrollment <- function() list(
    # ----------------------------------------------------------
    # PHASE 4: ENROLLMENT SPANS (using member_enrollment with 30-day gap logic)
    # Per IE spec: Build continuous enrollment spans from raw member_enrollment
    # allowing gaps <= 30 days to be absorbed into continuous spans.
    # This replaces using prebuilt member_cont_enrollment to ensure consistent
    # gap handling logic across baseline and followup periods.
    # ----------------------------------------------------------
    list(
      name = "13_enrollment_spans",
      description = "Building enrollment spans with 30-day gap logic from member_enrollment",
      source_tables = c("member_enrollment"),
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('enrollment_spans')} AS
        WITH base AS (
          -- Use member_enrollment (raw) with 30-day gap allowance
          SELECT PATID, cast(ELIGEFF as date) AS elig_eff, cast(ELIGEND as date) AS elig_end
          FROM {cdm_src(cfg$tbl_member_enrollment)}
          WHERE ELIGEFF IS NOT NULL AND ELIGEND IS NOT NULL
        ),
        ordered AS (
          SELECT *,
            -- Use max(elig_end) seen so far to handle overlapping/nested segments
            max(elig_end) OVER (
              PARTITION BY PATID
              ORDER BY elig_eff, elig_end
              ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
            ) AS max_end_so_far
          FROM base
        ),
        flagged AS (
          SELECT *,
            -- Allow gaps <= {cfg$gap_days} days: new group if elig_eff > max_end_so_far + gap_days + 1
            CASE WHEN max_end_so_far IS NULL THEN 1
                 WHEN elig_eff <= date_add(max_end_so_far, {cfg$gap_days} + 1) THEN 0
                 ELSE 1 END AS new_grp
          FROM ordered
        ),
        grouped AS (
          SELECT *,
            sum(new_grp) OVER (PARTITION BY PATID ORDER BY elig_eff, elig_end
                               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS grp_id
          FROM flagged
        )
        SELECT PATID, grp_id, min(elig_eff) AS cov_start, max(elig_end) AS cov_end
        FROM grouped
        GROUP BY PATID, grp_id
      "),
      qc = glue("SELECT count(DISTINCT PATID) AS n_patients FROM {work('enrollment_spans')}")
    ),

    # ----------------------------------------------------------
    # PHASE 4b: STRICT ENROLLMENT SPANS (NO GAPS) - for CE_3mosf sensitivity
    # Per StudyPop spec: CE_3mosf requires NO allowable gaps
    # This step uses member_enrollment (raw eligibility records) since
    # the prebuilt member_cont_enrollment already absorbs <30 day gaps
    # and cannot be used to detect true enrollment gaps.
    # FIXED: Handle overlapping/nested segments by using max(elig_end) over window
    # instead of lag() which fails when a short segment follows a long one.
    # ----------------------------------------------------------
    list(
      name = "13b_enrollment_spans_strict",
      description = "Building strict enrollment spans (no gaps, handles overlaps)",
      source_tables = c("member_enrollment"),
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('enrollment_spans_strict')} AS
        WITH base AS (
          -- Use member_enrollment (raw) to detect ALL gaps
          SELECT PATID, cast(ELIGEFF as date) AS elig_eff, cast(ELIGEND as date) AS elig_end
          FROM {cdm_src(cfg$tbl_member_enrollment)}
          WHERE ELIGEFF IS NOT NULL AND ELIGEND IS NOT NULL
        ),
        ordered AS (
          SELECT *,
            -- FIXED: Use max(elig_end) seen so far, not just previous row
            -- This handles overlapping/nested segments correctly
            max(elig_end) OVER (
              PARTITION BY PATID
              ORDER BY elig_eff, elig_end
              ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
            ) AS max_end_so_far
          FROM base
        ),
        flagged AS (
          SELECT *,
            -- NO allowable gaps: new group if elig_eff > max_end_so_far + 1
            CASE WHEN max_end_so_far IS NULL THEN 1
                 WHEN elig_eff <= date_add(max_end_so_far, 1) THEN 0
                 ELSE 1 END AS new_grp
          FROM ordered
        ),
        grouped AS (
          SELECT *,
            sum(new_grp) OVER (PARTITION BY PATID ORDER BY elig_eff, elig_end
                               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS grp_id
          FROM flagged
        )
        SELECT PATID, grp_id, min(elig_eff) AS cov_start, max(elig_end) AS cov_end
        FROM grouped
        GROUP BY PATID, grp_id
      "),
      qc = glue("SELECT count(DISTINCT PATID) AS n_patients FROM {work('enrollment_spans_strict')}")
    ),

    # ----------------------------------------------------------
    # PHASE 5: CE FLAGS (baseline 6 months, follow-up)
    # NOTE: CE_3mosf is computed in Step 23 with death-awareness per IE spec
    # (requires enrollment through min(index+91, death_dt, study_end), no gaps)
    # Per IE spec: Baseline ends at index_date - 1; CE_f checks enrollment on index_date
    # CE_f = 1 when cov_start <= index_date AND cov_end >= index_date (follow-up starts on index)
    # ----------------------------------------------------------
    list(
      name = "14_ce_flags",
      description = "CRITERION: Continuous enrollment (baseline before index, follow-up from index)",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('ce_flags')} AS
        WITH idx AS (
          SELECT PATID, index_date,
                 date_sub(index_date, {cfg$baseline_days}) AS baseline_start,
                 date_sub(index_date, 1) AS baseline_end
          FROM {work('mm_qualifying')}
        ),
        -- CE_b and CE_f use standard enrollment spans (with 30-day allowable gaps)
        -- Baseline excludes index_date; CE_f requires enrollment on index_date (follow-up starts on index)
        joined_std AS (
          SELECT i.PATID, i.index_date, i.baseline_start, i.baseline_end,
                 s.cov_start, s.cov_end,
                 CASE WHEN s.cov_start <= i.baseline_start AND s.cov_end >= i.baseline_end
                      THEN 1 ELSE 0 END AS covers_baseline,
                 -- CE_f: requires enrollment covering index_date (follow-up starts on index)
                 CASE WHEN s.cov_start <= i.index_date AND s.cov_end >= i.index_date
                      THEN 1 ELSE 0 END AS has_1day_followup
          FROM idx i
          LEFT JOIN {work('enrollment_spans')} s ON i.PATID = s.PATID
        )
        SELECT PATID, index_date, baseline_start, baseline_end,
               max(covers_baseline) AS CE_b,
               max(has_1day_followup) AS CE_f,
               max(CASE WHEN has_1day_followup = 1 THEN cov_end END) AS ENDDATE_CE
        FROM joined_std
        GROUP BY PATID, index_date, baseline_start, baseline_end
      "),
      qc = glue("SELECT sum(CE_b) AS n_with_baseline_ce FROM {work('ce_flags')}")
    )
  )
  phase_demographics <- function() list(
    # ----------------------------------------------------------
    # PHASE 6: DEMOGRAPHICS
    # ----------------------------------------------------------
    list(
      name = "15_member_demo",
      description = "Extracting patient demographics (age/gender)",
      source_tables = c("member_cont_enrollment"),
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('member_demo')} AS
        WITH ranked AS (
          SELECT PATID, GDR_CD, cast(YRDOB as int) AS YRDOB,
                 row_number() OVER (PARTITION BY PATID
                   ORDER BY CASE WHEN upper(GDR_CD) NOT IN ('U','') THEN 0 ELSE 1 END,
                            cast(ELIGEND as date) DESC) AS rn
          FROM {cdm_src(cfg$tbl_member_elig)}
        )
        SELECT PATID, GDR_CD, YRDOB FROM ranked WHERE rn = 1
      "),
      qc = glue("SELECT count(*) AS n_patients FROM {work('member_demo')}")
    ),

    # ----------------------------------------------------------
    # PHASE 6b: DEATH DATE DERIVATION
    # Per StudyPop spec: When death date is only available at month-level
    # granularity, the date is generalized to the middle of the month (15th)
    # ----------------------------------------------------------
    # FIXED: Compute DEATH_DT directly with Dec 31 rule by joining to mm_qualifying
    # Per IE spec: Year-only death uses July 15 UNLESS index_date > July 15, then Dec 31
    # This prevents DEATH_DT < INDEX_DATE which would cause negative FU_DAYS
    list(
      name = "15b_death_dt",
      description = "Deriving death dates (month->15th, year-only uses July15/Dec31 rule)",
      source_tables = c("dod"),
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('death_dt')} AS
        WITH raw_death AS (
          SELECT
            PATID,
            cast(SUBSTR(YMDOD, 1, 4) as int) AS death_yr,
            CASE
              WHEN LENGTH(TRIM(YMDOD)) >= 6 THEN cast(SUBSTR(YMDOD, 5, 2) as int)
              ELSE NULL
            END AS death_mo
          FROM {cdm_src(cfg$tbl_dod)}
          WHERE YMDOD IS NOT NULL AND LENGTH(TRIM(YMDOD)) >= 4
        ),
        ranked AS (
          SELECT *,
                 row_number() OVER (PARTITION BY PATID ORDER BY death_yr DESC, death_mo DESC NULLS LAST) AS rn
          FROM raw_death
        ),
        best AS (
          SELECT PATID, death_yr, NULLIF(death_mo, 0) AS death_mo
          FROM ranked
          WHERE rn = 1
        ),
        calc AS (
          SELECT
            q.PATID,
            q.index_date,
            CASE
              WHEN b.death_yr IS NULL THEN NULL
              WHEN b.death_mo IS NOT NULL THEN
                -- Month-level: use 15th unless index_date > 15th in same month, then use month-end
                CASE
                  WHEN year(q.index_date) = b.death_yr
                   AND month(q.index_date) = b.death_mo
                   AND q.index_date > make_date(b.death_yr, b.death_mo, 15)
                  THEN last_day(make_date(b.death_yr, b.death_mo, 1))
                  ELSE make_date(b.death_yr, b.death_mo, 15)
                END
              ELSE
                -- Year-only: use July 15 unless index_date > July 15 in same year, then Dec 31
                CASE
                  WHEN year(q.index_date) = b.death_yr
                   AND q.index_date > make_date(b.death_yr, 7, 15)
                  THEN make_date(b.death_yr, 12, 31)
                  ELSE make_date(b.death_yr, 7, 15)
                END
            END AS death_raw
          FROM {work('mm_qualifying')} q
          LEFT JOIN best b ON q.PATID = b.PATID
        )
        -- Final clamp: ensure DEATH_DT >= index_date (prevents negative FU_DAYS from data issues)
        -- NOTE: Output includes index_date since death can be relative to each potential index
        SELECT
          PATID,
          index_date,
          CASE
            WHEN death_raw IS NOT NULL AND death_raw < index_date THEN index_date
            ELSE death_raw
          END AS DEATH_DT
        FROM calc
      "),
      qc = glue("SELECT count(*) AS n_with_death_dt FROM {work('death_dt')} WHERE DEATH_DT IS NOT NULL")
    )
  )
  phase_clinical_flags <- function() list(
    # ----------------------------------------------------------
    # PHASE 7: BASELINE MM EVIDENCE FLAG
    # Step 16 (claim_nondiagnostic view) was removed -- it was orphaned and
    # not referenced by any downstream step. The attrition table Step 7
    # requires only >=1 MM dx (strict) in baseline, not non-diagnostic claims.
    # ----------------------------------------------------------

    # Per ATTRITION TABLE Step 7: >=1 medical claim for MM (203.0x/C90.0x) in baseline
    # NOTE: Attrition table does NOT require non-diagnostic; IE criteria PDF row 14 does.
    # Following attrition table as the authoritative source.
    list(
      name = "17_mm_baseline_evidence_flag",
      description = "Checking for any STRICT MM dx (203.0x/C90.0x) claim in baseline period",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('mm_baseline_evidence_flag')} AS
        SELECT
          q.PATID,
          q.index_date,
          -- Per attrition table Step 7: >=1 MM claim (203.0x/C90.0x) in baseline
          -- Baseline excludes index_date (baseline = before index)
          -- mm_dx_strict_flg ensures only STRICT codes are counted
          max(CASE WHEN e.svc_dt BETWEEN date_sub(q.index_date, {cfg$baseline_days})
                                     AND date_sub(q.index_date, 1)
                    AND e.mm_dx_strict_flg = 1
               THEN 1 ELSE 0 END) AS MM_BASELINE_EVIDENCE
        FROM {work('mm_qualifying')} q
        LEFT JOIN {work('mm_dx_events_all')} e ON q.PATID = e.PATID
        GROUP BY q.PATID, q.index_date
      "),
      qc = glue("SELECT sum(MM_BASELINE_EVIDENCE) AS n_with_baseline_mm FROM {work('mm_baseline_evidence_flag')}")
    ),

    # ----------------------------------------------------------
    # PHASE 8: THERAPY EVENTS AND FLAGS
    # ----------------------------------------------------------
    # Step 18 scans 4 therapy sources, matching the LOT pipeline (S04):
    #   (1) PROC_CD (HCPCS/CPT) on medical claims      [source = MEDICAL_PROC_CD]
    #   (2) BILL_PROC_CD (HCPCS) on medical claims     [source = MEDICAL_BILL_PROC_CD]
    #   (3) NDC on medical claims                       [source = MEDICAL_NDC]
    #   (4) NDC on Rx claims                            [source = RX]
    list(
      name = "18_therapy_events",
      description = "Identifying MM therapy events (medical PROC_CD + BILL_PROC_CD + NDC, Rx NDC)",
      source_tables = c("medical", "rx"),
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('therapy_events')} AS
        -- 1) Medical therapy via PROC_CD (HCPCS/CPT)
        SELECT /*+ BROADCAST(c) */
          m.PATID, cast(m.FST_DT as date) AS event_dt, 'MEDICAL_PROC_CD' AS source
        FROM {cdm_src(cfg$tbl_medical)} m
        INNER JOIN {work('mm_therapy_codes')} c
          ON c.code_type IN ('HCPCS','CPT')
          AND upper(regexp_replace(coalesce(cast(m.PROC_CD as string),''), '[^A-Za-z0-9]', '')) = c.code
        WHERE m.FST_DT BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
        UNION ALL
        -- 2) Medical therapy via BILL_PROC_CD (HCPCS)
        SELECT /*+ BROADCAST(c) */
          m.PATID, cast(m.FST_DT as date) AS event_dt, 'MEDICAL_BILL_PROC_CD' AS source
        FROM {cdm_src(cfg$tbl_medical)} m
        INNER JOIN {work('mm_therapy_codes')} c
          ON c.code_type = 'HCPCS'
          AND upper(regexp_replace(coalesce(cast(m.BILL_PROC_CD as string),''), '[^A-Za-z0-9]', '')) = c.code
        WHERE m.FST_DT BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
        UNION ALL
        -- 3) Medical therapy via NDC
        SELECT /*+ BROADCAST(c) */
          m.PATID, cast(m.FST_DT as date) AS event_dt, 'MEDICAL_NDC' AS source
        FROM {cdm_src(cfg$tbl_medical)} m
        INNER JOIN {work('mm_therapy_codes')} c
          ON c.code_type = 'NDC'
          AND lpad(regexp_replace(coalesce(cast(m.NDC as string),''), '[^0-9]', ''), 11, '0')
            = lpad(regexp_replace(c.code, '[^0-9]', ''), 11, '0')
        WHERE m.FST_DT BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
        UNION ALL
        -- 4) Rx therapy via NDC
        SELECT /*+ BROADCAST(c) */
          r.PATID, cast(r.FILL_DT as date) AS event_dt, 'RX' AS source
        FROM {cdm_src(cfg$tbl_rx)} r
        INNER JOIN {work('mm_therapy_codes')} c
          ON c.code_type = 'NDC'
          AND lpad(regexp_replace(coalesce(cast(r.NDC as string),''), '[^0-9]', ''), 11, '0')
            = lpad(regexp_replace(c.code, '[^0-9]', ''), 11, '0')
        WHERE r.FILL_DT BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
      "),
      qc = glue("SELECT count(*) AS n_therapy_events FROM {work('therapy_events')}")
    ),

    # ----------------------------------------------------------
    # FIXED: Join death_dt to therapy_flags so follow-up therapy is bounded by death date
    # This prevents counting therapy after death (data quality issue) and ensures
    # that patients who die are not incorrectly included due to post-death claims
    # ----------------------------------------------------------
    list(
      name = "19_therapy_flags",
      description = "CRITERION: MM therapy in baseline/follow-up (death-aware)",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('therapy_flags')} AS
        SELECT
          q.PATID,
          q.index_date,
          -- Baseline excludes index_date per IE spec (baseline = before index)
          max(CASE WHEN t.event_dt BETWEEN date_sub(q.index_date, {cfg$baseline_days})
                                       AND date_sub(q.index_date, 1)
               THEN 1 ELSE 0 END) AS MM_THERAPY_BASELINE,
          -- Followup starts on index_date per IE spec (>= index_date)
          -- Bounded by fu_cap_expr (death + optionally ENDDATE_CE under sensitivity flag)
          max(CASE WHEN t.event_dt >= q.index_date
                    AND t.event_dt <= {fu_cap_expr}
               THEN 1 ELSE 0 END) AS MM_THERAPY_FOLLOWUP
        FROM {work('mm_qualifying')} q
        LEFT JOIN {work('death_dt')} d ON q.PATID = d.PATID AND q.index_date = d.index_date
        {ce_join_for_fu_cap}
        LEFT JOIN {work('therapy_events')} t ON q.PATID = t.PATID
        GROUP BY q.PATID, q.index_date
      "),
      qc = glue("SELECT sum(MM_THERAPY_FOLLOWUP) AS n_with_fu_therapy FROM {work('therapy_flags')}")
    )
  )
  phase_exclusions <- function() list(
    # ----------------------------------------------------------
    # PHASE 9: EXCLUSION FLAGS (pregnancy, clinical trial, other cancer)
    # Each is an independent flag per StudyPop spec
    # ----------------------------------------------------------
    # Per IE spec: "1 of medical claim with a diagnosis, procedure, or revenue code
    # indicating pregnancy or childbirth during the baseline or follow-up period"
    # FIXED: Added revenue code (RVNU_CD) support per spec requirement
    # NOTE: Pregnancy check spans baseline + follow-up per attrition table Step 9
    list(
      name = "20_pregnancy_flag",
      description = "EXCLUSION: Pregnancy flag (DX + PROC + RVNU_CD, baseline + follow-up)",
      source_tables = c("med_diagnosis", "medical", "med_procedure"),
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('pregnancy_flag')} AS
        WITH dx AS (
          SELECT PATID, cast(FST_DT as date) AS event_dt,
                 CASE WHEN upper(ICD_FLAG) IN ('9','ICD9','ICD-9') THEN 'ICD9DIAG' ELSE 'ICD10DIAG' END AS code_type,
                 upper(regexp_replace(DIAG, '[^A-Za-z0-9]', '')) AS code
          FROM {cdm_src(cfg$tbl_med_diag)}
          WHERE FST_DT BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
        ),
        hcpcs_proc AS (
          SELECT PATID, cast(FST_DT as date) AS event_dt, 'HCPCS' AS code_type,
                 upper(regexp_replace(PROC_CD, '[^A-Za-z0-9]', '')) AS code
          FROM {cdm_src(cfg$tbl_medical)}
          WHERE PROC_CD IS NOT NULL
            AND FST_DT BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
        ),
        icd_proc AS (
          SELECT PATID, cast(FST_DT as date) AS event_dt,
                 CASE WHEN upper(ICD_FLAG) IN ('9','ICD9','ICD-9') THEN 'ICD9PROC' ELSE 'ICD10PROC' END AS code_type,
                 upper(regexp_replace(PROC, '[^A-Za-z0-9]', '')) AS code
          FROM {cdm_src(cfg$tbl_med_proc)}
          WHERE PROC IS NOT NULL
            AND FST_DT BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
        ),
        rev AS (
          SELECT PATID, cast(FST_DT as date) AS event_dt, 'REV' AS code_type,
                 upper(TRIM(RVNU_CD)) AS code
          FROM {cdm_src(cfg$tbl_medical)}
          WHERE RVNU_CD IS NOT NULL AND TRIM(RVNU_CD) != ''
            AND FST_DT BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
        ),
        events AS (SELECT * FROM dx UNION ALL SELECT * FROM hcpcs_proc UNION ALL SELECT * FROM icd_proc UNION ALL SELECT * FROM rev),
        matched AS (
          SELECT /*+ BROADCAST(p) */ e.PATID, e.event_dt
          FROM events e
          INNER JOIN {work('preg_codes')} p ON e.code_type = p.code_type AND e.code = p.code
        )
        SELECT
          q.PATID,
          q.index_date,
          -- Per attrition table: pregnancy during baseline or follow-up period
          -- Follow-up upper bound follows fu_cap_expr (sensitivity flag aware)
          max(CASE WHEN m.event_dt BETWEEN date_sub(q.index_date, {cfg$baseline_days})
                                       AND {fu_cap_expr}
               THEN 1 ELSE 0 END) AS PREGNANT_FLAG
        FROM {work('mm_qualifying')} q
        LEFT JOIN {work('death_dt')} d ON q.PATID = d.PATID AND q.index_date = d.index_date
        {ce_join_for_fu_cap}
        LEFT JOIN matched m ON q.PATID = m.PATID
        GROUP BY q.PATID, q.index_date
      "),
      qc = glue("SELECT sum(PREGNANT_FLAG) AS n_pregnant FROM {work('pregnancy_flag')}")
    ),

    # Per IE spec: "Evidence of clinical trial participation during each of the
    # baseline and follow-up periods. See tab CL CLNTRIAL."
    # FIXED: Added revenue code (RVNU_CD) support for consistency with CL CLNTRIAL tab
    list(
      name = "21_clintrial_flag",
      description = "EXCLUSION: Clinical trial flag (DX + PROC + RVNU_CD, baseline + follow-up)",
      source_tables = c("med_diagnosis", "medical", "med_procedure"),
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('clintrial_flag')} AS
        WITH dx AS (
          SELECT PATID, cast(FST_DT as date) AS event_dt,
                 CASE WHEN upper(ICD_FLAG) IN ('9','ICD9','ICD-9') THEN 'ICD9DIAG' ELSE 'ICD10DIAG' END AS code_type,
                 upper(regexp_replace(DIAG, '[^A-Za-z0-9]', '')) AS code
          FROM {cdm_src(cfg$tbl_med_diag)}
          WHERE FST_DT BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
        ),
        hcpcs_proc AS (
          SELECT PATID, cast(FST_DT as date) AS event_dt, 'HCPCS' AS code_type,
                 upper(regexp_replace(PROC_CD, '[^A-Za-z0-9]', '')) AS code
          FROM {cdm_src(cfg$tbl_medical)}
          WHERE PROC_CD IS NOT NULL
            AND FST_DT BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
        ),
        icd_proc AS (
          SELECT PATID, cast(FST_DT as date) AS event_dt,
                 CASE WHEN upper(ICD_FLAG) IN ('9','ICD9','ICD-9') THEN 'ICD9PROC' ELSE 'ICD10PROC' END AS code_type,
                 upper(regexp_replace(PROC, '[^A-Za-z0-9]', '')) AS code
          FROM {cdm_src(cfg$tbl_med_proc)}
          WHERE PROC IS NOT NULL
            AND FST_DT BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
        ),
        rev AS (
          SELECT PATID, cast(FST_DT as date) AS event_dt, 'REV' AS code_type,
                 upper(TRIM(RVNU_CD)) AS code
          FROM {cdm_src(cfg$tbl_medical)}
          WHERE RVNU_CD IS NOT NULL AND TRIM(RVNU_CD) != ''
            AND FST_DT BETWEEN date('{cfg$study_start}') AND date('{cfg$study_end}')
        ),
        events AS (SELECT * FROM dx UNION ALL SELECT * FROM hcpcs_proc UNION ALL SELECT * FROM icd_proc UNION ALL SELECT * FROM rev),
        matched AS (
          SELECT /*+ BROADCAST(c) */ e.PATID, e.event_dt
          FROM events e
          INNER JOIN {work('clintrial_codes')} c ON e.code_type = c.code_type AND e.code = c.code
        )
        SELECT
          q.PATID,
          q.index_date,
          -- Baseline excludes index_date per IE spec (baseline = before index)
          max(CASE WHEN m.event_dt BETWEEN date_sub(q.index_date, {cfg$baseline_days})
                                       AND date_sub(q.index_date, 1)
               THEN 1 ELSE 0 END) AS CLINTRIAL_BASELINE,
          -- Followup starts on index_date per IE spec
          -- Follow-up upper bound follows fu_cap_expr (sensitivity flag aware)
          max(CASE WHEN m.event_dt >= q.index_date
                    AND m.event_dt <= {fu_cap_expr}
               THEN 1 ELSE 0 END) AS CLINTRIAL_FOLLOWUP
        FROM {work('mm_qualifying')} q
        LEFT JOIN {work('death_dt')} d ON q.PATID = d.PATID AND q.index_date = d.index_date
        {ce_join_for_fu_cap}
        LEFT JOIN matched m ON q.PATID = m.PATID
        GROUP BY q.PATID, q.index_date
      "),
      qc = glue("SELECT sum(CLINTRIAL_BASELINE) + sum(CLINTRIAL_FOLLOWUP) AS n_clintrial FROM {work('clintrial_flag')}")
    ),

    list(
      name = "22_other_malig_flag",
      description = "EXCLUSION: Other malignancy flag (>=1 IP or >=2 OP within 30d per spec)",
      source_tables = c("med_diagnosis", "medical", "confinement"),
      sql = glue("
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
          -- Per spec: >=1 inpatient OR >=2 outpatient within 30d, same tumor group, in baseline
          max(CASE
            -- Path A: single inpatient claim in baseline
            WHEN ip.event_dt BETWEEN date_sub(q.index_date, {cfg$baseline_days})
                                 AND date_sub(q.index_date, 1)
            THEN 1
            -- Path B: 2 outpatient claims within 30d, first in baseline
            -- Per StudyPop MM_baseline_other: Only the first of the 2 codes
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
      qc = glue("SELECT sum(OTHER_MALIGN_FLAG) AS n_other_malig FROM {work('other_malig_flag')}")
    )
  )
  phase_assembly <- function() list(
    # ----------------------------------------------------------
    # PHASE 10: FINAL ASSEMBLY - ELIG_COH with all flags
    # FIXED: Added Death_dt, proper ENDDATE/FU_DAYS per StudyPop spec:
    #   - ENDDATE = min(Death_dt, study_end)
    #   - ENDDATE_CE = min(Death_dt, disenrollment, study_end)
    #   - FU_DAYS = datediff(ENDDATE, index_date + 1) + 1  (follow-up starts day after index)
    #   - FU_DAYS_CE = datediff(ENDDATE_CE, index_date + 1) + 1
    # ----------------------------------------------------------
    list(
      name = "23_ELIG_COH_ALLFLAGS",
      description = "Assembling cohort with all flags",
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work('ELIG_COH_ALLFLAGS')} AS
        WITH base AS (
          SELECT
            q.PATID,
            q.index_date,
            d.GDR_CD,
            d.YRDOB,
            death.DEATH_DT,
            ce.baseline_start,
            ce.baseline_end,
            ce.CE_b,
            ce.CE_f,
            ce.ENDDATE_CE,
            th.MM_THERAPY_BASELINE,
            th.MM_THERAPY_FOLLOWUP,
            mm_bl.MM_BASELINE_EVIDENCE,
            om.OTHER_MALIGN_FLAG,
            preg.PREGNANT_FLAG,
            ct.CLINTRIAL_BASELINE,
            ct.CLINTRIAL_FOLLOWUP,
            q.inpt_qual, q.outpt_qual, q.outpt2_30, q.outpt2_60, q.outpt2_90, q.index_source
          FROM {work('mm_qualifying')} q
          LEFT JOIN {work('ce_flags')} ce ON q.PATID = ce.PATID AND q.index_date = ce.index_date
          LEFT JOIN {work('member_demo')} d ON q.PATID = d.PATID
          LEFT JOIN {work('death_dt')} death ON q.PATID = death.PATID AND q.index_date = death.index_date
          LEFT JOIN {work('mm_baseline_evidence_flag')} mm_bl ON q.PATID = mm_bl.PATID AND q.index_date = mm_bl.index_date
          LEFT JOIN {work('therapy_flags')} th ON q.PATID = th.PATID AND q.index_date = th.index_date
          LEFT JOIN {work('pregnancy_flag')} preg ON q.PATID = preg.PATID AND q.index_date = preg.index_date
          LEFT JOIN {work('clintrial_flag')} ct ON q.PATID = ct.PATID AND q.index_date = ct.index_date
          LEFT JOIN {work('other_malig_flag')} om ON q.PATID = om.PATID AND q.index_date = om.index_date
        ),
        -- CE_3mosf with death-aware logic (no gaps, ends at min of 90 days/death/study_end)
        ce3mos_calc AS (
          SELECT
            b.PATID,
            b.index_date,
            least(
              date_add(b.index_date, 90),
              date('{cfg$study_end}'),
              coalesce(b.DEATH_DT, date('{cfg$study_end}'))
            ) AS required_3mos_end,
            ss.cov_start,
            ss.cov_end
          FROM base b
          LEFT JOIN {work('enrollment_spans_strict')} ss ON b.PATID = ss.PATID
        ),
        ce3mos_flag AS (
          SELECT PATID, index_date,
            max(CASE WHEN cov_start <= index_date AND cov_end >= required_3mos_end THEN 1 ELSE 0 END) AS CE_3mosf
          FROM ce3mos_calc
          GROUP BY PATID, index_date
        )
        SELECT
          b.PATID,
          b.index_date AS INDEX_DATE,
          year(b.index_date) AS INDEX_YR,
          b.GDR_CD,
          b.YRDOB,
          (year(b.index_date) - b.YRDOB) AS AGE_INDEX_YR,
          b.inpt_qual, b.outpt_qual, b.outpt2_30, b.outpt2_60, b.outpt2_90, b.index_source,
          b.baseline_start, b.baseline_end,
          coalesce(b.CE_b, 0) AS CE_b,
          coalesce(b.CE_f, 0) AS CE_f,
          coalesce(c3.CE_3mosf, 0) AS CE_3mosf,
          b.DEATH_DT,
          least(date('{cfg$study_end}'), coalesce(b.DEATH_DT, date('{cfg$study_end}'))) AS ENDDATE,
          least(date('{cfg$study_end}'), coalesce(b.DEATH_DT, date('{cfg$study_end}')), coalesce(b.ENDDATE_CE, date('{cfg$study_end}'))) AS ENDDATE_CE,
          datediff(least(date('{cfg$study_end}'), coalesce(b.DEATH_DT, date('{cfg$study_end}'))), date_add(b.index_date, 1)) + 1 AS FU_DAYS,
          datediff(least(date('{cfg$study_end}'), coalesce(b.DEATH_DT, date('{cfg$study_end}')), coalesce(b.ENDDATE_CE, date('{cfg$study_end}'))), date_add(b.index_date, 1)) + 1 AS FU_DAYS_CE,
          coalesce(b.MM_THERAPY_BASELINE, 0) AS MM_bl_agents,
          coalesce(b.MM_THERAPY_FOLLOWUP, 0) AS MM_FU_agents,
          coalesce(b.MM_BASELINE_EVIDENCE, 0) AS MM_baseline_diag,
          coalesce(b.OTHER_MALIGN_FLAG, 0) AS OTHER_MALIGN_FLAG,
          coalesce(b.PREGNANT_FLAG, 0) AS PREGNANT_FLAG,
          coalesce(b.CLINTRIAL_BASELINE, 0) AS CLINTRIAL_BASELINE,
          coalesce(b.CLINTRIAL_FOLLOWUP, 0) AS CLINTRIAL_FOLLOWUP
        FROM base b
        LEFT JOIN ce3mos_flag c3 ON b.PATID = c3.PATID AND b.index_date = c3.index_date
      "),
      qc = glue("SELECT count(*) AS n_total, count(DISTINCT PATID) AS n_patients FROM {work('ELIG_COH_ALLFLAGS')}")
    ),

    list(
      name = "24_ELIG_COH_FINAL",
      description = glue("FINAL COHORT ({cfg$final_table_name}): Apply IE criteria then select EARLIEST qualifying index_date per patient"),
      sql = glue("
        CREATE OR REPLACE TEMPORARY VIEW {work(cfg$final_table_name)} AS
        -- First apply IE criteria, then select the EARLIEST qualifying index_date per patient
        -- This ensures that if a patient's earliest potential index_date fails IE criteria,
        -- a later index_date that passes can still be selected
        WITH filtered AS (
          SELECT *
          FROM {work('ELIG_COH_ALLFLAGS')}
          WHERE 1=1
            -- Step 1: Index date must qualify via IP (strict) or OP in configured window
            AND (inpt_qual = 1 OR outpt2_{cfg$outpatient_window} = 1)
            {criteria_sql}
        ),
        ranked AS (
          SELECT *,
                 row_number() OVER (PARTITION BY PATID ORDER BY INDEX_DATE) AS rn
          FROM filtered
        )
        SELECT * FROM ranked WHERE rn = 1
      "),
      qc = glue("SELECT count(*) AS n_final_cohort FROM {work(cfg$final_table_name)}")
    ),

    # ----------------------------------------------------------
    # STEP 24b: PERSIST FINAL COHORT TO PERSONAL SCHEMA
    # ----------------------------------------------------------
    # Uses lazy table approach to save final cohort as permanent table
    # in user's personal schema. Set PERSIST_TO_SCHEMA=FALSE to skip.

    if (isTRUE(cfg$persist_to_schema) && nzchar(cfg$personal_schema)) {
      persist_tbl <- full_name(cfg$personal_schema, cfg$final_table_name)
      list(
        name = "24b_persist_final_cohort",
        description = glue("Persist final cohort to {persist_tbl}"),
        sql = glue("
          CREATE OR REPLACE TABLE {persist_tbl} AS
          SELECT * FROM {work(cfg$final_table_name)}
        "),
        qc = glue("SELECT count(*) AS n_persisted FROM {persist_tbl}")
      )
    } else NULL
  )

  # ---- Assemble phases ----
  # Named list allows filtering by phase for interactive debugging:
  #   build_steps(cfg, mat_tables, phases = c("codelists", "dx_events"))
  all_phases <- list(
    codelists      = phase_codelists,
    dx_events      = phase_dx_events,
    index_date     = phase_index_date,
    enrollment     = phase_enrollment,
    demographics   = phase_demographics,
    clinical_flags = phase_clinical_flags,
    exclusions     = phase_exclusions,
    assembly       = phase_assembly
  )

  if (is.null(phases)) {
    selected <- all_phases
  } else {
    bad <- setdiff(phases, names(all_phases))
    if (length(bad) > 0) {
      stop("Unknown phase(s): ", paste(bad, collapse = ", "),
           ". Valid phases: ", paste(names(all_phases), collapse = ", "))
    }
    # Warn about missing prerequisites (phases depend on earlier phases)
    phase_order <- names(all_phases)
    last_idx <- max(match(phases, phase_order))
    missing <- setdiff(phase_order[seq_len(last_idx)], phases)
    if (length(missing) > 0) {
      log_msg("WARN: Skipped prerequisite phase(s): ", paste(missing, collapse = ", "),
              ". Views from those phases must already exist.")
    }
    selected <- all_phases[phases]
  }
  do.call(c, lapply(selected, function(fn) fn()))
}
