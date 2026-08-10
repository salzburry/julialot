#!/usr/bin/env Rscript
# Both evidence grids, loaded through the readers the harness itself uses, and
# reported as fill state.
#
#   Rscript .claude/skills/lot-evidence/scripts/check_grids.R [<validation dir>]
#
# No warehouse. Exit status is 0 when both grids load, 1 when either is refused
# - which is the state a half-filled grid is in, and the point of running this
# before handing work back.
#
# It calls read_definition_sources() and read_benchmarks() rather than
# re-checking the rules, so this cannot drift from what the harness will do
# with the same file. If they stop refusing something, so does this.

args <- commandArgs(trailingOnly = TRUE)
HERE <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                            fixed = TRUE))) else getwd()
})
# <repo>/.claude/skills/lot-evidence/scripts -> <repo>
REPO <- dirname(dirname(dirname(dirname(HERE))))
VDIR <- if (length(args)) args[1] else file.path(REPO, "Jul 28", "lot", "validation")
if (!dir.exists(VDIR)) {
  cat("No validation package at ", VDIR, "\n", sep = "")
  quit(status = 1L)
}

`%||%` <- function(a, b) if (is.null(a)) b else a
suppressWarnings({
  source(file.path(VDIR, "R", "definitions.R"))
  source(file.path(VDIR, "R", "benchmarks.R"))
})

filled <- function(x) !is.na(x) & nzchar(trimws(x))
line <- function() cat(strrep("-", 66), "\n", sep = "")

cat("\n", strrep("=", 66), "\n", sep = "")
cat("  LOT EVIDENCE GRIDS\n")
cat(strrep("=", 66), "\n", sep = "")

status <- 0L
report <- function(label, path, reader, count) {
  cat("\n  ", label, "\n", sep = "")
  cat("  ", path, "\n", sep = "")
  df <- tryCatch(reader(path), error = function(e) e)
  if (inherits(df, "error")) {
    status <<- 1L
    cat("  REFUSED\n")
    for (l in strsplit(conditionMessage(df), "\n")[[1]]) cat("   ", l, "\n")
    return(invisible(NULL))
  }
  cat("  loads. ", count(df), "\n", sep = "")
}

report("definitions_sources.csv - the algorithm against IMWG and the trials",
       file.path(VDIR, "definitions_sources.csv"), read_definition_sources,
       function(df) {
         n <- sum(filled(df$answer))
         cc <- tolower(trimws(ifelse(is.na(df$concordance), "", df$concordance)))
         paste0(n, " of ", nrow(df), " rows answered",
                if (n) paste0("  (agrees ", sum(cc == "agrees"),
                              ", differs ", sum(cc == "differs"),
                              ", unclear ", sum(cc == "unclear"), ")") else "")
       })

report("benchmarks.csv - the outputs against published numbers",
       file.path(VDIR, "benchmarks.csv"), read_benchmarks,
       function(df) {
         n <- sum(!is.na(df$published_value))
         cmp <- tolower(trimws(ifelse(is.na(df$comparable), "", df$comparable)))
         paste0(n, " of ", nrow(df), " rows sourced",
                if (n) paste0("  (comparable ", sum(cmp == "yes"),
                              ", with caveat ", sum(cmp == "caveat"),
                              ", recorded only ", sum(!cmp %in% c("yes", "caveat")), ")")
                else "")
       })

cat("\n"); line()
if (status == 0L) {
  cat("  Both grids load. That means every filled cell carries what it needs\n")
  cat("  to be checked by someone else - not that any of it is right.\n\n")
} else {
  cat("  A grid was refused. The row is named above. Fix the citation or\n")
  cat("  empty the cell; do not remove the guard.\n\n")
}
quit(status = status)
