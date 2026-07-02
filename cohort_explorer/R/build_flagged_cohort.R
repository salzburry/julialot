# =============================================================================
# build_flagged_cohort.R  --  the "large cohort with flags" data layer
# -----------------------------------------------------------------------------
# Produces / loads the FLAGGED SUPERSET cohort: one row per patient in the
# broadest 1L-treated MM population, with one boolean column per IE criterion
# (registry_flag_ids()) plus the demographics / clinical / LOT-derived /
# time-to-event fields the NDMM study protocol asks for. Nothing is
# dropped here -- selection happens in cohort_select.R by AND-ing flags.
#
# Also produces a LOT-LONG table (one row per patient x LOT_NUM) that backs the
# per-LOT (1L/2L/3L) outcome views and the regimen / Sankey transition tab.
#
# PRODUCTION WIRING (not run in this environment -- no warehouse):
#   The real builder is a thin projection over the validated upstream LOT
#   pipeline outputs (ELIG_COH_FINAL + LOT_LONG), with the per-criterion flags
#   and the baseline characteristics (CCI, comorbidities, HCRU) computed at the
#   correct anchor -- the same SQL the upstream NDMM flag build uses for its IE
#   post-filters, but emitted as COLUMNS instead of applied as row filters. Implement
#   source_flagged_cohort_warehouse() to SELECT that projection via DBI/odbc.
#
# RUNNABLE HERE:
#   load_flagged_cohort("synthetic") generates a deterministic synthetic cohort
#   so the app is demoable without a warehouse (reserved 9-billion PATIDs).
# =============================================================================

# ---- contract: non-flag columns every flagged cohort must carry -------------
FLAGGED_COHORT_BASE_COLS <- c(
  "patient_id",
  # demographics (protocol Table 1)
  "age_index", "gender", "region", "race", "ethnicity", "payer_type",
  # dates
  "index_date", "lot1_start_dt", "death_dt",
  # calendar / follow-up (protocol characteristics + attrition)
  "dx_year", "lot_init_year", "dx_to_1l_months", "fu_from_dx_months",
  "fu_potential_months",
  # raw continuous-enrollment durations (months) -- carried as MEASURES, not
  # just fixed-threshold flags, so a "movable CE window" is an in-memory slider
  "baseline_ce_months", "followup_ce_months",
  # clinical: Charlson + baseline comorbidities of interest (flag + count + PY)
  "cci",
  "bl_hepatic", "bl_renal", "bl_infection", "bl_ocular", "bl_cv", "bl_neuro",
  "n_hepatic", "n_renal", "n_infection", "n_ocular", "n_cv", "n_neuro",
  "baseline_py",
  # baseline healthcare resource utilisation
  "ip_hosp_count", "er_visit_count", "ip_los_days",
  # LOT-derived
  "soc_category", "n_lines", "lot1_length",
  # time-to-event (months + 1/0 event); OS = time to death (protocol endpoint)
  "os_time", "os_event",
  "ttd_time", "ttd_event",
  "ttnt_time", "ttnt_event",
  # PFS retained as EXPLORATORY only (protocol says PFS not ascertainable)
  "pfs_time", "pfs_event"
)

# comorbidity + HCRU columns that must be strictly 0/1 alongside the flags
COMORBID_COLS <- c("bl_hepatic", "bl_renal", "bl_infection", "bl_ocular",
                   "bl_cv", "bl_neuro")

# ---- derived subgroup columns (added after load; consistent for real data) --
# age bands, transplant-eligibility proxies (protocol §6.2.3), CCI bands.
add_derived_cols <- function(df) {
  df$age_band <- cut(df$age_index, breaks = c(-Inf, 44, 64, 74, Inf),
                     labels = c("18-44", "45-64", "65-74", "75+"))
  df$age_band <- as.character(df$age_band)
  df$age_ge70 <- ifelse(df$age_index >= 70, ">=70", "<70")
  df$cci_band <- as.character(pmin(df$cci, 5L))
  df$cci_band[df$cci >= 5L] <- "5+"
  # TI/TE proxies: transplant-INELIGIBLE (TI) vs -ELIGIBLE (TE)
  df$ti_te_age <- ifelse(df$age_index >= 70, "TI (age>=70)", "TE (age<70)")
  df$ti_te_age_cci <- ifelse(df$age_index >= 70 | df$cci >= 3L,
                             "TI (age>=70 or CCI>=3)", "TE (age<70 & CCI<3)")
  # HCRU count bands (protocol: 1/2/3/4+)
  band4 <- function(x) { b <- as.character(pmin(x, 4L)); b[x >= 4L] <- "4+"; b }
  df$ip_hosp_band <- band4(df$ip_hosp_count)
  df$er_visit_band <- band4(df$er_visit_count)
  # current-line SOC alias so one stratum ("lot_soc") works at BOTH the
  # patient level (1L = soc_category) and later lines (LOT-long carries lot_soc)
  df$lot_soc <- df$soc_category
  df
}

