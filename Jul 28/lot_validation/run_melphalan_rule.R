#!/usr/bin/env Rscript
# The melphalan line-advancing rule, measured against a finished LOT run.
#
#   # print the rule, the settings and what would be measured - no connection
#   Rscript lot_validation/run_melphalan_rule.R
#
#   # measure it against a run
#   DATABRICKS_PWD=... DOMINO_USER_NAME=usr00000 OBJECT_PREFIX=ndmm_ \
#     MELP_EXECUTE=TRUE Rscript lot_validation/run_melphalan_rule.R
#
# Reads a finished run and writes three tables of its own. It changes nothing in
# lot, builds no lines, and does not touch the run it measures - so it can be
# run against the production tables without a rebuild.
#
# What it cannot do: give the resulting line count or the line dates. Moving a
# boundary changes which line an exposure falls in, whether an agent is inside
# an induction window, regimen membership, discontinuation dates and every later
# line number. None of that is recoverable from finished boundaries. It counts
# boundaries - how many the rule adds and how many it removes - which is what
# sizes the decision. An exact resulting line structure needs an alternate
# build, once the clinical rule is settled.

.script_dir <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  # Rscript renders a space in the path as ~+~, so a folder with one in its
  # name resolves to nothing without this.
  if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                            fixed = TRUE))) else getwd()
})
source(file.path(.script_dir, "R", "melphalan.R"))
source(file.path(.script_dir, "R", "run_binding.R"))

LOT_ROOT <- normalizePath(file.path(.script_dir, "..", "lot"), mustWork = TRUE)
env_flag <- function(nm) identical(toupper(trimws(Sys.getenv(nm, unset = ""))), "TRUE")

report_rule <- function(mc) {
  cat("\nThe melphalan line-advancing rule, as asked.\n\n")
  cat("  An exposure is one administration; doses less than ", mc$exposure_days,
      " days apart\n  are the same one. Consecutive pairs, so a third exposure ",
      "is judged\n  against the second.\n\n", sep = "")
  cat("  first exposure INSIDE its line's induction window\n")
  cat("    next < ", mc$advance_days, " days     does not advance\n", sep = "")
  cat("    next >= ", mc$advance_days, " days    the NEXT exposure starts a line, on its own date\n\n", sep = "")
  cat("  first exposure OUTSIDE the induction window\n")
  cat("    next < ", mc$restart_days, " days      the FIRST exposure starts a line, on its own date\n", sep = "")
  cat("    next ", mc$restart_days, "-", mc$advance_days - 1L,
      " days   neither advances\n", sep = "")
  cat("    next >= ", mc$advance_days, " days    the NEXT exposure starts a line, on its own date\n\n", sep = "")
  cat("  induction window: ", mc$induction_1l, " days at LOT1, ", mc$induction_n,
      " at LOT2 and later - the build's own.\n\n", sep = "")
  cat("Where a transplant is coded on the same event (MELP_RULE_MODE):\n")
  cat("  mode: ", mc$mode, "\n", sep = "")
  if (identical(mc$mode, "yield_to_sct"))
    cat("    An exposure with an AUTO coded within ", mc$sct_days, " days is left to the\n",
        "    transplant rule, which already allows a tandem within 180 days and\n",
        "    ends the line on an excess one. The melphalan rule then only fills\n",
        "    the gap where a transplant left no procedure code.\n", sep = "")
  else
    cat("    Every exposure is judged, whether or not a transplant is coded on\n",
        "    it. This is the rule exactly as written. Where a transplant IS\n",
        "    coded, both rules see one clinical event; the flag is recorded so\n",
        "    the overlap is countable.\n", sep = "")
  cat("\n  The ask does not say which. Set MELP_RULE_MODE=as_asked or\n",
      "  =yield_to_sct; the mode is written onto every row.\n", sep = "")
  cat("\nSettings, and what each one does:\n\n")
  for (nm in names(MELP_SETTINGS)) {
    s <- MELP_SETTINGS[[nm]]
    cat(sprintf("  %-28s %-6s %s\n", s$env, format(mc[[nm]]), s$what))
  }
  cat("\nWrites <prefix>MELP_RULE_EXPOSURES, <prefix>MELP_RULE_BRANCHES and\n",
      "<prefix>MELP_RULE_IMPACT. It writes no LOT table and rebuilds nothing.\n", sep = "")
}

