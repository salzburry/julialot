#!/usr/bin/env Rscript
# validate_manifest.R
# RUNTIME checks for a run manifest that JSON Schema cannot express: secret
# REDACTION (no secret-like key may carry a value anywhere - especially inside the
# free-form config.resolved object the schema cannot enumerate) and value-level
# cross-rules (a failed/mismatched run must not be published; reference data must
# be approved). Pair with contracts/manifest.schema.json, which owns STRUCTURE.
# Pure R (+ lib.R); runnable.

if (!exists(".lotlib")) source(local({ .find_lib <- function() {
  fa <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(fa)) { p <- file.path(dirname(sub("^--file=", "", fa[1])), "lib.R"); if (file.exists(p)) return(p) }
  for (p in c("scripts/lib.R", "lib.R")) if (file.exists(p)) return(p); stop("lib.R not found") }; .find_lib() }))

# Key names that must never carry an inline value in a manifest (references only).
SECRET_KEY_RX <- "(?i)(password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key|client[_-]?secret|credential|private[_-]?key|conn(ection)?[_-]?string)"

# Recursively find every leaf whose KEY looks secret-like and whose value is a
# non-empty scalar (a redaction leak). `secrets[].reference` is allowed (it is a
# reference, not a value) so the top-level `secrets` array is skipped.
.scan_secrets <- function(x, path = "") {
  hits <- character(0)
  if (is.list(x)) {
    nm <- names(x); if (is.null(nm)) nm <- rep("", length(x))
    for (i in seq_along(x)) {
      key <- nm[i]; child <- x[[i]]
      cp <- if (nzchar(path)) paste0(path, ".", key) else key
      if (identical(cp, "secrets")) next                 # references-only array, by contract
      if (nzchar(key) && grepl(SECRET_KEY_RX, key, perl = TRUE) &&
          !is.list(child) && length(child) == 1 && !is.na(child) &&
          nzchar(trimws(as.character(child))))
        hits <- c(hits, cp)
      hits <- c(hits, .scan_secrets(child, cp))
    }
  }
  hits
}

# ONE fail-closed gate = STRUCTURE (schema_conformance against manifest.schema.json:
# required fields, closed objects, and - critically - closed secrets[] items so a
# value field there is rejected) + RUNTIME value checks JSON Schema cannot express.
validate_manifest <- function(m, schema_path = "contracts/manifest.schema.json") {
  errors <- character(0); warnings <- character(0)
  # 0. STRUCTURE: required run_id/git/version_axes/source/environment/outputs/... and
  #    closed secrets[] (this is what closes the secrets-subtree redaction bypass).
  if (file.exists(schema_path)) {
    s <- schema_conformance(m, schema_path)
    if (length(s)) errors <- c(errors, paste0("schema: ", s))
  }
  # 1. redaction (the security promise): no secret-like key carries a value
  leaked <- .scan_secrets(m)
  if (length(leaked))
    errors <- c(errors, sprintf("secret-like value present (must be redacted, references only): %s",
                paste(leaked, collapse = ", ")))
  rs <- m$run_status %||% ""; ps <- m$publication$status %||% ""
  # 2. a failed run must never be published
  if (rs == "failed" && ps == "published")
    errors <- c(errors, "run_status=failed but publication.status=published")
  # 3. a comparison MISMATCH must never be published
  if (identical(m$comparison$result %||% "", "mismatch") && ps == "published")
    errors <- c(errors, "comparison.result=mismatch but publication.status=published")
  # 4. a non-primary-use or degraded-gate cohort must never reach the published
  #    alias (fail-closed cohort-quality policy).
  if (ps == "published" && isFALSE(m$quality$cohort_valid_for_primary_use))
    errors <- c(errors, "publication.status=published but quality.cohort_valid_for_primary_use=false")
  deg <- m$quality$degraded_gates %||% list()
  if (ps == "published" && length(deg) > 0)
    errors <- c(errors, sprintf("publication.status=published but degraded cohort gate(s) present: %s",
                paste(unlist(deg), collapse = ", ")))
  # 5. a successful run must emit outputs
  if (rs == "success" && length(m$outputs %||% list()) == 0)
    errors <- c(errors, "run_status=success but no outputs recorded")
  # 6. reproducibility: reference_data present and every entry approved
  rd <- m$reference_data %||% list()
  if (!length(rd)) errors <- c(errors, "reference_data is empty (reproducibility/provenance)")
  for (r in rd) if (!identical(r$approval_status %||% "", "approved"))
    errors <- c(errors, sprintf("reference_data '%s' is not approved", r$id %||% "?"))
  list(errors = errors, warnings = warnings)
}

report_manifest <- function(res, id = "manifest") {
  cat(sprintf("== %s ==\n", id))
  for (w in res$warnings) cat("  WARN: ", w, "\n")
  for (e in res$errors)  cat("  ERROR:", e, "\n")
  cat(if (length(res$errors)) "  -> INVALID\n" else "  -> OK\n")
  invisible(length(res$errors) == 0)
}

if (sys.nframe() == 0 && !interactive()) {
  a <- commandArgs(trailingOnly = TRUE)
  if (length(a) >= 1 && file.exists(a[1])) {
    ok <- report_manifest(validate_manifest(read_json_file(a[1])), a[1])
    quit(status = if (ok) 0L else 1L)
  }
  # self-test
  m <- list(run_status = "success", publication = list(status = "published"),
            reference_data = list(list(id = "steroid", approval_status = "approved")),
            config = list(resolved = list(database = "prod", max_lot = 5, db_password = "hunter2")))
  report_manifest(validate_manifest(m), "self-test (expects a redaction error)")
}
