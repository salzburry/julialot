# =============================================================================
# ie_codelists.R -- push the five cohort code lists into the output schema
# -----------------------------------------------------------------------------
# Spark executors cannot read the driver's filesystem, so each CSV is read in R
# and sent as a VALUES list.
#
# They are written as prefixed TABLES, not session temp views, so they survive a
# reconnect mid-build. They are intermediates and get dropped after a clean run.
#
# All five are required. A missing or empty file is an error: every flag is built
# even when its gate is off, so an empty list would quietly change one.
# =============================================================================

ie_load_codelists <- function(con, cfg, h = ie_names(cfg)) {
  if (!isTRUE(cfg$use_csv_codelists)) {
    log_msg("USE_CSV_CODELISTS=FALSE; reading code lists from ", cfg$ref_schema)
    return(invisible(NULL))
  }
  need <- c(cfg$cl_mm_dx, cfg$cl_mm_therapy, cfg$cl_preg, cfg$cl_clintrial,
            cfg$cl_other_malig)
  for (tbl in need) {
    file <- cfg$codelist_csv_map[[tbl]]
    if (is.null(file))
      stop("no CSV mapped for code list '", tbl, "'.", call. = FALSE)
    path <- file.path(cfg$codelist_dir, file)
    if (!file.exists(path))
      stop("code list ", path, " is missing. CODELIST_DIR is ",
           cfg$codelist_dir, ".", call. = FALSE)

    df <- utils::read.csv(path, stringsAsFactors = FALSE, colClasses = "character")
    df[] <- lapply(df, trimws)
    if (!nrow(df))
      stop("code list ", path, " has no rows.", call. = FALSE)

    cols <- names(df)
    lit <- function(v) if (is.na(v) || !nzchar(v)) "NULL" else
      paste0("'", gsub("'", "''", v), "'")
    rows <- vapply(seq_len(nrow(df)), function(i)
      paste0("(", paste(vapply(cols, function(c) lit(df[[c]][i]), character(1)),
                        collapse = ","), ")"), character(1))
    DBI::dbExecute(con, paste0(
      "CREATE OR REPLACE TABLE ", h$work(tbl), " AS\nSELECT ",
      paste(cols, collapse = ", "), " FROM VALUES\n",
      paste(rows, collapse = ",\n"), "\nAS t(", paste(cols, collapse = ", "),
      ")"))
    log_msg("code list ", h$work(tbl), " <- ", file, " (",
            format(nrow(df), big.mark = ","), " rows)")
  }
  invisible(need)
}
