#!/usr/bin/env Rscript
# How a line of therapy is created, scenario by scenario, and how many patients
# each rule decides.
#
#   # the scenarios and what the engine does with them; no connection
#   Rscript exploration/lot/run_lot_scenarios.R
#
#   # add the real-data counts and write the workbook
#   DATABRICKS_PWD=... DOMINO_USER_NAME=usr00000 OBJECT_PREFIX=ndmm_ \
#     SCENARIO_EXECUTE=TRUE Rscript exploration/lot/run_lot_scenarios.R
#
# Read-only. Every statement is a SELECT; nothing is written to the warehouse.
#
# Output: out/lot_scenarios.xlsx. How a line is built, the scenarios in plain
# words with the same patient in days beside them, the patient counts by line
# number, what every code in the output table means, and the open questions
# still waiting on the study team. Without openxlsx the same sheets come out
# as CSVs, named after the workbook they stand in for.
#
# Without SCENARIO_EXECUTE the preview goes to out/lot_scenarios_reference.xlsx
# instead - no counts, no connection - so it never overwrites the counted
# workbook.
#
# The lines in each scenario are not predictions. Each one was produced by
# running the engine's own SQL over that patient, and the synthetic harness
# beside this delivery re-runs them all and fails if any line moves.

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
source(file.path(.script_dir, "R", "lot_scenarios.R"))

# How a line gets built, in the order the engine does it. Sheet one, because
# every scenario below is one of these steps landing a day either side of a
# threshold.
HOW_A_LINE_IS_BUILT <- data.frame(
  STEP = 1:8,
  WHAT_HAPPENS = c(
    "The first line starts",
    "The line's drugs are decided",
    "How long those drugs cover the patient",
    "What could end the line",
    "The line ends",
    "Stopping treatment has to be confirmed",
    "The next line starts",
    "Counting stops"),
  IN_PLAIN_WORDS = c(
    "On the day of the patient's first myeloma drug. Steroids do not count.",
    paste0("Any myeloma drug the patient STARTS in the first 60 days. For ",
           "later lines it is the first 30 days, or 45 days if the line was ",
           "started by CAR-T. A drug the patient was already on, and simply ",
           "keeps refilling, does not count as started."),
    paste0("Each drug's supply is followed forward from the day the line ",
           "began. The line is covered until the last supply runs out. If the ",
           "patient goes 90 days or more with no supply of that drug, the ",
           "following runs stop there."),
    paste0("A new drug being added, a transplant, CAR-T therapy, the patient ",
           "dying, the drugs running out, or the data ending."),
    paste0("On whichever of those comes first, with one exception: where ",
           "treatment stopped, the stop was confirmed, and the patient later ",
           "died with nothing in between, the line is recorded as ending at ",
           "the death (open question Q3, scenario S15). Same-day ties: when a ",
           "transplant and a drug would START the next line on the same day, ",
           "a donor transplant wins, then CAR-T, then a stem cell transplant, ",
           "then a drug. When two transplant types would END a line on the ",
           "same day, the first line breaks the tie in a different order from ",
           "later lines - open question Q4."),
    paste0("Running out of drugs only counts as stopping treatment once ",
           "either 90 days of follow-up have passed with nothing else, or the ",
           "patient starts something that would begin the next line. Until ",
           "then the line is recorded as running to the end of the data."),
    paste0("On whichever comes first: a drug that was not on this line, one ",
           "of this line's own drugs coming back after a confirmed 90-day ",
           "break, a stem cell transplant no line has claimed, CAR-T therapy, ",
           "or a donor transplant. It has to be after the previous line ",
           "ended."),
    paste0("After 5 lines. Anything the patient is given after that is not ",
           "counted into a line.")),
  stringsAsFactors = FALSE)

fmt_block <- function(v) if (!length(v)) "" else paste(v, collapse = "\n")

