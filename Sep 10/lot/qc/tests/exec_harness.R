# Runs the checks, rather than reading them.
#
# Everything else in this suite inspects the SQL as a string, which cannot tell
# that a WHERE can never be true, that a predicate was inverted, or that a
# check lost the half of its condition that made it bite.
#
# So each check here is executed twice: against a clean fixture, where it must
# count nothing, and against the same fixture carrying the defect it describes,
# where it must count that and name it.
#
# The checks are written for Spark and transpiled to DuckDB to run at all, so a
# statement Spark would reject can still run here. This complements the text
# tests and a run against the warehouse rather than replacing either.

# The tables a check may read, with the columns the catalogue actually uses.
# Named for the key the runner hands in (`final`, `long`, ...) rather than for
# the warehouse table, because that is what a check's `needs` names.
EXEC_SCHEMA <- list(
  final = list(table = "LOT_LONG_FINAL", columns = c(
    PATID = "VARCHAR", LOT_NUM = "INTEGER", LOT_START_DT = "DATE",
    LOT_START_TYPE = "VARCHAR", LOT_BASE_MEDS = "VARCHAR",
    LOT_MED_CNT = "INTEGER", LOT_BASE_DISCON_DT = "DATE",
    LOT_BASE_1ST_ADD_MED = "VARCHAR", LOT_BASE_1ST_ADD_MED_DT = "DATE",
    LOT_BASE_END_DT = "DATE", LOT_BASE_END_REASON = "VARCHAR",
    LOT_BASE_LENGTH = "INTEGER", LOT_BASE_END_DT_CE_SENS = "DATE",
    LOT_BASE_END_REASON_CE_SENS = "VARCHAR", LOT_TX_AUTO_MAX_DT = "DATE")),

  long = list(table = "LOT_LONG", columns = c(
    PATID = "VARCHAR", LOT_NUM = "INTEGER", LOT_START_DT = "DATE",
    LOT_START_TYPE = "VARCHAR", LOT_BASE_END_DT = "DATE",
    LOT_TX_AUTO_DT_1 = "DATE", LOT_TX_AUTO_DT_2 = "DATE",
    LOT_TX_AUTO_TAND_FLG = "INTEGER")),

  map = list(table = "MAP_STACKED", columns = c(
    PATID = "VARCHAR", MAP_MED_ABBR = "VARCHAR", MAP_MED_TYPE = "VARCHAR",
    MAP_MED_CLASS = "VARCHAR", MAP_START_DT = "DATE", MAP_END_DT = "DATE",
    MAP_DISCON_FLG = "INTEGER", MAP_MED_RUNOUT_DT = "DATE",
    MAP_RX_RUNOUT_DT = "DATE", ELIGIBLE_END = "DATE")),

  sct = list(table = "LOT1_SCT", columns = c(
    PATID = "VARCHAR", LOT1_START_DT = "DATE", LOT1_TX_ENDDATE = "DATE",
    LOT1_SCT_AUTO_SING_FLG = "INTEGER", LOT1_SCT_AUTO_TAND_FLG = "INTEGER")),

  auto = list(table = "TX_AUTO_DATES", columns = c(
    PATID = "VARCHAR", TX_DT = "DATE")),

  allo = list(table = "TX_ALLO_CART_DATES", columns = c(
    PATID = "VARCHAR", TX_DT = "DATE", SCT_TYPE = "VARCHAR")),

  attrition = list(table = "LOT_ATTRITION", columns = c(
    RUN_ID = "VARCHAR", STEP_NUM = "INTEGER", KIND = "VARCHAR",
    STEP = "VARCHAR", N_PATIENTS = "BIGINT", N_LINES = "BIGINT",
    PCT_OF_START = "DOUBLE", PCT_OF_PREV = "DOUBLE")),

  meta = list(table = "LOT_RUN_METADATA", columns = c(
    RUN_ID = "VARCHAR", RUN_TIMESTAMP = "VARCHAR",
    LOT_LONG_BY_LINE = "VARCHAR", N_LOT_FINAL_ROWS = "BIGINT",
    N_LOT_FINAL_PATIENTS = "BIGINT", CODE_MD5 = "VARCHAR",
    CONTRACT_SETTINGS = "VARCHAR", STUDY_START = "VARCHAR",
    STUDY_END = "VARCHAR", LINE_CRITERIA_APPLIED = "VARCHAR")),

  cohort = list(table = "LOT_PATIENT_INPUT", columns = c(
    PATID = "VARCHAR", INDEX_DATE = "DATE", ENDDATE = "DATE",
    ENDDATE_CE = "DATE", DEATH_DT = "DATE")),

  # Lower case, because 01_codelists.R writes them that way and C1 joins on
  # them by name.
  subs = list(table = "PERMISSIBLE_SUBS", columns = c(
    original_med = "VARCHAR", substitute_med = "VARCHAR"))
)

EXEC_TABLES <- stats::setNames(
  lapply(EXEC_SCHEMA, function(x) x$table), names(EXEC_SCHEMA))

.exec_json_val <- function(n, v) {
  if (is.null(v) || (length(v) == 1L && is.na(v))) sprintf('"%s":null', n)
  else if (is.numeric(v)) sprintf('"%s":%s', n, format(v, scientific = FALSE))
  else sprintf('"%s":"%s"', n, v)
}

.exec_json_rows <- function(rows, cols) {
  paste(vapply(rows, function(r)
    paste0("{", paste(vapply(names(cols), function(n) .exec_json_val(n, r[[n]]),
                             character(1)), collapse = ","), "}"),
    character(1)), collapse = ",")
}

.exec_json_data <- function(data) {
  keys <- intersect(names(EXEC_SCHEMA), names(data))
  paste(vapply(keys, function(k)
    sprintf('"%s":[%s]', EXEC_SCHEMA[[k]]$table,
            .exec_json_rows(data[[k]], EXEC_SCHEMA[[k]]$columns)),
    character(1)), collapse = ",")
}

.exec_json_str <- function(s)
  gsub("\n", "\\\\n", gsub('"', '\\\\"', gsub("\\\\", "\\\\\\\\", s)))

# Returns one row per case: id, n_clean, n_planted, detail, error.
run_exec_cases <- function(checks, cases, clean, params, root) {
  py <- file.path(root, "tests", "run_duckdb.py")
  if (!file.exists(py)) return(NULL)
  by_id <- stats::setNames(checks, vapply(checks, function(c_i) c_i$id, character(1)))
  built <- character(0)
  for (id in names(cases)) {
    c_i <- by_id[[id]]
    if (is.null(c_i)) next
    built <- c(built, sprintf('{"id":"%s","sql":"%s","planted":{%s}}', id,
      .exec_json_str(c_i$sql(EXEC_TABLES, params)),
      .exec_json_data(cases[[id]]$planted)))
  }
  schema <- paste(vapply(names(EXEC_SCHEMA), function(k) {
    cols <- EXEC_SCHEMA[[k]]$columns
    sprintf('"%s":{"columns":{%s}}', EXEC_SCHEMA[[k]]$table,
            paste(sprintf('"%s":"%s"', names(cols), cols), collapse = ","))
  }, character(1)), collapse = ",")
  spec <- sprintf('{"tables":{%s},"clean":{%s},"cases":[%s]}',
                  schema, .exec_json_data(clean), paste(built, collapse = ","))
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
