# =============================================================================
# build_cohort.R -- run the cohort steps and report attrition
# -----------------------------------------------------------------------------
# The body of apr_30_2026/01_cohort.R's main(), unchanged, with one difference:
# it takes the folder whose config.csv should be applied. That is what lets
# overall/ and ndmm/ run the same SQL with different switches.
#
# Each cohort folder's build.R calls build_cohort(<its own folder>).
# =============================================================================

build_cohort <- function(cohort_dir, root = dirname(cohort_dir)) {
  user_cfg    <- prompt_user_options(cfg_defaults)
  ie_criteria <- prompt_ie_criteria(cfg_defaults)
  cfg         <- finalize_cfg(cfg_defaults, user_cfg, ie_criteria)

  log_msg("=", SEP_59)
  log_msg("COHORT BUILD - ", basename(cohort_dir), " - run_id: ", run_id)
  log_msg("OUTPATIENT WINDOW: ", cfg$outpatient_window, " days")
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
  load_phase_steps(file.path(root, "R", "steps"))
  steps <- Filter(Negate(is.null), build_steps(cfg, mat_tables))

  cat("\n", SEP_60, "\n", sep = "")
  cat("  STARTING BUILD: ", length(steps), " steps\n")
  cat(SEP_60, "\n")

  for (i in seq_along(steps)) {
    s <- steps[[i]]
    table_name <- sub("^\\d+[a-z]?_", "", s$name)
    is_ckpt <- isTRUE(cfg$materialize_checkpoints) && table_name %in% CHECKPOINT_STEPS

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

  tryCatch({
    h <- make_naming_helpers(cfg, mat_tables)
    catalog <- build_criteria_catalog(cfg)
    rows <- run_attrition_report(catalog, cfg, conn, h$work_tbl)
    if (isTRUE(cfg$persist_to_schema)) persist_attrition_table(rows, cfg, conn)
    print_cohort_characteristics(cfg, conn, h$work_tbl)
  }, error = function(e) {
    log_msg("WARN: could not generate the full attrition report: ",
            conditionMessage(e))
  })
  log_msg("=", SEP_59)

  invisible(list(cfg = cfg, conn = conn, mat_tables = mat_tables))
}

# Source the shared modules. Call before build_cohort().
#
# Order matters and is the same order 01_cohort.R uses: the config CSVs are
# applied BEFORE config_prompts.R is sourced, because cfg_defaults reads
# Sys.getenv() at source time. Source it first and the CSV values never reach
# it -- the build silently runs on code defaults.
#
# The cohort's own config.csv is read before the shared pipeline_inputs.csv,
# and load_pipeline_inputs() only fills variables that are still unset, so the
# cohort's value wins. A real env var, set before either, wins over both.
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