# The rules that still need a decision from the study team. The code applies
# each one on every run; what is open is whether it is the right rule. Each
# points at the scenario that shows it and the count that sizes it.
OPEN_QUESTIONS <- data.frame(
  ID = c("Q1", "Q2", "Q3", "Q4"),
  THE_QUESTION = c(
    paste0("Should a drug the patient is still taking count as part of the ",
           "new line, even though they started it in an earlier line?"),
    paste0("Is three months without a fill a treatment decision, or a ",
           "paperwork artefact - a long holiday, a change of pharmacy ",
           "benefit, a stockpile?"),
    paste0("When treatment stops, the stop is confirmed, and the patient ",
           "later dies with nothing in between - should the line end at the ",
           "stop, with the death kept as the patient outcome it already is?"),
    paste0("When two transplant types would end a line on the same day, which ",
           "one is recorded as the reason? The first line and later lines ",
           "answer differently.")),
  WHAT_THE_CODE_DOES_TODAY = c(
    paste0("A drug counts only if the patient STARTS it in the line's first ",
           "60 days (30 for later lines, 45 after CAR-T). A drug carried ",
           "over from the last line and refilled without a break never ",
           "counts."),
    paste0("A break of 90 days or more in one drug's supply counts as ",
           "stopping it. Under 90 days the line carries on through the gap. ",
           "When the drug that comes back is one the current line was built ",
           "on, one day either side turns one line into two - S05 and S06. ",
           "A drug from an older line opens a new line at any gap."),
    paste0("The line is recorded as ending at the death. The date treatment ",
           "stopped is still on the row, so the other reading is recoverable ",
           "without a rebuild."),
    paste0("On the first line a stem cell transplant wins the tie, then a ",
           "donor transplant, then CAR-T. On later lines a donor transplant ",
           "wins, then CAR-T, then a stem cell transplant. The end DATE is ",
           "identical either way; only the recorded reason differs, and only ",
           "on an exact same-day tie.")),
  WHAT_A_CHANGE_WOULD_MOVE = c(
    paste0("The drug lists on later lines. Line starts and line counts, ",
           "because a drug missing from a line's list is free to start the ",
           "next one. Line lengths."),
    paste0("Where lines end and how many there are, for every patient whose ",
           "refill gap sits near the threshold."),
    paste0("Line lengths, time to discontinuation, and the died/stopped ",
           "split. Not line counts."),
    paste0("Only the recorded end reason on exact-tie days, and any summary ",
           "split by end reason. No dates and no line counts.")),
  SEE_SCENARIO = c("S09", "S05 and S06", "S15",
                   "none - two transplants on one day is rarer than any worked case here"),
  THE_COUNT_THAT_SIZES_IT = c(
    paste0("4.2-prior-agent-covered-but-not-in-the-regimen and ",
           "4.3-line-started-by-an-agent-from-two-lines-back, in ",
           "run_scenario_counts.R"),
    "return-gap-around-the-90-day-threshold, in run_lot_audit_counts.R",
    "the S15 row of the Patients-by-line sheet",
    "no count yet - same-day transplant-type ties would need their own query"),
  stringsAsFactors = FALSE)

# The codes the output table uses, in words. The scenarios are readable without
# it; the table they describe is not.
WHAT_THE_CODES_MEAN <- data.frame(
  COLUMN = c(rep("LOT_START_TYPE", 4), rep("LOT_BASE_END_REASON", 8),
             "LOT_BASE_MEDS", "LOT_BASE_DISCON_DT", "LOT_NUM"),
  CODE = c("MED", "SCT_AUTO", "CART", "SCT_ALLO",
           "MED_ADD", "DISCONTINUATION", "SCT_AUTO", "SCT_AUTO_CONT",
           "SCT_CART", "CART_INIT", "SCT_ALLO", "DEATH",
           "(a list of drugs)", "(a date, or blank)", "(1 to 5)"),
  IN_PLAIN_WORDS = c(
    "The line started because the patient started a drug.",
    "The line started on a stem cell transplant.",
    "The line started on CAR-T therapy.",
    "The line started on a donor transplant.",
    "The line ended because the patient started a drug that was not on it.",
    "The line ended because the drugs ran out, and the stop was confirmed.",
    "The line ended the day before a stem cell transplant.",
    paste0("The line was held open to a transplant it owns and ended ON the ",
           "transplant date - a planned second transplant, or a single ",
           "in-window transplant landing after the drugs ran out. Unlike the ",
           "other transplant ends, which close the line the day BEFORE the ",
           "event."),
    "The line ended the day before CAR-T therapy.",
    paste0("The line ended on CAR-T therapy that followed a drug added in ",
           "the 45 days before it."),
    "The line ended the day before a donor transplant.",
    "The line ended because the patient died.",
    paste0("The drugs the patient started in the line's first 60 days (30 ",
           "for later lines, 45 after CAR-T). Blank for a donor-transplant ",
           "line, which carries no drugs."),
    paste0("The day the patient's treatment on this line ran out, where ",
           "that was confirmed. Blank where it was not."),
    "Which line this is. Counting stops at 5."),
  stringsAsFactors = FALSE)

