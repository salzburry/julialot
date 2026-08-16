#!/usr/bin/env Rscript
# Real-data frequencies for the LOT assignment findings.
#
#   # list the counts this will run; no connection, touches nothing
#   Rscript run_lot_audit_counts.R
#
#   # run them
#   DATABRICKS_PWD=... DOMINO_USER_NAME=usr00000 OBJECT_PREFIX=ndmm_ \
#     INPUT_COHORT_TABLE=ndmm_NDMM_COHORT \
#     AUDIT_EXECUTE=TRUE Rscript run_lot_audit_counts.R
#
# Read-only. Every statement is a SELECT; nothing is written to the warehouse.
# Results print as a table and land in out/lot_audit_counts.csv.
#
# The audit that produced these questions ran against synthetic patients, so its
# frequencies are shape and not prevalence. This is the same set of questions put
# to the finished build, and its answers are the ones that can be quoted.
#
# AUDIT_TABLE picks which line table to count: LOT_LONG_FINAL (default, the study
# deliverable, line criteria applied) or LOT_LONG (before them). Run both if the
# criteria drop a meaningful number of lines.

.script_dir <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  # Rscript renders a space in a path as ~+~, so a folder with one in its name
  # resolves to nothing without this.
  if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                            fixed = TRUE))) else getwd()
})
LOT_ROOT <- normalizePath(file.path(.script_dir, "..", "engine"), mustWork = TRUE)
out_dir  <- file.path(.script_dir, "out")
env_flag <- function(nm) identical(toupper(trimws(Sys.getenv(nm, unset = ""))), "TRUE")

