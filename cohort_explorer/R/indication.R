# =============================================================================
# indication.R  --  indication packs: the single source of every disease-
# specific choice, so the SAME dashboard serves Multiple Myeloma, Ovarian,
# Prostate, NSCLC, ... without touching engine or UI code.
# -----------------------------------------------------------------------------
# A "pack" is a plain list describing one tumour type:
#   id, disease, short        identifiers + display names
#   header_title, header_sub  the app banner
#   superset_label            attrition superset label ("Superset (1L-treated MM)")
#   criteria                  the IE-criteria registry (see criteria_registry.R
#                             for the field contract)
#   cohorts                   default cohort definitions (Overall / NDMM / ...)
#   soc_1l, soc_later         standard-of-care / regimen category vocabularies
#   soc_later_probs           sampling weights for the synthetic later-line SOC
#   endpoints                 time-to-event endpoint dictionary
#   safety_events             baseline safety events (flag, count, label)
#   variable_labels           per-variable label overrides (disease wording)
#   soc_case_sql              the warehouse drug->category CASE expression
#
# Add a tumour type  ==  add a pack_<id>() builder + register it in
# INDICATION_PACKS(). Select at runtime with  INDICATION=<id>  (default "mm").
# =============================================================================

# ---- Multiple Myeloma (the reference pack; matches the original app 1:1) -----
pack_mm <- function() list(
  id = "mm", disease = "Multiple Myeloma", short = "MM",
  header_title = "Oncology Real-World Data Explorer Tool",
  header_sub = paste(" — Multiple Myeloma (Overall & NDMM) ·",
                     "flag-driven IE selection · NDMM study protocol"),
  superset_label = "Superset (1L-treated MM)",

  criteria = list(
    incl_qualifying_mm = list(
      id = "incl_qualifying_mm", label = "Qualifying MM diagnosis",
      desc = "1 inpatient or >=2 outpatient MM dx on separate days within 90d.",
      polarity = "incl", phase = "pre_lot", ui_category = "Clinical",
      type = "flag", keep_when = 1L),
    incl_eligible_1l_tx = list(
      id = "incl_eligible_1l_tx", label = "Eligible 1L treatment (>= 2017)",
      desc = "First eligible MM treatment on/after MM dx in the ID period.",
      polarity = "incl", phase = "pre_lot", ui_category = "Treatments",
      type = "flag", keep_when = 1L),
    incl_adult = list(
      id = "incl_adult", label = "Adult at index (age >= 18)",
      desc = "Age >= 18 years at index (calendar year of MM diagnosis).",
      polarity = "incl", phase = "pre_lot", ui_category = "Demographics",
      type = "flag", keep_when = 1L),
    incl_baseline_ce_6m = list(
      id = "incl_baseline_ce_6m", label = "Baseline CE >= 6 months",
      desc = "Continuous enrollment >=6m before index (Overall default).",
      polarity = "incl", phase = "pre_lot", ui_category = "Other",
      type = "flag", keep_when = 1L),
    incl_baseline_ce_12m = list(
      id = "incl_baseline_ce_12m", label = "Baseline CE >= 12 months",
      desc = "Continuous enrollment >=12m before 1L index (NDMM default).",
      polarity = "incl", phase = "pre_lot", ui_category = "Other",
      type = "flag", keep_when = 1L),
    incl_fu_ce_3m = list(
      id = "incl_fu_ce_3m", label = "Follow-up CE >= 3 months",
      desc = "CE >=3m during follow-up (or death), no gaps (NDMM).",
      polarity = "incl", phase = "post_lot1", ui_category = "Other",
      type = "flag", keep_when = 1L),
    incl_new_user = list(
      id = "incl_new_user", label = "No baseline MM agents (new user)",
      desc = "No MM agents during the baseline period.",
      polarity = "incl", phase = "pre_lot", ui_category = "Treatments",
      type = "flag", keep_when = 1L),
    incl_fu_mm_agents = list(
      id = "incl_fu_mm_agents", label = "Treated (>=1 MM agent in follow-up)",
      desc = "At least one MM treatment start exists (defines the LOT).",
      polarity = "incl", phase = "post_lot1", ui_category = "Treatments",
      type = "flag", keep_when = 1L),
    excl_prior_mm_tx = list(
      id = "excl_prior_mm_tx", label = "No prior MM therapy (12m baseline)",
      desc = "No MM oncology therapy in the 12m before 1L index.",
      polarity = "excl", phase = "post_lot1", ui_category = "Treatments",
      type = "flag", keep_when = 1L),
    excl_other_cancer = list(
      id = "excl_other_cancer", label = "No other cancer (12m baseline)",
      desc = "No other primary/metastatic malignancy in the 12m baseline.",
      polarity = "excl", phase = "post_lot1", ui_category = "Clinical",
      type = "flag", keep_when = 1L),
    excl_belantamab = list(
      id = "excl_belantamab", label = "No belantamab (any LOT)",
      desc = "No belantamab mafodotin (ADC) exposure in any LOT.",
      polarity = "excl", phase = "study_period", ui_category = "Treatments",
      type = "flag", keep_when = 1L),
    excl_pregnancy = list(
      id = "excl_pregnancy", label = "No pregnancy",
      desc = "No pregnancy/childbirth code during the study period.",
      polarity = "excl", phase = "study_period", ui_category = "Clinical",
      type = "flag", keep_when = 1L),
    flt_age = list(
      id = "flt_age", label = "Age at index",
      desc = "Restrict to an age-at-index range.",
      polarity = "incl", phase = "pre_lot", ui_category = "Demographics",
      type = "param", variable = "age_index", filter = "range", default = NULL),
    flt_gender = list(
      id = "flt_gender", label = "Gender",
      desc = "Restrict to selected gender(s).",
      polarity = "incl", phase = "pre_lot", ui_category = "Demographics",
      type = "param", variable = "gender", filter = "categorical", default = NULL),
    flt_region = list(
      id = "flt_region", label = "Region",
      desc = "Restrict to selected US census region(s).",
      polarity = "incl", phase = "pre_lot", ui_category = "Demographics",
      type = "param", variable = "region", filter = "categorical", default = NULL),
    flt_payer = list(
      id = "flt_payer", label = "Payer / product type",
      desc = "Restrict to selected insurance product type(s).",
      polarity = "incl", phase = "pre_lot", ui_category = "Other",
      type = "param", variable = "payer_type", filter = "categorical", default = NULL),
    flt_baseline_ce = list(
      id = "flt_baseline_ce", label = "Baseline CE (months)",
      desc = "Require at least this many months of baseline continuous enrollment.",
      polarity = "incl", phase = "pre_lot", ui_category = "Other",
      type = "param", variable = "baseline_ce_months", filter = "range", default = NULL),
    flt_followup_ce = list(
      id = "flt_followup_ce", label = "Follow-up CE (months)",
      desc = "Require at least this many months of follow-up enrollment.",
      polarity = "incl", phase = "post_lot1", ui_category = "Other",
      type = "param", variable = "followup_ce_months", filter = "range", default = NULL),
    flt_dx_year = list(
      id = "flt_dx_year", label = "Year of MM diagnosis",
      desc = "Restrict to a diagnosis-year window.",
      polarity = "incl", phase = "pre_lot", ui_category = "Other",
      type = "param", variable = "dx_year", filter = "range", default = NULL),
    flt_lot_init_year = list(
      id = "flt_lot_init_year", label = "Year of 1L initiation",
      desc = "Restrict to a 1L-initiation-year window.",
      polarity = "incl", phase = "pre_lot", ui_category = "Other",
      type = "param", variable = "lot_init_year", filter = "range", default = NULL),
    flt_soc = list(
      id = "flt_soc", label = "1L SOC regimen category",
      desc = "Restrict to selected 1L standard-of-care regimen group(s).",
      polarity = "incl", phase = "post_lot1", ui_category = "Treatments",
      type = "param", variable = "soc_category", filter = "categorical", default = NULL)
  ),

  cohorts = list(
    overall = list(
      id = "overall",
      label = "Overall (parent LOT cohort)",
      desc  = paste("Step-6 denominator: qualifying MM + adult + 6m baseline CE",
                    "+ treatment-naive + treated. NDMM-specific exclusions OFF."),
      active_flags = c("incl_qualifying_mm", "incl_adult",
                       "incl_baseline_ce_6m", "incl_new_user",
                       "incl_fu_mm_agents")),
    ndmm = list(
      id = "ndmm",
      label = "NDMM (1L newly-diagnosed)",
      desc  = paste("Overall + tightened CE (12m baseline, 3m strict follow-up)",
                    "+ eligible-1L-from-2017 + NDMM exclusions",
                    "(no prior MM tx / other cancer / belantamab / pregnancy)."),
      active_flags = c("incl_qualifying_mm", "incl_adult",
                       "incl_eligible_1l_tx",
                       "incl_baseline_ce_12m", "incl_fu_ce_3m",
                       "incl_new_user", "incl_fu_mm_agents",
                       "excl_prior_mm_tx", "excl_other_cancer",
                       "excl_belantamab", "excl_pregnancy"))
  ),

  soc_1l = c(
    "Quadruplet with anti-CD38 backbone",
    "Triplet with anti-CD38 backbone",
    "Other triplet (non-anti-CD38)",
    "Doublet", "Monotherapy", "Other"),
  soc_later = c(
    "Triplet with anti-CD38 backbone",
    "Other triplet (non-anti-CD38)",
    "Other novel agent (e.g. selinexor)",
    "CAR-T", "Bispecific (BCMA / non-BCMA)",
    "Doublet", "Monotherapy"),
  soc_later_probs = c(0.22, 0.16, 0.10, 0.10, 0.10, 0.18, 0.14),

  endpoints = list(
    OS   = list(time = "os_time",   event = "os_event",
                label = "Overall Survival — time to death (OS)", protocol = TRUE),
    TTD  = list(time = "ttd_time",  event = "ttd_event",
                label = "Time to Treatment Discontinuation (TTD)", protocol = TRUE),
    TTNT = list(time = "ttnt_time", event = "ttnt_event",
                label = "Time to Next Treatment (TTNT)", protocol = TRUE),
    Attrition = list(time = "dx_to_1l_months", event = NA,
                label = "Attrition — time from diagnosis to 1L", protocol = TRUE),
    PFS_exploratory = list(time = "pfs_time", event = "pfs_event",
                label = "PFS — EXPLORATORY (NOT a protocol endpoint; §6.9)",
                protocol = FALSE)
  ),

  safety_events = list(
    c("bl_hepatic",  "n_hepatic",    "Hepatic toxicity"),
    c("bl_renal",    "n_renal",      "Renal impairment"),
    c("bl_infection","n_infection",  "Serious infection"),
    c("bl_ocular",   "n_ocular",     "Ocular event"),
    c("bl_cv",       "n_cv",         "Cardiovascular condition"),
    c("bl_neuro",    "n_neuro",      "Neurologic condition")),

  variable_labels = list(
    dx_year      = "Year of first MM diagnosis",
    soc_category = "1L SOC regimen category",
    lot_soc      = "Current-line SOC regimen",
    ti_te_age    = "Transplant eligibility (age proxy)",
    ti_te_age_cci= "Transplant eligibility (age or CCI proxy)",
    bl_hepatic   = "Baseline hepatic toxicity",
    bl_renal     = "Baseline renal impairment",
    bl_infection = "Baseline serious infection",
    bl_ocular    = "Baseline ocular event",
    bl_cv        = "Baseline cardiovascular condition",
    bl_neuro     = "Baseline neurologic condition"),

  soc_case_sql = "
    CASE
      WHEN coalesce(LOT_CART_LOT_FLG,0)=1 THEN 'CAR-T'
      WHEN coalesce(LOT_ALLO_LOT_FLG,0)=1 THEN 'Transplant'
      WHEN coalesce(LOT_MED_CNT,0)>=4 AND coalesce(LOT_CLASS_ACD38,0)=1 THEN 'Quadruplet with anti-CD38 backbone'
      WHEN coalesce(LOT_MED_CNT,0)=3  AND coalesce(LOT_CLASS_ACD38,0)=1 THEN 'Triplet with anti-CD38 backbone'
      WHEN coalesce(LOT_MED_CNT,0)=3 THEN 'Other triplet (non-anti-CD38)'
      WHEN coalesce(LOT_MED_CNT,0)=2 THEN 'Doublet'
      WHEN coalesce(LOT_MED_CNT,0)=1 THEN 'Monotherapy'
      ELSE 'Other' END"
)

