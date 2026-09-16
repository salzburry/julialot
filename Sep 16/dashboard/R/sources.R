# Where the numbers come from. Three sources, one interface.
#
#   snapshot   CSVs a Domino Job exported. What a deployed App normally reads:
#              no warehouse session per viewer, and the numbers are fixed at
#              the moment the Job ran.
#   warehouse  the S_* tables live, over the study package's own connection.
#              For a session that has one.
#   synthetic  generated here. No warehouse and no files, so the App can be
#              deployed and clicked through before any run exists.
#
# A source answers two questions: which scenarios are there, and give me one
# table from one of them. Everything above this line is the same either way.

# A name that may be used as one path segment, and nothing else.
#
# Prefixes and LOT run ids are pasted into a file path, and they come from a
# metadata table that anyone with warehouse write access controls: a run id of
# "../../PRIVATE" would read a file outside the snapshot root.
#
# Rejected rather than sanitised, because silently reading a different file
# from the one asked for is worse than reading none.
# Whether a run's own record says its release left a withheld cell that the
# rest of its group gives away, and if so in what words.
#
# mod_release() withholds every cell under the floor and then records the
# groups where exactly one withheld cell is still the group's total less the
# published rest. Whether to regroup or withhold a second stratum is the
# analyst's call and the package does not make it - so the check lives at the
# point where a run stops being the warehouse's and becomes something other
# people read, which is the snapshot job.
#
# "none" is the only answer that clears. An empty value is a build from before
# the column existed, and "release module did not run" is a run that has not
# been shown to have no recoverable cell because it never looked - neither is
# the same as none, and neither may pass.
RELEASE_NOT_RECORDED <- "nothing recorded - a build from before this column existed"

release_recoverable_blocks <- function(recoverable) {
  v <- trimws(as.character(recoverable %||% "")[1])
  # NA is not a value to interpolate into a refusal. as.character(NA) is
  # NA_character_, nzchar() of which is TRUE, so an unnormalised NA used to
  # fall through this function and come back out in the message.
  if (is.na(v) || !nzchar(v) || identical(toupper(v), "NA"))
    return(RELEASE_NOT_RECORDED)
  # The clean sentinel is matched without regard to case, because this column
  # is read back from a warehouse and from CSV and may have been through a
  # hand edit or an upstream normalisation on the way. "NONE" said in capitals
  # is the same answer, and treating it as a finding withholds every released
  # table from a run that has nothing wrong with it.
  #
  # Only the clean sentinel is folded. Everything else is a finding whatever
  # its case, so this can turn a needless refusal into a read and cannot turn
  # a finding into a clear.
  if (identical(toupper(v), "NONE")) return("")
  v
}

# The tables a verdict names, read from the run's own list rather than out of
# its prose.
#
# RELEASE_RECOVERABLE is a sentence, written to be read by a person, and
# recovering table names from a sentence is a guess in both directions: a
# reworded warning names none, which silently turns a targeted refusal into a
# blanket one, and a table whose name is a substring of another's is refused
# along with it. So the producer writes the names it found in a field of their
# own - RELEASE_RECOVERABLE_TABLES, semicolon separated - and this reads that.
#
# The list is believed only where it IS one, and the test is membership, not
# spelling. Every name has to be one of the tables that HAS a released copy -
# the six of SUPPRESSION_SPEC - because this field is what narrows a refusal,
# and a name matched on shape alone narrows it to nothing: a stale or hand-
# edited "S_NOT_A_TABLE" is a perfectly well-formed name, and believing it
# would refuse a table that does not exist while leaving the recoverable one
# readable. So one unrecognised name discards the whole list rather than part
# of it - a field that is partly wrong is not one to act on the rest of.
#
# Empty, absent, unreadable or unrecognised, this returns nothing and the
# caller falls back to the sentence, which refuses every released table when it
# names none. A build from before the column existed takes that path, and so
# does a run whose release module never ran. An empty list therefore never
# narrows a refusal; only a list of known released tables does.
release_named_tables <- function(tables) {
  v <- trimws(as.character(tables %||% "")[1])
  if (is.na(v) || !nzchar(v) || identical(v, "NA")) return(character(0))
  parts <- toupper(trimws(strsplit(v, ";", fixed = TRUE)[[1]]))
  parts <- parts[nzchar(parts)]
  known <- toupper(sub("_RELEASE$", "", names(SUPPRESSION_SPEC_NAMES())))
  if (!length(parts) || !all(parts %in% known)) return(character(0))
  unique(parts)
}

