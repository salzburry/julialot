# =============================================================================
# summaries.R  --  Patient Characteristics summary statistics
# -----------------------------------------------------------------------------
# Reproduces the sample dashboard's "Summary Statistics" tables and the NDMM
# protocol's Table 1: categorical variables as N / % (overall + per strata
# level, incl. an explicit (Missing) category), continuous variables as
# mean / SD / median / IQR / min / max + a Missing count. Applies the
# protocol's <25-patient suppression to strata (§6.5). Pure base R.
# =============================================================================

SUPPRESS_MIN_N <- 25L   # protocol §6.5: do not report a stratum with < 25 pts

# Variable dictionary: label + type ("cat" | "cont" | "binary"). Drives the
# "Select Variables" control and dispatches to the right summary.
variable_dictionary <- function() {
  list(
    # ---- continuous ----
    age_index        = list(label = "Age at index (years)", type = "cont"),
    cci              = list(label = "Charlson Comorbidity Index", type = "cont"),
    dx_to_1l_months  = list(label = "Time diagnosis -> 1L (months)", type = "cont"),
    fu_from_dx_months= list(label = "Follow-up from diagnosis (months)", type = "cont"),
    lot1_length      = list(label = "LOT1 length (days)", type = "cont"),
    n_lines          = list(label = "Number of lines", type = "cont"),
    ip_los_days      = list(label = "Baseline inpatient LOS (days)", type = "cont"),
    ip_hosp_count    = list(label = "Baseline inpatient hospitalisations (n)", type = "cont"),
    er_visit_count   = list(label = "Baseline ER visits (n)", type = "cont"),
    # ---- categorical (demographics) ----
    gender       = list(label = "Sex", type = "cat"),
    region       = list(label = "Region", type = "cat"),
    race         = list(label = "Race", type = "cat"),
    ethnicity    = list(label = "Ethnicity", type = "cat"),
    payer_type   = list(label = "Insurance type", type = "cat"),
    age_band     = list(label = "Age band", type = "cat"),
    age_ge70     = list(label = "Age >= 70", type = "cat"),
    cci_band     = list(label = "CCI band", type = "cat"),
    dx_year      = list(label = "Year of first MM diagnosis", type = "cat"),
    lot_init_year= list(label = "Year of 1L initiation", type = "cat"),
    soc_category = list(label = "1L SOC regimen category", type = "cat"),
    lot_soc      = list(label = "Current-line SOC regimen", type = "cat"),
    ti_te_age    = list(label = "Transplant eligibility (age proxy)", type = "cat"),
    ti_te_age_cci= list(label = "Transplant eligibility (age or CCI proxy)", type = "cat"),
    ip_hosp_band = list(label = "Baseline inpatient hospitalisations", type = "cat"),
    er_visit_band= list(label = "Baseline ER visits", type = "cat"),
    # ---- baseline comorbidities of interest (binary -> Yes/No) ----
    bl_hepatic   = list(label = "Baseline hepatic toxicity", type = "binary"),
    bl_renal     = list(label = "Baseline renal impairment", type = "binary"),
    bl_infection = list(label = "Baseline serious infection", type = "binary"),
    bl_ocular    = list(label = "Baseline ocular event", type = "binary"),
    bl_cv        = list(label = "Baseline cardiovascular condition", type = "binary"),
    bl_neuro     = list(label = "Baseline neurologic condition", type = "binary")
  )
}

var_label <- function(v, dict = variable_dictionary())
  if (!is.null(dict[[v]])) dict[[v]]$label else v
var_type <- function(v, dict = variable_dictionary())
  if (!is.null(dict[[v]])) dict[[v]]$type else "cat"

# render a variable as a character vector of categories, mapping NA -> (Missing)
# and binary 0/1 -> No/Yes.
.as_category <- function(x, type) {
  if (identical(type, "binary")) x <- ifelse(x == 1L, "Yes", "No")
  x <- as.character(x)
  x[is.na(x) | !nzchar(x)] <- "(Missing)"
  x
}

# build strata groups, dropping any strata level with < SUPPRESS_MIN_N patients
# (Overall is never suppressed). Returns list(groups=, suppressed=char vec).
.build_groups <- function(df, strata, min_n = SUPPRESS_MIN_N) {
  groups <- list(Overall = rep(TRUE, nrow(df)))
  suppressed <- character(0)
  if (!is.null(strata) && nzchar(strata) && strata %in% names(df)) {
    lv <- sort(unique(.as_category(df[[strata]], var_type(strata))))
    for (l in lv) {
      sel <- .as_category(df[[strata]], var_type(strata)) == l
      if (sum(sel) < min_n) { suppressed <- c(suppressed, l); next }
      groups[[l]] <- sel
    }
  }
  list(groups = groups, suppressed = suppressed)
}