# ---- validation: fail closed on a missing column ----------------------------
validate_flagged_cohort <- function(df, reg = criteria_registry()) {
  stopifnot(is.data.frame(df))
  need <- c(FLAGGED_COHORT_BASE_COLS, registry_flag_ids(reg))
  miss <- setdiff(need, names(df))
  if (length(miss))
    stop("flagged cohort is missing required columns: ",
         paste(miss, collapse = ", "), call. = FALSE)
  for (f in c(registry_flag_ids(reg), COMORBID_COLS)) {
    v <- df[[f]]
    if (!all(v %in% c(0L, 1L)))
      stop("column '", f, "' must be strictly 0/1 (no NA).", call. = FALSE)
  }
  # safety-event counts feed rate-per-PY directly: must be non-negative,
  # integer-valued, non-missing, and baseline_py strictly positive.
  count_cols <- c("n_hepatic", "n_renal", "n_infection", "n_ocular", "n_cv", "n_neuro")
  for (c in intersect(count_cols, names(df))) {
    v <- df[[c]]
    if (any(is.na(v)) || any(v < 0) || !all(v == round(v)))
      stop("safety count '", c, "' must be non-negative integers (no NA).",
           call. = FALSE)
  }
  if ("baseline_py" %in% names(df) &&
      (any(is.na(df$baseline_py)) || any(df$baseline_py <= 0)))
    stop("baseline_py must be strictly positive (no NA).", call. = FALSE)
  # the Yes/No flag and the event count must agree (prevalence is read from the
  # flag, rates from the count -- a contradiction would be internally inconsistent)
  pairs <- list(c("bl_hepatic", "n_hepatic"), c("bl_renal", "n_renal"),
                c("bl_infection", "n_infection"), c("bl_ocular", "n_ocular"),
                c("bl_cv", "n_cv"), c("bl_neuro", "n_neuro"))
  for (p in pairs) if (all(p %in% names(df)))
    if (any(df[[p[1]]] != as.integer(df[[p[2]]] > 0)))
      stop("safety flag '", p[1], "' disagrees with count '", p[2],
           "' (flag must equal count>0).", call. = FALSE)
  # ---- core numeric contract (fail-closed at load, not just displayed later) --
  nn_int <- function(v) !any(is.na(v)) && all(v >= 0) && all(v == round(v))
  int_cols <- c("age_index", "cci", "n_lines", "ip_hosp_count", "er_visit_count")
  for (c in intersect(int_cols, names(df)))
    if (!nn_int(df[[c]]))
      stop("'", c, "' must be non-negative integer-valued (no NA).", call. = FALSE)
  if ("n_lines" %in% names(df) && any(df$n_lines < 1L))
    stop("n_lines must be >= 1.", call. = FALSE)
  if ("lot1_length" %in% names(df) &&
      (any(is.na(df$lot1_length)) || any(df$lot1_length <= 0)))
    stop("lot1_length must be strictly positive (no NA).", call. = FALSE)
  if ("ip_los_days" %in% names(df) &&
      (any(is.na(df$ip_los_days)) || any(df$ip_los_days < 0)))
    stop("ip_los_days must be non-negative (no NA).", call. = FALSE)

  # ---- patient-level time-to-event contract (mirrors validate_lot_long) -------
  # the 1L KM tabs read these directly from the patient-level cohort, so they
  # must fail closed the same way the LOT-long endpoints do.
  eps <- 1e-6
  ev_pairs <- list(c("os_time", "os_event"), c("ttd_time", "ttd_event"),
                   c("ttnt_time", "ttnt_event"), c("pfs_time", "pfs_event"))
  for (p in ev_pairs) if (all(p %in% names(df))) {
    tt <- df[[p[1]]]; ev <- df[[p[2]]]
    if (any(is.na(tt)) || any(tt < 0))
      stop("'", p[1], "' must be non-negative (no NA).", call. = FALSE)
    if (!all(ev %in% c(0L, 1L)))
      stop("'", p[2], "' must be strictly 0/1.", call. = FALSE)
    if ("fu_potential_months" %in% names(df) && any(tt > df$fu_potential_months + eps))
      stop("'", p[1], "' exceeds fu_potential_months for some patients.", call. = FALSE)
  }
  # an OS death event requires a death date (a death after administrative
  # censoring, death_dt present with os_event=0, is allowed by design)
  if (all(c("os_event", "death_dt") %in% names(df)) &&
      any(df$os_event == 1L & is.na(df$death_dt)))
    stop("os_event=1 requires a non-missing death_dt.", call. = FALSE)
  # patient-level TTNT biconditional (mirrors the LOT-long one): a next-treatment
  # event iff the patient reached >=2 lines -- else a treated 2L+ patient is
  # miscensored on the 1L TTNT curve.
  if (all(c("ttnt_event", "n_lines") %in% names(df)) &&
      any(df$ttnt_event != as.integer(df$n_lines > 1L)))
    stop("ttnt_event must equal (n_lines > 1) at the patient level.", call. = FALSE)

  # ---- required dates present & ordered ---------------------------------------
  for (d in c("index_date", "lot1_start_dt"))
    if (d %in% names(df) && any(is.na(df[[d]])))
      stop("'", d, "' has missing/unparseable dates.", call. = FALSE)
  if (all(c("index_date", "lot1_start_dt") %in% names(df)) &&
      any(df$index_date > df$lot1_start_dt))
    stop("index_date must be <= lot1_start_dt.", call. = FALSE)

  if (anyDuplicated(df$patient_id))
    stop("patient_id is not unique in the flagged cohort.", call. = FALSE)
  invisible(df)
}

