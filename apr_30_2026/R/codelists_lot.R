# ============================================================
# codelists_lot.R — CSV-only codelist loading (no embedded fallbacks)
# ============================================================
# Extracted from lot_program.R during modularization.
# Loader policy:
#   Priority 1: CSV from codelist_dir (REQUIRED — fail if missing).
#   No embedded fallback. No ref schema fallback.
# Requires: cfg (from config_lot.R), log_msg (from db_utils_lot.R)
# ============================================================

load_codelist_csv <- function(csv_name, col_spec) {
  if (!dir.exists(cfg$codelist_dir)) {
    stop(glue("CODELIST ERROR: codelist directory does not exist: {cfg$codelist_dir}"))
  }
  csv_path <- file.path(cfg$codelist_dir, csv_name)
  if (!file.exists(csv_path)) {
    stop(glue("CODELIST ERROR: required CSV file not found: {csv_path}"))
  }
  df <- read.csv(csv_path, stringsAsFactors = FALSE, na.strings = c("", "NA", "NaN"))
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
  log_msg("Loaded codelist from CSV: ", csv_path, " (", nrow(df), " rows)")
  paste0("(", sql, ") src")
}
