#' Interactive Command Line Interface for Attrition Cohort
#'
#' Provides an interactive question-based interface for configuring
#' and running attrition cohort analysis without a GUI.

#' Run interactive CLI for attrition cohort analysis
#'
#' @param data Patient data (optional, will prompt for file if not provided)
#' @return Results from attrition analysis
#' @export
run_interactive_analysis <- function(data = NULL) {
  cat("\n")
  cat("========================================================\n")
  cat("   MULTIPLE MYELOMA ATTRITION COHORT ANALYSIS\n")
  cat("   Interactive Configuration Tool\n")
  cat("========================================================\n\n")

  # Step 1: Load data if not provided
  if (is.null(data)) {
    data <- prompt_data_input()
  }

  cat(sprintf("\nData loaded: %d patients, %d variables\n", nrow(data), ncol(data)))

  # Step 2: Configure study periods
  config <- create_default_config()
  config <- prompt_study_periods(config)

  # Step 3: Configure enrollment parameters
  config <- prompt_enrollment_params(config)

  # Step 4: Configure diagnosis windows
  config <- prompt_diagnosis_windows(config)

  # Step 5: Configure inclusion/exclusion criteria
  config <- prompt_criteria_config(config)

  # Step 6: Review configuration
  cat("\n")
  print_config_summary(config)

  # Step 7: Confirm and run
  proceed <- prompt_yes_no("\nProceed with analysis?")

  if (proceed) {
    cat("\nRunning attrition analysis...\n")
    results <- apply_attrition_criteria(data, config, verbose = TRUE)

    # Generate attrition table
    cat("\nGenerating attrition table...\n")
    attrition_table <- generate_attrition_table(results, config)

    # Display results
    cat("\n")
    print_attrition_table(attrition_table)

    # Offer to save results
    save_results <- prompt_yes_no("\nWould you like to save the results?")
    if (save_results) {
      filename <- readline("Enter filename (without extension): ")
      if (nchar(filename) > 0) {
        export_attrition_table(attrition_table, paste0(filename, ".csv"), "csv")
        saveRDS(results, paste0(filename, "_full_results.rds"))
        cat(sprintf("Results saved to %s.csv and %s_full_results.rds\n", filename, filename))
      }
    }

    return(invisible(list(results = results, attrition_table = attrition_table, config = config)))
  } else {
    cat("Analysis cancelled.\n")
    return(invisible(NULL))
  }
}

#' Prompt for data input
#' @keywords internal
prompt_data_input <- function() {
  cat("DATA INPUT\n")
  cat("-----------\n")
  cat("Please provide patient data.\n")
  cat("Supported formats: CSV, RDS\n\n")

  filepath <- readline("Enter file path (or press Enter to use sample data): ")

  if (nchar(filepath) == 0) {
    cat("Generating sample data for demonstration...\n")
    return(generate_sample_data())
  }

  if (!file.exists(filepath)) {
    stop("File not found: ", filepath)
  }

  ext <- tools::file_ext(filepath)
  if (ext == "csv") {
    return(read.csv(filepath, stringsAsFactors = FALSE))
  } else if (ext == "rds") {
    return(readRDS(filepath))
  } else {
    stop("Unsupported file format. Use CSV or RDS.")
  }
}

#' Prompt for study periods configuration
#' @keywords internal
prompt_study_periods <- function(config) {
  cat("\nSTUDY PERIODS CONFIGURATION\n")
  cat("-----------------------------\n")

  use_defaults <- prompt_yes_no(sprintf(
    "Use default study period (%s to %s)?",
    config$study_periods$study_start_date,
    config$study_periods$study_end_date
  ))

  if (!use_defaults) {
    start <- readline("Enter study start date (YYYY-MM-DD): ")
    end <- readline("Enter study end date (YYYY-MM-DD): ")

    if (nchar(start) > 0) config$study_periods$study_start_date <- as.Date(start)
    if (nchar(end) > 0) config$study_periods$study_end_date <- as.Date(end)

    id_start <- readline("Enter identification period start date (YYYY-MM-DD): ")
    id_end <- readline("Enter identification period end date (YYYY-MM-DD): ")

    if (nchar(id_start) > 0) config$study_periods$id_period_start <- as.Date(id_start)
    if (nchar(id_end) > 0) config$study_periods$id_period_end <- as.Date(id_end)
  }

  config
}

