# A scenario set with no warehouse and no files, so the App can be deployed and
# clicked through before any run exists.
#
# Every number here is MADE UP. The dashboard says so on every page it draws
# from this source, and DASH_ALLOW_SYNTHETIC=FALSE refuses to start on it at
# all - a deployment meant to show the study's numbers must not quietly show
# these instead.
#
# The shapes are real: the columns are the package's own DDL, and the scenarios
# differ on the open questions that actually move numbers, so the comparison
# view can be exercised.

SYNTH_SCENARIOS <- list(
  s223926_ = list(
    mm_hosp_position = "confinement", claim_status = "paid_only",
    months_as = "days", censor_at_disenrollment = "TRUE"),
  s223926_q27_ = list(
    mm_hosp_position = "claim_positions", claim_status = "paid_only",
    months_as = "days", censor_at_disenrollment = "TRUE"),
  s223926_q25_ = list(
    mm_hosp_position = "confinement", claim_status = "all",
    months_as = "days", censor_at_disenrollment = "TRUE"),
  s223926_q13_ = list(
    mm_hosp_position = "confinement", claim_status = "paid_only",
    months_as = "calendar", censor_at_disenrollment = "FALSE")
)

# One stream, shared by every scenario, rather than a stream each. The base
# draw is identical across scenarios and a setting scales only what it actually
# reaches, so a difference on this page is a difference the setting made.
.SYNTH_SEED <- 20260908L

.synth_rng <- function(seed = .SYNTH_SEED) {
  set.seed(seed)
  function(n, min, max) round(stats::runif(n, min, max), 4)
}

COHORT_KEYS <- c("1L", "2L", "3L", "SEC2L")
# Every vocabulary below is the package's own, not a paraphrase of it. A shell
# row names a condition, a measure or a period by its exact string, so a
# generator that invented its own would leave the Tables tab empty and the
# page would demonstrate the opposite of what it does on a real run.
SYNTH_CONDITIONS <- c(
  "acute_hepatitis_b", "toxic_liver_disease", "hepatic_failure",
  "fibrosis_and_cirrhosis", "non_alcoholic_steatohepatitis",
  "acute_kidney_injury_or_acute_kidney_disease", "chronic_kidney_disease",
  "moderate_to_severe_renal_impairment_or_esrd", "corneal_ulcer",
  "keratopathies", "myocardial_infarction_or_unstable_angina",
  "pulmonary_hypertension", "cerebrovascular_events_stroke_and_tia",
  "peripheral_arterial_thromboembolism",
  "deep_venous_thrombosis_or_pulmonary_embolism", "peripheral_neuropathy",
  "parkinsons_disease", "other_movement_disorders", "seizures",
  "severe_infection_resulting_in_hospitalisation",
  "lower_respiratory_or_lung_infection", "thrombocytopenia", "anemia")
SYNTH_DOMAINS <- c(
  rep("hepatologic", 5), rep("renal", 3), rep("ocular", 2),
  rep("cardiovascular", 5), rep("neurologic", 4), "infectious", "infectious",
  "other", "other")
SYNTH_MEASURES <- c("ALL_CAUSE_HOSPITALISATION", "MM_RELATED_HOSPITALISATION",
                    "ED_VISIT")
SYNTH_PERIODS <- c("BASELINE", "TREATMENT")
SYNTH_MALIG <- c("Hematological", "Genitourinary", "Gynecological",
                 "Head and Neck", "Gastrointestinal", "Thoracic (non-H&N)",
                 "Breast cancer", "Melanoma", "Non-melanoma skin cancer",
                 "Other")
SYNTH_OUTCOMES <- c("received_next_lot", "died", "discontinued_no_further",
                    "lost_to_followup")
# The package's own vocabulary, not a paraphrase of it. A shell column maps a
# regimen class to these strings by name, so a synthetic table spelling them
# differently would leave every class column empty and demonstrate the opposite
# of what the page does on a real run.
SYNTH_SOC <- c("Quadruplet with anti-CD38 backbone",
               "Triplet with anti-CD38 backbone",
               "Other triplet (non-anti-CD38)", "Doublet/monotherapy",
               "Other novel agent", "CAR-T", "BCMA bispecific",
               "Non-BCMA bispecific", "Other",
               "Autologous SCT (no regimen recorded)",
               "Allogeneic SCT (no regimen recorded)")

# The stratifications the package writes into its rate and count tables, and
# the bands its demographics module writes.
SYNTH_SOC_ALL <- "(all categories)"
SYNTH_AGE_ALL <- "(all ages)"
SYNTH_AGE_BANDS <- c("18-44", "45-64", "65-74", "75+")

# Fixed weights, not draws: the split must not move the RNG stream that
# produces the totals, or every number on the page would change with it.
SYNTH_SOC_W <- c(16, 22, 14, 18, 6, 5, 6, 4, 6, 2, 1)
SYNTH_AGE_W <- c(4, 24, 34, 38)

