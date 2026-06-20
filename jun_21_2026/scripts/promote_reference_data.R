#!/usr/bin/env Rscript
# promote_reference_data.R
# Reference-data promotion (Increment 2): intake -> validated -> approved.
# Monthly updates promote a COMPLETE IMMUTABLE SNAPSHOT (never mutate an
# approved file). Blocks on any validation error; requires recorded clinical +
# engineering approval. SKELETON (the approval gate + impact estimate are stubs).
#
# Usage:
#   Rscript promote_reference_data.R <intake_csv> <codelist_id> <version> \
#           --clinical <name> --engineering <name>

suppressWarnings(source(file.path(dirname(sys.frame(1)$ofile %||% "."),
                                  "validate_reference_data.R")))
`%||%` <- function(a, b) if (is.null(a) || (length(a) == 1 && is.na(a))) b else a

REFDATA_ROOT <- "reference_data"   # intake/ validated/ approved/ manifest.yml

content_hash <- function(path) {
  # Stable content hash of the canonicalized rows (sorted, normalized) -- not a
  # raw file hash, so reordering/whitespace does not change identity.
  if (requireNamespace("digest", quietly = TRUE)) {
    df <- utils::read.csv(path, stringsAsFactors = FALSE, check.names = FALSE,
                          comment.char = "#")
    key <- do.call(paste, c(lapply(df[order(names(df))], as.character), sep = "\037"))
    digest::digest(sort(key), algo = "sha256")
  } else paste0("sha256-unavailable-", as.integer(file.info(path)$size))
}

approved_diff <- function(intake_csv, codelist_id) {
  prior <- list.files(file.path(REFDATA_ROOT, "approved"),
                      pattern = paste0("^", codelist_id, "@.*\\.csv$"), full.names = TRUE)
  if (!length(prior)) return("(no prior approved version)")
  # TODO: human-readable added/removed/reclassified rows vs the latest prior.
  sprintf("diff vs %s: <added/removed/reclassified counts> (stub)", basename(tail(prior, 1)))
}

impact_estimate <- function(intake_csv, codelist_id) {
  # TODO (Databricks, non-prod): affected-patient / affected-claim estimate of
  # applying the new codelist vs the current approved one. Goes in the PR.
  "affected patients/claims: <run on non-prod Databricks> (stub)"
}

promote <- function(intake_csv, codelist_id, version, clinical, engineering,
                    manifest_entry = list(id = codelist_id, row_count_min = 1)) {
  stopifnot(file.exists(intake_csv), nzchar(version))
  df <- utils::read.csv(intake_csv, stringsAsFactors = FALSE, check.names = FALSE,
                        comment.char = "#")
  res <- validate_reference_data(df, manifest_entry)
  if (length(res$warnings)) for (w in res$warnings) cat("WARN: ", w, "\n")
  if (length(res$errors)) {
    for (e in res$errors) cat("ERROR:", e, "\n")
    cat("BLOCKED: validation errors; not promoted.\n"); quit(status = 1)
  }
  if (is.null(clinical) || is.null(engineering)) {
    cat("BLOCKED: clinical and engineering approval are both required.\n"); quit(status = 1)
  }
  hash <- content_hash(intake_csv)
  out  <- file.path(REFDATA_ROOT, "approved", sprintf("%s@%s.csv", codelist_id, version))
  cat("DIFF:  ", approved_diff(intake_csv, codelist_id), "\n")
  cat("IMPACT:", impact_estimate(intake_csv, codelist_id), "\n")
  cat(sprintf("PROMOTE: %s -> %s\n  version=%s hash=%s clinical=%s engineering=%s\n",
              intake_csv, out, version, hash, clinical, engineering))
  # TODO: write immutable snapshot `out` (refuse if it already exists), append a
  # manifest.yml entry {id, version, hash, code_system_version, effective dates,
  # row_count, clinical, engineering, approval_date, superseded_version}, and a
  # lock-file pin {version, hash}. Approved files are never overwritten.
  invisible(list(out = out, version = version, hash = hash))
}

if (sys.nframe() == 0 && !interactive())
  cat("promote_reference_data.R: skeleton loaded. Wire snapshot write +",
      "manifest append + Databricks impact estimate.\n")
