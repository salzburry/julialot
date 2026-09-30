# Settings for the LOT build. Values come from config.csv; the environment
# wins over it. build_lot.R checks them against CONTRACT before anything runs.
# The cohort table and prefix are not here - the caller passes those.

cfg_defaults <- list(
  # ---- Connection ----
  dsn = Sys.getenv("DATABRICKS_DSN", unset = "RWDE"),
  pwd = Sys.getenv("DATABRICKS_PWD", unset = ""),

  # ---- Catalog and schemas ----
  catalog    = Sys.getenv("DATABRICKS_CATALOG", unset = "hive_metastore"),
  # The MDV schema. Called cdm_schema so R/mdv_source.R reads one name in both
  # packages, and so LOT_RUN_METADATA.CDM_SCHEMA still says where the data was.
  cdm_schema = Sys.getenv("MDV_SCHEMA", unset = "clnprw_mdv_all_use"),
  # pin_output_schema() sets this from the environment before the build reads
  # it. Blank here so a build that skipped that step stops instead of writing
  # somewhere shared.
  work_schema = "",

  # ---- Which cohort this run is for ----
  # The cohort table is named by the cohort build, so it is read as-is.
  # object_prefix goes on LOT's own outputs, so two cohorts do not overwrite
  # each other in one schema.
  input_cohort_table = Sys.getenv("INPUT_COHORT_TABLE", unset = ""),
  object_prefix      = Sys.getenv("OBJECT_PREFIX", unset = ""),

  # ---- MDV source ----
  # The tables and columns are in R/mdv_source.R, shared with the cohort build.
  use_quarterly_tables = as.logical(Sys.getenv("USE_QUARTERLY_TABLES", unset = "TRUE")),
  # Blank - unset, or set empty - is the default, like every setting; the
  # vintage is never derived from STUDY_END (mdv_vintage()).
  mdv_vintage          = local({ v <- trimws(Sys.getenv("MDV_VINTAGE", unset = ""))
                                 if (nzchar(v)) v else "2026q2" }),
  # The study window this run covers. build_lot() takes it as an argument, so
  # these are what a run uses when none is passed.
  #
  # They do not filter acts: every scan is bounded by the cohort's own
  # INDEX_DATE and OBS_END_DT. What they say is which data this build may see;
  # check_cohort_window() stops a cohort built to a wider window. On MDV the
  # tables' vintage is MDV_VINTAGE, not STUDY_END's quarter.
  study_start          = Sys.getenv("STUDY_START", unset = "2018-01-01"),
  study_end            = Sys.getenv("STUDY_END", unset = "2026-03-31"),

  # ---- LOT parameters ----
  # Two 90-day settings, two different rules. map_discon_gap_days is per drug:
  # a gap this long between one drug episode and the next makes the later one a
  # restart. lot_discon_confirm_days is per line: a raw run-out becomes the
  # line's discontinuation only after this much observation past it, or a
  # LOT-start trigger. See the header of steps/10_lot2_5_base.R.
  induction_window_days       = as.integer(Sys.getenv("INDUCTION_WINDOW_DAYS", unset = "60")),
  lot_n_induction_window_days = as.integer(Sys.getenv("INDUCTION_WINDOW_DAYS_LOT_N", unset = "30")),
  map_discon_gap_days         = as.integer(Sys.getenv("MAP_DISCON_GAP_DAYS", unset = "90")),
  lot_discon_confirm_days     = as.integer(Sys.getenv("LOT_DISCON_CONFIRM_DAYS", unset = "90")),
  # An injected MM drug (CL_ROUTE=INJ) covers this many days from each
  # administration - the Optum build's medical-claim supply, and on MDV the
  # assumption every line boundary follows from, because a DPC administration
  # record says when, not for how long.
  medical_day_supply          = as.integer(Sys.getenv("MEDICAL_DAY_SUPPLY", unset = "28")),
  # An oral one (CL_ROUTE=ORAL) covers its act's days supplied where the
  # delivery carries them (MDV_COL_ACT_DAYS); where it does not, this many for
  # an outpatient prescription, the Optum build's imputation for a missing
  # supply, and one day for an inpatient administration.
  oral_days_default           = as.integer(Sys.getenv("ORAL_DAYS_DEFAULT", unset = "28")),

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
  # On MDV, TRUE (the contract): OBS_END_DT = ENDDATE_CE, the patient's last
  # record at the hospital, capped at death and the study end. MDV has no
  # enrollment, and a patient who stops attending looks like one who stopped
  # treatment, so without the cap every loss to follow-up would read as a
  # discontinuation. FALSE observes everyone to the study end, the Optum
  # primary; it needs LOT_CONTRACT_OVERRIDE here.
  censor_at_disenrollment = as.logical(Sys.getenv("CENSOR_AT_DISENROLLMENT", unset = "TRUE")),

  # ---- The melphalan line-advancing rule (R/melp_rule.R) ----
  # 'simplified' is the contract build, and config.csv carries it. The only
  # other value is 'off', a different algorithm, so it is pinned in CONTRACT and
  # needs LOT_CONTRACT_OVERRIDE.
  #
  # The default here stays blank so a run that loses config.csv fails the
  # contract check rather than defaulting to the study's rule. Blank cannot be
  # asked for from the environment - load_inputs.R fills an empty variable from
  # config.csv - so 'off' is the word that survives, and melp_rule_on() maps it
  # to no rule.
  apply_melp_rule    = Sys.getenv("APPLY_MELP_RULE",    unset = ""),
  # Pinned TRUE in CONTRACT - LOT_RULES.md 4.8. FALSE builds without it and
  # needs LOT_CONTRACT_OVERRIDE. The default stays FALSE so a run that loses
  # config.csv fails the contract check rather than defaulting to the rule.
  apply_map_foldin   = as.logical(Sys.getenv("APPLY_MAP_FOLDIN", unset = "FALSE")),
  # The returning-drug release, LOT_RULES.md 4.3. TRUE, the value pinned in
  # CONTRACT, means a drug of the line's own regimen coming back after a gap
  # does not open the next line: nothing new was given, so the line's run-out
  # chains over the gap. FALSE is the engine's older rule, where the gap
  # released the drug to open a line like any other agent. Default FALSE so a
  # run that loses config.csv fails the contract check.
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
  melp_simple_course_days = as.integer(Sys.getenv("MELP_SIMPLE_COURSE_DAYS",
                                                  unset = "28")),

  # ---- Code lists ----
  codelist_dir = Sys.getenv("CODELIST_DIR", unset = "/mnt/code/codelist_mdv"),

  persist_to_schema = as.logical(Sys.getenv("PERSIST_TO_SCHEMA", unset = "TRUE")),
  output_dir        = Sys.getenv("OUTPUT_DIR", unset = "/mnt/artifacts/results"),

  # ---- Retry ----
  max_retries = 4,
  base_sleep  = 5
)

run_id <- Sys.getenv("DOMINO_RUN_ID", unset = format(Sys.time(), "%Y%m%d%H%M%S"))
