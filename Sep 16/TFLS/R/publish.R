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
#
# Two rules keep those three states the only ones a kill can leave:
#
#   * A marker is changed BEFORE the files it describes are moved, never
#     after. Restoring the previous set removes the first marker first, so a
#     restore that is itself killed part-way reads as "set-aside cut short"
#     - both sides the previous run's - and the next pass moves the rest back
#     rather than deleting what the last pass already put back.
#   * A set-aside is discarded by RENAMING it out of the way and then
#     removing it. unlink() removes a directory's entries in whatever order
#     the filesystem lists them, so a kill inside it could leave the markers
#     gone and the files present, or the reverse; nothing reads a
#     .tfls_discard_ directory, so its removal can stop anywhere.
TFLS_MARK_ASIDE <- ".set_aside_complete"
TFLS_MARK_MOVED <- ".move_in_complete"

# The run id, as a piece of a directory name.
#
# It is read off the run's own metadata row, which is warehouse data rather
# than anything this tool chose, and both the staging and the set-aside
# directory are named with it. A run id holding a separator or a ".." named a
# directory OUTSIDE the output directory - and the first thing done to the
# staging directory is unlink(recursive = TRUE), so a name that escaped took
# whatever it landed on with it. safe_segment() refuses such a name rather
# than repairing it, but refusing the FILL over a run id the warehouse is
# happy with would be the wrong trade: the directory is this tool's own
# scratch, never read back by name, so an unusable id is replaced here
# instead.
#
# Replaced, not shortened: every character a path may not hold becomes "_",
# and a name left empty or not starting with a letter or digit gets a fixed
# stem. Two different ids can then share a tag, which is why nothing below
# relies on the tag alone to tell two directories apart.
tfls_path_tag <- function(run_id) {
  v <- chr(run_id)
  if (length(v) != 1L || is.na(v)) v <- ""
  v <- gsub("[^A-Za-z0-9._-]", "_", v)
  if (!safe_segment(v)) v <- paste0("run_", gsub("^[^A-Za-z0-9]+", "", v))
  if (!safe_segment(v)) v <- "run"
  v
}

# Where a run stages its tables before they are published: inside the output
# directory, hidden, and NAMED UNIQUELY.
#
# Named by run id alone it was not unique. The engine keeps one run id for a
# session, so two fills of the same run - two floors, two shell sets - shared
# a staging directory, and each one's first act is to clear it: the second
# fill deleted the first's tables from under it, and the first's exit handler
# deleted the second's. The publish lock is no help, because staging happens
# before a publisher takes it.
tfls_staging_dir <- function(out_dir, run_id) {
  tempfile(pattern = paste0(".tfls_staging_", tfls_path_tag(run_id), "_"),
           tmpdir = out_dir)
}

discard_set_aside <- function(prev) {
  # The BASENAME is renamed, not the path. Substituting over the whole path
  # rewrites the first match anywhere in it, so an output directory that
  # itself sits under a folder named .tfls_previous_something had its parent
  # renamed in the string instead - a target in a directory that does not
  # exist, so the rename fails and the set-aside can never be discarded.
  gone <- file.path(dirname(prev),
                    sub("^[.]tfls_previous_", ".tfls_discard_", basename(prev)))
  unlink(gone, recursive = TRUE)
  if (dir.exists(prev) && !file.rename(prev, gone))
    stop("Could not discard the set-aside directory ", prev, ". The output ",
         "directory holds one run's tables; remove that directory by hand.",
         call. = FALSE)
  unlink(gone, recursive = TRUE)
  invisible(TRUE)
}

