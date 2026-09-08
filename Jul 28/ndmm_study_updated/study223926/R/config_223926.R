# Settings for study 223926, and the contract that pins the protocol's own
# numbers.
#
# Three layers, in this order of authority:
#
#   1. the environment          - a shell export or a Domino-injected value
#   2. config.csv               - the defaults, filled only where 1 is unset
#   3. cfg_defaults() below     - the fallback, if a row is missing from the CSV
#
# Layer 3 means a truncated config.csv cannot silently change a definition.
#
# CONTRACT is the subset the protocol states outright. Changing one is a
# different study: it needs SETTINGS_OVERRIDE=TRUE and lands in
# CONTRACT_DEVIATIONS on the run's status row. Everything else is a reading the
# protocol leaves open, and every run records which one it used.

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

# The protocol's own numbers, with the section each comes from.
CONTRACT <- list(
  baseline_days             = 365L,   # s7.1
  ce_pre_days               = 365L,   # s7.2.1.1
  gap_days                  = 30L,    # s7.2.1.1
  lot_post_discon_days      = 30L,    # Figure 1 note 2
  acute_washout_days        = 30L,    # s7.3.2
  tte_min_potential_fu_days = 90L,    # s7.8.2
  suppress_min_n            = 25L,    # s7.2.3
  lot1_index_from           = "2019-01-01",  # s7.1
  sec2l_index_from          = "2020-01-01",  # s7.4
  study_end                 = "2026-03-31"   # s7.1
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
    # CDM table names, overridable. The defaults are in CDM_TABLE_NAMES and
    # match the cohort build's; blank here means use those.
    tbl_medical           = .env_chr("TBL_MEDICAL", ""),
    tbl_diagnosis         = .env_chr("TBL_MED_DIAG", ""),
    tbl_procedure         = .env_chr("TBL_MED_PROC", ""),
    tbl_rx                = .env_chr("TBL_RX", ""),
    tbl_confinement       = .env_chr("TBL_CONFINEMENT", ""),
    tbl_member_enrollment = .env_chr("TBL_MEMBER_ENROLLMENT", ""),
    tbl_member_elig       = .env_chr("TBL_MEMBER_ELIG", ""),
    tbl_dod               = .env_chr("TBL_DOD", ""),
    # Empty means "this package's own codelists/", resolved against the
    # package directory in build_223926(). The folder ships the shapes so it is
    # complete on its own; production points this at the real directory.
    codelist_dir = .env_chr("CODELIST_DIR", ""),

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
    # s7.4.1.1 wants 2L initiators regardless of when their 1L fell, and
    # s7.8.1 permits a prior malignancy. Every cohort here joins onto
    # INPUT_COHORT_TABLE, so no setting can widen that input.
    #
    # TRUE asserts the input was built without X2 and without the 1L floor.
    # Only whoever ran it knows, so it is an assertion, not a test. FALSE with
    # SEC2L selected stops rather than reporting a prevalence of zero.
    sec2l_input_is_wide = .env_lgl("SEC2L_INPUT_IS_WIDE", FALSE),
    # The 1L index-setting agents are NOT a setting here. Barring belantamab,
    # panobinostat or elotuzumab from setting an index means re-deriving the
    # index date, which is the cohort build's job - ndmm/ already has
    # NDMM_INDEX_EXCLUDED_ABBRS for exactly this. A second copy here would be
    # recorded as applied while applying nothing. ../BUILD_DELTA.md section 3.
    lot_allow_unproven_lineage = .env_lgl("LOT_ALLOW_UNPROVEN_LINEAGE", FALSE),

    # --- follow-up and censoring -----------------------------------------
    censor_at_disenrollment  = .env_lgl("CENSOR_AT_DISENROLLMENT", TRUE),
    # BRIDGED_GAP_IS_PERSON_TIME was here and is gone. It named a person-time
    # rule - whether a bridged enrolment gap counts as observed time - and
    # BASELINE_PY and PERIOD_PY are window lengths whichever way it was set, so
    # flipping it changed no denominator while the run recorded that it had.
    # ../OPEN_QUESTIONS.md Q19 is still open; it is not answered by a setting
    # that does nothing.

    # --- comorbidity ------------------------------------------------------
    # Both off by default, and both are switches rather than silent omissions.
    # Frailty needs Annex 7 and the subgroup flags need Annex 3; neither has
    # been delivered, so asking for either stops the run naming the annex.
    frailty            = .env_lgl("FRAILTY", FALSE),
    comorbid_subgroups = .env_lgl("COMORBID_SUBGROUPS", FALSE),
    # Kim 2018's own cut-point. A setting rather than a constant because the
    # protocol says "CFI >= 0.25 = frail" and Annex 7 may say otherwise.
    frailty_frail_cutoff = as.numeric(.env_chr("FRAILTY_FRAIL_CUTOFF", "0.25")),

    # --- demographics -----------------------------------------------------
    region_source = .env_enum("REGION_SOURCE", "state_crosswalk",
      c("region_column", "state_crosswalk")),
    enrol_attr_at = .env_enum("ENROL_ATTR_AT", "index_span",
      c("index_span", "latest_span")),
    ed_definition = .env_list("ED_DEFINITION", "revenue,pos"),
    # An ED visit that becomes an admission: counted as an ED visit, a
    # hospitalisation, or both? ../OPEN_QUESTIONS.md Q11 asks it and the CDM
    # answers the mechanics - business rule 14: "All other records without a
    # CONF_ID or where CONF_ID is NULL should be considered non-inpatient". So
    # an ED claim carrying a CONF_ID is one that became an admission, and it
    # can be dropped from the ED count. `both` is the current behaviour and
    # stays the default; it is not obviously right, which is why it is
    # recorded rather than assumed.
    ed_admitted = .env_enum("ED_ADMITTED", "both", c("both", "inpatient_only")),

    # --- which route makes a stay MM-related --------------------------------
    # s7.8.1 says "first or second position" without saying of what.
    # `confinement` reads CONFINEMENT.DIAG1/DIAG2; `claim_positions` reads
    # MED_DIAGNOSIS.DIAG_POSITION 1-2 on a claim carrying the CONF_ID, which is
    # the route business rule 13 documents.
    #
    # Over 241,362 stays they find 32,508 and 65,206, and 33,904 stays only the
    # claim route finds. Largest unresolved swing here. See OPEN_QUESTIONS Q27.
    # `confinement` is what every number so far used, so it stays the default.
    mm_hosp_position = .env_enum("MM_HOSP_POSITION", "confinement",
                                 c("confinement", "claim_positions")),

    # --- claim status -----------------------------------------------------
    # MEDICAL.PAID_STATUS separates PAID from DENIED. Nothing has ever filtered
    # on it, and `all` keeps it that way by default.
    #
    # Denials are 17.4% of medical lines but concentrate in ordinary outpatient
    # claims. At the event grain only 2,630 of 499,272 ED patient-days have
    # every line denied, so paid_only removes one ED visit in 200.
    #
    # It is narrower than its name: claim_status_sql() has one call site, the
    # ED arm of 07_hcru.R. It does not reach the I5 follow-up test, the
    # MM-hospitalisation subquery, CONFINEMENT, or RX - the pharmacy table has
    # no paid status, and STD_COST cannot stand in for one (14.9M denied lines
    # carry a positive value). Widening it is a study decision, not a config
    # change. See OPEN_QUESTIONS Q25.
    claim_status = .env_enum("CLAIM_STATUS", "all", c("all", "paid_only")),

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

# Every open question's reading, and WHERE it is applied. Written to the run's
# metadata so a number can be traced to the readings behind it.
#
# The distinction matters: without it a reader cannot tell a window this
# package applied from one the cohort build applied.
#
#   "here"      this package's SQL changes when the setting changes, and
#               tests/run_tests.R proves it by emitting both ways.
#   "upstream"  the rule belongs to the cohort or LOT build. Recorded so the
#               tables say which definition produced them; applied elsewhere.
OPEN_QUESTION_SOURCE <- c(
  fu_evidence_rule                    = "here",
  sec2l_apply_other_cancer            = "here",
  sec2l_input_is_wide                 = "here",
  censor_at_disenrollment             = "here",
  months_as                           = "here",
  baseline_includes_index             = "here",
  comorbidity_baseline_includes_index = "here",
  region_source                       = "here",
  enrol_attr_at                       = "here",
  ed_definition                       = "here",
  ed_admitted                         = "here",
  mm_hosp_position                    = "here",
  claim_status                        = "here",
  frailty                             = "here",
  comorbid_subgroups                  = "here",
  # Applied by the cohort build (Jul 28/ndmm), not here. ../BUILD_DELTA.md.
  study_start                         = "upstream",
  mm_dx_outpatient_codes              = "upstream",
  mm_dx_outpatient_window_days        = "upstream",
  prior_tx_drop_steroids              = "upstream",
  other_cancer_pair_days              = "upstream",
  other_cancer_pair_grain             = "upstream",
  other_cancer_both_in_baseline       = "upstream",
  pregnancy_window                    = "upstream"
)

open_question_readings <- function(cfg) {
  vapply(names(OPEN_QUESTION_SOURCE), function(k) {
    v <- paste(as.character(cfg[[k]]), collapse = "|")
    sprintf("%s=%s%s", k, v,
            if (identical(OPEN_QUESTION_SOURCE[[k]], "upstream"))
              " (upstream)" else "")
  }, character(1), USE.NAMES = FALSE)
}

check_settings <- function(cfg) {
  # REGION does not exist on the deployed enrolment table. The V9.0 dictionary
  # documents it as Added, and three of the four V9 additions did land on the
  # 2025q4 extract - ETHNICITY, RACE (moved from the SES file and renamed from
  # D_RACE_CODE) and RACE_SOURCE, appended at columns 26 and 27. REGION and
  # LIS_DUAL did not. Verified column by column against the `describe table`
  # in the Optum enrolment documentation; ../DATA_MAPPING.md section 4 has the list.
  #
  # Refused here rather than left to Spark, which would say UNRESOLVED_COLUMN
  # after the session had been opened and the spine built.
  if (identical(cfg$region_source, "region_column"))
    stop("SETTING ERROR: REGION_SOURCE=region_column reads ",
         "MEMBER_ENROLLMENT.REGION, which the deployed extract does not have. ",
         "It is a V9.0 addition and the deployed table is an earlier vintage: ",
         "27 columns, carrying STATE (which V9.0 removed) and neither REGION ",
         "nor LIS_DUAL. Use REGION_SOURCE=state_crosswalk, or confirm the ",
         "warehouse has been refreshed to a true V9.0 extract first. ",
         "../OPEN_QUESTIONS.md Q9.", call. = FALSE)

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
