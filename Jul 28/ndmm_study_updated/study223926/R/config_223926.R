# Settings for study 223926, and the contract that pins the protocol's own
# numbers.
#
# Three layers, in this order of authority:
#
#   1. the environment          - a shell export or a Domino-injected value
#   2. config.csv               - the defaults, filled only where 1 is unset
#   3. cfg_defaults() below     - the fallback, if a row is missing from the CSV
#
# Layer 3 exists so a truncated config.csv cannot silently change a definition:
# every setting has a value here even when the file has none.
#
# CONTRACT is the subset the protocol states outright. Changing one of those is
# a different study, so it needs SETTINGS_OVERRIDE=TRUE and lands in
# CONTRACT_DEVIATIONS on the run's own status row. Everything outside CONTRACT
# is a reading the protocol leaves open - each one is an entry in
# ../OPEN_QUESTIONS.md, and every run records which reading it used.

.env_chr <- function(name, default) {
  v <- trimws(Sys.getenv(name, unset = ""))
  if (nzchar(v)) v else default
}
.env_int <- function(name, default) {
  v <- .env_chr(name, as.character(default))
  n <- suppressWarnings(as.integer(v))
  if (is.na(n))
    stop("SETTING ERROR: ", name, " = '", v, "' is not a whole number.",
         call. = FALSE)
  n
}
.env_lgl <- function(name, default) {
  v <- toupper(.env_chr(name, if (isTRUE(default)) "TRUE" else "FALSE"))
  if (!v %in% c("TRUE", "FALSE"))
    stop("SETTING ERROR: ", name, " = '", v, "' is not TRUE or FALSE.",
         call. = FALSE)
  identical(v, "TRUE")
}
# A comma-separated list, trimmed, uppercased where asked, blanks dropped.
.env_list <- function(name, default, upper = FALSE) {
  v <- .env_chr(name, default)
  out <- trimws(strsplit(v, ",", fixed = TRUE)[[1]])
  out <- out[nzchar(out)]
  if (upper) out <- toupper(out)
  out
}
# One of a fixed set. An unrecognised value stops the run rather than falling
# through to a default, because a silent fallback here changes a definition.
.env_enum <- function(name, default, allowed) {
  v <- tolower(.env_chr(name, default))
  if (!v %in% allowed)
    stop("SETTING ERROR: ", name, " = '", v, "'. Allowed: ",
         paste(allowed, collapse = ", "), ".", call. = FALSE)
  v
}
.env_date <- function(name, default) {
  v <- .env_chr(name, default)
  if (!grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", v))
    stop("SETTING ERROR: ", name, " = '", v, "' is not YYYY-MM-DD.",
         call. = FALSE)
  if (is.na(as.Date(v)))
    stop("SETTING ERROR: ", name, " = '", v, "' is not a real date.",
         call. = FALSE)
  v
}

# The protocol's own numbers. Section references are to the Aug 26 2026
# document; screen numbers are the photographs in ../ashley study.pdf.
CONTRACT <- list(
  baseline_days             = 365L,   # s7.1, screen 17
  ce_pre_days               = 365L,   # s7.2.1.1, screen 21
  gap_days                  = 30L,    # s7.2.1.1, screen 21
  lot_post_discon_days      = 30L,    # Figure 1 note 2, screen 19
  acute_washout_days        = 30L,    # s7.3.2, screen 29
  tte_min_potential_fu_days = 90L,    # s7.8.2, screen 48
  suppress_min_n            = 25L,    # s7.2.3, screen 24
  lot1_index_from           = "2019-01-01",  # s7.1, screen 17
  sec2l_index_from          = "2020-01-01",  # s7.4, screen 37
  study_end                 = "2026-03-31"   # s7.1, screen 17
)

cfg_defaults <- function() {
  list(
    # --- connection -------------------------------------------------------
    # sparklyr. On a Databricks cluster the session already exists, so nothing
    # is authenticated here; databricks_connect is for driving one from
    # outside and is the only mode that needs a token.
    spark_method = .env_enum("SPARK_METHOD", "databricks",
                             c("databricks", "databricks_connect", "local")),
    databricks_host       = .env_chr("DATABRICKS_HOST", ""),
    databricks_token      = Sys.getenv("DATABRICKS_TOKEN", unset = ""),
    databricks_cluster_id = .env_chr("SPARK_CLUSTER_ID", ""),
    catalog      = .env_chr("DATABRICKS_CATALOG", "hive_metastore"),
    cdm_schema   = .env_chr("OPTUM_CDM_SCHEMA", "clnprw_optum"),
    work_schema  = .env_chr("WORK_SCHEMA", ""),
    use_quarterly_tables = .env_lgl("USE_QUARTERLY_TABLES", TRUE),
    codelist_dir = .env_chr("CODELIST_DIR", "/mnt/code/codelist"),

    # --- what to read -----------------------------------------------------
    input_cohort_table = .env_chr("INPUT_COHORT_TABLE", ""),
    object_prefix      = .env_chr("OBJECT_PREFIX", ""),
    cohort_prefix      = .env_chr("COHORT_PREFIX", ""),
    lot_prefix         = .env_chr("LOT_PREFIX", ""),

    # --- periods ----------------------------------------------------------
    study_start      = .env_date("STUDY_START", "2018-01-01"),
    study_end        = .env_date("STUDY_END", CONTRACT$study_end),
    lot1_index_from  = .env_date("LOT1_INDEX_FROM", CONTRACT$lot1_index_from),
    sec2l_index_from = .env_date("SEC2L_INDEX_FROM", CONTRACT$sec2l_index_from),

    # --- windows ----------------------------------------------------------
    baseline_days   = .env_int("BASELINE_DAYS", CONTRACT$baseline_days),
    months_as       = .env_enum("MONTHS_AS", "days", c("days", "calendar")),
    baseline_includes_index =
      .env_lgl("BASELINE_INCLUDES_INDEX", FALSE),
    comorbidity_baseline_includes_index =
      .env_lgl("COMORBIDITY_BASELINE_INCLUDES_INDEX", TRUE),
    gap_days        = .env_int("GAP_DAYS", CONTRACT$gap_days),
    ce_pre_days     = .env_int("CE_PRE_DAYS", CONTRACT$ce_pre_days),
    lot_post_discon_days =
      .env_int("LOT_POST_DISCON_DAYS", CONTRACT$lot_post_discon_days),
    acute_washout_days =
      .env_int("ACUTE_WASHOUT_DAYS", CONTRACT$acute_washout_days),
    tte_min_potential_fu_days =
      .env_int("TTE_MIN_POTENTIAL_FU_DAYS", CONTRACT$tte_min_potential_fu_days),

    # --- criteria switches ------------------------------------------------
    mm_dx_outpatient_codes =
      .env_enum("MM_DX_OUTPATIENT_CODES", "listed", c("strict", "listed")),
    mm_dx_outpatient_window_days =
      .env_int("MM_DX_OUTPATIENT_WINDOW_DAYS", 90L),
    fu_evidence_rule = .env_enum("FU_EVIDENCE_RULE", "claim_from_index",
      c("claim_from_index", "claim_after_index", "enrolled_on_index")),
    prior_tx_drop_steroids = .env_lgl("PRIOR_TX_DROP_STEROIDS", TRUE),
    other_cancer_pair_days = .env_int("OTHER_CANCER_PAIR_DAYS", 30L),
    other_cancer_pair_grain =
      .env_enum("OTHER_CANCER_PAIR_GRAIN", "icd3", c("icd3", "tumor_group")),
    other_cancer_both_in_baseline =
      .env_lgl("OTHER_CANCER_BOTH_IN_BASELINE", TRUE),
    pregnancy_window = .env_enum("PREGNANCY_WINDOW", "study_period",
      c("study_period", "patient_period")),
    sec2l_apply_other_cancer = .env_lgl("SEC2L_APPLY_OTHER_CANCER", FALSE),
    index_excluded_abbrs =
      .env_list("INDEX_EXCLUDED_ABBRS", "BELA,PANO,ELOT", upper = TRUE),

    # --- follow-up and censoring -----------------------------------------
    censor_at_disenrollment  = .env_lgl("CENSOR_AT_DISENROLLMENT", TRUE),
    bridged_gap_is_person_time =
      .env_lgl("BRIDGED_GAP_IS_PERSON_TIME", TRUE),

    # --- demographics -----------------------------------------------------
    region_source = .env_enum("REGION_SOURCE", "state_crosswalk",
      c("region_column", "state_crosswalk")),
    enrol_attr_at = .env_enum("ENROL_ATTR_AT", "index_span",
      c("index_span", "latest_span")),
    ed_definition = .env_list("ED_DEFINITION", "revenue,pos"),

    # --- reporting --------------------------------------------------------
    suppress_min_n  = .env_int("SUPPRESS_MIN_N", CONTRACT$suppress_min_n),
    rate_multiplier = .env_int("RATE_MULTIPLIER", 100000L),
    max_lot         = .env_int("MAX_LOT", 4L),

    # --- selection --------------------------------------------------------
    cohorts       = .env_list("COHORTS", "1L,2L,3L", upper = TRUE),
    modules       = .env_list("MODULES", "all"),
    skip_modules  = .env_list("SKIP_MODULES", ""),
    dry_run       = .env_lgl("DRY_RUN", FALSE),

    # --- plumbing ---------------------------------------------------------
    max_retries = .env_int("MAX_RETRIES", 4L),
    base_sleep  = .env_int("BASE_SLEEP", 5L),
    settings_override = .env_lgl("SETTINGS_OVERRIDE", FALSE)
  )
}

# Every setting the contract pins, and the cfg field that carries it. Kept as
# data so check_contract() cannot fall behind CONTRACT.
CONTRACT_FIELDS <- c(
  baseline_days             = "baseline_days",
  ce_pre_days               = "ce_pre_days",
  gap_days                  = "gap_days",
  lot_post_discon_days      = "lot_post_discon_days",
  acute_washout_days        = "acute_washout_days",
  tte_min_potential_fu_days = "tte_min_potential_fu_days",
  suppress_min_n            = "suppress_min_n",
  lot1_index_from           = "lot1_index_from",
  sec2l_index_from          = "sec2l_index_from",
  study_end                 = "study_end"
)

# Returns the deviations rather than printing them, so the caller can both
# refuse the run and write them onto its status row.
contract_deviations <- function(cfg) {
  out <- character(0)
  for (nm in names(CONTRACT_FIELDS)) {
    want <- CONTRACT[[nm]]
    got  <- cfg[[CONTRACT_FIELDS[[nm]]]]
    if (!identical(as.character(want), as.character(got)))
      out <- c(out, sprintf("%s=%s (contract: %s)", nm, got, want))
  }
  out
}

check_contract <- function(cfg) {
  dev <- contract_deviations(cfg)
  if (!length(dev)) return(invisible(character(0)))
  if (!isTRUE(cfg$settings_override))
    stop("CONTRACT ERROR: ", length(dev),
         " setting(s) differ from what the protocol states:\n  ",
         paste(dev, collapse = "\n  "),
         "\nThe protocol states these outright, so a run that changes one is a ",
         "different study. Set SETTINGS_OVERRIDE=TRUE to proceed; the run will ",
         "record every deviation on its status row and no reader in this repo ",
         "will accept it as the study's numbers.", call. = FALSE)
  dev
}

# The settings that are NOT in the contract, with the reading each one took.
# Written to the run's metadata so a number can be traced to the readings that
# produced it. Ordered, so two runs' rows compare line for line.
open_question_readings <- function(cfg) {
  keys <- c("study_start", "mm_dx_outpatient_codes",
            "mm_dx_outpatient_window_days", "fu_evidence_rule",
            "prior_tx_drop_steroids", "other_cancer_pair_days",
            "other_cancer_pair_grain", "other_cancer_both_in_baseline",
            "pregnancy_window", "sec2l_apply_other_cancer",
            "censor_at_disenrollment", "bridged_gap_is_person_time",
            "months_as", "baseline_includes_index",
            "comorbidity_baseline_includes_index", "region_source",
            "enrol_attr_at", "ed_definition", "index_excluded_abbrs")
  vapply(keys, function(k) {
    v <- cfg[[k]]
    sprintf("%s=%s", k, paste(as.character(v), collapse = "|"))
  }, character(1), USE.NAMES = FALSE)
}

check_settings <- function(cfg) {
  if (!nzchar(cfg$input_cohort_table))
    stop("SETTING ERROR: INPUT_COHORT_TABLE is required - it names the cohort ",
         "the LOT run was built over.", call. = FALSE)
  if (!nzchar(cfg$object_prefix))
    stop("SETTING ERROR: OBJECT_PREFIX is required - every table this package ",
         "writes carries it, and two runs without one would overwrite each ",
         "other.", call. = FALSE)
  if (as.Date(cfg$study_start) >= as.Date(cfg$study_end))
    stop("SETTING ERROR: STUDY_START (", cfg$study_start, ") is not before ",
         "STUDY_END (", cfg$study_end, ").", call. = FALSE)
  if (as.Date(cfg$lot1_index_from) < as.Date(cfg$study_start))
    stop("SETTING ERROR: LOT1_INDEX_FROM (", cfg$lot1_index_from, ") is before ",
         "STUDY_START (", cfg$study_start, "), so the 1L index could fall ",
         "outside the study period.", call. = FALSE)
  for (nm in c("baseline_days", "ce_pre_days", "gap_days",
               "lot_post_discon_days", "acute_washout_days",
               "tte_min_potential_fu_days", "suppress_min_n",
               "rate_multiplier", "max_lot"))
    if (cfg[[nm]] < 0L)
      stop("SETTING ERROR: ", nm, " is negative.", call. = FALSE)
  if (cfg$max_lot < 1L || cfg$max_lot > 5L)
    stop("SETTING ERROR: MAX_LOT is ", cfg$max_lot,
         "; the LOT engine builds lines 1 to 5.", call. = FALSE)
  bad_ed <- setdiff(cfg$ed_definition, c("revenue", "pos", "cpt"))
  if (length(bad_ed))
    stop("SETTING ERROR: ED_DEFINITION names ", paste(bad_ed, collapse = ", "),
         ". Allowed: revenue, pos, cpt.", call. = FALSE)
  if (!length(cfg$ed_definition))
    stop("SETTING ERROR: ED_DEFINITION is empty, so no emergency visit could ",
         "ever be found. Name at least one of revenue, pos, cpt.",
         call. = FALSE)
  if (cfg$months_as == "calendar")
    message("[config] MONTHS_AS=calendar: month windows use add_months(), so ",
            "two patients indexed a day apart can face windows of different ",
            "lengths. See ../OPEN_QUESTIONS.md Q21.")
  invisible(TRUE)
}
