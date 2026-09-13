#!/usr/bin/env Rscript
# Fill the table shells from a finished study run.
#
#   # list the shells and what each row would read; no connection
#   Rscript TFLS/run_tfls.R
#
#   # fill them from a snapshot
#   TFLS_SOURCE=snapshot TFLS_SNAPSHOT_DIR=/mnt/data/NDMM TFLS_PREFIX=s223926_ \
#     Rscript TFLS/run_tfls.R
#
#   # or straight from the warehouse
#   TFLS_SOURCE=warehouse DATABRICKS_PWD=... PROJECT_WORK_SCHEMA=... \
#     TFLS_PACKAGE_DIR=... TFLS_PREFIX=s223926_ Rscript TFLS/run_tfls.R
#
# Reads only. The tables land in out/: one CSV per table, tfls.md holding all
# of them, and tfls_unfilled.csv naming every row nothing could fill and why.
#
#   TFLS_SOURCE        snapshot or warehouse. Unset lists the shells and stops.
#   TFLS_SNAPSHOT_DIR  the snapshot root, whose <prefix>/<TABLE>.csv is read
#   TFLS_PREFIX        which run: the prefix its tables were written under
#   TFLS_MIN_N         a floor at or above the protocol's 25; it may only raise
#   TFLS_CATALOG       warehouse catalog (default hive_metastore)
#   TFLS_PACKAGE_DIR   the study package directory, for its own connection
#   TFLS_COHORT_TABLE  warehouse only: the input cohort table, which carries
#                      the diagnosis date that no study output does
#   TFLS_TTE_ELIGIBLE_ONLY  TRUE restricts every curve to TTE_ELIGIBLE = 1.
#                      Off by default: the study writes the whole cohort and
#                      leaves the restriction to the reader, so applying it is
#                      a decision and the caption says which way it was made.
#
# Exit status is 0 when the tables were written, or when the shells were only
# listed, and 1 when something stopped it.

.script_dir <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  # Rscript renders a space in a path as ~+~, so a folder with one in its name
  # resolves to nothing without this.
  if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                            fixed = TRUE))) else getwd()
})

TFLS_R_FILES <- c("classes.R", "shells.R", "stats.R", "suppress.R", "fill.R",
                  "render.R")
for (f in TFLS_R_FILES) source(file.path(.script_dir, "R", f))

shells_dir <- file.path(.script_dir, "shells")
out_dir <- file.path(.script_dir, "out")

env_chr <- function(nm, unset = "") trimws(Sys.getenv(nm, unset = unset))
env_flag <- function(nm) identical(toupper(env_chr(nm)), "TRUE")

# A name that may be used as one path segment or one table name, and nothing
# else. A prefix is pasted into a file path and into a table name, so one
# holding a slash or a quote would read something other than what was asked
# for. Refused rather than repaired.
safe_segment <- function(x) {
  x <- chr(x)
  length(x) == 1L && nzchar(x) && grepl("^[A-Za-z0-9][A-Za-z0-9._-]*$", x)
}

# A warehouse table name: one to three plain segments separated by dots.
safe_table_name <- function(x) {
  parts <- strsplit(chr(x), ".", fixed = TRUE)[[1]]
  length(parts) >= 1L && length(parts) <= 3L &&
    all(vapply(parts, safe_segment, logical(1)))
}

need_env <- function(nm, why) {
  v <- env_chr(nm)
  if (!nzchar(v)) stop("No ", nm, ". ", why, call. = FALSE)
  v
}

# --- the plan ---------------------------------------------------------------

