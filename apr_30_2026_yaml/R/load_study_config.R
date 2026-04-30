# ============================================================
# load_study_config.R — YAML-backed study/methodology config
# ============================================================
# One source of truth for parameters that BOTH Part 1 (main.R) and
# Part 2 (lot_program.R) must agree on. Infrastructure / secrets stay
# in env vars.
#
# Precedence (low -> high):
#   hard-coded defaults  <  configs/study.yaml  <  environment variables
#
# Public surface:
#   resolve_study_config(yaml_path, run_id, output_dir)
#       -> list(cfg = <flat-named list>, provenance = <list>)
#       Always writes <output_dir>/resolved_config_<run_id>.yaml.
#
# All values returned in `cfg` use the SAME flat keys the existing
# code already references (cfg$study_end, cfg$apply_age_incl, etc.),
# so callers don't change their lookup style.
# ============================================================

# ---- Hard-coded defaults (lowest precedence) ----
# Mirror configs/study.yaml in shape; used only if a key is missing
# from BOTH the YAML and the env-var override. Server runs must have
# study.yaml so these defaults are essentially safety belts.
.STUDY_DEFAULTS <- list(
  study = list(
    start = "2015-07-01", end = "2025-06-30",
    id_start = "2016-01-01", id_end = "2025-06-30",
    baseline_days = 183L, gap_days = 30L
  ),
  ie = list(
    outpatient_window = 90L, min_age = 18L,
    apply_age_incl = TRUE, apply_ce_b_incl = TRUE, apply_ce_f_incl = TRUE,
    apply_no_bl_agents_incl = TRUE, apply_fu_agents_incl = TRUE,
    apply_pregnancy_excl = TRUE, apply_clintrial_excl = TRUE,
    apply_other_malig_excl = TRUE, apply_baseline_mm_excl = TRUE
  ),
  lot = list(
    induction_window_days = 60L, map_discon_gap_days = 90L,
    lot_discon_gap_days = 90L, medical_day_supply = 28L,
    cart_consolidation_days = 45L,
    sct_auto_window_days = 13L, sct_auto_gap_days = 60L,
    sct_tandem_days = 180L
  ),
  sensitivity = list(censor_at_disenrollment = FALSE),
  codelists = list(
    dir = "/mnt/code/codelist",
    files = list(
      cl_mm_dx = "mm_dx.csv",
      cl_mm_therapy = "cl_mma_codelist.csv",
      cl_mma_codelist = "cl_mma_codelist.csv",
      cl_mma_rollup = "cl_mma_rollup.csv",
      cl_sct_codelist = "cl_sct_codelist.csv",
      cl_permissible_subs = "permissible_subs.csv",
      cl_pregnancy = "pregnancy.csv",
      cl_clintrial = "clintrial.csv",
      cl_other_malignancies = "other_malig.csv"
    )
  )
)

# ---- Env-var override map ----
# (yaml_path, env_var, parser). Anything not listed here cannot be
# overridden via env var — that's intentional, keeps the surface small.
.ENV_OVERRIDES <- list(
  list("study.start",                          "STUDY_START",              identity),
  list("study.end",                            "STUDY_END",                identity),
  list("study.id_start",                       "ID_START",                 identity),
  list("study.id_end",                         "ID_END",                   identity),
  list("ie.outpatient_window",                 "OUTPATIENT_WINDOW",        as.integer),
  list("ie.min_age",                           "MIN_AGE",                  as.integer),
  list("ie.apply_pregnancy_excl",              "APPLY_PREGNANCY_EXCL",     as.logical),
  list("ie.apply_clintrial_excl",              "APPLY_CLINTRIAL_EXCL",     as.logical),
  list("ie.apply_other_malig_excl",            "APPLY_OTHER_MALIG_EXCL",   as.logical),
  list("ie.apply_baseline_mm_excl",            "APPLY_BASELINE_MM_EXCL",   as.logical),
  list("lot.induction_window_days",            "INDUCTION_WINDOW_DAYS",    as.integer),
  list("lot.map_discon_gap_days",              "MAP_DISCON_GAP_DAYS",      as.integer),
  list("lot.lot_discon_gap_days",              "LOT_DISCON_GAP_DAYS",      as.integer),
  list("lot.medical_day_supply",               "MEDICAL_DAY_SUPPLY",       as.integer),
  list("lot.cart_consolidation_days",          "CART_CONSOLIDATION_DAYS",  as.integer),
  list("lot.sct_auto_window_days",             "SCT_AUTO_WINDOW_DAYS",     as.integer),
  list("lot.sct_auto_gap_days",                "SCT_AUTO_GAP_DAYS",        as.integer),
  list("lot.sct_tandem_days",                  "SCT_TANDEM_DAYS",          as.integer),
  list("sensitivity.censor_at_disenrollment",  "CENSOR_AT_DISENROLLMENT",  as.logical),
  list("codelists.dir",                        "CODELIST_DIR",             identity)
)

# ---- Helpers ----

# Recursive deep merge. `overlay` wins where keys overlap.
# Note: base R modifyList() is recursive but only descends into named
# lists; we wrap it so the intent is obvious + easy to test.
deep_merge_config <- function(base, overlay) {
  if (is.null(overlay)) return(base)
  if (is.null(base))    return(overlay)
  utils::modifyList(base, overlay, keep.null = FALSE)
}

# Get/set values by dotted path ("ie.min_age").
.split_path <- function(path) strsplit(path, "\\.", fixed = FALSE)[[1]]

