# Shared setup for the question scripts in this folder.
#
# They read what the cohort and LOT builds wrote, so they use the lot package's
# own modules rather than a second copy - one definition of cdm_src(), the
# code-list loaders and the naming helpers.

# Order matters. config_lot.R builds cfg_defaults out of environment variables
# at the moment it is sourced, so config.csv has to be loaded FIRST or every
# setting silently falls back to its hardcoded default and these scripts
# describe a run configured differently from the one they are reading. The
# build loads them in this order for the same reason.
`%||%` <- function(a, b) if (is.null(a)) b else a

qs_setup <- function(script_dir) {
  lot_root <- normalizePath(file.path(script_dir, "..", "lot"), mustWork = TRUE)
  lot_r    <- file.path(lot_root, "R")

  source(file.path(lot_r, "load_inputs.R"))
  load_pipeline_inputs(lot_root, "config.csv")
  for (f in c("config_lot.R", "db_utils_lot.R", "codelists_lot.R",
              "line_criteria.R"))
    source(file.path(lot_r, f))

  cfg <- get("cfg_defaults", envir = globalenv())

  schema <- Sys.getenv("PROJECT_WORK_SCHEMA",
              unset = Sys.getenv("DOMINO_USER_NAME",
                unset = Sys.getenv("DOMINO_STARTING_USERNAME", unset = "")))
  if (!nzchar(schema))
    stop("No work schema. Set DOMINO_USER_NAME to the schema the builds wrote ",
         "into, or PROJECT_WORK_SCHEMA to override.", call. = FALSE)
  if (!grepl("^[A-Za-z_][A-Za-z0-9_]*$", schema))
    stop("Work schema '", schema, "' is not a schema name.", call. = FALSE)
  cfg$work_schema <- schema

  # The prefix says WHICH run these answers are about, and every table below is
  # named with it. Blank would silently ask for unprefixed tables - which
  # usually do not exist, but if some older ones do, these scripts would read
  # them and give a confident answer about the wrong study. So it is required,
  # and a run that genuinely had no prefix has to say so.
  pfx <- trimws(Sys.getenv("OBJECT_PREFIX", unset = ""))
  if (!nzchar(pfx) &&
      !identical(toupper(Sys.getenv("QS_ALLOW_NO_PREFIX", unset = "")), "TRUE"))
    stop("No OBJECT_PREFIX. These scripts read one run's tables and the prefix ",
         "is what names them, so a blank prefix asks for unprefixed tables and ",
         "would answer about whatever happens to be there. Set OBJECT_PREFIX to ",
         "the prefix that run used, or QS_ALLOW_NO_PREFIX=TRUE if it truly had ",
         "none.", call. = FALSE)
  if (nzchar(pfx) && !grepl("^[A-Za-z][A-Za-z0-9_]*_$", pfx))
    stop("OBJECT_PREFIX '", pfx, "' should be a name ending in '_', e.g. ndmm_.",
         call. = FALSE)
  cfg$object_prefix <- pfx

  # Several questions read the cohort table for observation windows, index
  # dates and the raw-claim bounds. config_lot.R defaults it to "", which
  # resolves to a name that is only the schema - so those sections would warn
  # and carry on with unbounded examples rather than stopping. Required here.
  #
  # The WHOLE physical name, prefix included, because that is how LOT takes it:
  # the cohort is named by whoever built it, so wrk() adds nothing.
  ct <- trimws(cfg$input_cohort_table %||% "")
  if (!nzchar(ct))
    stop("No INPUT_COHORT_TABLE. Several questions read the cohort for its ",
         "observation windows and index dates, and without it they would skip ",
         "or run unbounded. Give the whole table name including the prefix, ",
         "e.g. ", pfx, "NDMM_COHORT.", call. = FALSE)
  if (!grepl("^[A-Za-z_][A-Za-z0-9_]*$", ct))
    stop("INPUT_COHORT_TABLE '", ct, "' is not a table name. Give the table ",
         "only - the catalog and schema come from the settings.", call. = FALSE)
  cfg$input_cohort_table <- ct

  set_lot_config(cfg)
  invisible(cfg)
}

