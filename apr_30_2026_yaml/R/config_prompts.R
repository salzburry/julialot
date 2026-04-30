# ============================================================
# config_prompts.R — Configuration defaults, env-var loading, prompts
# ============================================================
# Study/methodology parameters live in configs/study.yaml and are loaded
# via R/load_study_config.R::resolve_study_config(). This file owns only
# infrastructure / deployment defaults (DSN, schemas, source tables) and
# the interactive-prompt surface.

# ---- Source the YAML loader (relative to this file's directory) ----
.config_prompts_dir <- tryCatch(dirname(sys.frame(1)$ofile), error = function(e) NULL)
if (is.null(.config_prompts_dir) || !nzchar(.config_prompts_dir)) {
  .config_prompts_dir <- getwd()
}
source(file.path(.config_prompts_dir, "load_study_config.R"))

# ---- Prompting control ----
# Static mode: non-interactive Rscript uses env-var/config defaults (no prompts)
# Interactive mode: prompts by default
# Override: set PROMPT_USER=TRUE to force prompts, or FALSE to suppress them
should_prompt <- function() {
  env_val <- Sys.getenv("PROMPT_USER", unset = "")
  if (nzchar(env_val)) return(isTRUE(as.logical(env_val)))
  interactive()
}

# ---- Validation helpers ----
validate_outpatient_window <- function(x, default = 90L) {
  x <- suppressWarnings(as.integer(x))
  if (is.na(x) || !(x %in% c(30L, 60L, 90L))) return(default)
  x
}

# ============================================================
# CONFIGURATION DEFAULTS
# ============================================================
# Infrastructure / deployment-only fields. Study, IE, LOT and codelist
# values come from configs/study.yaml and are merged in by build_cfg_defaults().
.cfg_infrastructure <- list(
  # ---- Databricks / ODBC ----
  dsn         = Sys.getenv("DATABRICKS_DSN", unset = "RWDE"),
  pwd         = Sys.getenv("DATABRICKS_PWD", unset = ""),
  catalog     = Sys.getenv("DATABRICKS_CATALOG", unset = "hive_metastore"),
  max_retries = as.integer(Sys.getenv("MAX_RETRIES", unset = "3")),
  base_sleep  = as.numeric(Sys.getenv("BASE_SLEEP_SECS", unset = "5")),

  # ---- Schemas (Optum CDM / Domino pattern) ----
  cdm_schema  = Sys.getenv("OPTUM_CDM_SCHEMA", unset = "clnprw_optum"),
  ref_schema  = Sys.getenv("PROJECT_REF_SCHEMA",
                           unset = Sys.getenv("DOMINO_USER_NAME", unset = "gsk_mm_lot_ref")),
  work_schema = Sys.getenv("PROJECT_WORK_SCHEMA",
                           unset = Sys.getenv("DOMINO_USER_NAME", unset = "gsk_mm_lot_work")),

  # ---- Source tables (Optum CDM v9.0) ----
  tbl_member_elig       = "member_cont_enrollment",
  tbl_member_enrollment = "member_enrollment",
  tbl_medical           = "medical",
  tbl_med_diag          = "med_diagnosis",
  tbl_med_proc          = "med_procedure",
  tbl_rx                = "rx",
  tbl_dod               = "dod",
  tbl_confinement       = "confinement",
  use_quarterly_tables  = as.logical(Sys.getenv("USE_QUARTERLY_TABLES", unset = "TRUE")),

  # ---- Code-list table names (used only when CSVs are NOT used) ----
  cl_mm_dx           = "cl_mm_dx",
  cl_mm_therapy      = "cl_mm_therapy",
  cl_preg            = "cl_pregnancy",
  cl_clintrial       = "cl_clintrial",
  cl_other_malig     = "cl_other_malignancies",
  cl_mma_codelist    = "cl_mma_codelist",
  cl_mma_rollup      = "cl_mma_rollup",
  cl_sct_codelist    = "cl_sct_codelist",
  cl_permissible_subs = "cl_permissible_subs",

  use_csv_codelists = as.logical(Sys.getenv("USE_CSV_CODELISTS", unset = "TRUE")),

  # ---- Diagnosis window thresholds (fixed per protocol) ----
  dx_window_30 = 30,
  dx_window_60 = 60,
  dx_window_90 = 90,

  # ---- Output ----
  final_table_name = Sys.getenv("FINAL_TABLE_NAME", unset = "ELIG_COH_FINAL"),

  # ---- Performance ----
  persist_to_schema       = as.logical(Sys.getenv("PERSIST_TO_SCHEMA", unset = "TRUE")),
  personal_schema         = Sys.getenv("DOMINO_USER_NAME",
                                       unset = Sys.getenv("DOMINO_STARTING_USERNAME", unset = "")),
  materialize_checkpoints = TRUE
)

