# Cohort runner for overall/. build.R calls build_cohort(<this folder>).

build_cohort <- function(cohort_dir, root = cohort_dir, expect_table = NULL,
                         expect_prefix = NULL) {
  check_settings()
  cfg <- pin_output_schema(cfg_defaults)
  cfg$outpatient_window <- validate_outpatient_window(cfg$outpatient_window)
  check_output_contract(cfg, expect_table, expect_prefix)

  log_msg("=", SEP_59)
  log_msg("COHORT BUILD - ", basename(cohort_dir), " - run_id: ", run_id)
  log_msg("OUTPATIENT WINDOW: ", cfg$outpatient_window, " days")
  log_msg("OUTPUT SCHEMA: ", cfg$catalog, ".", cfg$work_schema)
  log_msg("OUTPUT TABLE: ", cfg$final_table_name)
  log_msg("=", SEP_59)

  conn <- new.env()
  conn$con <- with_retry(function() {
    c <- connect_databricks(cfg)
    log_msg("Connected to Databricks")
    c
  }, max_retries = cfg$max_retries, base_sleep = cfg$base_sleep)
  if (!interactive()) {
    on.exit({ if (!is.null(conn$con)) try(DBI::dbDisconnect(conn$con), silent = TRUE) },
            add = TRUE)
  }

  check_no_active_run_overall(conn, cfg)
  write_build_status(conn, cfg, "started")
  build_complete <- FALSE
  # Mark partial runs before the connection closes.
  on.exit({
    if (!build_complete)
      try(write_build_status(conn, cfg, "failed"), silent = TRUE)
  }, add = TRUE, after = FALSE)

  load_csv_codelists(conn, cfg)

  mat_tables <- new.env()
  ckpt_steps <- resolve_checkpoints()
  log_msg("CHECKPOINTS: ", paste(ckpt_steps, collapse = ", "))
  load_phase_steps(file.path(root, "R", "steps"))
  steps <- Filter(Negate(is.null), build_steps(cfg, mat_tables))

  cat("\n", SEP_60, "\n", sep = "")
  cat("  STARTING BUILD: ", length(steps), " steps\n")
  cat(SEP_60, "\n")

  for (i in seq_along(steps)) {
    s <- steps[[i]]
    view_name <- step_view_name(s$sql)
    is_ckpt <- isTRUE(cfg$materialize_checkpoints) &&
               is_checkpoint(view_name, ckpt_steps, cfg)

    with_retry(function() {
      run_step(s$name, s$sql, conn = conn, cfg = cfg,
               qc_sql = if (is_ckpt) NULL else s$qc,
               description = s$description,
               step_num = i, total_steps = length(steps),
               source_tables = s$source_tables)
    }, max_retries = cfg$max_retries, base_sleep = cfg$base_sleep)

    if (is_ckpt) {
      ok <- materialize_to_personal_schema(conn$con, view_name, cfg, mat_tables)
      if (isTRUE(ok)) check_normalized_codelist(conn, cfg, view_name, mat_tables)
      if (!isTRUE(ok)) {
        stop("'", view_name, "' failed to materialize to '",
             cfg$personal_schema, "'. See the WARN above.")
      }
      with_retry(function() run_qc(conn$con, s$qc),
                 max_retries = cfg$max_retries, base_sleep = cfg$base_sleep)
    }
  }

  log_msg("=", SEP_59)
  log_msg("BUILD COMPLETE - generating attrition report...")

  # Point the final-cohort lookups at the table step 24b wrote, not the view
  # it was built from, so the attrition row counts the actual deliverable.
  assign(cfg$final_table_name,
         make_naming_helpers(cfg, mat_tables)$full_name(cfg$personal_schema,
                                                        cfg$final_table_name),
         envir = mat_tables)

  # No tryCatch. The attrition table is a deliverable - if it can't be
  # produced, the run failed.
  h <- make_naming_helpers(cfg, mat_tables)
  catalog <- build_criteria_catalog(cfg)
  rows <- run_attrition_report(catalog, cfg, conn, h$work_tbl)
  if (isTRUE(cfg$persist_to_schema)) persist_attrition_table(rows, cfg, conn)
  print_cohort_characteristics(cfg, conn, h$work_tbl)

  write_build_status(conn, cfg, "complete")
  build_complete <- TRUE
  log_msg("=", SEP_59)

  invisible(list(cfg = cfg, conn = conn, mat_tables = mat_tables))
}

