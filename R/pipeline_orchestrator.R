#' Pipeline Orchestrator for Attrition Cohort Build
#'
#' Manages the execution of SQL pipeline steps with:
#' - Checkpointing for resume after failure
#' - Progress tracking
#' - Error handling and logging
#' - Parallel execution where possible
#' - Resource cleanup

#' Pipeline step definition
#' @export
PipelineStep <- function(name, sql_fn, dependencies = character(),
                         description = "", critical = TRUE, optimize = FALSE,
                         zorder_cols = NULL) {
  list(
    name = name,
    sql_fn = sql_fn,
    dependencies = dependencies,
    description = description,
    critical = critical,
    optimize = optimize,
    zorder_cols = zorder_cols
  )
}

#' Define the attrition cohort pipeline steps
#' @export
define_pipeline_steps <- function() {
  list(
    # Phase 1: Code list normalization
    PipelineStep("mm_dx_codes", sql_mm_dx_codes,
                 description = "Normalize MM diagnosis codes"),
    PipelineStep("diag_proc_codes", sql_diagnostic_proc_codes,
                 description = "Normalize diagnostic procedure codes"),
    PipelineStep("mm_therapy_codes", sql_therapy_codes,
                 description = "Normalize MM therapy codes"),
    PipelineStep("preg_codes", sql_pregnancy_codes,
                 description = "Normalize pregnancy codes"),
    PipelineStep("clintrial_codes", sql_clintrial_codes,
                 description = "Normalize clinical trial codes"),
    PipelineStep("other_malig_codes", sql_other_malig_codes,
                 description = "Normalize other malignancy codes"),

    # Phase 2: Base data extraction
    PipelineStep("med_claim_header", sql_med_claim_header,
                 dependencies = c(),
                 description = "Extract medical claim headers",
                 optimize = TRUE, zorder_cols = c("PATID")),
    PipelineStep("mm_dx_events", sql_mm_dx_events,
                 dependencies = c("mm_dx_codes", "med_claim_header"),
                 description = "Extract MM diagnosis events",
                 optimize = TRUE, zorder_cols = c("PATID", "svc_dt")),

    # Phase 3: Index date derivation
    PipelineStep("mm_outpt_dates", function(config) sql_mm_outpt_pairs(config)[[1]],
                 dependencies = c("mm_dx_events"),
                 description = "Extract outpatient MM dates"),
    PipelineStep("mm_outpt_pairs", function(config) sql_mm_outpt_pairs(config)[[2]],
                 dependencies = c("mm_outpt_dates"),
                 description = "Compute outpatient date pairs"),
    PipelineStep("mm_qualifying", sql_mm_qualifying,
                 dependencies = c("mm_dx_events", "mm_outpt_pairs"),
                 description = "Determine qualifying index dates",
                 critical = TRUE,
                 optimize = TRUE, zorder_cols = c("PATID")),

    # Phase 4: Enrollment and demographics
    PipelineStep("enroll_spans", sql_enrollment_spans,
                 dependencies = c(),
                 description = "Build enrollment spans with gap logic",
                 optimize = TRUE, zorder_cols = c("PATID")),
    PipelineStep("ce_flags", sql_ce_flags,
                 dependencies = c("mm_qualifying", "enroll_spans"),
                 description = "Compute CE flags"),
    PipelineStep("member_demo", sql_member_demo,
                 dependencies = c(),
                 description = "Extract member demographics"),

    # Phase 5: Non-diagnostic claims
    PipelineStep("claim_nondiagnostic", sql_claim_nondiagnostic,
                 dependencies = c("diag_proc_codes"),
                 description = "Identify non-diagnostic claims",
                 optimize = TRUE, zorder_cols = c("PATID", "CLMID")),
    PipelineStep("mm_baseline_nondx", sql_mm_baseline_nondx,
                 dependencies = c("mm_qualifying", "mm_dx_events", "claim_nondiagnostic"),
                 description = "Flag MM baseline non-diagnostic (smoldering)"),

    # Phase 6: Therapy events and flags
    PipelineStep("therapy_events", sql_therapy_events,
                 dependencies = c("mm_therapy_codes"),
                 description = "Extract therapy events",
                 optimize = TRUE, zorder_cols = c("PATID", "event_dt")),
    PipelineStep("therapy_flags", sql_therapy_flags,
                 dependencies = c("mm_qualifying", "therapy_events"),
                 description = "Compute therapy flags"),

    # Phase 7: Exclusion flags
    PipelineStep("pregnancy_flag", sql_pregnancy_flag,
                 dependencies = c("mm_qualifying", "preg_codes"),
                 description = "Compute pregnancy flag"),
    PipelineStep("clintrial_flag", sql_clintrial_flag,
                 dependencies = c("mm_qualifying", "clintrial_codes"),
                 description = "Compute clinical trial flag"),
    PipelineStep("other_malig_flag", sql_other_malig_flag,
                 dependencies = c("mm_qualifying", "other_malig_codes", "claim_nondiagnostic"),
                 description = "Compute other malignancy flag"),

    # Phase 8: Final cohort assembly
    PipelineStep("elig_coh_allflags", sql_elig_coh_allflags,
                 dependencies = c("mm_qualifying", "ce_flags", "member_demo",
                                  "mm_baseline_nondx", "therapy_flags",
                                  "pregnancy_flag", "clintrial_flag", "other_malig_flag"),
                 description = "Assemble ELIG_COH with all flags",
                 critical = TRUE,
                 optimize = TRUE, zorder_cols = c("PATID")),
    PipelineStep("elig_coh_final", sql_elig_coh_final,
                 dependencies = c("elig_coh_allflags"),
                 description = "Create final filtered cohort",
                 critical = TRUE,
                 optimize = TRUE, zorder_cols = c("PATID"))
  )
}

