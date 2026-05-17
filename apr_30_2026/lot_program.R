#!/usr/bin/env Rscript
# GSK MM LOT - Part 2: Lines of Therapy (LOT) Analysis
#
# Implements Part 2 specifications (based on provided PDFs):
#   5A. MMA_MED    - MM-approved + steroid medication claims pull
#   5B. MAP_MED    - Medication Available Period algorithm (pushout/runout)
#   6.  LOT1_BASE  - LOT1 induction regimen identification
#   7.  SCT        - Stem Cell Transplant detection (AUTO/ALLO/CART)
#
# Key references (provided by user):
#   - mma med.pdf
#   - map med.pdf        (pushout/runout logic + Figure 3 example)
#   - lot1base.pdf
#   - sct.pdf            (SCT detection: AUTO/ALLO/CART)
#   - tab 40.pdf         (CL_MMA_ROLLUP)
#   - tab 41 sample.pdf  (CL_MMA_CODELIST)
#   - optum data dict.pdf (field validation)
#   - optum business rules.pdf (join/filter logic guidance)
#
# Input:  ELIG_COH_FINAL (output of the Part 1 attrition pipeline; see main.R)
# Output: MAP_STACKED, LOT1_BASE, LOT1_SCT, LOT1_BASE_END
#
# IMPORTANT - MAP algorithm corrections vs prior versions:
#   1. Medical claims: NO pushout (per map med.pdf page 5: "Pushout is
#      not implemented"). Medical runout always = DATE_SERVICE + DAY_SUPPLY - 1.
#   2. Pharmacy claims: pushout only when new claim arrives BEFORE current
#      rx_runout. When pharmacy claim arrives AFTER rx_runout (but within
#      med_runout), pharmacy resets without pushout (per Figure 3, iter 4).
#   3. The simplified "sum pharmacy day supply" approach is incorrect when
#      pharmacy expires mid-MAP (kept alive by medical) and later resets.
#      The aggregate() state machine handles this correctly.

# Resolve script directory robustly for all invocation modes:
#   Rscript lot_program.R        -> commandArgs --file=
#   source("lot_program.R")      -> sys.frame()$ofile
#   interactive line-by-line      -> falls back to getwd()
.script_dir <- local({
  # 1. Rscript --file=<path>
  args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", args, value = TRUE)
  if (length(file_arg) > 0) {
    return(dirname(normalizePath(sub("^--file=", "", file_arg[1]))))
  }
  # 2. source() from R console - walk call stack for $ofile
  for (i in seq_len(sys.nframe())) {
    ofile <- tryCatch(sys.frame(i)$ofile, error = function(e) NULL)
    if (!is.null(ofile)) return(dirname(normalizePath(ofile)))
  }
  # 3. Fallback: working directory (user must be in Program/)
  getwd()
})
source_dir <- file.path(.script_dir, "R")
# Apply pipeline_inputs.csv overrides BEFORE config_lot.R reads
# Sys.getenv(), so a direct `Rscript lot_program.R` honours the same
# single input file as the orchestrated run.
if (file.exists(file.path(source_dir, "load_inputs.R"))) {
  source(file.path(source_dir, "load_inputs.R"))
  load_pipeline_inputs(c(.script_dir, dirname(.script_dir)))
}
source(file.path(source_dir, "config_lot.R"))
source(file.path(source_dir, "db_utils_lot.R"))
source(file.path(source_dir, "codelists_lot.R"))
source(file.path(source_dir, "dashboard_lot.R"))
source(file.path(source_dir, "descriptives_lot.R"))
source(file.path(source_dir, "cyclo_appendix_lot.R"))