# Build the full cfg_defaults by merging infrastructure with the YAML-resolved
# study/IE/LOT/codelist values. Returns list(cfg_defaults, resolution) where
# resolution is the structure from resolve_study_config() so callers can write
# the resolved-config dump later.
build_cfg_defaults <- function(yaml_path = "configs/study.yaml",
                               run_id    = format(Sys.time(), "%Y%m%d%H%M%S"),
                               output_dir = NULL,
                               require_yaml = TRUE,
                               validate_codelist_files = TRUE) {
  res <- resolve_study_config(
    yaml_path  = yaml_path,
    run_id     = run_id,
    output_dir = output_dir,
    require_yaml = require_yaml,
    validate_codelist_files = validate_codelist_files
  )
  # Map flat YAML values onto the legacy cfg key names already used by the codebase.
  yaml_cfg <- res$cfg
  legacy <- list(
    study_start   = yaml_cfg$start,
    study_end     = yaml_cfg$end,
    id_start      = yaml_cfg$id_start,
    id_end        = yaml_cfg$id_end,
    baseline_days = as.integer(yaml_cfg$baseline_days),
    gap_days      = as.integer(yaml_cfg$gap_days),

    outpatient_window = as.integer(yaml_cfg$outpatient_window),
    min_age           = as.integer(yaml_cfg$min_age),
    apply_age_incl          = as.logical(yaml_cfg$apply_age_incl),
    apply_ce_b_incl         = as.logical(yaml_cfg$apply_ce_b_incl),
    apply_ce_f_incl         = as.logical(yaml_cfg$apply_ce_f_incl),
    apply_no_bl_agents_incl = as.logical(yaml_cfg$apply_no_bl_agents_incl),
    apply_fu_agents_incl    = as.logical(yaml_cfg$apply_fu_agents_incl),
    apply_pregnancy_excl    = as.logical(yaml_cfg$apply_pregnancy_excl),
    apply_clintrial_excl    = as.logical(yaml_cfg$apply_clintrial_excl),
    apply_other_malig_excl  = as.logical(yaml_cfg$apply_other_malig_excl),
    apply_baseline_mm_excl  = as.logical(yaml_cfg$apply_baseline_mm_excl),

    censor_at_disenrollment = as.logical(yaml_cfg$censor_at_disenrollment),

    codelist_dir     = yaml_cfg$codelist_dir,
    codelist_csv_map = yaml_cfg$codelist_csv_map
  )
  cfg <- utils::modifyList(.cfg_infrastructure, legacy, keep.null = FALSE)
  list(cfg_defaults = cfg, resolution = res)
}

# Backwards-compatible exposed name. Built lazily (env-var-only) so existing
# scripts that source this file but don't call build_cfg_defaults() still
# parse — but they'll be missing study/IE values and prompts will break.
# Server entry points (main.R) MUST call build_cfg_defaults() and pass its
# cfg_defaults explicitly.
cfg_defaults <- .cfg_infrastructure

CHECKPOINT_STEPS <- c("mm_dx_events_all", "mm_qualifying", "ELIG_COH_ALLFLAGS")
run_id <- Sys.getenv("DOMINO_RUN_ID", unset = format(Sys.time(), "%Y%m%d%H%M%S"))

# ============================================================
# INTERACTIVE PROMPTS
# ============================================================

