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

# Coerce a date string to YYYY-MM-DD. Accepts ISO (pass-through) plus
# the common Excel reformats (DD-MM-YYYY, DD/MM/YYYY, MM/DD/YYYY,
# YYYY/MM/DD). Returns the input unchanged if nothing parses to a
# plausible (year >= 1900) date, so a downstream config error still
# surfaces clearly rather than being silently wrong.
.normalize_iso_date <- function(v, nm = "") {
  if (grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", v)) return(v)
  for (fmt in c("%d-%m-%Y", "%d/%m/%Y", "%m/%d/%Y", "%Y/%m/%d", "%m-%d-%Y")) {
    d <- tryCatch(as.Date(v, format = fmt), error = function(e) NA)
    if (!is.na(d) && as.integer(format(d, "%Y")) >= 1900) {
      iso <- format(d, "%Y-%m-%d")
      message("[load_inputs] normalized ", nm, " '", v, "' -> ", iso,
              " (Excel likely reformatted the date)")
      return(iso)
    }
  }
  message("[load_inputs] WARN: could not normalize ", nm, " '", v,
          "' to YYYY-MM-DD; passing through.")
  v
}

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
      vl <- trimws(as.character(vl))
      # Excel (esp. non-US locale) silently rewrites ISO dates, e.g.
      # STUDY_END 2025-06-30 -> 30-06-2025, which then mis-parses into
      # the wrong quarterly table. Normalize known date keys back to
      # YYYY-MM-DD here so the CSV survives an Excel round-trip.
      if (toupper(nm) %in% c("STUDY_END", "STUDY_START",
                             "ID_START", "ID_END")) {
        vl <- .normalize_iso_date(vl, nm)
      }
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
