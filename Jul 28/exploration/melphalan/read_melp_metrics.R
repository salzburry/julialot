#!/usr/bin/env Rscript
# The melphalan comparison, read off cells that are already built.
#
#   DATABRICKS_PWD=... DOMINO_USER_NAME=usr00000 \
#     INPUT_COHORT_TABLE=ndmm_NDMM_COHORT COHORT_PREFIX=ndmm_ \
#     Rscript exploration/melphalan/read_melp_metrics.R
#
# run_aug1_melp.R builds three cells and then reads them. When the read fails -
# as it did on 2026-08-12, in the Spark optimizer rather than in the data - the
# builds are still there and rebuilding them buys nothing. This is that script's
# second half on its own: it reads, compares and writes, and builds nothing.
#
# It refuses to guess. A cell whose tables are missing stops the run, because
# the deliverable is the comparison between all three and two rows of it are
# not a smaller answer, they are a different one.

.script_dir <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  # Rscript renders a space in a path as ~+~, so a folder with one in its name
  # resolves to nothing without this.
  if (length(a)) dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]),
                                            fixed = TRUE))) else getwd()
})
LOT_ROOT <- normalizePath(file.path(.script_dir, "..", "..", "lot", "engine"), mustWork = TRUE)

source(file.path(LOT_ROOT, "R", "load_inputs.R"))
load_pipeline_inputs(LOT_ROOT, "config.csv")
for (f in c("config_lot.R", "db_utils_lot.R"))
  source(file.path(LOT_ROOT, "R", f))
source(file.path(.script_dir, "R", "cells.R"))

cfg <- get("cfg_defaults", envir = globalenv())
schema <- Sys.getenv("PROJECT_WORK_SCHEMA",
            unset = Sys.getenv("DOMINO_USER_NAME", unset = ""))
if (!nzchar(schema))
  stop("No work schema. Set DOMINO_USER_NAME or PROJECT_WORK_SCHEMA.",
       call. = FALSE)
cfg$work_schema <- schema
set_lot_config(cfg)

# run_aug1_melp.R's resolver, not a second default. The two disagreed, so a
# recovery wrote a fresh set to the artifacts directory while the build's own
# stale CSVs stayed beside its logs, still looking current.
out_dir <- melp_out_dir(.script_dir)
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")
con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 120)
on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

# Through melp_cell_plan(), not MELP_CELLS directly - the prefix is attached
# there, and iterating the bare list reads <schema>.LOT_LONG_FINAL, which is
# the STUDY's table rather than a cell's.
cells <- melp_cell_plan(MELP_CELLS,
                        trimws(Sys.getenv("AUG1_PREFIX_BASE", unset = "melp_")))
# The same reading the runner does, from the same function - every output,
# and every provenance check, including the one that reads the windows off the
# cells rather than off this run's environment.
#
# check_melp_plan() is not here and does not need to be: it refuses a plan that
# would WRITE over the study's tables, and this writes nothing.
melp_report(con, cells, out_dir, lot_root = LOT_ROOT)
