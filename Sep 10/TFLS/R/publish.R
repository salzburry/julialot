# Replacing one run's output with the next, and being able to undo it.
#
# Its own file because it is the step that can destroy a published deliverable,
# and a step like that has to be callable by a test rather than only readable.

# The tool's own files. Only these are ever moved: whatever else a person has
# put in the output directory is theirs.
TFLS_OUTPUT_PATTERN <- "^tfls_.*[.]csv$|^tfls[.]md$"

# One publisher at a time. dir.create() is the one filesystem call base R
# offers that creates-or-fails atomically, so a directory is the lock: a
# second publisher into the same output directory finds it and stops, rather
# than moving its files in between the first one's. Removed however the
# publish ends - and so left behind only by a process that was killed, which
# is what the message says.
TFLS_PUBLISH_LOCK <- ".tfls_publish.lock"

# The set-aside directory records how far a publish got, because a killed
# process leaves no other trace of it. Absent: the set-aside itself was cut
# short, so the tool's files in the output directory are the previous run's
# too. The first marker: every previous file is in the set-aside and the move
# in had begun, so what is in the output directory is this run's, and partial.
# The second: the move in completed and only the cleanup was lost.
TFLS_MARK_ASIDE <- ".set_aside_complete"
TFLS_MARK_MOVED <- ".move_in_complete"

# A publish that was killed part-way, put right before the next one starts.
#
# Two-file moves cannot be made atomic, but what a crash leaves can be made
# unambiguous, and that is what the markers above are for. Each case is
# resolved to a WHOLE set - the previous run's where the new one did not
# land, the new one's where it did - and never to a mixture. Only the tool's
# own files are touched.
recover_interrupted_publish <- function(out_dir) {
  prevs <- list.files(out_dir, pattern = "^[.]tfls_previous_", all.files = TRUE,
                      full.names = TRUE, include.dirs = TRUE)
  prevs <- prevs[dir.exists(prevs)]
  for (prev in prevs) {
    aside_done <- file.exists(file.path(prev, TFLS_MARK_ASIDE))
    moved_done <- file.exists(file.path(prev, TFLS_MARK_MOVED))
    if (moved_done) {
      # The new set is complete in the output directory; only the discard of
      # the old one was lost.
      unlink(prev, recursive = TRUE)
      cat("  recovered ", basename(prev), ": that publish had completed and ",
          "only its cleanup was lost\n", sep = "")
      next
    }
    if (aside_done) {
      # The previous set is whole in the set-aside; what is in the output
      # directory is the interrupted run's, and partial.
      partial <- list.files(out_dir, pattern = TFLS_OUTPUT_PATTERN, full.names = TRUE)
      if (length(partial)) file.remove(partial)
    }
    back <- list.files(prev, pattern = TFLS_OUTPUT_PATTERN, full.names = TRUE)
    if (length(back)) {
      ok <- file.rename(back, file.path(out_dir, basename(back)))
      if (!all(ok))
        stop("A publish before this one was interrupted, and its previous ",
             "output could not be put back from ", prev, ": ",
             paste(basename(back)[!ok], collapse = ", "), ". Restore it by ",
             "hand before publishing again.", call. = FALSE)
    }
    unlink(prev, recursive = TRUE)
    cat("  recovered ", basename(prev), ": a publish before this one was ",
        "interrupted ", if (aside_done) "while moving its tables in"
                        else "while setting the previous tables aside",
        ", so the previous run's output has been put back whole\n", sep = "")
  }
  invisible(length(prevs))
}

publish_outputs <- function(stage, out_dir, run_id) {
  lock <- file.path(out_dir, TFLS_PUBLISH_LOCK)
  if (!dir.create(lock, showWarnings = FALSE))
    stop("Another publish holds ", lock, ", so this one would move its files ",
         "in between that one's. If nothing else is publishing into ",
         out_dir, ", the lock was left by a publish that was killed: remove ",
         "the directory and run again, and the interrupted publish is put ",
         "right first. This run's tables are complete in ", stage, ".",
         call. = FALSE)
  on.exit(unlink(lock, recursive = TRUE), add = TRUE)
  recover_interrupted_publish(out_dir)

  # Everything rendered and written. Now replace, and be able to UNDO it.
  #
  # Deleting the old output and then moving the new one in is two operations
  # that each succeed for some files and fail for others. Four of five deletes
  # succeeding and the fifth failing destroys four published tables and then
  # stops - and the message this used to print, that nothing published had
  # changed, was false exactly when it mattered. The same is true of the move:
  # four in and one not leaves a directory that is half of one run and half of
  # another, with nothing on either half saying so.
  #
  # So the previous output is SET ASIDE rather than deleted, and put back if
  # the move in does not complete. The same shape dashboard/jobs/export_lib.R
  # uses for a snapshot, which had it right first.
  #
  # Dropping a table from tables.csv is why the old files go at all: its
  # tfls_<id>.csv would otherwise stay behind, identical in shape to the ones
  # beside it and belonging to a shell set that no longer exists.
  prev <- file.path(out_dir, paste0(".tfls_previous_", run_id))
  old <- list.files(out_dir, pattern = TFLS_OUTPUT_PATTERN, full.names = TRUE)
  # Created even when there is nothing to set aside, so a crash during the
  # move in is recoverable by the same rule either way.
  dir.create(prev, showWarnings = FALSE, recursive = TRUE)
  if (length(old)) {
    aside <- file.rename(old, file.path(prev, basename(old)))
    if (!all(aside)) {
      # Put back whatever did move, so the failure costs nothing.
      done <- basename(old)[aside]
      if (length(done))
        file.rename(file.path(prev, done), file.path(out_dir, done))
      unlink(prev, recursive = TRUE)
      stop("Could not set aside the previous output in ", out_dir, ": ",
           paste(basename(old)[!aside], collapse = ", "),
           ". The previous run is still published and unchanged; this run's ",
           "tables are complete in ", stage, ".", call. = FALSE)
    }
  }
  file.create(file.path(prev, TFLS_MARK_ASIDE))
  made <- list.files(stage, full.names = TRUE)
  moved <- file.rename(made, file.path(out_dir, basename(made)))
  if (!all(moved)) {
    # Take back the half that landed, then restore the run that was there.
    landed <- basename(made)[moved]
    if (length(landed)) file.remove(file.path(out_dir, landed))
    back <- list.files(prev, pattern = TFLS_OUTPUT_PATTERN, full.names = TRUE)
    if (length(back))
      file.rename(back, file.path(out_dir, basename(back)))
    unlink(prev, recursive = TRUE)
    stop("Could not publish ", paste(basename(made)[!moved], collapse = ", "),
         " into ", out_dir, ". The previous run has been put back, so what is ",
         "published is one run's; this run's tables are in ", stage, ".",
         call. = FALSE)
  }
  file.create(file.path(prev, TFLS_MARK_MOVED))
  unlink(prev, recursive = TRUE)
  invisible(TRUE)
}