# Which of a run's tables its own release verdict refuses.
#
# A run with one recoverable group loses that table and not the page. Which
# table comes from the run's own list where it wrote one, and from the sentence
# otherwise; a verdict that names no table refuses every released table,
# because an answer that cannot be read is not one that clears.
#
# A run with NO record is the one case this does not refuse. The snapshot job
# is the gate - it blocks an export whose record is absent, so what reaches a
# Dataset has been through it - and refusing here as well would blank every
# snapshot taken before the column existed, which is a large harm against a
# risk the banner states on the page instead. Re-exporting such a run through
# the job is what actually settles it.
release_refused_tables <- function(recoverable, tables = "") {
  blocked <- release_recoverable_blocks(recoverable)
  if (!nzchar(blocked) || identical(blocked, RELEASE_NOT_RECORDED))
    return(character(0))
  named <- release_named_tables(tables)
  if (length(named)) return(named)
  known <- sub("_RELEASE$", "", names(SUPPRESSION_SPEC_NAMES()))
  from_prose <- known[vapply(known, function(t)
    grepl(t, blocked, fixed = TRUE), logical(1))]
  if (length(from_prose)) from_prose else known
}

# Whether this deployment has been told to show them anyway. The snapshot job
# has the same switch under its own name; a warehouse App is a second way in
# and needs its own, because nothing it reads has been through that job.
release_recoverable_allowed <- function()
  isTRUE(as.logical(Sys.getenv("DASH_ALLOW_RECOVERABLE", "FALSE")))

# A catalog, schema, prefix or table, ready to go into a statement: quoted,
# not checked against a grammar. NA where the name cannot be quoted safely.
#
# The grammar was the wrong tool, and wrong in both directions. It let through
# names this warehouse needs quoting for - a hyphen, an all-digit name - so
# validation passed and the query then failed to parse; and it refused names
# that are perfectly ordinary here, like a leading underscore. A reserved word
# is the same problem again. Backticks are Spark's delimited identifier and
# answer all of it at once, so what is left to refuse is only what quoting
# cannot survive: a backtick of its own, a line break, a control character,
# and nothing at all.
#
# Injection is closed by the same change rather than by the list: a prefix of
# "x; DROP TABLE p; --" comes out as one identifier with that name, which no
# warehouse has, so the read finds nothing instead of running it.
sql_name <- function(x) {
  v <- as.character(x %||% "")
  if (length(v) != 1L || is.na(v) || !nzchar(v) ||
      grepl("[`]", v) || grepl("[[:cntrl:]]", v)) return(NA_character_)
  sprintf("`%s`", v)
}

safe_segment <- function(x) {
  x <- as.character(x %||% "")
  length(x) == 1L && nzchar(x) && !is.na(x) &&
    # The anchor already refuses "." and ".." - the first character has to be
    # alphanumeric - so the second test cannot fire. Kept as the explicit
    # statement of what this is for.
    grepl("^[A-Za-z0-9][A-Za-z0-9._-]*$", x) && !grepl("^[.]{1,2}$", x)
}

new_source <- function(cfg = dashboard_config(), con = NULL) {
  s <- switch(cfg$source,
    snapshot  = snapshot_source(cfg),
    warehouse = warehouse_source(cfg, con),
    synthetic = synthetic_source(cfg),
    stop("DASHBOARD ERROR: DASH_SOURCE '", cfg$source,
         "' is not one of snapshot, warehouse, synthetic.", call. = FALSE))
  if (identical(cfg$source, "synthetic") && !isTRUE(cfg$allow_synthetic))
    stop("DASHBOARD ERROR: DASH_SOURCE=synthetic but DASH_ALLOW_SYNTHETIC is ",
         "FALSE. A deployment meant to show real numbers must not fall back ",
         "to made-up ones.", call. = FALSE)
  s$config <- cfg
  s
}