# Prompt for study parameters (dates, schemas, windows)
# Reads initial values from base_cfg (the defaults template)
prompt_user_options <- function(base_cfg = cfg_defaults) {
  user_cfg <- list(
    cdm_schema  = base_cfg$cdm_schema,
    ref_schema  = base_cfg$ref_schema,
    work_schema = base_cfg$work_schema,
    study_start = base_cfg$study_start,
    study_end   = base_cfg$study_end,
    id_start    = base_cfg$id_start,
    id_end      = base_cfg$id_end,
    baseline_days = base_cfg$baseline_days,
    gap_days      = base_cfg$gap_days,
    use_quarterly_tables = base_cfg$use_quarterly_tables
  )

  # Resolve schemas from environment
  user_cfg$cdm_schema  <- Sys.getenv("OPTUM_CDM_SCHEMA",    unset = user_cfg$cdm_schema)
  user_cfg$ref_schema  <- Sys.getenv("PROJECT_REF_SCHEMA",  unset = user_cfg$ref_schema)
  user_cfg$work_schema <- Sys.getenv("PROJECT_WORK_SCHEMA", unset = user_cfg$work_schema)

  cat("\n")
  cat("============================================================\n")
  cat("  MM LOT ATTRITION COHORT PIPELINE\n")
  cat("============================================================\n")
  cat("\nDefault Configuration:\n")
  cat("  CDM Schema:       ", user_cfg$cdm_schema, "\n")
  cat("  Reference Schema: ", user_cfg$ref_schema, "\n")
  cat("  Work Schema:      ", user_cfg$work_schema, "\n")
  cat("  Study Period:     ", user_cfg$study_start, " to ", user_cfg$study_end, "\n")
  cat("  ID Period:        ", user_cfg$id_start, " to ", user_cfg$id_end, "\n")
  cat("  Baseline Days:    ", user_cfg$baseline_days, "\n")
  cat("  Gap Days:         ", user_cfg$gap_days, "\n")
  cat("\n")

  if (should_prompt()) {
    cat("Run with default options? [Y/n]: ")
    response <- readline()
    if (tolower(trimws(response)) %in% c("n", "no")) {
      cat("\nCustomize options (press Enter to keep default):\n")

      cat("  Study Start Date [", user_cfg$study_start, "]: ", sep = "")
      val <- readline(); if (nzchar(trimws(val))) user_cfg$study_start <- trimws(val)

      cat("  Study End Date [", user_cfg$study_end, "]: ", sep = "")
      val <- readline(); if (nzchar(trimws(val))) user_cfg$study_end <- trimws(val)

      cat("  ID Start Date [", user_cfg$id_start, "]: ", sep = "")
      val <- readline(); if (nzchar(trimws(val))) user_cfg$id_start <- trimws(val)

      cat("  ID End Date [", user_cfg$id_end, "]: ", sep = "")
      val <- readline(); if (nzchar(trimws(val))) user_cfg$id_end <- trimws(val)

      cat("  Baseline Days [", user_cfg$baseline_days, "]: ", sep = "")
      val <- readline(); if (nzchar(trimws(val))) user_cfg$baseline_days <- as.integer(trimws(val))

      cat("  Gap Days [", user_cfg$gap_days, "]: ", sep = "")
      val <- readline(); if (nzchar(trimws(val))) user_cfg$gap_days <- as.integer(trimws(val))
    }
  }

  cat("\nUsing configuration:\n")
  cat("  CDM Schema:       ", user_cfg$cdm_schema, "\n")
  cat("  Reference Schema: ", user_cfg$ref_schema, "\n")
  cat("  Work Schema:      ", user_cfg$work_schema, "\n")
  cat("  Study Period:     ", user_cfg$study_start, " to ", user_cfg$study_end, "\n")
  cat("  ID Period:        ", user_cfg$id_start, " to ", user_cfg$id_end, "\n")
  cat("  Quarterly Tables: ", if (isTRUE(user_cfg$use_quarterly_tables)) "YES" else "NO", "\n")
  cat("============================================================\n\n")

  user_cfg
}