# ---- public loader ----------------------------------------------------------
# source: "synthetic" | path to a CSV with the contract schema | a function
#         returning the data.frame (e.g. the warehouse projection).
load_flagged_cohort <- function(source = "synthetic", ...) {
  df <- if (is.function(source)) {
    source(...)
  } else if (identical(source, "synthetic")) {
    synth_flagged_cohort(...)
  } else if (is.character(source) && file.exists(source)) {
    read.csv(source, stringsAsFactors = FALSE)
  } else {
    stop("load_flagged_cohort: unknown source '", source, "'.", call. = FALSE)
  }
  for (d in c("index_date", "lot1_start_dt", "death_dt"))
    if (!inherits(df[[d]], "Date")) df[[d]] <- as.Date(df[[d]])
  df <- add_derived_cols(df)
  validate_flagged_cohort(df)
}

# =============================================================================
# Synthetic patient-level generator -- deterministic, base R only.
# =============================================================================
synth_flagged_cohort <- function(n = 4000L, seed = 42L, soc_levels = NULL) {
  set.seed(seed)
  if (is.null(soc_levels)) soc_levels <- soc_levels_1l()

  patient_id <- sprintf("%010.0f", 9000000000 + seq_len(n) - 1)

  age_index  <- pmin(95L, pmax(30L, round(rnorm(n, 69, 11))))
  gender     <- sample(c("Female", "Male", "Unknown"), n, TRUE, c(0.46, 0.535, 0.005))
  region     <- sample(c("Midwest", "Northeast", "South", "West", "Unknown"),
                       n, TRUE, c(0.26, 0.18, 0.40, 0.15, 0.01))
  race       <- sample(c("White", "Black", "Asian", "Unknown"),
                       n, TRUE, c(0.66, 0.20, 0.05, 0.09))
  ethnicity  <- sample(c("Hispanic or Latino", "Not Hispanic or Latino", "Unknown"),
                       n, TRUE, c(0.08, 0.82, 0.10))
  payer_type <- sample(c("Commercial", "Medicare"), n, TRUE, c(0.45, 0.55))

  # MM diagnosis (index) then 1L start after a dx->1L gap (attrition)
  origin     <- as.Date("2016-01-01")
  index_date <- origin + sample(0:(as.integer(as.Date("2024-06-30") - origin)), n, TRUE)
  dx_to_1l_days <- round(pmax(0, rgamma(n, shape = 1.4, scale = 40)))   # ~skewed
  lot1_start_dt <- index_date + dx_to_1l_days
  dx_to_1l_months <- round(dx_to_1l_days / 30.44, 1)
  dx_year       <- as.integer(format(index_date, "%Y"))
  lot_init_year <- as.integer(format(lot1_start_dt, "%Y"))

  soc_category <- sample(soc_levels, n, TRUE, c(0.22, 0.20, 0.18, 0.20, 0.12, 0.08))
  n_lines      <- sample(1:5, n, TRUE, c(0.42, 0.27, 0.16, 0.09, 0.06))
  lot1_length  <- round(pmax(20, rgamma(n, shape = 2.2, scale = 130)))

  # Charlson comorbidity index (0..8), skewed low
  cci <- pmin(8L, rpois(n, 1.6))

  # baseline comorbidities of interest (protocol safety-event background):
  # per-patient EVENT COUNTS over the 12-mo baseline; the Yes/No flag is
  # "count > 0". baseline_py = 1.0 (standardised 12-mo baseline person-year),
  # so rates are events per patient-year over the baseline window.
  bern <- function(p) as.integer(runif(n) < p)
  cnt  <- function(mean) rpois(n, mean)
  n_cv        <- cnt(0.35)
  n_neuro     <- cnt(0.15)
  n_renal     <- rpois(n, 0.12 + 0.03 * cci)     # ties to CCI
  n_hepatic   <- cnt(0.06)
  n_infection <- cnt(0.20)
  n_ocular    <- cnt(0.05)
  baseline_py <- rep(1.0, n)
  bl_cv        <- as.integer(n_cv > 0)
  bl_neuro     <- as.integer(n_neuro > 0)
  bl_renal     <- as.integer(n_renal > 0)
  bl_hepatic   <- as.integer(n_hepatic > 0)
  bl_infection <- as.integer(n_infection > 0)
  bl_ocular    <- as.integer(n_ocular > 0)

  # baseline HCRU (12-mo pre-index)
  ip_hosp_count  <- rpois(n, 0.7)
  er_visit_count <- rpois(n, 0.9)
  ip_los_days    <- round(ip_hosp_count * pmax(0, rgamma(n, 1.5, scale = 3)), 1)

  # ---- follow-up + time-to-event (months, from 1L index) ----
  # Potential follow-up is ADMINISTRATIVE (death-independent): from 1L start to
  # the earlier of study end and a random disenrollment horizon. OS is then the
  # min of a latent death time and this potential follow-up -- so a patient who
  # dies at 1 month still HAS >=3-mo potential follow-up and is retained by the
  # protocol >=3-mo TTE restriction (fixes the death-unaware cut).
  study_end   <- as.Date("2025-06-30")
  admin_months <- pmax(0.1, as.integer(study_end - lot1_start_dt) / 30.44)
  disenroll_months <- pmax(1, rgamma(n, shape = 2, scale = 22))
  fu_potential_months <- round(pmin(admin_months, disenroll_months), 1)

  latent_death <- pmax(0.2, rexp(n, rate = 1 / 52) *
    (1 - (age_index - 69) / 260) * (1 - (n_lines - 1) * 0.07) *
    (1 - pmin(cci, 6) * 0.03))
  os_time  <- round(pmin(latent_death, fu_potential_months), 1)
  os_event <- as.integer(latent_death <= fu_potential_months)
  # OBSERVED follow-up from diagnosis (dx -> death/censor), not administrative
  # potential follow-up -- this is the protocol Table-1 characteristic.
  fu_from_dx_months <- round(dx_to_1l_months + os_time, 1)

  # raw continuous-enrollment durations (months); the fixed-threshold CE flags
  # below are DERIVED from these, so a movable CE slider stays consistent with
  # the flags and 12mo is always a subset of 6mo.
  baseline_ce_months <- pmax(0L, round(rgamma(n, shape = 2.4, scale = 7)))
  followup_ce_months <- pmax(0L, round(pmin(fu_potential_months,
                                            rgamma(n, shape = 2, scale = 8))))

  death_dt <- as.Date(rep(NA_integer_, n), origin = "1970-01-01")
  ev <- os_event == 1L
  death_dt[ev] <- lot1_start_dt[ev] + round(os_time[ev] * 30.44)

  pfs_time  <- round(pmin(os_time, pmax(0.3, os_time * runif(n, 0.45, 0.95))), 1)
  pfs_event <- as.integer(runif(n) < 0.62)
  ttd_time  <- round(pmax(0.3, pmin(os_time, lot1_length / 30.44 * runif(n, 0.8, 1.3))), 1)
  ttd_event <- as.integer(runif(n) < 0.7)
  ttnt_time <- round(pmin(os_time, ttd_time + rexp(n, 1 / 6)), 1)
  ttnt_event <- as.integer(n_lines > 1L)

  df <- data.frame(
    patient_id, age_index, gender, region, race, ethnicity, payer_type,
    index_date, lot1_start_dt, death_dt,
    dx_year, lot_init_year, dx_to_1l_months, fu_from_dx_months, fu_potential_months,
    baseline_ce_months, followup_ce_months,
    cci, bl_hepatic, bl_renal, bl_infection, bl_ocular, bl_cv, bl_neuro,
    n_hepatic, n_renal, n_infection, n_ocular, n_cv, n_neuro, baseline_py,
    ip_hosp_count, er_visit_count, ip_los_days,
    soc_category, n_lines, lot1_length,
    os_time, os_event, ttd_time, ttd_event, ttnt_time, ttnt_event,
    pfs_time, pfs_event,
    stringsAsFactors = FALSE)

  # ---- IE flags (1 = patient satisfies the criterion) ----
  df$incl_qualifying_mm   <- bern(0.985)
  df$incl_adult           <- as.integer(age_index >= 18L)
  df$incl_eligible_1l_tx  <- as.integer(lot1_start_dt >= as.Date("2017-01-01"))
  df$incl_baseline_ce_6m  <- as.integer(df$baseline_ce_months >= 6L)
  df$incl_baseline_ce_12m <- as.integer(df$baseline_ce_months >= 12L)
  df$incl_fu_ce_3m        <- as.integer(df$followup_ce_months >= 3L | os_event == 1L)
  df$incl_new_user        <- bern(0.9)
  df$incl_fu_mm_agents    <- bern(0.995)
  df$excl_prior_mm_tx     <- bern(0.91)
  df$excl_other_cancer    <- bern(0.86)
  df$excl_belantamab      <- bern(0.985)
  df$excl_pregnancy       <- as.integer(!(gender == "Female" & runif(n) < 0.01))

  rownames(df) <- NULL
  df
}

