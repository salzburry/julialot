# The two registries, and how a run is selected out of them.
#
# Everything this package can build is declared here as data, not as a call
# order. A module names what it needs, what it writes, and which code lists it
# cannot run without; the runner works out the order and refuses a selection it
# cannot satisfy. So "run only the safety outcomes over the 2L cohort" is a
# setting rather than an edit.
#
# The rule the whole file exists to enforce: a module that is asked for and
# cannot run STOPS the run. It never returns an empty table. A rate of zero for
# want of a code list is indistinguishable from a rate of zero for want of
# events, and only one of them is a finding.

# ---------------------------------------------------------------------------
# Cohorts
# ---------------------------------------------------------------------------
#
# key        what the study calls it
# label      for logs and for the attrition table
# lot_num    the line whose start is this cohort's index date
# nested_in  the cohort this one is drawn from, or NA for a standalone one
# index_from cfg field holding the earliest index date, or NA for no floor
# criteria   the eligibility criteria that apply, in the order they apply
#
# The 1L criteria are the study's own; 2L and 3L add only the two the protocol
# lists under "Additional eligibility"; SEC2L repeats the 1L set minus the
# other-cancer exclusion. Nothing here is inferred - see ../IE_CRITERIA.md.

CRITERIA_1L <- c("I1_mm_dx", "I2_age", "I3_eligible_1l_tx", "I4_ce_pre",
                 "I5_followup", "X1_prior_mm_tx", "X2_other_cancer",
                 "X3_pregnancy", "X4_belantamab")

# table -> the count the rule TESTS, and the values that go with it when a cell
# is suppressed. Spec data, so a module that adds a column cannot quietly leave
# it unsuppressed.
#
# `n_col` is the POPULATION the row describes, not the patients who had the
# event: s7.2.3 and s7.8 restrict by stratum size. So the rate tables test
# N_AT_RISK and suppress N_PATIENTS as a value; the count-only tables have no
# separate denominator, and their N_PATIENTS is both.
#
# `group_by` is the stratum a table's rows divide up. mod_release() reads it to
# find the groups where exactly one row was suppressed, because that row is
# recoverable by subtracting the published rest from the group's own total.
# `facet` is the column whose values a table's rows enumerate. With
# SOC_CATEGORY beside it the regimen categories of one facet value DO sum to
# that value's (all categories) row, so a single suppressed category is
# recoverable from the total less the published rest - a stronger relation than
# the group above, and checked separately in mod_release().
SUPPRESSION_SPEC <- list(
  S_SAFETY_RATES = list(
    n_col = "N_AT_RISK",
    group_by = c("COHORT", "LOT_NUM", "PERIOD"),
    facet = "CONDITION",
    value_cols = c("N_PATIENTS", "N_EVENTS", "PERSON_YEARS", "RATE",
                   "RATE_LO", "RATE_HI")),
  S_HCRU_RATES = list(
    n_col = "N_AT_RISK",
    group_by = c("COHORT", "LOT_NUM", "PERIOD"),
    facet = "MEASURE",
    value_cols = c("N_PATIENTS", "N_EVENTS", "PERSON_YEARS", "RATE",
                   "MEAN_LOS", "MEDIAN_LOS", "N_LOS_EXCLUDED")),
  S_MALIGNANCY_RATES = list(
    n_col = "N_AT_RISK",
    group_by = c("COHORT", "LOT_NUM", "PERIOD"),
    facet = "CATEGORY",
    value_cols = c("N_PATIENTS", "PERSON_YEARS", "RATE", "RATE_LO", "RATE_HI")),
  # One row per treatment sequence among the patients with a malignancy, so
  # the count IS the stratum: a sequence held by fewer than the floor is a
  # cell about fewer than the floor.
  S_MALIGNANCY_SEQUENCES = list(
    n_col = "N_PATIENTS",
    group_by = c("COHORT", "SCOPE", "LINES"),
    value_cols = c("PCT")),
  S_PATTERNS = list(
    n_col = "N_PATIENTS",
    group_by = c("COHORT", "LOT_NUM"),
    value_cols = c("PCT")),
  S_SWITCH = list(
    n_col = "N_PATIENTS",
    group_by = c("COHORT", "FROM_LOT"),
    value_cols = character(0)),
  S_TX_ATTRITION = list(
    n_col = "N_PATIENTS",
    group_by = c("COHORT", "LOT_NUM"),
    facet = "OUTCOME",
    value_cols = c("N_DENOM", "PCT"))
)


