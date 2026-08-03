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

# A prefixed output table, from either build.
#
# NOT wrk(). In this package wrk() resolves catalog.schema.table with no
# prefix - the cohort table is named by whoever built it, so the caller passes
# the whole name. Every table these scripts read is a build's own output and
# carries that build's prefix: LOT_LONG and MAP_STACKED from lot, NDMM_FLAGS_ALL
# and ELIG_COH_ALLFLAGS from the cohort build, which share the prefix when one
# study is built under one prefix.
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

# The per-patient flag table, whichever build made this cohort.
#
# The two builds do not agree on a name. The standalone cohort build writes
# NDMM_FLAGS_ALL; the broad build writes ELIG_COH_ALLFLAGS. Asking for the
# wrong one is not a missing table you can shrug at - under a reused prefix an
# old ELIG_COH_ALLFLAGS from a retired flow can still be sitting there, and
# nothing links it to the cohort or the LOT run being read, so the flag
# breakdowns would come back full of confident numbers about another study.
#
# Named explicitly when it matters. Otherwise the caller is told which two
# names were tried rather than being handed whichever turned up first.
qs_flags_table <- function() {
  named <- trimws(Sys.getenv("FLAGS_TABLE", unset = ""))
  if (nzchar(named)) {
    if (!grepl("^[A-Za-z_][A-Za-z0-9_]*$", named))
      stop("FLAGS_TABLE '", named, "' is not a table name.", call. = FALSE)
    return(qs_tbl(named))
  }
  qs_tbl("NDMM_FLAGS_ALL")
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
