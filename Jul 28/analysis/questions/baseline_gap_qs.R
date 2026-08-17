#!/usr/bin/env Rscript
# How many patients discontinue the previous line BEFORE the baseline period
# for the next one begins.
#
#   DATABRICKS_PWD=... DOMINO_USER_NAME=usr00000 OBJECT_PREFIX=ndmm_ \
#     Rscript analysis/questions/baseline_gap_qs.R
#
#   BASELINE_DAYS=365 ...   to ask the same question of a different window
#
# The question, for 2L and again for 3L: a study that characterises a patient
# over the N months immediately before their 2L start reads a window that opens
# at LOT2_START - N. A patient whose 1L ended before that day discontinued
# outside the window, so nothing in the baseline period records the end of the
# line they were on. This counts them.
#
#   |<-------- 1L -------->|                  gap                |<-- 2L -->|
#                          ^ 1L ends                             ^ 2L starts
#                                        |<-- baseline window -->|
#                          ^ ends BEFORE the window opens - counted here
#
# Read-only. Every statement is a SELECT; it builds nothing.
#
# Two things this deliberately does not do.
#
# It does not require the gap to be untreated. LOT_BASE_END_DT to the next
# line's start is by construction a period with no line in it, but a patient
# can have claims there that the line rules did not turn into a line - a
# steroid, a permissible substitute, an out-of-window transplant. The
# question is about where the line ENDED relative to the window, so that is
# what is measured.
#
# It does not use LOT_BASE_DISCON_DT. A line that ended DEATH, SCT_ALLO or
# STUDY_END has no discontinuation date, and dropping those patients would
# answer a narrower question than the one asked. The split by end reason is
# in the output instead, so the discontinued-only subset is recoverable.

.script_dir <- local({
  args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", args, value = TRUE)
  if (length(file_arg) > 0)
    return(dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", file_arg[1]),
                                      fixed = TRUE))))
  getwd()
})

source(file.path(.script_dir, "_setup.R"))
qs_setup(.script_dir)

BASELINE_DAYS <- local({
  v <- suppressWarnings(as.integer(trimws(Sys.getenv("BASELINE_DAYS", unset = "365"))))
  if (is.na(v) || v <= 0)
    stop("BASELINE_DAYS must be a positive whole number of days.", call. = FALSE)
  v
})