# Plain words first, then the same thing in the algorithm's own terms. A
# reader who only wants the answer stops after column five.
scenario_frame <- function() do.call(rbind, lapply(LOT_SCENARIOS, function(s)
  data.frame(ID = s$id, TOPIC = s$group,
             WHAT_HAPPENS_TO_THE_PATIENT = s$story,
             WHAT_THE_ALGORITHM_DOES     = s$outcome,
             HOW_MANY_LINES              = length(s$lines),
             THE_SAME_PATIENT_IN_DAYS    = fmt_block(s$timeline),
             THE_LINES_IT_BUILDS         = fmt_block(s$lines),
             IN_TECHNICAL_TERMS          = s$note,
             RULE                        = s$rule,
             stringsAsFactors = FALSE)))

report_plan <- function() {
  cat("\nHow a line of therapy is created, and how many patients each rule decides.\n\n")
  cat("Read-only: every statement is a SELECT. Nothing is written to the warehouse.\n")
  for (st in seq_len(nrow(HOW_A_LINE_IS_BUILT))) {
    cat("\n  ", HOW_A_LINE_IS_BUILT$STEP[st], ". ",
        HOW_A_LINE_IS_BUILT$WHAT_HAPPENS[st], "\n", sep = "")
    for (l in strwrap(HOW_A_LINE_IS_BUILT$IN_PLAIN_WORDS[st], width = 68))
      cat("       ", l, "\n", sep = "")
  }
  wrap <- function(txt, ind) {
    for (l in strwrap(txt, width = 74 - ind)) cat(strrep(" ", ind), l, "\n", sep = "")
  }
  grp <- ""
  for (s in LOT_SCENARIOS) {
    if (!identical(s$group, grp)) { grp <- s$group; cat("\n\n== ", grp, " ==\n", sep = "") }
    cat("\n  ", s$id, "  ", s$title, "\n\n", sep = "")
    wrap(s$story, 6)
    cat("\n")
    wrap(s$outcome, 6)
    cat("\n      the same patient, in days:\n")
    for (l in s$timeline) cat("        ", l, "\n", sep = "")
    cat("      the lines, as the output table records them:\n")
    for (l in s$lines)    cat("        ", l, "\n", sep = "")
  }
  cat("\n\n", length(LOT_SCENARIOS), " scenarios, ",
      sum(vapply(LOT_SCENARIOS, function(s) !is.null(s$sql), logical(1))),
      " with a count.", sep = "")
  if (env_flag("SCENARIO_EXECUTE")) {
    cat(" Counting them now.\n\n")
  } else {
    cat(" Set SCENARIO_EXECUTE=TRUE to count them.\n")
    cat("Needs DATABRICKS_PWD, DOMINO_USER_NAME (or PROJECT_WORK_SCHEMA) and\n")
    cat("OBJECT_PREFIX.\n\n")
  }
}