# 1L SOC categories (protocol §6.2.2)
soc_levels_1l <- function() c(
  "Quadruplet with anti-CD38 backbone",
  "Triplet with anti-CD38 backbone",
  "Other triplet (non-anti-CD38)",
  "Doublet", "Monotherapy", "Other")

# 2L+ SOC categories (protocol §6.2.2, later lines)
soc_levels_later <- function() c(
  "Triplet with anti-CD38 backbone",
  "Other triplet (non-anti-CD38)",
  "Other novel agent (e.g. selinexor)",
  "CAR-T", "Bispecific (BCMA / non-BCMA)",
  "Doublet", "Monotherapy")

# =============================================================================
# Synthetic LOT-LONG generator -- one row per (patient, lot_num).
# Backs the per-LOT outcome views and the regimen/Sankey transition tab.
# Depends only on patient-level fields already generated.
# =============================================================================
synth_lot_long <- function(cohort, seed = 43L) {
  set.seed(seed)
  later <- soc_levels_later()
  rows <- list()
  for (i in seq_len(nrow(cohort))) {
    pid <- cohort$patient_id[i]; nl <- cohort$n_lines[i]
    start <- cohort$lot1_start_dt[i]
    for (l in seq_len(nl)) {
      soc <- if (l == 1L) cohort$soc_category[i]
             else sample(later, 1, prob = c(0.22, 0.16, 0.10, 0.10, 0.10, 0.18, 0.14))
      # per-line ADMINISTRATIVE potential follow-up (death-independent), then
      # OS = min(latent death, potential follow-up) -- same semantics as the
      # patient level, so the >=3-mo TTE restriction retains early deaths.
      fu_pot <- round(pmax(1, rgamma(1, shape = 2, scale = 20)), 1)
      latent_death <- pmax(0.2, rgamma(1, 2, scale = 18))
      os_t <- round(min(latent_death, fu_pot), 1)
      os_e <- as.integer(latent_death <= fu_pot)
      ttd_t <- round(pmax(0.3, min(os_t, rgamma(1, 2, scale = 6))), 1)
      ttd_e <- as.integer(runif(1) < 0.7)
      ttnt_t <- round(min(fu_pot, ttd_t + rexp(1, 1 / 6)), 1)
      ttnt_e <- as.integer(l < nl)              # next line observed iff one exists
      rows[[length(rows) + 1L]] <- data.frame(
        patient_id = pid, lot_num = l, lot_label = paste0(l, "L"),
        lot_start_dt = start, lot_soc = soc,
        payer_type = cohort$payer_type[i], age_index = cohort$age_index[i],
        os_time = os_t, os_event = os_e,
        ttd_time = ttd_t, ttd_event = ttd_e,
        ttnt_time = ttnt_t, ttnt_event = ttnt_e,
        fu_potential_months = fu_pot,
        stringsAsFactors = FALSE)
      start <- start + round(ttnt_t * 30.44)    # next line begins after TTNT
    }
  }
  out <- do.call(rbind, rows)
  # next-line SOC for transition/Sankey (NA on the last observed line)
  out <- out[order(out$patient_id, out$lot_num), ]
  nxt <- ave(out$lot_soc, out$patient_id,
             FUN = function(s) c(s[-1], NA_character_))
  out$next_soc <- nxt
  rownames(out) <- NULL
  out
}

