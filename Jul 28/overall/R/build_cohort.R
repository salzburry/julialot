# Cohort runner for overall/. build.R calls build_cohort(<this folder>).

build_cohort <- function(cohort_dir, root = cohort_dir, expect_table = NULL,
                         expect_prefix = NULL) {
  check_settings()
  user_cfg    <- prompt_user_options(cfg_defaults)
  ie_criteria <- prompt_ie_criteria(cfg_defaults)
  cfg         <- pin_output_schema(finalize_cfg(cfg_defaults, user_cfg, ie_criteria))
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

  write_build_status(conn, cfg, "started")
  # Any failure past this point leaves half the tables from this run and half
  # from the last one. Record that rather than leaving it to be discovered.
  if (!interactive()) {
    on.exit({
      st <- get0(".build_state", ifnotfound = "failed")
      if (!identical(st, "complete"))
        try(write_build_status(conn, cfg, "failed"), silent = TRUE)
    }, add = TRUE, after = FALSE)
  }

  load_csv_codelists(conn, cfg)
  check_codelists_not_empty(conn, cfg)

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
      ok <- materialize_to_personal_schema(conn$con, view_name, cfg,
                                           mat_tables, replace = TRUE)
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

  .build_state <<- "complete"
  write_build_status(conn, cfg, "complete")
  log_msg("=", SEP_59)

  invisible(list(cfg = cfg, conn = conn, mat_tables = mat_tables))
}

# What this build must write. config.csv only fills a variable when it is
# unset, so an ambient value wins over the committed one - the table name, the
# prefix and the checkpoint set all have to be checked, not just defaulted.
check_output_contract <- function(cfg, expect_table, expect_prefix = NULL) {
  if (!is.null(expect_table) && !identical(cfg$final_table_name, expect_table)) {
    stop("This build writes ", expect_table, ", but FINAL_TABLE_NAME is '",
         cfg$final_table_name, "'. Unset it, or fix config.csv.", call. = FALSE)
  }
  if (!is.null(expect_prefix) && !identical(cfg$object_prefix, expect_prefix)) {
    stop("This build prefixes its tables '", expect_prefix,
         "', but OBJECT_PREFIX is '", cfg$object_prefix,
         "'. Wrong prefix overwrites the other cohort.", call. = FALSE)
  }
  if (!identical(resolve_checkpoints(), "*")) {
    stop("CHECKPOINT_STEPS must be '*' so every step is written to the schema. ",
         "It is '", paste(resolve_checkpoints(), collapse = "|"), "'.",
         call. = FALSE)
  }
  if (!isTRUE(cfg$persist_to_schema)) {
    stop("PERSIST_TO_SCHEMA is FALSE, so nothing would be written. ",
         "Set it TRUE to build a cohort.", call. = FALSE)
  }
  invisible(TRUE)
}

# The Apr 30 config fails open: as.logical("Y") is NA and isTRUE(NA) is FALSE,
# so a typo silently drops a criterion; validate_outpatient_window() silently
# substitutes 90. Environment wins over config.csv, so a committed file does
# not protect against either. Check the raw values before anything runs.
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

  a <- Sys.getenv("MIN_AGE", unset = "")
  if (nzchar(a) && is.na(suppressWarnings(as.integer(a))))
    bad <- c(bad, paste0("MIN_AGE='", a, "' (want a whole number)"))

  # as.Date("30-06-2025", "%Y-%m-%d") returns year 30 rather than failing, so
  # check the shape first.
  for (v in c("STUDY_START", "STUDY_END", "ID_START", "ID_END")) {
    x <- Sys.getenv(v, unset = "")
    if (!nzchar(x)) next
    if (!grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", x) ||
        is.na(suppressWarnings(as.Date(x, "%Y-%m-%d"))))
      bad <- c(bad, paste0(v, "='", x, "' (want YYYY-MM-DD)"))
  }
  for (v in c("PROJECT_WORK_SCHEMA", "DOMINO_USER_NAME")) {
    x <- Sys.getenv(v, unset = "")
    if (grepl(".", x, fixed = TRUE))
      bad <- c(bad, paste0(v, "='", x, "' (a schema name, not catalog.schema)"))
  }
  if (length(bad))
    stop("Bad settings:\n  ", paste(bad, collapse = "\n  "), call. = FALSE)
  invisible(TRUE)
}

