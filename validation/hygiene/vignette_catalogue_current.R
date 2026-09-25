#!/usr/bin/env Rscript
# The tracked vignette catalogue against the code that generates it.
#
#   Rscript validation/hygiene/vignette_catalogue_current.R
#
# lot/validation/out/ holds a CSV and a markdown table rendered from
# R/vignettes.R and the pinned settings. Both are committed, because a
# reviewable record of what the rules say is worth having in the repository
# rather than only on whoever last ran the script.
#
# A tracked output that nothing regenerates drifts, and this one did. The
# cart_bridge vignettes were corrected in the source - an agent added inside
# line 1's 60-day window joins the regimen, so day 60 is the first day a
# MED_ADD can exist - and the committed CSV kept the old day-20 dates for
# weeks. It surfaced only because someone happened to run the renderer.
#
# So the renderer runs here, into a temporary directory, and its output is
# compared with what is committed. OUTPUT_DIR is what makes that possible
# without touching the working tree: run_vignettes.R writes wherever it points.
#
# A difference is not a defect in the rules. It means the catalogue is behind
# the code, and re-running the renderer is the fix:
#
#   Rscript "Jul 28/lot/validation/run_vignettes.R"

HERE <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                            fixed = TRUE))) else getwd()
})
REPO  <- dirname(dirname(HERE))
STUDY <- local({
  v <- Sys.getenv("STUDY_FOLDER", unset = "")
  if (!nzchar(v)) file.path(REPO, "Jul 28")
  else if (startsWith(v, "/")) v else file.path(REPO, v)
})

pass <- 0L; fail <- 0L
ok <- function(cond, what) {
  if (isTRUE(cond)) { pass <<- pass + 1L; cat("  ok     ", what, "\n") }
  else              { fail <<- fail + 1L; cat("  FAIL   ", what, "\n") }
}

cat("\n-- the tracked catalogue is what the renderer produces --\n")

renderer <- file.path(STUDY, "lot", "validation", "run_vignettes.R")
tracked  <- file.path(STUDY, "lot", "validation", "out")
FILES    <- c("lot_edge_case_vignettes.csv", "lot_edge_case_vignettes.md")

if (!file.exists(renderer)) {
  cat("  SKIP    no renderer at ", renderer, "\n", sep = "")
  cat("\n", strrep("-", 52), "\n", sep = "")
  cat(sprintf("%d passed, %d failed\n", pass, fail))
  quit(status = 0L)
}

tmp <- file.path(tempdir(), paste0("vig", Sys.getpid()))
dir.create(tmp, showWarnings = FALSE, recursive = TRUE)
on.exit(unlink(tmp, recursive = TRUE), add = TRUE)

# OUTPUT_DIR through this process's environment, which the renderer inherits,
# and put back after. system2(env = ...) is a command-line prefix, and on
# Windows Rscript took it for the script to run and never ran the renderer.
old_out <- Sys.getenv("OUTPUT_DIR", unset = NA)
Sys.setenv(OUTPUT_DIR = tmp)
out <- suppressWarnings(system2("Rscript", shQuote(renderer),
                                stdout = TRUE, stderr = TRUE))
if (is.na(old_out)) Sys.unsetenv("OUTPUT_DIR") else Sys.setenv(OUTPUT_DIR = old_out)
st <- attr(out, "status"); st <- if (is.null(st)) 0L else st
ok(st == 0L, "the renderer runs")
if (st != 0L) for (l in utils::tail(out, 6)) cat("           ", l, "\n")

# Byte-for-byte. A catalogue that differs only in whitespace is still a
# catalogue nobody re-rendered, and the fix is the same either way.
for (f in FILES) {
  a <- file.path(tracked, f)
  b <- file.path(tmp, f)
  if (!file.exists(b)) { ok(FALSE, paste0(f, ": the renderer did not write it")); next }
  if (!file.exists(a)) { ok(FALSE, paste0(f, ": rendered, but not here")); next }
  # On disk is not the same as IN THE COMMIT. These two live under out/, which
  # .gitignore ignores, so they are tracked only because they were force-added
  # once. A delivery folder copied from another one gets them on disk and NOT
  # in the commit - git add -A skips them - and then this suite passes in the
  # working copy that made them and fails on every clone, which is the worst
  # way round for a check to fail. That is not hypothetical: it is how Sep 16
  # was committed.
  #
  # Only inside a work tree. From an exported copy there is nothing to ask,
  # and the existence test above is the guard there.
  in_repo <- identical(trimws(paste(suppressWarnings(system2(
    "git", c("-C", shQuote(dirname(a)), "rev-parse", "--is-inside-work-tree"),
    stdout = TRUE, stderr = FALSE)), collapse = "")), "true")
  if (in_repo) {
    listed <- suppressWarnings(system2("git", c("-C", shQuote(dirname(a)),
                                                "ls-files", "--", shQuote(basename(a))),
                                       stdout = TRUE, stderr = FALSE))
    ok(length(listed) > 0L && nzchar(listed[1]),
       paste0(f, " is in the commit, not just on disk",
              if (!(length(listed) > 0L && nzchar(listed[1])))
                " [out/ is gitignored - add it with: git add -f]" else ""))
  }
  same <- identical(readLines(a, warn = FALSE), readLines(b, warn = FALSE))
  ok(same, paste0(f, " is current"))
  if (!same) {
    ta <- readLines(a, warn = FALSE); tb <- readLines(b, warn = FALSE)
    n  <- which(head(ta, min(length(ta), length(tb))) !=
                head(tb, min(length(ta), length(tb))))
    cat("          first difference at line ",
        if (length(n)) n[1] else min(length(ta), length(tb)) + 1L, "\n", sep = "")
    cat("          re-render with: Rscript \"", renderer, "\"\n", sep = "")
  }
}

cat("\n", strrep("-", 52), "\n", sep = "")
cat(sprintf("%d passed, %d failed\n", pass, fail))
if (fail > 0L) quit(status = 1L)
