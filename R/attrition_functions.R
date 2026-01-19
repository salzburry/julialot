#' Attrition Cohort Functions
#'
#' Core functions for applying inclusion/exclusion criteria to build the study cohort.
#' Each criterion is implemented as an independent function that can be toggled on/off.

#' Apply all enabled criteria to create attrition cohort
#'
#' @param data Patient-level data frame with required variables
#' @param config Configuration list from create_default_config()
#' @param verbose Print progress messages
#' @return Data frame with all criteria flags and filtered cohort
#' @export
apply_attrition_criteria <- function(data, config, verbose = TRUE) {
  # Validate config
  validate_config(config)

  if (verbose) {
    cat("\n=== Starting Attrition Cohort Build ===\n")
    cat(sprintf("Initial patient count: %d\n", nrow(data)))
  }

  # Initialize result with all patients
  result <- data

  # Track attrition at each step
  attrition_tracker <- list()
  attrition_tracker[["initial"]] <- nrow(result)

  # ----- CRITERION 0: Base MM Diagnosis (Always Applied) -----
  if (config$criteria$c0_mm_diagnosis$enabled) {
    if (verbose) cat("\nApplying Criterion 0: Base MM Diagnosis...\n")
    result <- apply_c0_mm_diagnosis(result, config)
    attrition_tracker[["c0_mm_diagnosis"]] <- sum(result$flag_c0_mm_diagnosis == 1)
    if (verbose) cat(sprintf("  Patients meeting criterion: %d\n", attrition_tracker[["c0_mm_diagnosis"]]))
  }

  # ----- CRITERION 1: Strict MM Diagnosis -----
  if (config$criteria$c1_mm_diagnosis_strict$enabled) {
    if (verbose) cat("\nApplying Criterion 1: Inpatient/Outpatient MM Diagnosis...\n")
    result <- apply_c1_mm_diagnosis_strict(result, config)
    attrition_tracker[["c1_mm_diagnosis_strict"]] <- sum(result$flag_c1_mm_strict == 1, na.rm = TRUE)
    if (verbose) cat(sprintf("  Patients meeting criterion: %d\n", attrition_tracker[["c1_mm_diagnosis_strict"]]))
  }

  # ----- CRITERION 2: Age -----
  if (config$criteria$c2_age$enabled) {
    if (verbose) cat("\nApplying Criterion 2: Age Requirement...\n")
    result <- apply_c2_age(result, config)
    attrition_tracker[["c2_age"]] <- sum(result$flag_c2_age == 1, na.rm = TRUE)
    if (verbose) cat(sprintf("  Patients meeting criterion: %d\n", attrition_tracker[["c2_age"]]))
  }

  # ----- CRITERION 3: MM Therapy in Follow-up -----
  if (config$criteria$c3_mm_therapy_followup$enabled) {
    if (verbose) cat("\nApplying Criterion 3: MM Therapy in Follow-up...\n")
    result <- apply_c3_mm_therapy_followup(result, config)
    attrition_tracker[["c3_mm_therapy_followup"]] <- sum(result$flag_c3_therapy_fu == 1, na.rm = TRUE)
    if (verbose) cat(sprintf("  Patients meeting criterion: %d\n", attrition_tracker[["c3_mm_therapy_followup"]]))
  }

  # ----- CRITERION 4: No MM Therapy in Baseline (Exclusion) -----
  if (config$criteria$c4_mm_therapy_baseline$enabled) {
    if (verbose) cat("\nApplying Criterion 4: No MM Therapy in Baseline (Exclusion)...\n")
    result <- apply_c4_mm_therapy_baseline(result, config)
    # For exclusion, flag=1 means patient should be EXCLUDED
    attrition_tracker[["c4_mm_therapy_baseline"]] <- sum(result$flag_c4_therapy_bl == 0, na.rm = TRUE)
    if (verbose) cat(sprintf("  Patients NOT excluded: %d\n", attrition_tracker[["c4_mm_therapy_baseline"]]))
  }

  # ----- CRITERION 5: Baseline Enrollment -----
  if (config$criteria$c5_baseline_enrollment$enabled) {
    if (verbose) cat("\nApplying Criterion 5: Baseline Continuous Enrollment...\n")
    result <- apply_c5_baseline_enrollment(result, config)
    attrition_tracker[["c5_baseline_enrollment"]] <- sum(result$flag_c5_ce_baseline == 1, na.rm = TRUE)
    if (verbose) cat(sprintf("  Patients meeting criterion: %d\n", attrition_tracker[["c5_baseline_enrollment"]]))
  }

  # ----- CRITERION 6: Follow-up Enrollment -----
  if (config$criteria$c6_followup_enrollment$enabled) {
    if (verbose) cat("\nApplying Criterion 6: Follow-up Enrollment...\n")
    result <- apply_c6_followup_enrollment(result, config)
    attrition_tracker[["c6_followup_enrollment"]] <- sum(result$flag_c6_ce_followup == 1, na.rm = TRUE)
    if (verbose) cat(sprintf("  Patients meeting criterion: %d\n", attrition_tracker[["c6_followup_enrollment"]]))
  }

  # ----- CRITERION 7: Other Cancer (Exclusion) -----
  if (config$criteria$c7_other_cancer$enabled) {
    if (verbose) cat("\nApplying Criterion 7: Other Cancer Exclusion...\n")
    result <- apply_c7_other_cancer(result, config)
    attrition_tracker[["c7_other_cancer"]] <- sum(result$flag_c7_other_cancer == 0, na.rm = TRUE)
    if (verbose) cat(sprintf("  Patients NOT excluded: %d\n", attrition_tracker[["c7_other_cancer"]]))
  }

  # ----- CRITERION 8: Pregnancy (Exclusion) -----
  if (config$criteria$c8_pregnancy$enabled) {
    if (verbose) cat("\nApplying Criterion 8: Pregnancy Exclusion...\n")
    result <- apply_c8_pregnancy(result, config)
    attrition_tracker[["c8_pregnancy"]] <- sum(result$flag_c8_pregnancy == 0, na.rm = TRUE)
    if (verbose) cat(sprintf("  Patients NOT excluded: %d\n", attrition_tracker[["c8_pregnancy"]]))
  }

  # ----- CRITERION 9: Clinical Trial (Exclusion) -----
  if (config$criteria$c9_clinical_trial$enabled) {
    if (verbose) cat("\nApplying Criterion 9: Clinical Trial Exclusion...\n")
    result <- apply_c9_clinical_trial(result, config)
    attrition_tracker[["c9_clinical_trial"]] <- sum(result$flag_c9_clinical_trial == 0, na.rm = TRUE)
    if (verbose) cat(sprintf("  Patients NOT excluded: %d\n", attrition_tracker[["c9_clinical_trial"]]))
  }

  # Create final cohort flag based on all enabled criteria
  result <- create_final_cohort_flag(result, config)

  if (verbose) {
    final_count <- sum(result$in_final_cohort == 1, na.rm = TRUE)
    cat(sprintf("\n=== Final Cohort: %d patients ===\n", final_count))
  }

  # Attach attrition tracker as attribute
  attr(result, "attrition_tracker") <- attrition_tracker
  attr(result, "config") <- config

  result
}