# What this build is. An env var beats config.csv, so every setting that moves
# the cohort has to be checked, not just defaulted. Change a value here and in
# config.csv together, deliberately.
CONTRACT <- list(
  catalog                 = "hive_metastore",
  cdm_schema              = "clnprw_optum",
  use_csv_codelists       = TRUE,
  codelist_dir            = "/mnt/code/codelist",
  use_quarterly_tables    = TRUE,
  outpatient_window       = 90L,
  min_age                 = 18L,
  censor_at_disenrollment = FALSE,
  apply_age_incl          = TRUE,
  apply_ce_b_incl         = TRUE,
  apply_ce_f_incl         = TRUE,
  apply_no_bl_agents_incl = TRUE,
  apply_fu_agents_incl    = TRUE,
  apply_baseline_mm_excl  = FALSE,
  apply_other_malig_excl  = FALSE,
  apply_pregnancy_excl    = FALSE,
  apply_clintrial_excl    = FALSE,
  dsn                     = "RWDE",
  tbl_member_elig         = "member_cont_enrollment",
  tbl_member_enrollment   = "member_enrollment",
  tbl_medical             = "medical",
  tbl_med_diag            = "med_diagnosis",
  tbl_med_proc            = "med_procedure",
  tbl_rx                  = "rx",
  tbl_dod                 = "dod",
  tbl_confinement         = "confinement",
  # Which map entry each code list reads. Pinned with the file names below,
  # so a re-pointed selector can't reach a different file.
  cl_mm_dx                = "cl_mm_dx",
  cl_mm_therapy           = "cl_mm_therapy",
  cl_preg                 = "cl_pregnancy",
  cl_clintrial            = "cl_clintrial",
  cl_other_malig          = "cl_other_malignancies"
)

# The file behind each code list. Renaming one silently changes the cohort.
CODELIST_FILES <- list(
  cl_mm_dx              = "mm_dx.csv",
  cl_mm_therapy         = "cl_mma_codelist.csv",
  cl_pregnancy          = "pregnancy.csv",
  cl_clintrial          = "clintrial.csv",
  cl_other_malignancies = "other_malig.csv"
)

check_output_contract <- function(cfg, expect_table, expect_prefix = NULL) {
  wrong <- Filter(Negate(is.null), lapply(names(CONTRACT), function(k) {
    got <- cfg[[k]]
    if (isTRUE(all.equal(got, CONTRACT[[k]]))) NULL
    else paste0(k, " = ", format(got), " (want ", format(CONTRACT[[k]]), ")")
  }))
  if (length(wrong))
    stop("This build is defined as:\n  ", paste(unlist(wrong), collapse = "\n  "),
         call. = FALSE)
  if (!is.null(expect_table) && !identical(cfg$final_table_name, expect_table)) {
    stop("This build writes ", expect_table, ", but FINAL_TABLE_NAME is '",
         cfg$final_table_name, "'. Unset it, or fix config.csv.", call. = FALSE)
  }
  if (!is.null(expect_prefix) && !identical(cfg$object_prefix, expect_prefix)) {
    stop("This build prefixes its tables '", expect_prefix,
         "', but OBJECT_PREFIX is '", cfg$object_prefix,
         "'. A wrong prefix overwrites another build's tables.", call. = FALSE)
  }
  if (!identical(resolve_checkpoints(), "*")) {
    stop("CHECKPOINT_STEPS must be '*' so every step is written to the schema. ",
         "It is '", paste(resolve_checkpoints(), collapse = "|"), "'.",
         call. = FALSE)
  }
  # Whole map, not just these five keys: checking a subset would let an added
  # key plus a re-pointed cl_* selector feed the build a different file.
  if (!identical(cfg$codelist_csv_map, CODELIST_FILES)) {
    stop("The code-list file names are not the ones this build is defined on.",
         call. = FALSE)
  }
  if (!isTRUE(cfg$persist_to_schema)) {
    stop("PERSIST_TO_SCHEMA is FALSE, so nothing would be written. ",
         "Set it TRUE to build a cohort.", call. = FALSE)
  }
  invisible(TRUE)
}

# Bad values fail open: as.logical("Y") is NA, which reads as FALSE and drops a
# criterion. An invalid window silently becomes 90. Catch both up front.
BOOL_SETTINGS <- c("APPLY_AGE_INCL", "APPLY_CE_B_INCL", "APPLY_CE_F_INCL",
                   "APPLY_NO_BL_AGENTS_INCL", "APPLY_FU_AGENTS_INCL",
                   "APPLY_BASELINE_MM_EXCL", "APPLY_OTHER_MALIG_EXCL",
                   "APPLY_PREGNANCY_EXCL", "APPLY_CLINTRIAL_EXCL",
                   "USE_CSV_CODELISTS", "USE_QUARTERLY_TABLES",
                   "CENSOR_AT_DISENROLLMENT", "PERSIST_TO_SCHEMA")

