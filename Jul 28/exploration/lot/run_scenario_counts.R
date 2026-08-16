#!/usr/bin/env Rscript
# Does the real data contain the scenarios lot/SCENARIOS.md is written around?
#
#   # list what this will count; no connection, touches nothing
#   Rscript run_scenario_counts.R
#
#   # run it
#   DATABRICKS_PWD=... DOMINO_USER_NAME=usr00000 OBJECT_PREFIX=ndmm_ \
#     INPUT_COHORT_TABLE=ndmm_NDMM_COHORT \
#     AUDIT_EXECUTE=TRUE Rscript run_scenario_counts.R
#
# Read-only. Every statement is a SELECT; nothing is written to the warehouse.
# Results print as a table and land in out/lot_scenario_counts.csv.
#
# Every scenario in lot/SCENARIOS.md is a claim about what the build DOES to a
# patient of a given shape. Each is either derived from the code or checked
# against the vignette catalogue - and neither of those asks the question this
# script asks, which is whether such a patient exists at all.
#
# That matters in both directions. A rule with no patients behind it is not
# wrong, but it is not carrying weight either, and it should not be argued over
# as though it were. A rule with thousands is one to have looked at before a
# rebuild moves it. And a count of zero where one was expected is a signal that
# the scenario has been mis-read, or that the shape cannot arise for a reason
# nobody has written down.
#
# Each entry names the section of SCENARIOS.md it counts, so a number can be
# taken back to the scenario it is about. HANDLED is the column to read second:
# it splits the matching patients by what the build actually did with them, so
# "there are 412 of these" is followed by "and here is how they came out".
#
# This does NOT execute patients through the engine. It counts the finished
# output. A scenario the engine gets wrong would be counted here under whatever
# the engine produced, so a surprising HANDLED split is a reason to look at the
# rule, not a proof that the rule fired.
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
LOT_ROOT <- normalizePath(file.path(.script_dir, "..", "..", "lot", "engine"), mustWork = TRUE)
out_dir  <- file.path(.script_dir, "out")
env_flag <- function(nm) identical(toupper(trimws(Sys.getenv(nm, unset = ""))), "TRUE")