# One sheet per frame where openxlsx is there, one CSV each where it is not.
# The workbook is the deliverable and the CSVs are the fallback, so a machine
# without the package still produces every number.
write_workbook <- function(sheets, path) {
  if (requireNamespace("openxlsx", quietly = TRUE)) {
    wb <- openxlsx::createWorkbook()
    for (nm in names(sheets)) {
      openxlsx::addWorksheet(wb, nm)
      openxlsx::writeData(wb, nm, sheets[[nm]])
      openxlsx::setColWidths(wb, nm, cols = seq_along(sheets[[nm]]),
                             widths = "auto")
      openxlsx::freezePane(wb, nm, firstRow = TRUE)
      openxlsx::addStyle(wb, nm, openxlsx::createStyle(wrapText = TRUE, valign = "top"),
                         rows = 2:(nrow(sheets[[nm]]) + 1),
                         cols = seq_along(sheets[[nm]]), gridExpand = TRUE)
    }
    openxlsx::saveWorkbook(wb, path, overwrite = TRUE)
    cat("Wrote ", path, "\n", sep = "")
    return(invisible(path))
  }
  cat("openxlsx is not installed - writing CSVs instead of the workbook.\n")
  for (nm in names(sheets)) {
    f <- file.path(dirname(path),
                   paste0(sub("\\.xlsx$", "", basename(path)), "_",
                          gsub("[^A-Za-z0-9]+", "_", tolower(nm)), ".csv"))
    utils::write.csv(sheets[[nm]], f, row.names = FALSE)
    cat("Wrote ", f, "\n", sep = "")
  }
  invisible(NULL)
}