# One entry per finding. `sql` is a glue template over the table names below.
# `expect` records what the synthetic cohort gave, purely so a wildly different
# real number is noticeable rather than silently accepted.
AUDIT_COUNTS <- list(
  list(id = "auto-line-never-runs-out",
       what = "Transplant-started lines with an empty regimen, and what they cost in days",
       expect = "synthetic: 605/685 ASCT lines (88.3%), mean 506.9d vs 110.5d",
       sql = "
      SELECT l.LOT_START_TYPE,
             CASE WHEN l.LOT_MED_CNT = 0 THEN 'empty regimen' ELSE 'has regimen' END AS REGIMEN,
             count(*)                                        AS N_LINES,
             round(avg(l.LOT_BASE_LENGTH), 1)                AS MEAN_LENGTH_DAYS,
             percentile_approx(l.LOT_BASE_LENGTH, 0.5)       AS MEDIAN_LENGTH_DAYS,
             sum(CASE WHEN l.LOT_BASE_END_REASON = 'STUDY_END' THEN 1 ELSE 0 END) AS ENDS_STUDY_END,
             sum(CASE WHEN l.LOT_BASE_END_REASON = 'MED_ADD'   THEN 1 ELSE 0 END) AS ENDS_MED_ADD
      FROM {t$long} l
      GROUP BY 1, 2
      ORDER BY 1, 2"),

  list(id = "drug-days-outside-every-line",
       what = "Non-steroid supply days attributed to no line at all",
       expect = "synthetic: 230,710 of 2,079,231 drug-days (11.1%), 1,441/3,997 patients",
       sql = "
      WITH totals AS (
        SELECT sum(datediff(m.MAP_END_DT, m.MAP_START_DT) + 1) AS DRUG_DAYS,
               count(DISTINCT m.PATID)                         AS N_PAT
        FROM {t$map} m
        WHERE m.MAP_MED_CLASS <> 'STEROID'
      ),
      covered AS (
        SELECT sum(greatest(0, datediff(
                 least(m.MAP_END_DT,   l.LOT_BASE_END_DT),
                 greatest(m.MAP_START_DT, l.LOT_START_DT)) + 1)) AS DRUG_DAYS
        FROM {t$map} m
        INNER JOIN {t$long} l ON l.PATID = m.PATID
        WHERE m.MAP_MED_CLASS <> 'STEROID'
          AND m.MAP_START_DT <= l.LOT_BASE_END_DT
          AND m.MAP_END_DT   >= l.LOT_START_DT
      )
      SELECT t.DRUG_DAYS                                  AS TOTAL_DRUG_DAYS,
             c.DRUG_DAYS                                  AS DRUG_DAYS_IN_A_LINE,
             t.DRUG_DAYS - c.DRUG_DAYS                    AS DRUG_DAYS_OUTSIDE,
             round(100.0 * (t.DRUG_DAYS - c.DRUG_DAYS) / t.DRUG_DAYS, 2) AS PCT_OUTSIDE,
             t.N_PAT                                      AS N_PATIENTS_WITH_SUPPLY
      FROM totals t CROSS JOIN covered c"),

  list(id = "episodes-starting-outside-every-line",
       what = "Whole supply episodes whose start date falls in no line",
       expect = "synthetic: 380 of 16,592 non-steroid episodes",
       sql = "
      SELECT count(*)                    AS N_EPISODES,
             count(DISTINCT m.PATID)     AS N_PATIENTS
      FROM {t$map} m
      WHERE m.MAP_MED_CLASS <> 'STEROID'
        AND NOT EXISTS (SELECT 1 FROM {t$long} l
                        WHERE l.PATID = m.PATID
                          AND m.MAP_START_DT BETWEEN l.LOT_START_DT AND l.LOT_BASE_END_DT)"),

  list(id = "discon-dt-postdates-line-end",
       what = "Lines carrying a discontinuation date after their own end date",
       expect = "synthetic: 3,160 of 11,835 lines (26.7%), max 1,161 days after",
       sql = "
      SELECT l.LOT_BASE_END_REASON,
             count(*)                                                        AS N_LINES,
             round(avg(datediff(l.LOT_BASE_DISCON_DT, l.LOT_BASE_END_DT)), 1) AS MEAN_DAYS_AFTER,
             max(datediff(l.LOT_BASE_DISCON_DT, l.LOT_BASE_END_DT))           AS MAX_DAYS_AFTER
      FROM {t$long} l
      WHERE l.LOT_BASE_DISCON_DT IS NOT NULL
        AND l.LOT_BASE_DISCON_DT > l.LOT_BASE_END_DT
      GROUP BY 1
      ORDER BY 2 DESC"),

  list(id = "discon-while-drug-still-supplied",
       what = "Lines ending DISCONTINUATION while a non-regimen agent was still supplied",
       expect = "synthetic: 1,277 of 5,419 DISCONTINUATION lines (23.6%)",
       sql = "
      SELECT count(*)                AS N_LINES,
             count(DISTINCT l.PATID) AS N_PATIENTS
      FROM {t$long} l
      WHERE l.LOT_BASE_END_REASON = 'DISCONTINUATION'
        AND EXISTS (SELECT 1 FROM {t$map} m
                    WHERE m.PATID = l.PATID
                      AND m.MAP_MED_CLASS <> 'STEROID'
                      AND m.MAP_START_DT <= l.LOT_BASE_END_DT
                      AND m.MAP_END_DT   >= l.LOT_BASE_END_DT
                      AND NOT array_contains(
                            split(coalesce(l.LOT_BASE_MEDS, ''), ' '), m.MAP_MED_TYPE))"),

  list(id = "death-suppressed-at-line-cap",
       what = "LOT5 rows reading DISCONTINUATION in patients who died inside observation",
       expect = "synthetic: 35 lines, mean 503 days between the reported end and the death",
       sql = "
      SELECT count(*)                                                 AS N_LINES,
             round(avg(datediff(p.DEATH_DT, l.LOT_BASE_END_DT)), 1)   AS MEAN_DAYS_END_TO_DEATH,
             max(datediff(p.DEATH_DT, l.LOT_BASE_END_DT))             AS MAX_DAYS_END_TO_DEATH,
             round(avg(l.LOT_BASE_LENGTH), 1)                         AS MEAN_REPORTED_LENGTH
      FROM {t$long} l
      INNER JOIN {t$cohort} p ON p.PATID = l.PATID
      WHERE l.LOT_NUM = 5
        AND l.LOT_BASE_END_REASON = 'DISCONTINUATION'
        AND p.DEATH_DT IS NOT NULL
        AND p.DEATH_DT <= p.{obs_col}"),

  list(id = "regimen-agent-with-no-episode-in-window",
       what = "Lines naming an agent that has no supply episode starting inside the line",
       expect = "synthetic: 30 of 10,659 lines with a regimen",
       sql = "
      WITH exploded AS (
        SELECT l.PATID, l.LOT_NUM, l.LOT_START_DT, l.LOT_BASE_END_DT,
               explode(split(l.LOT_BASE_MEDS, ' ')) AS MED_ABBR
        FROM {t$long} l
        WHERE coalesce(trim(l.LOT_BASE_MEDS), '') <> ''
      )
      SELECT count(DISTINCT concat_ws('|', e.PATID, e.LOT_NUM)) AS N_LINES,
             count(DISTINCT e.PATID)                            AS N_PATIENTS
      FROM exploded e
      WHERE e.MED_ABBR <> ''
        AND NOT EXISTS (SELECT 1 FROM {t$map} m
                        WHERE m.PATID = e.PATID
                          AND m.MAP_MED_TYPE = e.MED_ABBR
                          AND m.MAP_START_DT BETWEEN e.LOT_START_DT AND e.LOT_BASE_END_DT)"),

  list(id = "empty-regimen-lines-by-start-type",
       what = "Regimen-less lines consuming a LOT1-5 slot, by what started them",
       expect = "synthetic: 1,176 of 11,835 lines (9.9%)",
       sql = "
      SELECT l.LOT_START_TYPE,
             count(*)                         AS N_LINES,
             round(avg(l.LOT_BASE_LENGTH), 1) AS MEAN_LENGTH_DAYS
      FROM {t$long} l
      WHERE l.LOT_MED_CNT = 0
      GROUP BY 1
      ORDER BY 2 DESC"),

  list(id = "patients-at-the-line-cap",
       what = "Patients reaching LOT5, whose later therapy cannot be represented",
       expect = "synthetic: 274 of 4,000 patients still supplied past the cap (6.9%)",
       sql = "
      WITH capped AS (
        SELECT PATID, max(LOT_NUM) AS MAX_LOT,
               max(CASE WHEN LOT_NUM = 5 THEN LOT_BASE_END_DT END) AS L5_END
        FROM {t$long} GROUP BY PATID
      )
      SELECT count(*)                                                       AS N_AT_CAP,
             sum(CASE WHEN EXISTS (SELECT 1 FROM {t$map} m
                                   WHERE m.PATID = c.PATID
                                     AND m.MAP_MED_CLASS <> 'STEROID'
                                     AND m.MAP_START_DT > c.L5_END)
                      THEN 1 ELSE 0 END)                                    AS N_TREATED_PAST_CAP
      FROM capped c
      WHERE c.MAX_LOT = 5"),

  list(id = "line-length-by-start-type",
       what = "Line duration by line number and start type - context for the Q1 tab",
       expect = "no synthetic target; this is the distribution the defects above distort",
       sql = "
      SELECT l.LOT_NUM, l.LOT_START_TYPE,
             count(*)                                  AS N_LINES,
             round(avg(l.LOT_BASE_LENGTH), 1)          AS MEAN_LENGTH_DAYS,
             percentile_approx(l.LOT_BASE_LENGTH, 0.5) AS MEDIAN_LENGTH_DAYS,
             percentile_approx(l.LOT_BASE_LENGTH, 0.75) AS P75_LENGTH_DAYS
      FROM {t$long} l
      GROUP BY 1, 2
      ORDER BY 1, 2")
)

report_plan <- function() {
  cat("\nReal-data frequencies for the LOT assignment findings.\n\n")
  cat("Read-only: every statement is a SELECT. Nothing is written to the warehouse.\n\n")
  for (a in AUDIT_COUNTS) {
    cat("  ", a$id, "\n    ", a$what, "\n    ", a$expect, "\n", sep = "")
  }
  cat("\n", length(AUDIT_COUNTS), " counts. Set AUDIT_EXECUTE=TRUE to run them.\n", sep = "")
  cat("Needs DATABRICKS_PWD, DOMINO_USER_NAME (or PROJECT_WORK_SCHEMA),\n")
  cat("OBJECT_PREFIX and INPUT_COHORT_TABLE.\n\n")
}

main <- function() {
  report_plan()
  if (!env_flag("AUDIT_EXECUTE")) return(invisible(0L))

  library(DBI); library(odbc); library(glue)
  source(file.path(LOT_ROOT, "R", "load_inputs.R"))
  load_pipeline_inputs(LOT_ROOT, "config.csv")
  for (f in c("config_lot.R", "db_utils_lot.R")) source(file.path(LOT_ROOT, "R", f))

  cfg <- lot_config()
  schema <- trimws(Sys.getenv("PROJECT_WORK_SCHEMA",
             unset = Sys.getenv("DOMINO_USER_NAME",
             unset = Sys.getenv("DOMINO_STARTING_USERNAME", unset = ""))))
  if (!nzchar(schema))
    stop("No work schema. Set DOMINO_USER_NAME to the schema the build wrote into, ",
         "or PROJECT_WORK_SCHEMA to override.", call. = FALSE)
  cfg$work_schema <- schema

  pfx <- trimws(Sys.getenv("OBJECT_PREFIX", unset = ""))
  if (!nzchar(pfx))
    stop("No OBJECT_PREFIX. It names the run's tables, so without it this would ",
         "count whatever unprefixed tables happen to exist.", call. = FALSE)
  if (!grepl("^[A-Za-z][A-Za-z0-9_]*_$", pfx))
    stop("OBJECT_PREFIX '", pfx, "' should be a name ending in '_'.", call. = FALSE)
  cfg$object_prefix <- pfx

  cohort <- trimws(Sys.getenv("INPUT_COHORT_TABLE", unset = ""))
  if (!nzchar(cohort))
    stop("No INPUT_COHORT_TABLE. The death-date count reads the cohort for its ",
         "observation window. Give the whole name including the prefix, e.g. ",
         pfx, "NDMM_COHORT.", call. = FALSE)

  set_lot_config(cfg)
  dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
  stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")

  # Which line table to count. LOT_LONG_FINAL is the study deliverable, with the
  # line criteria applied; LOT_LONG is what the engine built before them.
  which_tbl <- trimws(Sys.getenv("AUDIT_TABLE", unset = "LOT_LONG_FINAL"))
  if (!which_tbl %in% c("LOT_LONG_FINAL", "LOT_LONG"))
    stop("AUDIT_TABLE must be LOT_LONG_FINAL or LOT_LONG.", call. = FALSE)

  # OBS_END_DT is not persisted - it is chosen at build time from ENDDATE or
  # ENDDATE_CE. Match whichever the run used, or the death filter will disagree
  # with the build's own idea of when observation stopped.
  obs_col <- if (isTRUE(cfg$censor_at_disenrollment)) "ENDDATE_CE" else "ENDDATE"

  t <- list(long   = lot_out(which_tbl),
            map    = lot_out("MAP_STACKED"),
            cohort = wrk(cohort))

  cat("Counting against:\n")
  for (nm in names(t)) cat("  ", nm, ": ", t[[nm]], "\n", sep = "")
  cat("  observation column: ", obs_col, "\n\n", sep = "")

  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  rows <- list()
  failed <- 0L
  for (a in AUDIT_COUNTS) {
    cat("== ", a$id, "\n", sep = "")
    cat("   ", a$what, "\n", sep = "")
    sql <- glue(a$sql, .open = "{", .close = "}")
    res <- tryCatch(DBI::dbGetQuery(con, sql), error = function(e) e)
    if (inherits(res, "error")) {
      failed <- failed + 1L
      cat("   FAILED: ", conditionMessage(res), "\n\n", sep = "")
      next
    }
    print(res, row.names = FALSE)
    cat("   (", a$expect, ")\n\n", sep = "")
    # Long format, one row per cell. The counts return different columns from
    # each other, so writing them as separate CSV tables into one file produced
    # repeated headers and a file nothing could read.
    if (nrow(res)) {
      for (i in seq_len(nrow(res))) for (nm in names(res)) {
        rows[[length(rows) + 1L]] <- data.frame(
          finding = a$id, row = i, metric = nm,
          value = as.character(res[[nm]][i]),
          stringsAsFactors = FALSE)
      }
    }
  }

  csv <- file.path(out_dir, "lot_audit_counts.csv")
  utils::write.csv(do.call(rbind, rows), csv, row.names = FALSE)
  cat("Wrote ", csv, "\n", sep = "")
  if (failed) {
    cat(failed, " count(s) failed - see the messages above.\n", sep = "")
    return(invisible(1L))
  }
  invisible(0L)
}

if (!interactive()) quit(status = main())