# ---- LOT-long contract + validation -----------------------------------------
# Required set = EVERY column the downstream views (KM per-LOT, regimen freq,
# transition/Sankey) actually consume -- incl. payer_type and next_soc, whose
# absence used to pass validation and then crash the transition tab.
LOT_LONG_REQUIRED_COLS <- c(
  "patient_id", "lot_num", "lot_start_dt", "lot_soc", "next_soc", "payer_type",
  "os_time", "os_event", "ttd_time", "ttd_event",
  "ttnt_time", "ttnt_event", "fu_potential_months")

# Derive next_soc (next line's SOC; NA on the last observed line) if a supplied
# table lacks it -- so a real projection without the column still works.
derive_next_soc <- function(ll) {
  ll <- ll[order(ll$patient_id, ll$lot_num), ]
  ll$next_soc <- ave(ll$lot_soc, ll$patient_id,
                     FUN = function(s) c(s[-1], NA_character_))
  ll
}

validate_lot_long <- function(ll) {
  stopifnot(is.data.frame(ll))
  miss <- setdiff(LOT_LONG_REQUIRED_COLS, names(ll))
  if (length(miss))
    stop("LOT-long is missing required columns: ", paste(miss, collapse = ", "),
         call. = FALSE)
  if (anyDuplicated(ll[c("patient_id", "lot_num")]))
    stop("LOT-long key (patient_id, lot_num) is not unique.", call. = FALSE)
  # lot_num must be integer-VALUED (DBI/CSV often deliver it as double); compare
  # by value, not R type, so 1,2,3 as numeric is accepted but 1.5 is rejected.
  if (any(is.na(ll$lot_num)) || !all(ll$lot_num == round(ll$lot_num)))
    stop("LOT-long lot_num must be integer-valued.", call. = FALSE)
  ll$lot_num <- as.integer(round(ll$lot_num))
  if (!all(ll$lot_num >= 1L)) stop("LOT-long lot_num must be >= 1.", call. = FALSE)
  for (f in c("os_event", "ttd_event", "ttnt_event"))
    if (!all(ll[[f]] %in% c(0L, 1L)))
      stop("LOT-long '", f, "' must be strictly 0/1.", call. = FALSE)
  for (t in c("os_time", "ttd_time", "ttnt_time", "fu_potential_months"))
    if (any(ll[[t]] < 0, na.rm = TRUE))
      stop("LOT-long '", t, "' has negative values.", call. = FALSE)
  # within patient: line 1 present, lot_num contiguous from 1, start dates
  # non-decreasing (downstream code assumes a well-formed line sequence)
  o <- ll[order(ll$patient_id, ll$lot_num), ]
  by_pt <- split(o, o$patient_id)
  bad_seq <- vapply(by_pt, function(p)
    p$lot_num[1] != 1L || !identical(p$lot_num, seq_len(nrow(p))) ||
      any(diff(as.numeric(p$lot_start_dt)) < 0), logical(1))
  if (any(bad_seq))
    stop(sum(bad_seq), " patient(s) have a non-contiguous / mis-ordered LOT ",
         "sequence (must start at 1L, be contiguous, dates non-decreasing).",
         call. = FALSE)
  # next_soc must be CONSISTENT with the line SOC sequence, even when supplied
  # (a stale/incorrect next_soc would silently corrupt the transition/pathway).
  der <- ave(o$lot_soc, o$patient_id, FUN = function(s) c(s[-1], NA_character_))
  mism <- (is.na(der) != is.na(o$next_soc)) |
          (!is.na(der) & !is.na(o$next_soc) & der != o$next_soc)
  if (any(mism))
    stop(sum(mism), " LOT-long row(s) have next_soc inconsistent with the ",
         "line SOC sequence (expected next line's lot_soc, NA on the last line).",
         call. = FALSE)
  # lot_soc / payer_type must be non-missing & non-blank: table() silently drops
  # NA, so a blank would quietly vanish from regimen / transition / pathway counts
  for (col in c("lot_soc", "payer_type"))
    if (any(is.na(ll[[col]]) | !nzchar(trimws(as.character(ll[[col]])))))
      stop("LOT-long '", col, "' has missing/blank values.", call. = FALSE)
  # event/time consistency: every TTE must fall within potential follow-up, and a
  # TTNT event implies a subsequent line actually exists in the table
  eps <- 1e-6
  for (t in c("os_time", "ttd_time", "ttnt_time"))
    if (any(ll[[t]] > ll$fu_potential_months + eps))
      stop("LOT-long '", t, "' exceeds fu_potential_months for some rows.",
           call. = FALSE)
  # TTNT event must reconcile with whether a next line actually exists, BOTH
  # ways: 1 on a non-terminal line (next treatment observed) and 0 on the last
  # observed line. A one-sided check let an observed next line be miscensored.
  max_ln <- ave(o$lot_num, o$patient_id, FUN = max)
  next_exists <- o$lot_num < max_ln
  n_bad <- sum((o$ttnt_event == 1L) != next_exists)
  if (n_bad)
    stop(n_bad, " LOT-long row(s) have ttnt_event inconsistent with the next ",
         "line (must be 1 iff a subsequent line exists, 0 on the last line).",
         call. = FALSE)
  # ttnt_time on a non-terminal line must reconcile with the actual gap to the
  # next line's start (TTNT = time to next treatment). Generous tolerance
  # absorbs day-rounding / minor definitional slack; catches gross mismatch.
  next_start <- ave(as.numeric(o$lot_start_dt), o$patient_id,
                    FUN = function(x) c(x[-1], NA_real_))
  gap_m <- (next_start - as.numeric(o$lot_start_dt)) / 30.44
  recon <- next_exists & !is.na(gap_m)
  n_gap <- sum(abs(o$ttnt_time[recon] - gap_m[recon]) > 2)   # tolerance: 2 months
  if (n_gap)
    stop(n_gap, " LOT-long row(s) have ttnt_time inconsistent (>2mo) with the ",
         "gap between this line and the next line's start date.", call. = FALSE)
  invisible(ll)
}

