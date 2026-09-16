# A scenario is an OBJECT_PREFIX and the S_RUN_METADATA row the run wrote.
#
# The package already does all of this. Every table it writes carries the run's
# prefix, and every run records its cohorts, its modules, the LOT run it read,
# and its answer to each open question. So two runs under two prefixes are two
# scenarios, and comparing them needs only somewhere to read both.
#
# The dashboard never writes. A scenario a viewer asks for that nobody has run
# does not appear; scenario_command() prints what would produce it.

# One S_RUN_METADATA row -> a scenario.
#
# OPEN_QUESTION_READINGS is written as "k=v; k=v (upstream, verified); ...".
# Parsed back so the readings can be compared setting by setting rather than as
# one string that differs somewhere.
#
# The separator is a semicolon and a note may contain one: the producer writes
# "study_start=2016-01-01 (upstream, verified; this run was set to 2018-01-01)"
# when the two disagree, which is exactly when the provenance is worth reading.
# So the split has to know where the note is rather than cutting on every
# semicolon.
.split_entries <- function(s) {
  ch <- strsplit(s, "", fixed = TRUE)[[1]]
  depth <- 0L; out <- character(0); cur <- character(0)
  for (c in ch) {
    if (identical(c, "(")) depth <- depth + 1L
    else if (identical(c, ")")) depth <- max(0L, depth - 1L)
    if (identical(c, ";") && depth == 0L) { out <- c(out, paste(cur, collapse = "")); cur <- character(0) }
    else cur <- c(cur, c)
  }
  c(out, paste(cur, collapse = ""))
}

parse_readings <- function(s) {
  s <- trimws(as.character(s %||% ""))
  if (!length(s) || !nzchar(s)) return(list())
  parts <- trimws(.split_entries(s))
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
    # The key is trimmed and must be non-empty: untrimmed, "months_as " and
    # "months_as" read as two settings differing on whitespace alone.
    key <- trimws(substr(p, 1, eq - 1))
    if (!nzchar(key)) return(NULL)
    list(key = key, value = trimws(substring(p, eq + 1)), note = note)
  })
  out <- Filter(Negate(is.null), out)
  keys <- vapply(out, `[[`, character(1), "key")
  # A key repeated in one string keeps its first reading only, so names() and
  # [[ ]] agree: a list with duplicate names looks up the first.
  keep <- !duplicated(keys)
  stats::setNames(out[keep], keys[keep])
}

# One field of a metadata row as the string a scenario carries: trimmed,
# and "" where the row lacks it or holds NA - "not recorded", either way.
row_field <- function(row, k) {
  v <- if (!is.null(row) && k %in% names(row)) row[[k]] else NULL
  if (!length(v) || is.na(v[1])) "" else trimws(as.character(v[1]))
}

scenario_from_row <- function(prefix, row) {
  g <- function(k) row_field(row, k)
  readings <- parse_readings(g("OPEN_QUESTION_READINGS"))
  list(
    prefix = prefix,
    run_id = g("RUN_ID"),
    state = g("STATE"),
    updated_at = g("UPDATED_AT"),
    cohorts = trimws(strsplit(g("COHORTS"), ";")[[1]]),
    modules = trimws(strsplit(g("MODULES"), ";")[[1]]),
    lot_run_id = g("LOT_RUN_ID"),
    # Which BUILD of that run - the stamp of the status row the run vouched
    # for. Empty on metadata written before it was recorded.
    lot_run_version = g("LOT_RUN_VERSION"),
    study_start = g("STUDY_START"),
    study_end = g("STUDY_END"),
    deviations = g("CONTRACT_DEVIATIONS"),
    codelists = g("CODELISTS"),
    # What the run's release module found: "none", or the tables where one
    # withheld cell is still the group's total less the published rest. Read
    # here so the reader can refuse those tables, the way the snapshot job
    # refuses to export them.
    release_recoverable = g("RELEASE_RECOVERABLE"),
    # ...and the same finding as the run's own list of table names, which is
    # what the reader actually refuses on. Blank on a build from before that
    # column existed, and the reader then falls back to the sentence.
    release_recoverable_tables = g("RELEASE_RECOVERABLE_TABLES"),
    # Which contract the run was driven by, and which code produced it. The
    # first decides whether this dashboard's registry can say anything about
    # the run at all - see scenario_contract_bound(). The second is shown.
    study_contract_md5 = g("STUDY_CONTRACT_MD5"),
    study_code_md5 = g("STUDY_CODE_MD5"),
    readings = readings,
    # A label a stakeholder can pick out of a list. The prefix is the identity;
    # what makes one scenario interesting is where its readings differ, and
    # that is only knowable against the others - so it is added by
    # label_scenarios() once the whole set is known.
    label = prefix)
}

