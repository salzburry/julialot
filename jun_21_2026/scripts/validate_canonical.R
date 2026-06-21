#!/usr/bin/env Rscript
# validate_canonical.R
# The adapter VALIDATION REPORT, runnable locally on canonical-shaped CSVs
# (synthetic fixtures or, in prod, the adapter views). Checks schema
# conformance, required/non-null (incl. lineage), types (decimals rejected),
# code-system domains, NDC/proc normalization correctness, positive day-supply,
# enrollment span ordering, and key-uniqueness; reports rejected rows. Runs
# before core stages. Pure R (+ lib.R).

if (!exists(".lotlib")) source(local({ .find_lib <- function() {
  fa <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(fa)) { p <- file.path(dirname(sub("^--file=", "", fa[1])), "lib.R"); if (file.exists(p)) return(p) }
  for (p in c("scripts/lib.R", "lib.R")) if (file.exists(p)) return(p); stop("lib.R not found") }; .find_lib() }))

# Contract (from contracts/inputs.md). Per entity: cols (name="type[,required]"),
# key, allowed code `systems`, the `raw_col` for normalization, `pos_int` columns
# (must be > 0), and `span` (span_start <= span_end). canonical_medical is now
# ONE ROW PER CODE (raw_code + source_code_field), unifying with dx/procedure.
CANONICAL_SPEC <- list(
  members = list(file = "members.csv", entity = "canonical_enrollment",
    cols = list(patient_id = "string,required", span_start = "date,required",
                span_end = "date,required", coverage_type = "string",
                data_vintage = "string,required"),
    key = c("patient_id", "span_start", "span_end", "coverage_type"), span = TRUE),
  pharmacy = list(file = "pharmacy.csv", entity = "canonical_pharmacy",
    cols = list(patient_id = "string,required", service_date = "date,required",
                raw_ndc = "string,required", normalized_code = "string,required",
                code_system = "string,required", days_supply = "integer,required",
                claim_status = "string", reversal_status = "string",
                source_table = "string,required", source_record_id = "string,required",
                data_vintage = "string,required"),
    key = c("patient_id", "service_date", "normalized_code", "source_record_id"),
    dedup_key = c("patient_id", "service_date", "normalized_code"),
    systems = "NDC", raw_col = "raw_ndc", pos_int = "days_supply"),
  medical = list(file = "medical.csv", entity = "canonical_medical",
    cols = list(patient_id = "string,required", service_date = "date,required",
                raw_code = "string,required", normalized_code = "string,required",
                code_system = "string,required", source_code_field = "string,required",
                day_supply = "integer,required", place_of_service = "string",
                claim_status = "string", reversal_status = "string",
                source_table = "string,required", source_record_id = "string,required",
                data_vintage = "string,required"),
    key = c("patient_id", "service_date", "normalized_code", "code_system", "source_record_id"),
    dedup_key = c("patient_id", "service_date", "normalized_code", "code_system"),
    systems = c("HCPCS", "CPT", "NDC"), raw_col = "raw_code", pos_int = "day_supply",
    enums = list(source_code_field = c("proc_cd", "bill_proc_cd", "ndc"))),
  diagnosis = list(file = "diagnosis.csv", entity = "canonical_diagnosis",
    cols = list(patient_id = "string,required", event_date = "date,required",
                raw_code = "string,required", normalized_code = "string,required",
                code_system = "string,required", source_table = "string,required",
                source_record_id = "string,required", data_vintage = "string,required"),
    key = c("patient_id", "event_date", "normalized_code", "code_system", "source_record_id"),
    systems = c("ICD9DIAG", "ICD10DIAG"), raw_col = "raw_code"),
  procedure = list(file = "procedure.csv", entity = "canonical_procedure",
    cols = list(patient_id = "string,required", event_date = "date,required",
                raw_code = "string,required", normalized_code = "string,required",
                code_system = "string,required", source_table = "string,required",
                source_record_id = "string,required", data_vintage = "string,required"),
    key = c("patient_id", "event_date", "normalized_code", "code_system", "source_record_id"),
    systems = c("ICD9PROC", "ICD10PROC", "HCPCS"), raw_col = "raw_code"),
  death = list(file = "death.csv", entity = "canonical_death",
    cols = list(patient_id = "string,required", death_date = "date,required",
                death_date_source = "string", data_vintage = "string,required"),
    key = c("patient_id"))
)
# All six entities are part of the contract; the adapter output must produce each.
REQUIRED_ENTITIES <- names(CANONICAL_SPEC)

.req <- function(s) grepl("required", s)
.typ <- function(s) sub(",.*$", "", s)

