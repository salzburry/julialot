#!/usr/bin/env Rscript
# The melphalan comparison, read off cells that are already built.
#
#   DATABRICKS_PWD=... DOMINO_USER_NAME=usr00000 \
#     INPUT_COHORT_TABLE=ndmm_NDMM_COHORT COHORT_PREFIX=ndmm_ \
#     Rscript lot/melphalan/read_melp_metrics.R
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
LOT_ROOT <- normalizePath(file.path(.script_dir, "..", "engine"), mustWork = TRUE)

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

out_dir <- Sys.getenv("OUTPUT_DIR", unset = "/mnt/artifacts/results")
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)

stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")
con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn, pwd = cfg$pwd, timeout = 120)
on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

abbr <- Sys.getenv("MELP_ABBR", unset = "MELP")
rows <- list()
for (c_i in MELP_CELLS) {
  final <- wrk(paste0(c_i$prefix, "LOT_LONG_FINAL"))
  log_msg("Reading ", c_i$id, " from ", final)
  m <- melp_metrics(con, final,
                    wrk(paste0(c_i$prefix, "LOT_ATTRITION")),
                    cell_run_id(con, c_i), abbr,
                    map_tbl      = wrk(paste0(c_i$prefix, "MAP_STACKED")),
                    expo_days    = cfg$melp_exposure_days,
                    restart_days = cfg$melp_restart_days,
                    advance_days = cfg$melp_advance_days,
                    ind1         = cfg$induction_window_days,
                    indn         = cfg$lot_n_induction_window_days,
                    cart         = cfg$cart_consolidation_days)
  if (is.null(m))
    stop("Metrics could not be read for ", c_i$id, " (", final, "). Either that ",
         "cell was never built, or one of its statements failed. The result is ",
         "the comparison between all three, so this is a stop rather than a row ",
         "left out of it.", call. = FALSE)
  rows[[length(rows) + 1L]] <- cbind(cell = c_i$id, mode = c_i$mode, m,
                                     stringsAsFactors = FALSE)
}

res <- do.call(rbind, rows)
utils::write.csv(res, file.path(out_dir, "melp_cells.csv"), row.names = FALSE)
cmp <- melp_compare(res)
utils::write.csv(cmp, file.path(out_dir, "melp_vs_reference.csv"), row.names = FALSE)

cat("\nAgainst the contract build:\n\n")
for (i in seq_len(nrow(cmp)))
  cat(sprintf("  %-13s %-19s %10s -> %-10s %+8s\n",
              cmp$cell[i], cmp$metric[i], format(cmp$reference[i]),
              format(cmp$observed[i]), format(cmp$change[i])))
cat("\nWritten to ", out_dir, "\n", sep = "")
