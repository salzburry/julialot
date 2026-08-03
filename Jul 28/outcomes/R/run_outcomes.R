# The runner. Resolves which LOT run owns the tables, refuses anything it
# cannot vouch for, then writes the four tables.
#
# Nothing here is waivable. This package reads a finished run and does
# arithmetic on it; if the run cannot be identified there is no reading of
# these numbers that is worth having.

# The cohort build's own prefix. One study is one prefix, so it defaults to
# this run's - set it only when the cohort was built under a different one.
coh_tbl <- function(tbl) {
  cfg <- lot_config()
  p <- trimws(cfg$cohort_prefix %||% "")
  full_name(cfg$work_schema, paste0(if (nzchar(p)) p else cfg$object_prefix, tbl))
}

# NDMM_BASE_COHORT is where the MM diagnosis date lives. The cohort table does
# not carry it - its INDEX_DATE is the 1L treatment start - so it is read from
# the checkpoint the cohort build already wrote. Probed rather than assumed: a
# cohort built by another package has no such table, and the diagnosis columns
# are then absent rather than guessed.
find_base_cohort <- function(con) {
  t <- coh_tbl("NDMM_BASE_COHORT")
  ok <- tryCatch({ db_q(con, glue("SELECT MM_DX_DT FROM {t} LIMIT 1")); TRUE },
                 error = function(e) FALSE)
  if (!ok) {
    log_msg("  ", t, " is not readable, so time from diagnosis to 1L is not ",
            "computed. Every other outcome is unaffected.")
    return(NULL)
  }
  log_msg("  MM diagnosis dates from ", t)
  t
}

# The LOT run that last wrote the tables, whatever state it reached - the same
# rule every other reader in this folder uses, and for the same reason: a build
# replaces its outputs before it validates them, so the newest row owns them.
check_lot_run <- function(con, prefix, cohort_table, study_end) {
  tbl <- out_tbl("LOT_BUILD_STATUS")
  d <- tryCatch(db_q(con, glue(
    "SELECT * FROM {tbl} ORDER BY UPDATED_AT DESC LIMIT 1")), error = function(e) NULL)
  if (is.null(d) || !nrow(d))
    stop("No LOT run is recorded in ", tbl, ". These outcomes are measured off ",
         "the lines, so the LOT build has to run first.", call. = FALSE)
  pick <- function(nm) {
    i <- match(toupper(nm), toupper(names(d)))
    if (is.na(i)) NA_character_ else as.character(d[[i]][1])
  }
  st <- tolower(trimws(pick("STATE")))
  if (!identical(st, "complete"))
    stop("The last LOT run on prefix '", prefix, "' (", pick("RUN_ID"),
         ") is marked '", st, "'. It replaces LOT_LONG_FINAL before it ",
         "validates it, so those lines may be an unfinished run's.",
         call. = FALSE)
  want <- toupper(trimws(cohort_table))
  got  <- sub("^.*\\.", "", toupper(trimws(pick("INPUT_COHORT_TABLE"))))
  if (!is.na(got) && nzchar(got) && !identical(got, want))
    stop("That LOT run was built from '", pick("INPUT_COHORT_TABLE"),
         "', not from ", cohort_table, ". The outcomes would be measured on ",
         "lines belonging to another population.", call. = FALSE)
  dev <- pick("CONTRACT_DEVIATIONS")
  if (!is.na(dev) && nzchar(trimws(dev)))
    stop("That LOT run was built with LOT_CONTRACT_OVERRIDE (", dev,
         "), so its lines are an alternative algorithm's.", call. = FALSE)
  # The attrition split is decided by the study end, and this package holds its
  # own copy of it. lot writes the window it ran to onto the status row for
  # exactly this reason, so ask rather than assume: an unchecked copy silently
  # scores every still-treated patient as lost to follow-up when it runs long.
  se  <- trimws(pick("STUDY_END"))
  ask <- trimws(as.character(study_end))
  if (!is.na(se) && nzchar(se) && !identical(se, ask))
    stop("That LOT run was built to STUDY_END ", se, " and this package is ",
         "set to ", ask, ". The attrition split reads the study end to tell a ",
         "patient who disenrolled from one the study stopped observing, so ",
         "the two have to be the same window.", call. = FALSE)
  log_msg("LOT run ", pick("RUN_ID"), " completed over ",
          pick("INPUT_COHORT_TABLE"))
  invisible(TRUE)
}

