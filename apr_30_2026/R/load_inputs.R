# ============================================================
# load_inputs.R — optional CSV-driven input defaults
# ============================================================
# Lets you change/reset pipeline inputs by editing one file
# (pipeline_inputs.csv) instead of juggling Sys.setenv() calls or
# shell exports. The CSV has columns: name,value,description.
#
# Precedence: THE ENVIRONMENT ALWAYS WINS. A CSV value is applied only
# when that variable is currently UNSET/empty in the environment, so
# the CSV behaves as an editable defaults file and never silently
# overrides a shell export, a Domino-injected value, or an inline
# command like:
#   SKIP_COHORT=TRUE FORCE_RERUN=TRUE Rscript run_pipeline.R
#
# Rules:
#   - Variable already set in the env (non-empty) -> CSV row ignored.
#   - Variable unset + non-empty CSV `value`      -> Sys.setenv applied.
#   - Blank CSV `value`                           -> skipped (use the
#     code's own default / fallback chain).
#   - Rows whose `name` is blank or starts with '#' are comment rows.
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
    n_set <- 0L; n_kept_env <- 0L
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
      # Environment wins: only fill when the variable is unset/empty.
      if (nzchar(Sys.getenv(nm, unset = ""))) { n_kept_env <- n_kept_env + 1L; next }
      do.call(Sys.setenv, setNames(list(as.character(vl)), nm))
      n_set <- n_set + 1L
    }
    message("[load_inputs] applied ", n_set, " default(s) from ", f,
            "; kept ", n_kept_env, " existing env value(s)")
    return(invisible(TRUE))
  }
  invisible(FALSE)
}