main <- function() {
  stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")
  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  out_dir <- cfg$output_dir
  if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  stamp <- format(Sys.time(), "%Y%m%d_%H%M%S")

  write_out <- function(df, tag) {
    if (is.null(df) || nrow(df) == 0) {
      log_msg("  (", tag, ": no rows)"); return(invisible())
    }
    f <- file.path(out_dir, paste0("baseline_gap_", tag, "_", stamp, ".csv"))
    write.csv(df, f, row.names = FALSE)
    log_msg("  wrote ", tag, " -> ", f, " (", nrow(df), " rows)")
  }

  # The tables below belong to whichever LOT run last wrote this prefix, and a
  # newer failed run may have replaced them. Bound before anything is counted,
  # like every other script in this folder.
  qs_check_run_binding(con)

  lot <- qs_tbl("LOT_LONG_FINAL")

  # Consecutive lines, paired on the same patient. The join is on n and n+1
  # rather than lag(), so a patient missing a line number cannot silently pair
  # 1L with 3L and report a gap that spans a line.
  pairs <- glue("
    SELECT p.PATID,
           p.LOT_NUM                      AS PREV_LOT,
           n.LOT_NUM                      AS NEXT_LOT,
           p.LOT_BASE_END_DT              AS PREV_END_DT,
           p.LOT_BASE_END_REASON          AS PREV_END_REASON,
           n.LOT_START_DT                 AS NEXT_START_DT,
           datediff(n.LOT_START_DT, p.LOT_BASE_END_DT) AS GAP_DAYS
    FROM {lot} p
    INNER JOIN {lot} n
      ON n.PATID = p.PATID AND n.LOT_NUM = p.LOT_NUM + 1
    WHERE p.LOT_BASE_END_DT IS NOT NULL
      AND n.LOT_START_DT IS NOT NULL")

  # --- the answer ------------------------------------------------------------
  # OUTSIDE is the count Julia asked for: the previous line ended strictly
  # before the baseline window opened. The window opens at
  # NEXT_START_DT - BASELINE_DAYS, so ending on that day is inside it - hence
  # GAP_DAYS > BASELINE_DAYS, not >=.
  q_main <- db_q(con, glue("
    SELECT NEXT_LOT,
           count(*)                                             AS N_PATIENTS,
           sum(CASE WHEN GAP_DAYS >  {BASELINE_DAYS} THEN 1 ELSE 0 END) AS N_ENDED_BEFORE_BASELINE,
           round(100.0 * sum(CASE WHEN GAP_DAYS > {BASELINE_DAYS} THEN 1 ELSE 0 END)
                 / count(*), 1)                                 AS PCT_BEFORE_BASELINE,
           sum(CASE WHEN GAP_DAYS <= {BASELINE_DAYS} THEN 1 ELSE 0 END) AS N_INSIDE_BASELINE,
           percentile_approx(GAP_DAYS, 0.5)                     AS MEDIAN_GAP_DAYS,
           min(GAP_DAYS)                                        AS MIN_GAP_DAYS,
           max(GAP_DAYS)                                        AS MAX_GAP_DAYS
    FROM ({pairs}) g
    GROUP BY NEXT_LOT ORDER BY NEXT_LOT"))

  # --- how far outside -------------------------------------------------------
  # A count on its own does not say whether these are near misses or years
  # out, and the two mean different things for a study design.
  q_bands <- db_q(con, glue("
    SELECT NEXT_LOT,
           CASE WHEN GAP_DAYS <= 0   THEN 'a. next line starts on or before the end'
                WHEN GAP_DAYS <= 90  THEN 'b. 1-90 days'
                WHEN GAP_DAYS <= 180 THEN 'c. 91-180 days'
                WHEN GAP_DAYS <= 365 THEN 'd. 181-365 days'
                WHEN GAP_DAYS <= 730 THEN 'e. 366-730 days'
                ELSE                      'f. over 730 days' END AS GAP_BAND,
           count(*) AS N_PATIENTS
    FROM ({pairs}) g
    GROUP BY NEXT_LOT, 2 ORDER BY NEXT_LOT, 2"))

  # --- by how the previous line ended ----------------------------------------
  # DEATH and SCT_ALLO cannot be a discontinuation, and STUDY_END is a censor
  # rather than a stop. Split out so the discontinued-only answer is available
  # without re-running anything.
  q_reason <- db_q(con, glue("
    SELECT NEXT_LOT, PREV_END_REASON,
           count(*)                                             AS N_PATIENTS,
           sum(CASE WHEN GAP_DAYS >  {BASELINE_DAYS} THEN 1 ELSE 0 END) AS N_ENDED_BEFORE_BASELINE,
           percentile_approx(GAP_DAYS, 0.5)                     AS MEDIAN_GAP_DAYS
    FROM ({pairs}) g
    GROUP BY NEXT_LOT, PREV_END_REASON
    ORDER BY NEXT_LOT, N_PATIENTS DESC"))

  # The denominator this is NOT. Patients who never reached the next line are
  # absent from every table above by construction, so the percentages are of
  # those who did reach it. Printed rather than left to be assumed.
  q_reach <- db_q(con, glue("
    SELECT LOT_NUM, count(DISTINCT PATID) AS N_PATIENTS
    FROM {lot} GROUP BY LOT_NUM ORDER BY LOT_NUM"))

  cat("\nPatients reaching each line (the denominators above are the pairs,",
      "\nso a patient who never started the next line is not in them):\n")
  print(q_reach, row.names = FALSE)
  cat("\nPrevious line ended before a ", BASELINE_DAYS,
      "-day baseline window for the next line opened:\n", sep = "")
  print(q_main, row.names = FALSE)
  cat("\nHow far outside:\n"); print(q_bands, row.names = FALSE)
  cat("\nBy how the previous line ended:\n"); print(q_reason, row.names = FALSE)

  write_out(q_reach,  "lines_reached")
  write_out(q_main,   "summary")
  write_out(q_bands,  "gap_bands")
  write_out(q_reason, "by_end_reason")
}

if (!interactive()) main()
