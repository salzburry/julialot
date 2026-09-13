# The parts of jobs/build_scenarios.R a test can drive.
#
# The job itself is a script: it reads a grid, starts a child R process per row
# and connects to a warehouse, so nothing in it can be reached from a test. The
# three decisions that matter - which settings the export runs under, what a
# read that came back empty means, and when a snapshot becomes visible - live
# here instead, and the job sources them.

# The settings this row runs under. Computed once and given to both the build
# and the export, because they have to be the same settings: a row setting
# WORK_SCHEMA or LOT_PREFIX would otherwise build in one place and be read from
# another.
#
# `set_cols` defaults to the row's own upper-case names, the job's convention
# for "this column is a setting". The job passes it in so the grid decides
# once; the default lets the function stand on its own.
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

# One table, read back. Three outcomes, and they are not the same:
#
#   ok      rows, or a table that legitimately holds none
#   absent  the table was never written - an optional module was not selected
#   failed  the read itself errored
#
# Collapsed into "skip", an empty or failed read writes nothing, the previous
# CSV survives the refresh, and the snapshot publishes a new run's metadata
# beside an old run's rows.
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


# with_env() and `%||%` are the study package's own (R/config_223926.R);
# lot_prefix_owner_ok() is the reader's (R/sources.R). The job loads both.
