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

# ONE stream, shared by every scenario.
#
# Not a stream per scenario. With a stream each, every measure differed between
# any two scenarios - including the ones the setting does not touch - and the
# comparison view then taught a viewer that changing the washout moves the ED
# rate. The base draw is identical across scenarios and the setting scales only
# what it actually reaches, so a difference on this page is a difference the
# setting made.
.SYNTH_SEED <- 20260908L

.synth_rng <- function(seed = .SYNTH_SEED) {
  set.seed(seed)
  function(n, min, max) round(stats::runif(n, min, max), 4)
}

COHORT_KEYS <- c("1L", "2L", "3L", "SEC2L")
SYNTH_CONDITIONS <- c("ocular_toxicity", "thrombocytopenia", "anemia",
                      "severe_infection", "peripheral_neuropathy",
                      "renal_impairment", "second_primary_malignancy")
SYNTH_MEASURES <- c("all_cause_hospitalisation", "mm_related_hospitalisation",
                    "emergency_department_visit")
SYNTH_SOC <- c("Quadruplet", "Triplet", "Doublet", "Anti-CD38 backbone",
               "CAR-T", "BCMA bispecific", "Other")

synthetic_scenarios <- function(cfg = dashboard_config()) {
  out <- list()
  for (i in seq_along(SYNTH_SCENARIOS)) {
    pfx <- names(SYNTH_SCENARIOS)[i]
    out[[pfx]] <- synthetic_one(pfx, SYNTH_SCENARIOS[[pfx]])
  }
  out
}

