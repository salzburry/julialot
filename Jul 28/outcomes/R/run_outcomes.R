# The runner. Resolves which LOT run owns the tables, refuses anything it
# cannot vouch for, then writes the five tables.
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

# The line-specific eligibility cohorts, if the cohort build wrote them, and if
# they still belong beside the lines being measured.
#
# Readable is not the same as current. Re-running LOT leaves the 2L/3L tables on
# disk untouched and perfectly readable, and eligibility from the old run would
# then be stamped onto the new run's lines - with every output correctly carrying
# this run's ids, so no stamp check could catch it. ALL_LINES would stay right
# and LINE_ELIGIBLE would be quietly wrong.
#
# The subsequent build records which LOT run it drew from. Ask, and drop a
# cohort that names a different one rather than restricting on it.
find_subsequent_cohorts <- function(con, lot_run, lines = c(2L, 3L)) {
  out <- list(); stale <- character(0)
  for (n in lines) {
    t <- coh_tbl(paste0("NDMM_COHORT_", n, "L"))
    d <- tryCatch(db_q(con, glue("SELECT * FROM {t} LIMIT 1")), error = function(e) NULL)
    if (is.null(d) || !nrow(d)) next
    i <- match("SOURCE_LOT_RUN_ID", toupper(names(d)))
    src <- if (is.na(i)) NA_character_ else trimws(as.character(d[[i]][1]))
    # An older table predates the column. Not current by omission: it cannot
    # say which run it came from, so it cannot be shown to belong to this one.
    if (is.na(i) || is.na(src) || !nzchar(src) || !identical(src, trimws(lot_run))) {
      stale <- c(stale, paste0(t, if (is.na(i)) " (records no source LOT run)"
                                  else paste0(" (built from LOT run ", src, ")")))
      next
    }
    out[[as.character(n)]] <- t
  }
  if (length(stale))
    stop("These line cohorts were not built from LOT run ", lot_run, ": ",
         paste(stale, collapse = "; "), ". Their patients would set ",
         "LINE_ELIGIBLE on lines they are not about, and every output would ",
         "still carry this run's ids - so nothing downstream would catch it. ",
         "Re-run nndm/build_subsequent_cohorts.R against this LOT run, or ",
         "unset them to report ALL_LINES alone.", call. = FALSE)
  if (!length(out))
    log_msg("  No line-specific cohorts (", coh_tbl("NDMM_COHORT_2L"),
            " and friends), so every result is over the 1L cohort's lines.")
  else
    log_msg("  Line-specific denominators from ", paste(unlist(out), collapse = ", "),
            ", both built from LOT run ", lot_run, ".")
  out
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
  check_cohort_attempt(con, pick("RUN_ID"))
  invisible(pick("RUN_ID"))
}

