# Which study folder these harnesses emit from.
#
# Named outright with STUDY_FOLDER; otherwise the one folder that HAS the part
# being asked for. If several do, this REFUSES and names them rather than
# picking - see below.
#
# Both emitters used to hardcode "Jul 28", which stopped carrying either part.
# Every caller got "SKIP: no engine" / "SKIP: no QC catalogue" and a status
# their callers read as a failure, so the emit never ran at all - and a harness
# that never ran reports nothing about the rule it was pointed at.
#
# Why refuse rather than take the newest. A mtime tie-break looks reasonable
# and is wrong where it matters most: a fresh clone writes every file at
# checkout time, so in CI - the one place nobody reads the output - every
# candidate ties and the "newest" is whichever the filesystem listed first.
# Picking the wrong engine there would emit one delivery's SQL while the run
# claimed to be testing another, and it would do it silently. Naming the
# folder is one environment variable; a harness that emitted the wrong build
# is a green that means nothing.
#
# Sourced by emit_chain.R and emit_qc.R. One resolution, so pointing them at
# different folders is a thing someone chose rather than a thing that drifted.

study_folder_candidates <- function(repo, ...) {
  parts <- list(...)
  has <- function(d) all(vapply(parts, function(p)
    file.exists(do.call(file.path, c(list(repo, d), as.list(p)))), logical(1)))
  cand <- list.dirs(repo, full.names = FALSE, recursive = FALSE)
  cand <- cand[nzchar(cand) & !startsWith(cand, ".")]
  sort(cand[vapply(cand, has, logical(1))])
}

# "" when there is nothing to emit from, or when the choice is ambiguous. The
# reason is returned alongside so the caller can print it, and a "status"
# saying which of the two it is: a checkout with no engine in it is a genuine
# skip, and a checkout with two is someone who has to say which - the second
# must not read as "nothing to test here", because a vacuous green in CI is
# the failure this whole file exists to stop.
study_folder_with <- function(repo, ...) {
  have <- study_folder_candidates(repo, ...)
  named <- trimws(Sys.getenv("STUDY_FOLDER", unset = ""))
  if (nzchar(named))
    return(if (named %in% have) named
           else structure("", status = if (length(have)) "ambiguous" else "absent",
                          reason = paste0(
             "STUDY_FOLDER names '", named, "', which does not carry it",
             if (length(have)) paste0(" (these do: ", paste(have, collapse = ", "), ")")
             else "")))
  if (!length(have))
    return(structure("", status = "absent",
                     reason = "no folder here carries it"))
  if (length(have) > 1L)
    return(structure("", status = "ambiguous", reason = paste0(
      "set STUDY_FOLDER - ", length(have), " folders carry it: ",
      paste(have, collapse = ", "))))
  have[1]
}

# 3 is "nothing here to emit", which callers read as a skip. 4 is "say which",
# which they must read as a failure.
study_folder_quit <- function(what, STUDY) {
  st <- attr(STUDY, "status") %||% "absent"
  cat("SKIP: no ", what, " to emit - ", attr(STUDY, "reason"), "\n", sep = "")
  quit(status = if (identical(st, "ambiguous")) 4L else 3L)
}
