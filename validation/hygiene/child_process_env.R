#!/usr/bin/env Rscript
# No child process is given its settings through system2(env = ...).
#
#   Rscript validation/hygiene/child_process_env.R
#
# system2(env = ...) does not set an environment. It writes the assignments in
# front of the command - `NAME=value Rscript script.R` - which is a Unix
# shell's syntax. On Windows they reach the program as its first arguments, and
# Rscript takes the first one for the script to run: the launcher checks, the
# logger checks, the vignette check and the melphalan runner all ran a script
# called PIPELINE_LOG_FILE=... or OUTPUT_DIR=... there, and never the one they
# named. A check that runs nothing reports whatever its assertions say about
# nothing.
#
# The settings go into this process's environment for the length of the call
# and are put back after, so the child inherits them on every platform - the
# study package's with_env(), and with_child_env() where a package cannot reach
# that one.
#
# Read with R's own parser, so a call spread over several lines is one call
# and a comment or a string that mentions system2 is not.

HERE <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (!length(a)) getwd()
  else dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]), fixed = TRUE)))
})
REPO   <- dirname(dirname(HERE))
FOLDER <- Sys.getenv("STUDY_FOLDER", unset = "Jul 28")
ROOT   <- file.path(REPO, FOLDER)
if (!dir.exists(ROOT)) {
  cat("SKIP: no ", FOLDER, " folder beside this one.\n", sep = "")
  quit(status = 3L)
}

pass <- 0L; fail <- 0L
ok <- function(cond, what) {
  if (isTRUE(cond)) { pass <<- pass + 1L; cat("  ok     ", what, "\n") }
  else              { fail <<- fail + 1L; cat("  FAIL   ", what, "\n") }
}

# The lines of `f` holding a system() or system2() call with an argument named
# env. NA where the file does not parse, which is reported rather than passed.
env_calls <- function(f) {
  ex <- tryCatch(parse(f, keep.source = TRUE), error = function(e) NULL)
  if (is.null(ex)) return(NA_integer_)
  pd <- utils::getParseData(ex)
  if (is.null(pd) || !nrow(pd)) return(integer(0))
  calls <- pd[pd$token == "SYMBOL_FUNCTION_CALL" & pd$text %in% c("system2", "system"), ]
  hit <- integer(0)
  for (i in seq_len(nrow(calls))) {
    call_id <- pd$parent[pd$id == calls$parent[i]]
    named <- pd$text[pd$parent == call_id & pd$token == "SYMBOL_SUB"]
    if ("env" %in% named) hit <- c(hit, calls$line1[i])
  }
  hit
}

# The scanner first, on text planted for it: a check that finds nothing has to
# be shown able to find something.
planted <- tempfile(fileext = ".R")
writeLines(c(
  "x <- system2('Rscript', 'a.R',",
  "             stdout = TRUE,",
  "             env = c('A=1'))",
  "y <- base::system2('Rscript', 'b.R', env = 'B=2')",
  "# system2('Rscript', env = 'in a comment')",
  "z <- 'system2(\"Rscript\", env = \"in a string\")'",
  "w <- system2('Rscript', 'c.R', stdout = TRUE)",
  "v <- f(env = 1)"), planted)
got <- env_calls(planted)
unlink(planted)
ok(identical(got, c(1L, 4L)),
   "the scanner finds a call spread over lines and a namespaced one, and not a comment, a string, a call without env or another function's env")

files <- c(list.files(ROOT, "\\.[Rr]$", recursive = TRUE, full.names = TRUE),
           list.files(file.path(REPO, "validation"), "\\.[Rr]$", recursive = TRUE,
                      full.names = TRUE))
res <- lapply(files, env_calls)
unparsed <- files[vapply(res, anyNA, logical(1))]
ok(!length(unparsed),
   paste0("every R file in ", FOLDER, " and validation/ parses (", length(files),
          " read)", if (length(unparsed))
            paste0(": ", paste(basename(unparsed), collapse = ", ")) else ""))
found <- unlist(Map(function(f, l) if (length(l) && !anyNA(l))
  paste0(sub(paste0("^", REPO, "/"), "", f), ":", l), files, res))
ok(!length(found),
   paste0("no child process is handed its settings through system2(env = ...)",
          if (length(found)) paste0(": ", paste(found, collapse = ", ")) else ""))

cat("\n", strrep("-", 52), "\n", sep = "")
cat(sprintf("%d passed, %d failed\n", pass, fail))
if (fail > 0L) quit(status = 1L)
