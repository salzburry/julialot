#' Attrition Cohort Configuration
#'
#' This file contains all configurable parameters for the attrition cohort analysis.
#' Each inclusion/exclusion criterion can be toggled on/off and parameters can be modified.

#' Create default configuration for attrition cohort analysis
#' @return A list containing all configuration parameters
#' @export
create_default_config <- function() {
  list(
    # ============================================================================
    # STUDY TIME PERIODS
    # ============================================================================
    study_periods = list(
      study_start_date = as.Date("2015-07-01"),
      study_end_date = as.Date("2025-06-30"),
      id_period_start = as.Date("2016-01-01"),
      id_period_end = as.Date("2025-06-30")
    ),

    # ============================================================================
    # ENROLLMENT PARAMETERS
    # ============================================================================
    enrollment = list(
      baseline_months = 6,
      min_followup_days = 1,
      allowable_gap_days = 30,
      require_medical_benefits = TRUE,
      require_pharmacy_benefits = TRUE
    ),

    # ============================================================================
    # DIAGNOSIS WINDOW OPTIONS (for outpatient claims)
    # ============================================================================
    diagnosis_window = list(
      # Which windows to evaluate (can select multiple)
      windows_to_use = c(30, 60, 90),
      # Primary window for main analysis
      primary_window = 90
    ),

    # ============================================================================
    # INCLUSION/EXCLUSION CRITERIA TOGGLES
    # Each criterion can be enabled/disabled independently
    # ============================================================================
    criteria = list(
      # Criterion 0: Base cohort - MM diagnosis claims (ALWAYS ON - base requirement)
      c0_mm_diagnosis = list(
        enabled = TRUE,
        description = ">=1 medical claims for multiple myeloma (ICD-9-CM=203.x or ICD-10-CM=C90.x)",
        type = "INCLUSION",
        modifiable = FALSE  # This is the base cohort requirement
      ),

      # Criterion 1: Inpatient/Outpatient MM diagnosis requirement
      c1_mm_diagnosis_strict = list(
        enabled = TRUE,
        description = ">=1 inpatient OR >=2 outpatient claims within window days",
        type = "INCLUSION",
        options = list(
          require_inpatient = FALSE,  # If TRUE, requires at least 1 inpatient
          outpatient_count = 2,       # Number of outpatient claims required
          window_days = 90            # Days between outpatient claims (30/60/90)
        )
      ),

      # Criterion 2: Age requirement
      c2_age = list(
        enabled = TRUE,
        description = "Patients >= minimum age in the index year",
        type = "INCLUSION",
        options = list(
          min_age = 18
        )
      ),

      # Criterion 3: MM therapy in follow-up
      c3_mm_therapy_followup = list(
        enabled = TRUE,
        description = "Evidence of FDA-approved MM oncology therapy in follow-up period",
        type = "INCLUSION",
        options = list(
          require_any_therapy = TRUE
        )
      ),

      # Criterion 4: No MM therapy in baseline (newly diagnosed)
      c4_mm_therapy_baseline = list(
        enabled = TRUE,
        description = "No MM oncology therapy during baseline period (6 months prior)",
        type = "EXCLUSION",
        options = list(
          exclude_if_therapy = TRUE
        )
      ),

      # Criterion 5: Baseline continuous enrollment
      c5_baseline_enrollment = list(
        enabled = TRUE,
        description = ">=6 months continuous enrollment before index date",
        type = "INCLUSION",
        options = list(
          required_months = 6,
          allowable_gap_days = 30
        )
      ),

      # Criterion 6: Follow-up enrollment
      c6_followup_enrollment = list(
        enabled = TRUE,
        description = ">=1 day continuous enrollment from index date",
        type = "INCLUSION",
        options = list(
          min_days = 1,
          allowable_gap_days = 30
        )
      ),

      # Criterion 7: Other cancer exclusion
      c7_other_cancer = list(
        enabled = FALSE,  # Disabled by default per spec
        description = "Exclude patients with another cancer in baseline period",
        type = "EXCLUSION",
        options = list(
          require_2_claims = TRUE,
          within_days = 30
        )
      ),

      # Criterion 8: Pregnancy exclusion
      c8_pregnancy = list(
        enabled = FALSE,  # Disabled by default per spec
        description = "Exclude patients with pregnancy/childbirth during study",
        type = "EXCLUSION",
        options = list(
          check_baseline = TRUE,
          check_followup = TRUE
        )
      ),

      # Criterion 9: Clinical trial exclusion
      c9_clinical_trial = list(
        enabled = FALSE,  # Disabled by default per spec
        description = "Exclude patients with clinical trial participation",
        type = "EXCLUSION",
        options = list(
          check_baseline = TRUE,
          check_followup = TRUE
        )
      )
    ),

    # ============================================================================
    # SENSITIVITY ANALYSIS FLAGS
    # ============================================================================
    sensitivity = list(
      # Flag patients with >=3 months CE for sensitivity analyses
      flag_3month_ce = TRUE,
      # Flag smoldering MM patients
      flag_smoldering = TRUE,
      # Include non-diagnostic claims analysis
      include_non_diagnostic = TRUE
    ),

    # ============================================================================
    # OUTPUT OPTIONS
    # ============================================================================
    output = list(
      include_all_flags = TRUE,
      generate_attrition_table = TRUE,
      export_format = "csv"  # csv, xlsx, rds
    )
  )
}