# --- the stratifications ----------------------------------------------------
#
# The rate and count tables are written once for each line as a whole and then
# once per stratum of each stratification. Every pass runs the SAME query with
# one more column in the GROUP BY, so the counting rules, the washout, the
# person-time and the confidence intervals are the ones stated above,
# unchanged: a stratum's numbers are the line's own arithmetic over a subset of
# its patients.
#
# The total keeps a row of its own rather than being left to be added up,
# because a rate is not the sum of its strata's rates and a confidence interval
# is not the sum of theirs. It is labelled, not blank: a NULL there would be
# read as a missing stratum.
#
# MARGINS, NOT A CROSS. A row is stratified by regimen category or by age, not
# by both at once: no table the protocol asks for crosses them, and every cell
# of the cross would fall under the floor. So a query naming a real value in
# both columns finds no row, which is the honest answer rather than a zero.
#
# The age stratification is AGE_GROUP - the protocol's two groups - and not
# S_DEMOGRAPHICS.AGE_BAND's four descriptive ones. A rate is not the sum of its
# strata's rates, so a grouping that spread "< 75" over three rows could report
# no rate for it at all.
STRATUM_TOTALS <- c(SOC_CATEGORY = "(all categories)", AGE_GROUP = "(all ages)")

# A line the soc module wrote no row for, and a patient the demographics module
# found no enrolment row for. Neither can happen while those modules run over
# the same spine, and both are named rather than dropped so that the strata
# still sum to the total if either ever does.
SOC_UNCATEGORISED <- "(uncategorised)"
# Not "Unknown": the demographics module writes that as a real age group, for a
# patient whose age it could not read. This one means there was no row to read
# at all, which is a different thing and must not be folded into it.
AGE_NO_ROW <- "(no demographics row)"

soc_stratified <- function(cfg) isTRUE("soc" %in% cfg$modules_run)
age_stratified <- function(cfg) isTRUE("demographics" %in% cfg$modules_run)

# One pass: the SELECT list for the stratum columns, the GROUP BY fragment for
# the ones that vary, and the join that carries them. `on` is the alias in that
# query of the table holding PATID, COHORT and LOT_NUM.
.stratum_pass <- function(key, exprs, vary, join) {
  nms <- names(STRATUM_TOTALS)
  list(key = key,
       cols = paste(sprintf("%s AS %s", exprs[nms], nms), collapse = ", "),
       group = if (length(vary)) paste0(", ", paste(exprs[vary], collapse = ", "))
               else "",
       join = join)
}

stratum_passes <- function(cfg, on) {
  lit <- vapply(STRATUM_TOTALS, function(v) sprintf("'%s'", v), character(1))
  out <- list(.stratum_pass("total", lit, character(0), ""))
  if (soc_stratified(cfg)) {
    e <- lit
    e[["SOC_CATEGORY"]] <- sprintf("coalesce(soc.SOC_CATEGORY, '%s')",
                                   SOC_UNCATEGORISED)
    out <- c(out, list(.stratum_pass("by_soc", e, "SOC_CATEGORY",
      sprintf("LEFT JOIN %s soc ON soc.PATID = %s.PATID
               AND soc.COHORT = %s.COHORT AND soc.LOT_NUM = %s.LOT_NUM",
              wrk("S_SOC"), on, on, on))))
  }
  if (age_stratified(cfg)) {
    e <- lit
    e[["AGE_GROUP"]] <- sprintf("coalesce(age.AGE_GROUP, '%s')", AGE_NO_ROW)
    # Age is the cohort's own index age, so the join is on the patient and the
    # cohort: S_DEMOGRAPHICS is one row per patient per cohort, not per line.
    out <- c(out, list(.stratum_pass("by_age", e, "AGE_GROUP",
      sprintf("LEFT JOIN %s age ON age.PATID = %s.PATID
               AND age.COHORT = %s.COHORT",
              wrk("S_DEMOGRAPHICS"), on, on))))
  }
  out
}

