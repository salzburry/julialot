# Names, windows and code-list overrides for this cohort.

NDMM_LOT_LONG_FILT       <- "_ndmm_lot_long"
# Table behind the view above. The view joins LOT_LONG to the cohort and is
# read many times, so build it once and point the view at it.
NDMM_LOT_LONG_FILT_TBL   <- "NDMM_LOT_LONG_FILT"
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
# Table behind the view above. The view holds every raw-claim scan - pregnancy,
# belantamab, prior therapy, other cancer - and is read many times. Build it
# once and point the view at it.
NDMM_FLAGS_ALL_TBL       <- "NDMM_FLAGS_ALL"
NDMM_PATIDS       <- "_ndmm_patids"
NDMM_PREG_CODES          <- "_ndmm_preg_codes"
NDMM_PREGNANCY_PATIDS    <- "_ndmm_pregnancy_patids"
NDMM_STUDY_START         <- Sys.getenv("STUDY_START", unset = "2016-01-01")
NDMM_PRE_LOT1_DAYS       <- 365L  # 12-mo CE/baseline before 1L index date
# Days after the index date a no-gap span must cover for follow-up CE. 0 means
# the index date itself - one day. That is what the study team confirmed for
# this cohort; other cohorts use three months, so the window is named here
# rather than written into the SQL.
NDMM_FU_CE_DAYS          <- 0L

# Tumor groups that do NOT count as another cancer. These are the myeloma
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
# Override for sensitivity runs.
NDMM_LOT1_FROM <- Sys.getenv("NDMM_LOT1_FROM", unset = "2017-01-01")

# Raw CDM confinement table, used to tell inpatient from outpatient in the
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
