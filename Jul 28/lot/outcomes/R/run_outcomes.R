# The runner. Resolves which LOT run owns the tables, refuses anything it
# cannot vouch for, then writes the five tables.
#
# Nothing here is waivable except by name. This package reads a finished run
# and does arithmetic on it; if the run cannot be identified there is no
# reading of these numbers that is worth having. Where the lineage cannot be
# PROVEN rather than shown wrong - no cohort status table, no recorded attempt,
# an attempt recorded without a stamp - the run stops and names
# OUT_ALLOW_UNPROVEN_LINEAGE, so an operator accepts it deliberately and the log
# records that they did. It used to carry on and log, which made "we could not
# check" and "we checked and it matched" the same outcome.

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
find_subsequent_cohorts <- function(con, lot_run, lines = c(2L, 3L),
                                    attempt = NULL) {
  out <- list(); stale <- character(0); prov <- list()
  for (n in lines) {
    t <- coh_tbl(paste0("NDMM_COHORT_", n, "L"))
    d <- tryCatch(db_q(con, glue("SELECT * FROM {t} LIMIT 1")), error = function(e) NULL)
    if (is.null(d) || !nrow(d)) next
    at <- function(nm) {
      i <- match(toupper(nm), toupper(names(d)))
      if (is.na(i)) NA_character_ else trimws(as.character(d[[i]][1]))
    }
    src <- at("SOURCE_LOT_RUN_ID")
    # An older table predates the column. Not current by omission: it cannot
    # say which run it came from, so it cannot be shown to belong to this one.
    # as.character() strips anything riding along on either side. identical()
    # is the right comparison for text and the wrong one for text wearing an
    # attribute, and this function is handed a run id from a caller it does not
    # control.
    want <- as.character(trimws(lot_run))
    if (is.na(src) || !nzchar(src) || !identical(src, want)) {
      stale <- c(stale, paste0(t, if (is.na(src)) " (records no source LOT run)"
                                  else paste0(" (built from LOT run ", src, ")")))
      next
    }
    out[[as.character(n)]] <- t
    prov[[as.character(n)]] <- c(
      subseq = at("SUBSEQ_RUN_ID"), pre = at("CE_PRE_DAYS"), fu = at("CE_FU_DAYS"),
      coh = at("SOURCE_COHORT_RUN_ID"), stamp = at("SOURCE_COHORT_STAMP"))
  }
  if (length(stale))
    stop("These line cohorts were not built from LOT run ", lot_run, ": ",
         paste(stale, collapse = "; "), ". Their patients would set ",
         "LINE_ELIGIBLE on lines they are not about, and every output would ",
         "still carry this run's ids - so nothing downstream would catch it. ",
         "Re-run ndmm/build_subsequent_cohorts.R against this LOT run, or ",
         "unset them to report ALL_LINES alone.", call. = FALSE)
  # Naming the same LOT run is not the same as being the same build. The
  # subsequent build stamps five things onto these tables and only one of them
  # was read, which left two ways to get a wrong denominator that carried every
  # id correctly:
  #
  #   a partial re-run - 2L from one subsequent build and 3L from another, both
  #   pointing at this LOT run, so LINE_ELIGIBLE means one thing on one line
  #   and another on the next;
  #
  #   a sensitivity build - the same tables under overridden continuous
  #   enrolment windows, which become the ordinary LINE_ELIGIBLE denominator
  #   with nothing in the output to say the window moved.
  #
  # Both are checked here, and the windows are logged rather than assumed, so a
  # non-default one is visible instead of silent.
  if (length(prov)) {
    agree <- function(k, what) {
      v <- vapply(prov, function(p) p[[k]], character(1))
      if (any(is.na(v) | !nzchar(v)))
        return(out_unproven(paste0("Line cohort(s) ",
                                   paste(names(prov)[is.na(v) | !nzchar(v)],
                                         collapse = ", "),
                                   "L record no ", what, ".")))
      if (length(unique(v)) > 1L)
        stop("The line cohorts disagree on ", what, ": ",
             paste0(names(prov), "L=", v, collapse = ", "),
             ". They are not one build, so LINE_ELIGIBLE means a different ",
             "thing on each line and every output would still carry this ",
             "run's ids. Re-run ndmm/build_subsequent_cohorts.R.", call. = FALSE)
      invisible(v[[1]])
    }
    agree("subseq", "which subsequent-cohort run built them")
    coh   <- agree("coh",   "which cohort attempt they were built over")
    stamp <- agree("stamp", "the stamp of that cohort attempt")
    agree("pre",    "the continuous-enrolment window before the line")
    agree("fu",     "the continuous-enrolment window after it")
    # Agreeing with each other is not the same as belonging to the lines. Both
    # tables can consistently describe cohort attempt B while the lines were
    # built over attempt A, and this package reads the tables it is given
    # rather than assuming how they were made - so the agreed value is held
    # against the attempt the LOT run actually read.
    if (!is.null(attempt) && length(attempt) == 2L && !any(is.na(attempt))) {
      if (!identical(coh, attempt[["run"]]) ||
          !identical(stamp, attempt[["stamp"]]))
        stop("The line cohorts were built over cohort attempt ", coh, " (",
             stamp, "), and the LOT lines over ", attempt[["run"]], " (",
             attempt[["stamp"]], "). LINE_ELIGIBLE would restrict this run's ",
             "lines by a population from another attempt of the cohort - and ",
             "every output would still carry this run's ids, so nothing ",
             "downstream would catch it. Re-run ",
             "ndmm/build_subsequent_cohorts.R against this LOT run.",
             call. = FALSE)
    } else {
      out_unproven(paste0("The cohort attempt behind the LOT run was not ",
                          "established, so the line cohorts' attempt ", coh,
                          " cannot be shown to be the same one."))
    }
    p1 <- prov[[1]]
    log_msg("  Line cohorts from subsequent run ", p1[["subseq"]],
            ", continuous enrolment ", p1[["pre"]], "d before and ",
            p1[["fu"]], "d after the line, over cohort attempt ",
            p1[["coh"]], " (", p1[["stamp"]], ").")
  }
  if (!length(out))
    log_msg("  No line-specific cohorts (", coh_tbl("NDMM_COHORT_2L"),
            " and friends), so every result is over the 1L cohort's lines.")
  else
    log_msg("  Line-specific denominators from ", paste(unlist(out), collapse = ", "),
            ", both built from LOT run ", lot_run, ".")
  # Named, not attached. The provenance is one row - every line cohort agrees
  # on it by the time we get here - or NULL when there are no line cohorts at
  # all, which the SQL builders read as "no LINE_ELIGIBLE, so no window to
  # record".
  list(tables = out, provenance = if (length(prov)) prov[[1]] else NULL)
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
  # Whether the column is there at all, which is a different question from what
  # it says. Every check below used to read a blank the same way it read a
  # match - `!is.na(x) && nzchar(x) && x != want` passes when x is missing - so
  # a status row that recorded nothing proved everything.
  has <- function(nm) !is.na(match(toupper(nm), toupper(names(d))))
  said <- function(nm) { v <- pick(nm); !is.na(v) && nzchar(trimws(v)) }
  st <- tolower(trimws(pick("STATE")))
  if (!identical(st, "complete"))
    stop("The last LOT run on prefix '", prefix, "' (", pick("RUN_ID"),
         ") is marked '", st, "'. It replaces LOT_LONG_FINAL before it ",
         "validates it, so those lines may be an unfinished run's.",
         call. = FALSE)
  want <- toupper(trimws(cohort_table))
  got  <- sub("^.*\\.", "", toupper(trimws(pick("INPUT_COHORT_TABLE"))))
  if (!said("INPUT_COHORT_TABLE"))
    out_unproven(paste0(tbl, " records no INPUT_COHORT_TABLE for run ",
                        pick("RUN_ID"), ", so the lines cannot be shown to ",
                        "belong to ", cohort_table, "."))
  else if (!identical(got, want))
    stop("That LOT run was built from '", pick("INPUT_COHORT_TABLE"),
         "', not from ", cohort_table, ". The outcomes would be measured on ",
         "lines belonging to another population.", call. = FALSE)
  # Blank and absent differ here and the difference is the whole check. A blank
  # CONTRACT_DEVIATIONS is a positive statement - the run used the contract
  # algorithm - and is what every production run writes. A MISSING column says
  # nothing, and was being read as the blank.
  # Three states, and the third was being read as the second. The engine always
  # writes CONTRACT_DEVIATIONS as a quoted string, so a contract build writes
  # '' - NULL is not something a build produces. It is what the in-place column
  # upgrade leaves on rows that predate the column, which turns "the column is
  # missing" into "the column is present and says nothing" and walks past the
  # check written for exactly that case. An empty string is a statement; a NULL
  # is the absence of one, and only the first proves a contract build.
  dev <- pick("CONTRACT_DEVIATIONS")
  if (!has("CONTRACT_DEVIATIONS"))
    out_unproven(paste0(tbl, " has no CONTRACT_DEVIATIONS column, so this run ",
                        "cannot be shown to have used the contract algorithm ",
                        "rather than a sensitivity sweep's."))
  else if (is.na(dev))
    out_unproven(paste0(tbl, " has a CONTRACT_DEVIATIONS column that is NULL ",
                        "for run ", pick("RUN_ID"), ". Every build writes it, ",
                        "so a NULL is a row from before the column existed - ",
                        "it does not say the contract algorithm was used."))
  else if (nzchar(trimws(dev)))
    stop("That LOT run was built with LOT_CONTRACT_OVERRIDE (", dev,
         "), so its lines are an alternative algorithm's.", call. = FALSE)
  # The attrition split is decided by the study end, and this package holds its
  # own copy of it. lot writes the window it ran to onto the status row for
  # exactly this reason, so ask rather than assume: an unchecked copy silently
  # scores every still-treated patient as lost to follow-up when it runs long.
  se  <- trimws(pick("STUDY_END"))
  ask <- trimws(as.character(study_end))
  if (!said("STUDY_END"))
    out_unproven(paste0(tbl, " records no STUDY_END for run ", pick("RUN_ID"),
                        ", so this package's ", ask, " cannot be shown to be ",
                        "the window the lines were built to."))
  else if (!identical(se, ask))
    stop("That LOT run was built to STUDY_END ", se, " and this package is ",
         "set to ", ask, ". The attrition split reads the study end to tell a ",
         "patient who disenrolled from one the study stopped observing, so ",
         "the two have to be the same window.", call. = FALSE)
  log_msg("LOT run ", pick("RUN_ID"), " completed over ",
          pick("INPUT_COHORT_TABLE"))
  attempt <- check_cohort_attempt(con, pick("RUN_ID"))
  # Two named fields, not a run id with something hidden on it. An attributed
  # character is not the string it prints as: trimws() is sub(), sub() returns
  # "the same attributes as x", and identical() compares attributes - so
  # identical("L1", trimws(lot_run)) was FALSE for the same eight characters,
  # and every valid 2L/3L cohort was reported as built from another run. The
  # runner unpacks this into a plain character before anything compares it.
  list(run = as.character(pick("RUN_ID")), attempt = attempt)
}