# The cohort table's name matching is not the same as its contents matching.
# Re-running the cohort build under the same prefix replaces the cohort, the
# enrollment spans and NDMM_BASE_COHORT in place, and the name is unchanged - so
# outcomes would measure lines built over attempt A using death, enrolment and
# diagnosis dates from attempt B. LOT records which attempt it read, so ask.
#
# The same shape as nndm/R/build_subsequent.R, and for the same reason.
check_cohort_attempt <- function(con, lot_run_id) {
  meta <- out_tbl("LOT_RUN_METADATA")
  m <- tryCatch(db_q(con, glue(
    "SELECT * FROM {meta} WHERE RUN_ID = {sql_text(lot_run_id)} LIMIT 1")),
    error = function(e) NULL)
  # A run that reached "complete" always wrote this row, so its absence is not
  # an old-run allowance - something is wrong with what is on disk.
  if (is.null(m) || !nrow(m))
    stop("LOT run ", lot_run_id, " is marked complete but has no row in ", meta,
         ", so there is no record of which cohort attempt its lines were ",
         "built over.", call. = FALSE)
  at <- function(d, nm) {
    i <- match(toupper(nm), toupper(names(d)))
    if (is.na(i)) NA_character_ else as.character(d[[i]][1])
  }
  lot_cohort <- at(m, "COHORT_RUN_ID"); lot_stamp <- at(m, "COHORT_STAMP")
  # Both names the cohort builds use, as lot resolves them (COHORT_STATUS_TABLES
  # in build_lot.R). Asking only for the nndm one would find nothing on an
  # overall cohort and report the attempt as uncomparable, which reads as "no
  # such record" when the record is there under the other name.
  tbl <- NULL; d <- NULL
  for (nm in c("NDMM_BUILD_STATUS", "build_status")) {
    t <- coh_tbl(nm)
    r <- tryCatch(db_q(con, glue(
      "SELECT * FROM {t} ORDER BY UPDATED_AT DESC LIMIT 1")), error = function(e) NULL)
    if (!is.null(r) && nrow(r)) { tbl <- t; d <- r; break }
  }
  # Nothing recorded is nothing to compare, and saying so is honest. A cohort
  # built by another package has no such table.
  if (is.null(d)) {
    log_msg("  No cohort build status under ", coh_tbl("NDMM_BUILD_STATUS"),
            " or ", coh_tbl("build_status"),
            " - the cohort attempt cannot be compared.")
    return(invisible(FALSE))
  }
  now_id <- at(d, "RUN_ID"); now_stamp <- at(d, "UPDATED_AT")
  if (is.na(lot_cohort) || !nzchar(trimws(lot_cohort))) {
    log_msg("  ", meta, " records no cohort attempt for run ", lot_run_id,
            ", so it cannot be compared to cohort run ", now_id, ".")
    return(invisible(FALSE))
  }
  eq <- function(a, b) {
    a <- trimws(as.character(a)); b <- trimws(as.character(b))
    length(a) == 1L && length(b) == 1L && !is.na(a) && !is.na(b) && identical(a, b)
  }
  if (!(eq(lot_cohort, now_id) &&
        (is.na(lot_stamp) || !nzchar(trimws(lot_stamp)) || eq(lot_stamp, now_stamp))))
    stop("The LOT lines were built over cohort run ", lot_cohort, " (", lot_stamp,
         "), but ", tbl, " now holds run ", now_id, " (", now_stamp,
         "). The follow-up ends, death dates and diagnosis dates on disk are a ",
         "later attempt than the lines, so every outcome would be measured ",
         "against a population the lines are not about. Re-run the LOT build.",
         call. = FALSE)
  log_msg("  Cohort attempt ", now_id, " matches the one the LOT run read.")
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

# A table left behind by an earlier run is a mismatch rather than a silent mix.
# Asked of the tables themselves: a log line saying they are stamped is not
# evidence that they are.
# Both ids: which outcomes run wrote the table, and which LOT run supplied the
# lines. Checking only the first would accept a table stamped by this run whose
# lines came from a different one.
check_stamps <- function(con, run_id, lot_run, tbls, tte) {
  bad <- character(0)
  for (t in c(tte, tbls)) {
    n <- tryCatch(as.numeric(db_q(con, glue(
      "SELECT count(*) AS n FROM {t}
        WHERE OUT_RUN_ID IS NULL OR OUT_RUN_ID <> {sql_text(run_id)}
           OR LOT_RUN_ID IS NULL OR LOT_RUN_ID <> {sql_text(lot_run)}"))$n),
      error = function(e) NA_real_)
    if (is.na(n)) bad <- c(bad, paste0(t, " (cannot be read)"))
    else if (n > 0) bad <- c(bad, paste0(t, " (", n, " rows from another run)"))
  }
  if (length(bad))
    stop("These outputs are not this run's: ", paste(bad, collapse = "; "),
         ". They are read together, so a mix of runs is not a partial answer ",
         "- it is a wrong one. Re-run the build.", call. = FALSE)
  log_msg("  All ", length(tbls) + 1L, " outputs carry OUT_RUN_ID ", run_id,
          " over LOT run ", lot_run)
  invisible(TRUE)
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
  lot_run <- check_lot_run(con, cfg$object_prefix, cfg$input_cohort_table,
                           cfg$study_end)

  lines  <- out_tbl("LOT_LONG_FINAL")
  cohort <- wrk(cfg$input_cohort_table)
  base   <- find_base_cohort(con)
  subseq <- find_subsequent_cohorts(con, lot_run)
  both   <- length(subseq) > 0L
  tte    <- out_tbl("OUT_TTE")

  log_msg("Building ", tte, " - one row per patient per line")
  db_exec(con, glue("CREATE OR REPLACE TABLE {tte} AS {
    outcomes_tte_sql(outcomes_base_sql(lines, cohort, base, subseq),
                     run_id, lot_run)}"))
  check_lines_in_followup(con, tte, lines, cohort)

  tables <- list(
    list("OUT_ATTRITION", function(t) outcomes_attrition_sql(
                            t, cfg$study_end, run_id, lot_run, both)),
    list("OUT_LINE_GAP",  function(t) outcomes_line_gap_sql(t, run_id, lot_run, both)),
    list("OUT_REGIMEN",   function(t) outcomes_regimen_sql(t, run_id, lot_run, both)))
  if (!is.null(base))
    tables <- c(tables, list(list("OUT_DX_TO_LOT1",
      function(t) outcomes_dx_to_lot1_sql(t, run_id, lot_run))))
  for (p in tables) {
    t <- out_tbl(p[[1]])
    db_exec(con, glue("CREATE OR REPLACE TABLE {t} AS {p[[2]](tte)}"))
    log_msg("Wrote ", t)
  }
  # OUT_DX_TO_LOT1 is the one optional output, and an optional output is the one
  # that can be left behind: a run without a readable base cohort writes the
  # other four and would leave an earlier run's diagnosis table beside them,
  # unstamped by this run and outside the check below. Dropped rather than
  # stamped - there is no diagnosis date to put in it.
  if (is.null(base)) {
    d1 <- out_tbl("OUT_DX_TO_LOT1")
    db_exec(con, glue("DROP TABLE IF EXISTS {d1}"))
    log_msg("  ", d1, " dropped - this run has no MM diagnosis date to put in it.")
  }
  # Every table written, so the stamps agree. A run that died between them
  # leaves an OUT_TTE from this run beside summaries from the last one, and
  # OUT_RUN_ID is what says so - which is why it goes on all of them and is
  # checked here rather than asserted in the log.
  check_stamps(con, run_id, lot_run,
               vapply(tables, function(p) out_tbl(p[[1]]), character(1)), tte)

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
  log_msg("Lines from LOT run ", lot_run, "; every output stamped OUT_RUN_ID ",
          run_id)
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