#' Pipeline state tracker for checkpointing
#' @export
PipelineState <- R6::R6Class("PipelineState",
  public = list(
    checkpoint_file = NULL,
    completed_steps = character(),
    failed_steps = character(),
    step_timings = list(),
    start_time = NULL,
    config = NULL,

    initialize = function(checkpoint_dir = "checkpoints", run_id = NULL) {
      if (!dir.exists(checkpoint_dir)) {
        dir.create(checkpoint_dir, recursive = TRUE)
      }
      run_id <- run_id %||% format(Sys.time(), "%Y%m%d_%H%M%S")
      self$checkpoint_file <- file.path(checkpoint_dir, paste0("pipeline_", run_id, ".rds"))
      self$start_time <- Sys.time()
    },

    save = function() {
      state <- list(
        completed_steps = self$completed_steps,
        failed_steps = self$failed_steps,
        step_timings = self$step_timings,
        start_time = self$start_time,
        saved_at = Sys.time()
      )
      saveRDS(state, self$checkpoint_file)
      log_debug(sprintf("Checkpoint saved: %s", self$checkpoint_file))
    },

    load = function(checkpoint_file) {
      if (file.exists(checkpoint_file)) {
        state <- readRDS(checkpoint_file)
        self$completed_steps <- state$completed_steps
        self$failed_steps <- state$failed_steps
        self$step_timings <- state$step_timings
        self$start_time <- state$start_time
        self$checkpoint_file <- checkpoint_file
        log_info(sprintf("Resumed from checkpoint: %d steps completed",
                         length(self$completed_steps)))
        return(TRUE)
      }
      return(FALSE)
    },

    mark_completed = function(step_name, duration) {
      self$completed_steps <- unique(c(self$completed_steps, step_name))
      self$step_timings[[step_name]] <- duration
      self$save()
    },

    mark_failed = function(step_name, error) {
      self$failed_steps <- unique(c(self$failed_steps, step_name))
      self$step_timings[[step_name]] <- list(error = error)
      self$save()
    },

    is_completed = function(step_name) {
      step_name %in% self$completed_steps
    },

    get_summary = function() {
      total_time <- as.numeric(difftime(Sys.time(), self$start_time, units = "secs"))
      list(
        completed = length(self$completed_steps),
        failed = length(self$failed_steps),
        total_seconds = total_time,
        step_timings = self$step_timings
      )
    }
  )
)

