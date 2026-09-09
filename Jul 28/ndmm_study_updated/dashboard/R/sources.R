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
      d <- d[nzchar(d)]
      if (length(cfg$prefixes)) intersect(d, cfg$prefixes) else d
    },
    read = function(prefix, table) {
      p <- file.path(root, prefix, paste0(table, ".csv"))
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
               error = function(e) NULL))
}

# --- synthetic --------------------------------------------------------------
synthetic_source <- function(cfg) {
  data <- synthetic_scenarios(cfg)
  list(
    kind = "synthetic", synthetic = TRUE, origin = "generated in-process",
    prefixes = function() names(data),
    read = function(prefix, table) data[[prefix]][[table]])
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

mark_source <- function(d, which) { attr(d, "table_source") <- which; d }

SUPPRESSION_SPEC_NAMES <- function() {
  if (!exists("SUPPRESSION_SPEC")) return(character(0))
  stats::setNames(as.list(paste0(names(SUPPRESSION_SPEC), "_RELEASE")),
                  paste0(names(SUPPRESSION_SPEC), "_RELEASE"))
}
