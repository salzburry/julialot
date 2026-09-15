# What each output table IS, so one renderer can serve all of them.
#
# The package's registry says which tables exist and which module writes them.
# It does not say how to READ one: which columns are the stratum, which are the
# numbers, and which number is the denominator a suppression rule tests. That
# is what this adds, and nothing else.
#
# A table with no entry here is still shown - as a plain grid, with its keys
# guessed from its column types. So a module added to the package appears in
# the dashboard without an edit, and gets a better view when someone writes
# three lines here.

# shape:
#   rate    one row per stratum x measure, carrying a rate and its denominator
#   count   one row per stratum, carrying a count and a percentage
#   subject one row per patient
#   edge    one row per from -> to pair, for a flow view
#   funnel  one row per criterion, in the order they applied
TABLE_SPEC <- list(
  S_ATTRITION = list(
    shape = "funnel", label = "Attrition funnel",
    keys = c("COHORT"), order = "STEP",
    facet = "CRITERION", values = c("N_REMAINING", "N_LOST")),

  S_DEMOGRAPHICS = list(
    shape = "subject", label = "Baseline demographics",
    keys = c("COHORT"), id = "PATID",
    # Both age columns, because the table carries both and they answer
    # different questions: AGE_BAND is the four-band distribution Table 1
    # reports, AGE_GROUP the protocol's two-group stratification that the rate
    # tables are cut by. Showing only the first would leave the grouping every
    # subgroup column depends on impossible to look at.
    categorical = c("AGE_BAND", "AGE_GROUP", "AGE_AT_DX_BAND", "SEX", "REGION",
                    "RACE", "ETHNICITY", "INSURANCE_TYPE", "ATTR_SOURCE"),
    continuous = c("AGE_YEARS", "AGE_AT_DX_YEARS")),

  S_COMORBIDITY = list(
    shape = "subject", label = "Charlson comorbidity",
    keys = c("COHORT"), id = "PATID",
    categorical = "CCI_BAND", continuous = c("CCI", "N_CONDITIONS")),

  S_PERIODS = list(
    shape = "subject", label = "Baseline and follow-up periods",
    keys = c("COHORT", "LOT_NUM"), id = "PATID",
    # DX_YEAR and the two diagnosis-anchored durations are Table 4's year of
    # MM diagnosis, follow-up from diagnosis, and Table 5's time from
    # diagnosis to 1L; DX_DT_SOURCE says which diagnosis date they hang on.
    categorical = c("TTE_ELIGIBLE", "INDEX_YEAR", "DX_YEAR", "DX_DT_SOURCE"),
    continuous = c("FU_DAYS", "FU_MONTHS", "BASELINE_PY",
                   "DX_TO_INDEX_MONTHS", "FU_FROM_DX_MONTHS")),

  S_SOC = list(
    shape = "subject", label = "SOC regimen category",
    keys = c("COHORT", "LOT_NUM"), id = "PATID",
    # The transplant flags and year are Table 6's SCT-by-year-by-SOC count.
    categorical = c("SOC_CATEGORY", "MATCHED", "LOT_START_YEAR",
                    "AUTO_SCT", "ALLO_SCT", "CART", "AUTO_SCT_YEAR"),
    continuous = "N_AGENTS"),

  S_SAFETY_RATES = list(
    shape = "rate", label = "Key safety events",
    keys = c("COHORT", "LOT_NUM", "PERIOD", "SOC_CATEGORY", "AGE_GROUP"),
    facet = "CONDITION", groups = c("DOMAIN", "ACUTE_CHRONIC"),
    n_col = "N_AT_RISK", rate = "RATE", lo = "RATE_LO", hi = "RATE_HI",
    numerator = "N_PATIENTS", events = "N_EVENTS", py = "PERSON_YEARS"),

  S_HCRU_RATES = list(
    shape = "rate", label = "Healthcare resource use",
    keys = c("COHORT", "LOT_NUM", "PERIOD", "SOC_CATEGORY", "AGE_GROUP"),
    facet = "MEASURE",
    n_col = "N_AT_RISK", rate = "RATE",
    numerator = "N_PATIENTS", events = "N_EVENTS", py = "PERSON_YEARS",
    extra = c("MEAN_LOS", "MEDIAN_LOS", "N_LOS_EXCLUDED")),

  S_MALIGNANCY_RATES = list(
    shape = "rate", label = "Secondary malignancies",
    keys = c("COHORT", "LOT_NUM", "PERIOD", "SOC_CATEGORY", "AGE_GROUP"),
    facet = "CATEGORY",
    n_col = "N_AT_RISK", rate = "RATE", lo = "RATE_LO", hi = "RATE_HI",
    numerator = "N_PATIENTS", py = "PERSON_YEARS"),

  S_PATTERNS = list(
    shape = "count", label = "Treatment patterns",
    keys = c("COHORT", "LOT_NUM"), facet = "SOC_CATEGORY",
    n_col = "N_PATIENTS", denom = "N_DENOM", pct = "PCT"),

  S_TX_ATTRITION = list(
    shape = "count", label = "Treatment attrition",
    keys = c("COHORT", "LOT_NUM", "SOC_CATEGORY", "AGE_GROUP"),
    facet = "OUTCOME",
    n_col = "N_PATIENTS", denom = "N_DENOM", pct = "PCT"),

  S_SWITCH = list(
    shape = "edge", label = "Regimen transitions",
    keys = "COHORT", from = "FROM_CATEGORY", to = "TO_CATEGORY",
    from_lot = "FROM_LOT", to_lot = "TO_LOT", n_col = "N_PATIENTS"),

  S_TTE = list(
    shape = "subject", label = "Time to event",
    keys = c("COHORT", "LOT_NUM"), id = "PATID",
    categorical = "TTE_ELIGIBLE",
    continuous = c("TTNT_MONTHS", "TTD_MONTHS", "OS_MONTHS"),
    endpoints = list(
      TTNT = c(time = "TTNT_MONTHS", event = "TTNT_EVENT"),
      TTD  = c(time = "TTD_MONTHS",  event = "TTD_EVENT"),
      OS   = c(time = "OS_MONTHS",   event = "OS_EVENT"))),

  S_MALIGNANCY = list(
    shape = "subject", label = "Secondary malignancy detail",
    keys = "COHORT", id = "PATID",
    categorical = c("CATEGORY", "SUBTYPE", "AFTER_INDEX"),
    continuous = c("MONTHS_FROM_DX", "MONTHS_FROM_INDEX")),

  # Table 4's "top 5-10 sequences among those with a malignancy occurring
  # after treatment", every sequence ranked, in two scopes: after the
  # cohort's index, and - the sensitivity - after 2L.
  S_MALIGNANCY_SEQUENCES = list(
    shape = "count", label = "Treatment sequences among those with a malignancy",
    # LINES is the reading of "sequence": the lines up to the malignancy,
    # the lines after it, or every observed line - each its own denominator.
    keys = c("COHORT", "SCOPE", "LINES"), facet = "SEQUENCE",
    n_col = "N_PATIENTS", denom = "N_DENOM", pct = "PCT"),

  S_SAFETY_EVENTS = list(
    shape = "subject", label = "Safety events, per patient",
    keys = "COHORT", id = "PATID",
    categorical = c("CONDITION", "DOMAIN", "ACUTE_CHRONIC")),

  # --- the LOT engine's own outputs ---------------------------------------
  #
  # A different build wrote these, under its own prefix, and a study scenario
  # records which run in S_RUN_METADATA.LOT_RUN_ID. Several scenarios normally
  # share one LOT run, because none of this package's open questions changes
  # how a line is counted - so these describe a scenario's lineage rather than
  # the scenario.
  LOT_LONG_FINAL = list(
    shape = "subject", label = "Lines of therapy, after the line criteria",
    source = "lot", keys = "LOT_NUM", id = "PATID",
    categorical = c("LOT_START_TYPE", "LOT_BASE_END_REASON", "LOT_ALLO_LOT_FLG",
                    "LOT_CART_LOT_FLG", "LOT_BASE_MEDS"),
    continuous = c("LOT_MED_CNT", "LOT_BASE_LENGTH")),

  LOT_LONG = list(
    shape = "subject", label = "Lines of therapy, BEFORE the line criteria",
    source = "lot", keys = "LOT_NUM", id = "PATID",
    categorical = c("LOT_START_TYPE", "LOT_BASE_END_REASON"),
    continuous = c("LOT_MED_CNT", "LOT_BASE_LENGTH")),

  LOT_ATTRITION = list(
    shape = "funnel", label = "LOT funnel: cohort to study population",
    source = "lot", keys = character(0), order = "STEP_NUM",
    facet = "STEP", groups = "KIND",
    values = c("N_PATIENTS", "N_LINES", "PCT_OF_START", "PCT_OF_PREV")),

  LOT_FACE_VALIDITY = list(
    shape = "check", label = "Face validity",
    source = "lot", keys = character(0), facet = "WHAT",
    value = "VALUE", lo = "EXPECT_LO", hi = "EXPECT_HI", verdict = "VERDICT"),

  LOT_QC_SUMMARY = list(
    shape = "check", label = "QC checks",
    source = "lot", keys = character(0), facet = "CHECK_NAME",
    value = "CHECK_VALUE", verdict = "CHECK_STATUS"),

  LOT_RUN_METADATA = list(
    shape = "grid", label = "What produced these lines", source = "lot",
    keys = character(0)),

  LOT_BUILD_STATUS = list(
    shape = "grid", label = "LOT build status", source = "lot",
    keys = character(0)),

  S_HCRU_EVENTS = list(
    shape = "subject", label = "HCRU events, per patient",
    keys = "COHORT", id = "PATID",
    categorical = c("EVENT_TYPE", "MM_RELATED", "HAS_DISCHARGE"),
    continuous = "LOS_DAYS")
)