# Prompt for IE criteria selection
# Returns a list of criteria flags to apply
prompt_ie_criteria <- function(base_cfg = cfg_defaults) {
  # Seed interactive defaults from base_cfg so env-var overrides are
  # honoured consistently in both interactive and batch paths.
  criteria <- list(
    apply_age = base_cfg$apply_age_incl, min_age = base_cfg$min_age,
    apply_ce_baseline = base_cfg$apply_ce_b_incl,
    apply_ce_followup = base_cfg$apply_ce_f_incl,
    apply_no_baseline_therapy = base_cfg$apply_no_bl_agents_incl,
    apply_followup_therapy = base_cfg$apply_fu_agents_incl,
    outpatient_window = base_cfg$outpatient_window,
    apply_pregnancy_excl = base_cfg$apply_pregnancy_excl,
    apply_clintrial_excl = base_cfg$apply_clintrial_excl,
    apply_other_malig_excl = base_cfg$apply_other_malig_excl,
    apply_baseline_mm_excl = base_cfg$apply_baseline_mm_excl
  )

  if (!should_prompt()) {
    cat("Non-interactive mode: using IE criteria from environment variables / config\n")
    return(criteria)
  }

  # ---- Prompt helpers ----
  ask_yn <- function(prompt, default) {
    cat(prompt, " [", if (default) "Y" else "N", "]: ", sep = "")
    r <- tolower(trimws(readline()))
    if (r == "") return(default)
    r %in% c("y", "yes", "1", "true")
  }
  ask_num <- function(prompt, default) {
    cat(prompt, " [", default, "]: ", sep = "")
    r <- trimws(readline())
    if (r == "") return(default)
    as.integer(r)
  }
  ask_choice <- function(prompt, choices, default) {
    cat(prompt, " [", default, "]: ", sep = "")
    r <- trimws(readline())
    if (r == "") return(default)
    val <- as.integer(r)
    if (val %in% choices) val else { cat("  Invalid, using default: ", default, "\n"); default }
  }

  cat("\n")
  cat("============================================================\n")
  cat("  INCLUSION / EXCLUSION CRITERIA SELECTION\n")
  cat("============================================================\n")
  cat("\nFor each criterion, enter Y/N or a new value. Press Enter to keep default.\n\n")

  cat("--- INCLUSION CRITERIA ---\n\n")
  criteria$apply_age <- ask_yn("Apply Age >= 18 criterion?", criteria$apply_age)
  if (criteria$apply_age) criteria$min_age <- ask_num("  Minimum age", criteria$min_age)

  cat("\nOutpatient MM Diagnosis Confirmation Window:\n")
  cat("  Requires 2 outpatient claims within X days for non-inpatient patients\n")
  cat("  Options: 30, 60, or 90 days\n")
  criteria$outpatient_window <- ask_choice("Select window (30/60/90)", c(30, 60, 90), criteria$outpatient_window)

  cat("\n")
  criteria$apply_ce_baseline         <- ask_yn("Apply 6-month baseline enrollment (CE_b=1)?", criteria$apply_ce_baseline)
  criteria$apply_ce_followup         <- ask_yn("Apply 1+ day follow-up enrollment (CE_f=1)?", criteria$apply_ce_followup)
  criteria$apply_no_baseline_therapy <- ask_yn("Apply no MM therapy in baseline (MM_bl_agents=0)?", criteria$apply_no_baseline_therapy)
  criteria$apply_followup_therapy    <- ask_yn("Apply MM therapy in follow-up required (MM_FU_agents=1)?", criteria$apply_followup_therapy)

  cat("\n--- EXCLUSION CRITERIA ---\n\n")
  criteria$apply_pregnancy_excl   <- ask_yn("Exclude patients with pregnancy claims?", criteria$apply_pregnancy_excl)
  criteria$apply_clintrial_excl   <- ask_yn("Exclude patients in clinical trials?", criteria$apply_clintrial_excl)
  criteria$apply_other_malig_excl <- ask_yn("Exclude patients with other malignancies?", criteria$apply_other_malig_excl)
  criteria$apply_baseline_mm_excl <- ask_yn("Exclude patients with MM dx (203.0x/C90.0x) in baseline?", criteria$apply_baseline_mm_excl)

  # ---- Summary ----
  cat("\n")
  cat("============================================================\n")
  cat("  CRITERIA SUMMARY\n")
  cat("============================================================\n")
  cat("\nINCLUSION CRITERIA:\n")
  cat("  [", if(criteria$apply_age) "X" else " ", "] Age >= ", criteria$min_age, "\n", sep = "")
  cat("  [", if(criteria$apply_ce_baseline) "X" else " ", "] 6-month baseline enrollment (CE_b=1)\n", sep = "")
  cat("  [", if(criteria$apply_ce_followup) "X" else " ", "] 1+ day follow-up enrollment (CE_f=1)\n", sep = "")
  cat("  [", if(criteria$apply_no_baseline_therapy) "X" else " ", "] No MM therapy in baseline\n", sep = "")
  cat("  [", if(criteria$apply_followup_therapy) "X" else " ", "] MM therapy in follow-up required\n", sep = "")
  cat("  [X] Outpatient confirmation window: ", criteria$outpatient_window, " days\n", sep = "")

  cat("\nEXCLUSION CRITERIA:\n")
  cat("  [", if(criteria$apply_pregnancy_excl) "X" else " ", "] Pregnancy\n", sep = "")
  cat("  [", if(criteria$apply_clintrial_excl) "X" else " ", "] Clinical trial participation\n", sep = "")
  cat("  [", if(criteria$apply_other_malig_excl) "X" else " ", "] Other malignancies\n", sep = "")
  cat("  [", if(criteria$apply_baseline_mm_excl) "X" else " ", "] Baseline MM evidence (Step 7)\n", sep = "")

  cat("\n============================================================\n")
  cat("Proceed with these criteria? [Y/n]: ")
  response <- tolower(trimws(readline()))
  if (response %in% c("n", "no")) {
    cat("\nRestarting criteria selection...\n")
    return(prompt_ie_criteria(base_cfg))
  }

  cat("\nCriteria confirmed. Proceeding with pipeline...\n\n")
  criteria
}