validate_entity <- function(df, spec) {
  errors <- character(0); warnings <- character(0)
  cols <- spec$cols
  miss <- setdiff(names(cols)[vapply(cols, .req, logical(1))], names(df))
  if (length(miss)) {
    errors <- c(errors, sprintf("missing required column(s): %s", paste(miss, collapse = ", ")))
    return(list(errors = errors, warnings = warnings, report = list(rows = nrow(df), rejected = NA)))
  }
  rej <- rep(FALSE, nrow(df))
  for (cn in intersect(names(cols), names(df))) {
    v <- as.character(df[[cn]]); t <- .typ(cols[[cn]])
    if (.req(cols[[cn]])) {
      bad <- is.na(v) | !nzchar(trimws(v))
      if (any(bad)) { errors <- c(errors, sprintf("%s: %d null/blank in required column", cn, sum(bad))); rej <- rej | bad }
    }
    if (t == "date") {
      bad <- nzchar(v) & !is_iso_date(v)
      if (any(bad)) { errors <- c(errors, sprintf("%s: %d non-ISO date(s)", cn, sum(bad))); rej <- rej | bad }
    }
    if (t == "integer") {
      bad <- nzchar(trimws(v)) & !grepl("^-?[0-9]+$", trimws(v))   # decimals/non-int rejected
      if (any(bad)) { errors <- c(errors, sprintf("%s: %d non-integer value(s)", cn, sum(bad))); rej <- rej | bad }
    }
  }
  for (cn in (spec$pos_int %||% character(0))) if (cn %in% names(df)) {
    iv <- suppressWarnings(as.integer(as.character(df[[cn]])))
    bad <- !is.na(iv) & iv <= 0L
    if (any(bad)) { errors <- c(errors, sprintf("%s: %d non-positive value(s)", cn, sum(bad))); rej <- rej | bad }
  }
  if (!is.null(spec$systems) && "code_system" %in% names(df)) {
    cs <- toupper(trimws(as.character(df$code_system)))
    bad <- !(cs %in% toupper(spec$systems))
    if (any(bad)) { errors <- c(errors, sprintf("code_system: %d value(s) not in {%s}", sum(bad), paste(spec$systems, collapse = ","))); rej <- rej | bad }
  }
  for (cn in names(spec$enums %||% list())) if (cn %in% names(df)) {  # enum domains
    bad <- !(tolower(trimws(as.character(df[[cn]]))) %in% tolower(spec$enums[[cn]]))
    if (any(bad)) { errors <- c(errors, sprintf("%s: %d value(s) not in {%s}", cn, sum(bad), paste(spec$enums[[cn]], collapse = ","))); rej <- rej | bad }
  }
  # Normalization. NDC: the STORED normalized_code must ITSELF be a canonical
  # 11-digit string (^[0-9]{11}$) - checked directly, NOT via normalize_ndc (which
  # strips separators), so a dashed or letter-bearing value is rejected, not kept.
  # Segment-aware 10->11 from raw is the adapter's job; raw is preserved. Non-NDC:
  # deterministic, so verify normalized == normalize(raw).
  rc <- spec$raw_col
  if (!is.null(rc) && all(c(rc, "normalized_code", "code_system") %in% names(df))) {
    cs <- toupper(trimws(as.character(df$code_system)))
    nc <- toupper(as.character(df$normalized_code)); has <- nzchar(as.character(df[[rc]]))
    badn <- cs == "NDC" & has & !is_ndc11(df$normalized_code)
    if (any(badn)) { errors <- c(errors, sprintf("normalized_code not a canonical 11-digit NDC (^[0-9]{11}$) in %d row(s)", sum(badn))); rej <- rej | badn }
    is_p <- cs != "NDC" & has
    if (any(is_p)) {
      expp <- normalize_proc(df[[rc]]); badp <- is_p & (is.na(expp) | toupper(expp) != nc)
      if (any(badp)) {
        i <- which(badp)[1]
        errors <- c(errors, sprintf("normalized_code != normalize(raw) in %d non-NDC row(s) (e.g. '%s' [%s] -> '%s', got '%s')",
                    sum(badp), df[[rc]][i], cs[i], expp[i], as.character(df$normalized_code)[i])); rej <- rej | badp
      }
    }
  }
  if (isTRUE(spec$span) && all(c("span_start", "span_end") %in% names(df))) {
    ss <- suppressWarnings(as.Date(as.character(df$span_start)))
    se <- suppressWarnings(as.Date(as.character(df$span_end)))
    bad <- !is.na(ss) & !is.na(se) & ss > se
    if (any(bad)) { errors <- c(errors, sprintf("span_start > span_end in %d row(s)", sum(bad))); rej <- rej | bad }
  }
  if (!is.null(spec$key) && all(spec$key %in% names(df))) {           # grain 1: source-level
    k <- do.call(paste, c(df[spec$key], sep = "\037"))
    dupd <- duplicated(k) | duplicated(k, fromLast = TRUE)
    if (any(dupd)) { errors <- c(errors, sprintf("key %s not unique (%d duplicate rows)", paste(spec$key, collapse = "+"), sum(dupd))); rej <- rej | dupd }
  }
  if (!is.null(spec$dedup_key) && all(spec$dedup_key %in% names(df))) {  # grain 2: algorithm input
    k <- do.call(paste, c(df[spec$dedup_key], sep = "\037"))
    dupd <- duplicated(k) | duplicated(k, fromLast = TRUE)
    if (any(dupd)) { errors <- c(errors, sprintf("dedup grain %s not unique post-dedup (%d row(s)); adapter must collapse to max day_supply, then min code (one row per patient+date+code)", paste(spec$dedup_key, collapse = "+"), sum(dupd))); rej <- rej | dupd }
  }
  list(errors = errors, warnings = warnings, report = list(rows = nrow(df), rejected = sum(rej)))
}

validate_canonical_dir <- function(dir, spec = CANONICAL_SPEC, require_present = TRUE) {
  out <- list(); ok <- TRUE
  for (nm in names(spec)) {
    p <- file.path(dir, spec[[nm]]$file)
    if (!file.exists(p)) {
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
    cat(sprintf("== %s (rows=%d, rejected=%s) ==\n", nm, r$report$rows, as.character(r$report$rejected)))
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