# ============================================================================
# INDIVIDUAL CRITERION FUNCTIONS
# ============================================================================

#' Criterion 0: Base MM Diagnosis
#' @keywords internal
apply_c0_mm_diagnosis <- function(data, config) {
  # Flag patients with at least 1 MM diagnosis claim
  # This should already be in the data as the base requirement
  if (!"flag_c0_mm_diagnosis" %in% names(data)) {
    # If MM_DX variable exists, use it; otherwise assume all patients have MM dx
    if ("MM_DX" %in% names(data)) {
      data$flag_c0_mm_diagnosis <- as.integer(data$MM_DX >= 1)
    } else {
      # Assume base cohort already has MM diagnosis
      data$flag_c0_mm_diagnosis <- 1L
    }
  }
  data
}

#' Criterion 1: Strict MM Diagnosis (Inpatient OR multiple Outpatient)
#' @keywords internal
apply_c1_mm_diagnosis_strict <- function(data, config) {
  opts <- config$criteria$c1_mm_diagnosis_strict$options
  window_days <- opts$window_days
  outpatient_count <- opts$outpatient_count

  # Check for required variables
  has_inpatient_var <- "MM_INPATIENT" %in% names(data) | "mm_inpatient_claim" %in% names(data)
  has_outpatient_var <- "MM_OUTPATIENT_WITHIN_WINDOW" %in% names(data) |
                        paste0("mm_outpatient_", window_days, "d") %in% names(data)

  if (!has_inpatient_var && !has_outpatient_var) {
    # Create flags based on available data
    if ("CLAIM_TYPE" %in% names(data) && "CLAIM_DATE" %in% names(data)) {
      # Would need to process claims - placeholder
      warning("Claims processing required for C1. Using placeholder.")
      data$flag_c1_mm_strict <- 1L
    } else {
      # Use existing flags if available
      if ("INDEX_INPATIENT" %in% names(data)) {
        data$flag_c1_mm_strict <- as.integer(data$INDEX_INPATIENT == 1 |
                                              data[[paste0("OUTPATIENT_", window_days, "D")]] >= outpatient_count)
      } else {
        data$flag_c1_mm_strict <- 1L
      }
    }
  } else {
    # Use existing variables
    inpatient_col <- ifelse("MM_INPATIENT" %in% names(data), "MM_INPATIENT", "mm_inpatient_claim")
    outpatient_col <- ifelse("MM_OUTPATIENT_WITHIN_WINDOW" %in% names(data),
                             "MM_OUTPATIENT_WITHIN_WINDOW",
                             paste0("mm_outpatient_", window_days, "d"))

    data$flag_c1_mm_strict <- as.integer(
      data[[inpatient_col]] >= 1 |
      data[[outpatient_col]] >= outpatient_count
    )
  }

  # Also create window-specific flags for attrition table
  for (w in config$diagnosis_window$windows_to_use) {
    flag_name <- paste0("flag_c1_", w, "d")
    if (!flag_name %in% names(data)) {
      out_col <- paste0("mm_outpatient_", w, "d")
      if (out_col %in% names(data)) {
        data[[flag_name]] <- as.integer(
          data[["MM_INPATIENT"]] >= 1 | data[[out_col]] >= outpatient_count
        )
      } else {
        data[[flag_name]] <- data$flag_c1_mm_strict
      }
    }
  }

  data
}

