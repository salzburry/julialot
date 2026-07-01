# =============================================================================
# build_flagged_cohort.R  --  the "large cohort with flags" data layer
# -----------------------------------------------------------------------------
# Produces / loads the FLAGGED SUPERSET cohort: one row per patient in the
# broadest 1L-treated MM population, with one boolean column per IE criterion
# (registry_flag_ids()) plus the demographics / clinical / LOT-derived /
# time-to-event fields the NDMM protocol (GSK 223926) asks for. Nothing is
# dropped here -- selection happens in cohort_select.R by AND-ing flags.
#
# Also produces a LOT-LONG table (one row per patient x LOT_NUM) that backs the
# per-LOT (1L/2L/3L) outcome views and the regimen / Sankey transition tab.
#
# PRODUCTION WIRING (not run in this environment -- no warehouse):
#   The real builder is a thin projection over the validated apr_30_2026
#   outputs (ELIG_COH_FINAL + LOT_LONG), with the per-criterion flags and the
#   baseline characteristics (CCI, comorbidities, HCRU) computed at the correct
#   anchor -- the same SQL 06_ndmm_dashboard.R uses for its IE post-filters, but
#   emitted as COLUMNS instead of applied as row filters. Implement
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
  df
}

# ---- validation: fail closed on a missing column (jun_21 convention) --------
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
  fu_from_dx_months <- round(dx_to_1l_months + fu_potential_months, 1)

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
  df$incl_baseline_ce_6m  <- bern(0.88)
  df$incl_baseline_ce_12m <- as.integer(df$incl_baseline_ce_6m == 1L & runif(n) < 0.78)
  df$incl_fu_ce_3m        <- as.integer(os_event == 1L | runif(n) < 0.8)
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
      # per-line time-to-event (months, from this line's start)
      ttd_t <- round(pmax(0.3, rgamma(1, 2, scale = 6)), 1)
      ttd_e <- as.integer(runif(1) < 0.7)
      ttnt_t <- round(ttd_t + rexp(1, 1 / 6), 1)
      ttnt_e <- as.integer(l < nl)              # next line observed iff one exists
      os_t <- round(pmax(ttd_t, rgamma(1, 2, scale = 18)), 1)
      os_e <- as.integer(runif(1) < 0.42)
      rows[[length(rows) + 1L]] <- data.frame(
        patient_id = pid, lot_num = l, lot_label = paste0(l, "L"),
        lot_start_dt = start, lot_soc = soc,
        payer_type = cohort$payer_type[i], age_index = cohort$age_index[i],
        os_time = os_t, os_event = os_e,
        ttd_time = ttd_t, ttd_event = ttd_e,
        ttnt_time = ttnt_t, ttnt_event = ttnt_e,
        fu_potential_months = os_t,
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
LOT_LONG_REQUIRED_COLS <- c(
  "patient_id", "lot_num", "lot_start_dt", "lot_soc",
  "os_time", "os_event", "ttd_time", "ttd_event",
  "ttnt_time", "ttnt_event", "fu_potential_months")

validate_lot_long <- function(ll) {
  stopifnot(is.data.frame(ll))
  miss <- setdiff(LOT_LONG_REQUIRED_COLS, names(ll))
  if (length(miss))
    stop("LOT-long is missing required columns: ", paste(miss, collapse = ", "),
         call. = FALSE)
  if (anyDuplicated(ll[c("patient_id", "lot_num")]))
    stop("LOT-long key (patient_id, lot_num) is not unique.", call. = FALSE)
  if (!all(ll$lot_num >= 1L)) stop("LOT-long lot_num must be >= 1.", call. = FALSE)
  for (f in c("os_event", "ttd_event", "ttnt_event"))
    if (!all(ll[[f]] %in% c(0L, 1L)))
      stop("LOT-long '", f, "' must be strictly 0/1.", call. = FALSE)
  for (t in c("os_time", "ttd_time", "ttnt_time", "fu_potential_months"))
    if (any(ll[[t]] < 0, na.rm = TRUE))
      stop("LOT-long '", t, "' has negative values.", call. = FALSE)
  # within patient: lines ordered and start dates non-decreasing
  o <- ll[order(ll$patient_id, ll$lot_num), ]
  bad_order <- tapply(as.numeric(o$lot_start_dt), o$patient_id,
                      function(d) any(diff(d) < 0))
  if (any(unlist(bad_order), na.rm = TRUE))
    stop("LOT-long lot_start_dt decreases within a patient.", call. = FALSE)
  invisible(ll)
}

# Carry patient-level BASELINE strata onto LOT-long so later-line (2L/3L) KM
# stratification works. These are explicitly 1L-BASELINE CARRY-FORWARD values
# (the UI labels them as such); true per-line baselines are a warehouse step.
augment_lot_long <- function(lot_long, cohort) {
  carry <- intersect(c("age_band", "cci_band", "ti_te_age", "ti_te_age_cci",
                       "gender", "region", "race", "ethnicity",
                       "bl_cv", "bl_neuro", "bl_renal"), names(cohort))
  add <- cohort[, c("patient_id", carry), drop = FALSE]
  for (b in intersect(c("bl_cv", "bl_neuro", "bl_renal"), carry))
    add[[b]] <- ifelse(add[[b]] == 1L, "Yes", "No")
  merged <- merge(lot_long, add, by = "patient_id", all.x = TRUE, sort = FALSE)
  merged[order(merged$patient_id, merged$lot_num), , drop = FALSE]
}

# =============================================================================
# Warehouse source (production) -- fail-closed stub.
# Implement the DBI/odbc projection of the validated apr_30_2026 outputs
# (ELIG_COH_FINAL x LOT_LONG + per-criterion flags as columns) here; the
# dashboard consumes it via load_flagged_cohort(source_flagged_cohort_warehouse).
# =============================================================================
source_flagged_cohort_warehouse <- function(...) {
  stop("source_flagged_cohort_warehouse() is not implemented in this ",
       "environment (no Databricks warehouse). Implement the DBI/odbc ",
       "projection of ELIG_COH_FINAL x LOT_LONG + IE flags (see README / ",
       "06_ndmm_dashboard.R) before using a production data path.",
       call. = FALSE)
}