# One entry per finding. `sql` is a glue template over the table names below.
# `expect` records what the synthetic cohort gave, purely so a wildly different
# real number is noticeable rather than silently accepted.
AUDIT_COUNTS <- list(
  # SCENARIOS.md 3.1 / 4.1 - what starts a line, and how often each way.
  # The denominator every other count here should be read against.
  list(id = "5.1-how-every-line-starts",
       what = "Lines by what started them, with median length",
       expect = "MED dominant; SCT_AUTO, CART and SCT_ALLO the tail",
       sql = "
      SELECT LOT_NUM, LOT_START_TYPE,
             count(*)                                   AS N_LINES,
             count(DISTINCT PATID)                      AS N_PATIENTS,
             percentile_approx(LOT_BASE_LENGTH, 0.5)    AS MEDIAN_LENGTH
      FROM {t$long}
      GROUP BY LOT_NUM, LOT_START_TYPE
      ORDER BY LOT_NUM, LOT_START_TYPE"),

  # SCENARIOS.md 4.2 - the divergence from the protocol wording, and the one
  # nobody can size by reading the code. Regimen membership is an episode
  # STARTING inside the window; a dispense arriving under live cover extends the
  # episode it is already in and leaves no start to find. So an agent the patient
  # is demonstrably still taking on the day a line opens is absent from that
  # line's regimen unless its cover happened to lapse first.
  #
  # The protocol says "all MM therapies identified during the first 30 days of
  # the LOT", which reads wider. This is the number that decides whether that
  # difference is a footnote or a finding, and it has to be answered before
  # regimen strings are published.
  list(id = "4.2-prior-agent-covered-but-not-in-the-regimen",
       what = "Later lines where a previous line's agent is under live cover on the start date but absent from the regimen",
       expect = "unknown - never measured; this is the protocol-wording divergence",
       sql = "
      WITH prev_agents AS (
        SELECT l.PATID, l.LOT_NUM, l.LOT_START_DT, l.LOT_BASE_MEDS,
               explode(split(p.LOT_BASE_MEDS, ' ')) AS PREV_MED
        FROM {t$long} l
        INNER JOIN {t$long} p ON p.PATID = l.PATID AND p.LOT_NUM = l.LOT_NUM - 1
        WHERE l.LOT_NUM > 1
          AND coalesce(trim(p.LOT_BASE_MEDS), '') <> ''
      ),
      still_covered AS (
        SELECT DISTINCT a.PATID, a.LOT_NUM, a.PREV_MED,
               CASE WHEN array_contains(split(a.LOT_BASE_MEDS, ' '), a.PREV_MED)
                    THEN 1 ELSE 0 END AS IN_THIS_REGIMEN
        FROM prev_agents a
        INNER JOIN {t$map} m
           ON m.PATID = a.PATID
          AND m.MAP_MED_TYPE = a.PREV_MED
          AND a.LOT_START_DT BETWEEN m.MAP_START_DT AND m.MAP_END_DT
        WHERE a.PREV_MED <> ''
      )
      SELECT LOT_NUM,
             CASE WHEN IN_THIS_REGIMEN = 1
                  THEN 'COVERED AND IN THE REGIMEN (it restarted in the window)'
                  ELSE 'COVERED BUT NOT IN THE REGIMEN (no episode start)' END AS HANDLED,
             count(*)                                   AS N_AGENT_LINE_PAIRS,
             count(DISTINCT PATID)                      AS N_PATIENTS
      FROM still_covered
      GROUP BY 1, 2
      ORDER BY LOT_NUM, HANDLED"),

  # SCENARIOS.md 4.3 - the propagation of the count above. The prior-regimen
  # exclusion looks one line back only, so an agent wrongly missing from line
  # N-1 is free to START line N. The signature is a line whose regimen carries
  # an agent that was in the regimen two lines back but not one - which either
  # means the drug genuinely stopped and came back, or means it never stopped
  # and line N-1 simply failed to record it. The two are indistinguishable here,
  # so this is an upper bound, and the shape to pull patient-level and read.
  list(id = "4.3-line-started-by-an-agent-from-two-lines-back",
       what = "Lines whose regimen holds an agent present two lines back but absent one line back",
       expect = "upper bound on the exclusion being wrongly relaxed",
       sql = "
      WITH ctx AS (
        SELECT l.PATID, l.LOT_NUM, l.LOT_START_TYPE, l.LOT_BASE_MEDS,
               p1.LOT_BASE_MEDS AS PREV1, p2.LOT_BASE_MEDS AS PREV2
        FROM {t$long} l
        INNER JOIN {t$long} p1 ON p1.PATID = l.PATID AND p1.LOT_NUM = l.LOT_NUM - 1
        INNER JOIN {t$long} p2 ON p2.PATID = l.PATID AND p2.LOT_NUM = l.LOT_NUM - 2
        WHERE l.LOT_NUM >= 3
          AND coalesce(trim(l.LOT_BASE_MEDS), '') <> ''
      ),
      ex AS (
        SELECT PATID, LOT_NUM, LOT_START_TYPE, PREV1, PREV2,
               explode(split(LOT_BASE_MEDS, ' ')) AS MED
        FROM ctx
      )
      SELECT LOT_NUM, LOT_START_TYPE,
             count(*)                                       AS N_AGENT_LINE_PAIRS,
             count(DISTINCT concat_ws('|', PATID, LOT_NUM))  AS N_LINES,
             count(DISTINCT PATID)                           AS N_PATIENTS
      FROM ex
      WHERE MED <> ''
        AND NOT array_contains(split(coalesce(PREV1, ''), ' '), MED)
        AND array_contains(split(coalesce(PREV2, ''), ' '), MED)
      GROUP BY LOT_NUM, LOT_START_TYPE
      ORDER BY LOT_NUM, LOT_START_TYPE"),

  # SCENARIOS.md 7.1 - a line ends at the earliest qualifying event. This is
  # the whole cascade as the data actually exercises it. A branch with no rows
  # is a branch nothing has ever taken.
  list(id = "7.1-which-end-reasons-actually-occur",
       what = "Lines by end reason, with median length",
       expect = "every reason the cascade can write should appear, or be explained",
       sql = "
      SELECT LOT_BASE_END_REASON,
             count(*)                                AS N_LINES,
             count(DISTINCT PATID)                   AS N_PATIENTS,
             percentile_approx(LOT_BASE_LENGTH, 0.5) AS MEDIAN_LENGTH
      FROM {t$long}
      GROUP BY LOT_BASE_END_REASON
      ORDER BY N_LINES DESC"),

  # SCENARIOS.md 6.5 - the rule added most recently, and the one with no prior
  # run behind it at all. If SCT_AUTO_CONT is absent from a finished run, the
  # scenario it was written for does not arise in this cohort and the rule is
  # inert; if it is common, every line it touched changed length.
  list(id = "6.5-lines-held-open-to-their-transplant",
       what = "SCT_AUTO_CONT lines: how many, and how much longer the rule made them",
       expect = "unknown - this rule has never been run against claims",
       sql = "
      SELECT l.LOT_NUM,
             count(*)                                     AS N_LINES,
             count(DISTINCT l.PATID)                      AS N_PATIENTS,
             percentile_approx(datediff(l.LOT_BASE_END_DT,
                                        l.LOT_TX_AUTO_MAX_DT), 0.5) AS MEDIAN_DAYS_PAST_TX,
             percentile_approx(l.LOT_BASE_LENGTH, 0.5)    AS MEDIAN_LENGTH
      FROM {t$long} l
      WHERE l.LOT_BASE_END_REASON = 'SCT_AUTO_CONT'
      GROUP BY l.LOT_NUM
      ORDER BY l.LOT_NUM"),

  # SCENARIOS.md 6.5 and 14.5 - the defect the rule closed. Every autologous
  # transplant should now sit inside some line. Read from the transplant rather
  # than from the line, which is the only direction that can see one that
  # belongs nowhere. HANDLED says which line took it.
  list(id = "6.5-does-every-transplant-have-a-line",
       what = "Autologous transplants by whether a line covers them, and which line",
       expect = "IN_A_LINE should account for all of them inside observation",
       sql = "
      WITH tx AS (
        SELECT s.PATID, s.LOT1_TX_AUTO_DT_1 AS TX_DT FROM {t$sct} s
        WHERE s.LOT1_TX_AUTO_DT_1 IS NOT NULL
        UNION ALL
        SELECT s.PATID, s.LOT1_TX_AUTO_DT_2 FROM {t$sct} s
        WHERE s.LOT1_TX_AUTO_DT_2 IS NOT NULL
      ),
      owned AS (
        SELECT tx.PATID, tx.TX_DT,
               max(CASE WHEN tx.TX_DT BETWEEN l.LOT_START_DT AND l.LOT_BASE_END_DT
                        THEN l.LOT_NUM END)                       AS OWNING_LOT,
               max(CASE WHEN l.LOT_START_DT > tx.TX_DT THEN 1 ELSE 0 END) AS HAS_LATER_LINE
        FROM tx
        LEFT JOIN {t$long} l ON tx.PATID = l.PATID
        GROUP BY tx.PATID, tx.TX_DT
      )
      SELECT CASE WHEN OWNING_LOT IS NOT NULL THEN concat('IN_A_LINE: LOT', OWNING_LOT)
                  WHEN HAS_LATER_LINE = 1     THEN 'IN NO LINE, WITH A LATER LINE'
                  ELSE                             'IN NO LINE, TRAILING' END AS HANDLED,
             count(*)              AS N_TRANSPLANTS,
             count(DISTINCT PATID) AS N_PATIENTS
      FROM owned
      GROUP BY 1
      ORDER BY N_TRANSPLANTS DESC"),

  # SCENARIOS.md 6.3 - a tandem is a pair inside 180 days with a clear gap.
  # The gap condition is the study team's, added late, and nothing has ever
  # measured how many pairs it excludes. TANDEM vs INTERRUPTED is that number.
  list(id = "6.3-tandem-pairs-and-what-interrupts-them",
       what = "Two-transplant patients by gap length and whether anything falls between",
       expect = "the INTERRUPTED rows are the pairs the clear-gap rule removed",
       sql = "
      WITH pairs AS (
        SELECT s.PATID, s.LOT1_TX_AUTO_DT_1 AS A1, s.LOT1_TX_AUTO_DT_2 AS A2
        FROM {t$sct} s
        WHERE s.LOT1_TX_AUTO_DT_1 IS NOT NULL AND s.LOT1_TX_AUTO_DT_2 IS NOT NULL
      ),
      judged AS (
        SELECT p.PATID, datediff(p.A2, p.A1) AS GAP,
               coalesce(sum(CASE WHEN m.MAP_START_DT > p.A1 AND m.MAP_START_DT < p.A2
                                  AND m.MAP_MED_CLASS <> 'STEROID'
                                 THEN 1 ELSE 0 END), 0) AS N_BETWEEN
        FROM pairs p
        LEFT JOIN {t$map} m ON p.PATID = m.PATID
        GROUP BY p.PATID, p.A1, p.A2
      )
      SELECT CASE WHEN GAP > 180      THEN 'NOT A TANDEM: over 180 days apart'
                  WHEN N_BETWEEN > 0  THEN 'NOT A TANDEM: treatment in between'
                  ELSE                     'PLANNED TANDEM: clear gap' END AS HANDLED,
             count(*)                                AS N_PATIENTS,
             percentile_approx(GAP, 0.5)             AS MEDIAN_GAP_DAYS
      FROM judged
      GROUP BY 1
      ORDER BY N_PATIENTS DESC"),

  # SCENARIOS.md 3.3 and 14.2 - the regimen cutoff. This should now be empty.
  # A non-zero count means the cutoff is not binding somewhere.
  list(id = "3.3-regimen-agents-starting-after-the-line-ended",
       what = "Lines naming a regimen agent with no supply episode inside the line",
       expect = "zero - this is the defect the regimen cutoff closed",
       sql = "
      WITH exploded AS (
        SELECT l.PATID, l.LOT_NUM, l.LOT_START_DT, l.LOT_BASE_END_DT,
               explode(split(l.LOT_BASE_MEDS, ' ')) AS MED_ABBR
        FROM {t$long} l
        WHERE coalesce(trim(l.LOT_BASE_MEDS), '') <> ''
      )
      SELECT e.LOT_NUM,
             count(DISTINCT concat_ws('|', e.PATID, e.LOT_NUM)) AS N_LINES,
             count(DISTINCT e.PATID)                            AS N_PATIENTS
      FROM exploded e
      WHERE e.MED_ABBR <> ''
        AND NOT EXISTS (SELECT 1 FROM {t$map} m
                        WHERE m.PATID = e.PATID AND m.MAP_MED_TYPE = e.MED_ABBR
                          AND m.MAP_START_DT BETWEEN e.LOT_START_DT AND e.LOT_BASE_END_DT)
      GROUP BY e.LOT_NUM
      ORDER BY e.LOT_NUM"),

  # SCENARIOS.md 5.3 - a run-out is a discontinuation only once confirmed.
  # How many lines rest on the buffer rather than on an event.
  list(id = "5.3-how-discontinuations-were-confirmed",
       what = "DISCONTINUATION lines by whether an event or the buffer confirmed them",
       expect = "both should be substantial; all-buffer would mean the guard never fires",
       sql = "
      SELECT CASE WHEN datediff(l.LOT_BASE_END_DT, l.LOT_BASE_DISCON_DT) = 0
                   AND EXISTS (SELECT 1 FROM {t$long} n
                               WHERE n.PATID = l.PATID AND n.LOT_NUM = l.LOT_NUM + 1)
                  THEN 'CONFIRMED BY THE NEXT LINE STARTING'
                  ELSE 'CONFIRMED BY OBSERVATION ALONE' END AS HANDLED,
             count(*)              AS N_LINES,
             count(DISTINCT l.PATID) AS N_PATIENTS
      FROM {t$long} l
      WHERE l.LOT_BASE_END_REASON = 'DISCONTINUATION'
      GROUP BY 1
      ORDER BY N_LINES DESC"),

  # SCENARIOS.md 6.4 and 7.3 - the CAR-T rules, both added late and both
  # carrying a window this repository has no document for.
  list(id = "6.4-car-t-lines-and-how-they-resolved",
       what = "CAR-T-started lines and CART_INIT ends, by line",
       expect = "CART_INIT is the one that turns on cart_consolidation_days",
       sql = "
      SELECT LOT_NUM,
             sum(CASE WHEN LOT_START_TYPE = 'CART' THEN 1 ELSE 0 END)        AS N_CART_STARTED,
             sum(CASE WHEN LOT_BASE_END_REASON = 'CART_INIT' THEN 1 ELSE 0 END) AS N_CART_INIT_END,
             sum(CASE WHEN LOT_BASE_END_REASON = 'SCT_CART' THEN 1 ELSE 0 END)  AS N_SCT_CART_END,
             count(DISTINCT PATID)                                            AS N_PATIENTS
      FROM {t$long}
      GROUP BY LOT_NUM
      ORDER BY LOT_NUM"),

  # SCENARIOS.md 11.1 - the returning-agent rule, KNOWN_ISSUES #3. The number
  # the open question turns on, so it is here rather than only in the audit.
  list(id = "11.1-lines-spanning-a-long-uncovered-gap",
       what = "Lines whose length far exceeds their covered days, by end reason",
       expect = "the returning-agent question is about the tail of this",
       sql = "
      WITH covered AS (
        SELECT l.PATID, l.LOT_NUM, l.LOT_BASE_LENGTH, l.LOT_BASE_END_REASON,
               coalesce(sum(datediff(least(m.MAP_END_DT, l.LOT_BASE_END_DT),
                                     greatest(m.MAP_START_DT, l.LOT_START_DT)) + 1), 0) AS COVERED_DAYS
        FROM {t$long} l
        LEFT JOIN {t$map} m
          ON m.PATID = l.PATID
         AND m.MAP_START_DT <= l.LOT_BASE_END_DT
         AND m.MAP_END_DT   >= l.LOT_START_DT
         AND m.MAP_MED_CLASS <> 'STEROID'
        GROUP BY l.PATID, l.LOT_NUM, l.LOT_BASE_LENGTH, l.LOT_BASE_END_REASON
      )
      SELECT LOT_BASE_END_REASON,
             CASE WHEN LOT_BASE_LENGTH - COVERED_DAYS >= 180 THEN 'UNCOVERED 180+ DAYS'
                  WHEN LOT_BASE_LENGTH - COVERED_DAYS >= 90  THEN 'UNCOVERED 90-179 DAYS'
                  ELSE                                            'UNCOVERED UNDER 90 DAYS' END AS HANDLED,
             count(*)              AS N_LINES,
             count(DISTINCT PATID) AS N_PATIENTS
      FROM covered
      GROUP BY 1, 2
      ORDER BY LOT_BASE_END_REASON, HANDLED")

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
  which_tbl <- trimws(Sys.getenv("AUDIT_TABLE", unset = "LOT_LONG"))
  if (!which_tbl %in% c("LOT_LONG_FINAL", "LOT_LONG"))
    stop("AUDIT_TABLE must be LOT_LONG_FINAL or LOT_LONG.", call. = FALSE)

  # OBS_END_DT is not persisted - it is chosen at build time from ENDDATE or
  # ENDDATE_CE. Match whichever the run used, or the death filter will disagree
  # with the build's own idea of when observation stopped.
  obs_col <- if (isTRUE(cfg$censor_at_disenrollment)) "ENDDATE_CE" else "ENDDATE"

  lot1_window <- cfg$induction_window_days
  t <- list(long   = lot_out(which_tbl),
            map    = lot_out("MAP_STACKED"),
            sct    = lot_out("LOT1_SCT"),
            cohort = wrk(cohort))

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
