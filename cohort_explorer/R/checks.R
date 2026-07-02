# =============================================================================
# checks.R  --  reusable validation/QC over the SELECTED sub-cohort
# -----------------------------------------------------------------------------
# Two families:
#   lot_checks()            structural sanity of the LOT derivation
#   ndmm_protocol_checks()  each NDMM IE criterion, as a protocol conformance
#                           pass-rate on the currently selected cohort
# Each returns a tidy data.frame (Check, Status, Detail) with Status in
# PASS / WARN / FAIL, so the dashboard can colour them and a headless run can
# assert on them. Pure base R; safe on an empty cohort.
# =============================================================================

.chk <- function(name, ok, detail, warn_ok = NULL) {
  status <- if (isTRUE(ok)) "PASS" else if (isTRUE(warn_ok)) "WARN" else "FAIL"
  data.frame(Check = name, Status = status, Detail = detail,
             stringsAsFactors = FALSE)
}

# ---- LOT structural checks --------------------------------------------------
lot_checks <- function(df, max_lot = 5L) {
  if (!nrow(df))
    return(.chk("Cohort non-empty", FALSE, "Selected cohort has 0 patients."))

  pct <- function(x) sprintf("%d of %d (%.1f%%)", sum(x), length(x),
                             100 * mean(x))
  rows <- list(
    .chk("LOT count in 1..MAX_LOT",
         all(df$n_lines >= 1L & df$n_lines <= max_lot),
         sprintf("n_lines range observed: %d..%d (MAX_LOT=%d).",
                 min(df$n_lines), max(df$n_lines), max_lot)),

    .chk("LOT1 length positive",
         all(df$lot1_length > 0),
         sprintf("Min LOT1 length = %.0f days.", min(df$lot1_length))),

    .chk("Index date <= LOT1 start",
         all(df$index_date <= df$lot1_start_dt),
         "Each patient's MM index precedes (or equals) their 1L start."),

    .chk("rwPFS <= rwOS (per patient)",
         all(df$pfs_time <= df$os_time + 1e-6),
         sprintf("PFS exceeds OS for %s patients.",
                 sum(df$pfs_time > df$os_time + 1e-6))),

    # matches the loader's rule: os_event=1 REQUIRES a death date; death_dt
    # present with os_event=0 (death after administrative censoring) is allowed,
    # so this no longer FAILs a state validate_flagged_cohort() accepts.
    .chk("Death date present when OS event",
         all(df$os_event != 1L | !is.na(df$death_dt)),
         sprintf("%s death-event patient(s) missing a death date.",
                 sum(df$os_event == 1L & is.na(df$death_dt)))),

    .chk("rwTTNT event iff LOT2+",
         all((df$ttnt_event == 1L) == (df$n_lines > 1L)),
         "Next-treatment event holds exactly when a subsequent line exists."),

    .chk("SOC regimen category populated",
         all(!is.na(df$soc_category) & nzchar(df$soc_category)),
         sprintf("Non-missing 1L SOC category: %s.",
                 pct(!is.na(df$soc_category) & nzchar(df$soc_category))))
  )
  do.call(rbind, rows)
}

# ---- NDMM protocol conformance ---------------------------------------------
# For each NDMM IE criterion, report the pass-rate on the selected cohort.
# If the criterion is ACTIVE it must be 100% (the selection enforced it) -> a
# <100% rate is a FAIL (selection bug). If it is INACTIVE, the rate is
# informational (WARN if it would exclude patients), so a user can see the
# impact of a criterion they have currently switched off.
ndmm_protocol_checks <- function(df, active_flags = character(),
                                 reg = criteria_registry()) {
  if (!nrow(df))
    return(.chk("Cohort non-empty", FALSE, "Selected cohort has 0 patients."))

  flag_ids <- registry_flag_ids(reg)
  rows <- lapply(flag_ids, function(id) {
    crit   <- registry_get(id, reg)
    rate   <- mean(df[[id]] == crit$keep_when)
    active <- id %in% active_flags
    detail <- sprintf("%s | satisfied by %.1f%% of selected cohort.",
                      if (active) "ACTIVE" else "inactive", 100 * rate)
    if (active) {
      .chk(crit$label, isTRUE(all.equal(rate, 1)), detail)
    } else {
      # inactive: PASS if it wouldn't exclude anyone, else WARN (informational)
      .chk(crit$label, isTRUE(all.equal(rate, 1)), detail, warn_ok = TRUE)
    }
  })
  out <- do.call(rbind, rows)

  # cross-criterion protocol invariant: 12m CE must be a subset of 6m CE
  if (all(c("incl_baseline_ce_6m", "incl_baseline_ce_12m") %in% names(df))) {
    bad <- sum(df$incl_baseline_ce_12m == 1L & df$incl_baseline_ce_6m == 0L)
    out <- rbind(out, .chk("12m baseline CE subset of 6m CE", bad == 0,
                           sprintf("%d patients flagged 12m-CE without 6m-CE.", bad)))
  }
  out
}

