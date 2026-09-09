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
    # LOT tables sit under lot/<LOT_RUN_ID>/, not under a scenario. Several
    # scenarios normally read ONE LOT run, and a copy per scenario would both
    # waste the space and suggest they differ.
    read_lot = function(lot_run_id, table) {
      if (!safe_segment(lot_run_id) || !safe_segment(table)) return(NULL)
      p <- file.path(root, "lot", lot_run_id, paste0(table, ".csv"))
      if (!file.exists(p)) return(NULL)
      utils::read.csv(p, stringsAsFactors = FALSE, check.names = FALSE,
                      na.strings = c("", "NA"))
    })
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
  lot_ok <- function(lot_run_id)
    lot_status_owner(tryCatch(db_q(con, sprintf("SELECT * FROM %s",
                                     full(cfg$lot_prefix, "LOT_BUILD_STATUS"))),
                              error = function(e) NULL),
                     lot_run_id, cfg$lot_prefix)
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
    lot_run_ok = function(lot_run_id) lot_ok(lot_run_id),
    read_lot = function(lot_run_id, table) {
      if (!nzchar(cfg$lot_prefix)) return(NULL)
      # Fails closed. A run that cannot be shown to be the one under this
      # prefix is not read: an unbound LOT table is another build's numbers
      # under this scenario's label.
      if (!lot_ok(lot_run_id)) return(NULL)
      d <- tryCatch(db_q(con, sprintf("SELECT * FROM %s",
                                      full(cfg$lot_prefix, table))),
                    error = function(e) NULL)
      if (is.null(d)) return(NULL)
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
    read_lot = function(lot_run_id, table)
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

# Whether the NEWEST row of a LOT_BUILD_STATUS table names this run, complete.
#
# Pure, so the warehouse reader and the snapshot exporter decide ownership the
# same way, and a test can drive it with a frame. Newest by UPDATED_AT where
# the table carries it; otherwise the last row written.
lot_status_owner <- function(st, lot_run_id, lot_prefix = "x") {
  id <- trimws(lot_run_id %||% "")
  if (!nzchar(id) || !nzchar(lot_prefix %||% "")) return(FALSE)
  if (is.null(st) || !nrow(st) || !all(c("RUN_ID", "STATE") %in% names(st)))
    return(FALSE)
  o <- if ("UPDATED_AT" %in% names(st))
    order(as.character(st$UPDATED_AT), decreasing = TRUE) else rev(seq_len(nrow(st)))
  newest <- st[o[1], , drop = FALSE]
  identical(trimws(as.character(newest$RUN_ID)), id) &&
    identical(tolower(trimws(as.character(newest$STATE))), "complete")
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
read_scenario_table <- function(src, scenario, table, prefer_release = TRUE) {
  was <- trimws(scenario$run_id %||% "")
  same <- function() {
    now <- current_run_id(src, scenario$prefix)
    !nzchar(was) || (!is.na(now) && identical(now, was))
  }
  if (!same()) return(NULL)
  d <- read_table(src, scenario$prefix, table, prefer_release)
  if (!same()) return(NULL)
  d
}

# The run a prefix holds RIGHT NOW, as opposed to the one read at startup.
#
# The scenarios are loaded once, when the app starts; a table is read when a
# viewer opens a panel. A refresh in between replaces the snapshot, and the
# page then shows the new run's rows under the old run's metadata - the
# settings the sidebar names, the LOT run the Compare tab checks - with
# nothing saying so.
current_run_id <- function(src, prefix) {
  md <- tryCatch(src$read(prefix, "S_RUN_METADATA"), error = function(e) NULL)
  if (is.null(md) || !nrow(md) || !"RUN_ID" %in% names(md)) return(NA_character_)
  if ("UPDATED_AT" %in% names(md))
    md <- md[order(md$UPDATED_AT, decreasing = TRUE), , drop = FALSE]
  trimws(as.character(md$RUN_ID[1]))
}

# Is this scenario still the run the app read at startup? NA where neither
# side records a run, which is the same answer same_lot_run() gives.
scenario_is_current <- function(src, scenario) {
  was <- trimws(scenario$run_id %||% "")
  now <- current_run_id(src, scenario$prefix)
  if (!nzchar(was) || is.na(now) || !nzchar(now)) return(NA)
  identical(was, now)
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
  src$read_lot(scenario$lot_run_id, table)
}

# Whether a source can bind this scenario's LOT run at all, for a panel that
# has to say WHY it is empty. A source that does not bind runs (the snapshot
# keys them by directory, so it already has) answers TRUE.
lot_run_bound <- function(src, scenario) {
  if (is.null(src$lot_run_ok)) return(TRUE)
  isTRUE(src$lot_run_ok(scenario$lot_run_id))
}

# Do two scenarios rest on the SAME lines?
#
# The question the Compare tab has to answer before it draws a difference. Two
# scenarios sharing a LOT run differ only in what this package did; two reading
# different runs differ in the lines as well, and a delta between them carries
# both without saying so.
same_lot_run <- function(a, b) {
  ra <- trimws(a$lot_run_id %||% ""); rb <- trimws(b$lot_run_id %||% "")
  if (!nzchar(ra) || !nzchar(rb)) return(NA)
  identical(ra, rb)
}