#' Validate configuration
#' @param config Configuration list
#' @return TRUE if valid, otherwise throws error
#' @export
validate_config <- function(config) {
  # Check required sections

required_sections <- c("study_periods", "enrollment", "diagnosis_window", "criteria")
  missing <- setdiff(required_sections, names(config))
  if (length(missing) > 0) {
    stop(paste("Missing required config sections:", paste(missing, collapse = ", ")))
  }

  # Validate dates
  if (config$study_periods$study_start_date >= config$study_periods$study_end_date) {
    stop("Study start date must be before study end date")
  }

  if (config$study_periods$id_period_start < config$study_periods$study_start_date) {
    stop("Identification period cannot start before study period")
  }

  # Validate enrollment parameters
  if (config$enrollment$baseline_months < 0) {
    stop("Baseline months must be non-negative")
  }

  if (config$enrollment$allowable_gap_days < 0) {
    stop("Allowable gap days must be non-negative")
  }

  TRUE
}

#' Print configuration summary
#' @param config Configuration list
#' @export
print_config_summary <- function(config) {
  cat("\n========================================\n")
  cat("ATTRITION COHORT CONFIGURATION SUMMARY\n")
  cat("========================================\n\n")

  cat("STUDY PERIODS:\n")
  cat(sprintf("  Study Period: %s to %s\n",
              config$study_periods$study_start_date,
              config$study_periods$study_end_date))
  cat(sprintf("  ID Period: %s to %s\n",
              config$study_periods$id_period_start,
              config$study_periods$id_period_end))

  cat("\nENROLLMENT REQUIREMENTS:\n")
  cat(sprintf("  Baseline: %d months\n", config$enrollment$baseline_months))
  cat(sprintf("  Min Follow-up: %d days\n", config$enrollment$min_followup_days))
  cat(sprintf("  Allowable Gap: %d days\n", config$enrollment$allowable_gap_days))

  cat("\nDIAGNOSIS WINDOWS:\n")
  cat(sprintf("  Windows: %s days\n", paste(config$diagnosis_window$windows_to_use, collapse = ", ")))
  cat(sprintf("  Primary: %d days\n", config$diagnosis_window$primary_window))

  cat("\nINCLUSION/EXCLUSION CRITERIA:\n")
  for (name in names(config$criteria)) {
    crit <- config$criteria[[name]]
    status <- ifelse(crit$enabled, "[ENABLED]", "[DISABLED]")
    type_tag <- ifelse(crit$type == "INCLUSION", "INC", "EXC")
    cat(sprintf("  %s %s (%s): %s\n", status, name, type_tag, crit$description))
  }

  cat("\n========================================\n")
}

#' Update a specific criterion setting
#' @param config Configuration list
#' @param criterion_name Name of criterion (e.g., "c1_mm_diagnosis_strict")
#' @param enabled TRUE/FALSE to enable/disable
#' @param options Named list of options to update
#' @return Updated configuration
#' @export
update_criterion <- function(config, criterion_name, enabled = NULL, options = NULL) {
  if (!criterion_name %in% names(config$criteria)) {
    stop(paste("Unknown criterion:", criterion_name))
  }

  if (!is.null(enabled)) {
    # Check if criterion is modifiable
    if (isFALSE(config$criteria[[criterion_name]]$modifiable %||% TRUE)) {
      warning(paste("Criterion", criterion_name, "cannot be disabled (base requirement)"))
    } else {
      config$criteria[[criterion_name]]$enabled <- enabled
    }
  }

  if (!is.null(options)) {
    for (opt_name in names(options)) {
      if (opt_name %in% names(config$criteria[[criterion_name]]$options)) {
        config$criteria[[criterion_name]]$options[[opt_name]] <- options[[opt_name]]
      } else {
        warning(paste("Unknown option", opt_name, "for criterion", criterion_name))
      }
    }
  }

  config
}

#' Null coalescing operator
#' @keywords internal
`%||%` <- function(x, y) if (is.null(x)) y else x