# What the release module found that a publication gate has to know about: the
# groups where one withheld row is the group's total less the published rest.
#
# Recorded here as well as logged. Whether to regroup or withhold a second
# stratum is the analyst's call and this package does not make it - but a log
# line cannot be gated on, and a release that leaves the warehouse carrying a
# recoverable cell is the one thing a gate most needs to refuse. So the run's
# own metadata says so, in a column a check can read.
.release_state <- new.env(parent = emptyenv())

# Two records of the same finding, because they answer to two readers. The
# sentence is for a person reading the metadata row. The list of table names is
# for the gate: a gate that has to recover table names out of a sentence is
# guessing - a reworded warning names none and turns a targeted refusal into a
# blanket one, and a table whose name is a substring of another's is refused
# with it - so the producer, which knows exactly which table it found, says so
# in a field of its own.
release_recoverable_reset <- function() {
  assign("groups", character(0), envir = .release_state)
  assign("tables", character(0), envir = .release_state)
}

release_recoverable_note <- function(table, txt) {
  assign("groups", c(release_recoverable(), txt), envir = .release_state)
  assign("tables", unique(c(release_recoverable_tables(), table)),
         envir = .release_state)
}

release_recoverable <- function()
  get0("groups", envir = .release_state, ifnotfound = character(0))

release_recoverable_tables <- function()
  get0("tables", envir = .release_state, ifnotfound = character(0))

COHORTS <- list(
  `1L` = list(
    key = "1L", label = "1L (NDMM)", lot_num = 1L, nested_in = NA_character_,
    index_from = "lot1_index_from", criteria = CRITERIA_1L),
  `2L` = list(
    key = "2L", label = "2L (RRMM, nested)", lot_num = 2L, nested_in = "1L",
    index_from = NA_character_,
    criteria = c("N1_received_line", "N2_ce_pre", "I5_followup")),
  `3L` = list(
    key = "3L", label = "3L (RRMM, nested)", lot_num = 3L, nested_in = "2L",
    index_from = NA_character_,
    criteria = c("N1_received_line", "N2_ce_pre", "I5_followup")),
  SEC2L = list(
    key = "SEC2L", label = "Secondary 2L (RRMM, not nested)", lot_num = 2L,
    nested_in = NA_character_, index_from = "sec2l_index_from",
    # s7.4.1.1: "All inclusion/exclusion criteria will be the same as the
    # primary cohort, with the exception of the index date", and s7.8.1
    # confirms prior malignancy is permitted. X2 is dropped by
    # SEC2L_APPLY_OTHER_CANCER, resolved in resolve_cohorts().
    criteria = CRITERIA_1L)
)

# ---------------------------------------------------------------------------
# Modules
# ---------------------------------------------------------------------------
#
# key        what MODULES= names
# label      for logs
# needs      module keys that must run first
# codelists  code-list files the module cannot run without
# outputs    the unprefixed table names it writes
# per_cohort TRUE if it runs once per selected cohort
# fn         the function name, defined under R/modules/
# blocked    a reason string if the module cannot run yet, or NA

