# The parts of jobs/build_scenarios.R a test can drive.
#
# The job itself is a script: it reads a grid, starts a child R process per
# row and connects to a warehouse, so nothing in it could be reached from the
# suite. What the review found wrong was in these three pieces - which
# settings the export runs under, what a read that came back empty means, and
# when a snapshot becomes visible - so they live here and the job sources
# them. Same reason panel_table_html() left app.R's server.

# The settings this row runs under. Computed once and given to BOTH the build
# and the export, because they have to be the same settings: the export used
# to rebuild the configuration with only OBJECT_PREFIX changed, so a row
# setting WORK_SCHEMA or LOT_PREFIX built in one place and read from another,
# and the CSVs published under that scenario were the parent's tables.
# `set_cols` defaults to the row's own upper-case names, which is the job's
# convention for "this column is a setting". Passed in by the job so the grid
# decides once; defaulted here so the function stands on its own.
scenario_env <- function(row,
                         set_cols = grep("^[A-Z][A-Z0-9_]*$", names(row),
                                         value = TRUE)) {
  env <- character(0)
  for (k in set_cols) {
    v <- trimws(as.character(row[[k]]))
    if (nzchar(v) && !identical(v, "NA")) env[[k]] <- v
  }
  env[["OBJECT_PREFIX"]] <- trimws(row[["prefix"]])
  env
}

# One table, read back. Three outcomes, and they are NOT the same:
#
#   ok      rows, or a table that legitimately holds none
#   absent  the table was never written - an optional module was not selected
#   failed  the read itself errored
#
# Collapsing all three into "skip" is what let a stale CSV survive a refresh:
# an empty or failed read wrote nothing, the previous file stayed where it
# was, and the snapshot published a new run's metadata beside an old run's
# rows.
read_export <- function(con, name, optional = FALSE) {
  got <- tryCatch(db_q(con, sprintf("SELECT * FROM %s", name)),
                  error = function(e) conditionMessage(e))
  if (is.character(got))
    return(list(state = if (optional && grepl("not found|NoSuchTable|TABLE_OR_VIEW",
                                              got, ignore.case = TRUE))
                          "absent" else "failed",
                why = got))
  list(state = "ok", data = got)
}

# The swap. A snapshot becomes visible only once everything it holds has been
# read, and an older one that a failed refresh could not replace keeps its own
# identity rather than being half-overwritten.
#
# Not atomic in the filesystem sense - two renames cannot be - but each
# directory is replaced whole, and a failure before this point leaves every
# published directory exactly as it was.
publish <- function(stage, dest, n, prefix, lot_id, lstage = NULL, ldest = NULL) {
  swap <- function(from, to) {
    if (is.null(from) || !dir.exists(from)) return(invisible(FALSE))
    old <- paste0(to, ".previous")
    unlink(old, recursive = TRUE)
    if (dir.exists(to) && !file.rename(to, old))
      stop("could not set aside the previous snapshot at ", to, call. = FALSE)
    if (!file.rename(from, to)) {
      if (dir.exists(old)) file.rename(old, to)   # put the old one back
      stop("could not publish ", to, call. = FALSE)
    }
    unlink(old, recursive = TRUE)
    invisible(TRUE)
  }
  swap(lstage, ldest)
  swap(stage, dest)
  message("  published ", n, " table(s) to ", dest,
          if (nzchar(lot_id %||% "")) paste0("  (LOT run ", lot_id, ")") else "")
  n
}


`%||%` <- function(a, b) if (is.null(a)) b else a

# Whether the LOT prefix is owned, RIGHT NOW, by the run - and the BUILD of
# it - this scenario read.
#
# The exporter copied whatever sat under the LOT prefix into lot/<run id>/ and
# the reader trusts that directory name. A prefix rebuilt between the study
# run and the export therefore filed the NEW build's lines under the OLD run's
# id. The status table keeps every run's row, so "a row says this run
# completed" is history; only the newest row says whose tables are there -
# and, since the engine keeps a run id for a session, its stamp says which
# build. The rule itself is the warehouse reader's (lot_status_owner in
# R/sources.R, which the job loads), so the two cannot drift.
lot_prefix_owner_ok <- function(con, status_tbl, lot_id, lot_version = "") {
  st <- tryCatch(db_q(con, sprintf("SELECT * FROM %s", status_tbl)),
                 error = function(e) NULL)
  lot_status_owner(st, lot_id, "x", lot_version)
}

# Run `expr` with these environment variables set in THIS process, restored
# afterwards. The child build inherits them, on every platform: passing them
# as system2(env = ...) prefixes `NAME=value` onto the command line, which
# Windows does not do, and the job's child then built with none of its
# settings and produced no output.
with_env <- function(env, expr) {
  env <- env[nzchar(names(env))]
  old <- Sys.getenv(names(env), unset = NA_character_, names = TRUE)
  do.call(Sys.setenv, as.list(env))
  on.exit({
    for (k in names(old))
      if (is.na(old[[k]])) Sys.unsetenv(k) else
        do.call(Sys.setenv, stats::setNames(list(old[[k]]), k))
  }, add = TRUE)
  force(expr)
}
