#!/usr/bin/env Rscript
# validate_canonical.R
# The adapter VALIDATION REPORT, runnable locally on canonical-shaped CSVs
# (synthetic fixtures or, in prod, the adapter views). Checks schema
# conformance, required/non-null, types, NDC normalization correctness,
# key-uniqueness, and reports rejected rows (never silently dropped).
# Pure R (+ lib.R). Runs before core stages.

if (!exists(".lotlib")) source(local({ .find_lib <- function() {
  fa <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(fa)) { p <- file.path(dirname(sub("^--file=", "", fa[1])), "lib.R"); if (file.exists(p)) return(p) }
  for (p in c("scripts/lib.R", "lib.R")) if (file.exists(p)) return(p); stop("lib.R not found") }; .find_lib() }))

# Contract (subset; from contracts/inputs.md). type: string|date|integer.
CANONICAL_SPEC <- list(
  members = list(file = "members.csv", entity = "canonical_enrollment",
    cols = list(patient_id = "string,required", span_start = "date,required",
                span_end = "date,required", coverage_type = "string",
                data_vintage = "string,required"),
    key = c("patient_id", "span_start", "span_end", "coverage_type")),
  pharmacy = list(file = "pharmacy.csv", entity = "canonical_pharmacy",
    cols = list(patient_id = "string,required", service_date = "date,required",
                raw_ndc = "string,required", normalized_code = "string,required",
                code_system = "string,required", days_supply = "integer,required",
                claim_status = "string", reversal_status = "string",
                source_table = "string", source_record_id = "string",
                data_vintage = "string,required"),
    key = c("patient_id", "service_date", "normalized_code", "source_record_id"),
    ndc = TRUE),
  medical = list(file = "medical.csv", entity = "canonical_medical",
    cols = list(patient_id = "string,required", service_date = "date,required",
                raw_proc_code = "string", raw_bill_proc_code = "string",
                raw_ndc = "string", normalized_code = "string",
                code_system = "string", day_supply = "integer,required",
                place_of_service = "string", claim_status = "string",
                reversal_status = "string", source_table = "string",
                source_record_id = "string", data_vintage = "string,required"),
    key = c("patient_id", "service_date", "normalized_code", "code_system", "source_record_id"),
    ndc = TRUE),
  diagnosis = list(file = "diagnosis.csv", entity = "canonical_diagnosis",
    cols = list(patient_id = "string,required", event_date = "date,required",
                raw_code = "string,required", normalized_code = "string,required",
                code_system = "string,required", source_table = "string",
                source_record_id = "string", data_vintage = "string,required"),
    key = c("patient_id", "event_date", "normalized_code", "code_system", "source_record_id")),
  procedure = list(file = "procedure.csv", entity = "canonical_procedure",
    cols = list(patient_id = "string,required", event_date = "date,required",
                raw_code = "string,required", normalized_code = "string,required",
                code_system = "string,required", source_table = "string",
                source_record_id = "string", data_vintage = "string,required"),
    key = c("patient_id", "event_date", "normalized_code", "code_system", "source_record_id")),
  death = list(file = "death.csv", entity = "canonical_death",
    cols = list(patient_id = "string,required", death_date = "date,required",
                death_date_source = "string", data_vintage = "string,required"),
    key = c("patient_id"))
)
# All six entities are part of the contract; the adapter output must produce
# each. validate_canonical_dir(require_present=TRUE) errors on any missing one.
REQUIRED_ENTITIES <- names(CANONICAL_SPEC)

.req <- function(spec_str) grepl("required", spec_str)
.typ <- function(spec_str) sub(",.*$", "", spec_str)

