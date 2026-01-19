#!/usr/bin/env Rscript
#' Main Entry Point for Attrition Cohort Pipeline
#'
#' This script runs the complete attrition cohort build pipeline
#' on Databricks via ODBC. Designed for Domino execution.
#'
#' Usage:
#'   Rscript R/run_pipeline.R [--env=dev|test|prod] [--config=path/to/config.yaml]
#'                            [--resume=path/to/checkpoint.rds] [--dry-run]
#'
#' Environment Variables:
#'   DATABRICKS_DSN     - ODBC DSN name (preferred)
#'   DATABRICKS_HOST    - Databricks host (if no DSN)
#'   DATABRICKS_TOKEN   - Personal access token
#'   DATABRICKS_HTTP_PATH - SQL warehouse HTTP path
#'   DATABRICKS_CATALOG - Unity Catalog name (optional)

# ============================================================================
# SETUP
# ============================================================================

# Get script directory for sourcing
script_dir <- if (interactive()) {
  "R"
} else {
  dirname(sub("--file=", "", commandArgs()[grep("--file=", commandArgs())]))
}

# Source all required modules
source(file.path(script_dir, "databricks_connection.R"))
source(file.path(script_dir, "config_databricks.R"))
source(file.path(script_dir, "sql_builder.R"))
source(file.path(script_dir, "pipeline_orchestrator.R"))

# ============================================================================
# ARGUMENT PARSING
# ============================================================================

parse_arguments <- function() {
  args <- commandArgs(trailingOnly = TRUE)

  parsed <- list(
    env = "dev",
    config_file = NULL,
    resume_from = NULL,
    dry_run = FALSE,
    help = FALSE
  )

  for (arg in args) {
    if (arg == "--help" || arg == "-h") {
      parsed$help <- TRUE
    } else if (grepl("^--env=", arg)) {
      parsed$env <- sub("^--env=", "", arg)
    } else if (grepl("^--config=", arg)) {
      parsed$config_file <- sub("^--config=", "", arg)
    } else if (grepl("^--resume=", arg)) {
      parsed$resume_from <- sub("^--resume=", "", arg)
    } else if (arg == "--dry-run") {
      parsed$dry_run <- TRUE
    }
  }

  parsed
}

