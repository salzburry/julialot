#!/usr/bin/env Rscript
# engine/run_engine.R - driver for the LOCAL verification engine: read canonical
# inputs + codelist + resolved params, run the modular core, write outputs. This
# is the harness that lets us see the refactor reproduce behaviour on synthetic
# data locally; production is Databricks SQL on hive_metastore (separate).

if (!exists("build_lot1_end")) local({
  fa <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (length(fa)) dirname(sub("^--file=", "", fa[1])) else "engine"
  for (m in c("map.R", "lot1.R", "sct.R", "lot_end.R")) source(file.path(d, m))
})

# Params are DATA (resolved config), so retuning the algorithm is a config edit.
DEFAULT_PARAMS <- list(map_discon_gap_days = 90L, medical_day_supply = 28L,
                       induction_window_days = 60L, sct_auto_window_days = 13L,
                       sct_auto_gap_days = 60L, sct_tandem_days = 180L)

# Full local pipeline MAP -> LOT1 -> SCT -> LOT1 end.
run_engine <- function(input_dir, params = list()) {
  rd <- function(f) { p <- file.path(input_dir, f)
    if (file.exists(p)) read.csv(p, stringsAsFactors = FALSE, colClasses = "character")
    else data.frame() }
  p <- modifyList(DEFAULT_PARAMS, params)
  members <- rd("members.csv"); subs <- rd("permissible_subs.csv"); death <- rd("death.csv")
  map_stacked <- build_map_stacked(rd("pharmacy.csv"), rd("medical.csv"),
    rd("rollup.csv"), members, p$map_discon_gap_days, p$medical_day_supply)
  lot1 <- build_lot1_base(map_stacked, members, if (nrow(subs)) subs else NULL, p$induction_window_days)
  sct_claims <- extract_sct_claims(rd("procedure.csv"), rd("sct_codelist.csv"))
  sct <- if (nrow(lot1)) build_sct_summary(sct_claims, lot1[, c("patient_id", "lot1_start_dt")],
            members, p$sct_tandem_days, p$sct_auto_window_days, p$sct_auto_gap_days) else NULL
  auto_dates <- finalize_auto_per_patient(sct_claims, p$sct_auto_window_days, p$sct_auto_gap_days, p$sct_tandem_days)
  list(MAP_STACKED = map_stacked, LOT1_BASE = lot1,
       LOT1_END = build_lot1_end(lot1, sct, members, if (nrow(death)) death else NULL,
                    map_stacked = map_stacked, auto_dates = auto_dates,
                    permissible_subs = if (nrow(subs)) subs else NULL))
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