# --- snapshot ---------------------------------------------------------------
# <dir>/<prefix>/<TABLE>.csv, one directory per scenario. That is what
# jobs/build_scenarios.R writes, and it is readable by anything.
snapshot_source <- function(cfg) {
  root <- cfg$snapshot_dir
  list(
    kind = "snapshot", synthetic = FALSE, origin = root,
    prefixes = function() {
      if (!dir.exists(root)) return(character(0))
      d <- list.dirs(root, full.names = FALSE, recursive = FALSE)
      d <- d[nzchar(d) & vapply(d, safe_segment, logical(1)) & d != "lot"]
      if (length(cfg$prefixes)) intersect(d, cfg$prefixes) else d
    },
    read = function(prefix, table) {
      if (!safe_segment(prefix) || !safe_segment(table)) return(NULL)
      p <- file.path(root, prefix, paste0(table, ".csv"))
      if (!file.exists(p)) return(NULL)
      # The metadata row is text, every field of it: a run id or a hash that
      # happens to be all digits would otherwise come back as a number, and
      # as a different string.
      if (identical(toupper(table), "S_RUN_METADATA"))
        return(utils::read.csv(p, stringsAsFactors = FALSE, check.names = FALSE,
                               na.strings = c("", "NA"), colClasses = "character"))
      utils::read.csv(p, stringsAsFactors = FALSE, check.names = FALSE,
                      na.strings = c("", "NA"))
    },
    # LOT tables sit under lot/<run>.<build>/ (lot/<run>/ where the scenario
    # recorded no build), not under a scenario. Several scenarios normally
    # read one LOT run, and a copy per scenario would both waste the space and
    # suggest they differ. Filed by build as well as run because the engine
    # may build a run id more than once - see lot_dir_name().
    read_lot = function(lot_run_id, table, lot_run_version = "") {
      dir <- lot_dir_name(lot_run_id, lot_run_version)
      if (!safe_segment(dir) || !safe_segment(table)) return(NULL)
      p <- file.path(root, "lot", dir, paste0(table, ".csv"))
      if (!file.exists(p)) return(NULL)
      utils::read.csv(p, stringsAsFactors = FALSE, check.names = FALSE,
                      na.strings = c("", "NA"))
    })
}

# Where a LOT build's tables are filed in a snapshot: by run id, and by build
# where the scenario recorded one. The engine keeps its run id for the life of
# a session, so one id can name two builds with different lines, and a
# directory named by run alone holds whichever was exported last. The version
# is the stamp of the build's status row (run_version_stamp), alphanumeric, so
# the pair is one path segment. A snapshot exported before builds were recorded
# keeps its run-only directories, and a scenario without a version reads them.
lot_dir_name <- function(lot_run_id, lot_run_version = "") {
  id <- trimws(as.character(lot_run_id %||% ""))
  v  <- trimws(as.character(lot_run_version %||% ""))
  if (nzchar(v)) paste0(id, ".", v) else id
}

