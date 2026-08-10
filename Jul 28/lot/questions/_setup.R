# Shared setup for the question scripts in this folder.
#
# They read what the cohort and LOT builds wrote, so they use the lot package's
# own modules rather than a second copy - one definition of cdm_src(), the
# code-list loaders and the naming helpers.

# Order matters. config_lot.R builds cfg_defaults out of environment variables
# at the moment it is sourced, so config.csv has to be loaded first or every
# setting silently falls back to its hardcoded default and these scripts
# describe a run configured differently from the one they are reading. The
# build loads them in this order for the same reason.
`%||%` <- function(a, b) if (is.null(a)) b else a

qs_setup <- function(script_dir) {
  lot_root <- normalizePath(file.path(script_dir, "..", "engine"), mustWork = TRUE)
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
  # The whole physical name, prefix included, because that is how LOT takes it:
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
# Not "not ICD-9, therefore ICD-10". That reads an ICD-9 claim with a missing
# flag as ICD-10, fails the family join silently, and lets a question count a
# diagnosis the cohort build did not. NULL matches neither family, which is the
# honest answer for an unknown row.
#
# It matters because raw_icd_flag is a WAIVABLE check in the cohort build, so a
# run can legitimately carry unrecognised flags.
#
# The lists live in ndmm/R/codelists.R, which this package cannot source - it
# would replace lot's load_codelist_csv(). Repeated here, and test_setup.R
# fails if the two ever differ.
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
# Not wrk(), which resolves the name with no prefix - that is for the cohort
# table, named by whoever built it. Everything these scripts read is a build's
# own output and carries its prefix. A table from a different build is named
# for itself; see qs_trial_flags().
#
# wrk() here would ask for the unprefixed name. That usually finds nothing,
# which is survivable - but an unprefixed table left by an older run succeeds,
# and the answer is about another study with nothing to say so.
qs_tbl <- function(tbl) lot_out(tbl)

# Which population a question runs over.
#
# The LOT run is over the NDMM cohort already, so its output under this prefix
# is the study population; a different cohort is a different prefix.
#
# The real choice is before or after the line criteria within one run.
# LOT_LONG_FINAL is the study population; LOT_LONG is the same run before a
# truncating criterion removed anyone, which answers what a criterion cost.
#
# FINAL is the default. A denominator off LOT_LONG called the cohort would
# count patients the study excluded.
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
# Not the cohort build's NDMM_FLAGS_ALL. That is the exclusion audit, one row
# per patient on PATID alone, with no INDEX_DATE, no OTHER_MALIGN_FLAG and no
# CLINTRIAL_* column. Pointing a trial question at it is worse than a missing
# table: it is readable, so a readable() guard passes and the query then dies
# on an unresolved column part way through the workbook.
#
# Two tables, from one build. ELIG_COH_ALLFLAGS has a row per candidate index
# date; the final cohort says which candidate that build selected, and the join
# needs both. Aligning the flags to the NDMM cohort instead puts two different
# index definitions either side of the join - a diagnosis-based candidate
# against the LOT1 start - so it matches almost nothing and reads as nobody
# being flagged.
#
# TRIAL_PREFIX names that build when it is not this one. Blank falls back to
# this prefix, which is right when the cohort came from the broad build itself.
#
# The two tables are named DIFFERENTLY. ELIG_COH_ALLFLAGS is a checkpoint, so
# it is written with that build's prefix. The final cohort is not: it is
# persisted by name from that build's own FINAL_TABLE_NAME, with no prefix.
# So TRIAL_INDEX_TABLE names it whole, the way INPUT_COHORT_TABLE does.
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

# The cohort build's own trial flag, cut at the 1L index.
#
# This one answers what the study team asked - did trial therapy come before
# the 1L start - because its windows are anchored where the cohort's index is.
# The broad build's pair cannot: its baseline ends before a diagnosis-based
# index and its follow-up starts there and runs past LOT1, so the stretch
# between is in neither.
#
# Every patient here is a patient of this run, so when it exists it is
# preferred. The broad flags are what is left for OTHER_MALIGN_FLAG.
QS_NDMM_TRIAL_COLS <- c("PATID", "LOT1_START_DT", "MM_DX_DT",
                        "CLINTRIAL_PRE_DX", "CLINTRIAL_DX_TO_LOT1",
                        "CLINTRIAL_POST_LOT1", "CLINTRIAL_PRE_LOT1_12MO",
                        "CLINTRIAL_DX_TO_LOT1_DAYS")

# Does that table belong to the cohort run these LOT lines were built from?
#
# The name is not enough, nor is the column list. The cohort build writes the
# trial flag before its cohort table and its "complete" status, so a rerun can
# replace it and then fail. And a rerun that does finish replaces it under the
# same name, so the LOT run-binding check sees nothing change.
#
# LOT records which cohort run it read - COHORT_RUN_ID and COHORT_STAMP in
# LOT_RUN_METADATA. The stamp is there because a cohort re-run keeps its id and
# rewrites its rows, so the id alone cannot tell one attempt from the next.
qs_ndmm_trial_flags <- function(con) {
  tbl  <- qs_tbl("NDMM_CLINTRIAL_FLAGS")
  gap  <- function(why) list(ok = FALSE, table = tbl, why = why)
  miss <- qs_missing_cols(con, tbl, QS_NDMM_TRIAL_COLS)
  if (length(miss) == 1L && is.na(miss))
    return(gap(paste0(
      tbl, " is not there. It is the cohort build's own trial flag, anchored ",
      "on the 1L start; a cohort built before it existed does not have it, and ",
      "the broad build's diagnosis-anchored flags are used instead.")))
  if (length(miss))
    return(gap(paste0(
      tbl, " has no ", paste(miss, collapse = ", "), ", so it is not the ",
      "1L-anchored trial flag. Re-run the cohort build.")))

  st  <- qs_tbl("NDMM_BUILD_STATUS")
  got <- tryCatch(db_q(con, glue(
    "SELECT * FROM {st} ORDER BY UPDATED_AT DESC LIMIT 1")),
    error = function(e) NULL)
  if (is.null(got) || nrow(got) == 0)
    return(gap(paste0(
      "no run is recorded in ", st, ", so nothing says whether ", tbl,
      " came from a cohort build that finished, or from the one that produced ",
      "these LOT lines.")))
  state <- tolower(trimws(as.character(qs_col(got, "STATE")[1])))
  if (!identical(state, "complete"))
    return(gap(paste0(
      "the last cohort run under this prefix (",
      as.character(qs_col(got, "RUN_ID")[1]), ") is marked '", state, "' in ",
      st, ". ", tbl, " is written before the cohort table and before that ",
      "status, so a run that stopped in between leaves it well-formed and ",
      "unfinished.")))

  # Which cohort attempt LOT read, against which one is on disk now.
  #
  # SELECT *, and the ordering column is RUN_TIMESTAMP - the name this table
  # actually uses (08_persist.R). Ordering by a column that is not there put the
  # whole query inside its own tryCatch, which returned NULL, which took the
  # "an older lot did not record it" path and passed. A guard that cannot run
  # is worse than no guard: the code and the README both claimed the check.
  lot <- tryCatch(db_q(con, glue(
    "SELECT * FROM {qs_tbl('LOT_RUN_METADATA')}
     WHERE COHORT_RUN_ID IS NOT NULL ORDER BY RUN_TIMESTAMP DESC LIMIT 1")),
    error = function(e) NULL)
  want <- if (is.null(lot) || nrow(lot) == 0) NA_character_ else
    trimws(as.character(qs_col(lot, "COHORT_RUN_ID")[1]))
  if (is.na(want) || !nzchar(want)) {
    log_msg("WARNING: the LOT run did not record which cohort run it read, so ",
            tbl, " is taken on trust. An older lot did not record it.")
    return(list(ok = TRUE, table = tbl, why = NULL))
  }
  have <- trimws(as.character(qs_col(got, "RUN_ID")[1]))
  if (!identical(toupper(want), toupper(have)))
    return(gap(paste0(
      "these LOT lines were built from cohort run ", want, ", but ", st,
      " now says the cohort under this prefix is run ", have, ". ", tbl,
      " belongs to the newer one, so pairing them would put one run's trial ",
      "flags against another run's lines.")))
  # A re-run keeps its run id, so the id matching says nothing on its own - the
  # stamp is the part that separates one attempt from the next, and the trial
  # table is written early enough in the cohort build to be a later attempt's
  # while the id still matches. A gap, not a warning, for the same reason the
  # dashboard skips its funnel here rather than annotating it.
  stamp_w <- trimws(as.character(qs_col(lot, "COHORT_STAMP")[1]))
  stamp_h <- trimws(as.character(qs_col(got, "UPDATED_AT")[1]))
  if (nzchar(stamp_w) && nzchar(stamp_h) && !identical(stamp_w, stamp_h))
    return(gap(paste0(
      "cohort run ", have, " has been rewritten since LOT read it - LOT saw ",
      stamp_w, ", ", st, " now says ", stamp_h, ". A re-run keeps its id, so ",
      tbl, " is a later attempt's than the lines it would be paired with.")))
  list(ok = TRUE, table = tbl, why = NULL)
}

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
# holds one row and no ordering is needed. A run that dies part way leaves the
# flags and the final cohort from different attempts - both readable, both
# fully formed, and nothing else in the schema says so.
#
# It also records the final table name it wrote, which is worth more than the
# state: TRIAL_INDEX_TABLE defaults to a name from a config file this package
# does not read, so this is the one place to check that default.
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
# Checking the name as a name stops a blank from resolving to just the schema. It cannot stop a valid name for the wrong cohort, and the
# questions that read it - observation windows, index dates, raw-claim bounds -
# would then bound this run's answers by a cohort it never saw. The LOT build
# records what it was given, so ask it.
#
# The latest row, whatever state it reached - not the latest complete one.
# "complete" is written last, so the latest row is the run that last touched
# these tables. LOT replaces LOT_LONG_FINAL early and validates it afterwards,
# so filtering to complete rows would credit a failed rerun's tables to the
# previous good run. The dashboard resolves ownership the same way.
#
# NULL when there is nothing to read - an older run predates the table, so the
# caller decides whether that is a warning or a refusal.
#
# SELECT *, not a column list: STUDY_END was added later, and naming it would
# make an older run's table unreadable, which reads as no run at all.
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
  dev <- one("CONTRACT_DEVIATIONS")
  list(tbl       = tbl,
       run       = one("RUN_ID"),
       state     = tolower(trimws(one("STATE"))),
       cohort    = one("INPUT_COHORT_TABLE"),
       study_end = one("STUDY_END"),
       # Empty on every contract build, and on a status table written before
       # the column existed - which is a run built before the override did, so
       # it cannot have deviated either.
       deviations = if (is.na(dev) || !nzchar(trimws(dev))) character(0)
                    else strsplit(trimws(dev), "|", fixed = TRUE)[[1]])
}

# Did that run read the same CDM vintage these questions are configured for?
#
# STUDY_END picks the quarterly table, and the quarterlies are cumulative. The
# question scripts go back to the raw CDM themselves and resolve that suffix
# from cfg, not from the run they are reading - so a different STUDY_END pairs
# that run's patients with a later vintage of their claims.
#
# A sentence, not a refusal. The newer vintage is usually better data, but a
# number that is not what that run would have produced should say so.
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
  # A run built with LOT_CONTRACT_OVERRIDE is an alternative algorithm's - a
  # sensitivity cell. Its lines are not this study's, and a workbook answered
  # off one would read exactly like a workbook answered off the study.
  if (length(got$deviations))
    stop("The LOT run under prefix '", cfg$object_prefix, "' (", got$run,
         ") was built with LOT_CONTRACT_OVERRIDE, so it is not the study's ",
         "algorithm:\n  ", paste(got$deviations, collapse = "\n  "),
         "\nThese answers would describe a threshold experiment while reading ",
         "as the study. Point OBJECT_PREFIX at the study's own run.",
         call. = FALSE)
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
# Same rule as this run's, different consequence: the broad run is read for one
# half of one question, so an unfinished one skips that half rather than
# stopping the workbook.
#
# The cohort it was built from comes back too, so the tab can name the
# population instead of leaving "the broad cohort" to mean whatever sits under
# the prefix.
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

# Two table references, one table.
#
# Compared on the bare name, case-insensitively. One side comes out of a status
# row the LOT build wrote (INPUT_COHORT_TABLE, as the operator typed it) and
# the other out of a name this package resolved through the work schema, so
# one is routinely schema-qualified and the other is not. Comparing them whole
# would report every matching pair as a mismatch.
qs_same_table <- function(a, b) {
  bare <- function(x) toupper(trimws(sub(".*[.]", "", as.character(x)[1])))
  if (length(a) == 0L || length(b) == 0L) return(FALSE)
  if (is.na(a[1]) || is.na(b[1])) return(FALSE)
  x <- bare(a); y <- bare(b)
  nzchar(x) && nzchar(y) && identical(x, y)
}

# Do the broad LOT run and the broad flag build describe the same population?
#
# BROAD_PREFIX names a LOT run, TRIAL_PREFIX the cohort build behind the
# diagnosis-anchored flags. Nothing makes them the same study, and the flag
# section joins one to the other - it labels flag-build patients POMA-1L from
# the LOT run's regimens. Point them at two cohorts and every patient the
# second build lacks reads as 'other', which looks the same as not having had
# POMA.
#
# The LOT run records the cohort it was built from, and that should be the
# cohort the flag build wrote. So it is asked rather than assumed.
#
# `bound` is TRUE only when both were recorded and match. Neither recorded is
# `unverified` - older runs predate the status table. A positive disagreement
# is known-wrong, and stops the join rather than warning.
qs_broad_pair_bound <- function(broad_cohort, trial_index) {
  has <- function(x) length(x) && !is.na(x[1]) && nzchar(trimws(as.character(x[1])))
  if (!has(broad_cohort) || !has(trial_index))
    return(list(bound = FALSE, verified = FALSE, why = paste0(
      "nothing records which cohort one of them came from, so the two broad ",
      "sources are taken on trust to be the same population")))
  if (!qs_same_table(broad_cohort, trial_index))
    return(list(bound = FALSE, verified = TRUE, why = paste0(
      "the broad LOT run was built from '", trimws(as.character(broad_cohort)[1]),
      "', but the diagnosis-anchored flags belong to the build that wrote '",
      trimws(as.character(trial_index)[1]), "'. Those are two different broad ",
      "cohorts, so lines from one cannot label patients of the other - a ",
      "patient missing from the LOT run would read as not having had POMA ",
      "rather than as not being in it. Point BROAD_PREFIX and TRIAL_PREFIX at ",
      "the same study, or leave the split off.")))
  list(bound = TRUE, verified = TRUE, why = NULL)
}

# The line criteria that REMOVED patients from this run, read from the lot
# package's own declaration and the APPLY_* settings this run used.
#
# A question that counts a drug in MAP_STACKED and then looks for it in
# LOT_LONG_FINAL has to know about these. MAP_STACKED is built before the
# criteria; no_belantamab truncates, so LOT_LONG_FINAL holds none of that
# patient's lines. Empty means the study removed them, not that the drug never
# joined a regimen.
qs_truncating_criteria <- function() {
  Filter(function(c_i) identical(c_i$on_fail, "truncate"), enabled_line_criteria())
}

# The same run's lines before the truncate, each carrying every criterion's
# flag as a column. Built whether or not a criterion is enabled, so it answers
# "who did this catch" even for a run that left it off.
qs_allflags_lines <- function() qs_tbl("LOT_LONG_ALLFLAGS")
