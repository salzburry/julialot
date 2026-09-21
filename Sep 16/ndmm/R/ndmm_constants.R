# Names, windows and code-list overrides for this cohort.

NDMM_ENROLL_SPANS        <- "_ndmm_enroll_spans"
NDMM_ENROLL_SPANS_STRICT <- "_ndmm_enroll_spans_strict"  # no-gap spans for the 3-mo FU CE
NDMM_LOT1_STARTS         <- "_ndmm_lot1_starts"
NDMM_MMA_CODELIST        <- "_ndmm_mma_codelist"
NDMM_THERAPY_PRE_LOT1    <- "_ndmm_therapy_pre_lot1"
NDMM_OTHER_MALIG_CODES   <- "_ndmm_other_malig_codes"
NDMM_MED_CLAIM_HEADER    <- "_ndmm_med_claim_header"
NDMM_CONFINEMENT         <- "_ndmm_confinement"
NDMM_OTHER_MALIG_PATIDS  <- "_ndmm_other_malig_patids"
NDMM_FLAGS_ALL           <- "_ndmm_flags_all"   # per-PATID filter flags (for attrition)
NDMM_PATIDS       <- "_ndmm_patids"
NDMM_PREG_CODES          <- "_ndmm_preg_codes"
NDMM_PREGNANCY_EVENTS    <- "_ndmm_pregnancy_events"
NDMM_PREGNANCY_PATIDS    <- "_ndmm_pregnancy_patids"
NDMM_STUDY_START         <- Sys.getenv("STUDY_START", unset = "2016-01-01")
# 12-mo CE/baseline before the 1L index date. Read from PRE_LOT1_DAYS, which
# is the name config.csv and cfg$pre_lot1_days both use: written as a literal
# here, a config.csv that set it moved cfg and left the SQL on 365, and the
# run stopped in check_constants() with nothing to do about it but edit this
# file.
NDMM_PRE_LOT1_DAYS       <- as.integer(Sys.getenv("PRE_LOT1_DAYS", unset = "365"))
# Days after the index date a no-gap span must cover for follow-up CE. 0 means
# the index date itself - one day. That is what the study team confirmed for
# this cohort; other cohorts use three months, so the window is named here
# rather than written into the SQL.
NDMM_FU_CE_DAYS          <- as.integer(Sys.getenv("FU_CE_DAYS", unset = "0"))

# Tumor groups that do not count as another cancer. These are the myeloma
# itself or its precursor - plasma cell leukemia, the plasmacytomas, monoclonal
# gammopathy. The exclusion is for a cancer distinct from the myeloma, so these
# should not trigger it.
#
# Matched on tumor_group, ignoring case and spacing. Only the "NOT HAVING
# ACHIEVED REMISSION" labels are here; the "in remission" variants stay in the
# filter until someone confirms them. build_ndmm_other_malig_codes() logs how
# many matched - fewer than this list means the stored wording differs, and
# that blocks the run review.
#
# Secondary malignant neoplasm of bone is deliberately absent: C79.51 is a
# metastatic cancer and excludes, even though myeloma bone disease is often
# coded that way. See DECISIONS.md #4.
NDMM_MM_ADJACENT_OVERRIDE <- c(
  "MONOCLONAL GAMMOPATHY",
  "SOLITARY PLASMACYTOMA NOT HAVING ACHIEVED REMISSION",
  "PLASMA CELL LEUKEMIA NOT HAVING ACHIEVED REMISSION",
  "EXTRAMEDULLARY PLASMACYTOMA NOT HAVING ACHIEVED REMISSION"
)

# Earliest date an eligible 1L treatment can count. Enforced in
# build_lot1_starts_ndmm(), so the view never returns a start before it.
#
# LOT1_FROM, which is the name config.csv uses and the name cfg$lot1_from
# reads. It used to be NDMM_LOT1_FROM - one setting under two names, where the
# config drove the contract check and the constant drove the query. Setting
# LOT1_FROM alone moved the config, left this at 2017-01-01, and stopped the
# run in check_constants() after check_contract() had passed; setting both was
# the documented answer, and nobody should have to know that. check_settings()
# refuses a leftover NDMM_LOT1_FROM rather than ignoring it.
NDMM_LOT1_FROM <- Sys.getenv("LOT1_FROM", unset = "2017-01-01")

# Raw CDM confinement table, which tells inpatient from outpatient in the
# other-cancer check. Set here because nothing else defines it.
NDMM_TBL_CONFINEMENT <- Sys.getenv("TBL_CONFINEMENT", unset = "confinement")

# Steroids dropped from the prior-therapy check. They are supportive care, so
# a steroid claim alone does not make someone previously treated.
NDMM_STEROID_ABBRS <- c("DEX","DEXA","DEXAMETHASONE","PRED","PREDNISONE")

# Settings the LOT config does not carry. Same env-var names as the cohort
# build uses, so exporting them once covers both.
NDMM_TBL_MEMBER_ENROLLMENT <- Sys.getenv("TBL_MEMBER_ENROLLMENT",
                                       unset = "member_enrollment")
NDMM_GAP_DAYS              <- as.integer(Sys.getenv("GAP_DAYS",
                                                  unset = "30"))
NDMM_FINAL_TABLE_NAME      <- Sys.getenv("FINAL_TABLE_NAME",
                                       unset = "ELIG_COH_FINAL")