# Which ICD family a raw claim's flag names, the way the cohort builds decide
# it: ICD9 for the ICD-9 spellings, ICD10 for the ICD-10 ones, NULL for
# anything else - blank, missing, or a spelling nobody expected.
#
# NOT "not ICD-9, therefore ICD-10". That reads a genuine ICD-9 claim with a
# missing flag as ICD-10, and it then fails the family join silently, so a
# question can count a diagnosis the cohort build deliberately did not. NULL
# matches neither family, which is the honest answer for a row whose family is
# unknown. The CDM's values cannot be corrected the way a code list can.
#
# It matters because raw_icd_flag is a WAIVABLE check in the cohort build: a
# run can legitimately carry unrecognised flags, and then the two rules
# disagree on exactly those claims.
#
# The lists live in nndm/R/codelists.R, which this package cannot source - it
# defines its own load_codelist_csv() and would replace lot's. So they are
# repeated here and tests/test_setup.R fails if the two ever differ.
QS_RAW_ICD9  <- c("9", "ICD9", "ICD-9")
QS_RAW_ICD10 <- c("10", "ICD10", "ICD-10")
qs_icd_family_sql <- function(col, nine = "ICD9", ten = "ICD10") {
  q <- function(v) paste(sprintf("'%s'", v), collapse = ", ")
  paste0("CASE WHEN upper(trim(", col, ")) IN (", q(QS_RAW_ICD9), ") THEN '", nine, "'",
         " WHEN upper(trim(", col, ")) IN (", q(QS_RAW_ICD10), ") THEN '", ten, "'",
         " ELSE NULL END")
}

# A prefixed output table, from either build.
#
# NOT wrk(). In this package wrk() resolves catalog.schema.table with no
# prefix - the cohort table is named by whoever built it, so the caller passes
# the whole name. Every table these scripts read is a build's own output and
# carries that build's prefix: LOT_LONG and MAP_STACKED from lot,
# NDMM_FLAGS_ALL from the cohort build, which share a prefix when one study is
# built under one prefix. A table written by a DIFFERENT build carries that
# build's prefix instead and is named for itself - see qs_trial_flags().
#
# Using wrk() here asks for the unprefixed name. That usually fails to find a
# table, which is survivable - but if an unprefixed table from some older run
# is sitting in the schema it succeeds, and the answer is about a different
# study with nothing to say so.
qs_tbl <- function(tbl) lot_out(tbl)

# Which population a question runs over.
#
# The old switch was between two COHORTS - the full LOT run and an NDMM-filtered
# copy of it persisted alongside. That arrangement is gone: the LOT run is over
# the NDMM cohort already, so its output under this prefix IS the study
# population, and a different cohort is a different prefix.
#
# What is still a real choice is BEFORE or AFTER the line criteria, within one
# run. LOT_LONG_FINAL is the study population; LOT_LONG is the same run before
# a truncating criterion removed anyone, which is worth looking at when the
# question is what a criterion cost.
#
# FINAL is the default because that is what ships. Reporting a denominator off
# LOT_LONG while calling it the cohort would count patients the study excluded.
qs_population <- function() {
  old <- Sys.getenv("LOT_COHORT", unset = "")
  if (nzchar(old))
    stop("LOT_COHORT is no longer read. It chose between the full LOT run and a ",
         "separate NDMM-filtered table, and that table is not produced any more - ",
         "the LOT run is over the cohort, so its output is the study population. ",
         "Use LOT_POPULATION=FINAL (the study population, the default) or ",
         "LOT_POPULATION=PRECRITERIA (the same run before the line criteria).",
         call. = FALSE)
  mode <- toupper(trimws(Sys.getenv("LOT_POPULATION", unset = "FINAL")))
  if (!mode %in% c("FINAL", "PRECRITERIA"))
    stop("LOT_POPULATION='", mode, "' is not a population. Use FINAL or ",
         "PRECRITERIA.", call. = FALSE)
  if (identical(mode, "FINAL"))
    list(mode = mode, table = qs_tbl("LOT_LONG_FINAL"),
         label = "study population, after the line criteria")
  else
    list(mode = mode, table = qs_tbl("LOT_LONG"),
         label = "same run BEFORE the line criteria - includes patients the study removed")
}

