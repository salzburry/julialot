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

out <- suppressWarnings(system2("Rscript", shQuote(renderer),
                                stdout = TRUE, stderr = TRUE,
                                env = paste0("OUTPUT_DIR=", shQuote(tmp))))
st <- attr(out, "status"); st <- if (is.null(st)) 0L else st
ok(st == 0L, "the renderer runs")
if (st != 0L) for (l in utils::tail(out, 6)) cat("           ", l, "\n")

# Byte-for-byte. A catalogue that differs only in whitespace is still a
# catalogue nobody re-rendered, and the fix is the same either way.
for (f in FILES) {
  a <- file.path(tracked, f)
  b <- file.path(tmp, f)
  if (!file.exists(b)) { ok(FALSE, paste0(f, ": the renderer did not write it")); next }
  if (!file.exists(a)) { ok(FALSE, paste0(f, ": rendered, but not committed")); next }
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
