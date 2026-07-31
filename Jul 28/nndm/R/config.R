# Settings for the NDMM cohort build. Values come from config.csv; the
# environment wins over it. build_nndm.R checks them against CONTRACT before
# anything runs. The cohort prefix is not here - the caller passes it.

cfg_defaults <- list(
  dsn = Sys.getenv("DATABRICKS_DSN", unset = "RWDE"),
  pwd = Sys.getenv("DATABRICKS_PWD", unset = ""),

  catalog    = Sys.getenv("DATABRICKS_CATALOG", unset = "hive_metastore"),
  cdm_schema = Sys.getenv("OPTUM_CDM_SCHEMA", unset = "clnprw_optum"),
  # pin_output_schema() sets this before the build reads it. Blank here so a
  # build that skipped that step stops instead of writing somewhere shared.
  work_schema   = "",
  object_prefix = Sys.getenv("OBJECT_PREFIX", unset = ""),

  tbl_medical     = "medical",
  tbl_med_proc    = "med_procedure",
  tbl_med_diag    = "med_diagnosis",
  tbl_rx          = "rx",
  tbl_confinement = Sys.getenv("TBL_CONFINEMENT", unset = "confinement"),
  # Read by both enrollment-span builds, so it is the first raw table the run
  # touches. Same environment variable nndm_constants.R uses for it.
  tbl_member_enroll = Sys.getenv("TBL_MEMBER_ENROLLMENT", unset = "member_enrollment"),

  # Read by the demographics step: sex and birth year, and date of death.
  tbl_member_elig = Sys.getenv("TBL_MEMBER_ELIG", unset = "member_cont_enrollment"),
  tbl_dod         = Sys.getenv("TBL_DOD", unset = "dod"),

  # Two outpatient MM claims within this many days confirm a diagnosis; this is
  # the age their year is measured against. Both S6.2.1.1.
  outpatient_window = as.integer(Sys.getenv("OUTPATIENT_WINDOW", unset = "90")),
  min_age           = as.integer(Sys.getenv("MIN_AGE", unset = "18")),
  # How belantamab is recognised on cl_mma_codelist.csv; see
  # standalone_constants.R. Pinned because it is exclusion 4.
  belantamab_abbr   = Sys.getenv("NDMM_BELANTAMAB_ABBR", unset = "BEL%"),
  # Agents barred from setting the 1L index beyond belantamab. Empty unless the
  # study team names one; see standalone_constants.R and NDMM_INDEX_AGENTS.
  index_excluded_abbrs = Sys.getenv("NDMM_INDEX_EXCLUDED_ABBRS", unset = ""),
  # The same, by HCPCS or NDC rather than by the code list's own abbreviation.
  index_excluded_codes = Sys.getenv("NDMM_INDEX_EXCLUDED_CODES", unset = ""),
  # Which claims proxy stands for "belantamab in any LOT"; see
  # standalone_constants.R and NDMM_BELANTAMAB_SCOPE_COUNTS.
  belantamab_scope     = Sys.getenv("NDMM_BELANTAMAB_SCOPE", unset = "study_period"),
  # Whether a plasma-cell disorder in remission still excludes as another
  # cancer; see standalone_constants.R and NDMM_MM_ADJACENT_GROUPS.
  mm_adjacent_states = Sys.getenv("NDMM_MM_ADJACENT_STATES", unset = "override"),

  use_quarterly_tables = as.logical(Sys.getenv("USE_QUARTERLY_TABLES", unset = "TRUE")),
  study_end            = Sys.getenv("STUDY_END", unset = "2026-03-31"),

  # The 1L eligible-treatment period opens here (protocol S6.2.1.1).
  lot1_from     = Sys.getenv("LOT1_FROM", unset = "2017-01-01"),
  # 12 months of CE and of baseline before the 1L index date.
  pre_lot1_days = as.integer(Sys.getenv("PRE_LOT1_DAYS", unset = "365")),
  # Days after index a no-gap span must cover. Zero is the index date itself -
  # one day - confirmed by the study team for 1L, overriding the protocol's
  # three months. The 2L/3L cohorts keep three months; see README.
  fu_ce_days    = as.integer(Sys.getenv("FU_CE_DAYS", unset = "0")),
  # Gaps of this many days or fewer still count as continuous enrollment.
  gap_days      = as.integer(Sys.getenv("GAP_DAYS", unset = "30")),
  # The pregnancy exclusion scans [study_start, study_end]. Same environment
  # variable nndm_constants.R reads for NDMM_STUDY_START.
  study_start   = Sys.getenv("STUDY_START", unset = "2016-01-01"),

  codelist_dir = Sys.getenv("CODELIST_DIR", unset = "/mnt/code/codelist"),
  # Per-code answers for the other-cancer criterion, where a tumour-group label
  # cannot give one - see codelists.R and NDMM_MM_ADJACENT_CODES. Blank means
  # the copy that ships with this package; pin_override_csv() fills it in.
  mm_adjacent_csv = Sys.getenv("NDMM_MM_ADJACENT_CSV", unset = ""),
  # Which agents may set the 1L index - see codelists.R and NDMM_INDEX_AGENTS.
  # Blank means the copy that ships with this package; pin_override_csv()
  # fills it in. Empty file means any MM therapy can set the index.
  eligible_1l_csv = Sys.getenv("NDMM_ELIGIBLE_1L_CSV", unset = ""),
  # Which code-list labels are one tumour type, for the two-outpatient-claim
  # rule - see codelists.R and NDMM_OTHER_MALIG_GROUPS. Blank means the copy
  # that ships with this package. Empty file means each label is its own group.
  primary_groups_csv = Sys.getenv("NDMM_PRIMARY_GROUPS_CSV", unset = ""),
  output_dir   = Sys.getenv("OUTPUT_DIR", unset = "/mnt/artifacts/results"),

  max_retries = 4,
  base_sleep  = 5
)

run_id <- Sys.getenv("DOMINO_RUN_ID", unset = format(Sys.time(), "%Y%m%d%H%M%S"))
