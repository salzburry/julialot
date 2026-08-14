#!/usr/bin/env Rscript
# Re-challenge events and the gap that decides them, against a finished LOT run.
#
#   # print what would be measured - no connection
#   Rscript lot/validation/run_rechallenge_evidence.R
#
#   # measure it against a run
#   DATABRICKS_PWD=... DOMINO_USER_NAME=usr00000 OBJECT_PREFIX=ndmm_ \
#     RECHALL_EXECUTE=TRUE Rscript lot/validation/run_rechallenge_evidence.R
#
# Reads <prefix>STOCKPILE_ABSORBED_ADD, so run_stockpiling_rule.R comes first.
#
# The question it serves: the protocol ends a line on an agent that is not in the
# line's regimen, and says nothing about whether the patient has had that agent
# before. So a drug returning after an earlier line ends one line and opens
# another. Whether it should is clinical, and the measure that decides it is how
# long the patient had actually been off the drug - GAP_DAYS, read off claim
# dates so it means the same thing for a patient whose cover had lapsed and one
# whose had not.
#
# It changes nothing in lot, builds no lines, and does not touch the run it
# measures. It cannot give the line structure under any threshold: that needs an
# alternate build.

.script_dir <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  # Rscript renders a space in the path as ~+~, so a folder with one in its
  # name resolves to nothing without this.
  if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                            fixed = TRUE))) else getwd()
})
source(file.path(.script_dir, "R", "stockpiling.R"))
source(file.path(.script_dir, "R", "rechallenge.R"))
source(file.path(.script_dir, "R", "run_binding.R"))

LOT_ROOT <- normalizePath(file.path(.script_dir, "..", "engine"), mustWork = TRUE)
env_flag <- function(nm) identical(toupper(trimws(Sys.getenv(nm, unset = ""))), "TRUE")
num0 <- function(x) if (!length(x) || is.na(x[1])) "-" else format(x[1], big.mark = ",")

report_rule <- function(rc) {
  cat("\nRe-challenge: an agent returning to a line it is not part of.\n\n")
  cat("  An event is an agent that appeared in ANY earlier line for the patient,\n")
  cat("  is absent from this line's regimen, and turns up inside this line. The\n")
  cat("  protocol ends the line on it and opens the next one there.\n\n")
  cat("  GAP_DAYS is the days from the previous claim for that agent to the one\n")
  cat("  that brings it back. It comes from claim dates, not cover, so it reads\n")
  cat("  the same whether or not days-supply happened to run out.\n\n")
  cat("  Bands:\n")
  cat("    <=45d    inside one dispense of the last fill - continuous therapy\n")
  cat("    46-90d   a lapse, shorter than the run-out gap the build uses\n")
  cat("    91-180d  longer than the discontinuation gap - the patient stopped\n")
  cat("    >180d    a restart after months off\n\n")
  cat("  Two populations, split by what the BUILD did, not by anything clinical:\n")
  cat("    FIRED       the return opened an episode, so the line ended MED_ADD.\n")
  cat("    SUPPRESSED  an open episode absorbed the claim, so nothing happened.\n")
  cat("  If their gap distributions match, the boundary is being decided by\n")
  cat("  leftover days-supply rather than by the patient.\n\n")
  cat("  A new partner agent within ", rc$partner, " days is reported alongside: a drug\n",
      "  returning on its own reads as continuation, with a new partner as a new\n",
      "  regimen.\n", sep = "")
  cat("\nWrites <prefix>RECHALL_EVENTS, <prefix>RECHALL_BY_GAP and\n",
      "<prefix>RECHALL_BY_MED. It writes no LOT table and rebuilds nothing.\n", sep = "")
}

