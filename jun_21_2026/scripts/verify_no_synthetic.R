#!/usr/bin/env Rscript
# verify_no_synthetic.R
# Release gate (Increment 1 / CI): a production artifact is built from an
# ALLOWLIST (not "exclude tests/"), and no synthetic data may ship or persist
# in production. Blocks the release on any violation.
#
# Pure R; runnable locally. Usage:
#   Rscript verify_no_synthetic.R <bundle_manifest.txt> [data_dir ...]
# where bundle_manifest.txt lists, one per line, every repo-relative path the
# production artifact will contain.

# --- policy ---------------------------------------------------------------
PROD_ALLOWLIST <- c("R/", "studies/", "reference_data/approved/",
                    "orchestration/", "scripts/")   # runtime scripts only
PROD_DENYLIST  <- c("tests/", "fixtures/", "synthetic/")
# Reserved, obviously-fake PATID range for all synthetic patients.
SYNTHETIC_PATID_LO <- 9000000000
SYNTHETIC_PATID_HI <- 9999999999
SYNTHETIC_MARKER_COLS <- c("SYNTHETIC", "synthetic", "is_synthetic")

# --- checks ---------------------------------------------------------------

# Every shipped path must sit under an allowed prefix and under no denied one.
verify_bundle_allowlist <- function(paths) {
  norm <- gsub("\\\\", "/", paths)
  allowed <- vapply(norm, function(p)
    any(startsWith(p, PROD_ALLOWLIST)), logical(1))
  denied  <- vapply(norm, function(p)
    any(vapply(PROD_DENYLIST, function(d) grepl(d, p, fixed = TRUE), logical(1))),
    logical(1))
  bad <- norm[!allowed | denied]
  list(ok = length(bad) == 0, offending = bad)
}

# Scan a data file for synthetic PATIDs (reserved range) or a marker column.
# Scans the WHOLE file (no row cap), parses TSV with a tab separator, and FAILS
# CLOSED on an unreadable file - "no synthetic in production" is non-negotiable.
# NOTE: this is the file-level gate only; a separate Databricks-side query that
# no synthetic PATID persists in any PRODUCTION schema is still required (stub).
scan_file_for_synthetic <- function(path) {
  if (!grepl("\\.(csv|tsv)$", path, ignore.case = TRUE)) return(character(0))
  sep <- if (grepl("\\.tsv$", path, ignore.case = TRUE)) "\t" else ","
  df <- tryCatch(utils::read.csv(path, sep = sep, stringsAsFactors = FALSE,
                                 check.names = FALSE),
                 error = function(e) NULL)
  if (is.null(df)) return("UNREADABLE file (fail closed)")
  if (nrow(df) == 0) return(character(0))
  hits <- character(0)
  if (any(names(df) %in% SYNTHETIC_MARKER_COLS))
    hits <- c(hits, "SYNTHETIC marker column present")
  pid_col <- grep("^patid$|^patient_id$", names(df), ignore.case = TRUE, value = TRUE)
  for (pc in pid_col) {
    pid <- suppressWarnings(as.numeric(gsub("[^0-9]", "", as.character(df[[pc]]))))
    if (any(!is.na(pid) & pid >= SYNTHETIC_PATID_LO & pid <= SYNTHETIC_PATID_HI))
      hits <- c(hits, sprintf("synthetic-range PATID in column '%s'", pc))
  }
  unique(hits)
}

verify_no_synthetic_data <- function(paths) {
  offending <- list()
  for (p in paths) {
    if (!file.exists(p)) { offending[[p]] <- "MISSING listed file (fail closed)"; next }
    h <- scan_file_for_synthetic(p)
    if (length(h)) offending[[p]] <- h
  }
  list(ok = length(offending) == 0, offending = offending)
}

# --- entry ----------------------------------------------------------------
main <- function(args) {
  if (length(args) < 1) stop("usage: verify_no_synthetic.R <bundle_manifest.txt> [data_dir ...]")
  paths <- readLines(args[1], warn = FALSE)
  paths <- trimws(paths[nzchar(trimws(paths))])

  a <- verify_bundle_allowlist(paths)
  data_files <- paths[grepl("\\.(csv|tsv)$", paths, ignore.case = TRUE)]
  if (length(args) > 1)
    data_files <- c(data_files,
      list.files(args[-1], pattern = "\\.(csv|tsv)$", recursive = TRUE, full.names = TRUE))
  s <- verify_no_synthetic_data(unique(data_files))

  if (a$ok && s$ok) { cat("PASS: bundle is allowlist-clean and synthetic-free.\n"); quit(status = 0) }
  if (!a$ok) {
    cat("FAIL: paths outside the production allowlist / inside the denylist:\n")
    for (p in a$offending) cat("  ", p, "\n")
  }
  if (!s$ok) {
    cat("FAIL: synthetic data found in to-be-shipped files:\n")
    for (p in names(s$offending)) cat("  ", p, ": ", paste(s$offending[[p]], collapse = "; "), "\n")
  }
  quit(status = 1)
}

if (sys.nframe() == 0 && !interactive()) main(commandArgs(trailingOnly = TRUE))