# ---- Stub packs (skeletons to fill in) --------------------------------------
# Each carries a minimal-but-valid IE registry + two cohorts so the app runs
# end-to-end on synthetic data for that tumour type. Replace the SOC categories,
# criteria wording, and soc_case_sql with the tumour's authoritative definitions
# before using real data. `.stub_criteria()` yields a disease-agnostic core set
# (adult / baseline CE / treated + the standard param filters).
.stub_criteria <- function(dx_label) c(
  list(
    incl_qualifying_dx = list(
      id = "incl_qualifying_dx", label = paste("Qualifying", dx_label, "diagnosis"),
      desc = paste("Confirmed", dx_label, "diagnosis in the identification period."),
      polarity = "incl", phase = "pre_lot", ui_category = "Clinical",
      type = "flag", keep_when = 1L),
    incl_adult = list(
      id = "incl_adult", label = "Adult at index (age >= 18)",
      desc = "Age >= 18 years at index.",
      polarity = "incl", phase = "pre_lot", ui_category = "Demographics",
      type = "flag", keep_when = 1L),
    incl_baseline_ce_6m = list(
      id = "incl_baseline_ce_6m", label = "Baseline CE >= 6 months",
      desc = "Continuous enrollment >=6m before index.",
      polarity = "incl", phase = "pre_lot", ui_category = "Other",
      type = "flag", keep_when = 1L),
    incl_baseline_ce_12m = list(
      id = "incl_baseline_ce_12m", label = "Baseline CE >= 12 months",
      desc = "Continuous enrollment >=12m before index.",
      polarity = "incl", phase = "pre_lot", ui_category = "Other",
      type = "flag", keep_when = 1L),
    incl_fu_ce_3m = list(
      id = "incl_fu_ce_3m", label = "Follow-up CE >= 3 months",
      desc = "CE >=3m during follow-up (or death), no gaps.",
      polarity = "incl", phase = "post_lot1", ui_category = "Other",
      type = "flag", keep_when = 1L),
    incl_new_user = list(
      id = "incl_new_user", label = "No baseline systemic therapy (new user)",
      desc = "No systemic anti-cancer therapy during the baseline period.",
      polarity = "incl", phase = "pre_lot", ui_category = "Treatments",
      type = "flag", keep_when = 1L),
    incl_fu_mm_agents = list(
      id = "incl_fu_mm_agents", label = "Treated (>=1 systemic agent in follow-up)",
      desc = "At least one systemic treatment start exists (defines the LOT).",
      polarity = "incl", phase = "post_lot1", ui_category = "Treatments",
      type = "flag", keep_when = 1L),
    excl_other_cancer = list(
      id = "excl_other_cancer", label = "No other cancer (12m baseline)",
      desc = "No other primary/metastatic malignancy in the 12m baseline.",
      polarity = "excl", phase = "post_lot1", ui_category = "Clinical",
      type = "flag", keep_when = 1L),
    excl_pregnancy = list(
      id = "excl_pregnancy", label = "No pregnancy",
      desc = "No pregnancy/childbirth code during the study period.",
      polarity = "excl", phase = "study_period", ui_category = "Clinical",
      type = "flag", keep_when = 1L)),
  # standard live filters (identical across tumours -- pure demographics/dates)
  list(
    flt_age = list(id = "flt_age", label = "Age at index",
      desc = "Restrict to an age-at-index range.",
      polarity = "incl", phase = "pre_lot", ui_category = "Demographics",
      type = "param", variable = "age_index", filter = "range", default = NULL),
    flt_gender = list(id = "flt_gender", label = "Gender",
      desc = "Restrict to selected gender(s).",
      polarity = "incl", phase = "pre_lot", ui_category = "Demographics",
      type = "param", variable = "gender", filter = "categorical", default = NULL),
    flt_region = list(id = "flt_region", label = "Region",
      desc = "Restrict to selected US census region(s).",
      polarity = "incl", phase = "pre_lot", ui_category = "Demographics",
      type = "param", variable = "region", filter = "categorical", default = NULL),
    flt_payer = list(id = "flt_payer", label = "Payer / product type",
      desc = "Restrict to selected insurance product type(s).",
      polarity = "incl", phase = "pre_lot", ui_category = "Other",
      type = "param", variable = "payer_type", filter = "categorical", default = NULL),
    flt_baseline_ce = list(id = "flt_baseline_ce", label = "Baseline CE (months)",
      desc = "Require at least this many months of baseline continuous enrollment.",
      polarity = "incl", phase = "pre_lot", ui_category = "Other",
      type = "param", variable = "baseline_ce_months", filter = "range", default = NULL),
    flt_followup_ce = list(id = "flt_followup_ce", label = "Follow-up CE (months)",
      desc = "Require at least this many months of follow-up enrollment.",
      polarity = "incl", phase = "post_lot1", ui_category = "Other",
      type = "param", variable = "followup_ce_months", filter = "range", default = NULL),
    flt_dx_year = list(id = "flt_dx_year", label = "Year of diagnosis",
      desc = "Restrict to a diagnosis-year window.",
      polarity = "incl", phase = "pre_lot", ui_category = "Other",
      type = "param", variable = "dx_year", filter = "range", default = NULL),
    flt_lot_init_year = list(id = "flt_lot_init_year", label = "Year of 1L initiation",
      desc = "Restrict to a 1L-initiation-year window.",
      polarity = "incl", phase = "pre_lot", ui_category = "Other",
      type = "param", variable = "lot_init_year", filter = "range", default = NULL),
    flt_soc = list(id = "flt_soc", label = "1L regimen category",
      desc = "Restrict to selected 1L regimen group(s).",
      polarity = "incl", phase = "post_lot1", ui_category = "Treatments",
      type = "param", variable = "soc_category", filter = "categorical", default = NULL)))