#' Run the attrition cohort pipeline
#'
#' @param con DBI connection to Databricks
#' @param config Configuration list
#' @param resume_from Optional checkpoint file to resume from
#' @param skip_completed Skip steps already marked complete
#' @param dry_run If TRUE, only print SQL without executing
#' @return Pipeline state with completion status
#' @export
run_pipeline <- function(con, config, resume_from = NULL, skip_completed = TRUE,
                         dry_run = FALSE) {
  log_info("=" %rep% 60)
  log_info("ATTRITION COHORT PIPELINE - STARTING")
  log_info("=" %rep% 60)

  # Initialize or resume state
  state <- PipelineState$new(
    checkpoint_dir = config$pipeline$checkpoint_dir %||% "checkpoints"
  )

  if (!is.null(resume_from) && file.exists(resume_from)) {
    state$load(resume_from)
  }

  # Get pipeline steps
  steps <- define_pipeline_steps()
  step_map <- setNames(steps, sapply(steps, `[[`, "name"))

  # Create working schema
  log_info("Creating working schema...")
  if (!dry_run) {
    tryCatch({
      execute_sql_with_retry(con, sql_create_schema(config), config,
                             operation_name = "Create schema")
    }, error = function(e) {
      log_error(sprintf("Failed to create schema: %s", e$message))
      stop(e)
    })
  }

  # Topological sort for dependency order
  execution_order <- topological_sort(steps)
  log_info(sprintf("Executing %d pipeline steps...", length(execution_order)))

  # Execute steps in order
  for (step_name in execution_order) {
    step <- step_map[[step_name]]

    # Skip if already completed
    if (skip_completed && state$is_completed(step_name)) {
      log_info(sprintf("[SKIP] %s - already completed", step_name))
      next
    }

    # Check dependencies
    missing_deps <- setdiff(step$dependencies, state$completed_steps)
    if (length(missing_deps) > 0) {
      msg <- sprintf("Step '%s' has unmet dependencies: %s",
                     step_name, paste(missing_deps, collapse = ", "))
      if (step$critical) {
        log_error(msg)
        state$mark_failed(step_name, msg)
        stop(msg)
      } else {
        log_warn(paste(msg, "- skipping non-critical step"))
        next
      }
    }

    # Execute step
    log_info(sprintf("[RUN] %s - %s", step_name, step$description))

    tryCatch({
      start_time <- Sys.time()

      # Generate SQL
      sql <- step$sql_fn(config)

      if (dry_run) {
        cat("\n--- SQL for", step_name, "---\n")
        cat(sql, "\n")
      } else {
        # Execute SQL
        execute_sql_with_retry(con, sql, config, operation_name = step_name)

        # Optimize if requested
        if (step$optimize && !is.null(config$pipeline$optimize_tables) &&
            config$pipeline$optimize_tables) {
          optimize_sql <- sql_optimize_table(config, step_name, step$zorder_cols)
          execute_sql_with_retry(con, optimize_sql, config,
                                 operation_name = paste0(step_name, " OPTIMIZE"))
        }
      }

      duration <- as.numeric(difftime(Sys.time(), start_time, units = "secs"))
      state$mark_completed(step_name, duration)
      log_info(sprintf("[DONE] %s completed in %.2f seconds", step_name, duration))

    }, error = function(e) {
      state$mark_failed(step_name, e$message)
      log_error(sprintf("[FAIL] %s failed: %s", step_name, e$message))

      if (step$critical) {
        stop(sprintf("Critical step '%s' failed: %s", step_name, e$message))
      }
    })
  }

  # Print summary
  summary <- state$get_summary()
  log_info("=" %rep% 60)
  log_info("PIPELINE COMPLETE")
  log_info(sprintf("  Completed: %d steps", summary$completed))
  log_info(sprintf("  Failed: %d steps", summary$failed))
  log_info(sprintf("  Total time: %.2f seconds", summary$total_seconds))
  log_info("=" %rep% 60)

  invisible(state)
}

#' Topological sort for dependency resolution
#' @keywords internal
topological_sort <- function(steps) {
  # Build adjacency list
  step_names <- sapply(steps, `[[`, "name")
  deps <- setNames(lapply(steps, `[[`, "dependencies"), step_names)

  # Kahn's algorithm
  in_degree <- setNames(rep(0, length(step_names)), step_names)
  for (step in step_names) {
    for (dep in deps[[step]]) {
      if (dep %in% step_names) {
        # dep is depended upon by step (but we track in_degree for step)
      }
    }
  }

  # Calculate in-degrees
  for (step in step_names) {
    for (dep in deps[[step]]) {
      if (dep %in% step_names) {
        # step depends on dep, so step's dependencies include dep
      }
    }
    in_degree[step] <- length(intersect(deps[[step]], step_names))
  }

  # Process
  result <- character()
  queue <- step_names[in_degree == 0]

  while (length(queue) > 0) {
    current <- queue[1]
    queue <- queue[-1]
    result <- c(result, current)

    # Find steps that depend on current
    for (step in step_names) {
      if (current %in% deps[[step]]) {
        in_degree[step] <- in_degree[step] - 1
        if (in_degree[step] == 0 && !(step %in% result)) {
          queue <- c(queue, step)
        }
      }
    }
  }

  if (length(result) != length(step_names)) {
    missing <- setdiff(step_names, result)
    stop(sprintf("Circular dependency detected involving: %s",
                 paste(missing, collapse = ", ")))
  }

  result
}

