# Reads config.csv (name,value,description) into the environment as defaults.
#
# The environment wins. A row is applied only when that variable is unset, so
# the file never overrides a shell export or a value Domino injected. A blank
# value, a blank name or a '#' name is skipped, and DATABRICKS_PWD is never read
# from the file. Source this before config_lot.R reads Sys.getenv().

# Turn a date string into YYYY-MM-DD. ISO passes straight through. So do the
# common Excel reformats: DD-MM-YYYY, DD/MM/YYYY, MM/DD/YYYY, YYYY/MM/DD.
# If nothing parses to a plausible date - year 1900 or later - the input comes
# back unchanged, so a config error downstream still shows clearly instead of
# being quietly wrong.
.normalize_iso_date <- function(v, nm = "") {
  if (grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", v)) return(v)
  cand <- Filter(Negate(is.na), lapply(
    c("%d-%m-%Y", "%d/%m/%Y", "%m/%d/%Y", "%Y/%m/%d", "%m-%d-%Y"),
    function(fmt) {
      d <- tryCatch(as.Date(v, format = fmt), error = function(e) NA)
      if (!is.na(d) && as.integer(format(d, "%Y")) >= 1900) d else NA
    }))
  iso <- unique(vapply(cand, format, character(1)))
  # 03/04/2025 is 3 April read day-first and 4 March read month-first. Taking
  # the first format that parses picks one quietly. For STUDY_END the two fall
  # in different quarters, which means a different set of CDM tables.
  if (length(iso) > 1L)
    stop("[load_inputs] ", nm, " '", v, "' is ambiguous - it reads as ",
         paste(iso, collapse = " or "), ". Write it as YYYY-MM-DD.",
         call. = FALSE)
  if (length(iso) == 1L) {
    message("[load_inputs] normalized ", nm, " '", v, "' -> ", iso,
            " (Excel likely reformatted the date)")
    return(iso)
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
      # Excel quietly rewrites ISO dates, especially in a non-US locale:
      # STUDY_END 2025-06-30 becomes 30-06-2025, which then parses into the
      # wrong quarterly table. Known date keys go back to YYYY-MM-DD here, so
      # the CSV survives a trip through Excel.
      if (toupper(nm) %in% c("STUDY_END", "STUDY_START",
                             "ID_START", "ID_END")) {
        vl <- .normalize_iso_date(vl, nm)
      }
      # The environment wins. Only fill when the variable is unset or empty.
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