validate_entity <- function(df, spec) {
  errors <- character(0); warnings <- character(0); rejected <- 0L
  cols <- spec$cols
  miss <- setdiff(names(cols)[vapply(cols, .req, logical(1))], names(df))
  if (length(miss)) {
    errors <- c(errors, sprintf("missing required column(s): %s", paste(miss, collapse = ", ")))
    return(list(errors = errors, warnings = warnings, report = list(rows = nrow(df), rejected = NA)))
  }
  for (cn in intersect(names(cols), names(df))) {
    v <- df[[cn]]; t <- .typ(cols[[cn]])
    if (.req(cols[[cn]]) && any(!nzchar(trimws(as.character(v))) | is.na(v))) {
      n <- sum(!nzchar(trimws(as.character(v))) | is.na(v))
      errors <- c(errors, sprintf("%s: %d null/blank in required column", cn, n)); rejected <- rejected + n
    }
    if (t == "date" && any(nzchar(as.character(v)) & !is_iso_date(v))) {
      n <- sum(nzchar(as.character(v)) & !is_iso_date(v))
      errors <- c(errors, sprintf("%s: %d non-ISO date(s)", cn, n)); rejected <- rejected + n
    }
    if (t == "integer" && any(nzchar(as.character(v)) &
        is.na(suppressWarnings(as.integer(as.character(v)))))) {
      errors <- c(errors, sprintf("%s: non-integer value(s)", cn))
    }
  }
  # NDC normalization correctness
  if (isTRUE(spec$ndc) && all(c("raw_ndc", "normalized_code", "code_system") %in% names(df))) {
    isn <- toupper(df$code_system) == "NDC" & nzchar(as.character(df$raw_ndc))
    if (any(isn)) {
      exp <- normalize_ndc(df$raw_ndc[isn]); got <- as.character(df$normalized_code[isn])
      bad <- which(is.na(exp) | exp != got)
      if (length(bad))
        errors <- c(errors, sprintf("NDC normalization mismatch/reject in %d row(s) (e.g. raw '%s' -> expected '%s', got '%s')",
                    length(bad), df$raw_ndc[isn][bad[1]], exp[bad[1]] %||% "NA", got[bad[1]]))
    }
  }
  # key uniqueness
  if (!is.null(spec$key) && all(spec$key %in% names(df))) {
    k <- do.call(paste, c(df[spec$key], sep = "\037"))
    if (any(duplicated(k)))
      errors <- c(errors, sprintf("key %s not unique (%d duplicate rows)",
                  paste(spec$key, collapse = "+"), sum(duplicated(k))))
  }
  list(errors = errors, warnings = warnings,
       report = list(rows = nrow(df), rejected = rejected))
}

validate_canonical_dir <- function(dir, spec = CANONICAL_SPEC, require_present = TRUE) {
  out <- list(); ok <- TRUE
  for (nm in names(spec)) {
    p <- file.path(dir, spec[[nm]]$file)
    if (!file.exists(p)) {
      # A required canonical entity that is absent is an ERROR (an incomplete
      # adapter output / fixture dir must not pass the "adapter validation" gate).
      if (require_present && nm %in% REQUIRED_ENTITIES) {
        out[[nm]] <- list(errors = sprintf("required canonical entity '%s' missing (%s)", nm, spec[[nm]]$file),
                          warnings = character(0), report = list(rows = 0L, rejected = NA))
        ok <- FALSE
      }
      next
    }
    df <- read.csv(p, stringsAsFactors = FALSE, check.names = FALSE, colClasses = "character")
    res <- validate_entity(df, spec[[nm]])
    out[[nm]] <- res
    if (length(res$errors)) ok <- FALSE
  }
  attr(out, "ok") <- ok
  out
}

report_canonical <- function(res) {
  for (nm in names(res)) {
    r <- res[[nm]]
    cat(sprintf("== %s (rows=%d, rejected=%s) ==\n", nm, r$report$rows, r$report$rejected))
    for (w in r$warnings) cat("  WARN: ", w, "\n")
    for (e in r$errors)  cat("  ERROR:", e, "\n")
    if (!length(r$errors)) cat("  OK\n")
  }
  invisible(isTRUE(attr(res, "ok")))
}

if (sys.nframe() == 0 && !interactive()) {
  dir <- commandArgs(trailingOnly = TRUE)[1] %||% "tests/fixtures/synthetic"
  ok <- report_canonical(validate_canonical_dir(dir))
  quit(status = if (ok) 0 else 1)
}