MODULES <- list(
  # The package's two independent roots. Eligibility is the cohort build's
  # verdict and needs no line of therapy; the spine is the LOT engine's lines
  # and needs no cohort. Neither reads the other. `cohorts` is where a patient
  # and a line are combined, and it is the first module that needs both.
  eligibility = list(
    key = "eligibility", label = "Eligibility, without a line of therapy",
    needs = character(0), codelists = character(0),
    outputs = "S_ELIGIBILITY", per_cohort = FALSE,
    fn = "mod_eligibility", blocked = NA_character_),

  spine = list(
    key = "spine", label = "Cohort x LOT spine", needs = character(0),
    codelists = character(0), outputs = "S_SPINE", per_cohort = FALSE,
    fn = "mod_spine", blocked = NA_character_),

  cohorts = list(
    key = "cohorts", label = "Cohort membership",
    needs = c("eligibility", "spine"), codelists = character(0),
    outputs = "S_COHORT", per_cohort = TRUE,
    fn = "mod_cohorts", blocked = NA_character_),

  attrition = list(
    key = "attrition", label = "The attrition funnel",
    needs = "cohorts", codelists = character(0),
    outputs = "S_ATTRITION", per_cohort = TRUE,
    fn = "mod_attrition", blocked = NA_character_),

  periods = list(
    key = "periods", label = "Baseline, follow-up and treatment periods",
    needs = "cohorts", codelists = character(0),
    outputs = c("S_PERIODS", "S_LOT_PERIODS"), per_cohort = TRUE,
    fn = "mod_periods", blocked = NA_character_),

  demographics = list(
    key = "demographics", label = "Baseline demographics",
    needs = "periods", codelists = character(0),
    outputs = "S_DEMOGRAPHICS", per_cohort = TRUE,
    fn = "mod_demographics", blocked = NA_character_),

  comorbidity = list(
    key = "comorbidity", label = "Charlson and frailty",
    # The MM code list as well: Quan carries myeloma under `any_malignancy`
    # rather than as a condition of its own, so Table 4's MM adjustment can
    # only be made on the CODES.
    needs = "periods", codelists = c("charlson_quan2011.csv", "mm_dx.csv"),
    # The last two are written only when their switch is on, and are declared
    # anyway: a table the registry does not name is one nothing downstream
    # knows to look for.
    outputs = c("S_COMORBIDITY", "S_COMORB_SUBGROUP", "S_FRAILTY"),
    per_cohort = TRUE,
    fn = "mod_comorbidity", check = "check_charlson_list", blocked = NA_character_),

  soc = list(
    key = "soc", label = "SOC regimen categorisation",
    needs = "periods", codelists = "soc_regimen_categories.csv",
    outputs = "S_SOC", per_cohort = TRUE,
    fn = "mod_soc", check = "check_soc_list", blocked = NA_character_),

  safety = list(
    key = "safety", label = "Key safety events: prevalence and incidence",
    needs = "periods", codelists = "safety_events.csv",
    # S_SAFETY_COUNTED is the washout's own working set - the events that
    # survived the 30-day rule. Declared because a QC that cannot find it
    # cannot check the washout against the raw events.
    outputs = c("S_SAFETY_EVENTS", "S_SAFETY_COUNTED", "S_SAFETY_RATES"),
    per_cohort = TRUE,
    fn = "mod_safety", check = "check_safety_list", blocked = NA_character_),

  hcru = list(
    key = "hcru", label = "Hospitalisation, length of stay and ED visits",
    # The MM code list as well: the MM-related hospitalisation test reads it,
    # and a list a module loads without declaring is invisible to the preflight.
    needs = "periods", codelists = c("hcru.csv", "mm_dx.csv"),
    outputs = c("S_HCRU_EVENTS", "S_HCRU_RATES"), per_cohort = TRUE,
    fn = "mod_hcru", check = "check_hcru_list", blocked = NA_character_),

  malignancy = list(
    key = "malignancy", label = "Secondary malignancies",
    # S_MALIGNANCY_SEQUENCES is the treatment sequences of the patients with
    # a malignancy, in regimen categories, so it is written only where the
    # soc module ran - like the rate tables' regimen stratification, which
    # follows the same rule rather than a dependency.
    # mm_dx.csv is read to REFUSE, not to match: a secondary malignancy is
    # a malignancy other than the myeloma, so no code on the MM list may be
    # on this one.
    needs = "periods", codelists = c("secondary_malig.csv", "mm_dx.csv"),
    outputs = c("S_MALIGNANCY", "S_MALIGNANCY_DATES", "S_MALIGNANCY_RATES",
                "S_MALIGNANCY_SEQUENCES"),
    per_cohort = TRUE,
    fn = "mod_malignancy", check = "check_malignancy_list",
    blocked = NA_character_),

  tte = list(
    key = "tte", label = "TTNT, TTD and OS",
    needs = "periods", codelists = character(0),
    outputs = "S_TTE", per_cohort = TRUE,
    fn = "mod_tte", blocked = NA_character_),

  patterns = list(
    key = "patterns", label = "Treatment patterns, attrition and switching",
    needs = c("periods", "soc"), codelists = character(0),
    outputs = c("S_PATTERNS", "S_SWITCH", "S_TX_ATTRITION"),
    per_cohort = TRUE, fn = "mod_patterns", blocked = NA_character_),

  release = list(
    key = "release", label = "Small-cell suppression, applied",
    # Everything that produces a rate or a percentage.
    needs = c("safety", "hcru", "malignancy", "patterns"),
    codelists = character(0),
    outputs = paste0(names(SUPPRESSION_SPEC), "_RELEASE"),
    per_cohort = FALSE,
    fn = "mod_release", blocked = NA_character_)
)

