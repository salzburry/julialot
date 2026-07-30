# =============================================================================
# ie_codelists.R -- push the five cohort code lists into the session
# -----------------------------------------------------------------------------
# Spark executors cannot read the driver's filesystem, so each CSV is read in R
# and sent as a VALUES list.
#
# Two reasons this is here instead of using ../lib/db_utils.R's loader:
#   - that one calls glue() unqualified, and nothing here declares glue
#   - it iterates the whole codelist map, including the LOT and dashboard lists
#     this build does not use
#
# The views keep their logical names (cl_mm_dx and so on) because the step SQL
# references them by those names. They are temporary, so they live in the session
# only, and they stay views because they are small and read once each.
#
# All five are required. A missing or empty one is an error, not a warning: the
# step that reads it would otherwise produce an empty code list and silently
# drop every patient.
# =============================================================================

ie_load_codelists <- function(con, cfg) {
  if (!isTRUE(cfg$use_csv_codelists)) {
    message("USE_CSV_CODELISTS=FALSE; reading code lists from ", cfg$ref_schema)
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
      "CREATE OR REPLACE TEMPORARY VIEW ", tbl, " AS\nSELECT ",
      paste(cols, collapse = ", "), " FROM VALUES\n",
      paste(rows, collapse = ",\n"), "\nAS t(", paste(cols, collapse = ", "),
      ")"))
    log_msg("code list ", tbl, " <- ", file, " (",
            format(nrow(df), big.mark = ","), " rows)")
  }
  invisible(need)
}