#' Criterion 2: Age Requirement
#' @keywords internal
apply_c2_age <- function(data, config) {
  min_age <- config$criteria$c2_age$options$min_age

  # Calculate age at index if not present
  if (!"AGE_DX" %in% names(data)) {
    if ("INDEX_DATE" %in% names(data) && "BIRTH_DATE" %in% names(data)) {
      data$AGE_DX <- as.integer(format(data$INDEX_DATE, "%Y")) -
                     as.integer(format(data$BIRTH_DATE, "%Y"))
    } else if ("INDEX_YR" %in% names(data) && "BIRTH_YR" %in% names(data)) {
      data$AGE_DX <- data$INDEX_YR - data$BIRTH_YR
    } else {
      warning("Cannot calculate age - missing birth date/year. Using placeholder.")
      data$AGE_DX <- 50  # Placeholder
    }
  }

  data$flag_c2_age <- as.integer(data$AGE_DX >= min_age)
  data
}

#' Criterion 3: MM Therapy in Follow-up Period
#' @keywords internal
apply_c3_mm_therapy_followup <- function(data, config) {
  # Check for MM therapy flags
  therapy_cols <- c("MM_FU_agents", "mm_fu_therapy", "HAS_MM_THERAPY_FU")
  found_col <- intersect(therapy_cols, names(data))

  if (length(found_col) > 0) {
    data$flag_c3_therapy_fu <- as.integer(data[[found_col[1]]] == 1)
  } else {
    warning("MM therapy follow-up variable not found. Using placeholder.")
    data$flag_c3_therapy_fu <- 1L
  }

  data
}