# Loader: read (CSV / synth / function), derive next_soc if absent, validate.
load_lot_long <- function(source, cohort = NULL, ...) {
  ll <- if (is.function(source)) source(...)
        else if (identical(source, "synthetic")) synth_lot_long(cohort, ...)
        else if (is.character(source) && file.exists(source)) {
          x <- read.csv(source, stringsAsFactors = FALSE)
          x$lot_start_dt <- as.Date(x$lot_start_dt); x
        } else stop("load_lot_long: unknown source.", call. = FALSE)
  if (!"next_soc" %in% names(ll)) ll <- derive_next_soc(ll)
  ll <- validate_lot_long(ll)
  # coverage: every flagged patient must have a 1L LOT-long row, else the
  # per-LOT / regimen / pathway views silently undercount vs the KPI N.
  if (!is.null(cohort)) {
    have_1l <- ll$patient_id[ll$lot_num == 1L]
    miss <- setdiff(as.character(cohort$patient_id), as.character(have_1l))
    if (length(miss))
      stop(length(miss), " flagged-cohort patient(s) have no 1L LOT-long row ",
           "(per-LOT / regimen / pathway views would undercount vs the KPI N). ",
           "The LOT-long projection must cover every flagged patient.",
           call. = FALSE)
    # row count per patient must equal n_lines (else later-line views undercount
    # even though FLAGGED$n_lines says the lines exist). Lines are contiguous
    # from 1L (checked above), so a matching count implies lines 1..n_lines.
    if ("n_lines" %in% names(cohort)) {
      rc  <- tapply(ll$lot_num, as.character(ll$patient_id), length)
      exp <- setNames(as.integer(cohort$n_lines), as.character(cohort$patient_id))
      got <- rc[names(exp)]
      bad <- sum(is.na(got) | got != exp)
      if (bad)
        stop(bad, " flagged patient(s) have a LOT-long line count != n_lines ",
             "(later-line regimen / KM / pathway views would disagree with the ",
             "patient-level cohort). The projection must emit every line 1..n_lines.",
             call. = FALSE)
    }
  }
  ll
}

