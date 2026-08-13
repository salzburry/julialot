#!/usr/bin/env Rscript
# Coverage-based regimen membership, measured against a finished LOT run.
#
#   # print the rule and what would be measured - no connection
#   Rscript lot/validation/run_stockpiling_rule.R
#
#   # measure it against a run
#   DATABRICKS_PWD=... DOMINO_USER_NAME=usr00000 OBJECT_PREFIX=ndmm_ \
#     STOCK_EXECUTE=TRUE Rscript lot/validation/run_stockpiling_rule.R
#
# The build puts an agent in a line's regimen when it is FILLED inside the
# induction window. Optum supplies no treatment end date, so cover is FILL_DT
# plus DAYS_SUP and an overlapping refill pushes it out instead of opening a new
# episode - which means an agent can be covered across the whole of the next
# line's window while carrying the earlier line's MAP_START_DT, and does not
# join. This counts the patients and lines a coverage rule would change.
#
# Reads a finished run and writes four tables of its own. It changes nothing in
# lot, builds no lines, and does not touch the run it measures, so it can run
# against production without a rebuild.
#
# What it cannot do: give the resulting line structure. An added agent is a base
# agent, so it enters the run-out calculation and leaves the added-medication
# candidate list. WOULD_EXTEND_RUNOUT and WOULD_REMOVE_ADD_MED count the lines
# where each of those bites, which is what sizes the decision - but the lines
# that follow a moved boundary are not recoverable from finished lines.

.script_dir <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  # Rscript renders a space in the path as ~+~, so a folder with one in its
  # name resolves to nothing without this.
  if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                            fixed = TRUE))) else getwd()
})
source(file.path(.script_dir, "R", "stockpiling.R"))
source(file.path(.script_dir, "R", "run_binding.R"))

# The status row is read once before the tables are written and once after.
# Each program replaces its outputs one statement at a time, so a LOT rebuild
# landing in the middle leaves some tables measured against the old attempt and
# some against the new - all stamped with the attempt that was current when the
# run started. Comparing the stamp is what turns that into a message instead of
# a number nobody can trace.
recheck_lot_attempt <- function(con, prefix, before, what) {
  after <- tryCatch(lot_run_row(con, prefix), error = function(e) NULL)
  if (is.null(after)) {
    cat("\nWARNING: the LOT status row could not be re-read, so this run cannot\n",
        "  confirm the tables it measured are still the attempt it started on.\n",
        sep = "")
    return(invisible(FALSE))
  }
  if (!identical(after$run, before$run) || !identical(after$stamp, before$stamp)) {
    cat("\nWARNING: the LOT run moved while this was measuring.\n")
    cat("  started on ", before$run, " / ", before$stamp, "\n", sep = "")
    cat("  now        ", after$run,  " / ", after$stamp,  "\n", sep = "")
    cat("  The ", what, " tables are part one attempt and part the other. Their\n",
        "  SOURCE_LOT_STAMP says which attempt each row was measured against;\n",
        "  re-run against a settled build before reading them.\n", sep = "")
    return(invisible(FALSE))
  }
  cat("\nStill the attempt this started on: ", after$run, " / ", after$stamp,
      ".\n", sep = "")
  invisible(TRUE)
}


env_flag <- function(nm) identical(toupper(trimws(Sys.getenv(nm, unset = ""))), "TRUE")
# A count that came back NULL is not a zero - it is a question that did not run.
num0 <- function(x) if (!length(x) || is.na(x[1])) "-" else format(x[1], big.mark = ",")

