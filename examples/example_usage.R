#' Example Usage of Attrition Cohort Analysis Tool
#'
#' This script demonstrates various ways to use the attrition cohort analysis
#' tool for Multiple Myeloma studies.

# ==============================================================================
# SETUP: Source the main file to load all functions
# ==============================================================================

# Set working directory to project root (adjust as needed)
# setwd("/path/to/julialot")

# Source the main file
source("R/new_code.R")

# ==============================================================================
# EXAMPLE 1: Generate Sample Data for Testing
# ==============================================================================

cat("\n=== EXAMPLE 1: Generate Sample Data ===\n\n")

# Create sample data for demonstration
set.seed(42)
n <- 5000

sample_data <- data.frame(
  PATID = seq_len(n),
  INDEX_DATE = as.Date("2020-01-01") + sample(0:1000, n, replace = TRUE),
  BIRTH_YR = sample(1940:1985, n, replace = TRUE),

  # MM diagnosis flags
  MM_INPATIENT = sample(c(0, 1), n, replace = TRUE, prob = c(0.3, 0.7)),
  mm_outpatient_30d = sample(0:3, n, replace = TRUE),
  mm_outpatient_60d = sample(0:4, n, replace = TRUE),
  mm_outpatient_90d = sample(0:5, n, replace = TRUE),

  # Therapy flags
  MM_FU_agents = sample(c(0, 1), n, replace = TRUE, prob = c(0.2, 0.8)),
  MM_bl_agents = sample(c(0, 1), n, replace = TRUE, prob = c(0.9, 0.1)),

  # Enrollment flags
  CE_b = sample(c(0, 1), n, replace = TRUE, prob = c(0.15, 0.85)),
  CE_f = sample(c(0, 1), n, replace = TRUE, prob = c(0.05, 0.95)),
  CE_3mosf = sample(c(0, 1), n, replace = TRUE, prob = c(0.1, 0.9)),

  # Exclusion flags
  MM_baseline_other = sample(c(0, 1), n, replace = TRUE, prob = c(0.95, 0.05)),
  Pregnant = sample(c(0, 1), n, replace = TRUE, prob = c(0.98, 0.02)),
  CT_part = sample(c(0, 1), n, replace = TRUE, prob = c(0.95, 0.05)),

  # Follow-up
  FU_DAYS = sample(30:1000, n, replace = TRUE),
  Death_dt = as.Date(NA),

  stringsAsFactors = FALSE
)

cat(sprintf("Generated sample data with %d patients\n", nrow(sample_data)))

# ==============================================================================
# EXAMPLE 2: Quick Analysis with Default Settings
# ==============================================================================

cat("\n=== EXAMPLE 2: Quick Analysis with Defaults ===\n\n")

# Run quick analysis with all default settings
results <- quick_attrition_analysis(sample_data, use_defaults = TRUE)

# ==============================================================================
# EXAMPLE 3: Custom Configuration
# ==============================================================================

cat("\n=== EXAMPLE 3: Custom Configuration ===\n\n")

# Create custom configuration
config <- create_default_config()

# Modify age requirement
config <- update_criterion(config, "c2_age", options = list(min_age = 21))

# Enable the optional "other cancer" exclusion criterion
config <- update_criterion(config, "c7_other_cancer", enabled = TRUE)

# Change diagnosis window to 60 days
config <- update_criterion(config, "c1_mm_diagnosis_strict",
                           options = list(window_days = 60, outpatient_count = 2))

# Print configuration summary
print_config_summary(config)

# Run analysis with custom config
results_custom <- apply_attrition_criteria(sample_data, config, verbose = TRUE)

# Generate attrition table
attrition_table <- generate_attrition_table(results_custom, config)
print_attrition_table(attrition_table)

# ==============================================================================
# EXAMPLE 4: Sensitivity Analysis - Compare Different Windows
# ==============================================================================

cat("\n=== EXAMPLE 4: Sensitivity Analysis ===\n\n")

# Run analysis for each diagnosis window and compare results
windows <- c(30, 60, 90)
final_counts <- data.frame(window = windows, n = NA)

for (i in seq_along(windows)) {
  w <- windows[i]
  config_w <- create_default_config()
  config_w <- update_criterion(config_w, "c1_mm_diagnosis_strict",
                               options = list(window_days = w))
  results_w <- apply_attrition_criteria(sample_data, config_w, verbose = FALSE)
  final_counts$n[i] <- sum(results_w$in_final_cohort == 1, na.rm = TRUE)
}

cat("Final cohort sizes by diagnosis window:\n")
print(final_counts)

# ==============================================================================
# EXAMPLE 5: Export Results
# ==============================================================================

cat("\n=== EXAMPLE 5: Export Results ===\n\n")

# Export attrition table to CSV
export_attrition_table(attrition_table, "attrition_results.csv", "csv")

# Save full results including all flags
saveRDS(results_custom, "full_cohort_results.rds")

# Get final filtered cohort
final_cohort <- get_final_cohort(results_custom)
cat(sprintf("Final cohort saved: %d patients\n", nrow(final_cohort)))

# ==============================================================================
# EXAMPLE 6: Launch Shiny GUI (Interactive)
# ==============================================================================

cat("\n=== EXAMPLE 6: Launch Shiny GUI ===\n\n")
cat("To launch the interactive GUI, run:\n")
cat("  launch_attrition_app()\n")
cat("  launch_attrition_app(sample_data)  # With pre-loaded data\n")

# Uncomment to launch:
# launch_attrition_app(sample_data)

# ==============================================================================
# EXAMPLE 7: Interactive CLI (Question-based)
# ==============================================================================

cat("\n=== EXAMPLE 7: Interactive CLI ===\n\n")
cat("To run the interactive command-line interface, run:\n")
cat("  run_interactive_analysis()\n")
cat("  run_interactive_analysis(sample_data)  # With pre-loaded data\n")

# Uncomment to launch:
# run_interactive_analysis(sample_data)

cat("\n=== All Examples Complete ===\n\n")