# A total cut into parts that sum back to it EXACTLY. The package guarantees
# its strata partition the line, the shells add margins up on that basis, and
# a demonstration whose parts did not add up would show something the study
# cannot do. The rounding remainder goes to the largest part.
split_total <- function(total, w, int = TRUE) {
  if (is.na(total) || total <= 0) return(rep(if (int) 0L else 0, length(w)))
  p <- w / sum(w)
  out <- if (int) floor(total * p) else round(total * p, 1)
  i <- which.max(p)
  out[i] <- out[i] + (total - sum(out))
  if (int) as.integer(out) else round(out, 4)
}

# One margin: the line's rows repeated once per stratum, every count cut into
# parts that add back up, and the other stratification left at its total -
# margins, not a cross, which is how the package writes them.
synth_margin <- function(d, col, levels, other, counts, nums, w) {
  out <- d[rep(seq_len(nrow(d)), each = length(levels)), , drop = FALSE]
  out[[col]] <- rep(levels, nrow(d))
  out[[other]] <- if (identical(other, "SOC_CATEGORY")) SYNTH_SOC_ALL
                  else SYNTH_AGE_ALL
  for (nm in counts)
    out[[nm]] <- as.integer(unlist(lapply(d[[nm]], split_total, w, TRUE)))
  for (nm in nums)
    out[[nm]] <- unlist(lapply(d[[nm]], split_total, w, FALSE))
  rownames(out) <- NULL
  out
}

# The line as a whole, then each stratification, then the derived columns
# recomputed from the parts rather than copied from the line.
synth_stratify <- function(d, counts, nums, recompute) {
  d$SOC_CATEGORY <- SYNTH_SOC_ALL
  d$AGE_BAND <- SYNTH_AGE_ALL
  recompute(rbind(
    d,
    synth_margin(d, "SOC_CATEGORY", SYNTH_SOC, "AGE_BAND", counts, nums,
                 SYNTH_SOC_W),
    synth_margin(d, "AGE_BAND", SYNTH_AGE_BANDS, "SOC_CATEGORY", counts, nums,
                 SYNTH_AGE_W)))
}

synthetic_scenarios <- function(cfg = dashboard_config()) {
  out <- list()
  for (i in seq_along(SYNTH_SCENARIOS)) {
    pfx <- names(SYNTH_SCENARIOS)[i]
    out[[pfx]] <- synthetic_one(pfx, SYNTH_SCENARIOS[[pfx]],
                                as.integer(cfg$suppress_min_n))
  }
  out
}

