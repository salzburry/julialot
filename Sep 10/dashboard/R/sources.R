# Where the numbers come from. Three sources, one interface.
#
#   snapshot   CSVs a Domino Job exported. What a deployed App normally reads:
#              no warehouse session per viewer, and the numbers are fixed at
#              the moment the Job ran.
#   warehouse  the S_* tables over sparklyr. For a session that has a cluster.
#   synthetic  generated here. No warehouse and no files, so the App can be
#              deployed and clicked through before any run exists.
#
# A source answers two questions: which scenarios are there, and give me one
# table from one of them. Everything above this line is the same either way.

# A name that may be used as ONE path segment, and nothing else.
#
# Prefixes and LOT run ids are pasted into a file path. A run id of
# "../../PRIVATE" read a file outside the snapshot root - it came from a
# metadata TABLE, which anyone who can write to the warehouse controls, and
# the dashboard then handed its contents to whoever opened the page.
#
# Rejected rather than sanitised: a name that needs cleaning up is not a name
# this dashboard wrote, and silently reading a different file than the one
# asked for is worse than reading none.
safe_segment <- function(x) {
  x <- as.character(x %||% "")
  length(x) == 1L && nzchar(x) && !is.na(x) &&
    # The anchor already refuses "." and ".." - the first character has to be
    # alphanumeric - so the second test is redundant and provably cannot fire.
    # Kept as the explicit statement of what this is for, since the anchor is
    # doing that work by accident rather than by saying so.
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
      utils::read.csv(p, stringsAsFactors = FALSE, check.names = FALSE,
                      na.strings = c("", "NA"))
    },
    # LOT tables sit under lot/<run>.<build>/ (lot/<run>/ where the scenario
    # recorded no build), not under a scenario. Several scenarios normally
    # read ONE LOT run, and a copy per scenario would both waste the space and
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