# --- warehouse --------------------------------------------------------------
warehouse_source <- function(cfg, con) {
  if (is.null(con))
    stop("DASHBOARD ERROR: DASH_SOURCE=warehouse needs a connection. ",
         "app.R opens one from the package's own connect_db() when the App ",
         "is configured for it.", call. = FALSE)
  full <- function(prefix, table) {
    sch <- if (nzchar(cfg$work_schema)) cfg$work_schema else
      stop("DASHBOARD ERROR: DASH_WORK_SCHEMA is not set, so a table name ",
           "cannot be built.", call. = FALSE)
    # Every part quoted before it is pasted into SQL. The snapshot reader has
    # checked its path segments since it was written and this one never did,
    # though the two take the same values from the same places: DASH_PREFIXES,
    # DASH_LOT_PREFIX, or a prefix read back off SHOW TABLES.
    #
    # The prefix and the table are ONE identifier - "s223926_S_SAFETY_RATES" -
    # so they are quoted together, not each in turn.
    for (part in list(c("DASH_CATALOG", cfg$catalog), c("DASH_WORK_SCHEMA", sch),
                      c("the prefix", prefix), c("the table name", table)))
      if (is.na(sql_name(part[[2]])))
        stop("DASHBOARD ERROR: ", part[[1]], " is '", part[[2]], "', which ",
             "cannot go in a query: a name here may not hold a backtick, a ",
             "line break or a control character, and may not be empty.",
             call. = FALSE)
    sprintf("%s.%s.%s", sql_name(cfg$catalog), sql_name(sch),
            sql_name(paste0(prefix, table)))
  }
  # Whether the LOT prefix holds the run this scenario named, right now.
  #
  # The status table keeps every run's row and the output tables are replaced
  # in place, so "some row says this run completed" is history, not ownership.
  # Only the newest row says whose tables sit under the prefix, and it is read
  # on every call, because the answer changes whenever the prefix is rebuilt.
  lot_ok <- function(lot_run_id, lot_run_version = "")
    nzchar(cfg$lot_prefix) &&
      lot_prefix_owner_ok(con, full(cfg$lot_prefix, "LOT_BUILD_STATUS"),
                          lot_run_id, lot_run_version)
  list(
    kind = "warehouse", synthetic = FALSE,
    origin = sprintf("%s.%s", cfg$catalog, cfg$work_schema),
    prefixes = function() {
      if (length(cfg$prefixes)) return(cfg$prefixes)
      # Every run wrote S_RUN_METADATA under its own prefix, so the prefixes
      # ARE the tables whose name ends in it.
      if (is.na(sql_name(cfg$catalog)) || is.na(sql_name(cfg$work_schema)))
        stop("DASHBOARD ERROR: DASH_CATALOG and DASH_WORK_SCHEMA cannot go in ",
             "a query - a backtick, a line break, a control character or an ",
             "empty value. They are '", cfg$catalog, "' and '",
             cfg$work_schema, "'.", call. = FALSE)
      d <- tryCatch(db_q(con, sprintf("SHOW TABLES IN %s.%s",
                                      sql_name(cfg$catalog),
                                      sql_name(cfg$work_schema))),
                    error = function(e) NULL)
      if (is.null(d) || !nrow(d)) return(character(0))
      nm <- unlist(d[, intersect(c("tableName", "TABLENAME", "table_name",
                                   "name"), names(d))[1]], use.names = FALSE)
      hit <- grep("S_RUN_METADATA$", nm, value = TRUE)
      p <- sub("S_RUN_METADATA$", "", hit)
      p[grepl(cfg$prefix_pattern, p)]
    },
    read = function(prefix, table) {
      # The name is built OUTSIDE the tryCatch on purpose. A table that is not
      # there is an ordinary answer and reads as NULL; a catalog, schema or
      # prefix that is not a name a query can hold is a misconfigured
      # deployment, and swallowing that would leave the App quietly reading
      # nothing while looking like a run with no tables.
      nm <- full(prefix, table)
      tryCatch(db_q(con, sprintf("SELECT * FROM %s", nm)),
               error = function(e) NULL)
    },
    # The LOT build wrote under its own prefix, which S_RUN_METADATA does not
    # carry - it records the run id, not where the run wrote. DASH_LOT_PREFIX
    # names it, and the prefix is checked against LOT_BUILD_STATUS before any
    # of its tables is read, so a prefix pointing at a different run is caught
    # rather than drawn.
    #
    # The check comes first, not per column: filtering on RUN_ID binds only the
    # tables that carry that column, and LOT_LONG_FINAL, the one the panels are
    # about, does not.
    lot_run_ok = lot_ok,
    read_lot = function(lot_run_id, table, lot_run_version = "") {
      if (!nzchar(cfg$lot_prefix)) return(NULL)
      # Fails closed. A run that cannot be shown to be the one under this
      # prefix is not read: an unbound LOT table is another build's numbers
      # under this scenario's label.
      #
      # Asked before the read and again after it, because the output tables
      # are replaced in place and a rebuild can land in between. The snapshot
      # exporter checks both sides of its copy for the same reason.
      if (!lot_ok(lot_run_id, lot_run_version)) return(NULL)
      d <- tryCatch(db_q(con, sprintf("SELECT * FROM %s",
                                      full(cfg$lot_prefix, table))),
                    error = function(e) NULL)
      if (is.null(d)) return(NULL)
      if (!lot_ok(lot_run_id, lot_run_version)) return(NULL)
      if ("RUN_ID" %in% names(d) && nzchar(lot_run_id %||% ""))
        d <- d[as.character(d$RUN_ID) == lot_run_id, , drop = FALSE]
      d
    })
}

