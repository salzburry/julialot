# CSV-only codelist loading. The CSV in cfg$codelist_dir is required; there is
# no embedded or ref-schema fallback.

# The four files this build reads. Anything else is a typo, not a code list.
CODELIST_FILES <- c("cl_mma_rollup.csv", "cl_mma_codelist.csv",
                    "permissible_subs.csv", "cl_sct_codelist.csv")

load_codelist_csv <- function(csv_name, col_spec) {
  cfg <- lot_config()
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
  log_msg("Loaded codelist from CSV: ", csv_path, " (", nrow(df), " rows, md5 ",
          if (is.na(md5)) "unavailable" else md5, ")")
  paste0("(", sql, ") src")
}