#' Prompt for enrollment parameters
#' @keywords internal
prompt_enrollment_params <- function(config) {
  cat("\nENROLLMENT PARAMETERS\n")
  cat("-----------------------\n")

  use_defaults <- prompt_yes_no(sprintf(
    "Use default enrollment parameters (Baseline: %d months, Gap: %d days)?",
    config$enrollment$baseline_months,
    config$enrollment$allowable_gap_days
  ))

  if (!use_defaults) {
    baseline <- readline(sprintf("Baseline period in months [%d]: ", config$enrollment$baseline_months))
    if (nchar(baseline) > 0) config$enrollment$baseline_months <- as.integer(baseline)

    gap <- readline(sprintf("Allowable enrollment gap in days [%d]: ", config$enrollment$allowable_gap_days))
    if (nchar(gap) > 0) config$enrollment$allowable_gap_days <- as.integer(gap)
  }

  config
}

#' Prompt for diagnosis windows
#' @keywords internal
prompt_diagnosis_windows <- function(config) {
  cat("\nDIAGNOSIS WINDOW CONFIGURATION\n")
  cat("-------------------------------\n")
  cat("For outpatient claims, patients need >=2 claims within a specified window.\n")
  cat("Available windows: 30, 60, 90 days\n\n")

  primary <- readline("Primary window for analysis (30/60/90) [90]: ")
  if (nchar(primary) > 0) {
    config$diagnosis_window$primary_window <- as.integer(primary)
  }

  config$criteria$c1_mm_diagnosis_strict$options$window_days <- config$diagnosis_window$primary_window

  config
}

#' Prompt for criteria configuration
#' @keywords internal
prompt_criteria_config <- function(config) {
  cat("\nINCLUSION/EXCLUSION CRITERIA CONFIGURATION\n")
  cat("--------------------------------------------\n")
  cat("For each criterion, you can enable/disable and modify options.\n\n")

  # Criterion 1: MM Diagnosis
  cat("CRITERION 1: Inpatient/Outpatient MM Diagnosis Requirement\n")
  cat("  >=1 inpatient OR >=2 outpatient claims within window days\n")
  config$criteria$c1_mm_diagnosis_strict$enabled <- prompt_yes_no("  Enable this criterion?", TRUE)

  if (config$criteria$c1_mm_diagnosis_strict$enabled) {
    count <- readline("  Number of outpatient claims required [2]: ")
    if (nchar(count) > 0) {
      config$criteria$c1_mm_diagnosis_strict$options$outpatient_count <- as.integer(count)
    }
  }

  # Criterion 2: Age
  cat("\nCRITERION 2: Age Requirement\n")
  cat("  Patients must be at least minimum age in index year\n")
  config$criteria$c2_age$enabled <- prompt_yes_no("  Enable this criterion?", TRUE)

  if (config$criteria$c2_age$enabled) {
    age <- readline("  Minimum age [18]: ")
    if (nchar(age) > 0) {
      config$criteria$c2_age$options$min_age <- as.integer(age)
    }
  }

  # Criterion 3: MM Therapy Follow-up
  cat("\nCRITERION 3: MM Therapy in Follow-up (Inclusion)\n")
  cat("  Evidence of FDA-approved MM oncology therapy during follow-up\n")
  config$criteria$c3_mm_therapy_followup$enabled <- prompt_yes_no("  Enable this criterion?", TRUE)

  # Criterion 4: MM Therapy Baseline (Exclusion)
  cat("\nCRITERION 4: MM Therapy in Baseline (Exclusion)\n")
  cat("  Exclude patients with MM therapy during baseline (ensures newly diagnosed)\n")
  config$criteria$c4_mm_therapy_baseline$enabled <- prompt_yes_no("  Enable this criterion?", TRUE)

  # Criterion 5: Baseline CE
  cat("\nCRITERION 5: Baseline Continuous Enrollment\n")
  cat("  Required months of CE before index date\n")
  config$criteria$c5_baseline_enrollment$enabled <- prompt_yes_no("  Enable this criterion?", TRUE)

  if (config$criteria$c5_baseline_enrollment$enabled) {
    months <- readline("  Required CE months [6]: ")
    if (nchar(months) > 0) {
      config$criteria$c5_baseline_enrollment$options$required_months <- as.integer(months)
    }
  }

  # Criterion 6: Follow-up CE
  cat("\nCRITERION 6: Follow-up Enrollment\n")
  cat("  Minimum days of CE starting on index date\n")
  config$criteria$c6_followup_enrollment$enabled <- prompt_yes_no("  Enable this criterion?", TRUE)

  if (config$criteria$c6_followup_enrollment$enabled) {
    days <- readline("  Minimum CE days [1]: ")
    if (nchar(days) > 0) {
      config$criteria$c6_followup_enrollment$options$min_days <- as.integer(days)
    }
  }

  # Optional criteria (disabled by default)
  cat("\n--- OPTIONAL CRITERIA (Disabled by default per protocol) ---\n")

  # Criterion 7: Other Cancer
  cat("\nCRITERION 7: Other Cancer (Exclusion)\n")
  cat("  Exclude patients with another cancer in baseline period\n")
  config$criteria$c7_other_cancer$enabled <- prompt_yes_no("  Enable this criterion?", FALSE)

  # Criterion 8: Pregnancy
  cat("\nCRITERION 8: Pregnancy/Childbirth (Exclusion)\n")
  cat("  Exclude patients with pregnancy or childbirth\n")
  config$criteria$c8_pregnancy$enabled <- prompt_yes_no("  Enable this criterion?", FALSE)

  # Criterion 9: Clinical Trial
  cat("\nCRITERION 9: Clinical Trial (Exclusion)\n")
  cat("  Exclude patients with clinical trial participation\n")
  config$criteria$c9_clinical_trial$enabled <- prompt_yes_no("  Enable this criterion?", FALSE)

  config
}