# --- synthetic --------------------------------------------------------------
synthetic_source <- function(cfg) {
  data <- synthetic_scenarios(cfg)
  lot <- synthetic_lot_run()
  list(
    kind = "synthetic", synthetic = TRUE, origin = "generated in-process",
    prefixes = function() names(data),
    read = function(prefix, table) data[[prefix]][[table]],
    # One LOT run behind every scenario, which is the normal case: none of the
    # study's open questions changes how a line is counted.
    read_lot = function(lot_run_id, table, lot_run_version = "")
      if (identical(lot_run_id, SYNTH_LOT_RUN_ID)) lot[[table]] else NULL)
}

# --- the layer everything above uses ----------------------------------------

# Every scenario the source can see, labelled by what makes it different.
load_scenarios <- function(src) {
  pfx <- src$prefixes()
  if (!length(pfx)) return(list())
  # The newest row, so a prefix re-run shows its latest run.
  out <- lapply(pfx, function(p) {
    md <- newest_metadata_row(src, p)
    if (is.null(md)) NULL else scenario_from_row(p, md)
  })
  out <- Filter(Negate(is.null), out)
  if (!length(out)) return(list())
  out <- label_scenarios(out)
  stats::setNames(out, vapply(out, `[[`, character(1), "prefix"))
}

# One table from one scenario, with the release version preferred when the
# viewer asked for it and the run wrote one.
#
# The release table is what may leave the warehouse: its small cells are gone.
# The raw one is what QC reads. A dashboard several people can open is the
# first case, so the release version is the default and reading the raw one is
# a deliberate choice.
read_table <- function(src, prefix, table, prefer_release = TRUE,
                       raw_fallback = FALSE) {
  if (prefer_release && paste0(table, "_RELEASE") %in% names(SUPPRESSION_SPEC_NAMES())) {
    rel <- src$read(prefix, paste0(table, "_RELEASE"))
    if (!is.null(rel) && nrow(rel)) return(mark_source(rel, "release"))
    # The released copy was asked for and is not there. Whether the raw table
    # may stand in is the CALLER'S to say, and only a caller that knows the
    # run never released one may say yes - the raw table holds exactly what
    # the release was run to remove. The default is no, so a caller that has
    # not thought about it gets the safe answer; read_raw_table() below is the
    # way to ask for the other one, and it says what it is in its name.
    if (!isTRUE(raw_fallback)) return(NULL)
  }
  raw <- src$read(prefix, table)
  if (is.null(raw)) return(NULL)
  mark_source(raw, "raw")
}

# The raw table, where the caller has established that it may have it: a run
# that never released this one, or a QC path that has asked for the unreleased
# numbers on purpose. Named rather than reached by an argument, so a call site
# reads as what it is.
read_raw_table <- function(src, prefix, table)
  read_table(src, prefix, table, prefer_release = FALSE, raw_fallback = TRUE)

