# Runner for the LOT build. Standalone: one module, pointed at a cohort table.
#
# The rules are the same for every cohort. What changes per run is which table
# is read and which prefix the outputs carry, and the caller supplies both.
# No cohort is named anywhere in this folder. Everything else is pinned below
# and checked before the first query.

`%||%` <- function(a, b) if (is.null(a)) b else a

# Settings that decide what a LOT run means. A different value here is a
# different result, so they are checked rather than defaulted. Change a value
# here and in config.csv together, deliberately.
CONTRACT <- list(
  catalog                     = "hive_metastore",
  cdm_schema                  = "clnprw_optum",
  codelist_dir                = "/mnt/code/codelist",
  use_quarterly_tables        = TRUE,
  # Picks the quarterly CDM tables, so a different date is different source
  # data for every read.
  study_end                   = "2025-06-30",
  censor_at_disenrollment     = FALSE,
  induction_window_days       = 60L,
  lot_n_induction_window_days = 30L,
  map_discon_gap_days         = 90L,
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
  tbl_med_diag                = "med_diagnosis",
  tbl_rx                      = "rx"
)

# Reviewable code-list checks: each has a reading a study team can accept.
# Named individually, because one switch for all of them meant waiving an
# expected condition also waived the dangerous ones.
WAIVABLE_CHECKS <- c("orphan_meds", "uncoded_meds", "code_types",
                     "subs_substitute", "subs_original", "ndc_short",
                     "claim_ndc_short", "claim_ndc_shape")

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
                   "PERSIST_TO_SCHEMA")
INT_SETTINGS  <- c("INDUCTION_WINDOW_DAYS", "INDUCTION_WINDOW_DAYS_LOT_N",
                   "MAP_DISCON_GAP_DAYS", "MEDICAL_DAY_SUPPLY",
                   "SCT_AUTO_WINDOW_DAYS", "SCT_AUTO_GAP_DAYS",
                   "SCT_TANDEM_DAYS", "CART_CONSOLIDATION_DAYS", "MAX_LOT")

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
  e <- Sys.getenv("STUDY_END", unset = "")
  if (nzchar(e) && !grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", e))
    bad <- c(bad, paste0("STUDY_END='", e, "' (want YYYY-MM-DD)"))
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
         "(e.g. osk02156), or PROJECT_WORK_SCHEMA to override.", call. = FALSE)
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

check_lot_contract <- function(cfg) {
  wrong <- Filter(Negate(is.null), lapply(names(CONTRACT), function(k) {
    got <- cfg[[k]]
    if (isTRUE(all.equal(got, CONTRACT[[k]]))) NULL
    else paste0(k, " = ", format(got), " (want ", format(CONTRACT[[k]]), ")")
  }))
  if (length(wrong))
    stop("This build is defined as:\n  ", paste(unlist(wrong), collapse = "\n  "),
         call. = FALSE)
  # Without a prefix every run writes the same table names, so a second cohort
  # would overwrite the first instead of sitting beside it.
  if (!nzchar(cfg$object_prefix))
    stop("No output prefix. LOT outputs would collide with another cohort's.",
         call. = FALSE)
  if (!nzchar(cfg$input_cohort_table))
    stop("No cohort table to read.", call. = FALSE)
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
  for (f in c("config_lot.R", "db_utils_lot.R", "codelists_lot.R", "line_criteria.R"))
    source(file.path(here, "R", f))
  steps <- sort(list.files(file.path(here, "R", "steps"), "\\.R$", full.names = TRUE))
  for (f in steps) source(f)
  invisible(TRUE)
}

