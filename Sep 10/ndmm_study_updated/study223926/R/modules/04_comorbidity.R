# Charlson (Quan 2011), the MM adjustment, and Table 4's optional extras.
#
# Table 4 asks for the CCI "adjusted for having received a MM diagnosis, such
# that a value of 0 indicates no additional comorbidities beyond MM".
#
# It cannot be made by name: Quan has no myeloma row, only `any_malignancy`,
# so dropping a condition named myeloma drops nothing and every patient scores
# a weight of 2. A CCI of 0 becomes unreachable.
#
# So it is made on the CODES - a diagnosis in mm_dx.csv supports no Charlson
# condition. MM alone scores 0; MM plus breast cancer still scores
# any_malignancy. The name test stays for a list that does name myeloma.
#
# Frailty and the subgroup flags need annexes that were not delivered, so both
# are switches, off by default. Switched on, the guard stops naming the annex.
# What the Charlson list must carry beyond its shape. The module runs it as
# it starts; the preflight runs it before the connection is opened.
check_charlson_list <- function(cfg, cl = load_codelist("charlson_quan2011.csv", cfg)) {
  if (!"weight" %in% names(cl))
    stop("CODELIST ERROR: charlson_quan2011.csv has no weight column.",
         call. = FALSE)
  invisible(cl)
}

