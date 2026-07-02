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
# The ONE shared typed-config contract (CONFIG_SPEC) governs param validation too -
# no second spec to drift. Source it (and the reference-data validator) standalone when
# not already loaded by the runner.
local({
  fa <- grep("^--file=", commandArgs(FALSE), value = TRUE)
  d <- if (length(fa)) dirname(sub("^--file=", "", fa[1])) else "engine"
  src <- function(f) { p <- file.path(d, "..", "scripts", f); if (!file.exists(p)) p <- file.path("scripts", f)
    if (file.exists(p)) source(p) }
  if (!exists("CONFIG_SPEC")) src("validate_config.R")
  if (!exists("validate_reference_data")) src("validate_reference_data.R")
})

# Params are DATA (resolved config). DEFAULTS are DERIVED from the ONE shared
# CONFIG_SPEC (the refactor's typed contract) - a single source, so engine defaults
# can't drift from the spec's defaults. (the production pipeline still resolves config
# from env vars via config_lot.R and does not yet consume CONFIG_SPEC - wiring that is
# a future step; here CONFIG_SPEC is the refactor's validation contract.)
if (!exists("CONFIG_SPEC")) stop("run_engine: CONFIG_SPEC not loaded (scripts/validate_config.R)")
.ENGINE_PARAMS <- c("map_discon_gap_days", "medical_day_supply", "induction_window_days",
                    "lot_n_induction_window_days", "cart_consolidation_days", "sct_auto_window_days",
                    "sct_auto_gap_days", "sct_tandem_days", "allo_lot_span", "max_lot")
DEFAULT_PARAMS <- lapply(CONFIG_SPEC[.ENGINE_PARAMS], `[[`, "default")
# Fail-closed validation against CONFIG_SPEC's engine-tunable subset. Validates the
# FULL RESOLVED config (not just the overrides), so even a no-override run is checked,
# and an unknown override key (modifyList would silently add it) is rejected. Out-of-
# range (e.g. map_discon_gap_days=0), non-integer, and bad enums all fail closed.
# validate_canonical() of the input ROWS is still pending - see README.
.validate_params <- function(cfg) {
  if (!exists("validate_config")) stop("run_engine: validate_config (scripts/validate_config.R) not loaded")
  errs <- validate_config(cfg, spec = CONFIG_SPEC[.ENGINE_PARAMS])
  if (length(errs)) stop("run_engine: invalid engine config: ", paste(errs, collapse = "; "))
  invisible(TRUE)
}

# Full local pipeline MAP -> LOT1 -> SCT -> LOT1 end.
REQUIRED_INPUTS <- c("pharmacy.csv", "rollup.csv", "members.csv", "sct_codelist.csv")

run_engine <- function(input_dir, params = list()) {
  p <- modifyList(DEFAULT_PARAMS, params)
  .validate_params(p)                                # validate the FULL RESOLVED config, fail closed
  miss <- REQUIRED_INPUTS[!file.exists(file.path(input_dir, REQUIRED_INPUTS))]
  if (length(miss))                                  # fail closed - never emit partial output
    stop("run_engine: missing required input(s): ", paste(miss, collapse = ", "))
  rd <- function(f) { pp <- file.path(input_dir, f)
    if (file.exists(pp)) read.csv(pp, stringsAsFactors = FALSE, colClasses = "character")
    else data.frame() }
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
  rollup <- rd("rollup.csv"); names(rollup) <- tolower(names(rollup))
  # Headers are CANONICALIZED to lowercase so the engine's case-sensitive reads
  # (map.R `rollup$code_type` etc., .maint_maps `rollup$med_abbr`) work regardless of
  # input case - validation and consumption are consistent. Case-folding two headers
  # onto one name is ambiguous, so reject duplicates.
  if (anyDuplicated(names(rollup)))
    stop("run_engine: rollup.csv has duplicate column names after case-normalization: ",
         paste(unique(names(rollup)[duplicated(names(rollup))]), collapse = ", "))
  # STRUCTURE: rows + every consumed column - code_type/code/med_abbr/med_class (MAP)
  # PLUS monomaintenance/dualmaintenancewith (maintenance; production cl_mma_rollup).
  need_ru <- c("code_type", "code", "med_abbr", "med_class", "monomaintenance", "dualmaintenancewith")
  if (!nrow(rollup) || !all(need_ru %in% names(rollup)))
    stop("run_engine: rollup.csv must have rows and columns ", paste(need_ru, collapse = "/"),
         " (case-insensitive; reference + maintenance metadata; contains_mtx_reg must be evaluated)")
  # SEMANTICS via the shared reference-data validator (not one-off checks): blank
  # code/med_abbr, code-system domain, NDC 11-digit, and one (code_system, code) mapping
  # to >1 medication (collision) all BLOCK - so a rows-but-unusable rollup fails clearly
  # instead of silently emptying MAP/LOT. (`med_abbr` is the mapped_to concept.)
  if (exists("validate_reference_data")) {
    ru_chk <- validate_reference_data(transform(rollup, mapped_to = med_abbr),
                                      list(id = "rollup", row_count_min = 1L))
    if (length(ru_chk$errors))
      stop("run_engine: rollup.csv reference-data errors: ", paste(ru_chk$errors, collapse = "; "))
  }
  # med_class is a rollup-specific column (outside the reference-data code/concept
  # contract) that drives STEROID exclusion + LOT start/end decisions (lot1.R / lot_long.R).
  # A blank value would silently treat e.g. a DEX row as non-steroid, so reject it.
  blank_mc <- !nzchar(trimws(as.character(rollup$med_class)))
  if (any(blank_mc))
    stop("run_engine: rollup.csv has ", sum(blank_mc), " row(s) with blank med_class ",
         "(drives steroid exclusion / LOT decisions; must be non-blank)")
  map_stacked <- build_map_stacked(rd("pharmacy.csv"), med, rollup, members,
    p$map_discon_gap_days, p$medical_day_supply)
  lot1 <- build_lot1_base(map_stacked, members, if (nrow(subs)) subs else NULL, p$induction_window_days)
  # SCT from ALL canonical evidence routes (procedure + diagnosis + medical).
  sct_claims <- extract_sct_claims(proc, codelist, diagnosis = diag, medical = med)
  sct <- if (nrow(lot1)) build_sct_summary(sct_claims, lot1[, c("patient_id", "lot1_start_dt")],
            members, p$sct_tandem_days, p$sct_auto_window_days, p$sct_auto_gap_days) else NULL
  auto_dates <- finalize_auto_per_patient(sct_claims, members, p$sct_auto_window_days, p$sct_auto_gap_days, p$sct_tandem_days)
  deathd <- if (nrow(death)) death else NULL; subsd <- if (nrow(subs)) subs else NULL
  lot1_end <- build_lot1_end(lot1, sct, members, deathd, map_stacked = map_stacked,
                             auto_dates = auto_dates, permissible_subs = subsd,
                             cart_consolidation_days = p$cart_consolidation_days,        # propagate ALL
                             lot_n_induction_window_days = p$lot_n_induction_window_days, # tunables to LOT1
                             sct_tandem_days = p$sct_tandem_days)                         # (CART_INIT / death guard)
  lot_long <- build_lot_long(lot1, lot1_end, map_stacked, sct_claims, members, deathd, subsd,
                p$lot_n_induction_window_days, p$cart_consolidation_days, p$sct_tandem_days,
                p$sct_auto_window_days, p$sct_auto_gap_days,
                allo_lot_span = p$allo_lot_span, max_lot = p$max_lot, rollup = rollup)
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