check_settings <- function() {
  bad <- character(0)
  for (v in BOOL_SETTINGS) {
    x <- Sys.getenv(v, unset = "")
    if (nzchar(x) && !(toupper(x) %in% c("TRUE", "FALSE")))
      bad <- c(bad, paste0(v, "='", x, "' (want TRUE or FALSE)"))
  }
  w <- Sys.getenv("OUTPATIENT_WINDOW", unset = "")
  if (nzchar(w) && !(w %in% c("30", "60", "90")))
    bad <- c(bad, paste0("OUTPATIENT_WINDOW='", w, "' (want 30, 60 or 90)"))

  # The text, not what coercion makes of it: as.integer("18.5") is 18, so a
  # decimal would pass here and the build would quietly use a different age
  # than the one asked for.
  a <- trimws(Sys.getenv("MIN_AGE", unset = ""))
  if (nzchar(a) && !grepl("^[0-9]+$", a))
    bad <- c(bad, paste0("MIN_AGE='", a, "' (want a whole number)"))

  # The study window is fixed in config_prompts.R and nothing reads these.
  # Validating them would suggest they work.
  for (v in c("STUDY_START", "STUDY_END", "ID_START", "ID_END")) {
    if (nzchar(Sys.getenv(v, unset = "")))
      bad <- c(bad, paste0(v, " is set but ignored - the study window is fixed"))
  }
  # A schema name reaches every statement this build writes, so it is checked
  # the way the other packages check theirs - a bare identifier, not just "no
  # dot". All three sources, because pin_output_schema falls through them.
  for (v in c("PROJECT_WORK_SCHEMA", "DOMINO_USER_NAME", "DOMINO_STARTING_USERNAME")) {
    x <- trimws(Sys.getenv(v, unset = ""))
    if (nzchar(x) && !grepl("^[A-Za-z_][A-Za-z0-9_]*$", x))
      bad <- c(bad, paste0(v, "='", x, "' (want a schema name on its own, ",
                           "letters, digits and underscores)"))
  }
  if (length(bad))
    stop("Bad settings:\n  ", paste(bad, collapse = "\n  "), call. = FALSE)
  invisible(TRUE)
}

# Refuse to start while another run is building this prefix.
#
# Every output name is the prefix plus the table, with no run id in it, so two
# runs on one prefix replace each other's checkpoints while the other is still
# reading them - and both can reach "complete" with the final cohort and the
# attrition built from different executions. That is a population error, not
# just untidy metadata.
#
# Read before the status row is written, because writing it destroys the
# evidence: this table is CREATE OR REPLACE, so it holds one row, and the
# second run's "started" overwrites the first's.
#
# A check, not a lock. Two runs starting in the same second can both pass it.
# It catches the case worth catching - starting a second run while one is
# going - and says so.
check_no_active_run_overall <- function(conn, cfg) {
  tbl <- build_status_table(cfg)
  d <- tryCatch(DBI::dbGetQuery(conn$con, paste0(
         "SELECT run_id, state, updated_at FROM ", tbl)),
       error = function(e) NULL)
  # No table yet on a first run, and nothing to collide with.
  if (is.null(d) || !nrow(d)) return(invisible(TRUE))
  me    <- get0("run_id", ifnotfound = "")
  state <- tolower(trimws(as.character(d$state[1])))
  who   <- as.character(d$run_id[1])
  if (!identical(state, "started") || identical(who, me)) return(invisible(TRUE))
  if (identical(toupper(Sys.getenv("OVERALL_IGNORE_ACTIVE_RUN", unset = "")), "TRUE")) {
    log_msg("WARNING: run ", who, " is marked started on prefix '",
            cfg$object_prefix, "' and OVERALL_IGNORE_ACTIVE_RUN is set. If it ",
            "is still running, both sets of outputs will be wrong.")
    return(invisible(TRUE))
  }
  stop("Run ", who, " is already building prefix '", cfg$object_prefix,
       "' (started ", d$updated_at[1], "). Every output name is the prefix ",
       "plus the table, so two runs would replace each other's tables while ",
       "the other is reading them, and both could still finish. Use a ",
       "different OBJECT_PREFIX, or wait. If that run is known to be dead, ",
       "set OVERALL_IGNORE_ACTIVE_RUN=TRUE.", call. = FALSE)
}

build_status_table <- function(cfg) {
  obj <- paste0(tolower(cfg$object_prefix), "build_status")
  if (nzchar(cfg$catalog))
    paste0(cfg$catalog, ".", cfg$work_schema, ".", obj)
  else paste0(cfg$work_schema, ".", obj)
}

# How the last run ended. A run that dies halfway leaves some tables from this
# run and some from the one before, and nothing else says so.
write_build_status <- function(conn, cfg, state) {
  tbl <- build_status_table(cfg)
  q <- function(x) paste0("'", gsub("'", "''", as.character(x)), "'")
  DBI::dbExecute(conn$con, paste0(
    "CREATE OR REPLACE TABLE ", tbl, " AS SELECT ",
    q(get0("run_id", ifnotfound = "")), " AS run_id, ",
    q(state), " AS state, ",
    q(cfg$final_table_name), " AS final_table_name, ",
    q(format(Sys.time(), "%Y-%m-%d %H:%M:%S")), " AS updated_at"))
  log_msg("Build status: ", state, " (", tbl, ")")
  invisible(TRUE)
}

