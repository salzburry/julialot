#' Attrition Table Generation
#'
#' Functions to generate formatted attrition tables showing patient counts
#' at each step of the cohort selection process.

#' Generate attrition table from cohort data
#'
#' @param data Data frame with criteria flags applied (output from apply_attrition_criteria)
#' @param config Configuration list (optional, will use attached config if not provided)
#' @param by_window Generate separate columns for each diagnosis window (30/60/90 days)
#' @return Data frame representing the attrition table
#' @export
generate_attrition_table <- function(data, config = NULL, by_window = TRUE) {
  # Get config from data if not provided
  if (is.null(config)) {
    config <- attr(data, "config")
    if (is.null(config)) {
      stop("Configuration not found. Provide config parameter or use output from apply_attrition_criteria().")
    }
  }

  # Get diagnosis windows
  windows <- config$diagnosis_window$windows_to_use

  # Initialize attrition table
  attrition <- data.frame(
    step = integer(),
    criteria_type = character(),
    criteria_description = character(),
    stringsAsFactors = FALSE
  )

  # Add columns for each window if by_window = TRUE
  if (by_window) {
    for (w in windows) {
      attrition[[paste0("n_", w, "d")]] <- integer()
      attrition[[paste0("pct_", w, "d")]] <- numeric()
    }
  } else {
    attrition$n <- integer()
    attrition$pct <- numeric()
  }

  # Step 0: Starting population
  step <- 0
  row <- list(
    step = step,
    criteria_type = "Base",
    criteria_description = ">=1 medical claims for multiple myeloma (ICD-9-CM=203.x or ICD-10-CM=C90.x) in any position on claim"
  )

  if (by_window) {
    for (w in windows) {
      # Base cohort - same for all windows
      if ("flag_c0_mm_diagnosis" %in% names(data)) {
        n <- sum(data$flag_c0_mm_diagnosis == 1, na.rm = TRUE)
      } else {
        n <- nrow(data)
      }
      row[[paste0("n_", w, "d")]] <- n
      row[[paste0("pct_", w, "d")]] <- 100.0
    }
  } else {
    n <- nrow(data)
    row$n <- n
    row$pct <- 100.0
  }
  attrition <- rbind(attrition, as.data.frame(row, stringsAsFactors = FALSE))

  # Helper function to calculate cumulative filter
  calc_cumulative <- function(data, flags, window = NULL) {
    mask <- rep(TRUE, nrow(data))
    for (f in flags) {
      if (f$type == "inclusion") {
        col <- f$col
        if (!is.null(window) && paste0(f$col_base, "_", window, "d") %in% names(data)) {
          col <- paste0(f$col_base, "_", window, "d")
        }
        if (col %in% names(data)) {
          mask <- mask & (data[[col]] == 1)
        }
      } else if (f$type == "exclusion") {
        if (f$col %in% names(data)) {
          mask <- mask & (data[[f$col]] == 0)
        }
      }
    }
    sum(mask, na.rm = TRUE)
  }

  # Track cumulative flags
  cumulative_flags <- list()
  base_n <- nrow(data)

  # Step 1: Inpatient/Outpatient requirement
  if (config$criteria$c1_mm_diagnosis_strict$enabled) {
    step <- step + 1
    window_days <- config$criteria$c1_mm_diagnosis_strict$options$window_days

    row <- list(
      step = step,
      criteria_type = "Inclusion",
      criteria_description = sprintf(
        "At least one inpatient medical claim OR >= %d outpatient medical claims within %d/%d/%d days",
        config$criteria$c1_mm_diagnosis_strict$options$outpatient_count,
        windows[1], windows[2], windows[3]
      )
    )

    cumulative_flags[[length(cumulative_flags) + 1]] <- list(
      type = "inclusion", col = "flag_c1_mm_strict", col_base = "flag_c1"
    )

    if (by_window) {
      for (w in windows) {
        flag_col <- paste0("flag_c1_", w, "d")
        if (flag_col %in% names(data)) {
          n <- sum(data[[flag_col]] == 1, na.rm = TRUE)
        } else {
          n <- sum(data$flag_c1_mm_strict == 1, na.rm = TRUE)
        }
        row[[paste0("n_", w, "d")]] <- n
        row[[paste0("pct_", w, "d")]] <- round(n / base_n * 100, 1)
      }
    } else {
      n <- sum(data$flag_c1_mm_strict == 1, na.rm = TRUE)
      row$n <- n
      row$pct <- round(n / base_n * 100, 1)
    }
    attrition <- rbind(attrition, as.data.frame(row, stringsAsFactors = FALSE))
  }

  # Step 2: Age requirement
  if (config$criteria$c2_age$enabled) {
    step <- step + 1
    min_age <- config$criteria$c2_age$options$min_age

    row <- list(
      step = step,
      criteria_type = "Inclusion",
      criteria_description = sprintf("Patients %d years of age or older in the index year", min_age)
    )

    cumulative_flags[[length(cumulative_flags) + 1]] <- list(
      type = "inclusion", col = "flag_c2_age", col_base = "flag_c2_age"
    )

    if (by_window) {
      for (w in windows) {
        n <- calc_cumulative(data, cumulative_flags, w)
        row[[paste0("n_", w, "d")]] <- n
        row[[paste0("pct_", w, "d")]] <- round(n / base_n * 100, 1)
      }
    } else {
      n <- calc_cumulative(data, cumulative_flags)
      row$n <- n
      row$pct <- round(n / base_n * 100, 1)
    }
    attrition <- rbind(attrition, as.data.frame(row, stringsAsFactors = FALSE))
  }

  # Step 3: MM Therapy in follow-up
  if (config$criteria$c3_mm_therapy_followup$enabled) {
    step <- step + 1

    row <- list(
      step = step,
      criteria_type = "Inclusion",
      criteria_description = "Evidence of FDA-approved MM oncology therapy in claims during the follow-up period"
    )

    cumulative_flags[[length(cumulative_flags) + 1]] <- list(
      type = "inclusion", col = "flag_c3_therapy_fu", col_base = "flag_c3_therapy_fu"
    )

    if (by_window) {
      for (w in windows) {
        n <- calc_cumulative(data, cumulative_flags, w)
        row[[paste0("n_", w, "d")]] <- n
        row[[paste0("pct_", w, "d")]] <- round(n / base_n * 100, 1)
      }
    } else {
      n <- calc_cumulative(data, cumulative_flags)
      row$n <- n
      row$pct <- round(n / base_n * 100, 1)
    }
    attrition <- rbind(attrition, as.data.frame(row, stringsAsFactors = FALSE))
  }

  # Step 4: No MM Therapy in baseline (Exclusion)
  if (config$criteria$c4_mm_therapy_baseline$enabled) {
    step <- step + 1

    row <- list(
      step = step,
      criteria_type = "Exclusion",
      criteria_description = ">= 1 medical or pharmacy claim for FDA-approved MM oncology therapy during baseline period"
    )

    cumulative_flags[[length(cumulative_flags) + 1]] <- list(
      type = "exclusion", col = "flag_c4_therapy_bl", col_base = "flag_c4_therapy_bl"
    )

    if (by_window) {
      for (w in windows) {
        n <- calc_cumulative(data, cumulative_flags, w)
        row[[paste0("n_", w, "d")]] <- n
        row[[paste0("pct_", w, "d")]] <- round(n / base_n * 100, 1)
      }
    } else {
      n <- calc_cumulative(data, cumulative_flags)
      row$n <- n
      row$pct <- round(n / base_n * 100, 1)
    }
    attrition <- rbind(attrition, as.data.frame(row, stringsAsFactors = FALSE))
  }

  # Step 5: Baseline enrollment
  if (config$criteria$c5_baseline_enrollment$enabled) {
    step <- step + 1
    req_months <- config$criteria$c5_baseline_enrollment$options$required_months
    gap_days <- config$criteria$c5_baseline_enrollment$options$allowable_gap_days

    row <- list(
      step = step,
      criteria_type = "Inclusion",
      criteria_description = sprintf(
        ">= %d months of Continuous Enrollment with medical and pharmacy benefits before index date (gaps <= %d days allowed)",
        req_months, gap_days
      )
    )

    cumulative_flags[[length(cumulative_flags) + 1]] <- list(
      type = "inclusion", col = "flag_c5_ce_baseline", col_base = "flag_c5_ce_baseline"
    )

    if (by_window) {
      for (w in windows) {
        n <- calc_cumulative(data, cumulative_flags, w)
        row[[paste0("n_", w, "d")]] <- n
        row[[paste0("pct_", w, "d")]] <- round(n / base_n * 100, 1)
      }
    } else {
      n <- calc_cumulative(data, cumulative_flags)
      row$n <- n
      row$pct <- round(n / base_n * 100, 1)
    }
    attrition <- rbind(attrition, as.data.frame(row, stringsAsFactors = FALSE))
  }

  # Step 6: Follow-up enrollment
  if (config$criteria$c6_followup_enrollment$enabled) {
    step <- step + 1
    min_days <- config$criteria$c6_followup_enrollment$options$min_days

    row <- list(
      step = step,
      criteria_type = "Inclusion",
      criteria_description = sprintf(
        ">= %d day(s) of Continuous Enrollment starting on index date",
        min_days
      )
    )

    cumulative_flags[[length(cumulative_flags) + 1]] <- list(
      type = "inclusion", col = "flag_c6_ce_followup", col_base = "flag_c6_ce_followup"
    )

    if (by_window) {
      for (w in windows) {
        n <- calc_cumulative(data, cumulative_flags, w)
        row[[paste0("n_", w, "d")]] <- n
        row[[paste0("pct_", w, "d")]] <- round(n / base_n * 100, 1)
      }
    } else {
      n <- calc_cumulative(data, cumulative_flags)
      row$n <- n
      row$pct <- round(n / base_n * 100, 1)
    }
    attrition <- rbind(attrition, as.data.frame(row, stringsAsFactors = FALSE))
  }

  # Step 7: Other cancer (Exclusion) - if enabled
  if (config$criteria$c7_other_cancer$enabled) {
    step <- step + 1

    row <- list(
      step = step,
      criteria_type = "Exclusion",
      criteria_description = ">= 1 medical claim for MM during the baseline period (non-diagnostic)"
    )

    cumulative_flags[[length(cumulative_flags) + 1]] <- list(
      type = "exclusion", col = "flag_c7_other_cancer", col_base = "flag_c7_other_cancer"
    )

    if (by_window) {
      for (w in windows) {
        n <- calc_cumulative(data, cumulative_flags, w)
        row[[paste0("n_", w, "d")]] <- n
        row[[paste0("pct_", w, "d")]] <- round(n / base_n * 100, 1)
      }
    } else {
      n <- calc_cumulative(data, cumulative_flags)
      row$n <- n
      row$pct <- round(n / base_n * 100, 1)
    }
    attrition <- rbind(attrition, as.data.frame(row, stringsAsFactors = FALSE))
  }

  # Step 8: Pregnancy (Exclusion) - if enabled
  if (config$criteria$c8_pregnancy$enabled) {
    step <- step + 1

    row <- list(
      step = step,
      criteria_type = "Exclusion",
      criteria_description = "Pregnancy or childbirth during the baseline or follow-up period"
    )

    cumulative_flags[[length(cumulative_flags) + 1]] <- list(
      type = "exclusion", col = "flag_c8_pregnancy", col_base = "flag_c8_pregnancy"
    )

    if (by_window) {
      for (w in windows) {
        n <- calc_cumulative(data, cumulative_flags, w)
        row[[paste0("n_", w, "d")]] <- n
        row[[paste0("pct_", w, "d")]] <- round(n / base_n * 100, 1)
      }
    } else {
      n <- calc_cumulative(data, cumulative_flags)
      row$n <- n
      row$pct <- round(n / base_n * 100, 1)
    }
    attrition <- rbind(attrition, as.data.frame(row, stringsAsFactors = FALSE))
  }

  # Step 9: Clinical trial (Exclusion) - if enabled
  if (config$criteria$c9_clinical_trial$enabled) {
    step <- step + 1

    row <- list(
      step = step,
      criteria_type = "Exclusion",
      criteria_description = "Evidence of clinical trial participation during baseline and follow-up periods"
    )

    cumulative_flags[[length(cumulative_flags) + 1]] <- list(
      type = "exclusion", col = "flag_c9_clinical_trial", col_base = "flag_c9_clinical_trial"
    )

    if (by_window) {
      for (w in windows) {
        n <- calc_cumulative(data, cumulative_flags, w)
        row[[paste0("n_", w, "d")]] <- n
        row[[paste0("pct_", w, "d")]] <- round(n / base_n * 100, 1)
      }
    } else {
      n <- calc_cumulative(data, cumulative_flags)
      row$n <- n
      row$pct <- round(n / base_n * 100, 1)
    }
    attrition <- rbind(attrition, as.data.frame(row, stringsAsFactors = FALSE))
  }

  # Format step numbers
  attrition$step <- paste0("Step ", attrition$step, ":")

  # Rename columns for clarity
  if (by_window) {
    for (w in windows) {
      names(attrition)[names(attrition) == paste0("n_", w, "d")] <- paste0(w, "-day Cohort (n)")
      names(attrition)[names(attrition) == paste0("pct_", w, "d")] <- paste0(w, "-day Cohort (%)")
    }
  }

  names(attrition)[names(attrition) == "step"] <- "Step"
  names(attrition)[names(attrition) == "criteria_type"] <- "Inclusion/Exclusion"
  names(attrition)[names(attrition) == "criteria_description"] <- "Criteria Description"

  attrition
}

