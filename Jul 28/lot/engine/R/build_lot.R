# Runner for the LOT build. Standalone: one module, pointed at a cohort table.
#
# The rules are the same for every cohort. What changes per run is which table
# is read, which prefix the outputs carry, and which study window the run
# covers - the caller supplies all four. No cohort is named anywhere in this
# folder, and no study's dates are pinned in it. Everything else is fixed below
# and checked before the first query.

`%||%` <- function(a, b) if (is.null(a)) b else a

# Settings that decide what a LOT run means. A different value here is a
# different result, so they are checked rather than defaulted. Change a value
# here and in config.csv together, deliberately.
#
# The study window is deliberately not here. It follows the cohort being built,
# and different cohorts have different windows, so pinning it would mean editing
# this file to run the same algorithm against a different study. It is a per-run
# argument, like the cohort table and the output prefix, checked by
# pin_study_window() and recorded in LOT_RUN_METADATA.
CONTRACT <- list(
  catalog                     = "hive_metastore",
  cdm_schema                  = "clnprw_optum",
  codelist_dir                = "/mnt/code/codelist",
  use_quarterly_tables        = TRUE,
  censor_at_disenrollment     = FALSE,
  # Blank is the algorithm this study is defined as. A mode builds a different
  # one, which is why it is pinned here rather than left as a free setting - as
  # are the thresholds that say what the rule means.
  apply_melp_rule             = "",
  # A CAR-T inside LOT1's induction window is part of LOT1 - it neither ends
  # the line nor starts one. Confirmed by the study team on 2026-08-13; see
  # R/cart_rule.R and lot/LOT_RULES.md section 10.
  apply_cart_induction_rule   = TRUE,
  # The protocol's belantamab exclusion. It was a line criterion and nothing
  # else, so APPLY_NO_BELANTAMAB defaulted to FALSE when unset: a config.csv
  # that lost the row, or an environment that never set it, produced a
  # STATE=complete run with the exclusion silently off and nothing in
  # CONTRACT_DEVIATIONS to say so. Pinned here, so the default is on and
  # turning it off needs LOT_CONTRACT_OVERRIDE and is recorded like any other
  # contract change. criterion_enabled() reads this, not a bare env default.
  apply_no_belantamab         = TRUE,
  melp_med_abbr               = "MELP",
  melp_exposure_days          = 30L,
  melp_restart_days           = 60L,
  melp_advance_days           = 180L,
  melp_sct_days               = 14L,
  induction_window_days       = 60L,
  lot_n_induction_window_days = 30L,
  map_discon_gap_days         = 90L,
  # Follow-up required AFTER a line's run-out before it counts as a
  # discontinuation. The spec's LOT1_BASE tab carries this and its later
  # end-date tabs do not; the study team adjudicated in favour of the tab that
  # has it, because in a real-world claims study "we stopped seeing fills" and
  # "the patient discontinued" are different claims when the data simply runs
  # out. A run-out with less than this much observation left is not confirmed,
  # so the line is censored at study end instead. 0 restores the old behaviour.
  lot_discon_confirm_days     = 90L,
  medical_day_supply          = 28L,
  sct_auto_window_days        = 13L,
  sct_auto_gap_days           = 60L,
  sct_tandem_days             = 180L,
  cart_consolidation_days     = 45L,
  allo_lot_span               = "single_day",
  max_lot                     = 5L,
  dsn                         = "RWDE",
  tbl_medical                 = "medical",
  tbl_med_proc                = "med_procedure",
  # How belantamab is spelled in MED_ABBR, for the line criterion. Same
  # abbreviation the cohort build uses on cl_mma_codelist.csv.
  belantamab_med_abbr         = "BELA",
  tbl_med_diag                = "med_diagnosis",
  tbl_rx                      = "rx"
)

# Reviewable code-list checks: each has a reading a study team can accept.
# Named individually, because one switch for all of them meant waiving an
# expected condition also waived the dangerous ones.
# The claim side is not here: a CDM value that matches nothing is a non-match,
# not a decision. These are the code list's own, which are fixable at source.
WAIVABLE_CHECKS <- c("orphan_meds", "uncoded_meds", "code_types",
                     "subs_substitute", "subs_original", "ndc_short")

# Fatal checks: always stop the build. Named rather than merely absent, so a
# waiver naming one is told why it is refused instead of "no such check".
FATAL_CHECKS <- c("code_to_med", "bad_ndc", "rollup_defs", "blank_keys",
                  "ndc_shape", "multi_class", "class_agreement")

ALL_CHECKS <- c(WAIVABLE_CHECKS, FATAL_CHECKS)

codelist_waivers_named <- function() {
  v <- trimws(strsplit(Sys.getenv("CODELIST_WAIVERS", unset = ""), "[,|]")[[1]])
  v[nzchar(v)]
}

# Never hands back a check that cannot be waived, whatever the environment
# says, so the split holds even if check_settings is bypassed.
codelist_waivers <- function() intersect(codelist_waivers_named(), WAIVABLE_CHECKS)

# The columns LOT reads off whatever cohort table it is pointed at. Checked
# against the real table before any work starts, so a cohort that cannot drive
# LOT says so immediately instead of failing somewhere in the middle.
REQUIRED_COHORT_COLS <- c("PATID", "INDEX_DATE", "ENDDATE", "ENDDATE_CE",
                          "DEATH_DT", "GDR_CD", "YRDOB", "AGE_INDEX_YR",
                          "FU_DAYS", "FU_DAYS_CE")

# Bad values fail open: as.logical("Y") is NA, which reads as FALSE. An
# integer setting that will not parse becomes NA and silently widens a window.
BOOL_SETTINGS <- c("USE_QUARTERLY_TABLES", "CENSOR_AT_DISENROLLMENT",
                   "PERSIST_TO_SCHEMA", "APPLY_CART_INDUCTION_RULE",
                   "APPLY_NO_BELANTAMAB")
INT_SETTINGS  <- c("INDUCTION_WINDOW_DAYS", "INDUCTION_WINDOW_DAYS_LOT_N",
                   "MAP_DISCON_GAP_DAYS", "MEDICAL_DAY_SUPPLY",
                   "SCT_AUTO_WINDOW_DAYS", "SCT_AUTO_GAP_DAYS",
                   "SCT_TANDEM_DAYS", "CART_CONSOLIDATION_DAYS", "MAX_LOT",
                   "LOT_DISCON_CONFIRM_DAYS",
                   # The melphalan windows are in CONTRACT and config_lot.R
                   # coerces them the same way, but they were not checked here:
                   # MELP_EXPOSURE_DAYS=30.5 became 30, matched the contract
                   # value, and recorded no deviation.
                   "MELP_EXPOSURE_DAYS", "MELP_RESTART_DAYS",
                   "MELP_ADVANCE_DAYS", "MELP_SCT_DAYS")

