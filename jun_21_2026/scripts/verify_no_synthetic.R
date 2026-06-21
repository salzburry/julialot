#!/usr/bin/env Rscript
# verify_no_synthetic.R
# Release gate (Increment 1 / CI): a production artifact is built from an
# ALLOWLIST (not "exclude tests/"), and no synthetic data may ship or persist
# in production. Blocks the release on any violation.
#
# Pure R; runnable locally. Usage:
#   Rscript verify_no_synthetic.R <bundle_manifest.txt> [--bundle <dir>] [data_dir ...]
# where bundle_manifest.txt lists, one per line, every repo-relative path the
# production artifact will contain. With --bundle, the manifest is RECONCILED
# against the actual bundle directory so an unlisted file cannot escape the scan.
#
# Defenses: allowlist + denylist + `..`-traversal rejection on every path;
# manifest-vs-bundle reconciliation; whole-file CSV/TSV synthetic scan (reserved
# PATID range + marker column), fail-closed on unreadable/missing files.
# Known limitations (documented, not silently ignored): the content scan covers
# CSV/TSV only - binary data (e.g. Parquet) is guarded by the allowlist + the
# reserved-PATID convention, and the authoritative "no synthetic PATID persists in
# any PRODUCTION schema" check is a Databricks-side query (still a stub).

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
# A `..` segment is rejected outright: a prefix check on `R/../tests/x.csv` would
# pass the allowlist while actually pointing into a denied tree.
verify_bundle_allowlist <- function(paths) {
  norm <- gsub("\\\\", "/", paths)
  traversal <- grepl("(^|/)\\.\\.(/|$)", norm)
  allowed <- vapply(norm, function(p)
    any(startsWith(p, PROD_ALLOWLIST)), logical(1))
  denied  <- vapply(norm, function(p)
    any(vapply(PROD_DENYLIST, function(d) grepl(d, p, fixed = TRUE), logical(1))),
    logical(1))
  bad <- norm[!allowed | denied | traversal]
  list(ok = length(bad) == 0, offending = bad)
}

# Reconcile the DECLARED manifest against the ACTUAL bundle contents. A file present
# in the bundle but absent from the manifest would escape the per-file synthetic
# scan; a manifested file absent from the bundle is a broken manifest. Both fail
# closed - the scan must not trust an unverified manifest.
verify_manifest_matches_bundle <- function(manifest_paths, bundle_dir) {
  mp <- gsub("\\\\", "/", trimws(manifest_paths)); mp <- mp[nzchar(mp)]
  actual <- gsub("\\\\", "/", list.files(bundle_dir, recursive = TRUE))
  missing_from_bundle <- setdiff(mp, actual)
  unlisted_in_manifest <- setdiff(actual, mp)
  list(ok = length(missing_from_bundle) == 0 && length(unlisted_in_manifest) == 0,
       missing_from_bundle = missing_from_bundle, unlisted_in_manifest = unlisted_in_manifest)
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

# The set of data files to synthetic-scan. With a bundle dir, the manifest paths
# are bundle-relative, so they MUST be resolved against it (otherwise the scan
# reads a clean repo file at cwd while the bundled file may carry synthetic rows).
bundle_data_files <- function(manifest_paths, bundle_dir = NA_character_, extra_dirs = character(0)) {
  d <- manifest_paths[grepl("\\.(csv|tsv)$", manifest_paths, ignore.case = TRUE)]
  if (!is.na(bundle_dir)) d <- file.path(bundle_dir, d)
  if (length(extra_dirs))
    d <- c(d, list.files(extra_dirs, pattern = "\\.(csv|tsv)$", recursive = TRUE, full.names = TRUE))
  unique(d)
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
  if (length(args) < 1)
    stop("usage: verify_no_synthetic.R <bundle_manifest.txt> [--bundle <dir>] [data_dir ...]")
  bi <- which(args == "--bundle")
  bundle_dir <- if (length(bi)) args[bi + 1L] else NA_character_
  rest <- args[setdiff(seq_along(args), c(bi, bi + 1L))]
  paths <- readLines(rest[1], warn = FALSE)
  paths <- trimws(paths[nzchar(trimws(paths))])

  a <- verify_bundle_allowlist(paths)
  recon <- if (!is.na(bundle_dir)) verify_manifest_matches_bundle(paths, bundle_dir) else list(ok = TRUE)
  data_files <- bundle_data_files(paths, bundle_dir, if (length(rest) > 1) rest[-1] else character(0))
  s <- verify_no_synthetic_data(data_files)

  if (a$ok && s$ok && recon$ok) {
    cat("PASS: bundle is allowlist-clean, manifest-reconciled, and synthetic-free.\n"); quit(status = 0) }
  if (!a$ok) {
    cat("FAIL: paths outside the production allowlist / inside the denylist / with traversal:\n")
    for (p in a$offending) cat("  ", p, "\n")
  }
  if (!isTRUE(recon$ok)) {
    cat("FAIL: manifest does not match bundle contents:\n")
    for (p in recon$missing_from_bundle) cat("    missing from bundle:", p, "\n")
    for (p in recon$unlisted_in_manifest) cat("    unlisted in manifest (would escape scan):", p, "\n")
  }
  if (!s$ok) {
    cat("FAIL: synthetic data found in to-be-shipped files:\n")
    for (p in names(s$offending)) cat("  ", p, ": ", paste(s$offending[[p]], collapse = "; "), "\n")
  }
  quit(status = 1)
}

if (sys.nframe() == 0 && !interactive()) main(commandArgs(trailingOnly = TRUE))
