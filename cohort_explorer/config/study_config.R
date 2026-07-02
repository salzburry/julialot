# =============================================================================
# study_config.R  --  the ONE place study-level knobs live.
# -----------------------------------------------------------------------------
# This is the shared, reusable study definition. BOTH sides read it:
#   * the apr_30_2026 analytic-cohort BUILD (materialisation) -- so a new study
#     is a config change, not an algorithm edit (env vars in config_lot.R /
#     config_prompts.R map 1:1 to these keys; see the mapping below);
#   * the DASHBOARD -- criteria_registry() / cohort_definitions() / the
#     synthetic generator read their defaults from here.
#
# Config-as-R (no yaml dependency). Values here are the study PARAMETERS; the
# IE criteria catalogue itself is criteria_registry.R and the cohort flag-sets
# are cohort_definitions().
#
# env-var mapping (apr_30 build reads these; blank => default):
#   study_start          STUDY_START
#   study_end            STUDY_END
#   id_start / id_end    (cohort id window; config_prompts.R)
#   lot1_from            NDMM_LOT1_FROM
#   pre_lot1_days        NDMM_PRE_LOT1_DAYS   (currently hard-coded 365 in 06 -> lift)
#   ce_gap_days          GAP_DAYS
#   induction_window_days / lot_n_induction_window_days / map_discon_gap_days /
#     sct_* / cart_consolidation_days / max_lot   -> identical keys in config_lot.R
# =============================================================================

study_config <- function() {
  list(
    # study + identification windows
    study_start = "2015-07-01",
    study_end   = "2025-06-30",
    id_start    = "2016-01-01",
    id_end      = "2025-06-30",

    # NDMM 1L anchoring
    lot1_from     = "2017-01-01",   # eligible-1L cutoff
    pre_lot1_days = 365L,           # 12-mo pre-LOT1 baseline (was hard-coded in 06)
    ce_gap_days   = 30L,            # allowable enrollment gap counted as continuous

    # continuous-enrollment requirement, per cohort (months)
    baseline_ce_months = list(overall = 6L, ndmm = 12L),
    followup_ce_months = list(overall = 0L, ndmm = 3L),

    # demographic gate
    age_min = 18L,

    # LOT algorithm params (mirror config_lot.R defaults; kept here so a study
    # override is declared in ONE file and flows to both build + dashboard)
    induction_window_days       = 60L,
    lot_n_induction_window_days = 30L,
    map_discon_gap_days         = 90L,
    sct_auto_window_days        = 13L,
    sct_auto_gap_days           = 60L,
    sct_tandem_days             = 180L,
    cart_consolidation_days     = 45L,
    max_lot                     = 5L,

    # TTE analysis
    min_followup_months = 3L,               # protocol >=3-mo restriction
    landmark_months     = c(6, 9, 12, 18, 24),

    # SOC regimen category map (production loads the full drug->category list
    # from the GSK LoT-algorithm doc; here we carry the §6.2.2 scheme labels)
    soc_categories_1l    = c(
      "Quadruplet with anti-CD38 backbone", "Triplet with anti-CD38 backbone",
      "Other triplet (non-anti-CD38)", "Doublet", "Monotherapy", "Other"),
    soc_categories_later = c(
      "Triplet with anti-CD38 backbone", "Other triplet (non-anti-CD38)",
      "Other novel agent (e.g. selinexor)", "CAR-T",
      "Bispecific (BCMA / non-BCMA)", "Doublet", "Monotherapy")
  )
}

# Resolve the config, letting env vars override (so the apr_30 batch run and the
# dashboard honour the same overrides). Only scalar keys are env-overridable.
resolved_study_config <- function(cfg = study_config()) {
  env_int <- function(name, default) {
    v <- Sys.getenv(name, unset = "")
    if (nzchar(v)) as.integer(v) else default
  }
  env_chr <- function(name, default) {
    v <- Sys.getenv(name, unset = ""); if (nzchar(v)) v else default
  }
  cfg$study_start   <- env_chr("STUDY_START", cfg$study_start)
  cfg$study_end     <- env_chr("STUDY_END",   cfg$study_end)
  cfg$lot1_from     <- env_chr("NDMM_LOT1_FROM", cfg$lot1_from)
  cfg$pre_lot1_days <- env_int("NDMM_PRE_LOT1_DAYS", cfg$pre_lot1_days)
  cfg$ce_gap_days   <- env_int("GAP_DAYS", cfg$ce_gap_days)
  cfg$max_lot       <- env_int("MAX_LOT", cfg$max_lot)
  cfg
}

# =============================================================================
# study_config -> apr_30_2026 build mapping.
# -----------------------------------------------------------------------------
# apr_30's pipeline reads its knobs from env vars (config_lot.R / config_prompts.R).
# This turns ONE study_config into the exact env var set the apr_30 run +
# analytic-cohort materialisation consume, so a study is defined in one place and
# flows to the (slow, warehouse) build. Keys with no apr_30 consumer today are
# still emitted (marked) so they wire straight through once lifted (e.g. 06's
# hard-coded NDMM_PRE_LOT1_DAYS = 365).
# =============================================================================
study_config_to_env <- function(cfg = resolved_study_config()) {
  c(
    STUDY_START                = cfg$study_start,
    STUDY_END                  = cfg$study_end,
    NDMM_LOT1_FROM             = cfg$lot1_from,
    NDMM_PRE_LOT1_DAYS         = as.character(cfg$pre_lot1_days), # lift 06's 365
    GAP_DAYS                   = as.character(cfg$ce_gap_days),
    INDUCTION_WINDOW_DAYS      = as.character(cfg$induction_window_days),
    INDUCTION_WINDOW_DAYS_LOT_N= as.character(cfg$lot_n_induction_window_days),
    MAP_DISCON_GAP_DAYS        = as.character(cfg$map_discon_gap_days),
    SCT_AUTO_WINDOW_DAYS       = as.character(cfg$sct_auto_window_days),
    SCT_AUTO_GAP_DAYS          = as.character(cfg$sct_auto_gap_days),
    SCT_TANDEM_DAYS            = as.character(cfg$sct_tandem_days),
    CART_CONSOLIDATION_DAYS    = as.character(cfg$cart_consolidation_days),
    MAX_LOT                    = as.character(cfg$max_lot)
  )
}

# Emit the mapping as shell `export` lines (for `source pipeline_env.sh; Rscript
# run_pipeline.R`) and, when apply=TRUE, also set them in this R session.
emit_pipeline_env <- function(cfg = resolved_study_config(), file = NULL,
                              apply = FALSE) {
  kv <- study_config_to_env(cfg)
  lines <- sprintf('export %s="%s"', names(kv), kv)
  if (!is.null(file)) writeLines(lines, file)
  if (isTRUE(apply)) do.call(Sys.setenv, as.list(kv))
  invisible(kv)
}