# Whether the newest row of a LOT_BUILD_STATUS table names this run, complete,
# and - where the scenario recorded which build of the run it read - that
# build. The engine keeps a run id for a session, so a second build leaves a
# second `complete` row under the same id; the study run records the stamp of
# the row it vouched for (S_RUN_METADATA.LOT_RUN_VERSION), and a newest row
# carrying another stamp is a different build's tables under this run's name. A
# scenario that recorded no build is bound by id alone, which is all it can be.
#
# Pure, so the warehouse reader and the snapshot exporter decide ownership the
# same way. Newest by UPDATED_AT where the table carries it; otherwise the last
# row written.
lot_status_owner <- function(st, lot_run_id, lot_prefix = "x",
                             lot_run_version = "") {
  if (!nzchar(lot_prefix %||% "") || is.null(st) || !nrow(st) ||
      !all(c("RUN_ID", "STATE") %in% names(st))) return(FALSE)
  lot_build_owns(newest_row(st), lot_run_id, lot_run_version)
}

# The same question asked of a table by name. The snapshot job asks it of
# the LOT prefix around its copy; the warehouse source asks it around each
# read.
lot_prefix_owner_ok <- function(con, status_tbl, lot_id, lot_version = "") {
  st <- tryCatch(db_q(con, sprintf("SELECT * FROM %s", status_tbl)),
                 error = function(e) NULL)
  lot_status_owner(st, lot_id, "x", lot_version)
}

# The newest row of a status or metadata table: by UPDATED_AT where the table
# carries it, otherwise the last row written.
newest_row <- function(df) {
  o <- if ("UPDATED_AT" %in% names(df))
    order(as.character(df$UPDATED_AT), decreasing = TRUE) else rev(seq_len(nrow(df)))
  df[o[1], , drop = FALSE]
}

# A study table, bound to the run the scenario describes.
#
# The scenarios are read once, at startup; a table is read when a panel opens,
# and a refresh in between replaces the snapshot. So the identity is checked
# around every read - before, so a moved snapshot yields nothing, and after, so
# a swap landing between the check and the read is caught too.

# --- the scope of a run --------------------------------------------------
#
# A run writes only the modules it selected, for the cohorts it selected, and
# leaves every other table and every other cohort's rows under the prefix as
# the previous run left them. That is what makes a partial re-run cheap, and it
# means a completed run's prefix can hold tables the run never wrote and rows
# it never built. Its metadata says what it did write - MODULES and COHORTS -
# and the three rules below bind what is shown, compared and exported to that.
# The reader and the snapshot job both apply them, so the two cannot drift.

# The module that writes a table, off the package's own registry; NA for a
# table no module declares. Release tables are the release module's.
table_owner <- function(table, modules = MODULES) {
  for (m in modules) if (table %in% (m$outputs %||% character(0))) return(m$key)
  NA_character_
}

# Whether this table is this run's, and if not why not - in the words a panel
# shows.
#
# One verdict for every site that asks: the reader, the panel resolver, the
# Compare tab and the snapshot job. A table is the run's only if the run
# finished (its metadata row is written before its tables are replaced, so
# under a `started` or `failed` run the tables are the previous build's, or
# part of this one), if the run's own metadata names the module that writes it,
# and - for a module's optional output - if the run recorded that output's
# switch on. A run that recorded no modules, or no reading of a switch, can
# vouch for nothing that depends on them.
scenario_table_status <- function(scenario, table, modules = MODULES) {
  if (identical(table, "S_RUN_METADATA")) return(list(ok = TRUE, why = ""))
  no <- function(why) list(ok = FALSE, why = why)
  if (!scenario_is_usable(scenario))
    return(no(paste(
      scenario_unusable_why(scenario),
      if (identical(tolower(scenario$state %||% ""), "complete"))
        "Its tables are not shown."
      else paste("Its tables are not shown: they may be the previous build's,",
                 "or part of this one."),
      "Its settings and the LOT run it read are on the Overview tab.")))
  own <- table_owner(table, modules)
  if (is.na(own)) return(no(sprintf("%s is not a table this package writes.", table)))
  ran <- trimws(as.character(scenario$modules %||% character(0)))
  if (!own %in% ran[nzchar(ran)])
    return(no(sprintf("The '%s' module did not run in this scenario, so %s is empty.",
                      own, table)))
  setting <- optional_output_setting(table)
  if (!is.na(setting) && !reading_is_true(scenario, setting))
    return(no(sprintf("%s is written only when %s is on, which this run did not record.",
                      table, toupper(setting))))
  list(ok = TRUE, why = "")
}