synthetic_one <- function(prefix, settings, min_n = 25L) {
  r <- .synth_rng()
  # A scale per scenario, so the open questions visibly move the numbers the
  # way the profile said they do: Q27 roughly doubles MM hospitalisations,
  # Q25 adds the denied claims, Q13 changes who is still followed.
  hosp_scale <- if (identical(settings$mm_hosp_position, "claim_positions")) 2.0 else 1.0
  claim_scale <- if (identical(settings$claim_status, "all")) 1.17 else 1.0
  fu_scale <- if (identical(settings$censor_at_disenrollment, "FALSE")) 1.29 else 1.0

  n_by <- c("1L" = 10514L, "2L" = 5179L, "3L" = 3127L, "SEC2L" = 6042L)
  periods <- SYNTH_PERIODS

  grid <- function(...) expand.grid(..., stringsAsFactors = FALSE,
                                    KEEP.OUT.ATTRS = FALSE)

  safety <- grid(COHORT = COHORT_KEYS, LOT_NUM = 1:3, PERIOD = periods,
                 CONDITION = SYNTH_CONDITIONS)
  safety$DOMAIN <- SYNTH_DOMAINS[match(safety$CONDITION, SYNTH_CONDITIONS)]
  safety$ACUTE_CHRONIC <- ifelse(
    safety$CONDITION %in% c("severe_infection_resulting_in_hospitalisation",
                            "thrombocytopenia"),
    "acute", "chronic")
  safety$N_AT_RISK <- as.integer(n_by[safety$COHORT] *
    r(nrow(safety), .25, .85) / safety$LOT_NUM)
  safety$PERSON_YEARS <- round(safety$N_AT_RISK * r(nrow(safety), .7, 2.6) * fu_scale, 1)
  safety$N_PATIENTS <- as.integer(safety$N_AT_RISK * r(nrow(safety), .01, .28) * claim_scale)
  safety$N_EVENTS <- as.integer(safety$N_PATIENTS * r(nrow(safety), 1, 2.4))
  safety <- synth_stratify(safety,
    counts = c("N_AT_RISK", "N_PATIENTS", "N_EVENTS"), nums = "PERSON_YEARS",
    recompute = function(d) {
      d$RATE <- round(1000 * d$N_EVENTS / pmax(d$PERSON_YEARS, 1), 2)
      d$RATE_LO <- round(d$RATE * 0.86, 2)
      d$RATE_HI <- round(d$RATE * 1.16, 2)
      d
    })

  hcru <- grid(COHORT = COHORT_KEYS, LOT_NUM = 1:3, PERIOD = periods,
               MEASURE = SYNTH_MEASURES)
  hcru$N_AT_RISK <- as.integer(n_by[hcru$COHORT] * r(nrow(hcru), .3, .9) / hcru$LOT_NUM)
  hcru$PERSON_YEARS <- round(hcru$N_AT_RISK * r(nrow(hcru), .7, 2.6) * fu_scale, 1)
  mmrel <- hcru$MEASURE == "MM_RELATED_HOSPITALISATION"
  hcru$N_PATIENTS <- as.integer(hcru$N_AT_RISK * r(nrow(hcru), .05, .42) *
                                ifelse(mmrel, hosp_scale, 1) * claim_scale)
  hcru$N_EVENTS <- as.integer(hcru$N_PATIENTS * r(nrow(hcru), 1, 2.9))
  hcru$MEAN_LOS <- round(r(nrow(hcru), 3.1, 11.4), 1)
  hcru$MEDIAN_LOS <- round(hcru$MEAN_LOS * 0.82, 1)
  hcru$N_LOS_EXCLUDED <- as.integer(hcru$N_EVENTS * r(nrow(hcru), 0, .04))
  # A length of stay is not a count and does not divide up, so a stratum keeps
  # the line's, which is what a mean of a subset looks like anyway.
  hcru <- synth_stratify(hcru,
    counts = c("N_AT_RISK", "N_PATIENTS", "N_EVENTS", "N_LOS_EXCLUDED"),
    nums = "PERSON_YEARS",
    recompute = function(d) {
      d$RATE <- round(1000 * d$N_EVENTS / pmax(d$PERSON_YEARS, 1), 2)
      d
    })

  malig <- grid(COHORT = COHORT_KEYS, LOT_NUM = 1:3, PERIOD = periods,
                CATEGORY = SYNTH_MALIG)
  malig$N_AT_RISK <- as.integer(n_by[malig$COHORT] * r(nrow(malig), .3, .9) / malig$LOT_NUM)
  malig$PERSON_YEARS <- round(malig$N_AT_RISK * r(nrow(malig), .7, 2.6) * fu_scale, 1)
  malig$N_PATIENTS <- as.integer(malig$N_AT_RISK * r(nrow(malig), .002, .05))
  malig <- synth_stratify(malig,
    counts = c("N_AT_RISK", "N_PATIENTS"), nums = "PERSON_YEARS",
    recompute = function(d) {
      d$RATE <- round(1000 * d$N_PATIENTS / pmax(d$PERSON_YEARS, 1), 2)
      d
    })

  patterns <- grid(COHORT = COHORT_KEYS, LOT_NUM = 1:3, SOC_CATEGORY = SYNTH_SOC)
  patterns$N_DENOM <- as.integer(n_by[patterns$COHORT] / patterns$LOT_NUM)
  patterns$N_PATIENTS <- as.integer(patterns$N_DENOM * r(nrow(patterns), .01, .32))
  patterns$PCT <- round(100 * patterns$N_PATIENTS / pmax(patterns$N_DENOM, 1), 1)

  txattr <- grid(COHORT = COHORT_KEYS, LOT_NUM = 1:3,
                 OUTCOME = SYNTH_OUTCOMES)
  txattr$N_DENOM <- as.integer(n_by[txattr$COHORT] / txattr$LOT_NUM)
  txattr$N_PATIENTS <- as.integer(txattr$N_DENOM * r(nrow(txattr), .04, .35))
  txattr <- synth_stratify(txattr,
    counts = c("N_DENOM", "N_PATIENTS"), nums = character(0),
    recompute = function(d) {
      d$PCT <- round(100 * d$N_PATIENTS / pmax(d$N_DENOM, 1), 1)
      d
    })

  switch_tbl <- grid(COHORT = COHORT_KEYS, FROM_LOT = 1:2,
                     FROM_CATEGORY = SYNTH_SOC, TO_CATEGORY = SYNTH_SOC)
  switch_tbl$TO_LOT <- switch_tbl$FROM_LOT + 1L
  switch_tbl$N_PATIENTS <- as.integer(
    n_by[switch_tbl$COHORT] * r(nrow(switch_tbl), .001, .06))

  attrition <- do.call(rbind, lapply(COHORT_KEYS, function(c1) {
    crit <- if (c1 %in% c("2L", "3L")) c("indexed", "N1_received_line", "N2_ce_pre",
                                         "I5_followup")
            else c("indexed", "I1_mm_dx", "I2_age", "I3_eligible_1l_tx",
                   "I4_ce_pre", "I5_followup", "X1_prior_mm_tx",
                   "X2_other_cancer", "X3_pregnancy", "X4_belantamab")
    n <- round(n_by[c1] * cumprod(c(1, r(length(crit) - 1, .82, .99))))
    data.frame(COHORT = c1, STEP = seq_along(crit), CRITERION = crit,
               APPLIED_BY = ifelse(crit == "indexed", "spine", "this package"),
               N_REMAINING = as.integer(n),
               N_LOST = as.integer(c(0, -diff(n))), stringsAsFactors = FALSE)
  }))

  n_sub <- 1200L
  tte <- data.frame(
    PATID = sprintf("P%06d", seq_len(n_sub)),
    COHORT = rep(COHORT_KEYS, length.out = n_sub),
    LOT_NUM = rep(1:3, length.out = n_sub),
    INDEX_DATE = as.Date("2019-01-01") + as.integer(r(n_sub, 0, 2200)),
    # Not everyone is in the survival analysis: the producer keeps the whole
    # cohort in S_TTE and marks the restricted population with this flag (see
    # study223926/R/modules/09_tte.R). A fixture where everyone is eligible
    # cannot tell a descriptive summary of the table from a curve over the
    # analysis set.
    TTE_ELIGIBLE = as.integer(seq_len(n_sub) %% 5L != 0L),
    stringsAsFactors = FALSE)
  for (ep in c("TTNT", "TTD", "OS")) {
    scale <- c(TTNT = 14, TTD = 11, OS = 34)[[ep]] * fu_scale
    mo <- round(stats::rexp(n_sub, rate = 1 / scale), 2)
    tte[[paste0(ep, "_MONTHS")]] <- mo
    tte[[paste0(ep, "_EVENT")]] <- as.integer(mo < scale * 1.5)
  }

  demo <- data.frame(
    PATID = tte$PATID, COHORT = tte$COHORT,
    INDEX_DATE = tte$INDEX_DATE,
    AGE_YEARS = as.integer(r(n_sub, 40, 89)),
    SEX = sample(c("M", "F"), n_sub, TRUE, c(.54, .46)),
    REGION = sample(c("Midwest", "Northeast", "South", "West", "Unknown"),
                    n_sub, TRUE),
    RACE = sample(c("White", "Black", "Asian", "Hispanic", "Unknown"),
                  n_sub, TRUE, c(.62, .18, .05, .08, .07)),
    ETHNICITY = sample(c("Hispanic", "Not Hispanic", "Unknown"), n_sub, TRUE,
                       c(.09, .8, .11)),
    INSURANCE_TYPE = sample(c("Commercial", "Medicare"), n_sub, TRUE, c(.42, .58)),
    ENROL_ROW_FOUND = 1L, stringsAsFactors = FALSE)
  # The package's own band labels: 03_demographics.R writes '75+', and a shell
  # column selecting it would match nothing spelled any other way.
  demo$AGE_BAND <- cut(demo$AGE_YEARS, c(-Inf, 44, 64, 74, Inf),
                       labels = SYNTH_AGE_BANDS)
  demo$AGE_BAND <- as.character(demo$AGE_BAND)

  comorb <- data.frame(
    PATID = tte$PATID, COHORT = tte$COHORT,
    CCI = round(r(n_sub, 0, 9)), N_CONDITIONS = as.integer(r(n_sub, 0, 7)),
    stringsAsFactors = FALSE)
  comorb$CCI_BAND <- cut(comorb$CCI, c(-Inf, 0, 1, 2, Inf),
                         labels = c("0", "1", "2", "3+"))
  comorb$CCI_BAND <- as.character(comorb$CCI_BAND)

  readings <- paste(c(
    vapply(names(settings), function(k) sprintf("%s=%s", k, settings[[k]]),
           character(1)),
    # The two optional outputs. A module's switch is what says the table was
    # written, and a run that wrote S_FRAILTY without recording the switch is
    # one whose own reader refuses to read it - correctly, because under a
    # prefix that table could be a previous run's.
    "frailty=TRUE", "comorbid_subgroups=TRUE",
    "study_start=2016-01-01 (upstream, verified; this run was set to 2018-01-01)",
    "pregnancy_window=study_period (upstream, unverified)"),
    collapse = "; ")

  meta <- data.frame(
    RUN_ID = paste0(prefix, "synthetic"), STATE = "complete",
    UPDATED_AT = "2026-09-08 12:00:00",
    COHORTS = paste(COHORT_KEYS, collapse = "; "),
    MODULES = paste(names(MODULES), collapse = "; "),
    LOT_RUN_ID = "synthetic-lot", LOT_RUN_VERSION = "20260908T110500Z",
    STUDY_START = "2018-01-01",
    STUDY_END = "2026-03-31", CONTRACT_DEVIATIONS = "none",
    OPEN_QUESTION_READINGS = readings,
    CODELISTS = "safety_events.csv(synthetic,42 rows)",
    stringsAsFactors = FALSE)

  # The study's own per-line categorisation, which is how a class or a line
  # reaches a table that carries neither: S_DEMOGRAPHICS has no LOT_NUM, so a
  # column headed by a line and a regimen class is answered by the patients
  # this table puts in it. The scenario's metadata says the soc module ran, and
  # a scenario that said so and wrote nothing was not one the page could
  # demonstrate on.
  soc <- data.frame(
    PATID = tte$PATID, COHORT = tte$COHORT, LOT_NUM = tte$LOT_NUM,
    SOC_CATEGORY = rep(SYNTH_SOC, length.out = n_sub),
    REGIMEN = rep(c("DVRd", "DRd", "VRd", "Rd", "Kd", "Cilta-cel", "Tec",
                    "Tal", "PVd", "ASCT", "AlloSCT"), length.out = n_sub),
    N_AGENTS = rep(c(4L, 3L, 3L, 2L, 2L, 1L, 1L, 1L, 3L, 1L, 1L),
                   length.out = n_sub),
    MATCHED = 1L, stringsAsFactors = FALSE)

  # One row per patient who had a secondary malignancy, which is the grain the
  # T3 shell reads: the rates table beside it is per stratum and cannot answer
  # a question about when the malignancy fell relative to the line.
  mi <- seq_len(n_sub) %% 17L == 0L
  malig_pt <- data.frame(
    PATID = tte$PATID[mi], COHORT = tte$COHORT[mi],
    CATEGORY = rep(SYNTH_MALIG, length.out = sum(mi)),
    SUBTYPE = rep(c("lymphoma", "prostate", "ovarian", "other_hn", "colorectal",
                    "lung", "breast", "melanoma", "basal_cell_carcinoma",
                    "other"), length.out = sum(mi)),
    LOT_AFTER_WHICH = rep(1:3, length.out = sum(mi)),
    N_DATES = 2L,
    MONTHS_FROM_DX = round(r(sum(mi), 6, 96), 1),
    MONTHS_FROM_INDEX = round(r(sum(mi), 1, 54), 1),
    stringsAsFactors = FALSE)

  # --- the windows, the spine and the membership ----------------------------
  #
  # Everything below hangs off the same 1,200 patients, so a line selected on
  # one table is the same patients on every other. The dates are consistent
  # rather than merely present: baseline ends the day before index, the
  # treatment window starts at index, and a line's next start is the following
  # line's own.
  fu_days <- as.integer(r(n_sub, 90, 2000) * fu_scale)
  periods_tbl <- data.frame(
    PATID = tte$PATID, COHORT = tte$COHORT, LOT_NUM = tte$LOT_NUM,
    INDEX_DATE = tte$INDEX_DATE,
    BASELINE_START = tte$INDEX_DATE - 365L,
    BASELINE_END = tte$INDEX_DATE - 1L,
    COMORB_BASELINE_START = tte$INDEX_DATE - 365L,
    COMORB_BASELINE_END = tte$INDEX_DATE - 1L,
    FU_END = tte$INDEX_DATE + fu_days,
    FU_DAYS = fu_days,
    FU_MONTHS = round(fu_days / 30.4375, 2),
    BASELINE_PY = round(366 / 365.25, 4),
    TTE_ELIGIBLE = tte$TTE_ELIGIBLE, stringsAsFactors = FALSE)

  # One row per patient per line, which is the grain the treatment period and
  # the spine share. The line's own start walks forward from the index.
  lines <- do.call(rbind, lapply(1:3, function(k) {
    st <- tte$INDEX_DATE + as.integer((k - 1) * 420)
    en <- st + as.integer(r(n_sub, 60, 700) * fu_scale)
    data.frame(PATID = tte$PATID, COHORT = tte$COHORT, LOT_NUM = k,
               PERIOD_START = st, PERIOD_END = en,
               PERIOD_PY = round(as.integer(en - st) / 365.25, 4),
               LOT_START_DT = st,
               PROTOCOL_DISCON_DT = en,
               NEXT_LOT_START_DT = if (k < 3) st + 420L else as.Date(NA),
               stringsAsFactors = FALSE)
  }))
  lines <- lines[order(lines$PATID, lines$LOT_NUM), ]
  rownames(lines) <- NULL

  # The engine's own line table, as the package republishes it. The transplant
  # flags live here and nowhere else, which is what the exploratory objective
  # would read.
  spine <- data.frame(
    PATID = lines$PATID, LOT_NUM = lines$LOT_NUM,
    LOT_START_DT = lines$LOT_START_DT,
    LOT_START_TYPE = ifelse(lines$LOT_NUM == 1L, "FIRST_LINE", "NEW_LINE"),
    LOT_BASE_MEDS = rep(c("DAR BOR LEN DEX", "LEN DEX", "CAR DEX"),
                        length.out = nrow(lines)),
    LOT_MED_CNT = rep(c(4L, 2L, 2L), length.out = nrow(lines)),
    LOT_BASE_DISCON_DT = lines$PROTOCOL_DISCON_DT,
    LOT_BASE_END_DT = lines$PROTOCOL_DISCON_DT,
    LOT_BASE_END_REASON = rep(c("DISCONTINUATION", "MED_ADD", "SCT_AUTO",
                                "CENSORED"), length.out = nrow(lines)),
    LOT_ALLO_LOT_FLG = as.integer(seq_len(nrow(lines)) %% 97L == 0L),
    LOT_CART_LOT_FLG = as.integer(seq_len(nrow(lines)) %% 41L == 0L),
    LOT_TX_AUTO_FLG = as.integer(seq_len(nrow(lines)) %% 7L == 0L),
    LOT_TX_AUTO_TAND_FLG = as.integer(seq_len(nrow(lines)) %% 53L == 0L),
    LOT_TX_AUTO_MAX_DT = as.Date(ifelse(seq_len(nrow(lines)) %% 7L == 0L,
                                        lines$LOT_START_DT + 120L, NA),
                                 origin = "1970-01-01"),
    NEXT_LOT_START_DT = lines$NEXT_LOT_START_DT,
    IS_PROTOCOL_DISCON = as.integer(
      rep(c(1L, 1L, 1L, 0L), length.out = nrow(lines))),
    PROTOCOL_DISCON_DT = lines$PROTOCOL_DISCON_DT,
    stringsAsFactors = FALSE)

  # Per-criterion verdicts per patient, which is the grain the funnel is
  # aggregated from. Everyone here is in their cohort - the funnel above is
  # what says how many were not.
  cohort_tbl <- data.frame(
    PATID = tte$PATID, COHORT = tte$COHORT, LOT_NUM = tte$LOT_NUM,
    INDEX_DATE = tte$INDEX_DATE,
    MET_N1 = 1L, MET_N2 = 1L, MET_I5 = 1L,
    MET_X1 = 0L, MET_X2 = 0L, MET_X3 = 0L, MET_X4 = 0L,
    IN_COHORT = 1L, stringsAsFactors = FALSE)

  # --- the two comorbidity subgroups and the frailty index -------------------
  #
  # One row per patient per concept, including the patients who do NOT have it:
  # the flag is the numerator and the concept's own rows are the denominator,
  # which is how a shell row reads it without the denominator drifting.
  subgroup <- do.call(rbind, lapply(
    c("neuropathy", "lung_parenchymal_disease"), function(cc) {
      has <- as.integer(
        if (identical(cc, "neuropathy")) seq_len(n_sub) %% 4L == 0L
        else seq_len(n_sub) %% 9L == 0L)
      data.frame(PATID = tte$PATID, COHORT = tte$COHORT, CONCEPT = cc,
                 HAS_HISTORY = has,
                 FIRST_DT = as.Date(ifelse(has == 1L,
                                           tte$INDEX_DATE - 200L, NA),
                                    origin = "1970-01-01"),
                 stringsAsFactors = FALSE)
    }))

  cfi <- round(r(n_sub, 0.05, 0.45), 3)
  frailty <- data.frame(
    PATID = tte$PATID, COHORT = tte$COHORT, CFI = cfi,
    FRAIL = as.integer(cfi >= 0.25), N_VARIABLES = 93L,
    stringsAsFactors = FALSE)

  # --- the event tables the rates were computed from -------------------------
  #
  # Not a re-derivation of the rates above: these are the working sets QC reads
  # to check a rate against the events behind it, and they are here so that a
  # page showing one can show the other.
  ei <- seq_len(n_sub) %% 3L == 0L
  safety_ev <- data.frame(
    PATID = tte$PATID[ei], COHORT = tte$COHORT[ei],
    CONDITION = rep(SYNTH_CONDITIONS, length.out = sum(ei)),
    stringsAsFactors = FALSE)
  safety_ev$DOMAIN <- SYNTH_DOMAINS[match(safety_ev$CONDITION, SYNTH_CONDITIONS)]
  safety_ev$ACUTE_CHRONIC <- ifelse(
    safety_ev$CONDITION %in% c("severe_infection_resulting_in_hospitalisation",
                               "thrombocytopenia"), "chronic", "acute")
  safety_ev$EVENT_DT <- tte$INDEX_DATE[ei] + as.integer(r(sum(ei), -300, 900))

  safety_counted <- data.frame(
    PATID = safety_ev$PATID, COHORT = safety_ev$COHORT,
    LOT_NUM = tte$LOT_NUM[ei],
    PERIOD = ifelse(safety_ev$EVENT_DT < tte$INDEX_DATE[ei],
                    "BASELINE", "TREATMENT"),
    CONDITION = safety_ev$CONDITION, EVENT_DT = safety_ev$EVENT_DT,
    stringsAsFactors = FALSE)

  hi <- seq_len(n_sub) %% 2L == 0L
  los <- as.integer(r(sum(hi), 1, 21))
  # A stay with no discharge date is what N_LOS_EXCLUDED counts, so some have
  # none - a fixture where every stay had one could not show the exclusion.
  no_disch <- seq_len(sum(hi)) %% 23L == 0L
  hcru_ev <- data.frame(
    PATID = tte$PATID[hi], COHORT = tte$COHORT[hi],
    EVENT_TYPE = rep(c("INPATIENT", "ED"), length.out = sum(hi)),
    EVENT_DT = tte$INDEX_DATE[hi] + as.integer(r(sum(hi), -200, 800)),
    stringsAsFactors = FALSE)
  hcru_ev$END_DT <- as.Date(ifelse(no_disch, NA, hcru_ev$EVENT_DT + los),
                            origin = "1970-01-01")
  hcru_ev$LOS_DAYS <- ifelse(no_disch, NA_integer_, los)
  hcru_ev$MM_RELATED <- as.integer(seq_len(sum(hi)) %% 3L == 0L)
  hcru_ev$HAS_DISCHARGE <- as.integer(!no_disch)

  # Every qualifying date, not only the first: the rates table is dated at the
  # first and this is what a baseline prevalence would be read from.
  malig_dates <- do.call(rbind, lapply(0:1, function(k)
    data.frame(PATID = malig_pt$PATID, COHORT = malig_pt$COHORT,
               CATEGORY = malig_pt$CATEGORY, SUBTYPE = malig_pt$SUBTYPE,
               EVENT_DT = tte$INDEX_DATE[mi] + as.integer(k * 45) +
                 as.integer(malig_pt$MONTHS_FROM_INDEX * 30),
               stringsAsFactors = FALSE)))

  tables <- list(
    S_RUN_METADATA = meta, S_SPINE = spine, S_COHORT = cohort_tbl,
    S_ATTRITION = attrition, S_PERIODS = periods_tbl, S_LOT_PERIODS = lines,
    S_SOC = soc, S_COMORB_SUBGROUP = subgroup, S_FRAILTY = frailty,
    S_SAFETY_EVENTS = safety_ev, S_SAFETY_COUNTED = safety_counted,
    S_HCRU_EVENTS = hcru_ev, S_MALIGNANCY = malig_pt,
    S_MALIGNANCY_DATES = malig_dates,
    S_DEMOGRAPHICS = demo, S_COMORBIDITY = comorb, S_TTE = tte,
    S_SAFETY_RATES = safety, S_HCRU_RATES = hcru,
    S_MALIGNANCY_RATES = malig, S_PATTERNS = patterns,
    S_TX_ATTRITION = txattr, S_SWITCH = switch_tbl)

  # The released copies, from the package's own spec rather than a second
  # statement of the rule: which count decides, and which values go with it.
  # The scenario's metadata says the release module ran, so a page that
  # prefers the released table was falling back to the raw one and showing
  # numbers no release had passed.
  c(tables, synth_release(tables, min_n))
}

