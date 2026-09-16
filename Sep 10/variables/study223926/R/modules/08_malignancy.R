# Secondary malignancies - Primary Objective 3.
#
# Table 4: "Occurrence of malignancy to be confirmed through the presence of at
# least 2 diagnosis codes occurring on separate dates. The date of the first
# ICD code will be used." So a single code is not an occurrence, and the date
# is the FIRST of the confirming pair - which puts the event earlier than its
# confirmation and shortens every time-to-malignancy figure.
#
# s7.8.1 also splits the two cohorts:
#   1L nested - prior malignancy is excluded by X2, so incidence only
#   2L (secondary) - prior malignancy is permitted, so prevalence AND incidence
# That split is read off the cohort's own criteria rather than hard-coded, so
# it follows SEC2L_APPLY_OTHER_CANCER.
# The aggregate row: every category as one. s7.8.1 names "malignancies" as
# ONE chronic condition, so beside the per-category rates there is the rate
# of a first malignancy of any kind - counted once, at the first of them,
# with a patient who had any before the period out of both numerator and
# denominator, and at-risk time ending at the first one. Table 3's total row
# and Figure 4 read this rather than adding categories, which a rate cannot.
MALIG_ANY_CATEGORY <- "(any malignancy)"

# What the malignancy list must satisfy beyond its shape: none of its codes is
# a multiple myeloma code. Table 4's secondary malignancy is "a malignancy
# other than MM"; a myeloma code on this list would confirm every patient's
# own disease as a secondary malignancy on their first two claims, and the
# study's headline rate would be about 100%. The module runs it as it starts;
# the preflight runs it before the connection is opened. Codes are compared
# the way the SQL joins them - upper-cased, punctuation stripped, within the
# ICD family - and a row with no code yet is not a clash.
check_malignancy_list <- function(cfg, cl = load_codelist("secondary_malig.csv", cfg)) {
  mm <- load_codelist("mm_dx.csv", cfg)
  norm <- function(x) toupper(gsub("[^A-Za-z0-9]", "", as.character(x)))
  fam <- function(x) {
    u <- toupper(trimws(as.character(x)))
    ifelse(u %in% c("9", "ICD9", "ICD-9", "ICD9DIAG"), "ICD9",
    ifelse(u %in% c("10", "ICD10", "ICD-10", "ICD10DIAG"), "ICD10", NA_character_))
  }
  code_col <- if ("code" %in% names(cl)) "code" else "dx"
  mm_col   <- if ("dx" %in% names(mm)) "dx" else "code"
  mm_key <- paste(fam(mm$icd_family), norm(mm[[mm_col]]))
  cl_key <- paste(fam(cl$icd_family), norm(cl[[code_col]]))
  clash <- nzchar(norm(cl[[code_col]])) & cl_key %in% mm_key
  if (any(clash)) {
    rows <- cl[clash, , drop = FALSE]
    stop("CODELIST ERROR: secondary_malig.csv carries ", sum(clash),
         " code(s) that mm_dx.csv names as multiple myeloma: ",
         paste(unique(sprintf("%s (%s, %s)", rows[[code_col]], rows$icd_family,
                              rows$category)), collapse = "; "),
         ".\nTable 4's secondary malignancy is a malignancy other than the ",
         "myeloma under treatment; a myeloma code here would confirm every ",
         "patient's own disease as a secondary malignancy. Remove the code, ",
         "or say why the study is counting the myeloma itself.", call. = FALSE)
  }
  invisible(cl)
}

