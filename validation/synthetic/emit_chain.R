#!/usr/bin/env Rscript
# Emit every statement the LOT build issues, in order, for a fixed med universe.
#
#   Rscript validation/synthetic/emit_chain.R <out_dir>
#
# The point is that nothing here is retyped. run_step/materialize/db_exec are
# stubbed to capture what the engine actually produces, so the SQL that gets
# tested is the SQL that ships. Change a step file and the emitted text changes
# with it - a test written against a copy could not say that.
#
# Two settings are read from the environment so a run can be differenced
# against itself: CONFIRM_DAYS (lot_discon_confirm_days) and CART_RULE
# (apply_cart_induction_rule). Everything else is the contract.
#
# Not part of the merge gate. See README.md in this directory.

args <- commandArgs(trailingOnly = TRUE)
OUT  <- if (length(args) >= 1) args[1] else tempdir()
dir.create(OUT, showWarnings = FALSE, recursive = TRUE)

HERE <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (!length(a)) getwd()
  else dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]), fixed = TRUE)))
})
REPO   <- dirname(dirname(HERE))
STUDY  <- Sys.getenv("STUDY_FOLDER", unset = "Jul 28")
ENGINE <- file.path(REPO, STUDY, "lot", "engine", "R")
NDMM   <- file.path(REPO, STUDY, "ndmm", "R")
if (!dir.exists(ENGINE)) {
  cat("SKIP: no engine at ", ENGINE, "\n", sep = ""); quit(status = 3L)
}
library(glue)

MEDS    <- c("LEN", "BORT", "DARA", "POMA", "CYCLO", "CARF")
CLASSES <- c("IMID", "PI", "MAB", "ALKY")

e <- new.env(parent = globalenv())
SQL <- character(0)
assign("%||%", function(a, b) if (is.null(a)) b else a, e)
assign("cfg", list(
  lot_discon_confirm_days = as.integer(Sys.getenv("CONFIRM_DAYS", unset = "90")),
  medical_day_supply = 28L, map_discon_gap_days = 90L,
  induction_window_days = 60L, lot_n_induction_window_days = 30L,
  cart_consolidation_days = 45L, sct_auto_window_days = 13L,
  sct_auto_gap_days = 60L, sct_tandem_days = 180L, max_lot = 5L,
  apply_cart_induction_rule =
    as.logical(Sys.getenv("CART_RULE", unset = "TRUE")),
  apply_melp_rule = Sys.getenv("MELP_RULE", unset = ""), melp_med_abbr = "MELP",
  melp_exposure_days = 30L, melp_restart_days = 60L,
  melp_advance_days = 180L, melp_sct_days = 14L,
  study_end = "2026-03-31"), e)

assign("materialize", function(con, step, view, name, body, qc = NULL) {
  SQL <<- c(SQL, paste0("CREATE OR REPLACE TABLE T_", name, " AS ", body),
                 paste0("CREATE OR REPLACE TEMPORARY VIEW ", view,
                        " AS SELECT * FROM T_", name))
  invisible(paste0("T_", name)) }, e)
assign("run_step", function(con, name, sql, qc = NULL) { SQL <<- c(SQL, sql); TRUE }, e)
assign("db_exec", function(con, sql) { SQL <<- c(SQL, sql); invisible(NULL) }, e)
assign("lot_out", function(n) paste0("T_", n), e)
assign("log_msg", function(...) invisible(NULL), e)
assign("sanitize_col", function(x) gsub("[^A-Za-z0-9]+", "_", toupper(x)), e)
# build_lot2_5 asks the connection two things: the med/class universe, and
# whether the previous line produced rows. Emitting is not running, and the
# statement TEXT for LOT_N does not depend on that count - so a nonzero answer
# just means all five lines are emitted, and the ones no patient reaches come
# out empty at run time.
assign("db_q", function(con, sql) {
  if (grepl("CL_MED_ABBR", sql))  return(data.frame(MED_ABBR = MEDS, stringsAsFactors = FALSE))
  if (grepl("CL_MED_CLASS", sql)) return(data.frame(MED_CLASS = CLASSES, stringsAsFactors = FALSE))
  data.frame(n = 1L)
}, e)

sys.source(file.path(ENGINE, "melp_rule.R"), e)
sys.source(file.path(ENGINE, "cart_rule.R"), e)
for (f in c("04_lot1_base.R", "05b_lot1_sct.R", "06_lot1_end.R", "10_lot2_5_base.R"))
  sys.source(file.path(ENGINE, "steps", f), e)

flag_exprs <- function(vals, col, prefix)
  paste(sprintf("max(case when im.%s = '%s' then 1 else 0 end) as LOT1_%s_%s",
                col, vals, prefix, vals), collapse = ",\n      ")
ctx <- list(meds = MEDS, classes = CLASSES, sanitize_col = e$sanitize_col,
            med_flag_exprs   = flag_exprs(MEDS, "MED_ABBR", "MED"),
            class_flag_exprs = flag_exprs(CLASSES, "MED_CLASS", "CLASS"))

# A step's QC read is a bare expression in its caller, so the stubbed db_q's
# return value autoprints. Nothing here wants that output; only the last line
# of this script is meant for the caller.
sink(tempfile())
invisible(e$phase_lot1_base(NULL, ctx))
invisible(e$phase_lot1_sct(NULL, ctx))
invisible(e$phase_lot1_end(NULL, ctx))
invisible(e$build_lot2_5(NULL, induction_window_days = 30L, cart_consolidation_days = 45L,
               sct_tandem_days = 180L, allo_lot_span = "single_day", max_lot = 5L,
               apply_cart_induction_rule = e$cfg$apply_cart_induction_rule,
               lot1_induction_window_days = 60L))
sink()
writeLines(paste(SQL, collapse = "\n;;;\n"), file.path(OUT, "full_chain.sql"))

# The 2L/3L cohorts, off the lines the chain above builds.
s <- new.env(parent = globalenv())
assign("sql_text", function(x) if (is.na(x)) "NULL" else paste0("'", x, "'"), s)
sys.source(file.path(NDMM, "build_subsequent.R"), s)
for (n in c(2L, 3L))
  writeLines(s$subseq_cohort_sql(n, if (n == 2L) "coh_1l" else "coh_2l",
                                 paste0("coh_", n, "l"),
                                 pre_days = 365L, fu_days = 90L,
                                 lines_tbl = "lot_long_final",
                                 spans_tbl = "spans", spans_strict_tbl = "spans_strict",
                                 run_id = "R1", lot_run = "L1", coh_run = "C1",
                                 coh_stamp = "S1", lot_stamp = "T1", attempt = "A1"),
             file.path(OUT, paste0("sub_", n, "l.sql")))

cat("emitted ", length(SQL), " LOT statements + 2 cohort statements to ", OUT, "\n", sep = "")
