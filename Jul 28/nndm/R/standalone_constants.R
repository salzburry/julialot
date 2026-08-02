# Names and settings for the MM-diagnosis, demographics and 1L-index steps.
# Kept apart from nndm_constants.R, which is held to a fixed line count.

# Views built by 00_mm_cohort.R. Leading underscore so they cannot collide
# with a table name.
NDMM_MM_DX_CODES       <- "_ndmm_mm_dx_codes"
NDMM_MM_CLAIM_HEADER   <- "_ndmm_mm_claim_header"
NDMM_MM_CONFINEMENT    <- "_ndmm_mm_confinement"
NDMM_MM_DX_EVENTS      <- "_ndmm_mm_dx_events"
NDMM_MM_QUALIFYING     <- "_ndmm_mm_qualifying"
NDMM_MEMBER_DEMO       <- "_ndmm_member_demo"
NDMM_DEATH_DT          <- "_ndmm_death_dt"
NDMM_BASE_COHORT       <- "_ndmm_base_cohort"

# Views built by 00b_lot1_index.R.
NDMM_BELANTAMAB_CODES  <- "_ndmm_belantamab_codes"
NDMM_BELANTAMAB_PATIDS <- "_ndmm_belantamab_patids"

# Two outpatient MM claims on different days within this many days confirm a
# diagnosis. 90 is the study's window. Other builds report 30/60/90 side by
# side as a sensitivity, but only one of those is a cohort.
NDMM_OUTPATIENT_WINDOW <- as.integer(Sys.getenv("OUTPATIENT_WINDOW", unset = "90"))

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

# Agents barred from setting the 1L index date, beyond belantamab. Empty by
# default: only belantamab is named as a later-line therapy, and adding a name
# here shrinks the cohort by a rule nobody has written down.
#
# NDMM_INDEX_AGENTS is written on every run for this decision - every agent
# that actually set an index date, and for how many patients. Read it after the
# first run and name any later-line-only agent here. Comma-separated, matched
# against CL_MED_ABBR as LIKE patterns, so a prefix works.
NDMM_INDEX_EXCLUDED_ABBRS <- Sys.getenv("NDMM_INDEX_EXCLUDED_ABBRS", unset = "")

# The same, by code instead of abbreviation, for when someone has the HCPCS or
# NDC and not the code list's naming. Comma-separated, either TYPE:CODE or a
# bare CODE that bars every type:
#
#   NDMM_INDEX_EXCLUDED_CODES=HCPCS:J9999,NDC:12345678901
#   NDMM_INDEX_EXCLUDED_CODES=J9999
#
# Punctuation is stripped and letters uppercased, the same way the code list is
# treated, so a hyphenated NDC works. Not padded to eleven - padding happens at
# the join, so a ten-digit entry still matches. A code matching no row of
# cl_mma_codelist.csv stops the run: barring it would do nothing while looking
# as though it did.
NDMM_INDEX_EXCLUDED_CODES <- Sys.getenv("NDMM_INDEX_EXCLUDED_CODES", unset = "")

# The "belantamab in any LOT" exclusion is not applied here. Lines do not exist
# until lot has run over this cohort, so anything here would be a claims proxy
# nobody could check - a patient dropped here never gets lines. It lives in
# lot/R/line_criteria.R instead, where LOT membership is known.
#
# NO_BELANTAMAB is still computed and still ships on the cohort table, over the
# whole study period, as a record of who carries a belantamab claim at all.
# Nothing filters on it.

NDMM_BELANTAMAB_TX        <- "_ndmm_belantamab_tx"

# The other disease states of the same conditions.
#
# nndm_constants.R lists the tumour groups the other-cancer rule must not
# exclude on. Three of them are the "not having achieved remission" state of a
# plasma-cell disorder, and the remaining states were left in the filter.
#
# other_malig.csv carries each of those three conditions in three states:
#
#   C9010 / C9011 / C9012  Plasma cell leukemia        not achieved / in remission / in relapse
#   C9020 / C9021 / C9022  Extramedullary plasmacytoma not achieved / in remission / in relapse
#   C9030 / C9031 / C9032  Solitary plasmacytoma       not achieved / in remission / in relapse
#
# Only the first of each three was overridden. So a patient was excluded for
# having another cancer because their plasma cell leukemia was in remission or
# in relapse, while an identical patient whose plasma cell leukemia had not
# achieved remission was kept. A disease state cannot make a plasma-cell
# disorder into a different cancer - relapse least of all.
#
# tumour_group in that file is one label per ICD code, not a grouping, so these
# really are separate groups to the rule that reads it.
#
# The default overrides all six. Set NDMM_MM_ADJACENT_STATES=exclude to keep
# them in the filter and compare.
#
# These are not required to exist - absence just means the code list stopped
# carrying the wording. NDMM_MM_ADJACENT_GROUPS records what was found.
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
ndmm_mm_adjacent_groups <- function() {
  switch(NDMM_MM_ADJACENT_STATES,
    override = c(NDMM_MM_ADJACENT_OVERRIDE, NDMM_MM_ADJACENT_STATE_LABELS),
    exclude  = NDMM_MM_ADJACENT_OVERRIDE,
    stop("NDMM_MM_ADJACENT_STATES='", NDMM_MM_ADJACENT_STATES,
         "' is not a setting. Use override or exclude; see ",
         "standalone_constants.R.", call. = FALSE))
}

# Views built by the index-agent profile.
NDMM_OTHER_MALIG_EVENTS   <- "_ndmm_other_malig_events"
NDMM_INDEX_TX             <- "_ndmm_index_tx"
NDMM_INDEX_INELIGIBLE     <- "_ndmm_index_ineligible"
