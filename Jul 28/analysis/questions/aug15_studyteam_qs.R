#!/usr/bin/env Rscript
# The study team's mid-August asks -> CSVs.
#
#   DATABRICKS_PWD=... DOMINO_USER_NAME=usr00000 OBJECT_PREFIX=ndmm_ \
#     INPUT_COHORT_TABLE=ndmm_NDMM_COHORT \
#     Rscript analysis/questions/aug15_studyteam_qs.R
#
# Three asks, three answers:
#
#   1. How many patients are affected by the MAP-splitting rule: a line that
#      ended MED_ADD because an agent from the PREVIOUS line's regimen came
#      back after this line's induction window. Under the proposed update the
#      agent would fold into the line instead, so these lines are the affected
#      population. Counted here, off the published lines.
#
#   2. How the melphalan rules are working: already answered by the melphalan
#      package - run exploration/melphalan/run_aug1_melp.R (three cells), then
#      read_melp_asks.R and read_melp_decisions.R. Nothing is recomputed here;
#      the summary CSV names those programs.
#
#   3. Cohort counts: patients who discontinue 1L and then have the 12-month
#      continuous-enrollment baseline before their 2L start; the same one line
#      up for 3L. The baseline is the same window the 2L/3L cohort build
#      applies: one gap-merged span covering [line start - 365, line start - 1].
#
# Reads only. Writes CSVs to OUTPUT_DIR (default /mnt/artifacts/results).

.script_dir <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  # Rscript renders a space in the path as ~+~, so a folder with one in its
  # name resolves to nothing without this.
  if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                            fixed = TRUE))) else getwd()
})
source(file.path(.script_dir, "_setup.R"))
cfg <- qs_setup(.script_dir)

