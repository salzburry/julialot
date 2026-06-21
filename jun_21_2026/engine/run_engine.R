#!/usr/bin/env Rscript
# engine/run_engine.R - driver for the LOCAL verification engine: read canonical
# inputs + codelist + resolved params, run the modular core, write outputs. This
# is the harness that lets us see the refactor reproduce behaviour on synthetic
# data locally; production is Databricks SQL on hive_metastore (separate).

if (!exists("build_lot_long")) local({
  fa <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (length(fa)) dirname(sub("^--file=", "", fa[1])) else "engine"
  if (!file.exists(file.path(d, "map.R"))) d <- "engine"          # robust when sourced
  for (m in c("map.R", "lot1.R", "sct.R", "lot_end.R", "lot_long.R")) source(file.path(d, m))
})

# Params are DATA (resolved config), so retuning the algorithm is a config edit.
DEFAULT_PARAMS <- list(map_discon_gap_days = 90L, medical_day_supply = 28L,
                       induction_window_days = 60L, lot_n_induction_window_days = 30L,
                       cart_consolidation_days = 45L, sct_auto_window_days = 13L,
                       sct_auto_gap_days = 60L, sct_tandem_days = 180L,
                       allo_lot_span = "single_day", max_lot = 5L)

# Full local pipeline MAP -> LOT1 -> SCT -> LOT1 end.
REQUIRED_INPUTS <- c("pharmacy.csv", "rollup.csv", "members.csv", "sct_codelist.csv")

run_engine <- function(input_dir, params = list()) {
  miss <- REQUIRED_INPUTS[!file.exists(file.path(input_dir, REQUIRED_INPUTS))]
  if (length(miss))                                  # fail closed - never emit partial output
    stop("run_engine: missing required input(s): ", paste(miss, collapse = ", "))
  rd <- function(f) { p <- file.path(input_dir, f)
    if (file.exists(p)) read.csv(p, stringsAsFactors = FALSE, colClasses = "character")
    else data.frame() }
  p <- modifyList(DEFAULT_PARAMS, params)
  if (!all(c("index_date", "obs_end_dt") %in% names(read.csv(file.path(input_dir, "members.csv"),
            nrows = 1, stringsAsFactors = FALSE))))
    stop("run_engine: members.csv must carry index_date + obs_end_dt (claim-window scoping)")
  members <- rd("members.csv"); subs <- rd("permissible_subs.csv"); death <- rd("death.csv")
  proc <- rd("procedure.csv"); diag <- rd("diagnosis.csv"); med <- rd("medical.csv")
  # sct_codelist.csv is required by CONTENT, not just by filename: it must carry
  # rows AND the matching columns, so SCT evidence on ANY route (procedure /
  # diagnosis / medical) can never silently yield no SCT (README contract).
  codelist <- rd("sct_codelist.csv"); need_cl <- c("code_type", "code", "sct_type")
  if (!nrow(codelist) || !all(need_cl %in% names(codelist)))
    stop("run_engine: sct_codelist.csv must have rows and columns ",
         paste(need_cl, collapse = "/"), " (SCT evidence cannot be silently empty)")
  map_stacked <- build_map_stacked(rd("pharmacy.csv"), med, rd("rollup.csv"), members,
    p$map_discon_gap_days, p$medical_day_supply)
  lot1 <- build_lot1_base(map_stacked, members, if (nrow(subs)) subs else NULL, p$induction_window_days)
  # SCT from ALL canonical evidence routes (procedure + diagnosis + medical).
  sct_claims <- extract_sct_claims(proc, codelist, diagnosis = diag, medical = med)
  sct <- if (nrow(lot1)) build_sct_summary(sct_claims, lot1[, c("patient_id", "lot1_start_dt")],
            members, p$sct_tandem_days, p$sct_auto_window_days, p$sct_auto_gap_days) else NULL
  auto_dates <- finalize_auto_per_patient(sct_claims, members, p$sct_auto_window_days, p$sct_auto_gap_days, p$sct_tandem_days)
  deathd <- if (nrow(death)) death else NULL; subsd <- if (nrow(subs)) subs else NULL
  lot1_end <- build_lot1_end(lot1, sct, members, deathd, map_stacked = map_stacked,
                             auto_dates = auto_dates, permissible_subs = subsd)
  lot_long <- build_lot_long(lot1, lot1_end, map_stacked, sct_claims, members, deathd, subsd,
                p$lot_n_induction_window_days, p$cart_consolidation_days, p$sct_tandem_days,
                p$sct_auto_window_days, p$sct_auto_gap_days,
                allo_lot_span = p$allo_lot_span, max_lot = p$max_lot)
  list(MAP_STACKED = map_stacked, LOT1_BASE = lot1, LOT1_END = lot1_end, LOT_LONG = lot_long)
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
