# =============================================================================
# build_flagged_cohort.R  --  the "large cohort with flags" data layer
# -----------------------------------------------------------------------------
# Produces / loads the FLAGGED SUPERSET cohort: one row per patient in the
# broadest 1L-treated MM population, with one boolean column per IE criterion
# (registry_flag_ids()) plus the demographics / LOT-derived / time-to-event
# fields the dashboard needs. Nothing is dropped here -- selection happens in
# cohort_select.R by AND-ing flags.
#
# PRODUCTION WIRING (not run in this environment -- no warehouse):
#   The real builder is a thin projection over the validated apr_30_2026
#   outputs. Conceptually:
#     ELIG_COH_FINAL  (cohort attrition, 01_cohort.R)
#       join LOT_LONG  (02_lot1.R / lot2_5_base.R) on patient_id
#       + per-criterion flags computed at the correct anchor (the same SQL the
#         06_ndmm_dashboard.R IE post-filters already use), but emitted as
#         boolean COLUMNS instead of being applied as row filters.
#   To wire it in, implement `source_flagged_cohort_warehouse()` to SELECT that
#   projection via DBI/odbc (DSN/catalog from pipeline_inputs.csv) and return a
#   data.frame with the contract columns below. The dashboard code does not
#   change -- only the data source does. That is the reuse contract.
#
# RUNNABLE HERE:
#   load_flagged_cohort("synthetic") generates a deterministic synthetic cohort
#   so the app is demoable without a warehouse. Synthetic PATIDs use the
#   reserved 9-billion range (matches the repo's no-synthetic-in-prod rule).
# =============================================================================

# ---- contract: non-flag columns every flagged cohort must carry -------------
FLAGGED_COHORT_BASE_COLS <- c(
  "patient_id",
  # demographics / cohort passthrough
  "age_index", "gender", "region", "payer_type", "race",
  "index_date", "lot1_start_dt", "death_dt",
  # LOT-derived
  "soc_category", "n_lines", "lot1_length",
  # time-to-event (months + 1/0 event indicator); censored when event = 0
  "os_time", "os_event",
  "pfs_time", "pfs_event",
  "ttd_time", "ttd_event",
  "ttnt_time", "ttnt_event"
)

# ---- validation: fail closed on a missing column (jun_21 convention) --------
validate_flagged_cohort <- function(df, reg = criteria_registry()) {
  stopifnot(is.data.frame(df))
  need <- c(FLAGGED_COHORT_BASE_COLS, registry_flag_ids(reg))
  miss <- setdiff(need, names(df))
  if (length(miss))
    stop("flagged cohort is missing required columns: ",
         paste(miss, collapse = ", "), call. = FALSE)
  # flag columns must be 0/1 (NA not allowed -- a flag is a decided fact)
  for (f in registry_flag_ids(reg)) {
    v <- df[[f]]
    if (!all(v %in% c(0L, 1L)))
      stop("flag column '", f, "' must be strictly 0/1 (no NA).", call. = FALSE)
  }
  if (anyDuplicated(df$patient_id))
    stop("patient_id is not unique in the flagged cohort.", call. = FALSE)
  invisible(df)
}

# ---- public loader ----------------------------------------------------------
# source: "synthetic" | a path to a CSV with the contract schema | a function
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
  # coerce dates if read from CSV
  for (d in c("index_date", "lot1_start_dt", "death_dt"))
    if (!inherits(df[[d]], "Date")) df[[d]] <- as.Date(df[[d]])
  validate_flagged_cohort(df)
}

