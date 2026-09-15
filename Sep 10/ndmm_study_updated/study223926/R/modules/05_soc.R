# SOC regimen categorisation - s7.2.2.
#
# The categories are the protocol's; which regimens fall in each is Annex 2.
# The code list is one row per (line scope, category, agent, role), so a
# regimen is categorised by the agents it contains rather than by a regimen
# string - which is what survives a new combination.

SOC_CATEGORIES_1L <- c(
  "Quadruplet with anti-CD38 backbone", "Triplet with anti-CD38 backbone",
  "Other triplet (non-anti-CD38)", "Doublet/monotherapy", "Other")
SOC_CATEGORIES_LATER <- c(
  "Quadruplet with anti-CD38 backbone", "Triplet with anti-CD38 backbone",
  "Other triplet (non-anti-CD38)", "Other novel agent", "CAR-T",
  "BCMA bispecific", "Non-BCMA bispecific", "Doublet/monotherapy", "Other")

# Which category wins when a regimen's agents map to more than one. Modality
# beats size: a CAR-T with a bridging agent is a CAR-T line, not a doublet.
# Among size categories the regimen's own agent count decides, and 'Other' is
# last so it is only ever a fallback.
#
# The precedence is this package's own - s7.2.2 lists the categories without
# saying how to resolve a regimen spanning two - and is written here so it can
# be argued with.
SOC_PRECEDENCE <- c(
  "CAR-T", "BCMA bispecific", "Non-BCMA bispecific", "Other novel agent",
  "Quadruplet with anti-CD38 backbone", "Triplet with anti-CD38 backbone",
  "Other triplet (non-anti-CD38)", "Doublet/monotherapy", "Other")
# Categories whose NAME is a claim about the regimen, and the test each claim
# has to pass. Both halves are tested: "Quadruplet with anti-CD38 backbone"
# says four agents AND a backbone, and "Other triplet (non-anti-CD38)" says
# three agents and NO backbone while containing the substring "anti-CD38". So
# the backbone is read off the agents, never off the category name.
#
# A four-agent regimen with no backbone falls through to 'Other'; s7.2.2 lists
# no other quadruplet category and inventing one would report what the protocol
# does not define.
SOC_SIZE_CATEGORIES <- c(
  "Quadruplet with anti-CD38 backbone" = "N_AGENTS >= 4 AND HAS_CD38_BACKBONE = 1",
  "Triplet with anti-CD38 backbone"    = "N_AGENTS  = 3 AND HAS_CD38_BACKBONE = 1",
  "Other triplet (non-anti-CD38)"      = "N_AGENTS  = 3 AND HAS_CD38_BACKBONE = 0",
  "Doublet/monotherapy"                = "N_AGENTS <= 2")

# The categories whose agents ARE the anti-CD38 backbone. An agent listed under
# one of these with role 'backbone' is what makes HAS_CD38_BACKBONE true.
SOC_CD38_CATEGORIES <- c("Quadruplet with anti-CD38 backbone",
                         "Triplet with anti-CD38 backbone")

soc_size_case_sql <- function() {
  arms <- vapply(seq_along(SOC_SIZE_CATEGORIES), function(i)
    sprintf("             WHEN %s\n               THEN '%s'",
            SOC_SIZE_CATEGORIES[[i]],
            gsub("'", "''", names(SOC_SIZE_CATEGORIES)[i])), character(1))
  paste(arms, collapse = "\n")
}

sql_in_list <- function(x) paste(sprintf("'%s'", gsub("'", "''", x)),
                                 collapse = ", ")

soc_rank_sql <- function(col = "cl.soc_category") {
  arms <- vapply(seq_along(SOC_PRECEDENCE), function(i)
    sprintf("WHEN %s = '%s' THEN %d", col,
            gsub("'", "''", SOC_PRECEDENCE[i]), i), character(1))
  paste0("CASE ", paste(arms, collapse = " "), " ELSE 999 END")
}