report_plan <- function(sh, floor_n) {
  cat("\nThe requested table shells, filled from a finished study run.\n\n")
  cat("  shells  ", shells_dir, "\n", sep = "")
  cat("  floor   ", floor_n, " (TFLS_MIN_N may raise it, never lower it)\n", sep = "")
  cat("  curves  ", if (env_flag("TFLS_TTE_ELIGIBLE_ONLY"))
      "over TTE_ELIGIBLE = 1 (TFLS_TTE_ELIGIBLE_ONLY is on)"
      else "over every row of the time-to-event table (TFLS_TTE_ELIGIBLE_ONLY is off)",
      "\n", sep = "")
  cat("  writes  ", file.path(out_dir, "tfls_<table>.csv"), ",\n",
      "          tfls.md and tfls_unfilled.csv beside them\n", sep = "")
  cat("  classes ", nrow(sh$classes), " in regimen_classes.csv, each a ",
      "heading over the study's own SOC categories:\n", sep = "")
  for (i in seq_len(nrow(sh$classes))) {
    cats <- class_categories(sh$classes$class_id[i], sh$classes)
    cat("    ", sh$classes$class_id[i], "  ",
        if (class_is_overall(sh$classes$class_id[i]))
          "every line in the column's population"
        else if (!length(cats))
          "no SOC category: every cell in this column is reported unfilled"
        else paste(cats, collapse = "; "), "\n", sep = "")
  }
  for (tid in shell_table_ids(sh)) {
    cols <- shell_columns_of(sh, tid); rows <- shell_rows_of(sh, tid)
    meta <- sh$tables[sh$tables$table_id == tid, , drop = FALSE]
    cat("\n", tid, "  ", chr(meta$title[1]), "\n", sep = "")
    cat("  ", nrow(cols), " column(s), ", nrow(rows), " row(s), ",
        nrow(shell_footnotes_of(sh, tid)), " footnote(s)\n", sep = "")
    for (i in seq_len(nrow(cols)))
      cat("    col ", cols$order_n[i], "  ", chr(cols$label[i]), " - ",
          column_population_label(cols[i, , drop = FALSE], sh$classes), "\n",
          sep = "")
    for (i in seq_len(nrow(rows)))
      cat("    row ", rows$order_n[i], "  ",
          strrep("  ", rows$indent_n[i]), chr(rows$label[i]), " - ",
          row_reads_label(rows[i, , drop = FALSE]), "\n", sep = "")
  }
  srcs <- sort(unique(chr(sh$rows$source)))
  srcs <- srcs[nzchar(srcs)]
  cat("\n  in total it would read: ", paste(srcs, collapse = ", "), "\n",
      sep = "")
}

# --- sources ----------------------------------------------------------------
#
# Two of them, one interface: a function of a table name that gives back a data
# frame or NULL. Where the package published a released copy of a table, that
# is what is read, so the suppression is the package's own and not a second
# opinion of it.

release_first <- function(read_one) function(table) {
  table <- toupper(chr(table))
  if (!grepl("_RELEASE$", table)) {
    rel <- read_one(paste0(table, "_RELEASE"))
    if (!is.null(rel) && nrow(rel)) return(rel)
  }
  read_one(table)
}

# Where a build's lines are filed in a snapshot: by run id, and by build where
# the run recorded one. The engine keeps one run id for a session, so an id can
# name two builds and a directory named by run alone holds whichever was
# exported last.
lot_dir_name <- function(run_id, version = "") {
  id <- chr(run_id); v <- chr(version)
  if (nzchar(v)) paste0(id, ".", v) else id
}

# <dir>/<prefix>/<TABLE>.csv, which is the layout a snapshot job writes. The
# lines sit under lot/<run>[.<build>]/ instead, because several runs normally
# read one build of them and a copy per run would suggest they differ.
snapshot_reader <- function(root, prefix, lot_dir = "") {
  read_one <- function(table) {
    if (!safe_segment(prefix) || !safe_segment(table)) return(NULL)
    p <- file.path(root, prefix, paste0(table, ".csv"))
    if (!file.exists(p) && nzchar(lot_dir) && safe_segment(lot_dir))
      p <- file.path(root, "lot", lot_dir, paste0(table, ".csv"))
    if (!file.exists(p)) return(NULL)
    utils::read.csv(p, stringsAsFactors = FALSE, check.names = FALSE,
                    na.strings = c("", "NA"))
  }
  release_first(read_one)
}

warehouse_reader <- function(con, catalog, schema, prefix, cohort_table = "") {
  read_one <- function(table) {
    if (!safe_segment(table) || !safe_segment(prefix)) return(NULL)
    # The input cohort table is not one of the run's outputs and carries no
    # prefix: it is read only where the run was told where it is.
    full <- if (toupper(table) %in% TFLS_COHORT_TABLE_NAMES) {
      if (!nzchar(cohort_table)) return(NULL)
      cohort_table
    } else sprintf("%s.%s.%s%s", catalog, schema, prefix, table)
    tryCatch(db_q(con, sprintf("SELECT * FROM %s", full)),
             error = function(e) NULL)
  }
  release_first(read_one)
}

