# Names, windows and code-list overrides for this cohort.

NDMM_OBS_PERIOD          <- "_ndmm_obs_period"   # first and last MDV record per patient
NDMM_LOT1_STARTS         <- "_ndmm_lot1_starts"
NDMM_MMA_CODELIST        <- "_ndmm_mma_codelist"
NDMM_MMA_RECEIPTS        <- "_ndmm_mma_receipts" # the code list resolved to receipt codes
NDMM_MM_TX               <- "_ndmm_mm_tx"        # every MM therapy act of a candidate
NDMM_THERAPY_PRE_LOT1    <- "_ndmm_therapy_pre_lot1"
NDMM_OTHER_MALIG_CODES   <- "_ndmm_other_malig_codes"
NDMM_OTHER_MALIG_PATIDS  <- "_ndmm_other_malig_patids"
NDMM_FLAGS_ALL           <- "_ndmm_flags_all"   # per-PATID filter flags (for attrition)
NDMM_PATIDS              <- "_ndmm_patids"
NDMM_PREG_CODES          <- "_ndmm_preg_codes"
NDMM_PREGNANCY_EVENTS    <- "_ndmm_pregnancy_events"
NDMM_PREGNANCY_PATIDS    <- "_ndmm_pregnancy_patids"
NDMM_STUDY_START         <- Sys.getenv("STUDY_START", unset = "2018-01-01")
# 12 months of lookback and baseline before the 1L index date. Read from
# PRE_LOT1_DAYS, the name config.csv and cfg$pre_lot1_days both use.
NDMM_PRE_LOT1_DAYS       <- as.integer(Sys.getenv("PRE_LOT1_DAYS", unset = "365"))
# Days after the index date the patient must still be observed at the
# hospital. 0 means the index date itself - one day - which the study team
# confirmed for the Optum cohort; other cohorts use three months.
NDMM_FU_CE_DAYS          <- as.integer(Sys.getenv("FU_CE_DAYS", unset = "0"))

# Tumor groups that do not count as another cancer. These are the myeloma
# itself or its precursor - plasma cell leukemia, the plasmacytomas, monoclonal
# gammopathy. The exclusion is for a cancer distinct from the myeloma, so these
# should not trigger it.
#
# Matched on tumor_group, ignoring case and spacing. other_malig.csv is
# re-authored in MDV codes for this build, and its tumor_group labels have to
# keep this English wording or the override matches nothing, which stops the
# run (build_ndmm_other_malig_codes()).
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

# Earliest date an eligible 1L treatment can count. LOT1_FROM, which is the
# name config.csv uses and the name cfg$lot1_from reads, so one setting moves
# both the contract check and the query.
NDMM_LOT1_FROM <- Sys.getenv("LOT1_FROM", unset = "2019-01-01")

# Steroids dropped from the prior-therapy check. They are supportive care, so
# a steroid claim alone does not make someone previously treated.
NDMM_STEROID_ABBRS <- c("DEX","DEXA","DEXAMETHASONE","PRED","PREDNISONE")