check_settings <- function() {
  bad <- character(0)
  for (v in BOOL_SETTINGS) {
    x <- Sys.getenv(v, unset = "")
    if (nzchar(x) && !(toupper(x) %in% c("TRUE", "FALSE")))
      bad <- c(bad, paste0(v, "='", x, "' (want TRUE or FALSE)"))
  }
  for (v in INT_SETTINGS) {
    x <- trimws(Sys.getenv(v, unset = ""))
    # The text, not what coercion makes of it: as.integer("60.5") is 60, not
    # NA, so a decimal passed this and was silently truncated - the run used 60
    # while the operator had asked for 60.5. "6e1" is the same story.
    if (nzchar(x) && !grepl("^[0-9]+$", x))
      bad <- c(bad, paste0(v, "='", x, "' (want a whole number)"))
  }
  s <- Sys.getenv("PROJECT_WORK_SCHEMA", unset = "")
  if (grepl(".", s, fixed = TRUE))
    bad <- c(bad, paste0("PROJECT_WORK_SCHEMA='", s,
                         "' is catalog.schema; it wants a schema name"))
  for (v in c("STUDY_START", "STUDY_END")) {
    x <- Sys.getenv(v, unset = "")
    if (nzchar(x) && !grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", x))
      bad <- c(bad, paste0(v, "='", x, "' (want YYYY-MM-DD)"))
  }
  # Both parse, and in order. A window that runs backwards would pass every
  # per-setting check and then make check_cohort_window() reject every cohort.
  # Reaches an identifier, so it is held to one - the same rule the cohort
  # table and the prefixes get.
  cst <- trimws(Sys.getenv("COHORT_STATUS_TABLE", unset = ""))
  if (nzchar(cst) && !grepl("^[A-Za-z_][A-Za-z0-9_]*$", cst))
    bad <- c(bad, paste0("COHORT_STATUS_TABLE='", cst, "' (want a table name ",
                         "on its own, no schema and no prefix)"))
  cp2 <- trimws(Sys.getenv("COHORT_PREFIX", unset = ""))
  if (nzchar(cp2) && !grepl("^[A-Za-z][A-Za-z0-9_]*_$", cp2))
    bad <- c(bad, paste0("COHORT_PREFIX='", cp2, "' (want a name ending in '_')"))
  s <- Sys.getenv("STUDY_START", unset = ""); e <- Sys.getenv("STUDY_END", unset = "")
  if (grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", s) &&
      grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", e) && s >= e)
    bad <- c(bad, paste0("STUDY_START='", s, "' is not before STUDY_END='", e, "'"))
  w <- codelist_waivers_named()
  refused <- intersect(w, FATAL_CHECKS)
  if (length(refused))
    bad <- c(bad, paste0("CODELIST_WAIVERS names checks that cannot be waived: ",
                         paste(refused, collapse = ", "),
                         " - each one changes who counts as treated, so it has ",
                         "to be corrected in the code list"))
  unknown <- setdiff(w, ALL_CHECKS)
  if (length(unknown))
    bad <- c(bad, paste0("CODELIST_WAIVERS names no such check: ",
                         paste(unknown, collapse = ", "), " (choose from ",
                         paste(WAIVABLE_CHECKS, collapse = ", "), ")"))
  # run_id reaches SQL as a string literal at fifteen sites, and every other
  # identifier that does is checked - schema, cohort table, prefix. The platform
  # sets this one, so it is consistency rather than defence against anybody; an
  # apostrophe in it would fail somewhere deep instead of here.
  r <- Sys.getenv("DOMINO_RUN_ID", unset = "")
  if (nzchar(r) && !grepl("^[A-Za-z0-9_.-]+$", r))
    bad <- c(bad, paste0("DOMINO_RUN_ID='", r,
                         "' (want letters, digits, underscore, dot or dash)"))
  a <- Sys.getenv("ALLO_LOT_SPAN", unset = "")
  if (nzchar(a) && !a %in% c("single_day", "extend_to_next"))
    bad <- c(bad, paste0("ALLO_LOT_SPAN='", a,
                         "' (want single_day or extend_to_next)"))

  if (length(bad))
    stop("Settings that would build a different LOT:\n  ",
         paste(bad, collapse = "\n  "), call. = FALSE)
  invisible(TRUE)
}

# One schema for everything: <catalog>.<schema>. No schema is an error rather
# than a silently skipped write.
pin_output_schema <- function(cfg) {
  schema <- Sys.getenv("PROJECT_WORK_SCHEMA",
              unset = Sys.getenv("DOMINO_USER_NAME",
                unset = Sys.getenv("DOMINO_STARTING_USERNAME", unset = "")))
  if (!nzchar(schema))
    stop("No output schema. Set DOMINO_USER_NAME to your personal schema ",
         "(e.g. usr00000), or PROJECT_WORK_SCHEMA to override.", call. = FALSE)
  # It goes straight into table names, so check the value we resolved rather
  # than each variable it could have come from.
  if (!grepl("^[A-Za-z_][A-Za-z0-9_]*$", schema))
    stop("Output schema '", schema, "' is not a schema name.", call. = FALSE)
  cfg$work_schema <- schema
  cfg
}

# The caller says which table to read and what to call the outputs. This folder
# holds no cohort names of its own - that is what keeps it a package rather
# than part of one study.
pin_cohort <- function(cfg, cohort_table, prefix) {
  cohort_table <- trimws(as.character(cohort_table %||% ""))
  prefix       <- trimws(as.character(prefix %||% ""))
  if (!nzchar(cohort_table) || !nzchar(prefix))
    stop("LOT needs a cohort table and an output prefix.\n",
         "  Rscript build.R <COHORT_TABLE> <prefix_>\n",
         "  or set INPUT_COHORT_TABLE and OBJECT_PREFIX.", call. = FALSE)
  # Both end up in SQL identifiers, so keep them to what an identifier allows.
  if (!grepl("^[A-Za-z_][A-Za-z0-9_]*$", cohort_table))
    stop("Cohort table '", cohort_table, "' is not a table name. Give the ",
         "table only - the catalog and schema come from the settings.",
         call. = FALSE)
  if (!grepl("^[A-Za-z][A-Za-z0-9_]*_$", prefix))
    stop("Prefix '", prefix, "' should be a name ending in '_', e.g. mystudy_.",
         call. = FALSE)
  cfg$input_cohort_table <- cohort_table
  cfg$object_prefix      <- prefix
  cfg
}

# The study window this run covers. Passed rather than pinned: the algorithm is
# the same for every study, but the dates are the cohort's, and a run against a
# cohort with a different window has to be possible without editing this folder.
#
# study_end also selects the quarterly CDM tables, so it is not merely a label -
# a different value is different source data for every read. That is why it is
# checked here as strictly as the settings that are pinned, rather than taken on
# trust because it arrived as an argument: check_settings() only sees the
# environment, and these can come from the command line instead.
pin_study_window <- function(cfg, study_start, study_end) {
  start <- trimws(as.character(study_start %||% ""))
  end   <- trimws(as.character(study_end   %||% ""))
  if (!nzchar(start)) start <- cfg$study_start %||% ""
  if (!nzchar(end))   end   <- cfg$study_end   %||% ""
  bad <- character(0)
  if (!nzchar(start) || !nzchar(end))
    stop("LOT needs a study window.\n",
         "  Rscript build.R <COHORT_TABLE> <prefix_> <study_start> <study_end>\n",
         "  or set STUDY_START and STUDY_END (config.csv supplies both).",
         call. = FALSE)
  # tryCatch because as.Date errors, rather than returning NA, on a string
  # matching none of its standard formats - "2026-13-31" is ISO-shaped and not a
  # date, and without this it stops with R's own message instead of one naming
  # the setting.
  real_date <- function(x)
    !is.na(tryCatch(suppressWarnings(as.Date(x)), error = function(e) NA))
  for (p in list(c("study_start", start), c("study_end", end)))
    if (!grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", p[2]) || !real_date(p[2]))
      bad <- c(bad, paste0(p[1], "='", p[2], "' (want a real date, YYYY-MM-DD)"))
  # String comparison is the date comparison for ISO dates, and both have just
  # been checked to be ISO.
  if (!length(bad) && start >= end)
    bad <- c(bad, paste0("study_start='", start, "' is not before study_end='",
                         end, "'"))
  if (length(bad))
    stop("The study window would not build a LOT:\n  ",
         paste(bad, collapse = "\n  "), call. = FALSE)
  cfg$study_start <- start
  cfg$study_end   <- end
  cfg
}

# A cohort table missing a column LOT needs would fail deep into the build, so
# ask the table up front.
check_cohort_input <- function(con, tbl) {
  cols <- tryCatch(toupper(db_q(con, glue("DESCRIBE {tbl}"))[[1]]),
                   error = function(e)
                     stop("Cannot read the cohort table ", tbl, ": ",
                          conditionMessage(e), call. = FALSE))
  miss <- setdiff(REQUIRED_COHORT_COLS, cols)
  if (length(miss))
    stop(tbl, " cannot drive LOT. Missing: ", paste(miss, collapse = ", "),
         call. = FALSE)

  # The rules read this table row for row - no DISTINCT, no ranking. A repeated
  # patient would multiply their claims and their lines, so check the shape too,
  # not just the column names. ENDDATE_CE may be null: the primary branch uses
  # ENDDATE and the sensitivity branch falls back to it.
  # SUM is NULL on an empty table. Coalesce the validation counts.
  q <- db_q(con, glue("
    SELECT count(*) AS n_rows,
           count(DISTINCT PATID) AS n_patients,
           coalesce(sum(CASE WHEN PATID IS NULL THEN 1 ELSE 0 END), 0) AS n_null_patid,
           coalesce(sum(CASE WHEN INDEX_DATE IS NULL THEN 1 ELSE 0 END), 0) AS n_null_index,
           coalesce(sum(CASE WHEN ENDDATE IS NULL THEN 1 ELSE 0 END), 0) AS n_null_end,
           coalesce(sum(CASE WHEN ENDDATE < INDEX_DATE THEN 1 ELSE 0 END), 0) AS n_end_before_index
    FROM {tbl}"))
  # Nothing else is worth saying about an empty table, and stopping here means
  # the counts above are never compared even if a coalesce is lost later.
  if (q$n_rows == 0) stop(tbl, " cannot drive LOT: it is empty", call. = FALSE)
  bad <- character(0)
  if (q$n_null_patid > 0)       bad <- c(bad, paste0(q$n_null_patid, " rows have no PATID"))
  if (q$n_null_index > 0)       bad <- c(bad, paste0(q$n_null_index, " rows have no INDEX_DATE"))
  if (q$n_null_end > 0)         bad <- c(bad, paste0(q$n_null_end, " rows have no ENDDATE"))
  if (q$n_end_before_index > 0) bad <- c(bad, paste0(q$n_end_before_index,
                                                     " rows end before they start"))
  if (q$n_rows != q$n_patients)
    bad <- c(bad, paste0(q$n_rows, " rows for ", q$n_patients,
                         " patients - one index per patient is required"))
  if (length(bad))
    stop(tbl, " cannot drive LOT: ", paste(bad, collapse = "; "), call. = FALSE)
  log_msg("  Cohort input OK in ", tbl, ": ", q$n_patients, " patients")
  # Returned so the pinned copy can be checked against the table it came from.
  invisible(list(n_rows = q$n_rows, n_patients = q$n_patients))
}

# The cohort has to fit inside the window this build reads.
#
# Every claim scan is bounded by the cohort's INDEX_DATE and OBS_END_DT, so a
# cohort whose ENDDATE runs past study_end asks for follow-up the CDM tables do
# not hold. It does not fail - it gives MAPs that end early, discontinuations
# that never happened and STUDY_END reasons. All wrong, all plausible, none
# visible in a count.
#
# Not hypothetical: the NDMM cohort ends 2026-03-31 and this build defaults to
# 2025-06-30, a different quarterly vintage.
# Table names the cohort builds use for their run status, before the prefix.
COHORT_STATUS_TABLES <- c("NDMM_BUILD_STATUS", "build_status")

# The cohort build's prefix. Its tables carry it; ours carry ours. Usually the
# same - one study, one prefix - so it defaults to ours rather than being a
# second thing to remember.
#
# This matters more than it looks. wrk() here does not add a prefix: the cohort
# table is named by the cohort build, so the caller passes the whole name. Only
# lot_out() prefixes, and only for our own outputs. So a status table has to be
# prefixed explicitly, and looking for a bare "NDMM_BUILD_STATUS" finds nothing
# on any real run.
cohort_prefix <- function(cfg) {
  cp <- trimws(cfg$cohort_prefix %||% "")
  if (nzchar(cp)) cp else (cfg$object_prefix %||% "")
}

# Refuse a cohort whose own build did not finish.
#
# Both cohort builds publish the table before they are marked complete, and
# validate it afterwards. So a failed build leaves a readable, well-formed
# cohort table - one every check below passes, because they ask whether the
# table is shaped right, not whether anyone stood behind it.
#
# Returns the cohort build's run id, or NA when no status table was found.
check_cohort_build <- function(con, cfg) {
  named <- trimws(cfg$cohort_status_table %||% "")
  cp    <- cohort_prefix(cfg)
  cands <- if (nzchar(named)) named else COHORT_STATUS_TABLES
  want  <- toupper(trimws(cfg$input_cohort_table))
  tried <- character(0)
  found <- list()

  for (nm in cands) {
    tbl <- wrk(paste0(cp, nm))
    tried <- c(tried, tbl)
    # Absent and unreadable are different answers. A permissions failure, a
    # dropped connection or a malformed table all used to read as "no status
    # here", and the run carried on with no cohort provenance at all.
    d <- tryCatch(db_q(con, glue(
           "SELECT * FROM {tbl} ORDER BY UPDATED_AT DESC LIMIT 1")),
         error = function(e) e)
    if (inherits(d, "error")) {
      if (missing_object_error(d)) next
      stop("Could not read the cohort build-status table ", tbl, ": ",
           conditionMessage(d), ". That is not the same as its being absent, ",
           "so this run will not treat the cohort as unverified and carry on.",
           call. = FALSE)
    }
    if (!nrow(d)) next
    # Column case differs between the builds. Spark does not care; R does.
    pick <- function(w) {
      i <- match(tolower(w), tolower(names(d)))
      if (is.na(i)) NA_character_ else as.character(d[[i]][1])
    }
    # Does this row say which cohort it built? Some status tables carry the
    # name and some do not, so this is "yes/no/it does not say" rather than a
    # match test.
    cohort_col <- pick("final_table_name")
    names_it <- if (is.na(cohort_col)) NA
                else identical(toupper(trimws(cohort_col)), want)
    found[[length(found) + 1L]] <- list(
      table = tbl, state = tolower(trimws(pick("state") %||% "")),
      run_id = pick("run_id"), stamp = pick("updated_at"),
      names_it = names_it, cohort = cohort_col)
  }

  # A row that names a different cohort is not this cohort's status, whatever
  # its state. Drop it rather than letting table order decide.
  wrong <- Filter(function(f) identical(f$names_it, FALSE), found)
  found <- Filter(function(f) !identical(f$names_it, FALSE), found)
  for (w in wrong)
    log_msg("  Ignoring ", w$table, ": it is the status of ", w$cohort,
            ", not of ", cfg$input_cohort_table, ".")
  # Every candidate named a DIFFERENT cohort. That is not "no status found" -
  # it is positive evidence that the status under this prefix belongs to
  # something else, and the cohort handed to LOT has none of its own.
  if (length(wrong) && !length(found))
    stop("The build-status table(s) under prefix '", cp, "' record ",
         paste(unique(vapply(wrong, function(w) w$cohort, character(1))),
               collapse = ", "), ", not ", cfg$input_cohort_table,
         ". Nothing here says that cohort was ever built, let alone that it ",
         "finished. Name its status table with COHORT_STATUS_TABLE, or give ",
         "the cohort its own COHORT_PREFIX.", call. = FALSE)

  # More than one left and none of them says which cohort it built. Picking by
  # the order they are listed in would be guessing, and a reused prefix is
  # exactly when that guess is wrong.
  if (length(found) > 1L && !any(vapply(found, function(f) isTRUE(f$names_it),
                                        logical(1))))
    stop("More than one cohort build-status table sits under prefix '", cp,
         "': ", paste(vapply(found, `[[`, character(1), "table"), collapse = ", "),
         ". None of them records which cohort it built, so which one describes ",
         cfg$input_cohort_table, " cannot be decided here. Name it with ",
         "COHORT_STATUS_TABLE, or give the cohort its own COHORT_PREFIX.",
         call. = FALSE)

  # Prefer the one that names this cohort, if any does.
  ord <- order(!vapply(found, function(f) isTRUE(f$names_it), logical(1)))
  for (f in found[ord]) {
    # The run id alone does not identify an attempt: a cohort re-run keeps its
    # run id and rewrites its rows under it. UPDATED_AT moves every time, so
    # the pair is what says "this attempt", and it is the pair that gets
    # recorded and re-checked.
    got <- list(run_id = f$run_id, stamp = f$stamp, table = f$table)
    if (identical(f$state, "complete")) {
      log_msg("Cohort build ", f$run_id, " completed (", f$table, ", ",
              f$stamp, ")")
      return(got)
    }
    if (identical(toupper(Sys.getenv("LOT_IGNORE_COHORT_STATE", unset = "")), "TRUE")) {
      log_msg("WARNING: cohort build ", f$run_id, " is marked '", f$state,
              "' in ", f$table, " and LOT_IGNORE_COHORT_STATE is set. These ",
              "lines may be built from a cohort its own build did not stand ",
              "behind.")
      return(got)
    }
    stop("The cohort build that last wrote ", f$table, " (run ", f$run_id,
         ") is marked '", f$state, "', not complete. Its cohort table is still ",
         "readable and well formed - the build publishes it before it ",
         "validates it and records its attrition - so nothing further down ",
         "would notice. Re-run the cohort build. If that run is known to have ",
         "failed after the cohort was final, set LOT_IGNORE_COHORT_STATE=TRUE.",
         call. = FALSE)
  }

  # Named but unreadable is a mistake, not an absence. Carrying on would give
  # the run no cohort provenance while looking like it had been checked.
  if (nzchar(named))
    stop("COHORT_STATUS_TABLE names ", tried[1], ", which could not be read. ",
         "Give the table name without the schema and without the cohort ",
         "prefix - COHORT_PREFIX is added for you, and defaults to this run's ",
         "own prefix.", call. = FALSE)
  # No status anywhere. This used to warn and carry on, which meant the normal
  # path - COHORT_STATUS_TABLE unset - could build a whole study off a cohort
  # whose own build may have failed, and record NULL provenance for it. The
  # explicit path already stopped; the default now does too.
  msg <- paste0("No cohort build-status table found (looked for ",
                paste(tried, collapse = ", "), "). Nothing here can say ",
                "whether the build that wrote ", wrk(cfg$input_cohort_table),
                " finished, so these lines would be built on an unverified ",
                "cohort and recorded with no provenance. Set ",
                "COHORT_STATUS_TABLE, and COHORT_PREFIX if the cohort build ",
                "used a different one.")
  if (!identical(toupper(Sys.getenv("LOT_ALLOW_UNVERIFIED_COHORT", unset = "")),
                 "TRUE"))
    stop(msg, " If the cohort is known good and has no status table, set ",
         "LOT_ALLOW_UNVERIFIED_COHORT=TRUE.", call. = FALSE)
  log_msg("WARNING: ", msg, " LOT_ALLOW_UNVERIFIED_COHORT is set, so the run ",
          "continues with no cohort provenance.")
  list(run_id = NA_character_, stamp = NA_character_, table = NA_character_)
}

# The cohort must not have moved while we were reading it.
#
# check_cohort_build() runs before the cohort is copied into
# LOT_PATIENT_INPUT, with the code lists loaded in between. A cohort rebuilt in
# that gap replaces the table, and the snapshot check compares only row and
# patient counts - which a same-size rebuild passes.
#
# So it is asked again afterwards, and must be the same attempt: same run id
# and same timestamp, because a re-run keeps its id.
recheck_cohort_build <- function(con, cfg, before) {
  # No run id means check_cohort_build() found no status - only reachable now
  # under LOT_ALLOW_UNVERIFIED_COHORT. Skipping in silence made an unverified
  # cohort look re-checked; say what is not being checked.
  if (is.na(before$run_id)) {
    log_msg("WARNING: no cohort attempt was recorded before the copy, so ",
            "whether the cohort was rebuilt during it cannot be checked.")
    return(invisible(TRUE))
  }
  after <- tryCatch(check_cohort_build(con, cfg), error = function(e) e)
  if (inherits(after, "error"))
    stop("The cohort build's status changed while LOT was reading it: ",
         conditionMessage(after), call. = FALSE)
  if (!identical(after$run_id, before$run_id) ||
      !identical(as.character(after$stamp), as.character(before$stamp)))
    stop("The cohort was rebuilt while this run was reading it. Before the ",
         "copy it was run ", before$run_id, " (", before$stamp, "); after it ",
         "is run ", after$run_id, " (", after$stamp, "). LOT_PATIENT_INPUT may ",
         "hold either, and the snapshot check compares only row and patient ",
         "counts, which a same-size rebuild passes. Re-run the LOT build.",
         call. = FALSE)
  invisible(TRUE)
}

check_cohort_window <- function(con, tbl, cfg) {
  q <- db_q(con, glue("
    SELECT cast(min(INDEX_DATE) as string) AS min_index,
           cast(max(INDEX_DATE) as string) AS max_index,
           cast(max(ENDDATE)    as string) AS max_end,
           coalesce(sum(CASE WHEN ENDDATE > date('{cfg$study_end}') THEN 1 ELSE 0 END), 0) AS n_past_end,
           coalesce(sum(CASE WHEN INDEX_DATE < date('{cfg$study_start}') THEN 1 ELSE 0 END), 0) AS n_before_start
    FROM {tbl}"))
  vintage <- if (isTRUE(cfg$use_quarterly_tables))
    paste0(" (the ", get_quarter_suffix(cfg$study_end), " CDM tables)") else ""
  bad <- character(0)
  if (q$n_past_end > 0)
    bad <- c(bad, paste0(q$n_past_end, " patients are observed past STUDY_END=",
                         cfg$study_end, vintage, " - the latest ENDDATE is ",
                         q$max_end))
  if (q$n_before_start > 0)
    bad <- c(bad, paste0(q$n_before_start, " patients are indexed before ",
                         "STUDY_START=", cfg$study_start,
                         " - the earliest INDEX_DATE is ", q$min_index))
  if (length(bad))
    stop(tbl, " was built to a wider window than this LOT run reads:\n  ",
         paste(bad, collapse = "\n  "),
         "\nLOT bounds every claim scan by the cohort's own dates, so the ",
         "claims outside this window are simply absent: lines would end early, ",
         "discontinuations would be recorded that did not happen, and nothing ",
         "in the output would say so. Either point STUDY_START/STUDY_END at ",
         "the same window the cohort was built to, or rebuild the cohort to ",
         "this one.", call. = FALSE)
  log_msg("  Cohort window OK: indexed ", q$min_index, " to ", q$max_index,
          ", observed to ", q$max_end, ", inside ", cfg$study_start, " .. ",
          cfg$study_end, vintage)
  invisible(TRUE)
}

# A build that is not the contract build is a different algorithm, and it is
# refused. LOT_CONTRACT_OVERRIDE is the one way past, and it exists for one
# caller: the sensitivity sweep, whose axes are all contract-pinned.
#
# Safe only because a deviating run cannot pass for the study's: the deviations
# go into LOT_BUILD_STATUS and every reader refuses them, CONTRACT_SETTINGS
# records what the run used rather than what CONTRACT pins, and the sweep will
# not write to the study's prefix.
#
# Unset - every production run - nothing here changes.
check_lot_contract <- function(cfg) {
  options(lot_contract_deviations = character(0))
  wrong <- unlist(Filter(Negate(is.null), lapply(names(CONTRACT), function(k) {
    got <- cfg[[k]]
    if (isTRUE(all.equal(got, CONTRACT[[k]]))) NULL
    else paste0(k, "=", format(got), " (contract ", format(CONTRACT[[k]]), ")")
  })))
  if (length(wrong)) {
    if (!identical(toupper(trimws(Sys.getenv("LOT_CONTRACT_OVERRIDE", unset = ""))),
                   "TRUE"))
      stop("This build is defined as:\n  ", paste(wrong, collapse = "\n  "),
           "\nA different value is a different LOT algorithm, not a setting. ",
           "If you are deliberately building an alternative to measure it ",
           "against this one, set LOT_CONTRACT_OVERRIDE=TRUE: the deviations ",
           "are then recorded in LOT_BUILD_STATUS and every reader that ",
           "resolves run ownership refuses the output as the study's.",
           call. = FALSE)
    options(lot_contract_deviations = wrong)
    log_msg("WARNING: LOT_CONTRACT_OVERRIDE is set. This is NOT the contract ",
            "build:\n  ", paste(wrong, collapse = "\n  "))
    log_msg("  Its tables are an alternative algorithm's. They are recorded as ",
            "such in LOT_BUILD_STATUS, and the questions, the dashboard and ",
            "the benchmark harness all refuse a run carrying deviations.")
  }
  # Without a prefix every run writes the same table names, so a second cohort
  # would overwrite the first instead of sitting beside it.
  if (!nzchar(cfg$object_prefix))
    stop("No output prefix. LOT outputs would collide with another cohort's.",
         call. = FALSE)
  if (!nzchar(cfg$input_cohort_table))
    stop("No cohort table to read.", call. = FALSE)
  # Not in CONTRACT, so say so here rather than letting an empty window reach
  # get_quarter_suffix() and fail as an unparseable date.
  if (!nzchar(cfg$study_start %||% "") || !nzchar(cfg$study_end %||% ""))
    stop("No study window. LOT reads the quarterly CDM tables that study_end ",
         "selects, so it cannot start without one.", call. = FALSE)
  if (!isTRUE(cfg$persist_to_schema))
    stop("PERSIST_TO_SCHEMA is FALSE, so nothing would be written. ",
         "Set it TRUE to build LOT.", call. = FALSE)
  invisible(TRUE)
}

# config.csv has to load before config_lot.R, which reads Sys.getenv() at
# source time.
load_lot_modules <- function(here) {
  source(file.path(here, "R", "load_inputs.R"))
  load_pipeline_inputs(here, "config.csv")
  for (f in c("config_lot.R", "db_utils_lot.R", "codelists_lot.R", "line_criteria.R",
              "melp_rule.R", "cart_rule.R"))
    source(file.path(here, "R", f))
  steps <- sort(list.files(file.path(here, "R", "steps"), "\\.R$", full.names = TRUE))
  for (f in steps) source(f)
  invisible(TRUE)
}

# The run. Phases in order, each one leaving temp views the next reads.
# study_start/study_end default to whatever config.csv put in the environment,
# so the common case passes two arguments and the cross-study case passes four.
build_lot <- function(here, cohort_table, prefix,
                      study_start = NULL, study_end = NULL) {
  check_settings()
  cfg <- pin_output_schema(cfg_defaults)
  cfg <- pin_cohort(cfg, cohort_table, prefix)
  cfg <- pin_study_window(cfg, study_start, study_end)
  cfg$code_md5 <- code_fingerprint(here)
  check_lot_contract(cfg)
  # Every helper reads the config, so publish it before anything runs.
  set_lot_config(cfg)

  stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")
  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  log_msg("Connected. Run ID: ", run_id)
  log_msg("Configuration:")
  log_msg("  CDM Schema:        ", cfg$cdm_schema)
  log_msg("  Work Schema:       ", cfg$work_schema)
  log_msg("  Input Cohort:      ", cfg$input_cohort_table)
  log_msg("  Output Prefix:     ", cfg$object_prefix)
  log_msg("  Study Window:      ", cfg$study_start, " .. ", cfg$study_end,
          if (isTRUE(cfg$use_quarterly_tables))
            paste0(" (", get_quarter_suffix(cfg$study_end), " CDM tables)") else "")
  log_msg("  Induction Window (LOT1):   ", cfg$induction_window_days, " days")
  log_msg("  Induction Window (LOT2-5): ", cfg$lot_n_induction_window_days, " days")
  log_msg("  Discon Gap (per-drug, MAP-level): ", cfg$map_discon_gap_days, " days")
  log_msg("  Medical Day Supply: ", cfg$medical_day_supply, " days")

  cohort <- check_cohort_input(con, wrk(cfg$input_cohort_table))
  check_cohort_window(con, wrk(cfg$input_cohort_table), cfg)
  # Before anything is pinned or built from it.
  cohort_status <- check_cohort_build(con, cfg)
  options(lot_cohort_run_id = cohort_status$run_id,
          lot_cohort_stamp  = as.character(cohort_status$stamp))

  # LOT1 is written before LOT_LONG, so track partial runs.
  # Cleared first, or a second run in one session inherits the first's.
  options(lot_waivers_applied = character(0), lot_codelist_md5 = list(),
          lot_line_criteria = "", lot_lines_built = integer(0))
  check_no_active_run(con, cfg)
  write_build_status(con, cfg, "started")
  # After = FALSE, or this fires after the disconnect above and writes to a
  # closed connection. Registered here, not beside the connection, so a
  # preflight failure still leaves no status row at all.
  #
  # And armed BEFORE clear_run_rows(), not after it. A DELETE that failed - a
  # permission, a lock, a dropped connection - raised with the 'started' row
  # already written and no handler yet registered, so nothing ever wrote
  # 'failed'. The prefix was then held by a run that had ended: every later
  # run refused by check_no_active_run() until someone cleared the row by
  # hand. build_ndmm.R:1247 arms it in this order for the same reason.
  on.exit(if (!isTRUE(getOption("lot_complete", FALSE)))
            try(write_build_status(con, cfg, "failed"), silent = TRUE),
          add = TRUE, after = FALSE)
  options(lot_complete = FALSE)
  # After the status row and after the handler, so a run is marked started
  # whatever this does, and before the first step, so no writer can be reached
  # with the previous attempt's rows still under this run's id.
  clear_run_rows(con, cfg)

  ctx <- phase_codelists(con)
  record_codelist_hashes(con, cfg)
  phase_patient_input(con)
  materialize_cohort_input(con, cohort)
  # The snapshot exists now, so ask again: nothing may have replaced the cohort
  # between the check above and this copy.
  recheck_cohort_build(con, cfg, cohort_status)
  check_claim_ndc(con, cfg)
  phase_mma_map(con, ctx)
  phase_lot1_base(con, ctx)
  phase_sct(con, ctx)
  phase_lot1_sct(con, ctx)
  phase_lot1_end(con, ctx)
  phase_qc(con, ctx)
  check_lot1_invariants(con, cfg)
  phase_persist(con, ctx)

  # LOT1 built these moments ago. Rebuilding them here would re-read the code
  # lists and the cohort table, and nothing establishes that those still hold
  # what LOT1 used - the loader compares a file's hash across one read, not
  # across two phases. LOT2-5 would then be built from a different snapshot
  # than the LOT1 tables beside it, and the run would still reach "complete".
  # One run, one snapshot: stop instead.
  if (!lot_inputs_present(con))
    stop("The views LOT2-5 reads are missing, or the catalogue could not be ",
         "asked. LOT1 built them earlier in this run, so something has ",
         "dropped them or the connection has changed. Rebuilding them here ",
         "would read the code lists and the cohort table again with no ",
         "guarantee they still match what LOT1 used, so this run would mix ",
         "two snapshots. Re-run the build.", call. = FALSE)
  log_msg("Session views from LOT1 are still here.")
  materialize_sct_views(con)
  build_lot2_5(con,
               induction_window_days   = cfg$lot_n_induction_window_days,
               cart_consolidation_days = cfg$cart_consolidation_days,
               sct_tandem_days         = cfg$sct_tandem_days,
               allo_lot_span           = cfg$allo_lot_span,
               max_lot                 = cfg$max_lot,
               apply_cart_induction_rule  = cfg$apply_cart_induction_rule,
               lot1_induction_window_days = cfg$induction_window_days)

  # Validate before deriving: publishing the criteria tables first would leave
  # them behind, built from a LOT_LONG that then failed its checks. Two
  # statements, not one nested call - R would not force the promise until after
  # record_final_counts had altered the table.
  lot_long <- check_lot_long(con, cfg)
  phase_line_criteria(con, cfg)
  # After the criteria layer, not before it: LOT_LONG_FINAL is what downstream
  # reads, and with a truncate criterion it is not LOT_LONG.
  final <- check_lot_final(con, cfg)
  # After the final table is validated: the funnel's last row is that table, so
  # writing it first would publish a funnel ending in numbers no check had
  # accepted.
  phase_lot_attrition(con, cfg)
  run_face_validity(con, cfg)
  record_final_counts(con, cfg, lot_long, final)
  check_run_recorded(con, cfg)
  write_build_status(con, cfg, "complete")
  # Only after the write succeeded. Setting it first meant a failed write left
  # the run marked "started" with on.exit believing it had finished.
  options(lot_complete = TRUE)

  log_msg(SEP)
  log_msg("LOT complete for ", cfg$input_cohort_table, " -> ", cfg$object_prefix, "*")
  written <- lot_run_outputs()
  log_msg("Wrote ", length(written), " tables: ",
          paste(sort(written), collapse = ", "))
  log_msg(SEP)
  invisible(TRUE)
}

# The views LOT2-5 reads. All present means LOT1 ran in this session.
LOT2_5_INPUT_VIEWS <- c("lot_patient_input", "mma_rollup", "permissible_subs",
                        "sct_codelist", "sct_claims_raw", "tx_auto_dates",
                        "tx_allo_cart_dates", "map_stacked", "lot1_sct",
                        "lot1_base_end")

# What a run writes, all prefixed. Two groups, because they answer different
# questions and are named differently.
#
# The fixed names are here as a list rather than derived: this is the
# declaration, and tests/test_runner.R holds it to the names the steps
# actually pass to lot_out(), so a table added to a step without being
# declared fails there rather than appearing unannounced in a schema.
LOT_TABLES <- c(
  # the deliverables
  "LOT_LONG", "LOT_LONG_ALLFLAGS", "LOT_LONG_FINAL", "LOT_ATTRITION",
  "LOT_FACE_VALIDITY",
  # the run's own record
  "LOT_RUN_METADATA", "LOT_CODELIST_METADATA", "LOT_QC_SUMMARY",
  "LOT_BUILD_STATUS",
  # the pinned inputs and the LOT1 working, each written where it is built so
  # that every later read is a scan rather than a re-run of its query
  "LOT_PATIENT_INPUT", "MMA_MED_PROCESSED", "MAP_STACKED",
  "SCT_CLAIMS_RAW", "TX_AUTO_DATES", "TX_ALLO_CART_DATES",
  "LOT1_INDUCTION_MEDS", "LOT1_BASE", "LOT1_SCT", "LOT1_CONTAINS_MTX_REG",
  "LOT1_BASE_END"
)

# Everything a run wrote, fixed names and per-line stage tables together.
# `lines` is the lines LOT2-5 actually built, which build_lot2_5() records -
# the loop stops at the first line with no patients to roll forward, so a run
# configured for five lines need not have written five lines' worth of tables.
lot_run_outputs <- function(lines = getOption("lot_lines_built", integer(0))) {
  perline <- if (length(lines))
    unlist(lapply(lines, function(n)
      vapply(.LOTN_STAGES, function(s) lotn_table(n, s), character(1))),
      use.names = FALSE) else character(0)
  unique(c(LOT_TABLES, perline))
}

# Ask the catalogue, not the data. "SELECT 1 FROM v LIMIT 1" on a lazy view
# runs the view - and three of these are raw CDM scans, so the existence check
# itself would have cost real time.
lot_inputs_present <- function(con) {
  d <- tryCatch(db_q(con, "SHOW VIEWS"), error = function(e) NULL)
  # A catalogue error means the views cannot be confirmed, so say no.
  if (is.null(d) || !all(c("viewName", "isTemporary") %in% names(d))) return(FALSE)
  # SHOW VIEWS lists persistent views as well. LOT1 leaves temporary ones, so a
  # persistent table of the same name elsewhere in the schema is not the view
  # this run built - answering yes to it would be the false positive that
  # stopping was meant to prevent.
  temp <- as.character(d$isTemporary)
  have <- tolower(d$viewName[toupper(temp) %in% c("TRUE", "T")])
  all(tolower(LOT2_5_INPUT_VIEWS) %in% have)
}

# Persist the cohort and repoint the session view, so every later phase reads
# one fixed snapshot rather than a view that re-runs against a live table.
# Then validate the snapshot itself, not just the table it came from.
materialize_cohort_input <- function(con, before) {
  tbl <- materialize(con, "S03b_materialize_cohort_input",
                     view = "lot_patient_input", name = "LOT_PATIENT_INPUT",
                     body = "SELECT * FROM lot_patient_input",
                     qc = "SELECT count(*) AS n_rows, count(DISTINCT PATID) AS n_patients
                           FROM lot_patient_input")

  after <- check_cohort_input(con, tbl)
  # A count change, not proof of identity - a same-size swap passes. The
  # validated snapshot is what makes the run sound; these counts came free.
  if (after$n_rows != before$n_rows || after$n_patients != before$n_patients)
    stop("The cohort changed size between being checked and being pinned: ",
         before$n_rows, " rows / ", before$n_patients, " patients at the ",
         "check, ", after$n_rows, " / ", after$n_patients, " in ", tbl,
         ". Re-run the build against a settled cohort.", call. = FALSE)
  log_msg("Cohort input pinned to ", tbl, " and re-checked")
  invisible(TRUE)
}

# LOT1 leaves these three as views over the raw CDM, and LOT2-5 reads them
# once per line - roughly 8 AUTO aggregates and 20 SCT scans if left lazy.
# sct_claims_raw goes first, so the other two write from a table.
SCT_MATERIALIZE <- list(
  list(view = "sct_claims_raw",     name = "SCT_CLAIMS_RAW"),
  list(view = "tx_auto_dates",      name = "TX_AUTO_DATES"),
  list(view = "tx_allo_cart_dates", name = "TX_ALLO_CART_DATES")
)

materialize_sct_views <- function(con) {
  for (mv in SCT_MATERIALIZE) {
    t0 <- Sys.time()
    materialize(con, paste0("L20_materialize_", tolower(mv$name)),
                view = mv$view, name = mv$name,
                body = glue("SELECT * FROM {mv$view}"),
                qc = glue("SELECT count(*) AS n_rows, count(DISTINCT PATID) AS n_patients
                           FROM {mv$view}"))
    log_msg("  ", mv$name, " materialized in ",
            round(as.numeric(difftime(Sys.time(), t0, units = "secs")), 1), " s")
  }
  log_msg("SCT views materialized; LOT2-5 reads tables, not CDM scans.")
  invisible(TRUE)
}

# The claim side of the NDC contract that ndc_shape and ndc_short put on the
# code list. Both joins pad the claim to eleven the same way, so a ten-digit
# claim NDC has the same layout problem and a canonical code misses it.
# Measured the way the join measures, before any claim is read.
check_claim_ndc <- function(con, cfg) {
  log_msg("Checking claim NDC shape...")
  # Scoped to the cohort and its observation window, like the joins - a whole
  # scan of medical is not worth a shape check.
  # Every nonblank value, including the ones that cannot join: a profile that
  # skipped them would report "all eleven digits" without having looked.
  profile_sql <- function(src, tbl, dt) glue("
    SELECT '{src}' AS SOURCE,
           count(*) AS n_ndc,
           sum(CASE WHEN d = 11 THEN 1 ELSE 0 END) AS n_11,
           sum(CASE WHEN d = 10 THEN 1 ELSE 0 END) AS n_10,
           sum(CASE WHEN d NOT IN (10, 11) THEN 1 ELSE 0 END) AS n_other,
           sum(CASE WHEN v RLIKE '[A-Za-z]' THEN 1 ELSE 0 END) AS n_alpha,
           sum(CASE WHEN d = 0 THEN 1 ELSE 0 END) AS n_nodigit,
           sum(CASE WHEN d > 0 AND digits RLIKE '^0+$' THEN 1 ELSE 0 END) AS n_zero
    FROM (
      SELECT v, digits, length(digits) AS d
      FROM (
        SELECT v, regexp_replace(v, '[^0-9]', '') AS digits
        FROM (
          SELECT cast(t.NDC as string) AS v
          FROM {tbl} t
          INNER JOIN lot_patient_input p ON t.PATID = p.PATID
          WHERE cast(t.NDC as string) IS NOT NULL
            AND trim(cast(t.NDC as string)) <> ''
            AND cast(t.{dt} AS date) >= p.INDEX_DATE
            AND cast(t.{dt} AS date) <= p.OBS_END_DT)))")
  prof <- rbind(
    db_q(con, profile_sql("medical", cdm_src(cfg$tbl_medical), "FST_DT")),
    db_q(con, profile_sql("rx",      cdm_src(cfg$tbl_rx),      "FILL_DT")))
  print(prof)

  detail <- function(d) paste(vapply(seq_len(nrow(d)), function(i) with(d[i, ],
    paste0(SOURCE, ": ", n_ndc, " NDCs, ", n_11, " eleven-digit, ", n_10,
           " ten-digit, ", n_other, " other length, ", n_alpha, " with letters, ",
           n_nodigit, " with no digits, ", n_zero, " all zeros")),
    character(1)), collapse = "; ")

  # Two conditions, named apart the way the code side is. Both are reviewable:
  # these are the CDM's tables, not ours, so there is no code list to correct
  # and a run that could not proceed would have no remedy short of changing the
  # join. What the split buys is that accepting one does not accept the other.
  decide <- function(d, name, msg) {
    if (nrow(d) == 0) return(invisible(FALSE))
    if (!(name %in% codelist_waivers())) stop(msg, call. = FALSE)
    log_msg("WAIVED (", name, "): ", detail(d))
    options(lot_waivers_applied = union(getOption("lot_waivers_applied",
                                                  character(0)), name))
    invisible(TRUE)
  }

  # Cannot be an NDC in any form. 'ABC123' reaches the join as 00000000123 and
  # can match a real code; an underlength numeric does the same. All-zero has
  # eleven digits, so only a count of its own catches it - it is the key a
  # claim with no NDC produces, and bad_ndc stops the same value on the code
  # side.
  # Reported, never gated. ndc_key() gives no key to a value that cannot be an
  # NDC, so it cannot collide with a code - it is a non-match, which is what a
  # join produces. Optum writes NONE or UNK where a medical claim has no NDC;
  # stopping over that asked the operator to approve the vendor's word for null.
  shape <- prof[prof$n_ndc > 0 & (prof$n_alpha > 0 | prof$n_other > 0 |
                                  prof$n_zero > 0), , drop = FALSE]
  if (nrow(shape))
    log_msg("  Claim NDCs that are not eleven digits, and so match nothing: ",
            detail(shape))

  # Ten-digit is a real ambiguity - 4-4-2 against 5-3-2 or 5-4-1 - and it is
  # said once rather than held over the run.
  short <- prof[prof$n_ndc > 0 & prof$n_10 > 0, , drop = FALSE]
  if (nrow(short))
    log_msg("  Ten-digit claim NDCs, padded on the 4-4-2 layout: ", detail(short),
            ". A 5-3-2 or 5-4-1 code pads to a different key; confirm with a ",
            "crosswalk if the count is material.")

  if (nrow(shape) == 0 && nrow(short) == 0)
    log_msg("  OK: Every claim NDC is eleven digits.")
  invisible(TRUE)
}

# One row per run saying whether its outputs belong together. Without it a
# failed run leaves tables that look complete.
# REQUESTED is what the run was given, APPLIED what actually fired - a run can
# ask for a waiver on a condition that never occurs.
#
# STUDY_END picks the quarterly CDM table, and the quarterlies are cumulative.
# Anything that reads these outputs and then goes back to the raw CDM - the
# question scripts do - resolves that suffix from its own setting, so a
# different STUDY_END pairs this run's patients with later claims.
#
# CONTRACT_DEVIATIONS is empty on every contract build. It is here as well as
# in LOT_RUN_METADATA because this is the row downstream reads to decide which
# run owns a prefix's tables.
BUILD_STATUS_COLS <- c(
  RUN_ID = "STRING", INPUT_COHORT_TABLE = "STRING", OBJECT_PREFIX = "STRING",
  STATE = "STRING", STUDY_END = "STRING", CODELIST_WAIVERS_REQUESTED = "STRING",
  CODELIST_WAIVERS_APPLIED = "STRING", CONTRACT_DEVIATIONS = "STRING",
  UPDATED_AT = "TIMESTAMP")

# CREATE TABLE IF NOT EXISTS does nothing to a table an earlier run left, so a
# column added to a *_COLS list reaches a fresh prefix and no other, and the
# INSERT naming it fails. Each table is created and then brought up to its list.
#
# Look before adding - ADD COLUMNS on a column that exists is an error - and
# treat an unreadable DESCRIBE as no answer rather than as a table with no
# columns, or this would try to add every column to a table that has them all.
lot_ensure_cols <- function(con, tbl, spec) {
  have <- tryCatch({
    d  <- db_q(con, glue("DESCRIBE {tbl}"))
    cn <- intersect(c("col_name", "COL_NAME", "name", "NAME"), names(d))
    if (length(cn)) toupper(trimws(as.character(d[[cn[1]]]))) else character(0)
  }, error = function(e) character(0))
  if (!length(have)) return(invisible(FALSE))
  for (m in setdiff(names(spec), have)) {
    tryCatch({
      db_exec(con, glue("ALTER TABLE {tbl} ADD COLUMNS ({m} {spec[[m]]})"))
      log_msg("  schema evolution on ", tbl, ": added ", m)
    }, error = function(e) {
      # Every column here is named in the INSERT that follows, so one that
      # could not be added is a failure now rather than a surprise later.
      if (!grepl("already exists|AlreadyExists|FIELD_ALREADY_EXISTS",
                 conditionMessage(e), ignore.case = TRUE))
        stop("Could not add column ", m, " to ", tbl, ": ", conditionMessage(e),
             call. = FALSE)
    })
  }
  invisible(TRUE)
}

write_build_status <- function(con, cfg, state) {
  tbl  <- lot_out("LOT_BUILD_STATUS")
  cols <- names(BUILD_STATUS_COLS)
  db_exec(con, glue("CREATE TABLE IF NOT EXISTS {tbl} (",
                    paste(cols, BUILD_STATUS_COLS, collapse = ", "), ")"))

  lot_ensure_cols(con, tbl, BUILD_STATUS_COLS)

  requested <- paste(codelist_waivers(), collapse = "|")
  # Set by phase_codelists when it waives something. Empty at "started", and on
  # a failure before the code lists ran.
  applied <- paste(getOption("lot_waivers_applied", character(0)), collapse = "|")
  deviations <- paste(getOption("lot_contract_deviations", character(0)),
                      collapse = "|")
  vals <- c(RUN_ID                     = glue("'{run_id}'"),
            INPUT_COHORT_TABLE         = glue("'{cfg$input_cohort_table}'"),
            OBJECT_PREFIX              = glue("'{cfg$object_prefix}'"),
            STATE                      = glue("'{state}'"),
            STUDY_END                  = glue("'{cfg$study_end}'"),
            CODELIST_WAIVERS_REQUESTED = glue("'{requested}'"),
            CODELIST_WAIVERS_APPLIED   = glue("'{applied}'"),
            # Set by check_lot_contract, so it is already there at "started" -
            # a run that deviates is marked from its first status row, not
            # only once it finishes.
            CONTRACT_DEVIATIONS        = glue("'{deviations}'"),
            UPDATED_AT                 = "current_timestamp()")
  # One declaration drives the CREATE, the upgrade and the INSERT, so they
  # cannot drift apart again - a column added to BUILD_STATUS_COLS with no
  # value here stops the build rather than reaching the warehouse.
  stopifnot(identical(names(vals), cols))
  # One unit: retrying the INSERT alone would leave this run two status rows.
  db_replace(con,
    glue("DELETE FROM {tbl} WHERE RUN_ID = '{run_id}'"),
    glue("INSERT INTO {tbl} ({paste(cols, collapse = ', ')}) ",
         "VALUES ({paste(vals, collapse = ', ')})"))
  log_msg("Build status: ", state, " (run ", run_id, ")")
  invisible(TRUE)
}

# A re-run in the same session keeps run_id - it is fixed when config_lot.R is
# sourced - so an earlier attempt's rows would stay under this run's id and
# describe work this run did not do. Each writer clears its own rows, but only
# when it is reached: a run that fails before one of them leaves the previous
# attempt's rows looking like this one's. Cleared up front instead.
#
# The tables need not exist yet, and on a first run they do not, so a delete
# that cannot find its table is not a failure. TABLE_OR_VIEW_NOT_FOUND is one
# of with_retry's permanent errors, so this does not sit through four attempts.
RUN_SCOPED_TABLES <- c("LOT_RUN_METADATA", "LOT_QC_SUMMARY",
                       "LOT_CODELIST_METADATA", "LOT_ATTRITION")

# A missing table is fine. Anything else is not: a permission, a lock or a
# malformed table stops the delete, and swallowing that leaves an earlier
# attempt's rows under this run's id - a re-run keeps its run id - describing
# work this run did not do. Whoever reads that metadata directly has nothing
# telling them it is stale.
clear_run_rows <- function(con, cfg) {
  bad <- character(0)
  for (t in RUN_SCOPED_TABLES) {
    tbl <- lot_out(t)
    err <- tryCatch({
      db_exec(con, glue("DELETE FROM {tbl} WHERE RUN_ID = '{run_id}'")); NULL
    }, error = function(e) conditionMessage(e))
    if (!is.null(err) &&
        !grepl("TABLE_OR_VIEW_NOT_FOUND|Table or view not found", err,
               ignore.case = TRUE))
      bad <- c(bad, paste0(tbl, ": ", err))
  }
  # All of them, then stop once: whatever stopped one delete has usually
  # stopped the others, and naming one at a time would take three runs to
  # find out.
  if (length(bad))
    stop("Could not clear run ", run_id, " from:\n  ",
         paste(bad, collapse = "\n  "),
         "\nA re-run keeps its run id, so rows an earlier attempt wrote under ",
         "it are still there and would be read as this run's.", call. = FALSE)
  invisible(TRUE)
}

# Output names carry no run id, and several phases repoint a session view at a
# shared table they have just replaced. Two runs on one prefix interleave: the
# second replaces a table the first has a view on, and the first reads the
# second's rows from there. Both can still reach "complete", outputs mixed.
#
# Different prefixes are safe - that is how two cohorts run at once. This
# refuses the same-prefix case.
#
# A check, not a lock: two runs starting at the same moment both pass it. It
# catches the case worth catching - starting a second run while one is going.
check_no_active_run <- function(con, cfg) {
  # Not excluding this run's own id. run_id comes from DOMINO_RUN_ID, so a
  # second attempt in one Domino execution shares it - and excluding it hid the
  # collision most worth catching. Safe because this runs before
  # write_build_status marks this attempt started, so a 'started' row under
  # this id is always another attempt's.
  d <- tryCatch(db_q(con, glue("
    SELECT RUN_ID, UPDATED_AT FROM {lot_out('LOT_BUILD_STATUS')}
    WHERE OBJECT_PREFIX = '{cfg$object_prefix}'
      AND STATE = 'started'")), error = function(e) e)
  ignoring <- identical(toupper(Sys.getenv("LOT_IGNORE_ACTIVE_RUN", unset = "")),
                        "TRUE")
  # No table is the first run on this prefix. Any other failure is this check
  # not running, which is not this check passing - clear_run_rows() below draws
  # the same line.
  if (inherits(d, "condition")) {
    if (missing_object_error(d)) return(invisible(TRUE))
    # The same override the found-a-run branch takes, or the message below
    # names a way out that does not exist.
    if (ignoring) {
      log_msg("WARNING: ", lot_out("LOT_BUILD_STATUS"), " could not be read (",
              conditionMessage(d), ") and LOT_IGNORE_ACTIVE_RUN is set, so ",
              "nothing checked whether another run is building this prefix.")
      return(invisible(TRUE))
    }
    stop("Could not read ", lot_out("LOT_BUILD_STATUS"), " to check for a run ",
         "already building prefix ", cfg$object_prefix, ": ",
         conditionMessage(d),
         "\nThis is the check that stops two runs sharing one prefix, and it ",
         "did not run. It is not a first run - a missing table says so ",
         "specifically, and this did not. Fix the read and start again, or set ",
         "LOT_IGNORE_ACTIVE_RUN=TRUE if you know no other run is going.",
         call. = FALSE)
  }
  if (!nrow(d)) return(invisible(TRUE))
  who <- paste(d$RUN_ID, collapse = ", ")
  if (ignoring) {
    log_msg("WARNING: run(s) ", who, " are marked started on prefix ",
            cfg$object_prefix, " and LOT_IGNORE_ACTIVE_RUN is set. If they are ",
            "still running, both sets of outputs will be wrong.")
    return(invisible(TRUE))
  }
  stop("Run(s) ", who, " are already building prefix ", cfg$object_prefix,
       ". Every output name is the prefix plus the table, so two runs would ",
       "replace each other's tables while the other is reading them, and both ",
       "could still finish. Use a different prefix, or wait. If those runs are ",
       "not actually running - a killed process leaves 'started' behind - set ",
       "LOT_IGNORE_ACTIVE_RUN=TRUE.",
       # Said out loud, or a shared DOMINO_RUN_ID reads as self-blocking.
       if (any(as.character(d$RUN_ID) == run_id))
         paste0("\nOne of those is this run's own id (", run_id, "), which a ",
                "second attempt in the same Domino execution shares. This ",
                "attempt has not written its own row yet, so that one is ",
                "another attempt still marked started.") else "",
       call. = FALSE)
}

# The QC phase reports these and carries on - it prints "** BUG **" and the run
# still finishes. They are not judgement calls: each one is impossible unless
# something earlier is wrong, so re-run them here where a breach stops the
# build. The distributions and coverage tables in phase_qc stay informational.
LOT1_INVARIANTS <- list(
  list(name = "MAP ends before it starts",
       sql = "SELECT count(*) AS n FROM map_stacked WHERE MAP_END_DT < MAP_START_DT"),
  list(name = "MAP end is not the later runout",
       sql = "SELECT count(*) AS n FROM map_stacked
              WHERE MAP_END_DT <> greatest(
                coalesce(MAP_RX_RUNOUT_DT, cast('1900-01-01' as date)),
                coalesce(MAP_MED_RUNOUT_DT, cast('1900-01-01' as date)))
                AND MAP_END_DT IS NOT NULL"),
  list(name = "LOT1 ends after observation",
       sql = "SELECT count(*) AS n FROM lot1_base_end lb
              INNER JOIN lot_patient_input p ON lb.PATID = p.PATID
              WHERE lb.LOT1_BASE_END_DT > p.OBS_END_DT"),
  # phase_qc reports this one as INVESTIGATE inside a tryCatch, so a run could
  # finish with it. Every end-date branch is bounded by OBS_END_DT, so it is
  # impossible unless something earlier is wrong.
  list(name = "SCT end date past observation",
       sql = "SELECT count(*) AS n FROM lot1_sct sct
              INNER JOIN lot_patient_input p ON sct.PATID = p.PATID
              WHERE sct.LOT1_TX_ENDDATE > p.OBS_END_DT"),
  list(name = "AUTO transplant both tandem and single",
       sql = "SELECT count(*) AS n FROM lot1_sct
              WHERE LOT1_SCT_AUTO_TAND_FLG = 1 AND LOT1_SCT_AUTO_SING_FLG = 1"),
  list(name = "AUTO transplant before LOT1 started",
       sql = "SELECT count(*) AS n FROM lot1_sct sct
              INNER JOIN lot1_base lb ON sct.PATID = lb.PATID
              WHERE sct.LOT1_TX_AUTO_DT_1 IS NOT NULL
                AND sct.LOT1_TX_AUTO_DT_1 < lb.LOT1_START_DT")
)

check_lot1_invariants <- function(con, cfg) {
  bad <- character(0)
  for (iv in LOT1_INVARIANTS) {
    # No tryCatch: a check that cannot run is not a check that passed.
    n <- db_q(con, iv$sql)$n
    if (is.na(n) || n > 0) bad <- c(bad, paste0(iv$name, ": ", n))
  }
  if (length(bad))
    stop("LOT1 is internally inconsistent:\n  ", paste(bad, collapse = "\n  "),
         call. = FALSE)
  log_msg("LOT1 invariants OK (", length(LOT1_INVARIANTS), " checked)")
  invisible(TRUE)
}

# 08_persist.R writes the metadata and QC summary inside a tryCatch, so a
# failure there only logs a warning. Check the row actually arrived - a run
# with no record of how it was configured cannot be validated later.
# ---- Face validity ----------------------------------------------------------
#
# The invariants ask whether the output is consistent. These ask whether it
# looks like myeloma - transplants in late lines, CAR-T in first line, a median
# line of three days. Those come from a code list matching the wrong thing or a
# date rule firing early, and nothing else here would catch them.
#
# The number is the point, not the verdict: every check records what it found
# either way. The bands are wide, catching gross failure rather than nuance,
# and none is a published benchmark.
#
# Reported, not fatal - an unusual cohort can fail one honestly.
# FACE_VALIDITY_FATAL=TRUE makes them stop.
FACE_VALIDITY <- list(
  list(name = "auto_sct_is_early",
       what = "% of lines containing an autologous transplant that are LOT1 or LOT2",
       # Transplant is induction consolidation in newly-diagnosed myeloma. If
       # most of them are late lines, the SCT dates or the line numbering are
       # wrong.
       #
       # LOT_TX_AUTO_FLG, not LOT_START_TYPE: every LOT1 row is projected as
       # 'MED', so an AUTO inside a drug-started first line - the normal case -
       # carries 'MED'. Keying on the start type would see only transplants
       # that BEGIN a later line and report transplant as systematically late.
       lo = 50, hi = 100,
       sql = "SELECT round(100.0 * sum(CASE WHEN LOT_NUM <= 2 THEN 1 ELSE 0 END)
                           / nullif(count(*), 0), 1) AS v
              FROM {t}
              WHERE LOT_TX_AUTO_FLG = 1 OR LOT_START_TYPE = 'SCT_AUTO'"),

  list(name = "cart_is_late",
       what = "% of patients whose CAR-T falls at LOT3 or later",
       # CAR-T is a later-line therapy. In a first-line cohort it should be
       # uncommon and late; CAR-T in LOT1 means the trigger fired on the wrong
       # claim.
       # LOT_CART_LOT_FLG is 0 on every LOT1 row and LOT1 always starts 'MED',
       # so a CAR-T during or closing a first line shows only in its end
       # reason. The flags alone would miss it.
       # Per patient, because one CAR-T is two rows - the line it closes and
       # the line it starts - and counting rows makes a single CAR-T at LOT3
       # read 50%. The line it STARTED wins.
       lo = 50, hi = 100,
       sql = "WITH cart AS (
                SELECT PATID,
                       min(CASE WHEN LOT_START_TYPE = 'CART' OR LOT_CART_LOT_FLG = 1
                                THEN LOT_NUM END)                       AS started_at,
                       min(CASE WHEN LOT_BASE_END_REASON IN ('SCT_CART', 'CART_INIT')
                                THEN LOT_NUM END)                       AS closed_at
                FROM {t} GROUP BY PATID)
              SELECT round(100.0 * sum(CASE WHEN coalesce(started_at, closed_at) >= 3
                                            THEN 1 ELSE 0 END)
                           / nullif(count(*), 0), 1) AS v
              FROM cart
              WHERE started_at IS NOT NULL OR closed_at IS NOT NULL"),

  list(name = "allo_sct_is_rare",
       what = "% of patients with any allogeneic transplant line",
       # Allogeneic transplant is uncommon in myeloma. A high share points at a
       # code list matching something else.
       # Same shape as CAR-T: an allo inside LOT1 leaves the start type 'MED'
       # and LOT_ALLO_LOT_FLG 0, and shows only in the end reason.
       lo = 0, hi = 5,
       sql = "SELECT round(100.0 * count(DISTINCT CASE
                             WHEN LOT_START_TYPE = 'SCT_ALLO'
                               OR LOT_ALLO_LOT_FLG = 1
                               OR LOT_BASE_END_REASON = 'SCT_ALLO'
                             THEN PATID END)
                           / nullif(count(DISTINCT PATID), 0), 2) AS v
              FROM {t}"),

  list(name = "later_lines_start_on_a_drug",
       what = "% of LOT2+ lines started by a medication rather than a procedure",
       # Most lines begin because a regimen changed, not because a transplant or
       # CAR-T happened. If procedures are starting most later lines, the
       # trigger rules are firing on the wrong events.
       #
       # LOT2 onward only. Asking this of LOT1 would be a tautology: every LOT1
       # row is projected with LOT_START_TYPE = 'MED', so the answer is 100% for
       # any non-empty output and the check could never fail.
       lo = 60, hi = 100,
       sql = "SELECT round(100.0 * sum(CASE WHEN LOT_START_TYPE = 'MED' THEN 1 ELSE 0 END)
                           / nullif(count(*), 0), 1) AS v
              FROM {t} WHERE LOT_NUM >= 2"),

  list(name = "lot1_duration_is_plausible",
       what = "median LOT1 length in days",
       # Wide on purpose. This catches an end-date rule firing on the start
       # date, or never firing at all - not a view about how long myeloma
       # treatment lasts.
       # LOT_BASE_LENGTH, not datediff. The engine defines length inclusively -
       # datediff(end, start) + 1 - so computing it here without the +1 reports
       # one day less than the number stored beside it, and a true 30-day median
       # would read 29 and trip the lower band. Read the column it already has.
       lo = 30, hi = 1500,
       sql = "SELECT percentile_approx(LOT_BASE_LENGTH, 0.5) AS v
              FROM {t} WHERE LOT_NUM = 1 AND LOT_BASE_LENGTH IS NOT NULL"),

  list(name = "regimens_are_not_fragmented",
       what = "% of LOT1 patients covered by the ten most common regimens",
       # Myeloma first-line treatment is concentrated in a few regimens. If the
       # top ten cover almost nobody, the regimen string is being built from
       # too many parts and every patient looks unique.
       lo = 25, hi = 100,
       sql = "WITH top10 AS (
                SELECT LOT_BASE_MEDS, count(DISTINCT PATID) AS n
                FROM {t} WHERE LOT_NUM = 1 AND LOT_BASE_MEDS IS NOT NULL
                GROUP BY LOT_BASE_MEDS ORDER BY n DESC LIMIT 10)
              SELECT round(100.0 * (SELECT sum(n) FROM top10)
                           / nullif((SELECT count(DISTINCT PATID) FROM {t}
                                     WHERE LOT_NUM = 1), 0), 1) AS v")
)

FACE_VALIDITY_COLS <- c(RUN_ID = "STRING", CHECK_NAME = "STRING",
                        WHAT = "STRING", VALUE = "DOUBLE",
                        EXPECT_LO = "DOUBLE", EXPECT_HI = "DOUBLE",
                        VERDICT = "STRING", RECORDED_AT = "TIMESTAMP")

run_face_validity <- function(con, cfg) {
  tbl <- lot_out("LOT_FACE_VALIDITY")
  cols <- names(FACE_VALIDITY_COLS)
  db_exec(con, glue("CREATE TABLE IF NOT EXISTS {tbl} (",
                    paste(cols, FACE_VALIDITY_COLS, collapse = ", "), ")"))
  lot_ensure_cols(con, tbl, FACE_VALIDITY_COLS)
  final <- lot_out("LOT_LONG_FINAL")
  rows <- character(0)
  off  <- character(0)
  log_msg("Face validity (reported, not fatal):")
  for (fv in FACE_VALIDITY) {
    v <- tryCatch(as.numeric(db_q(con, gsub("{t}", final, fv$sql, fixed = TRUE))$v[1]),
                  error = function(e) NA_real_)
    verdict <- if (is.na(v)) "NO VALUE"
               else if (v >= fv$lo && v <= fv$hi) "ok"
               else "LOOK"
    log_msg("  ", format(verdict, width = 8), fv$what, ": ",
            if (is.na(v)) "no rows" else format(v, big.mark = ","),
            "  (expect ", fv$lo, "-", fv$hi, ")")
    # No value is not a pass. A query that errored, a column that moved and a
    # genuinely empty denominator all land here and look identical, so it is
    # reported like any other check that did not come back clean.
    if (verdict %in% c("LOOK", "NO VALUE")) off <- c(off, fv$name)
    rows <- c(rows, glue("('{run_id}', '{fv$name}', {sql_text(fv$what)}, ",
                         "{if (is.na(v)) 'NULL' else v}, {fv$lo}, {fv$hi}, ",
                         "'{verdict}', current_timestamp())"))
  }
  db_replace(con,
    glue("DELETE FROM {tbl} WHERE RUN_ID = '{run_id}'"),
    glue("INSERT INTO {tbl} ({paste(cols, collapse = ', ')}) VALUES ",
         paste(rows, collapse = ", ")))
  if (length(off)) {
    msg <- paste0(length(off), " face-validity check(s) outside the expected ",
                  "band or with no value: ", paste(off, collapse = ", "),
                  ". These are plausibility bands, not published benchmarks - ",
                  "read ", tbl, " and decide whether the number is wrong or the ",
                  "band is.")
    if (isTRUE(cfg$face_validity_fatal))
      stop(msg, call. = FALSE)
    log_msg("  WARNING: ", msg)
  }
  invisible(off)
}

check_run_recorded <- function(con, cfg) {
  # Exactly one row, not at least one. 08_persist writes this table with a
  # DELETE and an INSERT as separately retried statements, so an INSERT that
  # reached the warehouse with its answer lost leaves two rows. Caught here
  # rather than in the writer.
  meta_tbl <- lot_out("LOT_RUN_METADATA")
  n <- tryCatch(db_q(con, glue(
         "SELECT count(*) AS n FROM {meta_tbl} WHERE RUN_ID = '{run_id}'"))$n,
       error = function(e) 0L)
  if (is.na(n) || n < 1)
    stop("This run left no row in ", meta_tbl, ". The outputs exist but ",
         "nothing records how they were built.", call. = FALSE)
  if (n > 1)
    stop(meta_tbl, " has ", n, " rows for this run, so which one describes these ",
         "outputs is not decidable. A retried INSERT has doubled them.",
         call. = FALSE)

  # The same fixed set of checks runs every time, so a CHECK_NAME appearing
  # twice is a doubled write rather than a second finding.
  qc_tbl <- lot_out("LOT_QC_SUMMARY")
  q <- tryCatch(db_q(con, glue(
         "SELECT count(*) AS n, count(DISTINCT CHECK_NAME) AS k
          FROM {qc_tbl} WHERE RUN_ID = '{run_id}'")),
       error = function(e) data.frame(n = 0L, k = 0L))
  if (is.na(q$n) || q$n < 1)
    stop("This run left no row in ", qc_tbl, ". The outputs exist but ",
         "nothing records how they were built.", call. = FALSE)
  if (q$n != q$k)
    stop(qc_tbl, " has ", q$n, " rows for ", q$k, " checks in this run. A retried ",
         "INSERT has doubled them.", call. = FALSE)
  # One row is not the contract: the build reads four code lists and every one
  # has to be accounted for. "At least one row" would pass a run that recorded
  # a single file, which is the shape a partial write leaves behind.
  cl_tbl <- lot_out("LOT_CODELIST_METADATA")
  c4 <- tryCatch(db_q(con, glue(
         "SELECT count(*) AS n, count(DISTINCT CODELIST_FILE) AS k
          FROM {cl_tbl}
          WHERE RUN_ID = '{run_id}' AND MD5 RLIKE '^[0-9a-f]{{32}}$'
            AND CODELIST_FILE IN ({paste0(\"'\", CODELIST_FILES, \"'\", collapse = ', ')})")),
       error = function(e) data.frame(n = 0L, k = 0L))
  if (is.na(c4$k) || c4$k != length(CODELIST_FILES))
    stop("This run recorded ", if (is.na(c4$k)) 0 else c4$k, " of ",
         length(CODELIST_FILES), " code lists in ", cl_tbl,
         ". The outputs exist but nothing says in full which lists built them.",
         call. = FALSE)
  if (c4$n != c4$k)
    stop(cl_tbl, " has ", c4$n, " rows for ", c4$k, " code lists in this run. A ",
         "retried INSERT has doubled them.", call. = FALSE)

  # The row is written by phase_persist, before LOT2-5 exists, so a row alone
  # says only that LOT1 ran. record_final_counts fills the rest in.
  n <- tryCatch(db_q(con, glue(
         "SELECT count(*) AS n FROM {meta_tbl}
          WHERE RUN_ID = '{run_id}' AND N_LOT_LONG_ROWS IS NOT NULL
            AND N_LOT_FINAL_ROWS IS NOT NULL"))$n,
       error = function(e) 0L)
  if (is.na(n) || n < 1)
    stop("The metadata row for this run has no LOT_LONG counts. It describes ",
         "LOT1 only, so nothing records what LOT2-5 produced.", call. = FALSE)
  log_msg("Run recorded in LOT_RUN_METADATA and LOT_QC_SUMMARY")
  invisible(TRUE)
}

# Which version of each code list built these tables. The run log says so too,
# but a log is a separate artefact - filed away from the tables, or lost. One
# row per file per run, written once the lists have passed their checks and
# before any claim is read - so a run that fails later still records what it
# was reading, and one that fails inside those checks records nothing.
# RECORDED_AT is the warehouse clock at the insert.
CODELIST_METADATA_COLS <- c(RUN_ID = "STRING", CODELIST_FILE = "STRING",
                            MD5 = "STRING", N_ROWS = "BIGINT",
                            RECORDED_AT = "TIMESTAMP")

record_codelist_hashes <- function(con, cfg) {
  seen <- getOption("lot_codelist_md5", list())
  missing <- setdiff(CODELIST_FILES, names(seen))
  if (length(missing))
    stop("No hash recorded for ", paste(missing, collapse = ", "),
         ". Every code list this build reads has to be accounted for.",
         call. = FALSE)
  tbl  <- lot_out("LOT_CODELIST_METADATA")
  cols <- names(CODELIST_METADATA_COLS)
  db_exec(con, glue("CREATE TABLE IF NOT EXISTS {tbl} (",
                    paste(cols, CODELIST_METADATA_COLS, collapse = ", "), ")"))

  # CREATE TABLE IF NOT EXISTS does nothing to a table an earlier run left
  # behind, and the INSERT below names its columns - so one this table lacks
  # fails the run rather than being filled positionally.
  #
  # Stricter than the shared helper on one point, deliberately: this table is
  # the record of WHICH code lists a cohort was built from, so a DESCRIBE that
  # cannot be read stops rather than carrying on unmigrated. lot_ensure_cols()
  # treats the same silence as "leave it alone", which is right for a status
  # row and not for this.
  if (!length(tryCatch({
        d  <- db_q(con, glue("DESCRIBE {tbl}"))
        cn <- intersect(c("col_name", "COL_NAME", "name", "NAME"), names(d))
        if (length(cn)) as.character(d[[cn[1]]]) else character(0)
      }, error = function(e) character(0))))
    stop("Cannot read the columns of ", tbl, ", so the code list hashes cannot ",
         "be recorded.", call. = FALSE)
  lot_ensure_cols(con, tbl, CODELIST_METADATA_COLS)

  vals <- vapply(CODELIST_FILES, function(f) glue(
    "('{run_id}', '{f}', '{seen[[f]]$md5}', {seen[[f]]$n_rows}, current_timestamp())"),
    character(1), USE.NAMES = FALSE)
  # One unit: retrying the INSERT alone would record each file twice.
  db_replace(con,
    glue("DELETE FROM {tbl} WHERE RUN_ID = '{run_id}'"),
    glue("INSERT INTO {tbl} ({paste(cols, collapse = ', ')}) VALUES ",
         paste(vals, collapse = ", ")))
  log_msg("Recorded ", length(CODELIST_FILES), " code list hashes in ", tbl)
  invisible(TRUE)
}

# LOT_RUN_METADATA is written by phase_persist, before LOT2-5, so its counts
# stop at LOT1. The totals here come from check_lot_long, which has just
# counted them and passed, so nothing is scanned for twice.
#
# Two columns rather than one per setting: CODE_MD5 fingerprints the R that
# ran, CONTRACT_SETTINGS carries the settings.
#
# A hash of the sources rather than a version-control revision: this folder
# is copied into Domino to run, where there may be nothing to ask, and the
# hash describes the code that actually executed either way.
code_fingerprint <- function(here) {
  # radix, not the default: character sort is collation-sensitive, and a hash
  # meant to say "the same code" must not depend on the machine's locale.
  fs <- sort(c(list.files(file.path(here, "R"), "\\.R$", full.names = TRUE,
                          recursive = TRUE),
               file.path(here, "build.R")), method = "radix")
  fs <- fs[file.exists(fs)]
  if (!length(fs)) return(NA_character_)
  tmp <- tempfile(); on.exit(unlink(tmp), add = TRUE)
  writeLines(unlist(lapply(fs, readLines, warn = FALSE)), tmp)
  unname(tools::md5sum(tmp))
}

# Sorted, so two runs with the same settings produce the same string and it can
# be compared as one value.
#
# Read from the RUN's config, not from CONTRACT. On every contract build the
# two are identical - check_lot_contract has just proved it - so this changes
# nothing for a production run. On an overridden build it is the difference
# between recording what the run did and recording what it was supposed to do,
# and a metadata row that says the second is worse than none: the dashboard
# reads max_lot out of this string to decide how many panels a run has.
contract_settings <- function(cfg) {
  k <- sort(names(CONTRACT), method = "radix")
  val <- function(key) {
    v <- if (!is.null(cfg[[key]])) cfg[[key]] else CONTRACT[[key]]
    as.character(v)[1]
  }
  paste(paste0(k, "=", vapply(k, val, character(1))), collapse = "|")
}

# STUDY_START and STUDY_END are columns of their own because they are no longer
# in CONTRACT, so CONTRACT_SETTINGS does not carry them - and the window decides
# which quarterly tables the run read, which is the first thing anyone comparing
# two runs needs to know.
FINAL_METADATA_COLS <- c(N_LOT_LONG_ROWS = "BIGINT",
                         N_LOT_LONG_PATIENTS = "BIGINT",
                         LOT_LONG_BY_LINE = "STRING",
                         N_LOT_FINAL_ROWS = "BIGINT",
                         N_LOT_FINAL_PATIENTS = "BIGINT",
                         CODE_MD5 = "STRING", CONTRACT_SETTINGS = "STRING",
                         STUDY_START = "STRING", STUDY_END = "STRING",
                         LINE_CRITERIA_APPLIED = "STRING",
                         # Which cohort run these lines were built from. The
                         # cohort table carries no run id, so this is the only
                         # link between a set of lines and the cohort behind
                         # them. NULL when no status table was found.
                         COHORT_RUN_ID = "STRING",
                         # A re-run keeps its run id, so the id alone does not
                         # name an attempt. This moves every time.
                         COHORT_STAMP = "STRING")

record_final_counts <- function(con, cfg, counts, final) {
  tbl <- lot_out("LOT_RUN_METADATA")
  have <- tryCatch({
    d  <- db_q(con, glue("DESCRIBE {tbl}"))
    cn <- intersect(c("col_name", "COL_NAME", "name", "NAME"), names(d))
    if (length(cn)) toupper(trimws(as.character(d[[cn[1]]]))) else character(0)
  }, error = function(e) character(0))
  # phase_persist creates the table without these, so the first run on a given
  # schema adds them and later ones find them. No answer means DESCRIBE failed,
  # not an empty table - adding blind would error on the first column.
  if (!length(have))
    stop("Cannot read the columns of ", tbl, ", so the LOT_LONG counts cannot ",
         "be recorded.", call. = FALSE)
  add <- setdiff(names(FINAL_METADATA_COLS), have)
  if (length(add)) {
    db_exec(con, glue("ALTER TABLE {tbl} ADD COLUMNS (",
                      paste(add, FINAL_METADATA_COLS[add], collapse = ", "), ")"))
    log_msg("  Metadata schema evolution: added ", paste(add, collapse = ", "))
  }

  by_line <- db_q(con, glue("
    SELECT LOT_NUM, count(*) AS n FROM {lot_out('LOT_LONG')}
    GROUP BY LOT_NUM ORDER BY LOT_NUM"))
  dist <- paste(paste0(by_line$LOT_NUM, ":",
                       vapply(by_line$n, sql_count, character(1))), collapse = "|")
  db_exec(con, glue("
    UPDATE {tbl}
       SET N_LOT_LONG_ROWS = {sql_count(counts$n_rows)},
           N_LOT_LONG_PATIENTS = {sql_count(counts$n_patients)},
           LOT_LONG_BY_LINE = '{dist}',
           N_LOT_FINAL_ROWS = {sql_count(final$n_rows)},
           N_LOT_FINAL_PATIENTS = {sql_count(final$n_patients)},
           CODE_MD5 = {sql_text(cfg$code_md5)},
           CONTRACT_SETTINGS = {sql_text(contract_settings(cfg))},
           COHORT_RUN_ID = {sql_text(getOption('lot_cohort_run_id', NA_character_))},
           COHORT_STAMP = {sql_text(getOption('lot_cohort_stamp', NA_character_))},
           STUDY_START = {sql_text(cfg$study_start)},
           STUDY_END = {sql_text(cfg$study_end)},
           LINE_CRITERIA_APPLIED = {sql_text(getOption('lot_line_criteria', ''))}
     WHERE RUN_ID = '{run_id}'"))
  log_msg("Recorded LOT_LONG: ", counts$n_rows, " lines for ",
          counts$n_patients, " patients (", dist, "); LOT_LONG_FINAL: ",
          final$n_rows, " lines for ", final$n_patients, " patients")
  invisible(TRUE)
}

# LOT_LONG invariants. These are structural, not judgement calls, so a breach
# stops the build rather than printing INVESTIGATE.
check_lot_long <- function(con, cfg) {
  tbl <- lot_out("LOT_LONG")
  # SUM is NULL on an empty table. Coalesce the validation counts.
  q <- db_q(con, glue("
    SELECT count(*) AS n_rows,
           count(DISTINCT PATID) AS n_patients,
           coalesce(sum(CASE WHEN LOT_START_DT IS NULL THEN 1 ELSE 0 END), 0) AS n_null_start,
           coalesce(sum(CASE WHEN LOT_BASE_END_DT IS NULL THEN 1 ELSE 0 END), 0) AS n_null_end,
           coalesce(sum(CASE WHEN LOT_BASE_END_DT < LOT_START_DT THEN 1 ELSE 0 END), 0) AS n_end_before_start,
           coalesce(sum(CASE WHEN LOT_NUM < 1 OR LOT_NUM > {cfg$max_lot} THEN 1 ELSE 0 END), 0) AS n_bad_lot_num
    FROM {tbl}"))
  # Nothing else is worth saying about an empty table, and stopping here means
  # neither the four queries below nor the counts above run on one - so a lost
  # coalesce cannot turn this into an R error either.
  if (q$n_rows == 0) stop(tbl, " is not usable: it is empty", call. = FALSE)
  d <- db_q(con, glue("
    SELECT count(*) AS n FROM (
      SELECT PATID, LOT_NUM FROM {tbl} GROUP BY PATID, LOT_NUM HAVING count(*) > 1)"))$n
  # A line has to start after the previous one ended. Every LOT_N candidate is
  # taken strictly after PREV_END_DT, so anything else means the chain broke.
  seq_bad <- db_q(con, glue("
    SELECT count(*) AS n FROM (
      SELECT LOT_START_DT,
             lag(LOT_BASE_END_DT) OVER (PARTITION BY PATID ORDER BY LOT_NUM) AS prev_end
      FROM {tbl})
    WHERE prev_end IS NOT NULL AND LOT_START_DT <= prev_end"))$n
  # And no line may run past the patient's observation. Every branch of the
  # end-date rule is bounded by OBS_END_DT, so a breach is a real defect.
  past_obs <- db_q(con, glue("
    SELECT count(*) AS n
    FROM {tbl} l
    INNER JOIN lot_patient_input p ON l.PATID = p.PATID
    WHERE l.LOT_BASE_END_DT > p.OBS_END_DT"))$n
  g <- db_q(con, glue("
    SELECT count(*) AS n FROM (
      SELECT PATID, min(LOT_NUM) AS lo, max(LOT_NUM) AS hi, count(DISTINCT LOT_NUM) AS k
      FROM {tbl} GROUP BY PATID HAVING lo <> 1 OR k <> hi - lo + 1)"))$n
  bad <- character(0)
  if (d > 0)                   bad <- c(bad, paste0(d, " duplicate (PATID, LOT_NUM)"))
  # First, because a null date is why every other check here would pass. All
  # of them compare dates, and a comparison with NULL is unknown rather than
  # true, so a line with no start or no end slips through the lot of them.
  if (q$n_null_start > 0)      bad <- c(bad, paste0(q$n_null_start, " lines with no start date"))
  if (q$n_null_end > 0)        bad <- c(bad, paste0(q$n_null_end, " lines with no end date"))
  if (q$n_end_before_start > 0) bad <- c(bad, paste0(q$n_end_before_start, " lines end before they start"))
  if (q$n_bad_lot_num > 0)     bad <- c(bad, paste0(q$n_bad_lot_num, " lines outside 1..", cfg$max_lot))
  if (g > 0)                   bad <- c(bad, paste0(g, " patients whose lines do not run 1..n"))
  if (seq_bad > 0)             bad <- c(bad, paste0(seq_bad, " lines starting on or before the previous line's end"))
  if (past_obs > 0)            bad <- c(bad, paste0(past_obs, " lines ending after the patient's observation"))
  if (length(bad))
    stop(tbl, " is not usable: ", paste(bad, collapse = "; "), call. = FALSE)
  log_msg("LOT_LONG OK: ", q$n_rows, " lines for ", q$n_patients, " patients")
  # Handed to record_final_counts rather than counted again.
  invisible(list(n_rows = q$n_rows, n_patients = q$n_patients))
}

# Validate the table downstream reads. check_lot_long ran on LOT_LONG, which is
# a different table once a truncate criterion is declared. LOT_LONG_ALLFLAGS
# needs no equivalent: the layer only adds columns, so its rows are LOT_LONG's.
check_lot_final <- function(con, cfg) {
  tbl <- lot_out("LOT_LONG_FINAL")
  q <- db_q(con, glue("
    SELECT count(*) AS n_rows, count(DISTINCT PATID) AS n_patients FROM {tbl}"))
  if (q$n_rows == 0)
    stop(tbl, " is empty, so the run produced no lines to read. LOT_LONG has ",
         "rows, so a truncate criterion has removed every one of them - check ",
         "the criterion's SQL and its APPLY_ switch.", call. = FALSE)
  # truncate drops the first failing line and every later one, so what is left
  # always runs 1..n. A gap means it took a line out of the middle, which is
  # the one thing the mode is defined not to do.
  g <- db_q(con, glue("
    SELECT count(*) AS n FROM (
      SELECT PATID, min(LOT_NUM) AS lo, max(LOT_NUM) AS hi,
             count(DISTINCT LOT_NUM) AS k
      FROM {tbl} GROUP BY PATID HAVING lo <> 1 OR k <> hi - lo + 1)"))$n
  if (g > 0)
    stop(tbl, " is not usable: ", g, " patients whose lines do not run 1..n. ",
         "truncate removes a failing line and every later one, so a gap means ",
         "the removal is not doing that.", call. = FALSE)
  log_msg("LOT_LONG_FINAL OK: ", q$n_rows, " lines for ", q$n_patients,
          " patients")
  invisible(list(n_rows = q$n_rows, n_patients = q$n_patients))
}

# The criteria layer, on top of LOT_LONG. With no criteria declared both
# tables are copies, so downstream can always read them.
# The criterion matches one MED_ABBR against map_stacked, which is built from
# cl_mma_codelist.csv. If the list does not use that abbreviation it matches
# nothing and excludes nobody - silently, because "no patient had belantamab"
# and "the abbreviation is wrong" give the same empty result. Checking the code
# list tells them apart.
#
# Only asked when the criterion is on. The NDMM build guards its side the same
# way, in build_ndmm_belantamab_codes().
check_belantamab_abbr <- function(con, cfg) {
  on <- Filter(function(c_i) identical(c_i$name, "no_belantamab"),
               enabled_line_criteria())
  if (!length(on)) return(invisible(NULL))
  abbr <- cfg$belantamab_med_abbr
  n <- tryCatch(as.integer(db_q(con, glue(
    "SELECT count(*) AS n FROM mma_codelist WHERE CL_MED_ABBR = '{abbr}'"))$n),
    error = function(e) NA_integer_)
  if (is.na(n) || n == 0)
    stop("APPLY_NO_BELANTAMAB is on, but no row of cl_mma_codelist.csv has ",
         "CL_MED_ABBR = '", abbr, "'. The criterion would exclude nobody and ",
         "the run would look clean. Check 'SELECT DISTINCT CL_MED_ABBR FROM ",
         "mma_codelist' and set BELANTAMAB_MED_ABBR to what it uses.",
         call. = FALSE)
  log_msg("  Belantamab line criterion: '", abbr, "' matches ", n,
          " code-list row(s)")
  invisible(n)
}

# Which line criteria this run applied, and what each one costs.
#
# Everything else is recorded - code lists, waivers, the contract, the window -
# but not the criteria, and they are the only thing here that removes patients.
# "Nobody had belantamab", "the criterion was off" and "wrong cohort" all leave
# the same LOT_LONG_FINAL.
#
# LOT_LONG_ALLFLAGS carries every criterion as a column, enabled or not, so the
# disabled ones are counted too - leaving one off becomes reviewable rather
# than silent.
# One integer or NA. These are diagnostics: an unreadable count is worth
# reporting as unknown, never worth failing a sound build. A bare d[[col]] on a
# frame without that column gives integer(0), and is.na(integer(0)) errors.
.one_int <- function(d, col) {
  if (is.null(d) || !is.data.frame(d) || !(col %in% names(d))) return(NA_integer_)
  v <- suppressWarnings(as.integer(d[[col]]))
  if (length(v) != 1L) NA_integer_ else v
}

report_line_criteria <- function(con, cfg, tbl = "lot_long_allflags") {
  crit <- lapply(LINE_CRITERIA, normalize_criterion)
  if (!length(crit)) {
    log_msg("Line criteria: none declared")
    options(lot_line_criteria = "")
    return(invisible(""))
  }
  # count(DISTINCT ... ) over a CASE, so a patient failing on several lines
  # counts once - the criterion removes patients, so patients is the unit.
  sel <- paste(vapply(crit, function(c_i)
    paste0("count(DISTINCT CASE WHEN ", c_i$flag, " = 0 THEN PATID END) AS ",
           c_i$flag), character(1)), collapse = ", ")
  n <- tryCatch(db_q(con, glue("SELECT {sel} FROM {tbl}")),
                error = function(e) NULL)
  parts <- character(0)
  for (c_i in crit) {
    on  <- criterion_enabled(c_i)
    hit <- .one_int(n, c_i$flag)
    log_msg("  ", if (on) "APPLIED " else "off     ", c_i$name,
            " (", c_i$on_fail, "): ",
            if (is.na(hit)) "count unavailable" else paste0(hit, " patient(s) fail it"),
            if (on && identical(c_i$on_fail, "truncate")) " - removed" else "")
    parts <- c(parts, paste0(c_i$name, "=", if (on) "on" else "off", ":",
                             c_i$on_fail, ":", if (is.na(hit)) "NA" else hit))
  }
  applied <- paste(parts, collapse = "|")
  options(lot_line_criteria = applied)
  invisible(applied)
}

# The LOT funnel: how many patients the cohort handed over, and how many are
# left. Not every row is attrition, and KIND says which is which.
#
# NDMM indexes on TREATMENT, so every member already has a qualifying MM
# therapy claim, and lot derives that fact again from the same code list. So
# "has a mapped episode" and "has LOT1" are RECONCILIATION rows - they should
# equal the row above, and a drop means the two derivations disagree rather
# than that patients were lost. As attrition they would read as expected loss
# and hide a real one.
#
# The criterion rows are the attrition. A diagnosis-indexed cohort has no such
# guarantee and there the same rows are a real narrowing, so the check below
# warns rather than stops.
#
# Two counts per step: a truncating criterion drops the first failing line and
# every later one, so a patient can survive with fewer lines and a patient
# count alone would show nothing.
#
# PCT_OF_PREV as well as PCT_OF_START, because the share of the row above is
# usually what is being asked - a criterion's own cost, or for the progression
# rows how many of a line's patients reach the next.
LOT_ATTRITION_COLS <- c(RUN_ID = "STRING", STEP_NUM = "INT", KIND = "STRING",
                        STEP = "STRING", N_PATIENTS = "BIGINT",
                        N_LINES = "BIGINT", PCT_OF_START = "DOUBLE",
                        PCT_OF_PREV = "DOUBLE", RECORDED_AT = "TIMESTAMP")

# Only criteria that actually removed something get a row. A funnel is what
# narrowed the population; a criterion that was declared but left off did not,
# and a row showing it costing nothing reads as evidence it was harmless rather
# than as evidence it never ran. Which criteria were on, and what each one
# would have cost, is already in LOT_RUN_METADATA via report_line_criteria().
lot_attrition_counts <- function(con, cfg) {
  cnt <- function(src, lines) {
    sel <- if (lines) "count(DISTINCT PATID) AS p, count(*) AS l"
           else       "count(DISTINCT PATID) AS p, cast(NULL as bigint) AS l"
    d <- db_q(con, glue("SELECT {sel} FROM {src}"))
    list(patients = as.numeric(d$p[1]),
         lines    = if (lines) as.numeric(d$l[1]) else NA_real_)
  }
  steps <- list(
    list(kind = "input", step = "Cohort patients handed to LOT",
         n = cnt("lot_patient_input", FALSE)),
    list(kind = "reconciliation", step = "With a mapped MM therapy episode",
         n = cnt("map_stacked", FALSE)),
    list(kind = "reconciliation", step = "With LOT1 built",
         n = cnt("lot_long", TRUE)))

  # Cumulative, and through the build's own truncate SQL rather than a second
  # version of it here: the rule that decides which lines go is the thing being
  # counted, so a copy of it would report on itself.
  on <- Filter(function(c_i) identical(c_i$on_fail, "truncate"),
               enabled_line_criteria())
  for (i in seq_along(on)) {
    v <- paste0("lot_attrition_step_", i)
    db_exec(con, line_criteria_final_sql(cfg, "lot_long_allflags", v,
                                         crit = on[seq_len(i)]))
    steps[[length(steps) + 1L]] <-
      list(kind = "criterion", step = paste0("+ ", on[[i]]$label), n = cnt(v, TRUE))
  }
  steps[[length(steps) + 1L]] <-
    list(kind = "final", step = "Study population (LOT_LONG_FINAL)",
         n = cnt("lot_long_final", TRUE))

  # How far patients get: LOT1, then LOT2, and so on to max_lot.
  #
  # Its own KIND, because nobody was removed here - a patient with no LOT3
  # either did not progress or ran out of follow-up. As exclusions they would
  # read as the study losing people it never lost.
  #
  # Over LOT_LONG_FINAL, where check_lot_final() has established lines run
  # 1..n, so reaching LOT n implies every line below.
  #
  # Every line to max_lot gets a row, including ones nobody reached: "no
  # patient got to LOT5" is an answer, a missing row is not.
  by_line <- db_q(con, glue("
    SELECT LOT_NUM, count(DISTINCT PATID) AS p, count(*) AS l
    FROM lot_long_final GROUP BY LOT_NUM"))
  for (k in seq_len(as.integer(cfg$max_lot))) {
    i <- match(k, as.integer(by_line$LOT_NUM))
    steps[[length(steps) + 1L]] <- list(
      kind = "progression", step = paste0("Reached LOT", k),
      n = list(patients = if (is.na(i)) 0 else as.numeric(by_line$p[i]),
               lines    = if (is.na(i)) 0 else as.numeric(by_line$l[i])))
  }
  steps
}

# The reconciliation rows, against the row above them.
#
# A cohort indexed on a treatment has already found the claim lot is about to
# find again, so these should not move. When they do, the two derivations
# disagree and every count below is over a population the cohort build does not
# think it handed over.
#
# A warning, not a stop: lot runs over cohorts it did not build, and one
# indexed on a diagnosis has no such guarantee. Naming the number is what this
# can honestly do; deciding is the operator's.
report_lot_reconciliation <- function(steps) {
  start <- steps[[1]]$n$patients
  for (i in seq_along(steps)) {
    s <- steps[[i]]
    if (!identical(s$kind, "reconciliation")) next
    lost <- start - s$n$patients
    if (is.na(lost) || lost <= 0) next
    log_msg("WARNING: ", format(lost, big.mark = ",", scientific = FALSE),
            " of ", format(start, big.mark = ",", scientific = FALSE),
            " cohort patients (", round(100 * lost / start, 2),
            "%) are missing at '", s$step, "'. If the cohort's index is a ",
            "TREATMENT qualifier - NDMM's is - every member already had a ",
            "qualifying claim on the same cl_mma_codelist.csv, so this is not ",
            "attrition: it is that scan and this one disagreeing. If the ",
            "cohort is indexed on something else, it is a real narrowing and ",
            "expected.")
  }
  invisible(TRUE)
}

# The funnel only narrows, on both counts. A step larger than the one above it
# means a join fanned out or a filter ran against the wrong population.
#
# And the last criterion step must equal the final table. They are built from
# the same SQL over the same view, so a difference means the criteria applied
# here are not the criteria that produced LOT_LONG_FINAL - which would make
# every row above it a description of some other run's population.
check_lot_attrition <- function(steps) {
  p <- vapply(steps, function(s) s$n$patients, numeric(1))
  for (nm in c("patients", "lines")) {
    v <- vapply(steps, function(s) s$n[[nm]], numeric(1))
    # Compared between steps that HAVE the count, but reported by their
    # position in the funnel. The first two steps have no line count, so
    # indexing the compacted vector would name the wrong step.
    idx <- which(!is.na(v))
    for (k in seq_len(max(0L, length(idx) - 1L))) {
      i <- idx[k]; j <- idx[k + 1L]
      if (v[j] > v[i])
        stop("LOT attrition rises at step ", j, " (", nm, "): ",
             steps[[i]]$step, " -> ", steps[[j]]$step,
             ". A funnel cannot widen, so a join fanned out or a step ran ",
             "against the wrong population.", call. = FALSE)
    }
  }
  kind <- vapply(steps, function(s) s$kind, character(1))
  # Located, not assumed to be last: the progression rows sit after it.
  f <- match("final", kind)
  if (!is.na(f) && f >= 2L && !identical(p[f], p[f - 1L]))
    stop("The last criterion leaves ", p[f - 1L], " patients but ",
         "LOT_LONG_FINAL has ", p[f], ". Both come from the same criteria SQL ",
         "over lot_long_allflags, so they cannot differ unless the criteria ",
         "counted here are not the ones that built it.", call. = FALSE)
  # Every patient in LOT_LONG_FINAL has a LOT1 - check_lot_final() has already
  # established that their lines run 1..n - so the first progression row is
  # that table counted a second way. A difference means the by-line query and
  # the table query disagree about the same rows.
  l1 <- which(kind == "progression")[1]
  if (!is.na(f) && !is.na(l1) && !identical(p[l1], p[f]))
    stop("LOT_LONG_FINAL has ", p[f], " patients but only ", p[l1],
         " reach LOT1. Lines run 1..n there, so every patient has a LOT1 and ",
         "these are the same population counted twice.", call. = FALSE)
  invisible(TRUE)
}

write_lot_attrition <- function(con, cfg, steps) {
  tbl  <- lot_out("LOT_ATTRITION")
  cols <- names(LOT_ATTRITION_COLS)
  db_exec(con, glue("CREATE TABLE IF NOT EXISTS {tbl} (",
                    paste(cols, LOT_ATTRITION_COLS, collapse = ", "), ")"))
  lot_ensure_cols(con, tbl, LOT_ATTRITION_COLS)
  start <- steps[[1]]$n$patients
  pct_of <- function(num, den)
    if (is.na(den) || den == 0 || is.na(num)) "NULL"
    else sql_count(round(100 * num / den, 2))
  vals <- vapply(seq_along(steps), function(i) {
    s     <- steps[[i]]
    prev  <- if (i == 1L) NA_real_ else steps[[i - 1L]]$n$patients
    lines <- if (is.na(s$n$lines)) "NULL" else sql_count(s$n$lines)
    glue("('{run_id}', {i}, {sql_text(s$kind)}, {sql_text(s$step)}, ",
         "{sql_count(s$n$patients)}, {lines}, ",
         "{pct_of(s$n$patients, start)}, {pct_of(s$n$patients, prev)}, ",
         "current_timestamp())")
  }, character(1), USE.NAMES = FALSE)
  db_replace(con,
    glue("DELETE FROM {tbl} WHERE RUN_ID = '{run_id}'"),
    glue("INSERT INTO {tbl} ({paste(cols, collapse = ', ')}) VALUES ",
         paste(vals, collapse = ", ")))
  for (i in seq_along(steps)) {
    s    <- steps[[i]]
    prev <- if (i == 1L) NA_real_ else steps[[i - 1L]]$n$patients
    log_msg("  ", i, ". [", s$kind, "] ", s$step, ": ",
            format(s$n$patients, big.mark = ",", scientific = FALSE), " patients",
            if (is.na(s$n$lines)) ""
            else paste0(", ", format(s$n$lines, big.mark = ",", scientific = FALSE), " lines"),
            if (!is.na(start) && start > 0)
              paste0(" (", round(100 * s$n$patients / start, 1), "% of cohort") else "",
            # The share of the row above is the number these rows are asked
            # for: a criterion's cost, and the proportion of one line's
            # patients who go on to the next.
            if (!is.na(prev) && prev > 0)
              paste0(", ", round(100 * s$n$patients / prev, 1), "% of previous)")
            else if (!is.na(start) && start > 0) ")" else "")
  }
  log_msg("LOT attrition written to ", tbl)
  invisible(tbl)
}

phase_lot_attrition <- function(con, cfg) {
  log_msg("LOT attrition")
  steps <- lot_attrition_counts(con, cfg)
  check_lot_attrition(steps)
  report_lot_reconciliation(steps)
  write_lot_attrition(con, cfg, steps)
}

phase_line_criteria <- function(con, cfg) {
  # A flag naming a column LOT_LONG already has does not fail: the generated
  # SQL is SELECT *, <expr> AS <flag>, so the result carries the name twice and
  # which one a later reference means is Spark's choice. Asked of the table
  # rather than assumed, because what LOT_LONG carries depends on the code list.
  crit <- lapply(LINE_CRITERIA, normalize_criterion)
  if (length(crit)) {
    have  <- toupper(trimws(as.character(db_q(con, "DESCRIBE lot_long")[[1]])))
    clash <- Filter(function(c_i) toupper(c_i$flag) %in% have, crit)
    if (length(clash))
      stop("Line criteria whose flag is already a LOT_LONG column: ",
           paste(vapply(clash, function(c_i) paste0(c_i$name, " -> ", c_i$flag),
                        character(1)), collapse = ", "),
           ". Rename the flag; the column would otherwise appear twice.",
           call. = FALSE)
  }
  check_belantamab_abbr(con, cfg)
  # The patient-level facts a criterion asks of the claims rather than of
  # lot_long. Built first: the flags view joins them.
  for (pv in line_criteria_patient_sql(cfg))
    run_step(con, paste0("L39_", tolower(pv$name)), pv$sql,
             qc = glue("SELECT count(*) AS n_patients FROM {pv$name}"))
  run_step(con, "L40_lot_long_allflags",
           line_criteria_flags_sql(cfg, "lot_long", "lot_long_allflags"))
  # Written before anything reads it, and before the final view is defined
  # over it - Spark inlines a temporary view's plan at creation, so a final
  # view created first would keep the flags query even after the repoint.
  # The tables are tables, not persistent views, because both sit on
  # temporary views and Spark refuses a persistent view over one of those.
  # And the views are repointed at them, so the reporter below and every
  # attrition read after it scans the table instead of re-running the
  # criteria SQL.
  materialize(con, "L40b_persist_lot_long_allflags",
              view = "lot_long_allflags", name = "LOT_LONG_ALLFLAGS",
              body = "SELECT * FROM lot_long_allflags",
              qc = "SELECT count(*) AS n_rows FROM lot_long_allflags")
  # Before the truncate: allflags still has every line, so the counts are of
  # patients the criteria catch rather than of the ones that survived them.
  report_line_criteria(con, cfg)
  run_step(con, "L41_lot_long_final",
           line_criteria_final_sql(cfg, "lot_long_allflags", "lot_long_final"))
  materialize(con, "L41b_persist_lot_long_final",
              view = "lot_long_final", name = "LOT_LONG_FINAL",
              body = "SELECT * FROM lot_long_final",
              qc = "SELECT count(*) AS n_rows FROM lot_long_final")
  invisible(TRUE)
}