# What counts as a usable row in each list. A row count isn't enough:
# normalization strips punctuation, so a code of "--" becomes "" and still
# counts. The columns differ per list - dx lists carry dx, the procedure/NDC
# lists carry code and code_type - so each one is spelled out rather than
# guessed from the name.
NORMALIZED_CODELISTS <- list(
  mm_dx_codes       = "dx",
  mm_therapy_codes  = c("code", "code_type"),
  preg_codes        = c("code", "code_type"),
  clintrial_codes   = c("code", "code_type"),
  other_malig_codes = c("dx", "tumor_group")
)

check_normalized_codelist <- function(conn, cfg, view_name, mat_tables) {
  cols <- NORMALIZED_CODELISTS[[view_name]]
  if (is.null(cols)) return(invisible(TRUE))
  where <- paste(sprintf("%s IS NOT NULL AND trim(%s) <> ''", cols, cols),
                 collapse = " AND ")
  n <- DBI::dbGetQuery(conn$con, paste0(
    "SELECT count(*) AS n FROM ", get(view_name, envir = mat_tables),
    " WHERE ", where))$n
  if (is.na(n) || n == 0)
    stop("Code list '", view_name, "' has no usable codes.", call. = FALSE)
  log_msg("  code list ", view_name, ": ", format(n, big.mark = ","), " codes")
  invisible(TRUE)
}

# One schema for everything: <catalog>.<schema>, e.g. hive_metastore.usr00000.
# work and personal schema are set together, and no schema is an error rather
# than a silently skipped write.
pin_output_schema <- function(cfg) {
  schema <- Sys.getenv("PROJECT_WORK_SCHEMA",
              unset = Sys.getenv("DOMINO_USER_NAME",
                unset = Sys.getenv("DOMINO_STARTING_USERNAME", unset = "")))
  if (!nzchar(schema)) {
    stop("No output schema. Set DOMINO_USER_NAME to your personal schema ",
         "(e.g. usr00000), or PROJECT_WORK_SCHEMA to override.", call. = FALSE)
  }
  if (!grepl("^[A-Za-z_][A-Za-z0-9_]*$", trimws(schema)))
    stop("Output schema '", schema, "' is not a schema name. Give the schema ",
         "on its own - letters, digits and underscores - with no catalog and ",
         "no punctuation.", call. = FALSE)
  cfg$work_schema     <- schema
  cfg$personal_schema <- schema
  cfg$object_prefix   <- Sys.getenv("OBJECT_PREFIX", unset = "")
  cfg
}

# Which views get written to the schema. "*" is every step, which is what the
# cohort configs use. Or name them, pipe-separated, in config.csv.
resolve_checkpoints <- function() {
  v <- Sys.getenv("CHECKPOINT_STEPS", unset = "")
  if (!nzchar(v)) return(CHECKPOINT_STEPS)
  s <- trimws(strsplit(v, "[|,]")[[1]])
  s[nzchar(s)]
}

# The view a step creates - not its name. 24_ELIG_COH_FINAL creates the view
# named by FINAL_TABLE_NAME; 06c_validate_rvnu_cd creates rvnu_cd_check.
# NA when the step writes a table (24b).
step_view_name <- function(sql) {
  m <- regmatches(sql, regexpr("CREATE OR REPLACE TEMPORARY VIEW +[^ \n]+",
                               sql, ignore.case = TRUE))
  if (!length(m)) return(NA_character_)
  sub("CREATE OR REPLACE TEMPORARY VIEW +", "", m[1], ignore.case = TRUE)
}

# Skip the final cohort view - 24b writes that table already.
is_checkpoint <- function(view_name, ckpt_steps, cfg) {
  if (is.na(view_name)) return(FALSE)
  if (identical(view_name, cfg$final_table_name)) return(FALSE)
  identical(ckpt_steps, "*") || view_name %in% ckpt_steps
}

# Source this folder's modules. Call before build_cohort().
# Order matters: cfg_defaults reads Sys.getenv() when sourced, so config.csv
# has to be applied first. A real env var still wins over the file.
load_cohort_modules <- function(root) {
  d <- file.path(root, "R")
  source(file.path(d, "load_inputs.R"))
  if (!file.exists(file.path(root, "config.csv")))
    stop("No config.csv in ", root, call. = FALSE)
  load_pipeline_inputs(root, filename = "config.csv")
  for (f in c("config_prompts.R", "db_utils.R",
              "criteria_attrition.R", "pipeline_steps.R"))
    source(file.path(d, f))
  invisible(TRUE)
}
