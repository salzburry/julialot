# SOC regimen categorisation - s7.2.2.
#
# The categories are the protocol's; which regimens fall in each is Annex 2,
# which was not delivered. soc_regimen_categories.csv is the shape
# ../CODELISTS.md section 4 proposes: one row per (line scope, category, agent,
# role), so a regimen is categorised by the set of agents it contains rather
# than by a regimen string, which is what makes it survive a new combination.
#
# apr_30_2026/regimen_categories.csv is the nearest existing asset - 47 rows
# keyed on a regimen STRING - and is not read here, because a string key misses
# every permutation the LOT engine can emit.

SOC_CATEGORIES_1L <- c(
  "Quadruplet with anti-CD38 backbone", "Triplet with anti-CD38 backbone",
  "Other triplet (non-anti-CD38)", "Doublet/monotherapy", "Other")
SOC_CATEGORIES_LATER <- c(
  "Quadruplet with anti-CD38 backbone", "Triplet with anti-CD38 backbone",
  "Other triplet (non-anti-CD38)", "Other novel agent", "CAR-T",
  "BCMA bispecific", "Non-BCMA bispecific", "Doublet/monotherapy", "Other")

mod_soc <- function(con, cfg, cohort) {
  cl <- load_codelist("soc_regimen_categories.csv", cfg, code_col = "CL_MED_ABBR")
  bad <- setdiff(unique(cl$soc_category),
                 union(SOC_CATEGORIES_1L, SOC_CATEGORIES_LATER))
  if (length(bad))
    stop("CODELIST ERROR: soc_regimen_categories.csv names categories the ",
         "protocol does not: ", paste(bad, collapse = "; "),
         ".\nProtocol categories are s7.2.2, screens 23-24. Rename them or say ",
         "why the study is reporting a category the protocol does not define.",
         call. = FALSE)
  bad_scope <- setdiff(toupper(unique(cl$line_scope)), c("1L", "LATER"))
  if (length(bad_scope))
    stop("CODELIST ERROR: line_scope must be 1L or LATER; found ",
         paste(bad_scope, collapse = ", "), ".", call. = FALSE)

  reg <- register_codelist_view(con, cl, "S_CL_SOC",
                                cols = c("line_scope", "soc_category",
                                         "CL_MED_ABBR", "role"))
  # LOT_BASE_MEDS is a space-separated list of CL_MED_ABBR. Exploded here so a
  # category can be decided by the SET of agents rather than by the string.
  run_step(con, paste0("soc_", cohort$key), sprintf("
    CREATE TABLE IF NOT EXISTS %1$s (
      PATID string, COHORT string, LOT_NUM int, REGIMEN string,
      N_AGENTS int, SOC_CATEGORY string, MATCHED int);
    INSERT INTO %1$s
    WITH agents AS (
      SELECT s.PATID, p.COHORT, s.LOT_NUM, s.LOT_BASE_MEDS AS REGIMEN,
             explode(split(trim(s.LOT_BASE_MEDS), '\\\\s+')) AS ABBR
      FROM %2$s s
      INNER JOIN %3$s p ON p.PATID = s.PATID AND p.COHORT = '%4$s'
      WHERE s.LOT_BASE_MEDS IS NOT NULL AND trim(s.LOT_BASE_MEDS) <> ''
    ),
    tagged AS (
      SELECT a.PATID, a.COHORT, a.LOT_NUM, a.REGIMEN,
             count(DISTINCT a.ABBR) AS N_AGENTS,
             max(CASE WHEN cl.CL_MED_ABBR IS NOT NULL THEN cl.soc_category END)
               AS SOC_CATEGORY,
             max(CASE WHEN cl.CL_MED_ABBR IS NOT NULL THEN 1 ELSE 0 END) AS MATCHED
      FROM agents a
      LEFT JOIN %5$s cl
             ON upper(trim(cl.CL_MED_ABBR)) = upper(trim(a.ABBR))
            AND upper(trim(cl.line_scope)) =
                CASE WHEN a.LOT_NUM = 1 THEN '1L' ELSE 'LATER' END
      GROUP BY a.PATID, a.COHORT, a.LOT_NUM, a.REGIMEN
    )
    SELECT PATID, COHORT, LOT_NUM, REGIMEN, N_AGENTS,
           coalesce(SOC_CATEGORY, 'Other') AS SOC_CATEGORY, MATCHED
    FROM tagged",
    wrk("S_SOC"), wrk("S_SPINE"), wrk("S_PERIODS"), cohort$key, reg),
    qc = sprintf("SELECT count(*) AS n_rows, sum(1 - MATCHED) AS n_uncategorised
                  FROM %s WHERE COHORT = '%s'", wrk("S_SOC"), cohort$key))

  n <- db_q(con, sprintf(
    "SELECT count(*) AS n, sum(1 - MATCHED) AS unmatched FROM %s WHERE COHORT='%s'",
    wrk("S_SOC"), cohort$key))
  if (n$n[1] > 0 && n$unmatched[1] / n$n[1] > 0.1)
    log_msg("  WARNING: ", n$unmatched[1], " of ", n$n[1], " regimens in ",
            cohort$key, " matched no category and fell to 'Other'. 'Other' is ",
            "a protocol category, so this does not fail - but a tenth of the ",
            "cohort landing there means Annex 2 is short of the regimens the ",
            "data actually contains.")
}
