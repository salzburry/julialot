# Runs the checks, rather than reading them.
#
# Everything else in this suite inspects the SQL as a string. Text cannot tell
# you that a WHERE can never be true, that a predicate was inverted, or that a
# check lost the half of its condition that made it bite - and a check that
# cannot fail reports "pass" on a real defect for ever.
#
# So each check here is executed twice: against a clean fixture, where it must
# count nothing, and against the same fixture with the defect it describes
# planted in it, where it must count that and name it.
#
# The compromise is real. The checks are written for Spark and are transpiled
# to DuckDB to run at all, so a statement Spark would reject can still run
# here. This is complementary to the text tests and to a run against the
# warehouse, not a replacement for either.

EXEC_COLS <- c(PATID = "VARCHAR", LOT_NUM = "INTEGER", LOT_START_DT = "DATE",
               LOT_START_TYPE = "VARCHAR", LOT_BASE_MEDS = "VARCHAR",
               LOT_MED_CNT = "INTEGER", LOT_BASE_DISCON_DT = "DATE",
               LOT_BASE_1ST_ADD_MED_DT = "DATE", LOT_BASE_END_DT = "DATE",
               LOT_BASE_END_REASON = "VARCHAR", LOT_BASE_LENGTH = "INTEGER",
               LOT_BASE_END_DT_CE_SENS = "DATE",
               LOT_BASE_END_REASON_CE_SENS = "VARCHAR",
               LOT_TX_AUTO_MAX_DT = "DATE")

.exec_json_row <- function(r, cols = EXEC_COLS) {
  paste0("{", paste(vapply(names(cols), function(n) {
    v <- r[[n]]
    if (is.null(v) || (length(v) == 1L && is.na(v))) sprintf('"%s":null', n)
    else if (is.numeric(v)) sprintf('"%s":%s', n, format(v, scientific = FALSE))
    else sprintf('"%s":"%s"', n, v)
  }, character(1)), collapse = ","), "}")
}

.exec_json_str <- function(s)
  gsub("\n", "\\\\n", gsub('"', '\\\\"', gsub("\\\\", "\\\\\\\\", s)))

# Returns one row per case: id, n_clean, n_planted, detail, error.
run_exec_cases <- function(checks, cases, clean, tables, params, root) {
  py <- file.path(root, "tests", "run_duckdb.py")
  if (!file.exists(py)) return(NULL)
  by_id <- stats::setNames(checks, vapply(checks, function(c_i) c_i$id, character(1)))
  built <- character(0)
  for (id in names(cases)) {
    c_i <- by_id[[id]]
    if (is.null(c_i)) next
    built <- c(built, sprintf('{"id":"%s","sql":"%s","planted":[%s]}', id,
      .exec_json_str(c_i$sql(tables, params)),
      paste(vapply(cases[[id]]$planted, .exec_json_row, character(1)), collapse = ",")))
  }
  spec <- sprintf('{"table":"LOT_LONG_FINAL","columns":{%s},"clean":[%s],"cases":[%s]}',
    paste(sprintf('"%s":"%s"', names(EXEC_COLS), EXEC_COLS), collapse = ","),
    paste(vapply(clean, .exec_json_row, character(1)), collapse = ","),
    paste(built, collapse = ","))
  f <- tempfile(fileext = ".json"); writeLines(spec, f)
  out <- suppressWarnings(system2("python3", c(shQuote(py), shQuote(f)),
                                  stdout = TRUE, stderr = TRUE))
  if (!length(out)) return(NULL)
  if (grepl("^SKIP", out[1])) return("skip")
  do.call(rbind, lapply(out, function(l) {
    p <- strsplit(l, "\t", fixed = TRUE)[[1]]
    length(p) <- 5L
    data.frame(id = p[1], n_clean = p[2], n_planted = p[3],
               detail = p[4], error = p[5], stringsAsFactors = FALSE)
  }))
}
