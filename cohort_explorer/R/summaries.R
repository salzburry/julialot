# =============================================================================
# summaries.R  --  Patient Characteristics summary statistics
# -----------------------------------------------------------------------------
# Reproduces the sample dashboard's "Summary Statistics" tables: categorical
# variables as N / % (overall + per strata level) and continuous variables as
# mean / SD / median / IQR. Pure base R.
# =============================================================================

# Variable dictionary: label + type ("cat" | "cont"). Drives the
# "Select Variables" control and dispatches to the right summary.
variable_dictionary <- function() {
  list(
    age_index    = list(label = "Age at index (years)", type = "cont"),
    lot1_length  = list(label = "LOT1 length (days)",    type = "cont"),
    n_lines      = list(label = "Number of lines",       type = "cont"),
    os_time      = list(label = "rwOS follow-up (months)", type = "cont"),
    gender       = list(label = "Gender",                type = "cat"),
    region       = list(label = "Region",                type = "cat"),
    race         = list(label = "Race",                  type = "cat"),
    payer_type   = list(label = "Payer / product type",  type = "cat"),
    soc_category = list(label = "1L SOC regimen category", type = "cat")
  )
}

var_label <- function(v, dict = variable_dictionary()) {
  if (!is.null(dict[[v]])) dict[[v]]$label else v
}
var_type <- function(v, dict = variable_dictionary()) {
  if (!is.null(dict[[v]])) dict[[v]]$type else "cat"
}

# ---- categorical summary ----------------------------------------------------
# Returns a long data.frame: Variable, Category, then for "Overall" and each
# strata level a paired N and pct column. Denominator per column = column total
# (matches the sample footnote: strata columns are 100% on their own total).
summarize_categorical <- function(df, vars, strata = NULL,
                                   dict = variable_dictionary()) {
  vars <- vars[vapply(vars, function(v) var_type(v, dict) == "cat", logical(1))]
  if (!length(vars) || !nrow(df)) return(NULL)

  groups <- list(Overall = rep(TRUE, nrow(df)))
  if (!is.null(strata) && nzchar(strata) && strata %in% names(df)) {
    for (lv in sort(unique(as.character(df[[strata]]))))
      groups[[lv]] <- as.character(df[[strata]]) == lv
  }

  out <- list()
  for (v in vars) {
    lv_all <- sort(unique(as.character(df[[v]])))
    for (lv in lv_all) {
      row <- list(Variable = var_label(v, dict), Category = lv)
      for (g in names(groups)) {
        sel <- groups[[g]]
        n_g <- sum(sel)
        n_c <- sum(sel & as.character(df[[v]]) == lv)
        row[[paste0(g, " N")]]   <- n_c
        row[[paste0(g, " %")]]   <- if (n_g) round(100 * n_c / n_g, 2) else NA_real_
      }
      out[[length(out) + 1L]] <- as.data.frame(row, check.names = FALSE,
                                               stringsAsFactors = FALSE)
    }
  }
  do.call(rbind, out)
}

# ---- continuous summary ------------------------------------------------------
# Returns: Variable, Statistic columns (N, Mean, SD, Median, Q1, Q3, Min, Max),
# one block of rows per strata group.
summarize_continuous <- function(df, vars, strata = NULL,
                                  dict = variable_dictionary()) {
  vars <- vars[vapply(vars, function(v) var_type(v, dict) == "cont", logical(1))]
  if (!length(vars) || !nrow(df)) return(NULL)

  groups <- list(Overall = rep(TRUE, nrow(df)))
  if (!is.null(strata) && nzchar(strata) && strata %in% names(df)) {
    for (lv in sort(unique(as.character(df[[strata]]))))
      groups[[lv]] <- as.character(df[[strata]]) == lv
  }

  out <- list()
  for (v in vars) {
    for (g in names(groups)) {
      x <- suppressWarnings(as.numeric(df[[v]][groups[[g]]]))
      x <- x[!is.na(x)]
      q <- if (length(x)) stats::quantile(x, c(0.25, 0.5, 0.75)) else rep(NA, 3)
      out[[length(out) + 1L]] <- data.frame(
        Variable = var_label(v, dict), Group = g,
        N = length(x),
        Mean   = rnd(mean_or_na(x)), SD = rnd(sd_or_na(x)),
        Median = rnd(q[2]), Q1 = rnd(q[1]), Q3 = rnd(q[3]),
        Min = rnd(min_or_na(x)), Max = rnd(max_or_na(x)),
        check.names = FALSE, stringsAsFactors = FALSE)
    }
  }
  do.call(rbind, out)
}

# small NA-safe helpers
mean_or_na <- function(x) if (length(x)) mean(x) else NA_real_
sd_or_na   <- function(x) if (length(x) > 1) stats::sd(x) else NA_real_
min_or_na  <- function(x) if (length(x)) min(x) else NA_real_
max_or_na  <- function(x) if (length(x)) max(x) else NA_real_
rnd        <- function(x) if (is.na(x)) NA_real_ else round(x, 2)