# The other-cancer and clinical-trial flags, with the table that says which
# index date each row belongs to.
#
# NOT the cohort build's NDMM_FLAGS_ALL. That table is the exclusion audit -
# CE, prior therapy, other cancer, pregnancy, belantamab - one row per patient
# keyed on PATID alone. It has no INDEX_DATE, no OTHER_MALIGN_FLAG and no
# CLINTRIAL_* column. Pointing a trial question at it is worse than a missing
# table: it IS readable, so a readable() guard passes and the query then stops
# on an unresolved column part way through a workbook.
#
# Two tables, and they have to come from ONE build. ELIG_COH_ALLFLAGS has a row
# per candidate index date; ELIG_COH_FINAL says which candidate that build
# selected, and the join needs both. Aligning the flags to the NDMM cohort
# instead puts two different index definitions on either side of the join - the
# broad build picks a diagnosis-based candidate, NDMM_COHORT.INDEX_DATE is the
# LOT1 start - so it matches almost nothing and reads as nobody being flagged.
#
# TRIAL_PREFIX names that build when it is not this one, since the flags carry
# its prefix and not this run's. Blank falls back to this prefix, which is
# right when the cohort came from the broad build itself.
#
# The two tables are named DIFFERENTLY, which is easy to get wrong from this
# side. ELIG_COH_ALLFLAGS is a checkpoint, so it is written through that
# build's prefixing helper and comes out as <prefix>ELIG_COH_ALLFLAGS. The
# final cohort is not a checkpoint: it is persisted by name from that build's
# own FINAL_TABLE_NAME, with no prefix - overall/config.csv sets it to
# OVERALL_COH_FINAL. Deriving it here as <prefix>ELIG_COH_FINAL asks for a
# table that build never writes, so TRIAL_INDEX_TABLE names it, whole, the way
# INPUT_COHORT_TABLE does.
qs_trial_flags <- function() {
  cfg <- lot_config()
  pfx <- trimws(Sys.getenv("TRIAL_PREFIX", unset = ""))
  if (nzchar(pfx) && !grepl("^[A-Za-z][A-Za-z0-9_]*_$", pfx))
    stop("TRIAL_PREFIX '", pfx, "' should be a name ending in '_', e.g. overall_.",
         call. = FALSE)
  idx <- trimws(Sys.getenv("TRIAL_INDEX_TABLE", unset = "OVERALL_COH_FINAL"))
  if (!grepl("^[A-Za-z_][A-Za-z0-9_]*$", idx))
    stop("TRIAL_INDEX_TABLE '", idx, "' is not a table name. Give the table ",
         "only, whole - it carries no prefix, so this is the FINAL_TABLE_NAME ",
         "that build was configured with.", call. = FALSE)
  list(prefix = if (nzchar(pfx)) pfx else cfg$object_prefix,
       named   = nzchar(pfx),
       flags   = if (nzchar(pfx))
                   full_name(cfg$work_schema, paste0(pfx, "ELIG_COH_ALLFLAGS"))
                 else qs_tbl("ELIG_COH_ALLFLAGS"),
       index   = wrk(idx))
}

QS_TRIAL_FLAG_COLS  <- c("PATID", "INDEX_DATE", "OTHER_MALIGN_FLAG",
                         "CLINTRIAL_BASELINE", "CLINTRIAL_FOLLOWUP")
QS_TRIAL_INDEX_COLS <- c("PATID", "INDEX_DATE")

# Which of cols the table does not have. character(0) when it has them all;
# NA when it could not be described at all, which is a different problem from a
# table of the wrong shape and gets a different message.
qs_missing_cols <- function(con, tbl, cols) {
  have <- tryCatch({
    d  <- db_q(con, glue("DESCRIBE TABLE {tbl}"))
    cn <- intersect(c("col_name", "COL_NAME", "name", "NAME"), names(d))
    if (!length(cn)) character(0) else {
      v <- toupper(trimws(as.character(d[[cn[1]]])))
      v[nzchar(v) & !startsWith(v, "#")]
    }
  }, error = function(e) NULL)
  if (is.null(have)) return(NA_character_)
  setdiff(toupper(cols), have)
}

# A column by name, whichever case the warehouse gave it back in. The two
# builds do not agree: LOT writes its status columns upper case, the broad
# build writes them lower. A bare d$STATE is NULL on the one that used state,
# which reads as "no state recorded" rather than as looking in the wrong place.
qs_col <- function(d, name) {
  if (is.null(d) || !is.data.frame(d)) return(NULL)
  i <- match(toupper(name), toupper(names(d)))
  if (is.na(i)) NULL else d[[i]]
}

