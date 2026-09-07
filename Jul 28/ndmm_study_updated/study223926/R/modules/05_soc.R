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

# Which category wins when a regimen's agents map to more than one.
#
# A regimen containing a CAR-T agent alongside a companion agent matches both
# 'CAR-T' and whatever the companion maps to, so something has to choose. An
# aggregate like max() chooses alphabetically, which puts 'Doublet/monotherapy'
# and 'Other' above 'CAR-T' - a silent, stable, wrong answer.
#
# The modality categories take precedence over the size categories, because a
# CAR-T given with a bridging agent is a CAR-T line and not a doublet. Among
# the size categories the regimen's OWN agent count decides, not any single
# agent's row - which is what "categorised by the set of agents it contains"
# has to mean. 'Other' is last, so it is only ever a fallback.
#
# This precedence is this package's, not the protocol's: Annex 2 was not
# delivered and s7.2.2 lists the categories without saying how to resolve a
# regimen that spans two. It is written here so it can be argued with.
SOC_PRECEDENCE <- c(
  "CAR-T", "BCMA bispecific", "Non-BCMA bispecific", "Other novel agent",
  "Quadruplet with anti-CD38 backbone", "Triplet with anti-CD38 backbone",
  "Other triplet (non-anti-CD38)", "Doublet/monotherapy", "Other")
# The categories whose name is a claim about how many agents the regimen has.
SOC_SIZE_CATEGORIES <- c(
  "Quadruplet with anti-CD38 backbone" = 4L,
  "Triplet with anti-CD38 backbone"    = 3L,
  "Other triplet (non-anti-CD38)"      = 3L,
  "Doublet/monotherapy"                = 2L)

soc_rank_sql <- function(col = "cl.soc_category") {
  arms <- vapply(seq_along(SOC_PRECEDENCE), function(i)
    sprintf("WHEN %s = '%s' THEN %d", col,
            gsub("'", "''", SOC_PRECEDENCE[i]), i), character(1))
  paste0("CASE ", paste(arms, collapse = " "), " ELSE 999 END")
}

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
  prepare_table(con, wrk("S_SOC"),
    "PATID string, COHORT string, LOT_NUM int, REGIMEN string,
     N_AGENTS int, SOC_CATEGORY string, MATCHED int", cohort$key)
  run_step(con, paste0("soc_", cohort$key), sprintf("
    INSERT INTO %1$s
    WITH agents AS (
      SELECT s.PATID, p.COHORT, s.LOT_NUM, s.LOT_BASE_MEDS AS REGIMEN,
             explode(split(trim(s.LOT_BASE_MEDS), '\\\\s+')) AS ABBR
      FROM %2$s s
      INNER JOIN %3$s p ON p.PATID = s.PATID AND p.COHORT = '%4$s'
      WHERE s.LOT_BASE_MEDS IS NOT NULL AND trim(s.LOT_BASE_MEDS) <> ''
    ),
    matched AS (
      SELECT a.PATID, a.COHORT, a.LOT_NUM, a.REGIMEN, a.ABBR, cl.soc_category,
             %6$s AS RANK
      FROM agents a
      LEFT JOIN %5$s cl
             ON upper(trim(cl.CL_MED_ABBR)) = upper(trim(a.ABBR))
            AND upper(trim(cl.line_scope)) =
                CASE WHEN a.LOT_NUM = 1 THEN '1L' ELSE 'LATER' END
    ),
    tagged AS (
      SELECT PATID, COHORT, LOT_NUM, REGIMEN,
             count(DISTINCT ABBR) AS N_AGENTS,
             min(CASE WHEN soc_category IS NOT NULL THEN RANK END) AS BEST_RANK,
             max(CASE WHEN soc_category IS NOT NULL THEN 1 ELSE 0 END) AS MATCHED
      FROM matched
      GROUP BY PATID, COHORT, LOT_NUM, REGIMEN
    ),
    named AS (
      SELECT t.*,
             (SELECT max(soc_category) FROM matched m
               WHERE m.PATID = t.PATID AND m.COHORT = t.COHORT
                 AND m.LOT_NUM = t.LOT_NUM AND m.RANK = t.BEST_RANK)
               AS BEST_CATEGORY
      FROM tagged t
    )
    SELECT PATID, COHORT, LOT_NUM, REGIMEN, N_AGENTS,
           -- A size category is only kept when the regimen is that size;
           -- otherwise the count decides, which is what the category names.
           CASE
             WHEN BEST_CATEGORY IS NULL THEN 'Other'
             WHEN BEST_CATEGORY NOT IN (%7$s) THEN BEST_CATEGORY
             WHEN N_AGENTS >= 4 THEN 'Quadruplet with anti-CD38 backbone'
             WHEN N_AGENTS = 3 AND BEST_CATEGORY LIKE '%%anti-CD38%%'
               THEN 'Triplet with anti-CD38 backbone'
             WHEN N_AGENTS = 3 THEN 'Other triplet (non-anti-CD38)'
             WHEN N_AGENTS <= 2 THEN 'Doublet/monotherapy'
             ELSE 'Other'
           END AS SOC_CATEGORY,
           coalesce(MATCHED, 0) AS MATCHED
    FROM named",
    wrk("S_SOC"), wrk("S_SPINE"), wrk("S_PERIODS"), cohort$key, reg,
    soc_rank_sql(),
    paste(sprintf("'%s'", gsub("'", "''", names(SOC_SIZE_CATEGORIES))),
          collapse = ", ")),
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