# Two reasons a line in LOT_LONG_FINAL can be absent from OUT_TTE, and they
# are not the same problem: its patient is not in the cohort at all, or the
# line starts after that patient's follow-up ends. Counted separately, because
# a single "n dropped" would let the first hide behind the second - and the
# first should be impossible, since lot builds its lines from this cohort.
check_lines_in_followup <- function(con, tte_tbl, lines_tbl, cohort_tbl) {
  n <- db_q(con, glue("
    WITH l AS (SELECT cast(PATID as string) AS PATID FROM {lines_tbl}),
         c AS (SELECT cast(PATID as string) AS PATID FROM {cohort_tbl})
    SELECT (SELECT count(*) FROM l)                                  AS n_lines,
           (SELECT count(*) FROM l WHERE PATID NOT IN (SELECT PATID FROM c))
                                                                     AS n_no_cohort,
           (SELECT count(*) FROM {tte_tbl})                          AS n_kept"))
  no_coh <- as.numeric(n$n_no_cohort)
  after  <- as.numeric(n$n_lines) - no_coh - as.numeric(n$n_kept)
  if (no_coh > 0)
    log_msg("  WARNING: ", no_coh, " line(s) belong to a patient who is not in ",
            cohort_tbl, ". lot builds its lines from this cohort, so this ",
            "should be zero.")
  if (after > 0)
    log_msg("  ", after, " line(s) start after their patient's follow-up end ",
            "and are not in ", tte_tbl, ".")
  if (no_coh == 0 && after == 0)
    log_msg("  Every line belongs to a cohort patient and starts inside their ",
            "follow-up.")
  invisible(c(no_cohort = no_coh, after_followup = after))
}

build_outcomes <- function(here, cohort_table, prefix) {
  cfg <- pin_output_schema(cfg_defaults)
  cfg <- pin_cohort(cfg, cohort_table, prefix)
  set_lot_config(cfg)

  stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")
  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  log_msg(SEP)
  log_msg("Treatment patterns and treatment-related outcomes (protocol Table 4)")
  log_msg("  cohort ", cfg$input_cohort_table, ", LOT prefix ", cfg$object_prefix)
  log_msg("  run ", run_id)
  log_msg(SEP)
  check_lot_run(con, cfg$object_prefix, cfg$input_cohort_table, cfg$study_end)

  lines  <- out_tbl("LOT_LONG_FINAL")
  cohort <- wrk(cfg$input_cohort_table)
  base   <- find_base_cohort(con)
  tte    <- out_tbl("OUT_TTE")

  log_msg("Building ", tte, " - one row per patient per line")
  db_exec(con, glue("CREATE OR REPLACE TABLE {tte} AS {
    outcomes_tte_sql(outcomes_base_sql(lines, cohort, base), run_id)}"))
  check_lines_in_followup(con, tte, lines, cohort)

  tables <- list(list("OUT_ATTRITION",
                      function(t) outcomes_attrition_sql(t, cfg$study_end)),
                 list("OUT_LINE_GAP",  outcomes_line_gap_sql),
                 list("OUT_REGIMEN",   outcomes_regimen_sql))
  if (!is.null(base))
    tables <- c(tables, list(list("OUT_DX_TO_LOT1", outcomes_dx_to_lot1_sql)))
  for (p in tables) {
    t <- out_tbl(p[[1]])
    db_exec(con, glue("CREATE OR REPLACE TABLE {t} AS {p[[2]](tte)}"))
    log_msg("Wrote ", t)
  }

  # What the run produced, on the log, so a failure to write is not the first
  # anyone hears of a number being wrong.
  s <- db_q(con, glue("
    SELECT LOT_NUM, count(*) AS n,
           sum(TTNT_EVENT) AS ttnt_ev, sum(TTD_EVENT) AS ttd_ev,
           sum(OS_EVENT) AS os_ev
    FROM {tte} GROUP BY LOT_NUM ORDER BY LOT_NUM"))
  log_msg(DASH)
  for (i in seq_len(nrow(s)))
    log_msg("  LOT ", s$LOT_NUM[i], ": ", s$n[i], " patients; events - TTNT ",
            s$ttnt_ev[i], ", TTD ", s$ttd_ev[i], ", OS ", s$os_ev[i])
  log_msg(DASH)
  log_msg("Every table is stamped OUT_RUN_ID = ", run_id)
  log_msg(SEP)
  invisible(TRUE)
}

# The schema and the cohort/prefix pair, pinned the way every other package in
# this folder pins them, so a wrong prefix is a stopped run rather than a wrong
# study.
pin_output_schema <- function(cfg) {
  schema <- Sys.getenv("PROJECT_WORK_SCHEMA",
              unset = Sys.getenv("DOMINO_USER_NAME",
                unset = Sys.getenv("DOMINO_STARTING_USERNAME", unset = "")))
  if (!nzchar(schema))
    stop("No output schema. Set DOMINO_USER_NAME to your personal schema, ",
         "or PROJECT_WORK_SCHEMA to override.", call. = FALSE)
  if (!grepl("^[A-Za-z_][A-Za-z0-9_]*$", schema))
    stop("Output schema '", schema, "' is not a schema name.", call. = FALSE)
  cfg$work_schema <- schema
  cfg
}

pin_cohort <- function(cfg, cohort_table, prefix) {
  cohort_table <- trimws(as.character(cohort_table %||% ""))
  prefix       <- trimws(as.character(prefix %||% ""))
  if (!nzchar(cohort_table) || !nzchar(prefix))
    stop("Outcomes needs a cohort table and the LOT run's prefix.\n",
         "  Rscript build.R <COHORT_TABLE> <lot_prefix_>\n",
         "  or set INPUT_COHORT_TABLE and OBJECT_PREFIX.", call. = FALSE)
  if (!grepl("^[A-Za-z_][A-Za-z0-9_]*$", cohort_table))
    stop("Cohort table '", cohort_table, "' is not a table name. Give the ",
         "table only - the catalog and schema come from the settings.",
         call. = FALSE)
  if (!grepl("^[A-Za-z][A-Za-z0-9_]*_$", prefix))
    stop("Prefix '", prefix, "' should be a name ending in '_', e.g. ndmm_.",
         call. = FALSE)
  cfg$input_cohort_table <- cohort_table
  cfg$object_prefix      <- prefix
  cfg
}

`%||%` <- function(a, b) if (is.null(a)) b else a