#' Prompt for yes/no response
#' @keywords internal
prompt_yes_no <- function(question, default = TRUE) {
  default_str <- ifelse(default, "Y/n", "y/N")
  response <- readline(sprintf("%s [%s]: ", question, default_str))

  if (nchar(response) == 0) {
    return(default)
  }

  tolower(substr(response, 1, 1)) == "y"
}

#' Generate sample data for demonstration
#' @keywords internal
generate_sample_data <- function(n = 5000) {
  set.seed(42)

  data.frame(
    PATID = seq_len(n),
    INDEX_DATE = as.Date("2020-01-01") + sample(0:1000, n, replace = TRUE),
    BIRTH_YR = sample(1940:1980, n, replace = TRUE),
    MM_INPATIENT = sample(c(0, 1), n, replace = TRUE, prob = c(0.3, 0.7)),
    mm_outpatient_30d = sample(0:3, n, replace = TRUE),
    mm_outpatient_60d = sample(0:4, n, replace = TRUE),
    mm_outpatient_90d = sample(0:5, n, replace = TRUE),
    MM_FU_agents = sample(c(0, 1), n, replace = TRUE, prob = c(0.2, 0.8)),
    MM_bl_agents = sample(c(0, 1), n, replace = TRUE, prob = c(0.9, 0.1)),
    CE_b = sample(c(0, 1), n, replace = TRUE, prob = c(0.15, 0.85)),
    CE_f = sample(c(0, 1), n, replace = TRUE, prob = c(0.05, 0.95)),
    CE_3mosf = sample(c(0, 1), n, replace = TRUE, prob = c(0.1, 0.9)),
    MM_baseline_other = sample(c(0, 1), n, replace = TRUE, prob = c(0.95, 0.05)),
    Pregnant = sample(c(0, 1), n, replace = TRUE, prob = c(0.98, 0.02)),
    CT_part = sample(c(0, 1), n, replace = TRUE, prob = c(0.95, 0.05)),
    FU_DAYS = sample(30:1000, n, replace = TRUE),
    Death_dt = as.Date(NA),
    stringsAsFactors = FALSE
  )
}

#' Quick start function for common use case
#'
#' @param data Patient data
#' @param use_defaults Use all default settings
#' @return Results from attrition analysis
#' @export
quick_attrition_analysis <- function(data, use_defaults = TRUE) {
  config <- create_default_config()

  if (use_defaults) {
    cat("Running attrition analysis with default configuration...\n\n")
  }

  results <- apply_attrition_criteria(data, config, verbose = TRUE)
  attrition_table <- generate_attrition_table(results, config)

  print_attrition_table(attrition_table)

  list(results = results, attrition_table = attrition_table, config = config)
}