# How the build behind the trial flags ended.
#
# The broad build writes <prefix>build_status with CREATE OR REPLACE, so it
# holds one row and that row is the last run on the prefix - no ordering
# needed. A run that dies part way leaves some tables from this attempt and
# some from the one before, and nothing else in the schema says so: the flags
# and the final cohort are separate writes, and a failure between them leaves
# two tables that are individually readable, carry every column, and describe
# different runs.
#
# It also records the final table name it wrote, which is worth more than the
# state: TRIAL_INDEX_TABLE defaults to a name from a config file this package
# does not read, so this is the one place that default can be checked against
# what the build actually did.
#
# No status table is a warning, not a refusal - an older build predates it.
qs_trial_build_state <- function(con, src) {
  tbl <- wrk(paste0(tolower(src$prefix), "build_status"))
  d <- tryCatch(db_q(con, glue("SELECT * FROM {tbl}")), error = function(e) NULL)
  if (is.null(d) || nrow(d) == 0) {
    log_msg("WARNING: no ", tbl, ", so the build behind the trial flags is ",
            "unverified - these answers assume it finished and wrote both ",
            "tables in the same run.")
    return(list(ok = TRUE, why = NULL))
  }
  state <- tolower(trimws(as.character(qs_col(d, "state")[1])))
  run   <- as.character(qs_col(d, "run_id")[1])
  wrote <- qs_col(d, "final_table_name")
  if (!identical(state, "complete")) {
    if (!identical(toupper(Sys.getenv("QS_IGNORE_TRIAL_BUILD_STATE", unset = "")),
                   "TRUE"))
      return(list(ok = FALSE, why = paste0(
        "the build behind them (", run, ", prefix '", src$prefix,
        "') is marked '", state, "' in ", tbl, ". It writes the flags and the ",
        "final cohort separately, so a run that stopped between them leaves ",
        "two readable tables from different attempts and nothing to tell them ",
        "apart. Re-run that build, or set QS_IGNORE_TRIAL_BUILD_STATE=TRUE if ",
        "you know it failed before writing either.")))
    log_msg("WARNING: the build behind the trial flags (", run, ") is marked '",
            state, "' and QS_IGNORE_TRIAL_BUILD_STATE is set. If it got as far ",
            "as replacing either table, the trial numbers are that run's.")
  }
  # Its own record of what it wrote beats a default this package guessed.
  if (!is.null(wrote) && nzchar(trimws(as.character(wrote[1])))) {
    want <- toupper(trimws(sub(".*[.]", "", src$index)))
    got  <- toupper(trimws(as.character(wrote[1])))
    if (!identical(want, got))
      return(list(ok = FALSE, why = paste0(
        "TRIAL_INDEX_TABLE resolves to ", src$index, ", but that build recorded ",
        "writing '", wrote[1], "' (", tbl, "). Set TRIAL_INDEX_TABLE=", wrote[1],
        " - it is named by that build's FINAL_TABLE_NAME, which this package ",
        "cannot read.")))
  }
  list(ok = TRUE, why = NULL)
}

# Can the trial questions run this time, and if not, exactly why.
#
# Readable is not enough - NDMM_FLAGS_ALL is readable and has none of the
# columns. Nor are the columns enough: two tables from different attempts of a
# half-failed build are individually well-formed. So the build's own record of
# how it ended is asked first, then the columns, and the caller gets one
# sentence to print instead of a stack trace mid-workbook.
qs_trial_flags_ready <- function(con, src = qs_trial_flags()) {
  where <- paste0("TRIAL_PREFIX is the prefix of the build that wrote ",
                  "ELIG_COH_ALLFLAGS",
                  if (!src$named) paste0(" (this run tried its own, '",
                                         src$prefix, "')") else "",
                  "; TRIAL_INDEX_TABLE is that build's final cohort table, ",
                  "which carries no prefix and is named by its ",
                  "FINAL_TABLE_NAME.")
  st <- qs_trial_build_state(con, src)
  if (!isTRUE(st$ok))
    return(list(ok = FALSE, src = src, why = paste0(
      "The other-cancer and clinical-trial answers are skipped: ", st$why)))
  for (t in list(list(tbl = src$flags, cols = QS_TRIAL_FLAG_COLS),
                 list(tbl = src$index, cols = QS_TRIAL_INDEX_COLS))) {
    miss <- qs_missing_cols(con, t$tbl, t$cols)
    if (length(miss) == 1L && is.na(miss))
      return(list(ok = FALSE, src = src, why = paste0(
        t$tbl, " is not readable, so the other-cancer and clinical-trial ",
        "answers are skipped. ", where)))
    if (length(miss))
      return(list(ok = FALSE, src = src, why = paste0(
        t$tbl, " has no ", paste(miss, collapse = ", "),
        ", so it is not the table these flags live in - the cohort build's ",
        "NDMM_FLAGS_ALL is the exclusion audit and carries none of them. ", where)))
  }
  list(ok = TRUE, src = src, why = NULL)
}

