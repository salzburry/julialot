#!/usr/bin/env Rscript
# Spec-compliance helper: emit LOT_BASE_LENGTH_CE_SENS without
# editing the LOT2-5 base build.
#
#   Rscript lot_ce_sens_length.R
#
# The spec
# (scripts/build_lot2_5_spec.py:504 - LOTN_BASE_LENGTH_CE_SENS) lists
# the cohort-end-clamped LOT length as a required output column.
# The LOT2-5 long-format build emits LOT_BASE_LENGTH and the CE-sens
# end-date / end-reason variants (LOT_BASE_END_DT_CE_SENS,
# LOT_BASE_END_REASON_CE_SENS) but never computed the parallel
# length. lot_long_dashboard.R / downstream scripts therefore have
# no way to expose CE-clamped duration.
#
# Rather than touching lot2_5_base.R (the user wants the existing
# pipeline programs left alone), this script materialises a thin
# work-schema VIEW that wraps LOT_LONG and adds the missing column
# derived from already-persisted fields:
#
#   LOT_BASE_LENGTH_CE_SENS = datediff(LOT_BASE_END_DT_CE_SENS,
#                                       LOT_START_DT) + 1
#
# The derivation is exact for every end-reason: when the reason is
# DISCONTINUATION the LOT_LONG build sets LOT_BASE_END_DT =
# LOT_BASE_DISCON_DT (so the CE-sens end date already captures the
# discontinuation case), and when CE clamping triggered
# LOT_BASE_END_DT_CE_SENS = ENDDATE_CE so the length is clamped.
#
# Idempotent: CREATE OR REPLACE VIEW. Safe to rerun any time after
# the pipeline. View name overridable via LOT_LONG_PLUS_NAME.

.script_dir <- local({
  args <- commandArgs(trailingOnly = FALSE)
  file_arg <- grep("^--file=", args, value = TRUE)
  if (length(file_arg) > 0) {
    return(dirname(normalizePath(sub("^--file=", "", file_arg[1]))))
  }
  for (i in seq_len(sys.nframe())) {
    ofile <- tryCatch(sys.frame(i)$ofile, error = function(e) NULL)
    if (!is.null(ofile)) return(dirname(normalizePath(ofile)))
  }
  getwd()
})

source_dir <- file.path(.script_dir, "R")
if (file.exists(file.path(source_dir, "load_inputs.R"))) {
  source(file.path(source_dir, "load_inputs.R"))
  load_pipeline_inputs(c(.script_dir, dirname(.script_dir)))
}
source(file.path(source_dir, "config_lot.R"))
source(file.path(source_dir, "db_utils_lot.R"))

VIEW_BASE <- Sys.getenv("LOT_LONG_PLUS_NAME", unset = "LOT_LONG_PLUS")

main <- function() {
  stop_if_blank(cfg$pwd, "DATABRICKS_PWD environment variable is not set.")
  con <- DBI::dbConnect(odbc::odbc(), dsn = cfg$dsn,
                        pwd = cfg$pwd, timeout = 120)
  on.exit(try(DBI::dbDisconnect(con), silent = TRUE), add = TRUE)

  lot_long  <- wrk("LOT_LONG")
  view_name <- wrk(VIEW_BASE)
  log_msg("Building ", view_name, " from ", lot_long,
          " (adds LOT_BASE_LENGTH_CE_SENS per spec, no pipeline edit)")

  cols <- tryCatch(db_q(con, glue("DESCRIBE TABLE {lot_long}")),
                   error = function(e) NULL)
  if (is.null(cols) || !"col_name" %in% names(cols)) {
    stop("Cannot read ", lot_long,
         ". Build LOT_LONG (run_pipeline.R / LOT2-5 stage) first.")
  }
  have <- toupper(trimws(cols$col_name))
  for (req in c("LOT_BASE_END_DT_CE_SENS", "LOT_START_DT",
                "LOT_BASE_LENGTH")) {
    if (!req %in% have)
      stop(lot_long, " is missing required column ", req,
           "; rebuild LOT_LONG with the LOT2-5 stage first.")
  }

  db_exec(con, glue("
    CREATE OR REPLACE VIEW {view_name} AS
    SELECT
      ll.*,
      datediff(ll.LOT_BASE_END_DT_CE_SENS, ll.LOT_START_DT) + 1
        AS LOT_BASE_LENGTH_CE_SENS
    FROM {lot_long} ll
  "))

  qc <- db_q(con, glue("
    SELECT
      count(*)                                                AS total_rows,
      sum(case when LOT_BASE_LENGTH_CE_SENS < LOT_BASE_LENGTH
               then 1 else 0 end)                             AS n_ce_capped,
      sum(case when LOT_BASE_LENGTH_CE_SENS = LOT_BASE_LENGTH
               then 1 else 0 end)                             AS n_unchanged,
      sum(case when LOT_BASE_LENGTH_CE_SENS IS NULL
               then 1 else 0 end)                             AS n_null_length
    FROM {view_name}
  "))
  log_msg(sprintf(
    "Built %s | total=%s | CE-capped (LENGTH_CE_SENS<LENGTH)=%s | unchanged=%s | null=%s",
    view_name,
    format(as.numeric(qc$total_rows[1]),  big.mark = ","),
    format(as.numeric(qc$n_ce_capped[1]), big.mark = ","),
    format(as.numeric(qc$n_unchanged[1]), big.mark = ","),
    format(as.numeric(qc$n_null_length[1]), big.mark = ",")))
}

if (!interactive()) main()