mod_malignancy <- function(con, cfg, cohort) {
  cl <- load_codelist("secondary_malig.csv", cfg)
  cl <- check_malignancy_list(cfg, cl)
  reg <- register_codelist_view(con, cl, "S_CL_MALIG",
    cols = c("category", "subtype", "code_type", "code", "icd_family"))

  prepare_table(con, wrk("S_MALIGNANCY"),
    "PATID string, COHORT string, CATEGORY string, SUBTYPE string,
     FIRST_DT date, CONFIRM_DT date, N_DATES int,
     LOT_AFTER_WHICH int, AFTER_INDEX int,
     MONTHS_FROM_DX double, MONTHS_FROM_INDEX double",
    cohort$key)
  prepare_table(con, wrk("S_MALIGNANCY_RATES"),
    "COHORT string, LOT_NUM int, PERIOD string,
     SOC_CATEGORY string, AGE_GROUP string, CATEGORY string,
     N_PATIENTS int, N_AT_RISK int, PERSON_YEARS double, RATE double,
     RATE_LO double, RATE_HI double", cohort$key)
  run_step(con, paste0("malignancy_", cohort$key), sprintf("
    INSERT INTO %1$s
    WITH dates AS (
      SELECT DISTINCT p.PATID, p.COHORT, cl.category, cl.subtype,
                      cast(d.FST_DT as date) AS EVENT_DT
      FROM %2$s p
      INNER JOIN %3$s d ON cast(d.PATID as string) = p.PATID
      INNER JOIN %4$s cl
             ON upper(regexp_replace(d.DIAG, '[^A-Za-z0-9]', '')) = cl.code_norm
            AND cl.icd_norm = %5$s
      WHERE p.COHORT = '%6$s' AND d.FST_DT IS NOT NULL
        -- Bounded by this cohort's own observation. Unbounded, a second
        -- diagnosis after disenrollment, after death, or in a later enrolment
        -- span confirmed an earlier event retrospectively - the study would be
        -- reporting an occurrence it did not observe. FU_END is per patient
        -- and per cohort, so the same malignancy can be confirmed for a later
        -- cohort that did observe it and not for an earlier one that did not.
        AND cast(d.FST_DT as date) <= p.FU_END
    ),
    confirmed AS (
      SELECT PATID, COHORT, category, subtype,
             min(EVENT_DT) AS FIRST_DT,
             min(CASE WHEN rn = 2 THEN EVENT_DT END) AS CONFIRM_DT,
             count(*) AS N_DATES
      FROM (SELECT *, row_number() OVER (PARTITION BY PATID, COHORT, category,
                                                      subtype
                                         ORDER BY EVENT_DT) AS rn
            FROM dates) t
      GROUP BY PATID, COHORT, category, subtype
      HAVING count(*) >= 2
    ),
    -- The line the malignancy fell after, as a join rather than a correlated
    -- scalar subquery: Spark rejects a correlation on a non-equality
    -- predicate, and LOT_START_DT <= FIRST_DT is one.
    lot_after AS (
      SELECT c.PATID, c.COHORT, c.category, c.subtype,
             max(l.LOT_NUM) AS LOT_AFTER_WHICH
      FROM confirmed c
      LEFT JOIN %7$s l
             ON l.PATID = c.PATID AND l.LOT_START_DT <= c.FIRST_DT
      GROUP BY c.PATID, c.COHORT, c.category, c.subtype
    )
    SELECT c.PATID, c.COHORT, c.category, c.subtype, c.FIRST_DT, c.CONFIRM_DT,
           c.N_DATES, la.LOT_AFTER_WHICH,
           -- Table 4 measures time from the index to the malignancy '2L only
           -- among those where the malignancy occurred after 2L', and the
           -- secondary cohort permits one before it. The flag says which; the
           -- duration is NULL for a malignancy before the index rather than a
           -- negative number a mean would swallow.
           CASE WHEN c.FIRST_DT > p.INDEX_DATE THEN 1 ELSE 0 END AS AFTER_INDEX,
           %8$s AS MONTHS_FROM_DX,
           CASE WHEN c.FIRST_DT >= p.INDEX_DATE THEN %9$s END AS MONTHS_FROM_INDEX
    FROM confirmed c
    INNER JOIN lot_after la ON la.PATID = c.PATID AND la.COHORT = c.COHORT
                           AND la.category = c.category
                           AND la.subtype <=> c.subtype
    INNER JOIN %2$s p ON p.PATID = c.PATID AND p.COHORT = c.COHORT
    INNER JOIN %10$s co ON co.PATID = c.PATID",
    wrk("S_MALIGNANCY"), wrk("S_PERIODS"), cdm_src("diagnosis"), reg,
    icd_family_sql("d.ICD_FLAG"), cohort$key, wrk("S_SPINE"),
    # Table 4: diagnosis date (included) until the malignancy date (included).
    # The diagnosis date is the study's one diagnosis date, S_PERIODS.DX_DT,
    # whichever reading DX_DATE_SOURCE took.
    days_to_months_sql(interval_days_sql("p.DX_DT", "c.FIRST_DT", TRUE, TRUE)),
    days_to_months_sql(interval_days_sql("p.INDEX_DATE", "c.FIRST_DT", TRUE, TRUE)),
    wrk("S_ELIGIBILITY")),
    qc = sprintf("SELECT count(*) AS n_rows, count(DISTINCT PATID) AS n_pat
                  FROM %s WHERE COHORT='%s'", wrk("S_MALIGNANCY"), cohort$key),
    allow_empty = TRUE)

  # Every qualifying diagnosis DATE for a confirmed category, not just the
  # first. Baseline prevalence needs it: a cancer first coded years before
  # baseline and coded again during it IS present during baseline, whereas the
  # GLOBAL first date answers a different question - new onset - and returns
  # zero for the established malignancies the secondary 2L cohort describes.
  #
  # prepare_table + INSERT, not CREATE OR REPLACE: this module runs once per
  # cohort, so replacing the whole table would leave only the last cohort's
  # rows.
  prepare_table(con, wrk("S_MALIGNANCY_DATES"),
    "PATID string, COHORT string, CATEGORY string, SUBTYPE string,
     EVENT_DT date",
    cohort$key)
  db_exec(con, sprintf("
    INSERT INTO %1$s
    SELECT DISTINCT p.PATID, p.COHORT, cl.category AS CATEGORY,
                    cl.subtype AS SUBTYPE,
                    cast(d.FST_DT as date) AS EVENT_DT
    FROM %2$s p
    INNER JOIN %3$s d ON cast(d.PATID as string) = p.PATID
    INNER JOIN %4$s cl
           ON upper(regexp_replace(d.DIAG, '[^A-Za-z0-9]', '')) = cl.code_norm
          AND cl.icd_norm = %5$s
    -- Matched on SUBTYPE as well as category, which is the grain confirmation
    -- was established at. On category alone a single baseline code of one
    -- subtype borrowed the two-date confirmation of a different subtype in the
    -- same category and was reported as baseline prevalence on its own.
    INNER JOIN %6$s m ON m.PATID = p.PATID AND m.COHORT = p.COHORT
                     AND m.CATEGORY = cl.category
                     AND m.SUBTYPE <=> cl.subtype
    WHERE p.COHORT = '%7$s' AND d.FST_DT IS NOT NULL
      AND cast(d.FST_DT as date) <= p.FU_END",
    wrk("S_MALIGNANCY_DATES"), wrk("S_PERIODS"), cdm_src("diagnosis"), reg,
    icd_family_sql("d.ICD_FLAG"), wrk("S_MALIGNANCY"), cohort$key))

  # The confirmed malignancies with the aggregate beside them: one more
  # category per patient, MALIG_ANY_CATEGORY, dated at the first of any kind.
  # Every rate below reads these views, so the aggregate is the same
  # arithmetic as a category and not a second implementation of it.
  db_exec(con, sprintf("
    CREATE OR REPLACE TEMPORARY VIEW s_malig_first AS
    SELECT PATID, COHORT, CATEGORY, FIRST_DT FROM %1$s WHERE COHORT = '%2$s'
    UNION ALL
    SELECT PATID, COHORT, '%3$s' AS CATEGORY, min(FIRST_DT) AS FIRST_DT
    FROM %1$s WHERE COHORT = '%2$s' GROUP BY PATID, COHORT",
    wrk("S_MALIGNANCY"), cohort$key, MALIG_ANY_CATEGORY))
  db_exec(con, sprintf("
    CREATE OR REPLACE TEMPORARY VIEW s_malig_dates AS
    SELECT PATID, COHORT, CATEGORY, EVENT_DT FROM %1$s WHERE COHORT = '%2$s'
    UNION ALL
    SELECT DISTINCT PATID, COHORT, '%3$s' AS CATEGORY, EVENT_DT
    FROM %1$s WHERE COHORT = '%2$s'",
    wrk("S_MALIGNANCY_DATES"), cohort$key, MALIG_ANY_CATEGORY))

  # Malignancy is on the s7.8.1 chronic list, so incidence counts the first
  # occurrence only and a patient with one BEFORE the treatment period is not
  # at risk: they leave both the numerator and the person-time denominator.
  # Prevalence is reported only for a cohort whose criteria permit a prior
  # malignancy - for the others it would be zero by construction.
  db_exec(con, sprintf("
    CREATE OR REPLACE TEMPORARY VIEW s_malig_prior AS
    SELECT DISTINCT p.PATID, p.COHORT, p.LOT_NUM, m.CATEGORY
    FROM %s p
    INNER JOIN %s m ON m.PATID = p.PATID AND m.COHORT = p.COHORT
    WHERE p.COHORT = '%s' AND m.FIRST_DT < p.PERIOD_START",
    wrk("S_LOT_PERIODS"), "s_malig_first", cohort$key))

  # Baseline prevalence is reported for a cohort that can HAVE a prior
  # malignancy, and there are two ways it cannot.
  #
  # The first is this cohort's verdict. X2 reaches 2L and 3L through the cohort
  # they are nested in, so the test walks the chain rather than reading this
  # cohort's own list - and it is given cfg, because nesting is a setting.
  # Under COHORT_NESTED=FALSE there is no parent join, membership never ANDs
  # MET_X2, and 2L holds the patients 1L excluded; suppressing the number there
  # hid the one thing that changed.
  #
  # The second is the input. Where the cohort build pre-filtered on X2 it
  # retained no flag, every MET_X2 is 1 for everyone, and the answer is zero
  # whatever this cohort's own verdict is - so it is not a measurement and is
  # not published as one.
  x2 <- CRITERION_FLAG[["X2_other_cancer"]]
  reports_prevalence <- !cohort_applies(cohort, "X2_other_cancer", cfg) &&
                        x2 %in% .cohort_cols()

  # The line as a whole, then each regimen category, from the same query.
  for (sp in stratum_passes(cfg, "p")) {
  run_step(con, paste0("malignancy_rates_", cohort$key, "_", sp$key), sprintf("
    INSERT INTO %1$s
    WITH cats AS (SELECT DISTINCT category FROM %6$s
                  UNION ALL SELECT '%14$s' AS category),
    den AS (
      -- Malignancy is on the s7.8.1 chronic list, so it is counted once at
      -- first occurrence - and a patient who has that first occurrence stops
      -- being at risk of a first one there. The denominator has to end with
      -- them, exactly as 06_safety.R does for the other chronic conditions.
      -- Summing the whole PERIOD_PY regardless kept counting time in which a
      -- first event was no longer possible, which overstates at-risk time and
      -- understates incidence.
      SELECT p.COHORT, p.LOT_NUM, %9$s, c.category,
             sum(CASE
                   WHEN h.PATID IS NOT NULL THEN 0
                   WHEN fm.FIRST_DT IS NOT NULL THEN %8$s
                   ELSE p.PERIOD_PY END) AS PY,
             count(DISTINCT CASE WHEN h.PATID IS NOT NULL THEN NULL
                                 ELSE p.PATID END) AS N_AT_RISK
      FROM %4$s p
      CROSS JOIN cats c
      LEFT JOIN (SELECT PATID, COHORT, CATEGORY, min(FIRST_DT) AS FIRST_DT
                 FROM %7$s WHERE COHORT = '%5$s'
                 GROUP BY PATID, COHORT, CATEGORY) fm
             ON fm.PATID = p.PATID AND fm.COHORT = p.COHORT
            AND fm.CATEGORY = c.category
      LEFT JOIN s_malig_prior h
             ON h.PATID = p.PATID AND h.COHORT = p.COHORT
            AND h.LOT_NUM = p.LOT_NUM AND h.CATEGORY = c.category
      %10$s
      WHERE p.COHORT = '%5$s' AND p.PERIOD_PY IS NOT NULL
      GROUP BY p.COHORT, p.LOT_NUM, c.category%11$s
    ),
    num AS (
      SELECT p.COHORT, p.LOT_NUM, %9$s, m.CATEGORY,
             count(DISTINCT m.PATID) AS N_PATIENTS
      FROM %3$s m
      INNER JOIN %4$s p ON p.PATID = m.PATID AND p.COHORT = m.COHORT
      LEFT JOIN s_malig_prior h
             ON h.PATID = m.PATID AND h.COHORT = p.COHORT
            AND h.LOT_NUM = p.LOT_NUM AND h.CATEGORY = m.CATEGORY
      %10$s
      WHERE p.COHORT = '%5$s' AND h.PATID IS NULL
        AND m.FIRST_DT BETWEEN p.PERIOD_START AND p.PERIOD_END
      GROUP BY p.COHORT, p.LOT_NUM, m.CATEGORY%11$s
    )
    SELECT den.COHORT, den.LOT_NUM, 'TREATMENT' AS PERIOD,
           den.SOC_CATEGORY, den.AGE_GROUP, den.category,
           coalesce(num.N_PATIENTS, 0) AS N_PATIENTS, den.N_AT_RISK,
           den.PY AS PERSON_YEARS, %2$s AS RATE,
           %12$s AS RATE_LO, %13$s AS RATE_HI
    FROM den
    LEFT JOIN num ON num.COHORT = den.COHORT AND num.LOT_NUM = den.LOT_NUM
                 AND num.CATEGORY = den.category
                 AND num.SOC_CATEGORY = den.SOC_CATEGORY
                 AND num.AGE_GROUP = den.AGE_GROUP",
    wrk("S_MALIGNANCY_RATES"),
    rate_sql("coalesce(num.N_PATIENTS, 0)", "den.PY", cfg),
    "s_malig_first", wrk("S_LOT_PERIODS"), cohort$key, "S_CL_MALIG",
    "s_malig_first",
    # At-risk time to the first confirmed occurrence, both endpoints included -
    # the same convention PERIOD_PY uses.
    person_years_sql("p.PERIOD_START", "least(fm.FIRST_DT, p.PERIOD_END)", cfg),
    sp$cols, sp$join, sp$group,
    rate_ci_sql("coalesce(num.N_PATIENTS, 0)", "den.PY", cfg, "lo"),
    rate_ci_sql("coalesce(num.N_PATIENTS, 0)", "den.PY", cfg, "hi"),
    MALIG_ANY_CATEGORY),
    qc = sprintf("SELECT count(*) AS n_rows FROM %s WHERE COHORT='%s'",
                 wrk("S_MALIGNANCY_RATES"), cohort$key),
    allow_empty = TRUE)
  }

  if (reports_prevalence) {
    # The window the prevalence is taken over. s7.4.1.2 and s7.8.4, which are
    # about the cohort that permits a prior malignancy: "all malignancies
    # occurring after diagnosis but prior to 2L will be tabulated as the
    # background prevalence" - the diagnosis day and the index day both
    # excluded, and the person-time is that interval's. s7.8.1's summary of
    # the same analysis says "during baseline", the 12-month window, which
    # MALIG_PREVALENCE_WINDOW=baseline takes instead. ../OPEN_QUESTIONS.md Q31.
    win <- if (identical(cfg$malig_prevalence_window, "baseline"))
      list(start = "p.BASELINE_START", end = "p.BASELINE_END", py = "p.BASELINE_PY")
    else list(start = "date_add(p.DX_DT, 1)", end = "date_sub(p.INDEX_DATE, 1)",
              py = sprintf("CASE WHEN p.INDEX_DATE > p.DX_DT THEN %s ELSE 0 END",
                           person_years_sql("date_add(p.DX_DT, 1)",
                                            "date_sub(p.INDEX_DATE, 1)", cfg)))
    # Driven from the denominator crossed with the category list, like the
    # incidence block above: a category with no baseline events would otherwise
    # produce no row, which downstream cannot be told from the module not
    # having run for it.
    for (sp in stratum_passes(cfg, "p")) {
    run_step(con, paste0("malignancy_prevalence_", cohort$key, "_", sp$key),
      sprintf("
      INSERT INTO %1$s
      WITH cats AS (SELECT DISTINCT category FROM %5$s
                    UNION ALL SELECT '%15$s' AS category),
      den AS (
        SELECT p.COHORT, p.LOT_NUM, %7$s,
               sum(%12$s) AS PY,
               count(DISTINCT p.PATID) AS N_AT_RISK
        FROM %3$s p
        %8$s
        WHERE p.COHORT = '%4$s' GROUP BY p.COHORT, p.LOT_NUM%9$s
      ),
      num AS (
        -- ANY qualifying date inside the window, not the global first one.
        -- s7.8.1 baseline is prevalence - what is PRESENT - and it is taken
        -- irrespective of prior event history, so a malignancy first coded
        -- before the window and coded again during it belongs here.
        SELECT p.COHORT, p.LOT_NUM, %7$s, m.CATEGORY,
               count(DISTINCT m.PATID) AS N_PATIENTS
        FROM %6$s m
        INNER JOIN %3$s p ON p.PATID = m.PATID AND p.COHORT = m.COHORT
        %8$s
        WHERE p.COHORT = '%4$s'
          AND m.EVENT_DT BETWEEN %10$s AND %11$s
        GROUP BY p.COHORT, p.LOT_NUM, m.CATEGORY%9$s
      )
      SELECT den.COHORT, den.LOT_NUM, 'BASELINE' AS PERIOD,
             den.SOC_CATEGORY, den.AGE_GROUP, cats.category,
             coalesce(num.N_PATIENTS, 0), den.N_AT_RISK, den.PY, %2$s,
             %13$s, %14$s
      FROM den
      CROSS JOIN cats
      LEFT JOIN num ON num.COHORT = den.COHORT AND num.LOT_NUM = den.LOT_NUM
                   AND num.CATEGORY = cats.category
                   AND num.SOC_CATEGORY = den.SOC_CATEGORY
                   AND num.AGE_GROUP = den.AGE_GROUP",
      wrk("S_MALIGNANCY_RATES"),
      rate_sql("coalesce(num.N_PATIENTS, 0)", "den.PY", cfg),
      wrk("S_PERIODS"), cohort$key, "S_CL_MALIG",
      "s_malig_dates", sp$cols, sp$join, sp$group,
      win$start, win$end, win$py,
      rate_ci_sql("coalesce(num.N_PATIENTS, 0)", "den.PY", cfg, "lo"),
      rate_ci_sql("coalesce(num.N_PATIENTS, 0)", "den.PY", cfg, "hi"),
      MALIG_ANY_CATEGORY),
      qc = sprintf("SELECT count(*) AS n_rows FROM %s
                    WHERE COHORT='%s' AND PERIOD='BASELINE'",
                   wrk("S_MALIGNANCY_RATES"), cohort$key))
    }
    log_msg("  ", cohort$key, " permits a prior malignancy, so background ",
            "prevalence is reported alongside incidence, over the ",
            cfg$malig_prevalence_window, " window (s7.8.1, s7.8.4).")
  } else {
    log_msg("  ", cohort$key, " excludes a prior malignancy (X2), so no ",
            "baseline prevalence is reported - it would be zero by ",
            "construction (s7.8.1).")
  }

  # Table 4: "Tabulation of the top 5-10 sequences among those with a
  # malignancy occurring after treatment. For sensitivity analysis - this will
  # be tabulated among those with a new malignancy occurring only after 2L".
  # Every sequence with its count, ranked, so the reader picks the top
  # however many; two scopes, one per sentence. In regimen categories, which
  # are the soc module's, so written where that module ran.
  #
  # "Sequences" is not pinned to a side of the malignancy, and the two
  # readings answer different questions: the lines the patient had been
  # given WHEN the malignancy appeared are its exposure history, which is
  # what a background-rate study is describing; the lines given AFTER it say
  # what happened to their myeloma treatment. So the table carries both, and
  # the whole observed sequence beside them, on LINES - three rows per
  # sequence and scope, each its own denominator - rather than choosing one
  # in code and losing the other. ../OPEN_QUESTIONS.md Q32.
  #
  #   to_malignancy      lines started on or before the malignancy's first
  #                      date - the line it appeared in is the last of them
  #   after_malignancy   lines started after it; '(no further therapy)' when
  #                      none was observed
  #   all_observed       every line from the cohort's index within follow-up
  prepare_table(con, wrk("S_MALIGNANCY_SEQUENCES"),
    "COHORT string, SCOPE string, LINES string, SEQUENCE string,
     N_PATIENTS int, N_DENOM int, PCT double, RANK int", cohort$key)
  if (soc_stratified(cfg)) {
    lines <- seq_len(as.integer(cfg$max_lot))
    seq_joins <- paste(sprintf(
      "LEFT JOIN %s s%d ON s%d.PATID = q.PATID AND s%d.COHORT = q.COHORT AND s%d.LOT_NUM = %d",
      wrk("S_SOC"), lines, lines, lines, lines, lines), collapse = "\n      ")
    # One expression per LINES value, over the same joined lines: a line
    # outside the reading is NULL and concat_ws skips it.
    seq_of <- function(keep) sprintf("concat_ws(' -> ', %s)", paste(
      sprintf("CASE WHEN %s THEN s%d.SOC_CATEGORY END",
              sprintf(keep, lines), lines), collapse = ", "))
    seq_to    <- seq_of("s%d.LOT_START_DT <= q.FIRST_DT")
    seq_after <- seq_of("s%d.LOT_START_DT >  q.FIRST_DT")
    seq_all   <- seq_of("s%d.PATID IS NOT NULL")
    run_step(con, paste0("malignancy_sequences_", cohort$key), sprintf("
      INSERT INTO %1$s
      WITH pts AS (
        -- One row per patient and scope, dated at the FIRST qualifying
        -- malignancy, which is the one the sequence is split around.
        SELECT m.PATID, m.COHORT, 'after_index' AS SCOPE, min(m.FIRST_DT) AS FIRST_DT
        FROM %2$s m WHERE m.COHORT = '%3$s' AND m.AFTER_INDEX = 1
        GROUP BY m.PATID, m.COHORT
        UNION ALL
        SELECT m.PATID, m.COHORT, 'after_2l' AS SCOPE, min(m.FIRST_DT) AS FIRST_DT
        FROM %2$s m
        INNER JOIN %4$s l2 ON l2.PATID = m.PATID AND l2.LOT_NUM = 2
        WHERE m.COHORT = '%3$s' AND m.FIRST_DT > l2.LOT_START_DT
        GROUP BY m.PATID, m.COHORT
      ),
      seq AS (
        -- The lines from this cohort's index line onward, within its
        -- follow-up: that is what S_SOC holds for a cohort, so a line before
        -- the index or after follow-up ended is NULL and concat_ws skips it.
        SELECT q.PATID, q.COHORT, q.SCOPE, 'to_malignancy' AS LINES,
               coalesce(nullif(%5$s, ''), '(no regimen recorded)') AS SEQUENCE
        FROM pts q
        %8$s
        UNION ALL
        SELECT q.PATID, q.COHORT, q.SCOPE, 'after_malignancy' AS LINES,
               coalesce(nullif(%6$s, ''), '(no further therapy)') AS SEQUENCE
        FROM pts q
        %8$s
        UNION ALL
        SELECT q.PATID, q.COHORT, q.SCOPE, 'all_observed' AS LINES,
               coalesce(nullif(%7$s, ''), '(no regimen recorded)') AS SEQUENCE
        FROM pts q
        %8$s
      )
      SELECT COHORT, SCOPE, LINES, SEQUENCE, count(*) AS N_PATIENTS,
             sum(count(*)) OVER (PARTITION BY COHORT, SCOPE, LINES) AS N_DENOM,
             round(100.0 * count(*) / sum(count(*)) OVER (PARTITION BY COHORT, SCOPE, LINES), 1)
               AS PCT,
             row_number() OVER (PARTITION BY COHORT, SCOPE, LINES
                                ORDER BY count(*) DESC, SEQUENCE) AS RANK
      FROM seq GROUP BY COHORT, SCOPE, LINES, SEQUENCE",
      wrk("S_MALIGNANCY_SEQUENCES"), wrk("S_MALIGNANCY"), cohort$key,
      wrk("S_SPINE"), seq_to, seq_after, seq_all, seq_joins),
      qc = sprintf("SELECT count(*) AS n_rows FROM %s WHERE COHORT='%s'",
                   wrk("S_MALIGNANCY_SEQUENCES"), cohort$key),
      allow_empty = TRUE)
  } else {
    log_msg("  the soc module did not run, so the treatment sequences of ",
            "patients with a malignancy are not written for ", cohort$key)
  }
}
