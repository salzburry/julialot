# Replacing one run's output with the next, and being able to undo it.
#
# Its own file because it is the step that can destroy a published deliverable,
# and a step like that has to be callable by a test rather than only readable.

# The tool's own files. Only these are ever moved: whatever else a person has
# put in the output directory is theirs.
TFLS_OUTPUT_PATTERN <- "^tfls_.*[.]csv$|^tfls[.]md$"

publish_outputs <- function(stage, out_dir, run_id) {
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
  unlink(prev, recursive = TRUE)
  old <- list.files(out_dir, pattern = TFLS_OUTPUT_PATTERN, full.names = TRUE)
  if (length(old)) {
    dir.create(prev, showWarnings = FALSE, recursive = TRUE)
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
  made <- list.files(stage, full.names = TRUE)
  moved <- file.rename(made, file.path(out_dir, basename(made)))
  if (!all(moved)) {
    # Take back the half that landed, then restore the run that was there.
    landed <- basename(made)[moved]
    if (length(landed)) file.remove(file.path(out_dir, landed))
    if (dir.exists(prev)) {
      back <- list.files(prev, full.names = TRUE)
      if (length(back))
        file.rename(back, file.path(out_dir, basename(back)))
      unlink(prev, recursive = TRUE)
    }
    stop("Could not publish ", paste(basename(made)[!moved], collapse = ", "),
         " into ", out_dir, ". The previous run has been put back, so what is ",
         "published is one run's; this run's tables are in ", stage, ".",
         call. = FALSE)
  }
  unlink(prev, recursive = TRUE)
  invisible(TRUE)
}