# ---- protocol data-quality / analysis-readiness checks ----------------------
# Reports the TTE denominator (>=3-mo follow-up), missing/unknown tallies, and
# <25-patient suppression flags. By default it audits EVERY categorical/binary
# variable the UI can offer as a stratum (from variable_dictionary()), so the
# Checks tab covers exactly what a user can select -- not a hand-picked subset.
protocol_dq_checks <- function(df, min_fu = 3L, strata_vars = NULL,
                               dict = variable_dictionary()) {
  if (!nrow(df))
    return(.chk("Cohort non-empty", FALSE, "Selected cohort has 0 patients."))
  cat_bin <- intersect(names(dict)[vapply(dict,
    function(x) x$type %in% c("cat", "binary"), logical(1))], names(df))
  cat_only <- intersect(names(dict)[vapply(dict,
    function(x) identical(x$type, "cat"), logical(1))], names(df))
  if (is.null(strata_vars)) strata_vars <- cat_bin      # all selectable strata
  rows <- list()

  if ("fu_potential_months" %in% names(df)) {
    n_fu <- sum(df$fu_potential_months >= min_fu, na.rm = TRUE)
    rows[[length(rows) + 1L]] <- .chk(
      sprintf("TTE denominator (>=%d-mo follow-up)", min_fu), n_fu > 0,
      sprintf("%d of %d patients (%.1f%%) meet the follow-up cut.",
              n_fu, nrow(df), 100 * n_fu / nrow(df)), warn_ok = TRUE)
  }

  # missing/unknown tally for every categorical characteristic (+ CCI)
  for (v in unique(c(cat_only, intersect("cci", names(df))))) {
    miss <- sum(is.na(df[[v]]) |
                (is.character(df[[v]]) & df[[v]] %in% c("", "Unknown", "(Missing)")))
    rows[[length(rows) + 1L]] <- .chk(
      paste0("Missing/Unknown: ", v), miss == 0,
      sprintf("%d of %d (%.1f%%).", miss, nrow(df), 100 * miss / nrow(df)),
      warn_ok = TRUE)
  }

  # <25 suppression flags on every selectable stratum
  for (sv in intersect(strata_vars, names(df))) {
    small <- names(which(table(as.character(df[[sv]])) < 25L))
    rows[[length(rows) + 1L]] <- .chk(
      paste0("Strata >=25 pts: ", sv), length(small) == 0,
      if (length(small))
        paste0("suppressed (<25): ", paste(small, collapse = ", "))
      else "all levels reportable.", warn_ok = TRUE)
  }
  do.call(rbind, rows)
}

# Roll a checks table up to a one-line headline for the UI banner.
checks_headline <- function(tbl) {
  if (is.null(tbl) || !nrow(tbl)) return("No checks run.")
  n_fail <- sum(tbl$Status == "FAIL"); n_warn <- sum(tbl$Status == "WARN")
  if (n_fail) sprintf("%d FAIL, %d WARN, %d PASS", n_fail, n_warn,
                      sum(tbl$Status == "PASS"))
  else if (n_warn) sprintf("All structural checks pass (%d WARN informational).", n_warn)
  else "All checks pass."
}
