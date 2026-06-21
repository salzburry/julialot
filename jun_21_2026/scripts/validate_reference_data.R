#!/usr/bin/env Rscript
# validate_reference_data.R
# Codelist / registry validation (Increment 2). Runs on intake -> validated.
# Returns BLOCKING errors vs non-blocking WARNINGS; invalid rows are reported,
# never silently dropped. Pure R; runnable.

VALID_CODE_SYSTEMS <- c("HCPCS", "CPT", "NDC", "ICD9DIAG", "ICD10DIAG",
                        "ICD9PROC", "ICD10PROC")
REQUIRED_COLS <- c("code", "code_type", "mapped_to")

# NDC: require validated 11-digit (segment-aware 10->11 is the adapter's job).
normalize_ndc <- function(code) {
  d <- gsub("[^0-9]", "", as.character(code))
  ifelse(nchar(d) == 11L, d, NA_character_)
}
normalize_proc <- function(code) toupper(gsub("[^A-Za-z0-9]", "", as.character(code)))
# Normalize per code system.
normalize_code <- function(code, code_system) {
  cs <- toupper(trimws(as.character(code_system)))
  ifelse(cs == "NDC", normalize_ndc(code), normalize_proc(code))
}

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

  # 4. normalize per system; NDC must be 11-digit, others non-empty
  norm <- normalize_code(df$code, ct)
  mt   <- toupper(trimws(as.character(df$mapped_to)))
  raw  <- as.character(df$code)
  bad_ndc <- which(ct == "NDC" & is.na(norm))
  if (length(bad_ndc))
    errors <- c(errors, sprintf("%d NDC row(s) not a valid 11-digit code (rejected; supply 11-digit NDC)",
                                length(bad_ndc)))
  bad_proc <- which(ct != "NDC" & ct %in% VALID_CODE_SYSTEMS & (is.na(norm) | !nzchar(norm)))
  if (length(bad_proc))
    errors <- c(errors, sprintf("%d non-NDC code(s) empty after normalization", length(bad_proc)))

  # 5. GENERAL collision (every code system): one (code_system, normalized_code)
  #    must not map to >1 distinct concept = BLOCKING; two raw forms -> same code
  #    (same concept) = warning.
  okc <- !is.na(norm) & nzchar(norm)
  if (any(okc)) {
    key <- paste(ct[okc], norm[okc])
    conflict <- names(which(tapply(mt[okc], key, function(x) length(unique(x)) > 1)))
    if (length(conflict))
      errors <- c(errors, sprintf("%d normalized code(s) map to >1 concept (e.g. %s -> {%s})",
                  length(conflict), conflict[1], paste(unique(mt[okc][key == conflict[1]]), collapse = ", ")))
    if (any(unlist(tapply(raw[okc], key, function(x) length(unique(x)) > 1))))
      warnings <- c(warnings, "two raw forms normalize to the same code")
  }

  # 5b. EXACT duplicate rows: identical (code_type, normalized_code, mapped_to).
  #     Harmless to set semantics but a hygiene smell (copy/paste, bad merge) -
  #     reported, never silently de-duped. Computed on normalized rows so two raw
  #     spellings of the same code+concept also count.
  if (any(okc)) {
    dk <- paste(ct[okc], norm[okc], mt[okc], sep = "\037")
    ndup <- sum(duplicated(dk))
    if (ndup > 0) {
      ex <- dk[duplicated(dk)][1]
      warnings <- c(warnings, sprintf("%d exact-duplicate row(s) (same code_type+normalized_code+mapped_to; e.g. %s)",
                    ndup, gsub("\037", "/", ex)))
    }
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
       normalized = data.frame(code_type = ct, raw_code = raw,
                               normalized_code = norm, mapped_to = mt,
                               stringsAsFactors = FALSE))
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