# Carry patient-level BASELINE strata onto LOT-long so later-line (2L/3L) KM
# stratification works. These are explicitly 1L-BASELINE CARRY-FORWARD values
# (the UI labels them as such); true per-line baselines are a warehouse step.
augment_lot_long <- function(lot_long, cohort) {
  # carry EVERY dictionary categorical/binary variable that the KM strata
  # dropdown can offer, so an advertised stratum is never silently unavailable
  # at 2L/3L (except the line-level columns already on LOT-long: lot_soc, payer).
  vd <- variable_dictionary()
  strata_vars <- names(vd)[vapply(vd, function(x) x$type %in% c("cat", "binary"),
                                  logical(1))]
  carry <- setdiff(intersect(strata_vars, names(cohort)), names(lot_long))
  add <- cohort[, c("patient_id", carry), drop = FALSE]
  bl_cols <- c("bl_hepatic", "bl_renal", "bl_infection", "bl_ocular",
               "bl_cv", "bl_neuro")
  for (b in intersect(bl_cols, carry)) add[[b]] <- ifelse(add[[b]] == 1L, "Yes", "No")
  merged <- merge(lot_long, add, by = "patient_id", all.x = TRUE, sort = FALSE)
  merged[order(merged$patient_id, merged$lot_num), , drop = FALSE]
}

