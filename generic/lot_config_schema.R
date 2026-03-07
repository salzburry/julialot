#!/usr/bin/env Rscript
# ============================================================
# Generic LOT Framework — Configuration Loader & Validator
# ============================================================
# Loads a disease-specific YAML config and validates all
# required fields, providing clear error messages.
# ============================================================

#' Load and validate a LOT configuration YAML file
#'
#' @param config_path Path to the YAML configuration file
#' @return A validated config list ready for the LOT engine
load_lot_config <- function(config_path) {
  if (!requireNamespace("yaml", quietly = TRUE)) {
    stop("Package 'yaml' is required. Install with: install.packages('yaml')")
  }

  if (!file.exists(config_path)) {
    stop("Config file not found: ", config_path)
  }

  cfg <- yaml::yaml.load_file(config_path)
  validate_lot_config(cfg, config_path)
  cfg
}

#' Validate a LOT config list
#'
#' @param cfg Parsed config list
#' @param source Label for error messages
validate_lot_config <- function(cfg, source = "config") {
  errors <- character(0)

  # --- Required top-level sections ---
  required_sections <- c("disease", "parameters", "medications", "claims_mapping")
  for (sec in required_sections) {
    if (is.null(cfg[[sec]])) {
      errors <- c(errors, sprintf("Missing required section: '%s'", sec))
    }
  }
  if (length(errors) > 0) {
    stop("Config validation failed (", source, "):\n  - ",
         paste(errors, collapse = "\n  - "))
  }

  # --- Disease metadata ---
  if (is.null(cfg$disease$name)) {
    errors <- c(errors, "disease.name is required (e.g., 'Multiple Myeloma')")
  }
  if (is.null(cfg$disease$abbreviation)) {
    errors <- c(errors, "disease.abbreviation is required (e.g., 'MM')")
  }


  # --- Parameters ---
  params <- cfg$parameters
  param_defaults <- list(
    induction_window_days = 60L,
    map_gap_days = 90L,
    medical_day_supply = 28L,
    lot_discon_gap_days = 90L,
    max_lot_lines = 10L
  )
  for (p in names(param_defaults)) {
    if (is.null(params[[p]])) {
      message(sprintf("  NOTE: parameters.%s not set, defaulting to %s", p, param_defaults[[p]]))
      cfg$parameters[[p]] <- param_defaults[[p]]
    }
  }

  # --- Medications: rollup and codelist ---
  meds <- cfg$medications
  if (is.null(meds$rollup) || length(meds$rollup) == 0) {
    errors <- c(errors, "medications.rollup must define at least one medication")
  } else {
    for (i in seq_along(meds$rollup)) {
      med <- meds$rollup[[i]]
      if (is.null(med$medication) || is.null(med$class) || is.null(med$abbreviation)) {
        errors <- c(errors, sprintf(
          "medications.rollup[%d] must have: medication, class, abbreviation", i))
      }
    }
  }

  if (is.null(meds$codelist) || length(meds$codelist) == 0) {
    if (is.null(meds$codelist_table)) {
      errors <- c(errors, paste(
        "medications must have either 'codelist' (inline codes)",
        "or 'codelist_table' (external table reference)"))
    }
  }

  # --- Claims mapping ---
  cm <- cfg$claims_mapping
  if (is.null(cm$patient_id_field)) {
    cfg$claims_mapping$patient_id_field <- "PATID"
  }
  if (is.null(cm$date_field)) {
    errors <- c(errors, "claims_mapping.date_field is required (e.g., 'FST_DT' or 'FILL_DT')")
  }

  # --- Excluded classes (optional but common) ---
  if (is.null(cfg$parameters$excluded_classes_from_lot_start)) {
    cfg$parameters$excluded_classes_from_lot_start <- character(0)
  }

  if (length(errors) > 0) {
    stop("Config validation failed (", source, "):\n  - ",
         paste(errors, collapse = "\n  - "))
  }

  invisible(cfg)
}

#' Build SQL VALUES clause from rollup config
#'
#' @param rollup List of medication rollup entries from config
#' @return SQL string for CREATE VIEW
build_rollup_sql <- function(rollup) {
  rows <- vapply(rollup, function(med) {
    esc <- function(x) {
      if (is.null(x) || is.na(x)) return("NULL")
      paste0("'", gsub("'", "''", as.character(x)), "'")
    }
    sprintf("(%s, %s, %s, %s, %s, %s, %s)",
      esc(med$medication),
      esc(med$class),
      esc(med$abbreviation),
      if (isTRUE(med$monomaintenance)) "1" else "0",
      esc(med$dualmaintenance_with),
      if (isTRUE(med$conditioning)) "1" else "0",
      if (isTRUE(med$used_for_other_cancers)) "1" else "0"
    )
  }, character(1))

  paste0(
    "SELECT * FROM (VALUES\n  ",
    paste(rows, collapse = ",\n  "),
    "\n) AS t(\n",
    "  CL_MEDICATION_FULL, CL_MED_CLASS, CL_MED_ABBR,\n",
    "  MONOMAINTENANCE, DUALMAINTENANCEWITH,\n",
    "  CONDITIONING, USED_FOR_OTHER_CANCERS\n",
    ")"
  )
}

#' Build SQL VALUES clause from codelist config
#'
#' @param codelist List of code entries from config
#' @return SQL string for CREATE VIEW
build_codelist_sql <- function(codelist) {
  rows <- vapply(codelist, function(code) {
    esc <- function(x) paste0("'", gsub("'", "''", as.character(x)), "'")
    sprintf("(%s, %s, %s, %s, %s)",
      esc(code$code_type),
      esc(code$code),
      esc(code$medication),
      esc(code$class),
      esc(code$abbreviation)
    )
  }, character(1))

  paste0(
    "SELECT * FROM (VALUES\n  ",
    paste(rows, collapse = ",\n  "),
    "\n) AS t(\n",
    "  CL_CODE_TYPE, CL_CODE, CL_MEDICATION_FULL,\n",
    "  CL_MED_CLASS, CL_MED_ABBR\n",
    ")"
  )
}

#' Build SQL VALUES clause from permissible substitutions
#'
#' @param subs List of substitution pairs from config
#' @return SQL string or NULL if no subs defined
build_permissible_subs_sql <- function(subs) {
  if (is.null(subs) || length(subs) == 0) return(NULL)

  rows <- vapply(subs, function(s) {
    sprintf("('%s', '%s')", s$original, s$substitute)
  }, character(1))

  paste0(
    "SELECT * FROM (VALUES\n  ",
    paste(rows, collapse = ",\n  "),
    "\n) AS t(original_med, substitute_med)"
  )
}

#' Build SQL VALUES clause from procedure codelist (e.g., SCT)
#'
#' @param procedures List of procedure code entries from config
#' @return SQL string or NULL if no procedures defined
build_procedure_codelist_sql <- function(procedures) {
  if (is.null(procedures) || length(procedures) == 0) return(NULL)

  rows <- vapply(procedures, function(p) {
    sprintf("('%s', '%s', '%s')",
      p$code_type, p$code, p$procedure_type)
  }, character(1))

  paste0(
    "SELECT * FROM (VALUES\n  ",
    paste(rows, collapse = ",\n  "),
    "\n) AS t(CL_CODE_TYPE, CL_CODE, PROCEDURE_TYPE)"
  )
}