# The run. Phases in order, each one leaving temp views the next reads.
build_lot <- function(here, cohort_table, prefix) {
  check_settings()
  cfg <- pin_output_schema(cfg_defaults)
  cfg <- pin_cohort(cfg, cohort_table, prefix)
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
  log_msg("  Induction Window (LOT1):   ", cfg$induction_window_days, " days")
  log_msg("  Induction Window (LOT2-5): ", cfg$lot_n_induction_window_days, " days")
  log_msg("  Discon Gap (per-drug, MAP-level): ", cfg$map_discon_gap_days, " days")
  log_msg("  Medical Day Supply: ", cfg$medical_day_supply, " days")

  cohort <- check_cohort_input(con, wrk(cfg$input_cohort_table))

  # LOT1 is written before LOT_LONG, so track partial runs.
  # Cleared first, or a second run in one session inherits the first's.
  options(lot_waivers_applied = character(0), lot_codelist_md5 = list())
  check_no_active_run(con, cfg)
  write_build_status(con, cfg, "started")
  clear_run_rows(con, cfg)
  # after = FALSE, or this fires after the disconnect above and writes to a
  # closed connection. Registered here, not beside the connection, so a
  # preflight failure still leaves no status row at all.
  on.exit(if (!isTRUE(getOption("lot_complete", FALSE)))
            try(write_build_status(con, cfg, "failed"), silent = TRUE),
          add = TRUE, after = FALSE)
  options(lot_complete = FALSE)

  ctx <- phase_codelists(con)
  record_codelist_hashes(con, cfg)
  phase_patient_input(con)
  materialize_cohort_input(con, cohort)
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
               max_lot                 = cfg$max_lot)

  # Validate before deriving: publishing the criteria tables first would leave
  # them behind, built from a LOT_LONG that then failed its checks. Two
  # statements, not one nested call - R would not force the promise until after
  # record_final_counts had altered the table.
  lot_long <- check_lot_long(con, cfg)
  phase_line_criteria(con, cfg)
  # After the criteria layer, not before it: LOT_LONG_FINAL is what downstream
  # reads, and with a truncate criterion it is not LOT_LONG.
  final <- check_lot_final(con, cfg)
  record_final_counts(con, cfg, lot_long, final)
  check_run_recorded(con, cfg)
  write_build_status(con, cfg, "complete")
  # Only after the write succeeded. Setting it first meant a failed write left
  # the run marked "started" with on.exit believing it had finished.
  options(lot_complete = TRUE)

  log_msg(SEP)
  log_msg("LOT complete for ", cfg$input_cohort_table, " -> ", cfg$object_prefix, "*")
  log_msg(SEP)
  invisible(TRUE)
}