main <- function() {
  stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")
  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  qs_check_run_binding(con)

  stamp   <- format(Sys.time(), "%Y%m%d_%H%M%S")
  out_dir <- cfg$output_dir
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  write_out <- function(df, tag) {
    if (is.null(df) || nrow(df) == 0) { log_msg("  (", tag, ": no rows)"); return(invisible()) }
    f <- file.path(out_dir, paste0("aug15_qs_", tag, "_", stamp, ".csv"))
    write.csv(df, f, row.names = FALSE)
    log_msg("  wrote ", tag, " -> ", f, " (", nrow(df), " rows)")
  }

  pop   <- qs_population()
  lines <- pop$table
  log_msg(SEP)
  log_msg("Aug 15 asks [", pop$mode, " population] -> CSVs")
  log_msg(SEP)

  # ---- 1. Patients affected by the MAP-splitting rule ----------------------
  # A MED_ADD end is, by construction, an agent outside the line's regimen
  # starting an episode after the line's induction window. The affected subset
  # is the one Julia described: the added agent was in the IMMEDIATELY
  # previous line's regimen - drug B from 1L ending 2L. The regimen string
  # already carries permissible substitutes that were filled, and the pairs
  # are joined both ways so a biosimilar of drug B still matches drug B.
  log_msg("1. MAP-splitting rule: lines ended by a previous-line agent coming back")
  subs_src <- load_codelist_csv("permissible_subs.csv",
                                c("original_med", "substitute_med"))
  affected <- db_q(con, glue("
    WITH ln AS (
      SELECT cast(PATID as string) AS PATID, cast(LOT_NUM as int) AS LOT_NUM,
             LOT_BASE_MEDS, LOT_BASE_1ST_ADD_MED, LOT_BASE_END_REASON
      FROM {lines}
    ),
    subs AS (
      SELECT upper(trim(original_med))   AS o,
             upper(trim(substitute_med)) AS s
      FROM {subs_src}
    ),
    prev AS (
      SELECT PATID, LOT_NUM + 1 AS NEXT_LOT,
             upper(trim(m.MED)) AS PREV_MED
      FROM ln LATERAL VIEW explode(split(trim(LOT_BASE_MEDS), ' ')) m AS MED
      WHERE trim(coalesce(LOT_BASE_MEDS, '')) <> ''
    ),
    fired AS (
      SELECT PATID, LOT_NUM,
             upper(trim(LOT_BASE_1ST_ADD_MED)) AS ADD_MED
      FROM ln
      WHERE LOT_BASE_END_REASON = 'MED_ADD'
        AND trim(coalesce(LOT_BASE_1ST_ADD_MED, '')) <> ''
    ),
    hit AS (
      SELECT DISTINCT f.PATID, f.LOT_NUM
      FROM fired f
      INNER JOIN prev p
              ON p.PATID = f.PATID AND p.NEXT_LOT = f.LOT_NUM
      LEFT JOIN subs s1 ON s1.o = p.PREV_MED AND s1.s = f.ADD_MED
      LEFT JOIN subs s2 ON s2.s = p.PREV_MED AND s2.o = f.ADD_MED
      WHERE p.PREV_MED = f.ADD_MED
         OR s1.o IS NOT NULL
         OR s2.o IS NOT NULL
    )
    SELECT cast(LOT_NUM as string) AS LINE_THAT_ENDED,
           count(*)                AS N_LINES,
           count(DISTINCT PATID)   AS N_PATIENTS
    FROM hit GROUP BY LOT_NUM
    UNION ALL
    SELECT 'ALL', count(*), count(DISTINCT PATID) FROM hit
    ORDER BY LINE_THAT_ENDED"))
  write_out(affected, "map_splitting_affected")

  # ---- 3. Discontinue the prior line, then the 12-month CE baseline --------
  # The baseline is the 2L/3L cohort build's own criterion, written the same
  # way: one gap-merged span covering [line start - 365, line start - 1].
  log_msg("3. Discontinued the prior line, then the 12mo CE baseline")
  spans <- qs_cohort_side_tbl("NDMM_ENROLL_SPANS")
  funnel <- do.call(rbind, lapply(c(2L, 3L), function(n) {
    d <- db_q(con, glue("
      WITH ln AS (
        SELECT cast(PATID as string) AS PATID, cast(LOT_NUM as int) AS LOT_NUM,
               cast(LOT_START_DT as date) AS LOT_START_DT, LOT_BASE_END_REASON
        FROM {lines}
      ),
      disc AS (
        SELECT PATID FROM ln
        WHERE LOT_NUM = {n - 1} AND LOT_BASE_END_REASON = 'DISCONTINUATION'
      ),
      nxt AS (
        SELECT l.PATID, l.LOT_START_DT
        FROM ln l INNER JOIN disc d ON d.PATID = l.PATID
        WHERE l.LOT_NUM = {n}
      ),
      ce AS (
        SELECT DISTINCT x.PATID
        FROM nxt x
        INNER JOIN {spans} s
                ON cast(s.PATID as string) = x.PATID
               AND cast(s.cov_start as date) <= date_sub(x.LOT_START_DT, 365)
               AND cast(s.cov_end as date)   >= date_sub(x.LOT_START_DT, 1)
      )
      SELECT (SELECT count(*) FROM disc) AS N_DISCONTINUED_PRIOR,
             (SELECT count(*) FROM nxt)  AS N_ALSO_HAS_NEXT_LINE,
             (SELECT count(*) FROM ce)   AS N_ALSO_12MO_CE_BEFORE_IT"))
    data.frame(COHORT = paste0(n, "L"),
               PRIOR_LINE_DISCONTINUED = paste0(n - 1, "L"),
               N_DISCONTINUED_PRIOR    = d$N_DISCONTINUED_PRIOR[1],
               N_ALSO_HAS_NEXT_LINE    = d$N_ALSO_HAS_NEXT_LINE[1],
               N_ALSO_12MO_CE_BEFORE_IT = d$N_ALSO_12MO_CE_BEFORE_IT[1],
               stringsAsFactors = FALSE)
  }))
  write_out(funnel, "discontinued_then_12mo_ce")

  # The subsequent-cohort build's own funnel beside it, for reconciliation -
  # its N_CE_PRE is the same window without the discontinuation cut. Absent
  # until ndmm/build_subsequent_cohorts.R has run; said, not guessed.
  attr_note <- tryCatch({
    a <- db_q(con, glue("SELECT COHORT, N_FROM, N_REACHED_LOT, N_CE_PRE, N_FINAL,
                                CE_PRE_DAYS, CE_FU_DAYS
                         FROM {qs_cohort_side_tbl('NDMM_SUBSEQUENT_ATTRITION')}
                         ORDER BY COHORT"))
    write_out(a, "subsequent_cohort_attrition")
    "written"
  }, error = function(e) {
    log_msg("  (subsequent-cohort attrition not readable - run ",
            "ndmm/build_subsequent_cohorts.R for the build's own funnel)")
    "not available this run"
  })

  # ---- 2. How the melphalan rules are working, and where each answer is ----
  summary <- data.frame(
    ASK = c(
      "1. Patients affected by the MAP-splitting rule",
      "2. How the MELP rules are working",
      "3. Discontinue 1L, then 12mo CE baseline before 2L; same for 3L"),
    ANSWERED_BY = c(
      paste0("aug15_qs_map_splitting_affected_", stamp, ".csv - lines ended ",
             "MED_ADD by an agent from the previous line's regimen ",
             "(substitute pairs matched both ways)"),
      paste0("exploration/melphalan: AUG1_EXECUTE=TRUE run_aug1_melp.R builds ",
             "the reference and two rule cells; read_melp_asks.R answers the ",
             "duration / MELP-mono / SCT-in-MELP-line questions; ",
             "read_melp_decisions.R prices each branch of the rule"),
      paste0("aug15_qs_discontinued_then_12mo_ce_", stamp, ".csv - the ",
             "baseline window is the 2L/3L cohort build's own ",
             "[start-365, start-1] over gap-merged spans; the build's ",
             "attrition table beside it is ", attr_note)),
    stringsAsFactors = FALSE)
  write_out(summary, "summary")

  log_msg(SEP)
  log_msg("Aug 15 asks complete. Outputs in ", out_dir)
  log_msg(SEP)
}

if (!interactive()) main()