.stub_cohorts <- function() list(
  overall = list(id = "overall", label = "Overall (parent LOT cohort)",
    desc = "Adult + 6m baseline CE + treatment-naive + treated.",
    active_flags = c("incl_qualifying_dx", "incl_adult",
                     "incl_baseline_ce_6m", "incl_new_user", "incl_fu_mm_agents")),
  newdx = list(id = "newdx", label = "Newly diagnosed (1L)",
    desc = "Overall + 12m baseline CE + 3m follow-up + no other cancer.",
    active_flags = c("incl_qualifying_dx", "incl_adult",
                     "incl_baseline_ce_12m", "incl_fu_ce_3m",
                     "incl_new_user", "incl_fu_mm_agents", "excl_other_cancer")))

.stub_endpoints <- function() list(
  OS   = list(time = "os_time",   event = "os_event",
              label = "Overall Survival — time to death (OS)", protocol = TRUE),
  TTD  = list(time = "ttd_time",  event = "ttd_event",
              label = "Time to Treatment Discontinuation (TTD)", protocol = TRUE),
  TTNT = list(time = "ttnt_time", event = "ttnt_event",
              label = "Time to Next Treatment (TTNT)", protocol = TRUE),
  Attrition = list(time = "dx_to_1l_months", event = NA,
              label = "Attrition — time from diagnosis to 1L", protocol = TRUE),
  PFS_exploratory = list(time = "pfs_time", event = "pfs_event",
              label = "PFS — EXPLORATORY (verify ascertainment)", protocol = FALSE))

