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
    categorical = c("AGE_BAND", "SEX", "REGION", "RACE", "ETHNICITY",
                    "INSURANCE_TYPE"),
    continuous = "AGE_YEARS"),

  S_COMORBIDITY = list(
    shape = "subject", label = "Charlson comorbidity",
    keys = c("COHORT"), id = "PATID",
    categorical = "CCI_BAND", continuous = c("CCI", "N_CONDITIONS")),

  S_PERIODS = list(
    shape = "subject", label = "Baseline and follow-up periods",
    keys = c("COHORT", "LOT_NUM"), id = "PATID",
    categorical = "TTE_ELIGIBLE",
    continuous = c("FU_DAYS", "FU_MONTHS", "BASELINE_PY")),

  S_SOC = list(
    shape = "subject", label = "SOC regimen category",
    keys = c("COHORT", "LOT_NUM"), id = "PATID",
    categorical = c("SOC_CATEGORY", "MATCHED"), continuous = "N_AGENTS"),

  S_SAFETY_RATES = list(
    shape = "rate", label = "Key safety events",
    keys = c("COHORT", "LOT_NUM", "PERIOD"),
    facet = "CONDITION", groups = c("DOMAIN", "ACUTE_CHRONIC"),
    n_col = "N_AT_RISK", rate = "RATE", lo = "RATE_LO", hi = "RATE_HI",
    numerator = "N_PATIENTS", events = "N_EVENTS", py = "PERSON_YEARS"),

  S_HCRU_RATES = list(
    shape = "rate", label = "Healthcare resource use",
    keys = c("COHORT", "LOT_NUM", "PERIOD"),
    facet = "MEASURE",
    n_col = "N_AT_RISK", rate = "RATE",
    numerator = "N_PATIENTS", events = "N_EVENTS", py = "PERSON_YEARS",
    extra = c("MEAN_LOS", "MEDIAN_LOS", "N_LOS_EXCLUDED")),

  S_MALIGNANCY_RATES = list(
    shape = "rate", label = "Secondary malignancies",
    keys = c("COHORT", "LOT_NUM", "PERIOD"),
    facet = "CATEGORY",
    n_col = "N_AT_RISK", rate = "RATE",
    numerator = "N_PATIENTS", py = "PERSON_YEARS"),

  S_PATTERNS = list(
    shape = "count", label = "Treatment patterns",
    keys = c("COHORT", "LOT_NUM"), facet = "SOC_CATEGORY",
    n_col = "N_PATIENTS", denom = "N_DENOM", pct = "PCT"),

  S_TX_ATTRITION = list(
    shape = "count", label = "Treatment attrition",
    keys = c("COHORT", "LOT_NUM"), facet = "OUTCOME",
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
    categorical = c("CATEGORY", "SUBTYPE"),
    continuous = c("MONTHS_FROM_DX", "MONTHS_FROM_INDEX")),

  S_SAFETY_EVENTS = list(
    shape = "subject", label = "Safety events, per patient",
    keys = "COHORT", id = "PATID",
    categorical = c("CONDITION", "DOMAIN", "ACUTE_CHRONIC")),

  S_HCRU_EVENTS = list(
    shape = "subject", label = "HCRU events, per patient",
    keys = "COHORT", id = "PATID",
    categorical = c("EVENT_TYPE", "MM_RELATED", "HAS_DISCHARGE"),
    continuous = "LOS_DAYS")
)

# A table nothing declared. Its keys are the columns the package uses as keys
# everywhere, its numbers are whatever is numeric, and it is shown as a grid.
GENERIC_KEYS <- c("COHORT", "LOT_NUM", "PERIOD")

table_spec <- function(name, cols = character(0)) {
  s <- TABLE_SPEC[[name]]
  if (!is.null(s)) return(utils::modifyList(list(name = name), s))
  list(name = name, shape = "grid",
       label = gsub("_", " ", sub("^S_", "", name)),
       keys = intersect(GENERIC_KEYS, cols), declared = FALSE)
}

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