# The newest row of a metadata table: by UPDATED_AT where it carries one,
# otherwise the last row written.
newest_row <- function(df) {
  if (is.null(df) || !nrow(df)) return(NULL)
  o <- if ("UPDATED_AT" %in% names(df))
    order(as.character(df$UPDATED_AT), decreasing = TRUE) else rev(seq_len(nrow(df)))
  df[o[1], , drop = FALSE]
}

row_field <- function(row, nm)
  if (is.null(row) || !nm %in% names(row)) "" else chr(row[[nm]][1])

# The identity a run is bound by: the id, and the state and timestamp that tell
# one build under that id from another. A run id is not a build - the same id
# is kept for every build inside one session - so all three are compared.
run_identity <- function(row)
  paste(row_field(row, "RUN_ID"), row_field(row, "STATE"),
        row_field(row, "UPDATED_AT"), sep = "\r")

bind_run <- function(reader, where) {
  md <- newest_row(reader("S_RUN_METADATA"))
  if (is.null(md))
    stop("No S_RUN_METADATA under ", where, ", so there is no run to fill ",
         "these shells from.", call. = FALSE)
  state <- row_field(md, "STATE")
  if (!identical(state, "complete"))
    stop("The run under ", where, " is '", state, "', not complete, so its ",
         "tables may be the previous build's or part of this one. Nothing ",
         "was filled.", call. = FALSE)
  md
}

# --- the run ----------------------------------------------------------------

write_outputs <- function(filled, sh, floor_n, run_id) {
  dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
  for (f in filled)
    tfls_write_csv(render_csv(f),
                   file.path(out_dir, paste0("tfls_", f$table_id, ".csv")))
  md <- render_all_markdown(filled, sh)
  md <- append(md, c(paste0("Run ", run_id, ", floor ", floor_n, "."), ""),
               after = 2L)
  writeLines(md, file.path(out_dir, "tfls.md"))
  unf <- all_unfilled(filled)
  tfls_write_csv(unf, file.path(out_dir, "tfls_unfilled.csv"))
  n_cells <- sum(vapply(filled, function(f) sum(f$cells$SECTION == 0L), integer(1)))
  n_supp <- sum(vapply(filled, function(f)
    sum(f$cells$SECTION == 0L & f$cells$SUPPRESSED == 1L), integer(1)))
  cat("  filled ", length(filled), " table(s), ", n_cells, " cell(s); ",
      n_supp, " withheld at the floor of ", floor_n, "; ", nrow(unf),
      " row/column pair(s) could not be filled\n", sep = "")
  if (nrow(unf))
    for (k in TFLS_REASON_KINDS) {
      n <- sum(unf$REASON_KIND == k)
      if (n) cat("    ", n, " ", k, "\n", sep = "")
    }
  cat("Wrote ", out_dir, ".\n", sep = "")
}