.stub_safety <- function() list(
  c("bl_hepatic",  "n_hepatic",    "Hepatic toxicity"),
  c("bl_renal",    "n_renal",      "Renal impairment"),
  c("bl_infection","n_infection",  "Serious infection"),
  c("bl_ocular",   "n_ocular",     "Ocular event"),
  c("bl_cv",       "n_cv",         "Cardiovascular condition"),
  c("bl_neuro",    "n_neuro",      "Neurologic condition"))

# Generic class/count -> category SQL (no tumour-specific backbone flags). Swap
# in the authoritative regimen map before real use.
.stub_soc_case_sql <- "
    CASE
      WHEN coalesce(LOT_CART_LOT_FLG,0)=1 THEN 'Cellular therapy'
      WHEN coalesce(LOT_ALLO_LOT_FLG,0)=1 THEN 'Transplant'
      WHEN coalesce(LOT_MED_CNT,0)>=3 THEN 'Triplet+'
      WHEN coalesce(LOT_MED_CNT,0)=2 THEN 'Doublet'
      WHEN coalesce(LOT_MED_CNT,0)=1 THEN 'Monotherapy'
      ELSE 'Other' END"

.make_stub_pack <- function(id, disease, short, soc_1l, soc_later) list(
  id = id, disease = disease, short = short,
  header_title = "Oncology Real-World Data Explorer Tool",
  header_sub = paste0(" — ", disease, " (", short,
                      ") · flag-driven IE selection · template pack (verify SOC & criteria)"),
  superset_label = paste0("Superset (1L-treated ", short, ")"),
  criteria = .stub_criteria(short),
  cohorts  = .stub_cohorts(),
  soc_1l = soc_1l, soc_later = soc_later,
  soc_later_probs = rep(1, length(soc_later)) / length(soc_later),
  endpoints = .stub_endpoints(),
  safety_events = .stub_safety(),
  variable_labels = list(
    dx_year = paste("Year of first", short, "diagnosis"),
    soc_category = "1L regimen category",
    lot_soc = "Current-line regimen"),
  soc_case_sql = .stub_soc_case_sql,
  is_stub = TRUE)