# Where a LOT build's tables are filed in a snapshot: by run id, and by BUILD
# where the scenario recorded one. The LOT engine keeps its run id for the
# life of a session, so one id can name two builds with different lines; a
# directory named by run alone held whichever was exported last, and a
# scenario that read the other was shown it. The version is the stamp of
# the build's status row (run_version_stamp), alphanumeric, so the pair is
# one path segment. Older snapshots, exported before builds were recorded,
# keep their run-only directories and scenarios without a version read them.
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
    sprintf("%s.%s.%s%s", cfg$catalog, sch, prefix, table)
  }
  # Does the LOT prefix hold the run this scenario named, RIGHT NOW?
  #
  # The status table keeps every run's row and the output tables are replaced
  # in place, so "some row says this run completed" is history, not
  # ownership: with an old and a new completed row both present, asking for
  # the old run returned the new run's lines. Only the NEWEST row says whose
  # tables sit under the prefix, and it is read on every call - the answer
  # can change inside a session, whenever the prefix is rebuilt, so a
  # remembered yes was a yes for as long as the app stayed up.
  lot_ok <- function(lot_run_id, lot_run_version = "")
    lot_status_owner(tryCatch(db_q(con, sprintf("SELECT * FROM %s",
                                     full(cfg$lot_prefix, "LOT_BUILD_STATUS"))),
                              error = function(e) NULL),
                     lot_run_id, cfg$lot_prefix, lot_run_version)
  list(
    kind = "warehouse", synthetic = FALSE,
    origin = sprintf("%s.%s", cfg$catalog, cfg$work_schema),
    prefixes = function() {
      if (length(cfg$prefixes)) return(cfg$prefixes)
      # Every run wrote S_RUN_METADATA under its own prefix, so the prefixes
      # ARE the tables whose name ends in it.
      d <- tryCatch(db_q(con, sprintf("SHOW TABLES IN %s.%s", cfg$catalog,
                                      cfg$work_schema)),
                    error = function(e) NULL)
      if (is.null(d) || !nrow(d)) return(character(0))
      nm <- unlist(d[, intersect(c("tableName", "TABLENAME", "table_name",
                                   "name"), names(d))[1]], use.names = FALSE)
      hit <- grep("S_RUN_METADATA$", nm, value = TRUE)
      p <- sub("S_RUN_METADATA$", "", hit)
      p[grepl(cfg$prefix_pattern, p)]
    },
    read = function(prefix, table)
      tryCatch(db_q(con, sprintf("SELECT * FROM %s", full(prefix, table))),
               error = function(e) NULL),
    # The LOT build wrote under its own prefix, which S_RUN_METADATA does not
    # carry - it records the run id, not where the run wrote. DASH_LOT_PREFIX
    # names it, and the prefix is checked against LOT_BUILD_STATUS before any
    # of its tables is read, so a prefix pointing at a DIFFERENT run is caught
    # rather than drawn.
    #
    # The check has to come FIRST, not per column. Filtering on RUN_ID where
    # the table happens to carry that column bound only the tables that do -
    # and LOT_LONG_FINAL, which is the one the panels are about, does not.
    # Asking for an old run returned the current lines, and the mismatching
    # status was never read at all.
    lot_run_ok = function(lot_run_id, lot_run_version = "")
      lot_ok(lot_run_id, lot_run_version),
    read_lot = function(lot_run_id, table, lot_run_version = "") {
      if (!nzchar(cfg$lot_prefix)) return(NULL)
      # Fails closed. A run that cannot be shown to be the one under this
      # prefix is not read: an unbound LOT table is another build's numbers
      # under this scenario's label.
      #
      # Asked before the read AND after it. The output tables are replaced in
      # place, so a rebuild landing during the read handed back the new
      # build's rows with only one status query ever issued - the one that
      # had said yes. The snapshot exporter checks both sides of its copy
      # for the same reason.
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
  out <- lapply(pfx, function(p) {
    md <- src$read(p, "S_RUN_METADATA")
    if (is.null(md) || !nrow(md)) return(NULL)
    # Newest first, so a prefix re-run shows its latest run.
    if ("UPDATED_AT" %in% names(md))
      md <- md[order(md$UPDATED_AT, decreasing = TRUE), , drop = FALSE]
    scenario_from_row(p, md[1, , drop = FALSE])
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
read_table <- function(src, prefix, table, prefer_release = TRUE) {
  if (prefer_release && paste0(table, "_RELEASE") %in% names(SUPPRESSION_SPEC_NAMES())) {
    rel <- src$read(prefix, paste0(table, "_RELEASE"))
    if (!is.null(rel) && nrow(rel)) return(mark_source(rel, "release"))
  }
  raw <- src$read(prefix, table)
  if (is.null(raw)) return(NULL)
  mark_source(raw, "raw")
}

# Whether the NEWEST row of a LOT_BUILD_STATUS table names this run, complete
# - and, where the scenario recorded which BUILD of the run it read, that
# build. The engine keeps a run id for a session, so a second build under
# the same id leaves a second `complete` row under it; the study run records
# the stamp of the row it vouched for (S_RUN_METADATA.LOT_RUN_VERSION), and a
# newest row carrying any other stamp is a different build's tables under
# this run's name. A scenario that recorded no build is bound by id alone,
# which is all it can be.
#
# Pure, so the warehouse reader and the snapshot exporter decide ownership the
# same way, and a test can drive it with a frame. Newest by UPDATED_AT where
# the table carries it; otherwise the last row written.
lot_status_owner <- function(st, lot_run_id, lot_prefix = "x",
                             lot_run_version = "") {
  id <- trimws(lot_run_id %||% "")
  if (!nzchar(id) || !nzchar(lot_prefix %||% "")) return(FALSE)
  if (is.null(st) || !nrow(st) || !all(c("RUN_ID", "STATE") %in% names(st)))
    return(FALSE)
  o <- if ("UPDATED_AT" %in% names(st))
    order(as.character(st$UPDATED_AT), decreasing = TRUE) else rev(seq_len(nrow(st)))
  newest <- st[o[1], , drop = FALSE]
  if (!identical(trimws(as.character(newest$RUN_ID)), id) ||
      !identical(tolower(trimws(as.character(newest$STATE))), "complete"))
    return(FALSE)
  v <- trimws(as.character(lot_run_version %||% ""))
  !nzchar(v) || identical(run_version_stamp(newest$UPDATED_AT %||% ""), v)
}

# A study table, bound to the run the scenario describes.
#
# The scenarios are read once, at startup; a table is read when a panel
# opens. A refresh in between replaces the snapshot, and a reactive guard that
# read the metadata file once per selected scenario could not see it: a file
# is not a reactive input, so a later floor or tab change re-read the new
# tables under the old run's settings. The identity is checked around EVERY
# read instead - before, so a moved snapshot yields nothing, and after, so a
# swap landing between the check and the read is caught too.
# --- the scope of a run --------------------------------------------------
#
# A run writes only the modules it selected, for the cohorts it selected, and
# leaves every other table and every other cohort's rows under the prefix as
# the previous run left them: prepare_table() clears one cohort's rows of one
# table. That is what makes a partial re-run cheap, and it means a completed
# run's prefix can hold tables the run never wrote and rows it never built.
# Its metadata says what it did write - MODULES and COHORTS - and these three
# rules bind what is shown, compared and exported to that. The reader and the
# snapshot job both apply them, so the two cannot drift.

# The module that writes a table, off the package's own registry; NA for a
# table no module declares. Release tables are the release module's.
table_owner <- function(table, modules = MODULES) {
  for (m in modules) if (table %in% (m$outputs %||% character(0))) return(m$key)
  NA_character_
}

# Did THIS run write this table? Only if its metadata names the module that
# writes it. A retained safety table under a run that omitted safety is the
# previous run's; a release table under a run that omitted release is too. A
# run that recorded no modules can vouch for nothing but its metadata.
scenario_wrote <- function(scenario, table, modules = MODULES) {
  if (identical(table, "S_RUN_METADATA")) return(TRUE)
  ran <- trimws(as.character(scenario$modules %||% character(0)))
  ran <- ran[nzchar(ran)]
  own <- table_owner(table, modules)
  !is.na(own) && length(ran) > 0 && own %in% ran
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
  # A run that did not finish has no numbers of its own. The producer writes
  # its metadata row BEFORE it replaces a table, and a failure leaves what was
  # there - the previous build's tables, or part of the new one - so a
  # `started` or `failed` scenario, or one whose state is not recorded, reads
  # only its metadata and never a result. A fresh page over such a run drew
  # the previous build's rate under the new run's settings.
  if (!identical(table, "S_RUN_METADATA") && !scenario_is_usable(scenario))
    return(NULL)
  # ...and only what it wrote. A table under the prefix that this run's
  # metadata does not claim is a previous run's, and the released copy is
  # preferred only where this run ran the release module - otherwise the
  # rebuilt raw table is this run's and the released one is not.
  if (!scenario_wrote(scenario, table)) return(NULL)
  prefer_release <- prefer_release && scenario_wrote(scenario, paste0(table, "_RELEASE"))
  same <- function() {
    m <- scenario_matches_now(src, scenario)
    # Unanswerable two ways: a scenario that recorded no run is not bound and
    # reads freely; one that did, over a prefix whose metadata cannot be read
    # now, is refused - a run that cannot be shown to be there is not there.
    if (is.na(m)) !nzchar(trimws(scenario$run_id %||% "")) else m
  }
  if (!same()) return(NULL)
  d <- read_table(src, scenario$prefix, table, prefer_release)
  if (!same()) return(NULL)
  restrict_to_cohorts(d, scenario)
}

# The metadata row a prefix holds RIGHT NOW, as opposed to the one read at
# startup: the newest by UPDATED_AT, or the last one written.
#
# The scenarios are loaded once, when the app starts; a table is read when a
# viewer opens a panel. A refresh in between replaces the snapshot, and the
# page then shows the new run's rows under the old run's metadata - the
# settings the sidebar names, the LOT run the Compare tab checks - with
# nothing saying so.
newest_metadata_row <- function(src, prefix) {
  md <- tryCatch(src$read(prefix, "S_RUN_METADATA"), error = function(e) NULL)
  if (is.null(md) || !nrow(md) || !"RUN_ID" %in% names(md)) return(NULL)
  if ("UPDATED_AT" %in% names(md))
    md <- md[order(md$UPDATED_AT, decreasing = TRUE), , drop = FALSE]
  md[1, , drop = FALSE]
}

current_run_id <- function(src, prefix) {
  r <- newest_metadata_row(src, prefix)
  if (is.null(r)) NA_character_ else trimws(as.character(r$RUN_ID[1]))
}

# The fields every reader binds a run by, off one metadata row: the id, and
# the state and timestamp that tell one BUILD under that id from another.
run_identity <- function(row) {
  g <- function(k) {
    v <- if (!is.null(row) && k %in% names(row)) row[[k]] else NULL
    # Absent, NULL, empty and NA all read as "not recorded".
    if (!length(v) || is.na(v[1])) "" else trimws(as.character(v[1]))
  }
  list(run_id = g("RUN_ID"), state = g("STATE"), updated_at = g("UPDATED_AT"))
}

# Is the build under this prefix, right now, the one the scenario describes?
#
# By id, and by state and timestamp where the scenario recorded them. A run
# id is not a build: the study package reuses DOMINO_RUN_ID for every build
# inside one Domino run, so a re-run keeps the id while its state goes to
# `started` and back and its UPDATED_AT moves. Bound by id alone, the page
# showed the re-run's rows - first a build still going, then a finished one
# with possibly different settings - under the earlier build's metadata.
#
# NA where it cannot be said: the scenario records no run, or the prefix has
# no metadata to read. The same answer same_lot_run() gives.
scenario_matches_now <- function(src, scenario) {
  was <- run_identity(list(RUN_ID = scenario$run_id, STATE = scenario$state,
                           UPDATED_AT = scenario$updated_at))
  if (!nzchar(was$run_id)) return(NA)
  row <- newest_metadata_row(src, scenario$prefix)
  if (is.null(row)) return(NA)
  now <- run_identity(row)
  if (!nzchar(now$run_id) || !identical(now$run_id, was$run_id)) return(FALSE)
  for (k in c("state", "updated_at"))
    if (nzchar(was[[k]]) && !identical(now[[k]], was[[k]])) return(FALSE)
  TRUE
}

# Is this scenario still the build the app read at startup?
scenario_is_current <- function(src, scenario) scenario_matches_now(src, scenario)

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

# Do two scenarios rest on the SAME lines?
#
# The question the Compare tab has to answer before it draws a difference. Two
# scenarios sharing a LOT run differ only in what this package did; two reading
# different runs differ in the lines as well, and a delta between them carries
# both without saying so.
#
# The same run id under two BUILDS is two sets of lines as surely as two ids
# are, so where both scenarios recorded which build they read, the builds
# have to match too. Where only one did, it cannot be said - NA, like a
# missing id - rather than claimed.
same_lot_run <- function(a, b) {
  ra <- trimws(a$lot_run_id %||% ""); rb <- trimws(b$lot_run_id %||% "")
  if (!nzchar(ra) || !nzchar(rb)) return(NA)
  if (!identical(ra, rb)) return(FALSE)
  va <- trimws(a$lot_run_version %||% ""); vb <- trimws(b$lot_run_version %||% "")
  if (nzchar(va) != nzchar(vb)) return(NA)
  identical(va, vb)
}
