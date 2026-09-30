# Names and settings for the MM-diagnosis, demographics and 1L-index steps.
# Kept apart from ndmm_constants.R, which is held to a fixed line count.

# Views built by 00_mm_cohort.R. Leading underscore so they cannot collide
# with a table name.
NDMM_DX                <- "_ndmm_dx"          # MDV diagnoses, staged (R/mdv_source.R)
NDMM_FF1               <- "_ndmm_ff1"         # MDV DPC Form 1 episodes, staged
NDMM_MM_DX_CODES       <- "_ndmm_mm_dx_codes"
NDMM_MM_DX_EVENTS      <- "_ndmm_mm_dx_events"
NDMM_MM_QUALIFYING     <- "_ndmm_mm_qualifying"
NDMM_MEMBER_DEMO       <- "_ndmm_member_demo"
NDMM_DEATH_DT          <- "_ndmm_death_dt"
NDMM_BASE_COHORT       <- "_ndmm_base_cohort"

# Views built by 00b_lot1_index.R.
NDMM_BELANTAMAB_CODES  <- "_ndmm_belantamab_codes"
NDMM_BELANTAMAB_PATIDS <- "_ndmm_belantamab_patids"

# Views built by 08_clintrial.R. A descriptive flag on its own table, kept off
# NDMM_FLAGS_ALL so nothing reads it as a criterion.
NDMM_CLINTRIAL_CODES   <- "_ndmm_clintrial_codes"
NDMM_CLINTRIAL_FLAGS   <- "_ndmm_clintrial_flags"

# Two outpatient MM diagnoses in different claim months at most this many
# months apart confirm a diagnosis. The Optum rule is two claims on different
# days within 90 days; MDV dates a diagnosis only to its claim month, so
# "different days" becomes "different months" and 90 days becomes 3 months.
# Counted in calendar months, not in days over 30.44: February 1 to March 1 is
# 28 days, which the OC rules' gap_months = days / 30.44 >= 1 reads as less
# than a month apart. DECISIONS.md, "MDV".
NDMM_OUTPATIENT_WINDOW_MONTHS <- as.integer(Sys.getenv("OUTPATIENT_WINDOW_MONTHS", unset = "3"))

# The other-cancer rule's two outpatient claims within 30 days, the same way:
# two claim months at most this many months apart, so adjacent months.
NDMM_OTHER_MALIG_WINDOW_MONTHS <- as.integer(Sys.getenv("OTHER_MALIG_WINDOW_MONTHS", unset = "1"))

# What makes an MDV diagnosis an inpatient one for criterion 1.
#
#   none       nyugaikbn is the inpatient value. The Optum rule's inpatient
#              claim line, translated. (default)
#   ff1        and the record's fromdate falls inside one of the patient's
#              DPC Form 1 episodes - the OC rules' FF1 alignment.
#   ff1_chemo  and that episode is a first cancer (cancerfirstflg) given
#              chemotherapy (chemotherapyflg) - the OC rules' whole inpatient
#              rule.
#
# The default translates the study's rule; the other two are the OC rules'
# refinements, and NDMM_MM_DX_RULES prices all three on every run.
NDMM_MDV_IP_RULE <- Sys.getenv("NDMM_MDV_IP_RULE", unset = "none")
NDMM_MDV_IP_RULES <- c("none", "ff1", "ff1_chemo")

# Whether an MM or other-cancer diagnosis must carry MDV's cancer flag. The OC
# rules require it of their cancer; a myeloma code without it is either a
# coding slip or a record MDV itself did not class as cancer.
NDMM_MDV_REQUIRE_CANCERFLG <- toupper(trimws(Sys.getenv("NDMM_MDV_REQUIRE_CANCERFLG",
                                                        unset = "TRUE"))) == "TRUE"

# Minimum age at diagnosis. Calendar year, so year(diagnosis) - YRDOB, not a
# birthday.
NDMM_MIN_AGE <- as.integer(Sys.getenv("MIN_AGE", unset = "18"))

# How belantamab is spelled in cl_mma_codelist.csv - a whole CL_MED_ABBR,
# matched exactly. lot matches the same drug the same way, so the two packages
# cannot disagree on a code list carrying more than one BEL* abbreviation.
#
# Nothing here can see the real CSV, so build_ndmm_belantamab_codes() stops the
# run if this matches nothing, and also if the list carries another BEL*
# abbreviation this does not name.
NDMM_BELANTAMAB_ABBR <- Sys.getenv("NDMM_BELANTAMAB_ABBR", unset = "BELA")