#' Print formatted attrition table
#' @param attrition_table Attrition table from generate_attrition_table()
#' @export
print_attrition_table <- function(attrition_table) {
  cat("\n")
  cat("=" %>% rep(100) %>% paste(collapse = ""))
  cat("\n                           ATTRITION TABLE\n")
  cat("=" %>% rep(100) %>% paste(collapse = ""))
  cat("\n\n")

  # Simple text output
  for (i in seq_len(nrow(attrition_table))) {
    row <- attrition_table[i, ]
    cat(sprintf("%s %s: %s\n",
                row[["Step"]],
                row[["Inclusion/Exclusion"]],
                row[["Criteria Description"]]))

    # Print counts for each window
    count_cols <- grep("Cohort \\(n\\)", names(row), value = TRUE)
    for (col in count_cols) {
      window_name <- gsub(" \\(n\\)", "", col)
      pct_col <- gsub("\\(n\\)", "(%)", col)
      cat(sprintf("    %s: n = %s (%.1f%%)\n",
                  window_name,
                  format(row[[col]], big.mark = ","),
                  row[[pct_col]]))
    }
    cat("\n")
  }
}

#' Export attrition table to file
#' @param attrition_table Attrition table
#' @param filepath Output file path
#' @param format Output format: "csv", "xlsx", or "rds"
#' @export
export_attrition_table <- function(attrition_table, filepath, format = "csv") {
  format <- tolower(format)

  if (format == "csv") {
    write.csv(attrition_table, filepath, row.names = FALSE)
  } else if (format == "xlsx") {
    if (!requireNamespace("writexl", quietly = TRUE)) {
      stop("Package 'writexl' required for xlsx export. Install with: install.packages('writexl')")
    }
    writexl::write_xlsx(attrition_table, filepath)
  } else if (format == "rds") {
    saveRDS(attrition_table, filepath)
  } else {
    stop("Unknown format. Use 'csv', 'xlsx', or 'rds'.")
  }

  message(sprintf("Attrition table exported to: %s", filepath))
}

#' Pipe operator for print function
#' @keywords internal
`%>%` <- function(lhs, rhs) {
  # Simple implementation for rep and paste
  if (is.function(rhs)) {
    rhs(lhs)
  } else {
    # Handle special cases
    call <- match.call()
    eval(call[[3]], envir = list(`.` = lhs))
  }
}
