#' Multiple Myeloma Attrition Cohort Analysis
#'
#' Main entry point for the attrition cohort analysis package.
#' This file sources all required components and provides convenient
#' wrapper functions for common use cases.
#'
#' @description
#' This package provides tools for building attrition cohorts for
#' Multiple Myeloma studies with fully configurable inclusion/exclusion criteria.
#'
#' @details
#' Key features:
#' - Each I/E criterion can be toggled on/off
#' - Parameters for each criterion are fully configurable
#' - Interactive Shiny GUI for visual configuration
#' - Command-line interface for scripted workflows
#' - Generates formatted attrition tables
#' - Supports multiple diagnosis window analyses (30/60/90 days)
#'
#' @examples
#' \dontrun{
#' # Load all functions
#' source("R/attrition_cohort.R")
#'
#' # Option 1: Launch Shiny GUI
#' launch_attrition_app()
#'
#' # Option 2: Interactive CLI
#' run_interactive_analysis()
#'
#' # Option 3: Programmatic use
#' config <- create_default_config()
#' config <- update_criterion(config, "c7_other_cancer", enabled = TRUE)
#' results <- apply_attrition_criteria(my_data, config)
#' attrition_table <- generate_attrition_table(results)
#' }

# Source all component files
local({
  # Get the directory of this script
  script_dir <- if (exists("ofile")) {
    dirname(ofile)
  } else if (interactive()) {
    "R"
  } else {
    "R"
  }

  # Source files in order
  source(file.path(script_dir, "config.R"), local = FALSE)
  source(file.path(script_dir, "attrition_functions.R"), local = FALSE)
  source(file.path(script_dir, "attrition_table.R"), local = FALSE)
  source(file.path(script_dir, "interactive_cli.R"), local = FALSE)
  source(file.path(script_dir, "shiny_app.R"), local = FALSE)
})

#' Print welcome message and usage instructions
#' @export
attrition_help <- function() {
  cat("\n")
  cat("=================================================================\n")
  cat("    MULTIPLE MYELOMA ATTRITION COHORT ANALYSIS TOOL\n")
  cat("=================================================================\n\n")

  cat("QUICK START OPTIONS:\n")
  cat("--------------------\n\n")

  cat("1. SHINY GUI (Recommended for visual configuration):\n")
  cat("   > launch_attrition_app()\n")
  cat("   > launch_attrition_app(my_data)  # With pre-loaded data\n\n")

  cat("2. INTERACTIVE CLI (Question-based configuration):\n")
  cat("   > run_interactive_analysis()\n")
  cat("   > run_interactive_analysis(my_data)\n\n")

  cat("3. PROGRAMMATIC USE (For scripted workflows):\n")
  cat("   # Create and customize configuration\n")
  cat("   > config <- create_default_config()\n")
  cat("   > config <- update_criterion(config, 'c2_age', options = list(min_age = 21))\n")
  cat("   > config <- update_criterion(config, 'c7_other_cancer', enabled = TRUE)\n\n")
  cat("   # Run analysis\n")
  cat("   > results <- apply_attrition_criteria(my_data, config)\n")
  cat("   > attrition_table <- generate_attrition_table(results)\n")
  cat("   > print_attrition_table(attrition_table)\n\n")

  cat("4. QUICK ANALYSIS (Default settings):\n")
  cat("   > quick_attrition_analysis(my_data)\n\n")

  cat("INCLUSION/EXCLUSION CRITERIA:\n")
  cat("------------------------------\n")
  cat("  C0: Base MM Diagnosis (Required - always enabled)\n")
  cat("  C1: Inpatient/Outpatient MM Diagnosis Confirmation\n")
  cat("  C2: Age Requirement (>=18 years)\n")
  cat("  C3: MM Therapy in Follow-up (Inclusion)\n")
  cat("  C4: No MM Therapy in Baseline (Exclusion)\n")
  cat("  C5: Baseline Continuous Enrollment (6 months)\n")
  cat("  C6: Follow-up Enrollment (>=1 day)\n")
  cat("  C7: Other Cancer Exclusion (Optional)\n")
  cat("  C8: Pregnancy Exclusion (Optional)\n")
  cat("  C9: Clinical Trial Exclusion (Optional)\n\n")

  cat("For more help, see the documentation in each function.\n")
  cat("=================================================================\n\n")
}

# Display help on load
if (interactive()) {
  attrition_help()
}