# Template packs for the oncology tumour areas served here. SOC categories use
# CLASS-based labels (public standard-of-care), not brand assets. The IE criteria
# are the generic .stub_criteria() core -- replace with each tumour's authoritative
# study definition (and the drug->category SOC map) before running real data.

# Endometrial cancer -- gynae-oncology core (checkpoint + PARP combination era)
pack_ec <- function() .make_stub_pack(
  "ec", "Endometrial Cancer", "EC",
  soc_1l = c("Chemo + immunotherapy", "Platinum doublet (carbo-paclitaxel)",
             "Single-agent chemotherapy", "Hormonal therapy", "Other"),
  soc_later = c("Immunotherapy (anti-PD-1)", "TKI + immunotherapy",
                "PARP maintenance", "Single-agent chemotherapy",
                "Hormonal therapy", "Other"))

# Ovarian cancer -- platinum + PARP-maintenance (HRD) landscape
pack_oc <- function() .make_stub_pack(
  "oc", "Ovarian Cancer", "OC",
  soc_1l = c("Platinum doublet + anti-VEGF", "Platinum doublet + PARP maintenance",
             "Platinum doublet", "PARP maintenance (HRD)", "Other"),
  soc_later = c("Platinum rechallenge", "PARP inhibitor", "Anti-VEGF-based",
                "Non-platinum chemotherapy", "Other"))