# Agents barred from setting the 1L index date, beyond belantamab. Protocol
# I3 names panobinostat and elotuzumab as later-line agents, so the contract
# pins PANO|ELOT: a different value is a different cohort and needs
# NDMM_CONTRACT_OVERRIDE. Each entry must match the production code list's
# CL_MED_ABBR, or build_ndmm_index_ineligible_codes() stops the run.
#
# NDMM_INDEX_AGENTS is written on every run for this decision - every agent
# that actually set an index date, and for how many patients. Separated by |,
# matched against CL_MED_ABBR as LIKE patterns, so a prefix works.
NDMM_INDEX_EXCLUDED_ABBRS <- Sys.getenv("NDMM_INDEX_EXCLUDED_ABBRS", unset = "PANO|ELOT")

# The same, by receipt code instead of abbreviation, for when someone has the
# code and not the code list's naming. Separated by |, either
# RECEIPTCODE:CODE or a bare CODE:
#
#   NDMM_INDEX_EXCLUDED_CODES=RECEIPTCODE:622222222
#   NDMM_INDEX_EXCLUDED_CODES=622222222
#
# Matched against the receipt codes the code list resolves to, so it bars a
# code that a NAME_ENG pattern brought in as well as one listed outright. A
# code matching none of them stops the run: barring it would do nothing while
# looking as though it did.
NDMM_INDEX_EXCLUDED_CODES <- Sys.getenv("NDMM_INDEX_EXCLUDED_CODES", unset = "")

# The "belantamab in any LOT" exclusion is not applied here. Lines do not exist
# until lot has run over this cohort, so anything here would be a claims proxy
# nobody could check - a patient dropped here never gets lines. It lives in
# lot/engine/R/line_criteria.R instead, where LOT membership is known.
#
# NO_BELANTAMAB is still computed and still carried on the cohort table, over the
# whole study period, as a record of who carries a belantamab claim at all.
# Nothing filters on it.

NDMM_BELANTAMAB_TX        <- "_ndmm_belantamab_tx"

# The other disease states of the same conditions.
#
# ndmm_constants.R lists the tumour groups the other-cancer rule must not
# exclude on. Three of them are the "not having achieved remission" state of a
# plasma-cell disorder, and the other states were left in the filter:
#
#   C9010 / C9011 / C9012  Plasma cell leukemia        not achieved / remission / relapse
#   C9020 / C9021 / C9022  Extramedullary plasmacytoma not achieved / remission / relapse
#   C9030 / C9031 / C9032  Solitary plasmacytoma       not achieved / remission / relapse
#
# Only the first of each three was overridden, so a patient was excluded for
# another cancer because their plasma cell leukemia was in remission, while an
# identical patient whose leukemia had not achieved remission was kept. A
# disease state cannot make a plasma-cell disorder into a different cancer.
#
# tumour_group is one label per ICD code, not a grouping, so to the rule that
# reads it these really are separate groups.
#
# The default overrides all six. NDMM_MM_ADJACENT_STATES=exclude keeps them in
# the filter. None is required to exist - absence means the code list stopped
# carrying the wording, and NDMM_MM_ADJACENT_GROUPS records what was found.
NDMM_MM_ADJACENT_STATES <- Sys.getenv("NDMM_MM_ADJACENT_STATES", unset = "override")
NDMM_MM_ADJACENT_STATE_LABELS <- c(
  "PLASMA CELL LEUKEMIA IN REMISSION",
  "PLASMA CELL LEUKEMIA IN RELAPSE",
  "EXTRAMEDULLARY PLASMACYTOMA IN REMISSION",
  "EXTRAMEDULLARY PLASMACYTOMA IN RELAPSE",
  "SOLITARY PLASMACYTOMA IN REMISSION",
  "SOLITARY PLASMACYTOMA IN RELAPSE"
)

# Every tumour group the override covers. The step reads this rather than the
# constant, so both lists stay in one place.
#
# Four settings, not two, because the question underneath them is not the
# remission states. All nine plasma-cell labels are C90 - the block for
# multiple myeloma and malignant plasma cell neoplasms - and the fourth digit
# is the disease state, not the disease. Monoclonal gammopathy is separate:
# D47.2 is "uncertain behaviour", not a malignancy, so the criterion does not
# reach it whatever anyone decides about the C90 codes.
#
#   override   the nine C90 labels and MGUS      (default)
#   exclude    the three C90 "not in remission" labels and MGUS
#   mgus_only  MGUS alone - every C90 code excludes
#   none       nothing; only codes on mm_dx.csv are kept
ndmm_mm_adjacent_groups <- function() {
  switch(NDMM_MM_ADJACENT_STATES,
    override  = c(NDMM_MM_ADJACENT_OVERRIDE, NDMM_MM_ADJACENT_STATE_LABELS),
    exclude   = NDMM_MM_ADJACENT_OVERRIDE,
    mgus_only = grep("GAMMOPATHY", NDMM_MM_ADJACENT_OVERRIDE, value = TRUE),
    none      = character(0),
    stop("NDMM_MM_ADJACENT_STATES='", NDMM_MM_ADJACENT_STATES,
         "' is not a setting. Use override, exclude, mgus_only or none; see ",
         "standalone_constants.R.", call. = FALSE))
}

