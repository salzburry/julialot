#!/usr/bin/env Rscript
# Extract named patients' LOT INPUTS from a finished run, so their real rows
# can be replayed through the engine off the warehouse.
#
#   # list what it would do; no connection
#   Rscript lot/qc/extract_patients.R
#
#   # run it
#   DATABRICKS_PWD=... DOMINO_USER_NAME=usr00000 OBJECT_PREFIX=ndmm_ \
#     EXTRACT_PATIDS=33062938660,33007568794 \
#     EXTRACT_EXECUTE=TRUE Rscript lot/qc/extract_patients.R
#
# Reads only. Writes out/extract/*.csv.
#
# Why it exists. When a run's lines look wrong for a patient, the question is
# whether the ENGINE is wrong or whether the patient's shape is not the shape
# anyone reasoned about. A hand-built patient answers the first question about
# a hand-built patient and nothing about the real one. This writes out exactly
# the seven inputs the engine reads, so the real rows can be put through the
# real rules and the answer compared with what the run produced.
#
# The seven, all under OBJECT_PREFIX:
#   LOT_PATIENT_INPUT     the patient's index, observation end and death
#   MAP_STACKED           every supply episode, with its class, count and
#                         discontinuation flag
#   TX_AUTO_DATES         the finalized AUTO transplant dates
#   TX_ALLO_CART_DATES    ALLO and CAR-T dates
#   PERMISSIBLE_SUBS      the substitution pairs (whole table; it is small)
#   MED_UNIVERSE          every (drug, class) the RUN saw, not just these
#                         patients - the engine emits one flag column per
#                         member, so a short list is a different build
#   LOT_LONG_FINAL        what the run decided, to compare a replay against
#
# and RUN_PIN.csv: the run id, its code hash, its contract settings and the
# stamp, so a replay can say which build it is replaying.
#
#   EXTRACT_PATIDS      comma-separated ids. Required.
#   EXTRACT_MASK_PATID  FALSE to write real ids. TRUE by default, unlike the
#                       traces: those stay on the platform and this file is
#                       written to be carried off it. Masking is the same
#                       last-six rule the traces use, applied to every file
#                       at once, so the rows still join to each other and to
#                       a trace written with TRACE_MASK_PATID=TRUE.
#   EXTRACT_DIR         where to write (default out/extract beside this file)
#   QC_ALLOW_DEVIATION  TRUE extracts from a run that deviated from the
#                       contract.
#
# Exit status is 0 when the files were written, 1 when something stopped it.

.script_dir <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                            fixed = TRUE))) else getwd()
})
source(file.path(.script_dir, "R", "checks.R"))
source(file.path(.script_dir, "R", "foldin_trace.R"))

LOT_ROOT <- normalizePath(file.path(.script_dir, "..", "engine"), mustWork = TRUE)
env_flag <- function(nm, dflt = FALSE) {
  v <- toupper(trimws(Sys.getenv(nm, unset = "")))
  if (!nzchar(v)) dflt else identical(v, "TRUE")
}
out_dir <- function() {
  d <- trimws(Sys.getenv("EXTRACT_DIR", unset = ""))
  if (nzchar(d)) d else file.path(.script_dir, "out", "extract")
}
extract_patids <- function() {
  raw <- trimws(Sys.getenv("EXTRACT_PATIDS", unset = ""))
  if (!nzchar(raw))
    stop("No EXTRACT_PATIDS. This extracts named patients, so without a list ",
         "there is nothing to extract.", call. = FALSE)
  foldin_trace_check_patids(strsplit(raw, ",", fixed = TRUE)[[1]])
}

report_plan <- function() {
  cat("\nExtract a run's LOT inputs for named patients.\n\n")
  listed <- tryCatch(extract_patids(), error = function(e) {
    cat("  EXTRACT_PATIDS refused: ", conditionMessage(e), "\n", sep = ""); NULL })
  cat("  reads   LOT_PATIENT_INPUT, MAP_STACKED, TX_AUTO_DATES,\n",
      "          TX_ALLO_CART_DATES, PERMISSIBLE_SUBS, LOT_LONG_FINAL,\n",
      "          LOT_RUN_METADATA and LOT_BUILD_STATUS under OBJECT_PREFIX\n",
      "  writes  ", out_dir(), "/*.csv\n", sep = "")
  cat("  patients ",
      if (is.null(listed)) "none named yet"
      else paste0(length(listed), ": ", paste(listed, collapse = ", ")), "\n", sep = "")
  cat("  ids     ", if (env_flag("EXTRACT_MASK_PATID", TRUE))
                      "masked to the last six characters (EXTRACT_MASK_PATID=FALSE writes them whole)"
                    else "written whole (EXTRACT_MASK_PATID=FALSE)", "\n", sep = "")
}

