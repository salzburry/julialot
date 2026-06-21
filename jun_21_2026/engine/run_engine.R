#!/usr/bin/env Rscript
# engine/run_engine.R - driver for the LOCAL verification engine: read canonical
# inputs + codelist + resolved params, run the modular core, write outputs. This
# is the harness that lets us see the refactor reproduce behaviour on synthetic
# data locally; production is Databricks SQL on hive_metastore (separate).

if (!exists("build_map_stacked")) source(local({
  fa <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (length(fa)) dirname(sub("^--file=", "", fa[1])) else "engine"
  file.path(d, "map.R") }))

# Params are DATA (resolved config), so retuning the algorithm is a config edit.
DEFAULT_PARAMS <- list(map_discon_gap_days = 90L, medical_day_supply = 28L)

run_engine <- function(input_dir, params = list()) {
  rd <- function(f) { p <- file.path(input_dir, f)
    if (file.exists(p)) read.csv(p, stringsAsFactors = FALSE, colClasses = "character")
    else data.frame() }
  p <- modifyList(DEFAULT_PARAMS, params)
  list(MAP_STACKED = build_map_stacked(rd("pharmacy.csv"), rd("medical.csv"),
         rd("rollup.csv"), rd("members.csv"), p$map_discon_gap_days, p$medical_day_supply))
}

if (sys.nframe() == 0 && !interactive()) {
  a <- commandArgs(trailingOnly = TRUE)
  indir  <- if (length(a) >= 1) a[1] else "engine/fixtures"
  outdir <- if (length(a) >= 2) a[2] else tempdir()
  dir.create(outdir, showWarnings = FALSE, recursive = TRUE)
  res <- run_engine(indir)
  for (t in names(res)) {
    f <- file.path(outdir, paste0(t, ".csv"))
    write.csv(res[[t]], f, row.names = FALSE, na = "")
    cat(sprintf("wrote %s (%d rows)\n", f, nrow(res[[t]])))
  }
}