# The views LOT2-5 reads. All present means LOT1 ran in this session.
LOT2_5_INPUT_VIEWS <- c("lot_patient_input", "mma_rollup", "permissible_subs",
                        "sct_codelist", "sct_claims_raw", "tx_auto_dates",
                        "tx_allo_cart_dates", "map_stacked", "lot1_sct",
                        "lot1_base_end")

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
  tbl <- lot_out("LOT_PATIENT_INPUT")
  run_step(con, "S03b_materialize_cohort_input", glue("
    CREATE OR REPLACE TABLE {tbl} AS SELECT * FROM lot_patient_input"),
    qc = glue("SELECT count(*) AS n_rows, count(DISTINCT PATID) AS n_patients
               FROM {tbl}"))
  db_exec(con, glue("
    CREATE OR REPLACE TEMPORARY VIEW lot_patient_input AS SELECT * FROM {tbl}"))

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
    run_step(con, paste0("L20_materialize_", tolower(mv$name)),
             glue("CREATE OR REPLACE TABLE {lot_out(mv$name)} AS SELECT * FROM {mv$view}"),
             qc = glue("SELECT count(*) AS n_rows, count(DISTINCT PATID) AS n_patients
                        FROM {lot_out(mv$name)}"))
    db_exec(con, glue(
      "CREATE OR REPLACE TEMPORARY VIEW {mv$view} AS SELECT * FROM {lot_out(mv$name)}"))
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
  shape <- prof[prof$n_ndc > 0 & (prof$n_alpha > 0 | prof$n_other > 0 |
                                  prof$n_zero > 0), , drop = FALSE]
  decide(shape, "claim_ndc_shape",
         paste0("Claim NDCs that cannot be an NDC: ", detail(shape),
                ".\nThe join strips non-digits and pads to eleven, so a value ",
                "like ABC123 arrives as 00000000123 and can match a real code, ",
                "and nothing here can tell it from a genuine claim. If the CDM ",
                "really carries these, either the join has to exclude them or ",
                "the study team has to accept that they may match: waive with ",
                "CODELIST_WAIVERS=claim_ndc_shape."))

  # A real NDC in one of three layouts, and the pad only gets 4-4-2 right.
  short <- prof[prof$n_ndc > 0 & prof$n_10 > 0, , drop = FALSE]
  decide(short, "claim_ndc_short",
         paste0("Ten-digit claim NDCs: ", detail(short),
                ".\nThe join left-pads to eleven, which is right only for the ",
                "4-4-2 layout, so a ten-digit claim can be read as a different ",
                "drug's code or as none. Confirm how this CDM represents NDC, ",
                "or convert with an approved NDC10-to-NDC11 crosswalk. Once ",
                "the study team has established that the padding is right for ",
                "this data, waive it with CODELIST_WAIVERS=claim_ndc_short."))

  if (nrow(shape) == 0 && nrow(short) == 0)
    log_msg("  OK: Every claim NDC is eleven digits.")
  invisible(TRUE)
}

# One row per run saying whether its outputs belong together. Without it a
# failed run leaves tables that look complete.
# REQUESTED is what the run was given; APPLIED is what actually fired and was
# waived, which is the one that says something about the code lists. A run can
# request a waiver for a condition that never occurs.
BUILD_STATUS_COLS <- c(
  RUN_ID = "STRING", INPUT_COHORT_TABLE = "STRING", OBJECT_PREFIX = "STRING",
  STATE = "STRING", CODELIST_WAIVERS_REQUESTED = "STRING",
  CODELIST_WAIVERS_APPLIED = "STRING", UPDATED_AT = "TIMESTAMP")

write_build_status <- function(con, cfg, state) {
  tbl  <- lot_out("LOT_BUILD_STATUS")
  cols <- names(BUILD_STATUS_COLS)
  db_exec(con, glue("CREATE TABLE IF NOT EXISTS {tbl} (",
                    paste(cols, BUILD_STATUS_COLS, collapse = ", "), ")"))

  # CREATE TABLE IF NOT EXISTS does nothing to a table an earlier version left
  # behind, so add any column it lacks: naming the columns in the INSERT stops
  # a positional mis-fill but cannot supply a missing one. Look before adding -
  # adding a column that already exists is an error.
  have <- tryCatch({
    d  <- db_q(con, glue("DESCRIBE {tbl}"))
    cn <- intersect(c("col_name", "COL_NAME", "name", "NAME"), names(d))
    if (length(cn)) toupper(trimws(as.character(d[[cn[1]]]))) else character(0)
  }, error = function(e) character(0))
  # No answer means DESCRIBE failed, not that the table has no columns. Acting
  # on that would try to add every column to a table that already has them.
  for (m in if (length(have)) setdiff(cols, have) else character(0)) {
    tryCatch({
      db_exec(con, glue("ALTER TABLE {tbl} ADD COLUMNS ({m} {BUILD_STATUS_COLS[[m]]})"))
      log_msg("  Build status schema evolution: added ", m)
    }, error = function(e) {
      msg <- conditionMessage(e)
      # Unlike the metadata table, every one of these is in the INSERT, so a
      # column we could not add is a failure now rather than a warning.
      if (!grepl("already exists|AlreadyExists|FIELD_ALREADY_EXISTS",
                 msg, ignore.case = TRUE))
        stop("Cannot add ", m, " to ", tbl, ": ", msg, call. = FALSE)
    })
  }

  requested <- paste(codelist_waivers(), collapse = "|")
  # Set by phase_codelists when it waives something. Empty at "started", and on
  # a failure before the code lists ran.
  applied <- paste(getOption("lot_waivers_applied", character(0)), collapse = "|")
  vals <- c(RUN_ID                     = glue("'{run_id}'"),
            INPUT_COHORT_TABLE         = glue("'{cfg$input_cohort_table}'"),
            OBJECT_PREFIX              = glue("'{cfg$object_prefix}'"),
            STATE                      = glue("'{state}'"),
            CODELIST_WAIVERS_REQUESTED = glue("'{requested}'"),
            CODELIST_WAIVERS_APPLIED   = glue("'{applied}'"),
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
                       "LOT_CODELIST_METADATA")

clear_run_rows <- function(con, cfg) {
  for (t in RUN_SCOPED_TABLES)
    try(db_exec(con, glue("DELETE FROM {lot_out(t)} WHERE RUN_ID = '{run_id}'")),
        silent = TRUE)
  invisible(TRUE)
}

# Output names are work schema + prefix + table, with no run id in them, and
# several phases repoint a session view at a shared prefixed table they have
# just replaced - LOT_PATIENT_INPUT, the three SCT tables, the LOT_LONG stage.
# Two runs on one prefix therefore interleave: the second replaces a table the
# first has already pointed a view at, and the first reads the second's rows
# from there on. Both can still reach "complete", with the outputs mixed.
#
# Different prefixes are safe, and that is how two cohorts are meant to run at
# once. This refuses the same-prefix case.
#
# A check, not a lock: two runs starting at the same moment can both pass it,
# because there is nothing here that could hold a lock. It catches the case
# worth catching - starting a second run while one is going - and says so.
check_no_active_run <- function(con, cfg) {
  d <- tryCatch(db_q(con, glue("
    SELECT RUN_ID, UPDATED_AT FROM {lot_out('LOT_BUILD_STATUS')}
    WHERE OBJECT_PREFIX = '{cfg$object_prefix}' AND STATE = 'started'
      AND RUN_ID <> '{run_id}'")), error = function(e) NULL)
  # No table yet on a first run, and nothing to collide with.
  if (is.null(d) || !nrow(d)) return(invisible(TRUE))
  who <- paste(d$RUN_ID, collapse = ", ")
  if (identical(toupper(Sys.getenv("LOT_IGNORE_ACTIVE_RUN", unset = "")), "TRUE")) {
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
       "LOT_IGNORE_ACTIVE_RUN=TRUE.", call. = FALSE)
}

# The QC phase reports these and carries on - it prints "** BUG **" and the run
# still finishes. They are not judgement calls: each one is impossible unless
# something upstream is wrong, so re-run them here where a breach stops the
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
  # impossible unless something upstream is wrong.
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
# failure there only logs a warning. Rather than edit the ported file, check
# the row actually arrived - a run with no record of how it was configured is
# not a run anyone can validate later.
check_run_recorded <- function(con, cfg) {
  # Exactly one row, not at least one. 08_persist writes this table with a
  # DELETE and an INSERT as separately retried statements, so an INSERT that
  # reached the warehouse with its answer lost leaves two rows. That file is
  # the ported source, so the duplicate is caught here rather than edited there.
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

  # CREATE TABLE IF NOT EXISTS does nothing to a table an earlier version left
  # behind, and the INSERT below names its columns - so one this table lacks
  # fails the run rather than being filled positionally. The other two metadata
  # tables already migrate; this one did not, and the first column to be renamed
  # or added would have stopped every schema that had run the older version.
  have <- tryCatch({
    d  <- db_q(con, glue("DESCRIBE {tbl}"))
    cn <- intersect(c("col_name", "COL_NAME", "name", "NAME"), names(d))
    if (length(cn)) toupper(trimws(as.character(d[[cn[1]]]))) else character(0)
  }, error = function(e) character(0))
  if (!length(have))
    stop("Cannot read the columns of ", tbl, ", so the code list hashes cannot ",
         "be recorded.", call. = FALSE)
  add <- setdiff(cols, have)
  if (length(add)) {
    db_exec(con, glue("ALTER TABLE {tbl} ADD COLUMNS (",
                      paste(add, CODELIST_METADATA_COLS[add], collapse = ", "), ")"))
    log_msg("  Codelist metadata schema evolution: added ", paste(add, collapse = ", "))
  }

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

# LOT_RUN_METADATA is written by phase_persist, which runs before LOT2-5, so
# its counts stop at LOT1: cohort, MMA claims, MAPs, LOT1 patients. Nothing
# recorded what the run actually produced. The totals come from check_lot_long,
# which has just counted them and passed - so they describe a table already
# found usable, and are not scanned for twice.
# What produced these tables, beyond the counts. LOT_RUN_METADATA is the ported
# source's and records seven of the twenty-one settings CONTRACT pins, and
# nothing about the code - so an old run's outputs could not say which version
# or which full contract made them. Two columns rather than one per setting:
# CODE_MD5 fingerprints the R that ran, and CONTRACT_SETTINGS carries the lot.
#
# A hash of the sources rather than a git sha: this folder is copied into
# Domino to run, where there may be no repository to ask, and the hash
# describes the code that actually executed either way.
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
contract_settings <- function() {
  k <- sort(names(CONTRACT), method = "radix")
  paste(paste0(k, "=", vapply(CONTRACT[k], function(v) as.character(v)[1],
                              character(1))), collapse = "|")
}

FINAL_METADATA_COLS <- c(N_LOT_LONG_ROWS = "BIGINT",
                         N_LOT_LONG_PATIENTS = "BIGINT",
                         LOT_LONG_BY_LINE = "STRING",
                         N_LOT_FINAL_ROWS = "BIGINT",
                         N_LOT_FINAL_PATIENTS = "BIGINT",
                         CODE_MD5 = "STRING", CONTRACT_SETTINGS = "STRING")

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
           CONTRACT_SETTINGS = {sql_text(contract_settings())}
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
  run_step(con, "L40_lot_long_allflags",
           line_criteria_flags_sql(cfg, "lot_long", "lot_long_allflags"))
  run_step(con, "L41_lot_long_final",
           line_criteria_final_sql(cfg, "lot_long_allflags", "lot_long_final"))
  # Persisted, not views: both are built from temporary views, and Spark
  # refuses a persistent view over one of those.
  for (v in list(list(view = "lot_long_allflags", name = "LOT_LONG_ALLFLAGS"),
                 list(view = "lot_long_final",    name = "LOT_LONG_FINAL"))) {
    run_step(con, paste0("L42_persist_", tolower(v$name)),
             glue("CREATE OR REPLACE TABLE {lot_out(v$name)} AS SELECT * FROM {v$view}"),
             qc = glue("SELECT count(*) AS n_rows FROM {lot_out(v$name)}"))
  }
  invisible(TRUE)
}
