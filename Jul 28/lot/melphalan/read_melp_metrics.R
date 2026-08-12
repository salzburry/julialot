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

abbr <- toupper(trimws(Sys.getenv("MELP_MED_ABBR", unset = "MELP")))
# Through melp_cell_plan(), not MELP_CELLS directly - the prefix is attached
# there, and iterating the bare list reads <schema>.LOT_LONG_FINAL, which is
# the STUDY's table rather than a cell's.
cells <- melp_cell_plan(MELP_CELLS,
                        trimws(Sys.getenv("AUG1_PREFIX_BASE", unset = "melp_")))
# What each cell was built over, before any number is read off it.
#
# check_melp_plan() is not here and does not need to be - it refuses a plan that
# would WRITE over the study's tables, and this writes nothing. These two are
# the read-side equivalent, and they are the whole reason the comparison means
# anything: without them three cells built over different cohort refreshes
# compare cleanly, and the study's own build can sit in the reference row.
inputs <- list()
for (c_i in cells) {
  r <- tryCatch(db_q(con, melp_inputs_sql(
    wrk(paste0(c_i$prefix, "LOT_RUN_METADATA")),
    wrk(paste0(c_i$prefix, "LOT_CODELIST_METADATA")),
    wrk(paste0(c_i$prefix, "LOT_BUILD_STATUS")),
    cell_run_id(con, c_i))), error = function(e) e)
  if (inherits(r, "error"))
    stop("Could not read what ", c_i$id, " was built over: ",
         conditionMessage(r), call. = FALSE)
  if (!nrow(r))
    stop("No LOT_RUN_METADATA row for ", c_i$id, ". Without it there is no ",
         "record of which cohort attempt or code lists it was built over, and ",
         "the comparison cannot be shown to be about the rule.", call. = FALSE)
  inputs[[c_i$id]] <- r
}
melp_check_inputs(inputs)
melp_check_deviations(inputs, cells)
log_msg("All three cells were built over cohort attempt ",
        inputs[[1]]$COHORT_RUN_ID[1], " / ", inputs[[1]]$COHORT_STAMP[1],
        ", the same code and the same code lists.")

rows <- list()
for (c_i in cells) {
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