# =============================================================================
# Synthetic generator -- deterministic, base R only.
# =============================================================================
synth_flagged_cohort <- function(n = 4000L, seed = 42L,
                                 soc_levels = NULL) {
  set.seed(seed)
  if (is.null(soc_levels)) {
    soc_levels <- c(
      "Quadruplet with anti-CD38 backbone (1L NDMM)",
      "Triplet with anti-CD38 backbone (1L NDMM)",
      "Other triplet non-antiCD38 (1L NDMM)",
      "Doublet (1L NDMM)", "Monotherapy (1L NDMM)", "Other (1L NDMM)")
  }

  # reserved synthetic PATID range 9_000_000_000 .. 9_999_999_999
  patient_id <- sprintf("%010.0f", 9000000000 + seq_len(n) - 1)

  age_index  <- pmin(95L, pmax(30L, round(rnorm(n, 69, 11))))
  gender     <- sample(c("Female", "Male", "Unknown"), n, TRUE,
                        c(0.46, 0.535, 0.005))
  region     <- sample(c("Midwest", "Northeast", "South", "West", "Unknown"),
                        n, TRUE, c(0.26, 0.18, 0.40, 0.15, 0.01))
  payer_type <- sample(c("Commercial", "Medicare Advantage"), n, TRUE,
                       c(0.45, 0.55))
  race       <- sample(c("White", "Black", "Asian", "Hispanic", "Other/Unknown"),
                       n, TRUE, c(0.62, 0.18, 0.05, 0.08, 0.07))

  # index / 1L start (1L start ~ index for the parent; jitter a few days)
  origin     <- as.Date("2016-01-01")
  index_date <- origin + sample(0:(as.integer(as.Date("2024-12-31") - origin)),
                                n, TRUE)
  lot1_start_dt <- index_date + sample(0:5, n, TRUE)

  # SOC regimen group (skewed toward triplets/quadruplets)
  soc_category <- sample(soc_levels, n, TRUE,
                         c(0.22, 0.20, 0.18, 0.20, 0.12, 0.08))
  n_lines      <- sample(1:5, n, TRUE, c(0.42, 0.27, 0.16, 0.09, 0.06))
  lot1_length  <- round(pmax(20, rgamma(n, shape = 2.2, scale = 130)))

  # ---- time-to-event (months) ----
  # rwOS: exponential-ish; older + later line => shorter
  base_os <- rexp(n, rate = 1 / 52)
  os_raw  <- base_os * (1 - (age_index - 69) / 260) * (1 - (n_lines - 1) * 0.07)
  os_time <- round(pmin(120, pmax(0.5, os_raw)), 1)
  os_event <- as.integer(runif(n) < 0.46)           # ~46% deaths observed

  # death date consistent with OS event
  death_dt <- as.Date(rep(NA_integer_, n), origin = "1970-01-01")
  ev <- os_event == 1L
  death_dt[ev] <- lot1_start_dt[ev] + round(os_time[ev] * 30.44)

  # rwPFS <= OS; rwTTD (discontinuation) <= PFS-ish; rwTTNT next-treatment
  pfs_time  <- round(pmin(os_time, pmax(0.3, os_time * runif(n, 0.45, 0.95))), 1)
  pfs_event <- as.integer(runif(n) < 0.62)
  ttd_time  <- round(pmax(0.3, pmin(pfs_time, lot1_length / 30.44 *
                                      runif(n, 0.8, 1.3))), 1)
  ttd_event <- as.integer(runif(n) < 0.7)
  ttnt_time <- round(pmin(os_time, ttd_time + rexp(n, 1 / 6)), 1)
  ttnt_event <- as.integer(n_lines > 1L)            # next tx observed iff LOT2+

  df <- data.frame(
    patient_id, age_index, gender, region, payer_type, race,
    index_date, lot1_start_dt, death_dt,
    soc_category, n_lines, lot1_length,
    os_time, os_event, pfs_time, pfs_event,
    ttd_time, ttd_event, ttnt_time, ttnt_event,
    stringsAsFactors = FALSE)

  # ---- IE flags (1 = patient satisfies the criterion) ----
  # Make them correlated with the demographics so toggling criteria visibly
  # moves the cohort (and the attrition waterfall is non-trivial).
  bern <- function(p) as.integer(runif(n) < p)

  df$incl_qualifying_mm  <- bern(0.985)
  df$incl_adult          <- as.integer(age_index >= 18L)        # ties to slider
  df$incl_eligible_1l_tx <- as.integer(lot1_start_dt >= as.Date("2017-01-01"))
  df$incl_baseline_ce_6m  <- bern(0.88)
  # 12m CE is a subset of 6m CE (tighter): only patients with 6m can have 12m
  df$incl_baseline_ce_12m <- as.integer(df$incl_baseline_ce_6m == 1L & runif(n) < 0.78)
  df$incl_fu_ce_3m        <- as.integer(os_event == 1L | runif(n) < 0.8)  # death satisfies
  df$incl_new_user        <- bern(0.9)
  df$incl_fu_mm_agents    <- bern(0.995)                        # superset is treated
  df$excl_prior_mm_tx     <- bern(0.91)
  df$excl_other_cancer    <- bern(0.86)
  df$excl_belantamab      <- bern(0.985)
  df$excl_pregnancy       <- as.integer(!(gender == "Female" & runif(n) < 0.01))

  rownames(df) <- NULL
  df
}