#' Criterion 4: MM Therapy in Baseline (Exclusion - flag=1 means EXCLUDE)
#' @keywords internal
apply_c4_mm_therapy_baseline <- function(data, config) {
  # Check for MM therapy flags
  therapy_cols <- c("MM_bl_agents", "mm_bl_therapy", "HAS_MM_THERAPY_BL")
  found_col <- intersect(therapy_cols, names(data))

  if (length(found_col) > 0) {
    # flag=1 means patient HAD therapy in baseline = should be EXCLUDED
    data$flag_c4_therapy_bl <- as.integer(data[[found_col[1]]] == 1)
  } else {
    warning("MM therapy baseline variable not found. Using placeholder.")
    data$flag_c4_therapy_bl <- 0L  # No exclusion
  }

  data
}

#' Criterion 5: Baseline Continuous Enrollment
#' @keywords internal
apply_c5_baseline_enrollment <- function(data, config) {
  required_months <- config$criteria$c5_baseline_enrollment$options$required_months

  # Check for CE flags
  ce_cols <- c("CE_b", "ce_baseline", "BASELINE_CE")
  found_col <- intersect(ce_cols, names(data))

  if (length(found_col) > 0) {
    data$flag_c5_ce_baseline <- as.integer(data[[found_col[1]]] == 1)
  } else if ("BASELINE_CE_MONTHS" %in% names(data)) {
    data$flag_c5_ce_baseline <- as.integer(data$BASELINE_CE_MONTHS >= required_months)
  } else {
    warning("Baseline CE variable not found. Using placeholder.")
    data$flag_c5_ce_baseline <- 1L
  }

  data
}

#' Criterion 6: Follow-up Continuous Enrollment
#' @keywords internal
apply_c6_followup_enrollment <- function(data, config) {
  min_days <- config$criteria$c6_followup_enrollment$options$min_days

  # Check for CE flags
  ce_cols <- c("CE_f", "ce_followup", "FOLLOWUP_CE")
  found_col <- intersect(ce_cols, names(data))

  if (length(found_col) > 0) {
    data$flag_c6_ce_followup <- as.integer(data[[found_col[1]]] == 1)
  } else if ("FU_DAYS" %in% names(data)) {
    data$flag_c6_ce_followup <- as.integer(data$FU_DAYS >= min_days)
  } else {
    warning("Follow-up CE variable not found. Using placeholder.")
    data$flag_c6_ce_followup <- 1L
  }

  # Also flag for 3-month CE sensitivity analysis
  if (config$sensitivity$flag_3month_ce) {
    if ("CE_3mosf" %in% names(data)) {
      data$flag_ce_3month <- as.integer(data$CE_3mosf == 1)
    } else if ("FU_DAYS" %in% names(data)) {
      data$flag_ce_3month <- as.integer(data$FU_DAYS >= 91)  # ~3 months
    }
  }

  data
}

#' Criterion 7: Other Cancer Exclusion
#' @keywords internal
apply_c7_other_cancer <- function(data, config) {
  # Check for other cancer flags
  cancer_cols <- c("MM_baseline_other", "other_cancer_bl", "HAS_OTHER_CANCER")
  found_col <- intersect(cancer_cols, names(data))

  if (length(found_col) > 0) {
    # flag=1 means patient HAS other cancer = should be EXCLUDED
    data$flag_c7_other_cancer <- as.integer(data[[found_col[1]]] == 1)
  } else {
    warning("Other cancer variable not found. Using placeholder.")
    data$flag_c7_other_cancer <- 0L  # No exclusion
  }

  data
}

