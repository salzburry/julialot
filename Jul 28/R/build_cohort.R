# Shared cohort runner. Each cohort folder supplies its own config.csv and
# calls build_cohort(<its own folder>).

build_cohort <- function(cohort_dir, root = dirname(cohort_dir)) {
  user_cfg    <- prompt_user_options(cfg_defaults)
  ie_criteria <- prompt_ie_criteria(cfg_defaults)
  cfg         <- pin_output_schema(finalize_cfg(cfg_defaults, user_cfg, ie_criteria))

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
    table_name <- sub("^\\d+[a-z]?_", "", s$name)
    is_ckpt <- isTRUE(cfg$materialize_checkpoints) && table_name %in% ckpt_steps

    with_retry(function() {
      run_step(s$name, s$sql, conn = conn, cfg = cfg,
               qc_sql = if (is_ckpt) NULL else s$qc,
               description = s$description,
               step_num = i, total_steps = length(steps),
               source_tables = s$source_tables)
    }, max_retries = cfg$max_retries, base_sleep = cfg$base_sleep)

    if (is_ckpt) {
      ok <- materialize_to_personal_schema(conn$con, table_name, cfg,
                                           mat_tables, replace = TRUE)
      if (nzchar(cfg$personal_schema) && !isTRUE(ok)) {
        stop("Checkpoint '", table_name, "' failed to materialize to '",
             cfg$personal_schema, "'. See the WARN above.")
      }
      with_retry(function() run_qc(conn$con, s$qc),
                 max_retries = cfg$max_retries, base_sleep = cfg$base_sleep)
    }
  }

  log_msg("=", SEP_59)
  log_msg("BUILD COMPLETE - generating attrition report...")

  # No tryCatch. The attrition table is a deliverable - if it can't be
  # produced, the run failed.
  h <- make_naming_helpers(cfg, mat_tables)
  catalog <- build_criteria_catalog(cfg)
  rows <- run_attrition_report(catalog, cfg, conn, h$work_tbl)
  if (isTRUE(cfg$persist_to_schema)) persist_attrition_table(rows, cfg, conn)
  print_cohort_characteristics(cfg, conn, h$work_tbl)
  log_msg("=", SEP_59)

  invisible(list(cfg = cfg, conn = conn, mat_tables = mat_tables))
}

# One schema for everything this build writes - checkpoints, the final cohort,
# attrition_report - as <catalog>.<schema>, e.g. hive_metastore.osk02156.
# config_prompts.R resolves work_schema and personal_schema separately and
# personal_schema can come back empty, which silently skips writing the cohort.
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
  cfg
}

# Which views get written to the schema. Everything else stays a temp view and
# is gone when the session ends. Set per cohort in config.csv, pipe-separated:
#
#   CHECKPOINT_STEPS,mm_dx_events_all|mm_dx_events_id|mm_qualifying|ELIG_COH_ALLFLAGS
resolve_checkpoints <- function() {
  v <- Sys.getenv("CHECKPOINT_STEPS", unset = "")
  if (!nzchar(v)) return(CHECKPOINT_STEPS)
  s <- trimws(strsplit(v, "[|,]")[[1]])
  s[nzchar(s)]
}

# Source the shared modules. Call before build_cohort().
#
# Order matters: cfg_defaults reads Sys.getenv() at source time, so the config
# CSVs must be applied before config_prompts.R is sourced. The cohort's own
# config.csv is read first and wins over pipeline_inputs.csv; a real env var
# set before either wins over both.
load_cohort_modules <- function(root, cohort_dir = NULL) {
  d <- file.path(root, "R")
  source(file.path(d, "load_inputs.R"))
  if (!is.null(cohort_dir) && file.exists(file.path(cohort_dir, "config.csv")))
    load_pipeline_inputs(cohort_dir, filename = "config.csv")
  load_pipeline_inputs(root)
  for (f in c("config_prompts.R", "db_utils.R", "codelists.R",
              "criteria_attrition.R", "pipeline_steps.R"))
    source(file.path(d, f))
  invisible(TRUE)
}
