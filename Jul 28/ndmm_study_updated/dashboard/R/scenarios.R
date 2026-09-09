# A scenario is an OBJECT_PREFIX and the S_RUN_METADATA row the run wrote.
#
# The package already does all of this. Every table it writes carries the run's
# prefix, and every run records its cohorts, its modules, the LOT run it read,
# and its answer to each open question. So two runs under two prefixes ARE two
# scenarios, and comparing them needs no new concept - only somewhere to read
# both.
#
# The dashboard never writes. A scenario a viewer asks for that nobody has run
# does not appear; scenario_command() prints what would produce it.

# One S_RUN_METADATA row -> a scenario.
#
# OPEN_QUESTION_READINGS is written as "k=v; k=v (upstream, verified); ...".
# Parsed back so the readings can be compared setting by setting rather than as
# one string that differs somewhere.
parse_readings <- function(s) {
  s <- trimws(as.character(s %||% ""))
  if (!length(s) || !nzchar(s)) return(list())
  parts <- trimws(strsplit(s, ";", fixed = TRUE)[[1]])
  parts <- parts[nzchar(parts)]
  out <- lapply(parts, function(p) {
    # "key=value (note)" - the note is provenance, not part of the value.
    note <- ""
    m <- regexpr(" \\([^)]*\\)$", p)
    if (m > 0) {
      note <- gsub("^ \\(|\\)$", "", substring(p, m))
      p <- substr(p, 1, m - 1)
    }
    eq <- regexpr("=", p, fixed = TRUE)
    if (eq < 1) return(NULL)
    list(key = substr(p, 1, eq - 1), value = substring(p, eq + 1), note = note)
  })
  out <- Filter(Negate(is.null), out)
  stats::setNames(out, vapply(out, `[[`, character(1), "key"))
}

scenario_from_row <- function(prefix, row) {
  g <- function(k) {
    v <- if (k %in% names(row)) row[[k]][1] else NA
    if (is.null(v) || is.na(v)) "" else trimws(as.character(v))
  }
  readings <- parse_readings(g("OPEN_QUESTION_READINGS"))
  list(
    prefix = prefix,
    run_id = g("RUN_ID"),
    state = g("STATE"),
    updated_at = g("UPDATED_AT"),
    cohorts = trimws(strsplit(g("COHORTS"), ";")[[1]]),
    modules = trimws(strsplit(g("MODULES"), ";")[[1]]),
    lot_run_id = g("LOT_RUN_ID"),
    study_start = g("STUDY_START"),
    study_end = g("STUDY_END"),
    deviations = g("CONTRACT_DEVIATIONS"),
    codelists = g("CODELISTS"),
    readings = readings,
    # A label a stakeholder can pick out of a list. The prefix is the identity;
    # what makes one scenario interesting is where its readings differ, and
    # that is only knowable against the others - so it is added by
    # label_scenarios() once the whole set is known.
    label = prefix)
}

# Only a run that finished has numbers worth showing. A `started` row is a run
# still going or one that died before its handler; `failed` is a run that
# stopped. Both are listed, and both are marked, because a scenario that is
# missing from a comparison for want of a finished run is worth seeing.
scenario_is_usable <- function(s) identical(tolower(s$state), "complete")

# What actually differs across a set of scenarios, setting by setting.
#
# Every run records every reading, so two scenarios differ in a handful of
# places and agree everywhere else. Only the handful is worth a viewer's
# attention, and it is what names them.
scenario_diff_keys <- function(scenarios) {
  if (length(scenarios) < 2L) return(character(0))
  keys <- unique(unlist(lapply(scenarios, function(s) names(s$readings))))
  Filter(function(k) {
    vals <- vapply(scenarios, function(s)
      if (k %in% names(s$readings)) s$readings[[k]]$value else "<absent>",
      character(1))
    length(unique(vals)) > 1L
  }, keys)
}

# A name a stakeholder can read: the settings that make this scenario
# different, not its prefix. Falls back to the prefix when nothing differs.
label_scenarios <- function(scenarios) {
  d <- scenario_diff_keys(scenarios)
  lapply(scenarios, function(s) {
    if (!length(d)) { s$label <- s$prefix; return(s) }
    bits <- vapply(d, function(k)
      sprintf("%s=%s", k,
              if (k %in% names(s$readings)) s$readings[[k]]$value else "-"),
      character(1))
    s$label <- paste(bits, collapse = ", ")
    s$differs_on <- d
    s
  })
}

# Two scenarios, side by side, on the readings alone.
compare_readings <- function(a, b) {
  keys <- sort(unique(c(names(a$readings), names(b$readings))))
  if (!length(keys)) return(data.frame())
  val <- function(s, k) if (k %in% names(s$readings)) s$readings[[k]]$value else NA_character_
  note <- function(s, k) if (k %in% names(s$readings)) s$readings[[k]]$note else NA_character_
  out <- data.frame(
    SETTING = keys,
    A = vapply(keys, val, character(1), s = a),
    B = vapply(keys, val, character(1), s = b),
    A_NOTE = vapply(keys, note, character(1), s = a),
    B_NOTE = vapply(keys, note, character(1), s = b),
    stringsAsFactors = FALSE)
  out$DIFFERS <- !identical(TRUE, FALSE) & (is.na(out$A) != is.na(out$B) |
    (!is.na(out$A) & !is.na(out$B) & out$A != out$B))
  rownames(out) <- NULL
  out[order(!out$DIFFERS, out$SETTING), ]
}

# What a viewer would run to get a scenario nobody has run.
#
# Printed, never executed. The dashboard reads; a run writes to the warehouse
# and belongs to whoever owns the schema.
scenario_command <- function(settings, cfg = dashboard_config(),
                             prefix = NULL, env_map = SETTING_ENV) {
  settings <- settings[!vapply(settings, is.null, logical(1))]
  known <- intersect(names(settings), names(env_map))
  unknown <- setdiff(names(settings), names(env_map))
  lines <- c(
    sprintf("export OBJECT_PREFIX=%s",
            if (is.null(prefix)) "<a prefix nothing has used>" else prefix),
    vapply(known, function(k)
      sprintf("export %s=%s", env_map[[k]],
              paste(as.character(settings[[k]]), collapse = ",")),
      character(1)),
    cfg$run_cmd)
  list(command = paste(lines, collapse = "\n"),
       unsupported = unknown)
}

`%||%` <- function(a, b) if (is.null(a) || (length(a) == 1L && is.na(a))) b else a

# The environment variable behind each setting, read off cfg_defaults() itself.
#
# The package writes them inline - `months_as = .env_enum("MONTHS_AS", ...)` -
# and there is no map to import. Deriving one by reading that function means
# the dashboard cannot print an export for a variable the package does not
# read, and a setting added there appears here with no edit.
setting_env_map <- function(fn = NULL) {
  if (is.null(fn)) {
    if (!exists("cfg_defaults", mode = "function")) return(character(0))
    fn <- get("cfg_defaults", mode = "function")
  }
  src <- paste(deparse(fn), collapse = "\n")
  # field = .env_<type>("ENV_NAME", ...
  m <- gregexpr(
    "[A-Za-z_][A-Za-z0-9_.]*[[:space:]]*=[[:space:]]*\\.env_[a-z]+\\([[:space:]]*\"[A-Z0-9_]+\"",
    src)
  hits <- regmatches(src, m)[[1]]
  if (!length(hits)) return(character(0))
  field <- sub("[[:space:]]*=.*$", "", hits)
  envv  <- sub('^.*"([A-Z0-9_]+)"$', "\\1", hits)
  keep <- !duplicated(field)
  stats::setNames(envv[keep], field[keep])
}