#' Helper: repeat string
#' @keywords internal
`%rep%` <- function(x, n) paste(rep(x, n), collapse = "")

#' Validate pipeline results
#'
#' @param con DBI connection
#' @param config Configuration list
#' @return Validation results
#' @export
validate_pipeline_results <- function(con, config) {
  log_info("Validating pipeline results...")

  validations <- list()

  # Check ELIG_COH_ALLFLAGS exists and has records
  tryCatch({
    count_sql <- glue("SELECT COUNT(*) AS n FROM {work_table(config, 'ELIG_COH_ALLFLAGS')}")
    result <- query_with_retry(con, count_sql, config, operation_name = "Validate ELIG_COH_ALLFLAGS")
    validations$elig_coh_allflags <- list(
      exists = TRUE,
      count = result$n[1]
    )
    log_info(sprintf("ELIG_COH_ALLFLAGS: %d patients", result$n[1]))
  }, error = function(e) {
    validations$elig_coh_allflags <<- list(exists = FALSE, error = e$message)
    log_error(sprintf("ELIG_COH_ALLFLAGS validation failed: %s", e$message))
  })

  # Check ELIG_COH_FINAL exists and has records
  tryCatch({
    count_sql <- glue("SELECT COUNT(*) AS n FROM {work_table(config, 'ELIG_COH_FINAL')}")
    result <- query_with_retry(con, count_sql, config, operation_name = "Validate ELIG_COH_FINAL")
    validations$elig_coh_final <- list(
      exists = TRUE,
      count = result$n[1]
    )
    log_info(sprintf("ELIG_COH_FINAL: %d patients", result$n[1]))
  }, error = function(e) {
    validations$elig_coh_final <<- list(exists = FALSE, error = e$message)
    log_error(sprintf("ELIG_COH_FINAL validation failed: %s", e$message))
  })

  # Check attrition ratios are reasonable
  if (!is.null(validations$elig_coh_allflags$count) &&
      !is.null(validations$elig_coh_final$count)) {
    ratio <- validations$elig_coh_final$count / validations$elig_coh_allflags$count
    validations$attrition_ratio <- ratio
    log_info(sprintf("Attrition ratio (final/all): %.2f%%", ratio * 100))

    if (ratio < 0.01) {
      log_warn("Very high attrition (>99%) - please review criteria")
    }
  }

  validations
}

#' Load R6 if not available (fallback)
#' @keywords internal
if (!requireNamespace("R6", quietly = TRUE)) {
  # Simple fallback implementation
  PipelineState <- function(...) {
    env <- new.env()
    env$checkpoint_file <- NULL
    env$completed_steps <- character()
    env$failed_steps <- character()
    env$step_timings <- list()
    env$start_time <- Sys.time()

    list(
      save = function() {
        state <- list(
          completed_steps = env$completed_steps,
          failed_steps = env$failed_steps,
          step_timings = env$step_timings,
          start_time = env$start_time
        )
        if (!is.null(env$checkpoint_file)) {
          saveRDS(state, env$checkpoint_file)
        }
      },
      load = function(f) {
        if (file.exists(f)) {
          state <- readRDS(f)
          env$completed_steps <- state$completed_steps
          env$failed_steps <- state$failed_steps
          env$step_timings <- state$step_timings
          env$start_time <- state$start_time
          env$checkpoint_file <- f
          return(TRUE)
        }
        FALSE
      },
      mark_completed = function(step, dur) {
        env$completed_steps <- unique(c(env$completed_steps, step))
        env$step_timings[[step]] <- dur
      },
      mark_failed = function(step, err) {
        env$failed_steps <- unique(c(env$failed_steps, step))
        env$step_timings[[step]] <- list(error = err)
      },
      is_completed = function(step) step %in% env$completed_steps,
      get_summary = function() {
        list(
          completed = length(env$completed_steps),
          failed = length(env$failed_steps),
          total_seconds = as.numeric(difftime(Sys.time(), env$start_time, units = "secs")),
          step_timings = env$step_timings
        )
      }
    )
  }
}