main <- function() {
  floor_n <- tfls_floor_from_env()
  sh <- tryCatch(load_shells(shells_dir), tfls_missing_shells = function(e) e)
  if (inherits(sh, "condition")) {
    # The shells are the delivery; without them there is nothing to list and
    # nothing to fill, and saying so is not the same as failing to read a run.
    cat("\n", conditionMessage(sh), "\n", sep = "")
    cat("Nothing was read.\n")
    return(invisible(NULL))
  }
  report_plan(sh, floor_n)

  src <- tolower(env_chr("TFLS_SOURCE"))
  if (!nzchar(src)) {
    cat("\nNothing was read. Set TFLS_SOURCE=snapshot or TFLS_SOURCE=warehouse",
        " to fill these.\n", sep = "")
    return(invisible(NULL))
  }
  if (!src %in% c("snapshot", "warehouse"))
    stop("TFLS_SOURCE='", src, "' is not one of snapshot, warehouse.",
         call. = FALSE)

  prefix <- need_env("TFLS_PREFIX",
    "It is what names the run's tables, so without it this would fill the shells from whatever is there.")
  if (!safe_segment(prefix))
    stop("TFLS_PREFIX '", prefix, "' is not a plain name, and it is pasted ",
         "into a path and a table name.", call. = FALSE)

  options(scipen = 999)
  if (identical(src, "snapshot")) {
    root <- need_env("TFLS_SNAPSHOT_DIR",
                     "It is the directory the run's tables were exported to.")
    if (!dir.exists(root))
      stop("TFLS_SNAPSHOT_DIR '", root, "' is not a directory.", call. = FALSE)
    where <- file.path(root, prefix)
    md <- bind_run(snapshot_reader(root, prefix), where)
    # The lines sit under their own run, not under this one, so reading them
    # needs the build this run recorded reading.
    reader <- snapshot_reader(root, prefix,
                              lot_dir_name(row_field(md, "LOT_RUN_ID"),
                                           row_field(md, "LOT_RUN_VERSION")))
    recheck <- function() bind_run(snapshot_reader(root, prefix), where)
  } else {
    # Nothing above this line needs a driver, so the plan prints on a machine
    # that has none. The connection is opened only once the run is asked for.
    pkg <- need_env("TFLS_PACKAGE_DIR",
      "It is the study package directory, whose own connection is used so this cannot connect differently from the runs it reads.")
    if (!dir.exists(file.path(pkg, "R")))
      stop("TFLS_PACKAGE_DIR '", pkg, "' holds no R/ directory.", call. = FALSE)
    schema <- need_env("PROJECT_WORK_SCHEMA",
                       "It is the schema the run wrote its tables into.")
    if (!safe_segment(schema))
      stop("PROJECT_WORK_SCHEMA '", schema, "' is not a plain name.",
           call. = FALSE)
    catalog <- env_chr("TFLS_CATALOG", unset = "hive_metastore")
    if (!safe_segment(catalog))
      stop("TFLS_CATALOG '", catalog, "' is not a plain name.", call. = FALSE)
    cohort_table <- env_chr("TFLS_COHORT_TABLE")
    if (nzchar(cohort_table) && !safe_table_name(cohort_table))
      stop("TFLS_COHORT_TABLE '", cohort_table, "' is not a plain table name.",
           call. = FALSE)
    library(DBI); library(odbc)
    for (f in c("config_223926.R", "db_utils_223926.R"))
      source(file.path(pkg, "R", f))
    cfg <- cfg_defaults
    cfg$work_schema <- schema
    cfg$catalog <- catalog
    if (!nzchar(chr(cfg$pwd)))
      stop("DATABRICKS_PWD environment variable is not set.", call. = FALSE)
    con <- connect_db(cfg)
    on.exit(try(disconnect_db(con), silent = TRUE), add = TRUE)
    reader <- warehouse_reader(con, catalog, schema, prefix, cohort_table)
    where <- sprintf("%s.%s.%s", catalog, schema, prefix)
    md <- bind_run(reader, where)
    recheck <- function()
      bind_run(warehouse_reader(con, catalog, schema, prefix), where)
  }

  run_id <- row_field(md, "RUN_ID")
  pinned <- run_identity(md)
  cat("\nRun ", run_id, " under ", where, "\n", sep = "")

  ctx <- fill_context(reader, sh$classes,
                      tte_eligible_only = env_flag("TFLS_TTE_ELIGIBLE_ONLY"))
  cat("  curves  ", if (env_flag("TFLS_TTE_ELIGIBLE_ONLY"))
      "over TTE_ELIGIBLE = 1 (TFLS_TTE_ELIGIBLE_ONLY is on)"
      else paste0("over every row of the time-to-event table; TTE_ELIGIBLE is ",
                  "applied only where a shell row's own filter names it"),
      "\n", sep = "")
  filled <- fill_all(sh, ctx, floor_n)

  # Still the same build. A re-run under this prefix while its tables were
  # being read would leave the tables half from one build and half from the
  # next, and the document would name the pinned run while showing another
  # build's numbers. Asked before anything is written, so a run that lost its
  # build leaves the previous output on disk rather than half-replacing it.
  if (!identical(run_identity(recheck()), pinned))
    stop("The run under ", where, " changed while its tables were being read, ",
         "so what was read is not one build's. Nothing was written.",
         call. = FALSE)

  write_outputs(filled, sh, floor_n, run_id)
}

if (!interactive()) {
  out <- tryCatch(main(), error = function(e) e)
  if (inherits(out, "error")) {
    cat("\nERROR: ", conditionMessage(out), "\n", sep = "")
    quit(status = 1L)
  }
}