report_rule <- function(sc) {
  cat("\nRegimen membership, as built and as the alternative.\n\n")
  cat("  built        an agent joins a line's regimen when it is FILLED inside\n")
  cat("               the induction window (MAP_START_DT in the window).\n")
  cat("  alternative  it joins when the patient is COVERED, so an episode that\n")
  cat("               opened in an earlier line and is still running joins too.\n\n")
  cat("  Induction windows judged: LOT1 ", sc$ind1, "d, CAR-T-started ", sc$cart,
      "d, other ", sc$indn, "d.\n", sep = "")
  cat("  ALLO-started lines are excluded - they carry no regimen at all.\n")
  cat("  LOT1 cannot be affected: it starts at the patient's first non-steroid\n")
  cat("  MM agent, so no such episode precedes it. A non-zero LOT1 is reported\n")
  cat("  rather than hidden, because it would mean this assumption is wrong.\n")
  cat("\n  Two populations are separated, because they are different questions:\n")
  cat("    passive   leftover cover and no claim of its own in the window. The\n")
  cat("              study team settled this one - a patient who has switched\n")
  cat("              is no longer filling the old agent.\n")
  cat("    absorbed  a real claim inside the window that an already-open\n")
  cat("              episode swallowed, so it opened no episode and the agent\n")
  cat("              is absent from the regimen anyway. Nothing settled covers\n")
  cat("              this: the patient is still filling the drug.\n")
  cat("\nWrites <prefix>STOCKPILE_AGENTS, <prefix>STOCKPILE_IMPACT,\n",
      "<prefix>STOCKPILE_BY_LOT and <prefix>STOCKPILE_BY_MED. It reads\n",
      "<prefix>MMA_MED_PROCESSED for the claim dates. It writes no LOT table\n",
      "and rebuilds nothing.\n", sep = "")
}

