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
    -- DISTINCT: this is a lookup keyed on CL_MED_ABBR, so a repeated row
    -- would fan out every join against it.
    SELECT DISTINCT
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

  # Code list vs rollup consistency.
  #
  # These were warnings inside a tryCatch, so a bad code list printed a line
  # and the build carried on - and a QC query that itself failed was swallowed
  # whole. Each of these silently changes who counts as treated, so they stop
  # the build. ALLOW_CODELIST_WARNINGS=TRUE downgrades them for a run where the
  # study team has looked and accepted what they say.
  log_msg("Checking codelist <-> rollup consistency...")
  problems <- data.frame(check = character(0), detail = character(0),
                         stringsAsFactors = FALSE)

  # A code list med with no rollup row is extracted with no class, so the
  # STEROID exclusion and the maintenance flags do not apply to it.
  orphan_meds <- db_q(con, "
    SELECT c.CL_MED_ABBR, count(*) AS n_codes
    FROM mma_codelist c
    LEFT JOIN mma_rollup r ON c.CL_MED_ABBR = r.CL_MED_ABBR
    WHERE r.CL_MED_ABBR IS NULL
    GROUP BY c.CL_MED_ABBR
    ORDER BY n_codes DESC
  ")
  if (nrow(orphan_meds) > 0) {
    log_msg("  Codelist meds NOT in rollup (no class, no flags):")
    print(orphan_meds)
    problems <- rbind(problems, data.frame(check = "orphan_meds", detail = paste0(
      nrow(orphan_meds), " codelist med(s) missing from the rollup: ",
      paste(orphan_meds$CL_MED_ABBR, collapse = ", ")), stringsAsFactors = FALSE))
  } else {
    log_msg("  OK: All codelist meds found in rollup.")
  }

  # A rollup med with no codes can never be seen in a claim, so patients on it
  # look untreated.
  uncoded_meds <- db_q(con, "
    SELECT r.CL_MED_ABBR, r.CL_MED_CLASS
    FROM mma_rollup r
    LEFT JOIN mma_codelist c ON r.CL_MED_ABBR = c.CL_MED_ABBR
    WHERE c.CL_MED_ABBR IS NULL
    ORDER BY r.CL_MED_CLASS, r.CL_MED_ABBR
  ")
  if (nrow(uncoded_meds) > 0) {
    log_msg("  Rollup meds with ZERO codes (never extractable):")
    print(uncoded_meds)
    problems <- rbind(problems, data.frame(check = "uncoded_meds", detail = paste0(
      nrow(uncoded_meds), " rollup med(s) with no codes: ",
      paste(uncoded_meds$CL_MED_ABBR, collapse = ", ")), stringsAsFactors = FALSE))
  } else {
    log_msg("  OK: All rollup meds have at least one code in codelist.")
  }

  # Only these two are ever joined on, in 03_mma_map. A code of any other type
  # sits in the list and matches nothing - the medication looks unused.
  EXTRACTED_CODE_TYPES <- c("NDC", "HCPCS")
  code_types <- db_q(con, "
    SELECT CL_CODE_TYPE, count(*) AS n_codes
    FROM mma_codelist
    GROUP BY CL_CODE_TYPE
    ORDER BY CL_CODE_TYPE
  ")
  log_msg("  Code type distribution in codelist:")
  print(code_types)
  unexpected_types <- setdiff(code_types$CL_CODE_TYPE, EXTRACTED_CODE_TYPES)
  if (length(unexpected_types) > 0)
    problems <- rbind(problems, data.frame(check = "code_types", detail = paste0(
      "code type(s) nothing extracts: ", paste(unexpected_types, collapse = ", "),
      " (extraction reads ", paste(EXTRACTED_CODE_TYPES, collapse = " and "), ")"),
      stringsAsFactors = FALSE))

  # DISTINCT covers all five selected columns, but extraction joins on only
  # (CL_CODE_TYPE, CL_CODE). Two rows sharing a code but naming different drugs
  # both survive, and one claim then becomes two treatment events.
  code_to_med <- db_q(con, "
    SELECT CL_CODE_TYPE, CL_CODE, count(DISTINCT CL_MED_ABBR) AS n_meds,
           concat_ws(', ', collect_set(CL_MED_ABBR)) AS meds
    FROM mma_codelist
    GROUP BY CL_CODE_TYPE, CL_CODE
    HAVING count(DISTINCT CL_MED_ABBR) > 1
  ")
  if (nrow(code_to_med) > 0) {
    log_msg("  One code naming more than one medication:")
    print(code_to_med)
    problems <- rbind(problems, data.frame(check = "code_to_med", detail = paste0(
      nrow(code_to_med), " code(s) mapped to several meds: ",
      paste(utils::head(code_to_med$CL_CODE, 5), collapse = ", ")),
      stringsAsFactors = FALSE))
  } else {
    log_msg("  OK: Each code names exactly one medication.")
  }

  # An NDC of '0' passes the digit guard on the join and still pads to eleven
  # zeros, which is what a claim with no NDC looks like.
  bad_ndc <- db_q(con, "
    SELECT CL_CODE, CL_MED_ABBR
    FROM mma_codelist
    WHERE CL_CODE_TYPE = 'NDC'
      AND cast(regexp_replace(CL_CODE, '[^0-9]', '') AS bigint) = 0
  ")
  if (nrow(bad_ndc) > 0) {
    log_msg("  NDC rows that are all zeros:")
    print(bad_ndc)
    problems <- rbind(problems, data.frame(check = "bad_ndc", detail = paste0(
      nrow(bad_ndc), " all-zero NDC row(s): ",
      paste(bad_ndc$CL_MED_ABBR, collapse = ", ")), stringsAsFactors = FALSE))
  } else {
    log_msg("  OK: No all-zero NDC rows.")
  }

  # Two classes for one abbreviation: min() later picks one without saying so.
  multi_class <- db_q(con, "
    SELECT CL_MED_ABBR, count(DISTINCT CL_MED_CLASS) AS n_classes,
           concat_ws(', ', collect_set(CL_MED_CLASS)) AS classes
    FROM mma_codelist
    GROUP BY CL_MED_ABBR
    HAVING count(DISTINCT CL_MED_CLASS) > 1
  ")
  if (nrow(multi_class) > 0) {
    log_msg("  MED_ABBR mapping to more than one class:")
    print(multi_class)
    problems <- rbind(problems, data.frame(check = "multi_class", detail = paste0(
      nrow(multi_class), " med(s) with more than one class: ",
      paste(multi_class$CL_MED_ABBR, collapse = ", ")), stringsAsFactors = FALSE))
  } else {
    log_msg("  OK: Each MED_ABBR maps to exactly one class.")
  }

  if (nrow(problems)) {
    waived <- problems[problems$check %in% codelist_waivers(), , drop = FALSE]
    fatal  <- problems[!problems$check %in% codelist_waivers(), , drop = FALSE]
    if (nrow(waived))
      for (i in seq_len(nrow(waived)))
        log_msg("WAIVED (", waived$check[i], "): ", waived$detail[i])
    if (nrow(fatal))
      stop("The production code lists would change who counts as treated:\n  ",
           paste0(fatal$check, ": ", fatal$detail, collapse = "\n  "),
           "\nFix the code lists, or name the checks to waive in ",
           "CODELIST_WAIVERS once the study team has reviewed them, e.g. ",
           "CODELIST_WAIVERS=uncoded_meds", call. = FALSE)
  }

  # Minimum code list coverage.
  # A short list means something failed to load, not that the study is small.
  min_rollup_meds <- 20L    # the rollup carries 28

  min_codelist_codes <- 50L # the code list carries hundreds
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