main <- function() {
  stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")

  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  log_msg("Connected. Run ID: ", run_id)
  log_msg("Configuration:")
  log_msg("  CDM Schema:        ", cfg$cdm_schema)
  log_msg("  Work Schema:       ", cfg$work_schema)
  log_msg("  Input Cohort:      ", cfg$input_cohort_table)
  log_msg("  Induction Window (LOT1):   ", cfg$induction_window_days, " days")
  log_msg("  Induction Window (LOT2-5): ", cfg$lot_n_induction_window_days, " days")
  log_msg("  Discon Gap (per-drug, MAP-level): ", cfg$map_discon_gap_days, " days")
  log_msg("  Medical Day Supply: ", cfg$medical_day_supply, " days")

  # STEP 0: Register code lists as TEMP views
  rollup_src <- load_codelist_csv("cl_mma_rollup.csv",
    c("CL_MEDICATION_FULL", "CL_MED_CLASS", "CL_MED_ABBR",
      "MONOMAINTENANCE", "DUALMAINTENANCEWITH", "CONDITIONING", "USED_FOR_OTHER_CANCERS"))
  codelist_src <- load_codelist_csv("cl_mma_codelist.csv",
    c("CL_CODE_TYPE", "CL_CODE", "CL_MEDICATION_FULL", "CL_MED_CLASS", "CL_MED_ABBR"))
  subs_src <- load_codelist_csv("permissible_subs.csv",
    c("original_med", "substitute_med"))
  sct_src <- load_codelist_csv("cl_sct_codelist.csv",
    c("CL_CODE_TYPE", "CL_CODE", "SCT_TYPE"))
  run_step(con, "S00_mma_rollup", glue("
    CREATE OR REPLACE TEMPORARY VIEW mma_rollup AS
    SELECT
      lower(trim(CL_MEDICATION_FULL)) AS CL_MEDICATION_FULL,
      upper(trim(CL_MED_CLASS))       AS CL_MED_CLASS,
      upper(trim(CL_MED_ABBR))        AS CL_MED_ABBR,
      -- Tab 40 fields can be 'YES', 'YES mainly...', 1, 0, or NULL.
      -- Robust parsing: treat 'YES%' or '1' as 1, everything else as 0.
      CASE WHEN upper(trim(cast(MONOMAINTENANCE AS string))) LIKE 'YES%'
            OR  trim(cast(MONOMAINTENANCE AS string)) = '1'
           THEN 1 ELSE 0 END AS MONOMAINTENANCE,
      CASE
        WHEN DUALMAINTENANCEWITH IS NULL
          OR upper(trim(cast(DUALMAINTENANCEWITH AS string))) IN ('', 'NULL', 'NONE', 'NA', 'N/A')
          THEN NULL
        ELSE upper(trim(cast(DUALMAINTENANCEWITH AS string)))
      END AS DUALMAINTENANCEWITH,
      CASE WHEN upper(trim(cast(CONDITIONING AS string))) LIKE 'YES%'
            OR  trim(cast(CONDITIONING AS string)) = '1'
           THEN 1 ELSE 0 END AS CONDITIONING,
      CASE WHEN upper(trim(cast(USED_FOR_OTHER_CANCERS AS string))) LIKE 'YES%'
            OR  trim(cast(USED_FOR_OTHER_CANCERS AS string)) = '1'
           THEN 1 ELSE 0 END AS USED_FOR_OTHER_CANCERS
    FROM {rollup_src}
  "), qc = "SELECT count(*) AS n_rows, count(DISTINCT CL_MED_ABBR) AS n_meds,
            sum(MONOMAINTENANCE) AS n_monomaint, sum(CONDITIONING) AS n_conditioning,
            sum(USED_FOR_OTHER_CANCERS) AS n_other_cancer FROM mma_rollup")

  run_step(con, "S01_mma_codelist", glue("
    CREATE OR REPLACE TEMPORARY VIEW mma_codelist AS
    SELECT
      upper(trim(CL_CODE_TYPE)) AS CL_CODE_TYPE,
      upper(regexp_replace(trim(CL_CODE), '[^A-Za-z0-9]', '')) AS CL_CODE,
      lower(trim(CL_MEDICATION_FULL)) AS CL_MEDICATION_FULL,
      upper(trim(CL_MED_CLASS))       AS CL_MED_CLASS,
      upper(trim(CL_MED_ABBR))        AS CL_MED_ABBR
    FROM {codelist_src}
    WHERE CL_CODE IS NOT NULL AND trim(CL_CODE) <> ''
      AND CL_CODE_TYPE IS NOT NULL AND trim(CL_CODE_TYPE) <> ''
  "), qc = "SELECT count(*) AS n_rows, count(DISTINCT CL_MED_ABBR) AS n_meds, count(DISTINCT CL_CODE_TYPE) AS n_code_types FROM mma_codelist")

  run_step(con, "S02_permissible_subs", glue("
    CREATE OR REPLACE TEMPORARY VIEW permissible_subs AS
    SELECT
      upper(trim(original_med))   AS original_med,
      upper(trim(substitute_med)) AS substitute_med
    FROM {subs_src}
    WHERE original_med IS NOT NULL AND substitute_med IS NOT NULL
  "), qc = "SELECT count(*) AS n_rows, count(DISTINCT original_med) AS n_orig_meds FROM permissible_subs")

  # Codelist <-> Rollup consistency QC
  log_msg("Checking codelist <-> rollup consistency...")
  tryCatch({
    # Codelist meds not in rollup (will be missing class/flag info)
    orphan_meds <- db_q(con, "
      SELECT c.CL_MED_ABBR, count(*) AS n_codes
      FROM mma_codelist c
      LEFT JOIN mma_rollup r ON c.CL_MED_ABBR = r.CL_MED_ABBR
      WHERE r.CL_MED_ABBR IS NULL
      GROUP BY c.CL_MED_ABBR
      ORDER BY n_codes DESC
    ")
    if (nrow(orphan_meds) > 0) {
      log_msg("  WARNING: Codelist meds NOT in rollup (will have NULL class/flags):")
      print(orphan_meds)
    } else {
      log_msg("  OK: All codelist meds found in rollup.")
    }

    # Reverse check: rollup meds with ZERO codes in codelist (therapy would be
    # completely undetectable - silent drop of an entire medication)
    uncoded_meds <- db_q(con, "
      SELECT r.CL_MED_ABBR, r.CL_MED_CLASS
      FROM mma_rollup r
      LEFT JOIN mma_codelist c ON r.CL_MED_ABBR = c.CL_MED_ABBR
      WHERE c.CL_MED_ABBR IS NULL
      ORDER BY r.CL_MED_CLASS, r.CL_MED_ABBR
    ")
    if (nrow(uncoded_meds) > 0) {
      log_msg("  WARNING: Rollup meds with ZERO codes in codelist (will never be extracted!):")
      print(uncoded_meds)
    } else {
      log_msg("  OK: All rollup meds have at least one code in codelist.")
    }

    # Validate CL_CODE_TYPE values are exactly the expected set
    code_types <- db_q(con, "
      SELECT CL_CODE_TYPE, count(*) AS n_codes
      FROM mma_codelist
      GROUP BY CL_CODE_TYPE
      ORDER BY CL_CODE_TYPE
    ")
    log_msg("  Code type distribution in codelist:")
    print(code_types)
    unexpected_types <- setdiff(code_types$CL_CODE_TYPE, c("NDC", "HCPCS", "ICD"))
    if (length(unexpected_types) > 0) {
      log_msg("  WARNING: Unexpected CL_CODE_TYPE values: ", paste(unexpected_types, collapse = ", "))
      log_msg("  These codes will NOT be matched by the extraction logic!")
    }

    # MED_ABBR mapping to >1 class (min() will hide this)
    multi_class <- db_q(con, "
      SELECT CL_MED_ABBR, count(DISTINCT CL_MED_CLASS) AS n_classes,
             concat_ws(', ', collect_set(CL_MED_CLASS)) AS classes
      FROM mma_codelist
      GROUP BY CL_MED_ABBR
      HAVING count(DISTINCT CL_MED_CLASS) > 1
    ")
    if (nrow(multi_class) > 0) {
      log_msg("  WARNING: MED_ABBR maps to multiple classes (min() will pick one):")
      print(multi_class)
    } else {
      log_msg("  OK: Each MED_ABBR maps to exactly one class.")
    }
  }, error = function(e) {
    log_msg("  WARNING: Codelist consistency QC failed: ", e$message)
  })

  # H4 fix: Codelist minimum-coverage validation (fail-loud)
  # Ensures the loaded codelists meet minimum thresholds so the
  # pipeline never silently runs on incomplete fallback data.
  min_rollup_meds <- 20L    # Tab 40 has 28 unique MED_ABBR; 20 is conservative floor

  min_codelist_codes <- 50L # Tab 41 has hundreds of codes; 50 is conservative floor
  n_rollup <- db_q(con, "SELECT count(DISTINCT CL_MED_ABBR) AS n FROM mma_rollup")$n
  n_codelist <- db_q(con, "SELECT count(*) AS n FROM mma_codelist")$n
  if (n_rollup < min_rollup_meds) {
    stop(glue("CODELIST VALIDATION FAILED: mma_rollup has {n_rollup} unique medications ",
              "(minimum required: {min_rollup_meds}). Check codelist CSV files. ",
              "Pipeline cannot proceed with incomplete medication coverage."))
  }
  if (n_codelist < min_codelist_codes) {
    stop(glue("CODELIST VALIDATION FAILED: mma_codelist has {n_codelist} code entries ",
              "(minimum required: {min_codelist_codes}). Check codelist CSV files. ",
              "Pipeline cannot proceed with incomplete code mappings."))
  }
  log_msg("Codelist validation passed: rollup has ", n_rollup, " meds, codelist has ", n_codelist, " codes.")

  # Fetch med/class lists for dynamic flag generation
  meds <- db_q(con, "SELECT DISTINCT CL_MED_ABBR FROM mma_rollup ORDER BY CL_MED_ABBR")$CL_MED_ABBR
  classes <- db_q(con, "SELECT DISTINCT CL_MED_CLASS FROM mma_rollup ORDER BY CL_MED_CLASS")$CL_MED_CLASS
  if (length(meds) == 0) stop("mma_rollup has 0 medications after load/clean.")
  if (length(classes) == 0) stop("mma_rollup has 0 classes after load/clean.")
  log_msg("Rollup meds: ", paste(meds, collapse = ", "))
  log_msg("Rollup classes: ", paste(classes, collapse = ", "))

  # Dynamic flag expressions
  # Sanitize both med abbreviations and class names for safe SQL column names
  sanitize_col <- function(x) gsub("[^A-Za-z0-9]+", "_", toupper(x))
  med_flag_exprs <- paste0(
    vapply(meds, function(m) glue("max(case when im.MED_ABBR = '{m}' then 1 else 0 end) as LOT1_MED_{sanitize_col(m)}"), character(1)),
    collapse = ",\n      "
  )
  class_flag_exprs <- paste0(
    vapply(classes, function(cl) glue("max(case when im.MED_CLASS = '{cl}' then 1 else 0 end) as LOT1_CLASS_{sanitize_col(cl)}"), character(1)),
    collapse = ",\n      "
  )

  # STEP 1: Load Part 1 cohort
  # OBS_END_DT = observation end for all LOT/MAP logic.
  # Primary analysis (cfg$censor_at_disenrollment = FALSE):
  #   OBS_END_DT = ENDDATE = min(death_dt, study_end).
  #   Disenrollment is NOT a censoring criterion.
  # Sensitivity analysis (cfg$censor_at_disenrollment = TRUE):
  #   OBS_END_DT = coalesce(ENDDATE_CE, ENDDATE), so disenrollment also caps obs.
  # ENDDATE_CE is preserved as a column either way for ad-hoc analyses.
  obs_end_dt_expr <- if (isTRUE(cfg$censor_at_disenrollment)) {
    "coalesce(cast(ENDDATE_CE AS date), cast(ENDDATE AS date))"
  } else {
    "cast(ENDDATE AS date)"
  }
  log_msg("  OBS_END_DT mode:    ",
          if (isTRUE(cfg$censor_at_disenrollment)) "SENSITIVITY (ENDDATE_CE)"
          else "PRIMARY (ENDDATE, disenrollment ignored)")
  run_step(con, "S03_patient_input", glue("
    CREATE OR REPLACE TEMPORARY VIEW lot_patient_input AS
    SELECT
      PATID,
      cast(INDEX_DATE AS date) AS INDEX_DATE,
      cast(ENDDATE AS date)    AS ENDDATE,
      cast(ENDDATE_CE AS date) AS ENDDATE_CE,
      -- OBS_END_DT picked by cfg$censor_at_disenrollment (logged above).
      -- All MAP gap checks, LOT discontinuation confirmation, SCT windows,
      -- and LOT end date logic use this value.
      {obs_end_dt_expr} AS OBS_END_DT,
      cast(DEATH_DT AS date)   AS DEATH_DT,
      GDR_CD,
      YRDOB,
      AGE_INDEX_YR,
      FU_DAYS,
      FU_DAYS_CE
    FROM {wrk(cfg$input_cohort_table)}
  "), qc = "
    SELECT count(*) AS n_patients, min(INDEX_DATE) AS min_index, max(OBS_END_DT) AS max_obs_end,
           sum(case when ENDDATE_CE < ENDDATE then 1 else 0 end) AS n_disenrolled_before_enddate
    FROM lot_patient_input")

  # STEP 2 (5A): MMA_MED - Raw extraction
  # Sources: medical (PROC_CD, BILL_PROC_CD, NDC), rx (NDC)
  # Note: med_procedure excluded - contains ICD procedure codes only, not HCPCS/NDC drug codes
  run_step(con, "S04_mma_med_raw", glue("
    CREATE OR REPLACE TEMPORARY VIEW mma_med_raw AS
    WITH codelist AS (
      SELECT /*+ BROADCAST */ * FROM mma_codelist
    ),
    -- 1) Medical claims - PROC_CD (HCPCS)
    -- Day supply hardcoded to {cfg$medical_day_supply} per spec (5A.MMA_MED row 15)
    med_proc_cd AS (
      SELECT
        m.PATID,
        cast(m.FST_DT AS date) AS DATE_SERVICE,
        {cfg$medical_day_supply} AS DAY_SUPPLY,
        'medical' AS CLAIM_TYPE,
        'med_proc_cd' AS CLAIM_SOURCE,
        c.CL_CODE AS CODE,
        c.CL_CODE_TYPE AS CODE_TYPE,
        c.CL_MED_ABBR AS MED_ABBR,
        c.CL_MED_CLASS AS MED_CLASS
      FROM {cdm_src(cfg$tbl_medical)} m
      INNER JOIN lot_patient_input p ON m.PATID = p.PATID
      INNER JOIN codelist c
        ON c.CL_CODE_TYPE = 'HCPCS'
       AND upper(regexp_replace(coalesce(cast(m.PROC_CD as string),''), '[^A-Za-z0-9]', '')) = c.CL_CODE
      WHERE cast(m.FST_DT AS date) >= p.INDEX_DATE
        AND cast(m.FST_DT AS date) <= p.OBS_END_DT  -- ENDDATE primary; ENDDATE_CE under sensitivity flag
    ),
    -- 2) Medical claims - BILL_PROC_CD (HCPCS)
    med_bill_proc_cd AS (
      SELECT
        m.PATID,
        cast(m.FST_DT AS date) AS DATE_SERVICE,
        {cfg$medical_day_supply} AS DAY_SUPPLY,
        'medical' AS CLAIM_TYPE,
        'med_bill_proc' AS CLAIM_SOURCE,
        c.CL_CODE AS CODE,
        c.CL_CODE_TYPE AS CODE_TYPE,
        c.CL_MED_ABBR AS MED_ABBR,
        c.CL_MED_CLASS AS MED_CLASS
      FROM {cdm_src(cfg$tbl_medical)} m
      INNER JOIN lot_patient_input p ON m.PATID = p.PATID
      INNER JOIN codelist c
        ON c.CL_CODE_TYPE = 'HCPCS'
       AND upper(regexp_replace(coalesce(cast(m.BILL_PROC_CD as string),''), '[^A-Za-z0-9]', '')) = c.CL_CODE
      WHERE cast(m.FST_DT AS date) >= p.INDEX_DATE
        AND cast(m.FST_DT AS date) <= p.OBS_END_DT  -- ENDDATE primary; ENDDATE_CE under sensitivity flag
    ),
    -- 3) Medical claims - NDC field (NDC-coded drug administrations on medical)
    med_ndc AS (
      SELECT
        m.PATID,
        cast(m.FST_DT AS date) AS DATE_SERVICE,
        {cfg$medical_day_supply} AS DAY_SUPPLY,
        'medical' AS CLAIM_TYPE,
        'med_ndc' AS CLAIM_SOURCE,
        c.CL_CODE AS CODE,
        c.CL_CODE_TYPE AS CODE_TYPE,
        c.CL_MED_ABBR AS MED_ABBR,
        c.CL_MED_CLASS AS MED_CLASS
      FROM {cdm_src(cfg$tbl_medical)} m
      INNER JOIN lot_patient_input p ON m.PATID = p.PATID
      INNER JOIN codelist c
        ON c.CL_CODE_TYPE = 'NDC'
       -- Normalize both sides to NDC11 (lpad stripped value to 11 digits with zeros)
       AND lpad(regexp_replace(coalesce(cast(m.NDC as string),''), '[^0-9]', ''), 11, '0')
         = lpad(regexp_replace(c.CL_CODE, '[^0-9]', ''), 11, '0')
      WHERE cast(m.NDC as string) IS NOT NULL AND trim(cast(m.NDC as string)) <> ''
        AND cast(m.FST_DT AS date) >= p.INDEX_DATE
        AND cast(m.FST_DT AS date) <= p.OBS_END_DT  -- ENDDATE primary; ENDDATE_CE under sensitivity flag
    ),
    -- 4) med_procedure table: REMOVED — Optum med_procedure.PROC contains ICD
    -- procedure codes, not HCPCS/NDC drug codes. The MMA codelist only has HCPCS
    -- and NDC codes for medication identification, so matching against ICD procedure
    -- codes is not meaningful. SCT extraction (S12) correctly matches ICD procedure
    -- codes from this table using the SCT codelist.
    -- 5) Pharmacy (rx) claims (NDC)
    rx_claims AS (
      SELECT
        r.PATID,
        cast(r.FILL_DT AS date) AS DATE_SERVICE,
        cast(r.DAYS_SUP AS int) AS DAY_SUPPLY,
        'pharmacy' AS CLAIM_TYPE,
        'rx_ndc' AS CLAIM_SOURCE,
        c.CL_CODE AS CODE,
        c.CL_CODE_TYPE AS CODE_TYPE,
        c.CL_MED_ABBR AS MED_ABBR,
        c.CL_MED_CLASS AS MED_CLASS
      FROM {cdm_src(cfg$tbl_rx)} r
      INNER JOIN lot_patient_input p ON r.PATID = p.PATID
      INNER JOIN codelist c
        ON c.CL_CODE_TYPE = 'NDC'
       -- Normalize both sides to NDC11 (lpad stripped value to 11 digits with zeros)
       AND lpad(regexp_replace(coalesce(cast(r.NDC as string),''), '[^0-9]', ''), 11, '0')
         = lpad(regexp_replace(c.CL_CODE, '[^0-9]', ''), 11, '0')
      WHERE cast(r.FILL_DT AS date) >= p.INDEX_DATE
        AND cast(r.FILL_DT AS date) <= p.OBS_END_DT  -- ENDDATE primary; ENDDATE_CE under sensitivity flag
    )
    SELECT * FROM med_proc_cd
    UNION ALL SELECT * FROM med_bill_proc_cd
    UNION ALL SELECT * FROM med_ndc
    UNION ALL SELECT * FROM rx_claims
  "), qc = "
    SELECT
      count(*) AS n_rows,
      count(DISTINCT PATID) AS n_patients,
      count(DISTINCT MED_ABBR) AS n_meds,
      sum(case when CLAIM_TYPE='pharmacy' then 1 else 0 end) AS n_pharmacy_rows,
      sum(case when CLAIM_TYPE='medical' then 1 else 0 end) AS n_medical_rows,
      -- Source contribution audit (Item 9B: confirms each source path is active)
      sum(case when CLAIM_SOURCE='med_proc_cd' then 1 else 0 end) AS n_from_proc_cd,
      sum(case when CLAIM_SOURCE='med_bill_proc' then 1 else 0 end) AS n_from_bill_proc,
      sum(case when CLAIM_SOURCE='med_ndc' then 1 else 0 end) AS n_from_med_ndc,
      sum(case when CLAIM_SOURCE='rx_ndc' then 1 else 0 end) AS n_from_rx_ndc
    FROM mma_med_raw")

  # Enrich + dedup (mma med.pdf spec)
  run_step(con, "S05_mma_med_processed", glue("
    CREATE OR REPLACE TEMPORARY VIEW mma_med_processed AS
    WITH enriched AS (
      SELECT
        r.PATID,
        r.CODE,
        r.CODE_TYPE,
        r.CLAIM_TYPE,
        r.DATE_SERVICE,
        r.DAY_SUPPLY,
        r.MED_ABBR,
        r.MED_CLASS,
        CASE WHEN coalesce(ru.CONDITIONING,0) = 1 THEN 'Yes' ELSE 'No' END AS MED_COND,
        CASE WHEN coalesce(ru.USED_FOR_OTHER_CANCERS,0) = 1 THEN 'Yes' ELSE 'No' END AS MED_OTHER_CANCER
      FROM mma_med_raw r
      LEFT JOIN mma_rollup ru
        ON r.MED_ABBR = ru.CL_MED_ABBR
    ),
    filtered AS (
      -- C2 fix: Per spec (mmamedapr14) and protocol (Section 5.1.1), pharmacy claims
      -- with missing or anomalous DAY_SUPPLY should be imputed to 28, not dropped.
      SELECT
        PATID, CODE, CODE_TYPE, CLAIM_TYPE, DATE_SERVICE,
        CASE
          WHEN CLAIM_TYPE = 'pharmacy' AND (DAY_SUPPLY IS NULL OR DAY_SUPPLY < 1)
          THEN 28
          ELSE DAY_SUPPLY
        END AS DAY_SUPPLY,
        MED_ABBR, MED_CLASS, MED_COND, MED_OTHER_CANCER
      FROM enriched
    ),
    dedup AS (
      -- Dedup per spec: within (PATID, MED_ABBR, DATE_SERVICE, CLAIM_TYPE)
      -- keep max DAY_SUPPLY (pharmacy) or single row (medical, all 28)
      SELECT
        PATID,
        MED_ABBR,
        DATE_SERVICE,
        CLAIM_TYPE,
        max(DAY_SUPPLY) AS DAY_SUPPLY,
        -- Deterministic dedup: min() for reproducibility across runs
        min(CODE) AS CODE,
        min(CODE_TYPE) AS CODE_TYPE,
        min(MED_CLASS) AS MED_CLASS,
        min(MED_COND) AS MED_COND,
        min(MED_OTHER_CANCER) AS MED_OTHER_CANCER
      FROM filtered
      GROUP BY PATID, MED_ABBR, DATE_SERVICE, CLAIM_TYPE
    )
    SELECT * FROM dedup
  "), qc = "
    SELECT
      count(*) AS n_rows,
      sum(case when CLAIM_TYPE='pharmacy' then 1 else 0 end) AS n_pharmacy_rows,
      sum(case when CLAIM_TYPE='medical' then 1 else 0 end) AS n_medical_rows,
      min(DAY_SUPPLY) AS min_day_supply,
      max(DAY_SUPPLY) AS max_day_supply
    FROM mma_med_processed")

  # Sanity check: after imputation, no pharmacy rows should have invalid DAY_SUPPLY
  bad_ds <- db_q(con, "SELECT count(*) AS n_bad FROM mma_med_processed WHERE CLAIM_TYPE='pharmacy' AND (DAY_SUPPLY IS NULL OR DAY_SUPPLY < 1)")$n_bad
  if (bad_ds > 0) stop(glue("Post-imputation: found {bad_ds} pharmacy rows with invalid DAY_SUPPLY — imputation logic failed."))


  # STEP 3 (5B): MAP_MED - Medication Available Period algorithm
  #
  # CORRECTED per map med.pdf (page 5):
  #   "Medical runout date ... Pushout is not implemented."
  #
  # Pharmacy pushout rules (per Figure 3):
  #   - If new pharmacy claim DATE_SERVICE <= current rx_runout:
  #     pushout = rx_runout - DATE_SERVICE + 1
  #     new rx_runout = DATE_SERVICE + DAY_SUPPLY - 1 + pushout
  #   - If new pharmacy claim DATE_SERVICE > current rx_runout
  #     (but still within MAP via med_runout):
  #     rx_runout RESETS to DATE_SERVICE + DAY_SUPPLY - 1 (NO pushout)
  #
  # Medical: ALWAYS DATE_SERVICE + DAY_SUPPLY - 1 (no pushout ever)
  #
  # MAP boundary: new MAP when DATE_SERVICE > max(rx_runout, med_runout)
  map_struct_type <- "array<struct<MAP_CNT:int,MAP_START_DT:date,MAP_RX_RUNOUT_DT:date,MAP_MED_RUNOUT_DT:date,MAP_END_DT:date>>"
  min_date <- "cast('1900-01-01' as date)"

  run_step(con, "S06_map_med", glue("
    CREATE OR REPLACE TEMPORARY VIEW map_med AS
    WITH claims AS (
      SELECT
        PATID,
        MED_ABBR,
        MED_CLASS,
        DATE_SERVICE AS dt,
        CLAIM_TYPE  AS claim_type,
        cast(DAY_SUPPLY as int) AS ds
      FROM mma_med_processed
    ),
    grouped AS (
      SELECT
        PATID,
        MED_ABBR,
        min(MED_CLASS) AS MED_CLASS,  -- deterministic; should be 1:1 with MED_ABBR via rollup
        -- Sort: by date, then pharmacy before medical on same date (type_ord=0 for rx).
        -- Design choice: pharmacy processed first on same-day ties. This is safe because:
        --   rx pushout only depends on rx_runout (not med_runout),
        --   and medical never has pushout, so order on same day doesn't distort either.
        -- Spec doesn't mandate tie-break order; this choice is documented and deterministic.
        sort_array(collect_list(named_struct(
          'dt', dt,
          'type_ord', case when claim_type='pharmacy' then 0 else 1 end,
          'type', claim_type,
          'ds', ds
        ))) AS claims_arr
      FROM claims
      GROUP BY PATID, MED_ABBR
    ),
    maps AS (
      SELECT
        PATID,
        MED_ABBR,
        MED_CLASS,
        explode(
          aggregate(
            claims_arr,
            -- Accumulator: current MAP state
            named_struct(
              'map_cnt', 0,
              'cur_start', cast(null as date),
              'rx_runout', cast(null as date),
              'med_runout', cast(null as date),
              'maps', cast(array() as {map_struct_type})
            ),
            -- Merge function: process each claim
            (s, x) -> CASE
              -- CASE 1: First claim ever (no current MAP open)
              WHEN s.cur_start IS NULL THEN
                named_struct(
                  'map_cnt', 1,
                  'cur_start', x.dt,
                  'rx_runout', CASE WHEN x.type='pharmacy' THEN date_add(x.dt, x.ds - 1) ELSE NULL END,
                  'med_runout', CASE WHEN x.type='medical' THEN date_add(x.dt, x.ds - 1) ELSE NULL END,
                  'maps', s.maps
                )
              -- CASE 2: Claim beyond both runouts -> close current MAP, start new
              WHEN x.dt > greatest(coalesce(s.rx_runout, {min_date}), coalesce(s.med_runout, {min_date})) THEN
                named_struct(
                  'map_cnt', s.map_cnt + 1,
                  'cur_start', x.dt,
                  'rx_runout', CASE WHEN x.type='pharmacy' THEN date_add(x.dt, x.ds - 1) ELSE NULL END,
                  'med_runout', CASE WHEN x.type='medical' THEN date_add(x.dt, x.ds - 1) ELSE NULL END,
                  'maps', array_append(
                    s.maps,
                    named_struct(
                      'MAP_CNT', s.map_cnt,
                      'MAP_START_DT', s.cur_start,
                      'MAP_RX_RUNOUT_DT', s.rx_runout,
                      'MAP_MED_RUNOUT_DT', s.med_runout,
                      'MAP_END_DT', greatest(coalesce(s.rx_runout, {min_date}), coalesce(s.med_runout, {min_date}))
                    )
                  )
                )
              -- CASE 3: Claim within current MAP -> update runouts
              ELSE
                named_struct(
                  'map_cnt', s.map_cnt,
                  'cur_start', s.cur_start,
                  -- PHARMACY RUNOUT UPDATE
                  'rx_runout', CASE
                    WHEN x.type='pharmacy' THEN
                      CASE
                        -- First pharmacy claim in this MAP
                        WHEN s.rx_runout IS NULL THEN date_add(x.dt, x.ds - 1)
                        -- Pharmacy claim WITHIN current rx coverage -> PUSHOUT
                        -- pushout = rx_runout - DATE_SERVICE + 1
                        -- new rx_runout = DATE_SERVICE + DS - 1 + pushout = rx_runout + DS
                        WHEN x.dt <= s.rx_runout THEN
                          date_add(s.rx_runout, x.ds)
                        -- Pharmacy claim AFTER rx_runout but still in MAP (via med_runout)
                        -- -> RESET without pushout (per Figure 3, iteration 4)
                        ELSE
                          date_add(x.dt, x.ds - 1)
                      END
                    -- Not a pharmacy claim: rx_runout unchanged
                    ELSE s.rx_runout
                  END,
                  -- MEDICAL RUNOUT UPDATE
                  -- Per map med.pdf page 5: Pushout is not implemented for medical.
                  -- Always: DATE_SERVICE + DAY_SUPPLY - 1.
                  -- greatest() is a safety belt: if a same-day or out-of-order claim
                  -- produces an earlier runout, we keep the existing later one.
                  'med_runout', CASE
                    WHEN x.type='medical' THEN
                      CASE
                        WHEN s.med_runout IS NULL THEN date_add(x.dt, x.ds - 1)
                        ELSE greatest(s.med_runout, date_add(x.dt, x.ds - 1))
                      END
                    ELSE s.med_runout
                  END,
                  'maps', s.maps
                )
            END,
            -- Finalize: flush the last open MAP
            s -> CASE
              WHEN s.cur_start IS NULL THEN cast(array() as {map_struct_type})
              ELSE array_append(
                s.maps,
                named_struct(
                  'MAP_CNT', s.map_cnt,
                  'MAP_START_DT', s.cur_start,
                  'MAP_RX_RUNOUT_DT', s.rx_runout,
                  'MAP_MED_RUNOUT_DT', s.med_runout,
                  'MAP_END_DT', greatest(coalesce(s.rx_runout, {min_date}), coalesce(s.med_runout, {min_date}))
                )
              )
            END
          )
        ) AS map_rec
      FROM grouped
    ),
    base AS (
      SELECT
        m.PATID,
        m.MED_ABBR,
        m.MED_CLASS,
        map_rec.MAP_CNT           AS MAP_CNT,
        map_rec.MAP_START_DT      AS MAP_START_DT,
        map_rec.MAP_RX_RUNOUT_DT  AS MAP_RX_RUNOUT_DT,
        map_rec.MAP_MED_RUNOUT_DT AS MAP_MED_RUNOUT_DT,
        CASE WHEN map_rec.MAP_END_DT = {min_date} THEN NULL ELSE map_rec.MAP_END_DT END AS MAP_END_DT
      FROM maps m
    ),
    with_next AS (
      SELECT
        b.*,
        lead(MAP_START_DT) OVER (PARTITION BY PATID, MED_ABBR ORDER BY MAP_CNT) AS NEXT_MAP_START_DT
      FROM base b
    )
    SELECT
      w.PATID,
      w.MED_ABBR,
      w.MED_CLASS,
      w.MAP_CNT,
      w.MAP_START_DT,
      w.MAP_RX_RUNOUT_DT,
      w.MAP_MED_RUNOUT_DT,
      w.MAP_END_DT,
      w.MED_ABBR AS MAP_MED_TYPE,
      w.MED_CLASS AS MAP_MED_CLASS,
      CASE
        WHEN w.NEXT_MAP_START_DT IS NOT NULL
          AND datediff(w.NEXT_MAP_START_DT, w.MAP_END_DT) >= {cfg$map_discon_gap_days}
          THEN 1
        WHEN w.NEXT_MAP_START_DT IS NULL
          AND datediff(p.OBS_END_DT, w.MAP_END_DT) >= {cfg$map_discon_gap_days}
          THEN 1
        ELSE 0
      END AS MAP_DISCON_FLG
    FROM with_next w
    INNER JOIN lot_patient_input p ON w.PATID = p.PATID
    WHERE w.MAP_END_DT IS NOT NULL
  "), qc = "
    SELECT
      count(*) AS n_maps,
      count(DISTINCT PATID) AS n_patients,
      count(DISTINCT MED_ABBR) AS n_meds,
      avg(datediff(MAP_END_DT, MAP_START_DT) + 1) AS avg_map_len_days,
      sum(MAP_DISCON_FLG) AS n_discontinuations
    FROM map_med")

  # STEP 4: MAP_STACKED
  run_step(con, "S07_map_stacked", "
    CREATE OR REPLACE TEMPORARY VIEW map_stacked AS
    SELECT * FROM map_med
  ", qc = "SELECT count(*) AS n_rows FROM map_stacked")

  # STEP 5 (6): LOT1_BASE
  run_step(con, "S08_lot1_start", "
    CREATE OR REPLACE TEMPORARY VIEW lot1_start AS
    SELECT
      ms.PATID,
      min(ms.MAP_START_DT) AS LOT1_START_DT
    FROM map_stacked ms
    WHERE ms.MAP_MED_CLASS <> 'STEROID'
    GROUP BY ms.PATID
  ", qc = "SELECT count(*) AS n_patients_with_lot1, min(LOT1_START_DT) AS min_lot1_start, max(LOT1_START_DT) AS max_lot1_start FROM lot1_start")

  run_step(con, "S09_lot1_induction_meds", glue("
    CREATE OR REPLACE TEMPORARY VIEW lot1_induction_meds AS
    SELECT DISTINCT
      ms.PATID,
      l1.LOT1_START_DT,
      ms.MAP_MED_TYPE AS MED_ABBR,
      ms.MAP_MED_CLASS AS MED_CLASS
    FROM map_stacked ms
    INNER JOIN lot1_start l1
      ON ms.PATID = l1.PATID
    WHERE ms.MAP_START_DT >= l1.LOT1_START_DT
      AND ms.MAP_START_DT <= date_add(l1.LOT1_START_DT, {cfg$induction_window_days - 1})
      AND ms.MAP_MED_CLASS <> 'STEROID'  -- H1 fix: exclude steroids per protocol Section 5.1.1
  "), qc = "
    SELECT count(*) AS n_rows, count(DISTINCT PATID) AS n_patients, avg(cnt) AS avg_induction_meds
    FROM (SELECT PATID, count(DISTINCT MED_ABBR) AS cnt FROM lot1_induction_meds GROUP BY PATID)")

  # LOT1 BASE: induction meds + permissible subs, discon, first add
  run_step(con, "S10_lot1_base", glue("
    CREATE OR REPLACE TEMPORARY VIEW lot1_base AS
    WITH base_meds AS (
      SELECT PATID, MED_ABBR
      FROM lot1_induction_meds
      UNION
      SELECT im.PATID, ps.substitute_med AS MED_ABBR
      FROM lot1_induction_meds im
      INNER JOIN permissible_subs ps
        ON im.MED_ABBR = ps.original_med
    ),
    -- H1 fix: Steroids are now excluded from base_meds (via lot1_induction_meds filter)
    -- per protocol Section 5.1.1: corticosteroids are not oncology agents and should
    -- not drive regimen membership, discontinuation, or add-med logic.
    discon_raw AS (
      SELECT
        ms.PATID,
        max(ms.MAP_END_DT) AS RAW_DISCON_DT
      FROM map_stacked ms
      INNER JOIN lot1_start l1 ON ms.PATID = l1.PATID
      INNER JOIN base_meds bm
        ON ms.PATID = bm.PATID
       AND ms.MAP_MED_TYPE = bm.MED_ABBR
      WHERE ms.MAP_START_DT >= l1.LOT1_START_DT
      GROUP BY ms.PATID
    ),
    discon AS (
      SELECT
        p.PATID,
        -- Q1 (06-May): no LOT-level 90d confirmation buffer. LOT1_BASE_DISCON_DT
        -- is the last med date (max MAP_END_DT across induction agents) whenever
        -- a runout exists and falls on or before OBS_END_DT. Capping at OBS_END_DT
        -- prevents days-supply tails past death/study_end from extending the LOT.
        CASE
          WHEN d.RAW_DISCON_DT IS NOT NULL AND d.RAW_DISCON_DT <= p.OBS_END_DT
            THEN d.RAW_DISCON_DT
          ELSE NULL
        END AS LOT1_BASE_DISCON_DT
      FROM lot_patient_input p
      LEFT JOIN discon_raw d ON p.PATID = d.PATID
    ),
    med_summary AS (
      SELECT
        im.PATID,
        min(im.LOT1_START_DT) AS LOT1_START_DT,  -- same for all rows per PATID; min for determinism
        count(DISTINCT im.MED_ABBR) AS LOT1_MED_CNT,
        concat_ws(' ', sort_array(collect_set(im.MED_ABBR))) AS LOT1_BASE_MEDS,
        {med_flag_exprs},
        {class_flag_exprs}
      FROM lot1_induction_meds im
      GROUP BY im.PATID
    ),
    base_core AS (
      SELECT
        p.PATID,
        p.INDEX_DATE,
        p.ENDDATE,
        p.OBS_END_DT,
        p.DEATH_DT,
        p.GDR_CD,
        p.YRDOB,
        p.AGE_INDEX_YR,
        ms.LOT1_START_DT,
        ms.LOT1_MED_CNT,
        ms.LOT1_BASE_MEDS,
        d.LOT1_BASE_DISCON_DT,
        {paste0('ms.', paste(c(paste0('LOT1_MED_', vapply(meds, sanitize_col, character(1))), paste0('LOT1_CLASS_', vapply(classes, sanitize_col, character(1)))), collapse = ', ms.'))}
      FROM lot_patient_input p
      INNER JOIN med_summary ms ON p.PATID = ms.PATID
      LEFT JOIN discon d ON p.PATID = d.PATID
    ),
    first_add_candidates AS (
      SELECT
        ms.PATID,
        ms.MAP_START_DT,
        ms.MAP_MED_TYPE
      FROM map_stacked ms
      INNER JOIN base_core bc ON ms.PATID = bc.PATID
      LEFT JOIN base_meds bm
        ON ms.PATID = bm.PATID AND ms.MAP_MED_TYPE = bm.MED_ABBR
      WHERE bm.MED_ABBR IS NULL
        AND ms.MAP_MED_CLASS <> 'STEROID'  -- H1 fix: steroids cannot trigger add-med
        AND ms.MAP_START_DT >= bc.LOT1_START_DT
        AND ms.MAP_START_DT <= coalesce(bc.LOT1_BASE_DISCON_DT, bc.OBS_END_DT)
    ),
    first_add_pick AS (
      -- Spec: when multiple non-induction drugs share the earliest add date,
      -- pick one at random with a fixed seed. rand(42) is deterministic
      -- across runs, so the pick is reproducible but not alphabetically
      -- biased the way min() was.
      SELECT PATID, LOT1_BASE_1ST_ADD_MED_DT, LOT1_BASE_1ST_ADD_MED
      FROM (
        SELECT
          PATID,
          date_sub(MAP_START_DT, 1) AS LOT1_BASE_1ST_ADD_MED_DT,
          MAP_MED_TYPE              AS LOT1_BASE_1ST_ADD_MED,
          row_number() OVER (
            PARTITION BY PATID
            ORDER BY MAP_START_DT, rand(42)
          ) AS rn
        FROM first_add_candidates
      ) ranked
      WHERE rn = 1
    )
    SELECT
      bc.PATID, bc.INDEX_DATE, bc.ENDDATE, bc.OBS_END_DT, bc.DEATH_DT,
      bc.GDR_CD, bc.YRDOB, bc.AGE_INDEX_YR,
      bc.LOT1_START_DT, bc.LOT1_MED_CNT, bc.LOT1_BASE_MEDS,
      bc.LOT1_BASE_DISCON_DT,
      -- M1 fix: LOT1_BASE_LENGTH moved to S16 where LOT1_BASE_END_DT is finalized.
      -- This aligns with the spec's 2-way formula using the derived end date.
      {paste0('bc.', paste(c(paste0('LOT1_MED_', vapply(meds, sanitize_col, character(1))), paste0('LOT1_CLASS_', vapply(classes, sanitize_col, character(1)))), collapse = ', bc.'))},
      fa.LOT1_BASE_1ST_ADD_MED_DT,
      fa.LOT1_BASE_1ST_ADD_MED
    FROM base_core bc
    LEFT JOIN first_add_pick fa
      ON bc.PATID = fa.PATID
  "), qc = "
    SELECT
      count(*) AS n_patients,
      avg(LOT1_MED_CNT) AS avg_induction_meds,
      sum(case when LOT1_BASE_DISCON_DT is not null then 1 else 0 end) as n_with_discon_dt,
      sum(case when LOT1_BASE_1ST_ADD_MED_DT is not null then 1 else 0 end) as n_with_add_med
    FROM lot1_base")


  # STEP 7 (SCT): Stem Cell Transplant detection
  # Per sct.pdf spec section 7:
  #   - AUTO: 14-day window grouping + 60-day gap + 180-day tandem
  #   - ALLO/CART: simple sequential dates
  #   - ALLO/CART immediately end LOT1
  #   - Single AUTO allowed; tandem pair allowed; excess AUTO ends LOT1
  #
  # NOTE: Apr 19 spec makes maintenance a descriptive flag only (contains_mtx_reg,
  # derived in S16b). There is no standalone maintenance-period view anymore.

  # S11: Register SCT codelist
  # Normalize CL_CODE_TYPE to canonical values:
  #   ICD10PROC / ICD10PCS            -> 'ICD10PROC' (matches med_procedure.PROC with ICD_FLAG=10)
  #   ICD9PROC                        -> 'ICD9PROC'  (matches med_procedure.PROC with ICD_FLAG=9)
  #   ICD10DIAG / ICD10DX             -> 'ICD10DIAG' (matches med_diagnosis.DIAG with ICD_FLAG=10)
  #   ICD9DIAG / ICD9DX               -> 'ICD9DIAG'  (matches med_diagnosis.DIAG with ICD_FLAG=9)
  #   HCPCS                           -> 'HCPCS'     (matches medical.PROC_CD)
  # Normalize SCT_TYPE: Allogenic->ALLO, Autologous->AUTO, CAR-T->CART
  run_step(con, "S11_sct_codelist", glue("
    CREATE OR REPLACE TEMPORARY VIEW sct_codelist AS
    SELECT
      CASE
        WHEN upper(trim(CL_CODE_TYPE)) IN ('ICD10PROC', 'ICD10PCS') THEN 'ICD10PROC'
        WHEN upper(trim(CL_CODE_TYPE)) = 'ICD9PROC' THEN 'ICD9PROC'
        WHEN upper(trim(CL_CODE_TYPE)) LIKE '%PROC%'
          OR upper(trim(CL_CODE_TYPE)) = 'ICD' THEN 'ICD10PROC'
        WHEN upper(trim(CL_CODE_TYPE)) IN ('ICD10DIAG', 'ICD10DX', 'DIAG10')
          OR upper(trim(CL_CODE_TYPE)) LIKE 'ICD%10%DIAG%' THEN 'ICD10DIAG'
        WHEN upper(trim(CL_CODE_TYPE)) IN ('ICD9DIAG', 'ICD9DX', 'ICD9', 'DIAG9')
          OR upper(trim(CL_CODE_TYPE)) LIKE 'ICD%9%DIAG%' THEN 'ICD9DIAG'
        WHEN upper(trim(CL_CODE_TYPE)) IN ('DIAG', 'DX', 'DIAGNOSIS') THEN 'ICD10DIAG'
        WHEN upper(trim(CL_CODE_TYPE)) IN ('CPT', 'CPT4') THEN 'HCPCS'
        ELSE upper(trim(CL_CODE_TYPE))
      END AS CL_CODE_TYPE,
      upper(regexp_replace(trim(CL_CODE), '[^A-Za-z0-9]', '')) AS CL_CODE,
      CASE
        WHEN upper(trim(SCT_TYPE)) LIKE 'ALLO%' THEN 'ALLO'
        WHEN upper(trim(SCT_TYPE)) LIKE 'AUTO%' THEN 'AUTO'
        WHEN upper(trim(SCT_TYPE)) IN ('CAR-T', 'CART', 'CAR_T') THEN 'CART'
        WHEN upper(trim(SCT_TYPE)) IN ('UNKNOWN', 'UNK', 'OTHER', 'SCT', 'HSCT',
                                        'HCT', 'STEM CELL', 'TRANSPLANT', 'BMT')
          THEN 'UNKNOWN'
        ELSE upper(trim(SCT_TYPE))
      END AS SCT_TYPE
    FROM {sct_src}
    WHERE CL_CODE IS NOT NULL AND trim(CL_CODE) <> ''
      AND SCT_TYPE IS NOT NULL AND trim(SCT_TYPE) <> ''
  "), qc = "SELECT SCT_TYPE, CL_CODE_TYPE, count(*) AS n_codes FROM sct_codelist GROUP BY SCT_TYPE, CL_CODE_TYPE ORDER BY SCT_TYPE, CL_CODE_TYPE")

  # S12: Extract raw SCT claims from MEDICAL + MED_PROCEDURE
  run_step(con, "S12_sct_claims_raw", glue("
    CREATE OR REPLACE TEMPORARY VIEW sct_claims_raw AS
    WITH sct_codes AS (
      SELECT /*+ BROADCAST */ * FROM sct_codelist
    ),
    -- Medical PROC_CD (contains CPT/HCPCS per Optum business rules)
    med_proc AS (
      SELECT m.PATID, cast(m.FST_DT AS date) AS DATE_SERVICE,
             s.SCT_TYPE, s.CL_CODE AS CODE, 'med_proc_cd' AS SRC
      FROM {cdm_src(cfg$tbl_medical)} m
      INNER JOIN lot_patient_input p ON m.PATID = p.PATID
      INNER JOIN sct_codes s
        ON s.CL_CODE_TYPE = 'HCPCS'
       AND upper(regexp_replace(coalesce(cast(m.PROC_CD as string),''), '[^A-Za-z0-9]', '')) = s.CL_CODE
      WHERE cast(m.FST_DT AS date) >= p.INDEX_DATE
        AND cast(m.FST_DT AS date) <= p.OBS_END_DT
    ),
    -- Medical BILL_PROC_CD (also CPT/HCPCS per Optum business rules)
    med_bill AS (
      SELECT m.PATID, cast(m.FST_DT AS date) AS DATE_SERVICE,
             s.SCT_TYPE, s.CL_CODE AS CODE, 'med_bill_proc' AS SRC
      FROM {cdm_src(cfg$tbl_medical)} m
      INNER JOIN lot_patient_input p ON m.PATID = p.PATID
      INNER JOIN sct_codes s
        ON s.CL_CODE_TYPE = 'HCPCS'
       AND upper(regexp_replace(coalesce(cast(m.BILL_PROC_CD as string),''), '[^A-Za-z0-9]', '')) = s.CL_CODE
      WHERE cast(m.FST_DT AS date) >= p.INDEX_DATE
        AND cast(m.FST_DT AS date) <= p.OBS_END_DT
    ),
    -- MED_PROCEDURE PROC (ICD-9/ICD-10 procedure codes + HCPCS safety net)
    medproc AS (
      SELECT mp.PATID, cast(mp.FST_DT AS date) AS DATE_SERVICE,
             s.SCT_TYPE, s.CL_CODE AS CODE, 'med_procedure' AS SRC
      FROM {cdm_src(cfg$tbl_med_proc)} mp
      INNER JOIN lot_patient_input p ON mp.PATID = p.PATID
      INNER JOIN sct_codes s
        ON (  (s.CL_CODE_TYPE = 'ICD10PROC'
               AND coalesce(upper(mp.ICD_FLAG), '') NOT IN ('9', 'ICD9', 'ICD-9'))
           OR (s.CL_CODE_TYPE = 'ICD9PROC'
               AND upper(mp.ICD_FLAG) IN ('9', 'ICD9', 'ICD-9'))
           OR s.CL_CODE_TYPE = 'HCPCS'
           )
       AND upper(regexp_replace(coalesce(cast(mp.PROC as string),''), '[^A-Za-z0-9]', '')) = s.CL_CODE
      WHERE cast(mp.FST_DT AS date) >= p.INDEX_DATE
        AND cast(mp.FST_DT AS date) <= p.OBS_END_DT
    ),
    -- MED_DIAGNOSIS DIAG (ICD-10/ICD-9 diagnosis codes)
    med_diag AS (
      SELECT d.PATID, cast(d.FST_DT AS date) AS DATE_SERVICE,
             s.SCT_TYPE, s.CL_CODE AS CODE, 'med_diagnosis' AS SRC
      FROM {cdm_src(cfg$tbl_med_diag)} d
      INNER JOIN lot_patient_input p ON d.PATID = p.PATID
      INNER JOIN sct_codes s
        ON (  (s.CL_CODE_TYPE = 'ICD10DIAG'
               AND coalesce(upper(d.ICD_FLAG), '') NOT IN ('9', 'ICD9', 'ICD-9'))
           OR (s.CL_CODE_TYPE = 'ICD9DIAG'
               AND upper(d.ICD_FLAG) IN ('9', 'ICD9', 'ICD-9'))
           )
       AND upper(regexp_replace(coalesce(cast(d.DIAG as string),''), '[^A-Za-z0-9]', '')) = s.CL_CODE
      WHERE cast(d.FST_DT AS date) >= p.INDEX_DATE
        AND cast(d.FST_DT AS date) <= p.OBS_END_DT
    ),
    combined AS (
      SELECT * FROM med_proc
      UNION ALL SELECT * FROM med_bill
      UNION ALL SELECT * FROM medproc
      UNION ALL SELECT * FROM med_diag
    )
    -- Deduplicate: one record per (PATID, DATE_SERVICE, SCT_TYPE)
    SELECT PATID, DATE_SERVICE, SCT_TYPE, min(CODE) AS CODE
    FROM combined
    GROUP BY PATID, DATE_SERVICE, SCT_TYPE
  "), qc = "
    SELECT SCT_TYPE, count(*) AS n_claims, count(DISTINCT PATID) AS n_patients,
           min(DATE_SERVICE) AS min_date, max(DATE_SERVICE) AS max_date
    FROM sct_claims_raw
    GROUP BY SCT_TYPE
    ORDER BY SCT_TYPE")

  # NOTE: SCT CTEs include SRC column for debug traceability (dropped during dedup).
  # To audit source contributions, query the combined CTE directly before dedup.


  # S13: AUTO SCT date processing (per sct.pdf)
  #
  # Step 1: Group AUTO claims into 14-day windows (claims within 14 days of
  #         window start are in same window). Per spec, select the LAST (max)
  #         date in each window, NOT the first -- first claims are workup
  #         activity, last claim is the actual transplant.
  #
  # Tandem boundary adjustment: when a 14-day window overlaps the 180-day
  # tandem boundary (from the previous finalized TX date), select the date
  # closest to the boundary rather than the window max. This ensures accurate
  # tandem determination. Computed as min |date - boundary| over all dates
  # in the window. (See sct.pdf example: TX_AUTO1=09MAY2018, 180-day mark
  # ~05NOV2018, window 06NOV-20NOV picks 07NOV instead of 20NOV.)
  #
  # Step 2: Apply 60-day minimum gap between events (merge if < 60 days apart).
  # Result: finalized TX dates for AUTO SCT per patient.
  run_step(con, "S13_tx_auto_dates", glue("
    CREATE OR REPLACE TEMPORARY VIEW tx_auto_dates AS
    WITH auto_dates AS (
      SELECT DISTINCT PATID, DATE_SERVICE AS dt
      FROM sct_claims_raw
      WHERE SCT_TYPE = 'AUTO'
    ),
    grouped AS (
      SELECT PATID,
             sort_array(collect_list(dt)) AS dates_arr
      FROM auto_dates
      GROUP BY PATID
    ),
    -- Phase 1 + 2 combined: 14-day windowing with tandem-aware date selection
    -- + 60-day gap merging in a single pass.
    --
    -- State tracks:
    --   tx_dates: finalized TX dates array
    --   cur_start: start of current 14-day window (first date in window)
    --   cur_max_dt: last (max) date in current window (default selection)
    --   cur_boundary_dt: date in window closest to tandem boundary
    --   cur_boundary_dist: abs distance of cur_boundary_dt to tandem boundary
    --   last_tx_dt: last finalized TX date (for tandem boundary + 60-day gap)
    processed AS (
      SELECT PATID,
        aggregate(
          dates_arr,
          named_struct(
            'tx_dates', cast(array() as array<date>),
            'cur_start', cast(null as date),
            'cur_max_dt', cast(null as date),
            'cur_boundary_dt', cast(null as date),
            'cur_boundary_dist', cast(null as int),
            'last_tx_dt', cast(null as date)
          ),
          (s, x) -> CASE
            -- First claim ever: start first window
            WHEN s.cur_start IS NULL THEN
              named_struct(
                'tx_dates', s.tx_dates,
                'cur_start', x,
                'cur_max_dt', x,
                'cur_boundary_dt', cast(null as date),
                'cur_boundary_dist', cast(null as int),
                'last_tx_dt', s.last_tx_dt
              )
            -- Within 14-day window: update max + tandem boundary tracking
            WHEN datediff(x, s.cur_start) <= {cfg$sct_auto_window_days} THEN
              named_struct(
                'tx_dates', s.tx_dates,
                'cur_start', s.cur_start,
                'cur_max_dt', x,  -- x >= cur_max_dt since sorted
                -- Track date closest to tandem boundary, BUT only when date is
                -- within window_days of the boundary (i.e., window overlaps or
                -- is adjacent to the 180-day mark). When far from boundary,
                -- cur_boundary_dt stays NULL so coalesce() falls back to max.
                'cur_boundary_dt', CASE
                  WHEN s.last_tx_dt IS NULL THEN NULL
                  WHEN abs(datediff(x, date_add(s.last_tx_dt, {cfg$sct_tandem_days} - 1)))
                       <= {cfg$sct_auto_window_days}
                   AND (s.cur_boundary_dist IS NULL
                        OR abs(datediff(x, date_add(s.last_tx_dt, {cfg$sct_tandem_days} - 1)))
                           < s.cur_boundary_dist)
                    THEN x
                  WHEN s.cur_boundary_dt IS NOT NULL THEN s.cur_boundary_dt
                  ELSE NULL
                END,
                'cur_boundary_dist', CASE
                  WHEN s.last_tx_dt IS NULL THEN NULL
                  WHEN abs(datediff(x, date_add(s.last_tx_dt, {cfg$sct_tandem_days} - 1)))
                       <= {cfg$sct_auto_window_days}
                   AND (s.cur_boundary_dist IS NULL
                        OR abs(datediff(x, date_add(s.last_tx_dt, {cfg$sct_tandem_days} - 1)))
                           < s.cur_boundary_dist)
                    THEN abs(datediff(x, date_add(s.last_tx_dt, {cfg$sct_tandem_days} - 1)))
                  WHEN s.cur_boundary_dist IS NOT NULL THEN s.cur_boundary_dist
                  ELSE NULL
                END,
                'last_tx_dt', s.last_tx_dt
              )
            -- Beyond 14-day window: finalize current window, start new
            ELSE
              -- Select date: use boundary-closest if tandem boundary active, else max
              -- Then apply 60-day gap: only keep if >= 60 days from last_tx_dt
              CASE
                WHEN s.last_tx_dt IS NOT NULL
                 AND datediff(
                       coalesce(s.cur_boundary_dt, s.cur_max_dt),
                       s.last_tx_dt
                     ) < {cfg$sct_auto_gap_days}
                THEN
                  -- Too close to last TX: discard window, start new
                  named_struct(
                    'tx_dates', s.tx_dates,
                    'cur_start', x,
                    'cur_max_dt', x,
                    -- Only init boundary tracking if x is near the boundary
                    'cur_boundary_dt', CASE
                      WHEN s.last_tx_dt IS NOT NULL
                       AND abs(datediff(x, date_add(s.last_tx_dt, {cfg$sct_tandem_days} - 1)))
                           <= {cfg$sct_auto_window_days}
                      THEN x
                      ELSE NULL
                    END,
                    'cur_boundary_dist', CASE
                      WHEN s.last_tx_dt IS NOT NULL
                       AND abs(datediff(x, date_add(s.last_tx_dt, {cfg$sct_tandem_days} - 1)))
                           <= {cfg$sct_auto_window_days}
                      THEN abs(datediff(x, date_add(s.last_tx_dt, {cfg$sct_tandem_days} - 1)))
                      ELSE NULL
                    END,
                    'last_tx_dt', s.last_tx_dt
                  )
                ELSE
                  -- Valid TX: finalize and start new window
                  named_struct(
                    'tx_dates', array_append(
                      s.tx_dates,
                      coalesce(s.cur_boundary_dt, s.cur_max_dt)
                    ),
                    'cur_start', x,
                    'cur_max_dt', x,
                    -- Init boundary tracking relative to newly finalized TX
                    'cur_boundary_dt', CASE
                      WHEN abs(datediff(
                             x,
                             date_add(coalesce(s.cur_boundary_dt, s.cur_max_dt), {cfg$sct_tandem_days} - 1)
                           )) <= {cfg$sct_auto_window_days}
                      THEN x
                      ELSE NULL
                    END,
                    'cur_boundary_dist', CASE
                      WHEN abs(datediff(
                             x,
                             date_add(coalesce(s.cur_boundary_dt, s.cur_max_dt), {cfg$sct_tandem_days} - 1)
                           )) <= {cfg$sct_auto_window_days}
                      THEN abs(datediff(
                             x,
                             date_add(coalesce(s.cur_boundary_dt, s.cur_max_dt), {cfg$sct_tandem_days} - 1)
                           ))
                      ELSE NULL
                    END,
                    'last_tx_dt', coalesce(s.cur_boundary_dt, s.cur_max_dt)
                  )
                END
          END,
          -- Finalize: flush last open window
          s -> CASE
            WHEN s.cur_start IS NULL THEN s.tx_dates
            -- Apply 60-day gap check for last window
            WHEN s.last_tx_dt IS NOT NULL
             AND datediff(
                   coalesce(s.cur_boundary_dt, s.cur_max_dt),
                   s.last_tx_dt
                 ) < {cfg$sct_auto_gap_days}
            THEN s.tx_dates
            ELSE array_append(
              s.tx_dates,
              coalesce(s.cur_boundary_dt, s.cur_max_dt)
            )
          END
        ) AS tx_dates
      FROM grouped
    ),
    exploded AS (
      SELECT PATID, posexplode(tx_dates) AS (pos, TX_DT)
      FROM processed
    )
    SELECT PATID, pos + 1 AS TX_SEQ, TX_DT
    FROM exploded
  "), qc = "
    SELECT count(*) AS n_auto_tx_events, count(DISTINCT PATID) AS n_patients,
           min(TX_SEQ) AS min_seq, max(TX_SEQ) AS max_seq
    FROM tx_auto_dates")

  # S14: ALLO and CART sequential dates (simple ordering)
  run_step(con, "S14_tx_allo_cart_dates", "
    CREATE OR REPLACE TEMPORARY VIEW tx_allo_cart_dates AS
    WITH allo_dates AS (
      SELECT DISTINCT PATID, DATE_SERVICE AS dt
      FROM sct_claims_raw
      WHERE SCT_TYPE = 'ALLO'
    ),
    cart_dates AS (
      SELECT DISTINCT PATID, DATE_SERVICE AS dt
      FROM sct_claims_raw
      WHERE SCT_TYPE = 'CART'
    ),
    allo_seq AS (
      SELECT PATID, 'ALLO' AS SCT_TYPE, dt AS TX_DT,
             row_number() OVER (PARTITION BY PATID ORDER BY dt) AS TX_SEQ
      FROM allo_dates
    ),
    cart_seq AS (
      SELECT PATID, 'CART' AS SCT_TYPE, dt AS TX_DT,
             row_number() OVER (PARTITION BY PATID ORDER BY dt) AS TX_SEQ
      FROM cart_dates
    )
    SELECT * FROM allo_seq
    UNION ALL
    SELECT * FROM cart_seq
  ", qc = "
    SELECT SCT_TYPE, count(*) AS n_events, count(DISTINCT PATID) AS n_patients
    FROM tx_allo_cart_dates
    GROUP BY SCT_TYPE
    ORDER BY SCT_TYPE")


  # S15: LOT1 SCT variables
  # Derives: LOT1_TX_AUTO_DT_1/2, TAND_FLG, SING_FLG,
  #          LOT1_TX_ENDDATE, LOT1_TX_ENDDATE_REASON, LOT1_1ST_SCT_DT
  run_step(con, "S15_lot1_sct", glue("
    CREATE OR REPLACE TEMPORARY VIEW lot1_sct AS
    WITH lot1 AS (
      SELECT PATID, LOT1_START_DT, OBS_END_DT FROM lot1_base
    ),
    -- AUTO dates within LOT1 observation window
    -- Censored at earliest ALLO/CART: ALLO and CART immediately end LOT1,
    -- so AUTO events after an ALLO/CART are not relevant to LOT1.
    earliest_non_auto AS (
      SELECT ac.PATID, min(ac.TX_DT) AS FIRST_NON_AUTO_DT
      FROM tx_allo_cart_dates ac
      INNER JOIN lot1 l ON ac.PATID = l.PATID
      WHERE ac.SCT_TYPE IN ('ALLO', 'CART')
        AND ac.TX_DT >= l.LOT1_START_DT
        AND ac.TX_DT <= l.OBS_END_DT
      GROUP BY ac.PATID
    ),
    auto_in_lot1 AS (
      SELECT a.PATID, a.TX_DT,
             row_number() OVER (PARTITION BY a.PATID ORDER BY a.TX_DT) AS LOT1_SEQ
      FROM tx_auto_dates a
      INNER JOIN lot1 l ON a.PATID = l.PATID
      LEFT JOIN earliest_non_auto ena ON a.PATID = ena.PATID
      WHERE a.TX_DT >= l.LOT1_START_DT
        AND a.TX_DT <= l.OBS_END_DT
        AND (ena.FIRST_NON_AUTO_DT IS NULL OR a.TX_DT < ena.FIRST_NON_AUTO_DT)
    ),
    auto_pivot AS (
      SELECT PATID,
        max(CASE WHEN LOT1_SEQ = 1 THEN TX_DT END) AS AUTO_DT_1,
        max(CASE WHEN LOT1_SEQ = 2 THEN TX_DT END) AS AUTO_DT_2,
        max(CASE WHEN LOT1_SEQ = 3 THEN TX_DT END) AS AUTO_DT_3
      FROM auto_in_lot1
      GROUP BY PATID
    ),
    -- First ALLO date within LOT1
    first_allo AS (
      SELECT ac.PATID, min(ac.TX_DT) AS ALLO_DT
      FROM tx_allo_cart_dates ac
      INNER JOIN lot1 l ON ac.PATID = l.PATID
      WHERE ac.SCT_TYPE = 'ALLO'
        AND ac.TX_DT >= l.LOT1_START_DT
        AND ac.TX_DT <= l.OBS_END_DT
      GROUP BY ac.PATID
    ),
    -- First CART date within LOT1
    first_cart AS (
      SELECT ac.PATID, min(ac.TX_DT) AS CART_DT
      FROM tx_allo_cart_dates ac
      INNER JOIN lot1 l ON ac.PATID = l.PATID
      WHERE ac.SCT_TYPE = 'CART'
        AND ac.TX_DT >= l.LOT1_START_DT
        AND ac.TX_DT <= l.OBS_END_DT
      GROUP BY ac.PATID
    ),
    -- Check for ALLO between AUTO_DT_1 and AUTO_DT_2 (inclusive, per spec)
    -- Spec: tandem disqualified if ALLO exists such that AUTO_DT_1 <= ALLO <= AUTO_DT_2
    allo_between AS (
      SELECT ap.PATID,
        sum(CASE WHEN ac.TX_DT >= ap.AUTO_DT_1 AND ac.TX_DT <= ap.AUTO_DT_2
                 THEN 1 ELSE 0 END) AS n_allo_between
      FROM auto_pivot ap
      LEFT JOIN tx_allo_cart_dates ac
        ON ap.PATID = ac.PATID AND ac.SCT_TYPE = 'ALLO'
      WHERE ap.AUTO_DT_2 IS NOT NULL
      GROUP BY ap.PATID
    ),
    -- Derive tandem flag and LOT-ending AUTO date
    sct_derived AS (
      SELECT
        l.PATID,
        ap.AUTO_DT_1 AS LOT1_TX_AUTO_DT_1,
        ap.AUTO_DT_2 AS LOT1_TX_AUTO_DT_2,
        -- Tandem: two AUTO SCTs within 180 days, no ALLO between
        CASE
          WHEN ap.AUTO_DT_2 IS NOT NULL
           AND datediff(ap.AUTO_DT_2, ap.AUTO_DT_1) <= {cfg$sct_tandem_days}  -- Tandem if AUTO_DT_2 is within sct_tandem_days (180d) of AUTO_DT_1; no +1 (Q9 resolved 13-May)
           AND coalesce(ab.n_allo_between, 0) = 0
          THEN 1 ELSE 0
        END AS LOT1_SCT_AUTO_TAND_FLG,
        -- Single AUTO: has first AUTO but not a valid tandem
        CASE
          WHEN ap.AUTO_DT_1 IS NOT NULL
           AND NOT (ap.AUTO_DT_2 IS NOT NULL
                    AND datediff(ap.AUTO_DT_2, ap.AUTO_DT_1) <= {cfg$sct_tandem_days}  -- Tandem if AUTO_DT_2 is within sct_tandem_days (180d) of AUTO_DT_1; no +1 (Q9 resolved 13-May)
                    AND coalesce(ab.n_allo_between, 0) = 0)
          THEN 1 ELSE 0
        END AS LOT1_SCT_AUTO_SING_FLG,
        -- LOT-ending AUTO: excess AUTO beyond what's allowed
        -- Tandem -> 3rd AUTO ends LOT1; Single -> 2nd AUTO ends LOT1
        CASE
          WHEN ap.AUTO_DT_2 IS NOT NULL
           AND datediff(ap.AUTO_DT_2, ap.AUTO_DT_1) <= {cfg$sct_tandem_days}  -- Tandem if AUTO_DT_2 is within sct_tandem_days (180d) of AUTO_DT_1; no +1 (Q9 resolved 13-May)
           AND coalesce(ab.n_allo_between, 0) = 0
          THEN ap.AUTO_DT_3
          WHEN ap.AUTO_DT_1 IS NOT NULL
          THEN ap.AUTO_DT_2
          ELSE NULL
        END AS ENDING_AUTO_DT,
        fa.ALLO_DT AS FIRST_ALLO_DT,
        fc.CART_DT AS FIRST_CART_DT,
        -- LOT1_TX_AUTO_FLG: binary flag for any valid autologous HSCT (per spec)
        CASE WHEN ap.AUTO_DT_1 IS NOT NULL THEN 1 ELSE 0 END AS LOT1_TX_AUTO_FLG,
        -- LOT1_TX_AUTO_MAX_DT: date of 2nd tandem AUTO if tandem, else single AUTO date (per spec)
        CASE
          WHEN ap.AUTO_DT_2 IS NOT NULL
           AND datediff(ap.AUTO_DT_2, ap.AUTO_DT_1) <= {cfg$sct_tandem_days}
           AND coalesce(ab.n_allo_between, 0) = 0
          THEN ap.AUTO_DT_2
          ELSE ap.AUTO_DT_1
        END AS LOT1_TX_AUTO_MAX_DT
      FROM lot1 l
      LEFT JOIN auto_pivot ap ON l.PATID = ap.PATID
      LEFT JOIN allo_between ab ON l.PATID = ab.PATID
      LEFT JOIN first_allo fa ON l.PATID = fa.PATID
      LEFT JOIN first_cart fc ON l.PATID = fc.PATID
    )
    SELECT
      sd.*,
      -- LOT1_TX_ENDDATE: earliest LOT-ending SCT event - 1 day
      CASE
        WHEN coalesce(sd.ENDING_AUTO_DT, sd.FIRST_ALLO_DT, sd.FIRST_CART_DT) IS NOT NULL
        THEN date_sub(
          least(
            coalesce(sd.ENDING_AUTO_DT, cast('9999-12-31' as date)),
            coalesce(sd.FIRST_ALLO_DT,  cast('9999-12-31' as date)),
            coalesce(sd.FIRST_CART_DT,   cast('9999-12-31' as date))
          ), 1)
        ELSE NULL
      END AS LOT1_TX_ENDDATE,
      -- LOT1_TX_ENDDATE_REASON: 1=AUTO, 2=ALLO, 3=CART (whichever is earliest)
      CASE
        WHEN coalesce(sd.ENDING_AUTO_DT, sd.FIRST_ALLO_DT, sd.FIRST_CART_DT) IS NULL THEN NULL
        WHEN coalesce(sd.ENDING_AUTO_DT, cast('9999-12-31' as date))
             <= coalesce(sd.FIRST_ALLO_DT, cast('9999-12-31' as date))
         AND coalesce(sd.ENDING_AUTO_DT, cast('9999-12-31' as date))
             <= coalesce(sd.FIRST_CART_DT, cast('9999-12-31' as date))
        THEN 1
        WHEN coalesce(sd.FIRST_ALLO_DT, cast('9999-12-31' as date))
             <= coalesce(sd.FIRST_CART_DT, cast('9999-12-31' as date))
        THEN 2
        ELSE 3
      END AS LOT1_TX_ENDDATE_REASON,
      -- LOT1_1ST_SCT_DT: first SCT of any type during LOT1
      CASE
        WHEN coalesce(sd.LOT1_TX_AUTO_DT_1, sd.FIRST_ALLO_DT, sd.FIRST_CART_DT) IS NOT NULL
        THEN least(
          coalesce(sd.LOT1_TX_AUTO_DT_1, cast('9999-12-31' as date)),
          coalesce(sd.FIRST_ALLO_DT,     cast('9999-12-31' as date)),
          coalesce(sd.FIRST_CART_DT,      cast('9999-12-31' as date))
        )
        ELSE NULL
      END AS LOT1_1ST_SCT_DT
    FROM sct_derived sd
  "), qc = "
    SELECT
      count(*) AS n_patients,
      sum(CASE WHEN LOT1_TX_AUTO_DT_1 IS NOT NULL THEN 1 ELSE 0 END) AS n_with_auto,
      sum(CASE WHEN FIRST_ALLO_DT IS NOT NULL THEN 1 ELSE 0 END) AS n_with_allo,
      sum(CASE WHEN FIRST_CART_DT IS NOT NULL THEN 1 ELSE 0 END) AS n_with_cart,
      sum(LOT1_SCT_AUTO_TAND_FLG) AS n_tandem,
      sum(LOT1_SCT_AUTO_SING_FLG) AS n_single_auto,
      sum(CASE WHEN LOT1_TX_ENDDATE IS NOT NULL THEN 1 ELSE 0 END) AS n_with_sct_end
    FROM lot1_sct")

  # Materialize heavy upstream views before final assembly + reporting.
  # map_stacked, lot1_base, and lot1_sct are TEMPORARY VIEWs with deep
  # CTE chains back to CDM tables. S16 itself only references each
  # once, so the pay-off is downstream: descriptives reads map_stacked
  # ~17x, lot1_sct ~11x, and lot1_base several times; MAP validation
  # QC and run-metadata counts touch them again. Materializing once
  # here lets every downstream query hit a physical work-schema table
  # instead of re-evaluating the CTE chain.
  # Write to work schema tables, then repoint the views at them.
  # (CACHE TABLE is not supported on SQL warehouses.)
  log_msg("Materializing intermediate views for downstream reporting/QC...")
  for (mv in list(
    list(name = "MAP_STACKED", view = "map_stacked"),
    list(name = "LOT1_BASE",   view = "lot1_base"),
    list(name = "LOT1_SCT",    view = "lot1_sct")
  )) {
    run_step(con, paste0("S16_materialize_", tolower(mv$name)), glue("
      CREATE OR REPLACE TABLE {wrk(mv$name)} AS
      SELECT * FROM {mv$view}
    "), qc = glue("SELECT count(*) AS n_rows FROM {wrk(mv$name)}"))
    db_exec(con, glue("
      CREATE OR REPLACE TEMPORARY VIEW {mv$view} AS
      SELECT * FROM {wrk(mv$name)}
    "))
  }


  # S16b: contains_mtx_reg - Flag-only maintenance concept (Apr 15 meeting)
  # Does the LOT1 induction regimen contain a valid maintenance-approved subset
  # (mono or dual) PLUS an anchor agent (any additional induction drug outside
  # that subset)? The anchor may itself be maintenance-eligible in another context.
  run_step(con, "S16b_lot1_contains_mtx_reg", glue("
    CREATE OR REPLACE TEMPORARY VIEW lot1_contains_mtx_reg AS
    WITH
    -- Valid maintenance regimens from actual induction drugs only (NOT substitution-
    -- expanded base_meds). Permissible subs can create phantom regimen members whose
    -- original drug then falsely anchors a single-agent induction.
    valid_maint_regimens AS (
      -- Mono maintenance: drug has MONOMAINTENANCE=1 and is an actual induction drug
      SELECT DISTINCT im.PATID, im.MED_ABBR AS REGIMEN_KEY
      FROM lot1_induction_meds im
      INNER JOIN mma_rollup ru ON im.MED_ABBR = ru.CL_MED_ABBR
      WHERE ru.MONOMAINTENANCE = 1
      UNION
      -- Dual maintenance: drug lists partner via DUALMAINTENANCEWITH, both in induction
      SELECT DISTINCT
        im.PATID,
        concat_ws(' ', sort_array(array(im.MED_ABBR, im2.MED_ABBR))) AS REGIMEN_KEY
      FROM lot1_induction_meds im
      INNER JOIN mma_rollup ru ON im.MED_ABBR = ru.CL_MED_ABBR
      INNER JOIN lot1_induction_meds im2
        ON im.PATID = im2.PATID
        AND im.MED_ABBR <> im2.MED_ABBR
        AND array_contains(
          transform(split(coalesce(ru.DUALMAINTENANCEWITH, ''), ','), v -> upper(trim(v))),
          im2.MED_ABBR)
    ),
    -- Anchor check: at least one induction drug outside the maintenance subset
    anchored AS (
      SELECT DISTINCT vmr.PATID
      FROM valid_maint_regimens vmr
      INNER JOIN lot1_induction_meds im ON vmr.PATID = im.PATID
      WHERE NOT array_contains(split(vmr.REGIMEN_KEY, ' '), im.MED_ABBR)
    )
    SELECT DISTINCT
      p.PATID,
      CASE WHEN a.PATID IS NOT NULL THEN 1 ELSE 0 END AS contains_mtx_reg
    FROM (SELECT DISTINCT PATID FROM lot1_induction_meds) p
    LEFT JOIN anchored a ON p.PATID = a.PATID
  "), qc = "
    SELECT contains_mtx_reg, count(*) AS n
    FROM lot1_contains_mtx_reg
    GROUP BY contains_mtx_reg")

  # S16: LOT1_BASE_END - Final end reason incorporating SCT + CAR-T initiation
  # Apr 19 spec numbering: Rule 1 = Discontinuation, Rule 2 = SCT / CAR-T,
  # Rule 3 = Death, Rule 4 = Disenrollment, Rule 5 = Study end.
  # End reason priority. Note this is NOT only a tie-break on identical
  # dates: after the Q1 06-May changes, DEATH can outrank an earlier
  # DISCONTINUATION when there is no LOT2-qualifying trigger between
  # runout and death (Q1.1 post-runout guard). The earlier branches
  # (SCT, CART_INIT, MED_ADD) keep their own gating against DISCON_DT
  # to fire only when their event sits at or before runout.
  # Order:
  #   SCT_ALLO > SCT_CART > SCT_AUTO (Rule 2 unplanned) > CART_INIT > MED_ADD
  #   > DEATH (guarded by Q1.1) > DISCONTINUATION > STUDY_END
  # NOTE: Disenrollment is NOT a censoring criterion per study design.
  # Patients whose observable period ended at disenrollment are classified STUDY_END.
  # Apr 19 spec: MAINTENANCE_END and SCT_NO_MAINT removed as final values;
  # former cases route by earliest applicable event.
  # CART_INIT: MED_ADD followed by CART within cart_consolidation_days
  # -> LOT1 ends on FIRST_CART_DT - 1 (the day before CAR-T infusion).
  run_step(con, "S16_lot1_base_end", glue("
    CREATE OR REPLACE TEMPORARY VIEW lot1_base_end AS
    WITH
    -- Q1.1 (post-review fix): identify whether any LOT2-qualifying trigger
    -- exists strictly after LOT1_BASE_DISCON_DT and on/before OBS_END_DT.
    -- Prevents DEATH from preempting DISCONTINUATION when a patient ran out
    -- and then started new therapy (or had an SCT) before dying.
    --
    -- These CTEs MIRROR the actual LOT2 start-candidate logic from
    -- lot2_5_base.R (med_cand / auto_cand) so the guard fires exactly when
    -- LOT2 would actually have a valid start trigger:
    --   - MED: any non-steroid MM agent NOT in LOT1's permissible biosimilar
    --     substitutes. Same-drug restarts DO qualify.
    --   - AUTO: any AUTO outside LOT1 30-day applicable window
    --     (LOT2-5 auto_cand uses 30d for any MED-started prior LOT,
    --     regardless of LOT1's own 60d induction window) AND not within
    --     sct_tandem_days (180d) of the immediately prior AUTO in patient
    --     history (planned tandem).
    --   - ALLO/CART: any after runout (no window check; always trigger).
    post_runout_excluded_meds AS (
      SELECT im.PATID, ps.substitute_med AS MED_ABBR
      FROM lot1_induction_meds im
      INNER JOIN permissible_subs ps ON im.MED_ABBR = ps.original_med
    ),
    post_runout_med AS (
      SELECT DISTINCT ms.PATID
      FROM map_stacked ms
      INNER JOIN lot1_base lb ON ms.PATID = lb.PATID
      LEFT JOIN post_runout_excluded_meds prem
        ON ms.PATID = prem.PATID AND ms.MAP_MED_TYPE = prem.MED_ABBR
      WHERE lb.LOT1_BASE_DISCON_DT IS NOT NULL
        AND ms.MAP_START_DT > lb.LOT1_BASE_DISCON_DT
        AND ms.MAP_START_DT <= lb.OBS_END_DT
        AND ms.MAP_MED_CLASS <> 'STEROID'
        AND prem.MED_ABBR IS NULL
    ),
    post_runout_autos AS (
      SELECT a.PATID, a.TX_DT,
             lag(a.TX_DT) OVER (PARTITION BY a.PATID ORDER BY a.TX_DT) AS PREV_AUTO_DT
      FROM tx_auto_dates a
    ),
    post_runout_auto AS (
      -- Mirrors LOT2-5 auto_cand: LOT1 is MED-started in lot_long, so the
      -- applicable window from LOT2 perspective is cfg$lot_n_induction_window_days
      -- (default 30d). LOT1's own 60d induction window is NOT used here because the
      -- guard models what LOT2's auto_cand would see, not what LOT1 itself uses.
      SELECT DISTINCT lb.PATID
      FROM lot1_base lb
      INNER JOIN post_runout_autos awp ON lb.PATID = awp.PATID
      WHERE lb.LOT1_BASE_DISCON_DT IS NOT NULL
        AND awp.TX_DT > lb.LOT1_BASE_DISCON_DT
        AND awp.TX_DT <= lb.OBS_END_DT
        AND awp.TX_DT > date_add(lb.LOT1_START_DT, {cfg$lot_n_induction_window_days} - 1)
        AND NOT (awp.PREV_AUTO_DT IS NOT NULL
                 AND datediff(awp.TX_DT, awp.PREV_AUTO_DT) <= {cfg$sct_tandem_days})
    ),
    post_runout_trigger AS (
      SELECT lb.PATID,
        CASE
          WHEN lb.LOT1_BASE_DISCON_DT IS NULL THEN 0
          WHEN prm.PATID IS NOT NULL THEN 1
          WHEN sct.FIRST_ALLO_DT IS NOT NULL AND sct.FIRST_ALLO_DT > lb.LOT1_BASE_DISCON_DT THEN 1
          WHEN sct.FIRST_CART_DT IS NOT NULL AND sct.FIRST_CART_DT > lb.LOT1_BASE_DISCON_DT THEN 1
          WHEN pra.PATID IS NOT NULL THEN 1
          ELSE 0
        END AS POST_RUNOUT_TRIGGER_FLG
      FROM lot1_base lb
      LEFT JOIN lot1_sct sct ON lb.PATID = sct.PATID
      LEFT JOIN post_runout_med prm ON lb.PATID = prm.PATID
      LEFT JOIN post_runout_auto pra ON lb.PATID = pra.PATID
    ),
    end_candidates AS (
      SELECT
        lb.*,
        coalesce(prt.POST_RUNOUT_TRIGGER_FLG, 0) AS POST_RUNOUT_TRIGGER_FLG,
        sct.LOT1_TX_AUTO_DT_1,
        sct.LOT1_TX_AUTO_DT_2,
        sct.LOT1_SCT_AUTO_TAND_FLG,
        sct.LOT1_SCT_AUTO_SING_FLG,
        sct.LOT1_TX_ENDDATE,
        sct.LOT1_TX_ENDDATE_REASON,
        sct.LOT1_1ST_SCT_DT,
        sct.FIRST_ALLO_DT,
        sct.FIRST_CART_DT,
        -- contains_mtx_reg flag (Apr 19 spec: descriptive, flag-only; does not
        -- drive end-reason routing or create a standalone maintenance period)
        COALESCE(cmr.contains_mtx_reg, 0) AS contains_mtx_reg,
        -- CART_INIT: MED_ADD followed by CART within {cfg$cart_consolidation_days} days
        -- Apr 15 meeting (Julia): if someone has a new medication added, but then within
        -- 45 days of that new agent, they start CAR-T, the reason for LOT1 end should
        -- be initiation of CAR-T therapy, not a medication add.
        -- datediff(A, B) = A - B in Databricks; CART_DT - ADD_START_DT BETWEEN 0 AND 45
        -- Note: LOT1_BASE_1ST_ADD_MED_DT is date_sub(ADD_START_DT, 1), so add 1 back
        CASE
          WHEN sct.FIRST_CART_DT IS NOT NULL
           AND lb.LOT1_BASE_1ST_ADD_MED_DT IS NOT NULL
           AND datediff(sct.FIRST_CART_DT, date_add(lb.LOT1_BASE_1ST_ADD_MED_DT, 1)) BETWEEN 0 AND {cfg$cart_consolidation_days}
          THEN 1
          ELSE 0
        END AS CART_INIT_FLG
      FROM lot1_base lb
      LEFT JOIN lot1_sct sct ON lb.PATID = sct.PATID
      LEFT JOIN lot1_contains_mtx_reg cmr ON lb.PATID = cmr.PATID
      LEFT JOIN post_runout_trigger   prt ON lb.PATID = prt.PATID
    )
    SELECT
      ec.*,
      -- Apr 19 spec numbering:
      --   Rule 1 = Discontinuation, Rule 2 = SCT / CAR-T events,
      --   Rule 3 = Death, Rule 4 = Disenrollment, Rule 5 = Study end.
      -- End reason priority. Not purely a tie-break on identical earliest
      -- dates: DEATH can outrank an earlier DISCONTINUATION when there is
      -- no LOT2-qualifying trigger sitting between runout and death (Q1.1
      -- post-runout guard, 06-May). Earlier branches (SCT, CART_INIT,
      -- MED_ADD) still gate themselves against DISCON_DT to fire only when
      -- their event is at or before runout.
      -- Order:
      --   SCT_ALLO > SCT_CART > SCT_AUTO (Rule 2, unplanned) > CART_INIT
      --   > MED_ADD > DEATH (guarded by Q1.1) > DISCONTINUATION > STUDY_END
      -- NOTE: DISENROLLMENT removed — not a censoring criterion per study design.
      -- Apr 19 spec: MAINTENANCE_END and SCT_NO_MAINT removed; former
      -- cases route by earliest applicable event. CART_INIT ends LOT1 on
      -- FIRST_CART_DT - 1 (the day before CAR-T infusion).
      CASE
        -- Rule 2: SCT (ALLO, CART, or excess AUTO)
        -- When CART_INIT_FLG=1 and the SCT IS the CART (reason=3), skip this branch
        -- so CART_INIT can handle it. Otherwise CART events always route to SCT_CART
        -- before CART_INIT is ever reached.
        -- Tie-break vs CART_INIT uses FIRST_CART_DT - 1 (CART_INIT's spec end date),
        -- so SCT only wins on ties when its end is <= CART_INIT's end.
        WHEN ec.LOT1_TX_ENDDATE IS NOT NULL
         AND NOT (ec.CART_INIT_FLG = 1 AND ec.LOT1_TX_ENDDATE_REASON = 3)
         AND (ec.LOT1_BASE_1ST_ADD_MED_DT IS NULL
              OR (ec.CART_INIT_FLG = 1 AND ec.LOT1_TX_ENDDATE <= date_sub(ec.FIRST_CART_DT, 1))
              OR (ec.CART_INIT_FLG = 0 AND ec.LOT1_TX_ENDDATE <= ec.LOT1_BASE_1ST_ADD_MED_DT))
         AND (ec.LOT1_BASE_DISCON_DT IS NULL OR ec.LOT1_TX_ENDDATE <= ec.LOT1_BASE_DISCON_DT)
        THEN CASE ec.LOT1_TX_ENDDATE_REASON
               WHEN 1 THEN 'SCT_AUTO'
               WHEN 2 THEN 'SCT_ALLO'
               WHEN 3 THEN 'SCT_CART'
               ELSE 'SCT'
             END
        -- CART_INIT: MED_ADD followed by CART within {cfg$cart_consolidation_days} days.
        -- Spec end date is FIRST_CART_DT - 1, so gate against discon uses that.
        WHEN ec.CART_INIT_FLG = 1
         AND (ec.LOT1_BASE_DISCON_DT IS NULL OR date_sub(ec.FIRST_CART_DT, 1) <= ec.LOT1_BASE_DISCON_DT)
        THEN 'CART_INIT'
        -- MED_ADD: new non-base drug added (not followed by CART within 45 days)
        WHEN ec.LOT1_BASE_1ST_ADD_MED_DT IS NOT NULL
         AND ec.CART_INIT_FLG = 0
         AND (ec.LOT1_BASE_DISCON_DT IS NULL OR ec.LOT1_BASE_1ST_ADD_MED_DT <= ec.LOT1_BASE_DISCON_DT)
        THEN 'MED_ADD'
        -- Q1 + Q1.1 (06-May review): DEATH outranks DISCONTINUATION, but only
        -- when no qualifying LOT2-start trigger exists between runout and
        -- death. If the patient ran out then started new therapy (or had an
        -- SCT) before dying, the runout is the true LOT1 end and the new
        -- event triggers LOT2.
        WHEN ec.DEATH_DT IS NOT NULL AND ec.DEATH_DT <= ec.OBS_END_DT
         AND ec.POST_RUNOUT_TRIGGER_FLG = 0 THEN 'DEATH'
        -- Rule 1: Discontinuation of all agents (also catches former MAINTENANCE_END patients)
        WHEN ec.LOT1_BASE_DISCON_DT IS NOT NULL THEN 'DISCONTINUATION'
        -- Study end (disenrollment not a censoring criterion per study design;
        -- DISENROLLMENT therefore never triggers in the primary cascade).
        ELSE 'STUDY_END'
      END AS LOT1_BASE_END_REASON,
      -- Corresponding end date (mirrors end-reason priority).
      -- CART_INIT ends LOT1 on FIRST_CART_DT - 1 per Apr 19 spec.
      CASE
        WHEN ec.LOT1_TX_ENDDATE IS NOT NULL
         AND NOT (ec.CART_INIT_FLG = 1 AND ec.LOT1_TX_ENDDATE_REASON = 3)
         AND (ec.LOT1_BASE_1ST_ADD_MED_DT IS NULL
              OR (ec.CART_INIT_FLG = 1 AND ec.LOT1_TX_ENDDATE <= date_sub(ec.FIRST_CART_DT, 1))
              OR (ec.CART_INIT_FLG = 0 AND ec.LOT1_TX_ENDDATE <= ec.LOT1_BASE_1ST_ADD_MED_DT))
         AND (ec.LOT1_BASE_DISCON_DT IS NULL OR ec.LOT1_TX_ENDDATE <= ec.LOT1_BASE_DISCON_DT)
        THEN ec.LOT1_TX_ENDDATE
        WHEN ec.CART_INIT_FLG = 1
         AND (ec.LOT1_BASE_DISCON_DT IS NULL OR date_sub(ec.FIRST_CART_DT, 1) <= ec.LOT1_BASE_DISCON_DT)
        THEN date_sub(ec.FIRST_CART_DT, 1)
        WHEN ec.LOT1_BASE_1ST_ADD_MED_DT IS NOT NULL
         AND ec.CART_INIT_FLG = 0
         AND (ec.LOT1_BASE_DISCON_DT IS NULL OR ec.LOT1_BASE_1ST_ADD_MED_DT <= ec.LOT1_BASE_DISCON_DT)
        THEN ec.LOT1_BASE_1ST_ADD_MED_DT
        WHEN ec.DEATH_DT IS NOT NULL AND ec.DEATH_DT <= ec.OBS_END_DT
         AND ec.POST_RUNOUT_TRIGGER_FLG = 0 THEN ec.DEATH_DT
        WHEN ec.LOT1_BASE_DISCON_DT IS NOT NULL THEN ec.LOT1_BASE_DISCON_DT
        ELSE ec.OBS_END_DT  -- OBS_END_DT = ENDDATE (disenrollment not a censoring criterion)
      END AS LOT1_BASE_END_DT,
      -- LOT1_BASE_LENGTH: mirrors the LOT1_BASE_END_DT cascade exactly so that
      -- length always equals (LOT1_BASE_END_DT - LOT1_START_DT + 1). Cascade
      -- order matches the END_REASON priority including the Q1 06-May flip
      -- (DEATH > DISCONTINUATION > STUDY_END).
      CASE
        WHEN ec.LOT1_TX_ENDDATE IS NOT NULL
         AND NOT (ec.CART_INIT_FLG = 1 AND ec.LOT1_TX_ENDDATE_REASON = 3)
         AND (ec.LOT1_BASE_1ST_ADD_MED_DT IS NULL
              OR (ec.CART_INIT_FLG = 1 AND ec.LOT1_TX_ENDDATE <= date_sub(ec.FIRST_CART_DT, 1))
              OR (ec.CART_INIT_FLG = 0 AND ec.LOT1_TX_ENDDATE <= ec.LOT1_BASE_1ST_ADD_MED_DT))
         AND (ec.LOT1_BASE_DISCON_DT IS NULL OR ec.LOT1_TX_ENDDATE <= ec.LOT1_BASE_DISCON_DT)
        THEN datediff(ec.LOT1_TX_ENDDATE, ec.LOT1_START_DT) + 1
        WHEN ec.CART_INIT_FLG = 1
         AND (ec.LOT1_BASE_DISCON_DT IS NULL OR date_sub(ec.FIRST_CART_DT, 1) <= ec.LOT1_BASE_DISCON_DT)
        THEN datediff(date_sub(ec.FIRST_CART_DT, 1), ec.LOT1_START_DT) + 1
        WHEN ec.LOT1_BASE_1ST_ADD_MED_DT IS NOT NULL
         AND ec.CART_INIT_FLG = 0
         AND (ec.LOT1_BASE_DISCON_DT IS NULL OR ec.LOT1_BASE_1ST_ADD_MED_DT <= ec.LOT1_BASE_DISCON_DT)
        THEN datediff(ec.LOT1_BASE_1ST_ADD_MED_DT, ec.LOT1_START_DT) + 1
        -- Q1 + Q1.1: DEATH outranks DISCONTINUATION, but only when no
        -- post-runout LOT2-start trigger exists.
        WHEN ec.DEATH_DT IS NOT NULL AND ec.DEATH_DT <= ec.OBS_END_DT
         AND ec.POST_RUNOUT_TRIGGER_FLG = 0
        THEN datediff(ec.DEATH_DT, ec.LOT1_START_DT) + 1
        WHEN ec.LOT1_BASE_DISCON_DT IS NOT NULL
        THEN datediff(ec.LOT1_BASE_DISCON_DT, ec.LOT1_START_DT) + 1
        ELSE datediff(ec.OBS_END_DT, ec.LOT1_START_DT) + 1
      END AS LOT1_BASE_LENGTH
    FROM end_candidates ec
  "), qc = "
    SELECT LOT1_BASE_END_REASON, count(*) AS n,
           sum(CART_INIT_FLG) AS n_cart_init,
           sum(contains_mtx_reg) AS n_contains_mtx_reg
    FROM lot1_base_end
    GROUP BY LOT1_BASE_END_REASON
    ORDER BY LOT1_BASE_END_REASON")


  # NDC Format QC (Fix #5 from review)
  # Validates NDC length match between codelist and claims
  log_msg("Running NDC format QC...")
  tryCatch({
    ndc_qc_codelist <- db_q(con, "
      SELECT length(CL_CODE) AS ndc_len, count(*) AS n
      FROM mma_codelist
      WHERE CL_CODE_TYPE = 'NDC'
      GROUP BY length(CL_CODE)
      ORDER BY length(CL_CODE)
    ")
    log_msg("  NDC length distribution in codelist:")
    print(ndc_qc_codelist)

    # Restrict to cohort PATIDs + date window to avoid full RX scan
    ndc_qc_rx <- db_q(con, glue("
      SELECT length(upper(regexp_replace(coalesce(cast(r.NDC as string),''), '[^A-Za-z0-9]', ''))) AS ndc_len,
             count(*) AS n
      FROM {cdm_src(cfg$tbl_rx)} r
      INNER JOIN lot_patient_input p ON r.PATID = p.PATID
      WHERE cast(r.NDC as string) IS NOT NULL AND trim(cast(r.NDC as string)) <> ''
        AND cast(r.FILL_DT AS date) >= p.INDEX_DATE
        AND cast(r.FILL_DT AS date) <= p.OBS_END_DT
      GROUP BY length(upper(regexp_replace(coalesce(cast(r.NDC as string),''), '[^A-Za-z0-9]', '')))
      ORDER BY ndc_len
    "))
    log_msg("  NDC length distribution in RX claims:")
    print(ndc_qc_rx)

    # Check for mismatches
    codelist_lens <- ndc_qc_codelist$ndc_len
    rx_lens <- ndc_qc_rx$ndc_len
    if (length(intersect(codelist_lens, rx_lens)) == 0 && length(codelist_lens) > 0 && length(rx_lens) > 0) {
      log_msg("  WARNING: NDC lengths in codelist and RX table DO NOT OVERLAP!")
      log_msg("  This may cause silent misses in pharmacy claim matching.")
      log_msg("  Codelist lengths: ", paste(codelist_lens, collapse = ", "))
      log_msg("  RX table lengths: ", paste(rx_lens, collapse = ", "))
    }
  }, error = function(e) {
    log_msg("  WARNING: NDC QC failed: ", e$message)
  })

  # Validation QC Suite (Fix #10 from review)
  # Must-run validations for MAP + LOT correctness
  log_msg("Running validation QC suite...")
  tryCatch({
    # A) MMA_MED coverage by source
    log_msg("  [A] MMA_MED extraction coverage:")
    coverage <- db_q(con, "
      SELECT CODE_TYPE, CLAIM_TYPE, count(*) AS n_claims, count(DISTINCT PATID) AS n_patients, count(DISTINCT MED_ABBR) AS n_meds
      FROM mma_med_processed
      GROUP BY CODE_TYPE, CLAIM_TYPE
      ORDER BY CODE_TYPE, CLAIM_TYPE
    ")
    print(coverage)

    # B) MAP correctness spot checks
    log_msg("  [B] MAP algorithm spot checks:")
    # Check no MAP has end < start
    bad_maps <- db_q(con, "SELECT count(*) AS n_bad FROM map_stacked WHERE MAP_END_DT < MAP_START_DT")$n_bad
    log_msg("    MAPs with END < START: ", bad_maps, if (bad_maps > 0) " ** INVESTIGATE **" else " (OK)")

    # Check MAP_END_DT = max(rx_runout, med_runout)
    runout_check <- db_q(con, "
      SELECT count(*) AS n_mismatch
      FROM map_stacked
      WHERE MAP_END_DT <> greatest(
        coalesce(MAP_RX_RUNOUT_DT, cast('1900-01-01' as date)),
        coalesce(MAP_MED_RUNOUT_DT, cast('1900-01-01' as date))
      )
      AND MAP_END_DT IS NOT NULL
    ")$n_mismatch
    log_msg("    MAPs where END_DT != max(rx_runout, med_runout): ", runout_check,
            if (runout_check > 0) " ** INVESTIGATE **" else " (OK)")

    # MAPs with both rx and med sources (mixed claim type coverage)
    both_src <- db_q(con, "
      SELECT count(*) AS n_maps_both_sources
      FROM map_stacked
      WHERE MAP_RX_RUNOUT_DT IS NOT NULL AND MAP_MED_RUNOUT_DT IS NOT NULL
    ")$n_maps_both_sources
    log_msg("    MAPs with both pharmacy + medical sources: ", format(both_src, big.mark = ","))

    # C) ENDDATE_CE vs ENDDATE sensitivity
    log_msg("  [C] OBS_END_DT (ENDDATE_CE) sensitivity:")
    ce_sens <- db_q(con, "
      SELECT
        sum(case when ENDDATE_CE < ENDDATE then 1 else 0 end) AS n_disenrolled_early,
        count(*) AS n_total,
        avg(case when ENDDATE_CE < ENDDATE then datediff(ENDDATE, ENDDATE_CE) else 0 end) AS avg_gap_days
      FROM lot_patient_input
    ")
    log_msg("    Patients disenrolled before study ENDDATE: ",
            format(ce_sens$n_disenrolled_early, big.mark = ","),
            " / ", format(ce_sens$n_total, big.mark = ","),
            " (", round(100 * ce_sens$n_disenrolled_early / max(ce_sens$n_total, 1), 1), "%)")
    log_msg("    Avg gap (ENDDATE - ENDDATE_CE): ", round(ce_sens$avg_gap_days, 1), " days")

    # D) LOT1 completeness
    log_msg("  [D] LOT1 completeness:")
    lot1_check <- db_q(con, "
      SELECT
        count(*) AS n_lot1,
        sum(case when lb.LOT1_BASE_END_DT > p.OBS_END_DT then 1 else 0 end) AS n_end_past_obs
      FROM lot1_base_end lb
      INNER JOIN lot_patient_input p ON lb.PATID = p.PATID
    ")
    log_msg("    LOT1 patients: ", format(lot1_check$n_lot1, big.mark = ","))
    log_msg("    LOT1_BASE_END_DT > OBS_END_DT: ", lot1_check$n_end_past_obs,
            if (lot1_check$n_end_past_obs > 0) " ** INVESTIGATE **" else " (OK)")

    # E) Rollup flag sanity
    log_msg("  [E] Rollup flag validation:")
    flag_check <- db_q(con, "
      SELECT CL_MED_ABBR, CL_MED_CLASS, MONOMAINTENANCE, CONDITIONING, USED_FOR_OTHER_CANCERS
      FROM mma_rollup
      ORDER BY CL_MED_CLASS, CL_MED_ABBR
    ")
    print(flag_check)

    # F) SCT consistency
    log_msg("  [F] SCT validation:")
    sct_check <- db_q(con, "
      SELECT
        sum(CASE WHEN LOT1_TX_ENDDATE IS NOT NULL AND LOT1_TX_ENDDATE > lb.OBS_END_DT THEN 1 ELSE 0 END)
          AS n_sct_end_past_obs,
        sum(CASE WHEN LOT1_SCT_AUTO_TAND_FLG = 1 AND LOT1_SCT_AUTO_SING_FLG = 1 THEN 1 ELSE 0 END)
          AS n_both_tandem_and_single,
        sum(CASE WHEN LOT1_TX_AUTO_DT_1 IS NOT NULL AND LOT1_TX_AUTO_DT_1 < lb.LOT1_START_DT THEN 1 ELSE 0 END)
          AS n_auto_before_lot1
      FROM lot1_sct sct
      INNER JOIN lot1_base lb ON sct.PATID = lb.PATID
    ")
    log_msg("    SCT end date past OBS_END_DT: ", sct_check$n_sct_end_past_obs,
            if (sct_check$n_sct_end_past_obs > 0) " ** INVESTIGATE **" else " (OK)")
    log_msg("    Both tandem AND single flag: ", sct_check$n_both_tandem_and_single,
            if (sct_check$n_both_tandem_and_single > 0) " ** BUG **" else " (OK)")
    log_msg("    AUTO DT_1 before LOT1_START: ", sct_check$n_auto_before_lot1,
            if (sct_check$n_auto_before_lot1 > 0) " ** INVESTIGATE **" else " (OK)")

    log_msg("Validation QC suite complete.")
  }, error = function(e) {
    log_msg("WARNING: Validation QC suite failed: ", e$message)
  })

  # Descriptives + Figures
  if (isTRUE(cfg$generate_descriptives)) {
    log_msg("Generating descriptive summary and figures...")
    print_descriptives(con)
  } else {
    log_msg("Descriptives generation disabled (GENERATE_DESCRIPTIVES=FALSE).")
  }

  # Persist outputs
  if (isTRUE(cfg$persist_to_schema)) {
    # MAP_STACKED, LOT1_BASE, LOT1_SCT already materialized before S16.
    # Only persist the remaining outputs here.
    persist_tables <- list(
      list(step = "S20", name = "LOT1_BASE_END",     view = "lot1_base_end"),
      list(step = "S21", name = "MMA_MED_PROCESSED", view = "mma_med_processed")
    )
    for (pt in persist_tables) {
      run_step(con, paste0(pt$step, "_persist_", tolower(pt$name)), glue("
        CREATE OR REPLACE TABLE {wrk(pt$name)} AS
        SELECT * FROM {pt$view}
      "), qc = glue("SELECT count(*) AS n_rows FROM {wrk(pt$name)}"))
    }

    # Persist run metadata - parameters + key counts for rerun comparison
    tryCatch({
      cohort_n <- as.numeric(db_q(con, "SELECT count(DISTINCT PATID) AS n FROM lot_patient_input")$n)
      mma_n    <- as.numeric(db_q(con, "SELECT count(*) AS n FROM mma_med_processed")$n)
      map_n    <- as.numeric(db_q(con, "SELECT count(*) AS n FROM map_stacked")$n)
      lot1_n   <- as.numeric(db_q(con, "SELECT count(*) AS n FROM lot1_base")$n)

      # Create metadata table if not exists (full current schema).
      run_step(con, "S22a_create_metadata_table", glue("
        CREATE TABLE IF NOT EXISTS {wrk('LOT_RUN_METADATA')} (
          RUN_ID STRING, RUN_TIMESTAMP TIMESTAMP,
          CDM_SCHEMA STRING, WORK_SCHEMA STRING, INPUT_COHORT_TABLE STRING,
          INDUCTION_WINDOW_DAYS INT, INDUCTION_WINDOW_DAYS_LOT_N INT,
          MAP_DISCON_GAP_DAYS INT, MEDICAL_DAY_SUPPLY INT,
          N_COHORT_PATIENTS BIGINT, N_MMA_CLAIMS BIGINT,
          N_MAPS BIGINT, N_LOT1_PATIENTS BIGINT
        )
      "))
      # Schema evolution: older LOT_RUN_METADATA tables pre-date the
      # INDUCTION_WINDOW_DAYS_LOT_N column. CREATE TABLE IF NOT EXISTS is
      # a no-op when the table already exists. Check the column FIRST and
      # only ALTER when it is genuinely missing -- otherwise a rerun
      # raises FIELD_ALREADY_EXISTS which db_exec/with_retry logs as a
      # noisy "Permanent error" stack BEFORE the catch can swallow it.
      have_cols <- tryCatch({
        d  <- db_q(con, glue("DESCRIBE {wrk('LOT_RUN_METADATA')}"))
        cn <- intersect(c("col_name", "COL_NAME", "name", "NAME"), names(d))
        if (length(cn)) toupper(trimws(as.character(d[[cn[1]]]))) else character(0)
      }, error = function(e) character(0))
      if (!("INDUCTION_WINDOW_DAYS_LOT_N" %in% have_cols)) {
        tryCatch({
          db_exec(con, glue("
            ALTER TABLE {wrk('LOT_RUN_METADATA')} ADD COLUMNS (INDUCTION_WINDOW_DAYS_LOT_N INT)
          "))
          log_msg("  Metadata schema evolution: added INDUCTION_WINDOW_DAYS_LOT_N")
        }, error = function(e) {
          msg <- conditionMessage(e)
          if (!grepl("already exists|AlreadyExists|FIELD_ALREADY_EXISTS|DELTA_ADD_COLUMN_PARENT_NOT_STRUCT",
                     msg, ignore.case = TRUE)) {
            log_msg("  Metadata schema evolution warning: ", msg)
          }
        })
      } else {
        log_msg("  Metadata schema: INDUCTION_WINDOW_DAYS_LOT_N already present (no migration needed)")
      }
      # Delete any prior row for this exact run_id (idempotent re-runs)
      run_step(con, "S22b_dedup_metadata", glue("
        DELETE FROM {wrk('LOT_RUN_METADATA')} WHERE RUN_ID = '{run_id}'
      "))
      # Explicit column list - robust against column ordering after ALTER
      # TABLE on older schemas (new columns are appended, not inserted in
      # the original position) and against extra legacy columns
      # (e.g. LOT_DISCON_GAP_DAYS on tables created before its removal).
      run_step(con, "S22c_insert_run_metadata", glue("
        INSERT INTO {wrk('LOT_RUN_METADATA')} (
          RUN_ID, RUN_TIMESTAMP, CDM_SCHEMA, WORK_SCHEMA, INPUT_COHORT_TABLE,
          INDUCTION_WINDOW_DAYS, INDUCTION_WINDOW_DAYS_LOT_N,
          MAP_DISCON_GAP_DAYS, MEDICAL_DAY_SUPPLY,
          N_COHORT_PATIENTS, N_MMA_CLAIMS, N_MAPS, N_LOT1_PATIENTS
        )
        SELECT
          '{run_id}',
          current_timestamp(),
          '{cfg$cdm_schema}',
          '{cfg$work_schema}',
          '{cfg$input_cohort_table}',
          {cfg$induction_window_days},
          {cfg$lot_n_induction_window_days},
          {cfg$map_discon_gap_days},
          {cfg$medical_day_supply},
          {cohort_n},
          {mma_n},
          {map_n},
          {lot1_n}
      "))
    }, error = function(e) {
      log_msg("  WARNING: Run metadata persist failed: ", conditionMessage(e))
    })

    # Persist QC summary - one row per check for governance
    tryCatch({
      # Table-driven QC checks: name -> SQL that returns a single count
      qc_defs <- list(
        list(name = "CODELIST_ORPHAN_MEDS", sql = "
          SELECT count(DISTINCT c.CL_MED_ABBR) AS n
          FROM mma_codelist c LEFT JOIN mma_rollup r ON c.CL_MED_ABBR = r.CL_MED_ABBR
          WHERE r.CL_MED_ABBR IS NULL"),
        list(name = "MAP_END_BEFORE_START", sql = "
          SELECT count(*) AS n FROM map_stacked WHERE MAP_END_DT < MAP_START_DT"),
        list(name = "LOT1_END_PAST_OBS", sql = "
          SELECT sum(case when lb.LOT1_BASE_END_DT > p.OBS_END_DT then 1 else 0 end) AS n
          FROM lot1_base_end lb INNER JOIN lot_patient_input p ON lb.PATID = p.PATID"),
        list(name = "SCT_TANDEM_AND_SINGLE", sql = "
          SELECT sum(CASE WHEN LOT1_SCT_AUTO_TAND_FLG = 1 AND LOT1_SCT_AUTO_SING_FLG = 1 THEN 1 ELSE 0 END) AS n
          FROM lot1_sct")
      )
      qc_rows <- vapply(qc_defs, function(qd) {
        val <- tryCatch(as.numeric(db_q(con, qd$sql)$n), error = function(e) NA)
        status <- if (is.na(val)) "ERROR" else if (val == 0) "PASS" else "WARN"
        glue("SELECT '{qd$name}' AS CHECK_NAME, {if (is.na(val)) 'NULL' else val} AS CHECK_VALUE, '{status}' AS CHECK_STATUS, '{run_id}' AS RUN_ID")
      }, character(1))

      qc_union <- paste(qc_rows, collapse = "\n        UNION ALL\n        ")
      run_step(con, "S23a_create_qc_table", glue("
        CREATE TABLE IF NOT EXISTS {wrk('LOT_QC_SUMMARY')} (
          CHECK_NAME STRING, CHECK_VALUE BIGINT, CHECK_STATUS STRING, RUN_ID STRING
        )
      "))
      run_step(con, "S23b_dedup_qc", glue("
        DELETE FROM {wrk('LOT_QC_SUMMARY')} WHERE RUN_ID = '{run_id}'
      "))
      run_step(con, "S23c_insert_qc_summary", glue("
        INSERT INTO {wrk('LOT_QC_SUMMARY')}
        {qc_union}
      "))
    }, error = function(e) {
      log_msg("  WARNING: QC summary persist failed: ", conditionMessage(e))
    })

  } else {
    log_msg("Persist disabled (PERSIST_TO_SCHEMA=FALSE).")
  }

  log_msg(SEP)
  log_msg("LOT Part 2 complete.")
  log_msg("Temporary views: mma_med_processed, map_stacked, lot1_base, lot1_sct, lot1_base_end")
  if (isTRUE(cfg$persist_to_schema)) {
    log_msg("Persisted tables in work schema: MAP_STACKED, LOT1_BASE, LOT1_SCT, LOT1_BASE_END, MMA_MED_PROCESSED, LOT_RUN_METADATA, LOT_QC_SUMMARY")
  }
  if (isTRUE(cfg$generate_descriptives)) {
    log_msg("Figures saved to: ", cfg$output_dir)
  }
  log_msg(SEP)

  invisible(TRUE)
}

if (sys.nframe() == 0) {
  main()
}
