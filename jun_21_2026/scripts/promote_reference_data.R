#!/usr/bin/env Rscript
# promote_reference_data.R
# Reference-data promotion (Increment 2): intake -> validated -> approved.
# Monthly updates promote a COMPLETE IMMUTABLE SNAPSHOT (never mutate an
# approved file). Blocks on any validation error and requires recorded clinical
# + engineering approval. Runnable as a dry-run; only the snapshot WRITE +
# Databricks impact estimate are stubs (they touch the governed store / warehouse).
#
# Usage:
#   Rscript promote_reference_data.R <intake_csv> <codelist_id> <version> \
#           --clinical <name> --engineering <name>

.srcguard <- function(file, sentinel) {
  if (exists(sentinel)) return(invisible())
  fa <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  cand <- c(if (length(fa)) file.path(dirname(sub("^--file=", "", fa[1])), file),
            file.path("scripts", file), file)
  cand <- cand[file.exists(cand)]
  if (length(cand)) source(cand[1]) else stop(file, " not found")
}
.srcguard("lib.R", ".lotlib")
.srcguard("validate_reference_data.R", "validate_reference_data")

REFDATA_ROOT <- "reference_data"   # intake/ validated/ approved/ manifest.yml

approved_diff <- function(intake_csv, codelist_id) {
  prior <- list.files(file.path(REFDATA_ROOT, "approved"),
                      pattern = paste0("^", codelist_id, "@.*\\.csv$"), full.names = TRUE)
  if (!length(prior)) return("(no prior approved version)")
  sprintf("diff vs %s: <added/removed/reclassified counts> (stub)", basename(tail(prior, 1)))
}
impact_estimate <- function(intake_csv, codelist_id) {
  # Databricks (non-prod): affected-patient/claim estimate vs current approved.
  "affected patients/claims: <run on non-prod Databricks> (stub)"
}

# Returns a plan list (does not quit); the CLI/report decides exit status.
promote <- function(intake_csv, codelist_id, version, clinical = NULL, engineering = NULL,
                    manifest_entry = list(id = codelist_id, row_count_min = 1L),
                    write = FALSE) {
  if (!file.exists(intake_csv)) return(list(promoted = FALSE, reason = "intake file missing"))
  if (is.null(version) || !nzchar(version)) return(list(promoted = FALSE, reason = "version required"))
  df <- utils::read.csv(intake_csv, stringsAsFactors = FALSE, check.names = FALSE, comment.char = "#")
  res <- validate_reference_data(df, manifest_entry)
  if (length(res$errors))
    return(list(promoted = FALSE, reason = "validation errors", errors = res$errors, warnings = res$warnings))
  if (is.null(clinical) || is.null(engineering))
    return(list(promoted = FALSE, reason = "clinical and engineering approval both required",
                warnings = res$warnings))
  plan <- list(promoted = TRUE,
               out = file.path(REFDATA_ROOT, "approved", sprintf("%s@%s.csv", codelist_id, version)),
               version = version, hash = content_hash(df),
               clinical = clinical, engineering = engineering, warnings = res$warnings,
               diff = approved_diff(intake_csv, codelist_id),
               impact = impact_estimate(intake_csv, codelist_id))
  if (write) plan$written <- FALSE   # snapshot write is governed-store side (stub)
  plan
}

report_promote <- function(r) {
  for (w in r$warnings %||% character(0)) cat("WARN: ", w, "\n")
  if (!isTRUE(r$promoted)) {
    cat("BLOCKED:", r$reason, "\n")
    for (e in r$errors %||% character(0)) cat("  ERROR:", e, "\n")
    return(invisible(FALSE))
  }
  cat("DIFF:  ", r$diff, "\n"); cat("IMPACT:", r$impact, "\n")
  cat(sprintf("PROMOTE (dry-run; snapshot write stubbed): %s\n  version=%s hash=%s clinical=%s engineering=%s\n",
              r$out, r$version, substr(r$hash, 1, 16), r$clinical, r$engineering))
  invisible(TRUE)
}

.parse_args <- function(a) {
  flags <- list(); pos <- character(0); i <- 1L
  while (i <= length(a)) {
    if (grepl("^--", a[i])) { flags[[sub("^--", "", a[i])]] <- a[i + 1L]; i <- i + 2L }
    else { pos <- c(pos, a[i]); i <- i + 1L }
  }
  list(pos = pos, flags = flags)
}

if (sys.nframe() == 0 && !interactive()) {
  a <- .parse_args(commandArgs(trailingOnly = TRUE))
  if (length(a$pos) < 3) {
    cat("usage: promote_reference_data.R <intake_csv> <codelist_id> <version>",
        "--clinical <name> --engineering <name>\n"); quit(status = 2)
  }
  r <- promote(a$pos[1], a$pos[2], a$pos[3], a$flags$clinical, a$flags$engineering)
  report_promote(r)
  quit(status = if (isTRUE(r$promoted)) 0L else 1L)
}