# One released table per entry of the package's SUPPRESSION_SPEC: the count
# column and everything computed from it set to NULL wherever the stratum is
# under the floor, and the reason recorded beside it. A count that cannot be
# read has not been shown to clear the floor, so a NULL suppresses too - the
# same reading mod_release() takes.
synth_release <- function(tables, min_n) {
  out <- list()
  for (tbl in names(SUPPRESSION_SPEC)) {
    d <- tables[[tbl]]
    if (is.null(d)) next
    spec <- SUPPRESSION_SPEC[[tbl]]
    n <- suppressWarnings(as.numeric(d[[spec$n_col]]))
    hit <- is.na(n) | n < min_n
    for (cl in intersect(c(spec$n_col, spec$value_cols), names(d)))
      d[[cl]][hit] <- NA
    d$SUPPRESSED <- as.integer(hit)
    d$SUPPRESSION_REASON <- ifelse(is.na(n), "n unknown",
                            ifelse(n < min_n, paste0("n < ", min_n), NA))
    out[[paste0(tbl, "_RELEASE")]] <- d
  }
  out
}

# --- the LOT run behind every synthetic scenario -----------------------------
#
# One run, shared. That is the normal case: none of the study's open questions
# changes how a line is counted, so several study scenarios rest on the same
# lines. Made up like the rest, and the page says so.

