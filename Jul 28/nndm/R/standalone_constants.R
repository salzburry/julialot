# Names and settings for the steps that make this package standalone.
#
# nndm_constants.R is a port and is held to apr_30_2026 line for line, so
# nothing new goes in it. These are the views and values the MM-diagnosis,
# demographics and 1L-index steps need - none of which exist in that source,
# because there the cohort and the index date both arrived from other builds.

# Views built by 00_mm_cohort.R. Leading underscore, like the ported views, so
# they cannot collide with a table name.
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

# Two outpatient MM claims on separate days within this many days confirm a
# diagnosis. Protocol S6.2.1.1 fixes it at 90; the attrition spreadsheet writes
# it as "30/60/90" because the parent build reports all three as a sensitivity.
# Only one of them is a cohort, and this is the one the protocol names.
NDMM_OUTPATIENT_WINDOW <- as.integer(Sys.getenv("OUTPATIENT_WINDOW", unset = "90"))

# "Aged >=18 years at the time of MM diagnosis according to calendar year"
# (S6.2.1.1). Calendar year, so it is year(diagnosis) - YRDOB, not a birthday.
NDMM_MIN_AGE <- as.integer(Sys.getenv("MIN_AGE", unset = "18"))

# How belantamab is recognised on cl_mma_codelist.csv. MAP_STACKED carried a
# MAP_MED_TYPE and apr_30_2026 matched 'BEL%' against it; reading the code list
# directly, the same token is the medication abbreviation. This package cannot
# see the production CSV to confirm it, so build_ndmm_belantamab_codes() stops
# the run if it matches nothing rather than letting the exclusion the study
# turns on quietly do nothing.
NDMM_BELANTAMAB_ABBR <- Sys.getenv("NDMM_BELANTAMAB_ABBR", unset = "BEL%")

# Agents that may not set the 1L index date, beyond belantamab. S6.2.1.1 says
# the eligible treatments are "MM regimens commonly used in the first line
# setting, excluding those restricted to later LOTs (see exclusion criteria)" -
# and the exclusion criteria in S6.2.1.2 name one therapy, belantamab. So the
# protocol as written restricts nothing else, and this is empty by default:
# adding a name here shrinks the cohort by a rule the protocol does not state,
# and that has to be a study-team decision made against real data.
#
# NDMM_INDEX_AGENTS is written on every run for exactly that decision: it is
# every agent that actually set an index date, with how many patients it set
# one for. Read it after the first run and, if a later-line-only agent is in
# it, name it here - patterns are matched against CL_MED_ABBR the same way
# NDMM_BELANTAMAB_ABBR is, comma-separated.
NDMM_INDEX_EXCLUDED_ABBRS <- Sys.getenv("NDMM_INDEX_EXCLUDED_ABBRS", unset = "")

# The same thing by code rather than by abbreviation, for when the study team
# has the HCPCS or NDC to hand and not the code list's own naming. Entries are
# comma-separated, either TYPE:CODE or a bare CODE that bars every type:
#
#   NDMM_INDEX_EXCLUDED_CODES=HCPCS:J9999,NDC:12345678901
#   NDMM_INDEX_EXCLUDED_CODES=J9999
#
# Punctuation is stripped and letters uppercased - the same normalisation the
# code list itself gets, so a hyphenated NDC works. Stripped, not padded to
# eleven: the code list stores its codes stripped too and the padding happens
# at the join, so padding here would stop a ten-digit entry matching the
# ten-digit code someone typed. A code that matches no row of
# cl_mma_codelist.csv stops the run: it is not a therapy this build would have
# matched anyway, so barring it does nothing while reading as though it did.
NDMM_INDEX_EXCLUDED_CODES <- Sys.getenv("NDMM_INDEX_EXCLUDED_CODES", unset = "")

# What "in any LOT" is taken to mean for the belantamab exclusion (S6.2.1.2).
# Lines of therapy do not exist when this build runs - the LOT algorithm runs
# over the cohort it produces - so this is a claims proxy for LOT membership,
# and which proxy changes the count:
#
#   study_period  any belantamab claim in [STUDY_START, STUDY_END]. Lines are
#                 only ever built over the study period, so a claim outside it
#                 is in no LOT. This is the default.
#   from_index    on or after the patient's own 1L index. Lines are numbered
#                 from that date, so this is the strictest reading of "in any
#                 LOT" - and the narrowest, excluding fewest patients.
#
# Neither is LOT membership. Only running the LOT algorithm and checking which
# line a belantamab claim landed in is exact; see the README.
#
# apr_30_2026 bounded neither end but the upper one, so a claim from before the
# study period excluded the patient. That is wrong under any reading.
NDMM_BELANTAMAB_SCOPE <- Sys.getenv("NDMM_BELANTAMAB_SCOPE", unset = "study_period")

NDMM_BELANTAMAB_TX        <- "_ndmm_belantamab_tx"

# The remission halves of the MM-adjacent override.
#
# nndm_constants.R lists five tumour groups the other-cancer rule must not
# exclude on, because they are the index MM itself or its precursor rather than
# another cancer. Three of them are worded "NOT HAVING ACHIEVED REMISSION", and
# its own comment says the "in remission" variants "are left in the filter
# pending confirmation".
#
# Leaving them there is not neutral. It says a patient is excluded for having
# another cancer because their plasma cell leukemia is in remission, while an
# identical patient whose plasma cell leukemia is not in remission is kept.
# Remission cannot make a plasma-cell disorder more like a different cancer, so
# the default here overrides them too, and NDMM_MM_ADJACENT_REMISSION=exclude
# restores apr_30_2026's behaviour for anyone who wants to compare.
#
# Unlike the five, these are not required to exist: absence just means this
# code list does not carry the wording, and the override has nothing to
# override. NDMM_MM_ADJACENT_GROUPS records what was found either way.
NDMM_MM_ADJACENT_REMISSION <- Sys.getenv("NDMM_MM_ADJACENT_REMISSION",
                                         unset = "override")
NDMM_MM_ADJACENT_REMISSION_LABELS <- c(
  "SOLITARY PLASMACYTOMA IN REMISSION",
  "PLASMA CELL LEUKEMIA IN REMISSION",
  "EXTRAMEDULLARY PLASMACYTOMA IN REMISSION"
)

# Every tumour group the override applies to, given the setting. The ported
# step reads this instead of the constant, so the two lists stay in one place.
ndmm_mm_adjacent_groups <- function() {
  switch(NDMM_MM_ADJACENT_REMISSION,
    override = c(NDMM_MM_ADJACENT_OVERRIDE, NDMM_MM_ADJACENT_REMISSION_LABELS),
    exclude  = NDMM_MM_ADJACENT_OVERRIDE,
    stop("NDMM_MM_ADJACENT_REMISSION='", NDMM_MM_ADJACENT_REMISSION,
         "' is not a setting. Use override or exclude; see ",
         "standalone_constants.R.", call. = FALSE))
}

# Views built by the index-agent profile.
NDMM_INDEX_TX             <- "_ndmm_index_tx"
NDMM_INDEX_INELIGIBLE     <- "_ndmm_index_ineligible"