mod_comorbidity <- function(con, cfg, cohort) {
  cl <- load_codelist("charlson_quan2011.csv", cfg)
  check_charlson_list(cfg, cl)
  # The MM adjustment's own code list, registered by the runner before any
  # module ran. Named here so the SQL below reads as one thing.
  mm_view <- "S_CL_MM_DX"

  # Quan's index is hierarchical: a patient with both mild and severe liver
  # disease scores the severe weight only, not both, and the same holds for
  # diabetes with and without complications and for cancer versus metastatic
  # solid tumour. Summing every matched condition inflates the score.
  #
  # The hierarchy is data, not code: an optional `supersedes` column naming the
  # condition each row overrides. A file without it is summed flat, and the run
  # says so rather than pretending the adjustment was made.
  has_hier <- "supersedes" %in% names(cl)
  if (!has_hier) {
    cl$supersedes <- ""
    log_msg("  NOTE: charlson_quan2011.csv has no `supersedes` column, so no ",
            "Quan hierarchy is applied. A patient with both mild and severe ",
            "liver disease will score both weights - 6 where Quan gives 4.")
  }
  reg <- register_codelist_view(con, cl, "S_CL_CHARLSON",
                                cols = c("condition", "weight", "supersedes",
                                         "code_type", "code", "icd_family"))
  prepare_table(con, wrk("S_COMORBIDITY"),
    "PATID string, COHORT string, CCI double, CCI_BAND string,
     N_CONDITIONS int", cohort$key)
  run_step(con, paste0("comorbidity_", cohort$key), sprintf("
    INSERT INTO %1$s
    WITH hits AS (
      SELECT DISTINCT p.PATID, p.COHORT, cl.condition, cl.supersedes,
             cast(cl.weight as double) AS weight
      FROM %2$s p
      INNER JOIN %3$s d
             ON cast(d.PATID as string) = p.PATID
            AND cast(d.FST_DT as date)
                BETWEEN p.COMORB_BASELINE_START AND p.COMORB_BASELINE_END
      INNER JOIN %4$s cl
             ON upper(regexp_replace(d.DIAG, '[^A-Za-z0-9]', '')) = cl.code_norm
            AND cl.icd_norm = %5$s
      -- The MM adjustment. A myeloma diagnosis supports no Charlson condition,
      -- so a patient whose only cancer is their myeloma scores 0.
      LEFT JOIN %7$s mm
             ON mm.code_norm = upper(regexp_replace(d.DIAG, '[^A-Za-z0-9]', ''))
            AND mm.icd_norm = %5$s
      WHERE p.COHORT = '%6$s'
        AND mm.code_norm IS NULL
        AND lower(cl.condition) NOT LIKE '%%myeloma%%'
    ),
    kept AS (
      -- Drop a condition that another matched condition supersedes.
      SELECT h.* FROM hits h
      LEFT JOIN hits sup
             ON sup.PATID = h.PATID AND sup.COHORT = h.COHORT
            AND lower(trim(sup.supersedes)) = lower(trim(h.condition))
            AND nullif(trim(sup.supersedes), '') IS NOT NULL
      WHERE sup.PATID IS NULL
    )
    SELECT PATID, COHORT, sum(weight) AS CCI,
           CASE WHEN sum(weight) >= 5 THEN '5+' ELSE cast(cast(sum(weight) as int) as string) END
             AS CCI_BAND,
           count(*) AS N_CONDITIONS
    FROM kept GROUP BY PATID, COHORT",
    wrk("S_COMORBIDITY"), wrk("S_PERIODS"), cdm_src("diagnosis"), reg,
    icd_family_sql("d.ICD_FLAG"), cohort$key, mm_view),
    # A cohort in which nobody has a qualifying comorbidity is a valid result -
    # every patient is CCI 0 - and the backfill immediately below is what turns
    # that into rows. Stopping here on zero matched conditions meant the
    # backfill was never reached and an all-CCI-0 cohort could not be built.
    # The check that matters is the row count AFTER the backfill, below.
    allow_empty = TRUE,
    qc = sprintf("SELECT count(*) AS n_rows, round(avg(CCI),2) AS mean_cci
                  FROM %s WHERE COHORT = '%s'", wrk("S_COMORBIDITY"), cohort$key))

  # Patients with no qualifying comorbidity have no row above; they are CCI 0,
  # not missing, and a left join downstream would report them as unknown.
  db_exec(con, sprintf("
    INSERT INTO %1$s
    SELECT p.PATID, p.COHORT, 0.0, '0', 0
    FROM %2$s p
    LEFT JOIN %1$s c ON c.PATID = p.PATID AND c.COHORT = p.COHORT
    WHERE p.COHORT = '%3$s' AND c.PATID IS NULL",
    wrk("S_COMORBIDITY"), wrk("S_PERIODS"), cohort$key))

  # And now the check that cannot legitimately come back empty: after the
  # backfill every patient in the cohort has exactly one comorbidity row.
  run_step(con, paste0("comorbidity_complete_", cohort$key), "SELECT 1",
    qc = sprintf("SELECT count(*) AS n_rows FROM %s WHERE COHORT = '%s'",
                 wrk("S_COMORBIDITY"), cohort$key))

  if (isTRUE(cfg$comorbid_subgroups)) comorbid_subgroup_flags(con, cfg, cohort)
  if (isTRUE(cfg$frailty))            frailty_index(con, cfg, cohort)
}

# Table 4's subgroup flags - baseline history of neuropathy, of lung
# parenchymal disease, and of whatever else Annex 3 names. One row per patient
# per concept, so a concept added to the code list needs no change here.
comorbid_subgroup_flags <- function(con, cfg, cohort) {
  cl <- load_codelist("comorbid_subgroups.csv", cfg)
  reg <- register_codelist_view(con, cl, "S_CL_SUBGROUPS",
                                cols = c("concept", "code_type", "code",
                                         "icd_family"))
  prepare_table(con, wrk("S_COMORB_SUBGROUP"),
    "PATID string, COHORT string, CONCEPT string, HAS_HISTORY int,
     FIRST_DT date", cohort$key)
  run_step(con, paste0("comorbid_subgroups_", cohort$key), sprintf("
    INSERT INTO %1$s
    WITH hits AS (
      SELECT p.PATID, p.COHORT, c.concept,
             min(cast(d.FST_DT as date)) AS FIRST_DT
      FROM %2$s p
      INNER JOIN %4$s d
             ON cast(d.PATID as string) = p.PATID
            AND cast(d.FST_DT as date)
                BETWEEN p.COMORB_BASELINE_START AND p.COMORB_BASELINE_END
      INNER JOIN %3$s c
             ON upper(regexp_replace(d.DIAG, '[^A-Za-z0-9]', '')) = c.code_norm
            AND c.icd_norm = %5$s
      WHERE p.COHORT = '%6$s'
      GROUP BY p.PATID, p.COHORT, c.concept
    )
    -- Every patient gets a row for every concept: absence of history is 0,
    -- not a missing row that a downstream join would read as unknown.
    SELECT p.PATID, p.COHORT, cc.concept,
           CASE WHEN h.PATID IS NULL THEN 0 ELSE 1 END AS HAS_HISTORY,
           h.FIRST_DT
    FROM %2$s p
    CROSS JOIN (SELECT DISTINCT concept FROM %3$s) cc
    LEFT JOIN hits h ON h.PATID = p.PATID AND h.COHORT = p.COHORT
                    AND h.concept = cc.concept
    WHERE p.COHORT = '%6$s'",
    wrk("S_COMORB_SUBGROUP"), wrk("S_PERIODS"), reg, cdm_src("diagnosis"),
    icd_family_sql("d.ICD_FLAG"), cohort$key),
    qc = sprintf("SELECT count(*) AS n_rows, sum(HAS_HISTORY) AS n_with_history
                  FROM %s WHERE COHORT = '%s'", wrk("S_COMORB_SUBGROUP"),
                 cohort$key))
}

# The Kim 2018 claims-based frailty index: a linear score over binary claim
# indicators, frail at >= 0.25.
#
# The variable list, the coefficients and the codes behind them are all Annex
# 7. load_codelist() stops here naming it. That is the point of the switch: a
# run that asks for frailty is told exactly what is missing, rather than
# getting a column of zeros that reads as a cohort with no frail patients.
frailty_index <- function(con, cfg, cohort) {
  cl <- load_codelist("frailty_kim2018.csv", cfg)
  # Two inputs this implementation cannot honour, checked before it runs.
  #
  # An intercept applies to every patient, but the score is built by matching
  # rows to diagnosis codes and an intercept has none - it would drop out of
  # every score. A non-diagnosis feature needs its own source table, and every
  # row here is matched against MED_DIAGNOSIS.
  #
  # Either is a wrong score reported as a score, so either stops the run.
  vv <- tolower(trimws(as.character(cl$variable)))
  if (any(vv == "intercept"))
    stop("FRAILTY ERROR: frailty_kim2018.csv carries an `intercept` row, and ",
         "this implementation matches every row to a diagnosis code - so the ",
         "intercept would apply to nobody and every score would be short by ",
         "it. The intercept has to be added to all patients before this ",
         "module can be used. ../OPEN_QUESTIONS.md Q15 (Annex 7).",
         call. = FALSE)
  if ("code_type" %in% names(cl)) {
    ct <- toupper(trimws(as.character(cl$code_type)))
    bad <- sort(unique(ct[nzchar(ct) & !ct %in% c("ICD9DIAG", "ICD10DIAG")]))
    if (length(bad))
      stop("FRAILTY ERROR: frailty_kim2018.csv carries feature(s) of ",
           "code_type ", paste(bad, collapse = ", "), ", and this ",
           "implementation reads MED_DIAGNOSIS only - those coefficients ",
           "would match nothing and be dropped from every score without a ",
           "trace. Route them to their own source tables before enabling ",
           "FRAILTY. ../OPEN_QUESTIONS.md Q15 (Annex 7).", call. = FALSE)
  }
  reg <- register_codelist_view(con, cl, "S_CL_FRAILTY",
                                cols = c("variable", "coefficient", "code_type",
                                         "code", "icd_family"))
  prepare_table(con, wrk("S_FRAILTY"),
    "PATID string, COHORT string, CFI double, FRAIL int, N_VARIABLES int",
    cohort$key)
  # The intercept is Annex 7's too. Without it the score is the sum of the
  # matched coefficients, which is the model minus its constant - so it is
  # carried as a row named `intercept` in the code list rather than assumed,
  # and its absence is visible in N_VARIABLES.
  run_step(con, paste0("frailty_", cohort$key), sprintf("
    INSERT INTO %1$s
    WITH matched AS (
      SELECT DISTINCT p.PATID, p.COHORT, cl.variable,
             cast(cl.coefficient as double) AS coefficient
      FROM %2$s p
      INNER JOIN %4$s d
             ON cast(d.PATID as string) = p.PATID
            AND cast(d.FST_DT as date)
                BETWEEN p.COMORB_BASELINE_START AND p.COMORB_BASELINE_END
      INNER JOIN %3$s cl
             ON upper(regexp_replace(d.DIAG, '[^A-Za-z0-9]', '')) = cl.code_norm
            AND cl.icd_norm = %5$s
      WHERE p.COHORT = '%6$s'
    ),
    scored AS (
      SELECT PATID, COHORT, sum(coefficient) AS CFI, count(*) AS N_VARIABLES
      FROM matched GROUP BY PATID, COHORT
    )
    SELECT p.PATID, p.COHORT,
           coalesce(s.CFI, 0.0) AS CFI,
           CASE WHEN coalesce(s.CFI, 0.0) >= %7$s THEN 1 ELSE 0 END AS FRAIL,
           coalesce(s.N_VARIABLES, 0) AS N_VARIABLES
    FROM %2$s p
    LEFT JOIN scored s ON s.PATID = p.PATID AND s.COHORT = p.COHORT
    WHERE p.COHORT = '%6$s'",
    wrk("S_FRAILTY"), wrk("S_PERIODS"), reg, cdm_src("diagnosis"),
    icd_family_sql("d.ICD_FLAG"), cohort$key,
    format(cfg$frailty_frail_cutoff, nsmall = 2)),
    qc = sprintf("SELECT count(*) AS n_rows, sum(FRAIL) AS n_frail
                  FROM %s WHERE COHORT = '%s'", wrk("S_FRAILTY"), cohort$key))
}