main <- function() {
  sc <- stock_cfg()
  report_rule(sc)
  if (!env_flag("STOCK_EXECUTE")) {
    cat("\nNothing was measured. Set STOCK_EXECUTE=TRUE to run against a warehouse.\n")
    return(invisible(NULL))
  }
  stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")
  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  prefix <- Sys.getenv("OBJECT_PREFIX", unset = "")
  # The same run-ownership rule the other validation programs use. Measuring an
  # unfinished run's lines would report an impact on lines that are not final.
  run <- require_lot_run(con, prefix)
  # The windows this run was built with, not this environment's config: a line
  # has to be judged by the window it was made under.
  sc <- stock_cfg(from_run = tryCatch(lot_run_meta(con, prefix),
                                      error = function(e) NULL))
  run_id <- paste0("stock_", format(Sys.time(), "%Y%m%d%H%M%S"))

  lines  <- wrk(paste0(prefix, "LOT_LONG_FINAL"))
  maps   <- wrk(paste0(prefix, "MAP_STACKED"))
  # The claim dates. Without them a fill absorbed into an open episode is
  # indistinguishable from leftover cover, which is the whole split - so this
  # stops rather than reporting every carried agent as passive.
  claims <- wrk(paste0(prefix, "MMA_MED_PROCESSED"))
  if (!isTRUE(tryCatch({ db_q(con, glue("SELECT 1 FROM {claims} LIMIT 1")); TRUE },
                       error = function(e) FALSE)))
    stop("Cannot read ", claims, ". It carries DATE_SERVICE, which is the only ",
         "way to tell a real refill absorbed into an open episode from leftover ",
         "cover. Without it every carried agent would be reported as passive.",
         call. = FALSE)
  ag    <- wrk(paste0(prefix, "STOCKPILE_AGENTS"))
  im    <- wrk(paste0(prefix, "STOCKPILE_IMPACT"))
  bl    <- wrk(paste0(prefix, "STOCKPILE_BY_LOT"))
  bm    <- wrk(paste0(prefix, "STOCKPILE_BY_MED"))

  cat("\nMeasuring against LOT run ", run$run, " on ", lines, "\n", sep = "")
  cat("Windows from the run: LOT1 ", sc$ind1, "d, CAR-T ", sc$cart, "d, other ",
      sc$indn, "d.\n", sep = "")
  db_exec(con, glue("CREATE OR REPLACE TABLE {ag} AS {
    stock_agents_sql(lines, maps, claims, sc, run_id, run$run, run$stamp)}"))
  db_exec(con, glue("CREATE OR REPLACE TABLE {im} AS {stock_impact_sql(ag)}"))
  db_exec(con, glue("CREATE OR REPLACE TABLE {bl} AS {stock_by_lot_sql(im, lines)}"))
  db_exec(con, glue("CREATE OR REPLACE TABLE {bm} AS {stock_by_med_sql(ag)}"))

  tot <- db_q(con, glue("
    SELECT count(*) AS n_lines, count(DISTINCT PATID) AS n_pat,
           sum(N_AGENTS_ADDED) AS n_agents,
           sum(WOULD_EXTEND_RUNOUT) AS n_extend,
           sum(WOULD_REMOVE_ADD_MED) AS n_rm_add,
           sum(HAS_REAL_FILL_IN_WINDOW) AS n_real
    FROM {im}"))
  cat("\nWhat a coverage rule would change:\n")
  cat("  ", num0(tot$n_lines), " lines in ", num0(tot$n_pat),
      " patients gain at least one agent.\n", sep = "")
  cat("  ", num0(tot$n_agents), " agent-line pairs added in total.\n", sep = "")
  cat("  ", num0(tot$n_extend), " of those lines would also run out later, ",
      "because the added\n      agent's cover outlasts what the line ran out on.\n",
      sep = "")
  cat("  ", num0(tot$n_rm_add), " would lose their MED_ADD boundary, because the ",
      "agent that\n      ended them would be in the regimen instead.\n", sep = "")
  cat("\nAnd the split that decides whether this is settled:\n")
  cat("  ", num0(tot$n_real), " of those lines have a REAL claim inside the window ",
      "that an open\n      episode absorbed. The patient was still filling the ",
      "drug, so the\n      study team's reason for excluding leftover cover ",
      "does not cover them.\n", sep = "")
  passive <- if (length(tot$n_lines) && length(tot$n_real) &&
                 !is.na(tot$n_lines[1]) && !is.na(tot$n_real[1]))
               tot$n_lines[1] - tot$n_real[1] else NA
  cat("  ", num0(passive), " are leftover cover only - the case the study team ",
      "settled.\n", sep = "")

  b <- db_q(con, glue("SELECT * FROM {bl}"))
  cat("\nBy line:\n")
  cat(sprintf("  %-5s %9s %9s %10s %9s %9s %9s %10s\n",
              "LOT", "lines", "affected", "% affected", "patients", "extend",
              "-MED_ADD", "real fill"))
  for (i in seq_len(nrow(b)))
    cat(sprintf("  %-5s %9s %9s %9s%% %9s %9s %9s %10s\n",
                b$LOT_NUM[i], num0(b$N_LINES[i]), num0(b$N_LINES_AFFECTED[i]),
                format(b$PCT_LINES_AFFECTED[i]), num0(b$N_PATIENTS_AFFECTED[i]),
                num0(b$N_WOULD_EXTEND[i]), num0(b$N_WOULD_REMOVE_ADD[i]),
                num0(b$N_WITH_REAL_FILL[i])))
  l1 <- b$N_LINES_AFFECTED[b$LOT_NUM == 1]
  if (length(l1) && !is.na(l1) && l1 > 0)
    cat("\n  WARNING: LOT1 shows ", num0(l1), " affected lines. LOT1 starts at the\n",
        "  patient's first non-steroid MM agent, so nothing should precede it. ",
        "Check\n  the line table before reading anything else here.\n", sep = "")

  m <- db_q(con, glue("SELECT * FROM {bm}"))
  if (nrow(m)) {
    cat("\nBy agent, the ones that carry:\n")
    cat(sprintf("  %-10s %9s %9s %11s %9s\n",
                "agent", "lines", "patients", "whole wdw", "med days"))
    for (i in seq_len(min(nrow(m), 15L)))
      cat(sprintf("  %-10s %9s %9s %11s %9s\n",
                  m$MED_ABBR[i], num0(m$N_LINES[i]), num0(m$N_PATIENTS[i]),
                  num0(m$N_COVERS_WHOLE_WINDOW[i]), format(m$MEDIAN_DAYS_COVERED[i])))
    if (nrow(m) > 15L) cat("  ... ", nrow(m) - 15L, " more in ", bm, "\n", sep = "")
  }

  cat("\nThese are regimen changes and the two boundary effects that follow from\n",
      "them. They are NOT a resulting line count. An added agent is a base agent,\n",
      "so it changes when the line runs out and what may end it, and every later\n",
      "line moves with that. An exact line structure needs an alternate build.\n",
      sep = "")
  recheck_lot_attempt(con, prefix, run, "STOCKPILE")
  cat("\nWrote ", ag, ", ", im, ", ", bl, " and ", bm, ".\n", sep = "")
}

main()
