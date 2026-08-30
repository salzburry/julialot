# Code lists into views, then the consistency checks. Returns what the later
# phases need: the SCT source, and the per-med and per-class flag expressions.

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
    -- DISTINCT because this is a lookup keyed on CL_MED_ABBR. A repeated row
    -- would fan out every join against it.
    SELECT DISTINCT
      lower(trim(CL_MEDICATION_FULL)) AS CL_MEDICATION_FULL,
      upper(trim(CL_MED_CLASS))       AS CL_MED_CLASS,
      upper(trim(CL_MED_ABBR))        AS CL_MED_ABBR,
      -- Rollup fields come as 'YES', 'YES mainly...', 1, 0 or NULL. Read
      -- 'YES%' or '1' as 1, and everything else as 0.
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
    -- Steroid codes are kept separately, so the rollup should not list them
    -- either. build_lot2_5() filters the same way.
    WHERE upper(trim(coalesce(CL_MED_CLASS, ''))) <> 'STEROID'
  "), qc = "SELECT count(*) AS n_rows, count(DISTINCT CL_MED_ABBR) AS n_meds,
            sum(MONOMAINTENANCE) AS n_monomaint, sum(CONDITIONING) AS n_conditioning,
            sum(USED_FOR_OTHER_CANCERS) AS n_other_cancer FROM mma_rollup")

  run_step(con, "S01_mma_codelist", glue("
    CREATE OR REPLACE TEMPORARY VIEW mma_codelist AS
    -- DISTINCT, because a repeated row would duplicate every claim it
    -- matches.
    SELECT DISTINCT
      upper(trim(CL_CODE_TYPE)) AS CL_CODE_TYPE,
      upper(regexp_replace(trim(CL_CODE), '[^A-Za-z0-9]', '')) AS CL_CODE,
      lower(trim(CL_MEDICATION_FULL)) AS CL_MEDICATION_FULL,
      upper(trim(CL_MED_CLASS))       AS CL_MED_CLASS,
      upper(trim(CL_MED_ABBR))        AS CL_MED_ABBR
    FROM {codelist_src}
    WHERE CL_CODE IS NOT NULL AND trim(CL_CODE) <> ''
      AND CL_CODE_TYPE IS NOT NULL AND trim(CL_CODE_TYPE) <> ''
      -- The filter above tests the raw value, but the code is stored
      -- normalized, so '--' would survive as ''. The claim side turns a
      -- missing code into '' too, and the two would then match every claim
      -- with no code at all.
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

  # Check the code lists before treatment extraction. Reviewable findings need
  # a named waiver. The rest always stop the build.
  log_msg("Checking codelist <-> rollup consistency...")
  problems <- data.frame(check = character(0), detail = character(0),
                         stringsAsFactors = FALSE)

  # The rows extraction can reach. Every join in 03_mma_map is on one of these
  # two types, so a check counting any other row answers about a row the build
  # never reads. code_types keeps the full list, because the unread types are
  # what it is about.
  run_step(con, "S01b_mma_extractable_codelist", "
    CREATE OR REPLACE TEMPORARY VIEW mma_extractable_codelist AS
    SELECT * FROM mma_codelist WHERE CL_CODE_TYPE IN ('NDC', 'HCPCS')
  ", qc = "SELECT count(*) AS n_rows, count(DISTINCT CL_MED_ABBR) AS n_meds
           FROM mma_extractable_codelist")

  # A code list med with no rollup row is still extracted, and still carries
  # its class - that comes from the code list. What it has no values for are
  # the rollup flags, so no rule keyed on one of those applies to it.
  orphan_meds <- db_q(con, "
    SELECT c.CL_MED_ABBR, count(*) AS n_codes
    FROM mma_extractable_codelist c
    LEFT JOIN mma_rollup r ON c.CL_MED_ABBR = r.CL_MED_ABBR
    WHERE r.CL_MED_ABBR IS NULL
    GROUP BY c.CL_MED_ABBR
    ORDER BY n_codes DESC
  ")
  if (nrow(orphan_meds) > 0) {
    log_msg("  Codelist meds NOT in rollup (no rollup flags):")
    print(orphan_meds)
    problems <- rbind(problems, data.frame(check = "orphan_meds", detail = paste0(
      nrow(orphan_meds), " codelist med(s) missing from the rollup: ",
      paste(orphan_meds$CL_MED_ABBR, collapse = ", ")), stringsAsFactors = FALSE))
  } else {
    log_msg("  OK: All codelist meds found in rollup.")
  }

  # A rollup med with no NDC or HCPCS code can never be seen in a claim, so
  # patients on it look untreated. It may still have ICD rows.
  uncoded_meds <- db_q(con, "
    SELECT r.CL_MED_ABBR, r.CL_MED_CLASS
    FROM mma_rollup r
    LEFT JOIN mma_extractable_codelist c ON r.CL_MED_ABBR = c.CL_MED_ABBR
    WHERE c.CL_MED_ABBR IS NULL
    ORDER BY r.CL_MED_CLASS, r.CL_MED_ABBR
  ")
  if (nrow(uncoded_meds) > 0) {
    log_msg("  Rollup meds with no extractable NDC/HCPCS code:")
    print(uncoded_meds)
    problems <- rbind(problems, data.frame(check = "uncoded_meds", detail = paste0(
      nrow(uncoded_meds), " rollup med(s) with no extractable NDC/HCPCS code: ",
      paste(uncoded_meds$CL_MED_ABBR, collapse = ", ")), stringsAsFactors = FALSE))
  } else {
    log_msg("  OK: Every rollup med has an extractable NDC/HCPCS code.")
  }

  # Only these two are ever joined on, in 03_mma_map. A code of any other type
  # sits in the list and matches nothing, so the medication looks unused.
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
  # (CL_CODE_TYPE, CL_CODE). Two rows sharing a code while naming different
  # drugs both survive, and one claim then becomes two treatment events.
  code_to_med <- db_q(con, "
    SELECT CL_CODE_TYPE, join_key, count(DISTINCT CL_MED_ABBR) AS n_meds,
           concat_ws(', ', collect_set(CL_MED_ABBR)) AS meds
    FROM (
      SELECT CL_CODE_TYPE, CL_MED_ABBR,
             -- The key extraction joins on, not the stored code. The NDC join
             -- pads to eleven digits, so '123456789' and '0123456789' are one
             -- key there and would look like two here.
             CASE WHEN CL_CODE_TYPE = 'NDC'
                  THEN lpad(regexp_replace(CL_CODE, '[^0-9]', ''), 11, '0')
                  ELSE CL_CODE END AS join_key
      FROM mma_extractable_codelist
    )
    GROUP BY CL_CODE_TYPE, join_key
    HAVING count(DISTINCT CL_MED_ABBR) > 1
  ")
  if (nrow(code_to_med) > 0) {
    log_msg("  One code naming more than one medication:")
    print(code_to_med)
    problems <- rbind(problems, data.frame(check = "code_to_med", detail = paste0(
      nrow(code_to_med), " code(s) mapped to several meds: ",
      paste(utils::head(code_to_med$join_key, 5), collapse = ", ")),
      stringsAsFactors = FALSE))
  } else {
    log_msg("  OK: Each code names exactly one medication.")
  }

  # An NDC of '0' passes the digit guard on the join, then pads to eleven
  # zeros - which is what a claim with no NDC looks like.
  bad_ndc <- db_q(con, "
    SELECT CL_CODE, CL_MED_ABBR
    FROM mma_codelist
    WHERE CL_CODE_TYPE = 'NDC'
      -- String logic lets a malformed value reach ndc_shape below.
      AND regexp_replace(CL_CODE, '[^0-9]', '') RLIKE '^0+$'
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

  # NDCs must be canonical eleven-digit values. The join pads anything else
  # without complaining. Two names, because they need different answers.
  # ndc_shape cannot be an NDC at all. ndc_short is a real ten-digit form whose
  # 4-4-2 / 5-3-2 / 5-4-1 layout the pad has to guess. lot/FILES.md has the
  # arithmetic.
  ndc_shape <- db_q(con, "
    SELECT CL_CODE, CL_MED_ABBR, n_digits,
           CASE
             WHEN has_alpha      THEN 'non-digits'
             WHEN n_digits > 11  THEN 'over eleven digits'
             WHEN n_digits = 10  THEN 'ten digits'
             ELSE 'under ten digits'
           END AS why
    FROM (
      SELECT CL_CODE, CL_MED_ABBR, CL_CODE_TYPE,
             CL_CODE RLIKE '[^0-9]' AS has_alpha,
             length(regexp_replace(CL_CODE, '[^0-9]', '')) AS n_digits
      FROM mma_codelist)
    WHERE CL_CODE_TYPE = 'NDC' AND (has_alpha OR n_digits <> 11)
    ORDER BY why, CL_MED_ABBR, CL_CODE
  ")
  ten  <- ndc_shape[ndc_shape$why == "ten digits", , drop = FALSE]
  junk <- ndc_shape[ndc_shape$why != "ten digits", , drop = FALSE]
  if (nrow(junk) > 0) {
    log_msg("  NDC rows that cannot be the code they claim to be:")
    print(junk)
    problems <- rbind(problems, data.frame(check = "ndc_shape", detail = paste0(
      nrow(junk), " malformed NDC row(s): ",
      paste(utils::head(paste0(junk$CL_CODE, " (", junk$why, ")"), 5),
            collapse = ", ")), stringsAsFactors = FALSE))
  } else {
    log_msg("  OK: Every NDC is the shape of an NDC.")
  }
  if (nrow(ten) > 0) {
    log_msg("  Ten-digit NDC rows, whose segment layout the join has to guess:")
    print(ten)
    problems <- rbind(problems, data.frame(check = "ndc_short", detail = paste0(
      nrow(ten), " ten-digit NDC row(s), padded as if 4-4-2: ",
      paste(utils::head(unique(ten$CL_CODE), 5), collapse = ", "),
      ". Convert them to eleven digits in the code list, or waive ndc_short ",
      "once the study team has confirmed the layout is 4-4-2"),
      stringsAsFactors = FALSE))
  } else {
    log_msg("  OK: Every NDC is already eleven digits.")
  }

  rollup_defs <- db_q(con, "
    SELECT CL_MED_ABBR, count(*) AS n_defs
    FROM (
      SELECT DISTINCT CL_MED_ABBR, CL_MED_CLASS, MONOMAINTENANCE,
             coalesce(DUALMAINTENANCEWITH, '') AS DUALMAINTENANCEWITH,
             CONDITIONING, USED_FOR_OTHER_CANCERS
      FROM mma_rollup
    )
    GROUP BY CL_MED_ABBR
    HAVING count(*) > 1
  ")
  if (nrow(rollup_defs) > 0) {
    log_msg("  Rollup medications defined more than one way:")
    print(rollup_defs)
    problems <- rbind(problems, data.frame(check = "rollup_defs", detail = paste0(
      nrow(rollup_defs), " med(s) with conflicting rollup rows: ",
      paste(rollup_defs$CL_MED_ABBR, collapse = ", ")), stringsAsFactors = FALSE))
  } else {
    log_msg("  OK: Each rollup medication is defined one way.")
  }

  # Blank keys join to nothing useful, and make the checks above meaningless.
  blank_keys <- db_q(con, "
    SELECT
      (SELECT count(*) FROM mma_rollup
       WHERE CL_MED_ABBR IS NULL OR trim(CL_MED_ABBR) = ''
          OR CL_MED_CLASS IS NULL OR trim(CL_MED_CLASS) = '') AS n_rollup,
      (SELECT count(*) FROM mma_extractable_codelist
       WHERE CL_MED_ABBR IS NULL OR trim(CL_MED_ABBR) = ''
          OR CL_MED_CLASS IS NULL OR trim(CL_MED_CLASS) = '') AS n_codelist
  ")
  if (blank_keys$n_rollup > 0 || blank_keys$n_codelist > 0)
    problems <- rbind(problems, data.frame(check = "blank_keys", detail = paste0(
      blank_keys$n_rollup, " rollup and ", blank_keys$n_codelist,
      " codelist row(s) with a blank medication or class"),
      stringsAsFactors = FALSE))
  else
    log_msg("  OK: No blank medication or class.")

  # Two classes for one abbreviation. min() later picks one and says nothing.
  multi_class <- db_q(con, "
    SELECT CL_MED_ABBR, count(DISTINCT CL_MED_CLASS) AS n_classes,
           concat_ws(', ', collect_set(CL_MED_CLASS)) AS classes
    FROM mma_extractable_codelist
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

  # One substitute standing in for two different drugs. The fold set and the
  # fold-in's agent grouping both collapse a substitute to the drug it
  # replaces, and with two candidates min() picks lexically and says nothing -
  # so a returning drug could be read as the wrong agent's return. Fatal for
  # the same reason multi_class is: the pick is arbitrary and it reaches the
  # lines.
  multi_original <- db_q(con, "
    SELECT substitute_med, count(DISTINCT original_med) AS n_originals,
           concat_ws(', ', collect_set(original_med)) AS originals
    FROM permissible_subs
    GROUP BY substitute_med
    HAVING count(DISTINCT original_med) > 1
  ")
  if (nrow(multi_original) > 0) {
    log_msg("  Substitute standing in for more than one drug:")
    print(multi_original)
    problems <- rbind(problems, data.frame(check = "multi_original", detail = paste0(
      nrow(multi_original), " substitute(s) with more than one original: ",
      paste(multi_original$substitute_med, collapse = ", ")),
      stringsAsFactors = FALSE))
  } else {
    log_msg("  OK: Each substitute stands in for exactly one drug.")
  }

  # Claims take MED_CLASS from the code list. The LOT1_CLASS_<x> columns are
  # named from the rollup's. The two must agree or the column is always zero.
  # Compared as sets, so a med that one file classes two ways is compared
  # rather than skipped. INNER JOIN, because a med in only one file is
  # orphan_meds or uncoded_meds, and steroids are left out of the rollup on
  # purpose.
  class_agreement <- db_q(con, "
    SELECT c.CL_MED_ABBR,
           concat_ws(', ', collect_set(c.CL_MED_CLASS)) AS codelist_class,
           concat_ws(', ', collect_set(r.CL_MED_CLASS)) AS rollup_class
    FROM mma_extractable_codelist c
    INNER JOIN mma_rollup r ON c.CL_MED_ABBR = r.CL_MED_ABBR
    GROUP BY c.CL_MED_ABBR
    HAVING concat_ws(',', sort_array(collect_set(c.CL_MED_CLASS)))
        <> concat_ws(',', sort_array(collect_set(r.CL_MED_CLASS)))
    ORDER BY c.CL_MED_ABBR
  ")
  if (nrow(class_agreement) > 0) {
    log_msg("  Medications the code list and the rollup class differently:")
    print(class_agreement)
    problems <- rbind(problems, data.frame(check = "class_agreement", detail = paste0(
      nrow(class_agreement), " med(s) classed differently by the two files: ",
      paste(class_agreement$CL_MED_ABBR, collapse = ", ")),
      stringsAsFactors = FALSE))
  } else {
    log_msg("  OK: The code list and the rollup agree on every class.")
  }

  # Both abbreviations in a substitution have to be ones the code list
  # produces, or the rule matches nothing and never fires. NOT EXISTS, not
  # NOT IN: one NULL CL_MED_ABBR makes NOT IN return nothing at all.
  subs_sub <- db_q(con, "
    SELECT DISTINCT p.substitute_med AS med
    FROM permissible_subs p
    WHERE NOT EXISTS (
      SELECT 1 FROM mma_extractable_codelist c WHERE c.CL_MED_ABBR = p.substitute_med)
    ORDER BY med
  ")
  if (nrow(subs_sub) > 0) {
    log_msg("  Substitutions naming a medication the code list never produces:")
    print(subs_sub)
    problems <- rbind(problems, data.frame(check = "subs_substitute", detail = paste0(
      nrow(subs_sub), " substitute_med(s) not in the code list: ",
      paste(subs_sub$med, collapse = ", ")), stringsAsFactors = FALSE))
  } else {
    log_msg("  OK: Every substitute_med is a medication the code list produces.")
  }

  # The other side does less harm. The join simply never matches, so the
  # substitution is dead rather than wrong. But it is still a rule the study
  # team believes is running.
  subs_orig <- db_q(con, "
    SELECT DISTINCT p.original_med AS med
    FROM permissible_subs p
    WHERE NOT EXISTS (
      SELECT 1 FROM mma_extractable_codelist c WHERE c.CL_MED_ABBR = p.original_med)
    ORDER BY med
  ")
  if (nrow(subs_orig) > 0) {
    log_msg("  Substitutions for a medication the code list never produces:")
    print(subs_orig)
    problems <- rbind(problems, data.frame(check = "subs_original", detail = paste0(
      nrow(subs_orig), " original_med(s) not in the code list: ",
      paste(subs_orig$med, collapse = ", ")), stringsAsFactors = FALSE))
  } else {
    log_msg("  OK: Every original_med is a medication the code list produces.")
  }

  if (nrow(problems)) {
    waived <- problems[problems$check %in% codelist_waivers(), , drop = FALSE]
    fatal  <- problems[!problems$check %in% codelist_waivers(), , drop = FALSE]
    if (nrow(waived)) {
      for (i in seq_len(nrow(waived)))
        log_msg("WAIVED (", waived$check[i], "): ", waived$detail[i])
      # What really fired, for LOT_BUILD_STATUS. The requested list says
      # nothing about the code lists. This says what was in them. Keep
      # whatever another preflight has already recorded.
      options(lot_waivers_applied = union(
        getOption("lot_waivers_applied", character(0)), waived$check))
    }
    if (nrow(fatal))
      stop("The production code lists would change who counts as treated:\n  ",
           paste0(fatal$check, ": ", fatal$detail, collapse = "\n  "),
           "\nFix the code lists. The checks a run may waive once the study ",
           "team has reviewed them are listed in lot/FILES.md and named in ",
           "CODELIST_WAIVERS, e.g. CODELIST_WAIVERS=uncoded_meds; the rest ",
           "have no reading that leaves the result usable.", call. = FALSE)
  }

  # Minimum code list coverage.
  # A short list means something failed to load, not that the study is small.
  min_rollup_meds <- 20L    # after steroids are filtered out

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

  # Generated aliases must be unique, and the values must be safe inside a SQL
  # string literal. LOT2-5 builds its columns the same way from the same
  # rollup, so checking here covers both.
  for (nm in list(list(v = meds, what = "medication"),
                  list(v = classes, what = "class"))) {
    san <- sanitize_col(nm$v)
    dup <- unique(san[duplicated(san)])
    if (length(dup) > 0)
      stop(length(dup), " ", nm$what, " column name(s) would be generated more ",
           "than once: ",
           paste(vapply(dup, function(d)
                    paste0(d, " from ", paste(nm$v[san == d], collapse = " and ")),
                  character(1)), collapse = "; "),
           " - punctuation and spaces both become '_'.", call. = FALSE)
    quoted <- nm$v[grepl("['\\\\]", nm$v)]
    if (length(quoted) > 0)
      stop(nm$what, " name(s) carrying a quote or backslash: ",
           paste(quoted, collapse = ", "),
           " - they are written into SQL string literals as they stand.",
           call. = FALSE)
  }
  # LOT1_MED_CNT, LOT{n}_MED_CNT and LOT_MED_CNT are fixed columns holding the
  # count of induction medications. So an abbreviation of CNT would generate a
  # second column of that name at every line.
  if ("CNT" %in% sanitize_col(meds))
    stop("Medication abbreviation ",
         paste(meds[sanitize_col(meds) == "CNT"], collapse = ", "),
         " would generate LOT1_MED_CNT, which is already the induction ",
         "medication count. Rename it in the rollup.", call. = FALSE)
  log_msg("  OK: Every medication and class makes one distinct column name.")

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