main <- function() {
  rc <- rechall_cfg()
  report_rule(rc)
  if (!env_flag("RECHALL_EXECUTE")) {
    cat("\nNothing was measured. Set RECHALL_EXECUTE=TRUE to run against a warehouse.\n")
    return(invisible(NULL))
  }
  stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")
  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  prefix <- Sys.getenv("OBJECT_PREFIX", unset = "")
  run <- require_lot_run(con, prefix)
  rc  <- rechall_cfg(from_run = tryCatch(lot_run_meta(con, prefix),
                                         error = function(e) NULL))
  run_id <- paste0("rechall_", format(Sys.time(), "%Y%m%d%H%M%S"))

  lines  <- wrk(paste0(prefix, "LOT_LONG_FINAL"))
  maps   <- wrk(paste0(prefix, "MAP_STACKED"))
  claims <- wrk(paste0(prefix, "MMA_MED_PROCESSED"))
  # The suppressed half of the population. Without it only the boundaries the
  # build already made are visible, which is the half that is not in question.
  absorb <- wrk(paste0(prefix, "STOCKPILE_ABSORBED_ADD"))
  if (!isTRUE(tryCatch({ db_q(con, glue("SELECT 1 FROM {absorb} LIMIT 1")); TRUE },
                       error = function(e) FALSE)))
    stop("Cannot read ", absorb, ". Run run_stockpiling_rule.R first: it holds ",
         "the returns an open episode absorbed, which are half the events and ",
         "the half the build cannot see.", call. = FALSE)

  ev <- wrk(paste0(prefix, "RECHALL_EVENTS"))
  bg <- wrk(paste0(prefix, "RECHALL_BY_GAP"))
  bm <- wrk(paste0(prefix, "RECHALL_BY_MED"))

  cat("\nMeasuring against LOT run ", run$run, " on ", lines, "\n", sep = "")
  db_exec(con, glue("CREATE OR REPLACE TABLE {ev} AS {
    rechall_events_sql(lines, maps, claims, absorb, rc, run_id,
                       run$run, run$stamp)}"))
  db_exec(con, glue("CREATE OR REPLACE TABLE {bg} AS {rechall_gap_sql(ev)}"))
  db_exec(con, glue("CREATE OR REPLACE TABLE {bm} AS {rechall_by_med_sql(ev)}"))

  t <- db_q(con, glue("
    SELECT count(*) AS n_ev, count(DISTINCT PATID) AS n_pat,
           sum(CASE WHEN BOUNDARY = 'SUPPRESSED' THEN 1 ELSE 0 END) AS n_sup,
           sum(CASE WHEN GAP_DAYS IS NULL THEN 1 ELSE 0 END) AS n_nogap,
           percentile_approx(GAP_DAYS, 0.5) AS med_gap
    FROM {ev}"))
  cat("\n", num0(t$n_ev), " re-challenge events in ", num0(t$n_pat),
      " patients. Median gap ", format(t$med_gap[1]), " days.\n", sep = "")
  cat("  ", num0(t$n_sup), " of them the build did not act on, because an open ",
      "episode\n      absorbed the claim.\n", sep = "")
  if (length(t$n_nogap) && !is.na(t$n_nogap[1]) && t$n_nogap[1] > 0)
    cat("  ", num0(t$n_nogap), " have no earlier claim for the agent and so no gap. ",
        "That\n      contradicts the event definition and should be read before ",
        "anything else.\n", sep = "")

  g <- db_q(con, glue("SELECT * FROM {bg}"))
  cat("\nBy gap band, and by what the build did:\n")
  cat(sprintf("  %-24s %-11s %8s %9s %11s %13s\n",
              "band", "boundary", "events", "patients", "median gap", "w/ partner"))
  for (i in seq_len(nrow(g)))
    cat(sprintf("  %-24s %-11s %8s %9s %11s %13s\n",
                g$GAP_BAND[i], g$BOUNDARY[i], num0(g$N_EVENTS[i]),
                num0(g$N_PATIENTS[i]), format(g$MEDIAN_GAP_DAYS[i]),
                num0(g$N_WITH_NEW_PARTNER[i])))
  cat("\n  Read down the band column. Where FIRED and SUPPRESSED look alike, the\n",
      "  build is splitting clinically identical patients on days-supply alone.\n",
      sep = "")

  th <- db_q(con, rechall_threshold_sql(ev))
  cat("\nWhat each threshold would keep as a line boundary:\n")
  cat(sprintf("  %-11s %8s %9s %9s %9s %10s\n",
              "boundary", "events", ">= 0d", ">= 46d", ">= 91d", ">= 181d"))
  for (i in seq_len(nrow(th)))
    cat(sprintf("  %-11s %8s %9s %9s %9s %10s\n",
                th$BOUNDARY[i], num0(th$N_EVENTS[i]), num0(th$KEEP_AT_0D[i]),
                num0(th$KEEP_AT_46D[i]), num0(th$KEEP_AT_91D[i]),
                num0(th$KEEP_AT_181D[i])))

  m <- db_q(con, glue("SELECT * FROM {bm}"))
  if (nrow(m)) {
    cat("\nBy agent:\n")
    cat(sprintf("  %-10s %8s %9s %12s %11s %13s\n", "agent", "events",
                "patients", "suppressed", "median gap", "w/ partner"))
    for (i in seq_len(min(nrow(m), 15L)))
      cat(sprintf("  %-10s %8s %9s %12s %11s %13s\n",
                  m$MED_ABBR[i], num0(m$N_EVENTS[i]), num0(m$N_PATIENTS[i]),
                  num0(m$N_SUPPRESSED[i]), format(m$MEDIAN_GAP_DAYS[i]),
                  num0(m$N_WITH_NEW_PARTNER[i])))
    if (nrow(m) > 15L) cat("  ... ", nrow(m) - 15L, " more in ", bm, "\n", sep = "")
  }

  cat("\nThese are events and gaps, NOT a line count under any threshold. Keeping\n",
      "or dropping a boundary renumbers every later line for that patient and\n",
      "changes what falls in which induction window. An exact line structure\n",
      "needs an alternate build.\n", sep = "")
  settled <- recheck_lot_attempt(con, prefix, run, "RECHALL")
  cat("\nWrote ", ev, ", ", bg, " and ", bm, ".\n", sep = "")
  if (!isTRUE(settled)) quit(status = 1L)
}

if (!interactive()) {
  # cfg, wrk(), db_exec() and db_q() come from the engine. The dry run needs
  # none of them, so they are loaded only on the path that connects.
  if (env_flag("RECHALL_EXECUTE")) {
    library(DBI); library(odbc); library(glue)
    e <- new.env(parent = globalenv())
    sys.source(file.path(LOT_ROOT, "R", "load_inputs.R"), envir = e)
    e$load_pipeline_inputs(LOT_ROOT, "config.csv")
    for (f in c("config_lot.R", "db_utils_lot.R")) source(file.path(LOT_ROOT, "R", f))
    set_lot_config(modifyList(cfg_defaults, list(
      work_schema = Sys.getenv("PROJECT_WORK_SCHEMA",
                      unset = Sys.getenv("DOMINO_USER_NAME", unset = "")),
      object_prefix = Sys.getenv("OBJECT_PREFIX", unset = ""))))
  }
  main()
}