# Views built by the index-agent profile.
NDMM_OTHER_MALIG_EVENTS   <- "_ndmm_other_malig_events"
NDMM_INDEX_TX             <- "_ndmm_index_tx"
NDMM_INDEX_INELIGIBLE     <- "_ndmm_index_ineligible"

# Metastatic (secondary) neoplasm codes, matched as prefixes on the
# punctuation-stripped ICD-10 code - so "C78" covers C78.00 and C78.7. MDV
# codes are ICD-10 only; an MDV disease code is grouped by the ICD-10 code
# other_malig.csv maps it to.
#
# One group rather than pairing by ICD category: two outpatient claims for
# metastases at different sites are still metastatic cancer, and pairing them
# on site would ask for the same metastasis twice. Primaries keep the category
# rule.
#
# C80.0 is disseminated disease and is here. C80.1 and C80.2 are not secondary,
# so the prefix is C800 rather than C80 - the same reason 1990 is listed
# rather than 199.
#
# Only codes already on other_malig.csv are affected: this regroups what the
# exclusion reads and adds nothing. build_ndmm_other_malig_codes() reports
# which prefixes matched, so one that matches nothing is visible.
NDMM_METASTATIC_PREFIXES <- c(
  # Lymph nodes; respiratory and digestive; other and unspecified sites;
  # secondary neuroendocrine; disseminated.
  "C77", "C78", "C79", "C7B", "C800"
)

# The SQL predicate for the above, over a column holding a stripped code.
ndmm_metastatic_sql <- function(col = "om.icd10") {
  paste(sprintf("%s LIKE '%s%%'", col, NDMM_METASTATIC_PREFIXES), collapse = "\n             OR ")
}

# The same codes grouped by the prefix each one matched, rather than collapsed
# into MET. This is the counterfactual the review table needs: plain
# substr(dx, 1, 3) is not, because C800 would fall back to C80 and rejoin
# C80.1 and C80.2 - codes deliberately kept out of the metastatic group. The
# difference would then net a pair the collapse adds against a pair it removes,
# and report the two as one number.
ndmm_metastatic_own_group_sql <- function(col = "om.icd10") {
  arms <- sprintf("WHEN %s LIKE '%s%%' THEN '%s'", col,
                  NDMM_METASTATIC_PREFIXES, NDMM_METASTATIC_PREFIXES)
  paste0("CASE ", paste(arms, collapse = "\n                "),
         "\n                ELSE substr(", col, ", 1, 3) END")
}

# How many codes the metastatic group actually claimed. A prefix that matches
# nothing is doing nothing, and saying so is cheaper than finding out from a
# count that did not move.
report_metastatic_group <- function(con) {
  n <- tryCatch(db_q(con, glue("
    SELECT count(*) AS n FROM {NDMM_OTHER_MALIG_CODES}
    WHERE primary_group = 'MET'"))$n, error = function(e) NA_integer_)
  if (is.na(n)) {
    log_msg("  Metastatic group: could not be counted.")
    return(invisible(NA_integer_))
  }
  log_msg("  Metastatic group: ", format(n, big.mark = ","),
          " code(s) on the list, from ", length(NDMM_METASTATIC_PREFIXES),
          " prefixes")
  # Per prefix, so a tier that matches nothing is named and one doing all the
  # work is visible. "How many matched" cannot say which.
  per <- tryCatch(db_q(con, glue("
    SELECT met_prefix AS P, count(*) AS n FROM {NDMM_OTHER_MALIG_CODES}
    WHERE primary_group = 'MET' GROUP BY 1")), error = function(e) NULL)
  hit <- if (is.null(per)) character(0) else as.character(per$P)
  for (px in NDMM_METASTATIC_PREFIXES) {
    i <- match(px, hit)
    log_msg("    ", px, ": ", if (is.na(i)) "no codes on the list"
                              else format(per$n[i], big.mark = ","))
  }
  if (n == 0L)
    log_msg("  WARNING: no code on other_malig.csv matches any prefix in ",
            "NDMM_METASTATIC_PREFIXES, so every code pairs by ICD category ",
            "and the metastatic group does nothing.")
  invisible(n)
}
