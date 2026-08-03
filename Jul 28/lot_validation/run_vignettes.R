#!/usr/bin/env Rscript
# Render the edge-case vignette catalogue.
#
#   Rscript lot_validation/run_vignettes.R
#
# No warehouse and no connection: the catalogue is a specification of what the
# rules say, resolved against this run's own configured parameters. It writes a
# CSV and a markdown table, and stops if the catalogue disagrees with the
# config it was resolved against.

.script_dir <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (length(a)) dirname(normalizePath(sub("^--file=", "", a[1]))) else getwd()
})

# lot's own config, loaded the way the build loads it - config.csv first,
# because config_lot.R turns environment variables into cfg_defaults the moment
# it is sourced. A second reader of these settings would be a second place for
# them to drift.
lotval_params <- function(script_dir = .script_dir) {
  lot_root <- normalizePath(file.path(script_dir, "..", "lot"), mustWork = TRUE)
  e <- new.env(parent = globalenv())
  sys.source(file.path(lot_root, "R", "load_inputs.R"), envir = e)
  e$load_pipeline_inputs(lot_root, "config.csv")
  sys.source(file.path(lot_root, "R", "config_lot.R"), envir = e)
  cfg <- get("cfg_defaults", envir = e)
  p <- cfg[names(VIGNETTE_PARAMS)]
  names(p) <- names(VIGNETTE_PARAMS)
  lapply(p, function(v) if (is.null(v)) NA_integer_ else as.integer(v)[1])
}

main <- function() {
  source(file.path(.script_dir, "R", "vignettes.R"))
  p <- lotval_params()

  cat("LOT edge-case vignettes, resolved against this run's parameters:\n")
  for (nm in names(VIGNETTE_PARAMS))
    cat(sprintf("  %-28s %-5s  %s\n", nm, p[[nm]], VIGNETTE_PARAMS[[nm]]))

  check_vignettes(p)
  df <- render_vignettes(p)

  out <- file.path(Sys.getenv("OUTPUT_DIR", unset = file.path(.script_dir, "out")))
  if (!dir.exists(out)) dir.create(out, recursive = TRUE, showWarnings = FALSE)
  csv <- file.path(out, "lot_edge_case_vignettes.csv")
  write.csv(df, csv, row.names = FALSE)

  md <- file.path(out, "lot_edge_case_vignettes.md")
  lines <- c(
    "# LOT edge-case vignettes",
    "",
    paste0("Resolved against: ",
           paste(sprintf("%s=%s", names(p), unlist(p)), collapse = ", ")),
    "",
    "`derived` follows from the rule quoted beside it. `to_confirm` is our",
    "reading of how the rules interact, and the first warehouse run settles it.",
    "",
    "| id | case | parameter | expected under this algorithm | confidence |",
    "|---|---|---|---|---|",
    sprintf("| `%s` | %s | %s | %s | %s |",
            df$id, df$title, ifelse(nzchar(df$parameter), paste0("`", df$parameter, "`"), "-"),
            df$expected, df$confidence),
    "",
    "## Timelines",
    "",
    unlist(lapply(seq_len(nrow(df)), function(i) c(
      paste0("**", df$id[i], "** - ", df$title[i]),
      "",
      paste0("- timeline: ", df$timeline[i]),
      paste0("- why it is hard: ", df$why_hard[i]),
      paste0("- rule: ", df$rule_at[i]),
      ""))))
  writeLines(lines, md)

  n_conf <- sum(df$confidence == "to_confirm")
  cat("\n", nrow(df), " vignettes, ", nrow(df) - n_conf, " derived and ", n_conf,
      " to confirm against a real run.\n", sep = "")
  cat("  ", csv, "\n  ", md, "\n", sep = "")
}

if (!interactive()) main()
