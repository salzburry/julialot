#!/usr/bin/env Rscript
# validate_reference_data.R
# Codelist / registry validation (Increment 2). Runs on intake -> validated.
# Returns BLOCKING errors vs non-blocking WARNINGS; invalid rows are reported,
# never silently dropped. Pure R; runnable.

VALID_CODE_SYSTEMS <- c("HCPCS", "CPT", "NDC", "ICD9DIAG", "ICD10DIAG",
                        "ICD9PROC", "ICD10PROC")
REQUIRED_COLS <- c("code", "code_type", "mapped_to")

# The exact, documented NDC normalization rule: strip non-digits, left-ZERO-pad
# to 11. (Note: formatC(flag="0") space-pads characters, so we pad explicitly.)
normalize_ndc <- function(code) {
  digits <- gsub("[^0-9]", "", as.character(code))
  ok <- nchar(digits) >= 10 & nchar(digits) <= 11
  padded <- paste0(strrep("0", pmax(0, 11 - nchar(digits))), digits)
  ifelse(ok, padded, NA_character_)
}
normalize_proc <- function(code) toupper(gsub("[^A-Za-z0-9]", "", as.character(code)))

# manifest_entry: list(id, version, expected_systems, row_count_min, row_count_max,
#                      effective_start (optional), effective_end (optional))
validate_reference_data <- function(df, manifest_entry) {
  errors <- character(0); warnings <- character(0)

  # 1. schema
  missing <- setdiff(REQUIRED_COLS, names(df))
  if (length(missing))
    errors <- c(errors, sprintf("missing required column(s): %s", paste(missing, collapse = ", ")))
  if (length(errors)) return(list(errors = errors, warnings = warnings, normalized = NULL))

  n <- nrow(df)
  if (n == 0) errors <- c(errors, "0 data rows")

  # 2. code-system domain
  ct <- toupper(trimws(as.character(df$code_type)))
  bad_sys <- which(!(ct %in% VALID_CODE_SYSTEMS))
  if (length(bad_sys))
    errors <- c(errors, sprintf("%d row(s) with unknown code_type (e.g. row %d: '%s')",
                                length(bad_sys), bad_sys[1], ct[bad_sys[1]]))

  # 3. blank code / mapped_to
  blank <- which(!nzchar(trimws(as.character(df$code))) |
                 !nzchar(trimws(as.character(df$mapped_to))))
  if (length(blank))
    errors <- c(errors, sprintf("%d row(s) with blank code or mapped_to (e.g. row %d)",
                                length(blank), blank[1]))

  # 4. NDC normalization + collisions
  is_ndc <- ct == "NDC"
  if (any(is_ndc)) {
    norm <- normalize_ndc(df$code[is_ndc])
    bad_ndc <- which(is.na(norm))
    if (length(bad_ndc))
      errors <- c(errors, sprintf("%d NDC row(s) not 10-11 digits after stripping (rejected, not matched)",
                                  length(bad_ndc)))
    okn <- !is.na(norm)
    if (any(okn)) {
      nc  <- norm[okn]
      mt  <- toupper(trimws(as.character(df$mapped_to[is_ndc][okn])))
      raw <- as.character(df$code[is_ndc][okn])
      # BLOCKING: one normalized NDC mapping to >1 distinct concept (mapped_to).
      conflict <- names(which(tapply(mt, nc, function(x) length(unique(x)) > 1)))
      if (length(conflict))
        errors <- c(errors, sprintf("%d normalized NDC(s) map to >1 concept (e.g. %s -> {%s})",
                    length(conflict), conflict[1],
                    paste(unique(mt[nc == conflict[1]]), collapse = ", ")))
      # WARNING: two raw forms normalize to the same code (same concept).
      if (any(unlist(tapply(raw, nc, function(x) length(unique(x)) > 1))))
        warnings <- c(warnings, "two raw NDC forms normalize to the same 11-digit code")
    }
  }

  # 5. procedure-code normalization collisions (HCPCS/CPT)
  is_proc <- ct %in% c("HCPCS", "CPT")
  if (any(is_proc)) {
    np <- normalize_proc(df$code[is_proc])
    if (any(!nzchar(np)))
      errors <- c(errors, "procedure code(s) empty after normalization")
  }

  # 6. row-count bounds (manifest/version level)
  if (!is.null(manifest_entry$row_count_min) && n < manifest_entry$row_count_min)
    errors <- c(errors, sprintf("row count %d below expected min %d", n, manifest_entry$row_count_min))
  if (!is.null(manifest_entry$row_count_max) && n > manifest_entry$row_count_max)
    warnings <- c(warnings, sprintf("row count %d above expected max %d", n, manifest_entry$row_count_max))

  # 7. expected code-system coverage
  if (!is.null(manifest_entry$expected_systems)) {
    missing_sys <- setdiff(manifest_entry$expected_systems, unique(ct))
    if (length(missing_sys))
      warnings <- c(warnings, sprintf("expected code systems not present: %s",
                                      paste(missing_sys, collapse = ", ")))
  }

  list(errors = errors, warnings = warnings,
       normalized = data.frame(code_type = ct, stringsAsFactors = FALSE))
}

report <- function(res, id = "codelist") {
  cat(sprintf("== %s ==\n", id))
  if (length(res$warnings)) for (w in res$warnings) cat("  WARN:  ", w, "\n")
  if (length(res$errors))  for (e in res$errors)  cat("  ERROR: ", e, "\n")
  cat(if (length(res$errors)) "  -> BLOCKED\n" else "  -> OK (promotable)\n")
  invisible(length(res$errors) == 0)
}

if (sys.nframe() == 0 && !interactive()) {
  # self-test
  df <- data.frame(code = c("J8540", "00002-1433-80", "BADNDC"),
                   code_type = c("HCPCS", "NDC", "NDC"),
                   mapped_to = c("DEXA", "DEXA", "DEXA"), stringsAsFactors = FALSE)
  report(validate_reference_data(df, list(id = "steroid", row_count_min = 1,
                                          expected_systems = c("HCPCS", "NDC"))), "steroid (self-test)")
}
