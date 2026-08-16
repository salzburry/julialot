#!/usr/bin/env Rscript
# Real-data frequencies for the LOT assignment findings.
#
#   # list the counts this will run; no connection, touches nothing
#   Rscript run_lot_audit_counts.R
#
#   # run them
#   DATABRICKS_PWD=... DOMINO_USER_NAME=usr00000 OBJECT_PREFIX=ndmm_ \
#     AUDIT_EXECUTE=TRUE Rscript run_lot_audit_counts.R
#
# Read-only. Every statement is a SELECT; nothing is written to the warehouse.
# Results print as a table and land in out/lot_audit_counts.csv.
#
# The audit that produced these questions ran against synthetic patients, so its
# frequencies are shape and not prevalence. This is the same set of questions put
# to the finished build, and its answers are the ones that can be quoted.
#
# AUDIT_TABLE picks which line table to count. It defaults to LOT_LONG, which is
# line assignment on its own; LOT_LONG_FINAL additionally applies the line
# criteria, so counting it mixes assignment behaviour with cohort exclusions.
# Run both only if you want that comparison deliberately.

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
  # 1. The one confirmed correctness defect. Induction medications are gathered
  #    across the whole window while the line's end is fixed later in the
  #    cascade, so a transplant that closes the line early can leave an agent in
  #    the regimen whose first supply begins after the line ended. That agent
  #    also reaches the run-out and the next line's prior-regimen exclusion.
  list(id = "regimen-agent-begins-after-line-end",
       what = "Lines naming a regimen agent whose first supply episode starts after the line ended",
       expect = "no comparator - the synthetic figure came from a query missing its lower bound, so it was a floor, not a count",
       sql = "
      WITH exploded AS (
        SELECT l.PATID, l.LOT_NUM, l.LOT_START_DT, l.LOT_BASE_END_DT,
               explode(split(l.LOT_BASE_MEDS, ' ')) AS MED_ABBR
        FROM {t$long} l
        WHERE coalesce(trim(l.LOT_BASE_MEDS), '') <> ''
      ),
      offending AS (
        SELECT DISTINCT e.PATID, e.LOT_NUM, e.MED_ABBR
        FROM exploded e
        WHERE e.MED_ABBR <> ''
          AND NOT EXISTS (SELECT 1 FROM {t$map} m
                          WHERE m.PATID = e.PATID
                            AND m.MAP_MED_TYPE = e.MED_ABBR
                            AND m.MAP_START_DT BETWEEN e.LOT_START_DT
                                                   AND e.LOT_BASE_END_DT)
      )
      SELECT count(*)                                   AS N_AGENT_LINE_PAIRS,
             count(DISTINCT concat_ws('|', PATID, LOT_NUM)) AS N_LINES,
             count(DISTINCT PATID)                       AS N_PATIENTS
      FROM offending"),

  # 2. Not a defect - an open study-team question about how long a
  #    regimen-less transplant line should run. Reported so the decision is
  #    made against real durations rather than a synthetic guess.
  list(id = "empty-regimen-transplant-line-durations",
       what = "DECISION, not a defect: how long transplant lines with no regimen actually run",
       expect = "synthetic: 605/685 ASCT lines empty, mean 506.9d vs 110.5d with a regimen",
       sql = "
      SELECT l.LOT_START_TYPE,
             CASE WHEN l.LOT_MED_CNT = 0 THEN 'empty regimen' ELSE 'has regimen' END AS REGIMEN,
             count(*)                                   AS N_LINES,
             round(avg(l.LOT_BASE_LENGTH), 1)           AS MEAN_LENGTH_DAYS,
             percentile_approx(l.LOT_BASE_LENGTH, 0.5)  AS MEDIAN_LENGTH_DAYS,
             percentile_approx(l.LOT_BASE_LENGTH, 0.75) AS P75_LENGTH_DAYS
      FROM {t$long} l
      GROUP BY 1, 2
      ORDER BY 1, 2"),

  # 3. Treatment outside every line, split by cause. The unpartitioned total is
  #    meaningless: leftover supply deliberately does not carry into a new line,
  #    an ALLO line is one day by design, and therapy past LOT5 is the cap. Only
  #    the residual bucket is a question.
  list(id = "outside-line-days-by-cause",
       what = "Non-steroid agent-DAYS owned by no LOT, split by cause - only the unexplained bucket is a question",
       expect = "no synthetic target - the unpartitioned 11.1% was an invalid measure",
       sql = "
      WITH bounds AS (
        SELECT PATID, min(LOT_START_DT) AS FIRST_START,
               max(LOT_BASE_END_DT)     AS LAST_END,
               max(LOT_NUM)             AS MAX_LOT
        FROM {t$long} GROUP BY PATID
      ),
      drug_days AS (
        SELECT m.PATID, m.MAP_MED_TYPE, m.MAP_CNT, m.MAP_START_DT,
               explode(sequence(m.MAP_START_DT, m.MAP_END_DT, interval 1 day)) AS SUPPLY_DT
        FROM {t$map} m
        WHERE m.MAP_MED_CLASS <> 'STEROID'
          AND m.MAP_START_DT IS NOT NULL AND m.MAP_END_DT IS NOT NULL
          AND m.MAP_END_DT >= m.MAP_START_DT
      ),
      -- Per EPISODE, not per day: did this episode begin inside some LOT? If so
      -- its uncovered days are carryover, which the rules deliberately do not
      -- move into the next regimen.
      episode_began_in_lot AS (
        SELECT DISTINCT m.PATID, m.MAP_MED_TYPE, m.MAP_CNT
        FROM {t$map} m
        INNER JOIN {t$long} l ON l.PATID = m.PATID
         AND m.MAP_START_DT BETWEEN l.LOT_START_DT AND l.LOT_BASE_END_DT
        WHERE m.MAP_MED_CLASS <> 'STEROID'
      ),
      allo_lots AS (
        SELECT PATID, LOT_START_DT FROM {t$long} WHERE LOT_START_TYPE = 'SCT_ALLO'
      ),
      orphan AS (
        SELECT d.PATID, d.MAP_MED_TYPE, d.MAP_CNT, d.SUPPLY_DT,
               b.FIRST_START, b.LAST_END, b.MAX_LOT,
               CASE WHEN e.PATID IS NOT NULL THEN 1 ELSE 0 END AS IS_CARRYOVER,
               CASE WHEN a.PATID IS NOT NULL THEN 1 ELSE 0 END AS NEAR_ALLO
        FROM drug_days d
        LEFT JOIN bounds b ON b.PATID = d.PATID
        LEFT JOIN episode_began_in_lot e
               ON e.PATID = d.PATID AND e.MAP_MED_TYPE = d.MAP_MED_TYPE
              AND e.MAP_CNT = d.MAP_CNT
        LEFT JOIN allo_lots a
               ON a.PATID = d.PATID
              AND d.SUPPLY_DT BETWEEN date_sub(a.LOT_START_DT, 1)
                                  AND date_add(a.LOT_START_DT, 1)
        WHERE NOT EXISTS (SELECT 1 FROM {t$long} l
                          WHERE l.PATID = d.PATID
                            AND d.SUPPLY_DT BETWEEN l.LOT_START_DT AND l.LOT_BASE_END_DT)
      ),
      total AS (SELECT count(*) AS N_ALL_AGENT_DAYS FROM drug_days)
      SELECT CASE
               WHEN FIRST_START IS NULL                  THEN 'patient has no LOT'
               WHEN SUPPLY_DT <  FIRST_START             THEN 'before LOT1'
               WHEN MAX_LOT = 5 AND SUPPLY_DT > LAST_END THEN 'past the LOT5 cap'
               WHEN SUPPLY_DT >  LAST_END                THEN 'after the last observed LOT'
               WHEN IS_CARRYOVER = 1                     THEN 'carryover: episode began inside a LOT'
               WHEN NEAR_ALLO = 1                        THEN 'adjacent to a one-day ALLO LOT'
               ELSE 'unexplained gap between LOTs'
             END                                     AS CAUSE,
             count(*)                                AS N_ORPHAN_AGENT_DAYS,
             round(100.0 * count(*) / max(N_ALL_AGENT_DAYS), 2) AS PCT_OF_ALL_AGENT_DAYS,
             count(DISTINCT PATID)                   AS N_PATIENTS,
             count(DISTINCT concat_ws('|', cast(PATID AS string), MAP_MED_TYPE,
                                      cast(MAP_CNT AS string))) AS N_EPISODES
      FROM orphan CROSS JOIN total
      GROUP BY 1
      ORDER BY 2 DESC"),

  # 5. In-window CAR-T is deliberately not a boundary and IS kept in LOT1_SCT.
  #    The question is only whether the final deliverable can see it.
  list(id = "in-window-cart-not-in-final-table",
       what = "Patients with a CAR-T inside LOT1's induction window, invisible in LOT_LONG",
       expect = "output-surface gap, not a boundary error",
       sql = "
      WITH lot1 AS (
        SELECT PATID, LOT_START_DT AS LOT1_START_DT
        FROM {t$long} WHERE LOT_NUM = 1
      ),
      in_window AS (
        SELECT s.PATID
        FROM {t$sct} s
        INNER JOIN lot1 l ON l.PATID = s.PATID
        WHERE s.FIRST_CART_DT IS NOT NULL
          AND s.FIRST_CART_DT BETWEEN l.LOT1_START_DT
                                  AND date_add(l.LOT1_START_DT, {p$ind1 - 1})
      ),
      cart_line AS (
        SELECT DISTINCT PATID FROM {t$long} WHERE LOT_START_TYPE = 'CART'
      )
      SELECT count(*)                                                  AS N_PATIENTS_IN_WINDOW_CART,
             sum(CASE WHEN c.PATID IS NOT NULL THEN 1 ELSE 0 END)      AS N_ALSO_WITH_A_CART_LINE_LATER
      FROM in_window i LEFT JOIN cart_line c ON c.PATID = i.PATID"),

  # Context for the Q1 duration tab. Not a finding on its own.
  list(id = "line-length-by-start-type",
       what = "Line duration by line number and start type - context for the Q1 tab",
       expect = "no target; this is the distribution the findings above bear on",
       sql = "
      SELECT l.LOT_NUM, l.LOT_START_TYPE,
             count(*)                                   AS N_LINES,
             round(avg(l.LOT_BASE_LENGTH), 1)           AS MEAN_LENGTH_DAYS,
             percentile_approx(l.LOT_BASE_LENGTH, 0.5)  AS MEDIAN_LENGTH_DAYS,
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
  cat("Needs DATABRICKS_PWD, DOMINO_USER_NAME (or PROJECT_WORK_SCHEMA)\n")
  cat("and OBJECT_PREFIX. No cohort table: nothing here reads one.\n\n")
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

  set_lot_config(cfg)
  dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
  stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")

  # Which line table to count. LOT_LONG_FINAL is the study deliverable, with the
  # line criteria applied; LOT_LONG is what the engine built before them.
  which_tbl <- trimws(Sys.getenv("AUDIT_TABLE", unset = "LOT_LONG"))
  if (!which_tbl %in% c("LOT_LONG_FINAL", "LOT_LONG"))
    stop("AUDIT_TABLE must be LOT_LONG_FINAL or LOT_LONG.", call. = FALSE)

  # OBS_END_DT is not persisted - it is chosen at build time from ENDDATE or
  # ENDDATE_CE. Match whichever the run used, or the death filter will disagree
  # with the build's own idea of when observation stopped.
  obs_col <- if (isTRUE(cfg$censor_at_disenrollment)) "ENDDATE_CE" else "ENDDATE"

  t <- list(long   = lot_out(which_tbl),
            map    = lot_out("MAP_STACKED"),
            sct    = lot_out("LOT1_SCT"))

  cat("Counting against:\n")
  for (nm in names(t)) cat("  ", nm, ": ", t[[nm]], "\n", sep = "")
  cat("  observation column: ", obs_col, "\n\n", sep = "")

  # Substitution reciprocity is a codelist question, not a warehouse one:
  # permissible_subs is loaded from CSV into a session view and is not persisted,
  # so it is checked here against the file the build would read. A one-way pair
  # is not automatically wrong - some are deliberately directional - but the set
  # should be reviewed rather than assumed symmetric.
  subs_csv <- file.path(cfg$codelist_dir, "permissible_subs.csv")
  cat("== substitution-reciprocity\n")
  if (!file.exists(subs_csv)) {
    cat("   SKIPPED: no permissible_subs.csv at ", subs_csv, "\n\n", sep = "")
  } else {
    ps <- utils::read.csv(subs_csv, stringsAsFactors = FALSE)
    key <- paste(ps$original_med, ps$substitute_med)
    rev <- paste(ps$substitute_med, ps$original_med)
    one_way <- ps[!(key %in% rev), c("original_med", "substitute_med")]
    cat("   ", nrow(ps), " pairs, ", nrow(one_way), " present in one direction only\n", sep = "")
    if (nrow(one_way)) print(head(one_way, 20), row.names = FALSE)
    cat("\n")
  }

  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  # Counting a half-written run reports its incompleteness as findings. Refuse
  # one whose own build did not finish, the way run_lot_qc.R does, and take the
  # induction window from what THAT run recorded rather than today's config.csv.
  source(file.path(.script_dir, "R", "checks.R"))
  st <- db_q(con, glue("SELECT RUN_ID, STATUS FROM {lot_out('LOT_BUILD_STATUS')}
                        ORDER BY RUN_ID DESC LIMIT 1"))
  if (!nrow(st))
    stop("No row in ", lot_out("LOT_BUILD_STATUS"), ", so there is no run to ",
         "count under prefix ", pfx, ".", call. = FALSE)
  run_id <- as.character(st$RUN_ID[1]); status <- as.character(st$STATUS[1])
  if (!identical(toupper(status), "COMPLETE"))
    stop("The run owning this prefix is '", status, "', not complete. Counting ",
         "it would report an unfinished build as findings.", call. = FALSE)
  meta <- db_q(con, glue("SELECT CONTRACT_SETTINGS FROM {lot_out('LOT_RUN_METADATA')}
                          WHERE RUN_ID = '{run_id}'"))
  if (!nrow(meta))
    stop("No LOT_RUN_METADATA row for run ", run_id, ", so the settings this ",
         "run was built with are unknown.", call. = FALSE)
  p <- qc_params(as.character(meta$CONTRACT_SETTINGS[1]), run_id)
  cat("Run ", run_id, " (", status, "), induction window ", p$ind1, " days\n\n", sep = "")

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
