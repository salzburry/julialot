#!/usr/bin/env Rscript
# Emit the QC catalogue's SQL, bound to the tables the synthetic harness builds.
#
#   Rscript validation/synthetic/emit_qc.R <out_file.tsv>
#
# The harness used to carry Python rewrites of two QC predicates. They proved
# the rewrites. A rewrite can be right while the shipped check is wrong, and
# that is exactly what happened: the synthetic run was green over a valid
# AUTO-started line with an empty regimen while the real A7 would have failed
# it, because A7's allowed list was missing SCT_AUTO and the copy did not exist.
#
# So nothing is retyped here either. checks.R is sourced and asked for its own
# SQL, the same way emit_chain.R asks the step files for theirs. What runs
# against the synthetic patients is what runs against the warehouse.
#
# Two settings follow the environment, the same two emit_chain.R reads, so a
# sensitivity run judges its output by the settings it was built with.
#
# Not part of the merge gate. See README.md in this directory.

args <- commandArgs(trailingOnly = TRUE)
OUT  <- if (length(args) >= 1) args[1] else stop("emit_qc.R <out_file.tsv>")

HERE <- local({
  a <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  if (!length(a)) getwd()
  else dirname(normalizePath(gsub("~+~", " ", sub("^--file=", "", a[1]), fixed = TRUE)))
})
REPO  <- dirname(dirname(HERE))
STUDY <- Sys.getenv("STUDY_FOLDER", unset = "Jul 28")
QC    <- file.path(REPO, STUDY, "lot", "qc", "R", "checks.R")
if (!file.exists(QC)) {
  cat("SKIP: no QC catalogue at ", QC, "\n", sep = ""); quit(status = 3L)
}
source(QC)

# The duckdb names the harness leaves behind, against the handles the checks
# ask for. lot_patient_input stands in for the cohort table: it carries the
# PATID, INDEX_DATE, ENDDATE, ENDDATE_CE and DEATH_DT the cohort checks read,
# which is every column they touch.
#
# attrition and meta are absent - the funnel and the metadata row are written
# by build_lot.R, not by the emitted chain - so the checks needing them are
# reported as skipped rather than quietly left out.
TBL <- list(final = "lot_long_final", long = "lot_long", map = "map_stacked",
            sct = "lot1_sct", auto = "tx_auto_dates",
            allo = "tx_allo_cart_dates", cohort = "lot_patient_input",
            subs = "permissible_subs")

# SCENARIO=1 emits the same checks against the tiny hand-built tables in
# qc_scenarios.py instead. Those cover the checks the patient chain cannot
# reach - the funnel and metadata tables are written by build_lot.R in R, not
# by the emitted SQL - and E1, whose failure a correct build cannot produce.
if (nzchar(Sys.getenv("SCENARIO", unset = "")))
  TBL <- list(final = "qc_final", attrition = "qc_attrition", sct = "qc_sct1",
              long = "qc_final", map = "qc_final", auto = "qc_final",
              allo = "qc_final", cohort = "qc_final", meta = "qc_final")

# Built through qc_params rather than hand-assembled, so the settings parsing
# is exercised by the same run. The two the harness varies come from the
# environment; the rest are the contract.
settings <- paste(c(
  "allo_lot_span=single_day",
  paste0("apply_cart_induction_rule=", Sys.getenv("CART_RULE", unset = "TRUE")),
  "belantamab_med_abbr=BELA", "cart_consolidation_days=45",
  "censor_at_disenrollment=FALSE", "induction_window_days=60",
  paste0("lot_discon_confirm_days=", Sys.getenv("CONFIRM_DAYS", unset = "90")),
  "lot_n_induction_window_days=30", "map_discon_gap_days=90", "max_lot=5",
  "medical_day_supply=28", "sct_auto_gap_days=60", "sct_auto_window_days=13",
  "sct_tandem_days=180",
  paste0("apply_melp_rule=",
         Sys.getenv("MELP_RULE", unset = "simplified")),
  paste0("apply_map_foldin=",
         Sys.getenv("MAP_FOLDIN", unset = "TRUE")),
  paste0("apply_own_return_fold=",
         Sys.getenv("OWN_RETURN_FOLD", unset = "TRUE"))), collapse = "|")
p <- qc_params(settings, "synthetic")
# E1 reads the raw per-line flags, and the runner tells it which lines the run
# wrote. Under SCENARIO the fixture supplies LOT2 only, which is the case the
# patient run cannot make fail.
p$sct_extra <- if (nzchar(Sys.getenv("SCENARIO", unset = "")))
  c("2" = "qc_sct2") else character(0)

# Checks the harness cannot answer even though it has the tables, because the
# stand-in table does not carry what they read. map_stacked is an INPUT here -
# 03_mma_map.R cannot run under duckdb, see README.md - so it is built by the
# generator with the columns the line rules read, and not the two per-source
# run-out dates the episode state machine leaves behind. Asking D2 of it would
# ask whether the generator agrees with itself.
#
# Named rather than allowed to error, so the reason is in the file rather than
# in whoever reads the traceback.
UNANSWERABLE <- c(
  D2 = "map_stacked is a fixture here and carries no per-source run-out dates")

rows <- lapply(LOT_QC_CHECKS, function(c_i) {
  missing <- setdiff(c_i$needs, names(TBL))
  if (!is.na(UNANSWERABLE[c_i$id]) && !length(missing))
    missing <- unname(UNANSWERABLE[c_i$id])
  data.frame(
    id       = c_i$id,
    severity = c_i$severity,
    what     = c_i$what,
    missing  = paste(missing, collapse = ","),
    # One line, so the file stays a TSV. The reader puts the newlines back.
    sql      = if (length(missing)) ""
               else gsub("\t", " ", gsub("\n", "\\\\n", c_i$sql(TBL, p))),
    stringsAsFactors = FALSE)
})
out <- do.call(rbind, rows)
write.table(out, OUT, sep = "\t", row.names = FALSE, quote = FALSE)
cat("emitted ", sum(!nzchar(out$missing)), " of ", nrow(out),
    " QC checks (", sum(nzchar(out$missing)), " need tables the harness has no",
    " counterpart for)\n", sep = "")