# ---------------------------------------------------------------------------
# Selection
# ---------------------------------------------------------------------------

resolve_cohorts <- function(cfg) {
  want <- cfg$cohorts
  unknown <- setdiff(want, names(COHORTS))
  if (length(unknown))
    stop("SELECTION ERROR: COHORTS names ", paste(unknown, collapse = ", "),
         ". Known cohorts: ", paste(names(COHORTS), collapse = ", "), ".",
         call. = FALSE)
  if (!length(want))
    stop("SELECTION ERROR: COHORTS is empty.", call. = FALSE)

  out <- COHORTS[want]
  # A nested cohort cannot be built without the one it is drawn from: 2L is
  # "the subset of the 1L cohort", so a 2L run without 1L would be a different
  # population under the same name.
  #
  # ...but only while nesting is ON. Under COHORT_NESTED=FALSE each line stands
  # on its own index and 2L is NOT drawn from 1L, so requiring the parent would
  # refuse exactly the selection the setting exists to allow - a 2L-only run of
  # second-line initiators. The requirement follows the setting, or the setting
  # is one the code does not honour.
  if (isTRUE(cfg$cohort_nested)) for (co in out) {
    if (!is.na(co$nested_in) && !(co$nested_in %in% want))
      stop("SELECTION ERROR: cohort ", co$key, " is nested in ", co$nested_in,
           ", which is not selected. Add it to COHORTS, drop ", co$key,
           ", or set COHORT_NESTED=FALSE to build it on its own index",
           " - a nested cohort built without its parent is a different ",
           "population.", call. = FALSE)
  }
  # The one criterion that varies by setting rather than by cohort, and the one
  # place where dropping it from this list is not enough to make it true:
  # membership is an INNER JOIN onto INPUT_COHORT_TABLE, where the cohort build
  # already applied X2 and the 1L index floor. Removing the name here changes
  # the funnel and changes nothing about who is in the cohort.
  if ("SEC2L" %in% want && !isTRUE(cfg$sec2l_apply_other_cancer)) {
    if (!isTRUE(cfg$sec2l_input_is_wide))
      stop("SELECTION ERROR: the secondary 2L cohort cannot be built from ",
           "this input.\n",
           "s7.4.1.1 takes 2L initiators irrespective of whether their 1L fell ",
           "in the primary ascertainment period, and s7.8.1 permits a prior ",
           "malignancy. But every cohort here is an inner join onto ",
           "INPUT_COHORT_TABLE (", cfg$input_cohort_table, "), which is the ",
           "primary NDMM cohort with the other-cancer exclusion and the ",
           cfg$lot1_index_from, " index floor already applied - and the LOT ",
           "run was built over that same population. Built from it, SEC2L is ",
           "nested in the primary cohort and its baseline malignancy ",
           "prevalence is zero by construction, which is the one number the ",
           "cohort exists to produce.\n",
           "Either point INPUT_COHORT_TABLE at a cohort (and a LOT run) built ",
           "without those two rules and set SEC2L_INPUT_IS_WIDE=TRUE, or set ",
           "SEC2L_APPLY_OTHER_CANCER=TRUE to build the nested version ",
           "knowingly - the run then records that it did.\n",
           "See ../IE_CRITERIA.md section 1 and ../OPEN_QUESTIONS.md Q7.",
           call. = FALSE)
    out$SEC2L$criteria <- setdiff(out$SEC2L$criteria, "X2_other_cancer")
  }

  # Declaration order, which is 1L, 2L, 3L, SEC2L - parents before the cohorts
  # nested in them, so the attrition table reads top to bottom.
  out[order(match(names(out), names(COHORTS)))]
}