scenario_wrote <- function(scenario, table, modules = MODULES)
  scenario_table_status(scenario, table, modules)$ok

# Whether the run recorded a setting as TRUE. Missing is not TRUE.
reading_is_true <- function(scenario, setting) {
  r <- scenario$readings[[setting]]
  !is.null(r) && identical(toupper(trimws(as.character(r$value %||% ""))), "TRUE")
}

# The switch that turns a table on, where the registry declares one
# (OPTIONAL_FEATURES in the package's registry.R); NA for every other table.
optional_output_setting <- function(table) {
  feats <- if (exists("OPTIONAL_FEATURES")) OPTIONAL_FEATURES else list()
  for (m in feats) for (setting in names(m))
    if (identical(m[[setting]]$output, table)) return(setting)
  NA_character_
}

# The rows of a table that belong to this run: the cohorts it selected. A
# 2L partition a previous run built sits beside a 1L this run rebuilt, and a
# panel over "all cohorts" drew both. A table with no COHORT column is not
# per cohort and passes whole; a run that recorded no cohorts owns no rows.
restrict_to_cohorts <- function(d, scenario) {
  if (is.null(d) || !"COHORT" %in% names(d)) return(d)
  co <- trimws(as.character(scenario$cohorts %||% character(0)))
  co <- co[nzchar(co)]
  if (!length(co)) return(d[0, , drop = FALSE])
  d[as.character(d$COHORT) %in% co, , drop = FALSE]
}

read_scenario_table <- function(src, scenario, table, prefer_release = TRUE) {
  # Only what this run wrote - scenario_table_status() says what that is: a
  # finished run's own tables, and the released copy only where it ran the
  # release module, otherwise the rebuilt raw table.
  if (!scenario_wrote(scenario, table)) return(NULL)
  # Did THIS run release this table? That decides two different things: which
  # copy to prefer, and - below - whether the raw one may stand in for it.
  released <- scenario_wrote(scenario, paste0(table, "_RELEASE"))
  prefer_release <- prefer_release && released
  same <- function() {
    m <- scenario_is_current(src, scenario)
    # Unanswerable two ways: a scenario that recorded no run is not bound and
    # reads freely; one that did, over a prefix whose metadata cannot be read
    # now, is refused - a run that cannot be shown to be there is not there.
    if (is.na(m)) !nzchar(trimws(scenario$run_id %||% "")) else m
  }
  if (!same()) return(NULL)
  # THE RELEASE VERDICT, on the read path as well as in the snapshot job.
  #
  # The job is one way a run reaches people and a live warehouse App is
  # another, and only the first was checking. A run whose own metadata says a
  # withheld cell is still its group's total less the published rest must not
  # show that table here either, whatever route it came by.
  #
  # Asked whether or not this run released THIS table. "The release module did
  # not run" is a verdict as much as a named finding is: the tables that would
  # have had a released copy have none, so what sits under the prefix is the
  # working table the release was meant to replace. The job refuses to export
  # such a run for exactly that reason, and reading it here would make the two
  # paths disagree about the same run.
  if (!release_recoverable_allowed() &&
      toupper(table) %in% release_refused_tables(
        scenario$release_recoverable, scenario$release_recoverable_tables))
    return(NULL)
  # FAIL CLOSED where this run released. The raw table may stand in only for a
  # run that never released one; where the run says it did and the copy is
  # missing or empty, reading the raw one would undo the release quietly, and
  # a partial write or a deleted table is exactly that case.
  d <- read_table(src, scenario$prefix, table, prefer_release,
                  raw_fallback = !released)
  if (!same()) return(NULL)
  restrict_to_cohorts(d, scenario)
}

