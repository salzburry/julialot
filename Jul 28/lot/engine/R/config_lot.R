# Settings for the LOT build. Values come from config.csv; the environment
# wins over it. build_lot.R checks them against CONTRACT before anything runs.
# The cohort table and prefix are not here - the caller passes those.

cfg_defaults <- list(
  # ---- Connection ----
  dsn = Sys.getenv("DATABRICKS_DSN", unset = "RWDE"),
  pwd = Sys.getenv("DATABRICKS_PWD", unset = ""),

  # ---- Catalog and schemas ----
  catalog    = Sys.getenv("DATABRICKS_CATALOG", unset = "hive_metastore"),
  cdm_schema = Sys.getenv("OPTUM_CDM_SCHEMA", unset = "clnprw_optum"),
  # pin_output_schema() sets this from the environment before the build reads
  # it. Blank here so a build that skipped that step stops instead of writing
  # somewhere shared.
  work_schema = "",

  # ---- Which cohort this run is for ----
  # The cohort table is named by the cohort build, so it is read as-is.
  # object_prefix goes on LOT's own outputs, which is what keeps two cohorts
  # from overwriting each other in one schema.
  input_cohort_table = Sys.getenv("INPUT_COHORT_TABLE", unset = ""),
  object_prefix      = Sys.getenv("OBJECT_PREFIX", unset = ""),

  # ---- CDM source tables ----
  tbl_medical  = "medical",
  tbl_med_proc = "med_procedure",
  tbl_med_diag = "med_diagnosis",
  tbl_rx       = "rx",

  use_quarterly_tables = as.logical(Sys.getenv("USE_QUARTERLY_TABLES", unset = "TRUE")),
  # The study window this run covers. build_lot() takes it as an argument, so
  # these are what a run uses when none is passed.
  #
  # They do not filter claims. Every claim scan is bounded by the cohort's own
  # INDEX_DATE and OBS_END_DT. What these dates say is which data this build may
  # see, and study_end also picks the quarterly CDM tables. A cohort built to a
  # wider window than these would have its follow-up quietly cut at the vintage.
  # check_cohort_window() stops the run instead.
  #
  # These are the study period of the cohort this build usually runs for.
  # Another cohort passes its own window and nothing here changes.
  study_start          = Sys.getenv("STUDY_START", unset = "2016-01-01"),
  study_end            = Sys.getenv("STUDY_END", unset = "2026-03-31"),

  # ---- LOT parameters ----
  # Two 90-day settings, two different rules. map_discon_gap_days is PER DRUG:
  # a gap this long between one drug episode and the next makes the later one
  # a restart. lot_discon_confirm_days is PER LINE: a raw run-out becomes the
  # line's discontinuation only after this much observation past it, or a
  # LOT-start trigger. Same number, not the same rule - see the header of
  # steps/10_lot2_5_base.R.
  induction_window_days       = as.integer(Sys.getenv("INDUCTION_WINDOW_DAYS", unset = "60")),
  lot_n_induction_window_days = as.integer(Sys.getenv("INDUCTION_WINDOW_DAYS_LOT_N", unset = "30")),
  map_discon_gap_days         = as.integer(Sys.getenv("MAP_DISCON_GAP_DAYS", unset = "90")),
  lot_discon_confirm_days     = as.integer(Sys.getenv("LOT_DISCON_CONFIRM_DAYS", unset = "90")),
  medical_day_supply          = as.integer(Sys.getenv("MEDICAL_DAY_SUPPLY", unset = "28")),

  # ---- SCT parameters ----
  sct_auto_window_days = as.integer(Sys.getenv("SCT_AUTO_WINDOW_DAYS", unset = "13")),
  sct_auto_gap_days    = as.integer(Sys.getenv("SCT_AUTO_GAP_DAYS", unset = "60")),
  sct_tandem_days      = as.integer(Sys.getenv("SCT_TANDEM_DAYS", unset = "180")),

  # New agents within this window of a CAR-T are consolidation, not a med add.
  cart_consolidation_days = as.integer(Sys.getenv("CART_CONSOLIDATION_DAYS", unset = "45")),

  # ---- LOT2 and later ----
  # single_day: an ALLO line spans only the transplant date.
  allo_lot_span = Sys.getenv("ALLO_LOT_SPAN", unset = "single_day"),
  max_lot       = as.integer(Sys.getenv("MAX_LOT", unset = "5")),
  # How belantamab is spelled in MED_ABBR, for the line criterion in
  # line_criteria.R. Same abbreviation the cohort build uses on
  # cl_mma_codelist.csv.
  belantamab_med_abbr = toupper(trimws(Sys.getenv("BELANTAMAB_MED_ABBR", unset = "BELA"))),

  # What the cohort build calls its run-status table, before the prefix. Empty
  # means try the names the cohort builds in this folder use. The check refuses
  # a cohort whose own build did not finish. It also refuses the run outright if
  # this names a table that cannot be read.
  cohort_status_table = trimws(Sys.getenv("COHORT_STATUS_TABLE", unset = "")),
  # Stop the build when a face-validity check falls outside its band. Off by
  # default: those bands are plausibility judgements, and an unusual cohort can
  # fail one legitimately. The values are recorded either way.
  face_validity_fatal = as.logical(Sys.getenv("FACE_VALIDITY_FATAL", unset = "FALSE")),
  # The cohort build's prefix, for that table. Defaults to this run's own -
  # one study, one prefix - so it is only set when the two differ.
  cohort_prefix       = trimws(Sys.getenv("COHORT_PREFIX", unset = "")),

  # ---- Observation end ----
  # FALSE (primary): OBS_END_DT = ENDDATE = min(death, study_end), so a
  # disenrolled patient keeps contributing follow-up.
  # TRUE (sensitivity): disenrollment caps observation too. ENDDATE_CE is kept
  # on lot_patient_input either way, so this flag is the only change needed.
  censor_at_disenrollment = as.logical(Sys.getenv("CENSOR_AT_DISENROLLMENT", unset = "FALSE")),

  # ---- The melphalan line-advancing rule (R/melp_rule.R) ----
  # 'simplified' is the contract build, and config.csv carries it. Any other
  # value - 'off', 'as_asked', 'yield_to_sct' - is a different algorithm, so it
  # is pinned in CONTRACT and needs LOT_CONTRACT_OVERRIDE.
  #
  # The default here stays blank on purpose. config.csv is what supplies the
  # contract mode, so a run that somehow loses it lands on blank, fails the
  # contract check and stops - rather than defaulting to the study's rule and
  # hiding the fact that the settings file never loaded. Note that blank cannot
  # be asked for from the environment: load_inputs.R fills an empty variable
  # from config.csv. 'off' is the word that survives, and melp_rule_mode()
  # maps it to no rule.
  apply_melp_rule    = Sys.getenv("APPLY_MELP_RULE",    unset = ""),
  # Pinned TRUE in CONTRACT since the study adopted the rule - LOT_RULES.md
  # 4.8. FALSE builds without it and needs LOT_CONTRACT_OVERRIDE. The default
  # stays FALSE so a run that somehow loses config.csv fails the contract
  # check and stops, rather than defaulting to the study's rule and hiding
  # that the settings file never loaded.
  apply_map_foldin   = as.logical(Sys.getenv("APPLY_MAP_FOLDIN", unset = "FALSE")),
  # The returning-drug release, LOT_RULES.md 4.3. TRUE - the value pinned in
  # CONTRACT since the study adopted it - means a drug of the line's own
  # regimen coming back after a gap does NOT open the next line: nothing new
  # was given, so it is returning to the line it left, and that line's run-out
  # chains over the gap. FALSE is the engine's older rule, where the gap
  # released the drug to open a line like any other agent. Default FALSE so a
  # run that somehow loses config.csv fails the contract check and stops.
  apply_own_return_fold =
    as.logical(Sys.getenv("APPLY_OWN_RETURN_FOLD", unset = "FALSE")),
  # Pinned TRUE in CONTRACT. Turning it off is a different algorithm and needs
  # LOT_CONTRACT_OVERRIDE, the same as any other contract setting.
  apply_cart_induction_rule =
    as.logical(Sys.getenv("APPLY_CART_INDUCTION_RULE", unset = "TRUE")),
  # Pinned TRUE in CONTRACT for the same reason. This is the value
  # criterion_enabled() applies, so the criterion and the recorded contract
  # cannot disagree about whether the exclusion ran.
  apply_no_belantamab =
    as.logical(Sys.getenv("APPLY_NO_BELANTAMAB", unset = "TRUE")),
  melp_med_abbr      = Sys.getenv("MELP_MED_ABBR",      unset = "MELP"),
  melp_exposure_days = as.integer(Sys.getenv("MELP_EXPOSURE_DAYS", unset = "30")),
  melp_restart_days  = as.integer(Sys.getenv("MELP_RESTART_DAYS",  unset = "60")),
  melp_advance_days  = as.integer(Sys.getenv("MELP_ADVANCE_DAYS",  unset = "180")),
  melp_sct_days      = as.integer(Sys.getenv("MELP_SCT_DAYS",      unset = "14")),
  melp_simple_course_days = as.integer(Sys.getenv("MELP_SIMPLE_COURSE_DAYS",
                                                  unset = "28")),

  # ---- Code lists ----
  codelist_dir = Sys.getenv("CODELIST_DIR", unset = "/mnt/code/codelist"),

  persist_to_schema = as.logical(Sys.getenv("PERSIST_TO_SCHEMA", unset = "TRUE")),
  output_dir        = Sys.getenv("OUTPUT_DIR", unset = "/mnt/artifacts/results"),

  # ---- Retry ----
  max_retries = 4,
  base_sleep  = 5
)

run_id <- Sys.getenv("DOMINO_RUN_ID", unset = format(Sys.time(), "%Y%m%d%H%M%S"))
