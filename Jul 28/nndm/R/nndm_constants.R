# The NDMM cohort's own names, windows and code-list overrides.
#

# concurrently with 05_regimen_dashboard.R without clobbering its temp views.
NDMM_LOT_LONG_FILT       <- "_ndmm_lot_long"
# Persisted (work-schema) twin of NDMM_LOT_LONG_FILT. The temp view joins
# LOT_LONG to the NDMM cohort and is read ~20x downstream (KPIs, gallery,
# validation, modal map, and ~13x inside the LOT1-5 detail); materializing it
# once and repointing the view collapses those rejoins (same pattern as
# NDMM_FLAGS_ALL / LOT_LONG_AUG).
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
# Persisted (work-schema) twin of NDMM_FLAGS_ALL. The temp view above embeds
# every NDMM raw-claim scan (pregnancy / belantamab / prior-Tx / other-cancer)
# and is read many times downstream; materializing it once to this table and
# repointing the view collapses those repeated scans to a single computation.
NDMM_FLAGS_ALL_TBL       <- "NDMM_FLAGS_ALL"
NDMM_PATIDS       <- "_ndmm_patids"
NDMM_PREG_CODES          <- "_ndmm_preg_codes"
NDMM_PREGNANCY_PATIDS    <- "_ndmm_pregnancy_patids"
NDMM_STUDY_START         <- Sys.getenv("STUDY_START", unset = "2016-01-01")
NDMM_PRE_LOT1_DAYS       <- 365L  # 12-mo CE/baseline before 1L index date
# Days after the 1L index date that a no-gap span must cover for the follow-up
# CE. 0 is the index date itself - one day of CE - which is what the study team
# confirmed for the 1L cohort. The protocol text (Rev Round 2, S6.2.1.1) asks
# for three months instead, and the 2L/3L cohorts keep that, so the window is
# named here rather than written into the SQL.
NDMM_FU_CE_DAYS          <- 0L

# Tumor_group labels treated as NON-exclusionary for the NDMM
# other-cancer filter ONLY (NDMM scope). These are plasma-cell /
# MM-adjacent diseases - the index MM itself (plasma cell leukemia,
# solitary + extramedullary plasmacytoma), its precursor (monoclonal
# gammopathy / MGUS), and MM bone disease (secondary malignant neoplasm
# of bone). The another-cancer exclusion targets a cancer DISTINCT from
# the index MM, so flagging these as non-exclusionary keeps the NDMM
# filter aligned with that intent.
# Parent pipeline (step 22) and the shared other_malig.csv are NOT
# changed - this list only adds a flag column at NDMM codelist-load time.
#
# Matched case/whitespace-insensitively against the codelist's
# tumor_group column. Only the five "NOT HAVING ACHIEVED REMISSION"
# labels are listed; "in remission" variants are left in
# the filter pending confirmation (see README). build_ndmm_other_-
# malig_codes() logs how many of these actually matched the codelist;
# a match count < length(this) means the stored labels differ from the
# wording below and is a run-review blocker.
NDMM_MM_ADJACENT_OVERRIDE <- c(
  "MONOCLONAL GAMMOPATHY",
  "SECONDARY MALIGNANT NEOPLASM OF BONE",
  "SOLITARY PLASMACYTOMA NOT HAVING ACHIEVED REMISSION",
  "PLASMA CELL LEUKEMIA NOT HAVING ACHIEVED REMISSION",
  "EXTRAMEDULLARY PLASMACYTOMA NOT HAVING ACHIEVED REMISSION"
)

# LOT1 eligible treatment cutoff ("Received an eligible
# treatment for MM ... on or after 01 Jan 2017"). Hard-enforced in
# build_lot1_starts_ndmm() so the LOT1 view never returns pre-cutoff
# starts. Env-overridable for sensitivity runs (e.g. 2018-01-01).
# Independent of parent cfg$id_start which defaults to 2016-01-01.
NDMM_LOT1_FROM <- Sys.getenv("NDMM_LOT1_FROM", unset = "2017-01-01")

# Confinement table name (raw CDM) for the other-cancer pre-LOT1 IP
# classification. config_lot.R does not define this so NDMM sets it
# locally with the same env-var name the cohort pipeline uses.
NDMM_TBL_CONFINEMENT <- Sys.getenv("TBL_CONFINEMENT", unset = "confinement")

# Steroid MED_ABBR values to exclude from the "MM oncology therapy"
# pre-LOT1 check. Same tokens as 05_regimen_dashboard.R::STEROID_TOKENS so the
# NDMM exclusion stays consistent with the steroid-augmentation semantics.
# (Steroids are supportive care; the "MM oncology therapy" rule
# targets actual MM agents, not supportive care.)
NDMM_STEROID_ABBRS <- c("DEX","DEXA","DEXAMETHASONE","PRED","PREDNISONE")

# Cohort-pipeline knobs that 05_regimen_dashboard.R's config_lot.R does NOT
# define (the cohort pipeline uses config_prompts.R instead). Defaults
# mirror config_prompts.R:43,90,98 verbatim, with env-var overrides
# matching the same env-var names so a user who already exports
# TBL_MEMBER_ENROLLMENT / GAP_DAYS / FINAL_TABLE_NAME for the parent
# cohort run picks up the same values here.
NDMM_TBL_MEMBER_ENROLLMENT <- Sys.getenv("TBL_MEMBER_ENROLLMENT",
                                       unset = "member_enrollment")
NDMM_GAP_DAYS              <- as.integer(Sys.getenv("GAP_DAYS",
                                                  unset = "30"))
NDMM_FINAL_TABLE_NAME      <- Sys.getenv("FINAL_TABLE_NAME",
                                       unset = "ELIG_COH_FINAL")
