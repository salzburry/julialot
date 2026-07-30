# Code lists into views, then the consistency checks. Returns what the later
# phases need: the SCT source and the per-med / per-class flag expressions.

phase_codelists <- function(con) {
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
      -- Rollup fields can be 'YES', 'YES mainly...', 1, 0, or NULL.
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
    -- DISTINCT: a repeated row would duplicate every claim it matches.
    SELECT DISTINCT
      upper(trim(CL_CODE_TYPE)) AS CL_CODE_TYPE,
      upper(regexp_replace(trim(CL_CODE), '[^A-Za-z0-9]', '')) AS CL_CODE,
      lower(trim(CL_MEDICATION_FULL)) AS CL_MEDICATION_FULL,
      upper(trim(CL_MED_CLASS))       AS CL_MED_CLASS,
      upper(trim(CL_MED_ABBR))        AS CL_MED_ABBR
    FROM {codelist_src}
    WHERE CL_CODE IS NOT NULL AND trim(CL_CODE) <> ''
      AND CL_CODE_TYPE IS NOT NULL AND trim(CL_CODE_TYPE) <> ''
      -- The filter above tests the raw value but the code is stored normalized,
      -- so '--' would survive as ''. The claim side coalesces a missing code to
      -- '' too, and the two would match every claim with no code at all.
      AND regexp_replace(CL_CODE, '[^A-Za-z0-9]', '') <> ''
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
  min_rollup_meds <- 20L    # the rollup has 28 unique MED_ABBR; 20 is conservative floor

  min_codelist_codes <- 50L # the codelist has hundreds of codes; 50 is conservative floor
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

  list(rollup_src = rollup_src, subs_src = subs_src, sct_src = sct_src,
       meds = meds, classes = classes, sanitize_col = sanitize_col,
       med_flag_exprs = med_flag_exprs, class_flag_exprs = class_flag_exprs)
}