synthetic_one <- function(prefix, settings) {
  r <- .synth_rng()
  # A scale per scenario, so the open questions visibly move the numbers the
  # way the profile said they do: Q27 roughly doubles MM hospitalisations,
  # Q25 adds the denied claims, Q13 changes who is still followed.
  hosp_scale <- if (identical(settings$mm_hosp_position, "claim_positions")) 2.0 else 1.0
  claim_scale <- if (identical(settings$claim_status, "all")) 1.17 else 1.0
  fu_scale <- if (identical(settings$censor_at_disenrollment, "FALSE")) 1.29 else 1.0

  n_by <- c("1L" = 10514L, "2L" = 5179L, "3L" = 3127L, "SEC2L" = 6042L)
  periods <- c("baseline", "follow_up", "on_treatment")

  grid <- function(...) expand.grid(..., stringsAsFactors = FALSE,
                                    KEEP.OUT.ATTRS = FALSE)

  safety <- grid(COHORT = COHORT_KEYS, LOT_NUM = 1:3, PERIOD = periods,
                 CONDITION = SYNTH_CONDITIONS)
  safety$DOMAIN <- c("ocular", "haematologic", "haematologic", "infectious",
                     "neurologic", "renal", "oncologic")[
                       match(safety$CONDITION, SYNTH_CONDITIONS)]
  safety$ACUTE_CHRONIC <- ifelse(
    safety$CONDITION %in% c("severe_infection", "thrombocytopenia"),
    "acute", "chronic")
  safety$N_AT_RISK <- as.integer(n_by[safety$COHORT] *
    r(nrow(safety), .25, .85) / safety$LOT_NUM)
  safety$PERSON_YEARS <- round(safety$N_AT_RISK * r(nrow(safety), .7, 2.6) * fu_scale, 1)
  safety$N_PATIENTS <- as.integer(safety$N_AT_RISK * r(nrow(safety), .01, .28) * claim_scale)
  safety$N_EVENTS <- as.integer(safety$N_PATIENTS * r(nrow(safety), 1, 2.4))
  safety$RATE <- round(1000 * safety$N_EVENTS / pmax(safety$PERSON_YEARS, 1), 2)
  safety$RATE_LO <- round(safety$RATE * 0.86, 2)
  safety$RATE_HI <- round(safety$RATE * 1.16, 2)

  hcru <- grid(COHORT = COHORT_KEYS, LOT_NUM = 1:3, PERIOD = periods,
               MEASURE = SYNTH_MEASURES)
  hcru$N_AT_RISK <- as.integer(n_by[hcru$COHORT] * r(nrow(hcru), .3, .9) / hcru$LOT_NUM)
  hcru$PERSON_YEARS <- round(hcru$N_AT_RISK * r(nrow(hcru), .7, 2.6) * fu_scale, 1)
  mmrel <- hcru$MEASURE == "mm_related_hospitalisation"
  hcru$N_PATIENTS <- as.integer(hcru$N_AT_RISK * r(nrow(hcru), .05, .42) *
                                ifelse(mmrel, hosp_scale, 1) * claim_scale)
  hcru$N_EVENTS <- as.integer(hcru$N_PATIENTS * r(nrow(hcru), 1, 2.9))
  hcru$RATE <- round(1000 * hcru$N_EVENTS / pmax(hcru$PERSON_YEARS, 1), 2)
  hcru$MEAN_LOS <- round(r(nrow(hcru), 3.1, 11.4), 1)
  hcru$MEDIAN_LOS <- round(hcru$MEAN_LOS * 0.82, 1)
  hcru$N_LOS_EXCLUDED <- as.integer(hcru$N_EVENTS * r(nrow(hcru), 0, .04))

  malig <- grid(COHORT = COHORT_KEYS, LOT_NUM = 1:3, PERIOD = periods,
                CATEGORY = c("haematologic", "solid_tumour", "skin"))
  malig$N_AT_RISK <- as.integer(n_by[malig$COHORT] * r(nrow(malig), .3, .9) / malig$LOT_NUM)
  malig$PERSON_YEARS <- round(malig$N_AT_RISK * r(nrow(malig), .7, 2.6) * fu_scale, 1)
  malig$N_PATIENTS <- as.integer(malig$N_AT_RISK * r(nrow(malig), .002, .05))
  malig$RATE <- round(1000 * malig$N_PATIENTS / pmax(malig$PERSON_YEARS, 1), 2)

  patterns <- grid(COHORT = COHORT_KEYS, LOT_NUM = 1:3, SOC_CATEGORY = SYNTH_SOC)
  patterns$N_DENOM <- as.integer(n_by[patterns$COHORT] / patterns$LOT_NUM)
  patterns$N_PATIENTS <- as.integer(patterns$N_DENOM * r(nrow(patterns), .01, .32))
  patterns$PCT <- round(100 * patterns$N_PATIENTS / pmax(patterns$N_DENOM, 1), 1)

  txattr <- grid(COHORT = COHORT_KEYS, LOT_NUM = 1:3,
                 OUTCOME = c("discontinued", "progressed_to_next_lot",
                             "died", "still_on_treatment", "censored"))
  txattr$N_DENOM <- as.integer(n_by[txattr$COHORT] / txattr$LOT_NUM)
  txattr$N_PATIENTS <- as.integer(txattr$N_DENOM * r(nrow(txattr), .04, .35))
  txattr$PCT <- round(100 * txattr$N_PATIENTS / pmax(txattr$N_DENOM, 1), 1)

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
    # Not everyone is in the survival analysis. The producer keeps the whole
    # cohort in S_TTE and marks the restricted population with this flag - see
    # study223926/R/modules/09_tte.R - so a fixture where everyone is eligible
    # cannot show the difference between a descriptive summary of the table
    # and a curve over the analysis set, and a panel drawn over the wrong one
    # looks right.
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
  demo$AGE_BAND <- cut(demo$AGE_YEARS, c(-Inf, 44, 64, 74, Inf),
                       labels = c("18-44", "45-64", "65-74", ">=75"))
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
    "study_start=2016-01-01 (upstream, verified; this run was set to 2018-01-01)",
    "pregnancy_window=study_period (upstream, unverified)"),
    collapse = "; ")

  meta <- data.frame(
    RUN_ID = paste0(prefix, "synthetic"), STATE = "complete",
    UPDATED_AT = "2026-09-08 12:00:00",
    COHORTS = paste(COHORT_KEYS, collapse = "; "),
    MODULES = paste(names(MODULES), collapse = "; "),
    LOT_RUN_ID = "synthetic-lot", STUDY_START = "2018-01-01",
    STUDY_END = "2026-03-31", CONTRACT_DEVIATIONS = "none",
    OPEN_QUESTION_READINGS = readings,
    CODELISTS = "safety_events.csv(synthetic,42 rows)",
    stringsAsFactors = FALSE)

  list(S_RUN_METADATA = meta, S_ATTRITION = attrition,
       S_DEMOGRAPHICS = demo, S_COMORBIDITY = comorb, S_TTE = tte,
       S_SAFETY_RATES = safety, S_HCRU_RATES = hcru,
       S_MALIGNANCY_RATES = malig, S_PATTERNS = patterns,
       S_TX_ATTRITION = txattr, S_SWITCH = switch_tbl)
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