# Was the run driven by the contract this dashboard's registry IS?
#
# Every decision below about a run - which tables it wrote, which of them
# have a released copy, which switch turns which on - is made from the
# registry loaded at startup, and the run records the hash of the contract
# it was actually driven by. A run of another version can have released a
# table this registry does not know as released, and reading its raw table
# under this registry's rules would show a number that run withheld. So the
# two are compared, and a difference makes the run unusable here.
#
# TRUE and FALSE where the run recorded a hash; NA where it did not, which is
# a run of a package from before the column - unproven, not wrong, and used.
scenario_contract_bound <- function(s) {
  have <- trimws(as.character(s$study_contract_md5 %||% ""))
  if (!nzchar(have) || identical(toupper(have), "NA")) return(NA)
  identical(have, DASH_CONTRACT_MD5)
}

# Only a run that finished has numbers worth showing. A `started` row is a run
# still going or one that died before its handler; `failed` is a run that
# stopped. Both are listed, and both are marked, because a scenario that is
# missing from a comparison for want of a finished run is worth seeing. And
# only a run this registry can describe - see scenario_contract_bound().
scenario_is_usable <- function(s)
  identical(tolower(s$state), "complete") && !isFALSE(scenario_contract_bound(s))

# Why not, in one sentence a page can show. "" for a usable run.
scenario_unusable_why <- function(s) {
  if (!identical(tolower(s$state), "complete"))
    return(sprintf("This run is '%s', not complete.",
                   if (nzchar(s$state %||% "")) s$state else "unrecorded"))
  if (isFALSE(scenario_contract_bound(s)))
    return(sprintf(paste(
      "This run was driven by a different study contract (%s) from the one",
      "this dashboard's registry describes (%s), so which tables it wrote,",
      "and which of them it published suppressed, cannot be decided here.",
      "Open it with the dashboard beside the package that produced it."),
      substr(s$study_contract_md5, 1, 8), substr(DASH_CONTRACT_MD5, 1, 8)))
  ""
}

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
#
# Every value is single-quoted, with any inner quote escaped the shell's way.
# The page invites a viewer to paste the block, and the values reach it from
# the scenario grid and from the page, so an unquoted newline or ';' in one
# would add a command of its own.
sh_quote <- function(x) {
  x <- paste(as.character(x), collapse = ",")
  paste0("'", gsub("'", "'\\''", x, fixed = TRUE), "'")
}

scenario_command <- function(settings, cfg = dashboard_config(),
                             prefix = NULL, env_map = SETTING_ENV) {
  settings <- settings[!vapply(settings, is.null, logical(1))]
  known <- intersect(names(settings), names(env_map))
  unknown <- setdiff(names(settings), names(env_map))
  lines <- c(
    if (is.null(prefix)) "export OBJECT_PREFIX=<a prefix nothing has used>"
    else sprintf("export OBJECT_PREFIX=%s", sh_quote(prefix)),
    vapply(known, function(k)
      sprintf("export %s=%s", env_map[[k]], sh_quote(settings[[k]])),
      character(1)),
    cfg$run_cmd)
  list(command = paste(lines, collapse = "\n"),
       unsupported = unknown)
}

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
