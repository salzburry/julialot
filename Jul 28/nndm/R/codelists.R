# CSV-only codelist loading, carried over from Jul 28/lot/R/codelists_lot.R.
# The CSV in cfg$codelist_dir is required; there is no embedded fallback.

# The four files this build reads. Anything else is a typo, not a code list.
# The files this build reads. cl_mma_codelist.csv drives the prior-MM-therapy
# scan; pregnancy.csv drives the pregnancy exclusion. Anything else is a typo,
# not a code list.
CODELIST_FILES <- c("cl_mma_codelist.csv", "pregnancy.csv")

load_codelist_csv <- function(csv_name, col_spec) {
  cfg <- nndm_config()
  if (!dir.exists(cfg$codelist_dir)) {
    stop(glue("CODELIST ERROR: codelist directory does not exist: {cfg$codelist_dir}"))
  }
  csv_path <- file.path(cfg$codelist_dir, csv_name)
  if (!file.exists(csv_path)) {
    stop(glue("CODELIST ERROR: required CSV file not found: {csv_path}"))
  }
  if (!csv_name %in% CODELIST_FILES)
    stop("CODELIST ERROR: ", csv_name, " is not one of the files this build is ",
         "defined on: ", paste(CODELIST_FILES, collapse = ", "), call. = FALSE)
  # The code lists live outside git, so the name alone does not say which
  # version a run used. Hash it, and hash it again after the read: if it were
  # swapped mid-read the logged hash would describe a file we did not load.
  md5 <- unname(tools::md5sum(csv_path))
  # NA when the file could not be opened for hashing. Left alone, the re-hash
  # below would compare NA with NA and pass - so the swap check would be
  # silently off - and 'NA' would be written to LOT_CODELIST_METADATA in the
  # shape of a hash. grepl is FALSE on NA, so this covers both.
  if (!grepl("^[0-9a-f]{32}$", md5))
    stop("CODELIST ERROR: could not hash ", csv_name, ", so this run cannot ",
         "record or re-check which version of it was read", call. = FALSE)
  # colClasses: without it R reads an NDC as a number and drops leading zeros.
  df <- read.csv(csv_path, stringsAsFactors = FALSE, na.strings = c("", "NA", "NaN"),
                 colClasses = "character")
  if (!identical(md5, unname(tools::md5sum(csv_path))))
    stop("CODELIST ERROR: ", csv_name, " changed while it was being read",
         call. = FALSE)
  log_msg("  CSV columns in ", csv_name, ": ", paste(names(df), collapse = ", "))
  missing <- setdiff(col_spec, names(df))
  if (length(missing) > 0) {
    stop(glue("CODELIST ERROR: CSV {csv_name} missing required columns: {paste(missing, collapse=', ')}. Found: {paste(names(df), collapse=', ')}"))
  }
  df <- df[, col_spec, drop = FALSE]
  if (nrow(df) == 0) {
    stop(glue("CODELIST ERROR: CSV {csv_name} has no data rows"))
  }
  esc <- function(x) {
    if (is.na(x) || is.null(x) || x == "") return("NULL")
    x <- gsub("'", "''", as.character(x))
    paste0("'", x, "'")
  }
  rows <- apply(df, 1, function(r) paste0("(", paste(vapply(r, esc, character(1)), collapse = ", "), ")"))
  sql <- paste0("SELECT * FROM (VALUES\n  ", paste(rows, collapse = ",\n  "), "\n) AS t(",
                paste(col_spec, collapse = ", "), ")")
  # Kept for LOT_CODELIST_METADATA, so the outputs say which version built them.
  seen <- getOption("nndm_codelist_md5", list())
  seen[[csv_name]] <- list(md5 = md5, n_rows = nrow(df))
  options(nndm_codelist_md5 = seen)
  log_msg("Loaded codelist from CSV: ", csv_path, " (", nrow(df), " rows, md5 ",
          md5, ")")
  paste0("(", sql, ") src")
}
