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

TFLS_R_FILES <- c("classes.R", "shells.R", "names.R", "stats.R", "suppress.R",
                  "fill.R", "scope.R", "render.R")
for (f in TFLS_R_FILES) source(file.path(.script_dir, "R", f))

env_chr <- function(nm, unset = "") trimws(Sys.getenv(nm, unset = unset))
env_flag <- function(nm) identical(toupper(env_chr(nm)), "TRUE")

shells_dir <- file.path(.script_dir, "shells")

# Where the finished tables are written. Beside the script by default, which is
# right when a person runs this and reads out/ next to the shells they filled.
#
# TFLS_OUT_DIR moves it, and on a platform that captures one directory as a
# run's results it has to: a file written beside the code is not an output
# there, it is a file in the code tree that the next sync overwrites or drops.
# On Domino that directory is /mnt/artifacts/results, which is also where the
# LOT engine's OUTPUT_DIR points by default.
out_dir <- {
  d <- env_chr("TFLS_OUT_DIR")
  if (nzchar(d)) d else file.path(.script_dir, "out")
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
        else paste0(paste(cats, collapse = "; "),
                    if (nzchar(class_requires_drug(sh$classes$class_id[i], sh$classes)))
                      paste0(", narrowed to the lines holding ",
                             class_requires_drug(sh$classes$class_id[i], sh$classes))
                    else ""), "\n", sep = "")
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
# frame or NULL, over whatever sits under the prefix. Which of that is this
# run's is not theirs to decide: run_reader() in R/scope.R binds them to the
# run's own declaration, and nothing here is handed to a fill unwrapped.

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
  function(table) {
    if (!safe_segment(prefix) || !safe_segment(table)) return(NULL)
    p <- file.path(root, prefix, paste0(table, ".csv"))
    if (!file.exists(p) && nzchar(lot_dir) && safe_segment(lot_dir))
      p <- file.path(root, "lot", lot_dir, paste0(table, ".csv"))
    if (!file.exists(p)) return(NULL)
    utils::read.csv(p, stringsAsFactors = FALSE, check.names = FALSE,
                    na.strings = c("", "NA"))
  }
}

# What a read failed with, by table, for the messages that would otherwise say
# only that nothing came back.
#
# Per READER, not per process. One environment shared by the whole session
# would carry a failure from one bind into the next: source this file twice, or
# call main() twice, and a stale S_RUN_METADATA error gets reported against a
# later prefix whose metadata is simply absent - a wrong diagnosis, which is
# the exact fault this record was added to fix.
read_error <- function(reader, table) {
  e <- attr(reader, "read_errors")
  t <- toupper(chr(table))
  if (is.null(e) || !exists(t, envir = e, inherits = FALSE)) "" else
    get(t, envir = e, inherits = FALSE)
}

warehouse_reader <- function(con, catalog, schema, prefix, cohort_table = "") {
  read_errors <- new.env(parent = emptyenv())
  f <- function(table) {
    # The input cohort table is not one of the run's outputs and carries no
    # prefix: it is read only where the run was told where it is, and it comes
    # already qualified, so it is quoted part by part.
    #
    # The prefix and the table are ONE identifier - "s223926_S_SAFETY_RATES" -
    # so those two are quoted together.
    full <- if (toupper(table) %in% TFLS_COHORT_TABLE_NAMES) {
      if (!nzchar(cohort_table)) return(NULL)
      sql_qualified_name(cohort_table)
    } else {
      q <- c(sql_name(catalog), sql_name(schema),
             sql_name(paste0(prefix, table)))
      if (anyNA(q)) NA_character_ else paste(q, collapse = ".")
    }
    if (is.na(full)) return(NULL)
    # The error is kept, not only the NULL. A read that fails and a table that
    # is not there are different problems with the same empty answer, and
    # swallowing the first makes it look like the second - which sends the
    # reader to check a table name that was never the trouble.
    tryCatch(db_q(con, sprintf("SELECT * FROM %s", full)),
             error = function(e) {
               assign(toupper(chr(table)), paste0(full, ": ",
                      conditionMessage(e)), envir = read_errors)
               NULL
             })
  }
  attr(f, "read_errors") <- read_errors
  f
}

# The run these shells are filled from: its metadata row, and the two checks
# that make it one to read.
#
# The state, because a run's metadata row is written before its tables are
# replaced, so under a `started` or `failed` run the tables are the previous
# build's or part of this one. And its own declaration, because a prefix holds
# whatever every run before this one left under it: a run that recorded no
# modules, or no cohorts, can vouch for none of it.
bind_run <- function(reader, where) {
  raw <- reader("S_RUN_METADATA")
  md <- newest_row(raw)
  if (is.null(md)) {
    why <- read_error(reader, "S_RUN_METADATA")
    if (nzchar(why))
      stop("S_RUN_METADATA under ", where, " could not be read, so there is ",
           "no run to fill these shells from. The read failed with:\n  ", why,
           call. = FALSE)
    if (!is.null(raw))
      stop("S_RUN_METADATA under ", where, " is there and has no rows, so ",
           "there is no run to fill these shells from. A prefix with an empty ",
           "metadata table is one whose study run has not finished writing.",
           call. = FALSE)
  }
  if (is.null(md))
    stop("No S_RUN_METADATA under ", where, ", so there is no run to fill ",
         "these shells from.", call. = FALSE)
  state <- row_field(md, "STATE")
  if (!identical(state, "complete"))
    stop("The run under ", where, " is '", state, "', not complete, so its ",
         "tables may be the previous build's or part of this one. Nothing ",
         "was filled.", call. = FALSE)
  scope <- run_scope(md)
  missing <- c(if (!length(scope$modules)) "MODULES",
               if (!length(scope$cohorts)) "COHORTS")
  if (length(missing))
    stop("The run under ", where, " records no ",
         paste(missing, collapse = " and no "), ", so nothing under this ",
         "prefix can be shown to be its own rather than a previous run's. ",
         "Nothing was filled.", call. = FALSE)
  md
}