main <- function() {
  report_plan()
  dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
  scen <- scenario_frame()

  if (!env_flag("SCENARIO_EXECUTE")) {
    write_workbook(list("How a line is built" = HOW_A_LINE_IS_BUILT,
                        "Scenarios"           = scen,
                        "Open questions"      = OPEN_QUESTIONS,
                        "What the codes mean"  = WHAT_THE_CODES_MEAN),
                   file.path(out_dir, "lot_scenarios_reference.xlsx"))
    return(invisible(0L))
  }

  library(DBI); library(odbc); library(glue)
  source(file.path(LOT_ROOT, "R", "load_inputs.R"))
  load_pipeline_inputs(LOT_ROOT, "config.csv")
  for (f in c("config_lot.R", "db_utils_lot.R")) source(file.path(LOT_ROOT, "R", f))
  source(file.path(.script_dir, "R", "run_binding.R"))

  # cfg_defaults, not lot_config(): config_lot.R defines cfg_defaults when it is
  # sourced, and lot_config() reads the config set_lot_config() installs, which
  # has not happened until the schema and prefix below are folded in.
  cfg <- get("cfg_defaults", envir = globalenv())
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
  stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")

  which_tbl <- trimws(Sys.getenv("AUDIT_TABLE", unset = "LOT_LONG"))
  if (!which_tbl %in% c("LOT_LONG_FINAL", "LOT_LONG"))
    stop("AUDIT_TABLE must be LOT_LONG_FINAL or LOT_LONG.", call. = FALSE)

  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  # Which run wrote these tables, and whether it finished as the contract
  # algorithm. Readable tables are not enough: a failed rebuild leaves lines
  # that read perfectly, and a contract-override sensitivity cell is a
  # different algorithm whose counts are not this study's.
  run <- require_lot_run(con, pfx)
  meta <- lot_run_meta(con, pfx)

  # The settings the counts are cut on come from the measured RUN's own
  # contract record, not from this session's config. A workbook built a month
  # later, with a different config beside it, still counts the run under the
  # thresholds the run was built with. Local config is only the fallback for a
  # run too old to have recorded a value, and the provenance sheet says which
  # was used.
  run_setting <- function(key, fallback) {
    v <- lot_run_contract(con, pfx, key)
    if (is.null(v) || is.na(v) || !nzchar(trimws(v))) fallback
    else as.integer(trimws(v))
  }
  lot1_window <- run_setting("induction_window_days",       cfg$induction_window_days)
  lotn_window <- run_setting("lot_n_induction_window_days", cfg$lot_n_induction_window_days)
  cart_days   <- run_setting("cart_consolidation_days",     cfg$cart_consolidation_days)
  tandem_days <- run_setting("sct_tandem_days",             cfg$sct_tandem_days)
  max_lot     <- run_setting("max_lot",                     cfg$max_lot)
  discon_days <- run_setting("map_discon_gap_days",         cfg$map_discon_gap_days)
  t <- list(long = lot_out(which_tbl), map  = lot_out("MAP_STACKED"),
            sct  = lot_out("LOT1_SCT"), auto = lot_out("TX_AUTO_DATES"),
            allo = lot_out("TX_ALLO_CART_DATES"))

  cat("Counting against:\n")
  for (nm in names(t)) cat("  ", nm, ": ", t[[nm]], "\n", sep = "")
  cat("  run ", run$run, " / attempt ", run$stamp, " / cohort ", run$cohort,
      "\n\n", sep = "")

  # What the numbers describe, on its own sheet, so the workbook carries its
  # own provenance instead of borrowing this session's.
  PROVENANCE <- data.frame(
    FIELD = c("LOT run id", "Run attempt (UPDATED_AT)", "Input cohort table",
              "Study end", "Object prefix", "Line table counted",
              "Cohort run id / stamp", "Contract settings (as recorded)",
              "Contract deviations", "Windows used by the counts",
              "Read at"),
    VALUE = c(as.character(run$run), as.character(run$stamp),
              as.character(run$cohort), as.character(run$study_end),
              pfx, which_tbl,
              if (is.null(meta)) "(no metadata row - a run predating it)"
              else paste0(meta$cohort_run, " / ", meta$cohort_at),
              if (is.null(meta) || is.na(meta$settings))
                "(not recorded - session config used as fallback)"
              else as.character(meta$settings),
              "(none - require_lot_run refuses a deviating run)",
              paste0("lot1=", lot1_window, "d lotn=", lotn_window,
                     "d cart=", cart_days, "d tandem=", tandem_days,
                     "d discon=", discon_days, "d max_lot=", max_lot),
              format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z")),
    stringsAsFactors = FALSE)

  # Each count says what it measures. Most are the RULE's population - every
  # patient the rule decides - which is wider than the worked drugs and days.
  # The catalogue's count_of states it per scenario, and it travels on every
  # row, so a zero reads as "nobody in the rule's population" and never as
  # "the worked example cannot happen".
  rows <- list(); failed <- 0L
  row_of <- function(s, lot, n, note) data.frame(
    ID = s$id, WHAT_HAPPENS_TO_THE_PATIENT = s$story,
    WHAT_THE_COUNT_MEASURES = s$count_of %||% s$sql_note %||% "",
    LOT_NUM = lot, N_PATIENTS = n, NOTE = note, stringsAsFactors = FALSE)
  for (s in LOT_SCENARIOS) {
    if (is.null(s$sql)) {
      rows[[length(rows) + 1L]] <-
        row_of(s, NA_integer_, NA_integer_,
               s$sql_note %||% "no count for this shape")
      next
    }
    cat("== ", s$id, "  ", s$title, "\n", sep = "")
    res <- tryCatch(DBI::dbGetQuery(con, glue(s$sql, .open = "{", .close = "}")),
                    error = function(e) e)
    if (inherits(res, "error")) {
      failed <- failed + 1L
      cat("   FAILED: ", conditionMessage(res), "\n", sep = "")
      rows[[length(rows) + 1L]] <-
        row_of(s, NA_integer_, NA_integer_,
               paste("query failed:", substr(conditionMessage(res), 1, 200)))
      next
    }
    if (!nrow(res)) {
      cat("   zero - nobody in this count's population\n")
      rows[[length(rows) + 1L]] <-
        row_of(s, NA_integer_, 0L, "zero - nobody in this count's population")
      next
    }
    print(res, row.names = FALSE)
    rows[[length(rows) + 1L]] <-
      row_of(s, as.integer(res$LOT_NUM), as.integer(res$N_PATIENTS), "")
  }
  counts <- do.call(rbind, rows)

  # The tables must still be the attempt the counts started on, or the sheet
  # mixes two builds and nothing on it says so.
  recheck_lot_attempt(con, pfx, run, "scenario count")

  write_workbook(list("What these numbers describe" = PROVENANCE,
                      "How a line is built" = HOW_A_LINE_IS_BUILT,
                      "Scenarios"           = scen,
                      "Patients by line"    = counts,
                      "Open questions"      = OPEN_QUESTIONS,
                      "What the codes mean" = WHAT_THE_CODES_MEAN),
                 file.path(out_dir, "lot_scenarios.xlsx"))
  if (failed) {
    cat(failed, " count(s) failed - see the messages above.\n", sep = "")
    return(invisible(1L))
  }
  invisible(0L)
}

`%||%` <- function(a, b) if (is.null(a)) b else a
if (!interactive()) quit(status = main())
