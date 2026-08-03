#!/usr/bin/env Rscript
# How this algorithm defines a line of therapy, beside how others do.
#
#   Rscript lot_validation/run_definitions.R
#
# No warehouse and no connection - the rules are in the code, not the data.
# Writes our side in full, the grid as it stands, and the questions to put to a
# protocol for the cells nobody has filled.

.script_dir <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(a)) dirname(normalizePath(sub("^--file=", "", a[1]))) else getwd()
})
source(file.path(.script_dir, "R", "definitions.R"))

SRC <- Sys.getenv("DEFINITION_SOURCES",
                  unset = file.path(.script_dir, "definitions_sources.csv"))
out_dir <- Sys.getenv("OUTPUT_DIR", unset = file.path(.script_dir, "out"))

main <- function() {
  ours    <- render_definitions()
  sources <- read_definition_sources(SRC)
  cmp     <- compare_definitions(sources)

  if (!dir.exists(out_dir)) dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  write.csv(ours, file.path(out_dir, "lot_definition_ours.csv"), row.names = FALSE)
  write.csv(cmp,  file.path(out_dir, "lot_definition_concordance.csv"), row.names = FALSE)

  cat("\nHow this algorithm defines a line of therapy - ", nrow(ours),
      " dimensions, each citable to a file.\n\n", sep = "")
  for (i in seq_len(nrow(ours)))
    cat("  ", ours$dimension[i], "\n    ", ours$ours[i], "\n    (", ours$ours_at[i],
        ")\n\n", sep = "")

  sourced <- cmp[cmp$concordance != "not yet sourced", , drop = FALSE]
  cat("Comparison grid: ", nrow(sources), " cells, ", nrow(sourced),
      " answered.\n", sep = "")
  if (nrow(sourced)) {
    for (v in c("agrees", "differs", "unclear"))
      cat(sprintf("  %-10s %d\n", v, sum(sourced$concordance == v)))
    diffs <- sourced[sourced$concordance == "differs", , drop = FALSE]
    if (nrow(diffs)) {
      cat("\nWhere this algorithm differs:\n")
      for (i in seq_len(nrow(diffs)))
        cat("  ", diffs$dimension[i], "\n    ours:  ", diffs$ours[i],
            "\n    ", diffs$source_id[i], ": ", diffs$answer[i],
            "\n    (", diffs$citation[i], ")\n", sep = "")
    }
  } else {
    cat("\n  Nothing has been sourced yet, so no dimension is marked as agreeing.\n",
        "  Not-yet-sourced is the default and stays that way: an empty comparison\n",
        "  reading as agreement would retire the question rather than answer it.\n\n",
        "  The consensus paper and the trial protocols are not in this folder,\n",
        "  and nothing here stands in for them. A summary of a document rather\n",
        "  than the document is the one thing these cells must not hold: it\n",
        "  reads like a citation and cannot be checked by anyone holding the\n",
        "  source. The grid rejects that by name.\n\n",
        "  What to fill, per dimension:\n\n", sep = "")
    for (i in seq_len(nrow(ours)))
      cat("    ", ours$dimension_id[i], "\n      ask: ", ours$ask_the_protocol[i],
          "\n", sep = "")
    cat("\n  Acceptable source_type: ",
        paste(names(DEF_SOURCE_TYPES), collapse = ", "), "\n", sep = "")
  }
  cat("\nWrote ", out_dir, "\n", sep = "")
}

if (!interactive()) main()