# --- the run ----------------------------------------------------------------

write_outputs <- function(filled, sh, floor_n, run_id) {
  dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
  # Remove the files THIS tool owns before writing, so the directory holds one
  # run's output and not two runs' mixed.
  #
  # Drop a table from tables.csv and its tfls_<id>.csv stays behind, identical
  # in shape to the ones beside it and belonging to a shell set that no longer
  # exists - and nothing on it says which run wrote it. Only the tool's own
  # filename pattern is touched: whatever else a person has put in this
  # directory is theirs.
  old <- list.files(out_dir, pattern = "^tfls_.*[.]csv$|^tfls[.]md$",
                    full.names = TRUE)
  if (length(old)) {
    ok <- file.remove(old)
    if (!all(ok))
      stop("Could not clear the previous output in ", out_dir, ": ",
           paste(basename(old[!ok]), collapse = ", "), ". Writing over part ",
           "of it would leave one run's tables beside another's.",
           call. = FALSE)
  }
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
    scope <- run_scope(md)
    # The lines sit under their own run, not under this one, so reading them
    # needs the build this run recorded reading.
    reader <- run_reader(
      snapshot_reader(root, prefix, lot_dir_name(row_field(md, "LOT_RUN_ID"),
                                                 row_field(md, "LOT_RUN_VERSION"))),
      scope)
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
    # These three are warehouse names and nothing else - no path is built from
    # them - so each is gated on whether quoting can hold it rather than on a
    # pattern, which would refuse names this warehouse takes.
    if (is.na(sql_name(schema)))
      stop("PROJECT_WORK_SCHEMA '", schema, "' cannot be quoted as a name.",
           call. = FALSE)
    catalog <- env_chr("TFLS_CATALOG", unset = "hive_metastore")
    if (is.na(sql_name(catalog)))
      stop("TFLS_CATALOG '", catalog, "' cannot be quoted as a name.",
           call. = FALSE)
    cohort_table <- env_chr("TFLS_COHORT_TABLE")
    if (nzchar(cohort_table) && is.na(sql_qualified_name(cohort_table)))
      stop("TFLS_COHORT_TABLE '", cohort_table, "' is not one to three ",
           "quotable name parts.", call. = FALSE)
    library(DBI); library(odbc)
    for (f in c("config_223926.R", "db_utils_223926.R"))
      source(file.path(pkg, "R", f))
    # cfg_defaults() is a function in the study package, not a list. Taking
    # it unevaluated made every warehouse run fail on the next line.
    cfg <- cfg_defaults()
    cfg$work_schema <- schema
    cfg$catalog <- catalog
    if (!nzchar(chr(cfg$pwd)))
      stop("DATABRICKS_PWD environment variable is not set.", call. = FALSE)
    con <- connect_db(cfg)
    on.exit(try(disconnect_db(con), silent = TRUE), add = TRUE)
    where <- sprintf("%s.%s.%s", catalog, schema, prefix)
    under_prefix <- warehouse_reader(con, catalog, schema, prefix, cohort_table)
    md <- bind_run(under_prefix, where)
    scope <- run_scope(md)
    reader <- run_reader(under_prefix, scope)
    recheck <- function()
      bind_run(warehouse_reader(con, catalog, schema, prefix), where)
  }

  run_id <- row_field(md, "RUN_ID")
  pinned <- run_identity(md)
  cat("\nRun ", run_id, " under ", where, "\n", sep = "")
  # What binds every read below. A prefix holds what earlier runs left under
  # it, so the cohorts and modules this run declared are printed beside its id:
  # a row reported unfilled against them is read against what is on the screen.
  cat("  built   ", paste(scope$cohorts, collapse = ", "), " with the module(s) ",
      run_modules_text(scope), "; every other table and cohort under this ",
      "prefix is a previous run's and reads as absent\n", sep = "")
  # The run's own verdict on its release, said out loud before a shell is
  # filled. These tables are what a study hands out, so what the source could
  # not close belongs on the screen and not only in the unfilled list.
  local({
    blocked <- release_verdict(scope)
    no_go <- release_refused(scope)
    if (identical(blocked, TFLS_RELEASE_NOT_RECORDED))
      cat("  release this run kept no record of what its release left ",
          "recoverable. The snapshot job is the gate for that; re-exporting ",
          "through it is what settles it\n", sep = "")
    else if (!nzchar(blocked))
      cat("  release its release left no withheld cell that the rest of its ",
          "group gives away\n", sep = "")
    else if (tfls_allow_recoverable())
      cat("  release TFLS_ALLOW_RECOVERABLE is on, so ", length(no_go),
          " table(s) are filled from anyway: ", paste(no_go, collapse = ", "),
          ". The run says: ", blocked, "\n", sep = "")
    else
      cat("  release ", length(no_go), " table(s) are NOT read, and the rows ",
          "resting on them are reported unfilled: ",
          paste(no_go, collapse = ", "), ". The run says: ", blocked, "\n",
          sep = "")
  })

  ctx <- fill_context(reader, sh$classes,
                      tte_eligible_only = env_flag("TFLS_TTE_ELIGIBLE_ONLY"),
                      absent_why = function(table) {
                        # The reader's own refusal first: it knows things the
                        # status cannot, such as a declared release that is
                        # not under the prefix.
                        r <- reader_refusal(reader, table)
                        if (nzchar(r)) r else run_table_status(scope, table)$why
                      })
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
