# Charlson (Quan 2011) and the Kim claims-based frailty index.
#
# Table 4 asks for the CCI "adjusted for having received a MM diagnosis, such
# that a value of 0 indicates no additional comorbidities beyond MM" - so the
# myeloma condition's weight is zeroed rather than the patient's MM claims
# being filtered out, which would also remove a genuine second haematological
# malignancy.
#
# Frailty is marked "only included pending review of data and mapping" and its
# algorithm is Annex 7, which was not delivered. FRAILTY=TRUE asks for it and
# the code-list guard stops the run naming the annex, which is the honest
# outcome.
mod_comorbidity <- function(con, cfg, cohort) {
  cl <- load_codelist("charlson_quan2011.csv", cfg)
  if (!"weight" %in% names(cl))
    stop("CODELIST ERROR: charlson_quan2011.csv has no weight column.",
         call. = FALSE)
  # The MM condition, zeroed. Named in the file rather than guessed from the
  # code, so a differently-named row is visible.
  mm_rows <- grepl("myeloma", tolower(cl$condition))
  if (!any(mm_rows))
    log_msg("  NOTE: charlson_quan2011.csv names no myeloma condition, so the ",
            "MM adjustment Table 4 asks for cannot be applied. Every patient's ",
            "CCI will carry whatever weight their MM claims attract.")

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
      WHERE p.COHORT = '%6$s'
        AND lower(cl.condition) NOT LIKE '%%myeloma%%'
    )
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
    icd_family_sql("d.ICD_FLAG"), cohort$key),
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
}
