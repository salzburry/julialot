# Cohort runner for overall/. build.R calls build_cohort(<this folder>).

build_cohort <- function(cohort_dir, root = cohort_dir, expect_table = NULL) {
  user_cfg    <- prompt_user_options(cfg_defaults)
  ie_criteria <- prompt_ie_criteria(cfg_defaults)
  cfg         <- pin_output_schema(finalize_cfg(cfg_defaults, user_cfg, ie_criteria))
  check_output_contract(cfg, expect_table)

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
  log_msg("=", SEP_59)

  invisible(list(cfg = cfg, conn = conn, mat_tables = mat_tables))
}

# A cohort folder states the table it must write; anything else is a mistake.
# config.csv only fills FINAL_TABLE_NAME when it is unset, so an ambient
# FINAL_TABLE_NAME=ELIG_COH_FINAL would quietly send this build at the legacy
# table. PERSIST_TO_SCHEMA=FALSE is worse: the run looks complete but the
# cohort only ever existed as a temp view.
check_output_contract <- function(cfg, expect_table) {
  if (!is.null(expect_table) && !identical(cfg$final_table_name, expect_table)) {
    stop("This build writes ", expect_table, ", but FINAL_TABLE_NAME is '",
         cfg$final_table_name, "'. Unset it, or fix config.csv.", call. = FALSE)
  }
  if (!isTRUE(cfg$persist_to_schema)) {
    stop("PERSIST_TO_SCHEMA is FALSE, so nothing would be written. ",
         "Set it TRUE to build a cohort.", call. = FALSE)
  }
  invisible(TRUE)
}

# The five cohort code lists. An empty one doesn't error - it makes an empty
# view, and the build runs to completion with a wrong cohort: no MM dx list
# gives no patients, no therapy list drops everyone at Step 6, an empty
# exclusion list passes everyone.
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
  if (file.exists(file.path(root, "config.csv")))
    load_pipeline_inputs(root, filename = "config.csv")
  load_pipeline_inputs(c(root, dirname(root)))
  for (f in c("config_prompts.R", "db_utils.R", "codelists.R",
              "criteria_attrition.R", "pipeline_steps.R"))
    source(file.path(d, f))
  invisible(TRUE)
}
