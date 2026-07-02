# =============================================================================
# global.R  --  loaded once at app startup (sourced by app.R)
# -----------------------------------------------------------------------------
# Sources the reusable engine, loads the flagged cohort + LOT-long table, and
# exposes the registry/cohort objects + var lists to ui/server.
# =============================================================================

suppressPackageStartupMessages({ library(shiny) })
HAS_SURVIVAL <- requireNamespace("survival", quietly = TRUE)

.app_dir <- tryCatch(dirname(sys.frame(1)$ofile), error = function(e) getwd())
if (is.null(.app_dir) || !nzchar(.app_dir)) .app_dir <- getwd()

for (f in c("criteria_registry.R", "build_flagged_cohort.R", "cohort_select.R",
            "summaries.R", "km.R", "checks.R", "lot_views.R", "ui_helpers.R")) {
  src <- file.path(.app_dir, "R", f)
  if (file.exists(src)) source(src, local = FALSE)
}

# datasource connection config (single source; used by the programmatic
# warehouse read path in build_flagged_cohort.R)
.wcfg_src <- file.path(.app_dir, "config", "warehouse_config.R")
if (file.exists(.wcfg_src)) source(.wcfg_src, local = FALSE)

REG     <- criteria_registry()
COHORTS <- cohort_definitions()
VARDICT <- variable_dictionary()
EPDICT  <- if (HAS_SURVIVAL) endpoint_dictionary() else list()

# ---- data source (with provenance + fail-closed synthetic guard) ----
# COHORT_EXPLORER_DATA     -> flagged cohort CSV (else deterministic synthetic)
# COHORT_EXPLORER_LOTLONG  -> LOT-long CSV (else synthesised from the cohort)
# ALLOW_SYNTHETIC_LOTLONG  -> "TRUE" to permit synthetic LOT-long with REAL cohort
.data_src <- Sys.getenv("COHORT_EXPLORER_DATA", "synthetic")
.cohort_synthetic <- !nzchar(.data_src) || identical(.data_src, "synthetic")
FLAGGED <- load_flagged_cohort(if (.cohort_synthetic) "synthetic" else .data_src)

.ll_src <- Sys.getenv("COHORT_EXPLORER_LOTLONG", "")
.ll_ok  <- nzchar(.ll_src) && file.exists(.ll_src)
.allow_synth_ll <- toupper(Sys.getenv("ALLOW_SYNTHETIC_LOTLONG", "")) == "TRUE"

# BLOCKER fix #3: never silently fabricate later-line data for a REAL cohort.
if (!.cohort_synthetic && !.ll_ok && !.allow_synth_ll)
  stop("A real flagged cohort (COHORT_EXPLORER_DATA) was supplied without a ",
       "real LOT-long table (COHORT_EXPLORER_LOTLONG). Per-LOT outcomes / ",
       "regimen / transition views would be SYNTHETIC. Provide the LOT-long ",
       "CSV, or set ALLOW_SYNTHETIC_LOTLONG=TRUE to explicitly opt in.",
       call. = FALSE)

.lotlong_synthetic <- !.ll_ok
# load_lot_long derives next_soc if absent and validates the full contract
# (incl. payer_type / next_soc / contiguous 1L.. lines) before use.
LOT_LONG <- load_lot_long(if (.ll_ok) .ll_src else "synthetic", cohort = FLAGGED)
LOT_LONG <- augment_lot_long(LOT_LONG, FLAGGED)   # carry baseline strata forward

# provenance banner (surfaced in the UI whenever any source is synthetic)
PROVENANCE <- list(
  cohort_synthetic  = .cohort_synthetic,
  lotlong_synthetic = .lotlong_synthetic,
  any_synthetic     = .cohort_synthetic || .lotlong_synthetic)

REG$flt_soc$default <- sort(unique(FLAGGED$soc_category))
MAX_LOT <- 5L

# lines offered in the per-LOT selector (protocol focuses on 1L/2L/3L)
LOT_CHOICES <- setNames(sort(unique(LOT_LONG$lot_num)),
                        paste0(sort(unique(LOT_LONG$lot_num)), "L"))
LOT_CHOICES <- LOT_CHOICES[LOT_CHOICES <= 3L]

# summary + strata variables
SUMMARY_VARS <- names(VARDICT)
STRATA_VARS  <- names(VARDICT)[vapply(names(VARDICT),
  function(v) var_type(v, VARDICT) %in% c("cat", "binary"), logical(1))]
STRATA_LABELLED <- setNames(STRATA_VARS, vapply(STRATA_VARS, var_label,
                                                character(1), dict = VARDICT))

# covariates offered to the adjusted (Cox) model: the strata set + clinically
# meaningful continuous measures (age, CCI). Outcome/ID/date fields excluded.
COVARS <- c(STRATA_VARS, "age_index", "cci")
COVARS_LABELLED <- setNames(COVARS, vapply(COVARS, var_label, character(1), dict = VARDICT))