#' Criterion 8: Pregnancy Exclusion
#' @keywords internal
apply_c8_pregnancy <- function(data, config) {
  # Check for pregnancy flags
  preg_cols <- c("Pregnant", "pregnancy", "HAS_PREGNANCY")
  found_col <- intersect(preg_cols, names(data))

  if (length(found_col) > 0) {
    # flag=1 means patient is pregnant = should be EXCLUDED
    data$flag_c8_pregnancy <- as.integer(data[[found_col[1]]] == 1)
  } else {
    warning("Pregnancy variable not found. Using placeholder.")
    data$flag_c8_pregnancy <- 0L  # No exclusion
  }

  data
}

#' Criterion 9: Clinical Trial Exclusion
#' @keywords internal
apply_c9_clinical_trial <- function(data, config) {
  # Check for clinical trial flags
  ct_cols <- c("CT_part", "clinical_trial", "HAS_CLINICAL_TRIAL")
  found_col <- intersect(ct_cols, names(data))

  if (length(found_col) > 0) {
    # flag=1 means patient in clinical trial = should be EXCLUDED
    data$flag_c9_clinical_trial <- as.integer(data[[found_col[1]]] == 1)
  } else {
    warning("Clinical trial variable not found. Using placeholder.")
    data$flag_c9_clinical_trial <- 0L  # No exclusion
  }

  data
}

#' Create final cohort flag combining all enabled criteria
#' @keywords internal
create_final_cohort_flag <- function(data, config) {
  # Start with all patients included
  data$in_final_cohort <- 1L

  # Apply inclusion criteria (must be 1 to be included)
  inclusion_flags <- c()
  if (config$criteria$c0_mm_diagnosis$enabled) inclusion_flags <- c(inclusion_flags, "flag_c0_mm_diagnosis")
  if (config$criteria$c1_mm_diagnosis_strict$enabled) inclusion_flags <- c(inclusion_flags, "flag_c1_mm_strict")
  if (config$criteria$c2_age$enabled) inclusion_flags <- c(inclusion_flags, "flag_c2_age")
  if (config$criteria$c3_mm_therapy_followup$enabled) inclusion_flags <- c(inclusion_flags, "flag_c3_therapy_fu")
  if (config$criteria$c5_baseline_enrollment$enabled) inclusion_flags <- c(inclusion_flags, "flag_c5_ce_baseline")
  if (config$criteria$c6_followup_enrollment$enabled) inclusion_flags <- c(inclusion_flags, "flag_c6_ce_followup")

  for (flag in inclusion_flags) {
    if (flag %in% names(data)) {
      data$in_final_cohort <- data$in_final_cohort * data[[flag]]
    }
  }

  # Apply exclusion criteria (must be 0 to be included)
  exclusion_flags <- c()
  if (config$criteria$c4_mm_therapy_baseline$enabled) exclusion_flags <- c(exclusion_flags, "flag_c4_therapy_bl")
  if (config$criteria$c7_other_cancer$enabled) exclusion_flags <- c(exclusion_flags, "flag_c7_other_cancer")
  if (config$criteria$c8_pregnancy$enabled) exclusion_flags <- c(exclusion_flags, "flag_c8_pregnancy")
  if (config$criteria$c9_clinical_trial$enabled) exclusion_flags <- c(exclusion_flags, "flag_c9_clinical_trial")

  for (flag in exclusion_flags) {
    if (flag %in% names(data)) {
      # Excluded if flag == 1
      data$in_final_cohort <- data$in_final_cohort * (1L - data[[flag]])
    }
  }

  data
}

#' Get filtered final cohort
#' @param data Data frame with criteria flags applied
#' @return Filtered data frame with only patients in final cohort
#' @export
get_final_cohort <- function(data) {
  if (!"in_final_cohort" %in% names(data)) {
    stop("Final cohort flag not found. Run apply_attrition_criteria() first.")
  }
  data[data$in_final_cohort == 1, ]
}