# What the SOC list must satisfy beyond its shape: the protocol's categories
# and the two line scopes. The module runs it as it starts; the preflight
# runs it before the connection is opened.
check_soc_list <- function(cfg, cl = load_codelist("soc_regimen_categories.csv", cfg)) {
  bad <- setdiff(unique(cl$soc_category),
                 union(SOC_CATEGORIES_1L, SOC_CATEGORIES_LATER))
  if (length(bad))
    stop("CODELIST ERROR: soc_regimen_categories.csv names categories the ",
         "protocol does not: ", paste(bad, collapse = "; "),
         ".\nProtocol categories are s7.2.2. Rename them or say ",
         "why the study is reporting a category the protocol does not define.",
         call. = FALSE)
  bad_scope <- setdiff(toupper(unique(cl$line_scope)), c("1L", "LATER"))
  if (length(bad_scope))
    stop("CODELIST ERROR: line_scope must be 1L or LATER; found ",
         paste(bad_scope, collapse = ", "), ".", call. = FALSE)
  invisible(cl)
}

mod_soc <- function(con, cfg, cohort) {
  cl <- load_codelist("soc_regimen_categories.csv", cfg)
  check_soc_list(cfg, cl)

  reg <- register_codelist_view(con, cl, "S_CL_SOC",
                                cols = c("line_scope", "soc_category",
                                         "CL_MED_ABBR", "role"))
  # LOT_BASE_MEDS is a space-separated list of CL_MED_ABBR. Exploded here so a
  # category can be decided by the SET of agents rather than by the string.
  #
  # It is coalesced BEFORE the split. explode() of a NULL array yields no row
  # at all, so a transplant line the engine emits with a NULL regimen (rather
  # than an empty string) vanished in spite of the WHERE keeping it: the line
  # existed for the engine and for the spine and not for the SOC table, and
  # the patterns built on it lost the line.
  #
  # The row also carries Table 6 (Exploratory Objective 1): patients with an
  # SCT in 1L-4L by year, according to SOC type. The engine's line-scoped
  # transplant flags and the autologous transplant's date sit beside the
  # category and the line's start year, so that table is a count over this
  # one and needs no join.
  #
  # (The query is one sprintf() format, which R caps at 8192 characters, so
  # the comments live here rather than in the SQL.)
  prepare_table(con, wrk("S_SOC"),
    "PATID string, COHORT string, LOT_NUM int, LOT_START_DT date,
     LOT_START_YEAR int, REGIMEN string,
     N_AGENTS int, SOC_CATEGORY string, MATCHED int,
     AUTO_SCT int, ALLO_SCT int, CART int, AUTO_SCT_DT date, AUTO_SCT_YEAR int",
    cohort$key)
  run_step(con, paste0("soc_", cohort$key), sprintf("
    INSERT INTO %1$s
    WITH agents AS (
      SELECT s.PATID, p.COHORT, s.LOT_NUM, s.LOT_START_DT,
             s.LOT_BASE_MEDS AS REGIMEN,
             coalesce(s.LOT_ALLO_LOT_FLG, 0) AS ALLO_FLG,
             coalesce(s.LOT_CART_LOT_FLG, 0) AS CART_FLG,
             coalesce(s.LOT_TX_AUTO_FLG, 0)  AS AUTO_FLG,
             s.LOT_TX_AUTO_MAX_DT,
             explode(split(trim(coalesce(s.LOT_BASE_MEDS, '')), '\\\\s+')) AS ABBR
      FROM %2$s s
      -- s.LOT_NUM >= p.LOT_NUM, the same restriction S_LOT_PERIODS applies.
      -- Without it the 3L cohort's S_SOC carries that cohort's lines 1 and 2 -
      -- therapy given BEFORE its index - and mod_patterns then reports them
      -- against the whole 3L denominator as though they were on-study lines.
      INNER JOIN %3$s p ON p.PATID = s.PATID AND p.COHORT = '%4$s'
                       AND s.LOT_NUM >= p.LOT_NUM
                       -- ...and bounded ABOVE by the cohort's follow-up. The
                       -- LOT engine deliberately continues through enrolment
                       -- gaps, so it builds lines that start after this cohort
                       -- stopped observing the patient. Unbounded, a 2L
                       -- beginning after the 1L cohort's FU_END appeared in
                       -- the 1L treatment-pattern tables while TTNT had
                       -- already censored that patient: two outputs
                       -- disagreeing about the same line. s7.1 observes within
                       -- follow-up and s7.8.2 allows censoring as a terminal
                       -- Sankey outcome, so the line is dropped, not reported.
                       AND s.LOT_START_DT <= p.FU_END
      -- An empty regimen string is NOT a malformed line. The LOT engine emits
      -- a single-day allogeneic transplant line with no medication string on
      -- purpose (LOT_RULES 4.6), and dropping it deleted a real line: the
      -- preceding line's switch became `(no further therapy)` even though the
      -- patient had a transplant and a further line after it. The line is kept
      -- and its modality is read off the engine's own transplant flags; only a
      -- line that is neither drugs nor a transplant is dropped.
      WHERE (trim(coalesce(s.LOT_BASE_MEDS, '')) <> ''
          OR coalesce(s.LOT_ALLO_LOT_FLG, 0) = 1
          OR coalesce(s.LOT_CART_LOT_FLG, 0) = 1
          OR coalesce(s.LOT_TX_AUTO_FLG, 0) = 1)
    ),
    matched AS (
      SELECT a.PATID, a.COHORT, a.LOT_NUM, a.LOT_START_DT, a.REGIMEN,
             a.ALLO_FLG, a.CART_FLG, a.AUTO_FLG, a.LOT_TX_AUTO_MAX_DT,
             a.ABBR, cl.soc_category,
             %6$s AS RANK,
             CASE WHEN lower(trim(cl.role)) = 'backbone'
                   AND cl.soc_category IN (%8$s) THEN 1 ELSE 0 END AS CD38
      FROM agents a
      LEFT JOIN %5$s cl
             ON upper(trim(cl.CL_MED_ABBR)) = upper(trim(a.ABBR))
            AND upper(trim(cl.line_scope)) =
                CASE WHEN a.LOT_NUM = 1 THEN '1L' ELSE 'LATER' END
    ),
    tagged AS (
      SELECT PATID, COHORT, LOT_NUM, LOT_START_DT, REGIMEN,
             max(ALLO_FLG) AS ALLO_FLG, max(CART_FLG) AS CART_FLG,
             max(AUTO_FLG) AS AUTO_FLG,
             max(LOT_TX_AUTO_MAX_DT) AS AUTO_SCT_DT,
             count(DISTINCT CASE WHEN trim(coalesce(ABBR,'')) <> ''
                                 THEN ABBR END) AS N_AGENTS,
             min(CASE WHEN soc_category IS NOT NULL THEN RANK END) AS BEST_RANK,
             max(CASE WHEN soc_category IS NOT NULL THEN 1 ELSE 0 END) AS MATCHED,
             max(CD38) AS HAS_CD38_BACKBONE
      FROM matched
      GROUP BY PATID, COHORT, LOT_NUM, LOT_START_DT, REGIMEN
    ),
    named AS (
      SELECT t.*,
             (SELECT max(soc_category) FROM matched m
               WHERE m.PATID = t.PATID AND m.COHORT = t.COHORT
                 AND m.LOT_NUM = t.LOT_NUM AND m.RANK = t.BEST_RANK)
               AS BEST_CATEGORY
      FROM tagged t
    )
    SELECT PATID, COHORT, LOT_NUM, LOT_START_DT,
           -- Table 4 tabulates the regimen categories by calendar year of
           -- line start, so the year is on the row beside the category.
           year(LOT_START_DT) AS LOT_START_YEAR, REGIMEN, N_AGENTS,
           -- A transplant-only line has no drug string to classify, and its
           -- modality is what the line IS. Reported from the engine's own
           -- flags rather than left to fall through to Other, and MATCHED
           -- stays 0 because no code list produced it - the protocol label for
           -- a transplant line is Annex 2's to give, and this names the
           -- modality without inventing a category.
           CASE
             -- CAR-T FIRST, and not only when the drug string is empty. The
             -- engine collects non-steroid consolidation drugs in a CAR-T
             -- line's capture window and keeps LOT_CART_LOT_FLG set, so a
             -- CAR-T line can carry a regimen - and reading the regimen first
             -- classified it as an ordinary doublet, which then propagated
             -- into the SOC counts, the patterns and the switch edges. The
             -- modality is what the line IS; the consolidation drugs are what
             -- was given inside it, and REGIMEN still reports them.
             --
             -- Unlike the transplant labels below this is not a placeholder:
             -- s7.2.2 names CAR-T, inclusive of all targets, as a later-line
             -- SOC category in its own right.
             WHEN CART_FLG = 1 THEN 'CAR-T'
             -- The transplant labels stay conditional on an empty regimen,
             -- because their protocol category is Annex 2's to give and there
             -- is no basis here for overriding a recorded regimen with a
             -- provisional name.
             WHEN trim(coalesce(REGIMEN, '')) = '' AND ALLO_FLG = 1
               THEN 'Allogeneic SCT (no regimen recorded)'
             WHEN trim(coalesce(REGIMEN, '')) = '' AND AUTO_FLG = 1
               THEN 'Autologous SCT (no regimen recorded)'
           -- A modality category (CAR-T, a bispecific, another novel agent) is
           -- a claim about an agent and is kept as the agent's row said. A
           -- size category is a claim about the REGIMEN, so the regimen's own
           -- agent count and backbone decide it, not the winning agent's row.
           --
           -- ...and it decides it whether or not any agent is on the list.
           -- 'Other triplet (non-anti-CD38)' and 'Doublet/monotherapy' are
           -- s7.2.2's names for any three-agent regimen without the backbone
           -- and any regimen of one or two agents; a regimen of agents Annex
           -- 2 does not name is still one of those sizes. Sent to 'Other'
           -- for being unlisted, a carfilzomib triplet was reported as a
           -- category the protocol reserves for what its sizes do not cover.
           -- MATCHED stays 0 for it, so the QC below still says the list is
           -- short of the data. A four-agent regimen with no backbone falls
           -- through to 'Other' as before: s7.2.2 has no other quadruplet.
             WHEN BEST_CATEGORY IS NOT NULL
                  AND BEST_CATEGORY NOT IN (%7$s) THEN BEST_CATEGORY
%9$s
             ELSE 'Other'
           END AS SOC_CATEGORY,
           coalesce(MATCHED, 0) AS MATCHED,
           AUTO_FLG AS AUTO_SCT, ALLO_FLG AS ALLO_SCT, CART_FLG AS CART,
           AUTO_SCT_DT, year(AUTO_SCT_DT) AS AUTO_SCT_YEAR
    FROM named",
    wrk("S_SOC"), wrk("S_SPINE"), wrk("S_PERIODS"), cohort$key, reg,
    soc_rank_sql(), sql_in_list(names(SOC_SIZE_CATEGORIES)),
    sql_in_list(SOC_CD38_CATEGORIES), soc_size_case_sql()),
    qc = sprintf("SELECT count(*) AS n_rows, sum(1 - MATCHED) AS n_uncategorised
                  FROM %s WHERE COHORT = '%s'", wrk("S_SOC"), cohort$key))

  n <- db_q(con, sprintf(
    "SELECT count(*) AS n, sum(1 - MATCHED) AS unmatched FROM %s WHERE COHORT='%s'",
    wrk("S_SOC"), cohort$key))
  if (n$n[1] > 0 && n$unmatched[1] / n$n[1] > 0.1)
    log_msg("  WARNING: ", n$unmatched[1], " of ", n$n[1], " regimens in ",
            cohort$key, " matched no category and fell to 'Other'. 'Other' is ",
            "a protocol category, so this does not fail - but a tenth of the ",
            "cohort landing there means the SOC code list is short of the ",
            "regimens the data actually contains.")
}