# Topological order over `needs`. A module asked for pulls in what it needs;
# a module in SKIP_MODULES that something selected needs is an error, not a
# silent inclusion, because the caller asked for two incompatible things.
resolve_modules <- function(cfg) {
  all_keys <- names(MODULES)
  want <- if (identical(tolower(cfg$modules), "all")) all_keys else cfg$modules
  unknown <- setdiff(c(want, cfg$skip_modules), all_keys)
  if (length(unknown))
    stop("SELECTION ERROR: unknown module(s) ",
         paste(unknown, collapse = ", "), ". Known: ",
         paste(all_keys, collapse = ", "), ".", call. = FALSE)

  want <- setdiff(want, cfg$skip_modules)
  if (!length(want))
    stop("SELECTION ERROR: no modules left after SKIP_MODULES.", call. = FALSE)

  # Pull in dependencies, then check none of them was skipped.
  closure <- character(0)
  frontier <- want
  while (length(frontier)) {
    k <- frontier[1]; frontier <- frontier[-1]
    if (k %in% closure) next
    closure <- c(closure, k)
    frontier <- c(frontier, MODULES[[k]]$needs)
  }
  pulled <- setdiff(closure, want)
  clash <- intersect(pulled, cfg$skip_modules)
  if (length(clash)) {
    # Name the modules that needed it, so the caller knows which of the two
    # asks to drop.
    needers <- Filter(function(w) length(intersect(MODULES[[w]]$needs, clash)) > 0L,
                      want)
    stop("SELECTION ERROR: ", paste(clash, collapse = ", "),
         " is in SKIP_MODULES but ", paste(needers, collapse = ", "),
         " needs it. Drop one or the other.", call. = FALSE)
  }
  if (length(pulled))
    message("[registry] pulled in ", paste(pulled, collapse = ", "),
            " to satisfy ", paste(want, collapse = ", "))

  # Kahn's algorithm over the closure, ties broken by declaration order so the
  # same selection always runs in the same order.
  ordered <- character(0)
  remaining <- closure[order(match(closure, all_keys))]
  while (length(remaining)) {
    ready <- remaining[vapply(remaining, function(k)
      all(MODULES[[k]]$needs %in% ordered), logical(1))]
    if (!length(ready))
      stop("SELECTION ERROR: the module graph has a cycle among ",
           paste(remaining, collapse = ", "), ".", call. = FALSE)
    ordered <- c(ordered, ready)
    remaining <- setdiff(remaining, ready)
  }
  apply_optional_features(MODULES[ordered], cfg)
}

# What a module does only when a switch asks for it: the code list it then
# needs, and the table it then writes. Declared here rather than in MODULES so
# a default run's preflight does not demand a list it will never read, and so
# the plan DRY_RUN prints names the tables that run will actually write.
OPTIONAL_FEATURES <- list(
  comorbidity = list(
    frailty = list(codelist = "frailty_kim2018.csv", output = "S_FRAILTY"),
    comorbid_subgroups = list(codelist = "comorbid_subgroups.csv",
                              output = "S_COMORB_SUBGROUP"))
)