# ---- categorical summary ----------------------------------------------------
summarize_categorical <- function(df, vars, strata = NULL,
                                   dict = variable_dictionary()) {
  vars <- vars[vapply(vars, function(v) var_type(v, dict) %in% c("cat", "binary"),
                      logical(1))]
  if (!length(vars) || !nrow(df)) return(NULL)
  g <- .build_groups(df, strata); groups <- g$groups

  out <- list()
  for (v in vars) {
    cats <- .as_category(df[[v]], var_type(v, dict))
    for (lv in sort(unique(cats))) {
      row <- list(Variable = var_label(v, dict), Category = lv)
      for (nm in names(groups)) {
        sel <- groups[[nm]]; n_g <- sum(sel); n_c <- sum(sel & cats == lv)
        row[[paste0(nm, " N")]] <- n_c
        row[[paste0(nm, " %")]] <- if (n_g) round(100 * n_c / n_g, 2) else NA_real_
      }
      out[[length(out) + 1L]] <- as.data.frame(row, check.names = FALSE,
                                               stringsAsFactors = FALSE)
    }
  }
  res <- do.call(rbind, out)
  attr(res, "suppressed") <- g$suppressed
  res
}

# ---- continuous summary ------------------------------------------------------
summarize_continuous <- function(df, vars, strata = NULL,
                                  dict = variable_dictionary()) {
  vars <- vars[vapply(vars, function(v) var_type(v, dict) == "cont", logical(1))]
  if (!length(vars) || !nrow(df)) return(NULL)
  g <- .build_groups(df, strata); groups <- g$groups

  out <- list()
  for (v in vars) {
    for (nm in names(groups)) {
      raw <- suppressWarnings(as.numeric(df[[v]][groups[[nm]]]))
      x   <- raw[!is.na(raw)]
      q   <- if (length(x)) stats::quantile(x, c(0.25, 0.5, 0.75)) else rep(NA, 3)
      out[[length(out) + 1L]] <- data.frame(
        Variable = var_label(v, dict), Group = nm,
        N = length(x), Missing = sum(is.na(raw)),
        Mean = rnd(mean_or_na(x)), SD = rnd(sd_or_na(x)),
        Median = rnd(q[2]), Q1 = rnd(q[1]), Q3 = rnd(q[3]),
        Min = rnd(min_or_na(x)), Max = rnd(max_or_na(x)),
        check.names = FALSE, stringsAsFactors = FALSE)
    }
  }
  res <- do.call(rbind, out)
  attr(res, "suppressed") <- g$suppressed
  res
}

# ---- baseline safety-event table (n / % + rate per patient-year) ------------
# Protocol §6.7.1: background prevalence of key safety events with n/% AND rate
# per patient-year over the 12-mo baseline (baseline_py).
safety_baseline_table <- function(df) {
  if (!nrow(df) || !"baseline_py" %in% names(df)) return(NULL)
  events <- list(
    c("bl_hepatic", "n_hepatic",   "Hepatic toxicity"),
    c("bl_renal",   "n_renal",     "Renal impairment"),
    c("bl_infection","n_infection","Serious infection"),
    c("bl_ocular",  "n_ocular",    "Ocular event"),
    c("bl_cv",      "n_cv",        "Cardiovascular condition"),
    c("bl_neuro",   "n_neuro",     "Neurologic condition"))
  py <- sum(df$baseline_py, na.rm = TRUE)
  rows <- lapply(events, function(e) {
    flg <- e[1]; cnt <- e[2]
    if (!all(c(flg, cnt) %in% names(df))) return(NULL)
    n_pt <- sum(df[[flg]] == 1L); n_ev <- sum(df[[cnt]])
    data.frame(
      Event = e[3],
      `Patients (n)` = n_pt,
      `Patients (%)` = round(100 * n_pt / nrow(df), 2),
      `Events (n)` = n_ev,
      `Person-years` = round(py, 1),
      `Rate per 100 PY` = if (py > 0) round(100 * n_ev / py, 2) else NA_real_,
      check.names = FALSE, stringsAsFactors = FALSE)
  })
  do.call(rbind, Filter(Negate(is.null), rows))
}

# strata levels suppressed (<25 pts) for a df + strata var (drives the note even
# when only continuous variables are shown).
suppressed_strata <- function(df, strata, min_n = SUPPRESS_MIN_N) {
  if (is.null(strata) || !nzchar(strata) || !strata %in% names(df)) return(character(0))
  tb <- table(.as_category(df[[strata]], var_type(strata)))
  names(tb)[tb < min_n]
}

# small NA-safe helpers
mean_or_na <- function(x) if (length(x)) mean(x) else NA_real_
sd_or_na   <- function(x) if (length(x) > 1) stats::sd(x) else NA_real_
min_or_na  <- function(x) if (length(x)) min(x) else NA_real_
max_or_na  <- function(x) if (length(x)) max(x) else NA_real_
rnd        <- function(x) if (is.na(x)) NA_real_ else round(x, 2)