print_help <- function() {
  cat("
ATTRITION COHORT PIPELINE - Databricks/Domino
==============================================

Usage:
  Rscript R/run_pipeline.R [OPTIONS]

Options:
  --env=ENV           Environment: dev, test, prod (default: dev)
  --config=FILE       Path to YAML configuration file
  --resume=FILE       Resume from checkpoint file
  --dry-run           Print SQL without executing
  --help, -h          Show this help message

Environment Variables:
  DATABRICKS_DSN        ODBC DSN name (recommended)
  DATABRICKS_HOST       Databricks workspace host
  DATABRICKS_TOKEN      Personal access token
  DATABRICKS_HTTP_PATH  SQL warehouse HTTP path
  DATABRICKS_CATALOG    Unity Catalog name (optional)

Examples:
  # Run with defaults (dev environment)
  Rscript R/run_pipeline.R

  # Run production build
  Rscript R/run_pipeline.R --env=prod

  # Run with custom config
  Rscript R/run_pipeline.R --config=config/my_config.yaml

  # Resume from checkpoint
  Rscript R/run_pipeline.R --resume=checkpoints/pipeline_20260119.rds

  # Dry run (print SQL only)
  Rscript R/run_pipeline.R --dry-run
")
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

main <- function() {
  # Parse arguments
  args <- parse_arguments()

  if (args$help) {
    print_help()
    return(invisible(0))
  }

  # Set log level
  set_log_level("INFO")

  log_info("=" %rep% 60)
  log_info("ATTRITION COHORT PIPELINE")
  log_info(sprintf("Started: %s", Sys.time()))
  log_info("=" %rep% 60)

  # Load configuration
  config <- if (!is.null(args$config_file)) {
    log_info(sprintf("Loading config from: %s", args$config_file))
    load_config_from_yaml(args$config_file)
  } else {
    log_info(sprintf("Using default config for environment: %s", args$env))
    create_databricks_config(args$env)
  }

  # Print configuration
  print_databricks_config(config)

  # Connect to Databricks
  con <- NULL
  tryCatch({
    if (args$dry_run) {
      log_info("DRY RUN MODE - SQL will be printed but not executed")
      con <- NULL
    } else {
      log_info("Connecting to Databricks...")
      con <- create_databricks_connection(config, max_retries = config$pipeline$max_retries)
    }

    # Run pipeline
    state <- run_pipeline(
      con = con,
      config = config,
      resume_from = args$resume_from,
      skip_completed = !is.null(args$resume_from),
      dry_run = args$dry_run
    )

    # Validate results (if not dry run)
    if (!args$dry_run) {
      validations <- validate_pipeline_results(con, config)

      # Generate attrition table if configured
      if (config$output$generate_attrition_table) {
        generate_output_attrition_table(con, config)
      }
    }

    log_info("Pipeline completed successfully!")

  }, error = function(e) {
    log_error(sprintf("Pipeline failed: %s", e$message))
    log_error("Check checkpoint file for resume capability")
    stop(e)

  }, finally = {
    # Clean up connection
    if (!is.null(con)) {
      safe_disconnect(con)
    }
  })

  invisible(0)
}

#' Generate output attrition table from final cohort
#' @keywords internal
generate_output_attrition_table <- function(con, config) {
  log_info("Generating attrition table...")

  # Query to get counts at each step
  attrition_sql <- glue::glue("
WITH base AS (
  SELECT COUNT(*) AS n FROM {work_table(config, 'mm_dx_events')}
  WHERE 1=1
  GROUP BY 1
),
step1 AS (
  SELECT COUNT(*) AS n FROM {work_table(config, 'mm_qualifying')}
),
step2 AS (
  SELECT COUNT(*) AS n FROM {work_table(config, 'ELIG_COH_ALLFLAGS')}
  WHERE AGE_INDEX_YR >= 18
),
step3 AS (
  SELECT COUNT(*) AS n FROM {work_table(config, 'ELIG_COH_ALLFLAGS')}
  WHERE AGE_INDEX_YR >= 18 AND MM_FU_agents = 1
),
step4 AS (
  SELECT COUNT(*) AS n FROM {work_table(config, 'ELIG_COH_ALLFLAGS')}
  WHERE AGE_INDEX_YR >= 18 AND MM_FU_agents = 1 AND MM_bl_agents = 0
),
step5 AS (
  SELECT COUNT(*) AS n FROM {work_table(config, 'ELIG_COH_ALLFLAGS')}
  WHERE AGE_INDEX_YR >= 18 AND MM_FU_agents = 1 AND MM_bl_agents = 0 AND CE_b = 1
),
step6 AS (
  SELECT COUNT(*) AS n FROM {work_table(config, 'ELIG_COH_FINAL')}
)
SELECT 'Step 0: Base MM Diagnosis' AS step, (SELECT COUNT(DISTINCT PATID) FROM {work_table(config, 'mm_dx_events')}) AS n
UNION ALL SELECT 'Step 1: Qualifying MM Diagnosis', n FROM step1
UNION ALL SELECT 'Step 2: Age >= 18', n FROM step2
UNION ALL SELECT 'Step 3: MM Therapy in Follow-up', n FROM step3
UNION ALL SELECT 'Step 4: No MM Therapy in Baseline', n FROM step4
UNION ALL SELECT 'Step 5: Baseline CE >= 6 months', n FROM step5
UNION ALL SELECT 'Step 6: Final Cohort (CE_f = 1)', n FROM step6
ORDER BY step
")

  tryCatch({
    result <- query_with_retry(con, attrition_sql, config, operation_name = "Attrition counts")

    # Calculate percentages
    base_n <- result$n[1]
    result$pct <- round(result$n / base_n * 100, 1)

    # Print
    cat("\n")
    cat("=" %rep% 70, "\n")
    cat("ATTRITION TABLE\n")
    cat("=" %rep% 70, "\n")
    for (i in seq_len(nrow(result))) {
      cat(sprintf("%-45s %10s (%5.1f%%)\n",
                  result$step[i],
                  format(result$n[i], big.mark = ","),
                  result$pct[i]))
    }
    cat("=" %rep% 70, "\n")

    # Export if directory exists
    output_dir <- config$output$results_dir
    if (dir.exists(output_dir)) {
      output_file <- file.path(output_dir,
                               sprintf("attrition_table_%s.csv", format(Sys.Date(), "%Y%m%d")))
      write.csv(result, output_file, row.names = FALSE)
      log_info(sprintf("Attrition table saved to: %s", output_file))
    }

  }, error = function(e) {
    log_warn(sprintf("Failed to generate attrition table: %s", e$message))
  })
}

# ============================================================================
# INTERACTIVE HELPERS
# ============================================================================

#' Run pipeline interactively with prompts
#' @export
run_interactive <- function() {
  cat("\n")
  cat("ATTRITION COHORT PIPELINE - Interactive Mode\n")
  cat("=============================================\n\n")

  # Select environment
  cat("Select environment:\n")
  cat("  1. dev (default)\n")
  cat("  2. test\n")
  cat("  3. prod\n")
  choice <- readline("Enter choice [1]: ")
  env <- switch(choice, "2" = "test", "3" = "prod", "dev")

  # Create config
  config <- create_databricks_config(env)
  print_databricks_config(config)

  # Confirm
  proceed <- readline("\nProceed with this configuration? [Y/n]: ")
  if (tolower(proceed) == "n") {
    cat("Aborted.\n")
    return(invisible(NULL))
  }

  # Connect and run
  log_info("Connecting to Databricks...")
  con <- create_databricks_connection(config)

  tryCatch({
    state <- run_pipeline(con, config)
    validate_pipeline_results(con, config)
  }, finally = {
    safe_disconnect(con)
  })
}

#' Quick start: source all files and show help
#' @export
quick_start <- function() {
  cat("\n")
  cat("ATTRITION COHORT PIPELINE - Quick Start\n")
  cat("========================================\n\n")

  cat("Available functions:\n")
  cat("  create_databricks_config(env)  - Create configuration\n")
  cat("  create_databricks_connection(config)  - Connect to Databricks\n")
  cat("  run_pipeline(con, config)      - Run full pipeline\n")
  cat("  run_interactive()              - Interactive mode with prompts\n")
  cat("  print_databricks_config(config) - Print configuration\n")
  cat("\n")
  cat("Example:\n")
  cat("  config <- create_databricks_config('dev')\n")
  cat("  con <- create_databricks_connection(config)\n")
  cat("  run_pipeline(con, config)\n")
  cat("\n")
  cat("Or from command line:\n")
  cat("  Rscript R/run_pipeline.R --env=prod\n")
  cat("\n")
}

# ============================================================================
# RUN IF EXECUTED AS SCRIPT
# ============================================================================

if (!interactive()) {
  status <- main()
  quit(status = status)
} else {
  quick_start()
}