# Stop when a required code list has no rows.
check_codelists_not_empty <- function(conn, cfg) {
  required <- c(cfg$cl_mm_dx, cfg$cl_mm_therapy, cfg$cl_preg,
                cfg$cl_clintrial, cfg$cl_other_malig)
  for (tbl in required) {
    src <- if (isTRUE(cfg$use_csv_codelists)) tbl else
      paste0(if (nzchar(cfg$catalog)) paste0(cfg$catalog, ".") else "",
             cfg$ref_schema, ".", tbl)
    n <- DBI::dbGetQuery(conn$con, paste0("SELECT count(*) AS n FROM ", src))$n
    if (is.na(n) || n == 0) stop("Code list '", src, "' is empty.", call. = FALSE)
    log_msg("  code list ", tbl, ": ", format(n, big.mark = ","), " rows")
  }
  invisible(TRUE)
}

# Where this build writes: one schema for everything - every step, the final
# cohort, attrition_report - as <catalog>.<schema>, e.g. hive_metastore.osk02156.
# config_prompts.R resolves work_schema and personal_schema separately and
# personal_schema can come back empty, which silently skips writing the cohort.
#
# OBJECT_PREFIX keeps the two cohorts apart in that one schema.
pin_output_schema <- function(cfg) {
  schema <- Sys.getenv("PROJECT_WORK_SCHEMA",
              unset = Sys.getenv("DOMINO_USER_NAME",
                unset = Sys.getenv("DOMINO_STARTING_USERNAME", unset = "")))
  if (!nzchar(schema)) {
    stop("No output schema. Set DOMINO_USER_NAME to your personal schema ",
         "(e.g. osk02156), or PROJECT_WORK_SCHEMA to override.", call. = FALSE)
  }
  cfg$work_schema     <- schema
  cfg$personal_schema <- schema
  cfg$object_prefix   <- Sys.getenv("OBJECT_PREFIX", unset = "")
  cfg
}

# Which views get written to the schema. "*" means every step, which is what
# the cohort configs use -- nothing then depends on a temp view surviving, and
# every table is there to query after the run. Set per cohort in config.csv,
# pipe-separated, or name specific steps:
#
#   CHECKPOINT_STEPS,*
#   CHECKPOINT_STEPS,mm_dx_events_all|mm_qualifying|ELIG_COH_ALLFLAGS
resolve_checkpoints <- function() {
  v <- Sys.getenv("CHECKPOINT_STEPS", unset = "")
  if (!nzchar(v)) return(CHECKPOINT_STEPS)
  s <- trimws(strsplit(v, "[|,]")[[1]])
  s[nzchar(s)]
}

# The view a step creates. Not the same as the step name: 24_ELIG_COH_FINAL
# creates the view named by FINAL_TABLE_NAME, and 06c_validate_rvnu_cd creates
# rvnu_cd_check. Materializing by step name would look for a view that isn't
# there. NA when the step writes a real table rather than a view (24b).
step_view_name <- function(sql) {
  m <- regmatches(sql, regexpr("CREATE OR REPLACE TEMPORARY VIEW +[^ \n]+",
                               sql, ignore.case = TRUE))
  if (!length(m)) return(NA_character_)
  sub("CREATE OR REPLACE TEMPORARY VIEW +", "", m[1], ignore.case = TRUE)
}

# The final cohort view is skipped: step 24b already writes it as a permanent
# table under its own name, which is what LOT reads.
is_checkpoint <- function(view_name, ckpt_steps, cfg) {
  if (is.na(view_name)) return(FALSE)
  if (identical(view_name, cfg$final_table_name)) return(FALSE)
  identical(ckpt_steps, "*") || view_name %in% ckpt_steps
}

# Source this folder's modules. Call before build_cohort().
#
# Order matters: cfg_defaults reads Sys.getenv() at source time, so the config
# has to be applied before config_prompts.R is sourced. config.csv is read
# first and wins; pipeline_inputs.csv (this folder, else Jul 28/) fills the
# rest. A real env var set before either wins over both.
load_cohort_modules <- function(root) {
  d <- file.path(root, "R")
  source(file.path(d, "load_inputs.R"))
  if (!file.exists(file.path(root, "config.csv")))
    stop("No config.csv in ", root, call. = FALSE)
  load_pipeline_inputs(root, filename = "config.csv")
  if (!isTRUE(load_pipeline_inputs(c(root, dirname(root)))))
    stop("No pipeline_inputs.csv in ", root, " or ", dirname(root),
         ". Running on code defaults would be silently wrong.", call. = FALSE)
  for (f in c("config_prompts.R", "db_utils.R", "codelists.R",
              "criteria_attrition.R", "pipeline_steps.R"))
    source(file.path(d, f))
  invisible(TRUE)
}