# The metadata row a prefix holds right now, as opposed to the one read at
# startup: the newest by UPDATED_AT, or the last one written. A refresh between
# the two replaces the snapshot, and the page would otherwise show the new
# run's rows under the old run's metadata.
newest_metadata_row <- function(src, prefix) {
  md <- tryCatch(src$read(prefix, "S_RUN_METADATA"), error = function(e) NULL)
  if (is.null(md) || !nrow(md) || !"RUN_ID" %in% names(md)) return(NULL)
  newest_row(md)
}

# The identity every reader binds a run by, off one metadata row: the id, and
# the state and timestamp that tell one build under that id from another, as
# one key. A run id is not a build - the study package reuses DOMINO_RUN_ID for
# every build inside one Domino run, so a re-run keeps the id while its state
# goes to `started` and back and its UPDATED_AT moves.
run_identity <- function(row)
  paste(row_field(row, "RUN_ID"), row_field(row, "STATE"),
        row_field(row, "UPDATED_AT"), sep = "\r")

# Whether the build under this prefix, right now, is the one the scenario
# describes.
# NA where it cannot be said: the scenario records no run, or the prefix has
# no metadata to read. The same answer same_lot_run() gives.
scenario_is_current <- function(src, scenario) {
  if (!nzchar(trimws(scenario$run_id %||% ""))) return(NA)
  row <- newest_metadata_row(src, scenario$prefix)
  if (is.null(row)) return(NA)
  identical(run_identity(row),
            run_identity(list(RUN_ID = scenario$run_id, STATE = scenario$state,
                              UPDATED_AT = scenario$updated_at)))
}

mark_source <- function(d, which) { attr(d, "table_source") <- which; d }

SUPPRESSION_SPEC_NAMES <- function() {
  if (!exists("SUPPRESSION_SPEC")) return(character(0))
  stats::setNames(as.list(paste0(names(SUPPRESSION_SPEC), "_RELEASE")),
                  paste0(names(SUPPRESSION_SPEC), "_RELEASE"))
}


# One LOT table for the run a scenario read.
#
# NULL when the scenario names no LOT run, or when this source cannot reach it.
# Both are reported by the panel rather than drawn as an empty table: "the LOT
# tables were not exported" and "the LOT run built nothing" look identical on a
# page and mean different things.
read_lot_table <- function(src, scenario, table) {
  if (is.null(src$read_lot)) return(NULL)
  src$read_lot(scenario$lot_run_id, table, scenario$lot_run_version %||% "")
}

# Whether a source can bind this scenario's LOT run at all, for a panel that
# has to say WHY it is empty. A source that does not bind runs (the snapshot
# keys them by directory, so it already has) answers TRUE.
lot_run_bound <- function(src, scenario) {
  if (is.null(src$lot_run_ok)) return(TRUE)
  isTRUE(src$lot_run_ok(scenario$lot_run_id, scenario$lot_run_version %||% ""))
}

# Whether two scenarios rest on the same lines.
#
# The question the Compare tab has to answer before it draws a difference. Two
# scenarios sharing a LOT run differ only in what this package did; two reading
# different runs differ in the lines as well, and a delta between them carries
# both without saying so. One run id under two builds is two sets of lines as
# surely as two ids are, so where both scenarios recorded which build they
# read, the builds have to match too; where only one did, it cannot be said.
#
# The answer carries why as an attribute, so the Compare tab can say which case
# it is without working the ids and builds out again.
same_lot_run <- function(a, b) {
  ra <- trimws(a$lot_run_id %||% ""); rb <- trimws(b$lot_run_id %||% "")
  if (!nzchar(ra) || !nzchar(rb)) return(structure(NA, why = "no_run"))
  if (!identical(ra, rb)) return(structure(FALSE, why = "different_run"))
  va <- trimws(a$lot_run_version %||% ""); vb <- trimws(b$lot_run_version %||% "")
  if (nzchar(va) != nzchar(vb)) return(structure(NA, why = "unknown_build"))
  if (!identical(va, vb)) return(structure(FALSE, why = "different_build"))
  structure(TRUE, why = "same")
}
