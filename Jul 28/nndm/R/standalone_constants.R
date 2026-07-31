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