# A code list a module needs under one reading of a setting and not under the
# other, with no output of its own turning on it - so not a switch, and not an
# OPTIONAL_FEATURES entry, which downstream readers take as "an output and the
# switch that asks for it".
#
# The diagnosis date Table 4 defines is "first medical claim for MM within the
# baseline period", which is a scan of the diagnosis table against the MM code
# list. Under the default reading the date is read off the cohort table and no
# list is needed - so the list is required only where it is read, and a run
# with no code list at all stays possible.
CONDITIONAL_CODELISTS <- list(
  periods = list(
    list(codelist = "mm_dx.csv",
         when = function(cfg) identical(cfg$dx_date_source, "baseline_first_claim")))
)

apply_optional_features <- function(mods, cfg) {
  for (k in intersect(names(OPTIONAL_FEATURES), names(mods))) {
    for (setting in names(OPTIONAL_FEATURES[[k]])) {
      f <- OPTIONAL_FEATURES[[k]][[setting]]
      if (isTRUE(cfg[[setting]]))
        mods[[k]]$codelists <- c(mods[[k]]$codelists, f$codelist)
      else
        mods[[k]]$outputs <- setdiff(mods[[k]]$outputs, f$output)
    }
  }
  for (k in intersect(names(CONDITIONAL_CODELISTS), names(mods)))
    for (f in CONDITIONAL_CODELISTS[[k]])
      if (isTRUE(f$when(cfg)))
        mods[[k]]$codelists <- unique(c(mods[[k]]$codelists, f$codelist))
  mods
}

# Does this cohort apply a criterion - its own, or one inherited from the
# cohort it is nested in? 2L and 3L declare only the criteria the protocol
# lists as ADDITIONAL for them, and the 1L exclusions reach them through
# nested_in, so `key %in% cohort$criteria` alone would conclude that 2L permits
# a prior malignancy.
#
# `cfg` because the inheriting half is a SETTING. Under COHORT_NESTED=FALSE
# there is no join to the parent cohort, so 2L is not its subset and the
# parent's exclusions do not reach it: MET_X2 is on a 2L row, but membership
# does not AND it, and the cohort genuinely holds patients with a prior
# malignancy. Read structurally this said otherwise, and the one caller uses
# the answer to decide whether a number is zero by construction.
#
# cfg omitted is the declaration-only reading, which is what a check of the
# registry itself wants.
cohort_applies <- function(cohort, key, cfg = NULL) {
  if (key %in% cohort$criteria) return(TRUE)
  if (!is.null(cfg) && !isTRUE(cfg$cohort_nested)) return(FALSE)
  parent <- cohort$nested_in
  seen <- character(0)
  while (!is.na(parent) && !(parent %in% seen)) {
    seen <- c(seen, parent)
    p <- COHORTS[[parent]]
    if (is.null(p)) return(FALSE)
    if (key %in% p$criteria) return(TRUE)
    parent <- p$nested_in
  }
  FALSE
}

# Everything the selected modules need from CODELIST_DIR, deduplicated.
required_codelists <- function(mods)
  sort(unique(unlist(lapply(mods, `[[`, "codelists"), use.names = FALSE)))

# A plan a person can read before anything is written. DRY_RUN prints this and
# stops.
describe_plan <- function(cfg, cohorts, mods) {
  lines <- c(
    "Study 223926 - run plan",
    sprintf("  cohorts : %s", paste(vapply(cohorts, `[[`, character(1), "label"),
                                    collapse = "; ")),
    sprintf("  modules : %s", paste(names(mods), collapse = " -> ")),
    if (length(attr(mods, "left_out")))
      sprintf("  left out: %s", paste(sprintf("%s (%s)", names(attr(mods, "left_out")),
                                              attr(mods, "left_out")), collapse = "; ")),
    sprintf("  period  : %s to %s (1L index from %s)",
            cfg$study_start, cfg$study_end, cfg$lot1_index_from),
    sprintf("  writes  : %s",
            paste(paste0(cfg$object_prefix,
                         unlist(lapply(mods, `[[`, "outputs"),
                                use.names = FALSE)), collapse = ", ")))
  cl <- required_codelists(mods)
  lines <- c(lines, sprintf("  codelists: %s",
    if (length(cl)) paste(cl, collapse = ", ") else "(none)"))
  c(lines, "  readings:", paste0("    ", open_question_readings(cfg)))
}