# The previous set, put back from its set-aside. `partial` says the output
# directory holds the interrupted run's files, to be removed first.
restore_set_aside <- function(prev, out_dir, partial) {
  if (partial) {
    made <- list.files(out_dir, pattern = TFLS_OUTPUT_PATTERN, full.names = TRUE)
    # Checked, because this is the step that makes the restore WHOLE. A file
    # of the interrupted run that could not be removed - held open, read-only
    # - stays beside the previous run's tables that are about to be moved
    # back, and the directory then holds part of each under a message saying
    # it holds one. Every caller reports a clean restore, so the mixture this
    # whole file exists to prevent would be reported as its opposite.
    if (length(made)) {
      left <- made[!file.remove(made)]
      if (length(left))
        stop("Could not remove the interrupted run's files from ", out_dir,
             ": ", paste(basename(left), collapse = ", "), ". The previous ",
             "run's tables are still set aside in ", prev, ", so the output ",
             "directory holds part of one run: remove those files and put ",
             "the set-aside back by hand.", call. = FALSE)
    }
  }
  # From here the state must read as "set-aside cut short" - both sides the
  # previous run's - so that a restore killed part-way is finished by the
  # next pass rather than undone by it. Removing the marker is what says so,
  # and it is CHECKED, because the sentence above is a guarantee and unlink()
  # does not give one.
  #
  # Unremoved, the marker still says the move in had begun. So a restore that
  # then put half the previous run back and stopped left the next recovery
  # reading those restored files as THIS run's half-published output - and
  # its first act is to delete them. The files lost are the ones this
  # function had just rescued.
  #
  # Nothing has been renamed at this point, so stopping here costs nothing:
  # the previous run is whole in the set-aside, and the next attempt tries
  # the marker again.
  mark <- file.path(prev, TFLS_MARK_ASIDE)
  unlink(mark)
  if (file.exists(mark))
    stop("Could not clear the set-aside marker in ", prev, ", and while it ",
         "is there a restore that stops part-way reads as this run's output ",
         "and is deleted. Nothing has been moved. Remove ", basename(mark),
         " by hand, or move the tables in that directory back yourself.",
         call. = FALSE)
  back <- list.files(prev, pattern = TFLS_OUTPUT_PATTERN, full.names = TRUE)
  if (length(back)) {
    ok <- file.rename(back, file.path(out_dir, basename(back)))
    if (!all(ok))
      stop("The previous output could not be put back from ", prev, ": ",
           paste(basename(back)[!ok], collapse = ", "), ". Restore it by ",
           "hand before publishing again.", call. = FALSE)
  }
  discard_set_aside(prev)
  invisible(TRUE)
}

# A publish that was killed part-way, put right before the next one starts.
#
# Two-file moves cannot be made atomic, but what a crash leaves can be made
# unambiguous, and that is what the markers above are for. Each case is
# resolved to a WHOLE set - the previous run's where the new one did not
# land, the new one's where it did - and never to a mixture. Only the tool's
# own files are touched.
recover_interrupted_publish <- function(out_dir) {
  # A discard that was cut short holds nothing anyone reads.
  for (gone in list.files(out_dir, pattern = "^[.]tfls_discard_", all.files = TRUE,
                          full.names = TRUE, include.dirs = TRUE))
    unlink(gone, recursive = TRUE)
  prevs <- list.files(out_dir, pattern = "^[.]tfls_previous_", all.files = TRUE,
                      full.names = TRUE, include.dirs = TRUE)
  prevs <- prevs[dir.exists(prevs)]
  for (prev in prevs) {
    aside_done <- file.exists(file.path(prev, TFLS_MARK_ASIDE))
    moved_done <- file.exists(file.path(prev, TFLS_MARK_MOVED))
    if (moved_done) {
      # The new set is complete in the output directory; only the discard of
      # the old one was lost.
      discard_set_aside(prev)
      cat("  recovered ", basename(prev), ": that publish had completed and ",
          "only its cleanup was lost\n", sep = "")
      next
    }
    restore_set_aside(prev, out_dir, partial = aside_done)
    cat("  recovered ", basename(prev), ": a publish before this one was ",
        "interrupted ", if (aside_done) "while moving its tables in"
                        else "while setting the previous tables aside",
        ", so the previous run's output has been put back whole\n", sep = "")
  }
  invisible(length(prevs))
}