# ---- Apply user selections to cfg ----
# Merges base defaults with user/IE overrides and returns a new list.
# No global mutation — the caller holds the finalized cfg as a local.
finalize_cfg <- function(base_cfg, user_cfg, ie_criteria) {
  out <- base_cfg
  out$cdm_schema  <- Sys.getenv("OPTUM_CDM_SCHEMA",    unset = user_cfg$cdm_schema)
  out$ref_schema  <- Sys.getenv("PROJECT_REF_SCHEMA",  unset = user_cfg$ref_schema)
  out$work_schema <- Sys.getenv("PROJECT_WORK_SCHEMA", unset = user_cfg$work_schema)
  out$study_start <- user_cfg$study_start
  out$study_end   <- user_cfg$study_end
  out$id_start    <- user_cfg$id_start
  out$id_end      <- user_cfg$id_end
  out$baseline_days <- user_cfg$baseline_days
  out$gap_days      <- user_cfg$gap_days

  out$outpatient_window      <- validate_outpatient_window(ie_criteria$outpatient_window)
  out$apply_age_incl         <- ie_criteria$apply_age
  out$min_age                <- ie_criteria$min_age
  out$apply_ce_b_incl        <- ie_criteria$apply_ce_baseline
  out$apply_ce_f_incl        <- ie_criteria$apply_ce_followup
  out$apply_no_bl_agents_incl <- ie_criteria$apply_no_baseline_therapy
  out$apply_fu_agents_incl   <- ie_criteria$apply_followup_therapy
  out$apply_pregnancy_excl   <- ie_criteria$apply_pregnancy_excl
  out$apply_clintrial_excl   <- ie_criteria$apply_clintrial_excl
  out$apply_other_malig_excl <- ie_criteria$apply_other_malig_excl
  out$apply_baseline_mm_excl <- ie_criteria$apply_baseline_mm_excl
  out
}