# A table nothing declared. Its keys are the columns the package uses as keys
# everywhere, its numbers are whatever is numeric, and it is shown as a grid.
GENERIC_KEYS <- c("COHORT", "LOT_NUM", "PERIOD")

# The package writes its rate and count tables once for each line as a whole
# and once per stratum, with the line's own row labelled below. These are keys
# rather than facets on those tables: a viewer selects a stratum the way they
# select a line.
#
# They are NOT in GENERIC_KEYS, which is what a table with no spec of its own
# falls back to. A table carrying the column without carrying the total row -
# S_SOC, S_PATTERNS, S_DEMOGRAPHICS - would be filtered to a value it does not
# have and come back empty. The four tables that do carry it name it in their
# own spec.
# Named for this folder, not STRATUM_TOTALS: the package registry declares one
# of those and global.R sources it, so the two would shadow each other and the
# survivor would be whichever was sourced last. The suite holds this one
# against the package's and the shells', which is the drift that matters.
DASH_STRATUM_TOTALS <- c(SOC_CATEGORY = "(all categories)",
                         AGE_GROUP = "(all ages)")

# The keys a viewer is offered, which is the generic ones plus the strata.
SELECTABLE_KEYS <- c(GENERIC_KEYS, names(DASH_STRATUM_TOTALS))