# Is INPUT_COHORT_TABLE the cohort this LOT run was actually built from?
#
# The name is checked as a name, which stopped the blank that used to resolve to
# just the schema. It cannot stop a valid name for the wrong cohort, and the
# questions that read it - observation windows, index dates, raw-claim bounds -
# would then bound this run's answers by a cohort it never saw. The LOT build
# records what it was given, so ask it rather than trusting the operator.
#
# A status table that cannot be read warns rather than stops: an older run may
# predate it, and refusing to answer at all would be worse than saying the
# binding is unverified.
#
# The LATEST row of a LOT run's status table, whatever state it reached - not
# the latest COMPLETE one. One row per run, "complete" written last of all, so
# the latest row is the run that last touched that prefix's tables. LOT
# replaces LOT_LONG_FINAL early in the line-criteria phase and validates it
# afterwards, so a rerun that replaced it and then failed leaves its own table
# on disk while the previous run's complete row still looks like the newest
# good one. Filtering to complete rows attributes those tables to a run that no
# longer wrote them - the exact case these guards exist for. The dashboard
# resolves ownership the same way, for the same reason.
#
# NULL when there is nothing to read. An older run predates the table, so the
# caller decides whether that is a warning or a refusal.
# SELECT *, not a column list: STUDY_END was added later, and an older run's
# table does not have it. Naming it would turn a run that predates it into an
# unreadable status table, which reads as no run recorded at all.
qs_lot_run_row <- function(con, prefix) {
  tbl <- wrk(paste0(prefix, "LOT_BUILD_STATUS"))
  d <- tryCatch(db_q(con, glue(
    "SELECT * FROM {tbl} ORDER BY UPDATED_AT DESC LIMIT 1")),
    error = function(e) NULL)
  if (is.null(d) || nrow(d) == 0) return(NULL)
  one <- function(nm) {
    v <- qs_col(d, nm)
    if (is.null(v)) NA_character_ else as.character(v[1])
  }
  list(tbl       = tbl,
       run       = one("RUN_ID"),
       state     = tolower(trimws(one("STATE"))),
       cohort    = one("INPUT_COHORT_TABLE"),
       study_end = one("STUDY_END"))
}

# Did that run read the same CDM vintage these questions are configured for?
#
# STUDY_END picks the quarterly table, and the quarterlies are cumulative. The
# question scripts go back to the raw CDM themselves - Q3's baseline diagnosis
# scan does - and resolve that suffix from cfg, not from the run they are
# reading. A different STUDY_END pairs that run's patients and index dates with
# a later vintage of their claims, which can carry corrections and late
# arrivals the run never saw.
#
# A sentence, not a refusal. The newer vintage is usually the better data, and
# the raw-claim sections are a minority of the workbook - but a number that is
# not what that run would have produced should say so rather than be quoted as
# if it were.
qs_vintage_note <- function(got, what) {
  cfg <- lot_config()
  if (is.null(got) || is.na(got$study_end) || !nzchar(trimws(got$study_end)))
    return(NULL)
  if (identical(trimws(got$study_end), trimws(as.character(cfg$study_end))))
    return(NULL)
  paste0(what, " ran with STUDY_END ", got$study_end, "; these questions are ",
         "configured for ", cfg$study_end, ". That picks a different quarterly ",
         "CDM table, and the quarterlies are cumulative - anything read from ",
         "the raw claims here uses the later vintage, so it can differ from ",
         "what that run saw.")
}