main <- function() {
  report_plan()
  if (!env_flag("EXTRACT_EXECUTE")) {
    cat("\nNothing was read. Set EXTRACT_EXECUTE=TRUE to run it.\n")
    return(invisible(NULL))
  }
  options(scipen = 999)
  library(DBI); library(odbc); library(glue)
  source(file.path(LOT_ROOT, "R", "load_inputs.R"))
  load_pipeline_inputs(LOT_ROOT, "config.csv")
  for (f in c("config_lot.R", "db_utils_lot.R")) source(file.path(LOT_ROOT, "R", f))
  cfg <- get("cfg_defaults", envir = globalenv())

  schema <- Sys.getenv("PROJECT_WORK_SCHEMA",
              unset = Sys.getenv("DOMINO_USER_NAME",
                unset = Sys.getenv("DOMINO_STARTING_USERNAME", unset = "")))
  if (!nzchar(schema))
    stop("No work schema. Set DOMINO_USER_NAME to the schema the build wrote ",
         "into, or PROJECT_WORK_SCHEMA to override.", call. = FALSE)
  cfg$work_schema <- schema
  pfx <- trimws(Sys.getenv("OBJECT_PREFIX", unset = ""))
  if (!nzchar(pfx))
    stop("No OBJECT_PREFIX. It is what names the run's tables, so without it ",
         "this would read whatever unprefixed tables exist.", call. = FALSE)
  if (!grepl("^[A-Za-z][A-Za-z0-9_]*_$", pfx))
    stop("OBJECT_PREFIX '", pfx, "' should be a name ending in '_'.", call. = FALSE)
  cfg$object_prefix <- pfx

  patids <- extract_patids()
  masked <- env_flag("EXTRACT_MASK_PATID", TRUE)
  dir <- out_dir()
  dir.create(dir, showWarnings = FALSE, recursive = TRUE)

  set_lot_config(cfg)
  stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")
  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  ids <- foldin_trace_in_list(patids)

  st <- db_q(con, glue("
    SELECT RUN_ID, STATE, UPDATED_AT, CONTRACT_DEVIATIONS
    FROM {lot_out('LOT_BUILD_STATUS')} ORDER BY UPDATED_AT DESC LIMIT 1"))
  if (!nrow(st))
    stop("No row in ", lot_out("LOT_BUILD_STATUS"), ", so there is no run to ",
         "extract from under prefix '", pfx, "'.", call. = FALSE)
  if (!identical(as.character(st$STATE[1]), "complete"))
    stop("The run owning this prefix is '", st$STATE[1], "', not complete.",
         call. = FALSE)
  devs <- trimws(as.character(st$CONTRACT_DEVIATIONS[1] %||% ""))
  if (nzchar(devs) && !identical(devs, "none") && !env_flag("QC_ALLOW_DEVIATION"))
    stop("The run deviated from the contract (", devs, "). Extracting from it ",
         "would replay a build nobody agreed to. Set QC_ALLOW_DEVIATION=TRUE ",
         "to do it anyway.", call. = FALSE)

  # The run's own record of what built it. A replay that cannot name the build
  # it is replaying is a replay of something.
  meta <- db_q(con, glue("SELECT * FROM {lot_out('LOT_RUN_METADATA')}"))

  # Every drug and class the RUN saw, not only these patients'. The emitted
  # build carries one flag column per member of the universe, so extracting
  # the patients' own drugs alone would replay a narrower build than the one
  # that produced the lines being explained.
  universe <- db_q(con, glue("
    SELECT DISTINCT cast(MAP_MED_TYPE as string) AS MAP_MED_TYPE,
           cast(MAP_MED_CLASS as string) AS MAP_MED_CLASS
    FROM {lot_out('MAP_STACKED')} ORDER BY 1, 2"))

  want <- list(
    lot_patient_input = glue("
      SELECT cast(PATID as string) AS PATID, cast(INDEX_DATE as date) AS INDEX_DATE,
             cast(ENDDATE as date) AS ENDDATE, cast(ENDDATE_CE as date) AS ENDDATE_CE,
             cast(OBS_END_DT as date) AS OBS_END_DT, cast(DEATH_DT as date) AS DEATH_DT,
             cast(GDR_CD as string) AS GDR_CD, cast(YRDOB as int) AS YRDOB,
             cast(AGE_INDEX_YR as int) AS AGE_INDEX_YR
      FROM {lot_out('LOT_PATIENT_INPUT')}
      WHERE cast(PATID as string) IN {ids} ORDER BY PATID"),
    map_stacked = glue("
      SELECT cast(PATID as string) AS PATID, cast(MAP_MED_TYPE as string) AS MAP_MED_TYPE,
             cast(MAP_MED_CLASS as string) AS MAP_MED_CLASS, cast(MAP_CNT as int) AS MAP_CNT,
             cast(MAP_START_DT as date) AS MAP_START_DT, cast(MAP_END_DT as date) AS MAP_END_DT,
             cast(MAP_DISCON_FLG as int) AS MAP_DISCON_FLG
      FROM {lot_out('MAP_STACKED')}
      WHERE cast(PATID as string) IN {ids} ORDER BY PATID, MAP_START_DT, MAP_MED_TYPE"),
    tx_auto_dates = glue("
      SELECT cast(PATID as string) AS PATID, cast(TX_SEQ as int) AS TX_SEQ,
             cast(TX_DT as date) AS TX_DT
      FROM {lot_out('TX_AUTO_DATES')}
      WHERE cast(PATID as string) IN {ids} ORDER BY PATID, TX_DT"),
    tx_allo_cart_dates = glue("
      SELECT cast(PATID as string) AS PATID, cast(SCT_TYPE as string) AS SCT_TYPE,
             cast(TX_SEQ as int) AS TX_SEQ, cast(TX_DT as date) AS TX_DT
      FROM {lot_out('TX_ALLO_CART_DATES')}
      WHERE cast(PATID as string) IN {ids} ORDER BY PATID, TX_DT"),
    lot_long_final = glue("
      SELECT * FROM {lot_out('LOT_LONG_FINAL')}
      WHERE cast(PATID as string) IN {ids} ORDER BY PATID, LOT_NUM"))

  # Read one at a time. A UNION of these over ODBC is what segfaulted the
  # driver in the fold-in trace; there is no reason to build one here.
  got <- lapply(want, function(sql) db_q(con, sql))
  got$permissible_subs <- db_q(con, glue("SELECT * FROM {lot_out('PERMISSIBLE_SUBS')}"))
  got$med_universe <- universe
  got$run_pin <- data.frame(
    RUN_ID = as.character(st$RUN_ID[1]),
    UPDATED_AT = as.character(st$UPDATED_AT[1]),
    CONTRACT_DEVIATIONS = if (nzchar(devs)) devs else "none",
    OBJECT_PREFIX = pfx,
    stringsAsFactors = FALSE)
  for (cn in c("CODE_MD5", "CONTRACT_SETTINGS", "STUDY_START", "STUDY_END"))
    if (cn %in% names(meta)) got$run_pin[[cn]] <- as.character(meta[[cn]][1])

  # Mask everywhere or nowhere. Masking one file and not another is how the
  # rows stop joining to each other.
  if (masked)
    got <- lapply(got, function(d) {
      if ("PATID" %in% names(d)) d$PATID <- mask_patid_r(d$PATID)
      d
    })

  for (nm in names(got)) {
    f <- file.path(dir, paste0(nm, ".csv"))
    utils::write.csv(got[[nm]], f, row.names = FALSE, na = "")
    cat("  wrote ", f, "  (", nrow(got[[nm]]), " rows)\n", sep = "")
  }
  have <- unique(as.character(got$lot_patient_input$PATID))
  want_ids <- if (masked) mask_patid_r(patids) else patids
  absent <- setdiff(want_ids, have)
  if (length(absent))
    cat("\n  NOT IN THE RUN: ", paste(absent, collapse = ", "),
        "\n  (they are not in LOT_PATIENT_INPUT under this prefix, so the run ",
        "never saw them)\n", sep = "")
  cat("\nRun ", got$run_pin$RUN_ID[1], " (", got$run_pin$UPDATED_AT[1], ")",
      if (!is.null(got$run_pin$CODE_MD5)) paste0(", code ", got$run_pin$CODE_MD5) else "",
      "\n", sep = "")
  invisible(NULL)
}

main()