get_nested <- function(lst, path) {
  parts <- .split_path(path)
  cur <- lst
  for (p in parts) {
    if (!is.list(cur) || is.null(cur[[p]])) return(NULL)
    cur <- cur[[p]]
  }
  cur
}

set_nested <- function(lst, path, value) {
  parts <- .split_path(path)
  if (length(parts) == 1L) {
    lst[[parts]] <- value
    return(lst)
  }
  head_p <- parts[1]; rest <- paste(parts[-1], collapse = ".")
  if (is.null(lst[[head_p]]) || !is.list(lst[[head_p]])) lst[[head_p]] <- list()
  lst[[head_p]] <- set_nested(lst[[head_p]], rest, value)
  lst
}

# All leaf paths in a nested list (ignores empty branches).
flatten_paths <- function(lst, prefix = "") {
  out <- character(0)
  for (nm in names(lst)) {
    val <- lst[[nm]]
    full <- if (nzchar(prefix)) paste0(prefix, ".", nm) else nm
    if (is.list(val) && length(names(val))) {
      out <- c(out, flatten_paths(val, full))
    } else {
      out <- c(out, full)
    }
  }
  out
}

# Flatten a nested config into a single-level named list using only
# the LEAF key names (drops the "study.", "ie.", etc. prefixes).
# Keeps codelists.files as a sub-list since downstream code uses it
# as `cfg$codelist_csv_map`.
.flatten_to_legacy_cfg <- function(nested) {
  out <- list()
  for (sec in c("study", "ie", "lot", "sensitivity")) {
    blk <- nested[[sec]]
    if (is.null(blk)) next
    for (nm in names(blk)) out[[nm]] <- blk[[nm]]
  }
  if (!is.null(nested$codelists$dir))   out$codelist_dir     <- nested$codelists$dir
  if (!is.null(nested$codelists$files)) out$codelist_csv_map <- nested$codelists$files
  out
}

# ---- Codelist CSV existence check ----
validate_codelists <- function(cfg_dir, csv_map) {
  if (!dir.exists(cfg_dir)) {
    stop("Codelist directory does not exist: ", cfg_dir)
  }
  missing <- character(0)
  for (nm in names(csv_map)) {
    f <- file.path(cfg_dir, csv_map[[nm]])
    if (!file.exists(f)) missing <- c(missing, paste0("  - ", nm, " -> ", f))
  }
  if (length(missing)) {
    stop("Missing codelist CSV files:\n", paste(missing, collapse = "\n"))
  }
  invisible(TRUE)
}

# ============================================================
# Public: resolve_study_config()
# ============================================================
resolve_study_config <- function(yaml_path = "configs/study.yaml",
                                 run_id    = format(Sys.time(), "%Y%m%d%H%M%S"),
                                 output_dir = NULL,
                                 require_yaml = TRUE,
                                 validate_codelist_files = TRUE) {

  if (!requireNamespace("yaml", quietly = TRUE)) {
    stop("R package 'yaml' is required. Install with: install.packages('yaml')")
  }

  # 1. Defaults
  resolved   <- .STUDY_DEFAULTS
  provenance <- list()
  for (p in flatten_paths(resolved)) {
    provenance[[p]] <- list(source = "default")
  }

  # 2. YAML
  if (file.exists(yaml_path)) {
    yml <- yaml::read_yaml(yaml_path)
    resolved <- deep_merge_config(resolved, yml)
    for (p in flatten_paths(yml)) {
      provenance[[p]] <- list(source = "study.yaml", path = normalizePath(yaml_path))
    }
  } else if (isTRUE(require_yaml)) {
    stop("Study config not found: ", yaml_path,
         "\nServer runs must have configs/study.yaml. ",
         "Searched: ", normalizePath(yaml_path, mustWork = FALSE))
  }

  # 3. Env-var overrides
  for (ov in .ENV_OVERRIDES) {
    path     <- ov[[1]]; envv <- ov[[2]]; parser <- ov[[3]]
    raw <- Sys.getenv(envv, unset = NA_character_)
    if (is.na(raw) || !nzchar(raw)) next
    val <- tryCatch(parser(raw),
                    warning = function(w) stop("Env var ", envv, "=", raw,
                                               " could not be parsed: ", conditionMessage(w)))
    resolved <- set_nested(resolved, path, val)
    provenance[[path]] <- list(source = "env_var", env_var = envv, raw = raw)
  }

  # 4. Validate codelist files exist on disk (best-effort: skip in offline tests)
  if (isTRUE(validate_codelist_files)) {
    validate_codelists(resolved$codelists$dir, resolved$codelists$files)
  }

  # 5. Write resolved config (always, if output_dir given)
  if (!is.null(output_dir) && nzchar(output_dir)) {
    write_resolved_config(resolved, provenance, output_dir, run_id)
  }

  # 6. Return BOTH a flat cfg (matches existing code expectations) and
  #    the nested resolved tree + provenance (for the dump / metadata table).
  flat <- .flatten_to_legacy_cfg(resolved)
  list(cfg = flat, resolved = resolved, provenance = provenance, run_id = run_id)
}

# ============================================================
# Write resolved config + provenance to output_dir
# ============================================================
write_resolved_config <- function(resolved, provenance, output_dir, run_id) {
  dir.create(output_dir, showWarnings = FALSE, recursive = TRUE)
  payload <- resolved
  payload[["_provenance"]] <- provenance
  payload[["_run_id"]]     <- run_id
  out_path <- file.path(output_dir, paste0("resolved_config_", run_id, ".yaml"))
  yaml::write_yaml(payload, out_path)
  message("Resolved config written to: ", out_path)
  invisible(out_path)
}