# =============================================================================
# Warehouse source (production) -- fail-closed stub.
# Implement the DBI/odbc projection of the validated upstream LOT pipeline
# outputs (ELIG_COH_FINAL x LOT_LONG + per-criterion flags as columns) here; the
# dashboard consumes it via load_flagged_cohort(source_flagged_cohort_warehouse).
# =============================================================================
# Read a materialised analytic table (built once by the pipeline: the NDMM flag
# join, UN-filtered, + parent flags + CCI/safety/HCRU + LOT-long) over DBI/odbc.
# Pass a live connection `con`; without one it fails closed (no warehouse here).
.warehouse_read <- function(table, con = NULL,
    catalog = Sys.getenv("WAREHOUSE_CATALOG", "main"),
    schema  = Sys.getenv("PROJECT_WORK_SCHEMA",
                         Sys.getenv("DOMINO_USER_NAME", "mm_lot_work"))) {
  if (is.null(con))
    stop("source_*_warehouse(): pass a live DBI connection `con`. The analytic ",
         "cohort must be MATERIALISED once by the pipeline (CREATE TABLE ",
         schema, ".", table, " AS <NDMM flag join, un-filtered> -- see ",
         "ANALYTIC_COHORT.md); this environment has no warehouse.", call. = FALSE)
  if (!requireNamespace("DBI", quietly = TRUE))
    stop("DBI is required to read the analytic cohort.", call. = FALSE)
  DBI::dbGetQuery(con, sprintf("SELECT * FROM %s.%s.%s", catalog, schema, table))
}

# patient-level analytic cohort (the flagged superset)
source_flagged_cohort_warehouse <- function(con = NULL, table = "ANALYTIC_COHORT", ...)
  .warehouse_read(table, con = con, ...)

# per-line analytic LOT-long
source_lot_long_warehouse <- function(con = NULL, table = "ANALYTIC_LOT_LONG", ...)
  .warehouse_read(table, con = con, ...)

# Export the materialised snapshot the OFFLINE dashboard path reads (the
# artifact the pipeline writes once per data refresh). Writes two CSVs + a
# build-stamp so the UI can show "data as of ...".
export_analytic_cohort <- function(cohort, lot_long, dir, stamp = NULL) {
  if (!dir.exists(dir)) dir.create(dir, recursive = TRUE)
  validate_flagged_cohort(cohort); validate_lot_long(lot_long)
  cp <- file.path(dir, "analytic_cohort.csv")
  lp <- file.path(dir, "analytic_lot_long.csv")
  utils::write.csv(cohort,   cp, row.names = FALSE)
  utils::write.csv(lot_long, lp, row.names = FALSE)
  writeLines(c(paste0("rows_cohort=", nrow(cohort)),
               paste0("rows_lot_long=", nrow(lot_long)),
               paste0("built=", if (is.null(stamp)) "unstamped" else stamp)),
             file.path(dir, "analytic_cohort.stamp"))
  invisible(list(cohort = cp, lot_long = lp))
}