qs_check_run_binding <- function(con) {
  cfg <- lot_config()
  got <- qs_lot_run_row(con, cfg$object_prefix)
  if (is.null(got)) {
    log_msg("WARNING: no LOT run recorded under prefix '", cfg$object_prefix,
            "', so INPUT_COHORT_TABLE=", cfg$input_cohort_table,
            " is unverified. These answers assume it is the cohort behind it.")
    return(invisible(FALSE))
  }
  if (!identical(got$state, "complete")) {
    if (!identical(toupper(Sys.getenv("QS_IGNORE_BUILD_STATE", unset = "")), "TRUE"))
      stop("The last LOT run on prefix '", cfg$object_prefix, "' (",
           got$run, ") is marked '", got$state, "', so it is the run that ",
           "last wrote these tables and it did not finish. LOT replaces ",
           "LOT_LONG_FINAL before it validates it, so the table on disk may be ",
           "that run's - built, unvalidated, left behind - and nothing here can ",
           "tell those numbers from good ones. Re-run the LOT build, or set ",
           "QS_IGNORE_BUILD_STATE=TRUE if you know it failed before it wrote ",
           "anything.", call. = FALSE)
    log_msg("WARNING: the last LOT run (", got$run, ") is marked '", got$state,
            "' and QS_IGNORE_BUILD_STATE is set. If it got as far as replacing ",
            "LOT_LONG_FINAL, these answers are that run's.")
  }
  if (!identical(toupper(trimws(got$cohort)),
                 toupper(trimws(cfg$input_cohort_table))))
    stop("INPUT_COHORT_TABLE is '", cfg$input_cohort_table, "', but the LOT run ",
         "under prefix '", cfg$object_prefix, "' was built from '",
         got$cohort, "' (", got$tbl, "). The questions bound their ",
         "answers by the cohort's windows and index dates, so this pair would ",
         "describe one run using another's cohort.", call. = FALSE)
  v <- qs_vintage_note(got, "This run")
  if (!is.null(v)) log_msg("WARNING: ", v)
  invisible(TRUE)
}

# Did the broad LOT run behind Q3's association finish?
#
# Same rule as this run's, different consequence. The broad run is a second
# population read for one half of one question, so an unfinished one costs that
# half and nothing else - it skips rather than stopping a workbook whose other
# answers do not depend on it.
#
# The cohort it was built from comes back too. The association is over that
# population, and the tab should name it rather than leaving "the broad cohort"
# to mean whatever happens to sit under the prefix.
qs_broad_run_state <- function(con, prefix) {
  got <- qs_lot_run_row(con, prefix)
  if (is.null(got)) {
    log_msg("WARNING: no LOT run recorded under prefix '", prefix, "', so the ",
            "broad run behind Q3's association is unverified - it is read as ",
            "though it finished.")
    return(list(ok = TRUE, why = NULL, cohort = NA_character_, vintage = NULL))
  }
  # Q3 is where this matters most: the lines and index dates are that run's,
  # while the baseline diagnosis scan beside them goes to the raw CDM at this
  # run's vintage. Carried out to the tab rather than only logged.
  vin <- qs_vintage_note(got, "The broad run")
  if (!identical(got$state, "complete")) {
    if (!identical(toupper(Sys.getenv("QS_IGNORE_BROAD_BUILD_STATE", unset = "")),
                   "TRUE"))
      return(list(ok = FALSE, cohort = got$cohort, vintage = vin, why = paste0(
        "the last LOT run on prefix '", prefix, "' (", got$run,
        ") is marked '", got$state, "' in ", got$tbl, ". It replaces ",
        "LOT_LONG_FINAL before it validates it, so the lines on disk may be ",
        "that run's - built, unvalidated, left behind. Re-run it, or set ",
        "QS_IGNORE_BROAD_BUILD_STATE=TRUE if you know it failed before it ",
        "wrote anything.")))
    log_msg("WARNING: the broad LOT run (", got$run, ") is marked '", got$state,
            "' and QS_IGNORE_BROAD_BUILD_STATE is set. If it got as far as ",
            "replacing LOT_LONG_FINAL, Q3's association is that run's.")
  }
  if (!is.null(vin)) log_msg("WARNING: ", vin)
  list(ok = TRUE, why = NULL, cohort = got$cohort, vintage = vin)
}

# The line criteria that REMOVED patients from this run, read from the lot
# package's own declaration and the APPLY_* settings this run used.
#
# A question that counts a drug from MAP_STACKED and then looks for it in
# LOT_LONG_FINAL has to know about these. MAP_STACKED is built before the
# criteria, so it still holds the exposure; no_belantamab is patient-level and
# truncates, so LOT_LONG_FINAL holds none of that patient's lines. Empty means
# the study removed them, not that the drug never joined a regimen - and only
# the criteria say which.
qs_truncating_criteria <- function() {
  Filter(function(c_i) identical(c_i$on_fail, "truncate"), enabled_line_criteria())
}

# The same run's lines BEFORE the truncate, each carrying every criterion's
# flag as a column. Built whether or not a criterion is enabled, so it answers
# "who did this catch" even for a run that left it off.
qs_allflags_lines <- function() qs_tbl("LOT_LONG_ALLFLAGS")