# The cohort table's name matching is not the same as its contents matching.
# Re-running the cohort build under the same prefix replaces the cohort, the
# enrollment spans and NDMM_BASE_COHORT in place, and the name is unchanged - so
# outcomes would measure lines built over attempt A using death, enrolment and
# diagnosis dates from attempt B. LOT records which attempt it read, so ask.
#
# The same shape as ndmm/R/build_subsequent.R, and for the same reason - now
# including how it ends. This used to log the three cases below and carry on,
# which is the failure the header of this file says it refuses: outcomes
# measured against a population the lines are not about, written into tables
# that look ordinary and carry this run's OUT_RUN_ID. Nothing downstream could
# tell them from proven ones, because nothing downstream is told.
#
# So an unproven lineage is now accepted by name or not at all. The name is on
# the record in the log, which is the point: "we could not check" and "we
# checked and it matched" stop being the same outcome.
out_unproven <- function(what) {
  if (identical(toupper(trimws(Sys.getenv("OUT_ALLOW_UNPROVEN_LINEAGE",
                                          unset = ""))), "TRUE")) {
    log_msg("UNPROVEN LINEAGE ACCEPTED: ", what)
    return(invisible(FALSE))
  }
  stop(what, " The lines' lineage cannot be proven, and outcomes measured over ",
       "mixed vintages look exactly like right ones. ",
       "OUT_ALLOW_UNPROVEN_LINEAGE=TRUE accepts that, on the record.",
       call. = FALSE)
}

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
  # in build_lot.R). Asking only for the ndmm one would find nothing on an
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
  if (is.null(d))
    return(out_unproven(paste0("No cohort build status under ",
                               coh_tbl("NDMM_BUILD_STATUS"), " or ",
                               coh_tbl("build_status"),
                               " - the cohort attempt cannot be compared.")))
  now_id <- at(d, "RUN_ID"); now_stamp <- at(d, "UPDATED_AT")
  if (is.na(lot_cohort) || !nzchar(trimws(lot_cohort)))
    return(out_unproven(paste0(meta, " records no cohort attempt for run ",
                               lot_run_id, ", so it cannot be compared to ",
                               "cohort run ", now_id, ".")))
  eq <- function(a, b) {
    a <- trimws(as.character(a)); b <- trimws(as.character(b))
    length(a) == 1L && length(b) == 1L && !is.na(a) && !is.na(b) && identical(a, b)
  }
  # A blank stamp used to count as a match. Two attempts can reuse a run id -
  # that is exactly what the stamp is for - so a blank one does not prove the
  # attempt, it fails to speak about it.
  if (eq(lot_cohort, now_id) && (is.na(lot_stamp) || !nzchar(trimws(lot_stamp))))
    return(out_unproven(paste0(meta, " records cohort run ", lot_cohort,
                               " with no stamp, so a second attempt under the ",
                               "same run id cannot be told from the one the ",
                               "lines were built over.")))
  if (!(eq(lot_cohort, now_id) && eq(lot_stamp, now_stamp)))
    stop("The LOT lines were built over cohort run ", lot_cohort, " (", lot_stamp,
         "), but ", tbl, " now holds run ", now_id, " (", now_stamp,
         "). The follow-up ends, death dates and diagnosis dates on disk are a ",
         "later attempt than the lines, so every outcome would be measured ",
         "against a population the lines are not about. Re-run the LOT build.",
         call. = FALSE)
  log_msg("  Cohort attempt ", now_id, " matches the one the LOT run read.")
  # Returned, not just checked. The 2L/3L tables record which cohort attempt
  # THEY were built over, and holding those against each other proves they are
  # one build without proving either belongs to the lines. This is the attempt
  # the lines were built over, so find_subsequent_cohorts() can close that.
  invisible(c(run = trimws(as.character(now_id)),
              stamp = trimws(as.character(now_stamp))))
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
  lr      <- check_lot_run(con, cfg$object_prefix, cfg$input_cohort_table,
                           cfg$study_end)
  lot_run <- lr$run

  lines  <- out_tbl("LOT_LONG_FINAL")
  cohort <- wrk(cfg$input_cohort_table)
  base   <- find_base_cohort(con)
  # Two values, returned as two values. This used to come back as one list with
  # the provenance smuggled on an attribute, and the runner then took [[1]] of
  # it unconditionally - so a run with no line cohorts, which is the documented
  # behaviour for the overall cohort and for any NDMM run before
  # build_subsequent_cohorts.R, died with "subscript out of bounds" at the
  # first table. The empty case was tested and the use of the empty case was
  # tested; nothing tested the two together, and the attribute is what let them
  # be written apart.
  sc     <- find_subsequent_cohorts(con, lot_run, attempt = lr$attempt)
  subseq <- sc$tables
  both   <- length(subseq) > 0L
  # The 2L/3L build's provenance, carried onto every table that has a DENOM or
  # a LINE_ELIGIBLE. It travelled only in the log before, which does not
  # outlive the session - so a run under non-default continuous-enrolment
  # windows produced tables indistinguishable from a standard one. NULL where
  # there are no line cohorts, which is what the SQL builders expect.
  sprov  <- sc$provenance
  tte    <- out_tbl("OUT_TTE")

  log_msg("Building ", tte, " - one row per patient per line")
  db_exec(con, glue("CREATE OR REPLACE TABLE {tte} AS {
    outcomes_tte_sql(outcomes_base_sql(lines, cohort, base, subseq),
                     run_id, lot_run, sprov)}"))
  check_lines_in_followup(con, tte, lines, cohort)

  tables <- list(
    list("OUT_ATTRITION", function(t) outcomes_attrition_sql(
                            t, cfg$study_end, run_id, lot_run, both, sprov)),
    list("OUT_LINE_GAP",  function(t) outcomes_line_gap_sql(t, run_id, lot_run, both, sprov)),
    list("OUT_REGIMEN",   function(t) outcomes_regimen_sql(t, run_id, lot_run, both, sprov)))
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