publish_outputs <- function(stage, out_dir, run_id) {
  # Nothing to publish is a stop, not a publish of nothing: with an empty
  # stage every step below would succeed and the previous run's tables would
  # be set aside and discarded, leaving the directory empty and the function
  # reporting success.
  made <- if (dir.exists(stage)) list.files(stage, full.names = TRUE) else character(0)
  if (!length(made))
    stop("Nothing to publish: the staging directory ", stage, " holds no ",
         "files. The previous run's output is untouched.", call. = FALSE)

  lock <- file.path(out_dir, TFLS_PUBLISH_LOCK)
  if (!dir.create(lock, showWarnings = FALSE))
    stop("Another publish holds ", lock, ", so this one would move its files ",
         "in between that one's. If nothing else is publishing into ",
         out_dir, ", the lock was left by a publish that was killed: remove ",
         "the directory and run again, and the interrupted publish is put ",
         "right first. Nothing of this run was published.", call. = FALSE)
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
  prev <- file.path(out_dir, paste0(".tfls_previous_", tfls_path_tag(run_id)))
  old <- list.files(out_dir, pattern = TFLS_OUTPUT_PATTERN, full.names = TRUE)
  # Created even when there is nothing to set aside, so a crash during the
  # move in is recoverable by the same rule either way.
  dir.create(prev, showWarnings = FALSE, recursive = TRUE)
  if (length(old)) {
    aside <- file.rename(old, file.path(prev, basename(old)))
    if (!all(aside)) {
      # Put back whatever did move, so the failure costs nothing.
      restore_set_aside(prev, out_dir, partial = FALSE)
      stop("Could not set aside the previous output in ", out_dir, ": ",
           paste(basename(old)[!aside], collapse = ", "),
           ". The previous run is still published and unchanged; nothing of ",
           "this run was published.", call. = FALSE)
    }
  }
  # Checked. The marker is what tells recovery that the move in had BEGUN;
  # without it a kill reads as "the set-aside was cut short", which means
  # both sides hold the previous run, so recovery puts the set-aside back
  # WITHOUT first removing what this run had already moved in - a directory
  # holding part of each, reported as put back whole. An unwritable marker
  # is therefore a reason not to start the move at all.
  if (!file.create(file.path(prev, TFLS_MARK_ASIDE))) {
    restore_set_aside(prev, out_dir, partial = FALSE)
    stop("Could not record the set-aside in ", prev, ", and that record is ",
         "what a publish killed part-way is read by. The previous run has ",
         "been put back and nothing of this run was published; free space ",
         "or fix permissions on that directory and run again.", call. = FALSE)
  }
  moved <- file.rename(made, file.path(out_dir, basename(made)))
  if (!all(moved)) {
    # Take back the half that landed, then restore the run that was there.
    restore_set_aside(prev, out_dir, partial = TRUE)
    stop("Could not publish ", paste(basename(made)[!moved], collapse = ", "),
         " into ", out_dir, ". The previous run has been put back, so what is ",
         "published is one run's; nothing of this run was published.",
         call. = FALSE)
  }
  # The second marker covers the last window: the move in is complete, and a
  # kill before the discard would otherwise read as partial and take this
  # run back out again. Nothing can be undone at this point - the run IS
  # published - so an unwritable marker is not a failure of the publish. The
  # discard closes the window itself by removing the set-aside, and only if
  # that also fails is there anything left to misread, which is what
  # discard_set_aside() stops on.
  recorded <- file.create(file.path(prev, TFLS_MARK_MOVED))
  discard_set_aside(prev)
  if (!recorded)
    cat("  note: this run is published, but the set-aside could not record ",
        "that it completed. The set-aside has been discarded, so nothing is ",
        "left for the next publish to misread.\n", sep = "")
  invisible(TRUE)
}