# What a key starts at. A stratum starts at the line's own row, because a chart
# over every row would draw the line beside its own parts.
key_default <- function(k, cohort_default) {
  if (identical(k, "COHORT")) return(cohort_default)
  if (k %in% names(DASH_STRATUM_TOTALS))
    return(unname(DASH_STRATUM_TOTALS[[k]]))
  "all"
}

table_spec <- function(name, cols = character(0)) {
  s <- TABLE_SPEC[[name]]
  if (!is.null(s))
    return(utils::modifyList(list(name = name, source = "study"), s))
  list(name = name, shape = "grid",
       label = gsub("_", " ", sub("^S_", "", name)),
       source = if (startsWith(name, "LOT")) "lot" else "study",
       keys = intersect(GENERIC_KEYS, cols), declared = FALSE)
}

# The LOT engine's output tables and its own record. Named here rather than
# imported from lot/engine/R/build_lot.R, because this folder has to stand on
# its own. tests/run_tests.R compares this list to LOT_TABLES whenever the
# engine is beside us, so one gaining a table and not the other is caught.
LOT_DASHBOARD_TABLES <- c("LOT_LONG_FINAL", "LOT_LONG", "LOT_ATTRITION",
                          "LOT_FACE_VALIDITY", "LOT_QC_SUMMARY",
                          "LOT_RUN_METADATA", "LOT_BUILD_STATUS")

# Every table the package can write, with the module that writes it. Read off
# the package's own registry, so this cannot drift from what a run produces.
dashboard_tables <- function(modules = MODULES) {
  rows <- lapply(modules, function(m)
    if (!length(m$outputs)) NULL else
      data.frame(TABLE = m$outputs, MODULE = m$key, MODULE_LABEL = m$label,
                 PER_COHORT = isTRUE(m$per_cohort),
                 BLOCKED = if (is.na(m$blocked)) "" else m$blocked,
                 stringsAsFactors = FALSE))
  out <- do.call(rbind, Filter(Negate(is.null), rows))
  out$SHAPE <- vapply(out$TABLE, function(t) table_spec(t)$shape, character(1))
  out$LABEL <- vapply(out$TABLE, function(t) table_spec(t)$label, character(1))
  rownames(out) <- NULL
  out
}