# Colorectal cancer -- incl. immunotherapy for dMMR/MSI-H
pack_crc <- function() .make_stub_pack(
  "crc", "Colorectal Cancer", "CRC",
  soc_1l = c("Doublet + anti-VEGF", "Doublet + anti-EGFR (RAS-wt)",
             "Immunotherapy (dMMR/MSI-H)", "Chemotherapy doublet", "Other"),
  soc_later = c("Anti-VEGF continuation", "Anti-EGFR", "Oral fluoropyrimidine",
                "Multikinase inhibitor", "Immunotherapy", "Other"))

# Head & neck squamous cell carcinoma
pack_hnscc <- function() .make_stub_pack(
  "hnscc", "Head & Neck SCC", "HNSCC",
  soc_1l = c("Platinum + 5-FU + immunotherapy", "Immunotherapy monotherapy",
             "Platinum + anti-EGFR", "Single-agent chemotherapy", "Other"),
  soc_later = c("Immunotherapy (anti-PD-1)", "Taxane", "Anti-EGFR-based",
                "Methotrexate", "Other"))

# Non-small cell lung cancer
pack_nsclc <- function() .make_stub_pack(
  "nsclc", "Non-Small Cell Lung Cancer", "NSCLC",
  soc_1l = c("Chemo + immunotherapy", "Immunotherapy monotherapy",
             "Targeted therapy (EGFR/ALK/ROS1)", "Platinum doublet", "Other"),
  soc_later = c("Immunotherapy", "Docetaxel +/- anti-VEGF",
                "Next-line targeted therapy", "Platinum doublet", "Other"))

# Small cell lung cancer (extensive stage)
pack_sclc <- function() .make_stub_pack(
  "sclc", "Small Cell Lung Cancer", "SCLC",
  soc_1l = c("Platinum-etoposide + immunotherapy", "Platinum-etoposide", "Other"),
  soc_later = c("Topoisomerase inhibitor", "Second-line chemotherapy",
                "Immunotherapy", "Platinum rechallenge", "Other"))

# ---- pack registry + active-pack accessor -----------------------------------
INDICATION_PACKS <- function()
  list(mm = pack_mm, ec = pack_ec, oc = pack_oc, crc = pack_crc,
       hnscc = pack_hnscc, nsclc = pack_nsclc, sclc = pack_sclc)

# selected tumour type: INDICATION env var (or option), default "mm". An env var
# that is set-but-empty is treated as unset (falls through to the option/default).
active_indication_id <- function() {
  id <- Sys.getenv("INDICATION", "")
  if (!nzchar(id)) id <- getOption("cohort_explorer.indication", "mm")
  id <- tolower(id)
  if (!nzchar(id)) "mm" else id
}

.pack_cache <- new.env(parent = emptyenv())
active_pack <- function(id = active_indication_id()) {
  if (is.null(.pack_cache[[id]])) {
    builders <- INDICATION_PACKS()
    if (is.null(builders[[id]]))
      stop("unknown INDICATION '", id, "' (have: ",
           paste(names(builders), collapse = ", "), ")", call. = FALSE)
    .pack_cache[[id]] <- builders[[id]]()
  }
  .pack_cache[[id]]
}

# small accessor used by the warehouse scripts (no app context needed)
indication_soc_case_sql <- function(id = active_indication_id()) active_pack(id)$soc_case_sql
