# ============================================================
# load_inputs.R — optional CSV-driven input overrides
# ============================================================
# Lets you change/reset pipeline inputs by editing one file
# (pipeline_inputs.csv) instead of juggling Sys.setenv() calls or
# shell exports. The CSV has columns: name,value,description.
#
# Rules:
#   - A non-empty `value` is applied via Sys.setenv(name = value),
#     so the file OVERRIDES whatever was in the environment (this is
#     what makes it a "reset" file).
#   - A blank `value` is skipped (that input keeps its default /
#     existing value).
#   - Rows whose `name` is blank or starts with '#' are ignored
#     (comment rows).
#   - DATABRICKS_PWD is NEVER taken from the file — secrets stay in
#     the environment / Domino secret store.
#
# Must be called BEFORE config_lot.R / config_prompts.R are sourced
# and before run_pipeline.R reads env vars, since those read
# Sys.getenv() at evaluation time.
# ============================================================

load_pipeline_inputs <- function(dirs, filename = "pipeline_inputs.csv") {
  for (d in dirs) {
    f <- file.path(d, filename)
    if (!file.exists(f)) next
    df <- tryCatch(
      utils::read.csv(f, stringsAsFactors = FALSE,
                      na.strings = c("", "NA", "NaN"),
                      colClasses = "character"),
      error = function(e) {
        message("[load_inputs] could not read ", f, ": ",
                conditionMessage(e))
        NULL
      })
    if (is.null(df)) return(invisible(FALSE))
    if (!all(c("name", "value") %in% names(df))) {
      message("[load_inputs] ", f,
              " is missing required 'name' and/or 'value' columns; ignored.")
      return(invisible(FALSE))
    }
    n_set <- 0L
    for (i in seq_len(nrow(df))) {
      nm <- trimws(as.character(df$name[i]))
      vl <- df$value[i]
      if (is.na(nm) || nm == "" || startsWith(nm, "#")) next
      if (toupper(nm) == "DATABRICKS_PWD") {
        message("[load_inputs] ignoring DATABRICKS_PWD from file ",
                "(secrets stay in the environment).")
        next
      }
      if (is.na(vl) || trimws(as.character(vl)) == "") next
      do.call(Sys.setenv, setNames(list(as.character(vl)), nm))
      n_set <- n_set + 1L
    }
    message("[load_inputs] applied ", n_set, " input(s) from ", f)
    return(invisible(TRUE))
  }
  invisible(FALSE)
}