SYNTH_LOT_RUN_ID <- "synthetic-lot"

LOT_START_TYPES <- c("MED", "SCT_AUTO", "SCT_ALLO", "CART", "SCT_CART",
                     "SCT_AUTO_CONT")
LOT_END_REASONS <- c("DISCONTINUATION", "MED_ADD", "CART_INIT", "SCT_AUTO",
                     "SCT_ALLO", "DEATH", "STUDY_END", "DISENROLLMENT")

synthetic_lot_run <- function() {
  r <- .synth_rng()
  n_pat <- 1200L
  pid <- sprintf("P%06d", seq_len(n_pat))
  # Lines per patient thin out the way real ones do: everyone has a 1L, and
  # each later line holds a fraction of the one before it.
  keep <- c(1, .49, .30, .16, .07)
  rows <- do.call(rbind, lapply(1:5, function(n) {
    take <- pid[seq_len(round(n_pat * keep[n]))]
    if (!length(take)) return(NULL)
    st <- if (n == 1L) rep("MED", length(take)) else
      sample(LOT_START_TYPES, length(take), TRUE, c(.72, .12, .04, .07, .03, .02))
    start <- as.Date("2019-01-01") + as.integer(r(length(take), 0, 1500)) +
      (n - 1L) * 210L
    len <- as.integer(r(length(take), 25, 640))
    data.frame(
      PATID = take, LOT_NUM = n, LOT_START_DT = start,
      LOT_START_TYPE = st,
      LOT_BASE_MEDS = sample(c("BORT|LEN|DEX", "DARA|LEN|DEX", "LEN|DEX",
                              "CARF|DEX", "BORT|CYCLO|DEX", "DARA|BORT|LEN|DEX"),
                             length(take), TRUE),
      LOT_MED_CNT = as.integer(r(length(take), 1, 4)),
      LOT_BASE_END_DT = start + len,
      LOT_BASE_END_REASON = sample(LOT_END_REASONS, length(take), TRUE,
                                   c(.34, .18, .05, .07, .02, .11, .19, .04)),
      LOT_BASE_LENGTH = len,
      LOT_ALLO_LOT_FLG = as.integer(st == "SCT_ALLO"),
      LOT_CART_LOT_FLG = as.integer(st %in% c("CART", "SCT_CART")),
      stringsAsFactors = FALSE)
  }))
  rownames(rows) <- NULL

  # The line criteria remove some lines. LOT_LONG is before them and
  # LOT_LONG_FINAL after, which is why the two are different tables and why
  # only the validation panel reads the first.
  drop <- r(nrow(rows), 0, 1) < 0.06
  final <- rows[!drop, , drop = FALSE]

  n_start <- n_pat
  steps <- list(
    list(KIND = "input", STEP = "cohort as LOT read it", n = n_start),
    list(KIND = "criterion", STEP = "line starts inside the study period",
         n = round(n_start * .97)),
    list(KIND = "criterion", STEP = "regimen is not empty", n = round(n_start * .95)),
    list(KIND = "criterion", STEP = "line ends on or before study end",
         n = round(n_start * .94)),
    list(KIND = "progression", STEP = "reached 2L", n = round(n_start * .49)),
    list(KIND = "progression", STEP = "reached 3L", n = round(n_start * .30)),
    list(KIND = "reconciliation", STEP = "patients with at least one line",
         n = round(n_start * .94)),
    list(KIND = "final", STEP = "study population", n = round(n_start * .94)))
  attrition <- do.call(rbind, lapply(seq_along(steps), function(i) {
    s <- steps[[i]]
    prev <- if (i > 1) steps[[i - 1]]$n else s$n
    data.frame(RUN_ID = SYNTH_LOT_RUN_ID, STEP_NUM = i, KIND = s$KIND,
               STEP = s$STEP, N_PATIENTS = as.integer(s$n),
               N_LINES = as.integer(s$n * 1.9),
               PCT_OF_START = round(100 * s$n / n_start, 1),
               PCT_OF_PREV = round(100 * s$n / max(prev, 1), 1),
               RECORDED_AT = "2026-09-08 11:00:00", stringsAsFactors = FALSE)
  }))

  # Face validity reports the number and its expected range; the verdict is
  # read off them. One deliberately outside its range, so the panel that shows
  # a LOOK is exercised rather than only ever drawing greens.
  fv <- data.frame(
    RUN_ID = SYNTH_LOT_RUN_ID,
    CHECK_NAME = c("pct_1l_bortezomib", "median_1l_length", "pct_reaching_2l",
                   "pct_auto_sct_1l", "mean_meds_per_lot"),
    WHAT = c("1L regimens containing bortezomib",
             "median 1L length in days", "patients reaching 2L",
             "1L lines ending in an autologous transplant",
             "agents per line"),
    VALUE = c(58.4, 331, 49.0, 18.2, 2.6),
    EXPECT_LO = c(45, 200, 35, 10, 2),
    EXPECT_HI = c(70, 420, 55, 30, 4),
    stringsAsFactors = FALSE)
  fv$VALUE[2] <- 512                       # outside 200-420 on purpose
  fv$VERDICT <- ifelse(fv$VALUE >= fv$EXPECT_LO & fv$VALUE <= fv$EXPECT_HI,
                       "ok", "LOOK")
  fv$RECORDED_AT <- "2026-09-08 11:00:00"

  qc <- data.frame(
    CHECK_NAME = c("LOT_LONG duplicate PATID x LOT_NUM", "lines with no regimen",
                   "line ending before it starts", "LOT_NUM not contiguous",
                   "start date outside the study period"),
    CHECK_VALUE = c(0L, 0L, 0L, 0L, 0L),
    CHECK_STATUS = "PASS", RUN_ID = SYNTH_LOT_RUN_ID, stringsAsFactors = FALSE)

  meta <- data.frame(
    RUN_ID = SYNTH_LOT_RUN_ID, RUN_TIMESTAMP = "2026-09-08 11:00:00",
    LOT_LONG_BY_LINE = "1:1200|2:588|3:360|4:192|5:84",
    N_LOT_FINAL_ROWS = nrow(final),
    N_LOT_FINAL_PATIENTS = length(unique(final$PATID)),
    CODE_MD5 = "synthetic", CONTRACT_SETTINGS = "induction_window_days=60|lot_n_induction_window_days=30",
    STUDY_START = "2016-01-01", STUDY_END = "2026-03-31",
    LINE_CRITERIA_APPLIED = "line_in_study_period; regimen_not_empty",
    stringsAsFactors = FALSE)

  status <- data.frame(
    RUN_ID = SYNTH_LOT_RUN_ID, INPUT_COHORT_TABLE = "ndmm_NDMM_COHORT",
    OBJECT_PREFIX = "lot_", STATE = "complete", STUDY_END = "2026-03-31",
    CODELIST_WAIVERS_REQUESTED = "", CODELIST_WAIVERS_APPLIED = "",
    CONTRACT_DEVIATIONS = "none", UPDATED_AT = "2026-09-08 11:05:00",
    stringsAsFactors = FALSE)

  list(LOT_LONG = rows, LOT_LONG_FINAL = final, LOT_ATTRITION = attrition,
       LOT_FACE_VALIDITY = fv, LOT_QC_SUMMARY = qc,
       LOT_RUN_METADATA = meta, LOT_BUILD_STATUS = status)
}