main <- function() {
  mc <- melp_cfg()
  report_rule(mc)
  if (!env_flag("MELP_EXECUTE")) {
    cat("\nNothing was measured. Set MELP_EXECUTE=TRUE to run against a warehouse.\n")
    return(invisible(NULL))
  }
  stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")
  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  prefix <- Sys.getenv("OBJECT_PREFIX", unset = "")
  # The same run-ownership rule the other validation programs use. Measuring an
  # unfinished run's lines would report an impact on lines that are not final.
  run <- require_lot_run(con, prefix)
  run_id <- paste0("melp_", format(Sys.time(), "%Y%m%d%H%M%S"))

  lines <- wrk(paste0(prefix, "LOT_LONG_FINAL"))
  maps  <- wrk(paste0(prefix, "MAP_STACKED"))
  autos <- wrk(paste0(prefix, "TX_AUTO_DATES"))
  ex    <- wrk(paste0(prefix, "MELP_RULE_EXPOSURES"))
  br    <- wrk(paste0(prefix, "MELP_RULE_BRANCHES"))
  im    <- wrk(paste0(prefix, "MELP_RULE_IMPACT"))

  cat("\nMeasuring against LOT run ", run$run_id, " on ", lines, "\n", sep = "")
  db_exec(con, glue("CREATE OR REPLACE TABLE {ex} AS {
    melp_rule_sql(lines, maps, autos, mc, run_id)}"))
  db_exec(con, glue("CREATE OR REPLACE TABLE {br} AS {melp_branch_sql(ex)}"))
  db_exec(con, glue("CREATE OR REPLACE TABLE {im} AS {
    melp_impact_sql(ex, lines, mc, run_id)}"))

  n <- db_q(con, glue("
    SELECT count(*) AS n_expo, count(DISTINCT PATID) AS n_pat,
           sum(CASE WHEN ADVANCES IS NOT NULL THEN 1 ELSE 0 END) AS n_adv,
           sum(HAS_AUTO) AS n_coded
    FROM {ex}"))
  cat("\n", n$n_expo, " exposures in ", n$n_pat, " patients. ", n$n_adv,
      " would advance a line.\n", sep = "")
  cat(n$n_coded, " of those exposures have an AUTO transplant coded within ",
      mc$sct_days, " days",
      if (identical(mc$mode, "yield_to_sct")) " and were left to it" else
        " and were judged anyway", ".\n", sep = "")

  b <- db_q(con, glue("SELECT * FROM {br}"))
  cat("\nBy branch:\n")
  for (i in seq_len(nrow(b)))
    cat(sprintf("  %-32s %-18s %-11s %6d exposures, %6d patients\n",
                b$FIRST_DOSE[i], b$NEXT_EXPOSURE[i], b$EFFECT[i],
                b$N_EXPOSURES[i], b$N_PATIENTS[i]))

  s <- db_q(con, glue("
    SELECT count(*) AS n_pat, sum(N_SPLIT) AS splits, sum(N_MERGE) AS merges
    FROM {im}"))
  cat("\nWhat it would do to the line BOUNDARIES:\n")
  cat("  ", s$n_pat, " patients have a boundary that moves.\n", sep = "")
  cat("  +", s$splits, " boundaries the rule adds.\n", sep = "")
  cat("  -", s$merges, " boundaries it removes.\n", sep = "")
  cat("\nThese are boundaries, NOT a resulting line count, and subtracting one ",
      "from the\nother does not give one. Moving a boundary changes which line ",
      "an exposure falls\nin, whether an agent is inside an induction window, ",
      "regimen membership and every\nlater line number. An exact line structure ",
      "needs an alternate build.\n", sep = "")
  cat("\nWrote ", ex, ", ", br, " and ", im, ".\n", sep = "")
}

if (!interactive()) {
  if (env_flag("MELP_EXECUTE")) {
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
